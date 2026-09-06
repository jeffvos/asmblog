#!/usr/bin/env bash
# fuzz.sh — robustness fuzzer for the HTTP and markdown parsers.
#
# No AFL++ here, so this is a black-box mutation fuzzer: it fires
# thousands of malformed/adversarial requests at a live server and at
# the markdown renderer (via /admin/preview), then asserts the process
# is still alive and still serving. A parser bug (out-of-bounds read,
# bad jump, arena overflow) shows up as a dead server or a 000 curl.
#
# Usage: tests/fuzz.sh [iterations] [port]
set -uo pipefail
trap '' PIPE            # the server closes malformed conns mid-write
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
ITERS="${1:-3000}"
PORT="${2:-$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')}"

TMP="$(mktemp -d)"
cp -r "$ROOT/templates" "$ROOT/static" "$TMP/"
cd "$TMP"
printf 'Fuzz Blog\n5\nfuzzpass12345\nfuzzpass12345\n' | "$ROOT/build/blogd" init >/dev/null 2>&1
"$ROOT/build/blogd" seed >/dev/null
"$ROOT/build/blogd" "$PORT" >/dev/null 2>&1 &
SRV=$!
trap 'kill -9 "$SRV" 2>/dev/null; rm -rf "$TMP"' EXIT
for i in $(seq 100); do
    curl -s -o /dev/null "http://127.0.0.1:$PORT/health" 2>/dev/null && break
    sleep 0.1
done

if ! kill -0 "$SRV" 2>/dev/null; then echo "fuzz: server failed to start"; exit 1; fi

# authenticate so /admin/preview (the markdown parser entrypoint) is reachable
curl -s -c "$TMP/j" -o /dev/null -d password=fuzzpass12345 "http://127.0.0.1:$PORT/admin/login"
CSRF="$(curl -s -b "$TMP/j" "http://127.0.0.1:$PORT/admin" | grep -o '[0-9a-f]\{64\}' | head -1)"

alive() { kill -0 "$SRV" 2>/dev/null && [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:$PORT/health")" = 200 ]; }

# 1) raw malformed HTTP over the socket (needs bash /dev/tcp)
echo "phase 1: $ITERS malformed raw requests"
paths=( / /page/ /page/-1 /page/999999999999 /post/ /post/../etc/passwd '/search?q=' /tag/ /admin /admin/edit/x /feed.xml /static/main.css )
methods=( GET POST PUT HEAD DELETE FNORD '' )
for i in $(seq 1 "$ITERS"); do
    m="${methods[$((RANDOM % ${#methods[@]}))]}"
    p="${paths[$((RANDOM % ${#paths[@]}))]}"
    n=$((RANDOM % 400))
    junk="$(head -c "$n" /dev/urandom | tr -d '\0')"
    case $((RANDOM % 5)) in
      0) req="$m $p HTTP/1.1\r\nHost: x\r\n\r\n" ;;
      1) req="$m $p$junk HTTP/1.1\r\n\r\n" ;;
      2) req="$junk" ;;
      3) req="$m $p HTTP/1.1\r\nContent-Length: 999999\r\n\r\n$junk" ;;
      4) req="GET $p HTTP/9.9\r\n$junk: $junk\r\n\r\n" ;;
    esac
    printf "%b" "$req" > "/dev/tcp/127.0.0.1/$PORT" 2>/dev/null || true
    if (( i % 500 == 0 )); then
        alive || { echo "fuzz: DIED after $i raw requests"; exit 1; }
        printf '  %d ok\n' "$i"
    fi
done
alive || { echo "fuzz: server died during phase 1"; exit 1; }

# 2) adversarial markdown through the real renderer
echo "phase 2: markdown parser torture"
md_cases=(
  '**' '*' '`' '[' '](' '[x](' '[x](javascript:alert(1))' '###### h'
  '```' '```
unterminated' '> > > nested' '-
-
-' '*a**b*c**d' '[[[[[[[[' '`````````'
  '# <script>alert(1)</script>' '[a](vbscript:x)' '[a](  javascript:x)'
  '****bold nested****' '1. 2. 3. 4. 5.' '---'
)
for i in $(seq 1 1200); do
    case $((RANDOM % 3)) in
      0) md="${md_cases[$((RANDOM % ${#md_cases[@]}))]}" ;;
      1) md="$(head -c $((RANDOM % 2000)) /dev/urandom | tr -dc '[:print:]#*`[]()<>&_-')" ;;
      2) md="$(for _ in $(seq $((RANDOM%40))); do printf '%s' "${md_cases[$((RANDOM % ${#md_cases[@]}))]}"; done)" ;;
    esac
    body="$(curl -s -b "$TMP/j" --max-time 3 --data-urlencode "csrf=$CSRF" --data-urlencode title=f --data-urlencode "md=$md" "http://127.0.0.1:$PORT/admin/preview")"
    # any output must never contain an executable scheme or raw script tag
    if printf '%s' "$body" | grep -qiE 'href="javascript:|href="vbscript:|<script>'; then
        echo "fuzz: XSS LEAK for md=<<$md>>"; exit 1
    fi
    if (( i % 300 == 0 )); then
        alive || { echo "fuzz: DIED after $i markdown cases"; exit 1; }
        printf '  %d ok\n' "$i"
    fi
done
alive || { echo "fuzz: server died during phase 2"; exit 1; }

echo "fuzz: survived $ITERS raw + 1200 markdown cases, server healthy"
