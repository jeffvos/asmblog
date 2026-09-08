"""The admin panel over HTTP: sessions, CSRF, editing, settings, i18n."""
import re
import time

import requests

from conftest import PASSWORD, ROOT

THEMES = ["sucre", "medellin", "bogota", "lapaz", "cochabamba", "santacruz", "pittsburgh"]


def test_admin_requires_a_session(site):
    assert site.get("/admin").status_code == 303
    assert site.get("/admin", cookies={"sid": "deadbeef"}).status_code == 303


def test_wrong_password_then_backoff(site):
    r = site.post("/admin/login", data={"password": "wrongwrong1"})
    assert r.status_code == 200 and "wrong password" in r.text
    r = site.post("/admin/login", data={"password": PASSWORD})      # inside the 1 s backoff
    assert r.status_code == 200 and "too many attempts" in r.text
    time.sleep(1.2)
    assert site.post("/admin/login", data={"password": PASSWORD}).status_code == 303


def test_login_sets_a_hardened_cookie(site):
    r = site.post("/admin/login", data={"password": PASSWORD})
    ck = r.headers["Set-Cookie"]
    assert ck.startswith("sid=") and "HttpOnly" in ck and "SameSite=Strict" in ck
    assert re.match(r"sid=[0-9a-f]{64};", ck)


def test_dashboard_lists_every_post(admin):
    dash = admin.get("/admin").text
    assert len(re.findall(r"/admin/edit/\d+", dash)) == 9
    assert len(admin.csrf) == 64


def test_csrf_mismatch_is_rejected(admin):
    r = admin.s.post(admin.site.url("/admin/delete"), data={"csrf": "deadbeef", "id": 1}, allow_redirects=False)
    assert r.status_code == 400


def test_publish_edit_draft_delete(admin, site):
    r = admin.save("Smoke Post", "Hello **world** from [here](/about)", tags="smoke")
    assert r.status_code == 303 and r.headers["Location"].endswith("/admin?saved=1")
    assert "<strong>world</strong>" in site.get("/post/smoke-post").text
    dash = admin.get("/admin?saved=1").text
    assert 'class="notice"' in dash
    pid = max(int(x) for x in re.findall(r"/admin/edit/(\d+)", dash))
    form = admin.get(f"/admin/edit/{pid}").text
    assert 'value="Smoke Post"' in form and "Hello **world**" in form
    # an edit keeps the id and the slug, the public page follows
    r = admin.save("Smoke Post 2", "Edited body", slug="smoke-post", tags="smoke", id=pid)
    assert r.status_code == 303
    assert "Edited body" in site.get("/post/smoke-post").text
    assert len(re.findall(r"/admin/edit/(\d+)", admin.get("/admin").text)) == 10
    # back to draft: hidden from the public site, still on the dashboard
    assert admin.save("Smoke Post 2", "Edited body", slug="smoke-post", id=pid, action="draft").status_code == 303
    assert site.get("/post/smoke-post").status_code == 404
    assert f"/admin/edit/{pid}" in admin.get("/admin").text
    # delete: confirm page, then the tombstone
    assert f'name="id" value="{pid}"' in admin.get(f"/admin/delete/{pid}").text
    r = admin.post("/admin/delete", {"id": pid})
    assert r.status_code == 303 and r.headers["Location"].endswith("/admin?deleted=1")
    assert f"/admin/edit/{pid}" not in admin.get("/admin").text


def test_validation_errors_rerender_the_form(admin):
    r = admin.post("/admin/save", {"id": 0, "title": "", "md": "x"})
    assert r.status_code == 200 and "title is required" in r.text


def test_long_excerpt_is_cut_once(admin, site):
    md = " ".join(f"word{i}" for i in range(60)) + " and then a second paragraph."
    admin.save("Long One", md, slug="long-one", tags="smoke")
    home = site.get("/").text
    exc = re.search(r'<p class="excerpt[^<]*</p>', home).group(0)
    assert "word0 " in exc and re.search(r"[a-z0-9]…</p>", exc) and "…." not in home
    assert re.search(r'name="description" content="word0 .*…"', site.get("/post/long-one").text)


def test_banner_setting(admin, site):
    assert admin.settings(banner="CUSTOM-BANNER-XYZ").status_code == 303
    assert "CUSTOM-BANNER-XYZ" in site.get("/").text


