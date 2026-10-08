//! Tracing: every request is a span, and the spans leave as OTLP
//! ([ADR 247](../docs/adr/247-a-request-is-a-span-and-the-trace-leaves-as-otlp.md)).
//!
//! ```zig
//! try app.trace(.{ .service = "orders" });                       // a collector on localhost:4318
//! try app.trace(.{
//!     .service = "orders",
//!     .endpoint = "https://api.honeycomb.io",
//!     .headers = &.{.{ .name = "x-honeycomb-team", .value = key }},
//! });
//!
//! fn charge(c: *nilo.Ctx, stripe: *Stripe) !Receipt {
//!     var span = c.span("charge card");      // a child of the request's span
//!     defer span.end();
//!     return stripe.postJson(c, "/v1/charges", …) catch |err| {   // a client span, and `traceparent`
//!         span.fail(err);
//!         return err;
//!     };
//! }
//! ```
//!
//! **A request is a server span without a line of code.** It is named for the
//! route (`GET /users/:id`), carries the attributes OpenTelemetry's HTTP
//! conventions call required (`http.request.method`, `http.route`,
//! `http.response.status_code`, `url.path`), and is an error when the status
//! is a 5xx. A request that arrives with a `traceparent` joins that trace;
//! one without starts a trace of its own. A call through `nilo_fetch` under
//! the request is a client span, and its `traceparent` names it, so the next
//! service's server span is its child. `c.span(name)` is everything else.
//!
//! **A span name is comptime.** OpenTelemetry asks for names of low
//! cardinality (`charge card`, never `charge card 4111…`), and a name that
//! has to be known while compiling cannot be anything else. The name of a
//! server span is the route pattern, which is the same property for the
//! same reason.
//!
//! **Recording a span is a copy into a ring, and nothing else.** Each
//! executor thread writes into a ring of its own, of `spans_per_thread`
//! records fixed when the server starts, so the request path takes no lock,
//! makes no allocation and does no IO. A ring that is full drops the span
//! and counts it; a slow collector costs spans, never requests. The ids come
//! from a generator per thread seeded once from the operating system, so a
//! request reads no entropy either.
//!
//! **This file is the half a request touches, and it names no network.**
//! Draining the rings, encoding OTLP with `nilo_proto` and posting it with
//! `nilo_fetch` is `otlp.zig`, which only `app.trace` reaches. A program
//! that never calls it links neither module, which is the property the
//! layering gave `nilo_fetch` in the first place (ADR 061).
//!
//! **What is left out, on purpose.** No metrics or logs signal: `app.metrics`
//! is the metrics answer and the logger is the logs one. No attribute API on
//! a span yet: a value would have to be copied into a fixed record, and the
//! shape of that copy waits for the first caller who needs it. Statement
//! spans from `nilo_sql` are not here either; `db.watching` is what reports a
//! slow statement today (ADR 108).

const std = @import("std");
const core = @import("nilo_core");
const bulkhead = @import("bulkhead.zig");

pub const Context = core.trace.Context;

/// What `app.trace` takes.
pub const Options = struct {
    /// `service.name`: what every span is filed under. Required.
    service: []const u8,
    /// Where the OTLP/HTTP receiver is: a collector, an agent or a vendor.
    /// `/v1/traces` is added, the way OpenTelemetry's own SDKs add it to
    /// `OTEL_EXPORTER_OTLP_ENDPOINT`.
    endpoint: []const u8 = "http://localhost:4318",
    /// Sent with every export: a vendor's key, mostly. At most sixteen.
    headers: []const std.http.Header = &.{},
    /// More attributes on the resource, beside `service.name`:
    /// `deployment.environment.name`, `service.version`.
    resource: []const Attribute = &.{},
    /// The fraction of traces that start here to record, from 0 to 1. A
    /// request that joined a trace follows the trace's own decision.
    sample: f64 = 1.0,
    /// Whether a request that arrives with a `traceparent` joins that trace.
    /// Off for a server on the open internet that does not want a client
    /// choosing its trace ids, or asking for every request to be recorded.
    join: bool = true,
    /// How often the exporter wakes to send what the rings hold.
    flush_ms: u32 = 1000,
    /// How many finished spans each thread holds before the next is dropped.
    /// Rounded up to a power of two. A record is `@sizeOf(Record)` bytes.
    spans_per_thread: u32 = 1024,
    /// The most spans one export carries.
    max_batch: u32 = 512,
    /// How long one export may take before it is given up.
    timeout_ms: u32 = 10_000,
};

