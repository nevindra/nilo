# zfast against other frameworks

[`benchmarks.md`](./benchmarks.md) ended with "no other framework was built or
run, so nothing here says how zfast places." This closes that gap. Eight other
servers were written against the same route, verified to return zfast's response
byte for byte, and run on the same four physical cores with the same load
generator.

The short version: **zfast is first on throughput, clearly first on tail
latency, third on memory per connection, and last on release build time though
not on the build a developer waits for.** The places it loses are the ones worth
reading — and the memory row only reads that way because measuring it the first
time put it seventh and got the code changed.

The harness is [`bench/compare/`](../bench/compare/) — `./build.sh` then
`python3 drive.py` — so this is a question that can be asked again rather than a
number to be remembered. It is out of the way of `zig build` on purpose: a Zig
repo should not need a Go toolchain to test itself.

## What was held equal

Every candidate serves `GET /users/:id`, returns the **same 982 bytes** of JSON,
serialises that JSON per request rather than caching a rendered buffer, sets
`Content-Type: application/json` and `Access-Control-Allow-Origin: *`, and
answers a missing user with a 404. The driver refuses to benchmark a server
whose body is not byte-identical to zfast's — that check caught Node returning
994 bytes, because without an explicit `Content-Length` it picks chunked
encoding and puts 12 bytes of framing on the wire nobody else was sending.

