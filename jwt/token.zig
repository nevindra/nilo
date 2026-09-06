//! Reading a signed JWT, in the order that makes the checks mean something.
//!
//! **The algorithm comes from this file, never from the token.** A verifier
//! that reads `alg` out of the header and does what it says will accept
//! `{"alg":"none"}`, and will accept an HMAC signed with the RSA public key
//! it published. So `alg` is not an instruction here, it is one more thing
//! compared against a constant.
//!
//! **Nothing in the payload is looked at until the signature has passed.**
//! `exp` off an unverified token is a number somebody chose.
//!
//! The claims come back as a struct of the caller's own — the same bargain
//! the rest of nilo makes, and the reason `sub` and `email` are fields with
//! types rather than lookups into a map. The registered claims are checked
//! whether or not that struct names them (ADR 0140).

const std = @import("std");
const b64 = @import("b64.zig");
const jwks = @import("jwks.zig");
const rs256 = @import("rs256.zig");

pub const Error = error{
    /// Not three base64url segments separated by two dots.
    NotAToken,
    /// The header says something other than `RS256` — including `none`.
    WrongAlgorithm,
    /// The header's `kid` is not in the key set, or it named none and the
    /// set has more than one key to choose from.
    NoSuchKey,
    /// The token carries no `exp`. A credential with no end is not one.
    NoExpiry,
    /// `exp` has passed.
    Expired,
    /// `nbf` has not arrived.
    NotYetValid,
    /// `iss` is not the issuer that was asked for, or there is none.
    WrongIssuer,
    /// `aud` does not carry the audience that was asked for.
    WrongAudience,
    /// The signature checked out and the payload does not fit the struct the
    /// caller asked for.
    ClaimsNotReadable,
    OutOfMemory,
} || rs256.Error;

pub const Options = struct {
    /// The issuer's keys. Fetching and refreshing them is the caller's —
    /// `nilo_fetch` sends the GET and `nilo_cache` holds the answer.
    keys: *const jwks.Keys,
    /// Refuse a token whose `iss` is not this. Null skips the check, which
    /// is only right when the key set can only have come from one issuer.
    issuer: ?[]const u8 = null,
    /// Refuse a token whose `aud` does not carry this. For Google this is
    /// the OAuth client id. Null skips the check.
    audience: ?[]const u8 = null,
    /// Now, in seconds since the epoch. An argument rather than a clock, for
    /// the reason `nilo_id` takes a millisecond as one: a module with no
    /// event loop has no clock, and a test that cannot choose the time
    /// cannot test an expiry.
    now_s: i64,
    /// How far the two clocks are allowed to disagree, both ways.
    leeway_s: u32 = 0,
};

/// What the header is read into. Everything optional: it is somebody else's
/// document until it has been checked.
const Header = struct {
    alg: ?[]const u8 = null,
    kid: ?[]const u8 = null,
    typ: ?[]const u8 = null,
};

/// The claims JWT itself defines, as opposed to the ones the caller's struct
/// names. `aud` is a `Value` because it is a string in most tokens and an
/// array of strings in some, and both are legal.
const Registered = struct {
    iss: ?[]const u8 = null,
    aud: ?std.json.Value = null,
    exp: ?i64 = null,
    nbf: ?i64 = null,
};

