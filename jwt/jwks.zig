//! A JWKS document read into the keys nilo can actually verify with.
//!
//! **nilo parses a key set and does not fetch one.** The fetch is an HTTPS GET
//! and `nilo_fetch` already sends those; the cache is `nilo_cache`; the
//! refresh policy — how long a key set is good for, what to do when a `kid`
//! misses — is the caller's, the way every other policy here is. What a
//! caller *cannot* already write safely is the rest of this module, and
//! ADR 0140 is where that line is argued.
//!
//! A key set usually carries keys this cannot use — an EC key beside the RSA
//! ones, a key marked `"use": "enc"`. Those are **skipped rather than
//! refused**: a document nilo cannot fully read is still a document with the
//! right key in it, and an issuer adding a key type is not a reason to stop
//! signing people in.

const std = @import("std");
const b64 = @import("b64.zig");

pub const Error = error{
    /// The bytes are not a JSON object with a `keys` array in it.
    NotAKeySet,
    /// A key said RSA and then did not carry `n` and `e` as base64url.
    KeyNotUsable,
    OutOfMemory,
};

/// One RSA public key, with both big integers already decoded. `kid` is
/// borrowed from nothing — like the integers, it is owned by the `Keys` that
/// holds it.
pub const Key = struct {
    kid: []const u8,
    /// The exponent, big-endian. `AQAB` — 65537 — for essentially every key
    /// in the world.
    e: []const u8,
    /// The modulus, big-endian.
    n: []const u8,
};

/// The keys of one document, owned together. `deinit` frees the lot.
pub const Keys = struct {
    all: []const Key,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Keys) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// The key a token's `kid` names. A key set with exactly one key answers
    /// for a token that named no `kid` at all, which is what a single-key
    /// issuer's tokens look like; a set with more than one does not guess.
    pub fn find(self: *const Keys, kid: ?[]const u8) ?Key {
        if (kid) |want| {
            for (self.all) |key| {
                if (std.mem.eql(u8, key.kid, want)) return key;
            }
            return null;
        }
        if (self.all.len == 1) return self.all[0];
        return null;
    }
};

/// What `std.json` is asked for. Every field is optional because a key set is
/// somebody else's document and the fields nilo does not use are the ones
/// most likely to be missing or to be a shape nilo did not expect.
const Document = struct {
    keys: []const Entry = &.{},

    const Entry = struct {
        kty: ?[]const u8 = null,
        alg: ?[]const u8 = null,
        use: ?[]const u8 = null,
        kid: ?[]const u8 = null,
        n: ?[]const u8 = null,
        e: ?[]const u8 = null,
    };
};

/// Read a JWKS document. The result owns its own memory and outlives `bytes`.
pub fn parse(gpa: std.mem.Allocator, bytes: []const u8) Error!Keys {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    const doc = std.json.parseFromSliceLeaky(Document, alloc, bytes, .{
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NotAKeySet,
    };

    var kept: std.ArrayList(Key) = .empty;
    for (doc.keys) |entry| {
        // Anything that is not an RSA signing key is another key type in the
        // same document, not a malformed one.
        const kty = entry.kty orelse continue;
        if (!std.mem.eql(u8, kty, "RSA")) continue;
        if (entry.use) |use| if (!std.mem.eql(u8, use, "sig")) continue;
        if (entry.alg) |alg| if (!std.mem.eql(u8, alg, "RS256")) continue;

        // Past here it *said* it was an RSA signing key, so a missing or
        // unreadable integer is the document being wrong rather than a key
        // nilo does not handle.
        const n_text = entry.n orelse return error.KeyNotUsable;
        const e_text = entry.e orelse return error.KeyNotUsable;
        const n = b64.keep(alloc, n_text) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NotBase64Url => return error.KeyNotUsable,
        };
        const e = b64.keep(alloc, e_text) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NotBase64Url => return error.KeyNotUsable,
        };

        try kept.append(alloc, .{ .kid = entry.kid orelse "", .e = e, .n = n });
    }

    return .{ .all = try kept.toOwnedSlice(alloc), .arena = arena };
}

const testing = std.testing;

test "an EC key beside an RSA one is skipped, not refused" {
    var keys = try parse(testing.allocator,
        \\{"keys":[
        \\  {"kty":"EC","crv":"P-256","kid":"ec","x":"aa","y":"bb"},
        \\  {"kty":"RSA","alg":"RS256","use":"sig","kid":"rsa","n":"-_8","e":"AQAB"}
        \\]}
    );
    defer keys.deinit();

    try testing.expectEqual(@as(usize, 1), keys.all.len);
    try testing.expectEqualStrings("rsa", keys.all[0].kid);
    try testing.expectEqualSlices(u8, &.{ 0x01, 0x00, 0x01 }, keys.all[0].e);
}

test "a kid that is not in the set finds nothing" {
    var keys = try parse(testing.allocator,
        \\{"keys":[{"kty":"RSA","kid":"one","n":"-_8","e":"AQAB"}]}
    );
    defer keys.deinit();

    try testing.expect(keys.find("two") == null);
    try testing.expect(keys.find("one") != null);
}

test "one key answers for a token with no kid, and two do not" {
    var one = try parse(testing.allocator,
        \\{"keys":[{"kty":"RSA","kid":"a","n":"-_8","e":"AQAB"}]}
    );
    defer one.deinit();
    try testing.expect(one.find(null) != null);

    var two = try parse(testing.allocator,
        \\{"keys":[
        \\  {"kty":"RSA","kid":"a","n":"-_8","e":"AQAB"},
        \\  {"kty":"RSA","kid":"b","n":"-_8","e":"AQAB"}
        \\]}
    );
    defer two.deinit();
    try testing.expect(two.find(null) == null);
}

test "an RSA key with no modulus is the document being wrong" {
    try testing.expectError(error.KeyNotUsable, parse(testing.allocator,
        \\{"keys":[{"kty":"RSA","kid":"a","e":"AQAB"}]}
    ));
}

test "bytes that are not a key set at all" {
    try testing.expectError(error.NotAKeySet, parse(testing.allocator, "not json"));
}

test "a key set with no keys parses to nothing rather than failing" {
    var keys = try parse(testing.allocator, "{\"keys\":[]}");
    defer keys.deinit();
    try testing.expectEqual(@as(usize, 0), keys.all.len);
    try testing.expect(keys.find(null) == null);
}
