; media.asm — self-hosted images: upload, conversion, storage, serving.
;
; An image uploaded through /admin/media is converted once, at upload
; time, into two sizes of two formats — <id>.webp/<id>.png (the longest
; edge capped by the "image size" setting) and <id>-s.webp/<id>-s.png
; (half that, for the inline copy on a post page) — under data/media/,
; and described by one TYPE_MEDIA record in the store (dimensions, byte
; sizes, the original filename). Posts reference it as ![alt](/media/N):
; md.asm turns that into a <picture> with a srcset and a CSS-only
; lightbox, and pages.asm uses the first one as og:image.
;
; Conversion runs outside the sandbox. The server's seccomp allowlist
; has no execve, so before the workers start (and before the filter
; lands) main forks a helper process that shares a socketpair with the
; server and nothing else. A worker sends it a 48-byte job (upload
; number, media id, sizes), the helper fork+execs tools/imgconv (a sh
; script that drives vipsthumbnail, ImageMagick or Pillow, whichever is
; installed), waits, and answers with the exit status. The helper is
; not filtered; the converter gets no file descriptors beyond
; stdin/out/err. Jobs are serialised on a mutex, and the worker that
; posted one blocks until the converter finishes (a few hundred ms per
; photo) — an admin uploading is the only client that waits.
;
; Large bodies never sit in memory: net.asm streams an upload into
; data/media/up-<n>.tmp as it arrives (only for POST /admin/media with
; a live session, so nobody anonymous can fill the disk), and the
; multipart parser here maps that file. The file part is written out
; as up-<n>.img for the converter and both temporaries are unlinked
; afterwards. A crash in between leaves files that the sweep at the
; next start removes, together with any rendition whose record is
; missing (converted, then the record append failed) and any rendition
; whose record is a tombstone (deleted, then the unlink never ran).
;
; Serving /media/<name> maps the file and lets conn_flush send from
; the mapping after the headers (no copy through the outbuf, no size
; limit); renditions are immutable per URL, so they carry a strong
; ETag and a one-year immutable cache policy.

BITS 64
%include "src/sys.inc"
%include "src/conn.inc"
%include "src/store.inc"

extern rd_lock
extern rd_unlock
extern wr_lock
extern wr_unlock
extern store_lock
extern media_find
extern media_reserve_id
extern store_append_media
extern store_delete_media
extern set_imgmax
extern mem_copy
extern mem_eq
extern mem_find
extern ci_prefix
extern u64_to_dec
extern parse_dec
extern find_header
extern hdr_block
extern inm_check
extern finish_304
extern build_page
extern resp_headers
extern sec_headers
extern sec_headers_len
extern emit_date_hdr_at
extern getenv_value
extern envp
extern admin_session_ok
extern session_csrf_ok

global media_init
global media_ready
global media_spool_allowed
global media_spool_open
global media_spool_discard
global media_upload
global media_lookup
global media_delete
global page_media

; media_upload result codes
%define MU_OK      0
%define MU_BADREQ  1            ; malformed multipart / csrf mismatch
%define MU_TYPE    2            ; not a supported image
%define MU_EMPTY   3            ; no file part, or an empty one
%define MU_CONV    4            ; the converter failed
%define MU_STORE   5            ; record append failed
%define MU_NOCONV  6            ; no converter available
%define MU_FULL    7            ; MAX_MEDIA reached

; helper job (48 bytes): op (0 check, 1 convert), media id, upload
; number, max edge, inline edge, reserved. Reply: 8 bytes, the status.
%define J_OP    0
%define J_ID    8
%define J_UP    16
%define J_MAX   24
%define J_INL   32
%define J_SIZE  48

%define SPOOL_CHUNK 65536

section .text

; ---- startup --------------------------------------------------------------

; media_init() -> 0. Creates data/media, sweeps stale files, locates the
; converter script, forks the helper and runs its self-check. Never
; fatal: without a converter the upload page says so and everything
; else works.
media_init:
    push r12
    push r13
    push rbx
    sub rsp, 16
    mov byte [media_ready], 0
    mov qword [helper_fd], -1
    mov rdi, p_mediadir
    mov esi, 0o700
    mov eax, SYS_mkdir
    syscall
    call media_sweep
    ; the converter: BLOGD_IMGCONV, else the first executable candidate
    mov rdi, env_imgconv
    call getenv_value
    test rax, rax
    jz .exe_rel
    cmp byte [rax], 0
    je .exe_rel
    mov [imgconv_path], rax
    jmp .have_conv
.exe_rel:
    ; next to the binary: <dir of /proc/self/exe>/../tools/imgconv, so a
    ; site directory elsewhere than the repo still finds the script
    mov rdi, p_self_exe
    mov rsi, exe_buf
    mov edx, 200
    mov eax, SYS_readlink
    syscall
    test rax, rax
    jle .candidates
    lea rcx, [exe_buf+rax]
.strip:
    dec rcx
    cmp rcx, exe_buf
    jbe .candidates
    cmp byte [rcx], '/'
    jne .strip
    lea rdi, [rcx+1]
    mov rsi, rel_imgconv
    call cstr_copy
    mov rdi, exe_buf
    mov esi, 1                  ; X_OK
    mov eax, SYS_access
    syscall
    test rax, rax
    jnz .candidates
    mov qword [imgconv_path], exe_buf
    jmp .have_conv
.candidates:
    xor ebx, ebx
.cand:
    mov rdi, [cand_tbl + rbx*8]
    test rdi, rdi
    jz .no_conv
    mov esi, 1                  ; X_OK
    mov eax, SYS_access
    syscall
    test rax, rax
    jz .picked
    inc rbx
    jmp .cand
.picked:
    mov rax, [cand_tbl + rbx*8]
    mov [imgconv_path], rax
.have_conv:
    ; socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, sv)
    mov edi, AF_UNIX
    mov esi, SOCK_STREAM | SOCK_CLOEXEC
    xor edx, edx
    mov r10, rsp
    mov eax, SYS_socketpair
    syscall
    test rax, rax
    js .no_conv
    mov eax, SYS_fork
    syscall
    test rax, rax
    js .fork_fail
    jnz .parent
    mov edi, [rsp]              ; child: keep sv[1] only
    mov eax, SYS_close
    syscall
    mov edi, [rsp+4]
    jmp helper_main             ; never returns
