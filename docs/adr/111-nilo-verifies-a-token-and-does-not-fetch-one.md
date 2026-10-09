# nilo verifies a token and does not fetch one

**Status:** accepted
**Topic:** [jwt](../design/jwt.md)
**Applies:** [ADR 044](./044-a-password-hash-is-gated-because-forgetting-is-silent.md).

## Context

Sign-in with Google means five things: provider discovery, a JWKS fetch, RS256 verification of the ID token, PKCE `S256`, and a nonce.
A caller asked for two of them, `verifyRs256(token, key)` and a cached, `kid`-keyed `Jwks.fetch`.
The first is a tool module's job; the second, and the rest, never were.

**The bar for a new module is what a caller cannot already do**, and a caller can already verify a token: `std.crypto.Certificate.rsa` is public in Zig 0.16, with `PublicKey.fromBytes` and `PKCS1v1_5Signature.verify`, the same code that verifies a TLS certificate chain.
`nilo_pw` shipped against the same bar for the same reason: a subtly wrong password hash runs perfectly and leaks, and getting a hash wrong is a fortnight of code away from getting it right, not a year.
Token verification is worse on exactly that axis, and the ways to get it subtly, silently wrong are short enough to list: read `alg` out of the header and do what it says, and `{"alg":"none"}` is a valid token; read `alg` and dispatch, and an HMAC signed with the RSA modulus you published is a valid token, because the public key is the shared secret; skip the `kid` match and any key in the set will do, including one the issuer rotated out; skip `aud` and a token minted for somebody else's application signs in here; get the DigestInfo prefix wrong and the signature check passes on the wrong hash.
Every one of those passes a test suite written by the person who made the mistake.

Two things this module did not anticipate turned up once it shipped. An issuer signing something other than RS256: Supabase Auth and Apple both sign ES256, ECDSA over P-256, and a token from either was `error.WrongAlgorithm` here, the right refusal and still a refusal a real caller needed answered. And every issuer rotates its signing keys, Google on the order of days, and the three lines a caller was told to write for that (refetch on `error.NoSuchKey`, hold a `*const Keys`, swap it under a mutex) are each wrong in a way no test finds: no refetch is every sign-in failing until a restart; an unbounded refetch is one HTTPS GET to the issuer per forged `kid`, a request from anybody on the internet turned into a request from this server to Google; and swapping the pointer while a verify on another thread is still reading the old one is a use-after-free the Debug build has no trap for, because a key set is a slice into an arena the `Str` trap does not know about.

## Decision

### What is in and what is not

**In:** RS256 and ES256 verification, the key set they read, the registered claims (`exp`, `iss`, `aud`), and a `Keyring` that rotates a key set without a race.
**Out:** the JWKS fetch's own HTTP call, discovery, PKCE, the nonce, the domain claim, and the mapping to a user row.

The line is not taste. A JWKS fetch is an HTTPS GET, which `nilo_fetch` already sends and which nothing about being wrong makes dangerous, a fetch that fails, fails loudly. Holding the answer is `nilo_cache`'s job; when to refresh it is a policy the module states a bound for and does not otherwise make. So the module is the half where being wrong is silent, and the caller (or the `Keyring` below) keeps the half where being wrong is obvious, the same cut `nilo_pw` makes between the hashing and the salt and the allocator.

### The key decides the algorithm, never the header

**The header's `alg` is compared, twice, and never dispatched on.** A JWKS key that says `"kty":"RSA"` is read as RS256 material (`e` and `n`); one that says `"kty":"EC"` is read as ES256 material (`crv`, `x`, `y`); `jwt.Key` carries which as a `material` union.
The header is checked at two points in `token.zig`, both refusals rather than routing:

1. **Before the key is looked up**, against the two names this module knows (`"RS256"`, `"ES256"`). `none`, `HS256`, `ES384` and everything else stop here and never reach a `kid` match, which is what keeps `none` reading `WrongAlgorithm` rather than `NoSuchKey`.
2. **After the key is found**, against the one name that key answers to. `ES256` over an RSA key is a mismatch, refused the way `none` is, before any arithmetic runs.

