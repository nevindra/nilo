//! ECDSA over P-256 with SHA-256 — ES256 — over a public key given as the
//! two coordinates a JWKS carries.
//!
//! **Everything hard here is `std.crypto.sign.ecdsa.EcdsaP256Sha256`'s**:
//! `PublicKey.fromSec1` for the key, `Signature.fromBytes` for the
//! signature, `Signature.verify` for the arithmetic. This file writes none
//! of that. What it adds is the three refusals in front of it — the curve,
//! the coordinate length, the signature length — because "verified" and
//! "did not check" have to be different answers (ADR 111), and the one
//! fact that a first attempt at this gets wrong:
//!
//! **A JWS signature is raw `r || s`, sixty-four bytes, and not DER.** Every
//! other place an ECDSA signature turns up — a certificate, `openssl dgst`,
//! a `.sig` file — it is the DER `SEQUENCE { INTEGER r, INTEGER s }`, seventy
//! bytes or so with a variable length. RFC 7518 §3.4 says a JWS carries the
//! two integers back to back, each padded to the curve's width. So the
//! decoder here is `Signature.fromBytes` and never `fromDer`, and a DER
//! signature arrives as `error.SignatureWrongLength` rather than as a
//! `BadSignature` somebody spends an afternoon on ([ADR 111](../docs/adr/111-nilo-verifies-a-token-and-does-not-fetch-one.md)).
//!
//! **Which key type this is for is the key's business, not the token's.**
//! `token.zig` calls this because the key it found says `EC`, and only after
//! the header's `alg` has been compared against what such a key answers to.

const std = @import("std");
const Ecdsa = std.crypto.sign.ecdsa.EcdsaP256Sha256;

pub const Error = error{
    /// The key's `crv` is not `P-256`. A curve with no branch is an error
    /// rather than a best effort, the way an RSA size with no branch is.
    CurveNotSupported,
    /// The signature is not sixty-four bytes, so it cannot be `r || s` on
    /// this curve. A DER signature lands here.
    SignatureWrongLength,
    /// A coordinate is not thirty-two bytes, or the two together are not a
    /// point on the curve.
    KeyNotUsable,
    /// The key is fine, the signature is not the signature of this message.
    BadSignature,
};

/// The curves that get a branch. P-256 is what Supabase, Apple and every
/// other ES256 issuer this was checked against publishes; a JWKS `crv` that
/// is not on this list is `error.CurveNotSupported`.
pub const curves = [_][]const u8{"P-256"};

/// One coordinate of a P-256 point, in bytes. `x` and `y` are each this.
pub const coordinate_len = 32;

/// `r || s` on P-256: two coordinates' worth.
pub const signature_len = 2 * coordinate_len;

/// `signed` is the first two segments of the token with the dot still between
/// them — the bytes the issuer hashed. `crv`, `x` and `y` are the key's,
/// exactly as they come out of a JWKS after base64url.
pub fn verify(signed: []const u8, sig: []const u8, crv: []const u8, x: []const u8, y: []const u8) Error!void {
    if (!std.mem.eql(u8, crv, curves[0])) return error.CurveNotSupported;
    if (x.len != coordinate_len or y.len != coordinate_len) return error.KeyNotUsable;
    if (sig.len != signature_len) return error.SignatureWrongLength;

    // SEC1 uncompressed: 0x04, then x, then y. sixty-five bytes on the
    // stack and nothing allocated.
    var sec1: [1 + 2 * coordinate_len]u8 = undefined;
    sec1[0] = 0x04;
    @memcpy(sec1[1 .. 1 + coordinate_len], x);
    @memcpy(sec1[1 + coordinate_len ..], y);
    const key = Ecdsa.PublicKey.fromSec1(&sec1) catch return error.KeyNotUsable;

    // `fromBytes`, not `fromDer` — see the header.
    const signature = Ecdsa.Signature.fromBytes(sig[0..signature_len].*);
    signature.verify(signed, key) catch |err| switch (err) {
        // An r or s of zero, or one past the group order, is a signature
        // that could not have been made; it is refused as one that was not.
        error.SignatureVerificationFailed,
        error.IdentityElement,
        error.NonCanonical,
        => return error.BadSignature,
    };
}

const testing = std.testing;
const b64 = @import("b64.zig");
const vector = @import("vector.zig");

test "a curve with no branch is refused rather than guessed" {
    const x = @as([48]u8, @splat(0x01));
    const sig = @as([96]u8, @splat(0));
    try testing.expectError(error.CurveNotSupported, verify("a.b", &sig, "P-384", &x, &x));
}

test "a signature that is not r || s on this curve is refused by its length" {
    const x = @as([32]u8, @splat(0x01));
    const der_shaped = @as([71]u8, @splat(0));
    try testing.expectError(error.SignatureWrongLength, verify("a.b", &der_shaped, "P-256", &x, &x));
}

test "a coordinate that is not thirty-two bytes is not a key" {
    const short = @as([31]u8, @splat(0x01));
    const full = @as([32]u8, @splat(0x01));
    const sig = @as([64]u8, @splat(0));
    try testing.expectError(error.KeyNotUsable, verify("a.b", &sig, "P-256", &short, &full));
    try testing.expectError(error.KeyNotUsable, verify("a.b", &sig, "P-256", &full, &short));
}

test "two coordinates that are not a point on the curve are not a key" {
    // x = y = 1 is not on P-256, and `fromSec1` says so.
    const one = @as([31]u8, @splat(0)) ++ [_]u8{0x01};
    const sig = @as([64]u8, @splat(0x01));
    try testing.expectError(error.KeyNotUsable, verify("a.b", &sig, "P-256", &one, &one));
}

test "the RFC's own ES256 example verifies here, and one bit off does not" {
    const gpa = testing.allocator;
    const x = try b64.keep(gpa, vector.es256_x);
    defer gpa.free(x);
    const y = try b64.keep(gpa, vector.es256_y);
    defer gpa.free(y);
    const sig = try b64.keep(gpa, vector.es256_signature);
    defer gpa.free(sig);

    const signed = vector.es256_header ++ "." ++ vector.es256_payload;
    try verify(signed, sig, "P-256", x, y);

    sig[10] ^= 0x01;
    try testing.expectError(error.BadSignature, verify(signed, sig, "P-256", x, y));
}

test "an r or s of zero is a bad signature rather than a crash" {
    const gpa = testing.allocator;
    const x = try b64.keep(gpa, vector.es256_x);
    defer gpa.free(x);
    const y = try b64.keep(gpa, vector.es256_y);
    defer gpa.free(y);

    const zeros = @as([64]u8, @splat(0));
    try testing.expectError(error.BadSignature, verify("a.b", &zeros, "P-256", x, y));
}
