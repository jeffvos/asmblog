; store.asm — append-only record store with crash-safe compaction.
;
; Durability model:
;   - every mutation appends one record and fsyncs before returning
;   - updates append a superseding record (last-wins by id at load)
;   - deletes append a tombstone
;   - load verifies each record's crc32c; the first bad/torn record
;     truncates the file there (a crashed half-write heals itself)
;   - compaction rewrites live records to store.tmp, fsyncs, rename()s
;     over the store, then fsyncs the directory
;
; Concurrency: all public entry points take the futex rwlock
; (write side for mutations; readers arrive in milestone 4).
; In-memory state (posts array, settings) lives in one arena that is
; rebuilt on load; post string pointers point into the arena-held file
; image or arena copies, so lifetime == arena lifetime.

BITS 64
%include "src/sys.inc"
%include "src/store.inc"

extern arena_create
extern arena_alloc
extern arena_destroy
extern mem_copy
extern rwlock_init
extern rd_lock
extern rd_unlock
extern wr_lock
extern wr_unlock

global store_open
global store_reset
global store_append_post
global store_delete_post
global store_save_settings
global store_compact
global store_find_by_id
global crc32c
global store_lock
global posts_arr
global posts_cnt
global next_id
global set_ppp
global set_ttl
global set_title_p
global set_title_l
global set_hash
global set_present

section .text

; crc32c(ptr, len) -> eax (Castagnoli, hardware crc32 instruction)
crc32c:
    mov eax, -1
.q:
    cmp rsi, 8
    jb .b
    crc32 rax, qword [rdi]
    add rdi, 8
    sub rsi, 8
    jmp .q
.b:
    test rsi, rsi
    jz .fin
    crc32 eax, byte [rdi]
    inc rdi
    dec rsi
    jmp .b
.fin:
    not eax
    ret

; write_all(fd, buf, len) -> 0 / -1
write_all:
.w:
    test rdx, rdx
    jz .ok
    mov eax, SYS_write
    syscall
    cmp rax, 0
    jle .err
    add rsi, rax
    sub rdx, rax
    jmp .w
.err:
    cmp rax, -EINTR
    je .w
    mov rax, -1
    ret
.ok:
    xor eax, eax
    ret

; time_now() -> unix seconds
time_now:
    xor edi, edi
    mov eax, SYS_time
    syscall
    ret

; store_open() -> 0 / -1. Creates data/ and the store file if missing,
; loads and verifies all records, truncates any torn tail.
store_open:
    push r12
    push rbx
    mov rdi, path_dir           ; mkdir data 0700 (EEXIST is fine)
    mov esi, 0o700
    mov eax, SYS_mkdir
    syscall
    mov rdi, path_store
    mov esi, O_RDWR | O_CREAT
    mov edx, 0o600
    mov eax, SYS_open
    syscall
    test rax, rax
    js .fail
    mov [store_fd], rax
    sub rsp, 144
    mov rdi, rax
    mov rsi, rsp
    mov eax, SYS_fstat
    syscall
    mov r12, [rsp+48]           ; st_size
    add rsp, 144
    test rax, rax
    js .fail
    mov rdi, store_lock
    call rwlock_init
    lea rdi, [r12*2+0x400000]   ; arena: file image + copies + structs
    call arena_create
    test rax, rax
    jz .fail
    mov [st_arena], rax
    mov rdi, rax
    mov esi, MAX_POSTS*8
    call arena_alloc
    mov [posts_arr], rax
    mov qword [posts_cnt], 0
    mov qword [next_id], 1
    mov dword [set_ppp], 5
    mov dword [set_ttl], 86400
    mov byte [set_present], 0
    mov qword [set_title_l], 0
    test r12, r12
    jnz .load
    mov rdi, [store_fd]         ; brand new store: write the file header
    mov rsi, file_hdr
    mov edx, 16
    call write_all
    test rax, rax
    jnz .fail
    mov rdi, [store_fd]
    mov eax, SYS_fsync
    syscall
    mov qword [store_size], 16
    xor eax, eax
    jmp .ret
