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
extern w_init
extern w_ovf
extern emit
extern emit_esc
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

global page_list
global page_post
global page_feed
global page_css
global load_static
global finish_page
global theme_class

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
%define L_FRAME   ((L_NUM + 32 + 15) & -16)

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
    ; site
    mov rax, [set_title_p]
    mov rcx, [set_title_l]
    test rcx, rcx
    jnz .site_ok
    mov rax, def_site
    mov rcx, def_site_len
.site_ok:
    mov [rsp+L_VALS+V_SITE*16], rax
    mov [rsp+L_VALS+V_SITE*16+8], rcx
    mov rax, [set_banner_p]
    mov [rsp+L_VALS+V_BANNER*16], rax
    mov rax, [set_banner_l]
    mov [rsp+L_VALS+V_BANNER*16+8], rax
    call theme_class
    mov [rsp+L_VALS+V_THEME*16], rax
    mov [rsp+L_VALS+V_THEME*16+8], rdx

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
    ; excerpt: first bytes of the markdown source, escaped by renderer
    mov rax, [r14+P_MD_P]
    mov [rsp+L_VALS+V_EXCERPT*16], rax
    mov rax, [r14+P_MD_L]
    cmp rax, 180
    jbe .exc_ok
    mov eax, 180
.exc_ok:
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
    mov rax, [rsp+L_MODE]
    cmp rax, 1
    je .t_tag
    cmp rax, 2
    je .t_search
    mov edi, S_T_HOME
    call i18n_get
    mov rcx, rdx
    jmp .t_set
.t_tag:
    mov rax, [rsp+L_TAGP]
    mov rcx, [rsp+L_TAGL]
    jmp .t_set
.t_search:
    mov edi, S_T_SEARCH
    call i18n_get
    mov rcx, rdx
.t_set:
    mov [rsp+L_VALS+V_TITLE*16], rax
    mov [rsp+L_VALS+V_TITLE*16+8], rcx
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
    call fill_count_val_a       ; visitor counter into L_NUM/vals
    ; render shell into the body region
    lea rdi, [rsp+L_BW]
    lea rsi, [r12+CTX_OUT+CTX_BODY_OFF]
    lea rdx, [r12+CTX_OUT+CTX_BODY_END]
    call w_init
    lea rdi, [rsp+L_BW]
    mov esi, T_SHELL
    lea rdx, [rsp+L_VALS]
    call tmpl_render
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

; fill_count_val_a — bump the visitor counter, format it into L_NUM and
; the vals slot. Called with page_list's frame live (rsp offsets +8 for
; our own return address).
fill_count_val_a:
    mov eax, 1
    lock xadd [hits], rax
    inc rax
    mov rdi, rax
    lea rsi, [rsp+8+L_NUM]
    call u64_to_dec
    lea rcx, [rsp+8+L_NUM]
    sub rax, rcx
    mov [rsp+8+L_VALS+V_COUNT*16], rcx
    mov [rsp+8+L_VALS+V_COUNT*16+8], rax
    ret

; pager_link(w, tag_p, tag_l, n, label_p, label_l)
pager_link:
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
    mov rbx, r8
    mov rbp, r9
    mov rdi, r12
    mov rsi, s_pgr_a
    mov edx, s_pgr_a_len
    call emit
    test r14, r14
    jz .base
    mov rdi, r12
    mov rsi, s_tagbase
    mov edx, s_tagbase_len
    call emit
    mov rdi, r12
    mov rsi, r13
    mov rdx, r14
    call emit
.base:
    mov rdi, r12
    mov rsi, s_pagebase
    mov edx, s_pagebase_len
    call emit
    mov rdi, r12
    mov rsi, r15
    call emit_u64
    mov rdi, r12
    mov rsi, s_pgr_b
    mov edx, s_pgr_b_len
    call emit
    mov rdi, r12
    mov rsi, rbx
    mov rdx, rbp
    call emit
    mov rdi, r12
    mov rsi, s_pgr_c
    mov edx, s_pgr_c_len
    call emit
    pop rbp
    pop rbx
    pop r15
    pop r14
    pop r13
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
%define Q_FRAME ((Q_NUM + 32 + 15) & -16)

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
    ; site
    mov rax, [set_title_p]
    mov rcx, [set_title_l]
    test rcx, rcx
    jnz .site_ok
    mov rax, def_site
    mov rcx, def_site_len
