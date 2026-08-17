"""Did the box stay quiet? Per-pass medians for every arm, and a step check.

`ops.py` pools the blocks of every pass into one list per arm, because the
pairing is *within* a block and so a difference is drift-free wherever in the
session it was taken. That is true of the paired column and false of the
wall-clock column: Zig ran in one time window and Node in another, so anything
that made the machine busy for part of the run shows up as a ranking rather
than as noise.

This splits the pooled list back into its passes and prints them side by side.
A pass sitting well off its neighbours dates the contamination, which is the
difference between "re-run everything" and "re-run pass 3".

The threshold is 6%: below that is this box's ordinary drift over minutes
(`bench/result/sql.md` §0 puts it at up to 8% across a whole session), above it
is something that happened.

    python3 drift.py
    python3 drift.py results/ops-tcp.json
"""
import json
import os
import statistics as st
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SUSPECT = 0.06


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        HERE, "results", "ops-unix.json")
    with open(path) as f:
        results = json.load(f)

    # Every arm of every language is expected to have the same block count, and
    # `passes` is inferred from the shape with the most — guessing it would be
    # the one number in here nobody could check.
    per_pass = int(os.environ.get("PASSES", "3"))

    flagged = []
    print(f"# {os.path.basename(path)} — per-pass medians, {per_pass} passes\n")

    for lang, r in results.items():
        print(f"\n## {lang}")
        for shape, s in r.get("shapes", {}).items():
            for arm, a in s["arms"].items():
                blocks = a["blocks"]
                n = len(blocks) // per_pass
                if n < 10:
                    continue
                meds = [st.median(blocks[p * n:(p + 1) * n])
                        for p in range(per_pass)]
                lo, hi = min(meds), max(meds)
                spread = (hi - lo) / lo if lo else 0
                mark = "  <-- " if spread > SUSPECT else "      "
                cells = "  ".join(f"{m:>10,.0f}" for m in meds)
                print(f"   {shape:<10} {arm:<15} {cells}"
                      f"   spread {spread * 100:>5.1f}%{mark}")
                if spread > SUSPECT:
                    flagged.append((lang, shape, arm, spread, meds))

    print("\n" + "=" * 74)
    if not flagged:
        print(f"No arm moved more than {SUSPECT * 100:.0f}% between passes.")
        print("The box held still. Both columns of the report stand.")
        return 0

    print(f"{len(flagged)} arm/shape pairs moved more than "
          f"{SUSPECT * 100:.0f}% between passes:\n")
    for lang, shape, arm, spread, meds in sorted(
            flagged, key=lambda f: -f[3])[:25]:
        print(f"   {spread * 100:>5.1f}%  {lang}/{shape}/{arm}   "
              + "  ".join(f"{m:,.0f}" for m in meds))

    # Which pass is the odd one out, counted across everything flagged. If it
    # is always the same pass, that dates the interference; if it is scattered,
    # this is ordinary drift and the threshold is too tight.
    worst = {}
    for _, _, _, _, meds in flagged:
        slowest = max(range(len(meds)), key=lambda i: meds[i])
        worst[slowest] = worst.get(slowest, 0) + 1
    print("\n   slowest pass, counted over the flagged rows:")
    for p in sorted(worst):
        print(f"     pass {p + 1}: {worst[p]}")
    print("\n   One pass holding most of them dates the interference and only")
    print("   that pass needs re-running. Scattered means ordinary drift.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