pub const Attribute = struct {
    key: []const u8,
    value: []const u8,
};

pub const Kind = enum(u8) { internal = 1, server = 2, client = 3 };

/// How much of a path or a host a span keeps. A longer one is cut; the route
/// says what the path was for.
pub const text_cap = 96;

/// One finished span, as a ring holds it. Fixed in size, so recording one is
/// a copy, and everything it points at outlives the server: a route pattern,
/// a comptime name, a method's name, an error's name.
pub const Record = struct {
    trace_id: [16]u8,
    span_id: [8]u8,
    /// All zero for a span that starts its trace.
    parent: [8]u8,
    start_us: i64,
    end_us: i64,
    /// A server span's route, or a `c.span` name. Empty for a server span
    /// that matched no route, which is named for its method alone.
    name: []const u8,
    method: []const u8 = "",
    failure: []const u8 = "",
    kind: Kind,
    status: u16 = 0,
    port: u16 = 0,
    text_len: u8 = 0,
    /// `url.path` for a server span, `server.address` for a client one.
    text: [text_cap]u8 = undefined,

    fn keepText(self: *Record, text: []const u8) void {
        const n = @min(text.len, text_cap);
        @memcpy(self.text[0..n], text[0..n]);
        self.text_len = @intCast(n);
    }

    pub fn textOf(self: *const Record) []const u8 {
        return self.text[0..self.text_len];
    }
};

/// Where a request is in its trace, kept on the Ctx while it runs.
pub const Active = struct {
    /// The trace, the span being worked in now (the server span, or the
    /// innermost `c.span` still open) and whether the trace is recorded.
    context: Context,
    /// The server span's own id, and the span it was called from.
    server: [8]u8,
    parent: [8]u8,
    started_us: i64,
    started_mono_us: i64,
    /// The `tracestate` the request arrived with, forwarded on its calls.
    state: []const u8,
};

/// A bounded queue several threads may push into and one drains, after
/// Vyukov's: a sequence number on every cell says whose turn it is, so a push
/// is one compare-and-swap on the tail and a copy, with no lock. One per
/// executor thread, so the swap is nearly always uncontended; any number of
/// threads stay correct on one.
const Ring = struct {
    cells: []Cell,
    mask: usize,
    tail: std.atomic.Value(usize) align(std.atomic.cache_line) = .init(0),
    head: std.atomic.Value(usize) align(std.atomic.cache_line) = .init(0),

    const Cell = struct {
        seq: std.atomic.Value(usize),
        record: Record,
    };

    fn init(gpa: std.mem.Allocator, capacity: usize) !Ring {
        std.debug.assert(std.math.isPowerOfTwo(capacity));
        const cells = try gpa.alloc(Cell, capacity);
        for (cells, 0..) |*cell, i| cell.seq = .init(i);
        return .{ .cells = cells, .mask = capacity - 1 };
    }

    fn deinit(self: *Ring, gpa: std.mem.Allocator) void {
        gpa.free(self.cells);
    }

    /// False when the ring is full, and the record is not kept.
    fn push(self: *Ring, record: *const Record) bool {
        var pos = self.tail.load(.monotonic);
        while (true) {
            const cell = &self.cells[pos & self.mask];
            const seq = cell.seq.load(.acquire);
            const diff = @as(isize, @bitCast(seq)) -% @as(isize, @bitCast(pos));
            if (diff == 0) {
                if (self.tail.cmpxchgWeak(pos, pos + 1, .monotonic, .monotonic)) |actual| {
                    pos = actual;
                    continue;
                }
                cell.record = record.*;
                cell.seq.store(pos + 1, .release);
                return true;
            }
            if (diff < 0) return false;
            pos = self.tail.load(.monotonic);
        }
    }

    /// The oldest record, or false when there is none. Only the exporter
    /// drains, so the head is moved without a swap.
    fn pop(self: *Ring, out: *Record) bool {
        const pos = self.head.load(.monotonic);
        const cell = &self.cells[pos & self.mask];
        const seq = cell.seq.load(.acquire);
        if (seq != pos + 1) return false;
        out.* = cell.record;
        cell.seq.store(pos + self.mask + 1, .release);
        self.head.store(pos + 1, .monotonic);
        return true;
    }
};

/// Which ring this thread writes into, picked the first time it records.
threadlocal var ring_slot: ?usize = null;
var next_slot: std.atomic.Value(usize) = .init(0);

