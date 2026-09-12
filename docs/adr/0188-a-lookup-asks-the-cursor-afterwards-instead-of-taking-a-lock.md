# A lookup asks the cursor afterwards instead of taking a lock

> **Amended by [ADR 0190](./0190-an-ordering-is-proved-on-the-processor-that-runs-it.md).**
> Every ordering below was argued against x86, and two of them — the cursor
> store in `reserve` and the second cursor load in `settled` — hold the
> compiler and not an aarch64 processor, which reorders the copy across
> both. The reader now issues a load-load barrier on aarch64 and the writer
> moves the cursor with a swap off x86; x86 is unchanged and the figures in
> this file stand. The test named below is what caught it, on the first
> machine that could.

[ADR 0138](0138-a-cache-holds-its-bytes-under-a-lock-it-can-spin-on.md) put every
cache operation behind one spin lock a shard, including reads. That is most of
what separated this module from the fastest cache measured against it: on eight
threads, four builds side by side put the lock at 10% of the figure and the
writes a read does inside it at another 16%
([`bench/result/cache.md`](../../bench/result/cache.md) §5).

A read now takes nothing at all. **+13% on eight threads, level on one**, three
to four interleaved rounds a side.

## What replaces it

The ring already answers the question the lock was being held to answer. A
region is a cursor that only goes forwards, and `live(slot)` means *the cursor
has not written over this entry yet*. So:

1. `reserve` publishes the moved cursor **before** the caller copies a byte.
2. A lookup reads the slot, reads the entry, copies the value into the caller's
   buffer, and then reads the cursor **again**.
3. If the cursor has passed the entry in between, some `put` was writing over
   those bytes while they were being read. The answer is thrown away and counted
   as an eviction, which is what it is.

That is a seqlock whose sequence number was already there and already read: the
second load is of the same word the liveness check reads anyway. The offset and
the pass number moved into one 64-bit `Mark` so both arrive in one load — two
fields would let a reader take the offset from before a wrap and the pass number
from after it, and conclude that an entry the ring had just written over was
still there.

Writers still hold the lock against each other, because two cursors moving at
once is two entries in one place.

## Why this is not the lock-free version that was wrong

ADR 0138 records a lock-free ring that gave seven wrong values in 1.9 million
hits, and the reason it did is worth being precise about, because "we tried that
and it was wrong" would otherwise rule this out.

That version let **writers** run concurrently. A writer descheduled inside its
own `memcpy` was lapped by another writer, so the bytes at an offset could be
older than the cursor said and no reader could tell. Sharding did not fix it;
sixteen rings gave eight.

Here a writer is alone in its shard. The cursor it publishes is the whole truth
about where writing is happening, so a reader comparing against it is comparing
against something that cannot be stale in the direction that matters.

## What says so, rather than what argues so

A soak: sixteen threads, a quarter of the operations writes, values of every
length from 8 to 908 bytes so entries never line up, a budget small enough that
the ring laps continuously. Every value is self-describing — its length and
every byte come from the key's number — so half of one entry and half of another
is caught, and so is a value read out of somebody else's bytes.

**542 million verified hits across six shapes, none wrong.** With the second
cursor read deleted and nothing else changed, the same shapes gave 14,564 wrong
answers on sixteen threads, 2,864 on another, and 519 on eight. A test that
cannot fail proves nothing, and that control is what says this one can.

A short version runs in the suite: `test "a lookup that holds no lock never
hands back a value that is not the key's"`.

## The orderings, and why each one is there

- `reserve` stores the cursor **sequentially consistent**. Not for the
  processor — x86 would not reorder two stores — but for the compiler, which
  must not sink that store below the `memcpy` its caller does next.
- A lookup's second cursor read is **sequentially consistent** for the mirror
  reason: the copy must not be sunk below it. Making it relaxed measured
  **1.9% faster and is wrong**, which is the ordinary shape of this trade.
- `Slot.load` is **acquire**, because the cursor is read after the slot. Without
  it, a slot a `put` has just written could be judged against a cursor from
  before that same `put` moved it, and a key that was just stored would read
  back as a miss.
- The bucket scan's eight loads are **unordered** — the weakest ordering that is
  still not a race. It may see any one write but never half of two, which is all
  the scan needs: what it returns is a list of candidate ways, and every one of
  them is loaded again and its whole key compared. A plain 64-byte vector read
  of the bucket is 16% faster on one thread and is a data race beside a `put`'s
  slot store, and this module does not get to hold that opinion.
