# A cache in this process

`nilo_cache` is an expiring cache in the memory of the program that opened
it: a cart looked up on every request, a rendered page, the answer from
somebody else's API that does not change for five minutes. A tool module: no
event loop, no allocator after `open`, and it imports nothing, so `zig test
cache/cache.zig` runs the whole of it and a program that is not a server can
take it on its own
([ADR 0138](../adr/0138-a-cache-holds-its-bytes-under-a-lock-it-can-spin-on.md)).

**It does not leave this process.** Two instances of your program have two
caches that do not agree, neither survives a restart, and nothing here reaches
a network. That is the trade the module is for, and
[ADR 0139](../adr/0139-an-in-process-cache-and-a-redis-client-are-two-modules.md)
is where the other answer — a Redis client — was named and not built.

```zig
const cache = @import("nilo_cache");
```

and in `build.zig`, beside `nilo_http`:

```zig
.{ .name = "nilo_cache", .module = nilo.module("nilo_cache") },
```

## The whole of it

A Space is a named, typed keyspace — the cache's answer to what a Bucket is
to an object store. Declare it once beside your other types:

```zig
const Cart = struct { owner: u64, items: u16, total_cents: u64 };

const Carts = cache.Space("cart", Cart, .{ .ttl_s = 300 });
```

Open the Store once, where the program starts, and the Spaces off it:

<!-- compiles: body -->
```zig
store = try cache.open(gpa, .{ .bytes = 64 << 20 });
defer store.deinit();
carts = Carts.open(&store);
try app.provide(&carts);
```

And wherever the work is:

<!-- compiles -->
```zig
fn cart(carts: *Carts, owner: u64) !Cart {
    var key: [24]u8 = undefined;
    const name = try std.fmt.bufPrint(&key, "u{d}", .{owner});

    if (carts.get(name)) |found| return found;

    const fresh: Cart = .{ .owner = owner, .items = 0, .total_cents = 0 };
    carts.put(name, fresh);
    return fresh;
}
```

A Space is a value a handler holds — by pointer, as a
[service](./services.md), or by value inside one. **Two Spaces over one Store
share its memory and cannot read each other's keys**: the name is hashed
while compiling into the seed every key goes through, and stored in each
entry, so a fingerprint collision cannot cross a Space boundary.

| | |
|---|---|
| `cache.open(gpa, .{ .bytes = n })` | `!Store` — all the memory, taken here and never again |
| `cache.Space(name, V, .{ .ttl_s = s })` | a keyspace, as a type |
| `Space.open(&store)` | the value a handler holds |
| `space.put(key, value)` | for the Space's `ttl_s` |
| `space.putFor(key, value, ttl_s)` | for a life of its own. `0` is until the ring writes over it |
| `space.get(key)` | `?V` for a flat value; `?[]const u8` and a `*Held` for bytes |
| `space.del(key)` | `bool` — was there anything to forget |
| `space.putIfAbsent(key, value)` | store only if the key is free, and say whether it was. One lock around the scan and the write, so two callers racing get one `true` between them — a claim, not a `get` and a `put`. What [`nilo.Idempotent`](./idempotency.md) claims a key with |
| `space.getInto(key, buf)` | the bytes, into a buffer of your choosing rather than a `Held` — for a caller whose buffer is the request arena |
| `store.stats()` | hits, and the three different ways of missing |
| `store.bytesHeld()` | every byte it will ever hold, and it never moves |
| `store.shardCount()` | how many it got, which is at most the `shards` asked for |
| `store.clear()` | forget everything |

