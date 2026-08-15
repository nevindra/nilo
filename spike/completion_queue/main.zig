//! Can one fiber wait on a socket read and a wakeup at the same time, and
//! survive being cancelled while it does?
//!
//! This is roadmap #1 and #2 asked as a program. Broadcasting to a WebSocket
//! a handler does not hold needs the fiber that already owns a connection to
//! be woken by *somebody else* while it sits in a read — otherwise every
//! connection that can be broadcast to needs a second fiber, which is
//! 8,673 bytes each and the whole of ADR 0018's per-connection budget over
//! again.
//!
//! zio#668 asked for `waitForIo` to be exported for this. The answer was that
//! `zio.CompletionQueue` already does it, and it does: it is public in
//! v0.17.0, which is the version zfast already pins. So the question is no
//! longer "is there an API" but "does it hold up where the last one did not".
//!
//! **What this is really testing is the cancel path.** zio#667 is a live
//! defect in `zio.BroadcastChannel`: a waiter node gets pushed onto a queue it
//! is already linked into, which aborts in Debug and — with no assertion to
//! catch it — hangs `ReleaseFast` 17 runs in 20. `CompletionQueue` is built on
//! the same `SimpleQueue`. Reading it, the discipline looks right (the owner
//! callback removes from `pending` before pushing to `completed`), but reading
//! is not the same as running, and every zfast connection is cancelled at
//! shutdown.
//!
//! One scenario per process, so a hang is a process that has to be killed
//! rather than a line in a log. `run.sh` repeats it.
//!
//! Exit codes: 0 clean, 1 the scenario reached a wrong conclusion, 2 the
//! watchdog fired (a hang), 3 something failed to set up.

const std = @import("std");
const zio = @import("zio");

