# nilo against other frameworks

[`benchmarks.md`](./benchmarks.md) ended with "no other framework was built or
run, so nothing here says how nilo places." This closes that gap. Eight other
servers were written against the same route, verified to return nilo's response
byte for byte, and run on the same four physical cores with the same load
generator.

The short version: **nilo is first on throughput, clearly first on tail
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
whose body is not byte-identical to nilo's — that check caught Node returning
994 bytes, because without an explicit `Content-Length` it picks chunked
encoding and puts 12 bytes of framing on the wire nobody else was sending.

| | |
|---|---|
| Server | pinned to `0-3,8-11` — 4 physical cores and their SMT siblings |
| Client | pinned to `4-7,12-15` — the other 4 |
| Load | `wrk -t4 -c64`, 10s warm-up discarded, 3 × 20s, median reported |
| Machine | as in [`benchmarks.md`](./benchmarks.md#the-machine) — Ryzen 7 9700X, loopback |

What is **not** equal, and cannot be: response header sets differ, so bytes on
the wire run from 1,099 (http.zig) to 1,171 (Node) against nilo's 1,110. That
is a 6% spread on a ~1.1 KB response and it is part of what is being measured,
not an error in it.

Versions: Go 1.26.3, Fiber v2.52.14 (fasthttp 1.51), Node 24.16, Bun 1.3.13,
axum 0.8 with hyper 1.11 and tokio 1.53, http.zig at `c22672f`, Zig 0.16.0.

## Throughput and latency

| framework | req/s | vs nilo | per core | p50 | p90 | p99 | CPU | ns CPU/req |
|---|---|---|---|---|---|---|---|---|
| **nilo** | **1,401,412** | 100% | 350,353 | 36µs | 46µs | **69µs** | 641% | 4,573 |
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

**All nine rows above are one session**, and they are kept that way on purpose.
nilo has since been run through the same harness again — the run that produced
the memory figures below — and read 1,456,636 req/s with a p99 of 57µs. That is
4% above the row in the table, which is inside the run-to-run spread declared at
the bottom of this page and is not an effect of anything that changed in
between. The table keeps the session number, because a re-run that only one of
nine candidates got is not a comparison. `results/raw.json` holds the newer nilo
figures, so the two disagree by exactly this much and for this reason.

### The field is compressed, and that was predictable

[`benchmarks.md`](./benchmarks.md#the-number-that-reframes-the-budget) measured
nilo's own code at about 4% of a request's CPU, the other 96% being `epoll`,
`recv`, `send` and the TCP path. A comparison at this payload therefore mostly
measures the kernel, and the table agrees: the top five are inside 20% of each
other, and the two clear outliers below them differ by their **concurrency
architecture** — a goroutine pair per connection, or one thread — rather than by
anything about routing or serialisation.

So nilo finishing 0.8% ahead of http.zig is not a result. Two servers doing
roughly the same number of syscalls in roughly the same way landed in the same
place, which is what should happen. The honest reading of the top of that table
is *nilo is in the fastest group*, not *nilo is the fastest*.

### The tail is where nilo actually separates

That said, one column is not compressed at all. At identical client load:

| | p99 | relative |
|---|---|---|
| http.zig | 65µs | 0.9× |
| **nilo** | **69µs** | 1× |
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

This is the measurement that changed the code. As first measured, nilo was
**seventh of nine** at 16,961 bytes — http.zig held a connection in two thirds
of that, Bun in a fiftieth. Chasing why turned up something the number was
hiding, and the fix is described in
[`benchmarks.md`](./benchmarks.md#giving-the-pages-back): a keep-alive
connection was holding every page its buffers had ever touched, and now hands
them back between requests. nilo's row below is re-measured through the same
harness afterwards; nothing else moved.

| framework | B per idle connection | baseline RSS |
|---|---|---|
| Bun.serve ×8 | 338 | 257.6 MB |
| Bun.serve ×1 | 700 | 32.7 MB |
| **nilo** | **8,767** | **5.4 MB** |
| Node http ×1 | 10,543 | 48.5 MB |
| Node cluster ×8 | 10,594 | 440.5 MB |
| http.zig | 11,218 | 11.5 MB (caps at 8,192 connections) |
| Go Fiber v2 | 16,534 | 7.9 MB |
| Rust axum | 19,259 | 3.6 MB |
| Go net/http | 19,897 | 7.7 MB |

**Third of nine**, and the lowest of anything that is not Bun. What is left is
two pages of fiber stack and about 574 bytes of bookkeeping, paid the moment
`accept` returns and belonging to zio rather than to nilo.

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
| Rust axum | axum below 193 connections, nilo above |
| Bun.serve ×1 | nilo below 3,532 connections |
| Bun.serve ×8 | nilo below 31,352 connections |
| http.zig, Go Fiber, Go net/http, both Node rows | nilo lower at every count |

**What this means for the README.** "Low memory" was stated without a number and
would not have survived being given one. It survives 8,767: an idle server is
5.4 MB, ten thousand held connections are 91 MB, and every server here except
Bun is beaten at every count measured. The honest qualifier that remains is that
a connection which has served a large response holds a page of retained request
arena on top — 12,940 bytes rather than 8,762 — and that Bun is still an order
of magnitude below on the per-connection number alone.

One more thing this measurement turned up: **http.zig stops accepting at 8,192
connections** and does not refuse them, it just stops answering. That is
`workers.max_conn`, whose default is 8,192 against a default of one worker.
Configurable, and a `u16`, so 65,535 is the ceiling. nilo took 10,000 without
being asked to.

That last sentence was written as a win and it was not one. http.zig has a
number and nilo had none, which means http.zig's failure mode is a connection
that waits and nilo's was the machine running out — the OOM killer takes the
whole process, in-flight requests included. nilo now has a cap of its own,
`.max_connections`, defaulting to 10,000: past it a connection is closed at once
rather than left waiting, so a client finds out immediately
([deploying](./guide/deploying.md#how-many-connections-at-once)). The default
sits exactly at the top row of the memory table above, which is where the 9 KB
figure came from — a run that wants more than 10,000 connections has to raise it
first.

## Build time and binary size

Warm means one source file's **contents** changed — measured by appending a
line, not by `touch`, because Go and Zig hash file contents and a touch reports
a fake 0.0s.

There are three columns and not two, because these projects do not agree on
what a release build is. Rust's `[profile.release]` leaves debug info out unless
asked; Go and Zig both emit it and make you opt out. A single "release" column
had a Rust build that skips that work sitting next to a Zig build that does it,
which is most of what made the gap look the size it did. **Dev** is what an edit
loop costs: `zig build`, `go build`, `cargo build`. **◂** marks what each
project does when you do not tell it anything.

| framework | warm, dev | warm release, debug info | warm release, without | binary, debug info | without |
|---|---|---|---|---|---|
| Node / Bun | — | — | — | — | — |
| Go net/http | **0.2s** | 0.2s ◂ | 0.1s | 8.3 MB | 5.8 MB |
| Go Fiber v2 | **0.2s** | 0.2s ◂ | 0.2s | 9.7 MB | 6.7 MB |
| Rust axum | **0.2s** | 6.5s | **4.7s** ◂ | — | 1.0 MB |
| http.zig | 0.3s | 9.2s ◂ | 3.9s | 4.2 MB | 0.4 MB |
| **nilo** | **0.4s** | 14.7s | **7.4s** ◂ | 6.0 MB | 0.8 MB |

**In the loop that a developer actually sits in, nilo is last by 0.2 seconds**
— 0.4s against Go's 0.2s. That is a difference nobody will feel, and it is the
column that ADR 0001's "developer experience comes first" is about.

nilo is still last in a release build, by 2.7s against axum and 3.5s against
http.zig. But it was 15.0s against 4.8s before this measurement was taken, and
that reading had two different things in it: a genuine gap, and a default
nobody had noticed.

### Where a release build goes

Building the same executable, warm, and stopping at each stage:

| | |
|---|---|
| parse and sema — every comptime handler included | **0.5s** |
| and LLVM, with the debug info left out | 7.3s |
| and the debug info | 14.7s |
| the same, stopping before the link | 14.6s |

So the frontend is 3% of it, the linker does not appear at all, and **half of a
release build is debug info**. Two things are behind that. The DWARF has to be
generated — 1.9 MB of it — and its metadata is then carried through every
optimisation pass LLVM runs. And some of it is code that stops existing: with
no debug info to read, std's stack-trace machinery, a DWARF reader and an ELF
parser, is dead. `.text` goes from 787 KB to 498 KB.

Leaving it out costs nothing measurable at runtime — 1,996,698 req/s against
1,988,414, which is inside this machine's noise — and costs the file and the
line on every frame of a panic. So `zig build -Doptimize=ReleaseFast` now leaves
it out for the two binaries whose whole job is to be measured, and nothing else:
the examples and the tests keep theirs. `-Dstrip=false` gets the old behaviour
back, `-Dstrip=true` applies it to everything.

By mode, warm:

| | |
|---|---|
| `zig build` (Debug) | 0.4s |
| `zig build -Doptimize=ReleaseSmall` | 3.7s |
| `zig build -Doptimize=ReleaseFast` | 7.3s |
| `zig build -Doptimize=ReleaseSafe` | 13.9s |
| `zig build -Doptimize=ReleaseFast -Dstrip=false` | 14.6s |

### How much of it is nilo

Building progressively less, cold, in `ReleaseFast`:

| | with debug info | without |
|---|---|---|
| a Zig hello world, no nilo at all | 6.9s | 1.5s |
| nilo-hello | 14.7s | 7.3s |
| **what nilo's own code adds** | 7.8s | **5.8s** |

And the part that looks most expensive — the comptime typed layer, one
specialised handler generated per route — costs about **59ms per route**:
zero routes to 32 routes adds 2.0s, measured with debug info on.

So the earlier reading of this, that "the typed layer is comptime and the root
file drives it", was wrong twice over. Comptime is nearly free: half a second
for the entire frontend. What is not free is LLVM, and half of what LLVM is
doing was debug info that nobody had asked for.

One thing that is *not* a way out, since it looks like one: `-fno-llvm`, Zig's
self-hosted backend, builds the same binary in **0.31s** — 47× faster. The
binary does 615,264 req/s against 1,988,414, with a p99 of 555ms. It is not a
release build. And for the loop where a fast build is what matters, `Debug` is
already 0.4s.

The test step had the same shape of problem and was split for the same reason:

| | |
|---|---|
| `zig build test` — Debug, the loop | **0.6s** |
| `zig build test-all` — Debug and ReleaseSafe, what CI runs | 7.8s |
| `zig build refusals` (included in both) | 0.5s |

Running the suite in both modes costs 12× running it in one, and
[ADR 0019](./adr/0019-a-response-owns-its-headers.md) is why it is still run
both ways: a use-after-return passed in `Debug` for a whole stage and only
failed in a release build. What changed is when it is paid. `test-all` runs on
every push, so the rule is held by CI rather than by the edit loop.

The binary is 0.8 MB, second only to http.zig and a seventh of Go's — and
smaller than `strip(1)` on the old one, which came out at 1.1 MB, because the
code that was never generated cannot be stripped back out afterwards.

## The scorecard

| | nilo's placing |
|---|---|
| Throughput | **1st of 9** — but inside the noise of http.zig |
| p99 under equal load | **2nd of 9**, and 3–45× ahead of everything outside the top two |
| CPU per request | 2nd of 9 |
| Memory, idle server | 2nd of 9 (5.4 MB) |
| Memory per connection | 3rd of 9 — was 7th before the fix this measurement caused |
| Warm rebuild, dev — the edit loop | 5th of 5 compiled, by 0.2s |
| Warm rebuild, release | **5th of 5 compiled** — 7.4s, was 15.0s before this measurement |
| Binary size | 2nd of 5 compiled (0.8 MB) |

## What this does not say

- **Nothing about a real deployment.** Loopback, one box, no NIC, no TLS, no
  database, no logging. A handler that touches Postgres makes every row in the
  throughput table identical.
- **Nothing about these frameworks in general.** Each is a ~50-line server
  written to match nilo's route. Fiber, axum and http.zig all have knobs that
  were left at their defaults, and so does nilo.
- **Nothing about correctness, features, or documentation**, which is most of
  what choosing a framework is actually about.
- **The single-threaded rows flatter themselves on CPU per request.** Bun ×1
  shows the lowest ns/req in the table partly because a server on one core has
  no cross-core cache traffic and no contention to pay for.
- **No statistical work.** Three runs and a median, spreads of 1–4%. Enough to
  separate 650k from 1.4M, not enough to separate nilo from http.zig — which is
  the point made above.
- **The second build column needed a knob http.zig does not ship.** Its
  `-Dstrip` is three lines added to the harness's own `build.zig`, defaulting to
  what http.zig would do on its own, purely so both Zig projects could be
  measured both ways. axum's column used `CARGO_PROFILE_RELEASE_DEBUG`; editing
  `Cargo.toml` instead invalidates the dependency graph and reports 12.5s, which
  is a rebuild of tokio, not a warm build.