.site_ok:
    mov [rsp+Q_VALS+V_SITE*16], rax
    mov [rsp+Q_VALS+V_SITE*16+8], rcx
    mov rax, [set_banner_p]
    mov [rsp+Q_VALS+V_BANNER*16], rax
    mov rax, [set_banner_l]
    mov [rsp+Q_VALS+V_BANNER*16+8], rax
    call theme_class
    mov [rsp+Q_VALS+V_THEME*16], rax
    mov [rsp+Q_VALS+V_THEME*16+8], rdx
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
    call fill_count_val_b
    lea rdi, [rsp+Q_BW]
    lea rsi, [r12+CTX_OUT+CTX_BODY_OFF]
    lea rdx, [r12+CTX_OUT+CTX_BODY_END]
    call w_init
    lea rdi, [rsp+Q_BW]
    mov esi, T_SHELL
    lea rdx, [rsp+Q_VALS]
    call tmpl_render
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

; counter helper for page_post's frame
fill_count_val_b:
    mov eax, 1
    lock xadd [hits], rax
    inc rax
    mov rdi, rax
    lea rsi, [rsp+8+Q_NUM]
    call u64_to_dec
    lea rcx, [rsp+8+Q_NUM]
    sub rax, rcx
    mov [rsp+8+Q_VALS+V_COUNT*16], rcx
    mov [rsp+8+Q_VALS+V_COUNT*16+8], rax
    ret

; ---- page_feed ---------------------------------------------------------
%define F_W     0
%define F_DATE  24              ; 32
%define F_FRAME 64

; page_feed(ctx) — Atom, latest 20 published posts
page_feed:
    push r12
    push r13
    push r14
    push r15
    push rbx
    sub rsp, F_FRAME
    mov r12, rdi
    mov rdi, store_lock
    call rd_lock
    lea rdi, [rsp+F_W]
    lea rsi, [r12+CTX_OUT+CTX_BODY_OFF]
    lea rdx, [r12+CTX_OUT+CTX_BODY_END]
    call w_init
    lea rdi, [rsp+F_W]
    mov rsi, a_head1
    mov edx, a_head1_len
    call emit
    ; site title
    mov rsi, [set_title_p]
    mov rdx, [set_title_l]
    test rdx, rdx
    jnz .site_ok
    mov rsi, def_site
    mov edx, def_site_len
.site_ok:
    lea rdi, [rsp+F_W]
    call emit_esc
    lea rdi, [rsp+F_W]
    mov rsi, a_head2
    mov edx, a_head2_len
    call emit
    xor edi, edi
    mov eax, SYS_time
    syscall
    mov rdi, rax
    lea rsi, [rsp+F_DATE]
    call fmt_datetime
    lea rdi, [rsp+F_W]
    lea rsi, [rsp+F_DATE]
    mov edx, 20
    call emit
    lea rdi, [rsp+F_W]
    mov rsi, a_head3
    mov edx, a_head3_len
    call emit
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
    lea rdi, [rsp+F_W]
    mov rsi, a_e1               ; <entry><title>
    mov edx, a_e1_len
    call emit
    lea rdi, [rsp+F_W]
    mov rsi, [r15+P_TITLE_P]
    mov rdx, [r15+P_TITLE_L]
    call emit_esc
    lea rdi, [rsp+F_W]
    mov rsi, a_e2               ; </title><link href="/post/
    mov edx, a_e2_len
    call emit
    lea rdi, [rsp+F_W]
    mov rsi, [r15+P_SLUG_P]
    mov rdx, [r15+P_SLUG_L]
    call emit
    lea rdi, [rsp+F_W]
    mov rsi, a_e3               ; "/><id>tag:blogd:post-
    mov edx, a_e3_len
    call emit
    lea rdi, [rsp+F_W]
    mov rsi, [r15+P_ID]
    call emit_u64
    lea rdi, [rsp+F_W]
    mov rsi, a_e4               ; </id><updated>
    mov edx, a_e4_len
    call emit
    mov rdi, [r15+P_UPDATED]
    lea rsi, [rsp+F_DATE]
    call fmt_datetime
    lea rdi, [rsp+F_W]
    lea rsi, [rsp+F_DATE]
    mov edx, 20
    call emit
    lea rdi, [rsp+F_W]
    mov rsi, a_e5               ; </updated><summary>
    mov edx, a_e5_len
    call emit
    mov rsi, [r15+P_MD_P]
    mov rdx, [r15+P_MD_L]
    cmp rdx, 180
    jbe .sum_ok
    mov edx, 180
