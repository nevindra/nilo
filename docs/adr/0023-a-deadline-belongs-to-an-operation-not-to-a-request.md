# A deadline belongs to an operation, not to a request

nilo 0.1.0 had no deadlines of any kind. `nc host 8080`, then say nothing, and a fiber is parked until TCP gives up on it — which on Linux is minutes. Repeat from one laptop and the server is full. No tool, no bandwidth, no cleverness: this was the largest hole in the project and [ADR 0020](./0020-a-request-that-lasts-is-still-one-request.md) named it and declined to fix it, on the grounds that read, header and write timeouts want one decision rather than a knob bolted onto each feature.

This is that decision.

## The question that decides the shape

Not "where do the timeouts go". It is: **what is a deadline attached to?**

The obvious answer is the request. Give a request 30 seconds; if it is not done, cut it. Every framework with a `request_timeout` works that way, and it is wrong here for reasons that are not about performance:

- **It is wrong about streams.** A server-sent event stream that runs for an hour is a request. So is a WebSocket. So is a 4 GB upload on a domestic line. Under a request deadline, each of those is either killed for working correctly or the deadline is set so high that it stops protecting anything.
- **It cannot be implemented without cancellation.** Cutting a request that is halfway through a handler means unwinding a fiber that is not asking to be unwound. Zig has no way to make that safe — the same fact that makes a `recover` middleware impossible ([ADR 0008](./0008-no-recover-middleware.md)) — so the honest version of a request deadline in nilo is "stop waiting on the socket", which is not a request deadline at all.
- **It answers the wrong question.** A handler taking 30 seconds is a slow handler, and slow handlers are the author's business. A *client* taking 30 seconds to send a header is nobody's business but the server's, because it is the server's fiber being held.

So:

> **A deadline is a limit on one wait for the network, not on a request.** Four limits, each on a different wait, and none of them can interrupt a handler that is doing work.

Nothing in nilo can be cut off mid-computation, which means nothing had to be made interruptible, which means this ADR adds no new way for a handler to fail. Every failure it introduces is a read or a write that returns an error — a shape every one of these call sites already handles, because a client can always disconnect.

## The four limits

| `Options` | Default | The wait it bounds |
|---|---|---|
| `header_timeout_ms` | 10,000 | From the first byte of a request head to the blank line that ends it |
| `idle_timeout_ms` | 75,000 | A connection between one request and the next |
| `body_timeout_ms` | 30,000 | Any single read of a request body |
| `write_timeout_ms` | 30,000 | Any single write to the client |

Zero turns one off. All four zero is 0.1.0's behaviour, kept reachable so that "put it behind a proxy that has them" stays a real option rather than a thing the docs say while the code disagrees.

**The header limit is absolute and the others are durations.** This is the only subtle line in the design and it is the whole defence. A client sending one byte a second satisfies a per-read limit of any size, forever, and never finishes a head — so the head gets one deadline, computed when its first byte arrives and shared by every read after that. `readHead` arms it exactly once; re-arming per read would move the finish line every time a byte turned up, which is the attack rather than the defence, and a test counts the arming rather than trusting the comment.

The other three are per operation, because for them "how long is reasonable" is a function of size and line speed that a server cannot know in advance. A 4 GB body over a slow link is not an attack. A body that stops arriving is, and a per-read limit catches it without anybody having to guess how big a legitimate upload is.

**Idle and header are separated on purpose.** A browser holding a keep-alive connection open has done nothing wrong and may do it for a minute; a client halfway through a head has. Different limits, and different answers when they run out — see below.

## What runs out, and what the client is told

- **Halfway through a head → 408, then close.** The client asked for something, so it gets an answer.
- **Idle, having asked for nothing → close, no answer.** There is nothing to answer. A status here is a line in a proxy's log that somebody has to decide what to do with.
- **A body that stops → the connection goes, with whatever the response already was.** If the handler was reading, it gets a read error like any other. If nobody read it, `App` was discarding it to reuse the connection, and now it will not be reused.
- **A write that stops → the response is abandoned and the connection closed.** Nothing else is possible: the head has gone out already.

The distinction between "timed out" and "the connection broke" needs asking for, because both arrive as `error.ReadFailed` through a `std.Io.Reader` — that interface has one error and no room for a reason. So the reason is kept on the side and `Deadlines.timedOut()` asks for it, right after the operation that failed. Which is also why a 408 is conditional on there being buffered bytes: a client that vanished mid-head gets nothing written into a socket nobody is holding.

