# Ten Postgres clients, one benchmark

Ten libraries across four languages, doing the same eleven operations against
the same Postgres. `bench/sql.zig` asks what `nilo_sql` costs against itself;
this asks what it costs against everybody else, and whether a cost belongs to
nilo, to its driver, or to nobody.

The results and the conclusions live in
[`bench/result/sql.md` §8](../result/sql.md). The reading version is
`report.html`. This file is how to run it and, more importantly, **why it is
built the way it is** — because the shape is not obvious and three of the
choices exist because the obvious version produced a wrong answer first.

## Running it

```bash
docker compose -f ../../sql/docker-compose.yml up -d
psql "$DATABASE_URL" -f fixture.sql

cd zigsql && zig build -Doptimize=ReleaseFast && cd ..
cd go    && GOCACHE=$PWD/../.gocache go build -o go-ops ops.go && cd ..
cd rust  && cargo build --release && cd ..
cd node  && npm install && npx prisma generate --schema schema.prisma && cd ..

TRANSPORT=unix PASSES=3 python3 ops.py
```

Then, in the order they answer questions:

| | |
|---|---|
| `summarise.py` | wall clock and paired cost, per shape — the report |
| `stability.py` | do the three passes agree which arm was faster? |
| `compare_runs.py old.json new.json` | do two whole runs agree? |
| `drift.py` | did the machine hold still, per pass, in absolutes |
| `census.py` | syscalls per prepared round trip, across the four drivers |
| `arm_census.py` | the same, but one Zig arm at a time — what settles whether a `nilo_sql` difference is on the wire or in the CPU |

**Run the sweep twice and keep both files.** One run cannot tell you whether a
difference is resolvable, and that is not a nicety — see below.

`TRANSPORT=tcp` is the default and `unix` is the one to use; the same server
over a socket is 133% faster than over a published Docker port, and which one a
number came through is part of the number. `PASSES` is not only a loop bound:
it is the unit the sign check splits on.

## Why it is built this way

**The quantity is smaller than the machine's own drift.** A mapper's overhead
can be under 1% of an operation; this box moves up to 8% over a few minutes. Run
each library in turn and you have measured the running order.

So **every arm for a language lives in one process and the blocks interleave**,
with the order rotated each block, and what is reported is the *median of
per-block differences* — never the difference of two medians. Drift lands on
both halves of a pair and cancels.

**Every arm must produce an identical checksum** over what it decoded: the sum
of the ids, the ages, the email lengths and the timestamps. Ten libraries, four
languages, one number. A library that decodes lazily cannot reach it, which is
what stops *fast* from meaning *did less*.

**Warm-up runs over every shape before any shape is timed.** Warming each shape
immediately before its own block made whichever ran first read 32 µs in its
opening blocks and 24.6 µs in its closing ones — a 23% slide that looked exactly
like a finding.

**Each ORM is paired against the raw driver of its own language, and four of
them are literally built on it.** For those four the subtraction is clean. SQLx
and Prisma bring their own driver, so their distance is part driver and part
mapper; the report marks those rows rather than dropping them, because "this is
not an ORM cost" is worth saying once per row. It also turned out to matter in
the other direction: two ORMs are *faster* than the driver they sit on, because
a driver's default row object can cost more than the struct a mapper fills
directly.

**`ops.py` runs the candidates round-robin**, never all of one library's passes
back to back, and checks with `pgrep` that no previous candidate is still alive
before starting the next.

### The rule that a pooled interval was not enough

This one cost a run to learn and it is the reason `stability.py` and
`compare_runs.py` exist.

Pooling 900 blocks narrows a confidence interval on the assumption that the
blocks are exchangeable. **Passes are not exchangeable** — each is a separate
session with its own thermal state — so pooling shrinks the error bar around a
centre that is itself moving. Every one of `nilo_sql`'s differences had a pooled
interval excluding zero, and split back per pass the sign moved: `key` read
+212, +178, **−147** ns. Across two whole runs the wide scan read **−35,008 ns
then +5,387**.

It only happened to one library. GORM, Drizzle, Prisma and diesel-async held
their sign in all six pass-measurements with swings of 0.4–7%, because their
differences are 20 to 6,500 times larger. So the split does not separate a
reliable box from an unreliable one — **it separates a difference this harness
can resolve from one it cannot.**

A difference is therefore real only when the interval excludes zero **and all
six pass-measurements agree which arm was faster**. `summarise.py` prints
`below resolution` for the case where the interval alone would have said yes.

Two corollaries, both learned the same afternoon:

- **The "before" for a re-run is the old run's clean pass, not its pooled
  median.** The first sweep here overlapped a peer session's multicore build for
  13 of its 28 minutes, so passes 1 and 2 were dirty and pass 3 was not.
  Comparing against the pooled figure would have credited the re-run with an
  improvement it did not earn — the same mistake in a mirror.
  `compare_runs.py` takes pass 3 alone.
