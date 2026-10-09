//! The logger middleware — one line per request, with the status and how
//! long it took.
//!
//! ```zig
//! try app.use(logger.standard);
//! try app.use(logger.with(.{ .level = .debug, .slow_micros = 50_000 }));
//! try app.use(logger.with(.{ .request_id = true, .skip = &.{"/healthz"} }));
//! ```
//!
//! What the line says is configured at compile time, so an option nobody
//! switched on costs nothing at run time. **How it is written is not the
//! middleware's to say**: text or JSON, and the lowest level written, are
//! `listen(.{ .log = … })`, because they are facts about the deployment and
//! every other line the process writes follows them too
//! ([ADR 262](../docs/adr/262-a-log-line-has-one-sink.md)).

const std = @import("std");
const builtin = @import("builtin");
const Ctx = @import("ctx.zig").Ctx;
const mw = @import("middleware.zig");
const fail = @import("fail.zig");
const bulkhead = @import("bulkhead.zig");
const json_mod = @import("json.zig");
const log_mod = @import("log.zig");

/// How much of a line is written before it is handed to `std.log`. A path is
/// the long part and a request head bounds it; past this the line is cut
/// rather than dropped, on the same reasoning a failure message is
/// ([ADR 004](../docs/adr/004-http-errors-via-fail-functions.md)).
const max_line = 1024;

/// `text` is `GET /users/7 200 59µs`, what a person reads in a terminal;
/// `json` is one object per line, for whatever collects them. Chosen by
/// `listen(.{ .log = .{ .format = … } })`, not by the middleware.
pub const Format = log_mod.Format;

pub const Options = struct {
    /// The level ordinary requests are logged at. Which level a line *is* is
    /// a fact about the code, like `slow_micros`; whether that level is
    /// written at all is `listen(.{ .log = .{ .level = … } })`.
    level: std.log.Level = .info,
    /// Paths that are never logged, compared exactly with the request's
    /// path: a health check a load balancer calls every second is not worth
    /// a line each. Empty costs nothing, and the compare is unrolled over
    /// the literals when it is not. The request is still answered, its
    /// `X-Request-Id` still set, and an error is still passed along.
    skip: []const []const u8 = &.{},
    /// Requests taking longer than this are logged at `.warn` instead, so
    /// they stand out without needing a second tool. 0 turns that off.
    slow_micros: u64 = 0,
    /// Give every request an id: `X-Request-Id` on the way out, and the same
    /// id on its log line.
    ///
    /// The one thing a proxy in front cannot reconstruct afterwards is which
    /// log lines belong to the request that timed out
    /// ([ADR 027](../docs/adr/027-tls-is-terminated-in-front.md)). Off by
    /// default because it costs a header on every response; `c.requestId()`
    /// works either way.
    request_id: bool = false,
};

/// The default: one `info` line per request.
pub const standard = with(.{});

