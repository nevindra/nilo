# `nilo_fetch` — what the Fitting costs

The four axes of [ADR 017](../../docs/adr/017-the-trade-budget-has-four-axes.md),
measured for the outbound HTTP client
([ADR 061](../../docs/adr/061-a-fitting-borrows-the-loop.md)) before it is
called finished. `nilo_fetch` is sixty-five lines of policy around
`std.http.Client`, so every number here is asked twice: once against a program
with no client in it at all, and once against the same call made through plain
`std.http.Client` with none of the policy. **Only the difference between those
two is nilo's.**

Everything below was run on 17 August 2026, at `d3ee93c` plus the working tree
that added `fetch/` — **except the memory section marked "measured again"**,
which is 5 September 2026 at `4131913` and supersedes the table above it. Read
that one first: the headline figure fell by three quarters and nothing in
`fetch/` changed. **The 4,139 that section leaves is not stack either**; see
*The 4,139 was the arena* below (9 October 2026, `1e583bc`), which also holds
the first measurement of an HTTPS connection in the pool.

- AMD Ryzen 7 9700X, 8 cores / 16 threads, Linux 7.0.0-29-generic
- Zig 0.16.0, `-Doptimize=ReleaseFast`, `-Dstrip=true` for the size figures
- Loopback, one box, generator and server sharing it — so the absolutes are a
  ceiling and the ratios are the result. `bench/result/http.md` says the same
  thing and it applies here unchanged.
- `bench/fetch_server.zig`, six routes, `bench/mem.py` and `wrk -t4 -c64`

## The six routes

Each one removes a layer from the one above, because a single number for "an
outbound call" cannot say which part of it is whose.

| route | what it does |
|---|---|
| `/health` | a constant `[]const u8`. No `Ctx`, no service, no arena. The floor. |
| `/bound` | arms a `core.Limits.Bound` and releases it. The deadline seam alone. |
| `/warm` | 1,008 bytes out of the request arena, no client. |
| `/bare` | one call through a plain `std.http.Client`: no gate, no deadline, no ceiling. |
| `/arena` | `/bare` with the two client buffers moved off the stack into the arena. |
| `/call` | the same call through `nilo_fetch`. |

The upstream is a fixed ~1 KB answer served from a thread inside the same
process. Deliberate: an upstream across a network puts its own latency and its
own variance into every reading, and what is being measured is a client's
overhead rather than a round trip.

## Memory per idle connection

The axis that decided the design, and the one ADR 062 makes mandatory: a
suspended fiber holds its stack at the high-water mark, so **a handler's cost
is per connection, not per request.**

Method as in [`http.md`](http.md): a freshly started server per route, open
keep-alive connections in steps, one request on each so the connection is fully
established and its response fully drained, settle two seconds, read `VmRSS`.
Earlier steps stay open, so the last row is 4,000 live connections.

| route | 500 | 1,000 | 2,000 | 4,000 | over `/health` |
|---|---|---|---|---|---|
| `/health` | 8,741 | 8,753 | 8,765 | **8,765** | — |
| `/bound` | 8,749 | 8,761 | 8,761 | **8,767** | +2 |
| `/warm` | 10,805 | 10,809 | 10,811 | **10,813** | +2,048 |
| `/bare` | 26,010 | 25,580 | 25,364 | **25,260** | +16,495 |
| `/arena` | 27,083 | 25,858 | 25,580 | **25,326** | +16,561 |
| `/call` | 26,010 | 25,580 | 25,367 | **25,261** | +16,496 |

All bytes per connection, marginal. `/health` reproduces the framework's known
floor of 8,767 to within two bytes, which is what says the harness is measuring
the same thing `http.md` measured.

**`nilo_fetch` costs one byte per idle connection over calling `std.http.Client`
yourself** — 25,261 against 25,260, which is noise and not a number. The
semaphore permit, the `Bound`, the body ceiling and the drain decision are all
free on this axis. **Arming a deadline is free too**: `/bound` is `/health` plus
two bytes, because a 192-byte slot lands inside a page the fiber had already
touched.

What is *not* free is the call itself, at **16,495 bytes an idle connection**,
and that belongs to `std.http.Client` rather than to nilo. On a service holding
10,000 keep-alive connections where every route calls out, that is 165 MB above
the floor.

> **This paragraph and the table above it are superseded.** The figure is 4,139
> and the floor is 4,679; see *Measured again after the stack release* below.
> They are kept rather than corrected in place because the two runs either side
> of one commit are the finding.

### The obvious lever was tried and lost

`send` puts a 2 KB redirect buffer and a 4 KB transfer buffer on the handler's
stack. Stack is per connection and arena is per request, so moving 6 KB across
that line should have been worth 6 KB on every idle connection. That is what
`/arena` is.

It is worth **−66 bytes**. The two buffers are not what sets the high-water
mark; the depth of `std.http.Client`'s own call chain is, and it reaches the
same pages with or without them.

The second theory died the same way. 16,384 of the 16,495 is *exactly*
`arena_keep`, which made the retained request arena look like the whole answer —
so `/warm` was added to serve the same 1,008 bytes out of the same arena with no
client in it. It costs 2,048. The arena is not where the 16 KB went.

