"""Turn a finished `ops.py` run into the two tables a reader actually wants.

`ops.py` prints the measurement: per language, per shape, every arm's median and
its paired difference from that language's own raw driver. That is the right
output for deciding whether a difference is real, and the wrong one for the
question people ask first, which is "so who is fastest".

Two tables, because there are two questions and conflating them is how a
benchmark misleads:

  **The tax** — a mapper minus the raw driver it is built on. Only meaningful
  where the mapper *is* built on the control (nilo_sql/pg.zig, GORM/pgx,
  diesel-async/tokio-postgres, Drizzle/node-postgres). SQLx and Prisma bring
  their own driver, so their distance from the control is a driver difference
  as well, and it is marked rather than reported as a tax.

  **The wall clock** — every arm of every language on one shape, ranked. This
  is what a service actually experiences, and it answers a different question
  from the first: a mapper can have the smallest tax in the field and still be
  slow because the driver underneath it is.

    python3 summarise.py                 # results/ops-unix.json
    python3 summarise.py results/ops-tcp.json
"""
import json
import os
import statistics as st
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

SHAPES = [
    ("empty", "SELECT 1 — the round trip with nothing in it"),
    ("key", "one row by primary key"),
    ("page", "twenty rows, filtered and sorted"),
    ("scan", "a thousand rows"),
    ("wide", "one row of twenty columns"),
    ("wide_scan", "a thousand rows of twenty columns"),
    ("insert", "one row stored, read back"),
    ("batch", "a hundred rows in one statement"),
    ("update", "one row changed by key, read back"),
    ("delete", "one row removed by key, read back"),
    ("tx", "BEGIN, a read, a write, COMMIT"),
]

CONTROL = {"zig": "pgzig", "go": "pgx", "rust": "tokiopg", "node": "pg"}

# Which arms sit on the control's own driver. The rest are marked in the tax
# table rather than dropped from it, because "this number is not a tax" is
# itself worth saying once per row.
ON_CONTROL = {"nilo_sql", "gorm", "diesel", "drizzle"}

LABEL = {
    "pgzig": "pg.zig", "nilo_sql": "nilo_sql",
    "pgx": "pgx", "gorm": "GORM",
    "tokiopg": "tokio-postgres", "diesel": "diesel-async", "sqlx": "SQLx",
    "pg": "node-postgres", "drizzle": "Drizzle", "prisma": "Prisma",
}


def paired(mapper, control):
    """Median of the per-block differences, with a distribution-free CI."""
    n = min(len(mapper), len(control))
    d = sorted(m - c for m, c in zip(mapper[:n], control[:n]))
    if not d:
        return None
    k = int(1.96 * (n ** 0.5) / 2)
    return dict(median=st.median(d), lo=d[max(0, n // 2 - k)],
                hi=d[min(n - 1, n // 2 + k)], n=n)


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        HERE, "results", "ops-unix.json")
    with open(path) as f:
        results = json.load(f)

    print(f"# {os.path.basename(path)}\n")

    for shape, gloss in SHAPES:
        present = [(k, r) for k, r in results.items()
                   if shape in r.get("shapes", {})]
        if not present:
            continue
        meta = present[0][1]["shapes"][shape]
        rows, cols = meta["rows"], meta.get("columns", 4)
        values = rows * cols

        print(f"\n## {shape} — {gloss}")
        print(f"   {rows} rows x {cols} columns"
              + (f"  ({values} values an operation)" if values else ""))

        # --- the wall clock -------------------------------------------------
        wall = []
        for key, r in present:
            for arm, a in r["shapes"][shape]["arms"].items():
                wall.append((st.median(a["blocks"]), key, arm))
        wall.sort()
        best = wall[0][0]
        print("\n   wall clock")
        for ns, key, arm in wall:
            mark = "raw " if arm == CONTROL[key] else "    "
            print(f"     {mark}{LABEL[arm]:<16} {ns:>11,.0f} ns"
                  f"   {ns / best:>5.2f}x")

        # --- the tax --------------------------------------------------------
        taxes = []
        for key, r in present:
            arms = r["shapes"][shape]["arms"]
            ctl = arms.get(CONTROL[key])
            if not ctl:
                continue
            for arm, a in arms.items():
                if arm == CONTROL[key]:
                    continue
                p = paired(a["blocks"], ctl["blocks"])
                if p:
                    taxes.append((arm, key, p))
        if taxes:
            print("\n   cost over that language's own raw driver"
                  "  (paired, 95% CI)")
            for arm, key, p in sorted(taxes, key=lambda t: t[2]["median"]):
                verdict = ("indistinguishable" if p["lo"] <= 0 <= p["hi"]
                           else "real")
                note = "" if arm in ON_CONTROL else "   [own driver — not a tax]"
                per = (f"{p['median'] / values:+7.2f} ns/value"
                       if values else "              ")
                print(f"     {LABEL[arm]:<16} {p['median']:>+11,.0f} ns"
                      f"  [{p['lo']:>+9,.0f}, {p['hi']:>+9,.0f}]"
                      f"  {per}  {verdict}{note}")

    print("\n\n## peak RSS of the benchmark process")
    for key, r in sorted(results.items(), key=lambda kv: kv[1].get("peak_rss_kb", 0)):
        print(f"   {key:<6} {r.get('peak_rss_kb', 0):>10,} kB")
    print()


if __name__ == "__main__":
    main()
