#!/usr/bin/env bash
# Smoke test: start blogd on scratch ports, poke it with curl.
#
# Hermetic: every server is started on a free port picked at run time and
# stopped by its own PID -- never by process name -- so the suite can run
# next to a live blogd (or a preview) without touching it.
set -euo pipefail
cd "$(dirname "$0")/.."

ROOT="$(pwd)"

free_port() {   # an ephemeral TCP port that is free right now
    python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'
}
PORT="${1:-$(free_port)}"

# store + crypto selftest runs in a scratch dir before the server tests
TMPD="$(mktemp -d)"
if (cd "$TMPD" && "$ROOT/build/blogd" selftest | grep -q 'selftest ok'); then
    echo "ok   - store + Argon2id selftest"
else
    echo "FAIL - store + Argon2id selftest"
    exit 1
fi
rm -rf "$TMPD"

# CI runners can be slow to bring a server up: poll instead of sleeping
wait_up() {   # wait_up <url> — until it answers (≤ 10 s), else fail loudly
    local i
    for i in $(seq 100); do
        curl -s -o /dev/null "$1" 2>/dev/null && return 0
        sleep 0.1
    done
    echo "FAIL - server at $1 did not come up"; exit 1
}
stop() {      # stop <pid> — SIGTERM, then wait until it is gone (≤ 5 s)
    local i
    kill "$1" 2>/dev/null || true
    for i in $(seq 50); do
        kill -0 "$1" 2>/dev/null || return 0
        sleep 0.1
    done
    kill -9 "$1" 2>/dev/null || true
}
PIDS=()
trap 'for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done' EXIT

./build/blogd "$PORT" &
PID=$!
PIDS+=("$PID")
wait_up "http://127.0.0.1:$PORT/health"

fail=0
# well-formedness check with the standard library (no xmllint needed)
xmlok() { python3 -c 'import sys, xml.dom.minidom as m; m.parseString(sys.stdin.buffer.read())' 2>/dev/null; }
export -f xmlok
# raw_status <port> <request bytes (python literal)> -> status code the
# server answers with, over a plain socket (for requests curl won't send)
raw_status() {
    python3 - "$1" "$2" <<'PY'
import socket, sys
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=5)
s.sendall(eval(sys.argv[2]))
data = b""
while b"\r\n" not in data:
    chunk = s.recv(4096)
    if not chunk: break
    data += chunk
print(data.split(b" ")[1].decode() if b" " in data else "000")
PY
}
export -f raw_status
# idle_closed <port> <max seconds> -> exits 0 if a silent connection is
# closed by the server within the window
idle_closed() {
    python3 - "$1" "$2" <<'PY'
import socket, sys, time
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=float(sys.argv[2]))
t0 = time.time()
try:
    data = s.recv(16)
except socket.timeout:
    sys.exit(1)
sys.exit(0 if data == b"" else 1)
PY
}
export -f idle_closed

check() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        echo "ok   - $desc"
    else
        echo "FAIL - $desc"
        fail=1
    fi
}

expect_code() {
    local desc="$1" want="$2"; shift 2
    local got
    got=$(curl -s -o /dev/null -w '%{http_code}' "$@")
    if [ "$got" = "$want" ]; then
        echo "ok   - $desc ($got)"
    else
        echo "FAIL - $desc (want $want, got $got)"
        fail=1
    fi
}

check "GET / serves the index page"        bash -c "curl -fsS http://127.0.0.1:$PORT/ | grep -q blogd"
check "GET /health returns ok"             bash -c "curl -fsS http://127.0.0.1:$PORT/health | grep -qx ok"
expect_code "unknown path is 404"      404 "http://127.0.0.1:$PORT/nope"
expect_code "POST is 405"              405 -X POST "http://127.0.0.1:$PORT/"
expect_code "index is 200"             200 "http://127.0.0.1:$PORT/"
check "Content-Length is present"          bash -c "curl -fsS -D - -o /dev/null http://127.0.0.1:$PORT/ | grep -qi '^content-length:'"
check "HTTP/1.1 gets keep-alive"           bash -c "curl -fsS -D - -o /dev/null http://127.0.0.1:$PORT/ | grep -qi '^connection: keep-alive'"
check "HTTP/1.0 gets close"                bash -c "curl -fsS --http1.0 -D - -o /dev/null http://127.0.0.1:$PORT/ | grep -qi '^connection: close'"
check "keep-alive reuses the connection"   bash -c "curl -sv -o /dev/null http://127.0.0.1:$PORT/ http://127.0.0.1:$PORT/health 2>&1 | grep -qiE 're-?using existing'"
check "100 parallel requests all 200"      bash -c "test \"\$(seq 100 | xargs -P20 -I@ curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:$PORT/health | sort -u)\" = 200"

