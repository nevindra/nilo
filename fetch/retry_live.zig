//! A target's `.retry` against a canned server that answers a script: the
//! tries, the keys, the waits, the budget and the deadline
//! ([ADR 271](../docs/adr/271-a-retry-is-the-callers-numbers-and-nilos-mechanism.md)).
//! Everything runs on `std.Io.Threaded`, like the rest of the module's live
//! tests, with a server started by `io.concurrent`.

const std = @import("std");
const core = @import("nilo_core");
const fetch = @import("fetch.zig");
const live = @import("live.zig");

const testing = std.testing;
const Canned = fetch.testing.Canned;
const Reply = fetch.testing.Reply;

fn withIo(comptime body: fn (std.Io) anyerror!void) !void {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    try body(threaded.io());
}

fn started(io: std.Io) !fetch.Client {
    var client: fetch.Client = .init(testing.allocator, .{});
    try client.nilo_start(io, .none);
    return client;
}

const unavailable: Reply = .{ .status = "503 Service Unavailable", .body = "later" };
const fine: Reply = .{ .body = "done" };

/// A Scope that carries a deadline, as a `Ctx` does (ADR 105).
const Timed = struct {
    run: core.Run,
    left: u32,

    pub fn arena(self: *Timed) std.mem.Allocator {
        return self.run.arena();
    }

    pub fn str(self: *Timed, bytes: []const u8) core.Str {
        return self.run.str(bytes);
    }

    pub fn timeLeftMs(self: *const Timed) ?u32 {
        return self.left;
    }
};

const quick: fetch.Retry = .{ .times = 3, .backoff = .{ .fixed_ms = 2 } };

test "a 503 is tried again and the 200 after it is the answer" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            var client = try started(io);
            defer client.deinit();
            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();
            var buf: [64]u8 = undefined;
            const Api = fetch.Target("api", .{ .retry = quick });
            var api = try Api.open(&client, .{ .base = try canned.url(&buf) });

            var served = try io.concurrent(Canned.serveScript, .{ &canned, &[_]Reply{ unavailable, fine }, 2 });
            defer served.cancel(io) catch {};
            const res = try api.get(&scope, "/v1/me", .{}, .{});
            try testing.expect(res.ok());
            try testing.expectEqualStrings("done", res.body.view());
            try testing.expectEqual(@as(usize, 2), canned.tried.count);
        }
    }.run);
}

test "a service that keeps saying later is asked times plus one and then heard" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            var client = try started(io);
            defer client.deinit();
            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();
            var buf: [64]u8 = undefined;
            const Api = fetch.Target("api", .{ .retry = quick });
            var api = try Api.open(&client, .{ .base = try canned.url(&buf) });

            var served = try io.concurrent(Canned.serveScript, .{ &canned, &[_]Reply{unavailable}, 4 });
            defer served.cancel(io) catch {};
            const res = try api.get(&scope, "/v1/me", .{}, .{});
            // The last answer is handed over as itself, not as an error.
            try testing.expectEqual(std.http.Status.service_unavailable, res.status);
            try testing.expectEqual(@as(usize, 4), canned.tried.count);
        }
    }.run);
}

test "a POST with no key is sent once and one with a key is sent again under the same key" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            var client = try started(io);
            defer client.deinit();
            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();
            var buf: [64]u8 = undefined;
            const Api = fetch.Target("api", .{ .retry = quick });
            var api = try Api.open(&client, .{ .base = try canned.url(&buf) });

            {
                var served = try io.concurrent(Canned.serveScript, .{ &canned, &[_]Reply{ unavailable, fine }, 1 });
                defer served.cancel(io) catch {};
                const res = try api.post(&scope, "/charges", .{}, "amount=5", .{});
                try testing.expectEqual(std.http.Status.service_unavailable, res.status);
                try testing.expectEqual(@as(usize, 1), canned.tried.count);
            }

            canned.tried.count = 0;
            {
                var served = try io.concurrent(Canned.serveScript, .{ &canned, &[_]Reply{ unavailable, fine }, 2 });
                defer served.cancel(io) catch {};
                const res = try api.post(&scope, "/charges", .{}, "amount=5", .{ .headers = &.{
                    .{ .name = "Idempotency-Key", .value = "order-7" },
                } });
                try testing.expect(res.ok());
                try testing.expectEqual(@as(usize, 2), canned.tried.count);
                try testing.expect(std.mem.indexOf(u8, canned.headOfTry(0), "Idempotency-Key: order-7") != null);
                try testing.expect(std.mem.indexOf(u8, canned.headOfTry(1), "Idempotency-Key: order-7") != null);
            }
        }
    }.run);
}