.parent:
    mov edi, [rsp+4]
    mov eax, SYS_close
    syscall
    mov eax, [rsp]
    mov [helper_fd], rax
    xor edi, edi                ; job 0: imgconv --check
    xor esi, esi
    xor edx, edx
    call media_convert
    test rax, rax
    jnz .check_failed
    mov byte [media_ready], 1
    mov rsi, msg_ready
    mov edx, msg_ready_len
    jmp .say
.check_failed:
    mov rsi, msg_nobackend
    mov edx, msg_nobackend_len
    jmp .say
.fork_fail:
    mov edi, [rsp]
    mov eax, SYS_close
    syscall
    mov edi, [rsp+4]
    mov eax, SYS_close
    syscall
.no_conv:
    mov rsi, msg_noconv
    mov edx, msg_noconv_len
.say:
    mov edi, STDERR
    mov eax, SYS_write
    syscall
    xor eax, eax
    add rsp, 16
    pop rbx
    pop r13
    pop r12
    ret

; helper_main(fd) — the unsandboxed helper process. Reads jobs until
; the server closes its end, runs the converter for each, answers with
; its exit status. Exits when the socket does.
helper_main:
    mov r12d, edi
.job:
    mov edi, r12d
    mov rsi, h_job
    mov edx, J_SIZE
    call read_full
    test rax, rax
    jnz .bye
    ; argv[0] = the script
    mov rax, [imgconv_path]
    mov [h_argv], rax
    cmp qword [h_job+J_OP], 0
    jne .convert
    mov qword [h_argv+8], a_check
    mov qword [h_argv+16], 0
    jmp .run
.convert:
    ; "data/media/up-<n>.img" "data/media/<id>" "<max>" "<inline>"
    mov rdi, [h_job+J_UP]
    mov rsi, h_in
    mov rdx, sfx_img
    call up_path
    mov rdi, [h_job+J_ID]
    mov rsi, h_out
    mov rdx, sfx_none
    call media_path
    mov rdi, [h_job+J_MAX]
    mov rsi, h_max
    call u64_to_dec
    mov byte [rax], 0
    mov rdi, [h_job+J_INL]
    mov rsi, h_inl
    call u64_to_dec
    mov byte [rax], 0
    mov qword [h_argv+8], h_in
    mov qword [h_argv+16], h_out
    mov qword [h_argv+24], h_max
    mov qword [h_argv+32], h_inl
    mov qword [h_argv+40], 0
.run:
    mov eax, SYS_fork
    syscall
    test rax, rax
    js .failed
    jnz .wait
    ; grandchild: nothing but stdin/out/err reaches the converter
    mov edi, 3
.closefds:
    mov eax, SYS_close
    syscall
    inc edi
    cmp edi, 1024
    jb .closefds
    mov rdi, [imgconv_path]
    mov rsi, h_argv
    mov rdx, [envp]
    mov eax, SYS_execve
    syscall
    mov edi, 127
    mov eax, SYS_exit_group
    syscall
.wait:
    mov rdi, rax                ; wait4(pid, &status, 0, 0)
    mov rsi, h_status
    xor edx, edx
    xor r10d, r10d
    mov eax, SYS_wait4
    syscall
    cmp rax, -EINTR
    je .wait
    test rax, rax
    js .failed
    mov eax, [h_status]
    test al, 0x7f
    jnz .signalled
    shr eax, 8
    movzx eax, al               ; exit code
    jmp .reply
.signalled:
    and eax, 0x7f
    add eax, 128
    jmp .reply
.failed:
    mov eax, 126
.reply:
    mov [h_reply], rax
    mov edi, r12d
    mov rsi, h_reply
    mov edx, 8
    call write_full
    test rax, rax
    jz .job
.bye:
    xor edi, edi
    mov eax, SYS_exit_group
    syscall

; read_full(fd, buf, n) -> 0 when all n bytes arrived, -1 on EOF/error
read_full:
    push r12
    push r13
    push r14
    mov r12d, edi
    mov r13, rsi
    mov r14, rdx
.rd:
    test r14, r14
    jz .ok
    mov edi, r12d
    mov rsi, r13
    mov rdx, r14
    xor eax, eax
    syscall
    cmp rax, 0
    jg .adv
    cmp rax, -EINTR
    je .rd
    mov rax, -1
    jmp .ret
.adv:
    add r13, rax
    sub r14, rax
    jmp .rd
.ok:
    xor eax, eax
.ret:
    pop r14
    pop r13
    pop r12
    ret

; write_full(fd, buf, n) -> 0 / -1
write_full:
    push r12
    push r13
    push r14
    mov r12d, edi
    mov r13, rsi
    mov r14, rdx
.wr:
    test r14, r14
    jz .ok
    mov edi, r12d
    mov rsi, r13
    mov rdx, r14
    mov eax, SYS_write
    syscall
    cmp rax, 0
    jg .adv
    cmp rax, -EINTR
    je .wr
    mov rax, -1
    jmp .ret
.adv:
    add r13, rax
    sub r14, rax
    jmp .wr
.ok:
    xor eax, eax
.ret:
    pop r14
    pop r13
    pop r12
    ret

; media_convert(op, id, upload_n) -> rax = converter exit status (0 ok),
; or -1 when the helper is gone. Serialised; the caller blocks.
media_convert:
    push r12
    push r13
    push r14
    sub rsp, J_SIZE
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    cmp qword [helper_fd], 0
    jl .gone
    mov rdi, helper_lock
    call wr_lock
    mov [rsp+J_OP], r12
    mov [rsp+J_ID], r13
    mov [rsp+J_UP], r14
    mov eax, [set_imgmax]
    mov [rsp+J_MAX], rax
    shr rax, 1                  ; the inline copy is half the full edge
    cmp rax, IMGMAX_MIN         ; (none below the floor: the full one
    jae .inl                    ;  serves both roles)
    xor eax, eax
.inl:
    mov [rsp+J_INL], rax
    mov qword [rsp+40], 0
    mov edi, [helper_fd]
    mov rsi, rsp
    mov edx, J_SIZE
    call write_full
    test rax, rax
    jnz .dead
    mov edi, [helper_fd]
    mov rsi, rsp
    mov edx, 8
    call read_full
    test rax, rax
    jnz .dead
    mov r12, [rsp]
    mov rdi, helper_lock
    call wr_unlock
    mov rax, r12
    jmp .ret
