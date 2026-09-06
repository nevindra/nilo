# Can a cache hold values of any length without allocating per operation?

`http/allowance.zig` already answers this for a value that is one `u64`: a
fixed table in `.bss`, four ways to a bucket, a fingerprint per way, the
stalest way forgotten when a bucket fills. Nothing allocates and one 64-byte
cache line is touched per request.

A cache is that table with a harder value. `Cart` is not a `u64`, and two of
them are not the same length, so the bytes have to live somewhere the slot can
point at. go-cache's answer is `interface{}` and Go's garbage collector, which
is why **its design does not survive translation** — the question it never has
to ask is who owns the bytes a reader is holding.

The shape under test is one ring of bytes, sized once at init. A put takes its
bytes with a single `fetchAdd` on a position that only goes forwards, then
copies key and value in. The ring is a window on that position: everything in
`[head - capacity, head)` is live and everything older has been written over.
Eviction is what writing does; nothing is freed because nothing is owned
individually.

A reader was supposed to need no lock:

```
pos = slot.pos
copy the key and value out of the ring
if (head_now - pos > capacity) -> miss     // it moved under us; throw the copy away
```

**That check does not hold, and finding out is what this spike was for.**

## Run it

```
./run.sh                      # every table below
./zig-out/bin/cache-ring-spike torture <writers> <readers> <seconds> <shards> <locked>
./zig-out/bin/cache-ring-spike bench   <threads> <seconds> <shards> <locked>
./zig-out/bin/cache-ring-spike hit     <working-set> <ring-mb>
```

`torture` exits non-zero if a reader is ever handed a value that is not the one
its key wrote. Every value carries its own key and its own length, so a reader
can tell a wrong answer from a plausible one.

Machine: 2 × Xeon Platinum 8255C @ 2.50GHz, 8 GB, Zig 0.16.0, ReleaseFast,
nilo at `3118b8b`. **Two cores, and that matters to the finding rather than
just to the absolutes.**

## The lock-free ring is wrong

| shards | lock | writers+readers | gets | hits | **wrong** | raced |
|---|---|---|---|---|---|---|
| 1 | none | 2+2, 5s | 19,944,448 | 1,915,096 | **7** | 170 |
| 16 | none | 2+2, 5s | 20,651,008 | 1,976,755 | **8** | 178 |
| 1 | none | 1+1, 10s | 34,910,464 | 3,350,129 | **0** | 218 |
| 16 | spin | 2+2, 5s | 12,428,800 | 1,189,327 | **0** | 0 |
| 16 | spin | 2+2, 30s | 73,246,976 | 7,017,617 | **0** | 0 |

**A writer descheduled inside its own `memcpy` is the whole failure.** It takes
its position, stops, and by the time it runs again the ring has gone round: it
now writes its bytes over an entry newer than itself. The victim's slot points
at a recent position, so the victim passes the window check and is handed to a
reader intact-looking and wrong.

Three things that reading the code does not tell you, and the table does:

- **Sharding does not help.** Sixteen shards made it 8 instead of 7. The race
  is inside one ring, so cutting the ring into sixteen changes nothing about
  it.
- **It needs more threads than cores.** One writer and one reader on two cores
  produced zero wrong answers in 34.9 million gets. That is not a defence, it
  is the opposite: the failure appears exactly when the machine is busy, which
  is when a cache is being used.
- **The post-copy check works for what it was for.** `raced` fires 170–218
  times per run and every one of those is a copy correctly thrown away. The
  check is not broken; it cannot see this.

## The fix is a lock, and it cannot be a mutex

Zig 0.16's `std.Io.Mutex.lock` takes an `io: Io`, because parking a caller on a
futex is something only a runtime can do. **A module with no event loop has no
`Io` to give it**, so a tool module cannot have a mutex without putting `Io`
into `get`'s signature — and needing no loop is the entry condition for that
layer ([ADR 0042](../../docs/adr/0042-the-bottom-layer-holds-more-than-one-module.md)).