What is left is the fiber's stack, at the depth std drives it to, held per
connection exactly as ADR 062 says.

## Throughput and p99

`wrk -t4 -c64`, unpinned, two runs an hour apart. Both are reported because the
first showed the machine has a bad mood and the ratios survived it.

| route | run A req/s | run B req/s | p50 | p99 |
|---|---|---|---|---|
| `/health` | 1,120,277 | 1,095,874 | 40 µs | 662 µs |
| `/bound` | 1,110,190 | 1,095,514 | 42 µs | 0.85 ms |
| `/warm` | — | 1,080,454 | 42 µs | 0.86 ms |
| `/bare` | 701,118 / 678,145 | 658,142 | 72 µs | 0.99 ms |
| `/arena` | — | 681,456 | 71 µs | 656 µs |
| `/call` | 694,497 / 670,804 | 664,644 | 72 µs | 0.87 ms |

`/bare` and `/call` were run twice within each run, in both orders, because the
difference between them is the entire question and it is smaller than the drift.

**`nilo_fetch` is within ±1% of a bare `std.http.Client`** — 0.9% and 1.1%
behind in run A, 1.0% ahead in run B. That is below the 10% ADR 017 allows a DX
feature to spend and below this harness's own noise, which is the honest way to
report it: no measurable cost, rather than a specific small one.

**Arming a deadline costs nothing measurable** — `/bound` is within 0.1% of
`/health` in run B and 0.9% in run A.

Calling out at all costs 40% of the floor: 1.10M down to 0.66M. That is one
extra socket round trip inside every request and is what an outbound call is,
not something a client implementation can give back.

## Binary size

Three stripped `ReleaseFast` executables, identical but for the client:

| program | bytes | delta |
|---|---|---|
| a nilo server, no outbound client | 879,312 | — |
| the same, one route calling `std.http.Client` directly | 1,534,912 | +655,600 |
| the same, one route calling `nilo_fetch` | 1,536,600 | **+1,688** |

**The module's own cost is 1,688 bytes.** The other 640 KiB is
`std.http.Client` and the TLS stack under it, paid by anyone who dials out in
Zig at all.

A program that never imports `nilo_fetch` pays **zero** — the first row is the
whole binary, and the module is not in it. That is the same property ADR 037
buys for `pg.zig` with `.lazy = true`, here for free because an unimported
module is never analysed.

ADR 017's running total gains 1,688 bytes, and only for programs that call out.

## Allocations per call

**Two, and they are the response's header block and its body**, into the
Scope's arena: the block is `dupe`d before the body reads over it
([ADR 187](../../docs/adr/187-a-head-that-outlives-its-body.md)), and the
body is `allocRemaining`. Held by a test rather than by this file —
`test "a call on a warm connection allocates twice: the header block, then the body"`
in `fetch/live.zig`, which counts through a wrapping allocator the way
`http/app.zig`'s budget test does. It was one — the body alone — until the
`Response` started carrying its headers, and that is the whole of the
change: a call that never reads a header pays one `memcpy` of a few hundred
bytes it did not before. An `Exchange` still allocates nothing in `begin`.
`postJson` and `withQuery` each add one more, for the JSON written out and
the URL assembled, which is the allocation their callers were already making
by hand ([ADR 061](../../docs/adr/061-a-fitting-borrows-the-loop.md)).

The gate is a semaphore with nothing allocated behind it, the deadline arms into
a slot inside the `Bound` on the stack, and the request head is written into the
connection's own buffer. Opening a connection allocates — that is
`std.http.Client`'s pool, a cost of the connection rather than of a call — so
the test warms one first and counts the second call down the same socket.

## What the first real endpoint found

Everything above was measured against `Canned`, a loopback server written for
the tests, and `bench/fetch_server.zig`'s upstream, written for the benchmark.
Both behave the way their author expected. **The first request to an endpoint
nobody here wrote came back as 388 bytes of gzip.**

`std.http.Client` advertises `Accept-Encoding: gzip, deflate` by default, and
`Response.reader` returns the *compressed* bytes — decompressing is a separate
call with a separate buffer. Fourteen canned tests passed over that, because
nothing in this repository compresses anything. Status 200, no error, a
non-empty `Str`, and every byte of it unreadable.

`send` now asks for `identity`, and the decision is on the record rather than
in a diff:

- **`readerDecompressing` was the alternative**, and it costs a
  `http.Decompress` plus a 32 KiB flate window. By ADR 062 that is per
  *connection* on the handler's stack — twice what the whole call already costs
  there, against the 16,495 measured above.
- **A setting would be the worst of the three.** The branch would be at
  runtime, so flate would link into every binary that dials out whether or not
  anybody turned it on. That is ADR 017's complaint about `docs()`, exactly.
- **Identity costs 48 bytes** — the difference between the +1,640 first
  measured and the +1,688 in the table — and makes `max_body` count the bytes
  a caller receives rather than the bytes on the wire, which is the more useful
  ceiling anyway.

