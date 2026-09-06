; net.asm — per-worker event loop: SO_REUSEPORT listener + epoll,
; nonblocking connections with keep-alive.
;
; Every worker owns its own listening socket (the kernel load-balances
; via SO_REUSEPORT) and its own epoll instance, so there is no shared
; accept lock and no cross-thread state at all in this file: connection
; contexts live and die within one worker.
;
; epoll data field: 0 = the listener, 1 = the idle-sweep timer,
; otherwise a ctx pointer. Level-triggered; reads and writes always run
; to EAGAIN.
;
; Idle connections: every context carries the time of its last event
; and sits on the worker's active list. A periodic timerfd wakes the
; loop every IDLE_TICK seconds to close anything quiet for longer than
; idle_secs (BLOGD_IDLE_SECS, default 20) — a half-sent request head, a
; keep-alive nobody reuses, a peer that stopped reading. Without it a
; client could pin a 650 KB context for ever by never finishing.

BITS 64
%include "src/sys.inc"
%include "src/conn.inc"

extern mem_copy
extern u64_to_dec
extern http_handle
extern http_body_len
extern http_expects_continue
extern build_page
extern listen_addr
extern idle_secs

global worker_main
global workers_ready

; worker state block (one private mmap per worker):
%define WS_LFD    0
%define WS_EP     8
%define WS_FREE   16            ; ctx freelist head
%define WS_ACTIVE 32            ; live ctx list head (CTX_LPREV/LNEXT)
%define WS_TFD    40            ; idle-sweep timerfd
%define WS_NOW    48            ; seconds, refreshed per epoll wakeup
%define WS_EVBUF  64            ; 64 epoll_events x 12 bytes
%define WS_TOTAL  4096
%define MAX_EVENTS 64
%define IDLE_TICK 5             ; sweep period, seconds

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
    jae .f_mmap
    mov r12, rax                ; r12 = ws for the rest of the loop

    ; nonblocking listener with SO_REUSEPORT
    mov edi, AF_INET
    mov esi, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC
    xor edx, edx
    mov eax, SYS_socket
    syscall
    test rax, rax
    js .f_socket
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
    js .f_bind
    mov rdi, [r12+WS_LFD]
    mov esi, 512
    mov eax, SYS_listen
    syscall
    test rax, rax
    js .f_listen

    xor edi, edi
    mov eax, SYS_epoll_create1
    syscall
    test rax, rax
    js .f_epoll
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
    js .f_epctl

    ; the idle sweep: a periodic timerfd registered with data = 1
    mov edi, CLOCK_MONOTONIC
    mov esi, TFD_NONBLOCK | TFD_CLOEXEC
    mov eax, SYS_timerfd_create
    syscall
    test rax, rax
    js .f_timer
    mov [r12+WS_TFD], rax
    sub rsp, 32                 ; struct itimerspec { interval; value }
    mov qword [rsp], IDLE_TICK
    mov qword [rsp+8], 0
    mov qword [rsp+16], IDLE_TICK
    mov qword [rsp+24], 0
    mov rdi, rax
    xor esi, esi
    mov rdx, rsp
    xor r10d, r10d
    mov eax, SYS_timerfd_settime
    syscall
    add rsp, 32
    test rax, rax
    js .f_timer
    sub rsp, 16
    mov dword [rsp], EPOLLIN
    mov qword [rsp+4], 1
    mov rdi, [r12+WS_EP]
    mov esi, EPOLL_CTL_ADD
    mov rdx, [r12+WS_TFD]
    mov r10, rsp
    mov eax, SYS_epoll_ctl
    syscall
    add rsp, 16
    test rax, rax
    js .f_epctl

    ; signal setup complete: main waits for all workers before it
    ; installs the seccomp filter (whose allowlist excludes the
    ; socket/bind/listen/epoll_create1/timerfd syscalls used only up
    ; to here).
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
    xor edi, edi
    mov eax, SYS_time           ; one clock read per wakeup stamps
    syscall                     ; every connection touched in this batch
    mov [r12+WS_NOW], rax
    xor ebx, ebx                ; index
