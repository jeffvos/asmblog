; admin.asm — the admin panel: login, dashboard, editor, settings.
;
; Security model:
;   - session cookie (sid) checked on every admin request; missing or
;     stale sessions bounce to /admin/login via 303
;   - every mutating POST verifies the per-session CSRF token on top
;     of SameSite=Strict cookies
;   - Argon2id verify/hash runs on the main thread via the crypto
;     mailbox (workers have no TLS); failed logins back off globally
;   - all user text rendered through the escaping template engine;
;     markdown is rendered to HTML at save time by md.asm
;
; Form fields decode into the connection's DECODE region; rendered
; markdown and dashboard rows build in MDHTML; templates render into
; SCRATCH, then the shell into BODY — no region ever aliases another.

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
extern set_ttl
extern set_title_p
extern set_title_l
extern set_banner_p
extern set_banner_l
extern set_theme
extern set_locale
extern set_present
extern set_hash
extern set_url
extern set_url_l
extern settings_set_url
extern theme_class
extern shell_vals
extern emit_date_hdr
extern i18n_get
extern fmt_date_local
extern store_find_by_id
extern store_append_post
extern store_delete_post
extern store_save_settings
extern session_create
extern session_find
extern session_csrf
extern session_csrf_ok
extern session_destroy
extern login_allowed
extern login_failed
extern login_ok
extern crypto_verify_remote
extern crypto_hash_remote
extern w_init
extern w_ovf
extern emit
extern emit_esc
extern emit_u64
extern tmpl_render
extern md_render
extern fmt_date
extern u64_to_dec
extern parse_dec
extern mem_copy
extern mem_eq
extern ci_prefix
extern percent_decode
extern valid_seg
extern build_page
extern finish_page
extern sec_headers
extern sec_headers_len

global admin_route

; form field indices
%define FI_PASSWORD  0
%define FI_PASSWORD2 1
%define FI_TITLE     2
%define FI_SLUG      3
%define FI_TAGS      4
%define FI_MD        5
%define FI_ID        6
%define FI_ACTION    7
%define FI_CSRF      8
%define FI_PPP       9
%define FI_BANNER    10
%define FI_THEME     11
%define FI_LOCALE    12
%define FI_URL       13
%define FIELD_N      14

; frame
%define A_VALS    0
%define A_W       (A_VALS + NVALS*16)
%define A_BW      (A_W + 24)
%define A_RW      (A_BW + 24)
%define A_FLD     (A_RW + 24)
%define A_SESS    (A_FLD + FIELD_N*16)
%define A_HLEN    (A_SESS + 8)
%define A_BLEN    (A_HLEN + 8)
%define A_POST    (A_BLEN + 8)
%define A_PATH    (A_POST + 8)
%define A_PATHL   (A_PATH + 8)
%define A_ID      (A_PATHL + 8)
%define A_NUM     (A_ID + 8)      ; 32
%define A_NUM2    (A_NUM + 32)    ; 32
%define A_DATE    (A_NUM2 + 32)   ; 32 (localized long dates)
%define A_SLUG    (A_DATE + 32)   ; 160
%define A_CK      (A_SLUG + 160)  ; 256
%define A_SIDBUF  (A_CK + 256)    ; 64
%define A_CSRFBUF (A_SIDBUF + 64) ; 64
%define A_HASH    (A_CSRFBUF + 64); 128
%define A_SPEC    (A_HASH + 128)  ; 96
%define A_FRAME   ((A_SPEC + 96 + 15) & -16)

section .text

; admin_route(ctx, path, path_len, head_len, body_len, is_post)
admin_route:
    push r12
    push r13
    push r14
    push r15
    push rbx
    push rbp
    sub rsp, A_FRAME
    mov r12, rdi
    lea rax, [rsi+6]            ; sub-path after "/admin"
    mov [rsp+A_PATH], rax
    lea rax, [rdx-6]
    mov [rsp+A_PATHL], rax
    mov [rsp+A_HLEN], rcx
    mov [rsp+A_BLEN], r8
    mov [rsp+A_POST], r9
    mov qword [rsp+A_ID], 0
    lea rdi, [rsp+A_VALS]
    mov ecx, NVALS*2
    xor eax, eax
    rep stosq
    lea rdi, [rsp+A_VALS]
    call shell_vals
    mov qword [rsp+A_VALS+V_META*16], a_noindex
    mov qword [rsp+A_VALS+V_META*16+8], a_noindex_len
    mov byte [r12+CTX_CACHE], CACHE_NOSTORE   ; nothing under /admin is cacheable
    mov byte [r12+CTX_ETAG_L], 0

    ; session from the sid cookie
    mov qword [rsp+A_SESS], -1
    lea rdi, [r12+CTX_IN]
    mov rsi, [rsp+A_HLEN]
    call cookie_sid
    test rax, rax
    jz .nosess
    mov rdi, rax
    mov rsi, rdx
    call session_find
    mov [rsp+A_SESS], rax
    cmp rax, -1
    je .nosess
    mov rdi, rax
    call session_csrf
    mov [rsp+A_VALS+V_CSRF*16], rax
    mov qword [rsp+A_VALS+V_CSRF*16+8], 64
.nosess:

    ; ---- sub-path dispatch ----
    mov r14, [rsp+A_PATH]
    mov r15, [rsp+A_PATHL]
    test r15, r15
    jz .dash_gate
    cmp r15, 1
    jne .d_login
    cmp byte [r14], '/'
    je .dash_gate
    jmp .notfound
.d_login:
    cmp r15, 6
    jne .d_logout
    mov rdi, r14
    mov rsi, a_p_login
    mov edx, 6
    call mem_eq
    test eax, eax
    jz .d_logout
    cmp qword [rsp+A_POST], 0
    jne .do_login
    xor eax, eax                ; GET: plain login page
    xor ecx, ecx
    jmp .login_page
.d_logout:
    cmp r15, 7
    jne .d_new
    mov rdi, r14
    mov rsi, a_p_logout
    mov edx, 7
    call mem_eq
    test eax, eax
    jz .d_new                   ; other 7-byte paths continue the chain
    cmp qword [rsp+A_POST], 0
    je .to_admin
    jmp .do_logout
.d_new:
    cmp r15, 4
    jne .d_edit
    mov rdi, r14
    mov rsi, a_p_new
    mov edx, 4
    call mem_eq
    test eax, eax
    jz .d_edit
    cmp qword [rsp+A_SESS], -1
    je .to_login
    jmp .editor
