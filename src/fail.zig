//! Fail functions — stop a request with a given status and message, from
//! anywhere, without having to hold a Ctx (ADR 0005).
//!
//! ```zig
//! fn getUser(db: *Db, id: u32) !User {
//!     return db.find(id) orelse fail.notFound("no user {d}", .{id});
//! }
//! ```
//!
//! How it works: the message is written into the Failure belonging to the
//! request currently running, and `error.Failed` is returned. The App that
//! called the handler reads that Failure and assembles the response.
//!
//! The Failure is found through the Bulkhead's slot, which is bound to the
//! fiber — not to the thread — so two requests taking turns on one thread
//! can never overwrite each other's message (ADR 0007). Called outside a
//! request there is no Failure, and a fail function just returns a plain
//! error with no message; handlers stay testable as ordinary functions.

const std = @import("std");
const bulkhead = @import("bulkhead.zig");

/// Messages longer than this are truncated. The Failure is deliberately a
/// fixed buffer rather than an allocation from the request arena: the
/// failure path must not have a failure path of its own, and fail
/// functions have to keep working when called outside a request.
pub const max_message = 240;

pub const Error = error{Failed};

/// Where a fail function's message lives for one request. App keeps one
/// per connection and clears it at the start of every request.
pub const Failure = struct {
    status: u16 = 0,
    n: usize = 0,
    buf: [max_message]u8 = undefined,

    pub fn clear(self: *Failure) void {
        self.status = 0;
        self.n = 0;
    }

    pub fn isSet(self: *const Failure) bool {
        return self.status != 0;
    }

    pub fn message(self: *const Failure) []const u8 {
        return self.buf[0..self.n];
    }

    pub fn set(self: *Failure, code: u16, comptime fmt: []const u8, args: anytype) void {
        self.status = code;
        var w = std.Io.Writer.fixed(&self.buf);
        // An over-long message is truncated rather than dropped: half a
        // message is still far more use than a 500 with no explanation.
        w.print(fmt, args) catch {};
        self.n = w.end;
    }
};

/// The Failure belonging to the request currently running, or null when
/// there is no request.
pub fn current() ?*Failure {
    const p = bulkhead.slot() orelse return null;
    return @ptrCast(@alignCast(p));
}

/// Stop the request with any status.
pub fn status(code: u16, comptime fmt: []const u8, args: anytype) Error {
    if (current()) |f| f.set(code, fmt, args);
    return error.Failed;
}

pub fn badRequest(comptime fmt: []const u8, args: anytype) Error {
    return status(400, fmt, args);
}

pub fn unauthorized(comptime fmt: []const u8, args: anytype) Error {
    return status(401, fmt, args);
}

pub fn forbidden(comptime fmt: []const u8, args: anytype) Error {
    return status(403, fmt, args);
}

pub fn notFound(comptime fmt: []const u8, args: anytype) Error {
    return status(404, fmt, args);
}

pub fn conflict(comptime fmt: []const u8, args: anytype) Error {
    return status(409, fmt, args);
}

pub fn unprocessable(comptime fmt: []const u8, args: anytype) Error {
    return status(422, fmt, args);
}

pub fn tooManyRequests(comptime fmt: []const u8, args: anytype) Error {
    return status(429, fmt, args);
}

/// A 500 with a message. The message is sent to the client, so do not put
/// anything in it that outsiders should not see.
pub fn internal(comptime fmt: []const u8, args: anytype) Error {
    return status(500, fmt, args);
}

/// Ordinary Zig errors coming from anywhere — a database, a parser, an
/// allocator — are mapped through this table. Anything unrecognised
/// becomes a 500 and is logged with its error name (ADR 0005).
pub fn statusFor(err: anyerror) u16 {
    return switch (err) {
        error.Failed => 500, // should already have been handled via the Failure

        error.NotFound, error.FileNotFound => 404,

        error.InvalidCharacter,
        error.Overflow,
        error.InvalidNumber,
        error.SyntaxError,
        error.UnexpectedToken,
        error.UnexpectedEndOfInput,
        error.InvalidEnumTag,
        error.MissingField,
        error.UnknownField,
        error.DuplicateField,
        error.LengthMismatch,
        => 400,

        error.Unauthorized => 401,
        error.Forbidden => 403,
        error.Conflict => 409,
        error.BodyTooLarge => 413,
        error.ChunkedNotSupported => 501,
        error.Timeout, error.Canceled => 503,

        else => 500,
    };
}

// ---- tests ----

const testing = std.testing;

/// Fail functions return a bare error value so they can be used as
/// `orelse fail.notFound(...)`; tests wrap that into an error union first.
fn asUnion(e: Error) Error!void {
    return e;
}

test "with no Failure, a fail function is just a plain error" {
    const previous = bulkhead.setFallbackSlot(null);
    defer _ = bulkhead.setFallbackSlot(previous);

    try testing.expectError(error.Failed, asUnion(notFound("no user {d}", .{7})));
}

test "with a Failure, the message and status are stored" {
    var failure = Failure{};
    const previous = bulkhead.setFallbackSlot(&failure);
    defer _ = bulkhead.setFallbackSlot(previous);

    try testing.expectError(error.Failed, asUnion(notFound("no user {d}", .{7})));
    try testing.expect(failure.isSet());
    try testing.expectEqual(@as(u16, 404), failure.status);
    try testing.expectEqualStrings("no user 7", failure.message());

    failure.clear();
    try testing.expect(!failure.isSet());
    try testing.expectEqualStrings("", failure.message());
}

test "an over-long message is truncated, not dropped" {
    var failure = Failure{};
    const previous = bulkhead.setFallbackSlot(&failure);
    defer _ = bulkhead.setFallbackSlot(previous);

    try testing.expectError(error.Failed, asUnion(badRequest("{s}", .{"x" ** (max_message * 2)})));
    try testing.expectEqual(@as(u16, 400), failure.status);
    try testing.expect(failure.message().len <= max_message);
}

test "the error mapping table" {
    try testing.expectEqual(@as(u16, 404), statusFor(error.NotFound));
    try testing.expectEqual(@as(u16, 400), statusFor(error.InvalidCharacter));
    try testing.expectEqual(@as(u16, 413), statusFor(error.BodyTooLarge));
    try testing.expectEqual(@as(u16, 500), statusFor(error.SomethingUnrecognised));
}