`get` answers `null` for every kind of not-here — never written, written and
expired, written and evicted — and [`stats()`](#why-is-it-not-hitting) is what
tells those apart.

## Space options

The third argument to `cache.Space`:

| Field | Default | |
|---|---|---|
| `ttl_s` | `0` | seconds an entry lives. Zero means until the ring writes over it, which for a cache is a perfectly good answer — nothing here sweeps |
| `max_bytes` | 4096 | the largest value a `[]const u8` Space will hold, and the size of its `Held`. **Read only for that shape** |

An empty name is a compile error, because the name is what keeps one Space's
keys out of another's. So is a `[]const u8` Space with a `max_bytes` of zero,
or of more than 65,535 — the length is stored in sixteen bits so that four
ways of a bucket are one cache line.

## The value type decides the shape of `get`

| The value | `get` |
|---|---|
| flat — a number, an enum, a struct or array with no pointer anywhere in it | `get(key) ?V` — by value, no buffer anywhere |
| `[]const u8` | `get(key, &held) ?[]const u8` — into an array you declared |

A flat value has a size known while compiling, so it comes back by value and
nobody declares anything. Bytes do not, so the Space says how large one can
be and hands out the array to read into:

<!-- compiles -->
```zig
const Pages = cache.Space("page", []const u8, .{ .max_bytes = 4096 });

fn page(pages: *Pages, path: []const u8) ![]const u8 {
    var held: Pages.Held = undefined;
    if (pages.get(path, &held)) |cached| return cached;
    const html = "…";
    try pages.put(path, html);
    return html;
}
```

**`Held` is your stack, and stack is held per connection for the life of
it** ([ADR 0063](../adr/0063-a-handlers-stack-is-per-connection.md)). A
handler declaring a 4 KiB `Held` has added 4 KiB to every connection that
reaches it. It is written as an array you declare rather than a buffer the
cache hides because that is the only way the number is yours to see. A
`put` of bytes is the one call that can fail: `error.TooLarge` when the value
is over `max_bytes`, or over a quarter of one shard's ring.

**A value with a pointer in it is a compile error, and the field is named.**
A cache entry outlives the call that wrote it — that is the entire point of
one — so a slice stored in it would point at a request that has ended. Go's
cache stores `interface{}` and gets away with it because a collector holds
the other end; there is none here. Encode it and use a Space of
`[]const u8`, or keep an id in the cache and look the rest up.

There is no allocator to pass anywhere in this module, and the signatures
are what say so: nothing allocates per operation.

## Store options

Given to `cache.open`:

| Field | Default | |
|---|---|---|
| `bytes` | 8 MiB | **the whole budget, and a ceiling rather than a target**. The ring the values live in and the table that points at them come out of it together, and `bytesHeld()` is never above it |
| `entries` | derived | how many entries the table can point at, when the five sixths the ring takes by default is the wrong split. Clamped to the budget rather than added to it — raise it for many small values, lower it for few large ones |
| `shards` | 64 | how many independent tables and rings, and so how many writers can be inside at once. A fixed number rather than the core count, so the same program holds the same memory on two machines |

`open` answers `error.TooSmall` when the numbers do not divide into a
working cache — under 64 KiB of value memory, or fewer entries than the
shards have ways to hold them — and `error.OutOfMemory` when the machine
will not give the budget.

**One number decides the memory and it never moves.** Nothing is allocated
after `open`, nothing grows, and there is no sweep: an entry goes when its
time is up or when the ring writes over it. That number is the whole of it,
which is worth saying because the two Go caches of this shape mean something
narrower by it — they bound their *values* and put the index on top,
unbounded, so 200,000 entries on a 12 MiB budget cost them 25.2 and 28.5 MiB
of RSS against this module's 12.0
([`bench/result/cache.md`](../../bench/result/cache.md)).

## Sizing it

**Ask for the hit rate you want rather than for a multiple of the data.**
Measured on a Zipf 0.99 workload — which is what traffic looks like — a ring
at a fortieth of the working set answers 63.9% of lookups and one at a fifth
answers 94.1%, and both are 96–98% of what a cache that size could reach at
all. Pick a budget, run it, read `stats()`.

An entry costs about 20 bytes over its value: 8 of table slot, 12 of header,
and the key. 64.3 bytes an entry on 200,000 of them, against go-cache's
100.2, freecache's 132.0 and bigcache's 149.4.

**A new entry has to be asked for twice before it gets the run of the ring**
([ADR 0187](../adr/0187-a-cache-that-admits-everything-forgets-what-mattered.md)). It lands in a
tenth of the ring and is copied into the rest when something reads it again,
so a flood of keys nobody asks for twice cannot flush what the cache is
holding. Two things follow that are worth knowing rather than discovering:
a cache with room still admits freely, and a cache written to and never read
holds its first entries indefinitely rather than forgetting the oldest.

## Why is it not hitting

`store.stats()` counts hits apart from the three ways of missing, which is
the question every cache eventually gets asked:

| Counter | |
|---|---|
| `hits` | |
| `misses` | nothing in the table under that key — it was never written, or the key is wrong |
| `evicted` | the table knew the key and the ring had moved past it. **This is the number that says the ring is too small** |
| `expired` | found, and past its time |
| `puts` | |
| `refused` | a value that did not fit an entry, so nothing was stored |
| `rescued` | warm entries a read moved out of the write cursor's way. **This is the number that says the policy is doing something** |
| `evictionRate()` | of the lookups that found nothing, how many were the ring being small |

High `evictionRate()` means the cache wants more `bytes`; low, with few
hits, means it is being asked about keys nobody wrote. The counters are
exact and the reading is not a snapshot — nothing is locked while they are
summed, because a lookup takes no lock either.

## What it costs

**A `get` takes no lock at all**
([ADR 0188](../adr/0188-a-lookup-asks-the-cursor-afterwards-instead-of-taking-a-lock.md)):
it copies the value out and then asks the ring's write cursor whether
anything wrote over those bytes while it read them. Readers do not queue
behind each other — 124.5M reads a second on eight threads, against 108.8M
when they did. A `put` takes one lock, per shard, across a `memcpy` and
nothing else.

That last rule is what makes the module safe to hold under a fiber. Zig's
`std.Io.Mutex` needs an `Io` this layer has none of, so the lock spins — and
a critical section with nothing in it that waits always finishes and
releases. It is also why nothing that waits may ever go inside one, which is
a constraint on the module and not on you.

**Per request, nothing**: a lookup is one cache line touched for the slot and
one copy for the value, and the request path's allocation budget is
untouched. Per connection, whatever `Held` you declared.

The TTL clock is the coarse monotonic one — a page the kernel updates on its
own tick rather than a vDSO call — because an operation costing a hundred
nanoseconds should not spend a fifth of it on accuracy a TTL measured in
seconds has no use for.

## Testing

A Store opens on `std.testing.allocator` with any budget over 64 KiB, and a
handler that takes a `*Carts` is an ordinary function:

```zig
test "a cart is remembered for the next request" {
    var store = try cache.open(testing.allocator, .{ .bytes = 1 << 20, .shards = 4 });
    defer store.deinit();
    var carts = Carts.open(&store);

    _ = try cart(&carts, 42);
    try testing.expect(carts.get("u42") != null);
}
```

An expiry is tested by the TTL rather than by waiting: `putFor(key, value,
1)` and a `std.Thread.sleep` of a second is the honest way, and the module's
own suite does it once so that yours need not.

## See also

- [The reference](../reference.md#nilo_cache) — the surface as a list.
- [Services](./services.md) — how the Space reaches a handler.
- [`bench/result/cache.md`](../../bench/result/cache.md) — every number
  above, how it was run, and the single-threaded rows where go-cache is
  faster.
- [ADR 0138](../adr/0138-a-cache-holds-its-bytes-under-a-lock-it-can-spin-on.md)
  — why the value may hold no pointer and why the lock spins.