.d_edit:
    cmp r15, 7                  ; "/edit/N" minimum
    jb .d_save
    mov rdi, r14
    mov rsi, a_p_edit
    mov edx, 6
    call mem_eq
    test eax, eax
    jz .d_delc
    lea rdi, [r14+6]
    lea rsi, [r15-6]
    call parse_dec
    test rax, rax
    jz .notfound
    mov [rsp+A_ID], rax
    cmp qword [rsp+A_SESS], -1
    je .to_login
    jmp .editor
.d_delc:
    cmp r15, 9                  ; "/delete/N" minimum
    jb .d_del
    mov rdi, r14
    mov rsi, a_p_deletes
    mov edx, 8
    call mem_eq
    test eax, eax
    jz .d_del
    lea rdi, [r14+8]
    lea rsi, [r15-8]
    call parse_dec
    test rax, rax
    jz .notfound
    mov [rsp+A_ID], rax
    cmp qword [rsp+A_SESS], -1
    je .to_login
    jmp .confirm
.d_del:
    cmp r15, 7
    jne .d_save
    mov rdi, r14
    mov rsi, a_p_delete
    mov edx, 7
    call mem_eq
    test eax, eax
    jz .d_save
    cmp qword [rsp+A_POST], 0
    je .to_admin
    cmp qword [rsp+A_SESS], -1
    je .to_login
    jmp .do_delete
.d_save:
    cmp r15, 5
    jne .d_set
    mov rdi, r14
    mov rsi, a_p_save
    mov edx, 5
    call mem_eq
    test eax, eax
    jz .d_set
    cmp qword [rsp+A_POST], 0
    je .to_admin
    cmp qword [rsp+A_SESS], -1
    je .to_login
    jmp .do_save
.d_set:
    cmp r15, 9
    jne .d_prev
    mov rdi, r14
    mov rsi, a_p_settings
    mov edx, 9
    call mem_eq
    test eax, eax
    jz .d_prev
    cmp qword [rsp+A_SESS], -1
    je .to_login
    cmp qword [rsp+A_POST], 0
    jne .do_settings
    jmp .settings_page
.d_prev:
    cmp r15, 8
    jne .notfound
    mov rdi, r14
    mov rsi, a_p_preview
    mov edx, 8
    call mem_eq
    test eax, eax
    jz .notfound
    cmp qword [rsp+A_POST], 0
    je .to_admin
    cmp qword [rsp+A_SESS], -1
    je .to_login
    jmp .do_preview

; ---- dashboard ---------------------------------------------------------
.dash_gate:
    cmp qword [rsp+A_POST], 0
    jne .method405
    cmp qword [rsp+A_SESS], -1
    je .to_login
    mov rdi, store_lock
    call rd_lock
    lea rdi, [rsp+A_RW]
    lea rsi, [r12+CTX_OUT+CTX_MDHTML_OFF]
    lea rdx, [r12+CTX_OUT+CTX_MDHTML_END]
    call w_init
    xor ebx, ebx
.drow:
    cmp rbx, [posts_cnt]
    jae .drows_done
    mov rax, [posts_arr]
    mov r13, [rax+rbx*8]
    lea rdi, [rsp+A_RW]
    mov rsi, r_tr1
    mov edx, r_tr1_len
    call emit
    lea rdi, [rsp+A_RW]
    mov rsi, [r13+P_ID]
    call emit_u64
    lea rdi, [rsp+A_RW]
    mov rsi, r_tr2
    mov edx, r_tr2_len
    call emit
    lea rdi, [rsp+A_RW]
    mov rsi, [r13+P_TITLE_P]
    mov rdx, [r13+P_TITLE_L]
    call emit_esc
    lea rdi, [rsp+A_RW]
    mov rsi, r_tr3
    mov edx, r_tr3_len
    call emit
    mov rdi, [r13+P_CREATED]
    lea rsi, [rsp+A_DATE]
    call fmt_date_local
    lea rsi, [rsp+A_DATE]
    mov rdx, rax
    sub rdx, rsi
    lea rdi, [rsp+A_RW]
    call emit
    lea rdi, [rsp+A_RW]
    mov rsi, r_tr4
    mov edx, r_tr4_len
    call emit
    mov edi, S_DRAFT
    test qword [r13+P_FLAGS], FLAG_PUBLISHED
    jz .status
    mov edi, S_PUB
.status:
    call i18n_get
    mov rsi, rax
    lea rdi, [rsp+A_RW]
    call emit
    lea rdi, [rsp+A_RW]
    mov rsi, r_tr5
    mov edx, r_tr5_len
    call emit
    lea rdi, [rsp+A_RW]
    mov rsi, [r13+P_ID]
    call emit_u64
    lea rdi, [rsp+A_RW]
    mov rsi, r_tr6a             ; ">
    mov edx, r_tr6a_len
    call emit
    mov edi, S_DEL_LINK
    call i18n_get
    mov rsi, rax
    lea rdi, [rsp+A_RW]
    call emit
    lea rdi, [rsp+A_RW]
    mov rsi, r_tr6b             ; </a></td></tr>
    mov edx, r_tr6b_len
    call emit
    inc rbx
    jmp .drow
.drows_done:
    lea rax, [r12+CTX_OUT+CTX_MDHTML_OFF]
    mov [rsp+A_VALS+V_ROWS*16], rax
    mov rcx, [rsp+A_RW]
    sub rcx, rax
    mov [rsp+A_VALS+V_ROWS*16+8], rcx
    mov edi, S_T_ADMIN
    call i18n_get
    mov [rsp+A_VALS+V_TITLE*16], rax
    mov [rsp+A_VALS+V_TITLE*16+8], rdx
    mov rdi, r12
    lea rsi, [rsp+A_VALS]
    mov edx, T_ADASH
    mov ecx, 1                  ; unlock store after render
    call admin_render
    jmp .done

; ---- login -------------------------------------------------------------
.login_page:                    ; rax = err ptr (0 none), rcx = err len
    mov [rsp+A_VALS+V_ERR*16], rax
    mov [rsp+A_VALS+V_ERR*16+8], rcx
    mov edi, S_T_LOGIN
    call i18n_get
    mov [rsp+A_VALS+V_TITLE*16], rax
    mov [rsp+A_VALS+V_TITLE*16+8], rdx
    mov rdi, r12
    lea rsi, [rsp+A_VALS]
    mov edx, T_ALOGIN
    xor ecx, ecx
    call admin_render
    jmp .done

.do_login:
    call parse_body
    test rax, rax
    jnz .badreq
    call login_allowed
    test eax, eax
    jnz .rate_ok
    mov edi, S_E_WAIT
    call i18n_get
    mov rcx, rdx
    jmp .login_page
.rate_ok:
    cmp byte [set_present], 0
    jne .have_pw
    mov edi, S_E_NOPW
    call i18n_get
    mov rcx, rdx
    jmp .login_page
