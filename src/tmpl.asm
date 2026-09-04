; tmpl.asm — bounded writer, HTML escaping, {{marker}} templates.
;
; Templates are plain HTML files loaded once at startup and split into
; segments at {{name}} markers; names resolve against a fixed registry
; at load time (an unknown marker is a fatal startup error). Rendering
; is a walk over segments: emit literal, emit value. Values are HTML-
; escaped unless the marker is in RAW_MASK (values we generated
; ourselves as HTML: content, tags, html).
;
; The writer is a 24-byte {cur, end, overflow} block. Overflow never
; faults: emits become no-ops and the flag tells the handler to 500.

BITS 64
%include "src/sys.inc"

extern arena_create
extern arena_alloc
extern mem_copy
extern mem_eq
extern u64_to_dec
extern set_locale

global w_init
global emit
global emit_esc
global emit_json_esc
global emit_u64
global w_len
global w_ovf
global tmpl_load_all
global tmpl_render

%include "src/tmpl.inc"

%define MAX_SEGS   64

section .text

; w_init(w, start, end)
w_init:
    mov [rdi], rsi
    mov [rdi+8], rdx
    mov byte [rdi+16], 0
    ret

; w_len(w, start) -> bytes written since start
w_len:
    mov rax, [rdi]
    sub rax, rsi
    ret

; w_ovf(w) -> overflow flag
w_ovf:
    movzx eax, byte [rdi+16]
    ret

; emit(w, ptr, len)
emit:
    test rdx, rdx
    jz .done
    mov rax, [rdi]
    lea rcx, [rax+rdx]
    cmp rcx, [rdi+8]
    ja .ovf
    push rdi
    mov rdi, rax
    call mem_copy
    pop rdi
    mov [rdi], rax
.done:
    ret
.ovf:
    mov byte [rdi+16], 1
    ret

; emit_esc(w, ptr, len) — HTML-escape & < > " '
emit_esc:
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi                ; w
    mov r13, rsi                ; scan
    lea r14, [rsi+rdx]          ; end
    mov r15, rsi                ; run start
.scan:
    cmp r13, r14
    jae .flush_end
    mov al, [r13]
    cmp al, '&'
    je .special
    cmp al, '<'
    je .special
    cmp al, '>'
    je .special
    cmp al, '"'
    je .special
    cmp al, 0x27                ; '
    je .special
    inc r13
    jmp .scan
.special:
    mov rdx, r13
    sub rdx, r15
    jz .ent
    mov rdi, r12
    mov rsi, r15
    call emit
.ent:
    mov al, [r13]
    cmp al, '&'
    je .amp
    cmp al, '<'
    je .lt
    cmp al, '>'
    je .gt
    cmp al, '"'
    je .quot
    mov rsi, ent_apos
    mov edx, ent_apos_len
    jmp .emit_ent
.amp:
    mov rsi, ent_amp
    mov edx, ent_amp_len
    jmp .emit_ent
.lt:
    mov rsi, ent_lt
    mov edx, ent_lt_len
    jmp .emit_ent
.gt:
    mov rsi, ent_gt
    mov edx, ent_gt_len
    jmp .emit_ent
.quot:
    mov rsi, ent_quot
    mov edx, ent_quot_len
.emit_ent:
    mov rdi, r12
    call emit
    inc r13
    mov r15, r13
    jmp .scan
.flush_end:
    mov rdx, r13
    sub rdx, r15
    jz .done
    mov rdi, r12
    mov rsi, r15
    call emit
.done:
    pop r15
    pop r14
    pop r13
    pop r12
    ret

; emit_json_esc(w, ptr, len) — JSON string body: escapes " and \, and
; writes controls (< 0x20) plus '<' as \u00XX so the value is safe
; inside a <script type="application/ld+json"> data block.
emit_json_esc:
    push r12
    push r13
    push r14
    push r15
    sub rsp, 8
    mov r12, rdi
    mov r13, rsi
    lea r14, [rsi+rdx]
    mov r15, rsi                ; run start
.scan:
    cmp r13, r14
    jae .flush_end
    mov al, [r13]
    cmp al, '"'
    je .special
    cmp al, '\'
    je .special
    cmp al, '<'
    je .special
    cmp al, 0x20
    jb .special
    inc r13
    jmp .scan
.special:
    mov rdx, r13
    sub rdx, r15
    jz .ent
    mov rdi, r12
    mov rsi, r15
    call emit
.ent:
    mov al, [r13]
    cmp al, '"'
    je .bs
    cmp al, '\'
    jne .ctl
