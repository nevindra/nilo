# Every header, without handing out the head

`c.header("X")` was the whole of what a handler could ask about the request's
headers, and it answers with the **first** of that name. Two things were
therefore unreachable:

- **A middleware that does not know the names in advance** — a signing proxy
  that has to canonicalise whatever arrived, somebody else's tracing header, a
  `Forwarded` reader.
- **A header the client sent twice**, which `header` cannot even report the
  existence of.

Both had one answer today, and it was to read `c._head` — an underscore field,
which in this repository means nilo's to change without telling anybody.

**`c.headers()` returns an iterator over every header in arrival order.** A
wrapper over the walk `header` already does, so no list is built, nothing is
allocated, and a request that never calls it pays for none of it.

## Why not export `http1`

`http1.HeaderIterator` exists, is already `pub`, and does exactly this. Adding
`pub const http1 = @import("http1.zig")` to `http.zig` is one line and was the
first shape tried.

It hands out `[]const u8`. **The request head is usually borrowed from the
connection's read buffer** rather than copied into the arena — see `borrowed` in
`app.zig` — so a name or a value kept past the end of the request points into
the bytes of somebody else's request. That is exactly the mistake `Str` and its
Debug-only use-after-request trap exist to catch
([ADR 0004](./0004-request-arena-and-the-str-type.md)), and an export that
routes around the type is a supported way to make it.

So the iterator yields `Ctx.RequestHeader`, whose `name` and `value` are both
`Str`. **The name as well as the value**, which is the part worth saying out
loud: a header name is as much a slice of the borrowed head as its value is, and
a version that returned `name: []const u8` for convenience would have shipped
the bug in the half nobody looks at.

## Why not a list on the `Ctx`

Every framework that offers this builds a map at parse time. That is an
allocation on every request, including the overwhelming majority that never
look at a header at all, to save a scan of a few hundred bytes on the few that
look twice — and it is the trade `header`'s own doc comment already rejected
when it was written. The iterator inherits that decision rather than reopening
it.

## The name

`nilo.Header` and `nilo.Headers` are already taken by the **response** side —
`Response.headers` is a list a handler writes. This is the request side, so it
is `Ctx.RequestHeader` and the iterator is only ever reached as the return of
`c.headers()`. Nobody has to write either type name.

## What it costs

Nothing per request that does not call it, and one pointer plus one iterator
for one that does — both on the stack of the caller, which by
[ADR 0063](./0063-a-handlers-stack-is-per-connection.md) is the axis worth
naming and this is inside the noise of it. Binary size: it is generic over
nothing and dead-strips when unused.
