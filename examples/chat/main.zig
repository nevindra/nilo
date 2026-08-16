//! A WebSocket that broadcasts: what one tab types, every tab sees.
//!
//! Two things are on show here, and the second one is the point. The first is
//! everything a WebSocket needs — the handshake, frame headers, masking,
//! pings, the closing handshake, a message ceiling, and shutdown that does not
//! hang on an idle typist (ADR 0022). The second is a `zfast.Room`: saying
//! something to sockets this handler does not hold, which was the honest limit
//! of 0.1.0 and is no longer.
//!
//! `zig build run-chat`, then open http://localhost:8787/ in two tabs. Or from
//! a terminal:
//!
//! ```
//! websocat ws://localhost:8787/ws
//! ```

const std = @import("std");
const zfast = @import("zfast");

pub const std_options = zfast.std_options;
pub const std_options_debug_io = zfast.debug_io;

/// One WebSocket connection, from a handler that looks like every other
/// handler: it takes what it needs and holds the connection until it ends.
///
/// The loop is the same one an echo server writes. Nothing in it mentions the
/// other connections, and nothing in it handles an incoming broadcast —
/// `receive` writes those out on the way past, from this fiber, because a
/// connection's bytes belong to the fiber serving it (ADR 0029).
fn chat(c: *zfast.Ctx, room: *zfast.Room) !void {
    var socket = try c.upgrade();

    // `join` takes a seat, `leave` gives it back. The `defer` is not optional
    // and not a nicety: Zig has no destructor, and a seat nobody gives up is
    // one the next connection cannot have. It is correct on every path out of
    // here, including the ones that fail before ever joining.
    try room.join(&socket);
    defer room.leave(&socket);

    var line: [64]u8 = undefined;
    try room.sayText(try std.fmt.bufPrint(&line, "welcome, {d} here", .{room.count()}));

    // This buffer is the message ceiling: one bigger than it closes the
    // connection with 1009 rather than growing anything. Ask for what you can
    // hold, which for a chat line is generous.
    var buf: [16 * 1024]u8 = undefined;
    while (try socket.receive(&buf)) |message| {
        // `live()` goes false when the server is stopping, so a deploy is not
        // held open by whoever is still typing (ADR 0020).
        if (!socket.live()) break;

        // To everybody, including whoever typed it. One code path, not one
        // for me and another for everyone else.
        try room.say(message.kind, message.data);
    }

    // Reached when the other end closed, which zfast has already answered.
    // Saying so again is harmless and this is where a real one would tidy up.
    try socket.close(.normal, "");
}

fn page() []const u8 {
    return
        \\<!doctype html>
        \\<title>zfast chat</title>
        \\<style>body{font:16px/1.6 ui-monospace,monospace;padding:2rem}
        \\input{font:inherit;width:20rem}
        \\p{color:#666;max-width:34rem}</style>
        \\<p>Open this page in a second tab. What you type here shows up there.</p>
        \\<pre id="log"></pre>
        \\<input id="say" placeholder="say something" autofocus>
        \\<script>
        \\  const log = document.getElementById("log");
        \\  const socket = new WebSocket(`ws://${location.host}/ws`);
        \\  socket.onmessage = e => { log.textContent += e.data + "\n" };
        \\  socket.onclose = () => { log.textContent += "(closed)\n" };
        \\  document.getElementById("say").addEventListener("keydown", e => {
        \\    if (e.key !== "Enter" || !e.target.value) return;
        \\    socket.send(e.target.value);
        \\    e.target.value = "";
        \\  });
        \\</script>
        \\
    ;
}

pub fn main() !void {
    var app = zfast.App.init(std.heap.smp_allocator);
    defer app.deinit();

    // A service with state shared across every connection, like any other —
    // `app.provide` and it arrives by type. What is different is only that
    // this one can reach connections other handlers are holding.
    var room = try zfast.Room.init(std.heap.smp_allocator);
    defer room.deinit();
    try app.provide(&room);

    try app.use(zfast.logger.standard);
    try app.get("/", page);
    try app.get("/ws", chat);

    try app.listen(.{});
}

// ---- tests ----

const testing = std.testing;

test "the handshake is answered and what arrives is broadcast" {
    var app = zfast.App.init(testing.allocator);
    defer app.deinit();
    var room = try zfast.Room.initWith(testing.allocator, .{ .seats = 4, .backlog = 4 });
    defer room.deinit();
    try app.provide(&room);
    try app.get("/ws", chat);

    var client = try zfast.testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    // The handshake and one masked text frame, "Hello", in one go.
    const answer = try client.send(&app, "GET /ws HTTP/1.1\r\nHost: x\r\n" ++
        "Upgrade: websocket\r\nConnection: Upgrade\r\n" ++
        "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n" ++
        "\x81\x85\x37\xfa\x21\x3d\x7f\x9f\x4d\x51\x58");

    try testing.expectEqual(@as(u16, 101), answer.status);
    try testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", answer.header("Sec-WebSocket-Accept").?);
    // A connection that has stopped being HTTP cannot carry another request.
    try testing.expect(!answer.keep_alive);

    // The greeting, then "Hello" coming back round through the room. Neither
    // is masked: a server never masks. Both arrive by the same route — this
    // connection's own `receive` writing out what the room posted to it,
    // which is exactly what a second tab would get.
    try testing.expectEqualStrings("\x81\x0fwelcome, 1 here\x81\x05Hello", answer.body);
}

test "a connection that has left the room is not written to" {
    var room = try zfast.Room.initWith(testing.allocator, .{ .seats = 2, .backlog = 2 });
    defer room.deinit();

    try testing.expectEqual(@as(usize, 0), room.count());
    // Nobody to hear it, and nothing leaked saying it.
    try room.sayText("anyone there?");
}
