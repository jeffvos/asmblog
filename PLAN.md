# blogd — architecture plan

Single-user blogging platform in x86_64 Linux assembly (NASM, raw syscalls,
no libc). Locked decisions: libsodium linked solely for Argon2id password
hashing; TLS terminated by a reverse proxy (blogd binds 127.0.0.1, plain
HTTP); custom append-only binary store; posts authored in a Markdown subset.

## Modules

| Module | Responsibility |
|---|---|
| `main`/`init` | `_start`, CLI parsing, first-run setup, lifecycle |
| `net`/`threads` | sockets, `clone()` worker pool, per-worker epoll loops |
| `http` | strict HTTP/1.1 parser, router, response writer |
| `store` | append-only record log, indexes, futex rwlock |
| `md` | Markdown-subset -> HTML renderer |
| `tmpl` | template loading and scatter-gather rendering |
| `auth` | sessions, CSRF, login rate limiting, libsodium shim |
| `media` | image uploads: spool, multipart, the conversion helper process, renditions on disk, `/media/` serving |
| `util` | mmap arena allocator, ptr+len strings, HTML escaper, dates |

## Threading

N workers (default = cores) via `clone(CLONE_VM|CLONE_THREAD|...)`, each with
its own mmap'd stack + guard page. Each worker owns a listening socket with
`SO_REUSEPORT` (`TCP_NODELAY` set there and inherited by every accepted
socket) and an independent nonblocking epoll loop — no accept lock, no
queue. Store guarded by a futex-based rwlock; public site takes only the read
side. The lock is one 32-bit word: writer bit, waiters bit, reader count.
A waiter sets the waiters bit (cmpxchg) before `FUTEX_WAIT`, and an unlock
calls `FUTEX_WAKE` only when the value it replaced carried that bit, so the
uncontended path is one locked instruction each way and no syscall.

The epoll loop is level-triggered. A read that comes back short means the
socket is drained, so the worker parses straight away rather than paying
for one more `read()` returning EAGAIN; pipelined requests already in the
buffer are answered back to back. One `time()` per wakeup stamps every
connection touched (idle sweep and the `Date` header alike); a keep-alive
connection serves up to 1000 requests before it is closed.

## Memory

No heap. Per-connection bump arenas (one mmap slab, reset per request) —
structurally eliminates UAF/double-free in request handling. All strings are
pointer+length. Limits: 2 KB request line, 8 KB headers, 1 MB body.

## Storage

`data/store.blg`: append-only records — magic | type | id | flags
(draft/published/tombstone) | timestamps | section lengths | payload | crc32c
(hardware crc32). Updates append a new version; deletes append tombstones;
fsync per write. Compaction at startup/on demand via write-temp + rename.
Startup builds in-memory indexes: date-sorted published list (pagination =
array slice), slug hash table, tag -> posts. Rendered HTML stored alongside
markdown at save time (zero parse cost at serve time); the plain-text
excerpt is derived once per load/save the same way. Compaction runs at
startup once dead records dominate, or via `blogd compact`. Settings record: site
title, posts_per_page (default 5, clamp 1-50, admin-editable), session TTL,
Argon2id hash, site URL, image size (320-4096 px). Media records
(`TYPE_MEDIA`, their own id sequence) describe an uploaded image —
dimensions of the full and inline renditions, byte sizes, original
filename — while the bytes live as files in `data/media/` (`<id>.webp`,
`<id>.png`, `<id>-s.webp`, `<id>-s.png`); a delete is a tombstone plus
unlinks, and a startup sweep removes files no live record claims. Every list page (home, tag, search) makes one filter pass
over the date-sorted index, collecting the indices of matching posts into a
stack array; the requested page is a slice of that array. Search matches
title+markdown with a case-insensitive substring scan: the first needle
byte is hunted 16 bytes at a time with SSE2 (both case forms), and only a
candidate position pays for the byte-wise compare of the rest.

## HTTP surface