pub fn with(comptime options: Options) mw.Middleware {
    return struct {
        fn run(c: *Ctx, next: mw.Next) anyerror!void {
            if (options.request_id) {
                // Set before the handler runs, not after: a response is
                // flushed the moment it is sent, so a header put on
                // afterwards would never leave the building (ADR 008).
                //
                // Static rather than copied — the id is either the Ctx's own
                // buffer or a slice of the request head, and both outlive the
                // response. A failure here is not worth ending a request over:
                // the header is a convenience, and the log line still carries
                // the id.
                c.setStaticHeader("X-Request-Id", c.requestId().view()) catch {};
            }

            if (comptime options.skip.len > 0) {
                const path = c.path().view();
                inline for (options.skip) |skipped| {
                    if (std.mem.eql(u8, path, skipped)) return next.run(c);
                }
            }
            const started = bulkhead.monotonicNanos();

            // The handler's error is reported and then passed along
            // untouched — App is what turns it into a response, and a
            // logger that swallowed it would change behaviour just by
            // being installed.
            next.run(c) catch |err| {
                // An answer already on the wire cannot be taken back, so
                // that is the status this request had — whatever the error
                // would have mapped to. A WebSocket handler failing after
                // its 101, or a stream failing mid-body, used to be logged
                // as a 500 nobody sent.
                const status = c.answered() orelse statusOf(err);
                log(c, status, microsSince(started), nameOf(err));
                return err;
            };

            log(c, c.answered() orelse 0, microsSince(started), null);
        }

        /// `noinline` for the reason
        /// [ADR 062](../docs/adr/062-where-a-connection-waits-is-what-it-costs.md)
        /// §3 gives, and this is the same mistake it found in
        /// `handleConnection`: the `max_line` buffer below is a local, `run`
        /// above is live across `next.run(c)`, and a frame that is live while a
        /// handler waits is memory every connection holds for as long as it
        /// waits. Inlined, this puts a kilobyte there whether or not a line is
        /// ever printed.
        ///
        /// What waits inside a handler is a database call, an outbound call and
        /// an SSE stream — and a stream waits there for as long as it lives. A
        /// WebSocket is unaffected, because its loop runs from
        /// `App.handleConnection` after the request has unwound (§4).
        noinline fn log(c: *Ctx, status: u16, took: u64, err_name: ?[]const u8) void {
            const slow = options.slow_micros > 0 and took > options.slow_micros;
            const level: std.log.Level = if (slow) .warn else options.level;

            // The run-time floor first, so a line the process does not write
            // is not built either. Only under `nilo.logFn`: behind std's
            // default there is no floor but the comptime one.
            if (log_mod.floorApplies() and !log_mod.enabled(level)) return;

            // Assembled into a stack buffer and handed on as one `{s}`.
            // Both shapes are built the same way so there is one place a
            // line is put together — and the JSON one has to be, because a
            // path is a stranger's text and needs escaping.
            var buf: [max_line]u8 = undefined;
            const line = lineFor(options, &buf, c, status, took, err_name, log_mod.format());

            if (builtin.is_test) if (tap) |sink| {
                sink.writeAll(line) catch {};
                sink.writeByte('\n') catch {};
                return;
            };

            // Under `nilo.logFn` the scope tells the sink to put the object's
            // fields beside `time` and `level`; under std's default there is
            // no such sink, and a scope would only be noise in front.
            const out = std.log.scoped(if (log_mod.installed) log_mod.access_scope else .default);

            // std.log's level is comptime, so the branch is unrolled here
            // rather than passed along as a value.
            switch (level) {
                .err => out.err("{s}", .{line}),
                .warn => out.warn("{s}", .{line}),
                .info => out.info("{s}", .{line}),
                .debug => out.debug("{s}", .{line}),
            }
        }
    }.run;
}

/// Test-only: where the line goes instead of `std.log`, which the test
/// runner owns and a suite cannot read back.
pub threadlocal var tap: ?*std.Io.Writer = null;

/// The line one request is logged as. A free function rather than something
/// buried inside `with`, so the shape of a line can be asserted without
/// arranging to catch what `std.log` did with it.
///
/// Truncated to `buf` rather than failing: a cut line still says which
/// request it was about, and a logger that could fail would be a second
/// failure path on the way out of the first.
pub fn lineFor(
    comptime options: Options,
    buf: []u8,
    c: *Ctx,
    status: u16,
    took: u64,
    err_name: ?[]const u8,
    as: Format,
) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    writeLine(options, &w, c, status, took, err_name, as, c.path().view()) catch {
        // A JSON object cut short is not JSON, and a collector drops the
        // line. The path is the one field with no bound but the request
        // head's, so it is the one shortened, and the object closed whole.
        if (as == .json) {
            w.end = 0;
            const path = c.path().view();
            const short = path[0..fail.wholeCharacters(path[0..@min(path.len, 100)])];
            writeLine(options, &w, c, status, took, err_name, as, short) catch {};
        }
    };
    return buf[0..w.end];
}

