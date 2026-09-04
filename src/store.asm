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
global settings_set_url
global crc32c
global crc32c_raw
global store_gen
global store_mtime
global set_url
global set_url_l
global store_lock
global posts_arr
global posts_cnt
global next_id
global set_ppp
global set_ttl
global set_title_p
global set_title_l
global set_banner_p
global set_banner_l
global set_theme
global set_locale
global set_hash
global set_present

section .text

; crc32c(ptr, len) -> eax (Castagnoli, hardware crc32 instruction)
crc32c:
    mov rdx, rsi
    mov rsi, rdi
    mov edi, -1
    call crc32c_raw
    not eax
    ret

; crc32c_raw(state, ptr, len) -> eax = updated state (no init/finalize),
; so several buffers can be chained into one checksum.
crc32c_raw:
    mov eax, edi
    mov rdi, rsi
    mov rsi, rdx
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
    ret

; store_touch(now) — record a mutation: bump the generation (the ETag
; validator) and advance the last-modified time. Caller holds wr lock.
; Preserves rax.
store_touch:
    inc qword [store_gen]
    cmp rdi, [store_mtime]
    jbe .ret
    mov [store_mtime], rdi
.ret:
    ret

; settings_set_url(p, l) -> 0 / -1. Validates and stages the public site
; URL ("https://host[/prefix]", one trailing slash dropped, <= 255
; bytes of [A-Za-z0-9.:/_-]) into [set_url]; the next settings write
; persists it. l == 0 clears it.
settings_set_url:
    test rsi, rsi
    jz .clear
    cmp rsi, 255
    ja .bad
    cmp rsi, 8
    jb .bad
    cmp dword [rdi], 'http'
    jne .bad
    mov eax, 7                  ; host starts after "http://" ...
    cmp byte [rdi+4], 's'
    jne .sep
    inc eax                     ; ... or "https://"
.sep:
    cmp byte [rdi+rax-3], ':'
    jne .bad
    cmp word [rdi+rax-2], '//'
    jne .bad
    cmp byte [rdi+rsi-1], '/'
    jne .nostrip
    dec rsi
.nostrip:
    cmp rsi, rax
    jbe .bad                    ; no host
    mov rcx, rax
.chars:
    cmp rcx, rsi
    jae .ok
    mov dl, [rdi+rcx]
    cmp dl, '-'
    je .okc
    cmp dl, '.'
    je .okc
    cmp dl, '/'
    je .okc
    cmp dl, ':'
    je .okc
    cmp dl, '_'
    je .okc
    cmp dl, '0'
    jb .bad
    cmp dl, '9'
    jbe .okc
    or dl, 0x20
    cmp dl, 'a'
    jb .bad
    cmp dl, 'z'
    ja .bad
.okc:
    inc rcx
    jmp .chars
.ok:
    mov [set_url_l], rsi
    mov rdx, rsi
    mov rsi, rdi
    mov rdi, set_url
    call mem_copy
    xor eax, eax
    ret
.clear:
    mov qword [set_url_l], 0
    xor eax, eax
    ret
.bad:
    mov rax, -1
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
    mov qword [set_banner_p], def_banner    ; default until settings load
    mov qword [set_banner_l], def_banner_len
    mov dword [set_theme], 0                 ; 0 = retro (default)
    mov dword [set_locale], 0                ; 0 = en-US (default)
    mov qword [set_url_l], 0
    mov qword [store_mtime], 0
    ; generation = boot nanoseconds, +1 per mutation: a restart (new
    ; templates/CSS) and every write both change every ETag
    sub rsp, 16
    xor edi, edi                ; CLOCK_REALTIME
    mov rsi, rsp
    mov eax, SYS_clock_gettime
    syscall
    mov rax, [rsp]
    imul rax, rax, 1000000000
    add rax, [rsp+8]
    add rsp, 16
    mov [store_gen], rax
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
    mov rax, [r12+R_UPDATED]
    cmp rax, [store_mtime]
    jbe .mtime_ok
    mov [store_mtime], rax
