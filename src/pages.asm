; pages.asm — public-site page handlers.
;
; Every handler renders under the store's read lock (post/settings
; pointers are only stable while held), releases it once the body is
; fully rendered into the connection's outbuf, then finish_page()
; writes headers immediately in front of the body (Content-Length is
; only known after rendering — no memmove of big bodies).
;
; Overflow anywhere → 500 via the writer's sticky flag; never a fault.

BITS 64
%include "src/sys.inc"
%include "src/conn.inc"
%include "src/store.inc"
%include "src/tmpl.inc"
%include "src/i18n.inc"

extern rd_lock
extern rd_unlock
extern store_lock
extern posts_arr
extern posts_cnt
extern set_ppp
extern set_title_p
extern set_title_l
extern set_banner_p
extern set_banner_l
extern set_theme
extern set_locale
extern set_url
extern set_url_l
extern store_mtime
extern crc32c
extern put_hex
extern fmt_httpdate
extern emit_date_hdr
extern inm_check
extern mem_find
extern w_init
extern w_ovf
extern emit
extern emit_esc
extern emit_json_esc
extern emit_u64
extern tmpl_render
extern fmt_date
extern fmt_datetime
extern u64_to_dec
extern mem_copy
extern mem_eq
extern ci_find
extern build_page
extern arena_create
extern arena_alloc
extern sec_headers
extern sec_headers_len
extern i18n_get
extern fmt_date_local
extern md_excerpt

global page_list
global page_post
global page_feed
global page_static
global page_hits
global page_robots
global page_sitemap
global page_manifest
global load_static
global hits_init
global hits_p
global finish_page
global finish_304
global shell_vals
global theme_class
global theme_from_value

; ---- page_list frame (offsets derive from NVALS so the registry can
; grow without hand-renumbering) ------------------------------------------
%define L_PAGE    0
%define L_TAGP    8
%define L_TAGL    16
%define L_QP      24
%define L_QL      32
%define L_MODE    40            ; 0 home, 1 tag, 2 search
%define L_W       48            ; content writer (24)
%define L_BW      72            ; body writer (24)
%define L_VALS    96            ; NVALS * 16
%define L_TOTAL   (L_VALS + NVALS*16)
%define L_PPP     (L_TOTAL + 8)
%define L_START   (L_TOTAL + 16)
%define L_MIDX    (L_TOTAL + 24)
%define L_EMIT    (L_TOTAL + 32)
%define L_NPAGES  (L_TOTAL + 40)
%define L_URL     (L_TOTAL + 48) ; 160
%define L_DATE    (L_URL + 160)  ; 32 (localized long dates)
%define L_TAGB    (L_DATE + 32)  ; 512
%define L_TW      (L_TAGB + 512) ; 24
%define L_HEAD    (L_TW + 24)    ; 256
%define L_NUM     (L_HEAD + 256) ; 32
%define L_EXC     (L_NUM + 32)   ; 192 (excerpt cap 180)
%define L_TITLE   (L_EXC + 192)  ; 256 (composed page title)
%define L_FRAME   ((L_TITLE + 256 + 15) & -16)

; EMITS literal[, writer-reg] — emit a .data literal (label + _len)
%macro EMITS 1-2 r12
    mov rdi, %2
    mov rsi, %1
    mov edx, %1_len
    call emit
%endmacro

section .text

; page_list(ctx, page, tag_p, tag_l, q_p, q_l)
page_list:
    push r12
    push r13
    push r14
    push r15
    push rbx
    push rbp
    sub rsp, L_FRAME
    mov r12, rdi
    mov [rsp+L_PAGE], rsi
    mov [rsp+L_TAGP], rdx
    mov [rsp+L_TAGL], rcx
    mov [rsp+L_QP], r8
    mov [rsp+L_QL], r9
    xor eax, eax
    test rcx, rcx
    jz .m1
    mov eax, 1
.m1:
    test r8, r8
    jz .m2
    mov eax, 2
.m2:
    mov [rsp+L_MODE], rax
    mov byte [r12+CTX_CACHE], CACHE_REVALIDATE
    cmp byte [r12+CTX_INM], 0
    jne .notmod                 ; client holds this generation: no render

    mov rdi, store_lock
    call rd_lock

    mov eax, [set_ppp]
    cmp qword [rsp+L_MODE], 2
    jne .pppok
    mov eax, 50                 ; search: one page, up to 50 hits
    mov qword [rsp+L_PAGE], 1
.pppok:
    mov [rsp+L_PPP], rax

    ; pass 1: count matches
    xor ebx, ebx
    xor r13d, r13d
.count:
    cmp r13, [posts_cnt]
    jae .counted
    mov rax, [posts_arr]
    mov rdi, [rax+r13*8]
    mov rsi, [rsp+L_TAGP]
    mov rdx, [rsp+L_TAGL]
    mov rcx, [rsp+L_QP]
    mov r8, [rsp+L_QL]
    call match_post
    test eax, eax
    jz .cnext
    inc rbx
.cnext:
    inc r13
    jmp .count
.counted:
    mov [rsp+L_TOTAL], rbx
    mov rax, rbx
    add rax, [rsp+L_PPP]
    dec rax
    xor edx, edx
    div qword [rsp+L_PPP]
    test rax, rax
    jnz .havepages
    mov eax, 1
.havepages:
    mov [rsp+L_NPAGES], rax
    mov rcx, [rsp+L_PAGE]
    test rcx, rcx
    jz .notfound
    cmp rcx, rax
    ja .notfound
    dec rcx
    imul rcx, [rsp+L_PPP]
    mov [rsp+L_START], rcx

    ; content writer over the scratch region
    lea rdi, [rsp+L_W]
    lea rsi, [r12+CTX_OUT+CTX_SCRATCH_OFF]
    lea rdx, [r12+CTX_OUT+CTX_SCRATCH_END]
    call w_init
    lea rdi, [rsp+L_VALS]
    mov ecx, NVALS*2
    xor eax, eax
    rep stosq
    lea rdi, [rsp+L_VALS]
    call shell_vals

    ; heading panel for tag/search pages
    cmp qword [rsp+L_MODE], 0
    je .no_head
    cmp qword [rsp+L_MODE], 1
    jne .h_search
    mov edi, S_H_TAG
    call i18n_get
    mov rsi, rax
    lea rdi, [rsp+L_HEAD]
    call mem_copy
    mov rdi, rax
    mov rsi, [rsp+L_TAGP]
    mov rdx, [rsp+L_TAGL]
    call mem_copy
    jmp .h_done
.h_search:
    mov edi, S_H_SEARCH
    call i18n_get
    mov rsi, rax
    lea rdi, [rsp+L_HEAD]
    call mem_copy
    mov rdi, rax
    mov rsi, [rsp+L_QP]
    mov rdx, [rsp+L_QL]
    cmp rdx, 100
    jbe .h_qlen
    mov edx, 100
.h_qlen:
    call mem_copy
.h_done:
    lea rcx, [rsp+L_HEAD]
    sub rax, rcx
    mov [rsp+L_VALS+V_HEADING*16], rcx
    mov [rsp+L_VALS+V_HEADING*16+8], rax
    lea rdi, [rsp+L_W]
    mov esi, T_LISTHEAD
    lea rdx, [rsp+L_VALS]
    call tmpl_render
.no_head:

    ; pass 2: render the page's slice
    xor r13d, r13d
    mov qword [rsp+L_MIDX], 0
    mov qword [rsp+L_EMIT], 0
.loop:
    cmp r13, [posts_cnt]
    jae .after
    mov rax, [rsp+L_EMIT]
    cmp rax, [rsp+L_PPP]
    jae .after
    mov rax, [posts_arr]
    mov r14, [rax+r13*8]
    mov rdi, r14
    mov rsi, [rsp+L_TAGP]
    mov rdx, [rsp+L_TAGL]
    mov rcx, [rsp+L_QP]
    mov r8, [rsp+L_QL]
    call match_post
    test eax, eax
    jz .next
    mov rax, [rsp+L_MIDX]
    inc qword [rsp+L_MIDX]
    cmp rax, [rsp+L_START]
    jb .next
    ; title
    mov rax, [r14+P_TITLE_P]
    mov [rsp+L_VALS+V_TITLE*16], rax
    mov rax, [r14+P_TITLE_L]
    mov [rsp+L_VALS+V_TITLE*16+8], rax
    ; url = /post/slug
    lea rdi, [rsp+L_URL]
    mov rsi, s_posturl
    mov edx, 6
    call mem_copy
    mov rdi, rax
    mov rsi, [r14+P_SLUG_P]
    mov rdx, [r14+P_SLUG_L]
    cmp rdx, 128
    jbe .slug_ok
    mov edx, 128
.slug_ok:
    call mem_copy
    lea rcx, [rsp+L_URL]
    sub rax, rcx
    mov [rsp+L_VALS+V_URL*16], rcx
    mov [rsp+L_VALS+V_URL*16+8], rax
    ; date
    mov rdi, [r14+P_CREATED]
    lea rsi, [rsp+L_DATE]
    call fmt_date_local
    lea rcx, [rsp+L_DATE]
    sub rax, rcx
    mov [rsp+L_VALS+V_DATE*16], rcx
    mov [rsp+L_VALS+V_DATE*16+8], rax
    ; tags
    lea rdi, [rsp+L_TW]
    lea rsi, [rsp+L_TAGB]
    lea rdx, [rsi+512]
    call w_init
    lea rdi, [rsp+L_TW]
    mov rsi, [r14+P_TAGS_P]
    mov rdx, [r14+P_TAGS_L]
    call build_tags_html
    lea rcx, [rsp+L_TAGB]
    mov rax, [rsp+L_TW]
    sub rax, rcx
    mov [rsp+L_VALS+V_TAGS*16], rcx
    mov [rsp+L_VALS+V_TAGS*16+8], rax
    ; excerpt: plain-text synopsis (no embeds/markup), escaped by renderer
    lea rdi, [rsp+L_EXC]
    mov esi, 180
    mov rdx, [r14+P_MD_P]
    mov rcx, [r14+P_MD_L]
    call md_excerpt
    lea rcx, [rsp+L_EXC]
    mov [rsp+L_VALS+V_EXCERPT*16], rcx
    mov [rsp+L_VALS+V_EXCERPT*16+8], rax
    lea rdi, [rsp+L_W]
    mov esi, T_CARD
    lea rdx, [rsp+L_VALS]
    call tmpl_render
    inc qword [rsp+L_EMIT]
.next:
    inc r13
    jmp .loop
.after:
    cmp qword [rsp+L_TOTAL], 0
    jne .pager
    mov edi, S_EMPTY
    call i18n_get
    mov rsi, rax
    lea rdi, [rsp+L_W]
    call emit
.pager:
    cmp qword [rsp+L_MODE], 2
    je .content_done            ; search: no pager
    mov rax, [rsp+L_NPAGES]
    cmp rax, 1
    jbe .content_done
    lea rdi, [rsp+L_W]
    mov rsi, s_pgr_open
    mov edx, s_pgr_open_len
    call emit
    mov rax, [rsp+L_PAGE]
    cmp rax, 1
    jbe .no_newer
    lea rdi, [rsp+L_W]
    mov rsi, s_pgr_prev
    mov edx, s_pgr_prev_len
    call emit
    mov edi, S_NEWER
    call i18n_get
    mov r8, rax
    mov r9, rdx
    mov rax, [rsp+L_PAGE]
    lea rcx, [rax-1]
    lea rdi, [rsp+L_W]
    mov rsi, [rsp+L_TAGP]
    mov rdx, [rsp+L_TAGL]
    call pager_link
.no_newer:
    mov rax, [rsp+L_PAGE]
    cmp rax, [rsp+L_NPAGES]
    jae .no_older
    lea rdi, [rsp+L_W]
    mov rsi, s_pgr_next
    mov edx, s_pgr_next_len
    call emit
    mov edi, S_OLDER
    call i18n_get
    mov r8, rax
    mov r9, rdx
    mov rax, [rsp+L_PAGE]
    lea rcx, [rax+1]
    lea rdi, [rsp+L_W]
    mov rsi, [rsp+L_TAGP]
    mov rdx, [rsp+L_TAGL]
    call pager_link
.no_older:
    lea rdi, [rsp+L_W]
    mov rsi, s_pgr_close
    mov edx, s_pgr_close_len
    call emit
