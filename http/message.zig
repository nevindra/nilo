//! What a request body is read as, when it is not nilo's JSON
//! (ADR 256, the way in that ADR 157 is the way out).
//!
//! ```zig
//! const SumRequest = struct {
//!     pub const wire = .{ .a = 1, .b = 2 };
//!     a: i32 = 0,
//!     b: i32 = 0,
//! };
//! const SumReply = struct {
//!     pub const wire = .{ .total = 1 };
//!     total: i32 = 0,
//! };
//!
//! fn getSum(in: SumRequest) SumReply { return .{ .total = in.a + in.b }; }
//! ```
//!
//! **Two ways a type says it.** A struct with a `wire` table is a protobuf
//! message ([ADR 245](../docs/adr/245-protobuf-is-read-from-the-struct-that-declares-it.md)),
//! and the request says which of its two spellings it was sent in: JSON
//! under `application/json`, protobuf under `application/proto` or any of
//! the names gRPC and older clients give it. **The answer goes back in the
//! spelling the request came in**, which is Connect's rule and the one that
//! lets one function be a JSON route, a protobuf route and a gRPC method at
//! once. Any other type that knows its own bytes declares
//! `nilo_content_type` and `nilo_decode`, the mirror of ADR 157's
//! `nilo_write`, and is read only when it arrives under that label: nilo
//! brings the door and the caller brings the codec.
//!
//! **Not negotiation.** `Accept` is not read (ADR 157 says why); the request's
//! own `Content-Type` already says what the client speaks, and a client that
//! sent protobuf reads protobuf.
//!
//! Nothing here names a `Ctx`: it is handed the request's content type and
//! its body, and answers with a value or a Failure, so `typed.zig` holds the
//! request and this file holds the rule.

const std = @import("std");
const proto = @import("nilo_proto");

const fail = @import("fail.zig");
const naming = @import("names.zig");
const versioned = @import("versioned.zig");

/// The two spellings of a message, protobuf in two envelopes; `unread` is a
/// request nothing has asked yet.
pub const Codec = enum {
    unread,
    json,
    /// Protobuf under Connect's name or an older one.
    proto,
    /// Protobuf in a gRPC call, its length prefix already taken off by the
    /// listener (ADR 220), and answered as `application/grpc`.
    grpc,

    /// Whether the body is protobuf, in either envelope.
    pub fn isProto(self: Codec) bool {
        return self == .proto or self == .grpc;
    }
};

/// Whether `T` is a protobuf message: a struct with a `wire` table, the test
/// `nilo_proto` itself reads a message by.
pub fn isMessage(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "wire");
}

/// Whether `T` reads its own body: it carries `nilo_decode`. A type carrying
/// it with no content type, or the pair written wrong, is caught by `check`.
pub fn decodesItsOwnBody(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, "nilo_decode"),
        else => false,
    };
}

/// The media type of a `Content-Type` value: what is before the first `;`,
/// without the spaces around it. Compared without regard to case by every
/// caller, as RFC 9110 §8.3.1 has it.
pub fn mediaType(content_type: []const u8) []const u8 {
    // A byte at a time: a content type is a few dozen bytes, and the
    // vectorised search is larger than the loop it would save.
    var end: usize = 0;
    while (end < content_type.len and content_type[end] != ';') end += 1;
    var start: usize = 0;
    while (start < end and (content_type[start] == ' ' or content_type[start] == '\t')) start += 1;
    while (end > start and (content_type[end - 1] == ' ' or content_type[end - 1] == '\t')) end -= 1;
    return content_type[start..end];
}

/// Whether a handler of type `Fn` reads or answers a message: an argument
/// with a `wire` table, or one returned, under an error union, a
/// `nilo_response`, a `Versioned` and an optional, the order `typed.zig`
/// unwraps an answer in. What gives a handler's wrapper a spelling to keep
/// (ADR 256), an App Connect's failure body (ADR 257) and a struct its
/// methods (ADR 258).
pub fn speaks(comptime Fn: type) bool {
    comptime {
        for (@typeInfo(Fn).@"fn".params) |p| if (p.type) |P| if (isMessage(P)) return true;
        const Returned = @typeInfo(Fn).@"fn".return_type orelse return false;
        var V = switch (@typeInfo(Returned)) {
            .error_union => |u| u.payload,
            else => Returned,
        };
        if (hasDeclOn(V, "nilo_response")) V = V.nilo_response;
        if (versioned.isVersioned(V)) V = V.nilo_versioned;
        if (@typeInfo(V) == .optional) V = @typeInfo(V).optional.child;
        return isMessage(V);
    }
}

