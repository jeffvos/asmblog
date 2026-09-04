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
%define V_COUNT    7
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
%define V_SELRETRO 24
%define V_SELSUCRE 25
%define NVALS      26

; markers whose values are emitted raw (already-safe HTML we generated)
%define RAW_MASK   ((1<<V_CONTENT)|(1<<V_TAGS)|(1<<V_HTML)|(1<<V_ROWS))

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
