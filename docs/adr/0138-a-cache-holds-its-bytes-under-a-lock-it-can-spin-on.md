# A cache holds its bytes under a lock it can spin on

`nilo_cache` is `http/allowance.zig`'s table with a harder value. That file
already holds the shape: a fixed table, ways to a bucket, a fingerprint per
way, the stalest way forgotten when a bucket fills, nothing allocated ever and
one 64-byte cache line touched per request
([ADR 0114](0114-an-allowance-is-a-table-sized-while-compiling.md)). A `Cart`
is not a `u64`, so the only thing that changes is where the bytes live — and
that one change is the whole of this decision.

The bytes live in a ring the cache owns, sized once at `open`. A slot says
**where** an entry is and **which pass over the ring** wrote it; an entry is
live if it was written on the current pass and is behind the write cursor, or
on the pass before and still ahead of it. **Eviction is what writing does.**
Nothing is freed because nothing is owned individually, no free list fragments,
and no size class wastes.

An offset and a pass number rather than a monotonically increasing position,
because a position has to be masked and masking needs a power-of-two ring —
which is a rounding a caller pays for. Flooring a 12 MiB budget to an 8 MiB
ring left a third of it unreachable, and the first working version of this
module cost **125.8 bytes an entry against go-cache's 96.9**. Nothing in the
sizing is rounded now: the table takes what `entries` implies, the ring takes
the rest exactly, and `bytesHeld()` is never above the `bytes` it was given.

go-cache is the design this is not, and the reason is not style. It stores
`interface{}` and hands back a pointer, which works because Go collects
garbage; the question it never has to answer is who owns the bytes a reader is
holding. That question is this file.

## A reader was supposed to need no lock, and the measurement says otherwise

The shape that fails is worth writing down because it reads correct:

```
pos = slot.pos
copy the key and value out of the ring
if (head_now - pos > capacity) -> miss     // it moved under us; drop the copy
```

If the window still holds `pos` once the copy is done, nothing overwrote those
bytes while it was being made — the only way to overwrite them is to move
`head` a full capacity past them.

The hole is that the reader is not the only thread that can be interrupted. **A
*writer* descheduled inside its own `memcpy` is lapped by the ring** and writes
its bytes over an entry newer than itself. The victim's position is recent, so
the victim passes every check the reader makes and arrives intact-looking and
wrong.

[`spike/cache_ring/`](../../spike/cache_ring/) put a number on it, on two cores:

| shards | lock | threads | gets | **wrong** |
|---|---|---|---|---|
| 1 | none | 2 writers + 2 readers | 19,944,448 | **7** |
| 16 | none | 2 + 2 | 20,651,008 | **8** |
| 1 | none | 1 + 1 | 34,910,464 | **0** |
| 16 | spin | 2 + 2, 30s | 73,246,976 | **0** |

Two rows earn their place. **Sharding is not a fix** — sixteen rings made it
eight rather than seven, because the race is inside one ring and cutting the
ring into sixteen does not touch it. And **it needs more threads than cores**,
which is not a defence: it is the failure appearing exactly when the machine is
busy, which is when a cache is being used at all.

The post-copy check itself is not broken. It fired 170–218 times per run and
every one of those was a copy correctly thrown away. It cannot see this.

## The lock cannot be a mutex, and that is the language's decision

Zig 0.16's `std.Io.Mutex.lock` takes an `io: Io`, because parking a caller on a
futex is something only a runtime can do. **A module with no event loop has no
`Io` to hand it.** A mutex would therefore put `Io` into `get`'s signature, and
needing no loop is the entry condition for the layer this module sits in
([ADR 0042](0042-the-bottom-layer-holds-more-than-one-module.md),
[ADR 0043](0043-a-setting-is-a-field-and-every-bad-one-is-named-at-once.md)) —
the property that lets `zig test cache/cache.zig` run the whole module with no
build graph, and lets a program that is not a server import it.

