//! The half of `fetch.zig`'s tests that needs a socket at both ends.
//!
//! **This file is the Fitting layer's entry condition, written down as
//! something that runs.** A Tool module proves its layer by running under a
//! plain `zig test` with no module graph; a Fitting borrows the loop, so it
//! cannot do that — but it can run under `std.Io.Threaded`, which is std's
//! own. Everything below drives a real client against a real loopback server
//! with **no zio anywhere**, so `zig test fetch/fetch.zig` is the whole suite
//! and `zig build test-fetch` is only the second optimize mode
//! ([ADR 061](../docs/adr/061-a-fitting-borrows-the-loop.md)).
//!
//! If a change ever makes this file need the Engine, the module is in the
//! wrong layer rather than the test being wrong.

const std = @import("std");
const core = @import("nilo_core");
const fetch = @import("fetch.zig");

const testing = std.testing;

/// The canned server, exported so a suite of somebody's own can stand one
/// real exchange without writing the far end again
/// ([ADR 061](../docs/adr/061-a-fitting-borrows-the-loop.md)).
/// Everything about how it is started — `io.concurrent`, never `io.async` —
/// is on the type.
const Canned = fetch.testing.Canned;

/// Everything here runs the loop the same way, and the way matters: this is
/// `std.Io.Threaded`, not the Engine.
fn withIo(comptime body: fn (std.Io) anyerror!void) !void {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    try body(threaded.io());
}

/// A client wired the way a CLI or a worker wires it.
///
/// `.none` rather than the Engine's `Limits`, because there is no Engine here
/// and that is the whole point of the file. Until ADR 056 that meant the
/// timeout was the one behaviour these tests could not reach — arming one
/// needed something that could cancel a fiber. Now it means the client bounds
/// the call itself, as a task of this `Io`, and the two tests under "a
/// deadline with no Engine" below are where that is seen to fire. The other
/// half — telling a deadline from a shutdown — is still `fetch.zig`'s, against
/// a hand-made `Limits`.
fn started(io: std.Io, settings: fetch.Client.Settings) !fetch.Client {
    var client: fetch.Client = .init(testing.allocator, settings);
    try client.nilo_start(io, .none);
    return client;
}

test "a body comes back as request-lifetime text" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            canned.body_len = 11;

            var served = try io.concurrent(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var client = try started(io, .{});
            defer client.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            var buf: [64]u8 = undefined;
            const res = try client.get(&scope, try canned.url(&buf), .{});

            try testing.expectEqual(std.http.Status.ok, res.status);
            try testing.expect(res.ok());
            try testing.expectEqual(@as(usize, 11), res.body.len());
            // It is the Run's memory, so it goes when the Run's tick does and
            // nothing here frees it. The trap that can say so is Debug-only by
            // design, so this half of the claim is checked in one mode.
            if (core.trap_enabled) try testing.expect(res.body.alive());
        }
    }.run);
}

/// A `Limits` that counts the waits reported through it, for the test below.
/// Not `engineless`, so the client takes the Engine's path, which is the one
/// that reports; under `std.Io.Threaded` that path runs each step on the
/// calling thread and nothing is ever cancelled, which this test does not need.
var waits_opened: usize = 0;
var waits_closed: usize = 0;
const counting_limits: core.Limits = .{ .vtable = &.{
    .arm = core.Limits.noop.arm,
    .release = core.Limits.noop.release,
    .fired = core.Limits.noop.fired,
    .waiting = struct {
        fn f(_: ?*anyopaque) u64 {
            waits_opened += 1;
            return 1;
        }
    }.f,
    .waited = struct {
        fn f(_: ?*anyopaque, token: u64) void {
            std.debug.assert(token == 1);
            waits_closed += 1;
        }
    }.f,
} };

test "every wait on the socket is reported, and none is open while the caller has the fiber" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            canned.body_len = 4096;

            var served = try io.concurrent(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var client: fetch.Client = .init(testing.allocator, .{});
            defer client.deinit();
            try client.nilo_start(io, counting_limits);

            waits_opened = 0;
            waits_closed = 0;

            var buf: [64]u8 = undefined;
            var ex: fetch.Exchange = .idle;
            defer ex.end();
            _ = try ex.begin(&client, .{ .method = .GET, .url = try canned.url(&buf) });
            // The permit and the head are waits; the handler holding the
            // fiber again means both are closed (ADR 210).
            try testing.expect(waits_opened >= 2);
            try testing.expectEqual(waits_opened, waits_closed);

            // A body moved in pieces is a wait per piece, closed before the
            // piece is handed over, so the handler's own work between them is
            // watched the way any other work is.
            var sink: [4096]u8 = undefined;
            var w = std.Io.Writer.fixed(&sink);
            var pieces: usize = 0;
            var moved: usize = 0;
            while (true) {
                const before = waits_opened;
                const n = try ex.stream(&w, .limited(512));
                try testing.expect(waits_opened > before);
                try testing.expectEqual(waits_opened, waits_closed);
                if (n == 0) break;
                moved += n;
                pieces += 1;
            }
            try testing.expectEqual(@as(usize, 4096), moved);
            try testing.expect(pieces >= 1);

            ex.end();
            try testing.expectEqual(waits_opened, waits_closed);
        }
    }.run);
}

test "a body over the ceiling stops at the ceiling" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            canned.body_len = 4096;

            var served = try io.concurrent(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var client = try started(io, .{ .max_body = 1024 });
            defer client.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            var buf: [64]u8 = undefined;
            try testing.expectError(
                error.BodyTooLarge,
                client.get(&scope, try canned.url(&buf), .{}),
            );
        }
    }.run);
}

test "a server that lies about content-length does not get past the ceiling" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            // Claims 10 bytes, sends 4096. The ceiling is enforced while
            // reading, so the claim buys nothing.
            canned.body_len = 4096;
            canned.claim_len = 10;

            var served = try io.concurrent(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var client = try started(io, .{ .max_body = 1024 });
            defer client.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            var buf: [64]u8 = undefined;
            const res = client.get(&scope, try canned.url(&buf), .{});
            // Either the ceiling caught it or the framing did; what must not
            // happen is 4096 bytes arriving under a ceiling of 1024.
            if (res) |ok| {
                try testing.expect(ok.body.len() <= 1024);
            } else |_| {}
        }
    }.run);
}

test "the status a caller checks is the status that arrived" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            canned.status = "503 Service Unavailable";
            canned.body_len = 4;

            var served = try io.concurrent(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var client = try started(io, .{});
            defer client.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            var buf: [64]u8 = undefined;
            const res = try client.get(&scope, try canned.url(&buf), .{});

            try testing.expectEqual(std.http.Status.service_unavailable, res.status);
            // A 503 is a response, not an error: the call worked and the
            // service said no. Only the caller knows which of those matters.
            try testing.expect(!res.ok());
        }
    }.run);
}

test "a body sent is a body the other end reads" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            canned.body_len = 2;

            var served = try io.concurrent(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var client = try started(io, .{});
            defer client.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            var buf: [64]u8 = undefined;
            _ = try client.post(&scope, try canned.url(&buf), "amount=500", .{});

            served.await(io) catch {};
            try testing.expect(std.mem.startsWith(u8, canned.seen[0..canned.seen_len], "POST /"));
        }
    }.run);
}

test "a header a caller adds is a header that arrives" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();

            var served = try io.concurrent(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var client = try started(io, .{});
            defer client.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            var buf: [64]u8 = undefined;
            _ = try client.get(&scope, try canned.url(&buf), .{
                .headers = &.{.{ .name = "Authorization", .value = "Bearer wati" }},
            });

            served.await(io) catch {};
            try testing.expect(std.mem.indexOf(
                u8,
                canned.seen[0..canned.seen_len],
                "Bearer wati",
            ) != null);
        }
    }.run);
}

test "a header std has a slot for goes out once, and it is the caller's" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();

            var served = try io.concurrent(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var client = try started(io, .{});
            defer client.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            // The three a pasted `curl` line carries, in the browser's own
            // capitalisation, and one std writes a default for regardless.
            var buf: [64]u8 = undefined;
            _ = try client.get(&scope, try canned.url(&buf), .{
                .headers = &.{
                    .{ .name = "User-Agent", .value = "Mozilla/5.0 (pasted)" },
                    .{ .name = "Host", .value = "cdn.example" },
                    .{ .name = "Authorization", .value = "Bearer once" },
                    .{ .name = "Accept-Encoding", .value = "br" },
                },
            });

            served.await(io) catch {};
            const seen = canned.seen[0..canned.seen_len];
            try testing.expectEqual(@as(usize, 1), countLines(seen, "user-agent:"));
            try testing.expectEqual(@as(usize, 1), countLines(seen, "host:"));
            try testing.expectEqual(@as(usize, 1), countLines(seen, "authorization:"));
            try testing.expectEqual(@as(usize, 1), countLines(seen, "accept-encoding:"));
            // And the one copy is the caller's, not std's.
            try testing.expect(std.mem.indexOf(u8, seen, "Mozilla/5.0 (pasted)") != null);
            try testing.expect(std.mem.indexOf(u8, seen, "cdn.example") != null);
            try testing.expect(std.mem.indexOf(u8, seen, "br") != null);
            try testing.expect(std.mem.indexOf(u8, seen, "identity") == null);
        }
    }.run);
}

/// How many header lines in `head` start with `name`, case-insensitively.
fn countLines(head: []const u8, name: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, head, '\n');
    while (it.next()) |line| {
        if (std.ascii.startsWithIgnoreCase(line, name)) n += 1;
    }
    return n;
}

// ---- a deadline with no Engine (ADR 056) ----

/// Wide enough that a slow machine passes, and an order of magnitude under
/// what an unbounded call would take: the silent server holds until the
/// client gives up, so a call with no working deadline never comes back.
const deadline_slack_ms = 5_000;

test "a deadline fires on std.Io.Threaded, with no Engine anywhere" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();

            var served = try io.concurrent(Canned.serveSilence, .{&canned});
            defer served.cancel(io) catch {};

            var client = try started(io, .{ .timeout_ms = 200 });
            defer client.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            var buf: [64]u8 = undefined;
            const started_at = core.monotonicMicros();
            try testing.expectError(error.TimedOut, client.get(&scope, try canned.url(&buf), .{}));
            const took_ms = @divFloor(core.monotonicMicros() - started_at, std.time.us_per_ms);
            try testing.expect(took_ms >= 150);
            try testing.expect(took_ms < deadline_slack_ms);

            // And the client is still good for the next call: the permit
            // came back and nothing is held.
            try testing.expectEqual(@as(usize, client.settings.max_in_flight), client.gate.permits);
        }
    }.run);
}