.load:
    mov rdi, r12
    call store_load
    jmp .ret
.fail:
    mov rax, -1
.ret:
    pop rbx
    pop r12
    ret

; store_reset() — close and forget everything (selftest / compact reload).
store_reset:
    mov rax, [st_arena]
    test rax, rax
    jz .nofree
    mov rdi, rax
    call arena_destroy
.nofree:
    mov qword [st_arena], 0
    mov rdi, [store_fd]
    test rdi, rdi
    jz .nofd
    mov eax, SYS_close
    syscall
.nofd:
    mov qword [store_fd], 0
    mov qword [posts_cnt], 0
    mov byte [set_present], 0
    ret

; store_load(filesize) -> 0 / -1 (internal; store_open set up state)
store_load:
    push r12
    push r13
    push r14
    push r15
    push rbx
    push rbp
    mov r12, rdi                ; size
    mov rdi, [st_arena]
    mov rsi, r12
    call arena_alloc
    test rax, rax
    jz .fail
    mov r13, rax                ; file image (lives in arena forever)
    mov rdi, [store_fd]
    xor esi, esi
    xor edx, edx                ; SEEK_SET 0
    mov eax, SYS_lseek
    syscall
    xor r14d, r14d              ; bytes read
.rd:
    cmp r14, r12
    jae .parse
    mov rdi, [store_fd]
    lea rsi, [r13+r14]
    mov rdx, r12
    sub rdx, r14
    xor eax, eax                ; SYS_read
    syscall
    cmp rax, 0
    jg .adv
    cmp rax, -EINTR
    je .rd
    jmp .fail
.adv:
    add r14, rax
    jmp .rd
.parse:
    cmp r12, 16
    jb .fail
    cmp dword [r13], 'BLG1'
    jne .fail
    mov r14, 16                 ; parse offset
.rec:
    lea rax, [r14+R_HDR]
    cmp rax, r12
    ja .tail
    lea r15, [r13+r14]
    cmp dword [r15+R_MAGIC], 'REC1'
    jne .tail
    mov eax, [r15+R_TLEN]
    add eax, [r15+R_SLEN]
    add eax, [r15+R_GLEN]
    add eax, [r15+R_MLEN]
    add eax, [r15+R_HLEN]
    mov ebx, eax                ; payload length
    lea rax, [rax+R_HDR+7]
    and rax, -8
    mov rbp, rax                ; padded record length
    lea rcx, [r14+rax]
    cmp rcx, r12
    ja .tail
    lea rdi, [r15+R_HDR]
    mov esi, ebx
    call crc32c
    cmp eax, [r15+R_CRC]
    jne .tail
    mov rdi, r15
    call apply_record
    add r14, rbp
    jmp .rec
.tail:
    cmp r14, r12                ; torn/garbage tail: cut it off
    jae .sized
    mov rdi, [store_fd]
    mov rsi, r14
    mov eax, SYS_ftruncate
    syscall
.sized:
    mov [store_size], r14
    mov rdi, [store_fd]
    mov rsi, r14
    xor edx, edx                ; SEEK_SET
    mov eax, SYS_lseek
    syscall
    call sort_posts
    xor eax, eax
    jmp .ret
.fail:
    mov rax, -1
.ret:
    pop rbp
    pop rbx
    pop r15
    pop r14
    pop r13
    pop r12
    ret

; apply_record(rec ptr, strings stay in the loaded image)
apply_record:
    push r12
    push r13
    mov r12, rdi
    cmp dword [r12+R_TYPE], TYPE_SETTINGS
    jne .post
    lea rax, [r12+R_HDR]
    mov ecx, [rax]              ; posts_per_page
    cmp ecx, 1
    jb .ppp_done
    cmp ecx, 50
    ja .ppp_done
    mov [set_ppp], ecx
.ppp_done:
    mov ecx, [rax+4]            ; session ttl
    test ecx, ecx
    jz .ttl_done
    mov [set_ttl], ecx
