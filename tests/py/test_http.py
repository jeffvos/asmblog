"""The protocol layer: framing, limits, keep-alive, headers."""
import concurrent.futures
import socket
import time

import requests

from conftest import Site


def test_index_and_health(ro_site):
    r = ro_site.get("/")
    assert r.status_code == 200 and "<html" in r.text
    assert "content-length" in r.headers
    assert ro_site.get("/health").text.strip() == "ok"


def test_status_codes(ro_site):
    assert ro_site.get("/nope").status_code == 404
    assert ro_site.post("/").status_code == 405
    r = requests.put(ro_site.url("/"))
    assert r.status_code == 405 and r.headers["Allow"] == "GET, HEAD"


def test_keep_alive_by_version(ro_site):
    assert ro_site.get("/").headers["Connection"] == "keep-alive"
    resp = ro_site.raw(b"GET / HTTP/1.0\r\nHost: t\r\n\r\n")
    assert b"Connection: close" in resp


def test_keep_alive_reuses_connection_and_pipelines(ro_site):
    two = b"GET /health HTTP/1.1\r\nHost: t\r\n\r\nGET /nope HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n"
    resp = ro_site.raw(two)
    assert resp.count(b"HTTP/1.1 ") == 2
    assert b"HTTP/1.1 200" in resp and b"HTTP/1.1 404" in resp


def test_parallel_requests(ro_site):
    def one(_):
        return requests.get(ro_site.url("/health")).status_code
    with concurrent.futures.ThreadPoolExecutor(20) as ex:
        codes = set(ex.map(one, range(100)))
    assert codes == {200}


def test_every_response_has_date_and_security_headers(ro_site):
    for path in ("/", "/nope"):
        h = ro_site.get(path).headers
        assert "Date" in h and h["Date"].endswith("GMT")
        assert h["Content-Security-Policy"].startswith("default-src 'self'")
        assert h["X-Content-Type-Options"] == "nosniff"
        assert h["Server"].startswith("blogd/")


def test_head_sends_headers_only(ro_site):
    r = ro_site.head("/")
    assert r.status_code == 200 and int(r.headers["Content-Length"]) > 0
    assert r.content == b""


def test_content_language_on_html_only(ro_site):
    assert ro_site.get("/").headers["Content-Language"] == "en"
    assert "Content-Language" not in ro_site.get("/feed.xml").headers


def test_body_over_the_cap_is_413(ro_site):
    resp = ro_site.raw(b"POST /admin/login HTTP/1.1\r\nHost: x\r\nContent-Length: 999999\r\n\r\n", read_all=False)
    assert resp.startswith(b"HTTP/1.1 413")


def test_head_over_8k_is_431(ro_site):
    resp = ro_site.raw(b"GET / HTTP/1.1\r\nHost: x\r\nX-Pad: " + b"a" * 9000, read_all=False)
    assert resp.startswith(b"HTTP/1.1 431")


def test_chunked_body_is_411(ro_site):
    resp = ro_site.raw(b"POST /admin/login HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n", read_all=False)
    assert resp.startswith(b"HTTP/1.1 411")


def test_malformed_requests_are_400_and_close(ro_site):
    for bad in (b"GARBAGE\r\n\r\n", b"GET / HTTP/2.0\r\nHost: x\r\n\r\n", b"GET /\r\n\r\n",
                b"POST /admin/login HTTP/1.1\r\nHost: x\r\nContent-Length: 9x\r\n\r\n"):
        resp = ro_site.raw(bad)
        assert resp.startswith(b"HTTP/1.1 400"), bad
        assert b"Connection: close" in resp


def test_expect_100_continue(ro_site):
    resp = ro_site.raw(b"POST /admin/login HTTP/1.1\r\nHost: x\r\nContent-Length: 11\r\nExpect: 100-continue\r\n\r\n",
                       read_all=False)
    assert resp.startswith(b"HTTP/1.1 100 Continue")


def test_idle_connection_is_swept(tmp_path):
    s = Site(tmp_path / "idle", seed=False).start(BLOGD_IDLE_SECS="1")
    try:
        with socket.create_connection(("127.0.0.1", s.port), timeout=12) as c:
            t0 = time.time()
            assert c.recv(16) == b""          # closed by the server, not by a timeout
            assert time.time() - t0 < 11
    finally:
        s.stop()
