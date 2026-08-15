//! A WebSocket, from the handshake to the last frame (ADR 0022).
//!
//! `zig build run-chat`, then open http://localhost:8787/ in two tabs and
//! type in both. Or from a terminal:
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
/// zfast does the handshake, the frame headers, the masking, the pings and
/// the closing handshake. What is left is the loop.
fn chat(c: *zfast.Ctx, room: *Room) !void {
    var socket = try c.upgrade();
    const who = try room.join();
    defer room.leave(who);

    var line: [128]u8 = undefined;
    try socket.sendText(try std.fmt.bufPrint(&line, "you are guest {d}", .{who}));

    // This buffer is the message ceiling: one bigger than it closes the
    // connection with 1009 rather than growing anything. Ask for what you
    // can hold, which for a chat line is generous.
    var buf: [16 * 1024]u8 = undefined;
    while (try socket.receive(&buf)) |message| {
        // `live()` goes false when the server is stopping, so a deploy is
        // not held open by whoever is still typing (ADR 0020).
        if (!socket.live()) break;

        try room.remember(message.data);
        // Echoed as it arrived. `remember` keeps only as much as its little
        // buffer holds, and that is the room's business, not the reply's.
        try socket.send(message.kind, message.data);
    }

    // Reached when the other end closed, which zfast has already answered.
    // Saying so again is harmless and this is where a real one would tidy up.
    try socket.close(.normal, "");
}

/// A service with mutable state shared across every connection, so it needs
/// a `zfast.Mutex` — the one that parks the fiber rather than the OS thread
/// under it (ADR 0011).
const Room = struct {
    lock: zfast.Mutex = .{},
    next_guest: u32 = 1,
    here: u32 = 0,
    said: [256]u8 = undefined,
    said_len: usize = 0,

    fn join(self: *Room) !u32 {
        try self.lock.lock();
        defer self.lock.unlock();
        self.here += 1;
        self.next_guest += 1;
        return self.next_guest - 1;
    }

    fn leave(self: *Room, _: u32) void {
        // Only fails if the request was cancelled, and this one is already
        // on its way out.
        self.lock.lock() catch return;
        defer self.lock.unlock();
        self.here -= 1;
    }

    /// Keeps the last thing anybody said, up to what fits. A real chat would
    /// fan out to the other connections instead, which needs a way to write
    /// to a socket this handler does not own.
    ///
    /// The reason that is not here is now a number rather than a shrug: the
    /// only shape that works today gives every connection a second fiber, at
    /// 8,673 bytes each against a whole-connection budget of 8,767. ADR 0029
    /// has the measurement and what it is waiting on.
    fn remember(self: *Room, text: []const u8) !void {
        try self.lock.lock();
        defer self.lock.unlock();
        self.said_len = @min(text.len, self.said.len);
        @memcpy(self.said[0..self.said_len], text[0..self.said_len]);
    }
};

fn page() []const u8 {
    return
        \\<!doctype html>
        \\<title>zfast chat</title>
        \\<style>body{font:16px/1.6 ui-monospace,monospace;padding:2rem}
        \\input{font:inherit;width:20rem}</style>
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

    var room = Room{};
    try app.provide(&room);

    try app.use(zfast.logger.standard);
    try app.get("/", page);
    try app.get("/ws", chat);

    try app.listen(.{});
}

// ---- tests ----

const testing = std.testing;

test "the handshake is answered and a message comes back" {
    var app = zfast.App.init(testing.allocator);
    defer app.deinit();
    var room = Room{};
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

    // The greeting, then the echo. Neither is masked: a server never masks.
    try testing.expectEqualStrings("\x81\x0fyou are guest 1\x81\x05Hello", answer.body);
}

test "the room hands out a guest number to each arrival" {
    var room = Room{};
    try testing.expectEqual(@as(u32, 1), try room.join());
    try testing.expectEqual(@as(u32, 2), try room.join());
    room.leave(1);
    try testing.expectEqual(@as(u32, 1), room.here);
}
