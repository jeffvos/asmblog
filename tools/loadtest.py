#!/usr/bin/env python3
"""loadtest.py — step blogd through concurrency levels and find its knees.

For each level (a number of concurrent keep-alive connections) the
script hammers a mix of public URLs for a fixed duration and records,
per level:

  * throughput (req/s), latency average / p50 / p95 / p99 / max
  * errors (connection failures, truncated responses) and non-200s
  * the server's CPU (all threads, so >100% is normal), resident memory
    (current and peak), thread count and open file descriptors, sampled
    from /proc while the level runs
  * the client's own CPU, so a client-bound level is flagged rather than
    misread as a server limit

then prints a table plus the break points it found: where p99 crosses
the latency SLO, where throughput stops growing, where errors begin,
and the memory cost per open connection.

By default a throwaway seeded server is started in a scratch directory
(like tools/preview.sh) and sampled by PID; --url/--pid target one you
already run. Standard library only. Examples:

  tools/loadtest.py                               # 1..1000 connections, 5 s each
  tools/loadtest.py --levels 16,64,256 --duration 10 --threads 8
  tools/loadtest.py --url http://127.0.0.1:8080 --pid $(cat /run/blogd.pid)
  tools/loadtest.py --no-keepalive --paths /,/feed.xml --json out.json

Two machines over the LAN, so the client's CPU never competes with the
server's:

  machine A:  tools/loadtest.py --serve                 # prints the URL to use
  machine B:  tools/loadtest.py --url http://A:8090     # full table, server columns included

--serve binds the throwaway server to every interface (plain HTTP, a
seeded demo site) and runs a stats endpoint on the next port that
reports the server's /proc figures; the client finds it by itself
(or pass --stats). Ctrl-C on A stops and deletes everything.

The client is several processes, each an asyncio loop with a share of
the connections; it comfortably drives tens of thousands of requests
per second. Raise the fd limit (ulimit -n) for levels above ~900.
"""
import argparse
import asyncio
import json
import os
import resource
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
from array import array
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from multiprocessing import Pipe, Process

DEFAULT_LEVELS = "1,4,16,64,256,1000"
DEFAULT_PATHS = "/,/post/why-assembly,/tag/asm,/page/2,/feed.xml,/static/main.css,/hits.svg,/search?q=mov"
CLK_TCK = os.sysconf("SC_CLK_TCK")


# ------------------------------------------------------------------ client

def worker(out, host, port, nconn, paths, duration, warmup, keepalive):
    """One process: nconn connections looping over paths until the clock
    runs out. Sends back latencies (ms), error count and status counts."""
    lat = array("d")
    errors = [0]
    codes = {}
    t_start = time.perf_counter()
    t_warm = t_start + warmup
    t_end = t_warm + duration

    async def one(i):
        idx = i
        reader = writer = None
        while time.perf_counter() < t_end:
            if writer is None:
                try:
                    reader, writer = await asyncio.open_connection(host, port)
                except OSError:
                    errors[0] += 1
                    await asyncio.sleep(0.01)
                    continue
            path = paths[idx % len(paths)]
            idx += 1
            req = ("GET %s HTTP/1.1\r\nHost: %s\r\n%s\r\n" % (
                path, host, "" if keepalive else "Connection: close\r\n")).encode()
            t0 = time.perf_counter()
            try:
                writer.write(req)
                await writer.drain()
                head = await reader.readuntil(b"\r\n\r\n")
                status = int(head[9:12])
                clen = 0
                close = not keepalive
                for line in head.split(b"\r\n")[1:]:
                    low = line.lower()
                    if low.startswith(b"content-length:"):
                        clen = int(low[15:])
                    elif low.startswith(b"connection:") and b"close" in low:
                        close = True
                if clen:
                    await reader.readexactly(clen)
            except (asyncio.IncompleteReadError, asyncio.LimitOverrunError,
                    ConnectionError, OSError, ValueError):
                errors[0] += 1
                writer.close()
                writer = None
                continue
            t1 = time.perf_counter()
            if t1 >= t_warm:
                lat.append((t1 - t0) * 1000.0)
                codes[status] = codes.get(status, 0) + 1
            if close:
                writer.close()
                writer = None
        if writer is not None:
            writer.close()

    async def run():
        await asyncio.gather(*(one(i) for i in range(nconn)))

    asyncio.run(run())
    ru = resource.getrusage(resource.RUSAGE_SELF)
    out.send((lat.tobytes(), errors[0], codes, ru.ru_utime + ru.ru_stime))
    out.close()