.content_done:
    lea rdi, [rsp+L_W]
    call w_ovf
    test eax, eax
    jnz .fail500
    ; shell values
    lea rax, [r12+CTX_OUT+CTX_SCRATCH_OFF]
    mov [rsp+L_VALS+V_CONTENT*16], rax
    mov rcx, [rsp+L_W]
    sub rcx, rax
    mov [rsp+L_VALS+V_CONTENT*16+8], rcx
    ; <head> block, appended to the scratch region after the content
    mov rax, [rsp+L_W]
    mov [rsp+L_VALS+V_META*16], rax
    lea rdi, [rsp+L_W]
    mov rsi, r12
    mov rdx, rsp
    call meta_list
    mov rax, [rsp+L_W]
    sub rax, [rsp+L_VALS+V_META*16]
    mov [rsp+L_VALS+V_META*16+8], rax
    lea rdi, [rsp+L_W]
    call w_ovf
    test eax, eax
    jnz .fail500
    ; title: "home", "home · page N", "#tag", "search: q"
    mov rax, [rsp+L_MODE]
    cmp rax, 1
    je .t_tag
    cmp rax, 2
    je .t_search
    mov edi, S_T_HOME
    call i18n_get
    lea rdi, [rsp+L_TITLE]
    mov rsi, rax
    call mem_copy
    cmp qword [rsp+L_PAGE], 1
    jbe .t_fin
    push rax
    mov edi, S_T_PAGE
    call i18n_get
    pop rdi
    mov rsi, rax
    call mem_copy
    mov rdi, [rsp+L_PAGE]
    mov rsi, rax
    call u64_to_dec
    jmp .t_fin
.t_tag:
    lea rdi, [rsp+L_TITLE]
    mov byte [rdi], '#'
    inc rdi
    mov rsi, [rsp+L_TAGP]
    mov rdx, [rsp+L_TAGL]
    call mem_copy
    jmp .t_fin
.t_search:
    mov edi, S_T_SEARCHQ
    call i18n_get
    lea rdi, [rsp+L_TITLE]
    mov rsi, rax
    call mem_copy
    mov rsi, [rsp+L_QP]
    mov rdx, [rsp+L_QL]
    cmp rdx, 100
    jbe .t_q
    mov edx, 100
.t_q:
    mov rdi, rax
    call mem_copy
.t_fin:
    lea rcx, [rsp+L_TITLE]
    sub rax, rcx
    mov [rsp+L_VALS+V_TITLE*16], rcx
    mov [rsp+L_VALS+V_TITLE*16+8], rax
    ; echo the query back into the search box (escaped by renderer)
    mov rax, [rsp+L_QP]
    test rax, rax
    jz .noq
    mov rcx, [rsp+L_QL]
    cmp rcx, 100
    jbe .qlen2
    mov ecx, 100
.qlen2:
    mov [rsp+L_VALS+V_Q*16], rax
    mov [rsp+L_VALS+V_Q*16+8], rcx
.noq:
    ; render shell into the body region
    lea rdi, [rsp+L_BW]
    lea rsi, [r12+CTX_OUT+CTX_BODY_OFF]
    lea rdx, [r12+CTX_OUT+CTX_BODY_END]
    call w_init
    lea rdi, [rsp+L_BW]
    mov esi, T_SHELL
    lea rdx, [rsp+L_VALS]
    call tmpl_render
    mov rax, [store_mtime]      ; validators, read under the lock
    mov [r12+CTX_LM], rax
    mov rdi, store_lock
    call rd_unlock
    lea rdi, [rsp+L_BW]
    call w_ovf
    test eax, eax
    jnz .fail500u
    lea rsi, [r12+CTX_OUT+CTX_BODY_OFF]
    mov rax, [rsp+L_BW]
    sub rax, rsi
    mov rdi, r12
    mov rsi, rax
    mov rdx, ct_html
    mov ecx, ct_html_len
    xor r8d, r8d
    xor r9d, r9d
    call finish_page
    jmp .done
.notmod:
    mov rdi, r12
    call finish_304
    jmp .done
.notfound:
    mov rdi, store_lock
    call rd_unlock
    mov rdi, r12
    mov esi, 2
    call build_page
    jmp .done
.fail500:
    mov rdi, store_lock
    call rd_unlock
.fail500u:
    mov rdi, r12
    mov esi, 5
    call build_page
.done:
    add rsp, L_FRAME
    pop rbp
    pop rbx
    pop r15
    pop r14
    pop r13
    pop r12
    ret

; list_path(w, tag_p, tag_l, page) — the canonical path of a list page:
; "/", "/page/N", "/tag/x", "/tag/x/page/N" (page 1 never says /page/1)
list_path:
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
    test r14, r14
    jz .notag
    EMITS s_tagbase
    mov rdi, r12
    mov rsi, r13
    mov rdx, r14
    call emit
    cmp r15, 1
    jbe .done
    jmp .paged
.notag:
    cmp r15, 1
    ja .paged
    EMITS s_slash
    jmp .done
.paged:
    EMITS s_pagebase
    mov rdi, r12
    mov rsi, r15
    call emit_u64
.done:
    pop r15
    pop r14
    pop r13
    pop r12
    ret

; pager_link(w, tag_p, tag_l, n, label_p, label_l) — the caller has
; already opened the anchor up to href="; this emits path">label</a>
pager_link:
    push r12
    push rbx
    push rbp
    mov r12, rdi
    mov rbx, r8
    mov rbp, r9
    call list_path
    EMITS s_pgr_b
    mov rdi, r12
    mov rsi, rbx
    mov rdx, rbp
    call emit
    EMITS s_pgr_c
    pop rbp
    pop rbx
    pop r12
    ret

; match_post(post, tag_p, tag_l, q_p, q_l) -> 1/0
match_post:
    test qword [rdi+P_FLAGS], FLAG_PUBLISHED
    jz .no
    test rdx, rdx
    jz .qcheck
    push rdi
    push rcx
    push r8
    mov rax, rdi
    mov rcx, rdx                ; tag len
    mov rdx, rsi                ; tag ptr
    mov rdi, [rax+P_TAGS_P]
    mov rsi, [rax+P_TAGS_L]
    call tag_in_list
    pop r8
    pop rcx
    pop rdi
    test eax, eax
    jz .no
.qcheck:
    test rcx, rcx
    jz .yes
    test r8, r8
    jz .yes                     ; empty query matches everything
    push rdi
    push rcx
    push r8
    mov rax, rdi
    mov rdx, rcx                ; needle ptr
    mov rcx, r8                 ; needle len
    mov rdi, [rax+P_TITLE_P]
    mov rsi, [rax+P_TITLE_L]
    call ci_find
    pop r8
    pop rcx
    pop rdi
    test eax, eax
    jnz .yes
    push rdi
    push rcx
    push r8
    mov rax, rdi
    mov rdx, rcx
    mov rcx, r8
    mov rdi, [rax+P_MD_P]
    mov rsi, [rax+P_MD_L]
    call ci_find
    pop r8
    pop rcx
    pop rdi
    test eax, eax
    jnz .yes
.no:
    xor eax, eax
    ret
.yes:
    mov eax, 1
    ret

; tag_in_list(list_p, list_l, tag_p, tag_l) -> 1/0 (comma-separated exact)
tag_in_list:
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
.seg:
    test r13, r13
    jz .no
    xor ecx, ecx
.fc:
    cmp rcx, r13
    jae .have
    cmp byte [r12+rcx], ','
    je .have
    inc rcx
    jmp .fc
.have:
    cmp rcx, r15
    jne .skip
    push rcx
    mov rdi, r12
    mov rsi, r14
    mov rdx, rcx
    call mem_eq
    pop rcx
    test eax, eax
    jnz .yes
.skip:
    lea rax, [rcx+1]
    cmp rax, r13
    ja .no
    add r12, rax
    sub r13, rax
    jmp .seg
.no:
    xor eax, eax
    jmp .ret
.yes:
    mov eax, 1
.ret:
    pop r15
    pop r14
    pop r13
    pop r12
    ret

; build_tags_html(w, tags_p, tags_l) — '<a class="tag" href="/tag/x">#x</a>'
; per valid [a-z0-9-] tag; invalid segments are skipped entirely.
build_tags_html:
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
.seg:
    test r14, r14
    jz .done
    xor ecx, ecx
.fc:
    cmp rcx, r14
    jae .have
    cmp byte [r13+rcx], ','
    je .have
    inc rcx
    jmp .fc
.have:
    mov r15, rcx
    test r15, r15
    jz .adv
    xor edx, edx
.val:
    cmp rdx, r15
    jae .valid
    mov al, [r13+rdx]
    cmp al, 'a'
    jb .chk09
    cmp al, 'z'
    jbe .okc
.chk09:
    cmp al, '0'
    jb .chkdash
    cmp al, '9'
    jbe .okc
.chkdash:
    cmp al, '-'
    jne .adv
.okc:
    inc rdx
    jmp .val
.valid:
    mov rdi, r12
    mov rsi, s_tag_a
    mov edx, s_tag_a_len
    call emit
    mov rdi, r12
    mov rsi, r13
    mov rdx, r15
    call emit
    mov rdi, r12
    mov rsi, s_tag_b
    mov edx, s_tag_b_len
    call emit
    mov rdi, r12
    mov rsi, r13
    mov rdx, r15
    call emit_esc
    mov rdi, r12
    mov rsi, s_tag_c
    mov edx, s_tag_c_len
    call emit
.adv:
    lea rax, [r15+1]
    cmp rax, r14
    ja .done
    add r13, rax
    sub r14, rax
    jmp .seg
.done:
    pop r15
    pop r14
    pop r13
    pop r12
    ret

; ---- page_post ---------------------------------------------------------
%define Q_W     0
%define Q_BW    24
%define Q_VALS  48              ; NVALS * 16
%define Q_DATE  (Q_VALS + NVALS*16)
%define Q_TAGB  (Q_DATE + 32)
%define Q_TW    (Q_TAGB + 512)
%define Q_NUM   (Q_TW + 24)
%define Q_DESC  (Q_NUM + 32)    ; 192 (meta description, cap 160)
%define Q_FRAME ((Q_DESC + 192 + 15) & -16)

; page_post(ctx, slug_p, slug_l)
page_post:
    push r12
    push r13
    push r14
    push r15
    push rbx
    push rbp
    sub rsp, Q_FRAME
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov byte [r12+CTX_CACHE], CACHE_REVALIDATE
    cmp byte [r12+CTX_INM], 0
    jne .notmod
    mov rdi, store_lock
    call rd_lock
    xor ebx, ebx
.find:
    cmp rbx, [posts_cnt]
    jae .notfound
    mov rax, [posts_arr]
    mov r15, [rax+rbx*8]
    test qword [r15+P_FLAGS], FLAG_PUBLISHED
    jz .fnext
    cmp r14, [r15+P_SLUG_L]
    jne .fnext
    mov rdi, [r15+P_SLUG_P]
    mov rsi, r13
    mov rdx, r14
    call mem_eq
    test eax, eax
    jnz .found
.fnext:
    inc rbx
    jmp .find
