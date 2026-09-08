#!/usr/bin/env python3
"""Write the seed corpus for the fuzz harnesses (tests/fuzz/corpus/).

One file per request shape / markdown shape the server knows. In the
HTTP seeds, 64 x 'A' stands for a live session id and 64 x 'C' for its
CSRF token: the harness substitutes the real ones (harness.c). The
password the harness's crypto stub accepts is "hunter22".

Run it after adding a case; the corpus is committed so AFL campaigns
are reproducible.
"""
import os, urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
SID = "A" * 64
CSRF = "C" * 64


def req(method, path, headers=(), body=b"", version="HTTP/1.1", host="t.example"):
    lines = [f"{method} {path} {version}"]
    if host is not None:
        lines.append(f"Host: {host}")
    lines += list(headers)
    if body:
        lines.append(f"Content-Length: {len(body)}")
    return ("\r\n".join(lines) + "\r\n\r\n").encode() + body


def form(**fields):
    return urllib.parse.urlencode(fields).encode()


def admin_post(path, **fields):
    return req("POST", path, [f"Cookie: sid={SID}", "Content-Type: application/x-www-form-urlencoded"],
               form(csrf=CSRF, **fields))


MD_IMAGES = ("## Hello World!\n\n```rust\nfn main() {}\n```\n\n"
             "![A photo](https://live.staticflickr.com/1/2_b.jpg)\n\n"
             "Inline ![local](/static/og.png) and ![evil](https://evil.example/x.png) and ![pr](//evil.example/x).\n\n"
             "![Sunset](/media/1)\n\nText ![tiny](/media/3) and ![gone](/media/77).")
MD_FLICKR = ('<a data-flickr-embed="true" href="https://www.flickr.com/photos/x/1/">'
             '<img src="https://live.staticflickr.com/1/2_b.jpg" alt="pic"/></a>'
             '<script src="//embedr.flickr.com/x.js"></script>')

HTTP = {
    "get_root": req("GET", "/"),
    "get_post": req("GET", "/post/why-assembly", ["X-Forwarded-Proto: https", "Accept-Encoding: gzip, br"]),
    "get_page2_http10": req("GET", "/page/2", version="HTTP/1.0"),
    "get_tag_page1": req("GET", "/tag/asm/page/1"),
    "get_tag": req("GET", "/tag/retro", ["Connection: close"]),
    "search": req("GET", "/search?q=%3Cscript%3E+MARQUEE&x=1"),
    "feed_ims": req("GET", "/feed.xml", ["If-Modified-Since: Thu, 01 Jan 1970 00:00:00 GMT"]),
    "css_versioned": req("GET", "/static/main.css?v=deadbeef", ["Accept-Encoding: gzip;q=0, br"]),
    "css_inm": req("GET", "/static/main.css", ["Accept-Encoding: gzip", 'If-None-Match: "00000000"']),
    "pipelined": req("GET", "/robots.txt") + req("GET", "/sitemap.xml", ["X-Forwarded-Proto: https"]),
    "head_root": req("HEAD", "/"),
    "conditional": req("GET", "/", ['If-None-Match: W/"18d3-1234"']),
    "media": req("GET", "/media/1.webp", ['If-None-Match: "1.webp"']),
    "media_bad": req("GET", "/media/../store.blg"),
    "manifest_hits_fav": req("GET", "/manifest.webmanifest") + req("GET", "/hits.svg") + req("GET", "/favicon.ico?v=theme-sucre"),
    "sitemap_n": req("GET", "/sitemap-1.xml"),
    "trailing_slash": req("GET", "/tag/asm/"),
    "not_found": req("GET", "/nope/%zz/%00"),
    "no_host": req("GET", "/", host=None),
    "login_ok": req("POST", "/admin/login", ["Content-Type: application/x-www-form-urlencoded"], form(password="hunter22")),
    "login_bad": req("POST", "/admin/login", [], form(password="wrongwrong1")),
    "admin_dash": req("GET", "/admin?saved=1", [f"Cookie: sid={SID}"]),
    "admin_nosession": req("GET", "/admin/settings", ["Cookie: sid=deadbeef"]),
    "admin_edit": req("GET", "/admin/edit/2", [f"Cookie: a=b; sid={SID}; c=d"]),
    "admin_new": req("GET", "/admin/new", [f"Cookie: sid={SID}"]),
    "save_publish": admin_post("/admin/save", id="0", title="Fuzz Post", slug="", tags="fuzz, asm",
                              md="Hello **world** from [here](/about)\n\n" + MD_IMAGES, action="publish"),
    "save_draft": admin_post("/admin/save", id="2", title="Edited", slug="why-assembly", tags="asm", md="# Hi\n\n- a\n- b", action="draft"),
    "save_bad_csrf": req("POST", "/admin/save", [f"Cookie: sid={SID}"], form(csrf="deadbeef", id="1", title="x", md="y")),
    "preview": admin_post("/admin/preview", title="t", md=MD_IMAGES + "\n\n" + MD_FLICKR),
    "settings": admin_post("/admin/settings", title="Fuzz Blog", ppp="3", banner="CUSTOM", theme="bogota",
                           locale="es", url="https://fuzz.example/", imgmax="800"),
    "settings_password": admin_post("/admin/settings", title="Fuzz Blog", ppp="5", password="newpassword1", password2="newpassword1"),
    "delete_confirm": req("GET", "/admin/delete/1", [f"Cookie: sid={SID}"]),
    "delete": admin_post("/admin/delete", id="1"),
    "media_lib": req("GET", "/admin/media?page=2", [f"Cookie: sid={SID}"]),
    "media_upload": req("POST", "/admin/media", [f"Cookie: sid={SID}", "Content-Type: multipart/form-data; boundary=XyZ"],
                        b"--XyZ\r\nContent-Disposition: form-data; name=\"csrf\"\r\n\r\n" + CSRF.encode() +
                        b"\r\n--XyZ\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.png\"\r\nContent-Type: image/png\r\n\r\n"
                        b"\x89PNG\r\n\x1a\n" + b"\0" * 64 + b"\r\n--XyZ--\r\n"),
    "media_delete": admin_post("/admin/media/delete", id="1"),
    "logout": admin_post("/admin/logout"),
    "expect_continue": req("POST", "/admin/login", ["Expect: 100-continue"], form(password="hunter22")),
    "bad_version": b"GET / HTTP/2.0\r\nHost: x\r\n\r\n",
    "bad_method": req("PUT", "/"),
    "bad_chunked": b"POST /admin/login HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n",
    "bad_length": b"POST /admin/login HTTP/1.1\r\nHost: x\r\nContent-Length: 9x\r\n\r\n",
    "bad_big": b"POST /admin/login HTTP/1.1\r\nHost: x\r\nContent-Length: 999999\r\n\r\n",
    "bad_garbage": b"\x00\xff GARBAGE\r\n\r\n",
    "long_head": b"GET / HTTP/1.1\r\nHost: x\r\nX-Pad: " + b"a" * 9000,
}

