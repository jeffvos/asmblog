; net.asm — per-worker event loop: SO_REUSEPORT listener + epoll,
; nonblocking connections with keep-alive.
;
; Every worker owns its own listening socket (the kernel load-balances
; via SO_REUSEPORT) and its own epoll instance, so there is no shared
; accept lock and no cross-thread state at all in this file: connection
; contexts live and die within one worker.
;
; epoll data field: 0 = the listener, otherwise a ctx pointer.
; Level-triggered; reads and writes always run to EAGAIN.

BITS 64
%include "src/sys.inc"
%include "src/conn.inc"

extern mem_copy
extern http_handle
extern http_body_len
extern build_page
extern listen_addr

global worker_main
global workers_ready

; worker state block (one private mmap per worker):
%define WS_LFD    0
%define WS_EP     8
%define WS_FREE   16            ; ctx freelist head
%define WS_EVBUF  24            ; 64 epoll_events x 12 bytes
%define WS_TOTAL  4096
%define MAX_EVENTS 64

section .text

; worker_main(unused) — never returns.
worker_main:
    ; ws = private state block
    xor edi, edi
    mov esi, WS_TOTAL
    mov edx, PROT_READ | PROT_WRITE
    mov r10d, MAP_PRIVATE | MAP_ANONYMOUS
    mov r8, -1
    xor r9d, r9d
    mov eax, SYS_mmap
    syscall
    cmp rax, -4095
    jae .fatal
    mov r12, rax                ; r12 = ws for the rest of the loop

    ; nonblocking listener with SO_REUSEPORT
    mov edi, AF_INET
    mov esi, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC
    xor edx, edx
    mov eax, SYS_socket
    syscall
    test rax, rax
    js .fatal
    mov [r12+WS_LFD], rax
    mov rdi, rax
    mov esi, SOL_SOCKET
    mov edx, SO_REUSEADDR
    mov r10, one_dw
    mov r8d, 4
    mov eax, SYS_setsockopt
    syscall
    mov rdi, [r12+WS_LFD]
    mov esi, SOL_SOCKET
    mov edx, SO_REUSEPORT
    mov r10, one_dw
    mov r8d, 4
    mov eax, SYS_setsockopt
    syscall
    mov rdi, [r12+WS_LFD]
    mov rsi, listen_addr
    mov edx, 16
    mov eax, SYS_bind
    syscall
    test rax, rax
    js .fatal
    mov rdi, [r12+WS_LFD]
    mov esi, 512
    mov eax, SYS_listen
    syscall
    test rax, rax
    js .fatal

    xor edi, edi
    mov eax, SYS_epoll_create1
    syscall
    test rax, rax
    js .fatal
    mov [r12+WS_EP], rax

    ; register the listener with data = 0
    sub rsp, 16
    mov dword [rsp], EPOLLIN
    mov qword [rsp+4], 0
    mov rdi, [r12+WS_EP]
    mov esi, EPOLL_CTL_ADD
    mov rdx, [r12+WS_LFD]
    mov r10, rsp
    mov eax, SYS_epoll_ctl
    syscall
    add rsp, 16
    test rax, rax
    js .fatal

    ; signal setup complete: main waits for all workers before it
    ; installs the seccomp filter (whose allowlist excludes the
    ; socket/bind/listen/epoll_create1 syscalls used only up to here).
    lock inc qword [workers_ready]

.loop:
    mov rdi, [r12+WS_EP]
    lea rsi, [r12+WS_EVBUF]
    mov edx, MAX_EVENTS
    mov r10, -1
    mov eax, SYS_epoll_wait
    syscall
    cmp rax, 0
    jle .loop                   ; EINTR or spurious: just wait again
    mov r13, rax                ; event count
    xor ebx, ebx                ; index
.evloop:
    cmp rbx, r13
    jae .loop
    lea r15, [rbx+rbx*2]
    shl r15, 2                  ; rbx * 12 (epoll_event is packed)
    lea r14, [r12+WS_EVBUF]
    mov edx, [r14+r15]          ; event bits
    mov rsi, [r14+r15+4]        ; data: 0 = listener, else ctx
    test rsi, rsi
    jz .accept
    mov rdi, r12
    call conn_event
    jmp .next