def test_theme_switching(admin, site):
    assert 'class="min-h-screen theme-retro"' in site.get("/").text
    css = site.get("/static/main.css").text
    assert ".theme-retro .masthead" in css and ".theme-sucre .masthead" not in css
    assert '<meta name="theme-color" content="#000080">' in site.get("/").text
    retro_v = re.search(r"main\.css\?v=([0-9a-f]+)", site.get("/").text).group(1)
    assert site.get("/favicon.ico").content == (ROOT / "static" / "favicon.ico").read_bytes()
    for t in THEMES:
        assert admin.settings(theme=t).status_code == 303, t
        page = site.get("/").text
        assert f'class="min-h-screen theme-{t}"' in page
        assert f'value="{t}" checked' in admin.get("/admin/settings").text
        for name in ("favicon.ico", "favicon.svg", "icon-192.png", "og.png"):
            path = "/favicon.ico" if name == "favicon.ico" else f"/static/{name}"
            assert site.get(path).content == (ROOT / "static" / f"{t}-{name}").read_bytes(), (t, name)
        assert f"og.png?v=theme-{t}" in page and f"favicon.svg?v=theme-{t}" in page
        m = site.get("/manifest.webmanifest").json()
        assert f"icon-512.png?v=theme-{t}" in m["icons"][-1]["src"] or f"theme-{t}" in str(m)
        assert f'<meta name="theme-color" content="{m["theme_color"]}">' in page
        assert re.search(r'fill="#[0-9a-f]{6}"', site.get("/hits.svg").text)
        assert f"theme-{t}" in site.get("/404-page").text
        tcss = site.get("/static/main.css").text
        assert f".theme-{t} .masthead" in tcss and ".theme-retro .masthead" not in tcss
        assert tcss == (ROOT / "static" / f"{t}-main.css").read_text()
        assert re.search(r"main\.css\?v=([0-9a-f]+)", page).group(1) != retro_v
    admin.settings(theme="bogus")
    assert "theme-retro" in site.get("/").text
    assert admin.settings(theme="retro").status_code == 303
    assert "theme-retro" in site.get("/").text


def test_locale_switching(admin, site):
    home = site.get("/").text
    assert '<html lang="en">' in home and re.search(r'class="date">[A-Z][a-z]+ \d+, \d{4}', home)
    assert admin.settings(locale="es").status_code == 303
    home = site.get("/").text
    assert '<html lang="es-BO">' in home and ">inicio<" in home
    assert re.search(r"\d+ de [a-z]+ de \d{4}", home) and "más antiguas" in home
    assert "entradas con la etiqueta #asm" in site.get("/tag/asm").text
    assert "panel de control" in admin.get("/admin").text
    assert "obligatorio" in admin.post("/admin/save", {"id": 0, "title": "", "md": "x"}).text
    assert site.get("/").headers["Content-Language"] == "es-BO"
    assert admin.settings(locale="en").status_code == 303
    assert '<html lang="en">' in site.get("/").text


def test_site_url_setting(admin, site):
    assert admin.settings(url="ftp://nope").status_code == 200
    assert admin.settings(url="https://smoke.example/").status_code == 303
    assert 'name="url" value="https://smoke.example"' in admin.get("/admin/settings").text
    p = site.get("/post/why-assembly", headers={"Host": "other.example"}).text
    assert 'rel="canonical" href="https://smoke.example/post/why-assembly"' in p


def test_posts_per_page_setting(admin, site):
    assert admin.settings(ppp=3).status_code == 303
    assert site.get("/").text.count("<article") == 3
    assert site.get("/page/3").text.count("<article") == 2
    assert admin.settings(ppp=0).status_code == 200      # out of range: form re-rendered


def test_admin_pages_are_private(admin):
    r = admin.get("/admin")
    assert r.headers["Cache-Control"] == "no-store" and 'content="noindex"' in r.text


def test_password_change(admin, site):
    r = admin.settings(password="newpassword1", password2="different1")
    assert r.status_code == 200
    r = admin.settings(password="newpassword1", password2="newpassword1")
    assert r.status_code == 303
    assert site.post("/admin/login", data={"password": PASSWORD}).status_code == 200
    time.sleep(1.2)
    assert site.post("/admin/login", data={"password": "newpassword1"}).status_code == 303


def test_many_large_saves(admin, site):
    big = ("lorem ipsum dolor sit amet " * 1100)[:30000]
    for i in range(1, 81):
        r = admin.save(f"Bulk {i}", big, slug=f"bulk-{i}", tags="bulk")
        assert r.status_code == 303, f"save {i} -> {r.status_code}"
    assert "lorem ipsum" in site.get("/post/bulk-80").text


def test_logout(admin, site):
    assert admin.post("/admin/logout").status_code == 303
    assert admin.get("/admin").status_code == 303


def test_preview_does_not_save(admin, site):
    html = admin.preview("# Preview Only\n\nbody text")
    assert '<h1 id="preview-only">Preview Only</h1>' in html and 'name="md"' in html
    assert "Preview Only" not in site.get("/").text