MD = {
    "images": MD_IMAGES,
    "flickr": MD_FLICKR + "\n\n" + MD_FLICKR.replace("www.flickr.com", "phish.example").replace("live.staticflickr.com", "evil.com"),
    "blocks": "# Title\n\n## Sub *em* **strong**\n\n> quote\n> more\n\n- one\n- two `code`\n\n1. a\n2. b\n\n---\n\npara\r\nwith crlf\n",
    "inline": "*a**b*c**d `x` [t](https://x.example/p?q=1&r=2) [m](mailto:a@b) [rel](/x#y) [frag](#z) [bad](javascript:alert(1)) [vb](  vbscript:x) ![](a)",
    "hostile": "[x](javascript:alert(1)) <script>alert(1)</script> \"'&<> ![img](javascript:x) [a](data:text/html,x)",
    "unterminated": "```\nunterminated fence\n**bold *em `code [link](",
    "fences": "```rust\nfn main() {}\n```\n\n```\nplain\n```\n\n```verylonginfostringthatgoesonandon extra\nx\n```\n",
    "nested": "> > > nested\n\n- - -\n\n****bold nested****\n\n###### h6\n\n####### not a heading\n\n#no space\n",
    "long": " ".join("word%d" % i for i in range(400)) + "\n\nand then a second paragraph.",
    "unicode": "# Título con acentos — ñ\n\nEmoji 🚀 and CJK 日本語 and rtl عربى and a   separator.",
    "empty_lines": "\n\n\n   \n\t\n",
    "headings_ids": "# Hello World!\n# Hello World!\n## ---\n## ¿Qué?\n",
}

for sub, cases, ext in (("http", HTTP, ".req"), ("md", MD, ".md")):
    d = os.path.join(HERE, "corpus", sub)
    os.makedirs(d, exist_ok=True)
    for name, data in cases.items():
        if isinstance(data, str):
            data = data.encode()
        with open(os.path.join(d, name + ext), "wb") as f:
            f.write(data)
    print(f"{sub}: {len(cases)} seeds")
