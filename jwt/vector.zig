//! One RSA key, one token signed with it, generated once and pinned here.
//!
//! Signed by somebody else's implementation on purpose. A vector produced by
//! the code under test only proves the code agrees with itself; this one was
//! made by a library that has verified against the RFC's own examples, so the
//! DigestInfo prefix and the PKCS#1 padding are being checked rather than
//! restated.
//!
//! The payload is `{"iss":"https://accounts.example","aud":"client-1",
//! "sub":"u-7","email":"a@example.com","exp":2000000000,"nbf":1000000000}`,
//! and the key set carries an EC key in front of the RSA one, so the skipping
//! is exercised by every test that reads it.
//!
//! **The private key was thrown away.** Nothing here signs anything, and
//! there is nothing in this file that could.

/// The whole token: header, payload, signature.
pub const token =
    "eyJhbGciOiJSUzI1NiIsImtpZCI6InRlc3Qta2V5IiwidHlwIjoiSldUIn0.eyJpc3MiOiJodHRwczovL2FjY2"
     ++ "91bnRzLmV4YW1wbGUiLCJhdWQiOiJjbGllbnQtMSIsInN1YiI6InUtNyIsImVtYWlsIjoiYUBleGFtcGxlLmNv"
     ++ "bSIsImV4cCI6MjAwMDAwMDAwMCwibmJmIjoxMDAwMDAwMDAwfQ.AcbsMWT1PLcxeCcSGyy0huOFwmr2veRJJNv"
     ++ "aLBP2UBsI2Y7_F6-CYF0z6wSahQU5wtFSnR7-ebRGWTpar5J1qFVVg9_XJ4FqhA2R1VmtxijbOXYJkJHQQtuTK"
     ++ "eRv_AicyxI0oFudf495-reWHHKjBCQJj65Zp-Jd51AqsLpk_jTDZD8NeWRwsXVH-wuofPrb7mKkgsEFIFdAfs2"
     ++ "ioGPJVI-sdbN7lSKD22UNC2_XWqLCiF50v7rHNJUmVYeozKr2FvTMiF51wh6OGJZ3XUSzDLTXLr80cqDV9__d1"
     ++ "nQ-VcVWFc8uyNXQChdhihk3GCOjsz3ty6-aIwhEcVvi1lBcvw";

/// The middle segment on its own, for the forged-header tests.
pub const payload =
    "eyJpc3MiOiJodHRwczovL2FjY291bnRzLmV4YW1wbGUiLCJhdWQiOiJjbGllbnQtMSIsInN1YiI6InUtNyIsIm"
     ++ "VtYWlsIjoiYUBleGFtcGxlLmNvbSIsImV4cCI6MjAwMDAwMDAwMCwibmJmIjoxMDAwMDAwMDAwfQ";

/// The issuer's key set, as it would come back from a JWKS endpoint.
pub const jwks =
    "{\"keys\":[{\"kty\":\"EC\",\"crv\":\"P-256\",\"kid\":\"an-ec-key\",\"x\":\"aaaa\",\"y\":\"bbbb\"},{\"kty\":\"RS"
     ++ "A\",\"alg\":\"RS256\",\"use\":\"sig\",\"kid\":\"test-key\",\"n\":\"tBFYa_IZgELJqUxuRyKGQDsWWYVZO0GHU2V"
     ++ "oZzGs8ALOaNcUbtCa50wrUo0cG8BBa069mmo_meOs0IsqOsZCZw4t14l8SwHLd2mNthp69GO4djVqC586QAKJ1"
     ++ "I8Ngn_uwTDxru9jONNAzu2F1fKiHCZMyD8_QupubOQXlDWLAqk0VHAbyoEwjdCZhoXCxjuSa8xfdZxOMeiRMrt"
     ++ "PbDhIiSJWlRjm3UBMXJXehIuLf1zH9jGtb3PuAPK4IB_JMh0IT-4t28bQKxJwUWixCUirVvCI4RQFjjgpIoJn7"
     ++ "k4cFWOEFgaejyzqP7mt_mvsqws3rVEuUaViHs6hkbZ_ateTew\",\"e\":\"AQAB\"}]}";
