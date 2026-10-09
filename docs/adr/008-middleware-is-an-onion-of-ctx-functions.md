# Middleware is an onion of Ctx functions, resolved at listen()

**Status:** accepted
**Topic:** [middleware](../design/middleware.md)

## Context

Middleware works at the `Ctx` layer, never the typed layer ([ADR 002](./002-typed-handlers-are-a-thin-layer-over-ctx.md)). What had to be decided was its shape, how a chain is assembled, where it attaches, and how a route removes itself from one.

Every API with accounts has the same shape: one prefix, almost all of it behind a session, and two routes inside it that cannot be, because you cannot require a session to create one. An application built with `app.use(mw)`, `app.useOn(prefix, mw)` and a group's own `use` had no way to say "except this route", so `g.use(requireOperator)` on a group mounted at `/v1` guarded `/v1/sign-up` too, and sign-up answered 401 on the first run, in ten tests at once. **Registering the open routes first did not help, and that is the expensive part: it looks like it should.** Chains are resolved at `listen()` (below), so mount order carries no meaning at all, and the failure is silent, immediate and un-Googleable.

## Decision

```zig
fn timing(c: *Ctx, next: Next) !void {
    const started = nilo.monotonicNanos();
    try next.run(c);
    std.log.info("{s} took {d}µs", .{ c.path().view(), (nilo.monotonicNanos() - started) / std.time.ns_per_us });
}

const v1 = app.group("/v1");
try v1.use(requireOperator);

const open = v1.without(requireOperator);
try open.post("/sign-up", signUp);
```

### An onion, not before/after hooks

The obvious alternative is two hooks, `before(c)` and `after(c)`. It has nowhere to put the thing that connects them: the timing middleware above needs a start time visible to both halves, and with separate hooks that value has to live in state nilo does not keep per request. With an onion it is an ordinary local variable, and the borrow checker of the human reading it is `try next.run(c)` sitting in the middle.

**The onion makes short-circuiting fall out for free.** A middleware that answers and does not call `next` ends the chain; nothing extra was invented for auth rejection. A middleware that fails goes through the same path as a handler that fails, the fail functions and the mapping table of [ADR 004](./004-http-errors-via-fail-functions.md): `return fail.unauthorized("token expired", .{})` from either produces the same response. One error path, not two.

**A middleware that neither answers nor calls `next` is a 500 that names it.** The empty 200 nilo sends for a request nothing answered is what a handler returning `void` means ([ADR 120](./120-a-ctx-handler-that-returns-nothing-may-have-written-it.md)); a guard written `if (!ok(c)) return;` that forgot its 401 used to get the same 200, with the handler never run, and nothing in the types or the tests could tell. `Next.run` writes into the Ctx how many layers were left below the deepest one reached, 0 once the handler runs, and App gives the empty 200 only at 0. Otherwise it logs `middleware N of M returned without answering and without calling next.run(c)` at `warn` and answers 500. The count is a `u8` on the Ctx, saturating at 255, which fits in padding the Ctx already had (824 bytes with it or without, where a `u16` made it 832), and one store per layer; no allocation.

### The chain is a runtime slice, resolved at listen()

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

`Next` is two words, passed by value, allocating nothing per request. The per-route slice is built once, at `listen()`, by `resolveChains`.

**Resolving at `listen()`, rather than at each route's registration, is what makes mount order irrelevant.** It kills the gotcha other frameworks report most, where a middleware added after a route silently does not apply to it. In nilo, order between `use`/`useOn` and a verb method does not matter. Order *among* `use`/`useOn` calls does, and that is the only ordering rule there is: middleware run in the order they were registered, and one registered with a prefix only runs on routes under that prefix.

**A route whose pattern cannot answer the prefix's question has its chain resolved per request.** `useOn("/files/private", auth)` beside `GET /files/*` is under the prefix for `/files/private/x` and not for `/files/public/x`, and the same holds for `useOn("/admin")` beside `/:page/settings` or a root `/*`: a `:param` or a `*` opposite a literal segment of the prefix. Compared at `listen()` against the pattern, `private` against `*`, it attached nothing, and `/files/private/x` was served without `auth`. Such a route is marked at `listen()` (`middleware.reach`), and its chain is built per request from the real path, one arena allocation that only such a route pays; a chain that cannot be built closes the connection rather than run the handler unguarded. A path segment is compared as it decodes, so `%70rivate` is `private`. Every other route still reads the chain it was given at `listen()`. Exemptions and attachments are by pattern, as before.