fn writeLine(
    comptime options: Options,
    w: *std.Io.Writer,
    c: *Ctx,
    status: u16,
    took: u64,
    err_name: ?[]const u8,
    as: Format,
    path: []const u8,
) !void {
    const method = @tagName(c.method);

    switch (as) {
        .text => {
            try w.print("{s} ", .{method});
            try writeEscaped(w, path);
            try w.print(" {d} {d}µs", .{ status, took });
            if (err_name) |name| try w.print(" error={s}", .{name});
            if (options.request_id) {
                try w.writeAll(" req=");
                try writeEscaped(w, c.requestId().view());
            }
            // On an App that traces, the id a trace view searches by, so a
            // line leads to its trace and back (ADR 247).
            try c.writeTraceId(w, " trace=", "");
        },
        // Every value a path could smuggle a delimiter through goes out
        // through the one escaper the response bodies use (`json.zig`).
        .json => {
            try w.writeAll("{\"method\":");
            try json_mod.writeString(w, method);
            try w.writeAll(",\"path\":");
            // Lossy: a path is a stranger's bytes, and `%ff` decodes to one
            // that is not text. JSON is UTF-8, so it goes out as U+FFFD.
            try json_mod.writeLossyString(w, path);
            try w.print(",\"status\":{d},\"us\":{d}", .{ status, took });
            if (err_name) |name| {
                try w.writeAll(",\"error\":");
                try json_mod.writeString(w, name);
            }
            if (options.request_id) {
                try w.writeAll(",\"request_id\":");
                try json_mod.writeString(w, c.requestId().view());
            }
            // OpenTelemetry's own name for the field, which a log pipeline
            // that already speaks it joins to the trace without a mapping.
            try c.writeTraceId(w, ",\"trace_id\":\"", "\"");
            try w.writeByte('}');
        },
    }
}

/// Text a stranger sent, with every control byte (and DEL) written as `\xNN`.
/// The target is not checked for them, and a raw ESC steers a terminal while
/// a raw CR overwrites the line the reader is on; the `.json` format gets the
/// same effect from its escaper. Bytes above 0x7f pass, so UTF-8 reads as it
/// came.
fn writeEscaped(w: *std.Io.Writer, text: []const u8) !void {
    for (text) |byte| {
        if (byte < 0x20 or byte == 0x7f) {
            try w.print("\\x{x:0>2}", .{byte});
        } else {
            try w.writeByte(byte);
        }
    }
}

/// The error worth naming on the log line, or null when there is none.
///
/// `error.Failed` is the sentinel every fail function returns — it carries
/// no information the status code does not already carry, so a line reading
/// `404 error=Failed` is one column of noise on the most ordinary answer a
/// server gives. The message the fail function was given is what matters,
/// and that has already gone to the client.
fn nameOf(err: anyerror) ?[]const u8 {
    if (err == fail.Error.Failed) return null;
    return @errorName(err);
}

/// What App is about to answer with. Asking `fail` rather than working it
/// out again keeps the logged status and the sent status from drifting
/// apart.
fn statusOf(err: anyerror) u16 {
    const failure = fail.current() orelse return fail.statusFor(err);
    return fail.resolveStatus(failure, err);
}

fn microsSince(started: u64) u64 {
    return (bulkhead.monotonicNanos() -| started) / std.time.ns_per_us;
}

// ---- tests ----

const testing = std.testing;
const str_mod = @import("nilo_core");

/// A Ctx with only what a log line reads filled in. Enough because the line
/// touches four things and nothing else; anything more would be arranging a
/// whole request to assert a string.
fn requestThatWas(
    lifetime: *const str_mod.Lifetime,
    path: []const u8,
    id: ?[]const u8,
) Ctx {
    var c: Ctx = undefined;
    c.method = .GET;
    c._path = path;
    c._lifetime = lifetime;
    c._request_id = if (id) |text| str_mod.Str.fromRequest(text, lifetime) else null;
    c._tracer = null;
    return c;
}

test "a text line reads the way it always has" {
    var lifetime: str_mod.Lifetime = .{};
    var c = requestThatWas(&lifetime, "/users/7", null);
    var buf: [max_line]u8 = undefined;

    try testing.expectEqualStrings(
        "GET /users/7 200 59µs",
        lineFor(.{}, &buf, &c, 200, 59, null, .text),
    );
    try testing.expectEqualStrings(
        "GET /users/7 500 59µs error=OutOfMemory",
        lineFor(.{}, &buf, &c, 500, 59, "OutOfMemory", .text),
    );
}