/// The id generator, one per thread, seeded from the operating system the
/// first time it is asked. Ids have to be unpredictable enough not to
/// collide, which this is; they are not secrets.
threadlocal var ids: ?std.Random.DefaultPrng = null;

fn randomInto(out: []u8) void {
    if (ids == null) {
        var seed: [8]u8 = undefined;
        bulkhead.randomSecure(&seed) catch {
            // Nothing to read the entropy from: the monotonic clock and the
            // thread's own stack address differ on every thread and every
            // start, which is what an id needs.
            const mixed = @as(u64, @bitCast(core.monotonicMicros())) ^ @intFromPtr(&seed);
            seed = @bitCast(mixed);
        };
        ids = .init(@bitCast(seed));
    }
    ids.?.random().bytes(out);
    // An id of all zero means "none" on the wire.
    if (std.mem.allEqual(u8, out, 0)) out[out.len - 1] = 1;
}

/// The highest trace id, read as a number from its last eight bytes, that a
/// ratio keeps: OpenTelemetry's `TraceIdRatioBased`.
fn boundFor(ratio: f64) u64 {
    if (ratio >= 1.0) return std.math.maxInt(u64);
    if (ratio <= 0.0) return 0;
    // 2^64 exactly, which an `f64` holds and `maxInt(u64)` as an `f64`
    // rounds up to; a ratio a hair under one lands on it, and is all of them.
    const scaled = ratio * 18446744073709551616.0;
    if (scaled >= 18446744073709551616.0) return std.math.maxInt(u64);
    return @intFromFloat(scaled);
}

fn keptByRatio(trace_id: *const [16]u8, bound: u64) bool {
    if (bound == std.math.maxInt(u64)) return true;
    return std.mem.readInt(u64, trace_id[8..16], .big) < bound;
}

