# asmblog / blogd

A single-user blogging platform — admin panel, tags, search, pagination,
retro-chic Tailwind frontend — implemented as a multi-threaded HTTP server
in hand-written x86_64 Linux assembly (NASM, raw syscalls, no libc).
libsodium is linked solely for Argon2id password hashing. TLS is terminated
by a reverse proxy in front; `blogd` binds 127.0.0.1 only.

It is also a well-behaved citizen of the modern web: every page carries
description/canonical/Open Graph/JSON-LD metadata for crawlers and link
previews, validators (`ETag`, `Last-Modified`) let clients and proxies
revalidate with 304s that cost no render, and there is a sitemap, a
robots.txt, an Atom feed with full content, a web app manifest and an
icon set — all emitted by the server, still with zero JavaScript.

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
different set. blogd binds `127.0.0.1` unless `BLOGD_BIND_ALL=1` is set
(containers).

## Docker

A minimal Alpine image (the binary, templates, stylesheet, libsodium,
busybox — no reverse proxy) is built and published by
[GitHub Actions](.github/workflows/ci.yml) to `ghcr.io/<owner>/blogd`
on every push to `main` and every `v*` tag. The Docker build is also the
musl test gate: it runs the selftest and a real login through the
seccomp sandbox before the runtime stage is assembled.

```bash
docker run -d --name blogd -p 8080:8080 \
  -e BLOGD_ADMIN_PASSWORD='a-long-password' \
  -v blogd-data:/var/lib/blogd/data \
  ghcr.io/<owner>/blogd:latest
```

On first boot the entrypoint initializes the store in the volume with
`BLOGD_ADMIN_PASSWORD` (stored only as an Argon2id hash — never in an
image layer); later boots just serve. Terminate TLS with Caddy/nginx in
front of the container. Environment:

| variable | default | purpose |
|---|---|---|
| `BLOGD_ADMIN_PASSWORD` | `changeme-blogd` | admin password on first boot (min 8 chars) |
| `BLOGD_SITE_TITLE` | `My Retro Blog` | site title on first boot |
| `BLOGD_POSTS_PER_PAGE` | `5` | posts per page on first boot |
| `BLOGD_SITE_URL` | *(unset)* | public origin, e.g. `https://blog.example.com` (also editable in `/admin/settings`) |
| `BLOGD_SEED` | `0` | `1` seeds demo posts on first boot |
| `BLOGD_THREADS` | `2` | worker threads |
| `BLOGD_PORT` | `8080` | listen port inside the container |

CI's container smoke test logs in with the `BLOGD_ADMIN_PASSWORD`
repository secret (falling back to the default). `make image` builds
the image locally.

The admin panel lives at `/admin` (log in with the password set by
`blogd init`). It offers a post dashboard, a markdown editor with live
preview and draft/publish, delete-with-confirm, and a settings page for
the site title, posts-per-page, the scrolling banner message, the theme,
the language, the public site URL, and the password.

### SEO, link previews and caching

Everything below is rendered by the server at request time; there is no
client-side code involved.

