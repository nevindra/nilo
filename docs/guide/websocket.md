# WebSocket

A WebSocket handler is a handler. It takes services by type, sits behind the same
middleware, and is registered with `app.get` like everything else — the only
difference is that it doesn't return for a while:

```zig
fn echo(c: *nilo.Ctx) !void {
    var socket = try c.upgrade();
    var buf: [16 * 1024]u8 = undefined;
    while (try socket.receive(&buf)) |message| {
        try socket.send(message.kind, message.data);
    }
}

try app.get("/ws", echo);
```

nilo does the handshake, the frame headers, the masking, the fragment
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
| `socket.print(fmt, args)` | one text message, formatted |
| `socket.json(value)` | one text message, serialised |
| `socket.ping(data)` | for a proxy that drops quiet connections |
| `socket.close(.normal, "")` | close, saying why — safe to call twice |
| `socket.closedCleanly()` | whether the other end said goodbye |
| `socket.live()` | false once the server is stopping, exactly as a stream's is |

**The buffer you pass to `receive` is the message ceiling** — there is no second
limit to contradict it. A frame announcing more than it holds is refused before a
byte of its payload is read, with a `1009`. Nothing is allocated per message, and
no byte of one is copied twice
([ADR 0052](../adr/0052-a-message-is-copied-once-and-framed-once.md)).

`receive` returns `null` three ways: the client closed politely, the client
vanished — a tab closed, a network gone — or the server is stopping, in which
case nilo has already told the client so with a `1001`. All three end the loop
the same way, so none of them is an error to write a branch for, and **a message
loop needs no shutdown check of its own**. `socket.closedCleanly()` tells the
first apart from the rest afterwards:

```zig
while (try socket.receive(&buf)) |message| { … }
if (!socket.closedCleanly()) std.log.info("client vanished", .{});
```

`live()` is still there for the handler doing work of its *own* between messages
— a long computation, a timer, a queue it drains — which nilo can't see and so
can't end on your behalf. Sending on a socket that has already closed writes
nothing rather than failing: the other end closing between two of your sends
isn't a bug you can prevent, so it isn't one you have to branch on.

## Saying something without a buffer of your own

`print` and `json` write straight onto the wire, so a formatted message doesn't
need a stack buffer you have to guess the size of:

```zig
try socket.print("welcome, {d} here", .{room.count()});
try socket.json(.{ .kind = "joined", .who = name, .here = room.count() });
```

Neither allocates. Both run the format twice — once to size the frame header,
once to write the bytes — because a frame states its length before its bytes and
there's nowhere to hold them meanwhile that isn't an allocation or a buffer you
guessed at. Pass values rather than a window onto memory another fiber is
writing, and the two passes agree.

`nilo.Room` has the same pair, and there they cost nothing extra at all: the
message is formatted into the allocation `say` was going to make anyway.

## Closing

Everything protocol-wrong is refused with the right close code before the error
comes back — an unmasked frame or a reserved bit is `1002`, text that isn't valid
UTF-8 is `1007`, too big is `1009` — because a connection dropped without a close
frame looks to the other end like a crash.

That includes a goodbye that isn't one. A close frame carrying a single byte, a
code nobody assigned, or a reason that isn't UTF-8 gets a `1002` rather than
being echoed back — echoing it would put the same broken frame on the wire
again. Your own reason is cut on a character boundary if it's longer than the
123 bytes a close frame has room for, so it never goes out as half a character.

Your own reasons go through `close`:

```zig
if (!members.allows(user)) return socket.close(.policy, "not a member");
```

`.normal`, `.going_away`, `.protocol_error`, `.unsupported`, `.invalid_payload`,
`.policy`, `.too_big`, `.internal`, or a number of your own.

## Shared state

A socket handler takes services by type like any other handler, so anything the
connections share is an ordinary service:

```zig
const Transcript = struct {
    lock: nilo.Mutex = .init,
    messages: std.ArrayList([]u8) = .empty,
};

fn chat(c: *nilo.Ctx, transcript: *Transcript) !void { … }
```

`nilo.Mutex`, not `std.Thread.Mutex` — see [Services](./services.md).

