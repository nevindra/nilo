//! The `Authorization` header, read once and refused with a challenge
//! ([ADR 0191](../docs/adr/0191-an-authorization-header-a-handler-can-ask-for.md)).
//!
//! ```zig
//! fn me(auth: nilo.Authorization(.bearer), issuer: *const Issuer, c: *nilo.Ctx) !Profile {
//!     const claims = jwt.verify(Claims, c.arena(), auth.value.view(), …) catch
//!         return nilo.Authorization(.bearer).refuse("that token is not valid here", .{});
//!     …
//! }
//!
//! fn admin(auth: nilo.Authorization(.{ .basic = "admin" })) !void {
//!     … auth.user, auth.password …
//! }
//! ```
//!
//! `c.header("Authorization")` reads the same bytes, and this file exists
//! because the six lines after it were written twice in this repository
//! and both copies were wrong in the same two ways: the scheme was matched
//! case-sensitively, which RFC 9110 §11.1 says it is not, and the 401 went
//! out without the `WWW-Authenticate` header §15.5.2 says it has to carry.
//! A check that runs perfectly and refuses the wrong clients is the kind of
//! bug `nilo_jwt` was built to keep out, one header up.
//!
//! **A 401 nilo writes carries the challenge, and so does one you write.**
//! Absent or the wrong scheme is refused here, with `WWW-Authenticate: Bearer`
//! or `Basic realm="…"`. A refusal *after* reading — the token did not
//! verify, the password did not match — is yours, and `T.refuse` is
//! `fail.unauthorized` with the same header on it, so the handler stays a
//! plain function with no Ctx in it.
//!
//! **What it costs.** Bearer reads a slice of the head and allocates
//! nothing. Basic decodes into the request arena — one allocation of the
//! decoded length, on the route that asked for it. Both are a scan of the
//! headers `c.header` would have done. The challenge on a failure is one
//! pointer to a comptime string, kept inside the padding `Failure` already
//! had, so a connection weighs what it weighed.
//!
//! **What it does not do.** Digest, and the chain "try the header, then the
//! query string, then a cookie" some frameworks offer. A token in a query
//! string is a token in every access log between the client and this
//! process; the type says where the value comes from and there is one place.

const std = @import("std");
const core = @import("nilo_core");
const fail = @import("fail.zig");

const Str = core.Str;

/// Which scheme the endpoint takes. `.basic` carries the realm the
/// browser's sign-in prompt shows, because RFC 7617 makes it required.
pub const Scheme = union(enum) {
    bearer,
    basic: []const u8,
};

/// The typed argument — see the file header.
pub fn Authorization(comptime scheme: Scheme) type {
    comptime check(scheme);
    return switch (scheme) {
        .bearer => struct {
            pub const nilo_authorization = scheme;
            /// What a nilo compile error calls this type, which is the name
            /// the reader's own import line gives it (ADR 0122).
            pub const nilo_type_name = "nilo.Authorization(.bearer)";
            /// What a 401 from this endpoint says in `WWW-Authenticate`.
            pub const challenge: [:0]const u8 = "Bearer";

            /// The token, as the client sent it: the bytes after the scheme,
            /// with the whitespace around them gone. Not decoded, because a
            /// bearer token is opaque to everybody but its issuer.
            value: Str,

            /// A 401 that carries this endpoint's challenge. For the refusal
            /// that comes *after* reading — the token did not verify.
            pub fn refuse(comptime fmt: []const u8, args: anytype) fail.Error {
                return fail.challenge(challenge, fmt, args);
            }
        },
        .basic => |realm| struct {
            pub const nilo_authorization = scheme;
            pub const nilo_type_name = "nilo.Authorization(.{ .basic = \"" ++ realm ++ "\" })";
            pub const challenge: [:0]const u8 = "Basic realm=\"" ++ realm ++ "\"";

            /// Before the first colon. A user-id cannot contain one
            /// (RFC 7617 §2), which is what makes the split unambiguous.
            user: Str,
            /// After it — and a password may contain colons of its own.
            password: Str,

            /// A 401 that carries this endpoint's challenge. For the refusal
            /// that comes *after* reading — the password did not match.
            pub fn refuse(comptime fmt: []const u8, args: anytype) fail.Error {
                return fail.challenge(challenge, fmt, args);
            }
        },
    };
}

/// Whether `T` is one of the types above. Asked by the typed engine.
pub fn is(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => @hasDecl(T, "nilo_authorization"),
        else => false,
    };
}

