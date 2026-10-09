# A cache in this process

**`nilo_cache` is an expiring cache in your program's own memory, with one fixed memory budget and typed keyspaces called Spaces; it is not shared between instances and does not survive a restart.**

**Reference:** [`nilo_cache`](../reference/cache.md#nilo_cache), [`Cached(Pages, options)`](../reference/handlers.md#cachedpages-options) · **Design:** [The in-process cache](../design/cache.md)

Use it for things like a cart looked up on every request, a rendered page, or an answer from somebody else's API that does not change for five minutes. It is a tool module: no event loop, no allocation after `open`, and no imports, so `zig test cache/cache.zig` runs all of it, and a program that is not a server can use it on its own ([ADR 109](../adr/109-a-cache-holds-its-bytes-under-a-lock-it-can-spin-on.md)).

**It never leaves this process.** Two instances of your program have two caches that do not agree, neither survives a restart, and nothing here touches the network. That is the trade-off the module exists for. [ADR 110](../adr/110-an-in-process-cache-and-a-redis-client-are-two-modules.md) is where the alternative, a Redis client, was considered and not built.

```zig
const cache = @import("nilo_cache");
```

and in `build.zig`, next to `nilo_http`:

```zig
.{ .name = "nilo_cache", .module = nilo.module("nilo_cache") },
```

## Spaces and the Store

**A Space is a named, typed keyspace, declared once as a type; a Store holds the memory that every Space shares.** A Space is to the cache what a Bucket is to an object store. Declare it next to your other types:

```zig
const Cart = struct { owner: u64, items: u16, total_cents: u64 };

const Carts = cache.Space("cart", Cart, .{ .ttl_s = 300 });
```

Open the Store once, where the program starts, and open the Spaces from it:

<!-- compiles: body -->
```zig
store = try cache.open(gpa, .{ .bytes = 64 << 20 });
defer store.deinit();
carts = Carts.open(&store);
try app.provide(&carts);
```

Then use it wherever the work is:

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

A handler holds a Space by pointer, as a [service](./services.md), or by value inside one. **Two Spaces over one Store share its memory but cannot read each other's keys**: the name is hashed at compile time into the seed every key goes through, and also stored in each entry, so a fingerprint collision cannot cross from one Space to another.

| | |
|---|---|
| `cache.open(gpa, .{ .bytes = n })` | `!Store`: all the memory, taken here and never again |
| `cache.Space(name, V, .{ .ttl_s = s })` | a keyspace, as a type |
| `Space.open(&store)` | the value a handler holds. Panics for a flat `V` the Store could never hold: an entry (12 bytes of header, the key and the value) over a quarter of one shard's ring, naming the type, the limit and the Store's size |
| `space.put(key, value)` | stores for the Space's `ttl_s` |
| `space.putFor(key, value, ttl_s)` | stores for a lifetime of its own. `0` means until the ring overwrites it |
| `space.get(key)` | `?V` for a flat value; `?[]const u8` and a `*Held` for bytes |
| `space.del(key)` | `bool`: whether there was anything to remove |
| `space.putIfAbsent(key, value)` | stores only if the key is free, and says whether it was. One lock covers the scan and the write, so of two callers racing, exactly one gets `true`: a claim, not a `get` then a `put`. This is how [`nilo.Cached`](#caching-a-routes-response-cached) claims a key |
| `space.putIfAbsentFor(key, value, ttl_s)` | the same claim for an entry that lives `ttl_s` seconds rather than the Space's own. This is how [`nilo.Idempotent`](./idempotency.md) claims a key, so its in-flight marker expires on its own schedule |
| `space.getInto(key, buf)` | the bytes, into a buffer you choose instead of a `Held`, for a caller whose buffer is the request arena |
| `store.stats()` | hits, and the three different kinds of miss |
| `store.bytesHeld()` | every byte it will ever hold; it never changes |
| `store.shardCount()` | how many shards it got, at most the `shards` asked for |
| `store.clear()` | remove everything |

`get` returns `null` for every kind of absence (never written, written and expired, written and evicted), and [`stats()`](#hit-and-miss-statistics) is what tells them apart.

## Space options

The third argument to `cache.Space`:

| Field | Default | |
|---|---|---|
| `ttl_s` | `0` | seconds an entry lives. Zero means until the ring overwrites it, which is a perfectly good answer for a cache, since nothing here sweeps for expired entries |
| `max_bytes` | 4096 | the largest value a `[]const u8` Space will hold, and the size of its `Held`. **Only used for that kind of Space** |

An empty name is a compile error, because the name is what keeps one Space's keys apart from another's. So is a `[]const u8` Space with a `max_bytes` of zero, or of more than 65,535: the length is stored in sixteen bits so that four slots of a bucket fit in one cache line.

## Storing structs, bytes and JSON

**The value type decides how `get` returns it: a flat value comes back by value, bytes come back through a buffer you declare.**

| The value | `get` |
|---|---|
| flat: a number, an enum, or a struct or array with no pointer anywhere in it | `get(key) ?V`, by value, no buffer anywhere |
| `[]const u8` | `get(key, &held) ?[]const u8`, into an array you declared |

A flat value has a size known at compile time, so it comes back by value and you declare nothing. Bytes do not, so the Space says how large a value can be and gives you the array type to read into:

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

**`Held` lives on your stack, and stack is kept per connection for as long as the connection lives** ([ADR 062](../adr/062-where-a-connection-waits-is-what-it-costs.md)). A handler that declares a 4 KiB `Held` adds 4 KiB to every connection that reaches it. It is an array you declare, not a buffer hidden inside the cache, because that is the only way you can see the number. A `put` of bytes is the only call that can fail: `error.TooLarge` when the value is over `max_bytes`, or over a quarter of one shard's ring.

**A value containing a pointer is a compile error, and the error names the field.** A cache entry outlives the call that wrote it (that is the whole point of a cache), so a slice stored in it would point into a request that has ended. Go's caches store `interface{}` and get away with it because a garbage collector keeps the other end alive; there is none here. Encode the value and use a Space of `[]const u8`, or keep an id in the cache and look the rest up.

For a value with more than one field, JSON is the usual encoding. `put` takes the bytes `std.json.Stringify` wrote into a buffer of yours. `getInto` reads them back into a buffer of yours too (here the request arena, since the value is going out in a response), and `std.json.parseFromSliceLeaky` turns them back into the struct:

<!-- compiles -->
```zig
const Note = struct { owner: u64, text: []const u8 };

const Notes = cache.Space("note", []const u8, .{ .max_bytes = 256 });

fn saveNote(notes: *Notes, key: []const u8, note: Note) !void {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try std.json.Stringify.value(note, .{}, &w);
    try notes.put(key, w.buffered());
}

fn loadNote(notes: *Notes, key: []const u8, c: *nilo.Ctx) !?Note {
    const buf = try c.arena().alloc(u8, 256);
    const bytes = notes.getInto(key, buf) orelse return null;
    return try std.json.parseFromSliceLeaky(Note, c.arena(), bytes, .{});
}
```

Use `parseFromSliceLeaky` rather than `parseFromSlice`, because there is nothing to call `.deinit()` on: the arena frees it, the same rule every row this module hands back follows.

There is no allocator to pass anywhere in this module, and the signatures show it: nothing allocates per operation.

## Counters (`incr`)

**A Space whose value is an integer has `incr`, an atomic add for rate limits and attempt counters.** Five OTPs per phone number an hour, failed sign-ins per email, a quota per API key: each is a count under a key, and `get` followed by `put` loses a count whenever two requests land between them ([ADR 109](../adr/109-a-cache-holds-its-bytes-under-a-lock-it-can-spin-on.md)):

<!-- compiles -->
```zig
const Attempts = cache.Space("signin", u32, .{ .ttl_s = 3600 });

fn signIn(attempts: *Attempts, email: []const u8) !void {
    if ((try attempts.incr(email, 1)) > 5) {
        return nilo.fail.tooManyRequests("too many attempts; try again in an hour", .{});
    }
    // … check the password, and `attempts.del(email)` when it matches …
}
```

`incr(key, delta)` returns the new count, and the read, the add and the write all happen under the shard's lock. That is the same lock a `put`'s copy runs under, and one add is not a wait, which is what the rule in [ADR 109](../adr/109-a-cache-holds-its-bytes-under-a-lock-it-can-spin-on.md) turned out to be about. Two requests arriving at once count two. A key too long to hold, over 65,535 bytes or a quarter of a shard's ring, is `error.TooLarge`, never a count, so the limit cannot be walked through with an oversized key.

A key nobody wrote starts from zero and lives for `ttl_s`. A key that already exists **keeps the expiry it had**, so the hour above is counted from the first attempt, not a window that slides with every attempt; `del` resets it early. The arithmetic saturates: a counter at its type's maximum stays there rather than wrapping to zero and reopening the quota. `incr(key, 0)` reads the count under the lock. A counter that is incremented again while it is still in the doorkeeper is promoted the way a read promotes, so unrelated writes do not reset it. `delta` has the Space's own type, so an unsigned Space only counts up; a counter that has to go down needs a Space of `i64`.

`nilo.Allowance` does the same thing keyed by client address only; use `incr` when the key is a user, a phone number or an API key. A Space of anything other than an integer has no `incr`, and the compiler says so.

## Store options

Passed to `cache.open`:

| Field | Default | |
|---|---|---|
| `bytes` | 8 MiB | **the whole budget, a hard limit rather than a target**. The ring that holds values and the table that points at them both come out of it, and `bytesHeld()` never exceeds it |
| `entries` | derived | how many entries the table can point at, for when the default split (the ring takes five sixths) is wrong. Clamped to the budget rather than added to it: raise it for many small values, lower it for few large ones |
| `shards` | 64 | how many independent tables and rings, and so how many writers can work at once. A fixed number rather than the core count, so the same program uses the same memory on two machines |
| `seed` | `null` | the secret every hash is mixed with, so nobody who chooses keys (emails, URLs) can precompute ones that share a shard and evict a chosen entry. `null` takes 8 bytes of operating-system entropy once in `open`; pass one from `nilo.randomSecure` if you have a loop. **A fixed seed belongs in a test**, where placement should be the same every run |

`open` returns `error.TooSmall` when the numbers do not make a working cache (under 64 KiB of value memory, or fewer entries than the shards have slots for), `error.ShardTooLarge` when one shard's ring would pass 4 GiB (give it more `shards` or fewer `bytes`), `error.SeedUnavailable` when no `seed` was given and the operating system had none to give (pass one), and `error.OutOfMemory` when the machine will not provide the budget.

**One number sets the memory, and it never changes.** Nothing is allocated after `open`, nothing grows, and there is no sweep: an entry disappears when its time is up or when the ring overwrites it. That number really is the total. Two Go caches built the same way mean something narrower by it: they limit their *values* and put an unbounded index on top, so 200,000 entries on a 12 MiB budget cost them 25.2 and 28.5 MiB of RSS, against this module's 12.0 ([`bench/result/cache.md`](../../bench/result/cache.md)).

## Choosing a size

**Size the cache for the hit rate you want, not as a multiple of your data.** Measured on a Zipf 0.99 workload, which is what real traffic looks like, a ring a fortieth the size of the working set answers 63.9% of lookups and one a fifth the size answers 94.1%. Both are 96 to 98% of the best any cache that size could do. Pick a budget, run it, and read `stats()`.

An entry costs about 20 bytes on top of its value: 8 for the table slot, 12 for the header, plus the key. On 200,000 entries that is 64.3 bytes an entry, against go-cache's 100.2, freecache's 132.0 and bigcache's 149.4.

**A new entry has to be read once before it gets the full ring** ([ADR 109](../adr/109-a-cache-holds-its-bytes-under-a-lock-it-can-spin-on.md)). It first lands in a tenth of the ring, and is copied into the rest when something reads it again, so a flood of keys nobody asks for twice cannot push out what the cache is holding. Two consequences are worth knowing in advance: a cache with free room still accepts everything, and a cache that is written to and never read keeps its first entries indefinitely rather than dropping the oldest.

## Hit and miss statistics

**`store.stats()` counts hits separately from the three kinds of miss**, which answers the question every cache eventually gets: why is it not hitting?

| Counter | |
|---|---|
| `hits` | |
| `misses` | nothing in the table under that key: it was never written, or the key is wrong |
| `evicted` | the table knew the key but the ring had moved past it. **This is the number that says the ring is too small** |
| `expired` | found, but past its time |
| `puts` | |
| `refused` | a value that did not fit in an entry, so nothing was stored |
| `rescued` | frequently read entries that a read moved out of the write cursor's way. **This is the number that says the admission policy is working** |
| `evictionRate()` | of the lookups that found nothing, the share caused by the ring being too small |

A high `evictionRate()` means the cache needs more `bytes`. A low one, with few hits, means it is being asked for keys nobody wrote. The counters are exact, but the reading is not a snapshot: nothing is locked while they are summed, because a lookup takes no lock either.

## What it costs

**A `get` takes no lock at all** ([ADR 152](../adr/152-a-lookup-asks-the-cursor-afterwards-instead-of-taking-a-lock.md)). It copies the value out, then checks the ring's write cursor to see whether anything overwrote those bytes while it was reading. Readers never queue behind each other: 124.5M reads a second on eight threads, against 108.8M when they did lock. A `put` takes one lock, per shard, around a `memcpy` and nothing else.

That last rule is what makes the module safe to use from a fiber. Zig's `std.Io.Mutex` needs an `Io`, which this layer does not have, so the lock spins, and a critical section containing nothing that waits always finishes and releases. It is also why nothing that waits may ever go inside one; that constraint is on the module, not on you.

**Per request, nothing**: a lookup touches one cache line for the slot and makes one copy for the value, and the request path's allocation budget is unchanged. Per connection, whatever `Held` you declared.

The TTL clock is the coarse monotonic one (a page the kernel updates on its own tick, not a vDSO call), because an operation costing a hundred nanoseconds should not spend a fifth of that on precision a TTL measured in seconds does not need. It reads whole seconds, truncated, so **a TTL of `n` seconds lives at least `n` and at most `n + 1`** (an entry put at 5.99 s with a TTL of one second is stored to expire at second 7). A clock that is monotonic does not advance while the machine is suspended, so nothing ages across a laptop sleep or a VM pause.

## Caching a route's response (`Cached`)

**[`nilo.Cached`](../reference/handlers.md#cachedpages-options) as a handler argument keeps the route's answer for a set time, so the handler does not run again until it expires.** The most common use of a cache in a web app is a page that costs four queries and changes once a minute. That is one argument on the handler, and the handler is otherwise the one you were going to write anyway:

<!-- compiles -->
```zig
const FrontPages = cache.Space("front", []const u8, .{ .max_bytes = 32 << 10 });

const Front = struct { headline: Str, stories: u32 };

fn frontPage(kept: nilo.Cached(FrontPages, .{ .ttl_s = 60 })) !Front {
    _ = kept;
    // …the four queries…
    return .{ .headline = .static("Selamat pagi"), .stories = 12 };
}
```

```
GET /                       → 200 {"headline":"Selamat pagi","stories":12}   Cache-Status: nilo; fwd=miss
GET /  (within a minute)    → 200 {"headline":"Selamat pagi","stories":12}   Cache-Status: nilo; hit
GET /?lang=en               → the handler runs: another query is another entry
GET /  (a minute later)     → the handler runs, and its new answer is the one kept
```

The first request runs the handler and **keeps what it returned** (the status, the body, and a `Response(T)`'s own headers) under the path and the query. Every request for the same thing within `ttl_s` gets that answer back, byte for byte, and the handler does not run. A handler *failure* is not kept; the next request runs the handler again. **An answer whose own headers include `Set-Cookie` is sent and not kept**, with a `warn`, because a kept one would give the first visitor's cookie to everybody; a cookie set through `c.setCookie` is not kept either, so only the visitor who made the miss gets it. Set cookies on a route that is not `Cached`.

`FrontPages` is a bytes Space, opened on the Store and given to the App as a service, the same way as [`Replays`](./idempotency.md#wiring-it-up). The record in it is the same record: `Cached` is `Idempotent` with a key made from the request line instead of a header ([ADR 188](../adr/188-a-route-can-say-cache-this-answer-for-a-minute.md)). The TTL belongs to the route, not the Space, so one Space can hold a page kept for a minute next to one kept for an hour.

**When an entry expires, only one request runs the handler.** Twenty browsers asking for the front page within the same hundred milliseconds are exactly what a cache is for, and a `get` followed by a `put` would run the four queries twenty times. The first request claims the key. The other nineteen find the claim and **wait for its answer**, checking every 10 ms for at most two seconds or half of what [`nilo.deadline`](./middleware.md) left the route, and get the answer when it arrives. A request that waits out the limit runs the handler itself. This is the one thing `nilo_cache` cannot do on its own, because its lock spins and nothing that waits may go inside it; the server is the layer with an `Io` to wait on.

**The key is set by `.by`**: `.path_and_query` by default, `.path` for a handler that ignores the query, or `.{ .header = "Accept-Language" }` for a page that differs per language (the same thing `Vary` says). The query is used exactly as it arrived, so `?a=1&b=2` and `?b=2&a=1` are two entries; nothing is normalised. `Cookie` and `Authorization` are refused as keys, because a cache keyed on a credential is a session store holding strangers' answers. Answer per-user requests without the cache.

**GET and HEAD only.** A kept answer is served to whoever asks next, and a POST's second client did not send the first client's body. `app.post(…)` refuses it at compile time; `app.route(.POST, …)` refuses it when the route is registered. For a write that should be answered once per client, use [`Idempotent`](./idempotency.md).

It costs what `Idempotent` costs, on the route that uses it and nowhere else: one arena allocation of `max_bytes` on a hit, one to encode the answer on a miss, and one to join the path and query when there is a query. Nothing on the stack.

## Testing

**A Store opens on `std.testing.allocator` with any budget over 64 KiB (give it a `.seed` for a placement that is the same every run), and a handler that takes a `*Carts` is an ordinary function:**

```zig
test "a cart is remembered for the next request" {
    var store = try cache.open(testing.allocator, .{ .bytes = 1 << 20, .shards = 4, .seed = 1 });
    defer store.deinit();
    var carts = Carts.open(&store);

    _ = try cart(&carts, 42);
    try testing.expect(carts.get("u42") != null);
}
```

To test expiry, use a short TTL rather than a long wait: `putFor(key, value, 1)` and a `std.Thread.sleep` of two seconds is the honest way, since a TTL of `n` lives up to `n + 1`, and the module's own suite does it once so yours does not have to.

## See also

- [The reference](../reference/cache.md#nilo_cache): the whole API as a list.
- [Services](./services.md): how the Space reaches a handler.
- [`bench/result/cache.md`](../../bench/result/cache.md): every number above, how it was measured, and the single-threaded results where go-cache is faster.
- [ADR 109](../adr/109-a-cache-holds-its-bytes-under-a-lock-it-can-spin-on.md): why a value may hold no pointer, and why the lock spins.