test "a type that mints keys sends a POST again, under one key the caller never wrote" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            var client = try started(io);
            defer client.deinit();
            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();
            var buf: [64]u8 = undefined;
            const Api = fetch.Target("api", .{ .retry = .{ .times = 2, .backoff = .{ .fixed_ms = 2 }, .mint_key = "Idempotency-Key" } });
            var api = try Api.open(&client, .{ .base = try canned.url(&buf) });

            var served = try io.concurrent(Canned.serveScript, .{ &canned, &[_]Reply{ unavailable, fine }, 2 });
            defer served.cancel(io) catch {};
            const res = try api.postJson(&scope, "/charges", .{}, .{ .amount = 5 }, .{});
            try testing.expect(res.ok());
            try testing.expectEqual(@as(usize, 2), canned.tried.count);

            const first = keyOf(canned.headOfTry(0)) orelse return error.NoKeyOnTheFirstTry;
            const second = keyOf(canned.headOfTry(1)) orelse return error.NoKeyOnTheSecondTry;
            try testing.expectEqual(@as(usize, 32), first.len);
            try testing.expectEqualStrings(first, second);
        }
    }.run);
}

fn keyOf(head: []const u8) ?[]const u8 {
    const needle = "Idempotency-Key: ";
    const at = std.mem.indexOf(u8, head, needle) orelse return null;
    const rest = head[at + needle.len ..];
    return rest[0 .. std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len];
}

test "a Retry-After longer than the cap is waited for at the cap, not at what it said" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            var client = try started(io);
            defer client.deinit();
            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();
            var buf: [64]u8 = undefined;
            const Api = fetch.Target("api", .{ .retry = .{ .times = 1, .backoff = .{ .fixed_ms = 1 }, .retry_after_max_ms = 150 } });
            var api = try Api.open(&client, .{ .base = try canned.url(&buf) });

            const slow: Reply = .{ .status = "429 Too Many Requests", .headers = "Retry-After: 3600\r\n" };
            var served = try io.concurrent(Canned.serveScript, .{ &canned, &[_]Reply{ slow, fine }, 2 });
            defer served.cancel(io) catch {};
            const res = try api.get(&scope, "/v1/me", .{}, .{});
            try testing.expect(res.ok());
            const gap_ms = @divFloor(canned.tried.at_us[1] - canned.tried.at_us[0], 1000);
            // Honoured: well past the 1 ms backoff. Capped: nowhere near an hour.
            try testing.expect(gap_ms >= 140);
            try testing.expect(gap_ms < 3_000);
        }
    }.run);
}

test "retries stop at the budget when most calls fail" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            var client = try started(io);
            defer client.deinit();
            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();
            var buf: [64]u8 = undefined;
            const Api = fetch.Target("api", .{ .retry = .{
                .times = 2,
                .backoff = .{ .fixed_ms = 1 },
                .budget = .{ .percent = 20, .min_per_sec = 0, .window_s = 10 },
            } });
            var api = try Api.open(&client, .{ .base = try canned.url(&buf) });

            // Ten calls to a service that fails every one. At 20 percent the
            // tenth call has earned two retries in all, so the service sees
            // the ten it was given and two more, where three tries each
            // would have sent it thirty.
            var served = try io.concurrent(Canned.serveScript, .{ &canned, &[_]Reply{unavailable}, 12 });
            defer served.cancel(io) catch {};
            for (0..10) |_| {
                const res = try api.get(&scope, "/v1/me", .{}, .{});
                try testing.expectEqual(std.http.Status.service_unavailable, res.status);
            }
            try testing.expectEqual(@as(usize, 12), canned.tried.count);
        }
    }.run);
}