def run_level(host, port, conns, paths, duration, warmup, keepalive, procs):
    """Spread `conns` connections over `procs` processes; -> (latencies,
    errors, status counts, client CPU seconds)."""
    procs = max(1, min(procs, conns))
    shares = [conns // procs + (1 if i < conns % procs else 0) for i in range(procs)]
    pipes, children = [], []
    for share in shares:
        rx, tx = Pipe(duplex=False)
        p = Process(target=worker, args=(tx, host, port, share, paths, duration, warmup, keepalive))
        p.start()
        tx.close()
        pipes.append(rx)
        children.append(p)
    lat = array("d")
    errors = 0
    codes = {}
    cpu = 0.0
    for rx in pipes:
        raw, e, c, t = rx.recv()
        lat.frombytes(raw)
        errors += e
        cpu += t
        for k, v in c.items():
            codes[k] = codes.get(k, 0) + v
    for p in children:
        p.join()
    return lat, errors, codes, cpu


# ----------------------------------------------------------------- sampler

class ProcSampler(threading.Thread):
    """Samples /proc/<pid> every `interval` seconds: cumulative CPU
    seconds (all threads), VmRSS, VmHWM, Threads, open fds."""

    def __init__(self, pid, interval=0.2):
        super().__init__(daemon=True)
        self.pid = pid
        self.interval = interval
        self.samples = []       # (t, cpu_s, rss_kb, hwm_kb, threads, fds)
        self.stop = threading.Event()
        self.ok = pid is not None and os.path.exists("/proc/%d/stat" % pid)

    def read(self):
        with open("/proc/%d/stat" % self.pid) as f:
            stat = f.read()
        fields = stat[stat.rindex(")") + 2:].split()
        cpu_s = (int(fields[11]) + int(fields[12])) / CLK_TCK   # utime + stime
        rss = hwm = threads = 0
        with open("/proc/%d/status" % self.pid) as f:
            for line in f:
                if line.startswith("VmRSS:"):
                    rss = int(line.split()[1])
                elif line.startswith("VmHWM:"):
                    hwm = int(line.split()[1])
                elif line.startswith("Threads:"):
                    threads = int(line.split()[1])
        try:
            fds = len(os.listdir("/proc/%d/fd" % self.pid))
        except OSError:
            fds = 0
        return (time.perf_counter(), cpu_s, rss, hwm, threads, fds)

    def run(self):
        while not self.stop.is_set():
            try:
                self.samples.append(self.read())
            except (OSError, ValueError):
                self.ok = False
                return
            self.stop.wait(self.interval)

    def window(self, t0, t1):
        """Stats over samples taken in [t0, t1]: cpu% (all threads),
        rss max, rss last, hwm, threads max, fds max."""
        s = [x for x in self.samples if t0 <= x[0] <= t1]
        if len(s) < 2:
            return None
        elapsed = s[-1][0] - s[0][0]
        cpu = (s[-1][1] - s[0][1]) / elapsed * 100.0 if elapsed > 0 else 0.0
        return {
            "cpu_pct": cpu,
            "rss_max_kb": max(x[2] for x in s),
            "rss_last_kb": s[-1][2],
            "hwm_kb": max(s[-1][3], max(x[2] for x in s)),   # /proc's VmRSS can briefly read above VmHWM
            "threads": max(x[4] for x in s),
            "fds_max": max(x[5] for x in s),
        }


class RemoteSampler(ProcSampler):
    """The same figures fetched from a --serve stats endpoint."""

    def __init__(self, stats_url, interval=0.2):
        super().__init__(None, interval)
        self.url = stats_url
        try:
            self.read()
            self.ok = True
        except Exception:
            self.ok = False

    def read(self):
        with urllib.request.urlopen(self.url, timeout=2) as r:
            d = json.loads(r.read())
        return (time.perf_counter(), d["cpu_s"], d["rss_kb"], d["hwm_kb"], d["threads"], d["fds"])


class StatsServer(threading.Thread):
    """GET /stats -> the sampler's current reading as JSON (the --serve side)."""

    def __init__(self, sampler, port):
        super().__init__(daemon=True)
        outer = self

        class H(BaseHTTPRequestHandler):
            def do_GET(self):
                if self.path != "/stats":
                    self.send_error(404)
                    return
                try:
                    t, cpu_s, rss, hwm, threads, fds = outer.sampler.read()
                except OSError:
                    self.send_error(503, "server gone")
                    return
                body = json.dumps({"pid": outer.sampler.pid, "cpu_s": cpu_s, "rss_kb": rss,
                                   "hwm_kb": hwm, "threads": threads, "fds": fds}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *a):
                pass

        self.sampler = sampler
        self.httpd = ThreadingHTTPServer(("0.0.0.0", port), H)

    def run(self):
        self.httpd.serve_forever()


# ------------------------------------------------------------------ server

def free_port():
    import socket
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def wait_up(url, secs=10):
    for _ in range(int(secs * 10)):
        try:
            urllib.request.urlopen(url, timeout=1).read()
            return True
        except Exception:
            time.sleep(0.1)
    return False


def raise_fd_limit():
    soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    if soft < hard:
        try:
            resource.setrlimit(resource.RLIMIT_NOFILE, (hard, hard))
        except ValueError:
            pass
    return resource.getrlimit(resource.RLIMIT_NOFILE)[0]


def lan_ip():
    """The address this host uses to reach the LAN (no packets are sent)."""
    import socket
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("10.255.255.255", 1))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except OSError:
        return socket.gethostbyname(socket.gethostname())