.dead:
    mov rdi, helper_lock
    call wr_unlock
.gone:
    mov rax, -1
.ret:
    add rsp, J_SIZE
    pop r14
    pop r13
    pop r12
    ret

; ---- paths ---------------------------------------------------------------

; up_path(n, dst, sfx_cstr) -> rax = end. "data/media/up-<n>" + sfx, NUL.
up_path:
    push r12
    mov r12, rdx
    push rsi
    push rdi
    mov rdi, rsi
    mov rsi, p_up
    mov edx, p_up_len
    call mem_copy
    pop rdi
    mov rsi, rax
    call u64_to_dec
    pop rsi
    mov rdi, rax
    mov rsi, r12
    call cstr_copy
    pop r12
    ret

; media_path(id, dst, sfx_cstr) -> rax = end. "data/media/<id>" + sfx, NUL.
media_path:
    push r12
    mov r12, rdx
    push rsi
    push rdi
    mov rdi, rsi
    mov rsi, p_mediadir_s
    mov edx, p_mediadir_s_len
    call mem_copy
    pop rdi
    mov rsi, rax
    call u64_to_dec
    pop rsi
    mov rdi, rax
    mov rsi, r12
    call cstr_copy
    pop r12
    ret

; cstr_copy(dst, src_cstr) -> rax = dst at the NUL (copied too)
cstr_copy:
.l:
    mov al, [rsi]
    mov [rdi], al
    test al, al
    jz .done
    inc rdi
    inc rsi
    jmp .l
.done:
    mov rax, rdi
    ret

; unlink_media(id, sfx) — best effort
unlink_media:
    sub rsp, 64
    mov rdx, rsi
    mov rsi, rsp
    call media_path
    mov rdi, rsp
    mov eax, SYS_unlink
    syscall
    add rsp, 64
    ret

; media_delete(id) -> 0 / -1. Tombstone first, then the files: if the
; unlink never runs, the sweep at the next start finishes the job.
media_delete:
    push r12
    mov r12, rdi
    call store_delete_media
    test rax, rax
    jnz .ret
    mov rdi, r12
    mov rsi, sfx_webp
    call unlink_media
    mov rdi, r12
    mov rsi, sfx_png
    call unlink_media
    mov rdi, r12
    mov rsi, sfx_swebp
    call unlink_media
    mov rdi, r12
    mov rsi, sfx_spng
    call unlink_media
    xor eax, eax
.ret:
    pop r12
    ret

; media_sweep — startup: drop up-* leftovers and renditions with no
; live record. Single-threaded, before the workers exist.
media_sweep:
    push r12
    push r13
    push r14
    push r15
    push rbx
    sub rsp, 4096 + 64
    mov rdi, p_mediadir
    mov esi, O_RDONLY | O_DIRECTORY
    mov eax, SYS_open
    syscall
    test rax, rax
    js .done
    mov r12, rax
.batch:
    mov edi, r12d
    lea rsi, [rsp+64]
    mov edx, 4096
    mov eax, SYS_getdents64
    syscall
    cmp rax, 0
    jle .close
    mov r13, rax                ; bytes
    xor r14d, r14d              ; offset
.ent:
    cmp r14, r13
    jae .batch
    lea r15, [rsp+64+r14]       ; dirent: ino 8, off 8, reclen 2, type 1, name
    movzx eax, word [r15+16]
    add r14, rax
    lea rbx, [r15+19]           ; name (NUL-terminated)
    ; "up-*" temporaries
    cmp word [rbx], 'up'
    jne .rendition
    cmp byte [rbx+2], '-'
    je .unlink
.rendition:
    ; <digits> then one of the four suffixes
    xor ecx, ecx
.digits:
    mov al, [rbx+rcx]
    sub al, '0'
    cmp al, 9
    ja .digits_end
    inc ecx
    cmp ecx, 9
    jbe .digits
    jmp .next
.digits_end:
    test ecx, ecx
    jz .next
    lea rdi, [rbx+rcx]
    call sfx_variant
    cmp rax, -1
    je .next
    mov rdi, rbx
    mov rsi, rcx
    call parse_dec
    test rax, rax
    jz .next
    mov rdi, rax
    call media_find             ; startup: no lock needed
    test rax, rax
    jnz .next
.unlink:
    mov rdi, rsp
    mov rsi, p_mediadir_s
    mov edx, p_mediadir_s_len
    call mem_copy
    mov rdi, rax
    mov rsi, rbx
    call cstr_copy
    mov rdi, rsp
    mov eax, SYS_unlink
    syscall
.next:
    jmp .ent
.close:
    mov edi, r12d
    mov eax, SYS_close
    syscall
.done:
    add rsp, 4096 + 64
    pop rbx
    pop r15
    pop r14
    pop r13
    pop r12
    ret

; sfx_variant(cstr) -> rax = 0 .webp, 1 .png, 2 -s.webp, 3 -s.png, or -1
sfx_variant:
    mov rsi, sfx_webp
    call cstr_eq_local
    test eax, eax
    jnz .v0
    mov rsi, sfx_png
    call cstr_eq_local
    test eax, eax
    jnz .v1
    mov rsi, sfx_swebp
    call cstr_eq_local
    test eax, eax
    jnz .v2
    mov rsi, sfx_spng
    call cstr_eq_local
    test eax, eax
    jnz .v3
    mov rax, -1
    ret
.v0:
    xor eax, eax
    ret
.v1:
    mov eax, 1
    ret
.v2:
    mov eax, 2
    ret
.v3:
    mov eax, 3
    ret

; cstr_eq_local(a, b) -> 1/0 (both NUL-terminated); preserves rdi
cstr_eq_local:
    push rdi
.l:
    mov al, [rdi]
    cmp al, [rsi]
    jne .no
    test al, al
    jz .yes
    inc rdi
    inc rsi
    jmp .l
.yes:
    mov eax, 1
    pop rdi
    ret
.no:
    xor eax, eax
    pop rdi
    ret

; ---- the upload spool (net.asm) --------------------------------------------

