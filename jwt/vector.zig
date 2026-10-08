//! One RSA key, one EC key, and a token signed with each — generated or
//! published elsewhere, and pinned here.
//!
//! Signed by somebody else's implementation on purpose. A vector produced by
//! the code under test only proves the code agrees with itself; these were
//! made by a library that has verified against the RFC's own examples, and
//! by the RFC itself, so the DigestInfo prefix, the PKCS#1 padding and the
//! `r || s` layout are being checked rather than restated.
//!
//! The RS256 payload is `{"iss":"https://accounts.example","aud":"client-1",
//! "sub":"u-7","email":"a@example.com","exp":2000000000,"nbf":1000000000}`.
//! The ES256 vector is RFC 7515 Appendix A.3 verbatim — header
//! `{"alg":"ES256"}`, payload `{"iss":"joe", "exp":1300819380,
//! "http://example.com/is_root":true}` with the RFC's own line breaks, and
//! the public half of the key in A.3.1 — and it was re-checked against an
//! independent P-256 before being pinned.
//!
//! The mixed key set carries an OKP key in front of the other two, so the
//! skipping is exercised by every test that reads it. Ed25519 is the right
//! stand-in for "a type nilo cannot read" because it is the one that will
//! stay unreadable: the EC key that used to sit there was read the moment
//! ES256 landed.
//!
//! **The private keys were thrown away**, or in the RFC's case were never
//! anybody's. Nothing here signs anything, and there is nothing in this
//! file that could.

/// The whole RS256 token: header, payload, signature.
pub const token =
    "eyJhbGciOiJSUzI1NiIsImtpZCI6InRlc3Qta2V5IiwidHlwIjoiSldUIn0.eyJpc3MiOiJodHRwczovL2FjY2" ++ "91bnRzLmV4YW1wbGUiLCJhdWQiOiJjbGllbnQtMSIsInN1YiI6InUtNyIsImVtYWlsIjoiYUBleGFtcGxlLmNv" ++ "bSIsImV4cCI6MjAwMDAwMDAwMCwibmJmIjoxMDAwMDAwMDAwfQ.AcbsMWT1PLcxeCcSGyy0huOFwmr2veRJJNv" ++ "aLBP2UBsI2Y7_F6-CYF0z6wSahQU5wtFSnR7-ebRGWTpar5J1qFVVg9_XJ4FqhA2R1VmtxijbOXYJkJHQQtuTK" ++ "eRv_AicyxI0oFudf495-reWHHKjBCQJj65Zp-Jd51AqsLpk_jTDZD8NeWRwsXVH-wuofPrb7mKkgsEFIFdAfs2" ++ "ioGPJVI-sdbN7lSKD22UNC2_XWqLCiF50v7rHNJUmVYeozKr2FvTMiF51wh6OGJZ3XUSzDLTXLr80cqDV9__d1" ++ "nQ-VcVWFc8uyNXQChdhihk3GCOjsz3ty6-aIwhEcVvi1lBcvw";

/// The RS256 token's middle segment on its own, for the forged-header tests.
pub const payload =
    "eyJpc3MiOiJodHRwczovL2FjY291bnRzLmV4YW1wbGUiLCJhdWQiOiJjbGllbnQtMSIsInN1YiI6InUtNyIsIm" ++ "VtYWlsIjoiYUBleGFtcGxlLmNvbSIsImV4cCI6MjAwMDAwMDAwMCwibmJmIjoxMDAwMDAwMDAwfQ";

/// The RS256 token's last segment on its own, for a forged header over a
/// real signature.
pub const signature =
    "AcbsMWT1PLcxeCcSGyy0huOFwmr2veRJJNvaLBP2UBsI2Y7_F6-CYF0z6wSahQU5wtFSnR7-ebRGWTpar5J1qFVVg9_" ++ "XJ4FqhA2R1VmtxijbOXYJkJHQQtuTKeRv_AicyxI0oFudf495-reWHHKjBCQJj65Zp-Jd51AqsLpk_jTDZD8NeWR" ++ "wsXVH-wuofPrb7mKkgsEFIFdAfs2ioGPJVI-sdbN7lSKD22UNC2_XWqLCiF50v7rHNJUmVYeozKr2FvTMiF51wh6" ++ "OGJZ3XUSzDLTXLr80cqDV9__d1nQ-VcVWFc8uyNXQChdhihk3GCOjsz3ty6-aIwhEcVvi1lBcvw";

