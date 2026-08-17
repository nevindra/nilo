"""Emit the measurement as one JSON blob, for the report page to render.

The page draws bars from data rather than from hand-typed numbers, so a rerun
is a regenerated blob and not eleven tables edited by hand. Getting that wrong
is how `connect_on_init` ended up documented in three files and working in
none (ADR 0062).

    python3 artifact_data.py > /tmp/ops.json
    python3 artifact_data.py results/ops-tcp.json
"""
import json
import os
import statistics as st
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

CONTROL = {"zig": "pgzig", "go": "pgx", "rust": "tokiopg", "node": "pg"}
ON_CONTROL = {"nilo_sql", "gorm", "diesel", "drizzle"}

LABEL = {
    "pgzig": "pg.zig", "nilo_sql": "nilo_sql",
    "pgx": "pgx", "gorm": "GORM",
    "tokiopg": "tokio-postgres", "diesel": "diesel-async", "sqlx": "SQLx",
    "pg": "node-postgres", "drizzle": "Drizzle", "prisma": "Prisma",
}

LANG = {"zig": "Zig", "go": "Go", "rust": "Rust", "node": "Node"}

SHAPES = ["empty", "key", "page", "scan", "wide", "wide_scan",
          "insert", "batch", "update", "delete", "tx"]


PASSES = int(os.environ.get("PASSES", "3"))


def paired(mapper, control):
    """Median of the per-block differences, a CI, and a per-pass sign check.

    The CI alone was not enough, and finding that out cost a rewrite. Pooling
    900 blocks narrows the interval on the assumption that the blocks are
    exchangeable — and they are not, because each pass is a separate session
    with its own thermal state. Every one of nilo_sql's differences had a
    pooled interval excluding zero and a sign that did not survive being split
    back into its three passes: `key` read +212, +178, −147.

    So `real` now needs both. The interval has to exclude zero *and* the three
    passes have to agree about which arm was faster. A difference smaller than
    the resolution of the thing measuring it is not a result, whatever its
    interval says (`bench/result/sql.md` §0).
    """
    n = min(len(mapper), len(control))
    diffs = [m - c for m, c in zip(mapper[:n], control[:n])]
    d = sorted(diffs)
    if not d:
        return None
    k = int(1.96 * (n ** 0.5) / 2)
    out = dict(median=st.median(d), lo=d[max(0, n // 2 - k)],
               hi=d[min(n - 1, n // 2 + k)], n=n)

    per = n // PASSES
    if per >= 10:
        pass_med = [st.median(diffs[p * per:(p + 1) * per])
                    for p in range(PASSES)]
        out["passes"] = pass_med
        out["agree"] = len({m > 0 for m in pass_med}) == 1
    else:
        out["passes"] = []
        # Too few blocks to split; fall back to the interval alone rather than
        # silently calling everything unstable.
        out["agree"] = True
    return out


def other_signs(path):
    """arm-key -> the per-pass signs of an earlier, independent run.

    Per pass and not the earlier run's pooled median, which was the first
    attempt and let one through. Pooling run 1 gave `key`/nilo_sql +212 ns —
    positive, agreeing with run 2's +370 — while run 1's own three passes were
    +212, +178, **−147**. The pooled figure hid the disagreement it was
    supposed to expose.

    So the rule is unanimity across all six pass-measurements, three from each
    run. A difference the harness can resolve puts the same arm in front every
    time it is asked; one that changes its mind once in six is not a finding,
    whatever the interval around the pooled number says.
    """
    try:
        with open(path) as f:
            prev = json.load(f)
    except (FileNotFoundError, ValueError):
        return {}
    signs = {}
    for lang, r in prev.items():
        for shape, s in r.get("shapes", {}).items():
            ctl = s["arms"].get(CONTROL[lang])
            if not ctl:
                continue
            for arm, a in s["arms"].items():
                if arm == CONTROL[lang]:
                    continue
                p = paired(a["blocks"], ctl["blocks"])
                if p and p["passes"]:
                    signs[(lang, shape, arm)] = [m > 0 for m in p["passes"]]
    return signs


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        HERE, "results", "ops-unix.json")
    prev_path = sys.argv[2] if len(sys.argv) > 2 else os.path.join(
        HERE, "results", "ops-unix-run1-dirty.json")
    with open(path) as f:
        results = json.load(f)
    prev = other_signs(prev_path)

    out = {"shapes": {}, "rss": {}, "blocks": 0}

    for key, r in results.items():
        out["rss"][LANG[key]] = r.get("peak_rss_kb", 0)

    for shape in SHAPES:
        present = [(k, r) for k, r in results.items()
                   if shape in r.get("shapes", {})]
        if not present:
            continue
        meta = present[0][1]["shapes"][shape]
        rows, cols = meta["rows"], meta.get("columns", 4)
        entry = {"rows": rows, "columns": cols, "arms": []}

        for key, r in present:
            arms = r["shapes"][shape]["arms"]
            ctl = arms.get(CONTROL[key])
            out["blocks"] = max(out["blocks"], len(ctl["blocks"]) if ctl else 0)
            for arm, a in arms.items():
                rec = {
                    "id": arm,
                    "label": LABEL[arm],
                    "lang": LANG[key],
                    "ns": st.median(a["blocks"]),
                    "raw": arm == CONTROL[key],
                    "onControl": arm in ON_CONTROL,
                }
                if ctl and arm != CONTROL[key]:
                    p = paired(a["blocks"], ctl["blocks"])
                    if p:
                        rec["delta"] = p["median"]
                        rec["lo"] = p["lo"]
                        rec["hi"] = p["hi"]
                        rec["passes"] = [round(m) for m in p["passes"]]
                        rec["agree"] = p["agree"]
                        rec["control"] = LABEL[CONTROL[key]]
                        # Three tests now: the interval, the passes inside this
                        # run, and the sign of the previous run. See `paired`
                        # and `other_signs`.
                        was = prev.get((key, shape, arm)) or []
                        here = [m > 0 for m in p["passes"]]
                        rec["crossRun"] = len(set(was + here)) <= 1
                        rec["priorPasses"] = len(was)
                        rec["real"] = ((not (p["lo"] <= 0 <= p["hi"]))
                                       and p["agree"] and rec["crossRun"])
                entry["arms"].append(rec)

        entry["arms"].sort(key=lambda a: a["ns"])
        out["shapes"][shape] = entry

    # One line, so refreshing the page after a rerun is a single replacement
    # rather than an edit through eleven tables.
    json.dump(out, sys.stdout, separators=(",", ":"))
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
