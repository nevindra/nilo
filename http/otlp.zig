//! The half of tracing that leaves the process: drain the rings, encode an
//! OTLP `ExportTraceServiceRequest`, post it
//! ([ADR 247](../docs/adr/247-a-request-is-a-span-and-the-trace-leaves-as-otlp.md)).
//!
//! **The only file in `nilo_http` that names `nilo_fetch` or `nilo_proto`,
//! and only `app.trace` reaches it.** The request path is `trace.zig`, which
//! names neither, so a program that never traces links no HTTP client and
//! no protobuf encoder, the property ADR 061 gave `nilo_fetch` and ADR 245
//! gave `nilo_proto`.
//!
//! **A fiber of the server's, waking every `flush_ms`.** It drains the rings
//! into a batch of at most `max_batch`, encodes it with `nilo_proto` into an
//! arena it resets after each post, and posts it with `nilo_fetch` to
//! `endpoint/v1/traces` as `application/x-protobuf`, the OTLP/HTTP binding
//! every collector and vendor reads. The batch, the arena and the client are
//! the exporter's, kept from one flush to the next, so a steady stream of
//! spans allocates nothing once the arena has grown to a batch's size.
//!
//! **A receiver that is down costs spans, never requests.** A post that
//! fails drops its batch and counts it in `Tracer.dropped`, and says so in
//! the log once a minute at most. Nothing is retried: a batch kept for a
//! retry is memory the rings would otherwise be using, and the next flush
//! has fresher spans to send.
//!
//! **What is still in the rings when the server stops goes out from
//! `nilo_stop`**, which runs on the way out of `listen()` once the requests
//! have drained.

const std = @import("std");
const core = @import("nilo_core");
const proto = @import("nilo_proto");
const fetch = @import("nilo_fetch");
const bulkhead = @import("bulkhead.zig");
const trace = @import("trace.zig");

const Record = trace.Record;

/// What `telemetry.sdk.version` says.
const sdk_version = "0.1";

/// The most headers `Options.headers` may hold, beside the content type.
pub const max_headers = 16;

