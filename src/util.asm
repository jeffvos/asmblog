; util.asm — arena allocator, memory and number primitives.
;
; Conventions (System V AMD64 unless noted):
;   - args rdi, rsi, rdx, rcx, r8, r9; return rax
;   - strings are (pointer, length) pairs; nothing scans for NUL in
;     untrusted data. parse_u64 is the one NUL-terminated exception,
;     used only on argv which the kernel terminates for us.
;   - u64_to_dec additionally clobbers r8/r9 (documented, callers beware).

BITS 64
%include "src/sys.inc"

global arena_create
global arena_alloc
global arena_reset
global arena_destroy
global cstr_eq
global fmt_date
global fmt_datetime
global fmt_httpdate
global emit_date_hdr
global put_hex
global civil
global parse_dec
global mem_copy
global mem_eq
global u64_to_dec
global parse_u64

section .text

; arena_create(size) -> arena ptr, or 0 on failure.
; Layout: [0]=capacity (total mapping size), [8]=bump offset, data at +16.
arena_create:
    mov rsi, rdi
    xor edi, edi
    mov edx, PROT_READ | PROT_WRITE
    mov r10d, MAP_PRIVATE | MAP_ANONYMOUS
    mov r8, -1
    xor r9d, r9d
    mov eax, SYS_mmap
    syscall
    cmp rax, -4095              ; kernel error returns are -4095..-1
    jae .fail
    mov [rax], rsi
    mov qword [rax+8], 0
    ret
.fail:
    xor eax, eax
    ret

; arena_alloc(arena, size) -> ptr or 0 if exhausted. 16-byte aligned.
arena_alloc:
    add rsi, 15
    and rsi, -16
    mov rax, [rdi+8]
    lea rdx, [rax+rsi]
    lea rcx, [rdx+16]
    cmp rcx, [rdi]
    ja .fail
    mov [rdi+8], rdx
    lea rax, [rdi+rax+16]
    ret
.fail:
    xor eax, eax
    ret

; arena_reset(arena) — free everything at once.
arena_reset:
    mov qword [rdi+8], 0
    ret

; arena_destroy(arena) — unmap the whole thing.
arena_destroy:
    mov rsi, [rdi]              ; capacity == mapping size
    mov eax, SYS_munmap
    syscall
    ret

; cstr_eq(cstr, lit, litlen) -> 1 if cstr is exactly lit, else 0
cstr_eq:
.loop:
    test rdx, rdx
    jz .end
    mov al, [rdi]
    test al, al
    jz .no
    cmp al, [rsi]
    jne .no
    inc rdi
    inc rsi
    dec rdx
    jmp .loop
.end:
    cmp byte [rdi], 0
    jne .no
    mov eax, 1
    ret
.no:
    xor eax, eax
    ret

; mem_copy(dst, src, len) -> dst+len (end pointer, for chained appends)
mem_copy:
    mov rcx, rdx
    rep movsb
    mov rax, rdi
    ret

; mem_eq(a, b, len) -> 1 if byte-equal else 0
mem_eq:
    test rdx, rdx
    jz .yes
.loop:
    mov al, [rdi]
    cmp al, [rsi]
    jne .no
    inc rdi
    inc rsi
    dec rdx
    jnz .loop
.yes:
    mov eax, 1
    ret
.no:
    xor eax, eax
    ret

; u64_to_dec(value, buf) -> pointer past last digit written.
; Clobbers r8, r9 in addition to caller-saved regs.
u64_to_dec:
    sub rsp, 40
    lea r8, [rsp+32]            ; digits accumulate backwards from here
    mov rax, rdi
    mov r9, 10
.digit:
    xor edx, edx
    div r9
    add dl, '0'
    dec r8
    mov [r8], dl
    test rax, rax
    jnz .digit
    lea rdx, [rsp+32]
    sub rdx, r8
    mov rdi, rsi
    mov rsi, r8
    call mem_copy
    add rsp, 40
    ret

; parse_dec(ptr, len) -> value, or 0 on empty/non-digit/too long.
; For URL path numbers (page counts): 0 is never a valid page anyway.
parse_dec:
    test rsi, rsi
    jz .bad
    cmp rsi, 9                  ; max 999,999,999 — no overflow possible
    ja .bad
    xor eax, eax
