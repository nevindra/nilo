# bench/compare-s3

Three other object-store clients, written against nilo's benchmark routes, so
the question "how does `nilo_s3` place?" has an answer somebody can re-run
rather than a number somebody remembers. The results are written up in
[`bench/result/s3.md`](../result/s3.md); this directory is how they were
produced.

**Separate from [`bench/compare/`](../compare/) rather than more candidates
inside it**, and not for tidiness. The two harnesses answer different questions
and one would contaminate the other:

- That one has **two** parties on the machine, a server and a load generator,
  and splits eight cores four and four. This one has **three** — the object
  store is a process too — and splits them three, three and two.
- That one runs with nothing installed. This one needs a container up and a
  bucket seeded before any candidate will start.

Nothing here shares a file with it, including the results.

Nothing here is built or run by `zig build`. It is out of the way on purpose —
a Zig repo should not need a Go toolchain to test itself.

## The rule the harness enforces

Seven routes, in three classes. **Three of the seven exist only to be
subtracted:**

| route | class | what it is |
|---|---|---|
| `/health` | floor | a constant, no store |
| `/warm/1k`, `/warm/1m` | floor | **the same bytes `/o/1k` and `/o/1m` answer with, and no object store anywhere near them** |
| `/o/1k`, `/o/64k`, `/o/1m` | store | one GET each, held whole |
| `/presign` | sign | the signer, no socket, no round trip |

The `/warm` pair is what makes the table mean anything. axum, `net/http`,
`Bun.serve` and nilo are not the same speed at answering a megabyte, so a table
of `/o/*` rows alone compares four HTTP servers wearing an S3 client as a hat.
What a client costs is `/o/1k` minus `/warm/1k` at the same size, and that
subtraction is the number to argue about.

**A `/warm` route must allocate and fill its buffer per request**, because that
is what the route it is subtracted from does: `/o/1m` sizes a buffer from
`content-length` and fills it every time. This is the one rule in the harness
that was got wrong first and caught by the numbers. Three of the four
candidates originally built the payload once at startup and handed out the same
slice — in Rust's case a `Bytes` clone, which is a refcount bump and no
allocation at all. That is not the same work minus the object store; it is less
work, and the control was flattering three candidates and not the fourth. The
tell was Go answering a megabyte 2.2× faster than nilo on the *control* route
while losing on every route that did real work.

Every candidate is verified on all seven routes before it is allowed a number,
byte for byte against bytes the harness builds itself. Its presigned URL is
then fetched by a client carrying no credentials — a signer that is fast and
wrong fails there rather than winning a row.

**One rule is enforced by reading the source rather than by the harness, and
that is a weakness worth naming.** Each candidate has to *hold* the object —
size a buffer from `content-length`, fill it, then answer — because that is
what nilo's bounded `get` does, and comparing it against a client that proxies
S3's socket straight to its own would be comparing two different operations.
All four do (`io.ReadFull`, `body.collect()`, `arrayBuffer()`, `bucket.get`),
but the payload check cannot tell the difference: a proxy produces the same
bytes and the same `Content-Length` while doing strictly less work. If a fifth
candidate ever arrives from somebody else, the way to make this mechanical is a
verification-only route answering a hash of the bytes the client read — a
server that never held them cannot compute it.

## The passes are interleaved, and a difference has to survive all of them

The obvious shape — three runs of `/o/1k`, then three of `/warm/1k` — puts a
quarter of an hour between the two halves of every subtraction, so anything
that drifts in that time lands wholly on one side and gets reported as what an
S3 client costs. Instead **one pass is all seven routes back to back**, and
there are three passes; each pass yields a paired difference taken seconds
apart. Every route is warmed before *any* of them is timed, so no route pays
for a cold process inside a pass.

A difference is reported only if **all three passes agree on its sign**, and
`drive.py` prints `<-- SIGN FLIPS, not a result` when they do not. A confidence
interval pooled across the three would not catch that: blocks within a pass are
not exchangeable with blocks in another, because each pass has its own thermal
state, and pooling narrows the interval on an assumption that is false.

**That rule filters noise. It does not certify a cost**, and the two are easy to
confuse. `table.py` applies the second test: **a client cannot cost negative
CPU, and two candidates running the same operation cannot disagree about the
sign of its cost.** Either of those means the subtraction is measuring the
machine. The 1 MB pair is exactly that case — it passes sign agreement with a
tight cluster and comes out *negative* for one candidate and positive for
another, because the floor route thrashes memory bandwidth, where a stalled
cycle still counts as CPU time, while the store route sits waiting on MinIO and
stalls less per byte. A route doing strictly more work then reports less CPU per
request than its own control.

