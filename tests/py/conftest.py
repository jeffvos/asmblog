"""Fixtures for the blogd integration suite.

Every test talks to a real server over HTTP. A Site is a throwaway
directory (templates + stylesheets copied in, its own data/) with a
blogd process bound to a free port; nothing here touches the
repository's data/ or any other running blogd, and every server is
stopped by its own pid. Requires build/blogd (run `make` first) and
the `requests` package; pytest.sh sets both up.
"""
import os
import pathlib
import re
import shutil
import signal
import socket
import subprocess
import time

import pytest
import requests

ROOT = pathlib.Path(__file__).resolve().parents[2]
BLOGD = ROOT / "build" / "blogd"
PASSWORD = "testpass123"
CSRF_RE = re.compile(r'name="csrf" value="([0-9a-f]{64})"')


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def converter_available():
    return subprocess.run(["sh", str(ROOT / "tools" / "imgconv"), "--check"],
                          capture_output=True).returncode == 0


needs_converter = pytest.mark.skipif(not converter_available(),
                                     reason="no image converter (libvips-tools, ImageMagick or Pillow)")


class Site:
    """A site directory and the blogd serving it."""

    def __init__(self, path, init=True, seed=True, env=None, threads=2):
        self.dir = pathlib.Path(path)
        self.dir.mkdir(parents=True, exist_ok=True)
        for sub in ("templates", "static"):
            if not (self.dir / sub).exists():
                shutil.copytree(ROOT / sub, self.dir / sub)
        self.env = dict(env or {})
        self.threads = threads
        self.port = free_port()
        self.proc = None
        self.out = self.dir / "server.out"
        self.err = self.dir / "server.err"
        if init:
            self.run_cli("init", input=f"Test Blog\n5\n{PASSWORD}\n{PASSWORD}\n")
        if seed:
            self.run_cli("seed")

    # --- process control ---------------------------------------------------
    def run_cli(self, *args, input=None, env=None, check=True):
        e = dict(os.environ)
        e.update(self.env)
        e.update(env or {})
        r = subprocess.run([str(BLOGD), *args], cwd=self.dir, input=input, text=True,
                           capture_output=True, env=e)
        if check and r.returncode != 0:
            raise RuntimeError(f"blogd {' '.join(args)} failed ({r.returncode}): {r.stderr}")
        return r

    def start(self, wait=True, **env):
        assert self.proc is None
        e = dict(os.environ)
        e.update(self.env)
        e.update(env)
        self.proc = subprocess.Popen([str(BLOGD), str(self.port), str(self.threads)], cwd=self.dir,
                                     stdout=open(self.out, "ab"), stderr=open(self.err, "ab"), env=e)
        if wait:
            self.wait_up()
        return self

    def wait_up(self, timeout=10.0):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self.proc.poll() is not None:
                raise RuntimeError(f"blogd exited with {self.proc.returncode}: {self.err.read_text()}")
            try:
                with socket.create_connection(("127.0.0.1", self.port), timeout=0.5) as s:
                    s.sendall(b"GET /health HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n")
                    if b"200" in s.recv(64):
                        return
            except OSError:
                time.sleep(0.05)
        raise RuntimeError("blogd did not come up: " + self.err.read_text())

    def stop(self, sig=signal.SIGTERM, timeout=15.0):
        """Signal the server and return its exit status (None if already gone)."""
        if self.proc is None:
            return None
        if self.proc.poll() is None:
            self.proc.send_signal(sig)
            try:
                self.proc.wait(timeout)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()
                raise
        rc = self.proc.returncode
        self.proc = None
        return rc

    def kill(self):
        return self.stop(signal.SIGKILL)

    def restart(self, **env):
        self.stop()
        return self.start(**env)

    @property
    def pid(self):
        return self.proc.pid

    def stderr(self):
        return self.err.read_text()

    def stdout(self):
        return self.out.read_text()

    # --- http helpers -----------------------------------------------------------
    @property
    def base(self):
        return f"http://127.0.0.1:{self.port}"

    def url(self, path):
        return self.base + path

    def get(self, path, **kw):
        kw.setdefault("allow_redirects", False)
        return requests.get(self.url(path), **kw)

    def head(self, path, **kw):
        kw.setdefault("allow_redirects", False)
        return requests.head(self.url(path), **kw)

    def post(self, path, **kw):
        kw.setdefault("allow_redirects", False)
        return requests.post(self.url(path), **kw)

    def raw(self, data, timeout=5.0, read_all=True):
        """Send raw bytes on a fresh connection, return what comes back."""
        with socket.create_connection(("127.0.0.1", self.port), timeout=timeout) as s:
            s.sendall(data)
            buf = b""
            try:
                while True:
                    chunk = s.recv(65536)
                    if not chunk:
                        break
                    buf += chunk
                    if not read_all and b"\r\n\r\n" in buf:
                        break
            except socket.timeout:
                pass
            return buf

    def login(self, password=PASSWORD):
        """A logged-in Admin (requests session + CSRF token)."""
        s = requests.Session()
        r = s.post(self.url("/admin/login"), data={"password": password}, allow_redirects=False)
        assert r.status_code == 303, f"login failed: {r.status_code} {r.text[:200]}"
        return Admin(self, s)


class Admin:
    def __init__(self, site, session):
        self.site = site
        self.s = session
        self.csrf = self.fetch_csrf()

    def fetch_csrf(self):
        html = self.s.get(self.site.url("/admin")).text
        m = CSRF_RE.search(html)
        assert m, "no csrf token on the dashboard"
        return m.group(1)

    def get(self, path, **kw):
        kw.setdefault("allow_redirects", False)
        return self.s.get(self.site.url(path), **kw)

    def post(self, path, data=None, **kw):
        kw.setdefault("allow_redirects", False)
        d = {"csrf": self.csrf}
        d.update(data or {})
        return self.s.post(self.site.url(path), data=d, **kw)

    def save(self, title, md, slug="", tags="", action="publish", id=0):
        return self.post("/admin/save", {"id": id, "title": title, "slug": slug,
                                         "tags": tags, "md": md, "action": action})

    def settings(self, **fields):
        d = {"title": "Test Blog", "ppp": 5}
        d.update(fields)
        return self.post("/admin/settings", d)

    def preview(self, md, title="t"):
        return self.post("/admin/preview", {"title": title, "md": md}).text

    def upload(self, path, name=None, **kw):
        with open(path, "rb") as f:
            files = {"file": (name or os.path.basename(path), f)}
            return self.s.post(self.site.url("/admin/media"), data={"csrf": self.csrf},
                               files=files, allow_redirects=False, **kw)


# --- fixtures ---------------------------------------------------------------------
@pytest.fixture(scope="session", autouse=True)
def _built():
    if not BLOGD.exists():
        pytest.exit("build/blogd is missing: run `make` first", returncode=2)


@pytest.fixture
def site(tmp_path):
    """A fresh, initialised, seeded site with its server running."""
    s = Site(tmp_path / "site").start()
    yield s
    s.stop()


@pytest.fixture
def cold_site(tmp_path):
    """The same site, not started: for tests that drive the lifecycle."""
    s = Site(tmp_path / "site")
    yield s
    if s.proc is not None:
        s.kill()


@pytest.fixture(scope="module")
def ro_site(tmp_path_factory):
    """A seeded server shared by the read-only tests of one module."""
    s = Site(tmp_path_factory.mktemp("ro") / "site").start()
    yield s
    s.stop()


@pytest.fixture
def admin(site):
    return site.login()
