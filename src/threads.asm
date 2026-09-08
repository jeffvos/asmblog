; threads.asm — clone()-based threads, CPU counting, futex rwlock.
;
; Threads share VM/files/signals (CLONE_THREAD); each gets a 1 MiB
; mmap'd stack with a PROT_NONE guard page at the low end, so stack
; overflow faults instead of silently corrupting a neighbour.
;
; The rwlock is a single 32-bit word (callers reserve one dword):
;   bit 31 (RW_WRITER)  a writer holds it
;   bit 30 (RW_WAIT)    at least one thread has gone, or is going, to
;                       sleep on the futex since the last wake
;   bits 0-29           reader count
; Every waiter sets RW_WAIT (with cmpxchg, so it sleeps only if the word
; still holds what it saw) before FUTEX_WAIT; an unlock issues FUTEX_WAKE
; only when the value it replaced carried RW_WAIT. The uncontended path
; is therefore one locked instruction each way and no syscall at all.
; Wakes are still all-or-nothing (thundering herd, everyone re-races)
; and there is no writer preference: readers keep taking the lock while
; a writer sleeps, exactly as before. The store is the main user; the
; page cache and the session table share the implementation.

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

%define RW_WRITER 0x80000000
%define RW_WAIT   0x40000000

; rwlock_init(lock)
rwlock_init:
    mov dword [rdi], 0
    ret

; RW_SLEEP retry — eax = the contended value just observed, rdi = lock.
; Publish RW_WAIT on exactly that value, sleep while the word still
; holds it, then jump back to the caller's retry loop.
%macro RW_SLEEP 1               ; %1 = retry label
    mov ecx, eax
    or ecx, RW_WAIT
    lock cmpxchg [rdi], ecx     ; someone changed it meanwhile: re-read
    jnz %1
    mov esi, FUTEX_WAIT_PRIVATE
    mov edx, ecx                ; sleep only if the word is still ecx
    xor r10d, r10d
    mov eax, SYS_futex
    syscall                     ; rdi survives the syscall
    jmp %1
%endmacro

; RW_WAKE — FUTEX_WAKE everyone sleeping on the word at rdi.
%macro RW_WAKE 0
    mov esi, FUTEX_WAKE_PRIVATE
    mov edx, 0x7fffffff         ; wake everyone; they re-race
    mov eax, SYS_futex
    syscall
%endmacro

; rd_lock(lock)
rd_lock:
.retry:
    mov eax, [rdi]
    test eax, eax
    js .wait                    ; writer holds it
    lea ecx, [eax+1]
    cmp eax, RW_WAIT            ; no readers and a leftover wait bit: at
    jne .cas                    ; this point no one can be asleep on it
    mov ecx, 1                  ; (see rd_unlock), so start clean
.cas:
    lock cmpxchg [rdi], ecx
    jnz .retry
    ret
.wait:
    RW_SLEEP .retry

; rd_unlock(lock)
; The last reader leaves the word at RW_WAIT (not 0) when a writer is
; asleep, and wakes it; the writer's cmpxchg accepts either value.
; Nobody ever sleeps on a word that is exactly RW_WAIT (readers sleep
; on RW_WRITER, writers on a non-zero count), so a stale RW_WAIT can be
; cleared by whoever acquires next without losing a wakeup.
rd_unlock:
    mov eax, -1
    lock xadd [rdi], eax        ; eax = previous value
    cmp eax, RW_WAIT | 1        ; last reader out with a sleeping writer
    jne .done
    RW_WAKE
.done:
    ret

; wr_lock(lock)
wr_lock:
.retry:
    mov eax, [rdi]
    test eax, ~RW_WAIT & 0xffffffff ; any reader or writer at all?
    jnz .wait
    mov ecx, RW_WRITER          ; from 0 or a stale RW_WAIT: take it clean
    lock cmpxchg [rdi], ecx
    jnz .retry
    ret
.wait:
    RW_SLEEP .retry

; wr_unlock(lock)
wr_unlock:
    xor eax, eax
    xchg [rdi], eax             ; implicitly locked; eax = previous value
    test eax, RW_WAIT
    jz .done
    RW_WAKE
.done:
    ret

section .note.GNU-stack noalloc noexec nowrite progbits
