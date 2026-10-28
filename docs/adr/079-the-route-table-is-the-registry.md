# The route table is the registry

**Status:** accepted
**Topic:** metrics

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

### There is no dynamic registry, and a service's own metrics are why that is not a hole

A registry means a name per increment: a hash, and a lock or a shard table, on
the path of every request that counts anything. That is the surface the roadmap
warned about and it does not fit.

**But refusing it is only sound if the application can still publish numbers of
its own**, and the first draft of this decision missed that. Without it, an
application with an `orders_total` of its own has a counter Prometheus can never
see, and it ends up running a second metrics server — at which point nilo's
metrics are not merely incomplete, they are a decoy. Two answers are in force.

**A service's metrics are fields of its type** (`http/metric_types.zig`). The
route table is closed when `listen()` resolves it; a service's metrics are
closed when the program is compiled, so the same argument holds one level down:

```zig
const Shop = struct {
    orders_total: nilo.Counter(Status) = .{},
    checkout_seconds: nilo.Histogram(void, .{ .buckets = .{ 5_000, 50_000, 500_000 } }) = .{},
    queue_depth: nilo.Gauge(void) = .{},
    pub const nilo_help = .{ .orders_total = "Orders, by status." };
};
```

`app.provide(&shop)` asks the type for fields that carry `nilo_metric` and keeps
a table of them in the registry entry, built while compiling (`Entry.metrics`,
null for a service with none, so the ordinary service pays nothing). The
metric's name is the field's name, exactly. `shop.orders_total.inc(.paid)` is a
`fetchAdd` on a cell whose address is arithmetic on the label the caller already
wrote.

- **A label is `void`, an exhaustive enum, or a struct of them.** The enum's
  names are the label's values and its short type name in snake case is the key
  (`Status` as `status`); a struct's field names are the keys. The cell is a
  mixed-radix sum, folded away for a constant. A string is not a label: that is
  the cardinality this decision exists to refuse.
- **Counter is `u64`, Gauge is `i64`.** A gauge is read as a difference, and a
  read between a `dec` landing and its `inc` becoming visible must show -1, not
  1.8e19.
- **Histogram boundaries are the metric's own**, up to sixteen integers. The
  bucket is found by comparing the value against all boundaries as an
  `@Vector` and counting the ones below it, then two `fetchAdd(.monotonic)`
  (the bucket, the sum). The count is the cumulative `+Inf` at scrape, so a
  page cannot disagree with itself. `.unit = .seconds` (the default) takes
  microseconds and prints seconds through `writeSeconds`, the integer printer
  of this ADR's binary-size finding; `.unit = .none` prints integers as given.
- **Every metric is `align(64)`** so two metrics never share a line; cells of
  one labelled metric are packed, and a histogram pads each row, which is what
  one `observe` writes twice.
- **Names are held by compile errors**, each with a file under `refusals/`: a
  counter ends `_total`, a histogram in seconds ends `_seconds`, a name is
  Prometheus' alphabet and does not start `nilo_` (nilo's own), a label is an
  exhaustive enum or a struct of them and does not use the keys `service` or
  `le`, boundaries are non-empty, integer, strictly climbing, first above zero
  and at most 16, a metric has at most **256 cells**, and a `nilo_help` key
  names a metric field that exists.
- **Every cell prints, zeros included.** A series that first appears with its
  first event loses that event to `rate()`. This is not the route table's rule
  (a route prints once reached) because a route table's size is the
  application's route count with no ceiling, and a metric's is the enum.
- **Every sample carries `service="<short type name>"`**, merged with the
  metric's own labels, so two services holding one family print one `# HELP` and
  `# TYPE` and all samples contiguous, grouped at scrape with no allocation. At
  `listen()` a program is refused if one name is two different families (a
  counter in one service and a gauge in another, or different label keys), if
  two services whose type names end alike share a family (their samples would
  be the same series), if one service holds a name twice, or if the services
  make **more than 1,024 series**, naming the biggest contributor. Both
  ceilings, 256 and 1,024, are **unmeasured**: they are the numbers past which
  a label has stopped being a label, and raising either needs a number.

**A module that cannot import `nilo_http` declares a table instead**
(ADR 038): `pub const nilo_metrics = .{ .{ "nilo_cache_hits_total", .counter,
"Lookups that found a value.", hitsOf } }`, where the reader is `fn (*const T)
u64`, or `?u64` to print no sample (a `Keyring` with no memo). Only std types, so
layering holds; the `nilo_` prefix is allowed here, because it is reserved for
nilo's own modules and the field path refuses it. A table row is one series, a
counter or a gauge, with the same suffix rule. `cache.Store` and `jwt.Keyring`
declare one.

**`app.expose("orders_placed", .counter, &orders_placed)` stays**, and it is the
`app.docs(opts)` shape applied to a number you already own: registration-time
cost only. You declare the atomic, you increment it, and nilo reads it once per
scrape. It has to be a `std.atomic.Value(u64)`, and a plain `u64` is a compile
error: handlers run on several threads and a non-atomic counter loses
increments without saying so. It has no labels; a service's field is what to
reach for when the number has a dimension.

The refusal is therefore "no dynamic registry, no keyed hot path", not "no user
metrics".

### Numbers nilo already keeps are read at the scrape, never kept for it

