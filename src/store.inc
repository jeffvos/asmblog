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
%define FLAG_PUBLISHED  1
%define FLAG_TOMBSTONE  2

; Settings payload: dword posts_per_page | dword session_ttl |
;                   dword title_len | dword hash_len(128) | title | hash[128]

; In-memory post struct (112 bytes, allocated from the store arena;
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
%define P_SIZE      112

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
