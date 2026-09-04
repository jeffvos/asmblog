#!/bin/sh
# blogd container entrypoint.
#
# First boot (no data/store.blg in the volume): initialize the store with
# the admin password from BLOGD_ADMIN_PASSWORD (min 8 chars), then serve.
# Every later boot just serves. The password is never baked into an
# image layer — it lives only in the volume as an Argon2id hash.
# BLOGD_SITE_URL (optional) is read by `blogd init` from the environment
# and becomes the public origin for canonical/Open Graph/feed/sitemap
# URLs; it can be changed later in /admin/settings. The visitor counter
# lives in the same volume (data/hits.blg).
set -eu
cd /var/lib/blogd

if [ ! -e data/store.blg ]; then
    : "${BLOGD_ADMIN_PASSWORD:=changeme-blogd}"
    if [ "$BLOGD_ADMIN_PASSWORD" = "changeme-blogd" ]; then
        echo "blogd: WARNING using the default admin password; set BLOGD_ADMIN_PASSWORD" >&2
    fi
    printf '%s\n%s\n%s\n%s\n' \
        "${BLOGD_SITE_TITLE:-My Retro Blog}" \
        "${BLOGD_POSTS_PER_PAGE:-5}" \
        "$BLOGD_ADMIN_PASSWORD" \
        "$BLOGD_ADMIN_PASSWORD" | ./blogd init
    if [ "${BLOGD_SEED:-0}" = "1" ]; then
        ./blogd seed
    fi
fi

exec ./blogd "${BLOGD_PORT:-8080}" "${BLOGD_THREADS:-2}"