test "a json line carries the same four things, and the id when asked" {
    var lifetime: str_mod.Lifetime = .{};
    var c = requestThatWas(&lifetime, "/users/7", "abc123");
    var buf: [max_line]u8 = undefined;

    try testing.expectEqualStrings(
        "{\"method\":\"GET\",\"path\":\"/users/7\",\"status\":200,\"us\":59}",
        lineFor(.{}, &buf, &c, 200, 59, null, .json),
    );
    try testing.expectEqualStrings(
        "{\"method\":\"GET\",\"path\":\"/users/7\",\"status\":500,\"us\":59," ++
            "\"error\":\"OutOfMemory\",\"request_id\":\"abc123\"}",
        lineFor(.{ .request_id = true }, &buf, &c, 500, 59, "OutOfMemory", .json),
    );
}

test "on an App that traces, a line carries the trace id in both formats" {
    var lifetime: str_mod.Lifetime = .{};
    var c = requestThatWas(&lifetime, "/users/7", null);
    var tracer = try @import("trace.zig").Tracer.init(testing.allocator, .{ .service = "orders" });
    defer tracer.deinit();
    c._tracer = &tracer;
    c._trace.context = str_mod.trace.Context.parse(
        "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
    ).?;
    var buf: [max_line]u8 = undefined;

    try testing.expectEqualStrings(
        "GET /users/7 200 59µs trace=4bf92f3577b34da6a3ce929d0e0e4736",
        lineFor(.{}, &buf, &c, 200, 59, null, .text),
    );
    try testing.expectEqualStrings(
        "{\"method\":\"GET\",\"path\":\"/users/7\",\"status\":200,\"us\":59," ++
            "\"trace_id\":\"4bf92f3577b34da6a3ce929d0e0e4736\"}",
        lineFor(.{}, &buf, &c, 200, 59, null, .json),
    );
}

test "a path that would break the line out of its own field cannot" {
    // The path is a stranger's text. A quote would end the JSON string and a
    // newline would forge a second line; both go out escaped instead.
    var lifetime: str_mod.Lifetime = .{};
    var c = requestThatWas(&lifetime, "/x\",\"status\":200,\"path\":\"\n/y", null);
    var buf: [max_line]u8 = undefined;

    const line = lineFor(.{}, &buf, &c, 404, 3, null, .json);
    try testing.expectEqualStrings(
        "{\"method\":\"GET\",\"path\":\"/x\\\",\\\"status\\\":200,\\\"path\\\":\\\"\\n/y\"," ++
            "\"status\":404,\"us\":3}",
        line,
    );

    // And it really is one JSON object with the status this request had.
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, line, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(i64, 404), parsed.value.object.get("status").?.integer);
}

test "a line too long for the buffer is cut, not dropped" {
    var lifetime: str_mod.Lifetime = .{};
    var c = requestThatWas(&lifetime, "/" ++ (&@as([200]u8, @splat('x'))), null);
    var buf: [64]u8 = undefined;

    const line = lineFor(.{}, &buf, &c, 200, 1, null, .text);
    try testing.expect(line.len > 0);
    try testing.expect(line.len <= buf.len);
    try testing.expect(std.mem.startsWith(u8, line, "GET /xxx"));
}

test "a text line writes a path's control bytes escaped, so a terminal cannot be steered by it" {
    var lifetime: str_mod.Lifetime = .{};
    var c = requestThatWas(&lifetime, "/a\x1b[31mRED\rFAKE\x7f", "id\x1b");
    var buf: [max_line]u8 = undefined;

    const line = lineFor(.{ .request_id = true }, &buf, &c, 404, 3, null, .text);
    try testing.expectEqualStrings(
        "GET /a\\x1b[31mRED\\x0dFAKE\\x7f 404 3µs req=id\\x1b",
        line,
    );
    for (line) |byte| try testing.expect(byte >= 0x20 and byte != 0x7f);
}

test "a path that is not UTF-8 is written as U+FFFD, so the json line still parses" {
    var lifetime: str_mod.Lifetime = .{};
    var c = requestThatWas(&lifetime, "/a\xff\xfeb", null);
    var buf: [max_line]u8 = undefined;

    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        lineFor(.{}, &buf, &c, 404, 3, null, .json),
        .{},
    );
    defer parsed.deinit();
    try testing.expectEqualStrings("/a\u{FFFD}\u{FFFD}b", parsed.value.object.get("path").?.string);
}
