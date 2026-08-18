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
0062](../../docs/adr/0062-a-pool-that-dialled-itself-whatever-it-was-told.md)
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

The first row confirms ADR 0018's 8,767 to within eighteen bytes, which is what
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
0063](../../docs/adr/0063-a-handlers-stack-is-per-connection.md); the guidance
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
text is a constant whatever the batch size (ADR 0053). GORM, Diesel, Drizzle and
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
not an allocation**. ADR 0074's first draft said a connection holds "roughly
2 MB … for the life of the pool" and that is only true of the second row. The
correction is the useful part: a service doing primary-key lookups pays the
first row, and the number a deployment sees is its working set.

Two numbers not to confuse with these: **an idle HTTP connection is unaffected**
(a pool connection is not a request's), and the prepared statements ADR 0057
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

**Re-run after the twenty-findings pass** (ADRs 0075–0084), same machine, same
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
([ADR 0078](../../docs/adr/0078-a-uuid-is-whatever-the-database-stores.md))
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

ADR 0074 was written from SQLite's documentation and said so. Running it held
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
`synchronous` settings because [ADR 0074](../../docs/adr/0074-one-writer-is-not-a-setting-it-is-the-database.md)
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
  ADR 0073 is explicitly waiting for is not even in the harness: `.hop` against
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
0059](../../docs/adr/0059-a-round-trip-is-not-the-cost-worth-chasing.md) was
right to refuse it: the round trip is mostly kernel, and only pipelining
amortises it. But **half of what pg.zig spends is not the round trip being
expensive, it is pg.zig taking two where pgx and tokio-postgres take one.**
`conn.zig:243` writes a standalone `Sync` on the prepared-statement cache-hit
path and waits for `ReadyForQuery` before it sends Bind and Execute. Coalescing
those is a small, local change rather than a protocol rewrite — and it is the
whole of nilo's single-row deficit against Rust in §8. Still upstream work, but
of a completely different size from pipelining.

**3. Releasing a fiber's stack, blocked on zio.** §7 says an ordinary database
route holds 17 kB an idle connection and most of it is stack that will never be
used again. `waitOrRelease` in `http/app.zig` already hands read and write
buffers back with `MADV_DONTNEED` when a connection goes quiet, and the stack
belongs beside them at no extra cost. What blocks it is one number zio does not
expose — the low end of the running fiber's stack. Guessing is not an option:
zio carves 64 stacks from one slab, so an `madvise` a page past the limit would
silently zero another connection's live stack. ADR 0063 has it in those terms.

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
