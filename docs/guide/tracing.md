# Tracing

**`app.trace` makes every request a span and sends the spans to any OpenTelemetry receiver: a collector, Jaeger, Tempo, Honeycomb or another vendor.**

**Reference:** [`app.trace`](../reference/app.md#app), [trace options](../reference/app.md#trace-options), [`c.span` and `c.traceId`](../reference/ctx.md#tracing) · **Design:** none; the decision is [ADR 247](../adr/247-a-request-is-a-span-and-the-trace-leaves-as-otlp.md)

[Metrics](./metrics.md) tell you that `/orders` got slow at 14:02. A trace tells you which request it was, and that the time went into the call to the payment service rather than into the database. This page turns that on.

## One line

<!-- compiles: body -->
```zig
try app.trace(.{ .service = "orders" });
```

**From here every request is a server span.** It is named for the route that matched (`GET /users/:id`, not `/users/7`), and it carries the method, the route, the status and the path. A 5xx marks it as failed. The spans go out as OTLP over HTTP to `http://localhost:4318/v1/traces`, the address an OpenTelemetry Collector listens on by default, every second in one batch.

To try it locally, run Jaeger, which takes OTLP directly:

```sh
docker run --rm -p 16686:16686 -p 4318:4318 jaegertracing/jaeger:latest
```

Send a few requests, then open `http://localhost:16686` and pick your service.

## Sending to a vendor

**Point `endpoint` at the vendor and put its key in `headers`.** `/v1/traces` is added for you, the same way OpenTelemetry's own SDKs treat `OTEL_EXPORTER_OTLP_ENDPOINT`:

<!-- compiles: body -->
```zig
try app.trace(.{
    .service = "orders",
    .endpoint = "https://api.honeycomb.io",
    .headers = &.{.{ .name = "x-honeycomb-team", .value = "your-api-key" }},
    .resource = &.{.{ .key = "deployment.environment.name", .value = "production" }},
});
```

The text is borrowed, so it has to outlive the App. A key read with [`nilo_config`](./config.md) does: settings are read once in `main` and kept.

## Following a request into the next service

**A request that arrives with a `traceparent` header joins that trace, and every call it makes through [`nilo_fetch`](./fetch.md) carries one.** So a trace started by your front end, or by another service, continues through this one and into the next with nothing written:

```
browser ──traceparent──► orders (server span)
                            └─ POST api.stripe.com (client span) ──traceparent──► stripe
```

The call is a client span of its own, a child of the request's span, with the host, the port and the status. A call that fails names its error. The `traceparent` it sends names the client span, so the next service's span hangs under it.

A server on the open internet may not want a stranger choosing its trace ids, or asking for every request to be recorded. `.join = false` starts a new trace for every request, whatever it arrives with.

## A span of your own

**`c.span(name)` measures a piece of a handler, and anything it calls becomes its child.**

<!-- compiles -->
```zig
fn checkout(c: *nilo.Ctx) !void {
    var span = c.span("reserve stock");
    defer span.end();
    reserve(c) catch |err| {
        span.fail(err);
        return err;
    };
}

fn reserve(c: *nilo.Ctx) !void {
    _ = c; // …the work being measured…
}
```

`defer span.end()` records it however the handler leaves. `span.fail(err)` in the `catch` marks it failed with the error's name, so a trace view shows which step failed and why. While the span is open, a `nilo_fetch` call or another `c.span` inside it is its child.

**The name is a comptime string, and that is on purpose.** A trace view groups spans by name. A name with an id in it (`reserve stock for order 9123`) makes every span its own group, which is the most common way a tracing bill gets out of hand. A name that has to be known while compiling cannot carry one.

## Finding a request's trace

**On an App that traces, every log line carries the trace id**: `trace=4bf92f…` in the text format and `"trace_id"` in JSON, the field name OpenTelemetry's own log model uses. `c.traceId()` gives the same 32 characters to a handler, for an error page that wants to say what to quote to support:

<!-- compiles -->
```zig
fn failed(c: *nilo.Ctx) !void {
    if (c.traceId()) |trace_id| try c.setHeader("X-Trace-Id", &trace_id);
    return nilo.fail.internal("something went wrong", .{});
}
```

## Recording only some of it

**`.sample` is the fraction of traces that start here to record**, from 0 to 1, and it defaults to all of them. The decision is read off the trace id rather than a coin toss. Two services that sample at the same ratio therefore record the same traces, and a trace is never half there. A request that joined a trace follows the decision of the service that started it.

A request whose trace is not recorded still sends `traceparent` on its calls, with the flag that says "not recorded", so the services after it do the same.

## What it costs

**On the request path: two clock reads, two random ids, one look through the request headers, and a copy of the finished span.** No allocation, no lock, no network. Each thread copies its spans into a ring of its own, and a fiber of the server's drains the rings and sends them. If the receiver is slow or down, the rings fill and new spans are dropped and counted. Your requests are never held up waiting for it. A receiver that cannot be reached is reported in the log at most once a minute.

**Held for the life of the App:** one ring per thread of `spans_per_thread` spans (1,024 by default, about 200 KB a thread) and one batch. Nothing per connection.

When the server stops, what is still in the rings is sent on the way out.

## What it does not do

- **Metrics and logs as OTLP.** Metrics are [a Prometheus page](./metrics.md), and logs are lines on stderr that a collector can read and join to the trace by `trace_id`.
- **Attributes of your own on a span.** A span has its name, its timing, and whether it failed and why. Values of your own wait for the first application that needs them.
- **A span per SQL statement.** `db.watching` reports a slow statement with its plan today ([Running a database](./sql/running.md)).
- **The `OTEL_*` environment variables, read for you.** Read them with `nilo_config` into the fields above. Two lines, and the names are yours to choose.