stop "$PID"

# content tests: seeded site in a scratch dir
CPORT="$(free_port)"
CTMP="$(mktemp -d)"
cp -r "$ROOT/templates" "$ROOT/static" "$CTMP/"
(cd "$CTMP" && "$ROOT/build/blogd" seed >/dev/null)
(cd "$CTMP" && exec "$ROOT/build/blogd" "$CPORT" >/dev/null 2>&1) &
CPID=$!
PIDS+=("$CPID")
B="http://127.0.0.1:$CPORT"
wait_up "$B/health"
expect_code "seeded home is 200"          200 "$B/"
expect_code "page past the end is 404"    404 "$B/page/3"
expect_code "draft post is hidden (404)"  404 "$B/post/secret-draft"
expect_code "tag page bounds enforced"    404 "$B/tag/asm/page/2"
check "home shows 5 cards (ppp default)"       bash -c "test \"\$(curl -s $B/ | grep -c '<article')\" = 5"
check "page 2 shows the remaining 3"           bash -c "test \"\$(curl -s $B/page/2 | grep -c '<article')\" = 3"
check "tag filter narrows to 3"                bash -c "test \"\$(curl -s $B/tag/asm | grep -c '<article')\" = 3"
check "search is case-insensitive"             bash -c "test \"\$(curl -s '$B/search?q=MARQUEE' | grep -c '<article')\" = 1"
check "post page renders body html"            bash -c "curl -s $B/post/why-assembly | grep -q 'The stack is a place'"
check "atom feed lists 8 published"            bash -c "test \"\$(curl -s $B/feed.xml | grep -c '<entry>')\" = 8"
check "css served with gzip when accepted"     bash -c "curl -s -H 'Accept-Encoding: gzip' -D - -o /dev/null $B/static/main.css | grep -qi '^content-encoding: gzip'"
check "html escaping in search echo"           bash -c "curl -s '$B/search?q=%3Cscript%3E' | grep -q '&lt;script&gt;' && ! curl -s '$B/search?q=%3Cscript%3E' | grep -q '<script>'"
check "security headers on every response"      bash -c "curl -s -D - -o /dev/null $B/ | grep -qi '^content-security-policy:' && curl -s -D - -o /dev/null $B/ | grep -qi '^x-content-type-options: nosniff'"
# --- caching, validators, HEAD ---
check "Date header on every response"           bash -c "curl -s -D - -o /dev/null $B/ | grep -qi '^date: ' && curl -s -D - -o /dev/null $B/nope | grep -qi '^date: '"
check "HEAD returns headers, no body"           bash -c "curl -s -I $B/ | grep -qi '^content-length: [1-9]' && test \"\$(curl -s --head -o /dev/null -w '%{size_download}' $B/)\" = 0"
check "405 carries Allow"                       bash -c "curl -s -D - -o /dev/null -X PUT $B/ | grep -qi '^allow: GET, HEAD'"
check "HTML has ETag + must-revalidate"         bash -c "curl -s -D - -o /dev/null $B/ | grep -qi '^etag: W/\"' && curl -s -D - -o /dev/null $B/ | grep -qi '^cache-control: public, max-age=0, must-revalidate'"
check "If-None-Match answers 304"               bash -c "ET=\$(curl -s -I $B/post/why-assembly | grep -i '^etag' | cut -d' ' -f2 | tr -d '\r'); test \"\$(curl -s -o /dev/null -w '%{http_code}' -H \"If-None-Match: \$ET\" $B/post/why-assembly)\" = 304"
check "If-Modified-Since answers 304"           bash -c "LM=\$(curl -s -I $B/ | grep -i '^last-modified' | cut -d' ' -f2- | tr -d '\r'); test \"\$(curl -s -o /dev/null -w '%{http_code}' -H \"If-Modified-Since: \$LM\" $B/)\" = 304"
check "stale If-Modified-Since gets 200"        bash -c "test \"\$(curl -s -o /dev/null -w '%{http_code}' -H 'If-Modified-Since: Thu, 01 Jan 1970 00:00:00 GMT' $B/feed.xml)\" = 200"
check "If-None-Match wins over If-Modified-Since" bash -c "LM=\$(curl -s -I $B/ | grep -i '^last-modified' | cut -d' ' -f2- | tr -d '\r'); test \"\$(curl -s -o /dev/null -w '%{http_code}' -H 'If-None-Match: \"nope\"' -H \"If-Modified-Since: \$LM\" $B/)\" = 200"
check "second render of a page is a cache hit (same bytes)" bash -c "A=\$(curl -s $B/page/2 | md5sum); B2=\$(curl -s $B/page/2 | md5sum); test \"\$A\" = \"\$B2\" && curl -s $B/page/2 | grep -q '<article'"
check "excerpts never double up punctuation"    bash -c "! curl -s $B/ | grep -q '[.!?]…' && ! curl -s $B/feed.xml | grep -q '[.!?]…' && ! curl -s $B/ | grep -q '\.\.\.\.'"
check "oversized body is 413"                   bash -c "test \"\$(raw_status $CPORT 'b\"POST /admin/login HTTP/1.1\\r\\nHost: x\\r\\nContent-Length: 999999\\r\\n\\r\\n\"')\" = 413"
check "oversized head is 431"                   bash -c "test \"\$(raw_status $CPORT 'b\"GET / HTTP/1.1\\r\\nHost: x\\r\\nX-Pad: \" + b\"a\"*9000')\" = 431"
check "chunked request body is 411"             bash -c "test \"\$(raw_status $CPORT 'b\"POST /admin/login HTTP/1.1\\r\\nHost: x\\r\\nTransfer-Encoding: chunked\\r\\n\\r\\n0\\r\\n\\r\\n\"')\" = 411"
check "Expect: 100-continue is answered"        bash -c "test \"\$(raw_status $CPORT 'b\"POST /admin/login HTTP/1.1\\r\\nHost: x\\r\\nContent-Length: 11\\r\\nExpect: 100-continue\\r\\n\\r\\n\"')\" = 100"
check "Content-Language on HTML only"           bash -c "curl -s -D - -o /dev/null $B/ | grep -qi '^content-language: en' && ! curl -s -D - -o /dev/null $B/feed.xml | grep -qi '^content-language'"
check "versioned css is immutable + Vary"       bash -c "curl -s -D - -o /dev/null '$B/static/main.css?v=x' | grep -qi 'immutable' && curl -s -D - -o /dev/null '$B/static/main.css?v=x' | grep -qi '^vary: accept-encoding'"
check "bare css revalidates hourly"             bash -c "curl -s -D - -o /dev/null $B/static/main.css | grep -qi 'max-age=3600'"
check "Accept-Encoding gzip;q=0 is honoured"    bash -c "! curl -s -D - -o /dev/null -H 'Accept-Encoding: gzip;q=0' $B/static/main.css | grep -qi '^content-encoding'"
check "static ETag round-trips to 304"          bash -c "ET=\$(curl -s -I $B/static/main.css | grep -i '^etag' | cut -d' ' -f2 | tr -d '\r'); test \"\$(curl -s -o /dev/null -w '%{http_code}' -H \"If-None-Match: \$ET\" $B/static/main.css)\" = 304"
check "shell links the versioned stylesheet"    bash -c "curl -s $B/ | grep -q 'href=\"/static/main.css?v=[0-9a-f]\{8\}\"'"
# --- discovery files ---
expect_code "favicon.ico is served"          200 "$B/favicon.ico"
expect_code "favicon.svg is served"          200 "$B/static/favicon.svg"
expect_code "icon-192.png is served"         200 "$B/static/icon-192.png"
expect_code "og.png is served"               200 "$B/static/og.png"
check "manifest names the site"                 bash -c "curl -s -D - $B/manifest.webmanifest | grep -qi '^content-type: application/manifest+json' && curl -s $B/manifest.webmanifest | grep -q '\"name\":\"blogd\"'"
check "robots.txt blocks admin, links sitemap"  bash -c "curl -s -H 'Host: t.example' -H 'X-Forwarded-Proto: https' $B/robots.txt | grep -q '^Disallow: /admin' && curl -s -H 'Host: t.example' -H 'X-Forwarded-Proto: https' $B/robots.txt | grep -q '^Sitemap: https://t.example/sitemap.xml'"
check "sitemap lists published posts only"      bash -c "test \"\$(curl -s -H 'Host: t.example' $B/sitemap.xml | grep -c '<url>')\" = 9 && ! curl -s -H 'Host: t.example' $B/sitemap.xml | grep -q secret-draft"
check "sitemap needs an absolute origin"        bash -c "test \"\$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: ' $B/sitemap.xml)\" = 404"
check "sitemap is well-formed xml"              bash -c "curl -s -H 'Host: t.example' $B/sitemap.xml | xmlok"
# --- canonical urls ---
check "/page/1 redirects to /"                  bash -c "test \"\$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' $B/page/1)\" = '301 $B/'"
check "trailing slash redirects"                bash -c "test \"\$(curl -s -o /dev/null -w '%{redirect_url}' $B/tag/asm/)\" = '$B/tag/asm'"
check "pager links carry rel=prev/next"         bash -c "curl -s $B/page/2 | grep -q 'rel=\"prev\" href=\"/\"' && curl -s $B/ | grep -q 'rel=\"next\" href=\"/page/2\"'"
# --- <head> metadata / link embeds ---
check "post has description, canonical, OG"     bash -c "P=\$(curl -s -H 'Host: t.example' -H 'X-Forwarded-Proto: https' $B/post/why-assembly); echo \"\$P\" | grep -q '<meta name=\"description\" content=\"Because every' && echo \"\$P\" | grep -q '<link rel=\"canonical\" href=\"https://t.example/post/why-assembly\">' && echo \"\$P\" | grep -q 'og:title\" content=\"Why Assembly?\"' && echo \"\$P\" | grep -q 'article:tag\" content=\"asm\"' && echo \"\$P\" | grep -q 'twitter:card'"
check "post JSON-LD parses as BlogPosting"      bash -c "curl -s -H 'Host: t.example' $B/post/why-assembly | grep -o '<script type=\"application/ld+json\">.*</script>' | sed 's/<script[^>]*>//;s/<\/script>//' | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d[\"@type\"]==\"BlogPosting\" and d[\"headline\"]==\"Why Assembly?\"'"
check "home JSON-LD is a WebSite w/ search"     bash -c "curl -s -H 'Host: t.example' $B/ | grep -o '<script type=\"application/ld+json\">.*</script>' | sed 's/<script[^>]*>//;s/<\/script>//' | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d[\"@type\"]==\"WebSite\" and \"search_term_string\" in d[\"potentialAction\"][\"target\"]'"
check "search results are noindex"              bash -c "curl -s '$B/search?q=mov' | grep -q 'content=\"noindex,follow\"' && ! curl -s $B/ | grep -q noindex"
check "list titles: page N, #tag, search: q"    bash -c "curl -s $B/page/2 | grep -q '<title>home · page 2 ' && curl -s $B/tag/asm | grep -q '<title>#asm ' && curl -s '$B/search?q=mov' | grep -q '<title>search: mov '"
check "no absolute urls without an origin"      bash -c "! curl -s -H 'Host: ' $B/post/why-assembly | grep -q 'rel=\"canonical\"' && curl -s -H 'Host: ' $B/post/why-assembly | grep -q 'twitter:card\" content=\"summary\"'"
# --- feed ---
check "feed: author, published, category, content" bash -c "F=\$(curl -s -H 'Host: t.example' $B/feed.xml); echo \"\$F\" | grep -q '<author><name>blogd</name></author>' && echo \"\$F\" | grep -q '<published>' && echo \"\$F\" | grep -q '<category term=\"asm\"/>' && echo \"\$F\" | grep -q '<content type=\"html\">' && echo \"\$F\" | grep -q 'href=\"http://t.example/post/why-assembly\"'"
check "feed is well-formed xml (with and without origin)" bash -c "curl -s -H 'Host: t.example' $B/feed.xml | xmlok && curl -s -H 'Host: ' $B/feed.xml | xmlok"
check "feed updated is the store time, not now" bash -c "A=\$(curl -s $B/feed.xml | grep -o '<updated>[^<]*' | head -1); sleep 1.1; B2=\$(curl -s $B/feed.xml | grep -o '<updated>[^<]*' | head -1); test \"\$A\" = \"\$B2\""
# --- visitor counter ---
check "hits.svg increments and is no-store"     bash -c "A=\$(curl -s $B/hits.svg | grep -o '>0*[0-9]*</text' | tr -dc 0-9); B2=\$(curl -s $B/hits.svg | grep -o '>0*[0-9]*</text' | tr -dc 0-9); test \$((10#\$A+1)) = \$((10#\$B2)) && curl -s -D - -o /dev/null $B/hits.svg | grep -qi '^cache-control: no-store'"
check "HEAD on hits.svg peeks without counting" bash -c "A=\$(curl -s $B/hits.svg | grep -o '>0*[0-9]*</text' | tr -dc 0-9); curl -s -I $B/hits.svg >/dev/null; B2=\$(curl -s $B/hits.svg | grep -o '>0*[0-9]*</text' | tr -dc 0-9); test \$((10#\$A+1)) = \$((10#\$B2))"
HITS_BEFORE="$(curl -s $B/hits.svg | grep -o '>0*[0-9]*</text' | tr -dc 0-9)"
stop "$CPID"
(cd "$CTMP" && exec "$ROOT/build/blogd" "$CPORT" >/dev/null 2>&1) &
CPID=$!
PIDS+=("$CPID")
wait_up "$B/health"
HITS_AFTER="$(curl -s $B/hits.svg | grep -o '>0*[0-9]*</text' | tr -dc 0-9)"
check "visitor counter survives a restart"      test "$((10#$HITS_AFTER))" = "$((10#$HITS_BEFORE + 1))"
stop "$CPID"

