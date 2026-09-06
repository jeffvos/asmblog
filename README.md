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
make            # nasm + ld -> build/blogd, tailwind -> one stylesheet per theme
make run        # serve on http://127.0.0.1:8080
make test       # contrast floor + smoke suite (store selftest, HTTP, content, admin)
make fuzz       # mutation-fuzz the HTTP and markdown parsers
make load       # step through concurrency levels, report latency/CPU/RSS knees
./build/blogd init       # first-run setup (title, posts/page, admin password)
./build/blogd seed       # demo posts for development
./build/blogd compact    # rewrite data/store.blg with only the live records
./build/blogd 9000 8     # custom port + thread count
```

`make test` is hermetic: every server it starts gets a free port and is
stopped by its own PID, so it can run beside a live blogd.

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
| `BLOGD_IDLE_SECS` | `20` | close connections quiet for this long (`0` = never) |

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
  weak `ETag` (`W/"<store generation>-<crc32c of host+scheme+path+query>"`)
  and `Last-Modified`; static assets carry a strong `ETag`. The
  generation changes on every write and every restart (templates and
  CSS load at boot), so an `If-None-Match` hit is answered with a 304
  before anything is rendered; without an `If-None-Match`, an
  `If-Modified-Since` (IMF-fixdate) is checked against the store's last
  write instead, which is what most feed readers send. Pages are
  `public, max-age=0, must-revalidate`; the feed is cacheable for five
  minutes; the versioned stylesheet (`/static/main.css?v=<crc>`) is
  `immutable` for a year; icons for a day; `/admin` and the counter are
  `no-store`.
- **Rendered-page cache**: because the ETag pins the exact bytes, a
  small shared cache keyed on it (plus host, scheme and request target)
  serves a repeat request for the same page as a copy, skipping the
  store lock and the template and markdown work; a write or restart
  moves the generation and every entry simply stops matching.
- **Request limits are named honestly**: a body over 100 KB is a `413`,
  a head that never ends inside 8 KiB is a `431`, and a body framed with
  `Transfer-Encoding` (chunked) is a `411` (bodies are framed by
  `Content-Length` only); each of those closes the connection. A
  connection that goes quiet — a half-sent head, an unused keep-alive,
  a peer that stopped reading — is closed after `BLOGD_IDLE_SECS`
  (default 20) by a per-worker timer, and its buffers are returned to
  the kernel.
- **`HEAD`** is supported everywhere; `Date`, `Content-Language`,
  `Vary: Accept-Encoding` (on negotiated assets) and `Allow` (on 405)
  are emitted; `Accept-Encoding` is tokenised (`;q=0` is honoured); every stylesheet
  ships with `.gz` and `.br` siblings and the best one the client accepts
  is served.
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

Eight themes ship, selectable in **/admin/settings** and applied via a
class on `<body>` (every palette is compiled into the single
stylesheet, so switching is instant and needs no rebuild). Each has its
own shapes, type and textures, not just colours:

- **Retro** (default) — polished 1990s web: navy backdrop with a tiled
  8-pixel dither, beveled silver panels, monospace, a scrolling
  marquee, a green-LED hit counter.
- **Sucre** — a modern take on the whitewashed colonial architecture of
  Sucre, Bolivia (*La Ciudad Blanca*): plaster-grain background, panels
  as white "walls" under a tiled terracotta roofline, colonial-green
  links, ochre accents, serif display type. The banner is a quiet
  engraved lintel rather than a marquee.
- **Medellín** — a Feria de las Flores street poster: halftone paper,
  chunky rounded panels with a thick ink outline and a hard offset
  shadow in a second colour, a silleta flower band under the masthead,
  slapped-on sticker tags, a vinyl-strip marquee, heavy grotesque caps.
- **Bogotá** — brick and gold, editorial: the page is a running-bond
  brick wall (one SVG tile tinted by the background), panels are
  window openings framed in a double line, Muisca gold accents, a
  literary serif with small caps and a drop cap. Nothing rounded.
- **La Paz** — neo-Andean cholet, dark by default: stepped chakana
  corners cut with `clip-path`, a glossy teal→violet stroke around every
  panel, the masthead framed in aguayo stripes, a minibus destination
  sign for the banner, Teleférico line colours on the badges, wide
  geometric caps. A thin-air daytime palette follows a light
  `prefers-color-scheme`.
- **Cochabamba** — La Cancha market: kraft paper with a fibre grain,
  chalkboard menus in wooden frames, posts as pinned index cards with
  dashed hand-ruled borders and coloured push-pins, string price tags,
  sticker badges, slab-serif signboard type.
- **Santa Cruz de la Sierra** — tropical lowland and mission woodwork:
  sand with an afternoon sun glow, open borderless panels with
  leaf-shaped corners, a painted-column band from the Chiquitos
  missions under the masthead, concentric *anillos* as ornaments, a
  light humanist sans and a lowercase brand.
- **Pittsburgh** — Steel City, black and gold, dark by default: panels
  are riveted steel plates, the masthead carries a bridge-truss band,
  the banner is a mill hazard stripe, badges take the Steelmark colours,
  the footer shows the three rivers meeting at the Point, condensed
  industrial caps. An overcast brushed-steel day mode follows a light
  `prefers-color-scheme`.

The favicon, touch icons, `og:image` card, web manifest colours,
`<meta name="theme-color">` and the hit counter's colours follow the
theme too: `tools/mkicons.py` draws a set per theme with its own frame
style (`static/favicon.*`, `static/sucre-favicon.*`, `static/pittsburgh-favicon.*`, …) and the server
serves whichever matches the active theme, with a `?v=theme-…` token on
the URLs so browsers and link unfurlers refetch after a switch. The
theme ids, class names, form values and server-emitted colours live in
one table in [src/pages.asm](src/pages.asm).

Templates use semantic classes (`.masthead`, `.card`, `.btn`, `.tag`, …)
that each theme restyles under a `.theme-<name>` scope in
[assets/input.css](assets/input.css). Textures are inline only — CSS
gradients and tiny data-URI SVG tiles — so a page still loads one
stylesheet and no extra requests. That stylesheet is built per theme:
`tools/mkcss.py` splits `input.css` at the `THEME:` banners and runs
Tailwind once per section, producing `static/main.css` (Retro) and
`static/<theme>-main.css` for the rest (4–6 KB gzipped each rather than
the 14 KB of all eight together), and `/static/main.css` serves
whichever matches the active theme with its own `?v=` token. All themes
but Retro follow `prefers-color-scheme`; every theme respects
`prefers-reduced-motion`, has a print stylesheet, and uses
cross-document view transitions for page-to-page navigation where the
browser supports them (no script involved).

Small text has a floor across themes: `tools/contrast.py` (run by
`make test`) resolves each theme's palette variables for both colour
schemes and fails the build if byline/excerpt text drops under WCAG AA
4.5:1 against its panel, or if any `.meta`/`.byline`/`.navlink`/`.footer`
rule sets a size below 13 px.

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

Requires: `nasm` (2.x or 3.x), GNU binutils, the libsodium development
package, `python3` (the CSS build, the icon generator and the tests),
`brotli` (the `.br` siblings; `BLOGD_NO_BROTLI=1` skips them on a
machine without the CLI), `curl`, and the Tailwind standalone CLI at
`tools/tailwindcss` (gitignored: `make` fetches the pinned release and
verifies its SHA-256 when the file is absent). `make deps` checks all
of that and names what is missing. Per distribution:

```bash
# Debian / Ubuntu
sudo apt install nasm binutils libsodium-dev python3 brotli curl
# RHEL / AlmaLinux / Rocky (libsodium lives in EPEL)
sudo dnf install epel-release && sudo dnf install nasm binutils libsodium-devel python3 brotli curl
# Alpine
apk add nasm binutils libsodium-dev python3 brotli curl
```

At run time only the libsodium shared library is needed (`libsodium23`
/ `libsodium` / `libsodium`), not the development package. The Makefile, CI and the Docker build all pin the same Tailwind
release and checksum (`TAILWIND_VERSION`/`TAILWIND_SHA256` in the
[Makefile](Makefile), [ci.yml](.github/workflows/ci.yml) and the
[Dockerfile](Dockerfile)); bump them together.

### Load testing

`tools/loadtest.py` (`make load`, or `make load LOAD_ARGS="--levels 16,64,256 --duration 10"`)
starts a seeded throwaway server and steps it through a list of
concurrency levels. Each level runs a fixed number of keep-alive
connections cycling over a mix of public URLs for a few seconds and
reports throughput, latency (average, p50/p95/p99/max), errors and
non-200s, and the server's CPU (all threads), resident memory, thread
and fd counts sampled from `/proc` while the level runs, plus the
client's own CPU so a client-bound level is starred rather than
misread. It ends with the break points: where p99 crosses the `--slo`
budget, where throughput stops growing, where errors begin, and the
memory cost per open connection. `--url`/`--pid` point it at a server
you already run, `--no-keepalive` measures connection setup, `--paths`
changes the mix and `--json` keeps every number. Raise `ulimit -n`
for levels above ~900 connections.

### Storage housekeeping

Every edit appends a new version of the post and every delete a
tombstone, so `data/store.blg` grows until it is compacted. blogd
rewrites it at startup once superseded records make up more than half
of a file past 64 KiB, and `blogd compact` does the same on demand
(run it in the site directory; it prints the sizes before and after).
The in-memory arena the records load into grows in slabs, so a long
run of saves never exhausts it.

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
