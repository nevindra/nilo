# nilo_cache

What one operation costs, what one entry costs to hold, and how both compare
with the thing this module is measured against.

Machine: 2 × Intel Xeon Platinum 8255C @ 2.50GHz, 8 GB, Zig 0.16.0, Go 1.25.1,
both sides ReleaseFast / `go build`. nilo at the commit that added
[`cache/`](../../cache/).

**Two cores, and every number here says so.** A comparison of two caches on a
box with two cores and an operating system also wanting one is a comparison
with a wide spread; the ranges below are three interleaved rounds each, and a
margin narrower than its own spread is quoted as a range rather than as a
figure.

## The competitor

[patrickmn/go-cache](https://github.com/patrickmn/go-cache) — a `map[string]Item`
under an `RWMutex`, the thing a Go program reaches for when it wants an
expiring cache in its own process. `bench/compare-cache/go/` is it, driven the
same way `bench/cache_bench.zig` drives this one: the same 50,000 keys, built
before the clock starts, the same 24-byte flat value and the same 512-byte
page, the same nine-reads-to-a-write mix.

## What one entry costs to hold

200,000 entries of a 24-byte value under an 11-byte key, RSS read from
`/proc/self/status` on both sides, with Go given a `runtime.GC()` and a
`debug.FreeOSMemory()` first.

| | bytes/entry | retrievable | can it grow |
|---|---|---|---|
| **nilo_cache** | **63.3** | 99.1% | no — `bytesHeld()` is fixed at `open` |
| go-cache | 97.5 | 100% | yes, without asking |

**A third less memory, and a ceiling instead of a habit.** The 0.9% is the
table being set-associative: eight ways to a bucket, and a key arriving at a
bucket whose eight are taken displaces the stalest. A cache is allowed to miss.

## What one operation costs

Three interleaved rounds, one thread, three seconds a row.

| | nilo_cache | go-cache | |
|---|---|---|---|
| flat 24 B, read, cache-resident working set | 10.3–10.6M ops/s | 14.1–15.0M | go ×1.4 |
| flat 24 B, read, 50,000 keys | 3.7–4.4M | 6.0–6.2M | go ×1.3–1.5 |
| flat 24 B, written | 3.6–3.9M | 6.1–6.3M | go ×1.6–1.9 |
| nine reads to a write, flat | 3.3–3.9M | 6.6–7.1M | go ×1.7–1.9 |
| 512 B page, read | 1.9–2.0M | 6.1M | go ×3.0 |
| nine reads to a write, 512 B | 2.0–2.2M | 6.3–6.5M | go ×3.0 |

**go-cache is faster, and the large-value row is not a tuning problem.** It
hands back a pointer into memory a garbage collector owns; this hands back a
copy, because there is no collector to hold the other end. Sixteen bytes of
string header against a 512-byte `memcpy` is the whole of that 3×, and it is
the same property that makes storing a pointer in an entry impossible here
([ADR 0138](../../docs/adr/0138-a-cache-holds-its-bytes-under-a-lock-it-can-spin-on.md)).

On the small values the gap is one cache miss. Go's map keeps the key next to
the probe, so a lookup is a single dependent miss; a slot pointing into a ring
is two. Closing it means putting entries in the table, which is the design that
cannot bound its own memory — the row above.

## The number that was wrong, and how

The first run of the comparison put the small-value gap at **1.64×**. It is
1.3–1.5×.

The Go benchmark looked keys up using the very string objects it had stored,
and Go compares two strings by checking their data pointers before their bytes.
Every probe hit that shortcut, so the key comparison cost nothing. A lookup key
in a real program is built from a request; it is not fished out of the array
that filled the cache. Giving the Go side a separate copy of the same text —
`string([]byte(k))` — took the gap to 1.32× in the same session.

**A comparison against another language's collection can hand that language a
shortcut this one has no way to take, and the shortcut is invisible in the
source of both.** The other side of this module compares bytes out of a ring
every time and has no such path available.

## Two mistakes inside the harness, both of which read as good numbers

**A row measured a cache another row had emptied.** `put_flat` writes ten
million entries through a ring holding a few hundred thousand, so `get_page`
two rows below it started against nothing and reported 0% hits at 7.4 million
lookups a second. A miss is fast. Warming per row rather than once fixed it.

**And then the warm-up wrote what the row would not read.** Warming both Spaces
put a thousand 512-byte pages over the 24-byte carts the next row wanted, which
on the small store left the headline row at 23% hits — again, mostly timing
misses. The warm-up now writes only the Space the row reads.

Both of these produced *higher* numbers, which is the direction that does not
prompt anybody to look.

## Where the memory went before

The module's first working version cost **125.8 bytes an entry at 98.3%
retrievable** — worse than go-cache on both. Two things, both about rounding:

- **The ring was masked, so it had to be a power of two.** A 12 MiB budget
  became an 8 MiB ring and a third of it was unreachable. Storing an offset
  and a pass number instead of a monotonic position needs no mask, and the
  ring is now sized exactly.
- **The slot was 16 bytes and the bucket had four ways.** Halving the slot and
  doubling the ways is the same 64-byte cache line touched, half the table, and
  better retention at any load.

63.3 at 99.1% is the two together.

## Can it be pushed further

Ranked, with what each would cost:

1. **The second cache miss on a read, worth up to ~1.4× on small values.** A
   slot points at a ring; the entry could instead live in the table for values
   under some size. That is the design that cannot bound its memory, so it
   would have to be a second table beside this one rather than a change to it.
   Nobody has asked.
2. **The 512-byte copy, worth up to ~3× on large values.** Handing back a slice
   into the ring instead of a copy means holding the lock across the caller's
   code, and the lock spins — the one rule this module is not allowed to break.
   A borrowed read is possible only if the lock stops being a spin lock, and it
   is a spin lock because a module with no event loop has no `Io` to park on.
3. **The clock on every `get`, worth about 2%.** `CLOCK_MONOTONIC_COARSE` is
   ~5ns of a ~230ns operation and is read whether or not anything in the Space
   has an expiry. Skipping it needs the shard to know that, which is a flag
   read outside the lock, which is a race worth about 2%.
4. **Pinning, worth an unknown amount of the spread.** Neither side was pinned;
   on two cores there is nowhere to pin to. Every ratio here should be re-taken
   on a machine with cores to spare before it is quoted anywhere else.