`table.py` also flags a weaker case as `†`: where the floor route is saturated
and the store route is not, the subtrahend is measured under contention the
other half never sees, so what comes out is a **lower bound** on what the
client costs rather than the cost itself. That applies to every candidate in the
same direction, so the ratio between them survives even where the absolute does
not.

## Running it

```bash
docker run -d --name nilo-s3-minio -p 9100:9000 \
  -e MINIO_ROOT_USER=niloadmin -e MINIO_ROOT_PASSWORD=nilosecret123 \
  quay.io/minio/minio server /data
python3 ../s3_setup.py        # the bucket and the three objects

./build.sh
python3 drive.py              # all four candidates
python3 drive.py nilo go      # or just these

DURATION=20s REPEATS=5 python3 drive.py   # longer than the 10s x3 default
```

`python3 drive.py` runs everything and starts `results/raw.json` clean. Naming
candidates merges into what is already there and prints which rows it kept —
those are numbers this run did not take.

## Three parties, and the store gets its own cores

The store is a process, and one that lands wherever the scheduler puts it will
share silicon with whichever side happens to be busy. `drive.py` pins MinIO
with `docker update --cpuset-cpus` before it starts and says so in its first
line of output; if it could not, it says *that* instead, because an unpinned
store is a benchmark of the scheduler.

The defaults are this machine's — an AMD 9700X, 8 cores and 16 threads, with
cpu0's sibling being cpu8. **They are not portable.** Check your own topology
before trusting them:

```bash
cat /sys/devices/system/cpu/cpu0/topology/thread_siblings_list
```

Then override all three, which are not `bench/compare/`'s two and do not
inherit from them:

```bash
SERVER_CPUS=0-2,8-10 CLIENT_CPUS=3-5,11-13 MINIO_CPUS=6-7,14-15 \
  python3 drive.py
```

Three physical cores each to the server and the load generator, two to the
store. The HTTP harness gives four and four because it has nobody else to pay;
taking a fourth core each here would come out of MinIO's, and a store short of
CPU makes every candidate look the same — the one outcome that would tell us
nothing.

## What is here

| | |
|---|---|
| `drive.py` | pins the store, starts each server, verifies all seven routes, benchmarks them interleaved, measures idle-connection memory |
| `table.py` | turns `results/raw.json` into the tables `bench/result/s3.md` carries, derives server CPU as a share of the budget, and flags a subtraction that is a lower bound or void |
| `build.sh` | builds every candidate; skips whatever toolchain is missing, and says if the store is not up |
| `go/` | Go stdlib `net/http` + `aws-sdk-go-v2` |
| `rust/` | axum + the official `aws-sdk-s3` |
| `bun/` | `Bun.serve` + `Bun.S3Client`, which is itself native Zig — the closest thing to a like-for-like row |
| `bun/leakprobe.js` | not part of the comparison: three routes that narrow *where* Bun retains. See below |
| `results/` | the recorded run behind `bench/result/s3.md` |

nilo's own side is not here: it is [`bench/s3_server.zig`](../s3_server.zig),
built by `zig build bench-s3-server`, because it is nilo source and belongs
with the rest of it. It carries two routes the others do not — `/stream/1m` and
`/head/1k` — which are controls for nilo's own questions and are outside the
comparison.

Bun is measured twice, as it ships (one thread) and one process per core, for
the reason the HTTP comparison found: the distance between those two rows is
larger than the distance between most of the candidates.

## Bun cannot currently finish, and the harness does not survive it

**Read this before running `drive.py` with `bun1` or `bun6`.** Bun 1.3.13
retains about one byte for every byte `Bun.S3Client` reads and never releases
it. On `/o/64k` that is 4.5 GB in five seconds. Twice during this work it
reached 27 GB and was killed by the kernel's OOM killer — which is *global*, so
it also took down MinIO, an unrelated Postgres container, and the session
driving the benchmark. The measurements are in
[`bench/result/s3.md`](../result/s3.md#bun-did-not-finish-and-that-is-the-row).

Two consequences:

- **Confine `bun` when you run it here.** `systemd-run --user --scope -p
  MemoryMax=6G -p MemorySwapMax=0 …` turns a dead machine into a dead `bun`.
  `drive.py` does not do this yet, which is why it is written here.
- **`drive.py` has no DNF.** A candidate that dies mid-pass takes the whole
  sweep with it and leaves nothing recorded, so the three candidates that did
  finish had to be re-run. Naming candidates on the command line merges into
  `results/raw.json`, which is the workaround; a per-candidate route set and a
  recorded DNF is the fix.

`bun/leakprobe.js` is the next step on the Bun side and has not been run. It
separates the read path from the response path, which is the first thing a Bun
maintainer will ask.