; media_spool_allowed(ctx, head_len, body_len) -> 1 if this request may
; stream its body to disk: a converter exists, the body is within
; MEDIA_BODY_MAX, the request line is "POST /admin/media[?...] " and the
; cookie names a live admin session.
media_spool_allowed:
    push r12
    push r13
    mov r12, rdi
    mov r13, rsi
    cmp byte [media_ready], 0
    je .no
    cmp rdx, MEDIA_BODY_MAX
    ja .no
    cmp r13, rl_media_len + 1
    jb .no
    lea rdi, [r12+CTX_IN]
    mov rsi, rl_media
    mov edx, rl_media_len
    call mem_eq
    test eax, eax
    jz .no
    mov al, [r12+CTX_IN+rl_media_len]
    cmp al, ' '
    je .line_ok
    cmp al, '?'
    jne .no
.line_ok:
    mov rdi, r12
    mov rsi, r13
    call admin_session_ok
    test eax, eax
    jz .no
    mov eax, 1
    jmp .ret
.no:
    xor eax, eax
.ret:
    pop r13
    pop r12
    ret

; media_spool_open(ctx) -> fd, or -1. Names data/media/up-<n>.tmp,
; records the fd and n in the context.
media_spool_open:
    push r12
    sub rsp, 64
    mov r12, rdi
    mov eax, 1
    lock xadd [up_seq], eax
    inc eax
    mov [r12+CTX_SPOOL_ID], eax
    mov edi, eax
    mov rsi, rsp
    mov rdx, sfx_tmp
    call up_path
    mov rdi, rsp
    mov esi, O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC
    mov edx, 0o600
    mov eax, SYS_open
    syscall
    mov [r12+CTX_SPOOL_FD], eax
    add rsp, 64
    pop r12
    ret

; media_spool_discard(ctx) — close and unlink the spool, if any.
media_spool_discard:
    push r12
    sub rsp, 64
    mov r12, rdi
    mov eax, [r12+CTX_SPOOL_FD]
    test eax, eax
    js .done
    mov edi, eax
    mov eax, SYS_close
    syscall
    mov dword [r12+CTX_SPOOL_FD], -1
    mov edi, [r12+CTX_SPOOL_ID]
    mov rsi, rsp
    mov rdx, sfx_tmp
    call up_path
    mov rdi, rsp
    mov eax, SYS_unlink
    syscall
.done:
    add rsp, 64
    pop r12
    ret

; ---- multipart/form-data ------------------------------------------------------

; part table filled by mp_parse: (ptr, len) pairs
%define MP_CSRF_P  0
%define MP_CSRF_L  8
%define MP_FILE_P  16
%define MP_FILE_L  24
%define MP_NAME_P  32
%define MP_NAME_L  40
%define MP_SIZE    48

; mp_boundary(ctx) -> rax = boundary ptr (0 none), rdx = length, from
; the request head's Content-Type (quotes around the value dropped).
mp_boundary:
    push r12
    push r13
    call hdr_block
    test rax, rax
    jz .no
    mov rdi, rax
    mov rsi, rdx
    mov rdx, h_ctype_lc
    mov ecx, 13
    call find_header
    test rax, rax
    jz .no
    mov r12, rax
    mov r13, rdx
    cmp r13, 19
    jb .no
    mov rdi, r12
    mov rsi, mp_multipart_lc
    mov edx, 19
    call ci_prefix
    test eax, eax
    jz .no
    mov rdi, r12
    mov rsi, r13
    mov rdx, mp_bnd
    mov ecx, 9
    call mem_find
    test rax, rax
    jz .no
    add rax, 9                  ; value start
    lea rcx, [r12+r13]          ; header end
    mov rdx, rcx
    sub rdx, rax                ; remaining
    test rdx, rdx
    jz .no
    cmp byte [rax], '"'
    jne .bare
    inc rax
    dec rdx
    xor ecx, ecx
.q:
    cmp rcx, rdx
    jae .len
    cmp byte [rax+rcx], '"'
    je .len
    inc rcx
    jmp .q
.bare:
    xor ecx, ecx
.b:
    cmp rcx, rdx
    jae .len
    mov r8b, [rax+rcx]
    cmp r8b, ';'
    je .len
    cmp r8b, ' '
    je .len
    inc rcx
    jmp .b
.len:
    test rcx, rcx
    jz .no
    cmp rcx, 70
    ja .no
    mov rdx, rcx
    jmp .ret
.no:
    xor eax, eax
    xor edx, edx
.ret:
    pop r13
    pop r12
    ret

; mp_parse(body_p, body_l, bnd_p, bnd_l, parts) -> 0 / -1
; Frame: [0..72) "\r\n--" + boundary (delimiter), [72] delim len,
;        [80] cursor, [88] end, [96] header start, [104] data start
mp_parse:
    push r12
    push r13
    push r14
    push r15
    push rbx
    push rbp
    sub rsp, 112
    mov r12, rdi
    mov r13, rsi
    mov rbx, r8                 ; parts
    mov word [rsp], 0x0A0D
    mov word [rsp+2], '--'
    lea rax, [rcx+4]
    mov [rsp+72], rax           ; delimiter length (with the CRLF)
    lea rdi, [rsp+4]
    mov rsi, rdx
    mov rdx, rcx
    call mem_copy
    mov rdi, rbx                ; absent parts read as (0, 0)
    mov ecx, MP_SIZE/8
    xor eax, eax
    rep stosq
    lea rax, [r12+r13]
    mov [rsp+88], rax           ; end
    ; the first delimiter has no CRLF before it: search for "--bnd"
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rsp+2]
    mov rcx, [rsp+72]
    sub rcx, 2
    call mem_find
    test rax, rax
    jz .bad
    mov rcx, [rsp+72]
    lea r14, [rax+rcx-2]        ; cursor: just past "--bnd"
.part:
    mov rax, [rsp+88]
    sub rax, r14
    cmp rax, 2
    jb .done
    cmp word [r14], '--'
    je .done                    ; closing delimiter
    cmp word [r14], 0x0A0D
    jne .bad
    add r14, 2
    mov [rsp+96], r14           ; headers
    mov rdi, r14
    mov rsi, [rsp+88]
    sub rsi, r14
    mov rdx, mp_crlf2
    mov ecx, 4
    call mem_find
    test rax, rax
    jz .bad
    lea r15, [rax+4]            ; data start
    mov [rsp+104], r15
    mov rdi, r15
    mov rsi, [rsp+88]
    sub rsi, r15
    mov rdx, rsp                ; "\r\n--bnd"
    mov rcx, [rsp+72]
    call mem_find
    test rax, rax
    jz .bad
    mov rbp, rax                ; data end
    ; which field? scan the part headers for name="..."
    mov rdi, [rsp+96]
    mov rsi, r15
    sub rsi, [rsp+96]           ; header block length (incl. CRLFCRLF)
    call mp_field_name          ; rax = name ptr (0 none), rdx = len
    test rax, rax
    jz .next
    cmp rdx, 4
    jne .chk_file
    cmp dword [rax], 'csrf'
    jne .chk_file
    mov [rbx+MP_CSRF_P], r15
    mov rax, rbp
    sub rax, r15
    mov [rbx+MP_CSRF_L], rax
    jmp .next