The page also carries what the process holds for its own reasons:
`nilo_watchdog_caught_total` (the detector's global, ADR 032),
`nilo_trace_spans_dropped_total` (the tracer's own atomic, present only when
`app.trace` is on, wired in `sizeMetrics`) and the `process_*` series that
Prometheus clients share, read from `/proc/self` in `http/process_stats.zig` on
Linux and absent elsewhere. Each is read by a scrape and by nothing else, so a
request pays nothing and a program that does not use the feature carries no
line about it.

**`nilo_http` does not name `nilo_cache` or `nilo_jwt`** (their build comments
say why: a program with no cache links no ring), so the cache's hits and misses
and the JWT memo's are not on the page. Reaching them takes a hook a service
declares and the registry calls, the way `nilo_ready` is, and that is a design
of its own on `docs/todo.md`.

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
[ADR 062](./062-where-a-connection-waits-is-what-it-costs.md) established. The
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
[ADR 017](./017-the-trade-budget-has-four-axes.md).

**That second figure was 37,112 until something was measured.** More than half
of it was `std.fmt`'s shortest-round-trip float formatter, pulled in by `{d}` on
an `f64` for the `le` labels — 19,696 bytes of float printer for a handful of
decimal points on a page scraped every fifteen seconds. A microsecond count is
six decimal places of a second and nothing else, so `writeSeconds` does it with
integer division and a trim. **Nobody would have looked for it**: the axis was
being checked out of habit, and the habit is what found it.

### What a service's metrics cost

**Allocations per request: zero**, held by `test "recording a service's metric
adds nothing to the allocation budget"` in `http/behaviour.zig`, the budget
request with a handler that does an `inc`, a `dec`, another `inc` and an
`observe`: one allocation (the JSON body), no resizes. **Per operation, as
reasoned and not measured:** an `inc` is one `lock xadd` on a cell whose address
is a constant when the label is; an `observe` is a vector compare, a popcount
and two `lock xadd`s. **Memory per idle connection: unchanged**, nothing is on
the connection's frame. **Startup memory:** 64 bytes a metric at least, a row
of a histogram `(buckets + 2) × 8` rounded up to 64. **Binary size: not
measured.** A program that provides no service with a metric field and no
`nilo_metrics` table gets a comptime-known null in each registry entry, so the
printing is not reachable; a program that does pays for the printer of the
kinds it uses and none of a float formatter. Throughput was not measured and
the 64-byte alignment is a design, not a result.

### One bug this found before it shipped

`Table.exposed` is a slice of the App's list, and appending to a list moves it.
`resolveChains` set the slice; `expose` did not re-set it. An ordinary `main`
never reaches that — `listen()` resolves the routes itself, after everything is
registered — but `start()` before `listen()`
([ADR 180](./180-work-that-needs-the-services-runs-on-their-loop.md)) does, and so does
every test, and what the page would read is freed memory. `expose` re-points it
on every append, which is one line and needs no ordering rule.

**The guard was seen to fail** with that line stubbed out, per
[ADR 032](./032-a-guard-is-not-a-guard-until-it-has-been-seen-to-fail.md) —
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
[ADR 062](./062-where-a-connection-waits-is-what-it-costs.md) was written after.

**Emitting every route's series whether or not it has been reached.**
Prometheus is happier with a series that exists at zero, but the table is sized
by the route count: a five-hundred-route application would scrape most of a
megabyte of zeroes every fifteen seconds. A route appears the first time it
answers, and the guide says so. **A service's metrics are the other way round
and print every cell**, because their count is bounded by an enum in the type
(at most 256 a metric, 1,024 a page) rather than by the application's size, and
a series that first appears with its first event loses that event to `rate()`.

**A string-keyed registry for services' metrics** (`registry.counter("orders",
.{ .status = "paid" })`). It is the library everyone knows and it is the one
this ADR started by refusing: a hash per increment, a lock or a shard table, and
a label that can be built from a request. The type-keyed version has the same
call site and none of the cost.

**Registering a global by name** (`app.family("orders_total", &global)`). It
works and it is `app.expose` with a label, but it leaves the metric apart from
the service that owns it, so the service label has nothing to say, a second
`Store` has nowhere to go, and every program writes the same wiring line. A
field in the service is found by `provide`, which is already called.

**A hook that writes its raw text** (`nilo_metrics_write(self, w)`). The
cheapest to build and the one nothing can check: the page would carry whatever
the service printed, so a duplicate `# TYPE`, a missing `service` label or an
unescaped quote takes down the whole page, which is the failure `checkExposed`
exists to prevent. The table of std types gives a module the same reach with the
header, the escaping and the grouping done once here.

**Per-thread shards for a service's counters.** Nothing has shown the atomics
cost anything, and a shard per thread per cell scales the memory with the
executor count. The 64-byte alignment keeps metrics from sharing a line; sharing
one cell between threads is what a single `Counter` costs, and a program that
measures it and finds it dear has a number to open this with, as the route
table's paragraph above says.

**Printing only the cells that have been touched.** The same argument as the
route table's, and it loses on a bounded set: the page would grow as a service
ran and `rate()` would miss the first event of each series.

**Authenticating `/metrics`.** nilo does not know what the application's
authentication is, and a built-in one would be a second, weaker copy of it. It
is an ordinary route, so `use("/internal", …)` in front of it is the answer, and
it is the answer the framework already has.

## What is deliberately not built

**Runtime labels** (a string built from a request) and **summaries**
(quantiles computed in the process) are not built: the first is the
cardinality this decision refuses, the second cannot be summed across
instances, which is what a histogram is for.

**Bytes sent** is one more atomic on the write path and nothing has measured
what that costs, so it is not there. **Connection counts** belong at the accept
layer rather than in `serveRequest`, which is a different file and a different
argument. Both are named in the roadmap rather than left to be rediscovered.
