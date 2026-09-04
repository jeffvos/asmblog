; http.asm — request parsing, routing, error responses.
;
; http_handle() is called by the worker with a complete request head
; buffered in ctx->inbuf. It parses strictly (METHOD SP PATH SP
; HTTP/1.x CRLF headers CRLFCRLF), decides keep-alive, splits the query
; string, and routes. Dynamic pages are rendered by pages.asm handlers;
; error pages come from the parallel tables at the bottom via
; build_page(). Nothing here touches the socket — conn_flush owns all
; writes.
;
; Error page indices: 1 = health, 2 = 404, 3 = 405, 4 = 400, 5 = 500

BITS 64
%include "src/sys.inc"
%include "src/conn.inc"

extern mem_copy
extern mem_eq
extern u64_to_dec
extern parse_dec
extern put_hex
extern emit_date_hdr
extern crc32c_raw
extern store_gen
extern set_locale
extern theme_class
extern page_list
extern page_post
extern page_feed
extern page_static
extern page_hits
extern page_robots
extern page_sitemap
extern page_manifest
extern admin_route

global http_handle
global http_body_len
global build_page
global ci_find
global ci_prefix
global find_header
global hdr_block
global inm_check
global percent_decode
global valid_seg
global sec_headers
global sec_headers_len

section .text

; http_handle(ctx, head_len, body_len)
; Frame: [rsp+0..127] percent-decode buffer for ?q=,
;        [rsp+128] tag ptr, [136] tag len, [144] rest len, [152] page N,
;        [160] body len, [168] is_post
http_handle:
    push r12
    push r13
    push r14
    push r15
    push rbx
    push rbp
    sub rsp, 176
    mov r12, rdi                ; ctx
    mov r13, rsi                ; head length (incl. CRLFCRLF)
    mov [rsp+160], rdx          ; body length
    lea r14, [r12+CTX_IN]
    ; per-request response state
    mov [r12+CTX_HLEN], r13
    mov byte [r12+CTX_HEAD], 0
    mov qword [r12+CTX_HOST_L], 0
    mov qword [r12+CTX_LM], 0
    mov dword [r12+CTX_ETAG_L], 0   ; etag_l, cache, https, inm
    mov byte [r12+CTX_VARY], 0

    ; request line ends at the first CR
    xor ebx, ebx
.findcr:
    cmp rbx, r13
    jae .bad
    cmp byte [r14+rbx], 13
    je .gotcr
    inc rbx
    jmp .findcr
.gotcr:                         ; rbx = request line length
    xor r15d, r15d
.sp1:
    cmp r15, rbx
    jae .bad
    cmp byte [r14+r15], ' '
    je .sp1d
    inc r15
    jmp .sp1
.sp1d:                          ; r15 = method length
    lea rdx, [r15+1]            ; path start
    mov rax, rdx
.sp2:
    cmp rax, rbx
    jae .bad
    cmp byte [r14+rax], ' '
    je .sp2d
    inc rax
    jmp .sp2
.sp2d:
    mov rcx, rbx                ; version must be exactly " HTTP/1.x"
    sub rcx, rax
    cmp rcx, 9
    jne .bad
    mov rcx, rax
    sub rcx, rdx
    push rcx                    ; [rsp+8] = path length
    lea rcx, [r14+rdx]
    push rcx                    ; [rsp]   = path pointer

    lea rcx, [r14+rax+1]
    cmp dword [rcx], 'HTTP'
    jne .badp
    cmp word [rcx+4], '/1'
    jne .badp
    cmp byte [rcx+6], '.'
    jne .badp
    mov al, [rcx+7]
    cmp al, '1'
    je .v11
    cmp al, '0'
    jne .badp
    mov byte [r12+CTX_KEEP], 0
    jmp .vdone
.v11:
    mov byte [r12+CTX_KEEP], 1
.vdone:
    ; Connection header may override the version default
    lea rdi, [r14+rbx+2]
    mov rsi, r13
    sub rsi, rbx
    sub rsi, 2
    call scan_connection        ; 0 none / 1 close / 2 keep-alive
    cmp rax, 1
    jne .not_close
    mov byte [r12+CTX_KEEP], 0
    jmp .conn_done
.not_close:
    cmp rax, 2
    jne .conn_done
    mov byte [r12+CTX_KEEP], 1
.conn_done:
    lea rdi, [r14+rbx+2]
    mov rsi, r13
    sub rsi, rbx
    sub rsi, 2
    call scan_gzip
    mov [r12+CTX_GZIP], al
    mov rdi, r12                ; Host (validated) + X-Forwarded-Proto
    lea rsi, [r14+rbx+2]
    mov rdx, r13
    sub rdx, rbx
    sub rdx, 2
    call scan_origin

    cmp r15, 3                  ; method: GET, HEAD or POST
    jne .try4
    mov rdi, r14
    mov rsi, str_GET
    mov edx, 3
    call mem_eq
    test eax, eax
    jz .m405
    xor r10d, r10d              ; is_post = 0
    jmp .method_done
.try4:
    cmp r15, 4
    jne .m405
    mov rdi, r14
    mov rsi, str_POST
    mov edx, 4
    call mem_eq
    test eax, eax
    jz .try_head
    mov r10d, 1
    jmp .method_done
.try_head:
    mov rdi, r14
    mov rsi, str_HEAD
    mov edx, 4
    call mem_eq
    test eax, eax
    jz .m405
    mov byte [r12+CTX_HEAD], 1  ; routed as GET; builders drop the body
    xor r10d, r10d
