# A body under an encoding nilo cannot read is refused, except gzip

**Status:** accepted
**Topic:** [http1-protocol](../design/http1-protocol.md)

## Context

Nothing read a request's `Content-Encoding`. A client sending a gzipped body had its compressed bytes handed to `c.json` as though they were the JSON, and got back a 400 saying the body was malformed, a sentence true about the bytes and useless to the person who sent them: the mistake is one line of client configuration and the answer sends them to look at their payload instead.

Refusing every encoding once meant refusing gzip too. Decoding it was set aside for the reason response compression was: a deflate window is 64 KB, and one per connection multiplies the 4,669 bytes an idle connection holds while one per request breaks the allocation budget ([ADR 017](./017-the-trade-budget-has-four-axes.md)); a pool sized to the thread count was the shape that would fit, and it was unbuilt on both sides. That premise held until a caller hit the refusal as a default rather than a choice: the stock OpenTelemetry Collector gzips its exports, so a nilo server on the receiving end needed a proxy in front to undo it, which is not what a proxy terminating TLS is for ([ADR 027](./027-tls-is-terminated-in-front.md)).

## Decision

**A body under any `Content-Encoding` but `identity` or `gzip` is a 415 naming the header, unless the route's chain says it reads that coding itself. A body under `gzip` is inflated once into the arena, in place of the bytes that arrived, and nothing after that line knows how it was sent.**

**A route can read a coding itself** (`nilo.bodyEncodings(.{"snappy"})`, [ADR 283](./283-a-route-can-read-a-content-encoding-itself.md)): for an App that has one, the refusal below is held back until the route is matched, and a body under a coding the matched route names reaches `c.body()` and `c.bodyStream()` as it arrived. Every other route, and every App that has none, is refused as this ADR says.

### Why 415 and not 400

The request is well formed and every parser in the world agrees about what it says; this server cannot read what it carries, which is what `415 Unsupported Media Type` is for. A 400 would be nilo claiming the client sent nonsense.

### Why gzip needs no pool

The 64 KB-window argument was about the other direction. A deflate *compressor* holds a window and a hash chain of its own and has to. A *decompressor* needs only the last 32 KiB of what it has written, to copy back-references from, and `std.compress.flate.Decompress` has a mode where that history is the destination writer's own buffer: handed no window at all, it writes straight into the writer and reaches back into its buffer for a match. The arena is going to hold the decoded body anyway, so the buffer that holds the body *is* the window, and the thing the pool was for does not exist on this side.

The allocation is exact rather than grown into. The last four bytes of a gzip stream are the uncompressed length modulo 2³², and read first, that number sizes the one arena `alloc` and is checked against `max_body` before a byte is inflated. Two checks come before the number is believed, because a wrong number sends the client to the wrong header: the three magic bytes, so JSON somebody forgot to compress reads as "not gzip" rather than "too large", and deflate's own ceiling of about 1032 to one, so a stream cut short (whose last four bytes are whatever happened to be there) reads as "broken" rather than "too large". A stream whose bytes disagree with its trailer, too many or too few, fails to decode as one answer, a 400 naming the coding, from the handler's own request path so the connection is kept. The compressed bytes are already bounded by `max_body` on the way in ([ADR 083](./083-a-body-is-taken-as-it-arrives.md)); the inflated ones are bounded by the same number, so a small body cannot inflate into a large one.

`x-gzip` is read as `gzip`, since RFC 9110 says a recipient should.

### Where the check lives

In `finish`, at the blank line, rather than in the header arm that reads the value: whether there is a body to refuse depends on `Content-Length` and `Transfer-Encoding`, and a check in the arm would give a different answer depending on header order, the same class of mistake [ADR 070](./070-a-request-nobody-else-would-answer-is-refused.md) refuses.

### A header with no body is left alone

`Content-Encoding` on a GET with nothing under it says nothing about anything. Refusing it would turn a request everybody answers into a 415 over a header with no effect, the opposite of the rule [ADR 070](./070-a-request-nobody-else-would-answer-is-refused.md) states: refuse what nobody else would answer, not what everybody else ignores.

### What still does not decode

