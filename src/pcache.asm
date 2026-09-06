; pcache.asm — rendered-page cache keyed by the dynamic validator.
;
; Every public page already carries an exact validator: the weak ETag
; W/"<store generation>-<crc32c(host, path, query)>" (see dyn_etag in
; http.asm). The generation changes on every write and every restart,
; so "same ETag" means "byte-identical page". That makes a cache almost
; free to keep correct: entries are keyed by the ETag plus the exact
; request identity (host, forwarded scheme, request target), and a
; stale entry simply stops matching once the generation moves on.
;
; A hit copies the rendered body into the connection's body region and
; hands it to finish_page, exactly as a handler would; the store read
; lock, template rendering and markdown/tag assembly are skipped. A miss
; costs one crc32c over the key and one lock/compare.
;
; The table is small (PC_NSLOT direct-mapped slots, bodies up to
; PC_BODYMAX) and shared by all workers under a futex lock; copies are
; a few KB, so contention is negligible. Only responses that a shared
; cache may hold are stored: the public cache modes, no extra headers
; (nothing content-negotiated), and never anything marked no-store.

BITS 64
%include "src/sys.inc"
%include "src/conn.inc"

extern wr_lock
extern wr_unlock
extern mem_copy
extern mem_eq
extern crc32c
extern finish_page

global pcache_lookup
global pcache_store

%define PC_NSLOT   16
%define PC_KEYMAX  512
%define PC_BODYMAX 65536

; slot layout
%define PS_KEYL   0             ; qword key length (0 = empty)
%define PS_BODYL  8
%define PS_CT     16            ; Content-Type header ptr/len (static data)
%define PS_CTL    24
%define PS_LM     32            ; Last-Modified the page was rendered with
%define PS_CACHE  40            ; byte: CACHE_* mode
%define PS_KEY    48
%define PS_BODY   (PS_KEY + PC_KEYMAX)
%define PS_SIZE   (PS_BODY + PC_BODYMAX)

section .text

; pc_key(ctx, dst) -> rax = key length, or 0 when the request has no
; dynamic validator or the key would not fit.
; key = ETag (29 bytes) | Host | https byte | request target
pc_key:
    push r12
    push rbx
    mov r12, rdi
    mov rbx, rsi
    cmp byte [r12+CTX_ETAG_L], 29
    jne .no
    mov rax, 30
    add rax, [r12+CTX_HOST_L]
    add rax, [r12+CTX_TGT_L]
    cmp rax, PC_KEYMAX
    ja .no
    mov rdi, rbx
    lea rsi, [r12+CTX_ETAG]
    mov edx, 29
    call mem_copy
    mov rdi, rax
    mov rsi, [r12+CTX_HOST_P]
    mov rdx, [r12+CTX_HOST_L]
    call mem_copy
    mov cl, [r12+CTX_HTTPS]
    mov [rax], cl
    lea rdi, [rax+1]
    mov rsi, [r12+CTX_TGT_P]
    mov rdx, [r12+CTX_TGT_L]
    call mem_copy
    sub rax, rbx
    jmp .ret
.no:
    xor eax, eax
.ret:
    pop rbx
    pop r12
    ret

; pc_slot(key, len) -> rax = slot address (direct-mapped by crc32c)
pc_slot:
    call crc32c
    and eax, PC_NSLOT - 1
    imul rax, rax, PS_SIZE
    add rax, pc_slots
    ret

