# WebSocket

A WebSocket handler is a handler. It takes services by type, sits behind the same
middleware, and is registered with `app.get` like everything else — the only
difference is that it doesn't return for a while:

```zig
fn chat(c: *zfast.Ctx, room: *Room) !void {
    var socket = try c.upgrade();
    var buf: [16 * 1024]u8 = undefined;
    while (try socket.receive(&buf)) |message| {
        try socket.send(message.kind, message.data);
    }
}

try app.get("/ws", chat);
```

zfast does the handshake, the frame headers, the masking, the fragment
reassembly and the closing handshake. Ping and pong are answered inside
`receive`, so a handler never writes those three branches.

`c.upgrade()` fails with a 400 if the request isn't a WebSocket handshake, so a
browser that wandered onto the URL gets told rather than hung up on.
`c.upgradeWith(.{ .protocol = "chat.v1" })` names a subprotocol.

## The message loop

| | |
|---|---|
| `socket.receive(&buf)` | the next message, or `null` when it's over |
| `socket.send(kind, data)` | one message, `.text` or `.binary` |
| `socket.sendText(text)` / `sendBinary(bytes)` | the shorthands |
| `socket.ping(data)` | for a proxy that drops quiet connections |
| `socket.close(.normal, "")` | close, saying why — safe to call twice |
| `socket.closedCleanly()` | whether the other end said goodbye |
| `socket.live()` | false once the server is stopping, exactly as a stream's is |

**The buffer you pass to `receive` is the message ceiling** — there is no second
limit to contradict it. A frame announcing more than it holds is refused before a
byte of its payload is read, with a `1009`. Nothing is allocated per message.

`receive` returns `null` both when the client closes politely and when it simply
vanishes — a tab closed, a network gone. That's the most common way a WebSocket
ends, so it isn't an error to write a branch for; `socket.closedCleanly()` tells
them apart afterwards:

```zig
while (try socket.receive(&buf)) |message| { … }
if (!socket.closedCleanly()) std.log.info("client vanished", .{});
```

## Closing

Everything protocol-wrong is refused with the right close code before the error
comes back — an unmasked frame or a reserved bit is `1002`, text that isn't valid
UTF-8 is `1007`, too big is `1009` — because a connection dropped without a close
frame looks to the other end like a crash.

Your own reasons go through `close`:

```zig
if (!room.allows(user)) return socket.close(.policy, "not a member");
```

`.normal`, `.going_away`, `.protocol_error`, `.unsupported`, `.invalid_payload`,
`.policy`, `.too_big`, `.internal`, or a number of your own.

## Shared state

A socket handler is the natural place to want other people's messages, and the
usual shape is a service holding the room:

```zig
const Room = struct {
    lock: zfast.Mutex = .init,
    history: std.ArrayList([]u8) = .empty,
};

fn chat(c: *zfast.Ctx, room: *Room) !void { … }
```

`zfast.Mutex`, not `std.Thread.Mutex` — see [Services](./services.md).

## What isn't here

**Sending to a socket you don't hold.** A connection's write buffer belongs to
the fiber serving it, so two fibers writing into it interleave frames — a corrupt
stream rather than a slow one. A lock per socket fixes that much.

It fixes nothing else, and this is worth knowing before you try it in your own
code. The broadcast is performed by the *speaker's* fiber: it walks the
connections, reaches one whose client has stopped reading, and blocks there. It
never gets back to reading its own socket, so everybody's messages stop because
one client stopped. Measured, with two healthy clients wanting only to talk to
each other and one wedged client in the same room: their messages never arrived
at all, at either lock granularity.

The write has to be done by something whose stalling costs only the slow
connection — which today means a second fiber per connection, at 8,673 bytes
each against a per-connection budget of 8,767. So it is not here, and
[ADR 0029](../adr/0029-a-spawned-fiber-belongs-to-the-server.md) records both the
number and the one upstream change that would remove it.

What did come out of that work is [`zfast.spawn`](../reference.md#concurrency),
for work that is not a request at all.

Also absent: `permessage-deflate`, and any read deadline. A socket is allowed to
sit quiet — a chat tab with nobody typing is working correctly — so what catches
a client that vanished is the write limit, on the next thing the server sends it.
A ping it fails to answer is what would catch one nobody writes to, and that is a
feature this doesn't have yet
([ADR 0023](../adr/0023-a-deadline-belongs-to-an-operation-not-to-a-request.md)).

One number worth knowing before a chat server meets its users: an open socket is
an open connection, and `max_connections` bounds those at 10,000 by default. A
tab that is connected and silent still counts. Raise it — and multiply by the
9 KB a connection costs — before that is the limit you find out about
([Deploying](./deploying.md#how-many-connections-at-once)).

`zig build run-chat` is a working one, browser page included.