test "a body that stalls after the head is a timeout too, and it is per call" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            canned.body_len = 10;

            var served = try io.concurrent(Canned.serveThenStall, .{&canned});
            defer served.cancel(io) catch {};

            // The client's own timeout is generous; the call's is not.
            var client = try started(io, .{ .timeout_ms = 60_000 });
            defer client.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            var buf: [64]u8 = undefined;
            const started_at = core.monotonicMicros();
            try testing.expectError(error.TimedOut, client.get(&scope, try canned.url(&buf), .{ .timeout_ms = 200 }));
            const took_ms = @divFloor(core.monotonicMicros() - started_at, std.time.us_per_ms);
            try testing.expect(took_ms < deadline_slack_ms);
        }
    }.run);
}

test "a redirect that was followed says where it ended, and one that was not says nothing" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            canned.body_len = 4;

            var served = try io.concurrent(Canned.serveRedirectThenOne, .{&canned});
            defer served.cancel(io) catch {};

            var client = try started(io, .{});
            defer client.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            var buf: [64]u8 = undefined;
            var redirect: [1 << 10]u8 = undefined;
            var transfer: [1 << 10]u8 = undefined;

            var ex: fetch.Exchange = .idle;
            defer ex.end();
            const head = try ex.begin(&client, .{
                .method = .GET,
                .url = try canned.url(&buf),
                .redirects = .{ .follow = &redirect },
                .transfer_buffer = &transfer,
            });
            try testing.expect(head.ok());

            var where: [128]u8 = undefined;
            const landed = (try head.location(&where)).?;
            var want: [64]u8 = undefined;
            try testing.expectEqualStrings(
                try std.fmt.bufPrint(&want, "http://127.0.0.1:{d}/moved", .{canned.port}),
                landed,
            );
            // The second request went to the new path, not the old one.
            served.await(io) catch {};
            try testing.expect(std.mem.indexOf(u8, canned.seen[0..canned.seen_len], "GET /moved ") != null);

            const body = try ex.take(&scope, 1 << 10);
            try testing.expectEqualStrings("xxxx", body.view());
        }
    }.run);

    // The control: an answer from the URL that was asked for.
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            canned.body_len = 1;

            var served = try io.concurrent(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var client = try started(io, .{});
            defer client.deinit();

            var buf: [64]u8 = undefined;
            var redirect: [1 << 10]u8 = undefined;
            var transfer: [1 << 10]u8 = undefined;

            var ex: fetch.Exchange = .idle;
            defer ex.end();
            const head = try ex.begin(&client, .{
                .method = .GET,
                .url = try canned.url(&buf),
                .redirects = .{ .follow = &redirect },
                .transfer_buffer = &transfer,
            });
            var where: [128]u8 = undefined;
            try testing.expect((try head.location(&where)) == null);
            try testing.expect(head.redirected == null);
        }
    }.run);
}

/// Whether the request head `seen` (as `Canned.request` returns it) carries
/// a header of this name, in any case: the client writes its own slots in
/// lower case and the caller's lines as they were given.
fn carries(seen: []const u8, name: []const u8) bool {
    var lines = std.mem.splitScalar(u8, seen, '\n');
    while (lines.next()) |line| {
        if (line.len > name.len and line[name.len] == ':' and std.ascii.eqlIgnoreCase(line[0..name.len], name)) return true;
    }
    return false;
}

test "a redirect to another origin leaves behind what a target stands behind" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            // Two servers on two ports: the same host and another port is
            // another origin, and the first sends the call to the second.
            var first = try Canned.open(io);
            defer first.close();
            var second = try Canned.open(io);
            defer second.close();
            var where: [96]u8 = undefined;
            const moved = try std.fmt.bufPrint(&where, "Location: http://127.0.0.1:{d}/files/1\r\n", .{second.port});
            first.reply("302 Found", moved, "");
            second.reply("200 OK", "", "ok");

            var client = try started(io, .{});
            defer client.deinit();
            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();
            var buf: [64]u8 = undefined;

            const Api = fetch.Target("api", .{});
            var api = try Api.open(&client, .{
                .base = try first.url(&buf),
                .authorization = "Bearer standing",
                .user_agent = "nilo-test",
                .headers = &.{ .{ .name = "x-api-key", .value = "secret" }, .{ .name = "accept", .value = "application/json" } },
            });

            var served_first = try io.concurrent(Canned.serveOne, .{&first});
            defer served_first.cancel(io) catch {};
            var served_second = try io.concurrent(Canned.serveOne, .{&second});
            defer served_second.cancel(io) catch {};
            const res = try api.get(&scope, "/v1/file", .{}, .{ .headers = &.{
                .{ .name = "Cookie", .value = "sid=1" },
                .{ .name = "Proxy-Authorization", .value = "Basic eA==" },
                .{ .name = "X-Trace", .value = "t1" },
            } });
            served_first.await(io) catch {};
            served_second.await(io) catch {};
            try testing.expectEqualStrings("ok", res.body.view());

            // The response says where the call ended, without the userinfo.
            var landed: [64]u8 = undefined;
            try testing.expectEqualStrings(
                try std.fmt.bufPrint(&landed, "http://127.0.0.1:{d}/files/1", .{second.port}),
                res.redirected.?,
            );

            // The service the target is for saw all of it.
            try testing.expect(carries(first.request(), "authorization"));
            try testing.expect(carries(first.request(), "x-api-key"));
            try testing.expect(carries(first.request(), "cookie"));

            // The other origin saw none of the credentials, and still saw
            // what is not one.
            const seen = second.request();
            try testing.expect(std.mem.startsWith(u8, seen, "GET /files/1 "));
            try testing.expect(!carries(seen, "authorization"));
            try testing.expect(!carries(seen, "x-api-key"));
            try testing.expect(!carries(seen, "cookie"));
            try testing.expect(!carries(seen, "proxy-authorization"));
            try testing.expect(carries(seen, "x-trace"));
            try testing.expect(carries(seen, "user-agent"));
        }
    }.run);
}

test "a call's own authorization line is left behind at another origin too" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var first = try Canned.open(io);
            defer first.close();
            var second = try Canned.open(io);
            defer second.close();
            var where: [96]u8 = undefined;
            first.reply("302 Found", try std.fmt.bufPrint(&where, "Location: http://127.0.0.1:{d}/\r\n", .{second.port}), "");
            second.reply("200 OK", "", "ok");

            var client = try started(io, .{});
            defer client.deinit();
            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();
            var buf: [64]u8 = undefined;

            var served_first = try io.concurrent(Canned.serveOne, .{&first});
            defer served_first.cancel(io) catch {};
            var served_second = try io.concurrent(Canned.serveOne, .{&second});
            defer served_second.cancel(io) catch {};
            _ = try client.get(&scope, try first.url(&buf), .{ .headers = &.{.{ .name = "Authorization", .value = "Bearer mine" }} });
            served_first.await(io) catch {};
            served_second.await(io) catch {};

            try testing.expect(carries(first.request(), "authorization"));
            try testing.expect(!carries(second.request(), "authorization"));
        }
    }.run);
}

test "a redirect inside one origin keeps every credential" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            canned.body_len = 2;
            var served = try io.concurrent(Canned.serveRedirectThenOne, .{&canned});
            defer served.cancel(io) catch {};

            var client = try started(io, .{});
            defer client.deinit();
            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();
            var buf: [64]u8 = undefined;

            const Api = fetch.Target("api", .{});
            var api = try Api.open(&client, .{ .base = try canned.url(&buf), .authorization = "Bearer standing", .headers = &.{.{ .name = "x-api-key", .value = "secret" }} });
            const res = try api.get(&scope, "/start", .{}, .{ .headers = &.{.{ .name = "Cookie", .value = "sid=1" }} });
            served.await(io) catch {};
            var landed: [64]u8 = undefined;
            try testing.expectEqualStrings(
                try std.fmt.bufPrint(&landed, "http://127.0.0.1:{d}/moved", .{canned.port}),
                res.redirected.?,
            );

            // Both requests, the one to `/start` and the one to `/moved`.
            const seen = canned.request();
            try testing.expectEqual(@as(usize, 2), std.mem.count(u8, seen, "GET /"));
            try testing.expectEqual(@as(usize, 2), std.mem.count(u8, seen, "authorization: Bearer standing"));
            try testing.expectEqual(@as(usize, 2), std.mem.count(u8, seen, "x-api-key: secret"));
            try testing.expectEqual(@as(usize, 2), std.mem.count(u8, seen, "Cookie: sid=1"));
        }
    }.run);
}

// ---- the other clock: silence, not the call (ADR 056) ----

test "silence after the head is a stall, told apart from the call's own clock" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            canned.body_len = 10;

            var served = try io.concurrent(Canned.serveThenStall, .{&canned});
            defer served.cancel(io) catch {};

            // No ceiling on the call at all (a transfer may take an hour)
            // and 200 ms on silence inside it.
            var client = try started(io, .{ .timeout_ms = 0, .stall_ms = 200 });
            defer client.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            var buf: [64]u8 = undefined;
            const started_at = core.monotonicMicros();
            try testing.expectError(error.Stalled, client.get(&scope, try canned.url(&buf), .{}));
            const took_ms = @divFloor(core.monotonicMicros() - started_at, std.time.us_per_ms);
            try testing.expect(took_ms >= 150);
            try testing.expect(took_ms < deadline_slack_ms);

            // The permit came back, the same check the deadline makes.
            try testing.expectEqual(@as(usize, client.settings.max_in_flight), client.gate.permits);
        }
    }.run);
}

test "a body that keeps moving never stalls, however slowly" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            canned.body_len = 24;

            // Twenty-four bytes, 60 ms apart: 1.44 s of body under a
            // one-second silence bound. A bound on the call would fire; a
            // bound on silence must not, because every gap is under it. A
            // second rather than 200 ms because the gaps are the server's
            // sleeps, and on the loaded macOS CI runner a 60 ms sleep was
            // measured at up to 135 ms and went past 200 often enough to fail
            // this on every run.
            var served = try io.concurrent(Canned.serveTrickle, .{ &canned, @as(u32, 60) });
            defer served.cancel(io) catch {};

            var client = try started(io, .{ .timeout_ms = 0, .stall_ms = 1000 });
            defer client.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            var buf: [64]u8 = undefined;
            const res = try client.get(&scope, try canned.url(&buf), .{});
            try testing.expectEqualStrings(&@as([24]u8, @splat('x')), res.body.view());
        }
    }.run);
}

