//! The code a failed call is answered with, which gRPC sends as a number in
//! `grpc-status` and Connect as a name in its error body: one table, so a
//! method failing the same way reads the same to a client of either
//! ([ADR 220](../docs/adr/220-grpc-is-served-over-h2c-behind-a-flag.md),
//! [ADR 257](../docs/adr/257-a-connect-client-is-told-its-failure-in-connect-words.md)).
//! The numbers are gRPC's; `names` is Connect's spelling of each.

const std = @import("std");

/// Connect's name for each code, by its number (the Connect protocol's
/// error codes, which are gRPC's in snake case and `canceled` with one l).
pub const names = [17][]const u8{
    "ok",                 "canceled",            "unknown",        "invalid_argument",
    "deadline_exceeded",  "not_found",           "already_exists", "permission_denied",
    "resource_exhausted", "failed_precondition", "aborted",        "out_of_range",
    "unimplemented",      "internal",            "unavailable",    "data_loss",
    "unauthenticated",
};

/// The code a failed call is answered with: the one its error names when it
/// names one, the one its status means otherwise (ADR 220).
pub fn of(failure: ?anyerror, status: u16) u8 {
    if (failure) |err| if (forError(err)) |code| return code;
    return forStatus(status);
}

/// The errors that say their code more precisely than their HTTP status
/// does. A duplicate row and a lost race are both a 409, and a client is
/// told to retry the second and not the first: `ALREADY_EXISTS` says the
/// thing is there, `ABORTED` that the transaction around the call should go
/// again, which is what a rolled-back one means, where its 503 would read as
/// `UNAVAILABLE`. One list, so the gRPC listener and Connect's writers
/// cannot know different ones.
pub const by_error = [_]struct { err: anyerror, code: u8 }{
    .{ .err = error.AlreadyExists, .code = 6 }, // ALREADY_EXISTS
    .{ .err = error.RolledBack, .code = 10 }, // ABORTED
};

/// The code `err` names, from `by_error`; null for every other error, whose
/// status decides.
pub fn forError(err: anyerror) ?u8 {
    inline for (by_error) |named| if (err == named.err) return named.code;
    return null;
}

/// The gRPC code an HTTP status means when a route failed with it. Chosen by
/// what the status says about the call rather than by gRPC's own table for
/// proxies, which reads a status as something that went wrong on the way:
/// a 404 from a route is a thing that was not found, not a method that does
/// not exist, and a path no route answers never gets here.
pub fn forStatus(status: u16) u8 {
    return switch (status) {
        200 => 0,
        400, 415, 422 => 3, // INVALID_ARGUMENT
        401 => 16, // UNAUTHENTICATED
        403 => 7, // PERMISSION_DENIED
        404 => 5, // NOT_FOUND
        405, 501 => 12, // UNIMPLEMENTED
        408, 504 => 4, // DEADLINE_EXCEEDED
        409 => 10, // ABORTED
        412 => 9, // FAILED_PRECONDITION
        413, 429 => 8, // RESOURCE_EXHAUSTED
        499 => 1, // CANCELLED
        503 => 14, // UNAVAILABLE
        500 => 13, // INTERNAL
        else => if (status >= 400 and status < 500) 9 else 2, // FAILED_PRECONDITION, UNKNOWN
    };
}

// ---- tests ----

const testing = std.testing;

test "the code a failed route's status means" {
    try testing.expectEqual(@as(u8, 3), forStatus(400));
    try testing.expectEqual(@as(u8, 16), forStatus(401));
    try testing.expectEqual(@as(u8, 7), forStatus(403));
    try testing.expectEqual(@as(u8, 5), forStatus(404));
    try testing.expectEqual(@as(u8, 8), forStatus(429));
    try testing.expectEqual(@as(u8, 13), forStatus(500));
    try testing.expectEqual(@as(u8, 14), forStatus(503));
    try testing.expectEqual(@as(u8, 2), forStatus(302));
}

test "a failure's error says its code before its status does" {
    try testing.expectEqual(@as(u8, 6), of(error.AlreadyExists, 409));
    try testing.expectEqual(@as(u8, 10), of(error.RolledBack, 503));
    try testing.expectEqual(@as(u8, 14), of(error.Other, 503));
    try testing.expectEqual(@as(u8, 5), of(null, 404));
    try testing.expectEqualStrings("already_exists", names[of(error.AlreadyExists, 409)]);
    try testing.expectEqualStrings("unauthenticated", names[16]);
}
