# A request that lasts is still one request

Everything v1 built assumes a request is short. Not "fast" — *short*: it arrives, it is answered, the arena is emptied, the fiber goes back to reading. Four features on the v2 list break that assumption, and they break it in the same place, so the decision is made once here rather than five times in five pull requests.

- **Streamed responses** — the body is written out in pieces because its length is not known when the head goes out.
- **Server-sent events** — the same, except the pieces arrive minutes apart.
- **Bodies larger than the arena** — the mirror image: read in pieces, because the whole thing does not fit anywhere sensible.
- **WebSocket** — the connection stops being HTTP after the handshake and lives until somebody closes it.

The question is not "where does the memory come from". That was the answer given at the end of a long session and it is too tidy. The question is: **what does a `Ctx` still mean when the handler holding it has been running for twenty minutes?**

## What does not change, and why that matters

Naming these first, because the list of things that break is shorter than it looks.

- **A `Str` is valid for the whole request, however long it is.** `Lifetime.end()` is called when the handler returns, not on a timer, so a path param read at minute nineteen is the same bytes it was at second zero (ADR 0004). No change.
- **The failure slot is bound to the fiber, not to a moment.** A fail function at minute nineteen finds its request (ADR 0007). What changes is only that a failure *after the head has gone out* cannot pick a status, which `c._sent` already knows.
- **The request arena is still emptied exactly once, when the request ends.** Nothing resets mid-request. That is a constraint, not a bug, and the next section is what follows from it.
- **A handler still gets its typed arguments.** Streaming happens on the response side, so `fn tokens(c: *Ctx, ask: Query(Prompt), llm: *Llm) !void` is an ordinary typed handler that happens to hold a `*Ctx` for the answer. The signature keeps meaning what it means (ADR 0015).

## Memory: a stream allocates nothing per piece

The arena is a bump allocator that is emptied when the request ends. A handler that allocates once per event and runs for twenty minutes therefore holds every event it has ever sent. That is not a slow leak, it is the arena working as designed against a use it was not designed for.

The rule adopted is not a new allocator. It is:

> **A stream allocates nothing per piece.** One buffer is taken from the request arena when the stream opens; after that, everything written passes through it and out to the connection.

The stream's writer is a `std.Io.Writer`, so `std.json.Stringify.value` serialises an event's JSON into that buffer with nothing in between, and `print` formats into the same place. A stream that runs for a week uses the same memory at the end as at the start.

ADR 0018's "allocations per request" invariant therefore survives contact with a feature that could have destroyed it. A non-streaming request still costs 3. A streamed one costs 2 — the request head and the stream's buffer — **whether it writes one piece or two hundred**, which is what a test asserts rather than what a comment claims.

The arena stays available for what it was always for — things whose size is bounded by the request head. A handler that insists on allocating per event may, and will grow the arena until the stream ends, and that is documented rather than prevented. Zig does not have the vocabulary to prevent it and inventing one here would cost more than the mistake.

The same rule going the other way is stricter still. `c.bodyStream()` reads a request body in pieces into a buffer **the handler already has**, so it allocates nothing whatsoever — not even the one buffer a response stream takes. Measured end to end on the streaming example: five rounds of a 3 MB upload plus a 50,000-row streamed report moved the server's RSS by 72 KB.

## Shutdown: a stream is told, and is expected to listen

`listen()` waits for requests in flight before returning, which is what makes a deploy not drop anything. A twenty-minute stream is in flight for twenty minutes, so the naive reading is that one SSE client can hold a deploy hostage.

The decision:

> A stream is counted as in flight like any other request, **and it is told to stop.** `stream.live()` goes false the moment a shutdown is requested, and a handler's loop is expected to check it.

Nothing is cut mid-frame and nothing is forcibly closed, which is what a hard deadline here would have meant. A handler that never checks `live()` delays the shutdown for as long as it runs — that is its choice, made visible, and it is the same bargain Zig makes everywhere else. The flag already exists: `Ctx._stopping` was added so a response could say `Connection: close` during a drain.

Measured on the streaming example with a client mid-stream: `Ctrl-C` to process exit, **204 ms**, and the client received the stream's closing event rather than a dropped connection.

The other way a stream ends is that the client went away, and that needs no machinery at all: the write fails, the handler gets an error, the fiber unwinds. A stream learns its reader is gone by trying to talk to it.

## The number: 21 KB times however many are open

One fiber per connection, and a stream holds its fiber. From v1's measurement:

| open streams | memory held |
|---|---|
| 1,000 | ~21 MB |
| 10,000 | ~210 MB |
| 100,000 | ~2.1 GB |

Most of that is the fiber's own stack; about 4 KB is the read and write buffers, which `Options.read_buffer` and `Options.write_buffer` turn down (17 KB per connection at 2 KB each). This is stated up front because TigerBeetle's rule, quoted approvingly in ADR 0015, is that every limit gets a number. Long-lived connections are the first zfast feature where the per-connection figure is the *design* rather than a footnote, and anybody planning to hold 100,000 SSE connections open should be planning around 2 GB before they write the handler.

## What the log line means now

The logger writes one line per request, when the handler returns, with how long it took. On a streamed response that line arrives when the stream *ends* and the duration is the stream's lifetime.

Left as is. The alternative — a line when the head goes out, and another when the body finishes — turns one line per request into two for a minority of requests, and makes every log parser in the world wrong about this server. The duration column on a streamed line means what it says: how long the response took. A time-to-first-byte metric is a different number and wants a different feature.

## HTTP versions and HEAD

Two cases where "write the body in pieces" is not available, decided here so the implementation has no room to improvise:

- **HTTP/1.0 has no chunked encoding.** A stream to a 1.0 client writes its pieces with no framing, sends `Connection: close`, and the connection ends with the body. That is the only way a 1.0 client can know where the response stopped.
- **A HEAD gets the head and nothing else.** The stream is created, the handler runs and writes normally, and every write is dropped. A handler should not have to know which verb it is answering (`Ctx.send` already works this way).

## What is deliberately not decided here

- ~~**No write timeout.** A client that opens an SSE stream and stops reading parks a fiber until TCP gives up on it, which can be minutes. That is a denial-of-service shape and zfast has no answer for it today. It belongs with read timeouts and header timeouts, which are also missing, and all three want one ADR about deadlines rather than a knob bolted onto streaming.~~ *Answered by [ADR 0023](./0023-a-deadline-belongs-to-an-operation-not-to-a-request.md).* The answer turned out to need nothing from streaming at all: a deadline bounds one write rather than a response, so a stream that sends an event a minute is inside the limit however long it runs, and the client that stops reading is caught on the next write. The question this ADR left open — whether a stream can extend its own deadline — dissolved rather than being decided, because there was never a per-response deadline for it to extend.
- **Backpressure beyond the socket's.** Writing blocks the fiber when the write buffer is full, which is backpressure in the only sense that matters here. A queue with a policy — drop oldest, drop newest, disconnect — is what a pub/sub layer wants, and zfast is not one.

  > **Amended by [ADR 0038](./0038-a-broadcast-rings-a-bell-it-does-not-write.md).** A `Room` is one, and it has that queue and that policy. What survives of this refusal is the part that was right: the *connection layer* still has no queue and no policy, and a stream or a body still gets the socket's backpressure and nothing else. What changed is that the policy is now named at the room, by whoever built it, rather than being a hidden default underneath every connection — which is what this paragraph was actually refusing.
- **A typed shape for streaming.** A handler that streams asks for a `*Ctx`. Whether there is a `Stream(T)` return type that reads as well as `Response(T)` does is a real question, and it is a better question once there is a stream to look at.

## Consequences

- `Ctx` gains one optional — what kind of stream is open, if any — so App knows not to send a default 200 afterwards, and knows how to close a body the handler forgot to finish. It lives on the `Ctx` rather than the `Stream` precisely because the `Stream` is on the handler's stack and App runs after the handler has returned.
- **A handler that writes its answer cannot be tested by calling it**, which is most of what the README says about testing. So `zfast.testing.Client` exists: one request through an App, no server, no socket, and chunk framing undone so a test asserts on what a client would see. It is the first piece of zfast that exists only for tests, and it is worth it — a feature whose handlers cannot be tested is a feature that will not be.
- `Transfer-Encoding` joins the reserved headers. A response announcing framing zfast is not applying is read as a chunk size, and everything after that is a guess.
- **The `retain_with_limit` on the arena reset becomes load-bearing in a new way.** A handler that did allocate per event leaves a large arena behind; the 16 KB cap already trims it before the connection waits for its next request.
- Four features now share one answer instead of four. Range requests, notably, need none of it: a range is a slice of a file already in memory with different headers, and it is the one item on the streaming list that was never blocked on anything.
- The rule "a stream allocates nothing per piece" is testable, and should be tested the way the three-allocation budget is — by counting, not by reading the code.
