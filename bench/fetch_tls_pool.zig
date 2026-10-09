//! What an idle outbound connection holds once the pool has it, plain and over
//! TLS, measured rather than read off buffer sizes.
//!
//! `std.http.Client` gives every connection a reader and a writer buffer on
//! the heap, and an HTTPS one three more (`tls_buffer_size` each, 16,645
//! bytes): 59,151 bytes in all, which `fetch/fetch.zig` and the guide have
//! quoted as what an HTTPS connection holds. A buffer is only resident where a
//! byte was written to it, so the sum of the sizes is a ceiling and not a
//! reading. This program is the reading: it opens N connections at once, lets
//! every one finish a request, hands them all back to the pool (`free_size` is
//! raised so none is closed), joins the threads that drove them, and reads
//! this process's `VmRSS`. Steps are cumulative, so the marginal column says
//! whether a connection costs the same at the thousandth as at the fiftieth.
//!
//! The pool is std's, so the client is `std.http.Client` itself. `nilo_fetch`
//! wraps one and costs nothing beside it on this axis
//! (`bench/result/fetch.md`), but caps the pool at the 32 it was given, which
//! would stop the series at 32 connections.
//!
//! ```
//! zig build-exe bench/fetch_tls_pool.zig -O ReleaseFast -target x86_64-linux-gnu \
//!     -femit-bin=zig-out/bin/nilo-bench-fetch-tls-pool
//!
//! # a local TLS server, certificate from the suite's fixture
//! zig build bench-tls-server -Dtls -Doptimize=ReleaseFast -Dtarget=x86_64-linux-gnu
//! ./zig-out/bin/nilo-bench-tls-server &                    # 127.0.0.1:8787
//! URL=https://localhost:8787/health CERT=http/testdata/tls/localhost.pem \
//!     ./zig-out/bin/nilo-bench-fetch-tls-pool
//!
//! # the same against a plain server, for the ratio
//! URL=http://localhost:8787/health ./zig-out/bin/nilo-bench-fetch-tls-pool
//!
//! # or a real endpoint: no CERT, so the system's roots are loaded
//! URL=https://example.com/ STEPS=4,8,16 ./zig-out/bin/nilo-bench-fetch-tls-pool
//! ```
//!
//! `URL` is required. `CERT` is a PEM added as the only root, so a self-signed
//! local server verifies; without it the system's roots are scanned once, on
//! the first request, and that scan is taken out of the base before the first
//! step. `STEPS` is the cumulative connection counts, default
//! `50,100,200,400,800,1600`.

const std = @import("std");
const Io = std.Io;

const gpa = std.heap.smp_allocator;

var arrived: std.atomic.Value(usize) = .init(0);
var failed: std.atomic.Value(usize) = .init(0);

fn rssBytes() !u64 {
    var buf: [8192]u8 = undefined;
    const fd = try std.posix.openat(std.posix.AT.FDCWD, "/proc/self/status", .{}, 0);
    defer _ = std.os.linux.close(fd);
    const n = try std.posix.read(fd, &buf);
    const text = buf[0..n];
    const at = std.mem.find(u8, text, "VmRSS:") orelse return error.NoRss;
    var it = std.mem.tokenizeAny(u8, text[at + 6 ..], " \tkB\n");
    const kb = try std.fmt.parseInt(u64, it.next().?, 10);
    return kb * 1024;
}

fn one(client: *std.http.Client, uri: std.Uri, want: usize) void {
    var req = client.request(.GET, uri, .{}) catch {
        _ = failed.fetchAdd(1, .monotonic);
        _ = arrived.fetchAdd(1, .release);
        return;
    };
    // Every connection is in use until every thread has its answer, so the
    // pool cannot hand one connection to two of them.
    ok: {
        req.sendBodiless() catch break :ok;
        var redirect: [512]u8 = undefined;
        var response = req.receiveHead(&redirect) catch break :ok;
        var transfer: [256]u8 = undefined;
        _ = response.reader(&transfer).discardRemaining() catch break :ok;
        _ = arrived.fetchAdd(1, .release);
        while (arrived.load(.acquire) < want) std.Thread.yield() catch {};
        req.deinit();
        return;
    }
    _ = failed.fetchAdd(1, .monotonic);
    _ = arrived.fetchAdd(1, .release);
    req.connection.?.closing = true;
    req.deinit();
}

pub fn main(init: std.process.Init) !void {
    const url = init.environ_map.get("URL") orelse return error.NoUrl;
    const steps_text = init.environ_map.get("STEPS") orelse "50,100,200,400,800,1600";
    const uri = try std.Uri.parse(url);

    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    client.connection_pool.free_size = 1 << 20;

    if (init.environ_map.get("CERT")) |cert| {
        const now = Io.Timestamp.now(io, .real);
        try client.ca_bundle.addCertsFromFilePath(gpa, io, now, Io.Dir.cwd(), cert);
        client.now = now;
    }

    // One connection first, so the one-time costs (the root scan, the first
    // handshake's code pages, the thread machinery) are in the base and not in
    // the first step's per-connection figure.
    arrived.store(0, .monotonic);
    const warm = try std.Thread.spawn(.{}, one, .{ &client, uri, 1 });
    warm.join();
    if (failed.load(.monotonic) != 0) return error.WarmCallFailed;

    std.debug.print("{s}\n", .{url});
    std.debug.print("{s:>12} {s:>12} {s:>10} {s:>14} {s:>12}\n", .{ "connections", "RSS kB", "in pool", "average B/conn", "marginal"});
    std.Io.sleep(io, .fromMilliseconds(1000), .awake) catch {};
    const base = try rssBytes();
    std.debug.print("{d:>12} {d:>12} {d:>10} {s:>14} {s:>12}\n", .{ 1, base / 1024, client.connection_pool.free_len, "-", "-" });

    var prev_rss = base;
    var prev_n: usize = 1;
    var it = std.mem.tokenizeScalar(u8, steps_text, ',');
    while (it.next()) |text| {
        const target = try std.fmt.parseInt(usize, text, 10);
        arrived.store(0, .monotonic);
        failed.store(0, .monotonic);

        const threads = try gpa.alloc(std.Thread, target);
        defer gpa.free(threads);
        var started: usize = 0;
        while (started < target) : (started += 1) {
            threads[started] = std.Thread.spawn(.{}, one, .{ &client, uri, target }) catch break;
        }
        // A thread that could not start would leave the others waiting for it.
        if (started < target) _ = arrived.fetchAdd(target - started, .release);
        for (threads[0..started]) |t| t.join();

        std.Io.sleep(io, .fromMilliseconds(2000), .awake) catch {};
        const rss = try rssBytes();
        const in_pool = client.connection_pool.free_len;
        const average = @as(f64, @floatFromInt(rss - base)) / @as(f64, @floatFromInt(@max(in_pool, 2) - 1));
        const marginal = @as(f64, @floatFromInt(@as(i64, @intCast(rss)) - @as(i64, @intCast(prev_rss)))) /
            @as(f64, @floatFromInt(@max(in_pool, prev_n + 1) - prev_n));
        std.debug.print("{d:>12} {d:>12} {d:>10} {d:>14.0} {d:>12.0}   (failed {d})\n", .{ target, rss / 1024, in_pool, average, marginal, failed.load(.monotonic) });
        prev_rss = rss;
        prev_n = in_pool;
    }
}
