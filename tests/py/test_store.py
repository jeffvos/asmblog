"""The command-line side: selftest, init, seed, compact, usage."""
import re

from conftest import Site


def test_selftest(tmp_path):
    s = Site(tmp_path / "st", init=False, seed=False)
    assert "selftest ok" in s.run_cli("selftest").stdout


def test_init_validation(tmp_path):
    s = Site(tmp_path / "i", init=False, seed=False)
    r = s.run_cli("init", input="T\n5\nshort\nshort\n", check=False)
    assert r.returncode == 1 and "too short" in r.stderr
    r = s.run_cli("init", input="T\n5\nlongenough1\nlongenough2\n", check=False)
    assert r.returncode == 1 and "do not match" in r.stderr
    r = s.run_cli("init", input="T\n5\nlongenough1\nlongenough1\n", check=False, env={"BLOGD_SITE_URL": "ftp://x"})
    assert r.returncode == 1 and "BLOGD_SITE_URL" in r.stderr
    r = s.run_cli("init", input="Env Blog\n7\nlongenough1\nlongenough1\n", env={"BLOGD_SITE_URL": "https://env.example/"})
    assert "initialized" in r.stdout
    s.run_cli("seed")
    s.start()
    try:
        home = s.get("/", headers={"Host": "other"}).text
        assert "<title>home &mdash; Env Blog" in home or "Env Blog" in home
        assert 'rel="canonical" href="https://env.example/">' in home
        assert home.count("<article") == 7
    finally:
        s.stop()


def test_seed_and_usage(tmp_path):
    s = Site(tmp_path / "u", seed=False)
    assert "seeded 9 posts" in s.run_cli("seed").stdout
    r = s.run_cli("99999", check=False)
    assert r.returncode == 1 and "usage:" in r.stderr
    r = s.run_cli("bogus", check=False)
    assert r.returncode == 1


def test_compact_keeps_everything(admin, site):
    admin.settings(banner="KEEP-ME")
    for i in range(5):
        admin.save("Same", f"version {i}", slug="same", tags="c", id=0 if i == 0 else 10)
    site.stop()
    before = (site.dir / "data" / "store.blg").stat().st_size
    out = site.run_cli("compact").stdout
    m = re.search(r"compacted data/store.blg: (\d+) -> (\d+) bytes", out)
    assert m and int(m.group(1)) == before and int(m.group(2)) < before
    site.start()
    assert site.get("/post/smoke-post").status_code == 404
    assert "KEEP-ME" in site.get("/").text
    assert "version 4" in site.get("/post/same").text
    assert site.get("/").text.count("<article") == 5
    assert "secret-draft" not in site.get("/sitemap.xml", headers={"Host": "t"}).text
