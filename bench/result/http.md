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
[ADR 0086](../../docs/adr/0086-a-response-header-cannot-forge-a-second-one.md)
refuses a response header value carrying `\r`, `\n` or `\0`, and the open choice
was whether to do it in every optimize mode or only in `Debug` and
`ReleaseSafe`. Same harness, same box, commit `a1537a6` as the baseline.

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
end, is where the other 6ns went.

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
