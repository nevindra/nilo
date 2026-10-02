# SQL benchmarks

What `nilo_sql` costs, and whether the ORM is the bottleneck people expect an
ORM to be. Everything here was measured in one cycle, against a real Postgres,
with a control standing next to each number.

The short answer is on the last row of the transport table: **215,000 requests
a second with a real query per request over a Docker bridge, 458,000 over a
unix socket** — on a box that is also running the database and the load
generator. The long answer is that two of the numbers this repository had
already published were wrong, and finding that out was worth more than the
optimisation was.

Three harnesses produce these figures and they answer different questions:

- **`zig build bench-sql`** (`bench/sql.zig`) — one connection, one statement
  at a time, 20,000 rounds a side after 2,000 warm-up. What an *operation*
  costs.
- **`zig build bench-sql-server`** (`bench/sql_server.zig`) — a server with
  four routes, driven by wrk. What a *service* does with that saving.
- **`bench/compare-sql/ops.py`** — ten libraries in four languages over eleven
  operations, every ORM paired against the raw driver of its own language.
  Whether the cost is nilo's, its driver's, or nobody's — [§8](#8-ten-clients-four-languages-eleven-operations).

The second is the one that matters and the first is the one that explains it.
A per-operation saving measured only unloaded understates what it is worth at
a pool, by two to three times — see [§2](#2-what-that-is-worth-to-a-server).

The third one carries a lesson that applies to the other two and to anything
paired: **a confidence interval pooled across passes is over-confident**, and it
nearly published five differences that do not survive being asked twice. §8 has
the rule that replaced it.

[§11](#11-the-migration-module-against-everybody-else-as-an-experience) is not
a harness. It is the one axis of `sql.migrate` that has no timing: what it is
like to use, measured the only way that can be, by porting a real 59-table
schema onto it three times and counting what was left to write by hand.

## The machine

| | |
|---|---|
| CPU | AMD Ryzen 7 9700X — **8 physical cores, 16 threads, SMT on** |
| Memory | 30 GiB |
| OS | Ubuntu 26.04, kernel 7.0.0-29-generic |
| Zig | 0.16.0 |
| Postgres | 18.4, in Docker, default `shared_buffers`, `max_connections = 100` |
| Load generator | wrk 4.2.0 |
| Commit | `c0ad817` |
| Transport | stated per table — it changes the answer by 133% |

**Three programs share eight physical cores here**: nilo, Postgres and wrk.
That is the single biggest caveat on every throughput figure below, and it cuts
in nilo's favour on the ratios and against it on the absolutes. A deployment
with the database on its own box has more room than these numbers show, not
less.

**Which transport a number was measured through is part of the number.** The
first sweep in this cycle went over Docker's published port, which is iptables
DNAT to a container address, and it cost 57% of the throughput. Tables below
say which.

## 1. What a prepared statement saves, per operation

`bench/sql.zig`, `PREPARED=0` against the same binary with it on. Same
connection, same rows, same everything else.

> **Method note, added 2026-08-17.** These two tables were taken with **one
> pass per side**. The harness now runs five interleaved passes and prints the
> range as well as the best — see [§9.5](#95-the-timing-arm-exists-and-this-machine-cannot-run-it)
> for why. Nothing below was re-run, so the tables and the current output are
> not the same measurement. The conclusions survive on margin — a fixed ~11 µs
> is far outside any plausible spread on an eight-core box — but a re-run is
> owed before these numbers are compared against a new one.

**Over the Docker bridge** (`127.0.0.1:5433` → DNAT → `172.22.0.2:5432`):

| | parsed every time | prepared once | saved |
|---|---|---|---|
| a bare round trip (`SELECT 1`) | 29,252 ns | 24,615 ns | 4,637 ns (**15.9%**) |
| a key lookup | 38,895 ns | 27,537 ns | 11,358 ns (**29.2%**) |
| a page with a sort | 98,901 ns | 81,417 ns | 17,484 ns (**17.7%**) |
| `db.find`, the whole module | 37,911 ns | 26,022 ns | 11,889 ns (**31.4%**) |

**Over a real loopback socket**, same binary, same day:

| | parsed every time | prepared once | saved |
|---|---|---|---|
| a bare round trip (`SELECT 1`) | 17,881 ns | 11,945 ns | 5,936 ns (**33.2%**) |
| a key lookup | 24,783 ns | 13,993 ns | 10,790 ns (**43.5%**) |
| a page with a sort | 79,728 ns | 67,787 ns | 11,941 ns (**15.0%**) |
| `db.find`, the whole module | 24,693 ns | 13,795 ns | 10,898 ns (**44.1%**) |

Three things to read off those rather than off the percentages.

**The saving is a fixed ~11 µs, not a share.** It is Parse and Describe, and
those do not care how much work the statement then does — which is why the same
absolute number reads as 29% on the bridge and 43.5% on loopback. **The
percentage is a property of the transport as much as of the feature**, and
quoting one without the other is how a benchmark misleads honestly.

**The bare round trip is the control and it earns its place.** `SELECT 1` has
nothing to prepare worth preparing, and it still saves 5–6 µs — so a chunk of
what the key lookup saves is the protocol, not the plan. Without that row the
first table reads as if the query planner were the whole cost.

**The module does not eat it.** The fourth row is the honest check on the
others: `db.find` builds a parameter tuple, fills a Row and copies its text
into the arena, identical on both sides of the subtraction. It came out
*higher* than the raw driver call it wraps, and the difference between rows two
and four is **about 100 ns** — a quarter of one percent of a key lookup. That
is the entire run-time price of the typed layer over this driver, and
`bench/sql.zig` now measures it every run. If a DX feature ever makes `db.find`
expensive, that is the row it shows up in.

## 2. What that is worth to a server

`bench/sql_server.zig`, `/people/:id`, wrk, **over the Docker bridge**.

| | before | after | |
|---|---|---|---|
| **one request at a time** (c=1) | 14,876 req/s, p50 64.5 µs | 18,456 req/s, p50 52 µs | **+24%** |
| pool 8, c=32 | 89,293 req/s, p99 848 µs | 134,971 req/s, p99 564 µs | **+51%** |
| pool 32, c=64 | 105,667 req/s, p99 1.38 ms | 176,635 req/s, p99 0.99 ms | **+67%** |
| pool 64, c=64 | 112,030 req/s, p99 1.99 ms | 190,945 req/s, p99 1.88 ms | **+70%** |

**The first row is the honest one and the rest are the interesting ones.**
Unloaded, 12 µs off a 64 µs request is the ~19% arithmetic says it should be.
Loaded, it is two to three times that — because **a pool connection is a serial
queue**, and time not spent holding one is capacity. Cut 30% off how long a
query holds its connection and that connection pushes about 43% more; Postgres
spending less of itself on Parse gives back the rest.

This is the habit worth keeping from this cycle: **measure a per-operation
saving twice, once unloaded and once at the pool.** They are different numbers
and only one of them is what the user gets.

The caveat belongs next to the figure: this benchmark's request *is* the query.
A service doing other work per request sees the same absolute 12 µs against a
larger total.

## 3. The transport, which is bigger than anything in the code

Pool 64, `/people/:id`, one container at a time so nothing shares a page cache.

| | c=1 | c=64 | p50 at c=64 | p99 at c=64 |
|---|---|---|---|---|
| Docker published port | 18,487 req/s | 197,109 req/s | 278 µs | 1.65 ms |
| loopback TCP (`--network host`) | 24,336 req/s | 358,531 req/s | 143 µs | 0.91 ms |
| unix socket | 27,033 req/s | **458,467 req/s** | 113 µs | 0.91 ms |

bridge → loopback **+82%**. loopback → unix **+28%**. bridge → unix **+133%**,
and the tail halves.

There is no `docker-proxy` in this path — it is pure iptables DNAT to
`172.22.0.2:5432`, which is the *fast* configuration of the slow one. The cost
is conntrack and the extra netfilter traversal per packet, paid twice per round
trip, several hundred thousand times a second.

**This is the largest single lever measured in this cycle, and it is not in
nilo's code.** It is one line of deployment:

```zig
// same box as the database, or a sidecar sharing a network namespace
try nilo.sql.Db.open(io, gpa,
    "postgres://user:pass@%2Fvar%2Frun%2Fpostgresql%2F.s.PGSQL.5432/app", .{});
```

pg.zig treats a host beginning with `/` as a unix socket path, and it wants the
**full socket path** — not libpq's directory. Percent-encode the slashes so the
URL parser keeps them in the host field. Getting that wrong is
`error.Unexpected`, which is how an hour went.

## 4. Is the load generator the ceiling? No.

Every table above is only worth what the client can push, so:

| wrk threads | req/s (`/health`) |
|---|---|
| 2 | 496,086 |
| 4 | 482,328 |
| 8 | 482,889 |

Flat, and *down* slightly with more threads — the generator is not the
constraint, the box is. **~490k is what this machine does with three programs
on eight physical cores**, and the unix-socket figure of 458k is 94% of it.
That is the real ceiling being reported, not nilo's.

## 5. Where the time goes

Same box, c=64, from `/proc/<pid>/stat` over a fixed wrk run.

| route | req/s | cores busy | CPU per request |
|---|---|---|---|
| `/health` (a constant, no `Ctx`) | 1,135,223 | 6.96 | 6.13 µs |
| `/people/:id` (one `db.find`) | 215,577 | 4.70 | 21.8 µs |

Split into user and system time:

| | user | sys |
|---|---|---|
| `/health` | 1.66 µs | 4.33 µs |
| `/people/:id` | 4.79 µs | 15.73 µs |
| **a query adds** | **3.13 µs** | **11.40 µs** |

**A query costs 3.6× more kernel than user.** Almost all of what a database
route spends is the socket — write, read, epoll, and on the bridge the
netfilter traversal on top. The ORM's share is the 3.13 µs of user time, and
about 0.1 µs of that is nilo's typed layer (§1).

The other half of that table is the answer to the question this cycle was
opened with. **nilo takes 4.70 of ~14 busy cores while serving 215k database
requests a second**, and it does not appear in the top twenty processes by CPU
while the run is going — Postgres and wrk do. A framework that is the
bottleneck does not look like that.

## 6. Pool size

Docker bridge, c=64, prepared on.

| pool | req/s | p99 |
|---|---|---|
| 2 | 60,216 | — |
| 4 | 99,276 | — |
| 8 | 132,962 | — |
| 16 | 147,638 | — |
| 32 | 179,983 | **784 µs** |
| 64 | 206,423 | 1.88 ms |
| 128 | *server would not start* — `max_connections = 100` | |

Throughput keeps climbing to 64 and the tail gets worse doing it. **32 is the
best row on this box**, and the shape generalises further than the number does:
past the point where the pool has more connections than the database has cores
to serve them, extra connections buy queueing rather than concurrency.

The 128 row is not a footnote. It is how [ADR
115](../../docs/adr/115-a-boot-dials-the-connection-its-work-needs.md)
was found — `connect_on_init` was 8 and the pool still exhausted a hundred
backends, which is arithmetic that does not work unless the option is being
ignored. It was. Every pool nilo had ever opened dialled itself in full, and
the header claiming a server boots with its database down had been false since
the module was written.

## 7. Memory per idle connection

500 keep-alive connections, one request on each, then read `VmRSS` while they
sit idle.

| route | what it does | bytes per idle connection |
|---|---|---|
| `/health` | a constant `[]const u8`, no `Ctx` | **8,749** |
| `/fixed/:id` | a `Ctx`, a four-field struct, JSON | **9,756** |
| `/people/:id` | the same, plus one `db.find` | **17,022** |
| `/deep/:id` | `/fixed` plus 8 KiB of stack touched — **no database** | **17,932** |

The first row confirms ADR 017's 8,767 to within eighteen bytes, which is what
a floor should do. **The fourth row is the finding**: a handler that does
nothing but `@memset` an 8 KiB array holds *more* per idle connection than one
that runs a query. The 7.3 kB the database route looked like it cost is not the
database — it is how deep pg.zig's protocol code goes.

| stack touched by the handler | bytes per idle connection | over the 9,756 baseline |
|---|---|---|
| 8 KiB | 17,924 | +8,168 |
| 32 KiB | 42,491 | +32,735 |
| 128 KiB | 140,787 | +131,031 |

One for one. A suspended fiber holds its stack at its high-water mark for the
life of the connection, so **every byte a handler ever touches is a byte held
until that connection closes**. The write-up is [ADR
062](../../docs/adr/062-where-a-connection-waits-is-what-it-costs.md); the guidance
it produces is the opposite of the usual Zig instinct — *in this framework the
arena is cheaper than the stack.*

Two controls, because "memory went up" has cheaper explanations that had to be
eliminated first:

- **Not the arena.** `arena_keep` swept 0 → 64 KiB changed nothing: at
  `arena_keep = 0` the database route still held 18,440 bytes a connection, and
  throughput across the whole sweep was 178k–186k req/s, which is noise. The
  16 KiB retained block is buying less than it looks like it is.
- **Not a leak.** 500 connections × 1 request grew 8,384 kB; 50 × 10 — the same
  500 requests — grew 868 kB; 50 × 100, ten times the work, grew 876 kB. It
  scales with connections, not requests.

Two smaller figures for the same axis: a pool connection is **~7 kB** idle, and
the prepared-statement cache is **0.9 kB a connection** — 56 kB across a pool
of 64 with one statement in flight, paid by pg.zig rather than by nilo.

## 8. Ten clients, four languages, eleven operations

`bench/compare-sql/`, a second harness with a different question: not what
`nilo_sql` costs against itself, but what it costs against everybody else.
Ten libraries — `nilo_sql`/pg.zig, GORM/pgx, diesel-async and SQLx over
tokio-postgres, Drizzle and Prisma over node-postgres — each doing the same
eleven operations. **Over a unix socket, 900 samples a library, two complete
runs of three passes each.** The report page is
`bench/compare-sql/report.html`.

Every ORM is paired against the raw driver of *its own* language. Four of them
are literally built on that driver, so the subtraction is clean; SQLx and Prisma
bring their own, and those rows are marked rather than read as an ORM cost.

### The method correction, which is the finding that mattered most

**A pooled confidence interval over three passes is over-confident, and it
nearly published five results that do not exist.**

Pooling 900 blocks narrows the interval on the assumption that the blocks are
exchangeable. They are not: each pass is a separate session with its own
thermal state. Split back per pass, every one of `nilo_sql`'s differences
changed sign — `key` read +212, +178, **−147** ns — while each pooled interval
excluded zero and would have been reported as real. Run it twice and the same
thing happens across runs: the wide scan read **−35,008 ns in run 1 and +5,387
in run 2**.

GORM, Drizzle, Prisma and diesel-async held their sign in all six
pass-measurements with swings of 0.4–7%. So the split does not separate a
reliable box from an unreliable one. It separates a difference the harness can
resolve from one it cannot.

The rule now, enforced in `ops.py`, `stability.py` and `artifact_data.py`: a
difference is real only when the interval excludes zero **and all six
pass-measurements agree which arm was faster.** `stability.py` checks that
inside one run, `compare_runs.py` across two — and the "before" it compares
against is run 1's *pass 3 alone*, the only pass taken on a box as quiet as the
re-run's. Comparing against run 1's pooled figure would have credited the re-run
with an improvement it did not earn, which is the same mistake in a mirror.

**Two things that rule does not do, both found by a peer session hitting them
in a harness of the same shape.**

- **It filters noise, not validity.** Six measurements agreeing on a direction
  says the difference is resolvable; it does not say the difference is a *cost*.
  Two things bounded by different resources produce a tight, repeatable,
  meaningless number — the peer's control saturated memory bandwidth while the
  route subtracted from it was throttled upstream, and the rule passed. Every
  paired comparison in §8 sends the same SQL over the same connection, so the
  differences here are costs by construction, but **it is reading the two code
  paths that establishes that, not the rule.**
- **The control has to do the allocation the real path does**, not merely produce
  the same bytes — and when it does not, say which way the asymmetry cuts. On
  every multi-row shape here `nilo_sql` builds and returns a slice of Rows while
  the raw arm accumulates an `i64` and never allocates an array, so **the bias
  runs against nilo**: every `nilo_sql` figure in §8 is a ceiling. Same for
  `insertMany`'s one array per column against the control's stack arrays. Left
  as-is and disclosed rather than fixed, because `db.select` returning a slice
  *is* the thing being measured, and a control that built no slice would be
  measuring a nilo nobody can call. It also makes the read finding *stronger*:
  building that array still lands under the resolution floor.

Three habits came out of it and all three are checks rather than paragraphs:

- **Warm up across every shape before timing any of them.** Warming each shape
  immediately before its own block made whichever shape ran first read 32 µs in
  its opening blocks and 24.6 µs in its closing ones — a 23% slide that looked
  exactly like a finding.
- **Every arm must produce an identical checksum** over what it decoded. That is
  what stops a library buying speed by decoding lazily.
- **`ops.py` runs `pgrep` for every candidate binary before each run** and warns
  if a previous one is still alive. `subprocess.run` waits on the direct child
  and nothing else.

### Reading

Medians, nanoseconds per operation. `raw` marks a driver with nothing above it.

| | 1 row × 4 | 1000 × 4 | 1 row × 20 | 1000 × 20 |
|---|---|---|---|---|
| raw pg.zig | 9,405 | **92,774** | 11,507 | **374,716** |
| `nilo_sql` | 9,916 | 93,728 | 11,576 | 380,282 |
| raw pgx | 7,774 | 117,180 | 9,802 | 376,328 |
| GORM | 10,697 | 484,094 | 15,446 | 2,020,551 |
| raw tokio-postgres | **6,204** | 134,165 | **7,759** | 484,360 |
| diesel-async | 7,417 | 164,208 | 9,543 | 439,818 |
| SQLx | 6,217 | 317,826 | 8,618 | 941,378 |
| raw node-postgres | 11,014 | 697,383 | 17,497 | 2,455,166 |
| Drizzle | 33,674 | 667,060 | 65,136 | 2,739,296 |
| Prisma | 66,546 | 2,372,744 | 126,072 | 8,993,099 |

**Two orderings, and which one applies depends on the shape.** On one row the
round trip dominates and six of the ten land inside 6.2–11 µs. On a thousand
rows of twenty columns the round trip is a rounding error, pure decode is what
is left, and tokio-postgres — *fastest* at one row — falls to 1.29× while
pg.zig leads.

`nilo_sql`'s difference from pg.zig is **not measurable on any of the four**,
by the rule above. That is the result, and it is a stronger one than the
+0.29 ns/value the pooled interval offered.

Two ORMs beat the driver they sit on, both surviving all six measurements:
**Drizzle is 60,283 ns faster than raw node-postgres** on the narrow scan and
**diesel-async is 46,601 ns faster than raw tokio-postgres** on the wide one.
A driver's default row representation can cost more than the struct a mapper
fills directly — node-postgres builds a name-keyed object per row.

### Writing and deleting

| | insert | 100 in one statement | update | delete | tx |
|---|---|---|---|---|---|
| raw pg.zig | 12,252 | **134,554** | 12,133 | 11,168 | 28,872 |
| `nilo_sql` | 15,778 | 140,428 | 11,508 | 13,584 | 31,265 |
| raw pgx | 12,274 | 157,234 | 10,251 | 10,649 | 28,455 |
| GORM | 56,194 | 401,920 | 52,609 | 57,867 | 67,035 |
| raw tokio-postgres | **10,553** | 143,848 | 9,412 | **9,165** | 24,666 |
| diesel-async | 31,564 | 273,988 | 28,436 | 14,668 | 47,753 |
| SQLx | 13,052 | 169,629 | **9,366** | 12,690 | **24,350** |
| raw node-postgres | 16,596 | 279,985 | 13,435 | 13,866 | 38,874 |
| Drizzle | 39,913 | 1,016,878 | 38,318 | 33,932 | 90,911 |
| Prisma | 77,152 | 1,395,005 | 74,535 | 74,268 | 221,707 |

**These numbers only exist because `synchronous_commit` is off** for that
throwaway database. With it on, one autocommitted INSERT is **660 µs** and every
library reads the same, because what is being timed is an fsync of the WAL. That
is a true number about the workload and a useless one about the comparison, and
it is reported here rather than replaced.

**Single-row writes spread 4–8× while decoding nothing.** There is no bulk work
to hide a fixed cost behind, so what separates the field is how many layers a
call crosses before it becomes a statement.

**The batch shape measures two strategies, not two implementations.** pg.zig and
`nilo_sql` send one array per column and `unnest` server-side, so the statement
text is a constant whatever the batch size (ADR 047). GORM, Diesel, Drizzle and
Prisma build a multi-row VALUES, so the text grows with the batch and Postgres
parses a new statement every time: 1.3 µs a row against 14 µs.

**`nilo_sql`'s only two measurable costs in the whole matrix are here** —
`insert` **+2,966 ns** and `delete` **+1,673 ns** over raw pg.zig, both holding
across all six measurements. `update`, which does nearly the same work, is not
measurable. All three go through prepared statements with the same comptime plan
name and all three return one row.

**The obvious explanation is an extra packet, and it is wrong.** The gap is
almost exactly one unix-socket round trip (~2.6 µs), so `OPS_ARMS=nilo|raw` was
added to run one arm alone — `strace` cannot tell two interleaved arms apart —
and the count came back identical:

| shape | raw pg.zig | `nilo_sql` |
|---|---|---|
| insert | 4.04 socket calls/op | 4.04 |
| update | 4.00 | 4.00 |
| delete | 4.12 | 4.12 |

Marginal over 100 operations by the same subtraction `census.py` uses, and
`readv`/`sendmsg` split evenly in both arms. **Same packets, same round trips,
so the cost is CPU inside the process.** Why it lands on insert and delete and
not on update is open, and **the next probe is a profile rather than a packet
count** — which is the whole value of having killed the plausible answer first.

### pg.zig: the best decoder here, and one round trip wasted

The driver question this sweep was run to answer, settled from the bytes on the
socket. For a prepared statement **already in the cache**:

```
pg.zig    sendmsg  5 B  S       -> readv     6 B  Z      <- carries no work
          sendmsg 44 B  B E H   -> readv    40 B  2 D C
pgx       write   88 B  B D E S -> read     40 B  2 T D C Z
tokio-pg  sendto  32 B  B E S   -> recvfrom 40 B  2 D C Z
```

`conn.zig:243`, on the cache-hit branch, writes a standalone `Sync` and waits
for `ReadyForQuery` before sending Bind and Execute. **Caching the statement
saves the server's Parse and does not save the round trip.**

| driver | syscalls/query | round trips | `SELECT 1` unix | `SELECT 1` bridge |
|---|---|---|---|---|
| pg.zig | 4.00 | **2** | 8,080 | 24,335 |
| pgx | **2.05** | 1 | 5,364 | 15,146 |
| tokio-postgres | 4.01 | 1 | **4,758** | 14,288 |
| node-postgres | 4.66 | 1 | 7,208 | — |

The extra trip is ~2.6 µs over a unix socket and ~9.2 µs over the Docker bridge,
which is why pg.zig's deficit roughly triples with the transport. **This is why
§1's single-row figures sit where they do, and it is upstream of nilo entirely.**

### Peak RSS of the benchmark process

| Zig | Rust | Go | Node |
|---|---|---|---|
| **4,116 kB** | 5,916 kB | 23,448 kB | 341,924 kB |

One connection, the same eleven operations. Not memory per connection — the cost
of the runtime existing, which is the figure that decides container density.

### What is not in this section

One connection, no pool, no HTTP — which is what makes the per-operation costs
clean and what leaves the service question open. §2 is the warning: a
per-operation saving measured only unloaded understated what it was worth at a
pool by two to three times. **Every difference above could change size or
direction behind a pool**, and `drive.py` is the harness that has not been
built.

## 9. SQLite: counters that hold, and a machine that cannot be timed

Taken 2026-08-17 on a **different machine from everything above**: a two-core
shared vCPU (Xeon Platinum 8255C, 7 GB), where the numbers in §1–§8 came from
eight physical cores. **Almost nothing in this section is a timing, and that is
the method rather than an apology.** A throughput figure taken on a shared vCPU
is a figure about the neighbours. Resident bytes and syscall counts are not, so
those are what was taken.

The exception is [§9.5](#95-the-timing-arm-exists-and-this-machine-cannot-run-it),
which is here because the *harness* was built and is worth having even though
its numbers are not.

The raw record is [`spike/sqlite_facts`](../../spike/sqlite_facts/), which runs
against zqlite 0.0.1 / SQLite 3.53.0 — the library the Wire ships with rather
than SQLite in the abstract, because the flags a wrapper passes to
`sqlite3_open_v2` decide several of these.

### What a pool connection holds

One writer and eight readers over a 2.9 MB table, 50,000 rows:

| | total | per connection |
|---|---|---|
| opened, idle | 252 KiB | **28 KiB** |
| after every reader has scanned the whole table | 16,892 KiB | **1,876 KiB** |

`PRAGMA cache_size` defaults to `-2000` — 2,000 KiB — and **it is a ceiling,
not an allocation**. ADR 065's first draft said a connection holds "roughly
2 MB … for the life of the pool" and that is only true of the second row. The
correction is the useful part: a service doing primary-key lookups pays the
first row, and the number a deployment sees is its working set.

Two numbers not to confuse with these: **an idle HTTP connection is unaffected**
(a pool connection is not a request's), and the prepared statements ADR 051
keeps are on top of both and are still unmeasured.

### What the page cache buys, in reads

If the ceiling costs 1.8 MiB a connection when it is reached, what does
lowering it cost? Reads are a counter, so this is answerable here.

| `cache_size` | 5,000 primary-key lookups over 200 hot rows | three full scans of the 2.9 MB table |
|---|---|---|
| −2000 KiB | 10 `pread64` | 2,261 `pread64` |
| −512 KiB | 10 | 2,265 |
| −128 KiB | 10 | 2,265 |
| −32 KiB | 10 | 2,265 |
| −8 KiB | **15,005** | — |

**The 2 MiB default buys nothing at either shape.** A hot working set fits in
32 KiB and reads the same ten pages whatever the ceiling; a scan larger than the
cache re-reads regardless, so 62× the memory is worth four reads out of 2,265.
The cliff between −32 and −8 KiB is the working set no longer fitting.

**This is not an argument for a small default**, and the limit is the
measurement rather than caution: the cliff sits wherever the working set sits,
and this one is 200 rows on a box whose OS page cache holds the whole file. A
database larger than RAM is where SQLite's page cache stops being a duplicate of
the operating system's, and nothing here reaches that.

### Binary size, which is the axis this module actually spends

`zig build size-sql -Doptimize=ReleaseFast` builds two programs differing by one
line — which database the single route reads. Stripped:

| | bytes |
|---|---|
| names `sql.Db` (Postgres) | 1,677,464 |
| names `sql.Sqlite` | 2,202,304 |
| **SQLite's cost to a program that uses it** | **524,840** |

**Re-run after the twenty-findings pass** (ADRs 066–0084), same machine, same
command, both trees built from a `git archive` so the before is built rather
than quoted:

| | before | after | Δ |
|---|---|---|---|
| names `sql.Db` | 1,677,464 | 1,694,344 | +16,880 |
| names `sql.Sqlite` | 2,202,304 | 2,217,696 | +15,392 |
| **SQLite's own cost** | **524,840** | **523,352** | −1,488 |

The published figure moved, which is the point of re-running it: 524,840 had
been reproduced exactly twice and was on its way to being a constant. Most of
the growth is not SQLite's — `example-hello`, which has no database in it at
all, moved 881,296 → 892,696 on the same pass, so the framework grew by about
11 KB and both probes carry it. SQLite's own share went *down* by 1,488 bytes,
which is the Dialect learning what form a uuid takes
([ADR 067](../../docs/adr/067-a-value-is-whatever-the-database-stores.md))
replacing what the SQLite Wire used to do about it.

`strings … | grep -ci sqlite` still answers 0 against the Postgres-only binary,
which is the claim that actually matters and the one this A/B exists for.

And the number that mattered more, because it was a claim rather than a
measurement until it was checked:

```
$ strings zig-out/bin/nilo-size-pg_only    | grep -ci sqlite
0
```

Both drivers live in one module, so both are fetched and the module links libc
whichever you use — but `sql/sqlite.zig` is analysed only when something names
it, so the amalgamation is dropped outright. **A Postgres-only binary carries
zero SQLite.**

### Five behavioural claims, and the one that was wrong

ADR 065 was written from SQLite's documentation and said so. Running it held
five claims — `:memory:` is private per connection, the shared URI form is one
database, WAL is unavailable in memory and *answers `memory` rather than
failing*, a shared in-memory database dies with its last connection, and a
read-only connection to a file refuses a write.

The sixth was found by a test failing rather than by reading, and it is the one
worth carrying forward: **`OpenFlags.ReadOnly` does not survive
`mode=memory`.** SQLite's URI `mode=` parameter takes precedence over the flags
handed to `sqlite3_open_v2`, so a "read-only" connection to a shared in-memory
database writes. On a file the same flag refuses.

That matters because the read-only reader is the backstop under routing
`db.raw` by its first keyword. In memory there is no backstop — so the test
that holds it opens a file, and the rule that locking tests cannot run in
memory is a correctness requirement rather than a coverage preference.

### 9.5 The timing arm exists, and this machine cannot run it

`zig build bench-sql` now has a SQLite half. It needs no server — a file in
`/tmp`, made and dropped by the program — and it asks the same question §1 asks
of Postgres, in the same three statement shapes, plus a write arm at both
`synchronous` settings because [ADR 065](../../docs/adr/065-one-writer-is-not-a-setting-it-is-the-database.md)
will not let a SQLite number be published without its durability beside it.

**It was run, and the run's finding is about the machine.** Three consecutive
passes of the same side of the same comparison gave 4,537, 6,158 and 8,281
ns/query — a spread of 1.8×. `uptime` explains it: load average **5.03 on two
cores**, so the box is oversubscribed 2.5× by neighbours nothing here controls.

That changed the harness rather than the write-up. Each comparison now runs
five interleaved passes, and prints two things instead of one: the best pass on
each side, and **the range of the saving across pairs**. What that prints here:

| | best of 5 | saving | across the passes |
|---|---|---|---|
| a bare round trip | 4,275 → 444 ns | 89.6% | 76.7% … 95.0% |
| a key lookup | 30,410 → 12,001 ns | 60.5% | 49.2% … 72.2% |
| a page with a sort | 518,888 → 538,973 ns | −3.9% | **−7.5% … +24.7%** |
| `db.find` through the module | 11,103 → 5,064 ns | 54.4% | 33.1% … 72.9% |

**Read the last column, not the third.** A key lookup's saving is somewhere
between a half and three quarters, which is a band too wide to put in a
sentence about a default. The absolutes are worse than useless: 12 µs for a
primary-key lookup against a 1,000-row table is roughly ten times what SQLite
costs on a machine nobody else is using, and taking the *minimum* of five
passes did not rescue it — an earlier single pass had come in at 4,537.

Two things do survive the noise, because they are structural rather than
marginal:

- **Preparing once is worth much more on SQLite than on Postgres**, and the
  reason is arithmetic rather than a measurement. On Postgres, skipping Parse
  and Describe saves 31% of a key lookup (§1) because the round trip is still
  there underneath. On SQLite there is no round trip: `sqlite3_prepare_v2` *is*
  the statement's fixed cost, so removing it removes most of what a cheap query
  costs. Every pass on every machine will put this well above §1's 31%.
- **On a statement whose own work dominates, it is worth nothing.** The page
  with a sort scans a thousand rows and sorts them; a prepare is ~20 µs against
  ~500 µs of that, so the true saving is a few percent and the ±25% band above
  is entirely noise. Postgres kept 15% on the same shape because its round trip
  does not scale with the sort. **`prepared` is a fixed-cost optimisation, and
  what it is worth is decided by what it is a fraction of.**

The write arm printed 33 µs at `NORMAL` against 1.78 ms at `FULL` — 54×. That
one is a disk measurement and belongs to this VPS's storage rather than to
SQLite or to nilo, and it is in the harness so that the default is never quoted
without its alternative.

**Nothing in that table should be copied into a document.** It is here so the
next person knows the harness runs, knows what it prints, and knows what the
run has to be repeated on.

### What is missing from this section, and it is most of a benchmark

- **Every timing that means anything**, for the reason §9.5 gives. And the one
  ADR 064 is explicitly waiting for is not even in the harness: `.hop` against
  `.in_fiber` needs the Engine and a load generator — a run of `bench-sql-server`
  with each — rather than a single-threaded program.
- **A comparison.** §8 puts `nilo_sql` beside nine Postgres clients. The
  equivalent for SQLite — Go's `mattn/go-sqlite3` or `modernc`, Rust's
  `rusqlite`, Bun's `bun:sqlite` — is unbuilt, and building it on a shared
  vCPU would produce a table nobody should quote.
- **Contention.** One process throughout. What `busy_timeout` does when two
  writers meet is the case the reader/writer split exists for.
- **Download size and build seconds**, which every `nilo_sql` user now pays for
  a driver half of them will not use. The amalgamation is the slow half — a
  cold `zig build test-sql` spent about a minute of CPU inside `zig clang` —
  and "about a minute" is an impression rather than a measurement.

## 10. The migration module costs the server nothing, and that is measured

**What it answers.** `sql/migrate.zig` and the four files under it landed with
ADR 123. The claim in the ADR's cost table is that a server which imports
`nilo_sql` and never calls a migration function carries none of it. That is the
one axis of the four this module could plausibly spend, so it is the one with a
number.

**How.** The same A/B the section above uses. `zig build size-sql` builds two
stripped `ReleaseFast` programs, and the before side was built rather than
quoted: `git archive HEAD | tar -x` into a scratch directory, `zig-pkg/` copied
across, `zig build size-sql` there.

| | before (`1dfae4d`) | after | Δ |
|---|---|---|---|
| names `sql.Db` (Postgres) | 1,785,640 | 1,785,640 | **0** |
| names `sql.Sqlite` | 2,291,696 | 2,291,696 | **0** |

Byte for byte, both sides. `sql/sql.zig` gained `pub const table`, `ddl`,
`snapshot` and `migrate`, and a `pub const` nothing reaches is a declaration Zig
never analyses — the same property that keeps the SQLite amalgamation out of a
Postgres-only binary two sections up.

**What it changed.** The ADR's binary-size row went from a reasoned 0 to a
measured 0. Nothing else: no decision moved, and that is the entry's whole
value. A future reader who wonders whether shipping a schema toolkit inside the
database module taxes every server has the answer without re-running it.

**What is still not measured.** `applyPending`, the in-process runner a SQLite
application calls between `app.start(io)` and `listen()`, which *is* reachable
from a server and does carry its step text. The two probes above never call it,
so what a server that does call it pays is still an argument rather than a
figure. It wants a third probe here.

**Worth noting for the next re-run**: the two absolutes moved since the
twenty-findings pass above — `pg_only` 1,694,344 → 1,785,640 and `sqlite_only`
2,217,696 → 2,291,696, both about 5% — over everything that shipped between.
Neither is migration's. That is the standing reason this file insists a before
is built rather than quoted.

### 10b. The marker's new words cost the same nothing, re-measured

**What it answers.** ADR 181 put `.default`, an enum column's `CHECK`, a
partial and ordered `.index`, a `.name` on any constraint and `sql.Date` into
the marker. The first four are comptime and reachable only from `migrate`; the
fifth is a type, and both Wires gained a branch for it. The question is whether
any of that reaches a server that never names them.

**How.** Exactly as above: `git archive HEAD | tar -x` into a scratch
directory, `zig build size-sql` on both sides, stripped `ReleaseFast`, and
`cmp` rather than a size comparison.

| | before | after | Δ |
|---|---|---|---|
| names `sql.Db` (Postgres) | 1,800,600 | 1,800,600 | **0** |
| names `sql.Sqlite` | 2,305,584 | 2,305,584 | **0** |

`cmp` reports both pairs identical byte for byte. The `date` branches in
`postgres.read` and `sqlite.read` are inside a `comptime` test, so a Row with no
`sql.Date` in it never compiles them, and the rest never leaves `table.zig`.

**What it changed.** Nothing, which is the answer that was wanted: the cost
table in ADR 181 says 0 on all four axes and the fourth is measured rather than
reasoned. The two absolutes moved again since 10 above, `pg_only` +14,960 and
`sqlite_only` +13,888 over what shipped between, which is the same standing
reason to build the before.

### 10c. The words that cross tables, and the version file, cost nothing either

**What it answers.** ADR 181 made a foreign key a *list* of columns and let it
name its table as text; ADR 123 reshaped the generated version file and added
`generate --baseline`. The first of those is the one worth measuring: unlike
ADR 181's words, it changes a runtime comparison — `Reference.sameAs` now walks
two lists where it used to compare two names — and `where.zig` builds a join
fragment in a loop. The second touches `migrations.zig`, which is the half of
the module that opens files.

**How.** The same way, and against the same commit as 10b so the two are
directly comparable: `git archive HEAD | tar -x`, `zig build size-sql` on both
sides, stripped `ReleaseFast`, `cmp` rather than a size comparison.

| | before | after | Δ |
|---|---|---|---|
| names `sql.Db` (Postgres) | 1,800,600 | 1,800,600 | **0** |
| names `sql.Sqlite` | 2,305,584 | 2,305,584 | **0** |

`cmp` reports both pairs identical byte for byte, and this time **the two
absolutes did not move either** — the first pair in this file's history that is
unchanged on both counts, because nothing shipped between 10b and here.

**What it changed.** Nothing, and the reason is worth keeping rather than
re-deriving: the `Reference` diff and the version-file writer are both reachable
only from `migrate` and `migrations`, which a server that serves never names.
The only part of this work that *is* on a request path is `where.zig`'s join
loop, and it runs at comptime — the fragment is a constant in the binary, so a
composite `.exists` costs a longer string literal and no instructions.

### 10d. The second kind of word, an array default and the `.sql` twin: nothing again

**What it answers.** ADR 181 put `.check` and `.trigger` in the marker, which
adds two lists to `Desc` and two new diff functions to `migrate.zig`; ADR 181
made an array column's default a list; ADR 123 has `generate` write a `.sql`
file beside every version and `check` compare the two. ADR 181 added a mirror
struct to `snapshot.zig` for an older file. The question is the same one 10b and
10c asked, and the reason to ask it again is that this round is the first to
put new code in the *runtime* half of the diff rather than only in `table.zig`.

**How.** The same way, against the same commit as 10c so all four are directly
comparable: `git archive HEAD | tar -x` into a scratch directory,
`zig build size-sql` on both sides, stripped `ReleaseFast`, and `cmp` rather
than a size comparison.

| | before | after | Δ |
|---|---|---|---|
| names `sql.Db` (Postgres) | 1,800,600 | 1,800,600 | **0** |
| names `sql.Sqlite` | 2,305,584 | 2,305,584 | **0** |

`cmp` reports both pairs identical byte for byte, and the absolutes have not
moved since 10b — the second round in a row where nothing shipped in between.

**What it changed.** Nothing, and the reason is the layering rather than luck.
`diffChecks`, `diffTriggers`, `renderSql` and `snapshot.upgraded` are all
reachable from `migrate.plan` and `migrations.generate`, and a server reaches
`migrate` through `apply`, `expect` and `createMissing` — never through `plan`.
The two new Dialect declarations, `trigger_drop_names_table` and
`trigger_repeatable_head`, are a `bool` and a string literal that a program
naming no trigger never references.

**What it does cost is disk, and it is worth writing down because it is the
first axis in this file that is not the binary.** The `.sql` twin is roughly the
size of the version file beside it, once per version, committed. A ported schema
of sixty tables is a few hundred kilobytes of `CREATE TABLE` written twice:
§11 measures it at 267 KB for 59 tables.

## 11. The migration module against everybody else, as an experience

**What it answers.** §10 to §10d say what `sql.migrate` costs a server, and
the answer was nothing, four times. They say nothing about what it costs the
person. This section is that, measured the only way it can be. A 59-table
Postgres schema (nodeflux-os: 96 foreign keys, 85 `CHECK` constraints, 126
column defaults, 92 indexes of which 34 are partial, 31 `updated_at` triggers,
one view, one hypertable, 113 rows of reference data) was ported onto the
module three times, once per vocabulary the module shipped, and after each
round what still had to be written as SQL by hand was counted. The full record
with every finding is
[`docs/input_from_nodeflux.md`](../../docs/input_from_nodeflux.md). This is
the comparison and the verdict.

**How.** Each round: rewrite the fourteen section files under
`backend-zig/src/schema/` onto the marker words that had landed,
`db generate --name schema --baseline`, migrate an empty database from the
result, `pg_dump --schema-only` it and the goose-migrated reference, split
both dumps into facts (a column with its type, nullability and default; a
constraint with its name and body; an index with its name, columns and
predicate; a trigger; the view) and compare the two sets. The control is the
goose schema, which is what the Go binary serves. Round three added a second
control: the `.sql` twin applied by `psql -f` to a third, empty database, with
no nilo in the loop, which has to come out identical and has to leave a ledger
row `db verify` accepts.

**The three rounds.** v0.4.0 at `eb545fa`; `636d7b6` after ADR 180 to 0223;
`87759b1` after ADR 181 to 0227.

| | `eb545fa` | `636d7b6` | `87759b1` |
|---|---|---|---|
| Facts equal to the reference | 50 names apart, nothing else | 875 of 875 | 875 of 875, on both controls |
| Steps `generate` wrote | 149 | 186 | 217: 59 tables, 127 indexes, 31 triggers |
| Steps written by hand | 141 | 73 | 15, of which 10 are reference data |
| `CHECK` clauses by hand, of 85 | 85 | 60 | 0 |
| `updated_at` triggers by hand, of 31 | 31 | 31 | 0 |
| `SET DEFAULT` clauses by hand, of 126 | 126 | 2 | 0 |
| `CREATE INDEX` by hand, of 92 | 39 | 1 | 1, over `lower(btrim(site))` |
| Tables split between a Row and a step | 56 of 59 | 46 of 59 | 2 of 59 |
| Lines in `src/schema/` | 3,876 | 3,444 | 3,183 |
| Names differing from the reference | 50 | 0 | 0 |
| Applicable without a Zig toolchain | no | no | yes, 1,473 lines of `.sql` |

The five hand-written steps that are not reference data on `87759b1`: the
extension, the `set_updated_at()` function, the `sku_catalogue` view,
`create_hypertable` and the one index over an expression. The first three
are what a `sql.Schema` would take and it does not exist yet. The last two
are `.data` by design.

**What a round cost in effort, which is the number a DX claim owes.** Round
two converted thirteen section files in parallel, nine assistants working
from one converted file and a one-page recipe; the first build afterwards
compiled, and the one wrong fact in 875 was the recipe's own mistake. Round
three was one 140-line script over the fourteen files and the first build
compiled, zero wrong. A rebuild of the tool after editing one section file is
1.7 s, and `check` and `generate` open no database. The other side of the
same fact: three rounds is three `feat!` commits, and the marker changed
shape each time.

**What the diff does with the new words, checked rather than read.** On
`87759b1`, one `.check` body was edited and one `.trigger` renamed, then
`db check` reported four steps (drop and re-add the constraint, create the
new trigger, drop the old one) and `db generate --name probe` wrote exactly
those into `0002_probe.zig` and its twin. On the live database a moved
`CHECK` refuses a row under its original name and a moved trigger moves
`updated_at`. Both were tried inside a rolled-back transaction, not inferred
from the dump.

### Against the field

The nilo column is measured on the port above. The other five are read from
each tool's documentation, and none of them was run here; a cell in those
columns is a claim about a feature's existence, never about its quality or
its speed. Six tools because the question is what the *shape* buys: goose is
what nodeflux-os runs today, Prisma and Drizzle are the two typed-schema
tools with a diff, Django is the oldest autodetecting one, Atlas is the one
tool that diffs and stays language-agnostic.

| | nilo `87759b1` | goose | Prisma | Drizzle | Django | Atlas |
|---|---|---|---|---|---|---|
| Schema is a type the compiler checks | yes | no, SQL | its own DSL | yes, TS | yes, Python | HCL or SQL |
| Diff written by the tool | yes | no | yes | yes | yes | yes |
| Diff needs no database | yes | n/a | no, a shadow database | yes | yes | no, a dev database |
| `CHECK` in the diff | yes | n/a | not modelled | yes | yes | yes |
| Triggers in the diff | yes | n/a | not modelled | not modelled | not modelled | yes, part behind Pro |
| Views, functions, extensions | hand-written step | SQL, so yes | not modelled | views only | not modelled | yes, part behind Pro |
| Hash of an applied version, verified later | yes, `verify` | no | yes | stored, nothing verifies it | no | yes, `atlas.sum` |
| Binary refuses to serve a database at the wrong version | yes, `db.expecting` | no | no | no | no, a warning | no |
| Apply without the language's toolchain | yes, the twin | yes | yes, `.sql` | yes, `.sql` | no | yes, one binary |
| Author a version without the language's toolchain | no | yes | no | no | no | yes |
| `down` | no, by design | yes | no | no | yes | yes |
| Age | 0.x, path dependency | mature | mature | 0.x | mature | mature |

Three things to read off it rather than count.

The boot guard is the row nobody else has, and it is the one that changed
what the port is. A binary that knows its schema version at compile time and
refuses to accept a connection before the database is there is not a
migration feature, it is the migration feature's *consequence*, and none of
the five have it because none of them compile the manifest into the program.
Rails comes closest with `PendingMigrationError`, in development only.
`db.checking` beside it, which holds every context Row against the live
schema on the same boot, is what sqlc gives the Go side at compile time, one
layer later and against the database that is actually there.

Diffing without a database puts nilo with Django and Drizzle and against
Prisma and Atlas, and it matters most in CI, where a shadow database is a
second service to stand up for a check that is otherwise pure.

The row nilo loses outright is authoring, and it loses it to the two SQL-first
tools only. The twin fixes applying, and it fixes it more completely than
Prisma's `.sql` does, because it carries the ledger row and Prisma's needs
`migrate resolve` after a manual apply. But a DBA cannot write a version in
SQL and have nilo pick it up, and ADR 123 says why not on purpose. goose and
Atlas can. That is the first question a team whose database is shared with
another language will ask, and the answer is no. The `down` row is not a loss:
it is refused, and §10's ADR 123 gives the reason.

### The score

A score is an opinion and the rest of this file is measurements, so each
line carries the number that produced it, and the number is the part to argue
with. Out of five.

| | | why |
|---|---|---|
| Writing the schema | 5 | 59 tables in 3,183 lines, 15 steps by hand. The compiler refuses a name over 63 bytes, `.words_of` on a non-enum, two entries with one name, a reference to a table no Row claims. Equal to Drizzle; Prisma needs its own language; goose checks nothing until the database does. |
| The diff | 4.5 | 217 steps from Rows, 875 of 875, no database opened. All three cases for a `.check` and a `.trigger` hold. Off half a point for item 15 of the input doc (`--name` demanded for a run that writes only twins) and a 119.6 KB snapshot in the repository. |
| Applying | 4.5 | One transaction per version behind an advisory lock, a chained hash, `verify`. Flyway's and Prisma's class; goose, dbmate and Django keep no hash at all. No `down`, and the refusal is right. |
| The boot guard | 5 | `db.expecting` and `db.checking`, the row above. The message names the version the binary was built for, the version the database is at, and what the first request would do. |
| The escape hatch | 4 | `.data` with a `why` that becomes a comment in the twin, `before` and `after` slots the generator never touches. Every tool has one. Off a point because a 60-line view is sixty `\\` lines in a Zig string until `sql.Schema` exists. |
| Outside Zig | 3.5 | The twin: 1,473 lines, `psql -f`, 875 of 875, ledger row included. Authoring stays Zig. Django, Ecto and Alembic make the same trade; goose, dbmate, Flyway and Atlas do not. |
| Errors and documentation | 5 | Every refusal is a sentence that says what to do. Nine assistants converted thirteen files from a one-page recipe and the first build compiled. `guide/sql/migrations.md` grew 153 lines for four ADRs. |
| The loop | 4 | 1.7 s to rebuild after one file, no database for `check`. Off a point because `zig build db -- check` buries a non-zero exit under `failed command` and a Build Summary; that is the Zig build runner, not nilo, and it is paid daily. Calling `./zig-out/bin/db` directly is the answer. |
| Maturity | 2.5 | Three `feat!` in three rounds; the snapshot changed shape once (ADR 181 reads the old one). Postgres and SQLite only. No introspection of an existing database, no studio, no seed. Version 1 of this port is three committed files, 80.0 + 67.7 + 119.6 KB, where goose is one file of 1,483 lines. |

**Eight of ten overall.** On the work that is most of a migration tool's
life (writing the schema, the diff, the guard, the errors) nilo is level with
or ahead of Prisma and Drizzle and well ahead of goose. What holds it at
eight is the same three facts from three angles: a 0.x vocabulary that moved
three times, authoring that needs a Zig toolchain, and three objects still
written as strings.

For a Zig program there is nothing to compare it to and it should be used.
For a program whose database another language also writes to, it works
since ADR 123 and the person writing versions still needs Zig. For
nodeflux-os the answer is yes, because the binary now knows its schema and
the Go one never did.

**What would move the score.** On nilo's side: `sql.Schema` takes the
hand-written steps from 15 to 12, item 15 is one branch, and a vocabulary
that stops changing is what maturity means. On the port's side, not nilo's:
`src/schema/` declares 59 tables a second time because 8 of the 59 context
Rows leave out `created_at` and `updated_at`, and folding the two is what
ADR 181's by-name `.references` was for.

## 12. The arena's query at one connection

[HttpArena](https://github.com/MDA2AV/HttpArena)'s `async-db` profile —
1,024 connections at `GET /async-db?min=10&max=50&limit=N` over a
100,000-row table with no index on `price`, a pool of 256 — read nilo at
66,189 req/s on 874% of sixty-four CPUs, rank 53 of 79, where zix answers
400k, actix 149k and go-stdlib 86k. Neither the server nor Postgres was
busy: 66k a second over 256 connections is 3.9 ms a query, for a scan the
planner finishes in 0.1 ms. This section is what could be taken apart on
the two-core box, which is the per-query cost with one request in flight,
and what could not, which is the 64-thread question that decides the rank.

**The box is the two-vCPU one `http.md` names**, Postgres 18 in a container
on a Docker *published* port (`127.0.0.1:5440`, so `docker-proxy` is in the
path — the absolutes are inflated by it and only the differences between
rows are meant), the arena's own `pgdb-seed.sql`, the routes in
`bench/sql_server.zig` at `3ca49e4` plus this commit, pool 64. `wrk -t1
-c1 -d4s`, two rounds each; the first block is the committed tree.

| route | what it leaves out | c=1 avg | against `/health` |
|---|---|---:|---:|
| `/health` | everything | 92 µs | — |
| `/async-db-ids?…&limit=50` | eight columns a row; one `i32` decoded, nothing written | 692 / 730 µs | +620 µs |
| `/async-db-notags?…&limit=50` | the `jsonb` column | 792 / 789 µs | +700 µs |
| `/async-db?…&limit=50` | nothing: the arena's handler | 880 / 880 µs | +788 µs |
| `/async-db?…&limit=5` | forty-five rows | 676 / 663 µs | +580 µs |

Postgres's own log (`log_min_duration_statement = 0`) puts its side of a
`limit=50` query at **bind 0.11 ms + execute 0.15–0.28 ms**, after the one
`parse` that ADR 051's statement cache makes. The bind is the part worth a
sentence: it is 0.11 ms on the thirty-sixth execution as on the sixth,
because `LIMIT $3` as a parameter is a plan Postgres cannot make generic —
the generic plan's cost assumes ten per cent of the rows, the custom plan
knows it is fifty — so it plans every call, and a third of the database's
time on this query is planning. The arena's five request files use five
limits; a handler that switched on them and passed each as a comptime
`.limit` would prepare five statements with the limit inlined and drop the
bind to a few microseconds. That is the entry's business rather than the
module's, and it is the same for every framework that binds the limit.

**What the rows cost nilo itself**, from `bench/paced.py` at 500 req/s over
16 connections — CPU per request, with the context switches beside it:

| route | CPU/req | switches/req | faults/req |
|---|---:|---:|---:|
| `/health` | 68 µs | 1.02 | 0 |
| `/async-db-ids` | 168 µs | 3.01 | 0 |
| `/async-db-notags` | 228 µs | 3.00 | 2 |
| `/async-db` | 284 µs | 3.01 | 5 |

So the round trip is +100 µs of CPU and two more context switches a
request; fifty rows of eight columns are +60 µs; fifty `jsonb` parses are
+56 µs — `std.json` into the arena at about a microsecond a row, plus the
arena's pages for it. **Decoding is 116 µs of the 284, and none of it is
the 3.9 ms.** At the arena's 66k req/s the whole 284 µs is 19 cores of 64;
the run reported 8.7. The server was waiting.

### What the two-core box cannot settle, and what it could

The wait is either Postgres or the pool, and the pool is one `xsync.Mutex`
and one `Condition` in pg.zig's `Pool.acquire`/`release` that every one of
1,024 fibers on 64 threads takes twice a request — a three-state futex
mutex whose every contended unlock is a cross-thread wake. Whether that
convoys at 64 threads is the question, and two threads cannot ask it. What
two threads could ask was whether the lock is slow *at all*, with a scratch
program — 1,024 fibers over a pool of 256 tokens on zio, `acquire`, one
`yield` for the round trip, `release`, the same `xsync` types pg.zig uses,
500 rounds each:

| threads | fibers / pool | stealing | acquire+release a second |
|---:|---|---|---:|
| 1 | 256 / 64 | on | 2,607,718 |
| 2 | 256 / 64 | on | 1,549,453 / 1,622,219 |
| 2 | 256 / 64 | **off** | 5,998,587 / 4,706,664 |
| 2 | 1,024 / 256 | on | 1,518,590 / 1,577,411 / 1,569,130 |
| 2 | 1,024 / 256 | **off** | 6,262,277 / 6,446,833 / 5,314,706 |
| 2 | 64 / 64, no wait ever | on | 9,157,313 |

Not slow: 1.5M handoffs a second with stealing on, and the arena needs 66k.
**But four times faster with stealing off**, three of three, which is the
scheduler churning the very wakes the pool makes — a `yield` or a
`Condition.signal` puts a task on a ring, a searcher steals it, its next
wait hands it back. ADR 199 turned stealing off for the reason `http.md`
gives, and this is a second reason from a second instrument. The arena run
that produced the 66k had it on.

**What would settle it:** the same three routes on a box with eight cores
or more, `wrk -c1024` against pool 256, Postgres on `--network host`; then
the same with `POOL_SIZE=32`, because `§6` says past the database's core
count a bigger pool buys queueing rather than concurrency, and the arena's
256 is eight times what this table found best. If the per-query latency
under load is Postgres's, the rank is the database's; if it is nilo's, the
pool is the next thing to read, and the shape is one lane of connections
per executor with a local wait queue — a connection that never crosses a
thread, which is what ADR 199 already made of a request.


## Reproducing this

```bash
docker compose -f sql/docker-compose.yml up -d

# per-operation, both sides of the subtraction
zig build bench-sql -Doptimize=ReleaseFast
PREPARED=0 zig build bench-sql -Doptimize=ReleaseFast

# The SQLite half of that same program needs nothing at all — no Docker, no
# DATABASE_URL. Leave the variable unset and the Postgres half says it was
# skipped; the SQLite half still runs. See §9.5 before quoting its output.

# the server, then wrk at it from the same box
zig build bench-sql-server -Doptimize=ReleaseFast
POOL_SIZE=32 ./zig-out/bin/nilo-bench-sql-server &
wrk -t4 -c64 -d15s --latency http://127.0.0.1:8080/people/1
```

`POOL_SIZE` and `PREPARED=0` are the two knobs. `/health`, `/fixed/:id`,
`/deep/:id` and `/people/:id` are the four routes, and they exist so that every
number above has the next one standing beside it.

**Do not kill the server with `pkill -f nilo-bench-sql-server`.** The pattern
matches the invoking shell's own command line and kills the shell — it silently
discarded an edit and voided a whole pool sweep in this cycle. Keep the `$!`
PID.

For §8, which needs four toolchains and the fixture:

```bash
cd bench/compare-sql
psql "$DATABASE_URL" -f fixture.sql        # five tables, deterministic timestamps

cd zigsql && zig build -Doptimize=ReleaseFast && cd ..
cd go && go build -o go-ops ops.go && cd ..
cd rust && cargo build --release && cd ..
cd node && npm install && npx prisma generate --schema schema.prisma && cd ..

TRANSPORT=unix PASSES=3 python3 ops.py     # the sweep, round-robin
python3 summarise.py                       # wall clock and paired, per shape
python3 stability.py                       # do the passes agree on the sign?
python3 compare_runs.py old.json new.json  # do two runs agree?
python3 census.py                          # syscalls per prepared round trip
```

**Run the sweep twice and keep both files.** One run cannot tell you whether a
difference is resolvable — that is what `compare_runs.py` is for, and it is the
check §8 exists because of. Ask any other session on the machine to stay off the
cores first; a peer's `cargo build --release` with LTO inside the window is worth
30% of the wall clock and an unknown amount of the numbers.

For §11, the port lives in nodeflux-os rather than here, and the reference is
the database its Go binary migrates:

```bash
cd nodeflux-os/backend-zig
zig build db -- check                              # Rows, migrations and twins agree? no database
zig build db -- generate --name schema --baseline  # re-derive version 1 from the Rows
zig build                                          # the twin needs the compiled version file
zig build db -- generate --name schema             # writes the .sql twin
DATABASE_URL=postgres://…/fresh ./zig-out/bin/db migrate
psql -v ON_ERROR_STOP=1 -d fresh_by_psql -f migrations/0001_schema.sql
DATABASE_URL=postgres://…/fresh_by_psql ./zig-out/bin/db verify
```

Then `pg_dump --schema-only -n public` of the reference and of each fresh
database, split into one line per column, constraint, index, trigger and view,
and diffed as sets. Two spellings are the same fact and are normalised before
the diff: `ADD CONSTRAINT … UNIQUE` against `CREATE UNIQUE INDEX`, and
`DEFAULT '1'::numeric` against `DEFAULT 1`. Nothing else is. Call the binary
rather than `zig build db --` when the exit code matters; the build runner
reports a refusal as `failed command` with the sentence above it.

## Is this as fast as it gets?

No, and the remaining levers are worth ranking honestly, because the biggest
one is not code.

**1. The transport, +133%, available today.** §3. A unix socket to a
co-located Postgres nearly doubles what the bridge does, and it is a
connection string rather than a change to nilo. This is the advice, and it is
now in `docs/guide/sql.md`. Anybody benchmarking nilo through a published
Docker port is measuring iptables.

**2. One wasted round trip in pg.zig, ~2.6 µs, upstream but small.** This lever
was written as "pipelining, unavailable" and §8 splits it in two. Pipelining
proper is still unavailable and [ADR
053](../../docs/adr/053-a-round-trip-is-not-the-cost-worth-chasing.md) was
right to refuse it: the round trip is mostly kernel, and only pipelining
amortises it. But **half of what pg.zig spends is not the round trip being
expensive, it is pg.zig taking two where pgx and tokio-postgres take one.**
`conn.zig:243` writes a standalone `Sync` on the prepared-statement cache-hit
path and waits for `ReadyForQuery` before it sends Bind and Execute. Coalescing
those is a small, local change rather than a protocol rewrite — and it is the
whole of nilo's single-row deficit against Rust in §8. Still upstream work, but
of a completely different size from pipelining. **Taken since**: upstream
removed it in `2c7c6ca`, nilo pins it, and §16 has the numbers.

**3. Releasing a fiber's stack, blocked on zio.** §7 says an ordinary database
route holds 17 kB an idle connection and most of it is stack that will never be
used again. `waitOrRelease` in `http/app.zig` already hands read and write
buffers back with `MADV_DONTNEED` when a connection goes quiet, and the stack
belongs beside them at no extra cost. What blocks it is one number zio does not
expose — the low end of the running fiber's stack. Guessing is not an option:
zio carves 64 stacks from one slab, so an `madvise` a page past the limit would
silently zero another connection's live stack. ADR 062 has it in those terms.

**4. `result_state_size`, small and free.** pg.zig allocates result state for
32 columns per connection whether a query has 32 or 2. `nilo_sql` knows the
column count while compiling — every statement is a comptime constant — so it
could size that from the Row rather than take the default. It is a few hundred
bytes a connection, which is nothing next to §7's stack, and it is the kind of
thing that is only cheap to do while somebody is already in the file.

**5. `arena_keep`, measured and left alone.** The sweep in §7 found it buys
nothing on this workload. It is not tuned on one measurement, but it is no
longer a number anybody should defend.

What is *not* on this list is the ORM. §1 puts the typed layer at ~100 ns on a
27 µs operation and §5 puts nilo at a third of the busy cores while the
database and the load generator take the rest. **The thing to make faster next
is the socket, and after that it is somebody else's repository.**

## 13. What naming a connection's holder costs a statement

**Run:** `zig build bench-sql`, the `db.find through the whole module` row with `.prepared = true`, SQLite in a file under `/tmp`, in-process with no socket. Before is `git archive HEAD` at `ae1cb61`; after is the working tree. Three pairs, interleaved, best of five each. AMD Ryzen 7 9700X, 16 threads, Linux 7.2, Zig 0.16.0, 2026-09-23.

**Why:** the line a SQLite statement writes when it gives up on a connection now names the statement holding it (ADR 107). The first version also stored when the connection was taken, so the line could say for how long.

| | pair 1 | pair 2 | pair 3 |
|---|---|---|---|
| before | 708 ns | 710 ns | 718 ns |
| after, text and a clock read per take | 750 ns | 742 ns | 743 ns |
| before (second set) | 709 ns | 712 ns | 715 ns |
| after, text only | 722 ns | 710 ns | 705 ns |

**What it changed:** the clock read was 4.5%, every pair the same way, on the path every statement takes. The text alone is a pointer store under a lock already held, and its margin changes sign between pairs, so it is "unchanged". The timestamp was dropped: the waiter's own `timeout_ms` already bounds how long the holder has had the connection, and a one-line statement named as the holder after that long says enough.

**Can it be pushed further:** there is nothing left to take out. The statement text was already in hand and the lock already taken.

## 14. A Row with a parent, children or a sum costs a program without one nothing

**What it answers.** ADR 218 let a Row carry a parent, children and aggregates, and to read them it replaced the loop that fills a flat Row with `readRow`, which walks the fields by kind. That loop is on every read any program makes, so the question is whether a program that declares no such Row pays for the generalisation.

**How.** `git archive HEAD | tar -x` at `3713789` into a scratch directory, `zig build size-sql -Dtarget=x86_64-linux-gnu` on both sides, stripped `ReleaseFast`. `bench-sql-server`, a whole server reading Postgres per request, was built the same way as a second reading.

| | before | after | Δ |
|---|---|---|---|
| names `sql.Db` (Postgres) | 1,875,080 | 1,875,160 | +80 |
| names `sql.Sqlite` | 2,297,144 | 2,296,792 | −352 |
| `bench-sql-server` | 1,884,024 | 1,883,864 | −160 |

**What it changed.** Nothing to decide: the three move in both directions by less than a cache line's worth of instructions each, and `cmp` says they differ, so this is code laid out differently rather than code added. The statements themselves are comptime constants either way. It is the number ADR 218 quotes for its binary-size axis.

**Can it be pushed further:** not by anything worth doing. The difference is where one `catch` sits: the flat loop caught each column's error, `readRow` returns it and the row is caught once.

## 15. A statement under `.hop` with a thread of its own

**Run:** a scratch server on `sql.Sqlite(.{ .threading = .{ .hop = nilo } })`, pool `size = 4` (a writer and three readers) over a file of 1,000 rows, with `/read/:id` (a `find`), `/write` (an `insert`), `/slowlong` (a four-way cross join of the table that starts with `SELECT`, so it runs on a reader, about 30 s under load) and `/health`. Built ReleaseFast for `x86_64-linux-gnu` against `git archive` of `1343509` (before, `nilo.blocking`) and of it plus the change (after, `nilo.blockingReserved`), each with its own cache and a fresh database file per start. Server on CPUs 0–3,8–11, eight threads; gcannon `11c802b` on 4–7,12–15. AMD Ryzen 7 9700X, Linux 7.2.5, 2026-09-25.

**Why:** zio's pool adds a worker only when none is idle and twice as many jobs wait as run, so a statement that has taken its connection can queue for a thread behind slow ones and hold the connection the whole time ([zio#745](https://github.com/lalinsky/zio/issues/745), ADR 107's `/healthz` report).

**The case**, two rounds, the order reversed in the second: three `/slowlong` at once, one on each reader, then 300 ms later five `/write` at once.

| | before | after |
|---|---|---|
| the five writes | **four 500s at 10.0 s** (the writer's `timeout_ms`), one 200 at 30.7–30.9 s | **five 200s at 0.40–0.83 ms** |
| the three slow reads | 31 s, and one at 57.6–58.7 s: it queued behind the other two | 29.1–31.3 s each |
| threads two seconds in | 11 | 13 |

The first write took the writer and waited for a thread until a slow read finished; the four behind it waited for the writer and gave up.

**The cost when nothing is slow**, three interleaved rounds, 512 keep-alive connections, `-t 8`, five seconds a path:

| | before | after |
|---|---|---|
| `/read/1` | 29.4–35.7K req/s, p99 67.5–81.3 ms, 155–192 µs CPU a request | 29.5–35.7K, p99 67.2–81.0 ms, 156–192 µs |
| `/write` | 16.0–16.1K req/s, p99 172–176 ms, 335–338 µs | 16.0–16.2K, p99 172–175 ms, 328–340 µs |
| threads after the writes | 15 | 16–17 |
| RSS after the writes | 21,632–21,780 kB | 22,592–22,632 kB |

`/read/1` reads either about 29.4K or 35.7K on both sides, whichever round, so the spread is the machine's and not the change's. No request failed on either side.

**What it changed:** every statement under `.hop` goes through `nilo.blockingReserved` (ADR 064). Throughput, p99 and CPU a request are unchanged; the price is one or two more pool threads under load and about 1 MB of RSS with them, bounded by the Gate in front of the connections, and gone after the pool's 60 s idle timeout. The binary is the same to the byte.

**Can it be pushed further:** the extra threads are the mechanism, not overhead to trim. What is left is the case the test cannot see: a pool whose Gate is larger than the machine wants threads, which is a pool size nobody should pick.

## 16. The round trip pg.zig wasted, taken back

**Run:** `git archive` of `9a031a1` twice. One side on the pin of the time, `lalinsky/pg.zig@ec8cf27`. The other on `ec8cf27` plus karlseguin's `2c7c6ca` ("Remove unnecessary sync when executing a cached prepared statement"), which cherry-picks cleanly. Postgres 18 (`postgres:18`, `--network host`, `synchronous_commit = off`) over its unix socket. AMD Ryzen 7 9700X, Linux 7.2.5, 2026-09-25. `bench-sql` ran four interleaved pairs; `compare-sql/ops.py` ran two runs of three passes for the Zig arms and one for Go and Rust, with every checksum agreeing.

**Why:** §8 found that on a cache hit, pg.zig writes a standalone `Sync` and waits for `ReadyForQuery` before Bind and Execute. That is two round trips where pgx and tokio-postgres take one, and it was the whole of the single-row gap to Rust.

**`bench-sql`**, the prepared arm, best of five, ns a query. The unprepared arm is the control: the change does not touch it, and it did not move (9,741–10,742 before against 9,666–10,587 after on `SELECT 1`).

| | before | after |
|---|---|---|
| `SELECT 1` | 7,721–8,012 | 4,904–5,061 |
| a key lookup | 8,899–9,333 | 6,102–6,700 |
| `db.find` through the module | 8,977–9,289 | 6,063–6,572 |

**`compare-sql`**, raw drivers only, median ns an operation, the two Zig runs side by side:

| | pg.zig before | pg.zig after | pgx | tokio-postgres |
|---|---:|---:|---:|---:|
| `SELECT 1` | 7,614 / 7,608 | 4,914 / 4,684 | 5,092 | **4,669** |
| 1 row × 4 | 9,242 / 9,310 | 6,545 / 6,500 | 7,254 | **6,005** |
| 20 rows × 4 | 83,740 / 83,832 | **81,224** / 81,554 | 84,895 | 85,238 |
| 1000 rows × 4 | 94,376 / 95,482 | **92,094** / 92,646 | 108,998 | 139,916 |
| 1 row × 20 | 11,008 / 11,014 | 7,916 / **7,846** | 9,462 | 7,842 |
| 1000 rows × 20 | 396,493 / 383,401 | 387,118 / **383,815** | 396,915 | 507,677 |
| insert | 10,654 / 10,636 | **8,579** / 8,682 | 10,740 | 9,466 |
| 100 in one statement | 123,738 / 127,344 | 127,154 / 128,554 | 146,269 | 138,642 |
| update | 13,054 / 13,264 | 10,096 / **9,954** | 11,344 | 10,326 |
| delete | 9,940 / 9,810 | **7,910** / 7,962 | 9,856 | 8,586 |
| transaction | 30,200 / 30,256 | 24,962 / 24,872 | 27,078 | **24,342** |

Every shape that goes through a cached statement lost 2.1 to 3.1 µs, one unix-socket round trip, and both runs agree. The batch did not move beyond its own spread. `nilo_sql` against raw pg.zig is still unmeasurable by §8's rule: `stability.py` finds the sign changing between passes on every shape it flags.

**What it changed:** pg.zig went from 24–63% behind tokio-postgres on a single row to fastest on seven of eleven shapes. It is ahead of pgx on all eleven, and 1–9% behind tokio-postgres on four single-row shapes. nilo pins `nevindra/pg.zig@0a8dab4`, which is `ec8cf27` plus this commit and `2907296` (startup_parameters), until [lalinsky/pg.zig#13](https://github.com/lalinsky/pg.zig/pull/13) is merged. `test-all` passed on that pin against a live Postgres.

**Two harness faults turned up on the way.** `bench/sql.zig` released its one connection twice, so every `bench-sql` since `987764b` ended in SEGV inside `Pool.deinit`, after its numbers had printed. `compare-sql/zigsql` no longer built, because it never passed `.sql = true` (ADR 066). Its pin had also drifted to `a2c9887` while the root's was `ec8cf27`, so its control was on a different driver. All three are fixed.

**Since:** both commits reached `lalinsky/pg.zig`'s `master` under the same hashes, and nilo pins `lalinsky/pg.zig@2bc3405` (2026-10-01), no longer the fork. The figures above were measured on `0a8dab4` and not re-run on the new pin, which also carries lalinsky's later commits (`d24a0fa`, `2bc3405`); `test-all` and `test-sql` against Postgres 17 pass on it.

**Can it be pushed further:** what is left against tokio-postgres is under 10% and is CPU, not packets. The next thing to measure is the pool behind many threads (§12), not the single query.

## 17. What holding a raw statement against its Row costs the binary

**Run:** `git archive` of `20478da` against the working tree of [ADR 233](../../docs/adr/233-a-raw-statement-is-held-against-its-row-the-first-time-it-runs.md), both built with `zig build size-sql -Doptimize=ReleaseFast -Dsql -j1`, stripped. Three programs added to both trees for the run and not kept: `pg_raw` and `sqlite_raw`, `pg_only.zig` and `sqlite_only.zig` with the route's `db.find` replaced by one `db.raw` of a `LEFT JOIN`, and `pg_raw2`, `pg_raw` with a second route and a second raw statement. Intel Xeon Platinum 8255C, 2 vCPU, Linux 6.8, Zig 0.16.0, 2026-09-26.

**Why:** the check is reachable from every raw call and runs behind a runtime flag, so the linker keeps all of it; ADR 017 asks for the number.

| | before | after | Δ |
|---|---:|---:|---:|
| `pg_only` (no raw statement) | 1,916,144 | 1,916,144 | +0 |
| `sqlite_only` (no raw statement) | 2,327,560 | 2,327,560 | +0 |
| `pg_raw`, first version (`std.json.Value`) | 1,917,536 | 2,006,032 | +88,496 |
| `pg_raw`, a reader of its own | 1,917,536 | 1,952,720 | +35,184 |
| `pg_raw`, the once-only half out of the generic call | 1,917,536 | 1,948,400 | **+30,864** |
| `sqlite_raw` | 2,326,712 | 2,337,528 | **+10,816** |
| `pg_raw2` − `pg_raw`, what a second statement costs | 7,296 | 7,664 | +368 |

**What it changed:** `std.json` went. Reading four string keys off a plan does not need a hash map per object or a float parser, and the unstripped symbol table put the new code at about 20 KB by name (the plan reader 13 KB, `outerNulls` 2.7 KB, `typeNames` 1.9 KB), the rest inlined into the call. Moving the half that runs once into a `noinline`, non-generic function is what keeps a second statement at +368.

**Can it be pushed further:** yes, by a few KB. The plan reader builds a tree and walks it; a reader that answered the question in one pass over the text would drop the tree and the two lists. Not done, because what is left is paid once per program and not per statement.

## 18. The count a page reads, keyset paging, and a stream let go early

**Run:** `462d84d`, while auditing `nilo_sql` for defects. Postgres 18.6 (`sql/docker-compose.yml`, the TimescaleDB image) over its Docker port on loopback, defaults throughout. AMD Ryzen 7 9700X, Linux 7.2.5, Zig 0.16.0, 2026-09-27. The plans and timings are `EXPLAIN (ANALYZE, BUFFERS)` from `psql` over tables built for the run and not kept; the stream figure is a probe test through `db.stream`, in Debug and ReleaseSafe.

**Why:** [ADR 150](../../docs/adr/150-a-page-knows-what-it-left-out.md) says a page's total is counted during the same scan, and the guide's keyset section offers an `.any` of `<` and `= … AND <` as the way past a deep `OFFSET`. Neither had a plan read under it.

| What | Table | Reading |
|---|---|---|
| `db.page`'s statement, `count(*) OVER ()`, index on the order column | 1,000,000 rows | 124 ms |
| the same page without the window | 1,000,000 rows | 0.024 ms |
| `db.page` with a condition narrowing the match | 1,000,000 rows | 42 ms |
| `OFFSET 900000` | 1,000,000 rows | 62 ms |
| the guide's keyset condition, index on `(created_at, id)`, cursor half way | 200,000 rows | 7.9 ms, `Rows Removed by Filter: 100001` |
| the guide's keyset condition, generic plan | 1,000,000 rows | 17.8 ms |
| a row comparison, `(created_at, id) < ($1, $2)` | 1,000,000 rows | 0.013 ms, 4 buffers, `Index Cond: ROW(created_at, id) < ROW($1, $2)` |
| a stream given back after 1 of 2,000,000 rows of 200 bytes | `generate_series` | 295 ms Debug, 327 ms ReleaseSafe |

`starts_with` and `istarts_with` were read the same way: SQLite plans `SCAN` over a table with a `NOCASE` index on the column, because the pattern is built inside the statement by `replace(…) || '%'` and SQLite's LIKE optimisation wants a constant; Postgres uses a `text_pattern_ops` index on a custom plan and scans 200,000 rows once the statement goes generic.

**What it changed:** four entries under `nilo_sql` in the [todo list](../../docs/todo.md). The window is read once, as ADR 150 says, but computed over every row that matches before the limit applies, so a page costs its whole match. The guide's keyset condition filters rather than seeks, and costs what the `OFFSET` it replaces does. A stream let go early reads the rest of its result off the socket while holding the connection.

**Can it be pushed further:** each is a shape rather than a tuning. A page with no total, a row comparison the index can seek on, and a stream that cancels or reads in batches are the three; the pattern bound whole from Zig costs an allocation a condition, which wants its own number against ADR 017 before it is taken.

## 19. The key a cut order ends in

**Run:** `462d84d` plus the working tree of the change that appends the key, 2026-09-28. Postgres 18.6 (`nilo-test-pg`, `postgres:18`) over its Docker port on loopback, defaults throughout. AMD Ryzen 7 9700X, Linux 7.2.5. `EXPLAIN (ANALYZE, FORMAT JSON, TIMING OFF)` from `psql`, the four statements interleaved for seven rounds, then the fifth for seven after its index was made. The table is 1,000,000 rows, `status` holding 10 values (100,000 rows each) and `created_at` 1,000 (1,000 rows each), with an index on each column alone.

**Why:** a page whose order ties repeats rows and skips others, because Postgres may order the ties differently at each `OFFSET`. The fix is the table's key after any cut order that does not name it ([ADR 150](../../docs/adr/150-a-page-knows-what-it-left-out.md#a-page-ends-in-the-key)), and that is a sort key the index on the order column does not cover.

| `LIMIT 25 OFFSET 500` ordered by | Index | Execution, seven runs |
|---|---|---|
| `status` | `(status)` | 0.068 to 0.091 ms |
| `status, id` | `(status)` | 6.6 to 14.4 ms, an incremental sort over the whole first group |
| `created_at DESC` | `(created_at)` | 1.1 to 1.3 ms |
| `created_at DESC, id` | `(created_at)` | 2.2 to 9.7 ms, 2.4 typical |
| `status, id` | `(status, id)` | 0.085 to 0.13 ms, one run at 3.0 |

**What it changed:** the key goes on anyway, because the statement without it answers a wrong list and the cost is the size of the tie group the page lands in: a hundredfold on an order by a ten-value column with 100,000 rows each, about double on a date with 1,000 rows each. The guide and the reference say that an index serving a paged order should end in the key, which puts it back where it was.

**Can it be pushed further:** by the caller, with the index above. Leaving the key off an order that is unique already is the other half, and nilo cannot see that today: `.unique` columns may be NULL, so only the key counts.

## 20. What a stream let go early costs to give back

**Run:** `91c34a0` plus the working tree of the change that bounds the drain, 2026-09-29. Postgres 17.10 (`timescale/timescaledb-ha:pg17`) over its Docker port on loopback, SCRAM-SHA-256 at 4,096 iterations, defaults otherwise. Intel Xeon Platinum 8255C, 2 vCPU, Linux 6.8.0, Zig 0.16.0. The live test "a stream let go early keeps its connection…" in a ReleaseSafe build forced onto LLVM, with timers around `rows.close()` and inside the drain, run on its own with the budget read from an environment variable, three budgets interleaved for two rounds of six closes each. The table is 200,000 rows of 200 bytes, and each close follows the first row, leaving 43,599,796 bytes of the result.

**Why:** §18 found a stream given back after its first row reads the whole rest first. The bound replaces the connection past a budget, and the budget is worth what a connect costs against what a read does.

| Budget | Read before giving up | Dial of the replacement | `rows.close()` |
|---|---|---|---|
| none, as before | 178 to 313 ms, all 43.6 MB | none | 178 to 313 ms |
| 1 MiB | 4.3 to 7.0 ms | 16 to 27 ms | 21 to 34 ms |
| 2 MiB | 8.8 to 18 ms | 17 to 54 ms | 26 to 72 ms |

A raw SCRAM connect from Python over the same port, with and without `TCP_NODELAY`, took 8.2 to 17 ms, so pg.zig's dial is within a few milliseconds of the protocol's own.

**Measured through a test binary, a connect is ten times what it costs.** The same dial timed inside `zig build test-sql` read 115 to 360 ms, and the ReleaseSafe binary was slower than the Debug one. Test builds here use the self-hosted backend (ADR 138), which leaves SCRAM's PBKDF2 unoptimised: 113 ms in Debug against 5.5 ms in ReleaseSafe on LLVM, timed alone. Run beside the Debug binary on two cores, the LLVM build's dial read 36 to 46 ms. The table above is the LLVM binary run by itself.

**What it changed:** [ADR 238](../../docs/adr/238-a-stream-let-go-early-reads-a-megabyte-of-what-is-left.md). `drain_budget` is 1 MiB: a rest past it costs at most one connect more than reading it would have, and a 42 MB rest costs a tenth of what it did. 2 MiB reads twice as much on every long rest to save a connect on a rest between the two.

**Can it be pushed further:** by a CancelRequest, which keeps the connection and needs the key pg.zig does not keep, or by a portal read in batches. Both are in the ADR's rejected list with what would reopen them. §18's 295 and 327 ms were taken through test binaries as well, so they are about the build as much as the drain.

## 21. Where a prefix pattern is built

**Run:** `eddc05d`, 2026-09-29. Intel Xeon Platinum 8255C, two vCPUs. Postgres 17.10 (`timescale/timescaledb-ha:pg17`) through `psql` inside its container; SQLite 3.45.1 through Python's `sqlite3`, in memory. Both tables 200,000 rows of `md5(n) || '@x.dev'`, analysed, the prefix `abc1` matching 4.

**Why:** §18 found `istarts_with` a `SCAN` on SQLite and a sequential scan on a generic Postgres plan, and the roadmap priced the fix, binding the pattern whole, at an allocation a condition. The question was which database the allocation buys anything on.

| Database, index | Pattern | Plan | Per query |
|---|---|---|---|
| SQLite, `email COLLATE NOCASE` | `LIKE replace(replace(replace(?1 …))) \|\| '%' ESCAPE '\'`, as nilo wrote it | `SCAN t` | 16.5 ms |
| SQLite, `email COLLATE NOCASE` | `LIKE ?1 ESCAPE '\'`, bound `abc1%` | `SEARCH t USING COVERING INDEX t_nocase (email>? AND email<?)` | 0.012 ms |
| Postgres, `text_pattern_ops`, prepared, eight runs | built in the statement | Index Scan, `email ~>=~ 'abc1' AND email ~<~ 'abc2'`; 8 custom plans, 0 generic | 0.021 ms |
| the same | bound whole | the same plan; 8 custom, 0 generic | 0.015 ms |
| the same, `plan_cache_mode = force_generic_plan` | either | Parallel Seq Scan | |

The two Postgres timings are one `EXPLAIN ANALYZE` each and inside each other's noise; the plan is the finding.

**Corrected by [§23](#23-istarts_with-on-postgres-and-the-expression-it-reads):** the Postgres rows were read over an index on the bare column, which the marker cannot make and a case-folding unique is not. `istarts_with` is `ILIKE`, and §23 reads it as a `Seq Scan` over that index too, on 17.10 (Ubuntu build), so the "uses a `text_pattern_ops` index" finding does not hold for the statement nilo wrote.

**What it changed:** [ADR 140](../../docs/adr/140-the-database-escapes-the-pattern-it-is-going-to-match.md), in place. On SQLite a non-negated `istarts_with` binds the escaped pattern, one arena allocation, and is `SEARCH` over a unique that ignores case. Postgres keeps the form that allocates nothing: it plans for the value every time here, folds the expression, and uses the index; §18's scan was a forced generic plan, where binding it whole scans as well.

**Can it be pushed further:** on SQLite, only with an index that folds case on a column with no unique over it, which the marker cannot yet write. On a Postgres plan made for any value, not with a `LIKE`: a byte range beside it would seek, and is wrong under a collation that does not order by bytes.

## 22. A guard and the plan a kept statement settles on

**Run:** `911001c` plus the working tree of the change that sends a guarded statement unnamed, 2026-09-30. Intel Xeon Platinum 8255C, 2 vCPUs, Linux 6.8.0. Postgres 17.10 (Ubuntu build, `nodeflux-os-db-1`, defaults) through `psql` 17 inside its container; SQLite 3.45.1 through Python's `sqlite3`, in memory. Both tables 500,000 rows, `cust` holding 1,000 values (500 rows each), an index on `cust`, analysed. The statement is `db.count`'s: `SELECT count(*) … WHERE (cust = $1 OR $1 IS NULL)`.

**Why:** the roadmap said the guard turns an indexed filter into a full scan on both databases, and [ADR 149](../../docs/adr/149-a-filter-that-is-absent-is-not-a-filter-that-is-null.md) said the plan that would do it is the one the cost comparison rejects. Both cannot be true.

| Database | How the statement runs | Call that sets `cust = 'c5'` | Plan |
|---|---|---|---|
| Postgres, `PREPARE`d (nilo's default) | after six calls with `NULL` | 115 ms | `Parallel Seq Scan`, `Filter: ((cust = $1) OR ($1 IS NULL))`, `Rows Removed by Filter: 249750`; `pg_prepared_statements` says 2 generic, 5 custom |
| Postgres, `PREPARE`d | after six calls with `'c5'` | 0.5 ms | `Bitmap Index Scan` on `cust`; 0, then 7 custom |
| Postgres, the guard with `'c5'` written in as a literal | | 0.27 ms | `Index Only Scan`, `Index Cond: (cust = 'c5')` |
| Postgres, unnamed (`\bind`), after seven other values | | 0.099 ms | `Index Only Scan`, `Index Cond: (cust = 'c5'::text)`, planning 0.05 ms |
| Postgres, the guard with `NULL` written in | | 60 ms | `Parallel Seq Scan`, no `Filter`: every row is the answer, so the scan is the right plan |
| SQLite, the guard | `?1 = 'c5'` | 29.4 ms per query, 20 runs | `SCAN t` |
| SQLite, the term alone | | 0.044 ms per query, 20 runs | `SEARCH t USING COVERING INDEX t_cust (cust=?)` |

The Postgres switch is the cost comparison working as designed and being wrong for this shape: the six calls without the filter make the average custom plan a scan's cost, the generic plan is the same scan, and it wins. An unnamed statement is planned at `Bind` for that call's values, so it is always the custom plan.

**What it changed:** [ADR 149](../../docs/adr/149-a-filter-that-is-absent-is-not-a-filter-that-is-null.md), in place. On Postgres a statement holding a `sql.given` is sent unnamed (`Dialect.plan_may_go_generic`), which costs the Parse and Describe a named statement skips (ADR 051's 12 µs, not measured again here) and buys the 0.1 ms plan. `plan_cache_mode = force_custom_plan` was rejected because it is the connection's, so it also takes the generic plan from the key lookups that gain from it. SQLite keeps the guard and the `SCAN`, and the ADR and the reference say so: a statement is planned once, before a value is bound, so preparing it again plans it the same way, and the cure is a text per combination of filters, which ADR 149 refused for binary size.

**Can it be pushed further:** on SQLite, only with the text changed: the term left out when the filter is absent and written bare when it is present, either 2ᵏ statements or a `WHERE` spliced into the arena the way ADR 165 splices an `ORDER BY`, with the placeholders renumbered. The second was not built; 29 ms against 0.044 ms on 500,000 rows is the number that would ask for it. The unnamed Parse was not timed through nilo's Wire: `psql` shares nothing with pg.zig's round trips.

## 23. `istarts_with` on Postgres and the expression it reads

**Run:** `911001c` plus the working tree of the change, 2026-09-30, on the machine and Postgres of §22 (database collation `C.UTF-8`). One table of 200,000 rows of `md5(n) || '@x.dev'`, analysed, the prefix `abc1` matching 4; the statement is what `dialect.pattern` writes, with the escape inside it.

**Why:** [§21](#21-where-a-prefix-pattern-is-built) found Postgres reading a `text_pattern_ops` index for `istarts_with`, and the roadmap said it never does: the statement is `"email" ILIKE …`, and the case-folding unique nilo builds is over `lower("email")`.

| Statement | Index | Plan | Execution |
|---|---|---|---|
| `email ILIKE replace(…) \|\| '%'`, as written before | `lower(email)` unique | `Seq Scan`, `email ~~* 'abc1%'` | 266 ms |
| `lower(email) LIKE lower(replace(…)) \|\| '%'` | `lower(email)` unique | `Parallel Seq Scan` | 242 ms |
| the same | `lower(email) text_pattern_ops` unique | `Index Scan`, `lower(email) ~>=~ 'abc1' AND lower(email) ~<~ 'abc2'` | 0.065 ms |
| `email ILIKE …` | `lower(email) text_pattern_ops` unique | `Seq Scan` | 277 ms |
| `email ILIKE …` | `email text_pattern_ops` on the bare column | `Seq Scan` | 274 ms |
| `lower(email) = lower('ABC1@x.dev')` | `lower(email) text_pattern_ops` unique | `Index Scan`, `Index Cond: (lower(email) = 'abc1@x.dev')` | 0.019 ms |
| `PREPARE`d lowered form, nine runs | `lower(email) text_pattern_ops` unique | `Index Scan`; 0 generic, 9 custom | 0.038 ms |
| the same, `plan_cache_mode = force_generic_plan` | | `Parallel Seq Scan` | 335 ms |

Inserting `upper(email)` of an existing row into the table still fails on the unique, and `=` on the lowered expression seeks it.

**What it changed:** [ADR 140](../../docs/adr/140-the-database-escapes-the-pattern-it-is-going-to-match.md), in place. A folding, non-negated prefix on Postgres is `lower(col) LIKE lower(escaped) || '%'`, and a case-folding unique there is `lower(col) text_pattern_ops` (`Dialect.foldedIndexColumn`), so one index serves `.ieq` and `istarts_with`. §21's Postgres finding did not reproduce here for `ILIKE` over either index, so it is corrected in place; What plan it read is not known; a case-sensitive `LIKE` would give the one it printed. A unique made before this keeps its old index and scans until it is dropped and made again: the migrator compares `ignoring_case`, not the operator class.

**Can it be pushed further:** not on a plan made for any value, which the last row shows and ADR 149 now keeps a guarded statement away from. A plain `.index` on `lower(col)` cannot be written by the marker, so only a unique serves the prefix.


## 24. The startup check and the ledger ask once

**Run:** `39896d2` plus the working tree of the change, 2026-09-30. Postgres 17.10 in the `nodeflux-os-db-1` container, database `nilo_test`, 50 scratch tables of eight columns each (`id int8` key, `text`, `int4`, `timestamptz`, `bool`, `numeric`, `text`, `int8`), dropped afterwards. The query texts are the ones in `dialect.zig`, taken out of the file by a script and sent through `psql` inside the container (a unix socket), so a round trip here costs almost nothing; SQLite is python's `sqlite3`, in memory, in process. **Not run through nilo**: the change was written under a rule that forbids `zig build`, so the round trips of the tool and of a boot below are counted from the code, and the times are the queries alone.

**Why:** `checkSchema` sent the introspection query once per Row and the enum query once per enum column, on the boot path of every replica; `db status` read the ledger with a `find` per version in the manifest, and `db migrate` made the ledger (a BEGIN, a lock, a CREATE and a COMMIT) three times.

| Ask | Before | After |
|---|---|---|
| Startup check, 50 Rows, none with an enum, Postgres | 50 queries | **1** |
| Startup check, 50 Rows, 5 named enum columns over 3 types, Postgres | 55 queries | **2** |
| The same, SQLite | 50 queries | **1** |
| Postgres, 50 tables, the queries alone, median of 7 interleaved runs | 26.7 ms | **7.7 ms** (`23.4`-`41.4` against `5.9`-`9.0`) |
| SQLite, 50 tables, in process, median of 15 | 5.3 ms | **2.5 ms** |
| `db status`, V versions, Postgres | 5 + V round trips | **5** |
| `db migrate` with nothing to apply, V versions, Postgres | 14 + V | **5** (one `ensureLedger` of four, and one read) |

The Postgres time is the 50 statements' server time and a unix-socket hop each. Over a network the difference is 49 round trips, at 0.5 ms 25 ms and at 2 ms 100 ms, added to the 19 ms above. The batch returned all 400 rows and the ordered lists matched the single query's for every table; a test in `live.zig` holds that, and one in `db.zig` holds the SQLite side (three tables, one spelled in another case, one missing).

**What it changed:** `dialect.introspect_all` per Dialect and `enum_values` taking the type names as an array; `columnsOfMany` and `labelsOfMany` on the Wire; `migrate.readLedger`, `seen` and `applyRecorded`, so the three readers of the ledger share one read and one comparison ([ADR 055](../../docs/adr/055-the-second-dialect-is-the-test-of-the-seam.md), in place). The single-table `introspect` stays for `liveColumns`, `addMissingColumns` and a migration's own transaction.

**Can it be pushed further:** the check still needs one query per schema a Row names. A boot that also runs `ensureLedger` and `expecting` pays those on top, and folding them into one round trip would put the ledger's `CREATE`, which runs inside a transaction holding the advisory lock, and a catalog read on one statement; not attempted.

## 25. A guard cut out of the text per call

**Run:** `39896d2` plus the working tree of the change, 2026-09-30. The machine, Postgres and SQLite of [§22](#22-a-guard-and-the-plan-a-kept-statement-settles-on). SQLite: python's `sqlite3`, in memory, 500,000 rows in `t(id, cust, stage, note)`, `cust` holding 1,000 values and `stage` 7, an index on each, analysed; the statement is `select count(*) from t where …`, 20 runs each. Postgres: `pgbench` 17 inside the container over a unix socket, one client, 5 s a run, three rounds interleaved, on a 500,000-row scratch table (`custn int4` 1,000 values, `stagen int4` 7, both indexed, vacuumed and analysed; dropped afterwards). pgbench substitutes its variables as `$n` parameters under `-M extended` (Parse, Bind and Execute on every call, unnamed) and `-M prepared` (named), which is what nilo sends unnamed and named. **Not run through nilo**: the change was written under a rule that forbids `zig build`, so the text below is what `statement.spliceOf` is written to produce, checked by hand against the guard `where.zig` writes, and the times are the database's.

**Why:** [§22](#22-a-guard-and-the-plan-a-kept-statement-settles-on) left SQLite reading the whole table for a `sql.given`, and Postgres parsing every such statement on every call. The roadmap named the cure, the `WHERE` written per call the way [ADR 165](../../docs/adr/165-an-order-chosen-at-run-time-from-a-closed-set.md) writes an `ORDER BY`, and the price it had to be weighed against, ADR 149's refusal of one statement per combination.

SQLite, two guarded filters (`cust`, `stage`), the guard as written against the text that is sent when a term is absent (`(?2 IS NULL)`) or present (the term alone):

| `cust` | `stage` | The guard `(c = ?1 OR ?1 IS NULL) AND (s = ?2 OR ?2 IS NULL)` | Cut per call | Plan of the cut text |
|---|---|---|---|---|
| set | absent | 69.0 ms | **0.055 ms** | `SEARCH t USING COVERING INDEX t_cust (cust=?)` |
| absent | set | 83.4 ms | **6.6 ms** (71,429 rows counted) | `SEARCH t USING COVERING INDEX t_stage (stage=?)` |
| absent | absent | 55.4 ms | 13.9 ms (every row is the answer) | `SCAN t USING COVERING INDEX t_stage` |
| set | set | 63.2 ms | **1.13 ms** | `SEARCH t USING INDEX t_cust (cust=?)` |

The guard is `SCAN t` in all four. Preparing the cut text on every call, which is what a statement with more than three guards does, cost 57 to 73 µs a call against 52 to 58 µs kept, on a seek of about 55 µs (python's per-call overhead is in both; the difference is between 0 and 20 µs).

Postgres, one term set (`custn = :c`), the other absent:

| How it is sent | Per call, three rounds |
|---|---|
| Today: the guard, unnamed (`-M extended`) | 0.242 to 0.257 ms |
| The bare term, unnamed | 0.232 to 0.287 ms |
| The bare term, **named** (`-M prepared`) | **0.108 to 0.122 ms** |
| The guard, named, as a kept plan would run it | 0.188 to 0.206 ms |
| Two terms, one absent as a literal `NULL`: the guard unnamed, the cut text unnamed, the cut text named | 0.254 to 0.267 ms, 0.241 to 0.248 ms, **0.111 to 0.119 ms** |

A statement with `custn = $1 AND ($2::text IS NULL)` `PREPARE`d and run with `NULL` for `$2`: `Index Only Scan … Index Cond: (custn = $1)` under `Result … One-Time Filter: (($2 IS NULL) AND ($3 IS NULL))`, and after eight runs `pg_prepared_statements` says 3 generic and 5 custom plans, the generic one still the index scan. The parameters are typed `{integer,text,text}`: the `text` is the cast, and a NULL is the same bytes under every type. (An earlier set of pgbench runs taken straight after the columns were added read 1.08 ms for the unnamed guard against 0.39 for the bare term; it was stale statistics and hint bits, discarded, and the table was vacuumed before the numbers above.)

**What it changed:** [ADR 149](../../docs/adr/149-a-filter-that-is-absent-is-not-a-filter-that-is-null.md), in place. `Dialect.splice_given` and `absentTerm`; `statement.spliceOf` finds each guard in the finished text and cuts the statement into pieces while compiling; `db.zig` writes the pieces, one arena allocation, and names the statement per combination up to three guards (`max_named_guards`), so a Db keeps at most 2³ = 8 texts of one call site on each connection and none of a call site with more, which is sent unnamed. On Postgres it replaces the unnamed statement: the named cut text is about **0.13 ms a call faster** than the unnamed guard on the sample, which is Parse and plan together, ten times the 12 µs ADR 051 counted for the Parse alone. On SQLite it is the difference between 69 ms and 0.055 ms on the sample.

**Can it be pushed further:** the two-column case on SQLite where only the low-cardinality filter is set (6.6 ms) is the count of 71,429 rows, not the plan. The unnamed statements past three guards pay the prepare, 0 to 20 µs here; a limit of four would keep 16 texts a call site and save that for a screen with four filters, and nobody has asked. The times are the databases'; a run through nilo's own Wire would add the driver's work to both sides and is owed. The Postgres numbers are over a unix socket, so the hop a network adds, which is paid once either way, is not in them.

## 26. Small costs a read pays

**Run:** `39896d2` plus the working tree of the change, 2026-09-30, on the machine of §25. Postgres 17.10 scratch tables `o` (20,000 rows) and `l` (60,000 rows, `order_id` indexed), dropped afterwards; SQLite figures are counted from the code. **Not run through nilo**, for the reason in §25.

**Why:** the roadmap's entry *A read pays small costs it could skip*.

| Cost | Before | After | How known |
|---|---|---|---|
| A feed with children fetched the children of the row it read past the limit | children statement asked for `limit + 1` parents' children; in the shop fixture (limit 2) it read 3 rows | asks for `limit` parents' and reads **2** | the test `on SQLite, a feed reads the children of the rows it answers with and not of the one past them` counts the rows the second statement read; on Postgres `= ANY` over 21 keys read 61 rows against 20 keys' worth |
| SQLite reset a kept statement and cleared its bindings on release and again on every use | 2 × (`sqlite3_reset`, `sqlite3_clear_bindings`) per use | one pair, and on the way in a `sqlite3_stmt_busy` test | counted from the code; the test asserts a released statement is idle and holds no value |
| `insertMany` and `updateMany` over an empty slice | one round trip: `INSERT … SELECT * FROM unnest('{}', '{}')` 0.039 ms prepared, 0.147 ms unnamed, over a unix socket | none | `pgbench`; the test asserts nothing reaches the Wire |
| A row's text columns each copied with an allocation of their own | k allocations for k plain text columns | **1** for two or more | the test asserts the columns are adjacent in one slab |
| A count over children used in `.where` and in the select list | two `SubPlan`s: `SubPlan 1` `loops=200` in the select list and `SubPlan 2` `loops=327` in the filter, 2.84 ms on `LIMIT 200 … > 2` | **not built.** The same query with the count as a `LEFT JOIN LATERAL` evaluates once, `loops=327`, 0.65 ms | `EXPLAIN (ANALYZE)`, one run each |
| One table reached by a `nilo_through` field and by an aggregate's `FILTER` | joined twice, under `#t/…` and `#f.…` | **not built** | read from `shape.zig` and `table.zig` |

A caller sees the same thing from each of the first four: the feed answers the same rows, the SQLite statement binds the same values, the text columns hold the same bytes, and an empty batch answers the empty slice it answered. The one difference is that an empty batch no longer fails on a Db that cannot reach its database or on a table that is not there.

**What it changed:** the four above; the last two are not built in this pass. **Can it be pushed further:** the lateral count took 527 subplan loops to 327 on this sample (the filter passed 327 of the rows it looked at and the select list needed 200), and the saving is the rows the `LIMIT` keeps. It needs the select list to know the `WHERE`, which `layoutOf` (per Row) does not, and SQLite has no `LATERAL`, so it would be Postgres text only.

## What is still missing

- **A second box.** Everything here shares eight physical cores between nilo,
  Postgres and wrk. §4 shows the generator is not the ceiling, but the box is,
  and the absolutes are all understated by an unknown amount.
- **A tuned Postgres.** Defaults throughout, including `shared_buffers`. The
  workload is a primary-key lookup on a small table so it is served from cache
  either way, but nothing here says what a real schema does.
- **A fixed-rate generator.** wrk's tail is subject to coordinated omission.
  The p99 numbers are comparable to each other and not to a service's SLO.
- **A *concurrent* write workload.** §8 measures insert, batch, update, delete
  and a transaction, so writes are no longer unmeasured — but on one connection.
  Row locks and contention between writers still have correctness tests and no
  benchmark.
- **The comparison behind a pool.** §8 is ten libraries on one connection. §2 is
  the warning that says those figures understate by two to three times what a
  pool sees, and nothing has been run to find out by how much per library.
- **A NIC.** No table here crosses a wire. A deployment where the database is a
  network hop away pays more per query than the worst row in §3.