/// Zig 0.16 dropped `std.Thread.sleep` and `std.posix` never had a wrapper,
/// so the syscall is called directly. These are plain OS threads — the
/// notifier and the watchdog — and parking them is exactly what is wanted;
/// the fiber-friendly `zio.sleep` is for the runtime side.
fn threadSleep(ms: u64) void {
    const req: std.os.linux.timespec = .{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    _ = std.os.linux.nanosleep(&req, null);
}

/// Long enough that a loaded machine is not mistaken for a deadlock, short
/// enough that twenty runs is a coffee, not an afternoon. A clean run is
/// milliseconds.
const watchdog_ms = 10_000;

/// How many times the notifier pokes the parked fiber. More than one because
/// the interesting half is re-arming: a broadcast wakes the same connection
/// over and over, so a `CompletionQueue` that only works once is no use.
const notifies = 5;

const Outcome = enum(u8) {
    running = 0,
    /// `wait()` returned `error.Canceled` — what a cancelled connection
    /// should see.
    canceled = 1,
    /// `wait()` returned null, meaning the queue emptied. Not expected here:
    /// something is always submitted.
    emptied = 2,
    /// Some other error.
    failed = 3,
};

const Shared = struct {
    /// Published by the owner fiber once its completions exist, so the
    /// notifier thread never touches them early.
    wake: std.atomic.Value(?*zio.ev.Async) = .init(null),

    /// Woken by the notifier — the half that does not exist today.
    async_wakes: std.atomic.Value(u32) = .init(0),
    /// Woken by the socket becoming readable — the half a connection is
    /// already doing.
    poll_wakes: std.atomic.Value(u32) = .init(0),

    /// Set while the fiber is inside `wait()`. The cancel has to land here to
    /// be testing anything.
    parked: std.atomic.Value(bool) = .init(false),
    outcome: std.atomic.Value(u8) = .init(0),
    /// A completion came back that was neither of the two submitted.
    stranger: std.atomic.Value(bool) = .init(false),

    /// What the `write` syscall that is supposed to wake the poll returned.
    /// Recorded because "the socket never woke the fiber" has two very
    /// different causes and guessing between them wastes a night.
    write_rc: std.atomic.Value(isize) = .init(-1),
};

/// The fiber that owns a connection. In the real thing this is the one
/// running the WebSocket read loop.
///
/// `rearm` picks how a completion that has already fired goes back on the
/// queue, which turned out to be the whole story — see the two Rearm cases.
fn owner(shared: *Shared, handle: zio.ev.Backend.NetHandle, rearm: Rearm) void {
    var cq = zio.CompletionQueue.init();
    var poll = zio.ev.NetPoll.init(handle, .recv);
    var wake = zio.ev.Async.init();

    cq.submit(&poll.c);
    cq.submit(&wake.c);
    shared.wake.store(&wake, .release);

    while (true) {
        shared.parked.store(true, .release);
        const maybe = cq.wait() catch |err| {
            shared.parked.store(false, .release);
            shared.outcome.store(
                @intFromEnum(if (err == error.Canceled) Outcome.canceled else Outcome.failed),
                .release,
            );
            return;
        };
        shared.parked.store(false, .release);

        const done = maybe orelse {
            shared.outcome.store(@intFromEnum(Outcome.emptied), .release);
            return;
        };

        if (done == &wake.c) {
            if (rearm == .reinit) wake = zio.ev.Async.init();
            cq.submit(&wake.c);
            _ = shared.async_wakes.fetchAdd(1, .release);
        } else if (done == &poll.c) {
            // Drain the byte before re-arming. `NetPoll` is level-triggered,
            // so leaving it there means the poll fires again immediately and
            // the fiber spins instead of parking — measured, that turned one
            // wake into 259, and a fiber that never parks is not the fiber
            // this spike is trying to cancel.
            var sink: [64]u8 = undefined;
            _ = std.os.linux.read(handle, &sink, sink.len);
            if (rearm == .reinit) poll = zio.ev.NetPoll.init(handle, .recv);
            cq.submit(&poll.c);
            _ = shared.poll_wakes.fetchAdd(1, .release);
        } else {
            shared.stranger.store(true, .release);
            return;
        }
    }
}

const Rearm = enum {
    /// Hand the same completion object straight back to `submit`, which is
    /// the obvious thing to write and what a connection would do.
    ///
    /// **This crashes zio**, and finding that is most of what this spike was
    /// worth. `CompletionQueue.submit` sets `c.group.owner` and
    /// `c.group.owner_callback` and links the completion into its `pending`
    /// list, and then calls `loop.add`. For a completion that has already run,
    /// `addInternal` sees `phase == .dead` and calls `Completion.reset()`
    /// (`ev/loop.zig:831`), which clears all three
    /// (`ev/completion.zig:411-414`). The queue's claim on the completion is
    /// wiped a line after it was made.
    ///
    /// What comes out the other side is a completion with no owner callback
    /// and no callback, which `finishCompletion` treats as a task wake and
    /// hands to `dispatched` — so `Executor.drainDispatched` reads
    /// `c.userdata.?`, finds null, and panics in `runtime.zig:1085`.
    ///
    /// `CompletionQueue`'s own tests never catch this: every one of them
    /// submits a *fresh* timer, and "dynamic submit during iteration" submits
    /// a second object rather than the first one again.
    plain,

    /// Build the completion again before handing it back. This is the
    /// workaround, and it is only good enough to answer the rest of the
    /// question — re-initialising an `Async` also clears its `pending` flag,
    /// so a notify that lands between the fire and the re-init is lost. The
    /// notifier below waits for each wake to be counted before sending the
    /// next one, so that race is kept out of the measurement rather than
    /// pretended away.
    reinit,
};

/// The other end of the connection, opened from inside the runtime because
/// `connect` is a zio call.
const Peer = struct {
    stream: ?zio.net.Stream = null,
    err: ?anyerror = null,
    ready: std.atomic.Value(bool) = .init(false),

    fn connect(self: *Peer, to: zio.net.Address) void {
        if (to.connect(.{ .timeout = .fromSeconds(5) })) |stream| {
            self.stream = stream;
        } else |err| {
            self.err = err;
        }
        self.ready.store(true, .release);
    }
};

/// A plain OS thread, not a fiber. `Async.notify` says it is thread-safe and
/// the broadcast case needs that to be true, so the spike takes it at its
/// word rather than being gentle with it.
fn notifier(shared: *Shared, peer_fd: zio.ev.Backend.NetHandle) void {
    const wake = spin(shared) orelse return;

    // One at a time, each confirmed before the next: under `.reinit` the
    // re-arm has a window where a notify would be dropped, and a spike that
    // fired five in a row could not tell a dropped notify from a broken
    // queue. Waiting makes the count mean one thing.
    for (0..notifies) |sent| {
        wake.notify();
        var waited: usize = 0;
        while (shared.async_wakes.load(.acquire) <= sent and waited < 1000) : (waited += 1) {
            threadSleep(1);
        }
    }

    // And once through the socket, so both halves of the race are shown to
    // reach the same parked fiber.
    // Straight to the syscall, like the sleep above: `std.posix.write` is
    // gone in Zig 0.16 too, and this thread is deliberately outside the
    // runtime — writing through zio here would put the wakeup on the same
    // side as the thing being woken.
    const rc = std.os.linux.write(peer_fd, "x", 1);
    shared.write_rc.store(@bitCast(rc), .release);

    // Wait for it to land, the same as the notifies above. Without this the
    // notifier returns the instant the byte is written, `cancel()` follows,
    // and the poll wake loses the race — measured at 6 runs in 60, which
    // looked exactly like a lost wakeup in zio and was this harness all
    // along.
    var waited: usize = 0;
    while (shared.poll_wakes.load(.acquire) == 0 and waited < 1000) : (waited += 1) {
        threadSleep(1);
    }
}

fn spin(shared: *Shared) ?*zio.ev.Async {
    var waited: usize = 0;
    while (waited < 2000) : (waited += 1) {
        if (shared.wake.load(.acquire)) |wake| return wake;
        threadSleep(1);
    }
    return null;
}

fn watchdog() void {
    threadSleep(watchdog_ms);
    std.debug.print("HANG: still running after {d}ms\n", .{watchdog_ms});
    std.process.exit(2);
}

pub fn main(init: std.process.Init.Minimal) void {
    const dog = std.Thread.spawn(.{}, watchdog, .{}) catch {
        std.debug.print("SETUP: could not start the watchdog\n", .{});
        std.process.exit(3);
    };
    dog.detach();

    // `plain` is the repro, `reinit` is the workaround that lets the rest of
    // the question be asked. Default is the one that can pass.
    var rearm: Rearm = .reinit;
    var args: std.process.Args.Iterator = .init(init.args);
    _ = args.skip();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "plain")) rearm = .plain;
    }

    run(rearm) catch |err| {
        std.debug.print("SETUP: {s}\n", .{@errorName(err)});
        std.process.exit(3);
    };
}

