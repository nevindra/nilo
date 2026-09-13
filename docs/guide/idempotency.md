# Answering once

A client that never hears back has to try again, and a server that runs the
handler again places the order twice. The `Idempotency-Key` header is the
answer every payment API settled on: the client makes up a key, sends it with
the request, and sends the *same* key on every retry; the server runs the
handler once per key and answers the retries with what it already said.

In nilo that is one argument, and the handler is otherwise the one you were
going to write:

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

The first request runs the handler and **keeps what it returned** — the
status, the body, and a `Response(T)`'s own headers, a `Location` say. Every
later request with the same key gets that back, byte for byte, with
`Idempotent-Replayed: true` on it, and the handler does not run. The card is
charged once. The row is inserted once.

## Wiring it up

`Replays` is a [`nilo_cache`](./cache.md) Space holding bytes, opened on a
Store and handed to the App as a service:

<!-- compiles: body -->
```zig
store = try cache.open(gpa, .{ .bytes = 16 << 20 });
var replays = Replays.open(&store);
try app.provide(&replays);
```

Then `try app.post("/orders", placeOrder)`, like any other route.

A Space rather than a table of nilo's own, because a cache is exactly what a
kept answer is: bounded, forgotten after a while, and allowed to miss — a
miss here is a retry that runs the handler again, which is what would have
happened without the feature. `ttl_s` is how long a client may keep retrying
against the same key; `max_bytes` is the largest answer kept, and one larger
is sent and not kept, with a line in the log saying so.

**The Space is a shape, not a dependency.** `nilo_http` names no cache; what
it asks of `Replays` is `getInto`, `putIfAbsent`, `put`, `del`, `max_bytes`
and `Held`, which a `nilo_cache` bytes Space has and a type of your own over
Redis could — for a key that has to survive a restart or be shared between
instances.

## Whose key it is

`.by` is the question the header cannot answer on its own. Two clients that
both pick `1` as their first key are two clients, and a key kept without
saying whose would hand the second one the first one's order. So `.by` is a
function of one `*Ctx` answering `?Str` — the account, the tenant, the API
key, whatever tells callers apart — and the kept answer is filed under both.
A [resolved value](./middleware.md#resolved-values) is the ordinary source:

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

Worked out once per request, so a handler that also takes `CurrentUser` does
not authenticate twice. Null from the function is a 403: an endpoint that
keeps answers per caller cannot keep one for nobody. Leave `.by` off only on
an endpoint with a single caller — an internal webhook receiver, say.

## The two refusals that keep a key honest

A key is for retrying *one* request. Two things a client can do with it are
mistakes, and both are answered before the handler runs, with the header
named:

| | |
|---|---|
| **409** | the same key is still being answered. The first request is in flight and the second arrived before it finished — a client retrying too soon. It waits by asking again |
| **422** | the same key on a *different* request: another body, path, query or method. The four are fingerprinted with the key, because answering the old order to a new body is the wrong order shipped |

And a **400** for no key at all, or one over 255 bytes. In the OpenAPI
document the route carries the header as a required parameter and the two
extra answers.

## What is kept, and what is not

**What the handler returned is kept, whatever the status.** A
`Status(201, Order)`, a `Response(T)` with a `Location`, a
`Status(409, Problem)` the handler chose — all kept, all replayed. So is an
answer a type wrote itself with `nilo_write`: the record carries its
`nilo_content_type`, and the replay goes out under the same label
([ADR 0195](../adr/0195-a-type-can-write-its-own-answer.md)). **What the
handler failed with is not.** A `fail.conflict(…)`, a `fail.unprocessable(…)`,
an `error.Disconnected` from the database: the answer goes out, the key is
released, and the next retry runs the handler again — which is what a retry
after a failure is for.

Two things cannot be kept, and asking for them is a Refusal rather than a
surprise on the first replay: a handler that holds the Ctx and writes its own
response has nothing nilo can send again, and a `FileBody` or a `Redirect` is
a file on disk or a status with a `Location`, not a body. Answer with the
thing that was made and let the client follow it.

## What it costs

On the route that asks, and nowhere else. A fresh request: one cache claim,
one arena allocation to encode the answer, one cache write, and the JSON
buffer the answer was going to take anyway. A replay: one cache read into an
arena allocation of `max_bytes`. **Nothing on the stack** — a `Held` there
would be `max_bytes` per idle connection for the life of it
([ADR 0063](../adr/0063-a-handlers-stack-is-per-connection.md)), which is why
the cache grew `getInto`.

The claim is the part worth knowing about: `putIfAbsent` takes the shard's
lock around the scan and the write, so two requests racing for one key get
one handler run between them wherever their threads are. A `get` followed by
a `put` would have run both
([ADR 0193](../adr/0193-a-request-answered-once-is-answered-the-same-way-again.md)).

## Testing

A handler with an `Idempotent` argument is still an ordinary function:
`placeOrder(.{ .key = .static("k") }, .{ .sku = .static("A1"), .qty = 1 })`
in a test, with no cache anywhere. The replay is tested through the
[test client](./testing.md) — send twice with one key, and assert the second
answer carries `Idempotent-Replayed` and the counter moved once.

## See also

- [The reference](../reference.md#idempotentreplays-options) — the surface as
  a list.
- [A cache in this process](./cache.md) — the Space that keeps the answers,
  and how to size it.
- [Checking somebody else's token](./jwt.md) — where `.by` usually gets its
  answer.
- [ADR 0193](../adr/0193-a-request-answered-once-is-answered-the-same-way-again.md)
  — why it is an argument and not a middleware, and what was refused.
