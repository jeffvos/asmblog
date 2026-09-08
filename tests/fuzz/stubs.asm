; stubs.asm — what the fuzz harnesses link instead of main.asm, net.asm
; and crypto.asm (see harness.c). The globals main.asm owns, and a
; libsodium-free "crypto" that accepts exactly one password, so the
; fuzzer can log in and reach every admin route without Argon2id.

BITS 64
%include "src/sys.inc"

extern mem_eq
extern mem_copy

global envp
global listen_addr
global idle_secs
global getenv_value
global crypto_init
global crypto_kick
global crypto_service
global crypto_hash_password
global crypto_verify_password
global crypto_verify_remote
global crypto_hash_remote

section .text

; getenv_value(name_cstr) -> rax = value ptr (0 if unset), rdx = length
; (a copy of main.asm's)
getenv_value:
    mov r9, [envp]
.next:
    mov r8, [r9]
    test r8, r8
    jz .no
    mov rsi, rdi
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
    jne .adv
    lea rax, [rcx+1]
    xor edx, edx
.len:
    cmp byte [rax+rdx], 0
    je .ret
    inc rdx
    jmp .len
.adv:
    add r9, 8
    jmp .next
.no:
    xor eax, eax
    xor edx, edx
.ret:
    ret

crypto_init:
    xor eax, eax
    ret

crypto_kick:
    ret

crypto_service:                 ; never called by the harness
    jmp crypto_service

; crypto_verify_password(hash128, pw, pwlen) -> 0 when pw is FUZZ_PW
crypto_verify_password:
    mov rdi, rsi
    mov rsi, rdx
; crypto_verify_remote(pw, pwlen) -> 0 match / 1
crypto_verify_remote:
    cmp rsi, fuzz_pw_len
    jne .no
    mov rsi, fuzz_pw
    mov edx, fuzz_pw_len
    call mem_eq                 ; 1 = equal
    xor eax, 1
    ret
.no:
    mov eax, 1
    ret

; crypto_hash_password(pw, pwlen, out128) / crypto_hash_remote(same) -> 0
crypto_hash_password:
crypto_hash_remote:
    mov rdi, rdx
    mov rsi, fuzz_hash
    mov edx, 128
    call mem_copy
    xor eax, eax
    ret

section .data
fuzz_pw: db 'hunter22'
fuzz_pw_len equ $-fuzz_pw
fuzz_hash: db '$argon2id$v=19$m=65536,t=2,p=1$stub-hash-for-the-fuzz-harness$', 0
           times 128-($-fuzz_hash) db 0

section .bss
envp:        resq 1
listen_addr: resb 16
idle_secs:   resq 1

section .note.GNU-stack noalloc noexec nowrite progbits
