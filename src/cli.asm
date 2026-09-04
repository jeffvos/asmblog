; cli.asm — `blogd init` and `blogd selftest`.
;
; init: interactive first-run setup — site title, posts per page,
; admin password read with terminal echo disabled, hashed with
; Argon2id (crypto.asm), persisted as the settings record.
;
; selftest: exercises the store end-to-end in the current working
; directory (run it in a scratch dir): append/update/delete, settings,
; reload from disk, compaction, then a real Argon2id hash+verify.
; Prints "selftest ok" or "selftest FAIL step N".

BITS 64
%include "src/sys.inc"
%include "src/store.inc"

%define SEED_N 9

extern store_open
extern store_reset
extern store_append_post
extern store_delete_post
extern store_save_settings
extern store_compact
extern store_find_by_id
extern posts_cnt
extern next_id
extern set_ppp
extern crypto_init
extern crypto_hash_password
extern crypto_verify_password
extern parse_u64
extern mem_eq
extern mem_copy
extern u64_to_dec

global init_main
global selftest_main
global seed_main

section .text

; print(ptr, len) to stdout
print:
    mov rdx, rsi
    mov rsi, rdi
    mov edi, STDOUT
    mov eax, SYS_write
    syscall
    ret

; read_line(buf, max) -> length, newline consumed but not stored.
; Reads one byte per syscall so a single line is taken from a pipe
; without swallowing following lines (init must behave the same whether
; stdin is a terminal or a here-string). Overflow bytes past `max` are
; drained and discarded so the next read starts on a fresh line.
read_line:
    push r12
    push r13
    push r14
    mov r12, rdi                ; buf
    mov r13, rsi                ; max
    xor r14d, r14d              ; count
.loop:
    sub rsp, 8
    xor edi, edi                ; stdin
    mov rsi, rsp
    mov edx, 1
    xor eax, eax                ; SYS_read
    syscall
    cmp rax, 1
    jne .eof
    mov al, [rsp]
    add rsp, 8
    cmp al, 10                  ; newline ends the line
    je .done
    cmp r14, r13
    jae .loop                   ; past capacity: keep draining to EOL
    mov [r12+r14], al
    inc r14
    jmp .loop
.eof:
    add rsp, 8
.done:
    mov rax, r14
    pop r14
    pop r13
    pop r12
    ret

; term_echo(enable) — toggle ECHO on stdin
term_echo:
    push r12
    mov r12, rdi
    sub rsp, 64
    xor edi, edi
    mov esi, TCGETS
    mov rdx, rsp
    mov eax, SYS_ioctl
    syscall
    mov eax, [rsp+12]           ; c_lflag
    test r12, r12
    jz .off
    or eax, ECHO_FLAG
    jmp .set
.off:
    and eax, ~ECHO_FLAG
.set:
    mov [rsp+12], eax
    xor edi, edi
    mov esi, TCSETS
    mov rdx, rsp
    mov eax, SYS_ioctl
    syscall
    add rsp, 64
    pop r12
    ret

; die(msgptr, msglen) — stderr + exit 1
die:
    mov rdx, rsi
    mov rsi, rdi
    mov edi, STDERR
    mov eax, SYS_write
    syscall
    mov edi, 1
    mov eax, SYS_exit_group
    syscall

; ---- blogd init -------------------------------------------------------

init_main:
    call crypto_init
    test rax, rax
    js .sodium_fail
    call store_open
    test rax, rax
    jnz .store_fail

    mov rdi, p_title
    mov esi, p_title_len
    call print
    mov rdi, title_buf
    mov esi, 120
    call read_line
    mov [title_len], rax
    cmp rax, 1
    jge .have_title
    mov rdi, title_buf          ; empty: default title
    mov rsi, def_title
    mov edx, def_title_len
    call mem_copy
    mov qword [title_len], def_title_len
.have_title:

    mov rdi, p_ppp
    mov esi, p_ppp_len
    call print
    mov rdi, num_buf
    mov esi, 14
    call read_line
    mov rcx, 5                  ; default
    cmp rax, 1
    jl .have_ppp
    mov byte [num_buf+rax], 0
    push rcx
    mov rdi, num_buf
    call parse_u64
    pop rcx
    cmp rax, 1
    jl .have_ppp
    cmp rax, 50
    ja .have_ppp
    mov rcx, rax
