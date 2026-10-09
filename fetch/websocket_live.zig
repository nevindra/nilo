//! The client's tests: a real `WebSocket` against a canned server over a real
//! loopback socket, on `std.Io.Threaded` and no Engine, as `live.zig` is the
//! rest of the module's (ADR 061, ADR 281).
//!
//! Every wait is bounded and every server is started with `io.concurrent`
//! (ADR 056). The server in `fetch.testing.Canned.serveWebSocket` is a script
//! of frames to send and frames to read, so a test says what the far end does
//! and reads back what it saw; the framing under both ends is `core.ws_frame`,
//! which has its own table, so what these check is the conversation.
//!
//! The same client against nilo's own server is `deadline.zig`'s, because
//! that names `nilo_http`.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("nilo_core");
const fetch = @import("fetch.zig");

const testing = std.testing;
const Canned = fetch.testing.Canned;
const WebSocket = fetch.WebSocket;

fn withIo(comptime body: fn (std.Io) anyerror!void) !void {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    try body(threaded.io());
}

fn started(io: std.Io, settings: fetch.Client.Settings) !fetch.Client {
    var client: fetch.Client = .init(testing.allocator, settings);
    try client.nilo_start(io, .none);
    return client;
}

fn carries(head: []const u8, line: []const u8) bool {
    return std.ascii.findIgnoreCase(head, line) != null;
}

test "a message goes out masked, and the answer comes back, and the close is acknowledged" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            const steps = [_]fetch.testing.WsStep{
                .read, // hello
                .{ .send = .{ .payload = "HELLO" } },
                .{ .send = .{ .opcode = 2, .payload = "\x01\x02\x03" } },
                .read, // the close
                .{ .send = .{ .opcode = 8, .payload = "\x03\xe8" } },
            };
            var served = try io.concurrent(Canned.serveWebSocket, .{ &canned, &steps });
            defer served.cancel(io) catch {};

            var client = try started(io, .{});
            defer client.deinit();
            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            var buf: [64]u8 = undefined;
            var ws: WebSocket = .idle;
            defer ws.deinit();
            try ws.open(&client, &scope, try canned.wsUrl(&buf), .{
                .headers = &.{.{ .name = "X-Token", .value = "abc" }},
            });
            try testing.expectEqual(@as(u16, 101), ws.status);
            try testing.expect(ws.isOpen());

            try ws.sendText("hello");
            const text = (try ws.receive()).?;
            try testing.expectEqual(fetch.websocket.Kind.text, text.kind);
            try testing.expectEqualStrings("HELLO", text.data);
            const binary = (try ws.receive()).?;
            try testing.expectEqual(fetch.websocket.Kind.binary, binary.kind);
            try testing.expectEqualSlices(u8, "\x01\x02\x03", binary.data);

            try testing.expectEqual(fetch.websocket.Closed.acknowledged, ws.close(.normal, "bye"));
            served.await(io) catch {};

            // The request that asked for the upgrade.
            const head = canned.request();
            try testing.expect(std.mem.startsWith(u8, head, "GET /feed HTTP/1.1"));
            try testing.expect(carries(head, "upgrade: websocket"));
            try testing.expect(carries(head, "connection: upgrade"));
            try testing.expect(carries(head, "sec-websocket-version: 13"));
            try testing.expect(carries(head, "sec-websocket-key: "));
            try testing.expect(carries(head, "x-token: abc"));

            // What the server read: both frames masked, the close carrying the
            // code and the reason.
            const seen = &canned.ws_seen;
            try testing.expectEqual(@as(usize, 2), seen.count);
            try testing.expect(seen.masked[0] and seen.masked[1]);
            try testing.expectEqual(@as(u8, 1), seen.opcode[0]);
            try testing.expectEqualStrings("hello", seen.payloadOf(0));
            try testing.expectEqual(@as(u8, 8), seen.opcode[1]);
            try testing.expectEqualSlices(u8, "\x03\xe8bye", seen.payloadOf(1));
        }
    }.run);
}