test "a chunk read through the Exchange is inside the silence clock" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            canned.body_len = 10;

            var served = try io.concurrent(Canned.serveThenStall, .{&canned});
            defer served.cancel(io) catch {};

            var client = try started(io, .{ .timeout_ms = 0 });
            defer client.deinit();

            var buf: [64]u8 = undefined;
            var out: [64]u8 = undefined;
            var w = std.Io.Writer.fixed(&out);

            var ex: fetch.Exchange = .idle;
            defer ex.end();
            _ = try ex.begin(&client, .{ .method = .GET, .url = try canned.url(&buf), .stall_ms = 200 });

            // The loop a download manager writes: a chunk at a time, up to a
            // boundary of its own. The three bytes land, then silence.
            var got: usize = 0;
            const failed = while (true) {
                const n = ex.stream(&w, .limited(10 - got)) catch |err| break err;
                if (n == 0) break error.EndedEarly;
                got += n;
            };
            try testing.expectEqual(@as(usize, 3), got);
            try testing.expectError(error.Stalled, @as(anyerror!void, failed));
        }
    }.run);
}

test "one socket read is one chunk, and zero is the end of the body" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            canned.body_len = 4096;

            var served = try io.concurrent(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var client = try started(io, .{});
            defer client.deinit();

            var buf: [64]u8 = undefined;
            var out: [8 << 10]u8 = undefined;
            var w = std.Io.Writer.fixed(&out);

            var ex: fetch.Exchange = .idle;
            defer ex.end();
            _ = try ex.begin(&client, .{ .method = .GET, .url = try canned.url(&buf) });

            var total: usize = 0;
            var reads: usize = 0;
            while (true) {
                const n = try ex.stream(&w, .limited(1000));
                if (n == 0) break;
                try testing.expect(n <= 1000);
                total += n;
                reads += 1;
            }
            try testing.expectEqual(@as(usize, 4096), total);
            try testing.expect(reads >= 5);
            // Asked again after the end, still the end.
            try testing.expectEqual(@as(usize, 0), try ex.stream(&w, .limited(1000)));
        }
    }.run);
}

// ---- a redirect is a decision with a name (ADR 183) ----

test "an answer that says go elsewhere is refused unless the call decided otherwise" {
    // The default: a 302 is an error that names what to decide.
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            canned.status = "302 Found";
            canned.headers = "Location: http://127.0.0.1:1/moved\r\n";

            var served = try io.concurrent(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var client = try started(io, .{});
            defer client.deinit();

            var buf: [64]u8 = undefined;
            var ex: fetch.Exchange = .idle;
            defer ex.end();
            try testing.expectError(error.RedirectRefused, ex.begin(&client, .{ .method = .GET, .url = try canned.url(&buf) }));
        }
    }.run);

    // Asked for: the same 302, handed over as itself.
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            canned.status = "302 Found";
            canned.headers = "Location: http://127.0.0.1:1/moved\r\n";

            var served = try io.concurrent(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var client = try started(io, .{});
            defer client.deinit();

            var buf: [64]u8 = undefined;
            var ex: fetch.Exchange = .idle;
            defer ex.end();
            const head = try ex.begin(&client, .{ .method = .GET, .url = try canned.url(&buf), .redirects = .expose });
            try testing.expectEqual(std.http.Status.found, head.status);
            try testing.expectEqualStrings("http://127.0.0.1:1/moved", head.header("location").?);
            try testing.expect(head.redirected == null);
        }
    }.run);

    // A 304 is a 3xx and not a redirect: it says nothing about where to go,
    // and a caller sending `if-none-match` is owed it as an answer.
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            canned.status = "304 Not Modified";

            var served = try io.concurrent(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var client = try started(io, .{});
            defer client.deinit();

            var buf: [64]u8 = undefined;
            var ex: fetch.Exchange = .idle;
            defer ex.end();
            const head = try ex.begin(&client, .{ .method = .GET, .url = try canned.url(&buf) });
            try testing.expectEqual(std.http.Status.not_modified, head.status);
        }
    }.run);
}

// ---- a head that outlives its body (ADR 187) ----

test "a kept head reads the same after the body has been through" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            canned.body_len = 3000;
            canned.headers = "ETag: \"d41d8cd9\"\r\nContent-Type: text/plain\r\n";

            var served = try io.concurrent(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var client = try started(io, .{});
            defer client.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            var buf: [64]u8 = undefined;
            var ex: fetch.Exchange = .idle;
            defer ex.end();
            const head = try ex.begin(&client, .{ .method = .GET, .url = try canned.url(&buf) });
            const kept = try head.keep(&scope);

            // A body larger than the connection's buffer, so the bytes the
            // borrowed head pointed at are read over for certain.
            const body = try ex.take(&scope, 1 << 20);
            try testing.expectEqual(@as(usize, 3000), body.len());

            try testing.expectEqualStrings("\"d41d8cd9\"", kept.header("etag").?);
            try testing.expectEqualStrings("text/plain", kept.content_type.?);
            try testing.expectEqual(std.http.Status.ok, kept.status);
            try testing.expectEqual(@as(u64, 3000), kept.content_length.?);
            // Its `content_type` moved with the block rather than being a
            // second copy: it points inside the kept bytes.
            const start = @intFromPtr(kept.bytes.ptr);
            const at = @intFromPtr(kept.content_type.?.ptr);
            try testing.expect(at >= start and at < start + kept.bytes.len);
        }
    }.run);
}

// ---- the transfer buffer serves nothing here (ADR 186) ----

test "no transfer buffer is needed on any framing, and the read size is the client's" {
    // Chunked, the framing that would read through one if any did, into
    // the Scope with no buffer anywhere.
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            canned.body_len = 2500;

            var served = try io.concurrent(Canned.serveChunked, .{&canned});
            defer served.cancel(io) catch {};

            var client = try started(io, .{});
            defer client.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            var buf: [64]u8 = undefined;
            var ex: fetch.Exchange = .idle;
            defer ex.end();
            const head = try ex.begin(&client, .{ .method = .GET, .url = try canned.url(&buf) });
            try testing.expect(head.content_length == null);
            const body = try ex.take(&scope, 1 << 20);
            try testing.expectEqual(@as(usize, 2500), body.len());
            try testing.expectEqual(@as(u8, 'x'), body.view()[2499]);
        }
    }.run);

    // And a wider read buffer, given to std at `init`, brings a body larger
    // than the default one whole.
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            canned.body_len = 100 << 10;

            var served = try io.concurrent(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var client = try started(io, .{ .read_buffer_size = 64 << 10 });
            defer client.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            var buf: [64]u8 = undefined;
            const res = try client.get(&scope, try canned.url(&buf), .{});
            try testing.expectEqual(@as(usize, 100 << 10), res.body.len());
        }
    }.run);
}

/// A Scope that has a request id — the shape a `*Ctx` has, without `http/`
/// in this file. `nilo_fetch` reads the id by declaration and never names
/// `Ctx`, so this is exactly what it sees (ADR 158).
const Named = struct {
    run: *core.Run,
    id: []const u8,

    pub fn arena(self: *Named) std.mem.Allocator {
        return self.run.arena();
    }
    pub fn str(self: *Named, bytes: []const u8) core.Str {
        return self.run.str(bytes);
    }
    pub fn requestId(self: *Named) core.Str {
        return self.run.str(self.id);
    }
};

test "a call made under a request carries the request's id, and one under a Run carries none" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();

            var client = try started(io, .{});
            defer client.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();
            var buf: [64]u8 = undefined;

            // A Run: no request, no header.
            {
                canned.seen_len = 0;
                var served = try io.concurrent(Canned.serveOne, .{&canned});
                defer served.cancel(io) catch {};
                _ = try client.get(&scope, try canned.url(&buf), .{});
                served.await(io) catch {};
                try testing.expect(std.mem.indexOf(u8, canned.seen[0..canned.seen_len], "X-Request-Id") == null);
            }

            // A request: its id, on a call that passed no headers of its own.
            var named: Named = .{ .run = &scope, .id = "7f3a9c1e5b2d4086" };
            {
                canned.seen_len = 0;
                var served = try io.concurrent(Canned.serveOne, .{&canned});
                defer served.cancel(io) catch {};
                _ = try client.get(&named, try canned.url(&buf), .{});
                served.await(io) catch {};
                try testing.expect(std.mem.indexOf(u8, canned.seen[0..canned.seen_len], "X-Request-Id: 7f3a9c1e5b2d4086") != null);
            }

            // And beside the caller's own headers, both arriving.
            {
                canned.seen_len = 0;
                var served = try io.concurrent(Canned.serveOne, .{&canned});
                defer served.cancel(io) catch {};
                _ = try client.get(&named, try canned.url(&buf), .{
                    .headers = &.{.{ .name = "Authorization", .value = "Bearer wati" }},
                });
                served.await(io) catch {};
                const seen = canned.seen[0..canned.seen_len];
                try testing.expect(std.mem.indexOf(u8, seen, "Bearer wati") != null);
                try testing.expect(std.mem.indexOf(u8, seen, "X-Request-Id: 7f3a9c1e5b2d4086") != null);
            }
        }
    }.run);
}

/// A Scope that traces: the two declarations a `*Ctx` on an App with
/// `app.trace` has, without `http/` in this file (ADR 247).
const Traced = struct {
    run: *core.Run,
    begun: usize = 0,
    ended: ?core.trace.Ended = null,
    ended_with: ?core.trace.Outbound = null,

    const context: core.trace.Context = .{ .trace_id = @splat(0xab), .span_id = @splat(0xcd), .sampled = true };

    pub fn arena(self: *Traced) std.mem.Allocator {
        return self.run.arena();
    }
    pub fn str(self: *Traced, bytes: []const u8) core.Str {
        return self.run.str(bytes);
    }
    pub fn traceBegin(self: *Traced) ?core.trace.Outbound {
        self.begun += 1;
        return .{ .context = context, .parent = @splat(1), .started_us = 0, .started_mono_us = 0, .state = "vendor=7" };
    }
    pub fn traceEnd(self: *Traced, begun: core.trace.Outbound, ended: core.trace.Ended) void {
        self.ended_with = begun;
        self.ended = ended;
    }
};

test "a call made under a Scope that traces carries traceparent, and the Scope hears how it ended" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();

            var client = try started(io, .{});
            defer client.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();
            var traced: Traced = .{ .run = &scope };
            var buf: [64]u8 = undefined;

            canned.seen_len = 0;
            var served = try io.concurrent(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};
            const res = try client.get(&traced, try canned.url(&buf), .{});
            served.await(io) catch {};

            const seen = canned.seen[0..canned.seen_len];
            try testing.expect(std.mem.indexOf(u8, seen, "traceparent: 00-abababababababababababababababab-cdcdcdcdcdcdcdcd-01") != null);
            try testing.expect(std.mem.indexOf(u8, seen, "tracestate: vendor=7") != null);
            try testing.expectEqual(@as(usize, 1), traced.begun);
            const ended = traced.ended.?;
            try testing.expectEqualStrings("GET", ended.method);
            try testing.expect(std.mem.startsWith(u8, ended.url, "http://127.0.0.1:"));
            try testing.expectEqual(@backingInt(res.status), ended.status);
            try testing.expect(ended.failure == null);
        }
    }.run);
}

