; i18n.asm — locale string table + localized long dates.
;
; The locale is a site-wide setting ([set_locale]: 0 en-US, 1 es-BO).
; Template text is localized by loading templates/<locale>/; this file
; covers only the strings assembly emits itself (page titles, list
; headings, pager labels, dashboard status, error messages) and the
; human-readable date format. Strings are UTF-8 bytes; the HTML escaper
; passes bytes >= 0x80 through untouched.

BITS 64
%include "src/i18n.inc"

extern set_locale
extern civil
extern mem_copy
extern u64_to_dec

global i18n_get
global fmt_date_local

section .text

; i18n_get(id) -> rax = ptr, rdx = len (clobbers rcx)
i18n_get:
    mov eax, [set_locale]
    cmp eax, 1
    jbe .ok
    xor eax, eax                ; unknown locale id: fall back to en
.ok:
    lea rcx, [rdi+rdi]          ; row = id*2 + locale, 16 bytes each
    add rcx, rax
    shl rcx, 4
    mov rax, [i18n_tbl + rcx]
    mov rdx, [i18n_tbl + rcx + 8]
    ret

; fmt_date_local(secs, buf) -> rax = end pointer.
;   en-US: "September 3, 2026"      es-BO: "3 de septiembre de 2026"
; Needs a 32-byte buffer. Clobbers caller-saved regs incl. r8-r11.
fmt_date_local:
    push r12
    push r13
    push r14
    push r15
    mov r12, rsi                ; buf
    call civil                  ; r8 = y, r9 = m, r10 = d
    mov r13, r8
    mov r14, r9
    mov r15, r10
    cmp dword [set_locale], 1
    je .es
    ; Month d, yyyy
    lea rax, [r14-1]
    shl rax, 4
    mov rdi, r12
    mov rsi, [month_en + rax]
    mov rdx, [month_en + rax + 8]
    call mem_copy
    mov byte [rax], ' '
    inc rax
    mov rdi, r15
    mov rsi, rax
    call u64_to_dec
    mov word [rax], ', '
    add rax, 2
    mov rdi, r13
    mov rsi, rax
    call u64_to_dec
    jmp .done
.es:
    ; d de mes de yyyy
    mov rdi, r15
    mov rsi, r12
    call u64_to_dec
    mov rdi, rax
    mov rsi, s_de
    mov edx, 4
    call mem_copy
    lea rcx, [r14-1]
    shl rcx, 4
    mov rdi, rax
    mov rsi, [month_es + rcx]
    mov rdx, [month_es + rcx + 8]
    call mem_copy
    mov rdi, rax
    mov rsi, s_de
    mov edx, 4
    call mem_copy
    mov rdi, r13
    mov rsi, rax
    call u64_to_dec
.done:
    pop r15
    pop r14
    pop r13
    pop r12
    ret

section .data

s_de: db ' de '

me1: db 'January'
me1_len equ $-me1
me2: db 'February'
me2_len equ $-me2
me3: db 'March'
me3_len equ $-me3
me4: db 'April'
me4_len equ $-me4
me5: db 'May'
me5_len equ $-me5
me6: db 'June'
me6_len equ $-me6
me7: db 'July'
me7_len equ $-me7
me8: db 'August'
me8_len equ $-me8
me9: db 'September'
me9_len equ $-me9
me10: db 'October'
me10_len equ $-me10
me11: db 'November'
me11_len equ $-me11
me12: db 'December'
me12_len equ $-me12

ms1: db 'enero'
ms1_len equ $-ms1
ms2: db 'febrero'
ms2_len equ $-ms2
ms3: db 'marzo'
ms3_len equ $-ms3
ms4: db 'abril'
ms4_len equ $-ms4
ms5: db 'mayo'
ms5_len equ $-ms5
ms6: db 'junio'
ms6_len equ $-ms6
ms7: db 'julio'
ms7_len equ $-ms7
ms8: db 'agosto'
ms8_len equ $-ms8
ms9: db 'septiembre'
ms9_len equ $-ms9
ms10: db 'octubre'
ms10_len equ $-ms10
ms11: db 'noviembre'
ms11_len equ $-ms11
ms12: db 'diciembre'
ms12_len equ $-ms12

align 8
month_en:
    dq me1, me1_len, me2, me2_len, me3, me3_len, me4, me4_len
    dq me5, me5_len, me6, me6_len, me7, me7_len, me8, me8_len
    dq me9, me9_len, me10, me10_len, me11, me11_len, me12, me12_len