.have_pw:
    mov rsi, [rsp+A_FLD+FI_PASSWORD*16+8]
    test rsi, rsi
    jz .lfail
    mov rdi, [rsp+A_FLD+FI_PASSWORD*16]
    call crypto_verify_remote
    test rax, rax
    jnz .lfail
    call login_ok
    lea rdi, [rsp+A_SIDBUF]
    lea rsi, [rsp+A_CSRFBUF]
    call session_create
    lea rdi, [rsp+A_CK]         ; sid=<hex>; HttpOnly; ...
    mov rsi, a_ck1
    mov edx, a_ck1_len
    call mem_copy
    mov rdi, rax
    lea rsi, [rsp+A_SIDBUF]
    mov edx, 64
    call mem_copy
    mov rdi, rax
    mov rsi, a_ck2
    mov edx, a_ck2_len
    call mem_copy
    lea rcx, [rsp+A_CK]
    mov r8, rax
    sub r8, rcx
    mov rdi, r12
    mov rsi, a_loc_admin
    mov edx, a_loc_admin_len
    call finish_redirect
    jmp .done
.lfail:
    call login_failed
    mov edi, S_E_WRONG
    call i18n_get
    mov rcx, rdx
    jmp .login_page

.do_logout:
    call parse_body
    test rax, rax
    jnz .badreq
    cmp qword [rsp+A_SESS], -1
    je .lo_redir
    mov rdi, [rsp+A_SESS]
    mov rsi, [rsp+A_FLD+FI_CSRF*16]
    mov rdx, [rsp+A_FLD+FI_CSRF*16+8]
    call session_csrf_ok
    test eax, eax
    jz .badreq
    mov rdi, [rsp+A_SESS]
    call session_destroy
.lo_redir:
    mov rdi, r12
    mov rsi, a_loc_root
    mov edx, a_loc_root_len
    mov rcx, a_ckclear
    mov r8, a_ckclear_len
    call finish_redirect
    jmp .done

; ---- editor ------------------------------------------------------------
.editor:                        ; [rsp+A_ID] = 0 for new
    mov rax, [rsp+A_ID]
    test rax, rax
    jz .ed_blank
    mov rdi, store_lock
    call rd_lock
    mov rdi, [rsp+A_ID]
    call store_find_by_id
    test rax, rax
    jz .ed_missing
    mov r13, rax
    mov rax, [r13+P_TITLE_P]
    mov [rsp+A_VALS+V_ETITLE*16], rax
    mov rax, [r13+P_TITLE_L]
    mov [rsp+A_VALS+V_ETITLE*16+8], rax
    mov rax, [r13+P_SLUG_P]
    mov [rsp+A_VALS+V_ESLUG*16], rax
    mov rax, [r13+P_SLUG_L]
    mov [rsp+A_VALS+V_ESLUG*16+8], rax
    mov rax, [r13+P_TAGS_P]
    mov [rsp+A_VALS+V_ETAGS*16], rax
    mov rax, [r13+P_TAGS_L]
    mov [rsp+A_VALS+V_ETAGS*16+8], rax
    mov rax, [r13+P_MD_P]
    mov [rsp+A_VALS+V_EMD*16], rax
    mov rax, [r13+P_MD_L]
    mov [rsp+A_VALS+V_EMD*16+8], rax
    call set_id_val
    mov edi, S_T_EDITOR
    call i18n_get
    mov [rsp+A_VALS+V_TITLE*16], rax
    mov [rsp+A_VALS+V_TITLE*16+8], rdx
    mov rdi, r12
    lea rsi, [rsp+A_VALS]
    mov edx, T_AEDIT
    mov ecx, 1
    call admin_render
    jmp .done
.ed_missing:
    mov rdi, store_lock
    call rd_unlock
    jmp .notfound
.ed_blank:
    call set_id_val
    mov edi, S_T_EDITOR
    call i18n_get
    mov [rsp+A_VALS+V_TITLE*16], rax
    mov [rsp+A_VALS+V_TITLE*16+8], rdx
    mov rdi, r12
    lea rsi, [rsp+A_VALS]
    mov edx, T_AEDIT
    xor ecx, ecx
    call admin_render
    jmp .done

; ---- delete confirm + delete -------------------------------------------
.confirm:
    mov rdi, store_lock
    call rd_lock
    mov rdi, [rsp+A_ID]
    call store_find_by_id
    test rax, rax
    jz .ed_missing
    mov r13, rax
    mov rax, [r13+P_TITLE_P]
    mov [rsp+A_VALS+V_ETITLE*16], rax
    mov rax, [r13+P_TITLE_L]
    mov [rsp+A_VALS+V_ETITLE*16+8], rax
    call set_id_val
    mov edi, S_T_DELETE
    call i18n_get
    mov [rsp+A_VALS+V_TITLE*16], rax
    mov [rsp+A_VALS+V_TITLE*16+8], rdx
    mov rdi, r12
    lea rsi, [rsp+A_VALS]
    mov edx, T_ACONF
    mov ecx, 1
    call admin_render
    jmp .done

.do_delete:
    call parse_body
    test rax, rax
    jnz .badreq
    call csrf_check
    test eax, eax
    jz .badreq
    mov rdi, [rsp+A_FLD+FI_ID*16]
    mov rsi, [rsp+A_FLD+FI_ID*16+8]
    call parse_dec
    test rax, rax
    jz .notfound
    mov rdi, rax
    call store_delete_post
    test rax, rax
    jnz .notfound
    jmp .to_admin

; ---- save ---------------------------------------------------------------
.do_save:
    call parse_body
    test rax, rax
    jnz .badreq
    call csrf_check
    test eax, eax
    jz .badreq
    mov rdi, [rsp+A_FLD+FI_ID*16]
    mov rsi, [rsp+A_FLD+FI_ID*16+8]
    call parse_dec
    mov [rsp+A_ID], rax         ; 0 = new post
    ; title 1..256
    mov rax, [rsp+A_FLD+FI_TITLE*16+8]
    test rax, rax
    jz .sv_etitle
    cmp rax, 256
    ja .sv_etitle
    ; slug: given or derived from the title
    mov rax, [rsp+A_FLD+FI_SLUG*16+8]
    test rax, rax
    jnz .slug_given
    lea rdi, [rsp+A_SLUG]
    mov rsi, [rsp+A_FLD+FI_TITLE*16]
    mov rdx, [rsp+A_FLD+FI_TITLE*16+8]
    mov ecx, 64
    call slugify
    test rax, rax
    jz .sv_eslug
    lea rcx, [rsp+A_SLUG]
    mov [rsp+A_FLD+FI_SLUG*16], rcx
    mov [rsp+A_FLD+FI_SLUG*16+8], rax
    jmp .slug_ok