## A WebSocket has no read limit, and that is not an oversight

After the handshake, reads go back to no limit at all. A chat tab with nobody typing is working correctly, and any read limit closes it.

What is worth catching there is a client that has gone away without saying so, and the answer to that is a ping it fails to answer — which needs a frame to send, a reply to wait for, and a decision about what to do when several are missed. That is a WebSocket feature with its own design, not a number in `Options`, and calling `idle_timeout_ms` that would be pretending.

Writes keep their limit, which is what makes this safe rather than a hole: a WebSocket whose client has stopped reading is caught by the write limit, and that is also the case that matters for a server pushing to a client that walked away.

## What this buys, measured

Against the real server on a real socket, with the limits turned down to 1000ms (2000ms idle) so a check takes seconds instead of a minute:

| | |
|---|---|
| A healthy request | 200, 10ms — untouched |
| Two requests down one keep-alive connection | both 200 |
| A head that stops halfway | **408 at 1001ms** |
| A head at one byte every 300ms — the slowloris shape | **408 at 1201ms** |
| An idle keep-alive connection | **closed at 2000ms**, nothing written |
| A body that stops halfway | **connection released at 1002ms** |
| 80,000 answers asked for and none read | **closed at 1116ms** |

The last row is the one that matters for streaming. Before this, that client parked a fiber in a blocked write for as long as the kernel would allow.

## Where it lives

The Engine already has to be able to wait with a limit — it cannot implement `accept` with a stop flag otherwise — so this asks nothing new of it. zio keeps a timeout on its reader and its writer and applies it to every operation, so putting a limit on the next read is a field store: no timer, no watchdog fiber, nothing per connection.

What the Bulkhead adds is the split between mechanism and policy. `engine.Clocks` can put a limit on a read or a write and has no idea why. `bulkhead.Deadlines` knows why — it holds the four numbers and the `arm*` calls that work out which limit applies — and has no idea how. `serve` is now the one call in the Bulkhead that wraps the Engine rather than re-exporting it, and only so that these two halves meet without either naming the other.

That split is also the test seam, which is the practical reason it is worth having. `Deadlines` reaches its target through a vtable, so a test can hand `App` one that writes down what it was asked for instead of doing it — and then "the header deadline is armed once, however many reads the head takes" is a counting assertion that runs in a millisecond, rather than a socket test that would have to wait out a real deadline to prove a negative. What zio does with a limit once it has one is checked by hand against a real server; the table above is that run.

## Consequences

- **`Ctx` carries the connection's limits**, because the paths that read from a connection are on `Ctx` and the limits belong to the connection.
- **`Ctx.aboutToRead` arms the body limit.** It already existed as the choke point every read passes through — it asserts that the request head was copied out of the read buffer first ([ADR 0018](./0018-the-trade-budget-has-three-axes.md)'s allocation work put it there). Arming the clock in the same place makes "every read has a limit" structurally true rather than remembered, for the same reason and at the same one line of cost.
- **`handleRequest` takes a fifth thing.** It was already deliberately separate from the Engine, and a `Deadlines` is a Bulkhead type rather than an Engine one, so that stays true. Every test that drives it directly passes `.off`, which is a complete working instance that does nothing.
- **The log line for a failed write says what happened.** "handler GET /users/7 failed after answering: WriteFailed" sends whoever reads it looking for a bug in a handler that did nothing wrong. When the write ran out of time it now says the client stopped reading.
- **A default changed behaviour rather than adding to it.** A server that upgraded to this and has clients on genuinely bad links may now see 408s it did not see before. That is the point, the numbers are generous, and it is a pre-1.0 release.
- **`idle_timeout_ms` is the first knob whose real units are memory.** About 21 KB per idle connection ([ADR 0020](./0020-a-request-that-lasts-is-still-one-request.md)), so a server with many visitors and few of them active wants it lower — and until now it had no way to want that.
- **A per-request deadline is still not available**, and a handler that loops forever still holds its thread. That is [ADR 0014](./0014-handlers-must-not-block-the-thread.md)'s problem and it has the same answer it always had: Zig cannot take control back from code that is not asking to give it up.
