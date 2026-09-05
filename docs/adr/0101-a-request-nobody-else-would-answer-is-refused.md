# A request nobody else would answer is refused

[ADR 0090](./0090-a-body-framed-twice-is-refused.md) closed four ways for the
proxy in front and nilo to disagree about where a request ends. A scan of the
parser found two more, and they are the same mistake in two places: a header
whose grammar RFC 9112 makes a **must**, read as though the rule were advice.

**A `Transfer-Encoding` whose final coding is not `chunked` is a 400, and an
HTTP/1.1 request with no `Host` or with two of them is a 400.**

## What was happening

`applyHeaderAt` asked `saysChunked` and, when the answer was no, **did nothing at
all** — no error, no framing, `content_length` left at zero. So
`Transfer-Encoding: gzip` with no `Content-Length` was answered immediately as a
request with no body, and the bytes the client sent as a body were still sitting
in the read buffer when the connection loop came round for the next request.

That is the definition of the case ADR 0090 was written for. RFC 9112 §6.1 says
a server that cannot decode the final coding **must** answer 400, and nilo can
decode exactly one; a front end reading `gzip` as a coding it will not pass on,
while nilo reads it as no body at all, is two hops disagreeing about how many
requests arrived.

`Host` was worse in a quieter way: nothing in `http1.zig` looked at it. The
parser's four-header switch did not include it and neither did `App`. RFC 9112
§3.2 requires a 400 for an HTTP/1.1 request carrying none and for one carrying
more than one, and both are refused by the front end nilo assumes is there
([ADR 0028](./0028-tls-is-terminated-in-front.md)) — so serving them was nilo
agreeing to answer a request nobody else agreed to. It also matters one layer
up, because a `Host` a handler reads back into a `Location` or a link was text
no layer had checked.

## Why the differential test did not find either

`fuzz.zig` carries `Transfer-Encoding: chunked, identity` in its corpus and the
reference parser read it the same wrong way, so the two agreed and the check
passed. That is the failure mode ADR 0090's own section on differential testing
describes: **an oracle written from the same reading of the spec as the thing it
checks tests that the reading is consistent, not that it is right.** Nothing
about the harness catches it; only reading the RFC again does.

The corpus is what changed as a result, and it changed more than the two new
entries. Every framing entry now carries a `Host`, because otherwise the whole
corpus would be refused for want of one and would stop exercising framing at
all — a check that silently never runs, which is the thing this repository keeps
finding. The block-edge trio is the one group deliberately left without one:
their byte offsets are the point, a header line in front would move all of them,
and what they are for is where the head *ends*, which is asked before anything
is parsed.

## Where the `Host` rule lives

`parseHead`, in a `finish` called from every exit rather than in `App`.

A second `Host` is caught as the line goes past, in a fifth arm on the length
switch — `has_content_length` was the worked example that the extra bool lands
in padding the struct already had, and `has_host` does too, so `@sizeOf(Request)`
is unchanged. That there was never a *first* one is only knowable once the head
has ended, which is why `finish` exists at all.

Putting the absence check in `App` was the alternative, and it would have cost
the same test churn while splitting one rule across two files. `parseHead` is
what parses a request message; a message rule belongs to it.

**HTTP/1.1 only.** `Host` was not required before 1.1 and a request that does
not claim to speak it is not held to it. A repeated `Host` is refused under both
versions, because two authorities in one request is not a version question.

**A repeat is refused even when the two agree**, which is where this differs
from `Content-Length` one arm down: §3.2 refuses the repeat itself rather than
the disagreement. A request naming two authorities is one the front end and nilo
may route differently, and that is true whether or not the strings match today.

## What it costs

Nothing per connection and nothing allocated. On the request path it is one more
byte in the parser's first-byte set — `'c', 'e', 'h', 't'`, which compiles to the
same range test and mask as `'c', 'e', 't'` did — plus one four-byte
`eqlIgnoreCase` on the `Host` line of every request, and one predictable branch
at the end of the head. `ETag` and `Date` are the same length and reach the arm
too; both fail on their first byte.

Measured as a pair of ReleaseFast benchmark servers, interleaved: see
[`bench/result/http.md`](../../bench/result/http.md). Binary size, stripped
ReleaseFast, +208 bytes on `nilo-hello`, which also carries the other four
changes in the same commit.

## What it breaks

**A client that sent no `Host` used to be served and now gets a 400.** No
browser, no proxy and no HTTP library does that, and the front end in front of a
deployed nilo already refused it — but a hand-written test client speaking to
the server directly very likely did, because nothing made it necessary.

Inside the repository that was 267 request literals across seven files, which is
the honest price of the rule and is why it is worth stating rather than burying:
the change is one line in a parser and three hundred in tests.
`testing.Client.get` and friends already wrote `Host: test`, so every test that
went through the client was untouched.
