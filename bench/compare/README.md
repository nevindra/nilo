# bench/compare

Eight other HTTP servers, written against zfast's benchmark route, so the
question "how does it place?" has an answer somebody can re-run rather than a
number somebody remembers. The results are written up in
[`docs/comparison.md`](../../docs/comparison.md); this directory is how they
were produced.

Nothing here is built or run by `zig build`. It is out of the way on purpose —
a Zig repo should not need a Go toolchain to test itself.

## The rule the harness enforces

Every candidate must return **the same 982 bytes** that `src/main.zig` returns,
with the same content type, the same CORS header, and a 404 for a missing user.
`drive.py` builds that body itself and refuses to benchmark a server whose
response differs, which is how Node was caught returning 994 bytes — without an
explicit `Content-Length` it chooses chunked encoding, and the framing is 12
bytes nobody else was sending.

Each candidate also serialises its JSON per request. Pre-rendering the response
into a buffer would measure a different thing, and would flatter whichever
server did it.

## Running it

```bash
./build.sh                 # every candidate, including zfast
python3 drive.py           # all of them
python3 drive.py zfast httpzig    # or just these

DURATION=20s WARMUP=10s python3 drive.py    # shorter than the 30s default
```

Results land in `results/raw.json`, and the console output is worth keeping —
`results/run.log` is the one behind `docs/comparison.md`.

Build times and binary sizes are separate, because they must not run while a
benchmark is in flight:

```bash
./buildtimes.sh    # cold builds, then binary sizes
./warmbuilds.sh    # one source file's contents changed, then rebuilt
```

`warmbuilds.sh` edits `src/main.zig`, times the rebuild, and puts it back. It
prints `git status` for that file at the end so you can see it did.

## The core split is not portable

The defaults pin the server to `0-3,8-11` and the client to `4-7,12-15`, which
is four whole physical cores each **on the machine this was written on**. On an
SMT machine, CPUs 0–7 are usually not eight cores — they are eight of the
sixteen hardware threads, one per core, and pinning that way puts the server and
the load generator on the same silicon. Check first:

```bash
cat /sys/devices/system/cpu/cpu0/topology/thread_siblings_list
```

Then override:

```bash
SERVER_CPUS=0-5,12-17 CLIENT_CPUS=6-11,18-23 python3 drive.py
```

The reasoning, and what it cost to find out, is in
[`docs/benchmarks.md`](../../docs/benchmarks.md#how-the-cores-were-split-and-why-it-is-not-obvious).

## What is here

| | |
|---|---|
| `drive.py` | starts each server, verifies its payload, benchmarks it, measures idle-connection memory |
| `build.sh` | builds every candidate; skips whatever toolchain is missing |
| `buildtimes.sh` | cold build times and binary sizes |
| `warmbuilds.sh` | warm rebuild times, by changing file contents rather than `touch` |
| `debuginfo.sh` | the same, with and without debug info — the projects here disagree on the default, and it is half of a Zig release build |
| `gonet/` | Go stdlib `net/http`, method+wildcard `ServeMux` |
| `gofiber/` | Go Fiber v2, fasthttp underneath |
| `nodehttp/` | Node stdlib `http`; `CLUSTER=n` forks n workers |
| `bunhttp/` | `Bun.serve` with route patterns; `CLUSTER=1` turns on `reusePort` |
| `rustaxum/` | axum on hyper and tokio |
| `httpzig/` | http.zig, the in-language competitor |
| `results/` | the recorded run behind `docs/comparison.md` |

`python3 drive.py` runs everything and starts `results/raw.json` clean. Naming
candidates — `python3 drive.py zfast httpzig` — merges into what is already
there and prints which rows it kept. The rows it keeps are numbers this run did
not take, so a file built that way is not a single session, and
`docs/comparison.md` says which of its tables is one and which is not.

Node and Bun are measured twice — as they ship, which is one thread, and with
one process per core. The distance between those two rows is larger than the
distance between most of the frameworks, which is itself the finding.