.sum_ok:
    lea rdi, [rsp+F_W]
    call emit_esc
    lea rdi, [rsp+F_W]
    mov rsi, a_e6               ; </summary></entry>
    mov edx, a_e6_len
    call emit
    inc r14
.next:
    inc r13
    jmp .loop
.tail:
    lea rdi, [rsp+F_W]
    mov rsi, a_tail
    mov edx, a_tail_len
    call emit
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

; ---- static css --------------------------------------------------------

; page_css(ctx)
page_css:
    push r12
    push r13
    push r14
    mov r12, rdi
    mov r13, [css_p]
    mov r14, [css_l]
    test r13, r13
    jz .missing
    cmp byte [r12+CTX_GZIP], 0
    je .plain
    cmp qword [css_gz_l], 0
    je .plain
    mov r13, [css_gz_p]
    mov r14, [css_gz_l]
    mov r8, x_gzip
    mov r9, x_gzip_len
    jmp .send
.plain:
    mov r8, x_plain
    mov r9, x_plain_len
.send:
    lea rax, [r14+CTX_BODY_OFF+4096]
    cmp rax, CTX_BODY_END
    ja .toobig
    push r8
    push r9
    lea rdi, [r12+CTX_OUT+CTX_BODY_OFF]
    mov rsi, r13
    mov rdx, r14
    call mem_copy
    pop r9
    pop r8
    mov rdi, r12
    mov rsi, r14
    mov rdx, ct_css
    mov ecx, ct_css_len
    call finish_page
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
    pop r14
    pop r13
    pop r12
    ret

; load_static() -> 0 / -1. main.css required, main.css.gz optional.
load_static:
    push r12
    mov edi, 0x100000
    call arena_create
    test rax, rax
    jz .fail
    mov r12, rax
    mov rdi, f_css
    mov rsi, r12
    mov rdx, css_p
    mov rcx, css_l
    call load_file
    test rax, rax
    jnz .fail
    mov rdi, f_cssgz
    mov rsi, r12
    mov rdx, css_gz_p
    mov rcx, css_gz_l
    call load_file              ; optional: ignore failure
    xor eax, eax
    pop r12
    ret
.fail:
    mov rax, -1
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

; theme_class() -> rax = class-name ptr, rdx = len (from [set_theme])
theme_class:
    cmp dword [set_theme], 1
    je .sucre
    mov rax, s_theme_retro
    mov edx, s_theme_retro_len
    ret
.sucre:
    mov rax, s_theme_sucre
    mov edx, s_theme_sucre_len
    ret

; finish_page(ctx, body_len, ctype_p, ctype_l, extra_p, extra_l)
; Headers are written right-aligned against CTX_BODY_OFF, where the
; body has already been rendered.
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
    mov rbx, r8
    mov rbp, r9
    sub rsp, 640
    mov rdi, rsp
    mov rsi, s_200
    mov edx, s_200_len
    call mem_copy
    mov rdi, rax
    mov rsi, s_server
    mov edx, s_server_len
    call mem_copy
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
    test rbp, rbp
    jz .noextra
    mov rdi, rax
    mov rsi, rbx
    mov rdx, rbp
    call mem_copy
