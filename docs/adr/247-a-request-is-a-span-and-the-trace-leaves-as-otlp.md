# A request is a span, and the trace leaves as OTLP

**Status:** accepted
**Topic:** tracing
**Extends:** [ADR 158](./158-a-request-id-goes-out-with-the-call.md), whose rejected `traceparent` this decides

A request id ([ADR 158](./158-a-request-id-goes-out-with-the-call.md)) lines up one log line with another. It cannot say where the time in a slow request went, or which service it went to. That is what a trace is for, and every backend that reads traces (an OpenTelemetry Collector, Jaeger, Tempo, Honeycomb, Datadog) reads one format, OTLP, and one header, W3C `traceparent`. ADR 158 refused `traceparent` because nilo had no spans and an invented parent is worse than none. This decision gives nilo the spans.

## Decision

**`app.trace(.{ .service = "orders" })` makes every request a server span, every `nilo_fetch` call under it a client span, and `c.span(name)` the rest, and sends them as OTLP/HTTP protobuf to `endpoint` + `/v1/traces`.**

```zig
try app.trace(.{ .service = "orders" });            // a collector on localhost:4318

var span = c.span("reserve stock");                 // in a handler
defer span.end();
reserve(c) catch |err| { span.fail(err); return err; };
```

- **A server span is named for the route**, `GET /users/:id`, and carries the attributes the HTTP semantic conventions call required: `http.request.method` (`_OTHER` for a method outside the list), `http.route`, `http.response.status_code`, `url.path` (its first 96 bytes). A 5xx is an error with `error.type`. A request that matched no route is named for its method alone.
- **A request with a valid `traceparent` joins that trace**, and its `tracestate` goes out on its calls as it came. A malformed one is treated as absent, as the specification asks (`core/trace.zig`). `.join = false` starts a new trace for every request, for a server that does not want a stranger choosing its trace ids or asking for every request to be recorded.
- **A `nilo_fetch` call is a client span** with `server.address`, `server.port`, the status, and the error's name when the call failed. The `traceparent` it sends names the client span, so the next service's span hangs under it. A call made while a trace is not recorded still sends `traceparent` with the sampled flag clear.
- **`c.span(comptime name)`** is a child of the current span and is current itself until `end`. A call or another span inside it is its child.
- **Sampling is parent-based, then a ratio of the trace id.** A joined trace follows its parent's flag. One that starts here is recorded when the trace id's low 64 bits fall under `sample` × 2⁶⁴, the TraceIdRatio rule, so two services at the same ratio record the same traces.
- **The log line carries the trace id** (`trace=` in text, `"trace_id"` in JSON, OpenTelemetry's own field name), and `c.traceId()` gives it to a handler.

### Where it lives

**The trace context is in Core, because two layers need it and neither may name the other** ([ADR 057](./057-percent-is-needed-by-two-layers.md)). The server reads `traceparent` and `nilo_fetch`, a Fitting that cannot import `nilo_http` ([ADR 061](./061-a-fitting-borrows-the-loop.md)), writes it. `core/trace.zig` holds the header's parse and format, and two optional Scope declarations hold the rest: `traceBegin(self) ?Outbound` before a call and `traceEnd(self, Outbound, Ended)` after it. They travel the way `requestId` and `entropyInto` already do, by `@hasDecl` on the Scope's type and a slot in `AnyScope`'s table. A `Run` declares neither and is not asked.

**The span store is the server's, and the request path touches only `http/trace.zig`.** Every executor thread writes finished spans into a ring of its own: a bounded queue after Vyukov's, with a sequence number per cell, so recording is one compare-and-swap and a copy of a fixed-size record. Everything a record points at outlives the server: a route pattern, a comptime name, a method's or an error's name. A path or a host is copied into the record. The span and trace ids come from a xoshiro generator per thread, seeded once from the operating system.

**The network half is `http/otlp.zig`, the one file in `nilo_http` that names `nilo_fetch` and `nilo_proto`, and only `app.trace` reaches it.** The exporter is a Service, so its client starts on the server's loop, and its stop hook sends what is left. A fiber spawned by `app.trace` wakes every `flush_ms`, drains the rings into one batch, encodes it with `nilo_proto` and posts it with one `nilo_fetch` client. The App holds the exporter as a pointer with its type erased, so `App`'s own declarations never name `otlp.zig`. Zig analyses a function's body only when something calls it, so a program that never calls `app.trace` compiles neither module, which keeps the property ADR 061 bought for `nilo_fetch` and ADR 245 for `nilo_proto`.

**The request path reaches the tracer only through pointers that `app.trace` sets.** `serve.zig` calls `app.trace_hooks.begin` and `.finish` when they are set, and `Ctx.traceBegin` and `traceEnd`, which `nilo_fetch` calls on every call, go through `Tracer.begin_call` and `end_call`, which `Tracer.init` fills in. A call behind a runtime null check is still linked, and the first build did it that way: every program carried the id generator, the header walk, the ring and the URL parse whether it traced or not, 12 KB on `examples/hello`. Behind the pointers, that code is reached only from `app.trace`'s body, so the linker never sees it in a program that does not trace. For the same reason the host and port of a call are read off its URL by the tracer, not by `nilo_fetch`: `core.trace.Ended` carries the URL.

### What it costs

Against [ADR 017](./017-the-trade-budget-has-four-axes.md):

| axis | without `app.trace` | with it |
|---|---|---|
| allocations per request | 0 | **0**: `test "a traced request stays inside the same allocation budget"` |
| memory per idle connection | **+0**: `examples/hello`, 5,190 bytes a connection at 10,000 both before and after, two interleaved rounds | **+0 marginal**: 7,233 bytes a connection from 5,000 to 10,000 against 7,232 without, and about 1.6 MB fixed for the rings, the batch and the exporter's client |
| throughput | one null check on each side of the request | two clock reads, two ids, one walk of the request headers, one copy of a ~200-byte record, two indirect calls |
| binary size (stripped `ReleaseFast`) | **+432 B** on `hello`, +384 on `rest`, +0 on `nilo-size-s3_none`; **+3,024** on `outbound`, which calls through `nilo_fetch` | **+690,224 B**, nearly all of it `std.http.Client` and TLS |

**Held for the life of the App, when it traces:** one ring per executor thread, of `spans_per_thread` records (1,024 by default, about 200 KB a thread), and one batch of `max_batch`, allocated when the chains are resolved. Nothing per connection is allocated.

**The Ctx grows by the trace state whether the App traces or not**: a tracer pointer and an `Active` of 80 bytes, on a struct that lives on the request's frame. **A `nilo_fetch` call's frame grows too**, by the `Outbound` it holds, the 55-byte `traceparent` buffer and two more header slots, 200 bytes or so on a frame of 6 KiB of buffers. Both are stack, which ADR 062 counts for the life of the connection. On `hello` the Ctx's growth crossed no page, which is what the memory row measures. The fetch frame's growth was not measured with `bench/mem.py` against `bench-fetch-server`, and it is the one figure here that is arithmetic rather than a run.

The memory and size figures are from a 2-core KVM guest (Intel Xeon Platinum 8255C), built at `5454e48` and with this change, same flags, same afternoon ([`bench/result/http.md`](../../bench/result/http.md#what-tracing-and-security-headers-cost-a-program-that-does-not-use-them)).

**What the exporter costs is bounded where it runs.** One `nilo_fetch` client with one connection in flight; a batch encoded into a scratch arena reset after every send; a receiver that is slow or down fills the rings, and new spans are dropped and counted, never waited for. One that cannot be reached is logged at `warn` at most once a minute.

## What was rejected

**`traceparent` as a header and nothing more**, ADR 158's position, which is where it said the trace id would go "the day nilo has a span". Forwarding a header without recording spans would carry a trace through nilo while showing nothing of nilo in it, which is what somebody turning tracing on is trying to see.

**`nilo_http` importing `nilo_fetch` from a file the server always reaches.** Simpler, and it would have put an HTTP client, its TLS and its certificate bundle in every program that serves anything. The split into `trace.zig`, which a request touches, and `otlp.zig`, which only `app.trace` reaches, costs one type-erased pointer and keeps the client out.

**A lock, or a channel, between the request and the exporter.** A shared queue is a lock every request on every thread takes once, which is contention that grows with the cores, on the path ADR 017 is strictest about. A ring per thread is never contended by another request, and the exporter is the only reader.

**Reading entropy for every id.** `getrandom` per request is a syscall on the request path. A generator per thread, seeded from the operating system once, is a few shifts. The ids are not secrets: the specification asks that they be random enough not to collide, which xoshiro256 is.

**OTLP as JSON.** Every receiver takes both, and protobuf is smaller on the wire and cheaper to write. Its encoder already exists as `nilo_proto` ([ADR 245](./245-protobuf-is-read-from-the-struct-that-declares-it.md)), so the trace messages are about a hundred lines of struct declarations, where JSON would have been another writer of its own.

**Span names and attributes at runtime.** A name that can carry an order number puts every span in a group of its own, the most common way a tracing bill gets out of hand, so a comptime name cannot. Attributes of a handler's own wait for an application that needs them, because a value has to be copied into a fixed record and the shape of that copy is a guess without one.

**On by default.** Tracing sends data to a receiver that has to exist, and a server that starts posting to `localhost:4318` because it was upgraded is a surprise. One line turns it on.

**Reading `OTEL_EXPORTER_OTLP_ENDPOINT` and the other environment variables.** A server that changes behaviour because of a variable it never mentions is the thing [ADR 039](./039-a-setting-is-a-field-and-every-bad-one-is-named-at-once.md) refuses for settings. `nilo_config` reads them into the fields in two lines, under names the application chooses.

**Metrics and logs as OTLP.** Metrics are a Prometheus page ([ADR 079](./079-the-route-table-is-the-registry.md)), and logs are lines a collector can read and join to the trace by `trace_id`. Each would be a second exporter with its own buffer, for a signal that already has a way out.