.slug_given:
    mov rdi, [rsp+A_FLD+FI_SLUG*16]
    mov rsi, rax
    mov edx, 128
    call valid_seg
    test eax, eax
    jz .sv_eslug
.slug_ok:
    ; slug collision (other id)?
    mov rdi, store_lock
    call rd_lock
    xor ebx, ebx
.dup:
    cmp rbx, [posts_cnt]
    jae .dup_done
    mov rax, [posts_arr]
    mov r13, [rax+rbx*8]
    mov rax, [rsp+A_FLD+FI_SLUG*16+8]
    cmp rax, [r13+P_SLUG_L]
    jne .dup_next
    mov rax, [r13+P_ID]
    cmp rax, [rsp+A_ID]
    je .dup_next
    mov rdi, [r13+P_SLUG_P]
    mov rsi, [rsp+A_FLD+FI_SLUG*16]
    mov rdx, [rsp+A_FLD+FI_SLUG*16+8]
    call mem_eq
    test eax, eax
    jnz .dup_hit
.dup_next:
    inc rbx
    jmp .dup
.dup_hit:
    mov rdi, store_lock
    call rd_unlock
    jmp .sv_eslugdup
.dup_done:
    mov rdi, store_lock
    call rd_unlock
    ; tags <= 256
    cmp qword [rsp+A_FLD+FI_TAGS*16+8], 256
    ja .sv_etags
    ; markdown <= MD_MAX
    cmp qword [rsp+A_FLD+FI_MD*16+8], MD_MAX
    ja .sv_emd
    ; render markdown
    lea rdi, [rsp+A_RW]
    lea rsi, [r12+CTX_OUT+CTX_MDHTML_OFF]
    lea rdx, [r12+CTX_OUT+CTX_MDHTML_END]
    call w_init
    lea rdi, [rsp+A_RW]
    mov rsi, [rsp+A_FLD+FI_MD*16]
    mov rdx, [rsp+A_FLD+FI_MD*16+8]
    call md_render
    lea rdi, [rsp+A_RW]
    call w_ovf
    test eax, eax
    jnz .sv_emd
    ; append spec
    lea rdi, [rsp+A_SPEC]
    mov ecx, S_SIZE/8
    xor eax, eax
    rep stosq
    mov rax, [rsp+A_ID]
    mov [rsp+A_SPEC+S_ID], rax
    ; action "draft" keeps it unpublished
    mov rax, [rsp+A_FLD+FI_ACTION*16+8]
    cmp rax, 5
    jne .publish
    mov rdi, [rsp+A_FLD+FI_ACTION*16]
    mov rsi, a_act_draft
    mov edx, 5
    call mem_eq
    test eax, eax
    jnz .flags_done
.publish:
    mov qword [rsp+A_SPEC+S_FLAGS], FLAG_PUBLISHED
.flags_done:
    mov rax, [rsp+A_FLD+FI_TITLE*16]
    mov [rsp+A_SPEC+S_TITLE_P], rax
    mov rax, [rsp+A_FLD+FI_TITLE*16+8]
    mov [rsp+A_SPEC+S_TITLE_L], rax
    mov rax, [rsp+A_FLD+FI_SLUG*16]
    mov [rsp+A_SPEC+S_SLUG_P], rax
    mov rax, [rsp+A_FLD+FI_SLUG*16+8]
    mov [rsp+A_SPEC+S_SLUG_L], rax
    mov rax, [rsp+A_FLD+FI_TAGS*16]
    mov [rsp+A_SPEC+S_TAGS_P], rax
    mov rax, [rsp+A_FLD+FI_TAGS*16+8]
    mov [rsp+A_SPEC+S_TAGS_L], rax
    mov rax, [rsp+A_FLD+FI_MD*16]
    mov [rsp+A_SPEC+S_MD_P], rax
    mov rax, [rsp+A_FLD+FI_MD*16+8]
    mov [rsp+A_SPEC+S_MD_L], rax
    lea rax, [r12+CTX_OUT+CTX_MDHTML_OFF]
    mov [rsp+A_SPEC+S_HTML_P], rax
    mov rcx, [rsp+A_RW]
    sub rcx, rax
    mov [rsp+A_SPEC+S_HTML_L], rcx
    lea rdi, [rsp+A_SPEC]
    call store_append_post
    test rax, rax
    js .sv_efail
    jmp .to_admin
.sv_etitle:
    mov edi, S_E_TITLE
    call i18n_get
    mov rcx, rdx
    jmp .save_err
.sv_eslug:
    mov edi, S_E_SLUG
    call i18n_get
    mov rcx, rdx
    jmp .save_err
.sv_eslugdup:
    mov edi, S_E_SLUGDUP
    call i18n_get
    mov rcx, rdx
    jmp .save_err
.sv_etags:
    mov edi, S_E_TAGS
    call i18n_get
    mov rcx, rdx
    jmp .save_err
.sv_emd:
    mov edi, S_E_MD
    call i18n_get
    mov rcx, rdx
    jmp .save_err
.sv_efail:
    mov edi, S_E_SAVE
    call i18n_get
    mov rcx, rdx
.save_err:                      ; editor again, fields repopulated
    mov [rsp+A_VALS+V_ERR*16], rax
    mov [rsp+A_VALS+V_ERR*16+8], rcx
    mov rax, [rsp+A_FLD+FI_TITLE*16]
    mov [rsp+A_VALS+V_ETITLE*16], rax
    mov rax, [rsp+A_FLD+FI_TITLE*16+8]
    mov [rsp+A_VALS+V_ETITLE*16+8], rax
    mov rax, [rsp+A_FLD+FI_SLUG*16]
    mov [rsp+A_VALS+V_ESLUG*16], rax
    mov rax, [rsp+A_FLD+FI_SLUG*16+8]
    mov [rsp+A_VALS+V_ESLUG*16+8], rax
    mov rax, [rsp+A_FLD+FI_TAGS*16]
    mov [rsp+A_VALS+V_ETAGS*16], rax
    mov rax, [rsp+A_FLD+FI_TAGS*16+8]
    mov [rsp+A_VALS+V_ETAGS*16+8], rax
    mov rax, [rsp+A_FLD+FI_MD*16]
    mov [rsp+A_VALS+V_EMD*16], rax
    mov rax, [rsp+A_FLD+FI_MD*16+8]
    mov [rsp+A_VALS+V_EMD*16+8], rax
    call set_id_val
    mov edi, S_T_EDITOR
    call i18n_get
    mov [rsp+A_VALS+V_TITLE*16], rax
    mov [rsp+A_VALS+V_TITLE*16+8], rdx
    mov rdi, r12
    lea rsi, [rsp+A_VALS]
    mov edx, T_AEDIT
    xor ecx, ecx
    call admin_render
    jmp .done

