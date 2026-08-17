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

Two harnesses produce these figures and they answer different questions:

- **`zig build bench-sql`** (`bench/sql.zig`) — one connection, one statement
  at a time, 20,000 rounds a side after 2,000 warm-up. What an *operation*
  costs.
- **`zig build bench-sql-server`** (`bench/sql_server.zig`) — a server with
  four routes, driven by wrk. What a *service* does with that saving.

The second is the one that matters and the first is the one that explains it.
A per-operation saving measured only unloaded understates what it is worth at
a pool, by two to three times — see [§2](#2-what-that-is-worth-to-a-server).

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

## Reproducing this

```bash
docker compose -f sql/docker-compose.yml up -d

# per-operation, both sides of the subtraction
zig build bench-sql -Doptimize=ReleaseFast
PREPARED=0 zig build bench-sql -Doptimize=ReleaseFast

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

## Is this as fast as it gets?

No, and the remaining levers are worth ranking honestly, because the biggest
one is not code.

**1. The transport, +133%, available today.** §3. A unix socket to a
co-located Postgres nearly doubles what the bridge does, and it is a
connection string rather than a change to nilo. This is the advice, and it is
now in `docs/guide/sql.md`. Anybody benchmarking nilo through a published
Docker port is measuring iptables.

**2. Pipelining, unavailable.** [ADR
0059](../../docs/adr/0059-a-round-trip-is-not-the-cost-worth-chasing.md)
refused chasing the round trip and §5 is why that was right — the round trip is
mostly kernel, and pipelining is the only thing that amortises it. pg.zig sends
one message and waits; changing that is upstream work, not nilo's. If it
arrives, the ~15.7 µs of system time per query is what it eats into.

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
- **A concurrent write workload.** Every table above reads. Row locks,
  transactions and `insertMany` have correctness tests and no benchmark.
- **A NIC.** No table here crosses a wire. A deployment where the database is a
  network hop away pays more per query than the worst row in §3.