That is for state of your own. Reaching the *other connections* is not something
to hand-roll on top of it — see below.

## Sending to a socket you don't hold

`nilo.Room` is a service like any other: provide one, take it by type, `join` on
the way in and `defer leave` on the way out.

```zig
var room = try nilo.Room.init(gpa);
defer room.deinit();
try app.provide(&room);

fn chat(c: *nilo.Ctx, room: *nilo.Room) !void {
    var socket = try c.upgrade();
    try room.join(&socket);
    defer room.leave(&socket);

    var buf: [16 * 1024]u8 = undefined;
    while (try socket.receive(&buf)) |message| {
        try room.say(message.kind, message.data);
    }
}
```

That loop is the one an echo server writes. Nothing in it mentions the other
connections and nothing handles an incoming broadcast — `receive` writes those
out on the way past, from the fiber that owns the socket. The rest of the API is
in [the reference](../reference.md#room). `defer room.leave(&socket)` is the part
that isn't optional: Zig has no destructor, and a seat nobody gives up is one the
next connection can't have.

**Size the room for the crowd it might hold.** `join` and `say` both cost what
the room *holds* rather than what it was sized for, so an extra thousand empty
seats is a memory decision and nothing else — and a `say` into a room with
nobody in it doesn't even allocate
([ADR 0052](../adr/0052-a-message-is-copied-once-and-framed-once.md)).

**Why it isn't a lock around a loop**, which is worth knowing before you write
one in your own code. A connection's write buffer belongs to the fiber serving
it, so two fibers writing into it interleave frames — a corrupt stream rather
than a slow one. A lock per socket fixes that much and nothing else: the
broadcast is then performed by the *speaker's* fiber, which walks the
connections, reaches one whose client has stopped reading, and blocks there. It
never gets back to reading its own socket, so everybody's messages stop because
one client stopped. Measured, with two healthy clients wanting only to talk to
each other and one wedged client in the same room: their messages never arrived
at all, at either lock granularity.

So `say` doesn't write. It rings a bell on each seat, and the connection's own
fiber does the writing — which is why one client that stops reading costs that
client and nobody else, and why a full backlog is a policy named at the room
(`.drop_oldest` by default, or `.drop_newest`, with `room.missed(&socket)` saying
how many went) rather than a disconnect
([ADR 0038](../adr/0038-a-broadcast-rings-a-bell-it-does-not-write.md)). It adds
4 measured bytes per idle connection. The design that needed a second fiber per
connection was 8,673 against a budget of 8,767, which is what kept this off the
list for two stages ([ADR 0029](../adr/0029-a-spawned-fiber-belongs-to-the-server.md)).

What else came out of that work is [`nilo.spawn`](../reference.md#concurrency),
for work that is not a request at all.

## A connection that goes quiet

There is no read deadline, and there shouldn't be: a socket is *allowed* to sit
quiet — a chat tab with nobody typing is working correctly, and closing it after
thirty seconds would be a framework breaking a working connection. What catches a
client that vanished without a FIN is `.idle_ms`, and it's a ping rather than a
deadline. Silence asks whether the client is still there; an answer buys another
stretch; a client that misses the next one is closed with `1001`.

```zig
var socket = try c.upgradeWith(.{ .idle_ms = 60_000 });  // 30s by default, 0 waits forever
```

Thirty seconds costs a dead connection about a minute to notice and a live one
two frames a minute. Proxies that drop quiet connections usually do so at sixty
([ADR 0023](../adr/0023-a-deadline-belongs-to-an-operation-not-to-a-request.md)).

## What isn't here

`permessage-deflate`. It's negotiated in the handshake, and a compressor per
connection is a 64 KB window against a budget of 8,767 bytes — so it needs a
design rather than a switch.

One number worth knowing before a chat server meets its users: an open socket is
an open connection, and `max_connections` bounds those at 10,000 by default. A
tab that is connected and silent still counts. Raise it — and multiply by the
9 KB a connection costs — before that is the limit you find out about
([Deploying](./deploying.md#how-many-connections-at-once)).

`zig build run-chat` is a working one, browser page included.
