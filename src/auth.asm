; auth.asm — server-side sessions, CSRF tokens, login rate limiting.
;
; Sessions are a fixed table of 16 slots (one admin; 16 concurrent
; browsers is plenty). Tokens are 32 random bytes from getrandom(2),
; stored and compared as 64 lowercase hex chars. Creating a session
; evicts the expired-or-oldest slot. All access is under a futex lock.
;
; Rate limiting is global (single-admin blog, and Argon2id verification
; is already serialized through the main thread): each failed login
; pushes the next allowed attempt out quadratically, capped at 5 min.

BITS 64
%include "src/sys.inc"

extern wr_lock
extern wr_unlock
extern mem_copy
extern mem_eq
extern set_ttl

global session_create
global session_find
global session_csrf
global session_csrf_ok
global session_destroy
global login_allowed
global login_failed
global login_ok

%define SESS_N   16
%define SE_SID   0              ; 64 hex chars
%define SE_CSRF  64             ; 64 hex chars
%define SE_EXP   128            ; qword expiry (unix secs; 0 = free)
%define SE_SIZE  144

section .text

now_secs:
    xor edi, edi
    mov eax, SYS_time
    syscall
    ret

; rand_hex(dst, nbytes) — nbytes of getrandom, written as 2n hex chars
rand_hex:
    push r12
    push r13
    push r14
    mov r12, rdi
    mov r13, rsi
    sub rsp, 64
    mov rdi, rsp
    mov rsi, r13
    xor edx, edx
    mov eax, SYS_getrandom
    syscall
    xor r14d, r14d
.enc:
    cmp r14, r13
    jae .done
    movzx eax, byte [rsp+r14]
    mov ecx, eax
    shr eax, 4
    and ecx, 15
    mov al, [hexdig+rax]
    mov cl, [hexdig+rcx]
    mov [r12+r14*2], al
    mov [r12+r14*2+1], cl
    inc r14
    jmp .enc
.done:
    add rsp, 64
    pop r14
    pop r13
    pop r12
    ret

; session_create(sid_out64, csrf_out64)
session_create:
    push r12
    push r13
    push r14
    push r15
    push rbx
    mov r12, rdi
    mov r13, rsi
    mov rdi, sess_lock
    call wr_lock
    call now_secs
    mov r14, rax                ; now
    ; pick a slot: first expired, else the one expiring soonest
    xor ebx, ebx                ; best index
    mov rdx, -1                 ; best expiry seen
    xor ecx, ecx
.scan:
    cmp rcx, SESS_N
    jae .picked
    imul rax, rcx, SE_SIZE
    mov rsi, [sessions+rax+SE_EXP]
    cmp rsi, r14
    jb .take                    ; expired (or free): take it now
    cmp rsi, rdx
    jae .next
    mov rdx, rsi
    mov rbx, rcx
.next:
    inc rcx
    jmp .scan
.take:
    mov rbx, rcx
.picked:
    imul r15, rbx, SE_SIZE
    lea r15, [sessions+r15]     ; entry
    lea rdi, [r15+SE_SID]
    mov esi, 32
    call rand_hex
    lea rdi, [r15+SE_CSRF]
    mov esi, 32
    call rand_hex
    mov eax, [set_ttl]
    add rax, r14
    mov [r15+SE_EXP], rax
    mov rdi, r12
    lea rsi, [r15+SE_SID]
    mov edx, 64
    call mem_copy
    mov rdi, r13
    lea rsi, [r15+SE_CSRF]
    mov edx, 64
    call mem_copy
    mov rdi, sess_lock
    call wr_unlock
    xor eax, eax
    pop rbx
    pop r15
    pop r14
    pop r13
    pop r12
    ret

; session_find(sid_p, sid_l) -> slot index or -1; extends expiry on hit
session_find:
    push r12
    push r13
    push r14
    push rbx
    cmp rsi, 64
    jne .no_nolock
    mov r12, rdi
    mov rdi, sess_lock
    call wr_lock
    call now_secs
    mov r14, rax
    xor ebx, ebx
.scan:
    cmp rbx, SESS_N
    jae .no
    imul r13, rbx, SE_SIZE
    lea r13, [sessions+r13]
    cmp [r13+SE_EXP], r14
    jb .next
    mov rdi, r13
    mov rsi, r12
    mov edx, 64
    call mem_eq
    test eax, eax
    jnz .hit
.next:
    inc rbx
    jmp .scan
.hit:
    mov eax, [set_ttl]
    add rax, r14
    mov [r13+SE_EXP], rax
    mov rdi, sess_lock
    call wr_unlock
    mov rax, rbx
    jmp .ret
.no:
    mov rdi, sess_lock
    call wr_unlock
.no_nolock:
    mov rax, -1
.ret:
    pop rbx
    pop r14
    pop r13
    pop r12
    ret

; session_csrf(idx) -> pointer to the 64-char CSRF token (static storage)
session_csrf:
    imul rax, rdi, SE_SIZE
    lea rax, [sessions+rax+SE_CSRF]
    ret

; session_csrf_ok(idx, tok_p, tok_l) -> 1/0
session_csrf_ok:
    cmp rdx, 64
    jne .no
    imul rax, rdi, SE_SIZE
    lea rdi, [sessions+rax+SE_CSRF]
    mov rdx, 64
    call mem_eq
    ret
.no:
    xor eax, eax
    ret

; session_destroy(idx)
session_destroy:
    push r12
    mov r12, rdi
    mov rdi, sess_lock
    call wr_lock
    imul r12, r12, SE_SIZE
    mov qword [sessions+r12+SE_EXP], 0
    mov rdi, sess_lock
    call wr_unlock
    pop r12
    ret

; login_allowed() -> 1/0
login_allowed:
    call now_secs
    cmp rax, [login_next]
    jae .yes
    xor eax, eax
    ret
.yes:
    mov eax, 1
    ret

; login_failed() — quadratic backoff, capped at 300s
login_failed:
    push r12
    mov rdi, sess_lock
    call wr_lock
    call now_secs
    mov r12, rax
    inc dword [login_fails]
    mov eax, [login_fails]
    imul eax, eax
    cmp eax, 300
    jbe .cap_ok
    mov eax, 300
.cap_ok:
    add r12, rax
    mov [login_next], r12
    mov rdi, sess_lock
    call wr_unlock
    pop r12
    ret

; login_ok()
login_ok:
    mov dword [login_fails], 0
    mov qword [login_next], 0
    ret

section .data
hexdig: db '0123456789abcdef'

section .bss
sessions:    resb SESS_N*SE_SIZE
sess_lock:   resd 1
login_fails: resd 1
login_next:  resq 1

section .note.GNU-stack noalloc noexec nowrite progbits
