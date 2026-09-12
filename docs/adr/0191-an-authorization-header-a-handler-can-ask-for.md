# An Authorization header a handler can ask for

`c.header("Authorization")` works, and the six lines after it were wrong in
both places this repository had them.

## What was found

The question that started this was whether Fiber's `extractors` package —
`FromHeader`, `FromQuery`, `FromCookie`, `FromAuthHeader`, and a `Chain` that
tries each in turn — was worth copying. Read against nilo's argument list it
mostly already exists, as types rather than functions: a path param is
positional, `Query(T)` and `Form(T)` are the query string and the body,
`FromHeader(name, T)` is a header ([ADR 0163](./0163-a-header-a-handler-can-be-given.md)),
`Session(T)` is the cookie, and `allowance.keyed(fn)` is `FromCustom`. The
`Chain` is the part nilo refuses on purpose. What was left over was one
function, `FromAuthHeader("Bearer")`, and looking for its equivalent here
found two hand-written copies — `examples/orders/main.zig` and the resolver
`docs/guide/jwt.md` shows — with the same two mistakes:

- **The scheme was matched case-sensitively.** `startsWith(value, "Bearer ")`
  refuses `bearer abc`, and RFC 9110 §11.1 says the scheme is
  case-insensitive. A client that lowercases its headers gets a 401 from a
  server that has the right token in its hand.
- **The 401 carried no `WWW-Authenticate`.** RFC 9110 §15.5.2 says a 401 has
  to, and nothing under `http/` had ever written one. A browser given a 401
  without it does not prompt; a generated client cannot tell an expired token
  from a route that wants a different scheme.

Both copies compiled, passed their tests and read as ordinary code, which is
the failure mode [ADR 0140](./0140-nilo-verifies-a-token-and-does-not-fetch-one.md)
built `nilo_jwt` to keep out — a check that runs perfectly and is subtly wrong
— one header up from where that module starts.

## What it does now

```zig
fn me(auth: nilo.Authorization(.bearer), issuer: *const Issuer, c: *nilo.Ctx) !Profile {
    const claims = jwt.verify(Claims, c.arena(), auth.value.view(), …) catch
        return nilo.Authorization(.bearer).refuse("that token is not valid here", .{});
    …
}

fn admin(auth: nilo.Authorization(.{ .basic = "admin" })) !void {
    … auth.user, auth.password …
}
```

The same family as `FromHeader`: a typed argument, a `Role` in `typed.zig`,
and an entry in the document. Three things are its own:

**Absent is a 401, not a 400, and the 401 says what would have done.** A
missing `Authorization`, another scheme, an empty token, Basic that is not
base64 or has no colon — each is refused before the handler runs, with
`WWW-Authenticate: Bearer` or `Basic realm="…"` on the answer. The scheme is
matched case-insensitively and the blanks around the token are not part of it.

**A refusal after reading carries the same header, without the handler holding
a Ctx.** The token did not verify; the password did not match. That 401 is the
handler's, and `T.refuse(fmt, args)` is `fail.unauthorized` with `T.challenge`
attached — through the `Failure` the fiber already owns, the way every fail
function works ([ADR 0007](./0007-failure-box-bound-to-the-fiber.md)),
so a handler stays a plain function that a test calls with no request behind
it. `serve.sendFailure` writes the header when the Failure carries one.

**In the document it is a security scheme, not a parameter.** An
`Authorization` argument becomes `security: [{bearerAuth: []}]` on the
operation, a `401` in its responses, and one entry under
`components.securitySchemes` — only for the schemes some route takes. A
generated client reads that as "sign in", where a header parameter would read
as "fill in a field".

`c.authorization(.bearer)` is the same read for a resolver or a middleware,
which have a Ctx and no argument list of their own; the resolver in the jwt
guide now uses it. The parsing lives in `http/authorization.zig`, handed the
header, the arena and the lifetime rather than the Ctx, so the file stays
outside the App's core (`http_core` in `build.zig`) and reads on its own.

## What it costs

Put against [ADR 0018](./0018-the-trade-budget-has-three-axes.md)'s four
axes before it was written:

- **Allocations per request.** Bearer: none — `.value` is a slice of the head,
  the way `c.header` answers. Basic: one, of the decoded length, from the
  request arena, on the route that asked for it. A route with neither runs
  the code it ran before.
- **Memory per idle connection.** None, and the test that holds it is
  `@sizeOf(Failure) == 256`. The challenge is one pointer to a comptime
  string on the `Failure` every connection holds; it fits because `n` became
  a `u8` — the buffer is 240 bytes — and the pointer took the six bytes of
  padding `status: u16` had been leaving before `n: usize`. The struct was 256
  bytes before and is 256 bytes after.
- **Throughput.** One `c.header` walk for a route that asks, the same walk the
  handler was doing by hand; an `eqlIgnoreCase` over six bytes.
- **Binary size.** A comptime generic and a branch in `sendFailure` on a
  pointer being null. Nothing the linker keeps for a program that names none
  of it.

## What is deliberately not built

**A chain.** Fiber's `Chain(FromHeader, FromQuery("token"), FromCookie(…))`
is the feature the package exists for and the one refused here. A token in a
query string is a token in every access log between the client and this
process, and a value that may have come from one of three places is a value
whose provenance the handler cannot reason about. The type says where it
comes from, and there is one place.

**A `Source` enum with a runtime warning for the insecure ones.** Where nilo
has a rule about where a value may come from, the rule is a Refusal at compile
time — the two on file are an empty Basic realm and one with a quote in it.
The warning Fiber logs for a CSRF token read from a query string becomes, if
CSRF is ever built, a type that cannot be read through `Query(T)`.

**Digest, and `Bearer` with parameters** (`error="invalid_token"`,
`scope=…`). The first is nobody's default in 2026; the second is a policy the
handler is better placed to state in the message than the type is to guess.

**`?Authorization(.bearer)`** — a route that works signed-out and personalises
signed-in. That shape is a resolver returning an optional, which exists, and
it reads `c.authorization` inside a `catch`. Making the argument itself
optional would mean deciding what a *present but wrong* header does on a
route that did not require one, and the honest answers differ by endpoint.

## The alternative that was rejected

**Leaving it to the resolver**, as ADR 0163 left the header. The argument
there was that the signed-in user *is* the resolver's job, and it still is —
but the header is not the user, and the two mistakes above are in the reading
of the header, which every resolver was rewriting. A resolver that wants the
user takes `c.authorization(.bearer)` and keeps its job; what it no longer
owns is the six lines it kept getting wrong.

**`fail.unauthorizedWith(challenge, …)` as the whole feature**, with no type.
It fixes the second mistake and not the first, and it puts nothing in the
document. The type is what makes the scheme's spelling nilo's business and
the sign-in a generated client's.

## Consequences

- One file, `http/authorization.zig`, outside the core; one `Role`, one line
  in the argument loop and one arm in the operation builder in `typed.zig`;
  one method on `Ctx`; one enum and two loops in `openapi.zig`; one pointer
  on `Failure`, one fail function, one branch in `sendFailure`.
- The refusal count moves from 116 to 118 for the framework's table.
- `examples/orders` and the jwt guide are each three lines shorter and no
  longer case-sensitive.
- The roadmap's list of small middleware loses `basicauth` and `keyauth`,
  which are this type plus a lookup the application already has.
