# Metrics

**One call counts every request per route and serves the numbers at `/metrics` in Prometheus format, with no allocation per request.**

**Reference:** [`app.metrics`, `app.expose`](../reference/app.md#app), [`metrics` options](../reference/app.md#metrics-options) · **Design:** none; the decision is [ADR 079](../adr/079-the-route-table-is-the-registry.md)

[Errors](./errors.md) covers one request at a time: a request id, a log line, the sentence that says what went wrong. Metrics answer a different question: not *what happened to this request* but *what is happening to this service*. How many requests, at what statuses, how long.

## Turning it on

<!-- compiles: body -->
```zig
try app.metrics(.{});
```

That is all. A page appears at `/metrics` in the format Prometheus scrapes, and every request the server answers from then on is counted.

## What you get

Three metric families, and a fourth if you ask for one.

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

**Requests are counted per route, not per path.** `/users/1` and `/users/2` both count as `/users/:id`, because the counter belongs to the route's place in the route table, not to the path that arrived. So a crawler cannot create a million series, and counting a request costs no allocation ([ADR 079](../adr/079-the-route-table-is-the-registry.md)).

**The status class is counted per route, and the exact code per service.** Whether *this* route is failing is a question about the route, and the class (4xx, 5xx) answers it. Which codes the server hands out overall (how many 401s, how many 429s) is a question about the service, and `nilo_responses_total` answers that. Exact codes per route as well would cost four kilobytes a route instead of the 160 bytes a route costs now, for a table that is nearly all zeroes.

## Requests that matched no route

**A request that reached no route is still counted, under a label that says why.**

| Route label | What it is |
|---|---|
| `<unmatched>` | a path no route and no static file answers: a 404 |
| `<method not allowed>` | the path exists, the method does not: a 405 |
| `<static file>` | served out of a directory loaded by `static()` |
| `<unparsed>` | a head that never became a request: a 400, 408 or 431 |
| `<shed>` | a request refused for load: parsed, past `max_in_flight`, answered 503 before it was routed ([ADR 159](../adr/159-a-server-past-its-limit-says-so-at-once.md)) |

They are kept apart because a spike in one shared bucket tells you nothing. A wave of `<unmatched>` is a scanner, or a deploy that dropped a route. A wave of `<method not allowed>` is a form posting to a `GET`. A wave of `<unparsed>` is something on the network. A wave of `<shed>` is the machine, or the value `max_in_flight` was set to. Those are four different problems to chase.

## Protecting the page

**`/metrics` is an ordinary route, and nilo puts no authentication on it.** Middleware in front of its path applies to it, it appears in the route table, and it counts itself like any other route. nilo cannot know what your authentication is, so you protect the page by where you mount it and what you `use` there:

```zig
try app.useOn("/internal", requireOperator);
try app.metrics(.{ .path = "/internal/metrics" });
```

Or leave it on `/metrics` and have the proxy in front of you, the one already terminating TLS ([ADR 027](../adr/027-tls-is-terminated-in-front.md)), refuse it from outside.

## Counters of your own

**There is no registry: you own the counter, and nilo publishes it with [`app.expose`](../reference/app.md#app).** This is deliberate. A counter named at runtime means a string key, a hash on every increment, and a lock or a sharded table underneath, all on the path of every request, for a feature most requests do not use.

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

The name is registered once when the server starts, and the value is read once per scrape. The increment is one atomic add on memory you already have, which is as cheap as this can be: the same cost a registry would have, minus everything else a registry adds.

Use `.counter` for a number that only goes up and `.gauge` for one that goes both ways. Prometheus treats them differently and misreads a gauge declared as a counter.

The counter must be a `std.atomic.Value(u64)`. Handlers run on several threads at once ([Services](./services.md)), and a plain `u64` updated from all of them loses increments without any sign, so a plain one is a build error rather than a number that is quietly too low.

The name is checked while compiling too: letters, digits, `_` and `:`, not starting with a digit, and not starting with `nilo_`. Two families under one name make Prometheus reject the **whole page**, not just the one line, so an application would lose every metric over one badly chosen name.

## Timings

**Bucket boundaries are given in microseconds, and the page reports seconds**, because every tool downstream assumes base units.

<!-- compiles: body -->
```zig
try app.metrics(.{ .buckets = &.{ 250, 1_000, 10_000, 100_000 } });
```

The default covers everything from a route answering out of memory to one waiting on a database: `100, 500, 1_000, 5_000, 10_000, 50_000, 100_000, 1_000_000`.

**Every route uses the same boundaries**, on purpose. A histogram is useful because two routes can be compared on it directly, and per-route boundaries would turn that into a conversion. If your routes really run at very different scales, use a longer list, not two lists.

## What it costs

A counted request reads the clock once at each end, walks the bucket boundaries, and adds to four counters. It allocates nothing: the test that holds the allocation budget for the primary route ([ADR 017](../adr/017-the-trade-budget-has-four-axes.md)) runs a second time with metrics switched on, and still reads one allocation.

The table is allocated when the routes are resolved and never grows: 160 bytes a route with the default boundaries, plus 4,000 bytes for the exact status codes, once for the whole process. A server with a hundred routes uses about 20 KB. Nothing is added per connection.

A server that never calls `metrics()` pays a null check per request and 1,984 bytes of binary. One that does pays 17,416 bytes more.

The throughput cost was measured as four interleaved pairs and came back inside the noise (the sign changed twice), so it is recorded as unchanged rather than as a figure ([`bench/result/http.md`](../../bench/result/http.md)).

## What is not counted

- **Bytes sent.** It would be one more atomic on the write path and has not been measured, so it is not there.
- **Connections.** `nilo_requests_in_flight` counts requests, not sockets; an idle keep-alive connection is not in it.
- **Anything across a restart.** Counters start at zero when the process does. Prometheus expects that and handles resets, but a dashboard built on raw totals rather than `rate()` shows a cliff on every deploy.

## Reading it

A first scrape config, for a server on the default port:

```yaml
scrape_configs:
  - job_name: nilo
    static_configs:
      - targets: ["127.0.0.1:8787"]
```

Three queries worth having on a dashboard from the first day:

```promql
sum by (route) (rate(nilo_requests_total[1m]))                       # traffic
sum by (route) (rate(nilo_requests_total{status="5xx"}[5m]))         # errors
histogram_quantile(0.99, sum by (route, le) (
  rate(nilo_request_duration_seconds_bucket[5m])))                   # p99
```

**A route that has not answered anything yet has no series at all.** It appears the first time it answers. That keeps the page from being mostly zeroes on a server with hundreds of routes, and it means a query for a route you just deployed returns nothing until somebody calls it.