So a key set holding an RSA key and an EC key at once, what an issuer publishes mid-migration, cannot be talked into checking one with the other: the token names a `kid`, the `kid` names a key, the key names the algorithm, and the header either agrees or the token is refused. At no point does anything in the token pick code.

**A key size or curve with no branch is refused by name, not skipped.** An RSA modulus that is not 2048, 3072 or 4096 bits is `error.KeySizeNotSupported`; an EC key whose `crv` is not `P-256` is kept by `parseKeys` and refused by name at `verify`, `error.CurveNotSupported`, because skipping it at parse time would turn the token into `NoSuchKey`, which the caller reads as "refetch", and they would refetch forever. A key of another type entirely, Ed25519, or one marked `"use":"enc"`, is still skipped at parse, because an issuer adding one of those means nothing about this program.

**The JWS signature on an EC token is raw `r || s`, sixty-four bytes on P-256, and never DER.** Every other place an ECDSA signature turns up, a certificate, `openssl dgst`, a `.sig` file, is the DER `SEQUENCE { INTEGER r, INTEGER s }`; RFC 7518 §3.4 says a JWS carries the two integers back to back, each padded to the curve's width. A DER signature arrives as `error.SignatureWrongLength` rather than as a `BadSignature` that costs an afternoon.

### Nothing is read until the signature has passed

An `exp` off an unverified token is a number somebody chose, so the order in `token.zig` is: split, header, `alg`, key, signature, and only then the claims. `exp` is required; a credential with no end is not one. `iss` and `aud` are checked against what the caller said, and the caller's claims struct does not have to mention any of the three, the registered claims are the module's business and the struct is for the application's.

```zig
const Claims = struct {
    sub: []const u8,
    email: []const u8,
    email_verified: bool,
};

const claims = try jwt.verify(Claims, c.arena(), id_token, .{
    .keys = &keys,
    .issuer = .{ .is = "https://accounts.google.com" },
    .audience = .{ .is = client_id },
    .now_s = @divFloor(nilo.nowMillis(), 1000),
});
```

Fields the token carries and the struct does not name are ignored, because a provider adding a claim is not a reason to stop signing people in. Everything about time is an argument, `now_s` and a `leeway_s` for two clocks that disagree, which is what makes an expiry testable: a test that cannot choose the time cannot test one.

### The issuer and the audience are said, never defaulted

**`issuer` and `audience` are `jwt.Expect`, a union with no default: `.{ .is = "…" }` insists on a value, `.unchecked` says the check is not wanted.** Leaving one out is `error: missing struct field: audience` at the line that builds the options, in `jwt.Options` and in `Keyring.Options` alike. This is [ADR 044](./044-a-password-hash-is-gated-because-forgetting-is-silent.md)'s rule applied to a token: a check whose omission costs silently is enforced rather than documented. Before this, both were `?[]const u8 = null`, and a ring over Google's keys with no `audience` accepted an ID token minted for any other application Google signs, because it is signed by the same keys; nothing failed, nothing logged, and every test written by the person who forgot it passed.

**Required with an opt-out, and not simply required, because the issuers read do not all put an `aud` in the token.** The question was whether any issuer's tokens carry no audience; if none did, `audience` would be a plain required string. Read from each issuer's own documentation:

| Issuer and token | Carries `aud`? | Source |
|---|---|---|
| Google, ID token | yes, "one of the OAuth 2.0 client IDs of your application" | [OpenID Connect](https://developers.google.com/identity/openid-connect/openid-connect) |
| Amazon Cognito, ID token | yes, the app client id | [the access token page](https://docs.aws.amazon.com/cognito/latest/developerguide/amazon-cognito-user-pools-using-the-access-token.html), under `client_id` |
| **Amazon Cognito, access token** | **no, unless the app asked for a resource binding**; the app client is in `client_id` | the same page: `aud` is "present only if your application requested a resource binding" |
| **Clerk, session token** | **no**: the default claims are `azp`, `exp`, `fva`, `iat`, `iss`, `jti`, `nbf`, `sid`, `sub` and a few of Clerk's own | [Session tokens](https://clerk.com/docs/guides/sessions/session-tokens) |
| **Keycloak, access token** | **not for every user**: the default Audience Resolve mapper adds the clients "for which user has at least one client role", so a user with none gets no `aud` until an Audience mapper is added | [`AudienceResolveProtocolMapper`](https://www.keycloak.org/docs-api/latest/javadocs/org/keycloak/protocol/oidc/mappers/AudienceResolveProtocolMapper.html); the version-19 change is reported on the [Keycloak forum](https://forum.keycloak.org/t/aud-field-in-access-token-in-keycloak-19/16757) |
| Auth0, API access token | yes, the API identifier; with no `audience` parameter the token is opaque and there is nothing to verify | [Get access tokens](https://auth0.com/docs/secure/tokens/access-tokens/get-access-tokens) |
| Microsoft Entra, access token | yes, "always the client ID of the API" in v2.0; the page says it "must be validated" | [Access token claims](https://learn.microsoft.com/en-us/entra/identity-platform/access-token-claims-reference) |
| Okta, custom authorization server | yes, the audience configured for the server; the org authorization server's access tokens are opaque | [Validate access tokens](https://developer.okta.com/docs/guides/validate-access-tokens/dotnet/main/) |
| Supabase Auth | yes, "always present … and cannot be removed" (`authenticated` or `anon`) | [JWT fields](https://supabase.com/docs/guides/auth/jwt-fields) |
| Sign in with Apple, identity token | by the usual reading yes, the app's bundle or Services id; Apple's page did not render for the fetch, so this row is not read from the primary source | [Verifying a user](https://developer.apple.com/documentation/sign_in_with_apple/sign_in_with_apple_rest_api/verifying_a_user) |

RFC 9068 makes `aud` a REQUIRED claim of a JWT access token, and three of the issuers above ship tokens that do not follow it by default. The three have a way to name the application that is not `aud`: Cognito's `client_id`, Clerk's and Keycloak's `azp`. So a required string would refuse a real, common deployment, and defaulting to null would be the hole this section closes; the caller has to choose, in a word that shows in review. `nilo` does not sign tokens of its own (a `Session(T)` is a sealed cookie, not a JWT), so there is no key of nilo's that needs an audience.

**`.unchecked` is not "safe", it is "checked somewhere else".** On a token whose `aud` is absent, the replay this check stops (a token minted for application B presented to application A, signed by the same keys) is stopped by the claim that names the application, and that claim is the caller's to read from its own `Claims` (`client_id: []const u8`, then compare). Reading an arbitrary claim by name inside the module is not done here: the registered claims are a fixed struct so that `verify` parses the payload once into scratch it already owns, and a by-name check would parse into a `std.json.Value` tree on every verify, an allocation on the request path ([ADR 017](./017-the-trade-budget-has-four-axes.md)'s hard axis). It stays on the todo list as a question with that number attached.

**`issuer` takes the same type, for a smaller reason.** Every token read above carries `iss` (OpenID Connect requires it of an ID token and RFC 9068 of an access token), so no issuer needs the opt-out for absence. It is needed for the opposite case: Microsoft's multi-tenant endpoints publish one key set and put the tenant in `iss` (`…/{tenant}/v2.0`), so a ring over those keys cannot name one issuer and has to say `.unchecked` and read `tid` itself. A key set that is one issuer's alone makes the check redundant rather than wrong, and redundant is the cheap side to err on. The two fields differ in how much a mistake costs (a missing `aud` is the confused deputy; a missing `iss` on a single-issuer key set is nearly nothing), and one type for both is chosen anyway: two spellings of "skip this check" would be one to remember and one to forget.

### A key set is swapped whole, and freed after its readers

**`jwt.Keyring` holds the current set behind an atomic pointer. A verify pins the set it is about to read and unpins it after; a swap publishes the new set, waits for the old set's pins to reach zero, and frees it. Readers never wait.**

```zig
var google: jwt.Keyring = try .init(gpa, .{
    .url = "https://www.googleapis.com/oauth2/v3/certs",
    .issuer = .{ .is = "https://accounts.google.com" },
    .audience = .{ .is = client_id },
});
try app.provide(&google);
try app.before(fetchKeys, .{ &google, &api });   // google.refresh(run, api, now_s)

const claims = try google.verifyOrRefresh(Claims, c.arena(), token, now_s, c, &api);
```

The pin is two counters. A reader increments `crossing`, loads the pointer, increments the set's own `readers`, then decrements `crossing`. A swap exchanges the pointer, waits for `crossing` to reach zero, then waits for the old set's `readers` to reach zero. Without `crossing`, a reader that had loaded the old pointer but not yet pinned it could increment a count on memory the swap had already freed; once the swap has seen `crossing` at zero after the exchange, every pin the old set will ever get is already counted, and its own count is the truth. The exchange and the `crossing` operations are `seq_cst`, a store on one side ordered against a load on the other being the one pattern acquire and release do not cover.

**The one wait is the writer's, it spins, and it is bounded by one verify.** A tool module has no `Io` to give `std.Io.Mutex`, and the rule for a lock down here is that it spins and holds nothing that itself waits. A verify is CPU work with no wait in it, so a spin on its count ends when the verify does; a swap runs once per rotation, so the spin is paid once, by the fiber that fetched the new document, never by a request.

**An unknown `kid` triggers a fetch at most once per `refresh_interval_s`.** `verifyOrRefresh` is `verify`, and on `NoSuchKey` a compare-and-swap on the last-refresh time: whichever verify sees the miss first takes the slot, fetches, reloads, and verifies again; the others inside the interval get `NoSuchKey` as before. Under a real rotation that is a handful of failures in the second the first new-key token arrives; under a flood of forged tokens it is one GET a minute to the issuer, which is the bound. A scheduled `refresh` records its own time too, so a miss straight after one does not fetch again.

**The client is a parameter, and the module still imports nothing.** `refresh(scope, client, now_s)` asks `client` for one call, `get(scope, url, .{})` answering `ok()` and `body.view()`, which is what `fetch.Client` answers and what a fake answers under `zig test jwt/jwt.zig`. `job.Table` takes its Db as a type for the same reason: the queue sits on the database without importing it, and the ring takes the client as an argument without importing `nilo_fetch`.

**Issuer, audience and leeway live on the ring once**, not on every `verify` call, because they are properties of the issuer whose keys the ring holds.

### Where it sits

**A tool module, importing nothing at all.** `zig test jwt/jwt.zig` runs the whole of it with no `build.zig`, the layer's entry condition rather than a convenience. `nilo_http` does not name it, the way it does not name `nilo_cache` (and names `nilo_fetch` only inside `app.trace`, [ADR 247](./247-a-request-is-a-span-and-the-trace-leaves-as-otlp.md)): a program that signs nobody in with Google links no RSA and no P-256, and a project that wants one writes `@import("nilo_jwt")`.

## What was rejected

**Vendoring a JWT library.** Less code here, and a third-party dependency in the path of every sign-in, the one place this repository has been most careful not to put one. The arithmetic that is genuinely hard is std's, already, and audited by everybody who runs a TLS client in Zig; what is left is a base64 split, a string comparison and a handful of date checks.

**Dispatching on the header's `alg`, then checking the key's type agrees.** The same two comparisons in the other order, with the same outcome on every input this module's tests can name, and rejected for the order itself: a reader who sees `switch (alg)` at the top of `verify` learns that the token picks the code path, and the next contributor adds their branch there. Switching on the key teaches the opposite, and the header comparisons read as the refusals they are.

**Skipping an unknown curve at `parseKeys`, the way an unknown key type is skipped.** Simpler, and it turns a key nilo cannot use into a key that looks not there, which the module already tells callers means "refetch": forever, for a curve no refetch will ever produce.

**An `alg` field on `Options`, to pin one algorithm per call.** A caller mid-migration would have to know which their issuer is on this week; the key set already knows.

**A mutex around the swap.** Readers under a mutex wait for the writer and a writer waits for every reader; `std.Io.Mutex` needs an `Io` this layer has none of, and a spinning reader-writer lock puts two read-modify-writes on every verify.

**A generation and a copy, the way `nilo_cache` answers the same question.** That works because a cache value is flat and can be copied out before a read-after check; a key set is not flat (an RSA verify reads `n` and `e` for the length of a modular exponentiation), so a copy is not the answer here.

**Freeing the old set on the next swap, with no wait.** Simpler, and wrong twice: a reader can still be inside a verify from two rotations ago on a slow thread, and a ring refreshed once at startup and once a week would hold a dead set for a week.

**Fetching inside the module**, `jwt.Jwks.fetch(url)`. Puts `nilo_fetch` under `jwt/`, which `zig build layering` refuses; and it decides, rather than bounds, the policy of when a miss means fetch and when it means refuse: a caller who wants no automatic fetch calls `verify` rather than `verifyOrRefresh`.

**`audience` as a plain required string.** What the todo list proposed if no issuer lacked an `aud`, and one does not: a Cognito access token carries `client_id` and no `aud`, as do Clerk's session tokens, and a required string would leave those callers inventing a value that matches nothing or giving up the module. Cognito, Clerk and Keycloak are not corners; they are three of the ones a caller asks about first.

**A required `?[]const u8`, so that `.audience = null` is the opt-out.** The same compile error for forgetting, with an opt-out that reads as a value: `null` is what a reader takes for "not set yet", and a reviewer scanning a diff for a skipped check finds `.unchecked` by name and `null` only by knowing to look.

**Keeping `null` as the default and logging a warning at `init`.** `std.log.err` is for a server refusing to start and `warn` is what a log line nobody reads is made of; ADR 044 says what the rule is for a check whose omission is silent, and a line in the log is a way of documenting it.

**A refusal in `refusals/` for the missing field.** The compile error is Zig's own `missing struct field: audience`, which names the field and points at the declaration this ADR's doc comment sits on. `nilo_jwt` has no refusals table (there are nine, none of them this module's), and a table is a row in `build.zig` for a message that would say what Zig already says.

**HS256, the EC families beyond P-256, JWE, and signing.** Signing is absent because a server issuing its own sessions has `Session(T)` sealed into a cookie, and a client that cannot hold a cookie has `Bearer(T)`, the same seal in an `Authorization` header ([ADR 265](./265-a-bearer-token-is-a-session-sealed-for-a-header.md)), and does not need a token it can read at all. HS256 is one call to `std.crypto.auth.hmac.sha2.HmacSha256`, and it stays out because the shared-secret shape is what makes the `alg`-confusion attack possible: a module that verifies both a shared secret and a public key has to be careful about something a module that verifies only public keys cannot get wrong.

## What it costs

| Axis | Cost |
|---|---|
| Allocations per request | none beyond `verify`'s own; a `Keyring` pin is three atomic operations and no allocation, and a swap allocates the new set once per rotation |
| Memory per idle connection | unchanged: a caller holds a pointer on its stack for as long as it held a `*const Keys` before |
| Throughput and p99 | unmeasured beyond the RSA or ECDSA verify itself (a modular exponentiation, or `EcdsaP256Sha256.Signature.verify`); a `Keyring` adds three atomics on top. The roadmap still holds "whether a sign-in endpoint should cache a verification or just do it" open, waiting on that number |
| Binary size | 0 for a program that never imports `nilo_jwt`, a linker fact rather than a promise; one that does links RS256 and ES256 both, since the choice between them is a runtime switch on the key |

`Expect` moves none of the four axes. It is a tag and a slice where an optional slice was, in an options value on the stack and once in a `Keyring`; `verify` makes one more `switch` on a tag it made one `if` on a pointer for, and allocates nothing it did not. No number was measured for this, since there is no instruction an allocation count or an idle connection could notice it in; `python3 bench/release.py` is the run that would, and `bench/release/jwt.zig` has to be rewritten to the new spelling before it runs.

Every failure in this module is a typed error rather than a Refusal, held by tests against a token signed by somebody else's implementation and, for ES256, against RFC 7515 Appendix A.3's own worked vectors: a vector produced by the code under test only proves the code agrees with itself, where a vector from the RFC or from an independent library checks the padding and the DigestInfo prefix against something that was not written by the code being tested.
