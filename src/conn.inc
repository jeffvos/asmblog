; conn.inc — per-connection context layout (one mmap'd block per connection,
; recycled through a per-worker freelist; workers never share contexts, so
; no locking is needed on any of these fields).
;
;   +0   fd          dword
;   +8   in_used     qword   bytes buffered in inbuf
;   +16  out_len     qword   total bytes of the pending response
;   +24  out_sent    qword   bytes of it already written
;   +32  keep        byte    keep-alive after current response?
;   +33  armed_out   byte    is EPOLLOUT currently subscribed?
;   +34  gzip        byte    bit0: client accepts gzip, bit1: br
;   +35  head        byte    HEAD request: send headers only
;   +36  nreq        dword   requests served on this connection
;   +40  next        qword   freelist link
;   +48  out_start   qword   response begins at outbuf+out_start (dynamic
;                            pages render the body first at CTX_BODY_OFF,
;                            then write headers immediately before it)
;   +56  hlen        qword   request head length (late header scans)
;   +64  host_p/l    qword   validated Host header value (l = 0: none)
;   +80  lm          qword   Last-Modified unix seconds (0: none)
;   +88  etag        32 B    ETag token for this response (see etag_l)
;   +120 etag_l      byte    0 = no ETag
;   +121 cache       byte    Cache-Control mode (CACHE_* below)
;   +122 https       byte    X-Forwarded-Proto said https
;   +123 inm         byte    If-None-Match matched etag → 304 eligible
;   +128 inbuf       (request head <= 8 KiB + body <= 100 KB)
;   +131200 outbuf

%define CTX_FD        0
%define CTX_IN_USED   8
%define CTX_OUT_LEN   16
%define CTX_OUT_SENT  24
%define CTX_KEEP      32
%define CTX_ARMED     33
%define CTX_GZIP      34
%define CTX_HEAD      35
%define CTX_NREQ      36
%define CTX_NEXT      40
%define CTX_OUT_START 48
%define CTX_HLEN      56
%define CTX_HOST_P    64
%define CTX_HOST_L    72
%define CTX_LM        80
%define CTX_ETAG      88
%define CTX_ETAG_L    120
%define CTX_CACHE     121
%define CTX_HTTPS     122
%define CTX_INM       123
%define CTX_IN        128
%define CTX_INBUF_SZ  131072
%define CTX_OUT       131200
%define CTX_OUTBUF_SZ 524288

; Cache-Control modes (CTX_CACHE); the header text lives in pages.asm
%define CACHE_NONE       0      ; no Cache-Control header
%define CACHE_REVALIDATE 1      ; public, max-age=0, must-revalidate (HTML)
%define CACHE_IMMUTABLE  2      ; public, max-age=31536000, immutable (versioned static)
%define CACHE_NOSTORE    3      ; no-store (admin, counter, redirects)
%define CACHE_FEED       4      ; public, max-age=300
%define CACHE_DAY        5      ; public, max-age=86400 (icons, manifest)
%define CACHE_HOUR       6      ; public, max-age=3600 (unversioned static)

%define HTTP_HEAD_MAX 8192      ; request line + headers
%define HTTP_BODY_MAX 100000    ; Content-Length cap

; Regions within outbuf:
;   [0, 1024)                headers land right-aligned against the body
;   [BODY, BODY_END)         final response body (shell + content)
;   [SCRATCH, SCRATCH_END)   content scratch (inner templates render here,
;                            the shell splices it via {{content}})
;   [DECODE, DECODE_END)     decoded form fields (admin POSTs)
;   [MDHTML, MDHTML_END)     rendered markdown / dashboard rows
%define CTX_BODY_OFF     1024
%define CTX_BODY_END     229376
%define CTX_SCRATCH_OFF  229376
%define CTX_SCRATCH_END  360448
%define CTX_DECODE_OFF   360448
%define CTX_DECODE_END   425984
%define CTX_MDHTML_OFF   425984
%define CTX_MDHTML_END   524288

%define CTX_TOTAL     659456    ; 131200 + 524288, rounded up to pages

%define MAX_REQS_PER_CONN 200
%define MD_MAX 32768            ; markdown source cap per post
