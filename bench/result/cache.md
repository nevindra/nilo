# nilo_cache

What one operation costs, what one entry costs to hold, **what fraction of
lookups the cache actually answers**, and how all three compare with the seven
other caches that answer the same question: three in Go (§3), two in Rust and
two in Zig (§4).

Machine: AMD Ryzen 7 9700X, 8 physical cores / 16 threads, 30 GiB, Ubuntu
26.04, kernel 7.0.0-31-generic. Zig 0.16.0, Go 1.25 (nix), both sides
ReleaseFast / `go build`.

**Every number in the previous version of this file was taken on a 2-core Xeon
and none of them survived being re-taken on a machine with cores.** That is not
a footnote: the module's whole job is serving a request path from several
fibers at once, and on two cores the question cannot be asked. The concurrency
rows below are the first ones this module has ever had.

## The headline

Against [freecache](https://github.com/coocood/freecache), which is the same
design in another language — a fixed byte budget, a segmented ring, a copy into
the caller's buffer:

| | nilo_cache | freecache | |
|---|---|---|---|
| reads a second, 8 threads | **135.0–136.0M** | 46.8–47.0M | **2.9×** |
| bytes an entry | **64.3** | 132.0 | **2.1×** |
| hit rate, Zipf 0.99, 512 KiB | **75.6%** | 67.5% | +8.1 points |

Three interleaved rounds a side, and both spreads are under 1%: nilo 135.8,
136.0, 135.0 against freecache 47.0, 46.9, 46.8. The margin is 290 times its
own spread, which is the only condition under which it may be quoted as a
figure rather than a range.

Throughput and memory multiply, because a cache serving nearly three times the
traffic out of half the memory is doing both: **5.9× the work per byte.**
Against [bigcache](https://github.com/allegro/bigcache) it is 6.1× (2.6× and
2.3×), and against [go-cache](https://github.com/patrickmn/go-cache) at eight
threads, 11.4× (7.3× and 1.6×).

**Every one of those is a product of two measurements and should be read as
one.** No single axis is 5×: the throughput is 2.6–7.3× depending on the
competitor, and the memory is 1.6–2.3×. What multiplies them is that they are
independent — the cache is not trading one for the other, which is the thing
that was in doubt.

**And one cache in this comparison is faster than nilo.** Rust's quick_cache
reads about 1.6× as fast on eight threads. It costs 105.4 bytes an entry
against 64.3, so the product is close to a wash. §4 is where the comparison
lives, **§5 is where its source was read** — because the first explanation
written here was wrong: quick_cache does not keep values in its table and does
not pay one cache miss to nilo's two, it pays two as well — and **§6 is what
was done about it**. A `get` now takes no lock at all: +13.3% on eight threads,
unchanged on one, hit rate up 0.1 to 0.3 points, and the gap to quick_cache down
from 1.81× to 1.60×.

## 1. What changed, and what each piece was worth

Four changes, in the order they were made and measured.

### A third of a small budget was memory nothing could reach

`shard_mask` is `shards.len - 1` used as a bitmask, which is a modulo only when
the count is a power of two. `Store.open` made the requested count a power of
two and *then* clamped it to `total_cap / 4096`, which is any number at all.

| budget | shards allocated | shards reachable | wasted |
|---|---|---|---|
| 64 KiB, default `shards` | 12 | 8 | **33%** |
| 192 KiB, `shards = 64` | 36 | 8 | **78%** |

64 KiB is the smallest budget the module accepts and 16 was the default, so
this was the standard configuration. `bytesHeld()` counted all twelve, which
means the number the module's headline promise is made of was counting memory
that could not hold anything. Flooring after the clamp fixes it; the property
is now a test rather than a paragraph.

### The shard default was costing two thirds of the machine

Every `get` takes its shard's lock, so few shards turn a read-mostly load into
a queue. Nine reads to a write, 8 threads, 64 MiB store:

| shards | 1 thread | 8 threads | scaling |
|---|---|---|---|
| 16 (the old default) | 25.1M | 87.4M | 3.5× |
| **64 (the new one)** | 23.9M | **125.0M** | 5.2× |
| 256 | 23.6M | 143.6M | 6.1× |
| 256, **lock removed entirely** | 25.1M | 145.6M | 5.8× |

**The last row is why there is no seqlock.** Taking the lock out altogether
buys 1.4% over 256 shards, and nothing at all on one thread — 29.4 ns against
29.3 ns. ADR 0138's spin lock was right, and the contention it was blamed for
was the shard count.

64 rather than 256 because 256 starts costing retention on small stores: on
Zipf 0.99 it loses 4.5 points at 512 KiB, where each shard's ring is too small
to hold what hashes to it. At 64 the two are within 0.1 of a point at every
budget measured, so it is free.

### The benchmark could not see the eviction policy at all

`bench/cache_bench.zig` picked its keys uniformly at random, and **uniform
random is the one distribution where an eviction policy provably cannot
matter**: every key is equally likely next, so knowing which entries were read
recently says nothing about which will be read again. Under it the cache scored
100% of the achievable ceiling at every size, which is what produced ADR 0138's
"hit rate is ring bytes over working-set bytes, to within a point — there is no
cliff". That reading was correct and it was about the harness.

The ceiling is analytic. For a stationary Zipfian the best any cache holding K
entries can do is hold the K most popular keys, so its hit rate is
`zeta(K) / zeta(N)`; nothing beats it and Belady does not need implementing to
say so.

Zipf 0.99, 100,000 keys, 5M lookups, read-through:

| budget | before | after | ceiling | of best, before → after |
|---|---|---|---|---|
| 128 KiB | 52.4% | **64.2%** | 66.7% | 78% → **96%** |
| 256 KiB | 59.5% | **69.8%** | 72.5% | 82% → **96%** |
| 512 KiB | 67.0% | **75.6%** | 78.3% | 85% → **96%** |
| 1 MiB | 74.9% | **81.4%** | 84.2% | 89% → **97%** |
| 4 MiB | 92.7% | **94.1%** | 96.1% | 96% → **98%** |

Zipf 0.9 is the same shape and a wider gap: 38.0% → 50.9% at 128 KiB, 71% → 94%
of best.

### The table was twice the size the ring could fill

`Store.open` gave the table a quarter of the budget without knowing what the
caller stores. A slot is 8 bytes, so a quarter is `bytes/32` slots; an entry is
12 of header plus the key plus the value, about 46 bytes for this shape, so a
three-quarter ring holds `bytes/61`. **Twice as many slots as anything could
ever point through**, paid for once in memory and again in every bucket probe
that misses a larger table.

100,000 entries in a 4 MiB budget, which is small enough that the ring is what
runs out — at 16 MiB every column read the same and the surplus was invisible:

| table share | held | bytes/entry | hit rate | 1 thread | 8 threads |
|---|---|---|---|---|---|
| 1/4 (what shipped) | 67,499 | 62.1 | 92.7% | 22.7M | 127.0M |
| **1/6** | **67,711** | **61.9** | **92.7%** | **24.4M** | **133.4M** |
| 1/8 | 59,498 | 70.5 | 91.5% | 28.4M | 148.6M |
| 1/12 | 42,343 | 99.0 | 88.7% | 32.7M | 165.3M |

A sixth costs nothing on the first three columns and is worth 7.5% on the
fourth, so it is the new default. **An eighth is faster again and pays for it
in hit rate, which is the wrong currency**: an operation is 40 ns and a miss is
a database round trip, so a point of hit rate buys more than 25% of operation
speed sells.

**Read as memory, which is what it is for:** 75.4% used to need 1 MiB and now
needs 512 KiB, and 63.9% used to need about 400 KiB and now needs 128 KiB.
**Two to three times less memory for the same hit rate**, and the gap is widest
exactly where the budget is tightest.

### Why the first attempt at the policy bought 0.7 points

Two bits taken out of the fingerprint for a frequency counter, bumped on a hit,
used to order a bucket's ways and to move a warm entry out of the write
cursor's way. Measured: 52.4% → 53.1%. Nearly nothing, and the arithmetic says
why.

A 128 KiB ring holds 2,137 entries. Every miss writes, and the miss rate is
47%, so the cursor laps every ~4,550 lookups. A key at rank 2,000 is asked for
once every 23,000 lookups. **It is never going to be warm when the cursor
arrives.** Only the top ~400 keys are asked for even once per lap, and they
cover 52.6% — which is the number that was already being scored.

So the problem was never which entry gets saved. It is that **every miss is
admitted**, and on Zipfian traffic most misses are keys nobody will ask for
again. They were flushing the cache. In one ring the victim is not chosen — it
is whatever the cursor reaches — so no amount of tuning the rescue rule reaches
it. That took two regions.

## 2. Where an operation's time actually goes

20M rounds, one thread, working set in L2, keys built before the clock starts.
Each row adds one piece to the row above it.

| | ns/op |
|---|---|
| the loop, the PRNG and the key lookup (the harness) | 2.0 |
| + Wyhash of the key | 3.7 |
| + `CLOCK_MONOTONIC_COARSE` | 5.6 |
| **the whole `get`** | **29.3** |
| `std.StringHashMap.get`, no lock and no ring | 11.9 |

**The remaining 23.7 ns is two dependent cache misses**, and that is the
ceiling on this design: a slot points at a ring, so the second load cannot
start until the first returns. A hash map keeps the key beside the probe and
pays one. Closing that gap means putting entries in the table, which is the
design that cannot bound its own memory — so 5–10× on a single-threaded
operation is not available here, and the concurrency rows are where the
throughput is.

The two clocks, for the record: `MONOTONIC_COARSE` 1.6 ns, `MONOTONIC` 15.6 ns.
ADR 0138's choice is worth 14 ns an operation.

## 3. Against the Go three

Same box, same load, same 50,000 keys built before the clock starts, same
24-byte flat value and 512-byte page, same nine-reads-to-a-write mix. freecache
and bigcache are given `GetWithBuf` and a caller's buffer — the calls that
match what nilo does — rather than the allocating ones.

**Eight threads**, which is the question a server asks:

| | nilo_cache | freecache | bigcache | go-cache |
|---|---|---|---|---|
| get_flat, in cache | **143.2–143.7M** | 48.5M | 54.3M | 19.4M |
| get_flat | **135.0–136.0M** | 46.8–47.0M | 51.4–52.2M | 18.5M |
| put_flat | **90.2M** | 46.4M | 25.9M | 11.3M |
| mixed_flat | **117.6–120.2M** | 44.7–45.3M | 17.0–17.3M | 28.2M |
| get_page | **72.8M** | 32.8M | 21.1M | 18.0M |
| mixed_page | **51.1M** | 32.1M | 9.0M | 25.1M |

**The two rows carrying ranges were interleaved three times a side; the rest
are one round a cell** and should be read as the shape rather than as four
significant figures.

**One thread**, where the answer is different and the reason is worth stating:

| | nilo_cache | freecache | bigcache | go-cache |
|---|---|---|---|---|
| get_flat, in cache | 38.1M | 12.4M | 14.2M | **55.6M** |
| get_flat | 25.2M | 8.7M | 9.4M | **30.7M** |
| mixed_flat | 21.9M | 8.7M | 8.1M | **35.9M** |
| get_page | 10.2M | 5.3M | 3.5M | **31.5M** |

**go-cache wins on one thread and loses badly on eight**, and both halves are
the same fact. It hands back a pointer into memory a collector owns, so a
512-byte value costs sixteen bytes of string header rather than a `memcpy` —
and it has one `RWMutex` for the whole map, so eight threads is 18.5M where one
was 30.7M. It goes backwards. nilo beats freecache and bigcache on one thread
by 2.4–2.9× and everything on eight by 1.6–2.7×.

### What 200,000 entries cost to hold

RSS on both sides, Go given a `runtime.GC()` and a `debug.FreeOSMemory()` first,
each cache given the smallest budget that still held 98% of them.

| | bytes/entry | retrievable | is the budget the whole memory |
|---|---|---|---|
| **nilo_cache** | **64.3** | 98.8% | **yes — 12,581,888 held against a 12 MiB budget** |
| go-cache | 100.2 | 100% | no bound at all |
| freecache | 132.0 | 99.9% | no — 25.2 MiB of RSS on a 12 MiB budget |
| bigcache | 149.4 | 100% | no — 28.5 MiB of RSS on a 12 MiB budget |

**The last column is the one that is easy to miss.** Both Go ring caches bound
the bytes their *values* occupy and put the index on top of it, unbounded, so
the number a caller sets is about half of what the machine gives up.
`bytesHeld()` is the whole of nilo's, and the test that says so is in
`store.zig`.

### Hit rate, the same trace on all four

Zipf 0.99, 3M lookups, read-through. go-cache is absent because it has no
eviction at all — it grows until the process dies, so it always scores 100% and
the row would mean nothing.

| budget | nilo_cache | freecache | bigcache |
|---|---|---|---|
| 512 KiB | **75.6%** | 67.5% | 76.7%* |
| 1 MiB | **81.4%** | 75.6% | 76.7% |
| 2 MiB | **87.6%** | 84.3% | 85.4% |
| 4 MiB | 94.1% | 93.3% | **94.5%** |
| 8 MiB | **97.9%** | 96.7% | 96.7% |

\* **Neither Go cache can be asked the question at the sizes where it matters.**
freecache floors at 512 KiB and bigcache at 1 MiB, so every row below those is
the same cache measured repeatedly — bigcache's 512 KiB entry is a 1 MiB cache
and is not a comparison. At the sizes all three can express, nilo is ahead
everywhere except 4 MiB, where bigcache is 0.4 points up and both are within
their own spread.

## 4. Against Rust and Zig

Four more caches in the two languages that take this question seriously, plus
three of zigache's five policies. Same 50,000 keys built before the clock, same
24-byte value, same nine-reads-to-a-write mix, same fresh cache a row.

**Every absolute in this section is about 25% below §3 and the ratios are
not.** These were taken on a different day, with a browser holding a core and a
load average of 4.0: nilo's own `get_flat` reads 103M here where §3 says 135M.
Every round was interleaved, so both halves of every ratio moved together —
which is the only reason anything below is quotable.

### Eight threads

| | get_flat | mixed_flat | against nilo |
|---|---|---|---|
| **quick_cache** (Rust) | **161M** | 117–156M | **1.56× faster than nilo** |
| **nilo_cache** | 103M | 93M | |
| zigache S3FIFO | 68.5M | 68M | nilo 1.50× |
| zigache W-TinyLFU | 66.5M | 51.6M | nilo 1.55× |
| zigache LRU | 60M | 58.6M | nilo 1.72× |
| cache.zig, 64 segments | 43.4M | 35M | nilo 2.40× |
| cache.zig, 8 (its default) | 40.6M | 20.2M | nilo 2.54× |
| moka (Rust) | 9.9M | 9.5M | nilo 10.4× |

Six interleaved rounds for nilo (96.9, 101.1, 102.7, 106.9, 107.9, 100.7) and
three a side for the rest. quick_cache's `mixed_flat` is a range because its
three rounds were 116.5, 117.1 and 155.9 and a margin wider than its own spread
is quoted as a range or it is quoted wrong.

**quick_cache is faster than nilo, and the explanation first written here was
wrong.** It said quick_cache keeps values in its table and so pays one cache
miss to nilo's two. Reading `shard.rs` says otherwise: its `map` is a
`HashTable<Token>` holding a `u32`, and the key and value live in a separate
`LinkedSlab`, so a lookup is a probe and then a dependent load into the slab.
**Two, the same as nilo.** §5 has what the difference actually is.

**moka is the one that does not scale, and it is not close.** It has the
strongest replacement policy in the comparison, and 9.9M reads a second on
eight threads against 3.8M on one is a speed-up of 2.6× on eight cores. Its
writes go through a queue a later read drains, and that queue is the whole
story.

### One thread

| | get_flat | against nilo |
|---|---|---|
| quick_cache | **29.5M** | 1.42× faster than nilo |
| **nilo_cache** | 20.8M | |
| zigache W-TinyLFU | 15.5M | nilo 1.34× |
| zigache S3FIFO | 15.0M | nilo 1.39× |
| zigache LRU | 13.5M | nilo 1.54× |
| cache.zig/8 | 7.3M | nilo 2.8× |
| cache.zig/64 | 5.7M | nilo 3.6× |
| moka | 3.8M | nilo 5.5× |

Unlike the Go table, nothing here wins on one thread and loses on eight. Both
Rust caches keep their ordering and both Zig ones do too.

**The 1.42× against quick_cache is mostly this harness, and §5 takes it apart.**
`bench/cache_bench.zig` opens a 64 MiB store for 50,000 keys, which is an 11 MiB
table; quick_cache was given 100,000 entries and builds about 1 MiB. Given a
budget matched to the working set nilo reads 26.1M against quick_cache's 29.3M,
and the gap is 1.12× rather than 1.42×.

### What 200,000 entries cost to hold

RSS, one cache a process. **nilo is the smallest of all eight caches measured
in this file**, and it is the only one whose budget is the whole of its memory.

| | bytes/entry | retrievable | notes |
|---|---|---|---|
| **nilo_cache** | **64.3** | 98.8% | 12,581,888 held against a 12 MiB budget |
| go-cache | 100.2 | 100% | no bound at all |
| **quick_cache** | 105.4 | 99.3% | bounds a count, not bytes |
| freecache | 132.0 | 99.9% | 25.2 MiB of RSS on a 12 MiB budget |
| zigache S3FIFO | 140.2 | 99.1% | **and it does not copy the key** |
| zigache LRU | 140.2 | 99.1% | the same |
| bigcache | 149.4 | 100% | 28.5 MiB of RSS on a 12 MiB budget |
| cache.zig | 212.1 | 92.5% | a segment shrinks by a fifth when it fills |
| moka | 384.7 | 100% | |

zigache's row is a **floor rather than a total**: its `put` stores the caller's
slice and its documentation says the key has to stay valid for as long as it is
in the cache, so twelve bytes of key an entry are somebody else's memory.
nilo, cache.zig, freecache and bigcache all copy it.

zigache's W-TinyLFU is not in the table. It read 143.7 bytes an entry while
holding 20.8% of what it was given, because a fill of distinct keys with no
repeats is exactly what its admission policy exists to reject. That is correct
behaviour and it is not a memory measurement.

### Hit rate, the same trace, at the same number of entries

Zipf 0.99, 3M lookups, read-through. Every count-bounded cache is given exactly
the entries nilo held at that budget, which measures the policy and nothing
else. **This is the reading that flatters the others most**, because it hands
them for free the memory efficiency that is nilo's whole argument.

| entries | nilo | quick_cache | moka | zigache TinyLFU | zigache S3FIFO | zigache LRU | cache.zig |
|---|---|---|---|---|---|---|---|
| 2,086 | 64.2% | **65.1%** | 64.5% | 63.0% | 60.8% | 55.8% | 52.5% |
| 4,159 | 69.8% | **70.9%** | 70.5% | 69.1% | 67.3% | 62.9% | 59.6% |
| 8,223 | 75.6% | **76.5%** | 76.4% | 75.0% | 73.5% | 70.3% | 66.9% |
| 16,283 | 81.4% | **82.1%** | 81.9% | 80.5% | 79.8% | 77.7% | 74.6% |
| 32,438 | 87.6% | **87.8%** | **87.8%** | 86.1% | 86.4% | 85.6% | 82.9% |
| 64,081 | **94.1%** | 93.7% | 93.6% | 92.0% | 93.0% | 93.3% | 91.6% |

**nilo beats every Zig cache at every size and loses to both Rust caches by
0.2–1.1 points at five of six.** Being level with Caffeine's descendant on
policy, with no ghost queue and no sketch, is the result ADR 0187 was after.
The Zig side is the one that says the two regions are worth something: zigache
implements S3-FIFO properly, with a ghost queue and a per-node frequency, and
is 1.6–3.4 points behind.

**One premise here was checked and was wrong, which is why the harness prints a
`held` column.** zigache's S3FIFO counts its ghost queue against `cache_size`,
so reading `s3fifo.zig` says a cache asked for N holds 0.55N — and measuring
says it holds 0.996N, because a demoted node keeps its value and `get` answers
from it without looking at which queue it is in. Had the reading been trusted,
every zigache row above would have been corrected by 1.8× in the wrong
direction.

### The same table read as memory, which is what a budget is

The rows above give every competitor the entry count nilo achieved. A caller
does not have an entry count. A caller has a machine. So: **how many entries
does each of them fit in 512 KiB, and what does it score there?**

| | bytes/entry | entries in 512 KiB | hit rate |
|---|---|---|---|
| **nilo_cache** | 64.3 | **8,223** | **75.6%** |
| quick_cache | 105.4 | 4,977 | ~72.0% |
| zigache S3FIFO | 140.2 | 3,742 | ~66.0% |
| moka | 384.7 | 1,364 | ~59% |
| cache.zig | 212.1 | 2,474 | ~53.8% |

The hit rates in the last column are interpolated between the two measured
rows either side, and are marked `~` for that reason. **The ordering is not
interpolated and neither is the first column.** Against quick_cache that is
+3.6 points of hit rate on the same memory, and against everything else it is
between 9 and 22.

Throughput times entries-per-byte, which is the product §"The headline" uses:
**62× moka, 7.9× cache.zig, 3.3× zigache, and 1.05× quick_cache** — a wash
against quick_cache, which is the honest summary of that one.

## 5. What quick_cache does differently, and what of it nilo can have

quick_cache is the only cache in this comparison that is faster than nilo, so
its source is worth more than its number. It is a modified Clock-PRO, which the
crate's own header says is "very similar to the later published S3-FIFO" — the
same family as ADR 0187's two regions. So the policy is not the difference.
Five differences are, and the measurements below say which of them matter.

Everything in this section was measured on the same box with the browser still
holding a core, at an **8 MiB budget rather than the 64 MiB `bench-cache`
uses**, so that both sides get a table sized for 50,000 keys. Each row is three
or four interleaved rounds.

### Where nilo's eight-thread figure actually goes

Four builds of `cache/`, identical except where named. `A` is what ships.

| | 8 threads | vs A | 1 thread |
|---|---|---|---|
| **A** — what ships, 64 shards | 82–85M | | 26.1M |
| A at 256 shards | 86.4M | +5% | |
| A at 1024 shards | 88.8M | +8% | |
| **B** — the lock removed entirely | 94.1M | **+10%** | 25.9M |
| **C** — `get` writes nothing, lock kept | 99.5M | **+16%** | 28.5M |
| **D** — both | 109–114M | **+32%** | |
| quick_cache | 159–176M | +100% | 29.3M |

Three things fall out of that table and each one changes what to do next.

**Raising `shards` is not the answer.** Four times the shards buys 5% and
sixteen times buys 8%, against 32% for changing what a `get` does. ADR 0187 put
the shard count at 15% on a 64 MiB store, and on a store sized for its working
set it is a third of that. The default stays at 64.

**`get` being a writer costs more than the lock does.** Removing the lock and
leaving the writes is worth 10%; keeping the lock and removing the writes is
worth 16%. nilo's `get` writes three things: `stats.hits`, which dirties the
shard's line on every single read; `slot.freq`, already guarded by
`if (slot.freq < warm)` so nearly free once a key is hot; and `shard.carry`,
which is a **whole-entry `memcpy` performed inside a read** on a hit in `small`
and on the rescue path.

**On one thread there is nothing to fix.** A is 26.1M against quick_cache's
29.3M, and C is 28.5M against the same 29.3M. Per-operation the two are level.
The whole of the remaining difference is that quick_cache's readers run at the
same time and nilo's queue.

### The five differences, and which ones are the 32%

| | nilo_cache | quick_cache |
|---|---|---|
| bound | **bytes** | entries, or a weight the caller invents |
| storage | one ring of bytes, entries variable-size | `Vec<Entry>` slab, one fixed slot an entry |
| index | 8-way bucket, 14-bit fingerprint, 8-byte slot | `HashTable<Token>` holding a `u32` |
| **loads per hit** | **two dependent** | **two dependent** |
| lock | exclusive spin, taken by every `get` | `RwLock`; `get` takes it **shared** |
| what a hit writes | `stats`, `freq`, sometimes a whole entry | one relaxed `fetch_add`, and only below `MAX_F` |
| promotion | in `get`, by copying the entry | at eviction, by relinking two `u32`s |
| ghost record | none | 0.5 × capacity of **full-size** slots holding a `u64` |
| stats | always counted | a cargo feature, **off by default** |

**Row four is the correction.** quick_cache's `map` stores a `Token` and the
`get` closure dereferences the slab to compare the key, so it misses on the
probe and again on the slab exactly as nilo misses on the bucket and again on
the ring. Item 1 of §9 is still a real lever and it is **not** what quick_cache
is exploiting.

### Three things worth taking

**1. Stop `get` writing, and take the lock shared. Worth 32%, measured.** The
promotion is the only hard part: it has to move out of the read and into the
next `put`, which forgets a `small` entry only if its `freq` is zero. That is
what S3-FIFO's paper says to do and what zigache does; nilo promotes eagerly
instead, and pays a `memcpy` per hit for it. `freq` then becomes an atomic
bumped under a shared lock, with the saturation guard it already has. Stats move
to their own cache line or behind a flag. **Costs nothing on ADR 0018's four
axes** — no allocation, no per-entry byte — but it is a different policy, so
the hit rate has to be re-measured rather than assumed.

**2. A ghost list nilo already pays for and does not read.** quick_cache's
hit-rate edge is its ghost: an evicted key's hash stays in the table, and when
that key comes back it is admitted **straight to hot**, skipping probation.
nilo already holds that record. A slot whose fingerprint matches the key being
inserted but whose `gen` is stale means *this key was here and the ring took
it* — and `put`'s first loop already walks exactly those ways and `continue`s
past them. Setting a flag there and sending the entry to `main` instead of
`small` is the same mechanism for **zero extra memory**. ADR 0187 wrote "the
ghost is already there" and then did not use it.

**3. Counting hits should be opt-in.** quick_cache's `hits`/`misses` are behind
`#[cfg(feature = "stats")]` and off by default; nilo's are unconditional and
sit in the shard's hot line. Part of C's 16% is that increment.

### Two things not to take

**Bounding a count instead of bytes.** The whole argument of this module.

**Paying for the ghost in full-size slots.** quick_cache's ghost entries occupy
a complete `Entry` in the slab to hold a `u64` hash, which is where a good part
of 105.4 bytes an entry against 64.3 goes. Idea 2 above gets the same property
out of eight bytes nilo has already spent.

And one claim not to make: its memory is **not** a step function that overshoots
by 3×. The crate's own formula has a `next_power_of_two`, but it grows lazily
and per shard, so measured across 150,000 to 350,000 entries it reads 117.1,
108.9, 105.8, 108.1 and 104.0 bytes an entry. A 12% band, not a cliff.

### What is still unexplained

At the ceiling — no lock, no writes — nilo is 109–114M against quick_cache's
159–176M, while on one thread the two are level. So roughly a third of the
eight-thread gap is now accounted for and the rest is scaling nobody has
attributed. **The next step there is `perf`, not another guess**, and until
somebody runs it this file should not claim a cause.

## 6. The lock came off the read path

§5 ended by saying what to build. This is what happened when it was built:
**+13.3% on eight threads, unchanged on one, and hit rate up 0.1 to 0.3 points
at every size.** Four interleaved rounds a side, same box, same browser holding
a core, 8 MiB budget and 50,000 keys.

| | 8 threads | 1 thread |
|---|---|---|
| before — exclusive lock on every `get` | 108.8–110.7M | 32.4–33.7M |
| **after — a `get` takes nothing** | **124.5–124.9M** | 32.8–33.0M |
| | **+13.3%** | unchanged |
| quick_cache, same rounds | 193.9–201.5M | 35.0–37.9M |

The eight-thread margin is 13.3% against spreads of 0.3% and 1.7%, so it is a
figure. The one-thread margin is 1.2% against a spread of 4.0%, so it is
"unchanged" and not a number. Against quick_cache the eight-thread gap goes from
1.81× to 1.60× and the one-thread gap stays at 1.12×.

### It is not a shared lock, and the shared lock is why

The obvious answer is a reader-writer lock, and that was built first. Sharing it
was **+11% on eight threads and −11% on one**: two atomic read-modify-writes per
lookup is a large fraction of what a 30 ns lookup costs, and one thread pays them
with nothing to gain. Taking nothing at all was worth 12% more than sharing, on
both thread counts.

What replaces the lock is one more read of a word the lookup already reads. A
region's cursor only goes forwards, `reserve` publishes it before a byte is
copied, and a lookup that reads it again after its copy and finds it unmoved has
proved nothing was writing there. [ADR 0188](../../docs/adr/0188-a-lookup-asks-the-cursor-afterwards-instead-of-taking-a-lock.md)
is the decision and the orderings.

### What says it is right

A soak, because an argument is not evidence. Sixteen threads, a quarter of the
operations writes, values of every length from 8 to 908 bytes, a budget small
enough that the ring laps continuously. Every value is self-describing, so half
of one entry and half of another is caught and so is a value read out of
somebody else's bytes.

**542 million verified hits across six shapes, none wrong.** The control matters
more than the result: with the second cursor read deleted and nothing else
changed, the same shapes gave **14,564 wrong answers, then 2,864, then 519**. A
check that has never fired proves nothing about a path that has never raced.

### Where the one-thread cost went, and it was not where it looked

The first working version was **13% slower on one thread**, and three rounds of
guessing put it on the lock, the validation and the promotion. A ladder of seven
builds put it somewhere else entirely.

| build | 1 thread | vs shipped |
|---|---|---|
| the exclusive lock it replaced | 33.8M | |
| lock-free, first working version | 27.8M | −18% |
| …with the bucket scan as one vector load | 32.4M | **+17%** |
| …with the rescue check reusing the cursor | 32.9M | **+18%** |
| …with the counters removed entirely | 30.5M | +10% |
| …with the promotion removed | 32.9M | +18% |
| **shipped** — both of the first two, sound | **32.9M** | |

Two of those are the same finding said twice: **an atomic load is one the
compiler may not fold, hoist or vectorise.** Eight `monotonic` loads of a bucket
cannot become the two vector loads a plain read becomes, and a second
`region.mark()` two lines after the first cannot be common-subexpressioned away.
Neither costs an instruction on paper and together they cost 18%.

The fix for the first is `unordered`, which is the weakest ordering that is
still not a race: it may see any one write but never half of two, which is all a
candidate list needs. A plain vector read is the same speed and is a data race,
and this module does not get to hold that opinion. The fix for the second is to
pass the cursor rather than read it again.

**The counters are the one item left and there is no cheaper exact version.**
Counting a read is 4.2% of the eight-thread figure and 7.0% of the one-thread
figure, because a read holds no lock now and the increment has to be atomic. One
set of counters per thread rather than per shard was built both ways, with a
thread-local lane and with a lane hashed from the stack address: 1.5% better on
eight threads, 3% worse on one. Per shard stayed.

### The ghost, which is real and small

`put` already walks exactly the ways whose fingerprint could be this key and
steps past the dead ones. A dead way that matches is a record that this key was
here and the ring took it, so it skips the doorkeeper. **+0.1 to +0.3 points at
every size**, for no memory at all.

| budget | before | after | ceiling |
|---|---|---|---|
| 128 KiB | 64.2% | **64.3%** | 66.8% |
| 512 KiB | 75.6% | **75.8%** | 78.6% |
| 1024 KiB | 81.4% | **81.7%** | 84.4% |
| 4096 KiB | 94.1% | **94.3%** | 96.3% |

**The window is the whole of why it is positive.** Ten laps of `small` is the
same stretch of writing as one lap of `main` and looks like the fair
comparison; it measured worse than one lap on five of six sizes (63.9% against
64.3% at 128 KiB) while holding 3% more entries. A ghost that reaches back far
enough stops being evidence about this key and becomes evidence that keys exist.

## 7. What it cost

Nothing is free and two things were spent.

**One thread is 8–10% slower.** `get` now writes the slot's frequency on a hit
until it saturates, and `put` ranks eight ways by liveness and warmth rather
than by age alone.

| | before | first cut | after hoisting |
|---|---|---|---|
| get_flat | 28.4M | 25.2M (−11%) | 26.1M (−8%) |
| put_flat | 19.3M | 16.0M (−17%) | 17.5M (−9%) |
| mixed_flat | 25.7M | 21.9M (−15%) | 23.0M (−10%) |

**Half of the first cut was the ranking asking the same question three times.**
The same-key check and the tier both called `live()`, which called `regionOf`,
which called `small.holds` — so eight ways cost `regionOf` sixteen times and
`small.holds` twenty-four. Reading liveness and region once a way gave back a
third of the loss, and the rest is the work itself.

Against +29% to +50% on eight threads, and 2–3× the hit rate per byte, this is
the right side of the trade for a module whose caller is a server. It would be
the wrong side for a single-threaded program, and that is worth saying out loud
rather than leaving in a table.

**An entry costs 64.3 bytes against 63.3 before**, which is 1.6% and is the two
regions rounding separately. The published 63.3 was a 2-core Xeon reading, so
the two are not strictly comparable; `perEntry` on this box reads 52.6 against
53.2 for a 16-byte value, which is the same figure moving the other way. Call
it unchanged.

## 8. Three mistakes in this cycle, all of which read as good numbers

**A whole sweep was run in Debug.** `zig build bench-cache` does not imply
`-Doptimize=ReleaseFast` and the first baseline taken here was 178 ns for an
operation that costs 24. Every conclusion drawn from it was wrong and the shape
of the table was identical.

**A row measured a store the row above had filled.** The file already carried
two comments about warming per row; a third was needed, because warming fills a
cache that is *empty* and cannot undo one somebody else filled. Once a store
has been round once it stops admitting freely, so `get_page` warming after
`put_flat` had written ten million carts retained a tenth of its pages and
reported 18.8% hits — at 26.4M ops/s, which looks like a win. Each row now gets
its own store.

**The policy's first version made an unread entry cost ten times its size.**
Sending every new entry through a tenth of the ring is admission control only
when something is competing for the other nine tenths. On a cache still filling
it is throwing room away: a store holding 78,875 entries held 8,065, and
`perEntry` reported 520 ring bytes for a 16-byte value. A cache with space to
spare now admits freely and the doorkeeper engages when `main` has been round
once.

All three produced numbers that pointed the same way as the change being made.

## 9. Can it be pushed further

Ranked, with what each would cost.

1. **The 60% still between nilo and quick_cache on eight threads, which nobody
   has attributed.** §6 took the lock off the read path and the gap went from
   1.81× to 1.60×. On one thread the two are 1.12× apart, so the remainder is
   still scaling rather than per-operation work, and §5's ceiling build — no
   lock, no writes at all — did not reach quick_cache either. **The next step
   here is `perf`, not another guess**, and this file should not name a cause
   until somebody runs it.
2. **Counting a read, worth 4.2% on eight threads and 7.0% on one.** The
   increment has to be atomic now that a read holds no lock. Per-thread lanes
   were built two ways and measured 1.5% better on eight threads and 3% worse
   on one, so the exact version stayed. What is left is quick_cache's answer:
   put the counters behind a build flag and let a caller who does not read
   `Stats` pay nothing. That is an API decision rather than a measurement.
3. **The second dependent cache miss, worth up to ~2× on the operation.** 29.3
   ns against a hash map's 11.9, and the whole difference is that a slot points
   at a ring. Fixing it means entries in the table, which cannot bound its own
   memory — so it would be a second table beside this one for values under some
   size, not a change to this one. **This used to be described here as the only
   lever worth more than a few percent, and §5 shows that was wrong**: it is the
   most invasive item on the list and no longer the largest.
4. **The clock on every `get`, worth about 4%.** 1.6 ns of a 24 ns operation,
   read whether or not anything in the Space has an expiry. Skipping it needs
   the shard to know that, which is a flag read outside the lock.
5. **The doorkeeper's share, worth an unknown amount of hit rate.** A tenth is
   what S3-FIFO uses; a fifth and a twentieth were tried here and both were
   worse, but the sweep was three points on one trace shape. Adaptive sizing —
   growing `small` while promotions are rare — has not been tried.
6. **Neither side is pinned.** Eight cores with the load generator on the same
   box; the ratios should survive but the absolutes will not. Re-take them
   before quoting them anywhere else.

## How to run it

```
zig build bench-cache -Doptimize=ReleaseFast -- [threads] [seconds]
zig build bench-cache -Doptimize=ReleaseFast -- mem [entries]
bash bench/compare-cache/run.sh              # nilo against all seven, interleaved
bench/compare-cache/go/cache-go hitrate      # the Go side's hit rate
bench/compare-cache/rust/target/release/cache-rust hitrate
bench/compare-cache/zig/zig-out/bin/cache-zig hitrate   # and `held`, which is §4's last note
```

`-Doptimize=ReleaseFast` is not optional and is not the default. See §5.