.ttl_done:
    mov ecx, [rax+8]            ; title length
    mov [set_title_l], rcx
    lea rdx, [rax+16]
    mov [set_title_p], rdx
    lea rsi, [rdx+rcx]
    mov rdi, set_hash
    mov edx, 128
    call mem_copy
    mov byte [set_present], 1
    jmp .done
.post:
    mov rdi, [r12+R_ID]
    call find_idx
    test qword [r12+R_FLAGS], FLAG_TOMBSTONE
    jz .live
    cmp rax, -1
    je .bump
    mov rdi, rax
    call remove_idx
    jmp .bump
.live:
    cmp rax, -1
    jne .replace
    mov rdi, [st_arena]
    mov esi, P_SIZE
    call arena_alloc
    test rax, rax
    jz .done
    mov r13, rax
    mov rcx, [posts_cnt]
    cmp rcx, MAX_POSTS
    jae .done
    mov rdx, [posts_arr]
    mov [rdx+rcx*8], r13
    inc qword [posts_cnt]
    jmp .fill
.replace:
    mov rcx, [posts_arr]
    mov r13, [rcx+rax*8]
.fill:
    mov rax, [r12+R_ID]
    mov [r13+P_ID], rax
    mov rax, [r12+R_FLAGS]
    mov [r13+P_FLAGS], rax
    mov rax, [r12+R_CREATED]
    mov [r13+P_CREATED], rax
    mov rax, [r12+R_UPDATED]
    mov [r13+P_UPDATED], rax
    lea rax, [r12+R_HDR]
    mov [r13+P_TITLE_P], rax
    mov ecx, [r12+R_TLEN]
    mov [r13+P_TITLE_L], rcx
    add rax, rcx
    mov [r13+P_SLUG_P], rax
    mov ecx, [r12+R_SLEN]
    mov [r13+P_SLUG_L], rcx
    add rax, rcx
    mov [r13+P_TAGS_P], rax
    mov ecx, [r12+R_GLEN]
    mov [r13+P_TAGS_L], rcx
    add rax, rcx
    mov [r13+P_MD_P], rax
    mov ecx, [r12+R_MLEN]
    mov [r13+P_MD_L], rcx
    add rax, rcx
    mov [r13+P_HTML_P], rax
    mov ecx, [r12+R_HLEN]
    mov [r13+P_HTML_L], rcx
.bump:
    mov rax, [r12+R_ID]
    inc rax
    cmp rax, [next_id]
    jbe .done
    mov [next_id], rax
.done:
    pop r13
    pop r12
    ret

; find_idx(id) -> array index or -1
find_idx:
    mov rcx, [posts_cnt]
    mov rdx, [posts_arr]
    xor eax, eax
.l:
    cmp rax, rcx
    jae .no
    mov rsi, [rdx+rax*8]
    cmp [rsi+P_ID], rdi
    je .yes
    inc rax
    jmp .l
.no:
    mov rax, -1
.yes:
    ret

; remove_idx(index) — shift the tail left
remove_idx:
    mov rcx, [posts_cnt]
    mov rdx, [posts_arr]
.l:
    lea rax, [rdi+1]
    cmp rax, rcx
    jae .done
    mov rsi, [rdx+rax*8]
    mov [rdx+rdi*8], rsi
    inc rdi
    jmp .l
.done:
    dec qword [posts_cnt]
    ret

; sort_posts — insertion sort, newest created first (ties: higher id first)
sort_posts:
    mov r8, [posts_arr]
    mov r9, [posts_cnt]
    mov rcx, 1
.outer:
    cmp rcx, r9
    jae .done
    mov rax, [r8+rcx*8]
    mov rdx, rcx
.inner:
    test rdx, rdx
    jz .place
    mov rsi, [r8+rdx*8-8]
    mov rdi, [rax+P_CREATED]
    cmp rdi, [rsi+P_CREATED]
    ja .shift
    jb .place
    mov rdi, [rax+P_ID]
    cmp rdi, [rsi+P_ID]
    jbe .place
