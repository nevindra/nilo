# 0090 — a body framed twice is refused

**Status:** accepted

## Context

nilo is deployed with a reverse proxy in front of it. That is not an assumption
about how people run it, it is a decision on the record: TLS is terminated
upstream (ADR 0028), so there is always something in front reading the same
bytes nilo reads.

Two parsers reading one request is fine while they agree about where the body
ends. Request smuggling is what happens when they do not. The front end reads
one request and forwards what it thinks is one request; nilo reads one and a
half, answers the first, and leaves the second half in the buffer as the start
of the *next* client's request. What that next client gets back is a response to
a request somebody else wrote.

`applyHeaderAt` had four ways to disagree with whatever is in front of it.

**`std.fmt.parseInt` is not `1*DIGIT`.** `Content-Length: +5` came back as 5,
`1_0` as 10, `-0` as 0. RFC 9112 §6.2 says the value is digits and nothing else,
and nginx, haproxy and envoy all agree with the RFC. So nilo was reading a body
length out of bytes the thing in front would have refused.

**A repeated `Content-Length` was last-one-wins.** `Content-Length: 6` followed
by `Content-Length: 7` framed a 7-byte body here and, for a front end taking the
first, a 6-byte one.

**`Content-Length` next to `Transfer-Encoding: chunked` was accepted**, with
both fields set and `discardBody` picking chunked. Which is one of the two
readings the RFC names as the smuggling case outright.

**`chunked` was matched as a substring.** `std.ascii.indexOfIgnoreCase(value,
"chunked")` takes `xchunked` and `chunked-x` for chunked framing. A front end
reads either as a transfer coding it does not know.

`fuzz.zig` has held a reference parser against the fast one since it was
written, and the doc comment on the comparison says what it is for: "a front end
and a back end that disagree about how long a body is are how a request gets
smuggled past the one doing the checking". It never caught any of these, because
the reference parser was written from the same reading of the spec as the thing
it was checking. A differential test only finds what the two implementations
disagree about.

## Decision

All four are `error.BadHeader`, which is already a 400.

- A `Content-Length` value that is not one or more ASCII digits.
- A second `Content-Length` whose value differs from the first. Repeating the
  same value is allowed: RFC 9110 §5.3 lets a recipient treat repeated field
  lines as the one value they agree on, and there is nothing to disagree about.
- `Content-Length` and chunked framing in the same request, in either order.
- A second `Transfer-Encoding` line once chunked has been seen, because the
  lines combine into one list and chunked has to be last.

`chunked` is now read as the final comma-separated coding rather than as a
substring, so `gzip, chunked` is chunked and `xchunked` is not.

`Request` gains `has_content_length`, because `content_length` alone cannot tell
an absent header from `Content-Length: 0` and the checks above need to. It lands
in padding the struct already had.

The reference parser in `fuzz.zig` was rewritten alongside, deliberately by the
other route: it splits the coding list forwards and keeps whatever came last,
where `http1` takes the last comma and reads from there. Two spellings of one
rule is the pair worth having.

## What was rejected

**Resolving rather than refusing.** RFC 9112 §6.1 permits a server to process a
request carrying both framings "in accordance with the Transfer-Encoding alone",
and that is what most servers do. It is the wrong choice here for the reason the
same paragraph gives: the message "might indicate an attempt to perform request
smuggling". Resolving means picking a reading and hoping the proxy picked the
same one. A 400 means nobody has to guess. nilo has no obligation to be liberal
about a request that is only ever sent by mistake or on purpose.

**Refusing a leading zero.** `Content-Length: 05` was on the refuse list in the
first draft of this, with "leading zeroes" written into the doc comment beside
`+5` and `1_0`. It is wrong: `05` is two digits, so it is legal ABNF, and every
parser in the chain reads it as 5. Refusing it would turn a request everyone
agrees about into a 400. The test caught it, which is the only reason it is a
sentence here rather than a bug.

**Sharing `range.number`.** `range.zig` has carried the same four-line
digits-only parser since it was written, with a comment naming the same
`std.fmt.parseInt` trap. It stays duplicated. `range.zig` runs under a plain
`zig test http/range.zig` with no module graph, and importing `http1.zig` would
cost it that.

## What it costs

Allocations per request: none. Memory per idle connection: one bool that fits in
existing padding.

Throughput: not measurable. Eight interleaved triples through `zig build
profile` put this change and the three that shipped with it at +1.25ns against
HEAD on a 192ns request, with the sign flipping in four of the eight, which is
the answer "unchanged" (`bench/result/http.md`). The two arms this touches do
not run at all on a GET with no body, which is what the profile measures; on a
POST they trade a `parseInt` for a digit loop over the same bytes.

Binary size: unchanged to the byte at the resolution the linker reports.
