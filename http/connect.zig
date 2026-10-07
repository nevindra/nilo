//! A failure told to a Connect client in the words it reads
//! ([ADR 257](../docs/adr/257-a-connect-client-is-told-its-failure-in-connect-words.md)).
//!
//! A Connect client calls a unary method as a POST whose body is the message,
//! in JSON or protobuf, and says so with `Connect-Protocol-Version: 1`; ADR 256
//! already answers it in the spelling it sent. What it reads from a failure is
//! `{"code":"not_found","message":"…"}`, with the code one of the seventeen
//! gRPC has, by name. So a request carrying that header is answered with that
//! body, its code from the error first and the status otherwise, the table
//! the gRPC listener reads (`code.zig`), and its message the sentence nilo
//! would have sent. The status is the one nilo chose, which a Connect client
//! reads only when the body is not one of these, and which middleware,
//! counters and the logger have already seen.
//!
//! **Only in a program that has a message route.** The first route reading
//! or answering a message hands the App `pick`; until then the
//! pointer is null and nothing here is linked, so a program with no message
//! pays a null check on its failure path and no more. A path no route
//! answers, asked by a Connect client of a program that has one, is a
//! `not_found` in the same shape.

const std = @import("std");
const json = @import("json.zig");
const codes = @import("code.zig");
const message = @import("message.zig");
const failurebody = @import("failurebody.zig");

/// Whether the request is a Connect call: it carries the protocol's version
/// header, at the one version there is.
pub fn asked(head: []const u8) bool {
    const version = message.fieldIn(head, "connect-protocol-version") orelse return false;
    return std.mem.eql(u8, version, "1");
}

/// Connect's error body for a request that asked for it, and null for every
/// other request, whose failure keeps the shape the App has (ADR 024).
/// An error in `code.by_error` picks a writer that says its code; any other
/// leaves the code to the status.
pub fn pick(head: []const u8, err: anyerror) ?failurebody.Write {
    if (!asked(head)) return null;
    inline for (codes.by_error) |named| if (err == named.err) return &writerFor(named.code).write;
    return &writerFor(null).write;
}

/// The shape for a failure whose code is `said` when its error named one
/// and its status's otherwise: three of these, each a call into `write`.
fn writerFor(comptime said: ?u8) type {
    return struct {
        fn write(status: u16, text: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
            return writeBody(said orelse codes.forStatus(status), text, w);
        }
    };
}

/// `{"code":…,"message":…}`, written once for all three.
noinline fn writeBody(code: u8, text: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll("{\"code\":\"");
    try w.writeAll(codes.names[code]);
    try w.writeAll("\",\"message\":");
    // A stranger's bytes can be in it, as in nilo's own shape.
    try json.writeLossyString(w, text);
    try w.writeByte('}');
}

// ---- tests ----

const testing = std.testing;

test "a request is a Connect call when it says version 1, and not otherwise" {
    try testing.expect(asked("POST /x HTTP/1.1\r\nConnect-Protocol-Version: 1\r\n\r\n"));
    try testing.expect(asked("\ncontent-type: application/proto\r\nconnect-protocol-version:1\r\n\r\n"));
    try testing.expect(!asked("POST /x HTTP/1.1\r\nConnect-Protocol-Version: 2\r\n\r\n"));
    try testing.expect(!asked("POST /x HTTP/1.1\r\nContent-Type: application/json\r\n\r\n"));
}

test "a Connect failure names its code from the error before the status" {
    const head = "POST /x HTTP/1.1\r\nConnect-Protocol-Version: 1\r\n\r\n";
    const write = pick(head, error.AlreadyExists).?;
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try write(409, "that name is taken", &w);
    try testing.expectEqualStrings("{\"code\":\"already_exists\",\"message\":\"that name is taken\"}", w.buffered());

    w = .fixed(&buf);
    try pick(head, error.Failed).?(404, "no user 7", &w);
    try testing.expectEqualStrings("{\"code\":\"not_found\",\"message\":\"no user 7\"}", w.buffered());

    w = .fixed(&buf);
    try pick(head, error.RolledBack).?(503, "try again", &w);
    try testing.expectEqualStrings("{\"code\":\"aborted\",\"message\":\"try again\"}", w.buffered());

    // Every error that names a code is told it, whatever its status.
    inline for (codes.by_error) |named| {
        w = .fixed(&buf);
        try pick(head, named.err).?(500, "m", &w);
        try testing.expect(std.mem.indexOf(u8, w.buffered(), codes.names[named.code]) != null);
    }

    try testing.expectEqual(null, pick("POST /x HTTP/1.1\r\n\r\n", error.Failed));
}