.shift:
    mov [r8+rdx*8], rsi
    dec rdx
    jmp .inner
.place:
    mov [r8+rdx*8], rax
    inc rcx
    jmp .outer
.done:
    ret

; write_record(pstruct, type) -> 0 / -1
; Serializes into a scratch mmap (zero-filled: padding comes free),
; appends to store_fd, fsyncs, advances store_size. Caller holds wr lock.
write_record:
    push r12
    push r13
    push r14
    push r15
    push rbx
    mov r12, rdi                ; pstruct
    mov r13, rsi                ; type
    mov rax, [r12+P_TITLE_L]
    add rax, [r12+P_SLUG_L]
    add rax, [r12+P_TAGS_L]
    add rax, [r12+P_MD_L]
    add rax, [r12+P_HTML_L]
    mov r14, rax                ; payload length
    lea r15, [rax+R_HDR+7]
    and r15, -8                 ; padded total
    xor edi, edi
    mov rsi, r15
    mov edx, PROT_READ | PROT_WRITE
    mov r10d, MAP_PRIVATE | MAP_ANONYMOUS
    mov r8, -1
    xor r9d, r9d
    mov eax, SYS_mmap
    syscall
    cmp rax, -4095
    jae .fail
    mov rbx, rax                ; scratch
    mov dword [rbx+R_MAGIC], 'REC1'
    mov [rbx+R_TYPE], r13d
    mov rax, [r12+P_ID]
    mov [rbx+R_ID], rax
    mov rax, [r12+P_FLAGS]
    mov [rbx+R_FLAGS], rax
    mov rax, [r12+P_CREATED]
    mov [rbx+R_CREATED], rax
    mov rax, [r12+P_UPDATED]
    mov [rbx+R_UPDATED], rax
    mov rax, [r12+P_TITLE_L]
    mov [rbx+R_TLEN], eax
    mov rax, [r12+P_SLUG_L]
    mov [rbx+R_SLEN], eax
    mov rax, [r12+P_TAGS_L]
    mov [rbx+R_GLEN], eax
    mov rax, [r12+P_MD_L]
    mov [rbx+R_MLEN], eax
    mov rax, [r12+P_HTML_L]
    mov [rbx+R_HLEN], eax
    lea rdi, [rbx+R_HDR]
    mov rsi, [r12+P_TITLE_P]
    mov rdx, [r12+P_TITLE_L]
    call mem_copy
    mov rdi, rax
    mov rsi, [r12+P_SLUG_P]
    mov rdx, [r12+P_SLUG_L]
    call mem_copy
    mov rdi, rax
    mov rsi, [r12+P_TAGS_P]
    mov rdx, [r12+P_TAGS_L]
    call mem_copy
    mov rdi, rax
    mov rsi, [r12+P_MD_P]
    mov rdx, [r12+P_MD_L]
    call mem_copy
    mov rdi, rax
    mov rsi, [r12+P_HTML_P]
    mov rdx, [r12+P_HTML_L]
    call mem_copy
    lea rdi, [rbx+R_HDR]
    mov rsi, r14
    call crc32c
    mov [rbx+R_CRC], eax
    mov rdi, [store_fd]
    mov rsi, rbx
    mov rdx, r15
    call write_all
    mov r12, rax                ; save status across cleanup
    mov rdi, [store_fd]
    mov eax, SYS_fsync
    syscall
    mov rdi, rbx
    mov rsi, r15
    mov eax, SYS_munmap
    syscall
    test r12, r12
    jnz .fail
    add [store_size], r15
    xor eax, eax
    jmp .ret
.fail:
    mov rax, -1
.ret:
    pop rbx
    pop r15
    pop r14
    pop r13
    pop r12
    ret

; memize_post(pstruct) -> 0 / -1
; Copies the five strings into the store arena and upserts the post
; into the in-memory array. Caller holds wr lock.
memize_post:
    push r12
    push r13
    push r14
    mov r12, rdi

