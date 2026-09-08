; signal.asm — process signals: graceful stop, template reload, SIGPIPE.
;
; SIGTERM / SIGINT: the handler writes to an eventfd that every worker
; keeps in its epoll set (data = 2, net.asm). A worker that sees it
; closes its listener, stops keeping connections alive, finishes the
; responses already in flight and exits; the last worker out ends the
; process with status 0, so a `systemctl stop` or `docker stop` is a
; clean exit rather than a kill.
;
; SIGHUP: the handler flags a reload and kicks the crypto service
; (crypto.asm) — the initial thread, parked between password checks —
; which re-reads templates/ and static/ (reload.asm) while the workers
; keep serving.
;
; SIGPIPE is ignored: the access log may be a pipe whose reader has
; gone away, and a write there must not take the server down (sockets
; already send with MSG_NOSIGNAL).
;
; Handlers touch async-signal-safe state only: a byte flag, an eventfd
; write, a futex wake. They may run on any thread (CLONE_SIGHAND).

BITS 64
%include "src/sys.inc"

extern crypto_kick

global sig_init
global stop_efd
global stopping
global reload_req

%define SIGHUP      1
%define SIGINT      2
%define SIGPIPE     13
%define SIGTERM     15
%define SIG_IGN     1
%define SA_RESTORER 0x04000000
%define SA_RESTART  0x10000000
%define SYS_rt_sigaction 13
%define SYS_eventfd2     290
%define EFD_NONBLOCK 0x800
%define EFD_CLOEXEC  0x80000

section .text

; sig_init() -> 0 / -errno. Called before the workers are spawned
; (they inherit the dispositions) and before seccomp (rt_sigaction and
; eventfd2 are not in the allowlist; the handler itself needs only
; write, futex and rt_sigreturn, which are).
sig_init:
    xor edi, edi                ; eventfd2(0, NONBLOCK | CLOEXEC)
    mov esi, EFD_NONBLOCK | EFD_CLOEXEC
    mov eax, SYS_eventfd2
    syscall
    test rax, rax
    js .ret
    mov [stop_efd], rax
    ; struct kernel_sigaction { handler; flags; restorer; mask }
    sub rsp, 32
    mov qword [rsp], sig_handler
    mov qword [rsp+8], SA_RESTORER | SA_RESTART
    mov qword [rsp+16], sig_restorer
    mov qword [rsp+24], 0
    mov edi, SIGTERM
    call .install
    test rax, rax
    js .fail
    mov edi, SIGINT
    call .install
    test rax, rax
    js .fail
    mov edi, SIGHUP
    call .install
    test rax, rax
    js .fail
    mov qword [rsp], SIG_IGN
    mov edi, SIGPIPE
    call .install
.fail:
    add rsp, 32
.ret:
    ret
.install:                       ; rdi = signo; the sigaction sits above
    lea rsi, [rsp+8]            ; our return address
    xor edx, edx
    mov r10d, 8                 ; sigsetsize
    mov eax, SYS_rt_sigaction
    syscall
    ret

; sig_handler(signo) — the kernel restores every register afterwards
sig_handler:
    cmp edi, SIGHUP
    je .hup
    mov byte [stopping], 1
    mov edi, [stop_efd]
    mov rsi, one_q
    mov edx, 8
    mov eax, SYS_write
    syscall
    ret
.hup:
    mov byte [reload_req], 1
    jmp crypto_kick             ; its ret lands in sig_restorer

sig_restorer:
    mov eax, 15                 ; rt_sigreturn
    syscall

section .data
one_q: dq 1

section .bss
stop_efd:   resq 1
stopping:   resb 1
reload_req: resb 1

section .note.GNU-stack noalloc noexec nowrite progbits
