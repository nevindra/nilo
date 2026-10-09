//! The one place a log line is written (ADR 262).
//!
//! Zig 0.17's default `logFn` prefixes every line with `info: `, so a
//! `.format = .json` logger reached stderr as `info: {"method":...}`, which
//! no collector parses. Nothing a library does can change that: `logFn` is a
//! root declaration. So nilo ships the function and the program names it:
//!
//! ```zig
//! pub const std_options: std.Options = .{ .logFn = nilo.logFn };
//! ```
//!
//! **One line per call, no allocation, one lock.** The line is assembled in a
//! stack buffer and written once under the lock std's own default takes, so
//! two threads cannot interleave halves of a line. A message too long for the
//! buffer is cut at a character boundary, and a JSON line is cut *inside* its
//! `msg` string and still closed, so truncation never breaks the syntax a
//! collector reads.
//!
//! **Format and level are run-time facts**, set from `listen(.{ .log = … })`
//! for the reason ADR 088 moved CORS origins to run time: the deployment
//! decides, and a rebuild per environment is the wrong price. `std_options.
//! log_level` stays the comptime ceiling, where a call below it is compiled
//! out and costs nothing. The run-time level filters inside that ceiling.
//!
//! **A handler's line joins its request.** `fail.InFlight` already is what the
//! fiber slot points at, and it now also points at the Ctx of the request in
//! flight. The id is read only when a line is written, so a request that
//! logs nothing pays nothing, and a line outside a request carries none. It
//! works on an HTTP/2 stream for the same reason the fail functions do:
//! `serve.serveRequest` sets it for both.
//!
//! **The access line is flat.** `logger` writes its fields as one JSON object
//! and sends it under the `nilo_access` scope; in JSON the sink splices
//! `time` and `level` in front of those fields, so a collector sees one
//! object rather than a JSON string holding another. In text the scope is
//! left off, and the line reads as it always has with a time in front.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("nilo_core");
const bulkhead = @import("bulkhead.zig");
const fail = @import("fail.zig");

pub const Format = bulkhead.Options.Log.Format;
pub const Settings = bulkhead.Options.Log;

/// The scope the access line is sent under when `logFn` is installed. A name
/// no library of the program's is likely to use, and the only scope the sink
/// treats differently.
pub const access_scope = .nilo_access;

/// Whether the program's root `std_options` names `logFn`. A comptime fact,
/// which is how `logger` knows whether the scope above will be understood.
pub const installed = std.options.logFn == logFn;

/// The room a line has, and what of it is kept back for what comes after the
/// message: the request id, the closing quote and brace, the newline.
const line_max = 1536;
const reserve = 192;
const id_max = 128;
/// The message as the caller formatted it, before it is escaped. A message
/// longer than this is cut, at a character boundary.
const msg_max = 1024;

var format_state: std.atomic.Value(u8) = .init(@intFromEnum(Format.text));
var level_state: std.atomic.Value(u8) = .init(@intFromEnum(std.options.log_level));

/// Make `settings` the process's. Called by `listen()`; a program that never
/// listens, or a test, keeps the defaults.
pub fn configure(settings: Settings) void {
    format_state.store(@intFromEnum(settings.format), .monotonic);
    level_state.store(@intFromEnum(settings.level orelse std.options.log_level), .monotonic);
}

pub fn format() Format {
    return @enumFromInt(format_state.load(.monotonic));
}

/// Test-only: pretend `logFn` is installed, so the logger's use of the floor
/// can be seen in a suite whose root is the test runner.
pub threadlocal var pretend_installed: bool = false;

/// Whether the run-time floor applies to the access line. Only when the sink
/// is the program's: behind std's default `logFn` nobody chose a floor, and
/// the comptime `log_level` is the one filter there is.
pub fn floorApplies() bool {
    return installed or (builtin.is_test and pretend_installed);
}

/// Whether a line at `level` is written, by the run-time floor.
pub fn enabled(level: std.log.Level) bool {
    return @intFromEnum(level) <= level_state.load(.monotonic);
}