month_es:
    dq ms1, ms1_len, ms2, ms2_len, ms3, ms3_len, ms4, ms4_len
    dq ms5, ms5_len, ms6, ms6_len, ms7, ms7_len, ms8, ms8_len
    dq ms9, ms9_len, ms10, ms10_len, ms11, ms11_len, ms12, ms12_len

; ---- string pairs: en first, then es ---------------------------------
; error messages carry their own paragraph so the templates render nothing
; when there is no error (V_ERR is a raw slot); braces group the parts
%define ERR_O '<p class="error" role="alert">'
%define ERR_C '</p>'
%define NOTE_O '<div class="notice" role="status">'
%define NOTE_C '</div>'

%macro STR 3                    ; label, en, es
%1_en: db %2
%1_en_len equ $-%1_en
%1_es: db %3
%1_es_len equ $-%1_es
%endmacro

STR t_home,     'home',            'inicio'
STR t_search,   'search',          'búsqueda'
STR t_admin,    'control panel',   'panel de control'
STR t_login,    'login',           'iniciar sesión'
STR t_editor,   'editor',          'editor'
STR t_settings, 'settings',        'configuración'
STR t_delete,   'delete post',     'eliminar entrada'
STR t_preview,  'preview',         'vista previa'
STR prevdate,   '(unsaved preview)', '(vista previa sin guardar)'
STR h_tag,      'posts tagged #',  'entradas con la etiqueta #'
STR h_search,   'search results for: ', 'resultados de búsqueda para: '
STR empty,      '<div class="notice">nothing here yet. check back soon!</div>', \
                '<div class="notice">todavía no hay nada por aquí. ¡vuelve pronto!</div>'
STR newer,      '&larr; newer',    '&larr; más recientes'
STR older,      'older &rarr;',    'más antiguas &rarr;'
STR pub,        '<span class="status pub">published</span>', '<span class="status pub">publicada</span>'
STR draft,      '<span class="status draft">draft</span>', '<span class="status draft">borrador</span>'
STR dellink,    'delete',          'eliminar'
STR e_wrong, {ERR_O, 'wrong password.', ERR_C}, \
                {ERR_O, 'contraseña incorrecta.', ERR_C}
STR e_wait, {ERR_O, 'too many attempts - wait a moment and try again.', ERR_C}, \
                {ERR_O, 'demasiados intentos: espera un momento y vuelve a intentarlo.', ERR_C}
STR e_nopw, {ERR_O, 'no admin password set. run: blogd init', ERR_C}, \
                {ERR_O, 'no hay contraseña de administrador. ejecuta: blogd init', ERR_C}
STR e_title, {ERR_O, 'title is required (1-256 characters).', ERR_C}, \
                {ERR_O, 'el título es obligatorio (1-256 caracteres).', ERR_C}
STR e_slug, {ERR_O, 'slug must be 1-128 chars of a-z, 0-9, dashes.', ERR_C}, \
                {ERR_O, 'el slug debe tener 1-128 caracteres: a-z, 0-9, guiones.', ERR_C}
STR e_slugdup, {ERR_O, 'that slug is already used by another post.', ERR_C}, \
                {ERR_O, 'ese slug ya lo usa otra entrada.', ERR_C}
STR e_tags, {ERR_O, 'tags too long (max 256 chars).', ERR_C}, \
                {ERR_O, 'etiquetas demasiado largas (máx. 256 caracteres).', ERR_C}
STR e_md, {ERR_O, 'markdown too large (max 32 KB).', ERR_C}, \
                {ERR_O, 'markdown demasiado grande (máx. 32 KB).', ERR_C}
STR e_save, {ERR_O, 'store write failed.', ERR_C}, \
                {ERR_O, 'error al escribir en el almacén.', ERR_C}
STR e_set, {ERR_O, 'check the fields: title 1-120 chars, posts per page 1-50.', ERR_C}, \
                {ERR_O, 'revisa los campos: título 1-120 caracteres, entradas por página 1-50.', ERR_C}
STR e_pw, {ERR_O, 'passwords must match and be at least 8 characters.', ERR_C}, \
                {ERR_O, 'las contraseñas deben coincidir y tener al menos 8 caracteres.', ERR_C}
