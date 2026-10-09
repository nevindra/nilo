# A fallback session secret opens and never seals

**Status:** accepted
**Topic:** [cookies-sessions](../design/cookies-sessions.md)
**Extends:** [ADR 033](./033-a-session-is-sealed-into-the-cookie.md), which left rotation open.

## Context

A session is sealed under one secret ([ADR 033](./033-a-session-is-sealed-into-the-cookie.md)), so changing it signs everybody out at once. That makes the secret the one a team never changes: a rotation costs a support morning, so it is put off, and a secret nobody rotates is one that has been in every `.env`, every CI log and every laptop since the project began. ADR 033 left the question open with four parts: how long to keep an old key, how many, where the list comes from, and what happens to a cookie sealed under one that has been dropped. It was built ahead of anybody being caught by the lack of it, because a rotation nobody can afford happens only when it is forced, and by then the old secret has had years to spread.

## Decision

**`listen(.{ .session_secret = new, .session_fallback_secrets = &.{old} })` seals every new session under `new` and still opens a cookie sealed under `old`.** A fallback secret opens and never seals.

The four parts, answered:

1. **How long: one `max_age`, and the seal is what makes that the whole wait.** The expiry is inside the seal (ADR 033), and a fallback changes which key opens a cookie, never how long the cookie lives. So once the longest `max_age` the application seals with has passed since the switch, every cookie sealed under the old secret has expired, and dropping it signs out nobody who was still signed in. With no `max_age`, that is `default_max_age`, 24 hours.
2. **How many: three.** `nilo.session.max_fallbacks`. Each costs one decryption for every cookie the current secret does not open, below. One `max_age` is the most a secret needs, so a fourth means rotating faster than a session lasts, and the answer to that is a shorter `max_age`.
3. **Where from: the application, like the secret itself.** An environment variable, a mounted file, a secrets manager. `listen()` checks and copies them, so what was passed does not have to outlive the call.
4. **A cookie under a dropped secret is no session**, the answer to every other failure to open. The person signs in again.

The current secret is tried first and the fallbacks only when it fails, in the order given. A `Bearer(T)` token ([ADR 265](./265-a-bearer-token-is-a-session-sealed-for-a-header.md)) is opened the same way, under the same secrets, so one rotation covers cookies and tokens. A cookie that decrypts under a fallback secret is then held to the version, the shape and the expiry exactly as one under the current secret is.

`listen()` refuses to start on four mistakes, each in one line: a fallback secret of the wrong length, more than three, fallback secrets with no `session_secret`, and a fallback secret that is the current one or listed twice. Fallbacks with no current secret would open cookies nothing can seal any more. A repeated one is a rotation that did not happen: the configuration would work, and the person who wrote it would believe an old secret had stopped sealing when it had not.

## Why no key id in the cookie

Trying each key needs no change to the cookie. A key id would: a byte in front of the nonce, `format_version` 3, and a cookie from before the upgrade read as no session. **Adding rotation would have signed everybody out once**, the exact cost rotation exists to remove, and it would have been paid by every application whether it ever rotated or not. What trial costs instead is a decryption per fallback on a cookie the current secret does not open, bounded by three, and nothing on one it does, which is nearly every cookie. Rails' `MessageEncryptor` rotations and gorilla's `securecookie` both try in turn for the same reason.

## Why two deploys on several instances, and why the word is "fallback"

ADR 033 requires the secret to be the same on every instance. A rolling deploy breaks that for a few minutes: the instances already updated seal under the new secret, and a request that lands on one not yet updated brings a cookie it cannot open. So on several instances a rotation is two deploys. The first adds the new secret as a fallback and changes nothing else, so every instance learns to open it while none seals under it. The second swaps the two, and the old secret becomes the fallback.

The option was first written as `session_retired_secrets`. It was renamed before it shipped, because the first of those deploys lists a secret that has never sealed anything, and "retired" says the opposite. "Fallback" is true of both deploys, and it is the name Django gives the same setting (`SECRET_KEY_FALLBACKS`).

## Why it is not for a leaked secret

A fallback secret still opens every cookie sealed under it, including one somebody forged with it. Rotating on a schedule and responding to a leak are different operations: the first keeps everybody signed in, the second must not. A leaked secret is dropped outright, which is the one-secret behaviour this leaves unchanged. The option's documentation says so, because the two look the same in a configuration file.

## What was rejected

- **A key id in the cookie**, above: it would sign everybody out to add the feature.
- **Re-sealing a cookie that opened under a fallback secret**, so it moves to the new secret on the next request. A `Set-Cookie` on a response the handler did not write, which ADR 033 refused for sliding expiry, and written without the `path`, `domain` and `max_age` the handler sealed it with, which a read does not know. The expiry already ends the old secret's cookies; nothing has to move them.
- **An end date on each fallback secret**, so nilo stops opening it on its own. The expiry inside the seal already does that for every cookie, so a date would be a second clock that has to agree with the first, and a fallback secret past its date would sit in the configuration looking live.
- **No limit.** Every cookie of the right length that the current secret does not open pays one decryption per fallback, and that includes a forged one. A list nobody bounds is a cost nobody stated.
- **A second option for the secret about to be used**, beside the one for the secret just replaced. Both are opened and never sealed under, so they are one list, and the two deploys above are one option used twice.
- **A slice on `Ctx`.** 16 bytes on every request for something only a cookie the current secret refused reads. `Ctx` holds a pointer to the App's slice instead, 8 bytes.

## What it costs

| Axis | Cost |
|---|---|
| Allocations per request | None. The fallbacks are copied onto the App at `listen()`, into a fixed array of three. |
| Memory per idle connection | Unchanged. `Ctx` grows by 8 bytes, from 816 to 824, and `bench/mem.py` against `nilo-hello` reads 5,190 B at 10,000 connections before and after, interleaved twice, the same to the byte ([the run](../../bench/result/http.md#a-fallback-session-secret)). |
| Throughput and p99 | Nothing on a request with no session, and nothing on one whose cookie opens under the current secret. A cookie sealed under a fallback secret, or a forged or stale one of the right length, pays one refused decryption per key before it: **270 ns** each, against 374 ns for the decryption that opens, ReleaseFast on one pinned core. A forged cookie with three fallback secrets costs four refusals, about 1.1 µs. |
| Binary size | **+624 B** on `hello` and **+592 B** on `rest`, stripped `ReleaseFast`, the check and its four messages in `listen()`, which every program that listens links. |

## What it breaks

Nothing. An application that never names `session_fallback_secrets` seals and opens as before, and the cookie format did not change, so no session out there is signed out by the upgrade.