/// The `std_options.logFn` of a nilo program.
///
/// **Thin on purpose.** This is generic over level, scope, format and
/// arguments, so everything in its body is instantiated once per `std.log`
/// call site in the program. All it does is format the caller's message into
/// a stack buffer, which std's default pays too, and hand the bytes to `emit`,
/// which is not generic: the time, the level, the scope, the request id, the
/// escaping and the lock exist once. The first version did all of it here and
/// cost a hello-world 41,744 bytes of stripped binary (ADR 262, ADR 017).
pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime fmt: []const u8,
    args: anytype,
) void {
    if (!enabled(level)) return;
    formatAndEmit(level, scope, fmt, args);
}

/// **No buffer of the line is on the stack.** The message and the line are
/// formatted into two statics while the stderr lock is held, which is what
/// makes sharing them safe: the lock is already one-at-a-time. A suspended
/// fiber keeps its stack at its high-water mark (ADR 062), so a handler that
/// logged once would otherwise hold the 2.5 KiB of buffers, and the page they
/// land on, for the life of its connection. std's default takes a 64-byte
/// buffer for the same reason. What is left on the stack is a handful of words.
///
/// `noinline` so even those stay out of the caller's frame.
noinline fn formatAndEmit(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime fmt: []const u8,
    args: anytype,
) void {
    var held = Held.acquire();
    defer held.release();
    const name = if (scope == .default) "" else @tagName(scope);
    if (depth > 0) return nested(&held, level, name, scope == access_scope, fmt, args);
    depth += 1;
    defer depth -= 1;
    const msg = formatted(&msg_buf, fmt, args);
    emit(&held, &line_buf, level, name, scope == access_scope, msg);
}

/// How many log calls this thread is inside. The stderr lock is recursive on
/// a thread, so a second call from the same one gets past it, and the statics
/// below belong to the first: a `format` method of the caller's that logs, or
/// a panic handler that logs while a line is being written, would otherwise
/// overwrite the line in progress. A fiber that parks inside the write leaves
/// this raised for another on the thread, which then takes the small path
/// below, so the cost of a wrong guess is a shorter line, never a torn one.
threadlocal var depth: u8 = 0;

/// What a call made while another is being written gets: its own small
/// buffers on the stack, so a line is cut at 256 bytes of message but never
/// lost and never mixed with the outer one. Rare enough that its frame is
/// not worth being off the stack for.
noinline fn nested(
    held: *Held,
    comptime level: std.log.Level,
    scope: []const u8,
    access: bool,
    comptime fmt: []const u8,
    args: anytype,
) void {
    var msg: [256]u8 = undefined;
    var line: [448]u8 = undefined;
    emit(held, &line, level, scope, access, formatted(&msg, fmt, args));
}

var msg_buf: [msg_max]u8 = undefined;
var line_buf: [line_max]u8 = undefined;
var lock_buf: [64]u8 = undefined;

/// The stderr lock std's default takes, with cancellation held off for the
/// length of it. Under a test with `capture` set there is nothing to lock.
const Held = struct {
    locked: ?std.Io.LockedStderr,
    prev: std.Io.CancelProtection,

    fn acquire() Held {
        if (builtin.is_test) if (capture != null) return .{ .locked = null, .prev = .unblocked };
        const io = std.Options.debug_io;
        const prev = io.swapCancelProtection(.blocked);
        return .{ .locked = std.debug.lockStderr(&lock_buf), .prev = prev };
    }

    fn release(self: *Held) void {
        if (self.locked == null) return;
        std.debug.unlockStderr();
        _ = std.Options.debug_io.swapCancelProtection(self.prev);
    }

    fn write(self: *Held, line: []const u8) void {
        if (builtin.is_test) if (capture) |sink| {
            sink.writeAll(line) catch {};
            return;
        };
        const out = &(self.locked orelse return).file_writer.interface;
        out.writeAll(line) catch {};
        out.flush() catch {};
    }
};

/// The one function that writes a line: not generic, so it is in the binary
/// once however many places log.
noinline fn emit(held: *Held, line: []u8, level: std.log.Level, scope: []const u8, access: bool, msg: []const u8) void {
    // Asked here, after the level has let the line through, which is the only
    // place the id is made: a filtered line and a request that logs nothing
    // never reach for it.
    const request: ?[]const u8 = if (access) null else if (fail.inFlight()) |f| f.requestId() else null;
    held.write(render(line, format(), level, scope, access, core.nowMicros(), request, msg));
}