%macro ARENIZE 1
    mov rdx, [r12+%1+8]
    test rdx, rdx
    jz %%skip
    mov rdi, [st_arena]
    mov rsi, rdx
    call arena_alloc
    test rax, rax
    jz .fail
    mov r14, rax
    mov rdi, rax
    mov rsi, [r12+%1]
    mov rdx, [r12+%1+8]
    call mem_copy
    mov [r12+%1], r14
%%skip:
%endmacro

    ARENIZE P_TITLE_P
    ARENIZE P_SLUG_P
    ARENIZE P_TAGS_P
    ARENIZE P_MD_P
    ARENIZE P_HTML_P

    mov rdi, [r12+P_ID]
    call find_idx
    cmp rax, -1
    jne .existing
    mov rdi, [st_arena]
    mov esi, P_SIZE
    call arena_alloc
    test rax, rax
    jz .fail
    mov r13, rax
    mov rcx, [posts_cnt]
    cmp rcx, MAX_POSTS
    jae .fail
    mov rdx, [posts_arr]
    mov [rdx+rcx*8], r13
    inc qword [posts_cnt]
    jmp .copy
.existing:
    mov rcx, [posts_arr]
    mov r13, [rcx+rax*8]
.copy:
    mov rdi, r13
    mov rsi, r12
    mov edx, P_SIZE
    call mem_copy
    xor eax, eax
    jmp .ret
.fail:
    mov rax, -1
.ret:
    pop r14
    pop r13
    pop r12
    ret

; store_append_post(spec) -> new/updated id, or -1
store_append_post:
    push r12
    push r13
    push r14
    push rbp
    mov r12, rdi
    mov rdi, store_lock
    call wr_lock
    call time_now
    mov r14, rax                ; now
    mov r13, [r12+S_ID]
    test r13, r13
    jnz .explicit
    mov r13, [next_id]
    inc qword [next_id]
    mov rbp, r14                ; created = now
    jmp .build
.explicit:
    mov rdi, r13
    call find_idx
    cmp rax, -1
    je .newid
    mov rcx, [posts_arr]
    mov rax, [rcx+rax*8]
    mov rbp, [rax+P_CREATED]    ; keep original created
    jmp .build
.newid:
    mov rbp, r14
    lea rax, [r13+1]
    cmp rax, [next_id]
    jbe .build
    mov [next_id], rax
.build:
    sub rsp, P_SIZE
    mov [rsp+P_ID], r13
    mov rax, [r12+S_FLAGS]
    mov [rsp+P_FLAGS], rax
    mov [rsp+P_CREATED], rbp
    mov [rsp+P_UPDATED], r14
    lea rdi, [rsp+P_TITLE_P]    ; the five (ptr,len) pairs, 80 bytes
    lea rsi, [r12+S_TITLE_P]
    mov edx, 80
    call mem_copy
    mov rdi, rsp
    mov esi, TYPE_POST
    call write_record
    test rax, rax
    jnz .fail
    mov rdi, rsp
    call memize_post
    test rax, rax
    jnz .fail
    add rsp, P_SIZE
    call sort_posts
    mov rdi, store_lock
    call wr_unlock
    mov rax, r13
    jmp .ret
.fail:
    add rsp, P_SIZE
    mov rdi, store_lock
    call wr_unlock
    mov rax, -1
.ret:
    pop rbp
    pop r14
    pop r13
    pop r12
    ret

; store_delete_post(id) -> 0 / -1 (unknown id)
store_delete_post:
    push r12
    push r13
    mov r12, rdi
    mov rdi, store_lock
    call wr_lock
    mov rdi, r12
    call find_idx
    cmp rax, -1
    je .fail
    mov r13, rax                ; index
    call time_now
    sub rsp, P_SIZE
    mov rdi, rsp
    mov ecx, P_SIZE/8
    push rax
    xor eax, eax
    rep stosq
    pop rax
    mov [rsp+P_ID], r12
    mov qword [rsp+P_FLAGS], FLAG_TOMBSTONE
    mov [rsp+P_CREATED], rax
    mov [rsp+P_UPDATED], rax
    mov rdi, rsp
    mov esi, TYPE_POST
    call write_record
    add rsp, P_SIZE
    test rax, rax
    jnz .fail
    mov rdi, r13
    call remove_idx
    mov rdi, store_lock
    call wr_unlock
    xor eax, eax
    jmp .ret
