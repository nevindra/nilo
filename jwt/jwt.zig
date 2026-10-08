//! nilo_jwt — checking somebody else's signed token, and nothing that needs a
//! loop ([ADR 111](../docs/adr/111-nilo-verifies-a-token-and-does-not-fetch-one.md)).
//!
//! A **tool module**: one job, no event loop, and it imports nothing at all,
//! which is why `zig test jwt/jwt.zig` runs the whole of it (ADR 038).
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
//!     .issuer = .{ .is = "https://accounts.google.com" },
//!     .audience = .{ .is = client_id },
//!     .now_s = @divFloor(nilo.nowMillis(), 1000),   // any clock you like
//! });
//! ```
//!
//! **nilo verifies a token and does not fetch one.** The JWKS fetch is an
//! HTTPS GET, which `nilo_fetch` already sends, and a `Keyring` borrows that
//! client through a parameter to hold the answer and swap it under readers
//! without a race — the one part of a rotation that is concurrency rather
//! than policy (ADR 111). When to refresh is still the caller's, the way
//! policy is everywhere else here. What a caller cannot already write
//! safely is this module — and the reason is the same one that justifies
//! `nilo_pw` when `std.crypto.argon2` is right there. A password hash written
//! subtly wrong runs perfectly and leaks; a token check written subtly wrong
//! is worse on exactly that axis. Skip the `alg` comparison, skip the `kid`
//! match, skip `aud`, get the DigestInfo prefix wrong, and every test passes
//! while the endpoint is open.
//!
//! So the three that are easiest to get wrong are not options:
//!
//! - **The algorithm is the key's, never the token's `alg`.** Two are read:
//!   RS256 for a JWKS key that says `RSA`, ES256 for one that says `EC` on
//!   `P-256`. Which one runs is decided by the key the `kid` found, and the
//!   header's `alg` is only compared — against the two names before a key is
//!   looked up, so `{"alg":"none"}` and an HMAC signed with the published
//!   RSA modulus are refused before anything else, and against the key's
//!   own name after, so `ES256` over an RSA key is a mismatch and not a
//!   request (ADR 111).
//! - **Nothing in the payload is read until the signature has passed.** An
//!   `exp` off an unverified token is a number somebody chose.
//!   `exp` is required, because a credential with no end is not one.
//! - **`iss` and `aud` are checked, and you say what for.** Neither has a
//!   default, so a call that forgets one does not compile, and skipping one
//!   is `.unchecked` on the line that builds the options. The claims struct
//!   does not have to mention either (ADR 111).
//!
//! **The arithmetic is std's.** RS256 is `std.crypto.Certificate.rsa`, which
//! is public in Zig 0.16 and is the code that verifies a TLS certificate
//! chain; ES256 is `std.crypto.sign.ecdsa.EcdsaP256Sha256`. This module
//! writes no RSA and no ECDSA. What it adds is the switch over RSA key
//! sizes, because `modulus_len` is a comptime parameter there and a run-time
//! length here, and the one fact about a JWS signature std cannot know: it
//! is raw `r || s`, not DER.
//!
//! **What it does not do**: HS256, any curve but P-256, encrypted tokens
//! (JWE), signing, discovery, PKCE, and the nonce. Signing is not here
//! because a server that issues its own sessions has `Session(T)` sealed into
//! a cookie (ADR 033) and does not need a token; the rest is the sign-in
//! flow, which is the caller's.
//!
//! **Everything about time is an argument**, for the reason `nilo_id` takes a
//! millisecond as one (ADR 038): a module with no event loop has no clock,
//! and a test that cannot choose the time cannot test an expiry.

const std = @import("std");

const jwks = @import("jwks.zig");
const rs256 = @import("rs256.zig");
const es256 = @import("es256.zig");
const token_mod = @import("token.zig");
const keyring_mod = @import("keyring.zig");
const verifier_mod = @import("verifier.zig");

/// A JWKS document read into the keys that can be verified with. `parse`
/// takes the bytes of the document; fetching them is the caller's.
pub const Keys = jwks.Keys;

/// One public key out of a key set: its `kid`, and its `material` — `.rsa`
/// with `e` and `n`, or `.ec` with `crv`, `x` and `y`. Which of the two it
/// is decides how a token under it is checked.
pub const Key = jwks.Key;

/// What `verify` is told: the keys, the issuer and audience to insist on,
/// and what time it is.
pub const Options = token_mod.Options;

/// What `issuer` and `audience` are set to: `.{ .is = "…" }` to insist on a
/// value, `.unchecked` to say the check is not wanted. There is no default
/// and no `null`, so forgetting is a compile error.
pub const Expect = token_mod.Expect;

/// Everything `verify` can answer instead of claims.
pub const Error = token_mod.Error;

/// Read a JWKS document. The result owns its memory; `deinit` frees it.
pub const parseKeys = jwks.parse;

/// A key set that rotates under its readers: `load` swaps a new document
/// in and frees the old one after the verifies reading it are done, and
/// `verifyOrRefresh` fetches on an unknown `kid` at most once an interval
/// ([ADR 111](../docs/adr/111-nilo-verifies-a-token-and-does-not-fetch-one.md)).
/// The client is a parameter, so the module still imports nothing.
pub const Keyring = keyring_mod.Keyring;

/// A ring, the client its refresh needs and a claims type, as one Service —
/// what `nilo.Verified(T)` names to hand a handler the claims behind a
/// bearer token, or a 401 before it runs
/// ([ADR 191](../docs/adr/191-verified-claims-are-a-handler-argument.md)).
/// The client is a type parameter, so the module still imports nothing.
pub const Verifier = verifier_mod.Verifier;

/// The signature memo a ring keeps when asked to (`remember_tokens`);
/// exported for a program that verifies with `jwt.verify` and its own keys.
pub const Memo = @import("memo.zig").Memo;

/// Verify a token and read its payload into a struct of your own. Strings in
/// the result point into `gpa`, so a request arena leaves nothing to free.
pub const verify = token_mod.verify;

/// The key sizes that have a branch, in bytes of modulus: 2048, 3072 and
/// 4096 bits. A key outside them is `error.KeySizeNotSupported` rather than
/// a best effort.
pub const key_sizes = rs256.sizes;

/// The curves that have a branch: `P-256`, and only that. An EC key on
/// another curve is `error.CurveNotSupported` rather than a best effort.
pub const curves = es256.curves;

test {
    _ = @import("b64.zig");
    _ = jwks;
    _ = rs256;
    _ = es256;
    _ = token_mod;
    _ = keyring_mod;
    _ = verifier_mod;
    _ = @import("memo.zig");
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
        .issuer = .{ .is = "https://accounts.example" },
        .audience = .{ .is = "client-1" },
        .now_s = 1_500_000_000,
    });
    try std.testing.expectEqualStrings("u-7", claims.sub);
}

test "an ES256 token reads end to end the same way, off the key's type alone" {
    const vector = @import("vector.zig");
    const Claims = struct { iss: []const u8 };

    var keys = try parseKeys(std.testing.allocator, vector.es256_jwks);
    defer keys.deinit();

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const claims = try verify(Claims, arena.allocator(), vector.es256_token, .{
        .keys = &keys,
        .issuer = .{ .is = "joe" },
        .audience = .unchecked,
        .now_s = 1_300_000_000,
    });
    try std.testing.expectEqualStrings("joe", claims.iss);
}