test "a traced call that cannot connect still ends its span, naming the error" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var client = try started(io, .{});
            defer client.deinit();
            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();
            var traced: Traced = .{ .run = &scope };

            // Port 1 on loopback: nothing listens, and the refusal is
            // immediate.
            _ = client.get(&traced, "http://127.0.0.1:1/", .{}) catch {};
            const ended = traced.ended.?;
            try testing.expectEqual(@as(u16, 0), ended.status);
            try testing.expect(ended.failure != null);
            try testing.expectEqualStrings("http://127.0.0.1:1/", ended.url);
        }
    }.run);
}

test "a caller's own X-Request-Id wins, and the setting turns the header off" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();
            var named: Named = .{ .run = &scope, .id = "ours" };
            var buf: [64]u8 = undefined;

            {
                var client = try started(io, .{});
                defer client.deinit();
                canned.seen_len = 0;
                var served = try io.concurrent(Canned.serveOne, .{&canned});
                defer served.cancel(io) catch {};
                _ = try client.get(&named, try canned.url(&buf), .{
                    .headers = &.{.{ .name = "x-request-id", .value = "theirs" }},
                });
                served.await(io) catch {};
                const seen = canned.seen[0..canned.seen_len];
                try testing.expect(std.mem.indexOf(u8, seen, "x-request-id: theirs") != null);
                try testing.expect(std.mem.indexOf(u8, seen, "ours") == null);
            }

            {
                var client = try started(io, .{ .forward_request_id = false });
                defer client.deinit();
                canned.seen_len = 0;
                var served = try io.concurrent(Canned.serveOne, .{&canned});
                defer served.cancel(io) catch {};
                _ = try client.get(&named, try canned.url(&buf), .{});
                served.await(io) catch {};
                try testing.expect(std.mem.indexOf(u8, canned.seen[0..canned.seen_len], "X-Request-Id") == null);
            }
        }
    }.run);
}

test "JSON parses into a struct of the caller's own" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var run_scope: core.Run = .init(testing.allocator);
            defer run_scope.deinit();

            // No socket needed: the parse is the whole subject, and the body
            // is the same Str either way.
            const res: fetch.Response = .{
                .status = .ok,
                .body = run_scope.str(
                    \\{"id": 7, "email": "wati@example.com", "extra": "ignored"}
                ),
            };

            const User = struct { id: u32, email: []const u8 };
            const user = try res.json(User, &run_scope);

            try testing.expectEqual(@as(u32, 7), user.id);
            try testing.expectEqualStrings("wati@example.com", user.email);
            _ = io;
        }
    }.run);
}

test "the body is asked for uncompressed, so what comes back is the body" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            canned.body_len = 4;

            var served = try io.concurrent(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var client = try started(io, .{});
            defer client.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            var buf: [64]u8 = undefined;
            _ = try client.get(&scope, try canned.url(&buf), .{});

            const head = canned.seen[0..canned.seen_len];

            // `std.http.Client` advertises `gzip, deflate` and then returns
            // the compressed bytes from `reader()`. `fetch/tls.zig` is where
            // that was caught, against a real endpoint; this is the half of
            // it that runs with no network, so deleting the line in `send`
            // fails in `zig build test` rather than only in `smoke-tls`.
            try testing.expect(std.mem.indexOf(u8, head, "accept-encoding: identity") != null);
            try testing.expect(std.mem.indexOf(u8, head, "gzip") == null);
        }
    }.run);
}

// ---- what an Exchange adds, and the drain that decides a connection ----

test "a refused body costs the connection rather than the download" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            // 32 KiB offered, a kilobyte allowed. What is left over is nearly
            // four times `max_drain`, so reading it to keep the connection is
            // the expensive answer and the connection goes instead.
            //
            // **The absolute size is load-bearing and it is not about HTTP.**
            // This server writes the whole body before the client stops
            // reading, so every byte of it has to sit in kernel socket buffers
            // — and a body past what they hold parks the server mid-write with
            // nothing to wake it. The first draft used a megabyte and hung the
            // suite; the second used 128 KiB, which is *exactly* this
            // machine's `net.ipv4.tcp_rmem` default of 131072 and hung it
            // again, intermittently, depending on where send-buffer
            // autotuning happened to be. 32 KiB is a quarter of the smallest
            // default worth worrying about, and the ratio to `max_drain` is
            // what the test is actually about — so scale both together, never
            // the body alone.
            canned.body_len = 32 << 10;

            var served = try io.concurrent(Canned.serveEach, .{ &canned, @as(usize, 2) });
            defer served.cancel(io) catch {};

            var client = try started(io, .{ .max_body = 1024, .max_drain = 8 << 10 });
            defer client.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            var buf: [64]u8 = undefined;
            const url = try canned.url(&buf);

            try testing.expectError(error.BodyTooLarge, client.get(&scope, url, .{}));
            _ = client.get(&scope, url, .{}) catch {};

            // Two connections means the first was dropped. One would mean it
            // was kept — which is only possible by reading the megabyte, since
            // `Request.deinit` drains whatever it keeps.
            try testing.expectEqual(@as(usize, 2), canned.accepted);
        }
    }.run);
}

test "a leftover under the ceiling is read, and the connection stays" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            canned.body_len = 32 << 10;

            var served = try io.concurrent(Canned.serveEach, .{ &canned, @as(usize, 2) });
            defer served.cancel(io) catch {};

            // The same body and the same refusal, with the ceiling moved above
            // it. This is the control: it is the *decision* that changes, not
            // the request, so a version of `dropIfDrainIsDearer` that always
            // dropped would fail here and still look right above. The body has
            // to match the test above byte for byte or the pair stops being a
            // control.
            var client = try started(io, .{ .max_body = 1024, .max_drain = 1 << 20 });
            defer client.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            var buf: [64]u8 = undefined;
            const url = try canned.url(&buf);

            try testing.expectError(error.BodyTooLarge, client.get(&scope, url, .{}));
            // The second call reuses a connection this server has already
            // closed, so whether it succeeds is the server's business. What is
            // being asked is whether the client went looking for a new one.
            _ = client.get(&scope, url, .{}) catch {};

            try testing.expectEqual(@as(usize, 1), canned.accepted);
        }
    }.run);
}

test "discard closes the connection whatever the drain policy would have kept" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            canned.body_len = 32 << 10;

            var served = try io.concurrent(Canned.serveEach, .{ &canned, @as(usize, 2) });
            defer served.cancel(io) catch {};

            // The same ceiling as the control above, under which `end`
            // would read the 32 KiB to keep the connection. The caller
            // knows better — a probe that got the whole file — and says so.
            var client = try started(io, .{ .max_drain = 1 << 20 });
            defer client.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            var buf: [64]u8 = undefined;
            const url = try canned.url(&buf);
            var transfer: [1 << 10]u8 = undefined;

            {
                var ex: fetch.Exchange = .idle;
                defer ex.end();
                const head = try ex.begin(&client, .{ .method = .GET, .url = url, .transfer_buffer = &transfer });
                try testing.expectEqual(@as(u64, 32 << 10), head.content_length.?);
                ex.discard();
            }
            _ = client.get(&scope, url, .{}) catch {};

            // Two connections: the first went with the body it did not read.
            try testing.expectEqual(@as(usize, 2), canned.accepted);
        }
    }.run);
}

test "a response header is readable before the body is touched" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            canned.body_len = 5;
            canned.headers = "ETag: \"d41d8cd9\"\r\nx-amz-request-id: 8F2C\r\n";

            var served = try io.concurrent(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var client = try started(io, .{});
            defer client.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            var buf: [64]u8 = undefined;
            var transfer: [1 << 10]u8 = undefined;

            var ex: fetch.Exchange = .idle;
            defer ex.end();

            const head = try ex.begin(&client, .{
                .method = .GET,
                .url = try canned.url(&buf),
                .transfer_buffer = &transfer,
            });

            try testing.expect(head.ok());
            try testing.expectEqual(@as(u64, 5), head.content_length.?);
            // Case-insensitively, because a server picks its own spelling and
            // `ETag` is the one S3 uses.
            try testing.expectEqualStrings("\"d41d8cd9\"", head.header("etag").?);
            try testing.expectEqualStrings("8F2C", head.header("X-AMZ-REQUEST-ID").?);
            try testing.expect(head.header("content-md5") == null);

            const body = try ex.take(&scope, 1 << 20);
            try testing.expectEqualStrings("xxxxx", body.view());
        }
    }.run);
}

test "a body piped out is written rather than held" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            canned.body_len = 4096;

            var served = try io.concurrent(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var client = try started(io, .{});
            defer client.deinit();

            var buf: [64]u8 = undefined;
            var transfer: [1 << 10]u8 = undefined;

            // Where the body goes. No Scope anywhere in this test, which is
            // the property: a 4 KiB object moved through a 1 KiB transfer
            // buffer, and nothing allocated for either.
            var out: [8 << 10]u8 = undefined;
            var w = std.Io.Writer.fixed(&out);

            var ex: fetch.Exchange = .idle;
            defer ex.end();

            _ = try ex.begin(&client, .{
                .method = .GET,
                .url = try canned.url(&buf),
                .transfer_buffer = &transfer,
            });
            const n = try ex.pipe(&w);

            try testing.expectEqual(@as(u64, 4096), n);
            try testing.expectEqual(@as(usize, 4096), w.buffered().len);
            try testing.expectEqual(@as(u8, 'x'), w.buffered()[4095]);
        }
    }.run);
}

test "a streamed body sends exactly the length it announced" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();

            var served = try io.concurrent(Canned.serveWithBody, .{&canned});
            defer served.cancel(io) catch {};

            var client = try started(io, .{});
            defer client.deinit();

            var buf: [64]u8 = undefined;
            var transfer: [1 << 10]u8 = undefined;

            // A reader over bytes already in hand is still a reader, which is
            // what makes this testable without a file: the source of a
            // streamed put is a `*std.Io.Reader` and nothing more.
            var source = std.Io.Reader.fixed("cinta laut dan langit");

            var ex: fetch.Exchange = .idle;
            defer ex.end();

            const head = try ex.begin(&client, .{
                .method = .PUT,
                .url = try canned.url(&buf),
                .content_type = "text/plain",
                .body = .{ .stream = .{ .reader = &source, .len = 21 } },
                .transfer_buffer = &transfer,
            });
            try testing.expect(head.ok());

            served.await(io) catch {};
            const sent = canned.seen[0..canned.seen_len];
            try testing.expect(std.mem.startsWith(u8, sent, "PUT /"));
            try testing.expect(std.mem.indexOf(u8, sent, "content-length: 21") != null);
            try testing.expect(std.mem.indexOf(u8, sent, "content-type: text/plain") != null);
            // Framed by content-length, so the bytes arrive as themselves
            // rather than inside chunk headers a signature never covered.
            try testing.expect(std.mem.indexOf(u8, sent, "chunked") == null);
            try testing.expectEqualStrings(
                "cinta laut dan langit",
                canned.body_seen[0..canned.body_seen_len],
            );
        }
    }.run);
}

