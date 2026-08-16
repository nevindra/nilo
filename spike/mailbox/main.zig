//! What does a connection that can be broadcast to cost, when the wakeup is a
//! mailbox its own fiber drains?
//!
//! [ADR 0029](../../docs/adr/0029-a-spawned-fiber-belongs-to-the-server.md)
//! killed the only shape that worked at the time with one number: a second
//! fiber per connection, 8,673 bytes, against a whole-connection budget of
//! 8,767. It also said which shape was right and could not be built —
//! a mailbox the *owning* fiber drains, which adds no fiber at all — and that
//! it was blocked on zio exporting a way to park on a completion.
//!
//! `spike/completion_queue/` settled that it is not blocked: `CompletionQueue`
//! is public in the pinned v0.17.0, its cancel path holds, and re-arming
//! across a broadcast is lossless if only the completion is rebuilt. So the
//! question is back to the one ADR 0029 asked, and it is a number again.
//!
//! **What is measured is the difference and nothing else.** Both modes accept
//! the same connections, spawn exactly one fiber each, and park it forever.
//! `baseline` parks in a read, which is what an idle WebSocket connection does
//! today. `mailbox` parks on a `CompletionQueue` holding the socket poll and
//! an `Async`, and carries the ring a broadcast would post into. Fiber stacks,
//! executors, listen backlog and the runtime itself are identical, so they
//! cancel and what is left is the machinery.
//!
//! ```
//! ./run.sh [connections] [repeats]
//! ./zig-out/bin/mailbox-spike server [baseline|mailbox] <port> <connections>
//! ./zig-out/bin/mailbox-spike client <port> <connections>
//! ```
//!
//! The server prints `ready` once every connection is up and then parks; the
//! RSS is read from outside, from `/proc/<pid>/status`, because a process
//! measuring itself has to allocate to do it.

const std = @import("std");
const zio = @import("zio");

const Mode = enum { baseline, mailbox };

/// How many posts a connection can fall behind before the policy has to
/// decide something — drop oldest, drop newest, disconnect.
///
/// `-Dslots=N`, because it is the caller's number and not this spike's: it
/// belongs to whoever is running the server, and ADR 0020 currently refuses
/// to have it at all. Sweeping it is also the only way to see the third cost
/// in the total, which is neither the machinery nor the ring — see the
/// README.
const slots = @import("config").slots;

/// A post is a slice of memory somebody else owns for as long as the mailbox
/// holds it. Whose memory that is, and who frees it, is the question this
/// spike does *not* answer — it measures the space the pointers take, which
/// is the part that is the same whatever the answer turns out to be.
const Post = []const u8;

/// Everything a broadcast-capable connection holds that an ordinary one does
/// not. One allocation per connection, because in nilo this would live in
/// the connection's own state rather than on a handler's stack — and because
/// a struct on a fiber stack that is already mapped would measure as free
/// when it is not.
const Mailbox = struct {
    /// The two-completion wait. Everything else in here is the mailbox; this
    /// is the part that makes the fiber wakeable by somebody who is not the
    /// client on the other end of the socket.
    cq: zio.CompletionQueue,
    wake: zio.ev.Async,
    poll: zio.ev.NetPoll,

    ring: [slots]Post,
    head: usize,
    tail: usize,
};

fn hold(mode: Mode, stream: zio.net.Stream, gpa: std.mem.Allocator, up: *std.atomic.Value(u32)) void {
    defer stream.close();

    switch (mode) {
        .baseline => {
            // What an idle connection does today: park in a read until the
            // client says something. `.none` is no timeout, which is the
            // honest shape — a WebSocket with no deadline is ADR 0022's
            // recorded hole, not this spike's business.
            var buf: [256]u8 = undefined;
            _ = up.fetchAdd(1, .release);
            _ = stream.read(&buf, .none) catch return;
        },

        .mailbox => {
            const box = gpa.create(Mailbox) catch return;
            defer gpa.destroy(box);
            box.* = .{
                .cq = zio.CompletionQueue.init(),
                .wake = zio.ev.Async.init(),
                .poll = zio.ev.NetPoll.init(stream.socket.handle, .recv),
                // Written rather than left `undefined` on purpose. Untouched
                // pages are not resident, and a mailbox that measured as free
                // because nobody had posted to it yet would be a lie by
                // exactly the amount it costs.
                .ring = @splat(&.{}),
                .head = 0,
                .tail = 0,
            };

            box.cq.submit(&box.poll.c);
            box.cq.submit(&box.wake.c);
            _ = up.fetchAdd(1, .release);
            _ = box.cq.wait() catch return;
        },
    }
}

