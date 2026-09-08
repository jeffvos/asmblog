"""Self-hosted images: uploads, renditions, markup, the lightbox, deletion."""
import re
import struct
import subprocess
import sys

import pytest

from conftest import ROOT, needs_converter

pytestmark = needs_converter


def mkpng(path, w, h, *extra):
    with open(path, "wb") as f:
        subprocess.run([sys.executable, str(ROOT / "tests" / "mkpng.py"), str(w), str(h), *extra], stdout=f, check=True)
    return path


def png_dims(data):
    return struct.unpack(">II", data[16:24])


@pytest.fixture
def pics(tmp_path):
    return {
        "big": mkpng(tmp_path / "big.png", 1200, 800),                 # < 100 KB: buffered
        "huge": mkpng(tmp_path / "huge.png", 2400, 1600, "7", "noisy"),  # > 100 KB: spooled
        "tiny": mkpng(tmp_path / "tiny.png", 300, 200),
    }


def test_sizes_of_the_test_pictures(pics):
    assert pics["big"].stat().st_size < 100000 < pics["huge"].stat().st_size


def test_upload_guards(admin, site, pics):
    lib = admin.get("/admin/media").text
    assert 'enctype="multipart/form-data"' in lib and "1600 px" in lib
    with open(pics["big"], "rb") as f:
        assert site.post("/admin/media", data={"csrf": admin.csrf}, files={"file": f}).status_code == 303
    with open(pics["huge"], "rb") as f:
        assert site.post("/admin/media", data={"csrf": admin.csrf}, files={"file": f}).status_code == 413
    with open(pics["big"], "rb") as f:
        assert admin.s.post(site.url("/admin/media"), data={"csrf": "deadbeef"}, files={"file": f},
                            allow_redirects=False).status_code == 400
    r = admin.s.post(site.url("/admin/media"), data={"csrf": admin.csrf},
                     files={"file": ("text.png", b"not an image")}, allow_redirects=False)
    assert r.headers["Location"].endswith("/admin/media?err=type")
    r = admin.s.post(site.url("/admin/media"), data={"csrf": admin.csrf},
                     files={"file": ("", b"")}, allow_redirects=False)
    assert r.headers["Location"].endswith("/admin/media?err=empty")


def test_upload_renditions_and_serving(admin, site, pics):
    r = admin.upload(pics["big"])
    assert r.status_code == 303 and r.headers["Location"].endswith("/admin/media?uploaded=1")
    assert site.get("/media/1.webp").headers["Content-Type"] == "image/webp"
    png = site.get("/media/1.png")
    assert png.headers["Content-Type"] == "image/png" and png_dims(png.content) == (1200, 800)
    assert png_dims(site.get("/media/1-s.png").content) == (800, 533)
    assert site.get("/media/1-s.webp").status_code == 200
    webp = site.get("/media/1.webp")
    assert webp.content[8:12] == b"WEBP"
    assert "max-age=31536000, immutable" in webp.headers["Cache-Control"] and webp.headers["ETag"] == '"1.webp"'
    assert site.get("/media/1.webp", headers={"If-None-Match": '"1.webp"'}).status_code == 304
    h = site.head("/media/1.png")
    assert int(h.headers["Content-Length"]) == len(png.content) and h.content == b""
    assert webp.content == (site.dir / "data" / "media" / "1.webp").read_bytes()
    # streamed (> 100 KB) upload
    r = admin.upload(pics["huge"])
    assert r.status_code == 303 and r.headers["Location"].endswith("uploaded=1")
    assert png_dims(site.get("/media/2.png").content) == (1600, 1067)
    assert not [p for p in (site.dir / "data" / "media").iterdir() if p.name.startswith("up-")]
    # below the inline size: one rendition only
    assert admin.upload(pics["tiny"]).status_code == 303
    assert site.get("/media/3.webp").status_code == 200
    assert site.get("/media/3-s.webp").status_code == 404
    assert not (site.dir / "data" / "media" / "3-s.png").exists()
    for bad in ("/media/99.webp", "/media/1.gif", "/media/../store.blg"):
        assert site.get(bad).status_code == 404, bad
    lib = admin.get("/admin/media").text
    assert 'class="mitem"' in lib and re.search(r"media/(\d+)", lib).group(1) == "3"
    assert "![big](/media/1)" in lib and "1200×800" in lib