fn run(rearm: Rearm) !void {
    const gpa = std.heap.smp_allocator;

    // Two executors, so the fiber being cancelled and the one doing the
    // cancelling are not automatically the same thread.
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();

    const addr = try zio.net.IpAddress.parseIp("127.0.0.1", 0);
    const server = try addr.listen(.{ .reuse_address = true });
    defer server.close();

    var group: zio.Group = .init;

    var peer: Peer = .{};
    try group.spawn(Peer.connect, .{ &peer, server.socket.address });

    const conn = try server.accept(.{ .timeout = .fromSeconds(5) });
    defer conn.close();

    while (!peer.ready.load(.acquire)) try zio.sleep(.fromMilliseconds(1));
    if (peer.err) |err| return err;
    const other_end = peer.stream orelse return error.NoPeer;
    defer other_end.close();

    var shared: Shared = .{};
    try group.spawn(owner, .{ &shared, conn.socket.handle, rearm });

    const poke = try std.Thread.spawn(.{}, notifier, .{ &shared, other_end.socket.handle });

    // Give the notifier its run, then wait for the fiber to be back inside
    // `wait()` rather than mid-loop. Cancelling a fiber that is not parked
    // would be a different, easier test.
    poke.join();
    var settle: usize = 0;
    while (settle < 1000) : (settle += 1) {
        if (shared.parked.load(.acquire)) break;
        try zio.sleep(.fromMilliseconds(1));
    }
    const was_parked = shared.parked.load(.acquire);

    // The moment being tested. This blocks until every task in the group has
    // actually finished, so a fiber that never comes back out of `wait()`
    // hangs here and the watchdog is what ends the process.
    group.cancel();

    const async_wakes = shared.async_wakes.load(.acquire);
    const poll_wakes = shared.poll_wakes.load(.acquire);
    const outcome: Outcome = @enumFromInt(shared.outcome.load(.acquire));

    std.debug.print(
        "parked={} async_wakes={d}/{d} poll_wakes={d} write_rc={d} outcome={s} stranger={}\n",
        .{
            was_parked,
            async_wakes,
            notifies,
            poll_wakes,
            shared.write_rc.load(.acquire),
            @tagName(outcome),
            shared.stranger.load(.acquire),
        },
    );

    var wrong = false;
    if (!was_parked) {
        std.debug.print("WRONG: the fiber was not parked when it was cancelled\n", .{});
        wrong = true;
    }
    if (async_wakes != notifies) {
        std.debug.print("WRONG: a notify was lost, or re-arming does not work\n", .{});
        wrong = true;
    }
    if (poll_wakes == 0) {
        std.debug.print("WRONG: the socket never woke the fiber\n", .{});
        wrong = true;
    }
    if (outcome != .canceled) {
        std.debug.print("WRONG: a cancelled wait should come back as error.Canceled\n", .{});
        wrong = true;
    }
    if (shared.stranger.load(.acquire)) {
        std.debug.print("WRONG: a completion came back that was never submitted\n", .{});
        wrong = true;
    }

    if (wrong) std.process.exit(1);
    std.debug.print("OK\n", .{});
}
