# A WebSocket is a handler that does not return yet

Everything else in nilo answers a request. A WebSocket stops being a request: after the 101 the connection carries frames in both directions until somebody closes it, and none of HTTP applies any more.

The temptation is a shape of its own — a registration API, a set of callbacks, an object with `onMessage` and `onClose`. That is what most frameworks do, and it means a WebSocket handler is not a handler, cannot take a service, cannot take a resolved value, and cannot be read next to the routes around it.

So it is a handler:

```zig
fn chat(c: *nilo.Ctx, room: *Room) !void {
    var socket = try c.upgrade();
    var buf: [16 * 1024]u8 = undefined;
    while (try socket.receive(&buf)) |message| {
        try socket.send(message.kind, message.data);
    }
}
```

`app.get("/ws", chat)` registers it, `room` arrives by type like any service, a `CurrentUser` would arrive the same way, and the middleware in front of it runs exactly as it does for anything else. What is different is only that it does not return for a while — which ADR 0020 already had to have an answer for.

## The buffer is the limit, and there is only one

The first version had an `Options.max_message` alongside the buffer passed to `receive`. It was wrong, and the way it was found is the argument: a test client sent 70 KB, the option said a megabyte was fine, the buffer was 4 KB, and the connection closed with `1009` for no reason visible anywhere in the handler.

> **The buffer handed to `receive` is the message ceiling.** There is no second number.

A frame whose header announces more than the buffer holds is refused before a byte of its payload is read, so a client announcing four gigabytes costs four bytes to refuse. Fragments are reassembled into that same buffer and the total is checked as they arrive. Nothing is allocated — the connection's memory is the handler's `buf`, exactly as ADR 0020 requires of a body reader.

An option that can quietly contradict the code beside it is worse than no option.

## The protocol keeps itself alive, invisibly

Ping, pong and close are answered inside `receive`. A handler never sees them, because they are not messages — they are the protocol's own housekeeping, and every handler would write the same three branches.

That includes the closing handshake: a close frame is echoed before `receive` returns null, which is what stops a browser reporting an ordinary goodbye as an error. A control frame arriving in the middle of a fragmented message is handled without disturbing what has been collected, which is legal, happens, and is the kind of thing that only shows up under a real client.

## A client that vanishes is not an error

`receive` returns null both for a close frame and for a connection that simply stopped — a tab closed, a laptop lid shut, a network gone.

Making the second one an error would be more precise and worse: it is the *most common* way a WebSocket ends, and every handler in the world would open with a `catch` that treats it as normal. The loop shape should be the same for both, because what the handler does next is the same for both. `closedCleanly()` tells them apart afterwards, for the one handler in twenty that cares.

> **There is a third way now, and it is the same `null`** ([ADR 0052](./0052-a-message-is-copied-once-and-framed-once.md)). A server that has been asked to stop ends the conversation itself, with a 1001 to the client first. The argument is this section's, read once more: ADR 0020 says a handler that ignores the stopping flag holds the deploy open, and leaving that to `if (!socket.live()) break;` in every loop is a rule stated somewhere it cannot be enforced. The same reading runs the other way too — **sending on a socket that has already closed writes nothing rather than failing**, because the other end closing between two of a handler's sends is exactly as unpreventable as a client vanishing.

## What is refused, and why it is refused properly

Every refusal sends a close frame with the right code before returning the error, because a connection that is dropped without one looks to the other end like a crash:

| | |
|---|---|
| An unmasked frame from a client | `1002` — either a broken client or something that is not a client |
| A reserved bit set | `1002` — an extension nobody negotiated |
| A continuation with nothing to continue | `1002` |
| Text that is not valid UTF-8 | `1007`, not `1002` — the framing was fine, the payload was not |
| A message bigger than the buffer | `1009` |