/// The rings and the rules: what a request records into, and what the
/// exporter drains.
pub const Tracer = struct {
    gpa: std.mem.Allocator,
    options: Options,
    bound: u64,
    rings: []Ring = &.{},
    /// Spans a full ring had no room for, and spans an export that failed
    /// took with it.
    dropped: std.atomic.Value(u64) = .init(0),
    /// `beginCall` and `endCall`, behind pointers so that `Ctx.traceBegin`
    /// and `Ctx.traceEnd`, which `nilo_fetch` reaches on every call, link the
    /// ids and the URL parse only into a program that calls `init`, which
    /// only `app.trace` does (ADR 247).
    begin_call: *const fn (*const Active) core.trace.Outbound,
    end_call: *const fn (*Tracer, core.trace.Outbound, core.trace.Ended) void,
    /// `writeId`, for the logger, behind a pointer for the same reason.
    write_id: *const fn (*const Active, *std.Io.Writer, []const u8, []const u8) std.Io.Writer.Error!void,

    pub const Error = error{ TraceServiceEmpty, TraceEndpointNotHttp, TraceSampleOutOfRange, TraceBatchEmpty };

    pub fn init(gpa: std.mem.Allocator, options: Options) Error!Tracer {
        if (options.service.len == 0) return error.TraceServiceEmpty;
        if (!std.mem.startsWith(u8, options.endpoint, "http://") and
            !std.mem.startsWith(u8, options.endpoint, "https://")) return error.TraceEndpointNotHttp;
        if (!(options.sample >= 0.0 and options.sample <= 1.0)) return error.TraceSampleOutOfRange;
        if (options.max_batch == 0 or options.spans_per_thread == 0) return error.TraceBatchEmpty;
        return .{
            .gpa = gpa,
            .options = options,
            .bound = boundFor(options.sample),
            .begin_call = beginCall,
            .end_call = endCall,
            .write_id = writeId,
        };
    }

    pub fn deinit(self: *Tracer) void {
        for (self.rings) |*r| r.deinit(self.gpa);
        self.gpa.free(self.rings);
    }

    /// The rings, one per executor thread, sized once the thread count is
    /// known. Kept when they are already that many, because the test client
    /// resolves the chains before every request.
    pub fn size(self: *Tracer, threads: usize) !void {
        if (self.rings.len == threads) return;
        for (self.rings) |*r| r.deinit(self.gpa);
        self.gpa.free(self.rings);
        self.rings = &.{};
        const capacity = std.math.ceilPowerOfTwo(usize, self.options.spans_per_thread) catch
            return error.OutOfMemory;
        const rings = try self.gpa.alloc(Ring, threads);
        var made: usize = 0;
        errdefer {
            for (rings[0..made]) |*r| r.deinit(self.gpa);
            self.gpa.free(rings);
        }
        for (rings) |*r| {
            r.* = try Ring.init(self.gpa, capacity);
            made += 1;
        }
        self.rings = rings;
    }

    /// Where a request starts in its trace: joining the one its
    /// `traceparent` names, or starting one.
    pub fn begin(self: *const Tracer, traceparent: ?[]const u8, tracestate: ?[]const u8) Active {
        var active: Active = .{
            .context = undefined,
            .server = undefined,
            .parent = @splat(0),
            .started_us = core.nowMicros(),
            .started_mono_us = core.monotonicMicros(),
            .state = "",
        };
        const joined = if (self.options.join) if (traceparent) |text| Context.parse(text) else null else null;
        if (joined) |incoming| {
            active.context = incoming;
            active.parent = incoming.span_id;
            active.state = tracestate orelse "";
        } else {
            randomInto(&active.context.trace_id);
            active.context.sampled = keptByRatio(&active.context.trace_id, self.bound);
        }
        randomInto(&active.server);
        active.context.span_id = active.server;
        return active;
    }

    /// The request's own span, once its status is settled.
    pub fn finish(self: *Tracer, active: *const Active, method: []const u8, route: []const u8, path: []const u8, status: u16) void {
        if (!active.context.sampled) return;
        var record: Record = .{
            .trace_id = active.context.trace_id,
            .span_id = active.server,
            .parent = active.parent,
            .start_us = active.started_us,
            .end_us = active.started_us + (core.monotonicMicros() - active.started_mono_us),
            .name = route,
            .method = method,
            .kind = .server,
            .status = status,
        };
        record.keepText(path);
        self.keep(&record);
    }

    /// A call about to leave under the request: a span id of its own, which
    /// is what its `traceparent` names.
    pub fn beginCall(active: *const Active) core.trace.Outbound {
        var id: [8]u8 = undefined;
        randomInto(&id);
        return .{
            .context = .{ .trace_id = active.context.trace_id, .span_id = id, .sampled = active.context.sampled },
            .parent = active.context.span_id,
            .started_us = core.nowMicros(),
            .started_mono_us = core.monotonicMicros(),
            .state = active.state,
        };
    }

    /// The trace id as 32 hex characters, between `before` and `after`: a
    /// log line's ` trace=…` or `"trace_id":"…"`.
    pub fn writeId(active: *const Active, w: *std.Io.Writer, before: []const u8, after: []const u8) std.Io.Writer.Error!void {
        var hex: [32]u8 = undefined;
        core.trace.writeHex(&active.context.trace_id, &hex);
        try w.writeAll(before);
        try w.writeAll(&hex);
        try w.writeAll(after);
    }

    pub fn endCall(self: *Tracer, begun: core.trace.Outbound, ended: core.trace.Ended) void {
        if (!begun.context.sampled) return;
        var record: Record = .{
            .trace_id = begun.context.trace_id,
            .span_id = begun.context.span_id,
            .parent = begun.parent,
            .start_us = begun.started_us,
            .end_us = begun.started_us + (core.monotonicMicros() - begun.started_mono_us),
            .name = ended.method,
            .method = ended.method,
            .failure = ended.failure orelse "",
            .kind = .client,
            .status = ended.status,
        };
        // `server.address` and `server.port`, read off the URL here rather
        // than by `nilo_fetch`, so a program that calls out and does not
        // trace parses nothing for it.
        if (std.Uri.parse(ended.url)) |uri| {
            if (uri.host) |h| record.keepText(switch (h) {
                .raw => |raw| raw,
                .percent_encoded => |enc| enc,
            });
            record.port = uri.port orelse if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) 443 else 80;
        } else |_| {}
        self.keep(&record);
    }

    fn keep(self: *Tracer, record: *const Record) void {
        if (self.rings.len == 0) {
            _ = self.dropped.fetchAdd(1, .monotonic);
            return;
        }
        const slot = ring_slot orelse pick: {
            const s = next_slot.fetchAdd(1, .monotonic);
            ring_slot = s;
            break :pick s;
        };
        if (!self.rings[slot % self.rings.len].push(record)) {
            _ = self.dropped.fetchAdd(1, .monotonic);
        }
    }

    /// Up to `into.len` records out of the rings. Round-robin, so one busy
    /// thread cannot keep another's spans waiting behind its own for a whole
    /// batch.
    pub fn drain(self: *Tracer, into: []Record) usize {
        var n: usize = 0;
        var any = true;
        while (any and n < into.len) {
            any = false;
            for (self.rings) |*r| {
                if (n == into.len) break;
                if (r.pop(&into[n])) {
                    n += 1;
                    any = true;
                }
            }
        }
        return n;
    }
};

