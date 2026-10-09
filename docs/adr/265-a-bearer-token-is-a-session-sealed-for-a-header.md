# A bearer token is the session's seal carried in a header

**Status:** accepted
**Topic:** [cookies-sessions](../design/cookies-sessions.md)
**Extends:** [ADR 033](./033-a-session-is-sealed-into-the-cookie.md), [ADR 111](./111-nilo-verifies-a-token-and-does-not-fetch-one.md), [ADR 225](./225-a-fallback-session-secret-opens-and-never-seals.md)

## Context

A client that sends its session as `Authorization: Bearer …`, a native mobile application most often, had nothing in nilo to sign in with. nilo signs no token ([ADR 111](./111-nilo-verifies-a-token-and-does-not-fetch-one.md)), and the way round on record was to write four lines of `HmacSha256`, where a signature compared with `std.mem.eql` compiles and leaks by timing: the shape of mistake that module exists to keep out. What such a client needs already existed and is better than an HS256 token: `session.seal` and `open` make an encrypted, expiring value in base64, with no `alg` to confuse. It was reachable only as a cookie. `Session(T)` read `__Host-session` and nothing else, the key sat in `Ctx`'s private `_session_key`, and the public `open` took no fallback secrets, so a token opened by hand stopped opening the day the secret rotated.

## Decision

**`nilo.Bearer(T)` is a resolved value that reads the seal of a `Session(T)` from `Authorization: Bearer <token>` instead of a cookie, and `Bearer(T).issue(c, value, .{ .max_age = n })` mints one.** The key never leaves the framework.

```zig
fn signIn(c: *nilo.Ctx, login: Login) !Token {
    const id = try accounts.check(login);
    const t = try nilo.Bearer(Signed).issue(c, .{ .user = id }, .{ .max_age = 3600 });
    return .{ .token = t.text, .expires_in = t.expires_in };
}

fn me(b: nilo.Bearer(Signed)) !Profile {
    const signed = try b.require();
    return profiles.find(signed.user);
}
```

- **The same machinery.** The struct checks on `T`, the plaintext layout, the fingerprint, the expiry inside the seal, `session_secret` and `session_fallback_secrets` (so rotation per ADR 225 covers tokens with no second setting), read once per request, `nilo_reads_caller`, and a `nilo_type_name`. A token is opaque to its client, so a client cannot read the claims; a `/me` route is how it learns them.
- **Absent is a null.** `value: ?T` and `get() ?T`, as the session's. Another scheme (Basic) in the header is no token. The scheme is matched case-insensitively (RFC 9110 section 11.1), through the same `split` as `Authorization(…)` (ADR 153).
- **`require() !T` is the 401.** Through `fail.challenge`, which already carried a `WWW-Authenticate` value ([ADR 153](./153-an-authorization-header-a-handler-can-ask-for.md)): `Bearer` when nothing came, `Bearer error="invalid_token"` when a token came and did not open (RFC 6750 section 3.1). Both are comptime strings, so `fail.zig` did not change.
- **The size bound is the request head's.** A cookie is held to 3,800 bytes because a browser drops a larger one; a header is held by the head the server reads, 16 KiB by default with the rest of the head to share it. `max_bearer_bytes` is 8,000 once sealed and base64'd, and a larger `T` is a Refusal while compiling.
- **A token and a cookie do not open as each other.** The seal is an AEAD and has a slot for associated data that the cookie left empty. A bearer token is sealed with the associated data `nilo.bearer`. It is covered by the tag and stored nowhere, so the token is no longer, and the cookie format is byte-identical: every session already out there opens as before. Without this, a session cookie's value, which a page's script cannot read but a browser extension, a proxy log or a support ticket can, would be a bearer token for anything taking `Bearer(T)` of the same shape, and the reverse.
- **CSRF is unchanged.** A native client sends neither `Origin` nor `Sec-Fetch-Site`, so rule 5 of ADR 224 already lets its POST through; nothing had to be exempted. Exempting a request because it carries an `Authorization` header was considered and refused: a cross-site page can set that header only through a CORS preflight, which `cors` decides, so the header adds no protection the CSRF check lacks, and a rule keyed on a header an attacker chooses is one a request carrying a session cookie could ride past. A browser SPA on another origin sending a bearer token is named in `csrf .origins` like any other, and a request that carries a session cookie is checked as before.
- **The document.** A handler taking `Bearer(T)` gets `security: [{bearerAuth: []}]` and a `bearerAuth` scheme in components, the one `Authorization(.bearer)` writes (ADR 153), found through the `nilo_bearer` marker. A resolver that takes a `Bearer` is a function body to the document and is not read, as a guard's cookie is until `app.guard` says so.

## What was rejected

- **A hand-written HS256 beside `nilo_jwt`**, the position `docs/decided.md` held. It left the constant-time compare to the caller. `nilo_jwt` still verifies RS256 and ES256 only; a token from an issuer other than this server is `Verified(V)`.
- **Signing JWTs.** An application issuing a token to its own client does not need one the client can read, and a token with an `alg` header is the confusion ADR 111 refuses.
- **A separate secret for tokens.** Two settings to rotate and to forget. One secret opens both, and the purpose in the associated data keeps them apart.
- **A key exposed so the application can call `seal`.** The key stays in `Ctx`; `issue` is the one way out.
- **A purpose byte in the plaintext.** It would change `format_version` and sign every session out once, the cost ADR 225 refused for a key id.
- **Reading the token from a query string or a cookie as a fallback.** A token in a query string is in every log on the way (ADR 153).
- **A revocation list.** A token cannot be revoked before its expiry, for the reason a session cannot (ADR 033): short `max_age`s, and a version number of the application's own inside `T`.

## What it costs

| Axis | Cost |
|---|---|
| Allocations per request | None for a route that does not take `Bearer(T)`: the code is reached only by naming it. A route that takes one pays what a `Session(T)` does (the resolved-value memo), pinned by a test that compares the two; `issue` takes the token's bytes from the arena, on the routes that issue. |
| Memory per idle connection | Unchanged. No field was added to `Ctx` or to the connection. |
| Throughput and p99 | Nothing on a request that does not read a token. A token costs one decryption per key tried, as a cookie does (ADR 225), and the purpose is a compare-free input to the AEAD. |
| Binary size | Only in a program that names `Bearer`. `listen()` and the default build gain nothing. |

## What it breaks

Nothing. `seal` and `open` keep their signatures and their bytes; `authorization.split` became public.