.fail:
    mov rdi, store_lock
    call wr_unlock
    mov rax, -1
.ret:
    pop r13
    pop r12
    ret

; write_settings_locked(ppp, ttl, title_p, title_l, hash_p128) -> 0 / -1
; Appends a settings record to store_fd. Caller holds wr lock.
write_settings_locked:
    push r12
    push r13
    push r14
    push r15
    push rbx
    push rbp
    mov r12, rdi                ; ppp
    mov r13, rsi                ; ttl
    mov r14, rdx                ; title ptr
    mov r15, rcx                ; title len
    mov rbx, r8                 ; hash ptr
    lea rax, [r15+16+128]       ; payload
    lea rbp, [rax+R_HDR+7]
    and rbp, -8                 ; padded total
    push rax                    ; keep payload length
    xor edi, edi
    mov rsi, rbp
    mov edx, PROT_READ | PROT_WRITE
    mov r10d, MAP_PRIVATE | MAP_ANONYMOUS
    mov r8, -1
    xor r9d, r9d
    mov eax, SYS_mmap
    syscall
    cmp rax, -4095
    jae .fail_pop
    mov rdi, rax
    pop rdx                     ; payload length
    push rdi                    ; keep scratch ptr
    mov dword [rdi+R_MAGIC], 'REC1'
    mov dword [rdi+R_TYPE], TYPE_SETTINGS
    mov [rdi+R_TLEN], edx
    call time_now
    mov rdx, [rsp]
    mov [rdx+R_CREATED], rax
    mov [rdx+R_UPDATED], rax
    mov rdi, rdx
    mov [rdi+R_HDR], r12d       ; posts per page
    mov [rdi+R_HDR+4], r13d     ; ttl
    mov [rdi+R_HDR+8], r15d     ; title len
    mov dword [rdi+R_HDR+12], 128
    lea rdi, [rdi+R_HDR+16]
    mov rsi, r14
    mov rdx, r15
    call mem_copy
    mov rdi, rax
    mov rsi, rbx
    mov edx, 128
    call mem_copy
    mov rdi, [rsp]              ; crc over the payload
    lea rdi, [rdi+R_HDR]
    lea rsi, [r15+16+128]
    call crc32c
    mov rdx, [rsp]
    mov [rdx+R_CRC], eax
    mov rdi, [store_fd]
    mov rsi, rdx
    mov rdx, rbp
    call write_all
    mov r12, rax
    mov rdi, [store_fd]
    mov eax, SYS_fsync
    syscall
    pop rdi                     ; scratch
    mov rsi, rbp
    mov eax, SYS_munmap
    syscall
    test r12, r12
    jnz .fail
    add [store_size], rbp
    xor eax, eax
    jmp .ret
.fail_pop:
    pop rax
.fail:
    mov rax, -1
.ret:
    pop rbp
    pop rbx
    pop r15
    pop r14
    pop r13
    pop r12
    ret

; store_save_settings(ppp, ttl, title_p, title_l, hash_p128) -> 0 / -1
store_save_settings:
    push r12
    push r13
    push r14
    push r15
    push rbx
    push rbp                    ; keep stack layout symmetric
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
    mov rbx, r8
    mov rdi, store_lock
    call wr_lock
    mov rdi, r12
    mov rsi, r13
    mov rdx, r14
    mov rcx, r15
    mov r8, rbx
    call write_settings_locked
    test rax, rax
    jnz .fail
    mov [set_ppp], r12d         ; mirror into live settings
    mov [set_ttl], r13d
    mov rdi, [st_arena]
    mov rsi, r15
    call arena_alloc
    test rax, rax
    jz .fail
    mov rbp, rax
    mov rdi, rax
    mov rsi, r14
    mov rdx, r15
    call mem_copy
    mov [set_title_p], rbp
    mov [set_title_l], r15
    mov rdi, set_hash
    mov rsi, rbx
    mov edx, 128
    call mem_copy
    mov byte [set_present], 1
    mov rdi, store_lock
    call wr_unlock
    xor eax, eax
    jmp .ret
