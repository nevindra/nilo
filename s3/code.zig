//! What S3 says when it says no, and what a handler is told instead.
//!
//! S3's failures arrive as a small XML document. **Reading it needs no XML
//! parser** — a scan for `<Code>…</Code>` is twenty lines, and the whole
//! reason `LIST` is not in v1 is that it is the one operation whose *success*
//! path is XML ([ADR 0068](../docs/adr/0068-a-bucket-is-a-type-and-a-key-is-not.md)).
//!
//! The code is logged and does not reach the client (ADR 0025). What reaches
//! the client is one of seven errors, chosen because a handler would do
//! something different about each.
//!
//! One is worth its extra five lines: `RequestTimeTooSkewed` is the single 403
//! that is not the program's fault, and S3's body carries the server's clock in
//! it. Scanning for that too turns *403* into *your clock is 23 minutes behind
//! S3*, and in this repository an error message is a feature.

const std = @import("std");

/// The failures a handler can tell apart, and the whole list
/// (ADR 0068). Anything not worth a different response is `Failed`.
pub const Error = error{
    /// No object at that key. **The one with a default status**, 404, because
    /// its meaning does not change with the request around it.
    NotFound,
    /// The object is larger than the bucket's `max_bytes`. Refused before a
    /// byte of it is read.
    TooLarge,
    /// S3 is shedding load — `SlowDown`, or a 503. Deliberately not a default
    /// 503 of its own: for `GET /avatar/:id` the right answer may well be a
    /// default image and a 200, and only the handler knows.
    Throttled,
    /// S3 answered 5xx. Distinct from `Throttled` because backing off is the
    /// answer to one and not the other.
    Unavailable,
    /// This call's deadline ran out (ADR 0065).
    TimedOut,
    /// S3 refused the request. **Not a 403 to the client**: telling a caller
    /// they are not allowed, when the truth is that the server's credentials
    /// are wrong, is a lie in the one place a lie costs the most debugging.
    Rejected,
    /// Everything else, including a response nilo could not make sense of.
    Failed,
};

/// What was read out of an error body. Every field is a slice into the body
/// itself, so it lives exactly as long as that does.
pub const Reason = struct {
    code: []const u8 = "",
    message: []const u8 = "",
    /// Only ever set for `RequestTimeTooSkewed`, and the reason this struct
    /// has three fields rather than two.
    server_time: []const u8 = "",

    pub fn read(body: []const u8) Reason {
        return .{
            .code = between(body, "<Code>", "</Code>"),
            .message = between(body, "<Message>", "</Message>"),
            .server_time = between(body, "<ServerTime>", "</ServerTime>"),
        };
    }
};

fn between(body: []const u8, open: []const u8, close: []const u8) []const u8 {
    const start = std.mem.indexOf(u8, body, open) orelse return "";
    const from = start + open.len;
    const end = std.mem.indexOfPos(u8, body, from, close) orelse return "";
    return body[from..end];
}

/// The error a status and a code amount to.
///
/// The status decides it and the code refines it, in that order, because a
/// gateway in front of S3 may answer 503 with no body at all and that is still
/// throttling as far as a handler is concerned.
pub fn errorFor(status: std.http.Status, code: []const u8) Error {
    if (std.mem.eql(u8, code, "SlowDown")) return error.Throttled;
    if (std.mem.eql(u8, code, "NoSuchKey")) return error.NotFound;
    if (std.mem.eql(u8, code, "NoSuchBucket")) return error.NotFound;

    return switch (@intFromEnum(status)) {
        404 => error.NotFound,
        403, 400, 401, 405, 409, 411, 412, 416 => error.Rejected,
        429 => error.Throttled,
        503 => error.Throttled,
        500, 501, 502, 504 => error.Unavailable,
        else => error.Failed,
    };
}

/// The one 403 that is not the program's fault, told apart so the log can say
/// what to fix.
pub fn isClockSkew(code: []const u8) bool {
    return std.mem.eql(u8, code, "RequestTimeTooSkewed");
}

// -- tests ---------------------------------------------------------------

const testing = std.testing;

const not_found_body =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<Error><Code>NoSuchKey</Code><Message>The specified key does not exist.</Message>
    \\<Key>avatars/7.png</Key><RequestId>8F2C</RequestId></Error>
;

test "a code is read out of an error body without an XML parser" {
    const reason: Reason = .read(not_found_body);
    try testing.expectEqualStrings("NoSuchKey", reason.code);
    try testing.expectEqualStrings("The specified key does not exist.", reason.message);
    try testing.expectEqualStrings("", reason.server_time);
}

test "a body with nothing in it reads as nothing rather than as a crash" {
    // What a gateway in front of S3 answers with, and what a truncated
    // response looks like. Both have to be survivable: this runs on the path
    // where something has already gone wrong.
    for ([_][]const u8{ "", "not xml at all", "<Error><Code>", "<Code></Code>" }) |body| {
        const reason: Reason = .read(body);
        try testing.expectEqualStrings("", reason.code);
        try testing.expectEqualStrings("", reason.message);
    }
}

test "a clock that has drifted says so, with the server's own time in it" {
    const skewed =
        \\<Error><Code>RequestTimeTooSkewed</Code>
        \\<Message>The difference between the request time and the current time is too large.</Message>
        \\<MaxAllowedSkewMilliseconds>900000</MaxAllowedSkewMilliseconds>
        \\<ServerTime>2026-08-17T01:42:33Z</ServerTime></Error>
    ;
    const reason: Reason = .read(skewed);
    try testing.expect(isClockSkew(reason.code));
    try testing.expectEqualStrings("2026-08-17T01:42:33Z", reason.server_time);
    // And it is still a `Rejected` to the handler — the difference is what the
    // log says, not what the caller gets.
    try testing.expectEqual(Error.Rejected, errorFor(.forbidden, reason.code));
}

test "a status becomes the error a handler would act on" {
    try testing.expectEqual(Error.NotFound, errorFor(.not_found, ""));
    try testing.expectEqual(Error.Rejected, errorFor(.forbidden, ""));
    try testing.expectEqual(Error.Throttled, errorFor(.service_unavailable, ""));
    try testing.expectEqual(Error.Unavailable, errorFor(.internal_server_error, ""));
    try testing.expectEqual(Error.Unavailable, errorFor(.bad_gateway, ""));
    try testing.expectEqual(Error.Failed, errorFor(@enumFromInt(299), ""));
}

test "a code refines the status rather than the other way round" {
    // S3 answers `SlowDown` with a 503 and sometimes with a 200-shaped
    // gateway error; the code is what means throttling either way.
    try testing.expectEqual(Error.Throttled, errorFor(.internal_server_error, "SlowDown"));
    try testing.expectEqual(Error.NotFound, errorFor(.forbidden, "NoSuchKey"));
    // A 503 with no body at all is still throttling, which is why the status
    // is read at all rather than only the code.
    try testing.expectEqual(Error.Throttled, errorFor(.service_unavailable, ""));
}