.noextra:
    mov rdi, rax
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
    lea rax, [rbx+r13]
    mov [r12+CTX_OUT_LEN], rax
    mov qword [r12+CTX_OUT_SENT], 0
    add rsp, 640
    pop rbp
    pop rbx
    pop r15
    pop r14
    pop r13
    pop r12
    ret

section .data

def_site: db 'blogd'
def_site_len equ $-def_site
s_theme_retro: db 'theme-retro'
s_theme_retro_len equ $-s_theme_retro
s_theme_sucre: db 'theme-sucre'
s_theme_sucre_len equ $-s_theme_sucre
s_posturl: db '/post/'

s_pgr_open: db '<div class="pager">'
s_pgr_open_len equ $-s_pgr_open
s_pgr_close: db '</div>'
s_pgr_close_len equ $-s_pgr_close
s_pgr_a: db '<a class="pglink" href="'
s_pgr_a_len equ $-s_pgr_a
s_tagbase: db '/tag/'
s_tagbase_len equ $-s_tagbase
s_pagebase: db '/page/'
s_pagebase_len equ $-s_pagebase
s_pgr_b: db '">'
s_pgr_b_len equ $-s_pgr_b
s_pgr_c: db '</a> '
s_pgr_c_len equ $-s_pgr_c

s_tag_a: db '<a class="tag" href="/tag/'
s_tag_a_len equ $-s_tag_a
s_tag_b: db '">#'
s_tag_b_len equ $-s_tag_b
s_tag_c: db '</a> '
s_tag_c_len equ $-s_tag_c

a_head1: db '<?xml version="1.0" encoding="utf-8"?>', 10
         db '<feed xmlns="http://www.w3.org/2005/Atom"><title>'
a_head1_len equ $-a_head1
a_head2: db '</title><link href="/"/><link rel="self" href="/feed.xml"/>'
         db '<id>tag:blogd:feed</id><updated>'
a_head2_len equ $-a_head2
a_head3: db '</updated>', 10
a_head3_len equ $-a_head3
a_e1: db '<entry><title>'
a_e1_len equ $-a_e1
a_e2: db '</title><link href="/post/'
a_e2_len equ $-a_e2
a_e3: db '"/><id>tag:blogd:post-'
a_e3_len equ $-a_e3
a_e4: db '</id><updated>'
a_e4_len equ $-a_e4
a_e5: db '</updated><summary>'
a_e5_len equ $-a_e5
a_e6: db '</summary></entry>', 10
a_e6_len equ $-a_e6
a_tail: db '</feed>', 10
a_tail_len equ $-a_tail

s_200: db 'HTTP/1.1 200 OK', 13, 10
s_200_len equ $-s_200
s_server: db 'Server: blogd/0.5', 13, 10
s_server_len equ $-s_server
s_ka: db 'Connection: keep-alive', 13, 10
s_ka_len equ $-s_ka
s_cl: db 'Connection: close', 13, 10
s_cl_len equ $-s_cl
s_clen: db 'Content-Length: '
s_clen_len equ $-s_clen
s_crlf2: db 13, 10, 13, 10

ct_html: db 'Content-Type: text/html; charset=utf-8', 13, 10
ct_html_len equ $-ct_html
ct_atom: db 'Content-Type: application/atom+xml; charset=utf-8', 13, 10
ct_atom_len equ $-ct_atom
ct_css: db 'Content-Type: text/css; charset=utf-8', 13, 10
ct_css_len equ $-ct_css
x_plain: db 'Cache-Control: public, max-age=3600', 13, 10
x_plain_len equ $-x_plain
x_gzip: db 'Cache-Control: public, max-age=3600', 13, 10
        db 'Content-Encoding: gzip', 13, 10
x_gzip_len equ $-x_gzip

f_css: db 'static/main.css', 0
f_cssgz: db 'static/main.css.gz', 0

section .bss

hits:     resq 1
css_p:    resq 1
css_l:    resq 1
css_gz_p: resq 1
css_gz_l: resq 1

section .note.GNU-stack noalloc noexec nowrite progbits
