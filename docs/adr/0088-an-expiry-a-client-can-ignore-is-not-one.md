# 0088 — an expiry a client can ignore is not one

**Status:** accepted
**Amends:** [ADR 0035](./0035-a-session-is-sealed-into-the-cookie.md)

## Context

A nilo session is sealed into the cookie: no table, no sweep, no lock
(ADR 0035). The sealed plaintext was `[version][fingerprint][fields]`, and
`open` verified the tag, the version and the shape fingerprint. **There was no
time in it anywhere.**

So the only thing bounding a session's life was `Max-Age` on the cookie — which
is an instruction to a browser. A browser obeys it. A copy of the cookie taken
out of a proxy log, a `curl -v` pasted into a ticket, a backup, or somebody
else's machine does not obey anything: it opens, and it goes on opening until
the secret is rotated, which signs out everybody at once.

**The documentation had already promised otherwise**, which is what made this
worth fixing rather than worth writing down. `docs/guide/sessions.md` offers

```zig
try s.setWith(.{ .user = id }, .{ .max_age = 30 * 24 * 60 * 60 });   // 30 days
```

under the heading *Staying signed in*, and three paragraphs later says *"A
sealed cookie is valid until it expires"* and *"a cookie somebody copied still
opens"*. Both sentences are in the file. Read together they say the copy stops
working after thirty days, and it did not — the two halves of the same page
described different behaviour, and neither described what the code did.

This is **not** the revocation gap. That one is on the roadmap under *Signing
out everywhere*, its answer is a version number checked against the row the
handler was fetching anyway, and it needs a store to do better. Expiry needs no
store at all: it is a number the server already knows when it writes the cookie.

## Decision

**The seal carries the moment it stops opening, and `open` refuses it after
that.**

The plaintext is now `[version:1][fingerprint:4][expires_at:8][fields]`, with
`expires_at` in **seconds since the epoch**, little-endian, and `format_version`
is 2.

**Inside the seal rather than beside it**, which is the whole decision. An
expiry in the cookie's own `Max-Age` is the client's to edit or drop; an expiry
under the AEAD tag is the server's. The read happens after `Cipher.decrypt` has
succeeded, so it is a number this server wrote.

**`Options.max_age` fills both halves from one number.** It sets the cookie
attribute, as before, and the sealed expiry, which is new. An application that
wants thirty days writes thirty days once and now gets it.

**A session cookie still has a ceiling.** `max_age = null` means "ask the
browser to forget this at the end of the window", and that is the right default
for a sign-in — but it says nothing to a copy. So null seals `default_max_age`,
which is **24 hours**: long enough that nobody working an ordinary day is signed
out under them, short enough that a leaked cookie is a problem with an end. It
is a ceiling on the copy, not a target for the browser.

**An expired session is `null`, like every other failure.** ADR 0035 already
settled that tampered, truncated, wrong-secret and wrong-shape all answer the
same thing, because the application has one thing to do about all of them.
Expired joins the list rather than becoming a distinguishable state that invites
a handler to treat it as "nearly signed in".

**`openAt(T, text, key, now)` is public and `open` calls it.** This is not a
convenience — it is [ADR 0033](./0033-a-guard-is-not-a-guard-until-it-has-been-seen-to-fail.md)
applied. An expiry that could only be exercised by waiting a day is a guard that
would only ever be *seen to pass*, which is exactly the shape that ADR refuses.
With `openAt`, the moment before, the moment of, and the moment after are three
lines in a test. It is also what lets an application stand a session at any age
it likes without moving the machine's clock.

## What was rejected

**Trusting `Max-Age` and doing nothing.** It is what was there. It works right
up until somebody has a copy of the cookie, which is the only case an expiry is
for.

**A separate `lifetime` option beside `max_age`.** Two knobs that must agree, on
a feature whose failure mode is silent. The one number is the point.

**No ceiling when `max_age` is null.** It reads as the conservative choice and
is the opposite: a session cookie is the *default*, so "no ceiling unless you
ask" would leave the common path unbounded and the rare one bounded.

**Milliseconds.** `Max-Age` counts seconds, a session measured to the
millisecond is a session nobody asked for, and it would cost the same eight
bytes for range nobody uses.

**Sliding expiry — re-sealing on each request to extend it.** It would put a
`Set-Cookie` on every response that carries a session, which is a header on the
hot path for a policy nobody has asked for. An application that wants it calls
`s.set` with the value it already has.

**Keeping `format_version` at 1.** The size check refuses a version-1 cookie
anyway, because the plaintext grew by eight bytes. Bumping it means the guard
that fires is the one that can say *why*.

## What it costs

**Allocations per request: unchanged at zero.** The expiry is eight bytes inside
a fixed-size buffer that was already there.

**Memory per idle connection: unchanged.** Nothing is stored anywhere.

**Throughput: one clock read per request that carries a session cookie**, and
none at all for a request that does not. `nilo_core`'s clock is a read from a
page the kernel keeps mapped, measured at **15ns** in ADR 0045 — against an
XChaCha20Poly1305 decrypt on the same path. A route with no session is untouched,
which is what the primary metric measures.

**Cookie size: +12 bytes** on the wire — eight bytes of plaintext through
base64. The ceiling in `max_cookie_bytes` is unchanged at 3,800, so what a
`Session(T)` may hold shrinks by those eight bytes. The refusal that names the
number moved from 5,528 to 5,540 and is checked by `zig build refusals`.

**Binary size: not measured, and not claimed.** Two `readInt`/`writeInt` calls
and a comparison on a path only a session reaches.

**The one behaviour change a user can see, and it is a real one:** everybody
holding a session is signed out on upgrade, because the plaintext layout moved.
That is the same thing adding a field to the session struct has always done and
the guide already documents it under *Changing the shape is safe*. And from then
on, a session cookie that used to work indefinitely stops after a day unless
`max_age` says otherwise. Both belong in the release notes, and neither is worth
keeping an unbounded token to avoid.
