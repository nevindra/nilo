//! Whether a Postgres wait costs a fiber or a thread.
//!
//! `bench/sql.zig` measures one connection sending one statement at a time
//! and finds that **a prepared key lookup is 26 µs, of which 24 µs is the
//! round trip** — the query itself is about two. The client spends 87% of
//! that blocked, one voluntary context switch per query.
//!
//! Which is fine, or fatal, depending on one thing: what the fiber does
//! while it waits. If the read suspends and the loop runs somebody else,
//! 24 µs is latency and the server's capacity is `pool size / 24 µs`. If it
//! blocks the OS thread, capacity is `threads / 24 µs` and the database
//! layer is the bottleneck of every application built on it — which is the
//! failure mode ADR 0014 names and the reason `nilo_start` exists at all.
//!
//! Reading the source says it suspends: pg.zig holds an `Io.net.Stream` and
//! reads through the `Io` it was handed, which under the engine is zio's.
//! **That is an argument, and this is the measurement.** Start it and point
//! the load generator at it:
//!
//! ```
//! zig build -Doptimize=ReleaseFast bench-sql-server
//! DATABASE_URL=postgres://nilo:nilo@localhost:5433/nilo ./zig-out/bin/nilo-bench-sql-server
//! ./bench/bench.sh http://127.0.0.1:8788/people/42
//! ```
//!
//! The number to compare against is 1 ÷ 24 µs ≈ **41,000 requests a second,
//! which is what one blocked thread would cap at.** Anything well past it is
//! the loop doing its job.
//!
//! ## Four routes, because a number needs something standing next to it
//!
//! - `/health` — a constant `[]const u8`, no `Ctx`. The floor.
//! - `/fixed/:id` — the same JSON `/people/:id` answers with, from a
//!   constant. Same `Ctx`, same serialiser, no database.
//! - `/deep/:id` — `/fixed/:id` plus eight kilobytes of stack touched and
//!   nothing else. The control that found what the memory actually was.
//! - `/people/:id` — one `db.find`.
//!
//! `POOL_SIZE` and `PREPARED=0` are the two knobs. Memory per idle
//! connection is measured by opening N keep-alive connections, doing one
//! request on each, and reading `VmRSS` while they sit there
//! ([ADR 0063](../docs/adr/0063-a-handlers-stack-is-per-connection.md)).

const std = @import("std");
const nilo = @import("nilo_http");
const sql = @import("nilo_sql");
const fail = nilo.fail;

pub const std_options = nilo.std_options;
pub const std_options_debug_io = nilo.debug_io;
pub const panic = nilo.panic;

/// The same table `bench/sql.zig` builds, and the same four columns — so
/// the per-query number this server is compared against is the one that
/// bench printed rather than a near relative of it.
const Person = struct {
    pub const nilo_table = .{ .name = "nilo_bench_people", .key = .id };

    id: i64,
    email: nilo.Str,
    age: i32,
    created_at: sql.Timestamp,
};

fn getPerson(db: *sql.Db, c: *nilo.Ctx, id: i64) !Person {
    return try db.find(Person, c, id) orelse fail.notFound("no person {d}", .{id});
}

/// The control. Same server, same router, same response path, no database —
/// so the difference between the two numbers is the whole of what a query
/// costs a *server*, as opposed to what it costs a caller.
fn health() []const u8 {
    return "alive\n";
}

/// The third route, and the control for the control. `/health` returns a
/// constant `[]const u8` and takes no `Ctx`; this returns the same JSON
/// shape `/people/:id` does, from a constant, through the same serialiser —
/// so the difference between *this* and `/people/:id` is the database and
/// nothing else, and the difference between this and `/health` is what a
/// handler that does ordinary work costs (ADR 0063).
fn fixedPerson(c: *nilo.Ctx, id: i64) !Person {
    return .{
        .id = id,
        .email = c.str("p42@example.dev"),
        .age = 62,
        .created_at = .{ .micros = 1_755_374_094_000_000 },
    };
}

/// No database, no allocation, one deep-ish stack frame — the test of what
/// the 7.6 kB between `/fixed/:id` and `/people/:id` actually is. If a
/// handler that only *touches* eight kilobytes of its own stack holds the
/// same extra memory per idle connection, then memory per connection is a
/// function of the deepest stack that connection's fiber ever reached, and
/// not of anything the database did (ADR 0063).
fn deepStack(c: *nilo.Ctx, id: i64) !Person {
    var pad: [8192]u8 = undefined;
    @memset(&pad, @truncate(@as(u64, @bitCast(id))));
    std.mem.doNotOptimizeAway(&pad);
    return fixedPerson(c, id);
}

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.smp_allocator;

    const url = init.minimal.environ.getPosix("DATABASE_URL") orelse {
        std.debug.print(
            "bench-sql-server needs a database.\n" ++
                "  DATABASE_URL=postgres://… ./zig-out/bin/nilo-bench-sql-server\n" ++
                "  docker compose -f sql/docker-compose.yml up -d\n" ++
                "  then run bench/sql.zig once to build the table.\n",
            .{},
        );
        return;
    };

    // Sized so the pool is not what runs out first: the question is whether
    // a waiting fiber frees the thread, and a pool of ten would cap the
    // answer at ten in flight whatever the loop does.
    //
    // `POOL_SIZE` overrides it, because "how many connections" turned out to
    // be the one knob users are told to raise and nobody had measured the
    // curve behind it (ADR 0062).
    const size: u16 = if (init.minimal.environ.getPosix("POOL_SIZE")) |text|
        std.fmt.parseInt(u16, text, 10) catch 64
    else
        64;
    // `PREPARED=0` turns the statement cache off, which is how the memory
    // it costs per connection was measured (ADR 0057).
    const prepared = if (init.minimal.environ.getPosix("PREPARED")) |text|
        !std.mem.eql(u8, text, "0")
    else
        true;
    // The whole pool dialled here rather than filled in the background:
    // this is a benchmark, and a pool still filling during the first second
    // of a run is a number about the reconnector.
    var db = sql.Db.init(gpa, url, .{
        .size = size,
        .connect_on_init = size,
        .prepared = prepared,
    });
    defer db.deinit();

    var app = nilo.App.init(gpa);
    defer app.deinit();

    try app.provide(&db);
    try app.get("/people/:id", getPerson);
    try app.get("/health", health);
    try app.get("/fixed/:id", fixedPerson);
    try app.get("/deep/:id", deepStack);

    // No logger, for the reason `bench/main.zig` gives: a line per request
    // would measure the logger.
    try app.listen(.{ .port = 8788 });
}