def spawn_server(threads, port=None, bind_all=False):
    """A seeded throwaway blogd in a scratch dir -> (proc, url, tmpdir).
    bind_all listens on every interface (the --serve side)."""
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    binary = os.path.join(root, "build", "blogd")
    if not os.access(binary, os.X_OK):
        sys.exit("loadtest: %s missing (run make)" % binary)
    tmp = tempfile.mkdtemp(prefix="blogd-load-")
    for d in ("templates", "static"):
        shutil.copytree(os.path.join(root, d), os.path.join(tmp, d))
    subprocess.run([binary, "init"], cwd=tmp, input=b"Load Blog\n5\nloadpass12345\nloadpass12345\n",
                   stdout=subprocess.DEVNULL, check=True)
    subprocess.run([binary, "seed"], cwd=tmp, stdout=subprocess.DEVNULL, check=True)
    port = port or free_port()
    log = open(os.path.join(tmp, "server.log"), "wb")
    env = dict(os.environ)
    if bind_all:
        env["BLOGD_BIND_ALL"] = "1"
    proc = subprocess.Popen([binary, str(port), str(threads)], cwd=tmp, stdout=log, stderr=log,
                            preexec_fn=raise_fd_limit, env=env)
    url = "http://127.0.0.1:%d" % port
    if not wait_up(url + "/health"):
        proc.kill()
        log.close()
        with open(os.path.join(tmp, "server.log"), errors="replace") as f:
            tail = f.read().strip()
        sys.exit("loadtest: server did not come up:\n%s" % tail)
    return proc, url, tmp


def port_free(port, host="0.0.0.0"):
    import socket
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        s.bind((host, port))
        return True
    except OSError:
        return False
    finally:
        s.close()


# ------------------------------------------------------------------ report

def pct(sorted_lat, p):
    if not sorted_lat:
        return 0.0
    k = int(round((len(sorted_lat) - 1) * p / 100.0))
    return sorted_lat[k]