Two lines rather than one, and the second is not decoration: setting only the
bool array emits a malformed `accept-encoding\r\n` with no value, because std's
writer skips `identity` when listing encodings and then trims a separator it
never wrote. The header goes on with `.{ .override = "identity" }`; the array
is what `receiveHead` checks, so a server that ignores the request and gzips
anyway is a clean error rather than a `Str` full of noise.

`fetch/tls.zig` holds it against the network and one test in `fetch/live.zig`
holds it against `Canned`, so deleting either line fails in `zig build test`
rather than only in a step somebody remembers to run.

## Measured again after the stack release: 16,495 became 4,139

Everything above was taken at `81bd9df`. `dcadb46` landed two days later and
gave a connection's *stack* pages back once it goes quiet
([ADR 062](../../docs/adr/062-where-a-connection-waits-is-what-it-costs.md),
`releaseIdleStack` in `http/engine/zio.zig`), which is precisely the lever the
ranked list below used to open with — and nothing re-ran this file, so the
number stood for a month describing a server that no longer existed.

Same six routes, same harness, out to 10,000 connections this time because at
4,000 the marginal figure was still 100 bytes above where it settled.

| route | 500 | 1,000 | 2,000 | 5,000 | 10,000 | over `/health` |
|---|---|---|---|---|---|---|
| `/health` | 4,801 | 4,739 | 4,706 | 4,686 | **4,679** | — |
| `/bound` | 4,801 | 4,739 | 4,706 | 4,686 | **4,679** | 0 |
| `/warm` | 6,980 | 6,853 | 6,787 | 6,747 | **6,733** | +2,054 |
| `/bare` | 9,757 | 9,265 | 9,017 | 8,868 | **8,818** | +4,139 |
| `/arena` | 13,894 | 13,390 | 13,115 | 12,965 | **12,914** | +8,235 |
| `/call` | 9,757 | 9,265 | 9,017 | 8,868 | **8,818** | +4,139 |

**Calling out costs 4,139 bytes an idle connection, not 16,495.** Three
quarters of it was frames of `std.http.Client`'s call chain that had already
returned, and the pages went back the moment the connection went quiet. On a
service holding 10,000 keep-alive connections where every route calls out, that
is 41 MB above the floor rather than 165 MB.

Two of the rows say more than that one does.

**`/call` is byte-for-byte `/bare`** — 8,818 against 8,818, where it used to be
one byte over. `nilo_fetch` costs nothing on this axis, and now it costs
nothing exactly rather than within noise.

**`/arena` inverted.** Moving the two client buffers off the stack and into the
request arena was worth −66 bytes when it was tried and it is now worth
**+4,096, one page, every time.** Nothing about `/arena` changed; the ground
under it did. Stack is given back when a connection goes quiet and the
retained arena is not, so the lever that used to move memory from one place
that held it to another place that held it now moves it *out* of the only
place that lets go. **A comparison is only as current as the thing it is
against**, and a lever measured as a wash is exactly the kind of result nobody
re-runs.

`/health` reproduces `http.md`'s 4,669 to within 10 bytes, which is what says
the harness is still measuring the same thing it was — and that is worth more
than usual here, because **it is not the same box.** The tables above are an
8-core Ryzen 7 9700X; this run is a 2-core Intel Xeon Platinum 8255C with 7 GiB.
A per-connection memory figure is the one axis that should survive that, and
`/health` landing within 10 bytes of the other machine's is the evidence it did.
Do not read the *throughput* tables above against this run.

RSS only, `bench/mem.py`, load average under 1, 5 September 2026, `4131913`.

## The 4,139 was the arena, and the stack was nothing

9 October 2026, `1e583bc` plus the working tree (`bench/fetch_server.zig` gained `NILO_ARENA_KEEP` and a `/exact` route, and `bench/fetch_tls_pool.zig` is new). AMD Ryzen 7 9700X, 8 cores / 16 threads, Linux 7.2.5-3-omarchy, Zig 0.17.0, `-Doptimize=ReleaseFast`, stripped except where a debugger was attached. The server was pinned to cpus 4 and 5 and the generator to cpu 6, three different physical cores. The load average was 0.4 to 1.6 for the first runs and 2 to 10 for the last (other builds on the box), and RSS did not move with it. `bench/mem.py`, a fresh server per route, out to 10,000 connections.

The todo entry for this said the 4,139 was "fiber stack rather than buffers, at the depth `std.http.Client` drives it to", and the open question was which frame of std it waits in. **It does not wait in one: the stack is not what an idle connection holds after a call.** The first step was to reproduce the figure, the second to take the retained request arena out of it (`arena_keep = 0`), which the earlier sections never did. They ruled the arena out with `/warm`, which costs 2,048 and so read as small.

Bytes an idle connection holds over `/health`, at 10,000 connections, two interleaved repetitions (both shown where they differ), `arena_keep` at its default of 16 KiB and at 0:

| route | 16 KiB, 10,000 | over `/health` | `arena_keep = 0`, 10,000 | over `/health` |
|---|---|---|---|---|
| `/health` | 4,678 | | 4,678 | |
| `/warm` | 6,726 | +2,048 | 4,679 | +1 |
| `/bare` | 8,819 | **+4,141** | 4,723 | **+45** |
| `/call` | 8,846 / 8,845 | **+4,168** | 4,750 / 4,749 | **+72** |

