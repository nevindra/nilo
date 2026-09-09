# A cache that admits everything forgets what mattered

`nilo_cache` forgot in write order and nothing else. The ring lapped whatever
was oldest, a full bucket dropped its stalest way, and **no line in the module
recorded that an entry had ever been read**. A key asked for a million times
died at the same instant as one nobody asked for twice.

That was not a gap somebody left; it was measured as fine. The reason is the
benchmark, and it is the part of this worth remembering.

## The benchmark could not see the policy, by construction

`bench/cache_bench.zig` drew its keys uniformly at random. **Uniform random is
the one distribution where an eviction policy provably cannot matter**: every
key is equally likely next, so knowing which entries were read recently tells
you nothing about which will be read again. Under it every policy scores the
same, and that score is `capacity / working set`.

Which is exactly what
[ADR 0138](0138-a-cache-holds-its-bytes-under-a-lock-it-can-spin-on.md)
recorded — "hit rate is ring bytes over working-set bytes, to within a point,
at every size measured. **There is no cliff**" — and read as the FIFO window
being safe. The reading was right about what it measured. The straight line was
the harness, not the cache, and a straight line at exactly the theoretical
optimum should have been the tell.

Real traffic is Zipfian. Measured against the analytic ceiling for a stationary
Zipfian — the best a cache of K entries can do is hold the K most popular keys,
`zeta(K) / zeta(N)`, which nothing beats — the module was scoring 78% of it at
128 KiB and 85% at 512 KiB. On uniform random it scored 100%.

**A benchmark that cannot distinguish two designs will report that the worse one
is fine.**

## Two bits of frequency bought 0.7 points, and the arithmetic says why

The first fix was the cheap one: two bits taken out of the 16-bit fingerprint
for a saturating frequency counter, bumped on a hit, used to rank a bucket's
ways and to copy a warm entry back to the head before the cursor reached it.
Zero extra bytes. It moved Zipf 0.99 at 128 KiB from 52.4% to 53.1%.

A 128 KiB ring holds 2,137 entries. Every miss writes, at a 47% miss rate, so
the cursor laps every ~4,550 lookups. A key at rank 2,000 is asked for once
every 23,000. It is never warm when the cursor arrives. Only the top ~400 keys
are asked for even once per lap, and those cover 52.6% — the score it already
had.

**So the question was never which entry to save.** It is that every miss is
admitted, and on Zipfian traffic most misses are keys nobody will ask for
again. They were flushing the cache. In a single ring the victim is not chosen,
it is whoever the cursor reaches, so no rescue rule reaches this.

## The decision: two regions, and the doorkeeper is a question

A shard's ring is cut in two. A new entry goes into `small`, a tenth of it,
which therefore laps ten times as fast. **A key asked for a second time while
it is still there is copied into `main`** and gets the other nine tenths to
live in. One never asked for again never leaves the tenth it came in through.

This is S3-FIFO's shape. What is different here is that it costs no memory:
there is no ghost queue, no sketch and no extra field. Which region a slot is in
is read from its offset, so the admission test is **a second question rather
than a data structure** — "is this entry still in the tenth?" — and the answer
is one compare.

Inside `main` the frequency counter earns its two bits after all: a warm entry
the cursor is about to reach is copied back to the head, so `main` is a second
chance queue rather than a plain FIFO.

Zipf 0.99, 100,000 keys, 5M lookups, read-through:

| budget | before | after | ceiling | of best |
|---|---|---|---|---|
| 128 KiB | 52.4% | **64.2%** | 66.7% | 78% → **96%** |
| 512 KiB | 67.0% | **75.6%** | 78.3% | 85% → **96%** |
| 1 MiB | 74.9% | **81.4%** | 84.2% | 89% → **97%** |
| 4 MiB | 92.7% | **94.1%** | 96.1% | 96% → **98%** |

Zipf 0.9 is the same shape and a wider gap: 38.0% → 50.9% at 128 KiB.

**Read it as memory, which is what a cache is spending.** 75.6% used to need
1 MiB and now needs 512 KiB. Two to three times less memory for the same hit
rate, and the ratio is widest exactly where the budget is tightest — which is
the case the module is for.

## The table was twice the size the ring could fill

Separate from the policy and found while measuring it. `Store.open` gave the
table a quarter of the budget without knowing what the caller stores: a slot is
8 bytes, so a quarter is `bytes/32` slots, while a three-quarter ring holds an
entry of 12 header plus key plus value — about `bytes/61`. **Twice as many
slots as anything could point through**, paid for in memory and again in every
bucket probe that misses a larger table.

100,000 entries in a 4 MiB budget, small enough that the ring is what runs out:

| table share | held | bytes/entry | hit rate | 1 thread | 8 threads |
|---|---|---|---|---|---|
| 1/4 (what shipped) | 67,499 | 62.1 | 92.7% | 22.7M | 127.0M |
| **1/6** | **67,711** | **61.9** | **92.7%** | **24.4M** | **133.4M** |
| 1/8 | 59,498 | 70.5 | 91.5% | 28.4M | 148.6M |

A sixth costs nothing on the first three columns and is worth 7.5% on the
fourth. **An eighth is faster again and pays in hit rate, which is the wrong
currency**: an operation is 40 ns and a miss is a database round trip, so a
point of hit rate buys more than 25% of operation speed sells. That sentence is
the whole reason this module exists and it is worth having written down.

## A doorkeeper in front of empty space is not admission control

The first version of this sent every new entry through the tenth regardless,
and that is wrong in a way the hit rate does not show. A cache that is still
filling has nine tenths that nothing is competing for. Sending unread entries
through the tenth anyway took a store holding 78,875 entries down to 8,065, and
`perEntry` reported **520 ring bytes for a 16-byte value** against 53.

So the doorkeeper engages when there is something to keep out: while `main` has
never been round, admissions go straight to it. `main.gen == 1` says so and
costs a compare.

**The property that follows has to be stated rather than discovered.** `main`
advances only when something is promoted into it, so a cache written to and
never read holds its first entries indefinitely. That is harmless — nothing is
asking for them, and a TTL still expires them on read — but it is a real change
from "the ring forgets the oldest first", and two tests in `store.zig` now say
so: one that a working set which moves takes the old one's place, and one that a
key read twice survives a flood of keys read never.

## What else this cycle found, since both were the same mistake shape

**A third of a small budget was memory nothing could reach.** `shard_mask` is
`shards.len - 1` used as a bitmask, which is a modulo only when the count is a
power of two — and `Store.open` made the request a power of two and *then*
clamped it to `total_cap / 4096`. At the 64 KiB minimum on the default
`shards`, twelve shards were allocated and eight were reachable. At 192 KiB and
64 shards, 78% was unreachable. `bytesHeld()` counted all of it, so the number
the module's headline promise is made of was counting memory that could not
hold anything. Floored after the clamp; there is a test.

**The shard default was costing two thirds of the machine.** Every `get` takes
its shard's lock, so few shards turn a read-mostly load into a queue. Nine reads
to a write on eight cores: 16 shards 87.4M ops/s, 64 shards 125.0M, 256 shards
143.6M, and **256 shards with the lock removed altogether 145.6M**. The lock was
worth 1.4%; the shard count was worth 64%. ADR 0138's spin lock was right and
the contention it was blamed for was not its fault. 64 rather than 256 because
256 costs 4.5 points of hit rate at 512 KiB and 64 costs none at any size.

## What was rejected

**A seqlock, or any lock-free read.** Measured first: removing the lock
entirely, at 256 shards, buys 1.4% on eight threads and nothing at all on one
(29.4 ns against 29.3). ADR 0138 argued the lock is free uncontended and it is.
The design work this would have taken bought a rounding error.

**Tuning the rescue rule instead.** The arithmetic above: only the top ~400 keys
of 2,137 are asked for once per lap, so no threshold reaches the rest.

**A ghost queue or a frequency sketch.** Both are the standard answer and both
cost memory this module refuses to spend. The table already remembers a key
whose entry the ring took — `Stats.evicted` is that fact counted — so the ghost
is already there, and the two-region split gets the same admission property out
of the ring itself.

**Making `small` a fixed fraction of writes rather than of space.** It admits
one-hit-wonders into the main ring for a full lap, which is the thing being
prevented.

**Leaving the uniform-random benchmark as the only one.** It is kept, because
the contrast is the finding: a policy scoring 100% of best on uniform random and
78% on Zipf is how a cache hides a missing policy for a year.

## What it cost

**One thread is 8–10% slower**: `get` writes the slot's frequency on a hit until
it saturates, and `put` ranks eight ways by liveness and warmth rather than by
age. The first cut was 11–17%, and half of that was the ranking asking the same
question three times — the same-key check and the tier each called `live()`,
which called `regionOf`, which called `small.holds`, so eight ways cost
`regionOf` sixteen times. Reading liveness and region once a way gave back a
third of the loss.

Against +29% to +50% on eight threads and 2–3× the hit rate per byte, that is
the right side of the trade for a module whose caller is a server — and the
wrong side for a single-threaded program, which is worth saying rather than
burying.

**An entry costs 64.3 bytes against 63.3**, 1.6%, being the two regions
rounding separately. The older figure was a 2-core Xeon reading and the two are
not strictly comparable; `perEntry` on the new box reads 52.6 against 53.2 for a
16-byte value, the same figure moving the other way.

**Allocations per request: still none, and the signature still says so.**
Nothing here allocates and there is no allocator in the module.

The numbers, the machine and the three Go caches this was measured against are
in [`bench/result/cache.md`](../../bench/result/cache.md).