/// The caller's message in `buf`, cut at a character boundary when it did not
/// fit. A character cut off by the caller's own bytes is not repaired here: the
/// JSON escaper turns it into U+FFFD.
fn formatted(buf: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    w.print(fmt, args) catch return buf[0..fail.wholeCharacters(buf[0..w.end])];
    return buf[0..w.end];
}

/// The line, in `buf`, newline included. Pure: nothing but its arguments.
///
/// `access` says the message is a whole JSON object the logger built, to be
/// flattened beside `time` and `level` rather than quoted into `msg`.
pub fn render(
    buf: []u8,
    as: Format,
    level: std.log.Level,
    scope: []const u8,
    access: bool,
    micros: i64,
    request: ?[]const u8,
    msg: []const u8,
) []const u8 {
    const room = buf.len - @min(buf.len, reserve);
    var at: usize = 0;
    var stamp: [24]u8 = undefined;
    timestamp(&stamp, micros);

    switch (as) {
        .text => {
            at = put(buf[0..room], at, &stamp);
            at = put(buf[0..room], at, " ");
            at = put(buf[0..room], at, levelName(level));
            if (scope.len > 0 and !access) {
                at = put(buf[0..room], at, "(");
                at = put(buf[0..room], at, scope);
                at = put(buf[0..room], at, ")");
            }
            at = put(buf[0..room], at, " ");
            const n = fail.wholeCharacters(msg[0..@min(msg.len, room - at)]);
            at = put(buf[0..room], at, msg[0..n]);
            if (request) |id| {
                at = put(buf, at, " request=");
                at = put(buf, at, clip(id));
            }
            at = put(buf, at, "\n");
        },
        .json => {
            at = put(buf[0..room], at, "{\"time\":\"");
            at = put(buf[0..room], at, &stamp);
            at = put(buf[0..room], at, "\",\"level\":\"");
            at = put(buf[0..room], at, levelName(level));
            at = put(buf[0..room], at, "\"");
            if (access) {
                // The message is `{...}`; its brace becomes the comma that
                // joins its fields to the two above, and it brings its own
                // closing brace.
                if (msg.len > 1 and msg[0] == '{') {
                    at = put(buf[0..room], at, ",");
                    at = put(buf[0..room], at, msg[1..]);
                } else at = put(buf[0..room], at, "}");
            } else {
                if (scope.len > 0) {
                    at = put(buf[0..room], at, ",\"scope\":\"");
                    at = put(buf[0..room], at, scope);
                    at = put(buf[0..room], at, "\"");
                }
                at = put(buf[0..room], at, ",\"msg\":\"");
                at = escape(buf[0..room], at, msg);
                at = put(buf, at, "\"");
                if (request) |id| {
                    at = put(buf, at, ",\"request\":\"");
                    at = escape(buf, at, clip(id));
                    at = put(buf, at, "\"");
                }
                at = put(buf, at, "}");
            }
            at = put(buf, at, "\n");
        },
    }
    return buf[0..at];
}

/// Append `text` at `at`, as much as fits; the new end.
fn put(buf: []u8, at: usize, text: []const u8) usize {
    const n = @min(text.len, buf.len - at);
    @memcpy(buf[at..][0..n], text[0..n]);
    return at + n;
}