test "every frame a client sends has a mask of its own" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            const steps = [_]fetch.testing.WsStep{ .read, .read, .read, .hold_until_closed };
            var served = try io.concurrent(Canned.serveWebSocket, .{ &canned, &steps });
            defer served.cancel(io) catch {};

            var client = try started(io, .{});
            defer client.deinit();
            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();
            var buf: [64]u8 = undefined;
            var ws: WebSocket = .idle;
            defer ws.deinit();
            try ws.open(&client, &scope, try canned.wsUrl(&buf), .{ .close_timeout_ms = 2_000 });

            // The same payload three times, the last one longer than the
            // connection's write buffer, so the masking runs in pieces.
            const big = try testing.allocator.alloc(u8, 20_000);
            defer testing.allocator.free(big);
            for (big, 0..) |*b, i| b.* = @truncate(i *% 7);
            try ws.sendBinary("same");
            try ws.sendBinary("same");
            try ws.sendBinary(big);
            _ = ws.close(.normal, "");
            served.await(io) catch {};

            const seen = &canned.ws_seen;
            try testing.expect(seen.count >= 3);
            try testing.expect(!std.mem.eql(u8, &seen.mask[0], &seen.mask[1]));
            try testing.expect(!std.mem.eql(u8, &seen.mask[1], &seen.mask[2]));
            try testing.expectEqual(@as(u64, 20_000), seen.len[2]);
            // Unmasked by the server's reader, the first 128 bytes are the
            // caller's.
            try testing.expectEqualSlices(u8, big[0..128], seen.payloadOf(2));
        }
    }.run);
}

test "a message in fragments, with a ping between them, arrives whole and the ping is answered" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            const steps = [_]fetch.testing.WsStep{
                .{ .send = .{ .payload = "hel", .fin = false } },
                .{ .send = .{ .opcode = 9, .payload = "tag" } },
                .{ .send = .{ .opcode = 0, .payload = "lo" } },
                .read, // the pong
            };
            var served = try io.concurrent(Canned.serveWebSocket, .{ &canned, &steps });
            defer served.cancel(io) catch {};

            var client = try started(io, .{});
            defer client.deinit();
            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();
            var buf: [64]u8 = undefined;
            var ws: WebSocket = .idle;
            defer ws.deinit();
            try ws.open(&client, &scope, try canned.wsUrl(&buf), .{});

            const message = (try ws.receive()).?;
            try testing.expectEqual(fetch.websocket.Kind.text, message.kind);
            try testing.expectEqualStrings("hello", message.data);
            served.await(io) catch {};

            // The caller never saw the ping, and the server heard its own
            // tag back, masked.
            const seen = &canned.ws_seen;
            try testing.expectEqual(@as(usize, 1), seen.count);
            try testing.expectEqual(@as(u8, 10), seen.opcode[0]);
            try testing.expect(seen.masked[0]);
            try testing.expectEqualStrings("tag", seen.payloadOf(0));
        }
    }.run);
}

test "a message bigger than the read buffer is collected and comes back whole" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            const big = try testing.allocator.alloc(u8, 30_000);
            defer testing.allocator.free(big);
            for (big, 0..) |*b, i| b.* = @truncate('a' + i % 26);

            var canned = try Canned.open(io);
            defer canned.close();
            const steps = [_]fetch.testing.WsStep{
                .{ .send = .{ .payload = big } },
                // And one in three pieces, each past the buffer.
                .{ .send = .{ .payload = big[0..10_000], .fin = false } },
                .{ .send = .{ .opcode = 0, .payload = big[10_000..20_000], .fin = false } },
                .{ .send = .{ .opcode = 0, .payload = big[20_000..] } },
            };
            var served = try io.concurrent(Canned.serveWebSocket, .{ &canned, &steps });
            defer served.cancel(io) catch {};

            var client = try started(io, .{});
            defer client.deinit();
            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();
            var buf: [64]u8 = undefined;
            var ws: WebSocket = .idle;
            defer ws.deinit();
            try ws.open(&client, &scope, try canned.wsUrl(&buf), .{});

            try testing.expectEqualStrings(big, (try ws.receive()).?.data);
            try testing.expectEqualStrings(big, (try ws.receive()).?.data);
        }
    }.run);
}

test "a message over the limit is refused on its header and the connection is closed with 1009" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            const steps = [_]fetch.testing.WsStep{
                // Announces a terabyte and sends none of it: the refusal is on
                // the four bytes of header, or the test hangs reading.
                .{ .send = .{ .payload = "", .declared_len = 1 << 40 } },
                .read,
            };
            var served = try io.concurrent(Canned.serveWebSocket, .{ &canned, &steps });
            defer served.cancel(io) catch {};

            var client = try started(io, .{});
            defer client.deinit();
            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();
            var buf: [64]u8 = undefined;
            var ws: WebSocket = .idle;
            defer ws.deinit();
            try ws.open(&client, &scope, try canned.wsUrl(&buf), .{ .max_message = 16 });

            try testing.expectError(error.MessageTooBig, ws.receive());
            served.await(io) catch {};
            try testing.expectEqual(@as(u8, 8), canned.ws_seen.opcode[0]);
            try testing.expectEqualSlices(u8, "\x03\xf1", canned.ws_seen.payloadOf(0));
            // The socket says it is over, and `send` says so too.
            try testing.expect((try ws.receive()) == null);
            try testing.expectError(error.Closed, ws.sendText("late"));
        }
    }.run);
}

