//! The gRPC envelope: what a unary call's message and metadata mean on top of
//! an HTTP/2 stream, and nothing about the stream itself
//! ([ADR 220](../docs/adr/220-grpc-is-served-over-h2c-behind-a-flag.md),
//! [ADR 259](../docs/adr/259-http2-is-a-framing-of-every-request.md)).
//!
//! **A gRPC method is an ordinary route.** `POST /package.Service/Method`,
//! registered with `app.post`. What is here is the part of a call that is
//! gRPC's and not HTTP/2's: the content type that makes a request a call,
//! `grpc-timeout`, the five-byte prefix and `grpc-encoding` of the one
//! message, and what the route answers turned back into HEADERS, a prefixed
//! message and trailers carrying `grpc-status` (Trailers-Only for a call
//! that failed). A route that fails with a status is a call that fails with
//! the gRPC code that status means.
//!
//! **This file never names the connection.** `h2conn.zig` imports it and
//! hands it fields and bytes, and it hands back values (`Envelope`, `Reply`,
//! `Refusal`), which is what lets another envelope (Connect, ADR 257) sit
//! beside it over the same connection and lets `zig test` run the rules
//! without a stream in the way.

const std = @import("std");
const hpack = @import("hpack.zig");
const h2 = @import("h2.zig");
const bulkhead = @import("bulkhead.zig");
const encoded = @import("encoded.zig");
const framing = @import("framing.zig");
const codes = @import("code.zig");

