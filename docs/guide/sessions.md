# Sessions

**`Session(T)` seals a struct of yours into one encrypted, signed cookie, so nothing about a session is kept on the server.**

**Reference:** [`Session(T)`](../reference/ctx.md#sessiont), [`session_secret` and the other `listen` options](../reference/app.md#listen-options), [password calls on `Ctx`](../reference/ctx.md#reading), [`nilo_pw`](../reference/pw.md) · **Design:** [Cookies and sessions](../design/cookies-sessions.md)

```zig
const Signed = struct { user: u32, admin: bool = false };

fn signIn(s: nilo.Session(Signed), form: nilo.Form(Login)) !nilo.Redirect(303) {
    const id = try accounts.check(form.email, form.password.view()) orelse
        return .to("/login?wrong");
    try s.set(.{ .user = id });
    return .to("/");
}

fn me(s: nilo.Session(Signed)) !?Profile {
    const signed = s.get() orelse return null;   // null → 404
    return profiles.find(signed.user);
}

fn signOut(s: nilo.Session(Signed)) !nilo.Redirect(303) {
    try s.clear();
    return .to("/");
}
```

**Nothing is kept on the server.** The whole session is serialised, encrypted and signed, and handed to the browser as one cookie. There is no table, no expiry sweep, no lock, and nothing added to what an idle connection costs. That is the reason to choose it, not an implementation detail ([ADR 033](../adr/033-a-session-is-sealed-into-the-cookie.md)).

A request that does not ask for a session runs exactly the code it ran before.

## Setting the session secret

```zig
try app.listen(.{ .session_secret = secret });   // exactly 32 bytes
```

**nilo has no default secret; you supply one.** It can come from an environment variable, a mounted file or a secrets manager. There is no default because a default key is a key everybody who has read this repository already has.

Three things must be true of it, and getting any of them wrong fails silently:

| | why |
|---|---|
| Exactly 32 bytes | checked at `listen()`, which stops with a message |
| The same on every instance | otherwise a request lands on a machine that cannot read its own cookies |
| The same after a restart | otherwise a deploy signs everybody out |

Generate one once, and keep it wherever your other secrets live:

```
head -c 32 /dev/urandom | base64
```

A handler that asks for a `Session(T)` when no secret was set answers **500** with a sentence naming the option. It does not fall back to anything.

## Rotating the secret

**Put the new secret in `session_secret` and the old one in `session_fallback_secrets`:**

```zig
try app.listen(.{
    .session_secret = new_secret,
    .session_fallback_secrets = &.{old_secret},
});
```

Every session sealed from then on uses the new secret. A cookie sealed under the old one still opens, so nobody is signed out by the deploy ([ADR 225](../adr/225-a-fallback-session-secret-opens-and-never-seals.md)).

**Remove the old secret once one `max_age` has passed.** The expiry is sealed inside every cookie, so by then nothing sealed under the old secret can open anyway. With no `max_age` that is 24 hours; with `.max_age = 30 * 24 * 60 * 60` it is thirty days.

| | why |
|---|---|
| At most three fallback secrets | each is one more decryption, about 270 ns, for every cookie the current secret does not open |
| Each exactly 32 bytes | checked at `listen()`, like the current one |
| None the same as `session_secret`, and none twice | that is a rotation that did not happen, and `listen()` says so |
| Fallback secrets need a `session_secret` | otherwise nothing could seal a new session |

A cookie under the current secret costs exactly what it did before. Only a cookie the current secret does not open is tried under the fallbacks, in the order you listed them.

**With several instances, it takes two deploys.** While a deploy rolls out, the instances already updated seal under the new secret, and an instance not yet updated cannot open what they wrote. So stage the new secret first:

```zig
// Deploy 1: every instance learns to open the new secret. Nothing seals under it yet.
.{ .session_secret = old_secret, .session_fallback_secrets = &.{new_secret} }

// Deploy 2, once the first has reached every instance: swap them.
.{ .session_secret = new_secret, .session_fallback_secrets = &.{old_secret} }
```

A single instance can go straight to the second step.

**Do not use a fallback after a leak.** A fallback secret still opens every cookie sealed under it, including one forged by whoever has the secret. Drop a leaked secret outright, and everybody signs in again. After a leak that is the correct result, not a side effect.

## What a session can store

**A struct of your own whose size is known at compile time:** integers, floats, bools, enums, `[N]u8` arrays, optionals of those, and structs of those.

```zig
const Signed = struct {
    user: u32,
    role: enum(u8) { member, admin } = .member,
    tenant: ?u32 = null,
};
```

**Not a slice.** `name: []const u8` is a compile error, and not because it would be hard to support: a browser drops an oversized cookie *silently*, so the size has to be checkable, and a size that depends on the data cannot be checked in advance. The limit is about 4 KB, and a `Session(T)` over it stops the build with the number.

For text, give it a fixed size (`name: [32]u8`), or better, keep an id in the session and look the rest up. **The session is sent with every request**, static files included, so keeping it small matters.

## Changing a session value

```zig
try s.set(.{ .user = id });     // ✅
var copy = s.value.?;
copy.user = id;                 // ❌ compiles, and does nothing
```

**To change a session, call `set`; assigning to a field does nothing.** A session is a [resolved value](./middleware.md#resolved-values), handed to the handler by value. A changed copy goes nowhere and looks exactly like it worked, so writing is a call: `set` becomes one `Set-Cookie` on this response.

Being a resolved value also makes it cheap: the cookie is decrypted **once per request** however many things ask for it, so a middleware guarding `/admin` and the handler behind it do not both pay.

```zig
fn requireAdmin(c: *nilo.Ctx, next: nilo.Next) !void {
    const s = try c.resolve(nilo.Session(Signed));
    const signed = s.get() orelse return nilo.fail.unauthorized("sign in first", .{});
    if (signed.role != .admin) return nilo.fail.forbidden("admins only", .{});
    try next.run(c);
}
```

## Session lifetime (`max_age`)

**By default the cookie is a browser-session cookie, gone when the browser closes**, which is what a sign-in usually wants. To keep it longer, say for how long:

```zig
try s.setWith(.{ .user = id }, .{ .max_age = 30 * 24 * 60 * 60 });   // 30 days
```

**That one number sets two things**, and the second is the one that matters. `Max-Age` is an instruction to the browser, and a browser follows it. A copy of the cookie (from a proxy log, a `curl -v` pasted into a ticket, a backup) follows nothing. So the same thirty days is also sealed *inside* the cookie, where the client cannot change it, and after thirty days it stops opening for anybody ([ADR 033](../adr/033-a-session-is-sealed-into-the-cookie.md)).

A browser-session cookie has a limit too, for the same reason: leaving `max_age` unset asks the browser to forget the cookie when it closes, and seals `nilo.session.default_max_age`, **24 hours**, for any copy that does not. Null does not mean forever, and could never safely mean that.

[`setWith`](../reference/ctx.md#sessiont) also takes `path`, `domain`, `secure` and `same_site`. It does not take `http_only`: a session a script can read is a session an injected script can send somewhere.

Testing the expiry boundary needs no clock and no waiting. `nilo.session.openAt(T, cookie, key, when)` opens a cookie as of a time you choose, which is how nilo's own tests check the second before an expiry, the second of it, and the second after.

## Revoking a session early

**A session cannot be revoked early.** A sealed cookie is valid until the expiry sealed into it, and nothing can cut that short, because there is no row to mark. `s.clear()` deletes the cookie in *this* browser; a cookie somebody copied keeps opening until its expiry. That is why the expiry exists, and why it is not optional.

If you need revocation, put a number in the session and check it:

```zig
const Signed = struct { user: u32, token_version: u16 };

fn me(s: nilo.Session(Signed), db: *Db) !?Profile {
    const signed = s.get() orelse return null;
    const account = db.find(signed.user) orelse return null;
    if (account.token_version != signed.token_version) return null;   // signed out everywhere
    return account.profile;
}
```

That is a database lookup, but it is the lookup you were already doing to answer the request, not a second one just to find the session.

**Changing the secret does not have to sign everybody out**: keep the old one as a fallback ([above](#rotating-the-secret)). Dropping it outright does, and after a leak that is what you want.

### The `__Host-` cookie name

**The cookie is called `__Host-session`, so another subdomain cannot plant one.** A browser only accepts a cookie with that prefix from this host, over HTTPS, at `/`. A plain `session` cookie could be set by any page on a sibling subdomain with `Domain=example.com; Path=/account`, and the browser would send that one first under `/account`, so the person would be working inside somebody else's account without knowing. A `setWith` that names a `domain`, another `path` or `secure = false` writes the plain name, because a browser drops the prefixed one with any of those, and so gives up that protection; it needs `listen(.{ .session_plain_name = true })`, without which the plain name is never read and the `set` fails with a message saying so. A program upgrading from 0.6.0, which wrote every session under the plain name, turns the same option on for as long as its longest `max_age`: each visitor's next `set` moves them to the new name, and then the option goes off.

## Changing the session struct

**Adding a field to your session struct is safe: cookies already issued are ignored, not misread**, and the people holding them sign in again.

This is by design. The sealed bytes carry a fingerprint of the struct's layout, so a cookie written by a different build does not open. Without it, the bytes that were a `bool` would become the low byte of a `u32` and somebody would be signed in as the wrong user. The same would happen if two fields of the same type swapped places, which no size check would catch.

## Sign-in and password checking

**A session is not authentication: it only holds a user's id once something else has confirmed who they are.** Talking to an identity provider, deciding what a role means, limiting sign-in attempts per address: all of that is yours. nilo provides the mechanism and no policy, the same line it draws around [middleware and resolved values](./middleware.md).

**Checking the password is the one part nilo does provide**, because getting it wrong fails silently:

<!-- compiles -->
```zig
const pw = @import("nilo_pw"); // the hashing module, for `pw.huge_pages` and `pw.Cost`

fn signIn(
    c: *nilo.Ctx,
    db: *sql.Db,
    s: nilo.Session(Signed),
    form: nilo.Form(SignIn),
) !nilo.Redirect(303) {
    const row = try db.one(Account, c, .{ .where = .{ .email = form.value.email } });
    if (!try c.verifyPassword(
        pw.huge_pages,
        if (row) |r| r.password.view() else null,
        form.value.password.view(),
    )) return nilo.fail.unauthorized("that is not a sign-in", .{});

    try s.set(.{ .user = @intCast(row.?.id) });
    return .to("/");
}
```

Three things about [`c.verifyPassword`](../reference/ctx.md#reading) are the whole reason it exists ([ADR 044](../adr/044-a-password-hash-is-gated-because-forgetting-is-silent.md)):

- **The stored hash is optional, and `null` means there is no such account.** The call still does the full work and answers false. Returning early for an unknown address answers in a millisecond instead of thirty, which lets anyone use the form to find out which addresses are registered. If you hash at a Cost of your own, pass it here too (`c.verifyPasswordWith(cost, …)`), because that Cost sets how long the no-account path takes.
- **It is a `Ctx` method, not a direct call to `nilo_pw`.** One hash takes 13 ms and 19 MiB, which is under `block_warning_ms`, so calling the module directly would block the thread on every sign-in with nothing in the log. The method parks the fiber and holds one of `password_hashes_at_once` permits.
- **The allocator is `pw.huge_pages`, not `db.gpa`.** The 19 MiB arrives in ten pages instead of 4,864, which is 11.0 ms a hash against 13.6, with nothing held between hashes. Any allocator works; this is the fastest, and on anything other than Linux it *is* `page_allocator`.

Signing somebody up is the other direction:

<!-- compiles: body -->
```zig
const stored = try c.hashPassword(pw.huge_pages, form.password.view());
_ = try db.insert(Account, c, .{ .email = form.email, .password = stored.text() });
```

A successful sign-in is the only moment the plaintext password is available, so it is the only place a hash written at an older Cost can be upgraded:

<!-- compiles: body -->
```zig
const row = try db.one(Account, c, .{ .where = .{ .email = form.email } });
if (try pw.needsRehash(row.?.password.view(), .default)) {
    const fresh = try c.hashPassword(pw.huge_pages, form.password.view());
    _ = try db.update(Account, c, .{
        .set = .{ .password = fresh.text() },
        .where = .{ .id = row.?.id },
    });
}
```

### Checking a password outside a request

**`nilo.verifyPassword` is the same check without a `Ctx`.** A CLI that resets an account, a job that re-hashes every row at a higher Cost, a test that wants neither an App nor a `Ctx`: none of them has a request, and none needs one, because the salt is in the stored string. It uses the same Gate and the same blocking pool, and runs inline when there is no event loop at all ([ADR 044](../adr/044-a-password-hash-is-gated-because-forgetting-is-silent.md)):

<!-- compiles -->
```zig
fn checkFromTheCommandLine(gpa: std.mem.Allocator, stored: []const u8, typed: []const u8) !bool {
    return nilo.verifyPassword(gpa, stored, typed);
}
```

There is no matching `nilo.hashPassword`. Making a hash needs entropy, and `c.entropy` is where the wait for it happens. Outside a request, fill a `[pw.salt_len]u8` with `std.Io.randomSecure` and call `pw.hash`; that is all it takes.

## A client that sends a bearer token

**A native application has no cookie jar, and `Bearer(T)` is the session's seal in an `Authorization: Bearer` header** ([ADR 265](../adr/265-a-bearer-token-is-a-session-sealed-for-a-header.md)). It is not a JWT: it is encrypted as well as signed, the client cannot read it, it has no `alg` to confuse, and there is no comparison for you to write. The sign-in route issues one; the client keeps it and sends it back.

<!-- compiles -->
```zig
const Token = struct { token: []const u8, expires_in: i64 };

// Whoever checked the password has a user id; a real route calls `pw` first.
fn issueToken(c: *nilo.Ctx, user: u32) !Token {
    const t = try nilo.Bearer(Signed).issue(c, .{ .user = user }, .{ .max_age = 3600 });
    return .{ .token = t.text, .expires_in = t.expires_in };
}

// The token is opaque to the client, so a route like this is how it learns its claims.
fn whoAmI(b: nilo.Bearer(Signed)) !Signed {
    return try b.require();
}
```

`require()` answers a 401 with `WWW-Authenticate: Bearer`, and with `error="invalid_token"` when a token was sent and did not open, which tells the client to sign in again (RFC 6750). `get()` returns `?T` for a route that works signed out. The token opens under `session_secret` and its fallbacks, so [rotating the secret](#rotating-the-secret) covers tokens too, and a token expires at its `max_age` inside the seal. A session cookie's value does not open as a token, and the reverse.

Send the token as `Authorization: Bearer <token>`. The CSRF middleware reads `Sec-Fetch-Site` and `Origin`, which a mobile application does not send, so its requests pass; a browser's cross-site request is refused whatever it carries. Like a session, a token cannot be revoked before it expires: keep `max_age` short and put a version number of your own in `Signed` to sign everybody out. Give the sign-in response `Cache-Control: no-store` if anything between you and the client caches.

## Password reset tokens and API keys

**[`pw.Token`](../reference/pw.md) is a random token for a reset link, an email verification or an API key, stored as a digest.** Every application needs all three, and the recipe is small enough that everybody writes it, yet easy enough to get wrong that most get one part wrong: storing the token as it was sent (so a copy of the table is a set of working links), comparing with `std.mem.eql`, or using a UUID as the token. `pw.Token` is the recipe written once ([ADR 044](../adr/044-a-password-hash-is-gated-because-forgetting-is-silent.md)).

<!-- compiles -->
```zig
const pw = @import("nilo_pw");

const Forgot = struct { email: Str };

fn forgot(c: *nilo.Ctx, db: *sql.Db, form: nilo.Form(Forgot)) !nilo.Redirect(303) {
    // The same answer whether or not the address is known, for the reason a
    // sign-in's is.
    const user = try db.one(Account, c, .{ .where = .{ .email = form.value.email } }) orelse
        return .to("/check-your-mail");

    const token = pw.Token.new(try c.entropy(pw.token_len));
    const digest = token.digest();
    _ = try db.insert(Reset, c, .{
        .user_id = user.id,
        .digest = sql.Bytes.of(&digest),
        .expires_at = sql.Timestamp.fromSeconds(sql.Timestamp.now().seconds() + 3600),
    });

    // The text goes in the mail and nowhere else.
    const sent = token.text();
    try sendResetMail(c, user.email, &sent);
    return .to("/check-your-mail");
}

const NewPassword = struct { password: Str };

// `POST /reset/:token`
fn reset(
    c: *nilo.Ctx,
    db: *sql.Db,
    token: Str,
    form: nilo.Form(NewPassword),
) !nilo.Redirect(303) {
    const presented = pw.Token.parse(token.view()) orelse
        return nilo.fail.unauthorized("that link is not one", .{});
    const digest = presented.digest();

    // Found and taken in one statement: two requests with the same link
    // cannot both get past this line.
    const row = try db.deleteReturningOne(Reset, c, .{ .where = .{ .digest = sql.Bytes.of(&digest) } }) orelse
        return nilo.fail.unauthorized("that link is not one", .{});
    if (row.expires_at.micros < nilo.nowMicros())
        return nilo.fail.unauthorized("that link is not one", .{});

    const fresh = try c.hashPassword(pw.huge_pages, form.value.password.view());
    _ = try db.update(Account, c, .{ .set = .{ .password = fresh.text() }, .where = .{ .id = row.user_id } });
    return .to("/sign-in");
}

fn sendResetMail(c: *nilo.Ctx, to: Str, text: []const u8) !void {
    _ = c;
    _ = to;
    _ = text;
}
```

Four things to know:

- **Send the text, store the digest, keep nothing else.** `token.text()` is 43 characters of base64url, safe in a URL, a header and an email, and `token.digest()` is SHA-256 over the bytes. A row holding the digest is useless to whoever reads the table, which is the point.
- **Every wrong token gets the same answer.** `parse` returns null for the wrong length, a character outside base64url or a padded spelling, and the lookup returns null for a token nobody issued. Both end in the same 401, because how a token was wrong is not something to tell whoever presented it. Looking the row up by its digest leaks no useful timing: whoever sends a token cannot choose the bytes of its SHA-256. Where the row is found some other way, `pw.Token.matches(stored, presented)` is the constant-time compare, and a stored value that is not 32 bytes gives `false`, so a table that kept the text by mistake signs nobody in rather than everybody.
- **No argon2.** A token has 256 bits of entropy and needs no stretching; a reset endpoint that took 13 ms to say no would be one that can be brute-forced. That is why this is `pw.Token` and not a Cost.
- **Expiry and single use are yours to implement.** `expires_at` is a column in your table, and single use is `deleteReturningOne`: the row is found by its digest and removed in the same statement, so a link clicked twice at once works only once. Reading it with `db.one` and deleting it afterwards leaves a gap where both requests read it. The digest needs `.unique` in the marker, which is what lets `deleteReturningOne` promise one row. A failure after the delete, such as the password update, uses up the link, and the user asks for another; that is the safe way round. An API key is the same calls with no expiry and no delete: look the row up by `pw.Token.parse(header).?.digest()`.

## Testing

**A handler that takes a session is an ordinary function, and the session is an ordinary value:**

```zig
test "me answers with the signed-in profile, and 404s without one" {
    // No request, no cookie, no server: the handler is a function of what it
    // was given.
    try testing.expectEqualStrings("Wati", (try me(.{ .value = .{ .user = 7 } })).?.name);
    try testing.expect(try me(.{ .value = null }) == null);
}
```

`set` and `clear` are the exception: outside a request there is no response to put a cookie on, so they fail instead of silently doing nothing.

To test the round trip (that the cookie really is set and really comes back), drive the App with the [test client](./testing.md), setting the key directly instead of calling `listen`:

```zig
var app = nilo.App.init(testing.allocator);
defer app.deinit();
app.session_key = @splat(0xA5);          // what `.session_secret` becomes
app.session_fallbacks = &.{@splat(0x5A)};  // and `.session_fallback_secrets`, for a rotation
try app.post("/sign-in", signIn);
```
