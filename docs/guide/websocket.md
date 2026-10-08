# WebSocket

**A WebSocket handler is an ordinary handler that hands the connection to a loop function and returns; nilo does the protocol work.**

**Reference:** [`c.upgrade`](../reference/ctx.md#answering), [`Socket`](../reference/streaming.md#socket), [`Room`](../reference/streaming.md#room), [`Rooms`](../reference/streaming.md#rooms) · **Design:** [WebSockets](../design/websocket.md)

## Upgrading a request

A WebSocket handler takes services by type, sits behind the same middleware, and is registered with `app.get` like everything else. What it does differently is hand the connection to a loop and return:

```zig
fn echo(c: *nilo.Ctx) !void {
    return c.upgrade(echoLoop, {});
}

fn echoLoop(socket: *nilo.Socket) !void {
    while (try socket.receive()) |message| {
        try socket.send(message.kind, message.data);
    }
}

try app.get("/ws", echo);
```

nilo does the handshake, the frame headers, the masking, the reassembly of fragments and the closing handshake. Ping and pong are answered inside `receive`, so a handler never writes those branches.

[`c.upgrade()`](../reference/ctx.md#answering) fails with a 400 if the request is not a WebSocket handshake, so a browser that lands on the URL gets an answer instead of a dropped connection. `c.upgradeWith(loop, state, .{ .protocols = &.{ "chat.v2", "chat.v1" } })` names the subprotocols the route speaks, and the answer is the first one the client offered, or none: a browser fails a connection whose answer names a protocol it did not offer, so `.protocol = "chat.v1"` (one name) is answered only to a client that asked for it. A `Sec-WebSocket-Key` that is not 16 bytes of base64 is a 400.

### Why the loop is a separate function

**Returning from the handler before the loop starts cuts the memory an idle socket holds from 9,290 bytes to 5,183** ([ADR 062](../adr/062-where-a-connection-waits-is-what-it-costs.md)). A suspended fiber keeps its stack, so where a socket waits decides what it costs while it waits. A handler that looped in place would stay parked *inside* the request for as long as the tab is open, holding the `Ctx`, the parsed head and the route match, none of which the loop can use. Returning first lets all of that unwind. The compiler enforces this: a `*nilo.Ctx` passed as the state, or inside it, is rejected, so take what the loop needs out of the Ctx before `upgrade`.

### Passing state into the loop

**The second argument to `upgrade` is whatever the handler knows and the loop needs.** Services are the common case, and they arrive the same way they do anywhere:

```zig
fn chat(c: *nilo.Ctx, room: *nilo.Room) !void {
    return c.upgrade(chatLoop, room);
}

fn chatLoop(socket: *nilo.Socket, room: *nilo.Room) !void { … }
```

Anything else works the same way: a `Str` from the query, a number from the path. It travels in the connection's own frame, so it is **128 bytes at most**. A bigger struct goes in `c.arena()`, which stays alive as long as the loop does, and you pass a pointer to it. The compiler tells you when the state is too big instead of truncating anything. Pass `{}` when there is nothing to carry.

## The message loop

| | |
|---|---|
| `socket.receive()` | the next message, or `null` when the conversation is over |
| `socket.send(kind, data)` | one message, `.text` or `.binary` |
| `socket.sendText(text)` / `sendBinary(bytes)` | the shorthands |
| `socket.print(fmt, args)` | one text message, formatted |
| `socket.json(value)` | one text message, serialised |
| `socket.ping(data)` | for a proxy that drops quiet connections |
| `socket.close(.normal, "")` | close, saying why. Safe to call twice |
| `socket.closedCleanly()` | whether the other end said goodbye |
| `socket.live()` | false once the server is stopping, the same as a stream's |

**`receive` takes no buffer, and that is a memory decision rather than a convenience.** A message's bytes live in a buffer the executor lends this socket while the message is arriving and takes back when the conversation goes quiet. So a process holds one buffer per message *in flight*, not one per open socket. On the workload WebSockets are for (ten thousand chat tabs with four people typing), those numbers differ by three orders of magnitude.

The size limit is `upgradeWith(loop, state, .{ .max_message = … })` and defaults to 16 KiB. A frame announcing more than that is rejected with a `1009` before any byte of its payload is read. Nothing is allocated per message, and no byte of a message is copied twice ([ADR 046](../adr/046-a-message-is-copied-once-and-framed-once.md)).

**`receive` returns `null` in three cases, and all three end the loop the same way:** the client closed politely; the client vanished (a tab closed, a network dropped); or the server is stopping, in which case nilo has already told the client so with a `1001`. None of them is an error you need a branch for, and **a message loop needs no shutdown check of its own**. `socket.closedCleanly()` tells the first case apart from the others afterwards:

```zig
while (try socket.receive()) |message| { … }
if (!socket.closedCleanly()) std.log.info("client vanished", .{});
```

`live()` is still there for a handler that does its *own* work between messages (a long computation, a timer, a queue it drains), which nilo cannot see and so cannot end for you. Sending on a socket that has already closed writes nothing instead of failing: the other end closing between two of your sends is not a bug you can prevent, so you do not have to branch on it.

## Formatted messages (`print` and `json`)

**`print` and `json` write straight onto the wire, so a formatted message needs no stack buffer whose size you have to guess:**

```zig
try socket.print("welcome, {d} here", .{room.count()});
try socket.json(.{ .kind = "joined", .who = name, .here = room.count() });
```

Neither allocates. Both run the format twice, once to size the frame header and once to write the bytes, because a frame states its length before its bytes and there is nowhere to hold them in between that is not an allocation or a guessed buffer. Pass values, not a view of memory that another fiber is writing, and the two passes agree.

`nilo.Room` has the same pair, and there they cost nothing extra: the message is formatted into the allocation `say` was going to make anyway.

## Closing

**Anything that breaks the protocol is closed with the correct close code before the error comes back**, because a connection dropped without a close frame looks like a crash to the other end. An unmasked frame or a reserved bit gets `1002`, text that is not valid UTF-8 gets `1007`, and a message that is too big gets `1009`.

That includes a close frame that is itself broken. A close frame carrying a single byte, a code nobody assigned, or a reason that is not UTF-8 gets a `1002` instead of being echoed back, since echoing it would put the same broken frame on the wire again. Your own reason is cut on a character boundary if it is longer than the 123 bytes a close frame can hold, so it never goes out as half a character.

Your own reasons go through `close`:

```zig
if (!members.allows(user)) return socket.close(.policy, "not a member");
```

The codes are `.normal`, `.going_away`, `.protocol_error`, `.unsupported`, `.invalid_payload`, `.policy`, `.too_big`, `.internal`, or a number of your own.

## Shared state

**A socket handler takes services by type like any other handler, so anything the connections share is an ordinary service:**

```zig
const Transcript = struct {
    lock: nilo.Mutex = .init,
    messages: std.ArrayList([]u8) = .empty,
};

fn chat(c: *nilo.Ctx, transcript: *Transcript) !void { … }
```

Use `nilo.Mutex`, not `std.Thread.Mutex`; see [Services](./services.md).

That is for state of your own. Do not build a way to reach the *other connections* on top of it yourself; use a room, below.

## Broadcasting with `nilo.Room`

**[`nilo.Room`](../reference/streaming.md#room) sends a message to every socket in it.** It is a service like any other: provide one, take it by type, `join` on the way in and `defer leave` on the way out.

```zig
var room = try nilo.Room.init(gpa);
defer room.deinit();
try app.provide(&room);

fn chat(c: *nilo.Ctx, room: *nilo.Room) !void {
    return c.upgrade(chatLoop, room);
}

fn chatLoop(socket: *nilo.Socket, room: *nilo.Room) !void {
    try room.join(socket);
    defer room.leave(socket);

    while (try socket.receive()) |message| {
        try room.say(message.kind, message.data);
    }
}
```

That loop is the same one an echo server writes. Nothing in it mentions the other connections, and nothing handles an incoming broadcast: `receive` writes those out as it goes, from the fiber that owns the socket. The rest of the API is in [the reference](../reference/streaming.md#room). `defer room.leave(socket)` is not optional: Zig has no destructors, and a seat nobody gives up is one the next connection cannot have.

**A socket can be in more than one room**, and the one `receive` call drains all of them. For example, a lobby everybody hears and a room for one user's open tabs, each joined and each with its own `defer leave`. A second room costs a seat in that room and nothing on the connection. **A room can also hold event streams beside the sockets**: a read-only page can listen with `EventSource` to the same room a chat writes into, through [`c.eventsFrom`](./streaming.md#event-streams-fed-by-a-room).

**Size the room for the largest crowd it might hold.** `join` and `say` both cost what the room currently *holds*, not what it was sized for, so a thousand extra empty seats cost memory and nothing else. A `say` into an empty room does not even allocate ([ADR 046](../adr/046-a-message-is-copied-once-and-framed-once.md)).

**Why a room is not a lock around a loop**, which is worth knowing before you write one in your own code. A connection's write buffer belongs to the fiber serving it, so two fibers writing into it interleave frames: a corrupt stream, not just a slow one. A lock per socket fixes that and nothing else. The broadcast is then done by the *speaker's* fiber, which walks the connections, reaches one whose client has stopped reading, and blocks there. It never gets back to reading its own socket, so everybody's messages stop because one client stopped. This was measured with two healthy clients talking to each other and one stuck client in the same room: their messages never arrived at all, with a lock of either granularity.

So `say` does not write. It rings a bell on each seat, and each connection's own fiber does the writing. That is why one client that stops reading affects only that client, and why a full backlog is handled by a policy set on the room (`.drop_oldest` by default, or `.drop_newest`, with `room.missed(&socket)` reporting how many were dropped) rather than by disconnecting ([ADR 035](../adr/035-a-broadcast-rings-a-bell-it-does-not-write.md)). It adds 4 measured bytes per idle connection. The earlier design needed a second fiber per connection, costing 8,673 bytes against a per-connection budget that was 8,767 at the time, which is what kept this feature off the list for two stages ([ADR 028](../adr/028-a-spawned-fiber-belongs-to-the-server.md)).

**A room belongs to one process.** A message said on one instance reaches only the sockets joined on that instance, so a chat served from two instances is two chats, and nothing says so at run time ([ADR 110](../adr/110-an-in-process-cache-and-a-redis-client-are-two-modules.md)). Serve a room from one instance until a bridge between instances exists.

That work also produced [`nilo.spawn`](../reference/app.md#concurrency), for work that is not a request at all.

## Reaching one user on every tab (`nilo.Rooms`)

**To reach one user wherever they are connected, use [`nilo.Rooms`](../reference/streaming.md#rooms) instead of creating a room per user by hand.** `nilo.Rooms` is a pool of rooms created at startup, each lent to a key you choose for as long as somebody is joined under it:

<!-- compiles -->
```zig
fn inbox(c: *nilo.Ctx, rooms: *nilo.Rooms, me: *const Me) !void {
    return c.upgrade(inboxLoop, Where{ .rooms = rooms, .user = me.id });
}

fn inboxLoop(socket: *nilo.Socket, where: Where) !void {
    var buf: [32]u8 = undefined;
    const key = try std.fmt.bufPrint(&buf, "user:{d}", .{where.user});
    try where.rooms.join(key, socket);
    defer where.rooms.leave(key, socket);

    while (try socket.receive()) |_| {}
}

fn notify(rooms: *nilo.Rooms, user: u64) !void {
    var buf: [32]u8 = undefined;
    try rooms.json(try std.fmt.bufPrint(&buf, "user:{d}", .{user}), .{ .unread = 1 });
}

const Me = struct { id: u64 };
const Where = struct { rooms: *nilo.Rooms, user: u64 };
```

Every tab the user opens joins the same key, and a `json` into that key reaches all of them. A `json` into a key nobody is under does nothing and allocates nothing. The last tab to close gives the room back to the pool. `nilo.Rooms.initWith(gpa, .{ .rooms = …, .seats = … })` is the whole cost, allocated up front: when every room is lent out, a new key gets `error.NoRoomFree` instead of more memory ([ADR 228](../adr/228-a-room-for-a-key-is-lent-from-a-pool.md)). The same key works for an event stream: `c.eventsFrom(rooms.named(key), .{})`.

## Sending on a schedule

**For a clock, a price feed or a heartbeat of your own, run a fiber the server owns that writes into the room every so often.** Nothing extra is needed, because a room is a service and [background work](./background.md) can hold one:

<!-- compiles -->
```zig
fn tick(room: *nilo.Room) void {
    var n: u64 = 0;
    while (true) {
        nilo.sleep(1_000) catch return; // Canceled: the server is going
        n += 1;
        room.print("tick {d}", .{n}) catch {};
    }
}

fn start(app: *nilo.App, room: *nilo.Room) !void {
    try app.spawn(tick, .{room});
}
```

For an empty room, the tick costs nothing but the check.

## Idle connections and pings

**There is no read deadline, and there should not be: a socket is allowed to sit quiet.** A chat tab with nobody typing is working correctly, and closing it after thirty seconds would mean the framework breaking a working connection. What catches a client that vanished without a FIN is `.idle_ms`, and it sends a ping rather than enforcing a deadline. After a quiet period, nilo pings to ask whether the client is still there. An answer buys another period; a client that misses the next one is closed with `1001`.

```zig
// 30s by default, 0 waits forever
return c.upgradeWith(chatLoop, room, .{ .idle_ms = 60_000 });
```

At thirty seconds, a dead connection takes about a minute to notice, and a live one costs two frames a minute. Proxies that drop quiet connections usually do so at sixty seconds ([ADR 022](../adr/022-a-deadline-belongs-to-an-operation-not-to-a-request.md)).

## Origin check

**A browser applies no CORS to a WebSocket, so nilo checks the origin itself.** The browser sends no preflight and ignores `Access-Control-Allow-Origin`, so a `cors.with(…)` in front of an upgrade route sets headers nobody enforces. The handshake is an ordinary GET, so it arrives carrying the session cookie. Without a check here, a page on any origin could open your users' sockets and read and write them for as long as its tab was open, and no browser step would stop it.

So by default only your own pages may connect: a handshake whose `Origin` does not name the same authority as its `Host` gets a 403. There is nothing to write for the ordinary case, where the page and the socket are served by the same server.

```zig
// the page is on another host to the socket
return c.upgradeWith(chatLoop, room, .{ .origins = &.{"https://app.example.com"} });
// a public socket, carrying nothing worth stealing
return c.upgradeWith(feedLoop, {}, .{ .origins = &.{"*"} });
```

The scheme is not compared, because TLS is terminated in front and nilo never learns which one the browser used. A request with **no** `Origin` is allowed, because it is not from a browser and has no ambient cookie to borrow. `curl`, `wstest` and every native client send none ([ADR 080](../adr/080-a-websocket-handshake-is-same-origin-unless-the-route-says-otherwise.md)).

## Testing

**Use `testing.Conversation` to drive a WebSocket route from a test.** A handler that upgrades never returns a value, so there is nothing for `testing.Client` to read. [`testing.Conversation`](../reference/testing.md#testing) queues the frames a client would send, runs the handshake and the loop, and returns what the server sent ([ADR 091](../adr/091-a-websocket-route-can-be-driven-from-a-test.md)):

```zig
test "the chat echoes what it is told" {
    var app = nilo.App.init(testing.allocator);
    defer app.deinit();
    try app.get("/chat", chat);

    var talking: nilo.testing.Conversation = try .init(testing.allocator, .{});
    defer talking.deinit();

    try talking.text("hello");
    try talking.close(1000, "bye");

    const talk = try talking.open(&app, "/chat");
    try testing.expect(talk.accepted());
    try testing.expectEqualStrings("hello", talk.at(0).?.bytes);
    try testing.expectEqual(@as(u16, 1000), talk.closedWith().?);
}
```

You can send `text`, `binary`, `ping`, `pong`, `close`, `fragments` and `raw`. `talk.at(n)`, `talk.first(.pong)` and `talk.closedWith()` read what came back. `setHeader` puts an `Origin` or a cookie on the handshake, which is how the [origin check](#origin-check) is tested.

**The frames are queued before the server runs**, so a test cannot read what the server said and then decide what to send next. A conversation between two sockets, which is what a [Room](#broadcasting-with-niloroom) is, needs two connections and cannot be driven from here at all.

## What is not supported

**`permessage-deflate` is not supported.** It is negotiated in the handshake, and a compressor per connection needs a 64 KB window against a per-connection budget of 4,669 bytes, so it needs a design rather than a switch.

One number to know before a chat server meets its users: an open socket is an open connection, and `max_connections` limits those to 10,000 by default. A tab that is connected and silent still counts. Raise the limit (and multiply by the 5,183 bytes an idle WebSocket costs) before it becomes the limit you discover in production ([Deploying](./deploying.md#how-many-connections-at-once)).

`zig build run-chat` is a working example, browser page included.
