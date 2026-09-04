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
extern page_list
extern page_post
extern page_feed
extern page_css
extern admin_route

global http_handle
global http_body_len
global build_page
global ci_find
global ci_prefix
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

    cmp r15, 3                  ; method: GET or POST
    jne .try_post
    mov rdi, r14
    mov rsi, str_GET
    mov edx, 3
    call mem_eq
    test eax, eax
    jz .m405
    xor r10d, r10d              ; is_post = 0
    jmp .method_done
.try_post:
    cmp r15, 4
    jne .m405
    mov rdi, r14
    mov rsi, str_POST
    mov edx, 4
    call mem_eq
    test eax, eax
    jz .m405
    mov r10d, 1
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
    cmp r15, 16
    jne .r_page
    mov rdi, r14
    mov rsi, str_css
    mov edx, 16
    call mem_eq
    test eax, eax
    jz .r_page                  ; a 16-char /post/ URL also lands here
    mov rdi, r12
    call page_css
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

; scan_gzip(headers, len) -> 1 if Accept-Encoding mentions gzip
scan_gzip:
    push r12
    push r13
    push r14
    mov r12, rdi
    mov r13, rsi
.line:
    test r13, r13
    jz .no
    xor r14d, r14d
.findcr:
    cmp r14, r13
    jae .no
    cmp byte [r12+r14], 13
    je .have
    inc r14
    jmp .findcr
.have:
    cmp r14, 16
    jb .advance
    mov rdi, r12
    mov rsi, str_ae_lc
    mov edx, 16
    call ci_prefix
    test eax, eax
    jz .advance
    lea rdi, [r12+16]
    lea rsi, [r14-16]
    mov rdx, str_gzip_lc
    mov ecx, 4
    call ci_find
    jmp .ret
.advance:
    lea rax, [r14+2]
    cmp rax, r13
    ja .no
    add r12, rax
    sub r13, rax
    jmp .line
.no:
    xor eax, eax
.ret:
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
build_page:
    push r12
    push r13
    push r14
    push rbx
    mov r12, rdi
    mov r13, rsi
    mov qword [r12+CTX_OUT_START], 0
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
    mov rdi, rax
    mov rsi, hdr_clen
    mov edx, hdr_clen_len
    call mem_copy
    mov rbx, [tbl_body_len + r13*8]
    mov rdi, rbx
    mov rsi, rax
    call u64_to_dec
    mov rdi, rax
    mov rsi, crlf2
    mov edx, 4
    call mem_copy
    mov rdi, rax
    mov rsi, [tbl_body + r13*8]
    mov rdx, rbx
    call mem_copy
    sub rax, r14
    mov [r12+CTX_OUT_LEN], rax
    mov qword [r12+CTX_OUT_SENT], 0
    pop rbx
    pop r14
    pop r13
    pop r12
    ret

section .data

str_GET:      db 'GET'
str_POST:     db 'POST'
str_admin:    db '/admin'
str_cl_lc:    db 'content-length:'
str_health:   db '/health'
str_feed:     db '/feed.xml'
str_css:      db '/static/main.css'
str_pagep:    db '/page/'
str_postp:    db '/post/'
str_tagp:     db '/tag/'
str_search:   db '/search'
str_conn_lc:  db 'connection:'
str_close_lc: db 'close'
str_ka_lc:    db 'keep-alive'
str_ae_lc:    db 'accept-encoding:'
str_gzip_lc:  db 'gzip'

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

hdr_server: db 'Server: blogd/0.6', 13, 10
hdr_server_len equ $-hdr_server

; Emitted on every response by all three builders. style-src allows
; 'unsafe-inline' because the retro theme leans on inline style on a
; couple of hardcoded error pages; everything else is same-origin only.
sec_headers:
 db 'X-Content-Type-Options: nosniff', 13, 10
 db 'X-Frame-Options: DENY', 13, 10
 db 'Referrer-Policy: no-referrer', 13, 10
 db "Content-Security-Policy: default-src 'self'; img-src 'self' data:; "
 db "style-src 'self' 'unsafe-inline'; object-src 'none'; base-uri 'none'; "
 db "frame-ancestors 'none'; form-action 'self'", 13, 10
sec_headers_len equ $-sec_headers
hdr_ka: db 'Connection: keep-alive', 13, 10
hdr_ka_len equ $-hdr_ka
hdr_cl: db 'Connection: close', 13, 10
hdr_cl_len equ $-hdr_cl
ct_html: db 'Content-Type: text/html; charset=utf-8', 13, 10
ct_html_len equ $-ct_html
ct_text: db 'Content-Type: text/plain; charset=utf-8', 13, 10
ct_text_len equ $-ct_text
hdr_clen: db 'Content-Length: '
hdr_clen_len equ $-hdr_clen
crlf2: db 13, 10, 13, 10

body_404:
 db '<!doctype html><html lang="en"><head><meta charset="utf-8"><title>404</title></head>'
 db '<body style="background:#000080;color:#fff;font-family:monospace;padding:40px">'
 db '<h1>404 &mdash; Not Found</h1><p>No such page. <a href="/" style="color:#0ff">Go home</a>.</p>'
 db '</body></html>'
body_404_len equ $-body_404

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
tbl_body:       dq body_404, body_ok, body_404, body_405, body_400, body_500
tbl_body_len:   dq body_404_len, body_ok_len, body_404_len, body_405_len, body_400_len, body_500_len

section .note.GNU-stack noalloc noexec nowrite progbits