/// `grpc-timeout`: at most eight digits and one unit, `H`, `M`, `S`, `m`,
/// `u` or `n` (gRPC over HTTP/2, "Requests"). Null for anything else.
pub fn timeoutNanos(text: []const u8) ?u64 {
    if (text.len < 2 or text.len > 9) return null;
    const digits = text[0 .. text.len - 1];
    for (digits) |ch| if (ch < '0' or ch > '9') return null;
    const n = std.fmt.parseInt(u64, digits, 10) catch return null;
    const unit: u64 = switch (text[text.len - 1]) {
        'H' => std.time.ns_per_hour,
        'M' => std.time.ns_per_min,
        'S' => std.time.ns_per_s,
        'm' => std.time.ns_per_ms,
        'u' => std.time.ns_per_us,
        'n' => 1,
        else => return null,
    };
    return n *| unit;
}
/// `application/grpc`, or `application/grpc+` and a subtype (gRPC over
/// HTTP/2, "Requests"). A prefix match took `application/grpc-web`, which is
/// a different protocol on the wire, for a native call.
pub fn isGrpcContentType(value: []const u8) bool {
    const media = "application/grpc";
    if (!std.ascii.startsWithIgnoreCase(value, media)) return false;
    const rest = value[media.len..];
    return rest.len == 0 or (rest[0] == '+' and rest.len > 1);
}
/// The message with its five-byte prefix, written into the room the
/// collector left in front of it, so the answer is held once (ADR 220).
/// Copied only when there is no such room, which an answer with no body
/// handed over has not.
pub fn prefixed(a: std.mem.Allocator, collected: *const framing.Collected) ![]const u8 {
    const message = collected.body;
    if (collected.room.len != 5 + message.len) return framed(a, message);
    const data = collected.room;
    data[0] = 0;
    std.mem.writeInt(u32, data[1..5], @intCast(message.len), .big);
    return data;
}
/// The message with its five-byte prefix: uncompressed, and its length.
pub fn framed(a: std.mem.Allocator, message: []const u8) ![]const u8 {
    const data = try a.alloc(u8, 5 + message.len);
    data[0] = 0;
    std.mem.writeInt(u32, data[1..5], @intCast(message.len), .big);
    @memcpy(data[5..], message);
    return data;
}
/// The two blocks nearly every call is answered with, as `encodeBlock` would
/// write them: `:status 200` from the static table and `content-type` as a
/// literal with the static table's name, then `grpc-status 0`. Constant, so
/// an ordinary call encodes nothing. A test holds them to `encodeBlock`.
pub const ok_head = "\x88\x0f\x10\x10application/grpc";
pub const ok_trailers = "\x00\x0bgrpc-status\x010";
/// What the route said with `c.setTrailer("grpc-status", …)` and
/// `"grpc-message"`, for a code no failure of nilo's names.
pub const Said = struct {
    code: ?u8 = null,
    message: ?[]const u8 = null,
};
pub fn statusSaid(trailers: []const framing.Header) Said {
    var said: Said = .{};
    for (trailers) |t| {
        if (std.mem.eql(u8, t.name, "grpc-status")) {
            said.code = std.fmt.parseInt(u8, t.value, 10) catch 2; // UNKNOWN
        } else if (std.mem.eql(u8, t.name, "grpc-message")) {
            said.message = t.value;
        }
    }
    return said;
}
/// The route's trailers other than the two gRPC writes itself, which go out
/// once, in the place it puts them.
pub fn ownTrailers(a: std.mem.Allocator, trailers: []const framing.Header) ![]const hpack.Field {
    var kept: std.ArrayList(hpack.Field) = .empty;
    for (trailers) |t| {
        if (std.mem.eql(u8, t.name, "grpc-status") or std.mem.eql(u8, t.name, "grpc-message")) continue;
        try kept.append(a, .{ .name = t.name, .value = t.value });
    }
    return kept.items;
}
/// What a failed route said, for `grpc-message`: the sentence of the failure
/// nilo answered for it, or, for a route that sent its own error status, its
/// body when that is short text, or nothing.
pub fn failureMessage(collected: *const framing.Collected) []const u8 {
    if (collected.failure != null) return collected.message;
    if (std.mem.startsWith(u8, collected.content_type, "text/plain") and collected.body.len <= 1024) return collected.body;
    return "";
}
/// What goes out as `grpc-message`, and whose words it is. nilo's own text
/// is plain and is encoded whole; a route that set the header itself set
/// what goes on the wire, already encoded, and only what could not be sent
/// as it is gets encoded.
pub const Message = union(enum) {
    ours: []const u8,
    routes: []const u8,
};
/// One HEADERS block carrying a whole failed call: the status, the content
/// type, `grpc-status` and `grpc-message`.
pub fn trailersOnly(a: std.mem.Allocator, code: u8, message: Message) ![]const u8 {
    return trailersOnlyWith(a, code, message, &.{});
}
pub fn trailersOnlyWith(a: std.mem.Allocator, code: u8, message: Message, extra: []const hpack.Field) ![]const u8 {
    var code_text: [3]u8 = undefined;
    const code_str = std.fmt.bufPrint(&code_text, "{d}", .{code}) catch unreachable;
    var fields: std.ArrayList(hpack.Field) = .empty;
    try fields.append(a, .{ .name = ":status", .value = "200" });
    try fields.append(a, .{ .name = "content-type", .value = "application/grpc" });
    try fields.append(a, .{ .name = "grpc-status", .value = try a.dupe(u8, code_str) });
    const text, const encoded_already = switch (message) {
        .ours => |t| .{ t, false },
        .routes => |t| .{ t, true },
    };
    if (text.len != 0) try fields.append(a, .{ .name = "grpc-message", .value = try percentEncoded(a, text, encoded_already) });
    try fields.appendSlice(a, extra);
    return hpack.encodeBlock(a, fields.items);
}
/// `grpc-message` is percent-encoded: everything outside printable ASCII,
/// and `%` itself (gRPC over HTTP/2, "Responses"). With `encoded_already`, a
/// `%` that starts a well-formed escape is kept as the escape it is, so a
/// route's `caf%C3%A9` reaches the client as `café` and not as the text
/// `caf%C3%A9`.
pub fn percentEncoded(a: std.mem.Allocator, text: []const u8, encoded_already: bool) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (text, 0..) |ch, i| {
        const escape = encoded_already and ch == '%' and i + 2 < text.len and
            std.ascii.isHex(text[i + 1]) and std.ascii.isHex(text[i + 2]);
        if (!escape and (ch < 0x20 or ch > 0x7e or ch == '%')) {
            try out.print(a, "%{X:0>2}", .{ch});
        } else try out.append(a, ch);
    }
    return out.toOwnedSlice(a);
}

