# syntax=docker/dockerfile:1
#
# blogd — minimal Alpine image: the assembly binary, its templates and
# stylesheet, libsodium (the one runtime dependency), libvips's
# vipsthumbnail for image uploads (driven through tools/imgconv by an
# unsandboxed helper process), and busybox for the entrypoint. No
# reverse proxy: terminate TLS outside the container (see
# deploy/Caddyfile, deploy/nginx.conf).
#
# The build stage doubles as the test harness for the musl toolchain:
# it runs the store/crypto selftest and then boots the server with the
# seccomp sandbox active and performs a real Argon2id login. A syscall
# missing from the allowlist under musl fails the build, not production.

ARG ALPINE_VERSION=3.20

# ---------------------------------------------------------------- build
FROM alpine:${ALPINE_VERSION} AS build
# Tailwind standalone CLI (musl build), pinned and checksummed; the CI
# workflow pins the glibc build of the same release. Bump both together.
ARG TAILWIND_VERSION=v4.3.3
ARG TAILWIND_SHA256=a04d34ceacc8f52cbe8920ad846cdeb61d3d0021dba32db0d1f77c9d9fad7a6c
RUN apk add --no-cache nasm make binutils libsodium-dev gzip brotli curl python3 vips-tools

WORKDIR /src
COPY Makefile ./
COPY src ./src
COPY assets ./assets
COPY templates ./templates
COPY static ./static
COPY tests ./tests

COPY tools/mkcss.py tools/contrast.py tools/imgconv ./tools/

# Tailwind standalone CLI (musl build) for the CSS step
RUN mkdir -p tools static && \
    curl -fsSL -o tools/tailwindcss \
      "https://github.com/tailwindlabs/tailwindcss/releases/download/${TAILWIND_VERSION}/tailwindcss-linux-x64-musl" && \
    echo "${TAILWIND_SHA256}  tools/tailwindcss" | sha256sum -c - && \
    chmod +x tools/tailwindcss

RUN make

# 1) store + Argon2id selftest under musl
RUN mkdir -p /tmp/selftest && cd /tmp/selftest && /src/build/blogd selftest

# 2) boot with seccomp on, init a password, log in through the mailbox,
#    upload an image through the helper + vipsthumbnail and fetch it back
RUN mkdir -p /tmp/boot && cd /tmp/boot && cp -r /src/templates /src/static . && \
    printf 'build test\n5\nbuildtestpw1\nbuildtestpw1\n' | /src/build/blogd init && \
    ( BLOGD_IMGCONV=/src/tools/imgconv /src/build/blogd 8080 2 & echo $! > pid ) && sleep 0.7 && \
    curl -fsS -o /dev/null http://127.0.0.1:8080/health && \
    CODE=$(curl -s -c jar -o /dev/null -w '%{http_code}' -d password=buildtestpw1 http://127.0.0.1:8080/admin/login) && \
    echo "in-image login -> $CODE" && [ "$CODE" = "303" ] && \
    CSRF=$(curl -s -b jar http://127.0.0.1:8080/admin | grep -o '[0-9a-f]\{64\}' | head -1) && \
    python3 /src/tests/mkpng.py 900 600 > t.png && \
    UP=$(curl -s -b jar -o /dev/null -w '%{http_code} %{redirect_url}' -F csrf="$CSRF" -F file=@t.png http://127.0.0.1:8080/admin/media) && \
    echo "in-image upload -> $UP" && [ "$UP" = "303 http://127.0.0.1:8080/admin/media?uploaded=1" ] && \
    curl -fsS -o /dev/null http://127.0.0.1:8080/media/1.webp && \
    curl -fsS -o /dev/null http://127.0.0.1:8080/media/1-s.png && \
    kill "$(cat pid)"

# -------------------------------------------------------------- runtime
FROM alpine:${ALPINE_VERSION}
RUN apk add --no-cache libsodium vips-tools && \
    adduser -D -H -u 10001 -s /sbin/nologin blogd && \
    mkdir -p /var/lib/blogd/data && chown -R blogd:blogd /var/lib/blogd

WORKDIR /var/lib/blogd
COPY --from=build --chown=blogd:blogd /src/build/blogd ./blogd
COPY --from=build --chown=blogd:blogd /src/templates ./templates
COPY --from=build --chown=blogd:blogd /src/static ./static
COPY --chmod=755 deploy/docker-entrypoint.sh /usr/local/bin/blogd-entrypoint
COPY --chmod=755 tools/imgconv /usr/local/bin/blogd-imgconv

USER blogd
ENV BLOGD_BIND_ALL=1 \
    BLOGD_PORT=8080 \
    BLOGD_THREADS=2 \
    BLOGD_IMGCONV=/usr/local/bin/blogd-imgconv
EXPOSE 8080
VOLUME ["/var/lib/blogd/data"]
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s \
    CMD wget -qO- http://127.0.0.1:8080/health >/dev/null || exit 1

ENTRYPOINT ["blogd-entrypoint"]
