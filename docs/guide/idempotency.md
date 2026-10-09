# Idempotency keys

**One argument, `nilo.Idempotent`, makes a route run its handler once per `Idempotency-Key` and answer every retry with the saved response.**

**Reference:** [`Idempotent(Replays, options)`](../reference/handlers.md#idempotentreplays-options) · **Design:** [Idempotency](../design/idempotency.md)

A client that never hears back has to try again, and a server that runs the handler again places the order twice. The `Idempotency-Key` header is the fix every payment API settled on: the client makes up a key, sends it with the request, and sends the *same* key on every retry. The server runs the handler once per key and answers the retries with what it already said.

In nilo that is one argument, and the handler is otherwise the one you were going to write.

(For a GET whose answer is the same for everybody for a minute, the related feature is [`Cached`](./cache.md#caching-a-routes-response-cached): the same saved record, keyed on the request line instead of a header.)

<!-- compiles -->
```zig
const cache = @import("nilo_cache");

const Replays = cache.Space("orders-replay", []const u8, .{
    .ttl_s = 86_400,          // a day: how long a client may keep retrying
    .max_bytes = 16 << 10,    // the largest answer kept
});

const NewOrder = struct { sku: Str, qty: u32 };
const Placed = struct { id: u64, sku: Str };
```

<!-- compiles -->
```zig
fn account(c: *nilo.Ctx) ?Str {
    return c.header("X-Account");
}

fn placeOrder(key: nilo.Idempotent(Replays, .{ .by = account }), body: NewOrder) !nilo.Status(201, Placed) {
    _ = key;
    // …charge the card, insert the row…
    return .{ .value = .{ .id = 7, .sku = body.sku } };
}
```

```
POST /orders                      Idempotency-Key: 4c1e…    → 201 {"id":7,"sku":"A1"}
POST /orders  (the retry)         Idempotency-Key: 4c1e…    → 201 {"id":7,"sku":"A1"}   Idempotent-Replayed: true
POST /orders  (a different body)  Idempotency-Key: 4c1e…    → 422
POST /orders  (no key)                                      → 400
```

The first request runs the handler and **keeps what it returned**: the status, the body, a `Response(T)`'s own headers such as a `Location`, and any header the handler set through the `*Ctx`, such as a session's `Set-Cookie`. Every later request with the same key gets that back, byte for byte, with `Idempotent-Replayed: true` on it, and the handler does not run. The card is charged once. The row is inserted once.

## Wiring it up

**`Replays` is a [`nilo_cache`](./cache.md) Space holding bytes, opened on a Store and given to the App as a service** (for one instance; [across instances](#once-across-instances-sqlreplays) it is a table):

<!-- compiles: body -->
```zig
store = try cache.open(gpa, .{ .bytes = 16 << 20 });
var replays = Replays.open(&store);
try app.provide(&replays);
```

Then `try app.post("/orders", placeOrder)`, like any other route.

It is a cache Space rather than a table of nilo's own because a saved answer is exactly what a cache holds: bounded, forgotten after a while, and allowed to miss. A miss here is a retry that runs the handler again, which is what would have happened without the feature. `ttl_s` is how long a client may keep retrying with the same key. `max_bytes` is the largest answer kept; a larger one is sent but not kept, with a line in the log saying so.

**nilo needs the Space's methods, not `nilo_cache` itself.** `nilo_http` names no cache. What it asks of `Replays` is `getInto`, `putIfAbsentFor`, `put`, `del`, `max_bytes` and `Held`, which a `nilo_cache` bytes Space has. `putIfAbsentFor(key, value, ttl_s)` is the claim with a lifetime of its own, which is how the in-flight marker expires after two minutes even when the Space keeps answers for a day. A type of your own could have them too; one that can fail or needs the request's memory declares `pub const takes_scope = true`, is called with the Scope first (`put(scope, key, value)`), and has no `Held`. That is what [`sql.Replays`](#once-across-instances-sqlreplays) is.

**A `cache.Space` belongs to one process, and so does the answer it keeps.** A retry that the balancer sends to a second instance finds nothing there and runs the handler again, and a rolling deploy is two instances while it lasts ([ADR 110](../adr/110-an-in-process-cache-and-a-redis-client-are-two-modules.md)). That is fine for a webhook receiver with one instance and not for a payment API with two: the next section is the store they share.

## Once across instances: `sql.Replays`

**`sql.Replays(Db, options)` keeps the answers in a table in the database you already have, and every instance that shares the database answers once.** It is the same argument with a different type in it:

<!-- compiles -->
```zig
const sql = @import("nilo_sql");

const SharedReplays = sql.Replays(Db, .{
    .name = "orders",         // keeps this store's keys out of another's in the table they share
    .ttl_s = 86_400,
    .max_bytes = 16 << 10,
});

comptime {
    _ = SharedReplays.Row;
}
```

<!-- compiles -->
```zig
fn placeOrderEverywhere(key: nilo.Idempotent(SharedReplays, .{ .by = account }), body: NewOrder) !nilo.Status(201, Placed) {
    _ = key;
    return .{ .value = .{ .id = 7, .sku = body.sku } };
}
```

The handler does not change. The table is yours to create, the way the queue's is: `SharedReplays.Row` goes into `createMissing`, or a migration, beside your own rows, and into `db.checking` so the server refuses to start without it.

<!-- compiles: body -->
```zig
try sql.migrate.createMissing(db, &run, .{ .tables = &.{SharedReplays.Row} });
var shared = SharedReplays.open(db);
try app.provide(&shared);
```

Then `try app.post("/orders", placeOrderEverywhere)`, like any other route.

**Two instances receiving one key at once run the handler once.** The claim is two statements, each atomic in the database: `INSERT … ON CONFLICT DO NOTHING` takes a free key, and if the key was taken, an `UPDATE` takes a row that has run out. The loser is told 409 (still being answered) or gets the answer once it is kept. The in-flight marker lives two minutes, as with a Space, so an instance that dies mid-handler costs a retry two minutes.

**What a database that does not answer does, so you know what to alert on:**

| When | What happens |
|---|---|
| it cannot be asked at the claim | a **503** naming the header, and the handler does not run: running it unclaimed is the double charge the key exists to prevent. The client retries |
| the handler fails | the key is released with a `DELETE`; if that fails too the marker is left, and the retry is told 409 for up to two minutes and then runs |
| it cannot take the answer after the handler ran | the answer is sent, a `warn` says so, and the marker stays: a retry is told 409 for up to two minutes, then runs the handler again. It is not deleted, because a retry that runs at once is the double run |

**What it cannot do is make the handler's own write and the answer commit together.** The marker, your writes and the answer are separate transactions, so a process that dies between your commit and the answer's leaves a marker and a handler that will run again after two minutes and find its own earlier write. Put a unique key on what the handler inserts, as you would for any at-least-once job ([ADR 160](../adr/160-a-queue-is-a-table-in-the-database-you-already-have.md)).

**Nothing deletes a key that never comes back.** A read ignores an expired row and a retry writes over one, but a key used once stays in the table. Run `sweep` from a [scheduled job](./background.md), once an hour is plenty:

<!-- compiles -->
```zig
fn sweepReplays(shared_replays: *SharedReplays, scope: *nilo.Run) !void {
    _ = try shared_replays.sweep(scope);
}
```

**What it costs, on the routes that ask and nowhere else.** A write waits for the database to flush its log. On Postgres 18 at defaults on one disk: a claim of a free key 1.0 ms, the put of the answer 1.6 ms, a claim of a key somebody holds 54 µs, a read 44 µs, so a fresh request pays about 2.6 to 3.3 ms before its handler and a replay or a 409 about 100 µs ([`bench/result/sql.md`](https://github.com/nevindra/nilo/blob/main/bench/result/sql.md) §27). The cost is the disk's: with `synchronous_commit = off` for the role that serves the table the same calls are tens of microseconds, at the price that a crash can lose the last few commits, which for a marker costs a retry and for an answer costs the handler running again. `expires_at` is written and compared in each instance's own clock, so keep the instances within seconds of each other (NTP does).

## Keys per caller (`.by`)

**`.by` says whose key it is, because the header alone cannot.** Two clients that both pick `1` as their first key are two different clients, and a key saved without saying whose would hand the second client the first one's order. So `.by` is a function of one `*Ctx` returning `?Str` (the account, the tenant, the API key, whatever tells callers apart), and the saved answer is filed under both. A [resolved value](./middleware.md#resolved-values) is the usual source:

<!-- compiles -->
```zig
const CurrentUser = struct {
    pub const nilo_resolve = whoIsThis;
    id: Str,
};

fn whoIsThis(c: *nilo.Ctx) !CurrentUser {
    const auth = try c.authorization(.bearer);
    return .{ .id = auth.value };            // …after verifying it, in a real one
}

fn caller(c: *nilo.Ctx) ?Str {
    const user = c.resolve(CurrentUser) catch return null;
    return user.id;
}
```

A resolved value is worked out once per request, so a handler that also takes `CurrentUser` does not authenticate twice. If the function returns null, the answer is a 403: an endpoint that keeps answers per caller cannot keep one for nobody. Leave `.by` off only on an endpoint with a single caller, such as an internal webhook receiver.

## Reusing a key wrongly: 409 and 422

**A key is for retrying one request, and two misuses are rejected before the handler runs**, with the header named in the answer:

| | |
|---|---|
| **409** | the same key is still being answered. The first request is in flight and the second arrived before it finished: a client retrying too soon. It waits by asking again |
| **422** | the same key on a *different* request: another body, path, query or method. All four are fingerprinted with the key, because answering a new body with the old order would ship the wrong order |

A request with no key, or a key over 255 bytes, gets a **400**. So does a key the Space itself cannot hold (a long `.by` string joined to it, or a very small Space), before the handler runs, with a `warn` naming the route: running it unkept would let a retry run it twice, which is what the key is for. In the OpenAPI document the route lists the header as a required parameter, along with the two extra answers.

## Which answers are kept

**What the handler returned is kept, whatever the status.** A `Status(201, Order)`, a `Response(T)` with a `Location`, a `Status(409, Problem)` the handler chose: all are kept and replayed. So is an answer a type wrote itself with `nilo_write`: the record carries its `nilo_content_type`, and the replay goes out with the same content type ([ADR 157](../adr/157-a-type-can-write-its-own-answer.md)).

**What the handler failed with is not kept.** For a `fail.conflict(…)`, a `fail.unprocessable(…)`, or an `error.Disconnected` from the database, the answer goes out, the key is released, and the next retry runs the handler again, which is the point of retrying after a failure. So is a request that never reached the handler: a body that does not parse, a `Bound` that is refused or an `Authorization` that is missing releases the key too, and the same key with a corrected body runs. An answer whose header nilo would refuse to send (a newline in a value) is not kept either; the handler runs again on the retry.

Two kinds of answer cannot be kept, and asking for them is a Refusal (a compile error) rather than a surprise on the first replay. A handler that holds the Ctx and writes its own response leaves nothing nilo can send again. A `FileBody` or a `Redirect` is a file on disk or a status with a `Location`, not a body. Answer with the thing that was created and let the client follow it.

## What it costs

**Only the route that asks pays anything.** A fresh request costs one cache claim, one arena allocation to encode the answer, one cache write, and the JSON buffer the answer was going to use anyway. A replay costs one cache read into an arena allocation of `max_bytes`. **Nothing goes on the stack**: a `Held` there would cost `max_bytes` per idle connection for its whole life ([ADR 062](../adr/062-where-a-connection-waits-is-what-it-costs.md)), which is why the cache gained `getInto`.

The claim is the part worth understanding. `putIfAbsentFor` holds the shard's lock around the scan and the write, so two requests racing for one key get one handler run between them, whichever threads they are on. A `get` followed by a `put` would have run both ([ADR 155](../adr/155-a-request-answered-once-is-answered-the-same-way-again.md)).

## Testing

A handler with an `Idempotent` argument is still an ordinary function: call `placeOrder(.{ .key = .static("k") }, .{ .sku = .static("A1"), .qty = 1 })` in a test, with no cache anywhere. Test the replay through the [test client](./testing.md): send twice with one key, and assert that the second answer carries `Idempotent-Replayed` and the counter moved once.

## See also

- [The reference](../reference/handlers.md#idempotentreplays-options): every option, as a list.
- [A cache in this process](./cache.md): the Space that keeps the answers, and how to size it.
- [`sql.Replays`](../reference/sql.md#sqlreplays-the-answers-two-instances-share): the table, its options and its calls.
- [Checking somebody else's token](./jwt.md): where `.by` usually gets its answer.
- [ADR 155](../adr/155-a-request-answered-once-is-answered-the-same-way-again.md): why it is an argument and not a middleware, and what was rejected.
