# nilo verifies a token and does not fetch one

Sign-in with Google means five things: provider discovery, a JWKS fetch, RS256
verification of the ID token, PKCE `S256`, and a nonce. A caller asked for two
of them.

```zig
nilo.jwt.verifyRs256(token, key) !Claims
nilo.jwt.Jwks.fetch(...)              // cached, keyed by kid
```

The first is `nilo_jwt`. The second is not, and the rest never were.

## It fails the bar, and ships anyway

The bar for a new module is
[ADR 0018](0018-the-trade-budget-has-three-axes.md)'s and the roadmap's:
**what a caller cannot already do.** A caller can do this. `std.crypto.Certificate.rsa`
is public in Zig 0.16 — `Certificate.zig:945` — with `PublicKey.fromBytes` and
`PKCS1v1_5Signature.verify`, and it is the same code that verifies a TLS
certificate chain. Six hundred lines on top of it is a fortnight, not a year.

`nilo_pw` fails the same bar, for the same reason, and
[ADR 0048](0048-a-password-hash-is-gated-because-forgetting-is-silent.md) shipped
it. What justified that one is that a subtly wrong password hash **runs
perfectly and leaks**. Token verification is worse on exactly that axis, and
the list of ways is short enough to write down:

- Read `alg` out of the header and do what it says, and `{"alg":"none"}` is a
  valid token.
- Read `alg` and dispatch, and `{"alg":"HS256"}` signed with the RSA modulus
  you published is a valid token, because the public key is the shared secret.
- Skip the `kid` match and any key in the set will do, including the one the
  issuer rotated out.
- Skip `aud` and a token minted for somebody else's application signs in here.
- Get the DigestInfo prefix wrong and the signature check passes on the wrong
  hash.

Every one of those passes a test suite written by the person who made the
mistake. That is the whole argument, and it is the same sentence ADR 0048
ends on.

## What is in and what is not

**In:** RS256, the key set, the registered claims.

**Out:** the fetch, the cache, discovery, PKCE, the nonce, the domain claim,
and the mapping to a user row.

The line is not taste. A JWKS fetch is an HTTPS GET, which `nilo_fetch`
already sends and which nothing about being wrong makes dangerous — a fetch
that fails, fails loudly. Holding the answer is `nilo_cache`. When to refresh
it is a policy, and the roadmap's "Auth contents: the mechanism is provided,
the policy is yours" already decided that one.

So the module is the half where being wrong is silent, and the caller keeps
the half where being wrong is obvious. That is the same cut `nilo_pw` makes:
the salt and the allocator are arguments, the hashing is not.

## Three things are not options

**The algorithm is a constant in this file, never the token's.** `verify` does
RS256 and compares the header's `alg` against the string `"RS256"`. It is not
an instruction, it is one more field checked against something known. This is
what makes the first two attacks in the list above impossible rather than
unlikely.

**Nothing in the payload is read until the signature has passed.** An `exp`
off an unverified token is a number somebody chose. The order in `token.zig`
is: split, header, `alg`, key, signature, and only then the claims.

**`exp` is required.** A credential with no end is not one. `iss` and `aud`
are checked whenever the caller names them, and the caller's claims struct
does not have to mention any of the three — the registered claims are the
module's business, and the struct is for the application's.

## The caller's struct is the claims

```zig
const Claims = struct {
    sub: []const u8,
    email: []const u8,
    email_verified: bool,
};

const claims = try jwt.verify(Claims, c.arena(), id_token, .{
    .keys = &keys,
    .issuer = "https://accounts.google.com",
    .audience = client_id,
    .now_s = @divFloor(nilo.nowMillis(), 1000),
});
```

The same bargain the rest of nilo makes, and the reason `sub` is a field with
a type rather than a lookup into a map. Fields the token carries and the
struct does not name are ignored, because a provider adding a claim is not a
reason to stop signing people in.

## Where it sits, and what that costs

A **tool module**, the fifth: one job, no event loop, imports nothing at all
([ADR 0042](0042-the-bottom-layer-holds-more-than-one-module.md)). So
`zig test jwt/jwt.zig` runs the whole of it with no `build.zig`, which is the
layer's entry condition rather than a convenience.

**`nilo_http` does not name it**, the way it does not name `nilo_cache` or
`nilo_fetch`. A program that signs nobody in with Google links no RSA. A
project that wants one writes `@import("nilo_jwt")`.

Everything about time is an argument — `now_s`, and a `leeway_s` for two
clocks that disagree. That is ADR 0042's rule and it is also what makes the
expiry testable: a test that cannot choose the time cannot test an expiry.

## The alternative that was rejected

**Vendoring a JWT library.** It would have been less code here and it puts a
third-party dependency in the path of every sign-in, which is the one place
this repository has been most careful not to
([ADR 0028](0028-tls-is-terminated-in-front.md) refuses TLS partly on that
ground). The arithmetic that is genuinely hard is std's, already, and audited
by everybody who runs a TLS client in Zig. What is left is a base64 split, a
string comparison and four date checks.

## What is not covered, and why the module says so

HS256, the EC families, JWE, and signing. Signing is absent because a server
that issues its own sessions has `Session(T)` sealed into a cookie
([ADR 0035](0035-a-session-is-sealed-into-the-cookie.md)) and does not need a
token at all. HS256 is one call to `std.crypto.auth.hmac.sha2.HmacSha256` and
would be four lines, and it is not here because the shared-secret shape is
what makes the `alg` confusion attack possible — a module that verifies both
has to be careful about something a module that verifies one cannot get
wrong. If a caller turns up who needs it, that is the trade to reopen.

A key size with no branch — anything but 2048, 3072 or 4096 bits — is
`error.KeySizeNotSupported` rather than a best effort, because "verified" and
"did not check" have to be different answers.

## Consequences

- Five tool modules rather than four, and `shipped_roots`, `.paths` and the
  `layers` table each gain a row.
- 23 tests, both optimize modes, against a token signed by somebody else's
  implementation. A vector produced by the code under test only proves the
  code agrees with itself; this one was signed by a library that verifies
  against the RFC's own examples, so the padding and the DigestInfo prefix are
  being checked rather than restated. The private key was thrown away.
- Nothing in nilo links it. The cost to a program that does not import it is
  zero, and that is a linker fact rather than a promise.
