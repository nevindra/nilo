# Metrics

[Errors](./errors.md) covers one request at a time: a request id, a log line,
the sentence that says what went wrong. Metrics are the other question — not
*what happened to this request* but *what is happening to this service*. How
many requests, at what statuses, how long.

<!-- compiles: body -->
```zig
try app.metrics(.{});
```

That is the whole of it. A page appears at `/metrics` in the format Prometheus
scrapes, and every request the server answers from then on is counted.

## What you get

Three families, and a fourth if you ask for one.

```
nilo_requests_total{method="GET",route="/users/:id",status="2xx"} 48219
nilo_requests_total{method="GET",route="/users/:id",status="4xx"} 12
nilo_request_duration_seconds_bucket{method="GET",route="/users/:id",le="0.0001"} 47908
nilo_request_duration_seconds_bucket{method="GET",route="/users/:id",le="0.0005"} 48214
nilo_request_duration_seconds_bucket{method="GET",route="/users/:id",le="+Inf"} 48231
nilo_request_duration_seconds_sum{method="GET",route="/users/:id"} 2.914533
nilo_request_duration_seconds_count{method="GET",route="/users/:id"} 48231
nilo_responses_total{code="200"} 48219
nilo_responses_total{code="404"} 12
nilo_requests_in_flight 3
```

**Per route, not per path.** `/users/1` and `/users/2` are both `/users/:id`,
because the counter is the route's place in the table rather than something
keyed by the path that arrived. That is why a crawler cannot make you a million
series, and why counting a request costs no allocation
([ADR 0100](../adr/0100-the-route-table-is-the-registry.md)).

**The class is per route and the exact code is per service.** Whether *this*
route is erroring is a question about the route, and 4xx answers it. Which codes
this server is handing out — how many 401s, how many 429s — is a question about
the service, and `nilo_responses_total` answers that. Doing exact codes per route
as well would be four kilobytes a route against the hundred and twenty-eight
bytes one costs now, for a table that is nearly all zeroes.

## The four things that are not routes

A request that reached no route is still traffic, and it is counted under a name
that says which kind:

| Route label | What it is |
|---|---|
| `<unmatched>` | a path no route and no static file answers — a 404 |
| `<method not allowed>` | the path exists, the verb does not — a 405 |
| `<static file>` | served out of a directory loaded by `static()` |
| `<unparsed>` | a head that never became a request — a 400, 408 or 431 |

They are told apart rather than added together because a spike against one
unnamed bucket answers nothing. A wave of `<unmatched>` is a scanner or a deploy
that dropped a route; a wave of `<method not allowed>` is a form posting to a
`GET`; a wave of `<unparsed>` is something on the network. Those are three
different afternoons.

## Where the page lives, and who may read it

It is an **ordinary route**. Middleware in front of its path applies to it,
it appears in the route table, and it counts itself like anything else.

nilo puts no authentication on it, because it does not know what yours is. What
protects it is where you mount it and what you `use` there:

```zig
try app.useOn("/internal", requireOperator);
try app.metrics(.{ .path = "/internal/metrics" });
```

Or leave it on `/metrics` and let the thing in front of you — the proxy that is
already terminating TLS ([ADR 0028](../adr/0028-tls-is-terminated-in-front.md))
— refuse it from outside.

## Numbers of your own

There is **no registry**, and that is deliberate. A counter you could name at
runtime means a string key, a hash on every increment, and a lock or a shard
table underneath it — on the path of every request, for a feature most requests
do not use.

What there is instead: you own the counter, and nilo publishes it.

```zig
var orders_placed: std.atomic.Value(u64) = .init(0);

pub fn main() !void {
    // …
    try app.expose("orders_placed", .counter, &orders_placed);
    try app.metrics(.{});
}

fn placeOrder(db: *Db, incoming: Order) !nilo.Status(201, Order) {
    const saved = try db.insert(incoming);
    _ = orders_placed.fetchAdd(1, .monotonic);
    return .{ .value = saved };
}
```

The naming is paid once when the server starts and the reading once per scrape.
The increment is one atomic add on memory you already had, which is the cheapest
this can be — and it is the same cost a registry would have *plus* nothing.

`.counter` for something that only climbs and `.gauge` for something that goes
both ways; Prometheus treats them differently and will misread a gauge declared
as a counter.

It has to be a `std.atomic.Value(u64)`. Handlers run on several threads at once
([Services](./services.md)), and a plain `u64` counted from all of them loses
increments without ever saying so — so a plain one is a build error rather than
a number that is quietly low.

The name is checked while compiling too: letters, digits, `_` and `:`, not
starting with a digit, and not starting with `nilo_`. Two families under one
name make Prometheus reject the **whole page** rather than the one line, so an
application would lose every metric it had over a name it chose in passing.

## Timings

The buckets are microseconds, and the page reports seconds, because every tool
downstream assumes base units.

<!-- compiles: body -->
```zig
try app.metrics(.{ .buckets = &.{ 250, 1_000, 10_000, 100_000 } });
```

The default spans a route answering out of memory to one waiting on a database:
`100, 500, 1_000, 5_000, 10_000, 50_000, 100_000, 1_000_000`.

**The same boundaries for every route**, on purpose. A histogram earns its keep
because two routes can be put side by side on it, and per-route boundaries would
make that a conversion rather than a comparison. A server whose routes really do
live at different scales wants a longer list, not two lists.

## What it costs

A counted request does one clock read at each end, walks the bucket boundaries,
and adds to four counters. It allocates nothing — the test that holds the
allocation budget for the primary route
([ADR 0018](../adr/0018-the-trade-budget-has-three-axes.md)) is run a second
time with metrics switched on, and still reads one allocation.

The table is allocated when the routes are resolved and never grows: 160 bytes a
route with the default boundaries, plus 4,000 bytes for the exact status codes,
once for the whole process. A hundred-route server is about 20 KB. Nothing per
connection.

A server that never calls `metrics()` pays a null check per request and 1,984
bytes of binary. One that does pays 17,416 more.

The throughput cost was measured as four interleaved pairs and came back inside
the noise — the sign changed twice — so it is written down as unchanged rather
than as a figure ([`bench/result/http.md`](../../bench/result/http.md)).

## What is not counted

- **Bytes sent.** It is one more atomic on the write path and it has not been
  measured, so it is not there.
- **Connections.** `nilo_requests_in_flight` is requests, not sockets; an idle
  keep-alive connection holding nothing is not in it.
- **Anything across a restart.** Counters start at zero when the process does,
  which is what Prometheus expects — it handles resets — but a dashboard built
  on raw totals rather than `rate()` will show a cliff on every deploy.

## Reading it

A first scrape config, for a server on the default port:

```yaml
scrape_configs:
  - job_name: nilo
    static_configs:
      - targets: ["127.0.0.1:8787"]
```

Three queries worth having on the wall from the first day:

```promql
sum by (route) (rate(nilo_requests_total[1m]))                       # traffic
sum by (route) (rate(nilo_requests_total{status="5xx"}[5m]))         # errors
histogram_quantile(0.99, sum by (route, le) (
  rate(nilo_request_duration_seconds_bucket[5m])))                   # p99
```

A route that has answered nothing yet has no series at all — it appears the
first time it answers. That keeps a page from being mostly zeroes on a server
with hundreds of routes, and it means a query for a route you have just deployed
returns nothing until somebody calls it.
