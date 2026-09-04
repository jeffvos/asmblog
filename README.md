# asmblog / blogd

A single-user blogging platform — admin panel, tags, search, pagination,
retro-chic Tailwind frontend — implemented as a multi-threaded HTTP server
in hand-written x86_64 Linux assembly (NASM, raw syscalls, no libc).
libsodium is linked solely for Argon2id password hashing. TLS is terminated
by a reverse proxy in front; `blogd` binds 127.0.0.1 only.

See [PLAN.md](PLAN.md) for the full architecture.

## Build & run

```
make            # nasm + ld -> build/blogd, tailwind -> static/main.css
make run        # serve on http://127.0.0.1:8080
make test       # smoke suite (store selftest + HTTP + content + admin)
make fuzz       # mutation-fuzz the HTTP and markdown parsers
./build/blogd init       # first-run setup (title, posts/page, admin password)
./build/blogd seed       # demo posts for development
./build/blogd 9000 8     # custom port + thread count
```

Deployment configs (TLS reverse proxy + hardened systemd unit) live in
[deploy/](deploy/). blogd installs its own seccomp syscall allowlist at
startup; set `BLOGD_NO_SECCOMP=1` to disable it if a kernel needs a
different set.

The admin panel lives at `/admin` (log in with the password set by
`blogd init`). It offers a post dashboard, a markdown editor with live
preview and draft/publish, delete-with-confirm, and a settings page for
the site title, posts-per-page, the scrolling banner message, the theme,
and the password.

### Themes

Two themes ship, selectable in **/admin/settings** and applied via a
class on `<body>` (both palettes are compiled into the single
stylesheet, so switching is instant and needs no rebuild):

- **Retro** (default) — polished 1990s web: navy backdrop, beveled
  silver panels, monospace, a scrolling marquee, a green-LED hit counter.
- **Sucre** — a modern take on the whitewashed colonial architecture of
  Sucre, Bolivia (*La Ciudad Blanca*): warm plaster background, panels as
  white "walls" under terracotta rooflines, colonial-green links, ochre
  accents, and serif display type. The banner becomes a quiet engraved
  lintel rather than a marquee.

Templates use semantic classes (`.masthead`, `.card`, `.btn`, `.tag`, …)
that each theme restyles under a `.theme-retro` / `.theme-sucre` scope in
[assets/input.css](assets/input.css).

### Embedding Flickr photos

Paste a Flickr "embed" snippet as its own line in a post's markdown:

```
<a data-flickr-embed="true" href="https://www.flickr.com/photos/.../"><img src="https://live.staticflickr.com/.../..._b.jpg" alt="..."/></a><script async src="//embedr.flickr.com/assets/client-code.js"></script>
```

blogd extracts only the photo-page link and the image URL, verifies both
are genuine Flickr hosts, and re-emits a **static, script-free** figure —
the `<script>` is discarded and nothing is stored or proxied locally
(the browser loads the image straight from Flickr's CDN, permitted by a
narrow `img-src` CSP allowance). A snippet whose hosts don't match
Flickr is left as escaped text, never rendered as a live tag. This is
the only remote content the app allows, and it never relaxes
`script-src 'none'`.

Requires: `nasm`, GNU binutils, `libsodium-dev`, `curl` (tests only), and
the Tailwind standalone CLI at `tools/tailwindcss` (gitignored; download
`tailwindcss-linux-x64` from the Tailwind GitHub releases and `chmod +x`).

## Roadmap

- [x] Milestone 1 — single-threaded skeleton: syscall layer, arena allocator,
      HTTP/1.1 parser, `/`, `/health`, 400/404/405
- [x] Milestone 2 — concurrency: `clone()` worker pool, `SO_REUSEPORT`,
      per-worker epoll, keep-alive, futex rwlock
- [x] Milestone 3 — storage: append-only record log + indexes, `blogd init`,
      `blogd selftest`, Argon2id via libsodium (the binary's one dynamic dep)
- [x] Milestone 4 — public site: {{marker}} template engine, Tailwind
      retro-chic frontend, pagination, tags, case-insensitive search,
      Atom feed, gzip static serving, visitor counter, `blogd seed`
- [x] Milestone 5 — admin: Argon2id login (via a main-thread crypto
      mailbox), server-side sessions, CSRF tokens, post CRUD with
      draft/publish, markdown-subset renderer, live preview, settings
- [x] Milestone 6 — hardening: seccomp syscall allowlist (with a worker
      readiness barrier + `BLOGD_NO_SECCOMP` escape hatch), security
      headers on every response, mutation fuzzing of both parsers,
      load test, and reverse-proxy + systemd deploy configs

## Code conventions

- System V AMD64 calling convention between functions; syscall args in
  rdi/rsi/rdx/r10/r8/r9.
- All strings are (pointer, length) pairs. No NUL-scanning of untrusted data.
- Per-connection bump arenas instead of a heap: `arena_reset` at the start of
  each request makes use-after-free structurally impossible in request code.
- Every source file declares a non-executable stack; the binary links with
  `-z noexecstack -z relro`.