/// What a route's answer turned into, as the pieces an HTTP/2 connection
/// writes: the HEADERS block, the one message with its prefix, and the
/// trailers block. `trailers_only` is the whole call in `head_block`.
pub const Reply = struct {
    head_block: []const u8,
    data: []const u8 = "",
    trailers: []const u8 = "",
    trailers_only: bool = false,
};

/// A call refused before its route runs: the status code and the sentence
/// that goes out as `grpc-message`.
pub const Refusal = struct { code: u8, message: []const u8 };

pub const bad_timeout: Refusal = .{
    .code = 3,
    .message = "grpc-timeout is not a number of up to eight digits and a unit",
};

/// When the client stops waiting, from a `grpc-timeout` value and the moment
/// the call's first HEADERS frame arrived: the client's clock started when it
/// sent the call, not when its message was whole (gRPC over HTTP/2,
/// "Requests").
pub fn untilNs(text: []const u8, headers_ns: u64) error{BadTimeout}!u64 {
    const ns = timeoutNanos(text) orelse return error.BadTimeout;
    return headers_ns +| ns;
}

/// What a unary call's body is: exactly one message, a five-byte prefix (a
/// compression flag and a big-endian length) and what it says follows. The
/// message itself is `body[prefix_len..]`.
pub const prefix_len = 5;

pub const Envelope = union(enum) {
    /// Not one well-formed message, or marked compressed against what
    /// `grpc-encoding` says.
    refused: Refusal,
    /// The message as it came.
    identity,
    /// The message is gzip, which the connection inflates under its budget.
    gzip,
    /// Marked compressed in an encoding this server does not read, which is
    /// answered with `unsupportedEncoding`.
    unsupported,
};

/// Read the prefix of a call's body and the encoding it names. A message
/// marked compressed with no encoding named is the client's mistake,
/// INTERNAL; an encoding named that this server does not read is
/// UNIMPLEMENTED, with the ones it does (gRPC's compression document).
pub fn envelope(body: []const u8, encoding: ?[]const u8) Envelope {
    const one_message: Envelope = .{ .refused = .{ .code = 13, .message = "a unary call carries exactly one message" } };
    if (body.len < prefix_len) return one_message;
    const compressed = body[0];
    const len = std.mem.readInt(u32, body[1..prefix_len], .big);
    if (compressed > 1 or len != body.len - prefix_len) return one_message;
    if (compressed == 0) return .identity;
    const named = encoding orelse "identity";
    if (std.mem.eql(u8, named, "identity"))
        return .{ .refused = .{ .code = 13, .message = "the message is marked compressed and grpc-encoding names no compression" } };
    if (!std.mem.eql(u8, named, "gzip")) return .unsupported;
    return .gzip;
}

/// The Trailers-Only block for an `Envelope.unsupported` call, carrying the
/// encodings this server does read.
pub fn unsupportedEncoding(a: std.mem.Allocator) ![]const u8 {
    return trailersOnlyWith(a, 12, .{ .ours = "the message is compressed with an encoding this server does not read" }, &.{
        .{ .name = "grpc-accept-encoding", .value = "identity,gzip" },
    });
}

