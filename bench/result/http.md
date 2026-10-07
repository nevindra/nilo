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