.have_ppp:
    mov [ppp_val], rcx

    mov rdi, p_pw
    mov esi, p_pw_len
    call print
    xor edi, edi
    call term_echo
    mov rdi, pw1_buf
    mov esi, 128
    call read_line
    mov [pw1_len], rax
    mov edi, 1
    call term_echo
    mov rdi, nl
    mov esi, 1
    call print
    cmp qword [pw1_len], 8
    jl .pw_short

    mov rdi, p_pw2
    mov esi, p_pw2_len
    call print
    xor edi, edi
    call term_echo
    mov rdi, pw2_buf
    mov esi, 128
    call read_line
    mov [pw2_len], rax
    mov edi, 1
    call term_echo
    mov rdi, nl
    mov esi, 1
    call print
    mov rax, [pw1_len]
    cmp rax, [pw2_len]
    jne .pw_mismatch
    mov rdi, pw1_buf
    mov rsi, pw2_buf
    mov rdx, rax
    call mem_eq
    test eax, eax
    jz .pw_mismatch

    mov rdi, p_hashing
    mov esi, p_hashing_len
    call print
    mov rdi, pw1_buf
    mov rsi, [pw1_len]
    mov rdx, hash_buf
    call crypto_hash_password
    test rax, rax
    jnz .hash_fail

    mov edi, [ppp_val]
    mov esi, 86400              ; session ttl: 24h
    mov rdx, title_buf
    mov rcx, [title_len]
    mov r8, hash_buf
    call store_save_settings
    test rax, rax
    jnz .store_fail

    mov rdi, p_done
    mov esi, p_done_len
    call print
    xor edi, edi
    mov eax, SYS_exit_group
    syscall

.sodium_fail:
    mov rdi, e_sodium
    mov esi, e_sodium_len
    jmp die
.store_fail:
    mov rdi, e_store
    mov esi, e_store_len
    jmp die
.pw_short:
    mov rdi, e_short
    mov esi, e_short_len
    jmp die
.pw_mismatch:
    mov rdi, e_mismatch
    mov esi, e_mismatch_len
    jmp die
.hash_fail:
    mov rdi, e_hash
    mov esi, e_hash_len
    jmp die

; ---- blogd seed -------------------------------------------------------
; Appends 9 demo posts (8 published, 1 draft) for development/testing.

seed_main:
    call store_open
    test rax, rax
    jnz .store_fail
    sub rsp, S_SIZE
    xor r12d, r12d
.row:
    cmp r12, SEED_N
    jae .done
    imul rax, r12, 88
    lea r13, [seed_tbl+rax]
    mov rdi, rsp
    mov ecx, S_SIZE/8
    xor eax, eax
    rep stosq
    mov rax, [r13]
    mov [rsp+S_FLAGS], rax
    lea rdi, [rsp+S_TITLE_P]    ; five (ptr,len) pairs follow flags
    lea rsi, [r13+8]
    mov edx, 80
    call mem_copy
    mov rdi, rsp
    call store_append_post
    test rax, rax
    js .seed_fail
    inc r12
    jmp .row
.done:
    mov rdi, p_seeded
    mov esi, p_seeded_len
    call print
    xor edi, edi
    mov eax, SYS_exit_group
    syscall
.store_fail:
.seed_fail:
    mov rdi, e_store
    mov esi, e_store_len
    jmp die

; ---- blogd selftest ---------------------------------------------------

; fail_test(step) — print "selftest FAIL step N" and exit 1
fail_test:
    push rdi
    mov rdi, e_fail
    mov esi, e_fail_len
    call print
    pop rdi
    mov rsi, num_buf
    call u64_to_dec
    mov byte [rax], 10
    inc rax
    mov rsi, rax
    sub rsi, num_buf            ; length including newline
    mov rdi, num_buf
    call print
    mov edi, 1
    mov eax, SYS_exit_group
    syscall

%macro CHECK 2                  ; CHECK cond-jump-to-ok, step
    %1 %%ok
    mov edi, %2
    call fail_test
