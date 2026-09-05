# A request can be read past the parts a handler names

`c.query("page")` answers about a name you already knew, and `c.header("Host")`
answers about the connection nilo has rather than the one the client made.
Three things were therefore unreachable without touching an underscore field —
which in this repository means nilo's to change without telling anybody
([ADR 0107](./0107-every-header-without-handing-out-the-head.md) closed the
fourth, one header over).

**`c.queries()`, `c.queryString()`, `c.host()` and `c.scheme()`.**

## The query string

`query(name)` walks the parsed pairs looking for one name and answers with the
**first** match. So a filter whose names are data — `?filter[status]=open&
filter[owner]=7` — has nothing to ask for, a repeated name cannot be seen at
all, and a request being signed, proxied or logged whole cannot be reproduced.

`queries()` is an iterator over the pairs in arrival order, yielding `Str` for
both halves for the reason `RequestHeader` does: the head is usually borrowed
from the connection's read buffer, so a `[]const u8` kept past the request
points at somebody else's ([ADR 0004](./0004-request-arena-and-the-str-type.md)).
Nothing is allocated — the split already happened, once, into the request
arena.

`queryString()` is the bytes as they arrived, still encoded, with no `?` on the
front. Not the same question: a signature computed over the request line needs
what was **sent**, not what it meant.

This is not the repeated-name *binding* gap, which is still open: `?tag=a&tag=b`
into a `tags: []const Str` field of a `Query(T)` remains a compile error naming
the field. What is fixed is that the data was already there and could not be
reached.

## The scheme and the host

nilo does not speak TLS ([ADR 0028](./0028-tls-is-terminated-in-front.md)), so
every request it reads arrived in plaintext, on whatever port it bound, with
whatever `Host` the proxy chose to pass on. A handler therefore could not write
a URL to its own service: a password-reset link, an OAuth `redirect_uri`, a
webhook callback, an absolute `Location`.

**`c.scheme()` and `c.host()` read `X-Forwarded-Proto` and `X-Forwarded-Host`
when `listen(.{ .trusted_hops = … })` is not zero, and ignore them otherwise.**
That is exactly the rule `clientIp()` already applies to `X-Forwarded-For`, and
it is the same argument: a header a client can write is a header a client can
write. With the default of zero, `scheme()` is always `"http"` — which is the
truth about the connection rather than a guess — and `host()` is the `Host`
header, which HTTP/1.1 requires exactly one of
([ADR 0101](./0101-a-request-nobody-else-would-answer-is-refused.md)).

Two things are deliberately narrow.

**A forwarded host is checked before it is used.** Letters, digits, `.`, `-`,
`:`, `[`, `]` and nothing else; anything else falls back to `Host`. What this
guards is not a parser but an email: a forged authority ends up inside the link
somebody clicks, and host-header poisoning is the ordinary way that is done.

**A chain's list is read as its first entry.** `X-Forwarded-Host: a, b` means a
client asked for `a` and a proxy passed it through another; the client's is the
one a URL is written from. That is the opposite end from `clientIp()`, which
counts from the right, and for the opposite reason: there the entries a trusted
proxy wrote are the trustworthy ones, here the first entry is the question
being answered.

## Why not a `baseUrl()`

Assembling `scheme ++ "://" ++ host` is a string, and a string is an
allocation on the request path — the one axis
[ADR 0018](./0018-the-trade-budget-has-three-axes.md) treats as an invariant.
Two accessors cost nothing and a handler that wants the third writes it into
its own buffer, next to whatever path it was going to append anyway.

## Why `host()` is not what the WebSocket handshake compares

`Ctx.handshake` compares the request's `Origin` against the `Host` header
directly, and now says so in a comment. Under a `trusted_hops` that is set,
`host()` would answer with a forwarded value, and the handshake's question is
whether the page that opened the socket is the authority the request itself
named ([ADR 0102](./0102-a-websocket-handshake-is-same-origin-unless-the-route-says-otherwise.md)).
Those are different questions and one of them is a security decision.

## What it costs

Nothing for a request that calls none of them, which is all of them today. An
iterator is two words on the caller's stack; `host()` and `scheme()` are a
header walk each, on the requests that ask. No allocation anywhere, and all
four dead-strip out of a program that never names them.