/// Read the header into the type, or stop the request with a 401 that says
/// what would have been accepted. `c.authorization(scheme)` is this with the
/// Ctx's own three arguments filled in, and it is what a resolver or a
/// middleware calls. Handed the pieces rather than the Ctx so this file
/// stays outside the App's core (`http_core` in build.zig).
pub fn read(
    comptime scheme: Scheme,
    header: ?[]const u8,
    arena: std.mem.Allocator,
    lifetime: *const core.Lifetime,
) !Authorization(scheme) {
    const T = Authorization(scheme);
    const raw = header orelse return fail.challenge(
        T.challenge,
        "this endpoint wants an Authorization header saying \"{s} …\"",
        .{schemeWord(scheme)},
    );
    const found = split(raw);
    if (!std.ascii.eqlIgnoreCase(found.scheme, schemeWord(scheme))) return fail.challenge(
        T.challenge,
        "the Authorization header has to say \"{s} …\", and it says something else",
        .{schemeWord(scheme)},
    );
    if (found.credentials.len == 0) return fail.challenge(
        T.challenge,
        "the Authorization header says \"{s}\" and nothing after it",
        .{schemeWord(scheme)},
    );

    switch (scheme) {
        .bearer => return .{ .value = Str.fromRequest(found.credentials, lifetime) },
        .basic => {
            const decoder = std.base64.standard.Decoder;
            const size = decoder.calcSizeForSlice(found.credentials) catch return fail.challenge(
                T.challenge,
                "what follows Basic in the Authorization header is not base64",
                .{},
            );
            const decoded = try arena.alloc(u8, size);
            decoder.decode(decoded, found.credentials) catch return fail.challenge(
                T.challenge,
                "what follows Basic in the Authorization header is not base64",
                .{},
            );
            const colon = std.mem.indexOfScalar(u8, decoded, ':') orelse return fail.challenge(
                T.challenge,
                "what follows Basic in the Authorization header has no colon between the user and the password",
                .{},
            );
            return .{
                .user = Str.fromRequest(decoded[0..colon], lifetime),
                .password = Str.fromRequest(decoded[colon + 1 ..], lifetime),
            };
        },
    }
}

fn schemeWord(comptime scheme: Scheme) []const u8 {
    return switch (scheme) {
        .bearer => "Bearer",
        .basic => "Basic",
    };
}

const Split = struct { scheme: []const u8, credentials: []const u8 };

/// `credentials = auth-scheme [ 1*SP ( token68 / #auth-param ) ]`, read the
/// way clients actually write it: any run of blanks between the two, and
/// none counted at either end.
fn split(value: []const u8) Split {
    const blank = " \t";
    const trimmed = std.mem.trim(u8, value, blank);
    const gap = std.mem.indexOfAny(u8, trimmed, blank) orelse
        return .{ .scheme = trimmed, .credentials = "" };
    return .{
        .scheme = trimmed[0..gap],
        .credentials = std.mem.trimStart(u8, trimmed[gap..], blank),
    };
}

/// The realm goes into a quoted-string on the wire and onto the screen in
/// the browser's prompt, and both refuse the same two things.
fn check(comptime scheme: Scheme) void {
    comptime {
        const realm = switch (scheme) {
            .bearer => return,
            .basic => |r| r,
        };
        if (realm.len == 0) @compileError(
            "nilo: `Authorization(.{ .basic = \"\" })` names no realm.\n" ++
                "  The realm is what the browser's sign-in prompt shows, and RFC 7617 " ++
                "makes it required: `nilo.Authorization(.{ .basic = \"admin\" })`.",
        );
        for (realm) |ch| {
            if (ch == '"' or ch == '\\' or ch < 0x20 or ch == 0x7f) @compileError(
                "nilo: the realm \"" ++ realm ++ "\" of an `Authorization(.{ .basic = … })` " ++
                    "has a character in it that a WWW-Authenticate header cannot carry.\n" ++
                    "  A realm is shown as it is written: letters, digits, spaces and " ++
                    "punctuation, with no `\"`, no `\\` and nothing unprintable.",
            );
        }
    }
}

// ---- tests ----

const testing = std.testing;

test "the scheme is whatever comes before the first blank, and the credentials are the rest" {
    const plain = split("Bearer abc.def.ghi");
    try testing.expectEqualStrings("Bearer", plain.scheme);
    try testing.expectEqualStrings("abc.def.ghi", plain.credentials);

    // Two spaces, a tab, and blanks at either end are how clients write it
    // when they are not a library.
    const loose = split("  bearer \t  abc.def.ghi  ");
    try testing.expectEqualStrings("bearer", loose.scheme);
    try testing.expectEqualStrings("abc.def.ghi", loose.credentials);

    const bare = split("Bearer");
    try testing.expectEqualStrings("Bearer", bare.scheme);
    try testing.expectEqualStrings("", bare.credentials);

    const nothing = split("   ");
    try testing.expectEqualStrings("", nothing.scheme);
    try testing.expectEqualStrings("", nothing.credentials);
}

test "the challenge is a comptime string the type carries" {
    try testing.expectEqualStrings("Bearer", Authorization(.bearer).challenge);
    try testing.expectEqualStrings("Basic realm=\"admin\"", Authorization(.{ .basic = "admin" }).challenge);
    try testing.expect(is(Authorization(.bearer)));
    try testing.expect(!is(struct { value: Str }));
}