%%ok:
%endmacro

%macro SPEC_CLEAR 0
    mov rdi, rsp
    mov ecx, S_SIZE/8
    xor eax, eax
    rep stosq
%endmacro

%macro SPEC_SET 3               ; offset, ptr, len
    mov qword [rsp+%1], %2
    mov qword [rsp+%1+8], %3
%endmacro

selftest_main:
    sub rsp, S_SIZE

    ; 1: fresh open
    call store_open
    test rax, rax
    CHECK jz, 1

    ; 2: append post A (published) -> id 1
    SPEC_CLEAR
    mov qword [rsp+S_FLAGS], FLAG_PUBLISHED
    SPEC_SET S_TITLE_P, t_titleA, t_titleA_len
    SPEC_SET S_SLUG_P,  t_slugA,  t_slugA_len
    SPEC_SET S_TAGS_P,  t_tags,   t_tags_len
    SPEC_SET S_MD_P,    t_md,     t_md_len
    SPEC_SET S_HTML_P,  t_html,   t_html_len
    mov rdi, rsp
    call store_append_post
    cmp rax, 1
    CHECK je, 2

    ; 3: append post B (draft) -> id 2
    SPEC_CLEAR
    SPEC_SET S_TITLE_P, t_titleB, t_titleB_len
    SPEC_SET S_SLUG_P,  t_slugB,  t_slugB_len
    SPEC_SET S_MD_P,    t_md,     t_md_len
    SPEC_SET S_HTML_P,  t_html,   t_html_len
    mov rdi, rsp
    call store_append_post
    cmp rax, 2
    CHECK je, 3

    ; 4: append post C (published) -> id 3
    SPEC_CLEAR
    mov qword [rsp+S_FLAGS], FLAG_PUBLISHED
    SPEC_SET S_TITLE_P, t_titleC, t_titleC_len
    SPEC_SET S_SLUG_P,  t_slugC,  t_slugC_len
    SPEC_SET S_MD_P,    t_md,     t_md_len
    SPEC_SET S_HTML_P,  t_html,   t_html_len
    mov rdi, rsp
    call store_append_post
    cmp rax, 3
    CHECK je, 4

    ; 5: three posts live
    cmp qword [posts_cnt], 3
    CHECK je, 5

    ; 6: delete the draft
    mov edi, 2
    call store_delete_post
    test rax, rax
    CHECK jz, 6
    cmp qword [posts_cnt], 2
    CHECK je, 6

    ; 7: save settings (ppp 7)
    mov edi, 7
    mov esi, 3600
    mov rdx, t_site
    mov ecx, t_site_len
    mov r8, t_fakehash
    call store_save_settings
    test rax, rax
    CHECK jz, 7

    ; 8-12: reload from disk, everything survives
    call store_reset
    call store_open
    test rax, rax
    CHECK jz, 8
    cmp qword [posts_cnt], 2
    CHECK je, 9
    cmp qword [next_id], 4
    CHECK je, 10
    cmp dword [set_ppp], 7
    CHECK je, 11
    mov edi, 1
    call store_find_by_id
    test rax, rax
    CHECK jnz, 12
    mov edi, 2
    call store_find_by_id
    test rax, rax
    CHECK jz, 12

    ; 13-15: update post 1 with a longer title
    SPEC_CLEAR
    mov qword [rsp+S_ID], 1
    mov qword [rsp+S_FLAGS], FLAG_PUBLISHED
    SPEC_SET S_TITLE_P, t_titleA2, t_titleA2_len
    SPEC_SET S_SLUG_P,  t_slugA,  t_slugA_len
    SPEC_SET S_MD_P,    t_md,     t_md_len
    SPEC_SET S_HTML_P,  t_html,   t_html_len
    mov rdi, rsp
    call store_append_post
    cmp rax, 1
    CHECK je, 13
    cmp qword [posts_cnt], 2
    CHECK je, 14
    mov edi, 1
    call store_find_by_id
    cmp qword [rax+P_TITLE_L], t_titleA2_len
    CHECK je, 15

    ; 16-19: compact, reload, everything still there
    call store_compact
    test rax, rax
    CHECK jz, 16
    call store_reset
    call store_open
    test rax, rax
    CHECK jz, 17
    cmp qword [posts_cnt], 2
    CHECK je, 18
    mov edi, 1
    call store_find_by_id
    test rax, rax
    CHECK jnz, 19
    cmp qword [rax+P_TITLE_L], t_titleA2_len
    CHECK je, 19

    ; 20-23: Argon2id round trip (the slow part)
    mov rdi, p_crypto
    mov esi, p_crypto_len
    call print
    call crypto_init
    test rax, rax
    CHECK jns, 20
    mov rdi, t_pw
    mov esi, t_pw_len
    mov rdx, hash_buf
    call crypto_hash_password
    test rax, rax
    CHECK jz, 21
    mov rdi, hash_buf
    mov rsi, t_pw
    mov edx, t_pw_len
    call crypto_verify_password
    test rax, rax
    CHECK jz, 22
    mov rdi, hash_buf
    mov rsi, t_wrongpw
    mov edx, t_wrongpw_len
    call crypto_verify_password
    test rax, rax
    CHECK jnz, 23

    mov rdi, p_ok
    mov esi, p_ok_len
    call print
    xor edi, edi
    mov eax, SYS_exit_group
    syscall

