# Checking somebody else's token

`nilo_jwt` verifies a JWT that an identity provider signed — a Google ID
token, an Auth0 or Clerk access token, a Keycloak or Cognito bearer — and
reads the claims into a struct of your own. It is a tool module: no event
loop, no allocator of its own, and it imports nothing, so `zig test
jwt/jwt.zig` runs the whole of it
([ADR 0140](../adr/0140-nilo-verifies-a-token-and-does-not-fetch-one.md)).

**It is for a token somebody else issued.** A sign-in your own server keeps
is a [`Session(T)`](./sessions.md), sealed into a cookie, and needs no token
at all. The word *token* here only ever means a credential that arrived from
outside ([`CONTEXT.md`](../../CONTEXT.md#tokens)).

```zig
const jwt = @import("nilo_jwt");
```

and one line in `build.zig`, beside the `nilo_http` one:

```zig
.{ .name = "nilo_jwt", .module = nilo.module("nilo_jwt") },
```

## The whole of it

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

`verify` does everything, in the order that is safe, and answers the claims
or one of the errors [below](#what-it-answers-instead). Three things decide
the shape of the call:

- **`Claims` is yours.** One field per thing the application wants out of the
  token; fields the token carries and the struct does not name are ignored.
  The registered claims — `iss`, `aud`, `exp`, `nbf` — are checked whether or
  not the struct mentions them, so a `Claims` with only `sub` in it is still
  a full check.
- **Strings in the answer point into `gpa`.** Hand it `c.arena()` inside a
  request and there is nothing to free; hand it a real allocator and the
  strings are yours to free.
- **The clock is an argument.** A module with no loop has no clock, and a
  test that cannot choose the time cannot test an expiry. Inside a request,
  `nilo.nowMillis()` is the one to pass.

## Options

| Field | Default | |
|---|---|---|
| `keys` | — | `*const jwt.Keys`, the issuer's — [below](#where-the-keys-come-from) |
| `issuer` | `null` | refuse a token whose `iss` is not exactly this. Null skips the check, which is right only when the key set itself is the proof of who signed |
| `audience` | `null` | refuse a token whose `aud` does not carry this — your client id. Null skips it, and a token minted for another application then passes |
| `now_s` | — | seconds since the epoch, for `exp` and `nbf` |
| `leeway_s` | `0` | how far the two clocks may disagree, both ways. Sixty is the usual number when the issuer is somebody else's machine |

Name the `issuer` and the `audience`. Both are optional because there are
deployments where the key set already settles them, and both are wrong to
leave off in the ordinary one: a Google ID token minted for *somebody else's*
application is signed by the same keys as one minted for yours, and `aud` is
the only thing that tells them apart.

## What is not an option

Each of these is a way to write a verifier that passes every test and leaves
the endpoint open, which is the whole reason the module exists rather than a
paragraph pointing at `std.crypto`:

- **The algorithm is nilo's constant, never the token's `alg`.** A header
  saying `none`, or `HS256` with the RSA modulus you published used as the
  HMAC secret, is refused before a key is looked up.
- **Nothing in the payload is read until the signature has passed.** An `exp`
  off an unverified token is a number somebody chose.
- **`exp` is required.** A credential with no end is not one, so a token
  without it is `error.NoExpiry` however well it is signed.

## What it answers instead

| Error | When | What to answer |
|---|---|---|
| `error.NotAToken` | not three base64url segments, or the header is not JSON | 401 |
| `error.WrongAlgorithm` | the header says anything but `RS256`, `none` included | 401 |
| `error.NoSuchKey` | the `kid` is not in the set, or none was named and the set has more than one key | the issuer may have rotated — [refresh](#when-the-issuer-rotates), then 401 |
| `error.BadSignature` | the key is right and the signature is not | 401 |
| `error.NoExpiry`, `error.Expired`, `error.NotYetValid` | `exp` missing, `exp` passed, `nbf` not arrived | 401 |
| `error.WrongIssuer`, `error.WrongAudience` | `iss` or `aud` is not what you named | 401 |
| `error.ClaimsNotReadable` | the signature passed and the payload does not fit your struct | 401 — or a 500 if the struct is the thing that is wrong |
| `error.KeySizeNotSupported` | a modulus that is not 2048, 3072 or 4096 bits | 500, and a caller on the [roadmap](../roadmap.md#nilo_jwt-checking-somebody-elses-token) |

Every one of them is a 401 to the client, and the *reason* belongs in your
log rather than in the response: telling a caller which check failed is
telling them what to fix on the next attempt. The one worth a different
answer is `NoSuchKey`, because it is what a key rotation looks like from here.

## Where the keys come from

**Fetching the key set is yours** — deliberately, because it is an HTTPS GET
that [`nilo_fetch`](./fetch.md) already sends, and *when* to fetch it again is
a policy with more than one right answer
([roadmap](../roadmap.md#nilo_jwt-checking-somebody-elses-token)). What the
module does is read the document:

| | |
|---|---|
| `jwt.parseKeys(gpa, bytes)` | `!Keys` — a JWKS document read into the RSA keys it can verify with. Keys of another type are skipped, not refused |
| `keys.find(kid)` | `?Key`. A set with exactly one key answers for a token that named no `kid` |
| `keys.deinit()` | frees the lot |
| `jwt.key_sizes` | the modulus lengths with a branch: 256, 384 and 512 bytes |

`parseKeys` answers `error.NotAKeySet` for bytes that are not a JSON object
with a `keys` array, and `error.KeyNotUsable` for a key that said RSA and then
carried no `n` and `e`.

The document's address is published by the issuer — Google's is
`https://www.googleapis.com/oauth2/v3/certs`, and for anything OIDC it is the
`jwks_uri` in `/.well-known/openid-configuration`. The ordinary shape is a
fetch at startup, before `listen()`, held as a service:

<!-- compiles: body -->
```zig
const res = try client.get(&run, "https://www.googleapis.com/oauth2/v3/certs", .{});
if (!res.ok()) return error.NoKeys;
var keys = try jwt.parseKeys(gpa, res.body.view());
defer keys.deinit();
```

`run` there is a [`nilo.Run`](../reference.md#run) — the Scope for work that
is not a request, which a startup path is. Since `nilo_fetch` is finished by
`listen()` like any other service, fetching before it means starting the
services under an `Io` of your own first, exactly as a database migration
does ([A query with no server](./sql/reading.md#a-query-with-no-server),
[ADR 0079](../adr/0079-there-is-a-phase-before-the-server.md)):
`app.start(threaded.io())`, the fetch, then `listen()`.

## The signed-in user

With the keys held, the token check is a
[resolved value](./middleware.md#resolved-values): the type says how it is
worked out, a handler asks for it by writing it in its argument list, and it
is worked out once per request however many things ask.

<!-- compiles -->
```zig
const jwt = @import("nilo_jwt");

const Issuer = struct {
    keys: jwt.Keys,
    audience: []const u8,
};

const CurrentUser = struct {
    pub const nilo_resolve = authenticate;

    id: []const u8,
    email: []const u8,
};

fn authenticate(c: *nilo.Ctx, issuer: *const Issuer) !CurrentUser {
    const header = c.header("Authorization") orelse
        return nilo.fail.unauthorized("this endpoint needs a bearer token", .{});
    const value = header.view();
    if (!std.mem.startsWith(u8, value, "Bearer "))
        return nilo.fail.unauthorized("this endpoint needs a bearer token", .{});

    const claims = jwt.verify(struct { sub: []const u8, email: []const u8 }, c.arena(), value["Bearer ".len..], .{
        .keys = &issuer.keys,
        .issuer = "https://accounts.google.com",
        .audience = issuer.audience,
        .now_s = @divFloor(nilo.nowMillis(), 1000),
        .leeway_s = 60,
    }) catch |err| {
        std.log.info("token refused: {t}", .{err});
        return nilo.fail.unauthorized("that token is not valid here", .{});
    };

    return .{ .id = claims.sub, .email = claims.email };
}

fn me(user: CurrentUser) !CurrentUser {
    return user;
}
```

`me` is still an ordinary function — `me(.{ .id = "7", .email = "…" })` in a
test, with no token anywhere. Guarding a whole prefix is the same `c.resolve`
the middleware page shows: `try app.useOn("/api", requireUser)` with
`_ = try c.resolve(CurrentUser)` inside it, and the handler behind it gets the
same lookup rather than a second one.

`c.arena()` is the right allocator there. The claims live exactly as long as
the request, and nothing is freed.

## When the issuer rotates

An issuer publishes a new key, signs with it, and keeps the old one in the
document for a while. From here that arrives as `error.NoSuchKey` on a token
that is otherwise fine, and the answer is to fetch the document again — once,
not on every refused request, because a flood of tokens with a made-up `kid`
is otherwise a flood of requests to the issuer.

The pieces are all things this guide already has: the fetch above, a
[`nilo.Mutex`](./services.md#they-are-shared-across-threads) around the swap,
and either a [ticker](./background.md) that refreshes on a schedule or a
timestamp beside the keys so a `NoSuchKey` triggers at most one refresh a
minute. Which policy is right depends on the issuer, which is why none is
built in; the roadmap says what would change that.

One rule holds whatever the policy: **swap the `Keys` under the same lock a
`verify` reads them under.** A verify in flight on another thread is reading
`keys.all` while `deinit` frees it otherwise, and the Debug build has no trap
for that one.

## Testing

`now_s` is an argument, so an expiry is tested by choosing the time rather
than by waiting. A token signed with a key you hold — `openssl genrsa`,
the public half as a JWKS document, a token signed by any library — and a
`verify` at the second before its `exp`, the second of it, and the second
after is the whole of a test, and it runs under `zig test` with no server.

The module's own suite does exactly that against a fixed vector
(`jwt/vector.zig`), which is the file to copy the shape from.

## What it costs

**Nothing per request that is not yours.** The module allocates only what
the claims need, from the allocator you passed, and holds nothing between
calls.

**And the number for one verification is not on file.** An RSA verify at
2048 bits is a modular exponentiation and it is not small; whether a hot
endpoint should cache the answer or just do it is a question the roadmap is
waiting on a measurement for. Until then, the safe reading is that a resolved
value is already the cheapest shape — once per request, not once per
handler — and a session cookie set after the first verified request is the
usual way to stop paying it at all.

## What it will not do

HS256 and the EC families, encrypted tokens (JWE), signing, discovery, PKCE
and the nonce. Signing is absent because a server issuing its own sessions has
[`Session(T)`](./sessions.md) and needs no token; HS256 is absent because a
module verifying both a shared secret and a public key has to defend against
the confusion attack that a module verifying one cannot commit
([roadmap](../roadmap.md#nilo_jwt-checking-somebody-elses-token)). The rest is
the sign-in flow — redirecting to the provider, exchanging a code — which is
yours.

## See also

- [The reference](../reference.md#nilo_jwt) — the surface as a list.
- [Sessions](./sessions.md) — what a signed-in user becomes after the first
  verified request.
- [Calling somebody else's API](./fetch.md) — the fetch that gets the key set.
- [ADR 0140](../adr/0140-nilo-verifies-a-token-and-does-not-fetch-one.md) —
  why verifying is here and fetching is not.