Fusing the whole chain into a single function at compile time would remove the indirect call per layer. It was rejected for the same reason [ADR 005](./005-services-via-a-runtime-registry.md) rejected a generic `App`: it would force every route's middleware set to be known at the point the route is registered, buying back a few nanoseconds across two to four layers, well under the [ADR 017](./017-the-trade-budget-has-four-axes.md) threshold.

### The chain runs even when no route matches

Otherwise the logger never sees a 404 and CORS cannot answer a preflight for a path that does not exist, both of which are exactly when they matter. So the chain always runs; when nothing matched, the innermost call is the 404 responder instead of a handler.

### An answer is written when it is sent, unless a middleware holds it

`c.setHeader(name, value)` accumulates into the request arena and is written out by `send`. Middleware sets headers before calling `next`, which is what CORS is built on. A finished response is flushed before the connection waits, not before `send` returns, so a pipelining client gets one write for many responses ([ADR 201](./201-a-response-is-flushed-before-the-connection-waits.md)).

**A middleware that changes an answer after `next` asks for it: `next.hold(c)` in place of `next.run(c)`.** It hands back a `nilo.Answer`, the answer below unwritten, and the answer is written when the chain has unwound, not when the handler sent it. What has not had to leave yet can still change: a whole answer's status, headers, body and trailers (`Answer.replace` swaps the whole answer, a 304 for an ETag middleware), and a stream's trailers and its end, whose head left when it opened. A failure after `hold` replaces a held whole answer with its own. A failure below `hold` comes back as an error, as from `run`, so a header meant for every answer, failures included, is set with `defer c.setHeader(...) catch {};` around `next.run(c)`.

**A body handed to `c.send` under a hold is copied into the arena**, because the handler's frame and anything its `defer` released are gone by the time the answer is written. That copy is free while it fits in what the arena keeps (16 KiB) and costly beyond it; a body that already outlives the chain is not copied: a typed handler's return, `sendJson`, `c.sendKept` and a static file.

**A header set after the head of an answer was written is refused** with a sentence naming `hold`. It used to go into a list nothing would write again and be lost without a word, which is what Go's `net/http` and Gin still do.

### A group can say a middleware does not cover it

`without(mw)` hands back the same group, or the App, with that middleware off for the routes registered through what it returns:

```zig
const v1 = app.group("/v1");
try v1.use(requireOperator);

const open = v1.without(requireOperator);
try open.post("/sign-up", signUp);
try open.post("/sign-in", signIn);
```

Everything else in the chain still runs: the logger still logs the sign-up, CORS still answers its preflight. It is one middleware off one route, not a route with no chain.

Three properties, each of them the reason a different bad shape was not taken:

- **The default stays deny.** The guard is on the group; a route says otherwise about itself. A route added next month is guarded because nobody did anything.
- **The exception is where the route is.** Renaming `/sign-up` moves it, because the exception is recorded by the same `joined(prefix, pattern)` the registration uses; there is no second copy of the string to fall out of step.
- **The URL layout is not decided by the middleware.** `/sign-up` stays inside `/v1` where it belongs, rather than being moved outside the prefix to dodge the guard.

**A registration that is refused records nothing.** An exemption, and an attachment from `with`, is keyed on the pattern, the method and the middleware, not on the route, so one recorded before the route was refused applied to the route already there: `v1.without(auth).tryRoute(.POST, "/sign-in", b)` returning `DuplicateRoute` used to exempt the first `/v1/sign-in` from `auth`. The group's `add` takes the room for its exemptions and attachments first, registers the route, and only then records them, so nothing after the route goes in can fail; `App.register` checks a name already taken with the path, before the router holds anything, where it used to find it after (the audit of `http/` at `39896d2`). A `tryRoute` caller who asked for the error back hears the explanation at `warn`, not `err`, which is a server refusing to start ([ADR 207](./207-a-try-call-hands-back-the-error-and-says-nothing.md) keeps the line because the error cannot name the route it collided with).

The exclusion list is a comptime parameter of the group's type, `GroupOf(prefix, excluded)`, of which `Group(prefix)` (a plain `app.group(prefix)`) is the empty case, so which routes carry an exception is settled while compiling, and the `inline for` that records them compiles to nothing for a group that has none.

### `mounted_at` is published

A group publishes the prefix it was built with as `mounted_at`, and so does the App (`""`). A `Middleware` is a bare function pointer with nowhere to keep state, so an exclusion or a plugin that needs to know its own prefix used to have no way to ask; a `mount(g: anytype)` plugin now reads `@TypeOf(g).mounted_at` rather than parsing `@typeName` or being handed the prefix a second time as an argument that can fall out of step with the first.

### A guard reads what it needs; it does not hand it over