> **One row was missing and its absence was worse than pedantry** ([ADR 0052](./0052-a-message-is-copied-once-and-framed-once.md)). A close frame carrying one byte, a code nobody assigned, or a reason that is not UTF-8 was *echoed* — so a server whose whole discipline here is "say goodbye properly" answered a broken goodbye by putting the same broken bytes back on the wire. It is a `1002` now, like every other framing error, and the reason nilo sends with a close of its own is cut on a character boundary rather than at the 123rd byte.

The UTF-8 check is the one that looks like pedantry and is not. Text frames are *defined* to be UTF-8; a handler that gets invalid bytes will pass them to something that breaks further away, where the cause is no longer visible.

## The thing this does not do: talking to a socket you do not hold

The chat example echoes. It does not broadcast, and that is the honest limit of what is here.

Sending to *other* connections needs a registry of live sockets and a way to write to one from a different fiber — and a connection's write buffer belongs to the fiber serving it, so a second fiber writing into it interleaves frames and corrupts the stream. Doing it properly means a per-socket outbox with its own lock, or a mailbox the owning fiber drains. That is Phoenix Channels, which ADR 0015 named as the shape to borrow, and it is a project rather than a function.

It is recorded here rather than half-built, because a broadcast that works in a test and interleaves under load is worse than one that does not exist.

> **This is no longer true, and [ADR 0038](./0038-a-broadcast-rings-a-bell-it-does-not-write.md) is how it stopped being.** A `nilo.Room` says things to sockets a handler does not hold, and the loop above is unchanged — `receive` writes out anything posted to this connection on its way past, so a handler still never sees a broadcast and never writes a branch for one. The registry is the Room's seats; the way to write to a socket from a different fiber is not to, which was the whole finding.
>
> **Both of the guesses below were wrong, and ADR 0029 has the measurements.** The interleaving is real and a lock per socket does fix it — and fixes nothing else, because the writing is done by the *speaker's* fiber, which then blocks on the first connection that has stopped reading. That is not a locking problem and no lock granularity touches it. The second guess, a mailbox the owning fiber drains, is the right shape and is not reachable: it needs a wait that ends on either the socket becoming readable or a post arriving, and zio exports no way to park a fiber on a completion. What did come out of that work is `nilo.spawn`.

Also not here: `permessage-deflate` (negotiated in the handshake, and a compressor per connection is memory nilo has not budgeted), and any deadline at all — a client that opens a socket and never speaks holds a fiber until TCP gives up. That last one is the same hole ADR 0020 recorded, and WebSocket makes it cheaper to exploit.

> **The hole is closed, by the answer this ADR already named.** `Options.idle_ms`, 30 seconds by default: silence sends a ping, and silence after an unanswered ping closes with 1001. Still not a deadline, for the reason given above — a quiet WebSocket is a working one, so the framework asks rather than assumes. What made it buildable was [ADR 0038](./0038-a-broadcast-rings-a-bell-it-does-not-write.md), which gave the connection a wait that can carry a limit; before that there was no way to time a WebSocket read without also breaking the quiet-is-fine promise. Set it to `0` for the old behaviour.

## Consequences

- The connection cannot carry another HTTP request, which nilo arranges: `upgrade()` sets the same flag an unframed HTTP/1.0 stream sets, and `keepAlive()` is false from then on. A handler only has to return.
- A handshake that is missing something is a 400 naming the missing part — `Upgrade`, `Connection`, `Sec-WebSocket-Version`, `Sec-WebSocket-Key` — rather than framing nobody can read. Getting this wrong by hand is the normal way to meet WebSocket for the first time.
- **The logger was reporting a status nobody sent.** A handler failing after its 101 was logged as `500`, because the logger asked the error what status it mapped to without asking whether an answer had already gone out. It now uses the sent status when there is one, which fixes the same wrongness for a stream that fails mid-body.
- 5 of the 8 statuses `Close` names are ones nilo sends itself. The enum is left open (`_`) because a handler is entitled to send a code of its own.
