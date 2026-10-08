//! What an open stream costs while nothing is arriving on it.
//!
//! `docs/guide/streaming.md` used to say **~21 KB** a stream and tell the
//! reader to plan ten thousand of them around it. That figure predates both
//! [ADR 062](../docs/adr/062-where-a-connection-waits-is-what-it-costs.md), which
//! found that a handler holds its stack at its high-water mark, and
//! [ADR 062](../docs/adr/062-where-a-connection-waits-is-what-it-costs.md),
//! which took an idle connection to 4,669 bytes. A stream is neither of those:
//! it is a handler that has not returned, so it holds its buffers **and** its
//! stack, and neither finding says what the total is. The guide says nothing
//! instead of saying the old number, which is honest and not useful.
//!
//! This is the server that answers it, and `bench/mem.py --hold` is what drives
//! it:
//!
//! ```
//! zig build bench-stream-server -Doptimize=ReleaseFast
//! python3 bench/mem.py --port 8790 --path /health           # the control
//! python3 bench/mem.py --port 8790 --path /stream --hold    # the stream
//! ```
//!
//! `--hold` is the whole reason this file exists rather than
//! `examples/stream`. `mem.py` drains a response before calling a connection
//! idle, and a stream that is being held open has no end to drain to, so the
//! harness could not measure the one thing this measures.
//!
//! ## Seven routes, because a number needs something standing next to it
//!
//! - `/health` — HTTP, a constant, no `Ctx`. The 4,669-byte floor re-taken on
//!   this binary, so the stream rows are compared against a number from the
//!   same run rather than one from another document (`bench/sql_server.zig`'s
//!   fourth route is here for the same reason).
//! - `/stream` — an event stream that sends one event and then waits. What a
//!   held stream costs, logger and all.
//! - `/stream/quiet` — the same, with **no middleware in front of it**, which
//!   is the control for the logger itself
//!   ([ADR 062](../docs/adr/062-where-a-connection-waits-is-what-it-costs.md)
//!   §3: a format string costs stack whether or not it is ever printed).
//! - `/stream/deep` — 32 KiB of stack touched before the first wait. ADR 062's
//!   `/deep/:id` control on this path: the cost the framework cannot give back,
//!   because the frame holding it is live for as long as the stream is.
//!
//! - `/events/room` — an event stream in a `Room`, handed to the connection
//!   with `c.eventsFrom` (ADR 227). Against `/stream`, what the handler that
//!   no longer waits was costing.
//! - `/events/room/deep` — the same with 32 KiB touched first. Against
//!   `/stream/deep`, whether the handler's stack still stays: it should not,
//!   because the handler has returned before the connection waits.
//! - `/events/named` — `/events/room` sitting under a key of its own as well,
//!   `user:<n>` with a new `n` every connection, lent from a `nilo.Rooms` pool
//!   (ADR 228). Against `/events/room`, what a key costs a connection, which
//!   should be nothing: the pool's Rooms are made before the listener opens.
//!
//! `KEEPALIVE_MS` sets `eventsFrom`'s keep-alive and **defaults to 0 here, not
//! the framework's 30,000**, for `bench/ws_server.zig`'s reason: a comment
//! every thirty seconds wakes every stream in the measurement.
//!
//! The logger is installed on purpose, which is the opposite of what
//! `bench/ws_server.zig` and `bench/main.zig` do. They are measuring the
//! framework and anything installed would be measured with it; this is
//! measuring what a deployed server holds, and `logger.standard` is in every
//! example and every guide.

const std = @import("std");
const nilo = @import("nilo_http");

pub const std_options = nilo.std_options;
pub const std_options_debug_io = nilo.debug_io;
pub const panic = nilo.panic;

/// How long a held stream waits between events, in milliseconds. Long enough
/// that `mem.py`'s settle never sees a second event, so what is measured is a
/// stream waiting rather than a stream working.
var hold_ms: u64 = 600_000;

/// The control, and the same handler `bench/sql_server.zig` and
/// `bench/ws_server.zig` both use for it.
fn health() []const u8 {
    return "alive\n";
}

/// One event, then a wait long enough to be measured through. `live()` is what
/// lets a Ctrl-C end it rather than waiting the full ten minutes out.
fn held(c: *nilo.Ctx) !void {
    var events = try c.events();
    try events.send(.{ .name = "open", .data = "1" });
    while (events.live()) {
        nilo.sleep(hold_ms) catch break;
    }
}

