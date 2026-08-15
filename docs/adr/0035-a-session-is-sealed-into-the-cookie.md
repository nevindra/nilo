# A session is sealed into the cookie

ADR 0030 gave zfast cookies and stopped there, on purpose: `c.setCookie` and `c.cookie` are the mechanism, and what goes in the cookie is policy. The roadmap then sat on sessions for a release with the note that *"it is not obvious there is a shape zfast should have an opinion about rather than an example of."*

That was wrong, and what settled it was reading how somebody else answered it. jetzig keeps the whole session **in the cookie**, encrypted and signed, with no server-side store at all. That is a shape zfast can have an opinion about, because the reason to prefer it is [ADR 0018](0018-the-trade-budget-has-three-axes.md)'s second and third rows rather than taste.

## The alternative, and why it loses

The obvious design is the one every framework with a database reaches for: the cookie carries an opaque id, and the server keeps a table of id → session.

Costed against ADR 0018 it is expensive in exactly the places zfast has said it will not spend:

- **Memory per connection is the wrong metric here, but memory per *signed-in user* is a new one**, and it is unbounded. A million idle sessions is a million rows nobody is reading, plus whatever it takes to find one.
- **An allocation per request**, at least: the id has to be looked up, and a lookup that touches a hash map under a lock is not free.
- **A lock.** The table is shared across every thread serving requests, so it needs one, and it is on the path of every authenticated request rather than of the ones that write.
- **An expiry sweep** — a background fiber, or a check on every read, and a decision about which.
- **And it does not survive a restart**, so the honest version of it is not a table at all, it is Redis. That is a dependency zfast would be pushing onto every application that wants a login.

The sealed cookie has none of those. Nothing is stored, so there is nothing to sweep, nothing to lock, nothing to lose on restart, and **nothing added to the 8,767 bytes an idle connection holds**. A request that does not ask for a session runs the code it ran before.

## What it costs instead

Three things, and they are stated here rather than left to be discovered.

**A session cannot be revoked.** A sealed cookie is valid until it expires, so "sign out everywhere" is not a thing the mechanism can do. The application's answer is a number in the session that it checks — a token version bumped on password change — and that check is a lookup the application already does. zfast does not pretend otherwise.

**It is about 4 KB, and the ceiling is real.** A browser drops an oversized cookie *silently*: no error, no warning, and a session that simply never appears. That is why what a session may hold is a fixed-size struct — numbers, bools, enums, `[N]u8`, optionals and nested structs of those — and why `Session(T)` refuses a slice at compile time. A size that depends on the data is a size nobody checked.

**It goes up the wire on every request.** A 200-byte session is 200 bytes on every request to every path, static files included. That is the argument for keeping an id in it rather than a profile, and the guide says so.

## The failure that shaped the format

Add a field to your session struct and deploy. Every cookie already out there was written to the old shape, and decrypted against the new one it is not corrupt — it is **plausible**. The bytes that were a `bool` are now the low byte of a `u32`, and somebody is signed in as the wrong user.

So the sealed plaintext is not just the fields. It is a version byte, a **32-bit fingerprint of the shape of `T`** — its field names in order, with their types — and then the fields. A cookie whose fingerprint does not match this build is treated as no cookie at all: the person signs in again, which is the correct answer and the boring one.

The fingerprint covers reordering as well as adding, which a size check alone would not: `{user: u32, tenant: u32}` and `{tenant: u32, user: u32}` are both eight bytes, and reading one as the other silently swaps two ids.

The fields are also written **field by field, little-endian, with no padding**, rather than by copying the struct's memory. A struct's layout is the compiler's to change, and a cookie written by one build has to be readable by the next.

## `XChaCha20Poly1305`, and why encrypted rather than signed

A signed-but-readable cookie — the JWT shape — would have been less code. It is rejected for one reason: it makes every field of the session a thing the user can read, and that is a decision the application would be making by accident. A session holding a tenant id, a role, or an internal user number should not be a thing anybody pastes into a decoder.

The cipher is `std.crypto.aead.chacha_poly.XChaCha20Poly1305`, and the choice is mostly about the nonce. There is nowhere to keep a counter — the whole point is that the server holds nothing — so the nonce has to be random, and XChaCha20's is 192 bits precisely so that random is safe. AES-GCM's 96-bit nonce is not, at this volume, without care nobody should have to take.

Being in `std.crypto` is the other half. [ADR 0028](0028-tls-is-terminated-in-front.md) refused TLS partly because the alternatives were a one-person crypto dependency or a C toolchain in the install story. A session that needed either would have reopened that argument; one that needs neither does not.

## The secret is the application's, and it is checked at `listen()`

Where the secret comes from — an environment variable, a mounted file, a secrets manager — is the application's, the same line [ADR 0016](0016-resolved-values-are-declared-by-their-type.md) draws around authentication.

**There is no default.** A default key is a key everybody who has read this repository already has, and the failure mode of shipping with it is not a crash, it is a forgeable session. So `Session(T)` with no secret set is a 500 with a sentence naming the option, and never a cookie sealed under zeroes.

What zfast does own is telling you when it is wrong. `listen(.{ .session_secret = … })` checks the length there and stops the server with a message, because a secret of the wrong length is a deployment mistake and startup is the moment somebody is watching. It also has to be the *same on every instance* and survive a restart, and the option's documentation says so — the symptom otherwise is users being randomly signed out, which is a long way from its cause.

## `Session(T)` is a resolved value, and reading is not writing

It carries `zfast_resolve` like any other resolved value ([ADR 0016](0016-resolved-values-are-declared-by-their-type.md)), so a handler asks for it by writing it in its argument list, and the cookie is decrypted once per request however many things ask — a middleware guarding a prefix and the handler behind it do not pay twice.

Reading and writing are separate calls, and that is not an oversight:

```zig
fn signIn(s: zfast.Session(Signed)) !zfast.Redirect(303) {
    try s.set(.{ .user = id });     // and not: s.value.user = id
    return .to("/");
}
```

A resolved value is handed to the handler **by value**. A mutated copy would go nowhere, compile cleanly, and look exactly like it had worked. `set` is a line in a diff instead, next to the `c.setCookie` it turns into.

## What this does not settle

**Rotation.** Changing the secret signs everybody out at once. Doing better means a second key to decrypt with and a decision about how long to keep it, and that is a design with its own questions — how many keys, where the list comes from, what happens to a cookie sealed under a key that has been dropped. It is not built, and the roadmap says so rather than this ADR pretending it is finished.