section .data

p_title: db 'site title [My Retro Blog]: '
p_title_len equ $-p_title
p_ppp: db 'posts per page [5]: '
p_ppp_len equ $-p_ppp
p_pw: db 'admin password (min 8 chars, echo off): '
p_pw_len equ $-p_pw
p_pw2: db 'confirm password: '
p_pw2_len equ $-p_pw2
p_hashing: db 'hashing password (Argon2id, ~1s)...', 10
p_hashing_len equ $-p_hashing
p_done: db 'initialized data/store.blg', 10
p_done_len equ $-p_done
def_title: db 'My Retro Blog'
def_title_len equ $-def_title
nl: db 10

e_sodium: db 'blogd init: libsodium init failed', 10
e_sodium_len equ $-e_sodium
e_store: db 'blogd: store open/write failed', 10
e_store_len equ $-e_store
e_short: db 'blogd init: password too short (min 8)', 10
e_short_len equ $-e_short
e_mismatch: db 'blogd init: passwords do not match', 10
e_mismatch_len equ $-e_mismatch
e_hash: db 'blogd init: password hashing failed', 10
e_hash_len equ $-e_hash
e_fail: db 'selftest FAIL step '
e_fail_len equ $-e_fail

p_crypto: db 'store ok; testing Argon2id (a few seconds)...', 10
p_crypto_len equ $-p_crypto
p_ok: db 'selftest ok', 10
p_ok_len equ $-p_ok
p_seeded: db 'seeded 9 posts (8 published, 1 draft)', 10
p_seeded_len equ $-p_seeded

; ---- seed content -----------------------------------------------------

sd_t1: db 'Welcome to the Retroweb'
sd_t1_len equ $-sd_t1
sd_s1: db 'welcome-to-the-retroweb'
sd_s1_len equ $-sd_s1
sd_g1: db 'meta,retro'
sd_g1_len equ $-sd_g1
sd_m1: db 'This blog is served by hand-written x86_64 assembly. No frameworks, no runtime, no libc. Just syscalls and vibes from 1996.'
sd_m1_len equ $-sd_m1
sd_h1: db '<p>This blog is served by <strong>hand-written x86_64 assembly</strong>. No frameworks, no runtime, no libc. Just syscalls and vibes from 1996.</p><p>View source. There is nothing to see. That is the point.</p>'
sd_h1_len equ $-sd_h1

sd_t2: db 'Why Assembly?'
sd_t2_len equ $-sd_t2
sd_s2: db 'why-assembly'
sd_s2_len equ $-sd_s2
sd_g2: db 'asm,meta'
sd_g2_len equ $-sd_g2
sd_m2: db 'Because every abstraction is a small act of forgetting. Down here there is only mov, and mov is honest.'
sd_m2_len equ $-sd_m2
sd_h2: db '<p>Because every abstraction is a small act of forgetting. Down here there is only <code>mov</code>, and <code>mov</code> is honest.</p><h2>The stack is a place</h2><p>You can visit it. Bring a guard page.</p>'
sd_h2_len equ $-sd_h2