.accept:
    mov rdi, [r12+WS_LFD]
    xor esi, esi
    xor edx, edx
    mov r10d, SOCK_NONBLOCK | SOCK_CLOEXEC
    mov eax, SYS_accept4
    syscall
    test rax, rax
    js .next                    ; EAGAIN: drained the backlog
    mov r15, rax                ; cfd
    mov rdi, r12
    call conn_get
    test rax, rax
    jz .reject
    mov [rax+CTX_FD], r15d
    mov qword [rax+CTX_IN_USED], 0
    mov qword [rax+CTX_OUT_LEN], 0
    mov qword [rax+CTX_OUT_SENT], 0
    mov qword [rax+CTX_OUT_START], 0
    mov byte [rax+CTX_KEEP], 1
    mov byte [rax+CTX_ARMED], 0
    mov byte [rax+CTX_GZIP], 0
    mov dword [rax+CTX_NREQ], 0
    sub rsp, 16
    mov dword [rsp], EPOLLIN
    mov [rsp+4], rax
    mov rdi, [r12+WS_EP]
    mov esi, EPOLL_CTL_ADD
    mov rdx, r15
    mov r10, rsp
    mov eax, SYS_epoll_ctl
    syscall
    add rsp, 16
    jmp .accept
.reject:                        ; out of memory for a ctx: shed load
    mov rdi, r15
    mov eax, SYS_close
    syscall
    jmp .accept
.next:
    inc rbx
    jmp .evloop

.fatal:
    mov edi, STDERR
    mov rsi, msg_wfatal
    mov edx, msg_wfatal_len
    mov eax, SYS_write
    syscall
    mov edi, 1
    mov eax, SYS_exit_group
    syscall

; conn_get(ws) -> ctx from the freelist, or a fresh mmap; 0 on failure.
conn_get:
    mov rax, [rdi+WS_FREE]
    test rax, rax
    jz .alloc
    mov rcx, [rax+CTX_NEXT]
    mov [rdi+WS_FREE], rcx
    ret
.alloc:
    xor edi, edi
    mov esi, CTX_TOTAL
    mov edx, PROT_READ | PROT_WRITE
    mov r10d, MAP_PRIVATE | MAP_ANONYMOUS
    mov r8, -1
    xor r9d, r9d
    mov eax, SYS_mmap
    syscall
    cmp rax, -4095
    jae .fail
    ret
.fail:
    xor eax, eax
    ret

; conn_put(ws, ctx) — recycle onto the freelist.
conn_put:
    mov rax, [rdi+WS_FREE]
    mov [rsi+CTX_NEXT], rax
    mov [rdi+WS_FREE], rsi
    ret

; conn_close(ws, ctx) — close(fd) drops the epoll registration too.
conn_close:
    push rdi
    push rsi
    mov edi, [rsi+CTX_FD]
    mov eax, SYS_close
    syscall
    pop rsi
    pop rdi
    jmp conn_put

; conn_event(ws, ctx, bits)
conn_event:
    push r12
    push r13
    mov r12, rdi
    mov r13, rsi
    test edx, EPOLLERR | EPOLLHUP
    jnz .close
    test edx, EPOLLOUT
    jz .chk_in
    mov rdi, r12
    mov rsi, r13
    call conn_flush
    cmp rax, 1
    jne .out                    ; closed, or output still pending
    jmp .read                   ; drained: process buffered/new input
.chk_in:
    test edx, EPOLLIN
    jz .out
.read:
    mov rdi, r12
    mov rsi, r13
    call conn_read
.out:
    pop r13
    pop r12
    ret
.close:
    mov rdi, r12
    mov rsi, r13
    call conn_close
    jmp .out

; conn_read(ws, ctx) — read to EAGAIN, then answer every complete
; request (head + declared body) sitting in the buffer.
conn_read:
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi
    mov r13, rsi
.rd:
    mov rdx, CTX_INBUF_SZ
    sub rdx, [r13+CTX_IN_USED]
    jz .parse                   ; buffer full: try to parse what we have
    mov edi, [r13+CTX_FD]
    lea rsi, [r13+CTX_IN]
    add rsi, [r13+CTX_IN_USED]
    xor eax, eax                ; SYS_read
    syscall
    cmp rax, 0
    je .close                   ; orderly shutdown from peer
    jl .rderr
    add [r13+CTX_IN_USED], rax
    jmp .rd
.rderr:
    cmp rax, -EAGAIN
    je .parse
    cmp rax, -EINTR
    je .rd
    jmp .close
.parse:
    lea rdi, [r13+CTX_IN]
    mov rsi, [r13+CTX_IN_USED]
    cmp rsi, HTTP_HEAD_MAX      ; the head must fit in the first 8 KiB
    jbe .headlen_ok
    mov esi, HTTP_HEAD_MAX