; pcache_lookup(ctx) -> 1 if the response was served from the cache
; (finish_page has been called), 0 on a miss. Call after dyn_etag and
; only when the client does not already hold the page (CTX_INM = 0).
pcache_lookup:
    push r12
    push r13
    push r14
    push rbx
    sub rsp, PC_KEYMAX
    mov r12, rdi
    mov rsi, rsp
    call pc_key
    test rax, rax
    jz .miss_nolock
    mov r13, rax
    mov rdi, rsp
    mov rsi, rax
    call pc_slot
    mov r14, rax
    mov rdi, pc_lock
    call wr_lock
    cmp [r14+PS_KEYL], r13
    jne .miss
    mov rdi, rsp
    lea rsi, [r14+PS_KEY]
    mov rdx, r13
    call mem_eq
    test eax, eax
    jz .miss
    ; hit: the body goes where a handler would have rendered it
    mov rbx, [r14+PS_BODYL]
    lea rdi, [r12+CTX_OUT+CTX_BODY_OFF]
    lea rsi, [r14+PS_BODY]
    mov rdx, rbx
    call mem_copy
    mov rax, [r14+PS_LM]
    mov [r12+CTX_LM], rax
    mov al, [r14+PS_CACHE]
    mov [r12+CTX_CACHE], al
    mov rdx, [r14+PS_CT]
    mov rcx, [r14+PS_CTL]
    mov [rsp], rdx              ; the key is no longer needed
    mov [rsp+8], rcx
    mov rdi, pc_lock
    call wr_unlock
    mov rdi, r12
    mov rsi, rbx
    mov rdx, [rsp]
    mov rcx, [rsp+8]
    xor r8d, r8d
    xor r9d, r9d
    call finish_page
    mov eax, 1
    jmp .ret
.miss:
    mov rdi, pc_lock
    call wr_unlock
.miss_nolock:
    xor eax, eax
.ret:
    add rsp, PC_KEYMAX
    pop rbx
    pop r14
    pop r13
    pop r12
    ret

; pcache_store(ctx, body_len, ctype_p, ctype_l, extra_l) — called by
; finish_page with the body rendered at CTX_OUT+CTX_BODY_OFF. Keeps the
; page when it is publicly cacheable, has no extra headers and fits.
pcache_store:
    test r8, r8
    jnz .skip
    cmp rsi, PC_BODYMAX
    ja .skip
    mov al, [rdi+CTX_CACHE]
    cmp al, CACHE_REVALIDATE
    je .ok
    cmp al, CACHE_FEED
    je .ok
    cmp al, CACHE_DAY
    jne .skip
.ok:
    push r12
    push r13
    push r14
    push r15
    push rbx
    push rbp
    sub rsp, PC_KEYMAX
    mov r12, rdi
    mov r13, rsi                ; body length
    mov r14, rdx                ; ctype
    mov r15, rcx
    mov rsi, rsp
    call pc_key
    test rax, rax
    jz .done
    mov rbx, rax                ; key length
    mov rdi, rsp
    mov rsi, rax
    call pc_slot
    mov rbp, rax                ; slot
    mov rdi, pc_lock
    call wr_lock
    cmp [rbp+PS_KEYL], rbx      ; already holding this page (a hit that
    jne .write                  ; just went through finish_page)?
    mov rdi, rsp
    lea rsi, [rbp+PS_KEY]
    mov rdx, rbx
    call mem_eq
    test eax, eax
    jnz .unlock
.write:
    mov qword [rbp+PS_KEYL], 0  ; never a half-written entry with a key
    lea rdi, [rbp+PS_KEY]
    mov rsi, rsp
    mov rdx, rbx
    call mem_copy
    lea rdi, [rbp+PS_BODY]
    lea rsi, [r12+CTX_OUT+CTX_BODY_OFF]
    mov rdx, r13
    call mem_copy
    mov [rbp+PS_BODYL], r13
    mov [rbp+PS_CT], r14
    mov [rbp+PS_CTL], r15
    mov rax, [r12+CTX_LM]
    mov [rbp+PS_LM], rax
    mov al, [r12+CTX_CACHE]
    mov [rbp+PS_CACHE], al
    mov [rbp+PS_KEYL], rbx
.unlock:
    mov rdi, pc_lock
    call wr_unlock
.done:
    add rsp, PC_KEYMAX
    pop rbp
    pop rbx
    pop r15
    pop r14
    pop r13
    pop r12
.skip:
    ret

section .bss

align 16
pc_slots: resb PC_NSLOT * PS_SIZE
pc_lock:  resd 1

section .note.GNU-stack noalloc noexec nowrite progbits