fn runServer(mode: Mode, port: u16, want: u32) !void {
    const gpa = std.heap.smp_allocator;

    // Two executors in both modes, so the per-executor cost is a constant
    // that cancels in the difference.
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();

    const addr = try zio.net.IpAddress.parseIp("127.0.0.1", port);
    const server = try addr.listen(.{ .reuse_address = true, .kernel_backlog = 1024 });
    defer server.close();

    var group: zio.Group = .init;
    var up: std.atomic.Value(u32) = .init(0);

    var accepted: u32 = 0;
    while (accepted < want) : (accepted += 1) {
        const stream = try server.accept(.{ .timeout = .fromSeconds(30) });
        try group.spawn(hold, .{ mode, stream, gpa, &up });
    }

    // Every connection accepted is not the same as every fiber parked, and
    // the difference is the whole measurement — a fiber still on its way to
    // `wait()` has not paid for its completions yet.
    while (up.load(.acquire) < want) try zio.sleep(.fromMilliseconds(10));

    // The struct's own size goes out with the count, so the gap between it
    // and the measured per-connection cost is visible rather than inferred.
    std.debug.print("ready {d} slots={d} sizeof={d}\n", .{ want, slots, @sizeOf(Mailbox) });

    // Park forever. Whoever started this reads `/proc/<pid>/status` and then
    // kills it; there is nothing to tidy because the process is the arena.
    while (true) try zio.sleep(.fromMilliseconds(1000));
}

fn runClient(port: u16, want: u32) !void {
    const gpa = std.heap.smp_allocator;

    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();

    const addr = try zio.net.IpAddress.parseIp("127.0.0.1", port);

    // A separate process, so none of this lands in the number being read.
    const held = try gpa.alloc(zio.net.Stream, want);
    defer gpa.free(held);
    for (held) |*slot| slot.* = try addr.connect(.{ .timeout = .fromSeconds(30) });

    while (true) try zio.sleep(.fromMilliseconds(1000));
}

pub fn main(init: std.process.Init.Minimal) void {
    var args: std.process.Args.Iterator = .init(init.args);
    _ = args.skip();

    const what = args.next() orelse usage();

    if (std.mem.eql(u8, what, "server")) {
        const mode_text = args.next() orelse usage();
        const mode: Mode = if (std.mem.eql(u8, mode_text, "baseline"))
            .baseline
        else if (std.mem.eql(u8, mode_text, "mailbox"))
            .mailbox
        else
            usage();

        runServer(mode, nextPort(&args), nextCount(&args)) catch |err| fail(err);
        return;
    }

    if (std.mem.eql(u8, what, "client")) {
        runClient(nextPort(&args), nextCount(&args)) catch |err| fail(err);
        return;
    }

    usage();
}

fn nextPort(args: *std.process.Args.Iterator) u16 {
    const text = args.next() orelse usage();
    return std.fmt.parseInt(u16, text, 10) catch usage();
}

fn nextCount(args: *std.process.Args.Iterator) u32 {
    const text = args.next() orelse usage();
    return std.fmt.parseInt(u32, text, 10) catch usage();
}

fn fail(err: anyerror) noreturn {
    std.debug.print("FAILED: {s}\n", .{@errorName(err)});
    std.process.exit(3);
}

fn usage() noreturn {
    std.debug.print(
        \\usage:
        \\  mailbox-spike server [baseline|mailbox] <port> <connections>
        \\  mailbox-spike client <port> <connections>
        \\
    , .{});
    std.process.exit(2);
}
