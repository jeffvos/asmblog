; seccomp.asm — install a syscall allowlist over the whole process.
;
; The filter is applied with SECCOMP_FILTER_FLAG_TSYNC after all workers
; are spawned, so every thread (workers + the crypto/main thread) runs
; under it. The allowlist is derived empirically by stracing both the
; selftest (which exercises Argon2id end to end) and a live server doing
; requests, logins, and saves — see tools/ strace notes. The default
; action is KILL_PROCESS: anything not listed (execve, ptrace, socket
; creation after startup, module loading, the other ~380 syscalls)
; terminates the process rather than being quietly allowed.
;
; A missing entry would kill the server on the first offending syscall,
; so the allowlist is validated by running the full admin end-to-end
; suite with the sandbox active (tests/smoke.sh).

BITS 64
%include "src/sys.inc"

global seccomp_install

; BPF opcodes
%define BPF_LD_W_ABS  0x20
%define BPF_JEQ_K     0x15
%define BPF_RET_K     0x06
; seccomp_data offsets
%define SD_NR         0
%define SD_ARCH       4

; One BPF instruction: dw code, db jt, db jf, dd k.
; ALLOW jumps forward to the `sc_allow` return; jt counts instructions
; from the one after this to the target: (sc_allow - ($+6)) / 8.
%macro SC_ALLOW 1
    dw BPF_JEQ_K
    db (sc_allow - ($ + 6)) >> 3
    db 0
    dd %1
%endmacro

section .text

; seccomp_install() -> 0 on success, negative errno on failure.
seccomp_install:
    ; prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0)
    mov edi, PR_SET_NO_NEW_PRIVS
    mov esi, 1
    xor edx, edx
    xor r10d, r10d
    xor r8d, r8d
    mov eax, SYS_prctl
    syscall
    test rax, rax
    js .ret
    ; seccomp(SECCOMP_SET_MODE_FILTER, TSYNC, &prog)
    mov edi, SECCOMP_SET_MODE_FILTER
    mov esi, SECCOMP_FILTER_FLAG_TSYNC
    mov rdx, sc_prog
    mov eax, SYS_seccomp
    syscall
.ret:
    ret

section .data

align 8
sc_prog:                            ; struct sock_fprog { u16 len; filter; }
    dw (sc_filter_end - sc_filter) / 8   ; len is an INSTRUCTION count
    dw 0
    dd 0
    dq sc_filter

align 8
sc_filter:
    ; reject any non-x86_64 personality outright
    dw BPF_LD_W_ABS
    db 0, 0
    dd SD_ARCH
    dw BPF_JEQ_K
    db 1, 0
    dd AUDIT_ARCH_X86_64
    dw BPF_RET_K
    db 0, 0
    dd SECCOMP_RET_KILL
    ; load the syscall number
    dw BPF_LD_W_ABS
    db 0, 0
    dd SD_NR

    ; --- allowlist (SYS_* from sys.inc; extras are libsodium/glibc) ---
    SC_ALLOW SYS_read
    SC_ALLOW SYS_write
    SC_ALLOW SYS_open
    SC_ALLOW SYS_close
    SC_ALLOW SYS_fstat
    SC_ALLOW SYS_lseek
    SC_ALLOW SYS_mmap
    SC_ALLOW SYS_mprotect
    SC_ALLOW SYS_munmap
    SC_ALLOW 12                 ; brk
    SC_ALLOW 14                 ; rt_sigprocmask
    SC_ALLOW 15                 ; rt_sigreturn
    SC_ALLOW 17                 ; pread64
    SC_ALLOW 21                 ; access
    SC_ALLOW 28                 ; madvise (libsodium sodium_malloc)
    SC_ALLOW 149                ; mlock   (libsodium secure memory)
    SC_ALLOW 150                ; munlock
    SC_ALLOW SYS_sendto
    SC_ALLOW SYS_fsync
    SC_ALLOW SYS_ftruncate
    SC_ALLOW SYS_rename
    SC_ALLOW SYS_mkdir
    SC_ALLOW SYS_futex
    SC_ALLOW SYS_time
    SC_ALLOW SYS_epoll_wait
    SC_ALLOW SYS_epoll_ctl
    SC_ALLOW SYS_accept4
    SC_ALLOW 257                ; openat
    SC_ALLOW 228                ; clock_gettime
    SC_ALLOW 302                ; prlimit64
    SC_ALLOW SYS_getrandom
    SC_ALLOW SYS_exit
    SC_ALLOW SYS_exit_group

    dw BPF_RET_K                ; default: kill the process
    db 0, 0
    dd SECCOMP_RET_KILL
sc_allow:
    dw BPF_RET_K
    db 0, 0
    dd SECCOMP_RET_ALLOW
sc_filter_end:

section .note.GNU-stack noalloc noexec nowrite progbits