test "a body decides the framing, not the method: a DELETE with one and a PATCH without" {
    // Item 73: `std.http.Client` asserts that a DELETE has no body and a
    // PATCH has one, and a real API does both the other way — a bulk delete
    // with `{ids:[…]}`, a `PATCH /users/1/full-suspend` whose whole request
    // is its path. Either tripped a panic in a worker thread (ADR 174).
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();

            var served = try io.concurrent(Canned.serveWithBody, .{&canned});
            defer served.cancel(io) catch {};

            var client = try started(io, .{});
            defer client.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            var buf: [64]u8 = undefined;
            const gone = try client.send(&scope, .DELETE, try canned.url(&buf), "{\"ids\":[1,2,3]}", .{
                .headers = &.{.{ .name = "X-Reason", .value = "expired" }},
            });
            try testing.expectEqual(std.http.Status.ok, gone.status);

            served.await(io) catch {};
            const sent = canned.seen[0..canned.seen_len];
            try testing.expect(std.mem.startsWith(u8, sent, "DELETE /"));
            // The length is written where std left the head's blank line, so
            // it sits after the caller's own headers rather than before them.
            try testing.expect(std.mem.indexOf(u8, sent, "X-Reason: expired\ncontent-length: 15") != null);
            try testing.expectEqualStrings("{\"ids\":[1,2,3]}", canned.body_seen[0..canned.body_seen_len]);
        }
    }.run);

    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();

            var served = try io.concurrent(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var client = try started(io, .{});
            defer client.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            var buf: [64]u8 = undefined;
            const suspended = try client.send(&scope, .PATCH, try canned.url(&buf), null, .{});
            try testing.expectEqual(std.http.Status.ok, suspended.status);

            served.await(io) catch {};
            const sent = canned.seen[0..canned.seen_len];
            try testing.expect(std.mem.startsWith(u8, sent, "PATCH /"));
            // Bodiless the way a body-taking method says it: a length of
            // zero, and nothing chunked.
            try testing.expect(std.mem.indexOf(u8, sent, "content-length: 0") != null);
            try testing.expect(std.mem.indexOf(u8, sent, "chunked") == null);
        }
    }.run);
}

test "a 204 with no content-length ends at its head, and the connection is still good" {
    // Item 76: Garage (hyper) answers a presigned POST with a 204 and no
    // `content-length`, and std's reader framed that as read-to-EOF — so
    // `client.send` sat until the server reaped the idle socket, 120 s for
    // an answer complete in 30 ms. S3's own DELETE is a 204 too (ADR 176).
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            canned.body_len = 3;

            var served = try io.concurrent(Canned.serveNoContentThenOne, .{&canned});
            defer served.cancel(io) catch {};

            var client = try started(io, .{});
            defer client.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            var buf: [64]u8 = undefined;
            const url = try canned.url(&buf);
            // A POST with a body, the shape of the form, and the answer
            // arrives empty rather than after the socket dies.
            const posted = try client.post(&scope, url, "a=b", .{});
            try testing.expectEqual(std.http.Status.no_content, posted.status);
            try testing.expectEqualStrings("", posted.body.view());

            // The same connection, because nothing was left in it to drain:
            // one accept, and the second answer is the second answer rather
            // than three bytes read as the first one's body.
            const next = try client.get(&scope, url, .{});
            try testing.expectEqual(std.http.Status.ok, next.status);
            try testing.expectEqualStrings("xxx", next.body.view());

            served.await(io) catch {};
            try testing.expectEqual(@as(usize, 1), canned.accepted);
        }
    }.run);
}

test "a signed call says its own host and authorization, verbatim" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();

            var served = try io.concurrent(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var client = try started(io, .{});
            defer client.deinit();

            var buf: [64]u8 = undefined;
            var transfer: [1 << 10]u8 = undefined;

            var ex: fetch.Exchange = .idle;
            defer ex.end();

            _ = try ex.begin(&client, .{
                .method = .GET,
                .url = try canned.url(&buf),
                // What SigV4 needs and what std would otherwise decide: the
                // host as it was signed, and an authorization header nobody
                // reformats.
                .host = "bucket.s3.example.com",
                .authorization = "AWS4-HMAC-SHA256 Credential=A/2/us-east-1/s3/aws4_request,Signature=ff",
                .headers = &.{.{ .name = "x-amz-date", .value = "20260817T000000Z" }},
                .transfer_buffer = &transfer,
            });

            served.await(io) catch {};
            const sent = canned.seen[0..canned.seen_len];
            try testing.expect(std.mem.indexOf(u8, sent, "host: bucket.s3.example.com") != null);
            try testing.expect(std.mem.indexOf(u8, sent, "Signature=ff") != null);
            try testing.expect(std.mem.indexOf(u8, sent, "x-amz-date: 20260817T000000Z") != null);
            // The one std would have written from the URL, and did not.
            try testing.expect(std.mem.indexOf(u8, sent, "host: 127.0.0.1") == null);
        }
    }.run);
}

/// Counts what passes through it and forwards the rest.
///
/// `http/budget.zig` has the same twenty lines, and this is not shared with
/// it: a Fitting may not import `nilo_http` (ADR 038), and pushing a test
/// helper down into Core to avoid writing it twice would put something in the
/// vocabulary that no shipped code calls. Twenty duplicated lines is the
/// cheaper of the two.
pub const Counting = struct {
    child: std.mem.Allocator,
    allocs: usize = 0,
    bytes: usize = 0,

    pub fn allocator(self: *Counting) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.allocs += 1;
        self.bytes += len;
        return self.child.vtable.alloc(self.child.ptr, len, a, ra);
    }
    fn resize(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) bool {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        return self.child.vtable.resize(self.child.ptr, m, a, n, ra);
    }
    fn remap(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        return self.child.vtable.remap(self.child.ptr, m, a, n, ra);
    }
    fn free(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, ra: usize) void {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        return self.child.vtable.free(self.child.ptr, m, a, ra);
    }
};

// ---- the ordinary call: JSON out, headers back (ADR 061, ADR 187) ----

test "a JSON body arrives written out, under a content-type the caller did not have to say" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();

            var served = try io.concurrent(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var client = try started(io, .{});
            defer client.deinit();

            var scope: core.Run = .init(std.testing.allocator);
            defer scope.deinit();

            var buf: [64]u8 = undefined;
            const res = try client.postJson(&scope, try canned.url(&buf), .{ .amount = 500, .currency = "idr" }, .{});
            try testing.expect(res.ok());

            served.await(io) catch {};
            const sent = canned.request();
            try testing.expect(std.mem.startsWith(u8, sent, "POST /"));
            try testing.expect(std.mem.indexOf(u8, sent, "content-type: application/json") != null);
            try testing.expectEqual(@as(usize, 1), countLines(sent, "content-type:"));
            try testing.expectEqualStrings("{\"amount\":500,\"currency\":\"idr\"}", canned.requestBody());
        }
    }.run);

    // A `content-type` the caller wrote is the one that goes, once, and the
    // body is still the value written out.
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();

            var served = try io.concurrent(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var client = try started(io, .{});
            defer client.deinit();

            var scope: core.Run = .init(std.testing.allocator);
            defer scope.deinit();

            var buf: [64]u8 = undefined;
            _ = try client.sendJson(&scope, .DELETE, try canned.url(&buf), .{ .ids = [_]u32{ 1, 2, 3 } }, .{
                .headers = &.{.{ .name = "Content-Type", .value = "application/vnd.api+json" }},
            });

            served.await(io) catch {};
            const sent = canned.request();
            try testing.expect(std.mem.startsWith(u8, sent, "DELETE /"));
            try testing.expectEqual(@as(usize, 1), countLines(sent, "content-type:"));
            try testing.expect(std.mem.indexOf(u8, sent, "application/vnd.api+json") != null);
            try testing.expect(std.mem.indexOf(u8, sent, "application/json\n") == null);
            try testing.expectEqualStrings("{\"ids\":[1,2,3]}", canned.requestBody());
        }
    }.run);
}

test "a form body arrives encoded, with its content-type and the OAuth basic authorization beside it" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();

            var served = try io.concurrent(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var client = try started(io, .{});
            defer client.deinit();

            var scope: core.Run = .init(std.testing.allocator);
            defer scope.deinit();

            var buf: [64]u8 = undefined;
            const auth = try fetch.basicAuth(&scope, "my id", "p+q:r s");
            const res = try client.postForm(&scope, try canned.url(&buf), .{
                .grant_type = "client_credentials",
                .scope = "read write",
            }, .{ .headers = &.{.{ .name = "authorization", .value = auth }} });
            try testing.expect(res.ok());

            served.await(io) catch {};
            const sent = canned.request();
            try testing.expect(std.mem.startsWith(u8, sent, "POST /"));
            try testing.expectEqual(@as(usize, 1), countLines(sent, "content-type:"));
            try testing.expect(std.mem.indexOf(u8, sent, "content-type: application/x-www-form-urlencoded") != null);
            try testing.expectEqual(@as(usize, 1), countLines(sent, "authorization:"));
            try testing.expect(std.mem.indexOf(u8, sent, "Basic bXkraWQ6cCUyQnElM0FyK3M=") != null);
            try testing.expectEqualStrings("grant_type=client_credentials&scope=read+write", canned.requestBody());
        }
    }.run);
}

test "a response carries its headers, so the Retry-After off a 429 is one call away" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            canned.reply("429 Too Many Requests", "Retry-After: 30\r\nX-RateLimit-Remaining: 0\r\n", "slow down");

            var served = try io.concurrent(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var client = try started(io, .{});
            defer client.deinit();

            var scope: core.Run = .init(std.testing.allocator);
            defer scope.deinit();

            var buf: [64]u8 = undefined;
            const res = try client.get(&scope, try canned.url(&buf), .{});
            try testing.expectEqual(std.http.Status.too_many_requests, res.status);
            try testing.expectEqualStrings("slow down", res.body.view());

            // Read after the body has been through, which is the whole
            // point: the block was kept before the body read over it.
            try testing.expectEqualStrings("30", res.header("retry-after").?);
            // Case-insensitively, because the server picks its spelling.
            try testing.expectEqualStrings("30", res.header("RETRY-AFTER").?);
            try testing.expectEqualStrings("0", res.header("x-ratelimit-remaining").?);
            // A header the answer did not carry is null, which for `etag`
            // is a fact about the server rather than an error.
            try testing.expect(res.header("etag") == null);
            // The block is the Scope's memory, like the body.
            const start = @intFromPtr(res.headers.ptr);
            const at = @intFromPtr(res.header("retry-after").?.ptr);
            try testing.expect(at >= start and at < start + res.headers.len);
        }
    }.run);
}

