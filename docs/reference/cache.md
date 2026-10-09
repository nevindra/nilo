# nilo_cache

**`nilo_cache` is an expiring cache inside this process, with a fixed memory budget taken once at `open`.**

**Guide:** [A cache in this process](../guide/cache.md) · **Design:** [The in-process cache](../design/cache.md)

## `nilo_cache`

An expiring cache in this process that needs no event loop ([ADR 109](../adr/109-a-cache-holds-its-bytes-under-a-lock-it-can-spin-on.md)). It is a tool module: it imports nothing, so `zig test cache/cache.zig` runs all of it, and a program that is not a server can use it on its own.

<!-- compiles: body -->
```zig
// once, where the program starts
store = try cache.open(gpa, .{ .bytes = 64 << 20 });
defer store.deinit();
carts = Carts.open(&store);

// and wherever the work is
carts.put("u42", .{ .owner = 42, .items = 3, .total_cents = 125_000 });
if (carts.get("u42")) |cart| {
    _ = cart.items;
}
```

`Carts` is a type of your own, declared once beside the others:

```zig
const Cart = struct { owner: u64, items: u16, total_cents: u64 };

const Carts = cache.Space("cart", Cart, .{ .ttl_s = 300 });
```

### `Store` and `Space`

| | |
|---|---|
| `cache.open(gpa, .{ .bytes = n })` | `!Store`: all the memory, taken here. `error.TooSmall`, `error.ShardTooLarge`, `error.SeedUnavailable` (no `seed` and no operating-system entropy) or `error.OutOfMemory` |
| `cache.Space(name, V, .{ .ttl_s = s })` | a keyspace, as a type |
| `Space.open(&store)` | the value a handler holds. Panics, naming the type, the limit and the Store's size, for a flat `V` whose entry (12-byte header, key and value) exceeds a quarter of one shard's ring, which every `put` would have refused |
| `space.put(key, value)` | stored for the Space's `ttl_s` |
| `space.putFor(key, value, ttl_s)` | stored for its own lifetime, at least `ttl_s` and at most `ttl_s + 1` seconds. `0` means "until the ring writes over it" |
| `space.get(key)` | `?V` for a flat value; `?[]const u8` and a `*Held` for bytes |
| `space.del(key)` | `bool`: whether there was anything to remove |
| `space.incr(key, delta)` | `PutError!V`: the new count, or `error.TooLarge` for a key over 65,535 bytes or an entry over a quarter of a shard's ring, never a count, for a Space whose `V` is an integer; any other `V` is a Refusal. The read, the add and the write happen under the shard's lock, so two callers count two. A key nobody wrote counts from zero and lives `ttl_s`; an existing key keeps the expiry it had. Saturating ([ADR 109](../adr/109-a-cache-holds-its-bytes-under-a-lock-it-can-spin-on.md)) |
| `space.putIfAbsent(key, value)` | stores only if the key is free, and says whether it was: `bool` for a flat value, `!bool` for bytes. One shard lock covers the scan and the write, so two racing callers get one `true` between them. This is how `nilo.Cached` claims a key ([ADR 188](../adr/188-a-route-can-say-cache-this-answer-for-a-minute.md)) |
| `space.putIfAbsentFor(key, value, ttl_s)` | the same claim for an entry that lives `ttl_s` seconds rather than the Space's own, with `0` for until the ring writes over it. This is how `nilo.Idempotent` claims its in-flight marker, so a marker a crashed handler left does not outlive the handler's own two minutes ([ADR 155](../adr/155-a-request-answered-once-is-answered-the-same-way-again.md)) |
| `space.getInto(key, buf)` | reads the bytes the way `get` does, but into a buffer you choose instead of a `Held`, for a caller whose buffer is an arena |
| `store.stats()` | hits, and the three different kinds of miss |
| `store.bytesHeld()` | every byte it will ever hold. This number never changes |
| `store.shardCount()` | how many shards it got, at most the `shards` asked for |
| `store.clear()` | remove everything |

### `space.get` and `Held`

**The value type decides the shape of `get`.** A flat value (a number, an enum, a struct with no pointer anywhere in it) has a size known while compiling, so it comes back by value and you declare no buffer. Bytes do not, so the Space says how large one can be and gives you the array type to read into:

<!-- compiles -->
```zig
const Pages = cache.Space("page", []const u8, .{ .max_bytes = 4096 });

fn render(pages: *Pages, path: []const u8) ![]const u8 {
    var held: Pages.Held = undefined;
    if (pages.get(path, &held)) |cached| return cached;
    const html = "…";
    try pages.put(path, html);
    return html;
}
```