.evloop:
    cmp rbx, r13
    jae .loop
    lea r15, [rbx+rbx*2]
    shl r15, 2                  ; rbx * 12 (epoll_event is packed)
    lea r14, [r12+WS_EVBUF]
    mov edx, [r14+r15]          ; event bits
    mov rsi, [r14+r15+4]        ; data: 0 = listener, 1 = timer, else ctx
    test rsi, rsi
    jz .accept
    cmp rsi, 1
    je .tick
    mov rdi, r12
    call conn_event
    jmp .next
.tick:
    mov rdi, r12
    call conn_sweep
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
    mov byte [rax+CTX_CONT], 0
    mov dword [rax+CTX_NREQ], 0
    mov rcx, [r12+WS_NOW]       ; onto the active list, stamped now
    mov [rax+CTX_LAST], rcx
    mov qword [rax+CTX_LPREV], 0
    mov rcx, [r12+WS_ACTIVE]
    mov [rax+CTX_LNEXT], rcx
    test rcx, rcx
    jz .linked
    mov [rcx+CTX_LPREV], rax
.linked:
    mov [r12+WS_ACTIVE], rax
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

; setup failures: say which step and which errno, since "bind" with
; EADDRINUSE (another process on the port) is by far the common case
.f_mmap:
    mov r14, wf_mmap
    mov r15d, wf_mmap_len
    jmp .fatal
.f_socket:
    mov r14, wf_socket
    mov r15d, wf_socket_len
    jmp .fatal
.f_bind:
    mov r14, wf_bind
    mov r15d, wf_bind_len
    jmp .fatal
.f_listen:
    mov r14, wf_listen
    mov r15d, wf_listen_len
    jmp .fatal
.f_epoll:
    mov r14, wf_epoll
    mov r15d, wf_epoll_len
    jmp .fatal
.f_epctl:
    mov r14, wf_epctl
    mov r15d, wf_epctl_len
    jmp .fatal
.f_timer:
    mov r14, wf_timer
    mov r15d, wf_timer_len
.fatal:                         ; rax = -errno
    neg rax
    mov rbx, rax
    sub rsp, 192
    mov rdi, rsp
    mov rsi, wf_1
    mov edx, wf_1_len
    call mem_copy
    mov rdi, rax
    mov rsi, r14
    mov rdx, r15
    call mem_copy
    mov rdi, rax
    mov rsi, wf_2
    mov edx, wf_2_len
    call mem_copy
    mov rdi, rbx
    mov rsi, rax
    call u64_to_dec
    mov byte [rax], ')'
    inc rax
    cmp rbx, 98                 ; EADDRINUSE
    jne .f_nohint
    mov rdi, rax
    mov rsi, wf_inuse
    mov edx, wf_inuse_len
    call mem_copy
.f_nohint:
    mov byte [rax], 10
    inc rax
    mov rdx, rax
    sub rdx, rsp
    mov edi, STDERR
    mov rsi, rsp
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
; The context leaves the active list and gives its buffer pages back
; to the kernel: a recycled context otherwise keeps every page it ever
; touched (up to the full 650 KB) resident for the life of the worker.
conn_close:
    push rdi
    push rsi
    mov rax, [rsi+CTX_LPREV]
    mov rcx, [rsi+CTX_LNEXT]
    test rax, rax
    jz .head
    mov [rax+CTX_LNEXT], rcx
    jmp .fix_next
.head:
    mov [rdi+WS_ACTIVE], rcx
.fix_next:
    test rcx, rcx
    jz .unlinked
    mov [rcx+CTX_LPREV], rax
.unlinked:
    mov edi, [rsi+CTX_FD]
    mov eax, SYS_close
    syscall
    mov rdi, [rsp]              ; ctx: drop everything past the first
    add rdi, 4096               ; page (the header and freelist link)
    mov esi, CTX_TOTAL - 4096
    mov edx, MADV_DONTNEED
    mov eax, SYS_madvise
    syscall
    pop rsi
    pop rdi
    jmp conn_put

; conn_sweep(ws) — timer tick: close every connection whose last event
; is older than idle_secs (0 disables the sweep).
conn_sweep:
    push r12
    push r13
    push r14
    mov r12, rdi
    sub rsp, 8
    mov edi, [r12+WS_TFD]       ; drain the expiration count
    mov rsi, rsp
    mov edx, 8
    xor eax, eax                ; SYS_read
    syscall
    add rsp, 8
    mov r14, [idle_secs]
    test r14, r14
    jz .done
    neg r14
    add r14, [r12+WS_NOW]       ; cutoff: quiet since before this -> gone
    mov r13, [r12+WS_ACTIVE]
