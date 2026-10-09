# A request answered once is answered the same way again

**Status:** accepted
**Topic:** [idempotency](../design/idempotency.md)

A client that never hears back has to try again, and a server that runs the
handler again places the order twice. The roadmap carried this for a cycle
as the one small middleware with a design under it, "because it has to keep
what it already answered somewhere, and nothing in this framework stores
anything between requests." `nilo_cache` is that somewhere now
([ADR 109](./109-a-cache-holds-its-bytes-under-a-lock-it-can-spin-on.md)),
and this is the design.

## What it does now

```zig
const Replays = cache.Space("orders-replay", []const u8, .{ .ttl_s = 86_400, .max_bytes = 16 << 10 });

fn placeOrder(key: nilo.Idempotent(Replays, .{ .by = account }), body: NewOrder, …) !nilo.Status(201, Order)
```

The client sends `Idempotency-Key` and sends the same key on every retry. The
first request runs the handler and keeps what it returned — status, the
`Response(T)`'s own headers, every header the handler set through the `*Ctx`
(a session's `Set-Cookie`), the body — under the key; every later request
with that key gets that back, byte for byte, with `Idempotent-Replayed:
true` on it, and the handler does not run. Before the handler, three
refusals with the header named: 400 for no key, one over 255 bytes or one
the Space cannot hold once `.by` is joined to it, 409
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
held per connection ([ADR 062](./062-where-a-connection-waits-is-what-it-costs.md)):
a 16 KiB `Held` in a handler is 16 KiB on every idle connection that ever
reached it. The engine reads into the arena instead.

The claim is a marker — kind, status 0, fingerprint — put under the key
before the handler runs and overwritten with the answer after. A second
request finding the marker is the 409; one finding it with a different
fingerprint is the 422.

The marker is claimed with `putIfAbsentFor`, which takes a lifetime of its own (`idempotent.marker_ttl_s`, two minutes), and not with `putIfAbsent` under the Space's `ttl_s`. A handler that dies with the process leaves its marker behind, and with a Space that outlives the process a marker kept for the Space's day answers 409 to every retry for the day. The answer, put after, is kept for the Space's `ttl_s` as before. The price of the bound is that a handler still running after two minutes can be run a second time by a retry; a handler that takes longer than that wants a job queue rather than a key.

## Why the Space is a shape and not an import

`nilo_http` names no cache. `Replays` is any type with `getInto`,
`putIfAbsentFor`, `put`, `del`, `max_bytes` and `Held`, checked while compiling
with each missing one named — the way `nilo_parse` and `nilo_resolve` are
declarations read by name so that `http/` need not import `nilo_id`
([ADR 038](./038-a-module-sits-where-the-loop-puts-it.md)). A
`nilo_cache` bytes Space has all six. So does a type of the caller's own over
Redis, which is what a key that has to survive a restart or be shared between
instances wants, and the module graph is unchanged either way.

**The store the instances share is `sql.Replays`**, a table in the database the program already has ([ADR 268](./268-an-answer-kept-for-a-retry-is-a-row-when-instances-share-a-database.md)), which is why the six declarations are a contract and not a description of one cache. A store that can fail and needs the request's memory declares `takes_scope`, is called with the Scope first, and has no `Held`; `Idempotent` maps every failure of it but `TooLarge` to a 503 before the handler runs (the claim could not be taken, and running unclaimed is the double run the key exists to prevent) and keeps the answer-put failure out of the way of the answer already made. The in-memory Space answers once per process, as above, and the guide says which to pick.

## What it costs

Put against [ADR 017](./017-the-trade-budget-has-four-axes.md)'s four
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

**Running a request whose key the Space cannot hold.** A key is `by`, a NUL and the client's key, and a long `by(c)` string or a Space sized small cannot hold it, so the claim answers `TooLarge`. The first position treated that as unreachable (a marker is thirteen bytes) and crashed; the audit of `http/` at `39896d2` found it. Running the handler and sending the answer unkept, the way `Cached` answers a key too long for its Space (ADR 188), was the next position and was rejected: a cached page run twice costs a render, and a payment run twice costs a payment, which is the one thing the key exists to prevent. The request is refused with a 400 before the handler runs, with a `warn` naming the route and the length for the operator, whose fix is a larger Space or a shorter `by`. The claim is also released on every error after it is taken: a handler failure, and equally an argument after the key that fails to read (a body that does not parse, a `Bound` refused, an `Authorization` missing, a path param that does not convert), which `typed.zig`'s `wrap` releases in the same `errdefer` that releases a `Cached` claim. The first position released only a handler's failure, so a request that never reached the handler left the key answering 409 to the same retry and 422 to a corrected one for the Space's whole TTL, where a failure is meant to run again.

**Keeping an answer before its headers were checked.** The kept record went into the Space and then `sendRendered` called `setHeader` on each header, so a header the handler built with a CR or LF, which `setHeader` refuses as a 500, was kept anyway and every retry replayed that 500 until the TTL ran out, where a miss would have run the handler again. Every header, and an `.own` answer's label, is now checked by `Ctx.checkHeader` before the put, and a refusal releases the claim like any other error. `Cached` does the same (ADR 188).

**Keeping only the headers on the answer.** Only a `Response(T)`'s or `Bytes`' own headers were kept, so a sign-up that set its session through `c.setCookie` and was retried got the kept 201 with no `Set-Cookie`, where this page promises the answer byte for byte. The headers set through the Ctx after the claim was taken are kept too, ahead of the answer's own (the order they went out in the first time). Headers set before the claim, which are middleware's, set themselves again on a replay and are not kept.

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
the header — for the reason [ADR 153](./153-an-authorization-header-a-handler-can-ask-for.md)
refuses a chain.

**A middleware form for Ctx handlers.** A streamed CSV cannot be kept, and a
handler that writes its own response has said it wants the wire. The
Refusal names both.

## The alternative that was rejected

**A table of nilo's own in `http/`**, the way the allowance is one
([ADR 092](./092-an-allowance-is-a-table-sized-while-compiling.md)). The
allowance holds a 64-bit word per address and fits in `.bss`; a kept answer
is a body, and a table of bodies is a cache, with everything a cache has to
decide about eviction and expiry. `nilo_cache` had already decided those
([ADR 109](./109-a-cache-holds-its-bytes-under-a-lock-it-can-spin-on.md)),
and a second, worse cache inside `http/` would have been the thing ADR 038
exists to refuse.

## Consequences

- One file, `http/idempotent.zig`, outside the core: the record codec, the
  fingerprint, the Space check. One role and three functions in `typed.zig`;
  one flag on `openapi.Operation`.
- `Store.putIfAbsent`, `Space.putIfAbsent`, `Space.putIfAbsentFor` and
  `Space.getInto` in `nilo_cache`.
- Four refusals: not a bytes Space, the key asked for twice, a handler that
  returns nothing, a handler that returns a file or a redirect.
- The roadmap's list of small middleware loses `idempotency`.