pub const Exporter = struct {
    tracer: *trace.Tracer,
    gpa: std.mem.Allocator,
    url: []u8,
    client: fetch.Client,
    run: ?core.Run = null,
    batch: []Record,
    scratch: std.heap.ArenaAllocator,
    last_warned_us: i64 = 0,
    sending: std.atomic.Value(bool) = .init(false),
    exported: std.atomic.Value(u64) = .init(0),

    pub fn init(gpa: std.mem.Allocator, tracer: *trace.Tracer) !Exporter {
        const options = tracer.options;
        if (options.headers.len > max_headers) return error.TraceTooManyHeaders;
        const base = std.mem.trimEnd(u8, options.endpoint, "/");
        const url = try std.fmt.allocPrint(gpa, "{s}/v1/traces", .{base});
        errdefer gpa.free(url);
        const batch = try gpa.alloc(Record, options.max_batch);
        return .{
            .tracer = tracer,
            .gpa = gpa,
            .url = url,
            .client = .init(gpa, .{ .max_in_flight = 1, .timeout_ms = options.timeout_ms, .forward_request_id = false }),
            .batch = batch,
            .scratch = .init(gpa),
        };
    }

    pub fn deinit(self: *Exporter) void {
        self.gpa.free(self.batch);
        self.gpa.free(self.url);
        if (self.run) |*run| run.deinit();
        self.scratch.deinit();
        self.client.deinit();
    }

    /// The service hook: the client and its Scope, on the loop the requests
    /// run on.
    pub fn nilo_start(self: *Exporter, io: std.Io, limits: core.Limits) !void {
        try self.client.nilo_start(io, limits);
        self.run = .initIo(self.gpa, io);
    }

    /// What is still in the rings goes out before the process does.
    pub fn nilo_stop(self: *Exporter) void {
        _ = self.flush();
    }

    /// The fiber: wake, send, sleep, until the server cancels it.
    pub fn exportEvery(self: *Exporter) void {
        while (true) {
            bulkhead.sleep(self.tracer.options.flush_ms) catch return;
            _ = self.flush();
        }
    }

    /// Send everything the rings hold, a batch at a time, and say how many
    /// spans went. One sender at a time: the fiber and `nilo_stop` may both
    /// get here.
    pub fn flush(self: *Exporter) usize {
        if (self.sending.swap(true, .acquire)) return 0;
        defer self.sending.store(false, .release);
        var sent: usize = 0;
        while (true) {
            const n = self.tracer.drain(self.batch);
            if (n == 0) break;
            if (self.send(self.batch[0..n])) {
                sent += n;
                _ = self.exported.fetchAdd(n, .monotonic);
            } else {
                _ = self.tracer.dropped.fetchAdd(n, .monotonic);
            }
            if (n < self.batch.len) break;
        }
        return sent;
    }

    fn send(self: *Exporter, batch: []const Record) bool {
        const run = if (self.run) |*r| r else return false;
        defer {
            _ = self.scratch.reset(.{ .retain_with_limit = 1 << 20 });
            run.reset();
        }
        const body = encode(self.scratch.allocator(), self.tracer.options, batch) catch return false;

        var headers: [max_headers + 1]std.http.Header = undefined;
        headers[0] = .{ .name = "content-type", .value = "application/x-protobuf" };
        const given = self.tracer.options.headers;
        @memcpy(headers[1..][0..given.len], given);

        const res = self.client.post(run, self.url, body, .{ .headers = headers[0 .. 1 + given.len] }) catch |err| {
            self.warn("the trace receiver at {s} could not be reached ({t}); {d} span(s) dropped", .{ self.url, err, batch.len });
            return false;
        };
        if (!res.ok()) {
            self.warn("the trace receiver at {s} answered {d}; {d} span(s) dropped", .{ self.url, @backingInt(res.status), batch.len });
            return false;
        }
        return true;
    }

    /// Once a minute at most: a receiver that is down is down for every
    /// flush, and a line a second about it is noise.
    fn warn(self: *Exporter, comptime fmt: []const u8, args: anytype) void {
        const now = core.nowMicros();
        if (self.last_warned_us != 0 and now - self.last_warned_us < 60 * std.time.us_per_s) return;
        self.last_warned_us = now;
        std.log.warn("nilo: " ++ fmt, args);
    }
};

/// A batch as an OTLP `ExportTraceServiceRequest`, in `arena`.
pub fn encode(arena: std.mem.Allocator, options: trace.Options, batch: []const Record) ![]u8 {
    var resource = try arena.alloc(KeyValue, 4 + options.resource.len);
    resource[0] = .string("service.name", options.service);
    resource[1] = .string("telemetry.sdk.name", "nilo");
    resource[2] = .string("telemetry.sdk.language", "zig");
    resource[3] = .string("telemetry.sdk.version", sdk_version);
    for (options.resource, 0..) |a, i| resource[4 + i] = .string(a.key, a.value);

    const spans = try arena.alloc(Span, batch.len);
    for (batch, spans) |*r, *s| s.* = try spanOf(arena, r);

    const request: ExportTraceServiceRequest = .{
        .resource_spans = &.{.{
            .resource = .{ .attributes = resource },
            .scope_spans = &.{.{
                .scope = .{ .name = "nilo", .version = sdk_version },
                .spans = spans,
            }},
        }},
    };
    return proto.encode(ExportTraceServiceRequest, arena, request);
}

