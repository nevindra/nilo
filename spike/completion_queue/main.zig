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
//! **The second question, asked later.** The first pass found that handing a
//! fired completion straight back to `submit` crashes zio (zio#673) and that
//! rebuilding it first works around that — but the workaround looked like it
//! cost a lost wakeup, which a broadcast cannot carry. It does not have to:
//! `pending` lives on `Async`, not on `Completion`, so rebuilding only the
//! completion keeps it. `.recomplete` and `--blind` are here to hold that
//! claim to a number instead of a reading of the source. See `Rearm` and
//! `Pace`.
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

/// How long the owner fiber holds its re-arm window open under `--window`.
/// Long enough that a thread doing a `write` syscall lands inside it every
/// time, short enough that the run is still milliseconds.
const window_ms = 50;

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

    /// A mailbox standing in for the real one: the notifier posts, the owner
    /// fiber takes what it finds every time it wakes.
    ///
    /// Counting *wakes* cannot answer the question this spike was extended to
    /// ask. `Async.notify` is `pending.swap(1)`, so two posts arriving before
    /// the fiber re-arms produce one wake — that is coalescing, it is the
    /// documented behaviour, and a broadcast is fine with it because the
    /// payload is in the mailbox rather than in the wake. What a broadcast
    /// cannot survive is the fiber parking with `posted > drained`: a message
    /// sitting in the mailbox and nothing left to wake anybody for it.
    ///
    /// So the assertion is `drained == posted`, not `async_wakes == notifies`.
    posted: std.atomic.Value(u32) = .init(0),
    drained: std.atomic.Value(u32) = .init(0),

    /// Set while the fiber is inside `wait()`. The cancel has to land here to
    /// be testing anything.
    parked: std.atomic.Value(bool) = .init(false),

    /// Set while the owner fiber is between draining its mailbox and
    /// re-arming its `Async` — the window `--window` exists to aim at.
    in_window: std.atomic.Value(bool) = .init(false),
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
fn owner(shared: *Shared, handle: zio.ev.Backend.NetHandle, rearm: Rearm, pace: Pace) void {
    var cq = zio.CompletionQueue.init();
    var poll = zio.ev.NetPoll.init(handle, .recv);
    var wake = zio.ev.Async.init();

    // Held open once, on the first wake, and only under `--window`. Once is
    // enough to answer the question and keeps the run short; holding it open
    // every time would just add `window_ms` to every pass.
    var window_left: usize = if (pace == .window) 1 else 0;

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
            // Drain first, then re-arm — the order a real mailbox has to use,
            // and the order that exposes the window. A post landing between
            // these two lines is the whole question: `.recomplete` leaves
            // `pending` set so `submit` completes immediately and it is seen
            // on the next pass, `.reinit` clears it and the fiber parks with
            // the post still sitting there.
            shared.drained.store(shared.posted.load(.acquire), .release);

            // Hold the window open so the notifier can put a post inside it
            // on purpose. `--blind` showed why this is needed: firing five
            // notifies as fast as a thread can go still produced
            // `async_wakes=1`, because all five landed before the fiber was
            // scheduled at all. The window is real and it is nanoseconds
            // wide; hoping to hit it is not a measurement.
            if (window_left > 0) {
                window_left -= 1;
                shared.in_window.store(true, .release);
                zio.sleep(.fromMilliseconds(window_ms)) catch {};
                shared.in_window.store(false, .release);
            }

            switch (rearm) {
                .plain => {},
                .reinit => wake = zio.ev.Async.init(),
                .recomplete => wake.c = .init(.async),
            }
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
            switch (rearm) {
                .plain => {},
                .reinit => poll = zio.ev.NetPoll.init(handle, .recv),
                // A `NetPoll` has no cross-incarnation state to keep — the
                // handle and the event it watches do not change — so the two
                // rebuilding modes differ only for the `Async`.
                .recomplete => poll.c = .init(.net_poll),
            }
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

    /// Build the whole handle again before handing it back — `wake =
    /// Async.init()`. This is the obvious workaround and it does clear
    /// zio#673, because a completion in phase `.new` never reaches the
    /// `reset()` that wipes the queue's claim on it.
    ///
    /// It costs a wakeup. `Async.init()` returns a fresh struct, and `pending`
    /// is a field of that struct, so a notify landing between the fire and the
    /// re-init has its flag thrown away with everything else. Under `--paced`
    /// the notifier waits for each wake before sending the next, which keeps
    /// that race out of the numbers rather than pretending it away; under
    /// `--blind` it is exactly what gets caught.
    reinit,

    /// Build only the *completion* again — `wake.c = .init(.async)` — and
    /// leave the handle around it alone.
    ///
    /// This is the same trick as `reinit` where zio#673 is concerned: phase
    /// goes back to `.new`, so `addInternal` never calls `reset()` and the
    /// owner callback `submit` just installed survives. The difference is what
    /// it does *not* touch. `pending` lives on `Async`, not on `Completion`
    /// (`ev/completion.zig:571-574`), and `Completion.reset` never had any
    /// business with it either way.
    ///
    /// So a notify landing in the re-arm window sets `pending` on a handle
    /// that keeps it, and the next `submit` walks straight into
    /// `checkAndSetAsyncResult` (`ev/loop.zig:872-883`), which swaps the flag
    /// back down and completes the handle on the spot. The wake is delivered
    /// late rather than lost.
    ///
    /// The cost is a race the memory model does not bless: assigning a whole
    /// `Completion` is a plain store across `c.loop`, which `Async.notify`
    /// reads atomically (`ev/completion.zig:319-325`). One aligned word, so
    /// the read returns either the old loop — a `wakeAsync` nobody needed,
    /// which is harmless — or null, which is the case `submit` already covers.
    /// Benign on any real target, and still worth saying out loud.
    recomplete,
};

