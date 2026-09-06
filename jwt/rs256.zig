//! RSASSA-PKCS1-v1_5 with SHA-256, over a public key given as the two big
//! integers a JWKS carries.
//!
//! **Everything hard here is `std.crypto.Certificate.rsa`'s**, which is public
//! in Zig 0.16 and is the same code that verifies a TLS certificate chain:
//! `PublicKey.fromBytes` for the key, `PKCS1v1_5Signature.verify` for the
//! signature, and the DigestInfo prefix table that goes with the hash. This
//! file writes none of that. What it adds is the one thing the std API cannot
//! do on its own — `modulus_len` is a comptime parameter there and a run-time
//! length here, because the modulus arrives inside a JSON document — so the
//! whole of this module is a switch over the three sizes anybody issues.
//!
//! **Refusing a size is the point of the `else`.** A key nilo does not have a
//! branch for is an error rather than a best effort, because "verified" and
//! "did not check" have to be different answers (ADR 0140).

const std = @import("std");
const rsa = std.crypto.Certificate.rsa;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Error = error{
    /// The modulus is not 2048, 3072 or 4096 bits.
    KeySizeNotSupported,
    /// The signature is not as long as the modulus, so it cannot be one.
    SignatureWrongLength,
    /// The exponent or the modulus is not a number this can use — an
    /// exponent over 32 bits, an even one, or a modulus under 512 bits.
    KeyNotUsable,
    /// The key is fine, the signature is not the signature of this message.
    BadSignature,
};

/// The sizes that get a branch. 2048 is what Google, Auth0, Okta and every
/// other issuer this was checked against uses; 3072 and 4096 are here so a
/// deployment that rotated up does not meet an error message.
pub const sizes = [_]usize{ 256, 384, 512 };

/// `signed` is the first two segments of the token with the dot still between
/// them — the bytes the issuer hashed. `e` and `n` are the exponent and the
/// modulus, big-endian, exactly as they come out of a JWKS after base64url.
pub fn verify(signed: []const u8, sig: []const u8, e: []const u8, n: []const u8) Error!void {
    const key = rsa.PublicKey.fromBytes(e, n) catch return error.KeyNotUsable;

    // `n` may carry a leading zero byte where the encoder kept the sign bit;
    // the signature never does, so the signature is what the length is taken
    // from and the modulus only has to be long enough to hold it.
    inline for (sizes) |len| {
        if (sig.len == len) {
            if (n.len < len) return error.KeyNotUsable;
            return rsa.PKCS1v1_5Signature.verify(
                len,
                sig[0..len].*,
                signed,
                key,
                Sha256,
            ) catch |err| switch (err) {
                error.InvalidSignature => error.BadSignature,
                error.MessageTooLong => error.KeyNotUsable,
            };
        }
    }

    // Tell the two apart: a key nilo has no branch for, versus a signature
    // that is not the length of the key it came with.
    for (sizes) |len| if (n.len == len or n.len == len + 1) return error.SignatureWrongLength;
    return error.KeySizeNotSupported;
}

test "a key size with no branch is refused rather than guessed" {
    const n = [_]u8{0xff} ** 128; // 1024 bits
    const e = [_]u8{ 0x01, 0x00, 0x01 };
    const sig = [_]u8{0} ** 128;
    try std.testing.expectError(error.KeySizeNotSupported, verify("a.b", &sig, &e, &n));
}

test "a signature that is not as long as its key is refused" {
    const n = [_]u8{0xff} ** 256;
    const e = [_]u8{ 0x01, 0x00, 0x01 };
    const sig = [_]u8{0} ** 200;
    try std.testing.expectError(error.SignatureWrongLength, verify("a.b", &sig, &e, &n));
}

test "an even exponent is not a key" {
    const n = [_]u8{0xff} ** 256;
    const e = [_]u8{ 0x01, 0x00, 0x02 };
    const sig = [_]u8{0} ** 256;
    try std.testing.expectError(error.KeyNotUsable, verify("a.b", &sig, &e, &n));
}