Public: `/`, `/page/N`, `/post/{slug}`, `/tag/{tag}` (paginated), `/search?q=`,
`/feed.xml` (RSS), `/static/*` (pre-gzipped at build time), `/media/<id>[-s].(webp|png)`
(uploaded images, served from a file mapping after the headers, strong
ETag, immutable).
Admin: login/logout, dashboard (drafts + published), new/edit/save
(draft|publish), preview (render without save), delete, settings
(posts-per-page, site title, image size, password change), media
(library, multipart upload, delete-with-confirm). A save, delete or settings
change redirects to `/admin?saved=1` (`draft`, `deleted`, `settings`) and
the dashboard renders the matching localised notice; error and notice
strings carry their own `<p class="error">`/`<div class="notice">`
wrappers so an empty message renders nothing. Preview puts the rendered
draft above a re-rendered editor with the submitted fields intact, so
there is a way back without a script.
Parser accepts only well-formed HTTP/1.1 GET/POST/HEAD with Content-Length
bodies; keep-alive supported; malformed 400, oversized 413/431, chunked
411. A body over the 100 KB buffer is accepted only for `POST /admin/media`
with a live session and up to 32 MB: it streams into `data/media/up-<n>.tmp`
through the idle outbuf and the handler maps that file. Idle connections are swept by a per-worker timerfd. Repeat requests
for an unchanged page are served from a render cache shared by all workers:
64 direct-mapped slots keyed by the page's weak ETag plus host, scheme and
request target (bodies up to 64 KB). Lookups are lock-free — each slot
carries a seqlock counter that a reader checks after copying the body, so a
racing store simply turns the hit into a miss — and only a store (once per
miss) takes the cache's writer lock. A page served from the cache is flagged
on the connection so `finish_page` does not store it back.

## Security

- Argon2id via libsodium (constant-time verify); per-IP + global exponential
  backoff on failed logins.
- Sessions: 32-byte getrandom tokens, server-side store with expiry; cookie
  HttpOnly; Secure; SameSite=Strict.
- CSRF token per session in every admin form, verified on every POST.
- One canonical HTML-escape routine for all dynamic output; markdown renderer
  escapes by default, link schemes allowlisted (http/https/mailto/relative).
- Post-setup seccomp BPF allowlist (~20 syscalls) via seccomp(2); systemd unit
  with NoNewPrivileges, ProtectSystem=strict, data dir sole writable path.
- Image conversion never runs inside the sandbox: a helper process forked
  before the workers (and before the filter) takes jobs over a socketpair,
  fork+execs `tools/imgconv` (vipsthumbnail / ImageMagick / Pillow) with
  no inherited descriptors, and reports the exit status. The server itself
  never gains `execve`.
- CSP default-src 'self', X-Content-Type-Options, Referrer-Policy on every
  response. Non-executable stack/heap.

## Frontend

Tailwind standalone CLI at build time only -> one purged, pre-gzipped
stylesheet. Templates: HTML with `{{marker}}` placeholders, split at startup
into static segments; rendering is scatter-gather of chunks + escaped values.
Retro-chic: local pixel display font, beveled 3D borders, blue/purple
link/visited colors, tiled SVG background, 88x31 badge, webring footer, CSS
marquee (respects prefers-reduced-motion), real visitor counter (atomic
increment, odometer digits). Semantic HTML, responsive, dark mode, accessible
contrast.

Themes are structurally distinct (shape, type, texture, a landmark skyline
drawn as an inline SVG mask; see the conventions comment at the top of
`assets/input.css`). The admin panel shares one theme-agnostic layer at the
end of that file: button hierarchy (primary / secondary / danger / quiet),
focus rings, a monospace editor, fieldset grouping, status badges and a
two-line dashboard row under 40rem. Each theme feeds it through `--a-*`
tokens in both colour schemes, and `tools/contrast.py` checks every token
pair at AA, so a theme cannot ship an unreadable control panel.

## Testing

pytest integration suite over real HTTP (auth, CSRF, pagination, search,
crash recovery); AFL++ fuzz harnesses for HTTP + markdown parsers; Valgrind.

## Milestones

1. **Skeleton** — syscall layer, arena allocator, string utils,
   single-threaded HTTP. *(done)*
2. **Concurrency** — clone() workers, SO_REUSEPORT + epoll, keep-alive,
   futex rwlock.
3. **Store** — record log, indexes, crash-safe compaction, `blogd init`.
4. **Public site** — templates + Tailwind, pagination, tags, search, RSS.
5. **Admin** — sessions/CSRF, CRUD, markdown parser + preview, settings.
6. **Hardening & ship** — seccomp, rate limiting, fuzzing, load test,
   proxy + systemd deployment.
7. **The modern web** — metadata, validators, icons, richer markdown.
8. **Own the pictures** — uploads streamed to disk, conversion helper,
   WebP + PNG at two sizes, media records, `<picture>` + CSS lightbox,
   media library.
