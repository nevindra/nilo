//! Redirects — a status and a `Location`, returned rather than sent
//! (ADR 0032).
//!
//! ```zig
//! fn shortLink(db: *Db, code: Str) !zfast.Redirect(302) {
//!     return .to(try db.target(code.view()));
//! }
//!
//! fn signUp(incoming: zfast.Form(SignUp)) !zfast.Redirect(303) {
//!     try store.add(incoming.value);
//!     return .to("/welcome");
//! }
//! ```
//!
//! The status is part of the type, so the generated API description names it
//! and says the answer carries a `Location` — the same reason `Status(201, T)`
//! exists next to `Response(T)` (ADR 0024). A redirect whose status is only
//! known while the request is running is `c.redirect(status, where)`, which
//! is what this compiles down to anyway.
//!
//! `location` is copied on the way out, exactly as a `Response`'s headers
//! are, so building one in the request arena — or on the stack — is safe.

const std = @import("std");

const typed = @import("typed.zig");

/// The declaration a `Redirect` carries, so the compile-time engine can tell
/// one from an ordinary return value. Its value is the status.
pub const marker = "zfast_redirect";

/// A response that sends the client somewhere else.
pub fn Redirect(comptime status: u16) type {
    comptime checkStatus(status);

    return struct {
        const Self = @This();

        pub const zfast_redirect = status;

        /// Where the client is being sent. A path (`/welcome`) or a whole
        /// URL; zfast passes it through untouched, because what counts as a
        /// sensible destination is the application's business.
        location: []const u8,

        /// Headers to send with the redirect — a `Set-Cookie`, usually,
        /// which is how a sign-in answers: set the session and send them on.
        headers: typed.Headers = .{},

        /// The redirect itself. Written as a decl literal at the return, so
        /// the status stays in the signature where the document can read it:
        ///
        /// ```zig
        /// fn old() zfast.Redirect(301) {
        ///     return .to("/new");
        /// }
        /// ```
        pub fn to(location: []const u8) Self {
            return .{ .location = location };
        }

        /// A redirect carrying headers of its own.
        ///
        /// ```zig
        /// return .with("/welcome", .of(&.{.{ .name = "Set-Cookie", .value = session }}));
        /// ```
        pub fn with(location: []const u8, headers: typed.Headers) Self {
            return .{ .location = location, .headers = headers };
        }
    };
}

/// The statuses that mean "go here instead". Everything else is refused
/// while compiling, because a redirect without a status that carries a
/// `Location` is a response no client will follow — and finding that out
/// from a browser is a bad afternoon.
fn checkStatus(comptime status: u16) void {
    comptime {
        switch (status) {
            301, 302, 303, 307, 308 => return,
            else => @compileError(
                "zfast: `Redirect(" ++ std.fmt.comptimePrint("{d}", .{status}) ++
                    ")` is not a redirect.\n" ++
                    "  The statuses that carry a Location are 301 (moved for good), 302 (found), " ++
                    "303 (see other — what a form POST answers with, so the reload does not " ++
                    "post again), 307 (temporary, and the method is kept) and 308 (permanent, " ++
                    "and the method is kept).",
            ),
        }
    }
}

/// Whether `T` is a redirect, for the compile-time engine.
pub fn isRedirect(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, marker),
        else => false,
    };
}

const testing = std.testing;

test "a redirect carries its status in the type and its location in the value" {
    const Moved = Redirect(301);
    try testing.expectEqual(@as(u16, 301), Moved.zfast_redirect);

    const answer: Moved = .to("/new");
    try testing.expectEqualStrings("/new", answer.location);
    try testing.expectEqual(@as(usize, 0), answer.headers.count);
}

test "a redirect can carry headers of its own" {
    const answer: Redirect(303) = .with("/welcome", .of(&.{
        .{ .name = "Set-Cookie", .value = "session=abc" },
    }));
    try testing.expectEqualStrings("/welcome", answer.location);
    try testing.expectEqual(@as(usize, 1), answer.headers.count);
    try testing.expectEqualStrings("session=abc", answer.headers.view()[0].value);
}

test "every redirect status the type accepts" {
    inline for (.{ 301, 302, 303, 307, 308 }) |status| {
        try testing.expectEqual(@as(u16, status), Redirect(status).zfast_redirect);
        try testing.expect(isRedirect(Redirect(status)));
    }
    try testing.expect(!isRedirect(u32));
    try testing.expect(!isRedirect(struct { a: u32 }));
}