sd_t3: db 'Under Construction Forever'
sd_t3_len equ $-sd_t3
sd_s3: db 'under-construction-forever'
sd_s3_len equ $-sd_s3
sd_g3: db 'retro,web'
sd_g3_len equ $-sd_g3
sd_m3: db 'Every good site of the old web was permanently under construction. The animated digging man was a promise: this place is alive.'
sd_m3_len equ $-sd_m3
sd_h3: db '<p>Every good site of the old web was permanently under construction. The animated digging man was a promise: <em>this place is alive</em>.</p><p>This site honors the tradition. Milestones remain.</p>'
sd_h3_len equ $-sd_h3

sd_t4: db 'The Lost Art of the Guestbook'
sd_t4_len equ $-sd_t4
sd_s4: db 'lost-art-of-the-guestbook'
sd_s4_len equ $-sd_s4
sd_g4: db 'retro,web'
sd_g4_len equ $-sd_g4
sd_m4: db 'Before comments, before likes, there was the guestbook: a place to simply say I was here, and mean it.'
sd_m4_len equ $-sd_m4
sd_h4: db '<p>Before comments, before likes, there was the guestbook: a place to simply say <em>I was here</em>, and mean it.</p><blockquote>cool site!!! greetings from Finland</blockquote><p>Poetry.</p>'
sd_h4_len equ $-sd_h4

sd_t5: db 'Ode to the Marquee Tag'
sd_t5_len equ $-sd_t5
sd_s5: db 'ode-to-the-marquee-tag'
sd_s5_len equ $-sd_s5
sd_g5: db 'retro,web'
sd_g5_len equ $-sd_g5
sd_m5: db 'The marquee tag was deprecated because we were not ready for it. Text that moves. Imagine the confidence.'
sd_m5_len equ $-sd_m5
sd_h5: db '<p>The <code>&lt;marquee&gt;</code> tag was deprecated because we were not ready for it. Text that moves. Imagine the confidence.</p><p>The banner atop this page is a CSS tribute. It respects <code>prefers-reduced-motion</code>, because we are polite now.</p>'
sd_h5_len equ $-sd_h5

sd_t6: db 'Ring My Webring'
sd_t6_len equ $-sd_t6
sd_s6: db 'ring-my-webring'
sd_s6_len equ $-sd_s6
sd_g6: db 'retro,web'
sd_g6_len equ $-sd_g6
sd_m6: db 'Webrings were federated discovery before anyone said federated. Previous, next, random: an algorithm you could hold in your hand.'
sd_m6_len equ $-sd_m6
sd_h6: db '<p>Webrings were federated discovery before anyone said federated. Previous, next, random: an algorithm you could hold in your hand.</p>'
sd_h6_len equ $-sd_h6

sd_t7: db 'Cache Rules Everything Around Me'
sd_t7_len equ $-sd_t7
sd_s7: db 'cache-rules-everything-around-me'
sd_s7_len equ $-sd_s7
sd_g7: db 'asm'
sd_g7_len equ $-sd_g7
sd_m7: db 'L1 in 4 cycles, L2 in 12, RAM in 200. The memory hierarchy is the only pyramid scheme that pays out.'
sd_m7_len equ $-sd_m7
sd_h7: db '<p>L1 in 4 cycles, L2 in 12, RAM in 200. The memory hierarchy is the only pyramid scheme that pays out.</p><pre>mov rax, [rdi]   ; pray it is resident</pre>'
sd_h7_len equ $-sd_h7

sd_t8: db 'One Megabyte Ought to Be Enough'
sd_t8_len equ $-sd_t8
sd_s8: db 'one-megabyte-ought-to-be-enough'
sd_s8_len equ $-sd_s8
sd_g8: db 'asm,meta'
sd_g8_len equ $-sd_g8
sd_m8: db 'This entire server, storage engine included, is smaller than the average favicon pipeline. Constraints are a design tool.'
sd_m8_len equ $-sd_m8
sd_h8: db '<p>This entire server, storage engine included, is smaller than the average favicon pipeline. Constraints are a design tool.</p>'
sd_h8_len equ $-sd_h8