The first run of the old method (stripped build, same pinning) read `/call` at 8,858 against `/health` at 4,685 (+4,173) and `/bare` at 8,831 (+4,146), so the 4,139 reproduces within 1%.

**With the arena kept out, a call costs 72 bytes an idle connection, not 4,168, and 45 of them are `std.http.Client` with none of nilo's policy on it.** The marginal figure says the rest is not per connection at all: between 5,000 and 10,000 connections `/call` with `arena_keep = 0` grows RSS by 50,872 kB less 28,060 kB, which is 4,672 bytes a connection, exactly what `/health` adds. What is left of the 72 is a constant of roughly 720 KB for the whole process (the code pages of the client, the outbound connection, the upstream thread), which divides by the connection count and vanishes as it grows. **The stack of a call is given back whole**, which is `releaseIdleStack` doing what ADR 062 says it does, and the ranked list that ended in "what is left is the frame `std.http.Client` waits in" was ranking a cost that did not exist.

What the 4,141 is: **one 4 KiB page of the request arena, kept resident by `arena_keep`.** A gdb breakpoint on `heap.ArenaAllocator.alloc` through a `/call` sees two allocations on the request's arena: 67 bytes, the header block `Exchange.begin` keeps (ADR 187), and 1,641 for the body. 1,641 for a 1,008-byte body is `Io.Reader.allocRemaining` growing an `Io.Writer.Allocating` and `toOwnedSlice` shrinking it in place, which an arena cannot give back. `arena_keep` retains the node they land in, and the pages stay touched. Setting `arena_keep` to 8 KiB, 4 KiB and 2 KiB changed nothing (8,845 at 10,000 in all three), so the retention is by whole nodes and not by bytes, and only 0 lets it go. A new route, `/exact`, is `/bare` with the head block copied first (so the arena sees the same two allocations in the same order) and the body read into a buffer sized by `content-length`, the way `Exchange.readInto` does:

| route | 10,000 | over `/health` | marginal, 5,000 to 10,000 |
|---|---|---|---|
| `/warm` | 6,726 | +2,048 | +2,048 |
| `/exact` | 6,783 | **+2,105** | +2,048 |
| `/bare` | 8,825 | +4,147 | +4,096 |
| `/call` | 8,846 | +4,168 | +4,096 |

**A sized read saves about 2,040 bytes an idle connection, half of what a call holds, with no allocation added.** What stays, +2,048, is what `/warm` already shows: any handler that puts about a kilobyte in its arena holds a page of it, which is `arena_keep` working as ADR 075 designed it and not the call's to remove. `Exchange.take` is nilo's own code and calls `allocRemaining` with a limit, so the lever is nilo's and needs no client of nilo's own. The same experiment in ReleaseSafe (`/call` at 10,000: 8,858 against `/health` 4,678, +4,180) reads the same, so the finding is not a ReleaseFast artefact.

**`/call` is 26 to 27 bytes over `/bare`** in every run of this session (8,846 against 8,819, and 8,858 against 8,831 in the first). ADR 061 said 0 bytes exactly, which held at the September run and does not now. The marginal figures are equal (4,096 both), so it is a constant of the module's code pages and not a cost per connection, and is quoted as 27 until a run says otherwise.

### Where the stack is while a call waits

This is the cost of an *in-flight* call and not of an idle one, and it is the number the circuit-breaker entry in `docs/todo.md` asks for ("the fibers and bytes the waiting calls hold"). Frames were read from a debugger on the unstripped build: a Python hook on a `common.waitForIo` breakpoint, three `/call` requests against the in-process upstream, `sp` of each frame walked from `gdb.newest_frame()`. Functions inlined into one frame are listed together, and bytes are the distance to the caller's `sp`. The deepest wait seen is the response head, in `receiveHead`.

| frame, outermost first | ReleaseFast | ReleaseSafe | whose | movable without a client of our own? |
|---|---|---|---|---|
| `entrypointFn`, `startFn` | 64 | 64 | zio | no |
| connection frame: `Wrapper.start` + `Conn.run` + `Bridge.run` + `handleConnection` | 2,352 | 2,384 | zio's spawn wrapper around nilo's loop | already moved (ADR 062); it is the floor |
| `serveRequest` + `Next.run` | 2,432 | 2,304 | nilo `http/` | yes, but it is released at idle anyway |
| `typed.Wrapper.run` with the handler, `Client.get`, `send`, `sendAs`, `sendCarrying` and `Exchange.begin` inlined | 6,656 | 6,720 | nilo `http/typed` and `fetch/` | yes: it holds the 2 KiB `redirect_buffer` (uninitialised, so only its written part is resident), the 992-byte `Exchange`, the carried headers and the traceparent |
| `Exchange.dispatch` + `bounded` | 1,200 | 1,216 | nilo `fetch/` | yes |
| `Exchange.attempt` | 1,392 | 1,568 | nilo `fetch/` | yes |
| `http.Client.Request.receiveHead` (with `Reader.receiveHead` and `fillMore` inlined) | 1,024 | 1,056 | **std** | no |
| `Io.net.Stream.Reader.readVec` (with `Io.operate` and `readWithControl`) | 288 | 352 | **std** | no |
| `io.operateImpl` | 128 | 128 | zio | no |
| `io.operateInner` (with `netReadOpImpl`) | 1,760 | 1,824 | zio | no |
| `common.waitForIo` | 144 | 160 | zio | no |
| **total at the wait** | **17,440** | **17,776** | | |