- **`<head>` metadata on every public page**: `meta description` (the
  post's excerpt, or "Latest posts from …"), `rel=canonical`,
  `rel=prev/next` on paginated lists, Open Graph (`og:title`,
  `og:description`, `og:url`, `og:image`, `og:site_name`, `og:locale`,
  `article:published_time`/`modified_time`/`tag`), a Twitter card, and
  JSON-LD (`BlogPosting` on posts, `WebSite` + `SearchAction` on the
  front page). JSON-LD is a data block, not a script, so the CSP's
  `script-src 'none'` — and the "0 BYTES OF JS" badge — still hold.
  Search results are `noindex,follow`; the admin panel is `noindex`.
- **`og:image`** is the first Flickr photo in the post, else
  `/static/og.png` (regenerate the icon set with `make icons`, which
  needs only Python's standard library).
- **Absolute URLs** (canonical, Open Graph, the feed's links, the
  sitemap) come from the **site URL** setting. When it is blank, blogd
  derives them from the request's `Host` and `X-Forwarded-Proto`, which
  both shipped proxy configs forward; when neither is known the
  absolute-URL tags are simply omitted.
- **`/robots.txt`** (disallows `/admin`, `/search`, `/hits.svg`, links
  the sitemap), **`/sitemap.xml`** (every published post with `lastmod`;
  a sitemap index of `/sitemap-N.xml` slices past 500 posts),
  **`/manifest.webmanifest`** (named after the site), `/favicon.ico`,
  `/static/favicon.svg`, `/static/icon-192.png`, `/static/icon-512.png`.
- **One URL per page**: trailing slashes, `/page/1` and `/tag/x/page/1`
  301 to the canonical form.
- **Validators**: HTML, the feed, the sitemap and `robots.txt` carry a
  weak `ETag` (`W/"<store generation>-<crc32c of host+path+query>"`)
  and `Last-Modified`; static assets carry a strong `ETag`. The
  generation changes on every write and every restart (templates and
  CSS load at boot), so an `If-None-Match` hit is answered with a 304
  before anything is rendered. Pages are `public, max-age=0,
  must-revalidate`; the feed is cacheable for five minutes; the versioned
  stylesheet (`/static/main.css?v=<crc>`) is `immutable` for a year;
  icons for a day; `/admin` and the counter are `no-store`.
- **`HEAD`** is supported everywhere; `Date`, `Content-Language`,
  `Vary: Accept-Encoding` (on negotiated assets) and `Allow` (on 405)
  are emitted; `Accept-Encoding` is tokenised (`;q=0` is honoured, and a
  `static/main.css.br` is served to clients that accept brotli when the
  `brotli` CLI was available at build time).
- **Atom feed**: absolute links, `<author>`, `<published>`,
  `<category>` per tag, `<summary type="text">` plus
  `<content type="html">` for posts up to 16 KB, `xml:lang`, and
  `<updated>` from the store rather than the clock. Entry ids are the
  stable `tag:blogd:post-N` URIs, so configuring the site URL later
  never duplicates entries in readers.
- **Visitor counter**: the footer shows `/hits.svg`, a tiny `no-store`
  SVG the server renders per view, so the HTML itself stays byte-stable
  and cacheable. The count persists across restarts in
  `data/hits.blg`, a 4 KiB `MAP_SHARED` page that the kernel writes back
  by itself — bumping it is one `lock xadd`, no syscall. Crawlers
  fetching HTML no longer count; browsers loading the image do.

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

The favicon, touch icons and the `og:image` card follow the theme too:
`tools/mkicons.py` draws a set per theme (`static/favicon.*`,
`static/sucre-favicon.*`, …) and the server serves whichever matches
the active theme, with a `?v=theme-…` token on the URLs so browsers and
link unfurlers refetch after a switch.

Templates use semantic classes (`.masthead`, `.card`, `.btn`, `.tag`, …)
that each theme restyles under a `.theme-retro` / `.theme-sucre` scope in
[assets/input.css](assets/input.css). Sucre follows
`prefers-color-scheme: dark`; both themes respect
`prefers-reduced-motion`, have a print stylesheet, and use cross-document
view transitions for page-to-page navigation where the browser supports
them (no script involved).

### Localization

The site language is a site-wide setting in **/admin/settings** (not
per visitor). Two locales ship: **en-US** (default) and **es-BO**.

- All template text lives in per-locale template sets:
  [templates/en/](templates/en/) and [templates/es/](templates/es/). Both
  sets load at startup; the active one is chosen per render. Adding a
  locale is a new directory plus one row per string in `src/i18n.asm`.
- Strings the assembly emits itself (page titles, list headings, pager
  labels, dashboard status, error messages) come from the string table
  in [src/i18n.asm](src/i18n.asm), and dates render in the locale's
  long form (`September 4, 2026` / `4 de septiembre de 2026`).
- The Atom feed keeps RFC 3339 timestamps regardless of locale.

### Markdown

The renderer supports `#`/`##`/`###` headings (each gets an `id` slug,
so sections are deep-linkable), fenced code blocks with an optional
language (```` ```rust ```` becomes `<pre><code class="language-rust">`),
blockquotes, lists, `---`, `**strong**`, `*em*`, `` `code` ``,
`[text](url)` links and `![alt](url)` images. Image URLs are limited to
what the Content-Security-Policy lets the browser load anyway:
site-relative paths and `https://live.staticflickr.com/…`; anything
else is rendered as text. An image alone on a line becomes a
`<figure>`. Images get `loading="lazy"` and `decoding="async"`; Flickr
URLs do not encode dimensions, so no `width`/`height` is emitted.

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

Requires: `nasm`, GNU binutils, `libsodium-dev`, `curl` and `python3`
(tests only), and the Tailwind standalone CLI at
`tools/tailwindcss` (gitignored; download `tailwindcss-linux-x64` from the
Tailwind GitHub releases and `chmod +x`). Optional: `brotli` (a `.br`
sibling of the stylesheet is produced when present).

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
- [x] Milestone 7 — the modern web: `<head>` metadata / Open Graph /
      JSON-LD, robots + sitemap + manifest + icons, ETag/304 validators
      and cache policy, HEAD, canonical redirects, richer Atom, markdown
      images/anchors/code classes, persistent visitor counter

## Code conventions

- System V AMD64 calling convention between functions; syscall args in
  rdi/rsi/rdx/r10/r8/r9.
- All strings are (pointer, length) pairs. No NUL-scanning of untrusted data.
- Per-connection bump arenas instead of a heap: `arena_reset` at the start of
  each request makes use-after-free structurally impossible in request code.
- Every source file declares a non-executable stack; the binary links with
  `-z noexecstack -z relro`.

## License

MIT — see [LICENSE](LICENSE).
