# 0100 — the route table is the registry

**Status:** accepted

## Context

The roadmap carried this for the whole life of the project:

> **There are no counters.** Correlation is covered, with request ids and JSON
> log lines, but metrics are not: how many requests, at what statuses, how long.
> That is a much larger surface than a log line. Where the numbers live, who
> reads them out, whether there is a registry, and whether any of it can be had
> without an allocation per request.

It is the only gap left in `nilo_http` with no workaround. Compression has one
written into its own entry — *"a proxy in front does this today and does it
well"* — and the megabyte arena is an optimisation of something that works. A
proxy cannot tell you which route is slow, which handler is returning 500s, or
how many requests are in flight, because it cannot see inside. Nothing could be
put on a wall about a deployed nilo server.

Four questions had to be answered, and the fourth is the one that decides the
other three: **can any of it be had without an allocation per request?**

## Decision

**A counter is an index into the route table, not a key in a map.**

Every metrics library this could have been modelled on labels its counters with
strings and hashes a set of them per request. That is where both of its costs
come from: the hash, and the cardinality — `/users/1` and `/users/2` become two
series, and a crawler makes a million of them.

nilo does not have to do either, because of something the router has had since
the first week: **the set of routes is closed by the time `listen()` resolves
them, and they are already numbered.** `Match` gains a `usize` index, the App
allocates one flat block of counters when the chains are resolved, and counting
a request is `counters[base + class] += 1` on memory that already exists. There
is no hash, there are no keys, `/users/1` and `/users/2` land on `/users/:id`
for free, and the answer to the fourth question is yes.

That decides the rest:

- **Where the numbers live.** One `[]Counter` on the App, `stride()` of them per
  slot, laid out flat rather than as a slice of structs so that the counters one
  request touches are next to each other and the neighbouring route's are not on
  the same line.
- **Who reads them out.** An ordinary route, registered by `app.metrics(.{})`,
  whose handler asks for the table the way every handler asks for anything
  long-lived — as a service, by type. **Nothing was added to `Ctx`**: a request
  that is not the scrape never looks at it.
- **Whether there is a registry.** No. See below.

### Four slots that are not routes, and why they are four

`<unparsed>`, `<unmatched>`, `<method not allowed>`, `<static file>` — first in
the table, so a route's slot is its index plus a constant and a request that
never got as far as matching is already pointing at the right one.

They were one slot in the first draft. One slot answers nothing: a wave of 4xx
against a single unnamed bucket is a scanner, or a deploy that dropped a route,
or a form posting to a `GET`, or something wrong on the network, and those are
four different afternoons. Four slots cost thirty-two words and no hot-path work.

### The counting is in `serveRequest`, not a middleware

`logger` is a middleware and this is not, which breaks the house pattern on
purpose.

A middleware sees the exchange. Metrics observe the **outcome**, and the outcome
is only settled in `serveRequest`: which route matched, whether the answer got
onto the wire before the handler failed, whether the request became a WebSocket.
`logger` has to reconstruct part of that today — `if (c._sent) c._status else
statusOf(err)` — and it gets it right. A second copy of that reasoning, kept in
step by nothing, is a second place to get it wrong, and the symptom would be
counters and log lines that disagree about the same request.

So the clock starts at the top of `serveRequest`, the slot is filled in wherever
the route was decided, and a `defer` finishes it — which covers all dozen ways
out, including the three that answer before a `Ctx` exists at all.

### There is no dynamic registry, and `expose` is why that is not a hole

A registry means a name per increment: a hash, and a lock or a shard table, on
the path of every request that counts anything. That is the surface the roadmap
warned about and it does not fit.

**But refusing it is only sound if a number the application owns can still be
published**, and the first draft of this decision missed that. Without it, an
application with an `orders_placed` of its own has a counter Prometheus can never
see, and it ends up running a second metrics server — at which point nilo's
metrics are not merely incomplete, they are a decoy.

`app.expose("orders_placed", .counter, &orders_placed)` is the answer, and it is
the `app.docs(opts)` shape applied to this: **registration-time cost only**. You
declare the atomic, you increment it, and nilo reads it once per scrape. The
increment is one `fetchAdd` on memory you already had — which is what a registry
would have cost *plus* the hash it would have added.

The refusal is therefore "no dynamic registry, no keyed hot path", not "no user
metrics". It has to be a `std.atomic.Value(u64)`, and a plain `u64` is a compile
error: handlers run on several threads and a non-atomic counter loses increments
without saying so.

### The status class is per route and the exact code is per process

Per-route exact codes is what a Prometheus user asks for first. Sized for the
worst case it is 500 `u64`s a route — four kilobytes, of which a route uses
three — against the 128 bytes one costs now, and the shape that avoids the array
is an open-addressed table per route, which is the registry being refused above,
smuggled back in one level down.

The two questions are also not the same question. *Is this route erroring* is
about the route, and the class answers it. *What is this service returning* —
how many 401s, how many 429s — is about the service, and one process-wide
`[500]Counter` answers that for four kilobytes total.

## What it costs

