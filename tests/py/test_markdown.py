"""The markdown renderer, through /admin/preview and saved posts."""
import re

MDX = """## Hello World!

```rust
fn main() {}
```

![A photo](https://live.staticflickr.com/1/2_b.jpg)

Inline ![local](/static/og.png) and ![evil](https://evil.example/x.png) and ![pr](//evil.example/x) and the tail survives."""

FLICKR = ('<a data-flickr-embed="true" href="https://www.flickr.com/photos/x/1/">'
          '<img src="https://live.staticflickr.com/1/2_b.jpg" alt="pic"/></a>'
          '<script src="//embedr.flickr.com/x.js"></script>')


def test_blocks_and_inline(admin):
    html = admin.preview(MDX)
    assert '<h2 id="hello-world">Hello World!</h2>' in html
    assert '<pre><code class="language-rust">fn main() {}' in html
    assert ('<figure><img src="https://live.staticflickr.com/1/2_b.jpg" alt="A photo" '
            'loading="lazy" decoding="async"></figure>') in html
    assert '<img src="/static/og.png" alt="local"' in html
    assert 'evil.example/x.png"' not in html and 'src="//evil' not in html
    assert "![evil](https://evil.example/x.png)" in html


def test_text_after_a_rejected_image_survives(admin):
    """A regression the fuzz harness found: the renderer resumed its scan
    with a clobbered register and dropped the rest of the line."""
    html = admin.preview("before ![evil](https://evil.example/x.png) middle ![pr](//evil.example/x) after.")
    assert re.search(r"before !\[evil\]\(https://evil\.example/x\.png\) middle !\[pr\]\(//evil\.example/x\) after\.", html)


def test_hostile_input_stays_escaped(admin):
    html = admin.preview('[x](javascript:alert(1)) <script>alert(1)</script> [v](  vbscript:x) "quoted" & <b>')
    assert "&lt;script&gt;" in html and "<script>alert" not in html
    assert 'href="javascript' not in html and 'href="  vbscript' not in html and 'href="vbscript' not in html
    assert "[x](javascript:alert(1))" in html           # left as visible text
    assert "&quot;quoted&quot;" in html and "&amp; &lt;b&gt;" in html


def test_link_schemes(admin):
    html = admin.preview("[a](https://x.example/p?q=1&r=2) [b](mailto:me@x) [c](/rel#f) [d](#frag) [e](ftp://x)")
    assert '<a href="https://x.example/p?q=1&amp;r=2">a</a>' in html
    assert '<a href="mailto:me@x">b</a>' in html and '<a href="/rel#f">c</a>' in html
    assert '<a href="#frag">d</a>' in html
    assert "[e](ftp://x)" in html


def test_lists_quotes_rules_and_emphasis(admin):
    html = admin.preview("# T\n\n> q1\n> q2\n\n- one\n- two `c<d`\n\n1. a\n2. b\n\n---\n\n*em* **st** ***both***\n\nunclosed **bold *em")
    assert "<blockquote>" in html and "</blockquote>" in html
    assert "<ul>" in html and "<li>two <code>c&lt;d</code></li>" in html
    assert "<ol>" in html and "<li>b</li>" in html and "<hr>" in html
    assert "<em>em</em> <strong>st</strong>" in html
    assert "<strong>bold <em>em</em></strong>" in html      # closed at end of line


def test_heading_anchors_are_slugs(admin):
    html = admin.preview("## ¿Qué Tal? — Hi!\n\n### ---")
    assert '<h2 id="qu-tal-hi">¿Qué Tal? — Hi!</h2>' in html
    assert "<h3>---</h3>" in html                       # nothing sluggable: no id attribute


def test_flickr_embed(admin, site):
    admin.save("Pic", FLICKR, slug="pic", tags="p")
    post = site.get("/post/pic").text
    assert '<figure class="flickr-embed">' in post and "embedr.flickr.com" not in post
    assert "live.staticflickr.com" in site.get("/").headers["Content-Security-Policy"]
    assert "data-flickr" not in site.get("/tag/p").text and "data-flickr" not in site.get("/feed.xml").text
    bad = FLICKR.replace("https://www.flickr.com/photos/x/1/", "https://phish.example/").replace(
        "https://live.staticflickr.com/1/2_b.jpg", "https://evil.com/x.jpg")
    admin.save("Bad", bad, slug="badpic", tags="p")
    post = site.get("/post/badpic").text
    assert '<figure class="flickr-embed">' not in post and 'evil.com/x.jpg"' not in post


def test_excerpt_strips_markers(admin, site):
    admin.save("Ex", "Hello **world** from `code` and [a link](/x)\n\n- item", slug="ex", tags="e")
    home = site.get("/").text
    assert "Hello world from code and [a link](/x) item" in home   # markers go, link text stays
    assert "Hello **world" not in home
