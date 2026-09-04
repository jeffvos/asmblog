#!/usr/bin/env bash
# Run a throwaway, seeded copy of the site for eyeballing changes:
# fresh store in a temp dir (never touches ./data), demo posts, admin
# password "previewpass1". Usage: tools/preview.sh [port] [site-url]
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
PORT="${1:-8080}"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
cp -r templates static "$T/"
cd "$T"
printf 'Preview Blog\n5\npreviewpass1\npreviewpass1\n' | \
    BLOGD_SITE_URL="${2:-}" "$ROOT/build/blogd" init >/dev/null
"$ROOT/build/blogd" seed >/dev/null
exec "$ROOT/build/blogd" "$PORT"