/// Verify a token and read its payload into `Claims`.
///
/// Strings in the result point into `gpa`. Hand it a request arena and there
/// is nothing to free.
pub fn verify(
    comptime Claims: type,
    gpa: std.mem.Allocator,
    token: []const u8,
    opts: Options,
) Error!Claims {
    // Scratch for the header, the signature and the payload bytes. The
    // caller's allocator only ever holds the claims, so handing this a
    // long-lived gpa does not leak the parts nobody asked for.
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const tmp = scratch.allocator();

    const first = std.mem.indexOfScalar(u8, token, '.') orelse return error.NotAToken;
    const rest = token[first + 1 ..];
    const second = std.mem.indexOfScalar(u8, rest, '.') orelse return error.NotAToken;
    const signed = token[0 .. first + 1 + second];
    const payload_text = rest[0..second];
    const sig_text = rest[second + 1 ..];
    if (first == 0 or second == 0 or sig_text.len == 0) return error.NotAToken;
    // A fourth segment is JWE, which this does not read.
    if (std.mem.indexOfScalar(u8, sig_text, '.') != null) return error.NotAToken;

    const header_bytes = b64.keep(tmp, token[0..first]) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NotBase64Url => return error.NotAToken,
    };
    const header = std.json.parseFromSliceLeaky(Header, tmp, header_bytes, .{
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NotAToken,
    };

    // Against a constant, not against whatever the token would like.
    const alg = header.alg orelse return error.WrongAlgorithm;
    if (!std.mem.eql(u8, alg, "RS256")) return error.WrongAlgorithm;

    const key = opts.keys.find(header.kid) orelse return error.NoSuchKey;

    const sig = b64.keep(tmp, sig_text) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NotBase64Url => return error.NotAToken,
    };
    try rs256.verify(signed, sig, key.e, key.n);

    // Past here the bytes are the issuer's.
    const payload_bytes = b64.keep(tmp, payload_text) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NotBase64Url => return error.NotAToken,
    };
    const reg = std.json.parseFromSliceLeaky(Registered, tmp, payload_bytes, .{
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ClaimsNotReadable,
    };

    const leeway: i64 = opts.leeway_s;
    const exp = reg.exp orelse return error.NoExpiry;
    if (opts.now_s > exp + leeway) return error.Expired;
    if (reg.nbf) |nbf| {
        if (opts.now_s + leeway < nbf) return error.NotYetValid;
    }
    if (opts.issuer) |want| {
        const iss = reg.iss orelse return error.WrongIssuer;
        if (!std.mem.eql(u8, iss, want)) return error.WrongIssuer;
    }
    if (opts.audience) |want| {
        if (!audienceCarries(reg.aud, want)) return error.WrongAudience;
    }

    return std.json.parseFromSliceLeaky(Claims, gpa, payload_bytes, .{
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ClaimsNotReadable,
    };
}

/// `aud` is one string in most tokens and a list in some. Both are the same
/// question: is this audience in there.
fn audienceCarries(aud: ?std.json.Value, want: []const u8) bool {
    const value = aud orelse return false;
    return switch (value) {
        .string => |s| std.mem.eql(u8, s, want),
        .array => |list| for (list.items) |item| {
            switch (item) {
                .string => |s| if (std.mem.eql(u8, s, want)) break true,
                else => {},
            }
        } else false,
        else => false,
    };
}

const testing = std.testing;

/// A 2048-bit key and a token signed with it, generated once with openssl and
/// pinned here. The payload is
/// `{"iss":"https://accounts.example","aud":"client-1","sub":"u-7",
///   "email":"a@example.com","exp":2000000000,"nbf":1000000000}`.
const vector = @import("vector.zig");

fn keySet() !jwks.Keys {
    return jwks.parse(testing.allocator, vector.jwks);
}

test "a token signed by the key in the set verifies, and the claims come back" {
    const Claims = struct { sub: []const u8, email: []const u8 };

    var keys = try keySet();
    defer keys.deinit();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const claims = try verify(Claims, arena.allocator(), vector.token, .{
        .keys = &keys,
        .issuer = "https://accounts.example",
        .audience = "client-1",
        .now_s = 1_500_000_000,
    });
    try testing.expectEqualStrings("u-7", claims.sub);
    try testing.expectEqualStrings("a@example.com", claims.email);
}

test "one flipped byte in the payload is a bad signature, not a claim" {
    const Claims = struct { sub: []const u8 };

    var keys = try keySet();
    defer keys.deinit();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // One character of the payload segment, changed. The signature was taken
    // over the header and the payload together, so this is what a tampered
    // claim looks like on the wire.
    const bad = try arena.allocator().dupe(u8, vector.token);
    const at = std.mem.indexOfScalar(u8, bad, '.').? + 1;
    bad[at] = if (bad[at] == 'A') 'B' else 'A';
    try testing.expect(!std.mem.eql(u8, bad, vector.token));
    try testing.expectError(error.BadSignature, verify(Claims, arena.allocator(), bad, .{
        .keys = &keys,
        .now_s = 1_500_000_000,
    }));
}

test "alg none is refused before anything else is looked at" {
    const Claims = struct { sub: []const u8 };

    var keys = try keySet();
    defer keys.deinit();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // {"alg":"none"} . the real payload . nothing
    const forged = "eyJhbGciOiJub25lIn0." ++ vector.payload ++ ".";
    try testing.expectError(error.NotAToken, verify(Claims, arena.allocator(), forged, .{
        .keys = &keys,
        .now_s = 1_500_000_000,
    }));

    // …and with a signature-shaped segment on the end, so it is the `alg`
    // check doing the refusing rather than the empty third segment.
    const forged_sig = "eyJhbGciOiJub25lIn0." ++ vector.payload ++ ".AAAA";
    try testing.expectError(error.WrongAlgorithm, verify(Claims, arena.allocator(), forged_sig, .{
        .keys = &keys,
        .now_s = 1_500_000_000,
    }));
}

test "HS256 signed with the published modulus is refused" {
    const Claims = struct { sub: []const u8 };

    var keys = try keySet();
    defer keys.deinit();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // {"alg":"HS256"} — the confused-deputy attack every JWT library has had.
    const forged = "eyJhbGciOiJIUzI1NiJ9." ++ vector.payload ++ ".AAAA";
    try testing.expectError(error.WrongAlgorithm, verify(Claims, arena.allocator(), forged, .{
        .keys = &keys,
        .now_s = 1_500_000_000,
    }));
}

test "expiry, not-yet-valid, issuer and audience each get their own answer" {
    const Claims = struct { sub: []const u8 };

    var keys = try keySet();
    defer keys.deinit();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectError(error.Expired, verify(Claims, a, vector.token, .{
        .keys = &keys,
        .now_s = 2_000_000_001,
    }));
    try testing.expectError(error.NotYetValid, verify(Claims, a, vector.token, .{
        .keys = &keys,
        .now_s = 999_999_999,
    }));
    try testing.expectError(error.WrongIssuer, verify(Claims, a, vector.token, .{
        .keys = &keys,
        .issuer = "https://accounts.google.com",
        .now_s = 1_500_000_000,
    }));
    try testing.expectError(error.WrongAudience, verify(Claims, a, vector.token, .{
        .keys = &keys,
        .audience = "some-other-client",
        .now_s = 1_500_000_000,
    }));
}

test "leeway covers a clock that is a minute out, and no more" {
    const Claims = struct { sub: []const u8 };

    var keys = try keySet();
    defer keys.deinit();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    _ = try verify(Claims, a, vector.token, .{
        .keys = &keys,
        .now_s = 2_000_000_030,
        .leeway_s = 60,
    });
    try testing.expectError(error.Expired, verify(Claims, a, vector.token, .{
        .keys = &keys,
        .now_s = 2_000_000_090,
        .leeway_s = 60,
    }));
}

test "a kid that is not in the set says so rather than failing the signature" {
    const Claims = struct { sub: []const u8 };

    var keys = try jwks.parse(testing.allocator,
        \\{"keys":[{"kty":"RSA","kid":"somebody-else","n":"-_8","e":"AQAB"}]}
    );
    defer keys.deinit();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.NoSuchKey, verify(Claims, arena.allocator(), vector.token, .{
        .keys = &keys,
        .now_s = 1_500_000_000,
    }));
}

