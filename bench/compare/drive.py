"""Run every candidate through an identical benchmark.

Same route, same 982-byte payload, same core split, same wrk invocation.
Each candidate is verified byte-for-byte against zfast's response before it is
allowed to produce a number.
"""
import json
import os
import re
import signal
import socket
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))

# The body every candidate has to return, byte for byte. Built here rather than
# read from a fixture so it cannot drift away from src/main.zig unnoticed.
BIO = "A systems nerd who writes Zig before breakfast. " * 19
EXPECTED = json.dumps(
    {"id": 42, "name": "Routed Tester", "email": "tester@example.dev", "bio": BIO},
    separators=(",", ":"),
).encode()

# The core split is this machine's. Check your own topology before trusting it:
#   cat /sys/devices/system/cpu/cpu0/topology/thread_siblings_list
# On an SMT machine `0-7` is not eight cores — see docs/benchmarks.md.
SERVER_CPUS = os.environ.get("SERVER_CPUS", "0-3,8-11")
CLIENT_CPUS = os.environ.get("CLIENT_CPUS", "4-7,12-15")
WRK = ["wrk", "-t4", "-c64", "--latency"]
DURATION = os.environ.get("DURATION", "30s")
WARMUP = os.environ.get("WARMUP", "10s")

ZFAST = os.path.join(REPO, "zig-out", "bin", "zfast-hello")

CANDIDATES = [
    dict(key="zfast", label="zfast", port=8787, cmd=[ZFAST]),
    dict(key="gonet", label="Go net/http", port=8801,
         cmd=[f"{HERE}/gonet/gonet-bench"]),
    dict(key="gofiber", label="Go Fiber v2", port=8802,
         cmd=[f"{HERE}/gofiber/gofiber-bench"]),
    dict(key="httpzig", label="http.zig", port=8806,
         cmd=[f"{HERE}/httpzig/zig-out/bin/httpzig-bench"]),
    dict(key="axum", label="Rust axum", port=8805,
         cmd=[f"{HERE}/rustaxum/target/release/rustaxum"]),
    dict(key="node1", label="Node http (1 thread, default)", port=8803,
         cmd=["node", f"{HERE}/nodehttp/server.js"]),
    dict(key="node8", label="Node http (cluster, 8 workers)", port=8803,
         cmd=["node", f"{HERE}/nodehttp/server.js"], env={"CLUSTER": "8"}),
    dict(key="bun1", label="Bun.serve (1 process, default)", port=8804,
         cmd=["bun", f"{HERE}/bunhttp/server.js"]),
    dict(key="bun8", label="Bun.serve (8 processes, reusePort)", port=8804,
         cmd=["bun", f"{HERE}/bunhttp/server.js"], env={"CLUSTER": "1"}, procs=8),
]


# ---------------------------------------------------------------- proc helpers

def children_of(pid, acc=None):
    """Every pid in the tree rooted at pid, including pid."""
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

def start(cand):
    env = dict(os.environ)
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


def wait_up(port, timeout=20):
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
    s.settimeout(10)
    s.sendall(f"GET {path} HTTP/1.1\r\nHost: 127.0.0.1\r\n"
              f"Connection: keep-alive\r\n\r\n".encode())
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = s.recv(65536)
        if not chunk:
            break
        buf += chunk
    head, _, body = buf.partition(b"\r\n\r\n")
    clen = 0
    for line in head.split(b"\r\n"):
        if line.lower().startswith(b"content-length:"):
            clen = int(line.split(b":")[1])
    while len(body) < clen:
        body += s.recv(65536)
    s.close()
    return head.decode("latin1"), body


def verify(cand):
    """Every candidate must return exactly the bytes zfast returns."""
    head, body = http_get(cand["port"], "/users/42")
    status = head.split("\r\n")[0]
    problems = []
    if "200" not in status:
        problems.append(f"status {status!r}")
    if body != EXPECTED:
        problems.append(f"body differs ({len(body)} bytes, want {len(EXPECTED)})")
    if "application/json" not in head.lower():
        problems.append("content-type is not application/json")
    if "access-control-allow-origin" not in head.lower():
        problems.append("no CORS header")

    head404, _ = http_get(cand["port"], "/users/9999999")
    if "404" not in head404.split("\r\n")[0]:
        problems.append(f"missing user is not a 404: {head404.split(chr(13))[0]!r}")

    return problems, len(head.encode()) + 4 + len(body)


# ----------------------------------------------------------------- measurement

