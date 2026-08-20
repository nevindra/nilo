# 0094 — a header is answered as asked, or refused

**Status:** accepted

## Context

Three request headers were read and then answered with something that was not
what they asked for. They were found by one reading of `http/` and they are one
mistake, which is why they are one ADR: **nilo knew the header was there and gave
an adjacent answer instead of the defined one.** An adjacent answer is worse than
no answer, because no answer is visible and an adjacent one is not.

**`Expect: 100-continue` was never answered.** Nothing under `http/` read the
header at all. A client that sends it holds its body back until the server says
something, and a server that says nothing leaves it waiting on its own timer —
curl's is one second, on every upload past its threshold. So an upload that
should cost one round trip cost one round trip plus a second, on every request,
for as long as the feature has existed.

**`If-Range` used the `If-None-Match` comparison.** `static.etagMatches` strips a
`W/` prefix and honours `*`, which is right for `If-None-Match` and is the one
comparison RFC 9110 §13.1.5 says must be strong. A weak validator means "close
enough to reuse, not byte for byte the same", and byte for byte is exactly the
claim a resumed download acts on: the client staples the returned bytes onto the
prefix it already holds. `static.etagForSpilled`'s own doc states that rule, as
the reason nilo's tags are strong — so the design knew it and the shared
comparison did not.

There was a second half. `sendfile.send` guarded its `If-Range` with
`contents.etag.len > 0` and said why: `etagMatches` would otherwise let a bare
`*` stand in for a comparison that never happened. `App.serveHeldFile` had no
such guard, while `serveHeldFile`'s own doc claimed there is exactly one copy of
each rule. Two arms of one feature, disagreeing, with a doc asserting they could
not.

**A multipart part naming its file only with `filename*` became a text field.**
`parseMultipart` decides a part is a file by asking `parameterOf` for `filename`,
and `parameterOf` compares the key exactly, so `filename*` does not match.
`form.zig` says the encoding is deliberately not read and gives the reason: "the
plain `filename` is always sent alongside it". That is true of browsers and is
not true of every HTTP library. What happened when it was not true is the part
with the wrong answer: the part was bound as a *text* field whose value is the
raw bytes of the upload, and the `Upload` the endpoint asked for was reported
missing. **The 400 named the wrong thing**, which is the one outcome that leaves
a caller with nowhere to go.

## Decision

**Each header gets the answer it asks for, and where nilo will not implement the
answer it refuses instead of inventing one.**

### `Expect: 100-continue`

`Request.expect_continue` is set by a new arm in `applyHeaderAt`, and the interim
response goes out at the moment nilo commits to reading the body — from
`Ctx.aboutToReadBody`, which the two body paths call and the WebSocket handshake
does not. A handshake is about to read frames, not a body, and has already
decided to write a 101.

Sending it there rather than when the head is parsed is what buys the other half
of RFC 9110 §10.1.1 for nothing. **A request refused before it reaches that line
is answered with its final status and the body is never sent at all**: a body over
`max_body` (`Ctx.body` checks the ceiling before it reads), a 404, a 405, or a
handler that simply never asks. A rejected 20 MB upload now costs the bytes of
the 413.

Three cases send nothing: an HTTP/1.0 client, which cannot be sent an interim
response (RFC 9110 §15.2); a request already answered; and `Content-Length: 0`,
where the client is holding nothing back whatever it expected.

`App.drain` learns one line. A request that expected a continue and never got one
still has its body on the client's side, so discarding it would mean waiting for
bytes nobody will send until their own timer fires. That connection answers and
then closes.

Only `100-continue` is recognised, matched against the whole field value rather
than searched for inside it. RFC 9110 allows a 417 for any other expectation and
nilo ignores them: an expectation nobody defined is one no client sends, and a
417 would be a new way to refuse a request that works today.

### `If-Range`

A second entry point, `static.etagMatchesStrong`, used by both `If-Range`
callers. It refuses a `W/` tag, refuses `*`, compares a single tag rather than a
list, and treats an empty ETag as matching nothing — which retires
`sendfile.send`'s hand-written guard rather than adding a second one to
`serveHeldFile`. `etagMatches` keeps all three behaviours for `If-None-Match`,
where all three are correct, and its doc now says it is not for `If-Range`.

