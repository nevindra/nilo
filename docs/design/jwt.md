# JWT verification

**nilo verifies tokens that someone else signed, and never signs or fetches tokens of its own.**

**Guide:** [Checking somebody else's token](../guide/jwt.md) · **Reference:** [`nilo_jwt`](../reference/jwt.md)

The code is `jwt/token.zig`, `jwt/keyring.zig`, `jwt/memo.zig`, `jwt/verifier.zig`, `jwt/rs256.zig` and `jwt/es256.zig`, with the App-layer half in `http/verified.zig`.

## Overview

```
issuer's JWKS ──► Keyring (rotates the key set, no race) ──► Verifier(Claims, Client)
                                                                       │
                                                     nilo.Verified(V) reads it,
                                                     or a 401 before the handler runs
```

A `Keyring` holds one issuer's keys behind an atomic pointer and refreshes them. A `Verifier` combines a `Keyring` with the client that fetches the keys and the claims type a handler wants. `nilo.Verified(V)` is the argument a handler writes. It is not a resolved value or middleware; it has its own role in the typed engine.

## Rules

1. **`nilo_jwt` verifies; it does not fetch tokens, do discovery, do PKCE or check a nonce.** Verification is where a mistake goes unnoticed. A fetch that fails, fails loudly, and fetching is already `nilo_fetch`'s job. [ADR 111](../adr/111-nilo-verifies-a-token-and-does-not-fetch-one.md)
2. **The key decides the algorithm, never the token's header.** `alg` is checked twice: before the key lookup, against the two algorithm names the module knows, and after it, against the one name the found key belongs to. A key of an unknown type is skipped rather than rejected, so an issuer publishing a new key type mid-migration cannot break verification. A key of a known type with an unsupported size or curve is rejected by name. [ADR 111](../adr/111-nilo-verifies-a-token-and-does-not-fetch-one.md)
3. **RS256 and ES256 only.** No HS256 (a shared secret is what makes confusing the header and the key possible), no other curves, no JWE, no signing. [ADR 111](../adr/111-nilo-verifies-a-token-and-does-not-fetch-one.md)
4. **Nothing is read until the signature is verified.** `exp` is required, `iss` and `aud` are checked against what the caller said, and the caller's claims struct is only filled after all of that. **`issuer` and `audience` have no default**: each is a `jwt.Expect`, `.{ .is = "…" }` or `.unchecked`, so forgetting one is a compile error and skipping one is a word in the diff. `.unchecked` exists because Cognito's and Clerk's access tokens carry no `aud`. [ADR 111](../adr/111-nilo-verifies-a-token-and-does-not-fetch-one.md)
5. **When a `Keyring` swaps in a new key set, the old one is freed only after every reader using it has finished.** So a verification never waits, and a rotation takes effect immediately for any lookup by `kid`. [ADR 111](../adr/111-nilo-verifies-a-token-and-does-not-fetch-one.md)
6. **An unknown `kid` triggers at most one fetch per `refresh_interval_s`.** On a miss, callers race a compare-and-swap on the last-refresh time; the loser gets `NoSuchKey` as before. That limits a flood of forged tokens to one GET to the issuer per interval. [ADR 111](../adr/111-nilo-verifies-a-token-and-does-not-fetch-one.md)
7. **The client the keyring refreshes through is a type parameter, and `nilo_jwt` imports nothing at all**: `zig test jwt/jwt.zig` tests all of it without `build.zig`. `nilo_http` does not name `nilo_jwt` either: `http/verified.zig` looks for the `nilo_verifier` marker instead of importing the module, so a server that never uses `Verified` links none of it. [ADR 111](../adr/111-nilo-verifies-a-token-and-does-not-fetch-one.md), [ADR 191](../adr/191-verified-claims-are-a-handler-argument.md)
8. **`jwt.Verifier(Claims, Client)` holds the keyring, the client and the claims type as one Service, and a handler asks for `nilo.Verified(V)`.** `.claims` is parsed into the request arena and `.token` is the raw text; if verification fails, the handler never runs and the client gets a 401 with `WWW-Authenticate: Bearer`. [ADR 191](../adr/191-verified-claims-are-a-handler-argument.md)
9. **`Verified` has its own role in the typed engine instead of being a resolved value**, because a resolver takes a `*Ctx`, and a file outside `http_core` may not name one. Middleware reads the same thing with `c.verified(V)`; a handler behind a guard where both ask pays for the signature check twice. [ADR 191](../adr/191-verified-claims-are-a-handler-argument.md)
10. **Every rejection caused by the token is a 401 naming the reason** (`Expired`, `WrongAudience`, `NoSuchKey`). The one exception is a 503: the issuer's keys could not be reached when a refresh was needed, so the token was never judged. [ADR 191](../adr/191-verified-claims-are-a-handler-argument.md)
11. **`Keyring.Options.remember_tokens` (default 0) remembers verified signatures by the token's SHA-256 digest**, so a repeated bearer token skips the signature math but still has `exp`, `nbf`, `iss` and `aud` checked on every call. The memo is cleared after a key swap, once the old set's readers have finished, so a rotated-out key cannot keep being remembered. [ADR 209](../adr/209-a-verified-signature-is-remembered-by-the-tokens-digest.md)

## Decisions

| ADR | What it decides |
|---|---|
| [111](../adr/111-nilo-verifies-a-token-and-does-not-fetch-one.md) | What the module verifies, choosing RS256 or ES256 by the key instead of the header, the `Keyring`'s lock-free swap, and why `issuer` and `audience` have no default |
| [191](../adr/191-verified-claims-are-a-handler-argument.md) | `jwt.Verifier` and `nilo.Verified(V)` as a handler argument, and why it has its own role instead of being a resolved value |
| [209](../adr/209-a-verified-signature-is-remembered-by-the-tokens-digest.md) | The signature memo keyed by the token's digest |

Related topics: the client a `Verifier` refreshes through is a Fitting (`nilo_fetch`), used as a type parameter instead of imported, which is what keeps this a tool module; see [layering](layering.md). `Authorization(.bearer)` is the step before this one, [ADR 153](../adr/153-an-authorization-header-a-handler-can-ask-for.md). A `Session(T)` is not a token; it is the alternative when nilo issues the credential itself, see [cookies-sessions](cookies-sessions.md).

## Open questions

- **Whether a sign-in endpoint should cache a verification or just redo it** has not been measured beyond the raw RSA and ECDSA cost; [ADR 191](../adr/191-verified-claims-are-a-handler-argument.md) leaves this open in its "What it costs" section.
