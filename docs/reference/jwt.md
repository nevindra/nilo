# nilo_jwt

**`nilo_jwt` checks a JWT that somebody else signed (RS256 or ES256), and never signs or fetches one itself.**

**Guide:** [Checking somebody else's token](../guide/jwt.md) · **Design:** [JWT verification](../design/jwt.md)

## `nilo_jwt`

Checking somebody else's signed token, with nothing that needs an event loop ([ADR 111](../adr/111-nilo-verifies-a-token-and-does-not-fetch-one.md)). It is a tool module: it imports nothing, so `zig test jwt/jwt.zig` runs all of it.

<!-- compiles -->
```zig
const jwt = @import("nilo_jwt");

const Claims = struct {
    sub: []const u8,
    email: []const u8,
    email_verified: bool,
};

fn signIn(gpa: std.mem.Allocator, keys: *const jwt.Keys, id_token: []const u8) !Claims {
    return jwt.verify(Claims, gpa, id_token, .{
        .keys = keys,
        .issuer = .{ .is = "https://accounts.google.com" },
        .audience = .{ .is = "…apps.googleusercontent.com" },
        .now_s = @divFloor(nilo.nowMillis(), 1000),
    });
}
```

### `jwt.verify` and `jwt.Keys`

| | |
|---|---|
| `jwt.parseKeys(gpa, bytes)` | `!Keys`: a JWKS document read into the keys it can verify with: `RSA`, and `EC` on `P-256` |
| `keys.deinit()` | frees all of it |
| `keys.find(kid)` | `?Key`. A set with one key matches a token that named no key |
| `key.material` | `.rsa = .{ .e, .n }` or `.ec = .{ .crv, .x, .y }`. Which one it is decides how a token signed with it is checked |
| `key.algorithm()` | the `alg` a token signed with this key must declare: `RS256` or `ES256` |
| `jwt.verify(Claims, gpa, token, opts)` | `!Claims`: the whole check, then the payload |
| `jwt.Expect` | `union(enum) { is: []const u8, unchecked }`: what `issuer` and `audience` are set to. There is no default and no `null`, so a call that forgets one does not compile ([ADR 111](../adr/111-nilo-verifies-a-token-and-does-not-fetch-one.md)) |
| `jwt.key_sizes` | the RSA modulus lengths supported: 256, 384 and 512 bytes |
| `jwt.curves` | the curves supported: `P-256` |

### `Options`

| | |
|---|---|
| `.keys` | `*const Keys`, the issuer's |
| `.issuer` | a `jwt.Expect`, with no default: `.{ .is = "…" }` rejects a token whose `iss` is not this, `.unchecked` skips the check |
| `.audience` | a `jwt.Expect`, with no default: `.{ .is = "…" }` rejects a token whose `aud` does not include this, `.unchecked` skips the check, and is for an access token that names the application in another claim and carries no `aud` (Cognito's, Clerk's) |
| `.now_s` | seconds since the epoch. An argument, not a clock |
| `.leeway_s` | how far the two clocks may disagree, in both directions. Default `0` |

### Fetching the key set

**You fetch the key set; a [`Keyring`](#jwtkeyring) holds it across a key rotation.** The fetch is an HTTPS GET, which `nilo_fetch` already sends. This module does the part where a mistake is silent, and swapping the set while readers use it is part of that.

<!-- compiles: body -->
```zig
const res = try client.get(&run, "https://www.googleapis.com/oauth2/v3/certs", .{});
var keys = try jwt.parseKeys(gpa, res.body.view());
defer keys.deinit();
```

### What is not an option

**Three things are fixed, because making any of them an option lets you write a verifier that passes every test and is still insecure:**

- **The algorithm comes from the key, never from the token's `alg`.** An `RSA` key is checked as RS256 and an `EC` key on `P-256` as ES256, and the header is only compared against that. `{"alg":"none"}` and an HMAC signed with the RSA modulus you published are rejected before any key is looked up, and `ES256` over an RSA key is a mismatch, not a request ([ADR 111](../adr/111-nilo-verifies-a-token-and-does-not-fetch-one.md)).
- **Nothing in the payload is read until the signature has passed.** An `exp` from an unverified token is a number somebody chose.
- **`exp` is required.** A credential that never expires is not a credential.

Strings in the returned claims point into the allocator you passed. Pass `c.arena()` and there is nothing to free.

### Errors

| Error | When |
|---|---|
| `error.NotAToken` | not three base64url segments, or the header is not JSON |
| `error.WrongAlgorithm` | the header says anything but `RS256` or `ES256` (`none` included), or names one of them over a key of the other kind |
| `error.NoSuchKey` | the `kid` is not in the set, or no `kid` was given and the set has more than one key |
| `error.BadSignature` | the key is right and the signature is not |
| `error.NoExpiry` / `error.Expired` / `error.NotYetValid` | `exp` missing, `exp` passed, `nbf` not yet reached |
| `error.WrongIssuer` / `error.WrongAudience` | `iss` or `aud` is not what you named |
| `error.ClaimsNotReadable` | the signature passed and the payload does not fit your struct |
| `error.KeySizeNotSupported` | a modulus that is not 2048, 3072 or 4096 bits |
| `error.CurveNotSupported` | an EC key whose `crv` is not `P-256` |
| `error.SignatureWrongLength` | a signature that is not the size of its key. For ES256 that is sixty-four bytes of `r \|\| s`, which is where a DER-encoded signature is caught |
| `error.KeyNotUsable` | a key in the set that the arithmetic cannot use: an even RSA exponent, or an EC coordinate that is not thirty-two bytes or not on the curve |

### `jwt.Keyring`

**A key set that can be replaced while readers use it.** The set is swapped as a whole, the old one is freed after the verifies reading it finish, and an unknown `kid` triggers a fetch at most once per interval ([ADR 111](../adr/111-nilo-verifies-a-token-and-does-not-fetch-one.md)). The HTTP client is a parameter, so the module still imports nothing.

<!-- compiles -->
```zig
const fetch = @import("nilo_fetch");

fn fetchKeys(run: *nilo.Run, google: *jwt.Keyring, api: *fetch.Client) !void {
    try google.refresh(run, api, @divFloor(nilo.nowMillis(), 1000));
}

fn whoIsThis(c: *nilo.Ctx, google: *jwt.Keyring, api: *fetch.Client, token: []const u8) !Claims {
    return google.verifyOrRefresh(Claims, c.arena(), token, @divFloor(nilo.nowMillis(), 1000), c, api);
}
```

| | |
|---|---|
| `jwt.Keyring.init(gpa, .{ .url, .issuer, .audience, .leeway_s, .refresh_interval_s, .remember_tokens })` | `!Keyring`, holding no keys: every verify returns `NoSuchKey` until `load` or `refresh`. `url`, `issuer` and `audience` are required, the last two as a `jwt.Expect`. `refresh_interval_s` defaults to 60. `remember_tokens` (default 0) is how many verified tokens the ring remembers by SHA-256 digest, so a token seen again skips the signature arithmetic (400 µs for ES256) but not the `exp`/`nbf`/`iss`/`aud` checks; a `load` forgets them all ([ADR 209](../adr/209-a-verified-signature-is-remembered-by-the-tokens-digest.md)) |
| `ring.deinit()` | frees the set it holds |
| `ring.load(bytes)` | parses a JWKS document and makes it the set every later verify reads; the old set is freed once its readers are done. A document that does not parse leaves the old set in place |
| `ring.refresh(scope, client, now_s)` | `client.get(scope, url, .{})`, then `load` the body; `error.KeysNotAvailable` for anything but a 2xx, with the old set still held. `client` is anything that has `ok()` and `body.view()`, which `fetch.Client` does. Records `now_s` as the last refresh |
| `ring.verify(Claims, gpa, token, now_s)` | `jwt.verify` against the current set, with the ring's issuer, audience and leeway |
| `ring.verifyOrRefresh(Claims, gpa, token, now_s, scope, client)` | `verify`, and on `NoSuchKey` a `refresh` at most once per `refresh_interval_s`, then `verify` again. A miss within the interval stays `NoSuchKey` |

A verify pins the set for its own duration and never waits. A swap spins on the old set's reader count, for at most one verify, once per rotation. Provide the ring as a service and ask for `*jwt.Keyring` where the token is checked, or hold it in a `Verifier` and ask for the claims.

### `jwt.Verifier(Claims, Client)`

**The ring, the client its refresh needs, and the claims type, as one service.** It is what [`nilo.Verified(V)`](./handlers.md#verifiedv) names to give a handler the claims behind a bearer token ([ADR 191](../adr/191-verified-claims-are-a-handler-argument.md)). The client is a type parameter, so the module still imports nothing.

<!-- compiles -->
```zig
const Google = jwt.Verifier(Claims, fetch.Client);

fn wire(app: *nilo.App, google: *jwt.Keyring, api: *fetch.Client) !void {
    const verifier = try app.gpa.create(Google);
    verifier.* = Google.init(google, api);
    try app.provide(verifier);
}
```

| | |
|---|---|
| `Verifier(Claims, Client)` | a type. `Client` is anything with `get(scope, url, .{})` returning something with `ok()` and `body.view()`, which `fetch.Client` does |
| `Google.init(&ring, &client)` | the value to `provide`: two pointers, nothing started |
| `verifier.verify(gpa, token, now_s, scope)` | `ring.verifyOrRefresh(Claims, …)` with the claims type, the ring and the client filled in |
| `Google.nilo_verifier` | `Claims`: what `nilo.Verified` reads |

### What it does not do

**Not included:** HS256, any curve but P-256, encrypted tokens, signing, discovery, PKCE and the nonce. There is no signing because a server issuing its own sessions has [`Session(T)`](./ctx.md#sessiont) and needs no token. The rest is the sign-in flow, which is yours.