.fail:
    mov rdi, store_lock
    call wr_unlock
    mov rax, -1
.ret:
    pop rbp
    pop rbx
    pop r15
    pop r14
    pop r13
    pop r12
    ret

; store_compact() -> 0 / -1
; Rewrite live state to store.tmp, rename over the store, fsync the dir.
store_compact:
    push r12
    push r13
    push r14
    mov rdi, store_lock
    call wr_lock
    mov rdi, path_tmp
    mov esi, O_WRONLY | O_CREAT | O_TRUNC
    mov edx, 0o600
    mov eax, SYS_open
    syscall
    test rax, rax
    js .fail
    mov r12, rax                ; tmp fd
    mov r13, [store_fd]         ; old fd
    mov [store_fd], r12         ; write_record targets store_fd
    mov qword [store_size], 16
    mov rdi, r12
    mov rsi, file_hdr
    mov edx, 16
    call write_all
    test rax, rax
    jnz .undo
    xor r14d, r14d              ; index
.wr:
    cmp r14, [posts_cnt]
    jae .settings
    mov rax, [posts_arr]
    mov rdi, [rax+r14*8]
    mov esi, TYPE_POST
    call write_record
    test rax, rax
    jnz .undo
    inc r14
    jmp .wr
.settings:
    cmp byte [set_present], 0
    je .swap
    mov edi, [set_ppp]
    mov esi, [set_ttl]
    mov rdx, [set_title_p]
    mov rcx, [set_title_l]
    mov r8, set_hash
    call write_settings_locked
    test rax, rax
    jnz .undo
.swap:
    mov rdi, path_tmp
    mov rsi, path_store
    mov eax, SYS_rename
    syscall
    test rax, rax
    js .undo
    mov rdi, r13                ; old store fd is now unlinked
    mov eax, SYS_close
    syscall
    mov rdi, path_dir           ; make the rename durable
    mov esi, O_RDONLY | O_DIRECTORY
    mov eax, SYS_open
    syscall
    test rax, rax
    js .nodirsync
    mov r14, rax
    mov rdi, rax
    mov eax, SYS_fsync
    syscall
    mov rdi, r14
    mov eax, SYS_close
    syscall
.nodirsync:
    mov rdi, store_lock
    call wr_unlock
    xor eax, eax
    jmp .ret
.undo:
    mov [store_fd], r13         ; put the old fd back, drop the tmp
    mov rdi, r12
    mov eax, SYS_close
    syscall
.fail:
    mov rdi, store_lock
    call wr_unlock
    mov rax, -1
.ret:
    pop r14
    pop r13
    pop r12
    ret

; store_find_by_id(id) -> post struct ptr, or 0
store_find_by_id:
    push rdi
    call find_idx
    pop rdi
    cmp rax, -1
    je .no
    mov rcx, [posts_arr]
    mov rax, [rcx+rax*8]
    ret
.no:
    xor eax, eax
    ret

section .data

path_dir:   db 'data', 0
path_store: db 'data/store.blg', 0
path_tmp:   db 'data/store.tmp', 0
file_hdr:   db 'BLG1'
            dd 1
            dq 0

section .bss

store_fd:    resq 1
store_size:  resq 1
st_arena:    resq 1
posts_arr:   resq 1
posts_cnt:   resq 1
next_id:     resq 1
set_ppp:     resd 1
set_ttl:     resd 1
set_title_p: resq 1
set_title_l: resq 1
set_hash:    resb 128
set_present: resb 1
store_lock:  resd 1

section .note.GNU-stack noalloc noexec nowrite progbits