# admin tests: init a password, drive the whole panel over HTTP
APORT="$(free_port)"
ATMP="$(mktemp -d)"
cp -r "$ROOT/templates" "$ROOT/static" "$ATMP/"
cd "$ATMP"
printf 'Smoke Blog\n5\nsmokepass123\nsmokepass123\n' | "$ROOT/build/blogd" init >/dev/null 2>&1
"$ROOT/build/blogd" seed >/dev/null
BLOGD_IDLE_SECS=2 "$ROOT/build/blogd" "$APORT" >/dev/null 2>&1 &
APID=$!
PIDS+=("$APID")
cd "$ROOT"
A="http://127.0.0.1:$APORT"
wait_up "$A/health"
JAR="$ATMP/jar.txt"
expect_code "admin without session bounces" 303 "$A/admin"
check "wrong password is refused"          bash -c "curl -s -d password=wrongwrong1 $A/admin/login | grep -q 'wrong password'"
sleep 1.2
expect_code "correct login gets 303"   303 -c "$JAR" -d password=smokepass123 "$A/admin/login"
DASH="$(curl -s -b "$JAR" "$A/admin")"
CSRF="$(echo "$DASH" | grep -o 'name="csrf" value="[0-9a-f]*"' | head -1 | grep -o '[0-9a-f]\{64\}')"
check "dashboard lists all 9 posts"        bash -c "test \"\$(echo '$DASH' | grep -o '/admin/edit/[0-9]*' | wc -l)\" = 9"
if [ "${#CSRF}" = 64 ]; then echo "ok   - csrf token is 64 hex chars"; else echo "FAIL - csrf token is 64 hex chars"; fail=1; fi
expect_code "save publishes a post"    303 -b "$JAR" --data-urlencode "csrf=$CSRF" --data-urlencode id=0 \
    --data-urlencode "title=Smoke Post" --data-urlencode slug= --data-urlencode tags=smoke \
    --data-urlencode 'md=Hello **world** from [here](/about)' --data-urlencode action=publish "$A/admin/save"
