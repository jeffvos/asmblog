; log.asm — the access log (Combined Log Format), opt-in.
;
; BLOGD_ACCESS_LOG picks the sink: unset or empty means no log at all
; (the request path pays one compare), "-" means stdout (the journal
; under systemd, `docker logs` in a container), anything else is a file
; opened once at startup with O_APPEND — before seccomp; write is the
; only syscall the log needs afterwards. One line per answered request,
; assembled on the stack and written with a single write(), so lines
; from different workers never interleave:
;
;   client - - [08/Sep/2026:17:19:00 +0000] "GET /x HTTP/1.1" 200 1234 "referer" "user-agent"
;
; client is the first address in X-Forwarded-For when the request
; carries one that looks like an address (blogd sits behind a proxy),
; else the peer address. Everything copied from the request is
; sanitised — bytes below 0x20, 0x7F and the double quote become '_' —
; so a request cannot forge a log line. bytes counts the response as
; sent, headers included (a HEAD counts its headers, a rendition its
; mapped file).

BITS 64
%include "src/sys.inc"
%include "src/conn.inc"

extern getenv_value
extern mem_copy
extern u64_to_dec
extern fmt_httpdate
extern find_header
extern hdr_block

global alog_init
global alog_request

%define LINE_MAX  2048
%define REQ_MAX   512           ; request line bytes kept
%define HDR_MAX   256           ; referer / user-agent bytes kept
%define O_APPEND  0x400

section .text

; alog_init() -> 0, or -1 when the configured file cannot be opened
alog_init:
    mov qword [alog_fd], -1
    mov rdi, env_alog
    call getenv_value           ; rax = value (0 unset), rdx = length
    test rax, rax
    jz .ok
    test rdx, rdx
    jz .ok
    cmp rdx, 1
    jne .file
    cmp byte [rax], '-'
    jne .file
    mov qword [alog_fd], STDOUT
    jmp .ok
.file:
    mov rdi, rax                ; NUL-terminated by the kernel
    mov esi, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC
    mov edx, 0o644
    mov eax, SYS_open
    syscall
    test rax, rax
    js .fail
    mov [alog_fd], rax
.ok:
    xor eax, eax
    ret
.fail:
    mov rax, -1
    ret

; alog_request(ctx, head_len) — head_len = the parsed request head, or
; 0 for a request rejected before parsing (400/411/413/431: the line
; is whatever arrived, no header lookups). Call it once the response
; is staged in the outbuf and before the inbuf is consumed.
alog_request:
    cmp qword [alog_fd], 0
    jl .off                     ; -1: disabled
    push r12
    push r13
    push r14
    push rbx
    sub rsp, LINE_MAX + 32      ; [0, LINE_MAX) the line; then httpdate scratch
    mov r12, rdi
    mov r13, rsi
    mov rbx, rsp                ; cursor
    ; --- client: X-Forwarded-For's first hop, else the peer ---
    test r13, r13
    jz .peer
    mov rdi, r12
    call hdr_block
    mov rdi, rax
    mov rsi, rdx
    mov rdx, h_xff
    mov ecx, h_xff_len
    call find_header
    test rax, rax
    jz .peer
    xor ecx, ecx
.xff:
    cmp rcx, rdx
    jae .xff_end
    cmp rcx, 45
    jae .peer                   ; longer than any address
    mov r8b, [rax+rcx]
    cmp r8b, ','
    je .xff_end
    cmp r8b, '.'
    je .xff_ok
    cmp r8b, ':'
    je .xff_ok
    cmp r8b, '0'
    jb .peer
    cmp r8b, '9'
    jbe .xff_ok
    or r8b, 0x20
    cmp r8b, 'a'
    jb .peer
    cmp r8b, 'f'
    ja .peer
.xff_ok:
    inc rcx
    jmp .xff
.xff_end:
    test rcx, rcx
    jz .peer
    mov rdi, rbx
    mov rsi, rax
    mov rdx, rcx
    call mem_copy
    mov rbx, rax
    jmp .client_done
.peer:
    xor r14d, r14d              ; dotted quad from CTX_PEER
.oct:
    movzx edi, byte [r12+CTX_PEER+r14]
    mov rsi, rbx
    call u64_to_dec
    mov rbx, rax
    inc r14
    cmp r14, 4
    jae .client_done
    mov byte [rbx], '.'
    inc rbx
    jmp .oct
