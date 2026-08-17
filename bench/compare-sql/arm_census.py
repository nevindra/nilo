"""Socket calls per operation, one arm at a time — Zig only.

`census.py` traces a whole candidate process and so cannot tell `nilo_sql` and
raw pg.zig apart: they interleave inside it by design. This runs one arm alone
through `OPS_ARMS` and counts what each puts on the socket.

It exists for one question and answered it in the negative, which is why it is
kept. `insert` costs `nilo_sql` +2,966 ns over raw pg.zig and `delete`
+1,673 ns — the only two shapes of eleven where the difference survives every
check — while `update`, doing nearly the same work, is not measurable. Both
figures land within a whisker of one unix-socket round trip (~2.6 µs), so an
extra packet was the obvious cause.

The counts came back identical to two decimal places in both arms: 4.04 socket
calls an insert, 4.00 an update, 4.12 a delete, `readv` and `sendmsg` splitting
evenly. **Same packets, so the cost is CPU inside the process** and the next
probe is a profile. A coherent theory that matched the magnitude, killed by one
run — see `bench/result/sql.md` §8.

    python3 arm_census.py                  # the three write shapes plus a read
    python3 arm_census.py insert batch      # or these

Counts, not times. Under `strace` every duration is meaningless, which is fine:
the question is how many packets an arm sends, not how fast it sends them.
"""
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
BIN = os.path.join(HERE, "zigsql", "zig-out", "bin", "zigsql-ops")
SOCK = os.environ.get("PGSOCKDIR", "/tmp/nilo-pgsock")
URL = os.environ.get(
    "DATABASE_URL",
    f"postgres://nilo:nilo@{SOCK.replace('/', '%2F')}%2F.s.PGSQL.5432/nilo",
)

LOW, HIGH = 1, 3
ARMS = ["raw", "nilo"]

# Rounds a block, per shape — the divisor has to match `Shape.rounds()` in
# `zigsql/src/ops.zig` or the per-operation figure is silently wrong by a
# factor. The first version of this script used one divisor for every shape and
# reported `key` at 16 socket calls an operation, which is 4.00 read through the
# wrong denominator.
ROUNDS = {
    "empty": 200, "key": 200, "page": 100, "scan": 20,
    "wide": 200, "wide_scan": 10,
    "insert": 50, "batch": 10, "update": 50, "delete": 50, "tx": 50,
}

DEFAULT = ["insert", "update", "delete", "key"]

SOCKET_CALLS = {"sendmsg", "readv", "write", "read", "sendto", "recvfrom",
                "writev", "recvmsg", "send", "recv"}


def counts(shape, arm, blocks):
    env = dict(os.environ)
    env.update(DATABASE_URL=URL, OPS_SHAPES=shape, OPS_ARMS=arm,
               OPS_WARMUP="0", OPS_BLOCKS=str(blocks))
    with tempfile.NamedTemporaryFile("r", suffix=".strace") as out:
        subprocess.run(["strace", "-c", "-f", "-o", out.name, BIN],
                       env=env, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL)
        text = out.read()
    got = {}
    for line in text.splitlines():
        m = re.match(
            r"\s*[\d.]+\s+[\d.]+\s+\d+\s+(\d+)(?:\s+(\d+))?\s+(\w+)\s*$", line)
        # `total` is strace's own summary row; counting it doubles everything.
        if m and m.group(3) != "total":
            got[m.group(3)] = got.get(m.group(3), 0) + int(m.group(1))
    return got


def main():
    shapes = [s for s in sys.argv[1:] if s in ROUNDS] or DEFAULT
    if not os.path.exists(BIN):
        print(f"build it first: cd zigsql && zig build -Doptimize=ReleaseFast")
        return 1

    rows = {}
    for shape in shapes:
        ops = (HIGH - LOW) * ROUNDS[shape]
        print(f"## {shape}   ({ops} marginal operations)")
        for arm in ARMS:
            lo, hi = counts(shape, arm, LOW), counts(shape, arm, HIGH)
            if not lo or not hi:
                print(f"   {arm:<5} no strace summary — is strace on PATH?")
                continue
            delta = {k: hi.get(k, 0) - lo.get(k, 0) for k in set(lo) | set(hi)}
            delta = {k: v for k, v in delta.items() if v > 0}
            sock = sum(v for k, v in delta.items() if k in SOCKET_CALLS)
            rows[(shape, arm)] = sock / ops
            # Every syscall that moved, not a curated subset — `census.py` hid
            # four a query behind the word "other" on its first run.
            detail = "  ".join(
                f"{k} {v / ops:.2f}" for k, v in
                sorted(delta.items(), key=lambda kv: -kv[1])[:6])
            print(f"   {arm:<5} socket {sock / ops:>5.2f}/op"
                  f"   all {sum(delta.values()) / ops:>5.2f}/op   {detail}")
        print()

    print("=" * 70)
    print("socket calls an operation, nilo_sql minus raw pg.zig\n")
    for shape in shapes:
        a, b = rows.get((shape, "raw")), rows.get((shape, "nilo"))
        if a is not None and b is not None:
            print(f"   {shape:<10} raw {a:>5.2f}   nilo {b:>5.2f}"
                  f"   diff {b - a:>+5.2f}")
    print("\nA round trip is one send and one receive, so +2.00 an operation is")
    print("one extra round trip. Anything smaller is a different cause, and")
    print("+0.00 means the difference in `ops.py` is not on the wire at all.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