nilo's frames are 14,032 of the 17,440 bytes (80%), std's are 1,312 (7.5%) and zio's 2,096 (12%). Waiting to write the request is 16,352 deep and the wait for a request id's random bytes 11,952. The idle park, for comparison, is `waitForIo` at 3,472 under `waitForRequest`, and everything below it is returned when the connection goes quiet. **A call that waits a long time on a slow upstream holds about 17.4 KB of stack, five pages and so up to 20 KB resident, for as long as it waits, and gives it all back when the handler returns.** Thirty-two calls through the default gate hold under 0.7 MB that way, and 1,000 slow calls 17 to 20 MB. A dial was not seen to reach `waitForIo` on loopback, and a TLS handshake (`std.crypto.tls.Client.init`) was not put under the debugger; either can be deeper than this table, and neither is measured. Only 7.5% of the in-flight depth is std's, and the largest single frame is `typed.Wrapper.run`, the one to read if the in-flight number ever matters. It does not matter for the idle one.

**Decision this moves.** The todo entry's premise (stack, std's frame) is withdrawn, and ADR 061's table and the guide's "it is fiber stack rather than buffers" are corrected in the same change. A new concrete entry takes its place: size the body from `content-length` in `Exchange.take`, worth about 2,040 bytes an idle connection. **Can it be pushed further?** The remaining 2,048 is `arena_keep`'s page, shared by every handler, so no from the call's side; the stack is already zero, so nothing from std's side either.

Reproducing it: `NILO_ARENA_KEEP=0 ./zig-out/bin/nilo-bench-fetch-server` (read once, in `main`), then `python3 bench/mem.py --port 8791 --path /call --steps 500,1000,2000,5000,10000` against it, pinned as above. `/exact` is a route of the same binary.

## What a connection in the pool holds over TLS, measured

9 October 2026, `1e583bc` plus `bench/fetch_tls_pool.zig`, same machine and pinning (client on cpus 2 and 3, server on 4 and 5), `-O ReleaseFast`. The 59,151 quoted in the guide, the reference and `fetch/fetch.zig` is `std.http.Client`'s allocation for a TLS connection: `sizeOf(Tls)` plus the host name, the read buffer (8,192 + 16,645), the two TLS buffers (16,645 each) and the write buffer (1,024). It was read off the code and never put on a scale, and a buffer is resident only where a byte was written to it, so the sum is a ceiling.

The program opens N connections at once so none is reused, lets each finish one request, hands them all back to a pool whose `free_size` is raised so none is closed, joins the threads that drove them, and reads its own `VmRSS` after two seconds. One connection is made first so the root-certificate scan and the first handshake's code are in the base. Steps are cumulative. It drives `std.http.Client` itself because `nilo_fetch` caps the idle pool at 32 and would stop the series there; the two share the connection allocation. The local server is `bench-tls-server -Dtls` (nilo's TLS 1.3 server, certificate `http/testdata/tls/localhost.pem` added as the client's only root, so verification is on). The plain control is the upstream thread of `bench-fetch-server`. The answers of other sizes come from a Python `http.server` over TLS, since the nilo servers have no route that answers a GET with a large body. A real endpoint, `https://example.com/`, was run for 4, 8 and 16 connections only, out of politeness.

Bytes a pooled connection holds, marginal as connections are added:

| connections in the pool | TLS, 1 KB answer | plain, 1 KB answer |
|---|---|---|
| 50 | 12,455 | 8,526 |
| 100 | 12,452 | 8,192 |
| 200 | 12,411 | 8,192 |
| 400 | 12,288 | 8,192 |
| 800 | 12,319 | 8,192 |
| 1,600 | 12,339 | 8,223 |
| 3,200 | 12,308 (average 12,324) | 8,205 (average 8,211) |

Two more repetitions at 100, 400 and 1,600 gave 12,371 / 12,288 / 12,302 and 12,329 / 12,288 / 12,305 over TLS, and 8,316 / 8,219 / 8,206 and 8,233 / 8,206 / 8,212 in plain. **A pooled connection costs 12.3 KB over TLS and 8.2 KB in plain, three pages and two, and neither steps nor compounds out to 3,200.** The first row is higher only because the one-off costs of the first handshakes have not yet divided out.

What it depends on is how much of the read buffers the answers have touched:

| answer | TLS, marginal at 400 | plain, marginal at 400 |
|---|---|---|
| 1 KB | 12,288 | 8,192 |
| 16 KB | **45,056** | 12,288 |
| 64 KB | **45,056** | 12,288 |
| `example.com` (a small page behind a real certificate chain) | 16,384 | |

