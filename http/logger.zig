//! The logger middleware — one line per request, with the status and how
//! long it took.
//!
//! ```zig
//! try app.use(logger.standard);
//! try app.use(logger.with(.{ .level = .debug, .slow_micros = 50_000 }));
//! try app.use(logger.with(.{ .format = .json, .request_id = true }));
//! ```
//!
//! Configured at compile time, so an option nobody switched on costs
//! nothing at runtime.

const std = @import("std");
const Ctx = @import("ctx.zig").Ctx;
const mw = @import("middleware.zig");
const fail = @import("fail.zig");
const bulkhead = @import("bulkhead.zig");
const json = @import("json.zig");

/// How much of a line is written before it is handed to `std.log`. A path is
/// the long part and a request head bounds it; past this the line is cut
/// rather than dropped, on the same reasoning a failure message is
/// ([ADR 0005](../docs/adr/0005-http-errors-via-fail-functions.md)).
const max_line = 1024;

pub const Format = enum {
    /// `GET /users/7 200 59µs` — what a person reads in a terminal.
    text,
    /// One JSON object per line, for whatever collects them.
    json,
};

pub const Options = struct {
    /// The level ordinary requests are logged at.
    level: std.log.Level = .info,
    /// Requests taking longer than this are logged at `.warn` instead, so
    /// they stand out without needing a second tool. 0 turns that off.
    slow_micros: u64 = 0,
    format: Format = .text,
    /// Give every request an id: `X-Request-Id` on the way out, and the same
    /// id on its log line.
    ///
    /// The one thing a proxy in front cannot reconstruct afterwards is which
    /// log lines belong to the request that timed out
    /// ([ADR 0028](../docs/adr/0028-tls-is-terminated-in-front.md)). Off by
    /// default because it costs a header on every response; `c.requestId()`
    /// works either way.
    request_id: bool = false,
};

/// The default: one `info` line per request.
pub const standard = with(.{});

pub fn with(comptime options: Options) mw.Middleware {
    return struct {
        fn run(c: *Ctx, next: mw.Next) anyerror!void {
            const started = bulkhead.monotonicNanos();

            if (options.request_id) {
                // Set before the handler runs, not after: a response is
                // flushed the moment it is sent, so a header put on
                // afterwards would never leave the building (ADR 0009).
                //
                // Static rather than copied — the id is either the Ctx's own
                // buffer or a slice of the request head, and both outlive the
                // response. A failure here is not worth ending a request over:
                // the header is a convenience, and the log line still carries
                // the id.
                c.setStaticHeader("X-Request-Id", c.requestId().view()) catch {};
            }

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
                const status = if (c._sent) c._status else statusOf(err);
                log(c, status, microsSince(started), nameOf(err));
                return err;
            };

            log(c, c._status, microsSince(started), null);
        }

        fn log(c: *Ctx, status: u16, took: u64, err_name: ?[]const u8) void {
            const slow = options.slow_micros > 0 and took > options.slow_micros;
            const level: std.log.Level = if (slow) .warn else options.level;

            // Assembled into a stack buffer and handed on as one `{s}`.
            // Both shapes are built the same way so there is one place a
            // line is put together — and the JSON one has to be, because a
            // path is a stranger's text and needs escaping.
            var buf: [max_line]u8 = undefined;
            const line = lineFor(options, &buf, c, status, took, err_name);

            // std.log's level is comptime, so the branch is unrolled here
            // rather than passed along as a value.
            switch (level) {
                .err => std.log.err("{s}", .{line}),
                .warn => std.log.warn("{s}", .{line}),
                .info => std.log.info("{s}", .{line}),
                .debug => std.log.debug("{s}", .{line}),
            }
        }

    }.run;
}

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
) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    writeLine(options, &w, c, status, took, err_name) catch {};
    return buf[0..w.end];
}

fn writeLine(
    comptime options: Options,
    w: *std.Io.Writer,
    c: *Ctx,
    status: u16,
    took: u64,
    err_name: ?[]const u8,
) !void {
    const method = @tagName(c.method);
    const path = c._path;

    switch (options.format) {
        .text => {
            try w.print("{s} {s} {d} {d}µs", .{ method, path, status, took });
            if (err_name) |name| try w.print(" error={s}", .{name});
            if (options.request_id) try w.print(" req={s}", .{c.requestId().view()});
        },
        // Every value a path could smuggle a delimiter through goes out
        // through the one escaper the response bodies use (`json.zig`).
        .json => {
            try w.writeAll("{\"method\":");
            try json.writeString(w, method);
            try w.writeAll(",\"path\":");
            try json.writeString(w, path);
            try w.print(",\"status\":{d},\"us\":{d}", .{ status, took });
            if (err_name) |name| {
                try w.writeAll(",\"error\":");
                try json.writeString(w, name);
            }
            if (options.request_id) {
                try w.writeAll(",\"request_id\":");
                try json.writeString(w, c.requestId().view());
            }
            try w.writeByte('}');
        },
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
    return c;
}

test "a text line reads the way it always has" {
    var lifetime: str_mod.Lifetime = .{};
    var c = requestThatWas(&lifetime, "/users/7", null);
    var buf: [max_line]u8 = undefined;

    try testing.expectEqualStrings(
        "GET /users/7 200 59µs",
        lineFor(.{}, &buf, &c, 200, 59, null),
    );
    try testing.expectEqualStrings(
        "GET /users/7 500 59µs error=OutOfMemory",
        lineFor(.{}, &buf, &c, 500, 59, "OutOfMemory"),
    );
}

test "a json line carries the same four things, and the id when asked" {
    var lifetime: str_mod.Lifetime = .{};
    var c = requestThatWas(&lifetime, "/users/7", "abc123");
    var buf: [max_line]u8 = undefined;

    try testing.expectEqualStrings(
        "{\"method\":\"GET\",\"path\":\"/users/7\",\"status\":200,\"us\":59}",
        lineFor(.{ .format = .json }, &buf, &c, 200, 59, null),
    );
    try testing.expectEqualStrings(
        "{\"method\":\"GET\",\"path\":\"/users/7\",\"status\":500,\"us\":59," ++
            "\"error\":\"OutOfMemory\",\"request_id\":\"abc123\"}",
        lineFor(.{ .format = .json, .request_id = true }, &buf, &c, 500, 59, "OutOfMemory"),
    );
}

test "a path that would break the line out of its own field cannot" {
    // The path is a stranger's text. A quote would end the JSON string and a
    // newline would forge a second line; both go out escaped instead.
    var lifetime: str_mod.Lifetime = .{};
    var c = requestThatWas(&lifetime, "/x\",\"status\":200,\"path\":\"\n/y", null);
    var buf: [max_line]u8 = undefined;

    const line = lineFor(.{ .format = .json }, &buf, &c, 404, 3, null);
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
    var c = requestThatWas(&lifetime, "/" ++ ("x" ** 200), null);
    var buf: [64]u8 = undefined;

    const line = lineFor(.{}, &buf, &c, 200, 1, null);
    try testing.expect(line.len > 0);
    try testing.expect(line.len <= buf.len);
    try testing.expect(std.mem.startsWith(u8, line, "GET /xxx"));
}
