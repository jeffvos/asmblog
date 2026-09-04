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
;   +34  gzip        byte    client sent Accept-Encoding: gzip?
;   +36  nreq        dword   requests served on this connection
;   +40  next        qword   freelist link
;   +48  out_start   qword   response begins at outbuf+out_start (dynamic
;                            pages render the body first at CTX_BODY_OFF,
;                            then write headers immediately before it)
;   +64  inbuf       (request head <= 8 KiB + body <= 100 KB)
;   +131136 outbuf

%define CTX_FD        0
%define CTX_IN_USED   8
%define CTX_OUT_LEN   16
%define CTX_OUT_SENT  24
%define CTX_KEEP      32
%define CTX_ARMED     33
%define CTX_GZIP      34
%define CTX_NREQ      36
%define CTX_NEXT      40
%define CTX_OUT_START 48
%define CTX_IN        64
%define CTX_INBUF_SZ  131072
%define CTX_OUT       131136
%define CTX_OUTBUF_SZ 524288

%define HTTP_HEAD_MAX 8192      ; request line + headers
%define HTTP_BODY_MAX 100000    ; Content-Length cap

; Regions within outbuf:
;   [0, 512)                 headers land right-aligned against the body
;   [BODY, BODY_END)         final response body (shell + content)
;   [SCRATCH, SCRATCH_END)   content scratch (inner templates render here,
;                            the shell splices it via {{content}})
;   [DECODE, DECODE_END)     decoded form fields (admin POSTs)
;   [MDHTML, MDHTML_END)     rendered markdown / dashboard rows
%define CTX_BODY_OFF     512
%define CTX_BODY_END     229376
%define CTX_SCRATCH_OFF  229376
%define CTX_SCRATCH_END  360448
%define CTX_DECODE_OFF   360448
%define CTX_DECODE_END   425984
%define CTX_MDHTML_OFF   425984
%define CTX_MDHTML_END   524288

%define CTX_TOTAL     659456    ; 131136 + 524288, rounded up to pages

%define MAX_REQS_PER_CONN 200
%define MD_MAX 32768            ; markdown source cap per post
