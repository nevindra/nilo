#!/usr/bin/env python3
"""Which executor each long-lived keep-alive connection lives on, and whether the
load on the executors stays uneven for as long as the connections do.

A connection is served by the executor it was dealt to (ADR 199) and the server
never closes one on its own, so where a connection was put on the day it opened
is where it stays. This client opens connections to `bench/keepalive_server.zig`
in a stated order, keeps them, and reads two things out of the server: the thread
that answered each request (the body), and each thread's CPU from
/proc/<pid>/task/<tid>/stat. It reports, per window of the run, the CPU each
executor spent and how many busy and idle connections it held.

A plan is a string of classes opened one after another, each waiting for its first
answer, so the order the server deals them in is the order written:

    B  busy: a `/work/<us>` request every `--period` ms, for the whole run
    I  idle: a `/tid` request every `--idle-period` s (a mobile client, a pool member)
    S  short: one request, then closed after `--short-life` s (churn between them)

A connection the server closes (`Connection: close`, or EOF) is reopened as the
same class, to the next instance in `--ports` that is up. `--add-at` brings the
second instance into that rotation late, which is what a balancer that spreads
*connections* does when an instance is added under load.

    PORT=8801 THREADS=4 taskset -c 0-3 ./zig-out/bin/nilo-bench-keepalive-server &
    taskset -c 4-7 python3 bench/keepalive.py --ports 8801 --pids $! \\
        --plan 'BIIIBIIIBIIIBIII' --secs 60 --windows 3
"""
import argparse, asyncio, os, random, re, sys, time

CLK = os.sysconf("SC_CLK_TCK")


def thread_cpu(pid, tid):
    try:
        with open(f"/proc/{pid}/task/{tid}/stat") as f:
            parts = f.read().rsplit(")", 1)[1].split()
        return (int(parts[11]) + int(parts[12])) / CLK
    except OSError:
        return 0.0


class Conn:
    def __init__(self, cls, idx):
        self.cls, self.idx = cls, idx
        self.tid = None
        self.port = None
        self.requests = 0
        self.reopened = 0