/// The same, with 32 KiB touched on the handler's own stack first. A suspended
/// fiber holds its stack at its high-water mark, so this is the difference
/// between what the framework costs and what a handler costs on top of it.
fn heldDeep(c: *nilo.Ctx) !void {
    var pad: [32 * 1024]u8 = undefined;
    @memset(&pad, 0x5a);
    std.mem.doNotOptimizeAway(&pad);
    return held(c);
}

/// Read once in `main`, like `hold_ms`.
var keepalive_ms: u32 = 0;

/// The room both `/events/room` routes sit in, sized past the largest step
/// `mem.py` takes so it is never full.
var feed_room: *nilo.Room = undefined;

/// Nothing held: the head goes out, the stream takes a seat, and the handler
/// returns. The connection waits from its own frame (ADR 227).
fn roomFeed(c: *nilo.Ctx) !void {
    return c.eventsFrom(feed_room, .{ .keepalive_ms = keepalive_ms });
}

/// The same with 32 KiB touched first, which `/stream/deep` holds for as long
/// as the stream is open. Here the frame has returned before anything waits.
fn roomFeedDeep(c: *nilo.Ctx) !void {
    var pad: [32 * 1024]u8 = undefined;
    @memset(&pad, 0x5a);
    std.mem.doNotOptimizeAway(&pad);
    return roomFeed(c);
}

/// Posts into `feed_room` for `BLAST_MS` (2,000 by default) as fast as it can,
/// a burst and then a turn for the connections, and answers how many it made.
/// `bench/fanout.py` counts what the subscribers were written (stage 6.3).
fn blast(c: *nilo.Ctx) !void {
    const until = nilo.monotonicNanos() + blast_ms * std.time.ns_per_ms;
    var n: u64 = 0;
    while (nilo.monotonicNanos() < until) {
        for (0..16) |_| {
            feed_room.print("event {d}", .{n}) catch {};
            n += 1;
        }
        nilo.sleep(0) catch break;
    }
    var buf: [32]u8 = undefined;
    return c.sendText(200, try std.fmt.bufPrint(&buf, "{d}\n", .{n}));
}
var blast_ms: u64 = 2000;

/// The pool `/events/named` borrows a Room from, one per connection, sized
/// like `feed_room`.
var pool: *nilo.Rooms = undefined;
var next_user = std.atomic.Value(u64).init(0);

/// A key per connection, the send-to-one-user shape: every stream is alone
/// under its own, and in the shared room beside it.
fn namedFeed(c: *nilo.Ctx) !void {
    var key: [32]u8 = undefined;
    const mine = try std.fmt.bufPrint(&key, "user:{d}", .{next_user.fetchAdd(1, .monotonic)});
    return c.eventsFrom(.{ feed_room, pool.named(mine) }, .{ .keepalive_ms = keepalive_ms });
}

fn millisFrom(init: std.process.Init, name: []const u8, default: u64) u64 {
    const text = init.minimal.environ.getPosix(name) orelse return default;
    return std.fmt.parseInt(u64, text, 10) catch default;
}

pub fn main(init: std.process.Init) !void {
    hold_ms = millisFrom(init, "HOLD_MS", hold_ms);
    keepalive_ms = @intCast(millisFrom(init, "KEEPALIVE_MS", 0));
    blast_ms = millisFrom(init, "BLAST_MS", blast_ms);

    var room = try nilo.Room.initWith(std.heap.smp_allocator, .{ .seats = 20_000, .backlog = @intCast(millisFrom(init, "BACKLOG", 4)) });
    defer room.deinit();
    feed_room = &room;
    var rooms = try nilo.Rooms.initWith(std.heap.smp_allocator, .{ .rooms = 20_000, .seats = 1 });
    defer rooms.deinit();
    pool = &rooms;

    var app = nilo.App.init(std.heap.smp_allocator);
    defer app.deinit();

    try app.use(nilo.logger.standard);

    try app.get("/health", health);
    try app.get("/stream", held);
    try app.get("/stream/deep", heldDeep);
    try app.get("/events/room", roomFeed);
    try app.get("/events/room/deep", roomFeedDeep);
    try app.get("/events/named", namedFeed);
    try app.get("/blast", blast);

    // The control for the logger itself. **Registration order buys nothing
    // here** — `use` says so in as many words, because chains are resolved in
    // `listen()` — so the exemption is the one ADR 008 built, attached to the
    // route rather than typed as a second string somewhere else.
    const quiet = app.without(nilo.logger.standard);
    try quiet.get("/stream/quiet", held);

    try app.listen(.{ .port = 8790 });
}