.chk_file:
    cmp rdx, 4
    jne .next
    cmp dword [rax], 'file'
    jne .next
    cmp qword [rbx+MP_FILE_P], 0
    jne .next                   ; first file part wins
    mov [rbx+MP_FILE_P], r15
    mov rax, rbp
    sub rax, r15
    mov [rbx+MP_FILE_L], rax
    mov rdi, [rsp+96]
    mov rsi, r15
    sub rsi, [rsp+96]
    call mp_file_name
    mov [rbx+MP_NAME_P], rax
    mov [rbx+MP_NAME_L], rdx
.next:
    mov r14, rbp
    add r14, [rsp+72]           ; past "\r\n--bnd"
    jmp .part
.done:
    xor eax, eax
    jmp .ret
.bad:
    mov rax, -1
.ret:
    add rsp, 112
    pop rbp
    pop rbx
    pop r15
    pop r14
    pop r13
    pop r12
    ret

; mp_attr(hdrs, len, key, klen) -> rax = value ptr (0 none), rdx = len:
; the quoted value after key (key includes the opening quote).
mp_attr:
    push r12
    push r13
    push r14
    mov r12, rdi
    mov r13, rsi
    mov r14, rcx                ; (mem_find clobbers r8-r11)
    call mem_find
    test rax, rax
    jz .no
    add rax, r14
    lea rcx, [r12+r13]
    xor edx, edx
.scan:
    lea rsi, [rax+rdx]
    cmp rsi, rcx
    jae .no
    cmp byte [rsi], '"'
    je .ret
    inc rdx
    jmp .scan
.no:
    xor eax, eax
    xor edx, edx
.ret:
    pop r14
    pop r13
    pop r12
    ret

; mp_field_name(hdrs, len) -> rax = the name="..." value (0 none),
; rdx = len. A hit that is really the tail of filename="..." is skipped.
mp_field_name:
    push r12
    push r13
    mov r12, rdi
    mov r13, rsi
.again:
    mov rdi, r12
    mov rsi, r13
    mov rdx, mp_name
    mov ecx, 6
    call mp_attr
    test rax, rax
    jz .ret
    lea rcx, [rax-6]            ; where name=" starts
    sub rcx, r12
    cmp rcx, 4
    jb .ret                     ; no room for a "file" prefix: genuine
    cmp dword [rax-10], 'file'
    jne .ret
    lea rcx, [rax+rdx+1]        ; past this value's closing quote
    lea rsi, [r12+r13]          ; window end
    sub rsi, rcx
    jb .none
    mov r13, rsi
    mov r12, rcx
    jmp .again
.none:
    xor eax, eax
    xor edx, edx
.ret:
    pop r13
    pop r12
    ret

; mp_file_name(hdrs, len) -> filename="..." value (0 none)
mp_file_name:
    mov rdx, mp_fname
    mov ecx, 10
    jmp mp_attr

; ---- upload ------------------------------------------------------------------

; image_kind(p, l) -> 1 if the leading bytes look like a raster image
; the converters understand (PNG, JPEG, GIF, WebP, TIFF, HEIF/AVIF), 0
; otherwise. The converter is the real check; this just refuses text
; and executables early.
image_kind:
    cmp rsi, 16
    jb .no
    cmp dword [rdi], 0x474E5089         ; \x89PNG
    je .yes
    mov eax, [rdi]
    and eax, 0xFFFFFF
    cmp eax, 0xFFD8FF                   ; JPEG SOI
    je .yes
    cmp dword [rdi], 'GIF8'
    je .yes
    cmp dword [rdi], 'RIFF'
    jne .tiff
    cmp dword [rdi+8], 'WEBP'
    je .yes
.tiff:
    cmp dword [rdi], 0x002A4949         ; II*\0
    je .yes
    cmp dword [rdi], 0x2A004D4D         ; MM\0*
    je .yes
    cmp dword [rdi+4], 'ftyp'           ; ISO BMFF: heic/heif/avif
    je .yes
.no:
    xor eax, eax
    ret
.yes:
    mov eax, 1
    ret

; png_dims(path_cstr) -> eax = width, edx = height, or eax = -1
png_dims:
    push r12
    sub rsp, 32
    mov esi, O_RDONLY | O_CLOEXEC
    mov eax, SYS_open
    syscall
    test rax, rax
    js .bad
    mov r12, rax
    mov rdi, rax
    mov rsi, rsp
    mov edx, 24
    xor r10d, r10d
    mov eax, SYS_pread64
    syscall
    mov r8, rax
    mov edi, r12d
    mov eax, SYS_close
    syscall
    cmp r8, 24
    jne .bad
    cmp dword [rsp], 0x474E5089
    jne .bad
    cmp dword [rsp+12], 'IHDR'
    jne .bad
    mov eax, [rsp+16]
    bswap eax
    mov edx, [rsp+20]
    bswap edx
    test eax, eax
    jz .bad
    test edx, edx
    jz .bad
    jmp .ret
.bad:
    mov eax, -1
.ret:
    add rsp, 32
    pop r12
    ret

; file_size(path_cstr) -> rax = st_size, or -1
file_size:
    push r12
    sub rsp, 144
    mov esi, O_RDONLY | O_CLOEXEC
    mov eax, SYS_open
    syscall
    test rax, rax
    js .bad
    mov r12, rax
    mov rdi, rax
    mov rsi, rsp
    mov eax, SYS_fstat
    syscall
    mov r8, rax
    mov edi, r12d
    mov eax, SYS_close
    syscall
    test r8, r8
    js .bad
    mov rax, [rsp+48]
    jmp .ret
.bad:
    mov rax, -1
.ret:
    add rsp, 144
    pop r12
    ret