What is left is `tryLock` and a spin. That forces a rule rather than merely
allowing one: **the critical section must stay short enough to spin on**, which
means a `memcpy` and nothing else, forever. It is the same sentence that makes
the lock safe to hold inside a fiber — a fiber only moves at a point that
waits, and a critical section with no wait in it always finishes and releases.

The rule is load-bearing and easy to break later by adding something reasonable
inside the lock. It belongs in the file's header comment as a refusal, not as a
note.

## What it costs

**Allocations per request: none at all, and the signature is what says so.**
`get` takes the caller's buffer and there is no allocator to pass anywhere in
the module. A flat value comes back by value; a `[]const u8` comes back in an
array the handler declared. **Not even an arena allocation**, which is one
better than [ADR 0018](0018-the-trade-budget-has-three-axes.md) would have
allowed on a route that asked for it.

**And `nilo_http` does not name this module.** A handler asks for `*Carts` in
its argument list and gets it from `app.provide`, the way it gets any service —
which needs no wiring between the two modules, because a `Space` is a type the
*caller* declared. There is no `http/cache.zig` and there is nothing for one to
do: the front half `nilo_pw` needed exists because a hash holds a thread for
13 ms, and a cache lookup holds one for 230 ns.

**Memory per idle connection: nothing.** The table and the ring are the
process's, allocated once. What a handler declares to receive a value into is
stack, and stack is held per connection for the life of it
([ADR 0063](0063-a-handlers-stack-is-per-connection.md)) — so a route reading a
1 KB value adds 1 KB per connection, one for one, and that is the caller's
number rather than this module's.

**Throughput: free uncontended, 26% contended, and the second figure is this
box's worst case.** One thread measured 2,261,642 ops/s locked against
2,122,329 unlocked — the locked run came out 6.6% *faster*, which is the two
being inside each other's noise. Two threads on two cores, with the operating
system also wanting one, put it at 2,045,029 against 2,773,886.

> **Re-taken on eight cores by
> [ADR 0187](0187-a-cache-that-admits-everything-forgets-what-mattered.md), and
> the conclusion holds while the 26% does not.** With the shard count raised to
> 256, removing the lock altogether buys 1.4% on eight threads and nothing at
> all on one: 29.4 ns against 29.3. The contention this figure recorded was the
> shard default of sixteen rather than the lock, and raising it to 64 was worth
> 64% where a lock-free read is worth 1.4%. Two cores could not tell those
> apart.
>
> **And then re-taken again, against a store sized for its working set, by
> [ADR 0188](0188-a-lookup-asks-the-cursor-afterwards-instead-of-taking-a-lock.md).**
> The 1.4% above was measured on a 64 MiB store holding 50,000 keys, which is an
> 11 MiB table and mostly memory latency; at 8 MiB the same removal is worth
> 13.3%. **A read takes no lock at all now**, and this ADR's "every operation
> under one lock" holds for writes only. What replaced it is not the lock-free
> design refused below: a writer is still alone in its shard, so the cursor it
> publishes is the whole truth about where writing is happening, and a read that
> re-reads that cursor after its copy can tell.

**And the absolutes are not this module's.** Each measured operation formats its
key with `std.fmt.bufPrint` and then reads ~500 bytes from a random position in
a 64 MB ring, so most of the 471 ns is a cache miss and a format. What
transfers is the ratio.

**Binary size: paid only by a program that imports it**, being a module of its
own rather than a file under `http/`.

## Sizing, which the module documents rather than guesses at

Hit rate is ring bytes over working-set bytes, to within a point, at every size
measured — 81.0% against 81.2% predicted. **There is no cliff**, which is the
thing a FIFO window had to be checked for: a policy that collapses when the
working set crosses capacity would have ruled the shape out by itself. A ring
at 1.6× the working set is where the number stopped moving.

> **Corrected by [ADR 0187](0187-a-cache-that-admits-everything-forgets-what-mattered.md).**
> That paragraph is a fact about the benchmark. It drew its keys uniformly at
> random, and under uniform random every policy scores the same and that score
> is the ratio — so the straight line was the harness agreeing with itself, and
> a result landing exactly on the theoretical optimum should have been the tell.
> On Zipf 0.99 the FIFO window scored 78% of what a cache that size could reach,
> and it is now 96%. The window was ruled out by the check it was given; the
> check could not see it.

