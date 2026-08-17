# `nilo_fetch` — what the Fitting costs

The four axes of [ADR 0018](../../docs/adr/0018-the-trade-budget-has-three-axes.md),
measured for the outbound HTTP client
([ADR 0070](../../docs/adr/0070-a-fitting-borrows-the-loop.md)) before it is
called finished. `nilo_fetch` is sixty-five lines of policy around
`std.http.Client`, so every number here is asked twice: once against a program
with no client in it at all, and once against the same call made through plain
`std.http.Client` with none of the policy. **Only the difference between those
two is nilo's.**

Everything below was run on 17 August 2026, at `d3ee93c` plus the working tree
that added `fetch/`.

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

The axis that decided the design, and the one ADR 0063 makes mandatory: a
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
connection exactly as ADR 0063 says.

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
behind in run A, 1.0% ahead in run B. That is below the 10% ADR 0018 allows a DX
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
whole binary, and the module is not in it. That is the same property ADR 0040
buys for `pg.zig` with `.lazy = true`, here for free because an unimported
module is never analysed.

ADR 0018's running total gains 1,688 bytes, and only for programs that call out.

## Allocations per call

**One, and it is the response body**, into the Scope's arena via
`allocRemaining`. Held by a test rather than by this file —
`test "a call on a warm connection allocates once, and it is the body"` in
`fetch/live.zig`, which counts through a wrapping allocator the way
`http/app.zig`'s budget test does.

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
  `http.Decompress` plus a 32 KiB flate window. By ADR 0063 that is per
  *connection* on the handler's stack — twice what the whole call already costs
  there, against the 16,495 measured above.
- **A setting would be the worst of the three.** The branch would be at
  runtime, so flate would link into every binary that dials out whether or not
  anybody turned it on. That is ADR 0018's complaint about `docs()`, exactly.
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

## Can these be pushed further

Ranked, with the two that were already tried marked.

1. **The 16,495 bytes an idle connection.** The largest number here by three
   orders of magnitude and the only one worth work. It is fiber stack, so the
   fix is not in `fetch/` at all: it is giving stack pages back between
   requests, the same `MADV_DONTNEED` treatment `http.md` describes for the
   connection buffers, which ADR 0063 records as never having been applied to
   stacks. That is an `http/` change and it would pay for every handler in the
   framework rather than only this one.
2. ~~Move the two client buffers into the arena.~~ *Tried, −66 bytes.* See
   above; they do not set the high-water mark.
3. ~~Blame the retained request arena.~~ *Tried, ruled out by `/warm`.*
4. **Shrink the two buffers.** 2 KB of redirect buffer is generous for a service
   calling a known endpoint, and 4 KB of transfer buffer bounds nothing that
   `max_body` does not already bound. Expected to be worth nothing, for the
   reason `/arena` was worth nothing — but it is cheap to test and it has not
   been.
5. **Nothing on throughput.** ±1% against the control, on a harness whose own
   run-to-run drift is larger. There is no signal here to chase.
6. **Nothing on binary size.** 1,640 bytes for the module; the rest is std's and
   is not nilo's to remove.

## Reproducing this

```bash
zig build -Doptimize=ReleaseFast bench-fetch-server
./zig-out/bin/nilo-bench-fetch-server        # listens on 8791, upstream on 8900+

# memory per idle connection — a fresh server per route, because RSS is a
# high-water mark and the previous route's pages are still in it
python3 bench/mem.py --port 8791 --path /call --steps 500,1000,2000,4000

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

## What is still missing

- **A quiet machine.** The load average was between 6 and 18 across these runs
  and the `/health` figure moved 2% because of it. Same gap as `http.md`.
- **TLS under load.** `zig build smoke-tls -Dnetwork` now runs three tests
  against real endpoints, so the handshake and certificate verification are
  exercised — see below. What is still missing is any *measurement* through
  one: every number in this file is `http://`, and a handshake is where an
  outbound client is slowest and holds the most memory. An HTTPS connection
  holds 59,151 bytes of buffers by `fetch.zig`'s own header, which is 3.6× the
  16,495 measured here and has never been put on a scale.
- **A deadline that fires under load.** `fetch/deadline.zig` proves one fires;
  nothing here measures what a server does when a slow upstream makes them fire
  on every request at once, which is the failure the gate and the deadline
  exist for.
- **An upstream that is not in the same process.** The one here removes network
  variance on purpose, and in doing so removes the case where a client's
  buffering strategy would show up at all.