; write_file(path_cstr, p, l) -> 0 / -1 (creates 0600, truncates)
write_file:
    push r12
    push r13
    push r14
    mov r13, rsi
    mov r14, rdx
    mov esi, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC
    mov edx, 0o600
    mov eax, SYS_open
    syscall
    test rax, rax
    js .bad
    mov r12, rax
    mov edi, eax
    mov rsi, r13
    mov rdx, r14
    call write_full
    mov r13, rax
    mov edi, r12d
    mov eax, SYS_close
    syscall
    mov rax, r13
    jmp .ret
.bad:
    mov rax, -1
.ret:
    pop r14
    pop r13
    pop r12
    ret

; media_upload(ctx, body_p, body_l, sess) -> eax = MU_* code, rdx = the
; new media id on MU_OK. The body is the multipart/form-data request
; body (buffered, or the mapped spool); sess is the session index for
; the csrf check.
; Frame: [0] parts (48) | [48] mstruct (64) | [112] path (80) |
;        [192] name buf (128) | [320] id, [328] upload n, [336] sess
%define U_PARTS 0
%define U_M     48
%define U_PATH  112
%define U_NAME  192
%define U_ID    320
%define U_UP    328
%define U_SESS  336
%define U_FRAME 352
media_upload:
    push r12
    push r13
    push r14
    push r15
    push rbx
    push rbp
    sub rsp, U_FRAME
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov [rsp+U_SESS], rcx
    mov qword [rsp+U_ID], 0
    cmp byte [media_ready], 0
    je .noconv
    mov rdi, r12
    call mp_boundary
    test rax, rax
    jz .badreq
    mov rdi, r13
    mov rsi, r14
    mov rcx, rdx                ; boundary length
    mov rdx, rax                ; boundary
    lea r8, [rsp+U_PARTS]
    call mp_parse
    test rax, rax
    jnz .badreq
    mov rdi, [rsp+U_SESS]
    mov rsi, [rsp+U_PARTS+MP_CSRF_P]
    mov rdx, [rsp+U_PARTS+MP_CSRF_L]
    call session_csrf_ok
    test eax, eax
    jz .badreq
    mov r15, [rsp+U_PARTS+MP_FILE_P]
    mov rbx, [rsp+U_PARTS+MP_FILE_L]
    test r15, r15
    jz .empty
    test rbx, rbx
    jz .empty
    cmp rbx, MEDIA_BODY_MAX
    ja .type
    mov rdi, r15
    mov rsi, rbx
    call image_kind
    test eax, eax
    jz .type
    ; the file part -> data/media/up-<n>.img
    mov eax, 1
    lock xadd [up_seq], eax
    inc eax
    mov [rsp+U_UP], rax
    mov edi, eax
    lea rsi, [rsp+U_PATH]
    mov rdx, sfx_img
    call up_path
    lea rdi, [rsp+U_PATH]
    mov rsi, r15
    mov rdx, rbx
    call write_file
    test rax, rax
    jnz .conv_fail
    call media_reserve_id
    mov [rsp+U_ID], rax
    mov edi, 1
    mov rsi, rax
    mov rdx, [rsp+U_UP]
    call media_convert
    mov rbp, rax
    lea rdi, [rsp+U_PATH]       ; the input is not needed any more
    mov eax, SYS_unlink
    syscall
    test rbp, rbp
    jnz .conv_fail
    ; measure what came out
    lea rdi, [rsp+U_M]
    mov ecx, M_SIZE/8
    xor eax, eax
    rep stosq
    mov rax, [rsp+U_ID]
    mov [rsp+U_M+M_ID], rax
    mov rdi, rax
    lea rsi, [rsp+U_PATH]
    mov rdx, sfx_png
    call media_path
    lea rdi, [rsp+U_PATH]
    call png_dims
    test eax, eax
    js .conv_fail
    mov [rsp+U_M+M_W], eax
    mov [rsp+U_M+M_H], edx
    lea rdi, [rsp+U_PATH]
    call file_size
    test rax, rax
    js .conv_fail
    mov [rsp+U_M+M_BPNG], eax
    mov rdi, [rsp+U_ID]
    lea rsi, [rsp+U_PATH]
    mov rdx, sfx_webp
    call media_path
    lea rdi, [rsp+U_PATH]
    call file_size
    test rax, rax
    js .conv_fail
    mov [rsp+U_M+M_BWEBP], eax
    ; the inline pair: keep it only when it is actually smaller
    mov rdi, [rsp+U_ID]
    lea rsi, [rsp+U_PATH]
    mov rdx, sfx_spng
    call media_path
    lea rdi, [rsp+U_PATH]
    call png_dims
    test eax, eax
    js .no_small
    cmp eax, [rsp+U_M+M_W]
    jae .no_small
    mov [rsp+U_M+M_SW], eax
    mov [rsp+U_M+M_SH], edx
    lea rdi, [rsp+U_PATH]
    call file_size
    test rax, rax
    js .no_small
    mov [rsp+U_M+M_BSPNG], eax
    mov rdi, [rsp+U_ID]
    lea rsi, [rsp+U_PATH]
    mov rdx, sfx_swebp
    call media_path
    lea rdi, [rsp+U_PATH]
    call file_size
    test rax, rax
    js .no_small
    mov [rsp+U_M+M_BSWEBP], eax
    jmp .sized
.no_small:
    mov dword [rsp+U_M+M_SW], 0
    mov dword [rsp+U_M+M_SH], 0
    mov dword [rsp+U_M+M_BSWEBP], 0
    mov dword [rsp+U_M+M_BSPNG], 0
    mov rdi, [rsp+U_ID]
    mov rsi, sfx_swebp
    call unlink_media
    mov rdi, [rsp+U_ID]
    mov rsi, sfx_spng
    call unlink_media
.sized:
    ; the original filename, sanitised (printable ASCII, no quotes or
    ; backslashes, <= MEDIA_NAME_MAX bytes)
    lea rdi, [rsp+U_NAME]
    mov rsi, [rsp+U_PARTS+MP_NAME_P]
    mov rdx, [rsp+U_PARTS+MP_NAME_L]
    call clean_name
    mov [rsp+U_M+M_NAME_L], rax
    lea rax, [rsp+U_NAME]
    mov [rsp+U_M+M_NAME_P], rax
    lea rdi, [rsp+U_M]
    call store_append_media
    test rax, rax
    js .store_fail
    mov rdx, rax
    mov eax, MU_OK
    jmp .ret
