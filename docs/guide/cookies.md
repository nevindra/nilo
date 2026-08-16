# Cookies

```zig
fn signIn(c: *zfast.Ctx, sessions: *Sessions) !void {
    try c.setCookie(.{ .name = "session", .value = try sessions.open() });
}

fn me(c: *zfast.Ctx) !?User {
    const token = c.cookie("session") orelse return null;
    ...
}
```

Reading walks the `Cookie` header where it lies and **allocates nothing**, so a
request that carries cookies costs the same as one that does not. A request
that splits its cookies across two `Cookie` headers — which HTTP/2 clients do —
is looked through in full.

## The value comes back as it was sent

zfast does not decode a cookie value. RFC 6265 makes it opaque bytes, and every
framework layers its own encoding on top — percent, base64, signed-then-base64
— so guessing would corrupt the ones that guessed otherwise.

If you are coming from Node, this is the one habit that does not transfer:
`cookie-parser` percent-decodes and this does not. Encode on the way in and
decode on the way out, in whatever your application uses.

The one thing that is stripped is surrounding quotes, because RFC 6265 allows
`name="value"` and some writers use it.

## Setting one

```zig
try c.setCookie(.{ .name = "session", .value = token });
```

goes out as

```
Set-Cookie: session=…; Path=/; Secure; HttpOnly; SameSite=Lax
```

**The defaults are the careful ones**, so turning a protection off is a visible
line rather than a forgotten one:

| | Default | |
|---|---|---|
| `path` | `"/"` | the whole site, not the path that happened to set it |
| `domain` | `""` | this host, no subdomains |
| `max_age` | `null` | a session cookie — gone when the browser closes |
| `expires` | `""` | an HTTP-date, if you have one. `max_age` needs no clock |
| `secure` | `true` | HTTPS only |
| `http_only` | `true` | kept away from JavaScript |
| `same_site` | `.lax` | `.strict`, `.lax`, `.none`, `.unset` |

`Secure` on a development server is fine: browsers have treated
`http://localhost` as a secure context since 2020.

`.none` without `.secure` is refused, because every current browser drops that
combination and the symptom is a cookie that silently never arrives.

## Two cookies are two cookies

Setting a header twice replaces it. `Set-Cookie` is the one exception — calling
`setCookie` twice sends two of them, because the spec says a server must, and
because the alternative is a login that silently delivers only its second
cookie.

## Clearing one

```zig
try c.clearCookie(.{ .name = "session" });
```

A browser matches a deletion on the name, the **path** and the **domain**. A
cookie set under `/admin` is not cleared by a deletion at the default `/`, and
nothing anywhere tells you it was not — so pass the same ones you set it with:

```zig
try c.clearCookie(.{ .name = "session", .path = "/admin" });
```

## A value with a `;` in it is refused

```zig
try c.setCookie(.{ .name = "session", .value = "abc; Path=/admin" });
```

That is not a broken cookie — it is a cookie with a path nobody wrote, because
`;` separates attributes and the grammar has no escaping to defend with. So it
is refused, with a 500 saying which character and to encode the value first.
The same goes for a space, a comma, a quote, a backslash and any control byte.

Base64 and hex — which is what a session token normally is — pass untouched.

## The signed-in user

Reading the cookie in every handler is not the shape to reach for. A
[resolved value](./middleware.md#resolved-values) reads it once and appears
in an argument list by name:

```zig
const SignedIn = struct {
    pub const zfast_resolve = authenticate;
    email: []const u8,
};

fn authenticate(c: *zfast.Ctx, sessions: *Sessions, arena: std.mem.Allocator) !SignedIn {
    const token = c.cookie("session") orelse
        return fail.unauthorized("you are not signed in", .{});
    ...
}

fn me(user: SignedIn) !Profile { … }   // and that is the whole wiring
```

## Sessions are yours

zfast gives you the cookie. What goes in it, where it is stored and how it is
signed is your application's — the same line it draws around authentication.
[`examples/forms`](../../examples/forms/main.zig) shows the whole shape in
about forty lines, with the session store as an ordinary
[Service](./services.md).

## Testing

The [test client](./testing.md) can ask what a response set:

```zig
const answer = try client.post(&app, "/sign-in", "");
try testing.expect(answer.setCookie("session") != null);
try testing.expectEqual(@as(usize, 2), answer.headerCount("Set-Cookie"));
```

and a request carries one the way any header does, through `client.send`:

```
POST /me HTTP/1.1\r\nCookie: session=abc123\r\n\r\n
```

## See also

- [ADR 0030](../adr/0030-a-cookie-is-a-header-and-set-cookie-is-the-one-that-repeats.md)
  — why nothing is decoded, why `Set-Cookie` breaks the replace rule, and why a
  bad value is refused rather than escaped.