test "a route with no time for the wait gets the answer it has, with no second try" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            var client = try started(io);
            defer client.deinit();
            var scope: Timed = .{ .run = .init(testing.allocator), .left = 100 };
            defer scope.run.deinit();
            var buf: [64]u8 = undefined;
            // A wait of 400 ms and a route that has 100 left.
            const Api = fetch.Target("api", .{ .retry = .{ .times = 3, .backoff = .{ .fixed_ms = 400 } } });
            var api = try Api.open(&client, .{ .base = try canned.url(&buf) });

            var served = try io.concurrent(Canned.serveScript, .{ &canned, &[_]Reply{ unavailable, fine }, 2 });
            defer served.cancel(io) catch {};
            const began = core.monotonicMicros();
            const res = try api.get(&scope, "/v1/me", .{}, .{});
            try testing.expectEqual(std.http.Status.service_unavailable, res.status);
            try testing.expectEqual(@as(usize, 1), canned.tried.count);
            // And it did not sleep on the way to finding that out.
            try testing.expect(core.monotonicMicros() - began < 300 * std.time.us_per_ms);
        }
    }.run);
}

test "a route that has time for one wait gets the second try" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            var client = try started(io);
            defer client.deinit();
            var scope: Timed = .{ .run = .init(testing.allocator), .left = 5_000 };
            defer scope.run.deinit();
            var buf: [64]u8 = undefined;
            const Api = fetch.Target("api", .{ .retry = .{ .times = 3, .backoff = .{ .fixed_ms = 20 } } });
            var api = try Api.open(&client, .{ .base = try canned.url(&buf) });

            var served = try io.concurrent(Canned.serveScript, .{ &canned, &[_]Reply{ unavailable, fine }, 2 });
            defer served.cancel(io) catch {};
            const res = try api.get(&scope, "/v1/me", .{}, .{});
            try testing.expect(res.ok());
            try testing.expectEqual(@as(usize, 2), canned.tried.count);
        }
    }.run);
}

test "a connection that is refused is tried again, and the error is the last one's" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            // A port nobody listens on: bind one, learn it, close it.
            var canned = try Canned.open(io);
            var buf: [64]u8 = undefined;
            const base = try canned.url(&buf);
            canned.close();

            var client = try started(io);
            defer client.deinit();
            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();
            const Api = fetch.Target("api", .{ .retry = .{ .times = 2, .backoff = .{ .fixed_ms = 1 } } });
            var api = try Api.open(&client, .{ .base = base });
            try testing.expectError(error.ConnectionRefused, api.get(&scope, "/v1/me", .{}, .{}));
        }
    }.run);
}

test "a call that succeeds first time asks the arena for what a target with no retry does" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            canned.body_len = 64;
            var client = try started(io);
            defer client.deinit();
            var buf: [64]u8 = undefined;
            const base = try canned.url(&buf);
            const Plain = fetch.Target("plain", .{});
            const Retrying = fetch.Target("retrying", .{ .retry = .{} });
            var plain = try Plain.open(&client, .{ .base = base });
            var retrying = try Retrying.open(&client, .{ .base = base });

            // Warm one connection, then count the second call down it, once
            // for each target.
            var served = try io.concurrent(Canned.serveKeepAlive, .{ &canned, @as(usize, 3) });
            defer served.cancel(io) catch {};
            var warm: core.Run = .init(testing.allocator);
            defer warm.deinit();
            _ = try plain.get(&warm, "/", .{}, .{});

            var counting_plain: live.Counting = .{ .child = testing.allocator };
            var one: core.Run = .init(counting_plain.allocator());
            defer one.deinit();
            _ = try plain.get(&one, "/", .{}, .{});

            var counting_retrying: live.Counting = .{ .child = testing.allocator };
            var two: core.Run = .init(counting_retrying.allocator());
            defer two.deinit();
            _ = try retrying.get(&two, "/", .{}, .{});

            try testing.expectEqual(counting_plain.allocs, counting_retrying.allocs);
            try testing.expectEqual(counting_plain.bytes, counting_retrying.bytes);
        }
    }.run);
}