.found:
    lea rdi, [rsp+Q_W]
    lea rsi, [r12+CTX_OUT+CTX_SCRATCH_OFF]
    lea rdx, [r12+CTX_OUT+CTX_SCRATCH_END]
    call w_init
    lea rdi, [rsp+Q_VALS]
    mov ecx, NVALS*2
    xor eax, eax
    rep stosq
    lea rdi, [rsp+Q_VALS]
    call shell_vals
    ; title
    mov rax, [r15+P_TITLE_P]
    mov [rsp+Q_VALS+V_TITLE*16], rax
    mov rax, [r15+P_TITLE_L]
    mov [rsp+Q_VALS+V_TITLE*16+8], rax
    ; date
    mov rdi, [r15+P_CREATED]
    lea rsi, [rsp+Q_DATE]
    call fmt_date_local
    lea rcx, [rsp+Q_DATE]
    sub rax, rcx
    mov [rsp+Q_VALS+V_DATE*16], rcx
    mov [rsp+Q_VALS+V_DATE*16+8], rax
    ; tags
    lea rdi, [rsp+Q_TW]
    lea rsi, [rsp+Q_TAGB]
    lea rdx, [rsi+512]
    call w_init
    lea rdi, [rsp+Q_TW]
    mov rsi, [r15+P_TAGS_P]
    mov rdx, [r15+P_TAGS_L]
    call build_tags_html
    lea rcx, [rsp+Q_TAGB]
    mov rax, [rsp+Q_TW]
    sub rax, rcx
    mov [rsp+Q_VALS+V_TAGS*16], rcx
    mov [rsp+Q_VALS+V_TAGS*16+8], rax
    ; body html (raw)
    mov rax, [r15+P_HTML_P]
    mov [rsp+Q_VALS+V_HTML*16], rax
    mov rax, [r15+P_HTML_L]
    mov [rsp+Q_VALS+V_HTML*16+8], rax
    lea rdi, [rsp+Q_W]
    mov esi, T_POST
    lea rdx, [rsp+Q_VALS]
    call tmpl_render
    lea rdi, [rsp+Q_W]
    call w_ovf
    test eax, eax
    jnz .fail500
    ; shell
    lea rax, [r12+CTX_OUT+CTX_SCRATCH_OFF]
    mov [rsp+Q_VALS+V_CONTENT*16], rax
    mov rcx, [rsp+Q_W]
    sub rcx, rax
    mov [rsp+Q_VALS+V_CONTENT*16+8], rcx
    ; <head> block after the content: description from the markdown
    lea rdi, [rsp+Q_DESC]
    mov esi, 160
    mov rdx, [r15+P_MD_P]
    mov rcx, [r15+P_MD_L]
    call md_excerpt
    mov r8, rax
    mov rax, [rsp+Q_W]
    mov [rsp+Q_VALS+V_META*16], rax
    lea rdi, [rsp+Q_W]
    mov rsi, r12
    mov rdx, r15
    lea rcx, [rsp+Q_DESC]
    call meta_post
    mov rax, [rsp+Q_W]
    sub rax, [rsp+Q_VALS+V_META*16]
    mov [rsp+Q_VALS+V_META*16+8], rax
    lea rdi, [rsp+Q_W]
    call w_ovf
    test eax, eax
    jnz .fail500
    lea rdi, [rsp+Q_BW]
    lea rsi, [r12+CTX_OUT+CTX_BODY_OFF]
    lea rdx, [r12+CTX_OUT+CTX_BODY_END]
    call w_init
    lea rdi, [rsp+Q_BW]
    mov esi, T_SHELL
    lea rdx, [rsp+Q_VALS]
    call tmpl_render
    mov rax, [store_mtime]
    mov [r12+CTX_LM], rax
    mov rdi, store_lock
    call rd_unlock
    lea rdi, [rsp+Q_BW]
    call w_ovf
    test eax, eax
    jnz .fail500u
    lea rsi, [r12+CTX_OUT+CTX_BODY_OFF]
    mov rax, [rsp+Q_BW]
    sub rax, rsi
    mov rdi, r12
    mov rsi, rax
    mov rdx, ct_html
    mov ecx, ct_html_len
    xor r8d, r8d
    xor r9d, r9d
    call finish_page
    jmp .done
.notmod:
    mov rdi, r12
    call finish_304
    jmp .done
.notfound:
    mov rdi, store_lock
    call rd_unlock
    mov rdi, r12
    mov esi, 2
    call build_page
    jmp .done
.fail500:
    mov rdi, store_lock
    call rd_unlock
.fail500u:
    mov rdi, r12
    mov esi, 5
    call build_page
.done:
    add rsp, Q_FRAME
    pop rbp
    pop rbx
    pop r15
    pop r14
    pop r13
    pop r12
    ret

; ---- page_feed ---------------------------------------------------------
%define F_W     0
%define F_DATE  24              ; 32
%define F_EXC   56              ; 192 (excerpt cap 180)
%define F_FRAME 256

; page_feed(ctx) — Atom, latest 20 published posts. Links are absolute
; when the site URL (or Host) is known; ids stay the stable tag: URIs
; so configuring the URL later never duplicates entries in readers.
page_feed:
    push r12
    push r13
    push r14
    push r15
    push rbx
    sub rsp, F_FRAME
    mov r12, rdi
    mov byte [r12+CTX_CACHE], CACHE_FEED
    cmp byte [r12+CTX_INM], 0
    jne .notmod
    mov rdi, store_lock
    call rd_lock
    lea rdi, [rsp+F_W]
    lea rsi, [r12+CTX_OUT+CTX_BODY_OFF]
    lea rdx, [r12+CTX_OUT+CTX_BODY_END]
    call w_init
    lea rbx, [rsp+F_W]          ; writer for EMITS
    EMITS a_head1, rbx          ; <?xml ...><feed ... xml:lang="
    mov rsi, a_lang_en
    mov edx, a_lang_en_len
    cmp dword [set_locale], 1
    jne .lang
    mov rsi, a_lang_es
    mov edx, a_lang_es_len
.lang:
    mov rdi, rbx
    call emit
    EMITS a_head1b, rbx         ; "><title>
    call site_name
    mov rdi, rbx
    mov rsi, rax
    call emit_esc
    EMITS a_head2, rbx          ; </title><link rel="alternate" ... href="
    mov rdi, rbx
    mov rsi, r12
    call emit_base
    EMITS a_head2b, rbx         ; /"/><link rel="self" ... href="
    mov rdi, rbx
    mov rsi, r12
    call emit_base
    EMITS a_head2c, rbx         ; /feed.xml"/><id>tag:blogd:feed</id><updated>
    mov rdi, [store_mtime]
    lea rsi, [rsp+F_DATE]
    call fmt_datetime
    mov rdi, rbx
    lea rsi, [rsp+F_DATE]
    mov edx, 20
    call emit
    EMITS a_head3, rbx          ; </updated><author><name>
    call site_name
    mov rdi, rbx
    mov rsi, rax
    call emit_esc
    EMITS a_head3b, rbx         ; </name></author><generator>...</generator>
    mov rdi, r12
    call have_base
    test eax, eax
    jz .noicon
    EMITS a_icon, rbx           ; <icon>
    mov rdi, rbx
    mov rsi, r12
    call emit_base
    EMITS a_icon2, rbx          ; /static/icon-192.png?v=
    call theme_class
    mov rdi, rbx
    mov rsi, rax
    call emit
    EMITS a_icon3, rbx          ; </icon>
.noicon:
    xor r13d, r13d              ; index
    xor r14d, r14d              ; emitted
.loop:
    cmp r13, [posts_cnt]
    jae .tail
    cmp r14, 20
    jae .tail
    mov rax, [posts_arr]
    mov r15, [rax+r13*8]
    test qword [r15+P_FLAGS], FLAG_PUBLISHED
    jz .next
    EMITS a_e1, rbx             ; <entry><title>
    mov rdi, rbx
    mov rsi, [r15+P_TITLE_P]
    mov rdx, [r15+P_TITLE_L]
    call emit_esc
    EMITS a_e2, rbx             ; </title><link rel="alternate" type="text/html" href="
    mov rdi, rbx
    mov rsi, r12
    call emit_base
    EMITS m_postp, rbx          ; /post/
    mov rdi, rbx
    mov rsi, [r15+P_SLUG_P]
    mov rdx, [r15+P_SLUG_L]
    call emit
    EMITS a_e3, rbx             ; "/><id>tag:blogd:post-
    mov rdi, rbx
    mov rsi, [r15+P_ID]
    call emit_u64
    EMITS a_e4, rbx             ; </id><published>
    mov rdi, [r15+P_CREATED]
    lea rsi, [rsp+F_DATE]
    call fmt_datetime
    mov rdi, rbx
    lea rsi, [rsp+F_DATE]
    mov edx, 20
    call emit
    EMITS a_e4b, rbx            ; </published><updated>
    mov rdi, [r15+P_UPDATED]
    lea rsi, [rsp+F_DATE]
    call fmt_datetime
    mov rdi, rbx
    lea rsi, [rsp+F_DATE]
    mov edx, 20
    call emit
    EMITS a_e5, rbx             ; </updated>
    mov rdi, rbx                ; <category term="tag"/> per tag
    mov rsi, [r15+P_TAGS_P]
    mov rdx, [r15+P_TAGS_L]
    mov rcx, a_cat
    mov r8, a_cat_len
    mov r9, a_cat_c
    mov r10d, a_cat_c_len
    call emit_tag_list
    EMITS a_e5b, rbx            ; <summary type="text">
    lea rdi, [rsp+F_EXC]        ; plain-text summary, same rules as cards
    mov esi, 180
    mov rdx, [r15+P_MD_P]
    mov rcx, [r15+P_MD_L]
    call md_excerpt
    mov rdx, rax
    lea rsi, [rsp+F_EXC]
    mov rdi, rbx
    call emit_esc
    EMITS a_e6, rbx             ; </summary>
    cmp qword [r15+P_HTML_L], 16384   ; full content for normal-sized posts
    ja .nocontent
    EMITS a_e7, rbx             ; <content type="html">
    mov rdi, rbx
    mov rsi, [r15+P_HTML_P]
    mov rdx, [r15+P_HTML_L]
    call emit_esc
    EMITS a_e7b, rbx            ; </content>
.nocontent:
    EMITS a_e8, rbx             ; </entry>
    inc r14
.next:
    inc r13
    jmp .loop
.tail:
    EMITS a_tail, rbx
    mov rax, [store_mtime]
    mov [r12+CTX_LM], rax
    mov rdi, store_lock
    call rd_unlock
    lea rdi, [rsp+F_W]
    call w_ovf
    test eax, eax
    jnz .fail500
    lea rsi, [r12+CTX_OUT+CTX_BODY_OFF]
    mov rax, [rsp+F_W]
    sub rax, rsi
    mov rdi, r12
    mov rsi, rax
    mov rdx, ct_atom
    mov ecx, ct_atom_len
    xor r8d, r8d
    xor r9d, r9d
    call finish_page
    jmp .done
.notmod:
    mov rdi, r12
    call finish_304
    jmp .done
.fail500:
    mov rdi, r12
    mov esi, 5
    call build_page
.done:
    add rsp, F_FRAME
    pop rbx
    pop r15
    pop r14
    pop r13
    pop r12
    ret

; ---- static assets ------------------------------------------------------
; A fixed table of files under static/, loaded once at boot with their
; optional .gz/.br siblings (pre-compressed at build time). Each variant
; carries a strong ETag (crc32c of the bytes served).
%define ST_PATH   0             ; cstr "static/<name>"
%define ST_NAME   8             ; -> name part of ST_PATH
%define ST_NLEN   16
%define ST_CT     24            ; Content-Type header ptr/len
%define ST_CTL    32
%define ST_CACHE  40            ; default cache mode when unversioned
%define ST_P      48            ; plain
%define ST_L      56
%define ST_GZP    64
%define ST_GZL    72
%define ST_BRP    80
%define ST_BRL    88
%define ST_CRC    96            ; dword x3: plain, gz, br
%define ST_ALT    112           ; index of the first themed variant, or -1
                                ; (variants for themes 1..NTHEMES-1 follow
                                ; each other, so theme t is at ST_ALT+t-1)
%define ST_SIZE   120

; theme_tbl row layout (the table itself sits with the data below)
%define TH_CLASS   0
%define TH_CLASS_L 8
%define TH_VAL     16
%define TH_VAL_L   24
%define TH_MFBG    32           ; 7 bytes
%define TH_COLOR   40           ; 7 bytes
%define TH_HITBG   48           ; 7 bytes
%define TH_HITFG   56           ; 7 bytes
%define TH_SIZE    64
%define NSTATIC   (6 + 5*(NTHEMES-1))

; page_static(ctx, name_p, name_l)
page_static:
    push r12
    push r13
    push r14
    push r15
    push rbx
    push rbp
    mov r12, rdi
    xor ecx, ecx
.find:
    cmp rcx, NSTATIC
    jae .missing
    imul rax, rcx, ST_SIZE
    lea r13, [static_tbl + rax]
    cmp rdx, [r13+ST_NLEN]
    jne .next
    push rcx
    push rsi
    push rdx
    mov rdi, rsi
    mov rsi, [r13+ST_NAME]
    call mem_eq
    pop rdx
    pop rsi
    pop rcx
    test eax, eax
    jnz .found
.next:
    inc rcx
    jmp .find
