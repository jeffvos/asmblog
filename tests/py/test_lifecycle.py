"""Process lifecycle: graceful stop, SIGHUP reload, the access log."""
import os
import re
import signal
import socket
import subprocess
import time

import pytest

from conftest import BLOGD, Site

CLF = re.compile(r'^(\S+) - - \[(\d\d)/([A-Z][a-z]{2})/(\d{4}):(\d\d):(\d\d):(\d\d) \+0000\] "([^"]*)" (\d{3}) (\d+) "([^"]*)" "([^"]*)"$')


def log_lines(site):
    return [CLF.match(l) for l in site.stdout().splitlines() if not l.startswith("blogd ")]


# ---- graceful stop ---------------------------------------------------------------

@pytest.mark.parametrize("sig", [signal.SIGTERM, signal.SIGINT])
def test_stop_exits_zero_and_drains(cold_site, sig):
    site = cold_site.start()
    # an idle keep-alive connection, a half-sent request, an in-flight response
    idle = socket.create_connection(("127.0.0.1", site.port))
    idle.sendall(b"GET /health HTTP/1.1\r\nHost: t\r\n\r\n")
    idle.recv(4096)
    half = socket.create_connection(("127.0.0.1", site.port))
    half.sendall(b"GET / HTTP/1.1\r\nHost:")
    big = socket.create_connection(("127.0.0.1", site.port))
    big.sendall(b"GET /feed.xml HTTP/1.1\r\nHost: t\r\n\r\n")
    t0 = time.time()
    rc = site.stop(sig)
    took = time.time() - t0
    assert rc == 0, site.stderr()
    assert took < 12, took                     # the drain grace period is two 5 s ticks
    big.settimeout(5)
    body = b""
    while True:
        c = big.recv(65536)
        if not c:
            break
        body += c
    assert body.startswith(b"HTTP/1.1 200") and body.endswith(b"</feed>\n")
    idle.settimeout(2)
    assert idle.recv(16) == b""
    half.settimeout(2)
    assert half.recv(16) == b""
    with pytest.raises(OSError):
        socket.create_connection(("127.0.0.1", site.port), timeout=1)


def test_stop_finishes_a_response_that_is_being_sent(cold_site):
    """A client reading slowly: the server keeps sending after the signal
    instead of dropping the connection, then exits 0."""
    site = cold_site.start()
    slow = socket.create_connection(("127.0.0.1", site.port))
    slow.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
    slow.sendall(b"GET /static/main.css HTTP/1.1\r\nHost: t\r\n\r\n")
    time.sleep(0.3)                            # the kernel buffers fill, the rest waits on EPOLLOUT
    os.kill(site.pid, signal.SIGTERM)
    slow.settimeout(10)
    data = b""
    while True:
        try:
            c = slow.recv(65536)
        except socket.timeout:
            break
        if not c:
            break
        data += c
    hdr, _, body = data.partition(b"\r\n\r\n")
    assert hdr.startswith(b"HTTP/1.1 200")
    assert len(body) == int(re.search(rb"Content-Length: (\d+)", hdr).group(1))
    assert site.stop() == 0


# ---- SIGHUP reload -----------------------------------------------------------------

def test_sighup_reloads_templates_and_assets(cold_site):
    site = cold_site.start()
    etag = site.head("/").headers["ETag"]
    shell = site.dir / "templates" / "en" / "shell.html"
    shell.write_text(shell.read_text().replace("<title>", "<title>RELOADED ", 1))
    css = site.dir / "static" / "main.css"
    css.write_text(css.read_text() + "\n/* reloaded */\n")
    (site.dir / "static" / "main.css.gz").unlink(missing_ok=True)
    (site.dir / "static" / "main.css.br").unlink(missing_ok=True)
    css_v = re.search(r"main\.css\?v=([0-9a-f]+)", site.get("/").text).group(1)
    os.kill(site.pid, signal.SIGHUP)
    for _ in range(50):
        if "reloaded static/" in site.stderr():
            break
        time.sleep(0.05)
    assert "reloaded templates/" in site.stderr() and "reloaded static/" in site.stderr()
    home = site.get("/")
    assert "<title>RELOADED " in home.text
    assert home.headers["ETag"] != etag
    assert site.get("/static/main.css").text.endswith("/* reloaded */\n")
    assert re.search(r"main\.css\?v=([0-9a-f]+)", home.text).group(1) != css_v
    assert "Content-Encoding" not in site.get("/static/main.css", headers={"Accept-Encoding": "gzip"}).headers
    assert site.stop() == 0


def test_sighup_with_a_broken_template_keeps_the_old_set(cold_site):
    site = cold_site.start()
    shell = site.dir / "templates" / "en" / "shell.html"
    good = shell.read_text()
    shell.write_text(good.replace("{{site}}", "{{bogus}}", 1))
    os.kill(site.pid, signal.SIGHUP)
    for _ in range(50):
        if "templates/ failed" in site.stderr():
            break
        time.sleep(0.05)
    assert "keeping the old set" in site.stderr()
    assert site.get("/").status_code == 200 and "Test Blog" in site.get("/").text
    shell.write_text(good)
    assert site.stop() == 0