/// The RSA key's `n`, as the JWKS spells it.
pub const rsa_n =
    "tBFYa_IZgELJqUxuRyKGQDsWWYVZO0GHU2VoZzGs8ALOaNcUbtCa50wrUo0cG8BBa069mmo_meOs0IsqOsZCZw4t" ++ "14l8SwHLd2mNthp69GO4djVqC586QAKJ1I8Ngn_uwTDxru9jONNAzu2F1fKiHCZMyD8_QupubOQXlDWLAqk0VHA" ++ "byoEwjdCZhoXCxjuSa8xfdZxOMeiRMrtPbDhIiSJWlRjm3UBMXJXehIuLf1zH9jGtb3PuAPK4IB_JMh0IT-4t28" ++ "bQKxJwUWixCUirVvCI4RQFjjgpIoJn7k4cFWOEFgaejyzqP7mt_mvsqws3rVEuUaViHs6hkbZ_ateTew";

// RFC 7515 Appendix A.3: "Example JWS Using ECDSA P-256 SHA-256".

/// `{"alg":"ES256"}`.
pub const es256_header = "eyJhbGciOiJFUzI1NiJ9";

/// `{"iss":"joe",\r\n "exp":1300819380,\r\n "http://example.com/is_root":true}`.
pub const es256_payload =
    "eyJpc3MiOiJqb2UiLA0KICJleHAiOjEzMDA4MTkzODAsDQogImh0dHA6Ly9leGFtcGxlLmNvbS9pc19yb290Ijp0cnVlfQ";

/// `r || s`, sixty-four bytes, as RFC 7518 §3.4 lays it out.
pub const es256_signature =
    "DtEhU3ljbEg8L38VWAfUAqOyKAM6-Xx-F4GawxaepmXFCgfTjDxw5djxLa8ISlSApmWQxfKTUJqPP3-Kg6NU1Q";

/// The same `r` and `s` as DER — `SEQUENCE { INTEGER r, INTEGER s }`,
/// seventy-one bytes — which is what every tool outside JOSE writes and what
/// a first attempt at ES256 decodes. Valid arithmetic; the wrong shape.
pub const es256_signature_der =
    "MEUCIA7RIVN5Y2xIPC9_FVgH1AKjsigDOvl8fheBmsMWnqZlAiEAxQoH04w8cOXY8S2vCEpUgKZlkMXyk1Cajz9_ioOjVNU";

/// The whole ES256 token.
pub const es256_token = es256_header ++ "." ++ es256_payload ++ "." ++ es256_signature;

/// The public half of the key in RFC 7515 A.3.1, as the JWKS spells it.
pub const es256_x = "f83OJ3D2xF1Bg8vub9tLe1gHMzV76e8Tus9uPHvRVEU";
pub const es256_y = "x_FEzRu9m36HLN_tue659LNpXW6pCyStikYjKIWI5a0";

/// A key set holding only the RFC's EC key, with no `kid`, which is what
/// the RFC's token — which names none — has to be read against.
pub const es256_jwks =
    "{\"keys\":[{\"kty\":\"EC\",\"crv\":\"P-256\",\"x\":\"" ++ es256_x ++ "\",\"y\":\"" ++ es256_y ++ "\"}]}";

/// The issuer's key set, as it would come back from a JWKS endpoint: an
/// Ed25519 key nilo skips (RFC 8037 A.2's), the RSA key under `test-key`,
/// and the RFC's EC key under `es256-key`.
pub const jwks =
    "{\"keys\":[" ++
    "{\"kty\":\"OKP\",\"crv\":\"Ed25519\",\"kid\":\"an-okp-key\",\"x\":\"11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo\"}," ++
    "{\"kty\":\"RSA\",\"alg\":\"RS256\",\"use\":\"sig\",\"kid\":\"test-key\",\"n\":\"" ++ rsa_n ++ "\",\"e\":\"AQAB\"}," ++
    "{\"kty\":\"EC\",\"crv\":\"P-256\",\"use\":\"sig\",\"kid\":\"es256-key\",\"x\":\"" ++ es256_x ++ "\",\"y\":\"" ++ es256_y ++ "\"}" ++
    "]}";