.found:
    mov eax, [set_theme]        ; themed icons: swap in the theme's file
    test eax, eax
    jz .themed
    mov rax, [r13+ST_ALT]
    test rax, rax
    js .themed
    add eax, [set_theme]
    dec rax
    imul rax, rax, ST_SIZE
    lea rax, [static_tbl + rax]
    cmp qword [rax+ST_P], 0
    je .themed                  ; variant missing: keep the default
    mov r13, rax
.themed:
    mov r14, [r13+ST_P]
    test r14, r14
    jz .missing                 ; file absent at boot
    mov r15, [r13+ST_L]
    xor ebx, ebx                ; extra headers (Content-Encoding)
    xor ebp, ebp
    mov eax, [r13+ST_CRC]
    cmp byte [r12+CTX_CACHE], 0
    jne .cache_ok
    mov rcx, [r13+ST_CACHE]
    mov [r12+CTX_CACHE], cl
.cache_ok:
    cmp qword [r13+ST_GZL], 0
    jne .negotiable
    cmp qword [r13+ST_BRL], 0
    je .chosen
.negotiable:
    mov byte [r12+CTX_VARY], 1
    test byte [r12+CTX_GZIP], 2
    jz .try_gz
    cmp qword [r13+ST_BRL], 0
    je .try_gz
    mov r14, [r13+ST_BRP]
    mov r15, [r13+ST_BRL]
    mov rbx, x_br
    mov ebp, x_br_len
    mov eax, [r13+ST_CRC+8]
    jmp .chosen
.try_gz:
    test byte [r12+CTX_GZIP], 1
    jz .chosen
    cmp qword [r13+ST_GZL], 0
    je .chosen
    mov r14, [r13+ST_GZP]
    mov r15, [r13+ST_GZL]
    mov rbx, x_gzip
    mov ebp, x_gzip_len
    mov eax, [r13+ST_CRC+4]
.chosen:
    lea rsi, [r12+CTX_ETAG]
    mov byte [rsi], '"'
    inc rsi
    mov edi, eax
    mov edx, 8
    call put_hex
    mov byte [rax], '"'
    mov byte [r12+CTX_ETAG_L], 10
    mov rdi, r12
    call inm_check
    test eax, eax
    jnz .notmod
    lea rax, [r15+CTX_BODY_OFF+4096]
    cmp rax, CTX_BODY_END
    ja .toobig
    lea rdi, [r12+CTX_OUT+CTX_BODY_OFF]
    mov rsi, r14
    mov rdx, r15
    call mem_copy
    mov rdi, r12
    mov rsi, r15
    mov rdx, [r13+ST_CT]
    mov rcx, [r13+ST_CTL]
    mov r8, rbx
    mov r9, rbp
    call finish_page
    jmp .done
.notmod:
    mov rdi, r12
    call finish_304
    jmp .done
.missing:
    mov rdi, r12
    mov esi, 2
    call build_page
    jmp .done
.toobig:
    mov rdi, r12
    mov esi, 5
    call build_page
.done:
    pop rbp
    pop rbx
    pop r15
    pop r14
    pop r13
    pop r12
    ret

; ---- robots.txt / sitemap / manifest -------------------------------------

; page_robots(ctx)
page_robots:
    push r12
    push rbx
    sub rsp, 32
    mov r12, rdi
    mov byte [r12+CTX_CACHE], CACHE_REVALIDATE
    cmp byte [r12+CTX_INM], 0
    jne .notmod
    mov rdi, rsp
    lea rsi, [r12+CTX_OUT+CTX_BODY_OFF]
    lea rdx, [r12+CTX_OUT+CTX_BODY_END]
    call w_init
    mov rbx, rsp
    EMITS rb_txt, rbx
    mov rdi, r12
    call have_base
    test eax, eax
    jz .nomap
    EMITS rb_sitemap, rbx
    mov rdi, rbx
    mov rsi, r12
    call emit_base
    EMITS rb_sitemap2, rbx
.nomap:
    lea rsi, [r12+CTX_OUT+CTX_BODY_OFF]
    mov rax, [rsp]
    sub rax, rsi
    mov rdi, r12
    mov rsi, rax
    mov rdx, ct_text
    mov ecx, ct_text_len
    xor r8d, r8d
    xor r9d, r9d
    call finish_page
    jmp .done
.notmod:
    mov rdi, r12
    call finish_304
.done:
    add rsp, 32
    pop rbx
    pop r12
    ret

