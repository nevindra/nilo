"""Does the paired difference hold up pass to pass? The decisive check.

`drift.py` asks whether the box stayed still and answers in absolutes, which is
the wrong currency for most of this report. The wall-clock column is measured
against the clock and a busy machine moves it; the paired column is measured
against an arm that ran adjacent to it, and the whole reason the blocks
interleave is that a busy machine should move *both halves of a pair together*
and cancel.

That is a claim, and this is the test of it. The paired difference is computed
independently per pass and the three are printed side by side. If interleaving
works, they agree even where the absolutes moved 17%; if they disagree, the
design does not do what its header says and the report has to say so.

A pass-to-pass swing under 25% of the difference itself is agreement here —
these are differences of noisy quantities, so their own spread is wider than
the spread of what they are made from. What matters is that the **sign and the
order of magnitude** hold: a mapper that costs +3 µs in one pass and +3.4 µs in
another is one finding, and one that costs +3 µs then −1 µs is not a finding at
all.

    python3 stability.py
    python3 stability.py results/ops-tcp.json
"""
import json
import os
import statistics as st
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

CONTROL = {"zig": "pgzig", "go": "pgx", "rust": "tokiopg", "node": "pg"}


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        HERE, "results", "ops-unix.json")
    with open(path) as f:
        results = json.load(f)
    per_pass = int(os.environ.get("PASSES", "3"))

    print(f"# {os.path.basename(path)} — paired difference, per pass\n")
    print("   Each cell is the median of per-block differences inside that")
    print("   pass alone. Sign flips are what invalidate a finding.\n")

    flips, wide = [], []

    for lang, r in results.items():
        print(f"\n## {lang}   (control: {CONTROL[lang]})")
        for shape, s in r.get("shapes", {}).items():
            ctl = s["arms"].get(CONTROL[lang])
            if not ctl:
                continue
            for arm, a in s["arms"].items():
                if arm == CONTROL[lang]:
                    continue
                n = min(len(a["blocks"]), len(ctl["blocks"])) // per_pass
                if n < 10:
                    continue
                deltas = []
                for p in range(per_pass):
                    lo, hi = p * n, (p + 1) * n
                    deltas.append(st.median(
                        m - c for m, c in zip(a["blocks"][lo:hi],
                                              ctl["blocks"][lo:hi])))
                signs = {d > 0 for d in deltas}
                flip = len(signs) > 1
                scale = max(abs(d) for d in deltas) or 1
                swing = (max(deltas) - min(deltas)) / scale
                mark = ""
                if flip:
                    mark = "  <-- SIGN FLIP"
                    flips.append((lang, shape, arm, deltas))
                elif swing > 0.25:
                    mark = "  <-- wide"
                    wide.append((lang, shape, arm, deltas, swing))
                cells = "  ".join(f"{d:>+10,.0f}" for d in deltas)
                print(f"   {shape:<10} {arm:<12} {cells}"
                      f"   swing {swing * 100:>5.1f}%{mark}")

    print("\n" + "=" * 74)
    print(f"sign flips: {len(flips)}     wide but consistent: {len(wide)}\n")
    if flips:
        print("A sign flip means the pairing did not settle that arm. Report it")
        print("as indistinguishable regardless of what the pooled CI says:\n")
        for lang, shape, arm, deltas in flips:
            print(f"   {lang}/{shape}/{arm}   "
                  + "  ".join(f"{d:+,.0f}" for d in deltas))
    else:
        print("No arm changed sign between passes. Every difference the report")
        print("calls real kept its direction in all three passes, which is what")
        print("the interleaving was built to buy.")
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