- **Contamination is monotone in its window.** A scattered slowest-pass count is
  therefore *not* contamination; it is something in your own session, or heat.
  8/5/8 across three passes is what that looks like.

## The shapes

Eleven, and the arrangement is the argument. The first four hold the table at
four columns and raise the row count; the next two hold the row count and widen
the table to twenty columns, which is the axis a real entity table grows along.
A mapper costing per *row* and one costing per *value* look identical on the
narrow ones and nothing alike on the wide ones.

| shape | rows × cols | what it separates |
|---|---|---|
| `empty` | — | protocol and socket, nothing else. Raw arms only |
| `key` | 1 × 4 | what an ordinary request does; round trip dominates |
| `page` | 20 × 4 | a page of a list, with a filter and a sort |
| `scan` | 1000 × 4 | where reflection stops hiding behind the socket |
| `wide` | 1 × 20 | width instead of length |
| `wide_scan` | 1000 × 20 | 20,000 values in one answer |
| `insert` | 1 × 4 | fixed per-call overhead, nothing to decode |
| `batch` | 100 × 4 | `unnest` arrays against a multi-row VALUES |
| `update` | 1 × 4 | the same work as insert, different statement |
| `delete` | 1 × 4 | the simplest operation here; one integer in |
| `tx` | 2 × 4 | four statements where the others send one |

The write shapes read the stored row back through `RETURNING`, so an arm that
discarded it would be doing less work and its checksum would not match.
`fixture.sql` gives each write shape its own table, and `prepareWrites` restores
it before **each arm's** block rather than before each pair — two arms writing
the same primary keys into a table only one of them emptied is a
unique-violation, not a benchmark.

`fixture.sql` also turns `synchronous_commit` off for the throwaway database,
and the comment there explains why: with it on, one autocommitted INSERT is
660 µs and every library reads the same, because what is being timed is an fsync
of the write-ahead log. That figure is reported beside the write numbers rather
than instead of them.

## Environment knobs

| | |
|---|---|
| `TRANSPORT` | `tcp` (default) or `unix`. Per-candidate DSN spellings are in `ops.py` — they disagree, and a candidate silently falling back to TCP would be the one wrong result nobody could see |
| `PASSES` | 3 by default; the unit the sign check splits on |
| `OPS_BLOCKS`, `OPS_WARMUP`, `OPS_SHAPES` | census knobs. A `strace` run has to be small and unwarmed |
| `OPS_ARMS` | `raw` or `nilo`, Zig only. Runs one arm alone, because `strace` cannot tell two interleaved arms apart. Never a benchmark setting — a lone arm is timed against the clock, so the drift the interleaving cancels comes straight back. `arm_census.py` is what it is for |

## One worked example of using these together

The sweep found `nilo_sql` costs +2,966 ns on `insert` and +1,673 ns on `delete`
over raw pg.zig, and nothing measurable on `update`. Both figures land within a
whisker of one unix-socket round trip, so the extra-packet theory was obvious,
coherent, and matched the magnitude.

`arm_census.py` killed it in one run: **4.04 socket calls an insert, 4.00 an
update, 4.12 a delete, identical in both arms to two decimal places.** Same
packets, so the cost is CPU inside the process and the next probe is a profile,
not protocol code.

Two things about that are worth copying. The plausible answer was tested
*because* it was plausible — an untested cause that fits the number is how a
wrong premise gets planned against. And the tool needed to test it did not
exist, which cost twenty lines and a `zig build`; the alternative was a paragraph
of reasoning nobody could check.

## Adding a candidate

A new library goes in its own directory beside `zigsql/`, `go/`, `rust/` and
`node/`, and owes four things:

1. **Every shape**, or the driver drops it from that shape's table.
2. **The checksum**, bit for bit. `writtenEmail`, `writtenAge` and
   `writtenMicros` in `zigsql/src/ops.zig` are the definitions; `epoch_base_s`
   is `1_767_225_600`.
3. **A raw arm from its own language**, prepared the same way, doing the same
   decoding and the same copies. A control that skipped a copy would charge the
   mapper for it.
4. **A `RESULT {...}` line** on stdout or stderr: `{"language", "shapes":
   {name: {"rows", "columns", "rounds", "arms": {name: {"checksum",
   "blocks"}}}}, "peak_rss_kb"}`.

Then a row in `CANDIDATES` in `ops.py` naming its control arm and its unix DSN.
No change to the repository's root `build.zig` is needed or wanted — `zigsql/`
reaches nilo through a path dependency, which is also a standing check that the
module graph works from outside the repo.