### `filename*`

A part carrying `filename*` and no `filename` is a 400 naming the part. nilo
still does not read RFC 6266's encoding; it stops pretending the part was
something else. This is the call [ADR 0081](./0081-a-ceiling-that-is-reached-is-said-out-loud.md)
makes about a ceiling, applied to a parameter.

## What was rejected

**Answering `100 Continue` from the head parser, as soon as the header is seen.**
Simpler, and it throws away the better half of the feature: once the interim has
gone out the client sends the body, so a 413 for an oversized upload arrives
after the 20 MB rather than instead of it. Deciding at the moment of reading is
what makes "refuse without reading" the default rather than a special case.

**Answering `417 Expectation Failed` for an expectation nilo does not know.**
Permitted, and it converts a request that works today into one that does not. The
expectations that would reach it do not exist.

**Rewriting `serveHeldFile`'s doc to admit the two arms differ.** The cheaper of
the two ways out, and it makes the disagreement permanent. The comparison was one
function away from being impossible to get wrong.

**Reading `filename*` properly.** RFC 6266's `UTF-8''…` is percent-encoded text
with a charset and an optional language tag, and `core/percent.zig` could decode
it ([ADR 0066](./0066-percent-is-needed-by-two-layers.md)). It is refused instead
because nobody has asked: the one caller who would need it is a non-browser
client that sends the encoded form alone, and until one turns up, decoding it
means shipping a second filename path with no test written from a real request.
The refusal is what makes that caller findable.

**Widening `parameterOf` to match a trailing `*`.** It would make `filename*` and
`filename` the same key, so the encoded value would be read as a plain filename —
`UTF-8''caf%C3%A9.png` as the name of a file. That is the original bug wearing a
hat.

## What it costs

Measured on the machine and by the method in
[`bench/result/http.md`](../../bench/result/http.md).

**Allocations per request: unchanged**, and the budget test holds it. Nothing
here allocates: the interim response is a 25-byte literal written to a buffer
that already exists, `etagMatchesStrong` is a compare, and the multipart refusal
is a `fail` message in the request arena on a path that ends in a 400.

**Memory per idle connection: unchanged.** `Request` gains one bool, which lands
in padding the struct already had, and `Ctx` gains one, which sits on
`serveRequest`'s frame — `noinline`, and unwound before the connection waits
([ADR 0071](./0071-where-a-connection-waits-is-what-it-costs.md), and now
measured rather than reasoned: `bench/result/http.md`).

**Throughput: unchanged, and the parse row is the one to watch.** `parseHead`'s
first-byte filter went from two letters to three, because `Expect` begins with
neither `c` nor `t`; and `Cookie` is exactly as long as `Expect`, so it now
reaches the length switch and pays one `eqlIgnoreCase` that fails on its first
byte. Seven interleaved pairs through `zig build profile`, the order reversed for
the last three, put **`parse the head` at 28–31ns on both sides**: the four
cleanest pairs read +1ns, and the sign flips in the seventh, so the difference is
inside the spread.

The end-to-end figure read 13ns lower on the changed tree in all seven pairs.
**That is withdrawn rather than reported**, for the reason ADR 0071 withdrew the
same shape of reading: nothing here can make a request faster, the row that
changed moved the other way, and a request total that swings 213–243ns across
runs is measuring code layout. A change that spends binary size does not also
need to have been free.

**Binary size: +1,280 to +2,032 bytes**, stripped `ReleaseFast`, and this is the
axis it spends.

| binary | before | after | delta |
|---|---|---|---|
| `example-hello` | 899,768 | 901,048 | **+1,280** |
| `example-chat` | 936,288 | 937,632 | +1,344 |
| `example-rest` | 1,051,976 | 1,053,848 | +1,872 |
| `example-forms` | 970,200 | 972,232 | **+2,032** |

`forms` is the top of the range because it is the example that reads a multipart
body, so it links the refusal's message. `hello` is the floor and pays for the
interim response and the strong comparison without using either, which is the
disclosure ADR 0018 asks for rather than a defence of it.
