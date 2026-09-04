; threads.asm — clone()-based threads, CPU counting, futex rwlock.
;
; Threads share VM/files/signals (CLONE_THREAD); each gets a 1 MiB
; mmap'd stack with a PROT_NONE guard page at the low end, so stack
; overflow faults instead of silently corrupting a neighbour.
;
; The rwlock is a single 32-bit word: 0 free, >0 reader count, -1 writer.
; Readers and writers sleep on the same futex. It is deliberately naive
; (thundering herd on wake); the store in milestone 3 is its first user.

BITS 64
%include "src/sys.inc"

global cpu_count
global thread_spawn
global rwlock_init
global rd_lock
global rd_unlock
global wr_lock
global wr_unlock

%define STACK_TOTAL 0x101000    ; 1 MiB + 4 KiB guard

section .text

; cpu_count() -> CPUs available to this process, clamped to 1..16.
cpu_count:
    sub rsp, 128
    mov rdi, rsp                ; zero the mask: kernel may write fewer
    mov ecx, 16                 ; than 128 bytes and we popcount all of it
    xor eax, eax
    rep stosq
    xor edi, edi                ; pid 0 = self
    mov esi, 128
    mov rdx, rsp
    mov eax, SYS_sched_getaffinity
    syscall
    xor r8d, r8d
    test rax, rax
    js .fallback
    mov ecx, 16
.count:
    popcnt rax, [rsp+rcx*8-8]
    add r8, rax
    dec ecx
    jnz .count
    test r8, r8
    jnz .clamp
.fallback:
    mov r8d, 4
.clamp:
    cmp r8, 16
    jbe .ok
    mov r8d, 16
.ok:
    mov rax, r8
    add rsp, 128
    ret

; thread_spawn(fn, arg) -> tid, or negative errno.
; Child runs fn(arg) on its own stack, then exits (thread only).
thread_spawn:
    push r12
    push r13
    push r14
    mov r12, rdi                ; fn
    mov r13, rsi                ; arg
    xor edi, edi
    mov esi, STACK_TOTAL
    mov edx, PROT_READ | PROT_WRITE
    mov r10d, MAP_PRIVATE | MAP_ANONYMOUS | MAP_STACK
    mov r8, -1
    xor r9d, r9d
    mov eax, SYS_mmap
    syscall
    cmp rax, -4095
    jae .ret                    ; propagate -errno
    mov r14, rax
    mov rdi, rax                ; guard page at the low end
    mov esi, 4096
    xor edx, edx                ; PROT_NONE
    mov eax, SYS_mprotect
    syscall
    lea rsi, [r14 + STACK_TOTAL - 16]
    mov [rsi], r12              ; child pops these off its new stack
    mov [rsi+8], r13
    mov edi, CLONE_THREAD_FLAGS
    xor edx, edx
    xor r10d, r10d
    xor r8d, r8d
    mov eax, SYS_clone
    syscall
    test rax, rax
    jz .child
.ret:
    pop r14
    pop r13
    pop r12
    ret
.child:
    mov rdi, [rsp+8]            ; arg
    call qword [rsp]            ; fn
    xor edi, edi
    mov eax, SYS_exit
    syscall

; ---- futex rwlock ----------------------------------------------------

; rwlock_init(lock)
rwlock_init:
    mov dword [rdi], 0
    ret

; rd_lock(lock)
rd_lock:
.retry:
    mov eax, [rdi]
    test eax, eax
    js .wait                    ; writer holds it
    lea ecx, [eax+1]
    lock cmpxchg [rdi], ecx
    jnz .retry
    ret
.wait:
    mov esi, FUTEX_WAIT_PRIVATE
    mov edx, eax                ; sleep only if value still what we saw
    xor r10d, r10d
    mov eax, SYS_futex
    syscall
    jmp .retry

; rd_unlock(lock)
rd_unlock:
    mov eax, -1
    lock xadd [rdi], eax        ; eax = previous count
    cmp eax, 1
    jne .done
    mov esi, FUTEX_WAKE_PRIVATE ; last reader out: a writer may be waiting
    mov edx, 1
    mov eax, SYS_futex
    syscall
.done:
    ret

; wr_lock(lock)
wr_lock:
.retry:
    xor eax, eax
    mov ecx, -1
    lock cmpxchg [rdi], ecx
    jz .done
    mov esi, FUTEX_WAIT_PRIVATE
    mov edx, eax                ; the contended value we observed
    xor r10d, r10d
    mov eax, SYS_futex
    syscall
    jmp .retry
.done:
    ret

; wr_unlock(lock)
wr_unlock:
    mov dword [rdi], 0
    mov esi, FUTEX_WAKE_PRIVATE
    mov edx, 0x7fffffff         ; wake everyone; they re-race
    mov eax, SYS_futex
    syscall
    ret

section .note.GNU-stack noalloc noexec nowrite progbits