.bs:
    mov byte [rsp], '\'
    mov [rsp+1], al
    mov rdi, r12
    mov rsi, rsp
    mov edx, 2
    call emit
    jmp .adv
.ctl:
    mov dword [rsp], '\u00'
    movzx eax, al
    mov ecx, eax
    shr ecx, 4
    mov cl, [json_hex + rcx]
    mov [rsp+4], cl
    and eax, 15
    mov cl, [json_hex + rax]
    mov [rsp+5], cl
    mov rdi, r12
    mov rsi, rsp
    mov edx, 6
    call emit
.adv:
    inc r13
    mov r15, r13
    jmp .scan
.flush_end:
    mov rdx, r13
    sub rdx, r15
    jz .done
    mov rdi, r12
    mov rsi, r15
    call emit
.done:
    add rsp, 8
    pop r15
    pop r14
    pop r13
    pop r12
    ret

; emit_u64(w, value)
emit_u64:
    push r12
    mov r12, rdi
    sub rsp, 32
    mov rdi, rsi
    mov rsi, rsp
    call u64_to_dec
    mov rdx, rax
    sub rdx, rsp
    mov rdi, r12
    mov rsi, rsp
    call emit
    add rsp, 32
    pop r12
    ret

; tmpl_render(w, tmpl_id, vals)
; vals = array of NVALS (ptr,len) pairs
tmpl_render:
    push r12
    push r13
    push r14
    push r15
    push rbx
    mov r12, rdi                ; w
    mov r13, rdx                ; vals
    mov eax, [set_locale]       ; pick this locale's template set
    imul rax, rax, NTMPL
    add rsi, rax
    mov r14, [tmpl_segs + rsi*8]
    mov r15, [tmpl_nseg + rsi*8]
    xor ebx, ebx
.seg:
    cmp rbx, r15
    jae .done
    lea rax, [rbx+rbx*2]
    lea rax, [r14+rax*8]        ; seg = base + i*24
    mov rdi, r12
    mov rsi, [rax]
    mov rdx, [rax+8]
    push rax
    call emit
    pop rax
    mov rcx, [rax+16]           ; value id, -1 = none
    test rcx, rcx
    js .next
    shl rcx, 4
    mov rsi, [r13+rcx]          ; value ptr
    mov rdx, [r13+rcx+8]        ; value len
    test rdx, rdx
    jz .next
    shr rcx, 4
    mov rax, RAW_MASK
    bt rax, rcx                 ; 64-bit: ids past 31 stay correct
    jc .raw
    mov rdi, r12
    call emit_esc
    jmp .next
.raw:
    mov rdi, r12
    call emit
.next:
    inc rbx
    jmp .seg
.done:
    pop rbx
    pop r15
    pop r14
    pop r13
    pop r12
    ret

; tmpl_load_all() -> 0 / -1. Loads and parses every template file.
tmpl_load_all:
    push r12
    push r13
    mov edi, 0x100000           ; 1 MiB template arena
    call arena_create
    test rax, rax
    jz .fail
    mov [tmpl_arena], rax
    xor r12d, r12d              ; table index (all locales)
.next:
    cmp r12, NTMPL*NLOCALES
    jae .ok
    lea rax, [r12+r12*2]
    lea r13, [tmpl_files + rax*8]   ; {path, id, unused} x 3 qwords
    mov rdi, [r13]
    mov rsi, [r13+8]
    call tmpl_load_one
    test rax, rax
    jnz .fail
    inc r12
    jmp .next
.ok:
    xor eax, eax
    pop r13
    pop r12
    ret
.fail:
    mov rax, -1
    pop r13
    pop r12
    ret

; tmpl_load_one(path_cstr, tmpl_id) -> 0 / -1
tmpl_load_one:
    push r12
    push r13
    push r14
    push r15
    push rbx
    mov r14, rsi                ; tmpl id
    mov esi, O_RDONLY
    mov eax, SYS_open
    syscall
    test rax, rax
    js .fail
    mov r12, rax                ; fd
    sub rsp, 144
    mov rdi, rax
    mov rsi, rsp
    mov eax, SYS_fstat
    syscall
    mov r13, [rsp+48]           ; size
    add rsp, 144
    test rax, rax
    js .close_fail
    test r13, r13
    jz .close_fail
    mov rdi, [tmpl_arena]
    mov rsi, r13
    call arena_alloc
    test rax, rax
    jz .close_fail
    mov r15, rax                ; buf
    xor ebx, ebx                ; got