test "the limit counts the pieces of a message together, in decoded bytes" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            const steps = [_]fetch.testing.WsStep{
                .{ .send = .{ .payload = "0123456789", .fin = false } },
                .{ .send = .{ .opcode = 0, .payload = "0123456789" } },
                .read,
            };
            var served = try io.concurrent(Canned.serveWebSocket, .{ &canned, &steps });
            defer served.cancel(io) catch {};

            var client = try started(io, .{});
            defer client.deinit();
            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();
            var buf: [64]u8 = undefined;
            var ws: WebSocket = .idle;
            defer ws.deinit();
            // Two pieces of ten, each inside sixteen, together twenty.
            try ws.open(&client, &scope, try canned.wsUrl(&buf), .{ .max_message = 16 });
            try testing.expectError(error.MessageTooBig, ws.receive());
            served.await(io) catch {};
            try testing.expectEqualSlices(u8, "\x03\xf1", canned.ws_seen.payloadOf(0));
        }
    }.run);
}

test "text that is not UTF-8 is closed with 1007, and so is a frame that breaks the rules with 1002" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var client = try started(io, .{});
            defer client.deinit();
            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            const Case = struct { frame: fetch.testing.WsFrame, err: anyerror, code: []const u8 };
            const cases = [_]Case{
                .{ .frame = .{ .payload = "\xff\xfe" }, .err = error.InvalidPayload, .code = "\x03\xef" },
                // A reserved opcode, and a control frame that is not whole.
                .{ .frame = .{ .opcode = 3, .payload = "x" }, .err = error.ProtocolError, .code = "\x03\xea" },
                .{ .frame = .{ .opcode = 9, .payload = "x", .fin = false }, .err = error.ProtocolError, .code = "\x03\xea" },
            };
            for (cases) |case| {
                var canned = try Canned.open(io);
                defer canned.close();
                const steps = [_]fetch.testing.WsStep{ .{ .send = case.frame }, .read };
                var served = try io.concurrent(Canned.serveWebSocket, .{ &canned, &steps });
                defer served.cancel(io) catch {};

                var buf: [64]u8 = undefined;
                var ws: WebSocket = .idle;
                defer ws.deinit();
                try ws.open(&client, &scope, try canned.wsUrl(&buf), .{});
                try testing.expectError(case.err, ws.receive());
                served.await(io) catch {};
                try testing.expectEqualSlices(u8, case.code, canned.ws_seen.payloadOf(0));
            }
        }
    }.run);
}

test "a close from the other side is echoed, and is the end of the conversation" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            const steps = [_]fetch.testing.WsStep{
                .{ .send = .{ .opcode = 8, .payload = "\x03\xe9going" } },
                .read,
            };
            var served = try io.concurrent(Canned.serveWebSocket, .{ &canned, &steps });
            defer served.cancel(io) catch {};

            var client = try started(io, .{});
            defer client.deinit();
            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();
            var buf: [64]u8 = undefined;
            var ws: WebSocket = .idle;
            defer ws.deinit();
            try ws.open(&client, &scope, try canned.wsUrl(&buf), .{});

            try testing.expect((try ws.receive()) == null);
            try testing.expect(ws.closedCleanly());
            try testing.expectEqual(@as(?u16, 1001), ws.closeCode());
            try testing.expectEqualStrings("going", ws.closeReason());
            served.await(io) catch {};
            // Echoed, masked, the same bytes.
            try testing.expectEqual(@as(u8, 8), canned.ws_seen.opcode[0]);
            try testing.expect(canned.ws_seen.masked[0]);
            try testing.expectEqualSlices(u8, "\x03\xe9going", canned.ws_seen.payloadOf(0));
            // Nothing left to wait for: `close` is at once.
            const began = core.monotonicMicros();
            try testing.expectEqual(fetch.websocket.Closed.acknowledged, ws.close(.normal, ""));
            try testing.expect(core.monotonicMicros() - began < 1_000_000);
        }
    }.run);
}