sd_t9: db 'Secret Draft: Do Not Publish'
sd_t9_len equ $-sd_t9
sd_s9: db 'secret-draft'
sd_s9_len equ $-sd_s9
sd_g9: db 'meta'
sd_g9_len equ $-sd_g9
sd_m9: db 'If you can read this on the public site, the draft flag is broken.'
sd_m9_len equ $-sd_m9
sd_h9: db '<p>If you can read this on the public site, the draft flag is broken.</p>'
sd_h9_len equ $-sd_h9

align 8
seed_tbl:                       ; 88 bytes per row: flags + 5 (ptr,len) pairs
    dq FLAG_PUBLISHED, sd_t1, sd_t1_len, sd_s1, sd_s1_len, sd_g1, sd_g1_len, sd_m1, sd_m1_len, sd_h1, sd_h1_len
    dq FLAG_PUBLISHED, sd_t2, sd_t2_len, sd_s2, sd_s2_len, sd_g2, sd_g2_len, sd_m2, sd_m2_len, sd_h2, sd_h2_len
    dq FLAG_PUBLISHED, sd_t3, sd_t3_len, sd_s3, sd_s3_len, sd_g3, sd_g3_len, sd_m3, sd_m3_len, sd_h3, sd_h3_len
    dq FLAG_PUBLISHED, sd_t4, sd_t4_len, sd_s4, sd_s4_len, sd_g4, sd_g4_len, sd_m4, sd_m4_len, sd_h4, sd_h4_len
    dq FLAG_PUBLISHED, sd_t5, sd_t5_len, sd_s5, sd_s5_len, sd_g5, sd_g5_len, sd_m5, sd_m5_len, sd_h5, sd_h5_len
    dq FLAG_PUBLISHED, sd_t6, sd_t6_len, sd_s6, sd_s6_len, sd_g6, sd_g6_len, sd_m6, sd_m6_len, sd_h6, sd_h6_len
    dq FLAG_PUBLISHED, sd_t7, sd_t7_len, sd_s7, sd_s7_len, sd_g7, sd_g7_len, sd_m7, sd_m7_len, sd_h7, sd_h7_len
    dq FLAG_PUBLISHED, sd_t8, sd_t8_len, sd_s8, sd_s8_len, sd_g8, sd_g8_len, sd_m8, sd_m8_len, sd_h8, sd_h8_len
    dq 0,              sd_t9, sd_t9_len, sd_s9, sd_s9_len, sd_g9, sd_g9_len, sd_m9, sd_m9_len, sd_h9, sd_h9_len

t_titleA: db 'Hello World'
t_titleA_len equ $-t_titleA
t_titleA2: db 'Hello Again, World'
t_titleA2_len equ $-t_titleA2
t_titleB: db 'Draft Post'
t_titleB_len equ $-t_titleB
t_titleC: db 'Third Post'
t_titleC_len equ $-t_titleC
t_slugA: db 'hello-world'
t_slugA_len equ $-t_slugA
t_slugB: db 'draft-post'
t_slugB_len equ $-t_slugB
t_slugC: db 'third-post'
t_slugC_len equ $-t_slugC
t_tags: db 'retro,meta'
t_tags_len equ $-t_tags
t_md: db '# Hi', 10, 10, 'Body text.'
t_md_len equ $-t_md
t_html: db '<h1>Hi</h1><p>Body text.</p>'
t_html_len equ $-t_html
t_site: db 'Test Blog'
t_site_len equ $-t_site
t_fakehash: times 128 db 'x'
t_pw: db 'correct horse battery'
t_pw_len equ $-t_pw
t_wrongpw: db 'wrong password!!'
t_wrongpw_len equ $-t_wrongpw

section .bss

title_buf: resb 128
title_len: resq 1
num_buf:   resb 32
ppp_val:   resq 1
pw1_buf:   resb 128
pw1_len:   resq 1
pw2_buf:   resb 128
pw2_len:   resq 1
hash_buf:  resb 128

section .note.GNU-stack noalloc noexec nowrite progbits
