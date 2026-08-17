"""Run every object-store candidate through an identical benchmark.

Same seven routes, same bytes, same core split, same wrk invocation. Each
candidate is verified byte-for-byte before it is allowed to produce a number,
and its presigned URL is fetched with a client carrying no credentials — a
signer that is fast and wrong fails here rather than winning a table.

Where this differs from `bench/compare/`'s driver is that there are **three**
parties, not two. A benchmark that pins the server and the load generator to
whole cores and lets MinIO land wherever is a benchmark of the scheduler: the
store ends up sharing silicon with whichever side happened to be busy, and the
ratios move between runs. So this splits the machine three ways and moves the
container too, which the HTTP harness never had to do.

That, and the fact that a run of this needs a container up and a bucket seeded,
is why this is a directory of its own rather than more candidates in
`bench/compare/`. Nothing here shares a file with that harness.

    python3 bench/compare-s3/drive.py                 # everything
    python3 bench/compare-s3/drive.py nilo go         # or just these
    DURATION=20s python3 bench/compare-s3/drive.py    # longer than the 10s default

Results land in `results/raw.json`, next to this file and nowhere near the HTTP
comparison's. The write-up is `bench/result/s3.md`.
"""
import json
import os
import re
import signal
import socket
import subprocess
import sys
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))

ENDPOINT = os.environ.get("S3_ENDPOINT", "http://127.0.0.1:9100")
ACCESS_KEY = os.environ.get("S3_ACCESS_KEY", "niloadmin")
SECRET_KEY = os.environ.get("S3_SECRET_KEY", "nilosecret123")

# Three parties on eight physical cores: three each for the server and the load
# generator, two for the store. The sibling harness splits four and four
# because it has nobody else to pay; here a fourth core each would be taken out
# of MinIO's, and a store that is short of CPU makes every candidate look the
# same — which is the one outcome that would tell us nothing.
#
# These are this machine's pairs (an AMD 9700X: 8 cores, 16 threads, sibling of
# cpu0 is cpu8). Check your own before trusting them:
#   cat /sys/devices/system/cpu/cpu0/topology/thread_siblings_list
SERVER_CPUS = os.environ.get("SERVER_CPUS", "0-2,8-10")
CLIENT_CPUS = os.environ.get("CLIENT_CPUS", "3-5,11-13")
MINIO_CPUS = os.environ.get("MINIO_CPUS", "6-7,14-15")
MINIO_CONTAINER = os.environ.get("MINIO_CONTAINER", "nilo-s3-minio")

WRK = ["wrk", "-t4", "-c64", "--latency"]
DURATION = os.environ.get("DURATION", "10s")
WARMUP = os.environ.get("WARMUP", "5s")
REPEATS = int(os.environ.get("REPEATS", "3"))

S3_ENV = {"S3_ENDPOINT": ENDPOINT, "S3_ACCESS_KEY": ACCESS_KEY,
          "S3_SECRET_KEY": SECRET_KEY}

# What `bench/s3_setup.py` wrote, and therefore what every candidate has to
# answer with. Built here rather than read from a fixture so the harness cannot
# quietly agree with a server that is wrong in the same way.
FILLER = b"x"
SIZES = {"1k": 1 << 10, "64k": 64 << 10, "1m": 1 << 20}

# The seven routes, in three classes. The classes are the whole point: `store`
# minus `floor` at the same size is what an object-store client costs, and
# `floor` on its own is what this language's HTTP server costs. A table of
# `store` rows alone is four HTTP servers wearing an S3 client as a hat.
ROUTES = [
    dict(path="/health", cls="floor", body=b"alive\n", ctype="text/plain"),
    dict(path="/warm/1k", cls="floor", body=FILLER * SIZES["1k"]),
    dict(path="/warm/1m", cls="floor", body=FILLER * SIZES["1m"]),
    dict(path="/o/1k", cls="store", body=FILLER * SIZES["1k"]),
    dict(path="/o/64k", cls="store", body=FILLER * SIZES["64k"]),
    dict(path="/o/1m", cls="store", body=FILLER * SIZES["1m"]),
    dict(path="/presign", cls="sign", body=None, ctype="text/plain"),
]

NILO = os.path.join(REPO, "zig-out", "bin", "nilo-bench-s3-server")

