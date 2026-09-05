# A body under an encoding nilo cannot read is refused

Nothing read a request's `Content-Encoding`. A client sending

```
POST /orders HTTP/1.1
Content-Encoding: gzip
Content-Type: application/json
Content-Length: 84
```

had its gzip stream handed to `c.json` as though the bytes were the JSON, and
got back a 400 saying the body was malformed. That sentence is true about the
bytes and useless to the person who sent them: the mistake is one line of
client configuration and the answer sends them to look at their payload.

**A body under any `Content-Encoding` but `identity` is now a 415 naming the
header.**

## Why 415 and not 400

The request is well formed. Every parser in the world agrees about what it
says; this server cannot read what it carries, which is exactly what
`415 Unsupported Media Type` is for. A 400 would be nilo claiming the client
sent nonsense.

## Why not decode it

Decoding is the inbound twin of the gap that keeps response compression out
(roadmap, *Known gaps*), and it inherits the same arithmetic: a deflate window
is 64 KB, and one per connection multiplies the 4,669 bytes an idle connection
holds while one per request breaks the allocation budget
([ADR 0018](./0018-the-trade-budget-has-three-axes.md)). A pool sized to the
thread count is the shape that would fit, and it is unbuilt on both sides.

**Refusing is not a step towards decoding and does not depend on it.** It is
the answer for a server that cannot read the body, and it stays the answer if
decoding never arrives — the same way `Transfer-Encoding` is refused rather
than extended.

## Where the check lives

In `finish`, which runs at the blank line, rather than in the header arm that
reads the value. Whether there is a body to refuse depends on `Content-Length`
and `Transfer-Encoding`, and a check in the arm would give a different answer
depending on which of the three headers the client sent first. This is the
same class of mistake as
[ADR 0090](./0090-a-body-framed-twice-is-refused.md)'s: an answer that depends
on header order is an answer two implementations will disagree about.

## A header on a request with no body is left alone

`Content-Encoding` on a GET with nothing under it says nothing about anything.
Refusing it would turn a request everybody answers into a 415 over a header
that had no effect, which is the opposite of the rule
[ADR 0101](./0101-a-request-nobody-else-would-answer-is-refused.md) states:
refuse what nobody else would answer, not what everybody else ignores.

## What it costs

One `eqlIgnoreCase` against `"identity"` on a request that sends the header,
and one bool test in `finish` on every request. The bool lands in padding the
`Request` struct already had, so the parser is the same size. No allocation,
nothing per connection, and the 415 is a static response like the 400 and the
431 beside it.