`c.bodyStream()` refuses any coding with a 415 of its own, except on a route that reads the coding itself (ADR 283), where it hands the bytes over as they came. A stream hands bytes out as they arrive into the caller's buffer and holds nothing, so there is no buffer to be the history, and the caller's own buffer is handed a piece at a time; decoding on that path needs a window per stream (the pool question again) or a decoder over the caller's buffer with a minimum size, and it is not the path the Collector takes.

**The head is not rewritten.** `header("Content-Encoding")` still says `gzip` and `header("Content-Length")` still gives the wire length after `body()` has inflated it, because the head is read where it lies ([ADR 085](./085-every-header-without-handing-out-the-head.md)) and there is nothing to remove a line from. A proxy handler forwarding `body()` with the request's own headers sends plain bytes labelled `gzip`; `Ctx.body`'s doc comment names the trap and says what to send instead.

## What was rejected

**Refusing the coding on every route with no way round.** The position this ADR first held, and the one that shipped: the refusal is made while the head is read, before any route matches, so a receiver whose protocol is a coding nilo does not decode (Prometheus remote-write sends snappy and no client setting avoids it) could not be written at all, not even over `bodyStream()`. ADR 283 holds the refusal back for an App that has a route which reads a coding, and leaves it where it was for every other.

**Decoding `deflate` too.** HTTP's `deflate` is a zlib stream some clients send raw, and telling the two apart is a heuristic; nothing that pushes telemetry sends it, and the 415 names gzip specifically rather than guess.

**The pool, as the roadmap once described it**, right for the outbound half where the compressor's state is real and per-thread is the only place to put it. For the inbound half it would have been a 64 KB window borrowed to do what the destination buffer already does for nothing.

**Inflating straight from the socket** rather than reading the compressed bytes first. Saves the compressed copy in the arena, but needs a bounded reader over the connection for the sized case and the chunked reader taught to be one for the other, and moves the inflater's stack frame to where the fiber suspends waiting for bytes, which is where a frame costs per connection ([ADR 062](./062-where-a-connection-waits-is-what-it-costs.md)). The compressed copy is cheaper than that.

**Growing into an `Allocating` writer** rather than trusting the trailer. Works for a stream with no trailer, and gzip always has one; reading the four bytes costs nothing and buys an exact allocation and a ceiling check that runs before the work rather than partway through it.

**A body that did not inflate is not the body.** `_body` is assigned only once the inflate has succeeded; it used to hold the compressed bytes first, so a second `c.body()` after a failed one (a middleware that logged the error and carried on) was handed them. A failure now leaves it empty and refuses every later call with a 400, and the connection stays good, because the wire was read to its end ([ADR 083](./083-a-body-is-taken-as-it-arrives.md)).

## What it costs

| Axis | Cost |
|---|---|
| Allocations per request | unchanged on a request that is not gzipped. A gzipped one pays one more arena allocation, of the inflated size exactly, on top of the one or two `readSizedBody` already makes for the compressed bytes; the compressed copy is not freed separately, it is arena memory and goes with the request |
| Memory per idle connection | unchanged for a connection that never sends a gzipped body. The inflater's state is 3,384 bytes of Huffman tables (`@sizeOf(std.compress.flate.Decompress)`, measured) on the handler's stack while `body()` runs, and since a fiber's stack is its high-water mark for the life of the connection ([ADR 062](./062-where-a-connection-waits-is-what-it-costs.md)), a connection that has ever sent one holds up to 3.4 KB more than one that has not. That is 1.5% of the 230,096 bytes a compressor's state was measured at, the number that kept the outbound direction out |
| Throughput and p99 | nothing on a request without the header; `finish` tests an enum instead of a bool, the same instruction. The inflating itself is a loop with no wait in it, since the compressed bytes are already in the arena, so the fiber does not suspend inside it |
| Binary size | `std.compress.flate.Decompress`, which `http/static.zig` already links for its own tests, and which a program serving gzipped static files already carries the compressor's half of. Unmeasured on its own; small against ADR 017's running total |

Refusing every other encoding, and gzip with no body, costs one `eqlIgnoreCase` on a request that sends the header and one enum test in `finish` on every request; nothing allocated, nothing per connection, and the 415 is a static response like the 400 and the 431 beside it.
