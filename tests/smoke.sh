#!/usr/bin/env bash
# Smoke test: start blogd on a scratch port, poke it with curl.
set -euo pipefail
cd "$(dirname "$0")/.."

PORT="${1:-8091}"
ROOT="$(pwd)"

# store + crypto selftest runs in a scratch dir before the server tests
TMPD="$(mktemp -d)"
if (cd "$TMPD" && "$ROOT/build/blogd" selftest | grep -q 'selftest ok'); then
    echo "ok   - store + Argon2id selftest"
else
    echo "FAIL - store + Argon2id selftest"
    exit 1
fi
rm -rf "$TMPD"

./build/blogd "$PORT" &
PID=$!
trap 'kill "$PID" 2>/dev/null || true' EXIT
sleep 0.3

fail=0
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

kill "$PID" 2>/dev/null || true

# content tests: seeded site in a scratch dir
CPORT=$((PORT+1))
CTMP="$(mktemp -d)"
cp -r "$ROOT/templates" "$ROOT/static" "$CTMP/"
(cd "$CTMP" && "$ROOT/build/blogd" seed >/dev/null && "$ROOT/build/blogd" "$CPORT" >/dev/null 2>&1 &)
sleep 0.4
B="http://127.0.0.1:$CPORT"
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
check "sitemap is well-formed xml"              bash -c "curl -s -H 'Host: t.example' $B/sitemap.xml | xmllint --noout -"
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
check "feed is well-formed xml (with and without origin)" bash -c "curl -s -H 'Host: t.example' $B/feed.xml | xmllint --noout - && curl -s -H 'Host: ' $B/feed.xml | xmllint --noout -"
check "feed updated is the store time, not now" bash -c "A=\$(curl -s $B/feed.xml | grep -o '<updated>[^<]*' | head -1); sleep 1.1; B2=\$(curl -s $B/feed.xml | grep -o '<updated>[^<]*' | head -1); test \"\$A\" = \"\$B2\""
# --- visitor counter ---
check "hits.svg increments and is no-store"     bash -c "A=\$(curl -s $B/hits.svg | grep -o '>0*[0-9]*</text' | tr -dc 0-9); B2=\$(curl -s $B/hits.svg | grep -o '>0*[0-9]*</text' | tr -dc 0-9); test \$((10#\$A+1)) = \$((10#\$B2)) && curl -s -D - -o /dev/null $B/hits.svg | grep -qi '^cache-control: no-store'"
check "HEAD on hits.svg peeks without counting" bash -c "A=\$(curl -s $B/hits.svg | grep -o '>0*[0-9]*</text' | tr -dc 0-9); curl -s -I $B/hits.svg >/dev/null; B2=\$(curl -s $B/hits.svg | grep -o '>0*[0-9]*</text' | tr -dc 0-9); test \$((10#\$A+1)) = \$((10#\$B2))"
HITS_BEFORE="$(curl -s $B/hits.svg | grep -o '>0*[0-9]*</text' | tr -dc 0-9)"
pkill -x blogd 2>/dev/null || true
sleep 0.2
(cd "$CTMP" && "$ROOT/build/blogd" "$CPORT" >/dev/null 2>&1 &)
sleep 0.4
HITS_AFTER="$(curl -s $B/hits.svg | grep -o '>0*[0-9]*</text' | tr -dc 0-9)"
check "visitor counter survives a restart"      test "$((10#$HITS_AFTER))" = "$((10#$HITS_BEFORE + 1))"
pkill -x blogd 2>/dev/null || true
sleep 0.2

# admin tests: init a password, drive the whole panel over HTTP
APORT=$((PORT+2))
ATMP="$(mktemp -d)"
cp -r "$ROOT/templates" "$ROOT/static" "$ATMP/"
cd "$ATMP"
printf 'Smoke Blog\n5\nsmokepass123\nsmokepass123\n' | "$ROOT/build/blogd" init >/dev/null 2>&1
"$ROOT/build/blogd" seed >/dev/null
"$ROOT/build/blogd" "$APORT" >/dev/null 2>&1 &
APID=$!
cd "$ROOT"
sleep 0.4
A="http://127.0.0.1:$APORT"
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
check "hostile markdown stays escaped"     bash -c "P=\$(curl -s -b '$JAR' --data-urlencode csrf=$CSRF --data-urlencode 'md=[x](javascript:alert(1)) <script>' --data-urlencode title=t '$A/admin/preview'); echo \"\$P\" | grep -q '&lt;script&gt;' && ! echo \"\$P\" | grep -q 'href=\"javascript'"
# configurable banner
expect_code "settings save with banner" 303 -b "$JAR" --data-urlencode "csrf=$CSRF" \
    --data-urlencode "title=Smoke Blog" --data-urlencode ppp=5 --data-urlencode "banner=CUSTOM-BANNER-XYZ" "$A/admin/settings"
check "custom banner shows on the site"    bash -c "curl -s $A/ | grep -q 'CUSTOM-BANNER-XYZ'"
# theme switching
check "default theme is retro"             bash -c "curl -s $A/ | grep -q 'class=\"min-h-screen theme-retro\"'"
expect_code "switch to sucre theme"    303 -b "$JAR" --data-urlencode "csrf=$CSRF" \
    --data-urlencode "title=Smoke Blog" --data-urlencode ppp=5 --data-urlencode theme=sucre "$A/admin/settings"
check "sucre theme now on the site"        bash -c "curl -s $A/ | grep -q 'class=\"min-h-screen theme-sucre\"'"
check "sucre radio pre-checked in form"    bash -c "curl -s -b '$JAR' $A/admin/settings | grep -q 'value=\"sucre\" checked'"
expect_code "switch back to retro"     303 -b "$JAR" --data-urlencode "csrf=$CSRF" \
    --data-urlencode "title=Smoke Blog" --data-urlencode ppp=5 --data-urlencode theme=retro "$A/admin/settings"
# localization (site-wide, from settings)
check "default locale is en-US"            bash -c "curl -s $A/ | grep -q '<html lang=\"en\">' && curl -s $A/ | grep -Eq 'class=\"meta text-xs mt-1\">[A-Z][a-z]+ [0-9]+, [0-9]{4}'"
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
expect_code "logout works"             303 -b "$JAR" --data-urlencode "csrf=$CSRF" "$A/admin/logout"
expect_code "session is gone after logout" 303 -b "$JAR" "$A/admin"
kill "$APID" 2>/dev/null || true

if [ "$fail" = 0 ]; then
    echo "smoke: all checks passed"
else
    echo "smoke: FAILURES"
    exit 1
fi