CANDIDATES = [
    dict(key="nilo", label="nilo (nilo_s3)", port=8792, cmd=[NILO]),
    dict(key="go", label="Go net/http + aws-sdk-go-v2", port=8811,
         cmd=[f"{HERE}/go/go-bench"]),
    dict(key="rust", label="Rust axum + aws-sdk-s3", port=8812,
         cmd=[f"{HERE}/rust/target/release/s3rust"]),
    dict(key="bun1", label="Bun.serve + Bun.S3Client (1 process)", port=8813,
         cmd=["bun", f"{HERE}/bun/server.js"]),
    dict(key="bun6", label="Bun.serve + Bun.S3Client (6 processes, reusePort)",
         port=8813, cmd=["bun", f"{HERE}/bun/server.js"],
         env={"CLUSTER": "1"}, procs=6),
]


# ---------------------------------------------------------------- proc helpers

def children_of(pid, acc=None):
    if acc is None:
        acc = []
    acc.append(pid)
    try:
        with open(f"/proc/{pid}/task/{pid}/children") as f:
            for c in f.read().split():
                children_of(int(c), acc)
    except OSError:
        pass
    return acc


def tree(roots):
    out = []
    for r in roots:
        out.extend(children_of(r))
    return sorted(set(out))


def cpu_ticks(pids):
    total = 0
    for pid in pids:
        try:
            with open(f"/proc/{pid}/stat") as f:
                fields = f.read().rsplit(") ", 1)[1].split()
            total += int(fields[11]) + int(fields[12])  # utime + stime
        except (OSError, IndexError):
            pass
    return total


def rss_kb(pids):
    total = 0
    for pid in pids:
        try:
            with open(f"/proc/{pid}/status") as f:
                for line in f:
                    if line.startswith("VmRSS:"):
                        total += int(line.split()[1])
                        break
        except OSError:
            pass
    return total


def threads(pids):
    n = 0
    for pid in pids:
        try:
            n += len(os.listdir(f"/proc/{pid}/task"))
        except OSError:
            pass
    return n


# ------------------------------------------------------------------- lifecycle

def pin_minio():
    """Give the store its own cores, or say plainly that it did not get them.

    An unpinned MinIO is the difference between a benchmark of four clients and
    a benchmark of the Linux scheduler, so this failing quietly would be worse
    than it failing loudly.
    """
    if not MINIO_CONTAINER:
        print("MinIO not pinned (MINIO_CONTAINER empty) — numbers are noisier",
              flush=True)
        return False
    r = subprocess.run(
        ["docker", "update", "--cpuset-cpus", MINIO_CPUS, MINIO_CONTAINER],
        capture_output=True, text=True)
    if r.returncode != 0:
        print(f"could not pin {MINIO_CONTAINER} to {MINIO_CPUS}: "
              f"{r.stderr.strip()} — numbers are noisier", flush=True)
        return False
    print(f"MinIO pinned to CPUs {MINIO_CPUS}", flush=True)
    return True


def start(cand):
    env = dict(os.environ)
    env.update(S3_ENV)
    env.update(cand.get("env", {}))
    env["NODE_ENV"] = "production"
    procs = []
    for _ in range(cand.get("procs", 1)):
        p = subprocess.Popen(
            ["taskset", "-c", SERVER_CPUS] + cand["cmd"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            env=env, start_new_session=True,
        )
        procs.append(p)
    return procs


def wait_up(port, timeout=30):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), 0.5):
                return True
        except OSError:
            time.sleep(0.2)
    return False


def stop(procs):
    for p in procs:
        try:
            os.killpg(os.getpgid(p.pid), signal.SIGTERM)
        except OSError:
            pass
    time.sleep(1)
    for p in procs:
        try:
            os.killpg(os.getpgid(p.pid), signal.SIGKILL)
        except OSError:
            pass
        try:
            p.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass
    time.sleep(1)


# ---------------------------------------------------------------- verification

