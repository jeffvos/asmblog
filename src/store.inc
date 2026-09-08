; store.inc — on-disk record layout and in-memory post structures.
;
; File: data/store.blg
;   16-byte file header: 'BLG1' | version dword | 8 reserved bytes
;   then a sequence of records, each 8-byte aligned:
;
; Record header (64 bytes) + payload (title|slug|tags|md|html concatenated):
%define R_MAGIC     0           ; dword 'REC1'
%define R_TYPE      4           ; dword: 1 post, 2 settings
%define R_ID        8           ; qword (settings: 0)
%define R_FLAGS     16          ; qword
%define R_CREATED   24          ; qword unix seconds
%define R_UPDATED   32          ; qword
%define R_TLEN      40          ; dword title len   (settings: whole payload)
%define R_SLEN      44          ; dword slug len
%define R_GLEN      48          ; dword tags len (comma-separated)
%define R_MLEN      52          ; dword markdown len
%define R_HLEN      56          ; dword rendered html len
%define R_CRC       60          ; dword crc32c of payload
%define R_HDR       64

%define TYPE_POST       1
%define TYPE_SETTINGS   2
%define TYPE_MEDIA      3
%define FLAG_PUBLISHED  1
%define FLAG_TOMBSTONE  2

; Media payload (TYPE_MEDIA): R_ID is the media id (its own sequence,
; next_mid); R_TLEN = MD_HDR (the fixed part), R_SLEN = name length,
; the other lengths 0:
;   dword w, h            full rendition (<= the max-size setting)
;   dword sw, sh          inline rendition (0,0 = none: the full one serves)
;   dword b_webp, b_png   file sizes of the full renditions
;   dword b_swebp, b_spng file sizes of the inline renditions
;   name                  original filename, sanitised (<= 120 bytes)
; The image bytes live in data/media/<id>.webp, <id>.png, <id>-s.webp,
; <id>-s.png (media.asm); a media record only describes them.
%define MD_HDR      32

; Settings payload: dword posts_per_page | dword session_ttl |
;   dword title_len | dword banner_len | dword theme | dword locale |
;   dword hash_len(128) | title | banner | hash[128]
;   | dword url_len | url            (extension; absent in older records)
;   | dword imgmax                   (extension 2: the longest edge an
;                                     uploaded image is resized to)
; theme, locale, hash and url come from the [set_theme]/[set_locale]/
; [set_hash]/[set_url] globals at write time (not passed as args):
; callers stage them first (settings_set_url validates the url).
%define SET_HDR 28                 ; fixed prefix before the strings

; themes: 0 retro, 1 sucre, 2 medellin, 3 bogota, 4 lapaz, 5 cochabamba,
; 6 santacruz, 7 pittsburgh — the table with names and colours lives in
; pages.asm
%define NTHEMES 8

; In-memory post struct (128 bytes, allocated from the store arena;
; string pointers point either into the loaded file image or into
; arena copies made at append time — both live as long as the arena):
%define P_ID        0
%define P_FLAGS     8
%define P_CREATED   16
%define P_UPDATED   24
%define P_TITLE_P   32
%define P_TITLE_L   40
%define P_SLUG_P    48
%define P_SLUG_L    56
%define P_TAGS_P    64
%define P_TAGS_L    72
%define P_MD_P      80
%define P_MD_L      88
%define P_HTML_P    96
%define P_HTML_L    104
%define P_EXC_P     112         ; plain-text excerpt, derived once at
%define P_EXC_L     120         ; load/save time (cards, feed, meta)
%define P_SIZE      128

%define EXC_CAP     180         ; excerpt cap; buffers hold EXC_CAP + 3
; Append spec passed to store_append_post (96 bytes, caller-owned):
%define S_ID        0           ; 0 = assign new id
%define S_FLAGS     8
%define S_TITLE_P   16          ; the five (ptr,len) pairs mirror P_* order
%define S_TITLE_L   24
%define S_SLUG_P    32
%define S_SLUG_L    40
%define S_TAGS_P    48
%define S_TAGS_L    56
%define S_MD_P      64
%define S_MD_L      72
%define S_HTML_P    80
%define S_HTML_L    88
%define S_SIZE      96

%define MAX_POSTS   4096
%define MAX_MEDIA   4096

; In-memory media struct (64 bytes, store arena), newest first in
; [media_arr]; M_NAME_P points into the file image or an arena copy.
%define M_ID        0
%define M_CREATED   8
%define M_W         16          ; dwords, in payload order (copied as one
%define M_H         20          ;   32-byte block from/to the record)
%define M_SW        24
%define M_SH        28
%define M_BWEBP     32
%define M_BPNG      36
%define M_BSWEBP    40
%define M_BSPNG     44
%define M_NAME_P    48
%define M_NAME_L    56
%define M_SIZE      64

; image size setting: longest edge of the full rendition, pixels
%define IMGMAX_DEF  1600
%define IMGMAX_MIN  320
%define IMGMAX_MAX  4096
%define MEDIA_NAME_MAX 120
%define COMPACT_MIN 65536       ; auto-compact only files past this size
