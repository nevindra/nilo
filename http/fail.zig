//! Fail functions — stop a request with a given status and message, from
//! anywhere, without having to hold a Ctx (ADR 004).
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
//! can never overwrite each other's message (ADR 006). Called outside a
//! request there is no Failure, and a fail function just returns a plain
//! error with no message; handlers stay testable as ordinary functions.
//! Two places outside a request give it one anyway: `testing.Refusals`, so
//! a test can read the sentence, and the boot, so work registered with
//! `app.before` that is refused says why in the line that stops the server
//! (ADR 129).

const std = @import("std");
const bulkhead = @import("bulkhead.zig");
const watchdog = @import("watchdog.zig");

/// Messages longer than this are truncated. The Failure is deliberately a
/// fixed buffer rather than an allocation from the request arena: the
/// failure path must not have a failure path of its own, and fail
/// functions have to keep working when called outside a request.
pub const max_message = 240;

pub const Error = error{Failed};

/// Where a fail function's message lives for one request. App keeps one
/// per connection and clears it at the start of every request.
pub const Failure = struct {
    /// What a nilo compile error calls this type, which is the name the
    /// reader's own import line gives it (ADR 074).
    pub const nilo_type_name = "nilo.Failure";

    status: u16 = 0,
    /// A `u8` and not a `usize`, so that the pointer below fits in the
    /// padding this struct already had: `@sizeOf(Failure)` is 256 with or
    /// without it, and a connection holds one (ADR 153).
    n: u8 = 0,
    buf: [max_message]u8 = undefined,
    /// What a 401 says in `WWW-Authenticate`, when the failure came from
    /// an endpoint that takes an `Authorization` header (ADR 153). A
    /// comptime string, so a pointer is the whole of it.
    challenge: ?[*:0]const u8 = null,

    pub fn clear(self: *Failure) void {
        self.status = 0;
        self.n = 0;
        self.challenge = null;
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
        var cut = false;
        w.print(fmt, args) catch {
            cut = true;
        };
        // The cut falls wherever the buffer ends, which can be inside a
        // multi-byte character, and half of one is not text: the body that
        // carries it would not be JSON (ADR 024).
        self.n = @intCast(if (cut) wholeCharacters(self.buf[0..w.end]) else w.end);
    }
};

/// How much of `text` to keep so that it does not end inside a UTF-8
/// character: step back over continuation bytes to the lead byte, and drop
/// that too when the character it starts is not all there. Text that already
/// ends on a boundary, or is not UTF-8 at all, keeps its length.
fn wholeCharacters(text: []const u8) usize {
    var start = text.len;
    var back: usize = 0;
    while (start > 0 and back < 3 and text[start - 1] & 0xC0 == 0x80) : (back += 1) start -= 1;
    if (start == 0) return text.len;
    const need = std.unicode.utf8ByteSequenceLength(text[start - 1]) catch return text.len;
    return if (text.len - (start - 1) < need) start - 1 else text.len;
}

/// Everything nilo tracks about the request this fiber is serving. It is
/// what the Bulkhead slot points at, so anything reachable from anywhere —
/// a fail function, the panic handler (ADR 007) — finds it here.
pub const InFlight = struct {
    failure: Failure = .{},

    /// The request line, for the panic handler. Slices into the request
    /// arena, so valid for exactly as long as the request is.
    method: []const u8 = "",
    path: []const u8 = "",

    /// Whether this request is holding its thread (ADR 013). Here for the
    /// same reason everything else is: `nilo.blocking` has to find it from
    /// inside a call that knows nothing about the request it is part of.
    watch: watchdog.Watch = .{},

    pub fn startRequest(self: *InFlight, method: []const u8, path: []const u8) void {
        self.failure.clear();
        self.method = method;
        self.path = path;
    }
};

/// What this fiber is serving, or null outside a request.
pub fn inFlight() ?*InFlight {
    const p = bulkhead.slot() orelse return null;
    return @ptrCast(@alignCast(p));
}