; ---- settings ------------------------------------------------------------
.settings_page:
    mov rdi, store_lock
    call rd_lock
    mov rax, [set_title_p]
    mov rcx, [set_title_l]
    test rcx, rcx
    jnz .sp_site
    mov rax, a_def_site
    mov rcx, a_def_site_len
.sp_site:
    mov [rsp+A_VALS+V_ESITE*16], rax
    mov [rsp+A_VALS+V_ESITE*16+8], rcx
    mov edi, [set_ppp]
    lea rsi, [rsp+A_NUM2]
    call u64_to_dec
    lea rcx, [rsp+A_NUM2]
    sub rax, rcx
    mov [rsp+A_VALS+V_EPPP*16], rcx
    mov [rsp+A_VALS+V_EPPP*16+8], rax
    mov rax, [set_banner_p]     ; current banner into the form
    mov [rsp+A_VALS+V_EBANNER*16], rax
    mov rax, [set_banner_l]
    mov [rsp+A_VALS+V_EBANNER*16+8], rax
    mov qword [rsp+A_VALS+V_EURL*16], set_url
    mov rax, [set_url_l]
    mov [rsp+A_VALS+V_EURL*16+8], rax
    ; pre-check the radio for the active theme
    cmp dword [set_theme], 1
    je .sp_sucre
    mov qword [rsp+A_VALS+V_SELRETRO*16], a_checked
    mov qword [rsp+A_VALS+V_SELRETRO*16+8], a_checked_len
    jmp .sp_theme_done
.sp_sucre:
    mov qword [rsp+A_VALS+V_SELSUCRE*16], a_checked
    mov qword [rsp+A_VALS+V_SELSUCRE*16+8], a_checked_len
.sp_theme_done:
    call set_locale_radios
    mov edi, S_T_SETTINGS
    call i18n_get
    mov [rsp+A_VALS+V_TITLE*16], rax
    mov [rsp+A_VALS+V_TITLE*16+8], rdx
    mov rdi, r12
    lea rsi, [rsp+A_VALS]
    mov edx, T_ASET
    mov ecx, 1
    call admin_render
    jmp .done

.do_settings:
    call parse_body
    test rax, rax
    jnz .badreq
    call csrf_check
    test eax, eax
    jz .badreq
    mov rax, [rsp+A_FLD+FI_TITLE*16+8]
    test rax, rax
    jz .st_err
    cmp rax, 120
    ja .st_err
    mov rdi, [rsp+A_FLD+FI_PPP*16]
    mov rsi, [rsp+A_FLD+FI_PPP*16+8]
    call parse_dec
    test rax, rax
    jz .st_err
    cmp rax, 50
    ja .st_err
    mov [rsp+A_ID], rax         ; borrow the slot for ppp
    cmp qword [rsp+A_FLD+FI_BANNER*16+8], 200   ; banner bound
    ja .st_err
    ; theme: "sucre" selects 1, anything else 0 (retro)
    xor r13d, r13d
    cmp qword [rsp+A_FLD+FI_THEME*16+8], 5
    jne .theme_set
    mov rdi, [rsp+A_FLD+FI_THEME*16]
    mov rsi, a_theme_sucre
    mov edx, 5
    call mem_eq
    test eax, eax
    jz .theme_set
    mov r13d, 1
.theme_set:
    mov [set_theme], r13d       ; store_save_settings persists [set_theme]
    ; locale: "es" selects es-BO (1), anything else en-US (0)
    xor r13d, r13d
    cmp qword [rsp+A_FLD+FI_LOCALE*16+8], 2
    jne .locale_set
    mov rax, [rsp+A_FLD+FI_LOCALE*16]
    cmp word [rax], 'es'
    jne .locale_set
    mov r13d, 1
.locale_set:
    mov [set_locale], r13d      ; persisted alongside the theme
    ; optional password change
    mov rax, [rsp+A_FLD+FI_PASSWORD*16+8]
    test rax, rax
    jz .save_settings          ; blank: keep the current [set_hash]
    cmp rax, 8
    jb .st_epw
    cmp rax, [rsp+A_FLD+FI_PASSWORD2*16+8]
    jne .st_epw
    mov rdi, [rsp+A_FLD+FI_PASSWORD*16]
    mov rsi, [rsp+A_FLD+FI_PASSWORD2*16]
    mov rdx, rax
    call mem_eq
    test eax, eax
    jz .st_epw
    mov rdi, [rsp+A_FLD+FI_PASSWORD*16]
    mov rsi, [rsp+A_FLD+FI_PASSWORD*16+8]
    lea rdx, [rsp+A_HASH]
    call crypto_hash_remote
    test rax, rax
    jnz .st_err
    lea rdi, set_hash          ; stage the new hash for the store to persist
    lea rsi, [rsp+A_HASH]
    mov edx, 128
    call mem_copy
.save_settings:
    mov rdi, [rsp+A_FLD+FI_URL*16]     ; public site url (may be blank)
    mov rsi, [rsp+A_FLD+FI_URL*16+8]
    call settings_set_url
    test rax, rax
    jnz .st_err
    mov rdi, [rsp+A_ID]        ; ppp
    mov esi, [set_ttl]
    mov rdx, [rsp+A_FLD+FI_TITLE*16]
    mov rcx, [rsp+A_FLD+FI_TITLE*16+8]
    mov r8, [rsp+A_FLD+FI_BANNER*16]
    mov r9, [rsp+A_FLD+FI_BANNER*16+8]
    call store_save_settings
    test rax, rax
    jnz .st_err
    jmp .to_admin
.st_epw:
    mov edi, S_E_PW
    call i18n_get
    mov rcx, rdx
    jmp .set_err
.st_err:
    mov edi, S_E_SET
    call i18n_get
    mov rcx, rdx