.store_fail:
    mov rdi, [rsp+U_ID]
    call unlink_all
    mov eax, MU_STORE
    jmp .ret
.conv_fail:
    mov rdi, [rsp+U_ID]
    test rdi, rdi
    jz .conv_code
    call unlink_all
.conv_code:
    mov eax, MU_CONV
    jmp .ret
.badreq:
    mov eax, MU_BADREQ
    jmp .ret
.type:
    mov eax, MU_TYPE
    jmp .ret
.empty:
    mov eax, MU_EMPTY
    jmp .ret
.noconv:
    mov eax, MU_NOCONV
.ret:
    add rsp, U_FRAME
    pop rbp
    pop rbx
    pop r15
    pop r14
    pop r13
    pop r12
    ret

; unlink_all(id) — every rendition of an id (failure cleanup)
unlink_all:
    push r12
    mov r12, rdi
    mov rsi, sfx_webp
    call unlink_media
    mov rdi, r12
    mov rsi, sfx_png
    call unlink_media
    mov rdi, r12
    mov rsi, sfx_swebp
    call unlink_media
    mov rdi, r12
    mov rsi, sfx_spng
    call unlink_media
    pop r12
    ret

; clean_name(dst, src, len) -> rax = length written: printable ASCII
; except " \ < > &, capped at MEDIA_NAME_MAX; a path is reduced to its
; last component.
clean_name:
    ; last component
    xor ecx, ecx
    mov r8, rsi
.comp:
    cmp rcx, rdx
    jae .have
    mov al, [rsi+rcx]
    cmp al, '/'
    je .cut
    cmp al, '\'
    jne .nc
.cut:
    lea r8, [rsi+rcx+1]
.nc:
    inc rcx
    jmp .comp
.have:
    lea rcx, [rsi+rdx]
    sub rcx, r8                 ; remaining length
    mov rsi, r8
    xor r8d, r8d
.copy:
    test rcx, rcx
    jz .done
    cmp r8, MEDIA_NAME_MAX
    jae .done
    mov al, [rsi]
    inc rsi
    dec rcx
    cmp al, 0x20
    jb .copy
    cmp al, 0x7e
    ja .copy
    cmp al, '"'
    je .copy
    cmp al, '\'
    je .copy
    cmp al, '<'
    je .copy
    cmp al, '>'
    je .copy
    cmp al, '&'
    je .copy
    mov [rdi+r8], al
    inc r8
    jmp .copy
.done:
    mov rax, r8
    ret

; media_lookup(id, out64) -> 1 and *out = the struct (name pointer
; included: arena memory, stable for the life of the process), or 0.
media_lookup:
    push r12
    push r13
    mov r12, rdi
    mov r13, rsi
    mov rdi, store_lock
    call rd_lock
    mov rdi, r12
    call media_find
    test rax, rax
    jz .miss
    mov rdi, r13
    mov rsi, rax
    mov edx, M_SIZE
    call mem_copy
    mov rdi, store_lock
    call rd_unlock
    mov eax, 1
    jmp .ret
.miss:
    mov rdi, store_lock
    call rd_unlock
    xor eax, eax
.ret:
    pop r13
    pop r12
    ret

; ---- GET /media/<name> ----------------------------------------------------

; page_media(ctx, name_p, name_l): <id>.webp | <id>.png | <id>-s.webp |
; <id>-s.png. A rendition never changes for its URL, so the ETag is the
; name and the cache policy is immutable.
page_media:
    push r12
    push r13
    push r14
    push r15
    push rbx
    push rbp
    sub rsp, 64 + 144 + 64      ; [0..64) path, [64..208) stat, [208..272) name
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    cmp r14, 24
    ja .notfound
    xor ecx, ecx
.digits:
    cmp rcx, r14
    jae .notfound
    mov al, [r13+rcx]
    sub al, '0'
    cmp al, 9
    ja .digits_end
    inc rcx
    cmp rcx, 9
    jbe .digits
    jmp .notfound
.digits_end:
    test rcx, rcx
    jz .notfound
    mov rbx, rcx                ; digit count
    ; the suffix, NUL-terminated for sfx_variant
    lea rdi, [rsp+208]
    lea rsi, [r13+rcx]
    mov rdx, r14
    sub rdx, rcx
    call mem_copy
    mov byte [rax], 0
    lea rdi, [rsp+208]
    call sfx_variant
    cmp rax, -1
    je .notfound
    mov r15, rax                ; variant
    mov rdi, r13
    mov rsi, rbx
    call parse_dec
    test rax, rax
    jz .notfound
    mov rbp, rax                ; id
    mov rdi, store_lock
    call rd_lock
    mov rdi, rbp
    call media_find
    test rax, rax
    jz .unlock_404
    cmp r15, 2
    jb .known
    cmp dword [rax+M_SW], 0
    je .unlock_404              ; no inline rendition for this one
.known:
    mov rax, [rax+M_CREATED]
    mov [r12+CTX_LM], rax
    mov rdi, store_lock
    call rd_unlock
    mov byte [r12+CTX_CACHE], CACHE_IMMUTABLE
    lea rdi, [r12+CTX_ETAG]
    mov byte [rdi], '"'
    inc rdi
    mov rsi, r13
    mov rdx, r14
    call mem_copy
    mov byte [rax], '"'
    lea rcx, [r14+2]
    mov [r12+CTX_ETAG_L], cl
    mov rdi, r12
    call inm_check
    test eax, eax
    jnz .notmod
    mov rdi, rbp
    mov rsi, rsp
    mov rdx, [sfx_tbl + r15*8]
    call media_path
    mov rdi, rsp
    mov esi, O_RDONLY | O_CLOEXEC
    mov eax, SYS_open
    syscall
    test rax, rax
    js .notfound
    mov rbx, rax                ; fd
    mov rdi, rax
    lea rsi, [rsp+64]
    mov eax, SYS_fstat
    syscall
    test rax, rax
    js .close_404
    mov r13, [rsp+64+48]        ; size
    test r13, r13
    jz .close_404
    xor r14d, r14d              ; mapping (none for HEAD)
    cmp byte [r12+CTX_HEAD], 0
    jne .mapped
    xor edi, edi
    mov rsi, r13
    mov edx, PROT_READ
    mov r10d, MAP_PRIVATE
    mov r8, rbx
    xor r9d, r9d
    mov eax, SYS_mmap
    syscall
    cmp rax, -4095
    jae .close_404
    mov r14, rax