def test_sighup_under_load_serves_consistent_pages(cold_site):
    """Reloading while workers render: every response is a complete page
    from either set, never a 500 or a torn one."""
    import concurrent.futures
    site = cold_site.start()
    shell = site.dir / "templates" / "en" / "shell.html"
    stop = False

    def hammer(_):
        n = 0
        while not stop:
            r = site.get("/page/2")
            assert r.status_code == 200 and r.text.rstrip().endswith("</html>"), r.text[-200:]
            n += 1
        return n
    with concurrent.futures.ThreadPoolExecutor(4) as ex:
        futs = [ex.submit(hammer, i) for i in range(4)]
        for i in range(10):
            shell.write_text(shell.read_text().replace("<title>", f"<title>R{i} ", 1))
            os.kill(site.pid, signal.SIGHUP)
            time.sleep(0.1)
        stop = True
        assert sum(f.result() for f in futs) > 40
    assert site.stderr().count("reloaded templates/") == 10
    assert "R9 " in site.get("/").text
    assert site.stop() == 0


# ---- access log ----------------------------------------------------------------------

def test_no_access_log_by_default(site):
    site.get("/")
    assert log_lines(site) == []


def test_access_log_to_stdout(cold_site):
    site = cold_site.start(BLOGD_ACCESS_LOG="-")
    site.get("/")
    site.get("/post/why-assembly", headers={"X-Forwarded-For": "203.0.113.9, 10.0.0.1",
                                            "Referer": 'http://x/"evil', "User-Agent": 'ua "q"\x01'})
    site.get("/nope")
    site.head("/")
    site.raw(b"GARBAGE\r\n\r\n")
    r = site.get("/static/main.css", headers={"Accept-Encoding": "identity"})
    time.sleep(0.1)
    lines = [m for m in log_lines(site) if m]
    assert len(lines) == 7, site.stdout()             # the fixture's /health probe, then ours
    assert lines[0].group(8) == "GET /health HTTP/1.1"
    reqs = [(m.group(1), m.group(8), m.group(9), int(m.group(10)), m.group(11), m.group(12)) for m in lines[1:]]
    assert reqs[0][0] == "127.0.0.1" and reqs[0][1] == "GET / HTTP/1.1" and reqs[0][2] == "200"
    assert reqs[1] == ("203.0.113.9", "GET /post/why-assembly HTTP/1.1", "200", reqs[1][3], "http://x/_evil", "ua _q__")
    assert reqs[2][1:3] == ("GET /nope HTTP/1.1", "404")
    assert reqs[3][1:3] == ("HEAD / HTTP/1.1", "200") and reqs[3][3] < 2000
    assert reqs[4][1:3] == ("GARBAGE", "400") and reqs[4][4:] == ("-", "-")
    assert reqs[5][1:3] == ("GET /static/main.css HTTP/1.1", "200")
    assert reqs[5][3] > len(r.content)          # bytes count the headers too
    assert all(m.group(3) in ("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec") for m in lines)
    assert site.stop() == 0


def test_access_log_to_a_file(cold_site):
    path = cold_site.dir / "access.log"
    site = cold_site.start(BLOGD_ACCESS_LOG=str(path))
    site.get("/health")
    site.get("/health")
    time.sleep(0.1)
    lines = path.read_text().splitlines()
    assert len(lines) == 3 and all(CLF.match(l) for l in lines)   # the startup probe + two
    site.restart(BLOGD_ACCESS_LOG=str(path))
    site.get("/health")
    time.sleep(0.1)
    assert len(path.read_text().splitlines()) == 5      # appended, not truncated
    assert site.stop() == 0


def test_unwritable_access_log_is_a_startup_error(cold_site):
    env = dict(os.environ, BLOGD_ACCESS_LOG="/nonexistent-dir/access.log")
    r = subprocess.run([str(BLOGD), str(cold_site.port)], cwd=cold_site.dir, capture_output=True, text=True, env=env)
    assert r.returncode == 1 and "access log" in r.stderr


def test_closed_log_pipe_does_not_kill_the_server(cold_site):
    """stdout is a pipe nobody reads any more: the log write fails with
    EPIPE (SIGPIPE is ignored) and the server keeps serving."""
    site = cold_site
    env = dict(os.environ, BLOGD_ACCESS_LOG="-")
    proc = subprocess.Popen([str(BLOGD), str(site.port), "2"], cwd=site.dir, stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, env=env)
    site.proc = proc
    site.wait_up()
    proc.stdout.close()
    for _ in range(3):
        assert site.get("/health").status_code == 200
        time.sleep(0.05)
    assert proc.poll() is None
    assert site.stop() == 0