STR d_home,     'Latest posts from ', 'Últimas entradas de '
STR d_tag,      'Posts tagged #',   'Entradas con la etiqueta #'
STR d_on,       ' on ',             ' en '
STR t_page,     ' · page ',         ' · página '
STR t_searchq,  'search: ',         'búsqueda: '
STR n_saved,    {NOTE_O, 'post published.', NOTE_C}, {NOTE_O, 'entrada publicada.', NOTE_C}
STR n_draft,    {NOTE_O, 'draft saved.', NOTE_C}, {NOTE_O, 'borrador guardado.', NOTE_C}
STR n_deleted,  {NOTE_O, 'post deleted.', NOTE_C}, {NOTE_O, 'entrada eliminada.', NOTE_C}
STR n_settings, {NOTE_O, 'settings saved.', NOTE_C}, {NOTE_O, 'configuración guardada.', NOTE_C}
STR t_media,    'media',           'imágenes'
STR t_mdelete,  'delete image',    'eliminar imagen'
STR n_uploaded, {NOTE_O, 'image uploaded. paste the snippet into a post.', NOTE_C}, \
                {NOTE_O, 'imagen subida. pega el fragmento en una entrada.', NOTE_C}
STR n_mdeleted, {NOTE_O, 'image deleted.', NOTE_C}, {NOTE_O, 'imagen eliminada.', NOTE_C}
STR e_uptype, {ERR_O, 'that file is not an image (PNG, JPEG, GIF, WebP, TIFF or HEIC).', ERR_C}, \
                {ERR_O, 'ese archivo no es una imagen (PNG, JPEG, GIF, WebP, TIFF o HEIC).', ERR_C}
STR e_upempty, {ERR_O, 'choose an image file first.', ERR_C}, \
                {ERR_O, 'primero elige un archivo de imagen.', ERR_C}
STR e_upconv, {ERR_O, 'the image could not be converted (see the server log).', ERR_C}, \
                {ERR_O, 'no se pudo convertir la imagen (revisa el registro del servidor).', ERR_C}
STR e_upstore, {ERR_O, 'store write failed.', ERR_C}, \
                {ERR_O, 'error al escribir en el almacén.', ERR_C}
STR e_upnoconv, {ERR_O, 'image uploads are disabled: no converter is installed (see the server log).', ERR_C}, \
                {ERR_O, 'la subida de imágenes está desactivada: no hay conversor instalado (revisa el registro del servidor).', ERR_C}
STR e_upfull, {ERR_O, 'the media library is full.', ERR_C}, \
                {ERR_O, 'la biblioteca de imágenes está llena.', ERR_C}
STR lb_open,    'view full size',  'ver a tamaño completo'
STR lb_close,   'close',           'cerrar'
STR e_imgmax, {ERR_O, 'image size must be 320 to 4096 pixels.', ERR_C}, \
                {ERR_O, 'el tamaño de imagen debe estar entre 320 y 4096 píxeles.', ERR_C}

%macro ROW 1
    dq %1_en, %1_en_len, %1_es, %1_es_len
%endmacro

align 8
i18n_tbl:                       ; indexed by S_* id (order must match i18n.inc)
    ROW t_home
    ROW t_search
    ROW t_admin
    ROW t_login
    ROW t_editor
    ROW t_settings
    ROW t_delete
    ROW t_preview
    ROW prevdate
    ROW h_tag
    ROW h_search
    ROW empty
    ROW newer
    ROW older
    ROW pub
    ROW draft
    ROW dellink
    ROW e_wrong
    ROW e_wait
    ROW e_nopw
    ROW e_title
    ROW e_slug
    ROW e_slugdup
    ROW e_tags
    ROW e_md
    ROW e_save
    ROW e_set
    ROW e_pw
    ROW d_home
    ROW d_tag
    ROW d_on
    ROW t_page
    ROW t_searchq
    ROW n_saved
    ROW n_draft
    ROW n_deleted
    ROW n_settings
    ROW t_media
    ROW t_mdelete
    ROW n_uploaded
    ROW n_mdeleted
    ROW e_uptype
    ROW e_upempty
    ROW e_upconv
    ROW e_upstore
    ROW e_upnoconv
    ROW e_upfull
    ROW lb_open
    ROW lb_close
    ROW e_imgmax

section .note.GNU-stack noalloc noexec nowrite progbits