A middleware guarding `/api` can reject a request but was once unable to pass the user it had just resolved on to the handler, which would have meant a `c.locals` map, untyped state smuggled back in through the side door. **The thing middleware was asked for, a resolved user, is a resolved value instead** ([ADR 015](./015-resolved-values-are-declared-by-their-type.md)): worked out once per request from a function the type itself carries, and asked for by writing the type in a handler's argument list. A middleware guards, a resolved value provides, and `c.resolve(T)` is how a guard reads one without making the handler behind it work the same thing out twice.

## What was rejected

**A path skip-list inside the middleware.** Default-deny, which is the right direction, but the exception is a string compared against `c.path()` in a framework whose whole claim is that the compiler checks the contract. Rename the route and the guard protects a 404 while the real one goes open, and nothing fails to compile.

**`useOn` per resource subgroup**, guarding each prefix by hand. Declarative, and default-*allow*: every new prefix is unguarded until somebody remembers to guard it. This is the shape that ships a security hole eventually.

**Moving the open routes out of the prefix**, `/sign-in` beside `/v1` rather than inside it. Free, but it means the URL layout is decided by the middleware rather than by the API.

**Per-route middleware, `g.postWith(&.{guard}, "/x", h)`.** The positive form of the subgroup idea, and still default-allow. It also needs a second copy of every verb method.

**A `g.open(pattern, handler)` that runs no middleware at all.** Simpler, and wrong: it drops the logger and CORS from exactly the routes an operator most wants to see logged.

**Making `use`/`useOn` take an `except` list of patterns.** The strings end up in the `use` call rather than on the middleware, a smaller version of the same problem: renaming the route still leaves the exception behind, now in a different file.

**Fusing the chain at compile time.** Rejected above under the chain's shape: the saving is under the [ADR 017](./017-the-trade-budget-has-four-axes.md) threshold and the cost is registration order the user has to keep.

**Two hooks, `before`/`after`, in place of the onion.** Rejected above: nowhere to hold what connects them without per-request storage nilo does not keep.

**A `c.locals` map for a middleware to hand a value to the handler.** Untyped state smuggled in through the side door; closed instead by resolved values, above.

**Leaving `Group` out to keep the compile-time engine simple.** It now exists precisely because `without`'s exclusion list needs a type to carry it, and it is what a plugin reads its own prefix from through `mounted_at`.

**Every answer held until the chain unwinds**, which is what Axum and Hono give a middleware. Holding itself cost nothing measurable, but every body handed to `c.send` then has to be copied into the arena, and past the 16 KiB the arena keeps that copy cost 63% of throughput at 64 KiB and 87% at 1 MiB, with 8.6 times the peak memory ([`bench/result/http.md`](../../bench/result/http.md#holding-every-answer-until-the-chain-unwinds)). `hold` puts that cost on the route behind a middleware that asked.

**A hook per framing for changing an answer**, a function a framing calls before it writes. It would be a second way to do what the onion does, with nowhere to keep state between the halves, which is the reason the onion was chosen.

**A header set after the answer was written, kept losing without a word.** The behaviour Go and Gin ship. Nothing could tell the author the header never left.

**An empty 200 for a chain a middleware stopped without a word**, which was the rule until the audit of `http/` at `39896d2`: it was the handler's rule applied to a layer that is not the handler.

**A middleware that has to return proof it answered or called `next`**, a value only `next.run` and `c.send` can make. The compiler would catch the forgotten 401 rather than a test, and every middleware ever written would change signature for one mistake a 500 and a log line already make loud the first time the route is hit.

## What it costs

| Axis | Cost |
|---|---|
| Allocations per request | 0. `Next` is two words passed by value; a request that matches no `without` exemption allocates nothing extra. A route behind `next.hold` pays a copy of a body sent with `c.send`, one arena bump, and a growth of the arena past 16 KiB when the body is larger |
| Memory per idle connection | 0 |
| Throughput and p99 | 1.3% of throughput in the default build for the bookkeeping a hold needs ([ADR 254](./254-an-answer-can-carry-trailers.md) has the run). An indirect call per middleware layer, two to four deep on a typical route; fusing the chain to remove it was measured against [ADR 017](./017-the-trade-budget-has-four-axes.md)'s threshold and not worth the ordering it would force on the caller |
| Binary size | The exclusion list is a comptime parameter folded away for a group with none; an App with no `without` call carries one empty `ArrayList` and never looks at it |

Chains, and the exemptions inside them, are resolved once per route in `resolveChains`, which runs at `listen()`; the request path only ever sees a resolved slice of function pointers.