What is left is `tryLock` and a spin, which forces a rule rather than merely
allowing one: **the critical section must stay short enough to spin on**, which
means a `memcpy` and nothing else. That is the same argument that makes it safe
to hold inside a fiber — there is no point in there that waits, so the holder
always finishes and releases.

## What the lock costs

| threads | shards | lock | ops/s |
|---|---|---|---|
| 1 | 16 | none | 2,122,329 |
| 1 | 16 | spin | **2,261,642** |
| 2 | 16 | none | 2,773,886 |
| 2 | 16 | spin | 2,045,029 |

**Uncontended it is free** — the locked run measured 6.6% *faster* at one
thread, which is the two being inside each other's noise rather than a win.
Contended it costs 26%, and that row is the worst case this machine can
produce: two threads on two cores with the operating system also wanting one.

The absolutes are not the cache's. Each operation formats its key with
`std.fmt.bufPrint` and then reads ~500 bytes from a random position in a 64 MB
ring, so most of the 471 ns is a cache miss and a format, not the lookup.
**What transfers is the ratio.**

## The window degrades in a straight line

| working set | ring | stored | hit rate |
|---|---|---|---|
| 10,000 entries | 1 MB | 492% of ring | 20.6% |
| 10,000 | 4 MB | 123% | 81.0% |
| 10,000 | 8 MB | 62% | 100% |
| 10,000 | 16 MB | 31% | 100% |
| 50,000 | 16 MB | 156% | 63.6% |

Hit rate is ring bytes over working-set bytes, to within a point, every time —
81.0% measured against 81.2% predicted. **There is no cliff and no
pathology**, which is the thing a FIFO window had to be checked for: an
eviction policy that collapses when the working set crosses capacity would
have ruled the shape out on its own.

## What it costs to hold an entry

Structural rather than measured:

```
16 bytes  the slot: a ring position and one word of fingerprint and lengths
 4 bytes  the entry header in the ring, carrying the expiry
 n bytes  the key, stored in the ring so a fingerprint match can be confirmed
```

The key is in the ring on purpose. A fingerprint alone would hand back another
key's value on a 32-bit collision, and a cache that is silently wrong is worse
than one that misses.

Four ways of 16 bytes is 64 bytes, so a bucket is one cache line — the property
`allowance.zig` is built around, kept. The expiry is in the ring rather than the
slot for the same reason: it is what keeps the slot at two words.

And **nothing allocates per operation, which the signature says rather than a
measurement**: `get` takes the caller's buffer and there is no allocator to
pass.

## What this does not measure

- **Fibers.** There is no zio here and no `Io` — which is the point, since the
  module this is for needs neither. How a spin lock behaves under nilo's
  scheduler specifically is unmeasured; a fiber cannot be preempted by another
  fiber on its thread, but the thread can still be preempted by the kernel,
  which is the case that broke the lock-free version.
- **More than two cores.** The 26% is this box's worst case. Contention on a
  machine with cores to spare is a different number and has to be taken there.
- **ReleaseSafe.** Only ReleaseFast was run.
- **Values over 64 KB**, which the 16-bit length field cannot express. A
  shipped module refuses them by name; the spike asserts.
- **A real workload.** Keys are uniform, and a cache in front of a database
  never is. A skewed load would raise the hit rate at every ring size in the
  table and would not change the failure above.

## What it decides

1. **The lock-free shape does not ship.** Not as a fast path, not behind a
   flag, not with a comment. It is wrong roughly once in 300,000 hits on a
   machine with more threads than cores, and a cache that returns another
   entry's bytes is the one failure a cache is not allowed to have.
2. **The lock is a spin lock, and that is the language's decision** rather than
   a preference. The consequence is a rule the module has to keep: nothing that
   waits, ever, inside a critical section.
3. **A value has a 64 KB ceiling**, and the refusal names it.
4. Sizing advice the module documents: a ring at 1.6× the working set is where
   the hit rate stopped moving.
