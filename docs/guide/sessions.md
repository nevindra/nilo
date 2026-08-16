# Sessions

```zig
const Signed = struct { user: u32, admin: bool = false };

fn signIn(s: nilo.Session(Signed), form: nilo.Form(Login)) !nilo.Redirect(303) {
    const id = try accounts.check(form.email, form.password) orelse
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
([ADR 0035](../adr/0035-a-session-is-sealed-into-the-cookie.md)).

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

`setWith` also takes `path`, `domain`, `secure` and `same_site`. It does not
take `http_only`: a session a script can read is a session an injected script
can send somewhere.

## What it cannot do

**A session cannot be revoked.** A sealed cookie is valid until it expires, so
there is no "sign out everywhere" in the mechanism. `s.clear()` deletes the
cookie in *this* browser; a cookie somebody copied still opens.

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

**Changing the secret signs everybody out.** Rotating without doing that needs
a second key to decrypt with, and that is not built yet
([roadmap](../roadmap.md)).

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

```zig
fn signIn(c: *nilo.Ctx, s: nilo.Session(User), form: nilo.Form(SignIn)) !Redirect(303) {
    const db = c.service(*Db).?;
    const conn = try db.acquire();
    defer conn.release();

    const row = try db.find(Account, conn, .{ .email = form.email });
    if (!try c.verifyPassword(db.gpa, if (row) |r| r.password else null, form.password))
        return nilo.fail.unauthorized("that is not a sign-in", .{});

    try s.set(.{ .id = row.?.id });
    return .{ .location = "/" };
}
```

Two things about that call are the whole reason it exists
([ADR 0048](../adr/0048-a-password-hash-is-gated-because-forgetting-is-silent.md)):

- **The stored hash is optional, and `null` means there is no such account.**
  It does the work anyway and answers false. Returning early when the address
  is unknown answers in a millisecond instead of thirty, which turns the form
  into a query for which addresses are registered.
- **It is a `Ctx` method rather than a call to `nilo_pw`.** One hash is 13 ms
  and 19 MiB — under `block_warning_ms`, so calling the module directly holds
  the thread on every sign-in and nothing in the log says so. The method parks
  the fiber and holds one of `password_hashes_at_once` permits.

Signing somebody up is the other direction:

```zig
const stored = try c.hashPassword(db.gpa, form.password);
_ = try db.insert(Account, conn, .{ .email = form.email, .password = stored.text() });
```

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
try app.post("/sign-in", signIn);
```