/// A child span, opened with `c.span(name)`.
pub const Span = struct {
    tracer: ?*Tracer,
    active: *Active,
    id: [8]u8,
    parent: [8]u8,
    name: []const u8,
    started_us: i64,
    started_mono_us: i64,
    failure: []const u8 = "",

    /// A span that records nothing: tracing is off, or the trace is not
    /// recorded.
    pub fn none(active: *Active) Span {
        return .{
            .tracer = null,
            .active = active,
            .id = undefined,
            .parent = undefined,
            .name = "",
            .started_us = 0,
            .started_mono_us = 0,
        };
    }

    pub fn open(tracer: *Tracer, active: *Active, comptime name: []const u8) Span {
        var span: Span = .{
            .tracer = tracer,
            .active = active,
            .id = undefined,
            .parent = active.context.span_id,
            .name = name,
            .started_us = core.nowMicros(),
            .started_mono_us = core.monotonicMicros(),
        };
        randomInto(&span.id);
        // What opens next, and what leaves through `nilo_fetch`, is this
        // span's child until it ends.
        active.context.span_id = span.id;
        return span;
    }

    /// Mark the span failed, naming the error: `call() catch |err| { span.fail(err); return err; }`.
    pub fn fail(self: *Span, err: anyerror) void {
        self.failure = @errorName(err);
    }

    /// Record the span, and make its parent the current span again. Takes
    /// the span by pointer so that `var span = c.span(…)` is always the
    /// spelling, with `fail` or without.
    pub fn end(self: *Span) void {
        const tracer = self.tracer orelse return;
        self.active.context.span_id = self.parent;
        const record: Record = .{
            .trace_id = self.active.context.trace_id,
            .span_id = self.id,
            .parent = self.parent,
            .start_us = self.started_us,
            .end_us = self.started_us + (core.monotonicMicros() - self.started_mono_us),
            .name = self.name,
            .failure = self.failure,
            .kind = .internal,
        };
        tracer.keep(&record);
    }
};

const testing = std.testing;

fn testTracer(options: Options) !Tracer {
    var t = try Tracer.init(testing.allocator, options);
    errdefer t.deinit();
    try t.size(2);
    return t;
}

test "a request with no traceparent starts a trace, and its span names its route" {
    var t = try testTracer(.{ .service = "orders" });
    defer t.deinit();

    const active = t.begin(null, null);
    try testing.expect(active.context.sampled);
    try testing.expect(std.mem.allEqual(u8, &active.parent, 0));
    try testing.expectEqualSlices(u8, &active.server, &active.context.span_id);
    t.finish(&active, "GET", "/users/:id", "/users/7", 200);

    var out: [4]Record = undefined;
    try testing.expectEqual(@as(usize, 1), t.drain(&out));
    try testing.expectEqualStrings("/users/:id", out[0].name);
    try testing.expectEqualStrings("/users/7", out[0].textOf());
    try testing.expectEqual(Kind.server, out[0].kind);
    try testing.expect(out[0].end_us >= out[0].start_us);
}

test "a request that arrives with a traceparent joins that trace as the caller's child" {
    var t = try testTracer(.{ .service = "orders" });
    defer t.deinit();

    const active = t.begin("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01", "vendor=x");
    const caller = Context.parse("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01").?;
    try testing.expectEqualSlices(u8, &caller.trace_id, &active.context.trace_id);
    try testing.expectEqualSlices(u8, &caller.span_id, &active.parent);
    try testing.expect(!std.mem.eql(u8, &caller.span_id, &active.server));
    try testing.expectEqualStrings("vendor=x", active.state);

    // Unless the server was told not to join.
    var closed = try testTracer(.{ .service = "orders", .join = false });
    defer closed.deinit();
    const own = closed.begin("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01", null);
    try testing.expect(!std.mem.eql(u8, &caller.trace_id, &own.context.trace_id));
    try testing.expect(std.mem.allEqual(u8, &own.parent, 0));
}

