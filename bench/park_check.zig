//! Whether a plain idle connection holds one page of fiber stack, or more.
//! `zig build park-check`, which `zig build test` runs on Linux x86-64
//! (ADR 062, ADR 212).
//!
//! **What it guards is the page, not the byte.** A connection parks at some
//! depth of its fiber's stack, and the pages below `waitForRequest` are given
//! back at idle. Above a boundary a little under 2,800 bytes of depth the
//! park touches a second page, and every idle connection of that build
//! costs 4,096 bytes more. A change that moves the depth by a few bytes
//! costs nothing; one that crosses the boundary costs 4 KiB a connection. So
//! the step fails on a crossing and on nothing else: it counts pages, and
//! never compares a depth against a number.
//!
//! **Why a program and not a test.** The depth is a property of what the
//! optimizer made of the connection loop's frames, and `zig build test` runs
//! in Debug, where every frame is several times larger. The program is built
//! `ReleaseFast` with the flags the build was asked for (`-Dtls`, `-Dhttp2`),
//! and they matter: a second caller of the handler under `-Dtls` moved the
//! plain park 384 bytes deeper, across the boundary.
//!
//! What it does: serves `/health` from this process, opens a few dozen
//! keep-alive connections, serves each one request, leaves them quiet past
//! `idle_peek_ms` so every one gives its pages back, and then reads
//! `/proc/self/smaps` for the 256 KiB fiber stacks and how many pages each
//! holds.
//!
//! - A build under the boundary (the default, `-Dhttp2`) must hold one page
//!   on every connection. Two or more is the failure.
//! - A build already across it (`-Dtls`, the inliner's page, ADR 212) is
//!   pinned at two pages on every connection. A third fails it. One means the
//!   page has been given back, which is good news and is printed as a note:
//!   the pin is stale and should come down in the same commit.
//!
//! **Where it runs.** It reads `/proc`, and a stack's depth is an x86-64
//! property, so `build.zig` adds the run only when both the host and the
//! target are Linux on x86-64. Anywhere else the step exists and is named
//! "skipped", does nothing, and succeeds. The figures in the documents (the
//! depths in bytes) were read with a four-line probe in `releaseIdleStack`
//! that is not in the tree; they are context for this check, not part of it.
//!
//! A change that moves a build across its pin changes the pin below, in the
//! same commit, with the run that justified it in `bench/result/http.md`.

const std = @import("std");
const nilo = @import("nilo_http");
const build_options = @import("park_options");

/// Quiet: the step prints one line, and a build step that writes to stderr is
/// reported as having failed even when it exits 0.
pub const std_options: std.Options = blk: {
    var options = nilo.std_options;
    options.log_level = .err;
    break :blk options;
};
pub const std_options_debug_io = nilo.debug_io;
pub const panic = nilo.panic;

/// Connections held open. Enough for every one to land on a stack and for a
/// stray to show, few enough that opening them is quick.
const connections = 48;

/// Pages a plain idle connection holds in this build: the known cost, and
/// the most it may take.
const pinned_pages: u32 = if (build_options.tls) 2 else 1;

fn health() []const u8 {
    return "alive\n";
}

fn serve(app: *nilo.App) void {
    app.tryListen(.{ .port = 0, .threads = 2, .stop_on_signal = false }) catch {};
}

/// How many fiber stacks (256 KiB mappings) hold at least two, and at least
/// three, pages, from `/proc/self/smaps`.
const Held = struct { two: u32 = 0, three: u32 = 0 };

fn heldStacks(gpa: std.mem.Allocator, io: std.Io) !Held {
    // Read to the end of the stream: `/proc` files claim a size of zero, which
    // is what a read sized by `stat` would believe.
    var file = try std.Io.Dir.cwd().openFile(io, "/proc/self/smaps", .{});
    defer file.close(io);
    var chunk: [4096]u8 = undefined;
    var reader = file.readerStreaming(io, &chunk);
    const text = try reader.interface.allocRemaining(gpa, .limited(8 << 20));
    defer gpa.free(text);

    var held: Held = .{};
    var size_kb: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "Size:")) {
            size_kb = std.fmt.parseInt(usize, std.mem.trim(u8, line["Size:".len..], " kB"), 10) catch 0;
        } else if (size_kb == 256 and std.mem.startsWith(u8, line, "Rss:")) {
            const rss_kb = std.fmt.parseInt(usize, std.mem.trim(u8, line["Rss:".len..], " kB"), 10) catch 0;
            if (rss_kb > 4) held.two += 1;
            if (rss_kb > 8) held.three += 1;
        }
    }
    return held;
}

