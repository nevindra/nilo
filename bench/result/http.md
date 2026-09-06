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
first row of [ADR 0018](../../docs/adr/0018-the-trade-budget-has-three-axes.md)'s budget
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

| pair | before (`0492be0`) | after (ADR 0071) | after − before |
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

[`history.md`](../../docs/history.md#after-010-what-the-router-scan-actually-costs)
recorded 585ns for the same harness on the machine it was written on, so this
box is about 3.2× faster. The router table moved with it — the mixed set went
from 27/47/56/107/167ns to 13/20/19/38/60ns across 1/5/25/50/100 routes, between
2.1× and 3.0× — and because both halves shrank together, the conclusion drawn
from their ratio survives: 10% of 181ns is 18ns, a 25-route mixed set costs 19ns
to match, and the linear scan still crosses ADR 0001's bar at around 25 to 30
routes. Only the absolute numbers were ever machine-bound.

### The number that reframes the budget

Put the two measurements beside each other. A request costs 181ns of nilo's own
work and **3,902–4,542ns of CPU** once it is actually being served over a
socket. nilo's own code is therefore about **4% of what a request costs.** The
other ~96% is the kernel: `epoll`, `recv`, `send`, and the TCP/IP path — on
loopback, where it is at its cheapest.

That is worth stating plainly next to
[ADR 0001](../../docs/adr/0001-dx-wins-below-the-10-percent-threshold.md), because it
makes the 10% rule more generous than it sounds. Ten percent of nilo's own work
is 18ns, which is **0.4% of the request**. The DX budget was never the thing
standing between this framework and a throughput number.

### What a union in the response was costing

`serialise the body` is 33% of that 181ns, and one shape was paying about three
times what the rest do. `covers` is answered for the **whole** value — one field
the generated writer does not recognise takes the entire struct to `std.json`
with it — and until [ADR 0085](../../docs/adr/0085-a-type-says-how-its-json-is-spelled.md)
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

### What checking every response header costs

Run to settle one question:
[ADR 0087](../../docs/adr/0087-a-header-value-cannot-end-its-own-line.md)
refuses a response header value that can end its own line, and the open choice
was whether to do it in every optimize mode or only in `Debug` and
`ReleaseSafe`. Same harness, same box, commit `a1537a6` as the baseline.

**Measured against a table-driven predicate that did not ship.** This run was
taken on the branch that refused only the six bytes with a consequence; what
merged is ADR 0087's `token` and `field-value` rules, which are a per-byte loop
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

Not a speed measurement. [ADR 0007](../../docs/adr/0007-failure-box-bound-to-the-fiber.md)
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

The third row of [ADR 0018](../../docs/adr/0018-the-trade-budget-has-three-axes.md)'s
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
stays, so nothing here allocates and ADR 0018's per-request invariant is
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
> [ADR 0071](../../docs/adr/0071-where-a-connection-waits-is-what-it-costs.md).

**That is the framework's floor, and the same bug turned out to be alive one
layer down.** Buffer pages stopped being held; *stack* pages never did. A
suspended fiber holds its stack at its high-water mark until the connection
closes, so a handler adds every byte it touches — measured one for one, from
8 KiB to 128 KiB. An ordinary route reading one row and answering JSON holds
**17,022 bytes** per idle connection rather than 8,749, and a handler with a
64 KiB buffer on its stack holds 64 KiB per connection rather than per request.
`bench/sql_server.zig` has the four routes that separate the causes, and
[ADR 0063](../../docs/adr/0063-a-handlers-stack-is-per-connection.md) has the tables.

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

[ADR 0089](../../docs/adr/0089-two-layers-can-each-name-a-vary-axis.md) took
`inline_headers` from six to seven so a gzipped static file behind a named-origin
CORS could carry both `Vary` axes without spilling to the arena. The 32 bytes sit
on `serveRequest`'s frame, which is `noinline` and unwound before the connection
waits, so the reasoning said an idle connection was untouched. **The reasoning was
all there was**: `bench/mem.py` reads `ss` and `/proc/<pid>/VmRSS`, both Linux,
and the change was made on Darwin. ADR 0063 is why that was not left alone — a
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
ADR 0089 argued and what nothing had checked.

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
row in the ADR 0018 table means `bench/main.zig`, and `run-hello` is a different
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
([ADR 0071](../../docs/adr/0071-where-a-connection-waits-is-what-it-costs.md)).

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
keep-alive connection** — the number ADR 0018 carries, and every reading from
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
  byte. [ADR 0063](../../docs/adr/0063-a-handlers-stack-is-per-connection.md)'s
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
  had sent six bytes got nothing in six seconds. The heartbeat ADR 0022 built
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
  gone. ADR 0071 is the same idea: the handler hands the loop back.

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
[ADR 0063](../../docs/adr/0063-a-handlers-stack-is-per-connection.md), which
found a handler holds its stack at its high-water mark, and
[ADR 0071](../../docs/adr/0071-where-a-connection-waits-is-what-it-costs.md),
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
| `/stream/quiet` | the same, exempt from the logger (ADR 0080) | **21,057 B** |
| `/stream/deep` | the same, 32 KiB of handler stack touched first | **53,825 B** |

Marginal met average at every step from 500 up, so all four are converged rather
than a transient.

**A held stream costs 21,058 bytes, and the number the guide used to quote was
right.** 4.5× an idle connection, and the gap is what a suspended handler holds
that a parked connection loop does not: its own frame, its stack at high water,
and the response buffer it has not finished with.

**`/stream/deep` is ADR 0063 again, to the byte.** 53,825 − 21,058 = 32,767,
which is the 32 KiB the handler touched, charged one for one and never given
back, because the frame holding it is live for as long as the stream is. The
arena is cheaper than the stack, on this path as on the others.

### What the logger costs a held stream: nothing, and the fix was already free

`roadmap.md` carried **"the logger puts a kilobyte on a frame that is live while
the handler waits"**, waiting on a number. `logger.with`'s inner `log` declares
`var buf: [1024]u8` and was a plain `fn`, so it was a candidate for inlining
into `run`, whose frame is live across `next.run(c)` — which is exactly the
mistake ADR 0071 §3 found in `handleConnection`, where four unreachable
`std.log.warn` sites were most of 4,184 bytes.

The number says it was not happening. `/stream` against `/stream/quiet` is
**21,058 against 21,057 bytes**: the whole middleware, buffer and all, is inside
the noise of one byte.

And building it both ways says why. `noinline fn log` against `fn log`, both
`ReleaseFast`, produced **byte-identical binaries** — LLVM was already not
inlining it. Three interleaved pairs of the full measurement agree: 21,058 /
21,057, 21,058 / 21,058, 21,057 / 21,057.

**The `noinline` is kept anyway, as a pin rather than a fix.** It costs nothing
today, provably, and ADR 0071 already put the same keyword on seven functions
for the same reason: what the optimiser chooses is not a guarantee, and a
kilobyte reappearing on a live frame is not the kind of regression anybody would
notice.

## The WebSocket against Autobahn

`roadmap.md` carried **"nothing runs the Autobahn suite against the
WebSocket"**, and by
[ADR 0033](../../docs/adr/0033-a-guard-is-not-a-guard-until-it-has-been-seen-to-fail.md)'s
reading that made every close-code and UTF-8 rule in
[ADR 0052](../../docs/adr/0052-a-message-is-copied-once-and-framed-once.md) a
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
[ADR 0098](../../docs/adr/0098-a-completion-the-loop-holds-outlives-the-frame-that-submitted-it.md).
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
[ADR 0100](../../docs/adr/0100-the-route-table-is-the-registry.md) — metrics
ship counting plain atomics rather than a sharded table, on the strength of this
being inside the noise.

**Can this be pushed further?** Not from here. What would settle it is the same
pair on the eight-core box, and the lever if it goes the other way is already
named: shard per executor, pad to 64 bytes, sum at scrape time.

## Binary size

The fourth axis of [ADR 0018](../../docs/adr/0018-the-trade-budget-has-three-axes.md),
and the one this change spends. Stripped `ReleaseFast`, every example rather
than the usual two, against `0492be0` **built from a `git archive` of that
commit into a scratch directory** rather than quoted from the table in
ADR 0018 — the whole reason that rule exists is that the published figure and
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
not `examples/hello`, and it is a different program. **A row in the ADR 0018
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
three lines and it is how ADR 0071 was found, so it is written down here rather
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
[ADR 0101](../../docs/adr/0101-a-request-nobody-else-would-answer-is-refused.md)
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
loop takes over (ADR 0071). This is that reasoning checked.

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
than whatever generic it woke up, which is the mistake ADR 0018 opens with.

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
[ADR 0120](../../docs/adr/0120-a-target-is-read-in-the-form-it-arrived-in.md),
which added a 16-byte `authority` slice to `http1.Request` so an absolute-form
target could be split. `Request` lives in the connection loop's frame and a
fiber holds its stack at its high-water mark
([ADR 0063](../../docs/adr/0063-a-handlers-stack-is-per-connection.md)), so the
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
[ADR 0121](../../docs/adr/0121-a-byte-that-is-not-text-is-not-a-string.md),
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
[ADR 0001](../../docs/adr/0001-dx-wins-below-the-10-percent-threshold.md)'s bar,
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
- **The allocations-per-request invariant**, the second row of ADR 0018's
  budget, which is held by a test rather than by this document.