test "an audience given as a list is read the same as one given as a string" {
    try testing.expect(audienceCarries(.{ .string = "client-1" }, "client-1"));
    try testing.expect(!audienceCarries(.{ .string = "client-2" }, "client-1"));

    // Built by the parser rather than by hand, because a list `aud` only ever
    // reaches this function that way.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const listed = try std.json.parseFromSliceLeaky(
        Registered,
        arena.allocator(),
        \\{"aud":["other","client-1"]}
    ,
        .{ .ignore_unknown_fields = true },
    );
    try testing.expect(audienceCarries(listed.aud, "client-1"));
    try testing.expect(!audienceCarries(listed.aud, "client-3"));

    try testing.expect(!audienceCarries(null, "client-1"));
    try testing.expect(!audienceCarries(.{ .integer = 1 }, "client-1"));
}

test "things that are not tokens" {
    const Claims = struct { sub: []const u8 };

    var keys = try keySet();
    defer keys.deinit();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const opts: Options = .{ .keys = &keys, .now_s = 1_500_000_000 };

    for ([_][]const u8{
        "",
        "one-segment",
        "two.segments",
        "a.b.c.d",
        ".b.c",
        "a..c",
        "a.b.",
        "!!!.b.c",
    }) |bad| {
        try testing.expectError(error.NotAToken, verify(Claims, a, bad, opts));
    }
}