async def request(reader, writer, path):
    writer.write(f"GET {path} HTTP/1.1\r\nHost: x\r\n\r\n".encode())
    head = await reader.readuntil(b"\r\n\r\n")
    m = re.search(rb"[Cc]ontent-[Ll]ength: (\d+)", head)
    body = await reader.readexactly(int(m.group(1))) if m else b""
    return head, body


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ports", required=True, help="comma list of instance ports")
    ap.add_argument("--pids", required=True, help="comma list, one server pid per port")
    ap.add_argument("--plan", required=True)
    ap.add_argument("--secs", type=float, default=60)
    ap.add_argument("--windows", type=int, default=3)
    ap.add_argument("--work-us", type=int, default=400)
    ap.add_argument("--period", type=float, default=2, help="ms between busy requests")
    ap.add_argument("--idle-period", type=float, default=10)
    ap.add_argument("--short-life", type=float, default=0.5)
    ap.add_argument("--up", type=int, default=1, help="instances in rotation at the start")
    ap.add_argument("--add-at", type=float, default=0, help="seconds in at which the rest join the rotation")
    ap.add_argument("--seed", type=int, default=1)
    a = ap.parse_args()
    random.seed(a.seed)
    ports = [int(p) for p in a.ports.split(",")]
    pids = {p: int(x) for p, x in zip(ports, a.pids.split(","))}
    up = ports[: a.up]
    rr = [0]
    conns = []
    lat = []
    stop = asyncio.Event()

    def pick():
        p = up[rr[0] % len(up)]
        rr[0] += 1
        return p

    async def run(c, first):
        while not stop.is_set():
            c.port = pick()
            reader, writer = await asyncio.open_connection("127.0.0.1", c.port)
            opened = time.monotonic()
            try:
                while not stop.is_set():
                    path = f"/work/{a.work_us}" if c.cls == "B" else "/tid"
                    t_req = time.monotonic()
                    head, body = await request(reader, writer, path)
                    if c.cls == "B":
                        lat.append((time.monotonic() - t_req) * 1000)
                    c.tid = (c.port, int(body))
                    c.requests += 1
                    if first and not first.done():
                        first.set_result(None)
                    if b"onnection: close" in head:
                        break
                    if c.cls == "S":
                        await asyncio.sleep(a.short_life)
                        break
                    await asyncio.sleep(a.period / 1000 if c.cls == "B" else a.idle_period * random.uniform(0.8, 1.2))
            except (asyncio.IncompleteReadError, ConnectionError):
                pass
            finally:
                writer.close()
            c.reopened += 1
            if c.cls == "S":
                return

    tasks = []
    for i, cls in enumerate(a.plan):
        c = Conn(cls, i)
        first = asyncio.get_running_loop().create_future()
        conns.append(c)
        tasks.append(asyncio.create_task(run(c, first)))
        await first
    # short ones that finished are gone; B and I stay for the run
    t0 = time.monotonic()
    wlen = a.secs / a.windows
    tids = {}  # (port, tid) -> cpu at window start
    last = {}
    rows = []
    added = False

    def snapshot():
        # Every executor thread of every instance, not only the ones a connection
        # was seen on: an executor holding nothing is the finding.
        out = {}
        for port, pid in pids.items():
            for t in os.listdir(f"/proc/{pid}/task"):
                with open(f"/proc/{pid}/task/{t}/comm") as f:
                    if f.read().startswith("iou-"):
                        continue
                out[(port, int(t))] = thread_cpu(pid, int(t))
        return out

    last = snapshot()
    for w in range(a.windows):
        w_end = t0 + (w + 1) * wlen
        while time.monotonic() < w_end:
            await asyncio.sleep(0.2)
            if not added and a.add_at and time.monotonic() - t0 >= a.add_at:
                up[:] = ports
                added = True
        now = snapshot()
        per = {}
        for k in now:
            per[k] = (now[k] - last.get(k, 0.0)) / wlen * 100
        held = {}
        for c in conns:
            if c.tid and c.cls in "BI" and c.port is not None:
                b, i = held.get(c.tid, (0, 0))
                held[c.tid] = (b + (c.cls == "B"), i + (c.cls == "I"))
        ls = sorted(lat)
        lat.clear()
        rows.append((w, per, held, ls))
        last = now
    stop.set()
    for t in tasks:
        t.cancel()
    await asyncio.gather(*tasks, return_exceptions=True)

    for w, per, held, ls in rows:
        print(f"window {w + 1}/{a.windows} ({wlen:.0f}s)")
        for k in sorted(set(per) | set(held)):
            b, i = held.get(k, (0, 0))
            print(f"  port {k[0]} tid {k[1]}: cpu {per.get(k, 0):6.1f}%  busy {b:2d}  idle {i:2d}")
        if ls:
            print(f"  busy request latency: p50 {ls[len(ls) // 2]:.2f} ms  p99 {ls[int(len(ls) * 0.99)]:.2f} ms  ({len(ls)} requests)")
        by_port = {}
        for k, v in per.items():
            by_port.setdefault(k[0], []).append(v)
        for port, vs in sorted(by_port.items()):
            if sum(vs) > 0.5:
                print(f"  port {port}: total {sum(vs):6.1f}%  max/mean {max(vs) / (sum(vs) / len(vs)):.2f}")
    total_req = sum(c.requests for c in conns)
    cpu_s = sum(sum(per.values()) / 100 * wlen for _, per, _, _ in rows)
    print("reconnects:", sum(c.reopened for c in conns if c.cls in "BI"), " requests:", total_req,
          f" server cpu per request (whole run, warm-up requests included): {cpu_s / max(total_req, 1) * 1e6:.2f} us")

asyncio.run(main())
