"""Crash recovery: the store after a kill, a torn write, a bad record.

The durability model (store.asm): every mutation is one appended,
fsynced record; the loader verifies each crc and truncates the file at
the first bad or torn record; compaction writes store.tmp and renames it
over the store. These tests break the file the way a crash would and
check the server comes back with everything it had acknowledged.
"""
import os
import random
import re
import struct
import threading
import time

import requests

from conftest import Site


def store(site):
    return site.dir / "data" / "store.blg"


def post_ids(site):
    return sorted(set(int(x) for x in re.findall(r"/post/([a-z0-9-]+)", site.get("/sitemap.xml", headers={"Host": "t"}).text)
                      if False) or set(re.findall(r"/post/([a-z0-9-]+)", site.get("/sitemap.xml", headers={"Host": "t"}).text)))


def slugs(site):
    return set(re.findall(r"/post/([a-z0-9-]+)</loc>", site.get("/sitemap.xml", headers={"Host": "t"}).text))


def test_torn_record_is_truncated(site):
    before = slugs(site)
    site.stop()
    path = store(site)
    size = path.stat().st_size
    # a record header that promises 4000 payload bytes, of which 100 arrive
    hdr = b"REC1" + struct.pack("<IQQQQIIIIII", 1, 99, 1, 1, 1, 4000, 0, 0, 0, 0, 0)
    with open(path, "ab") as f:
        f.write(hdr + b"x" * 100)
    site.start()
    assert slugs(site) == before
    assert site.get("/health").status_code == 200
    assert path.stat().st_size == size            # the torn tail is gone


def test_garbage_tail_is_truncated(site):
    before = slugs(site)
    site.stop()
    path = store(site)
    size = path.stat().st_size
    with open(path, "ab") as f:
        f.write(os.urandom(777))
    site.start()
    assert slugs(site) == before and path.stat().st_size == size


def test_bad_crc_stops_the_load_there(site):
    """A corrupted record and everything after it are dropped: the store is
    an append-only log, so nothing after a broken record can be trusted."""
    site.stop()
    path = store(site)
    data = bytearray(path.read_bytes())
    # the third record: walk two records from the 16-byte file header
    off = 16
    for _ in range(2):
        tlen, slen, glen, mlen, hlen = struct.unpack_from("<IIIII", data, off + 40)
        off += (64 + tlen + slen + glen + mlen + hlen + 7) & ~7
    data[off + 64] ^= 0xFF                      # flip a payload byte
    path.write_bytes(data)
    site.start()
    assert site.get("/health").status_code == 200
    assert path.stat().st_size == off
    assert len(slugs(site)) <= 2


def test_kill_storm_keeps_every_acknowledged_save(tmp_path):
    """SIGKILL the server at random moments while saves are in flight; every
    save that was answered 303 must be there after the restart, and the
    store must still load and compact."""
    site = Site(tmp_path / "storm", threads=1).start()
    acked = set()
    rnd = random.Random(1234)
    try:
        for i in range(20):
            admin = site.login()
            slug = f"storm-{i}"
            body = "x " * rnd.randint(10, 20000)
            result = {}

            def save():
                try:
                    r = admin.save(f"Storm {i}", body, slug=slug, tags="storm", id=0)
                    result["code"] = r.status_code
                except requests.RequestException as e:
                    result["err"] = e
            t = threading.Thread(target=save)
            t.start()
            time.sleep(rnd.uniform(0, 0.03))
            site.kill()
            t.join(10)
            if result.get("code") == 303:
                acked.add(slug)
            site.start()
        assert site.get("/health").status_code == 200
        present = slugs(site)
        missing = acked - present
        assert not missing, f"acknowledged saves lost: {missing}"
        assert "why-assembly" in present
        site.stop()
        assert "compacted data/store.blg" in site.run_cli("compact").stdout
        site.start()
        assert acked <= slugs(site)
    finally:
        if site.proc is not None:
            site.stop()


def test_leftover_compaction_temp_is_harmless(site):
    before = slugs(site)
    site.stop()
    tmp = site.dir / "data" / "store.tmp"
    tmp.write_bytes(b"BLG1" + os.urandom(500))     # a compaction that died before its rename
    site.start()
    assert slugs(site) == before
    site.stop()
    site.run_cli("compact")
    assert not tmp.exists()
    site.start()
    assert slugs(site) == before


def test_visitor_counter_survives_a_restart(site):
    def hits():
        return int(re.search(r">0*(\d*)</text", site.get("/hits.svg").text).group(1) or 0)
    a = hits()
    site.restart()
    assert hits() == a + 1
