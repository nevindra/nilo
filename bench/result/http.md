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
| Load generator | wrk 4.2.0, built from source |
| Commit | `a2c344c` |
| Transport | loopback — no NIC, no driver, no wire |

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

Re-taken two cycles later against the same binary shape, 20 seconds each, with
a same-machine baseline built from the commit before the change so the two are
not a quote against a measurement:

| | before ADR 0071 | after |
|---|---|---|
| run 1 | 1,443,627 req/s, p99 63µs | 1,420,908 req/s, p99 62µs |
| run 2 | 1,406,129 req/s, p99 61µs | 1,444,746 req/s, p99 60µs |
| run 3 | — | 1,485,190 req/s, p99 55µs |

The whole machine is faster than it was for the table above, which is why the
baseline was rebuilt rather than compared against the published 1.31M. Against
that baseline the change is **not a regression and probably a small win**: a
request that touches one page of stack instead of two takes fewer TLB entries
and fewer faults, which is enough to pay for the `noinline` calls it costs.

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
freshly started server, `VmRSS` read after the sockets settle, at 500 / 1,000 /
2,000 sockets so the marginal figure can be read off rather than assumed. Same
machine and method as the table above, so the HTTP row is the control rather
than a quote. `IDLE_MS=0` — the framework's 30-second keepalive would have
every fiber in the measurement waking to ping, which is a different thing to
measure.

Three things changed across this cycle and the columns are in the order they
landed: the message buffer stopped belonging to the handler
(`http/scratch.zig`), then the idle wait and the socket loop both moved up to
the connection loop's frame
([ADR 0071](../../docs/adr/0071-where-a-connection-waits-is-what-it-costs.md)).

| what the connection is | at the start | pooled buffer | loop handed back |
|---|---|---|---|
| HTTP keep-alive, one 6-byte response | 8,763 | 8,753 | **4,669** |
| WebSocket, upgraded and never spoken to | 21,619 | 9,290 | **5,186** |
| WebSocket, one 6-byte echo | 21,561 | 9,282 | **5,194** |
| WebSocket, 64 KiB ceiling, one 6-byte echo | 21,565 | 9,290 | **5,218** |
| WebSocket, 64 KiB ceiling, one 60 KiB echo | 87,101 | 9,282 | **5,181** |
| WebSocket, 64 KiB of stack touched in the loop | 87,099 | 74,858 | 70,767 |

All three columns are the marginal figure at 2,000 sockets — `(RSS at 2,000 −
RSS at 1,000) / 1,000` — which is the one that does not carry the server's own
8 MB baseline in it.

**An idle WebSocket cost 21,561 bytes and now costs 5,194** — a quarter of what
it was. Ten thousand idle chat tabs are 52 MB rather than 216 MB. Flat to
within 30 bytes from 500 sockets to 2,000, the way the HTTP figure is.

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

| what the connection is | nilo, at the start | nilo, now | gws |
|---|---|---|---|
| HTTP keep-alive, one 6-byte response | 8,763 | **4,669** | 19,913 |
| WebSocket, upgraded and never spoken to | 21,619 | **5,186** | 8,247 |
| WebSocket, one 6-byte echo | 21,561 | **5,194** | 10,144 |
| WebSocket, one 60 KiB echo | 87,101 | **5,181** | 10,224 |

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
connections, 64-byte payloads, serial round trips, 20 seconds:

| | nilo | gws |
|---|---|---|
| echo throughput, run 1 | **1,736,133 msg/s** | 1,615,326 |
| echo throughput, run 2 | **1,703,176 msg/s** | 1,587,149 |
| p50 | **31–32µs** | 33–34µs |
| p99 | **97–100µs** | 112–116µs |
| p999 | **173–258µs** | 328–368µs |

**7.4% on throughput, 14% on p99, 40% on p999 — a real win and a narrow one on
the headline, and the number is only honest because both were pinned.** An
earlier unpinned run had gws at 1,029,308 msg/s and would have been reported as
nilo winning by 68%. That was the load generator and the server fighting over
cores, not the two libraries, and it is the same trap `bench/bench.sh` unpinned
falls into on the HTTP side.

Two things the table cannot say. gws's per-connection figure is still falling
at 2,000 sockets (11,346 → 9,093 raw for the idle row) where nilo's is flat to
within 30 bytes, so the two are converging from opposite directions and gws
would need a bigger run to pin down. And every gws number moves with when the
collector last ran — its idle row read 7,989 one afternoon and 8,247 the next,
against nilo moving by eight — which is why both readings are in
`bench/result/ws-idle.json` and why the gws column deserves less precision than
it is printed with.

### What is not measured

**A message big enough to be worth pooling, under load.** Every throughput
figure here is 64 bytes, which never leaves one page of the free list's buffer.
What a 60 KiB message costs at a thousand messages a second — where the free
list's byte budget starts refusing spares and the allocator gets called — is
the number that would decide whether `keep_bytes` is right, and nothing here
answers it.

**Compression.** gws was run with `PermessageDeflate` off, which is the shape
that matches nilo and the one kindest to gws's memory number. A deployment that
turns it on is a different comparison in both directions.

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
```

WebSocket throughput, both servers driven by the same client so neither is
measured through a different implementation:

```bash
( cd bench/compare/wsload && go build -o wsload . )

IDLE_MS=0 taskset -c 0-3,8-11 ./zig-out/bin/nilo-bench-ws-server &
taskset -c 4-7,12-15 ./bench/compare/wsload/wsload \
    -url ws://127.0.0.1:8789/ws/small -conns 64 -d 20s -warmup 3s -payload 64
```

**Pin both sides or the number is about the scheduler.** Unpinned, gws measures
1,029,308 msg/s on this machine and pinned it measures 1,595,350 — a 55%
difference that has nothing to do with gws.

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
