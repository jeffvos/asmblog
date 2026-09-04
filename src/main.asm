; main.asm — entry point: CLI, worker spawn.
;
; Usage: blogd [port] [threads]
;   port    default 8080, always binds 127.0.0.1 (TLS/the outside world
;           are the reverse proxy's job)
;   threads default = CPU count (clamped 1..16)
;
; The main thread becomes worker 0; the rest are clone()d. Workers each
; open their own SO_REUSEPORT listener, so there is nothing to join.

BITS 64
%include "src/sys.inc"

extern parse_u64
extern mem_copy
extern u64_to_dec
extern cstr_eq
extern cpu_count
extern thread_spawn
extern worker_main
extern store_open
extern init_main
extern selftest_main
extern seed_main
extern tmpl_load_all
extern load_static
extern crypto_init
extern crypto_service
extern seccomp_install
extern workers_ready

global _start
global listen_addr

section .text

_start:
    mov rbp, [rsp]              ; argc
    lea rbx, [rsp+8]            ; argv
    lea rax, [rbx+rbp*8+8]      ; envp = argv + (argc+1)*8
    mov [envp], rax
    mov r15, 8080               ; port
    cmp rbp, 2
    jl .port_done
    mov rdi, [rbx+8]            ; subcommands first: init | selftest
    mov rsi, cmd_init
    mov edx, 4
    call cstr_eq
    test eax, eax
    jz .not_init
    call init_main              ; exits
.not_init:
    mov rdi, [rbx+8]
    mov rsi, cmd_selftest
    mov edx, 8
    call cstr_eq
    test eax, eax
    jz .not_selftest
    call selftest_main          ; exits
.not_selftest:
    mov rdi, [rbx+8]
    mov rsi, cmd_seed
    mov edx, 4
    call cstr_eq
    test eax, eax
    jz .not_seed
    call seed_main              ; exits
.not_seed:
    mov rdi, [rbx+8]
    call parse_u64
    test rax, rax
    jle .badarg
    cmp rax, 65535
    ja .badarg
    mov r15, rax
.port_done:
    xor r14d, r14d              ; threads (0 = auto)
    cmp rbp, 3
    jl .threads_auto
    mov rdi, [rbx+16]
    call parse_u64
    test rax, rax
    jle .badarg
    cmp rax, 16
    ja .badarg
    mov r14, rax
    jmp .threads_done
.threads_auto:
    call cpu_count
    mov r14, rax
.threads_done:

    call store_open             ; load posts + settings before serving
    test rax, rax
    jnz .storefail
    call tmpl_load_all          ; templates and CSS load once, pre-fork
    test rax, rax
    jnz .tmplfail
    call load_static
    test rax, rax
    jnz .cssfail
    call crypto_init            ; libsodium, initial thread only
    test rax, rax
    js .sodiumfail

    ; struct sockaddr_in { u16 family; u16 port(be); u32 addr(be); u8 pad[8]; }
    mov word [listen_addr], AF_INET
    mov rax, r15
    xchg al, ah                 ; htons
    mov [listen_addr+2], ax
    mov dword [listen_addr+4], 0x0100007F   ; 127.0.0.1
    mov qword [listen_addr+8], 0

    ; "blogd 0.6 listening on http://127.0.0.1:P (threads: N)\n"
    mov rdi, banner_buf
    mov rsi, msg_listen
    mov edx, msg_listen_len
    call mem_copy
    mov rdi, r15
    mov rsi, rax
    call u64_to_dec
    mov rdi, rax
    mov rsi, msg_thr
    mov edx, msg_thr_len
    call mem_copy
    mov rdi, r14
    mov rsi, rax
    call u64_to_dec
    mov word [rax], 0x0A29      ; ")\n"
    add rax, 2
    mov rdx, rax
    sub rdx, banner_buf
    mov edi, STDOUT
    mov rsi, banner_buf
    mov eax, SYS_write
    syscall

    mov rbx, r14                ; spawn every worker; the initial thread
.spawn:                         ; parks as the Argon2id crypto service
    test rbx, rbx               ; (workers have no TLS and must never
    jz .sandbox                 ; call into libsodium/libc themselves)
    mov rdi, worker_main
    xor esi, esi
    call thread_spawn
    dec rbx
    jmp .spawn
.sandbox:
    ; wait until every worker has finished its socket/epoll setup, so the
    ; TSYNC filter never lands on a thread still mid-startup
.waitready:
    mov rax, [workers_ready]
    cmp rax, r14
    jae .ready
    pause
    jmp .waitready
.ready:
    mov rdi, env_nosec          ; BLOGD_NO_SECCOMP escape hatch
    call getenv_present
    test eax, eax
    jnz .service
    call seccomp_install        ; TSYNC: covers every worker too
    test rax, rax
    jns .service
    mov edi, STDERR
    mov rsi, msg_seccomp
    mov edx, msg_seccomp_len
    mov eax, SYS_write
    syscall
    mov edi, 1
    mov eax, SYS_exit_group
    syscall
.service:
    call crypto_service         ; never returns

.badarg:
    mov edi, STDERR
    mov rsi, msg_usage
    mov edx, msg_usage_len
    mov eax, SYS_write
    syscall
    mov edi, 1
    mov eax, SYS_exit_group
    syscall
.storefail:
    mov edi, STDERR
    mov rsi, msg_store
    mov edx, msg_store_len
    mov eax, SYS_write
    syscall
    mov edi, 1
    mov eax, SYS_exit_group
    syscall
.tmplfail:
    mov edi, STDERR
    mov rsi, msg_tmpl
    mov edx, msg_tmpl_len
    mov eax, SYS_write
    syscall
    mov edi, 1
    mov eax, SYS_exit_group
    syscall
.cssfail:
    mov edi, STDERR
    mov rsi, msg_css
    mov edx, msg_css_len
    mov eax, SYS_write
    syscall
    mov edi, 1
    mov eax, SYS_exit_group
    syscall
.sodiumfail:
    mov edi, STDERR
    mov rsi, msg_sodium
    mov edx, msg_sodium_len
    mov eax, SYS_write
    syscall
    mov edi, 1
    mov eax, SYS_exit_group
    syscall

; getenv_present(name_cstr) -> 1 if NAME= appears in envp, else 0
getenv_present:
    mov r9, [envp]
.next:
    mov r8, [r9]
    test r8, r8
    jz .no
    mov rsi, rdi                ; compare name prefix up to '='
    mov rcx, r8
.cmp:
    mov al, [rsi]
    test al, al
    jz .checkeq
    cmp al, [rcx]
    jne .adv
    inc rsi
    inc rcx
    jmp .cmp
.checkeq:
    cmp byte [rcx], '='
    je .yes
.adv:
    add r9, 8
    jmp .next
.yes:
    mov eax, 1
    ret
.no:
    xor eax, eax
    ret

section .data

msg_listen: db 'blogd 0.6 listening on http://127.0.0.1:'
msg_listen_len equ $-msg_listen
msg_thr: db ' (threads: '
msg_thr_len equ $-msg_thr
msg_usage: db 'usage: blogd [init|selftest] | blogd [port 1-65535] [threads 1-16]', 10
msg_usage_len equ $-msg_usage
msg_store: db 'blogd: cannot open data/store.blg', 10
msg_store_len equ $-msg_store
msg_tmpl: db 'blogd: cannot load templates/ (run from the repo root)', 10
msg_tmpl_len equ $-msg_tmpl
msg_css: db 'blogd: static/main.css missing (run: make css)', 10
msg_css_len equ $-msg_css
msg_sodium: db 'blogd: libsodium init failed', 10
msg_sodium_len equ $-msg_sodium
msg_seccomp: db 'blogd: seccomp install failed (try BLOGD_NO_SECCOMP=1)', 10
msg_seccomp_len equ $-msg_seccomp
env_nosec: db 'BLOGD_NO_SECCOMP', 0
cmd_init: db 'init'
cmd_selftest: db 'selftest'
cmd_seed: db 'seed'

section .bss

listen_addr: resb 16
banner_buf:  resb 96
envp:        resq 1

section .note.GNU-stack noalloc noexec nowrite progbits