/// Turn what the route answered into the call's answer: HEADERS with the
/// route's headers as metadata, the body as one length-prefixed message, and
/// trailers with `grpc-status` and the route's own. A failed call, a status
/// other than 200 or a `grpc-status` the route set that is not 0, is said in
/// one HEADERS frame, Trailers-Only, carrying the route's trailers too.
pub fn fromCollected(a: std.mem.Allocator, collected: *const framing.Collected, until_ns: u64) !Reply {
    const said = statusSaid(collected.trailers);
    if (collected.status != 200 or (said.code orelse 0) != 0) {
        // A route that failed after the client's deadline failed because of
        // it, as far as the client can tell: `nilo.deadline`'s 503 and a wait
        // cut short both read as DEADLINE_EXCEEDED rather than UNAVAILABLE.
        const late = until_ns != 0 and bulkhead.monotonicNanos() >= until_ns;
        const code = said.code orelse if (late) 4 else codes.of(collected.failure, collected.status);
        const message: Message = if (said.message) |sent| .{ .routes = sent } else .{ .ours = failureMessage(collected) };
        return .{
            .head_block = try trailersOnlyWith(a, code, message, try ownTrailers(a, collected.trailers)),
            .trailers_only = true,
        };
    }

    var reply: Reply = .{ .head_block = ok_head };
    if (collected.headers.len == 0 and std.mem.eql(u8, collected.content_type, "application/grpc")) {
        // The constant block, which is `reply`'s own.
    } else {
        var head: std.ArrayList(hpack.Field) = .empty;
        try head.append(a, .{ .name = ":status", .value = "200" });
        try head.append(a, .{ .name = "content-type", .value = if (isGrpcContentType(collected.content_type)) collected.content_type else "application/grpc" });
        for (collected.headers) |f| if (!h2.hopByHop(f.name)) try head.append(a, .{ .name = f.name, .value = f.value });
        reply.head_block = try hpack.encodeBlock(a, head.items);
    }

    reply.data = try prefixed(a, collected);
    const own = try ownTrailers(a, collected.trailers);
    if (own.len == 0) {
        reply.trailers = ok_trailers;
    } else {
        var fields: std.ArrayList(hpack.Field) = .empty;
        try fields.append(a, .{ .name = "grpc-status", .value = "0" });
        try fields.appendSlice(a, own);
        reply.trailers = try hpack.encodeBlock(a, fields.items);
    }
    return reply;
}

// ---- tests ----

const testing = std.testing;

test "the constant answer blocks are what encodeBlock writes for them" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings(try hpack.encodeBlock(a, &.{
        .{ .name = ":status", .value = "200" },
        .{ .name = "content-type", .value = "application/grpc" },
    }), ok_head);
    try testing.expectEqualStrings(try hpack.encodeBlock(a, &.{.{ .name = "grpc-status", .value = "0" }}), ok_trailers);
}

test "grpc-timeout is eight digits at most and a unit, and anything else is refused" {
    try testing.expectEqual(@as(?u64, 5 * std.time.ns_per_s), timeoutNanos("5S"));
    try testing.expectEqual(@as(?u64, 250 * std.time.ns_per_ms), timeoutNanos("250m"));
    try testing.expectEqual(@as(?u64, 2 * std.time.ns_per_hour), timeoutNanos("2H"));
    try testing.expectEqual(@as(?u64, 99_999_999), timeoutNanos("99999999n"));
    try testing.expectEqual(@as(?u64, null), timeoutNanos("123456789S"));
    try testing.expectEqual(@as(?u64, null), timeoutNanos("5"));
    try testing.expectEqual(@as(?u64, null), timeoutNanos("5s"));
    try testing.expectEqual(@as(?u64, null), timeoutNanos("-5S"));
}

test "a body is one message, and anything else is refused with INTERNAL" {
    try testing.expectEqual(Envelope.identity, envelope("\x00\x00\x00\x00\x02hi", null));
    try testing.expectEqual(@as(u8, 13), envelope("\x00\x00", null).refused.code);
    try testing.expectEqual(@as(u8, 13), envelope("\x00\x00\x00\x00\x05hi", null).refused.code);
    try testing.expectEqual(@as(u8, 13), envelope("\x02\x00\x00\x00\x02hi", null).refused.code);
}

test "a compressed message is read by the encoding it names" {
    try testing.expectEqual(Envelope.gzip, envelope("\x01\x00\x00\x00\x02hi", "gzip"));
    try testing.expectEqual(Envelope.unsupported, envelope("\x01\x00\x00\x00\x02hi", "br"));
    try testing.expectEqual(@as(u8, 13), envelope("\x01\x00\x00\x00\x02hi", null).refused.code);
    try testing.expectEqual(@as(u8, 13), envelope("\x01\x00\x00\x00\x02hi", "identity").refused.code);
}

test "grpc-timeout is counted from when the headers arrived" {
    try testing.expectEqual(@as(u64, 1_000 + 5 * std.time.ns_per_s), try untilNs("5S", 1_000));
    try testing.expectError(error.BadTimeout, untilNs("5s", 1_000));
}