def http_get(port, path):
    s = socket.create_connection(("127.0.0.1", port), 5)
    s.settimeout(30)
    s.sendall(f"GET {path} HTTP/1.1\r\nHost: 127.0.0.1\r\n"
              f"Connection: keep-alive\r\n\r\n".encode())
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = s.recv(65536)
        if not chunk:
            break
        buf += chunk
    head, _, body = buf.partition(b"\r\n\r\n")
    clen = None
    for line in head.split(b"\r\n"):
        if line.lower().startswith(b"content-length:"):
            clen = int(line.split(b":")[1])
    if clen is None:
        s.close()
        return head.decode("latin1"), body, False
    while len(body) < clen:
        part = s.recv(65536)
        if not part:
            break
        body += part
    s.close()
    return head.decode("latin1"), body, True


def verify(cand):
    """Every candidate answers the same bytes, or it does not get a number."""
    problems, wire = [], {}
    for route in ROUTES:
        try:
            head, body, framed = http_get(cand["port"], route["path"])
        except OSError as e:
            problems.append(f"{route['path']}: {type(e).__name__}: {e}")
            continue

        if "200" not in head.split("\r\n")[0]:
            problems.append(f"{route['path']}: {head.split(chr(13))[0]!r}")
            continue
        if not framed:
            # Chunked where everybody else sends a length is 12 bytes of
            # framing that flatter whoever skipped it. Caught here, not later.
            problems.append(f"{route['path']}: no Content-Length (chunked?)")
        if route["body"] is not None and body != route["body"]:
            problems.append(f"{route['path']}: {len(body)} bytes, "
                            f"want {len(route['body'])}")
        ctype = route.get("ctype", "application/octet-stream")
        if ctype not in head.lower():
            problems.append(f"{route['path']}: content-type is not {ctype}")
        wire[route["path"]] = len(head.encode()) + 4 + len(body)

    # The signer, checked by using it: a presigned URL is only correct if
    # something that did not compute it can fetch the object.
    try:
        _, link, _ = http_get(cand["port"], "/presign")
        with urllib.request.urlopen(link.decode(), timeout=15) as r:
            got = r.read()
        if r.status != 200 or got != FILLER * SIZES["1k"]:
            problems.append(f"presigned URL returned {r.status} {len(got)} bytes")
    except Exception as e:
        problems.append(f"presigned URL did not work: {type(e).__name__}: {e}")

    return problems, wire


# ----------------------------------------------------------------- measurement

def one_run(cand, path, pids):
    before = cpu_ticks(pids)
    t0 = time.time()
    out = subprocess.run(
        ["taskset", "-c", CLIENT_CPUS] + WRK + ["-d", DURATION,
         f"http://127.0.0.1:{cand['port']}{path}"],
        capture_output=True, text=True).stdout
    elapsed = time.time() - t0
    after = cpu_ticks(pids)

    def pct(label):
        m = re.search(rf"^\s+{label}%\s+(\S+)$", out, re.M)
        return m.group(1) if m else "?"

    m = re.search(r"Requests/sec:\s+([\d.]+)", out)
    if not m:
        return dict(rps=0.0, p50="?", p90="?", p99="?", cpu=0.0,
                    ns_per_req=0.0, errors="wrk produced no number", non2xx=0)
    rps = float(m.group(1))
    cpu = (after - before) / os.sysconf("SC_CLK_TCK") / elapsed * 100
    errors = re.search(r"Socket errors: (.+)", out)
    non2xx = re.search(r"Non-2xx or 3xx responses: (\d+)", out)

    return dict(
        rps=rps, p50=pct("50"), p90=pct("90"), p99=pct("99"),
        cpu=cpu, ns_per_req=(cpu / 100 / rps * 1e9) if rps else 0.0,
        errors=errors.group(1) if errors else "",
        non2xx=int(non2xx.group(1)) if non2xx else 0,
    )


