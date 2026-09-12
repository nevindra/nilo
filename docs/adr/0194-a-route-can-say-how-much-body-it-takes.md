# A route can say how much body it takes

`listen(.{ .max_body = … })` is one number for every route, and one number is
the wrong shape. A CSV import takes fifty megabytes; the sign-in beside it takes
two hundred bytes. A `max_body` loose enough for the first is no bound on the
second, and a server that raised it for the import has told every other route
to hold fifty megabytes in the arena for anybody who sends them.

This is the argument [ADR 0133](0133-a-route-can-say-how-long-it-has.md) made
about time, one axis over, and it gets the same answer: a route that wants its
own limit says so, through `with`.

```zig
try app.with(nilo.maxBody(50 << 20)).post("/import", importCsv);
try app.with(nilo.maxBody(1024)).post("/sign-in", signIn);
```

actix-web is where the shape was checked: its `JsonConfig::limit()` is set per
scope for exactly this reason, and axum's `DefaultBodyLimit` is a layer applied
per route. Neither has a single server-wide number and nothing else.

## It is one field, written before the body is read

`Ctx` already carries `_limits`, a copy of `listen()`'s `Limits` made per
request (`serve.zig`), and `body()` reads `_limits.max_body` at the moment it
decides how much to take. So the middleware writes that field and calls
`next`:

```zig
fn run(c: *Ctx, next: mw.Next) anyerror!void {
    c.giveBodyLimit(bytes);
    return next.run(c);
}
```

`giveBodyLimit` is public on `Ctx` for the same reason `giveDeadline` is: a
middleware of the caller's own may want to decide the number from the request
— a plan, a role — rather than from the route.

The body is read lazily, from inside the handler or the typed layer, so every
middleware has run by then; nothing had to move. That is also why lowering is
as ordinary as raising: a `Content-Length` past the route's number is a 413
before a byte is read, exactly as it is past `listen()`'s.

## What it bounds, and what it leaves alone

**Every read into the request arena.** `c.body()`, a JSON body, `Form(T)`,
`Bound(…)` of either, an `Idempotent` route's replay — they all go through
`body()`, so one field covers them. A chunked body is counted against the same
field as it arrives.

**Not `c.bodyStream()`.** It holds nothing in the arena — memory is bounded by
the buffer the handler passes in — and it carries a `max_bytes` of its own
([ADR 0020](0020-a-request-that-lasts-is-still-one-request.md)) because the question it
answers is a different one: not "how much may sit in memory" but "how much may
the client send at all". A route that streams a body sets that number on the
stream, where it always has.

## What it costs

**Nothing for a route without one.** `_limits.max_body` is what `listen()`
said, as before.

**For a route with one**: a single store into a field already on the `Ctx`,
which is on the fiber's frame. No allocation, no bytes per idle connection,
nothing on the hot path that was not there. `bytes` is `comptime`, so
`maxBody.with` is generic on it and a program that never calls it links none
of it.

**A refusal**: `nilo.maxBody(0)` stops compilation. Zero is what somebody
writes for "no limit", and the answer to that is to leave the middleware off.

## What was rejected

**A per-route field in `listen()`** — `.max_body = .{ .default = 1 << 20,
.routes = … }`. A table keyed by pattern is a second registry beside the route
table, and ADR 0100 already decided the route table is the registry. `with` is
where a route says what covers it ([ADR 0126](0126-a-route-can-say-what-covers-it.md)).

**A typed argument** — `nilo.Body(50 << 20, T)`. It reads well and it puts the
limit somewhere only a typed handler can reach. A `*Ctx` handler calling
`c.body()` wants the same limit and has no argument list to say it in.

**Making `bodyStream()` honour it too.** One number for two different
questions. A route streaming a gigabyte to disk under a 50 MB arena limit is a
sensible route, and the stream's own `max_bytes` is where its answer goes.