fn spanOf(arena: std.mem.Allocator, r: *const Record) !Span {
    var attrs: std.ArrayList(KeyValue) = .empty;
    try attrs.ensureTotalCapacity(arena, 6);
    var name: []const u8 = r.name;
    var failed = false;
    var message: []const u8 = "";

    switch (r.kind) {
        .server => {
            name = if (r.name.len > 0) try std.fmt.allocPrint(arena, "{s} {s}", .{ r.method, r.name }) else r.method;
            attrs.appendAssumeCapacity(.string("http.request.method", r.method));
            if (r.name.len > 0) attrs.appendAssumeCapacity(.string("http.route", r.name));
            attrs.appendAssumeCapacity(.int("http.response.status_code", r.status));
            attrs.appendAssumeCapacity(.string("url.path", r.textOf()));
            // A 4xx is the client's mistake and the server did its job; a
            // 5xx is the server's (OpenTelemetry's HTTP conventions).
            if (r.status >= 500) {
                failed = true;
                attrs.appendAssumeCapacity(.string("error.type", try std.fmt.allocPrint(arena, "{d}", .{r.status})));
            }
        },
        .client => {
            attrs.appendAssumeCapacity(.string("http.request.method", r.method));
            attrs.appendAssumeCapacity(.string("server.address", r.textOf()));
            if (r.port != 0) attrs.appendAssumeCapacity(.int("server.port", r.port));
            if (r.status != 0) attrs.appendAssumeCapacity(.int("http.response.status_code", r.status));
            // For a call, a 4xx is a failure too: it was this side's call.
            if (r.failure.len > 0) {
                failed = true;
                message = r.failure;
                attrs.appendAssumeCapacity(.string("error.type", r.failure));
            } else if (r.status >= 400) {
                failed = true;
                attrs.appendAssumeCapacity(.string("error.type", try std.fmt.allocPrint(arena, "{d}", .{r.status})));
            }
        },
        .internal => if (r.failure.len > 0) {
            failed = true;
            message = r.failure;
            attrs.appendAssumeCapacity(.string("error.type", r.failure));
        },
    }

    const root = std.mem.allEqual(u8, &r.parent, 0);
    return .{
        .trace_id = try arena.dupe(u8, &r.trace_id),
        .span_id = try arena.dupe(u8, &r.span_id),
        .parent_span_id = if (root) "" else try arena.dupe(u8, &r.parent),
        .name = name,
        .kind = @fromBackingInt(@intCast(@backingInt(r.kind))),
        .start_time_unix_nano = @as(u64, @intCast(@max(r.start_us, 0))) * std.time.ns_per_us,
        .end_time_unix_nano = @as(u64, @intCast(@max(r.end_us, 0))) * std.time.ns_per_us,
        .attributes = attrs.items,
        .status = if (failed) .{ .message = message, .code = .@"error" } else null,
    };
}

// The part of OpenTelemetry's protocol a trace export uses, as `nilo_proto`
// structs: `collector/trace/v1/trace_service.proto`, `trace/v1/trace.proto`,
// `common/v1/common.proto` and `resource/v1/resource.proto`, the fields nilo
// writes and no others. A receiver skips nothing it needs, since every field
// left out is one OTLP lets a sender leave out.

pub const ExportTraceServiceRequest = struct {
    pub const wire = .{ .resource_spans = 1 };
    resource_spans: []const ResourceSpans = &.{},
};

pub const ResourceSpans = struct {
    pub const wire = .{ .resource = 1, .scope_spans = 2 };
    resource: Resource = .{},
    scope_spans: []const ScopeSpans = &.{},
};

pub const Resource = struct {
    pub const wire = .{ .attributes = 1 };
    attributes: []const KeyValue = &.{},
};

pub const ScopeSpans = struct {
    pub const wire = .{ .scope = 1, .spans = 2 };
    scope: InstrumentationScope = .{},
    spans: []const Span = &.{},
};

pub const InstrumentationScope = struct {
    pub const wire = .{ .name = 1, .version = 2 };
    name: []const u8 = "",
    version: []const u8 = "",
};

pub const SpanKind = enum(i32) { unspecified = 0, internal = 1, server = 2, client = 3, producer = 4, consumer = 5, _ };

pub const Span = struct {
    pub const wire = .{
        .trace_id = .{ 1, .bytes },
        .span_id = .{ 2, .bytes },
        .parent_span_id = .{ 4, .bytes },
        .name = 5,
        .kind = 6,
        .start_time_unix_nano = .{ 7, .fixed64 },
        .end_time_unix_nano = .{ 8, .fixed64 },
        .attributes = 9,
        .status = 15,
    };
    trace_id: []const u8 = "",
    span_id: []const u8 = "",
    parent_span_id: []const u8 = "",
    name: []const u8 = "",
    kind: SpanKind = .unspecified,
    start_time_unix_nano: u64 = 0,
    end_time_unix_nano: u64 = 0,
    attributes: []const KeyValue = &.{},
    status: ?Status = null,
};

pub const StatusCode = enum(i32) { unset = 0, ok = 1, @"error" = 2, _ };

