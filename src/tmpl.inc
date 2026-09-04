; tmpl.inc — template ids and value-registry ids shared between the
; template engine (tmpl.asm) and the page handlers (pages.asm/admin.asm).

; value registry (vals array = NVALS slots of (ptr,len), 16 bytes each)
%define V_SITE     0
%define V_TITLE    1
%define V_CONTENT  2
%define V_URL      3
%define V_DATE     4
%define V_TAGS     5
%define V_HTML     6
%define V_META     7            ; per-page <head> block (raw)
%define V_Q        8
%define V_HEADING  9
%define V_EXCERPT  10
%define V_ID       11
%define V_ETITLE   12
%define V_ESLUG    13
%define V_ETAGS    14
%define V_EMD      15
%define V_CSRF     16
%define V_ERR      17
%define V_ROWS     18
%define V_ESITE    19
%define V_EPPP     20
%define V_BANNER   21
%define V_EBANNER  22
%define V_THEME    23
%define V_SELRETRO 24           ; theme radios: V_SELRETRO + theme id
%define V_SELSUCRE 25
%define V_SELMDE   26           ; Medellín
%define V_SELBOG   27           ; Bogotá
%define V_SELLPB   28           ; La Paz
%define V_SELCBB   29           ; Cochabamba
%define V_SELSRZ   30           ; Santa Cruz de la Sierra
%define V_SELPGH   31           ; Pittsburgh
%define V_SELEN    32
%define V_SELES    33
%define V_CSSV     34           ; stylesheet version (crc32c of main.css)
%define V_EURL     35           ; site url in the settings form
%define V_THCOLOR  36           ; <meta name="theme-color"> for the theme
%define NVALS      37

; locales: templates/<dir>/ sets, selected site-wide by [set_locale]
%define LOC_EN     0
%define LOC_ES     1
%define NLOCALES   2

; markers whose values are emitted raw (already-safe HTML we generated)
%define RAW_MASK   ((1<<V_CONTENT)|(1<<V_TAGS)|(1<<V_HTML)|(1<<V_ROWS)|(1<<V_META))

%define T_SHELL    0
%define T_CARD     1
%define T_POST     2
%define T_LISTHEAD 3
%define T_ALOGIN   4
%define T_ADASH    5
%define T_AEDIT    6
%define T_ASET     7
%define T_ACONF    8
%define NTMPL      9