- Every other slot access is an atomic load or store of the whole eight bytes.
  A slot is written by `put`, by `carry`, by a reader clearing an expired entry
  and by a reader warming one, so a plain field write would be a race whatever
  the hardware does. It costs nothing: eight aligned bytes is one `mov` either
  way.
- `carry` swaps the slot rather than storing it, because a reader may have
  warmed or cleared it while the copy was being made — the first is a reason to
  try again, the second a reason to stop.

## Three things that were built, measured and thrown away

**A reader-writer lock**, which is the obvious answer. Sharing the lock was
worth 11% on eight threads and cost 11% on one: two atomic read-modify-writes
per lookup is a large fraction of what a 30 ns lookup costs, and one thread pays
them with nothing to gain. Taking nothing was worth 12% more than sharing, on
both thread counts.

Its first version also cost a separate lesson. Moving the promotion out of the
read and having `promote` re-find the key by walking the bucket again measured
**2.5% slower** than the exclusive lock it replaced: about an eighth of reads
want a promotion, and an eighth of reads paying a second lock and a second scan
costs more than seven eighths gain from running together. Handing back the way
rather than the key is what made it a win.

**One set of counters per thread instead of per shard.** Counting a read costs
4.2% of the eight-thread figure and 7.0% of the one-thread figure, because the
increment has to be atomic now. Lanes measured 1.5% better on eight threads and
3% worse on one — a lane lookup buying back contention it also pays for. Per
shard stayed.

**A wider ghost window.** Below.

## The ghost that costs no memory

`put`'s first loop already walks exactly the ways whose fingerprint could be
this key, and steps past the dead ones. A dead way whose fingerprint matches is
a record that *this key was here and the ring took it* — S3-FIFO's ghost queue,
with nothing allocated for it. quick_cache spends half its capacity again on
full-size non-resident slots to hold the same fact, and part of its 105.4 bytes
an entry against nilo's 64.3 is that.

A key with a ghost skips the doorkeeper and goes straight to `main`. It is worth
**+0.1 to +0.3 points of hit rate on every size measured**, and the window is
the whole of why. One lap of the region is what measured best. Ten laps of
`small` — the same stretch of writing as one lap of `main`, which looks like the
fair comparison — measured *worse* than one on five of six sizes (63.9% against
64.3% at 128 KiB) while holding 3% more entries. A ghost that reaches back far
enough stops being evidence about this key and becomes evidence that keys exist.

The same reordering fixed a second thing for free. `put`'s same-key scan now
runs before the region is chosen, so **a key already in `main` is not sent back
through the doorkeeper by being refreshed**. A cache in front of anything spends
most of its writes refreshing keys it already holds, and the old order demoted
every one of them into the tenth of the ring that laps ten times as fast.

## Against ADR 0018's four axes

- **Allocations per request: zero.** Nothing here allocates.
- **Memory per idle connection: zero.** The `Mark` is the two fields the region
  already had, in one word. `Counters` moved to a cache line of its own, which
  is 64 bytes a shard and was false sharing before.
- **Throughput: +13% at eight threads, −1% at one**, interleaved, four rounds a
  side. Hit rate up 0.1 to 0.3 points at every size.
- **Binary size: unchanged** to the nearest kilobyte.

## Consequences

- **A hit can now be counted as an eviction**, when a `put` overwrote the entry
  while it was being read. It is rare and it is the truthful classification, but
  `Stats.evicted` is no longer only about the ring being too small.
- `Store.stats()` takes no lock. The counters are atomic and nothing branches on
  them, so the answer is a sum over a moving target either way.
- `Store.clear()` writes the slots one at a time rather than in one `memset`,
  because a lookup that holds nothing may be reading any of them.
- **A test that was passing on a zero-byte margin was found by this.** The flood
  test put its wanted key on `main`'s very first byte, filled `main` exactly
  once, and passed because the cursor stopped precisely on it. One extra byte
  written to `main` failed it. It warms the cache first now, which is what makes
  the doorkeeper the thing under test rather than `filling`.
- ADR 0138's header sentence — every operation under one lock — is superseded
  for reads and still holds for writes.