// ---- the canned server, for a suite of somebody's own (ADR 061) ----

test "a canned server answers what reply said, and shows the request that reached it" {
    // The shape a caller's own suite writes, end to end, on nothing but the
    // exported type: open, reply, serve, call, assert. `serveOne` reads the
    // body the head announced, so a test about a POST sees what went out.
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try fetch.testing.Canned.open(io);
            defer canned.close();
            canned.reply("201 Created", "Location: /charges/ch_1\r\nContent-Type: application/json\r\n", "{\"id\":\"ch_1\"}");

            var served = try io.concurrent(fetch.testing.Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var client = try started(io, .{});
            defer client.deinit();

            var scope: core.Run = .init(std.testing.allocator);
            defer scope.deinit();

            var buf: [64]u8 = undefined;
            const res = try client.post(&scope, try canned.url(&buf), "amount=500", .{
                .headers = &.{.{ .name = "Idempotency-Key", .value = "k1" }},
            });
            try testing.expectEqual(std.http.Status.created, res.status);
            try testing.expectEqualStrings("/charges/ch_1", res.header("location").?);
            try testing.expectEqualStrings("application/json", res.header("content-type").?);
            try testing.expectEqualStrings("{\"id\":\"ch_1\"}", res.body.view());

            served.await(io) catch {};
            try testing.expect(std.mem.startsWith(u8, canned.request(), "POST / HTTP/1.1\n"));
            try testing.expect(std.mem.indexOf(u8, canned.request(), "Idempotency-Key: k1\n") != null);
            try testing.expectEqualStrings("amount=500", canned.requestBody());
        }
    }.run);
}

test "a call on a warm connection asks the arena for two things, the header block and a body sized by its length" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            canned.body_len = 64;

            var client = try started(io, .{});
            defer client.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            var buf: [64]u8 = undefined;
            const url = try canned.url(&buf);

            // Two requests down one connection, and only the second counted.
            // Opening a connection is where `std.http.Client` allocates its
            // own buffers, and those are a cost of the *connection* rather
            // than of a call — counting them here would report a number no
            // steady-state request ever pays. The same reason `http/app.zig`'s
            // budget test warms the arena before it counts.
            var served = try io.concurrent(Canned.serveKeepAlive, .{ &canned, @as(usize, 2) });
            defer served.cancel(io) catch {};

            _ = try client.get(&scope, url, .{});

            var counting: Counting = .{ .child = testing.allocator };
            var counted: core.Run = .init(counting.allocator());
            defer counted.deinit();

            const res = try client.get(&counted, url, .{});
            try testing.expectEqual(@as(usize, 64), res.body.view().len);

            // Two requests of the arena, in this order: the header block,
            // kept before the body reads over it (ADR 187), and the body,
            // which announced its length and is read into exactly that many
            // bytes (`Exchange.take`). What is counted is the arena's calls
            // on its backing allocator, so this is chunks rather than bumps.
            // It was two chunks while the body was `allocRemaining`'s, which
            // grows past what is left of the chunk the block got; sized, the
            // body fits in it, and the figure is one. A body that did not
            // announce its length is the growing read (`serveChunked`). Raising this needs a reason. It is the same
            // rule ADR 017's second row puts on the inbound path, applied to
            // the way out.
            try testing.expectEqual(@as(usize, 1), counting.allocs);
        }
    }.run);
}

test "a body that ends short of the length it announced is BodyTooShort, not a buffer with a tail of nothing" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            // Claims 100 bytes, sends 40 and closes.
            canned.body_len = 40;
            canned.claim_len = 100;

            var served = try io.concurrent(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var client = try started(io, .{});
            defer client.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            var buf: [64]u8 = undefined;
            const res = client.get(&scope, try canned.url(&buf), .{});
            try testing.expectError(error.BodyTooShort, res);
        }
    }.run);
}

test "a pooled connection the peer already closed costs one retry, not a failure" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            canned.body_len = 12;

            var client = try started(io, .{});
            defer client.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            var buf: [64]u8 = undefined;
            const url = try canned.url(&buf);

            var served = try io.concurrent(Canned.serveThenReap, .{&canned});
            defer served.cancel(io) catch {};

            // The call that leaves a connection in the pool. The server has
            // closed it by the time this returns.
            const first = try client.get(&scope, url, .{});
            try testing.expectEqual(@as(usize, 12), first.body.view().len);

            // And the one that finds it dead. Without the retry this is
            // `error.HttpConnectionClosing` reaching a handler as a 500 that
            // nothing about the request deserved.
            const second = try client.get(&scope, url, .{});
            try testing.expectEqual(@as(usize, 12), second.body.view().len);

            // Two connections for two calls, which is the shape of the fix:
            // the second call did not reuse the corpse, it dialled again.
            try testing.expectEqual(@as(usize, 2), canned.accepted);
        }
    }.run);
}

test "a pooled connection the peer reset costs one retry too" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            canned.body_len = 12;

            var client = try started(io, .{});
            defer client.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            var buf: [64]u8 = undefined;
            const url = try canned.url(&buf);

            var served = try io.concurrent(Canned.serveThenReset, .{&canned});
            defer served.cancel(io) catch {};

            const first = try client.get(&scope, url, .{});
            try testing.expectEqual(@as(usize, 12), first.body.view().len);

            // The same reaped connection as the test above, closed the other
            // way round: this request reaches the socket before the peer lets
            // go of it, so what comes back is an RST and `receiveHead` reports
            // `ReadFailed` rather than `HttpConnectionClosing`. Nothing was
            // answered either way, which is what `Exchange.nothingCameBack`
            // is for.
            const second = try client.get(&scope, url, .{});
            try testing.expectEqual(@as(usize, 12), second.body.view().len);

            try testing.expectEqual(@as(usize, 2), canned.accepted);
        }
    }.run);
}

test "a streamed body is sent on a fresh connection, so a pooled one the peer reaped cannot eat the reader" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            canned.body_len = 4;

            var client = try started(io, .{ .timeout_ms = 5_000 });
            defer client.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            var buf: [64]u8 = undefined;
            const url = try canned.url(&buf);

            var served = try io.concurrent(Canned.serveReapThenBody, .{&canned});
            defer served.cancel(io) catch {};

            // Leaves one connection in the pool, which the server then closes.
            _ = try client.get(&scope, url, .{});
            for (0..2_000) |_| {
                if (canned.reaped.load(.acquire)) break;
                try std.Io.sleep(io, .fromMilliseconds(1), .awake);
            } else return error.TestTimedOut;

            // A reader body cannot be replayed, so before this it was sent on
            // the corpse, consumed, and failed. On a fresh connection there
            // is nothing to be stale.
            var source = std.Io.Reader.fixed("cinta laut dan langit");
            var ex: fetch.Exchange = .idle;
            defer ex.end();
            const head = try ex.begin(&client, .{
                .method = .PUT,
                .url = url,
                .body = .{ .stream = .{ .reader = &source, .len = 21 } },
            });
            try testing.expect(head.ok());
            try testing.expectEqual(@as(usize, 2), canned.accepted);
            served.await(io) catch {};
            try testing.expectEqualStrings("cinta laut dan langit", canned.requestBody());
        }
    }.run);
}

test "a body going out that keeps moving is not a stall, however long it takes" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();

            var served = try io.concurrent(Canned.serveWithBody, .{&canned});
            defer served.cancel(io) catch {};

            // Nothing arrives from the peer while this goes out, so before the
            // upload counted as progress this was `Stalled` once the bound
            // ran out: 24 bytes 60 ms apart is 1.44 s under a one-second
            // bound, and every gap is well inside it. A second rather than
            // 150 ms for the reason the download twin above gives: the gaps
            // are sleeps, and on the loaded macOS runner a 60 ms sleep went
            // past 150 on every run.
            var client = try started(io, .{ .timeout_ms = 0, .stall_ms = 1000 });
            defer client.deinit();

            var buf: [64]u8 = undefined;
            var source: fetch.testing.Dribble = .init(io, 24, 60);
            var ex: fetch.Exchange = .idle;
            defer ex.end();
            const head = try ex.begin(&client, .{
                .method = .PUT,
                .url = try canned.url(&buf),
                .body = .{ .stream = .{ .reader = &source.reader, .len = 24 } },
            });
            try testing.expect(head.ok());
            try testing.expectEqualStrings(&@as([24]u8, @splat('y')), canned.requestBody());
        }
    }.run);
}

test "a body going out to a peer that stopped reading is a stall" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();

            // Reads the head and then nothing: the upload's gap outlasts the
            // bound on its own, which is the source going quiet.
            var served = try io.concurrent(Canned.serveWithBody, .{&canned});
            defer served.cancel(io) catch {};

            var client = try started(io, .{ .timeout_ms = 0, .stall_ms = 100 });
            defer client.deinit();

            var buf: [64]u8 = undefined;
            var source: fetch.testing.Dribble = .init(io, 2, 1_500);
            var ex: fetch.Exchange = .idle;
            defer ex.end();
            const began = core.monotonicMicros();
            try testing.expectError(error.Stalled, ex.begin(&client, .{
                .method = .PUT,
                .url = try canned.url(&buf),
                .body = .{ .stream = .{ .reader = &source.reader, .len = 2 } },
            }));
            try testing.expect(core.monotonicMicros() - began < 1_200 * std.time.us_per_ms);
        }
    }.run);
}

// ---- a target is a type, and a path is a template (ADR 061) ----