def test_picture_markup_and_lightbox(admin, site, pics):
    admin.upload(pics["big"]); admin.upload(pics["huge"]); admin.upload(pics["tiny"])
    admin.settings(url="https://smoke.example")
    md = "Text before.\n\n![Sunset over the bay](/media/1)\n\nInline ![tiny](/media/3) picture and a missing ![gone](/media/77) one."
    admin.save("Pictures", md, slug="pictures", tags="pics")
    pp = site.get("/post/pictures", headers={"Host": "t.example", "X-Forwarded-Proto": "https"}).text
    assert '<figure><a class="pic-open" href="#lb1"' in pp
    assert ('<source type="image/webp" srcset="/media/1-s.webp 800w, /media/1.webp 1200w" '
            'sizes="(min-width: 48rem) 44rem, 100vw">') in pp
    assert '<img src="/media/1.png" srcset="/media/1-s.png 800w, /media/1.png 1200w"' in pp
    assert 'width="1200" height="800" alt="Sunset over the bay" loading="lazy" decoding="async"' in pp
    assert "<figcaption>Sunset over the bay</figcaption>" in pp
    assert '<span class="lb" id="lb1" role="dialog" aria-modal="true"><a class="lb-bg" href="#_"' in pp
    assert 'id="lb2"' in pp and 'class="lb-x" href="#_"' in pp
    assert 'srcset="/media/1-s.webp 800w, /media/1.webp 1200w" sizes="100vw"' in pp
    assert pp.count('class="lb-ph"') == 2
    assert '<source type="image/webp" srcset="/media/3.webp"><img src="/media/3.png" srcset="/media/3.png" width="300" height="200"' in pp
    assert "![gone](/media/77)" in pp and "media/77.png" not in pp
    assert 'og:image" content="https://smoke.example/media/1.png"' in pp
    assert '"image":"https://smoke.example/media/1.png"' in pp
    feed = site.get("/feed.xml", headers={"Host": "t.example"}).text
    assert 'xml:base="https://smoke.example/"' in feed
    tag = site.get("/tag/pics").text
    assert "Text before. Inline" in tag and "media/1" not in tag
    for css in [ROOT / "static" / "main.css"] + list((ROOT / "static").glob("*-main.css")):
        t = css.read_text()
        assert ".lb:target" in t and ".lb-frame" in t, css


def test_image_size_setting(admin, site, pics):
    assert admin.settings(imgmax=640).status_code == 303
    assert 'name="imgmax" value="640"' in admin.get("/admin/settings").text
    admin.upload(pics["big"])
    assert png_dims(site.get("/media/1.png").content) == (640, 427)
    assert png_dims(site.get("/media/1-s.png").content) == (320, 213)
    assert admin.settings(imgmax=10).status_code == 200


def test_delete_and_limits(admin, site, pics):
    admin.upload(pics["big"])
    assert 'name="id" value="1"' in admin.get("/admin/media/delete/1").text
    r = admin.post("/admin/media/delete", {"id": 1})
    assert r.headers["Location"].endswith("/admin/media?deleted=1")
    assert site.get("/media/1.webp").status_code == 404
    assert not (site.dir / "data" / "media" / "1.png").exists()
    sid = admin.s.cookies["sid"]
    resp = site.raw(f"POST /admin/media HTTP/1.1\r\nHost: x\r\nCookie: sid={sid}\r\nContent-Length: 99999999\r\n\r\n".encode(),
                    read_all=False)
    assert resp.startswith(b"HTTP/1.1 413")


def test_media_survive_compaction_and_orphans_are_swept(admin, site, pics):
    admin.upload(pics["big"])
    admin.save("Pictures", "![s](/media/1)", slug="pictures", tags="pics")
    media = site.dir / "data" / "media"
    for orphan in ("up-99.tmp", "77.webp", "77-s.png"):
        (media / orphan).write_bytes(b"x")
    site.stop()
    assert "compacted data/store.blg" in site.run_cli("compact").stdout
    site.start()
    assert site.get("/media/1.webp").status_code == 200
    assert 'srcset="/media/1-s.webp 800w' in site.get("/post/pictures").text
    for orphan in ("up-99.tmp", "77.webp", "77-s.png"):
        assert not (media / orphan).exists()
    assert (media / "1.webp").exists()