/// Append `text` JSON-escaped, stopping before a byte whose escape would not
/// fit (so a cut line never ends halfway through `\u001f`). **Bytes that are
/// not UTF-8 become U+FFFD**, so the line is JSON whatever a `{s}` was handed.
fn escape(buf: []u8, start: usize, text: []const u8) usize {
    var at = start;
    var i: usize = 0;
    while (i < text.len) {
        const byte = text[i];
        switch (byte) {
            '"', '\\', '\n', '\r', '\t' => {
                if (buf.len - at < 2) break;
                buf[at] = '\\';
                buf[at + 1] = switch (byte) {
                    '\n' => 'n',
                    '\r' => 'r',
                    '\t' => 't',
                    else => byte,
                };
                at += 2;
                i += 1;
            },
            0...0x08, 0x0b...0x0c, 0x0e...0x1f => {
                if (buf.len - at < 6) break;
                at = put(buf, at, "\\u00");
                buf[at] = "0123456789abcdef"[byte >> 4];
                buf[at + 1] = "0123456789abcdef"[byte & 15];
                at += 2;
                i += 1;
            },
            0x20...0x21, 0x23...0x5b, 0x5d...0x7f => {
                if (buf.len - at < 1) break;
                buf[at] = byte;
                at += 1;
                i += 1;
            },
            else => {
                const n = std.unicode.utf8ByteSequenceLength(byte) catch 0;
                const whole = n >= 2 and i + n <= text.len and std.unicode.utf8ValidateSlice(text[i..][0..n]);
                // A sequence that is cut short or malformed is one U+FFFD for
                // the lead and the continuation bytes that followed it.
                var width: usize = 1;
                if (whole) {
                    width = n;
                } else if (n >= 2) {
                    while (width < n and i + width < text.len and text[i + width] & 0xC0 == 0x80) width += 1;
                }
                const out = if (whole) text[i..][0..n] else "\u{FFFD}";
                if (buf.len - at < out.len) break;
                at = put(buf, at, out);
                i += width;
            },
        }
    }
    return at;
}

fn clip(id: []const u8) []const u8 {
    return id[0..fail.wholeCharacters(id[0..@min(id.len, id_max)])];
}

fn levelName(level: std.log.Level) []const u8 {
    return switch (level) {
        .err => "error",
        .warn => "warn",
        .info => "info",
        .debug => "debug",
    };
}

/// `2026-10-09T12:00:00.123Z`, UTC, always 24 bytes. Whole milliseconds of
/// the wall clock a line is written at: a log line's time is when it was
/// written, which is not the cached second the `Date` header settles for.
/// Digits are written by hand: this is the only caller that wants them padded
/// and it keeps the formatter's integer machinery out of the sink.
fn timestamp(out: *[24]u8, micros: i64) void {
    const total = @max(micros, 0);
    const secs: u64 = @intCast(@divFloor(total, std.time.us_per_s));
    const ms: u32 = @intCast(@divFloor(@mod(total, std.time.us_per_s), std.time.us_per_ms));
    const es: std.time.epoch.EpochSeconds = .{ .secs = secs };
    const year_day = es.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day = es.getDaySeconds();
    digits(out[0..4], year_day.year);
    out[4] = '-';
    digits(out[5..7], month_day.month.numeric());
    out[7] = '-';
    digits(out[8..10], month_day.day_index + 1);
    out[10] = 'T';
    digits(out[11..13], day.getHoursIntoDay());
    out[13] = ':';
    digits(out[14..16], day.getMinutesIntoHour());
    out[16] = ':';
    digits(out[17..19], day.getSecondsIntoMinute());
    out[19] = '.';
    digits(out[20..23], ms);
    out[23] = 'Z';
}

fn digits(out: []u8, value: anytype) void {
    var v: u32 = @intCast(value);
    var i = out.len;
    while (i > 0) {
        i -= 1;
        out[i] = '0' + @as(u8, @intCast(v % 10));
        v /= 10;
    }
}

/// Test-only: a place to send lines instead of stderr.
pub threadlocal var capture: ?*std.Io.Writer = null;

/// The line `logFn` would write for the request this fiber is serving, for a
/// test to read instead of catching stderr.
fn lineHere(
    buf: []u8,
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime fmt: []const u8,
    args: anytype,
) []const u8 {
    var msg: [msg_max]u8 = undefined;
    const access = scope == access_scope;
    const request: ?[]const u8 = if (access) null else if (fail.inFlight()) |f| f.requestId() else null;
    return render(buf, format(), level, if (scope == .default) "" else @tagName(scope), access, core.nowMicros(), request, formatted(&msg, fmt, args));
}