test "a target's standing headers go out on every call, and the call's own line goes instead of one" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();

            var client = try started(io, .{});
            defer client.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();
            var buf: [64]u8 = undefined;
            const base = try canned.url(&buf);

            const Api = fetch.Target("api", .{});
            var api = try Api.open(&client, .{
                .base = base,
                .authorization = "Bearer standing",
                .user_agent = "nilo-test",
                .headers = &.{ .{ .name = "accept", .value = "application/json" }, .{ .name = "x-tenant", .value = "acme" } },
            });

            // Nothing on the call: every standing line arrives, once, and
            // the path's segment is encoded with the slash as data.
            {
                canned.seen_len = 0;
                var served = try io.concurrent(Canned.serveOne, .{&canned});
                defer served.cancel(io) catch {};
                _ = try api.get(&scope, "/v1/charges/{}", .{scope.str("ch/1")}, .{});
                served.await(io) catch {};
                const seen = canned.request();
                try testing.expect(std.mem.startsWith(u8, seen, "GET /v1/charges/ch%2F1 "));
                try testing.expect(std.mem.indexOf(u8, seen, "authorization: Bearer standing") != null);
                try testing.expect(std.mem.indexOf(u8, seen, "user-agent: nilo-test") != null);
                try testing.expect(std.mem.indexOf(u8, seen, "accept: application/json") != null);
                try testing.expect(std.mem.indexOf(u8, seen, "x-tenant: acme") != null);
                try testing.expectEqual(@as(usize, 1), std.mem.count(u8, seen, "authorization:"));
                try testing.expectEqual(@as(usize, 1), std.mem.count(u8, seen, "user-agent:"));
            }

            // The call's own `authorization` and `accept` go instead of the
            // standing ones — one line each, the caller's — and the standing
            // header the call did not name still arrives.
            {
                canned.seen_len = 0;
                var served = try io.concurrent(Canned.serveOne, .{&canned});
                defer served.cancel(io) catch {};
                _ = try api.get(&scope, "/v1/me", .{}, .{ .headers = &.{
                    .{ .name = "Authorization", .value = "Bearer mine" },
                    .{ .name = "Accept", .value = "text/csv" },
                } });
                served.await(io) catch {};
                const seen = canned.request();
                try testing.expect(std.mem.indexOf(u8, seen, "Authorization: Bearer mine") != null);
                try testing.expect(std.mem.indexOf(u8, seen, "standing") == null);
                try testing.expect(std.mem.indexOf(u8, seen, "Accept: text/csv") != null);
                try testing.expect(std.mem.indexOf(u8, seen, "application/json") == null);
                try testing.expect(std.mem.indexOf(u8, seen, "x-tenant: acme") != null);
                try testing.expect(std.mem.indexOf(u8, seen, "user-agent: nilo-test") != null);
            }
        }
    }.run);
}

test "a target's JSON call and its query arrive, and the target's own clock bounds the call" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();

            var client = try started(io, .{});
            defer client.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();
            var buf: [64]u8 = undefined;
            const base = try canned.url(&buf);

            const Api = fetch.Target("api", .{ .timeout_ms = 200 });
            var api = try Api.open(&client, .{ .base = base });

            {
                canned.seen_len = 0;
                canned.body_seen_len = 0;
                var served = try io.concurrent(Canned.serveOne, .{&canned});
                defer served.cancel(io) catch {};
                const cursor: ?[]const u8 = null;
                _ = try api.postJson(&scope, "/v1/charges/{id}/refunds", .{ .id = "ch_1", .limit = 10, .cursor = cursor }, .{ .amount = 500 }, .{});
                served.await(io) catch {};
                try testing.expect(std.mem.startsWith(u8, canned.request(), "POST /v1/charges/ch_1/refunds?limit=10 "));
                try testing.expect(std.mem.indexOf(u8, canned.request(), "content-type: application/json") != null);
                try testing.expectEqualStrings("{\"amount\":500}", canned.requestBody());
            }

            // The target says 200 ms where the client says thirty seconds,
            // and a server that answers nothing is `TimedOut` by the
            // target's number.
            {
                var served = try io.concurrent(Canned.serveSilence, .{&canned});
                defer served.cancel(io) catch {};
                const began = core.monotonicMicros();
                try testing.expectError(error.TimedOut, api.get(&scope, "/slow", .{}, .{}));
                const took_ms = @divTrunc(core.monotonicMicros() - began, std.time.us_per_ms);
                try testing.expect(took_ms < 5_000);
            }
        }
    }.run);
}

test "a target's form call fills the path and sends the fields as the body" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();

            var served = try io.concurrent(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var client = try started(io, .{});
            defer client.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();
            var buf: [64]u8 = undefined;

            const Api = fetch.Target("api", .{});
            var api = try Api.open(&client, .{ .base = try canned.url(&buf) });

            _ = try api.putForm(&scope, "/v1/clients/{id}", .{ .id = "c 1" }, .{ .name = "a b", .active = true }, .{});
            served.await(io) catch {};
            try testing.expect(std.mem.startsWith(u8, canned.request(), "PUT /v1/clients/c%201 "));
            try testing.expectEqual(@as(usize, 1), countLines(canned.request(), "content-type:"));
            try testing.expect(std.mem.indexOf(u8, canned.request(), "content-type: application/x-www-form-urlencoded") != null);
            try testing.expectEqualStrings("name=a+b&active=true", canned.requestBody());
        }
    }.run);
}

test "a target's own permit is given back after every call, and its ready path is what the health route asks" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();

            var client = try started(io, .{ .max_body = 1024 });
            defer client.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();
            var buf: [64]u8 = undefined;
            const base = try canned.url(&buf);

            const Api = fetch.Target("api", .{ .max_in_flight = 1, .ready = "/status" });
            var api = try Api.open(&client, .{ .base = base });
            try testing.expectEqual(@as(usize, 1), api.gate.permits);

            // A call that succeeds and one that is refused mid-body both
            // give the permit back; the gate is what bounds this service and
            // a permit lost to an error would close it one call at a time.
            {
                canned.body_len = 8;
                var served = try io.concurrent(Canned.serveOne, .{&canned});
                defer served.cancel(io) catch {};
                _ = try api.get(&scope, "/ok", .{}, .{});
                served.await(io) catch {};
                try testing.expectEqual(@as(usize, 1), api.gate.permits);
            }
            {
                canned.body_len = 4096;
                var served = try io.concurrent(Canned.serveOne, .{&canned});
                defer served.cancel(io) catch {};
                try testing.expectError(error.BodyTooLarge, api.get(&scope, "/big", .{}, .{}));
                served.await(io) catch {};
                try testing.expectEqual(@as(usize, 1), api.gate.permits);
            }

            // The health route: a 2xx from the ready path is ready, and
            // anything else names the target.
            var any: core.AnyScope = .of(&scope);
            {
                canned.reply("200 OK", "", "up");
                canned.seen_len = 0;
                var served = try io.concurrent(Canned.serveOne, .{&canned});
                defer served.cancel(io) catch {};
                try testing.expect(api.nilo_ready(&any) == null);
                served.await(io) catch {};
                try testing.expect(std.mem.startsWith(u8, canned.request(), "GET /status "));
            }
            {
                canned.reply("503 Service Unavailable", "", "down");
                var served = try io.concurrent(Canned.serveOne, .{&canned});
                defer served.cancel(io) catch {};
                try testing.expectEqualStrings("api answered outside 2xx", api.nilo_ready(&any).?);
                served.await(io) catch {};
            }
        }
    }.run);
}

/// What a server does that refuses a request on its head: read the head,
/// answer, and close with the body still unread, which the kernel turns into
/// an RST. `accepted` counts connections so a test can say none was reused.
fn answerEarly(canned: *Canned, status: []const u8, body: []const u8, count: usize) !void {
    for (0..count) |_| {
        var stream = try canned.server.accept(canned.io);
        defer stream.close(canned.io);
        canned.accepted += 1;
        var in_buf: [4 << 10]u8 = undefined;
        var reader = stream.reader(canned.io, &in_buf);
        while (std.mem.trimEnd(u8, try reader.interface.takeDelimiterInclusive('\n'), "\r\n").len != 0) {}
        var out_buf: [1 << 10]u8 = undefined;
        var writer = stream.writer(canned.io, &out_buf);
        try writer.interface.print(
            "HTTP/1.1 {s}\r\nContent-Type: application/xml\r\nContent-Length: {d}\r\n\r\n{s}",
            .{ status, body.len, body },
        );
        try writer.interface.flush();
    }
}

test "a refusal sent before the body was finished is the answer, not WriteFailed" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();

            const xml = "<Error><Code>AuthorizationHeaderMalformed</Code></Error>";
            var served = try io.concurrent(answerEarly, .{ &canned, "400 Bad Request", xml, @as(usize, 2) });
            defer served.cancel(io) catch {};

            var client = try started(io, .{});
            defer client.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            // **Far past what loopback buffers**, so the write is still going
            // when the server's close arrives and really fails. A body that
            // fits the send and receive buffers is written whole before the
            // answer is read, and proves nothing.
            const big = try testing.allocator.alloc(u8, 64 << 20);
            defer testing.allocator.free(big);
            @memset(big, 'x');

            var buf: [64]u8 = undefined;
            const url = try canned.url(&buf);
            const res = try client.put(&scope, url, big, .{});
            try testing.expectEqual(std.http.Status.bad_request, res.status);
            try testing.expectEqualStrings(xml, res.body.view());

            // The connection the request was left half-written on is not
            // reused: the second call is a second accept.
            _ = try client.put(&scope, url, big, .{});
            try testing.expectEqual(@as(usize, 2), canned.accepted);
        }
    }.run);
}

/// A server that answers each request it reads and then closes the socket,
/// without ever saying `Connection: close`: the idle-reaping server of a
/// load balancer, as far as a pooled client can tell. It takes `count`
/// requests, each on a connection of its own, and reads a body the head
/// announced before it answers, so the close is a FIN and nothing is left
/// unread to turn it into an RST.
fn serveEachThenClose(canned: *Canned, count: usize) !void {
    for (0..count) |_| {
        var stream = try canned.server.accept(canned.io);
        defer stream.close(canned.io);
        canned.accepted += 1;

        var in_buf: [4 << 10]u8 = undefined;
        var reader = stream.reader(canned.io, &in_buf);
        var body_len: usize = 0;
        while (true) {
            const line = try reader.interface.takeDelimiterInclusive('\n');
            const trimmed = std.mem.trimEnd(u8, line, "\r\n");
            if (trimmed.len == 0) break;
            if (std.ascii.startsWithIgnoreCase(trimmed, "content-length:")) {
                body_len = std.fmt.parseInt(usize, std.mem.trim(u8, trimmed["content-length:".len..], " \t"), 10) catch 0;
            }
        }
        if (body_len != 0) _ = try reader.interface.discard(.limited(body_len));

        var out_buf: [256]u8 = undefined;
        var writer = stream.writer(canned.io, &out_buf);
        try writer.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok");
        try writer.interface.flush();
    }
}

/// Three calls of one kind on one client, against a server that closes after
/// every answer. The first leaves a connection in the pool and the server
/// closes it; the next two find a corpse, and each must be dialled again.
fn threeCallsAcrossReaping(io: std.Io, comptime kind: enum { get, put_form, post_json }) !void {
    var canned = try Canned.open(io);
    defer canned.close();

    var client = try started(io, .{ .timeout_ms = 5_000 });
    defer client.deinit();

    var scope: core.Run = .init(testing.allocator);
    defer scope.deinit();

    var buf: [64]u8 = undefined;
    const url = try canned.url(&buf);

    var served = try io.concurrent(serveEachThenClose, .{ &canned, @as(usize, 3) });
    defer served.cancel(io) catch {};

    for (0..3) |_| {
        const res = switch (kind) {
            .get => try client.get(&scope, url, .{}),
            .put_form => try client.putForm(&scope, url, .{ .name = "a b", .active = true }, .{}),
            .post_json => try client.postJson(&scope, url, .{ .amount = 500 }, .{}),
        };
        try testing.expectEqualStrings("ok", res.body.view());
        // Let the server's close land before the next call, so that the
        // call finds the corpse rather than racing the FIN.
        try std.Io.sleep(io, .fromMilliseconds(20), .awake);
    }
    try testing.expectEqual(@as(usize, 3), canned.accepted);
}