.set_err:
    mov [rsp+A_VALS+V_ERR*16], rax
    mov [rsp+A_VALS+V_ERR*16+8], rcx
    mov rax, [rsp+A_FLD+FI_TITLE*16]
    mov [rsp+A_VALS+V_ESITE*16], rax
    mov rax, [rsp+A_FLD+FI_TITLE*16+8]
    mov [rsp+A_VALS+V_ESITE*16+8], rax
    mov rax, [rsp+A_FLD+FI_PPP*16]
    mov [rsp+A_VALS+V_EPPP*16], rax
    mov rax, [rsp+A_FLD+FI_PPP*16+8]
    mov [rsp+A_VALS+V_EPPP*16+8], rax
    mov rax, [rsp+A_FLD+FI_BANNER*16]
    mov [rsp+A_VALS+V_EBANNER*16], rax
    mov rax, [rsp+A_FLD+FI_BANNER*16+8]
    mov [rsp+A_VALS+V_EBANNER*16+8], rax
    mov rax, [rsp+A_FLD+FI_URL*16]
    mov [rsp+A_VALS+V_EURL*16], rax
    mov rax, [rsp+A_FLD+FI_URL*16+8]
    mov [rsp+A_VALS+V_EURL*16+8], rax
    cmp dword [set_theme], 1
    je .se_sucre
    mov qword [rsp+A_VALS+V_SELRETRO*16], a_checked
    mov qword [rsp+A_VALS+V_SELRETRO*16+8], a_checked_len
    jmp .se_theme_done
.se_sucre:
    mov qword [rsp+A_VALS+V_SELSUCRE*16], a_checked
    mov qword [rsp+A_VALS+V_SELSUCRE*16+8], a_checked_len
.se_theme_done:
    call set_locale_radios
    mov edi, S_T_SETTINGS
    call i18n_get
    mov [rsp+A_VALS+V_TITLE*16], rax
    mov [rsp+A_VALS+V_TITLE*16+8], rdx
    mov rdi, r12
    lea rsi, [rsp+A_VALS]
    mov edx, T_ASET
    xor ecx, ecx
    call admin_render
    jmp .done

; ---- preview -------------------------------------------------------------
.do_preview:
    call parse_body
    test rax, rax
    jnz .badreq
    call csrf_check
    test eax, eax
    jz .badreq
    cmp qword [rsp+A_FLD+FI_MD*16+8], MD_MAX
    ja .sv_emd
    lea rdi, [rsp+A_RW]
    lea rsi, [r12+CTX_OUT+CTX_MDHTML_OFF]
    lea rdx, [r12+CTX_OUT+CTX_MDHTML_END]
    call w_init
    lea rdi, [rsp+A_RW]
    mov rsi, [rsp+A_FLD+FI_MD*16]
    mov rdx, [rsp+A_FLD+FI_MD*16+8]
    call md_render
    lea rdi, [rsp+A_RW]
    call w_ovf
    test eax, eax
    jnz .sv_emd
    lea rax, [r12+CTX_OUT+CTX_MDHTML_OFF]
    mov [rsp+A_VALS+V_HTML*16], rax
    mov rcx, [rsp+A_RW]
    sub rcx, rax
    mov [rsp+A_VALS+V_HTML*16+8], rcx
    mov rax, [rsp+A_FLD+FI_TITLE*16]
    mov rcx, [rsp+A_FLD+FI_TITLE*16+8]
    test rcx, rcx
    jnz .pv_title
    mov edi, S_T_PREVIEW
    call i18n_get
    mov rcx, rdx
.pv_title:
    mov [rsp+A_VALS+V_TITLE*16], rax
    mov [rsp+A_VALS+V_TITLE*16+8], rcx
    mov edi, S_PREVDATE
    call i18n_get
    mov [rsp+A_VALS+V_DATE*16], rax
    mov [rsp+A_VALS+V_DATE*16+8], rdx
    mov rdi, r12
    lea rsi, [rsp+A_VALS]
    mov edx, T_POST
    xor ecx, ecx
    call admin_render
    jmp .done

; ---- shared exits ---------------------------------------------------------
.to_login:
    mov rdi, r12
    mov rsi, a_loc_login
    mov edx, a_loc_login_len
    xor ecx, ecx
    xor r8d, r8d
    call finish_redirect
    jmp .done
.to_admin:
    mov rdi, r12
    mov rsi, a_loc_admin
    mov edx, a_loc_admin_len
    xor ecx, ecx
    xor r8d, r8d
    call finish_redirect
    jmp .done
.method405:
    mov rdi, r12
    mov esi, 3
    call build_page
    jmp .done
.badreq:
    mov rdi, r12
    mov esi, 4
    call build_page
    jmp .done
.notfound:
    mov rdi, r12
    mov esi, 2
    call build_page
.done:
    add rsp, A_FRAME
    pop rbp
    pop rbx
    pop r15
    pop r14
    pop r13
    pop r12
    ret

