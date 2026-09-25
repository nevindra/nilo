# Sessions

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

**Nothing is kept on the server.** The whole session is serialised, encrypted
and signed, and handed to the browser as one cookie. There is no table, no
expiry sweep, no lock, and nothing added to what an idle connection costs —
which is the reason to prefer it, not a detail of how it is written
([ADR 033](../adr/033-a-session-is-sealed-into-the-cookie.md)).

A request that does not ask for a session runs the code it ran before.

## The secret

```zig
try app.listen(.{ .session_secret = secret });   // exactly 32 bytes
```

Where it comes from is yours — an environment variable, a mounted file, a
secrets manager. nilo has **no default**, because a default key is a key
everybody who has read this repository already has.

Three things have to be true of it, and getting any of them wrong is quiet:

| | why |
|---|---|
| Exactly 32 bytes | checked at `listen()`, which stops with a message |
| The same on every instance | otherwise a request lands on the machine that cannot read its own cookies |
| The same after a restart | otherwise a deploy signs everybody out |

Generating one, once, and keeping it wherever your other secrets live:

```
head -c 32 /dev/urandom | base64
```

A handler that asks for a `Session(T)` when no secret was set answers **500**
with a sentence naming the option. It does not fall back to anything.

## Changing the secret

Put the new secret in `session_secret` and the one it replaces in
`session_fallback_secrets`:

```zig
try app.listen(.{
    .session_secret = new_secret,
    .session_fallback_secrets = &.{old_secret},
});
```

Every session sealed from then on is sealed under the new secret. A cookie
sealed under the old one still opens, so nobody is signed out by the deploy
([ADR 225](../adr/225-a-fallback-session-secret-opens-and-never-seals.md)).

**Drop the old secret once one `max_age` has passed.** The expiry is sealed
inside every cookie, so by then nothing sealed under the old secret can open
anyway. With no `max_age` that is 24 hours; with `.max_age = 30 * 24 * 60 * 60`
it is thirty days.

| | why |
|---|---|
| At most three fallback secrets | each is one more decryption, about 270 ns, for every cookie the current secret does not open |
| Each exactly 32 bytes | checked at `listen()`, like the current one |
| None the same as `session_secret`, and none twice | that is a rotation that did not happen, and `listen()` says so |
| Fallback secrets need a `session_secret` | otherwise nothing could seal a new session |

A cookie under the current secret costs exactly what it did before. Only a
cookie the current secret does not open is tried under the fallbacks, in
the order you listed them.

**On several instances, it is two deploys.** While a deploy rolls out, the
instances already updated seal under the new secret, and one not yet updated
cannot open what they wrote. So stage the new secret first:

```zig
// Deploy 1: every instance learns to open the new secret. Nothing seals under it yet.
.{ .session_secret = old_secret, .session_fallback_secrets = &.{new_secret} }

// Deploy 2, once the first has reached every instance: swap them.
.{ .session_secret = new_secret, .session_fallback_secrets = &.{old_secret} }
```

A single instance can go straight to the second.

**Not after a leak.** A fallback secret still opens every cookie sealed under
it, including one forged by whoever has the secret. A leaked secret is
dropped outright, and everybody signs in again. That is the right answer
after a leak, not the cost of one.

## What a session may hold

A struct of your own, of a size known while compiling: integers, floats,
bools, enums, `[N]u8` arrays, optionals of those, and structs of those.

```zig
const Signed = struct {
    user: u32,
    role: enum(u8) { member, admin } = .member,
    tenant: ?u32 = null,
};
```

**Not a slice.** `name: []const u8` is a compile error, and the reason is not
that it would be hard: a browser drops an oversized cookie *silently*, so the
size has to be checkable, and a size that depends on the data is a size nobody
checked. The ceiling is about 4 KB and a `Session(T)` past it stops the build
with the number.

For text, give it a bound — `name: [32]u8` — or, better, keep an id in the
session and look the rest up. **The session goes up the wire on every request**,
static files included, so a small one is not a style preference.

## Reading is not writing

```zig
try s.set(.{ .user = id });     // ✅
s.value.user = id;              // ❌ compiles, and does nothing
```