/// `render` with the message formatted first, as `logFn` does.
fn renderFmt(
    buf: []u8,
    as: Format,
    level: std.log.Level,
    scope: []const u8,
    access: bool,
    micros: i64,
    request: ?[]const u8,
    comptime fmt: []const u8,
    args: anytype,
) []const u8 {
    var msg: [msg_max]u8 = undefined;
    return render(buf, as, level, scope, access, micros, request, formatted(&msg, fmt, args));
}

// ---- tests ----

const testing = std.testing;

fn parse(line: []const u8) !std.json.Parsed(std.json.Value) {
    try testing.expect(line[line.len - 1] == '\n');
    return std.json.parseFromSlice(std.json.Value, testing.allocator, line[0 .. line.len - 1], .{});
}

const noon: i64 = 1_791_547_200_000_000 + 123_456; // 2026-10-09T12:00:00.123Z

test "a text line leads with the time and level, then the scope and the message" {
    var buf: [line_max]u8 = undefined;
    try testing.expectEqualStrings(
        "2026-10-09T12:00:00.123Z warn(db) pool is full\n",
        renderFmt(&buf, .text, .warn, "db", false, noon, null, "pool is {s}", .{"full"}),
    );
    try testing.expectEqualStrings(
        "2026-10-09T12:00:00.123Z info hello request=ab12\n",
        renderFmt(&buf, .text, .info, "", false, noon, "ab12", "hello", .{}),
    );
}

test "a json line parses back, with the message escaped and the id beside it" {
    var buf: [line_max]u8 = undefined;
    const line = renderFmt(&buf, .json, .err, "db", false, noon, "ab12", "bad \"{s}\"\n\x01", .{"x\\y"});
    const parsed = try parse(line);
    defer parsed.deinit();
    const o = parsed.value.object;
    try testing.expectEqualStrings("2026-10-09T12:00:00.123Z", o.get("time").?.string);
    try testing.expectEqualStrings("error", o.get("level").?.string);
    try testing.expectEqualStrings("db", o.get("scope").?.string);
    try testing.expectEqualStrings("bad \"x\\y\"\n\x01", o.get("msg").?.string);
    try testing.expectEqualStrings("ab12", o.get("request").?.string);
}

test "a json line leaves scope and request out when there are none" {
    var buf: [line_max]u8 = undefined;
    const parsed = try parse(renderFmt(&buf, .json, .info, "", false, noon, null, "up", .{}));
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("scope") == null);
    try testing.expect(parsed.value.object.get("request") == null);
}

test "a message too long for the line is cut and a json line is still json" {
    var buf: [line_max]u8 = undefined;
    var big: [9000]u8 = undefined;
    for (0..3000) |i| @memcpy(big[i * 3 ..][0..3], "é\"");
    const parsed = try parse(renderFmt(&buf, .json, .warn, "", false, noon, "id1", "{s}", .{&big}));
    defer parsed.deinit();
    const msg = parsed.value.object.get("msg").?.string;
    try testing.expect(msg.len > 500 and msg.len < big.len);
    try testing.expectEqualStrings("id1", parsed.value.object.get("request").?.string);

    const text = renderFmt(&buf, .text, .warn, "", false, noon, "id1", "{s}", .{&big});
    try testing.expect(text.len <= line_max);
    try testing.expect(std.unicode.utf8ValidateSlice(text));
    try testing.expect(std.mem.endsWith(u8, text, " request=id1\n"));
}

test "an access message is flattened beside the time and level in json and plain in text" {
    var buf: [line_max]u8 = undefined;
    const fields = "{\"method\":\"GET\",\"path\":\"/x\",\"status\":200}";
    const parsed = try parse(renderFmt(&buf, .json, .info, "nilo_access", true, noon, null, "{s}", .{fields}));
    defer parsed.deinit();
    const o = parsed.value.object;
    try testing.expectEqualStrings("info", o.get("level").?.string);
    try testing.expectEqualStrings("GET", o.get("method").?.string);
    try testing.expectEqual(@as(i64, 200), o.get("status").?.integer);
    try testing.expect(o.get("msg") == null);

    try testing.expectEqualStrings(
        "2026-10-09T12:00:00.123Z info GET /x 200 59µs\n",
        renderFmt(&buf, .text, .info, "nilo_access", true, noon, null, "{s}", .{"GET /x 200 59µs"}),
    );
}