; page_manifest(ctx) — web app manifest named after the site
page_manifest:
    push r12
    push rbx
    sub rsp, 32
    mov r12, rdi
    mov byte [r12+CTX_CACHE], CACHE_REVALIDATE
    cmp byte [r12+CTX_INM], 0
    jne .notmod
    mov rdi, rsp
    lea rsi, [r12+CTX_OUT+CTX_BODY_OFF]
    lea rdx, [r12+CTX_OUT+CTX_BODY_END]
    call w_init
    mov rbx, rsp
    EMITS mf_1, rbx             ; {"name":"
    call site_name
    mov rdi, rbx
    mov rsi, rax
    call emit_json_esc
    EMITS mf_2, rbx             ; ","short_name":"
    call site_name
    mov rdi, rbx
    mov rsi, rax
    call emit_json_esc
    call theme_entry
    mov r13, rax
    EMITS mf_3, rbx             ; ","start_url":"/",...,"background_color":"
    lea rsi, [r13+TH_MFBG]
    mov edx, 7
    mov rdi, rbx
    call emit
    EMITS mf_4, rbx             ; ","theme_color":"
    lea rsi, [r13+TH_COLOR]
    mov edx, 7
    mov rdi, rbx
    call emit
    EMITS mf_5, rbx             ; ","icons":[{"src":"/static/icon-192.png?v=
    mov rsi, [r13+TH_CLASS]
    mov rdx, [r13+TH_CLASS_L]
    mov rdi, rbx
    call emit
    EMITS mf_6, rbx             ; ","sizes":"192x192",...,"src":"/static/icon-512.png?v=
    mov rsi, [r13+TH_CLASS]
    mov rdx, [r13+TH_CLASS_L]
    mov rdi, rbx
    call emit
    EMITS mf_7, rbx             ; ","sizes":"512x512","type":"image/png"}]}
    lea rsi, [r12+CTX_OUT+CTX_BODY_OFF]
    mov rax, [rsp]
    sub rax, rsi
    mov rdi, r12
    mov rsi, rax
    mov rdx, ct_manifest
    mov ecx, ct_manifest_len
    xor r8d, r8d
    xor r9d, r9d
    call finish_page
    jmp .done
.notmod:
    mov rdi, r12
    call finish_304
.done:
    add rsp, 32
    pop rbx
    pop r12
    ret

%define SM_PER 500              ; posts per sitemap file

; page_sitemap(ctx, n) — n = 0: /sitemap.xml (a urlset, or a sitemap
; index when there are more than SM_PER published posts); n >= 1:
; /sitemap-n.xml, the n-th slice. Needs the absolute site URL.
page_sitemap:
    push r12
    push r13
    push r14
    push r15
    push rbx
    push rbp
    sub rsp, 64                 ; [0..24) writer, [24] post idx, [32..64) date
    mov r12, rdi
    mov r13, rsi
    mov byte [r12+CTX_CACHE], CACHE_FEED
    mov rdi, r12
    call have_base
    test eax, eax
    jz .notfound
    cmp byte [r12+CTX_INM], 0
    jne .notmod
    mov rdi, store_lock
    call rd_lock
    xor r14d, r14d              ; published count
    xor ecx, ecx
.count:
    cmp rcx, [posts_cnt]
    jae .counted
    mov rax, [posts_arr]
    mov rax, [rax+rcx*8]
    test qword [rax+P_FLAGS], FLAG_PUBLISHED
    jz .cnext
    inc r14
.cnext:
    inc rcx
    jmp .count
.counted:
    mov rdi, rsp
    lea rsi, [r12+CTX_OUT+CTX_BODY_OFF]
    lea rdx, [r12+CTX_OUT+CTX_BODY_END]
    call w_init
    mov rbx, rsp
    test r13, r13
    jnz .slice
    cmp r14, SM_PER
    ja .index
    mov r13d, 1                 ; everything fits in one urlset
.slice:
    lea rax, [r13-1]
    imul r15, rax, SM_PER       ; first published index in this slice
    lea rbp, [r15+SM_PER]       ; one past the last
    cmp r13, 1
    je .in_range
    cmp r15, r14
    jae .notfound_unlock
.in_range:
    EMITS sm_open, rbx
    cmp r13, 1
    jne .posts
    EMITS sm_url_o, rbx
    mov rdi, rbx
    mov rsi, r12
    call emit_base
    EMITS s_slash, rbx
    EMITS sm_lastmod, rbx
    mov rdi, [store_mtime]
    lea rsi, [rsp+32]
    call fmt_datetime
    mov rdi, rbx
    lea rsi, [rsp+32]
    mov edx, 20
    call emit
    EMITS sm_url_c, rbx
.posts:
    xor r14d, r14d              ; published index seen so far
    mov qword [rsp+24], 0
.ploop:
    mov rcx, [rsp+24]
    cmp rcx, [posts_cnt]
    jae .close
    cmp r14, rbp
    jae .close
    mov rax, [posts_arr]
    mov r13, [rax+rcx*8]
    inc qword [rsp+24]
    test qword [r13+P_FLAGS], FLAG_PUBLISHED
    jz .ploop
    inc r14
    cmp r14, r15
    jbe .ploop                  ; before this slice
    EMITS sm_url_o, rbx
    mov rdi, rbx
    mov rsi, r12
    call emit_base
    EMITS m_postp, rbx
    mov rdi, rbx
    mov rsi, [r13+P_SLUG_P]
    mov rdx, [r13+P_SLUG_L]
    call emit
    EMITS sm_lastmod, rbx
    mov rdi, [r13+P_UPDATED]
    lea rsi, [rsp+32]
    call fmt_datetime
    mov rdi, rbx
    lea rsi, [rsp+32]
    mov edx, 20
    call emit
    EMITS sm_url_c, rbx
    jmp .ploop
.close:
    EMITS sm_close, rbx
    jmp .finish
.index:
    EMITS si_open, rbx
    lea rax, [r14+SM_PER-1]
    xor edx, edx
    mov ecx, SM_PER
    div rcx
    mov r15, rax                ; number of slices
    mov r13d, 1
.iloop:
    cmp r13, r15
    ja .iend
    EMITS si_item_o, rbx
    mov rdi, rbx
    mov rsi, r12
    call emit_base
    EMITS si_path, rbx
    mov rdi, rbx
    mov rsi, r13
    call emit_u64
    EMITS si_item_c, rbx
    inc r13
    jmp .iloop
.iend:
    EMITS si_close, rbx
.finish:
    mov rax, [store_mtime]
    mov [r12+CTX_LM], rax
    mov rdi, store_lock
    call rd_unlock
    mov rdi, rbx
    call w_ovf
    test eax, eax
    jnz .fail500
    lea rsi, [r12+CTX_OUT+CTX_BODY_OFF]
    mov rax, [rsp]
    sub rax, rsi
    mov rdi, r12
    mov rsi, rax
    mov rdx, ct_xml
    mov ecx, ct_xml_len
    xor r8d, r8d
    xor r9d, r9d
    call finish_page
    jmp .done
.notmod:
    mov rdi, r12
    call finish_304
    jmp .done
.notfound_unlock:
    mov rdi, store_lock
    call rd_unlock
.notfound:
    mov rdi, r12
    mov esi, 2
    call build_page
    jmp .done
.fail500:
    mov rdi, r12
    mov esi, 5
    call build_page
.done:
    add rsp, 64
    pop rbp
    pop rbx
    pop r15
    pop r14
    pop r13
    pop r12
    ret

; ---- <head> metadata ------------------------------------------------------

; site_name() -> rax = ptr, rdx = len (site title or the default)
site_name:
    mov rax, [set_title_p]
    mov rdx, [set_title_l]
    test rdx, rdx
    jnz .ok
    mov rax, def_site
    mov edx, def_site_len
.ok:
    ret

; have_base(ctx) -> 1 if an absolute site URL can be emitted
have_base:
    cmp qword [set_url_l], 0
    jne .yes
    cmp qword [rdi+CTX_HOST_L], 0
    jne .yes
    xor eax, eax
    ret
.yes:
    mov eax, 1
    ret

; emit_base(w, ctx) — the site origin: the configured URL, else the
; request's scheme (X-Forwarded-Proto) + validated Host; nothing if
; neither is known. No trailing slash.
emit_base:
    push r12
    push r13
    mov r12, rdi
    mov r13, rsi
    mov rdx, [set_url_l]
    test rdx, rdx
    jz .host
    mov rsi, set_url
    call emit
    jmp .done
.host:
    mov rdx, [r13+CTX_HOST_L]
    test rdx, rdx
    jz .done
    mov rsi, s_http
    mov edx, s_http_len
    cmp byte [r13+CTX_HTTPS], 0
    je .scheme
    mov rsi, s_https
    mov edx, s_https_len
.scheme:
    mov rdi, r12
    call emit
    mov rdi, r12
    mov rsi, [r13+CTX_HOST_P]
    mov rdx, [r13+CTX_HOST_L]
    call emit
.done:
    pop r13
    pop r12
    ret

; emit_tag_list(w, tags_p, tags_l, open_p, open_l, close_p, r10 = close_l)
; For every non-empty comma-separated tag: open, escaped tag, close.
emit_tag_list:
    push r12
    push r13
    push r14
    push r15
    push rbx
    push rbp
    sub rsp, 8
    mov [rsp], r10              ; close length
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
    mov rbx, r8
    mov rbp, r9
.seg:
    test r14, r14
    jz .done
    xor ecx, ecx
.fc:
    cmp rcx, r14
    jae .have
    cmp byte [r13+rcx], ','
    je .have
    inc rcx
    jmp .fc
.have:
    test rcx, rcx
    jz .adv
    push rcx
    mov rdi, r12
    mov rsi, r15
    mov rdx, rbx
    call emit
    mov rdi, r12
    mov rsi, r13
    mov rdx, [rsp]
    call emit_esc
    mov rdi, r12
    mov rsi, rbp
    mov rdx, [rsp+8]
    call emit
    pop rcx
.adv:
    lea rax, [rcx+1]
    cmp rax, r14
    ja .done
    add r13, rax
    sub r14, rax
    jmp .seg
.done:
    add rsp, 8
    pop rbp
    pop rbx
    pop r15
    pop r14
    pop r13
    pop r12
    ret

; emit_ogpng(w) — "/static/og.png?v=<theme class>": the card follows the
; theme, and the token makes caches and link unfurlers refetch it
emit_ogpng:
    push r12
    mov r12, rdi
    mov rsi, m_ogpng
    mov edx, m_ogpng_len
    call emit
    call theme_class
    mov rdi, r12
    mov rsi, rax
    call emit
    pop r12
    ret

; og_common(w, ctx) — og:site_name and og:locale
og_common:
    push r12
    mov r12, rdi
    EMITS m_ogsite
    call site_name
    mov rdi, r12
    mov rsi, rax
    call emit_esc
    EMITS m_end
    EMITS m_oglocale
    mov rsi, m_loc_en
    mov edx, m_loc_en_len
    cmp dword [set_locale], 1
    jne .loc
    mov rsi, m_loc_es
    mov edx, m_loc_es_len
.loc:
    mov rdi, r12
    call emit
    EMITS m_end
    pop r12
    ret

; meta_post(w, ctx, post, desc_p, desc_l) — the <head> block for a post:
; description, canonical, Open Graph / Twitter card, article times and
; tags, and a BlogPosting JSON-LD data block. Absolute-URL fields are
; omitted when no site URL is known; og:image is the first Flickr photo
; in the post, else the site card (which needs the absolute URL).
meta_post:
    push r12
    push r13
    push r14
    push r15
    push rbx
    push rbp
    sub rsp, 48                 ; [0..32) datetime, [32] img ptr, [40] img len
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
    mov rbx, r8
    EMITS m_desc
    mov rdi, r12
    mov rsi, r15
    mov rdx, rbx
    call emit_esc
    EMITS m_end
    mov rdi, r13
    call have_base
    test eax, eax
    jz .nocanon
    EMITS m_canon
    call .posturl
    EMITS m_end
    EMITS m_ogurl
    call .posturl
    EMITS m_end
.nocanon:
    EMITS m_ogarticle
    EMITS m_ogtitle
    mov rdi, r12
    mov rsi, [r14+P_TITLE_P]
    mov rdx, [r14+P_TITLE_L]
    call emit_esc
    EMITS m_end
    EMITS m_ogdesc
    mov rdi, r12
    mov rsi, r15
    mov rdx, rbx
    call emit_esc
    EMITS m_end
    mov rdi, r12
    mov rsi, r13
    call og_common
    mov qword [rsp+32], 0
    mov rdi, [r14+P_HTML_P]
    mov rsi, [r14+P_HTML_L]
    mov rdx, m_flhost
    mov ecx, m_flhost_len
    call mem_find
    test rax, rax
    jz .noflickr
    mov [rsp+32], rax
    mov rcx, [r14+P_HTML_P]
    add rcx, [r14+P_HTML_L]
    mov rdx, rax
.imglen:                        ; up to the closing quote
    cmp rdx, rcx
    jae .imgend
    cmp byte [rdx], '"'
    je .imgend
    inc rdx
    jmp .imglen
.imgend:
    sub rdx, rax
    mov [rsp+40], rdx
    EMITS m_ogimage
    mov rdi, r12
    mov rsi, [rsp+32]
    mov rdx, [rsp+40]
    call emit_esc
    EMITS m_end
    EMITS m_twlarge
    jmp .times
.noflickr:
    mov rdi, r13
    call have_base
    test eax, eax
    jz .twsmall
    EMITS m_ogimage
    mov rdi, r12
    mov rsi, r13
    call emit_base
    mov rdi, r12
    call emit_ogpng
    EMITS m_end
    EMITS m_twlarge
    jmp .times
.twsmall:
    EMITS m_twsmall
.times:
    EMITS m_pub
    mov rdi, [r14+P_CREATED]
    mov rsi, rsp
    call fmt_datetime
    mov rdi, r12
    mov rsi, rsp
    mov edx, 20
    call emit
    EMITS m_end
    EMITS m_mod
    mov rdi, [r14+P_UPDATED]
    mov rsi, rsp
    call fmt_datetime
    mov rdi, r12
    mov rsi, rsp
    mov edx, 20
    call emit
    EMITS m_end
    mov rdi, r12
    mov rsi, [r14+P_TAGS_P]
    mov rdx, [r14+P_TAGS_L]
    mov rcx, m_ogtag
    mov r8, m_ogtag_len
    mov r9, m_end
    mov r10d, m_end_len
    call emit_tag_list
    ; JSON-LD
    EMITS j_post1
    mov rdi, r12
    mov rsi, [r14+P_TITLE_P]
    mov rdx, [r14+P_TITLE_L]
    call emit_json_esc
    EMITS j_desc
    mov rdi, r12
    mov rsi, r15
    mov rdx, rbx
    call emit_json_esc
    EMITS j_pub
    mov rdi, [r14+P_CREATED]
    mov rsi, rsp
    call fmt_datetime
    mov rdi, r12
    mov rsi, rsp
    mov edx, 20
    call emit
    EMITS j_mod
    mov rdi, [r14+P_UPDATED]
    mov rsi, rsp
    call fmt_datetime
    mov rdi, r12
    mov rsi, rsp
    mov edx, 20
    call emit
    mov rdi, r13
    call have_base
    test eax, eax
    jz .jnourl
    EMITS j_url
    call .posturl
    EMITS j_main
    call .posturl
.jnourl:
    cmp qword [rsp+32], 0
    je .jimg_default
    EMITS j_img
    mov rdi, r12
    mov rsi, [rsp+32]
    mov rdx, [rsp+40]
    call emit_json_esc
    jmp .jauthor
.jimg_default:
    mov rdi, r13
    call have_base
    test eax, eax
    jz .jauthor
    EMITS j_img
    mov rdi, r12
    mov rsi, r13
    call emit_base
    mov rdi, r12
    call emit_ogpng
.jauthor:
    EMITS j_author
    call site_name
    mov rdi, r12
    mov rsi, rax
    call emit_json_esc
    EMITS j_publisher
    call site_name
    mov rdi, r12
    mov rsi, rax
    call emit_json_esc
    EMITS j_end
    add rsp, 48
    pop rbp
    pop rbx
    pop r15
    pop r14
    pop r13
    pop r12
    ret
.posturl:                       ; base + /post/ + slug
    mov rdi, r12
    mov rsi, r13
    call emit_base
    EMITS m_postp
    mov rdi, r12
    mov rsi, [r14+P_SLUG_P]
    mov rdx, [r14+P_SLUG_L]
    call emit
    ret

; meta_list(w, ctx, frame) — the <head> block for list pages; frame is
; page_list's stack frame (L_MODE, L_TAGP/L, L_PAGE, L_NPAGES).
; Search results are noindex; the front page also carries a WebSite
; JSON-LD block with the search action.
meta_list:
    push r12
    push r13
    push r14
    push r15
    push rbx
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    cmp qword [r14+L_MODE], 2
    jne .indexable
    EMITS m_noindex
    jmp .done
.indexable:
    EMITS m_desc
    call .desc
    EMITS m_end
    mov rdi, r13
    call have_base
    test eax, eax
    jz .nocanon
    EMITS m_canon
    call .listurl_abs
    EMITS m_end
    EMITS m_ogurl
    call .listurl_abs
    EMITS m_end
.nocanon:
    mov rax, [r14+L_PAGE]
    cmp rax, 1
    jbe .noprev
    EMITS m_prev
    mov rcx, [r14+L_PAGE]
    dec rcx
    call .listpath_n
    EMITS m_end
.noprev:
    mov rax, [r14+L_PAGE]
    cmp rax, [r14+L_NPAGES]
    jae .nonext
    EMITS m_next
    mov rcx, [r14+L_PAGE]
    inc rcx
    call .listpath_n
    EMITS m_end
.nonext:
    EMITS m_ogwebsite
    EMITS m_ogtitle
    call .ogtitle
    EMITS m_end
    EMITS m_ogdesc
    call .desc
    EMITS m_end
    mov rdi, r12
    mov rsi, r13
    call og_common
    mov rdi, r13
    call have_base
    test eax, eax
    jz .twsmall
    EMITS m_ogimage
    mov rdi, r12
    mov rsi, r13
    call emit_base
    mov rdi, r12
    call emit_ogpng
    EMITS m_end
    EMITS m_twlarge
    cmp qword [r14+L_MODE], 0
    jne .done
    cmp qword [r14+L_PAGE], 1
    jne .done
    EMITS j_site1
    call site_name
    mov rdi, r12
    mov rsi, rax
    call emit_json_esc
    EMITS j_site2
    mov rdi, r12
    mov rsi, r13
    call emit_base
    EMITS j_site3
    mov rdi, r12
    mov rsi, r13
    call emit_base
    EMITS j_site4
    jmp .done
.twsmall:
    EMITS m_twsmall
.done:
    pop rbx
    pop r15
    pop r14
    pop r13
    pop r12
    ret
.desc:                          ; "Latest posts from SITE" / "Posts tagged #x on SITE"
    cmp qword [r14+L_MODE], 1
    je .desc_tag
    mov edi, S_D_HOME
    call i18n_get
    mov rdi, r12
    mov rsi, rax
    call emit
    jmp .desc_site
.desc_tag:
    mov edi, S_D_TAG
    call i18n_get
    mov rdi, r12
    mov rsi, rax
    call emit
    mov rdi, r12
    mov rsi, [r14+L_TAGP]
    mov rdx, [r14+L_TAGL]
    call emit_esc
    mov edi, S_D_ON
    call i18n_get
    mov rdi, r12
    mov rsi, rax
    call emit
.desc_site:
    call site_name
    mov rdi, r12
    mov rsi, rax
    call emit_esc
    ret
.ogtitle:                       ; SITE, or "#tag · SITE"
    cmp qword [r14+L_MODE], 1
    jne .desc_site
    EMITS s_hash
    mov rdi, r12
    mov rsi, [r14+L_TAGP]
    mov rdx, [r14+L_TAGL]
    call emit_esc
    EMITS s_dot
    jmp .desc_site
.listurl_abs:
    mov rdi, r12
    mov rsi, r13
    call emit_base
    mov rcx, [r14+L_PAGE]
.listpath_n:                    ; rcx = page number
    mov rdi, r12
    mov rsi, [r14+L_TAGP]
    mov rdx, [r14+L_TAGL]
    jmp list_path

; page_hits(ctx) — the visitor counter as a tiny no-store SVG, so the
; HTML pages stay byte-stable (and therefore cacheable). GET bumps the
; persistent counter; HEAD only peeks.
page_hits:
    push r12
    push rbx
    sub rsp, 64                 ; [0..32) digits, [32..56) writer
    mov r12, rdi
    mov byte [r12+CTX_CACHE], CACHE_NOSTORE
    mov byte [r12+CTX_ETAG_L], 0
    mov rax, [hits_p]
    cmp byte [r12+CTX_HEAD], 0
    jne .peek
    mov ecx, 1
    lock xadd [rax], rcx
    lea rbx, [rcx+1]
    jmp .fmt
.peek:
    mov rbx, [rax]
.fmt:
    mov rdi, rbx
    mov rsi, rsp
    call u64_to_dec
    mov rbx, rax
    sub rbx, rsp                ; digit count
    lea rdi, [rsp+32]
    lea rsi, [r12+CTX_OUT+CTX_BODY_OFF]
    lea rdx, [r12+CTX_OUT+CTX_BODY_END]
    call w_init
    lea rdi, [rsp+32]
    mov rsi, svg1
    mov edx, svg1_len
    call emit
    mov rax, rbx                ; width: 8px cells, at least 6 digits
    cmp rax, 6
    jae .wide
    mov eax, 6
.wide:
    lea rcx, [rax*8+8]
    push rcx
    lea rdi, [rsp+40]
    mov rsi, rcx
    call emit_u64
    lea rdi, [rsp+40]
    mov rsi, svg2
    mov edx, svg2_len
    call emit
    pop rsi
    lea rdi, [rsp+32]
    call emit_u64
    call theme_entry
    push rax
    lea rdi, [rsp+40]
    mov rsi, svg3a
    mov edx, svg3a_len
    call emit
    mov rax, [rsp]
    lea rdi, [rsp+40]
    lea rsi, [rax+TH_HITBG]
    mov edx, 7
    call emit
    lea rdi, [rsp+40]
    mov rsi, svg3b
    mov edx, svg3b_len
    call emit
    mov rax, [rsp]
    lea rdi, [rsp+40]
    lea rsi, [rax+TH_HITFG]
    mov edx, 7
    call emit
    lea rdi, [rsp+40]
    mov rsi, svg3c
    mov edx, svg3c_len
    call emit
    pop rax
    mov rcx, 6                  ; zero-pad to six digits
    sub rcx, rbx
    jle .digits
.zero:
    push rcx
    lea rdi, [rsp+40]
    mov rsi, svg_zero
    mov edx, 1
    call emit
    pop rcx
    dec rcx
    jnz .zero
.digits:
    lea rdi, [rsp+32]
    mov rsi, rsp
    mov rdx, rbx
    call emit
    lea rdi, [rsp+32]
    mov rsi, svg4
    mov edx, svg4_len
    call emit
    lea rsi, [r12+CTX_OUT+CTX_BODY_OFF]
    mov rax, [rsp+32]
    sub rax, rsi
    mov rdi, r12
    mov rsi, rax
    mov rdx, ct_svg
    mov ecx, ct_svg_len
    xor r8d, r8d
    xor r9d, r9d
    call finish_page
    add rsp, 64
    pop rbx
    pop r12
    ret

; hits_init() — map data/hits.blg, the persistent visitor counter
; (16-byte header 'HIT1' | reserved | qword count, in a 4 KiB file).
; The page is MAP_SHARED, so `lock xadd` on it is the whole write path:
; the kernel writes the dirty page back itself, even if blogd is killed.
; Never fatal: on any failure the counter is process-local instead.
hits_init:
    push r12
    push r13
    mov qword [hits_p], hits_local
    mov rdi, f_hits
    mov esi, O_RDWR | O_CREAT
    mov edx, 0o600
    mov eax, SYS_open
    syscall
    test rax, rax
    js .ret
    mov r12, rax
    sub rsp, 144
    mov rdi, r12
    mov rsi, rsp
    mov eax, SYS_fstat
    syscall
    mov r13, [rsp+48]
    add rsp, 144
    test rax, rax
    js .close
    cmp r13, 4096
    jae .map
    mov rdi, r12
    mov esi, 4096
    mov eax, SYS_ftruncate
    syscall
    test rax, rax
    js .close
.map:
    xor edi, edi
    mov esi, 4096
    mov edx, PROT_READ | PROT_WRITE
    mov r10d, MAP_SHARED
    mov r8, r12
    xor r9d, r9d
    mov eax, SYS_mmap
    syscall
    cmp rax, -4095
    jae .close
    cmp dword [rax], 'HIT1'
    je .good
    mov dword [rax], 'HIT1'     ; fresh (or corrupt) file: start at 0
    mov dword [rax+4], 0
    mov qword [rax+8], 0
.good:
    lea rcx, [rax+8]
    mov [hits_p], rcx
.close:
    mov rdi, r12
    mov eax, SYS_close
    syscall
.ret:
    pop r13
    pop r12
    ret

; path_sfx(dst, path_cstr, sfx_cstr) — dst = path + sfx, NUL-terminated
path_sfx:
.p:
    mov al, [rsi]
    test al, al
    jz .s
    mov [rdi], al
    inc rdi
    inc rsi
    jmp .p
.s:
    mov al, [rdx]
    mov [rdi], al
    inc rdi
    inc rdx
    test al, al
    jnz .s
    ret

; load_static() -> 0 / -1. Loads every table entry (main.css required,
; the rest optional) plus .gz/.br siblings, records crc32c validators,
; and derives the stylesheet version token for cache busting.
load_static:
    push r12
    push r13
    push r14
    sub rsp, 64                 ; sibling path scratch
    mov edi, 0x100000
    call arena_create
    test rax, rax
    jz .fail
    mov r12, rax
    xor r13d, r13d
.ent:
    cmp r13, NSTATIC
    jae .ok
    imul rax, r13, ST_SIZE
    lea r14, [static_tbl + rax]
    mov rdi, [r14+ST_PATH]
    mov rsi, r12
    lea rdx, [r14+ST_P]
    lea rcx, [r14+ST_L]
    call load_file
    test rax, rax
    jz .loaded
    test r13, r13
    jz .fail                    ; main.css is required
    jmp .nextent
.loaded:
    mov rdi, [r14+ST_P]
    mov rsi, [r14+ST_L]
    call crc32c
    mov [r14+ST_CRC], eax
    mov rdi, rsp
    mov rsi, [r14+ST_PATH]
    mov rdx, sfx_gz
    call path_sfx
    mov rdi, rsp
    mov rsi, r12
    lea rdx, [r14+ST_GZP]
    lea rcx, [r14+ST_GZL]
    call load_file
    test rax, rax
    jnz .nogz
    mov rdi, [r14+ST_GZP]
    mov rsi, [r14+ST_GZL]
    call crc32c
    mov [r14+ST_CRC+4], eax
.nogz:
    mov rdi, rsp
    mov rsi, [r14+ST_PATH]
    mov rdx, sfx_br
    call path_sfx
    mov rdi, rsp
    mov rsi, r12
    lea rdx, [r14+ST_BRP]
    lea rcx, [r14+ST_BRL]
    call load_file
    test rax, rax
    jnz .nextent
    mov rdi, [r14+ST_BRP]
    mov rsi, [r14+ST_BRL]
    call crc32c
    mov [r14+ST_CRC+8], eax
.nextent:
    inc r13
    jmp .ent
.ok:
    mov edi, [static_tbl + ST_CRC]  ; main.css version token
    mov rsi, css_ver
    mov edx, 8
    call put_hex
    xor eax, eax
    jmp .ret
.fail:
    mov rax, -1
.ret:
    add rsp, 64
    pop r14
    pop r13
    pop r12
    ret

; load_file(path_cstr, arena, out_ptr_addr, out_len_addr) -> 0 / -1
load_file:
    push r12
    push r13
    push r14
    push r15
    push rbx
    push rbp
    mov r14, rsi                ; arena
    mov r15, rdx                ; &ptr
    mov rbp, rcx                ; &len
    mov esi, O_RDONLY
    mov eax, SYS_open
    syscall
    test rax, rax
    js .fail
    mov r12, rax
    sub rsp, 144
    mov rdi, rax
    mov rsi, rsp
    mov eax, SYS_fstat
    syscall
    mov r13, [rsp+48]
    add rsp, 144
    test rax, rax
    js .close_fail
    test r13, r13
    jz .close_fail
    mov rdi, r14
    mov rsi, r13
    call arena_alloc
    test rax, rax
    jz .close_fail
    mov rbx, rax
    xor r14d, r14d              ; got (arena reg no longer needed)
.rd:
    cmp r14, r13
    jae .ok
    mov rdi, r12
    lea rsi, [rbx+r14]
    mov rdx, r13
    sub rdx, r14
    xor eax, eax
    syscall
    cmp rax, 0
    jle .close_fail
    add r14, rax
    jmp .rd
.ok:
    mov rdi, r12
    mov eax, SYS_close
    syscall
    mov [r15], rbx
    mov [rbp], r13
    xor eax, eax
    jmp .ret
.close_fail:
    mov rdi, r12
    mov eax, SYS_close
    syscall
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

; ---- finish_page --------------------------------------------------------

; theme_entry() -> rax = theme_tbl row for [set_theme]
theme_entry:
    mov eax, [set_theme]
    imul rax, rax, TH_SIZE
    add rax, theme_tbl
    ret

; theme_class() -> rax = class-name ptr, rdx = len (from [set_theme])
theme_class:
    call theme_entry
    mov rdx, [rax+TH_CLASS_L]
    mov rax, [rax+TH_CLASS]
    ret

; theme_from_value(p, len) -> eax = theme id whose form value matches,
; 0 (retro) for anything unknown
theme_from_value:
    push r12
    push r13
    push rbx
    mov r12, rdi
    mov r13, rsi
    xor ebx, ebx
.next:
    imul rax, rbx, TH_SIZE
    add rax, theme_tbl
    cmp r13, [rax+TH_VAL_L]
    jne .miss
    mov rdi, r12
    mov rsi, [rax+TH_VAL]
    mov rdx, r13
    call mem_eq
    test eax, eax
    jnz .hit
.miss:
    inc ebx
    cmp ebx, NTHEMES
    jb .next
    xor ebx, ebx
.hit:
    mov eax, ebx
    pop rbx
    pop r13
    pop r12
    ret

; shell_vals(vals) — the values every shell render needs: site title,
; banner, theme class, stylesheet version.
shell_vals:
    mov rax, [set_title_p]
    mov rcx, [set_title_l]
    test rcx, rcx
    jnz .site_ok
    mov rax, def_site
    mov rcx, def_site_len
.site_ok:
    mov [rdi+V_SITE*16], rax
    mov [rdi+V_SITE*16+8], rcx
    mov rax, [set_banner_p]
    mov [rdi+V_BANNER*16], rax
    mov rax, [set_banner_l]
    mov [rdi+V_BANNER*16+8], rax
    call theme_entry
    mov rcx, [rax+TH_CLASS]
    mov [rdi+V_THEME*16], rcx
    mov rcx, [rax+TH_CLASS_L]
    mov [rdi+V_THEME*16+8], rcx
    add rax, TH_COLOR
    mov [rdi+V_THCOLOR*16], rax
    mov qword [rdi+V_THCOLOR*16+8], 7
    mov qword [rdi+V_CSSV*16], css_ver
    mov qword [rdi+V_CSSV*16+8], 8
    ret

; resp_headers(dst, ctx) -> rax = end. The response-state headers:
; Cache-Control (CTX_CACHE), Vary: Accept-Encoding for the negotiated
; static modes, ETag (CTX_ETAG) and Last-Modified (CTX_LM).
resp_headers:
    push r12
    push rbx
    mov rbx, rdi
    mov r12, rsi
    movzx eax, byte [r12+CTX_CACHE]
    test eax, eax
    jz .vary_chk
    shl eax, 4
    mov rsi, [cc_tbl + rax]
    mov rdx, [cc_tbl + rax + 8]
    mov rdi, rbx
    call mem_copy
    mov rbx, rax
.vary_chk:
    cmp byte [r12+CTX_VARY], 0
    je .etag
    mov rdi, rbx
    mov rsi, s_vary
    mov edx, s_vary_len
    call mem_copy
    mov rbx, rax
.etag:
    cmp byte [r12+CTX_ETAG_L], 0
    je .lm
    mov rdi, rbx
    mov rsi, s_etag
    mov edx, s_etag_len
    call mem_copy
    mov rdi, rax
    lea rsi, [r12+CTX_ETAG]
    movzx edx, byte [r12+CTX_ETAG_L]
    call mem_copy
    mov word [rax], 0x0A0D
    lea rbx, [rax+2]
.lm:
    cmp qword [r12+CTX_LM], 0
    je .done
    mov rdi, rbx
    mov rsi, s_lm
    mov edx, s_lm_len
    call mem_copy
    mov rdi, [r12+CTX_LM]
    mov rsi, rax
    call fmt_httpdate
    mov word [rax], 0x0A0D
    lea rbx, [rax+2]
.done:
    mov rax, rbx
    pop rbx
    pop r12
    ret

; finish_page(ctx, body_len, ctype_p, ctype_l, extra_p, extra_l)
; Headers are written right-aligned against CTX_BODY_OFF, where the
; body has already been rendered. Date, Content-Language (HTML) and the
; resp_headers set come from the connection's response state; a HEAD
; request sends the headers only (Content-Length still describes the
; body it would have had).
finish_page:
    push r12
    push r13
    push r14
    push r15
    push rbx
    push rbp
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
    sub rsp, 1040
    mov [rsp+1024], r8
    mov [rsp+1032], r9
    mov rdi, rsp
    mov rsi, s_200
    mov edx, s_200_len
    call mem_copy
    mov rdi, rax
    mov rsi, s_server
    mov edx, s_server_len
    call mem_copy
    mov rdi, rax
    call emit_date_hdr
    mov rdi, rax
    mov rsi, sec_headers
    mov edx, sec_headers_len
    call mem_copy
    cmp byte [r12+CTX_KEEP], 0
    je .cl
    mov rsi, s_ka
    mov edx, s_ka_len
    jmp .conn
.cl:
    mov rsi, s_cl
    mov edx, s_cl_len
.conn:
    mov rdi, rax
    call mem_copy
    mov rdi, rax
    mov rsi, r14
    mov rdx, r15
    call mem_copy
    mov rbx, rax
    cmp r15, 23                 ; Content-Language on text/html
    jb .nolang
    mov rdi, r14
    mov rsi, s_ct_html_pfx
    mov edx, 23
    call mem_eq
    test eax, eax
    jz .nolang
    mov rsi, s_lang_en
    mov edx, s_lang_en_len
    cmp dword [set_locale], 1
    jne .lang
    mov rsi, s_lang_es
    mov edx, s_lang_es_len
.lang:
    mov rdi, rbx
    call mem_copy
    mov rbx, rax
.nolang:
    mov rdi, rbx
    mov rsi, r12
    call resp_headers
    mov rbx, rax
    mov rbp, [rsp+1032]
    test rbp, rbp
    jz .noextra
    mov rdi, rbx
    mov rsi, [rsp+1024]
    mov rdx, rbp
    call mem_copy
    mov rbx, rax
.noextra:
    mov rdi, rbx
    mov rsi, s_clen
    mov edx, s_clen_len
    call mem_copy
    mov rdi, r13
    mov rsi, rax
    call u64_to_dec
    mov rdi, rax
    mov rsi, s_crlf2
    mov edx, 4
    call mem_copy
    mov rbx, rax
    sub rbx, rsp                ; header length
    lea rdi, [r12+CTX_OUT+CTX_BODY_OFF]
    sub rdi, rbx
    mov rsi, rsp
    mov rdx, rbx
    call mem_copy
    mov rax, CTX_BODY_OFF
    sub rax, rbx
    mov [r12+CTX_OUT_START], rax
    mov rax, rbx
    cmp byte [r12+CTX_HEAD], 0
    jne .len
    add rax, r13
.len:
    mov [r12+CTX_OUT_LEN], rax
    mov qword [r12+CTX_OUT_SENT], 0
    add rsp, 1040
    pop rbp
    pop rbx
    pop r15
    pop r14
    pop r13
    pop r12
    ret

; finish_304(ctx) — headers-only Not Modified carrying the validators
; the handler staged (the same ones its 200 would have had).
finish_304:
    push r12
    push r14
    mov r12, rdi
    lea r14, [r12+CTX_OUT]
    mov rdi, r14
    mov rsi, s_304
    mov edx, s_304_len
    call mem_copy
    mov rdi, rax
    mov rsi, s_server
    mov edx, s_server_len
    call mem_copy
    mov rdi, rax
    call emit_date_hdr
    cmp byte [r12+CTX_KEEP], 0
    je .cl
    mov rsi, s_ka
    mov edx, s_ka_len
    jmp .conn
.cl:
    mov rsi, s_cl
    mov edx, s_cl_len
.conn:
    mov rdi, rax
    call mem_copy
    mov rdi, rax
    mov rsi, r12
    call resp_headers
    mov word [rax], 0x0A0D
    add rax, 2
    sub rax, r14
    mov [r12+CTX_OUT_LEN], rax
    mov qword [r12+CTX_OUT_START], 0
    mov qword [r12+CTX_OUT_SENT], 0
    pop r14
    pop r12
    ret

section .data

def_site: db 'blogd'
def_site_len equ $-def_site
; ---- theme table -------------------------------------------------------
; One row per theme id (see NTHEMES in store.inc): the <body> class, the
; settings-form value, and the fixed-width '#rrggbb' colours the server
; emits itself — manifest background, theme-color (manifest + <meta>),
; and the hit counter's background/digits. Everything else about a theme
; is CSS (assets/input.css) and icons (tools/mkicons.py).
%macro THEME 6                  ; class, value, mfbg, color, hitbg, hitfg
    dq %%c, %%c_l, %%v, %%v_l
    db %3, 0, %4, 0, %5, 0, %6, 0
    [section .rodata]
%%c: db %1
%%c_l equ $-%%c
%%v: db %2
%%v_l equ $-%%v
    __?SECT?__
%endmacro
align 8
theme_tbl:
    THEME 'theme-retro',      'retro',      '#000080', '#000080', '#000000', '#33ff33'
    THEME 'theme-sucre',      'sucre',      '#f4ecdd', '#b0492e', '#2b241f', '#e6c07b'
    THEME 'theme-medellin',   'medellin',   '#fffdfa', '#1f7a3e', '#1f7a3e', '#ffffff'
    THEME 'theme-bogota',     'bogota',     '#3a3f45', '#7a2e22', '#26292d', '#d4a642'
    THEME 'theme-lapaz',      'lapaz',      '#17111f', '#5b2a86', '#0b0810', '#ffb000'
    THEME 'theme-cochabamba', 'cochabamba', '#e8d5b5', '#2f3a3d', '#2f3a3d', '#f3efe6'
    THEME 'theme-santacruz',  'santacruz',  '#fbf8f1', '#177245', '#0f4d33', '#ff6f59'
    THEME 'theme-pittsburgh', 'pittsburgh', '#1c1f22', '#ffb81c', '#101214', '#ffb81c'
s_posturl: db '/post/'
s_slash: db '/'
s_slash_len equ 1
s_hash: db '#'
s_hash_len equ 1
s_dot: db ' ', 0xC2, 0xB7, ' '        ; " · "
s_dot_len equ $-s_dot
s_http: db 'http://'
s_http_len equ $-s_http
s_https: db 'https://'
s_https_len equ $-s_https

s_pgr_open: db '<div class="pager">'
s_pgr_open_len equ $-s_pgr_open
s_pgr_close: db '</div>'
s_pgr_close_len equ $-s_pgr_close
s_pgr_prev: db '<a class="pglink" rel="prev" href="'
s_pgr_prev_len equ $-s_pgr_prev
s_pgr_next: db '<a class="pglink" rel="next" href="'
s_pgr_next_len equ $-s_pgr_next
s_tagbase: db '/tag/'
s_tagbase_len equ $-s_tagbase
s_pagebase: db '/page/'
s_pagebase_len equ $-s_pagebase
s_pgr_b: db '">'
s_pgr_b_len equ $-s_pgr_b
s_pgr_c: db '</a> '
s_pgr_c_len equ $-s_pgr_c

; <head> metadata fragments (m_end closes an attribute-valued tag)
m_end: db '">', 10
m_end_len equ $-m_end
m_desc: db '<meta name="description" content="'
m_desc_len equ $-m_desc
m_noindex: db '<meta name="robots" content="noindex,follow">', 10
m_noindex_len equ $-m_noindex
m_canon: db '<link rel="canonical" href="'
m_canon_len equ $-m_canon
m_prev: db '<link rel="prev" href="'
m_prev_len equ $-m_prev
m_next: db '<link rel="next" href="'
m_next_len equ $-m_next
m_ogarticle: db '<meta property="og:type" content="article">', 10
m_ogarticle_len equ $-m_ogarticle
m_ogwebsite: db '<meta property="og:type" content="website">', 10
m_ogwebsite_len equ $-m_ogwebsite
m_ogtitle: db '<meta property="og:title" content="'
m_ogtitle_len equ $-m_ogtitle
m_ogdesc: db '<meta property="og:description" content="'
m_ogdesc_len equ $-m_ogdesc
m_ogurl: db '<meta property="og:url" content="'
m_ogurl_len equ $-m_ogurl
m_ogsite: db '<meta property="og:site_name" content="'
m_ogsite_len equ $-m_ogsite
m_oglocale: db '<meta property="og:locale" content="'
m_oglocale_len equ $-m_oglocale
m_loc_en: db 'en_US'
m_loc_en_len equ $-m_loc_en
m_loc_es: db 'es_BO'
m_loc_es_len equ $-m_loc_es
m_ogimage: db '<meta property="og:image" content="'
m_ogimage_len equ $-m_ogimage
m_ogpng: db '/static/og.png?v='
m_ogpng_len equ $-m_ogpng
m_twlarge: db '<meta name="twitter:card" content="summary_large_image">', 10
m_twlarge_len equ $-m_twlarge
m_twsmall: db '<meta name="twitter:card" content="summary">', 10
m_twsmall_len equ $-m_twsmall
m_pub: db '<meta property="article:published_time" content="'
m_pub_len equ $-m_pub
m_mod: db '<meta property="article:modified_time" content="'
m_mod_len equ $-m_mod
m_ogtag: db '<meta property="article:tag" content="'
m_ogtag_len equ $-m_ogtag
m_postp: db '/post/'
m_postp_len equ $-m_postp
m_flhost: db 'https://live.staticflickr.com/'
m_flhost_len equ $-m_flhost

; JSON-LD (a data block: not a script, so script-src 'none' still holds)
j_post1: db '<script type="application/ld+json">{"@context":"https://schema.org",'
         db '"@type":"BlogPosting","headline":"'
j_post1_len equ $-j_post1
j_desc: db '","description":"'
j_desc_len equ $-j_desc
j_pub: db '","datePublished":"'
j_pub_len equ $-j_pub
j_mod: db '","dateModified":"'
j_mod_len equ $-j_mod
j_url: db '","url":"'
j_url_len equ $-j_url
j_main: db '","mainEntityOfPage":"'
j_main_len equ $-j_main
j_img: db '","image":"'
j_img_len equ $-j_img
j_author: db '","author":{"@type":"Person","name":"'
j_author_len equ $-j_author
j_publisher: db '"},"publisher":{"@type":"Organization","name":"'
j_publisher_len equ $-j_publisher
j_end: db '"}}</script>', 10
j_end_len equ $-j_end
j_site1: db '<script type="application/ld+json">{"@context":"https://schema.org",'
         db '"@type":"WebSite","name":"'
j_site1_len equ $-j_site1
j_site2: db '","url":"'
j_site2_len equ $-j_site2
j_site3: db '/","potentialAction":{"@type":"SearchAction","target":"'
j_site3_len equ $-j_site3
j_site4: db '/search?q={search_term_string}","query-input":"required name=search_term_string"}}</script>', 10
j_site4_len equ $-j_site4

; robots.txt / sitemap / manifest
rb_txt: db 'User-agent: *', 10, 'Disallow: /admin', 10, 'Disallow: /search', 10
        db 'Disallow: /hits.svg', 10
rb_txt_len equ $-rb_txt
rb_sitemap: db 'Sitemap: '
rb_sitemap_len equ $-rb_sitemap
rb_sitemap2: db '/sitemap.xml', 10
rb_sitemap2_len equ $-rb_sitemap2
sm_open: db '<?xml version="1.0" encoding="utf-8"?>', 10
         db '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">', 10
sm_open_len equ $-sm_open
sm_url_o: db '<url><loc>'
sm_url_o_len equ $-sm_url_o
sm_lastmod: db '</loc><lastmod>'
sm_lastmod_len equ $-sm_lastmod
sm_url_c: db '</lastmod></url>', 10
sm_url_c_len equ $-sm_url_c
sm_close: db '</urlset>', 10
sm_close_len equ $-sm_close
si_open: db '<?xml version="1.0" encoding="utf-8"?>', 10
         db '<sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">', 10
si_open_len equ $-si_open
si_item_o: db '<sitemap><loc>'
si_item_o_len equ $-si_item_o
si_path: db '/sitemap-'
si_path_len equ $-si_path
si_item_c: db '.xml</loc></sitemap>', 10
si_item_c_len equ $-si_item_c
si_close: db '</sitemapindex>', 10
si_close_len equ $-si_close
mf_1: db '{"name":"'
mf_1_len equ $-mf_1
mf_2: db '","short_name":"'
mf_2_len equ $-mf_2
mf_3: db '","start_url":"/","display":"minimal-ui","background_color":"'
mf_3_len equ $-mf_3
mf_4: db '","theme_color":"'
mf_4_len equ $-mf_4
mf_5: db '","icons":[{"src":"/static/icon-192.png?v='
mf_5_len equ $-mf_5
mf_6: db '","sizes":"192x192","type":"image/png"},{"src":"/static/icon-512.png?v='
mf_6_len equ $-mf_6
mf_7: db '","sizes":"512x512","type":"image/png"}]}', 10
mf_7_len equ $-mf_7

s_tag_a: db '<a class="tag" href="/tag/'
s_tag_a_len equ $-s_tag_a
s_tag_b: db '">#'
s_tag_b_len equ $-s_tag_b
s_tag_c: db '</a> '
s_tag_c_len equ $-s_tag_c

a_head1: db '<?xml version="1.0" encoding="utf-8"?>', 10
         db '<feed xmlns="http://www.w3.org/2005/Atom" xml:lang="'
a_head1_len equ $-a_head1
a_lang_en: db 'en'
a_lang_en_len equ $-a_lang_en
a_lang_es: db 'es-BO'
a_lang_es_len equ $-a_lang_es
a_head1b: db '"><title>'
a_head1b_len equ $-a_head1b
a_head2: db '</title>', 10, '<link rel="alternate" type="text/html" href="'
a_head2_len equ $-a_head2
a_head2b: db '/"/><link rel="self" type="application/atom+xml" href="'
a_head2b_len equ $-a_head2b
a_head2c: db '/feed.xml"/>', 10, '<id>tag:blogd:feed</id><updated>'
a_head2c_len equ $-a_head2c
a_head3: db '</updated>', 10, '<author><name>'
a_head3_len equ $-a_head3
a_head3b: db '</name></author><generator>blogd 0.9</generator>', 10
a_head3b_len equ $-a_head3b
a_icon: db '<icon>'
a_icon_len equ $-a_icon
a_icon2: db '/static/icon-192.png?v='
a_icon2_len equ $-a_icon2
a_icon3: db '</icon>', 10
a_icon3_len equ $-a_icon3
a_e1: db '<entry><title>'
a_e1_len equ $-a_e1
a_e2: db '</title><link rel="alternate" type="text/html" href="'
a_e2_len equ $-a_e2
a_e3: db '"/><id>tag:blogd:post-'
a_e3_len equ $-a_e3
a_e4: db '</id><published>'
a_e4_len equ $-a_e4
a_e4b: db '</published><updated>'
a_e4b_len equ $-a_e4b
a_e5: db '</updated>'
a_e5_len equ $-a_e5
a_cat: db '<category term="'
a_cat_len equ $-a_cat
a_cat_c: db '"/>', 10
a_cat_c_len equ $-a_cat_c
a_e5b: db '<summary type="text">'
a_e5b_len equ $-a_e5b
a_e6: db '</summary>'
a_e6_len equ $-a_e6
a_e7: db '<content type="html">'
a_e7_len equ $-a_e7
a_e7b: db '</content>'
a_e7b_len equ $-a_e7b
a_e8: db '</entry>', 10
a_e8_len equ $-a_e8
a_tail: db '</feed>', 10
a_tail_len equ $-a_tail

s_200: db 'HTTP/1.1 200 OK', 13, 10
s_200_len equ $-s_200
s_304: db 'HTTP/1.1 304 Not Modified', 13, 10
s_304_len equ $-s_304
s_server: db 'Server: blogd/0.9', 13, 10
s_server_len equ $-s_server
s_ka: db 'Connection: keep-alive', 13, 10
s_ka_len equ $-s_ka
s_cl: db 'Connection: close', 13, 10
s_cl_len equ $-s_cl
s_clen: db 'Content-Length: '
s_clen_len equ $-s_clen
s_crlf2: db 13, 10, 13, 10
s_etag: db 'ETag: '
s_etag_len equ $-s_etag
s_lm: db 'Last-Modified: '
s_lm_len equ $-s_lm
s_vary: db 'Vary: Accept-Encoding', 13, 10
s_vary_len equ $-s_vary
s_lang_en: db 'Content-Language: en', 13, 10
s_lang_en_len equ $-s_lang_en
s_lang_es: db 'Content-Language: es-BO', 13, 10
s_lang_es_len equ $-s_lang_es
s_ct_html_pfx: db 'Content-Type: text/html'

cc_reval: db 'Cache-Control: public, max-age=0, must-revalidate', 13, 10
cc_reval_len equ $-cc_reval
cc_imm: db 'Cache-Control: public, max-age=31536000, immutable', 13, 10
cc_imm_len equ $-cc_imm
cc_nostore: db 'Cache-Control: no-store', 13, 10
cc_nostore_len equ $-cc_nostore
cc_feed: db 'Cache-Control: public, max-age=300', 13, 10
cc_feed_len equ $-cc_feed
cc_day: db 'Cache-Control: public, max-age=86400', 13, 10
cc_day_len equ $-cc_day
cc_hour: db 'Cache-Control: public, max-age=3600', 13, 10
cc_hour_len equ $-cc_hour
align 8
cc_tbl:                         ; indexed by CACHE_* mode
    dq 0, 0
    dq cc_reval, cc_reval_len
    dq cc_imm, cc_imm_len
    dq cc_nostore, cc_nostore_len
    dq cc_feed, cc_feed_len
    dq cc_day, cc_day_len
    dq cc_hour, cc_hour_len

ct_html: db 'Content-Type: text/html; charset=utf-8', 13, 10
ct_html_len equ $-ct_html
ct_atom: db 'Content-Type: application/atom+xml; charset=utf-8', 13, 10
ct_atom_len equ $-ct_atom
ct_css: db 'Content-Type: text/css; charset=utf-8', 13, 10
ct_css_len equ $-ct_css
ct_svg: db 'Content-Type: image/svg+xml; charset=utf-8', 13, 10
ct_svg_len equ $-ct_svg
ct_text: db 'Content-Type: text/plain; charset=utf-8', 13, 10
ct_text_len equ $-ct_text
ct_xml: db 'Content-Type: application/xml; charset=utf-8', 13, 10
ct_xml_len equ $-ct_xml
ct_manifest: db 'Content-Type: application/manifest+json; charset=utf-8', 13, 10
ct_manifest_len equ $-ct_manifest
ct_ico: db 'Content-Type: image/x-icon', 13, 10
ct_ico_len equ $-ct_ico
ct_png: db 'Content-Type: image/png', 13, 10
ct_png_len equ $-ct_png
x_gzip: db 'Content-Encoding: gzip', 13, 10
x_gzip_len equ $-x_gzip
x_br: db 'Content-Encoding: br', 13, 10
x_br_len equ $-x_br

p_css: db 'static/main.css', 0
p_favsvg: db 'static/favicon.svg', 0
p_favico: db 'static/favicon.ico', 0
p_i192: db 'static/icon-192.png', 0
p_i512: db 'static/icon-512.png', 0
p_og: db 'static/og.png', 0
sfx_gz: db '.gz', 0
sfx_br: db '.br', 0

; themed icon sets: static/<theme>-<file>, one set per non-retro theme
%macro TPATHS 2                 ; label stem, file prefix
p_%1_favsvg: db 'static/', %2, 'favicon.svg', 0
p_%1_favsvg_l equ $-p_%1_favsvg-8
p_%1_favico: db 'static/', %2, 'favicon.ico', 0
p_%1_favico_l equ $-p_%1_favico-8
p_%1_i192: db 'static/', %2, 'icon-192.png', 0
p_%1_i192_l equ $-p_%1_i192-8
p_%1_i512: db 'static/', %2, 'icon-512.png', 0
p_%1_i512_l equ $-p_%1_i512-8
p_%1_og: db 'static/', %2, 'og.png', 0
p_%1_og_l equ $-p_%1_og-8
%endmacro
TPATHS sucre, 'sucre-'
TPATHS mde, 'medellin-'
TPATHS bog, 'bogota-'
TPATHS lpb, 'lapaz-'
TPATHS cbb, 'cochabamba-'
TPATHS srz, 'santacruz-'
TPATHS pgh, 'pittsburgh-'

; STATIC path, name len, ctype, ctype len, default cache mode, Sucre alt
%macro STATIC 6
    dq %1, %1+7, %2, %3, %4, %5, 0, 0, 0, 0, 0, 0
    dd 0, 0, 0, 0
    dq %6
%endmacro
align 8
static_tbl:                     ; main.css must stay first (css_ver)
    STATIC p_css, 8, ct_css, ct_css_len, CACHE_HOUR, -1
    STATIC p_favsvg, 11, ct_svg, ct_svg_len, CACHE_DAY, 6
    STATIC p_favico, 11, ct_ico, ct_ico_len, CACHE_DAY, 6+1*(NTHEMES-1)
    STATIC p_i192, 12, ct_png, ct_png_len, CACHE_DAY, 6+2*(NTHEMES-1)
    STATIC p_i512, 12, ct_png, ct_png_len, CACHE_DAY, 6+3*(NTHEMES-1)
    STATIC p_og, 6, ct_png, ct_png_len, CACHE_DAY, 6+4*(NTHEMES-1)
; themed variants, one group per file in theme-id order (sucre first)
%macro TGROUP 3                 ; file stem, ctype, ctype len
    STATIC p_sucre_%1, p_sucre_%1_l, %2, %3, CACHE_DAY, -1
    STATIC p_mde_%1, p_mde_%1_l, %2, %3, CACHE_DAY, -1
    STATIC p_bog_%1, p_bog_%1_l, %2, %3, CACHE_DAY, -1
    STATIC p_lpb_%1, p_lpb_%1_l, %2, %3, CACHE_DAY, -1
    STATIC p_cbb_%1, p_cbb_%1_l, %2, %3, CACHE_DAY, -1
    STATIC p_srz_%1, p_srz_%1_l, %2, %3, CACHE_DAY, -1
    STATIC p_pgh_%1, p_pgh_%1_l, %2, %3, CACHE_DAY, -1
%endmacro
    TGROUP favsvg, ct_svg, ct_svg_len
    TGROUP favico, ct_ico, ct_ico_len
    TGROUP i192, ct_png, ct_png_len
    TGROUP i512, ct_png, ct_png_len
    TGROUP og, ct_png, ct_png_len

svg1: db '<svg xmlns="http://www.w3.org/2000/svg" width="'
svg1_len equ $-svg1
svg2: db '" height="18" viewBox="0 0 '
svg2_len equ $-svg2
svg3a: db ' 18"><rect width="100%" height="100%" fill="'
svg3a_len equ $-svg3a
svg3b: db '"/><text x="4" y="13" font-family="Courier New,monospace" font-size="12" fill="'
svg3b_len equ $-svg3b
svg3c: db '">'
svg3c_len equ $-svg3c
svg4: db '</text></svg>', 10
svg4_len equ $-svg4
svg_zero: db '0'

f_hits: db 'data/hits.blg', 0

section .bss

hits_p:     resq 1              ; -> the counter qword (mapped file or local)
hits_local: resq 1
css_ver:    resb 8              ; crc32c of main.css as hex: ?v= token

section .note.GNU-stack noalloc noexec nowrite progbits
