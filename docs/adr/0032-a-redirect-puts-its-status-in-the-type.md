# A redirect puts its status in the type

A redirect was always possible — `Status(302, void)` with a `Location` header on it — and always three lines for a one-line idea:

```zig
fn old(arena: std.mem.Allocator) !zfast.Status(302, void) {
    return .{ .headers = .of(&.{.{ .name = "Location", .value = "/new" }}) };
}
```

Nothing about that is wrong. It is just that the thing being said — *go here instead* — is buried in a header somebody has to spell correctly, and the API description had no idea it was looking at a redirect.

## `Redirect(comptime status)` and not a runtime one

ADR 0024 already settled the shape of this trade for statuses generally: `Response(T)` picks its status while the request runs and the document can only write `default`; `Status(code, T)` puts it in the signature and the document names it.

A redirect's status is a constant in the source essentially always — a form POST answers 303, an old address answers 301 — so it belongs in the type:

```zig
fn signUp(incoming: zfast.Form(SignUp)) !zfast.Redirect(303) {
    return .to("/welcome");
}
```

The result is the most completely described thing a signature can produce: the status is known, there is no body to describe, and the one header that makes it followable is part of the promise. The document writes the status and a required `Location`.

A redirect whose status genuinely depends on what the handler found is `c.redirect(status, where)`, which is what all of this compiles down to anyway.

## Only the five statuses that carry a `Location`

`Redirect(200)` stops compilation. The message names the five and says what each is for, because the choice between them is the actual difficulty here and nobody remembers it:

> 301 (moved for good), 302 (found), 303 (see other — what a form POST answers with, so the reload does not post again), 307 (temporary, and the method is kept) and 308 (permanent, and the method is kept).

That sentence is the whole reason this feature is worth more than a header helper. **303 after a POST is the one people get wrong**, and getting it wrong means a browser's reload button submits the form a second time. Putting the explanation in the compile error puts it where somebody is already reading.

## It carries headers, because a sign-in has to

The shape this exists to serve is: read a form, start a session, set a cookie, send them back to the page. Three of those four are a redirect's business, so `Redirect` has the same `headers` field `Response` and `Status` do, copied on the way out the same way (ADR 0019).

```zig
return .with("/", .of(&.{.{ .name = "Set-Cookie", .value = session }}));
```

Without it a sign-in would have had to drop to a `*Ctx` and lose the described status again, which is exactly the trade this was meant to remove.

## No body

A redirect answers with a `Location` and `Content-Length: 0`. Browsers follow the header and never look at the body; the handful of clients that do not are better served by the status than by a paragraph of HTML nobody maintains.

## Consequences

- `zfast.Redirect(status)` with `.to(location)` and `.with(location, headers)`, plus `Ctx.redirect(status, location)`.
- 303, 307 and 308 join the statuses whose first line is assembled at compile time; 301 and 302 already had phrases and no way to reach them.
- `c.redirect` refuses an empty location and a status outside 3xx with a 500 rather than sending a `Location` nobody can follow. The typed version cannot reach the second of those — the type refused it while compiling.
- `location` is copied on the way out like any header value, so building one in the request arena or on the stack is safe.
