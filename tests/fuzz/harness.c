/*
 * harness.c — fuzz harnesses around blogd's parsers, for AFL++ and for a
 * plain corpus replay. One source, two binaries:
 *
 *   build/fuzz_http <site dir> [input | -]      the request path
 *   build/fuzz_md   [input | -]                 the markdown renderer (-DFUZZ_MD)
 *
 * The target is hand-written assembly, so there is nothing for afl-cc to
 * instrument: these binaries are for AFL++'s binary-only modes (FRIDA:
 * afl-fuzz -O, QEMU: -Q); tests/fuzz/afl.sh sets that up, with run_one()
 * as the persistent-mode entry point. On their own they are a sanitizer
 * of sorts: every input sits against PROT_NONE guard pages, so an
 * out-of-bounds read or write is a SIGSEGV instead of a quiet read of
 * whatever is next in memory, and every response is checked against the
 * invariants the network layer relies on (a status line, a header block
 * that ends, Content-Length that matches the body, everything inside the
 * outbuf). A violated invariant abort()s, which AFL files as a crash.
 *
 * Linked against every object of the server except main.o (the entry
 * point), net.o (sockets) and crypto.o (libsodium); stubs.asm supplies
 * the globals main.o owns and a crypto that accepts one password
 * ("hunter22"), so the fuzzer can log in and reach every admin route.
 * In the request bytes, 64 x 'A' is replaced by a live session id and
 * 64 x 'C' by its CSRF token before the run, so the corpus can carry
 * authenticated requests without knowing tonight's random tokens.
 *
 * The store the site directory holds is opened for real, then its
 * descriptor is pointed at /dev/null: saves and deletes run their whole
 * path (records built, checksummed, "written", in-memory indexes
 * updated) without the campaign growing a file on disk.
 */
#define _GNU_SOURCE
#include <dirent.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include "conn.h"               /* generated from src/conn.inc, src/store.inc */

#define PAGE 4096UL
#define INPUT_MAX (1UL << 20)   /* what run_one accepts; afl.sh caps -G below it */

/* ---- the assembly ------------------------------------------------------ */
extern long store_open(void);
extern long tmpl_load_all(void);
extern long load_static(void);
extern void hits_init(void);
extern void http_handle(uint8_t *ctx, uint64_t head_len, uint64_t body_len);
extern int64_t http_body_len(uint8_t *ctx, uint64_t head_len);
extern void build_page(uint8_t *ctx, uint64_t idx);
extern void session_create(char *sid64, char *csrf64);
extern void login_ok(void);
extern void w_init(void *w, void *start, void *end);
extern void md_render(void *w, const void *md, uint64_t len);
extern uint64_t md_excerpt(void *dst, uint64_t cap, const void *md, uint64_t len);
extern char **envp;             /* stubs.asm; main.asm's in the real binary */

static uint8_t input[INPUT_MAX];

static void die(const char *what) {
    perror(what);
    exit(2);
}

static void fail(const char *what) {
    fprintf(stderr, "harness: invariant violated: %s\n", what);
    abort();
}

