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
//! the loop doing its job. `/health` is the control: the same server, the
//! same routing, no database.

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
    var db = sql.Db.init(gpa, url, .{ .size = size, .connect_on_init = @min(size, 8) });
    defer db.deinit();

    var app = nilo.App.init(gpa);
    defer app.deinit();

    try app.provide(&db);
    try app.get("/people/:id", getPerson);
    try app.get("/health", health);

    // No logger, for the reason `bench/main.zig` gives: a line per request
    // would measure the logger.
    try app.listen(.{ .port = 8788 });
}