.method_done:
    pop rdi                     ; path pointer
    pop rsi                     ; path length
    mov r14, rdi                ; (inbuf base no longer needed)
    mov r15, rsi
    mov [rsp+168], r10          ; is_post

    ; split off the query string: rbx = qs ptr (0 none), rbp = qs len
    xor ebx, ebx
    xor ebp, ebp
    xor ecx, ecx
.qs:
    cmp rcx, r15
    jae .qsdone
    cmp byte [r14+rcx], '?'
    je .qshit
    inc rcx
    jmp .qs
.qshit:
    lea rbx, [r14+rcx+1]
    mov rbp, r15
    sub rbp, rcx
    dec rbp
    mov r15, rcx
.qsdone:
    inc dword [r12+CTX_NREQ]
    cmp dword [r12+CTX_NREQ], MAX_REQS_PER_CONN
    jb .route
    mov byte [r12+CTX_KEEP], 0

.route:
    ; /admin and /admin/* go to the admin router (GET and POST)
    cmp r15, 6
    jb .not_admin
    mov rdi, r14
    mov rsi, str_admin
    mov edx, 6
    call mem_eq
    test eax, eax
    jz .not_admin
    cmp r15, 6
    je .is_admin
    cmp byte [r14+6], '/'
    jne .not_admin
.is_admin:
    mov rdi, r12
    mov rsi, r14
    mov rdx, r15
    mov rcx, r13                ; head length
    mov r8, [rsp+160]           ; body length
    mov r9, [rsp+168]           ; is_post
    call admin_route
    jmp .fin
.not_admin:
    cmp qword [rsp+168], 0      ; POST only exists under /admin
    je .is_get
    mov edx, 3
    jmp .build
.is_get:
    ; one URL per page: a trailing slash redirects to the bare path
    cmp r15, 1
    jbe .no_slash
    cmp byte [r14+r15-1], '/'
    jne .no_slash
    mov rdi, r12
    mov rsi, r14
    lea rdx, [r15-1]
    call finish_301
    jmp .fin
.no_slash:
    ; validator for every public GET: generation + crc(host, path, query).
    ; Handlers answer 304 when the client already holds it.
    mov rdi, r12
    mov rsi, r14
    mov rdx, r15
    mov rcx, rbx
    mov r8, rbp
    call dyn_etag
    mov rdi, r12
    call inm_check
    ; "/"
    cmp r15, 1
    jne .r_health
    cmp byte [r14], '/'
    jne .r404
    mov rdi, r12
    mov esi, 1
    xor edx, edx
    xor ecx, ecx
    xor r8d, r8d
    xor r9d, r9d
    call page_list
    jmp .fin
.r_health:
    cmp r15, 7
    jne .r_feed
    mov rdi, r14
    mov rsi, str_health
    mov edx, 7
    call mem_eq
    test eax, eax
    jz .r_feed                  ; other 7-byte paths continue the chain
    mov edx, 1
    jmp .build
.r_feed:
    cmp r15, 9
    jne .r_css
    mov rdi, r14
    mov rsi, str_feed
    mov edx, 9
    call mem_eq
    test eax, eax
    jz .r_css
    mov rdi, r12
    call page_feed
    jmp .fin
.r_css:
    cmp r15, 9
    jne .r_static
    mov rdi, r14
    mov rsi, str_hits
    mov edx, 9
    call mem_eq
    test eax, eax
    jz .r_static
    mov rdi, r12
    call page_hits
    jmp .fin
.r_static:
    cmp r15, 9                  ; "/static/x" minimum
    jb .r_robots
    mov rdi, r14
    mov rsi, str_staticp
    mov edx, 8
    call mem_eq
    test eax, eax
    jz .r_fav
    test rbp, rbp               ; ?v=<hash> requests are immutable;
    jz .st_go                   ; page_static picks the default otherwise
    mov byte [r12+CTX_CACHE], CACHE_IMMUTABLE
.st_go:
    mov rdi, r12
    lea rsi, [r14+8]
    lea rdx, [r15-8]
    call page_static
    jmp .fin
.r_fav:
    cmp r15, 12
    jne .r_robots
    mov rdi, r14
    mov rsi, str_favicon
    mov edx, 12
    call mem_eq
    test eax, eax
    jz .r_sitemap
    mov rdi, r12
    lea rsi, [str_favicon+1]
    mov edx, 11
    call page_static
    jmp .fin
.r_robots:
    cmp r15, 11
    jne .r_sitemap
    mov rdi, r14
    mov rsi, str_robots
    mov edx, 11
    call mem_eq
    test eax, eax
    jz .r_sitemap
    mov rdi, r12
    call page_robots
    jmp .fin
.r_sitemap:
    cmp r15, 12
    jne .r_sitemap_n
    mov rdi, r14
    mov rsi, str_sitemap
    mov edx, 12
    call mem_eq
    test eax, eax
    jz .r_sitemap_n
    mov rdi, r12
    xor esi, esi
    call page_sitemap
    jmp .fin
.r_sitemap_n:                   ; /sitemap-N.xml
    cmp r15, 14
    jb .r_manifest
    mov rdi, r14
    mov rsi, str_sitemapp
    mov edx, 9
    call mem_eq
    test eax, eax
    jz .r_manifest
    lea rdi, [r14+r15-4]
    mov rsi, str_dotxml
    mov edx, 4
    call mem_eq
    test eax, eax
    jz .r_manifest
    lea rdi, [r14+9]
    lea rsi, [r15-13]
    call parse_dec
    test rax, rax
    jz .r404
    mov rdi, r12
    mov rsi, rax
    call page_sitemap
    jmp .fin
.r_manifest:
    cmp r15, 21
    jne .r_page
    mov rdi, r14
    mov rsi, str_manifest
    mov edx, 21
    call mem_eq
    test eax, eax
    jz .r_page
    mov rdi, r12
    call page_manifest
    jmp .fin
.r_page:
    cmp r15, 7                  ; "/page/N" minimum
    jb .r_tag
    mov rdi, r14
    mov rsi, str_pagep
    mov edx, 6
    call mem_eq
    test eax, eax
    jz .r_post
    lea rdi, [r14+6]
    lea rsi, [r15-6]
    call parse_dec
    test rax, rax
    jz .r404
    cmp rax, 1                  ; /page/1 is /
    jne .pg_go
    mov rdi, r12
    mov rsi, str_root
    mov edx, 1
    call finish_301
    jmp .fin
.pg_go:
    mov rdi, r12
    mov rsi, rax
    xor edx, edx
    xor ecx, ecx
    xor r8d, r8d
    xor r9d, r9d
    call page_list
    jmp .fin
.r_post:
    mov rdi, r14
    mov rsi, str_postp
    mov edx, 6
    call mem_eq
    test eax, eax
    jz .r_tag
    lea rdi, [r14+6]
    lea rsi, [r15-6]
    mov edx, 128
    call valid_seg
    test eax, eax
    jz .r404
    mov rdi, r12
    lea rsi, [r14+6]
    lea rdx, [r15-6]
    call page_post
    jmp .fin
.r_tag:
    cmp r15, 6                  ; "/tag/x" minimum
    jb .r_search_chk
    mov rdi, r14
    mov rsi, str_tagp
    mov edx, 5
    call mem_eq
    test eax, eax
    jz .r_search_chk
    lea r8, [r14+5]             ; rest
    mov r9, r15
    sub r9, 5
    xor ecx, ecx
.tslash:
    cmp rcx, r9
    jae .tag_nopage
    cmp byte [r8+rcx], '/'
    je .tag_page
    inc rcx
    jmp .tslash
.tag_nopage:
    mov [rsp+128], r8
    mov [rsp+136], r9
    mov rdi, r8
    mov rsi, r9
    mov edx, 64
    call valid_seg
    test eax, eax
    jz .r404
    mov rdi, r12
    mov esi, 1
    mov rdx, [rsp+128]
    mov rcx, [rsp+136]
    xor r8d, r8d
    xor r9d, r9d
    call page_list
    jmp .fin
.tag_page:
    mov [rsp+128], r8           ; tag ptr
    mov [rsp+136], rcx          ; tag len
    mov rax, r9
    sub rax, rcx                ; rest after tag
    cmp rax, 7                  ; "/page/N" minimum
    jb .r404
    mov [rsp+144], rax
    lea rdi, [r8+rcx]
    mov rsi, str_pagep
    mov edx, 6
    call mem_eq
    test eax, eax
    jz .r404
    mov rax, [rsp+128]
    mov rcx, [rsp+136]
    lea rdi, [rax+rcx+6]
    mov rsi, [rsp+144]
    sub rsi, 6
    call parse_dec
    test rax, rax
    jz .r404
    mov [rsp+152], rax
    mov rdi, [rsp+128]
    mov rsi, [rsp+136]
    mov edx, 64
    call valid_seg
    test eax, eax
    jz .r404
    cmp qword [rsp+152], 1      ; /tag/x/page/1 is /tag/x
    jne .tg_go
    mov rdi, r12
    mov rsi, r14
    mov rdx, [rsp+136]
    add rdx, 5
    call finish_301
    jmp .fin
.tg_go:
    mov rdi, r12
    mov rsi, [rsp+152]
    mov rdx, [rsp+128]
    mov rcx, [rsp+136]
    xor r8d, r8d
    xor r9d, r9d
    call page_list
    jmp .fin
.r_search_chk:
    cmp r15, 7
    jne .r404
    mov rdi, r14
    mov rsi, str_search
    mov edx, 7
    call mem_eq
    test eax, eax
    jz .r404
    mov rdi, rbx
    mov rsi, rbp
    call qs_find_q              ; rax = value ptr (0 none), rdx = len
    test rax, rax
    jnz .haveq
    mov rdi, r12
    mov esi, 1
    xor edx, edx
    xor ecx, ecx
    mov r8, str_search          ; non-null, zero-length: "all posts"
    xor r9d, r9d
    call page_list
    jmp .fin
.haveq:
    mov rdi, rsp                ; decode into the 128-byte frame buffer
    mov rsi, rax
    mov ecx, 128
    call percent_decode
    mov rdi, r12
    mov esi, 1
    xor edx, edx
    xor ecx, ecx
    mov r8, rsp
    mov r9, rax
    call page_list
    jmp .fin
.r404:
    mov edx, 2
    jmp .build
.m405:
    pop rax
    pop rax
    mov edx, 3
    jmp .build
.badp:
    pop rax
    pop rax
.bad:
    mov byte [r12+CTX_KEEP], 0
    mov edx, 4
.build:
    mov rdi, r12
    mov esi, edx
    call build_page
.fin:
    add rsp, 176
    pop rbp
    pop rbx
    pop r15
    pop r14
    pop r13
    pop r12
    ret

; http_body_len(ctx, head_len) -> Content-Length value; 0 if absent,
; -1 if unparseable.
http_body_len:
    push r12
    push r13
    push r14
    lea r12, [rdi+CTX_IN]
    mov r13, rsi
    xor ecx, ecx                ; skip the request line
.rl:
    cmp rcx, r13
    jae .none
    cmp byte [r12+rcx], 13
    je .rld
    inc rcx
    jmp .rl
.rld:
    add rcx, 2
    add r12, rcx
    sub r13, rcx
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
    cmp r14, 15
    jb .adv
    mov rdi, r12
    mov rsi, str_cl_lc
    mov edx, 15
    call ci_prefix
    test eax, eax
    jz .adv
    lea rdi, [r12+15]
    lea rsi, [r14-15]
.sp:
    test rsi, rsi
    jz .bad
    cmp byte [rdi], ' '
    jne .digits
    inc rdi
    dec rsi
    jmp .sp
.digits:
    mov r8b, [rdi]              ; parse_dec can't distinguish "0" from
    mov r9, rsi                 ; garbage, so remember the raw value
    call parse_dec
    test rax, rax
    jnz .ret
    cmp r9, 1
    jne .bad
    cmp r8b, '0'
    jne .bad
    xor eax, eax
    jmp .ret
.adv:
    lea rax, [r14+2]
    cmp rax, r13
    ja .none
    add r12, rax
    sub r13, rax
    jmp .line
.none:
    xor eax, eax
    jmp .ret
.bad:
    mov rax, -1
.ret:
    pop r14
    pop r13
    pop r12
    ret

; valid_seg(ptr, len, maxlen) -> 1/0 — nonempty, bounded, [a-z0-9-] only
valid_seg:
    test rsi, rsi
    jz .no
    cmp rsi, rdx
    ja .no
.loop:
    mov al, [rdi]
    cmp al, 'a'
    jb .digit
    cmp al, 'z'
    jbe .ok
.digit:
    cmp al, '0'
    jb .dash
    cmp al, '9'
    jbe .ok
.dash:
    cmp al, '-'
    jne .no
.ok:
    inc rdi
    dec rsi
    jnz .loop
    mov eax, 1
    ret
.no:
    xor eax, eax
    ret

; qs_find_q(qs_p, qs_l) -> rax = value ptr or 0, rdx = value len
qs_find_q:
    test rdi, rdi
    jz .none
.param:
    test rsi, rsi
    jz .none
    xor ecx, ecx
.f:
    cmp rcx, rsi
    jae .seg
    cmp byte [rdi+rcx], '&'
    je .seg
    inc rcx
    jmp .f
.seg:
    cmp rcx, 2
    jb .adv
    cmp word [rdi], 'q='
    jne .adv
    lea rax, [rdi+2]
    lea rdx, [rcx-2]
    ret
.adv:
    lea rax, [rcx+1]
    cmp rax, rsi
    ja .none
    add rdi, rax
    sub rsi, rax
    jmp .param
.none:
    xor eax, eax
    xor edx, edx
    ret

; hexval: al -> eax 0..15, or -1
hexval:
    cmp al, '0'
    jb .bad
    cmp al, '9'
    jbe .dig
    or al, 0x20
    cmp al, 'a'
    jb .bad
    cmp al, 'f'
    ja .bad
    sub al, 'a'-10
    movzx eax, al
    ret
.dig:
    sub al, '0'
    movzx eax, al
    ret
.bad:
    mov eax, -1
    ret

; percent_decode(dst, src, len, cap) -> decoded length ('+' -> space)
percent_decode:
    push r12
    xor r8d, r8d
.loop:
    test rdx, rdx
    jz .done
    cmp r8, rcx
    jae .done
    mov al, [rsi]
    cmp al, '+'
    jne .n1
    mov al, ' '
    jmp .store1
.n1:
    cmp al, '%'
    jne .store1
    cmp rdx, 3
    jb .store1
    mov al, [rsi+1]
    call hexval
    test eax, eax
    js .store_pct
    mov r12d, eax
    mov al, [rsi+2]
    call hexval
    test eax, eax
    js .store_pct
    shl r12d, 4
    add r12d, eax
    mov al, r12b
    mov [rdi+r8], al
    inc r8
    add rsi, 3
    sub rdx, 3
    jmp .loop
.store_pct:
    mov al, '%'
.store1:
    mov [rdi+r8], al
    inc r8
    inc rsi
    dec rdx
    jmp .loop
.done:
    mov rax, r8
    pop r12
    ret

; scan_connection(headers, len) -> 0 none / 1 close / 2 keep-alive
scan_connection:
    push r12
    push r13
    push r14
    mov r12, rdi
    mov r13, rsi
.line:
    test r13, r13
    jz .none
    xor r14d, r14d
.findcr:
    cmp r14, r13
    jae .none
    cmp byte [r12+r14], 13
    je .have
    inc r14
    jmp .findcr
.have:                          ; r14 = line length
    cmp r14, 11
    jb .advance
    mov rdi, r12
    mov rsi, str_conn_lc
    mov edx, 11
    call ci_prefix
    test eax, eax
    jz .advance
    lea rdi, [r12+11]           ; header value
    lea rsi, [r14-11]
    mov rdx, str_close_lc
    mov ecx, 5
    call ci_find
    test eax, eax
    jz .try_ka
    mov eax, 1
    jmp .ret
.try_ka:
    lea rdi, [r12+11]
    lea rsi, [r14-11]
    mov rdx, str_ka_lc
    mov ecx, 10
    call ci_find
    test eax, eax
    jz .none
    mov eax, 2
    jmp .ret
.advance:
    lea rax, [r14+2]
    cmp rax, r13
    ja .none
    add r12, rax
    sub r13, rax
    jmp .line
.none:
    xor eax, eax
.ret:
    pop r14
    pop r13
    pop r12
    ret

; find_header(headers, len, name_lc, name_len) -> rax = value ptr (0 if
; absent), rdx = value length with surrounding blanks trimmed. name_lc
; includes the colon ("host:") and follows ci_prefix's rules.
find_header:
    push r12
    push r13
    push r14
    push r15
    push rbx
    mov r12, rdi
    mov r13, rsi
    mov r15, rdx
    mov rbx, rcx
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
    cmp r14, rbx
    jb .adv
    mov rdi, r12
    mov rsi, r15
    mov rdx, rbx
    call ci_prefix
    test eax, eax
    jz .adv
    lea rax, [r12+rbx]
    mov rdx, r14
    sub rdx, rbx
.ltrim:
    test rdx, rdx
    jz .ret
    cmp byte [rax], ' '
    je .lt1
    cmp byte [rax], 9
    jne .rtrim
.lt1:
    inc rax
    dec rdx
    jmp .ltrim
.rtrim:
    cmp byte [rax+rdx-1], ' '
    je .rt1
    cmp byte [rax+rdx-1], 9
    jne .ret
.rt1:
    dec rdx
    jnz .rtrim
    jmp .ret
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

; hdr_block(ctx) -> rax = first header line ptr, rdx = length of the
; header block (request line skipped), from the buffered request head.
hdr_block:
    mov rdx, [rdi+CTX_HLEN]
    lea rax, [rdi+CTX_IN]
    xor ecx, ecx
.f:
    cmp rcx, rdx
    jae .none
    cmp byte [rax+rcx], 13
    je .hit
    inc rcx
    jmp .f
.hit:
    add rcx, 2
    add rax, rcx
    sub rdx, rcx
    ret
.none:
    xor eax, eax
    xor edx, edx
    ret

; host_valid(p, l) -> 1/0 — nonempty, <= 255, [A-Za-z0-9.:-] only
host_valid:
    test rsi, rsi
    jz .no
    cmp rsi, 255
    ja .no
.l:
    mov al, [rdi]
    cmp al, '-'
    je .ok
    cmp al, '.'
    je .ok
    cmp al, ':'
    je .ok
    cmp al, '0'
    jb .no
    cmp al, '9'
    jbe .ok
    or al, 0x20
    cmp al, 'a'
    jb .no
    cmp al, 'z'
    ja .no
.ok:
    inc rdi
    dec rsi
    jnz .l
    mov eax, 1
    ret
.no:
    xor eax, eax
    ret

; scan_origin(ctx, headers, len) — CTX_HOST_* from a well-formed Host,
; CTX_HTTPS when the proxy says X-Forwarded-Proto: https.
scan_origin:
    push r12
    push r13
    push r14
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov rdi, r13
    mov rsi, r14
    mov rdx, str_host_lc
    mov ecx, 5
    call find_header
    test rax, rax
    jz .proto
    mov [r12+CTX_HOST_P], rax
    mov [r12+CTX_HOST_L], rdx
    mov rdi, rax
    mov rsi, rdx
    call host_valid
    test eax, eax
    jnz .proto
    mov qword [r12+CTX_HOST_L], 0
.proto:
    mov rdi, r13
    mov rsi, r14
    mov rdx, str_xfp_lc
    mov ecx, 18
    call find_header
    test rax, rax
    jz .ret
    cmp rdx, 5
    jb .ret
    mov rdi, rax
    mov rsi, str_https_lc
    mov edx, 5
    call ci_prefix
    mov [r12+CTX_HTTPS], al
.ret:
    pop r14
    pop r13
    pop r12
    ret

; dyn_etag(ctx, path, plen, qs, qslen) — stage the weak validator for a
; dynamic page: W/"<store generation hex>-<crc32c(host,path,query) hex>".
; Same generation + same URL => byte-identical page (the counter lives
; in /hits.svg, not the HTML), so this is exact, and it costs no render.
dyn_etag:
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
    mov edi, -1
    mov rsi, [r12+CTX_HOST_P]
    mov rdx, [r12+CTX_HOST_L]
    call crc32c_raw
    mov edi, eax
    mov rsi, r13
    mov rdx, r14
    call crc32c_raw
    mov edi, eax
    mov rsi, r15
    mov rdx, rbx
    call crc32c_raw
    not eax
    mov ebx, eax
    lea rdi, [r12+CTX_ETAG]
    mov word [rdi], 'W/'
    mov byte [rdi+2], '"'
    mov rdi, [store_gen]
    lea rsi, [r12+CTX_ETAG+3]
    mov edx, 16
    call put_hex
    mov byte [rax], '-'
    mov edi, ebx
    lea rsi, [rax+1]
    mov edx, 8
    call put_hex
    mov byte [rax], '"'
    mov byte [r12+CTX_ETAG_L], 29
    pop rbx
    pop r15
    pop r14
    pop r13
    pop r12
    ret

; inm_check(ctx) -> 1 and CTX_INM = 1 if If-None-Match carries the staged
; CTX_ETAG (or "*"); weak/strong prefixes are ignored on both sides.
inm_check:
    push r12
    push r13
    push r14
    push r15
    push rbx
    mov r12, rdi
    mov byte [r12+CTX_INM], 0
    cmp byte [r12+CTX_ETAG_L], 0
    je .no
    mov rdi, r12
    call hdr_block
    test rax, rax
    jz .no
    mov rdi, rax
    mov rsi, rdx
    mov rdx, str_inm_lc
    mov ecx, 14
    call find_header
    test rax, rax
    jz .no
    mov r13, rax                ; cursor
    mov r14, rdx                ; remaining
.tok:
    test r14, r14
    jz .no
    mov al, [r13]
    cmp al, ' '
    je .skip1
    cmp al, ','
    je .skip1
    cmp al, 9
    jne .tokstart
.skip1:
    inc r13
    dec r14
    jmp .tok
.tokstart:
    xor ecx, ecx
.te:
    cmp rcx, r14
    jae .tokend
    mov al, [r13+rcx]
    cmp al, ','
    je .tokend
    cmp al, ' '
    je .tokend
    inc rcx
    jmp .te
.tokend:
    mov r15, rcx                ; token [r13, r13+r15)
    cmp rcx, 1
    jne .cmp
    cmp byte [r13], '*'
    je .yes
.cmp:
    mov rdi, r13
    mov rsi, r15
    cmp rsi, 2
    jb .cmp2
    cmp word [rdi], 'W/'
    jne .cmp2
    add rdi, 2
    sub rsi, 2
.cmp2:
    lea rdx, [r12+CTX_ETAG]
    movzx ecx, byte [r12+CTX_ETAG_L]
    cmp word [rdx], 'W/'
    jne .cmp3
    add rdx, 2
    sub rcx, 2
.cmp3:
    cmp rsi, rcx
    jne .next
    mov rsi, rdx
    mov rdx, rcx
    call mem_eq
    test eax, eax
    jnz .yes
.next:
    add r13, r15
    sub r14, r15
    jmp .tok
.yes:
    mov byte [r12+CTX_INM], 1
    mov eax, 1
    jmp .ret
.no:
    xor eax, eax
.ret:
    pop rbx
    pop r15
    pop r14
    pop r13
    pop r12
    ret

; scan_gzip(headers, len) -> eax bitmask of accepted encodings: 1 gzip
; (or x-gzip), 2 br. Tokenises Accept-Encoding and honours ;q=0.
scan_gzip:
    push r12
    push r13
    push r14
    push r15
    push rbx
    push rbp
    mov rdx, str_ae_lc
    mov ecx, 16
    call find_header
    xor ebx, ebx                ; mask
    test rax, rax
    jz .done
    mov r12, rax
    mov r13, rdx
.tok:
    test r13, r13
    jz .done
    mov al, [r12]
    cmp al, ' '
    je .skip1
    cmp al, ','
    je .skip1
    cmp al, 9
    jne .name
.skip1:
    inc r12
    dec r13
    jmp .tok
.name:
    xor ecx, ecx
.ne:
    cmp rcx, r13
    jae .nend
    mov al, [r12+rcx]
    cmp al, ';'
    je .nend
    cmp al, ','
    je .nend
    cmp al, ' '
    je .nend
    inc rcx
    jmp .ne
.nend:
    mov r14, rcx                ; name length
    mov r15, rcx
.te:
    cmp r15, r13
    jae .tend
    cmp byte [r12+r15], ','
    je .tend
    inc r15
    jmp .te
.tend:                          ; token [r12, r12+r15), params after r14
    mov ebp, 1                  ; accepted unless q=0
    lea rdi, [r12+r14]
    mov rsi, r15
    sub rsi, r14
.qs:
    cmp rsi, 2
    jb .qdone
    mov al, [rdi]
    or al, 0x20
    cmp al, 'q'
    jne .qn
    cmp byte [rdi+1], '='
    jne .qn
    add rdi, 2
    sub rsi, 2
    jz .qdone
    cmp byte [rdi], '0'
    jne .qdone                  ; q starts 1..9: accepted
.qv:                            ; zero unless a nonzero digit follows
    inc rdi
    dec rsi
    jz .qzero
    mov al, [rdi]
    cmp al, '1'
    jb .qv                      ; '0', '.'
    cmp al, '9'
    ja .qzero
    jmp .qdone                  ; nonzero digit
.qzero:
    xor ebp, ebp
    jmp .qdone
.qn:
    inc rdi
    dec rsi
    jmp .qs
.qdone:
    test ebp, ebp
    jz .next
    cmp r14, 4
    jne .n_br
    mov rdi, r12
    mov rsi, str_gzip_lc
    mov edx, 4
    call ci_prefix
    test eax, eax
    jz .next
    or ebx, 1
    jmp .next
.n_br:
    cmp r14, 2
    jne .n_xgzip
    mov rdi, r12
    mov rsi, str_br_lc
    mov edx, 2
    call ci_prefix
    test eax, eax
    jz .next
    or ebx, 2
    jmp .next
.n_xgzip:
    cmp r14, 6
    jne .next
    mov rdi, r12
    mov rsi, str_xgzip_lc
    mov edx, 6
    call ci_prefix
    test eax, eax
    jz .next
    or ebx, 1
.next:
    add r12, r15
    sub r13, r15
    jmp .tok
.done:
    mov eax, ebx
    pop rbp
    pop rbx
    pop r15
    pop r14
    pop r13
    pop r12
    ret

; finish_301(ctx, loc_p, loc_l) — permanent redirect, no body.
finish_301:
    push r12
    push r13
    push r14
    push rbx
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    lea rbx, [r12+CTX_OUT]
    mov rdi, rbx
    mov rsi, st301
    mov edx, st301_len
    call mem_copy
    mov rdi, rax
    mov rsi, hdr_server
    mov edx, hdr_server_len
    call mem_copy
    mov rdi, rax
    call emit_date_hdr
    mov rdi, rax
    mov rsi, sec_headers
    mov edx, sec_headers_len
    call mem_copy
    cmp byte [r12+CTX_KEEP], 0
    je .cl
    mov rsi, hdr_ka
    mov edx, hdr_ka_len
    jmp .conn
.cl:
    mov rsi, hdr_cl
    mov edx, hdr_cl_len
.conn:
    mov rdi, rax
    call mem_copy
    mov rdi, rax
    mov rsi, hdr_loc
    mov edx, hdr_loc_len
    call mem_copy
    mov rdi, rax
    mov rsi, r13
    mov rdx, r14
    call mem_copy
    mov rdi, rax
    mov rsi, hdr_301_tail
    mov edx, hdr_301_tail_len
    call mem_copy
    sub rax, rbx
    mov [r12+CTX_OUT_LEN], rax
    mov qword [r12+CTX_OUT_START], 0
    mov qword [r12+CTX_OUT_SENT], 0
    pop rbx
    pop r14
    pop r13
    pop r12
    ret

; ci_prefix(hay, needle_lowercase, n) -> 1/0.
; Needle must be lowercase letters plus ':' or '-' (unaffected by |0x20).
ci_prefix:
.loop:
    test rdx, rdx
    jz .yes
    mov al, [rdi]
    or al, 0x20
    cmp al, [rsi]
    jne .no
    inc rdi
    inc rsi
    dec rdx
    jmp .loop
.yes:
    mov eax, 1
    ret
.no:
    xor eax, eax
    ret

; ci_find(hay, hlen, needle, nlen) -> 1/0 — naive case-insensitive
; substring; both sides are lowercased with |0x20 (ASCII letters).
ci_find:
    cmp rsi, rcx
    jb .no
    test rcx, rcx
    jz .yes
    mov r8, rsi
    sub r8, rcx                 ; last valid start
    xor r9d, r9d
.outer:
    cmp r9, r8
    ja .no
    xor r10d, r10d
.inner:
    cmp r10, rcx
    jae .yes
    lea r11, [r9+r10]
    mov al, [rdi+r11]
    or al, 0x20
    mov r11b, [rdx+r10]
    or r11b, 0x20
    cmp al, r11b
    jne .next
    inc r10
    jmp .inner
.next:
    inc r9
    jmp .outer
.yes:
    mov eax, 1
    ret
.no:
    xor eax, eax
    ret

; build_page(ctx, page index) — full error/health response in outbuf.
; The 404 body is themed and localized: prefix | theme class | suffix.
build_page:
    push r12
    push r13
    push r14
    push r15
    push rbx
    push rbp
    sub rsp, 32                 ; [0] suffix ptr [8] suffix len
    mov r12, rdi                ; [16] theme ptr [24] theme len
    mov r13, rsi
    mov qword [r12+CTX_OUT_START], 0
    mov qword [rsp], 0
    mov qword [rsp+8], 0
    mov qword [rsp+24], 0
    mov r15, [tbl_body + r13*8]
    mov rbx, [tbl_body_len + r13*8]
    cmp r13, 2
    jne .body_known
    call theme_class
    mov [rsp+16], rax
    mov [rsp+24], rdx
    mov r15, b404a_en
    mov rbx, b404a_en_len
    mov qword [rsp], b404b_en
    mov qword [rsp+8], b404b_en_len
    cmp dword [set_locale], 1
    jne .body_known
    mov r15, b404a_es
    mov rbx, b404a_es_len
    mov qword [rsp], b404b_es
    mov qword [rsp+8], b404b_es_len
.body_known:
    mov rbp, rbx                ; total body length
    add rbp, [rsp+8]
    add rbp, [rsp+24]
    lea r14, [r12+CTX_OUT]
    mov rdi, r14
    mov rsi, [tbl_status + r13*8]
    mov rdx, [tbl_status_len + r13*8]
    call mem_copy
    mov rdi, rax
    mov rsi, hdr_server
    mov edx, hdr_server_len
    call mem_copy
    mov rdi, rax
    call emit_date_hdr
    mov rdi, rax
    mov rsi, sec_headers
    mov edx, sec_headers_len
    call mem_copy
    cmp byte [r12+CTX_KEEP], 0
    je .close_hdr
    mov rsi, hdr_ka
    mov edx, hdr_ka_len
    jmp .conn_hdr
.close_hdr:
    mov rsi, hdr_cl
    mov edx, hdr_cl_len
.conn_hdr:
    mov rdi, rax
    call mem_copy
    mov rdi, rax
    mov rsi, [tbl_ctype + r13*8]
    mov rdx, [tbl_ctype_len + r13*8]
    call mem_copy
    cmp r13, 3
    jne .noallow
    mov rdi, rax
    mov rsi, hdr_allow
    mov edx, hdr_allow_len
    call mem_copy
.noallow:
    mov rdi, rax
    mov rsi, hdr_clen
    mov edx, hdr_clen_len
    call mem_copy
    mov rdi, rbp
    mov rsi, rax
    call u64_to_dec
    mov rdi, rax
    mov rsi, crlf2
    mov edx, 4
    call mem_copy
    mov rcx, rax
    sub rcx, r14                ; header length
    cmp byte [r12+CTX_HEAD], 0
    jne .headonly
    mov rdi, rax
    mov rsi, r15
    mov rdx, rbx
    call mem_copy
    mov rdi, rax
    mov rsi, [rsp+16]
    mov rdx, [rsp+24]
    call mem_copy
    mov rdi, rax
    mov rsi, [rsp]
    mov rdx, [rsp+8]
    call mem_copy
    sub rax, r14
    mov [r12+CTX_OUT_LEN], rax
    jmp .fin
.headonly:
    mov [r12+CTX_OUT_LEN], rcx
.fin:
    mov qword [r12+CTX_OUT_SENT], 0
    add rsp, 32
    pop rbp
    pop rbx
    pop r15
    pop r14
    pop r13
    pop r12
    ret

section .data

str_GET:      db 'GET'
str_POST:     db 'POST'
str_HEAD:     db 'HEAD'
str_admin:    db '/admin'
str_cl_lc:    db 'content-length:'
str_host_lc:  db 'host:'
str_xfp_lc:   db 'x-forwarded-proto:'
str_https_lc: db 'https'
str_inm_lc:   db 'if-none-match:'
str_health:   db '/health'
str_feed:     db '/feed.xml'
str_hits:     db '/hits.svg'
str_staticp:  db '/static/'
str_favicon:  db '/favicon.ico'
str_robots:   db '/robots.txt'
str_sitemap:  db '/sitemap.xml'
str_sitemapp: db '/sitemap-'
str_dotxml:   db '.xml'
str_manifest: db '/manifest.webmanifest'
str_root:     db '/'
str_pagep:    db '/page/'
str_postp:    db '/post/'
str_tagp:     db '/tag/'
str_search:   db '/search'
str_conn_lc:  db 'connection:'
str_close_lc: db 'close'
str_ka_lc:    db 'keep-alive'
str_ae_lc:    db 'accept-encoding:'
str_gzip_lc:  db 'gzip'
str_xgzip_lc: db 'x-gzip'
str_br_lc:    db 'br'

st200: db 'HTTP/1.1 200 OK', 13, 10
st200_len equ $-st200
st404: db 'HTTP/1.1 404 Not Found', 13, 10
st404_len equ $-st404
st405: db 'HTTP/1.1 405 Method Not Allowed', 13, 10
st405_len equ $-st405
st400: db 'HTTP/1.1 400 Bad Request', 13, 10
st400_len equ $-st400
st500: db 'HTTP/1.1 500 Internal Server Error', 13, 10
st500_len equ $-st500
st301: db 'HTTP/1.1 301 Moved Permanently', 13, 10
st301_len equ $-st301
hdr_loc: db 'Location: '
hdr_loc_len equ $-hdr_loc
hdr_301_tail: db 13, 10, 'Cache-Control: public, max-age=86400', 13, 10
              db 'Content-Length: 0', 13, 10, 13, 10
hdr_301_tail_len equ $-hdr_301_tail

hdr_server: db 'Server: blogd/0.7', 13, 10
hdr_server_len equ $-hdr_server

; Emitted on every response by all the builders. Everything is
; same-origin only (the error pages use the stylesheet, not inline
; style); JSON-LD data blocks are not scripts and pass script-src 'none'.
; strict-origin-when-cross-origin lets sites we link to see where their
; visitors came from without leaking paths.
sec_headers:
 db 'X-Content-Type-Options: nosniff', 13, 10
 db 'X-Frame-Options: DENY', 13, 10
 db 'Referrer-Policy: strict-origin-when-cross-origin', 13, 10
 db "Content-Security-Policy: default-src 'self'; "
 db "img-src 'self' data: https://live.staticflickr.com; "
 db "style-src 'self'; script-src 'none'; object-src 'none'; "
 db "base-uri 'none'; frame-ancestors 'none'; form-action 'self'", 13, 10
sec_headers_len equ $-sec_headers
hdr_ka: db 'Connection: keep-alive', 13, 10
hdr_ka_len equ $-hdr_ka
hdr_cl: db 'Connection: close', 13, 10
hdr_cl_len equ $-hdr_cl
hdr_allow: db 'Allow: GET, HEAD', 13, 10
hdr_allow_len equ $-hdr_allow
ct_html: db 'Content-Type: text/html; charset=utf-8', 13, 10
ct_html_len equ $-ct_html
ct_text: db 'Content-Type: text/plain; charset=utf-8', 13, 10
ct_text_len equ $-ct_text
hdr_clen: db 'Content-Length: '
hdr_clen_len equ $-hdr_clen
crlf2: db 13, 10, 13, 10

; 404: prefix | theme class | suffix, per locale
b404a_en:
 db '<!doctype html><html lang="en"><head><meta charset="utf-8">'
 db '<meta name="viewport" content="width=device-width,initial-scale=1">'
 db '<title>404 &mdash; Not Found</title><meta name="robots" content="noindex">'
 db '<link rel="stylesheet" href="/static/main.css"></head><body class="min-h-screen '
b404a_en_len equ $-b404a_en
b404b_en:
 db '"><div class="mx-auto max-w-3xl px-3 py-6"><div class="card">'
 db '<h1 class="article-title text-xl mt-0 mb-2">404 &mdash; Not Found</h1>'
 db '<p class="text-sm">No such page. <a class="backlink" href="/">&larr; back to all posts</a></p>'
 db '</div></div></body></html>'
b404b_en_len equ $-b404b_en
b404a_es:
 db '<!doctype html><html lang="es-BO"><head><meta charset="utf-8">'
 db '<meta name="viewport" content="width=device-width,initial-scale=1">'
 db '<title>404 &mdash; No encontrado</title><meta name="robots" content="noindex">'
 db '<link rel="stylesheet" href="/static/main.css"></head><body class="min-h-screen '
b404a_es_len equ $-b404a_es
b404b_es:
 db '"><div class="mx-auto max-w-3xl px-3 py-6"><div class="card">'
 db '<h1 class="article-title text-xl mt-0 mb-2">404 &mdash; No encontrado</h1>'
 db '<p class="text-sm">No existe esa p', 0xC3, 0xA1, 'gina. <a class="backlink" href="/">&larr; volver a todas las entradas</a></p>'
 db '</div></div></body></html>'
b404b_es_len equ $-b404b_es

body_ok: db 'ok', 10
body_ok_len equ $-body_ok
body_405: db 'method not allowed', 10
body_405_len equ $-body_405
body_400: db 'bad request', 10
body_400_len equ $-body_400
body_500: db 'internal error', 10
body_500_len equ $-body_500

align 8
tbl_status:     dq st200, st200, st404, st405, st400, st500
tbl_status_len: dq st200_len, st200_len, st404_len, st405_len, st400_len, st500_len
tbl_ctype:      dq ct_html, ct_text, ct_html, ct_text, ct_text, ct_text
tbl_ctype_len:  dq ct_html_len, ct_text_len, ct_html_len, ct_text_len, ct_text_len, ct_text_len
tbl_body:       dq b404a_en, body_ok, b404a_en, body_405, body_400, body_500
tbl_body_len:   dq b404a_en_len, body_ok_len, b404a_en_len, body_405_len, body_400_len, body_500_len

section .note.GNU-stack noalloc noexec nowrite progbits