| | |
|---|---|
| Server | pinned to `0-3,8-11` — 4 physical cores and their SMT siblings |
| Client | pinned to `4-7,12-15` — the other 4 |
| Load | `wrk -t4 -c64`, 10s warm-up discarded, 3 × 20s, median reported |
| Machine | as in [`benchmarks.md`](./benchmarks.md#the-machine) — Ryzen 7 9700X, loopback |

What is **not** equal, and cannot be: response header sets differ, so bytes on
the wire run from 1,099 (http.zig) to 1,171 (Node) against zfast's 1,110. That
is a 6% spread on a ~1.1 KB response and it is part of what is being measured,
not an error in it.

Versions: Go 1.26.3, Fiber v2.52.14 (fasthttp 1.51), Node 24.16, Bun 1.3.13,
axum 0.8 with hyper 1.11 and tokio 1.53, http.zig at `c22672f`, Zig 0.16.0.

## Throughput and latency

| framework | req/s | vs zfast | per core | p50 | p90 | p99 | CPU | ns CPU/req |
|---|---|---|---|---|---|---|---|---|
| **zfast** | **1,401,412** | 100% | 350,353 | 36µs | 46µs | **69µs** | 641% | 4,573 |
| http.zig | 1,389,678 | 99% | 347,419 | 38µs | 51µs | **65µs** | 606% | 4,361 |
| Rust axum | 1,197,545 | 85% | 299,386 | 46µs | 65µs | 226µs | 695% | 5,803 |
| Bun.serve ×8 | 1,170,614 | 84% | 292,654 | 42µs | 104µs | 3.12ms | 732% | 6,255 |
| Go Fiber v2 | 1,100,151 | 79% | 275,038 | 45µs | 125µs | 763µs | 753% | 6,841 |
| Node cluster ×8 | 698,643 | 50% | 174,661 | 90µs | 137µs | 260µs | 796% | 11,393 |
| Go net/http | 651,458 | 46% | 162,865 | 79µs | 289µs | 652µs | 717% | 11,008 |
| Bun.serve ×1 | 269,284 | 19% | — | 231µs | 250µs | 389µs | 104% | 3,879 |
| Node http ×1 | 141,271 | 10% | — | 446µs | 460µs | 663µs | 100% | 7,096 |

The bottom two rows are Node and Bun **as they ship** — one thread. That is not
a handicap invented for this table; it is what you get from `node server.js`,
and reaching the rows above it means `cluster.fork()` or `reusePort` and running
one process per core. The gap between a runtime's default and its tuned form is
larger here than the gap between most of the frameworks.

### The field is compressed, and that was predictable

[`benchmarks.md`](./benchmarks.md#the-number-that-reframes-the-budget) measured
zfast's own code at about 4% of a request's CPU, the other 96% being `epoll`,
`recv`, `send` and the TCP path. A comparison at this payload therefore mostly
measures the kernel, and the table agrees: the top five are inside 20% of each
other, and the two clear outliers below them differ by their **concurrency
architecture** — a goroutine pair per connection, or one thread — rather than by
anything about routing or serialisation.

So zfast finishing 0.8% ahead of http.zig is not a result. Two servers doing
roughly the same number of syscalls in roughly the same way landed in the same
place, which is what should happen. The honest reading of the top of that table
is *zfast is in the fastest group*, not *zfast is the fastest*.

### The tail is where zfast actually separates

That said, one column is not compressed at all. At identical client load:

| | p99 | relative |
|---|---|---|
| http.zig | 65µs | 0.9× |
| **zfast** | **69µs** | 1× |
| Rust axum | 226µs | 3.3× |
| Node cluster ×8 | 260µs | 3.8× |
| Go net/http | 652µs | 9.4× |
| Go Fiber v2 | 763µs | 11× |
| Bun.serve ×8 | 3.12ms | 45× |

Fiber is 21% behind on throughput and **11× behind on p99**. Bun with eight
processes is close on throughput and 45× behind at the tail — `SO_REUSEPORT`
hands accepts to whichever process the kernel picks, and it does not pick
evenly. These are the same 64 connections and the same 4 client threads for
every row, so unlike the saturation table in `benchmarks.md`, none of this is
client queueing.

This is the result that matters, and it is the one ADR 0018 already said to care
about: the budget's first row is "throughput **and** p99", not throughput.

## Memory per idle connection

This is the measurement that changed the code. As first measured, zfast was
**seventh of nine** at 16,961 bytes — http.zig held a connection in two thirds
of that, Bun in a fiftieth. Chasing why turned up something the number was
hiding, and the fix is described in
[`benchmarks.md`](./benchmarks.md#giving-the-pages-back): a keep-alive
connection was holding every page its buffers had ever touched, and now hands
them back between requests. zfast's row below is re-measured through the same
harness afterwards; nothing else moved.

| framework | B per idle connection | baseline RSS |
|---|---|---|
| Bun.serve ×8 | 338 | 257.6 MB |
| Bun.serve ×1 | 700 | 32.7 MB |
| **zfast** | **8,767** | **5.5 MB** |
| Node http ×1 | 10,543 | 48.5 MB |
| Node cluster ×8 | 10,594 | 440.5 MB |
| http.zig | 11,218 | 11.5 MB (caps at 8,192 connections) |
| Go Fiber v2 | 16,534 | 7.9 MB |
| Rust axum | 19,259 | 3.6 MB |
| Go net/http | 19,897 | 7.7 MB |

**Third of nine**, and the lowest of anything that is not Bun. What is left is
two pages of fiber stack and about 574 bytes of bookkeeping, paid the moment
`accept` returns and belonging to zio rather than to zfast.

The flatness is the part that has not changed and is worth as much as the level:
marginal cost is within 20 bytes of average from 1,000 connections to 10,000.
Nothing steps and no pool doubles in the background, which is what makes the
figure safe to multiply and what
[ADR 0018](./adr/0018-the-trade-budget-has-three-axes.md)'s third row is really
asking for. Bun gets to a smaller number a different way — uSockets allocates
lazily and pays with a 33 MB floor per process, 258 MB across eight.

Which framework is leaner still depends on how many connections are held, but
the crossings have moved a long way:

| against | |
|---|---|
| Rust axum | axum below 193 connections, zfast above |
| Bun.serve ×1 | zfast below 3,532 connections |
| Bun.serve ×8 | zfast below 31,352 connections |
| http.zig, Go Fiber, Go net/http, both Node rows | zfast lower at every count |

**What this means for the README.** "Low memory" was stated without a number and
would not have survived being given one. It survives 8,767: an idle server is
5.5 MB, ten thousand held connections are 91 MB, and every server here except
Bun is beaten at every count measured. The honest qualifier that remains is that
a connection which has served a large response holds a page of retained request
arena on top — 12,940 bytes rather than 8,762 — and that Bun is still an order
of magnitude below on the per-connection number alone.

One more thing this measurement turned up: **http.zig stops accepting at 8,192
connections** and does not refuse them, it just stops answering. That is
`workers.max_conn`, whose default is 8,192 against a default of one worker.
Configurable, and a `u16`, so 65,535 is the ceiling. zfast took 10,000 without
being asked to.

## Build time and binary size

Warm means one source file's **contents** changed — measured by appending a
line, not by `touch`, because Go and Zig hash file contents and a touch reports
a fake 0.0s.

The mode matters more than the framework, so both are here. **Dev** is what an
edit loop costs: `zig build`, `go build`, `cargo build`. **Release** is the
binary you ship: `-Doptimize=ReleaseFast`, `cargo build --release`, and for Go
whichever one it has, because Go does not offer the choice.

| framework | warm, dev | warm, release | cold, release | binary | stripped |
|---|---|---|---|---|---|
| Node / Bun | — | — | — | — | — |
| Go net/http | **0.2s** | 0.2s | 3.0s | 8.3 MB | 5.8 MB |
| Go Fiber v2 | **0.2s** | 0.2s | 4.1s | 9.7 MB | 6.7 MB |
| Rust axum | **0.2s** | 4.8s | 10.3s | 1.0 MB | 0.8 MB |
| http.zig | 0.3s | 9.3s | 9.9s | 4.2 MB | 0.6 MB |
| **zfast** | **0.4s** | **15.0s** | 15.5s | 6.0 MB | 1.1 MB |

**In the loop that a developer actually sits in, zfast is last by 0.2 seconds**
— 0.4s against Go's 0.2s. That is a difference nobody will feel, and it is the
column that ADR 0001's "developer experience comes first" is about.

The release column is a real 15 seconds and it is last, but it is worth knowing
what is in it before deciding to spend anything on it. Building the same
executable in each mode, warm:

| | |
|---|---|
| `zig build` (Debug) | 0.4s |
| `zig build -Doptimize=ReleaseSmall` | 4.6s |
| `zig build -Doptimize=ReleaseSafe` | 14.1s |
| `zig build -Doptimize=ReleaseFast` | 14.9s |

And building progressively less of zfast, warm, in `ReleaseFast`:

| | |
|---|---|
| a Zig hello world, no zfast at all | **7.1s** |
| zfast imported, `App` built, **zero** routes | 14.6s |
| the same with 32 routes | 16.6s |

**Half of the 15 seconds is a hello world.** Seven of them are what Zig and LLVM
charge any program at all for a release build, before a line of zfast is
involved. Another ~7.5s is zfast's library arriving as machine code for LLVM to
optimise. And the part that looks most expensive — the comptime typed layer,
one specialised handler generated per route — costs about **59ms per route**:
32 of them add 2.0s.

So the earlier reading of this, that "the typed layer is comptime and the root
file drives it", was wrong. Comptime is nearly free here. What is not free is
LLVM optimising the code that comes out the other side, and most of that bill is
addressed to Zig rather than to zfast.

The test step is the one place a real choice exists:

| | |
|---|---|
| `zig build test`, Debug only | **0.8s** |
| `zig build test`, Debug and ReleaseSafe (as it ships) | 7.8s |
| `zig build refusals` | 0.5s |

Running the suite in both modes costs 10× running it in one, and
[ADR 0019](./adr/0019-a-response-owns-its-headers.md) is the reason it does it:
a use-after-return passed in `Debug` for a whole stage and only failed in a
release build. That is a real trade with a real bug behind it, not an
accident — but it is currently paid on every `zig build test` rather than
before a commit.

One number in `build.zig` is now stale: the comment there says the refusals
"never cache" and cost "about 9 seconds on a warm `zig build test`". They cache
fine on Zig 0.16 and cost 0.5s.

The binary is fine — 1.1 MB stripped, second only to http.zig, and a sixth of
Go's.

## The scorecard

| | zfast's placing |
|---|---|
| Throughput | **1st of 9** — but inside the noise of http.zig |
| p99 under equal load | **2nd of 9**, and 3–45× ahead of everything outside the top two |
| CPU per request | 2nd of 9 |
| Memory, idle server | 2nd of 9 (5.5 MB) |
| Memory per connection | 3rd of 9 — was 7th before the fix this measurement caused |
| Warm rebuild, dev — the edit loop | 5th of 5 compiled, by 0.2s |
| Warm rebuild, release | **5th of 5 compiled**, and half of it is Zig's floor |
| Binary size, stripped | 2nd of 5 compiled |

## What this does not say

- **Nothing about a real deployment.** Loopback, one box, no NIC, no TLS, no
  database, no logging. A handler that touches Postgres makes every row in the
  throughput table identical.
- **Nothing about these frameworks in general.** Each is a ~50-line server
  written to match zfast's route. Fiber, axum and http.zig all have knobs that
  were left at their defaults, and so does zfast.
- **Nothing about correctness, features, or documentation**, which is most of
  what choosing a framework is actually about.
- **The single-threaded rows flatter themselves on CPU per request.** Bun ×1
  shows the lowest ns/req in the table partly because a server on one core has
  no cross-core cache traffic and no contention to pay for.
- **No statistical work.** Three runs and a median, spreads of 1–4%. Enough to
  separate 650k from 1.4M, not enough to separate zfast from http.zig — which is
  the point made above.