**Allocations per request: unchanged at zero, and measured rather than argued.**
`test "counting a request adds nothing to the allocation budget"` is the budget
test with `app.metrics(.{})` added: four requests through `handleRequest` with a
counting allocator, one allocation and no resizes, the same as with metrics off.

**Throughput: inside the noise, which is the honest answer rather than a win.**
Four interleaved pairs of `wrk -t1 -c50 -d10s` against `/users/7`, on the small
machine described in [`bench/result/http.md`](../../bench/result/http.md), put
the pairs at **−2.2%, +2.0%, −5.1% and +2.3%** — the sign changes twice, the
spread is seven points wide, and the means differ by 0.8% inside it. A margin
narrower than its own spread is quoted as a range or it is quoted wrong, so this
is reported as unchanged rather than as a figure.

It is also an **understatement** of what it could cost on a real server, and
that is worth writing down rather than leaving for somebody to find: this box
has two cores, so two executor threads contend for a counter where eight would
contend harder, and the benchmark hammers a single route, which is the worst
case for one cache line. **A per-thread shard is the answer if that ever shows
up.** It has not been built because nothing has measured it — see below.

**Memory per idle connection: unchanged, and it is structural rather than
lucky.** The `Record` is three words on `serveRequest`'s frame, which is
`noinline` and unwound before the connection loop waits — the shape
[ADR 0071](./0071-where-a-connection-waits-is-what-it-costs.md) established. The
`usize` added to `Match` is on the same frame. Nothing was added to `Ctx`, which
is the same frame again, and nothing to `App`, which is not per connection.

**Startup memory: 160 bytes a route** — 128 of counters with the default eight
boundaries, and 32 for the label — plus 4,000 bytes for the exact status codes,
once for the process. A hundred-route application is 20,640 bytes. Nothing per
connection.

**Binary size: 1,984 bytes unconditionally, and 17,416 more if you call it.**
Both stripped `ReleaseFast`, both against the previous commit rebuilt from a
`git archive` rather than quoted. The 1,984 is `example-hello`, `example-rest`
and `bench/main.zig` to the byte — none of them calls `metrics()`, so what they
pay is the `Record` on `serveRequest`'s frame and the `observe` it can reach,
behind a runtime null check the linker cannot fold. The 17,416 is two builds of
`bench/main.zig` differing by one line, and it is the row in
[ADR 0018](./0018-the-trade-budget-has-three-axes.md).

**That second figure was 37,112 until something was measured.** More than half
of it was `std.fmt`'s shortest-round-trip float formatter, pulled in by `{d}` on
an `f64` for the `le` labels — 19,696 bytes of float printer for a handful of
decimal points on a page scraped every fifteen seconds. A microsecond count is
six decimal places of a second and nothing else, so `writeSeconds` does it with
integer division and a trim. **Nobody would have looked for it**: the axis was
being checked out of habit, and the habit is what found it.

### One bug this found before it shipped

`Table.exposed` is a slice of the App's list, and appending to a list moves it.
`resolveChains` set the slice; `expose` did not re-set it. An ordinary `main`
never reaches that — `listen()` resolves the routes itself, after everything is
registered — but `start()` before `listen()`
([ADR 0079](./0079-there-is-a-phase-before-the-server.md)) does, and so does
every test, and what the page would read is freed memory. `expose` re-points it
on every append, which is one line and needs no ordering rule.

**The guard was seen to fail** with that line stubbed out, per
[ADR 0033](./0033-a-guard-is-not-a-guard-until-it-has-been-seen-to-fail.md) —
the stale slice is empty rather than dangling, so it fails as a missing line on
the page rather than as a crash, which is exactly the failure that would have
gone unnoticed.

## What was rejected

**A middleware, like `logger`.** See above: it cannot see the outcome without
reconstructing it, and one copy of that reconstruction is already one too many.

**A field on `Ctx` holding the table.** Eight bytes on every request for
something one route in the process reads. The service registry was already the
mechanism for exactly this and needed no new field anywhere.

**Per-thread sharded counters, up front.** The right answer *if* the atomics
turn out to cost something, and nothing has shown that they do. Building it
first would have been a shard index, padding to 64 bytes to keep the false
sharing from moving into our own array, and per-route-per-thread memory that
quietly scales with the executor count — paid on the strength of an argument
rather than a number, which is what
[ADR 0063](./0063-a-handlers-stack-is-per-connection.md) was written after.

**Emitting every series whether or not it has been reached.** Prometheus is
happier with a series that exists at zero, but the table is sized by the route
count: a five-hundred-route application would scrape most of a megabyte of
zeroes every fifteen seconds. A route appears the first time it answers, and the
guide says so.

**Authenticating `/metrics`.** nilo does not know what the application's
authentication is, and a built-in one would be a second, weaker copy of it. It
is an ordinary route, so `use("/internal", …)` in front of it is the answer, and
it is the answer the framework already has.

## What is deliberately not built

**Bytes sent** is one more atomic on the write path and nothing has measured
what that costs, so it is not there. **Connection counts** belong at the accept
layer rather than in `serveRequest`, which is a different file and a different
argument. Both are named in the roadmap rather than left to be rediscovered.
