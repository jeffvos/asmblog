"""The public site: lists, posts, search, feed, discovery files, validators."""
import hashlib
import json
import re
import time
import xml.dom.minidom

import requests

ORIGIN = {"Host": "t.example", "X-Forwarded-Proto": "https"}


def articles(html):
    return html.count("<article")


def jsonld(html):
    m = re.search(r'<script type="application/ld\+json">(.*?)</script>', html, re.S)
    return json.loads(m.group(1))


def test_pagination_and_visibility(ro_site):
    assert articles(ro_site.get("/").text) == 5
    assert articles(ro_site.get("/page/2").text) == 3
    assert ro_site.get("/page/3").status_code == 404
    assert ro_site.get("/post/secret-draft").status_code == 404
    assert articles(ro_site.get("/tag/asm").text) == 3
    assert ro_site.get("/tag/asm/page/2").status_code == 404


def test_search(ro_site):
    assert articles(ro_site.get("/search?q=MARQUEE").text) == 1
    page = ro_site.get("/search?q=%3Cscript%3E").text
    assert "&lt;script&gt;" in page and "<script>" not in page
    assert 'content="noindex,follow"' in ro_site.get("/search?q=mov").text
    assert "noindex" not in ro_site.get("/").text


def test_post_page_renders_html(ro_site):
    assert "The stack is a place" in ro_site.get("/post/why-assembly").text


def test_list_titles(ro_site):
    assert "<title>home · page 2 " in ro_site.get("/page/2").text
    assert "<title>#asm " in ro_site.get("/tag/asm").text
    assert "<title>search: mov " in ro_site.get("/search?q=mov").text


def test_canonical_urls(ro_site):
    r = ro_site.get("/page/1")
    assert r.status_code == 301 and r.headers["Location"] == "/"
    r = ro_site.get("/tag/asm/")
    assert r.status_code == 301 and r.headers["Location"] == "/tag/asm"
    assert ro_site.get("/tag/asm/page/1").headers["Location"] == "/tag/asm"
    assert 'rel="prev" href="/"' in ro_site.get("/page/2").text
    assert 'rel="next" href="/page/2"' in ro_site.get("/").text


def test_validators_and_304(ro_site):
    h = ro_site.get("/").headers
    assert h["ETag"].startswith('W/"') and h["Cache-Control"] == "public, max-age=0, must-revalidate"
    et = ro_site.head("/post/why-assembly").headers["ETag"]
    assert ro_site.get("/post/why-assembly", headers={"If-None-Match": et}).status_code == 304
    lm = ro_site.head("/").headers["Last-Modified"]
    assert ro_site.get("/", headers={"If-Modified-Since": lm}).status_code == 304
    assert ro_site.get("/feed.xml", headers={"If-Modified-Since": "Thu, 01 Jan 1970 00:00:00 GMT"}).status_code == 200
    assert ro_site.get("/", headers={"If-None-Match": '"nope"', "If-Modified-Since": lm}).status_code == 200


def test_render_cache_serves_identical_bytes(ro_site):
    a = ro_site.get("/page/2").content
    b = ro_site.get("/page/2").content
    assert a == b and b"<article" in a


def test_excerpts_never_double_punctuation(ro_site):
    for path in ("/", "/feed.xml"):
        t = ro_site.get(path).text
        assert not re.search(r"[.!?]…", t) and "...." not in t


def test_static_assets(ro_site):
    css = ro_site.get("/static/main.css", headers={"Accept-Encoding": "gzip"}, stream=True).raw.headers
    assert css["Content-Encoding"] == "gzip"
    h = ro_site.get("/static/main.css?v=x").headers
    assert "immutable" in h["Cache-Control"] and h["Vary"] == "Accept-Encoding"
    assert "max-age=3600" in ro_site.get("/static/main.css").headers["Cache-Control"]
    plain = requests.get(ro_site.url("/static/main.css"), headers={"Accept-Encoding": "gzip;q=0"}, stream=True)
    assert "Content-Encoding" not in plain.raw.headers
    et = ro_site.head("/static/main.css").headers["ETag"]
    assert ro_site.get("/static/main.css", headers={"If-None-Match": et}).status_code == 304
    assert re.search(r'href="/static/main\.css\?v=[0-9a-f]{8}"', ro_site.get("/").text)


def test_discovery_files(ro_site):
    for p in ("/favicon.ico", "/static/favicon.svg", "/static/icon-192.png", "/static/og.png"):
        assert ro_site.get(p).status_code == 200, p
    m = ro_site.get("/manifest.webmanifest")
    assert m.headers["Content-Type"].startswith("application/manifest+json")
    assert m.json()["name"] == "Test Blog"
    robots = ro_site.get("/robots.txt", headers=ORIGIN).text
    assert "Disallow: /admin" in robots and "Sitemap: https://t.example/sitemap.xml" in robots
    sm = ro_site.get("/sitemap.xml", headers={"Host": "t.example"}).text
    assert sm.count("<url>") == 9 and "secret-draft" not in sm
    xml.dom.minidom.parseString(sm)
    assert ro_site.get("/sitemap.xml", headers={"Host": ""}).status_code == 404


def test_head_metadata(ro_site):
    p = ro_site.get("/post/why-assembly", headers=ORIGIN).text
    assert '<meta name="description" content="Because every' in p
    assert '<link rel="canonical" href="https://t.example/post/why-assembly">' in p
    assert 'og:title" content="Why Assembly?"' in p and 'article:tag" content="asm"' in p
    assert "twitter:card" in p
    d = jsonld(p)
    assert d["@type"] == "BlogPosting" and d["headline"] == "Why Assembly?"
    home = jsonld(ro_site.get("/", headers={"Host": "t.example"}).text)
    assert home["@type"] == "WebSite" and "search_term_string" in home["potentialAction"]["target"]
    bare = ro_site.get("/post/why-assembly", headers={"Host": ""}).text
    assert 'rel="canonical"' not in bare and 'twitter:card" content="summary"' in bare


def test_feed(ro_site):
    f = ro_site.get("/feed.xml", headers={"Host": "t.example"}).text
    assert f.count("<entry>") == 8
    assert "<author><name>Test Blog</name></author>" in f
    assert "<published>" in f and '<category term="asm"/>' in f and '<content type="html">' in f
    assert 'href="http://t.example/post/why-assembly"' in f
    xml.dom.minidom.parseString(f)
    xml.dom.minidom.parseString(ro_site.get("/feed.xml", headers={"Host": ""}).text)
    upd = re.search("<updated>([^<]*)", f).group(1)
    time.sleep(1.1)
    assert re.search("<updated>([^<]*)", ro_site.get("/feed.xml").text).group(1) == upd


def hits(site):
    return int(re.search(r">0*(\d*)</text", site.get("/hits.svg").text).group(1) or 0)


def test_visitor_counter(ro_site):
    a = hits(ro_site)
    assert hits(ro_site) == a + 1
    assert ro_site.get("/hits.svg").headers["Cache-Control"] == "no-store"
    b = hits(ro_site)
    ro_site.head("/hits.svg")
    assert hits(ro_site) == b + 1          # HEAD peeks without counting


def test_footer_badge_matches_the_server_version(ro_site):
    """The version lives in several literals (Server header, banner, feed
    generator, the shell templates' badge); a bump must move all of them."""
    r = ro_site.get("/")
    version = re.match(r"blogd/(\d+\.\d+)", r.headers["Server"]).group(1)
    assert f">blogd {version}<" in r.text
    assert f"<generator>blogd {version}</generator>" in ro_site.get("/feed.xml").text