; ---- helpers that reach into admin_route's frame -------------------------
; (called with admin_route's rsp intact; frame slots are +8 for the
;  helper's own return address)

; parse_body — decode the form body into the DECODE region and fill
; the field table. rax = 0 ok / -1 malformed.
parse_body:
    lea rdi, [rsp+8+A_FLD]      ; absent fields must read as (0, 0)
    mov ecx, FIELD_N*2
    xor eax, eax
    rep stosq
    lea rdi, [r12+CTX_IN]
    add rdi, [rsp+8+A_HLEN]
    mov rsi, [rsp+8+A_BLEN]
    lea rdx, [r12+CTX_OUT+CTX_DECODE_OFF]
    mov rcx, CTX_DECODE_END - CTX_DECODE_OFF
    lea r8, [rsp+8+A_FLD]
    jmp form_parse              ; tail call; returns to our caller

; csrf_check — rax = 1 if the posted csrf matches the session token.
csrf_check:
    cmp qword [rsp+8+A_SESS], -1
    je .no
    mov rdi, [rsp+8+A_SESS]
    mov rsi, [rsp+8+A_FLD+FI_CSRF*16]
    mov rdx, [rsp+8+A_FLD+FI_CSRF*16+8]
    call session_csrf_ok
    ret
.no:
    xor eax, eax
    ret

; set_locale_radios — pre-check the language radio for [set_locale].
set_locale_radios:
    cmp dword [set_locale], 1
    je .es
    mov qword [rsp+8+A_VALS+V_SELEN*16], a_checked
    mov qword [rsp+8+A_VALS+V_SELEN*16+8], a_checked_len
    ret
.es:
    mov qword [rsp+8+A_VALS+V_SELES*16], a_checked
    mov qword [rsp+8+A_VALS+V_SELES*16+8], a_checked_len
    ret

; set_id_val — format [rsp+A_ID] into A_NUM and set V_ID.
set_id_val:
    mov rdi, [rsp+8+A_ID]
    lea rsi, [rsp+8+A_NUM]
    call u64_to_dec
    lea rcx, [rsp+8+A_NUM]
    sub rax, rcx
    mov [rsp+8+A_VALS+V_ID*16], rcx
    mov [rsp+8+A_VALS+V_ID*16+8], rax
    ret

; ---- standalone helpers ---------------------------------------------------

; admin_render(ctx, vals, tmpl_id, locked)
; content template -> SCRATCH, shell -> BODY, then finish_page.
; If locked != 0, store_lock's read side is released after rendering.
admin_render:
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
    sub rsp, 56
    mov rdi, rsp
    lea rsi, [r12+CTX_OUT+CTX_SCRATCH_OFF]
    lea rdx, [r12+CTX_OUT+CTX_SCRATCH_END]
    call w_init
    mov rdi, rsp
    mov rsi, r14
    mov rdx, r13
    call tmpl_render
    lea rax, [r12+CTX_OUT+CTX_SCRATCH_OFF]
    mov [r13+V_CONTENT*16], rax
    mov rcx, [rsp]
    sub rcx, rax
    mov [r13+V_CONTENT*16+8], rcx
    lea rdi, [rsp+24]
    lea rsi, [r12+CTX_OUT+CTX_BODY_OFF]
    lea rdx, [r12+CTX_OUT+CTX_BODY_END]
    call w_init
    lea rdi, [rsp+24]
    mov esi, T_SHELL
    mov rdx, r13
    call tmpl_render
    test r15, r15
    jz .nolock
    mov rdi, store_lock
    call rd_unlock
.nolock:
    mov rdi, rsp
    call w_ovf
    test eax, eax
    jnz .fail
    lea rdi, [rsp+24]
    call w_ovf
    test eax, eax
    jnz .fail
    lea rsi, [r12+CTX_OUT+CTX_BODY_OFF]
    mov rax, [rsp+24]
    sub rax, rsi
    mov rdi, r12
    mov rsi, rax
    mov rdx, a_ct_html
    mov ecx, a_ct_html_len
    xor r8d, r8d
    xor r9d, r9d
    call finish_page
    jmp .ret
.fail:
    mov rdi, r12
    mov esi, 5
    call build_page
.ret:
    add rsp, 56
    pop r15
    pop r14
    pop r13
    pop r12
    ret

; finish_redirect(ctx, loc_p, loc_l, cookie_p, cookie_l) — 303, no body.
finish_redirect:
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
    sub rsp, 1024
    mov rdi, rsp
    mov rsi, a_303
    mov edx, a_303_len
    call mem_copy
    mov rdi, rax
    call emit_date_hdr
    mov rdi, rax
    mov rsi, sec_headers
    mov edx, sec_headers_len
    call mem_copy
    cmp byte [r12+CTX_KEEP], 0
    je .cl
    mov rsi, a_ka
    mov edx, a_ka_len
    jmp .conn
.cl:
    mov rsi, a_cl
    mov edx, a_cl_len
.conn:
    mov rdi, rax
    call mem_copy
    mov rdi, rax
    mov rsi, a_nostore
    mov edx, a_nostore_len
    call mem_copy
    mov rdi, rax
    mov rsi, a_loc_hdr
    mov edx, a_loc_hdr_len
    call mem_copy
    mov rdi, rax
    mov rsi, r13
    mov rdx, r14
    call mem_copy
    mov rdi, rax
    mov rsi, a_crlf
    mov edx, 2
    call mem_copy
    test rbx, rbx
    jz .nocookie
    mov rdi, rax
    mov rsi, a_setck
    mov edx, a_setck_len
    call mem_copy
    mov rdi, rax
    mov rsi, r15
    mov rdx, rbx
    call mem_copy
    mov rdi, rax
    mov rsi, a_crlf
    mov edx, 2
    call mem_copy
.nocookie:
    mov rdi, rax
    mov rsi, a_cl0
    mov edx, a_cl0_len
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
    mov [r12+CTX_OUT_LEN], rbx
    mov qword [r12+CTX_OUT_SENT], 0
    add rsp, 1024
    pop rbx
    pop r15
    pop r14
    pop r13
    pop r12
    ret

; cookie_sid(headers, len) -> rax = sid value ptr (0 none), rdx = len
cookie_sid:
    push r12
    push r13
    push r14
    push r15
    push rbx
    mov r12, rdi
    mov r13, rsi
.line:
    test r13, r13
    jz .none
    xor r14d, r14d
.fcr:
    cmp r14, r13
    jae .none
    cmp byte [r12+r14], 13
    je .have
    inc r14
    jmp .fcr
.have:
    cmp r14, 7
    jb .adv
    mov rdi, r12
    mov rsi, a_cookie_lc
    mov edx, 7
    call ci_prefix
    test eax, eax
    jz .adv
    lea r15, [r12+7]            ; cookie header value
    mov rbx, r14
    sub rbx, 7
.pair:
    test rbx, rbx
    jz .adv                     ; sid not in this header; keep scanning
    mov al, [r15]
    cmp al, ' '
    je .skip1
    cmp al, ';'
    jne .name
.skip1:
    inc r15
    dec rbx
    jmp .pair
.name:
    xor ecx, ecx
.fn:
    cmp rcx, rbx
    jae .adv                    ; no '=': give up on this header
    cmp byte [r15+rcx], '='
    je .fnd
    inc rcx
    jmp .fn
.fnd:
    lea rdx, [rcx+1]            ; value start index
    mov rax, rdx
.fv:
    cmp rax, rbx
    jae .vend
    cmp byte [r15+rax], ';'
    je .vend
    inc rax
    jmp .fv
.vend:
    cmp rcx, 3
    jne .next_pair
    cmp word [r15], 'si'
    jne .next_pair
    cmp byte [r15+2], 'd'
    jne .next_pair
    mov r9, rax
    sub r9, rdx                 ; value length
    lea rax, [r15+rdx]
    mov rdx, r9
    jmp .ret
.next_pair:
    add r15, rax
    sub rbx, rax
    jmp .pair
.adv:
    lea rax, [r14+2]
    cmp rax, r13
    ja .none
    add r12, rax
    sub r13, rax
    jmp .line
.none:
    xor eax, eax
    xor edx, edx
.ret:
    pop rbx
    pop r15
    pop r14
    pop r13
    pop r12
    ret

; form_parse(body_p, body_l, dst, dst_cap, fields) -> 0 / -1
; Decodes application/x-www-form-urlencoded params for known field
; names into dst; unknown params are skipped. Rejects (rather than
; truncates) values that would overflow the decode region.
form_parse:
    push r12
    push r13
    push r14
    push r15
    push rbx
    push rbp
    mov r12, rdi                ; body cursor
    mov r13, rsi                ; body remaining
    mov r14, rdx                ; dst cursor
    mov r15, rcx                ; dst remaining
    mov rbx, r8                 ; fields
.param:
    test r13, r13
    jz .ok
    xor ebp, ebp
.famp:
    cmp rbp, r13
    jae .seg
    cmp byte [r12+rbp], '&'
    je .seg
    inc rbp
    jmp .famp
.seg:
    xor ecx, ecx
.feq:
    cmp rcx, rbp
    jae .skip                   ; no '=': ignore the param
    cmp byte [r12+rcx], '='
    je .haveq
    inc rcx
    jmp .feq
.haveq:
    xor r9d, r9d
.match:
    cmp r9, FIELD_N
    jae .skip
    lea rax, [r9+r9*2]
    lea rax, [fld_names + rax*8]
    cmp rcx, [rax+8]
    jne .match_next
    push rcx
    push r9
    mov rdi, r12
    mov rsi, [rax]
    mov rdx, rcx
    call mem_eq
    pop r9
    pop rcx
    test eax, eax
    jnz .matched
.match_next:
    inc r9
    jmp .match
.matched:
    mov rdi, r14
    lea rsi, [r12+rcx+1]
    mov rdx, rbp
    sub rdx, rcx
    dec rdx
    mov rcx, r15
    call percent_decode
    cmp rax, r15
    jae .fail                   ; hit the cap: reject
    shl r9, 4
    mov [rbx+r9], r14
    mov [rbx+r9+8], rax
    add r14, rax
    sub r15, rax
.skip:
    lea rax, [rbp+1]
    cmp rax, r13
    ja .ok
    add r12, rax
    sub r13, rax
    jmp .param
.ok:
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

; slugify(dst, src, len, max) -> length (lowercased [a-z0-9-],
; runs of other characters collapse to single dashes, trimmed)
slugify:
    xor r8d, r8d                ; out length
    mov r9d, 1                  ; suppress leading dash
.loop:
    test rdx, rdx
    jz .done
    cmp r8, rcx
    jae .done
    mov al, [rsi]
    cmp al, 'A'
    jb .lc_done
    cmp al, 'Z'
    ja .lc_done
    or al, 0x20
.lc_done:
    cmp al, 'a'
    jb .chk09
    cmp al, 'z'
    jbe .keep
.chk09:
    cmp al, '0'
    jb .dash
    cmp al, '9'
    jbe .keep
.dash:
    test r9d, r9d
    jnz .adv
    mov byte [rdi+r8], '-'
    inc r8
    mov r9d, 1
    jmp .adv
.keep:
    mov [rdi+r8], al
    inc r8
    xor r9d, r9d
.adv:
    inc rsi
    dec rdx
    jmp .loop
.done:
    test r8, r8
    jz .ret
    cmp byte [rdi+r8-1], '-'
    jne .ret
    dec r8
.ret:
    mov rax, r8
    ret

section .data

a_def_site: db 'blogd'
a_def_site_len equ $-a_def_site
a_ct_html: db 'Content-Type: text/html; charset=utf-8', 13, 10
a_ct_html_len equ $-a_ct_html

a_p_login:    db '/login'
a_p_logout:   db '/logout'
a_p_new:      db '/new'
a_p_edit:     db '/edit/'
a_p_deletes:  db '/delete/'
a_p_delete:   db '/delete'
a_p_save:     db '/save'
a_p_settings: db '/settings'
a_p_preview:  db '/preview'
a_cookie_lc:  db 'cookie:'
a_act_draft:  db 'draft'
a_theme_sucre: db 'sucre'
a_checked: db 'checked'
a_checked_len equ $-a_checked


a_loc_admin: db '/admin'
a_loc_admin_len equ $-a_loc_admin
a_loc_login: db '/admin/login'
a_loc_login_len equ $-a_loc_login
a_loc_root: db '/'
a_loc_root_len equ $-a_loc_root

a_ck1: db 'sid='
a_ck1_len equ $-a_ck1
a_ck2: db '; HttpOnly; Path=/; SameSite=Strict; Max-Age=86400'
a_ck2_len equ $-a_ck2
a_ckclear: db 'sid=0; Path=/; Max-Age=0'
a_ckclear_len equ $-a_ckclear

a_303: db 'HTTP/1.1 303 See Other', 13, 10, 'Server: blogd/0.7', 13, 10
a_303_len equ $-a_303
a_ka: db 'Connection: keep-alive', 13, 10
a_ka_len equ $-a_ka
a_cl: db 'Connection: close', 13, 10
a_cl_len equ $-a_cl
a_loc_hdr: db 'Location: '
a_loc_hdr_len equ $-a_loc_hdr
a_setck: db 'Set-Cookie: '
a_setck_len equ $-a_setck
a_cl0: db 'Content-Length: 0', 13, 10, 13, 10
a_cl0_len equ $-a_cl0
a_crlf: db 13, 10
a_nostore: db 'Cache-Control: no-store', 13, 10
a_nostore_len equ $-a_nostore
a_noindex: db '<meta name="robots" content="noindex">', 10
a_noindex_len equ $-a_noindex

n_password:  db 'password'
n_password2: db 'password2'
n_ftitle:    db 'title'
n_fslug:     db 'slug'
n_ftags:     db 'tags'
n_fmd:       db 'md'
n_fid:       db 'id'
n_faction:   db 'action'
n_fcsrf:     db 'csrf'
n_fppp:      db 'ppp'
n_fbanner:   db 'banner'
n_ftheme:    db 'theme'
n_flocale:   db 'locale'
n_furl:      db 'url'

align 8
fld_names:                      ; {ptr, len, pad}, indexed by FI_*
    dq n_password, 8, 0
    dq n_password2, 9, 0
    dq n_ftitle, 5, 0
    dq n_fslug, 4, 0
    dq n_ftags, 4, 0
    dq n_fmd, 2, 0
    dq n_fid, 2, 0
    dq n_faction, 6, 0
    dq n_fcsrf, 4, 0
    dq n_fppp, 3, 0
    dq n_fbanner, 6, 0
    dq n_ftheme, 5, 0
    dq n_flocale, 6, 0
    dq n_furl, 3, 0

; dashboard row fragments (classes must be CSS components; Tailwind
; does not scan .asm, only the html templates)
r_tr1: db '<tr><td><a class="postlink" href="/admin/edit/'
r_tr1_len equ $-r_tr1
r_tr2: db '">'
r_tr2_len equ $-r_tr2
r_tr3: db '</a></td><td class="meta">'
r_tr3_len equ $-r_tr3
r_tr4: db '</td><td>'
r_tr4_len equ $-r_tr4
r_tr5: db '</td><td><a class="dellink" href="/admin/delete/'
r_tr5_len equ $-r_tr5
r_tr6a: db '">'
r_tr6a_len equ $-r_tr6a
r_tr6b: db '</a></td></tr>'
r_tr6b_len equ $-r_tr6b

section .note.GNU-stack noalloc noexec nowrite progbits