**The 59,151 is a ceiling that a connection reaches 76% of: 45,056 bytes once it has carried an answer as large as a TLS record, and 12,288 for a small API answer.** Plain, the same: 8,192 for a small answer and 12,288 after a large one, against about 9.3 KB on paper. An idle pooled connection over TLS is 1.5 times a plain one for the small answers an API gives, and 3.7 times after large ones. Neither number includes the kernel's socket buffers, which are not resident in the process and were not measured.

**Decision this moves.** `max_in_flight` and the guide's "five hundred concurrent handlers would be 29.6 MB" bound what a connection allocates and are conservative by a factor of 1.3 to 4.8, depending on the answer. The guide, the reference and ADR 060 now say "up to 59,151 bytes, 12 KB resident after a small answer and 45 KB after one of a record or more". `fetch/fetch.zig`'s header and its `Settings.max_in_flight` comment still quote 59,151 as what a connection holds, and are left for whoever next edits that file. A connection in flight also holds its fiber's stack (17 KB at the wait, above), which this series, with its threads joined, does not. **Can it be pushed further?** The buffers are std's and `read_buffer_size` is the one knob nilo exposes. Shrinking it from 8 KiB would lower the plain figure after a large answer and the TLS one by the same amount, and nothing measured says an API client wants that. A smaller TLS footprint is a different client's.

Reproducing it: the header of `bench/fetch_tls_pool.zig` has the commands. `zig build smoke-tls -Dnetwork` ran from this machine at this commit and exited 0 in both optimize modes, so the internet was reachable and the same network served both.

## Can these be pushed further

Ranked, with the three that were already tried marked.

1. ~~Give the fiber's stack pages back between requests.~~ **Done, and it was
   worth 12,356 bytes an idle connection** — see the table above. It paid for
   every handler in the framework, exactly as this entry predicted; it is left
   here because the prediction being right is the reason to trust the next one.