test "a handler's line carries the id of the request it was written in" {
    var in_flight: fail.InFlight = .{};
    const Fake = struct {
        fn id(_: *anyopaque, _: fail.InFlight.Part) []const u8 {
            return "req-7";
        }
    };
    var anchor: u8 = 0;
    const previous = bulkhead.setFallbackSlot(&in_flight);
    defer _ = bulkhead.setFallbackSlot(previous);
    var buf: [line_max]u8 = undefined;

    try testing.expect(std.mem.indexOf(u8, lineHere(&buf, .warn, .default, "out", .{}), "request=") == null);

    in_flight.request = &anchor;
    in_flight.read_request = Fake.id;
    try testing.expect(std.mem.endsWith(u8, lineHere(&buf, .warn, .default, "slow", .{}), "slow request=req-7\n"));

    in_flight.startRequest();
    try testing.expect(std.mem.indexOf(u8, lineHere(&buf, .warn, .default, "out", .{}), "request=") == null);
}

test "the run-time level filters what logFn writes" {
    var sink_buf: [512]u8 = undefined;
    var sink = std.Io.Writer.fixed(&sink_buf);
    capture = &sink;
    defer capture = null;
    configure(.{ .level = .warn });
    defer configure(.{});

    logFn(.info, .default, "quiet", .{});
    try testing.expectEqual(@as(usize, 0), sink.end);
    logFn(.warn, .default, "loud", .{});
    try testing.expect(std.mem.indexOf(u8, sink.buffered(), " warn loud\n") != null);
}

test "the format set at run time is the one logFn writes" {
    var sink_buf: [512]u8 = undefined;
    var sink = std.Io.Writer.fixed(&sink_buf);
    capture = &sink;
    defer capture = null;
    configure(.{ .format = .json, .level = .debug });
    defer configure(.{});

    logFn(.warn, .default, "hi", .{});
    const parsed = try parse(sink.buffered());
    defer parsed.deinit();
    try testing.expectEqualStrings("hi", parsed.value.object.get("msg").?.string);
}

test "bytes that are not UTF-8 in a message become U+FFFD and the line still parses" {
    var buf: [line_max]u8 = undefined;
    // A bare continuation, an invalid lead, a character split across
    // arguments is covered by `{s}{s}`, and a lead cut off by the end.
    const parsed = try parse(renderFmt(&buf, .json, .warn, "", false, noon, null, "a\xff\xfe{s}{s}b\xe2\x82", .{ "\xe2", "\x82\xac" }));
    defer parsed.deinit();
    try testing.expectEqualStrings("a\u{FFFD}\u{FFFD}\u{20AC}b\u{FFFD}", parsed.value.object.get("msg").?.string);
}

test "a floor left unset is the program's own log_level, not the build mode's" {
    configure(.{});
    for ([_]std.log.Level{ .err, .warn, .info, .debug }) |l| {
        try testing.expectEqual(@intFromEnum(l) <= @intFromEnum(std.options.log_level), enabled(l));
    }
    configure(.{ .level = .err });
    defer configure(.{});
    try testing.expect(!enabled(.warn));
}

const Chatty = struct {
    pub fn format(_: Chatty, w: *std.Io.Writer) std.Io.Writer.Error!void {
        logFn(.warn, .default, "inner line", .{});
        try w.writeAll("outer body");
    }
};

test "a log call made while another is being formatted does not garble it" {
    var sink_buf: [1024]u8 = undefined;
    var sink = std.Io.Writer.fixed(&sink_buf);
    capture = &sink;
    defer capture = null;
    configure(.{ .level = .debug });
    defer configure(.{});

    logFn(.warn, .default, "outer {f}!", .{Chatty{}});
    const got = sink.buffered();
    const inner = std.mem.indexOf(u8, got, " warn inner line\n").?;
    const outer = std.mem.indexOf(u8, got, " warn outer outer body!\n").?;
    try testing.expect(inner < outer);
    try testing.expectEqual(@as(u8, 0), depth);
}
