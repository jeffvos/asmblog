; reload.asm — SIGHUP: re-read templates/ and static/ while serving.
;
; Both loaders build the new set in a fresh arena and publish it with
; single pointer stores (one per template, one for the static table),
; so a worker mid-render keeps the set it started with and the next
; request sees the new one. The previous arenas are never unmapped: a
; worker may still be reading them, a reload is rare, and the leak is
; a megabyte or so per SIGHUP. A loader that fails (a template with an
; unknown marker, a missing main.css) leaves its old set in place and
; says so on stderr.
;
; The store generation moves afterwards so every ETag changes and the
; render cache (pcache.asm) stops matching, exactly as a restart would.
;
; Runs on the initial thread, from crypto_service (crypto.asm).

BITS 64
%include "src/sys.inc"

extern tmpl_load_all
extern load_static
extern store_lock
extern store_gen
extern wr_lock
extern wr_unlock

global reload_all

section .text

; reload_all()
reload_all:
    push r12
    call tmpl_load_all
    mov r12, rax
    mov rsi, msg_tmpl_ok
    mov edx, msg_tmpl_ok_len
    test rax, rax
    jz .say_tmpl
    mov rsi, msg_tmpl_bad
    mov edx, msg_tmpl_bad_len
.say_tmpl:
    mov edi, STDERR
    mov eax, SYS_write
    syscall
    call load_static
    mov rsi, msg_static_ok
    mov edx, msg_static_ok_len
    test rax, rax
    jz .say_static
    mov rsi, msg_static_bad
    mov edx, msg_static_bad_len
.say_static:
    mov edi, STDERR
    mov eax, SYS_write
    syscall
    ; the generation is bumped under the store's write lock: writers
    ; increment it with a plain inc under the same lock (store_touch)
    mov rdi, store_lock
    call wr_lock
    inc qword [store_gen]
    mov rdi, store_lock
    call wr_unlock
    pop r12
    ret

section .data
msg_tmpl_ok: db 'blogd: reloaded templates/', 10
msg_tmpl_ok_len equ $-msg_tmpl_ok
msg_tmpl_bad: db 'blogd: reload: templates/ failed to load, keeping the old set', 10
msg_tmpl_bad_len equ $-msg_tmpl_bad
msg_static_ok: db 'blogd: reloaded static/', 10
msg_static_ok_len equ $-msg_static_ok
msg_static_bad: db 'blogd: reload: static/ failed to load (main.css missing?), keeping the old set', 10
msg_static_bad_len equ $-msg_static_bad

section .note.GNU-stack noalloc noexec nowrite progbits
