; crypto.asm — the one libsodium boundary in the codebase.
;
; Everything else is raw syscalls; password hashing is the single job
; where hand-rolling would be a security liability, so Argon2id comes
; from libsodium (see PLAN.md, locked decision).
;
; ABI care: libsodium is C and demands a 16-byte-aligned stack at the
; call, which our internal code does not guarantee — each shim aligns
; explicitly. These may only be called from the initial thread: our
; clone()d workers have no TLS (%fs) set up, and glibc internals
; (errno, malloc tcache) would fault or corrupt.
;
; The mailbox solves that for the server: after spawning workers, the
; main thread parks in crypto_service(). Workers post verify/hash
; requests through a futex-serialized mailbox and sleep until the main
; thread has done the Argon2id work. This also serializes all password
; hashing — a free, structural rate limit on brute force.

BITS 64
%include "src/sys.inc"

extern sodium_init
extern crypto_pwhash_str
extern crypto_pwhash_str_verify
extern wr_lock
extern wr_unlock
extern set_hash

global crypto_init
global crypto_hash_password
global crypto_verify_password
global crypto_service
global crypto_verify_remote
global crypto_hash_remote

; Argon2id, libsodium INTERACTIVE cost: opslimit 2, memlimit 64 MiB
%define OPSLIMIT 2
%define MEMLIMIT 67108864

section .text

; crypto_init() -> >=0 ok, <0 failure. Initial thread only.
crypto_init:
    push rbp
    mov rbp, rsp
    and rsp, -16
    call sodium_init
    movsxd rax, eax
    mov rsp, rbp
    pop rbp
    ret

; crypto_hash_password(pw, pwlen, out128) -> 0 / nonzero. Initial thread only.
crypto_hash_password:
    push rbp
    mov rbp, rsp
    and rsp, -16
    mov rax, rdx                ; crypto_pwhash_str(out, passwd, len, ops, mem)
    mov rdx, rsi
    mov rsi, rdi
    mov rdi, rax
    mov ecx, OPSLIMIT
    mov r8, MEMLIMIT
    call crypto_pwhash_str
    movsxd rax, eax
    mov rsp, rbp
    pop rbp
    ret

; crypto_verify_password(hash128, pw, pwlen) -> 0 match / nonzero.
; Initial thread only.
crypto_verify_password:
    push rbp
    mov rbp, rsp
    and rsp, -16
    call crypto_pwhash_str_verify
    movsxd rax, eax
    mov rsp, rbp
    pop rbp
    ret

; ---- main-thread crypto service + worker-side mailbox ------------------
; State protocol on mb_state: 0 idle, 1 request posted, 2 result ready.
; Requesters serialize on mb_mutex; the service and the active
; requester rendezvous via futex on mb_state.

; crypto_service() — never returns. Run on the initial thread.
crypto_service:
.loop:
    mov eax, [mb_state]
    cmp eax, 1
    je .work
    mov rdi, mb_state
    mov esi, FUTEX_WAIT_PRIVATE
    mov edx, eax
    xor r10d, r10d
    mov eax, SYS_futex
    syscall
    jmp .loop
.work:
    mov eax, [mb_op]
    cmp eax, 2
    je .hash
    mov rdi, set_hash           ; verify against the stored admin hash
    mov rsi, [mb_pw_p]
    mov rdx, [mb_pw_l]
    call crypto_verify_password
    jmp .post
.hash:
    mov rdi, [mb_pw_p]
    mov rsi, [mb_pw_l]
    mov rdx, [mb_out_p]
    call crypto_hash_password
.post:
    mov [mb_result], rax
    mov dword [mb_state], 2
    mov rdi, mb_state
    mov esi, FUTEX_WAKE_PRIVATE
    mov edx, 0x7fffffff
    mov eax, SYS_futex
    syscall
    jmp .loop

; mb_request(op, pw, l, out) -> result. Internal.
mb_request:
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi                ; op
    mov r13, rsi                ; pw
    mov r14, rdx                ; len
    mov r15, rcx                ; out (hash op)
    mov rdi, mb_mutex
    call wr_lock
    mov [mb_op], r12d
    mov [mb_pw_p], r13
    mov [mb_pw_l], r14
    mov [mb_out_p], r15
    mov dword [mb_state], 1
    mov rdi, mb_state
    mov esi, FUTEX_WAKE_PRIVATE
    mov edx, 0x7fffffff
    mov eax, SYS_futex
    syscall
.wait:
    mov eax, [mb_state]
    cmp eax, 2
    je .got
    mov rdi, mb_state
    mov esi, FUTEX_WAIT_PRIVATE
    mov edx, eax
    xor r10d, r10d
    mov eax, SYS_futex
    syscall
    jmp .wait
.got:
    mov r12, [mb_result]
    mov dword [mb_state], 0
    mov rdi, mb_mutex
    call wr_unlock
    mov rax, r12
    pop r15
    pop r14
    pop r13
    pop r12
    ret

; crypto_verify_remote(pw, l) -> 0 match / nonzero (safe from any worker)
crypto_verify_remote:
    mov rdx, rsi
    mov rsi, rdi
    mov edi, 1
    xor ecx, ecx
    jmp mb_request

; crypto_hash_remote(pw, l, out128) -> 0 / nonzero (safe from any worker)
crypto_hash_remote:
    mov rcx, rdx
    mov rdx, rsi
    mov rsi, rdi
    mov edi, 2
    jmp mb_request

section .bss
mb_mutex:  resd 1
mb_state:  resd 1
mb_op:     resd 1
mb_pw_p:   resq 1
mb_pw_l:   resq 1
mb_out_p:  resq 1
mb_result: resq 1

section .note.GNU-stack noalloc noexec nowrite progbits