.rd:
    cmp rbx, r13
    jae .parse
    mov rdi, r12
    lea rsi, [r15+rbx]
    mov rdx, r13
    sub rdx, rbx
    xor eax, eax
    syscall
    cmp rax, 0
    jle .close_fail
    add rbx, rax
    jmp .rd
.parse:
    mov rdi, r12
    mov eax, SYS_close
    syscall
    ; segments array
    mov rdi, [tmpl_arena]
    mov esi, MAX_SEGS*24
    call arena_alloc
    test rax, rax
    jz .fail
    mov r12, rax                ; segs (fd no longer needed)
    xor ebx, ebx                ; nseg
    xor ecx, ecx                ; i
    xor edx, edx                ; lit_start
.scan:
    lea rax, [rcx+1]
    cmp rax, r13
    jae .tail_seg
    cmp word [r15+rcx], '{{'
    jne .adv
    ; find }}
    lea rsi, [rcx+2]            ; name start
.close:
    lea rax, [rsi+1]
    cmp rax, r13
    jae .fail                   ; unterminated marker
    cmp word [r15+rsi], '}}'
    je .found
    inc rsi
    jmp .close
.found:
    ; register segment: literal [lit_start, i) + value id
    cmp rbx, MAX_SEGS-1
    jae .fail
    push rcx
    push rdx
    push rsi
    ; resolve name [i+2, rsi)
    lea rdi, [r15+rcx+2]
    sub rsi, rcx
    sub rsi, 2                  ; name length
    call marker_lookup
    cmp rax, -1
    je .fail_pop3
    pop rsi
    pop rdx
    pop rcx
    lea rdi, [rbx+rbx*2]
    lea rdi, [r12+rdi*8]
    lea r8, [r15+rdx]
    mov [rdi], r8               ; lit ptr
    mov r8, rcx
    sub r8, rdx
    mov [rdi+8], r8             ; lit len
    mov [rdi+16], rax           ; value id
    inc rbx
    lea rcx, [rsi+2]            ; continue after }}
    mov rdx, rcx                ; new lit_start
    jmp .scan
.adv:
    inc rcx
    jmp .scan
.tail_seg:
    lea rdi, [rbx+rbx*2]
    lea rdi, [r12+rdi*8]
    lea r8, [r15+rdx]
    mov [rdi], r8
    mov r8, r13
    sub r8, rdx
    mov [rdi+8], r8
    mov qword [rdi+16], -1
    inc rbx
    mov [tmpl_segs + r14*8], r12
    mov [tmpl_nseg + r14*8], rbx
    xor eax, eax
    jmp .ret
.fail_pop3:
    pop rsi
    pop rdx
    pop rcx
    jmp .fail
.close_fail:
    mov rdi, r12
    mov eax, SYS_close
    syscall
.fail:
    mov rax, -1
.ret:
    pop rbx
    pop r15
    pop r14
    pop r13
    pop r12
    ret

; marker_lookup(name ptr, name len) -> value id or -1
marker_lookup:
    push r12
    push r13
    push r14
    mov r12, rdi
    mov r13, rsi
    xor r14d, r14d
.next:
    cmp r14, NVALS
    jae .no
    lea rax, [r14+r14*2]
    lea rax, [marker_names + rax*8]
    cmp r13, [rax+8]
    jne .skip
    mov rdi, r12
    mov rsi, [rax]
    mov rdx, r13
    call mem_eq
    test eax, eax
    jz .skip
    mov rax, r14
    jmp .ret
.skip:
    inc r14
    jmp .next
.no:
    mov rax, -1
.ret:
    pop r14
    pop r13
    pop r12
    ret

section .data

ent_amp:  db '&amp;'
ent_amp_len equ $-ent_amp
ent_lt:   db '&lt;'
ent_lt_len equ $-ent_lt
ent_gt:   db '&gt;'
ent_gt_len equ $-ent_gt
ent_quot: db '&quot;'
ent_quot_len equ $-ent_quot
ent_apos: db '&#39;'
ent_apos_len equ $-ent_apos
json_hex: db '0123456789abcdef'