.mtime_ok:
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
    mov ecx, [rax+16]           ; theme id (unknown values keep the default)
    cmp ecx, NTHEMES-1
    ja .theme_default
    mov [set_theme], ecx
.theme_default:
    mov ecx, [rax+20]           ; locale id (unknown values keep the default)
    cmp ecx, 1
    ja .locale_default
    mov [set_locale], ecx
.locale_default:
    mov ecx, [rax+8]            ; title length
    mov [set_title_l], rcx
    mov r8d, [rax+12]           ; banner length
    lea rdx, [rax+SET_HDR]      ; title
    mov [set_title_p], rdx
    lea rdx, [rdx+rcx]          ; banner follows the title
    test r8, r8
    jz .banner_default          ; empty stored banner keeps the default
    mov [set_banner_p], rdx
    mov [set_banner_l], r8
.banner_default:
    lea rsi, [rdx+r8]           ; hash follows the banner
    lea r9, [rsi+128]           ; optional extension follows the hash
    mov rdi, set_hash
    mov edx, 128
    call mem_copy
    ; extension: dword url_len | url (records written before it existed
    ; simply end at the hash)
    mov qword [set_url_l], 0
    lea rcx, [r12+R_HDR]
    mov edx, [r12+R_TLEN]       ; settings: whole payload length
    add rcx, rdx                ; payload end
    lea rdx, [r9+4]
    cmp rdx, rcx
    ja .no_url
    mov edx, [r9]
    cmp rdx, 255
    ja .no_url
    lea rsi, [r9+4]
    lea r8, [rsi+rdx]
    cmp r8, rcx
    ja .no_url
    mov [set_url_l], rdx
    mov rdi, set_url
    call mem_copy
.no_url:
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
    mov rdi, rax
    call store_touch
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
    mov rdi, rax
    call store_touch
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

; write_settings_locked(ppp, ttl, title_p, title_l, banner_p, banner_l)
;   -> 0 / -1. The admin password hash always comes from [set_hash], so
;   the caller must stage a new hash there before a password change.
;   Appends a settings record to store_fd. Caller holds wr lock.
; Stack scratch: [rsp+0]=scratch ptr, [rsp+8]=payload len,
;                [rsp+16]=banner ptr, [rsp+24]=banner len (padded to 32)
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
    sub rsp, 32
    mov [rsp+16], r8            ; banner ptr
    mov [rsp+24], r9            ; banner len
    lea rax, [r15+r9+SET_HDR+128+4] ; payload = SET_HDR + title + banner
    add rax, [set_url_l]            ;   + hash + url_len dword + url
    mov [rsp+8], rax
    lea rbp, [rax+R_HDR+7]
    and rbp, -8                 ; padded total record size
    xor edi, edi
    mov rsi, rbp
    mov edx, PROT_READ | PROT_WRITE
    mov r10d, MAP_PRIVATE | MAP_ANONYMOUS
    mov r8, -1
    xor r9d, r9d
    mov eax, SYS_mmap
    syscall
    cmp rax, -4095
    jae .fail
    mov [rsp], rax             ; scratch ptr
    mov rdi, rax
    mov dword [rdi+R_MAGIC], 'REC1'
    mov dword [rdi+R_TYPE], TYPE_SETTINGS
    mov rax, [rsp+8]
    mov [rdi+R_TLEN], eax       ; whole payload length (settings convention)
    call time_now
    mov rdi, rax
    call store_touch
    mov rdi, [rsp]
    mov [rdi+R_CREATED], rax
    mov [rdi+R_UPDATED], rax
    mov [rdi+R_HDR], r12d       ; posts per page
    mov [rdi+R_HDR+4], r13d     ; ttl
    mov [rdi+R_HDR+8], r15d     ; title len
    mov rax, [rsp+24]
    mov [rdi+R_HDR+12], eax     ; banner len
    mov eax, [set_theme]
    mov [rdi+R_HDR+16], eax     ; theme id
    mov eax, [set_locale]
    mov [rdi+R_HDR+20], eax     ; locale id
    mov dword [rdi+R_HDR+24], 128
    lea rdi, [rdi+R_HDR+SET_HDR]
    mov rsi, r14               ; title
    mov rdx, r15
    call mem_copy
    mov rdi, rax               ; banner
    mov rsi, [rsp+16]
    mov rdx, [rsp+24]
    call mem_copy
    mov rdi, rax               ; hash from the live setting
    mov rsi, set_hash
    mov edx, 128
    call mem_copy
    mov ecx, [set_url_l]       ; extension: url_len dword + url
    mov [rax], ecx
    lea rdi, [rax+4]
    mov rsi, set_url
    mov edx, ecx
    call mem_copy
    mov rdi, [rsp]
    lea rdi, [rdi+R_HDR]
    mov rsi, [rsp+8]           ; crc over the payload
    call crc32c
    mov rdi, [rsp]
    mov [rdi+R_CRC], eax
    mov rdi, [store_fd]
    mov rsi, [rsp]
    mov rdx, rbp
    call write_all
    mov r12, rax
    mov rdi, [store_fd]
    mov eax, SYS_fsync
    syscall
    mov rdi, [rsp]             ; scratch
    mov rsi, rbp
    mov eax, SYS_munmap
    syscall
    test r12, r12
    jnz .fail
    add [store_size], rbp
    add rsp, 32
    xor eax, eax
    jmp .ret