Holding an entry costs **8 bytes of slot**, 12 bytes of ring header carrying
the expiry, the Space and the two lengths, and the key. **Eight eight-byte
slots are one cache line**, where four sixteen-byte ones were: the same line
touched, half the table, and *better* retention, because a key arriving at a
full bucket is what a set-associative table loses and eight ways lose far fewer
of them than four. Measured on 200,000 entries that took the module from 125.8
bytes an entry at 98.3% retrievable to **63.3 at 99.1%**.

The lengths are in the ring rather than in the slot for the same arithmetic: a
byte in the ring is paid once per entry, and a byte in the slot is paid for
every slot whether or not anything is in it.

The key is in the ring on purpose. A fingerprint is 16 bits and a bucket holds
eight, so a collision is ordinary — the full key comparison behind it is what
makes one a wasted probe rather than somebody else's value, and **a cache that
is quietly wrong is worse than one that misses**.

A value has a **64 KB ceiling**, being what the header's 16-bit length can say,
and the refusal names it.

## Measured against go-cache, which wins the half it was built to win

[patrickmn/go-cache](https://github.com/patrickmn/go-cache) is the thing this
is compared to, on the same box, under the same load, interleaved three times
([`bench/result/cache.md`](../../bench/result/cache.md)).

| | nilo_cache | go-cache |
|---|---|---|
| 200,000 entries | **63.3 bytes/entry**, 99.1% retrievable | 97.5 bytes/entry, all of them |
| a flat 24-byte value, read | 3.7–4.4M ops/s | 6.0–6.2M ops/s |
| the same, written | 3.6–3.9M ops/s | 6.1–6.3M ops/s |
| a 512-byte value, read | 1.9–2.0M ops/s | 6.1M ops/s |
| memory when you did not ask | cannot grow | grows |

**It uses a third less memory and it is between a third and three times
slower**, and the second half of that is structural rather than a thing to
tune. go-cache hands back a pointer into memory a collector owns; this hands
back a copy, because there is no collector to hold the other end — which is the
whole reason the pointer could not be stored in the first place. That is the
entire 512-byte row: 16 bytes of string header against a 512-byte `memcpy`.

On the small values the gap is a cache miss. Go's map keeps the key beside the
probe, so a lookup is one dependent miss; this has a slot that points at a ring,
so it is two. Buying the second one back means putting the entry in the table,
which is the design that cannot bound its own memory.

**One number in that table was wrong the first time and is worth the warning.**
The Go side originally looked up with the very string objects it had stored,
and Go compares strings by checking their data pointers first — so its key
comparison was free and the gap read as 1.64×. Giving it a separate copy of the
same text, which is what a key built from a request actually is, moved it to
1.32×. A benchmark against another language's collection can hand that language
a shortcut this one has no way to take, and the shortcut is invisible in the
source.

## What was rejected

**The lock-free ring, as a fast path or behind a flag.** Wrong roughly once in
300,000 hits with more threads than cores. Handing back another entry's bytes
is the one failure a cache may not have, and an option that is wrong is not an
option.

**Sharding instead of locking.** Measured: eight wrong at sixteen shards
against seven at one.

**`std.Io.Mutex`.** It needs an `Io`, and taking one costs the module its
layer.

**A checksum per entry, verified on read.** It turns corruption into a miss
rather than preventing it, and a 32-bit check lets one in four billion through
— a design whose correctness is a probability, in exchange for avoiding a lock
that measured free when uncontended.

**A fixed-size value inline in the slot.** No ring, no lapping, no lock. It
either wastes most of a slot on small values or refuses the row-sized ones the
module exists for.

**An allocation per entry, the way go-cache does it.** It is an allocation per
put on the axis
[ADR 0018](0018-the-trade-budget-has-three-axes.md) treats as fixed, and
without a garbage collector it leaves the reader's copy with no owner.
