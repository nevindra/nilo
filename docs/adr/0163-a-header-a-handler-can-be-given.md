# A header a handler can be given

`c.header("X-Staff-Id")` works, and is not the point.

A path param, a query struct and a JSON body are all typed arguments, and all
three appear in the generated document. A header was a lookup inside a function
body, so it appeared nowhere — and a client generated from that document cannot
know the endpoint needs one. The port that reported this has six lines of it per
context today; it becomes every command endpoint in fourteen contexts the moment
authentication lands, because the header is how the actor arrives.

## What it does now

```zig
fn addComment(
    actor: nilo.FromHeader("X-Staff-Id", Uuid),
    body: NewComment,
) !nilo.Status(201, Comment) {
    ... actor.value ...
}
```

The same family as `Query(T)` and `Form(T)`, and read by the same `convert`, so
a header that will not become the type asked for is the same 400, in the same
words, as a query param that will not.

**Absent is decided by the type**, the way a query field decides it: a `?T` is
null when the header is not there, and anything else is a 400 naming the header.
The document says `required` accordingly.

The parameter is written last in `parameters`, after the path and query ones, so
adding a header to a route does not move the entries a generated client has
already been built against.

## The name

**`FromHeader`, not `Header`, and that is a fact rather than a preference.**
`nilo.Header` is the response side — `Response.headers` is a list a handler
writes — and has been public since 0.2.0.
[ADR 0107](./0107-every-header-without-handing-out-the-head.md) hit the same
collision from the other direction and settled it the same way, with
`Ctx.RequestHeader`. Renaming the response type to free the word would break
every program that names it, to save eight characters at a call site.

## What is deliberately not built

**A `Headers(T)` struct wrapper**, reading several headers into one type the way
`Query(T)` does. Two reasons: a header name is not a Zig identifier — `X-Staff-Id`
has hyphens — so the struct would need a rename map, which is an annotation; and
a handler wanting three headers can take three arguments, which reads as well
and needs nothing new.

**Any change to `c.header`.** It is still the right call for a middleware, for a
name worked out at run time, and for anything that is not part of the endpoint's
contract. This is for the ones that are.

## The alternative that was rejected

**A resolver** — `nilo_resolve` — which is what the Go original this port came
from uses, and which already exists here (ADR 0016). It is the right answer for
*the signed-in user*: read the header, look the session up, hand the handler a
`User`. It is the wrong answer for *the header itself*, because a resolver is a
type of the caller's own with a function on it, and the document still would not
know a header was involved. The two compose: a resolver that wants a header can
take one.

## Consequences

- One wrapper, one `Role`, one reader and one compile-time check in `typed.zig`;
  one field on `openapi.Operation` and one loop in the writer.
- Nothing per request that does not ask for one, and one `c.header` walk for one
  that does — the same walk the handler was doing itself.
- `can_reject` is true for a route with one, which is honest: nilo now refuses
  a request with a missing or unconvertible header before the handler runs.