fn hasDeclOn(comptime T: type, comptime name: []const u8) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, name),
        else => false,
    };
}

/// The value of the first `Content-Type` in a request head, `Ctx.header`'s
/// answer for it, read a byte at a time and looking at a line's name only
/// when the byte after it is the colon. `head` is a request line and its
/// fields, or a field block whose request line is empty (ADR 253).
///
/// Its own scan rather than `Ctx.header`, because a route reading a message
/// in JSON pays it on every request: 412 to 416ns a request with it against
/// 427 to 430 through the general one, where a plain struct is 365 (ADR 256).
pub fn contentTypeIn(head: []const u8) ?[]const u8 {
    return fieldIn(head, "content-type");
}

/// The value of the first field called `name`, lowercase, in a request head
/// or an HTTP/2 call's field block; `contentTypeIn`'s scan for any name, so
/// Connect's version header is read the same way (ADR 257).
pub fn fieldIn(head: []const u8, comptime name: []const u8) ?[]const u8 {
    var at: usize = 0;
    while (at < head.len and head[at] != '\n') at += 1;
    at += 1;
    while (at + name.len + 1 <= head.len) {
        if (head[at] == '\r' or head[at] == '\n') return null;
        if (head[at + name.len] == ':' and is(head[at .. at + name.len], name)) {
            var end = at + name.len + 1;
            while (end < head.len and head[end] != '\n') end += 1;
            return std.mem.trim(u8, head[at + name.len + 1 .. end], " \t\r");
        }
        while (at < head.len and head[at] != '\n') at += 1;
        at += 1;
    }
    return null;
}

/// Which spelling of a message a request's `Content-Type` names. Protobuf
/// only under one of its names; anything else is JSON, the way every other
/// struct is read whatever its label, so `curl -d` (which says
/// `application/x-www-form-urlencoded`) and a `fetch` of a string (which says
/// `text/plain`) keep working against a route whose argument happens to be a
/// message. A protobuf client always names what it sends, and a 415 for the
/// rest would refuse exactly the clients that do not.
///
/// Connect's name for protobuf, the IANA one and the one older clients send
/// are the same spelling; gRPC's two are protobuf whose length prefix the
/// listener has already taken off (ADR 220).
///
/// **Written for its size, not with `eqlIgnoreCase`**: a loop of those was
/// 4 KB, each compare vectorised, where this switch on the length and a byte
/// at a time, the letters folded and the rest compared exactly, is under one
/// (ADR 256).
pub fn codecOf(content_type: ?[]const u8) Codec {
    const m = mediaType(content_type orelse return .json);
    if (m.len < 16 or !is(m[0..12], "application/")) return .json;
    const rest = m[12..];
    return switch (rest.len) {
        4 => if (is(rest, "grpc")) .grpc else .json,
        5 => if (is(rest, "proto")) .proto else .json,
        8 => if (is(rest, "protobuf")) .proto else .json,
        10 => if (is(rest, "x-protobuf")) .proto else if (is(rest, "grpc+proto")) .grpc else .json,
        else => .json,
    };
}

/// `got` against the lowercase `want`, ignoring case where `want` has a
/// letter and comparing exactly where it does not, unrolled while compiling.
inline fn is(got: []const u8, comptime want: []const u8) bool {
    if (got.len != want.len) return false;
    inline for (want, 0..) |w, i| {
        const g = if (comptime std.ascii.isAlphabetic(w)) got[i] | 0x20 else got[i];
        if (g != w) return false;
    }
    return true;
}

/// The label an answer in `codec` goes out under: a gRPC call is answered
/// as `application/grpc`, and every other request that sent protobuf under
/// Connect's name for it.
pub fn answerType(codec: Codec) []const u8 {
    return switch (codec) {
        .grpc => "application/grpc",
        .proto => "application/proto",
        .unread, .json => "application/json",
    };
}