def bench_all(cand, pids):
    """Every route, `REPEATS` times, **interleaved rather than blocked**.

    The obvious shape is three runs of `/o/1k`, then three of `/warm/1k`. Do
    not: the number this benchmark exists for is the *difference* between those
    two routes, and blocking them puts a quarter of an hour between the halves
    of every pair. Anything that drifts in that quarter of an hour — another
    process, the fans, the governor — lands entirely on one side of the
    subtraction and is reported as what an S3 client costs.

    So one pass is all seven routes back to back, and there are `REPEATS`
    passes. Each pass yields a paired difference taken seconds apart, and the
    passes are the replicates.

    **A paired difference is reported only if all the passes agree on its
    sign.** A confidence interval pooled across passes is over-confident,
    because blocks within a pass are not exchangeable with blocks in another
    one — each pass has its own thermal state. Split back out, a difference
    smaller than the harness can resolve changes sign between passes, and the
    pooled interval would have excluded zero and called it real. (Found next
    door, on the ORM comparison, where every one of one candidate's differences
    flipped sign once the passes were separated.)
    """
    for route in ROUTES:  # nobody pays a first-call cost inside a pass
        subprocess.run(
            ["taskset", "-c", CLIENT_CPUS] + WRK +
            ["-d", WARMUP, f"http://127.0.0.1:{cand['port']}{route['path']}"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    passes = []
    for n in range(REPEATS):
        # Said out loud, because interleaving costs the operator every line of
        # feedback: nothing can be printed per route until every pass is in, so
        # without this the harness is silent for minutes and looks hung.
        print(f"  pass {n + 1}/{REPEATS}...", flush=True)
        passes.append({r["path"]: one_run(cand, r["path"], pids)
                       for r in ROUTES})
    return passes


def summarise(path, passes):
    """The median pass for one route, with every pass kept beside it."""
    runs = sorted((p[path] for p in passes), key=lambda r: r["rps"])
    median = dict(runs[len(runs) // 2])
    median["all_rps"] = [p[path]["rps"] for p in passes]
    median["all_ns"] = [p[path]["ns_per_req"] for p in passes]
    return median


# What each `store` route is subtracted from: the same bytes with no object
# store behind them. `/o/64k` has no floor of its own, so it is paired with
# nothing and reported as an absolute.
PAIRS = [("/o/1k", "/warm/1k"), ("/o/1m", "/warm/1m")]


def paired(passes):
    """What the object-store client costs, per pass, and whether that survives.

    Reported as CPU ns per request, because req/s at two different response
    sizes is not a difference anybody can subtract.
    """
    out = {}
    for store_path, floor_path in PAIRS:
        deltas = [p[store_path]["ns_per_req"] - p[floor_path]["ns_per_req"]
                  for p in passes]
        agree = all(d > 0 for d in deltas) or all(d < 0 for d in deltas)
        out[store_path] = dict(floor=floor_path, deltas=deltas, agree=agree,
                               median=sorted(deltas)[len(deltas) // 2])
    return out


def idle_memory(cand, pids, steps=(1000, 2000, 5000, 10000)):
    """What one idle keep-alive connection costs, on /health.

    Taken out to 10,000 for the reason `bench/result/ws-idle` gives: at 2,000
    the marginal cost and the average still disagree, which means the reading
    is a transient rather than a property of the connection.
    """
    req = (b"GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\n"
           b"Connection: keep-alive\r\n\r\n")
    time.sleep(2)
    base = rss_kb(pids)
    conns, rows = [], []
    capped_at = None
    try:
        for target in steps:
            while len(conns) < target:
                try:
                    s = socket.create_connection(("127.0.0.1", cand["port"]), 5)
                    s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                    s.settimeout(5)
                    s.sendall(req)
                    buf = b""
                    while b"\r\n\r\n" not in buf:
                        chunk = s.recv(4096)
                        if not chunk:
                            raise OSError("closed")
                        buf += chunk
                    head, _, rest = buf.partition(b"\r\n\r\n")
                    clen = 0
                    for h in head.split(b"\r\n"):
                        if h.lower().startswith(b"content-length:"):
                            clen = int(h.split(b":")[1])
                    while len(rest) < clen:
                        rest += s.recv(4096)
                    conns.append(s)
                except (OSError, TimeoutError):
                    capped_at = len(conns)
                    print(f"  !! stopped accepting at {capped_at:,} connections",
                          flush=True)
                    break
            if not conns:
                break
            time.sleep(3)
            now = rss_kb(pids)
            prev_n = rows[-1]["n"] if rows else 0
            prev_rss = rows[-1]["rss_kb"] if rows else base
            if len(conns) > prev_n:
                rows.append(dict(
                    n=len(conns), rss_kb=now,
                    per_conn=(now - base) * 1024 / len(conns),
                    marginal=(now - prev_rss) * 1024 / (len(conns) - prev_n),
                ))
            if capped_at is not None:
                break
    finally:
        for s in conns:
            s.close()
    return dict(base_kb=base, rows=rows, capped_at=capped_at)


# ------------------------------------------------------------------------ main

def save(results):
    os.makedirs(os.path.join(HERE, "results"), exist_ok=True)
    with open(os.path.join(HERE, "results", "raw.json"), "w") as f:
        json.dump(results, f, indent=2)


def load():
    try:
        with open(os.path.join(HERE, "results", "raw.json")) as f:
            return json.load(f)
    except (FileNotFoundError, ValueError):
        return {}


def main():
    only = sys.argv[1:]
    results = load() if only else {}
    if results:
        print("keeping recorded results for: "
              + ", ".join(k for k in results if k not in only), flush=True)

    pinned = pin_minio()
    print(f"server {SERVER_CPUS} | client {CLIENT_CPUS} | "
          f"store {MINIO_CPUS if pinned else 'unpinned'} | "
          f"{REPEATS}x{DURATION} after {WARMUP}", flush=True)

    for cand in CANDIDATES:
        if only and cand["key"] not in only:
            continue
        print(f"\n===== {cand['label']} =====", flush=True)
        procs = start(cand)
        try:
            if not wait_up(cand["port"]):
                print("  DID NOT START", flush=True)
                results[cand["key"]] = dict(label=cand["label"],
                                            error="did not start")
                save(results)
                continue
            time.sleep(2)
            pids = tree([p.pid for p in procs])

            problems, wire = verify(cand)
            if problems:
                print("  PAYLOAD MISMATCH: " + "; ".join(problems), flush=True)
                results[cand["key"]] = dict(label=cand["label"], error=problems)
                save(results)
                continue
            print(f"  seven routes verified, presigned URL fetched clean",
                  flush=True)
            print(f"  processes={len(pids)} threads={threads(pids)}", flush=True)

            passes = bench_all(cand, pids)
            routes = {}
            for route in ROUTES:
                b = summarise(route["path"], passes)
                routes[route["path"]] = dict(cls=route["cls"],
                                             wire=wire[route["path"]], **b)
                flag = ""
                if b["errors"] or b["non2xx"]:
                    flag = f"  !! errors={b['errors']} non2xx={b['non2xx']}"
                print(f"  {route['path']:<10} {b['rps']:>11,.0f} req/s  "
                      f"p50 {b['p50']:>8}  p99 {b['p99']:>8}  "
                      f"{b['ns_per_req']:>7,.0f} ns CPU/req{flag}", flush=True)

            # The number this whole harness exists for, and the check that
            # says whether it is a number at all.
            deltas = paired(passes)
            for store_path, d in deltas.items():
                per_pass = ", ".join(f"{x:+,.0f}" for x in d["deltas"])
                verdict = "" if d["agree"] else "   <-- SIGN FLIPS, not a result"
                print(f"  {store_path} - {d['floor']}: "
                      f"{d['median']:+,.0f} ns CPU/req  "
                      f"[{per_pass}]{verdict}", flush=True)

            # A fresh process for the memory reading: the one that just served
            # a benchmark has every fiber stack at its high-water mark, which
            # is a different question from what an idle connection costs.
            stop(procs)
            procs = start(cand)
            wait_up(cand["port"])
            time.sleep(2)
            pids = tree([p.pid for p in procs])
            m = idle_memory(cand, pids)
            print(f"  idle baseline: {m['base_kb']:,} kB", flush=True)
            for r in m["rows"]:
                print(f"  {r['n']:>6} idle conns: {r['rss_kb']:>9,} kB  "
                      f"avg {r['per_conn']:>8,.0f}  "
                      f"marginal {r['marginal']:>8,.0f} B/conn", flush=True)

            results[cand["key"]] = dict(label=cand["label"], procs=len(pids),
                                        routes=routes, paired=deltas,
                                        passes=passes, memory=m)
            save(results)
        except Exception as e:  # one candidate failing must not lose the rest
            print(f"  FAILED: {type(e).__name__}: {e}", flush=True)
            results.setdefault(cand["key"], dict(label=cand["label"]))["error"] = str(e)
            save(results)
        finally:
            stop(procs)

    save(results)
    print("\nwrote results/raw.json", flush=True)


if __name__ == "__main__":
    main()
