"""Turn `results/raw.json` into the tables `bench/result/s3.md` carries.

Separate from `drive.py` so the write-up can be regenerated without re-running
anything, and so the arithmetic in it is a program rather than a person with a
calculator. Every derived column here is derived in one place.

The column that is not in the raw output and matters most is **server CPU as a
percentage of the budget**. The server is pinned to three physical cores, so
600% is the ceiling, and a route near it is measuring the ceiling rather than
the candidate. Without this column the 1 MB rows look like a result.

    python3 bench/compare-s3/table.py
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

# Six hyperthreads on three physical cores, which is what `SERVER_CPUS`
# hands the server. A route drawing near this is CPU-bound at the budget.
CEILING = 600.0

ORDER = ["nilo", "go", "rust", "bun1", "bun6"]
ROUTES = ["/health", "/warm/1k", "/warm/1m", "/o/1k", "/o/64k", "/o/1m", "/presign"]


def load():
    with open(os.path.join(HERE, "results", "raw.json")) as f:
        return json.load(f)


def cpu_pct(row):
    """What this route drew, as a percentage of one core."""
    return row["rps"] * row["ns_per_req"] / 1e7


def saturated(row):
    return cpu_pct(row) > 0.85 * CEILING


def main():
    d = load()
    keys = [k for k in ORDER if k in d and "routes" in d[k]]
    if not keys:
        print("no completed candidates in results/raw.json", file=sys.stderr)
        return 1

    print("## Throughput, and how much of the core budget it took\n")
    print("| route | " + " | ".join(d[k]["label"] for k in keys) + " |")
    print("|---" * (len(keys) + 1) + "|")
    for path in ROUTES:
        cells = []
        for k in keys:
            r = d[k]["routes"][path]
            mark = " **⚠**" if saturated(r) else ""
            cells.append(f"{r['rps']:,.0f} req/s · {cpu_pct(r):.0f}% CPU{mark}")
        print(f"| `{path}` | " + " | ".join(cells) + " |")

    print("\n⚠ = drew more than 85% of the 600% budget, so **the req/s in that "
          "cell is bounded by the cores the server was given** rather than by "
          "the candidate. It does not invalidate the CPU-per-request column "
          "below: saturation caps throughput, not what one request costs, "
          "which is exactly why the subtraction is done in ns of CPU and not "
          "in req/s.\n")

    print("## CPU per request\n")
    print("| route | " + " | ".join(d[k]["label"] for k in keys) + " |")
    print("|---" * (len(keys) + 1) + "|")
    for path in ROUTES:
        cells = [f"{d[k]['routes'][path]['ns_per_req']:,.0f} ns" for k in keys]
        print(f"| `{path}` | " + " | ".join(cells) + " |")

    print("\n## What the object-store client costs — the subtraction\n")
    print("| pair | " + " | ".join(d[k]["label"] for k in keys) + " |")
    print("|---" * (len(keys) + 1) + "|")
    for store_path in ("/o/1k", "/o/1m"):
        cells, floor = [], None
        for k in keys:
            p = d[k].get("paired", {}).get(store_path)
            if not p:
                cells.append("—")
                continue
            floor = p["floor"]
            per_pass = ", ".join(f"{x:+,.0f}" for x in p["deltas"])
            note = "" if p["agree"] else " · **sign flips**"
            cells.append(f"{p['median']:+,.0f} ns [{per_pass}]{note}")
        # Two different problems, and lumping them loses the useful one.
        #
        # If the *store* side is saturated, the subtraction is void: both
        # halves are then bounded by the machine rather than by the client,
        # and at a megabyte they are bounded by different parts of it — the
        # floor thrashes memory bandwidth, where a stalled cycle still counts
        # as CPU, while the store route sits waiting on MinIO and stalls less
        # per byte. That is how a route doing strictly more work reports less
        # CPU per request, and no sign check catches it.
        #
        # If only the *floor* is saturated, the difference is still a cost —
        # but a floor measured under hyperthread contention the store route
        # never sees is an overstated subtrahend, so what comes out is a
        # **lower bound** on what the client costs.
        # The validity test that works, and it is not a threshold.
        #
        # **A client cannot cost negative CPU, and two candidates running the
        # same operation cannot disagree about the sign of its cost.** Either
        # of those means the subtraction is measuring the machine rather than
        # the client, whatever the CPU percentages happen to say. It catches
        # the 1 MB pair, which a saturation threshold does not: there the
        # binding resource is memory bandwidth, where a stalled cycle still
        # counts as CPU time, so a route doing strictly more work reports less
        # CPU per request than its own floor.
        #
        # This is the check the sign-agreement rule does not do. That rule asks
        # whether a difference is noise, by comparing a candidate's three
        # passes to each other. This asks whether it is a *cost*, by comparing
        # candidates to each other and to zero. The 1 MB pair passes the first
        # and fails the second.
        medians = [d[k]["paired"][store_path]["median"]
                   for k in keys if d[k].get("paired", {}).get(store_path)]
        void = any(m < 0 for m in medians) or \
            (len(medians) > 1 and not (all(m > 0 for m in medians) or
                                       all(m < 0 for m in medians)))
        floor_hot = floor and any(saturated(d[k]["routes"][floor]) for k in keys)
        if void:
            mark = ("  ⚠ **void — a client cannot cost negative CPU, so this "
                    "is the machine, not the candidates**")
        elif floor_hot:
            mark = "  † **a lower bound** — the floor is saturated, the store route is not"
        else:
            mark = ""
        print(f"| `{store_path}` − `{floor}` | " + " | ".join(cells) + f" |{mark}")

    print("\n## Memory per idle connection\n")
    print("| connections | " + " | ".join(d[k]["label"] for k in keys) + " |")
    print("|---" * (len(keys) + 1) + "|")
    steps = [r["n"] for r in d[keys[0]]["memory"]["rows"]]
    for i, n in enumerate(steps):
        cells = []
        for k in keys:
            rows = d[k]["memory"]["rows"]
            if i < len(rows):
                cells.append(f"{rows[i]['per_conn']:,.0f} B "
                             f"(marginal {rows[i]['marginal']:,.0f})")
            else:
                cells.append("—")
        print(f"| {n:,} | " + " | ".join(cells) + " |")

    print("\n## Errors\n")
    for k in keys:
        bad = []
        for path in ROUTES:
            r = d[k]["routes"][path]
            if r["non2xx"] or r["errors"]:
                bad.append(f"`{path}`: non2xx={r['non2xx']} {r['errors']}".strip())
        print(f"- **{d[k]['label']}** — " + ("; ".join(bad) if bad else "none"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