def fmt_mb(kb):
    return "%.1f" % (kb / 1024.0)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--levels", default=DEFAULT_LEVELS, help="concurrent connections per step (default %s)" % DEFAULT_LEVELS)
    ap.add_argument("--duration", type=float, default=5.0, help="measured seconds per level (default 5)")
    ap.add_argument("--warmup", type=float, default=1.0, help="unmeasured seconds per level (default 1)")
    ap.add_argument("--procs", type=int, default=os.cpu_count() or 2, help="client processes (default: CPUs)")
    ap.add_argument("--paths", default=DEFAULT_PATHS, help="comma-separated request paths, cycled per connection")
    ap.add_argument("--no-keepalive", action="store_true", help="one connection per request")
    ap.add_argument("--threads", type=int, default=os.cpu_count() or 2, help="worker threads for the spawned server")
    ap.add_argument("--url", help="test this server instead of spawning one")
    ap.add_argument("--pid", type=int, help="PID to sample when --url is given (same machine)")
    ap.add_argument("--stats", help="stats endpoint of a --serve instance (default: --url's port + 1)")
    ap.add_argument("--serve", action="store_true", help="run the throwaway server for another machine and exit on Ctrl-C")
    ap.add_argument("--port", type=int, default=8090, help="--serve port (default 8090; stats on port + 1)")
    ap.add_argument("--slo", type=float, default=50.0, help="p99 latency budget in ms for the knee report (default 50)")
    ap.add_argument("--json", help="write every number to this file")
    args = ap.parse_args()

    if args.serve:
        return serve(args)

    levels = [int(x) for x in args.levels.split(",") if x.strip()]
    paths = [p.strip() for p in args.paths.split(",") if p.strip()]
    fd_limit = raise_fd_limit()
    if max(levels) + 64 > fd_limit:
        print("note: fd limit is %d; levels above ~%d will show connection errors (raise ulimit -n)"
              % (fd_limit, fd_limit - 64))

    proc = tmp = None
    if args.url:
        url = args.url.rstrip("/")
        pid = args.pid
    else:
        proc, url, tmp = spawn_server(args.threads)
        pid = proc.pid
    host, port = url.split("//", 1)[1].split(":")
    port = int(port)

    if pid:
        sampler = ProcSampler(pid)
    elif args.url:
        stats = args.stats or "http://%s:%d/stats" % (host, port + 1)
        sampler = RemoteSampler(stats)
        if sampler.ok:
            print("server figures from %s" % stats)
        elif args.stats:
            sys.exit("loadtest: no stats endpoint at %s (is --serve running there?)" % stats)
        else:
            print("no stats endpoint at %s: server columns will be blank (start the other side with --serve, or pass --pid on the same machine)" % stats)
    else:
        sampler = None
    if sampler and sampler.ok:
        sampler.start()
        time.sleep(0.5)
        idle = sampler.read()
    else:
        sampler = None
        idle = None

    keepalive = not args.no_keepalive
    print("target %s  pid %s  server threads %s  client procs %d  %s  paths %d"
          % (url, pid or "-", args.threads if proc else "?", args.procs,
             "keep-alive" if keepalive else "connection: close", len(paths)))
    if idle:
        print("idle: rss %s MB, %d threads, %d fds" % (fmt_mb(idle[2]), idle[4], idle[5]))
    ncpu = os.cpu_count() or 1
    if not args.url and args.procs + args.threads > ncpu:
        print("note: %d client processes and %d server threads share %d cores; server figures are conservative"
              % (args.procs, args.threads, ncpu))
    hdr = "%6s %9s %8s %8s %8s %8s %8s %7s %7s | %7s %8s %8s %4s %5s | %7s" % (
        "conns", "req/s", "avg ms", "p50", "p95", "p99", "max", "errors", "non200",
        "cpu%", "rss MB", "peak MB", "thr", "fds", "cli cpu%")
    print(hdr)
    print("-" * len(hdr))

    rows = []
    for conns in levels:
        t0 = time.perf_counter()
        lat, errors, codes, cpu_s = run_level(host, port, conns, paths, args.duration, args.warmup, keepalive, args.procs)
        t1 = time.perf_counter()
        cli_cpu = cpu_s / (t1 - t0) * 100.0
        s = sorted(lat)
        n = len(s)
        window = sampler.window(t0 + args.warmup, t1) if sampler else None
        row = {
            "conns": conns, "requests": n, "rps": n / args.duration if n else 0.0,
            "avg_ms": (sum(s) / n) if n else 0.0,
            "p50_ms": pct(s, 50), "p95_ms": pct(s, 95), "p99_ms": pct(s, 99), "max_ms": s[-1] if n else 0.0,
            "errors": errors, "non200": sum(v for k, v in codes.items() if k != 200), "codes": codes,
            "client_cpu_pct": cli_cpu, "server": window,
        }
        rows.append(row)
        srv = window or {}
        print("%6d %9.0f %8.2f %8.2f %8.2f %8.2f %8.1f %7d %7d | %7s %8s %8s %4s %5s | %7.0f%s" % (
            conns, row["rps"], row["avg_ms"], row["p50_ms"], row["p95_ms"], row["p99_ms"], row["max_ms"],
            errors, row["non200"],
            ("%.0f" % srv["cpu_pct"]) if srv else "-", fmt_mb(srv["rss_max_kb"]) if srv else "-",
            fmt_mb(srv["hwm_kb"]) if srv else "-", srv.get("threads", "-"), srv.get("fds_max", "-"),
            cli_cpu, "*" if cli_cpu > 85.0 * args.procs else ""))
        sys.stdout.flush()

    if sampler:
        sampler.stop.set()
    if proc:
        proc.terminate()
        proc.wait()
        shutil.rmtree(tmp, ignore_errors=True)

    # ---- break points
    print()
    knee = next((r for r in rows if r["p99_ms"] > args.slo), None)
    if knee:
        i = rows.index(knee)
        prev = rows[i - 1]["conns"] if i else 0
        print("p99 crosses %.0f ms between %d and %d connections (p99 %.1f ms at %d)"
              % (args.slo, prev, knee["conns"], knee["p99_ms"], knee["conns"]))
    else:
        print("p99 stays under %.0f ms at every level (%.1f ms at %d connections)"
              % (args.slo, rows[-1]["p99_ms"], rows[-1]["conns"]))
    best = max(rows, key=lambda r: r["rps"])
    sat = next((rows[i] for i in range(1, len(rows)) if rows[i]["rps"] < rows[i - 1]["rps"] * 1.05), None)
    if sat:
        print("throughput stops growing at %d connections (peak %.0f req/s at %d)"
              % (rows[rows.index(sat) - 1]["conns"], best["rps"], best["conns"]))
    else:
        print("throughput still growing at the last level (peak %.0f req/s at %d connections)"
              % (best["rps"], best["conns"]))
    err = next((r for r in rows if r["errors"] or r["non200"]), None)
    if err:
        print("first errors at %d connections: %d failed, %d non-200 %s"
              % (err["conns"], err["errors"], err["non200"],
                 {k: v for k, v in err["codes"].items() if k != 200}))
    else:
        print("no errors or non-200 responses at any level")
    if idle and rows[-1]["server"]:
        top = rows[-1]
        delta_kb = top["server"]["rss_max_kb"] - idle[2]
        print("memory: idle %s MB -> %s MB at %d connections (%.0f KB per connection), peak ever %s MB"
              % (fmt_mb(idle[2]), fmt_mb(top["server"]["rss_max_kb"]), top["conns"],
                 delta_kb / max(1, top["conns"]), fmt_mb(top["server"]["hwm_kb"])))
    if any(r["client_cpu_pct"] > 85.0 * args.procs for r in rows):
        print("* client processes were near saturation at starred levels: those numbers bound the client, not the server (add --procs or a second machine)")

    if args.json:
        with open(args.json, "w") as f:
            json.dump({"target": url, "levels": levels, "paths": paths, "keepalive": keepalive,
                       "duration": args.duration, "warmup": args.warmup, "procs": args.procs,
                       "idle": {"rss_kb": idle[2], "threads": idle[4], "fds": idle[5]} if idle else None,
                       "rows": rows}, f, indent=1)
        print("wrote %s" % args.json)


def serve(args):
    """--serve: the throwaway server on every interface plus /stats."""
    for p in (args.port, args.port + 1):
        if not port_free(p):
            sys.exit("loadtest: port %d is already in use (ss -ltnp | grep ':%d'); pick another with --port"
                     % (p, args.port))
    proc, url, tmp = spawn_server(args.threads, args.port, bind_all=True)
    sampler = ProcSampler(proc.pid)
    stats = StatsServer(sampler, args.port + 1)
    stats.start()
    ip = lan_ip()
    print("throwaway seeded blogd on every interface (plain HTTP, demo content, %d threads)" % args.threads)
    print("stats endpoint: http://%s:%d/stats" % (ip, args.port + 1))
    print()
    print("on the other machine:  tools/loadtest.py --url http://%s:%d" % (ip, args.port))
    print()
    print("Ctrl-C stops the server and deletes %s" % tmp)
    sys.stdout.flush()
    try:
        while proc.poll() is None:
            time.sleep(0.5)
        print("server exited with %d (see %s/server.log)" % (proc.returncode, tmp))
    except KeyboardInterrupt:
        pass
    finally:
        if proc.poll() is None:
            proc.terminate()
            proc.wait()
        stats.httpd.shutdown()
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