def one_run(cand, pids):
    before = cpu_ticks(pids)
    t0 = time.time()
    out = subprocess.run(
        ["taskset", "-c", CLIENT_CPUS] + WRK + ["-d", DURATION,
         f"http://127.0.0.1:{cand['port']}/users/42"],
        capture_output=True, text=True).stdout
    elapsed = time.time() - t0
    after = cpu_ticks(pids)

    def pct(label):
        m = re.search(rf"^\s+{label}%\s+(\S+)$", out, re.M)
        return m.group(1) if m else "?"

    rps = float(re.search(r"Requests/sec:\s+([\d.]+)", out).group(1))
    cpu = (after - before) / os.sysconf("SC_CLK_TCK") / elapsed * 100
    errors = re.search(r"Socket errors: (.+)", out)
    non2xx = re.search(r"Non-2xx or 3xx responses: (\d+)", out)

    return dict(
        rps=rps, p50=pct("50"), p90=pct("90"), p99=pct("99"),
        cpu=cpu, ns_per_req=cpu / 100 / rps * 1e9,
        errors=errors.group(1) if errors else "",
        non2xx=int(non2xx.group(1)) if non2xx else 0,
    )


def bench(cand, pids, repeats=3):
    subprocess.run(["taskset", "-c", CLIENT_CPUS] + WRK + ["-d", WARMUP,
                    f"http://127.0.0.1:{cand['port']}/users/42"],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    runs = [one_run(cand, pids) for _ in range(repeats)]
    runs.sort(key=lambda r: r["rps"])
    median = dict(runs[len(runs) // 2])
    median["all_rps"] = [r["rps"] for r in runs]
    median["runs"] = runs
    return median


def idle_memory(cand, pids, steps=(1000, 2000, 5000, 10000)):
    req = (f"GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\n"
           f"Connection: keep-alive\r\n\r\n").encode()
    time.sleep(2)
    base = rss_kb(pids)
    conns, rows = [], []
    capped_at = None
    try:
        for target in steps:
            while len(conns) < target:
                # A server with a connection cap stops answering rather than
                # refusing, so a timeout here is a finding, not a harness bug.
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
            if capped_at is not None:
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
                break
            time.sleep(3)
            now = rss_kb(pids)
            prev_n = rows[-1]["n"] if rows else 0
            prev_rss = rows[-1]["rss_kb"] if rows else base
            rows.append(dict(
                n=len(conns), rss_kb=now,
                per_conn=(now - base) * 1024 / len(conns),
                marginal=(now - prev_rss) * 1024 / (len(conns) - prev_n),
            ))
    finally:
        for s in conns:
            s.close()
    return dict(base_kb=base, rows=rows, capped_at=capped_at)


# ------------------------------------------------------------------------ main

def save(results):
    with open(os.path.join(HERE, "results", "raw.json"), "w") as f:
        json.dump(results, f, indent=2)


def main():
    only = sys.argv[1:]
    results = {}
    for cand in CANDIDATES:
        if only and cand["key"] not in only:
            continue
        print(f"\n===== {cand['label']} =====", flush=True)
        procs = start(cand)
        try:
            if not wait_up(cand["port"]):
                print("  DID NOT START", flush=True)
                continue
            time.sleep(2)
            pids = tree([p.pid for p in procs])
            problems, wire = verify(cand)
            if problems:
                print("  PAYLOAD MISMATCH: " + "; ".join(problems), flush=True)
                results[cand["key"]] = dict(label=cand["label"], error=problems)
                continue
            print(f"  payload verified: {len(EXPECTED)} bytes body, "
                  f"{wire} bytes on the wire", flush=True)
            print(f"  processes={len(pids)} threads={threads(pids)}", flush=True)

            b = bench(cand, pids)
            print(f"  {b['rps']:>12,.0f} req/s   p50 {b['p50']:>8}  "
                  f"p90 {b['p90']:>8}  p99 {b['p99']:>8}", flush=True)
            print("  runs: " + ", ".join(f"{r:,.0f}" for r in b["all_rps"]),
                  flush=True)
            print(f"  server CPU {b['cpu']:.0f}%   "
                  f"{b['ns_per_req']:.0f} ns CPU/req", flush=True)
            if b["errors"] or b["non2xx"]:
                print(f"  !! errors={b['errors']} non2xx={b['non2xx']}", flush=True)

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

            results[cand["key"]] = dict(label=cand["label"], wire=wire,
                                        procs=len(pids), **b, memory=m)
            save(results)
        except Exception as e:  # one candidate failing must not lose the rest
            print(f"  FAILED: {type(e).__name__}: {e}", flush=True)
            results.setdefault(cand["key"], dict(label=cand["label"]))["error"] = str(e)
            save(results)
        finally:
            stop(procs)

    save(results)
    print(f"\nwrote results/raw.json", flush=True)


if __name__ == "__main__":
    main()