.headlen_ok:
    call find_crlf2
    test rax, rax
    jz .norequest
    mov r14, rax                ; head length
    mov rdi, r13
    mov rsi, rax
    call http_body_len          ; Content-Length value (0 none, -1 bad)
    cmp rax, -1
    je .badreq
    cmp rax, HTTP_BODY_MAX
    ja .badreq
    mov r15, rax                ; body length
    lea rax, [r14+r15]
    cmp rax, CTX_INBUF_SZ
    ja .badreq
    cmp rax, [r13+CTX_IN_USED]
    ja .done                    ; body still arriving: wait for more
    mov rdi, r13
    mov rsi, r14
    mov rdx, r15
    call http_handle            ; builds the response, sets keep
    add r14, r15                ; consume head + body
    mov rdx, [r13+CTX_IN_USED]
    sub rdx, r14
    mov [r13+CTX_IN_USED], rdx
    jz .flush
    lea rdi, [r13+CTX_IN]       ; slide pipelined leftovers to the front
    lea rsi, [r13+CTX_IN]       ; (dst < src: forward copy is safe)
    add rsi, r14
    call mem_copy
.flush:
    mov rdi, r12
    mov rsi, r13
    call conn_flush
    cmp rax, 1
    jne .done                   ; closed or pending: stop here
    jmp .parse                  ; sent and keeping alive: next request?
.norequest:
    cmp qword [r13+CTX_IN_USED], HTTP_HEAD_MAX
    jb .done                    ; incomplete: wait for more bytes
.badreq:
    mov byte [r13+CTX_KEEP], 0  ; oversized/malformed: reject and close
    mov rdi, r13
    mov esi, 4                  ; page 4 = 400
    call build_page
    mov rdi, r12
    mov rsi, r13
    call conn_flush
.done:
    pop r15
    pop r14
    pop r13
    pop r12
    ret
.close:
    mov rdi, r12
    mov rsi, r13
    call conn_close
    jmp .done

; conn_flush(ws, ctx) -> 0 closed | 1 fully sent, keep-alive | 2 pending
conn_flush:
    push r12
    push r13
    mov r12, rdi
    mov r13, rsi
.snd:
    mov rdx, [r13+CTX_OUT_LEN]
    sub rdx, [r13+CTX_OUT_SENT]
    jz .drained
    mov edi, [r13+CTX_FD]
    lea rsi, [r13+CTX_OUT]
    add rsi, [r13+CTX_OUT_START]
    add rsi, [r13+CTX_OUT_SENT]
    mov r10d, MSG_NOSIGNAL
    xor r8d, r8d
    xor r9d, r9d
    mov eax, SYS_sendto
    syscall
    cmp rax, 0
    jle .blocked
    add [r13+CTX_OUT_SENT], rax
    jmp .snd
.blocked:
    cmp rax, -EAGAIN
    je .arm
    cmp rax, -EINTR
    je .snd
    mov rdi, r12                ; peer is gone
    mov rsi, r13
    call conn_close
    xor eax, eax
    jmp .ret
.arm:
    cmp byte [r13+CTX_ARMED], 1
    je .pending
    mov byte [r13+CTX_ARMED], 1
    sub rsp, 16
    mov dword [rsp], EPOLLIN | EPOLLOUT
    mov [rsp+4], r13
    mov rdi, [r12+WS_EP]
    mov esi, EPOLL_CTL_MOD
    mov edx, [r13+CTX_FD]
    mov r10, rsp
    mov eax, SYS_epoll_ctl
    syscall
    add rsp, 16
.pending:
    mov eax, 2
    jmp .ret
.drained:
    mov qword [r13+CTX_OUT_LEN], 0
    mov qword [r13+CTX_OUT_SENT], 0
    mov qword [r13+CTX_OUT_START], 0
    cmp byte [r13+CTX_KEEP], 0
    jne .keep
    mov rdi, r12
    mov rsi, r13
    call conn_close
    xor eax, eax
    jmp .ret
.keep:
    cmp byte [r13+CTX_ARMED], 0
    je .kept
    mov byte [r13+CTX_ARMED], 0
    sub rsp, 16
    mov dword [rsp], EPOLLIN
    mov [rsp+4], r13
    mov rdi, [r12+WS_EP]
    mov esi, EPOLL_CTL_MOD
    mov edx, [r13+CTX_FD]
    mov r10, rsp
    mov eax, SYS_epoll_ctl
    syscall
    add rsp, 16
.kept:
    mov eax, 1
.ret:
    pop r13
    pop r12
    ret

; find_crlf2(buf, len) -> offset just past the first CRLFCRLF, or 0.
find_crlf2:
    cmp rsi, 4
    jb .no
    sub rsi, 4                  ; last valid start offset
    xor eax, eax
.scan:
    cmp rax, rsi
    ja .no
    cmp dword [rdi+rax], 0x0A0D0A0D
    je .hit
    inc rax
    jmp .scan
.hit:
    add rax, 4
    ret
.no:
    xor eax, eax
    ret

section .data
one_dw: dd 1
msg_wfatal: db 'blogd: worker fatal: socket/bind/listen/epoll failed', 10
msg_wfatal_len equ $-msg_wfatal

section .bss
workers_ready: resq 1

section .note.GNU-stack noalloc noexec nowrite progbits