.walk:
    test r13, r13
    jz .done
    mov rax, [r13+CTX_LNEXT]    ; read before a close unlinks it
    cmp [r13+CTX_LAST], r14     ; whole-second stamps: a gap of exactly
    jae .keep                   ; idle_secs may be under a second short
    push rax
    mov rdi, r12
    mov rsi, r13
    call conn_close
    pop rax
.keep:
    mov r13, rax
    jmp .walk
.done:
    pop r14
    pop r13
    pop r12
    ret

; conn_event(ws, ctx, bits)
conn_event:
    push r12
    push r13
    mov r12, rdi
    mov r13, rsi
    mov rax, [r12+WS_NOW]
    mov [r13+CTX_LAST], rax
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
    call http_body_len          ; Content-Length (0 none, -1 bad, -2 chunked)
    cmp rax, -1
    je .badreq
    cmp rax, -2
    je .lenreq
    cmp rax, HTTP_BODY_MAX
    ja .toolarge
    mov r15, rax                ; body length
    lea rax, [r14+r15]
    cmp rax, CTX_INBUF_SZ
    ja .toolarge
    cmp rax, [r13+CTX_IN_USED]
    ja .wait_body               ; body still arriving: wait for more
    mov byte [r13+CTX_CONT], 0
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
.wait_body:
    ; "Expect: 100-continue": the client is holding the body back until
    ; we say so (curl does, for anything over 1 KB, and otherwise gives
    ; up waiting after a second). Answer once, only when the output
    ; buffer is idle, then wait for the body as usual.
    cmp byte [r13+CTX_CONT], 0
    jne .done
    cmp qword [r13+CTX_OUT_LEN], 0
    jne .done
    mov [r13+CTX_HLEN], r14
    mov rdi, r13
    call http_expects_continue
    test eax, eax
    jz .done
    mov byte [r13+CTX_CONT], 1
    lea rdi, [r13+CTX_OUT]
    mov rsi, s_100
    mov edx, s_100_len
    call mem_copy
    mov qword [r13+CTX_OUT_START], 0
    mov qword [r13+CTX_OUT_LEN], s_100_len
    mov qword [r13+CTX_OUT_SENT], 0
    mov rdi, r12
    mov rsi, r13
    call conn_flush
    jmp .done
.norequest:
    cmp qword [r13+CTX_IN_USED], HTTP_HEAD_MAX
    jb .done                    ; incomplete: wait for more bytes
    mov esi, 7                  ; head never ended within 8 KiB: 431
    jmp .reject
.lenreq:
    mov esi, 8                  ; Transfer-Encoding: 411
    jmp .reject
.toolarge:
    mov esi, 6                  ; body over the cap: 413
    jmp .reject
.badreq:
    mov esi, 4                  ; malformed: 400
.reject:
    mov byte [r13+CTX_KEEP], 0  ; every rejection closes the connection
    mov rdi, r13
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
s_100: db 'HTTP/1.1 100 Continue', 13, 10, 13, 10
s_100_len equ $-s_100
wf_1: db 'blogd: worker fatal: '
wf_1_len equ $-wf_1
wf_2: db ' failed (errno '
wf_2_len equ $-wf_2
wf_inuse: db ': the port is already in use by another process'
wf_inuse_len equ $-wf_inuse
wf_mmap: db 'mmap'
wf_mmap_len equ $-wf_mmap
wf_socket: db 'socket'
wf_socket_len equ $-wf_socket
wf_bind: db 'bind'
wf_bind_len equ $-wf_bind
wf_listen: db 'listen'
wf_listen_len equ $-wf_listen
wf_epoll: db 'epoll_create1'
wf_epoll_len equ $-wf_epoll
wf_epctl: db 'epoll_ctl'
wf_epctl_len equ $-wf_epctl
wf_timer: db 'timerfd'
wf_timer_len equ $-wf_timer

section .bss
workers_ready: resq 1

section .note.GNU-stack noalloc noexec nowrite progbits
