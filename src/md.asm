; md.asm — Markdown-subset -> HTML renderer.
;
; Line-based block state machine + per-line inline pass. Supported:
;   blocks: # ## ### headings (with id anchors), ```lang fenced code,
;           > blockquote, -/* unordered lists, N. ordered lists,
;           --- hr, paragraphs, a lone ![image](url) line as <figure>
;   inline: **strong**, *em*, `code`, [text](url), ![alt](url)
;
; Safety model: every byte of user text goes through the HTML escaper;
; the only raw emissions are tags this file generates. Link URLs are
; scheme-allowlisted (http/https/mailto, site-relative, #fragment) and
; attribute-escaped, which closes both javascript: and attribute-
; breakout injection. Image URLs are limited to what the CSP lets the
; browser load anyway: site-relative paths and the Flickr CDN. Inline
; markers left unclosed at end of line are closed automatically —
; output is always well-formed.

BITS 64

extern emit
extern emit_esc
extern slugify

global md_render
global md_excerpt

section .text

; md_render(w, md_p, md_l)
md_render:
    push r12
    push r13
    push r14
    push r15
    push rbx
    mov r12, rdi                ; writer
    mov r13, rsi                ; cursor
    lea r14, [rsi+rdx]          ; end
    xor ebx, ebx                ; block state: 0 none 1 p 2 ul 3 ol 4 quote 5 code
.line:
    cmp r13, r14
    jae .eof
    ; find end of line
    xor r15d, r15d
.fnl:
    lea rax, [r13+r15]
    cmp rax, r14
    jae .gotline
    cmp byte [rax], 10
    je .gotline
    inc r15
    jmp .fnl
.gotline:                       ; r15 = line length (excl \n)
    test r15, r15
    jz .stripped
    cmp byte [r13+r15-1], 13
    jne .stripped
    dec r15                     ; strip \r
.stripped:
    ; --- code fence state ---
    cmp ebx, 5
    jne .not_code
    cmp r15, 3
    jb .code_text
    cmp word [r13], '``'
    jne .code_text
    cmp byte [r13+2], '`'
    jne .code_text
    mov rdi, r12                ; closing fence
    mov rsi, t_pre_c
    mov edx, t_pre_c_len
    call emit
    xor ebx, ebx
    jmp .advance
.code_text:
    mov rdi, r12
    mov rsi, r13
    mov rdx, r15
    call emit_esc
    mov rdi, r12
    mov rsi, t_nl
    mov edx, 1
    call emit
    jmp .advance
.not_code:
    ; --- blank line ---
    test r15, r15
    jnz .not_blank
    call close_block
    jmp .advance
.not_blank:
    ; --- opening fence ---
    cmp r15, 3
    jb .not_fence
    cmp word [r13], '``'
    jne .not_fence
    cmp byte [r13+2], '`'
    jne .not_fence
    call close_block
    mov rdi, r12
    mov rsi, t_pre_o
    mov edx, t_pre_o_len
    call emit
    ; info string -> class="language-x" ([A-Za-z0-9+_-], up to 16)
    lea rsi, [r13+3]
    lea rdx, [r15-3]
.info_sp:
    test rdx, rdx
    jz .info_done
    cmp byte [rsi], ' '
    jne .info_scan
    inc rsi
    dec rdx
    jmp .info_sp
.info_scan:
    xor ecx, ecx
.info_ch:
    cmp rcx, rdx
    jae .info_have
    cmp rcx, 16
    jae .info_have
    mov al, [rsi+rcx]
    cmp al, '+'
    je .info_ok
    cmp al, '-'
    je .info_ok
    cmp al, '_'
    je .info_ok
    cmp al, '0'
    jb .info_have
    cmp al, '9'
    jbe .info_ok
    or al, 0x20
    cmp al, 'a'
    jb .info_have
    cmp al, 'z'
    ja .info_have
.info_ok:
    inc rcx
    jmp .info_ch
.info_have:
    test rcx, rcx
    jz .info_done
    push rsi
    push rcx
    mov rdi, r12
    mov rsi, t_lang
    mov edx, t_lang_len
    call emit
    pop rdx
    pop rsi
    mov rdi, r12
    call emit_esc
    mov rdi, r12
    mov rsi, t_q
    mov edx, 1
    call emit
.info_done:
    mov rdi, r12
    mov rsi, t_gt
    mov edx, 1
    call emit
    mov ebx, 5
    jmp .advance
.not_fence:
    ; --- Flickr embed: a pasted <a data-flickr-embed ...> line is
    ; sanitized into a static, script-free <figure>. ---
    cmp r15, FL_MARK_len
    jb .not_flickr
    mov rdi, r13
    mov rsi, fl_marker
    mov edx, FL_MARK_len
    call bytes_eq
    test eax, eax
    jz .not_flickr
    call close_block
    mov rdi, r12
    mov rsi, r13
    mov rdx, r15
    call flickr_render
    test eax, eax
    jz .not_flickr             ; not a valid embed: fall through to text
    jmp .advance
.not_flickr:
    ; --- headings ---
    cmp r15, 2
    jb .not_h
    cmp byte [r13], '#'
    jne .not_h
    cmp byte [r13+1], ' '
    jne .try_h2
    call close_block
    mov rdi, r12
    lea rsi, [r13+2]
    lea rdx, [r15-2]
    mov ecx, '1'
    call heading
    jmp .advance
.try_h2:
    cmp r15, 3
    jb .not_h
    cmp byte [r13+1], '#'
    jne .not_h
    cmp byte [r13+2], ' '
    jne .try_h3
    call close_block
    mov rdi, r12
    lea rsi, [r13+3]
    lea rdx, [r15-3]
    mov ecx, '2'
    call heading
    jmp .advance
.try_h3:
    cmp r15, 4
    jb .not_h
    cmp byte [r13+2], '#'
    jne .not_h
    cmp byte [r13+3], ' '
    jne .not_h
    call close_block
    mov rdi, r12
    lea rsi, [r13+4]
    lea rdx, [r15-4]
    mov ecx, '3'
    call heading
    jmp .advance
.not_h:
    ; --- blockquote ---
    cmp byte [r13], '>'
    jne .not_q
    cmp ebx, 4
    je .q_line
    call close_block
    mov rdi, r12
    mov rsi, t_bq_o
    mov edx, t_bq_o_len
    call emit
    mov ebx, 4
.q_line:
    lea rsi, [r13+1]
    lea rdx, [r15-1]
    cmp r15, 2
    jb .q_render
    cmp byte [r13+1], ' '
    jne .q_render
    lea rsi, [r13+2]
    lea rdx, [r15-2]
.q_render:
    push rsi
    push rdx
    mov rdi, r12
    mov rsi, t_p_o
    mov edx, t_p_o_len
    call emit
    pop rdx
    pop rsi
    mov rdi, r12
    call inline_render
    mov rdi, r12
    mov rsi, t_p_c
    mov edx, t_p_c_len
    call emit
    jmp .advance
.not_q:
    ; --- unordered list ---
    cmp r15, 2
    jb .not_ul
    mov al, [r13]
    cmp al, '-'
    je .ul_chk
    cmp al, '*'
    jne .not_ul
.ul_chk:
    cmp byte [r13+1], ' '
    jne .not_ul
    cmp ebx, 2
    je .ul_item
    call close_block
    mov rdi, r12
    mov rsi, t_ul_o
    mov edx, t_ul_o_len
    call emit
    mov ebx, 2
.ul_item:
    mov rdi, r12
    mov rsi, t_li_o
    mov edx, t_li_o_len
    call emit
    lea rsi, [r13+2]
    lea rdx, [r15-2]
    mov rdi, r12
    call inline_render
    mov rdi, r12
    mov rsi, t_li_c
    mov edx, t_li_c_len
    call emit
    jmp .advance
.not_ul:
    ; --- ordered list: 1-3 digits, '.', ' ' ---
    xor ecx, ecx
.oldig:
    cmp rcx, r15
    jae .not_ol
    mov al, [r13+rcx]
    cmp al, '0'
    jb .oldigdone
    cmp al, '9'
    ja .oldigdone
    inc rcx
    cmp rcx, 3
    jbe .oldig
    jmp .not_ol
.oldigdone:
    test rcx, rcx
    jz .not_ol
    lea rax, [rcx+2]
    cmp rax, r15
    ja .not_ol
    cmp byte [r13+rcx], '.'
    jne .not_ol
    cmp byte [r13+rcx+1], ' '
    jne .not_ol
    push rcx
    cmp ebx, 3
    je .ol_item
    call close_block
    mov rdi, r12
    mov rsi, t_ol_o
    mov edx, t_ol_o_len
    call emit
    mov ebx, 3
.ol_item:
    mov rdi, r12
    mov rsi, t_li_o
    mov edx, t_li_o_len
    call emit
    pop rcx
    lea rsi, [r13+rcx+2]
    mov rdx, r15
    sub rdx, rcx
    sub rdx, 2
    mov rdi, r12
    call inline_render
    mov rdi, r12
    mov rsi, t_li_c
    mov edx, t_li_c_len
    call emit
    jmp .advance
.not_ol:
    ; --- hr: three or more dashes only ---
    cmp r15, 3
    jb .not_hr
    xor ecx, ecx
.hrchk:
    cmp rcx, r15
    jae .is_hr
    cmp byte [r13+rcx], '-'
    jne .not_hr
    inc rcx
    jmp .hrchk
.is_hr:
    call close_block
    mov rdi, r12
    mov rsi, t_hr
    mov edx, t_hr_len
    call emit
    jmp .advance
.not_hr:
    ; --- a line that is just ![alt](url) becomes a <figure> ---
    cmp ebx, 1
    je .p_join                  ; inside a paragraph it stays inline
    cmp r15, 5
    jb .not_fig
    cmp word [r13], '!['
    jne .not_fig
    cmp byte [r13+r15-1], ')'
    jne .not_fig
    call close_block
    mov rdi, r12
    mov rsi, t_fig_o
    mov edx, t_fig_o_len
    call emit
    mov rdi, r12
    mov rsi, r13
    mov rdx, r15
    call inline_render
    mov rdi, r12
    mov rsi, t_fig_c
    mov edx, t_fig_c_len
    call emit
    jmp .advance
.not_fig:
    ; --- paragraph text ---
    cmp ebx, 1
    je .p_join
    call close_block
    mov rdi, r12
    mov rsi, t_p_o
    mov edx, t_p_o_len
    call emit
    mov ebx, 1
    jmp .p_text
.p_join:
    mov rdi, r12
    mov rsi, t_sp
    mov edx, 1
    call emit
.p_text:
    mov rdi, r12
    mov rsi, r13
    mov rdx, r15
    call inline_render
.advance:
    lea r13, [r13+r15]
    cmp r13, r14
    jae .eof
    cmp byte [r13], 13
    jne .skipnl
    inc r13
    cmp r13, r14
    jae .eof
.skipnl:
    inc r13                     ; skip the \n
    jmp .line
.eof:
    call close_block
    pop rbx
    pop r15
    pop r14
    pop r13
    pop r12
    ret

; heading(w, text_p, text_l, level char) — <hN id="slug">…</hN>, the id
; being the slugified heading text (omitted when nothing survives), so
; sections are deep-linkable without any script.
heading:
    push r12
    push r13
    push r14
    push r15
    push rbx
    sub rsp, 80                 ; [0..64) slug, [64] level, [72] pad
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov [rsp+64], cl
    mov rdi, rsp
    mov rsi, r13
    mov rdx, r14
    mov ecx, 64
    call slugify
    mov rbx, rax                ; slug length
    mov rdi, r12
    mov rsi, t_h_o
    mov edx, 2
    call emit
    mov rdi, r12
    lea rsi, [rsp+64]
    mov edx, 1
    call emit
    test rbx, rbx
    jz .noid
    mov rdi, r12
    mov rsi, t_id
    mov edx, t_id_len
    call emit
    mov rdi, r12
    mov rsi, rsp
    mov rdx, rbx
    call emit
    mov rdi, r12
    mov rsi, t_q
    mov edx, 1
    call emit
.noid:
    mov rdi, r12
    mov rsi, t_gt
    mov edx, 1
    call emit
    mov rdi, r12
    mov rsi, r13
    mov rdx, r14
    call inline_render
    mov rdi, r12
    mov rsi, t_h_c
    mov edx, 3
    call emit
    mov rdi, r12
    lea rsi, [rsp+64]
    mov edx, 1
    call emit
    mov rdi, r12
    mov rsi, t_gtnl
    mov edx, 2
    call emit
    add rsp, 80
    pop rbx
    pop r15
    pop r14
    pop r13
    pop r12
    ret

; close_block — emit the closing tag for state in ebx, reset to 0.
; Uses r12 (writer); preserves everything else callee-visible.
close_block:
    test ebx, ebx
    jz .done
    cmp ebx, 1
    jne .n1
    mov rsi, t_p_c
    mov edx, t_p_c_len
    jmp .go
.n1:
    cmp ebx, 2
    jne .n2
    mov rsi, t_ul_c
    mov edx, t_ul_c_len
    jmp .go
.n2:
    cmp ebx, 3
    jne .n3
    mov rsi, t_ol_c
    mov edx, t_ol_c_len
    jmp .go
.n3:
    cmp ebx, 4
    jne .n4
    mov rsi, t_bq_c
    mov edx, t_bq_c_len
    jmp .go
.n4:
    mov rsi, t_pre_c
    mov edx, t_pre_c_len
.go:
    mov rdi, r12
    call emit
    xor ebx, ebx
.done:
    ret

; inline_render(w, p, l) — **strong**, *em*, `code`, [text](url),
; everything else escaped. Unclosed strong/em close at end of line.
inline_render:
    push r12
    push r13
    push r14
    push r15
    push rbx
    push rbp
    mov r12, rdi
    mov r13, rsi                ; scan
    lea r14, [rsi+rdx]          ; end
    mov r15, rsi                ; run start
    xor ebx, ebx                ; bit0 strong open, bit1 em open
.scan:
    cmp r13, r14
    jae .fin
    mov al, [r13]
    cmp al, '*'
    je .special
    cmp al, '`'
    je .special
    cmp al, '['
    je .special
    cmp al, '!'
    je .special
    cmp al, '&'
    je .special
    cmp al, '<'
    je .special
    cmp al, '>'
    je .special
    cmp al, '"'
    je .special
    cmp al, 0x27
    je .special
    inc r13
    jmp .scan
.special:
    mov rdx, r13                ; flush the plain run
    sub rdx, r15
    jz .dispatch
    mov rdi, r12
    mov rsi, r15
    call emit_esc
.dispatch:
    mov al, [r13]
    cmp al, '*'
    je .star
    cmp al, '`'
    je .tick
    cmp al, '['
    je .link
    cmp al, '!'
    je .bang
    ; plain escapable char
    mov rdi, r12
    mov rsi, r13
    mov edx, 1
    call emit_esc
    inc r13
    mov r15, r13
    jmp .scan
.star:
    lea rax, [r13+1]
    cmp rax, r14
    jae .em
    cmp byte [rax], '*'
    jne .em
    ; strong toggle
    test ebx, 1
    jnz .strong_c
    mov rsi, t_st_o
    mov edx, t_st_o_len
    jmp .strong_e
.strong_c:
    mov rsi, t_st_c
    mov edx, t_st_c_len
.strong_e:
    mov rdi, r12
    call emit
    xor ebx, 1
    add r13, 2
    mov r15, r13
    jmp .scan
.em:
    test ebx, 2
    jnz .em_c
    mov rsi, t_em_o
    mov edx, t_em_o_len
    jmp .em_e
.em_c:
    mov rsi, t_em_c
    mov edx, t_em_c_len
.em_e:
    mov rdi, r12
    call emit
    xor ebx, 2
    inc r13
    mov r15, r13
    jmp .scan
.tick:
    ; find the closing backtick
    lea rbp, [r13+1]
.tickscan:
    cmp rbp, r14
    jae .tick_lit
    cmp byte [rbp], '`'
    je .tick_hit
    inc rbp
    jmp .tickscan
.tick_hit:
    mov rdi, r12
    mov rsi, t_code_o
    mov edx, t_code_o_len
    call emit
    lea rsi, [r13+1]
    mov rdx, rbp
    sub rdx, r13
    dec rdx
    mov rdi, r12
    call emit_esc
    mov rdi, r12
    mov rsi, t_code_c
    mov edx, t_code_c_len
    call emit
    lea r13, [rbp+1]
    mov r15, r13
    jmp .scan
.tick_lit:
    mov rdi, r12
    mov rsi, r13
    mov edx, 1
    call emit                   ; a lone backtick is HTML-safe
    inc r13
    mov r15, r13
    jmp .scan
.link:
    ; [text](url) — rbp = ']' pos, then find ')'
    lea rbp, [r13+1]
.lbscan:
    cmp rbp, r14
    jae .link_lit
    cmp byte [rbp], ']'
    je .lbhit
    inc rbp
    jmp .lbscan
.lbhit:
    lea rax, [rbp+1]
    cmp rax, r14
    jae .link_lit
    cmp byte [rax], '('
    jne .link_lit
    push rbp                    ; save ']' pos
    lea rbp, [rbp+2]            ; url start
    mov rax, rbp
.lpscan:
    cmp rax, r14
    jae .link_lit_pop
    cmp byte [rax], ')'
    je .lphit
    inc rax
    jmp .lpscan
.lphit:
    ; url = [rbp, rax); validate scheme
    push rax                    ; save ')' pos
    mov rdi, rbp
    mov rsi, rax
    sub rsi, rbp
    call url_allowed
    test eax, eax
    jz .link_lit_pop2
    mov rdi, r12
    mov rsi, t_a_o              ; <a href="
    mov edx, t_a_o_len
    call emit
    mov rax, [rsp]              ; ')' pos
    mov rdi, r12
    mov rsi, rbp
    mov rdx, rax
    sub rdx, rbp
    call emit_esc               ; attribute-escaped URL
    mov rdi, r12
    mov rsi, t_a_m              ; ">
    mov edx, t_a_m_len
    call emit
    mov rax, [rsp+8]            ; ']' pos
    lea rsi, [r13+1]
    mov rdx, rax
    sub rdx, r13
    dec rdx
    mov rdi, r12
    call emit_esc               ; link text
    mov rdi, r12
    mov rsi, t_a_c              ; </a>
    mov edx, t_a_c_len
    call emit
    pop r13                     ; ')' pos
    inc r13
    pop rax                     ; discard ']' pos
    mov r15, r13
    jmp .scan
.link_lit_pop2:
    pop rax
.link_lit_pop:
    pop rax
.link_lit:
    mov rdi, r12
    mov rsi, r13
    mov edx, 1
    call emit                   ; '[' is HTML-safe
    inc r13
    mov r15, r13
    jmp .scan
.bang:
    ; ![alt](url) — same shape as a link; rbp = ']' pos, then ')'
    lea rax, [r13+1]
    cmp rax, r14
    jae .bang_lit
    cmp byte [rax], '['
    jne .bang_lit
    lea rbp, [r13+2]
.ibscan:
    cmp rbp, r14
    jae .bang_lit
    cmp byte [rbp], ']'
    je .ibhit
    inc rbp
    jmp .ibscan
.ibhit:
    lea rax, [rbp+1]
    cmp rax, r14
    jae .bang_lit
    cmp byte [rax], '('
    jne .bang_lit
    push rbp                    ; ']' pos
    lea rbp, [rbp+2]            ; url start
    mov rax, rbp
.ipscan:
    cmp rax, r14
    jae .bang_lit_pop
    cmp byte [rax], ')'
    je .iphit
    inc rax
    jmp .ipscan
.iphit:
    push rax                    ; ')' pos
    mov rdi, rbp
    mov rsi, rax
    sub rsi, rbp
    call img_allowed
    test eax, eax
    jz .bang_lit_pop2
    mov rdi, r12
    mov rsi, t_img_o            ; <img src="
    mov edx, t_img_o_len
    call emit
    mov rax, [rsp]
    mov rdi, r12
    mov rsi, rbp
    mov rdx, rax
    sub rdx, rbp
    call emit_esc               ; src
    mov rdi, r12
    mov rsi, t_img_m            ; " alt="
    mov edx, t_img_m_len
    call emit
    mov rax, [rsp+8]            ; ']' pos
    lea rsi, [r13+2]
    mov rdx, rax
    sub rdx, r13
    sub rdx, 2
    mov rdi, r12
    call emit_esc               ; alt
    mov rdi, r12
    mov rsi, t_img_c            ; " loading="lazy" decoding="async">
    mov edx, t_img_c_len
    call emit
    pop r13                     ; ')' pos
    inc r13
    pop rax
    mov r15, r13
    jmp .scan
.bang_lit_pop2:                 ; well-formed but not an allowed host:
    pop rax                     ; the whole ![alt](url) stays visible text
    pop rcx
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rax+1]
    sub rdx, r13
    call emit_esc
    lea r13, [rax+1]
    mov r15, r13
    jmp .scan
.bang_lit_pop:
    pop rax
.bang_lit:
    mov rdi, r12
    mov rsi, r13
    mov edx, 1
    call emit                   ; '!' is HTML-safe
    inc r13
    mov r15, r13
    jmp .scan
.fin:
    mov rdx, r13
    sub rdx, r15
    jz .close
    mov rdi, r12
    mov rsi, r15
    call emit_esc
.close:
    test ebx, 2
    jz .noem
    mov rdi, r12
    mov rsi, t_em_c
    mov edx, t_em_c_len
    call emit
.noem:
    test ebx, 1
    jz .nostrong
    mov rdi, r12
    mov rsi, t_st_c
    mov edx, t_st_c_len
    call emit
.nostrong:
    pop rbp
    pop rbx
    pop r15
    pop r14
    pop r13
    pop r12
    ret

; url_allowed(p, l) -> 1 if http://, https://, mailto:, '/', or '#'
url_allowed:
    test rsi, rsi
    jz .no
    mov al, [rdi]
    cmp al, '/'
    je .yes
    cmp al, '#'
    je .yes
    cmp rsi, 7
    jb .no
    cmp dword [rdi], 'http'
    je .http
    cmp dword [rdi], 'mail'
    jne .no
    cmp word [rdi+4], 'to'
    jne .no
    cmp byte [rdi+6], ':'
    jne .no
    jmp .yes
.http:
    cmp dword [rdi+3], 'p://'
    je .yes
    cmp rsi, 8
    jb .no
    cmp dword [rdi+4], 's://'
    je .yes
.no:
    xor eax, eax
    ret
.yes:
    mov eax, 1
    ret

; img_allowed(p, l) -> 1 for a site-relative path ("/x", not "//host")
; or a Flickr CDN URL — exactly what the CSP's img-src permits.
img_allowed:
    test rsi, rsi
    jz .no
    cmp byte [rdi], '/'
    jne .flickr
    cmp rsi, 2
    jb .yes
    cmp byte [rdi+1], '/'
    je .no
    jmp .yes
.flickr:
    cmp rsi, fl_img_host_len
    jb .no
    mov rdx, fl_img_host
    mov rcx, fl_img_host_len
    jmp host_ok
.no:
    xor eax, eax
    ret
.yes:
    mov eax, 1
    ret

; md_excerpt(dst, cap, md_p, md_l) -> rax = length written (dst must
; have room for cap + 3 bytes). When the text was cut at cap and does
; not already end a sentence, a trailing "…" (U+2026) is appended, so
; callers never add their own and a synopsis that ends on a full stop
; is left alone ("...a design tool." rather than "...a design tool.…").
; Plain-text synopsis of a markdown source for cards and feed summaries:
; skips Flickr embed lines, code fences and blank lines; strips block
; prefixes (# > - * and indentation) and inline markers (* `); joins
; lines with single spaces; stops at cap without splitting a UTF-8
; sequence. Output is still escaped by the caller/template.
md_excerpt:
    push r12
    push r13
    push r14
    push r15
    push rbx
    push rbp
    mov r12, rdi                ; dst
    mov r13, rsi                ; cap
    mov r14, rdx                ; cursor
    lea r15, [rdx+rcx]          ; end
    xor ebx, ebx                ; out
    xor ebp, ebp                ; 1 = stopped at cap: the text was cut
.line:
    cmp r14, r15
    jae .done
    cmp rbx, r13
    jae .cut
    xor ecx, ecx                ; line length
.fnl:
    lea rax, [r14+rcx]
    cmp rax, r15
    jae .gotline
    cmp byte [rax], 10
    je .gotline
    inc rcx
    jmp .fnl
.gotline:
    lea r9, [r14+rcx+1]         ; next line
    test rcx, rcx
    jz .nextline
    cmp byte [r14+rcx-1], 13
    jne .nocr
    dec rcx
    jz .nextline
.nocr:
    ; skip Flickr embed lines
    cmp rcx, FL_MARK_len
    jb .notfl
    xor r10d, r10d
.flcmp:
    cmp r10, FL_MARK_len
    jae .nextline               ; whole marker matched: skip line
    mov al, [r14+r10]
    cmp al, [fl_marker+r10]
    jne .notfl
    inc r10
    jmp .flcmp
.notfl:
    ; skip fence lines and image lines
    cmp rcx, 3
    jb .prefix
    cmp word [r14], '``'
    jne .notfence
    cmp byte [r14+2], '`'
    je .nextline
.notfence:
    cmp word [r14], '!['
    je .nextline
.prefix:
    mov r8, r14                 ; strip leading # > and spaces
.strip:
    test rcx, rcx
    jz .nextline
    mov al, [r8]
    cmp al, '#'
    je .strip1
    cmp al, '>'
    je .strip1
    cmp al, ' '
    je .strip1
    jmp .listmark
.strip1:
    inc r8
    dec rcx
    jmp .strip
.listmark:                      ; "- " / "* " bullets
    cmp rcx, 2
    jb .emitline
    cmp al, '-'
    je .lm2
    cmp al, '*'
    jne .emitline
.lm2:
    cmp byte [r8+1], ' '
    jne .emitline
    add r8, 2
    sub rcx, 2
.emitline:
    test rcx, rcx
    jz .nextline
    ; separator between lines
    test rbx, rbx
    jz .copy
    cmp rbx, r13
    jae .cut
    mov byte [r12+rbx], ' '
    inc rbx
.copy:
    test rcx, rcx
    jz .nextline
    cmp rbx, r13
    jae .cut
    mov al, [r8]
    inc r8
    dec rcx
    cmp al, '*'                 ; drop inline emphasis/code markers
    je .copy
    cmp al, '`'
    je .copy
    mov [r12+rbx], al
    inc rbx
    jmp .copy
.nextline:
    mov r14, r9
    jmp .line
.cut:
    mov ebp, 1
.done:
    ; trim a trailing space
    test rbx, rbx
    jz .ret
    cmp byte [r12+rbx-1], ' '
    jne .utf8
    dec rbx
.utf8:
    ; if we stopped at cap, back off to a UTF-8 character boundary
    cmp rbx, r13
    jb .ellipsis
.back:
    test rbx, rbx
    jz .ret
    mov al, [r12+rbx-1]
    and al, 0xC0
    cmp al, 0x80                ; continuation byte: keep backing up
    jne .lead
    dec rbx
    jmp .back
.lead:
    cmp byte [r12+rbx-1], 0xC0  ; a lead byte whose sequence we may
    jb .ellipsis                ; have truncated: drop it too
    dec rbx
.ellipsis:
    ; cut text ends in "…" unless it already closes a sentence; a
    ; dangling comma/semicolon/colon is dropped first
    test ebp, ebp
    jz .ret
    test rbx, rbx
    jz .ret
    mov al, [r12+rbx-1]
    cmp al, '.'
    je .ret
    cmp al, '!'
    je .ret
    cmp al, '?'
    je .ret
    cmp al, ','
    je .strip_punct
    cmp al, ';'
    je .strip_punct
    cmp al, ':'
    jne .add
.strip_punct:
    dec rbx
.add:
    mov byte [r12+rbx], 0xE2
    mov byte [r12+rbx+1], 0x80
    mov byte [r12+rbx+2], 0xA6
    add rbx, 3
.ret:
    mov rax, rbx
    pop rbp
    pop rbx
    pop r15
    pop r14
    pop r13
    pop r12
    ret

; bytes_eq(a, b, len) -> 1/0 (local copy; mem_eq lives in util)
bytes_eq:
    test rdx, rdx
    jz .y
.l:
    mov al, [rdi]
    cmp al, [rsi]
    jne .n
    inc rdi
    inc rsi
    dec rdx
    jnz .l
.y:
    mov eax, 1
    ret
.n:
    xor eax, eax
    ret

; attr_val(hay_p, hay_l, needle_p, needle_l) -> rax=value ptr, rdx=value
; len (span after needle up to the next '"'); rax=0 if needle absent.
attr_val:
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi               ; hay
    mov r13, rsi               ; hay len
    mov r14, rdx               ; needle
    mov r15, rcx               ; needle len
    cmp r13, r15
    jb .no
    mov r8, r13
    sub r8, r15                ; last valid start
    xor r9d, r9d
.outer:
    cmp r9, r8
    ja .no
    xor r10d, r10d
.inner:
    cmp r10, r15
    jae .hit
    lea r11, [r9+r10]
    mov al, [r12+r11]
    cmp al, [r14+r10]
    jne .next
    inc r10
    jmp .inner
.next:
    inc r9
    jmp .outer
.hit:
    lea rax, [r9+r15]          ; value start index
    mov rcx, rax               ; scan to closing quote
.vq:
    cmp rcx, r13
    jae .no
    cmp byte [r12+rcx], '"'
    je .done
    inc rcx
    jmp .vq
.done:
    mov rdx, rcx
    sub rdx, rax               ; value length
    lea rax, [r12+rax]         ; value pointer
    jmp .ret
.no:
    xor eax, eax
    xor edx, edx
.ret:
    pop r15
    pop r14
    pop r13
    pop r12
    ret

; host_ok(p, l, prefix_p, prefix_l) -> 1 if p starts with prefix
host_ok:
    cmp rsi, rcx
    jb .no
    mov rsi, rdx               ; prefix
    mov rdx, rcx               ; len
    call bytes_eq
    ret
.no:
    xor eax, eax
    ret

; flickr_render(w, line_p, line_l) -> 1 handled / 0 not a valid embed.
; Extracts href (Flickr photo page) and img src (staticflickr CDN),
; validates both hosts, and emits a static, script-free figure. The
; original <script> tag in the paste is simply ignored.
flickr_render:
    push r12
    push r13
    push r14
    push r15
    push rbx
    push rbp
    sub rsp, 40
    mov r12, rdi               ; writer
    mov r13, rsi               ; line
    mov r14, rdx               ; line len
    ; href="
    mov rdi, r13
    mov rsi, r14
    mov rdx, fl_href
    mov rcx, fl_href_len
    call attr_val
    test rax, rax
    jz .no
    mov [rsp], rax             ; href ptr
    mov [rsp+8], rdx           ; href len
    mov rdi, rax               ; validate host
    mov rsi, rdx
    mov rdx, fl_page_host
    mov rcx, fl_page_host_len
    call host_ok
    test eax, eax
    jnz .href_ok
    mov rdi, [rsp]
    mov rsi, [rsp+8]
    mov rdx, fl_page_host2
    mov rcx, fl_page_host2_len
    call host_ok
    test eax, eax
    jz .no
.href_ok:
    ; src="
    mov rdi, r13
    mov rsi, r14
    mov rdx, fl_src
    mov rcx, fl_src_len
    call attr_val
    test rax, rax
    jz .no
    mov [rsp+16], rax          ; src ptr
    mov [rsp+24], rdx          ; src len
    mov rdi, rax
    mov rsi, rdx
    mov rdx, fl_img_host
    mov rcx, fl_img_host_len
    call host_ok
    test eax, eax
    jz .no
    ; alt=" (optional)
    mov rdi, r13
    mov rsi, r14
    mov rdx, fl_alt
    mov rcx, fl_alt_len
    call attr_val
    mov [rsp+32], rax          ; alt ptr (may be 0)
    mov rbx, rdx               ; alt len
    ; --- emit the figure ---
    mov rdi, r12
    mov rsi, fl_o1             ; <figure...><a href="
    mov edx, fl_o1_len
    call emit
    mov rdi, r12
    mov rsi, [rsp]
    mov rdx, [rsp+8]
    call emit_esc              ; href, attribute-escaped
    mov rdi, r12
    mov rsi, fl_o2             ; " target=_blank rel=...><img src="
    mov edx, fl_o2_len
    call emit
    mov rdi, r12
    mov rsi, [rsp+16]
    mov rdx, [rsp+24]
    call emit_esc              ; src
    mov rdi, r12
    mov rsi, fl_o3             ; " alt="
    mov edx, fl_o3_len
    call emit
    mov rax, [rsp+32]
    test rax, rax
    jz .noalt
    mov rdi, r12
    mov rsi, rax
    mov rdx, rbx
    call emit_esc              ; alt
.noalt:
    mov rdi, r12
    mov rsi, fl_o4             ; " loading=lazy></a></figure>
    mov edx, fl_o4_len
    call emit
    add rsp, 40
    mov eax, 1
    pop rbp
    pop rbx
    pop r15
    pop r14
    pop r13
    pop r12
    ret
.no:
    add rsp, 40
    xor eax, eax
    pop rbp
    pop rbx
    pop r15
    pop r14
    pop r13
    pop r12
    ret

section .data

fl_marker: db '<a data-flickr-embed'
FL_MARK_len equ $-fl_marker
fl_href: db 'href="'
fl_href_len equ $-fl_href
fl_src: db 'src="'
fl_src_len equ $-fl_src
fl_alt: db 'alt="'
fl_alt_len equ $-fl_alt
fl_page_host: db 'https://www.flickr.com/'
fl_page_host_len equ $-fl_page_host
fl_page_host2: db 'https://flickr.com/'
fl_page_host2_len equ $-fl_page_host2
fl_img_host: db 'https://live.staticflickr.com/'
fl_img_host_len equ $-fl_img_host
fl_o1: db '<figure class="flickr-embed"><a href="'
fl_o1_len equ $-fl_o1
fl_o2: db '" target="_blank" rel="noopener noreferrer"><img src="'
fl_o2_len equ $-fl_o2
fl_o3: db '" alt="'
fl_o3_len equ $-fl_o3
fl_o4: db '" loading="lazy"></a></figure>', 10
fl_o4_len equ $-fl_o4

t_p_o:  db '<p>'
t_p_o_len equ $-t_p_o
t_p_c:  db '</p>', 10
t_p_c_len equ $-t_p_c
t_h_o:  db '<h'
t_h_c:  db '</h'
t_id:   db ' id="'
t_id_len equ $-t_id
t_q:    db '"'
t_gt:   db '>'
t_gtnl: db '>', 10
t_lang: db ' class="language-'
t_lang_len equ $-t_lang
t_fig_o: db '<figure>'
t_fig_o_len equ $-t_fig_o
t_fig_c: db '</figure>', 10
t_fig_c_len equ $-t_fig_c
t_img_o: db '<img src="'
t_img_o_len equ $-t_img_o
t_img_m: db '" alt="'
t_img_m_len equ $-t_img_m
t_img_c: db '" loading="lazy" decoding="async">'
t_img_c_len equ $-t_img_c
t_ul_o: db '<ul>', 10
t_ul_o_len equ $-t_ul_o
t_ul_c: db '</ul>', 10
t_ul_c_len equ $-t_ul_c
t_ol_o: db '<ol>', 10
t_ol_o_len equ $-t_ol_o
t_ol_c: db '</ol>', 10
t_ol_c_len equ $-t_ol_c
t_li_o: db '<li>'
t_li_o_len equ $-t_li_o
t_li_c: db '</li>', 10
t_li_c_len equ $-t_li_c
t_bq_o: db '<blockquote>', 10
t_bq_o_len equ $-t_bq_o
t_bq_c: db '</blockquote>', 10
t_bq_c_len equ $-t_bq_c
t_pre_o: db '<pre><code'
t_pre_o_len equ $-t_pre_o
t_pre_c: db '</code></pre>', 10
t_pre_c_len equ $-t_pre_c
t_hr:   db '<hr>', 10
t_hr_len equ $-t_hr
t_st_o: db '<strong>'
t_st_o_len equ $-t_st_o
t_st_c: db '</strong>'
t_st_c_len equ $-t_st_c
t_em_o: db '<em>'
t_em_o_len equ $-t_em_o
t_em_c: db '</em>'
t_em_c_len equ $-t_em_c
t_code_o: db '<code>'
t_code_o_len equ $-t_code_o
t_code_c: db '</code>'
t_code_c_len equ $-t_code_c
t_a_o:  db '<a href="'
t_a_o_len equ $-t_a_o
t_a_m:  db '">'
t_a_m_len equ $-t_a_m
t_a_c:  db '</a>'
t_a_c_len equ $-t_a_c
t_nl:   db 10
t_sp:   db ' '

section .note.GNU-stack noalloc noexec nowrite progbits