n_site:    db 'site'
n_title:   db 'title'
n_content: db 'content'
n_url:     db 'url'
n_date:    db 'date'
n_tags:    db 'tags'
n_html:    db 'html'
n_meta:    db 'meta'
n_q:       db 'q'
n_heading: db 'heading'
n_excerpt: db 'excerpt'
n_id:      db 'id'
n_etitle:  db 'etitle'
n_eslug:   db 'eslug'
n_etags:   db 'etags'
n_emd:     db 'emd'
n_csrf:    db 'csrf'
n_err:     db 'err'
n_rows:    db 'rows'
n_esite:   db 'esite'
n_eppp:    db 'eppp'
n_banner:  db 'banner'
n_ebanner: db 'ebanner'
n_theme:   db 'theme'
n_selretro: db 'selretro'
n_selsucre: db 'selsucre'
n_selmde:   db 'selmedellin'
n_selbog:   db 'selbogota'
n_sellpb:   db 'sellapaz'
n_selcbb:   db 'selcochabamba'
n_selsrz:   db 'selsantacruz'
n_selen:    db 'selen'
n_seles:    db 'seles'
n_cssv:     db 'cssv'
n_eurl:     db 'eurl'
n_thcolor:  db 'themecolor'

align 8
marker_names:                   ; {ptr, len, pad} triplets, indexed by id
    dq n_site, 4, 0
    dq n_title, 5, 0
    dq n_content, 7, 0
    dq n_url, 3, 0
    dq n_date, 4, 0
    dq n_tags, 4, 0
    dq n_html, 4, 0
    dq n_meta, 4, 0
    dq n_q, 1, 0
    dq n_heading, 7, 0
    dq n_excerpt, 7, 0
    dq n_id, 2, 0
    dq n_etitle, 6, 0
    dq n_eslug, 5, 0
    dq n_etags, 5, 0
    dq n_emd, 3, 0
    dq n_csrf, 4, 0
    dq n_err, 3, 0
    dq n_rows, 4, 0
    dq n_esite, 5, 0
    dq n_eppp, 4, 0
    dq n_banner, 6, 0
    dq n_ebanner, 7, 0
    dq n_theme, 5, 0
    dq n_selretro, 8, 0
    dq n_selsucre, 8, 0
    dq n_selmde, 11, 0
    dq n_selbog, 9, 0
    dq n_sellpb, 8, 0
    dq n_selcbb, 13, 0
    dq n_selsrz, 12, 0
    dq n_selen, 5, 0
    dq n_seles, 5, 0
    dq n_cssv, 4, 0
    dq n_eurl, 4, 0
    dq n_thcolor, 10, 0

; one template set per locale; slot = locale*NTMPL + template id
f_shell:    db 'templates/en/shell.html', 0
f_card:     db 'templates/en/card.html', 0
f_post:     db 'templates/en/post.html', 0
f_listhead: db 'templates/en/listhead.html', 0
f_alogin:   db 'templates/en/admin_login.html', 0
f_adash:    db 'templates/en/admin_dash.html', 0
f_aedit:    db 'templates/en/admin_edit.html', 0
f_aset:     db 'templates/en/admin_settings.html', 0
f_aconf:    db 'templates/en/admin_confirm.html', 0
g_shell:    db 'templates/es/shell.html', 0
g_card:     db 'templates/es/card.html', 0
g_post:     db 'templates/es/post.html', 0
g_listhead: db 'templates/es/listhead.html', 0
g_alogin:   db 'templates/es/admin_login.html', 0
g_adash:    db 'templates/es/admin_dash.html', 0
g_aedit:    db 'templates/es/admin_edit.html', 0
g_aset:     db 'templates/es/admin_settings.html', 0
g_aconf:    db 'templates/es/admin_confirm.html', 0

tmpl_files:                     ; {path, slot, pad} triplets
    dq f_shell, T_SHELL, 0
    dq f_card, T_CARD, 0
    dq f_post, T_POST, 0
    dq f_listhead, T_LISTHEAD, 0
    dq f_alogin, T_ALOGIN, 0
    dq f_adash, T_ADASH, 0
    dq f_aedit, T_AEDIT, 0
    dq f_aset, T_ASET, 0
    dq f_aconf, T_ACONF, 0
    dq g_shell, NTMPL+T_SHELL, 0
    dq g_card, NTMPL+T_CARD, 0
    dq g_post, NTMPL+T_POST, 0
    dq g_listhead, NTMPL+T_LISTHEAD, 0
    dq g_alogin, NTMPL+T_ALOGIN, 0
    dq g_adash, NTMPL+T_ADASH, 0
    dq g_aedit, NTMPL+T_AEDIT, 0
    dq g_aset, NTMPL+T_ASET, 0
    dq g_aconf, NTMPL+T_ACONF, 0

section .bss

tmpl_arena: resq 1
tmpl_segs:  resq NTMPL*NLOCALES
tmpl_nseg:  resq NTMPL*NLOCALES

section .note.GNU-stack noalloc noexec nowrite progbits