/// Read a message from `body` as protobuf. A message that does not decode is
/// a 400 naming the type and what was wrong with the bytes; the strings in
/// it borrow `body`, which lives as long as the request.
pub fn decodeProto(comptime T: type, arena: std.mem.Allocator, body: []const u8) !T {
    return proto.decode(T, arena, body) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => fail.badRequest("the request body is not a protobuf {s}: {s}", .{ comptime naming.of(T), describe(err) }),
    };
}

fn describe(err: proto.Error) []const u8 {
    return switch (err) {
        error.Truncated => "it ends in the middle of a field",
        error.VarintTooLong => "a number in it runs past ten bytes",
        error.InvalidKey => "a field key in it is not one protobuf can have",
        error.WrongWireType => "a field in it arrived as a different kind of value than its type",
        error.InvalidUtf8 => "a string field in it is not UTF-8",
        error.TooDeep => "its messages nest deeper than nilo reads",
        error.UnexpectedEndGroup => "a group in it ends that never started",
        error.OutOfMemory => "it is too large to hold",
    };
}

/// Read a type that declares its own bytes, if it arrived under its label:
/// a 415 otherwise, and a 400 naming the error `nilo_decode` returned.
pub fn decodeOwn(comptime T: type, arena: std.mem.Allocator, content_type: ?[]const u8, body: []const u8) !T {
    const want = mediaType(T.nilo_content_type);
    const given = content_type orelse return fail.status(
        415,
        "this endpoint reads {s}, and this request said nothing about what its body is",
        .{want},
    );
    if (!std.ascii.eqlIgnoreCase(mediaType(given), want)) return fail.status(
        415,
        "this endpoint reads {s} — this request's body arrived as \"{s}\"",
        .{ want, given },
    );
    return T.nilo_decode(body, arena) catch |err| {
        // Out of memory is the server's, not the client's; a fail function's
        // sentence is the decoder's own and stays; anything else is the
        // decoder saying why these bytes are not one.
        switch (@as(anyerror, err)) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Failed => return error.Failed,
            else => {},
        }
        return fail.badRequest("the request body is not a valid {s}: {s}", .{ want, @errorName(err) });
    };
}

/// Everything that can be wrong with a type read as a body, said at the
/// route that reads it.
pub fn check(comptime pattern: []const u8, comptime T: type) void {
    comptime {
        if (!decodesItsOwnBody(T)) return;
        if (!@hasDecl(T, "nilo_content_type")) @compileError(
            "nilo: the request body on route \"" ++ pattern ++ "\" is a " ++ naming.of(T) ++
                ", which has a `nilo_decode` and no `nilo_content_type`.\n" ++
                "  A body is read by its own decoder only when it arrives under the type's " ++
                "label, and nilo will not guess one. Add " ++
                "`pub const nilo_content_type = \"application/msgpack\";` — or whatever it reads.",
        );
        if (isMessage(T)) @compileError(
            "nilo: the request body on route \"" ++ pattern ++ "\" is a " ++ naming.of(T) ++
                ", which has both a `wire` table and a `nilo_decode`, so it says two things about " ++
                "how its bytes are read.\n" ++
                "  A `wire` table is read as protobuf or JSON by the request's content type; " ++
                "`nilo_decode` reads one label of the type's own. Keep one.",
        );
        const ct = T.nilo_content_type;
        const is_text = switch (@typeInfo(@TypeOf(ct))) {
            .pointer => |p| p.size == .slice and p.child == u8 or
                (p.size == .one and @typeInfo(p.child) == .array and @typeInfo(p.child).array.child == u8),
            else => false,
        };
        if (!is_text or mediaType(ct).len == 0) @compileError(
            "nilo: " ++ naming.of(T) ++ "'s `nilo_content_type` has to name the media type its " ++
                "body is read from, and it does not.\n" ++
                "  Write `pub const nilo_content_type = \"application/msgpack\";`.",
        );
        const D = @TypeOf(T.nilo_decode);
        const fits = switch (@typeInfo(D)) {
            .@"fn" => |f| f.params.len == 2 and
                f.params[0].type == []const u8 and
                f.params[1].type == std.mem.Allocator and
                f.return_type != null and
                switch (@typeInfo(f.return_type.?)) {
                    .error_union => |eu| eu.payload == T,
                    else => false,
                },
            else => false,
        };
        if (!fits) @compileError(
            "nilo: " ++ naming.of(T) ++ "'s `nilo_decode` is not `fn (body: []const u8, arena: " ++
                "std.mem.Allocator) !" ++ naming.of(T) ++ "`.\n" ++
                "  It is handed the whole body and the request arena, and returns the value or the " ++
                "error that says why the bytes are not one; the bytes live as long as the request.",
        );
    }
}