/* a mapping of n bytes with a PROT_NONE page on both sides */
static uint8_t *guarded(size_t n) {
    size_t body = (n + PAGE - 1) & ~(PAGE - 1);
    uint8_t *m = mmap(NULL, body + 2 * PAGE, PROT_READ | PROT_WRITE,
                      MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (m == MAP_FAILED) die("mmap");
    if (mprotect(m, PAGE, PROT_NONE) || mprotect(m + PAGE + body, PAGE, PROT_NONE))
        die("mprotect");
    return m + PAGE;
}

static size_t read_all(int fd) {
    size_t n = 0;
    for (;;) {
        ssize_t r = read(fd, input + n, INPUT_MAX - n);
        if (r < 0) die("read");
        if (r == 0 || (n += (size_t)r) == INPUT_MAX) return n;
    }
}

#ifndef FUZZ_MD
/* ======================================================================
 * HTTP: the framing net.asm does, then http_handle, then the checks.
 * ==================================================================== */

static uint8_t *ctx;            /* CTX_TOTAL bytes, guard page after */
static char sid[65], csrf[65];

/* find_crlf2 as net.asm has it: offset just past the first CRLFCRLF, or 0 */
static size_t find_crlf2(const uint8_t *p, size_t len) {
    for (size_t i = 0; i + 4 <= len; i++)
        if (p[i] == '\r' && p[i + 1] == '\n' && p[i + 2] == '\r' && p[i + 3] == '\n')
            return i + 4;
    return 0;
}

static const uint8_t *memfind(const uint8_t *h, size_t hl, const char *n) {
    size_t nl = strlen(n);
    for (size_t i = 0; i + nl <= hl; i++)
        if (memcmp(h + i, n, nl) == 0) return h + i;
    return NULL;
}

/* the response staged in the outbuf must be one the socket layer can send */
static void check_response(void) {
    uint64_t start = *(uint64_t *)(ctx + CTX_OUT_START);
    uint64_t len = *(uint64_t *)(ctx + CTX_OUT_LEN);
    if (start > CTX_OUTBUF_SZ || len > CTX_OUTBUF_SZ - start) fail("response outside the outbuf");
    if (len < 16) fail("response too short for a status line");
    const uint8_t *out = ctx + CTX_OUT + start;
    if (memcmp(out, "HTTP/1.1 ", 9) != 0) fail("no status line");
    for (int i = 9; i < 12; i++)
        if (out[i] < '0' || out[i] > '9') fail("status is not three digits");
    if (out[12] != ' ') fail("status not followed by a space");
    size_t hdr = find_crlf2(out, len < 8192 ? len : 8192);
    if (!hdr) fail("header block never ends");
    if (memcmp(out, "HTTP/1.1 100", 12) == 0) return;  /* net.asm sends those itself */
    uint64_t body = len - hdr;
    uint64_t file = *(uint64_t *)(ctx + CTX_FILE_P) ? *(uint64_t *)(ctx + CTX_FILE_L) : 0;
    const uint8_t *cl = memfind(out, hdr, "\r\nContent-Length: ");
    if (ctx[CTX_HEAD]) {
        if (body || file) fail("HEAD response carries a body");
        return;
    }
    if (cl) {
        uint64_t n = strtoull((const char *)cl + 18, NULL, 10);
        if (n != body + file) fail("Content-Length does not match the body");
    } else if (body || file) {
        fail("a body without Content-Length");
    }
}

/* the connection state accept() and http_handle expect */
static void reset_ctx(void) {
    memset(ctx, 0, CTX_IN);
    *(int32_t *)(ctx + CTX_FD) = -1;            /* nothing here touches a socket */
    ctx[CTX_KEEP] = 1;
    *(int32_t *)(ctx + CTX_SPOOL_FD) = -1;
    *(int64_t *)(ctx + CTX_LAST) = time(NULL);
}

static void substitute(uint8_t *p, size_t len, char c, const char *tok) {
    size_t run = 0;
    for (size_t i = 0; i < len; i++) {
        if (p[i] == (uint8_t)c) {
            if (++run == 64) { memcpy(p + i - 63, tok, 64); run = 0; }
        } else {
            run = 0;
        }
    }
}

/* run_one(buf, len): AFL_FRIDA_PERSISTENT_ADDR points here. */
__attribute__((noinline, used))
void run_one(uint8_t *buf, size_t len) {
    if (len > CTX_INBUF_SZ) len = CTX_INBUF_SZ;
    login_ok();                                 /* no backoff carried over */
    session_create(sid, csrf);                  /* a fresh admin session */
    reset_ctx();
    memcpy(ctx + CTX_IN, buf, len);
    substitute(ctx + CTX_IN, len, 'A', sid);
    substitute(ctx + CTX_IN, len, 'C', csrf);
    /* whole inbuf pages past the input become guard pages for this run */
    uintptr_t g0 = ((uintptr_t)(ctx + CTX_IN + len) + PAGE - 1) & ~(PAGE - 1);
    uintptr_t g1 = (uintptr_t)(ctx + CTX_OUT) & ~(PAGE - 1);
    if (g0 < g1 && mprotect((void *)g0, g1 - g0, PROT_NONE)) die("mprotect");
    size_t used = len;
    for (;;) {
        *(uint64_t *)(ctx + CTX_IN_USED) = used;
        size_t head = find_crlf2(ctx + CTX_IN, used < HTTP_HEAD_MAX ? used : HTTP_HEAD_MAX);
        if (!head) {
            if (used < HTTP_HEAD_MAX) break;    /* incomplete: the server would wait */
            ctx[CTX_KEEP] = 0; build_page(ctx, 7); check_response();    /* 431 */
            break;
        }
        int64_t body = http_body_len(ctx, head);
        int reject = 0;
        if (body == -1) reject = 4;             /* 400 */
        else if (body == -2) reject = 8;        /* 411 */
        else if (body > HTTP_BODY_MAX || head + (uint64_t)body > CTX_INBUF_SZ) reject = 6; /* 413 */
        if (reject) {
            ctx[CTX_KEEP] = 0; build_page(ctx, reject); check_response();
            break;
        }
        if (head + (size_t)body > used) break;  /* body still arriving */
        ctx[CTX_CONT] = 0;
        http_handle(ctx, head, (uint64_t)body);
        check_response();
        uint64_t fp = *(uint64_t *)(ctx + CTX_FILE_P);
        if (fp) {                               /* a mapped rendition */
            munmap((void *)fp, *(uint64_t *)(ctx + CTX_FILE_L));
            *(uint64_t *)(ctx + CTX_FILE_P) = 0;
        }
        *(uint64_t *)(ctx + CTX_OUT_LEN) = 0;
        *(uint64_t *)(ctx + CTX_OUT_START) = 0;
        used -= head + (size_t)body;
        if (!used || !ctx[CTX_KEEP]) break;
        memmove(ctx + CTX_IN, ctx + CTX_IN + head + body, used);    /* pipelined */
    }
    if (g0 < g1 && mprotect((void *)g0, g1 - g0, PROT_READ | PROT_WRITE)) die("mprotect");
}

/* point the store's descriptor at /dev/null: the store was loaded, every
 * later write goes nowhere (found through /proc: store_fd is private) */
static void detach_store(void) {
    DIR *d = opendir("/proc/self/fd");
    if (!d) die("opendir");
    struct dirent *e;
    char link[300], target[256];
    int fd = -1;
    while ((e = readdir(d))) {
        snprintf(link, sizeof link, "/proc/self/fd/%s", e->d_name);
        ssize_t n = readlink(link, target, sizeof target - 1);
        if (n <= 0) continue;
        target[n] = 0;
        size_t tl = strlen(target);
        if (tl >= 14 && strcmp(target + tl - 14, "data/store.blg") == 0) fd = atoi(e->d_name);
    }
    closedir(d);
    if (fd < 0) { fprintf(stderr, "harness: cannot find the store descriptor\n"); exit(2); }
    int null = open("/dev/null", O_RDWR);
    if (null < 0 || dup2(null, fd) < 0) die("dup2");
    close(null);
}

int main(int argc, char **argv, char **env) {
    envp = env;
    if (argc < 2) {
        fprintf(stderr, "usage: fuzz_http <site dir> [input | -]\n");
        return 2;
    }
    int fd = 0;                                 /* the input, before the chdir */
    if (argc > 2 && strcmp(argv[2], "-") != 0 && (fd = open(argv[2], O_RDONLY)) < 0) die("open");
    if (chdir(argv[1])) die("chdir");
    if (store_open()) { fprintf(stderr, "harness: store_open failed\n"); return 2; }
    detach_store();
    if (tmpl_load_all()) { fprintf(stderr, "harness: templates failed to load\n"); return 2; }
    if (load_static()) { fprintf(stderr, "harness: static/ failed to load\n"); return 2; }
    hits_init();
    ctx = guarded(CTX_TOTAL);
    size_t n = read_all(fd);
    run_one(input, n);
    return 0;
}

#else
/* ======================================================================
 * Markdown: md_render and md_excerpt against exact guard pages.
 * ==================================================================== */

#define OUT_SZ (CTX_MDHTML_END - CTX_MDHTML_OFF)  /* what a request gives the renderer */
/* EXC_CAP comes from conn.h (store.inc): the buffers hold EXC_CAP + 3 */

static uint8_t *out;            /* OUT_SZ, guarded */
static uint8_t *exc;            /* EXC_CAP + 3 at the end of a page, guard after */

static void check_html(const uint8_t *p, size_t n) {
    size_t lt = 0, gt = 0;
    for (size_t i = 0; i < n; i++) {
        if (p[i] == '<') lt++;
        else if (p[i] == '>') gt++;
    }
    if (lt != gt) fail("unbalanced < and > in rendered html");
    for (size_t i = 0; i + 7 <= n; i++)
        if (memcmp(p + i, "<script", 7) == 0) fail("a <script tag in rendered html");
    for (size_t i = 0; i + 17 <= n; i++)
        if (memcmp(p + i, "href=\"javascript:", 17) == 0) fail("a javascript: link in rendered html");
}

/* render md[len] where it sits (the caller placed it against a guard) */
static void render_at(const uint8_t *md, size_t len) {
    uint8_t w[32];                              /* md.asm uses [w+17] and [w+20] */
    memset(w, 0, sizeof w);
    w_init(w, out, out + OUT_SZ);
    md_render(w, md, len);
    uint8_t *cur = *(uint8_t **)w;
    if (cur < out || cur > out + OUT_SZ) fail("writer cursor outside the output buffer");
    if (!w[16]) check_html(out, (size_t)(cur - out));
    uint64_t n = md_excerpt(exc, EXC_CAP, md, len);
    if (n > EXC_CAP + 3) fail("excerpt longer than its buffer");
}

__attribute__((noinline, used))
void run_one(uint8_t *buf, size_t len) {
    if (len > MD_MAX) len = MD_MAX;
    /* tail-aligned: the byte after the input is unmapped */
    size_t body = (len + PAGE - 1) & ~(PAGE - 1);
    if (!body) body = PAGE;
    uint8_t *m = guarded(body);
    uint8_t *tail = m + body - len;
    memcpy(tail, buf, len);
    render_at(tail, len);
    /* head-aligned: the byte before the input is unmapped */
    memset(m, 0, body);
    memcpy(m, buf, len);
    render_at(m, len);
    munmap(m - PAGE, body + 2 * PAGE);
}

int main(int argc, char **argv, char **env) {
    envp = env;
    out = guarded(OUT_SZ);
    uint8_t *e = guarded(PAGE);
    exc = e + PAGE - (EXC_CAP + 3);
    int fd = 0;
    if (argc > 1 && strcmp(argv[1], "-") != 0 && (fd = open(argv[1], O_RDONLY)) < 0) die("open");
    size_t n = read_all(fd);
    run_one(input, n);
    return 0;
}
#endif