.client_done:
    mov rdi, rbx
    mov rsi, s_ident
    mov edx, s_ident_len
    call mem_copy
    mov rbx, rax
    ; --- date: from the IMF-fixdate "Sun, 06 Nov 1994 08:49:37 GMT" ---
    mov rdi, [r12+CTX_LAST]     ; the worker's clock, as the Date header
    lea rsi, [rsp+LINE_MAX]
    call fmt_httpdate
    lea rsi, [rsp+LINE_MAX]
    mov ax, [rsi+5]             ; dd
    mov [rbx], ax
    mov byte [rbx+2], '/'
    mov eax, [rsi+8]            ; "Mon " ...
    mov [rbx+3], eax
    mov byte [rbx+6], '/'       ; ... the space becomes the slash
    mov eax, [rsi+12]           ; yyyy
    mov [rbx+7], eax
    mov byte [rbx+11], ':'
    mov rax, [rsi+17]           ; hh:mm:ss
    mov [rbx+12], rax
    add rbx, 20
    mov rdi, rbx
    mov rsi, s_tz
    mov edx, s_tz_len
    call mem_copy
    mov rbx, rax
    ; --- request line: up to the first CR/LF, at most REQ_MAX bytes ---
    lea rsi, [r12+CTX_IN]
    mov rdx, [r12+CTX_IN_USED]
    cmp rdx, REQ_MAX
    jbe .rl
    mov edx, REQ_MAX
.rl:
    xor ecx, ecx
.rl_scan:
    cmp rcx, rdx
    jae .rl_done
    mov al, [rsi+rcx]
    cmp al, 13
    je .rl_done
    cmp al, 10
    je .rl_done
    inc rcx
    jmp .rl_scan
.rl_done:
    mov rdi, rbx
    mov rdx, rcx
    call copy_san
    mov rbx, rax
    mov word [rbx], '" '
    add rbx, 2
    ; --- status: the three digits after "HTTP/1.1 " ---
    mov rax, [r12+CTX_OUT_START]
    mov eax, [r12+CTX_OUT+rax+9]
    mov [rbx], eax              ; "200 " (the space comes along)
    add rbx, 4
    ; --- bytes: the outbuf slice plus a mapped file, if any ---
    mov rdi, [r12+CTX_OUT_LEN]
    cmp qword [r12+CTX_FILE_P], 0
    je .nofile
    add rdi, [r12+CTX_FILE_L]
.nofile:
    mov rsi, rbx
    call u64_to_dec
    mov rbx, rax
    mov word [rbx], ' "'
    add rbx, 2
    ; --- referer ---
    mov rdi, h_referer
    mov esi, h_referer_len
    call put_header
    mov dword [rbx], '" "'
    add rbx, 3
    ; --- user-agent ---
    mov rdi, h_ua
    mov esi, h_ua_len
    call put_header
    mov word [rbx], 0x0A22      ; '"' LF
    add rbx, 2
    mov rdi, [alog_fd]
    mov rsi, rsp
    mov rdx, rbx
    sub rdx, rsp
    mov eax, SYS_write
    syscall                     ; a short or failed write loses a line,
    add rsp, LINE_MAX + 32      ; never the request
    pop rbx
    pop r14
    pop r13
    pop r12
.off:
    ret

; put_header(name_lc, name_len) — appends the header's value at rbx
; (sanitised, HDR_MAX at most) or '-'. Internal: r12 = ctx, r13 =
; head length, rbx = cursor (advanced).
put_header:
    push r14
    push r15
    mov r14, rdi
    mov r15, rsi
    test r13, r13
    jz .dash
    mov rdi, r12
    call hdr_block
    mov rdi, rax
    mov rsi, rdx
    mov rdx, r14
    mov rcx, r15
    call find_header
    test rax, rax
    jz .dash
    cmp rdx, HDR_MAX
    jbe .len_ok
    mov edx, HDR_MAX
.len_ok:
    mov rdi, rbx
    mov rsi, rax
    call copy_san
    mov rbx, rax
    jmp .ret
.dash:
    mov byte [rbx], '-'
    inc rbx
.ret:
    pop r15
    pop r14
    ret

; copy_san(dst, src, len) -> rax = dst+len; control bytes, DEL and the
; double quote become '_'
copy_san:
    xor ecx, ecx
.b:
    cmp rcx, rdx
    jae .done
    mov al, [rsi+rcx]
    cmp al, 0x20
    jb .bad
    cmp al, 0x7f
    je .bad
    cmp al, '"'
    jne .put
.bad:
    mov al, '_'
.put:
    mov [rdi+rcx], al
    inc rcx
    jmp .b
.done:
    lea rax, [rdi+rdx]
    ret

section .data
env_alog:  db 'BLOGD_ACCESS_LOG', 0
s_ident:   db ' - - ['
s_ident_len equ $-s_ident
s_tz:      db ' +0000] "'
s_tz_len equ $-s_tz
h_xff:     db 'x-forwarded-for:'
h_xff_len equ $-h_xff
h_referer: db 'referer:'
h_referer_len equ $-h_referer
h_ua:      db 'user-agent:'
h_ua_len equ $-h_ua

section .bss
alog_fd: resq 1

section .note.GNU-stack noalloc noexec nowrite progbits
