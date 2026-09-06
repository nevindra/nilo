//! nilo_jwt — checking somebody else's signed token, and nothing that needs a
//! loop ([ADR 0140](../docs/adr/0140-nilo-verifies-a-token-and-does-not-fetch-one.md)).
//!
//! A **tool module**: one job, no event loop, and it imports nothing at all,
//! which is why `zig test jwt/jwt.zig` runs the whole of it (ADR 0042).
//!
//! ```zig
//! const jwt = @import("nilo_jwt");
//!
//! const Claims = struct {
//!     sub: []const u8,
//!     email: []const u8,
//!     email_verified: bool,
//! };
//!
//! var keys = try jwt.parseKeys(gpa, jwks_json);
//! defer keys.deinit();
//!
//! const claims = try jwt.verify(Claims, c.arena(), id_token, .{
//!     .keys = &keys,
//!     .issuer = "https://accounts.google.com",
//!     .audience = client_id,
//!     .now_s = @divFloor(nilo.nowMillis(), 1000),   // any clock you like
//! });
//! ```
//!
//! **nilo verifies a token and does not fetch one.** The JWKS fetch is an
//! HTTPS GET, which `nilo_fetch` already sends; holding the answer is
//! `nilo_cache`; when to refresh it is a policy, and policy is the caller's
//! the way it is everywhere else here. What a caller cannot already write
//! safely is this module — and the reason is the same one that justifies
//! `nilo_pw` when `std.crypto.argon2` is right there. A password hash written
//! subtly wrong runs perfectly and leaks; a token check written subtly wrong
//! is worse on exactly that axis. Skip the `alg` comparison, skip the `kid`
//! match, skip `aud`, get the DigestInfo prefix wrong, and every test passes
//! while the endpoint is open.
//!
//! So the three that are easiest to get wrong are not options:
//!
//! - **The algorithm is a constant in this file, never the token's `alg`.**
//!   `{"alg":"none"}` and an HMAC signed with the published RSA modulus are
//!   both refused before a key is looked up.
//! - **Nothing in the payload is read until the signature has passed.** An
//!   `exp` off an unverified token is a number somebody chose.
//!   `exp` is required, because a credential with no end is not one.
//! - **`iss` and `aud` are checked whenever you name them**, and the claims
//!   struct does not have to mention either.
//!
//! **The arithmetic is `std.crypto.Certificate.rsa`'s**, which is public in
//! Zig 0.16 and is the code that verifies a TLS certificate chain. This
//! module writes no RSA. What it adds is the switch over key sizes, because
//! `modulus_len` is a comptime parameter there and a run-time length here.
//!
//! **What it does not do**: HS256 and the EC families, encrypted tokens
//! (JWE), signing, discovery, PKCE, and the nonce. Signing is not here
//! because a server that issues its own sessions has `Session(T)` sealed into
//! a cookie (ADR 0035) and does not need a token; the rest is the sign-in
//! flow, which is the caller's.
//!
//! **Everything about time is an argument**, for the reason `nilo_id` takes a
//! millisecond as one (ADR 0042): a module with no event loop has no clock,
//! and a test that cannot choose the time cannot test an expiry.

const std = @import("std");

const jwks = @import("jwks.zig");
const rs256 = @import("rs256.zig");
const token_mod = @import("token.zig");

/// A JWKS document read into the keys that can be verified with. `parse`
/// takes the bytes of the document; fetching them is the caller's.
pub const Keys = jwks.Keys;

/// One RSA public key out of a key set.
pub const Key = jwks.Key;

/// What `verify` is told: the keys, the issuer and audience to insist on,
/// and what time it is.
pub const Options = token_mod.Options;

/// Everything `verify` can answer instead of claims.
pub const Error = token_mod.Error;

/// Read a JWKS document. The result owns its memory; `deinit` frees it.
pub const parseKeys = jwks.parse;

/// Verify a token and read its payload into a struct of your own. Strings in
/// the result point into `gpa`, so a request arena leaves nothing to free.
pub const verify = token_mod.verify;

/// The key sizes that have a branch, in bytes of modulus: 2048, 3072 and
/// 4096 bits. A key outside them is `error.KeySizeNotSupported` rather than
/// a best effort.
pub const key_sizes = rs256.sizes;

test {
    _ = @import("b64.zig");
    _ = jwks;
    _ = rs256;
    _ = token_mod;
}

test "the module's own example compiles and reads a token end to end" {
    const vector = @import("vector.zig");
    const Claims = struct { sub: []const u8, email: []const u8 };

    var keys = try parseKeys(std.testing.allocator, vector.jwks);
    defer keys.deinit();

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const claims = try verify(Claims, arena.allocator(), vector.token, .{
        .keys = &keys,
        .issuer = "https://accounts.example",
        .audience = "client-1",
        .now_s = 1_500_000_000,
    });
    try std.testing.expectEqualStrings("u-7", claims.sub);
}