/// A route whose body is a message answers in the spelling it was asked in,
/// so its answer has to have both: a message, or nothing at all. Anything
/// else would answer a protobuf client in JSON.
pub fn checkAnswer(comptime pattern: []const u8, comptime Body: type, comptime Answer: type) void {
    comptime {
        if (!isMessage(Body)) return;
        if (Answer == void or isMessage(Answer)) return;
        @compileError(
            "nilo: the handler for route \"" ++ pattern ++ "\" reads a protobuf message (" ++
                naming.of(Body) ++ ") and answers with a " ++ naming.of(Answer) ++ ", which is not one.\n" ++
                "  A client that sent protobuf reads the answer as protobuf, so the answer of a route " ++
                "whose body is a message is a message too: a struct with a `wire` table, or nothing.",
        );
    }
}

// ---- tests ----

const testing = std.testing;

test "a request's content type names protobuf, and anything else, none included, is JSON" {
    try testing.expectEqual(Codec.json, codecOf(null));
    try testing.expectEqual(Codec.json, codecOf("application/json; charset=utf-8"));
    try testing.expectEqual(Codec.proto, codecOf("application/proto"));
    try testing.expectEqual(Codec.proto, codecOf("Application/X-Protobuf"));
    try testing.expectEqual(Codec.grpc, codecOf("application/grpc+proto"));
    try testing.expectEqual(Codec.json, codecOf("application/grpc+json"));
    try testing.expectEqual(Codec.json, codecOf("text/plain"));
    try testing.expectEqual(Codec.json, codecOf("application/x-www-form-urlencoded"));
    try testing.expectEqual(Codec.proto, codecOf(" application/protobuf ; x=1"));
    try testing.expectEqual(Codec.grpc, codecOf("APPLICATION/GRPC"));
    try testing.expectEqual(Codec.json, codecOf("application/jsonx"));
    try testing.expectEqual(Codec.json, codecOf("application\x0fjson"));
    try testing.expectEqual(Codec.json, codecOf(""));
}

test "the first Content-Type in a head is found whatever its case, and a name that only starts like it is not" {
    const head = "POST /sum HTTP/1.1\r\nHost: t\r\nX-Content-Type: no\r\nCONTENT-TYPE:  application/proto \r\ncontent-type: application/json\r\n\r\n";
    try testing.expectEqualStrings("application/proto", contentTypeIn(head).?);
    // A field block, its request line empty, the way an HTTP/2 call's is.
    try testing.expectEqualStrings("application/grpc", contentTypeIn("\nhost: t\r\ncontent-type: application/grpc\r\n\r\n").?);
    try testing.expectEqual(null, contentTypeIn("GET / HTTP/1.1\r\nHost: t\r\n\r\n"));
    // The blank line ends the head; a body that looks like a field is not one.
    try testing.expectEqual(null, contentTypeIn("POST / HTTP/1.1\r\nHost: t\r\n\r\nContent-Type: x\r\n"));
    try testing.expectEqual(null, contentTypeIn(""));
}

test "an answer in protobuf goes out under gRPC's name to a gRPC call and Connect's to the rest" {
    try testing.expectEqualStrings("application/grpc", answerType(codecOf("application/grpc")));
    try testing.expectEqualStrings("application/proto", answerType(codecOf("application/x-protobuf")));
    try testing.expectEqualStrings("application/json", answerType(codecOf(null)));
}

test "a type is a message by its wire table, and reads its own body by nilo_decode" {
    const M = struct {
        pub const wire = .{ .a = 1 };
        a: i32 = 0,
    };
    const Own = struct {
        n: u8,
        pub const nilo_content_type = "application/x-one";
        pub fn nilo_decode(body: []const u8, _: std.mem.Allocator) !@This() {
            if (body.len != 1) return error.NotOneByte;
            return .{ .n = body[0] };
        }
    };
    try testing.expect(isMessage(M));
    try testing.expect(!isMessage(Own));
    try testing.expect(decodesItsOwnBody(Own));
    try testing.expect(!decodesItsOwnBody(M));
}