test "a close the other side never answers is given up on after the time it was given" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            const steps = [_]fetch.testing.WsStep{ .read, .hold_until_closed };
            var served = try io.concurrent(Canned.serveWebSocket, .{ &canned, &steps });
            defer served.cancel(io) catch {};

            var client = try started(io, .{});
            defer client.deinit();
            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();
            var buf: [64]u8 = undefined;
            var ws: WebSocket = .idle;
            defer ws.deinit();
            try ws.open(&client, &scope, try canned.wsUrl(&buf), .{ .close_timeout_ms = 200 });

            const began = core.monotonicMicros();
            try testing.expectEqual(fetch.websocket.Closed.timed_out, ws.close(.normal, ""));
            const took_ms = @divFloor(core.monotonicMicros() - began, std.time.us_per_ms);
            try testing.expect(took_ms >= 150);
            try testing.expect(took_ms < 5_000);
            // The connection was destroyed with it: the server's read of the
            // frames ends, which is what lets `serveWebSocket` return.
            served.await(io) catch {};
            try testing.expect(!ws.isOpen());
        }
    }.run);
}

test "a socket that says nothing for idle_ms is stalled, and one that is only quiet is not" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            const steps = [_]fetch.testing.WsStep{
                .{ .sleep_ms = 100 },
                .{ .send = .{ .payload = "late but in time" } },
                .{ .sleep_ms = 3_000 },
            };
            var served = try io.concurrent(Canned.serveWebSocket, .{ &canned, &steps });
            defer served.cancel(io) catch {};

            var client = try started(io, .{});
            defer client.deinit();
            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();
            var buf: [64]u8 = undefined;
            var ws: WebSocket = .idle;
            defer ws.deinit();
            try ws.open(&client, &scope, try canned.wsUrl(&buf), .{ .idle_ms = 1_000 });

            try testing.expectEqualStrings("late but in time", (try ws.receive()).?.data);
            const began = core.monotonicMicros();
            try testing.expectError(error.Stalled, ws.receive());
            const took_ms = @divFloor(core.monotonicMicros() - began, std.time.us_per_ms);
            try testing.expect(took_ms >= 900);
            try testing.expect(took_ms < 2_900);
        }
    }.run);
}

test "an answer that is not 101 is a refusal with its status, and nothing is left open" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            canned.reply("401 Unauthorized", "", "no");
            var served = try io.concurrent(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var client = try started(io, .{ .max_in_flight = 1 });
            defer client.deinit();
            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();
            var buf: [64]u8 = undefined;
            var ws: WebSocket = .idle;
            defer ws.deinit();
            try testing.expectError(error.UpgradeRefused, ws.open(&client, &scope, try canned.wsUrl(&buf), .{}));
            try testing.expectEqual(@as(u16, 401), ws.status);
            try testing.expect(!ws.isOpen());
            try testing.expectEqual(@as(usize, 1), client.gate.permits);
        }
    }.run);
}

test "a 101 that is not the answer to this handshake is refused" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var client = try started(io, .{});
            defer client.deinit();
            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            // An accept key that is not the hash of ours, an extension nobody
            // offered, and a subprotocol nobody offered.
            const Case = struct { accept: ?[]const u8 = null, headers: []const u8 = "", protocol: ?[]const u8 = null };
            const cases = [_]Case{
                .{ .accept = "AAAAAAAAAAAAAAAAAAAAAAAAAAA=" },
                .{ .headers = "Sec-WebSocket-Extensions: permessage-deflate\r\n" },
                .{ .protocol = "chat" },
            };
            for (cases) |case| {
                var canned = try Canned.open(io);
                defer canned.close();
                canned.ws_accept = case.accept;
                canned.ws_protocol = case.protocol;
                canned.headers = case.headers;
                var served = try io.concurrent(Canned.serveWebSocket, .{ &canned, &[_]fetch.testing.WsStep{} });
                defer served.cancel(io) catch {};

                var buf: [64]u8 = undefined;
                var ws: WebSocket = .idle;
                defer ws.deinit();
                try testing.expectError(error.BadHandshake, ws.open(&client, &scope, try canned.wsUrl(&buf), .{}));
            }
        }
    }.run);
}

test "a subprotocol is offered in order and the one chosen is one that was offered" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            canned.ws_protocol = "v2.chat";
            var served = try io.concurrent(Canned.serveWebSocket, .{ &canned, &[_]fetch.testing.WsStep{} });
            defer served.cancel(io) catch {};

            var client = try started(io, .{});
            defer client.deinit();
            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();
            var buf: [64]u8 = undefined;
            var ws: WebSocket = .idle;
            defer ws.deinit();
            try ws.open(&client, &scope, try canned.wsUrl(&buf), .{ .protocols = &.{ "v1.chat", "v2.chat" } });
            try testing.expectEqualStrings("v2.chat", ws.subprotocol.?);
            try testing.expect(carries(canned.request(), "sec-websocket-protocol: v1.chat, v2.chat"));
        }
    }.run);
}