2. ~~Shrink the two buffers.~~ **Run, and worth nothing: the 4 KB transfer
   buffer came out of `send` altogether and `/call` moved by 14 bytes**; see
   [the section below](#the-transfer-buffer-was-never-a-resident-page). A
   stack buffer no byte touches is never faulted in, so a buffer's *size* was
   never on this axis; only the depth of the frames that are written to is.
   The 2 KB redirect buffer is the same kind of thing and is not worth a run.
3. ~~Move the two client buffers into the arena.~~ *Tried twice: −66 bytes
   before the stack release and +4,096 after it.* Do not try a third time.
4. ~~Blame the retained request arena.~~ *Tried, ruled out by `/warm`.*
5. **Size the body from `content-length`.** *Measured, not built* (see
   [*The 4,139 was the arena*](#the-4139-was-the-arena-and-the-stack-was-nothing)):
   `/exact` against `/bare` is about 2,040 bytes an idle connection with no
   allocation added. The 4,139 was the arena and not the stack, so "what is
   left is the frame `std.http.Client` waits in" ranked a cost that was
   already zero.
6. **Nothing on throughput.** ±1% against the control, on a harness whose own
   run-to-run drift is larger. There is no signal here to chase.
7. **Nothing on binary size.** 1,640 bytes for the module; the rest is std's and
   is not nilo's to remove.

## The transfer buffer was never a resident page

18 September 2026, `b743876` plus the working tree of ADR 056 and 186,
`bench/fetch_server.zig` in ReleaseFast, `bench/mem.py` to 5,000, before and
after interleaved twice, load average under 1.6. A different box again from
the run above (AMD, 16 threads, Linux 7.2.5), so `/health` is 5,186 here
rather than 4,679 and only the differences are comparable.

| route | 500 | 1,000 | 2,000 | 5,000 |
|---|---|---|---|---|
| `/health`, after | 5,202 | 5,198 | 5,190 | **5,186** |
| `/bare`, after | 10,306 | 9,789 | 9,542 | **9,383** |
| `/call`, before, run 1 | 10,977 | 10,121 | 9,703 | **9,451** |
| `/call`, after, run 1 | 10,830 | 10,060 | 9,671 | **9,437** |
| `/call`, before, run 2 | 10,985 | 10,142 | 9,708 | **9,450** |
| `/call`, after, run 2 | 10,846 | 10,064 | 9,673 | **9,437** |

The diff under test takes the 4,096-byte `transfer_buffer` out of
`Client.send` and adds 64 bytes to `@sizeOf(Exchange)` (928 → 992, ADR
056's tap reader). **−14 bytes, both pairs.** A 4 KiB stack array that is
declared `undefined` and never written is never faulted in, so it was never
in `VmRSS` and taking it out cannot move `VmRSS`; and 64 bytes of struct
that *are* written land inside a page the frame already touches. That is
the mechanism behind lever 2 above being worth nothing, and behind
`bench/result/s3.md`'s "64 KB to 8 KB moved one byte", which had the same
fact on file under "the lever is depth".

What the buffer cost was the claim: three documents said it was the body's
window, and a download manager planned a mebibyte against it
([ADR 186](../../docs/adr/186-the-transfer-buffer-serves-nothing-here.md)).

`/call` over `/bare` is +54 here, where the September run had them equal;
the two are one run each on a box with 1.5 of load, and the difference is
under the spread between the two `/call` pairs at 500 connections (147
bytes), so it is quoted as noise rather than as a cost.

## Reproducing this

```bash
zig build -Doptimize=ReleaseFast bench-fetch-server
./zig-out/bin/nilo-bench-fetch-server        # listens on 8791, upstream on 8900+

# memory per idle connection — a fresh server per route, because RSS is a
# high-water mark and the previous route's pages are still in it, and out to
# 10,000 because at 4,000 the marginal figure is still 100 bytes high
python3 bench/mem.py --port 8791 --path /call --steps 500,1000,2000,5000,10000

# throughput, all six routes against one server
./bench/bench.sh http://127.0.0.1:8791/call
```

**Check the port before believing anything.** Three runs of this were thrown
away before the cause was found: a sibling worktree's bench server was holding
8789, so `nilo-bench-fetch-server` never bound, `mem.py` read the wrong
process's `VmRSS`, and `wrk` reported the other server's 404s as "Non-2xx". The
server now fails loudly when its upstream has nowhere to listen, and
`bench/mem.py` names the pid it is reading — but neither of those catches a
generator pointed at somebody else's port. A `Non-2xx` line in wrk output, or a
pid in `mem.py`'s header that is not the server just started, means throw the
run away.

## What a proxy, a roots setting and a wider retry cost a program that uses neither

Run on 9 October 2026, at `1e583bc` plus the working tree that added
`Settings.proxy`, `Settings.roots` and the retry of a failed write on a pooled
connection ([ADR 267](../../docs/adr/267-a-call-can-go-through-a-proxy-and-trust-a-private-authority.md),
[ADR 058](../../docs/adr/058-most-of-an-s3-client-is-not-s3.md)). Same machine
as above, Zig 0.17.0, the host being loaded by other builds, which does not
matter for a size.

A program that dials out through `nilo_fetch` with default `Settings` (a
`postJson` over `https://` and a `putForm` over `http://`), built twice with
`zig build-exe -OReleaseFast -fstrip -target x86_64-linux-gnu`, once against
`fetch/` and `core/` taken from `git archive 1e583bc` and once against the
working tree:

| module at | bytes | delta |
|---|---|---|
| `1e583bc` | 954,384 | — |
| working tree | 956,528 | **+2,144** |

The branch on `Settings.proxy` is a runtime one, so the bytes are unconditional
for a program that imports the module, and the retry change is in the number
(they share `Exchange.pickConnection`, which is why they are not separated). A
program that does not import `nilo_fetch` is byte-identical. `@sizeOf` of the
per-call struct `fetch.Exchange` is 992 before and after; `fetch.Client` is 640
before and 688 after, once per process.

Not measured: the stack high-water mark of a call parked under an Engine
(`bench/mem.py` against an `outbound`-shaped server), which is where ADR 062's
per-connection figure would move if `pickConnection`'s 255-byte name buffer
sat on the path while the fiber waited. By reading it does not (it returns
before the first read), and the figure of 4,139 bytes above is that of
`4131913` and not re-run. Can it be pushed further: the retry's `WriteFailed`
branch and `pickConnection` are about two kilobytes of this and cannot be
dropped by the linker; the proxy parsing is a few hundred bytes of it.

## A sized read gives back the arena's second page, and what a retry costs

9 October 2026, `1e583bc` plus the working tree of ADR 271 (a retry on `fetch.Target`, `Backoff` in Core, and `Exchange.take` sized from `content-length`). AMD Ryzen 7 9700X, Linux 7.2.5-3-omarchy, Zig 0.17.0, `-Doptimize=ReleaseFast`. The server was pinned to cpus 4 and 5 and `bench/mem.py` to cpu 6, a fresh server per route and per run, out to 10,000 connections, the two binaries interleaved (before, after, before, after) for three repetitions. The before is the `bench-fetch-server` built from the tree with the one hunk of `take` not yet written, the after is the same tree with it.

**Memory per idle connection (item: `Exchange.take`).** Bytes an idle connection holds, at 10,000 connections, the three repetitions identical to the byte:

| route | before | after | over `/health`, before | over `/health`, after |
|---|---|---|---|---|
| `/health` | 4,678 | 4,678 | | |
| `/call` | **8,852** (8,852, 8,852, 8,852) | **6,810** (6,810, 6,810, 6,810) | +4,174 | **+2,132** |

**A call holds 2,042 bytes less an idle connection**, 49% of what it held over the floor. The predicted figure from `/exact` was 2,040 (+2,105 against +2,132 here: the 27 bytes are the module's own code pages, the constant this section's predecessor measured), and the spread across repetitions was zero, so the margin is quoted as a figure and not a range. What stays, +2,048, is a page of the request arena that any handler putting a kilobyte in its arena keeps (`/warm`), which is `arena_keep` doing what ADR 075 designed. Arena chunks asked of the backing allocator by a warm call with a 64-byte body went from 2 to 1 (`fetch/live.zig`, "a call on a warm connection asks the arena for two things"): the header block and the body are still two asks of the arena, and the sized body fits in the chunk the block got, where `allocRemaining`'s growth went past it. A body that does not announce its length (chunked) and one announced past `max_body` take the growing read as before. A body that ends short of the length it announced is `error.BodyTooShort`, held by a test.

**Can it be pushed further?** Not from the call's side: the remaining 2,048 is shared by every handler. The binary cost of the second read path is real and not small (below).

**Binary size and what a Target pays (items: `take`, `Target.retry`).** One program (`postJson` over `https://` and `sendForm` over `http://` on the client, and a `get` and a `postJson` through a `Target`), `zig build-exe -OReleaseFast -fstrip -target x86_64-linux-gnu`, built against `fetch/` and `core/` from `git checkout-index` of the index (the base, 1e583bc with the earlier work of the session) and against the working tree; the Target declares nothing, or `.retry = .{ .times = 3, .mint_key = "Idempotency-Key" }`:

| build | bytes | delta |
|---|---|---|
| base, Target with no `.retry` | 965,216 | |
| working tree, `take` sized but the retry loop left in, no `.retry` declared | 967,152 | +1,936 |
| the same with the old `take` | 965,264 | +48 |
| working tree, `.retry` declared and minting keys | 977,664 | +10,512 over the no-`.retry` build |

So the retry costs **+48 bytes to a program that declares nothing** (the split of `through` into `once` and `retrying`, which resolve at compile time) and **+10,512 bytes to one that declares it** (the sleep, the generator, the date parser, the ledger and the key minting). **The sized read costs +1,888 bytes**, a second instantiation of `Exchange.bounded` for `readSliceAll` in programs that did not use `readInto`; that is more than a 2,042-byte saving per idle connection earns back on a binary, and it is the cheaper side of the trade only because the saving is multiplied by connections. It is reported against ADR 017's size axis, and could be shared with `readInto` by routing `take` through it (the only caller that already pays for it is `nilo_s3`).

**Allocations and idle bytes of a retrying Target.** A test (`fetch/retry_live.zig`, "a call that succeeds first time asks the arena for what a target with no retry does") holds a Target with `.retry` and one without to the same arena chunks and bytes on a warm connection. `@sizeOf(retry.Ledger)` is 264 bytes, once per Target that declares `.retry` (the field is `void` otherwise). `Exchange` was not touched. The stack a retrying call reaches was not measured: the loop is one more frame holding a 24-byte `Tries` and a copy of the `Call`, and nothing was read from a debugger.

**Not measured:** throughput with a retry declared, a retry sequence at the pool under load, and `s3`'s retry against a real store (the live suite skips without services). The first try of a retrying call takes the spin lock of the ledger once; that is the only addition to a path that succeeds.

**Decision this moves.** ADR 271 (a retry is the caller's numbers and nilo's mechanism), ADR 061's per-connection figure (+4,141 to +2,132 for `nilo_fetch`'s call), and ADR 017's running total. Reproducing the memory run: build `bench-fetch-server` before and after, then `taskset -c 4,5 ./nilo-bench-fetch-server &` and `taskset -c 6 python3 bench/mem.py --port 8791 --path /call --steps 5000,10000`, killing the server between runs.

## A call over a unix socket: what it costs (ADR 272)

Run at c4e2d08 plus the working tree of the change, on the development machine (x86-64 Linux, Zig 0.17.0), `-Dtarget=x86_64-linux-gnu`. Not a load run: three sizes, because the change adds a runtime branch and a dial and nothing to a call that sets no socket.

| what | before | after | delta |
|---|---|---|---|
| `@sizeOf(Exchange)` | 992 | 992 | 0 |
| `@sizeOf(Client)` | 688 | 688 | 0 |
| `@sizeOf(Client.Call)` | 48 | 64 | +16, on the stack of a call |
| `@sizeOf(Exchange.Begin)` | 208 | 224 | +16, on the stack of a call |
| stripped `ReleaseFast` program that does one `client.get` over `http://` | 953,008 | 953,744 | **+736** |

The program is one `get` with default settings, built with `zig build-exe -OReleaseFast -fstrip` against `fetch/` and `core/` from `git archive HEAD` and from the working tree. **Decision this moves:** none; ADR 272 quotes the figures. Allocations per request and the idle figures are not touched on a path that sets no socket, and the allocation budget test is unchanged. Not measured: throughput of a socket call, and `bench/mem.py` against a socket, which would say whether the dial frame changes the park.

## What is still missing

- **A quiet machine.** The load average was between 6 and 18 across these runs
  and the `/health` figure moved 2% because of it. Same gap as `http.md`.
- **TLS under load.** The idle bytes of a pooled HTTPS connection are
  measured now (*What a connection in the pool holds over TLS, measured*).
  What is still missing is a *throughput* figure through one: every req/s
  number in this file is `http://`, and a handshake is where an outbound
  client is slowest.
- **A deadline that fires under load.** `fetch/deadline.zig` proves one fires;
  nothing here measures what a server does when a slow upstream makes them fire
  on every request at once, which is the failure the gate and the deadline
  exist for.
- **An upstream that is not in the same process.** The one here removes network
  variance on purpose, and in doing so removes the case where a client's
  buffering strategy would show up at all.
