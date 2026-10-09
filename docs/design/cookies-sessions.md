# Cookies and sessions

**A cookie is read in place and never decoded, and a session is a cookie with policy on top: sealed into the cookie, never stored on the server.**

**Guide:** [Cookies](../guide/cookies.md), [Sessions](../guide/sessions.md) · **Reference:** [`Cookie`](../reference/ctx.md#cookie), [`Session(T)`](../reference/ctx.md#sessiont), [`Bearer(T)`](../reference/ctx.md#bearert)

The code is `http/cookie.zig` and `http/session.zig`, plus `putHeader` in `http1.zig`, which every response header passes through.

## Overview

```
Cookie header (request)  ──►  c.cookie(name)   Str, borrowed, undecoded
handler's own struct T   ──►  s.set(value)  ──►  seal  ──►  Set-Cookie (response)
                                              │
                             [version][fingerprint of T][expires_at][fields]
                             XChaCha20Poly1305, key from the application
                             (opened under the current key, then each fallback)
```

Every response header passes through `putHeader`, cookie or not, so a check written there covers every way of setting one. `Set-Cookie` and `Vary` are the two response headers that repeat instead of replacing each other, for opposite reasons.

## Rules

1. **Reading a cookie allocates nothing and decodes nothing.** `c.cookie(name)` walks the `Cookie` header in place and returns a `Str` pointing into the request head. RFC 6265 treats the value as opaque bytes, and nilo does not guess at an encoding someone layered on top. [ADR 029](../adr/029-a-header-is-checked-once-and-two-of-them-repeat.md)
2. **Every response header goes through `putHeader`, which rejects three things**: a reserved name (`Content-Type`, `Content-Length`, `Transfer-Encoding`, `Connection`), a name outside RFC 9110's `token` grammar, and a value containing a control byte below `0x21` other than SP or HTAB, or `0x7F`. All three are `fail.internal`, and the value is never echoed back. [ADR 029](../adr/029-a-header-is-checked-once-and-two-of-them-repeat.md)
3. **`Set-Cookie` and `Vary` repeat instead of being folded into one header**; `http1.repeats(name)` lists them. `Set-Cookie` repeats because RFC 6265 forbids folding cookies with commas. `Vary` repeats because CORS and a served static file each set it on their own, and folding it in `putHeader` would cost an arena allocation on the static-file path. An exact duplicate is dropped. [ADR 029](../adr/029-a-header-is-checked-once-and-two-of-them-repeat.md)
4. **A cookie value cannot contain its own delimiter.** The grammar has no way to escape `;`, so a value containing one is rejected before anything is written, instead of silently producing a cookie with an attribute nobody wrote. `SameSite=None` without `Secure` is rejected the same way, because current browsers drop it. [ADR 029](../adr/029-a-header-is-checked-once-and-two-of-them-repeat.md)
5. **Cookie defaults are the safe ones**: `Secure`, `HttpOnly`, `SameSite=Lax`, `Path=/`. Turning one off takes a visible line of code, so it cannot be forgotten. `Secure` costs nothing during development, because browsers treat `http://localhost` as a secure context. [ADR 029](../adr/029-a-header-is-checked-once-and-two-of-them-repeat.md)
6. **A session is sealed whole into the cookie, and nothing is kept on the server.** The alternative (an opaque id plus a server-side table) costs an allocation and a lookup per request, a lock shared by every request and an expiry sweep, and it does not survive a restart. The sealed cookie costs none of that. [ADR 033](../adr/033-a-session-is-sealed-into-the-cookie.md)
7. **A session cannot be revoked, and nilo does not pretend it can.** "Sign out everywhere" is done with a version number of the application's own inside the session, checked against a lookup the application already does. [ADR 033](../adr/033-a-session-is-sealed-into-the-cookie.md)
8. **`Session(T)` rejects a slice while compiling.** A cookie holds roughly 4 KB and a browser silently drops a larger one, so a session may hold numbers, bools, enums, fixed arrays, optionals and nested structs of those. [ADR 033](../adr/033-a-session-is-sealed-into-the-cookie.md)
9. **The sealed plaintext is `[version][fingerprint of T][expires_at][fields]`.** Fields are written one at a time instead of copying the struct's memory, because the compiler is free to change a struct's layout. The fingerprint changes when a field is added or reordered, so a cookie sealed under an old shape reads as no cookie instead of as plausible garbage. `format_version` is 2. [ADR 033](../adr/033-a-session-is-sealed-into-the-cookie.md)
10. **The expiry is sealed inside the cookie, not only sent as `Max-Age`.** The client can edit or drop `Max-Age`; `expires_at` sits under the AEAD tag, so it is a number the server wrote, and `open` checks it after decrypting. `max_age = null` still seals `default_max_age` (24 hours), even though it asks the browser to forget the cookie when the session ends, because a copied cookie ignores that request. An expired session returns `null`, the same as every other failure. [ADR 033](../adr/033-a-session-is-sealed-into-the-cookie.md)
11. **The cipher is `XChaCha20Poly1305`, so the session is encrypted, not only signed.** The user cannot read back a field like a role or a tenant id. A fresh 192-bit nonce is generated every time, because the server has nowhere to keep a counter. [ADR 033](../adr/033-a-session-is-sealed-into-the-cookie.md)
12. **The secret belongs to the application and has no default.** `listen()` checks its length and refuses to start instead of sealing with zeroes. Using `Session(T)` with no secret set answers a 500 naming the option. [ADR 033](../adr/033-a-session-is-sealed-into-the-cookie.md)
13. **`Session(T)` is a resolved value, decrypted once per request however many things ask for it, and reading and writing are separate calls** (`s.value` versus `s.set(...)`). Changing a by-value copy would compile cleanly and do nothing. [ADR 033](../adr/033-a-session-is-sealed-into-the-cookie.md)
14. **A fallback secret can open a cookie but never seals one**, so the secret can change without signing anybody out. The current secret is tried first, then up to three fallbacks in order. The cookie carries no key id, because adding one would change the format and sign everybody out once. The sealed expiry limits how long the old secret matters: one `max_age` after the switch, nothing sealed with it opens anyway. With several instances, a rotation takes two deploys, the first adding the new secret as a fallback. A leaked secret is removed, never kept as a fallback. [ADR 225](../adr/225-a-fallback-session-secret-opens-and-never-seals.md)
15. **The session cookie is named `__Host-session` wherever that prefix can apply, and the plain `session` is read only when the program says it writes one.** With `Secure`, `Path=/` and no `Domain`, a sibling subdomain cannot plant its own session under a path of this site, whether or not the visitor is signed in. `listen(.{ .session_plain_name = true })` reads the plain name after the prefixed one, for a session with a `domain`, another `path` or `secure = false`, and for a program upgrading from 0.6.0, whose next `set` moves each visitor to the new name. [ADR 033](../adr/033-a-session-is-sealed-into-the-cookie.md)
16. **A client with no cookie jar gets the same seal in an `Authorization: Bearer` header.** `Bearer(T)` reads it (`get()`, or `require()` for the 401 with `WWW-Authenticate`), `Bearer(T).issue(c, value, .{ .max_age })` mints it, and the secret and fallbacks are the session's, so rotation covers both. The seal's associated data is `nilo.bearer` for a token and empty for a cookie, so neither opens as the other and the cookie format did not change. [ADR 265](../adr/265-a-bearer-token-is-a-session-sealed-for-a-header.md)

## Decisions

| ADR | What it decides |
|---|---|
| [029](../adr/029-a-header-is-checked-once-and-two-of-them-repeat.md) | Cookies as a mechanism: reading, the single place headers are checked, and which headers repeat |
| [033](../adr/033-a-session-is-sealed-into-the-cookie.md) | A session as policy on top of that mechanism: sealed, encrypted, expiring, not revocable |
| [225](../adr/225-a-fallback-session-secret-opens-and-never-seals.md) | Rotating the secret: fallback secrets open and never seal, three at most, kept for one `max_age` |

| [265](../adr/265-a-bearer-token-is-a-session-sealed-for-a-header.md) | `Bearer(T)`: the same seal in an `Authorization` header for a client with no cookie jar, bound to its own purpose, issued by the framework |

Related topics: a `Session(T)` is not a `Token`; see [jwt](jwt.md) for the credential nilo verifies but does not issue. The clock the sealed expiry is checked against is [ADR 041](../adr/041-core-knows-what-time-it-is.md), and the entropy the nonce comes from is [ADR 042](../adr/042-entropy-belongs-to-the-loop.md), both in [id-clock-entropy](id-clock-entropy.md).

## Open questions

Nothing is open.
