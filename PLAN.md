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
| `util` | mmap arena allocator, ptr+len strings, HTML escaper, dates |

## Threading

N workers (default = cores) via `clone(CLONE_VM|CLONE_THREAD|...)`, each with
its own mmap'd stack + guard page. Each worker owns a listening socket with
`SO_REUSEPORT` and an independent nonblocking epoll loop — no accept lock, no
queue. Store guarded by a futex-based rwlock; public site takes only the read
side.

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
markdown at save time (zero parse cost at serve time). Settings record: site
title, posts_per_page (default 5, clamp 1-50, admin-editable), session TTL,
Argon2id hash. Search: case-insensitive SSE2 memmem over title+content.

## HTTP surface

Public: `/`, `/page/N`, `/post/{slug}`, `/tag/{tag}` (paginated), `/search?q=`,
`/feed.xml` (RSS), `/static/*` (pre-gzipped at build time).
Admin: login/logout, dashboard (drafts + published), new/edit/save
(draft|publish), preview (render without save), delete, settings
(posts-per-page, site title, password change).
Parser accepts only well-formed HTTP/1.1 GET/POST/HEAD with Content-Length
bodies; keep-alive supported; everything else 400.

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
