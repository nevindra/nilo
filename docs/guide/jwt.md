# Checking somebody else's token

**`nilo_jwt` verifies a JWT that an identity provider signed, with RS256 or ES256, and reads its claims into a struct of your own.**

**Reference:** [`nilo_jwt`](../reference/jwt.md#nilo_jwt), [`jwt.Keyring`](../reference/jwt.md#jwtkeyring), [`jwt.Verifier`](../reference/jwt.md#jwtverifierclaims-client), [`Verified(V)`](../reference/handlers.md#verifiedv) · **Design:** [JWT verification](../design/jwt.md)

`nilo_jwt` verifies tokens such as a Google ID token, an Auth0 or Clerk access token, a Keycloak or Cognito bearer token, or a Supabase session. It supports RS256 and ES256, which between them are what those issuers sign with. It is a tool module: no event loop, no allocator of its own, and it imports nothing, so `zig test jwt/jwt.zig` runs all of it ([ADR 111](../adr/111-nilo-verifies-a-token-and-does-not-fetch-one.md)).

**It is for a token somebody else issued.** A sign-in that your own server keeps track of is a [`Session(T)`](./sessions.md), sealed into a cookie, and needs no token at all. In nilo, the word *token* only ever means a credential that arrived from outside ([`CONTEXT.md`](../../CONTEXT.md#tokens)).

```zig
const jwt = @import("nilo_jwt");
```

and one line in `build.zig`, beside the `nilo_http` one:

```zig
.{ .name = "nilo_jwt", .module = nilo.module("nilo_jwt") },
```

## A complete example

<!-- compiles -->
```zig
const jwt = @import("nilo_jwt");

const Claims = struct {
    sub: []const u8,
    email: []const u8,
    email_verified: bool = false,
};

fn whoIsThis(gpa: std.mem.Allocator, keys: *const jwt.Keys, token: []const u8) !Claims {
    return jwt.verify(Claims, gpa, token, .{
        .keys = keys,
        .issuer = "https://accounts.google.com",
        .audience = "1234-abcd.apps.googleusercontent.com",
        .now_s = @divFloor(nilo.nowMillis(), 1000),
    });
}
```

**`verify` does every check, in a safe order, and returns the claims or one of the [errors below](#errors).** Three things shape the call:

- **`Claims` is yours.** Add one field per thing the application wants from the token; fields the token carries that the struct does not name are ignored. The registered claims (`iss`, `aud`, `exp`, `nbf`) are checked whether or not the struct mentions them, so a `Claims` with only `sub` in it still gets a full check.
- **Strings in the result point into `gpa`.** Pass `c.arena()` inside a request and there is nothing to free. Pass a real allocator and the strings are yours to free.
- **The clock is an argument.** A module with no loop has no clock, and a test that cannot choose the time cannot test an expiry. Inside a request, pass `nilo.nowMillis()`.

## Options

| Field | Default | |
|---|---|---|
| `keys` | none | `*const jwt.Keys`, the issuer's: [below](#getting-the-issuers-keys) |
| `issuer` | `null` | reject a token whose `iss` is not exactly this. Null skips the check, which is right only when the key set itself proves who signed |
| `audience` | `null` | reject a token whose `aud` does not include this (your client id). Null skips it, and then a token minted for another application passes |
| `now_s` | none | seconds since the epoch, for `exp` and `nbf` |
| `leeway_s` | `0` | how far the two clocks may disagree, in both directions. Sixty is the usual value when the issuer is somebody else's machine |

**Set both `issuer` and `audience`.** Both are optional because in some deployments the key set already settles them, but leaving them off is wrong in the ordinary case. A Google ID token minted for *somebody else's* application is signed by the same keys as one minted for yours, and `aud` is the only thing that tells them apart.

## Security checks that are always on

**Each of these is a mistake that would give you a verifier that passes every test and leaves the endpoint open**, and preventing them is the reason this module exists rather than a paragraph pointing at `std.crypto`:

- **The algorithm comes from the key, never from the token's `alg`.** A JWKS key that says `RSA` is checked as RS256, and one that says `EC` on `P-256` as ES256; nothing in the token header can change that. The header's `alg` is only compared. A header saying `none`, or `HS256` with your published RSA modulus used as the HMAC secret, is rejected before any key is looked up. A header saying `ES256` over an RSA key, or `RS256` over an EC key, returns `error.WrongAlgorithm` before any arithmetic runs. So a key set holding both kinds, which is what an issuer publishes in the middle of a migration, cannot be tricked into checking one kind with the other ([ADR 111](../adr/111-nilo-verifies-a-token-and-does-not-fetch-one.md)).
- **Nothing in the payload is read until the signature has passed.** An `exp` from an unverified token is a number somebody chose.
- **`exp` is required.** A credential with no end is not a credential, so a token without `exp` returns `error.NoExpiry` however well it is signed.

## Errors

| Error | When | What to answer |
|---|---|---|
| `error.NotAToken` | not three base64url segments, or the header is not JSON | 401 |
| `error.WrongAlgorithm` | the header says anything but `RS256` or `ES256` (`none` included), or names one over a key of the other kind | 401 |
| `error.NoSuchKey` | the `kid` is not in the set, or no `kid` was named and the set has more than one key | the issuer may have rotated: [refresh](#key-rotation), then 401 |
| `error.BadSignature` | the key is right and the signature is not | 401 |
| `error.NoExpiry`, `error.Expired`, `error.NotYetValid` | `exp` missing, `exp` passed, `nbf` not reached | 401 |
| `error.WrongIssuer`, `error.WrongAudience` | `iss` or `aud` is not what you set | 401 |
| `error.ClaimsNotReadable` | the signature passed and the payload does not fit your struct | 401, or a 500 if your struct is what is wrong |
| `error.KeySizeNotSupported` | a modulus that is not 2048, 3072 or 4096 bits | 500, and an entry on the [todo list](../todo.md) under `nilo_jwt` |
| `error.CurveNotSupported` | an EC key whose `crv` is not `P-256` | the same 500, and the same todo entry |
| `error.SignatureWrongLength` | a signature that is not the size of its key (for ES256, sixty-four bytes of `r \|\| s`) | 401. If it is *your* test token, the signer wrote DER: [below](#es256-signatures) |
| `error.KeyNotUsable` | the set carried a key the arithmetic cannot use: an even exponent, a point that is not on the curve | 500. The key document is wrong, and no token will pass |

**Every one of these is a 401 to the client, and the reason belongs in your log, not in the response.** Telling a caller which check failed tells them what to fix on the next attempt. The one worth a different answer is `NoSuchKey`, because that is what a key rotation looks like from here.

## Getting the issuer's keys

**You supply the HTTP client that fetches the key set.** This is deliberate: it is an HTTPS GET that [`nilo_fetch`](./fetch.md) already sends, and this module imports nothing. A `Keyring` takes that client, fetches the keys at startup, and fetches again on an unknown `kid`, at most once per interval. If you would rather a miss be rejected than trigger a fetch, call `verify` instead of `verifyOrRefresh`; the choice is yours ([decided](../decided.md#answered-and-kept-to-one-line-each)). What the module does with the key document is parse it:

| | |
|---|---|
| `jwt.parseKeys(gpa, bytes)` | `!Keys`: a JWKS document read into the keys it can verify with, `RSA` as `n` and `e`, `EC` as `crv`, `x` and `y`. Keys of another type (Ed25519, a key marked `"use":"enc"`) are skipped, not rejected |
| `keys.find(kid)` | `?Key`. A set with exactly one key answers for a token that named no `kid` |
| `key.material` | `.rsa` or `.ec`, and the key's own `algorithm()` is `RS256` or `ES256` accordingly |
| `keys.deinit()` | frees everything |
| `jwt.key_sizes` | the supported modulus lengths: 256, 384 and 512 bytes |
| `jwt.curves` | the supported curves: `P-256` |

`parseKeys` returns `error.NotAKeySet` for bytes that are not a JSON object with a `keys` array, and `error.KeyNotUsable` for a key that says RSA but has no `n` and `e`, or says EC but has no `crv`, `x` or `y`. An EC key on a curve other than `P-256` is *kept*, so that a token naming it returns `error.CurveNotSupported` rather than a `NoSuchKey` that sends you looking for a rotation.

The issuer publishes the document's address. Google's is `https://www.googleapis.com/oauth2/v3/certs`, and for any OIDC issuer it is the `jwks_uri` in `/.well-known/openid-configuration`. **The usual setup is a `Keyring`**: the key URL, issuer and audience written once, the document fetched at startup, and the key set swapped safely when the issuer rotates ([below](#key-rotation)).

<!-- compiles -->
```zig
const fetch = @import("nilo_fetch");

fn fetchKeys(run: *nilo.Run, google: *jwt.Keyring, api: *fetch.Client) !void {
    try google.refresh(run, api, @divFloor(nilo.nowMillis(), 1000));
}
```

and in `main`:

```zig
var google: jwt.Keyring = try .init(gpa, .{
    .url = "https://www.googleapis.com/oauth2/v3/certs",
    .issuer = "https://accounts.google.com",
    .audience = cfg.google_client_id,
});
defer google.deinit();
try app.provide(&google);
try app.before(fetchKeys, .{ &google, &api });
```

`run` there is a [`nilo.Run`](../reference/core.md#run), the Scope for work that is not a request, such as startup. `nilo_fetch` is finished by `listen()` like any other service, so the fetch goes in `app.before`, which runs inside `listen()` once the client is ready and before the first request, the same way a database migration does ([A query with no server](./sql/reading.md#queries-outside-a-request), [ADR 180](../adr/180-work-that-needs-the-services-runs-on-their-loop.md)). The ring needs only one call from the client, `get(scope, url, .{})`, which keeps the module free of imports: the client is an argument, the same way a [`job.Table`](./jobs.md) takes your Db.

A program that only wants to parse the bytes can still use `parseKeys`: `jwt.parseKeys(gpa, res.body.view())` on the result of a `client.get`, held as a `*const Keys` for a key set that never rotates.

## ES256 signatures

**ES256 keys need nothing different in the call: the key's type picks the arithmetic, and the same `verify` handles both.** Supabase, Apple and a growing number of issuers sign with ES256 (ECDSA over P-256 with SHA-256), and their JWKS carries `{"kty":"EC","crv":"P-256","x":…,"y":…}` instead of `n` and `e`.

One thing matters if you ever *create* an ES256 token for a test. A JWS signature is the two integers `r` and `s` back to back, thirty-two bytes each, sixty-four in total (RFC 7518 §3.4). Every tool outside JOSE (`openssl dgst`, a certificate, a `.sig` file) writes the DER `SEQUENCE { INTEGER r, INTEGER s }` instead, around seventy bytes with a variable length. A token whose last segment is DER is rejected here as `error.SignatureWrongLength`, by name, rather than as a `BadSignature` you spend an afternoon on. The module's own test vector is the one from RFC 7515, which avoids the problem.

## The signed-in user as a handler argument

**Once the keys are loaded, the claims behind a bearer token are one handler argument** ([ADR 191](../adr/191-verified-claims-are-a-handler-argument.md)):

<!-- compiles -->
```zig
const Google = jwt.Verifier(Claims, fetch.Client);

fn me(user: nilo.Verified(Google)) Claims {
    return user.claims;
}
```

and beside the ring in `main`:

```zig
var verifier = Google.init(&google, &api);
try app.provide(&verifier);
```

[`jwt.Verifier(Claims, Client)`](../reference/jwt.md#jwtverifierclaims-client) bundles the ring, the client its refresh needs, and the claims type into one service, which is what lets an argument name one type and reach all three. Before `me` runs, nilo:

1. reads the `Authorization` header and requires the `Bearer` scheme;
2. verifies the token through the ring, with the issuer, the audience and the clock;
3. fetches the keys once if the `kid` was missing;
4. hands over the claims, parsed into the request arena.

Anything that fails is a 401 with `WWW-Authenticate: Bearer` and the reason in the body (`Expired`, `WrongAudience`). The one exception is when the issuer cannot be reached while a refresh was needed: that is a 503, because the token was never judged. `listen()` refuses to start if the verifier was not provided, the same as for a `*Db`. The OpenAPI document includes the bearer scheme and the 401.

To reject a user after the token passes (the account is closed, the role is wrong), return `nilo.Verified(Google).refuse("that account is closed", .{})`, which is the same 401 with the same header. `user.token` is the token exactly as the client sent it, for a handler that forwards it to another service. A middleware guarding a prefix reads the same thing with `c.verified(Google)`, but a handler under it that asks again verifies again, so the signature is checked twice. A resolved value, below, avoids that.

**When the handler needs more than the claims** (the database row behind `sub`, a struct of your own), make the token check a [resolved value](./middleware.md#resolved-values). The type says how the value is worked out, a handler asks for it by writing it in its argument list, and it is worked out once per request however many things ask for it.

<!-- compiles -->
```zig
const CurrentUser = struct {
    pub const nilo_resolve = authenticate;

    id: []const u8,
    email: []const u8,
};

fn authenticate(c: *nilo.Ctx, google: *jwt.Keyring, api: *fetch.Client) !CurrentUser {
    const auth = try c.authorization(.bearer);

    const claims = google.verifyOrRefresh(
        struct { sub: []const u8, email: []const u8 },
        c.arena(),
        auth.value.view(),
        @divFloor(nilo.nowMillis(), 1000),
        c,
        api,
    ) catch |err| {
        std.log.info("token refused: {t}", .{err});
        return nilo.Authorization(.bearer).refuse("that token is not valid here", .{});
    };

    return .{ .id = claims.sub, .email = claims.email };
}

fn profile(user: CurrentUser) !CurrentUser {
    return user;
}
```

`c.authorization(.bearer)` reads the `Authorization` header as one scheme ([the reference](../reference/handlers.md#authorizationscheme)). The scheme is matched case-insensitively and whitespace is trimmed. A missing header or a different scheme gets a 401 that carries `WWW-Authenticate: Bearer`, the header every 401 must carry and the one a hand-written `startsWith(value, "Bearer ")` forgets. `Authorization(.bearer).refuse` is `fail.unauthorized` with that same header, for a rejection after reading. A handler that wants the raw token rather than the user asks for `nilo.Authorization(.bearer)` in its argument list, and also gets a security scheme in the OpenAPI document.

`profile` is still an ordinary function: in a test, call `profile(.{ .id = "7", .email = "…" })` with no token anywhere. To guard a whole prefix, use the same `c.resolve` the middleware page shows: `try app.useOn("/api", requireUser)` with `_ = try c.resolve(CurrentUser)` inside it. The handler behind it then reuses that result instead of verifying a second time.

`c.arena()` is the right allocator there. The claims live exactly as long as the request, and nothing needs freeing. A resolver that takes a `*Google` and calls `google.verify(c.arena(), auth.value.view(), now_s, c)` is the same five lines with the client already included.

## Key rotation

**When an issuer rotates keys, a valid token arrives signed with a key you do not have yet, and `verify` returns `error.NoSuchKey`.** An issuer publishes a new key, signs with it, and keeps the old one in the document for a while. This guide used to say the fix was three lines: fetch again, hold a `*const Keys`, swap under a mutex. Each of the three was wrong in a way no test catches:

- no refetch means every sign-in fails until a restart;
- an unbounded refetch means one GET to the issuer per forged `kid`;
- swapping a set that another thread is reading is a use-after-free that the Debug build has no trap for.

The last one is a concurrency problem, not a policy choice, and it is why the ring lives in the module ([ADR 111](../adr/111-nilo-verifies-a-token-and-does-not-fetch-one.md)).

**`verifyOrRefresh` is `verify`, plus at most one fetch per `refresh_interval_s` on `NoSuchKey`**, then `verify` again. The first request that sees the miss does the fetch. Other requests within that interval still get `NoSuchKey`. During a real rotation that means a handful of 401s in the second the first new-key token arrives; under a flood of forged tokens it is the limit doing its job. A [ticker](./background.md) can also call `refresh` on a schedule. Any refresh that ran, scheduled or not, counts as the last one, so a miss straight after it does not fetch again.

| | |
|---|---|
| `ring.load(bytes)` | parses a document and makes it current. The old set is freed once the verifies reading it are done, and a document that does not parse leaves the old set in place |
| `ring.refresh(scope, client, now_s)` | `client.get(scope, url, .{})` then `load`. Returns `error.KeysNotAvailable` for anything but a 2xx, with the old set still held |
| `ring.verify(Claims, gpa, token, now_s)` | `jwt.verify` against the current set, with the ring's issuer, audience and leeway. Never fetches |
| `ring.verifyOrRefresh(Claims, gpa, token, now_s, scope, client)` | the above, plus one bounded refresh on a missing `kid` |

**The swap is safe because each verify pins the set it reads.** A verify increments a count on the set, reads, and decrements it. A swap publishes the new set, then waits for the old set's count to reach zero before freeing it. Readers never wait. Only the writer waits, with a spin that lasts at most one verify, once per rotation. It spins because a `std.Io.Mutex` needs an `Io`, which a tool module does not have; the [cache](./cache.md) spins for the same reason. `nilo_cache` solves the same lifetime problem with a copy and a generation number ([ADR 152](../adr/152-a-lookup-asks-the-cursor-afterwards-instead-of-taking-a-lock.md)). A key set is not flat data, so here it is a pin.

Whether a `kid` miss should *reject* rather than *fetch* is still your decision: call `verify` and decide. The interval limits how often a fetch can happen; it is not a policy about whether to fetch.

## Testing

**`now_s` is an argument, so you test an expiry by choosing the time instead of waiting.** Create a key you hold (`openssl genrsa` or `openssl ecparam -name prime256v1 -genkey`), publish its public half as a JWKS document, and sign a token with any JOSE library. Then call `verify` at the second before its `exp`, at `exp`, and the second after. That is a complete test, and it runs under `zig test` with no server.

The module's own suite does exactly that against two fixed vectors in `jwt/vector.zig` (an RSA token signed elsewhere, and RFC 7515's own ES256 example). Copy the shape from that file.

## What it costs

**Nothing per request beyond what you ask for.** The module allocates only what the claims need, from the allocator you passed, and holds nothing between calls.

**The cost of one verification has not been measured.** An RSA verify at 2048 bits is a modular exponentiation, which is not cheap. An ES256 verify is two scalar multiplications on P-256 and is usually the cheaper of the two, but neither has been measured here. Whether a busy endpoint should cache the result or simply verify each time is a question the roadmap is waiting on a measurement for. Until then, a resolved value is already the cheapest setup (once per request, not once per handler), and setting a session cookie after the first verified request is the usual way to stop paying the cost at all.

## What it will not do

**Not supported: HS256, any curve but P-256, encrypted tokens (JWE), signing, discovery, PKCE and the nonce.** Signing is missing because a server that issues its own sessions has [`Session(T)`](./sessions.md) and needs no token. HS256 is missing because a module that verifies both a shared secret and a public key has to defend against an algorithm-confusion attack that a module verifying only one cannot fall for ([decided](../decided.md#accepted)). The rest is the sign-in flow (redirecting to the provider, exchanging a code), which is yours.

## See also

- [The reference](../reference/jwt.md#nilo_jwt): the full list of calls.
- [Sessions](./sessions.md): what a signed-in user becomes after the first verified request.
- [Calling somebody else's API](./fetch.md): the fetch that gets the key set.
- [ADR 111](../adr/111-nilo-verifies-a-token-and-does-not-fetch-one.md): why verifying is in this module and fetching is not, why the key picks the algorithm, and what ES256 costs.
