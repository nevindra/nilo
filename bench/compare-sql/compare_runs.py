"""Two runs, compared honestly: one pass of the old against all of the new.

Written because a peer session caught the mirror image of the bug this harness
had just fixed. The first sweep here overlapped somebody else's multicore
build; passes 1 and 2 were inside their window and pass 3 was outside it. The
tempting comparison — re-run against the old *pooled* median — credits the
re-run with an improvement it did not earn, because two thirds of the "before"
was measured on a busy machine.

So the before is **pass 3 alone**: the only pass of the old run taken on a box
as quiet as the re-run's. That is a third of the data and the right third.

    python3 compare_runs.py results/ops-unix-run1-dirty.json results/ops-unix.json

What to look for. A wall-clock figure moving a few percent is this box. A figure
moving 10%+ means one of the two runs saw something the other did not, and the
report should not quote it to four digits. A *paired* difference changing sign
between runs means the harness cannot resolve it, whatever either run's
interval said — the same conclusion `stability.py` reaches from inside one run,
reached again from outside.
"""
import json
import os
import statistics as st
import sys

CONTROL = {"zig": "pgzig", "go": "pgx", "rust": "tokiopg", "node": "pg"}
BEFORE_PASS = int(os.environ.get("BEFORE_PASS", "3"))
PASSES = int(os.environ.get("PASSES", "3"))
LOUD = 0.10


def tail_pass(blocks):
    """The blocks of `BEFORE_PASS` alone, out of a pooled list."""
    n = len(blocks) // PASSES
    if n < 10:
        return blocks
    lo = (BEFORE_PASS - 1) * n
    return blocks[lo:lo + n]


def paired_median(mapper, control):
    n = min(len(mapper), len(control))
    if not n:
        return None
    return st.median(m - c for m, c in zip(mapper[:n], control[:n]))


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    with open(sys.argv[1]) as f:
        old = json.load(f)
    with open(sys.argv[2]) as f:
        new = json.load(f)

    print(f"# before: {os.path.basename(sys.argv[1])} pass {BEFORE_PASS} only")
    print(f"# after:  {os.path.basename(sys.argv[2])} all passes\n")

    loud, flipped = [], []

    for lang in old:
        if lang not in new:
            continue
        print(f"\n## {lang}")
        for shape, so in old[lang].get("shapes", {}).items():
            sn = new[lang].get("shapes", {}).get(shape)
            if not sn:
                continue
            octl = tail_pass(so["arms"][CONTROL[lang]]["blocks"]) \
                if CONTROL[lang] in so["arms"] else None
            nctl = sn["arms"].get(CONTROL[lang], {}).get("blocks")
            for arm, ao in so["arms"].items():
                an = sn["arms"].get(arm)
                if not an:
                    continue
                b = st.median(tail_pass(ao["blocks"]))
                a = st.median(an["blocks"])
                move = (a - b) / b if b else 0
                mark = "  <--" if abs(move) > LOUD else ""
                if mark:
                    loud.append((lang, shape, arm, b, a, move))

                # And the paired difference, for the arms that have a control.
                extra = ""
                if octl and nctl and arm != CONTROL[lang]:
                    db = paired_median(tail_pass(ao["blocks"]), octl)
                    da = paired_median(an["blocks"], nctl)
                    if db is not None and da is not None:
                        flip = (db > 0) != (da > 0)
                        extra = f"   paired {db:>+9,.0f} → {da:>+9,.0f}"
                        if flip:
                            extra += "  SIGN FLIP"
                            flipped.append((lang, shape, arm, db, da))

                print(f"   {shape:<10} {arm:<15} {b:>11,.0f} → {a:>11,.0f}"
                      f"  {move * 100:>+6.1f}%{extra}{mark}")

    print("\n" + "=" * 78)
    print(f"wall clock moved more than {LOUD * 100:.0f}%: {len(loud)}")
    for lang, shape, arm, b, a, move in sorted(loud, key=lambda r: -abs(r[5]))[:20]:
        print(f"   {move * 100:>+6.1f}%  {lang}/{shape}/{arm}"
              f"   {b:,.0f} → {a:,.0f}")

    print(f"\npaired differences that changed sign between runs: {len(flipped)}")
    for lang, shape, arm, db, da in flipped:
        print(f"   {lang}/{shape}/{arm}   {db:+,.0f} → {da:+,.0f}")
    if flipped:
        print("\n   Two independent runs disagreeing about the *direction* of a")
        print("   difference settles it: below resolution. Report it that way")
        print("   whatever either run's confidence interval says.")
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