.fail:
    add rsp, 32
    mov rax, -1
.ret:
    pop rbp
    pop rbx
    pop r15
    pop r14
    pop r13
    pop r12
    ret

; store_save_settings(ppp, ttl, title_p, title_l, banner_p, banner_l)
;   -> 0 / -1. Persists the current [set_hash]; a caller changing the
;   password stages the new hash there first. Mirrors title and banner
;   into arena-held copies so the live pointers outlive the request.
store_save_settings:
    push r12
    push r13
    push r14
    push r15
    push rbx
    push rbp
    sub rsp, 16
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx                ; title ptr
    mov r15, rcx                ; title len
    mov rbx, r8                 ; banner ptr
    mov rbp, r9                 ; banner len
    mov rdi, store_lock
    call wr_lock
    mov rdi, r12
    mov rsi, r13
    mov rdx, r14
    mov rcx, r15
    mov r8, rbx
    mov r9, rbp
    call write_settings_locked
    test rax, rax
    jnz .fail
    mov [set_ppp], r12d         ; mirror into live settings
    mov [set_ttl], r13d
    mov rdi, [st_arena]         ; arena copy of the title
    mov rsi, r15
    call arena_alloc
    test rax, rax
    jz .fail
    mov [rsp], rax
    mov rdi, rax
    mov rsi, r14
    mov rdx, r15
    call mem_copy
    test rbp, rbp              ; arena copy of the banner (if any)
    jz .no_banner
    mov rdi, [st_arena]
    mov rsi, rbp
    call arena_alloc
    test rax, rax
    jz .fail
    mov [rsp+8], rax
    mov rdi, rax
    mov rsi, rbx
    mov rdx, rbp
    call mem_copy
    mov rax, [rsp+8]
    mov [set_banner_p], rax
    mov [set_banner_l], rbp
.no_banner:
    mov rax, [rsp]
    mov [set_title_p], rax
    mov [set_title_l], r15
    mov byte [set_present], 1
    mov rdi, store_lock
    call wr_unlock
    add rsp, 16
    xor eax, eax
    jmp .ret
.fail:
    mov rdi, store_lock
    call wr_unlock
    add rsp, 16
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
    mov r8, [set_banner_p]
    mov r9, [set_banner_l]
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
def_banner: db '*** WELCOME *** SERVED FRESH BY HAND-WRITTEN x86_64 ASSEMBLY '
            db '*** NO JAVASCRIPT WAS HARMED IN THE MAKING OF THIS PAGE ***'
def_banner_len equ $-def_banner

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
set_banner_p: resq 1
set_banner_l: resq 1
set_theme:   resd 1
set_locale:  resd 1
set_hash:    resb 128
set_url:     resb 256
set_url_l:   resq 1
set_present: resb 1
store_gen:   resq 1
store_mtime: resq 1
store_lock:  resd 1

section .note.GNU-stack noalloc noexec nowrite progbits