A session is a [resolved value](./middleware.md#resolved-values), handed to
the handler by value. A mutated copy goes nowhere and looks exactly like it
worked, so writing is a call: `set` turns into one `Set-Cookie` on this
response.

Being a resolved value is also what makes it cheap: the cookie is decrypted
**once per request** however many things ask for it, so a middleware guarding
`/admin` and the handler behind it do not both pay.

```zig
fn requireAdmin(c: *nilo.Ctx, next: nilo.Next) !void {
    const s = try c.resolve(nilo.Session(Signed));
    const signed = s.get() orelse return nilo.fail.unauthorized("sign in first", .{});
    if (signed.role != .admin) return nilo.fail.forbidden("admins only", .{});
    try next.run(c);
}
```

## Staying signed in

The cookie is a session cookie by default — gone when the browser closes,
which is what a sign-in usually wants. To outlive that, say for how long:

```zig
try s.setWith(.{ .user = id }, .{ .max_age = 30 * 24 * 60 * 60 });   // 30 days
```

**That one number sets two things**, and the second is the one that counts.
`Max-Age` is an instruction to the browser, and a browser obeys it; a copy of
the cookie — out of a proxy log, a `curl -v` pasted into a ticket, a backup —
obeys nothing. So the same thirty days is sealed *inside* the cookie, where the
client cannot reach it, and after thirty days it stops opening for anybody
([ADR 033](../adr/033-a-session-is-sealed-into-the-cookie.md)).

A session cookie has a ceiling too, for exactly that reason: leaving `max_age`
unset asks the browser to forget the cookie at the end of the window, and seals
`nilo.session.default_max_age` — **24 hours** — for the copy that does not. Null
does not mean forever and never safely could.

`setWith` also takes `path`, `domain`, `secure` and `same_site`. It does not
take `http_only`: a session a script can read is a session an injected script
can send somewhere.

Testing what happens at the boundary needs no clock and no waiting.
`nilo.session.openAt(T, cookie, key, when)` opens a cookie against a time you
name, which is how nilo's own tests reach the second before an expiry, the
second of it, and the second after.

## What it cannot do

**A session cannot be revoked early.** A sealed cookie is valid until the
expiry sealed into it, and nothing can cut that short, because there is no row
to go and mark. `s.clear()` deletes the cookie in *this* browser; a cookie
somebody copied goes on opening until its expiry — which is the reason the
expiry exists, and the reason it is not optional.

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

That is a lookup — but it is the lookup you were doing anyway to answer the
request, rather than a second one to find the session.

**Changing the secret does not have to sign everybody out**: keep the old
one as a fallback ([above](#changing-the-secret)). Dropping it outright does, and after a
leak that is what you want.

**The cookie is `__Host-session`, so another subdomain cannot plant one.** A browser keeps a cookie with that prefix only from this host, over HTTPS, at `/`. A plain `session` could be set by any page on a sibling subdomain with `Domain=example.com; Path=/account`, and the browser would send that one first under `/account`, so the person would be working inside somebody else's account without knowing. A `setWith` that names a `domain`, another `path` or `secure = false` writes the plain name, because a browser drops the prefixed one with any of those, and gives up that protection. A session written by 0.6.0 or earlier, under the plain name, still opens, and the next `set` moves it.

## Changing the shape is safe

Add a field to your session struct, deploy, and the cookies already out there
are **ignored** rather than misread — the people holding them sign in again.

That is not luck. The sealed bytes carry a fingerprint of the struct's shape,
so a cookie written by another build does not open. Without it, the bytes that
were a `bool` would become the low byte of a `u32` and somebody would be
signed in as the wrong user — the same for two fields of the same type
swapping places, which no size check would catch.

## A session is not authentication

It is where a user's id lives once something else has established it. What
talks to the identity provider, what a role means, how many sign-in attempts an
address gets — all yours. nilo provides the mechanism and no policy, the same
line it draws around [middleware and resolved values](./middleware.md).

**Checking the password is the one half nilo does provide**, because getting it
wrong is quiet:

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

Three things about that call are the whole reason it exists
([ADR 044](../adr/044-a-password-hash-is-gated-because-forgetting-is-silent.md)):

- **The stored hash is optional, and `null` means there is no such account.**
  It does the work anyway and answers false. Returning early when the address
  is unknown answers in a millisecond instead of thirty, which turns the form
  into a query for which addresses are registered. If you hash at a Cost of
  your own, say so here too — `c.verifyPasswordWith(cost, …)` — because that
  Cost is what the no-account path is measured out at.
- **It is a `Ctx` method rather than a call to `nilo_pw`.** One hash is 13 ms
  and 19 MiB — under `block_warning_ms`, so calling the module directly holds
  the thread on every sign-in and nothing in the log says so. The method parks
  the fiber and holds one of `password_hashes_at_once` permits.
- **The allocator is `pw.huge_pages` rather than `db.gpa`.** The 19 MiB arrives
  in ten pages instead of 4,864, which is 11.0 ms a hash against 13.6 and
  nothing held between them. Any allocator works; this is the one that is
  fastest, and on anything that is not Linux it *is* `page_allocator`.

Signing somebody up is the other direction:

<!-- compiles: body -->
```zig
const stored = try c.hashPassword(pw.huge_pages, form.password.view());
_ = try db.insert(Account, c, .{ .email = form.email, .password = stored.text() });
```

And when a sign-in succeeds is the one moment the plaintext is in hand, so it
is the only place a row written at an older Cost can be written forward:

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

### Checking one with no request in hand

A CLI that resets an account, a job that re-hashes every row at a raised
Cost, a test that wants neither an App nor a `Ctx`: none of them has a
request, and none of them needs one, because the salt is in the stored
string. `nilo.verifyPassword` is the method without the `Ctx` — the same
Gate and the same blocking pool, run inline when there is no loop at all
([ADR 044](../adr/044-a-password-hash-is-gated-because-forgetting-is-silent.md)):

<!-- compiles -->
```zig
fn checkFromTheCommandLine(gpa: std.mem.Allocator, stored: []const u8, typed: []const u8) !bool {
    return nilo.verifyPassword(gpa, stored, typed);
}
```

There is no `nilo.hashPassword` beside it. Making a hash needs entropy, and
`c.entropy` is where the wait for it is paid; outside a request,
`std.Io.randomSecure` into a `[pw.salt_len]u8` and `pw.hash` is the whole of
it.

## A token that is not a password

A password-reset link, an email verification, an API key. Every application
has all three, and the recipe is small enough that everybody writes it and
wrong in enough places that most get one of them: the token stored as it was
sent, so that a copy of the table is a set of working links; `std.mem.eql` on
the compare; a UUID used as the token. `pw.Token` is the recipe written once
([ADR 044](../adr/044-a-password-hash-is-gated-because-forgetting-is-silent.md)).

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

Four things about it:

- **Send the text, store the digest, keep nothing else.** `token.text()` is
  43 characters of base64url — safe in a URL, a header and a mail — and
  `token.digest()` is SHA-256 over the bytes. A row holding the digest is
  useless to whoever reads the table, which is the point of it.
- **Every wrong token gets one answer.** `parse` gives null for the wrong
  length, a character outside base64url or a padded spelling, and the lookup
  gives null for a token nobody issued. Both end in the same 401, because
  which way a token was wrong is not something to tell whoever presented it.
  Finding the row by its digest leaks no timing worth having: whoever sends a
  token cannot choose the bytes of its SHA-256. Where the row is found some
  other way, `pw.Token.matches(stored, presented)` is the constant-time
  compare, and a stored value that is not 32 bytes is `false`, so a table
  that kept the text by mistake signs nobody in rather than everybody.
- **No argon2.** A token has 256 bits of entropy and needs no stretching;
  a reset endpoint that took 13 ms to say no would be one that can be
  walked. This is why it is `pw.Token` and not a Cost.
- **Expiry and single use are yours.** `expires_at` is a column in your
  table, and single use is `deleteReturningOne`: the row is found by its
  digest and removed by the same statement, so a link clicked twice at once
  works once. Reading it with `db.one` and deleting it after leaves a gap
  where both requests read it. The digest needs `.unique` in the marker,
  which is what lets `deleteReturningOne` promise one row. A failure after
  the delete, such as the password update, spends the link, and the user asks
  for another. That is the safe way round. An API key is the same calls with
  no expiry and no delete: `pw.Token.parse(header).?.digest()` is what to
  look the row up by.

## Testing

A handler taking a session is an ordinary function, and the session is an
ordinary value:

```zig
test "me answers with the signed-in profile, and 404s without one" {
    // No request, no cookie, no server: the handler is a function of what it
    // was given.
    try testing.expectEqualStrings("Wati", (try me(.{ .value = .{ .user = 7 } })).?.name);
    try testing.expect(try me(.{ .value = null }) == null);
}
```

`set` and `clear` are the exception: outside a request there is no response to
put a cookie on, so they fail rather than quietly doing nothing.

For the round trip — that the cookie really is set and really comes back —
drive the App with the [test client](./testing.md), setting the key directly
rather than listening:

```zig
var app = nilo.App.init(testing.allocator);
defer app.deinit();
app.session_key = @splat(0xA5);          // what `.session_secret` becomes
app.session_fallbacks = &.{@splat(0x5A)};  // and `.session_fallback_secrets`, for a rotation
try app.post("/sign-in", signIn);
```