/// How hard the notifier leans on the re-arm window.
const Pace = enum {
    /// Wait for each wake to be counted before sending the next. The window
    /// is never occupied, so every mode that does not crash looks correct —
    /// which is what the first pass wanted, because it was asking about the
    /// cancel path and needed one variable at a time.
    paced,

    /// Post and notify as fast as the loop goes, five times, without looking.
    /// This is what a broadcast under load actually does.
    ///
    /// It does **not** separate `.reinit` from `.recomplete`, and finding
    /// that out was worth the run: all five notifies land before the fiber is
    /// scheduled even once, so the summary reads `async_wakes=1/5
    /// drained=5/5` and both modes pass. `notify` coalescing is doing the
    /// work, and the re-arm window is never occupied. Kept because "the
    /// obvious hammer does not reach it" is a fact about the window, and
    /// because it is the closest thing here to the real traffic pattern.
    blind,

    /// Put a post inside the re-arm window on purpose, with the fiber holding
    /// that window open (`window_ms`) so there is nothing to race.
    ///
    /// This is the one that answers the question. It is not a stress test and
    /// it is not pretending to be traffic — it is the mechanism, made
    /// observable: one post arrives while the handle is between drained and
    /// re-armed, and afterwards either the fiber saw it or it did not.
    window,
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
fn notifier(shared: *Shared, peer_fd: zio.ev.Backend.NetHandle, pace: Pace) void {
    const wake = spin(shared) orelse return;

    switch (pace) {
        // One at a time, each confirmed before the next. Under `.reinit` the
        // re-arm has a window where a notify would be dropped, and a spike
        // that fired five in a row could not tell a dropped notify from a
        // broken queue. Waiting makes the count mean one thing.
        .paced => for (0..notifies) |sent| {
            _ = shared.posted.fetchAdd(1, .release);
            wake.notify();
            var waited: usize = 0;
            while (shared.async_wakes.load(.acquire) <= sent and waited < 1000) : (waited += 1) {
                threadSleep(1);
            }
        },

        // Straight into the window, five times. The post is counted *before*
        // the notify, so a fiber that wakes in between sees the higher number
        // and the mailbox is never claimed as drained early.
        .blind => {
            for (0..notifies) |_| {
                _ = shared.posted.fetchAdd(1, .release);
                wake.notify();
            }

            // Then give it a bounded chance to catch up. Bounded, because a
            // lost wakeup should come out as `drained < posted` in the
            // summary rather than as a hang the watchdog has to end — the
            // difference between a measurement and a mystery.
            settle(shared);
        },

        .window => {
            // One post to get the fiber moving. It drains this, then holds
            // the window open.
            _ = shared.posted.fetchAdd(1, .release);
            wake.notify();

            var waited: usize = 0;
            while (!shared.in_window.load(.acquire) and waited < 2000) : (waited += 1) {
                threadSleep(1);
            }
            if (waited == 2000) return; // never opened; `drained` will say so

            // The post this whole mode exists for: the handle is drained, not
            // yet re-armed, and somebody wants to send a message to this
            // connection. Exactly the case a broadcast cannot afford to drop.
            _ = shared.posted.fetchAdd(1, .release);
            wake.notify();

            settle(shared);
        },
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

/// Wait, with a ceiling, for the fiber to have taken every post. The ceiling
/// is the point: a lost wakeup leaves `drained < posted` in the summary,
/// which is a result, rather than hanging until the watchdog kills the
/// process, which is only a symptom.
fn settle(shared: *Shared) void {
    var waited: usize = 0;
    while (waited < 1000) : (waited += 1) {
        if (shared.drained.load(.acquire) == shared.posted.load(.acquire)) return;
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

    // `plain` is the repro, `reinit` is the workaround the first pass
    // measured, `recomplete` is the one that should also keep its wakeups.
    // Defaults are the pair that was already known to pass.
    var rearm: Rearm = .reinit;
    var pace: Pace = .paced;
    var args: std.process.Args.Iterator = .init(init.args);
    _ = args.skip();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "plain")) rearm = .plain;
        if (std.mem.eql(u8, arg, "reinit")) rearm = .reinit;
        if (std.mem.eql(u8, arg, "recomplete")) rearm = .recomplete;
        if (std.mem.eql(u8, arg, "--blind")) pace = .blind;
        if (std.mem.eql(u8, arg, "--paced")) pace = .paced;
        if (std.mem.eql(u8, arg, "--window")) pace = .window;
    }

    run(rearm, pace) catch |err| {
        std.debug.print("SETUP: {s}\n", .{@errorName(err)});
        std.process.exit(3);
    };
}

fn run(rearm: Rearm, pace: Pace) !void {
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
    try group.spawn(owner, .{ &shared, conn.socket.handle, rearm, pace });

    const poke = try std.Thread.spawn(.{}, notifier, .{ &shared, other_end.socket.handle, pace });

    // Give the notifier its run, then wait for the fiber to be back inside
    // `wait()` rather than mid-loop. Cancelling a fiber that is not parked
    // would be a different, easier test.
    poke.join();
    var settled: usize = 0;
    while (settled < 1000) : (settled += 1) {
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
    const posted = shared.posted.load(.acquire);
    const drained = shared.drained.load(.acquire);
    const outcome: Outcome = @enumFromInt(shared.outcome.load(.acquire));

    std.debug.print(
        "parked={} async_wakes={d}/{d} drained={d}/{d} poll_wakes={d} write_rc={d} outcome={s} stranger={}\n",
        .{
            was_parked,
            async_wakes,
            notifies,
            drained,
            posted,
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
    // The one check that means the same thing under both paces: every post
    // was seen by the fiber. Under `--blind` this is the whole question.
    if (drained != posted) {
        std.debug.print("WRONG: the fiber parked with a post it never saw\n", .{});
        wrong = true;
    }
    // Wake-for-wake only holds when the notifier waited for each one. Firing
    // blind, `notify` coalesces by design and a smaller count is correct.
    if (pace == .paced and async_wakes != notifies) {
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