test "a caller that said not to record is followed, and nothing is kept" {
    var t = try testTracer(.{ .service = "orders" });
    defer t.deinit();
    const active = t.begin("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-00", null);
    try testing.expect(!active.context.sampled);
    t.finish(&active, "GET", "/x", "/x", 200);
    var out: [1]Record = undefined;
    try testing.expectEqual(@as(usize, 0), t.drain(&out));
}

test "a ratio keeps that fraction of the traces that start here, read off the trace id" {
    var none = try testTracer(.{ .service = "orders", .sample = 0 });
    defer none.deinit();
    var all = try testTracer(.{ .service = "orders", .sample = 1 });
    defer all.deinit();
    for (0..64) |_| {
        try testing.expect(!none.begin(null, null).context.sampled);
        try testing.expect(all.begin(null, null).context.sampled);
    }
    // Off the id rather than a coin, so every service in a trace that samples
    // by the same ratio comes to the same answer.
    var half = try testTracer(.{ .service = "orders", .sample = 0.5 });
    defer half.deinit();
    var kept: usize = 0;
    for (0..2000) |_| {
        if (half.begin(null, null).context.sampled) kept += 1;
    }
    try testing.expect(kept > 800 and kept < 1200);
    try testing.expectEqual(@as(u64, 1) << 63, boundFor(0.5));
}

test "a child span is the current span until it ends, and a call under it is its child" {
    var t = try testTracer(.{ .service = "orders" });
    defer t.deinit();
    var active = t.begin(null, null);

    var span = Span.open(&t, &active, "charge card");
    try testing.expectEqualSlices(u8, &span.id, &active.context.span_id);
    const call = Tracer.beginCall(&active);
    try testing.expectEqualSlices(u8, &span.id, &call.parent);
    t.endCall(call, .{ .method = "POST", .url = "https://api.stripe.com/v1/charges", .status = 402 });
    span.fail(error.CardDeclined);
    span.end();
    try testing.expectEqualSlices(u8, &active.server, &active.context.span_id);

    var out: [4]Record = undefined;
    try testing.expectEqual(@as(usize, 2), t.drain(&out));
    try testing.expectEqual(Kind.client, out[0].kind);
    try testing.expectEqualStrings("api.stripe.com", out[0].textOf());
    try testing.expectEqual(@as(u16, 443), out[0].port);
    try testing.expectEqual(Kind.internal, out[1].kind);
    try testing.expectEqualStrings("CardDeclined", out[1].failure);
    try testing.expectEqualSlices(u8, &active.server, &out[1].parent);
}

test "a full ring drops the span and counts it, and draining makes room again" {
    var t = try Tracer.init(testing.allocator, .{ .service = "orders", .spans_per_thread = 4 });
    defer t.deinit();
    try t.size(1);
    const active = t.begin(null, null);
    for (0..6) |_| t.finish(&active, "GET", "/x", "/x", 200);
    try testing.expectEqual(@as(u64, 2), t.dropped.load(.monotonic));

    var out: [8]Record = undefined;
    try testing.expectEqual(@as(usize, 4), t.drain(&out));
    // Round the ring more than once, which is where a sequence number that
    // was moved wrong shows.
    for (0..3) |_| {
        for (0..4) |_| t.finish(&active, "GET", "/x", "/x", 200);
        try testing.expectEqual(@as(usize, 4), t.drain(&out));
    }
    try testing.expectEqual(@as(u64, 2), t.dropped.load(.monotonic));
}

test "a long path is cut to what a record holds" {
    var t = try testTracer(.{ .service = "orders" });
    defer t.deinit();
    const active = t.begin(null, null);
    t.finish(&active, "GET", "/files/*", "/files/" ++ &@as([200]u8, @splat('a')), 200);
    var out: [1]Record = undefined;
    _ = t.drain(&out);
    try testing.expectEqual(@as(usize, text_cap), out[0].textOf().len);
}

test "options that could send nothing are refused at the start" {
    try testing.expectError(error.TraceServiceEmpty, Tracer.init(testing.allocator, .{ .service = "" }));
    try testing.expectError(error.TraceEndpointNotHttp, Tracer.init(testing.allocator, .{ .service = "x", .endpoint = "localhost:4318" }));
    try testing.expectError(error.TraceSampleOutOfRange, Tracer.init(testing.allocator, .{ .service = "x", .sample = 1.5 }));
}
