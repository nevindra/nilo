"""Run every per-operation candidate, round-robin, and report what survives.

Each candidate is one program holding every mapper for its language plus that
language's raw driver, timed in interleaved blocks inside a single process.
Why it is built that way is in `zigsql/src/ops.zig`; the short version is that
this box drifts up to 8% over a few minutes and the quantity being reported is
under 1% of an operation, so the arms have to be measured against each other
rather than against the clock.

This driver adds the second half of that discipline: **passes round-robin
across candidates**, never all of one candidate's runs back to back. Four runs
of A followed by four of B blames the drift on whichever went second.

    python3 ops.py                # every candidate
    python3 ops.py zig go         # only these, merged into results/raw.json
    PASSES=5 python3 ops.py       # more passes; 3 is the default
"""
import json
import os
import re
import statistics as st
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
RESULTS = os.path.join(HERE, "results")

TCP = os.environ.get("DATABASE_URL", "postgres://nilo:nilo@localhost:5433/nilo")

# Which transport a number was measured through is part of the number
# (`bench/result/sql.md` §3 — the Docker bridge costs 133% against a unix
# socket). Every candidate is given the *same* transport, in whichever spelling
# its own driver accepts, because the spellings disagree and a candidate that
# silently fell back to TCP while the others used the socket would be the one
# result nobody could see was wrong.
TRANSPORT = os.environ.get("TRANSPORT", "tcp")
SOCK = os.environ.get("PGSOCKDIR", "/tmp/nilo-pgsock")
# Passes are the unit the sign check splits on, so this is not only a loop
# bound — a run of three passes reported as one is a pooled interval nobody
# can check (see `paired`).
PASSES = int(os.environ.get("PASSES", "3"))

# `control` names the raw-driver arm — the one every mapper in that language is
# subtracted from. It lives here rather than in each program because it is a
# fact about the comparison, not about the candidate.
CANDIDATES = [
    dict(key="zig", label="Zig", control="pgzig",
         cmd=[os.path.join(HERE, "zigsql", "zig-out", "bin", "zigsql-ops")],
         # pg.zig wants the full socket *path*, not libpq's directory, and the
         # slashes have to be percent-encoded or the URL parser drops them out
         # of the host field. Getting this wrong is `error.Unexpected`.
         unix=f"postgres://nilo:nilo@{SOCK.replace('/', '%2F')}"
              f"%2F.s.PGSQL.5432/nilo"),
    dict(key="go", label="Go", control="pgx",
         cmd=[os.path.join(HERE, "go", "go-ops")],
         unix=f"postgres://nilo:nilo@/nilo?host={SOCK}"),
    dict(key="rust", label="Rust", control="tokiopg",
         cmd=[os.path.join(HERE, "rust", "target", "release", "rust-ops")],
         # One string has to satisfy tokio-postgres, diesel-async and sqlx at
         # once; the percent-encoded directory is the form all three read.
         unix=f"postgres://nilo:nilo@{SOCK.replace('/', '%2F')}/nilo"),
    dict(key="node", label="Node", control="pg",
         cmd=["node", os.path.join(HERE, "node", "ops.mjs")],
         # `localhost` is a placeholder that `?host=` then overrides. It is not
         # decoration: Prisma refuses an empty host outright (P1013) while
         # node-postgres accepts one, so the form without it benchmarks two of
         # the three arms and fails the run on the third.
         unix=f"postgres://nilo:nilo@localhost/nilo?host={SOCK}"),
]


def dsn(cand):
    if TRANSPORT == "unix":
        url = cand.get("unix")
        if not url:
            raise RuntimeError(f"{cand['key']} has no unix DSN")
        return url
    return TCP

# Six that read, five that write. The read shapes vary rows and columns to
# separate a mapper costing per value from one costing per call; the write
# shapes vary how many statements a single logical operation turns into.
SHAPES = ["empty", "key", "page", "scan", "wide", "wide_scan",
          "insert", "batch", "update", "delete", "tx"]


# ------------------------------------------------------------------ running

def strays():
    """Any candidate process still alive that should not be.

    `subprocess.run` waits on the direct child and nothing else, so a candidate
    that leaves a grandchild behind keeps burning CPU under the *next*
    candidate's measurement. That is not hypothetical: in the first sweep here
    `zig/wide_scan/pgzig` read 372,805 / 375,522 / 411,318 ns across three
    passes, 10% slowest in the pass taken on the quietest box — the shape
    contamination does not make, and an orphan from the preceding Node run is
    one of the two candidates for it.

    Cheap enough to check every pass rather than theorise about, which is the
    whole point: a rule that runs beats a rule that is written down.
    """
    names = ["zigsql-ops", "go-ops", "rust-ops", "ops.mjs"]
    out = []
    for n in names:
        r = subprocess.run(["pgrep", "-af", n], capture_output=True, text=True)
        for line in r.stdout.splitlines():
            # pgrep matches this driver's own command line through `ops.py`
            # when the pattern is `ops.mjs`; skip anything that is us.
            if "ops.py" in line or "pgrep" in line:
                continue
            out.append(line.strip()[:90])
    return out


