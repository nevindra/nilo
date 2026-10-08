//! W3C Trace Context: the `traceparent` a request arrives with and a call
//! leaves with ([ADR 247](../docs/adr/247-a-request-is-a-span-and-the-trace-leaves-as-otlp.md)).
//!
//! ```
//! traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
//!              ^^ ^^^^^^^^^^^^^^^^ trace id ^^^^^^^ ^^^ span id ^^^^ ^^ flags
//! ```
//!
//! Here because two layers need it and neither may name the other (ADR 057):
//! the server reads the header on the way in, and `nilo_fetch`, a Fitting
//! that cannot import `nilo_http`, writes it on the way out. What the two
//! share is this file and the Scope declarations below, and nothing about
//! where a span is kept or how it is sent; that is the server's.
//!
//! **Strict where the specification is.** Lowercase hex only, ids that are
//! not all zero, version `ff` refused, and a version `00` header exactly 55
//! bytes long. A header that fails any of these is treated as absent, which
//! is what the specification asks: the request starts a trace of its own
//! rather than joining one somebody spelled wrong. A later version is read
//! for its first 55 bytes, which the specification guarantees keep this shape.

const std = @import("std");

/// The request header that carries a trace into a server and out of a call.
pub const header = "traceparent";

/// The vendor half, forwarded as it came and never read.
pub const state_header = "tracestate";

/// How long a `traceparent` this file writes is.
pub const text_len = 55;

/// Where one piece of work sits in a trace: the trace it belongs to, the span
/// that is doing it, and whether the trace is being recorded.
pub const Context = struct {
    trace_id: [16]u8,
    span_id: [8]u8,
    sampled: bool,

    /// The context a `traceparent` names, or null for one the specification
    /// says to ignore.
    pub fn parse(text: []const u8) ?Context {
        if (text.len < text_len) return null;
        const version = hexByte(text[0..2]) orelse return null;
        if (version == 0xff) return null;
        if (version == 0x00 and text.len != text_len) return null;
        if (text.len > text_len and text[text_len] != '-') return null;
        if (text[2] != '-' or text[35] != '-' or text[52] != '-') return null;

        var out: Context = .{ .trace_id = undefined, .span_id = undefined, .sampled = false };
        if (!hexInto(text[3..35], &out.trace_id)) return null;
        if (!hexInto(text[36..52], &out.span_id)) return null;
        const flags = hexByte(text[53..55]) orelse return null;
        if (allZero(&out.trace_id) or allZero(&out.span_id)) return null;
        out.sampled = flags & 0x01 != 0;
        return out;
    }

    /// The `traceparent` that names this context, in `buf`.
    pub fn format(self: Context, buf: *[text_len]u8) []const u8 {
        buf[0..3].* = "00-".*;
        writeHex(&self.trace_id, buf[3..35]);
        buf[35] = '-';
        writeHex(&self.span_id, buf[36..52]);
        buf[52] = '-';
        buf[53..55].* = if (self.sampled) "01".* else "00".*;
        return buf;
    }
};

/// A call about to leave under a Scope that traces: the context its
/// `traceparent` carries, whose span id is the call's own, and what the Scope
/// needs back to record the call once it ends.
///
/// A Scope that traces declares `traceBegin(self) ?Outbound` and
/// `traceEnd(self, Outbound, Ended) void`; `nilo_fetch` asks the first before
/// a call and tells the second after it, and a Scope that declares neither is
/// not asked (`traceBeginOf` in `scope.zig`).
pub const Outbound = struct {
    context: Context,
    /// The span the call was made under.
    parent: [8]u8,
    started_us: i64,
    started_mono_us: i64,
    /// The `tracestate` the request arrived with, forwarded as it came. Empty
    /// when it had none. Borrowed from the request, so valid while it is.
    state: []const u8 = "",
};

/// How a call ended, for the span `traceEnd` records.
pub const Ended = struct {
    /// The method's name, `"GET"`.
    method: []const u8,
    /// The URL the call was given, the one a redirect started from. The
    /// Scope reads the host and port off it, so a caller that does not trace
    /// parses nothing. Borrowed for the length of `traceEnd`.
    url: []const u8,
    /// The status the other side answered, or 0 when it never did.
    status: u16,
    /// The error the call failed with, by name, when it failed.
    failure: ?[]const u8 = null,
};

fn hexByte(two: *const [2]u8) ?u8 {
    const hi = nibble(two[0]) orelse return null;
    const lo = nibble(two[1]) orelse return null;
    return hi << 4 | lo;
}

fn nibble(ch: u8) ?u8 {
    return switch (ch) {
        '0'...'9' => ch - '0',
        'a'...'f' => ch - 'a' + 10,
        else => null,
    };
}

fn hexInto(text: []const u8, out: []u8) bool {
    std.debug.assert(text.len == out.len * 2);
    for (out, 0..) |*b, i| b.* = hexByte(text[i * 2 ..][0..2]) orelse return false;
    return true;
}

/// `bytes` as lowercase hex into `out`, which is twice as long.
pub fn writeHex(bytes: []const u8, out: []u8) void {
    std.debug.assert(out.len == bytes.len * 2);
    const digits = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        out[i * 2] = digits[b >> 4];
        out[i * 2 + 1] = digits[b & 0x0f];
    }
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |b| if (b != 0) return false;
    return true;
}

const testing = std.testing;

test "the specification's own example reads back as the context it names" {
    const text = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01";
    const ctx = Context.parse(text).?;
    try testing.expect(ctx.sampled);
    try testing.expectEqual(@as(u8, 0x4b), ctx.trace_id[0]);
    try testing.expectEqual(@as(u8, 0xb7), ctx.span_id[7]);

    var buf: [text_len]u8 = undefined;
    try testing.expectEqualStrings(text, ctx.format(&buf));
}

test "a traceparent the specification says to ignore reads as absent" {
    const bad = [_][]const u8{
        "",
        "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7", // no flags
        "00-4BF92F3577B34DA6A3CE929D0E0E4736-00f067aa0ba902b7-01", // uppercase
        "00-00000000000000000000000000000000-00f067aa0ba902b7-01", // zero trace id
        "00-4bf92f3577b34da6a3ce929d0e0e4736-0000000000000000-01", // zero span id
        "ff-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01", // version ff
        "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01-extra", // 00 is exactly 55
        "00_4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
        "00-4bf92f3577b34da6a3ce929d0e0e473g-00f067aa0ba902b7-01",
    };
    for (bad) |text| try testing.expect(Context.parse(text) == null);
}

test "a later version is read for the part every version keeps" {
    const ctx = Context.parse("01-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-00-something").?;
    try testing.expect(!ctx.sampled);
    try testing.expect(Context.parse("01-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-00x") == null);
}

test "an unsampled context is written with its flag clear" {
    const ctx: Context = .{ .trace_id = @splat(1), .span_id = @splat(2), .sampled = false };
    var buf: [text_len]u8 = undefined;
    try testing.expectEqualStrings(
        "00-01010101010101010101010101010101-0202020202020202-00",
        ctx.format(&buf),
    );
}