test "a header the handshake writes is refused before anything is dialled" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var client = try started(io, .{});
            defer client.deinit();
            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();
            var ws: WebSocket = .idle;
            defer ws.deinit();
            try testing.expectError(error.ReservedHeader, ws.open(&client, &scope, "ws://127.0.0.1:1/", .{
                .headers = &.{.{ .name = "sec-websocket-key", .value = "x" }},
            }));
            try testing.expectError(error.InvalidProtocol, ws.open(&client, &scope, "ws://127.0.0.1:1/", .{
                .protocols = &.{"two words"},
            }));
            try testing.expectError(error.UnsupportedUriScheme, ws.open(&client, &scope, "ftp://127.0.0.1:1/", .{}));
        }
    }.run);
}

test "an open socket does not hold the permit that opening it took" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            var served = try io.concurrent(Canned.serveWebSocket, .{ &canned, &[_]fetch.testing.WsStep{.hold_until_closed} });
            defer served.cancel(io) catch {};

            var client = try started(io, .{ .max_in_flight = 1 });
            defer client.deinit();
            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();
            var buf: [64]u8 = undefined;
            var ws: WebSocket = .idle;
            defer ws.deinit();
            try ws.open(&client, &scope, try canned.wsUrl(&buf), .{});
            try testing.expectEqual(@as(usize, 1), client.gate.permits);
        }
    }.run);
}

test "a value goes out as one JSON text message, and text is refused at compile time" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            var served = try io.concurrent(Canned.serveWebSocket, .{ &canned, &[_]fetch.testing.WsStep{.read} });
            defer served.cancel(io) catch {};

            var client = try started(io, .{});
            defer client.deinit();
            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();
            var buf: [64]u8 = undefined;
            var ws: WebSocket = .idle;
            defer ws.deinit();
            try ws.open(&client, &scope, try canned.wsUrl(&buf), .{});
            try ws.sendJson(.{ .op = "subscribe", .channels = [_][]const u8{ "a", "b" } });
            served.await(io) catch {};
            try testing.expectEqual(@as(u8, 1), canned.ws_seen.opcode[0]);
            try testing.expectEqualStrings("{\"op\":\"subscribe\",\"channels\":[\"a\",\"b\"]}", canned.ws_seen.payloadOf(0));
        }
    }.run);
}

test "a socket opens over a unix socket and carries the URL's host as its Host" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    try withIo(struct {
        fn run(io: std.Io) !void {
            var path_buf: [96]u8 = undefined;
            const path = try std.fmt.bufPrint(&path_buf, "/tmp/nilo-fetch-ws-{d}.sock", .{core.monotonicMicros()});
            var canned = try Canned.openUnix(io, path);
            defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
            defer canned.close();
            var served = try io.concurrent(Canned.serveWebSocket, .{ &canned, &[_]fetch.testing.WsStep{
                .{ .send = .{ .payload = "over a file" } },
            } });
            defer served.cancel(io) catch {};

            var client = try started(io, .{});
            defer client.deinit();
            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();
            var ws: WebSocket = .idle;
            defer ws.deinit();
            try ws.open(&client, &scope, "ws://feed.internal/stream", .{ .unix_socket = path });
            try testing.expectEqualStrings("over a file", (try ws.receive()).?.data);
            try testing.expect(carries(canned.request(), "host: feed.internal"));

            var tls_ws: WebSocket = .idle;
            defer tls_ws.deinit();
            try testing.expectError(error.TlsOverSocket, tls_ws.open(&client, &scope, "wss://feed.internal/stream", .{ .unix_socket = path }));
        }
    }.run);
}

test "a socket that was never opened, or was closed twice, is safe to let go" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            var served = try io.concurrent(Canned.serveWebSocket, .{ &canned, &[_]fetch.testing.WsStep{.hold_until_closed} });
            defer served.cancel(io) catch {};

            var never: WebSocket = .idle;
            never.deinit();
            try testing.expectEqual(fetch.websocket.Closed.dropped, never.close(.normal, ""));

            var client = try started(io, .{});
            defer client.deinit();
            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();
            var buf: [64]u8 = undefined;
            var ws: WebSocket = .idle;
            try ws.open(&client, &scope, try canned.wsUrl(&buf), .{ .close_timeout_ms = 100 });
            _ = ws.close(.normal, "");
            try testing.expectEqual(fetch.websocket.Closed.dropped, ws.close(.normal, ""));
            ws.deinit();
            ws.deinit();
        }
    }.run);
}
