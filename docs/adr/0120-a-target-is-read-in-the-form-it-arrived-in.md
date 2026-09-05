# A target is read in the form it arrived in

`GET http://example.com/users/7 HTTP/1.1` was a 404 on a route that plainly
exists. `parseRequestLine` handed the whole target to the router as a path,
which split it into `http:`, ``, `example.com`, `users` and `7`, and matched
nothing.

RFC 9112 §3.2.2 does not leave this open: **a server must accept the
absolute-form**, and a client talking to what it believes is a proxy sends it.
Nobody hit it here because a browser sends origin-form and the proxy in front
rewrites — which is why it sat in the roadmap under *a caller* rather than
being fixed when it was found.

**The authority is taken off the target and kept, and what is left is an
origin-form path the router matches.**

## The four forms, and which one has a route behind it

| Form | Example | What nilo does |
|---|---|---|
| origin | `/users/7?x=1` | the path, as before |
| absolute | `http://example.com/users/7` | split: authority kept, path routed |
| asterisk | `*` (server-wide `OPTIONS`) | passed through |
| authority | `example.com:443` (`CONNECT`) | passed through |

The last two are passed through rather than special-cased because neither names
a route here. nilo is not a proxy, so a `CONNECT` has nothing to tunnel to, and
a server-wide `OPTIONS` is a feature this framework does not have. Both reach
the router as they arrived and get the 404 or 405 they got before. Refusing
them outright was the alternative and it fails the rule
[ADR 0101](./0101-a-request-nobody-else-would-answer-is-refused.md) states:
refuse what nobody else would answer, and these are answered by somebody.

## The authority *is* the Host, and that is not a preference

RFC 9112 §3.2 is explicit: an origin server receiving an absolute-form target
**must ignore the received `Host` header** and use the authority instead. So
two things follow, and both are behaviour changes rather than additions:

- `c.host()` answers from the target when one arrived that way. A trusted
  `X-Forwarded-Host` still outranks it, because that is what the deployment
  says the client asked for while the authority is what *this hop* was
  addressed as ([ADR 0112](./0112-a-request-can-be-read-past-the-parts-a-handler-names.md)).
- An HTTP/1.1 request with an absolute-form target and no `Host` header is no
  longer the 400 that a missing `Host` otherwise is
  ([ADR 0101](./0101-a-request-nobody-else-would-answer-is-refused.md)). The
  request said which host it wanted; it said it on the first line.

A `Host` beside an absolute-form target is still read and a second one is still
a 400. What changed is only which line is allowed to answer the rule.

## Two shapes inside absolute-form are refused

**Userinfo.** `http://real.example.com@evil.example.net/` names
`evil.example.net`, and every human reading it in a log sees the first name.
RFC 9110 §4.2.4 says a recipient must reject a userinfo subcomponent in an
http URI, and a host somebody misreads is worse than a 400.

**An empty path carrying a query.** `http://example.com?a=1` means `/?a=1`, and
there is no `/` in front of that query to point at. This parser copies nothing —
every slice it produces is inside the connection's read buffer, because `App`
moves them onto a copy of the head by their offset into it — so serving this
would mean either an allocation on the request path or dropping the query
silently. Both are worse than refusing a shape nothing sends.

`http://example.com` with no path at all *is* served, as `/`. The slash handed
back is the second one of the target's own `//`, which keeps every slice inside
the head. A static `"/"` would not survive `App.rebase`, and finding that out
before shipping it is the only reason this paragraph is short.

## What it costs

**One byte compare on the request path.** `target[0] == '/'` is true for every
request a browser sends, and the scheme match is behind it — an origin-form
target never reaches `startsWithIgnoreCase`.

**16 bytes on the `Request` struct**, which is the one axis this spends: the
struct sits in the connection loop's frame, and a fiber holds its stack at its
high-water mark ([ADR 0063](./0063-a-handlers-stack-is-per-connection.md)), so a
byte there is a byte per connection rather than per request.

Measured rather than reasoned about. `bench/mem.py --port 8787 --path /users/1`
against `bench/main.zig` built `-Doptimize=ReleaseFast`, this commit against a
`git archive` of its parent:

| connections | before | after |
|---:|---:|---:|
| 2,000 | 8,835 B | 8,835 B |
| 5,000 | 8,795 B | 8,795 B |
| 10,000 | **8,781 B** | **8,781 B** |

Identical at every step out to ten thousand, where marginal has met average.
Whole-process RSS at 10,000 was 89,272 kB against 89,280 kB — eight kilobytes
apart over ten thousand connections, which is two pages of noise. A frame is
rounded well past 16 bytes and this landed inside the rounding.

(8,781 rather than the 4,669 quoted elsewhere because that figure is the
framework's floor under a handler that does nothing, and this route builds a
JSON response — the handler's own stack is the difference, which is ADR 0063's
whole point.)

Nothing per request, no allocation, and the refusals reuse the 400 that was
already static.

## Why the fuzzer's reference parser was changed too

`fuzz.zig` holds a second parser written the obvious way, and the two are
checked against each other on generated heads — `http://x/y` has been in its
target list all along. The reference now splits from the `://` separator
outwards where `http1.absoluteForm` matches the two schemes as prefixes, so
`http://a/b://c` is a head the two have to agree about rather than a shape they
share a mistake on.