def run_once(cand):
    """One run of one candidate. Returns its parsed RESULT object."""
    left = strays()
    if left:
        print("\n    !! a previous candidate is still running — this "
              "measurement is not clean:", flush=True)
        for line in left:
            print(f"       {line}", flush=True)
    env = dict(os.environ)
    env["DATABASE_URL"] = dsn(cand)
    p = subprocess.run(cand["cmd"], capture_output=True, text=True, env=env)
    blob = None
    for line in (p.stdout + "\n" + p.stderr).splitlines():
        if line.startswith("RESULT "):
            blob = json.loads(line[len("RESULT "):])
    if blob is None:
        raise RuntimeError(
            f"no RESULT line (exit {p.returncode})\n"
            f"{(p.stderr or p.stdout)[-2000:]}"
        )
    return blob


def merge(into, new):
    """Pool a pass's blocks into what is already collected.

    Blocks pool across passes because the pairing is *within* a block: block i
    of the mapper and block i of the control ran adjacent to each other, so
    their difference is drift-free wherever in the session it was taken.
    """
    into.setdefault("language", new["language"])
    into["peak_rss_kb"] = max(into.get("peak_rss_kb", 0), new.get("peak_rss_kb", 0))
    for shape, s in new["shapes"].items():
        dst = into.setdefault("shapes", {}).setdefault(
            shape,
            dict(rows=s["rows"], columns=s.get("columns", 4),
                 rounds=s["rounds"], arms={}),
        )
        for arm, a in s["arms"].items():
            d = dst["arms"].setdefault(arm, dict(checksum=a["checksum"], blocks=[]))
            if d["checksum"] != a["checksum"]:
                raise RuntimeError(
                    f"{new['language']}/{shape}/{arm}: checksum moved between "
                    f"passes ({d['checksum']} then {a['checksum']}) — the "
                    f"fixture changed under the run"
                )
            d["blocks"].extend(a["blocks"])
    return into


# -------------------------------------------------------------- statistics