pub const Status = struct {
    pub const wire = .{ .message = 2, .code = 3 };
    message: []const u8 = "",
    code: StatusCode = .unset,
};

pub const KeyValue = struct {
    pub const wire = .{ .key = 1, .value = 2 };
    key: []const u8 = "",
    value: AnyValue = .{},

    pub fn string(key: []const u8, text: []const u8) KeyValue {
        return .{ .key = key, .value = .{ .value = .{ .string_value = text } } };
    }

    pub fn int(key: []const u8, n: i64) KeyValue {
        return .{ .key = key, .value = .{ .value = .{ .int_value = n } } };
    }
};

pub const AnyValue = struct {
    pub const wire = .{};
    value: ?union(enum) {
        pub const wire = .{ .string_value = 1, .bool_value = 2, .int_value = 3, .double_value = 4 };
        string_value: []const u8,
        bool_value: bool,
        int_value: i64,
        double_value: f64,
    } = null,
};

const testing = std.testing;

test "a batch encodes as the OTLP request a collector reads" {
    var tracer = try trace.Tracer.init(testing.allocator, .{
        .service = "orders",
        .resource = &.{.{ .key = "deployment.environment.name", .value = "test" }},
    });
    defer tracer.deinit();
    try tracer.size(1);

    var active = tracer.begin("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01", null);
    const call = trace.Tracer.beginCall(&active);
    tracer.endCall(call, .{ .method = "GET", .url = "https://api.example.com/v1/users", .status = 0, .failure = "ConnectionRefused" });
    tracer.finish(&active, "GET", "/users/:id", "/users/7", 503);

    var out: [2]Record = undefined;
    try testing.expectEqual(@as(usize, 2), tracer.drain(&out));
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const bytes = try encode(arena.allocator(), tracer.options, &out);

    const back = try proto.decode(ExportTraceServiceRequest, arena.allocator(), bytes);
    const rs = back.resource_spans[0];
    try testing.expectEqualStrings("service.name", rs.resource.attributes[0].key);
    try testing.expectEqualStrings("orders", rs.resource.attributes[0].value.value.?.string_value);
    try testing.expectEqualStrings("test", rs.resource.attributes[4].value.value.?.string_value);

    const client = rs.scope_spans[0].spans[0];
    try testing.expectEqualStrings("GET", client.name);
    try testing.expectEqual(SpanKind.client, client.kind);
    try testing.expectEqualStrings("ConnectionRefused", client.status.?.message);

    const server = rs.scope_spans[0].spans[1];
    try testing.expectEqualStrings("GET /users/:id", server.name);
    try testing.expectEqual(SpanKind.server, server.kind);
    try testing.expectEqual(@as(usize, 16), server.trace_id.len);
    try testing.expectEqualSlices(u8, &active.parent, server.parent_span_id);
    try testing.expectEqualSlices(u8, server.span_id, client.parent_span_id);
    try testing.expectEqual(StatusCode.@"error", server.status.?.code);
    try testing.expect(server.end_time_unix_nano >= server.start_time_unix_nano);
    var saw_status = false;
    for (server.attributes) |a| {
        if (std.mem.eql(u8, a.key, "http.response.status_code")) {
            try testing.expectEqual(@as(i64, 503), a.value.value.?.int_value);
            saw_status = true;
        }
    }
    try testing.expect(saw_status);
}

test "a span that starts its trace is sent with no parent, and a 4xx is not a server's failure" {
    var tracer = try trace.Tracer.init(testing.allocator, .{ .service = "orders" });
    defer tracer.deinit();
    try tracer.size(1);
    const active = tracer.begin(null, null);
    tracer.finish(&active, "POST", "", "/nowhere", 404);

    var out: [1]Record = undefined;
    _ = tracer.drain(&out);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const back = try proto.decode(ExportTraceServiceRequest, arena.allocator(), try encode(arena.allocator(), tracer.options, &out));
    const span = back.resource_spans[0].scope_spans[0].spans[0];
    try testing.expectEqual(@as(usize, 0), span.parent_span_id.len);
    try testing.expectEqualStrings("POST", span.name);
    try testing.expect(span.status == null);
}
