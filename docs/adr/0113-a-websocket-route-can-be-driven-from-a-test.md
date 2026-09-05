# A WebSocket route can be driven from a test

`testing.Client` drives a request into an App and reads the answer
([ADR 0108](./0108-the-test-client-can-do-what-a-client-does.md)). A WebSocket
handler has no answer to read: it upgrades, and then reads frames until they
stop. So there was no way to test one through the public API at all, and nilo's
own suite tested the largest and most intricate file in the repository —
`websocket.zig`, 2,122 lines — by writing masked frames as hex escapes into a
buffer and indexing into the response:

```zig
const frame = "\x81\x85\x37\xfa\x21\x3d\x7f\x9f\x4d\x51\x58"; // "Hello"
const result = h.send(&app, upgrade_request ++ frame);
const after_head = std.mem.indexOf(u8, result.response, "\r\n\r\n").? + 4;
try testing.expectEqualStrings("\x81\x05Hello", result.response[after_head..]);
```

**`testing.Conversation` queues frames, runs the handshake and the loop, and
hands back what the server said, decoded.**

```zig
var chat: nilo.testing.Conversation = try .init(testing.allocator, .{});
defer chat.deinit();

try chat.text("hello");
try chat.close(1000, "bye");

const talk = try chat.open(&app, "/chat");
try testing.expectEqualStrings("hello", talk.at(0).?.bytes);
try testing.expectEqual(@as(u16, 1000), talk.closedWith().?);
```

## Scripted, not interactive, and that is the design

The roadmap asked for "a reader the test drives turn by turn". This is not
quite that: the frames are queued before `open` runs, so a test cannot read
what the server said and *then* decide what to send.

Making it interactive is possible — one thread, one synchronous call, so a
reader could call back into the test with what has been written so far — and it
was not built, because the cases that want it are the ones this cannot reach
anyway. **A conversation between two clients needs two connections**, and
`handleRequest` is one. So a Room broadcast, a chat between two sockets, and
anything where one socket's message is another's input stay untestable here;
they want the real server `http/live.zig` stands up.

What the scripted version does reach is everything one client can do to one
server, which is where the protocol lives: fragmentation, control frames
arriving mid-conversation, a close handshake, a frame over the ceiling, a frame
a client did not mask. Six of the seven tests written against it in
`testing.zig` are behaviours nothing in the suite could reach before, and one
of them — a ping answered with a pong — never reaches the handler at all,
because `receive` answers it on the way past.

## The decoder does not share code with the encoder

`websocket.zig` can frame a message and `testing.zig` writes its own decoder
for the same bytes. That is deliberate duplication: a decoder built from the
encoder's own helpers agrees with it by construction, which is the property
[ADR 0090](./0090-a-body-framed-twice-is-refused.md) says is not worth having.
A test using this asserts against an independent reading of the wire.

The masking is the same argument from the other side. A client **must** mask
(RFC 6455 §5.3) and a server must refuse a frame that is not masked, so
`Conversation` masks — with a fixed key, so a failing test shows the same bytes
twice — and `raw` exists for the test that wants to say something no client
library would.

## Where it lives

In `testing.zig`, exported, rather than as a helper inside `app.zig`'s test
block. The suite is not the only thing with WebSocket handlers to test: an
application with a `/chat` route has exactly the same problem and no way to
solve it, which is the same reason `testing.Client` is public.

## What it costs

Nothing at run time — `testing.zig` is not on any request path, and no part of
this compiles into a server. One arena and one response buffer per
`Conversation`, both freed by `deinit`, and the frames are built into a
`std.ArrayList` the conversation owns.
