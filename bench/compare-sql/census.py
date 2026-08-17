"""How many syscalls each driver spends on one prepared round trip.

`ops.py` says pg.zig is the slowest driver here per round trip and the fastest
per row decoded. That is a symptom. This is the diagnosis: a bare `SELECT 1`
has nothing to plan, nothing to decode and one row of one column, so whatever
separates the drivers on that shape is the protocol and the socket — and both
are countable.

The method is a subtraction, because a process does not only make syscalls for
queries. Each candidate is run twice under `strace -c -f`, once with one block
and once with three, warm-up off, `empty` only. Connecting, authenticating,
preparing and tearing down happen exactly once in both, so they cancel; what is
left is the marginal cost of 400 queries.

    python3 census.py            # every candidate
    python3 census.py zig go     # or just these

Counts, not times. strace multiplies wall-clock by a large factor and none of
the timings under it mean anything — which is fine, because the question here
is how many packets a driver puts on the wire, not how fast it does it.
"""
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SOCK = os.environ.get("PGSOCKDIR", "/tmp/nilo-pgsock")

ROUNDS_PER_BLOCK = 200
LOW, HIGH = 1, 3
QUERIES = (HIGH - LOW) * ROUNDS_PER_BLOCK

CANDIDATES = [
    dict(key="zig", label="pg.zig",
         cmd=[os.path.join(HERE, "zigsql", "zig-out", "bin", "zigsql-ops")],
         url=f"postgres://nilo:nilo@{SOCK.replace('/', '%2F')}%2F.s.PGSQL.5432/nilo"),
    dict(key="go", label="pgx",
         cmd=[os.path.join(HERE, "go", "go-ops")],
         url=f"postgres://nilo:nilo@/nilo?host={SOCK}"),
    dict(key="rust", label="tokio-postgres",
         cmd=[os.path.join(HERE, "rust", "target", "release", "rust-ops")],
         url=f"postgres://nilo:nilo@{SOCK.replace('/', '%2F')}/nilo"),
    dict(key="node", label="node-postgres",
         cmd=["node", os.path.join(HERE, "node", "ops.mjs")],
         url=f"postgres://nilo:nilo@localhost/nilo?host={SOCK}"),
]

# The ones that can plausibly be per-query. Everything else is summed into
# "other" rather than dropped, so a driver spending its time somewhere this
# list did not anticipate still shows up.
INTERESTING = [
    "write", "writev", "send", "sendto", "sendmsg", "sendmmsg",
    "read", "readv", "recv", "recvfrom", "recvmsg", "recvmmsg",
    "epoll_wait", "epoll_pwait", "epoll_ctl", "ppoll", "poll",
    "futex", "nanosleep", "clock_nanosleep", "sched_yield",
    "io_uring_enter", "membarrier",
]


def counts(cand, blocks):
    """syscall -> count, for one run of one candidate."""
    env = dict(os.environ)
    env.update(DATABASE_URL=cand["url"], OPS_SHAPES="empty",
               OPS_WARMUP="0", OPS_BLOCKS=str(blocks))
    with tempfile.NamedTemporaryFile("r", suffix=".strace") as out:
        subprocess.run(
            ["strace", "-c", "-f", "-o", out.name] + cand["cmd"],
            env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        text = out.read()
    got = {}
    for line in text.splitlines():
        # "  0.00    0.000000           0       400           write"
        m = re.match(r"\s*[\d.]+\s+[\d.]+\s+\d+\s+(\d+)(?:\s+(\d+))?\s+(\w+)\s*$", line)
        # `total` is strace's own summary row. Counting it as a syscall doubled
        # every figure this script printed on its first run.
        if m and m.group(3) != "total":
            got[m.group(3)] = got.get(m.group(3), 0) + int(m.group(1))
    return got


def main():
    only = sys.argv[1:]
    rows = []
    for cand in CANDIDATES:
        if only and cand["key"] not in only:
            continue
        print(f"  tracing {cand['label']}…", flush=True)
        try:
            lo = counts(cand, LOW)
            hi = counts(cand, HIGH)
        except Exception as e:
            print(f"    FAILED: {e}", flush=True)
            continue
        if not lo or not hi:
            print("    no strace summary — is strace on PATH?", flush=True)
            continue
        delta = {k: hi.get(k, 0) - lo.get(k, 0) for k in set(lo) | set(hi)}
        delta = {k: v for k, v in delta.items() if v > 0}
        rows.append((cand, delta))

    print("\n" + "=" * 78)
    print(f"SYSCALLS PER PREPARED ROUND TRIP  (marginal over {QUERIES} queries)")
    print("=" * 78)
    print("\nA bare SELECT 1: nothing to plan, one row, one column. Whatever")
    print("separates these is protocol framing and socket handling.\n")

    for cand, delta in rows:
        total = sum(delta.values())
        print(f"  {cand['label']:<16} {total / QUERIES:>6.2f} syscalls/query"
              f"   ({total:,} over {QUERIES})")
        # Every syscall that moved, not a curated subset. The first version of
        # this script bucketed anything off a hand-written list into "other"
        # and hid four syscalls a query behind that word — which was most of
        # what the census existed to find.
        for k, v in sorted(delta.items(), key=lambda kv: -kv[1]):
            mark = " " if k in INTERESTING else "*"
            print(f"      {mark} {k:<18} {v / QUERIES:>6.2f}/query   ({v:,})")
        print()

    if len(rows) > 1:
        best = min(rows, key=lambda r: sum(r[1].values()))
        print(f"Fewest: {best[0]['label']} at "
              f"{sum(best[1].values()) / QUERIES:.2f} syscalls a query.")
        print("A driver doing more of them on a socket this fast is paying for")
        print("each one twice — once in the syscall and once in the wakeup.\n")


if __name__ == "__main__":
    main()
