# Middleware is an onion of Ctx functions, resolved at listen()

Middleware works at the `Ctx` layer, never the typed layer (ADR 0003). That much was already decided. What was not: its shape, how the chain is assembled, and where it attaches.

```zig
fn timing(c: *Ctx, next: Next) !void {
    var timer = try std.time.Timer.start();
    try next.run(c);
    std.log.info("{s} took {d}µs", .{ c.path().view(), timer.read() / 1000 });
}

try app.use(timing);
try app.use("/api", requireToken);
```

## The shape: onion, not before/after hooks

The obvious alternative is two hooks, `before(c)` and `after(c)`. It was rejected because it has nowhere to put the thing that connects them. The timing middleware above needs a start time visible to both halves; with separate hooks that has to go into per-request storage, which zfast deliberately does not have (see the limitation below). With an onion it is an ordinary local variable, and the borrow checker of the human reading it is `try next.run(c)` sitting in the middle.

The onion also makes short-circuiting fall out for free: a middleware that answers and simply does not call `next` ends the chain. Nothing extra has to be invented for auth rejection.

A middleware that fails goes through exactly the same path as a handler that fails — the fail functions and the mapping table of ADR 0005. `return fail.unauthorized("token expired", .{})` from a middleware and from a handler produce the same response. One error path, not two.

## The chain: a runtime slice, resolved at listen()

```zig
pub const Middleware = *const fn (*Ctx, Next) anyerror!void;

pub const Next = struct {
    rest: []const Middleware,
    handler: CtxHandler,

    pub fn run(self: Next, c: *Ctx) anyerror!void {
        if (self.rest.len == 0) return self.handler(c);
        return self.rest[0](c, .{ .rest = self.rest[1..], .handler = self.handler });
    }
};
```

`Next` is two words, passed by value, allocating nothing per request. The per-route slice is built once at `listen()`.

Fusing the whole chain at compile time into a single function would remove the indirect call per layer. It was rejected for the same reason ADR 0006 rejected a generic `App`: it would require every route's middleware set to be known at the point the route is registered, which forces registration order on the user to buy back a few nanoseconds across two to four layers. Well under the ADR 0001 threshold.

Resolving at `listen()` — rather than when each route is registered — kills Fiber's most reported gotcha, where `app.Use` after a route silently does not apply to it. In zfast, order between `use` and `get` does not matter. Order *among* `use` calls does, and that is the only ordering rule there is: **middleware run in the order they were registered; one registered with a prefix only runs on routes under that prefix.**

## The chain runs even when no route matches

Otherwise the logger never sees a 404 and CORS cannot answer a preflight for a path that does not exist — both of which are exactly when you want them. So the chain always runs; when nothing matched, the innermost call is the 404 responder instead of a handler.

## What this needs first: response headers

CORS cannot be built on today's `Ctx`. `send` writes a fixed set of headers and flushes immediately, so there is no way for a middleware to add `Access-Control-Allow-Origin`, and no way to add one afterwards either — the bytes are already gone.

So stage 4 starts with `c.setHeader(name, value)`, accumulating into the request arena and written out by `send`. Middleware sets headers on the way in, before calling `next`. This is a prerequisite, not a nice-to-have: two of the three remaining built-ins are blocked on it.

The flush-on-send model stays. It is what keeps the p99 metric honest, and it means the "after" half of a middleware can observe and clean up but cannot rewrite a response that has already gone out. That is a real constraint and the documentation has to say so, rather than letting people discover it by writing a middleware that silently does nothing.

## Consequences

- **Middleware cannot hand values to a handler.** This is the vocabulary's decision, not an oversight (CONTEXT.md: "produces no value for the handler"), and it has a real cost: auth middleware can reject a request but cannot pass the resolved user to the handler. v1 already ships auth's mechanism without its contents, so this holds for now — but it is the concrete thing a request-scoped value concept has to solve in v2, and it should be recorded as that rather than patched over with a `c.locals` map that would smuggle untyped state back in through the side door.
- **Route groups are deferred.** `app.use(prefix, mw)` covers the need that matters (auth on `/api`) without inventing a `Group` type that has to interact with the compile-time engine's comptime patterns. What is lost is only having to repeat the prefix on each route.
- Middleware is always a plain `Ctx` function. There is no typed middleware, so there are not two ways to write one.
- A middleware is an ordinary function taking two arguments, so like a handler it can be tested without starting a server — though unlike a handler it needs a `Ctx`, which is the layer it works at.
