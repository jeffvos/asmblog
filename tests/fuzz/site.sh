#!/usr/bin/env bash
# site.sh <dir> — a throwaway site directory for the http harness: the
# templates and stylesheets, an initialised store (the password does not
# matter: the harness's crypto stub accepts "hunter22") and the demo posts.
set -euo pipefail
cd "$(dirname "$0")/../.."
D="$1"
rm -rf "$D"
mkdir -p "$D"
cp -r templates static "$D/"
( cd "$D" && printf 'Fuzz Blog\n5\nhunter22\nhunter22\n' | "$OLDPWD/build/blogd" init >/dev/null 2>&1 \
          && "$OLDPWD/build/blogd" seed >/dev/null )