.mapped:
    mov edi, ebx
    mov eax, SYS_close
    syscall
    mov rdi, r12
    mov rsi, r13
    mov rdx, ct_webp
    mov ecx, ct_webp_len
    test r15, 1
    jz .ct
    mov rdx, ct_png
    mov ecx, ct_png_len
.ct:
    mov r8, r14
    call finish_file
    jmp .done
.close_404:
    mov edi, ebx
    mov eax, SYS_close
    syscall
    jmp .notfound
.unlock_404:
    mov rdi, store_lock
    call rd_unlock
.notfound:
    mov rdi, r12
    mov esi, 2
    call build_page
    jmp .done
.notmod:
    mov rdi, r12
    call finish_304
.done:
    add rsp, 64 + 144 + 64
    pop rbp
    pop rbx
    pop r15
    pop r14
    pop r13
    pop r12
    ret

; finish_file(ctx, size, ctype_p, ctype_l, map_p) — headers only in the
; outbuf; the body is the mapped file (map_p = 0 for HEAD), which
; conn_flush sends after the headers and unmaps when done.
finish_file:
    push r12
    push r13
    push r14
    push r15
    push rbx
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
    mov rbx, r8
    lea rdi, [r12+CTX_OUT]
    push rdi
    mov rsi, f_200
    mov edx, f_200_len
    call mem_copy
    mov rdi, rax
    mov rsi, f_server
    mov edx, f_server_len
    call mem_copy
    mov rdi, rax
    mov rsi, [r12+CTX_LAST]
    call emit_date_hdr_at
    mov rdi, rax
    mov rsi, sec_headers
    mov edx, sec_headers_len
    call mem_copy
    cmp byte [r12+CTX_KEEP], 0
    je .cl
    mov rsi, f_ka
    mov edx, f_ka_len
    jmp .conn
.cl:
    mov rsi, f_cl
    mov edx, f_cl_len
.conn:
    mov rdi, rax
    call mem_copy
    mov rdi, rax
    mov rsi, r14
    mov rdx, r15
    call mem_copy
    mov rdi, rax
    mov rsi, r12
    call resp_headers
    mov rdi, rax
    mov rsi, f_clen
    mov edx, f_clen_len
    call mem_copy
    mov rdi, r13
    mov rsi, rax
    call u64_to_dec
    mov dword [rax], 0x0A0D0A0D
    add rax, 4
    pop rdi
    sub rax, rdi
    mov [r12+CTX_OUT_LEN], rax
    mov qword [r12+CTX_OUT_START], 0
    mov qword [r12+CTX_OUT_SENT], 0
    mov [r12+CTX_FILE_P], rbx
    mov [r12+CTX_FILE_L], r13
    mov qword [r12+CTX_FILE_SENT], 0
    pop rbx
    pop r15
    pop r14
    pop r13
    pop r12
    ret

section .data

p_mediadir: db 'data/media', 0
p_mediadir_s: db 'data/media/'
p_mediadir_s_len equ $-p_mediadir_s
p_up: db 'data/media/up-'
p_up_len equ $-p_up
sfx_none: db 0
sfx_tmp: db '.tmp', 0
sfx_img: db '.img', 0
sfx_webp: db '.webp', 0
sfx_png: db '.png', 0
sfx_swebp: db '-s.webp', 0
sfx_spng: db '-s.png', 0
alignb 8
sfx_tbl: dq sfx_webp, sfx_png, sfx_swebp, sfx_spng

env_imgconv: db 'BLOGD_IMGCONV', 0
p_self_exe: db '/proc/self/exe', 0
rel_imgconv: db '../tools/imgconv', 0
c_local: db 'tools/imgconv', 0
c_libexec: db '/usr/local/libexec/blogd-imgconv', 0
c_bin: db '/usr/local/bin/blogd-imgconv', 0
c_usrbin: db '/usr/bin/blogd-imgconv', 0
alignb 8
cand_tbl: dq c_local, c_libexec, c_bin, c_usrbin, 0
a_check: db '--check', 0

msg_ready: db 'media: image uploads enabled', 10
msg_ready_len equ $-msg_ready
msg_nobackend: db 'media: image uploads disabled: the converter found no backend ', \
    '(install vips-tools / libvips-tools, ImageMagick, or python3 + Pillow)', 10
msg_nobackend_len equ $-msg_nobackend
msg_noconv: db 'media: image uploads disabled: tools/imgconv not found ', \
    '(set BLOGD_IMGCONV, or run from the repo root)', 10
msg_noconv_len equ $-msg_noconv

rl_media: db 'POST /admin/media'
rl_media_len equ $-rl_media
h_ctype_lc: db 'content-type:'
mp_multipart_lc: db 'multipart/form-data'
mp_bnd: db 'boundary='
mp_crlf2: db 13, 10, 13, 10
mp_name: db 'name="'
mp_fname: db 'filename="'

f_200: db 'HTTP/1.1 200 OK', 13, 10
f_200_len equ $-f_200
f_server: db 'Server: blogd/0.12', 13, 10
f_server_len equ $-f_server
f_ka: db 'Connection: keep-alive', 13, 10
f_ka_len equ $-f_ka
f_cl: db 'Connection: close', 13, 10
f_cl_len equ $-f_cl
f_clen: db 'Content-Length: '
f_clen_len equ $-f_clen
ct_webp: db 'Content-Type: image/webp', 13, 10
ct_webp_len equ $-ct_webp
ct_png: db 'Content-Type: image/png', 13, 10
ct_png_len equ $-ct_png

section .bss

media_ready: resb 1
alignb 8
helper_fd:   resq 1
helper_lock: resd 1
up_seq:      resd 1
imgconv_path: resq 1
exe_buf:     resb 256
; helper process state (a private copy after fork)
h_job:    resb J_SIZE
h_reply:  resq 1
h_status: resd 1
alignb 8
h_argv:   resq 8
h_in:     resb 64
h_out:    resb 64
h_max:    resb 16
h_inl:    resb 16

section .note.GNU-stack noalloc noexec nowrite progbits