def paired(mapper, control):
    """Median of the per-block differences, a CI, and a per-pass sign check.

    The median of differences, never the difference of medians. The second
    quietly assumes both arms saw the same conditions; the first is the whole
    reason the blocks are interleaved.

    The interval on its own turned out not to be enough, and it took a run to
    find out. Pooling every pass's blocks narrows the interval on the
    assumption that they are exchangeable, and they are not: each pass is a
    separate session with its own thermal state. Split back per pass, every
    difference nilo_sql showed against pg.zig changed sign — `key` read +212,
    +178, −147 ns — while each pooled interval excluded zero and would have
    been published as real. GORM, Drizzle, Prisma and diesel-async held their
    sign in all three with swings under 7%, so what the split separates is not
    a reliable box from an unreliable one but a difference the harness can
    resolve from one it cannot.

    So `agree` is reported next to the interval, and `report` calls a
    difference real only when both hold (`stability.py` is the standalone
    version of this check).
    """
    n = min(len(mapper), len(control))
    diffs = [m - c for m, c in zip(mapper[:n], control[:n])]
    d = sorted(diffs)
    if not d:
        return None
    k = int(1.96 * (n ** 0.5) / 2)
    lo = d[max(0, n // 2 - k)]
    hi = d[min(n - 1, n // 2 + k)]

    per = n // PASSES
    if per >= 10:
        pass_med = [st.median(diffs[p * per:(p + 1) * per])
                    for p in range(PASSES)]
        agree = len({m > 0 for m in pass_med}) == 1
    else:
        # Too few blocks to split. Fall back to the interval rather than
        # calling everything unstable.
        pass_med, agree = [], True

    return dict(median=st.median(d), lo=lo, hi=hi, n=n,
                passes=pass_med, agree=agree,
                iqr=(st.quantiles(d, n=4)[0], st.quantiles(d, n=4)[2])
                if n >= 4 else (d[0], d[-1]))


def ns(x):
    return f"{x:,.0f}"


# ------------------------------------------------------------------ report

def report(results):
    print("\n" + "=" * 78)
    print("PER-OPERATION — one connection, no pool, no HTTP")
    print("=" * 78)

    # The payload rule. Every candidate that read a shape must have arrived at
    # the same number, or one of them is not decoding what the others decode.
    print("\nChecksums (every arm of every language must agree per shape)")
    ok = True
    for shape in SHAPES:
        seen = {}
        for key, r in results.items():
            s = r.get("shapes", {}).get(shape)
            if not s:
                continue
            for arm, a in s["arms"].items():
                seen.setdefault(a["checksum"], []).append(f"{key}/{arm}")
        if shape == "empty":
            continue
        if len(seen) == 1:
            print(f"  {shape:<5} agreed: {list(seen)[0]:,}")
        else:
            ok = False
            print(f"  {shape:<5} DISAGREE — a candidate is not decoding:")
            for v, who in seen.items():
                print(f"          {v:>18,}  {', '.join(who)}")
    if not ok:
        print("\n  !! Numbers below are not comparable until that is fixed.")

    for shape in SHAPES:
        header = None
        for r in results.values():
            s = r.get("shapes", {}).get(shape)
            if s:
                header = f"{s['rows']} rows x {s.get('columns', 4)} cols"
                break
        if header is None:
            continue
        print(f"\n--- {shape}  ({header}) " + "-" * max(0, 48 - len(header)))
        for key, r in results.items():
            s = r.get("shapes", {}).get(shape)
            if not s:
                continue
            rows, cols = s["rows"], s.get("columns", 4)
            values = rows * cols
            control = next(c["control"] for c in CANDIDATES if c["key"] == key)
            ctl = s["arms"].get(control)
            if not ctl:
                continue
            print(f"  {key:<5} {control:<10} {ns(st.median(ctl['blocks'])):>11} ns"
                  f"   ({len(ctl['blocks'])} blocks)")
            for arm, a in s["arms"].items():
                if arm == control:
                    continue
                p = paired(a["blocks"], ctl["blocks"])
                mid = ns(st.median(a["blocks"]))
                if p["lo"] <= 0 <= p["hi"]:
                    verdict = "indistinguishable"
                elif not p["agree"]:
                    # The interval excluded zero and the passes disagreed about
                    # the sign. Trust the passes: this is below resolution.
                    verdict = "below resolution"
                else:
                    verdict = "real"
                # Per *value*, not per row. A mapper that costs per column and
                # one that costs per row look the same on a four-column table
                # and nothing alike on a twenty-column one, which is the whole
                # reason the wide shapes exist.
                per = f"{p['median']/values:+.2f} ns/value" if values else "—"
                print(f"        {arm:<10} {mid:>11} ns"
                      f"   {p['median']:+,.0f} ns [{p['lo']:+,.0f}, {p['hi']:+,.0f}]"
                      f"   {per:>18}   {verdict}")

    print("\n--- peak RSS of the benchmark process " + "-" * 39)
    for key, r in results.items():
        print(f"  {key:<5} {r.get('peak_rss_kb', 0):>10,} kB")
    print()


# -------------------------------------------------------------------- main

def load():
    try:
        with open(os.path.join(RESULTS, f"ops-{TRANSPORT}.json")) as f:
            return json.load(f)
    except (FileNotFoundError, ValueError):
        return {}


def save(results):
    os.makedirs(RESULTS, exist_ok=True)
    with open(os.path.join(RESULTS, f"ops-{TRANSPORT}.json"), "w") as f:
        json.dump(results, f, indent=1)


def main():
    only = [a for a in sys.argv[1:] if not a.startswith("-")]
    chosen = [c for c in CANDIDATES if not only or c["key"] in only]
    if not chosen:
        print("no candidate matched", file=sys.stderr)
        return 1

    results = load() if only else {}
    if results:
        kept = [k for k in results if k not in only]
        if kept:
            print("keeping recorded results for: " + ", ".join(kept), flush=True)

    fresh = {}
    alive = list(chosen)
    for p in range(PASSES):
        print(f"\n===== pass {p + 1} of {PASSES} =====", flush=True)
        for cand in list(alive):
            print(f"  {cand['label']}…", end="", flush=True)
            try:
                blob = run_once(cand)
            except Exception as e:  # one candidate failing must not lose the rest
                print(f" FAILED: {e}", flush=True)
                alive.remove(cand)
                continue
            merge(fresh.setdefault(cand["key"], {}), blob)
            print(" ok", flush=True)
            results[cand["key"]] = fresh[cand["key"]]
            save(results)

    save(results)
    report(results)
    print(f"wrote {os.path.join(RESULTS, f'ops-{TRANSPORT}.json')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