check "markdown rendered on public site"   bash -c "curl -s $A/post/smoke-post | grep -q '<strong>world</strong>'"
# excerpt of a long post: cut at the cap, finished with one ellipsis
LONGMD="$(python3 -c 'print(" ".join("word%d" % i for i in range(60)))') and then a second paragraph."
curl -s -b "$JAR" -o /dev/null --data-urlencode "csrf=$CSRF" --data-urlencode id=0 --data-urlencode "title=Long One" \
    --data-urlencode slug=long-one --data-urlencode tags=smoke --data-urlencode "md=$LONGMD" --data-urlencode action=publish "$A/admin/save"
check "long excerpt is cut with one ellipsis" bash -c "curl -s $A/ | grep -o '<p class=\"excerpt[^<]*</p>' | grep 'word0 ' | grep -q '[a-z0-9]…</p>' && ! curl -s $A/ | grep -q '…\.' && curl -s $A/post/long-one | grep -q 'name=\"description\" content=\"word0 .*…\"'"
# markdown: images (CSP-shaped allowlist), heading anchors, code classes
MDX='## Hello World!

```rust
fn main() {}
```

![A photo](https://live.staticflickr.com/1/2_b.jpg)

Inline ![local](/static/og.png) and ![evil](https://evil.example/x.png) and ![pr](//evil.example/x).'
MDP="$(curl -s -b "$JAR" --data-urlencode "csrf=$CSRF" --data-urlencode title=t --data-urlencode "md=$MDX" "$A/admin/preview")"
export MDP    # check() runs bash -c
check "headings get id anchors"             bash -c "echo \"\$MDP\" | grep -q '<h2 id=\"hello-world\">Hello World!</h2>'"
check "fenced code carries language class"  bash -c "echo \"\$MDP\" | grep -q '<pre><code class=\"language-rust\">fn main() {}'"
check "lone image line becomes a figure"    bash -c "echo \"\$MDP\" | grep -q '<figure><img src=\"https://live.staticflickr.com/1/2_b.jpg\" alt=\"A photo\" loading=\"lazy\" decoding=\"async\"></figure>'"
check "site-relative image is allowed"      bash -c "echo \"\$MDP\" | grep -q '<img src=\"/static/og.png\" alt=\"local\"'"
check "foreign image hosts render as text"  bash -c "! echo \"\$MDP\" | grep -q 'evil.example/x.png\"' && ! echo \"\$MDP\" | grep -q 'src=\"//evil' && echo \"\$MDP\" | grep -qF '![evil](https://evil.example/x.png)'"
check "hostile markdown stays escaped"     bash -c "P=\$(curl -s -b '$JAR' --data-urlencode csrf=$CSRF --data-urlencode 'md=[x](javascript:alert(1)) <script>' --data-urlencode title=t '$A/admin/preview'); echo \"\$P\" | grep -q '&lt;script&gt;' && ! echo \"\$P\" | grep -q 'href=\"javascript'"
# configurable banner
expect_code "settings save with banner" 303 -b "$JAR" --data-urlencode "csrf=$CSRF" \
    --data-urlencode "title=Smoke Blog" --data-urlencode ppp=5 --data-urlencode "banner=CUSTOM-BANNER-XYZ" "$A/admin/settings"
check "custom banner shows on the site"    bash -c "curl -s $A/ | grep -q 'CUSTOM-BANNER-XYZ'"
# theme switching
check "default theme is retro"             bash -c "curl -s $A/ | grep -q 'class=\"min-h-screen theme-retro\"'"
check "stylesheet carries only the active theme" bash -c "curl -s $A/static/main.css | grep -q '\.theme-retro .masthead' && ! curl -s $A/static/main.css | grep -q '\.theme-sucre .masthead'"
RETRO_CSSV="$(curl -s $A/ | grep -o 'main.css?v=[0-9a-f]*' | head -1)"
check "retro icons by default"             bash -c "cmp -s <(curl -s $A/favicon.ico) '$ROOT/static/favicon.ico'"
check "retro theme-color meta"             bash -c "curl -s $A/ | grep -q '<meta name=\"theme-color\" content=\"#000080\">'"
for T in sucre medellin bogota lapaz cochabamba santacruz pittsburgh; do
    expect_code "switch to $T theme"   303 -b "$JAR" --data-urlencode "csrf=$CSRF" \
        --data-urlencode "title=Smoke Blog" --data-urlencode ppp=5 --data-urlencode theme=$T "$A/admin/settings"
    check "$T theme now on the site"       bash -c "curl -s $A/ | grep -q 'class=\"min-h-screen theme-$T\"'"
    check "$T radio pre-checked in form"   bash -c "curl -s -b '$JAR' $A/admin/settings | grep -q 'value=\"$T\" checked'"
    check "$T icons follow the theme"      bash -c "cmp -s <(curl -s $A/favicon.ico) '$ROOT/static/$T-favicon.ico' && cmp -s <(curl -s $A/static/favicon.svg) '$ROOT/static/$T-favicon.svg' && cmp -s <(curl -s $A/static/icon-192.png) '$ROOT/static/$T-icon-192.png' && cmp -s <(curl -s $A/static/og.png) '$ROOT/static/$T-og.png' && curl -s $A/ | grep -q 'og.png?v=theme-$T' && curl -s $A/ | grep -q 'favicon.svg?v=theme-$T'"
    check "$T manifest + meta + counter"   bash -c "M=\$(curl -s $A/manifest.webmanifest); echo \"\$M\" | grep -q 'icon-512.png?v=theme-$T' && C=\$(echo \"\$M\" | grep -o '\"theme_color\":\"#[0-9a-f]*\"' | cut -d'\"' -f4) && curl -s $A/ | grep -q \"<meta name=.theme-color. content=.\$C.>\" && curl -s $A/hits.svg | grep -q 'fill=\"#[0-9a-f]\{6\}\"' && curl -s $A/404-page | grep -q 'theme-$T'"
    check "$T stylesheet served per theme" bash -c "curl -s $A/static/main.css | grep -q '\.theme-$T .masthead' && ! curl -s $A/static/main.css | grep -q '\.theme-retro .masthead' && cmp -s <(curl -s $A/static/main.css) '$ROOT/static/$T-main.css' && test \"\$(curl -s $A/ | grep -o 'main.css?v=[0-9a-f]*' | head -1)\" != '$RETRO_CSSV'"
done
check "unknown theme value falls back"     bash -c "curl -s -o /dev/null -b '$JAR' --data-urlencode csrf=$CSRF --data-urlencode 'title=Smoke Blog' --data-urlencode ppp=5 --data-urlencode theme=bogus $A/admin/settings && curl -s $A/ | grep -q 'theme-retro'"
expect_code "switch back to retro"     303 -b "$JAR" --data-urlencode "csrf=$CSRF" \
    --data-urlencode "title=Smoke Blog" --data-urlencode ppp=5 --data-urlencode theme=retro "$A/admin/settings"
check "theme survives a settings reload"   bash -c "curl -s $A/ | grep -q 'theme-retro'"
# localization (site-wide, from settings)
check "default locale is en-US"            bash -c "curl -s $A/ | grep -q '<html lang=\"en\">' && curl -s $A/ | grep -Eq 'class=\"date\">[A-Z][a-z]+ [0-9]+, [0-9]{4}'"
expect_code "switch locale to es-BO"   303 -b "$JAR" --data-urlencode "csrf=$CSRF" \
    --data-urlencode "title=Smoke Blog" --data-urlencode ppp=5 --data-urlencode locale=es "$A/admin/settings"
check "es-BO templates + lang attr"        bash -c "curl -s $A/ | grep -q '<html lang=\"es-BO\">' && curl -s $A/ | grep -q '>inicio<'"
check "es-BO long date format"             bash -c "curl -s $A/ | grep -Eq '[0-9]+ de [a-z]+ de [0-9]{4}'"
check "es-BO asm strings (pager/heading)"  bash -c "curl -s $A/ | grep -q 'más antiguas' && curl -s $A/tag/asm | grep -q 'entradas con la etiqueta #asm'"
check "es-BO admin + error messages"       bash -c "curl -s -b '$JAR' $A/admin | grep -q 'panel de control' && curl -s -b '$JAR' --data-urlencode csrf=$CSRF --data-urlencode id=0 --data-urlencode title= --data-urlencode md=x $A/admin/save | grep -q 'obligatorio'"
expect_code "switch locale back to en" 303 -b "$JAR" --data-urlencode "csrf=$CSRF" \
    --data-urlencode "title=Smoke Blog" --data-urlencode ppp=5 --data-urlencode locale=en "$A/admin/settings"
# flickr embed: valid one renders static, script stripped; spoof rejected
FL='<a data-flickr-embed="true" href="https://www.flickr.com/photos/x/1/"><img src="https://live.staticflickr.com/1/2_b.jpg" alt="pic"/></a><script src="//embedr.flickr.com/x.js"></script>'
curl -s -b "$JAR" -o /dev/null --data-urlencode "csrf=$CSRF" --data-urlencode id=0 --data-urlencode "title=Pic" \
    --data-urlencode slug=pic --data-urlencode tags=p --data-urlencode "md=$FL" --data-urlencode action=publish "$A/admin/save"
check "flickr embed becomes static figure"  bash -c "curl -s $A/post/pic | grep -qF '<figure class=\"flickr-embed\">'"
check "flickr script tag is stripped"       bash -c "! curl -s $A/post/pic | grep -q 'embedr.flickr.com'"
check "flickr image host allowed by CSP"    bash -c "curl -s -D - -o /dev/null $A/ | grep -qi 'live.staticflickr.com'"
check "embed never leaks into card excerpt" bash -c "! curl -s $A/tag/p | grep -q 'data-flickr' && ! curl -s $A/feed.xml | grep -q 'data-flickr'"
check "excerpt strips markdown markers"     bash -c "curl -s $A/ | grep -q 'Hello world from' && ! curl -s $A/ | grep -q 'Hello \*\*world'"
FLBAD='<a data-flickr-embed="true" href="https://phish.example/"><img src="https://evil.com/x.jpg" alt="x"/></a>'
curl -s -b "$JAR" -o /dev/null --data-urlencode "csrf=$CSRF" --data-urlencode id=0 --data-urlencode "title=Bad" \
    --data-urlencode slug=badpic --data-urlencode tags=p --data-urlencode "md=$FLBAD" --data-urlencode action=publish "$A/admin/save"
check "spoofed flickr host is rejected"     bash -c "! curl -s $A/post/badpic | grep -qF '<figure class=\"flickr-embed\">' && ! curl -s $A/post/badpic | grep -q 'evil.com/x.jpg\"'"
# site url setting: validated, persisted, used for canonical links over the Host fallback
expect_code "invalid site url is refused" 200 -b "$JAR" --data-urlencode "csrf=$CSRF" \
    --data-urlencode "title=Smoke Blog" --data-urlencode ppp=5 --data-urlencode url=ftp://nope "$A/admin/settings"
expect_code "site url saves"           303 -b "$JAR" --data-urlencode "csrf=$CSRF" \
    --data-urlencode "title=Smoke Blog" --data-urlencode ppp=5 --data-urlencode "url=https://smoke.example/" "$A/admin/settings"
check "site url echoed without trailing slash" bash -c "curl -s -b '$JAR' $A/admin/settings | grep -q 'name=\"url\" value=\"https://smoke.example\"'"
check "configured url wins over Host"       bash -c "curl -s -H 'Host: other.example' $A/post/smoke-post | grep -q 'rel=\"canonical\" href=\"https://smoke.example/post/smoke-post\"'"
check "admin pages are no-store + noindex"  bash -c "curl -s -D - -b '$JAR' $A/admin | grep -qi '^cache-control: no-store' && curl -s -b '$JAR' $A/admin | grep -q 'content=\"noindex\"'"
expect_code "csrf mismatch is rejected" 400 -b "$JAR" -d "csrf=deadbeef&id=1" "$A/admin/delete"
# many large saves: the store arena (file size x2 + 4 MiB at open) must
# grow in slabs rather than run dry and refuse every later save
BIGMD="$(python3 -c 'print(("lorem ipsum dolor sit amet " * 1100)[:30000])')"
export BIGMD    # check() runs bash -c
check "80 large saves all succeed (arena grows)" bash -c "for i in \$(seq 80); do c=\$(curl -s -o /dev/null -w '%{http_code}' -b '$JAR' --data-urlencode csrf=$CSRF --data-urlencode id=0 --data-urlencode \"title=Bulk \$i\" --data-urlencode slug=bulk-\$i --data-urlencode tags=bulk --data-urlencode \"md=\$BIGMD\" --data-urlencode action=publish '$A/admin/save'); [ \"\$c\" = 303 ] || { echo \"save \$i -> \$c\"; exit 1; }; done; curl -s $A/post/bulk-80 | grep -q 'lorem ipsum'"
expect_code "logout works"             303 -b "$JAR" --data-urlencode "csrf=$CSRF" "$A/admin/logout"
expect_code "session is gone after logout" 303 -b "$JAR" "$A/admin"
check "idle connection is closed by the sweep" idle_closed "$APORT" 12
stop "$APID"
# compaction: the edits above left superseded records behind; rewrite,
# restart, everything is still there
check "blogd compact rewrites the store"   bash -c "cd '$ATMP' && '$ROOT/build/blogd' compact | grep -q '^compacted data/store.blg: [0-9]* -> [0-9]* bytes'"
(cd "$ATMP" && exec "$ROOT/build/blogd" "$APORT" >/dev/null 2>&1) &
APID=$!
PIDS+=("$APID")
wait_up "$A/health"
expect_code "post survives compaction"  200 "$A/post/smoke-post"
check "settings survive compaction"        bash -c "curl -s $A/ | grep -q 'CUSTOM-BANNER-XYZ'"
stop "$APID"

if [ "$fail" = 0 ]; then
    echo "smoke: all checks passed"
else
    echo "smoke: FAILURES"
    exit 1
fi