test "a pooled connection the peer closed after answering is dialled again for a bodiless call" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            try threeCallsAcrossReaping(io, .get);
        }
    }.run);
}

test "a pooled connection the peer closed after answering is dialled again for a form body" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            try threeCallsAcrossReaping(io, .put_form);
        }
    }.run);
}

test "a pooled connection the peer closed after answering is dialled again for a JSON body" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            try threeCallsAcrossReaping(io, .post_json);
        }
    }.run);
}

test "a body write that fails on a connection just dialled is not sent again" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();

            var client = try started(io, .{ .timeout_ms = 5_000 });
            defer client.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            var buf: [64]u8 = undefined;
            const url = try canned.url(&buf);

            // The server takes a connection and closes it without reading or
            // answering, as often as it is dialled. The reset is the same one
            // a reaped connection gives, so the only thing that tells this
            // call from the stale ones above is that it dialled the
            // connection itself: sending it again would be a retry policy,
            // and `accepted` would say two.
            const Reset = struct {
                fn serve(c: *Canned) !void {
                    while (true) {
                        var stream = try c.server.accept(c.io);
                        c.accepted += 1;
                        stream.close(c.io);
                    }
                }
            };
            var served = try io.concurrent(Reset.serve, .{&canned});
            defer served.cancel(io) catch {};

            const big = try testing.allocator.alloc(u8, 64 << 20);
            defer testing.allocator.free(big);
            @memset(big, 'x');

            try testing.expectError(error.WriteFailed, client.put(&scope, url, big, .{}));
            try testing.expectEqual(@as(usize, 1), canned.accepted);
        }
    }.run);
}

// ---- an egress proxy and a private authority (ADR 267) ----

/// `http://ann:pw@127.0.0.1:<port>`, the proxy a test points at a Canned.
fn proxyUrl(buf: []u8, port: u16) ![]const u8 {
    return std.fmt.bufPrint(buf, "http://ann:pw@127.0.0.1:{d}", .{port});
}

test "an http call goes to the proxy in full form, with the proxy's credentials and nobody else's" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var proxy = try Canned.open(io);
            defer proxy.close();
            proxy.reply("200 OK", "", "ok");

            var purl: [96]u8 = undefined;
            var client = try started(io, .{ .proxy = .{ .url = try proxyUrl(&purl, proxy.port) } });
            defer client.deinit();
            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            var served = try io.concurrent(Canned.serveOne, .{&proxy});
            defer served.cancel(io) catch {};
            // `service.test` is not a name that resolves: reaching the proxy
            // at all is the proof that it is the proxy that was dialled.
            const res = try client.get(&scope, "http://service.test/v1/x?y=1", .{ .headers = &.{.{ .name = "X-Trace", .value = "t1" }} });
            served.await(io) catch {};
            try testing.expectEqualStrings("ok", res.body.view());

            const seen = proxy.request();
            try testing.expect(std.mem.startsWith(u8, seen, "GET http://service.test/v1/x?y=1 HTTP/1.1"));
            try testing.expect(std.mem.indexOf(u8, seen, "host: service.test") != null);
            // base64("ann:pw")
            try testing.expect(std.mem.indexOf(u8, seen, "proxy-authorization: Basic YW5uOnB3") != null);
            try testing.expect(carries(seen, "x-trace"));
            // The proxy's credential is the proxy's: the origin's line is not it.
            try testing.expect(!carries(seen, "authorization"));
        }
    }.run);
}

test "a host on the bypass list is dialled directly, in origin form, with no proxy line" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var origin = try Canned.open(io);
            defer origin.close();
            origin.reply("200 OK", "", "direct");

            // The proxy is a port nothing listens on: a call that went to it
            // would fail to connect instead of answering.
            var client = try started(io, .{ .proxy = .{
                .url = "http://ann:pw@127.0.0.1:1",
                .bypass = &.{"127.0.0.1"},
            } });
            defer client.deinit();
            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            var served = try io.concurrent(Canned.serveOne, .{&origin});
            defer served.cancel(io) catch {};
            var buf: [64]u8 = undefined;
            const res = try client.get(&scope, try origin.url(&buf), .{});
            served.await(io) catch {};
            try testing.expectEqualStrings("direct", res.body.view());
            try testing.expect(std.mem.startsWith(u8, origin.request(), "GET / HTTP/1.1"));
            try testing.expect(!carries(origin.request(), "proxy-authorization"));
        }
    }.run);
}

test "a redirect from the proxy to a bypassed host leaves the proxy's credential and the call's own behind" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var proxy = try Canned.open(io);
            defer proxy.close();
            var origin = try Canned.open(io);
            defer origin.close();
            var where: [96]u8 = undefined;
            proxy.reply("302 Found", try std.fmt.bufPrint(&where, "Location: http://127.0.0.1:{d}/after\r\n", .{origin.port}), "");
            origin.reply("200 OK", "", "landed");

            var purl: [96]u8 = undefined;
            var client = try started(io, .{ .proxy = .{
                .url = try proxyUrl(&purl, proxy.port),
                .bypass = &.{"127.0.0.1"},
            } });
            defer client.deinit();
            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            var served_proxy = try io.concurrent(Canned.serveOne, .{&proxy});
            defer served_proxy.cancel(io) catch {};
            var served_origin = try io.concurrent(Canned.serveOne, .{&origin});
            defer served_origin.cancel(io) catch {};
            const res = try client.get(&scope, "http://service.test/start", .{ .headers = &.{.{ .name = "Authorization", .value = "Bearer mine" }} });
            served_proxy.await(io) catch {};
            served_origin.await(io) catch {};
            try testing.expectEqualStrings("landed", res.body.view());

            // The first hop went to the proxy with both lines, the second
            // straight to the origin with neither.
            try testing.expect(std.mem.startsWith(u8, proxy.request(), "GET http://service.test/start "));
            try testing.expect(carries(proxy.request(), "proxy-authorization"));
            try testing.expect(carries(proxy.request(), "authorization"));
            try testing.expect(std.mem.startsWith(u8, origin.request(), "GET /after "));
            try testing.expect(!carries(origin.request(), "proxy-authorization"));
            try testing.expect(!carries(origin.request(), "authorization"));
        }
    }.run);
}

test "an https call the proxy would carry is refused before anything is dialled" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            // Nothing listens on port 1, so a dial would be `ConnectionRefused`.
            var client = try started(io, .{ .proxy = .{ .url = "http://127.0.0.1:1", .bypass = &.{"127.0.0.1"} } });
            defer client.deinit();
            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            try testing.expectError(error.TlsThroughProxy, client.get(&scope, "https://service.test/", .{}));
            // A bypassed name is not the proxy's, so it is dialled itself,
            // and refused by the port, which is the proof it was.
            if (client.get(&scope, "https://127.0.0.1:1/", .{})) |_| return error.TestUnexpectedResult else |err| {
                try testing.expect(err != error.TlsThroughProxy);
            }
        }
    }.run);
}

test "a proxy that is not an http or https URL with a host stops the client at start" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            for ([_][]const u8{ "ftp://proxy.test:21", "http://", "proxy.test:3128", "socks5://proxy.test:1080" }) |bad| {
                var client: fetch.Client = .init(testing.allocator, .{ .proxy = .{ .url = bad } });
                defer client.deinit();
                try testing.expectError(error.InvalidProxy, client.nilo_start(io, .none));
            }
        }
    }.run);
}

/// A self-signed authority generated for this test and good for a hundred
/// years; it signs nothing and is trusted by nothing.
const test_authority =
    \\MIIBojCCAUmgAwIBAgIUFMgMuZxLhrwIcpSKUkJN8x8MbcAwCgYIKoZIzj0EAwIw
    \\JjEkMCIGA1UEAwwbbmlsbyB0ZXN0IHByaXZhdGUgYXV0aG9yaXR5MCAXDTI2MTAw
    \\OTA0NTg1M1oYDzIxMjYwOTE1MDQ1ODUzWjAmMSQwIgYDVQQDDBtuaWxvIHRlc3Qg
    \\cHJpdmF0ZSBhdXRob3JpdHkwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAAR/PGWJ
    \\ZFYFmca/o7F/EpjWobb9iwZ71r0Y0taxrVnpQKFAIFdRTGrLsmhx0rkR63Dyp9PW
    \\KyTvy3eeVlPpjeaYo1MwUTAdBgNVHQ4EFgQUv0p4rQME5j+xd4ABHPjn6SooDZww
    \\HwYDVR0jBBgwFoAUv0p4rQME5j+xd4ABHPjn6SooDZwwDwYDVR0TAQH/BAUwAwEB
    \\/zAKBggqhkjOPQQDAgNHADBEAiA3CpcNEqjpEFUp78cJShyEPPXt6nBTrlO/QGLU
    \\h/nO8wIgNco76dCkJFtOebzwSZKxx2AuhCF4/hCeN+Zio5pbpm8=
;

test "a bundle the caller loaded is the one both clients trust, and the client never frees it" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            if (std.http.Client.disable_tls) return error.SkipZigTest;
            const gpa = testing.allocator;
            var roots: std.crypto.Certificate.Bundle = .empty;
            defer roots.deinit(gpa);

            // One certificate, decoded the way `Bundle.addCertsFromFile` does
            // it, from text instead of a file.
            const decoder = std.base64.standard.decoderWithIgnore("\n");
            const der = try gpa.alloc(u8, decoder.calcSizeUpperBound(test_authority.len));
            defer gpa.free(der);
            const len = try decoder.decode(der, test_authority);
            try roots.bytes.appendSlice(gpa, der[0..len]);
            try roots.parseCert(gpa, 0, std.Io.Clock.real.now(io).toSeconds());
            try testing.expectEqual(@as(u32, 1), roots.map.count());

            var client: fetch.Client = .init(gpa, .{ .roots = &roots });
            try client.nilo_start(io, .none);
            // A time is what tells std the bundle is final and that the
            // system is not to be scanned for.
            try testing.expect(client.inner.now != null);
            try testing.expect(client.fresh.now != null);
            // Both read the caller's bundle.
            try testing.expectEqual(@as(u32, 1), client.inner.ca_bundle.map.count());
            try testing.expectEqual(@as(u32, 1), client.fresh.ca_bundle.map.count());
            // `deinit` hands it back: std would free it twice, and again
            // under the caller's own `deinit` above, if it did not.
            client.deinit();
            try testing.expectEqual(@as(u32, 1), roots.map.count());
        }
    }.run);
}
