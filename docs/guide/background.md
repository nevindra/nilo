# Background work

**Work that no request started (a summary every minute, a queue drained every few seconds) runs in a fiber the server owns, started with `app.spawn` or `nilo.spawn`.**

**Reference:** [`app.spawn`, `app.before`, `app.start`](../reference/app.md#app), [`nilo.spawn`](../reference/app.md#concurrency), [`nilo.spawn` and `app.spawn`](../reference/core.md#nilospawn-and-appspawn) · **Design:** [The engine](../design/engine.md)

Everything else in this guide starts because somebody connected. This page is about the other kind of work: a summary written every minute, a queue drained every few seconds, a cache warmed once at startup and refreshed after that.

nilo has one mechanism for it, a fiber of its own owned by the server, and the only thing to decide is when it starts.

## A background loop

```zig
const std = @import("std");
const nilo = @import("nilo_http");

const Exporter = struct {
    lock: nilo.Mutex = .{},
    pending: u64 = 0,

    fn flush(self: *Exporter) !void {
        try self.lock.lock();
        defer self.lock.unlock();
        // …send them somewhere…
        self.pending = 0;
    }
};

fn flushEvery(exporter: *Exporter) void {
    while (true) {
        nilo.sleep(60_000) catch return;   // Canceled — the server is going
        exporter.flush() catch |err| std.log.err("flush: {t}", .{err});
    }
}

pub fn main() !void {
    var app = nilo.App.init(std.heap.smp_allocator);
    defer app.deinit();

    var exporter: Exporter = .{};
    try app.provide(&exporter);
    try app.spawn(flushEvery, .{&exporter});

    try app.listen(.{});
}
```

`zig build run-scheduled` is a smaller version of this, with a route that gives the loop something to count.

Three things about that loop matter.

**`nilo.sleep` pauses the fiber, not the thread.** Many requests share one OS thread. `std.Thread.sleep` there would stop every one of them for a minute; `nilo.sleep` stops only this fiber.

**`error.Canceled` means the server is shutting down, and it is the only way out of the loop.** The server owns the fiber exactly as it owns a connection: it is counted while it runs, and cut off when the shutdown grace period ends. Nothing else ends the loop, so `catch return` is not just tidiness: it is how the process gets to exit. The cancellation is reported once, and it may land in the work rather than in the `sleep`. A nilo call that turns it into an error of its own hands it back, so the next `sleep` still returns `Canceled` ([ADR 223](../adr/223-a-statement-cut-off-by-a-cancellation-hands-it-back.md)).

**The function cannot return an error.** There is no request and nobody to answer, so an error has nowhere to go but the log.

## Choosing when it starts

**`app.spawn` and `nilo.spawn` start the same kind of fiber; the difference is when.**

| | |
|---|---|
| `app.spawn(f, args)` | registered before the server, started once it is up |
| `nilo.spawn(f, args)` | started now; `error.NoServer` if nothing is listening |

A handler calls `nilo.spawn`, for a request that starts something that outlives it. It needs a running server, and inside a handler there always is one.

`main` calls [`app.spawn`](../reference/app.md#app). It exists because `listen()` does not return, so there is no "after the server started" point to write a line in. Registered next to the routes, it starts after the port is taken and before the first connection is accepted.

**Work that has to finish before the first request uses `app.before`.** A migration, a version check, a key set fetched once: such work needs the services, so it runs inside `listen()`, after the services have started and before anything registered with `app.spawn` ([Applying](./sql/migrations.md#applying-migrations)):

```zig
fn migrate(run: *nilo.Run, db: *sql.Db) !void {
    try sql.migrate.applyPending(db, run, try manifest.chain(run.arena()));
}

try app.provide(&db);
try app.before(migrate, .{&db});     // runs once, on the server's loop
try app.spawn(flushEvery, .{&exporter});
try app.listen(.{ .port = 8080 });
```

The function takes the startup's `nilo.Run` first, then whatever it was registered with. If it fails, the server does not start: a migration that could not run means a database this binary must not serve. The order between `before` and `spawn` is fixed, not decided by which line comes first: the services, then `before`, then the fibers ([ADR 180](../adr/180-work-that-needs-the-services-runs-on-their-loop.md)).

`app.start(io)` is for a program that never listens: a test, a script, a worker on `jobs.serveOn(io)`. Calling `listen()` after it is refused, because a service keeps the `Io` it was started on and `listen()` runs on a loop of its own (ADR 180).

## A queue a handler fills and a fiber empties

**When many requests need one thing done in order, once, for all of them, that thing is a fiber and the requests wait for it.** A write-ahead log is the case: one writer takes whatever has queued, writes it with one `fsync`, and wakes everyone whose bytes were in the batch. A handler gets the server's `std.Io` by asking for it, and puts its work on a `std.Io.Queue`, then waits on a `std.Io.Event` the writer sets ([ADR 244](../adr/244-a-handler-is-given-the-loop-it-runs-on.md)).

<!-- compiles -->
```zig
const std = @import("std");
const nilo = @import("nilo_http");

const Append = struct {
    bytes: []const u8,
    done: std.Io.Event = .unset,
    /// Set by the writer before `done`: false means it never reached disk.
    written: bool = false,
};

const Wal = struct {
    slots: [256]*Append = undefined,
    queue: std.Io.Queue(*Append) = undefined,

    /// In place: the queue points into `slots`, so a `Wal` returned by value
    /// would leave it pointing at a copy that is gone.
    fn init(self: *Wal) void {
        self.queue = .init(&self.slots);
    }

    /// The one writer. `app.spawn` starts it; the server cancels it when the
    /// shutdown grace period is over.
    fn write(self: *Wal) void {
        const io = nilo.io();
        var batch: [64]*Append = undefined;
        while (true) {
            // Waits for one, takes whatever else is already there.
            const n = self.queue.get(io, &batch, 1) catch break;
            // …write batch[0..n] and sync once, true if it reached disk…
            const ok = true;
            for (batch[0..n]) |item| {
                item.written = ok;
                item.done.set(io);
            }
        }
        // Cancelled. Close first, so no new append gets in, then answer every
        // append still queued: each of their handlers is waiting on `done`.
        self.queue.close(io);
        while (true) {
            const n = self.queue.getUncancelable(io, &batch, 1) catch return;
            for (batch[0..n]) |item| item.done.set(io);
        }
    }
};

fn append(io: std.Io, wal: *Wal, c: *nilo.Ctx) !void {
    var item: Append = .{ .bytes = (try c.body()).view() };
    wal.queue.putOne(io, &item) catch |err| switch (err) {
        error.Closed => return nilo.fail.status(503, "the log is shutting down", .{}),
        else => |e| return e,
    };
    // From here the writer holds a pointer into this frame, so the handler
    // waits for its answer even if it is cancelled.
    item.done.waitUncancelable(io);
    if (!item.written) return nilo.fail.status(503, "the log is shutting down", .{});
}

pub fn main() !void {
    var app = nilo.App.init(std.heap.smp_allocator);
    defer app.deinit();

    var wal: Wal = .{};
    wal.init();
    try app.provide(&wal);
    try app.post("/append", append);
    try app.spawn(Wal.write, .{&wal});

    try app.listen(.{});
}
```

Four things make this safe.

**A wait on the queue or the event parks the fiber, not the thread.** The `Io` is the loop the connections run on, so `putOne` and `wait` suspend the handler exactly as `nilo.sleep` does, and the writer is a fiber on the same loop.

**The item lives on the handler's stack, so once it is queued the handler waits whatever happens.** After `putOne` the writer holds a pointer into the handler's frame, and a handler that returned on `error.Canceled` would leave that pointer dangling. `waitUncancelable` is what holds the frame until the writer answers, and the writer's promise is the other half: every append it takes or finds queued gets `done` set, written or not.

**Shutdown ends the loop the way it ends `flushEvery`.** The server stops accepting, gives in-flight requests the grace period, and only then cancels the writer, so appends already waiting are still written. `get` then returns `error.Canceled`; the writer closes the queue, so a late `putOne` is `error.Closed`, and answers every append still queued with `written` false, so their handlers end with a 503 instead of waiting on an event nobody sets.

**A long wait is not reported as a blocked thread.** The detector ([ADR 013](../adr/013-handlers-must-not-block-the-thread.md)) is not told about an `Io` wait, but it sees that the server's loop turned over while the handler waited, and a handler that parked has not held its thread. What it does report is the handler running for `block_warning_ms` (250 ms) without waiting, counted from when the wait ended. A writer that can stall still needs a deadline on its own write, because a queued handler cannot stop waiting.

**A writer that must also wake while it is idle needs a deadline, and `queue.get` has none.** A log that hands its tail on when the active segment grows old has to run at that age with nobody appending, and `get(io, &batch, 1)` waits for an item for as long as it takes. `std.Io.Queue` has no get with a timeout. The queue plus a `std.Io.Event` has one: every putter sets the event after `put`, and the writer resets it, drains without waiting (`min` of 0), and only when the drain found nothing waits on the event with a timeout:

<!-- compiles -->
```zig
const std = @import("std");
const nilo = @import("nilo_http");

const IdleAppend = struct {
    done: std.Io.Event = .unset,
    written: bool = false,
};

const IdleWal = struct {
    slots: [256]*IdleAppend = undefined,
    queue: std.Io.Queue(*IdleAppend) = undefined,
    /// Set by every putter after `put`; reset by the writer before it drains.
    wake: std.Io.Event = .unset,

    fn init(self: *IdleWal) void {
        self.queue = .init(&self.slots);
    }

    /// What a handler calls instead of `queue.putOne`.
    fn put(self: *IdleWal, io: std.Io, item: *IdleAppend) !void {
        try self.queue.putOne(io, item);
        self.wake.set(io);
    }

    fn write(self: *IdleWal) void {
        const io = nilo.io();
        var batch: [64]*IdleAppend = undefined;
        while (true) {
            // Reset, then drain. A put that lands after the drain sets the
            // event again, so the wait below returns at once: no wake-up is
            // lost, which resetting after the drain would not promise.
            self.wake.reset();
            const n = self.queue.get(io, &batch, 0) catch break;
            if (n == 0) {
                self.wake.waitTimeout(io, .{ .duration = .{
                    .raw = .fromMilliseconds(500),
                    .clock = .awake,
                } }) catch |err| switch (err) {
                    // Idle for the whole deadline: hand the tail on here.
                    error.Timeout => {},
                    error.Canceled => break,
                };
                continue;
            }
            // …write batch[0..n] and sync once…
            for (batch[0..n]) |item| {
                item.written = true;
                item.done.set(io);
            }
        }
        // Cancelled: close, then answer what is still queued, as above.
        self.queue.close(io);
        while (true) {
            const n = self.queue.getUncancelable(io, &batch, 1) catch return;
            for (batch[0..n]) |item| item.done.set(io);
        }
    }
};
```

`waitTimeout` may also return `error.Timeout` on a spurious wake-up, so the timeout branch is "check the deadline", never "the deadline has passed". The cost is one `Event` word per log and one `set` per append, which is a store when nobody waits. A test of it needs the real loop, and [`testing.Live`](./testing.md#a-real-server-in-a-test) has one.

**To test it in memory, start the writer yourself.** `nilo.testing.Wired` has no server and cannot run `app.spawn`, but `io: std.Io` and `c.io()` answer a process-wide `std.Io.Threaded` there, and `wired.io()` hands a test the same one:

```zig
var wired = try nilo.testing.Wired.init(testing.allocator, .{});
defer wired.deinit();

var wal: Wal = .{};
wal.init();
try wired.app.provide(&wal);
try wired.app.post("/append", append);

var writing = try wired.io().concurrent(Wal.write, .{&wal});
defer _ = writing.cancel(wired.io());

const answer = try wired.post("/append", "{}");
try testing.expectEqual(@as(u16, 200), answer.status);
```

`Wal.write` calls `nilo.io()`, which with no server running is that same `Threaded`, so the writer and the handler share one loop here as they do in production.

## What not to pass in

**Do not pass a `Str` or use a fail function in background work.** The compiler refuses the first and not the second, and both apply to `nilo.spawn` in the same way.

**A `Str`.** It points into the request arena, which is reset when the request ends, and background work outlives the request that started it. `app.spawn` and `nilo.spawn` refuse, while compiling, an argument that is a `Str`, a `Ctx` or a pointer to one, or that holds one in a field, a slice, an optional or behind a pointer, and the message names the argument. Copy anything borrowed from a request before passing it in, with `.keep()` or your own allocation. A capture through a variable at file level is the one route the compiler does not see.

**A fail function.** `fail.notFound` and the others write their message into the request being served. There is no request here, so it returns a plain error with no message, and nothing builds a response from it. Log instead.

## What it costs

**Nothing per request and nothing per connection.** The request path is untouched, and each of these is one fiber for the whole process, not one per socket.

The fiber itself is not free. A suspended fiber holds its stack at the highest point it ever reached for as long as it lives ([ADR 062](../adr/062-where-a-connection-waits-is-what-it-costs.md)). For a fiber like this one that is a few kilobytes that never come back, paid once per thing you spawn. Spawn a handful, not one per row in a table.

## What it does not do

**There is no schedule language here**: no cron expressions, no "at 03:00 on Sundays", no policy for what happens when one tick runs into the next. A `sleep` in a loop is all there is, on purpose. Each of those policies has an answer that is right for some programs and wrong for others, and the loop keeps the choice where you can read it. Those policies *are* written in [`nilo_job`](./jobs.md), where a scheduled job must declare what an overlap and a missed tick mean or it does not compile, and where a tick is a database row that survives a restart. A fiber is for work that is a loop; a job is for work that is a row.

There is also no way to send a message to another connection's socket from here. That is a `Room`, covered in [its own section](./websocket.md#broadcasting-with-niloroom).
