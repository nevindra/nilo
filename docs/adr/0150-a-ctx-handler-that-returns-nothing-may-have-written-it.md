# A Ctx handler that returns nothing may have written it

The reference says a `void` return is "200, empty, no `Content-Type`", and it
is. The generated document said otherwise about the same route:

```
info: 1 of 10 routes write their own response, so the API description does not
describe what they answer
```

```json
"responses": { "default": { "description": "this endpoint writes its own response, so its signature does not describe it" } }
```

A caller read the two, believed the first, and filed the second as a bug. Both
sentences were about the same handler and only one of them was true.

## What is actually the case

```zig
answer.written = wants_ctx and returnsNothing(Fn);
```

A handler that takes a `*Ctx` and returns nothing is in one of two states, and
they are both ordinary:

- it wrote the response itself, with `c.json`, `c.send`, a `Stream`, a
  `sendfile`;
- it took the Ctx to read a header, set a cookie or check something, wrote
  nothing, and left nilo to send 200 with an empty body.

Zig cannot look inside a function body at comptime, so `wants_ctx` is the only
signal there is and it does not separate them.

## What changed, and what did not

**The classification did not change**, and deliberately. It fails in the safe
direction: a document claiming an empty 200 on a route that streams a file
would be a document that lies, and a document saying "I do not know" about a
route that answers 200-empty is only unhelpful. Between an over-claim and an
under-claim, the under-claim is the one a client generator survives.

**The wording did.** Both sentences said the handler *does* write its own
response. Neither knew that. They now say what is true — the handler holds the
Ctx and returns nothing, so the signature does not settle what it answers —
and both name the way out.

**The reference gained the case it was missing.** Its table row for `void` was
right about a handler that takes no Ctx and silent about one that does, which
is the row the caller read.

## The way out was already there

```zig
fn cancel(c: *nilo.Ctx, db: *Db, id: u32) !nilo.Status(200, void) {
    try db.cancel(id, c.header("x-actor") orelse "");
    return .{};
}
```

`Status(code, void)` has been the answer to "an empty response with a status I
choose" since [ADR 0024](0024-a-failure-mode-belongs-in-the-return-type.md).
It settles the status in the signature, so the document names it, and the
handler still holds its Ctx. Nothing new had to be built, which is why nothing
was.

## The alternatives that were rejected

**A marker return type meaning "I wrote it myself"**, so that `!void` could
mean 200-empty. It reads well and it silently re-describes every existing
`fn (c: *Ctx) !void` handler that *does* write its own response — their
documents would start claiming an empty 200. A silent documentation regression
is worse than the over-claim it replaces.

**Letting the route say, the way `app.named` lets it say its name.** A second
place to write down what an endpoint answers is an annotation wearing another
name, and ADR 0017 is the whole of why this framework does not have one. The
return type is where a handler says what it answers, and it already can.

## Consequences

- Two message strings and one reference row. No behaviour.
- The `listen()` line now says how many routes are in the undescribable state
  and what to return instead of it, so the count is actionable rather than a
  number to feel bad about.