/// The Failure belonging to the request currently running, or null when
/// there is no request.
pub fn current() ?*Failure {
    return &(inFlight() orelse return null).failure;
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

/// A 401 that says what would have been accepted: `with` goes out as the
/// `WWW-Authenticate` header, which RFC 9110 §15.5.2 says every 401
/// carries. `nilo.Authorization(…)` supplies it for the header it reads;
/// `T.refuse` is this with the type's own challenge filled in (ADR 153).
pub fn challenge(comptime with: [:0]const u8, comptime fmt: []const u8, args: anytype) Error {
    if (current()) |f| {
        f.set(401, fmt, args);
        f.challenge = with;
    }
    return error.Failed;
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

/// A 413, for a request body bigger than the endpoint will take. What
/// `c.bodyStream()` refusing a `Content-Length` wants to become (ADR 019).
pub fn tooLarge(comptime fmt: []const u8, args: anytype) Error {
    return status(413, fmt, args);
}

pub fn tooManyRequests(comptime fmt: []const u8, args: anytype) Error {
    return status(429, fmt, args);
}

/// A 500 with a message. The message is sent to the client, so do not put
/// anything in it that outsiders should not see.
pub fn internal(comptime fmt: []const u8, args: anytype) Error {
    return status(500, fmt, args);
}

/// The status a failed request will actually answer with: whatever a fail
/// function asked for, otherwise the mapping table. App uses this to build
/// the response; the logger middleware uses it to report the status
/// without having to guess the same thing twice.
///
/// The Failure speaks only for the error the fail functions return. It is
/// cleared when a request starts and never again, so a handler that caught a
/// `Failed` and went on to return something else would otherwise answer, and
/// log, the old status and message for an error that has nothing to do with
/// them. Every reader goes through `failed` for the same reason.
pub fn resolveStatus(failure: *const Failure, err: anyerror) u16 {
    return if (failed(failure, err)) failure.status else statusFor(err);
}

/// Whether `err` is the one the Failure describes: the sentinel a fail
/// function returned, with a message set behind it.
pub fn failed(failure: *const Failure, err: anyerror) bool {
    return err == error.Failed and failure.isSet();
}

/// Ordinary Zig errors coming from anywhere — a database, a parser, an
/// allocator — are mapped through this table. Anything unrecognised
/// becomes a 500 and is logged with its error name (ADR 004).
pub fn statusFor(err: anyerror) u16 {
    return switch (err) {
        error.Failed => 500, // should already have been handled via the Failure

        error.NotFound, error.FileNotFound => 404,

        // A body the client stopped sending before its end, read through
        // `bodyStream()`. `Ctx.body()` says the same in a sentence of its
        // own. Not `EndOfStream`: that name is every reader's, and a file a
        // handler read too far is not the client's fault (ADR 019).
        error.BodyTruncated,
        error.BadChunk,
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
        // `AlreadyExists` is `nilo_sql`'s, and one of the three errors of that
        // module's given a row here. A unique violation means the client
        // asked for something that is already there, and that is true
        // whatever the request around it was.
        //
        // The other two say the same thing whatever the request was, too:
        // `RolledBack` is a transaction the database gave up to keep the ones
        // beside it consistent, and `Disconnected` is a database that is not
        // there. Neither is the request's fault, and the same request sent
        // again may well succeed, which is what a 503 tells a client. Both
        // used to fall through to 500 — a server that looked broken while the
        // truth was a server that was busy or waiting on its database.
        //
        // **Every other constraint failure stays 500 and the handler
        // decides**, `ForeignKeyViolated` included (ADR 036, ADR 117).
        // That one is a 409 for a delete that lost a race and a 400 for an
        // insert naming a parent that was never there, and nothing here can
        // tell those apart — which is the reason it has a name rather than a
        // row.
        //
        // Naming it costs no dependency. A Zig error is a member of one
        // global set, so this file can match on the name without importing
        // the module that raises it — the arrow still runs one way.
        error.Conflict, error.AlreadyExists => 409,
        error.BodyTooLarge => 413,
        // The request never finished arriving, which is not the server's
        // fault and is worth retrying (ADR 022).
        error.BodyTooSlow => 408,
        error.Timeout, error.Canceled => 503,
        error.RolledBack, error.Disconnected => 503,

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

    try testing.expectError(error.Failed, asUnion(badRequest("{s}", .{&@as([(max_message * 2)]u8, @splat('x'))})));
    try testing.expectEqual(@as(u16, 400), failure.status);
    try testing.expect(failure.message().len <= max_message);
}

test "the error mapping table" {
    try testing.expectEqual(@as(u16, 404), statusFor(error.NotFound));
    try testing.expectEqual(@as(u16, 400), statusFor(error.InvalidCharacter));
    try testing.expectEqual(@as(u16, 413), statusFor(error.BodyTooLarge));
    try testing.expectEqual(@as(u16, 400), statusFor(error.BodyTruncated));
    try testing.expectEqual(@as(u16, 500), statusFor(error.SomethingUnrecognised));
    // A database that gave a transaction up, or is not there, is not the
    // request's fault, and the same request may go through if sent again.
    try testing.expectEqual(@as(u16, 503), statusFor(error.RolledBack));
    try testing.expectEqual(@as(u16, 503), statusFor(error.Disconnected));
    // And a constraint failure other than a duplicate stays the handler's.
    try testing.expectEqual(@as(u16, 500), statusFor(error.ForeignKeyViolated));
}

test "a challenge is a 401 that remembers what would have been accepted, and clear forgets it" {
    var failure = Failure{};
    const previous = bulkhead.setFallbackSlot(&failure);
    defer _ = bulkhead.setFallbackSlot(previous);

    try testing.expectError(error.Failed, asUnion(challenge("Bearer", "no token", .{})));
    try testing.expectEqual(@as(u16, 401), failure.status);
    try testing.expectEqualStrings("no token", failure.message());
    try testing.expectEqualStrings("Bearer", std.mem.span(failure.challenge.?));

    failure.clear();
    try testing.expect(failure.challenge == null);
}

test "a message cut at the limit is cut between characters, never inside one" {
    var failure = Failure{};
    const previous = bulkhead.setFallbackSlot(&failure);
    defer _ = bulkhead.setFallbackSlot(previous);

    // 239 bytes, then a two-byte character that has room for only half of it.
    try testing.expectError(error.Failed, asUnion(badRequest("{s}\u{e9}", .{&@as([(max_message - 1)]u8, @splat('x'))})));
    try testing.expect(std.unicode.utf8ValidateSlice(failure.message()));
    try testing.expectEqual(@as(usize, max_message - 1), failure.message().len);

    // A four-byte one cut after its first three bytes.
    try testing.expectError(error.Failed, asUnion(badRequest("{s}\u{1F600}", .{&@as([(max_message - 3)]u8, @splat('x'))})));
    try testing.expect(std.unicode.utf8ValidateSlice(failure.message()));

    // One that fits whole is kept whole.
    try testing.expectError(error.Failed, asUnion(badRequest("{s}\u{e9}", .{&@as([(max_message - 2)]u8, @splat('x'))})));
    try testing.expectEqual(@as(usize, max_message), failure.message().len);
}

test "a failure decides the status only for the error the fail functions return" {
    var failure = Failure{};
    failure.set(404, "no user", .{});
    try testing.expectEqual(@as(u16, 404), resolveStatus(&failure, error.Failed));
    // A handler that caught the Failed and went on to hit something else is
    // answering that something else (ADR 004).
    try testing.expectEqual(@as(u16, 500), resolveStatus(&failure, error.OutOfMemory));
    try testing.expectEqual(@as(u16, 413), resolveStatus(&failure, error.BodyTooLarge));
}

test "the challenge lives in the padding a Failure already had" {
    // The pointer is paid for by shrinking `n` to a byte, which the
    // 240-byte buffer allows. A connection holds one Failure, so this is
    // the per-connection number the feature must not move (ADR 153).
    try testing.expectEqual(@as(usize, 256), @sizeOf(Failure));
}