**`Held` lives on your stack, and a fiber keeps its stack for as long as it stays suspended** ([ADR 062](../adr/062-where-a-connection-waits-is-what-it-costs.md)). A handler that declares a 4 KiB `Held` and returns adds nothing to an idle connection; one that holds it across a wait (a WebSocket loop, a held stream) adds 4 KiB to every connection in that state. It is an array you declare, not a buffer hidden inside the cache, because that is the only way you get to see the number.

### Values with pointers

**A value type with a pointer in it is a compile error, and the error names the field.** A cache entry outlives the call that wrote it, so a slice stored in one would point into a request that has ended. Go's cache stores `interface{}` and gets away with it because a garbage collector keeps the other end alive; there is none here. Encode the value and use a `Space` of `[]const u8`.

### `cache.open` options

**One number sets the memory, and it is a ceiling.** `bytes` is the whole budget: the ring the values live in and the table that points at them both come out of it, and `bytesHeld()` never exceeds it. Nothing is allocated after `open`, nothing grows, and there is no sweep. An entry goes when its time is up or when the ring writes over it.

| | |
|---|---|
| `.bytes` | the budget. Five sixths go to the values, the rest to the table |
| `.entries` | how many entries the table points at, when the default split is wrong. Clamped to the budget, not added to it |
| `.shards` | how many writers can be inside at once, and how many independent rings. Default 64, reduced if the budget cannot carry that many |
| `.seed` | the secret every hash is mixed with. `null` (the default) takes 8 bytes of operating-system entropy once in `open`, and `open` answers `error.SeedUnavailable` where there is none; pass one from `nilo.randomSecure` if you have a loop, or a fixed one in a test for deterministic placement. **A fixed seed in production lets whoever chooses keys pile them onto one shard** ([ADR 042](../adr/042-entropy-belongs-to-the-loop.md)) |

### `store.stats()`

**`stats()` tells you why the cache is not hitting.** A miss on a key nothing was ever written under counts as `misses`; one whose entry the ring wrote over counts as `evicted`; one past its time counts as `expired`. `Stats.evictionRate()` answers the question directly: high means the cache needs more `bytes`, and low with few hits means it is being asked about keys nobody wrote. `rescued` counts entries a read moved out of the write cursor's way, which is the admission policy working.

The counters are exact, but *reading* them is not a snapshot: nothing is locked while they are summed, because a lookup takes no lock either ([ADR 152](../adr/152-a-lookup-asks-the-cursor-afterwards-instead-of-taking-a-lock.md)). `evicted` also counts the rare read whose bytes a `put` overwrote mid-copy: that read found the key and lost it to the ring, which is what the word means.

### Locking and admission

**A `get` takes no lock**, so readers do not queue behind each other: 124.5M reads a second on eight threads, against 108.8M when reads did lock. A `put` takes one lock, per shard.

**A new entry has to be read once before it can use the whole ring.** It lands in a tenth of the ring and is copied into the rest when something reads it again, so a flood of keys nobody asks for twice cannot flush what the cache is holding (ADR 109). Two things follow: a cache with room left still admits freely, and a cache that is written to and never read keeps its first entries indefinitely instead of dropping the oldest.

### Sizing

Measured, not guessed: on a Zipf 0.99 workload, a ring one fortieth the size of the working set answers 63.9% of lookups, and one a fifth the size answers 94.1%, which is 96 to 98% of what any cache that size could reach. **Size for the hit rate you want, not for a multiple of the data**, and read `stats()` to find out whether you got it.

### Memory per entry

One entry costs 8 bytes of table slot, 12 bytes of header, and the key: about 20 bytes on top of the value. **At 200,000 entries that is 64.3 bytes an entry, against go-cache's 100.2, freecache's 132.0 and bigcache's 149.4.** The budget covers all of nilo's memory; the two Go ring caches bound only their values and put the index on top, so the same 12 MiB budget cost them 25.2 and 28.5 MiB of RSS ([`bench/result/cache.md`](../../bench/result/cache.md), which also records the single-threaded rows where go-cache is faster, and why).

### What it will not do

**It never leaves this process.** Two instances of your program have two caches that do not agree, neither survives a restart, and nothing here uses the network. That is the trade the module exists to make. ADR 110 argues it, and names `nilo_redis` as the alternative nobody has needed yet.
