# A request answered once is answered the same way again

A client that never hears back has to try again, and a server that runs the
handler again places the order twice. The roadmap carried this for a cycle
as the one small middleware with a design under it, "because it has to keep
what it already answered somewhere, and nothing in this framework stores
anything between requests." `nilo_cache` is that somewhere now
([ADR 0138](./0138-a-cache-holds-its-bytes-under-a-lock-it-can-spin-on.md)),
and this is the design.

## What it does now

```zig
const Replays = cache.Space("orders-replay", []const u8, .{ .ttl_s = 86_400, .max_bytes = 16 << 10 });

fn placeOrder(key: nilo.Idempotent(Replays, .{ .by = account }), body: NewOrder, …) !nilo.Status(201, Order)
```

The client sends `Idempotency-Key` and sends the same key on every retry. The
first request runs the handler and keeps what it returned — status, the
`Response(T)`'s own headers, the body — under the key; every later request
with that key gets that back, byte for byte, with `Idempotent-Replayed:
true` on it, and the handler does not run. Before the handler, three
refusals with the header named: 400 for no key or one over 255 bytes, 409
for a key still being answered, 422 for a key reused on a different request
— method, path, query and body are fingerprinted with it. What the handler
*failed* with is not kept, so a retry after a failure runs it again.

`.by` is whose key it is — a function of one `*Ctx` answering the account or
the tenant — and the kept answer is filed under both. Two clients choosing
the same key must never see each other's answer, and the header alone cannot
say whose it is.

## Why it is an argument and not a middleware

Every framework that has this ships it as middleware, and the middleware has
to intercept the response on its way out: buffer what the handler wrote,
copy it somewhere, let it go. nilo's typed handler *returns* its answer,
which means the engine has the value in hand before a byte is written — and
so it can render it, keep it, and send it, in that order, with nothing
intercepted. The argument is where that shows: a handler that returns
nothing and writes through the Ctx has no answer nilo can keep, and saying
so is a Refusal at the route rather than a surprise on the first replay.

It is also where the document shows. An argument is read by the OpenAPI
writer the way every other one is, so the route promises the header, the
409 and the 422 without a second registration.

## Why the cache grew a claim

The obvious implementation is `get` and then `put`: look for a kept answer,
run the handler if there is none, put the answer. Between the `get` and the
`put` on two threads, two requests with one key both find nothing and both
run the handler — which is the double charge the feature exists to prevent,
arriving through the feature.

So the Store gained `putIfAbsent`: the same key scan `put` already does,
with one more answer at the end of it, under the same shard lock. Two
callers racing for one key get one `.stored` and one `.taken`, whichever
threads they are on. `put` and `putIfAbsent` are one function with a
comptime flag, so the ordinary write compiles to exactly what it was — the
branch the claim adds is on a constant. And the Space gained `getInto`,
because its `get` reads into a `Held` on the caller's stack, and a stack is
held per connection ([ADR 0063](./0063-a-handlers-stack-is-per-connection.md)):
a 16 KiB `Held` in a handler is 16 KiB on every idle connection that ever
reached it. The engine reads into the arena instead.

The claim is a marker — kind, status 0, fingerprint — put under the key
before the handler runs and overwritten with the answer after. A second
request finding the marker is the 409; one finding it with a different
fingerprint is the 422.

## Why the Space is a shape and not an import

`nilo_http` names no cache. `Replays` is any type with `getInto`,
`putIfAbsent`, `put`, `del`, `max_bytes` and `Held`, checked while compiling
with each missing one named — the way `nilo_parse` and `nilo_resolve` are
declarations read by name so that `http/` need not import `nilo_id`
([ADR 0042](./0042-the-bottom-layer-holds-more-than-one-module.md)). A
`nilo_cache` bytes Space has all six. So does a type of the caller's own over
Redis, which is what a key that has to survive a restart or be shared between
instances wants, and the module graph is unchanged either way.

## What it costs

Put against [ADR 0018](./0018-the-trade-budget-has-three-axes.md)'s four
axes before it was written, and all of it on the route that asks:

- **Allocations per request.** A fresh request: one arena allocation to
  encode the answer, plus the JSON buffer it was taking anyway; when `by` is
  set, one more to join the two halves of the key. A replay: one arena
  allocation of `max_bytes` to read into. A route without the argument runs
  the code it ran before, and the budget test holds.
- **Memory per idle connection.** None. Nothing is on the stack, which is
  the point of `getInto`.
- **Throughput.** Per fresh request one cache claim and one write, and the
  body read once — `c.body()` keeps what it read, so the handler's `body:
  T` reads the same bytes. Per replay one cache read.
- **Binary size.** One record codec, one arm in the engine.

## What is deliberately not built

**Keeping what the handler failed with.** Stripe keeps error responses too.
Here a `fail.…` is not kept because a failure is the case a retry exists
for: a database that was down at the first attempt is the reason the client
is trying again, and answering the old 503 to it would make the key a
curse. A handler that wants a refusal kept returns it — `Status(409,
Problem)` is kept like any other value.

**A key without `.by` being a warning at run time.** It is a documented
default rather than a Refusal, because an endpoint with one caller — an
internal webhook receiver — is real and has nobody to scope by. The guide
says when to leave it off in one sentence.

**Reading the key from a query string or a cookie.** The header, and only
the header — for the reason [ADR 0191](./0191-an-authorization-header-a-handler-can-ask-for.md)
refuses a chain.

**A middleware form for Ctx handlers.** A streamed CSV cannot be kept, and a
handler that writes its own response has said it wants the wire. The
Refusal names both.

## The alternative that was rejected

**A table of nilo's own in `http/`**, the way the allowance is one
([ADR 0114](./0114-an-allowance-is-a-table-sized-while-compiling.md)). The
allowance holds a 64-bit word per address and fits in `.bss`; a kept answer
is a body, and a table of bodies is a cache, with everything a cache has to
decide about eviction and expiry. `nilo_cache` had already decided those
([ADR 0187](./0187-a-cache-that-admits-everything-forgets-what-mattered.md)),
and a second, worse cache inside `http/` would have been the thing ADR 0041
exists to refuse.

## Consequences

- One file, `http/idempotent.zig`, outside the core: the record codec, the
  fingerprint, the Space check. One role and three functions in `typed.zig`;
  one flag on `openapi.Operation`.
- `Store.putIfAbsent`, `Space.putIfAbsent` and `Space.getInto` in
  `nilo_cache`.
- Four refusals: not a bytes Space, the key asked for twice, a handler that
  returns nothing, a handler that returns a file or a redirect.
- The roadmap's list of small middleware loses `idempotency`.
