#!/usr/bin/env bash
# Run a throwaway, seeded copy of the site for eyeballing changes:
# fresh store in a temp dir (never touches ./data), demo posts, admin
# password "previewpass1". When an image converter is available, two
# test pictures are uploaded and a "Pictures" post embeds them, so the
# figures and the lightbox can be seen in every theme.
# Usage: tools/preview.sh [port] [site-url]
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
PORT="${1:-8080}"
T="$(mktemp -d)"
trap 'kill "$PID" 2>/dev/null || true; rm -rf "$T"' EXIT
cp -r templates static "$T/"
cd "$T"
printf 'Preview Blog\n5\npreviewpass1\npreviewpass1\n' | \
    BLOGD_SITE_URL="${2:-}" "$ROOT/build/blogd" init >/dev/null
"$ROOT/build/blogd" seed >/dev/null
"$ROOT/build/blogd" "$PORT" &
PID=$!
B="http://127.0.0.1:$PORT"
for i in $(seq 100); do curl -s -o /dev/null "$B/health" 2>/dev/null && break; sleep 0.1; done
if sh "$ROOT/tools/imgconv" --check 2>/dev/null; then
    python3 "$ROOT/tests/mkpng.py" 1600 1000 3 > "$T/harbour.png"
    python3 "$ROOT/tests/mkpng.py" 900 1200 11 > "$T/tower.png"
    curl -s -c "$T/jar" -o /dev/null -d password=previewpass1 "$B/admin/login"
    CSRF="$(curl -s -b "$T/jar" "$B/admin" | grep -o '[0-9a-f]\{64\}' | head -1)"
    curl -s -o /dev/null -b "$T/jar" -F "csrf=$CSRF" -F "file=@$T/harbour.png" "$B/admin/media"
    curl -s -o /dev/null -b "$T/jar" -F "csrf=$CSRF" -F "file=@$T/tower.png" "$B/admin/media"
    curl -s -o /dev/null -b "$T/jar" --data-urlencode "csrf=$CSRF" --data-urlencode id=0 \
        --data-urlencode "title=Pictures from the harbour" --data-urlencode slug=pictures --data-urlencode tags=photos \
        --data-urlencode "md=A first look at the self-hosted pictures. Click one to open it full size; the backdrop, the × or the back button close it again.

![The harbour at dusk, seen from the incline](/media/1)

The second one sits inline: ![the tower](/media/2) between words of a paragraph, and this text keeps flowing after it. Nothing on this page is JavaScript." \
        --data-urlencode action=publish "$B/admin/save"
    rm -f "$T/jar"
fi
wait "$PID"
