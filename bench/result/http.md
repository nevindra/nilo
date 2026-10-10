# Benchmarks

The first run of `bench/bench.sh` in anger. The script has been in the repo
since stage 1 and the README has said "not benchmarked on a quiet machine yet"
ever since; this is the baseline that replaces the empty space, and it is
deliberately not a performance claim. **The machine is a developer desktop, not
a quiet box**, and the load generator runs on it too. What follows is written so
the next person can tell how much of each number to trust.

The in-process side of this — what one request costs when nothing else is
running — is [`zig build profile`](#what-a-request-costs-in-process), and it is
the more portable of the two.

How these numbers place against Go, Rust, Node and http.zig, measured the same
way on the same machine, is [`comparison.md`](../../docs/comparison.md).

## The machine

| | |
|---|---|
| CPU | AMD Ryzen 7 9700X — **8 physical cores, 16 threads, SMT on** |
| Memory | 30 GiB |
| OS | Ubuntu 26.04, kernel 7.0.0-29-generic |
| Governor | `powersave`, boost enabled |
| Zig | 0.16.0 |
| Load generator | wrk 4.2.0, built from source; `bench/compare/wsload/` for WebSockets |
| Commit | `a2c344c` for the first tables; **`dcadb46`** for everything in this cycle, against a baseline of `0492be0` |
| Transport | loopback — no NIC, no driver, no wire |

`dcadb46` is the merged tree — the change rebased onto `0492be0` — so the
figures below are from the code that ships rather than from the branch it was
developed on. Where a number was taken on both, both are given.

Two of those rows do most of the damage to how far these numbers travel. **SMT
is on**, which is why the core split below is not the obvious one. And
everything goes over **loopback**, so the kernel's network path is real but the
hardware's is not; a deployment with a NIC in it pays more per request than
anything here. Treat the throughput figures as a ceiling.

## How the cores were split, and why it is not obvious

The first attempt gave the server CPUs 0–7 and the client CPUs 8–15, which reads
like eight cores each. It is not. On this machine:

```
cpu0 core_id=0 siblings=0,8      cpu8  core_id=0 siblings=0,8
cpu1 core_id=1 siblings=1,9      cpu9  core_id=1 siblings=1,9
...
```

CPUs 0–7 are the eight physical cores' first threads and 8–15 are their SMT
siblings, so that split put the server and the load generator on **the same
eight physical cores**, each holding one hardware thread. Every request the
server served was competing with wrk for the same core's execution units.

Splitting by physical core instead — server on `0-3,8-11`, client on
`4-7,12-15`, four whole cores each — the server got **faster on half as many
cores**:

| split | server has | req/s |
|---|---|---|
| server `0-7`, client `8-15` | 8 cores, all shared with the client | 1,143,293 |
| server `0-3,8-11`, client `4-7,12-15` | 4 cores, none shared | **1,314,275** |

That is the first finding and it is about measuring, not about nilo: on an SMT
machine, `taskset -c 0-7` is not eight cores. Everything below uses the second
split, so **the server is on four physical cores.**

## Throughput and latency

The primary metric, as `bench/bench.sh` has stated it since stage 1 and as the
first row of [ADR 017](../../docs/adr/017-the-trade-budget-has-four-axes.md)'s budget
puts it: a routed `GET` with a path param returning ~1 KB of JSON, keep-alive,
no pipelining. The target is `GET /users/:id` in
[`bench/main.zig`](../main.zig), 982 bytes of body, CORS installed, no logger.

Three runs of 30 seconds, `wrk -t4 -c64`, after a discarded 10-second warm-up:

| run | req/s | p50 | p75 | p90 | p99 | server CPU |
|---|---|---|---|---|---|---|
| 1 | 1,314,275 | 35µs | 43µs | 53µs | 107µs | 597% |
| 2 | 1,353,257 | 35µs | 41µs | 52µs | 86µs | 614% |
| 3 | 1,310,724 | 35µs | 42µs | 53µs | 81µs | 598% |

Spread is about 3%. No socket errors, no non-2xx, in any run.

Re-taken two cycles later, 30 seconds each, against a same-machine baseline
built from `0492be0` — the commit this change was rebased onto — so the two are
a measurement against a measurement rather than against a published figure. The
two servers were run **alternately in the same session**, four pairs, so a
machine that drifts drifts under both:

| pair | before (`0492be0`) | after (ADR 062) | after − before |
|---|---|---|---|
| 1 | 1,443,307 req/s, p99 65µs | 1,469,457 req/s, p99 58µs | +1.8% |
| 2 | 1,445,694 req/s, p99 62µs | 1,427,047 req/s, p99 70µs | −1.3% |
| 3 | 1,454,942 req/s, p99 59µs | 1,454,035 req/s, p99 63µs | −0.1% |
| 4 | 1,337,753 req/s, p99 82µs | 1,366,634 req/s, p99 98µs | +2.2% |

Mean 1,420,424 before and 1,429,293 after — **+0.6%, which is less than the
spread of either column.** The honest reading is that HTTP throughput did not
move. The sign changes between pairs, and pair 4 is 8% below pair 3 on *both*
sides, which is what run-to-run noise looks like on a desktop; anything under
about ±2% here is not a result.

An earlier draft of this file read a single 1,485,190 against a single
1,424,878 and called the change "probably a small win", reasoning that one page
of stack instead of two costs fewer TLB entries. The reasoning may still be
right and the measurement never supported it: **one run each is not a
comparison, it is two samples from the same noisy distribution.** The claim is
withdrawn rather than restated more carefully. What the change is *for* is the
memory axis, and that one moved by 47%.

The whole machine is faster than it was for the table above, which is why the
baseline was rebuilt rather than compared against the published 1.31M.

"Server CPU" is `utime+stime` from `/proc/<pid>/stat` over the run, against a
ceiling of 800% — eight hardware threads on four physical cores. At ~600% the
server is **not saturated**, which means 1.31M is where the load generator ran
out, not where nilo did.

### Where it actually saturates

Pushing until the server stops going faster, 20 seconds each:

| wrk | req/s | p50 | p99 | server CPU | CPU per request |
|---|---|---|---|---|---|
| `-t4 -c64` | 1,329,932 | 35µs | 74µs | 604% | 4542ns |
| `-t8 -c64` | 1,861,323 | 30µs | 1.78ms | 754% | 4053ns |
| `-t8 -c256` | **1,955,653** | 112µs | 3.09ms | 763% | 3902ns |

**Roughly 1.96M requests per second on four physical cores**, about 489k per
core, at 95% of the server's hardware-thread budget.

The p99 column in the bottom two rows is **not nilo's latency and should not be
quoted as such.** The giveaway is p50: it stays at 30µs while p99 goes to
1.78ms. A server whose tail had grown would have dragged its median with it.
What grew is the queue inside a load generator that has been given eight threads
on four cores and is now competing with itself. Measuring a tail honestly at
this throughput needs a second machine, or a fixed-rate generator that corrects
for coordinated omission — `wrk2`, or `oha -q`. Neither was run.

So there are two defensible readings, and they answer different questions:

- **1.31M req/s at p99 ≈ 90µs** — both sides have headroom, so the latency is
  real. Throughput is a floor.
- **1.96M req/s** — the throughput ceiling on four cores. The latency beside it
  is the client's.

## What a request costs, in process

`zig build profile` measures the pieces without a socket or a load generator in
the way, and it is the number that survives a change of machine best. On this
box, one request is **181ns of nilo's own work**:

| | | |
|---|---|---|
| read the head | 6ns | 3.4% |
| parse the head | 29ns | 16.3% |
| copy the head to the arena | 7ns | 4.3% |
| match the route | 17ns | 9.6% |
| serialise the body | 60ns | 33.0% |
| write the response | 31ns | 17.2% |
| arena alloc + reset | 6ns | 3.7% |

[`history.md`](../../docs/history.md#where-the-cost-turned-out-to-be)
recorded 585ns for the same harness on the machine it was written on, so this
box is about 3.2× faster. The router table moved with it — the mixed set went
from 27/47/56/107/167ns to 13/20/19/38/60ns across 1/5/25/50/100 routes, between
2.1× and 3.0× — and because both halves shrank together, the conclusion drawn
from their ratio survives: 10% of 181ns is 18ns, a 25-route mixed set costs 19ns
to match, and the linear scan still crosses ADR 017's bar at around 25 to 30
routes. Only the absolute numbers were ever machine-bound.

### The number that reframes the budget

Put the two measurements beside each other. A request costs 181ns of nilo's own
work and **3,902–4,542ns of CPU** once it is actually being served over a
socket. nilo's own code is therefore about **4% of what a request costs.** The
other ~96% is the kernel: `epoll`, `recv`, `send`, and the TCP/IP path — on
loopback, where it is at its cheapest.

That is worth stating plainly next to
[ADR 017](../../docs/adr/017-the-trade-budget-has-four-axes.md), because it
makes the 10% rule more generous than it sounds. Ten percent of nilo's own work
is 18ns, which is **0.4% of the request**. The DX budget was never the thing
standing between this framework and a throughput number.

### What a union in the response was costing

`serialise the body` is 33% of that 181ns, and one shape was paying about three
times what the rest do. `covers` is answered for the **whole** value — one field
the generated writer does not recognise takes the entire struct to `std.json`
with it — and until [ADR 016](../../docs/adr/016-the-api-description-comes-from-the-signatures.md)
it did not recognise a `union(enum)` at all. So a response with one union field
anywhere in it paid `std.json`'s byte-at-a-time string escaping for every string
in the response.

Photon's alert rule, 374 bytes, one long string, one float, two enums:

| | ns, across six runs |
|---|---|
| **A** `std.json`, externally tagged — what nilo sent | 248–317 |
| **B** generated writer, externally tagged — identical bytes | 86–93 |
| **C** generated writer, internally tagged — the new encoding | 88–95 |
| **D** *control:* the union flattened into a plain struct by hand | 88–94 |
| **E** a 104-byte payload through A | 81–88 |
| **F** the same payload through C | 24–25 |

**2.8× to 3.2×** on the large payload, **3.4× to 3.5×** on the small one. Quoted
as a band because `std.json`'s row moves 28% between runs while the other three
sit inside 8ns of each other; the best pair alone would have read 3.6×.

Two of these rows exist only to stop the headline being over-read.

**D is the ceiling**, and C lands on it — the two swap places between runs. That
is the finding: an internally tagged union costs nothing against a struct with
no union in it, so the hand-written flattening people do today to stay on the
fast path buys no speed, only boilerplate. **B against C** says internal versus
external tagging is not a performance question at all, which removes the one
objection the new encoding could have attracted. And **E/F** says the win is not
an artefact of one long string — the small payload's ratio is the larger of the
two.

Five interleaved pairs of 200,000 iterations per run, ReleaseFast, on the machine
above.

```
zig run spike/union_json/main.zig -O ReleaseFast
```

[`spike/union_json/`](../../spike/union_json/) has the program and what each row
is for. Its one weakness is that it copies `writeString` and `nextEscape` out of
`http/json.zig` rather than importing them, so it measures the shape of the
writer rather than the exact bytes the framework ships.

### What a uuid in the response was costing

The same finding as the section above, reached from the other side and two
years' worth of responses wider. `covers` refused any type carrying its own
`jsonStringify`, and four of those are nilo's own: `sql.Uuid`, `sql.Timestamp`,
`sql.AsText` and `id.Uuid`. Since `covers` is answered for the **whole** value,
one of them anywhere in a response sent the entire struct to `std.json` —
strings included, which is the part the generated writer exists for.

The port that reported it has **145 `uuid` columns across 59 tables**, so this
was every response it sends.

One contact row, 305 bytes: three uuids, four strings, a bool and an integer.

| | ns, across three runs |
|---|---|
| **A** `std.json`, whole value — what nilo sent | 244–254 |
| **B** generated writer, leaf handed to `std.json` — [ADR 148](../../docs/adr/148-a-field-name-is-a-spelling-too.md) | 161–169 |
| **C** *control:* the same struct with the uuids already text | 102–121 |

**33% off**, and C says where the rest of it is: the gap between B and C is the
three `jsonStringify` calls, which is the leaf itself and is not going anywhere.
That is a smaller multiple than the union row above (2.8×) for the honest
reason — a `Uuid` is 36 characters of a 305-byte payload, so less of the
response was ever on the slow path than a union's whole struct is.

Both rows say the same thing, which is worth stating once: **`covers` answering
false is never local.** It is a property of the whole value, so the cost of a
type it will not touch is paid by every string beside it. That is the argument
for spending effort on what `covers` accepts rather than on what the writer does
once it has accepted something.

200,000 iterations per row, ReleaseFast on every module, on the machine above.

```
zig run -O ReleaseFast --dep nilo_json_writer -Mroot=spike/leaf_json/main.zig \
  -O ReleaseFast --dep nilo_core -Mnilo_json_writer=http/json.zig \
  -O ReleaseFast -Mnilo_core=core/core.zig
```

`-O ReleaseFast` before **every** `-M` is not decoration: given once it applies
to the root module only, and the first reading of this had A at 1,989ns and B at
1,423ns — a ratio that survived and absolutes that were eight times the truth.
[`spike/leaf_json/`](../../spike/leaf_json/) imports `http/json.zig` rather than
copying it, which is the one thing `spike/union_json/` could not do, and it
asserts the two paths produce identical bytes before it times either.

### Can it be pushed further?

Row C is the floor for this payload and B is 50ns over it, all of it in three
`std.json` leaf calls. Closing that would mean nilo writing `Uuid`'s 36
characters itself, which it cannot: the type is `nilo_id`'s and `http/` never
learns it exists (ADR 042). A `nilo_json_write` a leaf could declare would do
it and is not worth 50ns on a 305-byte response — filed here rather than built,
so the next person starts from the number.

### What checking every response header costs

Run to settle one question:
[ADR 029](../../docs/adr/029-a-header-is-checked-once-and-two-of-them-repeat.md)
refuses a response header value that can end its own line, and the open choice
was whether to do it in every optimize mode or only in `Debug` and
`ReleaseSafe`. Same harness, same box, commit `a1537a6` as the baseline.

**Measured against a table-driven predicate that did not ship.** This run was
taken on the branch that refused only the six bytes with a consequence; what
merged is ADR 029's `token` and `field-value` rules, which are a per-byte loop
rather than a table lookup. The numbers below are what *having a guard on every
`setHeader`* costs, and that is the question they were run to answer. What the
shipped predicate costs on its own has not been measured separately — it is a
loop over the same bytes with no table load, so it is expected to land inside
this spread, and "expected" is doing real work in that sentence.

Three trees, built and run interleaved (HEAD, HEAD plus the four other fixes in
this batch, and that plus the guard), so a machine that drifts drifts through
all three:

| | mean of 8 | spread | against the tree above |
|---|---|---|---|
| `a1537a6` | 191.5ns | 184–197 | |
| + `Vary`, `Content-Length`, the two ceilings | 192.75ns | 188–199 | **+1.25ns, sign flips 4 of 8, so unchanged** |
| + the header guard | 200.9ns | 194–208 | **+8.1ns, sign flips 1 of 8** |

**The four other fixes are not measurable and the guard is, at about 4%.** Take
the second figure as a band rather than a number: an earlier six pairs of the
same two trees put the guard at +0.2ns with the sign flipping three times, and
the same binary came back anywhere from 184 to 213ns across sixteen runs. What
every batch agrees on is single-digit nanoseconds, and never a win. **3 to 8ns
on a 192ns request is the honest quote.**

Two things about what that is measured *through*. It is `zig build profile`,
which is in process with no socket in the way, so the guard is a larger fraction
here than in anything served over a network. The section above puts nilo's own
work at about 4% of a served request, which makes this about 0.15% of one. And
it is per `setHeader` call rather than per request: the profile harness installs
`cors.permissive`, so every response sets one header. A response that sets none
pays nothing at all.

**The first version of the check cost 9ns rather than 3, and the reason is the
part worth keeping.** It used `scan.positionsOf`, which was the wrong tool by a
factor of three. `positionsOf` is built for the request head, where there are
whole 32-byte blocks to stand on; below one block it falls to a scalar tail
loop, so three delimiters over a 27-byte header name is three passes of 27
iterations rather than one vector compare. Header names and header values are
nearly always under a block. Replacing it with one branchless pass over a
256-byte table, one load and one `or` per byte with the answer read once at the
end, is where the other 6ns went. The table is not what shipped, but the lesson
survives the predicate: whatever the rule is, it wants one pass over the bytes.

The general form of that: **a SIMD helper that was fast where it was written is
not automatically fast where it is reused.** `scan.zig`'s own header says it
exists for the head, the query string and JSON strings, all of which are long. A
fourth caller with short inputs was a different problem wearing the same shape.

Reproduce with:

```
git archive HEAD | tar -x -C /tmp/base    # build the before, do not quote it
for i in $(seq 8); do
  (cd /tmp/base && zig build profile | head -1)
  zig build profile | head -1
done
```

## Correctness under load

Not a speed measurement. [ADR 006](../../docs/adr/006-failure-box-bound-to-the-fiber.md)
binds a fail function's `Failure` to the fiber rather than the thread, and
`bench/mixed.lua` is what would catch it if that were wrong: alternating hits on
a user that exists and one that does not, checking every body against the id it
asked for.

```
wrk -t4 -c64 -d15s -s bench/mixed.lua http://127.0.0.1:8787

13,695,461 requests at 907,027 req/s, half of them 404s
wrong or crossed responses: 0 out of 13695461
```

Not one message crossed between concurrent requests in 13.7 million of them.

## Memory per idle connection

The third row of [ADR 017](../../docs/adr/017-the-trade-budget-has-four-axes.md)'s
budget, described there as a hard invariant that every feature has to state a
cost against — and until now not measured, because `bench.sh` says outright that
it does not measure it.

Method: from one freshly started server with eight worker threads, open
keep-alive connections in steps, sending one request on each so the connection
is fully established through the accept path and draining the response so
nothing is left backed up. At each step, settle for two seconds and read
`VmRSS`. The connections from earlier steps stay open, so the last row is 10,000
live connections and not 10,000 opened and closed.

| idle connections | RSS | per connection (marginal) |
|---|---|---|
| 0 | 5,644 kB | — |
| 500 | 13,928 kB | 16,966 B |
| 1,000 | 22,216 kB | 16,974 B |
| 2,000 | 38,776 kB | 16,957 B |
| 5,000 | 88,464 kB | 16,960 B |
| 10,000 | 171,280 kB | 16,961 B |

**16,961 bytes per idle connection**, and the shape of that column is the real
result: marginal cost equals average cost to within 17 bytes across a twentyfold
increase. Nothing steps, nothing compounds, no pool doubles in the background —
which is what makes the figure safe to extrapolate from at all. 10,000 idle
connections cost 171 MB; 100,000 would cost about 1.7 GB.

An idle server is 5.6 MB.

### That number was not a property of a connection

The first reading of it was "16 KiB of buffers plus about 570 bytes of
bookkeeping". That is wrong in a way worth keeping, because the arithmetic
worked and the explanation did not.

`VmRSS` counts pages that have been *touched*, not bytes that have been
allocated, so what a connection costs depends on what it has done. Measured
three ways at the shipped 8 KB / 4 KB buffers, 4,000 connections each:

| the connection has | bytes of RSS |
|---|---|
| been accepted and never sent a byte | **8,766** |
| served one 6-byte response | 16,955 |
| served one 982-byte response | **21,114** |

So the table above, which used `GET /health`, understates a real application by
about a quarter. And raising the buffers changes nothing at all: at 16 KB / 8 KB
and again at 32 KB / 16 KB the cost stays 16,955, because the extra pages are
allocated and never touched. Lowering them does help, roughly a byte per byte,
until the touched pages run out.

The 8,766 that a never-used connection costs is two pages of fiber stack plus
about 574 bytes of connection bookkeeping. That part is zio's, and is paid the
moment `accept` returns. Everything above it is buffer pages that a connection
touched once and then held for as long as the client kept the socket open.

### Giving the pages back

Which is a thing that can be fixed, and now is. Between requests — once a short
read has come back empty, so a connection under load never reaches it —
`MADV_DONTNEED` hands both buffers' pages back to the kernel. The allocation
stays, so nothing here allocates and ADR 017's per-request invariant is
untouched; the next request faults the pages in again as zeroes, which is all a
buffer about to be overwritten needs to be.

| | before | after |
|---|---|---|
| accepted, never used | 8,766 | 8,763 |
| served one 6-byte response | 16,955 | **8,762** |
| served one 982-byte response | 21,114 | **12,940** |
| 10,000 idle connections | 171 MB | **91 MB** |
| throughput | 1,314,275 req/s | 1,314,031 req/s |
| p99 | ~90µs | 66µs |

A connection that has served a small response now costs what one that has never
been used costs. Re-measured through the same harness as the table above, the
per-connection figure is **8,767 bytes** and just as flat — 8,749 at 1,000
connections against 8,769 at 10,000.

> That figure stood for two cycles and is now **4,669**. What was left was two
> pages of fiber stack, and one of them was there only because the connection
> suspended itself four kilobytes deeper than it had to — see *Memory per idle
> WebSocket* below and
> [ADR 062](../../docs/adr/062-where-a-connection-waits-is-what-it-costs.md).

**That is the framework's floor, and the same bug turned out to be alive one
layer down.** Buffer pages stopped being held; *stack* pages never did. A
suspended fiber holds its stack at its high-water mark until the connection
closes, so a handler adds every byte it touches — measured one for one, from
8 KiB to 128 KiB. An ordinary route reading one row and answering JSON holds
**17,022 bytes** per idle connection rather than 8,749, and a handler with a
64 KiB buffer on its stack holds 64 KiB per connection rather than per request.
`bench/sql_server.zig` has the four routes that separate the causes, and
[ADR 062](../../docs/adr/062-where-a-connection-waits-is-what-it-costs.md) has the tables.

The gate is the whole design. Releasing on every trip round the loop, which was
the first attempt, took throughput from 1.31M to **626k** — a 52% loss, because
`MADV_DONTNEED` in a process with eight threads shoots down TLB entries on all
of them, and a busy keep-alive connection was paying that on every single
request to free pages it needed back microseconds later. Waiting 200ms first
costs a connection under load nothing, because it never gets there.

What is left above the floor for a real response is the request arena, which
retains up to `arena_keep` and so holds a page on any connection that has served
something. That is a deliberate trade for not reallocating per request, and it
is the next thing to look at rather than a defect.

### The seventh inline header costs nothing, and the figure is per binary

[ADR 029](../../docs/adr/029-a-header-is-checked-once-and-two-of-them-repeat.md) took
`inline_headers` from six to seven so a gzipped static file behind a named-origin
CORS could carry both `Vary` axes without spilling to the arena. The 32 bytes sit
on `serveRequest`'s frame, which is `noinline` and unwound before the connection
waits, so the reasoning said an idle connection was untouched. **The reasoning was
all there was**: `bench/mem.py` reads `ss` and `/proc/<pid>/VmRSS`, both Linux,
and the change was made on Darwin. ADR 062 is why that was not left alone — a
per-connection claim reasoned from the shape of the code, and repeated in six
files, was half wrong for two milestones.

Method: `examples/hello` on `/health`, out to 10,000 connections, `d04d1a2`
against a `git archive` rebuild of `v0.2.0` into a scratch directory. Four runs,
two per side, started alternately so a machine that drifts drifts under both.

| idle connections | `v0.2.0` | `d04d1a2` |
|---|---|---|
| 500 | 5,005 / 4,989 B | 5,005 / 4,981 B |
| 1,000 | 4,907 / 4,903 B | 4,899 / 4,891 B |
| 2,000 | 4,850 / 4,844 B | 4,850 / 4,848 B |
| 5,000 | 4,819 / 4,820 B | 4,821 / 4,819 B |
| 10,000 | **4,810 / 4,809 B** | **4,810 / 4,810 B** |

**Unchanged, and the spread across all four runs is one byte.** Marginal at the
last step is 4,798–4,803 against an average of 4,810, so the reading has
converged and the difference between the two sides is smaller than the noise on
either. The seventh header costs an idle connection nothing, which is what
ADR 029 argued and what nothing had checked.

**The other half of this run is the one to remember.** 4,810 is not 4,669, and
the gap is not a regression — it is a different program. The published figure
belongs to the benchmark server, and the same harness against it on the same
afternoon reads inside the band it always has:

| server | binary | 10,000 idle connections |
|---|---|---|
| `zig build run` | `nilo-hello` (`bench/main.zig`) | 4,674 B (marginal 4,673) |
| `zig build run-hello` | `example-hello` (`examples/hello`) | 4,810 B (marginal 4,800) |

136 bytes apart, on two programs whose names are one character different. This is
the memory axis of the trap the binary-size table already names further down: **a
row in the ADR 017 table means `bench/main.zig`, and `run-hello` is a different
answer to the same question.** The roadmap's own reproduce line said `run-hello`,
so the next person to settle the `inline_headers` question would have read 4,810,
compared it against 4,669 and found a regression that is not there. That line now
names the benchmark server.

`bench/result/s3.md` reads 4,670 at 10,000 for a third binary again, so the
framework's floor is a band of roughly 4,670 to 4,810 depending on which program
carries it, not a single constant. What every published number has in common is
that it was taken on `bench/main.zig` or something built the same way.

## Memory per idle WebSocket

Asked because [gws](https://github.com/lxzan/gws) claims a low memory footprint
and nobody here had a number to put beside it. The published figures were all
HTTP: an upgraded connection had never been measured, and the WebSocket path
differs in one way that should matter — `App.serveRequest` is left behind at
`c.upgrade()`, so the idle release never runs again and the two buffers it
hands back are held for as long as the socket is open.

Method: `bench/ws_server.zig` and `bench/ws_idle.py`, six scenarios each on a
freshly started server, `VmRSS` read after the sockets settle, in steps so the
marginal figure can be read off rather than assumed — 500 / 1,000 / 2,000 for
the comparison below, and out to 5,000 and 10,000 for the figures that get
quoted, which is a distinction the next section is about. Same machine and
method as the table above, so the HTTP row is the control rather than a quote.
`IDLE_MS=0` — the framework's 30-second keepalive would have every fiber in the
measurement waking to ping, which is a different thing to measure.

Three things changed across this cycle and the columns are in the order they
landed: the message buffer stopped belonging to the handler
(`http/scratch.zig`), then the idle wait and the socket loop both moved up to
the connection loop's frame
([ADR 062](../../docs/adr/062-where-a-connection-waits-is-what-it-costs.md)).

| what the connection is | at the start | pooled buffer | loop handed back |
|---|---|---|---|
| HTTP keep-alive, one 6-byte response | 8,763 | 8,753 | **4,669** |
| WebSocket, upgraded and never spoken to | 21,619 | 9,290 | **5,190** |
| WebSocket, one 6-byte echo | 21,561 | 9,282 | **5,255** |
| WebSocket, 64 KiB ceiling, one 6-byte echo | 21,565 | 9,290 | **5,190** |
| WebSocket, 64 KiB ceiling, one 60 KiB echo | 87,101 | 9,282 | **5,247** |
| WebSocket, 64 KiB of stack touched in the loop | 87,099 | 74,858 | 70,746 |

All three columns are the marginal figure at 2,000 sockets — `(RSS at 2,000 −
RSS at 1,000) / 1,000` — which is the one that does not carry the server's own
8 MB baseline in it.

The last column was taken twice, a rebase apart: once on the change alone and
once on the merged tree that ships, which is the run above. **The two agree to
within 66 bytes on every row** — 4,669 both times on the HTTP control, 5,186
against 5,190 on the idle socket, 70,767 against 70,746 on the stack control.

#### At 2,000 sockets two of those rows are still a transient

The `one 6-byte echo` and `one 60 KiB echo` rows read 5,255 and 5,247 above,
which is 60-odd bytes above the rows beside them, and the difference is not a
property of anything. Taking the same run out to 10,000 sockets says so — the
marginal figure, `(RSS at N − RSS at N−1) / step`:

| what the connection is | 500 | 1,000 | 2,000 | 5,000 | 10,000 | avg at 10,000 |
|---|---|---|---|---|---|---|
| HTTP keep-alive, one 6-byte response | 4,645 | 4,669 | 4,674 | 4,672 | 4,672 | 4,671 |
| WebSocket, never spoken to | 5,161 | 5,194 | 5,190 | 5,183 | **5,183** | 5,183 |
| WebSocket, one 6-byte echo | 5,636 | 5,186 | 5,198 | 5,190 | **5,183** | 5,209 |
| WebSocket, 64 KiB ceiling, one 6-byte echo | 5,284 | 5,194 | 5,194 | 5,184 | **5,182** | 5,190 |
| WebSocket, 64 KiB ceiling, one 60 KiB echo | 7,012 | 5,308 | 5,177 | 5,187 | **5,186** | 5,283 |
| WebSocket, 64 KiB of stack touched | 71,082 | 70,853 | 70,722 | 70,726 | **70,719** | 70,746 |

**Marginal equals average at 10,000 on every row**, which is the strongest form
this measurement takes: the cost is a property of a connection rather than
something that steps, compounds or amortises. The rows that looked different at
2,000 are the first message's buffer being paid for once by the server and
divided by a smaller N — the `60 KiB echo` row starts at 7,012 and ends at
5,186, and nothing about the socket changed in between.

**All four WebSocket rows land within four bytes of each other.** A socket that
has echoed 60 KiB costs the same as one that has never been spoken to, which is
exactly what `http/scratch.zig` was built to make true and is the one row worth
checking after any change to it.

So the figures to quote are the converged ones: **4,669 bytes per idle
keep-alive connection** — the number ADR 017 carries, and every reading from
500 to 10,000 sockets is inside 4,645–4,674 — and **5,183 bytes per idle
WebSocket**, whatever it has received.

**An idle WebSocket cost 21,561 bytes and now costs 5,183** — a quarter of what
it was. Ten thousand idle chat tabs are 52 MB rather than 216 MB, and that is
now a measured row rather than an extrapolation: 10,000 held-open sockets read
58,732 kB against a 8,116 kB baseline.

The rows are there to stop each other being misread:

- **Declaring a big buffer costs nothing.** 64 KiB and the default measure the
  same to within eight bytes, because `VmRSS` counts pages that were touched
  and a 6-byte message touches one of them.
- **Receiving one big message used to cost it forever.** In the first column
  the 60 KiB echo holds 61,440 bytes more than the small one for the life of
  the socket, because the receive buffer was a local in the handler's frame.
  Once the buffer comes from the executor's free list instead, that row is the
  same as the others: the buffer goes back when the conversation goes quiet.
- **The last row is the control that keeps the rest honest.** 64 KiB touched on
  the loop's own stack still costs 64 KiB per connection, one byte for one
  byte. [ADR 062](../../docs/adr/062-where-a-connection-waits-is-what-it-costs.md)'s
  finding is unchanged by any of this — what changed is how much stack the
  framework leaves under a parked socket, not whether a fiber holds it.

### The measurement that said nothing was happening

Worth writing down because it cost most of a day and the mistake is easy to
repeat.

With the stack release wired into the idle path, `strace -c` confirmed the
`madvise` ran on every idle connection, and **`VmRSS` per connection did not
move by a byte** — 8,767 before, 8,767 after. Two causes, found by printing
what the release actually saw (`base - limit`, `base - frame`, and the length
handed back) rather than by reasoning about it:

1. **Four pages of margin below the frame.** The chain being released is four
   to six kilobytes deep, so sixteen kilobytes of margin reached past every
   page there was to give back. A page of margin is not a page of safety; what
   has to be protected is this frame and the 128-byte red zone under it.
2. **The connection then walked back down and slept there.** `waitOrRelease`
   released and returned, and the loop called `serveRequest` → `readHead` →
   `fillMore` and suspended four kilobytes deeper than the frame the release
   had run at, faulting straight back in what it had given away.

Measured live chain, `base - frame` at the point the connection is suspended:

| | idle keep-alive | parked WebSocket |
|---|---|---|
| at the start | 5,561 | 6,457 |
| cold paths out of line | 3,497 | 4,233 |
| `serveRequest` out of line | 1,721 | 4,345 |
| loop handed back | 2,105 | **2,617** |

The stack is charged by the page, so only the crossings matter: both columns
now sit under 4,096 and hold one page where they used to hold two. The
`serveRequest` row is the one that looks wrong and is not — taking the request
frame out of line moved 1,608 bytes off the *HTTP* chain and none off the
WebSocket's, because a handler that keeps its own loop is suspended inside that
frame. That is the measurement the API change came out of.

### The finding was not the memory

The release did not work at first, and finding out why turned up something
worse than the bytes. `strace -c` said `madvise` fired for a socket that had
never been spoken to and never for one that had echoed a single message, so
sockets that had received anything were not parking at all.

They were not. `Wake.wait` in `http/engine/zio.zig` re-armed its `NetPoll`
completion **on the way out of a `.readable`, before the caller had read the
bytes**. `NetPoll` is level-triggered, so that re-submitted poll completed at
once against data still sitting in the kernel's receive buffer — and the next
wait found it already done, answered `.readable` for bytes that had since been
read, and dropped the fiber into a blocking read with no deadline on it.

**Nothing could reach it there.** Not a `Room` post, not the idle limit. So:

- a WebSocket stopped receiving broadcasts the moment it sent its first
  message, which is `examples/chat` failing at what the example exists to show
  — two tabs, type in one and the other sees it, type in the other and the
  first never hears from it again;
- `Options.idle_ms` only ever pinged a socket that had never spoken. With
  `IDLE_MS=1000` a silent socket is pinged at 1.0s and closed at 2.0s; one that
  had sent six bytes got nothing in six seconds. The heartbeat ADR 021 built
  to catch a client that has gone away could not catch one that had ever said
  anything.

Both were reproduced against the shipped `examples/chat` and both are fixed by
arming the poll on the way *in* to the next wait instead — after the caller has
read. `Waker` in `http/bulkhead.zig` now states it as the Engine contract it is:
one `.readable` per arrival of bytes, not one per call.

It is worth saying how this survived: it is invisible from the test suite. The
HTTP suite runs against in-memory buffers with `Waker.off`, which answers
`.readable` to everything by design, so no test could see it — and no benchmark
touched a WebSocket until this one. **The bug was found by measuring something
else.**

### Against gws

The library that put the question, measured through the same harness on the
same machine: `bench/compare/gws/`, gws v1.10.1 on Go 1.26.3, no compression,
no `ParallelEnabled`, no deadline — the shape that matches what nilo is doing
and the one that is kindest to gws's number. Go's `VmRSS` holds a heap the
collector has not returned, so its server exposes `/gc` and every row is read
twice; the figures below are after `runtime.GC()` and `debug.FreeOSMemory()`,
which is the reading that charges gws for connections rather than for garbage.

Both columns at **10,000 held-open sockets**, per-connection average with the
server's own baseline subtracted, gws's read after a forced `runtime.GC()` and
`debug.FreeOSMemory()`:

| what the connection is | nilo, at the start | nilo, now | gws | nilo/gws |
|---|---|---|---|---|
| HTTP keep-alive, one 6-byte response | 8,763 | **4,671** | 19,528 | **4.2× better** |
| WebSocket, upgraded and never spoken to | 21,619 | **5,183** | 7,836 | **1.5× better** |
| WebSocket, one 6-byte echo | 21,561 | **5,183** | 9,598 | **1.9× better** |
| WebSocket, one 60 KiB echo | 87,101 | **5,186** | 9,685 | **1.9× better** |

gws was taken to 10,000 as well rather than left at the 2,000 the first run
stopped at, because a comparison where one side is converged and the other is
not is a comparison with a thumb on it. It cost one command and it moved gws's
best row in gws's favour — the idle socket reads 8,206 at 2,000 and **7,836 at
10,000**, so the margin on that row is 1.5× rather than the 1.6× a shorter run
would have published. **Run the other side out too, especially when it helps
them**; the number that survives is worth more than the one that flatters.

The first column is why the comparison was worth running. gws was ahead on the
idle socket by a quarter and ahead on the 60 KiB one by **7.3×**, and both of
those were nilo paying for a design choice rather than for anything a
WebSocket needs:

- the receive buffer was a local in the handler's frame, so a socket that had
  ever received a big message held it until it closed. gws's payload comes from
  a `sync.Pool` and `message.Close()` puts it back. `http/scratch.zig` is the
  same idea: the buffer belongs to the executor, is borrowed while a message is
  arriving, and goes back when the connection goes quiet.
- the handler kept the loop, so a parked socket was suspended inside the
  request machinery. gws parks in its own read loop with the HTTP request long
  gone. ADR 062 is the same idea: the handler hands the loop back.

Throughput, same machine, both servers pinned to the same four physical cores
and driven by the same client — `bench/compare/wsload/`, which uses gws's own
client so neither side is measured through a different implementation. 64
connections, serial round trips, 20 seconds after a 3-second warm-up, the two
servers started **alternately in one session** so neither gets a colder machine
than the other:

| payload | run | nilo | gws | nilo − gws |
|---|---|---|---|---|
| 64 B | 1 | **1,672,617 msg/s** | 1,563,759 | +7.0% |
| 64 B | 2 | **1,685,719 msg/s** | 1,558,146 | +8.2% |
| 1 KiB | 1 | **1,592,039 msg/s** | 1,486,730 | +7.1% |
| 1 KiB | 2 | **1,582,707 msg/s** | 1,511,168 | +4.7% |

| percentile | nilo | gws |
|---|---|---|
| p50 | **32–34µs** | 34–35µs |
| p90 | **62–65µs** | 70–74µs |
| p99 | **102–112µs** | 121–128µs |
| p999 | **304–419µs** | 460–493µs |

**nilo is ahead on every run, by 5–8% on throughput and 12–15% on p99, and the
spread between runs is as wide as half the margin.** Quote it as "about 7%",
not as a figure with a decimal point in it: four runs put it at 7.0, 8.2, 7.1
and 4.7, and a fifth would land somewhere in that band too. The tail is the
firmer of the two claims — nilo's p999 is better than gws's in every run by
more than either one's spread.

The number is only honest because both sides were pinned. An earlier unpinned
run had gws at 1,029,308 msg/s and would have been reported as nilo winning by
68%. That was the load generator and the server fighting over cores, not the two
libraries, and it is the same trap `bench/bench.sh` unpinned falls into on the
HTTP side.

Two things the table cannot say. **gws's figure has still not converged at
10,000, where nilo's settles to the byte by 5,000.** On the idle row its raw
marginal runs 11,543 → 9,183 → 7,954 → 8,486 → 8,033 while its average after GC
runs 10,043 → 8,724 → 8,253 → 7,805 → 7,836; the two are still 200 bytes apart
at the last step, which by the test applied to nilo's own table means the number
is not yet a property of a connection. It is falling, so a longer run moves it
further in gws's favour, and **7,836 should be read as an upper bound rather
than a figure.** And every gws number moves with when the collector last ran:
its idle row has read 7,989, 8,247, 8,206 and 7,836 across four runs, against
nilo moving by four bytes. Every reading is in `bench/result/ws-idle.json`, and
**the gws column deserves less precision than it is printed with** — treat it as
8k, 10k, 20k. The ratio is what survives, and at 1.5× on gws's best row it
survives with room to spare.

### A second room costs a seat and nothing on the connection

Asked when a socket stopped being limited to one `Room` ([ADR 035](../../docs/adr/035-a-broadcast-rings-a-bell-it-does-not-write.md)): the chain of rooms a socket sits in moved into the seats, sixteen bytes a seat, and the socket's own two fields (32 bytes) became one head (16). The claim was that per idle connection nothing moves and the whole cost is up front, in the seats. Measured 2026-09-25 at `9a4d49f` plus the change, on the machine above now running kernel 7.2.5 (Omarchy) rather than the Ubuntu kernel in the table. Both sides were built the same afternoon from `git archive` into scratch directories, `ReleaseFast -Dtarget=x86_64-linux-gnu`, with the same harness copied into both. The rounds were interleaved before, after, before, after, with `STEPS=500,1000,2000` and `IDLE_MS=0`. Two new routes: `/ws/room` is `/ws/small` joined to one room, and `/ws/rooms` is the same joined to two. Each room has 12,000 seats, made before the listener opens.

| scenario, 2,000 sockets | before, two rounds | after, two rounds |
|---|---|---|
| `/ws/idle` | 5,695 / 5,693 B | 5,693 / 5,693 B |
| `/ws/small` | 5,693 / 5,691 B | 5,693 / 5,691 B |
| `/ws/room`, one room | 5,691 / 5,693 B | 5,700 / 5,704 B |
| `/ws/rooms`, two rooms | refused (`AlreadySeated`) | 5,693 / 5,693 B |
| idle baseline, two 12,000-seat rooms | 11,588 to 11,608 kB | 11,956 to 11,984 kB |

**Per connection: unchanged.** Every row sits inside a 13-byte spread, and `/ws/rooms` is no dearer than `/ws/room`. A seat's pages are written when the room is made, so taking one touches nothing new. The cost shows up in the baseline instead: **+370 kB for 24,000 seats, 15.8 bytes a seat**, which is the sixteen the struct grew by. A room pays 16 KB per thousand seats for being joinable alongside others. Marginal met average at every step on both sides.

**The absolute figure is not the published one.** 5,69x here against 5,183 in the table above, on both builds alike, so it is not this change. The host moved from Ubuntu's 7.0 kernel to 7.2.5 between the two runs, and nothing here has shown that is the cause. The next run of the full table should say which.

### What is not measured

**A message big enough to be worth pooling, under load.** The throughput
figures go up to 1 KiB, which still never leaves the first page of the free
list's buffer. What a 60 KiB message costs at a thousand messages a second —
where the byte budget starts refusing spares and the allocator gets called — is
the number that would decide whether `keep_bytes` is right, and nothing here
answers it. The memory table has the 60 KiB row but only one message per socket,
which is the opposite corner: it proves the buffer is given *back*, not what
handing it back and forth costs when it never goes quiet.

**Compression.** gws was run with `PermessageDeflate` off, which is the shape
that matches nilo and the one kindest to gws's memory number. A deployment that
turns it on is a different comparison in both directions.

## Memory per open stream

The row of the same axis that had never been taken. `docs/guide/streaming.md`
quoted **~21 KB a stream** from v1 and told the reader to plan ten thousand of
them around it; that figure predates
[ADR 062](../../docs/adr/062-where-a-connection-waits-is-what-it-costs.md), which
found a handler holds its stack at its high-water mark, and
[ADR 062](../../docs/adr/062-where-a-connection-waits-is-what-it-costs.md),
which took an idle connection to 4,669. The guide dropped the number rather than
keep quoting one nothing stood behind, which was honest and not useful.

Machine and kernel as above, on commit `c890923`. `bench/stream_server.zig` and
`python3 bench/mem.py --port 8790 --path … --hold`. **`--hold` is why this could
not be run before**: `mem.py` drains a response before calling a connection
idle, and a stream being held open has no end to drain to, so the harness read
the head and then waited for a body that was never coming. It now stops at the
head for a route it is told is held, which is a handler still suspended rather
than a connection between requests — and those are different numbers.

One freshly started server per row, because RSS does not come back down: a row
taken after another row's ten thousand connections is measured against a
baseline full of memory the allocator is about to hand out again, and reads far
too low. The first attempt at this table did exactly that and put a held stream
at 4,852 B.

| route | what is open | per connection at 10,000 |
|---|---|---|
| `/health` | keep-alive, nothing suspended | **4,674 B** |
| `/stream` | a held stream, `logger.standard` in front | **21,058 B** |
| `/stream/quiet` | the same, exempt from the logger (ADR 008) | **21,057 B** |
| `/stream/deep` | the same, 32 KiB of handler stack touched first | **53,825 B** |

Marginal met average at every step from 500 up, so all four are converged rather
than a transient.

**A held stream costs 21,058 bytes, and the number the guide used to quote was
right.** 4.5× an idle connection, and the gap is what a suspended handler holds
that a parked connection loop does not: its own frame, its stack at high water,
and the response buffer it has not finished with.

**`/stream/deep` is ADR 062 again, to the byte.** 53,825 − 21,058 = 32,767,
which is the 32 KiB the handler touched, charged one for one and never given
back, because the frame holding it is live for as long as the stream is. The
arena is cheaper than the stack, on this path as on the others.

### What the logger costs a held stream: nothing, and the fix was already free

`todo.md` carried **"the logger puts a kilobyte on a frame that is live while
the handler waits"**, waiting on a number. `logger.with`'s inner `log` declares
`var buf: [1024]u8` and was a plain `fn`, so it was a candidate for inlining
into `run`, whose frame is live across `next.run(c)` — which is exactly the
mistake ADR 062 §3 found in `handleConnection`, where four unreachable
`std.log.warn` sites were most of 4,184 bytes.

The number says it was not happening. `/stream` against `/stream/quiet` is
**21,058 against 21,057 bytes**: the whole middleware, buffer and all, is inside
the noise of one byte.

And building it both ways says why. `noinline fn log` against `fn log`, both
`ReleaseFast`, produced **byte-identical binaries** — LLVM was already not
inlining it. Three interleaved pairs of the full measurement agree: 21,058 /
21,057, 21,058 / 21,058, 21,057 / 21,057.

**The `noinline` is kept anyway, as a pin rather than a fix.** It costs nothing
today, provably, and ADR 062 already put the same keyword on seven functions
for the same reason: what the optimiser chooses is not a guarantee, and a
kilobyte reappearing on a live frame is not the kind of regression anybody would
notice.

### A stream whose events come from Rooms costs what an idle connection does

Asked when `c.eventsFrom` handed an event stream to the connection loop rather than keeping its handler ([ADR 227](../../docs/adr/227-an-event-stream-fed-by-rooms-waits-where-a-connection-waits.md)). The claim was that a stream with nothing of its own to say should cost an idle connection, not the 21 KB above, and that a handler which touched 32 KiB of stack before handing over should not keep it. Measured 2026-09-25 at `9a4d49f` plus the change, on the machine above running kernel 7.2.5 (Omarchy). Both sides were built the same afternoon from `git archive` into scratch directories, `ReleaseFast`, and the rows were interleaved over two rounds, one freshly started server per row, `python3 bench/mem.py --port 8790 --path … --hold`. Two new routes: `/events/room` is `c.eventsFrom(feed_room, .{})`, and `/events/room/deep` is the same after touching 32 KiB of stack first. `feed_room` has 20,000 seats, made before the listener opens, and `KEEPALIVE_MS` is left at its bench default of 0 so no comment wakes the connections during the count.

| route, per connection at 10,000 | before, two rounds | after, two rounds |
|---|---|---|
| `/health`, keep-alive, nothing suspended | 5,183 / 5,183 B | 5,182 / 5,182 B |
| `/stream`, a held stream | 21,566 / 21,567 B | 21,566 / 21,566 B |
| `/events/room`, a stream in one room | not there | **5,184 / 5,184 B** |
| `/events/room/deep`, the same after 32 KiB of stack | not there | **5,183 / 5,184 B** |
| idle baseline | 8,432 to 8,460 kB | 11,312 to 11,380 kB |

**A stream fed by rooms costs an idle connection, to within two bytes**: 5,184 against 21,566 for the stream a handler holds, a quarter of it. **And the stack the handler touched is gone**: `/events/room/deep` reads the same as `/events/room`, where `/stream/deep` above kept all 32,767 bytes. The handler's frame unwound before the connection parked, which is the whole of the design. Marginal met average from 1,000 connections up in every row.

**Nothing moved for a connection that never streams.** `/health` and `/stream` are the same to the byte on both builds, which is the check that the handover slot, now a union of a Socket and an event stream, did not grow the connection loop's frame. The baseline rose 2.9 MB, which is the 20,000 seats of `feed_room`, about 146 bytes a seat, paid by the bench server for having the route.

A third pass, after the stream's `run` was moved behind a pointer for the size axis ([ADR 227](../../docs/adr/227-an-event-stream-fed-by-rooms-waits-where-a-connection-waits.md#what-it-costs)), read 5,182, 5,183 and 5,184 B for the same three routes at 10,000, one round.

**The absolute figures are this host's.** `/health` here is 5,183 against the 4,674 in the table above; both builds agree, so that gap is not this change, and the same unexplained move is under [A second room costs a seat](#a-second-room-costs-a-seat-and-nothing-on-the-connection). Compare within a table, not across them.

**Can it be pushed further?** Not on the connection: it now costs exactly what a connection waiting for its next request does. What is left is the seat, and that is the room's.

### A key costs a connection nothing, and a Room in the pool about 445 bytes

Asked when `nilo.Rooms` began lending Rooms to keys ([ADR 228](../../docs/adr/228-a-room-for-a-key-is-lent-from-a-pool.md)). The claim was that a stream under a key of its own costs what a stream in a Room does, because the pool's Rooms are made before the listener opens. Measured 2026-09-25 at `9a4d49f` plus the change, same machine and kernel as the section above, `ReleaseFast`, two interleaved rounds, one freshly started server per row. `before` is `9a4d49f` itself. The new route is `/events/named`: the stream sits in `feed_room` and under `user:<n>`, a new `n` every connection, in a pool of 20,000 Rooms of one seat.

| route | at 10,000, two rounds | marginal, 5,000 to 10,000 |
|---|---|---|
| `before` `/health` | 5,182 / 5,183 B | 5,181 / 5,182 B |
| `/health` | 5,181 / 5,182 B | 5,183 / 5,184 B |
| `/events/room`, one Room | 5,184 / 5,183 B | 5,183 / 5,183 B |
| `/events/named`, a Room and a key | 5,195 / 5,195 B | **5,184 / 5,184 B** |
| idle baseline | 8,432 / 8,444 kB `before`, 19,956 / 20,124 kB after | |

**Per connection, a key costs nothing**: from 5,000 connections to 10,000 a named stream adds 5,184 bytes each, the figure of a stream in a Room alone. The average at 10,000 is eleven bytes higher because it had not met the marginal yet: the first 500 connections cost about 108 kB more than the same 500 without keys, and the average falls at every step after, 5,415, 5,288, 5,237, 5,205, 5,195. That is paid once, and is the key table's pages written for the first time as keys land across it.

**The pool costs its size, before anybody connects.** The baseline rose 8.6 to 8.7 MB over [the previous run](#a-stream-whose-events-come-from-rooms-costs-what-an-idle-connection-does), which had `feed_room` and no pool: **about 445 bytes a Room of one seat**, its four allocations and its share of the key table included.

**Can it be pushed further?** The per-connection figure cannot, being the floor. The up-front one could: each Room is four allocations of its own, and one block for the whole pool would take the allocator's per-block overhead off every Room. Nobody has asked for a pool large enough for that to matter.

## The WebSocket against Autobahn

`todo.md` carried **"nothing runs the Autobahn suite against the
WebSocket"**, and by
[ADR 032](../../docs/adr/032-a-guard-is-not-a-guard-until-it-has-been-seen-to-fail.md)'s
reading that made every close-code and UTF-8 rule in
[ADR 046](../../docs/adr/046-a-message-is-copied-once-and-framed-once.md) a
guard only ever seen to pass: the framing tests were all written from RFC 6455
by whoever wrote the framing.

`wstest` is now run against `bench/autobahn/server.zig`, from the container the
suite ships in. `bash bench/autobahn/run.sh`, commit `c890923`, 12 seconds for
the whole suite.

| verdict | cases |
|---|---|
| OK | **294** |
| NON-STRICT | 4 |
| INFORMATIONAL | 3 |
| **FAILED** | **0** |
| **UNIMPLEMENTED** | **0** |

301 cases, families 1 through 10. Cases 12.x and 13.x are excluded because they
are `permessage-deflate`, which nilo does not negotiate and which is a roadmap
item with a per-connection cost nobody has priced.

**The four NON-STRICT results are all 6.4.x, and they are one decision.** Those
cases want a server to fail *as soon as* invalid UTF-8 appears in a fragmented
text message; nilo validates a text message when it is whole and answers 1007.
Autobahn records the close code as correct (`close=OK`, `1007`) and the timing
as not its preference, which is what NON-STRICT means. Failing earlier would
mean carrying a resumable UTF-8 decoder across frames, and the RFC allows both.

The three INFORMATIONAL are the 9.x timings, which the suite reports rather than
judges.

**This is a run, not a build step.** It needs Docker, so it is off `zig build
test` for the same reason `smoke-tls` is off it, and `bench/autobahn/README.md`
says how to run it.

## Coming back from a SIGTERM

**On a different machine from every other number in this file.** Two cores
rather than eight, so the absolute hang rate here says nothing about the rate on
the box above — a race resolves differently on two executors than on eight.
What the run is for is the pair, and both sides of the pair were taken here,
minutes apart, with the same binary target.

| | CPU | Cores | Memory | Kernel |
|---|---|---|---|---|
| this run | Intel Xeon Platinum 8255C @ 2.50GHz | 2 | 7 GiB | 6.8.0-110-generic |
| everything else in this file | AMD Ryzen 7 9700X | 8 | 30 GiB | 7.0.0-29-generic |

`python3 bench/shutdown.py --cmd ./zig-out/bin/nilo-bench-ws-server --port 8789
--path /ws/small`, ReleaseFast either way (`bench-ws-server` pins the optimize
mode, so there is nothing to pass). The before side is **built from a `git
archive` of `1eecf12` into a scratch directory**, not quoted: the published
figure was 6 of 10 at six connections, on the other machine, and a fix measured
against it would have been comparing two different boxes.

| connections a run | runs | before (`1eecf12`) | after (`Wake.deinit`) |
|---|---|---|---|
| 6 | 10 / 20 | **4 hung** | **0 hung** |
| 24 | 25 | **23 hung** | **0 hung** |
| 24, `--http` control | 15 | — | **0 hung** |

Every hang reads the same: `1.0 cores, 2 threads left`, one executor spinning in
userspace with no syscall outstanding, for as long as anybody lets it.

The after column was taken twice: once on the fix as first written, and once on
a rebuild of the tree that shipped, after the guard test and the comments went
in — 15 more runs at 24 connections, also 0. Same code, but the second run is
about the binary that exists rather than the one the number was taken on.

**The Autobahn suite is the other half of the check**, because it is what found
this in the first place — a server left at five cores of nothing for thirteen
minutes after the run finished. Re-run here: **294 OK, 4 NON-STRICT, 0 FAILED**
of 301, identical to the table above, and this time the script's last line is
`info: nilo stopped` and no process is left behind.

What it changed:
[ADR 077](../../docs/adr/077-a-completion-the-loop-holds-outlives-the-frame-that-submitted-it.md).
`Wake` submitted two completions to zio's loop and never gave them back, so the
loop wrote through `c.group.owner` into a fiber frame that had been handed on.
The roadmap had it filed as upstream and it was never upstream — the answer was
in the last test of zio's own `completion_queue.zig`.

**Can this be pushed further?** There is nothing to push: it is a bug, not a
number. What is worth doing is running `bench/shutdown.py` on the eight-core box
as well, because the before figure there is a different rate and nobody has
taken the after.

## What counting a request costs

**Same machine as the SIGTERM run above** — two cores, not the eight the rest of
this file was taken on. Both sides were taken here, minutes apart, interleaved.

`bench/main.zig` built twice in `ReleaseFast`, identical but for one line —
`try app.metrics(.{});` — and driven with `wrk -t1 -c50 -d10s` at
`/users/7`. Four pairs, alternating, server restarted between every run.

| pair | off (req/s) | on (req/s) | delta | off p99 | on p99 |
|---|---|---|---|---|---|
| 1 | 44,638 | 43,643 | **−2.2%** | 3.56ms | 4.29ms |
| 2 | 44,805 | 45,679 | **+2.0%** | 3.50ms | 3.46ms |
| 3 | 45,327 | 42,997 | **−5.1%** | 3.47ms | 3.72ms |
| 4 | 44,590 | 45,605 | **+2.3%** | 3.53ms | 3.45ms |
| mean | 44,840 | 44,481 | −0.8% | 3.52ms | 3.73ms |

**The sign changes twice and the spread is seven points wide, so the answer is
unchanged.** Anyone reading a single pair off this table would publish either a
2% win or a 5% loss, and both would be noise — which is the whole reason the
rule about interleaving exists.

Two things this run does **not** settle, and both are the kind of gap that gets
quoted as a result if nobody writes them down:

- **Contention is understated here.** Two cores means two executor threads
  hitting one counter; eight would hit it harder, and `wrk` at a single route is
  the worst case for a single cache line. A per-thread shard is the fix if it
  ever shows up, and nothing has measured it.
- **The client shares the box.** 44,000 req/s against the 1.42M this file
  records elsewhere is the machine and the co-located load generator, not the
  server.

What it changed:
[ADR 079](../../docs/adr/079-the-route-table-is-the-registry.md) — metrics
ship counting plain atomics rather than a sharded table, on the strength of this
being inside the noise.

**Can this be pushed further?** Not from here. What would settle it is the same
pair on the eight-core box, and the lever if it goes the other way is already
named: shard per executor, pad to 64 bytes, sum at scrape time.

## Binary size

The fourth axis of [ADR 017](../../docs/adr/017-the-trade-budget-has-four-axes.md),
and the one this change spends. Stripped `ReleaseFast`, every example rather
than the usual two, against `0492be0` **built from a `git archive` of that
commit into a scratch directory** rather than quoted from the table in
ADR 017 — the whole reason that rule exists is that the published figure and
the same binary rebuilt months later are not the same number.

| binary | `0492be0` | `dcadb46` | delta |
|---|---|---|---|
| `example-hello` | 886,680 | 887,920 | **+1,240** |
| `example-stream` | 907,032 | 908,320 | +1,288 |
| `example-chat` | 919,912 | 922,392 | **+2,480** |
| `example-forms` | 950,368 | 951,688 | +1,320 |
| `example-rest` | 1,032,968 | 1,034,304 | **+1,336** |
| `example-spa` | 1,044,992 | 1,046,248 | +1,256 |
| `example-orders` | 1,125,256 | 1,126,704 | +1,448 |
| `example-outbound` | 1,585,848 | 1,587,136 | +1,288 |
| `nilo-hello` (the benchmark server) | 890,384 | 892,896 | +2,512 |

**Every example pays, which is what "unconditional" means and is the point of
measuring all eight rather than two.** The floor is 1,240 bytes: cold paths
that used to be inlined copies are now real functions, and that is what buys
the connection loop's frame a single page. `chat` is the top of the range at
2,480 because it is the one example that opens a WebSocket and so links the
handover as well.

`nilo-hello` is +2,512 rather than +1,240 on nearly the same source, which is
worth noticing before somebody quotes the wrong one: it is `bench/main.zig`,
not `examples/hello`, and it is a different program. **A row in the ADR 017
table means the example, and the two names are one character apart.**

0.14% of the binary, for 4,096 bytes on every connection the process holds.

## Reproducing this

```bash
zig build -Doptimize=ReleaseFast

# server on four whole physical cores — check your own topology first,
# `cat /sys/devices/system/cpu/cpu0/topology/thread_siblings_list`
taskset -c 0-3,8-11 ./zig-out/bin/nilo-hello

# client on the other four
taskset -c 4-7,12-15 wrk -t4 -c64 -d30s --latency http://127.0.0.1:8787/users/42
taskset -c 4-7,12-15 wrk -t4 -c64 -d15s -s bench/mixed.lua http://127.0.0.1:8787

zig build profile -Doptimize=ReleaseFast
```

Memory per idle connection, HTTP and WebSocket, and the same figures for gws
beside them:

```bash
zig build bench-ws-server -Doptimize=ReleaseFast
( cd bench/compare/gws && go build -o gws-bench . )

# `both` starts and stops each server itself; `nilo` or `gws` does one.
STEPS=500,1000,2000 python3 bench/ws_idle.py both

# far enough out that marginal meets average — this is the run to trust,
# and both sides get it
STEPS=500,1000,2000,5000,10000 python3 bench/ws_idle.py nilo
STEPS=500,1000,2000,5000,10000 python3 bench/ws_idle.py gws
```

**Take it to 10,000 before quoting a marginal figure.** At 2,000 sockets two of
the rows above still carry the first message's buffer divided by too small an
N, and read 60 bytes high. The tell is that marginal and average disagree; when
they meet, the number is a property of a connection. Every step costs about
fifteen seconds, so the longer run is minutes rather than an afternoon.

WebSocket throughput, both servers driven by the same client so neither is
measured through a different implementation:

```bash
( cd bench/compare/wsload && go build -o wsload . )

IDLE_MS=0 taskset -c 0-3,8-11 ./zig-out/bin/nilo-bench-ws-server &
taskset -c 4-7,12-15 ./bench/compare/wsload/wsload \
    -url ws://127.0.0.1:8789/ws/small -conns 64 -d 20s -warmup 3s -payload 64

# the same client against gws, on the same cores; `-payload 1024` for the
# second pair of rows
taskset -c 0-3,8-11 ./bench/compare/gws/gws-bench &
taskset -c 4-7,12-15 ./bench/compare/wsload/wsload \
    -url ws://127.0.0.1:8790/ws -conns 64 -d 20s -warmup 3s -payload 64
```

**Pin both sides or the number is about the scheduler.** Unpinned, gws measures
1,029,308 msg/s on this machine and pinned it measures 1,558,146–1,563,759 — a
52% difference that has nothing to do with gws.

**Start them alternately, not one library's runs and then the other's.** This
box drifts by 8% over a few minutes; four consecutive runs of one server and
then four of the other would charge the drift to whichever went second. Every
comparison in this file is interleaved for that reason, and the HTTP
before/after table is four `before, after` pairs rather than three of each.

The live chain a suspended connection holds — the number that decides how many
pages it costs — is not exposed anywhere, and is read by printing it from
`releaseIdleStack` in `http/engine/zio.zig`:

```zig
std.debug.print("stack: size={d} live={d} release={d}\n", .{
    info.base - info.limit, info.base - frame, floor - start,
});
```

One connection of each kind against that build says where every byte is. It is
three lines and it is how ADR 062 was found, so it is written down here rather
than left in the engine.

`bench/bench.sh` runs the first of those with the repo's defaults and no
pinning. Unpinned on this machine it reports 1,071,374 req/s with a p99 of
1.55ms — 19% slower than the pinned figure with a tail an order of magnitude
worse, because the server asks for one thread per CPU and then the load
generator wants four more. The script is the convenient form; the pinned
commands are the ones that measure something.

## What checking `Host` costs the parser

**A different machine, and it matters more than usual.** Everything above is the
8-core Ryzen; this pair was run on a 2-core Xeon Platinum 8255C vCPU with the
load generator on the same box, which is the weakest possible place to take a
throughput number. It is written down anyway, because the change it prices is on
the request path of every request.

What changed:
[ADR 070](../../docs/adr/070-a-request-nobody-else-would-answer-is-refused.md)
put `'h'` into the parser's first-byte set, so a `Host` line now reaches
`applyHeaderAt` and costs a four-byte `eqlIgnoreCase` instead of being thrown
out for nothing, and `parseHead` gained one branch at the end of the head.

Both sides built `-Doptimize=ReleaseFast` from a `git archive` of the parent
commit and from the working tree, run interleaved.

### `zig build profile` — the row that moved

| run | before | after |
|---|---|---|
| 1 | 104ns | 107ns |
| 2 | 99ns | 106ns |
| 3 | 102ns | 115ns |
| 4 | 97ns | 106ns |

**Parse the head: 100ns → 109ns, and every "after" run is above every "before"
run.** That is the signal — about +8ns, which is roughly what one call and one
four-byte compare should cost. Head parsing is 13% of a request on this shape,
so it is around +1% of a request.

End to end over the same four rounds was 785/814/757/776 before and
785/805/814/797 after. The means differ by 2% and the ranges overlap almost
completely, so **that number is unchanged and should not be quoted as a
regression.** The two rows disagreeing is the point of having both: a signal
worth 8ns is visible in the row that contains it and invisible in the total.

### wrk — four interleaved pairs, and what they are worth

`-t1 -c32 -d10s`, server pinned to core 0 and wrk to core 1.

| pair | before | after | |
|---|---|---|---|
| 1 | 38,888 | 37,486 | −3.6% |
| 2 | 39,202 | 37,122 | −5.3% |
| 3 | 38,550 | 38,649 | +0.3% |
| 4 | 39,878 | 38,067 | −4.5% |

**The spread on either side alone is 3–4%, so this table says nothing.** The
sign changes, and a margin that size cannot be told from code layout on a shared
vCPU — an 8ns arithmetic difference cannot be 5% of a 26µs request. It is here
so that nobody re-runs it expecting an answer: on this box the throughput
question is not answerable, and `zig build profile` is what to run instead.

### Memory per idle connection — unchanged, and checked rather than argued

`python3 bench/mem.py --port 8787 --path /users/42 --steps 200,500,1000`, a
fresh server each time, alternating:

| | 200 | 500 | 1,000 |
|---|---|---|---|
| before | 9,134 B | 8,905 B | 8,843 B |
| after | 9,134 B | 8,905 B | 8,843 B |
| before, again | 9,134 B | 8,905 B | 8,851 B |
| after, again | 9,134 B | 8,970 B | 8,901 B |

The first pair is byte-identical at every step. `Request` gained a `has_host`
bool and `websocket.Options` gained a slice, and neither was expected to cost
anything — the bool lands in padding (`@sizeOf(Request)` is 48 both ways) and
the Options live in the handshake's frame, which unwinds before the connection
loop takes over (ADR 062). This is that reasoning checked.

**The absolute figure is this box's, not the framework's.** 8,843 bytes here
against the 4,669 published above, on two cores rather than eight and with a
different executor count under it. Only the before/after comparison on one
machine means anything; do not quote the column.

Binary size, stripped ReleaseFast `nilo-hello`: 905,600 → 905,808 bytes, +208
for all five changes in that commit together.

## What a body costs while it is arriving

**A different machine, and every figure in this section is only comparable
within it.** 5 September 2026, `4131913` plus the working tree: 2-core Intel
Xeon Platinum 8255C at 2.50 GHz, 7 GiB, generator on the same two cores as the
server. Everything above is the 8-core Ryzen. The absolutes here are much lower
than that machine's and mean nothing beside them; what is being read is the
ratio between two builds measured one after the other on this one, and the
`mmap` finding below is *sharper* on two cores than it would be on eight, which
is said out loud rather than left for somebody to discover.

`c.body()` took the announced `Content-Length` out of the request arena before
reading a byte of it. `bench/body_server.zig` is what put a number on both
halves of changing that — what a body that never finishes holds, and what the
change costs a body that arrives normally — and it carries three controls:
`/health` (no `Ctx`), `/drop` (the body arrives and nobody asks for it), and
`/stream` (`c.bodyStream()`, the shape that never had the problem).

### The instrument was wrong first, and that is the finding

`bench/mem.py` reads `VmRSS`, and the first run said this:

| route | before | after |
|---|---|---|
| `/echo`, `VmRSS`/conn | 17,281 | 17,281 |

**A megabyte that is mapped and never written to is not resident**, so the
whole gap was invisible to the instrument this repository reaches for first.
`bench/slowloris.py` reports `VmData` beside it for exactly that reason.
1,000 connections, each announcing `max_body` and delivering one byte:

| route | `VmData`/conn before | after | `VmRSS`/conn, either |
|---|---|---|---|
| `/echo` — `c.body()` | 1,852,080 | **283,378** | 17,281 |
| `/stream` — `c.bodyStream()` | 275,448 | 275,448 | 17,539 |
| `/drop` — never reads it | 275,120 | 275,120 | 17,281 |

`/drop` is the floor — the fiber's stack reservation and the connection's
buffers — so **the body's own share went from 1,576,960 bytes to 8,258**, two
pages, and `/echo` is now within 8 KiB of `/stream`. At 10,000 connections that
is 18.5 GB of address space against 2.8 GB.

**Resident memory does not move, and that is part of the result rather than a
caveat.** The attack costs the machine no RAM either way, because a byte that
was never sent is a page that was never touched. What it costs is anonymous
mappings, which is `vm.max_map_count` and a strict-overcommit deployment. The
roadmap's "ten gigabytes a server will commit" was right in kind and about the
wrong resource.

### Three growth policies, and the one that fits

`wrk -t2 -c32 -d8s`, four interleaved pairs per body size, `bench/body_load.lua`
against `/echo`. Means of four; the 1 KB row is the same single allocation in
every shape and is here to prove the harness moves when the code does not.

| shape | 1 KB | 64 KiB | 1 MB |
|---|---|---|---|
| before | 35,797 | 8,314 | 814 |
| fixed 16 KiB steps into an `ArrayList` | unchanged | 5,341 (**−36%**) | 442 (**−46%**) |
| explicit doubling from 16 KiB | unchanged | 5,613 (**−32%**) | — |
| one 16 KiB step, then the rest | unchanged | 6,538 (**−21%**) | 754 (**−7.4%**) |
| **one 4 KiB step, then the rest** | unchanged | **8,002 (−1.5%)** | **792 (−2.3%)** |

**The copying was never the cost.** Doubling turns a linear number of copies
into a logarithmic one and bought four points of thirty-six. What costs is the
number of *allocations that need a new arena node*: each one is an
`mmap`/`munmap` pair, and on two cores the TLB shootdown behind it is worth more
than the whole rest of the request.

That is also why the step size is the whole design. `arena_keep` defaults to
16 KiB and a POST has already spent a little of it on the head, so **a 4 KiB
first allocation fits in the block the arena is already holding and a 16 KiB one
does not** — same shape, same two allocations, and the difference between −21%
and −1.5% is whether the first of them calls the page allocator.

The step sweep at 64 KiB, three interleaved pairs each, is what settled it:

| step | pair 1 | pair 2 | pair 3 |
|---|---|---|---|
| 1 KiB | +8.1% | +0.7% | −3.2% |
| 4 KiB | −6.2% | +4.6% | −7.1% |
| 16 KiB | −21%, four pairs, no sign change | | |

1 KiB and 4 KiB both change sign inside the harness's own spread, so both are
**unchanged** rather than one being faster. 4 KiB is the one that shipped
because it buys four times the defence for the same nothing: a client must
deliver the step before `max_body` is committed, so the amplification a stranger
can buy is 256× rather than 1024×.

At the final size the four interleaved pairs at 64 KiB read 7,841/8,188,
7,972/7,934, 8,080/8,241 and 8,115/8,139 — two of the four are flat and the
margin is inside the drift. At 1 MB one of the four pairs is positive.

### Reproducing the body run

```bash
zig build -Doptimize=ReleaseFast bench-body-server
./zig-out/bin/nilo-bench-body-server        # listens on 8792

# what a body that never finishes holds — a fresh server per route, and read
# the `data` column, not only `rss`
python3 bench/slowloris.py --port 8792 --path /echo
python3 bench/slowloris.py --port 8792 --path /drop     # the floor
python3 bench/slowloris.py --port 8792 --path /stream   # the shape that never had it

# what it costs a body that arrives, at three sizes on either side of the step
BODY_BYTES=65536 wrk -t2 -c32 -d8s -s bench/body_load.lua http://127.0.0.1:8792/echo
```

## What an allowance costs

**A different machine, and that is the first thing to read.** Everything above
was taken on the 8-core Ryzen in [The machine](#the-machine). This section was
taken on a **2-core Intel Xeon 8255C at 2.50 GHz, 7 GiB, kernel 6.8.0-110,
wrk 4.1.0, Zig 0.16.0**, against `52ed106` plus the change. Nothing here is
comparable to a number anywhere else in this file, and the absolute throughput
figures are worthless — the load generator and the server are sharing two cores.
What the run is for is the *ratio*, and even that is blunter than it should be.

### Binary size: +0 unless it is used, and +5,712 when it is

The unconditional row is a real zero, checked rather than assumed. Removing the
`pub const allowance` line from `http/http.zig` and rebuilding gave
**byte-for-byte identical** binaries — 902,928 for `example-hello` and 1,043,424
for `example-rest`, stripped `ReleaseFast`, both ways. An unreferenced `pub`
namespace is never analysed, so there is nothing for the linker to drop.

Adding one `app.use(allowance.with(.{ .per_window = 100, .window_s = 60 }))` to
each:

| | without | with | delta |
|---|---|---|---|
| `example-hello` | 902,928 | 910,128 | **+7,200 B** |
| `example-rest` | 1,043,424 | 1,050,512 | **+7,088 B** |

Two programs agreeing within 112 bytes says the figure is the feature rather
than whatever generic it woke up, which is the mistake ADR 017 opens with.

**Both rows moved after the first measurement, and the movement is the useful
part.** The same three binaries first came out at +5,712, +5,584 and +5,760
(`bench/main.zig` was the third and was not retaken). Then a review of the
shipped design found three defects, and fixing them cost about **1,500 bytes**:
an IPv4 parser and an IPv4-mapped-IPv6 check where there had been a slice of
text, a tag byte per address family, and a per-process hash seed. That is 0.16%
of `hello` for the difference between a limiter whose table can be aimed at
offline and one whose cannot — recorded here rather than folded into the total,
because a number that moves is worth more than a number that was right first
time.

**The table is not in that number**, and that is worth saying plainly: 131,072
bytes of `.bss` is `NOBITS` in the ELF, so it costs nothing on disk and 128 KiB
of RSS the first time a page of it is touched. An operator reading the binary
size will not see the memory, and an operator reading `ps` will not see it in
the first second either.

### Throughput: unchanged, at a resolution too poor to be sure

Four interleaved pairs, 10s each, `wrk -t2 -c64`, a routed `GET /users/:id`
answering ~1 KB of JSON, both sides listening with `.trusted_hops = 1` and both
driven by the same Lua script — `bench/xff.lua`, which puts a different
`X-Forwarded-For` on every request so the allowance sees 65,536 addresses
instead of one. `.per_window = 1023, .slots = 1 << 17`, so nothing is refused.

| pair | base req/s | allowance req/s | margin | base p99 | allowance p99 |
|---|---|---|---|---|---|
| 1 | 29,418 | 30,924 | **+5.1%** | 7.19ms | 6.11ms |
| 2 | 30,869 | 30,448 | −1.4% | 6.71ms | 6.55ms |
| 3 | 30,930 | 31,160 | +0.7% | 6.20ms | 6.43ms |
| 4 | 30,918 | 30,672 | −0.8% | 6.57ms | 6.68ms |

**The sign changes between pairs and the spread is wider than the margin, so
the answer is "unchanged".** That is the rule this file already runs on, and
here it is doing less work than usual, because the instrument is bad: 30k req/s
on a server that does 1.4M on the Ryzen means **wrk is the bottleneck, not
nilo**. `wrk`'s per-request `request()` callback defeats its own precomputed
request buffer, and on two cores the client eats the machine. A cost of 50ns a
request would be invisible at this resolution.

So what the run actually establishes is narrower than the table looks: adding
the allowance did not cost anything *findable at 30k req/s*, and the guarded
path was exercised properly — 65,536 distinct addresses through a 131,072-slot
table, with real hashing and real cache misses rather than one hot slot.

**What would settle it** is the same run on the machine at the top of this file,
where the baseline is 1.4M req/s and 50ns is 7%. That is one command and a
different box, and it has not been done.

### What is checked rather than measured

Two of the four axes are held by tests instead, which is the stronger record:

- **Allocations per request: 1, unchanged.** `test "an allowance adds nothing to
  the allocation budget"` in `http/app.zig` sends a guarded request through a
  counting allocator and asserts one allocation and no resizes — the same
  numbers the unguarded path gets. The address is never copied and the slot it
  lands in existed before `main` ran.
- **Memory per idle connection: +0.** Nothing is held between requests, so there
  is nothing per connection to measure. The 131,072 bytes are per process.

### Reproducing the allowance run

```bash
# the size rows
zig build examples -Doptimize=ReleaseFast -Dstrip=true
stat -c "%n %s" zig-out/bin/example-hello zig-out/bin/example-rest
# …then add one `app.use(nilo.allowance.with(.{ … }))` line to each and repeat

# the throughput rows: build both servers first, then alternate them
wrk -t2 -c64 -d10s --latency -s bench/xff.lua http://127.0.0.1:8787/users/42
```

## What reading a body's numbers by nilo's grammar costs

ADR 084 moved a JSON body's integers and floats from `std.json`'s `parseInt` and
`parseFloat` onto `convert.spelledAsNumber` followed by the same two calls
(`json.parseLeaky`), so `"1_0"`, `"nan"`, `1e999` and a `u128` posted as `2e38`
are refused. A body read must not gain an allocation or a pass, so this is the
same body parsed both ways.

Run: `zig build profile -Doptimize=ReleaseFast -Dtarget=x86_64-linux-gnu` with a
temporary block (not kept) that parses one body 200,000 times with
`std.json.parseFromSliceLeaky` and then with `json.parseLeaky`, in the same
binary, alternating, best of nine. Ryzen 7 9700X, not pinned, a desktop in use,
Zig 0.16.0, on the tree at `462d84d` plus this change. Two runs:

| body | `std.json` | `parseLeaky` |
|---|---:|---:|
| an order: 220 bytes, three lines, strings, ints, floats | 589, 578 ns | 567, 562 ns |
| 30 integers and 16 floats: 177 bytes | 1003, 976 ns | 971, 948 ns |
| three strings and no number (control): 118 bytes | 143, 137 ns | 143, 139 ns |

**Unchanged to slightly faster**, 2 to 4 percent on the two bodies with numbers
and none on the control, which is inside the spread of an unpinned desktop. No
allocation was added (`the request path stays inside its allocation budget`
passes unchanged). It decided nothing but the question of whether to gate the
walk behind a "this type has a number" check: it is not gated, so every struct
body takes it.

**Can it be pushed further.** Not worth it: the walk is `std.json`'s own with
the two leaves swapped, and a faster number path is `std.json`'s scanner.

## Can these be pushed further

Ranked, so the next person starts here rather than at the top of the file.

**1. The 4,096 bytes is a floor, not a target.** A parked connection holds one
page of stack, and the live chain under it is 2,105 bytes on HTTP and 2,617 on
a WebSocket — both comfortably inside the page and neither anywhere near the
next crossing down, because there isn't one. **Halving the live chain again
would buy nothing**: the kernel charges a page. Anyone who reads the live-chain
table and reaches for another 500 bytes is optimising a number that no longer
converts into memory. This is the single most likely mistake to make from this
document.

**2. What is left is 573 bytes on HTTP and 1,087 on a WebSocket, and nobody
knows what they are.** Subtract the page from 4,669 and 5,183. That remainder
is the whole of the remaining budget and it has never been broken down — it is
the connection's own structures, whatever the read and write buffers do not
give back, and the 514-byte gap between the two rows is presumably `Socket`.
**Measuring it is cheap and has not been done**, which makes it the first thing
to run, not the first thing to optimise. It is also 21% of a WebSocket's cost,
so it is the only lever here with a number attached that is worth having.

**3. Below one page per connection needs a different architecture, and that is
a decision rather than a lever.** nilo parks a fiber per connection, and a
parked fiber holds at least one page. gws does not — a goroutine's stack starts
at 2 KB and grows — which is most of why its idle socket is within 1.6× of
nilo's despite a garbage collector. Going lower means not holding a fiber per
connection: a state machine per connection, and the whole of nilo's API is that
a handler is an ordinary function that can block. **The trade is the API, and
it is not on the table.**

**4. Throughput on the WebSocket path has never been profiled.** `zig build
profile` measures a request; nothing measures a message. The 5–8% margin over
gws is a black box — it could be the frame parser, the syscall count, or the
scheduler, and no lever can be ranked until something says which.

## What a field on `Request` costs per connection

Run for
[ADR 095](../../docs/adr/095-a-target-is-read-in-the-form-it-arrived-in.md),
which added a 16-byte `authority` slice to `http1.Request` so an absolute-form
target could be split. `Request` lives in the connection loop's frame and a
fiber holds its stack at its high-water mark
([ADR 062](../../docs/adr/062-where-a-connection-waits-is-what-it-costs.md)), so the
question was whether 16 bytes there is 16 bytes per connection.

`bench/mem.py --port 8787 --path /users/1` against `bench/main.zig`,
`-Doptimize=ReleaseFast`, this commit against a `git archive` of its parent,
same box, one run each.

| connections | before | after |
|---:|---:|---:|
| 500 | 8,905 B | 9,028 B |
| 1,000 | 8,839 B | 8,901 B |
| 2,000 | 8,835 B | 8,835 B |
| 5,000 | 8,795 B | 8,795 B |
| 10,000 | **8,781 B** | **8,781 B** |

**Identical from two thousand connections onwards, and whole-process RSS at ten
thousand was 89,272 kB against 89,280 kB** — eight kilobytes apart across ten
thousand connections. The frame was rounded well past 16 bytes already and this
landed inside the rounding.

The 500- and 1,000-connection rows disagree by 123 and 62 bytes **in the same
direction as the change**, which is exactly the trap the WebSocket section
below documents: at small counts the per-connection figure is still carrying
the process's fixed cost, and a real 16-byte regression would not have vanished
by 2,000. Reading the first row alone would have published a 123-byte cost for
a 16-byte field.

8,781 rather than the 4,669 this document quotes for an idle connection because
`/users/:id` builds a JSON response and the handler's stack is part of what the
connection holds. Same reason, one route over.

## What validating a string as UTF-8 costs

Run for
[ADR 096](../../docs/adr/096-a-byte-that-is-not-text-is-not-a-string.md),
which made `json.zig` ask `std.unicode.utf8ValidateSlice` before writing a
string so that a byte that is not text comes out as `std.json`'s array of
numbers rather than as invalid JSON. The question the run had to answer was
whether the check is affordable on the request path.

Standalone program, `-OReleaseFast`, `taskset -c 0`, best of 25 rounds of
200,000 calls, three interleaved runs. 2-core Xeon Platinum 8255C vCPU — the
same weak box as the `Host` section above.

| input | bytes | ns |
|---|---:|---:|
| the primary metric's payload, all ASCII | 365 | **10** |
| a short field value | 9 | 5 |
| 1 KB with one `é` halfway through | 1,024 | 278 |
| 1 KB with one `é` near the front | 1,024 | 704 |
| 1 KB of nothing but `é` | 1,024 | 2,404 |

The last two runs agreed within 1% on every row.

**The cost is not a function of length. It is a function of where the first
byte over `0x7f` falls.** `utf8ValidateSlice` clears 32 bytes of ASCII at a
time with a vector compare and hands everything from the first non-ASCII byte
onwards to a byte-at-a-time decoder — which is why the same kilobyte costs
278ns with the accent halfway and 704ns with it near the front.

**What it decided:** ship it. 10ns against the 126ns that writing the whole
payload costs is +8%, under
[ADR 017](../../docs/adr/017-the-trade-budget-has-four-axes.md)'s bar,
and the case it fixes is a response that could not be parsed at all.

**What it changed about how the next one gets run:** best of five was not
enough. The first attempt read 38ns for the ASCII row and 6,585ns for the
all-`é` row — 3.8× and 2.7× the settled figures, and 38ns would have put the
ASCII case at 30% of the write, which is the wrong side of the bar and would
have blocked the fix. Three of this author's own `zig build test-all` runs were
on the box at the time. **A microbenchmark on a shared box needs its minimum
taken over enough rounds to find an unpreempted one, and needs running again
afterwards to see whether it moved.**

### Can it be pushed further

Yes, and only on the non-ASCII rows. A vectorised UTF-8 validator of the
Keiser–Lemire shape runs at roughly a byte a cycle whatever the input, which
would take the all-`é` kilobyte from 2,404ns to something near the ASCII row
instead of 19× the whole JSON write. Nothing here needs it — the payloads this
repository measures are ASCII — so it is a roadmap entry rather than work, and
this is the number that would justify it.

The ASCII rows have no headroom worth chasing: 10ns for 365 bytes is already
the vector path, and the only way past it is not to ask the question, which is
what the bug was.

## What finding a service costs per request

Run to settle a roadmap entry that had carried "it may well be nothing" for a
cycle with no number under it. `service.Registry.get` walks `entries` comparing
type names — a pointer compare, with a content compare behind it that never
fires because `@typeName` hands back the same literal — once per service
argument per request. `listen()` has already checked every one of those
arguments before the first request is served, so the question was whether work
that a startup pass could index is worth indexing.

`zig build profile`'s new **finding one service out of several** row.
ReleaseFast, best of five rounds of 1,000,000 lookups, warmed first, and the
whole profiler run five times. AMD Ryzen 7 9700X, kernel 7.0.0-30-generic, Zig
0.16.0, commit `95286b6`. In process, so no loopback, no client, and none of the
caveats the throughput tables carry.

The wanted service is registered **last**, so the scan runs to the end every
time. That is the ceiling for a given count rather than the average, which is
about half of it.

| services registered | ns per lookup | of the 289ns request |
|---:|---:|---:|
| 1 | 0.3 | 0.1% |
| 4 | 4.5 | 1.6% |
| 8 | 10.3 | 3.6% |
| 16 | 16.7 | 5.8% |
| 32 | 38.8 | 13.4% |

Five runs agreed within 4% on every row, which is the tightest spread anything
in this file has: it is a loop over 40-byte structs in L1 with a perfectly
predicted branch, and there is nothing in it for the scheduler to disturb.

**It is not nothing, and the entry does not close.** Past the first service the
cost is flatly linear at **1.2ns an entry**, which is a dependent load, a
compare and a branch that nothing unrolls. What the number changes is that
"probably free" was only ever true for small apps: at four services the lookup
is 1.6% of a request, comfortably under
[ADR 017](../../docs/adr/017-the-trade-budget-has-four-axes.md)'s 10%
bar, and at thirty-two it is 13.4%, over it. **And it is per service argument,
not per request** — a handler taking a database and a cache pays twice.

So the shape of the answer is a threshold rather than a yes or a no. Somewhere
between sixteen and thirty-two registered services, in the worst-case ordering,
this stops being noise.

### Can it be pushed further

To zero, and the shape was already named in the roadmap before the run: which
services a route needs is settled while compiling and checked at `listen()`, so
the pointers could be resolved into the route once at startup and the request
path would do no lookup at all. Nobody has built it and this run is not the
justification for building it today — four services is what the apps in
`examples/` have, and 4.5ns is not where the 289ns goes.

What the run is good for is that the next person arrives at a threshold instead
of at "it may well be nothing", which is a sentence that cannot be acted on in
either direction.

## What a `Date` costs, and what leaving `Connection` off gives back

[ADR 197](../../docs/adr/197-a-response-says-when-it-was-sent.md) put a
`Date` on every response and took `Connection: keep-alive` off HTTP/1.1
ones. The wire goes from 1,110 bytes to 1,123 on the benchmark response —
checked with `nc | wc -c`, not arithmetic — which is what Go, axum, Fiber
and Bun send for the same body. The question was whether the clock read,
the compare and the extra `writeAll`s per response show up.

**Not the machine above.** A 2-vCPU cloud VM — Intel Xeon Platinum 8255C,
`kvm-clock` (so `clock_gettime` is a vDSO read, checked with `strace -c`:
no syscalls), 8 GB, kernel 6.8.0-110, Zig 0.16.0, wrk 4.1.0 — with wrk on
the same two cores as the server. The absolute figures are a fortieth of
the table at the top and mean nothing outside this section; the *pairs*
are what the run is for. Before is `ab3c893` from `git archive`, after is
the same tree with ADR 197 on it, both `ReleaseFast`, stripped. Each run:
3 s warm-up discarded, then `wrk -t1 -c64 -d10s --latency`, server and
client restarted between every run, before and after alternating.

| pair | before req/s | before p99 | after req/s | after p99 | after vs before |
|---:|---:|---:|---:|---:|---:|
| 1 | 47,455 | 3.76ms | 45,403 | 3.94ms | -4.3% |
| 2 | 47,058 | 3.75ms | 46,246 | 4.04ms | -1.7% |
| 3 | 47,287 | 3.71ms | 46,834 | 3.78ms | -1.0% |
| 4 | 47,209 | 3.83ms | 45,417 | 3.77ms | -3.8% |
| 5 | 46,370 | 3.71ms | 46,127 | 3.79ms | -0.5% |
| 6 | 44,324 | 3.94ms | 47,956 | 3.74ms | +8.2% |
| 7 | 46,450 | 3.88ms | 46,181 | 3.96ms | -0.6% |
| 8 | 46,392 | 3.92ms | 47,899 | 3.84ms | +3.3% |

Means: 46,568 before, 46,508 after, **-0.1%**. The first four
pairs all read the after side low, by 1–4%, and the second four read it
high twice by more than that; the sign changes and the margin is inside the
spread, so by this file's own rule the answer is **unchanged**. p99 sits in
the same 3.7–4.0 ms band on both sides. That is the expected answer — 15 ns
of clock and one compare on a request this box serves in ~21 µs of CPU — and
the run exists so the next person does not have to guess it.

**Binary size is the axis that moved: +6,064 bytes on `example-hello`,
+6,072 on `example-rest`**, stripped `ReleaseFast`, against a guess of 400.
`nm --size-sort` on unstripped builds splits it: `date.writeLine` is 1,842
bytes, because `std.time.epoch`'s `calculateYearDay` and `calculateMonthDay`
loop over years and months and both inline; the errno name table
`__zig_tag_name_os.linux.E` is about 2,000, pulled in by `core.nowMicros`'s
panic message and paid for the first time here because nothing on the
request path had read the wall clock before; `sendFinal` grows 342 and the
head writers by a call each. The row is in ADR 017's running total.

### Can it be pushed further

The two levers are the two big symbols. Howard Hinnant's `civil_from_days`,
which `sql/types.zig` already carries, is a few divisions with no loop and
would take `writeLine` well under 500 bytes; and `core/clock.zig` printing
the errno as a number rather than `@tagName` would drop the 2 KB table —
for a panic that cannot fire. Neither is done, because 6 KB on a megabyte is
0.6% and the wire and throughput axes are where a response header would
have hurt, and did not.

## What the two atomics a request always makes cost, on two cores

Every request does `stop.in_flight.fetchAdd(1, .acq_rel)` when its head has
arrived and `fetchSub` when it is answered (`http/serve.zig`), on one `u32`
every thread writes — the count a graceful stop waits for, and the number
`max_in_flight` sheds against. actix-web has no atomic on its request path
at all: a connection never leaves the thread that accepted it, so its
counters are `Rc`s. The question was whether nilo's two read-modify-writes
on a shared cache line show up.

**The experiment.** `Stop` grew sixty-four lanes of `i32`, each padded to a
cache line, and a `threadlocal` index handed out on a thread's first
request; with `max_in_flight` off — the default, and the benchmark's — the
request added to and subtracted from its own thread's lane, and `drain()`
summed the lanes. Signed, because a fiber that starts on one thread and
finishes on another leaves +1 and −1 in two lanes. With `max_in_flight`
set the shared counter stayed, since the shed check needs the old value in
one operation. Forty lines, on the tree at `79c663e`.

**The box is the one the `Date` section above names** — two vCPUs, wrk on
the same two — and that is the weakest place to look for cache-line
contention, which the roadmap row for `app.metrics`' atomics already says.
Same protocol as above: eight interleaved pairs, 3 s warm-up, `wrk -t1
-c64 -d10s`.

| pair | before req/s | before p99 | after req/s | after p99 | after vs before |
|---:|---:|---:|---:|---:|---:|
| 1 | 46,100 | 3.80ms | 46,458 | 3.84ms | +0.8% |
| 2 | 48,438 | 3.68ms | 46,494 | 3.79ms | -4.0% |
| 3 | 46,710 | 3.77ms | 46,270 | 3.75ms | -0.9% |
| 4 | 44,886 | 3.78ms | 46,707 | 3.78ms | +4.1% |
| 5 | 45,935 | 3.79ms | 44,189 | 4.12ms | -3.8% |
| 6 | 46,915 | 3.69ms | 45,727 | 3.90ms | -2.5% |
| 7 | 46,591 | 3.82ms | 45,484 | 3.71ms | -2.4% |
| 8 | 45,842 | 4.02ms | 46,016 | 3.68ms | +0.4% |

Means: 46,427 before, 45,918 after, **-1.1%**, three pairs up and
five down. Inside the spread: **unchanged**, and the lanes were not landed.

**What the run does say.** Two threads on one line is not contention, so
the run cannot see the gain; what it can see is the lanes' own cost — a
`threadlocal` read, a null check, and an uncontended RMW in place of a
contended one — and that is also inside the noise. Arithmetic for the box
that matters: at 1.4M requests a second on sixteen threads that is 2.8M
RMWs a second on one line, and at 50–100 ns each under contention it is
0.14–0.28 s of CPU a second across sixteen cores, **1–2% of the machine**.
That is the ceiling on what the lanes can give back, and it is the same
1.5% [`cache.md`](./cache.md) measured for per-thread lanes on eight
threads. Inside ADR 017's 10% either way; a number worth having, not a
number worth a second design.

### Can it be pushed further

The run that decides is the roadmap's: the same pair on the eight-core
box, together with `app.metrics`' four atomics, which share the diagnosis
and the fix. If that run reads under 2%, the lanes stay out and the row
closes; over it, the forty lines above are the shape, with one addition —
the `threadlocal` index should come from the Engine's executor number
rather than a global counter, so a test thread and a worker thread cannot
share a lane.

## What a listen backlog of 128 drops

[ADR 198](../../docs/adr/198-a-backlog-is-sized-for-the-burst-not-the-load.md)
raised the listen backlog from zio's default of 128 to 4,096. The question
was not throughput — a backlog is a queue capacity and costs nothing per
request — but what a burst of connections does against each number, which
is the shape HttpArena's paced profiles have (1,024 sockets opened in one
go) and the shape a deploy has (every client reconnecting at once).

**The box is the two-vCPU one the `Date` section names**, kernel 6.8.0-110,
`net.core.somaxconn` 4096, `tcp_syncookies` 1, with the client on the same
two cores as the server. Before is `d4700a2` from `git archive`, the two
afters are the same tree with `backlog` at 1,024 and at 4,096, all
`nilo-hello`, `ReleaseFast`. The instrument is `bench/burst.py`: `--conns`
non-blocking `connect()`s back to back, polled to completion, with
`ListenOverflows` and `ListenDrops` from `/proc/net/netstat` read before
and after. A connect over half a second is one the kernel dropped and the
client's TCP retried, since the SYN retransmit timer is one second and
nothing else on loopback takes that long.

Bursts of 1,000, one burst per server start:

| backlog | run | connected | p50 | p99 | retried (>0.5 s) | `ListenDrops` |
|---:|---:|---:|---:|---:|---:|---:|
| 128 | 1 | 1000/1000 | 1,075.7 ms | 1,080.2 ms | **623** | +1,719 |
| 128 | 2 | 1000/1000 | 1,039.6 ms | 1,044.6 ms | **631** | +1,279 |
| 128 | 3 | 1000/1000 | 1,056.5 ms | 1,058.1 ms | **623** | +1,287 |
| 1,024 | 1 | 1000/1000 | 56.3 ms | 57.4 ms | 0 | 0 |
| 1,024 | 2 | 1000/1000 | 44.7 ms | 45.8 ms | 0 | 0 |
| 1,024 | 3 | 1000/1000 | 66.4 ms | 67.6 ms | 0 | 0 |
| 4,096 | 1 | 1000/1000 | 51.6 ms | 52.4 ms | 0 | 0 |

The 128 rows are the finding: **a median connect of one second**, from a
server whose accept loop was idle, with nothing in its log. The client
count (623) and the kernel count (1,279–1,719) disagree because a retried
SYN can be dropped again, and because a burst of 1,000 against a queue
of 128 that is being drained overflows more than once per connection. The
p50s under the other two rows are the Python client's own pace — a
thousand `connect()` calls on a shared two-core box — and say nothing
about the server.

Then 4,000 in one go, which is `limited-conn`'s connection count,
interleaved:

| backlog | run | connected | p50 | p99 | retried (>0.5 s) | `ListenDrops` |
|---:|---:|---:|---:|---:|---:|---:|
| 1,024 | 1 | 4000/4000 | 336.7 ms | 1,269.1 ms | **187** | +187 |
| 1,024 | 2 | 4000/4000 | 301.5 ms | 307.7 ms | 0 | 0 |
| 1,024 | 3 | 4000/4000 | 307.0 ms | 316.8 ms | 0 | 0 |
| 1,024 | 4 | 4000/4000 | 245.9 ms | 1,238.6 ms | **420** | +420 |
| 4,096 | 1–6 | 4000/4000 | 206–352 ms | 212–364 ms | 0 | 0 |

At 1,024 two runs of four dropped; at 4,096 none of six did. Whether the
1,024 row drops depends on how far the accept loop gets before the client
finishes issuing connects, which on a shared box is the scheduler's call —
on a box where the client is faster than this one, it would drop more.
That is what moved the default from actix's 1,024 to the kernel's own
4,096.

**What the run does not say.** Nothing about the arena's `limited-conn`
figure, which reconnects 4,096 connections continuously rather than once;
the accept loop's own throughput is the other half of that profile and it
is untested here. It is the next section to write, and the arena's next
run of nilo is the reading that decides both.

### Can it be pushed further

Not the number — 4,096 is `somaxconn`'s default and the kernel clamps
above it. What can move is the accept loop behind the queue: one fiber,
one `accept` with a 200 ms timeout armed on every call for the stop flag's
sake. A burst that drains slowly is a burst that overflows a bigger queue;
`bench/burst.py --conns 8000` against a server with the loop's drain rate
measured is where that would show, and an accept per executor
(`SO_REUSEPORT`, or handing accepted sockets round-robin the way actix
does) is the shape if it does.

## What a request costs when the server is not busy

Every figure above is taken at saturation, and a server at saturation is
the one place a wakeup is free: the thread was awake anyway. HttpArena's
`latency-10k` profile asks the other question — 1,024 connections at
10,000 req/s over sixty-four threads — and reported nilo at 40 µs of CPU
a request against 18 µs for the same server near saturation on eight CPUs,
where tokio reads 21 in both. [ADR 199](../../docs/adr/199-a-connection-is-served-by-the-thread-it-was-dealt-to.md)
is the decision; this is the run.

**The instrument is `bench/paced.py`**: a fixed offered rate, round-robin
over keep-alive connections with one request in flight per connection,
and the server's `utime + stime` from `/proc/<pid>/stat` — plus its
voluntary context switches from `/proc/<pid>/task/*/status` and its minor
faults — read before and after the window. Python paces it, so the client's
own cost shows in the latency columns and nowhere else. **The box is the
two-vCPU one the `Date` section names**, `nilo-hello` from `91f7c0d` with
two env knobs patched into a scratch copy of the tree (`NILO_THREADS`,
`NILO_MIGRATION`) so that four variants came out of one build.

`/health`, 64 connections, 6 s windows after 2 s warm-up:

| threads | migration | rate | CPU/req | switches/req | p50 | p99 |
|---:|---|---:|---:|---:|---:|---:|
| 2 | on | 500 | **100.0 µs** | 2.02 | 140 µs | 768 µs |
| 2 | on | 2,000 | 64.2 µs | 1.23 | 133 µs | 751 µs |
| 2 | on | 8,000 | 43.8 µs | 0.62 | 212 µs | 1,420 µs |
| 2 | off | 500 | **70.0 µs** | 1.02 | 124 µs | 876 µs |
| 2 | off | 2,000 | 55.0 µs | 0.87 | 142 µs | 795 µs |
| 2 | off | 8,000 | 34.0 µs | 0.39 | 200 µs | 1,352 µs |
| 1 | on | 500 | 70.0 µs | 1.02 | 126 µs | 875 µs |
| 1 | on | 2,000 | 41.7 µs | 0.51 | 111 µs | 606 µs |
| 1 | on | 8,000 | 24.6 µs | 0.13 | 181 µs | 1,007 µs |
| 1 | off | 500 | 66.7 µs | 1.02 | 125 µs | 592 µs |
| 1 | off | 2,000 | 41.7 µs | 0.51 | 113 µs | 662 µs |
| 1 | off | 8,000 | 25.0 µs | 0.15 | 187 µs | 1,114 µs |

The first block against the second is the finding: **two voluntary
context switches a request against one, and 30% more CPU for it.** The
second switch is zio's doze — a 100 µs timed park an executor takes after
running work, so its own loop can hand tasks back before a thief takes
them — and on a thread with nothing coming it is a sleep, a timer, a wake
to nothing and a second sleep. The one-thread rows are the control: with
nobody to steal from zio skips the doze, and migration on and off read
the same to the microsecond. The remaining gap between one thread and
two with migration off (25 vs 34 µs at 8,000) is batching: one executor
at 8,000 req/s stays awake for several requests (0.13 switches a request),
two executors at 4,000 each do not (0.39).

The same at 1,024 connections on `/users/1`, which is the arena's
connection count and a JSON body, twice each:

| migration | rate | CPU/req | switches/req | faults/req |
|---|---:|---:|---:|---:|
| on | 2,000 | 146.7 / 150.0 µs | 2.59 / 2.64 | — |
| off | 2,000 | 116.7 / 117.5 µs | 1.61 / 1.59 | 3.00 |
| on | 8,000 | 53.8 / 54.8 µs | 0.98 / 1.02 | — |
| off | 8,000 | 49.4 / 50.2 µs | 0.76 / 0.78 | — |

Same direction, −20% at 2,000 and −8% at 8,000. **And a second finding
the row was not looking for**: at 2,000 req/s over 1,024 connections a
request costs 117 µs against 59 at 64 or 256 connections, on the same
route at the same rate. The difference is that a connection sees a
request every 512 ms at 1,024 and every 32 ms at 64, and `idle_peek_ms`
is 200: past it the connection hands its pages back (ADR 062) — a timer
wake, three `madvise` calls, and three minor faults on the next request,
which on this VM is ~57 µs. That is the trade ADR 062 made, memory for
CPU on a connection that has gone quiet, and it is the right trade for a
person behind a browser; it is now a number rather than a sentence. Not
acted on. The arena's `latency-10k` sits at ~100 ms between requests on a
connection, inside the window, so it does not pay this.

Saturation, so the other side of the trade is on the record: `wrk -t1
-c64 -d8s` after a 3 s warm-up, two threads, four interleaved pairs.

| pair | migration on | migration off | off vs on |
|---:|---:|---:|---:|
| 1 | 46,132 req/s, p99 4.22 ms | 47,267, p99 3.59 ms | +2.5% |
| 2 | 46,465, p99 3.97 ms | 48,322, p99 3.91 ms | +4.0% |
| 3 | 47,072, p99 3.73 ms | 47,457, p99 3.80 ms | +0.8% |
| 4 | 45,757, p99 4.08 ms | 47,653, p99 3.63 ms | +4.1% |

Four of four the same sign, mean +2.9%. Not the spread-changing-sign
result the `Date` and atomics sections got on this box: turning stealing
off takes the `seq_cst` traffic on `idle_mask` and the searcher election
out of every park, and a busy executor parks often.

### Can it be pushed further

Yes, and the levers are ranked by the table. The single-executor row at
8,000 req/s is 25 µs a request and the two-executor row is 34, so **9 µs
a request is the price of the second thread's wakeups** — an executor
that could be told "stay awake a little" would batch the way one thread
does. That is Go's spinning-M and it burns CPU to save CPU; the honest
version is a `poll` with a short timeout only when the *previous* poll
returned work, which is zio's doze with the condition inverted, and is
the upstream issue ADR 199 describes. Below that, the 25 µs floor is
one `io_uring_enter` to wake and one to submit, and one context switch;
what is left is the request itself.

The `idle_peek_ms` finding has a lever too: `MADV_FREE` instead of
`DONTNEED` for the two buffers would make the give-back lazy — no fault
on the next request unless the kernel actually took the page — at the
cost of `VmRSS` no longer showing the saving, which is the number ADR
062 was measured by. A run with `--conns 1024 --rate 2000` before and
after, plus `bench/mem.py` to see what RSS does under pressure, would
settle whether the 57 µs is worth the honesty of the RSS figure.

## What one accept fiber caps a server at

[ADR 200](../../docs/adr/200-every-executor-accepts.md) is the decision;
this is the run, and the arena reading that led to it.

**The instrument on this box is [gcannon](https://github.com/MDA2AV/gcannon)**
(`11c802b`, built native against liburing 2.15), which is what HttpArena
drives every H/1.1 profile with, so the shape is the arena's: `-t 8`, five
seconds, `-r 10` for a connection closed after ten requests. The server is
`nilo-hello` (`bench/main.zig`, `/health`) in `ReleaseFast`, pinned to CPUs
0–7 with gcannon on 8–15, on an AMD Ryzen 7 9700X (8 cores, 16 threads,
SMT on) under Linux 7.2.5 (Omarchy). CPU is `utime + stime` from
`/proc/<pid>/stat` across the run. Before is `7e084ce`, one acceptor;
after is the working tree with one acceptor per executor. The pairs are
interleaved.

| shape | before | after |
|---|---|---|
| short-lived, 512 conns × 10 req | 664K / 668K / 660K req/s, p50 17 µs, p99 8.2 ms, **12.6 core-s** | **1.97M / 1.97M / 1.97M**, p50 121–127 µs, p99 1.5–1.8 ms, 30.0 core-s |
| short-lived, 4,096 conns × 10 req | 708K, p50 18 µs, p99 61 ms | 1.75M, p50 257 µs, p99 41 ms |
| keep-alive, 512 conns | 2.65M / 2.64M / 2.62M, 29.5 core-s | 2.64M / 2.64M / 2.64M, 29.3 core-s |

**2.95× on the shape that churns connections, unchanged on the one that
does not**, which is the whole of what the change was meant to do. The
before row's CPU is the finding in one number: 12.6 core-seconds over five
seconds is 2.5 cores of the 8 the server had, and its p99 is
512 / 66K connections a second = 7.8 ms — the time a handshake waited in
the backlog for the one fiber to get round to it. After, the server is at
6 of 8 cores and the p50 has moved from 17 µs to 121, because the first
request of every connection is now served rather than queued, and it costs
what a connection costs.

### The arena's two readings, and what changed between them

HttpArena ran nilo twice on 2026-09-21, first at `da101ff` and then at
`f1152a7`, which is the same tree plus the `Date` header (ADR 197), the
4,096 backlog (ADR 198) and stealing off (ADR 199). Sixty-four logical
CPUs for the server (`0-31,64-95` on a Threadripper PRO 3995WX), 5 s runs,
best of three on throughput.

| profile | `da101ff` | `f1152a7` | |
|---|---|---|---|
| baseline, 4,096 | 3.06M, p50 0.53–0.61 ms, 126 MiB | 3.17M, **p50 1.27 ms**, 186 MiB | +3.7%, latency 2× |
| pipelined, 4,096 (ref.) | 3.99M, p50 5.5 ms, p99.9 225 ms | 3.90M, p50 16.6 ms, **p99.9 1.13 s** | |
| limited-conn, 4,096 | 451K, p50 45 µs, **p99 3 ms**, 1832% | 426K, p50 48 µs, **p99 100 ms**, 1805% | |
| async-db, 1,024 (ref.) | 66.2K, p99 50 ms | 59.7K, p99 245–362 ms | −10% |
| echo-ws, 512 / 4,096 / 16,384 | 3.54M / 3.60M / 3.52M, 188 MiB at 16K | 3.57M / 3.73M / 3.44M, **483 MiB** at 16K | |
| latency-1m | 39.8 µs/req, rate 0.979, p99.9 2,035 µs | **30.6 µs/req**, rate 0.998, p99.9 320 µs | −23% CPU |
| latency-10k | 40.4 µs/req, rate 0.976 | **34.5 µs/req**, rate 0.998 | −15% CPU |
| latency-500k-8cpu (ref.) | rate 0.884, p99 6.6 s | rate 0.899, p99 2.0 s | still short |
| async, 32,000 | 1.88M, mean 13.4 ms, p99.9 23 ms | 1.83M, mean 16.0 ms, p99.9 277–534 ms | −3% |

Three things to read off it, one of which was predicted.

**ADR 199 landed where it said it would, and its other side is now
measured.** The prediction was 25–30 µs on `latency-10k` from 40; the
reading is 34.5, and 30.6 on `latency-1m`, with the rate held at 0.998 on
both for the first time (ADR 198's backlog). Everything saturated paid
for it: at the same throughput the baseline's p50 doubled, pipelined's
tail went from a quarter of a second to over one, and the async profile's
timers fire 6 ms late instead of 3. `bench/paced.py` measured a server
that is not busy; this is the busy one, and the account is that an
executor with a burst on its ring drains it alone while its neighbours
sleep. The trade stands — the fixed-rate profiles are the ones the arena
weights, and the tails are reference columns — but it is a trade, and the
saturation pairs in the section above did not show it because 64
connections on two threads is not a burst.

**`limited-conn` is not about the change at all, and its p99 says what it
is about.** 451K and 426K are the same number; the p99 moved from 3 ms to
100 ms because the backlog moved from 128 to 4,096, and each p99 is that
backlog divided by ~43K connections a second. One accept fiber at ~23 µs a
connection is the ceiling, on 18 of 64 cores, and ADR 200 is the answer.
The next arena run is the reading this box cannot take.

**Memory per active connection is ~29.5 KiB, not 4,669 bytes.** 483 MiB
over 16,384 echoing WebSockets and 924 MiB over 32,000 sleeping fibers
both divide to it. The 4,669 figure is an idle connection whose pages went
back (ADR 062); a connection inside a request or a `sleep` holds its
fiber's stack to its high-water mark plus both buffers, and that is what
the arena's memory column reads. It feeds only the board's optional memory
bonus, and it is ADR 017's third axis for a connection that is *not* idle,
which no number here had put beside the idle one.

### Can it be pushed further

On this box the after row is 6 of 8 cores at 1.97M with gcannon on the
other eight, so the next factor is not in the server. On the arena's
sixty-four the remaining per-connection cost is the handoff — a task
pushed onto another executor's queue and an eventfd write to wake it —
which a spawn homed on the accepting executor would remove; that is the
upstream row in the roadmap. Below that is the kernel's accept queue lock
on one listener, and `SO_REUSEPORT` is the lever if a profile ever puts it
there.

## What a flush per response costs a client that pipelines

[ADR 201](../../docs/adr/201-a-response-is-flushed-before-the-connection-waits.md)
is the decision; this is the run.

Same instrument and same split as the section above: gcannon (`11c802b`,
native, liburing 2.15) on CPUs 8–15, the server on 0–7, `ReleaseFast`,
eight-second runs, CPU as `utime + stime` from `/proc/<pid>/stat` across
the run. Before is `0efa4c0` (every executor accepts, every response
flushed), after is the working tree; each row is three interleaved pairs
unless it says two. `-p 16` is the arena's `pipelined` and
`echo-ws-pipeline` shape: sixteen requests or frames in one write, refilled
as answers come back. The HTTP server is `nilo-hello` on `/health`; the
WebSocket server is `bench/ws_server.zig` on `/ws/small`, echoing.

| shape | before | after |
|---|---|---|
| HTTP, 256 conns, `-p 16` | 3.06 / 3.04 / 3.05M req/s, p50 1.34 ms, p99 1.76–1.85 ms, p99.9 3.0–3.2 ms, 43.3–43.7 core-s | **13.58 / 12.75 / 12.31M**, p50 299–331 µs, p99 365–384 µs, p99.9 498–533 µs, 58.7–59.4 core-s |
| HTTP, 4,096 conns, `-p 16` (two pairs) | 2.06 / 2.05M, p50 14.8 ms, p99 107 ms, p99.9 338 ms | **10.99 / 10.37M**, p50 2.5–2.6 ms, p99 39 ms, p99.9 81–83 ms |
| WS echo, 256 conns, `-p 16` | 3.61 / 3.59 / 3.59M msg/s, p50 1.13 ms, p99 1.32–1.54 ms, 39.7 core-s | **37.27 / 37.12 / 37.36M**, p50 108 µs, p99 200–223 µs, 48.6 core-s |
| WS echo, 4,096 conns, `-p 16` (two pairs) | 2.93 / 2.91M, p50 11.0 ms, p99 81.5 ms | **31.14 / 30.77M**, p50 0.86 ms, p99 33 ms |
| HTTP, 256 conns, keep-alive | 2.61 / 2.61 / 2.61M, p99 161–193 µs, 46.3 core-s | 2.59 / 2.60 / 2.60M, p99 157–212 µs, 46.3 core-s |
| WS echo, 256 conns, one frame at a time | 2.75 / 2.75 / 2.74M, p99 183–204 µs, 45.6 core-s | 2.75 / 2.75 / 2.75M, p99 194–205 µs, 45.6 core-s |

**The syscall was the request.** Divide CPU by responses: a pipelined
`/health` cost 1.78 µs of server CPU before and 0.57 after; a pipelined
echo 1.38 µs before and 0.16 after. The echo is a memcpy of five bytes and
a frame header, so the syscall was nearly all of it, which is why the
WebSocket factor is ten and the HTTP one four. The tails move by the same
factors, because a response that used to wait behind fifteen `send(2)`s
now waits behind fifteen memcpys.

**The other two rows are the check that nothing else moved.** Neither
shape ever has a second request buffered when it answers, so both flush on
`send` exactly as before, and the change they see is the compare of
`in.seek` against `in.end` on every response and the load of the writer's
fill on every read that reaches the socket. WebSocket: identical to the
third digit and to the CPU tick. HTTP: 0.4% down with the sign the same in
all three pairs, at the same CPU. That is within the spread the section
above quotes for the same shape (2.62–2.65M) and inside ADR 017's 10% by
a factor of twenty, but it is not nothing, and it is written down as the
price rather than rounded away.

**Memory per idle connection does not move.** `bench/mem.py` against both
binaries at 2,000, 5,000 and 10,000 keep-alive connections: 5,218 / 5,198 /
5,191 bytes on before and the same three numbers on after. (5,191 on this
box against the 4,674 the section on idle connections quotes for the same
binary is the box, Linux 7.2.5 against 7.0.0, and not this change, since
both sides read it; it has not been taken apart.)

**`bench/shutdown.py`** comes back 6 of 6 on the WebSocket server and 6 of
6 on HTTP, so a connection with a held response is still one the shutdown
reaches.

### Can it be pushed further

On the pipelined HTTP row the server is now at 7.4 of its 8 cores, so the
next factor on this box is inside the request rather than around it, and
[the per-request accounting above](#what-a-request-costs-in-process) is
where to look. On the WebSocket row it is at 6.1 of 8 and gcannon at
37M frames a second is the more likely limit; a second box would say.
Sixteen is the arena's depth; a client that pipelines deeper than the
4 KiB write buffer holds gets a drain per 4 KiB, which is the right bound
and could be raised per server with `write_buffer` if a profile ever
wanted it.

## A reset between frames is a client that has gone

[ADR 202](../../docs/adr/202-a-reset-between-frames-is-a-client-that-has-gone.md)
is the decision; this is the run that found it, made before subscribing
nilo's arena entry to `echo-ws-limited`.

The shape is the arena's: `--ws -r 10`, a WebSocket connection closed
after ten echoed frames and reopened, at 512 and 4,096 connections. Same
instrument and split as the two sections above (gcannon on CPUs 8–15, the
server `bench/ws_server.zig` on 0–7, `/ws/small`, `ReleaseFast`, CPU from
`/proc/<pid>/stat`). One thing about the instrument matters here and was
read out of its source: **under `-r`, gcannon sets `SO_LINGER {1, 0}` on
every socket**, so each connection ends with a reset rather than a FIN.
That is what a load generator does to keep its ports out of `TIME_WAIT`,
and it is what every connection on the arena's two `limited` columns does.

Three builds, five-second runs, stderr to a file or to `/dev/null`,
descriptors sampled at 2.5 s with `ls /proc/<pid>/fd`, connection counts
from gcannon's `Reconnects` and `WS upgrades`:

| server | stderr | frames/s | descriptors mid-run | connections made | upgraded |
|---|---|---|---|---|---|
| `7e084ce`, one acceptor | a file | 878K | 10,014 | 542K | 445K |
| | `/dev/null` | 1.18M | 323 | 590K | 600K |
| `0efa4c0`, every executor accepts (ADR 200) | a file | 454K | 10,025 | 2.6M | 233K |
| | `/dev/null` | 708K | 10,021 | 2.4M | 360K |
| the tree with ADR 202 | a file | 1.70M | 560 | 851K | 863K |

**The warning per connection was the ceiling, and ADR 200 lowered it.**
A reset between frames came up through `receive` as `ReadFailed` and was
logged as "the WebSocket loop failed", once per connection; the log takes
one lock for the whole process and holds it across the format and the
write. With one acceptor the intake was throttled to roughly what that
lock could pass. With eight, connections arrived faster than the ones
before them could get through it; each fiber waiting for the lock held
the reset socket it was about to close, the descriptors climbed to
`max_connections` (10,000 on this server), the acceptors began refusing,
and gcannon retries a refused connection at once, so 2.4M connections
were made for 233K that reached a handshake. `/dev/null` moves the number
and not the shape, which is what says the lock and not the disk.
Treating the reset the way a FIN is already treated, `null` from
`receive` and no line, is the whole fix.

Interleaved pairs, eight seconds, `0efa4c0` → the tree with ADR 201 and
202, stderr to a file:

| shape | before | after |
|---|---|---|
| 512 conns × 10 frames | 461K / 469K frames/s, p50 340 µs, p99 640–670 µs, 39.6 core-s | **1.67M / 1.69M**, p50 69–86 µs, p99 380 µs, 48.6 core-s |
| 4,096 conns × 10 frames | 286K / 283K, p50 5.4 ms, p99 6.8 ms, 34.2 core-s | **1.58M / 1.58M**, p50 270 µs, p99 1.1–1.2 ms, 48.6 core-s |
| `7e084ce` for context, one run each | 874K, p50 12 µs, p99 46 µs (512) / 845K, p50 13 µs, p99 74 µs (4,096) | |

The one-acceptor row's latency is low because its intake was throttled:
gcannon times a frame from send to echo, and a connection waiting in the
backlog to be accepted is not yet sending frames. The after rows are at
6.1 of 8 cores, with descriptors and established sockets tracking the
client's connection count.

**The HTTP short-lived shape does not have this** and never did:
`-r 10` on `/health` at 512 and 4,096 connections holds 565 and ~2,500
descriptors mid-run at 1.96M and 1.76M req/s, with no line per connection,
because a reset between two requests is `waitForRequest`'s to swallow and
always was.

**What is not explained.** Both servers log "handler … failed after
answering: WriteFailed" for 0.05–0.1% of short-lived connections: 403 in
879K on HTTP at 4,096 connections, 934 in 794K on WebSocket, 163 in 435K
on the one-acceptor build, so it is older than any change here. The
response, or the 101, was written to a socket the client had already
reset, which under `-r 10` and `-p 1` should not happen before the tenth
answer has been read. gcannon reports ~100–200 `read` errors per run,
which is the same order but not the same number. The roadmap carries it.

### Can it be pushed further

The after rows are the same server that echoes 2.75M frames a second on
persistent connections, so the remaining 1M a second is the connection:
accept, the upgrade's SHA-1 and base64, a fiber and its two buffers, and
the teardown. ADR 200's upstream row, a spawn homed on the accepting
executor, is the next lever on it, and the same for HTTP's short-lived
shape.

## What gzipping an answer costs, and what putting the compressor on the stack would have

[ADR 211](../../docs/adr/211-a-response-is-compressed-on-a-compressor-borrowed-from-a-pool.md)
is the decision; these are the three runs under it, all on the Ryzen 7
9700X (8 cores, 16 threads) under Linux 7.2.5, Zig 0.16.0, against
`dc19600` where a before is named.

**The stack a `Compress.init` takes, read off the assembly.** A scratch
program with two `noinline` wrappers, one assigning `try
Compress.init(...)` into a heap slot and one `catch`-ing it, built
`-OReleaseFast -femit-asm`: both prologues reserve **99,048 and 99,032
bytes** (`sub rsp, 99048`), which is the 96 KB `buffered_tokens` built as a
temporary from its `.empty` constant and copied in; the hash table's
64 KB `head` is splatted in place and its 64 KB `chain` left undefined. The same wrapper doing the assignment field by field
(`compress.reset`) reserves **40 bytes**, and the deepest frames under a
`writeAll` + `finish` are `Compress.huffman.build` at 4,936 bytes and the
`sort.block` instantiation under it at 4,888. This is the number that
moved the compressor off the fiber and into a pool: on a fiber a frame is
held at its high-water mark for the connection's life (ADR 062), and
99 KB × 4,096 keep-alive connections is 400 MB.

**What the compressor costs per body: `zig build bench-compress`.** One
thread, one pool slot, the request arena reset after each body, 2,000
timed bodies after 100 warm ones, `std.json` bodies of the arena's three
`json-comp` shapes:

| items | bytes in | `.fastest` | `.default` | `.best` |
|---|---|---|---|---|
| 25 | 4,091 | 873 B, 35.0 µs | 748 B, 37.5 µs | 744 B, 38.1 µs |
| 40 | 6,553 | 1,252 B, 44.5 µs | 1,041 B, 49.7 µs | 1,036 B, 51.3 µs |
| 50 | 8,178 | 1,483 B, 50.6 µs | 1,225 B, 58.4 µs | 1,218 B, 63.7 µs |

`reset` alone, timed the same way in the scratch program, is **6.0–6.4 µs**,
nearly all of it the 64 KB `lookup.head` clear (32,768 two-byte entries;
this line said 128 KB until a later run counted them), so the three levels differ
by less than that table's reader expects: the fixed cost is a sixth of a
4 KB body. The clear is not optional. `matchAndAddHash` subtracts a head
entry's distance from the current index with no bounds check, so a stale
entry from the previous body reads before the buffer. What the table
decided: `.default` as the default (`.best` is under 1% smaller for 5–9%
more time), and the roadmap's stream question left open rather than
answered with a compressor held across writes.

**Binary size, both trees stripped `ReleaseFast`, `-Dtarget=x86_64-linux-gnu`.**
Two measurements, because the change carried two things:

| binary | before | feature alone | after | net | of which the qvalue scan |
|---|---|---|---|---|---|
| `example-hello` | 981,248 | +4,896 | 956,640 | **−24,608** | −29,504 |
| `example-rest` | 1,150,872 | +4,064 | 1,147,224 | **−3,648** | −7,712 |
| `nilo-hello` (bench) | 990,120 | +3,920 | 964,568 | −25,552 | −29,472 |
| `example-orders` | 1,272,456 | +3,888 | 1,268,648 | −3,808 | −7,696 |
| `example-spa` | 1,149,824 | +5,600 | 1,125,936 | −23,888 | −29,488 |

The last column was measured on an intermediate tree, the feature with
`parseFloat` still in against the same tree with the scan, and the feature
column is the net with that saving added back; the first, third and fourth
columns are direct. The feature is `Ctx.squeezed`, `Pool.eligible`,
`compressible` and `Pool.gzip`: 3.9–5.6 KB the linker keeps because the
switch is a runtime null on the Ctx. Deflate itself was already in every binary (`compress.flate.
Compress.drain` is in the before `nm` of `hello`), because the API reader
page is a static set and static sets gzip at load. The second column is
the `Accept-Encoding` reader's `std.fmt.parseFloat(f32, q)` replaced by a
digit scan: **25 KB** on a binary that parses no other float, 3.7 KB on
the three that already do (`orders`, `rest`, `sqlite`). It had been there
since static gzip landed. ADR 017's table carries the row.

### Can it be pushed further

The 6 µs reset is the lever, and it is the standard library's: a `head`
table that recorded which entries are live (a generation counter beside
each, or a clear bounded by what the last body touched) would make a
second body cost only its own matching. Not this repository's to change
without a fork of `Compress.zig`, and not worth one for a sixth of a small
body. Brotli is the other lever on the *score*, not the cost: the arena
weights bytes per response quadratically against the smallest body in the
field, and a brotli entry's is smaller than any gzip's. How much smaller
on these bodies has not been measured here, and the ADR says why it is a
decision of its own.

## What TLS carries at saturation, and the build flag that decides it

[ADR 212](../../docs/adr/212-tls-is-an-option-a-build-asks-for.md) closed
saying "throughput at saturation over `https://` was not measured, for want
of a load generator with TLS on the box, and is a roadmap row". This is that
row. Ryzen 7 9700X (8 cores, 16 threads), Linux 7.2.5, Zig 0.16.0, over
loopback and not a published port, against `219d51b`.

The shape is the benchmark arena's `8gbit` profile, which is the only one
anywhere here that loads ingest and egress at once: `POST /echo`, a
10,240-byte body up and the same bytes back, 512 connections, the rate held
at 50,000 req/s. That is 512 MB/s through the decrypt path and 512 MB/s
through the encrypt path. The server is `bench/echo_server.zig`, where TLS
is an env switch rather than a second binary, pinned to four physical cores
(CPUs 0-3,8-11) with eight executors; the generator is **zrk 2.3.0, the
board's own**, built from HttpArena's `docker/zrk.Dockerfile` and pinned to
the other four. Three rounds, interleaved, spread under 2%.

| build | rate_ratio | MB/s | p50 | p99 | server CPU/req |
|---|---|---|---|---|---|
| plain, the control | 0.995 | 491 | 0.05 ms | 0.08 ms | 6.8 µs |
| TLS, `-Dcpu=x86_64_v3+aes+pclmul` | 0.993 | 491 | 0.07 ms | 0.11 ms | 14.6 µs |
| TLS, `-Dcpu=x86_64_v3` | **0.389** | 192 | 3,040 ms | 5,990 ms | 407 µs |

Closed-loop, the same pinning, two rounds: plain 923,000 req/s and 9.1 GB/s;
TLS 303,700 req/s and 3.0 GB/s. Halving the server's cores took the TLS
ceiling to 206,000 rather than to 152,000 and the server sat at ~87% CPU
both times, so 300,000 is a floor on the server rather than its ceiling —
the generator is near its own limit there too. It is six times the profile's
requirement either way, and at the profile's rate the server spends 7.3 of
the 80 CPU-seconds available in a ten-second window, about 9% of four cores.

### The build flag is the whole story, and `x86_64_v3` is the wrong one

**Zig's `x86_64_v3` carries no `aes` and no `pclmul`.** AES-NI is not part of
the x86-64-v3 psABI level; it is a separate feature flag. Read off the
compiler:

```
x86_64_v3    aes=false vaes=false pclmul=false avx2=true
znver5       aes=true  vaes=true  pclmul=true  avx2=true
```

What that does to `std.crypto`, one core, 512 MB per measurement,
`taskset`-pinned, encrypt and decrypt timed apart:

| aead | record | `x86_64_v3` enc/dec | `+aes+pclmul` enc/dec |
|---|---|---|---|
| AES-256-GCM | 16 KB | **71 / 71 MB/s** | **5,133 / 5,102 MB/s** |
| AES-128-GCM | 16 KB | 74 / 74 | 5,850 / 5,857 |
| ChaCha20-Poly1305 | 16 KB | 734 / 735 | 734 / 735 |

**AES-256-GCM is the row that matters, and tls.zig's own fallback cannot
save it.** The library orders its TLS 1.3 suites on
`crypto.core.aes.has_hardware_support` and puts ChaCha20 first when it finds
none, which would be ten times quicker for that build. It never runs:
`handshake_server.zig` takes the first suite in the *client's* list it
supports, and an OpenSSL client offers AES-256-GCM first. Both builds were
asked, and both answered the same:

```
echo-aesni   New, TLSv1.3, Cipher is TLS_AES_256_GCM_SHA384
echo-v3      New, TLSv1.3, Cipher is TLS_AES_256_GCM_SHA384
```

So the entry's `Dockerfile`, which built amd64 with `-Dcpu=x86_64_v3`, put
software AES on the hot path of every TLS profile. At 50,000 req/s it needs
about seven cores to decrypt and seven to encrypt on an eight-core box; what
it does instead is saturate, deliver 39% of the offered rate and answer at a
six-second p99.

### What did not move, against expectation

**`write_buffer` at 16 KB is not worth anything, and at saturation it
costs.** A 10 KB answer leaves as three records at the 4 KB default and one
at 16 KB, and the AEAD table above makes a 16 KB record 8% cheaper than a
4 KB one, so the change looked free. At the profile's rate it is inside the
spread (14.70 µs against 14.74). Closed-loop it is **16% slower**, 255,500
req/s against 303,700, consistent across both rounds. The arithmetic says
why: 20 KB of AEAD is 4 µs of a 14.6 µs request, so 8% of it is 0.3 µs, and
against that the larger buffers cost 512 connections × 12 KB more of
working set. The published default stands.

### Can it be pushed further

The TLS request costs 14.6 µs against the plain 6.8, and about 4 µs of the
difference is the AEAD itself at 20 KB a request. The rest is record
framing and the copies through the cleartext buffers, which is where
`Ktls` would go — the roadmap row for it is unchanged and this run does not
settle it. Nothing here is worth doing for `8gbit`, which the server holds
at 9% of four cores.

## What an RSA certificate costs a handshake

**The section above was right about its certificate and wrong about the arena's.** Every TLS run in this file used `http/testdata/tls/localhost.pem`, which is ECDSA P-256, and put a handshake at about 0.3 ms. HttpArena mounts an RSA-2048 certificate, and with it a handshake cost **13.7 ms of server CPU**. The arena's reading at `fa0055f` was what showed it: `8gbit` at a rate of 0.94 with a 201 ms p99, and `json-tls` at 421K req/s on 6,287% CPU, about 149 µs a request.

**Where the time went.** tls.zig signed `CertificateVerify` with one full-size `pow(m, d)` on `std.crypto.ff.Modulus(4096)`, and its key parser read the primes, their exponents and the coefficient and dropped them. One 2048-bit private-key operation on one core, from a scratch program on `std.crypto.ff`: 15–23 ms as the library did it, 11.5–12 ms with `d` passed at the modulus's length (`pow` encodes the exponent at the capacity of the type, so half of it was leading zeros), and **3.0–3.5 ms through the CRT form**. OpenSSL's `speed rsa2048` signs in 0.22 ms on the same box.

**The fix is upstream's to take**: [ianic/tls.zig#59](https://github.com/ianic/tls.zig/pull/59), which keeps the CRT values, checks every CRT result against `e` before returning it, and falls back to `d` when the values are missing or wrong. Until it merges, `build.zig.zon` pins `nevindra/tls.zig` at `0185b3c`, which is upstream's `zig-0.16.x` at `e04ae44` plus that one commit.

**The run.** Ryzen 7 9700X, Linux 7.2.5, Zig 0.16.0, loopback. The server is `bench/echo_server.zig` with `ECHO_TLS=1` and eight threads pinned to CPUs 0-3,8-11, started in a directory whose `http/testdata/tls/` holds the arena's `certs/server.crt` and `server.key`. It was built `-Dtls -Dtarget=x86_64-linux-gnu -Dcpu=x86_64_v3+aes+pclmul --release=fast` twice from `16dc5dc`: once against the old pin and once against the fork, from a `git archive` copy whose `build.zig.zon` points at it. The clients are on CPUs 4-7,12-15: Python's `ssl` doing 300 handshakes one after another, zrk 2.3.0 from the arena's image in the `8gbit` shape (512 connections, a 10,240-byte POST echoed, 50,000 req/s, 5 s), and the arena's own `wrk` image at 4,096 connections on `/health`. Before and after were interleaved, two rounds each, and the rounds agreed to the digit shown.

| | before (`e04ae44`) | after (`0185b3c`) |
|---|---|---|
| server CPU per handshake | 13.6–13.7 ms | **2.57 ms** |
| `8gbit`: rate held | 0.83 | 0.96 |
| `8gbit`: p50 / p99 / p99.9 | 60 µs / 1,047–1,088 ms / 1,246–1,321 ms | 58 µs / 29 ms / 70 ms |
| `8gbit`: mean | 96–99 ms | 0.88–0.90 ms |
| `8gbit`: server CPU per request | 77.4 µs | 23.7 µs |
| 4,096 connections, 5 s: requests completed | **0** | 2,239K–2,242K (440K req/s) |

**The last row is the handshakes alone.** 4,096 of them at 13.7 ms each is 56 CPU-seconds, and eight threads have 40 in five seconds, so `wrk` never got a first answer.

**The control that isolated it** was the arena's own image (`fa0055f`) with the arena's certificate against a P-256 one and nothing else changed: in the `8gbit` shape, a rate of 0.83 against 0.98, a p99 of 1.05 s against 65 µs, and 75 µs a request against 12.7. The arena also sets the loopback MTU to 1,500. That was tried at 1,500 and at 65,536 and moved nothing.

**The other three axes.** Allocations per request do not move: the change is inside the handshake. Memory per idle TLS connection, `bench/mem.py --tls` at 2,000 and 5,000: 9,411 and 9,435 bytes before, 9,411 and 9,333 after, so it is unchanged. Binary size, stripped `ReleaseFast`: a build without `-Dtls` is byte-identical (`example-hello` 960,376, `example-rest` 1,150,792), and a `-Dtls` build pays **+26,768** and **+26,832** bytes for the second `ff.Modulus` instantiation.

### Can it be pushed further

Yes, and the p99 says where. 2.57 ms is still spent on the executor that accepted the connection, so every other connection on that thread waits behind each handshake. That is the 29 ms left on the `8gbit` p99. It would be closer to 60 ms on the arena's slower cores, and the arena scores `8gbit` a third of a term per decade of p99. The lever is to run the signature somewhere other than the executor, which needs a signer hook in tls.zig, and the roadmap carries it under Waiting on upstream. Below that, the 3 ms itself is `std.crypto.ff`'s constant-time exponentiation, fourteen times OpenSSL's, and a fixed-size Montgomery ladder for 1024-bit primes is the lever there. Neither has been tried.

The first was tried, and needed no upstream: nilo pins its own fork. It is [the signature off the executor](#what-a-signature-on-the-executor-costs-the-connections-already-open), below.

## What TLS costs a listener, and what it costs one that never asked

[ADR 212](../../docs/adr/212-tls-is-an-option-a-build-asks-for.md) is the
decision; these are the runs it quotes, taken on the code as shipped rather
than on the spike that preceded it (the spike's figures were within 2% on
memory and read 455 µs per handshake where the shipped code reads 280–295,
the difference being that the spike's client shared the server's cores).

The machine is the one at the top of this file, on Linux 7.2.5 rather than
the kernel listed there; commit `1264cac` plus the change. Server on CPUs
0–7, client on 8–15, loopback. Four binaries, all `ReleaseFast`, stripped,
`-Dtarget=x86_64-linux-gnu`: `nilo-hello` from `main` (the control),
`nilo-hello` from this change without `-Dtls`, `nilo-hello` from this change
with `-Dtls` and `.tls` never set, and `nilo-bench-tls-server` (the same
routes and middleware as `nilo-hello`, `bench/tls_server.zig`, with the
suite's certificate). The CPU rows add `-Dcpu=native` variants of the last
two.

**Size**, `stat -c %s`:

| binary | bytes | against `main` |
|---|---|---|
| `main` | 990,696 | |
| this change, no `-Dtls` | 993,456 | +2,760 |
| this change, `-Dtls`, `.tls` never set | 1,568,208 | +577,512 |
| `nilo-bench-tls-server`, `-Dtls` | 1,593,424 | +602,728 |

The 2,760 bytes the default build pays are the two refusal messages (`.tls`
on a build without it, `.tls` on a unix socket) and the branch that chooses
them; the spike, which had neither message, paid 488. The 560 KB the
`-Dtls` build pays before a certificate is loaded is `std.crypto`'s X.509,
the AEADs and the key exchange, reached by reference from `Conn.runTls`
whether or not the acceptor ever spawns it.

**Memory per idle connection**, `bench/mem.py --steps 2000,5000,10000
--settle 3`, `/health`, `--tls` for the last row. The marginal column is
(RSS at 10,000 − RSS at 5,000) / 5,000, and it agrees with the average, so
the figure is a property of the connection rather than a transient:

| listener | build | at 10,000 | marginal 5k→10k | against plain |
|---|---|---|---|---|
| plain | `main` | 5,191 | 5,184 | |
| plain | this change, no `-Dtls` | 5,191 | 5,184 | 0 |
| plain | this change, `-Dtls` | 9,293 | 9,280 | +4,102 |
| TLS | this change, `-Dtls` | 9,307 | 9,279 | +4,116 |

The default build is unchanged to the byte. The `-Dtls` build costs one
page per idle connection on a plain listener, and a TLS connection then
costs 14 bytes more than that: its 33,114 bytes of record buffers are
page-aligned and handed back at idle with the cleartext pair, and `smaps`
on the spike showed the slab mappings unchanged between the two rows. The
page is the plain path's park frame crossing a page boundary once the
handler has a second caller; ADR 212 has the account and the roadmap has
the measurement that would buy it back.

**CPU per operation**, server `utime + stime` from `/proc/<pid>/stat`
around 20,000 keep-alive requests on one connection (after 500 to warm it)
and around 2,000 connect-request-close cycles, from one Python client
(`ssl` for the TLS rows, certificate unchecked). Three runs each, quoted as
the band; the resolution is a 10 ms tick, so 0.5 µs on the request rows and
5 µs on the connection rows:

| | plain | TLS | ratio |
|---|---|---|---|
| per request, kept alive, baseline `x86_64` | 3.0–3.5 µs | 22–23 µs | ~6.5 |
| per new connection, baseline `x86_64` | 15 µs | 325 µs | ~22 |
| per request, kept alive, `-Dcpu=native` | 3.0–3.5 µs | 3.5–4.0 µs | ~1.15 |
| per new connection, `-Dcpu=native` | 10–15 µs | 280–295 µs | ~20–29 |

Two things to read out of that. **The request is cheap and the handshake is
not**, which is the shape TLS has everywhere: what a deployment pays is
decided by how often its clients connect, and a client that connects per
request pays twenty times an accept every time, with no session resumption
in the library to make the second cheaper. And **the baseline ISA has no AES
instructions**, so a `-Dtarget=x86_64-linux-gnu` binary with no `-Dcpu`
encrypts in software and a request costs six times what it costs with them:
a TLS listener is the one place in this repository where `-Dcpu` decides
the number, and ADR 212's guide page says so.

**Not measured, and the roadmap carries each:** throughput and p99 at
saturation over `https://` (no load generator with TLS on this box), the
plain park's headroom under the page boundary, and kernel TLS.

## zzz beside nilo, and the one thing its runtime does that zio does not

Run to settle a premise before planning against it: that [zzz](https://github.com/tardy-org/zzz), which ADR 001 names as the road not taken (its own io_uring runtime, [tardy](https://github.com/tardy-org/tardy)), is faster than nilo's Engine and has something to port. It is not faster on this box, on any shape tried, and what was worth taking from it is one SQE opcode inside zio rather than anything in the Engine.

**The machine** is the Ryzen 7 9700X of the sections above, now on Linux 7.2.5 (Omarchy), governor `performance`, Zig 0.16.0. **The instrument** is gcannon (`11c802b`, native, liburing 2.15), eight threads on CPUs `4-7,12-15`; the server gets `0-3,8-11`, four physical cores and their siblings, eight threads each (zzz's example patched from `.auto` to `.multi = 8`, nilo takes its count from the affinity mask). Every run is 8 s after a 3 s warm-up that is discarded, the pairs are interleaved, and CPU is `utime + stime` from `/proc/<pid>/stat` across the run. nilo is `nilo-hello` at `16dc5dc` on `/health`, `ReleaseFast`, `-Dtarget=x86_64-linux-gnu -Dcpu=native`. zzz is **v0.3.2**, its last release for Zig 0.16 (main has moved to 0.17-dev), its `basic` example (`Hello, world!`), `ReleaseFast`. The two answers are 116 and 101 bytes on the wire.

| shape | nilo | zzz v0.3.2 |
|---|---|---|
| keep-alive, 512 conns | 2.42 / 2.44 / 2.45M req/s, **2.36–2.39 µs CPU a request**, p99 447–490 µs, p99.9 0.93–1.50 ms, peak RSS 15 MB | 1.66 / 1.67 / 1.70M, 3.00–3.08 µs, p99 542–552 µs, p99.9 650–753 µs, peak RSS 787–798 MB |
| 512 conns × 10 requests | 1.69 / 1.88 / 1.89M, 3.09–3.32 µs, p99 1.5–2.9 ms, p99.9 10.8–13.4 ms, 34–45 MB | 713 / 720 / 739K, 8.7–9.1 µs, p99 2.2–2.4 ms, p99.9 2.7–3.2 ms, **23.1–24.0 GB** |
| 256 conns, `-p 16` | 11.53 / 11.73 / 11.99M, 0.61–0.64 µs, p99 357–379 µs, 10 MB | 1.81M × 3, 2.83 µs, p99 3.8–5.2 ms, 291–324 MB |

**Neither server was saturated on the keep-alive row**, which is why CPU a request is the column to read there rather than req/s: sampled per thread over six seconds, nilo's eight threads each ran 4.33–4.38 core-seconds and zzz's 3.84–3.90, so both are balanced and both are waiting on the client part of the time. The first guess about zzz's idle share, that a thread-per-core runtime with no stealing had left some threads with more connections than others, was checked this way and is wrong. What zzz spends more on per request was not taken apart; tardy v0.3.2's loop submits and then waits in separate `io_uring_enter` calls where zio does both in one, sets no `DEFER_TASKRUN`, keeps headers in a hash map that lower-cases and hashes each name byte by byte, and formats its status line and headers through `print`. The pipelined row is zzz answering one request per `send`, which is what nilo did before ADR 201. The 23 GB is `VmHWM` on a 30 GiB box under connection churn and was not investigated; it is written down so nobody mistakes zzz's README figure for a property of its runtime under this shape.

**One row goes zzz's way**, and it is the tail on the churn shape: p99.9 2.7–3.2 ms against nilo's 10.8–13.4 ms. zzz serves that at 40% of nilo's throughput, so it is not a like-for-like tail, but it is the shape where tardy's model differs most from nilo's: tardy's accept task *becomes* the connection and spawns its replacement acceptor, so the first request is served on the thread whose ring completed the accept, with no handoff on its critical path. nilo's acceptor deals the connection to another executor (ADR 200), which is the upstream row on a spawn homed on the calling executor.

### What tardy does that zio does not: a plain `RECV` and `SEND`

tardy prepares a socket read as `IORING_OP_RECV` and a write as `IORING_OP_SEND`. zio prepares every one as `RECVMSG` / `SENDMSG`, which has the kernel copy a `msghdr` in and import an iovec per operation. Nearly every read and flush nilo makes is one buffer: `readVec` fills the reader's free tail, and `fillBuf` drops empty slices, so a buffered response goes out as a single iovec. A scratch copy of zio v0.18.0 with only those two SQEs changed (one iovec takes `prep_recv` / `prep_send`, anything else keeps the `msg` form; nilo untouched, both builds from a path dependency so the control is built the same way), four interleaved pairs a shape, same split and harness as above:

| shape | CPU a request, recvmsg / sendmsg | CPU a request, recv / send | pairs |
|---|---|---|---|
| keep-alive, 512 conns | 2.35 / 2.35 / 2.37 / 2.37 µs | 2.29 / 2.29 / 2.29 / 2.30 µs | 4 of 4 lower, **−2.9%**, throughput +1.6 to +2.0% each pair |
| keep-alive, 64 conns | 2.50 / 2.51 / 2.47 / 2.44 µs | 2.40 / 2.36 / 2.40 / 2.36 µs | 4 of 4 lower, **−4.0%** |
| 256 conns, `-p 16` | 0.58 / 0.61 / 0.61 / 0.60 µs | 0.55 / 0.59 / 0.55 / 0.62 µs | sign changes in pair 4: **unchanged** |

Eight pairs of eight the same sign on the two keep-alive shapes, and the ranges do not overlap, so **3–4% of CPU a request** is a result rather than noise. The pipelined row is what the mechanism predicts: sixteen answers share one `send`, so a per-syscall saving is diluted sixteen times. Memory, allocations and binary size do not move (the patched `nilo-hello` is 224 bytes larger, all of it inside zio). It is zio's code, not nilo's: nilo cannot reach an SQE from the Engine, and ADR 001 is the reason it should not. **Not pursued** (2026-09-23); it is written down so the next person starts from the number rather than re-running it.

### Can it be pushed further

Ranked, and none of it is in zzz's HTTP layer, which has nothing nilo's does not already do more cheaply:

1. **The opcode above, upstream.** Measured, 3–4% on keep-alive, zero cost on every other axis. Not pursued, and no upstream issue was filed.
2. **An acceptor that becomes its connection**, tardy's shape, inside the Engine and needing nothing upstream: after `accept`, spawn the replacement acceptor (round-robin, as now) and serve the connection in the accepting fiber. It moves the handoff off the first request's critical path rather than removing it, so the thing to measure is the churn row's p50 and tail, not CPU. Two hazards are known before writing it: the acceptors' group is cancelled before the drain, so a connection living in it would be cut off rather than drained (ADR 200's shutdown order), and the frame under a plain connection's park would grow by the acceptor's, which is under 300 bytes from a page (ADR 212). `gcannon -r 10`, `bench/mem.py` and `bench/shutdown.py` are the three runs it would need.
3. **`IORING_RECVSEND_POLL_FIRST` on the read that follows a flush**, where a keep-alive client almost never has its next request already sent, which would skip the inline attempt that returns `EAGAIN`. Also zio's, not measured.

Not taken, each with its number above: a pool of per-connection buffers allocated at startup (zzz's "provisions", 787 MB at 512 connections against nilo's 15 MB, which gives pages back when idle), headers in a hash map, and one `send` per pipelined response.

```
git clone https://github.com/tardy-org/zzz && git -C zzz checkout v0.3.2   # .multi = 8 in examples/basic
zig build basic -Doptimize=ReleaseFast
zig build install -Doptimize=ReleaseFast -Dtarget=x86_64-linux-gnu -Dcpu=native
taskset -c 0-3,8-11 ./zig-out/bin/nilo-hello &
taskset -c 4-7,12-15 gcannon http://127.0.0.1:8787/health -t 8 -d 8 -c 512   # -r 10, -c 256 -p 16
```

## A short-lived WebSocket and the TLB

[ADR 216](../../docs/adr/216-a-message-that-arrived-whole-is-handed-over-where-it-lies.md) is the decision; these are the runs under it.

**What the arena showed.** `echo-ws-limited` at `baaccf8`: 1.13M frames a second at 512 connections and 945K at 4,096, on 39 of the arena's 64 cores. Every entry above nilo in the column served more at 4,096 than at 512 and used 53 to 60 cores. A server using fewer cores and doing less with more connections is waiting on something rather than working, and this box, at 8 threads, did not show the shape at all.

**The instrument.** The arena's entry (`frameworks/nilo` on the PR branch), built `-Dtarget=x86_64-linux-musl -Dcpu=x86_64_v3+aes+pclmul --release=fast` against this tree through a path dependency, pinned to CPUs 0-3,8-11. gcannon built from the arena's own `docker/gcannon.Dockerfile`, on CPUs 4-7,12-15, `--ws -r 10 -t 8 -d 8s`, which is the arena's shape at eight client threads. Server CPU from `/proc/<pid>/stat`, and TLB shootdowns from the `TLB` row of `/proc/interrupts`, summed over every CPU, before and after each run. Ryzen 7 9700X, Linux 7.2.5, `21890c6`.

**The finding.** The same server, the same shape:

| run, 4,096 connections, 8 s | TLB shootdowns |
|---|---|
| WebSocket, ten frames a connection | 409K, 428K |
| HTTP, ten requests a connection (`/baseline11`) | 550, 632 |
| WebSocket, `scratch.zig`'s `keep_bytes` raised to 64 MiB | 8,306, 8,581 |

One shootdown for every three connections, and only on the WebSocket. The third row is an experiment, not a candidate: it says the free list is where they come from. Its cap of 64 KiB is four 16 KiB buffers an executor; with 512 sockets open on each of this box's executors, every connection mapped a buffer at its first frame and unmapped it at its last, and every `munmap` in a threaded process interrupts the other cores to flush their TLBs.

**The fix and its pairs.** A whole message already in the read buffer is handed over from there, so no buffer is taken for it. Interleaved:

| run | before | after |
|---|---|---|
| 512 connections, frames a second | 1.53M, 1.63M | 1.62M, 1.68M |
| 512, shootdowns | 274K to 513K | 9.9K to 11.9K |
| 4,096 connections, frames a second | 1.24M, 1.26M, 1.27M, 1.44M, 1.52M | 0.91M, 1.40M, 1.43M, 1.50M, 1.52M |
| 4,096, shootdowns | 535K to 1.27M | 10.1K to 16.9K |
| persistent echo, 4,096 connections, RSS | 94,784 KiB, 94,736 KiB | 78,380 KiB, 78,396 KiB |

The 0.91M is one run that landed while the box was loaded (4.45 cores against 5.8 for the others) and its pair was low too; the three pairs after it agree on the sign. The throughput here is not the claim, because eight threads make a shootdown cheap; it says the change costs nothing on this box. The claim is the shootdown count, and the next arena run is the reading that says what it was worth on sixty-four cores.

**The other axes.** Allocations per request: the HTTP path is untouched. Binary size, stripped `ReleaseFast`: `example-hello` and `example-rest` byte-identical, `example-chat` +656 bytes. Memory per idle WebSocket was not re-measured: an idle socket already gave its buffer back at the 200 ms peek, and nothing on that path moved.

### Can it be pushed further

On the arena's column, the next thing is whatever the next run shows. A short-lived socket that sends messages bigger than its read buffer still maps and unmaps a buffer per connection; nothing has asked about that shape, and `scratch.zig` says so.

## What a signature on the executor costs the connections already open

[ADR 217](../../docs/adr/217-a-handshakes-signature-is-computed-off-the-executor.md) is the decision; these are the runs under it.

**What the arena showed.** `8gbit` at `baaccf8`: p50 101 µs, p99 169 µs, mean 267 µs, and p99.9 46 to 68 ms, in five seconds over 512 connections opened once. The mean is a quarter of the score and the field's best is 81.5 µs, so the column's gap was the tail.

**The instrument.** The arena's entry as in the section above, with the arena's `certs/server.crt` and `server.key` (RSA-2048). zrk 2.3.0 from the arena's image on CPUs 4-7,12-15: `-t 8 -c 512 -R 50000 -m POST -b @<10,240 bytes> -k`, which is the arena's `8gbit` at eight client threads. CPU per request from `/proc/<pid>/stat` over zrk's request count. The arena's `wrk` image for `json-tls`: `-t 8 -c 4096 -d 5s -s json-tls-rotate.lua`.

**What zrk counts.** Read out of its source (`src/connection.zig`): each connection anchors its schedule at its first request, after its own handshake. A connection's handshake is never in its own latency. What is in it is the requests of connections already open, timed from when they were due.

**The controls, before anything changed:**

| run, `8gbit` shape | mean | p99 | p99.9 | CPU/req |
|---|---|---|---|---|
| RSA-2048, 5 s, three runs | 942 to 1,135 µs | 31 to 45 ms | 72 to 95 ms | 23.6 to 24.3 µs |
| RSA-2048, 20 s | 289 µs | 132 µs | 56 ms | 16.7 µs |
| ECDSA P-256 (a fresh key), 5 s, two runs | 234, 248 µs | 172, 377 µs | 35, 38 ms | 15.0, 15.2 µs |
| cleartext, port 8080, 5 s, two runs | 62, 89 µs | 52, 325 µs | 9.8, 15.8 ms | 6.8, 6.9 µs |

The 5 s and 20 s rows put the same total excess on the requests, about 230 request-seconds, so it is paid once at the start. The P-256 row says most of it is the signature. The cleartext row says some of it is not TLS at all.

**The fix and its pairs**, without and with the signature on the blocking pool, both with ADR 216, interleaved:

| run | before | after |
|---|---|---|
| `8gbit`, 5 s: mean | 1,123, 960, 1,044 µs | **133, 179, 136 µs** |
| p99 | 45.3, 31.0, 39.7 ms | **465, 546, 311 µs** |
| p99.9 | 92, 75, 84 ms | 29, 42, 32 ms |
| rate held | 0.960 to 0.962 | 0.961 to 0.964 |
| CPU per request | 24.1, 24.9, 24.4 µs | 24.5, 24.4, 23.9 µs |
| `json-tls`, 4,096 connections: requests a second | 242K, 247K, 238K | 245K, 241K, 232K |
| mean latency | 34.4, 31.5, 34.4 ms | 13.7, 13.7, 13.9 ms |

**The other axes.** `bench/mem.py --tls` against `bench-tls-server -Dtls`, twice each: 9,415 and 9,334 bytes a connection at 2,000 and 5,000 before, 9,558 and 9,391 after. The marginal from 2,000 to 5,000 is 9,280 bytes in both, so the difference is a flat ~290 KB and not a cost per connection; the pool's threads starting would account for it, and that was not checked. Binary size, stripped `ReleaseFast`: `bench-tls-server -Dtls` 1,606,608 to 1,608,048 bytes (+1,440), and a build without `-Dtls` byte-identical.

### Can it be pushed further

Yes, twice. The p99.9 of 29 to 42 ms that is left is the start of the run: cleartext shows 10 to 16 ms of it, so the burst of new connections costs something whatever they speak, and that is the next thing to take apart, for every profile that opens its connections at once. And the signature still costs the CPU it did: 2.6 ms, where OpenSSL signs in 0.22. A fixed-width Montgomery ladder for 1024-bit primes is that lever, and it would move the CPU per request on every TLS profile, not only the tail.

## What checking a key against its certificate costs the binary

[ADR 212](../../docs/adr/212-tls-is-an-option-a-build-asks-for.md)
is the decision; this is the run behind its size table. The change is a
comparison at `listen()` of the leaf certificate's public key against the
one the private key carries, so the only axis it can spend is binary size:
it runs once at startup, keeps nothing, and adds nothing to a request.

**The machine** is the 2-core box this repository is worked on rather than
the desktop at the top of this file, which for a `stat -c %s` does not
matter. **The before was built, not quoted**: `git archive HEAD` into
`/tmp/nilo-before` with `zig-pkg` hardlinked across, so both trees see the
same pins. `nilo-hello` (`bench/main.zig`), `ReleaseFast`, `-Dstrip=true`,
`-Dtarget=x86_64-linux-gnu`, built alternately before/after/before/after.

| build | before | after | delta |
|---|---|---|---|
| no `-Dtls` | 968,144 | 968,144 | 0 |
| `-Dtls`, `.tls` never set | 1,547,728 | 1,538,352 | −9,376 |

Both `-Dtls` rows reproduced **to the byte** on the second round, so the
number is not build noise.

**The default build is unchanged to the byte**, which is the row the
decision rests on: the check is inside the comptime `if (nilo_build.tls)`
the Engine already had, so a build with no module named `tls` never
analyses it. That two independently built trees produce identical bytes is
also what says the trees are otherwise the same, which is worth more here
than the row below it.

**The `-Dtls` build got smaller, and the 9,376 bytes are the inliner's.**
`.text` is where it moved: 1,376,221 to 1,367,149 on an unstripped pair
built the same way. Three things say it is not a feature being dropped.
`keyIsTheCertificates` has no symbol in either binary, so it was inlined
into the listener loop. The certificate-loading chain beside it is byte for
byte the same size in both — `CertKeyPair` 145, `Certificate.parse` 9,639,
the RSA namespace 36,316. And the largest matched move is
`handshake_server.Handshake.serverFlight`, 22,598 to 21,140, which this
change does not touch and does not call. One more call in the startup loop
shifted what LLVM folded, and the rest is spread too thin to name.

**What it did not change:** nothing to re-measure on the other three axes.
No per-connection state, so `bench/mem.py` was not re-run; the two 512-byte
buffers the RSA prong compares through are a startup frame and are gone
before the first accept.

**Can it be pushed further:** there is nothing here to push. The 9,376 is
not a result to defend — a later change to the same loop could take it back
without anything being wrong — and the row to hold in a regression check is
the first one, the default build at 968,144.

## What a gRPC client puts on the wire, and what a stream would cost

Taken for [ADR 220](../../docs/adr/220-grpc-is-served-over-h2c-behind-a-flag.md), before any of it is built, because the two numbers that decide whether a gRPC connection fits nilo's memory axis are not in any RFC: what a real client does when the server asks it for less, and what zio charges for a fiber per stream. Ryzen 7 9700X (8 cores, 16 threads), Linux 7.2.5, Zig 0.16.0, zio v0.18.0, commit `dce5d93`, loopback. The harness is `spike/grpc/`: `./run.sh` for the clients, `fiber/` for the fiber.

**The clients.** `spike/grpc/probe/` is a gRPC server written at the frame level with `golang.org/x/net/http2` v0.59.0, so it can count what the client chose rather than what a library decoded. It answers every unary call with an empty message after 20 ms. Each client makes 32 calls, 16 at a time, on one channel: grpc-go 1.84.0, grpc-js 1.14.5, grpcio 1.84.0 (C-core 56.0.0), and tonic 0.14.6 on h2 0.4.19. The fifth row is the OpenTelemetry Collector 0.161.0 with its default `otlp` exporter, fed twenty traces, because a client library called by hand is not the same as a client somebody deployed with defaults.

### The HPACK table a server has to keep

| client | table 4,096: header block, first call / later | offered to the table | table 0: header block, later calls | offered to the table |
|---|---|---|---|---|
| grpc-go | 115 / 8 B | 367 B | 117 B | 0 |
| grpc-js | 143 / 52 B | 348 B | 143 B | 0 |
| grpcio | 248 / 8 B | 420 B | 248 B | 0 resident (see below) |
| tonic | 94 / 50 B | 213 B | 96 B | 0 |
| Collector | 194 / 10–17 B | 1,202 B over 20 calls, still growing | 196 B | 0 |

**Every client honoured `SETTINGS_HEADER_TABLE_SIZE = 0`.** Each sent a dynamic table size update of 0 at the top of its first header block and inserted nothing after. grpcio is the one that looks otherwise: it kept sending literals with incremental indexing, 192 of them. RFC 7541 §4.4 makes an entry bigger than the table empty the table rather than fail, so into a table of size 0 that is 0 bytes resident, and the decoder raised no error. What it costs is bandwidth, about 110 bytes more per call inbound, which against an OTLP export or any real message is noise.

**The Collector is the row that decides it.** `grpc-timeout` is a fresh value on every call and the Collector indexes it, so at the default table its connection inserts about 60 bytes per call: 1,202 over twenty calls, which by arithmetic rather than a longer run fills the 4,096 in about seventy and keeps it full for as long as the connection lives. Advertising 0 is the difference between a gRPC connection that costs a table and one that does not.

### What a cap on streams does

At `SETTINGS_MAX_CONCURRENT_STREAMS = 1`, all four libraries queued on the one connection: grpc-go 651 ms, grpc-js 670 ms, grpcio 653 ms, tonic 632 to 650 ms for 32 calls of 20 ms, against 41 to 56 ms at 100. **None opened a second connection and none failed a call.** A low cap is a throughput knob, never an error.

**But a cap is not a guarantee, because a client may open streams before it has read it.** tonic sends HEADERS before the server's SETTINGS in some runs and not others: in the first run it had two streams open against a cap of 1, in the second it sent two requests ahead of the ACK at the default cap and stayed under 1 at the cap. The other three waited every time. A server that caps has to refuse the excess with `REFUSED_STREAM`, and its decoder has to accept a 4,096-byte table until the size update arrives. Both are transient; neither is idle cost.

**The Collector's defaults are the shape to build for:** `grpc-encoding: gzip` on every call, a `grpc-timeout` of five seconds, at most ten streams open, and a connection held open between exports.

### A fiber per stream

`spike/grpc/fiber/`, ReleaseFast, one cold process per row, because zio keeps a finished fiber's stack in its pool with the pages still resident and a second round in the same process reads zero.

| stack the fiber touched | bytes per parked fiber, 5,000 | marginal to 20,000 |
|---|---|---|
| 0 | 4,547 | 4,544 to 4,607 |
| 1 KiB | 4,547 | 4,544 to 4,611 |
| 2 KiB | 4,547 | 4,565 to 4,594 |
| 4 KiB | 8,643 | 8,640 to 8,677 |
| 8 KiB | 12,739 | 12,736 |
| 16 KiB | 20,931 | 20,928 to 20,982 |

**A parked fiber costs 4,547 bytes, and every page of stack it touched after the first costs a page.** Marginal met average in every row, so it is a cost and not a transient. It is ADR 062's rule seen from the other side: that ADR found a handler's stack is charged one for one to the connection holding it, and this is the same charge on a fiber that holds nothing else. [ADR 028](../../docs/adr/028-a-spawned-fiber-belongs-to-the-server.md)'s 8,673 bytes for a second fiber was a fiber draining a queue, on a connection whose idle figure was then 66,959; this one has touched under a page, and the two are not the same question.

**What it decided:** that a stream in flight on HTTP/2 costs what a request in flight on HTTP/1.1 already costs, a fiber and its stack, so the idle axis does not move with the number of streams a connection has served. What moves is the worst case of one connection, which becomes the cap times that figure: at 100 streams of the database route in [ADR 062](../../docs/adr/062-where-a-connection-waits-is-what-it-costs.md), about 1.7 MB. The cap is the number that bounds it, and it has to be a stated default rather than a library's.

**Can it be pushed further:** the 4,547 is a page and zio's task. Whether the only stream open could run on the connection's own fiber was the open question here, and [the section below](#a-grpc-listener-built) answers it: it could, and it may not.

## A gRPC listener, built

The listener [ADR 220](../../docs/adr/220-grpc-is-served-over-h2c-behind-a-flag.md) accepted, measured before it was committed: the working tree on top of `dce5d93`, the same machine as the section above. `spike/grpc/server/` is the server (routes for the Collector, an echo, and HttpArena's `GetSum`), `spike/grpc/throughput.sh` the throughput run.

### Against real clients

grpc-go 1.84.0, grpc-js 1.14.5, grpcio 1.84.0, tonic 0.14.6 and the Collector 0.161.0 (twenty exports, gzip on every one) all complete against nilo: the same client commands `run.sh` gives the probe, pointed at `spike/grpc/server/`, which listens on the probe's port (127.0.0.1:50051), and the Collector with the same `otelcol.yaml`. A 1 MB message goes through and 2 MB is `RESOURCE_EXHAUSTED`, which is `max_body`. Over TLS, grpc-go (plain and gzip) and `curl --http2` reach `GetSum` with ALPN `h2`.

### Memory per idle connection

`bench/mem.py --grpc` opens a connection, makes one call, and leaves it idle.

| listener | bytes per idle connection, converged at 10,000 |
|---|---|
| HTTP/1.1, the default build (`bench nilo-hello`, marginal) | 5,183 |
| HTTP/1.1, the same program built with `-Dgrpc` | 5,183 |
| HTTP/1.1 on the spike server | 5,322 |
| gRPC on the spike server, before the optimizations below | 6,029 to 6,044 |
| gRPC on the spike server, as committed | 5,685 to 5,917 |

**The flag costs a plain connection nothing**, the thing ADR 212 found `-Dtls` did not manage, and a gRPC connection sits under a page above an HTTP/1.1 one on the same binary: the stream table, the decoder with a table of 0, and the spare streams dropped at the idle release.

### Binary size, stripped `ReleaseFast`

| build | hello | rest |
|---|---|---|
| before (`dce5d93`) | 964,952 | 1,155,368 |
| after, default | 964,960 (+8) | 1,155,480 (+112) |
| after, `-Dgrpc` | 1,080,680 (+115,720 on the default) | 1,207,912 (+52,432) |

### Throughput

h2load from HttpArena's image POSTing a 9-byte `SumRequest` to `GetSum`, `-m 100`, 5 s, eight h2load threads, interleaved with HttpArena's own grpc-go and tonic entries, server pinned to cores 0-3 (CPUs 0-3,8-11) and h2load to cores 4-7. Loopback, no Docker port for nilo, `--network host` for the others.

| run | c=256 | c=1024 |
|---|---|---|
| nilo, as first built | 710k to 750k | 407k to 440k |
| nilo, as committed, two rounds | 769k to 774k, mean 28 to 29 ms, max 1.40 to 1.44 s | 556k to 567k, mean 111 to 113 ms, max 3.80 to 3.85 s |
| grpc-go, the same rounds | 589k to 591k, mean 43 ms, max 0.27 to 0.30 s | 578k to 583k, mean 159 to 163 ms, max 1.33 to 1.74 s |
| tonic, the same rounds | 902k, mean 27 ms, max 0.23 to 0.26 s | 851k to 856k, mean 96 to 97 ms, max 1.05 to 1.11 s |
| nilo, every call inline on the connection's fiber, as first built (not shipped) | 1.44M | 1.24M to 1.28M |
| nilo, every call inline, as committed otherwise (not shipped) | 3.12M | 2.95M |

grpc-go and tonic read 4% and 6% higher in these rounds than on the day of the first build (564k and 854k at 256), so the first row is compared to its own day's controls: nilo was 1.26 to 1.33x grpc-go and 0.83 to 0.88x tonic at 256 then, and is 1.30 to 1.31x and 0.85 to 0.86x now. **The worst call is nilo's**, 1.4 s at 256 and 3.8 s at 1,024 against about 1.1 s for tonic, and h2load reports no percentiles to say how many calls are near it.

**A run with the wrong server in it looked like a win.** The first round of the committed row read 908k at 256 and then 0 for every later nilo run: the spike server had gained a TLS listener whose certificate path is relative to the repository root, `throughput.sh` started it from `spike/grpc/`, and it exited at once. The 908k was a server left over from an earlier session answering on the same port. The script now starts it from the root, waits for it to exit, and refuses to start if one is already running.

### Where a call's time goes

CPU per call from `/proc/<pid>/stat` over the run, eight executors, and `zig build profile`'s replay of h2load's steady-state 89-byte header block in process.

| | as first built | as committed |
|---|---|---|
| CPU per call, fiber per call, c=256 | 7.29 µs | 4.35 to 4.71 µs |
| CPU per call, fiber per call, c=1024 | not taken | 6.86 to 7.42 µs |
| CPU per call, inline, c=256 / c=1024 | 4.37 µs / not taken | 2.50 / 2.65 µs |
| context switches per call, fiber per call, c=256 / c=1024 | 0.47 / not taken | 0.87 to 0.95 / 0.71 to 0.81 |
| in process, whole call | 1,500 ns | 973 ns |
| of which HPACK decode | 563 ns | 247 ns |
| of which the App (`handleRequest` on the translated text) | 242 ns | 229 ns |
| of which the rest (frames, translation, answer) | 694 ns | 497 ns |
| heap allocations, second call on a connection | 4, 3,342 B | 0 |

What moved it: a Huffman decoder reading nine bits at a time from a 64-bit accumulator in place of a bit at a time; the answer's two constant header blocks written as bytes rather than encoded per call; one flush per wake rather than per frame; and a finished call's stream kept with 4 KiB of its arena for the next call.

**On one executor a fiber per call costs 2.74 µs against 2.51 inline**, so the fiber itself is 0.23 µs. The other 2 µs at eight executors is zio dealing every `spawn` round-robin to another executor (`getNextExecutor`) and waking it: a call's fiber runs on another thread, and its answer is posted back. Coalescing those posts (one wake for a batch of finished calls) measured no change and was taken out.

### What it decided

- **The only stream open does not run on the connection's fiber** (ADR 220's question 5). Inline is 4x the throughput, and a gRPC client puts every call on one connection, so one slow call would hold the rest and the connection's own PINGs behind it. The live test "two calls at once" is what holds that.
- **Spare streams are dropped when the connection waits with no call in flight**, not at the 200 ms idle release. Kept until then, a burst of 10,000 connections opening at once measured 5 MB more heap, which the allocator then held; dropped at the wait, the idle figure fell to below the unpooled one.

### Can it be pushed further

1. **A spawn on the calling executor.** The gap between 0.8M and 3.1M is almost all the cross-thread hop, and zio has no public call for "here"; the maintainer's proposal for one is [zio#704](https://github.com/lalinsky/zio/issues/704), which is `Placement.here` in the pinned mode nilo already runs. Nothing on nilo's side approaches it. Taken: [what placing a gRPC call on its own executor buys](#what-placing-a-grpc-call-on-its-own-executor-buys).
2. **The worst call.** 1.4 s at 256 connections is not explained. A per-call latency histogram, which h2load does not give, is the first thing to take; a client with percentiles (`ghz`) against the same build is the run.
3. **HPACK**, 247 ns of the 973. With a table of 0 every header is Huffman-decoded on every call; the next step is decoding only the fields the translation reads.
4. **The App's 229 ns** is the HTTP/1.1 parse of text this side just wrote. A request handed over already parsed would skip it, at the price of a second door into `handleRequest`, which is what the translation exists to avoid.

## Matching on a real table of 276 routes under one prefix

The roadmap held "whether the router needs a tree" open on one run: `zig build profile` on the application with 203 paths. That application is the Nodeflux ERP port (`nodeflux-os/backend-zig`), and its contract, `nodeflux-os/openapi.yaml`, lists **203 paths and 276 operations, every one under `/api`**: GET 101, POST 97, DELETE 32, PATCH 29, PUT 17; 2 to 6 segments, 114 of them at 4.

**Run:** `zig build profile -Dtarget=x86_64-linux-gnu -- --routes <file>`, the file being the 276 operations as `METHOD /pattern` with `{id}` written `:id`, extracted from `openapi.yaml`. Each route is matched against a path of its own shape (`7` for a param), best of five, so the figure weights the table evenly rather than by traffic nobody has measured. The same AMD Ryzen 7 9700X as above, now on kernel 7.2.5 (Arch), commit `0ba6fe3` plus the working tree that adds `--routes`. Three runs, back to back, load average under 1.

| | run 1 | run 2 | run 3 |
|---|---|---|---|
| the in-process request, one route | 362ns | 358ns | 360ns |
| match the route, one route | 19ns | 19ns | 20ns |
| **mean over the 276 routes** | **126ns (34.8%)** | **124ns (34.6%)** | **125ns (34.7%)** |
| median | 125ns | 123ns | 124ns |
| worst, `POST /api/work-items/:id/target-date` | 259ns | 251ns | 251ns |

The in-process request is 360ns here against the 181ns recorded above on an earlier commit; the ratio is what is read, and it is measured in the same run.

**Why the first-segment key does nothing here.** `Route.first_key` compares four bytes of the first segment, which took 44% off the synthetic 100-route set because every route there starts with a different word (`/thingN`). Every route in this table starts with `api`, so the key throws out nothing, and what is left to separate routes before any text is read is the method and the segment count. The biggest bucket those two leave is POST at 4 segments, **65 routes**, which is where the worst route is; the median sitting beside the mean says most of the cost is the walk over all 276 rather than the candidates, and 51 distinct second segments say a tree would reach the right branch in two steps.

**The decision it moved:** ADR 017 lets developer experience spend 10% of nilo's own work, and matching on this table spends 35% on average and 70% at worst. The router needs a structure, which the roadmap made conditional on exactly this number. Put against a request served over a socket (nilo's own work is about 4% of it, "The number that reframes the budget" above), the mean is about 1.4% of the CPU a request costs, so the case is ADR 017's bar rather than a throughput emergency.

### The tree, and two steps after it

Built beside the scan, every row measured by alternating two binaries from one working tree whose only difference is the router, three pairs each, same machine, same afternoon. The comparison binaries for the other routers are in the section below.

| | scan (`0ba6fe3`) | tree | tree + `matchInto` (shipped) |
|---|---|---|---|
| the in-process request, one route | 355–362ns | 360–365ns | 345–356ns |
| match the route, one route | 19–20ns | 19ns | 12–13ns |
| mixed 1 / 5 / 25 / 50 / 100 | 13–14 / 20–21 / 20 / 33–34 / 42 | 15 / 19 / 19 / 28 / 33–36 | 8–9 / 13–14 / 13 / 21–22 / 27–29 |
| same 1 / 5 / 25 / 50 / 100 | 23–24 / 25–26 / 36 / 50–51 / 86–96 | 26 / 26–27 / 29–30 / 34–35 / 43–44 | 19 / 19–20 / 22–24 / 27–29 / 37–39 |
| **mean over the 276 routes** | **124–126ns (34–35%)** | **34–35ns (9.4–9.7%)** | **27–28ns (7.7–8.0%)** |
| worst | 245–250ns | 61–63ns | 53–55ns |

**The tree** is ADR 012's ranking as a search order: literal, then param, then `*`, backing out of a dead end. It cost a one-route app 1 to 3ns on the synthetic sets and saved 90ns a match on the real table.

**`matchInto`** writes the `Match` into the caller's variable instead of returning it. A `Match` is about 300 bytes, and a temporary breakdown put the capture and its copies at about 13ns of the 35: it was a cost every request paid, which is why the one-route row moved as much as the big table did.

**Tried and dropped: searching the path without splitting it first** (matchit's way). The router got faster on its own, 24–25ns mean and 38–40ns worst, but the whole in-process request got slower by about 10ns in 11 of 12 alternating pairs (step 1 345–360ns, this 355–366ns), and a build with the search marked `noinline` did not bring it back (362–370ns), so it did not read as code layout. Nobody found where the 10ns went; the code is not in the tree, and it is the next thing to try with `perf` on a machine that has it.

**Tried and dropped: comparing eight child keys at once** with a vector at the node holding `/api`'s 51 children: 36–37ns against 35, so the child search was not where the time was.

### Against other routers, on the same table

The 276 operations through three other routers on this machine, each matching every route's own path, `7` for each param. The harnesses are not in this repository: Fiber's is a `_test.go` in a checkout of `gofiber/fiber` at `d0a059d` calling the unexported `app.next` the way its own `Benchmark_Router_Next` does; matchit and actix-router are a Rust binary built `--release` with LTO against checkouts of both.

| router | ns a route | how it matches |
|---|---|---|
| matchit (axum's) | 15.4–15.8 | a radix tree over bytes, no split; **path only**, 203 patterns, the method decided after |
| **nilo, tree + `matchInto`** | **27–28** | a tree of segments; method and path, 276 routes; the split and the capture included |
| Fiber v3 | 55.9–56.5 | per method, bucketed by the path's first three bytes, then a linear scan with SWAR filters; the path's hash is computed before the loop and not counted |
| actix-router | 2,800 | a linear scan, a regex a pattern, first match wins; path only |

Fiber and actix are not the fast routers they are fast frameworks around: under one `/api` prefix Fiber's three-byte bucket is one bucket, which is the old scan's problem with better filters, and actix relies on `web::scope` to keep each level small. matchit is the bar, and the gap to it is the split and the capture, not the tree.

**Can it be pushed further:** the 10ns the unsplit search cost the whole request is unexplained, and explaining it is worth up to 3ns a match on this table and 15ns at worst. Below that, matchit's 15ns is a router that does not choose a method.

### What the tree costs the binary

Stripped `ReleaseFast`, `-Dtarget=x86_64-linux-gnu`, `git archive HEAD` (`0ba6fe3`) against the working tree with the tree in it, each built from a scratch directory of the same path length: `examples/hello` 964,960 → 966,576 (**+1,616 B**), `examples/rest` 1,155,464 → 1,156,872 (**+1,408 B**). The same tree carries ADR 224's CSRF middleware, which neither example names and so neither pays for. The row is in ADR 017's running total.

## A fallback session secret

25 September 2026, on the Ryzen 7 9700X above, `0ba6fe3` plus the working tree of ADR 225. The "before" is that working tree with only ADR 225 taken out: `http/session.zig`, `ctx.zig`, `app.zig` and `bulkhead.zig` from `HEAD`, and the one line in `serve.zig`.

**What trying one more key costs.** `XChaCha20Poly1305` on the plaintext of a `Session(struct { user: u32, admin: bool })` (18 bytes), 2,000,000 calls a round, five rounds, `ReleaseFast`, pinned to one core with `taskset -c 2`. The harness is a single file in the session scratchpad and is not kept, because the whole of it is the two loops below.

| | ns a call, five rounds |
|---|---|
| decrypt under the right key | 374.1–374.6 |
| decrypt refused under a wrong key | 270.1–270.6 |

A refusal is cheaper than an open by the work after the tag, and it is not free: the subkey and the Poly1305 key have to be derived before the tag can be checked at all. So each fallback is 270ns on a cookie the current secret does not open, and three bound a forged cookie at four refusals, about 1.1µs. A cookie under the current secret opens on the first try and costs what it did. This is the number that set `max_fallbacks` at three rather than leaving it unbounded.

**Memory per idle connection.** `Ctx` goes from 816 to 824 bytes: a pointer to the App's slice rather than the slice, which measured 832. `bench/mem.py --path /health --steps 1000,5000,10000` against `nilo-hello` built `ReleaseFast` from each tree, before and after interleaved twice:

| | 1,000 | 5,000 | 10,000 |
|---|---|---|---|
| before, run 1 | 5,247 | 5,197 | **5,190** |
| after, run 1 | 5,247 | 5,197 | **5,190** |
| before, run 2 | 5,247 | 5,197 | **5,190** |
| after, run 2 | 5,247 | 5,197 | **5,190** |

**The same to the byte.** The only difference is at zero connections, 12 kB higher after on both runs, which is the larger binary mapped in. 5,190 is not the 4,669 in ADR 017 for the reason [`fetch.md`](fetch.md#the-transfer-buffer-was-never-a-resident-page) gives: this box reads `/health` at 5,186 whatever is measured on it, so only the difference is comparable.

**Binary size.** Stripped `ReleaseFast`, each tree from a scratch directory of the same path length: `examples/hello` 966,576 → 967,200 (**+624 B**), `examples/rest` 1,156,872 → 1,157,464 (**+592 B**), `examples/forms`, the one example that seals a session, 1,063,400 → 1,063,928 (+528 B). It is the check in `listen()` and its four one-line messages, which a program that listens links whether it names a fallback or not.

**A misreading on the way, kept because it looks like a result.** The first size comparison put the two trees' binaries in one `ls -l out-before/bin/ out-after/bin/`, and read the change as 624 bytes *smaller*. `ls` sorts its arguments, so `out-after` was printed first. Building each tree again from a second directory reproduced both sizes to the byte, which is what settled it. Name the side on the line that prints the number.

**Can it be pushed further:** not on the path that matters, which is already the cost it was. A key id in the cookie would take a stale cookie from 270ns a fallback to none, and would sign everybody out once to get there (ADR 225).

## What a CPU quota does to a thread per core

[ADR 230](../../docs/adr/230-a-cpu-quota-sets-the-thread-count.md) is the decision; these are the runs.

**Instrument and shape.** gcannon `11c802b` (liburing 2.15), `-t 8`, five seconds, 512 connections unless said; `nilo-hello` (`bench/main.zig`) in `ReleaseFast` for `x86_64-linux-gnu`, on port 18787; an AMD Ryzen 7 9700X under Linux 7.2.5. The quota is a `systemd-run --user --scope -p CPUQuota=…` around the server. The server is on CPUs 0–7 and gcannon on 8–15, **which are the SMT siblings of 0–7**: every figure in this section shares that, so the comparisons inside it hold and the absolutes are low against a split by physical core. CPU is `utime + stime` of the server across the run. Before is `53d0792`; after is the working tree with ADR 230. Each tree built with its own cache (`docs/history.md`, "Give every tree its own build cache").

**The count, by hand, at one CPU set.** A build of the tree with `threads` from an environment variable, `/users/1`, keep-alive:

| quota | threads | req/s | p50 | p99 | p99.9 | server CPU |
|---|---|---|---|---|---|---|
| 1 CPU | 1 | 349–354K | 910 µs | 22 ms | 27 ms | 3.5 s |
| | **2** | **487–495K** | 740 µs | 26–27 ms | 32–33 ms | 5.1 s |
| | 3 | 463–470K | 510 µs | 50–51 ms | 56–58 ms | 5.1 s |
| 2 CPUs | 2 | 694–697K | 740 µs | 836–852 µs | 0.93–0.97 ms | 7.1 s |
| | **3** | **917–932K** | 510 µs | 620 µs | 9.9 ms | 10.1 s |
| | 4 | 900–909K | 390 µs | 490 µs | 35 ms | 10.1 s |
| | 8 | 748–758K | 215 µs | 1.3–2.0 ms | 70–71 ms | 10.2 s |
| 4 CPUs | 4 | 1.27–1.31M | 390–403 µs | 449–476 µs | 0.53–0.59 ms | 14.7 s |
| | **5** | **1.56–1.57M** | 325 µs | 376–387 µs | 0.46–0.49 ms | 18.4 s |
| | 6 | 1.60–1.62M | 285 µs | 423–436 µs | 10–11 ms | 20.2 s |
| | 8 | 1.48–1.49M | 215 µs | 0.8–1.2 ms | 35–36 ms | 20.0 s |

Two readings. **At the quota, the quota is not spent**: two threads under two CPUs used 7.1 of 10 CPU-seconds, and two threads on two unlimited cores did the same (773–778K, 6.8–6.9 s), so an executor at this load is idle part of its time and a thread past the quota fills it. **Past quota plus one the quota is spent early and the period's remainder shows in the tail**: 35 ms and 70 ms are fractions of the 100 ms CFS period.

**The rule against the old count**, three interleaved pairs, `/users/1`:

| quota | before (a thread per core) | after (quota rounded up, plus one) |
|---|---|---|
| 2 CPUs | 749–758K, p99 1.2–1.4 ms, p99.9 71–72 ms | 919–928K, p99 0.62 ms, p99.9 10–11 ms |
| 4 CPUs | 1.48–1.49M, p99 0.68–0.79 ms, p99.9 36 ms | 1.53–1.56M, p99 0.37–0.38 ms, p99.9 0.45–0.53 ms |
| none | 2.14–2.15M, p99.9 1.2–1.4 ms | 2.14M, p99.9 1.3–1.6 ms |

With the quota on a parent slice (`systemctl --user set-property nilotest.slice CPUQuota=200%`, the server in a scope under it) the count is 3, which is the case zio's and dusty's readers, which look only at the process's own cgroup, would miss.

**Binary.** `nilo-hello` stripped, 979,112 bytes before and 984,792 after, both built from a clean archive the same afternoon: 5.7 KB, of which about 2.2 KB is the reader and 3.6 KB the one log line (measured apart, on an earlier state of the change). As first written with the quota an `f64` it was 1,008,248, float formatting for the line.

**Can it be pushed further.** The one more is a loopback reading, where part of each request's kernel work is charged to the client's CPU. Behind a real NIC more of it lands on the server's cgroup, and the right count may be the quota itself; a run with the load generator on another machine is what would say.

## How many acceptors eight threads want

[ADR 200](../../docs/adr/200-every-executor-accepts.md) kept one acceptor per executor; this is the run behind its log2 alternative, which [dusty](https://github.com/lalinsky/dusty) measured as the knee on 24 threads.

Same instrument and machine as the section above, no quota, eight threads, **server on CPUs 0–3,8–11 and gcannon on 4–7,12–15**, which splits them by physical core. The acceptor count capped by hand in a scratch tree of `53d0792`; three interleaved rounds of the four counts:

| shape | 8 (one per executor) | 5 | 3 (log2) | 2 |
|---|---|---|---|---|
| 512 conns, 1 request each, `/health` | 466–477K, p50 490–530 µs, p99 2.0–4.1 ms | 456–478K | 472–490K, p99 1.7–3.2 ms | 483–487K, **p50 985 µs**, p99 1.5–1.7 ms |
| 512 conns, 10 requests each | **1.81–1.83M** | 1.78–1.79M | 1.70–1.72M | 1.60–1.62M |
| 4,096 conns, 10 requests each | **1.64–1.68M**, p99 23.5–33 ms | 1.65–1.66M | 1.58M | 1.49–1.51M |
| 512 conns, keep-alive, `/users/1` | 2.05–2.06M | 2.06M | 2.06M | 2.05M |

**No knee at eight threads.** Where a connection carries one request, fewer acceptors are inside the spread, two at most 4% ahead and at twice the p50; where it carries ten, log2 loses 4–7% and two loses 8–13%; keep-alive does not move. One per executor stays. An earlier pass of the same sweep with the SMT split of the section above read the same way, inside a wider spread.

**Can it be pushed further.** Not on this box. dusty's loss past five loops was on 24 threads and the arena's box has sixty-four; the roadmap carries the run.

## What reading every byte of the head costs

[ADR 070](../../docs/adr/070-a-request-nobody-else-would-answer-is-refused.md) and [ADR 095](../../docs/adr/095-a-target-is-read-in-the-form-it-arrived-in.md) have the rules and [ADR 231](../../docs/adr/231-a-second-parser-reads-what-the-first-one-reads.md) the run against llhttp that found them: a control byte or a bare CR anywhere in the head, a method or header name that is not a token, and a target in none of the four forms are refused, where before only five headers were read. Unlike the first group in ADR 070, this looks at every byte and every name.

Before is `a629d1d`; after is it plus the parser change, each tree from `git archive` with its own cache, checksums compared. 9700X, Linux 7.2.5, `-Dtarget=x86_64-linux-gnu` (baseline x86-64), ReleaseFast.

**End to end**, the axis ADR 017 budgets: `nilo-hello` on CPUs 0–3,8–11, gcannon `11c802b` on 4–7,12–15, 512 keep-alive connections, eight threads, `/users/1`, five seconds, three interleaved pairs. The request is sent as a raw file: wrk's 125-byte head, and a Chrome navigation's 659-byte one with fourteen headers.

| head | before | after | p99 | p99.9 |
|---|---|---|---|---|
| wrk, 125 bytes | 2.04–2.05M req/s | 2.00–2.01M, −1.5 to −2.4% | 477–492 → 453–477 µs | 0.85–0.94 → 0.71–0.73 ms |
| browser, 659 bytes | 1.96–1.98M | 1.88–1.89M, −3.6 to −4.5% | 485–495 → 416–470 µs | 0.84–0.92 → 0.66–1.11 ms |

**Memory per idle connection**, `bench/mem.py --path /users/1` out to 10,000: 9,288 bytes before, 9,289 after. **Binary**, stripped: `hello` 976,864 → 981,040, `rest` 1,166,376 → 1,170,520, `nilo-hello` 984,792 → 988,936.

**`zig build profile`**, pinned to CPU 2, interleaved, with the head handed over as bytes the compiler cannot see (`unseen` in `profile.zig`; it made no difference here, and a constant is the wrong thing to hand a parser):

| row | before | after |
|---|---|---|
| parse the head (wrk's, 121 bytes) | 32–34ns | 54–55ns |
| parse a browser's head (682 bytes) | 78–79ns | 154–156ns |
| the whole in-process request | 356–370ns | 423–427ns |

The whole request grew by more than the parse did: 361 → 409–410ns with `parseHead` kept out of line on both sides, where the parse row alone is +22ns. Not run down. The likeliest reading is branch prediction: the new branches are per name and per block, a loop timing only the parser lets the predictor learn them, and a request between two parses does not. The end-to-end run is the one that includes that, and it is what the decision rests on.

**The shapes tried**, timed in a harness of `parseHead` alone that counts parse errors (`catch unreachable` let LLVM delete every refusal, see `docs/history.md`), baseline x86-64, wrk's head / the browser's:

| shape | after |
|---|---|
| before, for reference | 29–30 / 63–64ns |
| the block shifted a lane for "CR then LF", the full `tchar` class per name, a flag per line | 55.7 / 170ns |
| the same with the stray bytes from the loop's own LF mask, three compares a block | 51.8 / 149ns |
| the same with a name tested for letters, digits and `-` first | 50.6 / 158ns |
| both, which is what shipped | 46.6 / 138.7ns |
| a name class computed per block and tested per line by bit arithmetic | 52.6 / 164.8ns |
| the first stray byte kept as a position, one compare a line | the same or worse than a flag in all four pairings, by up to 4.6ns on wrk's head and 25ns on the browser's |

Taken apart in the first shape: with all five new checks out the harness read 29.4 / 63.0ns, the same as before, so the `Connection` list and the target forms cost nothing on these heads; the name check was 11 / 34ns and the stray bytes 8 / 48ns.

**Can it be pushed further.** Probably. The name test is nine or three compares a name where a byte-class table lookup (`pshufb`, NEON `tbl`) is two, and Zig 0.16 has no portable runtime shuffle to write it with. Folding the name test into the block walk measured worse here, but it was measured as one shape among several; a version that tests only blocks holding a name start is untried.

## What placing a gRPC call on its own executor buys

The first cut of [zio#704](https://github.com/lalinsky/zio/issues/704) landed on zio `main` as `spawnInto` ([zio#761](https://github.com/lalinsky/zio/pull/761), `0299e57`, not in a release), with `.local` homing a task on the calling executor. The same zio also removed `RuntimeOptions.enable_task_migration`: the mode is `zio_options.scheduling`, read from the root module, and without a declaration it is `.work_stealing`, where `.local` returns `error.InvalidPlacement`. The run below is the upgrade that keeps nilo pinned without a line in the application: `.scheduling = .pinned` passed to every `b.dependency("zio", …)` in `build.zig`, which a root `zio_options` still overrides.

Three trees from `git archive` of `d7c40bb`, each with its own cache: **A** as committed (zio v0.18.0); **B** zio `0299e57`, pinned through the build default, `enable_task_migration` dropped, every spawn still `.auto`; **C** B with the engine's `spawn` calling `group.spawnInto(.local, …)`, which is what `http/grpc.zig` starts a call through. `spike/grpc/server/` built ReleaseFast against each, and the instrument of [the gRPC throughput section](#throughput): h2load posting a 9-byte `SumRequest` to `GetSum`, `-m 100`, eight threads, 5 s, server on CPUs 0–3,8–11 with `NILO_THREADS=8`, h2load on 4–7,12–15, loopback. Three rounds, the order reversed every other round; CPU and context switches per call from `/proc` across the h2load run. No run errored, and a call to C answered `grpc-status: 0`, so no call went down the `InvalidPlacement` path, which answers 14.

| c | tree | calls/s | CPU per call | context switches per call | mean | max |
|---|---|---|---|---|---|---|
| 256 | A | 739–752k | 4.69–4.74 µs | 0.92–0.93 | 27–28 ms | 1.45–1.51 s |
| 256 | B | 755–756k | 4.53–4.56 µs | 0.80–0.81 | 27–28 ms | 1.55–1.79 s |
| 256 | C | **2.06–2.08M** | 3.73–3.78 µs | 0.035–0.036 | 12.3–12.5 ms | **51–52 ms** |
| 1,024 | A | 545–554k | 7.40–8.12 µs | 0.73–0.83 | 116–130 ms | 3.40–3.85 s |
| 1,024 | B | 555–557k | 7.62–8.37 µs | 0.55–0.64 | 124–138 ms | 3.19–3.59 s |
| 1,024 | C | **1.61–1.63M** | 4.81–4.87 µs | 0.034–0.036 | 64–65 ms | **149–167 ms** |

**The zio upgrade alone moves nothing**: B is inside 2% of A on throughput at both counts. **`.local` is 2.7x at 256 and 2.9x at 1,024**, context switches fall from nearly one a call to one in thirty, and **the worst call falls from 1.5 s to 52 ms**, which answers item 2 under "Can it be pushed further" in [the listener's section](#a-grpc-listener-built): the unexplained worst call was the hop, not HPACK or the stream table.

**What it decided**: the call fiber goes on `.local` (`bulkhead.spawnLocal`), and nilo sets the scheduling mode through `b.dependency` rather than asking every application to declare `zio_options`, which the maintainer confirmed is how zio means a dependent to do it ([#704](https://github.com/lalinsky/zio/issues/704)). The pin moved to `0299e57` on zio's `main` rather than waiting for a release, once the run below said the upgrade costs the rest of the server nothing. The committed code, `spawnLocal` with its fallback, measured again against A at c=256, two interleaved rounds: 2.04 to 2.06M calls/s and a worst call of 46 to 52 ms, against 758 to 760k and 1.32 to 1.47 s.

### What the upgrade costs everything else

The same A and B, now from `9630a47`, with `nilo-hello` moved to port 18787 in both trees because another project's server held 8787 (the first pass measured that server, see `docs/history.md`). ReleaseFast for `x86_64-linux-gnu`, stripped; server on CPUs 0–3,8–11 and gcannon `11c802b` on 4–7,12–15, `/users/1`, 512 connections, `-t 8`, five seconds, three interleaved rounds; `bench/paced.py` at `/health`, 64 connections, 6 s, two rounds; `bench/mem.py --path /users/1` to 10,000, two rounds.

| | A, zio v0.18.0 | B, zio `0299e57`, pinned by the build |
|---|---|---|
| keep-alive | 2.04–2.06M req/s, p99 459–497 µs | **2.12–2.13M**, p99 475–489 µs |
| 10 requests a connection (`-r 10`) | 1.56–1.58M | 1.61–1.70M |
| 5,000 req/s, CPU a request | 5.7–6.0 µs, 3.00 context switches | **4.7–5.0 µs, 1.00** |
| 1,000 req/s, CPU a request | 6.7–8.3 µs, 3.01 | 6.7–10.0 µs, 1.00 (0.04 s of CPU a window, too coarse to read) |
| idle connection | 9,279–9,280 B | 9,279 B |
| stripped binary | `nilo-hello` 988,936, `example-rest` 1,170,520 | **+6,888 to +6,920 B** on every binary built |

`test-all` passes on B against a live Postgres 18 and SeaweedFS the way CI runs them: 758 of 758 steps, 4,761 of 4,764 tests, the three skips being `job/live.zig`'s Postgres tests, which run only in Debug by design. The allocation budget is a test in that gate.

**Nothing moved the wrong way, and the idle server moved the right one.** One context switch a request where A had three is the pinned build showing: a build that stole would have added switches, not removed them (ADR 199). The binary cost is zio's, and the linker cannot drop it; it goes in ADR 017's running total with the pin.

**Can it be pushed further.** Yes. C is 2.07M against 3.12M inline, and 3.75 µs a call against 2.5; the fiber measured 0.23 µs on one executor, so about a microsecond is still unaccounted for and was not run down. The connection an acceptor spawns is the other round-robin hop left, and `.local` there is a separate run: the engine chose round-robin for connections on purpose (`http/engine/zio.zig`, above `Acceptor`).

## What a request serial in every build costs

Asked when `core.Lifetime`'s counter stopped being Debug-only, so that `sql.problem` can tell the request that failed from the next one on its connection ([ADR 117](../../docs/adr/117-a-statement-that-failed-says-what-the-database-said.md)). The claim was that eight bytes on the connection loop's frame, one atomic add per connection and one add per request move none of the four axes by a number worth quoting. Measured 2026-09-30 on a 2-vCPU Xeon Platinum 8255C VM, Linux 6.8, Zig 0.16.0, `-Dtarget=x86_64-linux-gnu`: before is a `git archive` of `cb45ea9`, after is the same with `core/str.zig`, `core/scope.zig`, `core/core.zig` and `http/ctx.zig` from the change, each in a scratch directory of the same path length.

**Memory per idle connection does not move.** `bench/mem.py --port 8787 --path /health --steps 1000,5000,10000` against `nilo-hello`, `ReleaseFast`, stripped, three runs interleaved after, before, after: 5,247, 5,197 and 5,190 bytes a connection at the three steps, identical in all three. The frame grew by eight bytes and stayed inside the page it was already in.

**Binary size**, stripped `ReleaseFast`: `examples/hello` 987,992 → 988,016 (**+24 B**), `examples/rest` 1,177,504 → 1,177,528 (**+24 B**), `nilo-hello` 995,888 → 995,912.

**Allocations per request** do not move: the counter is a field that already existed in Debug. Throughput was not run: one add per request against a round trip is below what wrk on a shared 2-vCPU box can see.

Whether it can be pushed further: the eight bytes could go to four by dropping the span in a release build, at the cost of a new connection in a reused stack counting through the numbers an old one left in `sql.problem`'s slot. Not worth four bytes that do not show up in RSS.

## What a body that fails, or is only padding, costs the arena

Three requests that cost the request arena far more than their size, found by the audit of `http/` at `39896d2` and measured here before and after the fix (ADR 226, ADR 030). **The instrument is a test that counts the bytes the arena was asked for** (`budget.Counting` wrapped around the arena, in `http/behaviour.zig` and `http/form.zig`), which is the same number on every machine and says nothing about time.

**Run on** an AMD Ryzen 7 9700X (16 threads), Linux 7.2.5, Zig 0.16.0, at `462d84d` plus the change, `zig build test -Dtarget=x86_64-linux-gnu` (Debug). The before is the same tree with the fix switched off for the run, not a quoted figure. Arena bytes are deterministic, so one run each; the one timing, the multipart search, is the best of five.

**A body that fails to parse, sent to a plain struct route.** `POST /echo` where the handler reads `struct { message: []const u8 }`, body `[` repeated `depth` times. The first parse fails at once (an array where an object was wanted); `describeBadBody` then read the whole body again as a `std.json.Value`.

| depth (= body bytes) | arena before | arena after | before / body |
|---|---|---|---|
| 1,000 | 83,200 | 1,183 | 83 |
| 4,000 | 505,649 | 4,183 | 126 |
| 16,000 | 2,476,033 | 20,280 | 155 |
| 64,000 | 8,267,656 | 68,280 | 129 |
| 250,000 | 50,080,250 | 254,281 | 200 |
| 1,000,000 | **174,406,291** | **1,004,282** | 174 |

After the fix the arena holds the body and about 4 KB of head and answer, whatever the depth. The 1,000,000 row is the default `max_body` and is what one request can send, so one connection could make the arena ask for 174 MB for a 1 MB request, and it did not crash in this run only because the test thread's stack was deep enough to recurse a million levels; a fiber's is not (ADR 226). The scan costs one pass over a body that has already failed.

**A urlencoded form of nothing but `&`.** `parse(.urlencoded)` on 1,048,576 bytes of `&`: **33,554,464 bytes of arena before**, thirty-two times the body, one `Param` per `&` allocated before a byte is read. After: **0 bytes**, the form is refused for its pair count (`max_pairs`, 1,024, a 400) before `parseQuery` runs. A form of exactly 1,024 pairs reads, one more is refused.

**A multipart form of 255 parts and a megabyte of padding.** The search for each part's blank line ran `\n\n` to the end of the body, once per part. 254 calls of the old search over a 1 MiB body took **4,755,579 µs** in this Debug build (the audit's ReleaseFast figure was 78 ms; the ratio is what carries, and Debug is the slower of the two builds that run in `test-all`); the whole parse after the fix, the same body, took **1,873 µs**, and the test holds it under twenty passes of `std.mem.count` over the same body, where the old search is two hundred and fifty. The search now stops at the first blank line, CRLF or bare LF, so it is parts plus bytes and not parts times bytes.

**What decided what.** The depth scan goes in front of the second parse for every type, not only for one that can nest (ADR 226). The pair limit is 1,024, 32 KiB of arena at most, past anything a browser sends and the same kind of bound `max_parts` is (ADR 030). Neither adds an allocation to a request that did not ask for it: the allocation-budget test passes unchanged.

**Can it be pushed further.** The 174 times is gone and the remaining cost is the body, which `max_body` already bounds. The multipart timing is Debug only; a ReleaseSafe figure beside it would be worth one line the next time this is run. The urlencoded number is bounded, not minimised: 1,024 pairs is 32 KiB for a form that has them, and a form of two fields pays for two.

## What gzipping holds a thread for, by size, and where `max_bytes` stands

**What was run.** `zig build bench-compress`, whose second table is new: one `Pool.gzip` on one thread at five body sizes, at `.fastest` and `.default`, `ReleaseFast`, the same JSON shape as the arena's `json-comp` profile (items of about 164 bytes), the request arena reset between rounds as a request would. Enough rounds for about a quarter of a second each and never fewer than five. No server and no socket: the number wanted is how long `Ctx.send` holds an executor thread while it compresses, because deflate runs whole and there is no point inside it where the fiber parks.

**Machine and commit.** AMD Ryzen 7 9700X, 8 cores and 16 threads, Zig 0.16.0, loopback irrelevant; on `1738286` plus the change that adds `Options.max_bytes`. The "before" is the same compressor: nothing in the deflate path changed, so there is no second build to compare, and what the bench adds is the sweep.

| bytes in | level | bytes out | ms/body | MB/s |
|---|---|---|---|---|
| 41,028 | `.fastest` | 6,410 | 0.178 | 230 |
| 41,028 | `.default` | 4,690 | 0.258 | 159 |
| 164,398 | `.fastest` | 24,667 | 0.679 | 242 |
| 164,398 | `.default` | 17,104 | 1.057 | 156 |
| 991,794 | `.fastest` | 145,619 | 4.196 | 236 |
| 991,794 | `.default` | 99,794 | 6.573 | 151 |
| 3,984,446 | `.fastest` | 582,362 | 16.775 | 238 |
| 3,984,446 | `.default` | 397,973 | 26.597 | 150 |
| 19,986,580 | `.fastest` | 2,916,434 | 83.853 | 238 |
| 19,986,580 | `.default` | 1,991,571 | 130.417 | 153 |

**What it showed.** Time is linear in size from 164 KB up, at about 150 MB/s on `.default` and 240 MB/s on `.fastest`, so there is no knee to find: the cap is a policy about how long a thread may be held, and the table converts it. A 20 MB JSON export held its thread for 130 ms with nothing else on it running; 130 ms is more than half of `block_warning_ms` (250), which is what the framework calls a handler blocking its thread.

**The decision it moved.** `Options.max_bytes` defaults to 1 MiB (1,048,576): about 6.6 ms on `.default` here, a thirty-eighth of the watchdog's figure, which leaves room for a machine five or six times slower before gzip alone reaches it. 4 MiB (27 ms here) was the alternative: it fits a slow machine too, but a body that big is a download rather than an API answer, and a download is better compressed ahead of time. Zero takes the limit off. A body over it goes out uncompressed and without `Vary`, since the same body is sent to every client (ADR 211).

**Can it be pushed further.** The 150 MB/s is the standard library's deflate at level 6, and 6 us of a small body is the hash table's reset, neither of which this changes. A compressor that yielded between blocks would remove the cap's reason, and costs a compressor held across a park, which ADR 211 refuses. The figures are from one machine; a slower core moves the cap's headroom, not its shape.

## What tracing and security headers cost a program that does not use them

**What was run.** Every example and `zig build size-s3 size-trace`, stripped `ReleaseFast`, `-Dtarget=x86_64-linux-gnu`, built at `5454e48` (from `git archive HEAD` into a scratch directory) and with the change that adds `nilo.secure` and `app.trace`. Then `bench/mem.py --port 8787 --path / --steps 1000,2000,5000,10000` against `examples/hello` from each tree, interleaved over two rounds, and the same against `nilo-size-s3_none` and `nilo-size-trace_on` on `/avatars/1`. `nm --size-sort` over unstripped builds of `hello` and `outbound` said where the bytes were.

**Machine and commit.** A 2-core KVM guest, Intel Xeon Platinum 8255C at 2.5 GHz, Zig 0.16.0, over loopback. Sizes and RSS do not depend on how busy the machine is.

| program | before | first build | shipped |
|---|---|---|---|
| `example-hello` | 1,008,784 | 1,020,816 (+12,032) | 1,009,216 (**+432**) |
| `example-rest` | 1,211,384 | 1,223,448 (+12,064) | 1,211,768 (**+384**) |
| `example-outbound` | 1,732,872 | 1,748,728 (+15,856) | 1,735,896 (**+3,024**) |
| `nilo-size-s3_none` | 1,131,384 | 1,142,840 (+11,456) | 1,131,384 (**+0**) |
| `nilo-size-trace_on` | | | 1,821,608 (+690,224 over `s3_none`) |

| idle connections | `hello` before | `hello` after | `s3_none` | `trace_on` |
|---|---|---|---|---|
| 1,000 | 5,247 B | 5,247 B | 7,295 B | 8,286 B |
| 10,000 | 5,190 B | 5,190 B | 7,238 B | 7,342 B |
| marginal, 5,000 to 10,000 | | | 7,232 B | 7,233 B |

**What it showed.** The first build called the tracer behind a runtime null check, and the linker kept all of it: `Tracer.begin` and `finish`, the generator per thread (1,640 bytes), the header walk, sizing the rings in `listen`, freeing them in `deinit`, the logger's trace field, and in `outbound` the URL parse and `traceparent` formatting. The security headers' line matching in `putHeader` was 1,156 more. Moved behind pointers that only `app.trace`, `Tracer.init` and `Ctx.putPolicy` set, it went: what is left is the null checks, two indirect calls and `writeExtra`. The 96 bytes the Ctx gained (88 for the trace state, 8 for the policy pointer) crossed no page on `hello`: measured again on the shipped build, 5,190 to 5,191 bytes a connection on both sides. With tracing on, the marginal figure is the same as without, and the 1.6 MB difference is fixed: rings filling, the batch and the exporter's client.

**The decision it moved.** The shape of both features: every piece of code that only a traced or policy-carrying request runs is reached through a pointer the opt-in call sets, never through a call guarded by a runtime check (ADR 246, ADR 247). ADR 017's running total gets one row, +432 and +384.

**Can it be pushed further.** `outbound`'s +3,024 is `withCarried`'s trace branch and the `traceparent` formatting on every `nilo_fetch` call under a `Ctx`. It could move behind the tracer's pointer as well, by having the tracer write the header text into the `Outbound`, and nobody has measured whether that is worth a field on a core type. The fetch frame's growth under ADR 062 was not measured against `bench-fetch-server`.

## Which deflate is fastest, and whether brotli or zstd would beat it

**What was run.** `bench/compare-compress/run_all.sh`: the bodies the arena's `json-comp` profile asks for (built from HttpArena's `dataset.json` at (25,4), (40,8) and (50,6)), `bench-compress`'s own bodies, and three large ones, each compressed by `std.flate` at levels 1, 6 and 9 through a copy of `Pool.gzip` and `reset`, and by libdeflate 1.26, zlib-ng, zstd and brotli at a sweep of levels. Every output was decompressed by its reference decoder and checked. The C libraries were built with `zig cc -O3 -DNDEBUG` for `x86_64_v3+aes+pclmul`, the CPU nilo's HttpArena image targets. The `std.flate` side gives byte-identical output to `zig build bench-compress` on `5454e48` (748, 1,041 and 1,225 bytes).

**Machine and commit.** A KVM guest with 2 cores, Intel Xeon Platinum 8255C at 2.5 GHz, Zig 0.16.0, at `5454e48`. **The machine was busy**, with load average 4 to 6 from a test suite running beside it, so the figures are thread CPU time (`CLOCK_THREAD_CPUTIME_ID`, which leaves out time spent waiting for a core), pinned with `taskset -c 1`. Codecs were interleaved, over two independent runs of seven repetitions each; the medians of the two runs agree to 2% (at most 11%). A first run on wall-clock time spread 50% to 200% and was thrown away. The guest has no PMU, so instruction counts could not be taken. This core is about 4.6 times slower than the 9700X above (`std.flate` level 6 on a 4 KB body: 171 µs against 37.5 µs), so **the ratios carry to another machine and the microseconds do not**.

Median CPU a body on the arena's bodies, and the ratio to today's default:

| codec | arena-25 (4,190 B) | arena-40 (6,707 B) | arena-50 (8,397 B) | × `std.flate` 6 |
|---|---|---|---|---|
| `std.flate` 1 | 1,096 B, 172 µs | 1,542 B, 208 µs | 1,866 B, 230 µs | 0.87 |
| **`std.flate` 6** (today) | **946 B, 191 µs** | **1,299 B, 239 µs** | **1,521 B, 277 µs** | **1.00** |
| libdeflate 1 | 1,012 B, 30 µs | 1,421 B, 42 µs | 1,708 B, 51 µs | 0.17 |
| **libdeflate 6** | **937 B, 62 µs** | **1,270 B, 97 µs** | **1,478 B, 122 µs** | **0.40** |
| zlib-ng 6 | 947 B, 60 µs | 1,301 B, 94 µs | 1,519 B, 117 µs | 0.38 |
| zstd 1 | 960 B, 25 µs | 1,332 B, 33 µs | 1,585 B, 39 µs | 0.14 |
| brotli 1 | 1,084 B, 45 µs | 1,554 B, 54 µs | 1,876 B, 82 µs | 0.25 |
| brotli 5 | 846 B, 205 µs | 1,170 B, 275 µs | 1,375 B, 323 µs | 1.14 |
| brotli 11 | 716 B, 10.8 ms | 994 B, 16.7 ms | 1,179 B, 21.9 ms | ~70 |

On 1 MB, `std.flate` 6 is 106,428 bytes in 21.8 ms, libdeflate 6 is 80,635 in 10.7 ms, and zstd 3 is 69,164 in 2.6 ms.

| | memory a compressor | stripped `ReleaseFast` size, static musl probe |
|---|---|---|
| `std.flate` (today's pool slot) | 295,640 B | +24.6 KB, already in every nilo binary |
| libdeflate, levels 2 to 9 | 668,295 B, one allocation, reusable | **+64.5 KB**, no libc needed |
| zstd | grows to the largest body, 74 KB to 1.3 MB | +386 KB, and std has no encoder |
| brotli | cannot be reset or pooled: 1.44 MB allocated a 4 KB body | +913 KB |

**What it showed.**

- **libdeflate at level 6 is 2.5 times faster than `std.flate` at level 6 on the arena's bodies, and 2% smaller.** On 1 MB it is twice as fast and 24% smaller. Its output is gzip, so nothing about `Accept-Encoding` changes.
- **brotli is the smallest and never the fastest worth having.** At level 5 it is 10% smaller than `std.flate` 6 and 14% slower. It cannot be pooled, so every body allocates 1.4 MB, which is ADR 017's allocation axis spent on the request path.
- **zstd is the fastest at every size.** HttpArena's validator accepts only `gzip` and `br`, about 83% of browsers send it, and Zig 0.16's std decodes it and does not encode it.
- **22% of `std.flate`'s time on an arena body is a memset nobody needs**: `toks.* = .empty` in `writeBlock` (`Compress.zig` lines 987 and 1055) rebuilds the 96 KB token buffer from its constant after every block. A scratch copy assigning the fields one by one gave byte-identical output 18% to 44% faster, about 50 µs a body here. That is a one-line change to the standard library, not to nilo.
- Two lines above were wrong and are corrected: the reset clears the hash table's 64 KB `head` (32,768 two-byte entries), not 128 KB.

**The decision it moved.** Nothing shipped. brotli and zstd are refused on these numbers ([`docs/decided.md`](../../docs/decided.md)). libdeflate behind a build flag, the way `-Dtls` brings tls.zig (ADR 212), is the candidate, and its open questions are on [`docs/todo.md`](../../docs/todo.md). Under HttpArena's score, `rps × (min_bytes / my_bytes)²`, with compression about 0.78 of a `json-comp` request's CPU (230 µs a request on the board against 49 µs for `json-tls`), libdeflate 6 scores about 1.95 times today's entry and brotli 5 about 1.10. That model has not been checked against the board.

**Can it be pushed further.** Yes, three ways. Run it again on a quiet machine and on a Zen 5, since the ratios have been measured only on this one. Measure the RSS libdeflate actually touches on a small body, which is bounded by the 668 KB above and not yet known. And the memset fix goes upstream to Zig, which every nilo build would get for nothing.

## libdeflate against `std.flate` on a quiet Zen 5, and what it keeps resident

**What was run.** `bench/compare-compress/run_all.sh` as it stands, with HttpArena's `data/` at `484dea6`, and the new `rss.zig` beside it: each compressor alone in an anonymous mapping under `MADV_NOHUGEPAGE`, its resident pages counted with `mincore` after the allocation, after one 4 KB body (`arena-25`), after ten more small bodies, and after a 1 MB one (`arenalarge-all`). The std.flate slot is built the way `Pool.init` builds it, `Compress.init` once and the in-place `reset` before each body. libdeflate 1.26 (`92e6a0d`), the same flags as the run above.

**Machine and commit.** AMD Ryzen 7 9700X (Zen 5, eight cores and sixteen threads), Linux 7.2.5, Zig 0.16.0, nilo `bb0f859`. **The machine was quiet**: load 0.3 when it started, and thread CPU time and wall-clock medians agree to 0.2% (`arena-25` at libdeflate 6, 10.11 against 10.13 µs), so here the figures are what a server pays. Seven interleaved repetitions, spread under 5% on every row quoted. Every output is the same byte count as on the Xeon, so both runs timed the same work.

Median a body, and the ratio beside the Xeon's:

| body | `std.flate` 6 | libdeflate 6 | × `std.flate` 6 | on the Xeon |
|---|---|---|---|---|
| arena-25 (4,190 B) | 946 B, 40.3 µs | 937 B, 10.1 µs | 0.25 | 0.32 |
| arena-40 (6,707 B) | 1,299 B, 53.6 µs | 1,270 B, 14.7 µs | 0.27 | 0.41 |
| arena-50 (8,397 B) | 1,521 B, 63.2 µs | 1,478 B, 18.0 µs | 0.28 | 0.44 |
| bench-400 (65,705 B) | 7,191 B, 420 µs | 5,891 B, 144 µs | 0.34 | |
| bench-6400 (1,057,992 B) | 106,428 B, 6.96 ms | 80,635 B, 2.52 ms | 0.36 | 0.49 |
| arenalarge-all (1,070,913 B) | 152,254 B, 9.26 ms | 140,345 B, 5.85 ms | 0.63 | |

Bytes resident, per compressor:

| | allocated | after the allocation | one 4 KB body | ten more small | one 1 MB body |
|---|---|---|---|---|---|
| `std.flate` slot, any level | 295,640 | 172,032 | 184,320 | 196,608 | 299,008 |
| libdeflate 1 | 202,759 | 8,192 | 143,360 | 143,360 | 176,128 |
| libdeflate 6 | 668,295 | 8,192 | 217,088 | 229,376 | 376,832 |
| libdeflate 9 | 668,295 | 8,192 | 217,088 | 229,376 | 368,640 |

Two runs of `rss` gave the same pages to the byte. The size probes match the run above: libdeflate with no libc is 69,352 bytes against 4,840 for the empty program, the same +64.5 KB.

Stack one call writes below its caller (`stack.zig`: the thread's stack painted, one call, the deepest changed byte), the same on every body from 4 KB to 1 MB to within 304 bytes, and the same over three runs:

| | libdeflate 1 | libdeflate 6 and 9 | `std.flate` 1 and 6 (reset, write, finish) |
|---|---|---|---|
| stack | 2,768 B | 3,120 B | 7,416 to 7,720 B |

**Built with no libc.** The plain nilo build links no libc, so the library was also compiled for `x86_64-linux-none` with `-DFREESTANDING -ffreestanding -fbuiltin -mevex512 -O2` (`-mevex512` because LLVM refuses the AVX-512 CRC path without it, which is why `build_libs.sh` passes it too). Linked with `utils.c`, the program's `memcpy` was libdeflate's: a 288-byte byte loop that `utils.c` defines weak under `FREESTANDING`, and that won the link over compiler_rt's for every caller in the program, Zig's own included. Linked without `utils.c`, and with its four other symbols (`libdeflate_aligned_malloc`, `libdeflate_aligned_free` and the two default allocator pointers, left null) written in Zig, `memcpy` was compiler_rt's and the output the same. Freestanding against the glibc build, best of seven, three interleaved runs on one pinned core: `arena-25` 10.02 to 10.04 µs against 9.99 to 10.04, `bench-400` 141.3 to 141.6 µs against 140.9 to 141.0, so no difference on the small body and under 0.5% on the larger.

**What it showed.**

- **On Zen 5 libdeflate 6 takes a quarter of `std.flate` 6's time on the arena's bodies**, 0.25 to 0.28 against 0.32 to 0.44 on the busy Xeon, and 0.36 on 1 MB against 0.49. The ratios did not carry between machines; they moved in libdeflate's favour. The margin is narrowest on the 1 MB body made of HttpArena's large dataset, 0.63, and why was not looked into.
- **The cost in memory is +32 KB a thread, not +373 KB.** libdeflate allocates 668 KB and writes 229 KB of it on small bodies, against 197 KB for today's slot; a body at the default `max_bytes` takes it to 377 KB against 299 KB, +78 KB. On sixteen threads that is half a megabyte steady and 1.2 MB at the ceiling. The 373 KB on the roadmap was the allocation, which no page fault ever reaches in full below the largest bodies.
- **That holds only off huge pages.** The first `rss` run had no `madvise` and reported 2 MB resident for every compressor, because this host runs transparent huge pages as `always`. `Pool.init` takes every slot in one `gpa.alloc`, so sixteen 668 KB compressors in one mapping would be backed by 2 MB pages and resident whole, 10.7 MB. A libdeflate pool wants `MADV_NOHUGEPAGE` on its mapping, or one mapping a compressor too small to hold a huge page. Read from `Pool.init` and the probe, not measured through nilo's pool.
- **It is the cheaper of the two on the stack**: 3.1 KB, under a page, against 7.4 KB for today's path. A fiber that compresses holds one page fewer at its high-water mark (ADR 062).
- **`.best` cannot become libdeflate 9.** On 1 MB libdeflate 9 is 17.5 ms against 12.8 for `std.flate` 9, and on 65 KB it is six times libdeflate 6 for 0.4% fewer bytes, so the time `max_bytes` was sized against would not hold.
- Both 1 MB bodies are just over the default `max_bytes` (1,048,576), so under the default they go out plain; they are here as the ceiling.

**The decision it moved.** The roadmap's question had three parts that wanted numbers, and this run answers them: the ratio on a quiet machine and a Zen 5, and the pages a small body touches. The fourth, whether HttpArena's `standard` mode counts a C library behind a flag, does not decide it: the time is what any JSON API pays. The entry moves from *Open questions* to *Next* as a build behind `-Dcompress=libdeflate`.

**Can it be pushed further.** Yes. Measure the resident pages through nilo's own `Pool` on a running server, with and without huge pages, rather than through the probe. Time levels 7 and 8 on the 1 MB bodies, which is what choosing `.best` needs. And take the ratio on aarch64, where libdeflate has its own NEON and PMULL paths and nothing here has been run.

## libdeflate behind `-Dlibdeflate`, measured through nilo

Taken for [ADR 248](../../docs/adr/248-gzip-is-libdeflate-when-a-build-asks-for-it.md), on the build that ships it rather than on the copies in `bench/compare-compress/`. AMD Ryzen 7 9700X, Linux 7.2.5 with transparent huge pages `always` (defrag `madvise`), Zig 0.16.0, libdeflate 1.26 from the release tarball, against nilo `bb0f859` as the before (`git archive HEAD`, same flags, same afternoon). Every build `-Dtarget=x86_64-linux-gnu`, so baseline x86-64 with the AVX-512 and PCLMUL paths taken at run time. Another user's benchmark held seven cores for part of the afternoon; the timings below were taken after it had finished, with load under 2, pinned to one core.

**`zig build bench-compress`, through `Pool.gzip`**, `std` and `-Dlibdeflate` interleaved, two runs each, which agree to 0.5%. The standard library's rows are ADR 211's table to the tenth of a microsecond.

| body | `.fastest` std / libdeflate | `.default` std / libdeflate | `.best` std / libdeflate |
|---|---|---|---|
| 25 items, 4,091 B | 873 B, 35.0 µs / 813 B, 5.3 µs | 748 B, 37.5 µs / 727 B, 9.4 µs | 744 B, 38.1 µs / 727 B, 9.7 µs |
| 40 items, 6,553 B | 1,252 B, 44.2 µs / 1,184 B, 6.8 µs | 1,041 B, 49.8 µs / 1,000 B, 13.5 µs | 1,036 B, 51.4 µs / 999 B, 16.3 µs |
| 50 items, 8,178 B | 1,483 B, 50.2 µs / 1,411 B, 7.9 µs | 1,225 B, 58.3 µs / 1,180 B, 16.5 µs | 1,218 B, 62.8 µs / 1,177 B, 21.5 µs |
| 991,794 B | 145,619 B, 4.15 ms / 133,248 B, 1.01 ms | 99,794 B, 6.48 ms / 75,665 B, 2.39 ms | |
| 19,986,580 B | 2,916,434 B, 82.9 ms / 2,662,816 B, 20.2 ms | 1,991,571 B, 129.8 ms / 1,501,171 B, 47.2 ms | |

**Which libdeflate level `.best` should be**, `bench/compare-compress` bodies, thread CPU time, median of seven (taken while the other benchmark was running, so the spread is the figure to trust: under 3% on every row):

| body | 6 | 7 | 8 | 9 | `std.flate` 9 |
|---|---|---|---|---|---|
| arena-50 (8,397 B) | 1,478 B, 18.2 µs | 1,466 B, 23.2 µs | 1,459 B, 30.4 µs | 1,459 B, 30.3 µs | 1,507 B, 68.9 µs |
| bench-400 (65,705 B) | 5,891 B, 147 µs | 5,882 B, 249 µs | 5,870 B, 640 µs | 5,867 B, 901 µs | 6,482 B, 706 µs |
| bench-6400 (1,057,992 B) | 80,635 B, 2.58 ms | 80,506 B, 4.18 ms | 80,302 B, 11.5 ms | 80,262 B, 17.7 ms | 89,442 B, 12.8 ms |
| arenalarge-all (1,070,913 B) | 140,345 B, 5.92 ms | 138,051 B, 9.40 ms | 135,611 B, 22.6 ms | 134,881 B, 31.1 ms | 145,790 B, 24.2 ms |

**Stack one `Pool.gzip` writes below its caller**, `zig build bench-compress-stack -Dlibdeflate`, every level, bodies of 3.9 KB, 58 KB and 888 KB:

| mode | `std.flate` | libdeflate |
|---|---|---|
| Debug | 13,216 to 14,112 B | 5,720 to 6,496 B |
| ReleaseSafe | 7,488 to 7,968 B | 2,272 to 2,624 B |
| ReleaseFast | 7,432 to 7,720 B | 2,272 to 2,624 B |

**Resident memory on a running server**, `bench/compress_rss.py` against `bench/compress_server.zig` on sixteen threads, an 8 KB JSON answer, 128 keep-alive connections of 200 requests each, first without `Accept-Encoding` and then with it. Three builds interleaved, two runs each: the standard library's, libdeflate's, and libdeflate's with the `madvise` taken out (a one-line edit for the measurement, reverted). Bytes:

| | idle | after the plain load | after the gzip load | AnonHugePages | pool mapping, idle / after gzip |
|---|---|---|---|---|---|
| `std.flate` | 12,337,152 | 14,446,592 to 14,462,976 | 16,666,624 to 16,781,312 | 2,097,152 | (in the heap) |
| libdeflate | 8,765,440 to 8,777,728 | 10,854,400 to 10,993,664 | 12,963,840 to 13,037,568 | 0 | 131,072 / 794,624 to 1,236,992 |
| libdeflate, no advice | 17,055,744 to 19,124,224 | 19,275,776 to 21,299,200 | 20,635,648 to 22,786,048 | 8,388,608 to 10,485,760 | |

**Binary size**, `zig build examples -Doptimize=ReleaseFast -Dstrip=true`:

| | `hello` | `rest` |
|---|---|---|
| before (`bb0f859`) | 1,011,504 | 1,248,568 |
| after, default build | 1,011,504 | 1,248,568 |
| after, `-Dlibdeflate` | 1,053,200 (+41,696) | 1,290,672 (+42,104) |

The same two builds unstripped: `memcpy` is 524 bytes in both, compiler_rt's, and the libdeflate build has no symbol under `flate.Compress` where the default one has nine.

**Other targets.** `bench-compress-server -Dlibdeflate` cross-builds and links for `aarch64-linux-gnu`, `aarch64-macos` and `x86_64-macos`. Built for `aarch64-linux-musl` and run under `qemu-aarch64-static`, `bench-compress -Dlibdeflate` gave every byte count of the x86 run above, and `zig build test` passed, with one test skipped: qemu's user mode answers `MADV_NOHUGEPAGE` with `EINVAL`, as a kernel built without transparent huge pages does, so the check that the pool's mapping carries `nh` now skips where the advice is refused rather than failing. No timing was taken under the emulator.

**What a dependent fetches.** `zig build fetch-check -Dnetwork` fails on this host before it counts, at the link of the dependent, which builds native and meets the GCC 16 `crt1.o` relocation; the tree before this change fails the same way. The fetch it exists to watch had already happened: `bench/dependent/zig-pkg/` held `zio` and nothing else after the run.

**What it showed.**

- **Through nilo the ratio is the one the copies measured**: 0.25, 0.27 and 0.28 of `std.flate`'s time at `.default` on the arena's bodies, 0.37 on a megabyte, 0.36 on twenty.
- **`.best` is level 7.** It is smaller than `std.flate` 9 on every body, faster than `std.flate` 6 on `bench-6400` and level with it on `arenalarge-all` (9.40 against 9.26 ms); 8 and 9 buy at most 2.3% for up to four times the time, and 9 on a megabyte is slower than the standard library's own `.best`.
- **A libdeflate server holds less, not more.** Idle, 8.8 MB against 12.3, because `Compress.init` writes 172 KB of every standard-library slot at startup and libdeflate writes 8 KB of a compressor until it is used; after the gzip load 13.0 MB against 16.7. The pool mapping held 0.8 to 1.2 MB, about three to five compressors' worth past the 8 KB each starts with: a borrow takes the lowest free slot and this client never kept more busy at once, so the rest were never touched. Sixteen in use would be 3.7 MB on the probe's 229 KB each.
- **The advice is worth 8 to 10 MB here.** Without it the pool mapping, 10.7 MB, was backed by four or five huge pages before a request arrived.
- **The standard library's build has huge pages too**: 2 MB of AnonHugePages, which its slots, one `gpa.alloc` of 4.7 MB, are the likely owner of; which mapping it is was not looked at. Most of each slot is written at startup anyway, so the advice would save less there; not changed here, and not measured.
- **The default build is unchanged to the byte**, and the libdeflate build is +41.7 KB and +42.1 KB, not the +64.5 KB of the probe, because the standard library's compressor leaves it.

**The decision it moved.** ADR 248 as written: the flag, level 7 for `.best`, one mapping under `MADV_NOHUGEPAGE`, and the size row in ADR 017.

**Can it be pushed further.** The resident figure with sixteen compressors busy at once wants a load generator that keeps sixteen requests compressing, which a Python client does not. aarch64 has been run, not timed. And the standard library's pool could take the same advice, worth a run of its own.

## What a route deadline's write clamp costs

**What was not run.** No throughput benchmark: the change is one indirect call and the stores it makes into the Engine's `Clocks` per request (`serve.handleConnection` re-arms the write limit before each request), and, for a route with a deadline, the same again where its answer is written. `test "the request path stays inside its allocation budget"` passes unchanged, nothing is held per connection (the `Deadlines` the connection already carries is read, not grown), and the test that found the defect (`a route deadline shortens the write to a client that reads nothing`, a 96 MB answer to a client that reads nothing, 200 ms against a 30,000 ms write limit) returns in about the deadline instead of failing at its six-second bound. A figure for the per-request re-arm belongs here the next time the paced benchmark is run on this path.

## What waiting for room buys an OpenTelemetry Collector

Taken for [ADR 220](../../docs/adr/220-grpc-is-served-over-h2c-behind-a-flag.md#what-the-budget-does-to-an-opentelemetry-collector), whose table of how many Collector batches a budget refuses was arithmetic from assumed batch sizes. This is the caller the roadmap entry asked for. Apple M1 Pro (8 cores), macOS 26, Zig 0.16.0, zio v0.18.0, nilo `1016cee` (**refused**) against the same tree with the change that made a call wait (**waiting**). The server is photon's OTLP logs spike on nilo (`photon/zig/spike/s1-ingest`, photon commit `7fcaabe`): a gRPC route decoding each `LogsService/Export` into columns and appending it to a WAL with a group-commit `F_FULLFSYNC`, on a real disk. In front of it the OpenTelemetry Collector contrib 0.161.0 at its defaults (batch of 8,192, `otlp` exporter with gzip, ten consumers on one connection, retry from 5 s), fed by `telemetrygen logs --rate 0` for 30 seconds; both in Docker under OrbStack with `--network host`, so loopback to the Mac. The harness is `collector/run.sh` there, and `collector/run-photon.sh` puts photon's own receiver (tonic, a 16 MiB message limit and no budget per connection) behind the same Collector as the control. The Collector's own metrics are read ten seconds after the load stops. One run each.

**Small batches** (8 workers, 58-byte logs, about 860 KB a batch inflated), refused:

| `max_body` | records accepted by the Collector | sent | refused `UNAVAILABLE` | lost |
|---|---|---|---|---|
| 1 MiB | 10,766,314 | 10,758,114 | 28 | 0 |
| 4 MiB | 10,742,808 | 10,742,808 | 1 | 0 |
| 16 MiB | 10,432,821 | 10,432,821 | 0 | 0 |

Waiting, at 1 MiB: 10,086,625 sent, 0 refused.

**Production-sized batches** (48 workers, 500-byte logs, about 4.4 MB a batch inflated):

| server | accepted | sent | refused | still queued | lost |
|---|---|---|---|---|---|
| refused, `max_body` 4 MiB | 25,205,633 | 7,033 | 60 `RESOURCE_EXHAUSTED` | 0 | 25,198,600 |
| refused, `max_body` 16 MiB | 16,338,650 | 13,653,000 | 40 `UNAVAILABLE` | 329 batches | 0 so far |
| refused, `max_body` 64 MiB | 20,771,725 | 20,771,725 | 6 `UNAVAILABLE` | 0 | 0 |
| **waiting, `max_body` 16 MiB** | **22,160,250** | **22,160,250** | **0** | **0** | **0** |
| tonic (photon), 16 MiB | 19,216,088 | 19,216,088 | 0 | 0 | 0 |

**What it moved.** A call that does not fit now waits instead of being refused (ADR 220). Refused, each `UNAVAILABLE` cost the exporter a backoff of 5 s and up while the server sat idle, so at 16 MiB the Collector's queue grew for as long as the load lasted (329 of its 1,000 batches after 30 seconds), and a longer run would have filled it and dropped. Raising `max_body` to 64 MiB only thinned the refusals. Waiting, the same load went through with nothing queued, more records than tonic took in the same 30 seconds; the WAL's `max_round_frames` of 2 says about two calls ran side by side, which is what the budget's arithmetic gives for 4.4 MB batches at 16 MiB. At 4 MiB the batches are over `max_body` itself, and `RESOURCE_EXHAUSTED` is permanent to the Collector, so the data is dropped there with or without this change: that is the caller's `max_body` to set.

**What it does not say.** Single runs on a laptop, with the Collector and the generator sharing it; the absolute records a second are about this machine. Peak memory of the server was not taken. Whether more than two calls side by side would help is not answered here, because the generator and the WAL's fsync are in the way before the budget is; that is the roadmap's budget-as-an-option entry, which waits for a caller held back by it.

## What writing a float costs, `std.json`'s spelling against serde_json's

Writing a float went from `std.json`'s `print("{}")` to `http/jsonfloat.zig`
(ADR 096): serde_json 1.0.150's layout over the same shortest digits, in a stack
buffer of 24 bytes an `f64`, and whole numbers below 2^53 written as the integer
they are.

**What was run.** `zig build bench-json-float -Dtarget=x86_64-linux-gnu
-Doptimize=ReleaseFast` under `taskset -c 5` (`bench/json_float.zig`), nilo
`1fe86dd` plus the earlier staged round plus this change, uncommitted. AMD Ryzen 7
9700X, Linux 7.2.5, Zig 0.16.0, **load average 8.6 while it ran** (other
sessions compiling), so each figure is the minimum of 41 rounds of 4,096 floats
with the old and new writers interleaved round by round, and the spread is
the minimum to the maximum. Old is `std.json.Stringify.value` after an
`isFinite` check, which is what the generated writer did; new is
`jsonfloat.write`. Both write into one rewound fixed buffer, so the number is the
formatter and the write and nothing else.

| values | old, ns a float | new, ns a float |
|---|---:|---:|
| short (`0.0`, `1.0`, `12.5`, `100.0`, `0.25`, ...) | 31.1 to 31.2 (31 to 37) | **14.0 to 14.1** (14 to 25) |
| 17 digits (`rnd.float`) | 24.3 to 25.3 (24 to 49) | **23.6 to 24.2** (24 to 32) |
| random bit patterns | 55.9 to 57.2 (56 to 79) | **35.4 to 36.5** (35 to 48) |

Three runs; the first, taken while the load was highest, read 46, 37 and 78
old against 22, 34 and 48 new and is not quoted. An earlier build of the new
writer without the whole-number path read 25 ns on the short set, so that path is
the 11 ns.

**Binary size**, `-Doptimize=ReleaseFast -Dstrip=true -Dcpu=x86_64_v3`, the old
tree built from the index: `hello` with one `f64` and one `f32` field,
**1,029,584 to 1,020,720 bytes (-8,864)**, because the decimal printer
`print("{}")` linked for a float is gone; `hello` and `rest` as they are (no
float anywhere) are byte-identical, 1,005,840 and 1,208,280. The request-path
allocation budget (`test "the request path stays inside its allocation budget"`)
passes in Debug and ReleaseSafe.

**What it moved.** Nothing was blocked on the speed, and the decision (ADR 096)
is for the spelling; the measurement is that it costs nothing: faster on every
set, smaller to link. **Whether it can be pushed further:** the 17-digit and
random sets are Ryu's (`std.fmt.float.binaryToDecimal`, about 20 ns), which is
what a faster formatter (Schubfach, `zmij`'s own) would have to beat; nobody
has needed it, and a float on a response is rarely the largest cost of the row.

## What telling a park from a hold costs a request

Taken for [ADR 013](../../docs/adr/013-handlers-must-not-block-the-thread.md): a wait through the server's `Io` is told from a handler holding its thread by asking the run loop, in `watchdog.reportIfTooLong`, whether a turn began since the stretch did. The claim is that this costs a request that does not wait long nothing, because the ask comes after the early exit every request takes.

**Method.** `bench/main.zig` (`GET /users/42`, about 1 KB of JSON, keep-alive) built `ReleaseFast` from two trees: the staged tree exported with `git checkout-index -a --prefix=` as the before, and that tree plus the change as the after. The server pinned to one core (`taskset -c 2`), a load generator of four processes by sixteen connections pinned to others, 2.56 million requests a run after a warm-up, eight runs of each **interleaved and alternating in order**. The figure is the server's own CPU time a request, from `/proc/<pid>/schedstat`, so it does not depend on how fast the generator is. `wrk`, `oha` and `valgrind` are not installed, so the generator is a short Python script and there are no instruction counts.

**Result.**

| | median | best | worst |
|---|---|---|---|
| before | 1,911 ns | 1,807 ns | 2,428 ns |
| after | 1,885 ns | 1,793 ns | 2,370 ns |

The difference is inside the noise: the machine was shared with other builds, and the runs fall into two groups, about 1.8 to 1.9 us and about 2.3 to 2.4 us, in both trees. Within a group the two are within 2 percent of each other and the after is the lower, which is not a claim that it is faster. What can be said is that it is not slower by anything this method sees.

**Why there is nothing to see.** The disassembly of `watchdog.reportIfTooLong` (`-Dstrip=false`) is the same through the load of the clock and the compare against the limit, where a request under it returns; the after has one more register move and a frame 16 bytes larger. The call to `engine.zio.loopTurnNanos` sits after that return. No hot-path function changed.

**Idle connections.** No field was added, `Watch` and `fail.InFlight` are untouched, and `bench/mem.py --port 8787 --path /health --steps 100,1000` reads the same on both, twice each: 5,816 bytes a connection at 100 and 5,247 at 1,000. The stripped benchmark binary is 272 bytes larger (1,015,464 to 1,015,736).

**Not measured.** A request that does wait long pays one thread-local read and one load, once, on the way to a report or a pass; a handler that waits 250 ms is not one whose nanoseconds are in question.

**Can it be pushed further.** There is nothing on the hot path to remove. The check itself is bounded by the limit: it runs at most once a stretch, and only for one past `block_warning_ms`.

## What is still missing

- **A quiet machine, and a second one to generate load from.** Both readings
  above are shaped by the client sharing a box with the server. This is the gap
  that was there before and it is narrower, not closed.
- **An honest tail at saturation**, which needs a fixed-rate generator that
  corrects for coordinated omission.
- **A NIC.** Everything here is loopback, so the throughput figures are a
  ceiling that real hardware will not reach.
- ~~**Anything to compare against.**~~ *Done* —
  [`comparison.md`](../../docs/comparison.md) runs eight other servers through this same
  harness on this same machine. nilo is first on throughput, first-equal on
  tail latency, third of nine on memory per connection, and last on release
  build time at 7.4s — though its edit loop is 0.4s, which is 0.2s behind Go and
  not the crisis a release-mode number alone makes it look. Both of the numbers
  in that sentence that moved were moved by being measured properly, not by
  being argued with.
- **The allocations-per-request invariant**, the second row of ADR 017's
  budget, which is held by a test rather than by this document.

## A short blocking call behind a long one, and what starting a worker for it costs

Asked by the photon port, whose WAL writer's `pwritev` and `fdatasync` (2 ms of work) waited 515 to 1,928 ms through `nilo.blocking` while one compaction pass held the pool's only worker. zio starts a worker for a queued call only when none is idle and `queued >= running * scale_threshold`, with a threshold of 2: one call running and one waiting is `1 < 2`, so nothing starts. The run decides whether `serve` should pass `scale_threshold = 0`, which starts a worker for any call that finds none idle, up to the same ceiling.

**The instrument** is a scratch program against the pinned zio (`0299e57`), ReleaseFast, four executors, on the Ryzen 7 9700X (16 logical CPUs, so the pool's ceiling is 32), at nilo `62e280e`. One binary takes the threshold as an argument, so both sides are the same build and the runs are interleaved, five pairs for the first row and three for the others. Three shapes, each a fresh runtime with a cold pool: one fiber holds a 500 ms call and a second makes a 2 ms call once the first has started; 512 fibers make 20 calls of 100 µs each; 16 fibers make 2,000 calls of 10 µs each. The peak is `running_threads` sampled inside every call, and CPU and RSS are the process's own `getrusage`.

| shape | threshold 2 (zio's default) | threshold 0 |
|---|---:|---:|
| the 2 ms call, behind the 500 ms one | 501.1 ms, all five | **2.1 ms**, all five |
| 512 fibers × 20 calls of 100 µs: wall, CPU, peak threads, max RSS | 64.8–65.3 ms, 1,012–1,026 ms, 32, 14.7 MB | 64.8–65.1 ms, 1,019–1,025 ms, 32, 14.6–14.7 MB |
| 16 fibers × 2,000 calls of 10 µs: wall, CPU, peak threads, max RSS | 48.7–49.0 ms, 367–371 ms, 7, 6.2 MB | **30.2–31.0 ms**, 391–392 ms, 16–17, 8.4–8.7 MB |

**The stall is the rule, not chance.** The short call waits exactly as long as the long one runs, every time, and starts at once with the threshold at 0. **A burst is unchanged**: 512 callers fill the pool to its ceiling either way, because the default rule also starts workers once the queue is twice what runs. **Steady concurrent calls are where it costs**: as many workers as callers instead of seven, 6% more CPU and 2.2 MB more RSS, for a wall time 38% shorter. Every one of those workers exits after zio's idle timeout of 60 s, as before.

The decision: `serve` runs the pool at `scale_threshold = 0` ([ADR 013](../../docs/adr/013-handlers-must-not-block-the-thread.md#how-the-pool-grows)). **Can it be pushed further?** Not by this knob: the ceiling is what bounds the threads now, and a caller that must never queue even at the ceiling is what `blockingReserved` is for.

## An answer handed to the framing

Taken for [ADR 253](../../docs/adr/253-an-answer-is-handed-to-the-framing-that-carried-its-request.md), the go or no-go on putting every write `Ctx` makes behind `Framing`, a tagged union whose HTTP/2 arm exists only under `-Dgrpc`. **The rule it was held to: the HTTP/1.1 path unchanged on the two hard axes, and inside the spread on the other two.**

**Machine and builds.** AMD Ryzen 7 9700X (8 cores, 16 threads), Linux 7.2.5, Zig 0.16.0, `-Dtarget=x86_64-linux-gnu`. Before is `6a914dd` exported with `git archive HEAD` into a scratch tree; after is the same commit with the seam. Both sides built the same afternoon, `ReleaseFast`, in the default build and with `-Dgrpc`, so the four binaries are one-arm before, one-arm after (the tag is known while compiling), and the same pair with the HTTP/2 arm present.

**Allocations per request: unchanged.** The four budget tests in `http/behaviour.zig` (the routed GET with CORS at exactly one allocation and no resize, traced, with metrics, with an allowance) pass unchanged, and so does every test that reads raw HTTP/1.1 back: 2,604 passed, 30 skipped, in Debug.

**Memory per idle connection: unchanged to the byte.** `bench/mem.py --path /health --steps 1000,5000,10000`, two rounds each, interleaved:

| build | 1,000 | 5,000 | 10,000 |
|---|---|---|---|
| default, before and after | 5,247 B | 5,197 B | 5,190 B |
| `-Dgrpc`, before and after | 5,313 B | 5,210 B | 5,197 B |

The marginal figure is the same on both sides of each pair in both rounds, as expected: `serveRequest` is `noinline`, so the `Ctx` that grew is unwound before the connection parks (ADR 062).

**Binary size: under a kilobyte either way.** `nilo-hello` (the benchmark server) stripped `ReleaseFast`: 1,017,512 to 1,017,112 bytes in the default build (400 smaller, the duplicate of `Ctx.send` in `serve.zig` gone), 1,140,296 to 1,141,128 with `-Dgrpc` (832 larger, the collecting arm).

**Throughput and p99, end to end: inside the spread.** A keep-alive load generator written for this (64 connections, one request in flight on each, 2 s warm-up and 8 s counted, plain Go over raw sockets because the machine has no wrk or oha), `GET /users/42` against `nilo-hello` over loopback, server on cores 0 to 3 and client on 4 to 7 and 12 to 15 so no physical core is shared. Five rounds, the four builds interleaved in each:

| build | requests a second, five rounds | median | p99 |
|---|---|---|---|
| default, before | 1.49, 1.46, 1.38, 1.62, 1.62 M | 1.49 M | 60 to 69 µs |
| default, after | 1.48, 1.45, 1.49, 1.45, 1.61 M | 1.48 M | 61 to 70 µs |
| `-Dgrpc`, before | 1.49, 1.32, 1.49, 1.49, 1.60 M | 1.49 M | 62 to 71 µs |
| `-Dgrpc`, after | 1.47, 1.33, 1.53, 1.48, 1.61 M | 1.48 M | 61 to 69 µs |

A margin of 0.6% against a spread of 17% is "unchanged".

**In process: the one number that moved, and why it is not the seam.** `zig build profile` (which had stopped compiling, see below), each binary pinned to core 6, eight interleaved rounds:

| build | the routed GET, end to end | a unary gRPC call |
|---|---|---|
| default, before | 394 to 406 ns | 1,099 to 1,114 ns |
| default, after | 418 to 426 ns | 1,111 to 1,140 ns |
| `-Dgrpc`, before | 397 to 433 ns | 1,101 to 1,153 ns |
| `-Dgrpc`, after | 400 to 423 ns | 1,131 to 1,143 ns |

The default build is about 20 ns slower in process, outside its spread, and the build with the second arm, the one that pays a compare, is not. The per-piece rows say where it went: "serialise the body", which is `json.zig` writing into a buffer and touches nothing the seam changed, went from 85 to 94 ns in the default build and to 91 in the other. A row the change cannot reach moving by half the difference is code placement, not the dispatch. End to end it is inside the spread above, about 0.7% of the 2.7 µs of CPU a request costs on four cores at 1.49 M a second. The gRPC call is about 2% slower in both builds, the same order, and it is not explained here: the call still goes through the HTTP/1.1 arm of the translation, so it pays what a routed GET pays and no more, and stage 2 of [the framing page](../../docs/design/framing.md#how-the-direction-is-built) removes that path along with the HTTP/1.1 text it parses back.

**Found on the way.** `zig build profile` did not compile at `6a914dd`: its module was never given `nilo_build`, which `compress.zig` has asked for since ADR 248, and nothing builds the profile on `zig build test`. It is now wired like every other instance of the App's files and compiled, not run, on every `test`.

**The decision it moved:** go. Every answer `Ctx` makes leaves through `Framing`, and stage 2 can build on it.

**Can it be pushed further:** (1) the 20 ns of placement in the default build, by finding which function's alignment moved (`perf` is not on this machine); it is not on any path the end-to-end run can see. (2) The gRPC call's text round trip, which stage 2 and 3 remove outright.

## Holding every answer until the chain unwinds

Taken for the open question on [the framing page](../../docs/design/framing.md#open-questions), whether a middleware may change an answer after `next()`. **The question: what it costs to hold every whole answer until the middleware chain has unwound, as Axum and Hono do, rather than only where a middleware asks for it.** Holding means `send` keeps the answer and the connection writes it after the chain, and a body the request does not own (anything handed to `c.send`) has to be copied into the arena first: the handler's frame is gone by then, and so is anything its `defer` released, a cache entry included.

**Machine and builds.** AMD Ryzen 7 9700X, Linux 7.2.5, Zig 0.16.0, `-Dtarget=x86_64-linux-gnu`, `ReleaseFast`. Base is `372b766` exported with `git archive`; the spike is the same tree with `Ctx.send` holding the answer, copying the body unless it came from the typed layer or `sendJson` (already in the arena), and `serveRequest` writing it after the chain. Both serve `nilo-hello` plus four routes answering `c.send(200, "application/octet-stream", blob[0..n])` from a global buffer, and an allocator under the App that counts what the arenas ask of it. Spike not kept.

**Method.** The Go load generator from the section above, 64 keep-alive connections, server on cores 0 to 3 and client on 4 to 7 and 12 to 15, 1 s warm-up and 5 s counted, five rounds with the order of the two builds swapped each round. Peak memory is the server's `VmHWM` at the end of each run. Backing allocations are a separate 2 s run with no warm-up, divided by the requests in it.

| route | base: req/s, p99 | spike: req/s, p99 | backing allocations a request, spike | peak RSS, base → spike |
|---|---|---|---|---|
| `/users/42` (typed JSON, not copied) | 1,641 k, 57.3 µs | 1,644 k, 57.5 µs | 0 | 6.9 → 6.9 MB |
| `/b/1k` | 1,759 k, 57.5 µs | 1,758 k, 57.8 µs | 0 | 6.6 → 6.8 MB |
| `/b/16k` | 1,029 k, 82.8 µs | 1,009 k, 85.6 µs | 0 | 6.6 → 7.9 MB |
| `/b/64k` | 388 k, 225 µs | 143 k, 620 µs | 1.0 | 6.6 → 9.8 MB |
| `/b/1m` | 67 k, 2.9 ms | 9 k, 8.1 ms | 1.0 | 6.6 → 56.8 MB |

Medians of five rounds; the base never asked its allocator for anything after warm-up on any route. **Holding itself costs nothing measurable** (`/users/42`, where nothing is copied, is level). **The copy is free while it fits in what the arena keeps and ruinous once it does not**: at 16 KiB it is 2% of throughput and 3% of p99, at the edge of the spread, and at 64 KiB every request grows its arena past `arena_keep` and gives it back, which cost 63% of throughput and nearly tripled p99. At 1 MiB it is 87% of throughput and 8.6 times the peak memory. Why the growth costs that much was not taken apart (no `perf` on this machine); the large blocks go to the page allocator, so a map and an unmap a request across four threads is the likely reading, not a measured one.

**The hypothesis it replaced was too kind.** Before the run the estimate for a 16 KiB to 1 MiB body was "a few microseconds" a request; it was 400 µs of p99 at 64 KiB. ADR 017 calls allocations a hard axis because one is "fine a million times and then it is a `mmap`"; here it is the `mmap` every time.

**The decision it moved:** holding every answer is refused. Holding where a middleware asks for it (`next.hold`, built in the next section) stays the recommendation, and it carries the same copy: a route behind such a middleware that sends a large body through `c.send` pays these numbers, which its documentation has to say. Idle memory per connection was not measured; nothing in the spike lives past `serveRequest`.

**Can it be pushed further:** the copy could be skipped for a body that provably outlives the chain, but nothing can prove that about a slice: a global, an arena and a cache entry released by the handler's `defer` look the same. Raising `arena_keep` moves the 64 KiB cost from throughput to memory a connection holds.

## Trailers, a held answer, and gRPC answered from what it collected

The cost of the framing's second stage ([ADR 254](../../docs/adr/254-an-answer-can-carry-trailers.md), [ADR 008](../../docs/adr/008-middleware-is-an-onion-of-ctx-functions.md), [ADR 220](../../docs/adr/220-grpc-is-served-over-h2c-behind-a-flag.md)): `c.setTrailer`, `next.hold(c)`, a header after the head refused, and a gRPC call answered from a `framing.Collected` instead of from HTTP/1.1 text it parsed back. **The question: what each axis pays, in a build with `-Dgrpc` and one without.**

**Machine and builds.** AMD Ryzen 7 9700X, Linux 7.2.5, Zig 0.16.0, `-Dtarget=x86_64-linux-gnu`, `ReleaseFast`. Before is `372b766` exported with `git archive`; after is the working tree on top of it, same afternoon, same flags, each built default and with `-Dgrpc`.

**Size**, stripped `nilo-hello`:

| build | before | after | |
|---|---|---|---|
| default | 1,017,104 | 1,020,800 | +3,696 |
| `-Dgrpc` | 1,141,120 | 1,094,112 | −47,008 |

The default build pays for the held answer, the trailer list on `Ctx` and the late-header check; the trailer writers are behind a pointer the first `setTrailer` sets (the ADR 246 move), which took 2,656 bytes out of the first cut. The `-Dgrpc` build loses the HTTP/1.1 response parser, the chunked decoder and the reframing copy that the call used to go through.

**The profile** (`zig build profile`, pinned to one core, four rounds interleaved, best of five inside each): a routed GET end to end 407 to 409 ns before and 403 to 405 ns after in the default build. **The first cut of the `-Dgrpc` build was a regression and is not what ships**: the same GET went from 392 to 395 ns to 464 to 469 ns, +18%, past ADR 017's 10%. Every row the profile breaks out was level, so it was in the remainder; a build with the HTTP/2 arm forced off came back to 402 to 403 ns, and with `Collected.whole` and `Collected.head` made `noinline` the GET is 411 to 412 ns (+4%, inside the 15 ns the two builds already differed by before). No `perf` on this machine, so the reading that inlining the collecting code into `Framing.whole` is what cost it is the experiment's, not a profile's. A unary gRPC call over h2c went from 1,083 to 1,118 ns to 902 to 910 ns, −17%: the parse it no longer does.

**End to end**, `/users/42` under the Go load generator, 64 keep-alive connections, server on cores 0 to 3 and client on 4 to 7 and 12 to 15, 2 s warm-up and 8 s counted, five rounds interleaved, medians:

| build | before: req/s, p99 | after: req/s, p99 |
|---|---|---|
| default | 1,633 k, 59.5 µs | 1,611 k, 59.5 µs |
| `-Dgrpc` | 1,610 k, 60.3 µs | 1,608 k, 60.3 µs |

The default build's −1.3% is small and is in every round, not inside the spread: after was below before in all five. It is the per-answer bookkeeping a hold needs (`_head_written`, the check `setHeader` makes against it, the trailer list's emptiness), and it is inside the budget.

**Idle memory** (`bench/mem.py`, 1,000, 5,000 and 10,000 idle connections, two rounds): 5,165, 5,181 and 5,182 bytes a connection before and after in the default build; 5,165, 5,181, 5,182 before and 5,161, 5,180, 5,182 after with `-Dgrpc`. Unchanged. Nothing new lives past `serveRequest`, and `endStream` stays `noinline` off the connection loop.

**Allocations.** The request path's budget test (`http/behaviour.zig`) passes unchanged: a route that does not hold or set a trailer pays nothing. A gRPC call's arena, counted with `budget.Counting` in a scratch build over the suite's three services:

| call | before: allocations, bytes | after: allocations, bytes |
|---|---|---|
| `/test.Echo/Say` | 4, 615 | 4, 495 |
| `/test.Meta/Who` | 9, 978 | 10, 697 |
| `/test.Orders/Get` | 8, 1,082 | 8, 824 |

The first cut was one more allocation on every call (5, 11 and 9): the body and the content type were copied separately. They are now one block, with the five bytes of the gRPC prefix in front of the body so the frame is written without a second copy. `Meta/Who` keeps one more, the copy of the headers it sets, which the old path paid as part of a larger text. Heap allocations from the second call on stay zero.

**The decision it moved:** the stage ships with `noinline` on the collecting methods, and the default build's 1.3% is the price of the hold. **Can it be pushed further:** the 1.3% could come back if the late-header check moved off `setHeader` into Debug only, which would turn a refusal into a silent loss in ReleaseFast; refused, for the reason ADR 008 gives.

## A call handed to the App as it was read

The cost of the framing's third stage ([ADR 253](../../docs/adr/253-an-answer-is-handed-to-the-framing-that-carried-its-request.md), [ADR 220](../../docs/adr/220-grpc-is-served-over-h2c-behind-a-flag.md)): a gRPC call handed to `serve.serveRequest` as a `framing.Call` (its method, path, a field block and its message) where it was written as HTTP/1.1 text and parsed back, its fields held to `parseHead`'s rules by `parseHead`'s own loop (`http1.parseFields`). **The question: does the read half of the translation pay for itself, and what does a second way in cost the HTTP/1.1 path.**

**Machine and builds.** AMD Ryzen 7 9700X, Linux 7.2.5, Zig 0.16.0, `-Dtarget=x86_64-linux-gnu`, `ReleaseFast`. Before is `3b76ed2` exported with `git archive`; after is the working tree on top of it, same afternoon, same flags, each built default and with `-Dgrpc`. The profile pinned to one core (`taskset -c 2`), four rounds interleaved, best of five inside each.

**The first cut was a regression and is not what ships.** It had two entries, `serveRequest` and a `serveCall`, over one `inline` core, so that each would keep a frame of its own. In the `-Dgrpc` build the routed GET went from 414 to 417 ns to 440 to 442 (+6%) and stripped `example-hello` grew 9,920 bytes, for a call that went from 912 to 914 ns to 900 to 911 (−1%). The default build was level on time and 1,232 bytes larger. The core compiled once per entry, and every function it calls had a second call site; the reading that the compiler stopped inlining them into the HTTP/1.1 path is the experiment's, not a profile's (no `perf` here), and the shape that fixed it is consistent with it: one `serveRequest` told how its request arrived by a `framing.Arrival`, `.wire` or `.call`, branching only to read and parse the head, with the `.call` arm `noreturn` without `-Dgrpc`.

**What ships**, the profile:

| row | before | after |
|---|---|---|
| routed GET, default build | 404 to 405 ns | 404 ns |
| routed GET, `-Dgrpc` build | 414 to 416 ns | 417 to 422 ns |
| unary gRPC call over h2c, end to end | 913 to 921 ns | 876 to 887 ns |
| of which HPACK decode | 246 to 251 ns | 244 to 247 ns |

The call is 4% faster. The `-Dgrpc` build's GET is about 1% slower, a margin the size of its spread: the compare on the arrival, which that build cannot fold. The App's row is not in the table because it measured different things on the two sides: before, the App handed HTTP/1.1 text and writing HTTP/1.1 bytes (270 to 273 ns), not counting what `asRequest` spent writing the text, which no row timed; after, the App handed the call and collecting its answer (213 to 216 ns). **Most of the 229 ns the roadmap called the translation was never the translation**: it was the App, the field parse and the route, which a call still runs and should. What went is the request line, the copy of the message into the text, finding the end of a head this side had just written, and the copy of that head into the arena.

**Size**, stripped `ReleaseFast`:

| binary | build | before | after | |
|---|---|---|---|---|
| `example-hello` | default | 1,013,248 | 1,013,248 | 0 |
| `example-hello` | `-Dgrpc` | 1,086,616 | 1,087,864 | +1,248 |
| `nilo-hello` (`bench/main.zig`) | `-Dgrpc` | 1,094,120 | 1,095,384 | +1,264 |

The default build is the same binary to the byte. The `-Dgrpc` build carries the second arm of the head: `applyTarget`, the field loop's instance with no request line, and the checks on a `Call`.

**Allocations.** The request path's budget test (`http/behaviour.zig`) passes unchanged, and heap allocations from a connection's second call on stay zero (`grpc.zig`'s budget test). A gRPC call's arena, counted with `budget.Counting` around it in a scratch build of each side, over the suite's three services with a forty-byte message:

| call | before: allocations, bytes | after: allocations, bytes |
|---|---|---|
| `/test.Echo/Say` | 4, 495 | 3, 269 |
| `/test.Meta/Who` | 10, 697 | 9, 471 |
| `/test.Orders/Get` | 8, 824 | 7, 598 |

The before column is the after column of the stage 2 entry above, to the byte. The allocation that went is the copy of the head into the arena, which a request with a body pays on HTTP/1.1 because the next read overwrites its buffer, and which a call's head, already in the call's arena, never needed; the bytes are that copy and `asRequest`'s 256 bytes of slack, the field block being sized exactly.

**Idle memory** (`bench/mem.py`, `nilo-hello` built with `-Dgrpc`, `/users/1`, server on cores 0 to 3, 1,000, 5,000 and 10,000 idle connections, two rounds interleaved): 9,253 to 9,257, 9,276 and 9,278 bytes a connection before; 9,253, 9,275 to 9,276 and 9,277 to 9,278 after. Unchanged. The default build is the same binary, so its figure is unchanged by construction.

**The decision it moved:** the stage ships with one entry and an `Arrival`, and ADR 253's rejected list carries the two-entry shape with these numbers. **Can it be pushed further:** (1) the route's `c.body()` copies the message once more into the arena it already lies in; handing the `Call`'s body to `Ctx` as already read would take a copy of every message off a call, at the cost of a second way for a body to be read. (2) HPACK decode is now the largest single row of a call, 28%, with a table advertised at 0, so every field is a Huffman-coded literal decoded afresh.

## Two Huffman symbols a lookup

The HPACK row of a unary gRPC call, 28% of it with the table advertised at 0 ([ADR 220](../../docs/adr/220-grpc-is-served-over-h2c-behind-a-flag.md)), taken apart and the larger half rebuilt. **The question: how much of the decode is Huffman, and how much of that a wider lookup buys back without a byte of idle memory.**

**Machine and builds.** AMD Ryzen 7 9700X, Linux 7.2.5, Zig 0.16.0, `-Dtarget=x86_64-linux-gnu`, `ReleaseFast`, pinned to one core (`taskset -c 2`). Before is `40e9f45` exported with `git archive`; after is the working tree on top of it, same afternoon, same flags.

**Huffman is most of the decode.** h2load's 89-byte block carries eight fields, five of them Huffman-coded strings, 68 bytes in all. Timed standalone against `hpack.zig` (best of 30 runs of 1,000): the whole block 209 to 210 ns, those five strings alone 163 to 164. The rest is the integers, the static table and the arena.

**Candidates**, each checked first against the decoder in the tree on about five million inputs (every byte, random strings whole, truncated and with a bit flipped, and random bytes), all agreeing on the bytes and on every refusal; then timed on h2load's five strings and on nine a Collector-like call carries (its path, authority, user agent, content and accepted codings, `grpc-timeout`, `traceparent`):

| decoder | table | h2load's five | a Collector-like call |
|---|---|---|---|
| one symbol a lookup, 9 bits (`40e9f45`) | 1 KB | 162 to 165 ns | 352 ns |
| the same, its input a word at a time at the top of a register | 1 KB | 133 to 134 ns | 300 to 305 ns |
| two symbols a lookup, 10 bits | 4 KB | 133 to 135 ns | 290 to 293 ns |
| two symbols a lookup, 11 bits | 8 KB | 94 to 97 ns | 209 to 212 ns |
| two symbols a lookup, 12 bits | 16 KB | 79 to 84 ns | 184 to 186 ns |
| two symbols a lookup, 13 bits | 32 KB | 77 ns | 173 ns |

Twelve bits is where a pair of the 5- and 6-bit codes that lowercase letters, digits and `/.-:` have fits, which is most of what a header is made of; thirteen buys 3 to 8% more for twice the table.

**What ships**, `zig build profile -Dgrpc`, four rounds interleaved:

| row | before | after |
|---|---|---|
| routed GET, `-Dgrpc` build | 419 to 430 ns | 419 to 424 ns |
| unary gRPC call over h2c, end to end | 865 to 879 ns | 767 to 773 ns |
| of which HPACK decode | 244 to 245 ns | 123 to 125 ns |
| the App, handed the call | 196 to 200 ns | 197 to 199 ns |
| the rest: frames, the call, answer | 422 to 437 ns | 445 to 451 ns |

The call is 11 to 12% faster, and the HPACK row is half what it was. **The call saved about 100 ns where the row saved 120**, and the difference landed in the rest, which is what is left of the call once the two timed rows are taken off it. It is not the table's size: an 11-bit build, half the table, run in the same three rounds (calls of 787 to 795 ns, its HPACK row 137 to 140) moved the rest by the same 30 ns. What it is was not found; the reading that the rows timed in a loop of their own are warmer than they are inside a call is consistent with it and not shown. The end-to-end row is the one to quote.

**Size**, stripped `ReleaseFast`: `example-hello` built with `-Dgrpc` 1,087,864 to 1,103,160 bytes, +15,296, the table less the one it replaces; the default build 1,013,248 both sides, since nothing without gRPC reaches `hpack.zig`. **Allocations and idle memory** are unchanged by construction: the decoder writes into the capacity it reserved before, and no connection holds anything new.

**The decision it moved:** the decoder takes two symbols a lookup at 12 bits, and the todo entry that asked for it narrows to the table it was weighed against. **Can it be pushed further:** HPACK is now 16% of a call. What is left of it is mostly the five strings decoded afresh every call, and only a table of the client's own keeps them, which is idle memory: the Collector's measured in ADR 220 fills one. Three symbols a lookup would need a 16-bit table, 256 KB, past where a lookup stays in the first cache.

## A body read as what its type says

The first piece of the framing's fourth stage ([ADR 256](../../docs/adr/256-a-body-is-read-as-what-its-type-says.md)): a struct with a `wire` table read as JSON or as protobuf by the request's `Content-Type` and answered in the same, and `nilo_decode` for a type that reads its own bytes. **The questions: what a message costs in each spelling, what everything that is not a message pays for it, and where the `Content-Type` is read.**

**Machine and builds.** AMD Ryzen 7 9700X, Linux 7.2.5, Zig 0.16.0, `-Dtarget=x86_64-linux-gnu`, `ReleaseFast`, pinned to one core (`taskset -c 2`). Before is `40e9f45` exported with `git archive`, with this entry's `http/profile.zig` copied in so both binaries time the same three requests; after is the working tree on top of it, which also carries [two Huffman symbols a lookup](#two-huffman-symbols-a-lookup), a change to the gRPC build only.

**The rows** (`zig build profile`, "one POST whose body is two numbers"): a plain struct read from JSON and answered as JSON, the control; the same two numbers into a message read from JSON; and from protobuf. At `40e9f45` the message is an ordinary struct and the protobuf request is a 400, so only its first two rows mean anything.

**Where the `Content-Type` is read was the design question, and three places were built and measured.**

| where | message as JSON | protobuf | what every program pays |
|---|---|---|---|
| `Ctx.header`, read twice (body, then answer) | 454 to 466 ns | 371 to 384 ns | nothing |
| a byte on the `Ctx`, read once | 421 to 428 ns | 297 to 310 ns | 81 bytes of `serve.serveRequest` |
| classed by the head parser into a byte `http1.Request` packs | 381 to 386 ns | 274 to 276 ns | 1.6 KB of request parsing, after it was cut from 5.2 KB |
| the handler's wrapper, read once by a scan of its own (**ships**) | 410 to 418 ns | 282 to 284 ns | nothing |

The control was 359 to 377 ns across these runs. A read of the head through `Ctx.header` is 27 ns in a loop of its own and about 40 inside a request, and classing the value 13 more until `application/json` was given a path of its own. The head parser's place was the fastest, and it put code on every program's request path, which [ADR 017](../../docs/adr/017-the-trade-budget-has-four-axes.md) does not allow for a feature at any size: the classing function alone was 4 KB written with `eqlIgnoreCase` and 969 bytes rewritten as a switch on the length. The `Ctx` byte sat in padding, `@sizeOf(Ctx)` 992 either way, and still cost `serveRequest` 81 bytes to initialise. What ships keeps the spelling on the stack of a handler's own wrapper, a byte where a message is in the signature and a zero-sized `void` everywhere else.

**What ships**, four rounds interleaved:

| row | before | after |
|---|---|---|
| routed GET | 402 to 403 ns | 410 to 414 ns |
| a plain struct, as JSON (the control) | 360 to 361 ns | 341 to 342 ns |
| a message, as JSON | 358 to 360 ns | 410 to 418 ns |
| a message, as protobuf | (a 400) | 282 to 284 ns |

**A message read as JSON is 52 to 58 ns slower than the same route was**, the read of its `Content-Type`, 15%; read as protobuf it is 21% faster than the same message as JSON was. The GET and the control moved 2 to 3% and −5% in opposite directions with `serve.serveRequest`, the router and the JSON reader the same bytes on both sides (`nm`), so those two are the layout of the profile binary, and a band of 5% is what a margin here has to clear.

**Size**, stripped `ReleaseFast`: `example-hello` 1,013,248 to 1,013,312 bytes in the default build and 1,103,160 to 1,103,224 with `-Dgrpc`, +64 each, and by symbol it is `openapi.write` (+175), the route table it is built from (−112 in `main`) and its rows: the document's content types became a list decided while compiling, where the first cut branched on a body kind at runtime and cost 496. Nothing on the request path changed size.

**Allocations** (`behaviour.zig`, held by a test): the same message is four allocations a request as JSON and three as protobuf, the head copied for a request with a body, the body and the answer; a message with no repeated field decodes in place. **Idle memory** (`bench/mem.py`, `nilo-hello`, `/users/1`, server on cores 0 to 3, two rounds): 9,351, 9,295 and 9,287 bytes a connection at 1,000, 5,000 and 10,000 before, and 9,347 to 9,351, 9,294 to 9,295 and 9,287 after.

**The decision it moved:** the codec follows the request's `Content-Type`, read only by a handler with a message in its signature, and the parser's faster place is in ADR 256's rejected list with its 1.6 KB. **Can it be pushed further:** the 52 to 58 ns are a read of the head that the parser has already done once; a cheaper `Ctx.header` takes it down for every caller of it at once, forms included, and is in [`todo.md`](../../docs/todo.md).

## A header is looked for by the lines that can hold it

The todo entry that [a body read as what its type says](#a-body-read-as-what-its-type-says) left: `Ctx.header` split the head into lines and trimmed each until a name matched, 27 ns for the third line of a short head in a loop of its own and about 40 inside a request, and every `c.header`, every form's `Content-Type` and a message read as JSON paid it. **The questions: how cheap can one lookup be with no allocation and no byte on the request path, and how much of a message row's gap to a plain struct was the lookup.**

**Machine and builds.** AMD Ryzen 7 9700X, Linux 7.2.5, Zig 0.16.0, `-Dtarget=x86_64-linux-gnu`, `ReleaseFast`, `taskset -c 2` for the in-process rows and `0-3,8-11` for the loops, under the shared bench lock. Before is `04a2e10` with this entry's `http/profile.zig` (its new rows included) so both binaries time the same requests; after is `04a2e10` with this change applied, the commit that adds this entry. The two `nilo-profile` binaries were built one after the other and run in turn, four rounds each.

**What was built.** `http1.findHeader(head, name)`: sixteen bytes at a time (one `pcmpeqb` and one `pmovmskb` a mask on the baseline target, where 32 lanes are two of each joined), the mask of `\n` and the mask of the name's first letter in either case, read one byte on, `and`ed, so only a line that starts with that letter is looked at; of those, one whose byte `name.len` in is not `:` is thrown out without a compare; the survivor is compared byte by byte, stopping at the first difference, and its value is read out of line by `valueAfter`. `Ctx.header` and `message.fieldIn` (so `contentTypeIn` and Connect's version header) call it. `message.fieldIn`'s own byte-at-a-time scan, `Ctx.header`'s iterator walk and its `eqlIgnoreCase` are gone from those two.

**A lookup in a loop of its own** (`zig build profile`, "one header read out of a head", best of five, `unseen` heads):

| name asked | head | iterator (was `Ctx.header`) | `findHeader` |
|---|---|---|---|
| `Content-Type`, 3rd of 4 lines | 90 bytes | 21 ns | 6 ns |
| `Host`, 1st of 4 | 90 bytes | 8 ns | 4 ns |
| `Cookie`, last of a browser's 15 | 682 bytes | 120 to 122 ns | 34 ns |
| `Accept-Language`, 14th of 15 | 682 bytes | 116 to 118 ns | 36 ns |
| `X-Request-Id`, not there | 682 bytes | 116 to 120 ns | 32 ns |

`Content-Type` to a codec (`codecOf` on the value, as a message route does) is 15 ns with the scan ADR 256 shipped and 9 with this.

**Variants that lost**, each measured the same way on the third line: `std.ascii.eqlIgnoreCase` for the compare, 15 ns against 9 for a byte loop that stops at the first difference; 32 lanes, 9 to 12 against 6 to 8 for 16; the value's end found by `indexOfScalarPos` (36 ns on `Cookie`) and by a byte loop (43 to 48), against a sixteen-byte mask loop (34); the value inlined into the loop, which took an absent name from 32 ns to 66 because the loop lost its registers to a path it takes once, and `noinline` on `valueAfter` gave 32 back. Reading the end of the line from the block's own `\n` mask, to save the second search, measured the same as the search.

**In a request** (`zig build profile`, "one POST whose body is two numbers", `taskset -c 2`, four rounds interleaved, before then after):

| row | before | after |
|---|---|---|
| a plain struct, as JSON (the control) | 366 to 371 ns | 364 to 367 ns |
| a message, as JSON | 441 to 445 ns | 408 to 413 ns |
| a form, urlencoded | 379 to 387 ns | 359 to 362 ns |
| a message, as protobuf | 284 to 287 ns | 263 to 268 ns |

**A message read as JSON is 72 to 77 ns above the control before and 41 to 47 after**, and a form went from 10 to 20 ns above it to 5 below. A message as protobuf is 21 ns faster. **The lookup is not all of the message's gap.** With `contentTypeIn` returning a string the compiler cannot see through and doing no scan, the message row is 26 to 30 ns above the control, so about 14 of the remaining 41 to 47 is the lookup and about 30 is the cost of choosing a spelling (`codecOf`, the `Codec` in the wrapper, `readBody` and `protoAnswer`'s branches). With the string a constant the compiler can see (the first thing tried) the gap was 9 ns, which is the compiler folding the choice away and not a figure for anything that ships.

**Size**, stripped `ReleaseFast`, before then after: `example-hello` 1,013,328 to 1,013,808 (+480), `example-forms` 1,122,232 to 1,122,840 (+608), `example-rest` 1,221,240 to 1,221,704 (+464), `example-orders` 1,392,168 to 1,392,648 (+480), and with `-Dhttp2` `example-hello` 1,147,680 to 1,148,144 (+464). By symbol in `example-hello` it is `ctx.Ctx.header` 618 to 783 and the new `http1.valueAfter` 232. A program with a message route also loses the byte scan `message.fieldIn` had (the profile binary, which has one, is 7,952 bytes smaller). **Allocations:** none; `behaviour.zig`'s budget test holds. **Idle memory** (`bench/mem.py`, `example-hello`, `/`, server on cores 0 to 3, two rounds each): 5,247, 5,197 and 5,190 bytes a connection at 1,000, 5,000 and 10,000 before and the same three after.

**Held by:** the h1 fuzzer in ReleaseSafe on a new seed (`zig build fuzz -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-gnu -- --iterations 1000000 --seed 0xb7e4a91d33c5`, every property held), and a test in `http1.zig` that builds 4,000 heads the parser accepts, with and without a request line and with CRLF or bare LF, and asks `findHeader` and the iterator for sixteen names, comparing the answer and the address.

**The decision it moved:** `Ctx.header` stays a read of the head with no list built, and is that lookup; the todo entry became the 30 ns that is not the read. **Can it be pushed further:** a head of a browser's size is 34 ns, about 0.8 ns a sixteen-byte load, and a build for a target with AVX2 (`-Dcpu`) was not tried, where a load would be 32 bytes; the lookup for a short head is 6 ns and what is left in it was not taken apart. The next gain on the message row is in the spelling's own cost, in [`todo.md`](../../docs/todo.md).

## A message is told from JSON by sixteen bytes

The todo entry that [a header is looked for by the lines that can hold it](#a-header-is-looked-for-by-the-lines-that-can-hold-it) left: a message read as JSON was 39 to 46 ns above a plain struct of the same shape, 14 of which that entry put on the lookup and about 30 on "choosing a spelling". **The questions: which of the pieces the 30 ns is, and what makes it cheaper without adding code to a program that has no message route.**

**Machine and builds.** AMD Ryzen 7 9700X, Linux 7.2.5, Zig 0.16.0, `-Dtarget=x86_64-linux-gnu`, `ReleaseFast`, every binary copied to one fixed path and run as `env -i PATH=/usr/bin taskset -c 2 ./nilo-profile` under the shared bench lock, three to four rounds interleaved. Before is `514e8c1` with this entry's `http/profile.zig`; each variant below is `514e8c1` with one edit to `typed.zig`'s `codecOf`. The gap is read inside one binary (message row minus control row), because the control row moves 355 to 370 ns from build to build with the layout.

**Taking the choice out one piece at a time** (the message row, "one POST whose body is two numbers"):

| variant | message minus control |
|---|---|
| shipped (`findHeader`, `mediaType`, `codecOf`, the branches) | 39 to 46 ns |
| `codecOf` returns a constant `.json`, nothing looked up | 8 ns |
| the header is found and the result thrown away | 36 to 41 ns |
| the header is found twice | about 75 ns |
| no lookup, `codecOf` on a slice of the head at a fixed place | 17 to 18 ns |

**So the branches in `readBody` and `protoAnswer`, and the `Codec` in the wrapper, cost 8 ns, and the other 30 to 38 is the lookup and the classification, each of which costs three to four times what its loop row says** (`findHeader` 7 ns in a loop, 35 to 41 a call in a request; `codecOf` 4 ns, 17). A request is one pass through a few thousand other branches, where a loop repeats one head and every branch is predicted.

**What was built.** `message.codecIn(head)`: `http1.findHeaderColon` (`findHeader` is it followed by `valueAfter`, the same code), then the first bytes of the value, spaces skipped, compared against `application/json` in one sixteen-byte vector compare with the letters folded; a match is `.json` whatever follows, since a media type that starts with those sixteen bytes can be none of protobuf's names, and any other value takes `codecOf(valueAfter(…))` as before. A test holds `codecIn` to `codecOf(contentTypeIn(…))` for nineteen values, three head shapes each.

| row, best of five, three rounds | before | after |
|---|---|---|
| a plain struct, as JSON (the control) | 375 to 382 ns | 366 to 373 ns |
| a message, as JSON | 414 to 421 ns | 383 to 395 ns |
| gap | 39 ns | 10 to 27 ns |

**Size**, stripped `ReleaseFast`, before then after: `example-hello` 1,013,872 to 1,013,872 (no change), `example-rest` 1,221,752 to 1,221,832 (+80), `example-orders` 1,392,696 to 1,392,872 (+176); the default build is byte-identical, and the message code stays absent from it (`codecIn` is reached only from a handler with a message in its signature). **Allocations:** none; `behaviour.zig`'s budget test holds. **Idle memory:** no connection or `Ctx` field changed, and `example-hello` is the same size to the byte; `bench/mem.py` was not run.

**Held by:** `zig build test` and `test-all` (exit 0), the h1 fuzzer in ReleaseSafe on a new seed (`zig build fuzz -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-gnu -- --iterations 1000000 --seed 0x2c9d17e4a6b3`, every property held).

**The decision it moved:** the message row's gap to the control is 10 to 27 ns, down from 39. **Can it be pushed further:** 8 ns is the branches, so the floor of this design is about 10; the rest is the lookup of a line in a head, which a head parser that noted the `Content-Type` as it went past would make free, at the 1.6 KB in every program ADR 256 turned down. A variant that gates that on a message route being registered was not tried, and would need `serve.zig`.

## A tagged union is read once when its tag comes first

`jsonmark.zig`'s header said an internally tagged union costs nothing per request, true of the write half and never measured for the read. `Reader.fromSpan` passed over each tagged object four times: `skipValue` to find its end, a scan for the discriminator, the variant's fields by `json.parseLeaky`, and a scan for unknown keys, two of them with a `std.json.Scanner` of their own. **The question: what a tagged value costs against the same fields untagged, and how much of that is passes.**

**Machine and builds.** As above. A new `zig build profile` section, "one array of 1000 objects read as a body", reads an array of a thousand objects of four fields (`id`, `x`, `y`, `label`) with `json.parseLeaky`, no request around it: untagged, tagged with the tag first, tagged with the tag last, and three variants (a click, a key with two fields, one with none) with the tag first. Before is `514e8c1` with that profile; after has the change. Four rounds interleaved.

| row | before | after |
|---|---|---|
| untagged, the control | 123 to 126 ns an object | 119 to 125 |
| tagged, the tag first | 493 to 523 | 145 to 152 |
| tagged, the tag last | 496 to 520 | 278 to 290 |
| tagged, three variants, the tag first | 314 to 331 | 94 to 97 |

**A tagged object was 4 times its untagged self and is 1.2 times it with the tag first**, a 3.3-fold cut, and 1.8-fold with the tag last. The mixed row, which includes variants with fewer fields, is 3.4-fold.

**What was built.** When every variant that carries fields is a plain struct with no field of the tag's name (decided while compiling, `Reader.singlePass`), a byte look at the start of the object asks whether it opens with `"tag":"`. If it does, `readOpening` takes the `{`, the key and the value off the scanner and hands the rest of the object to `json.readFields` with the variant the value names: one pass, the struct reader `innerRead` already used, taught that a key by the discriminator's name is the discriminator twice (`DuplicateField`). If it does not, `readAnywhere` finds the discriminator in one pass that also takes the object off the source (a second one is `DuplicateField`, none is `MissingField`) and reads the variant's fields from a second scanner over the same bytes, the discriminator skipped. A type whose variant is anything else (its own `jsonParse`, a tuple) keeps `fromSpan`. **Unknown keys are refused at the variant's top and ignored below it, as before**, and the thing the guess is wrong about costs nothing because the scanner reads the bytes properly after it.

**Commands:** `zig build profile -Dtarget=x86_64-linux-gnu`, the "one array of 1000 objects" rows, each binary copied to a fixed path and run as `env -i PATH=/usr/bin taskset -c 2 ./nilo-profile` under the bench lock, before and after interleaved.

**Refusals:** the same bodies are refused and a body with one mistake gets the same message. A body with two mistakes may now name the other first (the first in field order, where the old reader named the first of its passes): in 127,000 mutated bodies the error named differed, `MissingField` for `UnknownField` and, where `DuplicateField` or `SyntaxError` changed, the 400 sentence with it.

**Held by:** a test that sends twelve mistakes each with the tag first and with the tag last (unknown key, void variant with a key, a variant that does not exist, a field missing, the tag missing, the tag twice in both orders, a field twice, the tag not a string, a field the wrong kind, `"1_0"` in a count, a body that is not an object), a union in a list in a struct, and a nested unknown key; `zig build test` and `test-all` exit 0.

**Size:** `example-rest` +80 and `example-orders` +176 together with the change above (no tagged union in `hello`); allocations none beyond the scanner's, which allocates only for a string with an escape.

**The decision it moved:** the header's claim is corrected with the number, and the todo entry is closed. **Can it be pushed further:** the tag-first row is 25 ns above its untagged control, which is the scanner `std.json` tokenizes with. A reader that leaves it was prototyped in a scratch copy (2.2 to 2.8 times faster on these rows, +3.4 KB) and is not on the record until it has a harness in the repository and the user's approval.

## A Connect client told its failure

The second piece of the framing's fourth stage ([ADR 257](../../docs/adr/257-a-connect-client-is-told-its-failure-in-connect-words.md)): a request carrying `Connect-Protocol-Version: 1` that fails is answered in Connect's error shape, in a program with a message route. **The question: what every program pays for a choice on the failure path that only some programs use, and where to put it so that is least.**

**Machine and builds.** AMD Ryzen 7 9700X, Linux 7.2.5, Zig 0.16.0, `-Dtarget=x86_64-linux-gnu`, `ReleaseFast`, stripped for sizes and unstripped for `nm -S`. Before is the working tree of [a body read as what its type says](#a-body-read-as-what-its-type-says), copied aside; after is the same tree with this change.

**Three placements of the choice were built**, measured by `serve.sendFailure` in `example-hello`, which has no message route:

| what `sendFailure` does | `sendFailure` |
|---|---|
| a `Connect` writer that returns whether it wrote, its error handled in place | +157 bytes |
| a `Pick` from the head, and the error handed to the shape as a fourth argument of `Write` | +182 bytes |
| a `Pick` from the head and the error, returning a writer already knowing the code the error names (**ships**) | +84 bytes |

Of the 84, 20 are the App handed to `sendFailure` in place of its shape, which `serveRequest` pays 6 bytes less for, and the rest is the null check, the call and the registers it moves. **The error kept live across the shape's call was most of the second row**: the instructions added were a dozen, and the rest was every register below it chosen again.

**Size**, stripped:

| program | build | before | after | |
|---|---|---|---|---|
| `example-hello` | default | 1,013,312 | 1,013,408 | +96 |
| `example-hello` | `-Dgrpc` | 1,103,224 | 1,103,352 | +128 |
| `example-rest` | default | 1,221,224 | 1,221,320 | +96 |
| `example-orders` | default | 1,392,136 | 1,392,248 | +112 |

A program with a message route pays Connect's own code on top, by symbol in `nilo-profile`: `connect.pick` 825 bytes (the header scan inlined), `writeBody` 588, the writer whose code comes from the status 220 and the two whose code the error named 12 and 15. The two specialised writers were 556 bytes each before they shared `writeBody`.

**Not measured:** time. Nothing on a request that succeeds changed (`serveRequest` is 6 bytes smaller, by `nm`), and a failure in a program with a message route reads the head once more for the version header, the scan the message row of the entry above times inside its 52 to 58 ns.

**The decision it moved:** the choice is a pointer the first message route sets, handed the head and the error, and in ADR 017's running total at +96 bytes. **Can it be pushed further:** to zero only by knowing while compiling that an App has no message route, which an App registered at run time does not.


## What splitting the HTTP/2 connection from the gRPC envelope costs

**Question.** `grpc.zig` became `h2conn.zig`, the connection, and `grpc.zig`, the envelope, and the flag `-Dgrpc` became `-Dhttp2` ([ADR 259](../../docs/adr/259-http2-is-a-framing-of-every-request.md), stage 5.1 of [framing](../../docs/design/framing.md)). No behaviour changed, so the plan held it to the `-Dgrpc` build's size within the names.

**Machine and builds.** AMD Ryzen 7 9700X, Linux 7.2.5, Zig 0.16.0, `-Dtarget=x86_64-linux-gnu`, `ReleaseFast`, stripped for sizes and unstripped for `nm -S`. Before is `8c64019` from `git archive` built with `-Dgrpc=true`; after is the working tree built with `-Dhttp2=true`, the same afternoon.

**Size**, stripped:

| program | build | before | after | |
|---|---|---|---|---|
| `example-hello` | default | 1,013,408 | 1,013,408 | 0 (`cmp` equal) |
| `example-rest` | default | 1,221,320 | 1,221,320 | 0 (`cmp` equal) |
| `example-hello` | flag | 1,103,352 | 1,103,960 | +608 |
| `example-rest` | flag | 1,292,744 | 1,293,336 | +592 |

**It missed the plan's bar, by code and not names.** By `nm -S` the envelope's rules handed back as values cost what the connection used to do in place: `runCall` +172 (the answer returned as a `grpc.Reply` and copied onto the stream), `grpc.envelope` 232 against 107 that left `Conn.dispatch`, and `grpc.untilNs` 360 where `timeoutNanos` was 346. A one-line `refuse` helper was a function of 161 bytes of its own until it was made `inline`, which took the first measurement of +864 and +848 to the figures above.

**The decision it moved:** none; the split ships at this cost, because it lives only in a build that asked for HTTP/2 and stage 5.2 rewrites `Conn.dispatch` for every request. **Can it be pushed further:** yes, by writing the reply straight onto the stream; stage 5.2's own size measurement is taken against `8c64019` so the two are read together.

## What one port for HTTP/1.1 and HTTP/2 costs

**Question.** Stage 5.2 of [framing](../../docs/design/framing.md) makes every plain listener of a `-Dhttp2` build read the client's first bytes and serve HTTP/2 on the preface and HTTP/1.1 on anything else ([ADR 259](../../docs/adr/259-http2-is-a-framing-of-every-request.md)). The bar the ADR set: an HTTP/1.1 connection in that build holds the idle figure it held before, the routed `GET` stays inside its spread, and a build without the flag is byte-identical. The ADR named two ways to build it, a tail call from the choosing into the loop chosen, and, where the ABI refuses that, the choice inside `serve.handleConnection`'s first wait with a `noinline` hand-on, and said `bench/mem.py` decides.

**Machine and builds.** AMD Ryzen 7 9700X, Linux 7.2.5, Zig 0.16.0, `-Dtarget=x86_64-linux-gnu`, `ReleaseFast`, stripped. Before is `45459d1` and, for the size, `8c64019` (`-Dgrpc=true`), each from `git archive`; after is the working tree on `45459d1`. Everything the same afternoon, interleaved. Memory: `bench/mem.py --port 8787 --path /health` against `nilo-hello` (`bench/main.zig`), `ulimit -n 65536`. Throughput: wrk 4.2.0 `-t2 -c64`, 5 s of warm-up then 15 s, `/users/42`, the server on `taskset -c 0-3` and wrk on `-c 4,5` (four physical cores and two, SMT siblings idle), five rounds alternating the two builds.

**Size**, stripped:

| program | build | `45459d1` | `8c64019` | after | against `45459d1` | against `8c64019` |
|---|---|---|---|---|---|---|
| `example-hello` | default | 1,013,408 | 1,013,408 | 1,013,408 | 0 (`cmp` equal) | 0 |
| `example-rest` | default | 1,221,320 | 1,221,320 | 1,221,320 | 0 (`cmp` equal) | 0 |
| `nilo-hello` | default | 1,020,968 | | 1,020,968 | 0 (`cmp` equal) | |
| `example-hello` | flag | 1,103,960 | 1,103,352 | 1,103,496 | -464 | +144 |
| `example-rest` | flag | 1,293,336 | 1,292,744 | 1,292,856 | -480 | +112 |

The flag build is smaller than stage 5.1's because a plain listener no longer has a fiber function of its own for the HTTP/2 loop (`Entry(grpc_handler)` is gone); it is 112 to 144 bytes over the `-Dgrpc` build it replaces, from the sniff and the hand-on.

**Idle HTTP/1.1 connection**, bytes a connection after one request, `mem.py` at 1,000 and 10,000, two interleaved rounds (a range is the two rounds):

| build | 1,000 | 10,000 |
|---|---|---|
| default, `45459d1` | 5,251 to 5,255 | 5,191 |
| default, after | 5,251 to 5,255 | 5,191 |
| `-Dhttp2`, `45459d1` | 5,317 to 5,321 | 5,197 to 5,198 |
| `-Dhttp2`, after | 5,321 | 5,197 to 5,199 |

A connection that never says a word (10,000 sockets opened and left, the RSS read after the first wait has given its pages back): default 5,184 to 5,206, `-Dhttp2` before 5,198 to 5,325, after 5,192 to 5,267.

An idle HTTP/2 connection on the shared port, after one unary call (`mem.py --grpc`, a method no route answers, so a trailers-only call): 10,334 at 1,000, 10,092 at 5,000, 9,946 at 10,000. Plain and no call in flight is stage 5.3's to measure; this is the figure for the record.

**Routed `GET`**, `-Dhttp2` build, requests a second, five rounds each:

| build | rounds | mean | p99 |
|---|---|---|---|
| `45459d1` | 936,504; 946,841; 944,073; 939,836; 942,328 | 941,916 | 69 to 70 µs (122 µs once) |
| after | 941,053; 942,020; 941,199; 947,026; 940,870 | 942,434 | 69 to 72 µs |

Inside the spread of either, so unchanged.

**What the first attempts cost, and why the third ships.** The tail call compiles (`@call(.always_tail, serve.handleConnection, …)` from a chooser whose signature is the loops'; `noinline` on the chooser is refused, since the callee's type must match) and an HTTP/1.1 connection then cost **9,417 at 1,000 and 9,293 at 10,000, one page more**. Moving the choice to the first wait with a `noinline` hand-on taking pointers cost the same 9,417. Neither was the choosing's frame. `waitForRequest` had gained a second caller (the sniff's) and so stopped being inlined into the loop: the park sat one call frame deeper, and the plain park sits under 300 bytes short of a page ([ADR 212](../../docs/adr/212-tls-is-an-option-a-build-asks-for.md)). Naming it `@call(.always_inline)` in `handleConnection` under `-Dhttp2` gave 5,197. The tail call was not measured again after that, so it is not shown to be worse; what ships is the choice inlined into the Engine's entry, with the HTTP/2 loop run by the entry itself once the choosing has returned `.http2`, through a `noinline` function whose arguments are pointers to what the entry already keeps live (`bulkhead.Hand`, `Bridge.runPlain`, `Bridge.handOn`). That keeps the HTTP/1.1 frame the frame it was and puts no outgoing-argument area in it, the 272 bytes a by-value `Peer` costs ([ADR 212](../../docs/adr/212-tls-is-an-option-a-build-asks-for.md)).

**A connection that has said nothing is a second figure, and was a page more.** With `sniffFraming` out of line the first wait parked in its frame and a silent connection cost 9,363 at 1,000 and 9,288 at 10,000. Inlined, with `waitForRequest` named inline inside it, 5,263 and 5,192. A listener's health check or a browser's pre-connect is that connection.

**Outside the suite**, `example-hello -Dhttp2` on one port: `curl` gets the 200 and `wati`; `curl --http2` (an `Upgrade: h2c` offer) is answered as HTTP/1.1; `curl --http2-prior-knowledge` to a plain route is reset `PROTOCOL_ERROR`, which is what the HTTP/2 connection says of anything that is not a call until stage 5.3; a gRPC `POST` to the same port with prior knowledge is answered `grpc-status: 12`, no route; `printf 'GET /\r\n\r\n' | nc` is answered at once, a 400, never waited on.

**The decision it moved:** the choice ships as an inlined chooser with a hand-on from the entry, where the ADR's first preference was a tail call, because that is the one the idle figure held for and measured; ADR 259's text says so. **Can it be pushed further:** the tail call is the open question, and is worth one more measurement with `waitForRequest` inlined as above; nothing in a figure here asks for it. A TLS listener still runs `handleConnection` unchanged and is measured by stage 7.

## What any request on HTTP/2 costs

**Question.** Stage 5.3 of [framing](../../docs/design/framing.md) makes HTTP/2 serve every method but `CONNECT` through the router, middleware and handler on a fiber of its own, held to RFC 9113 §8, with `Ctx.connection()` removed and what waits for stage 6 refused by name ([ADR 259](../../docs/adr/259-http2-is-a-framing-of-every-request.md)). The bar the ADR set: a build without the flag byte-identical, an HTTP/1.1 connection in a `-Dhttp2` build at the idle figure it held, a request on HTTP/2 allocating no more than the same one on HTTP/1.1 from the second on a connection, and its time and idle figure on record.

**Machine and builds.** AMD Ryzen 7 9700X, Linux 7.2.5, Zig 0.16.0, `-Dtarget=x86_64-linux-gnu`, `ReleaseFast`, stripped. Before is `1e7d905` from `git archive`, after is the working tree on it, built the same afternoon. Server on cores 0 to 3, the client on 4 and 5.

**Size**, stripped:

| program | build | before | after | difference |
|---|---|---|---|---|
| `example-hello` | default | 1,013,408 | 1,013,408 | 0 |
| `example-rest` | default | 1,221,320 | 1,221,320 | 0 |
| `example-hello` | `-Dhttp2` | 1,103,496 | 1,116,168 | +12,672 |
| `example-rest` | `-Dhttp2` | 1,292,856 | 1,305,544 | +12,688 |

The 12.7 KB is the §8 checks, the `HTTP` answer and its head, and the stage-6 refusals. It is paid only by a build that asked for HTTP/2.

**Idle HTTP/1.1 connection**, `mem.py` at 1,000 and 10,000, two interleaved rounds: `-Dhttp2` before 5,317 to 5,321 and 5,197 to 5,198, after 5,317 to 5,321 and 5,197 to 5,198. A silent connection: 5,192 before and after at 10,000.

**Idle HTTP/2 connection**, `mem.py --h2` (the preface, a `GET /users/42` with the stream left to finish, then idle), the same two rounds: 9,462 at 1,000, 9,365 at 5,000, 9,355 at 10,000, before and after to within 4 bytes. With `--get`, the stream left open after the request with its answer read: 11,186 at 1,000, 10,736 at 5,000, 10,686 at 10,000. A browser opens one such connection where it opened six HTTP/1.1 ones (6 x 5,197 is 31,182).

**Routed `GET` over HTTP/1.1**, `-Dhttp2` build, wrk, 64 connections, five rounds each: before 967,168; 957,109; 959,555; 960,715; 961,044 (p99 67 to 68 µs), after 964,223; 964,639; 956,436; 958,093; 966,061 (p99 67 to 69 µs). Inside the spread of either, so unchanged.

**In process**, `zig build profile -Dhttp2`, one core, three runs: a routed `GET` over HTTP/1.1 412 to 414 ns, a unary gRPC call 866 to 869 ns, and the same routed `GET` over HTTP/2 963 to 971 ns on one connection's fiber, answered inline: HPACK decode 34 ns (3.5%), the App 370 ns (38%), frames, head and answer 558 ns (58%). No Engine runs there, so the fiber spawn a request costs in a server is not in it.

**Through a real server**, `h2load -n 1000000 -c 64 -m 10 -t 2` (nghttp2 1.12.0, Docker, host network) on `nilo-hello` with `-Dhttp2`, three runs: 1,015,573; 946,846; 1,013,072 requests a second, every one a 200. For the record: one fiber per stream, no reuse yet.

**Allocations.** `test "a request on HTTP/2 allocates no more than the same request on HTTP/1.1 from the second on a connection"` in `http/behaviour.zig`, counting at the allocator under the arena: 0 on both framings from the second request, a 100 byte body included.

**Outside the suite.** `curl --http2-prior-knowledge` against `example-hello` and `example-rest -Dhttp2`: a GET, a POST with a JSON body, a `HEAD` (no `DATA`), a 404 and a route's own headers all answer as on HTTP/1.1. h2spec 2.6.0 over the same port fails 67 of 146 as shipped. Nearly all of them are one thing: the suite sends the first header block without a dynamic table size update after our `SETTINGS_HEADER_TABLE_SIZE` of 0, which RFC 7541 §4.2 requires of the client, so the connection answers a compression error where the suite expected the stream to work. On a scratch copy with the table at 4096 the suite's own blocks decode, and what it then showed that was a real violation is fixed here: a stream depending on itself (§5.3.1), a `WINDOW_UPDATE` or `DATA` on a stream that is not open (§5.1), a window past 2^31-1 (`max_window` was one bit short), and a `GOAWAY` that dropped the frames already read. Run again on the tree as committed, with only the table widened to 4096 in a scratch copy (`example-hello`, `ReleaseSafe`): **142 of 146 pass**. The four left are choices, not defects: §3.5/2 sends a preface that differs from HTTP/2's, which one port serves as HTTP/1.1 by design (ADR 259) rather than answering `GOAWAY`; §5.1/8 and §5.1/11 send `DATA` on a stream the client reset or ended, which the connection counts against its window and ignores, because a reset for every such frame is a client making the server write uncounted (ADR 220); §5.4.1/1 sees the connection closed by a reset rather than a FIN after the `GOAWAY`, because the client's unread bytes are still in the socket when it closes. As shipped, with the table at 0, h2spec cannot test the rest: its encoder never sends the size update, which curl does (its requests above decode); a browser is put to it in stage 7.

**The decision it moved:** none. `Ctx.connection()` goes (ADR 253's open question), a `Collected` answer carries its length and a pre-written field block so HTTP is framed without a second copy, and the frame fuzzer holds the answer's block against the same properties. Whether a request on HTTP/2 can be made cheaper than 963 ns is the optimisation session's: reusing a finished call's fiber for the next stream is the first thing it tries ([`todo.md`](../../docs/todo.md)).

## What a request on HTTP/2 costs when its body is a pipe

**Question.** Stage 6.1 of [framing](../../docs/design/framing.md) runs a request on HTTP/2 when its header block is whole and reads what the client sends after it through a pipe the connection fills, the gRPC envelope and `c.body()` included, where the connection used to collect a call whole before it ran ([ADR 260](../../docs/adr/260-a-request-on-http2-runs-from-its-headers.md)). The bars it set: a build without the flag byte-identical, the idle figures unchanged, the HTTP/1.1 path unchanged, the message rows of `zig build profile` within one wait of collected, `c.body()` on a body that arrived whole allocating nothing, and an upload faster than its handler holding the connection to its budget.

**Machine and builds.** AMD Ryzen 7 9700X, Linux 7.2.5, Zig 0.16.0, `-Dtarget=x86_64-linux-gnu`, `ReleaseFast`, stripped. Before is `ab11878` from `git archive`, after is the working tree on it, built the same afternoon and run interleaved. Server on cores 0 to 3, the client on 4 and 5 (Docker, host network, `arena-wrk` and `arena-h2load`).

**Size**, stripped, `ReleaseFast`:

| program | build | before | after | difference |
|---|---|---|---|---|
| `example-hello` | default | 1,013,408 | 1,013,408 | 0 (`cmp` identical) |
| `example-rest` | default | 1,221,320 | 1,221,320 | 0 (`cmp` identical) |
| `example-hello` | `-Dhttp2` | 1,116,152 | 1,130,800 | +14,648 |
| `example-rest` | `-Dhttp2` | 1,305,528 | 1,321,376 | +15,848 |

The 14.6 KB is the pipe, the wait, the budget moved onto the call's fiber and the `bodyStream` path on HTTP/2. It is paid only by a build that asked for HTTP/2. **The default build was not identical at first**: `Request.ends_with_stream` as a `bool` and a sixth and seventh variant on `Body`'s `Progress.State` shrank `serve.serveRequest` by 217 bytes and moved a jump table, with no HTTP/2 in the program. The field is `void` and the transport's body a flag beside the state, both absent without the flag, and the two programs are the same bytes.

**Idle connection**, `mem.py` against `nilo-hello -Dhttp2` (HTTP/1.1 after one `GET /health`, HTTP/2 after one `GET /users/42`, as the entries above), three interleaved rounds, bytes a connection:

| connection | at | before | after |
|---|---|---|---|
| HTTP/1.1 | 1,000 | 5,313 | 5,313 |
| HTTP/1.1 | 10,000 | 5,197 | 5,197 |
| HTTP/2, `--h2` | 1,000 | 9,429 | 9,560 to 9,568 |
| HTTP/2, `--h2` | 10,000 | 9,352 to 9,353 | 9,423 to 9,424 |
| HTTP/2, `--h2 --get` | 1,000 | 10,375 | 10,199 |
| HTTP/2, `--h2 --get` | 10,000 | 9,853 to 9,955 | 9,641 to 9,657 |

**The HTTP/1.1 figure is unchanged and the HTTP/2 one is not**: +131 to +139 bytes at 1,000 and +70 to +72 at 10,000 after one `GET`, 176 bytes fewer at 1,000 and 196 to 314 fewer at 10,000 with the stream left open. The first is real and is what the pipe weighs: `Shared` went from 64 to 80 bytes, `Conn` from 408 to 432, and a `Stream` from 392 to 608 with its 208-byte `Inbox`, the spare one a connection keeps for the next call. The second the pipe made smaller by taking the message out of a state of the connection's. An HTTP/2 connection is still 1.8 times an HTTP/1.1 one.

**Routed `GET` over HTTP/1.1**, `-Dhttp2` build, wrk, 64 connections, 8 s, five interleaved rounds each: before 864,194; 878,745; 893,978; 899,211; 895,174, after 890,982; 895,442; 897,818; 895,040; 902,401 requests a second (p99 103 to 1,220 µs before, 107 to 555 after; the high ones are the first round, a cold server). Inside the spread, so unchanged.

**In process**, `zig build profile -Dhttp2`, one core, six interleaved runs, ns a call, answered inline because no Engine runs there, so what a wait costs is not in them:

| row | before | after | difference |
|---|---|---|---|
| a routed `GET` over HTTP/1.1 | 421 to 426 | 417 to 421 | none |
| a unary gRPC call | 850 to 860 | 912 to 918 | +62 (+7%) |
| the same `GET` over HTTP/2 | 960 to 977 | 992 to 1,008 | +30 (+3%) |
| a JSON `POST` over HTTP/2, 13 byte body (new row) | 811 to 827 | 897 to 906 | +85 (+10%) |

**The pipe costs 30 to 85 ns a request in process, and this is the number that went the wrong way**: the message rows are 7 and 10% slower, where ADR 260 asked for within one wait. A wait is not in the rows, so what they pay is the pipe's bookkeeping with nothing to wait for: a buffer kept, a monitor taken at every step (a try-lock first, which took about 15 ns back), the grant of the window, a request that starts twice where it is deferred until its stream has ended. Whether it is within one wait is the next row's to say.

**Through a real server**, `h2load -n 2,000,000 -c 64 -m 10 -t 2 -d <1 KiB>` (nghttp2 1.59.0) on `nilo-bench-body-server -Dhttp2`, `POST /echo` (`c.body()`), five interleaved runs each: before 1,781,458; 1,898,028; 1,906,623; 1,908,785; 1,914,009 requests a second, after 1,728,244; 1,761,981; 1,921,359; 1,948,752; 1,948,868, every one a 2xx. **The two spreads overlap**: a handler that starts at the HEADERS and parks for the DATA, a real wait through the Engine on every request, is not resolved from the collected one by this load. A request is about 2.1 µs of server CPU at this rate, and the spread of either is 4 to 8% of it, so a wait that costs more than about 100 ns would have shown. `POST /stream` (`c.bodyStream()`, which HTTP/2 refused before): 1,769,168; 1,881,579; 1,862,499, every one a 2xx.

**An upload faster than its handler**, `http/h2pipe_live.zig`, a client that obeys the server's WINDOW_UPDATEs against a handler that does not read for 400 ms and then reads 4 KiB at a time, a counting allocator under the server: the client could send the window, 65,535 bytes, and then had to stop; the stream was given no credit while the handler read nothing; **68,425 bytes** were held above idle while it stalled, and **98,890** at the peak of the whole 8 MiB, which then completed with every byte counted by the handler (Debug build, `NILO_UPLOAD_REPORT=1`). The bound is the window and one buffer growing into it, and it does not depend on how long the upload is: the test asserts a peak of three windows. Before the buffer was capped at the window by the doubling it held 130,890 bytes while stalled, two windows.

**Allocations.** `test "a body that arrived whole before the handler read it costs the request no allocation of its own"` in `http/h2conn.zig`, counting at the allocator under the arena: 0 a request from the second on a connection for a 3,000 byte body, and `test "a request on HTTP/2 allocates no more than the same request on HTTP/1.1…"` unchanged at 0. `Inbox.whole` returns the bytes where they lie, by a test that compares the pointer.

**Correctness.** h2spec 2.6.0 against `example-hello -Dhttp2` on a scratch copy with the table at 4096: 142 of 146, the four it failed before (3.5 invalid preface, 5.1 closed-stream DATA twice, 7 GOAWAY with an unknown code), no new one. `zig build fuzz -- --frames` with calls on threads, 200,000 connections under three seeds and `--iterations 200000` for the parser, every property held, in `ReleaseSafe`.

**A bug in the tool, found by this run.** `zig build profile -Dhttp2` crashed with a segmentation fault when pinned to one core, in the tree before this change as well: its two HPACK rows decoded into an `ArrayList` with the scratch arena and freed it with the general-purpose allocator, which `SmpAllocator` turns into a corrupted free list once it has one arena and anything allocates after. Fixed in `profile.zig`; the figures above are from the fixed tool, and the earlier entries' were not affected, because nothing allocated after those rows.

**The decision it moved:** none. The pipe's cost per request in process is on the record for the session that tries to make it cheaper: a connection that keeps its `Inbox` out of the stream (one per connection, not per stream) and a start that does not happen twice where no Engine runs.

## What a request on HTTP/2 costs when its answer is a pipe

**Question.** Stage 6.2 of [framing](../../docs/design/framing.md) lets a call write its answer in pieces on HTTP/2 (`c.stream()`, `c.events()`, `c.sendFile`, range requests, `HEAD` without `DATA`) through a pipe the connection empties into frames as both windows allow, where the stream and the file were refused by name ([ADR 260](../../docs/adr/260-a-request-on-http2-runs-from-its-headers.md)). The bars it set: a build without the flag byte-identical, no allocation per piece, the HTTP/1.1 path and its `sendfile` unchanged, the rows of `zig build profile` unchanged, the idle figure of an HTTP/2 connection unchanged, a client that stops reading cut off at the write deadline, and streams that take turns.

**Machine and builds.** AMD Ryzen 7 9700X, Linux 7.2.5, Zig 0.16.0, `-Dtarget=x86_64-linux-gnu`, `ReleaseFast`, stripped. Before is `2cd425d` from `git archive`, after is the working tree on it, built the same afternoon and run interleaved. Server pinned to cores 2 and 3, the client (`arena-h2load`, nghttp2 1.59.0, Docker, host network) to 4 and 5, one connection and one stream at a time.

**Size**, stripped, `ReleaseFast`:

| program | build | before | after | difference |
|---|---|---|---|---|
| `example-hello` | default | 1,013,408 | 1,013,408 | 0 (`cmp` identical) |
| `example-rest` | default | 1,221,320 | 1,221,320 | 0 (`cmp` identical) |
| `example-hello` | `-Dhttp2` | 1,131,424 | 1,142,624 | +11,200 |
| `example-rest` | `-Dhttp2` | 1,321,840 | 1,332,848 | +11,008 |

The 11 KB is the outbound pipe, the connection's turns and the file read into frames, paid only by a build that asked for HTTP/2.

**Pieces and a file**, a scratch dependent (`-Dhttp2`, two threads) with `GET /pieces` (50,000 calls of `writeAll` with 64 bytes, then `finish`) and `GET /file` (64 MiB, `c.sendFile`), `h2load -n 300 -c 1 -m 1` for pieces and `-n 20` for the file, three interleaved rounds each in two sessions, the same `--h1` against the same port for HTTP/1.1:

| route | HTTP/1.1 before | HTTP/1.1 after | HTTP/2 after |
|---|---|---|---|
| 50,000 pieces of 64 bytes, requests a second | 597 to 608 | 596 to 603 | 313 to 316 |
| the same in pieces a second | 29.9 to 30.4 million | 29.8 to 30.1 million | 15.6 to 15.8 million |
| 64 MiB file, GB/s | 6.6 to 8.1 | 6.7 to 7.3 | 3.17 to 3.19 |

HTTP/1.1 is inside its spread. **HTTP/2 writes a piece at half the rate of HTTP/1.1 and a file at 45% of `sendfile`'s**, and that is the price of the frames: each `DATA` frame is a header and a copy where HTTP/1.1 chunks into a buffer or hands the file to the kernel. Before this change HTTP/2 answered both with a 500 naming the refusal. **A file's buffer set the rate**: read 16 KiB at a time (one frame a hand-over to the connection's fiber) the file went at 2.20 to 2.28 GB/s, at 64 KiB (a connection's turn, `pump_quantum`) at 3.17 to 3.19, and at 256 KiB, past the client's 64 KiB window, at 0.56. It is 64 KiB, which is what a streaming file call holds in its arena while it runs.

**Allocations.** `test "a piece costs no allocation: a stream of two hundred allocates what a stream of one does"` in `http/h2conn.zig` counts at the allocator under the connection: the same number for a stream of 200 pieces as for one of 1, so a piece allocates nothing and the pipe and its head are made once. The 5.3 test (a request on HTTP/2 allocates no more than the same on HTTP/1.1 from the second on a connection) is unchanged at 0.

**In process**, `zig build profile -Dhttp2`, one core, three runs each, ns a call: the routed `GET` end to end 409 to 419 before and 393 to 399 after, `stream: 200 pieces` 1,012 to 1,026 and 997 to 1,020, `sse: 200 events` 3,521 to 3,666 and 3,569 to 3,624, `body: 1 MiB, chunked 8 KiB` 12,176 to 12,395 and 12,301 to 12,899. **One row moved the wrong way**: `write the response` 49 to 52 before and 55 to 59 after (+6 ns, 12%), in a path this change does not touch; the end-to-end row beside it went the other way, so it reads as the layout of the function and not as work, and it is not isolated.

**An idle connection**, `mem.py --h2` against `example-hello -Dhttp2`, two rounds each, bytes a connection at 500, 1,000 and 10,000: 9,708, 9,560 and 9,423 before and after, to the byte (`Conn` grew by a few words, which the allocator's size classes absorbed).

**What a stalled stream holds.** A stream whose client stopped reading holds, at most, its `Stream`, one `Outbox` (184 bytes) and the head's block in the request arena, one piece the call lent (the call's own buffer, not copied: a file's is the 64 KiB above) and the call's parked fiber. `test "a client that stops reading is cut off at the write deadline…"` in `http/h2pipe_live.zig` (400 ms limit): 65,535 bytes written, the window; the stream reset with `CANCEL` after 300 to 3,000 ms (asserted); the call's next write failed; a second stream on the same connection answered meanwhile, and a `PING` after it.

**Fairness**, `http/h2pipe_live.zig`, an 8 MiB piece and a 5 byte answer on one connection with the windows wide open: the small answer ended after **131,072 of the 8,388,608 bytes** of the large one, two turns of 64 KiB, and a test asserts less than half.

**Correctness.** h2spec 2.6.0 against `example-hello -Dhttp2 ReleaseSafe` on a scratch copy with the table at 4096 (the header table setting and the acknowledgement's `allow`): **141 of 146, and 140 on a run in four where §3.8/1 or §7/1 sees a reset instead of a close, as the tree before this change does** (five runs on each, 141 four times and 140 once, one connection refused each). The five it fails, 3.5/2, 5.1/8, 5.1/9, 5.1/11 and 5.4.1/1, are the five `2cd425d` fails, so nothing new; the brief's 142 to 144 was a figure from an earlier tree. `zig build fuzz -- --frames` 200,000 connections under five seeds (1, 0x77, 0xabc, 0xc0ffee, 0x5eed5) and `--iterations 200000` for the parser, every property held, in `ReleaseSafe`.

**The fuzzer found three bugs of the outbound pipe**, in the first run, each of which a test now holds as a corpus line: a reset by a client that sent a `WINDOW_UPDATE` of 0 or past 2^31-1, or `DATA` after its own end, reached a stream whose answer was already written, and was written after the `END_STREAM`; a reset that came before the call had begun to answer was not seen by the call, which then answered on a stream that was gone; and its checker took the `SETTINGS_MAX_FRAME_SIZE` of a client as 16,384 whatever it said, where a server may fill a frame to it.

**Two bugs found in the way.** A client that gave back its window one frame at a time stopped a server writing an 8 MiB answer: the connection read nothing while a stream had more to write, so the client's updates went unread until its own socket's buffer was full and it blocked in a write, with the server blocked in a write to it. The connection now looks at the socket between rounds (see the review below), and the test client gives the window back in batches as clients do. And `Wire.pump` of `http/h2pipe_live.zig` freed a list its decoder had grown in an arena with the general-purpose allocator, which `SmpAllocator` turned into a corrupted free list that failed an unrelated test further on in the run: the same mistake as the profile's two rows above.

**The decision it moved:** the file buffer of 64 KiB, not a frame's worth. A file over HTTP/2 stays at 45% of `sendfile`; `sendfile` between frames on plain TCP is in [`todo.md`](../../docs/todo.md) for the session that measures it. What would push it further: a longer turn than 64 KiB where the window allows, which needs the window to be larger than the client's default to matter.

### Review of the first version

A review of the first version found seven defects, each fixed with a test that was seen failing without the fix (the three behavioural ones by reverting the fix and rerunning).

- **A fixed walk starved the later streams, and whole answers.** `pumpOutputs` always began at the first stream of the table, so with a connection window shorter than the streams' demand the first took every WINDOW_UPDATE, and the whole answers were pumped after the streamed ones had taken the window. It now begins where the last round stopped (the stream that used the window goes last), and whole answers are written first. `test "three streamed answers and a whole one share a connection window of the default size, and all of them finish"` (`http/h2pipe_live.zig`: three 4 MiB lends and a `pong`, the connection window left at 65,535 and given back as the client reads): the whole answer ends before any streamed one, none is reset, and when the first streamed one ends each of the others has delivered more than half. Without the fix it fails.
- **A late call could park for ever.** A call that opened or waited on its pipe after `abortOutbound` had walked the table had its wake dropped. `Shared.dead` is set under the monitor before the walk, and `Outbox.open`, `lend` and `finish` read it under the same monitor (`Link.dead`), so a late pipe fails at once. `test "a pipe on a connection that has stopped writing fails at its first lend and its end, and never parks"` in `http/outbound.zig`; without the fix the first lend would park for ever. It is reached only when the end of a connection is cut short by a cancel, which an in-process test cannot cause, so the test is of the pipe.
- **A lend that kept moving was cut at the write limit.** `stuck_since` was set by the first round to end on its quantum and cleared only when the piece was written whole. It now restarts whenever bytes went in the round, and is set only when nothing could be written. `test "a large lend that keeps moving is not cut at the write limit, however long it takes"`: a 300 ms limit, a client that takes 4 MiB at 4 ms a frame (more than 900 ms): complete, not reset. Without the fix it is reset.
- **The 1 ms look at the socket capped a big lend at about 0.5 GB/s.** A new `Waker.poll` (`Wake.lookNow`, `CompletionQueue.next` after a `yield`) asks whether the socket is readable or the connection posted, without waiting, and the connection asks it every round that has more to write. `wait(0)` is no limit, so this is its own call. The reviewer's reading of the stale-poll worry holds: the look sits inside `if (c.in.bufferedLen() == 0)`, arms through the same `arm()` as `wait`, and `poll_armed` clears only when the poll fires, so nothing is submitted twice. **One 64 MiB lend over HTTP/2: 0.455 GB/s with the 1 ms look every eighth round, 4.85 to 4.92 GB/s with the non-blocking one** (`h2load -n 10 -c 1 -m 1`, two interleaved sessions of three, the same tree except for that call). The 64 MiB file is 3.16 to 3.19 GB/s against 3.07 to 3.17, and 50,000 pieces 315.6 to 317.5 against 313.4 to 315.4: unchanged inside the spread. HTTP/1.1 on the same route 9.1 to 12.5 GB/s. Because the round no longer waits, `overdue` is called from it, at most once a millisecond, or a stuck stream's deadline would never be looked at while another stream kept the connection busy.
- **A file buffer was flat and uncharged.** It is `min(len, 64 KiB)` now, charged to a per-connection budget of 1 MiB (`file_budget`, `Shared.file_held`) and given back when the file call returns. **A file past the budget is not failed and does not wait: it reads through a smaller buffer, never under 4 KiB**, slower and correct, so a connection's stalled downloads hold at most 1 MiB and 4 KiB a stream (100 streams: 1 MiB and 400 KB, where the first version held 6.4 MB). `test "a file's buffer is its size when it is small…"` in `http/framing.zig`.
- **A frame of one byte earned flood credit.** Credit is now earned by bytes: two updates (the connection's and the stream's) for each KiB of DATA written, however many frames it took. A client with a window of one byte that answers each byte with two updates is counted by `max_control_run` and sent `ENHANCE_YOUR_CALM` after a few hundred bytes, while a frame of one byte is still sent when the window is one (h2spec 6.9.1 sees its byte). `test "a client with a window of one byte that answers each byte with two updates is a flood…"`; without the fix the client is sent data for ever.
- **The default build ran a line of the HTTP/2 arm.** `shape.bodyless = …` is under `if (comptime framing_mod.http2_built)`, and `Waker.poll` is a field of the vtable only in a `-Dhttp2` build, so the default build is `cmp`-identical again (a first version of the call made `example-hello` 496 bytes larger).

**The second round's gates.** The frame fuzzer under three seeds that were not used before and the parser fuzzer, 200,000 each in `ReleaseSafe`, every property held. h2spec on the widened scratch copy (the table setting and the acknowledgement's `allow`, both): 140 to 141 of 146 over nine runs, the tree before the stage 139 to 142 over eight, so the same distribution, with 3.5/2, 5.1/8, 5.1/9, 5.1/11 and 5.4.1/1 failing in all and 3.8/1 and 7/1 in some. `zig build profile -Dhttp2`, three runs: the routed `GET` 405 to 418 ns, `write the response` 50 to 55, `stream: 200 pieces` 999 to 1,013, `sse: 200 events` 3,502 to 3,521: the same as before, the +6 ns of the first version's `write the response` is gone.

## What an event stream handed to the HTTP/2 connection costs

**Question.** Stage 6.3 of [framing](../../docs/design/framing.md) lets `c.eventsFrom` work on HTTP/2: the Rooms ring the connection's bell, the connection writes their posts as `DATA` under both windows in turn with every other stream, and the handler's fiber ends ([ADR 260](../../docs/adr/260-a-request-on-http2-runs-from-its-headers.md), [ADR 227](../../docs/adr/227-an-event-stream-fed-by-rooms-waits-where-a-connection-waits.md)). The bars it set: a build without the flag byte-identical, the HTTP/1.1 handed-over figure and the idle HTTP/2 connection unchanged, the rows of `zig build profile` unchanged, and a handed-over stream's idle figure on record against a parked fiber's at 1,000 and 10,000 streams.

**Machine and builds.** AMD Ryzen 7 9700X, Linux 7.2.5, Zig 0.16.0, `-Dtarget=x86_64-linux-gnu`, `ReleaseFast`, stripped. Before is `96232b2` from `git archive`, after is the working tree on it, built the same afternoon and run interleaved. Server pinned to cores 2 and 3, the client (`bench/mem.py`, `bench/fanout.py`) to 4 and 5. For the figures that need a route that feeds from a Room, `bench/stream_server.zig` (the same source for both trees, which gained a `/blast` route and a `BACKLOG` variable for this) built with and without `-Dhttp2`. Figures below are after a review of the first version (see the end), with the first version's where they differ.

**Size**, stripped, `ReleaseFast`:

| program | build | before | after | difference |
|---|---|---|---|---|
| `example-hello` | default | 1,013,408 | 1,013,408 | 0 (`cmp` identical) |
| `example-rest` | default | 1,221,320 | 1,221,320 | 0 (`cmp` identical) |
| `example-chat` | default | 1,062,816 | 1,062,816 | 0 (`cmp` identical) |
| `example-hello` | `-Dhttp2` | 1,142,624 | 1,147,760 | +5,136 |
| `example-rest` | `-Dhttp2` | 1,332,848 | 1,337,984 | +5,136 |
| `example-chat` | `-Dhttp2` | 1,194,416 | 1,199,536 | +5,120 |
| `bench-stream-server` (calls `eventsFrom`) | default | 1,208,176 | 1,208,176 | 0 (`.text` identical; 53 bytes of `.eh_frame` and its index differ) |
| `bench-stream-server` (calls `eventsFrom`) | `-Dhttp2` | 1,345,976 | 1,360,912 | +14,936 |

The 5.1 KB is the connection's half of the hand-over (the step and the heartbeat, the turn in the rotation, the end, the shielded end at a stop), paid by any `-Dhttp2` build; the further 9.8 KB is the stream's half (`Http2Events`, the replay, the event formatting) and is paid only by a program that calls `eventsFrom`, because the connection reaches it through two function pointers (ADR 227). **A program that calls `eventsFrom` pays nothing on HTTP/1.1.** The first version paid 112 bytes there and the review found why: the HTTP/1.1 walk over a stream's seats called the shared walk through a sink, 16 of them, and the seat helpers took two arguments more. The walk is written out again in `RoomEvents.deliver` (the shared one is HTTP/2's), and the helpers take the stream whole, so the HTTP/1.1 instantiation is what it was.

**Idle bytes a stream**, `bench/mem.py --hold` (HTTP/1.1) and `--h2 --streams-per-conn N` (HTTP/2, a stream counted, not a connection), against `bench-stream-server` with the logger installed, two rounds each:

| held stream | 1,000 | 10,000 |
|---|---|---|
| HTTP/1.1, handed to the connection, before and after | 5,263 | 5,192 |
| HTTP/1.1, parked in its handler (`c.events()`) | 21,627 | 21,574 |
| HTTP/2, handed to the connection, 100 to a connection, opened 1,000 at a time | 6,820 to 6,889 | 6,190 to 6,253 |
| HTTP/2, the same in one step from 1,000 | 6,533 to 10,224 | 11,976 to 12,153 |
| HTTP/2, handed to the connection, **one to a connection, as a browser opens one** | 14,430 | 14,288 |
| HTTP/2, parked in its handler, 100 to a connection | 19,747 | 19,605 |
| HTTP/2, parked in its handler, one to a connection | 37,405 | 37,264 |
| HTTP/2 connection, nothing in flight (`--h2`), before and after | 9,560 | 9,423 |

**HTTP/1.1 is unchanged to the byte and so is an idle HTTP/2 connection.** A browser's stream, one to a connection, weighs 14.3 KB, of which 9.4 is the connection: **a handed-over stream costs 4.9 KB on top of it, against 27.8 KB for a parked one**. With 100 streams to a connection a handed-over stream weighs 6.2 KB opened a thousand at a time and 12.0 to 12.2 KB opened in one step, against 19.6 KB parked. **The spread between the last two is a number this section could not explain, and [the subsection after the review](#the-spread-of-a-handed-over-stream-is-the-engines-stack-pool) does**: the same server, streams and client give 6.2 or 12.1 KB depending on whether the 9,000 are opened between two reads or all at once, the progressive series is not monotonic (8.6 KB at 4,000 in both rounds), and the parked figure and the HTTP/1.1 ones do not move with it. The figures are also 0.5 KB (progressive) and 1.3 KB (in one step) above what the first version measured (5.6 to 5.8 and 10.3 to 10.9 KB), which the review's changes (a held event's remainder, the failure flags) do not account for by their size, 40 bytes a stream, and which I have not separated from the allocator's behaviour. What a stream holds that a test can see is about 3.4 KB: `Stream` 680 bytes, the arena 1,428, the lists and the pipe.

**Fan-out**, `bench/fanout.py`: 100 subscribers on one Room (`BACKLOG=64`), `/blast` posting as fast as it can for 2 s, events written to the subscribers a second, three interleaved rounds (HTTP/2 over two connections of 50 streams, HTTP/1.1 over 100 connections):

| | events written a second |
|---|---|
| HTTP/1.1, default build, before | 18.1 to 18.2 million |
| HTTP/1.1, default build, after | 18.1 to 18.2 million |
| HTTP/1.1 in a `-Dhttp2` build, after | 18.2 to 18.4 million |
| HTTP/2 in a `-Dhttp2` build | 15.1 to 17.4 million (13.9 to 15.0 before the review) |

HTTP/1.1 is inside its spread. **HTTP/2 writes 83 to 96% of HTTP/1.1's rate** (it was 76 to 82%): the review gated the bell (a post that finds the stream already rung takes no lock and wakes nobody) and the figure rose by about a tenth. The comparison still flatters neither side: its 100 streams are two connections, so two fibers write what 100 fibers did on two threads, and the poster posts 35% more events in the same time (514,000 to 564,000 against 375,000 to 382,000), so it also drops more at the ring. A slow reader is held to the room's ring either way. The poke's lock stays: `Shared.poke` posts the waker under the lock that guards `closed`, because the waker lives on the connection's frame and the same lock is what stops a late post reaching a frame that has gone; moving the post out of it would need the waker to outlive the connection.

**Correctness.** `http/h2conn.zig` has the behaviours as tests on a stepped connection (posts as events in order with no handler running, `retry` first and then history and `Last-Event-ID`, the keep-alive comment and its bound on the wait, a client reset leaving the room, a slow reader bounded by the ring and reset with `CANCEL` at the write limit while another stream is answered, six 20,000-byte streams taking turns with a whole answer, GOAWAY, the connection ending and the server stopping each ending the streams and giving the seats back, the cap refusing the 201st stream, no allocation for 1 or for 100 posts, and `c.upgrade` still refused by name); `http/h2pipe_live.zig` has two on a real Engine (a poster thread of 150 events to three streams with one reset between the halves and every seat given back, and a quiet stream that hears its comments, hears a post after its pages went back and is ended by `app.shutdown()`); `http/behaviour.zig` has the head of a feed as a `HEAD` in the two-framing table (a `GET` never ends); `http/fuzz_frames.zig` has a `/v` route with a thread posting while the frames are read, in the generator and the corpus. h2spec 2.6.0 against `example-hello -Dhttp2` `ReleaseSafe` on a scratch copy with the table at 4096 (the header table setting and the acknowledgement's `allow`): 141, 141, 142 and 141 of 146 over four runs after the review (139, 141 and 141 before it); the five constant failures are 3.5/2, 5.1/8, 5.1/9, 5.1/11 and 5.4.1/1, as in the tree before.

**In process**, `zig build profile -Dhttp2`, three interleaved runs each on core 2, ns a call, before then after: routed `GET` 410 to 411 and 387 to 388, `write the response` 50 to 52 and 49 to 51, `stream: 200 pieces` 1,007 to 1,024 and 1,009 to 1,013, `sse: 200 events` 3,550 to 3,607 and 3,546 to 3,641, `the App, handed the request` 374 to 378 and 350 to 356. **Two rows moved the wrong way**: `a plain struct, as JSON (the control)` 361 and 374 to 378 (+4%), which is code this change does not touch, and `the rest: frames, head, answer` 553 to 562 and 599 to 606 (+8%), which shares the frames and the head with it; the first version had the second at +3% and the first at +3.5%. They read as the layout of the program (the rows beside them went the other way) and are not isolated.

### The review of the first version

A read-only review found no use-after-free, deadlock or lost event, and these defects, each fixed with a test that was seen failing without the fix (the fix reverted for the run).

- **A held event was formatted again at every turn, even with no window.** Every wake cleared the connection's scratch and formatted the whole event before `put` found the window shut, so a client giving its window back a byte at a time cost a full format and copy for each 13-byte frame. An event no window has room for is no longer formatted, and one that went only in part keeps its remainder (`Http2Events.pending`, from the connection's allocator, freed when it is out or on leave): it is formatted once however many turns it takes. `test "a client that gives its window back a byte at a time does not make a held event be formatted again, and is a flood"` counts formats (none while the window is shut, one in all) and sees `ENHANCE_YOUR_CALM` after `max_control_run` updates. Without the room check the test fails at the first count, and without the kept remainder at the second.
- **The 250 ms stop poll is gone.** It cost about 40,000 timer wakes a second at 10,000 idle connections holding a stream and put back the stack pages `releaseStack` had given away. A stop cannot wake a wait; the Engine's main fiber finishes `drain` (which waits for `Stop.in_flight`, counted by `serveRequest` for the length of a request, so a handed-over stream, whose handler has returned, is not waited for) and cancels the group, and the connection's wait comes back `.closed`. A connection that finds `app.stop` requested then ends its streams under a cancellation shield (`bulkhead.beginShield` and `endShield`, new in the Bulkhead contract, zio's own): GOAWAY with `NO_ERROR`, each event stream's end, one flush. `test "an event stream handed to an HTTP/2 connection is sent comments while it is quiet, hears a post after its pages went back, and is ended when the server stops"` (live, `app.shutdown()`) fails without it and passed five runs of five with it. The HTTP/1.1 event stream does not get a wake for a stop either, which is not this change's.
- **Every post poked the connection.** `Http2Events.ring` takes `Shared`'s lock and posts the waker on each; it now returns when the stream is already rung (`rung.swap(true)`), which is safe because `step` clears the flag before it looks, so a post after the look finds it clear and pokes, and `handOver` wakes the connection on its own. The fan-out row above is the measurement.
- **A server stop on a busy stream ended with a reset.** `endEvents` read `stuck_since != 0`, which `pumpEvents` also sets after a turn with more to write. It now pumps the stream until a turn is not cut short (at most 64) and resets only if an event is left unfinished for want of window. `test "a server that stops ends a busy event stream with its end and everything posted, and a stuck one with a reset"` (twelve 20,000-byte events and open windows end with `END_STREAM` and all of them; a 100-byte window and one 5,000-byte event end with `CANCEL` after 100 bytes) fails without it.
- **No memory to format an event killed the connection.** `pumpEvents` returned the error; the stream is now reset with `INTERNAL_ERROR` and forgotten after the round, and the others go on. `test "an event that cannot be kept for want of memory resets its stream and nothing else"` (a failing allocator under the connection) fails without it.
- **The upload test took minutes.** `Wire.pump` of `http/h2pipe_live.zig` returns only after a quiet stretch of `wait_ms` once any frame has come, and the test waited 1,000 ms after each window update, and 3,000 ms after the end. `pumpSome` waits for one frame and takes what came with it. `an upload faster than its handler is held to its window, stalls, and then completes` took 3 min 32 s before and 0.6 s after, asserting what it did (68,497 bytes held while stalled, 98,962 at the peak).

**The decision it moved:** the stream's `Room` bell is a value a framing hands to the seating, so a Room rings the HTTP/2 connection or the HTTP/1.1 request's waker through the same call, and the HTTP/2 walk over a stream's seats is `deliverSeats` while HTTP/1.1's stays written out in `RoomEvents.deliver`. What would push the HTTP/2 figure further: the idle bytes of a stream are the arena and the `Stream` (about 2.1 KB of the 3.4 that can be counted), which the hand-over could give back down to the `Http2Events` the stream keeps, and a stream's per-round share of the connection's fiber is the fan-out's limit, which more than one fiber a connection would change and nilo does not do (ADR 260).

### The spread of a handed-over stream is the Engine's stack pool

**Question.** [The section above](#what-an-event-stream-handed-to-the-http2-connection-costs) could not say why the same server, streams and client weigh 6.2 KB opened a thousand at a time and 12 KB opened in one step, and named the allocator's count as what would settle it.

**Machine and builds.** As that section, the working tree against `04a2e10`, `bench-stream-server -Dhttp2`, `ReleaseFast`, stripped; `bench/mem.py --h2 --streams-per-conn 100 --path /events/room --steps 1000,10000` (one step) and `--steps 1000,2000,...,10000` (a thousand at a time), the server on two cores (4 and 5) or one (4), the client on 6 and 7; the rows marked so ran in a network namespace of their own, because another process on the host's 8787 or 8790 would otherwise be the one measured. `/proc/<pid>/smaps` taken after the last reading.

**The spread is not the allocator's, and the allocator's count was not needed.** The server's heap does not differ between the two readings, because the streams are the same; what differs is the number of fibers that were alive at once. Each call runs on a fiber of its own (`spawnLocal`, on the connection's thread already, so that was not the cause either) that returns as soon as it has handed the stream over, and a fiber's stack goes to zio's stack pool with every page it touched still resident. The pool keeps what a burst needed (`Config.shrink_interval`, 60 s, halving its target each interval), so **what is resident after a burst is the most fibers that were ever alive together**, and that depends on whether the handlers got to run between the connection fiber's reads. The committed part of a stack is a 256 KiB region of its own in `smaps`, and each of those that a handler used holds 15 to 16 KiB:

| reading of the same binary and client | stacks pooled | resident in them | `mem.py` bytes a stream at 10,000 |
|---|---|---|---|
| quiet (server on two cores, early in the day) | a few hundred mappings in all | | 4,831 to 4,887 |
| burst, one core (namespace) | 5,259 to 6,066 | 83.6 to 96.2 MB | 13,421 to 14,781, then 14,872 to 15,123 |
| burst, two cores (namespace) | not counted | | 13,145 to 13,741 |
| burst, two cores | 2,788 to 4,062 | 45.1 to 66.0 MB | 9,258 to 11,406 |

**The 6 KB to 12 KB spread of the section above is the pool's, and a stream that stays costs 4.8 KB** (the Stream, its arena and its lists are the 3.4 KB a test can count). The 15 KiB a fiber touches is the route's own depth: the call, `Ctx`, the typed layer.

**What changed.** `runCall` of `http/h2conn.zig` calls `bulkhead.releaseEndingFiberStack()` (the Engine's `releaseIdleStack`, one `madvise(MADV_DONTNEED)` below the running frame) when its call handed an event stream over, just before the fiber ends. A stream that lives on pays one syscall, once; an ordinary request pays nothing. A pooled stack then holds 8.2 KiB (the frames at its top) instead of 15 to 16.

| burst, `mem.py` bytes a stream at 10,000 | before | after |
|---|---|---|
| one core, six rounds (namespace) | 14,872 to 15,123 | 10,198 to 10,413 (-31%) |
| two cores, six rounds (namespace) | 13,145 to 13,741 | 9,667 to 9,897 (-27%) |
| two cores, five rounds | 9,258 to 11,406 | 9,597 to 9,828 (-10% of the mean) |
| pooled stacks, resident each (two cores) | 2,788 to 4,062, 15.8 KiB | 5,724 to 5,991, 8.2 KiB |

**It does not make the burst stable, and the third row says why:** the `madvise` takes the fiber longer to end, more of them are alive together (5,700 to 6,000 pooled stacks where there were 2,800 to 4,100), and 8 KiB a stack for more stacks is a smaller saving than 8 KiB for the same number. The quiet reading, where the fibers end before the next is spawned, does not move (4,831 to 4,887 before and 4,798 to 5,146 after, six rounds each, in the runs before the host got busy). The idle HTTP/2 connection, the HTTP/1.1 stream and the parked stream are untouched code.

**What did not work, and what is open.** A `yield` after every eighth spawn in `Conn.start` left the pool where it was (6,076 to 6,240 regions on one core): the fibers spawned on the connection's thread are not run first by zio's queue, so the burst cannot be cut from the connection's side without a placement the scheduler does not offer. **Giving back the arena and the `Stream` was not done**: the arena holds the `Http2Events`, the `Replay` list, the `Outbox` the connection still reads `out` through, the head block and the decoded fields, so it can be reset only once all of those have moved to the connection's allocator, which is a restructuring of `Stream` that the HTTP/2 request path is being changed around, and it is worth at most the 1.4 KB the arena holds of the 4.8. What is left of a burst is two pages of a pooled stack for as many fibers as were alive together, until the pool's own timer lets them go; `stack_pool.shrink_interval` is zio's option and is not changed here. What would settle the rest: the pool's retained stacks counted as the handlers run (`smaps` over time), with the same burst at a `shrink_interval` of 5 s.

## What offering h2 to a browser costs

**Question.** Stage 7 of [framing](../../docs/design/framing.md) makes a TLS listener of a `-Dtls -Dhttp2` build offer `h2` and `http/1.1` by ALPN and serve what the handshake chose, through one call after it, and removes the listener option `.grpc` ([ADR 259](../../docs/adr/259-http2-is-a-framing-of-every-request.md), revising [ADR 027](../../docs/adr/027-tls-is-terminated-in-front.md) in place). The bar the ADR set: an HTTP/1.1 connection over TLS holds the idle figure of the same build before, the figure of an HTTP/2 connection over TLS on record before a browser is offered `h2`, a page load in Chromium over both protocols, a static file over TLS on both, h2spec over TLS, and a build without the flags unchanged.

**Machine and builds.** AMD Ryzen 7 9700X, Linux 7.2.5, Zig 0.16.0, `-Dtarget=x86_64-linux-gnu`, `ReleaseFast`, stripped. Before is `4e2644a` from `git archive`, after is the working tree on it, built the same afternoon and run interleaved, two rounds. The server on cores 0 to 3, the client on 4 to 7 (physical cores, SMT siblings idle). Memory: `bench/mem.py --tls` (`--h2 --get` for HTTP/2, which now negotiates `h2` and refuses to go on if it is not what was chosen) against `nilo-bench-tls-server`, `ulimit -n 65536`. The page: `bench/page_server.zig` and `bench/page_load.mjs`, a fresh Chromium and profile each run, the cache off. Files: `h2load` (nghttp2 1.59.0, Docker, host network) against the same server built `-Dcpu=native`.

**Where the choice is made.** The handshake's ALPN list is `h2` then `http/1.1` in a `-Dhttp2` build and `http/1.1` alone in any other; tls.zig picks the first of the server's list the client also offered (server preference) and reports it in `conn.alpn_protocol`. The Engine's one TLS entry reads it after the handshake: `h2` runs `hand_on`, the `noinline` function a plain listener's HTTP/2 connection already runs from the entry's frame (ADR 062), and anything else runs the HTTP/1.1 handler as it did. `runTlsGrpc`, the second instantiation of the entry, is gone, and so is `.grpc`.

**A stall it found, and fixed.** The first `mem.py --tls --h2 --get` stopped with a read timeout at 946, 1, and 1,328 connections in three of four runs: a client that sends the preface and SETTINGS in one TLS record and its `HEADERS` in the next, back to back, has both records in the server's first read, the server decrypts one, finds its cleartext buffer empty and parks on the socket, which the kernel has already emptied. `Wake.wait` now answers `.readable` while the record layer holds ciphertext or decrypted bytes (`Wake.held`), and a poll that fired meanwhile is checked against the socket once (`believe`). `test "a second TLS record that arrived with the first is answered, not waited for on an emptied socket"` puts both records in one socket write, twenty times, and was seen to fail without the fix (so did the ordinary `GET` test beside it, which sends its two records one after the other). It is the question [`todo.md`](../../docs/todo.md) carried for a WebSocket over TLS, answered from the code before and by this now; the fix is in `Wake.wait`, which a WebSocket parks in too. After it, two runs of `mem.py --h2` to 10,000 connections each and every Chromium load completed.

**A review's refinement: only a whole record counts.** `Wake.held` first answered for any ciphertext in the record layer's buffer, but tls.zig peeks a record's five-byte header and takes its payload, so the buffer can hold a header or half a payload behind a record already decrypted. Answering `.readable` for that sends the caller into a read that blocks on the socket until the rest arrives or the read deadline runs out, deaf meanwhile to a handler's post, to the other streams' answers on an HTTP/2 connection and to a WebSocket broadcast, and `lookNow` (the `out_more` probe) would have answered it every round. `held` now answers for decrypted leftover, or for `buffered >= 5` and `buffered >= 5 + length` from the header, peeked and not consumed; a partial record falls through to the poll, which fires when the rest arrives because the socket is drained. A whole record that is not application data (a ticket, a KeyUpdate) cannot be told apart cheaply: every record after the handshake is type 23 on the wire and only decrypting says what it holds, so it is answered like any whole one and the read after it waits for the next record. Four tests send a whole record (a PING frame, or a masked WebSocket text frame the loop says to its room) and 3 or 12 bytes of a second in one socket write, then post into the room, and the client has five seconds to receive the post: HTTP/2 and WebSocket, header only and half a payload. All four, and the two before them, failed with the whole-record test replaced by "any buffered byte" and pass with it. Not tested: `lookNow` (the HTTP/2 `out_more` probe) with a partial record; it shares `held`. Re-measured after it: `-Dtls -Dhttp2` HTTP/1.1 at 10,000 connections 9,341 and 9,370 against 9,335 and 9,335 before (6 to 35 bytes, inside the 30-byte jitter two runs of one binary showed), `-Dtls` 9,364 and 9,335 against 9,364 and 9,364, HTTP/2 after a `GET` 9,589 and 9,550 (9,564 to 9,581 earlier).

**Size**, stripped:

| program | build | before | after | difference |
|---|---|---|---|---|
| `example-hello` | default | 1,013,408 | 1,013,328 | -80 |
| `example-rest` | default | 1,221,320 | 1,221,240 | -80 |
| `example-hello` | `-Dtls` | 1,614,640 | 1,615,008 | +368 |
| `example-rest` | `-Dtls` | 1,822,248 | 1,822,456 | +208 |
| `example-hello` | `-Dhttp2` | 1,147,760 | 1,147,680 | -80 |
| `example-rest` | `-Dhttp2` | 1,337,984 | 1,337,888 | -96 |
| `example-hello` | `-Dtls -Dhttp2` | 1,753,504 | 1,751,104 | -2,400 |
| `example-rest` | `-Dtls -Dhttp2` | 1,943,920 | 1,941,296 | -2,624 |

No build is `cmp` equal, so the bar of a byte-identical default build is not met to the letter: the 80 to 96 bytes under the default and `-Dhttp2` builds are `.grpc` going from `Options`, `Listener` and the Engine's per-listener state, and its refusal's text. The 208 to 368 over a `-Dtls` build is `Wake.held` and `believe`, which only a build with TLS in it compiles (gated on `nilo_build.tls`, so the default build pays none of it; without the gate the default build was 336 bytes over). The `-Dtls -Dhttp2` build is 2.4 to 2.6 KB smaller because one entry is instantiated where two were.

**Idle HTTP/1.1 connection over TLS**, bytes a connection after one request, `mem.py --tls`, `http/1.1` offered, two interleaved rounds (a range is the rounds):

| build | 1,000 | 5,000 | 10,000 |
|---|---|---|---|
| `-Dtls`, `4e2644a` | 9,826 to 10,441 | 9,448 to 9,513 | 9,364 to 9,628 |
| `-Dtls`, after | 9,826 | 9,390 to 9,447 | 9,363 to 9,364 |
| `-Dtls -Dhttp2`, `4e2644a` | 9,826 to 10,117 | 9,390 to 9,448 | 9,364 |
| `-Dtls -Dhttp2`, after | 9,892 to 10,183 | 9,403 to 9,461 | 9,370 |

The 1,000 column is noisy in every build, run to run, by 600 bytes. At 10,000 the `-Dtls -Dhttp2` build holds **6 bytes more**, and the marginal cost from 1,000 to 10,000 is the same to the byte (9,312 before and after in the first round): the 6 bytes are about 64 KB of resident memory that does not grow with the connections, the size of the code the TLS entry now touches, and not a page a connection. The page ADR 212 measured is unchanged: a `-Dtls` build is 9.4 KB against 5.2 KB on a plain listener, with and without `-Dhttp2`. A plain listener, `example-hello`, two rounds: default 5,247 and 5,190, `-Dhttp2` 5,378 and 5,204, at 1,000 and 10,000, before and after to the byte.

**Idle HTTP/2 connection over TLS**, after one `GET /health` (the stream finished, nothing in flight), `mem.py --tls --h2 --get`, after only (before there was no `h2` on a TLS listener):

| connections | round 1 | round 2 |
|---|---|---|
| 1,000 | 10,215 | 10,224 |
| 5,000 | 9,705 | 9,608 |
| 10,000 | 9,581 | 9,564 |

That is 194 to 211 bytes over an HTTP/1.1 connection on the same listener at 10,000, where on a plain listener it is 4,158 over (9,355 against 5,197): the TLS page is the cost both pay, and the HTTP/2 connection's own state fits beside it. **One browser opens one such connection where it opened six HTTP/1.1 ones**: about 9.6 KB against 6 x 9.37 = 56.2 KB.

**A page load in Chromium** (Chromium 152.0.7977.82, headless, `--ignore-certificate-errors`, a page of nineteen subresources: four stylesheets, four scripts, eight images, a `fetch` of JSON, an `EventSource` and a WebSocket, `page_load.mjs`), `loadEventEnd` in ms, median and range of five runs a batch, three batches interleaved:

| | HTTP/2 (`h2` offered) | HTTP/1.1 (`--disable-http2`) |
|---|---|---|
| loopback | 47.7 (40.8 to 51.6); 46.8 (40.9 to 52.7); 48.5 (40.7 to 59.6) | 49.4 (42.3 to 58.5); 46.3 (39.1 to 51.8); 49.8 (48.2 to 56.2) |
| connections for the page | 1 | 4 to 6 |
| `nextHopProtocol` | `h2` | `http/1.1` |
| +20 ms on every request (`Network.emulateNetworkConditions`), two batches | 80.4 (77.0 to 83.8); 76.5 (73.1 to 84.7) | 120.8 (115.8 to 122.4); 117.4 (111.7 to 118.4) |

On loopback there is nothing to wait for and the protocols are the same inside their spread. With 20 ms added, six connections serialise nineteen requests and one does not: 77 to 80 ms against 117 to 121. The `-Dtls` server (no `h2` in the handshake) gives 48.6 (39.2 to 63.3) over six connections, the same as `--disable-http2` against the `-Dhttp2` one. **Chromium works with `SETTINGS_HEADER_TABLE_SIZE` of 0**: every request of every run was answered, on the one connection, so it sends the size update the server's decoder requires. The `fetch`, the `EventSource` (`eventsFrom` in a Room, a message after the page poked it) and the WebSocket all completed in every run. **The WebSocket is on a connection of its own**: its handshake is the 101 of HTTP/1.1, and the server holds two sockets for the page, the HTTP/2 connection and the WebSocket's (nilo sends no `SETTINGS_ENABLE_CONNECT_PROTOCOL`).

**A static file over TLS**, `h2load -c 1 -m 1`, one stream, `-Dcpu=native` (AES instructions; at the baseline target the cipher is 59 MB/s for either protocol and the framing does not show), no `sendfile` on either ([ADR 260](../../docs/adr/260-a-request-on-http2-runs-from-its-headers.md)):

| file | HTTP/1.1 | HTTP/2 |
|---|---|---|
| 1 MiB, held in memory (1,000 requests, three rounds) | 2.70, 2.71, 2.71 GB/s (359 µs a request) | 1.66, 1.76, 1.65 GB/s (553 to 589 µs) |
| 64 MiB, opened per request (12 requests, three rounds) | 599, 603, 593 MB/s | 1.57, 1.57, 1.58 GB/s |

**Both went a way worth saying.** A held 1 MiB file is **35 to 40% slower over HTTP/2** than over HTTP/1.1 on TLS; and a spilled 64 MiB file is **2.6 times slower over HTTP/1.1**, which is the odd one: the same file read the same way is 600 MB/s on one framing and 1.6 GB/s on the other, so the HTTP/1.1 spilled path over TLS is leaving something on the table. Neither is traced here; [the section after](#what-a-tls-write-is-sealed-in) traces and fixes both.

**h2spec over TLS** (`summerwind/h2spec -t -k -P /`, a scratch copy with the HPACK table widened to 4,096 in both places, since h2spec's encoder never sends a size update, three runs): **142 of 146 every time**, failing 3.5/2, 5.1/8, 5.1/9 and 5.1/11, the constant four of the plain baseline (139 to 142 of 146); 5.4.1/1 passed, which it does not on a plain port, and 3.8/1 and 7/1 did not flake.

**Routed `GET` over TLS**, `h2load --h1 -c 64 -t 2`, `/users/42`, `-Dtls -Dhttp2` build at the baseline CPU target, three rounds interleaved: before 183,901; 185,254; 184,975 requests a second, after 192,610; 188,447; 190,067. Not slower; the sign is the same in all three pairs and no cause is claimed. **`curl --http2 -k`** negotiates `h2` and is answered, `curl --http1.1 -k` negotiates `http/1.1` and is answered, `openssl s_client` with no ALPN and with `-alpn http/1.1` is answered HTTP/1.1, and with `-alpn spdy/3` alone fails with alert 120, `no_application_protocol`: RFC 7301 §3.2 says a server that supports none of the protocols offered SHALL answer that alert, and tls.zig does; every browser and client library offers `http/1.1`, so this is a client offering nothing the listener speaks. A client with no ALPN is served, since the library selects nothing when it is not asked.

**The decision it moved:** ALPN is offered `h2` first in a `-Dhttp2` build, the choice is read in the one TLS entry and HTTP/2 is run from its frame through the `noinline` hand-on a plain listener already uses; `.grpc` goes, with Zig's own "no field named" error as its refusal; and `Wake.wait` answers from bytes the record layer holds. **Can it be pushed further:** the 6 bytes at 10,000 and the 64 KB under them are worth tracing only if a dependent asks; a held 1 MiB file over HTTP/2 and a spilled one over HTTP/1.1 on TLS are the two numbers that went the wrong way, and the second one is likely a buffer size.

## What a request on HTTP/2 costs once its clocks, copies and passes are counted

**Question.** A routed `GET` over HTTP/2 was 974 to 1,032 ns in process and a unary gRPC call 958 to 1,003, against 386 to 390 for the same route over HTTP/1.1. Where does the difference go, and how much of it can be taken out without spending an idle byte, an allocation or a line of ADR 253's refusals? The bar set was a 2x cut on the `GET`.

**Machine and builds.** AMD Ryzen 7 9700X (8 cores, 16 threads), Linux 7.2.5, Zig 0.16.0, `-Dtarget=x86_64-linux-gnu`, `ReleaseFast`, stripped. Before is `04a2e10` from `git archive`, after is the working tree on it, built the same afternoon and run interleaved. Builds on cores 4-7 and 12-15; the in-process profile pinned to core 2; for a server, `taskset -c 0-1` with `h2load` (Docker, `--network host`) on cores 2-3 and `wrk` the same way, under one lock so nothing else ran.

**Method.** `zig build profile -Dhttp2`, the tree at `04a2e10` beside the working tree, four to five interleaved runs of each. The breakdown is rdtsc probes plus a `SIGPROF` sampler at 2 kHz with frame-pointer unwinding in a scratch build, and the same sampler inside `nilo-hello` under `h2load -c 64 -m 10 -t 2` for what the in-process profile cannot see. Real server: `h2load -n 1,000,000 -m 10` and `-n 400,000 -m 1`, CPU read from `/proc/<pid>/stat`.

**What the cost was made of** (a `GET`, in process, about 1,000 ns): two clock reads per request (the monotonic stamp at every frame read and the realtime clock for `Date`), a header block copied three times (decode, `Collected.fields`, the answer's headers), five separate validation passes, a linear scan of the 61-entry static table for each answer header, the standard arena's atomic operations on every allocation, a monitor taken to end a stream nothing else reads, and a 616-byte `Stream` rebuilt at each recycle. Decoding the HPACK block was 34 ns of the `GET` and 125 to 137 of the gRPC call (Huffman on h2load's strings); it was never the large part.

**What was changed, each measured on the message rows** (ns, interleaved runs, before at `04a2e10` / after):

| row | before | after | HTTP/1.1 on the same runs |
|---|---|---|---|
| routed `GET` over HTTP/2 | 974 to 1,032 | 784 to 807 | 386 to 388 before, 408 to 428 after |
| unary gRPC call | 958 to 1,003 | 774 to 793 | |
| `POST` of 13 bytes as JSON | 898 to 943 | 739 to 761 | |

The `GET` is 2.0 times HTTP/1.1 where it was 2.5. The HTTP/1.1 row is 20 ns higher in this build than in the tree before, in every run and also with `date.zig` and the profiler's changes taken out, though no code on that path changed; `wrk` through a server does not show it (898k to 908k requests a second before, 885k to 933k after, p99 86 to 105 us against 79 to 100 and one 343 us), and it is code layout, which a later run showed. With the three optimisation changes of this afternoon together (this one, [the header lookup](#a-header-is-looked-for-by-the-lines-that-can-hold-it) and [the TLS sealing](#what-a-tls-write-is-sealed-in)) the routed HTTP/1.1 `GET` of a default build read 406 to 415 ns against 394 to 397, every binary copied to one path and run with an empty environment, four interleaved rounds. Two controls settle what that is. The tree before with nothing but an unused exported function of 16, 48, 80 or 112 `nop`s added read 408 to 426, as far from the tree before as the change is; and the same binary run from two paths of different length read 394 against 402 to 406 until the path was made the same, because the path and the environment move the stack. So a margin under about 20 ns on this row is not a result in either direction, and a run that compares two builds copies each to the same path first. Through a server it is not there: `wrk -t2 -c64 -d8s` on the default build's `example-hello` (`/users/7`), server on cores 0-1 and client on 2-3, three interleaved rounds, read 343k to 350k requests a second at 2,737 to 2,760 ns of server CPU each before and 350k to 356k at 2,687 to 2,716 after.

The changes: the monotonic stamp is taken when bytes had to come off the socket for a frame, and once more after a frame whose payload was waited for, so the next head (usually in the same read) is not stamped with the time an upload began; `fields` capacity is reserved from the block's size before decoding; the five validation passes are one SWAR scan that skips the name check for a name that is in the static table (a differential test holds it to the old functions over 20,000 random cases, with names from the table, copies of them and literals); `fieldHead` builds the head in one arena allocation; the head block for a streamed answer is written straight from the route's headers with the static indices known at compile time (no `Collected.headers` copy, no 61-entry scan); `staticNameIndex` is a comptime `StaticStringMap`; a stream that opened with nothing to read ends its `Inbox` without the monitor.

**A stamp that was too stale.** The first version stamped only when a frame's head had to be waited for. Behind a long upload the next head is already buffered when the payload's read ends, so it was stamped with the time the payload began, and a `grpc-timeout`, the body limit and the silence limit all counted from it (`test "a call that arrives behind a slow upload is stamped when its bytes came, not when the upload began"` fails on that version: an 80 ms stall leaves the stamp 80 ms old). Stamping again after a frame whose payload was waited for costs a clock read only on a frame that was not already whole in the buffer, which the `h2load` runs below include.

**The coarse clock for `Date` bought nothing and was taken out.** `CLOCK_REALTIME_COARSE` against the precise clock, `zig build profile -Dhttp2`, five interleaved runs each: the HTTP/1.1 row 407 to 414 ns coarse and 408 to 410 precise, the HTTP/2 `GET` 787 to 791 against 785 to 797. `Date` reads the clock once a response and the read is not where the time goes, so the header keeps its precise second and never lags (ADR 197 unchanged).

**Through a server** (`h2load -c 64 -t 2`, two interleaved passes of two rounds each, the final tree): `-m 10` 1,053k to 1,089k requests a second and 1,610 to 1,640 ns of server CPU a request before, 1,161k to 1,187k and 1,450 to 1,470 after, **8 to 10% more throughput and 9 to 11% less CPU**; `-m 1` 575k to 591k before and 600k to 616k after with CPU 2,725 to 2,800 against 2,575 to 2,600, 4 to 6% on both. The spawn of a fiber for each stream, which the in-process profile cannot see, is about 9.5% of the server's CPU (near 140 ns a request) by sampling; running the request on the stream's own fiber in an experiment bought nothing measurable, so it was not kept.

**The four axes.** Allocations a request: the budget test holds (not re-counted per row). Idle memory: `bench/mem.py --h2` at 10,000 connections 9,423 B before and after; `--h2 --get` 9,521 B before, 9,513 B after. Throughput and p99: above. Size, stripped `ReleaseFast` `nilo-hello`: default build 1,020,872 bytes before and after (`cmp`-identical), `-Dhttp2` 1,155,184 to 1,156,944 (+1,760).

**Correctness.** `zig build test` and `zig build test-all` exit 0 (no Postgres in this environment, so `test-sql` ran without it); the frame fuzzer in `ReleaseSafe`, 1,000,000 connections, seeds `0x7a3c91e5d2b84f06` (first version) and `0x1b5e77c3a9d04f82` (final), and the HTTP/1.1 parser fuzzer, 1,000,000 inputs, seed `0x4c2f90e1b7a35d68`, every property held; h2spec 2.6.0 on the scratch copy with the table at 4096, three runs each: 140, 142, 141 of 146 before and 141, 141, 142 after, and the set of failing cases after is inside the set before (3.5/2, 5.1/8, 5.1/9, 5.1/11 constant, 5.4.1/1, 3.8/1 and 7/1 flaking).

**The decision it moved:** none, apart from a row in the running total of [ADR 017](../../docs/adr/017-the-trade-budget-has-four-axes.md). The App still receives an HTTP/2 request as a head and parses it with the same parser as HTTP/1.1.

**Can it be pushed further:** about 80 ns is the second parse of the head the App does on an HTTP/2 request, which skipping would split the refusals of the two protocols (ADR 253), so it was not done. A single-threaded arena for a `Stream` (an estimated 30 to 60 ns) and a fiber kept for the next stream (the 9.5%) are the two left; the second raises head-of-line blocking within a connection and needs its own argument. The HPACK dynamic table is not worth its idle bytes at this share. The 2x bar was not reached on the `GET` in process (2.5 to 2.0 times HTTP/1.1) and a call through a server costs 8 to 10% less CPU.

## What a TLS write is sealed in

**Question.** [The section above](#what-offering-h2-to-a-browser-costs) left two numbers going the wrong way on a TLS listener with AES in the target: a held 1 MiB file 35 to 40% slower over HTTP/2 than over HTTP/1.1 (1.65 to 1.76 GB/s against 2.70), and a spilled 64 MiB file 2.6 times slower over HTTP/1.1 than over HTTP/2 (593 to 603 MB/s against 1.57). The bar: each at least up to the other protocol's figure, with idle memory not a byte more on any listener and the default build unchanged.

**Machine and builds.** AMD Ryzen 7 9700X, Linux 7.2.5, Zig 0.16.0, `-Dtarget=x86_64-linux-gnu`, `-Doptimize=ReleaseFast -Dcpu=native -Dstrip=true` (AES instructions in the target), `bench-page-server -Dtls -Dhttp2`. Before is `04a2e10` from `git archive`, after is the working tree on it, built the same afternoon and run interleaved, five rounds. Server on cores 0 to 3 (and their siblings), `h2load` (nghttp2, the `arena-h2load` image, `--network host`) on 4 to 7, under the shared bench lock. `STATIC_DIR` holds `1m.bin` and `64m.bin` of random bytes; `h2load -c 1 -m 1 -n 1000 https://127.0.0.1:8443/files/1m.bin`, `-n 12` for the 64 MiB file, `--h1` for HTTP/1.1.

**No tracer was on this host** (`strace`, `perf` and `bpftrace` are not installed), so the causes were read from the code and then tested by changing one thing at a time, each build measured:

| build | h1 1 MiB | h2 1 MiB | h1 64 MiB | h2 64 MiB |
|---|---|---|---|---|
| before | 2.60 | 1.70 | 0.58 | 1.55 |
| record buffer out holds 4 records, one write per drain | 3.3 | 2.05 | 2.4 | 1.83 |
| ...and the last byte of a drain held back, so the write waits for the flush | 3.3 | 2.34 | 2.4 | 2.26 |
| ...and a body already in the arena not copied on HTTP/2 | 3.2 | 3.1 | 2.4 | 2.3 |

GB/s, one round each, so read to a tenth. What the code showed. **The library writes a record to the socket the moment it has sealed it** (`Connection.encryptWrite` ends in `output.flush()`), and the record buffer out was one record, so a write that reached the record layer cost a write per 16 KB, and, since a cleartext writer drains what it holds before the data it was handed, **an HTTP/2 frame's nine-byte head was a record and a write of its own** before each 16 KiB of payload. **A file on HTTP/1.1 is read through the cleartext writer's buffer** (`sendFileReading`, because a record layer has no `sendfile`), which is the connection's 4 KiB write buffer: a `pread` of 4 KiB, a record of 4 KiB and a write of 4 KiB, sixteen thousand times for 64 MiB, where HTTP/2's file call reads through 64 KiB. And **HTTP/2 copied a held body into the request arena** before it was written (`Collected.whole`): a megabyte past what the arena keeps, a page fault for each page and a `memcpy`, 110 µs of the 529 to 558 µs; HTTP/1.1 writes it from where it lies. The third row leaves that copy out for a body the framework owns (`Ctx.sendOwned`: a static file the App holds, and what is written into the arena, a value's JSON, a `nilo_write`, a message, gzip output). **A first form borrowed every `sendKept` body, which includes a slice a handler returned and a `Bytes.body`, and a route returning bytes a service frees could then be written after they were gone; it was withdrawn**, and those keep the copy (`h2conn.zig` has a test that overwrites the handler's buffer once the route has returned and the client has been sent 1,000 bytes of 20,000; it fails with the borrow on `sendKept`).

**What changed.** `http/engine/zio.zig`: the TLS entry's cleartext writer is `Sealer`, which holds the library's flush for the length of one drain and writes what was sealed in one go, keeps the last byte of a drain that carried data in the cleartext buffer (so that a caller that flushes only a writer with something in it finds something, and a drain never leaves bytes behind a writer that reads as empty), and reads a file 64 KiB at a time into a buffer that lives for the file alone; the record buffer out is two records (4 gave the same figures within 5%, 3 inside one spread). `http/framing.zig` and `http/ctx.zig`: `Framing.whole` takes `kept` (it means owned), and HTTP/2 does not copy a body of 16 KiB or more that is. `Ctx.sendOwned` is new, used by `serve.zig`'s held files and by `typed.zig`'s written, message and JSON bodies. `http/bulkhead.zig` and `http/h2conn.zig` carry the event stream's part (below). Tests: `tls_live.zig` sends a 300 KB body, a 300 KB file and a small answer in a row on one connection and compares every byte; `framing.zig` has the borrow and its three exceptions, and `h2conn.zig` sends 20,000 bytes of each owner kind under a 1,000-byte window.

**Final numbers**, five interleaved rounds (a range is the rounds), GB/s unless MB/s, mean request time in brackets:

| | before | after |
|---|---|---|
| held 1 MiB, HTTP/1.1 | 2.55 to 2.63 (353 to 359 µs) | 3.13 to 3.21 (295 to 300 µs) |
| held 1 MiB, HTTP/2 | 1.61 to 1.77 (529 to 558 µs) | 3.03 to 3.09 (303 to 307 µs) |
| spilled 64 MiB, HTTP/1.1 | 579 to 606 MB/s (100 to 106 ms) | 2.33 to 2.39 (25.7 to 26.3 ms) |
| spilled 64 MiB, HTTP/2 | 1.52 to 1.58 (38.3 to 40.2 ms) | 2.21 to 2.25 (26.8 to 28.0 ms) |

**Both inversions are closed**: HTTP/2 holds 96% of HTTP/1.1 on the held file (it held 63 to 68%), and HTTP/1.1 is 4.0 times what it was on the spilled one and now ahead of HTTP/2. Routed small answers over TLS (`h2load --h1 -c 64 -t 2 -D 3 /api/data`, and `-c 64 -m 10` for HTTP/2, three interleaved rounds): HTTP/1.1 547,120; 549,338; 544,790 requests a second before against 547,464; 538,683; 543,193 after (inside the spread), HTTP/2 1.47 to 1.49 million against 1.60 to 1.62 (+8%, the head and the payload leave in one write).

**The four axes.** Allocations per request: none added on the ordinary path (the 64 KiB read buffer of a file over TLS is one allocation per file answer, freed at its end; `test "the request path stays inside its allocation budget"` passes). Idle memory, `bench/mem.py` at 10,000 connections in a network namespace of its own, before then after: plain 5,190 and 5,190, plain HTTP/2 10,201 and 10,202, `-Dtls` 9,365 and 9,365, `-Dtls -Dhttp2` HTTP/1.1 9,371 and 9,370, HTTP/2 10,315 and 10,267 (the 1,000 column moves by 600 in either build, as above). The second record's pages are touched only by an answer larger than one record, and stay resident until the connection's next idle release, as the first's do. `sendFileAll` with a limit past the end of the file no longer takes a second buffer: `Sealer.sendFile` answers `EndOfStream` before allocating once the file reader is at its end. Stripped `ReleaseFast` `example-hello`: default 1,013,328 to 1,013,392 (+64, the `owned` argument and `sendOwned`), `-Dhttp2` 1,147,680 to 1,148,832 (+1,152), `-Dtls` 1,615,008 to 1,616,864 (+1,856), `-Dtls -Dhttp2` 1,751,104 to 1,754,000 (+2,896); `example-rest` +48, +1,040, +1,840 and +2,784 in the same builds. Throughput of the routed `GET` is the row above. The fuzzers, 1,000,000 inputs each in `ReleaseSafe` on new seeds (`--frames` 0xC0DEC5EED5, the parser 0xC0FFEE5EEDC): every property held.

**What did not work, and what was weighed.** Writing the last record of a drain at once, the first form, reached 2.05 GB/s on HTTP/2 where the form that waits for the flush reaches 3.0. Leaving the sealed records in the record buffer with nothing in the cleartext one was faster still and **unsafe**: `Socket.park` and `RoomEvents.park` flush a writer only `if (end != 0)`, so a message that left the cleartext buffer empty with records waiting would have sat there until the next write; keeping a byte is what makes `end` tell the truth. A bigger cleartext write buffer on every TLS connection was not taken (idle memory), and a frame size that fills a record does not help an arbitrary alignment. `sendfile` is still not used on TLS, which a record layer cannot (kTLS is ADR 212's open alternative).

**After the ownership fix, rerun** (four interleaved rounds, same commands, under the lock): held 1 MiB 3.12 to 3.21 GB/s on HTTP/1.1 and 3.05 to 3.09 on HTTP/2, spilled 64 MiB 2.33 to 2.36 and 2.18 to 2.23, so the held-file gain survives (the static file is `sendOwned`).

**The final flush of a connection is not shielded.** It could be cut by the cancellation a stop sends, and then the last record would not leave, but so can every write of a response in flight at a stop (the flush at the end of each drain is the same write), and a shield on a write with no deadline armed would let a stalled peer hold the stop. Left as it was.

**The decision it moved:** ADR 212 gained the paragraph on the record buffer and the cleartext writer. **Can it be pushed further:** HTTP/2 is 4% behind on the held file and 5% behind on the spilled one, which is the frame head and a second record per frame; batching the frames of one turn into one write would need the connection to say where a turn ends, which is `http/h2conn.zig`'s.

## What a connection's task costs, how a stack buffer costs at idle, and how close the park sits to a page

Run on 2026-10-08 at `514e8c1` plus the working tree, on the machine above, kernel 7.2.5. `bench/mem.py` in a private network namespace, `nilo-hello` built `ReleaseFast` with `-Dtarget=x86_64-linux-gnu -Dcpu=x86_64_v3`, server on cores 4 to 7, 1,000, 5,000 and 10,000 connections, each build twice. The before was built from the same commit in a scratch directory, same flags, same afternoon. Marginal (5,000 to 10,000) agrees with the average at 10,000 to within 10 bytes.

**The 512 bytes.** [`releases.md`](./releases.md) read 4,674 at v0.2.0 and 5,186 at v0.3.0. The bisect found no frame that grew: `serve` handed every connection's task a copy of `Options` (264 bytes) among its spawn arguments, which took zio's task from its 384-byte pool to the allocator's 1,024 class, where a 512 B one had been. The arguments are now `.{ st, stream, conn_gpa, sh }` and the sizes are read through `sh.sizes`, a pointer to a heap copy `serve` makes once. Commands: each server binary run in a private network namespace (`unshare -rn`, loopback up) on cores 4 to 7, then `python3 bench/mem.py --port 8787 --steps 1000,5000,10000` (default `--settle 2`) against `nilo-hello`, the same with `--tls` against `nilo-bench-tls-server`, and `--h2 --get` (with `--tls` for the TLS rows) for the h2 rows; each build twice, the second run in the table. Bytes per idle connection at 10,000:

| listener | before | after |
|---|---|---|
| plain | 5,188 | **4,678** |
| plain listener of a `-Dtls` build | 9,300 | 8,787 |
| TLS | 9,350 | 8,847 |
| `-Dhttp2`, an HTTP/1.1 connection | 5,204 | 4,691 |
| `-Dhttp2`, h2c after one GET | 9,677 | 9,506 |
| `-Dtls -Dhttp2`, TLS HTTP/1.1 | 9,327 | 8,853 |
| `-Dtls -Dhttp2`, TLS h2 after one GET | 10,259 | 10,267 |

The two h2 rows move by far less than 512: the stream state those connections hold sits in the same size class either way. A variant that shrank the arguments under 384 bytes to use zio's pool saved a further 115 bytes on HTTP/1.1 and made h2c about 390 bytes worse, and was dropped. Stripped `ReleaseFast` binaries: unchanged to within 200 bytes (994.9 KB and 994.7 KB for `nilo-hello`). Taking the address of the `options` parameter instead of a heap copy added 20,304 bytes, which is why the copy is on the heap.

**Throughput did not move.** `nilo-hello` `GET /`, wrk 4 threads 64 connections 10 s, server on cores 0 to 3, three interleaved rounds under the lock: 1,335,138 to 1,351,852 req/s before, 1,337,370 to 1,346,149 after, p50 latency 42 µs both.

**A stack buffer is free at rest.** A body-stream route with `var buf: [64 * 1024]u8` that returns costs 4,685 bytes an idle connection, 7 more than `/health`. A route using `c.stream()` costs 12,876: the stream's own 4 KiB buffer comes from the request arena and `arena_keep` (16 KiB) retains it. With `.arena_keep = 0` it reads 4,715, with a 256 B buffer 5,806. [ADR 062](../../docs/adr/062-where-a-connection-waits-is-what-it-costs.md) and [`s3.md`](./s3.md) had read the arena's bytes as the stack's.

**The park.** The plain stack flips from one resident page to two between 2,809 and 2,841 bytes of depth on the benchmark server (2,793 and 2,825 in the `park-check` program), found with ballast in steps of 16. Depth in the `park-check` program on `ReleaseFast`, read with a store-only probe in `releaseIdleStack` that is not in the tree: 2,505 default (288 under the boundary), 2,729 with `-Dhttp2` (64), 2,889 with `-Dtls` and 2,937 with both (across by 96 and 144). The depth moves by 16 to 32 bytes with a change of layout: a `std.debug.print` in the same frame read 2,537, 2,761, 2,921 and 2,969, and an earlier tree read 2,713 for `-Dhttp2`, so none of these is a constant. The `-Dtls` page is the inliner's: `Bridge.run` is a real call in the plain entry of that build, and two `always_inline` variants either did not compile away the frame or moved the depth the wrong way. `zig build park-check` counts pages and not bytes (a build under the boundary may hold one, `-Dtls` two), fails on a crossing, and runs only on a Linux x86-64 host and target.

**The decision it moved:** ADR 062 gained the sections on the task size class and the park check, and was corrected on the stack buffer; ADR 212 gained the measured margin. **Can it be pushed further:** the `-Dtls` plain listener's page (4,109 bytes) is the one open item, and the pooled-argument variant would take another 115 bytes off HTTP/1.1 if the h2c cost it caused were understood.

### A prototype: an idle HTTP/1.1 connection with no fiber

Run on 2026-10-08, same machine, commit and flags as above, in the patch under [`spike/fiberless-idle/`](../../spike/fiberless-idle/README.md), which says the base commit and how to apply and run it, and which is not merged. The prototype is a plain listener of a default build only (no `-Dtls`, no `-Dhttp2`). At the idle peek (`waitForRequest`, after the pages are released) the connection loop returns instead of waiting, the fiber ends, and the connection is a 512-byte heap record (`Rec`: the stream, the reader and writer, the peer, the listener's state and a `NetPoll` completion) submitted to one `CompletionQueue`. One reactor fiber waits on that queue and, when a socket is readable, spawns a connection fiber on the same record. The patch is about 215 lines over `bulkhead.zig` (a `park` entry in the Waker's table), `serve.zig` and `http/engine/zio.zig`. The memory rows below were read with the first version of the patch and one row (1,000 and 10,000 connections, 1,483 and 967 bytes) again after it was rebased onto the final tree.

Bytes per idle connection, `bench/mem.py` with `--settle 15`, two runs each:

| build | 1,000 | 5,000 | 10,000 | marginal 5,000 to 10,000 |
|---|---|---|---|---|
| fibers, as now | 4,735 | 4,685 | 4,678 | 4,671 |
| no fiber, stack pool shrinking every 1 s | 1,479 | 1,013 | 892 and 843 | 771 and 672 |
| no fiber, zio's default 60 s shrink | 9,351 | 7,542 | 4,919 | 2,296 |

The last row is the cost the prototype cannot hide: a fiber that ends hands its stack back to zio's pool, the pool keeps the stacks it recently needed (a half-life of one `shrink_interval`), and every one of them still holds the page its base frames touched. A burst of 10,000 connections that all idle at once leaves 10,000 stacks in the pool for minutes at the default. The first two rows set `stack_pool.shrink_interval` to one second in `Runtime.init`, which is an option and not a change to zio.

Does it cost anything when busy or when waking? `nilo-hello` `GET /`, wrk 4 threads 64 connections 10 s, server on cores 0 to 3, three interleaved rounds under the lock: 1,340,208 to 1,326,652 req/s with fibers, 1,337,148 to 1,337,977 without, p50 42 µs both (no connection ever parks under load, so this is the control). With 1,000 connections and 300 ms of think time before every request (a wrk `delay()`), every request wakes a parked connection: 3,225 to 3,230 req/s both, p50 0.78 to 0.90 ms with fibers and 0.70 to 0.80 without, p99 1.4 to 2.0 ms and 1.6 to 2.0, server CPU 61 to 64 ticks over 12 s with fibers and 57 to 58 without (a parked wake skips the `madvise` and the fault of the stack's pages). A single client that waits past the peek and then sends one request (`wakelat.py`, 50 connections, 1,000 samples, two runs): p50 29.8 and 29.6 µs with fibers, 34.7 and 42.6 without, p99 133 and 144 µs and 193 and 224. So the first request after a quiet spell is 5 to 13 µs slower at the median and 60 to 80 µs slower at p99 when nothing else is running, which is the price of a fiber spawn and a stack acquire on a wake that an already-suspended fiber does not pay. Stripped `ReleaseFast` binary: 1,020,504 bytes against 1,018,616 (+1.9 KB).

What the prototype leaves out, so the 700 to 770 bytes is a floor: an idle deadline for a parked connection (a timer or a sweep, 8 to 24 bytes), closing the parked ones at shutdown (a list and a lock, 16 bytes), a reactor per executor (one fiber behind one mutex is the wake rate's ceiling), and TLS and HTTP/2, whose connection state lives in the fiber's frame today. `zig build test` on the prototype passed 2,781 of 2,811 tests (30 skipped) with one failing step, `park-check`, which measures the park depth of a stack the parked connection no longer has; `test-all`, the fuzzers and the Debug `Str` trap across a park were not run.

## A fiber that finishes a call takes the next one waiting

**Question.** Every request on HTTP/2 is given a fiber by the Engine's spawn, which sampling put at about 9.5% of a server's CPU under `h2load -m 10` (near 140 ns a request). Can a fiber that finishes a call take the connection's next stream that is already waiting, with no fiber parked for a stream that has not arrived (idle memory), no call waiting behind a handler that parks (head-of-line blocking), and every rule of [ADR 260](../../docs/adr/260-a-request-on-http2-runs-from-its-headers.md) kept?

**Machine and builds.** AMD Ryzen 7 9700X, Linux 7.2.5, Zig 0.16.0, `-Dtarget=x86_64-linux-gnu`, `-Doptimize=ReleaseFast -Dstrip=true -Dhttp2`. Before is `514e8c1` from `git archive`, after is the working tree on it, built the same afternoon and run interleaved under the shared lock. Server (`nilo-hello`, `/users/7`, two executors) on cores 0-1, `h2load` (`arena-h2load`, Docker, `--network host`, `--cpuset-cpus 2-3`) `-c 64 -t 2 -n N -m M`, CPU read from `/proc/<pid>/stat` across the run. The gRPC rows are `spike/grpc/server` (`nilo-grpc`, `NILO_THREADS=8`, cores 0-3 and 8-11) driven by `h2load` on cores 4-7 and 12-15, `-m 100 -t 8 -D 5` with the POST body of HttpArena's `unary-grpc`, as [the gRPC listener's throughput run](#a-grpc-listener-built) does, and `--log-file` for the latency of each request.

**What was built.** A connection queues a call whose headers are in behind a fiber that has been spawned and has not begun, instead of spawning for it (`Shared.pending_head`, `fresh`); the fiber (`h2conn.runner`) takes the oldest queued call in the same hold of the lock that decides it ends (`finishNext`). Before the connection's fiber waits for anything it lets that fiber run (one yield); if it parked inside its call, the next queued call gets a fiber of its own and the connection yields again (`Conn.rendezvous`), so a call is held only by calls that are running. `spawnLocalExact` (new, in `zio.zig` and `bulkhead.zig`) is `spawnLocal` that fails with `InvalidPlacement` instead of dealing the call to another executor; where it fails, reuse is off for that connection.

**Through a server**, three interleaved rounds, `-n 300000` for `-m 10` and 200,000 for `-m 1`:

| shape | before req/s | after req/s | before CPU/request | after CPU/request |
|---|---|---|---|---|
| `-m 10` | 1,130k, 1,198k, 1,197k | 1,233k, 1,283k, 1,315k | 1,433, 1,400, 1,433 ns | 1,300, 1,266, 1,266 ns |
| `-m 1` | 565k, 588k, 573k | 584k, 577k, 588k | 2,700, 2,600, 2,700 ns | 2,600, 2,700, 2,650 ns |

**`-m 10` takes 7 to 10% more requests and 9 to 12% less CPU a request (about 135 ns, the spawn's share); `-m 1` is unchanged**, as it must be: with one stream in flight there is never a stream waiting when a call finishes, and keeping the fiber for the next one would be a parked fiber. The target of the entry was the spawn's share, and it is that.

**gRPC, `-m 100`** (a unary call, 100 streams a connection; one run each, before then after, so read to 5%): 32 connections 2.38M req/s before, 3.04M after (+28%); 64 connections 2.07M, 3.05M (+48%); 128 connections 1.53M, 1.65M; 256 connections 0.99M, 1.07M; 512 connections 0.79M, 0.90M; 1,024 connections 0.94M to 1.03M, 1.05M to 1.11M. The fiber is also a stack: 100 calls that were 100 fibers are one.

**Head-of-line blocking.** `grpc_live.zig` has the case: a quick call, a slow one (`slowEcho`, which sleeps 50 ms) and 24 quick ones, in one write; every quick one is answered before the slow one. With `Conn.rendezvous` taken out that test fails, and so do the existing "two calls on one connection run at once, and the quick one is not held behind the slow one" and two in `h2pipe_live.zig` ("a small answer on a connection does not wait for a large one that is being written beside it" and "three streamed answers and a whole one share a connection window"); with it the whole suite passes in Debug and ReleaseSafe. Why a queued call waits for no more than it did: on one executor a fiber of its own started when every call ahead of it had finished or suspended, and the rendezvous gives it one at the moment the call ahead suspends.

**The four axes.** Allocations a request: none added (the queue is intrusive through `Stream.next`; `test "the request path stays inside its allocation budget"` passes). Idle memory, `bench/mem.py` at 10,000 connections in a private network namespace: `--h2` 9,425 B before and 9,424 after; `--h2 --get` 9,594 to 9,613 before and 9,586 to 9,606 after (three rounds each); a connection holds 24 bytes more in `Shared` and the allocator's size class absorbs them. A burst of handed-over event streams (`--h2 --streams-per-conn 100 --path /events/room`, `nilo-bench-stream-server -Dhttp2`): **7,901 B a stream at 1,000 and 8,101 at 10,000 before, 5,194 and 5,735 after**, because a burst of handlers that return at once is one fiber's work and not four to six thousand stacks. Stripped `ReleaseFast` `nilo-hello`: default build 1,021,416 before and after (`cmp`-identical), `-Dhttp2` 1,158,480 to 1,159,504 (+1,024). Throughput and p99: the rows above.

**Correctness.** `zig build test` and `zig build test-all` exit 0 (no Postgres here). The frame fuzzer in `ReleaseSafe`, 1,000,000 connections, seed `0x3d9f1a62c7e45b08`, every property held (it drives a connection with no Engine, so it does not reach the new path; the live tests do). h2spec 2.6.0 (`summerwind/h2spec`, `-h 127.0.0.1 -p 8787 -P /health`) on a scratch copy of each tree with the HPACK table at 4096 in both places, `nilo-hello -Dhttp2` `ReleaseSafe`, three runs interleaved: 142, 139, 140 of 146 before and 140, 142, 140 after; the cases that fail are 3.5/2, 5.1/8, 5.1/9 and 5.1/11 constant and a GOAWAY, PING or unknown-code case (3.8/1, 6.7, 7/1) in some runs of both, so none that passed before fails.

**The decision it moved:** [ADR 260](../../docs/adr/260-a-request-on-http2-runs-from-its-headers.md) gained the paragraph on the fiber that takes the next call, and two rejected alternatives; [ADR 017](../../docs/adr/017-the-trade-budget-has-four-axes.md) a row in its running total. `bulkhead.yield` now reports a cancel (`error.Canceled`) instead of swallowing it: zio's `yield` is a cancellation point and consumes the cancel it reports, so the connection's yields, the new one and the existing one between rounds of a large answer, would have lost the one cancel a stop sends. A queued call is answered as turned away (gRPC 14, or a 500) and not run once a stop is requested, since the cancel of the fiber's task is spent on the call before it. A server whose tasks migrate (`zio_options`, a compile-time choice of the root module) gets a fiber for every call, as before; no test builds that configuration.

**Can it be pushed further:** a connection with one stream in flight at a time (`-m 1`, a browser's first request) pays the spawn as it did; the only ways to save it are a fiber that is not parked (a pool shared across connections, which holds stacks for idle ones) or a request that does not need a fiber until it suspends, which is a design of its own and is in `docs/todo.md`.

## What a `Stream` costs to recycle, and the monitor at the end of one

**Question.** After [the first round](#what-a-request-on-http2-costs-once-its-clocks-copies-and-passes-are-counted), the `Stream` of 616 bytes is rebuilt at each recycle and a stream that something else reads ends under the connection's monitor. How much of a request is that, as an upper bound, before building the real thing?

**Method.** Two scratch builds of the tree, `zig build profile -Dhttp2`, each binary copied to one path and run as `env -i PATH=/usr/bin taskset -c 2 ./nilo-profile`, four interleaved rounds against the unchanged tree. (a) `Monitor.enter` and `leave` made no-ops everywhere, which is wrong and an upper bound on what any change to the monitor could save. (b) `Stream.recycle` setting about thirty fields by hand and not copying the `Inbox` out and in, an upper bound on a cheaper rebuild.

**Result.** (a) unary gRPC call 771 to 794 ns unchanged, 779 to 804 without the monitor; routed `GET` over HTTP/2 797 to 812 and 818 to 845; `POST` 744 to 756 and 726 to 746 (-6 to -18 ns, the only row that moved the right way, inside the 20 ns the tree's layout moves a row by). (b) gRPC 769 to 829 and 811 to 875; `GET` 794 to 856 and 813 to 872; `POST` 740 to 797 and 739 to 799: slower or equal in every row. **Neither is a result**: with the monitor taken out entirely the rows do not clear the layout noise, and the rebuild is not where a request's 800 ns goes. An `Inbox` per connection would save less than (a) and (b) together, and could not serve two streams with bodies at once without a pool, so it was not built. Nothing was kept.

## Whether a connection should start on the executor that accepted it

**Question.** `spawnInto(.local)` bought 2.7x for a gRPC call. Should a connection start on the executor whose acceptor took it instead of round-robin ([ADR 200](../../docs/adr/200-every-executor-accepts.md))?

**Method.** A scratch build of the tree in which the Engine's accept loop places the connection with `connections.spawnInto(.local, ...)` when `NILO_PLACE` is set, and prints the thread id of each connection when `NILO_TALLY` is set. `nilo-hello` on cores 0-1 (two executors), clients on cores 2-3 (Docker, `--network host`): `wrk` (`arena-wrk`) `-t2 -c64 -d6s` for HTTP/1.1 keep-alive and with `-H 'Connection: close'`, `h2load -c 64 -t 2 -m 10 -n 600000` for HTTP/2 keep-alive and `-c 1000 -m 1 -n 3000` for connections of three requests, three interleaved rounds, round-robin then local.

| shape | round-robin req/s | `.local` req/s | connections on each executor, round-robin | `.local` |
|---|---|---|---|---|
| HTTP/1.1 keep-alive | 810k, 786k, 843k | 881k, 798k, 876k | 33/32 every round | 30/35, 31/34, 39/26 |
| HTTP/1.1 `Connection: close` | 95.9k, 108.7k, 104.4k | 117.7k, 113.8k, 103.1k | 288,613/288,612, 331,516/331,515, 313,987/313,986 | 354,212/353,558, 341,701/342,242, 312,162/308,537 |
| HTTP/2 keep-alive, `-m 10` | 1,238k, 1,143k, 1,209k | **647k, 580k**, 1,076k | 32/32 every round | **6/58, 59/5**, 36/28 |
| HTTP/2, three requests a connection | 39.4k, 32.0k, 44.3k | 40.0k, 39.9k, 38.4k | 500/500 every round | 581/419, 427/573, 733/267 |

**`.local` loses 11 to 53% on HTTP/2 keep-alive in all three rounds and wins 1 to 20% on HTTP/1.1.** The reason is in the right-hand column: the kernel wakes whichever acceptor it likes, so with `.local` the split of 64 connections between two executors was 6 and 58 in one round and 59 and 5 in another, where round-robin deals exactly 32 and 32. Two executors with a 10-to-1 split serve at the speed of the busier one. The condition set for the entry (win on both shapes and lose nowhere) is not met. **Round-robin stays**, and ADR 200's note that `.local` leaves the spread to the kernel is now a number.

## Where a gRPC call's worst latency comes from

**Question.** [The gRPC listener's throughput run](#a-grpc-listener-built) recorded a worst call of 1.4 s at 256 connections and 3.8 s at 1,024 against tonic's 1.1 s, from `h2load`, which reports no percentiles. Where does the tail come from?

**Method.** `h2load --log-file` writes the latency of every request; a ten-line script (scratch) sorts it. Server and `h2load` as in the gRPC rows above, `-c N -m 100 -t 8 -D 5`, the same pinning as the record. `ghz` (`ghcr.io/bojand/ghz`) was tried first and rejected: at 256 connections and 5,120 workers it generated 62k req/s, a tenth of what `h2load` does, so its histogram is the client's. The control is HttpArena's tonic image (`arena-tonic`, cores 0-3 and 8-11, `--network host`) read by the same script.

**The 1.4 s and 3.8 s do not reproduce.** At 256 connections the worst call is 188 to 255 ms before and 226 ms after; at 1,024 connections it is 0.84 to 1.07 s before and 0.87 to 1.06 s after, against tonic's 1.07 s in the same harness (tonic p50 3.2 ms, p90 389 ms, p99 659 ms; nilo p50 71 ms, p90 195 ms, p99 430 to 550 ms). The records of 1.4 and 3.8 s predate `spawnInto(.local)` and several rounds of work since.

**What the tail is made of**, at 1,024 connections (102,400 streams in flight), by the half second a request started in: the first half second has p50 303 to 438 ms and the maximum (102,400 streams are submitted at once and the connections are still being made), and the rest of the run has p50 70 ms, p99 280 to 330 ms and a maximum of 450 to 600 ms. **The mean is fixed by the load, not the server**: 102,400 in flight at 1.0 to 1.1M req/s is 93 to 100 ms by Little's law, which both servers show. What differs is the spread around it. Steady state p99 is 3 to 4 times p50 at every connection count from 256 up (256: 22 and 62 ms; 512: 49 to 57 and 213 to 242).

**Where that spread comes from** (read, then tested). zio's per-executor run queue is a ring of 256 tasks: when it is full it moves the *oldest* half to a shared overflow queue, which the executor refills 64 at a time once a tick (`utils/local_run_queue.zig`: `push`, `pushOverflow`, `refill`). With thousands of ready tasks an executor, a task's wait depends on whether it landed in the ring or the overflow, not on its age. To test it, a scratch build of the server against a zio whose ring holds 16,384 tasks: at 1,024 connections p50 111 ms, p90 119, p99 526 (the first half second; after it p50 110, p99 115, maximum 118 ms), maximum 553 ms against 870 to 1,063; at 256 connections p99 33 to 42 ms against 60 to 62. **The tail was the queue.** The same build served 0.81M req/s at 1,024 connections against 1.07 to 1.16M: strict first-in first-out order across 12,800 streams an executor is slower than the unfair one, whose recently readied tasks are still in cache, so fairness costs 25 to 30% of throughput there and nothing at 256 connections (0.99M and 1.09M against 1.04M and 1.07M).

**The decision it moved:** none in nilo, since the queue is in zio (a dependency, not edited) and the trade is not obviously worth making: the worst call is now what tonic's is, the p99 follows from a queue depth no server of this shape avoids, and what nilo controls, how many tasks are ready, is lower with the reuse above (a burst is one task, not a hundred; p99 at 1,024 connections 430 to 468 ms against 486 to 549). **Can it be pushed further:** a run queue with bounded unfairness is zio's to offer (a request to its author with these numbers); in nilo, fewer tasks ready at once, which for HTTP/2 is now done.

## What running a call on the connection's fiber would buy on HTTP/2, and what the head built for the App costs

**Question.** Two larger changes were asked about on top of the fiber that takes the next call: a request that finishes without suspending needing no fiber at all (run on the connection's until it first parks), and a request entering the App as its decoded fields instead of a text head rebuilt and parsed again. What does each buy, as an upper bound, before anyone designs it?

**Machine and builds.** As in [the section above](#a-fiber-that-finishes-a-call-takes-the-next-one-waiting): `514e8c1` plus the fiber reuse, scratch copies of the tree outside the worktree, `ReleaseFast`, `-Dhttp2`, interleaved under the shared lock, the same commands. Nothing here is in the worktree.

**Prototype of the first** (scratch, `Conn.start`): a call whose stream has ended (`!s.open`), or a gRPC call, which is deferred until its message has ended, runs at once on the connection's fiber through `runCall(s, true)`, the same function a call's fiber runs. It is guarded: the Engine's turn stamp (`bulkhead.loopTurnNanos`) is read before and after, and a call across which it moved parked at some point, after which that connection sends every call to a fiber as before. No code outside `Conn.start` changed. It is not safe to ship (see below), and it is the most this idea can show.

**`nilo-hello`, `/users/7`, `h2load -c 64 -t 2`, three interleaved rounds:** `-m 10` before the reuse 1,073k to 1,103k requests a second and 1,533 ns of server CPU a request, with the reuse 1,112k to 1,216k and 1,366 to 1,433, with the guarded inline run 1,240k to 1,264k and 1,300 to 1,333 (**5% less CPU than the reuse, 14% less than before**); `-m 1` four rounds 545k to 584k and 2,650 to 2,800 before, 562k to 582k and 2,650 to 2,750 with the reuse, 566k to 599k and 2,600 to 2,700 guarded (**inside the spread**: with one stream in flight the spawn was never the large part of 2,650 ns).

**`nilo-grpc` (`spike/grpc/server`), `-m 100 -t 8 -D 5`, cores as the record, two runs each in the order before, reuse, guarded:**

| connections | before req/s | reuse req/s | guarded inline req/s | p99 before / reuse / inline (ms) | worst before / reuse / inline (ms) |
|---|---|---|---|---|---|
| 64 | 1.96M, 1.60M | 1.44M, 1.82M | 1.72M, 2.73M | 7.5, 8.5 / 10.8, 7.5 / 7.5, 4.3 | 43, 37 / 27, 40 / 16, 14 |
| 256 | 1.05M, 1.29M | 1.23M, 1.30M | **2.43M, 2.49M** | 59, 44 / 50, 46 / **13.5, 12.5** | 227, 172 / 214, 177 / **34, 28** |
| 1,024 | 0.89M, 0.99M | 0.95M, 1.08M | **1.40M, 1.87M** | 544, 466 / 519, 507 / **76, 70** | 1,097, 908 / 1,070, 1,019 / **146, 124** |

**Twice the calls a second at 256 connections, 1.4 to 1.9 times at 1,024, and the worst call is 0.12 to 0.15 s where it was 0.9 to 1.1.** (The 64-connection row is dominated by the machine's other users and is read as "not worse".) Why: a call run where its headers were just decoded finds its `Stream`, its arena and the frame in the cache; with the calls queued for a fiber (and before that, with a fiber each) 100 streams' worth of memory, 500 KB a connection, is written by the connection and read cold by the call, and the executor keeps thousands of tasks ready, which is what [zio's queue](#where-a-grpc-calls-worst-latency-comes-from) spills. This is the same effect the fiber reuse could not reach, because the reuse still runs the calls after the connection has parsed the whole burst. **It also removes the tail**: with a handful of tasks ready the run queue never spills.

**What it costs and breaks.**

- **Idle memory: +60 bytes a connection** (`bench/mem.py --h2 --get`, 10,000 connections, two rounds: 9,565 and 9,590 with the reuse, 9,626 and 9,653 inline), the pages the route touched on the connection's stack. The hard axis says not a byte; the idle release the HTTP/2 connection already makes (`dropSpares`, its scratch) would have to give the stack pages back too, as HTTP/1.1's connection does.
- **A call that parks stops the connection reading for as long as it parks**, once per connection with this guard (and once per route with a flag on the route, which needs `typed.zig`'s knowledge of which service a handler takes). That is the rule [ADR 260](../../docs/adr/260-a-request-on-http2-runs-from-its-headers.md) refuses ("the connection stops reading while the handler waits, and a `PING`, a `RST_STREAM` or a `WINDOW_UPDATE` goes unanswered"). Cancellation of that call, a reset of another stream, a GOAWAY and a stop are all seen only when it returns. An executor already stops reading while a CPU-bound handler on a fiber of the same thread runs, so the new exposure is only the parked time, and a client that PINGs with a timeout shorter than a handler's wait would drop the connection. **The prototype does not pass the suite**: `zig build test` on the scratch tree stopped making progress in a test under `http/` (20 minutes of wall and no CPU, killed; the test was not located), which is what deferring every gRPC call until its message has ended does to a test that expects a call to be running while its message is incomplete, and the tests that hold the old rule (`grpc_live.zig` "two calls on one connection run at once...", `h2pipe_live.zig` "a small answer on a connection does not wait for a large one...") would fail by design the first time a call parks.
- **What would make it safe** is not a guard after the fact but not parking inline: a route known not to wait (a typed handler whose arguments hold no service that waits, which `typed.zig` can see and `nilo_sql`, `nilo_fetch`, `nilo_s3` and `cache` can declare on their types) runs inline, and every other route, including every handler that takes a `*Ctx`, keeps its fiber. The guard stays as the net for the unknown and flags the route when it fires. That is a decision for the user (it revises ADR 260's refusal and adds a declaration to the services) and for the owner of `typed.zig`.
- **Event streams, files, bodies read as they arrive** keep their fibers by construction: the criterion is a stream that has ended.

**Prototype of the second, bounded and not built.** The head the App parses on HTTP/2 is built by `fieldHead` and parsed by `http1.parseHead`. `fieldHead` repeated 99 times a request in a scratch build added 2,010 ns to the routed `GET` row, 2,125 to the gRPC row and 1,495 to the `POST` (three rounds each: 19 to 21 ns for a call, 15 for a `POST`), and the parse of a 121-byte head is 73 ns in the HTTP/1.1 profile. **The most that decoded fields entering the App could save is about 90 to 95 ns of a request that costs 810 to 830 in process (11%), about 7% of the server's CPU at `-m 10` and 3.5% at `-m 1`.** Against that: `Ctx` borrows a text head (`findHeader`, the typed extractors, `Str` views into it) and `typed.zig` and `message.zig` read it, so a second representation touches the files the other two agents of this round were working in; and ADR 253's refusals would have to be one validation over a field list that the HTTP/1.1 parser also produces, a rewrite of `http1.zig` whose benefit to HTTP/1.1 is nil. Not recommended on this number; worth reopening only if a cheaper way to give `Ctx` its fields appears.

**Can it be pushed further:** the first idea is the large one on this machine (2x on a gRPC server at 256 connections and above) and rests on one design decision (which calls may run where they might park), measured here only as a ceiling.

## A TLS build's plain listener holds one page

Run on 2026-10-09 at `1e583bc` plus the working tree (the fixed `park-check`, and `nilo_fetch` changes that touch no connection path), AMD Ryzen 7 9700X, Linux 7.2.5, Zig 0.17.0, `-Dtarget=x86_64-linux-gnu -Dcpu=x86_64_v3 -Doptimize=ReleaseFast -Dstrip=true`. The question was why `zig build park-check -Dtls`, with the miscount fixed ([`build.md`](./build.md)), reported 0 of 48 plain connections on a second page while CLAUDE.md, ADR 062, ADR 212 and the design page said a `-Dtls` build pays a page on every listener.

**`park-check`**, `-Dtls`: 0 of 48 hold more than one page and 0 more than two, in 4 runs of the built program pinned to cores 0 to 3 and 2 runs through `zig build`, all exit 0. `-Dtls -Dhttp2`, `-Dhttp2` and the default build read 0 and 0 as well. The same on a clean export of `1e583bc` with only the fixed `bench/park_check.zig` copied in, so the working tree's changes are not what moved it.

**`bench/mem.py`**, `--steps 1000,5000,10000`, each server in its own network namespace (`unshare -rn`) on cores 4 to 7 and `mem.py` on cores 0 to 3 (physical cores, siblings idle), bytes a connection at 10,000 (the 1,000 column moves by about 600 bytes either way):

| listener | build | bytes at 10,000 | marginal 5,000 to 10,000 | runs |
|---|---|---|---|---|
| plain | default | 4,678 | 4,672 | 1 |
| plain | `-Dtls` | 4,692, 4,692, 4,692 (the last on the clean export of `1e583bc`) | 4,672 | 3 |
| plain | `-Dtls -Dhttp2` | 4,699, 4,699 | 4,672 | 2 |
| TLS | `-Dtls`, `nilo-bench-tls-server`, `--tls` | 8,843, 8,844 | 8,769 | 2 |

Marginal meets average to within 25 bytes for the plain rows and 75 for TLS, so these are per-connection figures and not a fixed amount spread thin. The plain listener of a `-Dtls` build costs 14 bytes more than the default build's, not a page. A TLS connection costs 4,165 more than a plain one: a page and 69 bytes, which fits the 3,994 bytes it parks at (ADR 212), two pages. The recorded figures were 8,787 for the plain listener of a `-Dtls` build and 8,847 for TLS (`What a connection's task costs…`, above, at `514e8c1`), so the TLS row is unchanged and the plain row was stale.

**So the record was stale, and `park-check` and `mem.py` agree.** Both read one page for a plain connection in every build. `park-check` never sees the TLS connection's second page because it speaks plain HTTP; its pin of two on `-Dtls` was left over from the plain listener's old page. Not known: which commit between `514e8c1` and `1e583bc` gave the page back (the connection loop and the Bridge were reorganised for the HTTP/2 stages in that range); no bisect was run.

**The decision it moved:** `park-check` pins every build at one page, and CLAUDE.md, ADR 062, ADR 212, `docs/design/memory.md`, `docs/design/tls.md`, `docs/guide/deploying.md`, the roadmap and the todo entry now say a plain listener pays nothing and a TLS connection pays the page. **Can it be pushed further:** a TLS connection's second page is the handshake frames' high-water mark below the park (ADR 212); `park-check` does not cover it, so a TLS connection going from two pages to three is noticed only by `mem.py --tls`. Covering it needs a client that does a handshake, which the program does not carry. The default build's 288 bytes of headroom and `-Dhttp2`'s were not re-read here.

## A file a build compressed is held beside the file

Run on 2026-10-09 at `c4e2d08` plus the working tree of ADR 273, AMD Ryzen 7 9700X, Linux 7.2.5, Zig 0.17.0, one temporary test calling `static.load` on five directories and summing the held slices (the test was removed after the run). The compile was Debug with the standard library's gzip, so the load times below are Debug times and say only which side does the work, not what a ReleaseFast server pays.

The fixture is six real front-end files from this machine's `/usr/share/doc` (jQuery 3.6.0 minified, Bootstrap's `bootstrap.min.css`, clang's `searchindex.js`, LibreOffice's `contents.js` and two ffmpeg HTML pages), 1,421,488 plain bytes. The siblings were written the way a bundler's plugin does: `brotli -q 11` and `gzip -9`, each after the file.

| tree | gzip held | br held | total held | load (Debug) |
|---|---|---|---|---|
| plain only, `compress` on (today) | 339,431 (nilo's) | 0 | 1,760,919 | 186 ms |
| plain only, `compress = false` | 0 | 0 | 1,421,488 | 2 ms |
| `.br` and `.gz` beside every file | 333,516 (the build's) | 279,412 | 2,034,416 | 6 ms |
| `.br` only, `compress` on | 339,431 (nilo's) | 279,412 | 2,040,331 | 186 ms |
| `.br` only, `compress = false` | 0 | 279,412 | 1,700,900 | 2 ms |

What goes over the wire for the whole tree: 279,412 bytes as brotli, 333,516 as the build's gzip -9 and 339,431 as nilo's own, so brotli is 16.2% under gzip -9 and 17.7% under nilo's copy, and nilo's default level is within 1.8% of `gzip -9` on this tree. The largest file, `searchindex.js`, is 803,121 plain, 205,519 gzip and 169,659 brotli.

**What it moved.** The precompressed tree holds 273,497 bytes (15.5%) more than today's, all of it the brotli forms, and saves the startup gzip for every file with a `.gz`. A tree that gives up the gzip copy for brotli alone holds 60,019 bytes less than today's and serves nothing to a client without brotli but the plain file, which is the Chrome-over-HTTP case, so the default keeps nilo's copy when there is no `.gz`. The decision (ADR 273): serve the siblings, on by default, `br` before `gzip` by q, one more form per file held and charged against `max_total_bytes`.

**Not measured, and why.** The "Needs" of the todo entry asked for a front end served by nilo whose build writes these files; these are real files compressed with the real tools but not the output of one bundler, so the byte counts are a tree's and not Vite's. No req/s: the request path takes a slice either way and `behaviour.zig` holds its allocations at zero. Can it be pushed further: the only lever on memory is the choice of which forms to keep, and it is the operator's through `compress`.

## A JSON answer in arena segments does not beat `Allocating`

Run on 2026-10-09 at `c4e2d08` plus `bench/json_segments.zig` (the program and its `bench-json-segments` step, nothing under `http/`), AMD Ryzen 7 9700X, Linux 7.2.5, Zig 0.17.0, `-Dtarget=x86_64-linux-gnu -Doptimize=ReleaseFast`, `taskset -c 5`, SMT sibling idle but the rest of the machine not (other agents were building on other cores). The question was the todo entry "whether a body written into arena segments and sent with one vectored write would beat `std.Io.Writer.Allocating` for a JSON answer of a few kilobytes".

What was compared, all through the real `json.write` into a `*std.Io.Writer`: **A** is `sendJson`'s writer (`Allocating.initCapacity(arena, 512)`, growing); **B** is a prototype `Segments` writer (a `std.Io.Writer` whose buffer is an arena segment, sealed when full, 512 bytes doubling to 4,096, the segments being the iovecs of one `writev`); **C** is the same with 4,096-byte segments throughout. The bytes of B and C are checked equal to A's before anything is timed. The arena is a `std.heap.ArenaAllocator` reset after every request with `retain_with_limit = 16 KiB` (`default_arena_keep`), over a counting allocator. Answers: 7, 31 and 126 items of about 135 bytes, 952, 4,212 and 17,116 bytes of JSON (the nearest whole items to 1, 4 and 16 KiB). Instructions are the user-space `INSTRUCTIONS` counter through `perf_event_open`, because cachegrind is not installed here. Three variants interleaved, order rotated each round, 21 rounds of 5,000 requests, the first round of each discarded as warm-up; times are the minimum round and the median round. Run twice at the default keep and once at `--keep 65536`.

| answer | keep | variant | ns a request (min, median) | instructions a request | backing bytes a request |
|---|---|---|---|---|---|
| 952 B | 16 KiB | A | 582, 601 | 17,788 | 0 |
| | | B | 600, 612 | 18,097 | 0 |
| | | C | 591, 602 | 17,842 | 0 |
| 4,212 B | 16 KiB | A | 2,705, 2,724 | 78,062 | 0 |
| | | B | 2,712, 2,731 | 78,459 | 0 |
| | | C | 2,685, 2,702 | 77,958 | 0 |
| 17,116 B | 16 KiB | A | 14,223, 14,750 | 317,780 | 54,392 |
| | | B | 10,744, 10,991 | 315,808 | 0 |
| | | C | 10,554, 10,943 | 315,382 | 0 |
| 17,116 B | 64 KiB | A | 10,556, 10,715 | 314,909 | 0 |
| | | B | 10,520, 10,704 | 315,659 | 0 |
| | | C | 10,535, 10,644 | 315,147 | 0 |

Adding the one `writev` of head and body to `/dev/null` moves every row by the same 60 to 100 ns whichever variant, and the order of the three does not change (the full output is reproducible with the command in the program's header).

**Segments do not win.** At 1 and 4 KiB the three are within 1 to 3% of each other on time (inside the spread of a round, 2 to 12%) and within 1% on instructions, where B and C are not below A but a few hundred above or below it. At 17 KiB with the default keep the segments are 24 to 26% faster, and **that is not the segments**: at `--keep 65536` the three are equal (10.52 to 10.56 us, 314,909 to 315,659 instructions). What the 24% is, is that A's growth leaves a 17 KB answer using 54 KB of arena (the buffer at each size it passed through), more than the 16 KiB the arena keeps, so each request gives the excess back and asks the backing allocator for it again (2 calls and 54,392 bytes a request); the segments are many small blocks that the reset keeps within the limit (0 backing bytes a request), so they ask for nothing. Why that holds for 17 KB of segments and not for A's buffer was not chased further. The copy the todo entry feared is not in the numbers: the instruction counts of A and B differ by under 1% at every size, which is where the memcpy of a grow would show (the likely reason is that `Allocating`'s buffer is the arena's last allocation and grows in place, which was inferred and not checked).

**The decision it moved:** segments are not built. They would cost the contiguous body that everything after `sendJson` wants (`deliverWhole`'s compression, `holdWhole` for a middleware that holds the answer, HEAD, ETag, `kept`, and `sendOwned(…, out.written())` in `typed.zig`, `ownbody.zig` and `profile.zig`), for a saving the measurement does not find. What the run found instead is that **an answer larger than `arena_keep` costs a request 54 KB of backing allocation and about a quarter of its time**, and the cheaper levers for that are not segments: a size hint per route (the length of its last answer, so `initCapacity` is right the second time) or an `arena_keep` the answer fits in. Neither was measured here and neither is claimed.

**Can it be pushed further:** B and C differ from A by less than the spread everywhere the arena is not over its limit, so a better segment writer cannot turn it around; the open question is the one above, and it wants a run through the server (`bench/main.zig` with a 17 KB route) rather than this in-process one, because the backing allocator here is `smp_allocator` and the server's is whatever the App was given.

## A connection is never ended by the server: executor imbalance that lasts, and a cap on requests (ADR 275)

**What was run.** `bench/keepalive_server.zig` (every answer names the OS thread; `/work/:us` spins for a given time) and `bench/keepalive.py` (opens connections in a stated order, keeps them, reads each executor thread's CPU from `/proc/<pid>/task/<tid>/stat` per window). Busy connections ask `/work/400` every 2 ms (about 15% of a core each); quiet ones ask `/tid` every 10 s. Windows are 15 s of a 45 s run.

**Machine.** AMD Ryzen 7 9700X, 8 cores, 16 threads. Server pinned to cores 0 to 3 (four executors), client to cores 4 to 7, ReleaseFast, loopback. Commit c4e2d08 plus the diff for ADR 275.

**Without a cap, the imbalance is dealt on day one and does not move.** Hottest executor over the mean, the same in all three windows of each run:

| plan (B busy, I quiet, in opening order) | hottest / mean |
|---|---|
| `BBBBIIIIIIIIIIII` | 1.00 |
| `BIIIBIIIBIIIBIII` (strided) | 4.00 (all four busy on one executor, the other three at 0.0%) |
| six random orders of 4 B and 12 I | 1.99, 2.00, 2.00, 2.96, 2.99, 2.99 |
| three random orders of 16 B and 48 I, 8 ms apart | 1.74, 1.50, 1.50 |

The dealing is round-robin by arrival (`getNextExecutor`), so it is even in count; it is uneven in load whenever the busy ones are few.

**With `max_requests_per_connection = 1000`** (a busy connection reconnects about every 2 s here): strided 4.00 becomes 1.58, 1.03, 1.01 across the three windows; seed 2 from 3.00 becomes 1.33, 1.01, 1.00; seed 4 from 3.00 becomes 1.32, 1.01, 1.01; the 16-in-64 runs from 1.74, 1.50, 1.50 become 1.41/1.02/1.01, 1.28/1.00/1.02 and 1.28/1.02/1.01. The first window carries the first 2 s before any connection has been dealt again.

**Latency when the hot executor saturates** (400 us of work every 1 ms, three busy connections on one executor): uncapped p50 0.46, 0.82, 0.82 ms with 78,158 requests in 45 s and 70% of the server's four cores; capped p50 0.43 ms in all windows with 110,260 requests and 97 to 99%. p99 is noise between 0.5 and 3 ms in both and is not claimed: a capped run puts one busy connection on every executor, and each wakes from park.

**Two instances, 2 executors each, the second added to the rotation at 15 s** (8 busy and 24 quiet connections): uncapped, the second instance took 0.0% CPU and no connection in all three windows, the first held both executors at 56 to 59% each. Capped: window 2 split 61% / 51% and window 3 55% / 56% (busy 2+2 and 2+2). The 24 quiet connections stayed on the first instance for the whole run, as they would: at one request in ten seconds a count of a thousand is hours away. They carry no load.

**What it costs.** Server CPU per request on the cheapest route (32 busy connections back to back, 10 s, three runs each): cap 0 gives 2.50, 2.44, 2.43 us; cap 2 gives 5.74, 5.67, 5.56; cap 1 gives 8.60, 8.66, 8.72. A connection therefore costs about 6.3 us, so one per thousand requests is 0.26% of a request. A first attempt at cap 1000 against cap 0 for 15 s read between +10% and +60% and was noise from the Python client (the runs that disagreed with the cap 1 and cap 2 figures); the per-connection cost above is the figure to use. No wrk or oha is installed here, so this is CPU per request and never req/s, as ADR 242 prefers.

**Memory and size.** `bench/mem.py` against `nilo-hello`, three interleaved pairs, before and after: 4,731 / 4,704 / 4,684 / 4,678 bytes per connection at 1,000 / 2,000 / 5,000 / 10,000, identical to the byte in all six runs. `park-check` reads one page for the default build, `-Dhttp2`, `-Dtls` and `-Dtls -Dhttp2`. Stripped `nilo-hello`: 918,552 before, 918,880 after (+328 bytes).

**Decision.** Build it: a cap of 1,000 requests, jittered by a tenth, on by default. Age was not built: the quiet connections it would move carry no load. **Can the number be pushed further?** The 6.3 us a connection costs is accept, spawn, and the first request's cold pages; a smaller default than 1,000 would cost 2.6% at 100 and is not wanted. An age cap for quiet connections is open if a balancer that balances connection counts needs it.

## The arena's HTTP/2 profiles: work stealing, the request cap, and where nilo stands against the framework league's leader

Run on 2026-10-09, AMD Ryzen 7 9700X (8 cores, 16 threads), Linux 7.2.5, Zig 0.17.0. The arena entry of [HttpArena PR 1539](https://github.com/MDA2AV/HttpArena/pull/1539) built as the board builds it (`zig build -Dtarget=x86_64-linux-musl -Dcpu=x86_64_v3+aes+pclmul --release=fast`) in three variants: **steal**, the PR as submitted (`zio_options.scheduling = .work_stealing`, nilo `c4e2d08`); **pinned**, the same with that line removed; **main**, pinned against this working tree (`01ca862` plus the uncommitted changes of ADR 272 to 275) with `.max_requests_per_connection = 0`. The control is the board's swerver entry (first in the framework league's HTTP/2 composite), its own Dockerfile, `--network host`. Server on cpus 0-3,8-11 (four physical cores), the board's `h2load` image on 4-7,12-15, the board's own arguments per profile (`-m 100` for the baselines and gRPC, `-m 32` for static and JSON, `-t 8`), 5 s, the board's data and certificate mounted. CPU per request is the server's user and system time over the run divided by requests answered.

**Work stealing is what put the board's HTTP/2 numbers at the bottom.** The board read baseline-h2c 235k to 315k at about 6,000% CPU and 2 to 7 GiB, and unary-grpc 247k to 335k, last of sixteen. Two interleaved rounds here:

| profile | c | pinned req/s | steal req/s | pinned peak | steal peak |
|---|---|---|---|---|---|
| baseline-h2c | 256 | 1.44M | 0.66M | 65 MB | 370 MB |
| baseline-h2c | 1,024 | 1.53M, 2.94M | 1.14M, 1.19M | 47 to 53 MB | 1.47 to 1.48 GB |
| baseline-h2c | 4,096 | 2.86M, 2.87M | 0.86M, 0.99M | 216 to 227 MB | 5.88 to 5.92 GB |
| unary-grpc | 256 | 1.41M, 1.42M | 1.08M, 1.15M | 416 to 429 MB | 427 to 438 MB |
| unary-grpc | 1,024 | 1.29M, 1.29M | 1.05M, 1.07M | 842 to 848 MB | 1.75 to 1.81 GB |
| json-h2c | 1,024 | 667k, 671k | 539k, 537k | 237 to 251 MB | 713 to 722 MB |

Under `.work_stealing` zio refuses `spawnInto(.local)`, and the engine's fallback spawns a stream's call anywhere, so a connection's calls run on other executors and pile up there: the 5.9 GB at 4,096 connections is the board's 7.4 GiB. The `async-db` reason the override was put in for did not hold either (66k at 755% against 57k before, with dusty at 290k), so the override comes out of the entry.

**The request cap of ADR 275 at its default takes `h2load` down.** main as built with the default 1,000 read 195k req/s at 1,024 connections with 92,729 of 1,065,799 requests errored: a GOAWAY after a thousand requests refuses the streams `h2load` already opened above the last one named, and `h2load` does not open a new connection in a timed run. With the cap at 0, main reads 2.99M against pinned's 2.96M, the same.

**Against the control** (one round each, main with the cap at 0):

| profile | c | swerver req/s | nilo req/s | swerver µs CPU a request | nilo µs CPU a request | swerver peak | nilo peak |
|---|---|---|---|---|---|---|---|
| baseline-h2c | 1,024 | 6.03M | 2.99M | 1.24 | 2.44 | 916 MB | 47 MB |
| baseline-h2c | 4,096 | 5.61M | 2.90M | 1.30 | 2.55 | 2.6 GB | 215 MB |
| baseline-h2 (TLS) | 1,024 | 2.08M | 2.36M | 3.09 | 3.05 | 972 MB | 169 MB |
| static-h2 (TLS) | 256 | 703k | 106k | 9.26 | 44.29 | 516 MB | 182 MB |
| json-h2c | 1,024 | 1.73M | 680k | 4.51 | 10.16 | 912 MB | 240 MB |

Over TLS nilo is already ahead. Cleartext, it spends twice the CPU a request; JSON, 2.3 times; static, 4.8 times, because the entry serves `/data/static` with `.reload` (an open, a stat and a read per request, and no compressed form) since the board's rule is that a cache must follow the disk, and nilo's held files do not.

**What it decided.** The override leaves the entry and the entry sets the cap to 0 until the cap's HTTP/2 behaviour is settled. Three pieces of work follow, each measured against this table: a held static file that follows the disk, a request on HTTP/2 that does not cost twice the leader's, and JSON. Projected onto the board by these ratios, nilo would sit about seventh in the framework league's HTTP/2 composite; third needs static near swerver's, baseline-h2c at about 75% of its, and json-h2c at about two thirds.

## Where the arena's json-h2c profile spends 10 us a request, and what a JSON answer written once takes off (ADR 278)

**What was run.** The arena entry (`base`: PR 1539's entry with the `.work_stealing` override removed and `.max_requests_per_connection = 0`, built against `01ca862` plus the uncommitted work of ADR 272 to 275, never rebuilt) against the same entry built against this tree plus the diff of ADR 278 (`jp`), through the rig in `scratchpad/ab` (`run.sh`: server on cpus 0-3,8-11, the board's `h2load` image on 4-7,12-15, `-i json-h2c-uris.txt -p h2c -m 32 -t 8`, 5 s, 1,024 connections unless said). µs of server CPU a request is the server's `utime + stime` over requests answered; req/s is not quoted because other agents were compiling on the same machine and it moved 400k to 780k between runs of one binary. Profiles by sampling: the entry built unstripped, `gdb -p` attached 60 to 80 times a run with `thread apply all bt`, threads parked in `io_uring_enter` or in the thread pool dropped (`prof.sh`, `an.py`; `ptrace_scope` is 1, so the server is launched by a small script that sets `PR_SET_PTRACER_ANY`). The in-process figure is `bench/json_listing.zig`: the 50-item dataset's shape, the seven counts the board rotates through, 3,719 bytes on average, instructions from `perf_event_open` user-space, minimum and median of 21 rounds of 5,000 requests. AMD Ryzen 7 9700X, Linux 7.2.5, Zig 0.17.0.

**The contract.** `site/content/docs/test-profiles/h2/json-h2c/implementation.md`: `GET /json/{count}?m={multiplier}` answers the first `count` of 50 dataset items, each with `total = price * quantity * m`, in `{items, count}`, as `application/json`, serialised per request; counts 1, 5, 10, 15, 25, 40, 50. The entry's handler (`jsonItems`, `base/src/main.zig`) does that and nothing else: it reads the dataset once, copies `count` items into the arena with the derived field, and returns the struct; the framework serialises it. It does no work the contract does not ask for, and nothing in this change rearranges it.

**Where the 10.2 us goes** (base, 1,024 connections, `-m 32`; a plain `/baseline2` costs 2.45 us on the same rig, so about 7.7 us is the route). Of the samples that were not an idle thread, about 430 to 560 over 60 to 80 attaches, shares rounded:

| what | share of samples |
|---|---|
| `__munmap` + `__mmap`, from `ArenaAllocator.reset` in `h2conn.Stream.recycle` and from the arena growing under the answer's writer | 20% |
| `memcpy` (the runtime's, `copyBlocks`/`copyFixedLength`), most of it the writer's, and page-faulted pages of the fresh mappings | 12% |
| the JSON writer itself (`nextEscape`, `writeEscaped`, `utf8ValidateSlice`, `printIntAny`, `Writer.write`, `writeByte`) | about 17% |
| task spawn per request (`StackPool.acquire`/`release`, mutex), `serveRequest`, hpack, `h2conn` | the rest |

The user:system split of the server's CPU time was 60:40. Written down because it was the premise to check: the `mmap` is not the answer's size. An arena node that cannot grow is replaced by one 1.5 times the previous node plus the request, the stream's arena keeps `spare_arena_keep` = 4,096 bytes between requests, and a request that allocates the handler's items (up to 5.6 KB), the answer's buffer and its doublings reaches nodes past 32 KiB, which `SmpAllocator` does not serve from its slabs. It reproduces in neither of the in-process runs: `bench/json_listing.zig` with one arena kept at 4,096, with the seven counts in rotation and with the items copied in, shows no backing allocation, because its arena grows once and one stream sees every size.

**The in-process writer.** `bench/json_listing.zig`, `taskset -c 5`, ReleaseFast:

| | ns a request (min) | instructions |
|---|---|---|
| before (`Allocating`, field-at-a-time writer) | 1,452 to 1,533 | 47,900 |
| scalar fields as one reservation (key literal, digit pairs, plain ASCII in one copy) | 623 | 23,100 |
| and the runtime's `memcpy` replaced by overlapped moves for short text | 586 | 21,000 |

**Through the rig**, three interleaved pairs, µs of server CPU a request at 1,024 connections:

| | base | ADR 278 |
|---|---|---|
| buffer only (before the writer change), three pairs | 10.93, 11.04, 10.80 | 10.42, 10.34, 10.36 |
| buffer and writer, run 1 | 10.44, 10.03, 10.59 | 7.71, 7.98, 8.14 |
| buffer and writer, run 2 (a loaded machine) | 10.57, 10.84 | 8.52, 8.83 |
| buffer and writer, run 3 | 10.15, 10.81, 10.88 | 8.62, 8.37, 8.59 |
| 4,096 connections, one pair | 11.32 | 9.20 |
| `/baseline2` h2c, 1,024, one pair (control, no JSON) | 3.20 | 2.79 (noise: nothing under it changed) |

So the buffer is worth about 0.5 us (-4.5%) and the writer about 2 us. `h2load` reported 0 failed, 0 errored, 0 timeout in every run.

**What a bigger arena keep would take off, measured in a scratch copy of the tree and not in the tree** (`spare_arena_keep` in `http/h2conn.zig` set to 32,768 in a copy under the scratchpad; the worktree's `h2conn.zig` is untouched, it belongs to the HTTP/2 scheduling change): base with the keep alone, 10.24, 10.10 to 7.91, 7.96 us; ADR 278 plus the keep, 7.08, 6.75, 6.90 us against base 10.57 to 10.84 in the same round, peak memory 124 to 182 MB against 224 to 286. The sampling of that build has `__munmap` at 1% and the task spawn's mutex as the largest line that is not JSON. That is a decision about memory held by busy connections (every pooled stream keeps its arena, up to 32 of them a connection) that was not measured here and not taken; the number is for whoever takes it.

**Tried and lost.** `json_hint` of 16,384 instead of 512: 12.94, 13.04 us against 10.34, 10.13 (every request then asks a 4 KiB-keeping arena for a 16 KiB node, and gives it back).

**The decision it moved.** Build ADR 278: the answer is written once in a buffer the thread keeps and copied once, and scalars are written a field at a time as one reservation. `zig build test-http` passes, with new tests that every string length 0 to 80 with each special byte at each position, every integer width at both ends, bools, enums and lists of them, and writers with buffers of 0, 1, 7, 24 and 64 bytes produce exactly `std.json`'s bytes. It does not reach the leader: ADR 278 plus the keep is 6.8 to 7.1 us against swerver's 4.5, and the remaining difference is the per-request task spawn (`StackPool` mutex, about 10% of samples) and the 2.45 us a plain HTTP/2 request costs.

**Can it be pushed further.** The writer is at about 21,000 instructions for 3.7 KB, 5.6 a byte, of which a share is the 16 fields of an item each paying a reservation check; a writer that reserves an item's worst-case size once and writes unchecked would roughly halve it again, at the price of a worst-case bound per type that `covers` would have to compute (strings have none), so it was not built. Non-ASCII text still takes `utf8ValidateSlice` and `nextEscape`, two passes.

## A GOAWAY ends an h2load run, and `Connection: close` does not

**What was run.** `a94221f`, 2026-10-09, AMD Ryzen 7 9700X, Linux 7.2.5, Zig 0.17.0. `zig build examples -Dhttp2 -Doptimize=ReleaseFast`, `example-hello` on 127.0.0.1:8787 (16 threads, the logger on), with one cap for both protocols at its default of 1,000 as ADR 275 first shipped it. The board's load generators from their images, `--network host`, not pinned: `h2load` (nghttp2 1.59.0) and `wrk`.

| client | command | requests started | succeeded | failed |
|---|---|---|---|---|
| h2load, HTTP/2 | `-c 16 -m 32 -t 4 -n 200000` | 15,392 | 15,376 | 184,624 |
| h2load, HTTP/1.1 | `--h1 -c 16 -t 4 -n 100000` | 100,000 | 100,000 | 0 |
| wrk, HTTP/1.1 | `-c 16 -t 4 -d 3s` | 655,859 | 655,859 | 0 |

h2load opens its connections once: each one took its GOAWAY after 900 to 1,000 calls (16 connections, 15,392 started) and every request it had left was counted failed. After `Connection: close` both tools open another connection. The arena rig showed the same first ([the section above](#the-arenas-http2-profiles-work-stealing-the-request-cap-and-where-nilo-stands-against-the-framework-leagues-leader): 195k req/s, 92,729 errored).

**What it moved.** ADR 275's cap counts HTTP/1.1 only, and the HTTP/2 one is its own option, `max_requests_per_h2_connection`, off by default. Not a throughput figure: the logger was on and nothing was pinned, and the question was only whether the run survives.

## A call to a route that never waits runs on its connection's fiber

Run on 2026-10-09, AMD Ryzen 7 9700X, Linux 7.2.5, Zig 0.17.0. The arena rig of the section above: the entry of HttpArena PR 1539 (no `.work_stealing`, `max_requests_per_connection = 0`) built as the board builds it, server on cpus 0-3,8-11, the board's `h2load` on 4-7,12-15 with its own arguments (`-m 100`, `-t 8`, 5 s), µs being the server's user and system time over the run divided by requests answered. **base** is the tree this work started from (`01ca862` plus the uncommitted work of ADR 272 to 275), **after** is that plus the design of [ADR 260](../../docs/adr/260-a-request-on-http2-runs-from-its-headers.md): a call to a route known never to wait (`typed.knownNotToWait`: here `baselineGet` and the gRPC `getSum`, whose arguments are a query and a message) runs on the connection's fiber once its stream has ended, held for that when its message is still to come, and the stream arena keeps 32 KiB where it kept 4 KiB. Runs interleaved, base then after, each under the rig's lock. The entry was not changed: `baselinePost` and the JSON route take a `*Ctx` and keep their fibers.

| profile | c | base µs a request | after µs a request | base req/s | after req/s |
|---|---|---|---|---|---|
| baseline-h2c | 256 | 2.29, 2.31 | 1.22, 1.22 | 3.19M, 3.23M | 6.43M, 6.23M |
| baseline-h2c | 1,024 | 2.50, 2.60, 2.47, 2.71, 2.48, 2.46 | 1.25, 1.28, 1.29, 1.27, 1.27, 1.22 | 2.77M to 2.97M | 5.16M to 5.98M |
| baseline-h2c | 4,096 | 2.55, 2.62 | 1.33, 1.29 | 2.82M, 2.90M | 5.33M, 5.71M |
| baseline-h2 (TLS) | 1,024 | 3.03, 2.99 | 1.52, 1.50 | 2.40M | 4.56M, 4.62M |
| unary-grpc | 256 | 5.74, 5.57, 5.44, 5.61, 5.83 | 2.44, 2.41, 2.47, 2.54 | 1.2M to 1.4M | 3.0M to 3.2M |
| unary-grpc | 1,024 | 5.86, 6.04, 6.15, 6.16, 6.20 | 2.80, 2.75, 2.67, 2.80 | 1.17M to 1.30M | 2.65M to 2.83M |
| json-h2c (`*Ctx`, fiber) | 1,024 | 10.02, 10.10, 10.18 | 7.98, 7.96, 8.04 | 680k to 689k | 876k to 884k |

The leader's recorded figures on this box are 1.24 µs (1,024 connections) and 1.30 (4,096) for baseline-h2c and 3.09 for baseline-h2: after, nilo is level with it cleartext and ahead of it over TLS. The JSON row moved only through the arena change, not the inline run: **an HTTP/2 stream's arena kept 4 KiB, so any answer that grew it past the allocator's 32 KiB slab limit unmapped a node every request** (the lead's gdb sampling: about 20% of the busy samples of json-h2c in mmap and munmap); with 32 KiB kept the row went from 10.1 to 8.0 µs, and the peak fell from 230 to 300 MB to 167 to 181 MB.

**The first version held no call: it ran only a call whose stream had ended when its headers did, or whose next frame was its DATA.** gRPC did not move (5.7 µs), because h2load writes the HEADERS frames of its hundred streams first and their DATA behind them; the debugging print showed the next frame at every HEADERS to be another HEADERS. Holding the call until the frame that ends it is read (`Conn.holds`), and giving a fiber to the held ones before the connection waits (`Conn.startHeld`), took gRPC to 2.4 µs.

**The four axes.** Allocations a request: none added (the held call is in the stream, the answer is written from the connection's fiber with no queue, no lock, no waker post). Memory per idle connection, `bench/mem.py --h2 --get` on the arena entry's 8082, 1,000 and 10,000 connections, two rounds each: base 9,276 and 9,202 bytes at 10,000, after 9,302 and 9,192; `park-check` reads one page for every connection. A busy connection's spare streams (up to 100, dropped when the connection has nothing in flight) now keep up to 32 KiB of arena each rather than 4 KiB, but only what a call actually used: the peak RSS of json-h2c at 1,024 connections is lower, not higher. Throughput and p99: the table; no latency percentile was taken, only the rows.

**What is left.** baseline-h2c is at the leader's number, so the head rebuilt and reparsed (about 90 ns of 810 in process, the earlier bound) and the clock reads were not taken: the case for them is gone at this figure. unary-grpc at 2.4 µs is the largest remaining gap (the 123 ns HPACK decode of its larger header block, the envelope, the trailers frame), and the board's unary-grpc leader is not measured here. The write path was not counted: a burst answered from the connection's fiber is flushed once when the buffer empties.

**The decision it moved:** ADR 260 (a route known never to wait runs where its call arrives; the refusal of running on the connection's fiber now says "whatever its route does"). The connection stalls once for a promise that is wrong, which `grpc_live.zig` holds ("a route promised never to wait that does is named, and from then on gets a fiber"). **Can it be pushed further:** a `*Ctx` route outside the promise (`baselinePost`, the JSON route) keeps its fiber and its 9.5% spawn share; a per-executor stack cache in the Engine is the next place for them.

## What moving the WebSocket frame into Core costs the server

Run on 2026-10-09, AMD Ryzen 7 9700X (8 cores, 16 threads), Linux 7.2.5, Zig 0.17.0, at `0f6a939` against `0f6a939` plus the change that moves the frame code from `http/websocket.zig` to `core/ws_frame.zig` so that `nilo_fetch`'s WebSocket client can use it ([ADR 281](../../docs/adr/281-nilo-fetch-opens-a-websocket-and-the-framing-is-core.md)). The before is `git archive 0f6a939` in a scratch directory, built with the same flags the same afternoon (`zig build autobahn-server -Dtarget=x86_64-linux-gnu -Dstrip=false`, which is `ReleaseFast`), and the server is `bench/autobahn/server.zig`, the echo loop out of the guide with `max_message` raised.

**The question.** The masking loop (ADR 046: 2.4 times a single 32-byte tile on a 16 KiB message) is the one hot loop here, and it moved to another file. Zig compiles the modules as one unit and inlines across them, so the expectation was no change; that is an expectation and not a measurement.

**Machine code.** `unmaskInto` (152 instructions), `readPayload` (91) and `handleControl` (269) disassemble to the same instructions in both binaries, address operands aside (`objdump -d`, diffed after normalising addresses: 0 differing lines each). The connection loop that inlines `receive` (`websocket.runner…call`) is not the same: 798 instructions before, 847 after, and 0xd34 against 0xe17 bytes. The register allocation moved, and the header checks, now one function (`Frame.wellFormed`) instead of four `if`s in a row, are laid out differently. That is why the next two are measured and not argued.

**User instructions an echoed message**, read from a hardware counter (`perf_event_open`, user mode, inherited by the server's threads, read at exit; two counts of messages per run and the difference over the difference, so start, handshake and stop come out, as `bench/release.py` does with cachegrind, which this host lacks). One client on a pinned core, the server on another, a window of 32 messages in flight. Four interleaved runs of each:

| message | before | after |
|---|---|---|
| 40 bytes | 683.7, 683.7, 683.7, 683.7 | 683.9, 683.9, 683.9, 683.9 |
| 16 KiB | 8,596.9 to 8,599.3 | 8,596.5 to 8,597.6 |

The 40-byte rows differ by 0.2 instructions in 684, and the 16 KiB ranges overlap. **Unchanged.**

**The server's CPU a message** (the schedstat of the server's threads over the measured stretch, 3,000,000 messages of 40 bytes and 300,000 of 16 KiB, five interleaved runs each; the client is Python, so this is the server's CPU and the rate is the client's): 40 bytes, 0.165 to 0.190 µs before and 0.160 to 0.181 after; 16 KiB, 2.60 to 3.53 µs before and 2.51 to 2.72 after. The ranges overlap. **Unchanged.**

**Memory per idle WebSocket** (`bench/ws_idle.py nilo ws-room`, `bench/ws_server.zig`, ReleaseFast, marginal at 2,000 sockets, three interleaved pairs from freshly started servers): before 5,181, 5,186 and 5,186 bytes a socket, after 5,186, 5,186 and 5,186. **Unchanged.** A first single reading had 5,186 against 5,190, which the interleaved pairs show to be the spread. `zig build park-check` on the changed tree reads one page in all four builds (0 of 48 connections above it).

**Binary.** `.text` of the echo server is 1,212,963 bytes before and 1,213,187 after (+224 bytes, the connection loop above).

**What it decided.** The move stands: one copy of the framing in Core. Nothing here is a reason to keep a second one in the server. The Autobahn suite (`bash bench/autobahn/run.sh`) on the changed tree reads as it did before the move: 301 cases, 294 OK, the four 6.4.x NON-STRICT and the three 9.x INFORMATIONAL, 0 failed. The framing tests in `http/websocket.zig` (every one that was not a pure table of bytes, which went to `core/ws_frame.zig` with the code) pass in Debug and ReleaseSafe.

## A static directory that follows the disk

**What was run.** The HttpArena rig of the entry above, static-h2 (TLS, 20 files with `.br` and `.gz` twins, `Accept-Encoding: br;q=1, gzip;q=0.8`, `-m 32`), at 256 and 1,024 connections, `h2load` under `flock bench.lock`, interleaved runs of three builds of one tree (HEAD `01ca862` plus the uncommitted work of the unreleased tree and the ADR 277 diff): `base` (the entry as it was, `.reload`), `sdisk` (held, no `.reload`, not following: the lower bound a follower can approach) and `sfollow` (`.{ .follow = true }`, the one-line change in the entry's `src/main.zig`). Machine: the one above, load average 24 to 66 from other builds during the runs, so the figure is server CPU microseconds a request, not req/s.

| connections | `base` (`.reload`) | `sdisk` (held, stale) | `sfollow` | h2c control (same files) |
|---|---|---|---|---|
| 256 | 44.3 to 52.6 µs | 22.7 to 23.2 | 22.8 to 23.4 | 8.7 |
| 1,024 | 51.7 to 53.9 | not run | 28.3 to 28.9 | not run |

**The validator** (`static_staleness_probe` by hand: replace a file and its twins with same-length bytes, wait, read) passed in five cases, the board's order among them, answering the new bytes after 111 to 219 ms. Idle connections: `bench/mem.py --h2`, marginal 8,687 bytes a connection for `base` and `sfollow`; `park-check` unchanged. Binary, stripped `ReleaseFast`: 2,572,688 (`sdisk`) to 2,598,720 (`sfollow`) bytes.

**Where the rest of the gap is.** `sfollow` is half of `base` and 2.5 times swerver's 9.26 µs. The h2c control with the same files costs 8.7 µs, so what is left is TLS: the average body is 15.9 KB, and std's AES-GCM runs at about 2.1 GB/s alone and about 1.1 GB/s a thread with an SMT sibling busy, which is about 14 µs of the 22.8. tls.zig writes two records a DATA frame (a short header record and the payload) and copies the cleartext into the record buffer before encrypting in place; neither is the larger part (wider AES features were tried in `gcm.zig`, a microbench, and did not move it). That is an AEAD in the pinned tls.zig fork, not in static, and not changed here.

**The decision it moved.** The entry serves `/data/static` with `.follow = true` and drops `.reload`; ADR 277 is the design; the default stays off. **Can it be pushed further:** the TLS cost above is the whole remaining difference to the leader, and a faster AES-GCM in tls.zig is the lever; keeping unchanged files between generations (not needed for 1.7 MB) matters only for trees of tens of megabytes.

## The arena's HTTP/2 profiles with the three changes together

Run on 2026-10-09, the rig of [the section above](#the-arenas-http2-profiles-work-stealing-the-request-cap-and-where-nilo-stands-against-the-framework-leagues-leader), at `c416e35` plus the working tree: ADR 260 revised (a route known never to wait runs on its connection's fiber), ADR 278 (the JSON answer written once) and ADR 277 (`.follow`). The entry as in that section, plus three lines a dependent would write: `staticWith(..., .{ .follow = true })` in place of `.reload`, `pub const nilo_never_waits = true` on the in-memory `Dataset`, and the JSON route taking `arena: std.mem.Allocator` in place of a `*Ctx` it used only for its arena. One round, swerver then nilo per row.

| profile | c | swerver req/s | nilo req/s | swerver µs a request | nilo µs a request | swerver peak | nilo peak |
|---|---|---|---|---|---|---|---|
| baseline-h2 (TLS) | 256 | 2.11M | 5.35M | 3.05 | 1.44 | 501 MB | 51 MB |
| baseline-h2 (TLS) | 1,024 | 2.09M | 4.89M | 3.09 | 1.58 | 983 MB | 138 MB |
| static-h2 (TLS) | 256 | 714k | 337k | 9.13 | 22.50 | 531 MB | 167 MB |
| static-h2 (TLS) | 1,024 | 705k | 271k | 9.28 | 27.55 | 1,027 MB | 232 MB |
| baseline-h2c | 256 | 6.12M | 6.61M | 1.25 | 1.18 | 482 MB | 24 MB |
| baseline-h2c | 1,024 | 5.92M | 5.87M | 1.27 | 1.27 | 906 MB | 50 MB |
| baseline-h2c | 4,096 | 5.20M | 5.39M | 1.28 | 1.31 | 2,495 MB | 124 MB |
| json-h2c | 1,024 | 1.65M | 1.11M | 4.56 | 6.27 | 920 MB | 109 MB |
| json-h2c | 4,096 | 1.63M | 0.90M | 4.77 | 7.73 | 2,561 MB | 270 MB |

**Where static's gap is.** Both servers send 16.4 KB a request (the `.br` forms). AES-GCM is most of the difference: std's `Aes128Gcm` and `Aes256Gcm` encrypt 2.2 GB/s on one core of this machine at the rig's `x86_64_v3+aes+pclmul` (7.4 µs a 16 KiB record), 2.7 to 2.8 GB/s built for `znver2`, the board's CPU, while OpenSSL, which swerver links, reads 27 GB/s here with VAES. The board's Zen 2 has no VAES, so this machine overstates the gap there; how much it closes is not measured.

**What it moved.** Projected onto the board by these ratios against swerver's published numbers, nilo would be second in the framework league's HTTP/2 composite (about 3,000 against swerver's recomputed 3,340 and fib's 2,600), with baseline-h2 setting the league's maximum. The board's own run is the number that counts. **Can it be pushed further:** static-h2 through the cipher (the kernel's AES-GCM by kTLS, which also opens `sendfile` under TLS, or a faster AES-GCM), and json-h2c at 4,096 connections.

## Whether the compressor pool slows down as threads are added

Run on 2026-10-09 on the Ryzen 7 9700X box (eight cores and sixteen threads, cpus 0 to 7 distinct cores and 8 to 15 their siblings), Zig 0.17.0, `ReleaseFast`, at `630e636` plus the working tree. The question came from the HttpArena 64-core board, where `json-comp` costs nilo about 220 µs of server CPU a request against dusty's 164, and on this box with the server on 8 logical cpus the same pair reads 32.6 against 50.7: nilo's cost a request grows about 7 times from 8 to 64 threads and dusty's 3. The suspect was `PoolOf`: all free bits in one `u64`, and a borrow that always takes the lowest.

**The program** is `bench/compress_scale.zig` (`zig build bench-compress-scale -Dtarget=x86_64-linux-gnu -Dlibdeflate -- <dataset.json> --rounds 20000 --gap-ns 20000`). N threads pinned to cpus 0 to N-1 gzip the bodies of `/json/25?m=4`, `/json/40?m=4` and `/json/50?m=4` (4,190, 6,696 and 8,390 bytes, rendered from the board's dataset), rotating, each from its own request arena, in three arrangements: `shared` (one pool of N slots, no hint, so every scan starts at slot 0: the pool as it was), `owned` (the same pool, each thread asking with its own index) and `private` (N pools of one slot, the floor). Counters are the calling thread's user-space `perf_event_open`. `--gap-ns 20000` spins 20 µs between bodies, because a closed loop with no gap lets a thread take slot 0 back the moment it gave it up, which hides the migration; the gap run times only the `gzip` call.

**Without a gap the pool is not the problem:** at 16 threads `shared`, `owned` and `private` read 30,108, 30,092 and 30,086 ns a body for libdeflate (14,340 at one thread), and 54,884, 55,303 and 55,018 for the standard library. The growth from 1 to 16 threads is 2.1 times for both backends and for the compressor each thread owns: the 8 SMT siblings and the clock, not sharing.

**With 20 µs of other work between bodies the migration shows.** libdeflate, ns a body and last-level misses a body, `shared` against `owned` (private within 1% of owned), two runs:

| threads | shared ns | owned ns | shared over owned | shared misses | owned misses |
|---:|---:|---:|---:|---:|---:|
| 1 | 14,256 | 14,294 | 0 | 0.4 | 0.4 |
| 2 | 14,400 | 14,129 | +1.9% | 83.5 | 0.2 |
| 4 | 14,655 | 14,273 | +2.7% | 152.7 | 0.6 |
| 8 | 15,678 | 14,787 | +6.0% | 235.1 | 0.5 |
| 16 | 28,341 | 26,747 | +6.0% | 163.9 | 6.1 |

(second run: +1.7, +2.9, +5.0, +5.1 percent at 2, 4, 8, 16). The standard library's compressor at 8 and 16: 38,712 and 51,196 shared against 38,284 and 50,616 owned, +1.1%. Instructions a body are identical in all three arrangements.

**The fix** (`borrow(hint)`: each slot's free flag on its own cache line, a scan that starts at the executor's own index) reads as `owned` in the table. Through the arena entry on 8 logical cpus (`run1.sh`, jsoncomp, 4,096 connections, `-r 25`, built with `-Dlibdeflate`, `cpool-base` is `630e636` exported, four interleaved pairs under the lock): base 32.23, 32.86, 32.52, 32.62 µs of CPU a request (mean 32.56) against 31.84, 31.77, 31.94, 32.22 (mean 31.94): **-1.9%**, 236,000 to 243,000 req/s. Hard axes: `park-check` unchanged (0 of 48 idle connections over a page), no allocation added (the pool is built once), the flags are 64 bytes a slot.

**The decision it moved.** The pool is revised (ADR 211). **What it does not do: explain the board.** On this box the pool accounts for 0.4 to 1.6 µs of 14 to 27 µs of gzip and about 0.6 of a request's 32 µs, nowhere near the 56 µs between nilo's and dusty's cost a request on the 64-core part. The 7 times growth is not in the compressor at 16 threads, since a compressor each thread owns grows as much. A Threadripper's compressor line crossing a core complex costs more than a line crossing inside one die, which this box cannot show; even ten times the 0.6 would be a tenth of the gap. **Can it be pushed further:** the next suspects, from reading the code, are the two shared words every request writes (`stop.in_flight`, 2 RMWs, on the same line as `stop.requested` which every keep-alive request reads) and the connection-count words, listed with line numbers in the handoff; the section "What the two atomics a request always makes cost, on two cores" above bounds the first at 1 to 2% of a 16-thread machine, from arithmetic and not from a measured 64-thread run. The measurement that would settle the board is a run on the 64-core part with `perf` counting cross-CCX transfers, not another run here.

## A WebSocket frame cost two trips through the loop and three timers

Run on 2026-10-09 on the Ryzen 7 9700X box, Zig 0.17.0, `ReleaseFast`, at `077b4a8` plus the working tree. The server is the HttpArena entry (`frameworks/nilo` of PR 1539, the `/ws` route echoing each message with its opcode) on cpus 0 to 3 and 8 to 11, gcannon 0.5.3 (`--ws -c 512 -t 8 -d 5s`, `-r 10` for `echo-ws-limited`) in Docker on cpus 4 to 7 and 12 to 15, dusty (`ae164fa`, the image PR 1529 ran) in Docker on the server's cpus as the control. µs of server CPU a frame is the figure to trust: another session was compiling on the box, and frames a second moved with it.

**The board said** 3.60M frames a second for nilo at 512 connections and 4.12M for dusty, at 65.3 and 64.0 cores: 18.1 µs of CPU a frame against 15.5. `echo-ws-limited` at 512 was 1.22M at 38 cores against dusty's 2.11M at 65.

**What a frame did.** gdb samples of the busy threads, then `perf record -e cycles:u`, put the loop's timer and wait-group functions (`timedWaitForIoClock`, `setTimer`, `clearTimer`, `lockTimers`, `groupCallback`, `cancelLocal`, `CompletionQueue.waitTimeout`) at about 40% of user cycles. Per frame: the park's poll and its 200 ms peek timer, then the read the poll announced under `armEachRead`'s timer, then the send under the write limit's. dusty's loop is one receive and one send, with no timer on either.

**The park was all of it.** A build with `receive` never parking (measurement only: no posts, no pings, no idle release), three rounds, 512 connections, `echo-ws`: 2.69 to 2.85 µs a frame as shipped, 2.29 to 2.40 without the park, 2.25 to 2.33 for dusty. On `echo-ws-limited` the same build closed about half the distance (5.23 to 5.32, 4.67 to 4.93, 3.98 to 4.32, a noisier hour), the rest being what a connection costs to open and close.

**The change** (ADR 284) keeps the park and makes its peek a receive into the buffer the connection already holds. Three rounds each, interleaved, before, after and dusty:

| profile | before µs | after µs | dusty µs | before frames/s | after | dusty |
|---|---|---|---|---|---|---|
| `echo-ws` | 2.08–2.15 | 1.78–1.83 | 1.61–1.68 | 2.06–2.68M | 2.45–3.00M | 2.65–3.17M |
| `echo-ws-limited` | 3.46–3.53 | 3.05–3.09 | 2.79–2.87 | 1.62–1.72M | 1.87–1.88M | 1.90–1.96M |

A fourth session put the change and the no-park build side by side: 1.84 to 1.86 against 1.81 to 1.83, so the receive gives back what the park cost and keeps what it does.

**Nothing else moved.** h2c at 256 connections, 1.18 to 1.24 µs a request before and after; `json-h2c` at 1,024, 6.67 to 6.94 before and 6.52 to 6.79 after, inside the spread, since one wait there is followed by many frames. Memory per idle connection, `bench/mem.py --path / --steps 1000,2000,4000` against `example-hello` stripped, after, before, after: 4,719, 4,694 to 4,696 and 4,684 bytes at the three steps, the same in all three runs. `bench/ws_idle.py nilo`: 5,177 and 5,186 bytes marginal at 1,000 and 2,000 sockets in a Room, before and after. `park-check` holds one page. Stripped `ReleaseFast`: +1,840 B on `hello`, +1,808 B on `rest`.

**The decision it moved.** ADR 284. **Whether it can be pushed further:** yes, by the two timers left a frame, the peek's and the write's, which are most of the 0.15 µs between nilo and dusty on `echo-ws`, and by what opening and closing a connection costs beyond that: on `echo-ws-limited` nilo is 0.2 to 0.3 µs a frame behind dusty against 0.15 on `echo-ws`, about a microsecond more a connection. Both are in `docs/todo.md`.

## Why the board's HTTP/2 run sat below the rig's projection, and what a burst's writes cost

Run on 2026-10-10, AMD Ryzen 7 9700X, Linux 7.2.5, Zig 0.17.0, a loaded machine (other sessions compiling, load average 5 to 16), so the figures to trust are µs of CPU a request, not req/s. The entry of HttpArena PR 1539 at its board pin (`077b4a8`, pinned scheduling, `max_requests_per_connection = 0`) built as the board builds it, against variants built with `zig build --fork=` on a patched copy of `077b4a8`: **wb64** (the entry's `listen` with `.write_buffer = 64 * 1024`), **nd** (`TCP_NODELAY` set on each accepted socket) and **peek** (`h2conn.idle_peek_ms` 5,000 instead of 200). Server pinned with `taskset`, the board's `h2load` image on cpus 4-7,12-15 with the board's arguments, 5 s. Client CPU is h2load's own user and system time (`times` inside its container) over requests answered. Segment sizes are `ss -ti` `bytes_sent` over `data_segs_out` summed over the server's sockets across one second mid-run.

**The board read lower than the projection** of the section "The arena's HTTP/2 profiles with the three changes together": H2 composite 2,424, fifth in the framework league, against a projected 3,000. Its log says why in two shapes. json-h2c answered 1.10M at 1,024 connections and 1.09M at 4,096, at 1,880 to 2,040% CPU of 6,400: a ceiling that does not move with connections, on an idle server. static-h2 answered 903k at 256 connections and 190k at 1,024 at 6,175% CPU: busy and slow, 4.6 times the CPU a request.

**json-h2c: a response larger than the connection's 4 KiB write buffer leaves as its own write.** At 1,024 connections on four server cpus nilo sent 6.2 KB a TCP segment and swerver 50.8 KB, and h2load spent 3.84 µs of its own CPU a request reading nilo against 1.13 reading swerver. A 4.2 KB answer does not fit the buffer, so `std.Io.Writer` drains it at once rather than at the loop's flush. The frames of one 32-stream burst read with a single client are the same as swerver's (HEADERS then DATA per stream, one read), so it is the writes and not the framing.

| variant | server cpus | c | req/s | server µs a request | client µs a request |
|---|---|---|---|---|---|
| as pinned | 4 | 1,024 | 608k | 5.60 | 3.84 |
| nd | 4 | 1,024 | 612k | 5.63 | 3.94 |
| wb64 | 4 | 1,024 | 943k | 3.97 | 1.60 |
| swerver | 4 | 1,024 | 876k | 4.42 | 1.13 |
| as pinned | 8 | 1,024 / 4,096 | 1.00M / 0.83M | 6.28 / 7.63 | 4.08 / 5.18 |
| wb64 | 8 | 1,024 / 4,096 | 1.57M / 1.61M | 4.51 / 4.56 | 2.07 / 2.18 |
| swerver | 8 | 1,024 / 4,096 | 1.65M / 1.60M | 4.69 / 4.81 | 1.39 / 1.43 |

`TCP_NODELAY` moved nothing: Nagle was the first suspect and is not it (zio sets it on `connect` only, and nilo nowhere). The longest request under wb64 took 1.7 s at 1,024 connections and 5 s at 4,096 (swerver 132 ms); the as-pinned build has the same tail at 4,096 (3.6 s), so it is not the buffer's, and it is unexplained.

**static-h2 on the rig is the cipher, not the connections.** `perf record -e cycles:u` on an unstripped build at 1,024 connections: `ghash_polyval.Hash.blocks` 30.5%, `modes.ctr` 29.3%, GHASH init and `AesGcm.encrypt` 3.5%, `memcpy` 7.3%; 17 to 21% of the server's CPU was system time. µs a request rose 23.3 to 29.5 from 256 to 1,024 connections against swerver's 10.3 to 11.0. Neither wb64 (26.0, 35.2) nor peek (23.0 to 23.5, 28.9 to 30.9, two rounds) moved it, so the idle release of a connection's pages, the suspect from the board's 170 ms request time against a 200 ms peek, is not it here. This machine's OpenSSL has VAES and Zen 2 has not, so the cipher's share of the gap is smaller on the board than here, and the board's collapse at 1,024 connections is not reproduced on eight threads.

**What the rig cannot show, read from the code.** Every request through `serve.serveRequest` makes two read-modify-writes on one process-wide word (`stop.in_flight`, `serve.zig:427`), on the line `stop.requested` is read from by every keep-alive request; and every request that gets a fiber of its own takes zio's one `StackPool` mutex twice (`zio/src/coro/stack_pool.zig`, one pool a runtime). On one CCD both are cheap. On the board's sixteen core complexes they are the shared lines of a request, and nilo's baseline-h2c there costs 6.2 µs of CPU a request against swerver's 3.5 while the rig has them level (1.32 against 1.16 here), and HTTP/2 cleartext and HTTP/1.1 pipelined both stop near 10 to 12M req/s. That is a correlation, not a measurement.

**What it moved.** The composite recomputed from the board's results with nilo's rows replaced: json-h2c at fib-tuned's 2.3M is 2,691 (fourth); at swerver's 4.4M, 3,158 (second); static-h2 at 1,024 connections held at its 256-connection 903k is 2,745 (fourth); both of the first and that, 3,012 (third). A burst's answers leaving in one write is the first piece of work, because the rig shows it at the leader's figure. **Can it be pushed further:** a write buffer of 64 KiB is the experiment, not the design (it is per connection, and allocated past the allocator's slab limit); the design is the burst's DATA written from where it already is, in one vectored write at the loop's flush. The two shared lines need a run on the board's part to settle.

## A burst of HTTP/2 answers leaves in writes of 32 KiB

Run on 2026-10-10, AMD Ryzen 7 9700X, Linux 7.2.5, Zig 0.17.0, the same rig as the section above: the HttpArena entry of PR 1539 built as the board builds it, with `--fork=` on the tree at `d2bf561` (**before**) and on that tree with ADR 285 (**burst**), server pinned to cpus 0-3,8-11 and h2load to 4-7,12-15, five seconds a run, two rounds interleaved before, burst, before, burst. The figure to read is server CPU a request; req/s moves with it here because the server is the side that saturates.

| profile | c | before req/s | before µs a request | burst req/s | burst µs a request |
|---|---|---|---|---|---|
| json-h2c | 1,024 | 1.17M | 5.93 to 5.96 | 1.63M | 4.55 to 4.56 |
| json-h2c | 4,096 | 0.95M | 7.28 to 7.29 | 1.45M to 1.53M | 4.82 to 5.08 |
| h2c (`/baseline2`) | 1,024 | 5.86M to 5.98M | 1.30 to 1.31 | 5.94M to 5.99M | 1.29 to 1.31 |
| h2 over TLS | 1,024 | 4.96M to 4.97M | 1.56 to 1.57 | 4.94M to 4.98M | 1.56 to 1.57 |
| static-h2 | 256 | 334k to 336k | 22.57 to 22.62 | 337k to 339k | 22.40 to 22.52 |
| static-h2 | 1,024 | 276k to 277k | 27.04 to 27.12 | 270k to 271k | 27.64 to 27.70 |
| unary gRPC | 256 | 3.29M | 2.39 | 3.36M to 3.37M | 2.33 to 2.34 |
| unary gRPC | 1,024 | 2.91M to 2.94M | 2.66 to 2.69 | 2.97M to 2.98M | 2.63 |

swerver on the same rig earlier the same day: json-h2c 1.74M at 4.47 µs at 1,024 connections and 1.67M at 4.68 µs at 4,096. The gap on json-h2c went from 31% of server CPU to 2 to 8%. static-h2 at 1,024 connections is 2% slower, outside the spread of the two rounds; it is the one row that went the wrong way, and why is not found: its answers of 1 to 16 KiB take the buffer and pay the copy, but the same copy is a gain on json-h2c.

**Bytes a segment** (`ss -ti` over one second mid-run, json-h2c, 1,024 connections, four server cpus): 6,218 before, 25,271 with the burst; swerver's was 50.8 KB. The writes are 32 KiB, so a segment carries less than swerver's because nilo writes when the buffer fills rather than once a burst.

**Memory per idle connection** (`bench/mem.py --h2 --get --path '/json/1?m=3'`, the entry's h2c port, each connection idle after one 4 KB answer): 9,851, 9,476 and 9,288 bytes at 1,000, 2,000 and 4,000 connections before, 9,847, 9,474 and 9,287 with the burst. The buffer is given back at the flush, so nothing is left behind it. `park-check` passed.

**What was tried and dropped, the same day on the same rig** (one round each unless said): lending each body to one vectored write at the flush instead of copying it, 5.99 to 7.30 µs of server CPU on json-h2c at 1,024 (the stream could not be recycled until the flush, so `ArenaAllocator.reset` went from 0.62% to 8.51% of the profile) while the client's fell; a `write_buffer` of 64 KiB, 4.35 µs against the burst's 4.59 in that round, held by every connection for its whole life and an `mmap` each; a burst buffer of 12 KiB, 6.05 µs; a burst buffer for every answer, which took unary gRPC from 2.37 to 2.70 µs at 256 connections and static-h2 at 1,024 connections from 27.1 to 30.1, and is why only bodies of 1 KiB to under 16 KiB take it.

**What it moved:** ADR 285. **Can it be pushed further:** yes, by writing once a burst rather than once a buffer, which is what swerver's 50.8 KB a segment is; that needs the answers of a burst to outlive the copy, the lending design above, without holding their streams.