.loop:
    movzx ecx, byte [rdi]
    sub cl, '0'
    cmp cl, 9
    ja .bad
    imul rax, rax, 10
    add rax, rcx
    inc rdi
    dec rsi
    jnz .loop
    ret
.bad:
    xor eax, eax
    ret

; civil (Howard Hinnant's civil_from_days) — shared by the formatters.
; In: rdi = unix seconds. Out: r8 = year, r9 = month, r10 = day,
; r11 = seconds-of-day. Clobbers rax, rcx, rdx, rsi, rdi.
civil:
    mov rax, rdi
    xor edx, edx
    mov rcx, 86400
    div rcx
    mov r11, rdx                ; seconds of day
    add rax, 719468             ; z
    xor edx, edx
    mov rcx, 146097
    div rcx                     ; rax = era, rdx = doe
    mov rsi, rax                ; era
    mov rdi, rdx                ; doe
    ; yoe = (doe - doe/1460 + doe/36524 - doe/146096) / 365
    mov rax, rdi
    xor edx, edx
    mov rcx, 1460
    div rcx
    mov r8, rdi
    sub r8, rax
    mov rax, rdi
    xor edx, edx
    mov rcx, 36524
    div rcx
    add r8, rax
    mov rax, rdi
    xor edx, edx
    mov rcx, 146096
    div rcx
    sub r8, rax
    mov rax, r8
    xor edx, edx
    mov rcx, 365
    div rcx
    mov r9, rax                 ; yoe
    ; doy = doe - (365*yoe + yoe/4 - yoe/100)
    imul r10, r9, 365
    mov rcx, r9
    shr rcx, 2
    add r10, rcx
    mov rax, r9
    xor edx, edx
    mov rcx, 100
    div rcx
    sub r10, rax
    sub rdi, r10                ; rdi = doy
    ; mp = (5*doy + 2) / 153
    lea rax, [rdi+rdi*4+2]
    xor edx, edx
    mov rcx, 153
    div rcx
    mov r10, rax                ; mp
    ; d = doy - (153*mp + 2)/5 + 1
    imul rax, r10, 153
    add rax, 2
    xor edx, edx
    mov rcx, 5
    div rcx
    sub rdi, rax
    inc rdi                     ; day
    ; m = mp + (mp < 10 ? 3 : -9)
    lea rcx, [r10+3]
    cmp r10, 10
    jb .mok
    lea rcx, [r10-9]
.mok:
    imul rax, rsi, 400          ; y = yoe + era*400 (+1 if m <= 2)
    add rax, r9
    cmp rcx, 2
    ja .ynofix
    inc rax
.ynofix:
    mov r8, rax                 ; year
    mov r9, rcx                 ; month
    mov r10, rdi                ; day
    ret

; put2(buf, value 0..99) — two zero-padded digits; rax = buf+2
put2:
    xor edx, edx
    mov rcx, 10
    div rcx
    add al, '0'
    mov [rdi], al
    add dl, '0'
    mov [rdi+1], dl
    lea rax, [rdi+2]
    ret

; put_ymd(buf) with r8=y r9=m r10=d -> rax = buf+10 ("YYYY-MM-DD")
put_ymd:
    mov rax, r8
    xor edx, edx
    mov rcx, 1000
    div rcx
    add al, '0'
    mov [rdi], al
    mov rax, rdx
    xor edx, edx
    mov rcx, 100
    div rcx
    add al, '0'
    mov [rdi+1], al
    mov rax, rdx
    xor edx, edx
    mov rcx, 10
    div rcx
    add al, '0'
    mov [rdi+2], al
    add dl, '0'
    mov [rdi+3], dl
    mov byte [rdi+4], '-'
    lea rdi, [rdi+5]
    mov rax, r9
    call put2
    mov byte [rax], '-'
    lea rdi, [rax+1]
    mov rax, r10
    call put2
    ret

; fmt_date(secs, buf) -> rax = buf+10 ("YYYY-MM-DD")
fmt_date:
    push rsi
    call civil
    pop rdi
    jmp put_ymd

; fmt_datetime(secs, buf) -> rax = buf+20 ("YYYY-MM-DDTHH:MM:SSZ")
fmt_datetime:
    push rsi
    call civil
    pop rdi
    call put_ymd
    mov rdi, rax
    mov byte [rdi], 'T'
    inc rdi
    mov rax, r11
    xor edx, edx
    mov rcx, 3600
    div rcx
    mov r8, rdx
    call put2
    mov rdi, rax
    mov byte [rdi], ':'
    inc rdi
    mov rax, r8
    xor edx, edx
    mov rcx, 60
    div rcx
    mov r8, rdx
    call put2
    mov rdi, rax
    mov byte [rdi], ':'
    inc rdi
    mov rax, r8
    call put2
    mov byte [rax], 'Z'
    inc rax
    ret

; put4(buf, value 0..9999) — four zero-padded digits; rax = buf+4
put4:
    xor edx, edx
    mov rcx, 100
    div rcx                     ; rax = high pair, rdx = low pair
    push rdx
    call put2
    pop rdx
    mov rdi, rax
    mov rax, rdx
    jmp put2

; fmt_httpdate(secs, buf) -> rax = buf+29
;   RFC 7231 IMF-fixdate: "Sun, 06 Nov 1994 08:49:37 GMT"
fmt_httpdate:
    push r12
    push r13
    mov r12, rsi                ; buf
    mov r13, rdi                ; secs
    call civil                  ; r8 = y, r9 = m, r10 = d, r11 = sec of day
    mov rax, r13                ; day of week: 1970-01-01 was a Thursday
    xor edx, edx
    mov rcx, 86400
    div rcx
    add rax, 4
    xor edx, edx
    mov rcx, 7
    div rcx                     ; rdx = 0 Sun .. 6 Sat
    mov eax, [dow4 + rdx*4]     ; "Sun,"
    mov [r12], eax
    mov byte [r12+4], ' '
    lea rdi, [r12+5]
    mov rax, r10
    call put2                   ; day
    mov byte [r12+7], ' '
    lea rax, [r9-1]
    mov eax, [mon4 + rax*4]     ; "Nov "
    mov [r12+8], eax
    lea rdi, [r12+12]
    mov rax, r8
    call put4                   ; year
    mov byte [r12+16], ' '
    lea rdi, [r12+17]
    mov rax, r11
    xor edx, edx
    mov rcx, 3600
    div rcx
    mov r8, rdx
    call put2                   ; hour
    mov byte [r12+19], ':'
    lea rdi, [r12+20]
    mov rax, r8
    xor edx, edx
    mov rcx, 60
    div rcx
    mov r8, rdx
    call put2                   ; minute
    mov byte [r12+22], ':'
    lea rdi, [r12+23]
    mov rax, r8
    call put2                   ; second
    mov dword [r12+25], ' GMT'
    lea rax, [r12+29]
    pop r13
    pop r12
    ret

; emit_date_hdr(buf) -> rax = end. Writes "Date: <now>\r\n" (37 bytes).
emit_date_hdr:
    push r12
    mov r12, rdi
    mov dword [r12], 'Date'
    mov word [r12+4], ': '
    xor edi, edi
    mov eax, SYS_time
    syscall
    mov rdi, rax
    lea rsi, [r12+6]
    call fmt_httpdate
    mov word [rax], 0x0A0D
    lea rax, [rax+2]
    pop r12
    ret

; put_hex(value, buf, ndigits) -> rax = buf+ndigits. Lowercase, zero
; padded, low ndigits*4 bits of value.
put_hex:
    lea rax, [rsi+rdx]
    mov r8, rax
    mov rcx, rdx
.digit:
    test rcx, rcx
    jz .done
    mov rdx, rdi
    and edx, 15
    mov dl, [hexdigits + rdx]
    dec r8
    mov [r8], dl
    shr rdi, 4
    dec rcx
    jmp .digit
.done:
    ret

parse_u64:
    xor eax, eax
    cmp byte [rdi], 0
    je .bad
.loop:
    movzx ecx, byte [rdi]
    test cl, cl
    jz .done
    sub cl, '0'
    cmp cl, 9
    ja .bad
    imul rax, rax, 10
    jc .bad
    add rax, rcx
    jc .bad
    inc rdi
    jmp .loop
.done:
    ret
.bad:
    mov rax, -1
    ret

section .data

dow4: db 'Sun,Mon,Tue,Wed,Thu,Fri,Sat,'
mon4: db 'Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec '
hexdigits: db '0123456789abcdef'

section .note.GNU-stack noalloc noexec nowrite progbits
