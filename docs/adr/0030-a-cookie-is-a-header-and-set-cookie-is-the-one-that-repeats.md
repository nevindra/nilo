# A cookie is a header, and `Set-Cookie` is the one header that repeats

zfast had no cookies at all until 0.1.0 was nearly done. Nothing was decided about them; they were simply missing, and `docs/guide/middleware.md` had been quietly writing "behind a cookie" in an example for weeks. Somebody coming from Express or Gin reaches for `c.cookie("session")` inside the first ten minutes, finds `c.header("Cookie")`, and has to split `a=1; b=2` themselves.

So the question was never whether, only what shape. Three things had to be settled.

## Reading allocates nothing, and decodes nothing

`c.cookie(name)` walks the `Cookie` header where it lies and hands back a `Str` pointing into the request head — the same thing `c.header` does, and for the same reason (ADR 0018's per-request allocation invariant). A map built on the way in would have been an allocation on every request that carries cookies, to save a scan on the few that read two.

A test holds it: a request with four cookies through a route that reads one allocates **zero** times.

The harder half is **decoding, which does not happen.** RFC 6265 §4.1.1 makes a cookie value opaque octets, and every framework then layers its own encoding on top — percent, base64, signed-then-base64. There is no way to tell which one a value used, so guessing corrupts the ones that guessed otherwise. What went out is what comes back, minus the quotes if the writer used them. That is stated in the guide rather than left to be discovered, because it is the one place a Node person's habits do not transfer: `cookie-parser` decodes, and this does not.

## `Set-Cookie` breaks the rule every other response header follows

`Ctx.setHeader` has always replaced: setting `Vary` twice is somebody changing their mind, and sending both would be untidy at best. Applied to cookies that rule is a bug with no symptom — a handler that sets a session and a preference delivers only the preference, and nothing anywhere says so.

RFC 6265 §3 is explicit that a server sending two cookies sends two `Set-Cookie` lines, and that unlike every other repeatable field they may **not** be folded into one comma-separated value (a cookie's `Expires` attribute contains a comma, which is how that ended up being true).

So `http1.repeats(name)` is a list of one, and `putHeader` skips its replace loop for it. Small, and it earns its own function because a list of one that is really a rule wants somewhere to say why.

## The defaults are the careful ones

`.{ .name = "session", .value = token }` is `Secure`, `HttpOnly`, `SameSite=Lax`, `Path=/`.

The argument for permissive defaults is that they always work. That is the argument against them: forgetting `HttpOnly` reads exactly like not needing it, and the failure shows up in somebody else's XSS report rather than in a diff. Turning a protection off is now a visible line.

`Secure` by default was the one worth checking rather than assuming. Browsers have treated `http://localhost` as a secure context since 2020, so a development server sets and receives these normally — the default costs nothing where people actually meet it first.

## A value with a `;` in it is refused, not escaped

This is the part that is about security rather than taste. `.value = "abc; Path=/admin"` does not produce a broken cookie. It produces a cookie **with a path nobody wrote**, because `;` is the attribute separator and the grammar has no escaping to defend with. The same goes for a `\r\n`, which is response splitting outright.

There is nothing to encode it as, so it is refused: `check` runs before anything is allocated, and a value carrying a character RFC 6265's `cookie-octet` does not allow is a 500 naming the character and saying to encode the value first. A 500 and not a 400 — the request did nothing wrong; the server tried to write something it cannot.

`SameSite=None` without `Secure` is refused on the same footing, because every current browser drops that combination and the symptom is a cookie that silently never arrives.

## Consequences

- `Ctx.cookie`, `Ctx.setCookie`, `Ctx.clearCookie`; `zfast.Cookie` and `zfast.SameSite` are the surface. Nothing new on `App`.
- **One arena allocation per cookie set**, sized from `cookie.lengthOf` before it is written, and a test holds the length and the writer together — a length that disagreed with what is written is either a buffer overrun or a truncated cookie.
- `clearCookie` takes a `Clearing` and not a name, because a browser matches a deletion on name, path *and* domain. A cookie set under `/admin` is not cleared by a deletion at `/`, and nothing anywhere reports that it was not — so the two other fields are in the signature where they can be seen.
- **Sessions are still not here.** A cookie is the mechanism; what goes in it, where it is stored and how it is signed is policy, and that is the same line ADR 0016 draws around authentication. `examples/forms` shows the whole shape in about forty lines, with the session store as an ordinary Service.
- Reading a cookie is not a handler argument. A type carrying `zfast_resolve` already reads what it likes from the request and appears in an argument list by name (ADR 0016), and that is the mechanism a signed-in user should go through. A second way in would have been a second thing to keep in step.
