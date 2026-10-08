//! nilo_jwt: an RS256 token checked against a key set read once, with the
//! issuer, the audience and the expiry all checked and the claims read back,
//! which is what a sign-in with somebody else's identity provider costs.
//!
//! The token and the key are the module's own test vector (`jwt/vector.zig`),
//! signed by another implementation. The set holds the RSA key alone, so a
//! ref that predates ES256 reads the same set as one that has it.

const std = @import("std");
const jwt = @import("nilo_jwt");
const harness = @import("harness");

pub fn main(init: std.process.Init.Minimal) !void {
    return harness.run(init, Program);
}

/// Payload `{"iss":"https://accounts.example","aud":"client-1","sub":"u-7",
/// "email":"a@example.com","exp":2000000000,"nbf":1000000000}`.
const token =
    "eyJhbGciOiJSUzI1NiIsImtpZCI6InRlc3Qta2V5IiwidHlwIjoiSldUIn0.eyJpc3MiOiJodHRwczovL2FjY2" ++
    "91bnRzLmV4YW1wbGUiLCJhdWQiOiJjbGllbnQtMSIsInN1YiI6InUtNyIsImVtYWlsIjoiYUBleGFtcGxlLmNv" ++
    "bSIsImV4cCI6MjAwMDAwMDAwMCwibmJmIjoxMDAwMDAwMDAwfQ.AcbsMWT1PLcxeCcSGyy0huOFwmr2veRJJNv" ++
    "aLBP2UBsI2Y7_F6-CYF0z6wSahQU5wtFSnR7-ebRGWTpar5J1qFVVg9_XJ4FqhA2R1VmtxijbOXYJkJHQQtuTK" ++
    "eRv_AicyxI0oFudf495-reWHHKjBCQJj65Zp-Jd51AqsLpk_jTDZD8NeWRwsXVH-wuofPrb7mKkgsEFIFdAfs2" ++
    "ioGPJVI-sdbN7lSKD22UNC2_XWqLCiF50v7rHNJUmVYeozKr2FvTMiF51wh6OGJZ3XUSzDLTXLr80cqDV9__d1" ++
    "nQ-VcVWFc8uyNXQChdhihk3GCOjsz3ty6-aIwhEcVvi1lBcvw";

const rsa_n =
    "tBFYa_IZgELJqUxuRyKGQDsWWYVZO0GHU2VoZzGs8ALOaNcUbtCa50wrUo0cG8BBa069mmo_meOs0IsqOsZCZw4t" ++
    "14l8SwHLd2mNthp69GO4djVqC586QAKJ1I8Ngn_uwTDxru9jONNAzu2F1fKiHCZMyD8_QupubOQXlDWLAqk0VHA" ++
    "byoEwjdCZhoXCxjuSa8xfdZxOMeiRMrtPbDhIiSJWlRjm3UBMXJXehIuLf1zH9jGtb3PuAPK4IB_JMh0IT-4t28" ++
    "bQKxJwUWixCUirVvCI4RQFjjgpIoJn7k4cFWOEFgaejyzqP7mt_mvsqws3rVEuUaViHs6hkbZ_ateTew";

const jwks =
    "{\"keys\":[{\"kty\":\"RSA\",\"alg\":\"RS256\",\"use\":\"sig\",\"kid\":\"test-key\",\"n\":\"" ++
    rsa_n ++ "\",\"e\":\"AQAB\"}]}";

const Claims = struct { sub: []const u8, email: []const u8 };

const Program = struct {
    keys: jwt.Keys,

    pub fn init(gpa: std.mem.Allocator) !Program {
        return .{ .keys = try jwt.parseKeys(gpa, jwks) };
    }

    pub fn deinit(self: *Program) void {
        self.keys.deinit();
    }

    pub fn op(self: *Program, scratch: std.mem.Allocator, _: usize) !void {
        // Behind `keep`, so the optimiser cannot see into the token.
        var presented: []const u8 = token;
        harness.keep(&presented);
        const claims = try jwt.verify(Claims, scratch, presented, .{
            .keys = &self.keys,
            .issuer = .{ .is = "https://accounts.example" },
            .audience = .{ .is = "client-1" },
            // Inside the token's life: after its nbf, before its exp.
            .now_s = 1_759_300_000,
        });
        harness.keep(claims.sub.len);
        harness.keep(claims.email.len);
    }
};