fn readOneResponse(reader: *std.Io.Reader) !void {
    while (true) {
        if (std.mem.indexOf(u8, reader.buffered(), "\r\n\r\nalive\n")) |at| {
            reader.toss(at + 11);
            return;
        }
        try reader.fillMore();
    }
}

pub fn main() !u8 {
    const gpa = std.heap.smp_allocator;

    var app = nilo.App.init(gpa);
    defer app.deinit();
    try app.get("/health", health);

    const thread = try std.Thread.spawn(.{}, serve, .{&app});
    defer {
        app.shutdown();
        thread.join();
    }

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const port: u16 = for (0..500) |_| {
        if (app.boundPort()) |p| break p;
        std.Io.sleep(io, .fromMilliseconds(10), .awake) catch {};
    } else {
        std.debug.print("park-check: the server never bound a port\n", .{});
        return 1;
    };

    const before = try heldStacks(gpa, io);

    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    var streams: [connections]std.Io.net.Stream = undefined;
    var readers: [connections]std.Io.net.Stream.Reader = undefined;
    var writers: [connections]std.Io.net.Stream.Writer = undefined;
    var in_bufs: [connections][512]u8 = undefined;
    var out_bufs: [connections][128]u8 = undefined;
    var open: usize = 0;
    defer for (streams[0..open]) |*s| s.close(io);

    for (0..connections) |i| {
        streams[i] = try address.connect(io, .{ .mode = .stream });
        open += 1;
        readers[i] = streams[i].reader(io, &in_bufs[i]);
        writers[i] = streams[i].writer(io, &out_bufs[i]);
        try writers[i].interface.writeAll("GET /health HTTP/1.1\r\nHost: park\r\n\r\n");
        try writers[i].interface.flush();
        try readOneResponse(&readers[i].interface);
    }

    // Quiet past the peek, then until the numbers stop moving: a connection
    // gives its pages back `idle_peek_ms` after its last byte, and a loaded
    // machine can be late. Bounded, and the last reading is the one judged.
    var two: u32 = 0;
    var three: u32 = 0;
    var last_two: u32 = std.math.maxInt(u32);
    var steady: u32 = 0;
    for (0..100) |round| {
        std.Io.sleep(io, .fromMilliseconds(100), .awake) catch {};
        const now = try heldStacks(gpa, io);
        two = now.two -| before.two;
        three = now.three -| before.three;
        // Steady means the count of stacks above one page has stopped
        // moving, and, for the one-page builds, has reached zero or stayed.
        if (two == last_two) steady += 1 else steady = 0;
        last_two = two;
        // Never before a second has passed: the peek is 200 ms, and a count
        // that is steady at its starting value has not seen anything park.
        if (steady >= 5 and round >= 10) break;
    }

    var out_buf: [512]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &out_buf);
    try out.interface.print(
        "park-check: of {d} idle connections {d} hold more than one page of stack and {d} more than two " ++
            "(this build is pinned at {d} page{s})\n",
        .{ connections, two, three, pinned_pages, if (pinned_pages == 1) "" else "s" },
    );
    try out.interface.flush();

    var failed = false;
    if (pinned_pages == 1 and two != 0) {
        std.debug.print(
            "park-check: {d} of {d} idle connections hold a second page of stack. The connection loop's " ++
                "frames crossed the page boundary, and each of those connections costs 4,096 bytes more " ++
                "(ADR 062, ADR 212).\n",
            .{ two, connections },
        );
        failed = true;
    }
    if (pinned_pages == 2) {
        if (three != 0) {
            std.debug.print(
                "park-check: {d} of {d} idle connections hold a third page of stack, where this build is " ++
                    "known to pay two (ADR 212). Each costs 4,096 bytes more than it did.\n",
                .{ three, connections },
            );
            failed = true;
        }
        if (two < connections) {
            std.debug.print(
                "park-check: note: only {d} of {d} idle connections hold a second page, so this build has " ++
                    "given the page back or the run was late; if it is the first, lower the pin " ++
                    "in bench/park_check.zig and write the run in bench/result/http.md.\n",
                .{ two, connections },
            );
        }
    }
    return if (failed) 1 else 0;
}
