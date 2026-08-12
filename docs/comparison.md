# zfast against other frameworks

[`benchmarks.md`](./benchmarks.md) ended with "no other framework was built or
run, so nothing here says how zfast places." This closes that gap. Eight other
servers were written against the same route, verified to return zfast's response
byte for byte, and run on the same four physical cores with the same load
generator.

The short version: **zfast is first on throughput and clearly first on tail
latency, mid-pack on memory per connection, and last on build time.** The two
places it loses are the ones worth reading.

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

Here zfast does not win, and the shape of the loss is worth more than the
throughput win.

| framework | B per idle connection | baseline RSS |
|---|---|---|
| Bun.serve ×8 | 338 | 257.6 MB |
| Bun.serve ×1 | 700 | 32.7 MB |
| Node http ×1 | 10,543 | 48.5 MB |
| Node cluster ×8 | 10,594 | 440.5 MB |
| http.zig | 11,218 | 11.5 MB (caps at 8,192 connections) |
| Go Fiber v2 | 16,534 | 7.9 MB |
| **zfast** | **16,961** | **5.5 MB** |
| Rust axum | 19,259 | 3.6 MB |
| Go net/http | 19,897 | 7.7 MB |

zfast is **seventh of nine** on the per-connection number. http.zig holds a
connection in two thirds of what zfast uses; Bun holds one in a fiftieth.

The reason is architectural rather than sloppy: zfast gives every connection its
buffers up front, which is exactly what makes the number so flat — the marginal
cost is within 17 bytes of the average from 500 connections to 10,000, and that
predictability is what
[ADR 0018](./adr/0018-the-trade-budget-has-three-axes.md) is really asking for.
Bun's uSockets allocates lazily and pays instead with a 33 MB floor. Both are
defensible. They are not the same claim.

Because zfast has the second-lowest baseline and a mid-pack slope, whether it is
the leaner choice depends entirely on how many connections you hold:

| against | zfast uses less below | and more above |
|---|---|---|
| Rust axum | — | 882 connections |
| http.zig | 1,083 connections | — |
| Bun.serve ×1 | 1,752 connections | — |
| Go Fiber v2 | 5,797 connections | — |
| Node http ×1 | 7,018 connections | — |
| Bun.serve ×8 | 15,897 connections | — |
| Go net/http | every count measured | — |

**What this means for the README.** "Low memory" is currently stated without a
number. With one, it is true of an idle server and true of a few thousand
connections, and it stops being true against http.zig at about a thousand and
against Bun at about seventeen hundred. The claim needs the qualifier or the
16 KB needs to come down — most plausibly by not handing a connection its write
buffer until it has something to write.

One more thing this measurement turned up: **http.zig stops accepting at 8,192
connections** and does not refuse them, it just stops answering. That is
`workers.max_conn`, whose default is 8,192 against a default of one worker.
Configurable, and a `u16`, so 65,535 is the ceiling. zfast took 10,000 without
being asked to.

## Build time and binary size

| framework | cold build | warm rebuild | binary | stripped |
|---|---|---|---|---|
| Node / Bun | — | — | — | — |
| Go net/http | 3.0s | **0.2s** | 8.3 MB | 5.8 MB |
| Go Fiber v2 | 4.1s | **0.2s** | 9.7 MB | 6.7 MB |
| http.zig | 9.9s | 9.3s | 4.2 MB | 0.6 MB |
| Rust axum | 10.3s | 4.8s | 1.0 MB | 0.8 MB |
| **zfast** | **15.5s** | **15.0s** | 6.0 MB | 1.1 MB |

Cold means an empty build cache with dependencies already downloaded. Warm means
one source file's **contents** changed — measured by appending a line, not by
`touch`, because Go and Zig hash file contents and a touch reports a fake 0.0s.

**zfast has the slowest edit-rebuild loop in the field, by a lot.** 15 seconds
against Go's 0.2 is 75×, and the audience this framework is written for is
coming from Go and Node, where a rebuild is not a thing you wait for.

Worse than the absolute number is that **warm is not meaningfully cheaper than
cold** — 15.0s against 15.5s. Changing one line of `src/main.zig` re-does
essentially the whole build, because the typed layer is comptime and the root
file is what drives it. http.zig shows the same pattern (9.3s against 9.9s) so
part of this is Zig, but zfast is 60% slower than http.zig on top of it, and
`history.md` already recorded `zig build test` going from 6.4s to 15.4s when
`refusals/` landed.

[ADR 0001](./adr/0001-dx-wins-below-the-10-percent-threshold.md) says developer
experience comes first and spends its whole budget on throughput. On the
evidence here that budget was aimed at the wrong axis: zfast bought a throughput
win that a user cannot perceive and is paying for it with a wait the user feels
on every single edit. Nothing in the three-axis budget of ADR 0018 has a row for
build time, and this table is the argument that it needs one.

The binary is fine — 1.1 MB stripped, second only to http.zig, and a sixth of
Go's.

## The scorecard

| | zfast's placing |
|---|---|
| Throughput | **1st of 9** — but inside the noise of http.zig |
| p99 under equal load | **2nd of 9**, and 3–45× ahead of everything outside the top two |
| CPU per request | 2nd of 9 |
| Memory, idle server | 2nd of 9 (5.5 MB) |
| Memory per connection | **7th of 9** |
| Cold build | **9th of 9** |
| Warm rebuild | **9th of 9** |
| Binary size, stripped | 2nd of 9 |

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
