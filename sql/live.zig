//! The tests that need a database, and the only ones in this module that
//! do (ADR 036).
//!
//! Everything else in `sql/` is a pure function — SQL text out of types,
//! a schema comparison, a Row filled from a Fake — and runs in
//! `zig build test-sql` with nothing installed. These are the other half:
//! statements that were only ever checked against what this module *thinks*
//! Postgres accepts, run against a Postgres that gets a vote.
//!
//! `DATABASE_URL`, or `-Ddatabase-url=…`. With neither, every test here
//! skips, which is the case on the machine of somebody who cloned this to
//! read it. `docker-compose.yml` beside this file starts one:
//!
//! ```
//! docker compose -f sql/docker-compose.yml up -d
//! DATABASE_URL=postgres://nilo:nilo@localhost:5433/nilo zig build test-sql
//! ```
//!
//! The URL is read by `build.zig` and compiled in, rather than read here
//! out of the environment. A test binary that behaves differently depending
//! on who ran it is the opposite of what a test is for; this way what a
//! given binary connects to is fixed when it is built.
//!
//! Skipping rather than failing is the decision, and it is the same one
//! `test` and `test-all` already make about each other: the loop somebody
//! runs every thirty seconds must not need a service to be up, or it stops
//! being run every thirty seconds. On CI it is not optional: with `$CI` set
//! and no URL, `build.zig` fails `test-sql` before anything runs, and every
//! connection dialled here gives up on a lock or an idle transaction after
//! ten seconds, so a leaked one fails a test rather than hanging the run
//! (ADR 239).
//!
//! ## Why there is no event loop here
//!
//! pg.zig wants a `std.Io`, and the one nilo runs on belongs to zio, which
//! nothing outside `src/engine/` may name (ADR 001). It does not have to
//! be zio's: `std.Io.Threaded` is std's own implementation, so these tests
//! build one, hand it to `nilo_start` exactly as `listen()` would, and
//! never start a server at all. That the Wire cannot tell the difference is
//! the point of it taking a `std.Io` rather than a runtime.

const std = @import("std");
const core = @import("nilo_core");
const nilo = @import("nilo_http");
const live_config = @import("live_config");

const db_mod = @import("db.zig");
const ddl = @import("ddl.zig");
const dialect = @import("dialect.zig");
const migrate = @import("migrate.zig");
const postgres = @import("postgres.zig");
const schema = @import("schema.zig");
const types = @import("types.zig");
const where_mod = @import("where.zig");
const wire_mod = @import("wire.zig");

const builtin = @import("builtin");

const testing = std.testing;

/// The table these tests own, **named after the optimize mode**.
///
/// `zig build test-sql` runs two test binaries, Debug and ReleaseSafe, and
/// runs them at the same time. Pointed at one database they would drop and
/// re-create each other's fixture mid-test, which shows up as a duplicate
/// key on a table nobody inserted into twice — and shows up in a different
/// test each run, which is what a race looks like from the outside.
///
/// One table each is the cheapest fix that leaves both runs independent.
/// Serialising the two steps would have worked and would have cost the
/// parallelism for a reason that has nothing to do with either test.
/// Lower case, spelled out rather than taken from `@tagName`, because
/// Postgres folds an unquoted identifier to lower case and the Dialect
/// always quotes: `CREATE TABLE x_Debug` makes `x_debug`, and
/// `SELECT … FROM "x_Debug"` then cannot find it.
const mode_suffix = switch (builtin.mode) {
    .debug => "debug",
    .safe => "releasesafe",
    .fast => "releasefast",
    .small => "releasesmall",
};

const table = "nilo_live_people_" ++ mode_suffix;

/// A Postgres enum type, which the fixture owns for the same reason it owns
/// the table: two optimize modes run at once against one database, and a
/// `DROP TYPE` from the other run mid-test is the same race by another name.
const role_type = "nilo_live_role_" ++ mode_suffix;

/// A second table, for the array columns.
///
/// A table of their own rather than two more columns on the first, and the
/// reason is the fixture rather than tidiness: the rows an array needs are
/// **rows that go wrong** — one holding a NULL among its elements, one holding
/// an array two dimensions deep — and every count and every ordered body
/// asserted against the first table would have had to move to make room for
/// them. A wrong row is not something to hide in a table other tests read.
const list_table = "nilo_live_tickets_" ++ mode_suffix;

/// A view and a materialized view over the first table, and a table whose two
/// interesting columns are filled in by the database rather than by a caller.
///
/// A view earns a fixture of its own because it is the one relation where the
/// *check* was wrong rather than the read: Postgres does not track `NOT NULL`
/// through one, so every non-optional field of a Row over a view used to be
/// reported as a disagreement and the server refused to start (ADR 050). A
/// materialized view earns one because `information_schema` cannot see it at
/// all.
const adults_view = "nilo_live_adults_" ++ mode_suffix;
const totals_view = "nilo_live_totals_" ++ mode_suffix;
const auto_table = "nilo_live_auto_" ++ mode_suffix;
const lines_table = "nilo_live_lines_" ++ mode_suffix;

/// A schema of its own, so that a qualified name is tested against a table
/// that **only** exists there. A table in `public` with the same name would
/// let a broken `qualify` pass by finding the wrong relation, which is the
/// failure a test for this has to rule out rather than reproduce.
const other_schema = "nilo_live_other_" ++ mode_suffix;
const scoped_table = other_schema ++ ".widgets";

/// A table shaped like a session store: a `bytea` that is looked up by, and
/// a `bytea` that may be null.
///
/// Its own table for the reason `list_table` has one: the column that goes
/// wrong is the point of it. `bytea` was the one column type this module
/// could declare, check at startup and read, and **not write** — every
/// statement that bound one stopped inside the driver, on the first sign-in
/// of the port that found it. Nothing in the suite had a `bytea` to write
/// into, so nothing in the suite could have said so.
const session_table = "nilo_live_sessions_" ++ mode_suffix;

/// Tables of the tests that read a Row's shape and its groups, each named
/// for its mode like every table above, because the Debug and ReleaseSafe
/// suites run at once against one database and would drop each other's.
const unread_deals = "nilo_unread_deals_" ++ mode_suffix;
const shape_customers = "nilo_shape_customers_" ++ mode_suffix;
const shape_orders = "nilo_shape_orders_" ++ mode_suffix;
const shape_lines = "nilo_shape_lines_" ++ mode_suffix;
const group_customers = "nilo_group_customers_" ++ mode_suffix;
const group_orders = "nilo_group_orders_" ++ mode_suffix;

/// Created and dropped by `Live.open`, so a run leaves nothing behind and
/// does not care what else is in the database.
///
/// The three columns Zig has no word for are in this table rather than in
/// one of their own, and that is the whole lesson of them: `Timestamp`,
/// `Uuid` and `Json` were each tested against what this module *believed*
/// Postgres would say, and not one of them was ever read out of a real
/// column. The fixture had `bigint`, `text` and `integer` and nothing else,
/// so the compile error every Row carrying one of them produced was never
/// reached by anything the suite built.
///
/// `seen_at` carries a DEFAULT so that the inserts written before it existed
/// still say what they meant.
///
/// `role` is a Postgres enum, and **the third row holds a value the Zig enum
/// in the test deliberately does not have.** That is not an oversight in the
/// fixture, it is the case: `dialect.accepts` declines to judge an enum, so
/// this is the one column type startup cannot check, and a table that has
/// grown a value the code has not is the way it actually goes wrong.
const setup =
    // Before the table, because a view depends on it and Postgres will not
    // drop a relation something else is built on.
    "DROP MATERIALIZED VIEW IF EXISTS " ++ totals_view ++ ";" ++
    "DROP VIEW IF EXISTS " ++ adults_view ++ ";" ++
    "DROP TABLE IF EXISTS " ++ table ++ ";" ++
    "DROP TYPE IF EXISTS " ++ role_type ++ ";" ++
    "CREATE TYPE " ++ role_type ++ " AS ENUM ('admin', 'member', 'moderator');" ++
    "CREATE TABLE " ++ table ++ " (" ++
    "  id bigint PRIMARY KEY," ++
    // UNIQUE so that an upsert has a conflict target that is *not* the key —
    // which is the case the conflict argument exists for, and the one a
    // `.key`-only design could not have expressed.
    "  email text NOT NULL UNIQUE," ++
    "  handle text," ++
    "  age integer NOT NULL," ++
    "  seen_at timestamptz NOT NULL DEFAULT '2026-08-16T09:30:00Z'," ++
    "  token uuid," ++
    "  settings jsonb," ++
    "  role " ++ role_type ++ " NOT NULL DEFAULT 'member'," ++
    // Unconstrained `numeric`, so the precision this can hold is Postgres's
    // rather than a column definition's — which is what makes the round-trip
    // test below mean something.
    "  balance numeric NOT NULL DEFAULT 0," ++
    // Two column types this module has never had a Zig word for, and the
    // reason they are here rather than in a table of their own: they are read
    // through the same protocol a project's own column type uses, so a test
    // that they round-trip is a test that the protocol does (ADR 049).
    "  stay interval," ++
    "  origin inet," ++
    // A real `date`, written by Postgres and never by nilo, so the four bytes
    // the read below takes apart are the four bytes the server chose. Ada's
    // is before 1970 and Grace's is NULL, which are the two the arithmetic
    // gets wrong.
    "  born date" ++
    ");" ++
    "INSERT INTO " ++ table ++ " (id, email, handle, age, token, settings, role, stay, origin, born) VALUES" ++
    "  (1, 'ada@example.dev', 'ada', 36, '550e8400-e29b-41d4-a716-446655440000', '{\"theme\":\"dark\"}', 'admin', '3 days 04:05:06', '192.168.0.1', '1815-12-10')," ++
    "  (2, 'grace@example.dev', NULL, 45, NULL, NULL, 'member', NULL, NULL, NULL)," ++
    "  (3, 'kid@example.dev', 'kid', 11, '550e8400-e29b-41d4-a716-446655440001', '{\"theme\":\"light\"}', 'moderator', '1 mon', '10.0.0.7/24', '2015-03-01');" ++
    "CREATE VIEW " ++ adults_view ++ " AS SELECT id, email, age FROM " ++ table ++
    "  WHERE age >= 18;" ++
    // `role::text` so the matview's column is a `text` rather than the enum,
    // which is a Row's problem and not this test's.
    "CREATE MATERIALIZED VIEW " ++ totals_view ++ " AS SELECT role::text AS role," ++
    "  count(*)::bigint AS people FROM " ++ table ++ " GROUP BY role;" ++
    "DROP TABLE IF EXISTS " ++ auto_table ++ ";" ++
    "CREATE TABLE " ++ auto_table ++ " (" ++
    "  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY," ++
    "  label text NOT NULL," ++
    "  slug text GENERATED ALWAYS AS (label || '-x') STORED" ++
    ");" ++
    "DROP TABLE IF EXISTS " ++ list_table ++ ";" ++
    "CREATE TABLE " ++ list_table ++ " (" ++
    "  id bigint PRIMARY KEY," ++
    "  tags text[] NOT NULL," ++
    "  scores integer[]," ++
    // `uuid[]` is the array a schema of 145 uuid columns has as many of as it
    // has parent tables, and it is the one the module had no case for at all
    // (ADR 116). Nullable, so the four rows written before it still say what
    // they meant.
    "  owners uuid[]" ++
    ");" ++
    // Row 1 is the ordinary case, row 2 the two edge cases an array has that
    // nothing else does — empty, and null — and rows 3 and 4 are the two
    // shapes Postgres allows and a Zig slice cannot hold.
    "INSERT INTO " ++ list_table ++ " (id, tags, scores, owners) VALUES" ++
    "  (1, ARRAY['urgent','billing'], ARRAY[10,20,30]," ++
    "     ARRAY['550e8400-e29b-41d4-a716-446655440000'," ++
    "           '550e8400-e29b-41d4-a716-446655440001']::uuid[])," ++
    "  (2, ARRAY[]::text[], NULL, ARRAY[]::uuid[])," ++
    "  (3, ARRAY['solo',NULL], NULL, NULL)," ++
    "  (4, ARRAY['deep'], ARRAY[[1,2],[3,4]], NULL);" ++
    "DROP TABLE IF EXISTS " ++ session_table ++ ";" ++
    "CREATE TABLE " ++ session_table ++ " (" ++
    "  id bigint PRIMARY KEY," ++
    "  token_hash bytea NOT NULL," ++
    "  device bytea," ++
    // Who the session belongs to, so a `.exists` over this table has a join
    // to come out of — the guard-around-a-subquery shape needs one.
    "  person_id bigint" ++
    ");" ++
    "DROP SCHEMA IF EXISTS " ++ other_schema ++ " CASCADE;" ++
    "CREATE SCHEMA " ++ other_schema ++ ";" ++
    "CREATE TABLE " ++ scoped_table ++ " (" ++
    "  id bigint PRIMARY KEY," ++
    "  label text NOT NULL" ++
    ");" ++
    "INSERT INTO " ++ scoped_table ++ " (id, label) VALUES (1, 'in another schema');" ++
    // A table as wide as a real one — twenty columns, of which a save
    // writes seventeen — because a batch that compiled at nine columns and
    // not at seventeen was found by a port and not by a test (ADR 169).
    "DROP TABLE IF EXISTS " ++ lines_table ++ ";" ++
    "CREATE TABLE " ++ lines_table ++ " (" ++
    "  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY," ++
    "  rab_id bigint NOT NULL," ++
    "  section_id bigint," ++
    "  position integer NOT NULL," ++
    "  kind text NOT NULL," ++
    "  commitment_id bigint," ++
    "  sku_id bigint," ++
    "  description text NOT NULL," ++
    "  quantity numeric(14,3) NOT NULL," ++
    "  unit text NOT NULL," ++
    "  unit_cost_currency text," ++
    "  unit_cost_amount_minor bigint," ++
    "  cost_source text NOT NULL," ++
    "  notes text," ++
    "  partner_id bigint," ++
    "  lead_days integer," ++
    "  risk text," ++
    "  reference text," ++
    "  created_at timestamptz NOT NULL DEFAULT now()," ++
    "  updated_at timestamptz NOT NULL DEFAULT now()" ++
    ");";

const Person = struct {
    // The `UNIQUE` the fixture's DDL puts on `email`, declared so the upserts
    // below may conflict on it.
    pub const nilo_table = .{ .name = table, .key = .id, .unique = .{.email} };

    id: i64,
    email: []const u8,
    handle: ?[]const u8,
    age: i32,
};

/// A Wire against the real thing, with the fixture loaded, or null when
/// `DATABASE_URL` is unset.
///
/// The `std.Io.Threaded` is returned alongside because it has to outlive
/// the Wire — a pool holds the loop it dials through, and a loop that
/// deinits first takes the connections with it.
const Live = struct {
    threaded: *std.Io.Threaded,
    wire: postgres.Wire,
    arena: std.heap.ArenaAllocator,

    fn open(gpa: std.mem.Allocator) !?Live {
        const url = live_config.database_url orelse return null;
        return try openAt(gpa, url);
    }

    fn openAt(gpa: std.mem.Allocator, url: []const u8) !Live {

        const threaded = try gpa.create(std.Io.Threaded);
        errdefer gpa.destroy(threaded);
        threaded.* = .init(gpa, .{});
        errdefer threaded.deinit();

        // `connect_on_init = 2` — the whole pool, dialled here — and it is
        // not a preference. Anything less leaves pg.zig's reconnector to
        // fill the rest from a `Thread.spawn`ed OS thread, and that thread
        // takes an `xsync.Mutex` against the `Io` it was given.
        // `std.Io.Threaded` cannot park a caller that is not one of its own
        // tasks, so the mutex reaches `unreachable` and takes the test
        // runner with it — 77 of them, the first time this was tried.
        //
        // Under the engine it is fine: zio parks across threads, and
        // `bench/sql_server.zig` boots with the database switched off,
        // connects when it comes up and shuts down clean
        // ([ADR 115](../docs/adr/115-a-boot-dials-the-connection-its-work-needs.md)).
        // So this is a constraint on the *test harness*, and it is written
        // where the harness is.
        var wire = try postgres.Wire.open(threaded.io(), gpa, url, .{
            .size = 2,
            .connect_on_init = 2,
        });
        errdefer wire.close();

        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();

        // The fixture is several statements, which the extended protocol
        // will not take in one message, so they go one at a time.
        var it = std.mem.splitScalar(u8, setup, ';');
        while (it.next()) |raw| {
            const statement = std.mem.trim(u8, raw, " \n\r\t");
            if (statement.len == 0) continue;
            var rows = try wire.run(arena.allocator(), statement, .{}, null, null);
            wire.drain(&rows);
        }

        return .{ .threaded = threaded, .wire = wire, .arena = arena };
    }

    /// **A connection still out when the test ends fails the test.** It is
    /// a transaction or a stream the test never ended, and it used to show
    /// up as the next test's fixture waiting on its locks at no CPU. An
    /// `err` line is what fails a test from a `defer`; the session itself is
    /// ended by the server, past the `idle_in_transaction_session_timeout`
    /// `build.zig` puts on every live connection.
    fn close(self: *Live, gpa: std.mem.Allocator) void {
        const out = self.wire.pool.stats().in_use;
        if (out != 0) std.log.err(
            "the test ended with {d} of its pool's connections still out: a transaction or a stream it never closed",
            .{out},
        );
        self.arena.deinit();
        self.wire.close();
        self.threaded.deinit();
        gpa.destroy(self.threaded);
    }
};

test "a select the comptime half wrote comes back from a real Postgres" {
    const gpa = testing.allocator;
    var live = (try Live.open(gpa)) orelse return error.SkipZigTest;
    defer live.close(gpa);

    const options = .{ .where = .{ .age = .{ .gt = 18 } }, .order = .{ .id = .asc } };
    const stmt = comptime @import("statement.zig").select(dialect.Postgres, Person, @TypeOf(options));

    var rows = try live.wire.run(live.arena.allocator(), stmt.sql, .{@as(i32, 18)}, null, null);
    defer live.wire.drain(&rows);

    var seen: usize = 0;
    while (try live.wire.next(&rows)) : (seen += 1) {
        const id = try live.wire.read(&rows, i64, 0);
        const email = try live.wire.read(&rows, []const u8, 1);
        const age = try live.wire.read(&rows, i32, 3);
        try testing.expect(age > 18);
        try testing.expect(id == 1 or id == 2);
        try testing.expect(std.mem.endsWith(u8, email, "@example.dev"));
    }
    // The eleven-year-old is the one the condition is there to leave out.
    try testing.expectEqual(@as(usize, 2), seen);
}

test "a null column reads as null and a present one does not" {
    const gpa = testing.allocator;
    var live = (try Live.open(gpa)) orelse return error.SkipZigTest;
    defer live.close(gpa);

    var rows = try live.wire.run(
        live.arena.allocator(),
        "SELECT \"handle\" FROM \"" ++ table ++ "\" ORDER BY \"id\"",
        .{},
        null,
        null,
    );
    defer live.wire.drain(&rows);

    try testing.expect(try live.wire.next(&rows));
    try testing.expectEqualStrings("ada", (try live.wire.read(&rows, ?[]const u8, 0)).?);

    try testing.expect(try live.wire.next(&rows));
    try testing.expectEqual(@as(?[]const u8, null), try live.wire.read(&rows, ?[]const u8, 0));
}

test "every connection a live test dials gives up on a lock or an idle transaction after ten seconds" {
    const gpa = testing.allocator;
    var live = (try Live.open(gpa)) orelse return error.SkipZigTest;
    defer live.close(gpa);

    // Both of the pool's connections at once, so each is asked: the bound
    // is the URL's `options=`, which rides in every startup message rather
    // than in a `SET` somebody has to remember per connection.
    const show = "SELECT current_setting('lock_timeout'), current_setting('idle_in_transaction_session_timeout')";
    var first = try live.wire.run(live.arena.allocator(), show, .{}, null, null);
    defer live.wire.drain(&first);
    var second = try live.wire.run(live.arena.allocator(), show, .{}, null, null);
    defer live.wire.drain(&second);
    for ([_]*postgres.Wire.Rows{ &first, &second }) |rows| {
        try testing.expect(try live.wire.next(rows));
        try testing.expectEqualStrings("10s", try live.wire.read(rows, []const u8, 0));
        try testing.expectEqualStrings("10s", try live.wire.read(rows, []const u8, 1));
    }
}

test "the schema comparison agrees with the table it was written against" {
    const gpa = testing.allocator;
    var live = (try Live.open(gpa)) orelse return error.SkipZigTest;
    defer live.close(gpa);

    const arena = live.arena.allocator();
    const actual = try live.wire.columnsOf(arena, dialect.Postgres.introspect, null, table);

    var problems: std.ArrayList(schema.Problem) = .empty;
    const found = try schema.compare(dialect.Postgres, Person, actual, &problems, arena);
    if (found != 0) {
        for (problems.items) |problem| {
            var buf: [512]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buf);
            problem.write(&w) catch {};
            std.debug.print("unexpected: {s}\n", .{w.buffered()});
        }
    }
    try testing.expectEqual(@as(usize, 0), found);
}

test "a table that is not there is one sentence rather than one per column" {
    const gpa = testing.allocator;
    var live = (try Live.open(gpa)) orelse return error.SkipZigTest;
    defer live.close(gpa);

    // The premise, checked against a real Postgres rather than assumed: the
    // introspection query answers *nothing* for a table that is not there.
    // Every column then reported `no_such_column` off the back of it, so
    // forgetting to migrate — the most common way to arrive here — read as a
    // Row that had been written wrong ten different ways.
    const Missing = struct {
        pub const nilo_table = .{ .name = "nilo_no_such_table", .key = .id };

        id: i64,
        email: []const u8,
        age: i32,
    };

    const arena = live.arena.allocator();
    const actual = try live.wire.columnsOf(arena, dialect.Postgres.introspect, null, "nilo_no_such_table");
    try testing.expectEqual(@as(usize, 0), actual.len);

    var problems: std.ArrayList(schema.Problem) = .empty;
    const found = try schema.compare(dialect.Postgres, Missing, actual, &problems, arena);
    try testing.expectEqual(@as(usize, 1), found);
    try testing.expectEqual(schema.Mismatch.no_such_table, problems.items[0].kind);
}

test "a Row that disagrees with the table is caught, which is the point of the check" {
    const gpa = testing.allocator;
    var live = (try Live.open(gpa)) orelse return error.SkipZigTest;
    defer live.close(gpa);

    // `age` is `integer` in the table and `[]const u8` here, and `nickname`
    // is not a column at all. Both are the mistake this check exists for:
    // a 500 at three in the morning, moved to startup.
    const Wrong = struct {
        pub const nilo_table = .{ .name = table, .key = .id };

        id: i64,
        age: []const u8,
        nickname: []const u8,
    };

    const arena = live.arena.allocator();
    const actual = try live.wire.columnsOf(arena, dialect.Postgres.introspect, null, table);

    var problems: std.ArrayList(schema.Problem) = .empty;
    const found = try schema.compare(dialect.Postgres, Wrong, actual, &problems, arena);
    try testing.expectEqual(@as(usize, 2), found);
}

test "a unique violation is AlreadyExists rather than a message nobody translated" {
    const gpa = testing.allocator;
    var live = (try Live.open(gpa)) orelse return error.SkipZigTest;
    defer live.close(gpa);

    // id 1 is in the fixture, and id is the primary key.
    const err = live.wire.run(
        live.arena.allocator(),
        "INSERT INTO \"" ++ table ++ "\" (id, email, age) VALUES ($1, $2, $3)",
        .{ @as(i64, 1), @as([]const u8, "dup@example.dev"), @as(i32, 30) },
        null,
        null,
    );
    try testing.expectError(error.AlreadyExists, err);
}

test "a connection comes back usable after a result set is left unread" {
    const gpa = testing.allocator;
    var live = (try Live.open(gpa)) orelse return error.SkipZigTest;
    defer live.close(gpa);

    const arena = live.arena.allocator();
    const all = "SELECT \"id\" FROM \"" ++ table ++ "\" ORDER BY \"id\"";

    // Read one row of three and walk away, twice as many times as the pool
    // has connections. If `drain` were not giving them back usable, this
    // would run out or reconnect its way through the pool.
    var round: usize = 0;
    while (round < 6) : (round += 1) {
        var rows = try live.wire.run(arena, all, .{}, null, null);
        try testing.expect(try live.wire.next(&rows));
        live.wire.drain(&rows);
    }

    var rows = try live.wire.run(arena, all, .{}, null, null);
    defer live.wire.drain(&rows);
    var seen: usize = 0;
    while (try live.wire.next(&rows)) : (seen += 1) {}
    try testing.expectEqual(@as(usize, 3), seen);
}

fn adults(db: *db_mod.Db, c: *nilo.Ctx) ![]Person {
    return db.select(Person, c, .{
        .where = .{ .age = .{ .gt = 18 } },
        .order = .{ .id = .asc },
    });
}

test "a request goes in as HTTP and comes back as rows from Postgres" {
    const gpa = testing.allocator;
    var live = (try Live.open(gpa)) orelse return error.SkipZigTest;
    defer live.close(gpa);

    // The whole stack, with only the one thing a test cannot have: a server.
    // `nilo_start` would have built this pool; `Live.open` already did, so
    // it is handed over the same way and everything after it is real —
    // routing, the typed layer, the arena, the driver, the database.
    var db = db_mod.Db.init(gpa, "already open", .{});
    db.wire = live.wire;

    var app = nilo.App.init(gpa);
    defer app.deinit();
    try app.provide(&db);
    try app.get("/adults", adults);

    var client = try nilo.testing.Client.init(gpa, .{});
    defer client.deinit();

    const answer = try client.get(&app, "/adults");
    try testing.expectEqual(@as(u16, 200), answer.status);
    try testing.expectEqualStrings(
        "[{\"id\":1,\"email\":\"ada@example.dev\",\"handle\":\"ada\",\"age\":36}," ++
            "{\"id\":2,\"email\":\"grace@example.dev\",\"handle\":null,\"age\":45}]",
        answer.body,
    );
}

test "a Db told what to expect boots against a real Postgres and asks its ledger" {
    const gpa = testing.allocator;
    const url = live_config.database_url orelse return error.SkipZigTest;

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();

    // The boot a deploy runs, minus the server: `nilo_start` dials the pool
    // and `nilo_check` then asks the ledger, on that pool (ADR 180, ADR
    // 180). The whole pool is dialled up front for the reason `Live.open`
    // gives. `expecting(0)` is level or ahead on any database, so the guard
    // goes through; behind is pinned on SQLite in `migrate_live.zig`, where
    // the file is fresh.
    var db = db_mod.Db.init(gpa, url, .{ .size = 2, .connect_on_init = 2, .unchecked = true });
    defer db.deinit();
    db.expecting(0);
    try db.nilo_start(threaded.io(), .off);
    defer db.nilo_stop();
    try db.nilo_check(threaded.io());

    // Boot made the ledger, or this query has no table to read.
    var run: core.Run = .init(gpa);
    defer run.deinit();
    try testing.expect((try migrate.headVersion(&db, &run)) >= 0);
}

test "an unchecked Db on the defaults has a connection to lend the moment it starts" {
    const gpa = testing.allocator;
    const url = live_config.database_url orelse return error.SkipZigTest;

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();

    // `connect_on_init` left at 0 and nothing to check: the shape a program
    // whose tables are its own DDL writes, and then hands `app.before` a
    // migration. Before ADR 115 the pool reached that hook with nothing
    // dialled and the hook got `Disconnected`, every cold boot. `size = 1`
    // so that the one connection the boot dials is the whole pool, and the
    // reconnector has nothing to fill from an OS thread `std.Io.Threaded`
    // cannot park (the constraint `Live.open` states).
    var db = db_mod.Db.init(gpa, url, .{ .size = 1, .unchecked = true });
    defer db.deinit();
    try db.nilo_start(threaded.io(), .off);
    defer db.nilo_stop();

    // What `app.before` does a moment after `nilo_start` returns.
    var run: core.Run = .init(gpa);
    defer run.deinit();
    try testing.expectEqual(@as(?i64, 1), try db.rawOne(i64, &run, "SELECT 1::bigint", .{}));
}

test "a pool says how many connections it has open, idle and lent out, and counts the statements" {
    const gpa = testing.allocator;
    const url = live_config.database_url orelse return error.SkipZigTest;

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();

    // Before `nilo_start` there is no pool to read.
    var db = db_mod.Db.init(gpa, url, .{ .size = 2, .connect_on_init = 2, .unchecked = true });
    defer db.deinit();
    try testing.expectEqual(@as(?wire_mod.PoolStats, null), db.poolStats());

    try db.nilo_start(threaded.io(), .off);
    defer db.nilo_stop();

    // Two dialled at boot (the constraint `Live.open` states), none lent out.
    const idle = db.poolStats().?;
    try testing.expectEqual(@as(usize, 2), idle.size);
    try testing.expectEqual(@as(usize, 2), idle.available);
    try testing.expectEqual(@as(usize, 0), idle.missing);
    try testing.expectEqual(@as(usize, 0), idle.in_use);

    // One statement is one more in `statements`, and leaves the pool as full
    // as it found it.
    var run: core.Run = .init(gpa);
    defer run.deinit();
    try testing.expectEqual(@as(?i64, 1), try db.rawOne(i64, &run, "SELECT 1::bigint", .{}));
    const after = db.poolStats().?;
    try testing.expect(after.statements > idle.statements);
    try testing.expectEqual(@as(usize, 2), after.available);
    try testing.expectEqual(@as(usize, 0), after.in_use);
}

/// A `Limits` that counts what the wire reports through it, for the test below.
var waits_reported: usize = 0;
var waits_closed: usize = 0;
const counting_limits: core.Limits = .{ .vtable = &.{
    .arm = core.Limits.noop.arm,
    .release = core.Limits.noop.release,
    .fired = core.Limits.noop.fired,
    .waiting = struct {
        fn f(_: ?*anyopaque) u64 {
            waits_reported += 1;
            return 1;
        }
    }.f,
    .waited = struct {
        fn f(_: ?*anyopaque, token: u64) void {
            std.debug.assert(token == 1);
            waits_closed += 1;
        }
    }.f,
} };

test "every wait on the database is reported through the Limits the wire was started with" {
    const gpa = testing.allocator;
    const url = live_config.database_url orelse return error.SkipZigTest;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var wire = try postgres.Wire.open(threaded.io(), gpa, url, .{ .size = 1, .connect_on_init = 1, .limits = counting_limits });
    defer wire.close();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    waits_reported = 0;
    waits_closed = 0;
    // One statement is one wait, from the exchange to the close, however
    // many rows come off the socket in between (ADR 210).
    var rows = try wire.run(arena.allocator(), "SELECT generate_series(1, 1000)", .{}, null, null);
    var n: usize = 0;
    while (try wire.next(&rows)) n += 1;
    try testing.expectEqual(@as(usize, 1000), n);
    try testing.expectEqual(@as(usize, 1), waits_reported);
    try testing.expectEqual(@as(usize, 0), waits_closed);
    rows.close();
    try testing.expectEqual(@as(usize, 1), waits_closed);
    // A transaction reports its BEGIN, its statement and its COMMIT.
    const before = waits_reported;
    var tx = try wire.begin(arena.allocator(), .{});
    _ = try tx.exec(arena.allocator(), "SELECT 1", .{}, null, null);
    try tx.commit(arena.allocator(), null);
    try testing.expect(waits_reported - before >= 3);
}

// -- the write half, and the things built on it ---------------------------

/// A `Db` wired to an already-open pool, plus an App and a Client to drive
/// handlers through. Everything except the server, which a test cannot have.
const Stack = struct {
    live: Live,
    db: db_mod.Db,
    app: nilo.App,
    client: nilo.testing.Client,

    fn open(gpa: std.mem.Allocator) !?*Stack {
        const url = live_config.database_url orelse return null;
        return try openAt(gpa, url);
    }

    fn openAt(gpa: std.mem.Allocator, url: []const u8) !*Stack {
        const live = try Live.openAt(gpa, url);
        // Heap-allocated because the App holds a pointer to the Db and the
        // Client hands out a Ctx pointing at the App; moving any of them
        // after wiring would leave those pointing at the old copy.
        const self = try gpa.create(Stack);
        self.* = .{
            .live = live,
            .db = db_mod.Db.init(gpa, "already open", .{}),
            .app = nilo.App.init(gpa),
            .client = try nilo.testing.Client.init(gpa, .{}),
        };
        self.db.wire = self.live.wire;
        try self.app.provide(&self.db);
        return self;
    }

    fn close(self: *Stack, gpa: std.mem.Allocator) void {
        self.client.deinit();
        self.app.deinit();
        // Not `self.db.deinit()`: the pool belongs to `live`, and closing it
        // twice would take the same connections down twice.
        self.live.close(gpa);
        gpa.destroy(self);
    }
};

fn insertOne(db: *db_mod.Db, c: *nilo.Ctx) !nilo.Status(201, Person) {
    return .{ .value = try db.insert(Person, c, .{
        .id = @as(i64, 42),
        .email = "new@example.dev",
        .handle = @as(?[]const u8, "new"),
        .age = @as(i32, 28),
    }) };
}

test "an insert comes back as the row the database stored" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    try stack.app.post("/people", insertOne);
    const answer = try stack.client.post(&stack.app, "/people", "");

    try testing.expectEqual(@as(u16, 201), answer.status);
    try testing.expectEqualStrings(
        "{\"id\":42,\"email\":\"new@example.dev\",\"handle\":\"new\",\"age\":28}",
        answer.body,
    );
}

fn insertDuplicate(db: *db_mod.Db, c: *nilo.Ctx) !Person {
    // id 1 is in the fixture and id is the primary key.
    return db.insert(Person, c, .{
        .id = @as(i64, 1),
        .email = "dup@example.dev",
        .handle = @as(?[]const u8, null),
        .age = @as(i32, 20),
    });
}

test "a duplicate key reaches the handler as AlreadyExists" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    const err = insertDuplicateDirect(&stack.db, &stack.app, &stack.client);
    try testing.expectError(error.AlreadyExists, err);
}

/// The insert above, called for its error rather than through a route, so
/// that the error itself can be asserted on rather than the status it turns
/// into.
fn insertDuplicateDirect(
    db: *db_mod.Db,
    app: *nilo.App,
    client: *nilo.testing.Client,
) !void {
    const Route = struct {
        fn go(d: *db_mod.Db, c: *nilo.Ctx) !Person {
            return insertDuplicate(d, c);
        }
    };
    try app.post("/dup", Route.go);
    const was = std.testing.log_level;
    defer std.testing.log_level = was;
    std.testing.log_level = .err;

    const answer = try client.post(app, "/dup", "");
    _ = db;
    // ADR 004's table gives `AlreadyExists` a 409 and nothing else a
    // default, which is the whole of what "the one whose meaning does not
    // change with the request" buys.
    if (answer.status == 409) return error.AlreadyExists;
    return error.WrongStatus;
}

fn ageUp(db: *db_mod.Db, c: *nilo.Ctx) ![]const u8 {
    const changed = try db.update(Person, c, .{
        .set = .{ .age = @as(i32, 99) },
        .where = .{ .id = @as(i64, 1) },
    });
    return if (changed == 1) "one" else "not one";
}

test "an update says how many rows it changed" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    try stack.app.get("/age-up", ageUp);
    const answer = try stack.client.get(&stack.app, "/age-up");
    try testing.expectEqual(@as(u16, 200), answer.status);
    try testing.expectEqualStrings("one", answer.body);
}

fn deleteKid(db: *db_mod.Db, c: *nilo.Ctx) ![]Person {
    _ = try db.delete(Person, c, .{ .where = .{ .age = .{ .lt = @as(i32, 18) } } });
    return db.select(Person, c, .{ .order = .{ .id = .asc } });
}

test "a delete narrows the table and the next select sees it" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    try stack.app.get("/delete-kid", deleteKid);
    const answer = try stack.client.get(&stack.app, "/delete-kid");
    try testing.expectEqual(@as(u16, 200), answer.status);
    // Three rows in the fixture, one of them under 18.
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, answer.body, "@example.dev"));
}

test "a delete whose list arrived empty is refused before it is sent, rather than emptying the table" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    // "Delete everyone except these" on the day the list is empty. Sent, it
    // is `"id" <> ALL('{}')`, true of every row.
    const keep: []const i64 = &.{};
    try testing.expectError(
        error.QueryFailed,
        stack.db.delete(Person, &run, .{ .where = .{ .id = .{ .not_in = keep } } }),
    );
    // A search box left empty, as the condition of a write.
    try testing.expectError(error.QueryFailed, stack.db.update(Person, &run, .{
        .set = .{ .age = @as(i32, 1) },
        .where = .{ .email = .{ .contains = @as([]const u8, "") } },
    }));
    // The same box holding `%`, handed to a raw pattern as it arrived.
    try testing.expectError(
        error.QueryFailed,
        stack.db.delete(Person, &run, .{ .where = .{ .email = .{ .ilike = @as([]const u8, "%") } } }),
    );
    try testing.expectEqual(@as(usize, 3), try stack.db.count(Person, &run, .{}));

    // Beside a term that narrows, the empty list narrows nothing more and
    // the statement is an ordinary one: it is sent, and matches nothing here.
    try testing.expectEqual(@as(usize, 0), try stack.db.delete(Person, &run, .{
        .where = .{ .id = @as(i64, 999_999), .age = .{ .not_in = @as([]const i32, &.{}) } },
    }));
    // And a list with something in it is the delete it always was.
    try testing.expectEqual(@as(usize, 0), try stack.db.delete(Person, &run, .{
        .where = .{ .id = .{ .not_in = @as([]const i64, &.{ 1, 2, 3 }) } },
    }));
    try testing.expectEqual(@as(usize, 3), try stack.db.count(Person, &run, .{}));
}

test "a negative limit or offset is refused before it is sent, as it is on SQLite" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    try testing.expectError(error.QueryFailed, stack.db.select(Person, &run, .{
        .order = .{ .id = .asc },
        .limit = @as(i64, -1),
    }));
    try testing.expectError(error.QueryFailed, stack.db.page(Person, &run, .{
        .order = .{ .id = .asc },
        .limit = @as(i64, 10),
        .offset = @as(i64, -1),
    }));
    // The connection is fine afterwards: nothing was sent.
    try testing.expectEqual(@as(usize, 3), (try stack.db.select(Person, &run, .{
        .order = .{ .id = .asc },
        .limit = @as(i64, 10),
    })).len);
}

fn rollbackAnInsert(db: *db_mod.Db, c: *nilo.Ctx) ![]Person {
    {
        var tx = try db.begin(c, .{});
        defer tx.deinit();
        _ = try tx.insert(Person, c, .{
            .id = @as(i64, 77),
            .email = "ghost@example.dev",
            .handle = @as(?[]const u8, null),
            .age = @as(i32, 50),
        });
        // and no commit, so `deinit` rolls it back
    }
    return db.select(Person, c, .{ .order = .{ .id = .asc } });
}

test "a transaction nobody committed leaves the table as it was" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    try stack.app.get("/rollback", rollbackAnInsert);
    const answer = try stack.client.get(&stack.app, "/rollback");
    try testing.expectEqual(@as(u16, 200), answer.status);
    try testing.expect(std.mem.indexOf(u8, answer.body, "ghost") == null);
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, answer.body, "@example.dev"));
}

fn commitAnInsert(db: *db_mod.Db, c: *nilo.Ctx) ![]Person {
    {
        var tx = try db.begin(c, .{});
        defer tx.deinit();
        _ = try tx.insert(Person, c, .{
            .id = @as(i64, 78),
            .email = "kept@example.dev",
            .handle = @as(?[]const u8, null),
            .age = @as(i32, 51),
        });
        try tx.commit();
    }
    return db.select(Person, c, .{ .order = .{ .id = .asc } });
}

test "a committed transaction is visible to the next statement" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    try stack.app.get("/commit", commitAnInsert);
    const answer = try stack.client.get(&stack.app, "/commit");
    try testing.expectEqual(@as(u16, 200), answer.status);
    try testing.expect(std.mem.indexOf(u8, answer.body, "kept@example.dev") != null);
}

fn streamEmails(db: *db_mod.Db, c: *nilo.Ctx) ![]const u8 {
    var rows = try db.stream(Person, c, .{ .order = .{ .id = .asc } });
    defer rows.close();

    var out: std.ArrayList(u8) = .empty;
    while (try rows.next()) |p| {
        // `p.email` is a `[]const u8` and not a `Str`, because it dies at
        // the next `next()`. Appending copies it before that happens.
        try out.print(c.arena(), "{d}:{s};", .{ p.id, p.email });
    }
    return out.toOwnedSlice(c.arena());
}

test "a stream reads rows one at a time and the text is good until the next" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    try stack.app.get("/stream", streamEmails);
    const answer = try stack.client.get(&stack.app, "/stream");
    try testing.expectEqual(@as(u16, 200), answer.status);
    try testing.expectEqualStrings(
        "1:ada@example.dev;2:grace@example.dev;3:kid@example.dev;",
        answer.body,
    );
}

fn rawCount(db: *db_mod.Db, c: *nilo.Ctx) ![]Tally {
    // An aggregate, which is exactly what this module refuses to write and
    // exactly what `raw` is for.
    return db.raw(
        Tally,
        c,
        "SELECT count(*)::bigint AS n, min(age)::integer AS youngest" ++
            " FROM \"" ++ table ++ "\" WHERE age > $1",
        .{@as(i32, 18)},
    );
}

/// A Row that no table matches, because what it reads is the shape of an
/// answer rather than of a row. `raw` gives up the column check, and this is
/// what giving it up buys.
const Tally = struct {
    pub const nilo_table = .{ .name = table, .key = .n };

    n: i64,
    youngest: i32,
};

test "raw fills a Row from a statement this module would never write" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    try stack.app.get("/tally", rawCount);
    const answer = try stack.client.get(&stack.app, "/tally");
    try testing.expectEqual(@as(u16, 200), answer.status);
    try testing.expectEqualStrings("[{\"n\":2,\"youngest\":36}]", answer.body);
}

test "count and exists answer with numbers Postgres worked out" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    // The fixture is three people, aged 36, 45 and 11.
    try testing.expectEqual(@as(usize, 3), try stack.db.count(Person, &run, .{}));
    try testing.expectEqual(
        @as(usize, 2),
        try stack.db.count(Person, &run, .{ .where = .{ .age = .{ .gt = 18 } } }),
    );
    try testing.expectEqual(
        @as(usize, 0),
        try stack.db.count(Person, &run, .{ .where = .{ .age = .{ .gt = 200 } } }),
    );

    // `EXISTS` answers a bool, so there is nothing for the caller to compare
    // against zero and no way to get that comparison the wrong way round.
    try testing.expect(try stack.db.exists(Person, &run, .{ .where = .{ .id = @as(i64, 1) } }));
    try testing.expect(!try stack.db.exists(Person, &run, .{ .where = .{ .id = @as(i64, 99) } }));

    // `IS NULL` reaches the count the same way it reaches a select, because
    // it is the same walker: one person in the fixture has no handle.
    try testing.expectEqual(
        @as(usize, 1),
        try stack.db.count(Person, &run, .{ .where = .{ .handle = null } }),
    );
}

test "one asks Postgres for a single row even when many match" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    // `age > 18` matches two rows. Ordered, so which one comes back is the
    // statement's business rather than the planner's.
    const oldest = try stack.db.one(Person, &run, .{
        .where = .{ .age = .{ .gt = 18 } },
        .order = .{ .age = .desc },
    });
    try testing.expectEqual(@as(i64, 2), oldest.?.id);

    const youngest = try stack.db.one(Person, &run, .{
        .where = .{ .age = .{ .gt = 18 } },
        .order = .{ .age = .asc },
    });
    try testing.expectEqual(@as(i64, 1), youngest.?.id);

    // And nothing matching is still null rather than an error — the shape a
    // handler returns as `!?Person` for its 404.
    const nobody = try stack.db.one(Person, &run, .{ .where = .{ .id = @as(i64, 99) } });
    try testing.expectEqual(@as(?Person, null), nobody);
}

test "a count and a page come from one condition written once" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    // What pagination actually is, and what needed `db.raw` and a Row that
    // matched no table before this: a total, and a page of the same query.
    const where = .{ .age = .{ .gt = 10 } };
    const total = try stack.db.count(Person, &run, .{ .where = where });
    const page = try stack.db.select(Person, &run, .{
        .where = where,
        .order = .{ .id = .asc },
        .limit = 2,
    });

    try testing.expectEqual(@as(usize, 3), total);
    try testing.expectEqual(@as(usize, 2), page.len);
    try testing.expectEqual(@as(i64, 1), page[0].id);
    try testing.expectEqual(@as(i64, 2), page[1].id);
}

test "find takes a key, and the column it compares comes from the Row" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    const ada = try stack.db.find(Person, &run, @as(i64, 1));
    try testing.expectEqualStrings("ada@example.dev", ada.?.email);

    // Nothing there is null rather than an error, which is what makes
    // `!?Person` a whole endpoint (ADR 023).
    try testing.expectEqual(
        @as(?Person, null),
        try stack.db.find(Person, &run, @as(i64, 99)),
    );
}

test "a negation asks Postgres the opposite question, not a different one" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    // `<> ALL($1)` is one placeholder holding the whole list, exactly as
    // `= ANY($1)` is — which is the property that keeps the statement a
    // constant, and the reason `not_in` is spelled this way rather than as
    // `NOT (… = ANY(…))`.
    const rest = try stack.db.select(Person, &run, .{
        .where = .{ .id = .{ .not_in = &[_]i64{ 1, 3 } } },
        .order = .{ .id = .asc },
    });
    try testing.expectEqual(@as(usize, 1), rest.len);
    try testing.expectEqual(@as(i64, 2), rest[0].id);

    const grown = try stack.db.select(Person, &run, .{
        .where = .{ .email = .{ .not_like = "kid%" } },
        .order = .{ .id = .asc },
    });
    try testing.expectEqual(@as(usize, 2), grown.len);

    // `NOT ILIKE` folds case and `NOT LIKE` does not, which is the whole of
    // the difference and the reason both exist.
    try testing.expectEqual(
        @as(usize, 0),
        (try stack.db.select(Person, &run, .{
            .where = .{ .email = .{ .not_ilike = "%@EXAMPLE.DEV" } },
        })).len,
    );
    try testing.expectEqual(
        @as(usize, 3),
        (try stack.db.select(Person, &run, .{
            .where = .{ .email = .{ .not_like = "%@EXAMPLE.DEV" } },
        })).len,
    );
}

fn renameAda(db: *db_mod.Db, c: *nilo.Ctx) ![]Person {
    return db.updateReturning(Person, c, .{
        .set = .{ .handle = @as(?[]const u8, "ada.l") },
        .where = .{ .id = @as(i64, 1) },
    });
}

test "an update that returns its rows is a whole PATCH in one statement" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    // The body is the row *after* the write, straight out of the statement
    // that made it. Written with `update` this needed a `SELECT` behind it,
    // which is a second round trip and a second chance for somebody else's
    // write to land in between.
    try stack.app.get("/rename", renameAda);
    const answer = try stack.client.get(&stack.app, "/rename");

    try testing.expectEqual(@as(u16, 200), answer.status);
    try testing.expectEqualStrings(
        "[{\"id\":1,\"email\":\"ada@example.dev\",\"handle\":\"ada.l\",\"age\":36}]",
        answer.body,
    );
}

fn removeKids(db: *db_mod.Db, c: *nilo.Ctx) ![]Person {
    return db.deleteReturning(Person, c, .{ .where = .{ .age = .{ .lt = @as(i32, 18) } } });
}

test "a delete that returns its rows says what it took" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    // Reading them first would be two statements and a race: a row can change
    // between the `SELECT` and the `DELETE`, and what came back then never
    // existed in that shape.
    try stack.app.get("/remove-kids", removeKids);
    const answer = try stack.client.get(&stack.app, "/remove-kids");

    try testing.expectEqual(@as(u16, 200), answer.status);
    try testing.expectEqualStrings(
        "[{\"id\":3,\"email\":\"kid@example.dev\",\"handle\":\"kid\",\"age\":11}]",
        answer.body,
    );
}

fn byIds(db: *db_mod.Db, c: *nilo.Ctx) ![]Person {
    return db.select(Person, c, .{
        .where = .{ .id = .{ .in = &[_]i64{ 1, 3 } } },
        .order = .{ .id = .asc },
    });
}

test "a list condition is one parameter, and Postgres agrees it is an array" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    // `= ANY($1)` rather than `IN ($1, $2)`: one placeholder however long
    // the list is, which is what keeps the statement a constant. This is
    // the test that the wire agrees with that claim.
    try stack.app.get("/by-ids", byIds);
    const answer = try stack.client.get(&stack.app, "/by-ids");

    try testing.expectEqual(@as(u16, 200), answer.status);
    try testing.expect(std.mem.indexOf(u8, answer.body, "ada@example.dev") != null);
    try testing.expect(std.mem.indexOf(u8, answer.body, "kid@example.dev") != null);
    try testing.expect(std.mem.indexOf(u8, answer.body, "grace@example.dev") == null);
}

test "the schema check a nilo_check runs passes on a table that agrees" {
    const gpa = testing.allocator;
    var live = (try Live.open(gpa)) orelse return error.SkipZigTest;
    defer live.close(gpa);

    var db = db_mod.Db.init(gpa, "already open", .{});
    db.wire = live.wire;
    db.checking(.{ .tables = &.{Person} });

    try testing.expectEqual(@as(usize, 0), try db.checkSchema(&.{Person}));
}

// -- the three column types Zig has no word for ---------------------------

const Theme = struct { theme: []const u8 };

/// A Row over the same table, reading only the columns `Person` leaves
/// alone. Kept apart so that the bodies asserted above did not have to move
/// when these columns arrived — and because what is being tested here is the
/// three types, not the table.
const Profile = struct {
    pub const nilo_table = .{ .name = table, .key = .id };

    id: i64,
    seen_at: types.Timestamp,
    token: ?types.Uuid,
    settings: ?types.Json(Theme),
};

fn profiles(db: *db_mod.Db, c: *nilo.Ctx) ![]Profile {
    return db.select(Profile, c, .{
        .where = .{ .id = .{ .lte = @as(i64, 2) } },
        .order = .{ .id = .asc },
    });
}

test "a Timestamp, a Uuid and a Json column come back as themselves" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    // Every one of these used to be a compile error inside the driver, and
    // the reason nobody saw it is that no fixture had the columns. The
    // assertion is on the body rather than on the fields because it pins
    // both halves at once: what was read out of the column, and what
    // `jsonStringify` then wrote — which was equally untested.
    try stack.app.get("/profiles", profiles);
    const answer = try stack.client.get(&stack.app, "/profiles");

    try testing.expectEqual(@as(u16, 200), answer.status);
    try testing.expectEqualStrings(
        "[{\"id\":1,\"seen_at\":\"2026-08-16T09:30:00.000000Z\"," ++
            "\"token\":\"550e8400-e29b-41d4-a716-446655440000\"," ++
            "\"settings\":{\"theme\":\"dark\"}}," ++
            "{\"id\":2,\"seen_at\":\"2026-08-16T09:30:00.000000Z\"," ++
            "\"token\":null,\"settings\":null}]",
        answer.body,
    );
}

fn touchProfile(db: *db_mod.Db, c: *nilo.Ctx) ![]Profile {
    _ = try db.update(Profile, c, .{
        .set = .{
            // One day later than the fixture's default, so that a write that
            // silently did nothing would still fail this test.
            .seen_at = types.Timestamp.fromSeconds(1_786_959_000),
            .token = @as(?types.Uuid, try types.Uuid.parse("11111111-2222-3333-4444-555555555555")),
            .settings = @as(?types.Json(Theme), .{ .value = .{ .theme = "midnight" } }),
        },
        .where = .{ .id = @as(i64, 2) },
    });
    return db.select(Profile, c, .{ .where = .{ .id = @as(i64, 2) } });
}

test "the same three types go out to a column and come back unchanged" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    // The other half of the round trip. Reading them was a compile error;
    // writing them was a `CannotBindStruct` the driver would only have
    // raised at run time, which is worse.
    try stack.app.get("/touch", touchProfile);
    const answer = try stack.client.get(&stack.app, "/touch");

    try testing.expectEqual(@as(u16, 200), answer.status);
    try testing.expectEqualStrings(
        "[{\"id\":2,\"seen_at\":\"2026-08-17T09:30:00.000000Z\"," ++
            "\"token\":\"11111111-2222-3333-4444-555555555555\"," ++
            "\"settings\":{\"theme\":\"midnight\"}}]",
        answer.body,
    );
}

test "a patch keeps every column it was not given, and every .now in a transaction is one instant" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    // The body of a PATCH that carried `age` and not `email`. Each is
    // `COALESCE($n, "column")`, so Postgres has to type the parameter from
    // the column; a statement it could not type would stop here.
    const email: ?[]const u8 = null;
    const age: ?i32 = 37;
    const patched = (try stack.db.updateReturningOne(Person, &run, .{
        .set = .{ .email = where_mod.given(email), .age = where_mod.given(age) },
        .where = .{ .id = @as(i64, 1) },
    })).?;
    try testing.expectEqualStrings("ada@example.dev", patched.email);
    try testing.expectEqual(@as(i32, 37), patched.age);

    // `now()` is the start of the transaction, so two rows stamped inside one
    // carry the same instant, and both are later than the fixture's.
    var tx = try stack.db.begin(&run, .{});
    defer tx.deinit();
    _ = try tx.update(Profile, &run, .{ .set = .{ .seen_at = .now }, .where = .{ .id = @as(i64, 1) } });
    _ = try tx.update(Profile, &run, .{ .set = .{ .seen_at = .now }, .where = .{ .id = @as(i64, 2) } });
    const stamped = try tx.select(Profile, &run, .{
        .where = .{ .id = .{ .lte = @as(i64, 2) } },
        .order = .{ .id = .asc },
    });
    try tx.commit();

    try testing.expectEqual(@as(usize, 2), stamped.len);
    try testing.expectEqual(stamped[0].seen_at.micros, stamped[1].seen_at.micros);
    try testing.expect(stamped[0].seen_at.seconds() > 1_786_872_600);
}

/// `Profile` without its Json column, because a streamed row allocates
/// nothing and a document cannot be parsed without allocating — which is a
/// Refusal rather than a footnote (`db.zig`, `assertStreamable`).
const Seen = struct {
    pub const nilo_table = Profile;

    id: i64,
    seen_at: types.Timestamp,
    token: ?types.Uuid,
};

fn streamSeen(db: *db_mod.Db, c: *nilo.Ctx) ![]const u8 {
    var rows = try db.stream(Seen, c, .{ .order = .{ .id = .asc }, .limit = 1 });
    defer rows.close();

    var out: std.ArrayList(u8) = .empty;
    while (try rows.next()) |s| {
        // Both types are assembled from bytes that were being read anyway,
        // so a borrowed row still costs no allocation — which is the whole
        // of what `stream` sells.
        var buf: [80]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        try s.seen_at.writeRfc3339(&w);
        try w.writeByte(':');
        try s.token.?.writeText(&w);
        try out.print(c.arena(), "{d}:{s};", .{ s.id, w.buffered() });
    }
    return out.toOwnedSlice(c.arena());
}

test "a borrowed row builds a Timestamp and a Uuid without allocating" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    try stack.app.get("/seen", streamSeen);
    const answer = try stack.client.get(&stack.app, "/seen");

    try testing.expectEqual(@as(u16, 200), answer.status);
    try testing.expectEqualStrings(
        "1:2026-08-16T09:30:00.000000Z:550e8400-e29b-41d4-a716-446655440000;",
        answer.body,
    );
}

fn firstFew(db: *db_mod.Db, c: *nilo.Ctx) ![]Person {
    // A page size held in a `usize`, which is the shape everybody writes and
    // which used to stop with Zig's own message pointing inside `db.zig`.
    var per_page: usize = 2;
    _ = &per_page;
    return db.select(Person, c, .{ .order = .{ .id = .asc }, .limit = per_page });
}

test "a limit held in a usize binds, rather than failing to coerce" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    try stack.app.get("/first-few", firstFew);
    const answer = try stack.client.get(&stack.app, "/first-few");

    try testing.expectEqual(@as(u16, 200), answer.status);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, answer.body, "@example.dev"));
}

// -- numeric --------------------------------------------------------------

/// `email` and `age` are here because the table requires both, which is the
/// ordinary reason a Row reads a column it is not about.
const Account = struct {
    pub const nilo_table = .{ .name = table, .key = .id };

    id: i64,
    email: []const u8,
    age: i32,
    balance: types.Decimal,
};

test "a numeric survives the round trip with every digit it went in with" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    // Twenty-nine significant digits. An f64 carries about fifteen, so if the
    // value went through one at any point in either direction this comes back
    // rounded — which is the entire reason the column type exists.
    const exact = "12345678901234567890.123456789";

    const made = try stack.db.insert(Account, &run, .{
        .id = @as(i64, 700),
        .email = "exact@example.dev",
        .age = @as(i32, 30),
        .balance = types.Decimal{ .text = exact },
    });
    try testing.expectEqualStrings(exact, made.balance.text);

    // And again on a fresh read, so the answer is Postgres's rather than an
    // echo of what was sent.
    const back = (try stack.db.find(Account, &run, @as(i64, 700))).?;
    try testing.expectEqualStrings(exact, back.balance.text);
}

test "a numeric compares as a number rather than as the text it is carried in" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    _ = try stack.db.insert(Account, &run, .{
        .id = @as(i64, 701),
        .email = "poor@example.dev",
        .age = @as(i32, 30),
        .balance = types.Decimal{ .text = "9.99" },
    });
    _ = try stack.db.insert(Account, &run, .{
        .id = @as(i64, 702),
        .email = "rich@example.dev",
        .age = @as(i32, 30),
        .balance = types.Decimal{ .text = "100.00" },
    });

    // `"100.00" > "9.99"` is false as text and true as a number. The `::numeric`
    // the Dialect puts on the placeholder is what decides which one this is.
    const rich = try stack.db.select(Account, &run, .{
        .where = .{ .balance = .{ .gt = types.Decimal{ .text = "50" } } },
        .order = .{ .id = .asc },
    });
    try testing.expectEqual(@as(usize, 1), rich.len);
    try testing.expectEqual(@as(i64, 702), rich[0].id);
}

fn richAccounts(db: *db_mod.Db, c: *nilo.Ctx) ![]Account {
    return db.select(Account, c, .{
        .where = .{ .balance = .{ .gt = types.Decimal{ .text = "50" } } },
        .order = .{ .id = .asc },
    });
}

test "a numeric leaves as a JSON string, so a consumer gets the digits" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();
    _ = try stack.db.insert(Account, &run, .{
        .id = @as(i64, 703),
        .email = "json@example.dev",
        .age = @as(i32, 30),
        .balance = types.Decimal{ .text = "1234.56" },
    });

    try stack.app.get("/rich", richAccounts);
    const answer = try stack.client.get(&stack.app, "/rich");

    try testing.expectEqual(@as(u16, 200), answer.status);
    // Quoted. A bare `1234.56` would be exact here and lose its last digits
    // in whichever consumer calls `JSON.parse`.
    try testing.expectEqualStrings(
        "[{\"id\":703,\"email\":\"json@example.dev\",\"age\":30,\"balance\":\"1234.56\"}]",
        answer.body,
    );
}

test "a streamed numeric borrows its digits, and the type says so" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();
    _ = try stack.db.insert(Account, &run, .{
        .id = @as(i64, 704),
        .email = "stream@example.dev",
        .age = @as(i32, 30),
        .balance = types.Decimal{ .text = "42.42" },
    });

    var rows = try stack.db.stream(Account, &run, .{ .where = .{ .id = @as(i64, 704) } });
    defer rows.close();

    const first = (try rows.next()).?;
    // `[]const u8` rather than a `Decimal`, because the digits point into the
    // read buffer and die at the next row — a Borrowed row makes that part of
    // the type instead of a comment. `stream` therefore still allocates
    // nothing, which `Json(T)` could not manage.
    try testing.expectEqual([]const u8, @TypeOf(first.balance));
    try testing.expectEqualStrings("42.42", first.balance);
}

// -- a date ---------------------------------------------------------------

/// `email` and `age` are here for the reason they are on `Account`: the table
/// requires both.
const Birthday = struct {
    pub const nilo_table = .{ .name = table, .key = .id };

    id: i64,
    email: []const u8,
    age: i32,
    born: ?types.Date,
};

test "a date the database wrote comes back as the day, out of the column's own bytes" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    // Nothing in this test wrote these three, which is the point of reading
    // them: the bytes came off the wire as Postgres stores a `date`, four of
    // them counting from 2000-01-01, and the shift back to 1970 is nilo's.
    const ada = (try stack.db.find(Birthday, &run, @as(i64, 1))).?;
    try testing.expectEqual(@as(i32, -56_270), ada.born.?.days);

    // A day before the epoch, which is where a `u32` or a `std.time.epoch`
    // walk would have gone wrong rather than failed.
    var buf: [16]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try ada.born.?.writeIso(&w);
    try testing.expectEqualStrings("1815-12-10", w.buffered());

    const grace = (try stack.db.find(Birthday, &run, @as(i64, 2))).?;
    try testing.expectEqual(@as(?types.Date, null), grace.born);

    const kid = (try stack.db.find(Birthday, &run, @as(i64, 3))).?;
    try testing.expectEqual(@as(i32, 16_495), kid.born.?.days);
}

const Endless = struct {
    pub const nilo_table = .projection;

    at: ?types.Timestamp,
    day: ?types.Date,
};

test "an infinite date or timestamp another client wrote is refused by name, not a panic or a moment" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    // `'infinity'::timestamptz` overflowed inside pg.zig's decoder and took
    // the process down; `'-infinity'` read back as a moment 292,000 years
    // ago. A `date` overflowed nilo's own shift the same way.
    inline for (.{
        "SELECT 'infinity'::timestamptz AS at, NULL::date AS day",
        "SELECT '-infinity'::timestamptz AS at, NULL::date AS day",
        "SELECT NULL::timestamptz AS at, 'infinity'::date AS day",
        "SELECT NULL::timestamptz AS at, '-infinity'::date AS day",
    }) |statement| {
        try testing.expectError(error.QueryFailed, stack.db.raw(Endless, &run, statement, .{}));
    }

    // The moments either side of them still read, and a null is still a null.
    const ends = try stack.db.raw(
        Endless,
        &run,
        "SELECT '1969-12-31 23:59:59.999999+00'::timestamptz AS at, '4000-01-01'::date AS day",
        .{},
    );
    try testing.expectEqual(@as(i64, -1), ends[0].at.?.micros);
    try testing.expectEqual(types.Date.nilo_parse("4000-01-01").?.days, ends[0].day.?.days);
    const nothing = try stack.db.raw(Endless, &run, "SELECT NULL::timestamptz AS at, NULL::date AS day", .{});
    try testing.expectEqual(@as(?types.Timestamp, null), nothing[0].at);
}

const Counted = struct {
    pub const nilo_table = .projection;

    at_ms: types.UnixMillis,
    at_s: ?types.UnixSeconds,
};

test "a UnixMillis and a UnixSeconds read an integer column as the count it holds, and write it back" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    const rows = try stack.db.raw(
        Counted,
        &run,
        "SELECT 1790846995323::int8 AS at_ms, NULL::int8 AS at_s",
        .{},
    );
    try testing.expectEqual(@as(i64, 1_790_846_995_323), rows[0].at_ms.count);
    try testing.expectEqual(@as(?types.UnixSeconds, null), rows[0].at_s);
    try testing.expectEqual(@as(i64, 1_790_846_995_323_000), rows[0].at_ms.toTimestamp().micros);
}

const Dated = struct {
    pub const nilo_table = .projection;

    day: types.Date,
};

test "a column that is not four bytes wide, read into a Date nothing checked first, is refused rather than cut to four" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    // `tx.raw` is not held against its Row on its first run (ADR 233), so
    // the width is what stands between a timestamp's eight bytes and a day
    // made of the first four of them.
    var tx = try stack.db.begin(&run, .{});
    defer tx.deinit();
    try testing.expectError(error.QueryFailed, tx.raw(Dated, &run, "SELECT now() AS day", .{}));
    try testing.expectError(error.QueryFailed, tx.raw(Dated, &run, "SELECT 1::int8 AS day", .{}));
}

test "a date goes out as ten characters and comes back as the same day" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    // The asymmetry, written down: pg.zig has no `date` codec to bind, so the
    // value leaves as text with the `::date` the Dialect puts on the
    // placeholder, and arrives back as the four bytes. A write that silently
    // landed a day out would pass an echo test and fail this one, because the
    // read is Postgres's own answer.
    const made = try stack.db.insert(Birthday, &run, .{
        .id = @as(i64, 710),
        .email = "born@example.dev",
        .age = @as(i32, 61),
        .born = @as(?types.Date, types.Date.nilo_parse("1965-08-09").?),
    });
    try testing.expectEqual(@as(i32, -1606), made.born.?.days);

    const back = (try stack.db.find(Birthday, &run, @as(i64, 710))).?;
    try testing.expectEqual(@as(i32, -1606), back.born.?.days);

    // And null both ways, which is a different branch in both Wires.
    _ = try stack.db.update(Birthday, &run, .{
        .set = .{ .born = @as(?types.Date, null) },
        .where = .{ .id = @as(i64, 710) },
    });
    try testing.expectEqual(
        @as(?types.Date, null),
        (try stack.db.find(Birthday, &run, @as(i64, 710))).?.born,
    );
}

test "a date compares as a day rather than as the text it is carried in" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    // The `::date` on the placeholder is what decides this. Without it the
    // parameter arrives as an unknown type beside a `date` column, and what
    // Postgres does with that is its business rather than something nilo
    // should be finding out per statement.
    const old = try stack.db.select(Birthday, &run, .{
        .where = .{ .born = .{ .lt = types.Date.nilo_parse("1900-01-01").? } },
        .order = .{ .id = .asc },
    });
    try testing.expectEqual(@as(usize, 1), old.len);
    try testing.expectEqual(@as(i64, 1), old[0].id);
}

fn bornDays(db: *db_mod.Db, c: *nilo.Ctx) ![]Birthday {
    return db.select(Birthday, c, .{
        .where = .{ .id = .{ .lte = @as(i64, 2) } },
        .order = .{ .id = .asc },
    });
}

test "a date leaves as the ten characters, and a null leaves as null" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    // Both halves at once, the way the three types above are asserted: what
    // came out of the column, and what `jsonStringify` then wrote.
    try stack.app.get("/born", bornDays);
    const answer = try stack.client.get(&stack.app, "/born");

    try testing.expectEqual(@as(u16, 200), answer.status);
    try testing.expectEqualStrings(
        "[{\"id\":1,\"email\":\"ada@example.dev\",\"age\":36,\"born\":\"1815-12-10\"}," ++
            "{\"id\":2,\"email\":\"grace@example.dev\",\"age\":45,\"born\":null}]",
        answer.body,
    );
}

// -- upserts --------------------------------------------------------------

test "an upsert that ignores leaves the row that was already there alone" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    // Ada is row 1, and `email` is the unique column rather than the key —
    // so this conflicts on something `db.find` could not have used.
    const clash = try stack.db.insertOrIgnore(Person, &run, .{
        .id = @as(i64, 99),
        .email = "ada@example.dev",
        .age = @as(i32, 1),
    }, .email);
    try testing.expectEqual(@as(?Person, null), clash);

    // Nothing was written: not the age, and not a second row.
    const ada = (try stack.db.find(Person, &run, @as(i64, 1))).?;
    try testing.expectEqual(@as(i32, 36), ada.age);
    try testing.expectEqual(@as(usize, 3), try stack.db.count(Person, &run, .{}));

    // And a genuinely new row still goes in and comes back.
    const made = try stack.db.insertOrIgnore(Person, &run, .{
        .id = @as(i64, 4),
        .email = "new@example.dev",
        .age = @as(i32, 20),
    }, .email);
    try testing.expectEqual(@as(i64, 4), made.?.id);
}

test "an upsert that updates writes over the row that was there, and answers with it" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    const back = try stack.db.insertOrUpdate(Person, &run, .{
        .id = @as(i64, 99),
        .email = "ada@example.dev",
        .age = @as(i32, 37),
    }, .email);

    // The row that was already there, with the proposed values written over
    // it — so the key is Ada's own `1` and not the `99` that was offered.
    try testing.expectEqual(@as(i64, 1), back.id);
    try testing.expectEqual(@as(i32, 37), back.age);
    try testing.expectEqual(@as(usize, 3), try stack.db.count(Person, &run, .{}));
}

test "an upsert is one statement, so two of them cannot both insert" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    // The shape this replaces — catch `AlreadyExists`, then update — is two
    // round trips with a window between them. Run the same upsert twice and
    // the table gains exactly one row, which is the property that window
    // cost.
    const before = try stack.db.count(Person, &run, .{});
    var round: usize = 0;
    while (round < 3) : (round += 1) {
        const back = try stack.db.insertOrUpdate(Person, &run, .{
            .id = @as(i64, 50 + @as(i64, @intCast(round))),
            .email = "repeat@example.dev",
            .age = @as(i32, @intCast(round)),
        }, .email);
        try testing.expectEqual(@as(i32, @intCast(round)), back.age);
    }
    try testing.expectEqual(before + 1, try stack.db.count(Person, &run, .{}));
}

test "a statement that fails inside a transaction still leaves a rollback that works" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    const dirty_before = try postgres.dirtyConnections();

    {
        var tx = try stack.db.begin(&run, .{});
        defer tx.deinit();
        // `id` is the primary key and row 1 is already there.
        try testing.expectError(error.AlreadyExists, tx.insert(Person, &run, .{
            .id = @as(i64, 1),
            .email = "clash@example.dev",
            .age = @as(i32, 30),
        }));
    }

    // The assertion the behaviour below cannot make. Postgres answers a
    // failed statement in a transaction with ReadyForQuery `E`, pg.zig calls
    // that `.fail`, and `canQuery` then refused the `ROLLBACK` — so the
    // connection was destroyed and re-dialled on every failed statement
    // inside a transaction. Nothing downstream could tell, which is why this
    // reads the counter instead of the rows.
    try testing.expectEqual(dirty_before, try postgres.dirtyConnections());

    // The pool holds two, so five rounds reuse whatever came back.
    var round: usize = 0;
    while (round < 5) : (round += 1) {
        var tx = try stack.db.begin(&run, .{});
        defer tx.deinit();
        const found = try tx.select(Person, &run, .{ .where = .{ .id = @as(i64, 1) } });
        try testing.expectEqual(@as(usize, 1), found.len);
        try tx.commit();
    }
}

// -- a statement with a deadline of its own -------------------------------

/// One column of nothing, for a statement whose answer is not the point.
const Slept = struct {
    pub const nilo_table = .{ .name = "unused", .key = .ok };
    ok: bool,
};

test "a statement past its deadline is cancelled by the database" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    var tx = try stack.db.begin(&run, .{});
    defer tx.deinit();

    try tx.deadline(100);

    // Ten seconds against a hundred milliseconds, so a slow machine cannot
    // turn this into a flake in either direction.
    const started = nilo.monotonicNanos();
    const answer = tx.raw(Slept, &run, "SELECT pg_sleep(10) IS NULL", .{});
    const waited_ms = @divFloor(nilo.monotonicNanos() - started, std.time.ns_per_ms);

    // `57014` rather than a generic failure, which is the whole reason
    // `TimedOut` exists: the handler that set the number is the one that can
    // decide what to do about it.
    try testing.expectError(error.TimedOut, answer);
    try testing.expect(waited_ms < 5_000);
}

test "a deadline of 0 times the next statement out, and one past maxInt(i32) keeps the transaction" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    {
        // `statement_timeout = 0` is Postgres for no limit, which would let
        // this sleep the whole second.
        var tx = try stack.db.begin(&run, .{});
        defer tx.deinit();
        try tx.deadline(0);
        try testing.expectError(error.TimedOut, tx.raw(Slept, &run, "SELECT pg_sleep(1) IS NULL", .{}));
    }
    {
        // Sent as it came, Postgres answers `22023` and the transaction is
        // aborted before its first statement.
        var tx = try stack.db.begin(&run, .{});
        defer tx.deinit();
        try tx.deadline(std.math.maxInt(u32));
        const slept = try tx.raw(Slept, &run, "SELECT pg_sleep(0.01) IS NULL", .{});
        try testing.expectEqual(@as(usize, 1), slept.len);
        try tx.commit();
    }
}

/// What a task cancelled in the middle of a statement finds once the
/// statement has answered: its cancellation still pending, or gone.
const AfterCancel = enum { still_cancelled, lost, finished };

fn slowThenAsk(db: *db_mod.Db, io: std.Io, gpa: std.mem.Allocator) AfterCancel {
    var run = nilo.Run.init(gpa);
    defer run.deinit();
    _ = db.raw(Slept, &run, "SELECT pg_sleep(10) IS NULL", .{}) catch {
        std.Io.checkCancel(io) catch return .still_cancelled;
        return .lost;
    };
    return .finished;
}

test "a statement cut off by a cancellation leaves the cancellation to its caller" {
    // A background loop gets out on `nilo.sleep(..) catch return`. When the
    // shutdown's one cancellation lands in a statement instead, the statement
    // reports `QueryFailed` — and unless the cancellation is re-armed the
    // loop logs that, sleeps on, and the process never exits (ADR 223).
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    const io = stack.live.threaded.io();
    var task = io.concurrent(slowThenAsk, .{ &stack.db, io, gpa }) catch return error.SkipZigTest;
    // Long enough to be waiting on the socket, far short of the ten seconds.
    try std.Io.sleep(io, .fromMilliseconds(300), .awake);
    try testing.expectEqual(AfterCancel.still_cancelled, task.cancel(io));
}

fn slowInTxThenAsk(db: *db_mod.Db, io: std.Io, gpa: std.mem.Allocator) AfterCancel {
    var run = nilo.Run.init(gpa);
    defer run.deinit();
    var tx = db.begin(&run, .{}) catch return .lost;
    _ = tx.raw(Slept, &run, "SELECT pg_sleep(10) IS NULL", .{}) catch {
        // The rollback a failing handler's `defer` runs. It meets the
        // re-armed cancellation straight away unless it is held off, and
        // then logs a failed rollback, which fails this test.
        tx.rollback();
        std.Io.checkCancel(io) catch return .still_cancelled;
        return .lost;
    };
    tx.rollback();
    return .finished;
}

test "a transaction cut off by a cancellation rolls back without calling it a failure" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    const io = stack.live.threaded.io();
    var task = io.concurrent(slowInTxThenAsk, .{ &stack.db, io, gpa }) catch return error.SkipZigTest;
    try std.Io.sleep(io, .fromMilliseconds(300), .awake);
    try testing.expectEqual(AfterCancel.still_cancelled, task.cancel(io));
}

/// Sleeps while the statement calling it is planned rather than run: an
/// immutable function with no arguments is folded into a constant by the
/// planner, so the EXPLAIN a first raw run sends to check its Row is the
/// step that waits.
const plan_sleep_fn = "nilo_test_plan_sleep";

fn slowToPlanThenAsk(db: *db_mod.Db, io: std.Io, gpa: std.mem.Allocator) AfterCancel {
    var run = nilo.Run.init(gpa);
    defer run.deinit();
    _ = db.raw(Slept, &run, "SELECT " ++ plan_sleep_fn ++ "() AS ok", .{}) catch {
        std.Io.checkCancel(io) catch return .still_cancelled;
        return .lost;
    };
    return .finished;
}

test "a cancellation that lands in a raw statement's first-run check reaches its caller" {
    // The check's EXPLAIN runs inside a transaction it rolls back, and the
    // ROLLBACK in its cleanup took the cancellation `translate` had re-armed
    // and dropped it. `db.raw` then ran the statement anyway, so a job cut
    // off there by a shutdown finished and was marked done (ADR 223).
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();
    _ = try stack.db.exec(&run, "CREATE OR REPLACE FUNCTION " ++ plan_sleep_fn ++ "() RETURNS boolean " ++
        "IMMUTABLE LANGUAGE plpgsql AS $$ BEGIN PERFORM pg_sleep(5); RETURN true; END $$", .{});
    defer _ = stack.db.exec(&run, "DROP FUNCTION IF EXISTS " ++ plan_sleep_fn ++ "()", .{}) catch {};

    const io = stack.live.threaded.io();
    var task = io.concurrent(slowToPlanThenAsk, .{ &stack.db, io, gpa }) catch return error.SkipZigTest;
    // Inside the five seconds the EXPLAIN plans for.
    try std.Io.sleep(io, .fromMilliseconds(500), .awake);
    const started = nilo.monotonicNanos();
    try testing.expectEqual(AfterCancel.still_cancelled, task.cancel(io));
    // Not run anyway: a statement that went on would plan for five more.
    try testing.expect(nilo.monotonicNanos() - started < 3 * std.time.ns_per_s);
}

test "a deadline ends with its transaction, so the next one starts clean" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    {
        var tx = try stack.db.begin(&run, .{});
        defer tx.deinit();
        try tx.deadline(100);
        try testing.expectError(
            error.TimedOut,
            tx.raw(Slept, &run, "SELECT pg_sleep(10) IS NULL", .{}),
        );
    }

    // `SET LOCAL` is undone by the end of the transaction whichever way it
    // ended — here a rollback, from the `defer` above. The pool is two
    // connections, so this asks for more than that many in a row: a
    // connection that went back still carrying a 100ms timeout would fail
    // this on whichever round reused it.
    var round: usize = 0;
    while (round < 5) : (round += 1) {
        var tx = try stack.db.begin(&run, .{});
        defer tx.deinit();
        const slept = try tx.raw(Slept, &run, "SELECT pg_sleep(0.3) IS NULL", .{});
        try testing.expectEqual(@as(usize, 1), slept.len);
        try tx.commit();
    }
}

// -- relations that are not tables ----------------------------------------

/// A Row over a view, and **every field is non-optional on purpose.** That is
/// the whole of what used to be wrong: Postgres reports a view's columns as
/// nullable whatever their source columns were, so this Row was five
/// disagreements and a server that would not start.
const Adult = struct {
    pub const nilo_table = .{ .name = adults_view, .key = .id };

    id: i64,
    email: []const u8,
    age: i32,
};

/// A Row over a materialized view, which `information_schema.columns` cannot
/// see at all — the old query answered nothing and the check called it a
/// table that does not exist.
const RoleTotal = struct {
    pub const nilo_table = .{ .name = totals_view, .key = .role };

    role: []const u8,
    people: i64,
};

test "a view is a relation a Row can read and a check can judge" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    const grown = try stack.db.select(Adult, &run, .{ .order = .{ .id = .asc } });
    try testing.expectEqual(@as(usize, 2), grown.len);
    try testing.expectEqualStrings("ada@example.dev", grown[0].email);
    try testing.expect(grown[0].age >= 18);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var problems: std.ArrayList(schema.Problem) = .empty;

    const columns = try stack.live.wire.columnsOf(
        arena.allocator(),
        dialect.Postgres.introspect,
        null,
        adults_view,
    );
    try testing.expect(columns.len == 3);
    // Nothing, and not three `unexpected_null`s: the database does not know
    // whether a view column can be null, and a check that does not know says
    // nothing rather than guessing (ADR 050).
    try testing.expectEqual(@as(usize, 0), try schema.compare(
        dialect.Postgres,
        Adult,
        columns,
        &problems,
        arena.allocator(),
    ));
    for (columns) |column| try testing.expectEqual(@as(?bool, null), column.nullable);

    // The type is still checked, which is the half a view does know.
    const Wrong = struct {
        pub const nilo_table = .{ .name = adults_view, .key = .id };
        id: i64,
        email: i64,
    };
    try testing.expect(try schema.compare(
        dialect.Postgres,
        Wrong,
        columns,
        &problems,
        arena.allocator(),
    ) > 0);
}

test "a materialized view is a relation the introspection can see" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    const totals = try stack.db.select(RoleTotal, &run, .{ .order = .{ .role = .asc } });
    try testing.expectEqual(@as(usize, 3), totals.len);
    try testing.expectEqualStrings("admin", totals[0].role);
    try testing.expectEqual(@as(i64, 1), totals[0].people);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var problems: std.ArrayList(schema.Problem) = .empty;

    const columns = try stack.live.wire.columnsOf(
        arena.allocator(),
        dialect.Postgres.introspect,
        null,
        totals_view,
    );
    // Two rather than none, which is what `information_schema.columns`
    // answered and what made this read as a missing table.
    try testing.expectEqual(@as(usize, 2), columns.len);
    try testing.expectEqual(@as(usize, 0), try schema.compare(
        dialect.Postgres,
        RoleTotal,
        columns,
        &problems,
        arena.allocator(),
    ));
}

/// A Row over a table where two of the three columns are the database's to
/// fill: `id` is `GENERATED ALWAYS AS IDENTITY` and `slug` is a generated
/// column. Neither may be written, and neither has to be — an insert names a
/// **subset** of the Row's columns, which is the design this is the payoff
/// for.
const Auto = struct {
    pub const nilo_table = .{ .name = auto_table, .key = .id };

    id: i64,
    label: []const u8,
    slug: ?[]const u8,
};

test "an identity key and a generated column are filled by the database" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    // One column written, three read back. `RETURNING` is not optional here
    // and this is why: without it a caller would have to go and ask what key
    // the database chose.
    const first = try stack.db.insert(Auto, &run, .{ .label = "alpha" });
    try testing.expect(first.id > 0);
    try testing.expectEqualStrings("alpha", first.label);
    try testing.expectEqualStrings("alpha-x", first.slug.?);

    const second = try stack.db.insert(Auto, &run, .{ .label = "beta" });
    try testing.expect(second.id > first.id);

    // And a batch, where the arrays hold only the column that was written.
    const Made = struct { label: []const u8 };
    const many = try stack.db.insertMany(Auto, &run, &[_]Made{
        .{ .label = "gamma" },
        .{ .label = "delta" },
    });
    try testing.expectEqual(@as(usize, 2), many.len);
    try testing.expectEqualStrings("gamma-x", many[0].slug.?);
    try testing.expect(many[1].id > many[0].id);

    // A generated column is nullable as far as Postgres is concerned — it
    // carries no `NOT NULL` unless one was written — so the Row reads it as
    // an optional and the check agrees.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var problems: std.ArrayList(schema.Problem) = .empty;
    const columns = try stack.live.wire.columnsOf(
        arena.allocator(),
        dialect.Postgres.introspect,
        null,
        auto_table,
    );
    try testing.expectEqual(@as(usize, 0), try schema.compare(
        dialect.Postgres,
        Auto,
        columns,
        &problems,
        arena.allocator(),
    ));
}

// -- a column type this module did not choose -----------------------------

/// The two the checklist named, read through the protocol rather than through
/// a branch of their own.
const Booking = struct {
    pub const nilo_table = .{ .name = table, .key = .id };

    id: i64,
    email: []const u8,
    age: i32,
    stay: ?types.Interval,
    origin: ?types.Inet,
};

test "an interval and an inet round-trip as the text postgres prints" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    const read = (try stack.db.find(Booking, &run, @as(i64, 1))).?;
    try testing.expectEqualStrings("3 days 04:05:06", read.stay.?.text);
    // With the mask, because `inet::text` always prints one — `inet_out` and
    // `host()` do not, and the text a text column carries is the cast's.
    try testing.expectEqualStrings("192.168.0.1/32", read.origin.?.text);

    // A null in either is a null, the way it is for every other column.
    const empty = (try stack.db.find(Booking, &run, @as(i64, 2))).?;
    try testing.expectEqual(@as(?types.Interval, null), empty.stay);
    try testing.expectEqual(@as(?types.Inet, null), empty.origin);

    // And the write half, which is the one that cannot work without the cast:
    // pg.zig has no encoder for either type, so what makes this land is
    // `$4::interval` rather than anything the driver knows.
    const made = try stack.db.insert(Booking, &run, .{
        .id = @as(i64, 720),
        .email = "span@example.dev",
        .age = @as(i32, 30),
        .stay = @as(?types.Interval, .{ .text = "2 days 01:00:00" }),
        .origin = @as(?types.Inet, .{ .text = "172.16.0.9/32" }),
    });
    defer _ = stack.db.delete(Booking, &run, .{ .where = .{ .id = @as(i64, 720) } }) catch {};

    try testing.expectEqualStrings("2 days 01:00:00", made.stay.?.text);
    try testing.expectEqualStrings("172.16.0.9/32", made.origin.?.text);

    // A value that is not optional, set into the column that is: the ordinary
    // act of filling in a date that was empty. It used to stop as a type
    // error inside `forWire`, and `@as(?Interval, …)` at every site was the
    // workaround (ADR 164).
    const filled = try stack.db.updateReturning(Booking, &run, .{
        .set = .{ .stay = types.Interval{ .text = "5 days" } },
        .where = .{ .id = @as(i64, 720) },
    });
    try testing.expectEqual(@as(usize, 1), filled.len);
    try testing.expectEqualStrings("5 days", filled[0].stay.?.text);
}

test "an interval column is judged at startup like any other" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const columns = try stack.live.wire.columnsOf(
        arena.allocator(),
        dialect.Postgres.introspect,
        null,
        table,
    );
    var problems: std.ArrayList(schema.Problem) = .empty;

    // The schema half was already open — this is the check that the name a
    // text column declares is the name the comparison uses, so a Row reading
    // `stay` as an `Inet` would be caught before the first request.
    try testing.expectEqual(@as(usize, 0), try schema.compare(
        dialect.Postgres,
        Booking,
        columns,
        &problems,
        arena.allocator(),
    ));

    const Wrong = struct {
        pub const nilo_table = .{ .name = table, .key = .id };
        id: i64,
        stay: ?types.Inet,
    };
    try testing.expect(try schema.compare(
        dialect.Postgres,
        Wrong,
        columns,
        &problems,
        arena.allocator(),
    ) > 0);
}

/// A column type a **project** declared, holding structure rather than text.
///
/// This is the case `AsText` cannot stand in for and the reason `nilo_read`
/// and `nilo_write` take an allocator: the value is an integer, the column is
/// a `numeric`, and going either way means building bytes that were not there
/// before.
const Cents = struct {
    value: i64,

    pub const nilo_column = "numeric";

    pub fn nilo_read(raw: []const u8, arena: std.mem.Allocator) !Cents {
        _ = arena;
        const dot = std.mem.indexOfScalar(u8, raw, '.') orelse
            return .{ .value = try std.fmt.parseInt(i64, raw, 10) * 100 };
        const whole = try std.fmt.parseInt(i64, raw[0..dot], 10);
        // Two digits, padded, so `1.5` is 150 rather than 15.
        var fraction: i64 = 0;
        for (0..2) |i| {
            const digit: i64 = if (dot + 1 + i < raw.len) raw[dot + 1 + i] - '0' else 0;
            fraction = fraction * 10 + digit;
        }
        return .{ .value = whole * 100 + fraction };
    }

    pub fn nilo_write(self: Cents, arena: std.mem.Allocator) ![]const u8 {
        // `@abs` because the remainder of a negative carries the sign, and a
        // padded `-4` is not two digits of a `numeric`.
        return std.fmt.allocPrint(arena, "{d}.{d:0>2}", .{
            @divTrunc(self.value, 100),
            @abs(@rem(self.value, 100)),
        });
    }
};

const Purse = struct {
    pub const nilo_table = .{ .name = table, .key = .id };

    id: i64,
    email: []const u8,
    age: i32,
    balance: Cents,
};

test "a column type a project wrote reads and writes through the same seam" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    const made = try stack.db.insert(Purse, &run, .{
        .id = @as(i64, 721),
        .email = "cents@example.dev",
        .age = @as(i32, 30),
        .balance = Cents{ .value = 1234 },
    });
    defer _ = stack.db.delete(Purse, &run, .{ .where = .{ .id = @as(i64, 721) } }) catch {};

    // `12.34` went down the wire, and an integer came back — neither of which
    // this module knows anything about. `nilo_write` allocated the digits in
    // the request arena, which is the whole reason it is handed one.
    try testing.expectEqual(@as(i64, 1234), made.balance.value);

    const back = (try stack.db.find(Purse, &run, @as(i64, 721))).?;
    try testing.expectEqual(@as(i64, 1234), back.balance.value);

    // And it is a condition like any other, cast the same way.
    const found = try stack.db.select(Purse, &run, .{
        .where = .{ .id = @as(i64, 721), .balance = .{ .gt = Cents{ .value = 1000 } } },
    });
    try testing.expectEqual(@as(usize, 1), found.len);
}

// -- what a transaction is begun with, and what a read holds --------------

/// The ids these tests own. High enough not to collide with the fixture and
/// with the rows the tests above insert, and every one of them is deleted by
/// the test that made it — the fixture is shared by everything in this file.
const scratch_id: i64 = 900;

/// One text column, for a `SHOW` — a statement whose answer is a setting
/// rather than a row of anything.
const Setting = struct {
    pub const nilo_table = .{ .name = "unused", .key = .value };
    value: []const u8,
};

test "a transaction begun read-only is read-only at the server" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    var tx = try stack.db.begin(&run, .{ .read_only = true });
    defer tx.deinit();

    // Asked of Postgres rather than proved by a refused insert, and the
    // reason is the test runner rather than the design: a write here answers
    // `25006`, `translate` logs the server's message at `err` on the way to
    // `QueryFailed`, and a test that logs an error is a failed test. What
    // nilo owes is that the words reached the `BEGIN`; that Postgres then
    // refuses writes is Postgres's, documented, and not this suite's to
    // re-prove.
    const shown = try tx.raw(Setting, &run, "SHOW transaction_read_only", .{});
    try testing.expectEqual(@as(usize, 1), shown.len);
    try testing.expectEqualStrings("on", shown[0].value);

    // Reading is the whole of what it may do, and it does it.
    const found = try tx.select(Person, &run, .{ .where = .{ .id = @as(i64, 1) } });
    try testing.expectEqual(@as(usize, 1), found.len);
}

test "a transaction begun with an isolation level says so at the server" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    var tx = try stack.db.begin(&run, .{ .isolation = .serializable });
    defer tx.deinit();

    const shown = try tx.raw(Setting, &run, "SHOW transaction_isolation", .{});
    try testing.expectEqualStrings("serializable", shown[0].value);
}

test "a repeatable-read transaction keeps seeing the row it first read" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    const id = scratch_id + 2;
    _ = try stack.db.insert(Person, &run, .{
        .id = id,
        .email = "snapshot@example.dev",
        .age = @as(i32, 30),
    });
    defer _ = stack.db.delete(Person, &run, .{ .where = .{ .id = id } }) catch {};

    {
        var tx = try stack.db.begin(&run, .{ .isolation = .repeatable_read });
        defer tx.deinit();

        // The snapshot is taken by the first statement rather than by the
        // `BEGIN`, so this read is what fixes what the transaction can see.
        const first = try tx.one(Person, &run, .{ .where = .{ .id = id } });
        try testing.expectEqual(@as(i32, 30), first.?.age);

        // Somebody else, on the pool's other connection, and committed.
        const changed = try stack.db.update(Person, &run, .{
            .set = .{ .age = @as(i32, 31) },
            .where = .{ .id = id },
        });
        try testing.expectEqual(@as(usize, 1), changed);

        // Read committed would answer 31 here. This is the difference the
        // option buys, and the reason it is worth a word on the `BEGIN`.
        const again = try tx.one(Person, &run, .{ .where = .{ .id = id } });
        try testing.expectEqual(@as(i32, 30), again.?.age);
        try tx.commit();
    }

    // And outside it, the change was always there.
    const now = try stack.db.one(Person, &run, .{ .where = .{ .id = id } });
    try testing.expectEqual(@as(i32, 31), now.?.age);
}

test "a row another transaction holds is refused rather than waited for" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    var holder = try stack.db.begin(&run, .{});
    defer holder.deinit();
    const held = try holder.select(Person, &run, .{
        .where = .{ .id = @as(i64, 1) },
        .lock = .update,
    });
    try testing.expectEqual(@as(usize, 1), held.len);

    var other = try stack.db.begin(&run, .{});
    defer other.deinit();

    // `.update` here would block until the first transaction ended, which on
    // one thread is a test that never finishes. `.update_nowait` is what a
    // handler asks when it would rather answer than queue, and `Locked` is
    // the answer it asked for — a plain `QueryFailed` would leave it unable
    // to tell this from a broken statement.
    try testing.expectError(error.Locked, other.select(Person, &run, .{
        .where = .{ .id = @as(i64, 1) },
        .lock = .update_nowait,
    }));
}

test "a locked row is left out of a skipping read rather than blocking it" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    var holder = try stack.db.begin(&run, .{});
    defer holder.deinit();
    _ = try holder.select(Person, &run, .{ .where = .{ .id = @as(i64, 1) }, .lock = .update });

    var worker = try stack.db.begin(&run, .{});
    defer worker.deinit();
    const taken = try worker.select(Person, &run, .{
        .where = .{ .age = .{ .gt = @as(i32, 0) } },
        .order = .{ .id = .asc },
        .lock = .update_skip_locked,
    });

    // Whatever else is in the table by now, row 1 is being held and is
    // therefore not in this answer — which is the whole of what a work queue
    // needs: two workers running the same statement never get the same row.
    try testing.expect(taken.len > 0);
    for (taken) |person| try testing.expect(person.id != 1);
}

test "a savepoint undoes one failed statement and leaves the transaction alive" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    const first = scratch_id + 3;
    const second = scratch_id + 4;
    defer _ = stack.db.delete(Person, &run, .{ .where = .{ .id = first } }) catch {};
    defer _ = stack.db.delete(Person, &run, .{ .where = .{ .id = second } }) catch {};

    {
        var tx = try stack.db.begin(&run, .{});
        defer tx.deinit();

        _ = try tx.insert(Person, &run, .{
            .id = first,
            .email = "before@example.dev",
            .age = @as(i32, 20),
        });

        var sp = try tx.savepoint();
        defer sp.deinit();

        // Row 1 is in the fixture and `id` is the primary key. Without the
        // mark above, this is the end of the transaction: Postgres aborts it
        // and every statement after this one answers `25P02` until somebody
        // rolls the whole thing back.
        try testing.expectError(error.AlreadyExists, tx.insert(Person, &run, .{
            .id = @as(i64, 1),
            .email = "clash@example.dev",
            .age = @as(i32, 30),
        }));
        sp.rollback();

        // The proof: a statement after the failure, in the same transaction.
        _ = try tx.insert(Person, &run, .{
            .id = second,
            .email = "after@example.dev",
            .age = @as(i32, 21),
        });
        try tx.commit();
    }

    // Both sides of the savepoint survived, because neither was what was
    // undone — what the mark took back was one failed statement.
    try testing.expect(try stack.db.exists(Person, &run, .{ .where = .{ .id = first } }));
    try testing.expect(try stack.db.exists(Person, &run, .{ .where = .{ .id = second } }));
}

test "a savepoint rolled back takes its work with it, and released keeps it" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    const undone = scratch_id + 5;
    const kept = scratch_id + 6;
    defer _ = stack.db.delete(Person, &run, .{ .where = .{ .id = kept } }) catch {};

    {
        var tx = try stack.db.begin(&run, .{});
        defer tx.deinit();

        var thrown = try tx.savepoint();
        _ = try tx.insert(Person, &run, .{
            .id = undone,
            .email = "undone@example.dev",
            .age = @as(i32, 22),
        });
        thrown.rollback();

        var held = try tx.savepoint();
        _ = try tx.insert(Person, &run, .{
            .id = kept,
            .email = "kept@example.dev",
            .age = @as(i32, 23),
        });
        try held.release();

        try tx.commit();
    }

    try testing.expect(!try stack.db.exists(Person, &run, .{ .where = .{ .id = undone } }));
    try testing.expect(try stack.db.exists(Person, &run, .{ .where = .{ .id = kept } }));
}

test "a savepoint an outer rollback ended stays ended after a newer one is taken" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    const kept = scratch_id + 9;
    defer _ = stack.db.delete(Person, &run, .{ .where = .{ .id = kept } }) catch {};

    {
        var tx = try stack.db.begin(&run, .{});
        defer tx.deinit();

        var outer = try tx.savepoint();
        defer outer.deinit();
        var later = later: {
            var inner = try tx.savepoint();
            // The `defer` that used to send `ROLLBACK TO` a mark Postgres had
            // already dropped with `outer`, once `later` was taken, which
            // aborted the transaction and failed the commit below.
            defer inner.deinit();
            outer.rollback();
            break :later try tx.savepoint();
        };
        _ = try tx.insert(Person, &run, .{
            .id = kept,
            .email = "kept-after-unwind@example.dev",
            .age = @as(i32, 24),
        });
        try later.release();
        try tx.commit();
    }

    try testing.expect(try stack.db.exists(Person, &run, .{ .where = .{ .id = kept } }));
}

test "a commit after a failed statement nobody undid is refused, and nothing in the transaction was kept" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    const before_clash = scratch_id + 7;
    defer _ = stack.db.delete(Person, &run, .{ .where = .{ .id = before_clash } }) catch {};
    const dirty_before = try postgres.dirtyConnections();

    {
        var tx = try stack.db.begin(&run, .{});
        defer tx.deinit();

        _ = try tx.insert(Person, &run, .{
            .id = before_clash,
            .email = "lost@example.dev",
            .age = @as(i32, 40),
        });
        // The mistake: the error caught and carried on past, with no
        // savepoint around it. Postgres has aborted the transaction here.
        if (tx.insert(Person, &run, .{
            .id = @as(i64, 1),
            .email = "clash@example.dev",
            .age = @as(i32, 30),
        })) |_| return error.TestUnexpectedResult else |err| try testing.expectEqual(error.AlreadyExists, err);

        // Sent, this COMMIT is answered with the tag `ROLLBACK` and no error,
        // and it used to come back as success.
        try testing.expectError(error.QueryFailed, tx.commit());
    }

    // What the refusal protects: the handler was not told the first insert
    // was kept, because it was not.
    try testing.expect(!try stack.db.exists(Person, &run, .{ .where = .{ .id = before_clash } }));
    // And the connection was rolled back and kept, not thrown away.
    try testing.expectEqual(dirty_before, try postgres.dirtyConnections());
}

test "a statement after a failed one in the same transaction is answered 25P02, not a reconnect" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    const dirty_before = try postgres.dirtyConnections();
    {
        var tx = try stack.db.begin(&run, .{});
        defer tx.deinit();
        try testing.expectError(error.AlreadyExists, tx.insert(Person, &run, .{
            .id = @as(i64, 1),
            .email = "clash@example.dev",
            .age = @as(i32, 30),
        }));
        // pg.zig used to refuse this before it left the process, as a
        // connection it could not use: `Disconnected`, and a reconnect.
        try testing.expectError(error.QueryFailed, tx.select(Person, &run, .{ .where = .{ .id = @as(i64, 1) } }));
        try testing.expectEqualStrings("25P02", db_mod.lastProblem(&run).?.code);
    }
    try testing.expectEqual(dirty_before, try postgres.dirtyConnections());
}

test "a serialization failure answers RolledBack, and the transaction run again goes through" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    const id = scratch_id + 8;
    _ = try stack.db.insert(Person, &run, .{
        .id = id,
        .email = "contended@example.dev",
        .age = @as(i32, 30),
    });
    defer _ = stack.db.delete(Person, &run, .{ .where = .{ .id = id } }) catch {};

    // The retry loop a handler writes, which it could not before: every
    // failure here used to be `QueryFailed`, the same word as a typo.
    var attempts: usize = 0;
    while (true) {
        attempts += 1;
        var tx = try stack.db.begin(&run, .{ .isolation = .repeatable_read });
        defer tx.deinit();

        const seen = (try tx.one(Person, &run, .{ .where = .{ .id = id } })).?;
        // Somebody else changes the row after this transaction's snapshot,
        // on the pool's other connection — the first time round only.
        if (attempts == 1) _ = try stack.db.update(Person, &run, .{
            .set = .{ .age = .{ .plus = @as(i32, 1) } },
            .where = .{ .id = id },
        });

        const wrote = tx.update(Person, &run, .{
            .set = .{ .age = seen.age + 10 },
            .where = .{ .id = id },
        });
        if (wrote) |_| {} else |err| switch (err) {
            error.RolledBack => {
                try testing.expectEqual(@as(usize, 1), attempts);
                continue;
            },
            else => return err,
        }
        try tx.commit();
        break;
    }

    try testing.expectEqual(@as(usize, 2), attempts);
    // 30, one from the other writer, ten from the retry that read it.
    const now = (try stack.db.one(Person, &run, .{ .where = .{ .id = id } })).?;
    try testing.expectEqual(@as(i32, 41), now.age);
}

/// What the second half of a deadlock found: its transaction rolled back
/// for the other's sake, or went through once the other one was.
const Deadlocked = enum { rolled_back, went_through, failed };

/// Hold `first`, say so, then reach for `second`, which the test's own
/// transaction holds. One of the two transactions is the one Postgres
/// breaks the cycle with.
fn holdThenReach(db: *db_mod.Db, gpa: std.mem.Allocator, holding: *std.atomic.Value(bool), first: i64, second: i64) Deadlocked {
    var run = nilo.Run.init(gpa);
    defer run.deinit();
    var tx = db.begin(&run, .{}) catch return .failed;
    defer tx.deinit();
    _ = tx.update(Person, &run, .{ .set = .{ .age = @as(i32, 1) }, .where = .{ .id = first } }) catch return .failed;
    holding.store(true, .release);
    _ = tx.update(Person, &run, .{ .set = .{ .age = @as(i32, 2) }, .where = .{ .id = second } }) catch |err|
        return if (err == error.RolledBack) .rolled_back else .failed;
    tx.commit() catch return .failed;
    return .went_through;
}

test "a deadlock answers RolledBack to the transaction Postgres broke it with, and the other goes through" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    const a = scratch_id + 30;
    const b = scratch_id + 31;
    _ = try stack.db.insert(Person, &run, .{ .id = a, .email = "deadlock-a@example.dev", .age = @as(i32, 30) });
    _ = try stack.db.insert(Person, &run, .{ .id = b, .email = "deadlock-b@example.dev", .age = @as(i32, 30) });
    defer _ = stack.db.delete(Person, &run, .{ .where = .{ .id = .{ .in = &[_]i64{ a, b } } } }) catch {};

    const io = stack.live.threaded.io();
    var tx = try stack.db.begin(&run, .{});
    defer tx.deinit();
    _ = try tx.update(Person, &run, .{ .set = .{ .age = @as(i32, 3) }, .where = .{ .id = a } });

    // The other transaction takes `b`, and then waits on `a`.
    var holding: std.atomic.Value(bool) = .init(false);
    var other = io.concurrent(holdThenReach, .{ &stack.db, gpa, &holding, b, a }) catch return error.SkipZigTest;
    var waited: usize = 0;
    while (!holding.load(.acquire)) : (waited += 1) {
        if (waited == 500) {
            _ = other.cancel(io);
            return error.TestUnexpectedResult;
        }
        try std.Io.sleep(io, .fromMilliseconds(10), .awake);
    }

    // This one reaches for `b`: a cycle, which Postgres finds after its
    // `deadlock_timeout` and breaks by rolling one side back with `40P01`.
    const mine: Deadlocked = if (tx.update(Person, &run, .{ .set = .{ .age = @as(i32, 4) }, .where = .{ .id = b } })) |_| blk: {
        try tx.commit();
        break :blk .went_through;
    } else |err| if (err == error.RolledBack) .rolled_back else return err;
    const theirs = other.await(io);

    try testing.expect((mine == .rolled_back and theirs == .went_through) or
        (mine == .went_through and theirs == .rolled_back));
    // The code is kept for the call that met it, on its own thread.
    if (mine == .rolled_back) try testing.expectEqualStrings("40P01", db_mod.lastProblem(&run).?.code);
}

/// `migrate.apply` on a task of its own, saying when it came back.
fn applyAndSay(db: *db_mod.Db, gpa: std.mem.Allocator, v: migrate.Version, hash: []const u8, done: *std.atomic.Value(bool)) bool {
    defer done.store(true, .release);
    var run = nilo.Run.init(gpa);
    defer run.deinit();
    return migrate.apply(db, &run, v, hash) catch false;
}

test "a version waits for the advisory lock another process holds, so two replicas never run it twice" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();
    try migrate.ensureLedger(&stack.db, &run);

    // A version number of this build's own: both optimize modes run this
    // file against one database at once, and share its ledger.
    const number: i64 = if (builtin.mode == .debug) 990_001 else 990_002;
    const made = "nilo_live_locked_" ++ mode_suffix;
    const forget = "DELETE FROM \"nilo_migrations\" WHERE \"version\" = " ++
        (if (builtin.mode == .debug) "990001" else "990002");
    _ = try stack.db.exec(&run, forget, .{});
    _ = try stack.db.exec(&run, "DROP TABLE IF EXISTS \"" ++ made ++ "\"", .{});
    defer _ = stack.db.exec(&run, forget, .{}) catch {};
    defer _ = stack.db.exec(&run, "DROP TABLE IF EXISTS \"" ++ made ++ "\"", .{}) catch {};

    const steps = [_]migrate.Step{.{ .kind = .create_table, .sql = "CREATE TABLE \"" ++ made ++ "\" (\"id\" int)", .why = "" }};
    const v: migrate.Version = .{ .number = number, .name = "locked", .steps = &steps };
    var digest: [64]u8 = undefined;
    const hash = migrate.hashOf("", v.steps, &digest);

    // Another replica, part way through its own migration, holding the lock.
    var holder = try stack.db.begin(&run, .{});
    defer holder.deinit();
    // The lock is asked for, not waited for (`migrate.polled`), so a holder in this test asks until it has it.
    while (!(try holder.rawOne(bool, &run, comptime dialect.Postgres.advisoryLock(migrate.lock_key).?, .{})).?) {
        _ = try holder.exec(&run, "SELECT pg_sleep(0.05)", .{});
    }

    const io = stack.live.threaded.io();
    var done: std.atomic.Value(bool) = .init(false);
    var task = io.concurrent(applyAndSay, .{ &stack.db, gpa, v, hash, &done }) catch return error.SkipZigTest;
    try std.Io.sleep(io, .fromMilliseconds(300), .awake);
    // Still waiting: without the lock it would have run the version by now.
    const waited = !done.load(.acquire);

    try holder.commit();
    const ran = task.await(io);
    try testing.expect(waited);
    try testing.expect(ran);
}

test "a version gives up on a table another transaction holds after its own lock_timeout, and keeps nothing" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();
    try migrate.ensureLedger(&stack.db, &run);

    const number: i64 = if (builtin.mode == .debug) 990_003 else 990_004;
    const held = "nilo_live_waited_" ++ mode_suffix;
    const forget = "DELETE FROM \"nilo_migrations\" WHERE \"version\" = " ++
        (if (builtin.mode == .debug) "990003" else "990004");
    _ = try stack.db.exec(&run, forget, .{});
    _ = try stack.db.exec(&run, "DROP TABLE IF EXISTS \"" ++ held ++ "\"", .{});
    _ = try stack.db.exec(&run, "CREATE TABLE \"" ++ held ++ "\" (\"id\" int)", .{});
    defer _ = stack.db.exec(&run, forget, .{}) catch {};
    defer _ = stack.db.exec(&run, "DROP TABLE IF EXISTS \"" ++ held ++ "\"", .{}) catch {};

    const steps = [_]migrate.Step{.{
        .kind = .add_column,
        .sql = "ALTER TABLE \"" ++ held ++ "\" ADD COLUMN \"n\" int8",
        .why = "add " ++ held ++ ".n",
    }};
    var digest: [64]u8 = undefined;
    const hash = migrate.hashOf("", &steps, &digest);

    // A report part way through: a read in an open transaction holds the
    // weakest lock there is, and an `ALTER` needs the strongest.
    var holder = try stack.db.begin(&run, .{});
    defer holder.deinit();
    _ = try holder.exec(&run, "SELECT * FROM \"" ++ held ++ "\"", .{});

    // Well under the URL's own ten seconds (ADR 239), so a `Locked` that
    // came from that bound rather than the version's cannot pass this.
    const started = core.monotonicMicros();
    try testing.expectError(error.Locked, migrate.apply(&stack.db, &run, .{
        .number = number,
        .name = "waited",
        .steps = &steps,
        .lock_timeout_ms = 200,
    }, hash));
    const waited_ms = @divFloor(core.monotonicMicros() - started, std.time.us_per_ms);
    try testing.expect(waited_ms >= 150 and waited_ms < 5_000);

    // Nothing kept, the ledger row included.
    try testing.expect(try stack.db.find(migrate.Applied, &run, number) == null);

    // Once the report ends, the same version runs under the default.
    try holder.commit();
    try testing.expect(try migrate.apply(&stack.db, &run, .{ .number = number, .name = "waited", .steps = &steps }, hash));
    _ = try stack.db.exec(&run, "SELECT \"n\" FROM \"" ++ held ++ "\"", .{});
}

// -- a role that is not the owner ------------------------------------------
//
// Every test below makes a role of its own and drops it again, so the suite is
// rerunnable and leaves the cluster as it found it. A role is cluster-wide, not
// per database, so each is named for the optimize mode as the tables are: the
// two modes run at once.

/// `url` with its user and password swapped for `role` and `nilo`, which is the
/// password every role these tests make is given.
fn urlAs(arena: std.mem.Allocator, url: []const u8, role: []const u8) ![]const u8 {
    const scheme_end = (std.mem.indexOf(u8, url, "://") orelse return error.SkipZigTest) + 3;
    const slash = std.mem.indexOfScalarPos(u8, url, scheme_end, '/') orelse url.len;
    const at = std.mem.lastIndexOfScalar(u8, url[scheme_end..slash], '@');
    const host = if (at) |a| url[scheme_end + a + 1 ..] else url[scheme_end..];
    return std.fmt.allocPrint(arena, "{s}{s}:nilo@{s}", .{ url[0..scheme_end], role, host });
}

/// Make a role, or skip the test where the connection may not: a role is a
/// privilege a managed database often withholds, and a test that needs one is
/// not a reason to fail a run there.
fn makeRole(db: *db_mod.Db, run: *core.Run, comptime role: []const u8) !void {
    _ = try db.exec(run, "DROP ROLE IF EXISTS " ++ role, .{});
    _ = db.exec(run, "CREATE ROLE " ++ role ++ " LOGIN PASSWORD 'nilo'", .{}) catch |err| {
        if (db_mod.lastProblem(run)) |problem| {
            if (std.mem.eql(u8, problem.code, "42501")) return error.SkipZigTest;
        }
        return err;
    };
}

/// What a replica applying a version found.
const Applying = enum { ran, already, failed };

fn applyAs(db: *db_mod.Db, gpa: std.mem.Allocator, v: migrate.Version, hash: []const u8) Applying {
    var run = nilo.Run.init(gpa);
    defer run.deinit();
    const ran = migrate.apply(db, &run, v, hash) catch return .failed;
    return if (ran) .ran else .already;
}

const rr_role = "nilo_probe_rr_" ++ mode_suffix;
const rr_schema = "nilo_probe_rr_" ++ mode_suffix;

test "two replicas migrating at once apply a version once, under a role whose default is REPEATABLE READ" {
    const gpa = testing.allocator;
    const url = live_config.database_url orelse return error.SkipZigTest;

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var admin = db_mod.Db.init(gpa, url, .{ .size = 1, .connect_on_init = 1, .unchecked = true });
    defer admin.deinit();
    try admin.nilo_start(io, .off);
    defer admin.nilo_stop();
    var run: core.Run = .init(gpa);
    defer run.deinit();

    // The role and the schema it owns, which its `search_path` is, so the
    // ledger and the table the version makes land there and nowhere shared.
    _ = try admin.exec(&run, "DROP SCHEMA IF EXISTS " ++ rr_schema ++ " CASCADE", .{});
    try makeRole(&admin, &run, rr_role);
    defer _ = admin.exec(&run, "DROP ROLE IF EXISTS " ++ rr_role, .{}) catch {};
    defer _ = admin.exec(&run, "DROP SCHEMA IF EXISTS " ++ rr_schema ++ " CASCADE", .{}) catch {};
    _ = try admin.exec(&run, "CREATE SCHEMA " ++ rr_schema ++ " AUTHORIZATION " ++ rr_role, .{});
    _ = try admin.exec(&run, "ALTER ROLE " ++ rr_role ++ " SET search_path = " ++ rr_schema, .{});
    // What the todo list asked about: `ALTER ROLE … SET
    // default_transaction_isolation` is a thing, and a plain `BEGIN` obeys it.
    _ = try admin.exec(&run, "ALTER ROLE " ++ rr_role ++ " SET default_transaction_isolation = 'repeatable read'", .{});

    // Two replicas: two pools, two connections, one role.
    const as_role = try urlAs(run.arena(), url, rr_role);
    var first = db_mod.Db.init(gpa, as_role, .{ .size = 1, .connect_on_init = 1, .unchecked = true });
    defer first.deinit();
    try first.nilo_start(io, .off);
    defer first.nilo_stop();
    var second = db_mod.Db.init(gpa, as_role, .{ .size = 1, .connect_on_init = 1, .unchecked = true });
    defer second.deinit();
    try second.nilo_start(io, .off);
    defer second.nilo_stop();

    // The premise: the role really does begin in REPEATABLE READ.
    var plain = try first.begin(&run, .{});
    defer plain.deinit();
    const level = (try plain.rawOne([]const u8, &run, "SELECT current_setting('transaction_isolation')", .{})).?;
    try testing.expectEqualStrings("repeatable read", level);
    try plain.commit();

    try migrate.ensureLedger(&first, &run);

    // A version that fails if it runs twice: its table is made by a plain
    // `CREATE TABLE`. The first replica holds the lock for most of a second.
    const steps = [_]migrate.Step{
        .{ .kind = .create_table, .sql = "CREATE TABLE \"nilo_probe_twice\" (\"id\" int)", .why = "" },
        .{ .kind = .data, .sql = "SELECT pg_sleep(0.8)", .why = "stay in the transaction a while" },
    };
    const v: migrate.Version = .{ .number = 1, .name = "twice", .steps = &steps };
    var digest: [64]u8 = undefined;
    const hash = migrate.hashOf("", v.steps, &digest);

    var one = io.concurrent(applyAs, .{ &first, gpa, v, hash }) catch return error.SkipZigTest;
    try std.Io.sleep(io, .fromMilliseconds(300), .awake);
    // The second arrives while the first holds the lock, so its snapshot, if it
    // takes one at the lock, is from before the first commits.
    var two = io.concurrent(applyAs, .{ &second, gpa, v, hash }) catch return error.SkipZigTest;

    const a = one.await(io);
    const b = two.await(io);
    try testing.expectEqual(Applying.ran, a);
    try testing.expectEqual(Applying.already, b);
}

const dml_role = "nilo_probe_dml_" ++ mode_suffix;
const dml_schema = "nilo_probe_dml_" ++ mode_suffix;

test "expect boots under a role that may read and write rows and may create nothing" {
    const gpa = testing.allocator;
    const url = live_config.database_url orelse return error.SkipZigTest;

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var admin = db_mod.Db.init(gpa, url, .{ .size = 1, .connect_on_init = 1, .unchecked = true });
    defer admin.deinit();
    try admin.nilo_start(io, .off);
    defer admin.nilo_stop();
    var run: core.Run = .init(gpa);
    defer run.deinit();

    // The schema belongs to the admin, as the migration's owner's would: the
    // role is let in and given rows, and no CREATE.
    _ = try admin.exec(&run, "DROP SCHEMA IF EXISTS " ++ dml_schema ++ " CASCADE", .{});
    try makeRole(&admin, &run, dml_role);
    defer _ = admin.exec(&run, "DROP ROLE IF EXISTS " ++ dml_role, .{}) catch {};
    defer _ = admin.exec(&run, "DROP SCHEMA IF EXISTS " ++ dml_schema ++ " CASCADE", .{}) catch {};
    _ = try admin.exec(&run, "CREATE SCHEMA " ++ dml_schema, .{});
    _ = try admin.exec(&run, "ALTER ROLE " ++ dml_role ++ " SET search_path = " ++ dml_schema, .{});
    _ = try admin.exec(&run, "GRANT USAGE ON SCHEMA " ++ dml_schema ++ " TO " ++ dml_role, .{});

    // The migration's owner made the ledger, as `db migrate` did.
    {
        var tx = try admin.begin(&run, .{});
        defer tx.deinit();
        _ = try tx.exec(&run, "SET LOCAL search_path TO " ++ dml_schema, .{});
        _ = try tx.exec(&run, comptime ddl.createIfMissing(dialect.Postgres, migrate.Applied), .{});
        try tx.commit();
    }
    _ = try admin.exec(&run, "GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA " ++ dml_schema ++ " TO " ++ dml_role, .{});

    const as_role = try urlAs(run.arena(), url, dml_role);
    var app_db = db_mod.Db.init(gpa, as_role, .{ .size = 1, .connect_on_init = 1, .unchecked = true });
    defer app_db.deinit();
    try app_db.nilo_start(io, .off);
    defer app_db.nilo_stop();

    // The premise: it really may create nothing.
    try testing.expectError(error.QueryFailed, app_db.exec(&run, "CREATE TABLE \"nilo_probe_nope\" (id int)", .{}));

    // The boot of an application that is not the migration's owner.
    try migrate.expect(&app_db, &run, 0);
    try testing.expectEqual(@as(i64, 0), try migrate.headVersion(&app_db, &run));
}

/// A table name of 62 bytes, which is allowed, and whose primary key Postgres
/// then cannot name `<table>_pkey`: that is 67, so it cuts the table's part.
const long_pk_head = "nilo_probe_pkey_" ++ mode_suffix ++ "_";
const long_pk_pad: [62 - long_pk_head.len]u8 = @splat('p');
const long_pk_table = long_pk_head ++ long_pk_pad;

const LongPk = struct {
    pub const nilo_table = .{ .name = long_pk_table, .key = .id };
    id: i64,
    label: []const u8,
};

test "sql.violated names the primary key of a table whose name leaves no room for _pkey" {
    const gpa = testing.allocator;
    const url = live_config.database_url orelse return error.SkipZigTest;

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var db = db_mod.Db.init(gpa, url, .{ .size = 1, .connect_on_init = 1, .unchecked = true });
    defer db.deinit();
    try db.nilo_start(threaded.io(), .off);
    defer db.nilo_stop();
    var run: core.Run = .init(gpa);
    defer run.deinit();

    try testing.expectEqual(@as(usize, 62), long_pk_table.len);
    _ = try db.exec(&run, "DROP TABLE IF EXISTS \"" ++ long_pk_table ++ "\"", .{});
    defer _ = db.exec(&run, "DROP TABLE IF EXISTS \"" ++ long_pk_table ++ "\"", .{}) catch {};
    try migrate.createMissing(&db, &run, .{ .tables = &.{LongPk} });

    _ = try db.insert(LongPk, &run, .{ .id = @as(i64, 1), .label = "one" });
    try testing.expectError(error.AlreadyExists, db.insert(LongPk, &run, .{ .id = @as(i64, 1), .label = "again" }));
    // Postgres says which constraint, and it is not `<62 bytes>_pkey`.
    try testing.expect(db_mod.lastProblem(&run).?.constraint.len <= 63);
    try testing.expect(db_mod.violated(&run, LongPk, .id));
}

const sp_schema = "nilo_probe_sp_" ++ mode_suffix;
const sp_table = "nilo_probe_sp_t_" ++ mode_suffix;

test "a table with no schema is found down the whole search_path, as a query finds it" {
    const gpa = testing.allocator;
    const url = live_config.database_url orelse return error.SkipZigTest;

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var db = db_mod.Db.init(gpa, url, .{ .size = 1, .connect_on_init = 1, .unchecked = true });
    defer db.deinit();
    try db.nilo_start(threaded.io(), .off);
    defer db.nilo_stop();
    var run: core.Run = .init(gpa);
    defer run.deinit();

    // The table is in `public`, and the path puts another schema first: the
    // shape of an application whose role has a schema of its own.
    _ = try db.exec(&run, "DROP SCHEMA IF EXISTS " ++ sp_schema ++ " CASCADE", .{});
    _ = try db.exec(&run, "DROP TABLE IF EXISTS \"" ++ sp_table ++ "\"", .{});
    defer _ = db.exec(&run, "DROP SCHEMA IF EXISTS " ++ sp_schema ++ " CASCADE", .{}) catch {};
    defer _ = db.exec(&run, "DROP TABLE IF EXISTS \"" ++ sp_table ++ "\"", .{}) catch {};
    _ = try db.exec(&run, "CREATE SCHEMA " ++ sp_schema, .{});
    _ = try db.exec(&run, "CREATE TABLE \"" ++ sp_table ++ "\" (id int8 PRIMARY KEY, label text NOT NULL)", .{});

    var tx = try db.begin(&run, .{});
    defer tx.deinit();
    _ = try tx.exec(&run, "SET LOCAL search_path TO " ++ sp_schema ++ ", public", .{});
    // A query resolves it, down the path.
    _ = try tx.exec(&run, "SELECT id, label FROM \"" ++ sp_table ++ "\"", .{});
    // And so must the question about its columns.
    const columns = try tx.liveColumns(&run, null, sp_table);
    try testing.expectEqual(@as(usize, 2), columns.len);
}

const trig_table = "nilo_probe_trig_" ++ mode_suffix;
const trig_fn = "nilo_probe_trig_fn_" ++ mode_suffix;

test "a plan that retypes a column an unchanged trigger names in UPDATE OF runs on Postgres" {
    const gpa = testing.allocator;
    const url = live_config.database_url orelse return error.SkipZigTest;

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var db = db_mod.Db.init(gpa, url, .{ .size = 1, .connect_on_init = 1, .unchecked = true });
    defer db.deinit();
    try db.nilo_start(threaded.io(), .off);
    defer db.nilo_stop();
    var run: core.Run = .init(gpa);
    defer run.deinit();

    const Before = struct {
        pub const nilo_table = .{
            .name = trig_table,
            .key = .id,
            .trigger = .{ .nilo_probe_trig_touch = .{
                .when = "BEFORE UPDATE OF count",
                .run = "FOR EACH ROW EXECUTE FUNCTION " ++ trig_fn ++ "()",
            } },
        };
        id: i64,
        count: i32,
    };
    // The same trigger, word for word, over a column that is wider.
    const After = struct {
        pub const nilo_table = .{
            .name = trig_table,
            .key = .id,
            .trigger = .{ .nilo_probe_trig_touch = .{
                .when = "BEFORE UPDATE OF count",
                .run = "FOR EACH ROW EXECUTE FUNCTION " ++ trig_fn ++ "()",
            } },
        };
        id: i64,
        count: i64,
    };

    _ = try db.exec(&run, "DROP TABLE IF EXISTS \"" ++ trig_table ++ "\"", .{});
    _ = try db.exec(&run, "DROP FUNCTION IF EXISTS " ++ trig_fn ++ "()", .{});
    defer _ = db.exec(&run, "DROP FUNCTION IF EXISTS " ++ trig_fn ++ "()", .{}) catch {};
    defer _ = db.exec(&run, "DROP TABLE IF EXISTS \"" ++ trig_table ++ "\"", .{}) catch {};
    _ = try db.exec(&run, "CREATE FUNCTION " ++ trig_fn ++ "() RETURNS trigger AS $$ BEGIN RETURN NEW; END $$ LANGUAGE plpgsql", .{});
    try migrate.createMissing(&db, &run, .{ .tables = &.{Before} });
    _ = try db.insert(Before, &run, .{ .id = @as(i64, 1), .count = @as(i32, 7) });

    const a = run.arena();
    const before = try migrate.snapshotOf(a, dialect.Postgres, 1, comptime migrate.desiredOf(dialect.Postgres, .{ .tables = &.{Before} }));
    const change = try migrate.plan(a, dialect.Postgres, comptime migrate.desiredOf(dialect.Postgres, .{ .tables = &.{After} }), before);
    try testing.expectEqual(@as(usize, 0), change.problems.len);

    // In one transaction, as `apply` sends a version. Postgres refuses the
    // `ALTER … TYPE` while the trigger that names the column is there.
    var tx = try db.begin(&run, .{});
    defer tx.deinit();
    for (change.steps) |step| _ = try tx.exec(&run, step.sql, .{});
    try tx.commit();

    // And the trigger is still there afterwards, doing its job.
    const kept = (try db.find(After, &run, @as(i64, 1))).?;
    try testing.expectEqual(@as(i64, 7), kept.count);
    const triggers = try db.rawOne(i64, &run, "SELECT count(*)::int8 FROM pg_trigger WHERE tgname = 'nilo_probe_trig_touch' AND tgrelid = '\"" ++ trig_table ++ "\"'::regclass", .{});
    try testing.expectEqual(@as(?i64, 1), triggers);
}

const Shuffled = struct {
    id: i64,
    email: []const u8,
    age: i32,
};

test "a batch of three hundred comes back row for row in the order it went in" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    // Ids that run backwards and ages that repeat: nothing about the data
    // makes input order and any other order the same.
    const count = 300;
    const first: i64 = 50_000;
    var rows: [count]Shuffled = undefined;
    for (&rows, 0..) |*row, i| row.* = .{
        .id = first + @as(i64, @intCast(count - i)),
        .email = try std.fmt.allocPrint(run.arena(), "ordered{d}@batch.dev", .{i}),
        .age = @intCast(i % 7),
    };
    defer _ = stack.db.delete(Person, &run, .{ .where = .{ .id = .{ .gte = first } } }) catch {};
    const stored = try stack.db.insertMany(Person, &run, @as([]const Shuffled, &rows));

    try testing.expectEqual(@as(usize, count), stored.len);
    for (stored, rows) |got, sent| {
        try testing.expectEqual(sent.id, got.id);
        try testing.expectEqualStrings(sent.email, got.email);
    }
}

// -- the column type nothing checks at startup ----------------------------

/// The Row that reads `role`, and **`Role` is missing `moderator` on
/// purpose** — the fixture's third row has it. This is a Zig enum that has
/// fallen behind its Postgres one, which is what an `ALTER TYPE … ADD VALUE`
/// leaves behind and the only way this column type goes wrong.
///
/// `.managed = false` because the fixture's `role` really is a Postgres
/// `ENUM`, and a plain Zig enum on a Row nilo builds is a `text` column with a
/// check over its words (ADR 181). Saying the program only reads this table
/// is what leaves the column type to the database, which is where it is.
const Staff = struct {
    pub const nilo_table = .{ .name = table, .key = .id, .managed = false };

    id: i64,
    role: Role,

    const Role = enum { admin, member };
};

fn staffUnderThree(db: *db_mod.Db, c: *nilo.Ctx) ![]Staff {
    return db.select(Staff, c, .{
        .where = .{ .id = .{ .lt = @as(i64, 3) } },
        .order = .{ .id = .asc },
    });
}

test "an enum column comes back as the Zig value of the same name" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    try stack.app.get("/staff", staffUnderThree);
    const answer = try stack.client.get(&stack.app, "/staff");

    try testing.expectEqual(@as(u16, 200), answer.status);
    try testing.expectEqualStrings(
        "[{\"id\":1,\"role\":\"admin\"},{\"id\":2,\"role\":\"member\"}]",
        answer.body,
    );
}

/// The same Row with the type named, which is what lets the check hold the
/// values against the database instead of only the type's name.
const NamedStaff = struct {
    pub const nilo_table = .{ .name = table, .key = .id };

    id: i64,
    role: Role,

    const Role = enum {
        admin,
        member,

        pub const nilo_column = role_type;
    };
};

test "an enum that has fallen behind its type is named at startup, not on the first row" {
    const gpa = testing.allocator;
    var live = (try Live.open(gpa)) orelse return error.SkipZigTest;
    defer live.close(gpa);

    const arena = live.arena.allocator();
    const labels = try live.wire.labelsOf(arena, dialect.Postgres.enum_values.?, role_type);
    try testing.expectEqual(@as(usize, 3), labels.len);
    try testing.expectEqualStrings("moderator", labels[2]);

    // `Role` lacks `moderator` on purpose (see `Staff`). Until this existed
    // the check passed and the third fixture row was a 500.
    var problems: std.ArrayList(schema.Problem) = .empty;
    const found = try schema.compareEnum(NamedStaff.Role, "NamedStaff", table, "role", role_type, labels, &problems, arena);
    try testing.expectEqual(@as(usize, 1), found);
    try testing.expectEqual(schema.Mismatch.value_zig_lacks, problems.items[0].kind);
    try testing.expectEqualStrings("moderator", problems.items[0].found);

    // And through the Db, which is the door a program uses — with the enum
    // that matches its type, since `checkSchema` reports a problem with
    // `std.log.err` and the test runner counts that as a failure. The
    // problem itself is asserted above, one layer down.
    var db = db_mod.Db.init(gpa, "already open", .{});
    db.wire = live.wire;
    try testing.expectEqual(@as(usize, 0), try db.checkSchema(&.{ WholeStaff, Staff }));
}

/// The Row whose enum has kept up with its type: every label, and the type
/// named, so the startup check reads the values and finds nothing to say.
const WholeStaff = struct {
    pub const nilo_table = .{ .name = table, .key = .id };

    id: i64,
    role: Role,

    const Role = enum {
        admin,
        member,
        moderator,

        pub const nilo_column = role_type;
    };
};

fn allStaff(db: *db_mod.Db, c: *nilo.Ctx) ![]Staff {
    return db.select(Staff, c, .{ .order = .{ .id = .asc } });
}

test "an enum value the Zig enum does not have is a 500, not a dead process" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    // Both the framework's line for the failed request and this module's line
    // naming the value are the behaviour under test rather than news.
    const was = std.testing.log_level;
    defer std.testing.log_level = was;
    std.testing.log_level = .err;

    try stack.app.get("/all-staff", allStaff);
    const answer = try stack.client.get(&stack.app, "/all-staff");

    // Before the decode moved out of the driver this was
    // `std.meta.stringToEnum(T, str).?` and the third row took the process
    // down — every in-flight request with it, because Zig cannot recover from
    // a panic (ADR 007). One request failing is the whole of the fix.
    try testing.expectEqual(@as(u16, 500), answer.status);
}

test "a connection is usable again after an enum refused to decode" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    const was = std.testing.log_level;
    defer std.testing.log_level = was;
    std.testing.log_level = .err;

    try stack.app.get("/all-staff", allStaff);
    try stack.app.get("/staff", staffUnderThree);

    // The rule the whole of `wire.zig` is built on: whatever the handler did,
    // the connection goes back usable. A row that stopped mid-result-set is a
    // result set left unread, so this asks for one more than the pool holds.
    var round: usize = 0;
    while (round < 4) : (round += 1) {
        const failed = try stack.client.get(&stack.app, "/all-staff");
        try testing.expectEqual(@as(u16, 500), failed.status);
    }

    const answer = try stack.client.get(&stack.app, "/staff");
    try testing.expectEqual(@as(u16, 200), answer.status);
}

// -- array columns --------------------------------------------------------

/// `tags` as `Str` and `scores` as a plain slice, which is the pair worth
/// reading together: one goes through the second walk that attaches the
/// lifetime marker, the other is handed straight over by the driver.
const Ticket = struct {
    pub const nilo_table = .{ .name = list_table, .key = .id };

    id: i64,
    tags: []const nilo.Str,
    scores: ?[]const i32,
};

test "an array column comes back as a slice, empty and null included" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    const found = try stack.db.select(Ticket, &run, .{
        .where = .{ .id = .{ .lte = @as(i64, 2) } },
        .order = .{ .id = .asc },
    });
    try testing.expectEqual(@as(usize, 2), found.len);

    try testing.expectEqual(@as(usize, 2), found[0].tags.len);
    try testing.expectEqualStrings("urgent", found[0].tags[0].view());
    try testing.expectEqualStrings("billing", found[0].tags[1].view());
    try testing.expectEqualSlices(i32, &.{ 10, 20, 30 }, found[0].scores.?);

    // An empty array is a slice of length zero and **not** a null: Postgres
    // tells the two apart and so does this, which is the whole reason the
    // second row is in the fixture.
    try testing.expectEqual(@as(usize, 0), found[1].tags.len);
    try testing.expectEqual(@as(?[]const i32, null), found[1].scores);
}

fn ticketOne(db: *db_mod.Db, c: *nilo.Ctx) ![]Ticket {
    return db.select(Ticket, c, .{ .where = .{ .id = @as(i64, 1) } });
}

test "an array column leaves as a JSON array" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    try stack.app.get("/ticket", ticketOne);
    const answer = try stack.client.get(&stack.app, "/ticket");

    try testing.expectEqual(@as(u16, 200), answer.status);
    try testing.expectEqualStrings(
        "[{\"id\":1,\"tags\":[\"urgent\",\"billing\"],\"scores\":[10,20,30]}]",
        answer.body,
    );
}

test "an array with a NULL in it is one failed request rather than a dead process" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    // The line naming what happened is the behaviour under test.
    const was = std.testing.log_level;
    defer std.testing.log_level = was;
    std.testing.log_level = .err;

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    // Postgres lets any array hold a NULL and there is no column definition
    // that forbids it, so this is not a fixture nobody would write — it is
    // what `text[]` means. Left to pg.zig it is `assert(has_nulls == 0)`,
    // which is a panic in Debug and a read past the end in ReleaseFast.
    try testing.expectError(error.QueryFailed, stack.db.select(Ticket, &run, .{
        .where = .{ .id = @as(i64, 3) },
    }));
}

/// The same column, read the way it has to be read when the array really can
/// hold a NULL. `?Str` in the slice rather than `?[]const Str` around it —
/// the null is in an element, not in the column.
const Loose = struct {
    pub const nilo_table = .{ .name = list_table, .key = .id };

    id: i64,
    tags: []const ?nilo.Str,
};

/// And as bytes, which reaches the Wire's list without `keptElement` in
/// between.
const LooseBytes = struct {
    pub const nilo_table = .{ .name = list_table, .key = .id };

    id: i64,
    tags: []const ?[]const u8,
};

test "a slice of optionals reads the array the strict one refused" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    const found = try stack.db.select(Loose, &run, .{ .where = .{ .id = @as(i64, 3) } });
    const bytes = try stack.db.select(LooseBytes, &run, .{ .where = .{ .id = @as(i64, 3) } });

    // Four statements more through the pool, each of whose answers
    // lands in the read buffer the elements above were read out of. pg.zig
    // copies an element only when it is exactly `[]const u8`, and these used
    // to point into that buffer and read "ZZZZ".
    for (0..4) |_| _ = try stack.db.raw([]const u8, &run, "SELECT repeat('Z', 64)", .{});

    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqual(@as(usize, 2), found[0].tags.len);
    try testing.expectEqualStrings("solo", found[0].tags[0].?.view());
    try testing.expectEqual(@as(?nilo.Str, null), found[0].tags[1]);

    try testing.expectEqual(@as(usize, 1), bytes.len);
    try testing.expectEqualStrings("solo", bytes[0].tags[0].?);
    try testing.expectEqual(@as(?[]const u8, null), bytes[0].tags[1]);
}

test "an array two dimensions deep is refused, because a slice is one" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    const was = std.testing.log_level;
    defer std.testing.log_level = was;
    std.testing.log_level = .err;

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    // `integer[]` in the DDL accepts an array of any depth — Postgres does not
    // enforce the dimensionality it was declared with. pg.zig asserts on it;
    // this answers instead.
    try testing.expectError(error.QueryFailed, stack.db.select(Ticket, &run, .{
        .where = .{ .id = @as(i64, 4) },
    }));
}

test "an array goes out to a column and comes back the same array" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    // A slice of literals, which is what a caller has — a value on its way to
    // the database has no lifetime question, so it is not asked for as `Str`.
    const made = try stack.db.insert(Ticket, &run, .{
        .id = @as(i64, 800),
        .tags = &.{ "written", "back" },
        .scores = @as(?[]const i32, &.{ 7, 8 }),
    });
    try testing.expectEqualStrings("written", made.tags[0].view());
    try testing.expectEqualSlices(i32, &.{ 7, 8 }, made.scores.?);

    // And again on a fresh read, so the answer is Postgres's rather than an
    // echo of what was sent.
    const back = (try stack.db.find(Ticket, &run, @as(i64, 800))).?;
    try testing.expectEqual(@as(usize, 2), back.tags.len);
    try testing.expectEqualStrings("back", back.tags[1].view());

    // An empty array written out is an empty array read back, and still not
    // a null.
    const empty = try stack.db.insert(Ticket, &run, .{
        .id = @as(i64, 801),
        .tags = &[_][]const u8{},
        .scores = @as(?[]const i32, null),
    });
    try testing.expectEqual(@as(usize, 0), empty.tags.len);
    try testing.expectEqual(@as(?[]const i32, null), empty.scores);
}

// -- a uuid, bound by hand and read in bulk -------------------------------

/// The same table read for its `uuid[]` column. `tags` is here because it is
/// `NOT NULL` and this Row writes as well as reads.
const Owned = struct {
    pub const nilo_table = .{ .name = list_table, .key = .id };

    id: i64,
    tags: []const nilo.Str,
    owners: ?[]const types.Uuid,
};

test "a uuid bound bare to db.exec reaches the column without a text cast" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    // What the report was: this compiled and answered `error.QueryFailed`,
    // with nothing logged at any level and nothing in Postgres's own log
    // because the statement never arrived (ADR 116, ADR 117). The workaround
    // was sending thirty-six characters and writing `$1::text::uuid`, which
    // costs an arena allocation per id and twenty bytes on the wire.
    const token = try types.Uuid.parse("550e8400-e29b-41d4-a716-446655440009");
    const changed = try stack.db.exec(
        &run,
        "UPDATE \"" ++ table ++ "\" SET token = $1 WHERE id = $2",
        .{ token, @as(i64, 2) },
    );
    try testing.expectEqual(@as(usize, 1), changed);

    // Read back through `db.raw` with the id bound bare as well, so both
    // halves of the fix are on one path.
    const Token = struct {
        pub const nilo_table = .{ .name = table, .key = .id };
        id: i64,
        token: ?types.Uuid,
    };
    const back = try stack.db.raw(
        Token,
        &run,
        "SELECT id, token FROM \"" ++ table ++ "\" WHERE token = $1",
        .{token},
    );
    try testing.expectEqual(@as(usize, 1), back.len);
    try testing.expectEqual(@as(i64, 2), back[0].id);
    try testing.expectEqualSlices(u8, &token.bytes, &back[0].token.?.bytes);
}

test "a uuid array goes out to a column and comes back the same array" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    const one = try types.Uuid.parse("550e8400-e29b-41d4-a716-446655440000");
    const two = try types.Uuid.parse("550e8400-e29b-41d4-a716-446655440001");

    const read = (try stack.db.find(Owned, &run, @as(i64, 1))).?;
    try testing.expectEqual(@as(usize, 2), read.owners.?.len);
    try testing.expectEqualSlices(u8, &one.bytes, &read.owners.?[0].bytes);
    try testing.expectEqualSlices(u8, &two.bytes, &read.owners.?[1].bytes);

    // Written, which is the half that stopped inside pg.zig: `[]const [16]u8`
    // is `cannot bind value of type`, four frames down and about a type the
    // caller never wrote (ADR 116).
    const made = try stack.db.insert(Owned, &run, .{
        .id = @as(i64, 810),
        .tags = &.{"written"},
        .owners = @as(?[]const types.Uuid, &.{ two, one }),
    });
    try testing.expectEqualSlices(u8, &two.bytes, &made.owners.?[0].bytes);

    // And the two edge cases every array column has.
    const empty = (try stack.db.find(Owned, &run, @as(i64, 2))).?;
    try testing.expectEqual(@as(usize, 0), empty.owners.?.len);
    // Row 4 rather than row 3 for the null: row 3's `tags` holds a NULL among
    // its elements, which this Row deliberately cannot read and which has a
    // test of its own.
    const absent = (try stack.db.find(Owned, &run, @as(i64, 4))).?;
    try testing.expectEqual(@as(?[]const types.Uuid, null), absent.owners);
}

test "an `in` over uuids is the one statement that stops an N+1" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    const Tokened = struct {
        pub const nilo_table = .{ .name = table, .key = .id };
        id: i64,
        token: ?types.Uuid,
    };

    const ada = try types.Uuid.parse("550e8400-e29b-41d4-a716-446655440000");
    const kid = try types.Uuid.parse("550e8400-e29b-41d4-a716-446655440001");

    // `WHERE token = ANY($1)`, which is what a list that attaches children to
    // its rows needs and what did not compile at all.
    const found = try stack.db.select(Tokened, &run, .{
        .where = .{ .token = .{ .in = &[_]types.Uuid{ ada, kid } } },
        .order = .{ .id = .asc },
    });
    try testing.expectEqual(@as(usize, 2), found.len);
    try testing.expectEqual(@as(i64, 1), found[0].id);
    try testing.expectEqual(@as(i64, 3), found[1].id);

    // An empty list matches nothing rather than failing, which is what
    // `= ANY('{}')` does.
    const none = try stack.db.select(Tokened, &run, .{
        .where = .{ .token = .{ .in = &[_]types.Uuid{} } },
    });
    try testing.expectEqual(@as(usize, 0), none.len);
}

// -- what a failed statement says -----------------------------------------

/// What the watcher below was told. A file-scope variable because a `Watcher`
/// is a plain function pointer with nowhere to put a capture, which is
/// [ADR 108](../docs/adr/108-a-statement-can-be-watched.md)'s own argument.
var said: ?db_mod.Sent = null;

fn recordSent(sent: db_mod.Sent) void {
    said = sent;
}

test "a failed statement carries what Postgres said, not only that it failed" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    said = null;
    stack.db.watching(recordSent);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    // A duplicate key, which is the failure with a name of its own — and the
    // one this test can take, because the failures `translate` cannot name
    // reach `std.log.err` and the test runner counts a logged `err` as a
    // failed run (`http/test_root.zig`). What is being pinned is the same slot
    // either way: `error.AlreadyExists` used to be the whole of what a program
    // could see, and the constraint that was violated is the field that names
    // the thing to go and fix (ADR 117).
    try testing.expectError(error.AlreadyExists, stack.db.exec(
        &run,
        "INSERT INTO \"" ++ table ++ "\" (id, email, age) VALUES ($1, $2, $3)",
        .{ @as(i64, 1), "dup@example.dev", @as(i32, 30) },
    ));

    const sent = said orelse return error.NothingWatched;
    try testing.expect(sent.failed);
    const problem = sent.problem orelse return error.NoProblemReported;
    try testing.expectEqualStrings("23505", problem.code);
    try testing.expectEqualStrings("ERROR", problem.severity);
    try testing.expect(std.mem.indexOf(u8, problem.message, "duplicate key") != null);
    try testing.expect(problem.constraint.len != 0);
    try testing.expect(problem.detail.len != 0);
}

test "the schema comparison judges an array by the array it holds" {
    const gpa = testing.allocator;
    var live = (try Live.open(gpa)) orelse return error.SkipZigTest;
    defer live.close(gpa);

    var db = db_mod.Db.init(gpa, "already open", .{});
    db.wire = live.wire;

    try testing.expectEqual(@as(usize, 0), try db.checkSchema(&.{Ticket}));

    // And it is exact rather than widening: an `int4[]` does not read into a
    // `[]const i64`, because the driver picks its element decoder off the
    // array's own OID. Startup is where that has to be said, not the first
    // request to touch the column.
    const Wide = struct {
        pub const nilo_table = .{ .name = list_table, .key = .id };

        id: i64,
        scores: ?[]const i64,
    };

    // Through `compare` rather than `checkSchema`, because the latter's whole
    // job is to log what it found and a logged `err` is a failed test run
    // (`http/test_root.zig`). What is under test is the comparison.
    const arena = live.arena.allocator();
    const actual = try live.wire.columnsOf(arena, dialect.Postgres.introspect, null, list_table);

    var problems: std.ArrayList(schema.Problem) = .empty;
    const found = try schema.compare(dialect.Postgres, Wide, actual, &problems, arena);
    try testing.expectEqual(@as(usize, 1), found);
    try testing.expectEqual(schema.Mismatch.wrong_type, problems.items[0].kind);
}

/// A table whose array columns are given their defaults by the marker rather
/// than by a hand-written `ALTER`
/// ([ADR 181](../docs/adr/181-the-marker-has-two-kinds-of-word.md)).
///
/// **The five elements are the five ways an array literal can be read as more
/// or fewer elements than it holds**: a comma, a brace, a double quote, a
/// backslash and an apostrophe. The comptime half proves nilo writes the text
/// it means to; only Postgres can say whether that text means what nilo
/// thinks, which is why this test exists rather than another `expectEqualStrings`.
const Agent = struct {
    pub const nilo_table = .{
        .name = agent_table,
        .key = .id,
        .default = .{
            .read_tags = &.{},
            .write_capabilities = &.{ "deals", "work" },
            .odd = &.{ "a,b", "{c}", "say \"hi\"", "back\\slash", "it's" },
            .weights = &.{ 1, 2, 3 },
        },
    };

    id: i64,
    read_tags: []const []const u8,
    write_capabilities: []const []const u8,
    odd: []const []const u8,
    weights: []const i32,
};

const agent_table = "nilo_live_agents_" ++ mode_suffix;

test "an array column's default is an array, and the elements survive the round trip" {
    const gpa = testing.allocator;
    var live = (try Live.open(gpa)) orelse return error.SkipZigTest;
    defer live.close(gpa);

    const arena = live.arena.allocator();
    var db = db_mod.Db.init(gpa, "already open", .{});
    db.wire = live.wire;

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    for ([_][]const u8{
        "DROP TABLE IF EXISTS " ++ agent_table,
        // The `CREATE TABLE` the marker produces, defaults and all — not one
        // written for the test, or this would prove nothing.
        comptime @import("ddl.zig").createTable(dialect.Postgres, Agent),
        "INSERT INTO " ++ agent_table ++ " (id) VALUES (1)",
    }) |statement| {
        var rows = try live.wire.run(arena, statement, .{}, null, null);
        live.wire.drain(&rows);
    }
    defer if (live.wire.run(arena, "DROP TABLE IF EXISTS " ++ agent_table, .{}, null, null)) |dropped| {
        var rows = dropped;
        live.wire.drain(&rows);
    } else |_| {};

    // Nothing was inserted into any of the four columns, so what comes back is
    // what the database wrote from the marker's own defaults.
    const agent = (try db.find(Agent, &run, @as(i64, 1))).?;

    try testing.expectEqual(@as(usize, 0), agent.read_tags.len);

    try testing.expectEqual(@as(usize, 2), agent.write_capabilities.len);
    try testing.expectEqualStrings("deals", agent.write_capabilities[0]);
    try testing.expectEqualStrings("work", agent.write_capabilities[1]);

    try testing.expectEqual(@as(usize, 3), agent.weights.len);
    try testing.expectEqualSlices(i32, &.{ 1, 2, 3 }, agent.weights);

    // The one that decides whether the escaping is right: five elements in,
    // five out, each byte for byte what was written in Zig.
    try testing.expectEqual(@as(usize, 5), agent.odd.len);
    try testing.expectEqualStrings("a,b", agent.odd[0]);
    try testing.expectEqualStrings("{c}", agent.odd[1]);
    try testing.expectEqualStrings("say \"hi\"", agent.odd[2]);
    try testing.expectEqualStrings("back\\slash", agent.odd[3]);
    try testing.expectEqualStrings("it's", agent.odd[4]);
}

test "the table nilo creates for an array default is one its own check accepts" {
    const gpa = testing.allocator;
    var live = (try Live.open(gpa)) orelse return error.SkipZigTest;
    defer live.close(gpa);

    const arena = live.arena.allocator();
    var db = db_mod.Db.init(gpa, "already open", .{});
    db.wire = live.wire;

    for ([_][]const u8{
        "DROP TABLE IF EXISTS " ++ agent_table,
        comptime @import("ddl.zig").createTable(dialect.Postgres, Agent),
    }) |statement| {
        var rows = try live.wire.run(arena, statement, .{}, null, null);
        live.wire.drain(&rows);
    }
    defer if (live.wire.run(arena, "DROP TABLE IF EXISTS " ++ agent_table, .{}, null, null)) |dropped| {
        var rows = dropped;
        live.wire.drain(&rows);
    } else |_| {};

    try testing.expectEqual(@as(usize, 0), try db.checkSchema(&.{Agent}));
}

/// The shape `addMissingColumns` is asked about on Postgres: a table that
/// shipped with two columns and a Row that has three more.
const Shipped = struct {
    pub const nilo_table = .{ .name = shipped_table, .key = .id };
    id: i64,
    url: []const u8,
};

const Widened = struct {
    pub const nilo_table = .{
        .name = shipped_table,
        .key = .id,
        .default = .{ .named = false, .tries = 0 },
        .references = .{ .parent_id = .{ @This(), .id } },
        .index = .{.parent_id},
    };
    id: i64,
    url: []const u8,
    sha256: ?[]const u8,
    named: bool,
    tries: i64,
    parent_id: ?i64,
};

const shipped_table = "nilo_live_shipped_" ++ mode_suffix;

/// The three schema-level objects on a real Postgres (ADR 181): a function
/// a trigger calls, a table carrying that trigger, and a view over the
/// table — made by `createMissing` in the order the tool owns.
const touched_table = "nilo_live_touched_" ++ mode_suffix;
const touched_fn = "nilo_live_touch_" ++ mode_suffix;
const touched_view = "nilo_live_touched_names_" ++ mode_suffix;

const Touched = struct {
    pub const nilo_table = .{
        .name = touched_table,
        .key = .id,
        .default = .{ .updated_at = .now },
        .trigger = .{
            .touch = .{ .when = "BEFORE UPDATE", .run = "FOR EACH ROW EXECUTE FUNCTION " ++ touched_fn ++ "()" },
        },
    };
    id: i64,
    name: []const u8,
    updated_at: types.Timestamp,
};

const touched_schema: migrate.Schema = .{
    .extensions = &.{"plpgsql"},
    .functions = &.{.{
        .name = touched_fn,
        .body = "CREATE OR REPLACE FUNCTION " ++ touched_fn ++ "() RETURNS trigger AS $$ " ++
            "BEGIN NEW.updated_at = NEW.updated_at + interval '1 hour'; RETURN NEW; END $$ LANGUAGE plpgsql",
    }},
    .tables = &.{Touched},
    .views = &.{.{ .name = touched_view, .body = "SELECT id, name FROM " ++ touched_table ++ " ORDER BY name" }},
};

test "createMissing on Postgres makes the function before the trigger that calls it, and the view after the table" {
    const gpa = testing.allocator;
    var live = (try Live.open(gpa)) orelse return error.SkipZigTest;
    defer live.close(gpa);

    const arena = live.arena.allocator();
    var db = db_mod.Db.init(gpa, "already open", .{});
    db.wire = live.wire;
    var run: nilo.Run = .init(gpa);
    defer run.deinit();

    // Three statements, because a prepared statement holds one; in the
    // order the dependencies allow.
    const clean = [_][]const u8{
        "DROP VIEW IF EXISTS " ++ touched_view,
        "DROP TABLE IF EXISTS " ++ touched_table,
        "DROP FUNCTION IF EXISTS " ++ touched_fn,
    };
    for (clean) |stmt| {
        var rows = try live.wire.run(arena, stmt, .{}, null, null);
        live.wire.drain(&rows);
    }
    defer for (clean) |stmt| {
        if (live.wire.run(arena, stmt, .{}, null, null)) |dropped| {
            var rows = dropped;
            live.wire.drain(&rows);
        } else |_| {}
    };

    try migrate.createMissing(&db, &run, touched_schema);
    // Twice, which is what a boot does: `CREATE OR REPLACE` on the function
    // and the view, `IF NOT EXISTS` on the extension and the table.
    try migrate.createMissing(&db, &run, touched_schema);

    const b = try db.insert(Touched, &run, .{ .name = "beta" });
    _ = try db.insert(Touched, &run, .{ .name = "alpha" });
    // The trigger ran the function: an update moves `updated_at` an hour on.
    const before = (try db.find(Touched, &run, b.id)).?.updated_at;
    _ = try db.update(Touched, &run, .{ .set = .{ .name = "beta" }, .where = .{ .id = b.id } });
    const after = (try db.find(Touched, &run, b.id)).?.updated_at;
    try testing.expectEqual(before.micros + 3_600_000_000, after.micros);

    const names = try db.raw([]const u8, &run, "SELECT name FROM " ++ touched_view, .{});
    try testing.expectEqual(@as(usize, 2), names.len);
    try testing.expectEqualStrings("alpha", names[0]);
}

test "addMissingColumns widens a Postgres table the way createMissing would have made it" {
    const gpa = testing.allocator;
    var live = (try Live.open(gpa)) orelse return error.SkipZigTest;
    defer live.close(gpa);

    const arena = live.arena.allocator();
    var db = db_mod.Db.init(gpa, "already open", .{});
    db.wire = live.wire;
    var run: nilo.Run = .init(gpa);
    defer run.deinit();

    {
        var rows = try live.wire.run(arena, "DROP TABLE IF EXISTS " ++ shipped_table, .{}, null, null);
        live.wire.drain(&rows);
    }
    defer if (live.wire.run(arena, "DROP TABLE IF EXISTS " ++ shipped_table, .{}, null, null)) |dropped| {
        var rows = dropped;
        live.wire.drain(&rows);
    } else |_| {};

    try migrate.createMissing(&db, &run, .{ .tables = &.{Shipped} });
    _ = try db.insert(Shipped, &run, .{ .url = "http://a/1" });

    // Through `pg_catalog` rather than `pragma_table_info`, which is the
    // half of ADR 123 the SQLite file cannot reach.
    try testing.expectEqual(@as(usize, 4), try migrate.addMissingColumns(&db, &run, .{ .tables = &.{Widened} }));
    try testing.expectEqual(@as(usize, 0), try migrate.addMissingColumns(&db, &run, .{ .tables = &.{Widened} }));

    // The added column's key came with it, and so did its index.
    try testing.expectError(error.ForeignKeyViolated, db.insert(Widened, &run, .{
        .url = "http://a/orphan",
        .sha256 = @as(?[]const u8, null),
        .parent_id = @as(?i64, 999_999),
    }));
    const indexes = try db.raw(
        []const u8,
        &run,
        "SELECT indexname::text FROM pg_indexes WHERE tablename = $1 AND indexname <> $2",
        .{ @as([]const u8, shipped_table), @as([]const u8, shipped_table ++ "_pkey") },
    );
    try testing.expectEqual(@as(usize, 1), indexes.len);

    const rows = try db.select(Widened, &run, .{});
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expect(!rows[0].named);
    try testing.expectEqual(@as(i64, 0), rows[0].tries);
    try testing.expectEqual(@as(?[]const u8, null), rows[0].sha256);
    try testing.expectEqual(@as(usize, 0), try db.checkSchema(&.{Widened}));

    // And a scalar read off the catalogue, the way the SQLite test reads
    // `pragma_table_info` (ADR 125).
    const names = try db.raw(
        []const u8,
        &run,
        "SELECT column_name::text FROM information_schema.columns WHERE table_name = $1 ORDER BY ordinal_position",
        .{@as([]const u8, shipped_table)},
    );
    try testing.expectEqual(@as(usize, 6), names.len);
    try testing.expectEqualStrings("tries", names[4]);
}

// -- the second kind of word, against a database that reads it (ADR 181) --

/// A table whose `CHECK` and whose trigger come out of the marker rather than
/// out of a hand-written step.
///
/// **Only Postgres can say whether the body means what the person meant**,
/// which is the whole point of the kind: nilo writes the text, hashes it and
/// never reads it, so the comptime tests can only prove the text was carried
/// through unchanged. This one proves the database took it, enforced it and
/// ran it.
const Invoice = struct {
    pub const nilo_table = .{
        .name = invoice_table,
        .key = .id,
        .check = .{
            .nilo_live_invoices_amount_is_positive = "amount > 0",
            .nilo_live_invoices_kind_is_known = .{ .words_of = .kind },
        },
        .trigger = .{
            .nilo_live_invoices_touch = .{
                .when = "BEFORE UPDATE",
                .run = "FOR EACH ROW EXECUTE FUNCTION " ++ touch_function ++ "()",
            },
        },
    };

    id: i64,
    amount: i64,
    kind: enum { sale, refund },
    seen: i64,
};

const invoice_table = "nilo_live_invoices_" ++ mode_suffix;
const touch_function = "nilo_live_touch_" ++ mode_suffix;

test "a check out of the marker is enforced by the database, under the name the marker gave it" {
    const gpa = testing.allocator;
    var live = (try Live.open(gpa)) orelse return error.SkipZigTest;
    defer live.close(gpa);

    const arena = live.arena.allocator();
    var db = db_mod.Db.init(gpa, "already open", .{});
    db.wire = live.wire;

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    for ([_][]const u8{
        "DROP TABLE IF EXISTS " ++ invoice_table,
        // The marker's own `CREATE TABLE`, checks and all.
        comptime @import("ddl.zig").createTable(dialect.Postgres, Invoice),
    }) |statement| {
        var rows = try live.wire.run(arena, statement, .{}, null, null);
        live.wire.drain(&rows);
    }
    defer if (live.wire.run(arena, "DROP TABLE IF EXISTS " ++ invoice_table, .{}, null, null)) |dropped| {
        var rows = dropped;
        live.wire.drain(&rows);
    } else |_| {};

    // A row the check allows.
    _ = try db.insert(Invoice, &run, .{
        .id = @as(i64, 1),
        .amount = @as(i64, 10),
        .kind = .sale,
        .seen = @as(i64, 0),
    });

    // And one it does not. The insert comes back as `error.CheckViolated`,
    // which is the database reading the body nilo never read.
    try testing.expectError(error.CheckViolated, db.insert(Invoice, &run, .{
        .id = @as(i64, 2),
        .amount = @as(i64, 0),
        .kind = .sale,
        .seen = @as(i64, 0),
    }));

    // Both constraints are in `pg_constraint` under the names the marker gave
    // them, including the one that renamed an enum column's own check — which
    // is the thing a test reading `pg_constraint` by name needed (item 12).
    //
    // Scoped by `conrelid` rather than by name alone: the Debug and the
    // ReleaseSafe run share a database, their tables differ by suffix and
    // Postgres keeps a constraint name per table, so two rows of one name is
    // the correct answer and not the one under test.
    const Found = struct {
        pub const nilo_table = .{ .name = "pg_constraint", .key = .conname, .managed = false };
        conname: []const u8,
    };
    const found = try db.raw(
        Found,
        &run,
        "SELECT conname FROM pg_constraint WHERE conrelid = $1::regclass ORDER BY conname",
        .{@as([]const u8, invoice_table)},
    );
    var checks: usize = 0;
    for (found) |c| {
        if (std.mem.eql(u8, c.conname, "nilo_live_invoices_kind_is_known")) checks += 1;
        if (std.mem.eql(u8, c.conname, "nilo_live_invoices_amount_is_positive")) checks += 1;
    }
    try testing.expectEqual(@as(usize, 2), checks);
}

test "a trigger out of the marker runs, and nilo wrote the `ON` between its halves" {
    const gpa = testing.allocator;
    var live = (try Live.open(gpa)) orelse return error.SkipZigTest;
    defer live.close(gpa);

    const arena = live.arena.allocator();
    var db = db_mod.Db.init(gpa, "already open", .{});
    db.wire = live.wire;

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    const made = comptime @import("ddl.zig").createdFor(dialect.Postgres, Invoice);
    for ([_][]const u8{
        "DROP TABLE IF EXISTS " ++ invoice_table,
        "CREATE OR REPLACE FUNCTION " ++ touch_function ++ "() RETURNS trigger AS $$ " ++
            "BEGIN NEW.seen := OLD.seen + 1; RETURN NEW; END; $$ LANGUAGE plpgsql",
        comptime @import("ddl.zig").createTable(dialect.Postgres, Invoice),
        made.triggers[0].sql,
        "INSERT INTO " ++ invoice_table ++ " (id, amount, kind, seen) VALUES (1, 10, 'sale', 0)",
    }) |statement| {
        var rows = try live.wire.run(arena, statement, .{}, null, null);
        live.wire.drain(&rows);
    }
    defer if (live.wire.run(arena, "DROP TABLE IF EXISTS " ++ invoice_table, .{}, null, null)) |dropped| {
        var rows = dropped;
        live.wire.drain(&rows);
    } else |_| {};

    _ = try db.update(Invoice, &run, .{
        .where = .{ .id = @as(i64, 1) },
        .set = .{ .amount = @as(i64, 11) },
    });

    // The trigger fired, so the table it hangs on is the one nilo wrote between
    // `.when` and `.run` — the half the marker deliberately cannot say.
    const after = (try db.find(Invoice, &run, @as(i64, 1))).?;
    try testing.expectEqual(@as(i64, 1), after.seen);
}

// -- a table in a schema of its own ---------------------------------------

/// The table this Row names is in `nilo_live_other_<mode>` and nowhere else,
/// so every assertion below fails if the name is quoted as one identifier.
const Widget = struct {
    pub const nilo_table = .{ .name = scoped_table, .key = .id };

    id: i64,
    label: []const u8,
};

test "a qualified table is found, read and written like any other" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    const found = (try stack.db.find(Widget, &run, @as(i64, 1))).?;
    try testing.expectEqualStrings("in another schema", found.label);

    const made = try stack.db.insert(Widget, &run, .{
        .id = @as(i64, 2),
        .label = "written there too",
    });
    try testing.expectEqual(@as(i64, 2), made.id);
    try testing.expectEqual(@as(usize, 2), try stack.db.count(Widget, &run, .{}));

    // Quoted as one identifier every statement above named
    // `"nilo_live_other_<mode>.widgets"` — a relation nobody created — and
    // said so only when it reached Postgres. Reaching Postgres is the whole
    // reason this test is here rather than beside the string assertions.
}

test "the schema check looks in the schema the Row named" {
    const gpa = testing.allocator;
    var live = (try Live.open(gpa)) orelse return error.SkipZigTest;
    defer live.close(gpa);

    var db = db_mod.Db.init(gpa, "already open", .{});
    db.wire = live.wire;

    // `current_schema()` is `public` and `widgets` is not there, so a check
    // that ignored the schema half would report `no_such_table` for a table
    // that exists.
    try testing.expectEqual(@as(usize, 0), try db.checkSchema(&.{Widget}));
}

// -- the null-safe comparison ---------------------------------------------

test "a null-safe comparison finds the null row where = never could" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    // One of the three fixture rows has no handle. This is the shape a
    // handler actually has: a filter that came off a request, where "no
    // handle" is a value the client may send.
    var wanted: ?[]const u8 = null;
    _ = &wanted;

    const nameless = try stack.db.select(Person, &run, .{
        .where = .{ .handle = .{ .not_distinct_from = wanted } },
    });
    try testing.expectEqual(@as(usize, 1), nameless.len);
    try testing.expectEqual(@as(i64, 2), nameless[0].id);

    // The same statement, a value in the optional this time. Nothing about
    // the SQL changed, which is the property that lets the optional in.
    wanted = "ada";
    const ada = try stack.db.select(Person, &run, .{
        .where = .{ .handle = .{ .not_distinct_from = wanted } },
    });
    try testing.expectEqual(@as(usize, 1), ada.len);
    try testing.expectEqual(@as(i64, 1), ada[0].id);

    // And the negation is every row that is not that one — including the
    // null row, which is what `<>` would silently drop.
    wanted = "ada";
    const others = try stack.db.select(Person, &run, .{
        .where = .{ .handle = .{ .distinct_from = wanted } },
        .order = .{ .id = .asc },
    });
    try testing.expectEqual(@as(usize, 2), others.len);
    try testing.expectEqual(@as(i64, 2), others[0].id);
    try testing.expectEqual(@as(i64, 3), others[1].id);
}

test "the ordinary comparison is the one that answers nothing, which is the point" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    // `"handle" = $1` with NULL in `$1` is legal SQL, runs, matches nothing
    // and reports no error. Pinned through `raw` because the module refuses
    // to compile it — this is the failure `distinct_from` exists to replace,
    // kept where somebody can see the difference rather than described.
    const none = try stack.db.raw(
        Person,
        &run,
        "SELECT \"id\", \"email\", \"handle\", \"age\" FROM \"" ++ table ++ "\" WHERE \"handle\" = $1",
        .{@as(?[]const u8, null)},
    );
    try testing.expectEqual(@as(usize, 0), none.len);

    const one = try stack.db.raw(
        Person,
        &run,
        "SELECT \"id\", \"email\", \"handle\", \"age\" FROM \"" ++ table ++
            "\" WHERE \"handle\" IS NOT DISTINCT FROM $1",
        .{@as(?[]const u8, null)},
    );
    try testing.expectEqual(@as(usize, 1), one.len);
}

// -- a batch in one statement ---------------------------------------------

/// One row of a batch. A named struct rather than a literal, because a slice
/// of anonymous literals has no element type for the statement to be compiled
/// from.
const Newcomer = struct {
    id: i64,
    email: []const u8,
    age: i32,
};

test "a batch goes in as one statement and comes back in the order it was sent" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    const before = try stack.db.count(Person, &run, .{});
    const stored = try stack.db.insertMany(Person, &run, &[_]Newcomer{
        .{ .id = 900, .email = "one@batch.dev", .age = 21 },
        .{ .id = 901, .email = "two@batch.dev", .age = 22 },
        .{ .id = 902, .email = "three@batch.dev", .age = 23 },
    });

    try testing.expectEqual(@as(usize, 3), stored.len);
    // `unnest` walks the arrays in step, so the rows come back in the order
    // they were given rather than in whatever order the table ended up in.
    try testing.expectEqual(@as(i64, 900), stored[0].id);
    try testing.expectEqualStrings("two@batch.dev", stored[1].email);
    try testing.expectEqual(@as(i32, 23), stored[2].age);

    try testing.expectEqual(before + 3, try stack.db.count(Person, &run, .{}));
}

test "paging through an order that ties sees every row once" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    // A thousand rows over ten ages. Without the key at the end of the order,
    // Postgres ordered the ties differently at each `OFFSET`, and 179 of these
    // came back twice and 179 never.
    const count = 1000;
    const first: i64 = 10_000;
    var rows: [count]Newcomer = undefined;
    for (&rows, 0..) |*row, i| row.* = .{
        .id = first + @as(i64, @intCast(i)),
        .email = try std.fmt.allocPrint(run.arena(), "tie{d}@page.dev", .{i}),
        .age = @intCast(i % 10),
    };
    _ = try stack.db.insertMany(Person, &run, @as([]const Newcomer, &rows));

    var seen = @as([count]bool, @splat(false));
    var offset: i64 = 0;
    while (offset < count) : (offset += 25) {
        const page = try stack.db.page(Person, &run, .{
            .where = .{ .id = .{ .gte = first } },
            .order = .{ .age = .asc },
            .limit = @as(i64, 25),
            .offset = offset,
        });
        try testing.expectEqual(@as(@TypeOf(page.total), count), page.total);
        for (page.rows) |p| {
            const at: usize = @intCast(p.id - first);
            try testing.expect(!seen[at]);
            seen[at] = true;
        }
    }
    for (seen) |was| try testing.expect(was);
}

test "an empty batch stores nothing and sends nothing" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    const before = try stack.db.count(Person, &run, .{});
    const none: []const Newcomer = &.{};
    const stored = try stack.db.insertMany(Person, &run, none);

    // `unnest` of empty arrays yields no rows, so the answer is known without
    // asking: the call returns it and sends nothing (`db.insertMany`, and
    // `db.zig` has the test that nothing goes down the wire).
    try testing.expectEqual(@as(usize, 0), stored.len);
    try testing.expectEqual(before, try stack.db.count(Person, &run, .{}));
}

test "a batch that violates a constraint takes none of its rows with it" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    const before = try stack.db.count(Person, &run, .{});
    // Row 1's email is Ada's, which is UNIQUE. One statement means one
    // failure: the two good rows beside it are not stored either, which is
    // the property a loop of inserts does not have without a transaction
    // around it.
    try testing.expectError(error.AlreadyExists, stack.db.insertMany(Person, &run, &[_]Newcomer{
        .{ .id = 910, .email = "fine@batch.dev", .age = 21 },
        .{ .id = 911, .email = "ada@example.dev", .age = 22 },
        .{ .id = 912, .email = "also-fine@batch.dev", .age = 23 },
    }));
    try testing.expectEqual(before, try stack.db.count(Person, &run, .{}));
}

test "a batch inside a transaction is undone with the rest of it" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    const before = try stack.db.count(Person, &run, .{});
    {
        var tx = try stack.db.begin(&run, .{});
        defer tx.deinit();
        const stored = try tx.insertMany(Person, &run, &[_]Newcomer{
            .{ .id = 920, .email = "tx-one@batch.dev", .age = 31 },
            .{ .id = 921, .email = "tx-two@batch.dev", .age = 32 },
        });
        try testing.expectEqual(@as(usize, 2), stored.len);
        // and no commit
    }
    try testing.expectEqual(before, try stack.db.count(Person, &run, .{}));
}

/// One row of a batch update: the key it is found by, and what changes.
const Bump = struct {
    id: i64,
    age: i32,
};

test "a batch update changes many rows in one statement" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    const changed = try stack.db.updateMany(Person, &run, &[_]Bump{
        .{ .id = 1, .age = 37 },
        .{ .id = 3, .age = 12 },
    });
    try testing.expectEqual(@as(usize, 2), changed.len);

    // Read back rather than trusting `RETURNING`, and read the row the batch
    // did *not* name too — a join that matched too much would show here.
    try testing.expectEqual(@as(i32, 37), (try stack.db.find(Person, &run, @as(i64, 1))).?.age);
    try testing.expectEqual(@as(i32, 45), (try stack.db.find(Person, &run, @as(i64, 2))).?.age);
    try testing.expectEqual(@as(i32, 12), (try stack.db.find(Person, &run, @as(i64, 3))).?.age);
}

test "a key the table does not have matches nothing, and the answer is shorter" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    // The join is the condition, so a key that is not there is not an error —
    // it simply finds no row. A shorter answer than the batch is how a caller
    // tells, which is why this is the documented way to find out.
    const changed = try stack.db.updateMany(Person, &run, &[_]Bump{
        .{ .id = 1, .age = 38 },
        .{ .id = 999, .age = 1 },
    });
    try testing.expectEqual(@as(usize, 1), changed.len);
    try testing.expectEqual(@as(i64, 1), changed[0].id);
    try testing.expectEqual(@as(usize, 3), try stack.db.count(Person, &run, .{}));
}

test "an empty batch update is a statement that changes nothing" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    const none: []const Bump = &.{};
    const changed = try stack.db.updateMany(Person, &run, none);
    try testing.expectEqual(@as(usize, 0), changed.len);
    try testing.expectEqual(@as(i32, 36), (try stack.db.find(Person, &run, @as(i64, 1))).?.age);
}

test "a batch update inside a transaction is undone with the rest of it" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    {
        var tx = try stack.db.begin(&run, .{});
        defer tx.deinit();
        const changed = try tx.updateMany(Person, &run, &[_]Bump{.{ .id = 1, .age = 99 }});
        try testing.expectEqual(@as(usize, 1), changed.len);
        // and no commit
    }
    try testing.expectEqual(@as(i32, 36), (try stack.db.find(Person, &run, @as(i64, 1))).?.age);
}

/// One row of a batch over the columns Zig has no word for, which is where a
/// batch could quietly go wrong: each of these binds as something other than
/// itself, and an array of them has to bind as an array of that.
const Reading = struct {
    id: i64,
    email: []const u8,
    age: i32,
    seen_at: types.Timestamp,
    token: ?types.Uuid,
    settings: ?types.Json(Theme),
    balance: types.Decimal,
};

/// The Row those columns are read back through. `email` and `age` are here
/// because the table requires both, which is the ordinary reason a Row reads
/// a column it is not about.
const Sample = struct {
    pub const nilo_table = .{ .name = table, .key = .id };

    id: i64,
    email: []const u8,
    age: i32,
    seen_at: types.Timestamp,
    token: ?types.Uuid,
    settings: ?types.Json(Theme),
    balance: types.Decimal,
};

test "a batch carries the column types that bind as something else" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    _ = try stack.db.insertMany(Sample, &run, &[_]Reading{
        .{
            .id = 930,
            .email = "sample-one@batch.dev",
            .age = 40,
            .seen_at = types.Timestamp.fromSeconds(1_786_959_000),
            .token = try types.Uuid.parse("11111111-2222-3333-4444-555555555555"),
            .settings = .{ .value = .{ .theme = "midnight" } },
            .balance = .{ .text = "10.25" },
        },
        .{
            .id = 931,
            .email = "sample-two@batch.dev",
            .age = 41,
            .seen_at = types.Timestamp.fromSeconds(1_787_045_400),
            .token = null,
            .settings = null,
            .balance = .{ .text = "12345678901234567890.123456789" },
        },
    });

    const back = try stack.db.select(Sample, &run, .{
        .where = .{ .id = .{ .gte = @as(i64, 930) } },
        .order = .{ .id = .asc },
    });
    try testing.expectEqual(@as(usize, 2), back.len);
    try testing.expectEqual(@as(i64, 1_786_959_000 * std.time.us_per_s), back[0].seen_at.micros);
    try testing.expectEqualStrings("10.25", back[0].balance.text);
    // A NULL among the values, which is the case an array has and a single
    // `INSERT` does not: one element of the parameter is null rather than the
    // whole parameter.
    try testing.expectEqual(@as(?types.Uuid, null), back[1].token);
    try testing.expectEqual(@as(?types.Json(Theme), null), back[1].settings);
    // The one column a batch pays per row for: the document is written out
    // here rather than handed to the driver as a struct, because pg.zig
    // encodes a `jsonb[]` element from bytes.
    try testing.expectEqualStrings("midnight", back[0].settings.?.value.theme);
    try testing.expectEqualStrings("12345678901234567890.123456789", back[1].balance.text);

    // `.in` and `.not_in` over the same columns, each list element mapped the
    // way a scalar is: the `Timestamp` as its micros, the `Decimal` as digits
    // cast through `text[]`. Before, neither compiled.
    const at = try stack.db.select(Sample, &run, .{
        .where = .{ .seen_at = .{ .in = &[_]types.Timestamp{types.Timestamp.fromSeconds(1_787_045_400)} } },
    });
    try testing.expectEqual(@as(usize, 1), at.len);
    try testing.expectEqual(@as(i64, 931), at[0].id);
    const priced = try stack.db.select(Sample, &run, .{
        .where = .{
            .id = .{ .gte = @as(i64, 930) },
            .balance = .{ .not_in = &[_]types.Decimal{.{ .text = "10.250" }} },
        },
    });
    try testing.expectEqual(@as(usize, 1), priced.len);
    try testing.expectEqual(@as(i64, 931), priced[0].id);
}

/// Numbers in fields of another width than their columns, each a pair the
/// schema check accepts.
const Widths = struct {
    pub const nilo_table = .{ .name = "nilo_live_widths_" ++ mode_suffix, .key = .id };
    id: i64,
    small: u8,
    tiny: i8,
    big: i32,
    half: f64,
    whole: ?f64,
};

test "a number is read out of whichever width its column is, and refused where it does not fit" {
    // pg.zig decodes only the exact type, so an `i32` over `int8` and an
    // `f64` over `float4` passed the schema check and failed every read, and
    // a `u8` or an `i8` did not compile inside the driver.
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    const widths = "nilo_live_widths_" ++ mode_suffix;
    _ = try stack.db.exec(&run, "DROP TABLE IF EXISTS " ++ widths, .{});
    defer _ = stack.db.exec(&run, "DROP TABLE IF EXISTS " ++ widths, .{}) catch {};
    _ = try stack.db.exec(&run, "CREATE TABLE " ++ widths ++ " (id int8 PRIMARY KEY, small int2 NOT NULL, " ++
        "tiny int2 NOT NULL, big int8 NOT NULL, half float4 NOT NULL, whole float8)", .{});

    const made = try stack.db.insert(Widths, &run, .{
        .id = @as(i64, 1),
        .small = @as(u8, 200),
        .tiny = @as(i8, -100),
        .big = @as(i32, 7),
        .half = @as(f64, 1.5),
        .whole = @as(?f64, 2.25),
    });
    try testing.expectEqual(@as(u8, 200), made.small);
    try testing.expectEqual(@as(i8, -100), made.tiny);
    try testing.expectEqual(@as(i32, 7), made.big);
    try testing.expectEqual(@as(f64, 1.5), made.half);
    try testing.expectEqual(@as(?f64, 2.25), made.whole);

    // Past what the field holds: refused, with the column named, rather
    // than truncated.
    _ = try stack.db.exec(&run, "UPDATE " ++ widths ++ " SET big = 5000000000", .{});
    try testing.expectError(error.QueryFailed, stack.db.find(Widths, &run, @as(i64, 1)));
    _ = try stack.db.exec(&run, "UPDATE " ++ widths ++ " SET big = 1, small = -1", .{});
    try testing.expectError(error.QueryFailed, stack.db.find(Widths, &run, @as(i64, 1)));

    // A raw statement's narrower column widens into the field.
    try testing.expectEqual(@as(i64, 5), try stack.db.rawExactlyOne(i64, &run, "SELECT 5::int4", .{}));
    try testing.expectEqual(@as(f64, 0.5), try stack.db.rawExactlyOne(f64, &run, "SELECT 0.5::float4", .{}));
}

/// A child whose key to its parent is checked at the COMMIT.
const Deferred = struct {
    pub const nilo_table = .{ .name = "nilo_live_deferred_" ++ mode_suffix, .key = .id };
    id: i64,
    parent_id: i64,
};

test "a commit a deferred key refuses says which key it was" {
    // A deferred constraint is checked at the COMMIT and nowhere else, and
    // the COMMIT's problem was never recorded: `ForeignKeyViolated` came back
    // with `sql.problem` still null, so nothing could say which key.
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    const child = "nilo_live_deferred_" ++ mode_suffix;
    const parent = "nilo_live_deferred_parent_" ++ mode_suffix;
    _ = try stack.db.exec(&run, "DROP TABLE IF EXISTS " ++ child ++ ", " ++ parent, .{});
    defer _ = stack.db.exec(&run, "DROP TABLE IF EXISTS " ++ child ++ ", " ++ parent, .{}) catch {};
    _ = try stack.db.exec(&run, "CREATE TABLE " ++ parent ++ " (id int8 PRIMARY KEY)", .{});
    _ = try stack.db.exec(&run, "CREATE TABLE " ++ child ++ " (id int8 PRIMARY KEY, parent_id int8 NOT NULL " ++
        "CONSTRAINT deferred_parent_later REFERENCES " ++ parent ++ " (id) DEFERRABLE INITIALLY DEFERRED)", .{});

    var tx = try stack.db.begin(&run, .{});
    defer tx.deinit();
    _ = try tx.insert(Deferred, &run, .{ .id = @as(i64, 1), .parent_id = @as(i64, 404) });
    try testing.expectEqual(@as(?wire_mod.Problem, null), db_mod.lastProblem(&run));
    try testing.expectError(error.ForeignKeyViolated, tx.commit());
    const refusal = db_mod.lastProblem(&run) orelse return error.NoProblemReported;
    try testing.expectEqualStrings("deferred_parent_later", refusal.constraint);
    try testing.expectEqualStrings("23503", refusal.code);
    // A retry is refused too; it used to reach a Wire that was done and succeed.
    try testing.expectError(error.QueryFailed, tx.commit());
}

test "a list condition over a date or bytes binds each element the way one is bound" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    // `::text[]::date[]`, because cast straight to `date[]` pg.zig has no
    // encoder for the OID and sends the elements as `bytea`.
    const born = try stack.db.select(Birthday, &run, .{
        .where = .{ .born = .{ .in = &[_]types.Date{ types.Date.nilo_parse("1815-12-10").?, types.Date.nilo_parse("2015-03-01").? } } },
        .order = .{ .id = .asc },
    });
    try testing.expect(born.len >= 1);
    try testing.expectEqual(@as(i64, 1), born[0].id);

    const digest = [_]u8{ 0xff, 0x00, 0x25 };
    _ = try stack.db.insert(Session, &run, .{
        .id = @as(i64, 1),
        .token_hash = types.Bytes.of(&digest),
        .device = @as(?types.Bytes, null),
    });
    const found = try stack.db.select(Session, &run, .{
        .where = .{ .token_hash = .{ .in = &[_]types.Bytes{ types.Bytes.of(&digest), types.Bytes.of("x") } } },
    });
    try testing.expectEqual(@as(usize, 1), found.len);
}

// -- bytes, written -----------------------------------------------------------

const Session = struct {
    pub const nilo_table = .{
        .name = session_table,
        .key = .id,
        .references = .{ .person_id = .{ Person, .id } },
    };

    id: i64,
    token_hash: types.Bytes,
    device: ?types.Bytes,
    person_id: ?i64,
};

/// One row of a batch of them, with the nullable column null in one row and
/// not the other — the case an array parameter has and a single insert does
/// not.
const NewSession = struct {
    id: i64,
    token_hash: types.Bytes,
    device: ?types.Bytes,
};

test "bytes go out to a bytea through every statement that binds one" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    // A NUL, a byte no UTF-8 decoder accepts, and a `%` — what a text
    // parameter would truncate at, mangle, and mean something else by. The
    // read half was known to be right; every call below used to be
    // `CannotBindStruct` from inside pg.zig before the statement left the
    // process, because the Wire handed the driver a struct it has no encoder
    // for (`postgres.zig`, `opened`).
    const digest = [_]u8{ 0xff, 0x00, 0x25, 0x41, 0xfe, 0x00 };
    const other = [_]u8{ 0x00, 0x01, 0x02 };

    // `db.insert`: the tuple carries a `Bytes` and a null `?Bytes`.
    const made = try stack.db.insert(Session, &run, .{
        .id = @as(i64, 1),
        .token_hash = types.Bytes.of(&digest),
        .device = @as(?types.Bytes, null),
    });
    try testing.expectEqualSlices(u8, &digest, made.token_hash.bytes);
    try testing.expectEqual(@as(?types.Bytes, null), made.device);

    // `.where` on the column, which is the lookup a session store is: the
    // parameter has to arrive as `bytea` for `=` to compare bytes to bytes.
    const found = try stack.db.select(Session, &run, .{
        .where = .{ .token_hash = types.Bytes.of(&digest) },
    });
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqual(@as(i64, 1), found[0].id);
    const none = try stack.db.select(Session, &run, .{
        .where = .{ .token_hash = types.Bytes.of(&other) },
    });
    try testing.expectEqual(@as(usize, 0), none.len);

    // `db.update` with a `?Bytes` that is present, then read back as itself.
    const changed = try stack.db.update(Session, &run, .{
        .set = .{ .device = @as(?types.Bytes, types.Bytes.of(&other)) },
        .where = .{ .id = @as(i64, 1) },
    });
    try testing.expectEqual(@as(usize, 1), changed);
    const after = (try stack.db.find(Session, &run, @as(i64, 1))).?;
    try testing.expectEqualSlices(u8, &other, after.device.?.bytes);

    // `db.raw`, where the caller wrote the cast and the tuple is mapped
    // through the same rule (ADR 116).
    const raw = try stack.db.raw(
        Session,
        &run,
        "SELECT \"id\", \"token_hash\", \"device\", \"person_id\" FROM \"" ++ session_table ++
            "\" WHERE \"token_hash\" = $1::bytea",
        .{types.Bytes.of(&digest)},
    );
    try testing.expectEqual(@as(usize, 1), raw.len);
    try testing.expectEqualSlices(u8, &digest, raw[0].token_hash.bytes);

    // Inside a transaction, which is the other Wire path — `Tx.run` and
    // `Tx.exec` hand the driver their own tuple, one connection held.
    {
        var tx = try stack.db.begin(&run, .{});
        defer tx.deinit();
        _ = try tx.insert(Session, &run, .{
            .id = @as(i64, 2),
            .token_hash = types.Bytes.of(&other),
            .device = @as(?types.Bytes, types.Bytes.of(&digest)),
        });
        const deleted = try tx.delete(Session, &run, .{
            .where = .{ .token_hash = types.Bytes.of(&digest) },
        });
        try testing.expectEqual(@as(usize, 1), deleted);
        try tx.commit();
    }
    try testing.expectEqual(@as(?Session, null), try stack.db.find(Session, &run, @as(i64, 1)));
    const second = (try stack.db.find(Session, &run, @as(i64, 2))).?;
    try testing.expectEqualSlices(u8, &other, second.token_hash.bytes);
    try testing.expectEqualSlices(u8, &digest, second.device.?.bytes);

    // A batch, where the column is one `bytea[]` parameter and each element
    // is the slice inside the caller's row (`ArrayElement`).
    const stored = try stack.db.insertMany(Session, &run, &[_]NewSession{
        .{ .id = 3, .token_hash = types.Bytes.of(&digest), .device = types.Bytes.of(&other) },
        .{ .id = 4, .token_hash = types.Bytes.of(&other), .device = null },
    });
    try testing.expectEqual(@as(usize, 2), stored.len);
    try testing.expectEqualSlices(u8, &digest, stored[0].token_hash.bytes);
    try testing.expectEqualSlices(u8, &other, stored[0].device.?.bytes);
    try testing.expectEqual(@as(?types.Bytes, null), stored[1].device);
    try testing.expectEqual(@as(usize, 3), try stack.db.count(Session, &run, .{}));

    // And `db.delete` outside a transaction, matched by the bytes.
    const gone = try stack.db.delete(Session, &run, .{
        .where = .{ .token_hash = types.Bytes.of(&other) },
    });
    try testing.expectEqual(@as(usize, 2), gone);
}

// -- a filter that is absent, against a database that types its parameters --

/// The four column types a guard has to work over, on one Row: text, a
/// number, a `timestamptz`, a `uuid` and an enum. Every one is the shape a
/// list screen filters on.
const Filtered = struct {
    pub const nilo_table = .{ .name = table, .key = .id };

    id: i64,
    email: []const u8,
    age: i32,
    seen_at: types.Timestamp,
    token: ?types.Uuid,
    role: Role,

    const Role = enum { admin, member, moderator };
};

test "a filter that is absent runs on Postgres in every shape a guard takes" {
    // ADR 149's guard was `($1 IS NULL OR "name" = $1)`, and every comptime
    // test asserted that string and passed. pg.zig sends a `Parse` with no
    // parameter types, so Postgres works each one out from its first use —
    // and `$1 IS NULL` is a null test on an unknown, which is `could not
    // determine data type of parameter $1` (42P08) from the database on the
    // first request. The port whose list endpoint was the ADR's own example
    // found it; `where.guarded` writes the term first now. This is the test
    // that would have caught it: one of each guard shape, set and unset,
    // against the real thing.
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    const given = @import("where.zig").given;

    // `=` on text, unset and set.
    try testing.expectEqual(@as(usize, 3), try stack.db.count(Filtered, &run, .{
        .where = .{ .email = given(@as(?[]const u8, null)) },
    }));
    try testing.expectEqual(@as(usize, 1), try stack.db.count(Filtered, &run, .{
        .where = .{ .email = given(@as(?[]const u8, "ada@example.dev")) },
    }));

    // An operator on a number.
    try testing.expectEqual(@as(usize, 2), try stack.db.count(Filtered, &run, .{
        .where = .{ .age = .{ .gte = given(@as(?i32, 18)) } },
    }));
    try testing.expectEqual(@as(usize, 3), try stack.db.count(Filtered, &run, .{
        .where = .{ .age = .{ .gte = given(@as(?i32, null)) } },
    }));

    // A pattern, whose parameter is inside three `replace` calls before it
    // reaches `ILIKE` — the deepest first use a guard has.
    try testing.expectEqual(@as(usize, 3), try stack.db.count(Filtered, &run, .{
        .where = .{ .email = .{ .icontains = given(@as(?[]const u8, "EXAMPLE")) } },
    }));
    try testing.expectEqual(@as(usize, 1), try stack.db.count(Filtered, &run, .{
        .where = .{ .email = .{ .icontains = given(@as(?[]const u8, "grace")) } },
    }));

    // A `timestamptz`, a `uuid` and an enum: the three where a cast on the
    // guard would have needed a type name this module does not always have
    // (`accepts` declines to name an enum), and the term-first order needs
    // nothing.
    try testing.expectEqual(@as(usize, 3), try stack.db.count(Filtered, &run, .{
        .where = .{ .seen_at = .{ .gt = given(@as(?types.Timestamp, types.Timestamp.fromSeconds(0))) } },
    }));
    try testing.expectEqual(@as(usize, 1), try stack.db.count(Filtered, &run, .{
        .where = .{ .token = given(@as(?types.Uuid, try types.Uuid.parse("550e8400-e29b-41d4-a716-446655440000"))) },
    }));
    try testing.expectEqual(@as(usize, 1), try stack.db.count(Filtered, &run, .{
        .where = .{ .role = given(@as(?Filtered.Role, .admin)) },
    }));
    try testing.expectEqual(@as(usize, 3), try stack.db.count(Filtered, &run, .{
        .where = .{ .role = given(@as(?Filtered.Role, null)) },
    }));

    // The guard around a whole `EXISTS`, which is the port's list endpoint:
    // a session for person 1 and none for the others.
    _ = try stack.db.insert(Session, &run, .{
        .id = @as(i64, 10),
        .token_hash = types.Bytes.of("t"),
        .device = @as(?types.Bytes, null),
        .person_id = @as(?i64, 1),
    });
    const with_session = try stack.db.page(Filtered, &run, .{
        .where = .{
            .email = .{ .icontains = given(@as(?[]const u8, null)) },
            .exists = .{
                .{ .in = Session, .where = .{ .id = given(@as(?i64, 10)) } },
            },
        },
        .order = .{ .id = .asc },
        .limit = 20,
    });
    try testing.expectEqual(@as(i64, 1), with_session.total);
    try testing.expectEqual(@as(i64, 1), with_session.rows[0].id);
    const everyone = try stack.db.page(Filtered, &run, .{
        .where = .{
            .email = .{ .icontains = given(@as(?[]const u8, null)) },
            .exists = .{
                .{ .in = Session, .where = .{ .id = given(@as(?i64, null)) } },
            },
        },
        .order = .{ .id = .asc },
        .limit = 20,
    });
    try testing.expectEqual(@as(i64, 3), everyone.total);
    try testing.expectEqual(@as(usize, 3), everyone.rows.len);
}

test "a search over several columns is one statement on Postgres, with the box empty and with it filled" {
    // Item 72: the fourth most common WHERE a list screen has is
    // `(q IS NULL OR code ILIKE q OR name ILIKE q OR …)` beside a handful of
    // guarded filters, and on nilo it was two `db.select` calls with the
    // filters written twice (ADR 172). One parameter named on every column;
    // Postgres is what says the shared placeholder types once and reads
    // three times.
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    const given = @import("where.zig").given;

    // `handle` is nullable and `email` is not; both are text, which is what
    // the parameter binds as.
    const Search = struct {
        q: ?[]const u8,
        least_age: ?i32,
        fn count(db: *db_mod.Db, scope: *nilo.Run, self: @This()) !usize {
            return db.count(Person, scope, .{ .where = .{
                .age = .{ .gte = given(self.least_age) },
                .across = .{ .columns = .{ .email, .handle }, .icontains = given(self.q) },
            } });
        }
    };

    // The box empty: every row the other filter allows.
    try testing.expectEqual(@as(usize, 3), try Search.count(&stack.db, &run, .{ .q = null, .least_age = null }));
    try testing.expectEqual(@as(usize, 2), try Search.count(&stack.db, &run, .{ .q = null, .least_age = 18 }));
    // Filled: matched on either column, and a NULL handle is no match rather
    // than an error.
    try testing.expectEqual(@as(usize, 1), try Search.count(&stack.db, &run, .{ .q = "KID", .least_age = null }));
    try testing.expectEqual(@as(usize, 1), try Search.count(&stack.db, &run, .{ .q = "grace", .least_age = null }));
    try testing.expectEqual(@as(usize, 3), try Search.count(&stack.db, &run, .{ .q = "a", .least_age = null }));
    try testing.expectEqual(@as(usize, 0), try Search.count(&stack.db, &run, .{ .q = "kid", .least_age = 18 }));

    // And the rows themselves, on a page, with the same condition.
    const found = try stack.db.page(Person, &run, .{
        .where = .{
            .age = .{ .gte = given(@as(?i32, null)) },
            .across = .{ .columns = .{ .email, .handle }, .icontains = given(@as(?[]const u8, "ada")) },
        },
        .order = .{ .id = .asc },
        .limit = 20,
    });
    try testing.expectEqual(@as(i64, 1), found.total);
    try testing.expectEqualStrings("ada@example.dev", found.rows[0].email);
}

test "ieq finds an address whatever its case, and reads an underscore as itself" {
    // Item 84: `lower("email") = lower($1)` is the lookup a unique that
    // ignores case is an index for; `.ilike` would have read the `_` in an
    // address as any one character.
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    const found = (try stack.db.one(Person, &run, .{
        .where = .{ .email = .{ .ieq = @as([]const u8, "ADA@Example.DEV") } },
    })).?;
    try testing.expectEqual(@as(i64, 1), found.id);
    try testing.expectEqual(@as(usize, 0), try stack.db.count(Person, &run, .{
        .where = .{ .email = .{ .ieq = @as([]const u8, "ad_@example.dev") } },
    }));
    try testing.expectEqual(@as(usize, 2), try stack.db.count(Person, &run, .{
        .where = .{ .email = .{ .not_ieq = @as([]const u8, "Ada@Example.Dev") } },
    }));
}

test "a list that may be absent drops its term on Postgres, and an empty one does not" {
    // Item 81: the multi-select on a filter bar. Postgres types `$1` from
    // `= ANY($1)` before the guard reads it, which is the order ADR 149
    // settled for one value, and the same has to hold for an array.
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    const given = where_mod.given;
    const Ids = struct {
        fn count(db: *db_mod.Db, scope: *nilo.Run, in: ?[]const i64, not_in: ?[]const i64) !usize {
            return db.count(Person, scope, .{ .where = .{
                .id = .{ .in = given(in), .not_in = given(not_in) },
            } });
        }
    };
    const one_three = [_]i64{ 1, 3 };
    const one = [_]i64{1};
    try testing.expectEqual(@as(usize, 3), try Ids.count(&stack.db, &run, null, null));
    try testing.expectEqual(@as(usize, 2), try Ids.count(&stack.db, &run, &one_three, null));
    try testing.expectEqual(@as(usize, 0), try Ids.count(&stack.db, &run, &.{}, null));
    try testing.expectEqual(@as(usize, 2), try Ids.count(&stack.db, &run, null, &one));
    try testing.expectEqual(@as(usize, 3), try Ids.count(&stack.db, &run, null, &.{}));
    try testing.expectEqual(@as(usize, 1), try Ids.count(&stack.db, &run, &one_three, &one));

    // Text and a uuid, the two element types that bind as something other
    // than themselves.
    const emails = [_][]const u8{ "ada@example.dev", "grace@example.dev" };
    try testing.expectEqual(@as(usize, 2), try stack.db.count(Filtered, &run, .{
        .where = .{ .email = .{ .in = given(@as(?[]const []const u8, &emails)) } },
    }));
    const tokens = [_]types.Uuid{try types.Uuid.parse("550e8400-e29b-41d4-a716-446655440001")};
    try testing.expectEqual(@as(usize, 1), try stack.db.count(Filtered, &run, .{
        .where = .{ .token = .{ .in = given(@as(?[]const types.Uuid, &tokens)) } },
    }));
    try testing.expectEqual(@as(usize, 3), try stack.db.count(Filtered, &run, .{
        .where = .{ .token = .{ .in = given(@as(?[]const types.Uuid, null)) } },
    }));
}

test "today is the database's date, written and compared without a parameter" {
    // Item 91: the start-date stamp, whose `WHERE` compares the column to
    // the same day the `SET` writes.
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    // Grace's is NULL and Kid's is in 2015, so only Grace is stamped.
    const stamped = try stack.db.update(Birthday, &run, .{
        .set = .{ .born = .today },
        .where = .{
            .id = .{ .in = @as([]const i64, &.{ 2, 3 }) },
            .any = .{ .{ .born = null }, .{ .born = .{ .gt = .today } } },
        },
    });
    try testing.expectEqual(@as(usize, 1), stamped);
    try testing.expectEqual(@as(usize, 1), try stack.db.count(Birthday, &run, .{ .where = .{ .born = .today } }));
    try testing.expectEqual(@as(usize, 2), try stack.db.count(Birthday, &run, .{ .where = .{ .born = .{ .lt = .today } } }));

    // And `.now` compares the way it is written.
    try testing.expectEqual(@as(usize, 3), try stack.db.count(Profile, &run, .{ .where = .{ .seen_at = .{ .lt = .now } } }));

    // Item 105: the clock moved by an offset, in a statement's `.where` and
    // in an aggregate's, which is where "closed in the last 90 days" is
    // counted. Grace's day is today and the other two are years back.
    try testing.expectEqual(@as(usize, 1), try stack.db.count(Birthday, &run, .{ .where = .{ .born = .{ .gte = .{ .today = -90 } } } }));
    try testing.expectEqual(@as(usize, 2), try stack.db.count(Birthday, &run, .{ .where = .{ .born = .{ .lt = .{ .today = -90 } } } }));
    try testing.expectEqual(@as(usize, 0), try stack.db.count(Birthday, &run, .{ .where = .{ .born = .{ .today = 1 } } }));
    try testing.expectEqual(@as(usize, 3), try stack.db.count(Profile, &run, .{ .where = .{ .seen_at = .{ .lt = .{ .now = .{ .days = 1 } } } } }));
    try testing.expectEqual(@as(usize, 0), try stack.db.count(Profile, &run, .{ .where = .{ .seen_at = .{ .gt = .{ .now = .{ .seconds = 60 } } } } }));
    const Recent = struct {
        pub const nilo_table = Birthday;
        pub const nilo_aggregate = .{
            .recent = .{ .count = .id, .where = .{ .born = .{ .gte = .{ .today = -90 } } } },
            .stamped = .{ .count = .id, .where = .{ .born = .today } },
        };
        recent: i64,
        stamped: i64,
    };
    const recent = try stack.db.exactlyOne(Recent, &run, .{});
    try testing.expectEqual(@as(i64, 1), recent.recent);
    try testing.expectEqual(@as(i64, 1), recent.stamped);

    // Item 99: the same two words on columns read as text, which is how a
    // date crosses an API as `yyyy-MM-dd`. The database writes the value
    // either way.
    const Stamped = struct {
        pub const nilo_table = .{ .name = table, .key = .id };
        id: i64,
        born: ?types.AsText("date"),
        seen_at: types.AsText("timestamptz"),
    };
    try testing.expectEqual(@as(usize, 1), try stack.db.count(Stamped, &run, .{ .where = .{ .born = .today } }));
    try testing.expectEqual(@as(usize, 1), try stack.db.update(Stamped, &run, .{
        .set = .{ .born = .today, .seen_at = .now },
        .where = .{ .id = @as(i64, 1), .born = .{ .lt = .today } },
    }));
    try testing.expectEqual(@as(usize, 2), try stack.db.count(Stamped, &run, .{ .where = .{ .born = .today, .seen_at = .{ .lte = .now } } }));
}

test "a paged raw statement takes the request's order and still carries its total" {
    // Item 82: `/work`, `/commitments` and `/deals` were `rawOrdered` and a
    // second statement for the count with the `WHERE` pasted in again.
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    const Paged = struct {
        pub const nilo_table = .projection;
        id: i64,
        email: []const u8,
    };
    const Sort = @import("ordering.zig").Ordering(Paged, .{ .id = .id, .age = "p.age" });
    const text = "SELECT p.id, p.email, count(*) OVER () FROM " ++ table ++
        " p WHERE p.age > $1 {order} LIMIT $2";

    const oldest = try stack.db.rawPageOrdered(Paged, &run, text, .{ @as(i32, 10), @as(i64, 2) }, Sort.by(&.{.{ .key = .age, .direction = .desc }}));
    try testing.expectEqual(@as(i64, 3), oldest.total);
    try testing.expectEqual(@as(usize, 2), oldest.rows.len);
    try testing.expectEqualStrings("grace@example.dev", oldest.rows[0].email);
    try testing.expectEqualStrings("ada@example.dev", oldest.rows[1].email);

    // Item 97: past the last row the window has no row to ride on, and the
    // same statement asked again from row one says the total. The port's
    // shape, a cast on each bound.
    const skipping = "SELECT p.id, p.email, count(*) OVER () FROM " ++ table ++
        " p WHERE p.age > $1 {order} LIMIT $2::int OFFSET $3::int";
    const past = try stack.db.rawPageOrdered(Paged, &run, skipping, .{ @as(i32, 10), @as(i32, 2), @as(i32, 200) }, Sort.by(&.{.{ .key = .id }}));
    try testing.expectEqual(@as(usize, 0), past.rows.len);
    try testing.expectEqual(@as(i64, 3), past.total);
    const typed_past = try stack.db.page(Person, &run, .{ .order = .{ .id = .asc }, .limit = 2, .offset = @as(i64, 200) });
    try testing.expectEqual(@as(usize, 0), typed_past.rows.len);
    try testing.expectEqual(@as(i64, 3), typed_past.total);

    // Item 98: the plan of the same statement, sorted as a request sorted it.
    const plan = try stack.db.rawExplainOrdered(&run, skipping, .{ @as(i32, 10), @as(i32, 2), @as(i32, 0) }, Sort.by(&.{.{ .key = .age }}));
    try testing.expect(std.mem.indexOf(u8, plan, "WindowAgg") != null);
    try testing.expect(std.mem.indexOf(u8, plan, "Execution Time:") != null);

    // A write's plan is asked inside a transaction that is rolled back, so
    // `ANALYZE` running it keeps nothing.
    const write_plan = try stack.db.rawExplain(&run, "UPDATE " ++ table ++ " SET age = age + $1", .{@as(i32, 100)});
    try testing.expect(std.mem.indexOf(u8, write_plan, "Update on") != null);
    try testing.expectEqual(@as(usize, 0), try stack.db.count(Person, &run, .{ .where = .{ .age = .{ .gt = @as(i32, 100) } } }));
}

test "a narrower Row sorts by a column of its table it does not carry" {
    // Item 86: the tiebreak the response has no reason to show.
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    const Email = struct {
        pub const nilo_table = Person;
        id: i64,
        email: []const u8,
    };
    const by_age = try stack.db.select(Email, &run, .{ .order = .{ .age = .desc } });
    try testing.expectEqual(@as(usize, 3), by_age.len);
    try testing.expectEqual(@as(i64, 2), by_age[0].id);
    try testing.expectEqual(@as(i64, 1), by_age[1].id);
    try testing.expectEqual(@as(i64, 3), by_age[2].id);

    // Item 96: and narrowed by one, bound as the table's `int4`.
    const grown = try stack.db.select(Email, &run, .{ .where = .{ .age = .{ .gte = @as(i32, 18) } }, .order = .{ .id = .asc } });
    try testing.expectEqual(@as(usize, 2), grown.len);
    try testing.expectEqualStrings("grace@example.dev", grown[1].email);
    const found = (try stack.db.one(Email, &run, .{ .where = .{ .handle = "kid" } })).?;
    try testing.expectEqual(@as(i64, 3), found.id);
}

test "an exists from the child's side reads the parent's key off the child's own reference" {
    // Item 75: `staff WHERE EXISTS (departments WHERE …)`, where the key is on
    // the outer Row. Here the session points at the person, and the query is
    // over sessions asking about the person (ADR 175).
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    const given = @import("where.zig").given;

    inline for (.{
        .{ 10, @as(?i64, 1) },
        .{ 11, @as(?i64, 2) },
        .{ 12, @as(?i64, null) },
    }) |row| {
        _ = try stack.db.insert(Session, &run, .{
            .id = @as(i64, row[0]),
            .token_hash = types.Bytes.of("t"),
            .device = @as(?types.Bytes, null),
            .person_id = row[1],
        });
    }

    // The session whose person is grace, and the two that are not — the
    // one with no person at all is one of them, which is what NOT EXISTS
    // over a nullable key means.
    try testing.expectEqual(@as(usize, 1), try stack.db.count(Session, &run, .{ .where = .{
        .exists = .{.{ .in = Person, .where = .{ .email = .{ .icontains = @as([]const u8, "grace") } } }},
    } }));
    try testing.expectEqual(@as(usize, 2), try stack.db.count(Session, &run, .{ .where = .{
        .not_exists = .{.{ .in = Person, .where = .{ .email = .{ .icontains = @as([]const u8, "grace") } } }},
    } }));
    // And the guard drops the whole subquery, the way it does from the other
    // side: every session, the orphan included.
    try testing.expectEqual(@as(usize, 3), try stack.db.count(Session, &run, .{ .where = .{
        .exists = .{.{ .in = Person, .where = .{ .email = .{ .icontains = given(@as(?[]const u8, null)) } } }},
    } }));
    try testing.expectEqual(@as(usize, 1), try stack.db.count(Session, &run, .{ .where = .{
        .exists = .{.{ .in = Person, .where = .{ .email = .{ .icontains = given(@as(?[]const u8, "ada")) } } }},
    } }));
}

test "a raw statement is held against its Row the first time it runs" {
    // Item 94: `rawcheck` counts and names the columns while compiling, and
    // the rest was left to the first row. The port's feed page went down on a
    // `LEFT JOIN LATERAL` read into a field that was not optional (ADR 233).
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    const Pair = struct {
        pub const nilo_table = .projection;
        id: i64,
        other: i64,
    };
    const MaybePair = struct {
        pub const nilo_table = .projection;
        id: i64,
        other: ?i64,
    };

    // A LEFT JOIN that finds a row every time, so reading it would work: the
    // statement is refused by the check and by nothing else, before a row is
    // read. Into an optional, the same statement fits and runs.
    const always = "SELECT p.id, q.id AS other FROM " ++ table ++ " p LEFT JOIN " ++ table ++
        " q ON q.id = p.id ORDER BY p.id";
    try testing.expectError(error.QueryFailed, stack.db.raw(Pair, &run, always, .{}));
    try testing.expectEqual(@as(usize, 3), (try stack.db.raw(MaybePair, &run, always, .{})).len);

    // What the Wire says about each shape, read directly.
    const w = &stack.db.wire.?;
    const arena = run.arena();
    const people = " FROM " ++ table ++ " p LEFT JOIN " ++ session_table ++ " s ON s.person_id = p.id";

    const left = (try w.describe(arena, "SELECT p.id, s.id, coalesce(s.id, 0)" ++ people, true)).?;
    try testing.expectEqual(false, left[0].outer_null);
    try testing.expectEqual(true, left[1].outer_null);
    // An expression is not judged, and `coalesce` is one.
    try testing.expectEqual(false, left[2].outer_null);
    try testing.expectEqualStrings("int8", left[1].udt.?);

    // A condition that throws the NULLs away, which the planner reads as an
    // inner join.
    const kept = (try w.describe(arena, "SELECT p.id, s.id" ++ people ++ " WHERE s.id > $1", true)).?;
    try testing.expectEqual(false, kept[1].outer_null);
    // `($1 IS NULL OR …)` does not throw them away, which is why the plan is
    // the generic one: one made for a value might have dropped the join.
    const guarded = (try w.describe(arena, "SELECT p.id, s.id" ++ people ++
        " WHERE ($1::bigint IS NULL OR s.id = $1)", true)).?;
    try testing.expectEqual(true, guarded[1].outer_null);

    // The port's shape.
    const lateral = (try w.describe(arena, "SELECT p.id, t.id FROM " ++ table ++
        " p LEFT JOIN LATERAL (SELECT s.id FROM " ++ session_table ++
        " s WHERE s.person_id = p.id ORDER BY s.id DESC LIMIT 1) t ON true", true)).?;
    try testing.expectEqual(false, lateral[0].outer_null);
    try testing.expectEqual(true, lateral[1].outer_null);

    // A branch of a UNION ALL, whose column the first branch names.
    const branch = (try w.describe(arena, "SELECT p.id, p.id FROM " ++ table ++
        " p UNION ALL SELECT p.id, s.id" ++ people, true)).?;
    try testing.expectEqual(false, branch[0].outer_null);
    try testing.expectEqual(true, branch[1].outer_null);

    // And types: `count(*)` is `int8`, which pg.zig will not decode into an
    // `i32` though `checkSchema` lets an `i32` stand over an `int8` column;
    // an enum arrives as its label, which a text field reads whatever the
    // type is called.
    const typed = (try w.describe(arena, "SELECT count(*), count(*)::int4, 'admin'::" ++ role_type ++
        " FROM " ++ table, false)).?;
    try testing.expectEqualStrings("int8", typed[0].udt.?);
    try testing.expectEqualStrings("int4", typed[1].udt.?);
    try testing.expectEqualStrings(role_type, typed[2].udt.?);
    try testing.expect(typed[2].textual);
    try testing.expectError(error.QueryFailed, stack.db.rawExactlyOne(i32, &run, "SELECT count(*) FROM " ++ table, .{}));
    try testing.expectEqual(@as(i32, 3), try stack.db.rawExactlyOne(i32, &run, "SELECT count(*)::int4 FROM " ++ table, .{}));
    const Named = struct {
        pub const nilo_table = .projection;
        role: []const u8,
    };
    _ = try stack.db.raw(Named, &run, "SELECT 'admin'::" ++ role_type ++ " AS role", .{});

    // Every describe above prepared the same name on one of the pool's
    // connections, so one left behind would have refused the next; and the
    // connection this lands on holds none.
    const left_over = try stack.db.rawExactlyOne(i64, &run, "SELECT count(*) FROM pg_prepared_statements WHERE name = 'nilo_describe'", .{});
    try testing.expectEqual(@as(i64, 0), left_over);
}

test "a raw statement whose first run found no table is held against its Row once the table is there" {
    // The check's flag used to be spent before `describe` answered, so a
    // first run that met a table a migration had not made yet left the
    // statement unchecked for the life of the process.
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    const late = "nilo_live_late_" ++ mode_suffix;
    _ = try stack.db.exec(&run, "DROP TABLE IF EXISTS " ++ late, .{});
    defer _ = stack.db.exec(&run, "DROP TABLE IF EXISTS " ++ late, .{}) catch {};

    const Pair = struct {
        pub const nilo_table = .projection;
        id: i64,
        other: i64,
    };
    const joined = "SELECT p.id, q.id AS other FROM " ++ late ++ " p LEFT JOIN " ++ late ++
        " q ON q.id = p.id ORDER BY p.id";

    // No table: the statement fails, and so did the describe beside it.
    try testing.expectError(error.QueryFailed, stack.db.raw(Pair, &run, joined, .{}));

    _ = try stack.db.exec(&run, "CREATE TABLE " ++ late ++ " (id int8 PRIMARY KEY)", .{});
    _ = try stack.db.exec(&run, "INSERT INTO " ++ late ++ " VALUES (1)", .{});
    // Every row would read, since the join always finds one; the refusal is
    // the check's, asked again because the first one had no answer.
    try testing.expectError(error.QueryFailed, stack.db.raw(Pair, &run, joined, .{}));
}

/// A person carrying the ids of their sessions — which no column holds, and
/// the handler fills after the read (ADR 178).
const Carried = struct {
    pub const nilo_table = Person;
    pub const nilo_beside = .{.sessions};

    id: i64,
    email: []const u8,
    sessions: []const i64 = &.{},
};

/// The timeline shape: a projection over a `UNION ALL`, carrying a field the
/// statement does not select (item 78).
const TimelineLine = struct {
    pub const nilo_table = .projection;
    pub const nilo_beside = .{.attachments};

    kind: []const u8,
    who: i64,
    attachments: []const []const u8 = &.{},
};

test "a field beside the columns is left for the caller, by select, by raw and by a stream" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    _ = try stack.db.insert(Session, &run, .{
        .id = @as(i64, 10),
        .token_hash = types.Bytes.of("t"),
        .device = @as(?types.Bytes, null),
        .person_id = @as(?i64, 1),
    });

    // `select` writes a SELECT list of the columns and leaves the rest at
    // its default; the caller fills it from a second read, which is the
    // shape a page's line has.
    const people = try stack.db.select(Carried, &run, .{ .order = .{ .id = .asc } });
    try testing.expectEqual(@as(usize, 3), people.len);
    for (people) |*p| {
        try testing.expectEqual(@as(usize, 0), p.sessions.len);
        const theirs = try stack.db.select(Session, &run, .{ .where = .{ .person_id = p.id } });
        const ids = try run.arena().alloc(i64, theirs.len);
        for (theirs, 0..) |t, i| ids[i] = t.id;
        p.sessions = ids;
    }
    try testing.expectEqual(@as(usize, 1), people[0].sessions.len);
    try testing.expectEqual(@as(i64, 10), people[0].sessions[0]);
    try testing.expectEqual(@as(usize, 0), people[1].sessions.len);

    // `raw` counts the statement's columns against the Row's *columns*, so a
    // two-column list fills a three-field projection.
    const lines = try stack.db.raw(
        TimelineLine,
        &run,
        "SELECT 'person'::text AS kind, id AS who FROM \"" ++ table ++ "\"" ++
            " UNION ALL SELECT 'session', person_id FROM " ++ session_table ++
            " ORDER BY 2, 1",
        .{},
    );
    try testing.expectEqual(@as(usize, 4), lines.len);
    try testing.expectEqualStrings("person", lines[0].kind);
    try testing.expectEqualStrings("session", lines[1].kind);
    try testing.expectEqual(@as(usize, 0), lines[1].attachments.len);

    // A streamed row keeps the field at its own type and its default.
    var rows = try stack.db.stream(Carried, &run, .{ .order = .{ .id = .asc } });
    defer rows.close();
    var seen: usize = 0;
    while (try rows.next()) |p| : (seen += 1) {
        try testing.expectEqual(@as(usize, 0), p.sessions.len);
    }
    try testing.expectEqual(@as(usize, 3), seen);

    // And the schema check does not go looking for the column.
    try testing.expectEqual(@as(usize, 0), try stack.db.checkSchema(&.{Carried}));
}

comptime {
    _ = wire_mod;
}

// -- prepared statements ---------------------------------------------------

test "statements interleaved on one connection keep their own prepared plans" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    // Four shapes with three different parameter counts, sent round and
    // round down the same connection. The failure this is here for is not
    // hypothetical: reusing one cache name for two statements is what
    // `bench/sql.zig` did by accident, and Postgres answered the *second*
    // statement's parameters against the *first* statement's describe. Two
    // statements with the same arity would not have said anything at all
    // (ADR 051), which is why the round trip below asserts the answers
    // rather than only that nothing errored.
    var round: usize = 0;
    while (round < 8) : (round += 1) {
        const ada = try stack.db.find(Person, &run, @as(i64, 1));
        try testing.expectEqualStrings("ada@example.dev", ada.?.email);

        const grown = try stack.db.select(Person, &run, .{
            .where = .{ .age = .{ .gt = 18 } },
            .order = .{ .id = .asc },
        });
        try testing.expectEqual(@as(usize, 2), grown.len);

        try testing.expectEqual(@as(usize, 3), try stack.db.count(Person, &run, .{}));
        try testing.expect(try stack.db.exists(Person, &run, .{ .where = .{ .id = @as(i64, 2) } }));

        run.reset();
    }
}

/// A table of its own, whose one column a test changes the type of under a
/// running pool — the thing a migration does to a server still up.
const stale_table = "nilo_live_stale_" ++ mode_suffix;

const Labelled = struct {
    pub const nilo_table = .{ .name = stale_table, .key = .id };
    id: i64,
    label: []const u8,
};

test "a plan a migration changed the answer of is prepared again, and inside a transaction answers RolledBack" {
    const gpa = testing.allocator;
    const url = live_config.database_url orelse return error.SkipZigTest;

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    // One connection, so the plan kept by the first read is the one every
    // read after it meets.
    var db = db_mod.Db.init(gpa, url, .{ .size = 1, .connect_on_init = 1, .unchecked = true });
    defer db.deinit();
    try db.nilo_start(threaded.io(), .off);
    defer db.nilo_stop();

    var run: core.Run = .init(gpa);
    defer run.deinit();

    _ = try db.exec(&run, "DROP TABLE IF EXISTS \"" ++ stale_table ++ "\"", .{});
    _ = try db.exec(&run, "CREATE TABLE \"" ++ stale_table ++ "\" (id int8 PRIMARY KEY, label text NOT NULL)", .{});
    defer _ = db.exec(&run, "DROP TABLE IF EXISTS \"" ++ stale_table ++ "\"", .{}) catch {};
    _ = try db.exec(&run, "INSERT INTO \"" ++ stale_table ++ "\" VALUES (1, 'one')", .{});

    // Prepared and kept.
    try testing.expectEqualStrings("one", (try db.find(Labelled, &run, @as(i64, 1))).?.label);

    // The migration. `text` to `varchar` changes the type the plan answers
    // with, and Postgres refuses the kept plan from here on with `0A000`.
    _ = try db.exec(&run, "ALTER TABLE \"" ++ stale_table ++ "\" ALTER COLUMN label TYPE varchar(40)", .{});

    // Outside a transaction nothing was done before the statement, so it is
    // deallocated and sent once more — the caller sees the row.
    try testing.expectEqualStrings("one", (try db.find(Labelled, &run, @as(i64, 1))).?.label);
    try testing.expectEqualStrings("one", (try db.find(Labelled, &run, @as(i64, 1))).?.label);

    // Inside one the refusal has aborted the transaction, so the answer is
    // the one that says to run it again.
    _ = try db.exec(&run, "ALTER TABLE \"" ++ stale_table ++ "\" ALTER COLUMN label TYPE text", .{});
    {
        var tx = try db.begin(&run, .{});
        defer tx.deinit();
        try testing.expectError(error.RolledBack, tx.find(Labelled, &run, @as(i64, 1)));
    }
    // And run again, it goes through: the rollback dropped the stale plan.
    {
        var tx = try db.begin(&run, .{});
        defer tx.deinit();
        try testing.expectEqualStrings("one", (try tx.find(Labelled, &run, @as(i64, 1))).?.label);
        try tx.commit();
    }
}

/// A table with a unique of its own, for `sql.violated` against Postgres's
/// spelling: the constraint's name.
const members_table = "nilo_live_members_" ++ mode_suffix;

const LiveMember = struct {
    pub const nilo_table = .{
        .name = members_table,
        .key = .id,
        .unique = .{ .{ .columns = .{.email} }, .{ .columns = .{ .org, .handle } } },
    };

    id: i64,
    org: i64,
    email: []const u8,
    handle: []const u8,
};

test "sql.violated says which unique a duplicate broke, by the name Postgres gives it" {
    const gpa = testing.allocator;
    const url = live_config.database_url orelse return error.SkipZigTest;

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var db = db_mod.Db.init(gpa, url, .{ .size = 1, .connect_on_init = 1, .unchecked = true });
    defer db.deinit();
    try db.nilo_start(threaded.io(), .off);
    defer db.nilo_stop();
    var run: core.Run = .init(gpa);
    defer run.deinit();

    _ = try db.exec(&run, "DROP TABLE IF EXISTS \"" ++ members_table ++ "\"", .{});
    defer _ = db.exec(&run, "DROP TABLE IF EXISTS \"" ++ members_table ++ "\"", .{}) catch {};
    try migrate.createMissing(&db, &run, .{ .tables = &.{LiveMember} });

    _ = try db.insert(LiveMember, &run, .{ .id = @as(i64, 1), .org = @as(i64, 1), .email = "ada@example.dev", .handle = "ada" });
    try testing.expectError(error.AlreadyExists, db.insert(LiveMember, &run, .{ .id = @as(i64, 2), .org = @as(i64, 1), .email = "ada@example.dev", .handle = "bob" }));
    try testing.expect(db_mod.violated(&run, LiveMember, .{.email}));
    try testing.expect(!db_mod.violated(&run, LiveMember, .{ .org, .handle }));

    try testing.expectError(error.AlreadyExists, db.insert(LiveMember, &run, .{ .id = @as(i64, 3), .org = @as(i64, 1), .email = "cy@example.dev", .handle = "ada" }));
    try testing.expect(db_mod.violated(&run, LiveMember, .{ .org, .handle }));

    try testing.expectError(error.AlreadyExists, db.insert(LiveMember, &run, .{ .id = @as(i64, 1), .org = @as(i64, 2), .email = "di@example.dev", .handle = "di" }));
    try testing.expect(db_mod.violated(&run, LiveMember, .id));
}

/// A table whose columns a generated plan drops, indexes and all.
const tidy_table = "nilo_live_tidy_" ++ mode_suffix;

test "a plan that drops an indexed column runs on Postgres, index first" {
    const gpa = testing.allocator;
    const url = live_config.database_url orelse return error.SkipZigTest;

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var db = db_mod.Db.init(gpa, url, .{ .size = 1, .connect_on_init = 1, .unchecked = true });
    defer db.deinit();
    try db.nilo_start(threaded.io(), .off);
    defer db.nilo_stop();

    var run: core.Run = .init(gpa);
    defer run.deinit();

    const Before = struct {
        pub const nilo_table = .{
            .name = tidy_table,
            .key = .id,
            .unique = .{.{ .columns = .{.slug} }},
            .index = .{.region},
        };
        id: i64,
        slug: []const u8,
        region: []const u8,
        count: i32,
    };
    const After = struct {
        pub const nilo_table = .{ .name = tidy_table, .key = .id };
        id: i64,
        count: i64,
    };

    _ = try db.exec(&run, "DROP TABLE IF EXISTS \"" ++ tidy_table ++ "\"", .{});
    defer _ = db.exec(&run, "DROP TABLE IF EXISTS \"" ++ tidy_table ++ "\"", .{}) catch {};
    try migrate.createMissing(&db, &run, .{ .tables = &.{Before} });
    _ = try db.insert(Before, &run, .{ .id = 1, .slug = "a", .region = "eu", .count = 7 });

    const a = run.arena();
    const before = try migrate.snapshotOf(a, dialect.Postgres, 1, comptime migrate.desiredOf(dialect.Postgres, .{ .tables = &.{Before} }));
    const change = try migrate.plan(a, dialect.Postgres, comptime migrate.desiredOf(dialect.Postgres, .{ .tables = &.{After} }), before);
    try testing.expectEqual(@as(usize, 0), change.problems.len);
    // int4 to int8 widens, so the two drops are the only losses to name.
    const unnamed = try change.unnamed(a, &.{});
    try testing.expectEqual(@as(usize, 2), unnamed.len);

    // In one transaction, the way `apply` sends a version. A `DROP INDEX`
    // after the column had taken its index with it failed here and undid
    // the lot.
    var tx = try db.begin(&run, .{});
    defer tx.deinit();
    for (change.steps) |s| _ = try tx.exec(&run, s.sql, .{});
    try tx.commit();

    const kept = (try db.find(After, &run, @as(i64, 1))).?;
    try testing.expectEqual(@as(i64, 7), kept.count);
}

const shape_parent = "nilo_live_shape_parent_" ++ mode_suffix;
const shape_child = "nilo_live_shape_child_" ++ mode_suffix;
const shape_counter = "nilo_live_shape_counter_" ++ mode_suffix;
const shape_list = "nilo_live_shape_list_" ++ mode_suffix;
const shape_top = "nilo_live_shape_top_" ++ mode_suffix;

test "a plan that drops two related tables, a checked column and retypes a column two views read runs on Postgres" {
    const gpa = testing.allocator;
    const url = live_config.database_url orelse return error.SkipZigTest;

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var db = db_mod.Db.init(gpa, url, .{ .size = 1, .connect_on_init = 1, .unchecked = true });
    defer db.deinit();
    try db.nilo_start(threaded.io(), .off);
    defer db.nilo_stop();

    var run: core.Run = .init(gpa);
    defer run.deinit();

    const Parent = struct {
        pub const nilo_table = .{ .name = shape_parent, .key = .id };
        id: i64,
    };
    const Child = struct {
        pub const nilo_table = .{ .name = shape_child, .key = .id, .references = .{ .parent_id = .{ Parent, .id } } };
        id: i64,
        parent_id: i64,
    };
    const Before = struct {
        pub const nilo_table = .{
            .name = shape_counter,
            .key = .id,
            .check = .{ .nilo_live_shape_note_said = "note <> ''" },
        };
        id: i64,
        count: i32,
        note: ?[]const u8,
    };
    const After = struct {
        pub const nilo_table = .{ .name = shape_counter, .key = .id };
        id: i64,
        count: i64,
    };
    // The one that reads the other listed first.
    const views = [_]migrate.Schema.Text{
        .{ .name = shape_top, .body = "SELECT * FROM " ++ shape_list ++ " WHERE count > 1" },
        .{ .name = shape_list, .body = "SELECT id, count FROM " ++ shape_counter },
    };
    const before_schema: migrate.Schema = .{ .tables = &.{ Child, Parent, Before }, .views = &views };
    const after_schema: migrate.Schema = .{ .tables = &.{After}, .views = &views };

    const drops = "DROP VIEW IF EXISTS \"" ++ shape_top ++ "\"; DROP VIEW IF EXISTS \"" ++ shape_list ++
        "\"; DROP TABLE IF EXISTS \"" ++ shape_child ++ "\", \"" ++ shape_parent ++ "\", \"" ++ shape_counter ++ "\"";
    _ = try db.exec(&run, drops, .{});
    defer _ = db.exec(&run, drops, .{}) catch {};
    try migrate.createMissing(&db, &run, before_schema);
    _ = try db.insert(Parent, &run, .{ .id = 1 });
    _ = try db.insert(Child, &run, .{ .id = 1, .parent_id = 1 });
    _ = try db.insert(Before, &run, .{ .id = 1, .count = 7, .note = @as(?[]const u8, "kept") });

    const a = run.arena();
    const before = try migrate.snapshotOf(a, dialect.Postgres, 1, comptime migrate.desiredOf(dialect.Postgres, before_schema));
    const change = try migrate.plan(a, dialect.Postgres, comptime migrate.desiredOf(dialect.Postgres, after_schema), before);
    try testing.expectEqual(@as(usize, 0), change.problems.len);

    // Each of these failed the version on Postgres's own error: the parent
    // dropped before its child, the check's `DROP CONSTRAINT` after the
    // column had taken it, and the `ALTER … TYPE` under two views.
    var tx = try db.begin(&run, .{});
    defer tx.deinit();
    for (change.steps) |step| _ = try tx.exec(&run, step.sql, .{});
    try tx.commit();

    const Top = struct {
        pub const nilo_table = .projection;
        id: i64,
        count: i64,
    };
    const top = try db.raw(Top, &run, "SELECT id, count FROM \"" ++ shape_top ++ "\"", .{});
    try testing.expectEqual(@as(usize, 1), top.len);
    try testing.expectEqual(@as(i64, 7), top[0].count);
}

const renamed_parent = "nilo_live_renamed_parent_" ++ mode_suffix;
const renamed_posts = "nilo_live_renamed_posts_" ++ mode_suffix;

test "a column `.was` renamed carries its index, its unique and its foreign key on Postgres" {
    const gpa = testing.allocator;
    const url = live_config.database_url orelse return error.SkipZigTest;

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var db = db_mod.Db.init(gpa, url, .{ .size = 1, .connect_on_init = 1, .unchecked = true });
    defer db.deinit();
    try db.nilo_start(threaded.io(), .off);
    defer db.nilo_stop();

    var run: core.Run = .init(gpa);
    defer run.deinit();

    const Parent = struct {
        pub const nilo_table = .{ .name = renamed_parent, .key = .id };
        id: i64,
    };
    const Before = struct {
        pub const nilo_table = .{
            .name = renamed_posts,
            .key = .id,
            .references = .{ .author_id = .{ Parent, .id } },
            .unique = .{.slug},
            .index = .{.author_id},
        };
        id: i64,
        author_id: i64,
        slug: []const u8,
    };
    const After = struct {
        pub const nilo_table = .{
            .name = renamed_posts,
            .key = .id,
            .was = .{ .writer_id = "author_id", .handle = "slug" },
            .references = .{ .writer_id = .{ Parent, .id } },
            .unique = .{.handle},
            .index = .{.writer_id},
        };
        id: i64,
        writer_id: i64,
        handle: []const u8,
    };

    const drops = "DROP TABLE IF EXISTS \"" ++ renamed_posts ++ "\", \"" ++ renamed_parent ++ "\"";
    _ = try db.exec(&run, drops, .{});
    defer _ = db.exec(&run, drops, .{}) catch {};
    try migrate.createMissing(&db, &run, .{ .tables = &.{ Parent, Before } });
    _ = try db.insert(Parent, &run, .{ .id = 1 });
    _ = try db.insert(Before, &run, .{ .id = 1, .author_id = 1, .slug = "a" });

    const a = run.arena();
    const before = try migrate.snapshotOf(a, dialect.Postgres, 1, comptime migrate.desiredOf(dialect.Postgres, .{ .tables = &.{ Parent, Before } }));
    const change = try migrate.plan(a, dialect.Postgres, comptime migrate.desiredOf(dialect.Postgres, .{ .tables = &.{ Parent, After } }), before);
    try testing.expectEqual(@as(usize, 0), change.problems.len);
    var tx = try db.begin(&run, .{});
    defer tx.deinit();
    for (change.steps) |step| _ = try tx.exec(&run, step.sql, .{});
    try tx.commit();

    // The names the next diff will drop by are the names the database has.
    const Named = struct {
        pub const nilo_table = .projection;
        n: i64,
    };
    const found = try db.raw(Named, &run,
        \\SELECT count(*) AS n FROM pg_class WHERE relname IN ('
    ++ renamed_posts ++ "_handle_key', '" ++ renamed_posts ++ "_writer_id_idx')" ++
        " UNION ALL SELECT count(*) FROM pg_constraint WHERE conname = '" ++ renamed_posts ++ "_writer_id_fkey'", .{});
    try testing.expectEqual(@as(i64, 2), found[0].n);
    try testing.expectEqual(@as(i64, 1), found[1].n);
    try testing.expectError(error.AlreadyExists, db.insert(After, &run, .{ .id = 2, .writer_id = 1, .handle = "a" }));
    try testing.expectError(error.ForeignKeyViolated, db.insert(After, &run, .{ .id = 3, .writer_id = 9, .handle = "b" }));
}

const fed_table = "nilo_live_fed_" ++ mode_suffix;

test "a feed after a cursor over a column rows share pages every row once on Postgres" {
    const gpa = testing.allocator;
    const url = live_config.database_url orelse return error.SkipZigTest;

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var db = db_mod.Db.init(gpa, url, .{ .size = 1, .connect_on_init = 1, .unchecked = true });
    defer db.deinit();
    try db.nilo_start(threaded.io(), .off);
    defer db.nilo_stop();

    var run: core.Run = .init(gpa);
    defer run.deinit();

    const Post = struct {
        pub const nilo_table = .{ .name = fed_table, .key = .id, .index = .{.{ .columns = .{ .posted, .id } }} };
        id: i64,
        posted: types.Timestamp,
    };
    _ = try db.exec(&run, "DROP TABLE IF EXISTS \"" ++ fed_table ++ "\"", .{});
    defer _ = db.exec(&run, "DROP TABLE IF EXISTS \"" ++ fed_table ++ "\"", .{}) catch {};
    try migrate.createMissing(&db, &run, .{ .tables = &.{Post} });
    // Forty rows over four moments, ten sharing each: a cursor over the
    // moment alone would skip nine of every ten it landed among.
    for (0..40) |i| _ = try db.insert(Post, &run, .{
        .id = @as(i64, @intCast(i + 1)),
        .posted = types.Timestamp{ .micros = @as(i64, @intCast(i / 10)) * 1_000_000 },
    });

    var seen: [41]bool = @splat(false);
    var found = try db.feed(Post, &run, .{ .order = .{ .posted = .desc, .id = .desc }, .limit = 7 });
    var total: usize = 0;
    while (true) {
        for (found.rows) |row| {
            try testing.expect(!seen[@intCast(row.id)]);
            seen[@intCast(row.id)] = true;
        }
        total += found.rows.len;
        if (!found.more) break;
        const last = found.rows[found.rows.len - 1];
        found = try db.feed(Post, &run, .{
            .order = .{ .posted = .desc, .id = .desc },
            .after = .{ .posted = last.posted, .id = last.id },
            .limit = 7,
        });
    }
    try testing.expectEqual(@as(usize, 40), total);
}

const long_table = "nilo_live_long_" ++ mode_suffix;

test "a stream let go early keeps its connection when the rest is short, and replaces it when it is long" {
    const gpa = testing.allocator;
    const url = live_config.database_url orelse return error.SkipZigTest;

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    // One connection, so the backend each statement reaches is the one the
    // pool holds.
    var db = db_mod.Db.init(gpa, url, .{ .size = 1, .connect_on_init = 1, .unchecked = true });
    defer db.deinit();
    try db.nilo_start(threaded.io(), .off);
    defer db.nilo_stop();

    var run: core.Run = .init(gpa);
    defer run.deinit();

    const Long = struct {
        pub const nilo_table = .{ .name = long_table, .key = .id };
        id: i64,
        body: []const u8,
    };
    const Backend = struct {
        pub const nilo_table = .projection;
        pid: i32,
    };
    _ = try db.exec(&run, "DROP TABLE IF EXISTS \"" ++ long_table ++ "\"", .{});
    defer _ = db.exec(&run, "DROP TABLE IF EXISTS \"" ++ long_table ++ "\"", .{}) catch {};
    // 200,000 rows of 200 bytes: forty times the budget.
    _ = try db.exec(&run, "CREATE TABLE \"" ++ long_table ++ "\" AS SELECT g::int8 AS id, repeat('x', 200) AS body " ++
        "FROM generate_series(1, 200000) AS g", .{});

    const first = (try db.raw(Backend, &run, "SELECT pg_backend_pid() AS pid", .{}))[0].pid;

    // A hundred rows: read to the end, and the connection kept.
    {
        var rows = try db.stream(Long, &run, .{ .order = .{ .id = .asc }, .limit = 100 });
        defer rows.close();
        _ = try rows.next();
    }
    try testing.expectEqual(first, (try db.raw(Backend, &run, "SELECT pg_backend_pid() AS pid", .{}))[0].pid);

    // The whole table: past the budget the connection is given up, and the
    // next statement runs on its replacement.
    {
        var rows = try db.stream(Long, &run, .{ .order = .{ .id = .asc } });
        defer rows.close();
        _ = try rows.next();
    }
    const after = (try db.raw(Backend, &run, "SELECT pg_backend_pid() AS pid", .{}))[0].pid;
    try testing.expect(after != first);
    try testing.expectEqual(@as(usize, 200_000), try db.count(Long, &run, .{}));
}

test "a Db told to keep no plans still answers, one Parse at a time" {
    const gpa = testing.allocator;
    var live = (try Live.open(gpa)) orelse return error.SkipZigTest;
    defer live.close(gpa);

    // The pgbouncer setting, against a real server. It is the same rows or
    // the escape hatch is not an escape hatch — a caller reaching for it has
    // a pooler in transaction mode and no third option.
    var db = db_mod.Db.init(gpa, "already open", .{ .prepared = false });
    db.wire = live.wire;

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    var round: usize = 0;
    while (round < 4) : (round += 1) {
        const ada = try db.find(Person, &run, @as(i64, 1));
        try testing.expectEqualStrings("ada@example.dev", ada.?.email);
        try testing.expectEqual(@as(usize, 3), try db.count(Person, &run, .{}));
        run.reset();
    }
}

// -- a Row as wide as a real table -----------------------------------------

/// Twenty columns, the width `rab_lines` has in the port that found the
/// builders running out of branches at seventeen written (ADR 169).
const Line = struct {
    pub const nilo_table = .{ .name = lines_table, .key = .id, .filled = .{ .created_at, .updated_at } };

    id: i64,
    rab_id: i64,
    section_id: ?i64,
    position: i32,
    kind: []const u8,
    commitment_id: ?i64,
    sku_id: ?i64,
    description: []const u8,
    quantity: types.Decimal,
    unit: []const u8,
    unit_cost_currency: ?[]const u8,
    unit_cost_amount_minor: ?i64,
    cost_source: []const u8,
    notes: ?[]const u8,
    partner_id: ?i64,
    lead_days: ?i32,
    risk: ?[]const u8,
    reference: ?[]const u8,
    created_at: types.Timestamp,
    updated_at: types.Timestamp,
};

/// What a save writes: everything but the key and the two the database fills.
const SavedLine = struct {
    rab_id: i64,
    section_id: ?i64,
    position: i32,
    kind: []const u8,
    commitment_id: ?i64,
    sku_id: ?i64,
    description: []const u8,
    quantity: types.Decimal,
    unit: []const u8,
    unit_cost_currency: ?[]const u8,
    unit_cost_amount_minor: ?i64,
    cost_source: []const u8,
    notes: ?[]const u8,
    partner_id: ?i64,
    lead_days: ?i32,
    risk: ?[]const u8,
    reference: ?[]const u8,
};

fn savedLine(rab: i64, position: i32, description: []const u8) SavedLine {
    return .{
        .rab_id = rab,
        .section_id = if (@rem(position, 2) == 0) 7 else null,
        .position = position,
        .kind = "sku",
        .commitment_id = null,
        .sku_id = 1_000 + position,
        .description = description,
        .quantity = .{ .text = "2.500" },
        .unit = "day",
        .unit_cost_currency = "IDR",
        .unit_cost_amount_minor = 150_000_00,
        .cost_source = "catalogue",
        .notes = null,
        .partner_id = null,
        .lead_days = 14,
        .risk = null,
        .reference = null,
    };
}

test "a batch seventeen columns wide goes into a twenty-column table in one statement" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    // The document, forty rows at a time, which is the shape the port saves
    // on a timer and had fallen back to one `INSERT` per row for.
    var lines: [40]SavedLine = undefined;
    for (&lines, 0..) |*line, i| line.* = savedLine(1, @intCast(i), "a line of the document");
    const stored = try stack.db.insertMany(Line, &run, &lines);
    try testing.expectEqual(@as(usize, 40), stored.len);
    try testing.expectEqual(@as(i32, 39), stored[39].position);
    try testing.expectEqual(@as(?i64, 7), stored[38].section_id);
    try testing.expectEqual(@as(?i64, null), stored[39].section_id);
    try testing.expectEqualStrings("2.500", stored[0].quantity.text);
    try testing.expect(stored[0].created_at.micros > 0);

    // One row the same way, and the upsert over it, on the same width.
    const one = try stack.db.insert(Line, &run, savedLine(2, 0, "a single line"));
    try testing.expectEqualStrings("a single line", one.description);
    try testing.expectEqual(@as(?i64, 1_000), one.sku_id);

    // A batched update carrying the key and every column a save may move.
    const Moved = struct { id: i64, position: i32, notes: ?[]const u8, quantity: types.Decimal };
    const moved = try stack.db.updateMany(Line, &run, &[_]Moved{
        .{ .id = stored[0].id, .position = 100, .notes = "moved", .quantity = .{ .text = "1.000" } },
        .{ .id = stored[1].id, .position = 101, .notes = null, .quantity = .{ .text = "0.250" } },
    });
    try testing.expectEqual(@as(usize, 2), moved.len);

    const total = try stack.db.count(Line, &run, .{ .where = .{ .rab_id = @as(i64, 1) } });
    try testing.expectEqual(@as(usize, 40), total);
}

test "a statement composed at run time fills a Row by position and runs unnamed" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);
    var run = nilo.Run.init(gpa);
    defer run.deinit();

    // The pieces a query engine has: names out of a model, values out of a
    // request. Nothing here is a comptime statement.
    const measure: []const u8 = "age";
    const by: []const u8 = "handle";
    var s = stack.db.compose(&run);
    try s.text("SELECT ");
    try s.ident(by);
    try s.text(", sum(");
    try s.ident(measure);
    try s.text(")::bigint FROM ");
    try s.ident(table);
    try s.text(" WHERE ");
    try s.ident(measure);
    try s.text(" > ");
    try s.param(1);
    try s.text(" GROUP BY 1 ORDER BY 1 NULLS LAST LIMIT ");
    try s.number(10);

    const Tallied = struct {
        pub const nilo_table = .projection;
        handle: ?[]const u8,
        total: i64,
    };
    const rows = try stack.db.composed(Tallied, &run, s, .{@as(i32, 0)});
    try testing.expect(rows.len >= 1);
    var sum: i64 = 0;
    for (rows) |r| sum += r.total;
    const exact = try stack.db.rawOne(i64, &run, "SELECT sum(age)::bigint FROM " ++ table ++ " WHERE age > 0", .{});
    try testing.expectEqual(exact.?, sum);

    // One column into a scalar, the way `raw` allows (ADR 125).
    var one = stack.db.compose(&run);
    try one.text("SELECT count(*)::bigint FROM ");
    try one.ident(table);
    const n = try stack.db.composedOne(i64, &run, one, .{});
    try testing.expectEqual(@as(i64, 3), n.?);

    // The same inside a transaction, down the connection it holds: the row
    // it inserted is one only it can see until it commits.
    {
        var tx = try stack.db.begin(&run, .{});
        defer tx.deinit();
        _ = try tx.exec(&run, "INSERT INTO " ++ table ++ " (id, email, age) VALUES (99, 'tx@example.dev', 1)", .{});
        var in_tx = tx.compose(&run);
        try in_tx.text("SELECT count(*)::bigint FROM ");
        try in_tx.ident(table);
        try testing.expectEqual(@as(i64, 4), (try tx.composedOne(i64, &run, in_tx, .{})).?);
    }
    try testing.expectEqual(@as(i64, 3), (try stack.db.composedOne(i64, &run, one, .{})).?);

    // A name that is not one never reaches the database, and neither does a
    // statement with more placeholders than values.
    var bad = stack.db.compose(&run);
    try testing.expectError(error.NotAnIdentifier, bad.ident("people; DROP TABLE people"));
    try testing.expectError(error.ParamCountMismatch, stack.db.composed(i64, &run, s, .{}));
}

/// A Row that is the response and leaves its timestamp out, declaring it
/// unread (item 102).
const UnreadDeal = struct {
    pub const nilo_table = .{
        .name = unread_deals,
        .default = .{ .created_at = .now },
        .unread = .{ .created_at = types.Timestamp },
    };
    id: i64,
    title: []const u8,
};

test "a column the Row does not read is written, ordered, narrowed and checked on a real Postgres" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();
    _ = try stack.db.exec(&run, "DROP TABLE IF EXISTS " ++ unread_deals, .{});
    _ = try stack.db.exec(&run, "CREATE TABLE " ++ unread_deals ++ " (id bigserial PRIMARY KEY, " ++
        "title text NOT NULL, created_at timestamptz NOT NULL DEFAULT now())", .{});

    // Two written with a moment of their own, in 2001 and 2000, and one left
    // to the default.
    _ = try stack.db.insert(UnreadDeal, &run, .{ .title = "old", .created_at = types.Timestamp{ .micros = 978_307_200_000_000 } });
    _ = try stack.db.insert(UnreadDeal, &run, .{ .title = "older", .created_at = types.Timestamp{ .micros = 946_684_800_000_000 } });
    _ = try stack.db.insert(UnreadDeal, &run, .{ .title = "new" });

    const ordered = try stack.db.select(UnreadDeal, &run, .{ .order = .{ .created_at = .asc } });
    try testing.expectEqual(@as(usize, 3), ordered.len);
    try testing.expectEqualStrings("older", ordered[0].title);
    try testing.expectEqualStrings("new", ordered[2].title);
    try testing.expectEqual(@as(usize, 1), try stack.db.count(UnreadDeal, &run, .{
        .where = .{ .created_at = .{ .gt = .{ .now = .{ .days = -90 } } } },
    }));

    // The boot check holds the unread column like a read one, and says so
    // when the table has lost it.
    const arena = run.arena();
    var problems: std.ArrayList(schema.Problem) = .empty;
    const columns = try stack.live.wire.columnsOf(arena, dialect.Postgres.introspect, null, unread_deals);
    try testing.expectEqual(@as(usize, 0), try schema.compare(dialect.Postgres, UnreadDeal, columns, &problems, arena));
    _ = try stack.db.exec(&run, "ALTER TABLE " ++ unread_deals ++ " DROP COLUMN created_at", .{});
    const without = try stack.live.wire.columnsOf(arena, dialect.Postgres.introspect, null, unread_deals);
    try testing.expectEqual(@as(usize, 1), try schema.compare(dialect.Postgres, UnreadDeal, without, &problems, arena));
    try testing.expectEqualStrings("created_at", problems.items[0].column);
    _ = try stack.db.exec(&run, "DROP TABLE " ++ unread_deals, .{});
}

// -- shaped Rows ---------------------------------------------------------
//
// What SQLite cannot say about ADR 218: that `sum` over a `bigint` comes
// back as the `numeric` Postgres makes of it unless it is cast, that a list
// of uuids is one `uuid[]` parameter `unnest` numbers, and that a presence
// test reads as a `bool`.

const ShapeCustomer = struct {
    pub const nilo_table = .{ .name = shape_customers };
    id: i64,
    name: []const u8,
};

const ShapeOrder = struct {
    pub const nilo_table = .{
        .name = shape_orders,
        .references = .{ .customer_id = .{ ShapeCustomer, .id }, .referrer_id = .{ ShapeCustomer, .id } },
    };
    id: types.Uuid,
    customer_id: i64,
    referrer_id: ?i64,
    total: i64,
    weight: f32,
};

const ShapeLine = struct {
    pub const nilo_table = .{ .name = shape_lines, .references = .{ .order_id = .{ ShapeOrder, .id } } };
    id: i64,
    order_id: types.Uuid,
    sku: []const u8,
};

const ShapeCustomerName = struct {
    pub const nilo_table = ShapeCustomer;
    name: []const u8,
};

const ShapeSku = struct {
    pub const nilo_table = ShapeLine;
    sku: []const u8,
};

const ShapeOrderCard = struct {
    pub const nilo_table = ShapeOrder;
    pub const nilo_via = .{ .customer = .customer_id, .referrer = .referrer_id };
    id: types.Uuid,
    total: i64,
    customer: ShapeCustomerName,
    referrer: ?ShapeCustomerName,
    lines: []const ShapeSku,
};

/// An order read for its customer alone, which leaves the order's key out
/// (item 103).
const ShapeOrderOwner = struct {
    pub const nilo_table = ShapeOrder;
    pub const nilo_via = .{ .customer = .customer_id };
    customer: ShapeCustomerName,
};

const ShapeByCustomer = struct {
    pub const nilo_table = ShapeOrder;
    pub const nilo_via = .{ .customer = .customer_id };
    pub const nilo_aggregate = .{
        .orders = .count,
        .revenue = .{ .sum = .total },
        .mean = .{ .avg = .total },
        .heaviest = .{ .max = .weight },
        .weighed = .{ .sum = .weight },
    };
    customer: ShapeCustomerName,
    orders: i64,
    revenue: i64,
    mean: f64,
    heaviest: f32,
    weighed: f64,
};

const ShapeLineTally = struct {
    pub const nilo_table = ShapeLine;
    pub const nilo_aggregate = .{
        .acme = .{ .count = .id, .where = .{ .order_id = .{ .customer_id = .{ .name = "Acme" } } } },
        .referred = .{ .count = .id, .where = .{ .order_id = .{ .referrer_id = .{ .name = "Borealis" } } } },
    };
    acme: i64,
    referred: i64,
};

const ShapeCounted = struct {
    pub const nilo_table = ShapeOrder;
    pub const nilo_via = .{ .customer = .customer_id };
    pub const nilo_children = .{
        .line_count = .{ .count = ShapeLine },
        .lines = .{ .order = .{ .sku = .desc }, .where = .{ .sku = .{ .in = .{ "a", "b" } } } },
    };
    id: types.Uuid,
    customer: ShapeCustomerName,
    line_count: i64,
    lines: []const ShapeSku,
};

const ShapeFiltered = struct {
    pub const nilo_table = ShapeOrder;
    pub const nilo_via = .{ .customer = .customer_id };
    pub const nilo_aggregate = .{
        .large = .{ .sum = .total, .where = .{ .total = .{ .gte = 100 } } },
        .referred = .{ .count = .id, .where = .{ .referrer_id = .{ .ne = null } } },
        .light = .{ .max = .weight, .where = .{ .weight = .{ .lt = 2.0 } } },
    };
    customer: ShapeCustomerName,
    large: ?i64,
    referred: i64,
    light: ?f32,
};

const ShapeOrderTotal = struct {
    pub const nilo_table = ShapeOrder;
    total: i64,
};

/// A customer with figures over its orders, some narrowed through the
/// order's other reference to a customer (item 100).
const ShapeCustomerPulse = struct {
    pub const nilo_table = ShapeCustomer;
    pub const nilo_via = .{
        .orders = .customer_id,
        .referred = .customer_id,
        .biggest_referred = .customer_id,
        .lightest = .customer_id,
        .referred_orders = .customer_id,
    };
    pub const nilo_children = .{
        .orders = .{ .count = ShapeOrder },
        .referred = .{ .count = ShapeOrder, .where = .{ .referrer_id = .{ .name = "Borealis" } } },
        .biggest_referred = .{ .max = .{ ShapeOrder, .total }, .where = .{ .referrer_id = .{ .name = "Borealis" } } },
        .lightest = .{ .min = .{ ShapeOrder, .weight } },
        .referred_orders = .{ .where = .{ .referrer_id = .{ .name = .{ .ne = "Nobody" } } } },
    };
    id: i64,
    name: []const u8,
    orders: i64,
    referred: i64,
    biggest_referred: ?i64,
    lightest: ?f32,
    referred_orders: []const ShapeOrderTotal,
};

/// An order read flat, the way a response whose contract is flat has it
/// (item 83).
const ShapeOrderFlat = struct {
    pub const nilo_table = ShapeOrder;
    pub const nilo_through = .{
        .customer_name = .{ .customer_id, .name },
        .referrer_name = .{ .referrer_id, .name },
    };
    id: types.Uuid,
    total: i64,
    customer_name: []const u8,
    referrer_name: ?[]const u8,
};

const ShapeLineFlat = struct {
    pub const nilo_table = ShapeLine;
    pub const nilo_through = .{ .customer_name = .{ .order_id, .customer_id, .name } };
    sku: []const u8,
    customer_name: []const u8,
};

/// A row whose referrer is missing, read as a word of its own or left out
/// (item 109).
const ShapeOrderLabelled = struct {
    pub const nilo_table = ShapeOrder;
    pub const nilo_through = .{
        .referrer_label = .{ .path = .{ .referrer_id, .name }, .otherwise = "direct" },
    };
    total: i64,
    referrer_label: []const u8,
};

const ShapeOrderReferred = struct {
    pub const nilo_table = ShapeOrder;
    pub const nilo_through = .{
        .referrer_name = .{ .path = .{ .referrer_id, .name }, .join = .inner },
    };
    total: i64,
    referrer_name: []const u8,
};

const shape_setup = [_][]const u8{
    "DROP TABLE IF EXISTS " ++ shape_lines,
    "DROP TABLE IF EXISTS " ++ shape_orders,
    "DROP TABLE IF EXISTS " ++ shape_customers,
    "CREATE TABLE " ++ shape_customers ++ " (id bigint PRIMARY KEY, name text NOT NULL)",
    "CREATE TABLE " ++ shape_orders ++ " (id uuid PRIMARY KEY, customer_id bigint NOT NULL, " ++
        "referrer_id bigint, total bigint NOT NULL, weight real NOT NULL)",
    "CREATE TABLE " ++ shape_lines ++ " (id bigint PRIMARY KEY, order_id uuid NOT NULL, sku text NOT NULL)",
    "INSERT INTO " ++ shape_customers ++ " VALUES (1, 'Acme'), (2, 'Borealis')",
    "INSERT INTO " ++ shape_orders ++ " VALUES " ++
        "('00000000-0000-7000-8000-000000000001', 1, 2, 100, 1.5), " ++
        "('00000000-0000-7000-8000-000000000002', 1, NULL, 250, 2.5), " ++
        "('00000000-0000-7000-8000-000000000003', 2, 1, 40, 0.5)",
    "INSERT INTO " ++ shape_lines ++ " VALUES " ++
        "(2, '00000000-0000-7000-8000-000000000001', 'b'), (1, '00000000-0000-7000-8000-000000000001', 'a'), " ++
        "(3, '00000000-0000-7000-8000-000000000003', 'c')",
};

test "a parent, its children and a sum come back from a real Postgres" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();
    for (shape_setup) |text| _ = try stack.db.exec(&run, text, .{});

    const cards = try stack.db.select(ShapeOrderCard, &run, .{ .order = .{ .total = .desc } });
    try testing.expectEqual(@as(usize, 3), cards.len);
    // 250: Acme's, no referrer, no lines.
    try testing.expectEqualStrings("Acme", cards[0].customer.name);
    try testing.expect(cards[0].referrer == null);
    try testing.expectEqual(@as(usize, 0), cards[0].lines.len);
    // 100: Acme's, referred by Borealis, two lines in key order.
    try testing.expectEqualStrings("Borealis", cards[1].referrer.?.name);
    try testing.expectEqual(@as(usize, 2), cards[1].lines.len);
    try testing.expectEqualStrings("a", cards[1].lines[0].sku);
    try testing.expectEqualStrings("b", cards[1].lines[1].sku);
    // 40: Borealis's, referred by Acme, one line.
    try testing.expectEqualStrings("Acme", cards[2].referrer.?.name);
    try testing.expectEqualStrings("c", cards[2].lines[0].sku);

    // Item 103: a Row carrying only a parent is found by the key it leaves
    // out, the way `one` finds it with the key in `.where`.
    const owner = (try stack.db.find(ShapeOrderOwner, &run, cards[2].id)).?;
    try testing.expectEqualStrings("Borealis", owner.customer.name);
    try testing.expect((try stack.db.find(ShapeOrderOwner, &run, types.Uuid.nil)) == null);

    // A condition through a parent, in a transaction so the two statements
    // are one snapshot.
    var tx = try stack.db.begin(&run, .{});
    defer tx.deinit();
    const referred = try tx.select(ShapeOrderCard, &run, .{
        .where = .{ .referrer = .{ .name = "Acme" } },
    });
    try testing.expectEqual(@as(usize, 1), referred.len);
    try testing.expectEqual(@as(i64, 40), referred[0].total);
    try tx.commit();

    const groups = try stack.db.page(ShapeByCustomer, &run, .{
        .where = .{ .revenue = .{ .gt = @as(i64, 10) } },
        .order = .{ .revenue = .desc },
        .limit = 10,
    });
    try testing.expectEqual(@as(i64, 2), groups.total);
    try testing.expectEqualStrings("Acme", groups.rows[0].customer.name);
    try testing.expectEqual(@as(i64, 2), groups.rows[0].orders);
    try testing.expectEqual(@as(i64, 350), groups.rows[0].revenue);
    try testing.expectEqual(@as(f64, 175), groups.rows[0].mean);
    try testing.expectEqual(@as(f32, 2.5), groups.rows[0].heaviest);
    try testing.expectEqual(@as(f64, 4), groups.rows[0].weighed);
    try testing.expectEqual(@as(i64, 40), groups.rows[1].revenue);

    // An aggregate's `.where`: the cast applies to the filtered call, and a
    // group none of whose rows matches is null rather than missing.
    const filtered = try stack.db.select(ShapeFiltered, &run, .{ .order = .{ .customer = .{ .name = .asc } } });
    try testing.expectEqual(@as(usize, 2), filtered.len);
    try testing.expectEqual(@as(?i64, 350), filtered[0].large);
    try testing.expectEqual(@as(i64, 1), filtered[0].referred);
    try testing.expectEqual(@as(?f32, 1.5), filtered[0].light);
    try testing.expect(filtered[1].large == null);
    try testing.expectEqual(@as(i64, 1), filtered[1].referred);
    try testing.expectEqual(@as(?f32, 0.5), filtered[1].light);
    const having = try stack.db.select(ShapeFiltered, &run, .{ .where = .{ .large = .{ .gt = @as(i64, 0) } } });
    try testing.expectEqual(@as(usize, 1), having.len);
    // A filtered sum is optional, and on Postgres `.desc` puts its nulls
    // first: a leaderboard ranks with `NULLS LAST`.
    const ranked = try stack.db.select(ShapeFiltered, &run, .{ .order = .{ .large = .desc_nulls_last } });
    try testing.expectEqual(@as(?i64, 350), ranked[0].large);
    try testing.expect(ranked[1].large == null);

    // Children in an order of their own and narrowed, and a count of them
    // read in the same statement as the rows it belongs to.
    const counted = try stack.db.select(ShapeCounted, &run, .{
        .where = .{ .line_count = .{ .gt = @as(i64, 0) } },
        .order = .{ .line_count = .desc },
    });
    try testing.expectEqual(@as(usize, 2), counted.len);
    try testing.expectEqual(@as(i64, 2), counted[0].line_count);
    try testing.expectEqual(@as(usize, 2), counted[0].lines.len);
    try testing.expectEqualStrings("b", counted[0].lines[0].sku);
    try testing.expectEqualStrings("a", counted[0].lines[1].sku);
    try testing.expectEqual(@as(i64, 1), counted[1].line_count);
    try testing.expectEqual(@as(usize, 0), counted[1].lines.len);

    // Item 100: a count, a max and a min over the rows pointing back, the
    // first two narrowed through the order's nullable reference to its
    // referrer, and a children list narrowed the same way. Acme's orders are
    // 100 (referred by Borealis) and 250; Borealis's is 40, referred by Acme.
    const pulse = try stack.db.select(ShapeCustomerPulse, &run, .{ .order = .{ .name = .asc } });
    try testing.expectEqual(@as(usize, 2), pulse.len);
    try testing.expectEqual(@as(i64, 2), pulse[0].orders);
    try testing.expectEqual(@as(i64, 1), pulse[0].referred);
    try testing.expectEqual(@as(?i64, 100), pulse[0].biggest_referred);
    try testing.expectEqual(@as(?f32, 1.5), pulse[0].lightest);
    try testing.expectEqual(@as(usize, 1), pulse[0].referred_orders.len);
    try testing.expectEqual(@as(i64, 100), pulse[0].referred_orders[0].total);
    try testing.expectEqual(@as(i64, 1), pulse[1].orders);
    try testing.expectEqual(@as(i64, 0), pulse[1].referred);
    try testing.expect(pulse[1].biggest_referred == null);
    try testing.expectEqual(@as(?f32, 0.5), pulse[1].lightest);
    try testing.expectEqual(@as(i64, 40), pulse[1].referred_orders[0].total);
    const with_referred = try stack.db.select(ShapeCustomerPulse, &run, .{
        .where = .{ .biggest_referred = .{ .gt = @as(i64, 0) } },
    });
    try testing.expectEqual(@as(usize, 1), with_referred.len);
    try testing.expectEqualStrings("Acme", with_referred[0].name);

    // Item 83: the same parents read flat, ordered and narrowed by, and two
    // references away from a line.
    const flat = try stack.db.select(ShapeOrderFlat, &run, .{ .order = .{ .total = .desc } });
    try testing.expectEqual(@as(usize, 3), flat.len);
    try testing.expectEqualStrings("Acme", flat[0].customer_name);
    try testing.expect(flat[0].referrer_name == null);
    try testing.expectEqualStrings("Borealis", flat[1].referrer_name.?);
    try testing.expectEqualStrings("Borealis", flat[2].customer_name);
    const by_referrer = try stack.db.select(ShapeOrderFlat, &run, .{
        .where = .{ .referrer_name = @as([]const u8, "Acme") },
    });
    try testing.expectEqual(@as(usize, 1), by_referrer.len);
    try testing.expectEqual(@as(i64, 40), by_referrer[0].total);
    try testing.expectEqual(@as(usize, 2), try stack.db.count(ShapeOrderFlat, &run, .{
        .where = .{ .customer_name = @as([]const u8, "Acme") },
    }));
    const flat_lines = try stack.db.select(ShapeLineFlat, &run, .{ .order = .{ .customer_name = .desc, .sku = .asc } });
    try testing.expectEqual(@as(usize, 3), flat_lines.len);
    try testing.expectEqualStrings("Borealis", flat_lines[0].customer_name);
    try testing.expectEqualStrings("a", flat_lines[1].sku);
    try testing.expectEqualStrings("Acme", flat_lines[2].customer_name);

    // Item 108: the same Row filled by a statement written by hand, one
    // field per column, held against it on its first run like any raw Row.
    const raw_flat = try stack.db.raw(ShapeOrderFlat, &run,
        "SELECT o.id, o.total, c.name AS customer_name, r.name AS referrer_name" ++
        " FROM " ++ shape_orders ++ " o" ++
        " JOIN " ++ shape_customers ++ " c ON c.id = o.customer_id" ++
        " LEFT JOIN " ++ shape_customers ++ " r ON r.id = o.referrer_id" ++
        " ORDER BY o.total DESC", .{});
    try testing.expectEqual(@as(usize, 3), raw_flat.len);
    try testing.expect(raw_flat[0].referrer_name == null);
    try testing.expectEqualStrings("Borealis", raw_flat[1].referrer_name.?);

    // Item 109: the order with no referrer reads the word the Row gave, in
    // the answer and in a condition alike, or is not read at all, and a
    // count agrees with the list.
    const labelled = try stack.db.select(ShapeOrderLabelled, &run, .{ .order = .{ .total = .desc } });
    try testing.expectEqual(@as(usize, 3), labelled.len);
    try testing.expectEqualStrings("direct", labelled[0].referrer_label);
    try testing.expectEqualStrings("Borealis", labelled[1].referrer_label);
    const direct = try stack.db.select(ShapeOrderLabelled, &run, .{
        .where = .{ .referrer_label = @as([]const u8, "direct") },
    });
    try testing.expectEqual(@as(usize, 1), direct.len);
    try testing.expectEqual(@as(i64, 250), direct[0].total);
    const referred_only = try stack.db.page(ShapeOrderReferred, &run, .{ .order = .{ .total = .desc }, .limit = 10 });
    try testing.expectEqual(@as(i64, 2), referred_only.total);
    try testing.expectEqual(@as(i64, 100), referred_only.rows[0].total);
    try testing.expectEqualStrings("Acme", referred_only.rows[1].referrer_name);
    try testing.expectEqual(@as(usize, 2), try stack.db.count(ShapeOrderReferred, &run, .{}));

    // Item 107: the orders no line points at, an `.exists` with nothing to
    // ask of the line but that it is there.
    const bare = try stack.db.select(ShapeOrderTotal, &run, .{
        .where = .{ .not_exists = .{.{ .in = ShapeLine }} },
    });
    try testing.expectEqual(@as(usize, 1), bare.len);
    try testing.expectEqual(@as(i64, 250), bare[0].total);
    try testing.expectEqual(@as(usize, 2), try stack.db.count(ShapeOrderTotal, &run, .{
        .where = .{ .exists = .{.{ .in = ShapeLine }} },
    }));

    // An aggregate's `.where` through two references, one of them nullable.
    const tally = try stack.db.exactlyOne(ShapeLineTally, &run, .{});
    // Order 1 is Acme's and holds two lines; order 2, Acme's too, holds none.
    try testing.expectEqual(@as(i64, 2), tally.acme);
    try testing.expectEqual(@as(i64, 2), tally.referred);

    // The plan of a shaped read, run with its values bound: what a slow page
    // is asked first.
    const plan = try stack.db.explain(ShapeOrderCard, &run, .{
        .where = .{ .total = .{ .gt = @as(i64, 50) } },
        .order = .{ .total = .desc },
    });
    try testing.expect(std.mem.indexOf(u8, plan, shape_orders) != null);
    try testing.expect(std.mem.indexOf(u8, plan, "Execution Time:") != null);
    try testing.expect(std.mem.indexOf(u8, plan, "\n") != null);

    for (shape_setup[0..3]) |text| _ = try stack.db.exec(&run, text, .{});
}

const GroupCustomer = struct {
    pub const nilo_table = .{ .name = group_customers };
    id: i64,
    name: []const u8,
};

const GroupOrder = struct {
    pub const nilo_table = .{
        .name = group_orders,
        .references = .{ .customer_id = .{ GroupCustomer, .id } },
    };
    id: i64,
    customer_id: i64,
    total: i64,
};

const GroupByCustomerName = struct {
    pub const nilo_table = GroupOrder;
    pub const nilo_through = .{ .customer_name = .{ .customer_id, .name } };
    pub const nilo_aggregate = .{ .orders = .count, .revenue = .{ .sum = .total } };
    customer_name: []const u8,
    orders: i64,
    revenue: i64,
};

test "a grouped Row reading a name through a reference keeps two customers of one name apart" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();
    const group_setup = [_][]const u8{
        "DROP TABLE IF EXISTS " ++ group_orders,
        "DROP TABLE IF EXISTS " ++ group_customers,
        "CREATE TABLE " ++ group_customers ++ " (id bigint PRIMARY KEY, name text NOT NULL)",
        "CREATE TABLE " ++ group_orders ++ " (id bigint PRIMARY KEY, customer_id bigint NOT NULL, total bigint NOT NULL)",
        "INSERT INTO " ++ group_customers ++ " VALUES (1, 'Ani'), (2, 'Ani'), (3, 'Budi')",
        "INSERT INTO " ++ group_orders ++ " VALUES (1, 1, 100), (2, 1, 50), (3, 2, 7), (4, 3, 1)",
    };
    for (group_setup) |text| _ = try stack.db.exec(&run, text, .{});
    defer for (group_setup[0..2]) |text| {
        _ = stack.db.exec(&run, text, .{}) catch {};
    };

    const groups = try stack.db.select(GroupByCustomerName, &run, .{
        .order = .{ .revenue = .desc },
    });
    try testing.expectEqual(@as(usize, 3), groups.len);
    try testing.expectEqualStrings("Ani", groups[0].customer_name);
    try testing.expectEqual(@as(i64, 150), groups[0].revenue);
    try testing.expectEqual(@as(i64, 2), groups[0].orders);
    try testing.expectEqualStrings("Ani", groups[1].customer_name);
    try testing.expectEqual(@as(i64, 7), groups[1].revenue);
    try testing.expectEqual(@as(i64, 1), groups[1].orders);
    try testing.expectEqualStrings("Budi", groups[2].customer_name);

    // Two pages of one, ordered by a tie: the second Ani is not lost.
    const first = try stack.db.page(GroupByCustomerName, &run, .{ .order = .{ .revenue = .desc }, .limit = 2 });
    try testing.expectEqual(@as(i64, 3), first.total);
    try testing.expectEqual(@as(usize, 2), first.rows.len);
}

const TicketKind = enum { urgent, billing };
const TicketKindShort = enum { urgent };

const KindedTicket = struct {
    pub const nilo_table = .{ .name = list_table, .key = .id };

    id: i64,
    tags: []const TicketKind,
};

const ShortKindedTicket = struct {
    pub const nilo_table = .{ .name = list_table, .key = .id };

    id: i64,
    tags: []const TicketKindShort,
};

const WideScores = struct {
    pub const nilo_table = .{ .name = list_table, .key = .id };

    id: i64,
    scores: ?[]const i64,
};

const FloatScores = struct {
    pub const nilo_table = .{ .name = list_table, .key = .id };

    id: i64,
    scores: ?[]const f64,
};

const TextScores = struct {
    pub const nilo_table = .{ .name = list_table, .key = .id };

    id: i64,
    scores: ?[]const []const u8,
};

test "a list of enums reads each label, and one the enum lacks is a refusal rather than a panic" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    const was = std.testing.log_level;
    defer std.testing.log_level = was;
    std.testing.log_level = .err;

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    const found = try stack.db.select(KindedTicket, &run, .{ .where = .{ .id = @as(i64, 1) } });
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqual(@as(usize, 2), found[0].tags.len);
    try testing.expectEqual(TicketKind.urgent, found[0].tags[0]);
    try testing.expectEqual(TicketKind.billing, found[0].tags[1]);

    // The empty array has a label to be wrong about in no element at all.
    const empty = try stack.db.select(KindedTicket, &run, .{ .where = .{ .id = @as(i64, 2) } });
    try testing.expectEqual(@as(usize, 0), empty[0].tags.len);

    // pg.zig decodes with `std.meta.stringToEnum(T, data).?`: `billing` is a
    // label of the column and not of this enum, and that took the process down.
    try testing.expectError(error.QueryFailed, stack.db.select(ShortKindedTicket, &run, .{
        .where = .{ .id = @as(i64, 1) },
    }));
}

test "an array read into a list of another element type is a refusal, empty or not, in place of pg.zig's panic" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    const was = std.testing.log_level;
    defer std.testing.log_level = was;
    std.testing.log_level = .err;

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    // `scores` is `integer[]`. pg.zig panics on an `i64` or an `f64` list of
    // any element type but its own.
    try testing.expectError(error.QueryFailed, stack.db.select(WideScores, &run, .{
        .where = .{ .id = @as(i64, 1) },
    }));
    try testing.expectError(error.QueryFailed, stack.db.select(FloatScores, &run, .{
        .where = .{ .id = @as(i64, 1) },
    }));
    // Text over an `integer[]` decoded as raw bytes without a word.
    try testing.expectError(error.QueryFailed, stack.db.select(TextScores, &run, .{
        .where = .{ .id = @as(i64, 1) },
    }));
}

test "an order over a numeric sorts the numbers, not the text they are read as" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    // Different widths: as text `9.00` sorts after `100.5`, which sorts after
    // `10.00`. `"balance"::text` is answered as `balance`, and Postgres reads a
    // bare name in `ORDER BY` against the answers first. Two of them share a
    // balance, so the tiebreak has to matter.
    const balances = [_][]const u8{ "9.00", "10.00", "100.5", "10.00" };
    const emails = [_][]const u8{ "w0@example.dev", "w1@example.dev", "w2@example.dev", "w3@example.dev" };
    for (balances, emails, 0..) |text, email, i| {
        _ = try stack.db.insert(Account, &run, .{
            .id = @as(i64, 710) + @as(i64, @intCast(i)),
            .email = email,
            .age = @as(i32, 30),
            .balance = types.Decimal{ .text = text },
        });
    }
    const ids = [_]i64{ 710, 711, 712, 713 };

    const down = try stack.db.select(Account, &run, .{
        .where = .{ .id = .{ .in = &ids } },
        .order = .{ .balance = .desc },
        .limit = 10,
    });
    try testing.expectEqual(@as(usize, 4), down.len);
    try testing.expectEqualStrings("100.5", down[0].balance.text);
    try testing.expectEqualStrings("10.00", down[1].balance.text);
    try testing.expectEqualStrings("10.00", down[2].balance.text);
    try testing.expectEqualStrings("9.00", down[3].balance.text);

    const up = try stack.db.select(Account, &run, .{
        .where = .{ .id = .{ .in = &ids } },
        .order = .{ .balance = .asc },
    });
    try testing.expectEqualStrings("9.00", up[0].balance.text);
    try testing.expectEqualStrings("100.5", up[3].balance.text);

    // A feed compares its cursor as a number, so the rows it walks have to be
    // in that order or it skips them. Its first page names only the balance,
    // and the tiebreak has to run the way the later pages, which name the key,
    // do: 713 and 711 share a balance.
    const first = try stack.db.feed(Account, &run, .{
        .where = .{ .id = .{ .in = &ids } },
        .order = .{ .balance = .desc },
        .limit = 2,
    });
    try testing.expectEqual(@as(usize, 2), first.rows.len);
    try testing.expectEqual(@as(i64, 712), first.rows[0].id);
    try testing.expectEqual(@as(i64, 713), first.rows[1].id);
    const last = first.rows[1];
    const second = try stack.db.feed(Account, &run, .{
        .where = .{ .id = .{ .in = &ids } },
        .order = .{ .balance = .desc, .id = .desc },
        .after = .{ .balance = last.balance, .id = last.id },
        .limit = 2,
    });
    try testing.expectEqual(@as(usize, 2), second.rows.len);
    try testing.expectEqual(@as(i64, 711), second.rows[0].id);
    try testing.expectEqual(@as(i64, 710), second.rows[1].id);
}

test "the startup check reads a domain as the type under it, and citext as text" {
    const gpa = testing.allocator;
    var live = (try Live.open(gpa)) orelse return error.SkipZigTest;
    defer live.close(gpa);

    const arena = live.arena.allocator();
    const home = "nilo_live_domains_" ++ mode_suffix;

    // `typname` of a domain column is the domain's own name, which no list
    // names, so a `Str` over `email_address` stopped a server whose table was
    // right. The introspection now follows `typbasetype`, through a domain
    // over a domain too (ADR 055).
    for ([_][]const u8{
        "DROP SCHEMA IF EXISTS " ++ home ++ " CASCADE",
        "CREATE SCHEMA " ++ home,
        "CREATE DOMAIN " ++ home ++ ".email_address AS text CHECK (position('@' in value) > 0)",
        "CREATE DOMAIN " ++ home ++ ".work_email AS " ++ home ++ ".email_address",
        "CREATE DOMAIN " ++ home ++ ".count AS integer",
    }) |statement| {
        var rows = try live.wire.run(arena, statement, .{}, null, null);
        live.wire.drain(&rows);
    }
    defer {
        var rows = live.wire.run(arena, "DROP SCHEMA IF EXISTS " ++ home ++ " CASCADE", .{}, null, null) catch null;
        if (rows) |*r| live.wire.drain(r);
    }

    // `citext` is an extension's type. It is created if the role may, and it
    // is left installed afterwards: the Debug and ReleaseSafe runs share the
    // database, and one dropping it under the other is a race, not a cleanup.
    // Without the privilege that half is skipped, the domains are not.
    const has_citext = blk: {
        var rows = live.wire.run(arena, "CREATE EXTENSION IF NOT EXISTS citext", .{}, null, null) catch break :blk false;
        live.wire.drain(&rows);
        break :blk true;
    };
    var made = false;
    if (has_citext) {
        var rows = live.wire.run(arena, "CREATE TABLE " ++ home ++ ".people (" ++
            "id bigint PRIMARY KEY, email " ++ home ++ ".email_address NOT NULL, " ++
            "work " ++ home ++ ".work_email, shout citext NOT NULL, visits " ++ home ++ ".count NOT NULL)", .{}, null, null) catch null;
        if (rows) |*r| {
            live.wire.drain(r);
            made = true;
        }
    }
    if (!made) {
        var rows = try live.wire.run(arena, "CREATE TABLE " ++ home ++ ".people (" ++
            "id bigint PRIMARY KEY, email " ++ home ++ ".email_address NOT NULL, " ++
            "work " ++ home ++ ".work_email, visits " ++ home ++ ".count NOT NULL)", .{}, null, null);
        live.wire.drain(&rows);
    }

    const columns = try live.wire.columnsOf(arena, dialect.Postgres.introspect, home, "people");
    try testing.expectEqualStrings("text", columns[1].udt);
    try testing.expectEqualStrings("text", columns[2].udt);
    try testing.expectEqualStrings("int4", columns[columns.len - 1].udt);

    const Domains = struct {
        pub const nilo_table = .{ .name = "people", .key = .id };

        id: i64,
        email: []const u8,
        work: ?[]const u8,
        visits: i32,
    };
    var problems: std.ArrayList(schema.Problem) = .empty;
    try testing.expectEqual(@as(usize, 0), try schema.compare(dialect.Postgres, Domains, columns, &problems, arena));

    // A domain is no looser than what is under it: a `Str` over the integer
    // one is still the mismatch this check is for.
    const Wrong = struct {
        pub const nilo_table = .{ .name = "people", .key = .id };

        id: i64,
        visits: []const u8,
    };
    try testing.expectEqual(@as(usize, 1), try schema.compare(dialect.Postgres, Wrong, columns, &problems, arena));
    try testing.expectEqualStrings("int4", problems.items[0].found);

    if (made) {
        try testing.expectEqualStrings("citext", columns[3].udt);
        const Shout = struct {
            pub const nilo_table = .{ .name = "people", .key = .id };

            id: i64,
            shout: []const u8,
        };
        try testing.expectEqual(@as(usize, 0), try schema.compare(dialect.Postgres, Shout, columns, &problems, arena));
    }
}

const dated_table = "nilo_live_dated_" ++ mode_suffix;

test "a feed after a cursor over a Date binds it through its cast and reads every page on Postgres" {
    // `.after` bound its cursor with a bare `$n` where every other condition
    // writes `bindAs`, and pg.zig has no `date` encoder: the first page has no
    // cursor and worked, and the second was a type error from the database.
    const gpa = testing.allocator;
    const url = live_config.database_url orelse return error.SkipZigTest;

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var db = db_mod.Db.init(gpa, url, .{ .size = 1, .connect_on_init = 1, .unchecked = true });
    defer db.deinit();
    try db.nilo_start(threaded.io(), .off);
    defer db.nilo_stop();

    var run: core.Run = .init(gpa);
    defer run.deinit();

    const Due = struct {
        pub const nilo_table = .{ .name = dated_table, .key = .id, .index = .{.{ .columns = .{ .due, .id } }} };
        id: i64,
        due: types.Date,
    };
    _ = try db.exec(&run, "DROP TABLE IF EXISTS \"" ++ dated_table ++ "\"", .{});
    defer _ = db.exec(&run, "DROP TABLE IF EXISTS \"" ++ dated_table ++ "\"", .{}) catch {};
    try migrate.createMissing(&db, &run, .{ .tables = &.{Due} });
    // Twenty-five rows over five days, five sharing each, so the cursor needs
    // the key as well as the day.
    for (0..25) |i| _ = try db.insert(Due, &run, .{
        .id = @as(i64, @intCast(i + 1)),
        .due = types.Date.fromDays(19_000 + @as(i32, @intCast(i / 5))),
    });

    var seen: [26]bool = @splat(false);
    var found = try db.feed(Due, &run, .{ .order = .{ .due = .asc, .id = .asc }, .limit = 4 });
    var total: usize = 0;
    while (true) {
        for (found.rows) |row| {
            try testing.expect(!seen[@intCast(row.id)]);
            seen[@intCast(row.id)] = true;
        }
        total += found.rows.len;
        if (!found.more) break;
        const last = found.rows[found.rows.len - 1];
        found = try db.feed(Due, &run, .{
            .order = .{ .due = .asc, .id = .asc },
            .after = .{ .due = last.due, .id = last.id },
            .limit = 4,
        });
    }
    try testing.expectEqual(@as(usize, 25), total);
}

const guarded_table = "nilo_live_guarded_" ++ mode_suffix;

test "a statement holding a given keeps one plan a combination, none of them the guard a generic plan cannot seek on" {
    // A kept plan goes generic after five calls, and on the generic plan
    // `("cust" = $1 OR $1 IS NULL)` cannot seek: with a table this size the
    // call that finally sets the filter read all of it (sql.md section 22).
    // One connection, so `pg_prepared_statements` is the pool's whole session.
    const gpa = testing.allocator;
    const url = live_config.database_url orelse return error.SkipZigTest;

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var db = db_mod.Db.init(gpa, url, .{ .size = 1, .connect_on_init = 1, .unchecked = true });
    defer db.deinit();
    try db.nilo_start(threaded.io(), .off);
    defer db.nilo_stop();

    var run: core.Run = .init(gpa);
    defer run.deinit();

    const Stock = struct {
        pub const nilo_table = .{ .name = guarded_table, .key = .id, .index = .{.{ .columns = .{.cust} }} };
        id: i64,
        cust: []const u8,
    };
    _ = try db.exec(&run, "DROP TABLE IF EXISTS \"" ++ guarded_table ++ "\"", .{});
    defer _ = db.exec(&run, "DROP TABLE IF EXISTS \"" ++ guarded_table ++ "\"", .{}) catch {};
    try migrate.createMissing(&db, &run, .{ .tables = &.{Stock} });
    for (0..30) |i| _ = try db.insert(Stock, &run, .{
        .id = @as(i64, @intCast(i + 1)),
        .cust = switch (i % 3) {
            0 => "c0",
            1 => "c1",
            else => "c2",
        },
    });

    const given = @import("where.zig").given;
    for (0..8) |_| try testing.expectEqual(@as(usize, 30), try db.count(Stock, &run, .{
        .where = .{ .cust = given(@as(?[]const u8, null)) },
    }));
    try testing.expectEqual(@as(usize, 10), try db.count(Stock, &run, .{
        .where = .{ .cust = given(@as(?[]const u8, "c1")) },
    }));
    try testing.expectEqual(@as(usize, 10), try db.count(Stock, &run, .{
        .where = .{ .cust = @as([]const u8, "c1") },
    }));

    const named = "SELECT count(*) FROM pg_prepared_statements WHERE statement LIKE '%" ++ guarded_table ++
        "%' AND statement NOT LIKE '%pg_prepared_statements%'";
    // The guard is cut out of the text per call (ADR 149): no kept plan holds
    // `("cust" = $1 OR $1 IS NULL)`, the form a generic plan cannot seek on.
    const guarded = try db.rawExactlyOne(i64, &run, named ++ " AND statement LIKE '% OR %IS NULL%'", .{});
    try testing.expectEqual(@as(i64, 0), guarded);
    // And each combination is a plan of its own: the filter left out, the
    // filter given, and the plain statement.
    const kept = try db.rawExactlyOne(i64, &run, named, .{});
    try testing.expect(kept >= 3);
}

const prefixed_table = "nilo_live_prefixed_" ++ mode_suffix;

test "istarts_with reads the case-folding unique as a range on Postgres, and a wildcard in the prefix is only itself" {
    // `ILIKE` over the bare column read no index; the unique is on
    // `lower("email") text_pattern_ops` and the prefix is written over that
    // expression (ADR 140, sql.md section 23).
    const gpa = testing.allocator;
    const url = live_config.database_url orelse return error.SkipZigTest;

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var db = db_mod.Db.init(gpa, url, .{ .size = 1, .connect_on_init = 1, .unchecked = true });
    defer db.deinit();
    try db.nilo_start(threaded.io(), .off);
    defer db.nilo_stop();

    var run: core.Run = .init(gpa);
    defer run.deinit();

    const Mailbox = struct {
        pub const nilo_table = .{
            .name = prefixed_table,
            .key = .id,
            .unique = .{.{ .columns = .{.email}, .ignoring_case = true }},
        };
        id: i64,
        email: []const u8,
    };
    _ = try db.exec(&run, "DROP TABLE IF EXISTS \"" ++ prefixed_table ++ "\"", .{});
    defer _ = db.exec(&run, "DROP TABLE IF EXISTS \"" ++ prefixed_table ++ "\"", .{}) catch {};
    try migrate.createMissing(&db, &run, .{ .tables = &.{Mailbox} });
    // Enough rows, and hex only, so no `zed`, `an` or `a_` is in the bulk.
    _ = try db.exec(
        &run,
        "INSERT INTO \"" ++ prefixed_table ++ "\" (id, email) " ++
            "SELECT n, md5(n::text) || '@x.dev' FROM generate_series(1, 20000) n",
        .{},
    );
    for ([_][]const u8{ "Ann@x.dev", "a_n@x.dev", "a%n@x.dev", "a\\n@x.dev" }, 0..) |email, i| {
        _ = try db.insert(Mailbox, &run, .{ .id = @as(i64, @intCast(20_001 + i)), .email = email });
    }
    _ = try db.exec(&run, "ANALYZE \"" ++ prefixed_table ++ "\"", .{});

    const plan = try db.explain(Mailbox, &run, .{
        .where = .{ .email = .{ .istarts_with = @as([]const u8, "abc1") } },
    });
    try testing.expect(std.mem.indexOf(u8, plan, "Index") != null);
    try testing.expect(std.mem.indexOf(u8, plan, "Seq Scan") == null);

    const Case = struct { prefix: []const u8, want: usize };
    for ([_]Case{
        .{ .prefix = "an", .want = 1 }, // `Ann`, since it folds case
        .{ .prefix = "AN", .want = 1 },
        .{ .prefix = "a_", .want = 1 }, // not `Ann`: `_` is not any character
        .{ .prefix = "a%", .want = 1 }, // not every `a…`
        .{ .prefix = "a\\", .want = 1 }, // the escape character, escaped first
        .{ .prefix = "zed", .want = 0 },
    }) |case| {
        const rows = try db.select(Mailbox, &run, .{ .where = .{ .email = .{ .istarts_with = case.prefix } } });
        try testing.expectEqual(case.want, rows.len);
    }

    // The unique still enforces what it always did, and serves `.ieq`.
    try testing.expectError(error.AlreadyExists, db.insert(Mailbox, &run, .{ .id = 30_000, .email = "ANN@X.DEV" }));
    const one = try db.select(Mailbox, &run, .{ .where = .{ .email = .{ .ieq = @as([]const u8, "ANN@x.dev") } } });
    try testing.expectEqual(@as(usize, 1), one.len);
}

const ends_table = "nilo_live_range_ends_" ++ mode_suffix;

test "a timestamp and a date before 1970 and at the ends of 0001 to 9999 survive Postgres and JSON both ways" {
    // The writer answered `null` for a moment before 1970 and the parser read
    // one, so a value that round-tripped through the column did not through a
    // response (ADR 127).
    const gpa = testing.allocator;
    const url = live_config.database_url orelse return error.SkipZigTest;

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var db = db_mod.Db.init(gpa, url, .{ .size = 1, .connect_on_init = 1, .unchecked = true });
    defer db.deinit();
    try db.nilo_start(threaded.io(), .off);
    defer db.nilo_stop();

    var run: core.Run = .init(gpa);
    defer run.deinit();

    const Ends = struct {
        pub const nilo_table = .{ .name = ends_table, .key = .id };
        id: i64,
        at: types.Timestamp,
        day: types.Date,
    };
    _ = try db.exec(&run, "DROP TABLE IF EXISTS \"" ++ ends_table ++ "\"", .{});
    defer _ = db.exec(&run, "DROP TABLE IF EXISTS \"" ++ ends_table ++ "\"", .{}) catch {};
    try migrate.createMissing(&db, &run, .{ .tables = &.{Ends} });

    const Case = struct { at: []const u8, day: []const u8 };
    for ([_]Case{
        .{ .at = "1969-12-31T23:59:59.999999Z", .day = "1969-12-31" },
        .{ .at = "1815-12-10T00:00:00.000001Z", .day = "1815-12-10" },
        .{ .at = "0001-01-01T00:00:00.000000Z", .day = "0001-01-01" },
        .{ .at = "9999-12-31T23:59:59.999999Z", .day = "9999-12-31" },
    }, 1..) |case, key| {
        const at = types.Timestamp.nilo_parse(case.at).?;
        const day = types.Date.nilo_parse(case.day).?;
        _ = try db.insert(Ends, &run, .{ .id = @as(i64, @intCast(key)), .at = at, .day = day });

        const back = (try db.find(Ends, &run, @as(i64, @intCast(key)))).?;
        try testing.expectEqual(at.micros, back.at.micros);
        try testing.expectEqual(day.days, back.day.days);

        // And through JSON: the text the response carries is the text sent in.
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try std.json.Stringify.value(back, .{}, &out.writer);
        try testing.expect(std.mem.indexOf(u8, out.written(), case.at) != null);
        try testing.expect(std.mem.indexOf(u8, out.written(), case.day) != null);
    }
}

test "the startup check's one query per schema answers what one query per table answers" {
    const gpa = testing.allocator;
    var live = (try Live.open(gpa)) orelse return error.SkipZigTest;
    defer live.close(gpa);

    const arena = live.arena.allocator();
    // A table that is there, one that is not, and the same table again in a
    // different place in the list: one answer each, in the order asked.
    const names = [_][]const u8{ table, "nilo_no_such_table", table };
    const many = try live.wire.columnsOfMany(arena, dialect.Postgres.introspect_all, null, &names);
    try testing.expectEqual(@as(usize, 3), many.len);
    try testing.expectEqual(@as(usize, 0), many[1].len);

    const one = try live.wire.columnsOf(arena, dialect.Postgres.introspect, null, table);
    try testing.expect(one.len > 0);
    for (&[_]usize{ 0, 2 }) |at| {
        try testing.expectEqual(one.len, many[at].len);
        for (one, many[at]) |want, got| {
            try testing.expectEqualStrings(want.name, got.name);
            try testing.expectEqualStrings(want.udt, got.udt);
            try testing.expectEqual(want.nullable, got.nullable);
        }
    }

    // And the same for the values of the enum types.
    const kinds = [_][]const u8{ role_type, "nilo_no_such_enum" };
    const labels = try live.wire.labelsOfMany(arena, dialect.Postgres.enum_values.?, &kinds);
    try testing.expectEqual(@as(usize, 2), labels.len);
    try testing.expectEqual(@as(usize, 3), labels[0].len);
    try testing.expectEqualStrings("moderator", labels[0][2]);
    try testing.expectEqual(@as(usize, 0), labels[1].len);
}

// -- an index built outside a transaction (ADR 269) --------------------------
//
// Every table, index and version number below is this build's own, for the
// reason the first fixture in this file is: both optimize modes run at once
// against one database.

fn versionFor(comptime base: i64) i64 {
    return base + (if (builtin.mode == .debug) 0 else 1);
}

/// A database of its own for the tests that build an index `CONCURRENTLY`.
///
/// **Not a convenience for the tests, a fact about Postgres**: a
/// `CREATE INDEX CONCURRENTLY` waits for every transaction in the whole
/// database that is older than it (`WaitForOlderSnapshots` is per database),
/// and those are lock waits, bounded by the `lock_timeout` this suite's URL
/// carries (ADR 239). A `DROP INDEX CONCURRENTLY` does the same and can
/// deadlock (`40P01`) with a build in the other optimize mode. In the shared
/// database every other live test, in both modes, is such a transaction, so
/// under load a build waited past ten seconds and failed. In a database that
/// only this test, in this mode, uses, no transaction is older than the build
/// but the build's own, which also makes a gate between the two modes
/// unnecessary: they no longer share a database.
///
/// The database is created when absent and kept between runs. Where the role
/// may not create one the test skips with a line saying why, and the shared
/// database is not used instead, because a build there is the flaky thing.
const OwnDatabase = struct {
    buf: [512]u8 = undefined,
    len: usize = 0,

    const name = "nilo_live_concurrently_" ++ mode_suffix;

    fn url(self: *const OwnDatabase) []const u8 {
        return self.buf[0..self.len];
    }

    fn open(gpa: std.mem.Allocator) !?OwnDatabase {
        const base = live_config.database_url orelse return null;
        var self: OwnDatabase = .{};
        // `scheme://authority/dbname?query`: the name is swapped, the rest kept.
        const after_scheme = (std.mem.indexOf(u8, base, "://") orelse return error.TestUnexpectedResult) + 3;
        const slash = std.mem.indexOfScalarPos(u8, base, after_scheme, '/') orelse return error.TestUnexpectedResult;
        const query = std.mem.indexOfScalarPos(u8, base, slash, '?') orelse base.len;
        self.len = (std.fmt.bufPrint(&self.buf, "{s}/{s}{s}", .{ base[0..slash], name, base[query..] }) catch return error.TestUnexpectedResult).len;

        // Its lock wait is one second where the suite's is ten, so the test
        // below can show a build outlasting it without a ten second sleep.
        const long = "lock_timeout%3D10s";
        if (std.mem.indexOf(u8, self.buf[0..self.len], long)) |at| {
            var rest: [512]u8 = undefined;
            const after = self.buf[at + long.len .. self.len];
            @memcpy(rest[0..after.len], after);
            const one = "lock_timeout%3D1s";
            @memcpy(self.buf[at..][0..one.len], one);
            @memcpy(self.buf[at + one.len ..][0..after.len], rest[0..after.len]);
            self.len = at + one.len + after.len;
        }

        var threaded: std.Io.Threaded = .init(gpa, .{});
        defer threaded.deinit();
        var admin = db_mod.Db.init(gpa, base, .{ .size = 1, .connect_on_init = 1, .unchecked = true });
        defer admin.deinit();
        try admin.nilo_start(threaded.io(), .off);
        defer admin.nilo_stop();
        var run: core.Run = .init(gpa);
        defer run.deinit();
        const there = (try admin.rawOne(bool, &run, "SELECT EXISTS (SELECT 1 FROM pg_database WHERE datname = $1)", .{@as([]const u8, name)})).?;
        if (!there) {
            _ = admin.exec(&run, "CREATE DATABASE \"" ++ name ++ "\"", .{}) catch |err| {
                std.log.warn("skipping: the role cannot CREATE DATABASE {s} ({s}), and a build CONCURRENTLY is not tried in the shared one", .{ name, @errorName(err) });
                return null;
            };
        }
        return self;
    }
};

fn forgetVersion(db: *db_mod.Db, run: *core.Run, number: i64) void {
    var buf: [96]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "DELETE FROM \"nilo_migrations\" WHERE \"version\" = {d}", .{number}) catch unreachable;
    _ = db.exec(run, text, .{}) catch {};
}

fn indexIsValid(db: *db_mod.Db, run: *core.Run, comptime quoted: []const u8) !?bool {
    return db.rawOne(bool, run, "SELECT indisvalid FROM pg_index WHERE indexrelid = to_regclass($1)", .{quoted});
}

/// `rows` rows into `table`, a text column `v` of distinct values and a column
/// `grp` that repeats every `rows / 2`, so a unique index on it fails.
fn fillBig(db: *db_mod.Db, run: *core.Run, comptime table_name: []const u8, rows: i64) !void {
    _ = try db.exec(run, "DROP TABLE IF EXISTS \"" ++ table_name ++ "\"", .{});
    _ = try db.exec(run, "CREATE TABLE \"" ++ table_name ++ "\" (\"id\" bigserial PRIMARY KEY, \"v\" text NOT NULL, \"grp\" int8 NOT NULL)", .{});
    _ = try db.exec(
        run,
        "INSERT INTO \"" ++ table_name ++ "\" (\"v\", \"grp\") SELECT md5(g::text), g % ($1 / 2) FROM generate_series(1, $1) g",
        .{rows},
    );
}

const Writing = struct {
    stop: std.atomic.Value(bool) = .init(false),
    building: std.atomic.Value(bool) = .init(false),
    during: std.atomic.Value(u32) = .init(0),
    total: std.atomic.Value(u32) = .init(0),
};

/// Inserts a row at a time until told to stop, counting the ones that began
/// and ended while a build was running.
fn writeWhile(db: *db_mod.Db, gpa: std.mem.Allocator, sql_text: []const u8, w: *Writing) void {
    var run = nilo.Run.init(gpa);
    defer run.deinit();
    while (!w.stop.load(.acquire)) {
        const was = w.building.load(.acquire);
        _ = db.exec(&run, sql_text, .{}) catch return;
        _ = w.total.fetchAdd(1, .monotonic);
        if (was and w.building.load(.acquire)) _ = w.during.fetchAdd(1, .monotonic);
    }
}

const big_rows: i64 = 1_000_000;
const big_table = "nilo_live_big_" ++ mode_suffix;
const big_index = "nilo_live_big_v_idx_" ++ mode_suffix;
const big_insert = "INSERT INTO \"" ++ big_table ++ "\" (\"v\", \"grp\") VALUES ('written meanwhile', 0)";

/// The writes that got through while `v` ran, on a table `fillBig` made.
fn writesDuring(stack: *Stack, gpa: std.mem.Allocator, run: *core.Run, v: migrate.Version, hash: []const u8) !struct { writes: u32, ms: i64 } {
    const io = stack.live.threaded.io();
    var w: Writing = .{};
    var task = io.concurrent(writeWhile, .{ &stack.db, gpa, big_insert, &w }) catch return error.SkipZigTest;
    // Let the writer be well under way before the build begins.
    try std.Io.sleep(io, .fromMilliseconds(50), .awake);
    const started = core.monotonicMicros();
    w.building.store(true, .release);
    const ran = migrate.apply(&stack.db, run, v, hash) catch |err| {
        w.building.store(false, .release);
        w.stop.store(true, .release);
        task.await(io);
        return err;
    };
    w.building.store(false, .release);
    const ms = @divFloor(core.monotonicMicros() - started, std.time.us_per_ms);
    w.stop.store(true, .release);
    task.await(io);
    try testing.expect(ran);
    return .{ .writes = w.during.load(.acquire), .ms = ms };
}

test "an index built outside a transaction lets writes through, where the one in a transaction stops them" {
    const gpa = testing.allocator;
    const own = (try OwnDatabase.open(gpa)) orelse return error.SkipZigTest;
    var stack = try Stack.openAt(gpa, own.url());
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();
    try migrate.ensureLedger(&stack.db, &run);

    const number = versionFor(990_020);
    const control = versionFor(990_022);
    forgetVersion(&stack.db, &run, number);
    forgetVersion(&stack.db, &run, control);
    defer forgetVersion(&stack.db, &run, number);
    defer forgetVersion(&stack.db, &run, control);
    defer _ = stack.db.exec(&run, "DROP TABLE IF EXISTS \"" ++ big_table ++ "\"", .{}) catch {};
    try fillBig(&stack.db, &run, big_table, big_rows);

    // The control: the same index in a version of the ordinary kind. Writes to
    // the table wait for the build, so almost none get through while it runs.
    const blocking = [_]migrate.Step{.{
        .kind = .create_index,
        .sql = "CREATE INDEX \"" ++ big_index ++ "_blocking\" ON \"" ++ big_table ++ "\" (\"v\")",
        .why = "index, the control",
    }};
    var d1: [64]u8 = undefined;
    const held = try writesDuring(stack, gpa, &run, .{ .number = control, .name = "blocking", .steps = &blocking }, migrate.hashOf("", &blocking, &d1));

    const outside = [_]migrate.Step{.{
        .kind = .create_index,
        .sql = "CREATE INDEX CONCURRENTLY IF NOT EXISTS \"" ++ big_index ++ "\" ON \"" ++ big_table ++ "\" (\"v\")",
        .why = "index, outside a transaction",
        .index = "\"" ++ big_index ++ "\"",
    }};
    var d2: [64]u8 = undefined;
    const free = try writesDuring(stack, gpa, &run, .{ .number = number, .name = "outside", .steps = &outside, .transactional = false }, migrate.hashOf("", &outside, &d2));


    // The build took long enough for the comparison to mean something.
    try testing.expect(held.ms > 100);
    try testing.expect(free.ms > 100);
    try testing.expect(held.writes <= 20);
    try testing.expect(free.writes >= 100);

    // And the index is whole, recorded, and was made with no transaction.
    try testing.expectEqual(@as(?bool, true), try indexIsValid(&stack.db, &run, "\"" ++ big_index ++ "\""));
    try testing.expect(try stack.db.find(migrate.Applied, &run, number) != null);
    // Run again, it is already recorded and does nothing.
    try testing.expect(!(try migrate.apply(&stack.db, &run, .{ .number = number, .name = "outside", .steps = &outside, .transactional = false }, migrate.hashOf("", &outside, &d2))));
}

const dup_table = "nilo_live_dups_" ++ mode_suffix;
const dup_first = "nilo_live_dups_v_idx_" ++ mode_suffix;
const dup_unique = "nilo_live_dups_grp_key_" ++ mode_suffix;

test "a build that fails halfway leaves an invalid index, which the next run drops and builds again" {
    const gpa = testing.allocator;
    const own = (try OwnDatabase.open(gpa)) orelse return error.SkipZigTest;
    var stack = try Stack.openAt(gpa, own.url());
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();
    try migrate.ensureLedger(&stack.db, &run);

    const number = versionFor(990_024);
    forgetVersion(&stack.db, &run, number);
    defer forgetVersion(&stack.db, &run, number);
    defer _ = stack.db.exec(&run, "DROP TABLE IF EXISTS \"" ++ dup_table ++ "\"", .{}) catch {};
    // Every `grp` appears twice, so a unique index over it cannot be built.
    try fillBig(&stack.db, &run, dup_table, 2_000);

    const steps = [_]migrate.Step{
        .{
            .kind = .create_index,
            .sql = "CREATE INDEX CONCURRENTLY IF NOT EXISTS \"" ++ dup_first ++ "\" ON \"" ++ dup_table ++ "\" (\"v\")",
            .why = "a plain index, which builds",
            .index = "\"" ++ dup_first ++ "\"",
        },
        .{
            .kind = .create_index,
            .sql = "CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS \"" ++ dup_unique ++ "\" ON \"" ++ dup_table ++ "\" (\"grp\")",
            .why = "a unique index over duplicates, which cannot",
            .index = "\"" ++ dup_unique ++ "\"",
        },
    };
    const v: migrate.Version = .{ .number = number, .name = "dups", .steps = &steps, .transactional = false };
    var digest: [64]u8 = undefined;
    const hash = migrate.hashOf("", &steps, &digest);

    // It fails, nothing is recorded, and what Postgres left is what it says
    // it leaves: the first index whole, the second there and invalid.
    try testing.expectError(error.AlreadyExists, migrate.apply(&stack.db, &run, v, hash));
    try testing.expect(try stack.db.find(migrate.Applied, &run, number) == null);
    try testing.expectEqual(@as(?bool, true), try indexIsValid(&stack.db, &run, "\"" ++ dup_first ++ "\""));
    try testing.expectEqual(@as(?bool, false), try indexIsValid(&stack.db, &run, "\"" ++ dup_unique ++ "\""));

    // Run again with the rows still wrong: the invalid one is dropped before
    // the build, the build fails the same way, and the same state is left.
    // `IF NOT EXISTS` alone would have passed over it and recorded the version.
    try testing.expectError(error.AlreadyExists, migrate.apply(&stack.db, &run, v, hash));
    try testing.expect(try stack.db.find(migrate.Applied, &run, number) == null);
    try testing.expectEqual(@as(?bool, false), try indexIsValid(&stack.db, &run, "\"" ++ dup_unique ++ "\""));

    // The rows are mended, and the same version, unchanged, now goes through.
    _ = try stack.db.exec(&run, "UPDATE \"" ++ dup_table ++ "\" SET \"grp\" = \"id\"", .{});
    try testing.expect(try migrate.apply(&stack.db, &run, v, hash));
    try testing.expectEqual(@as(?bool, true), try indexIsValid(&stack.db, &run, "\"" ++ dup_first ++ "\""));
    try testing.expectEqual(@as(?bool, true), try indexIsValid(&stack.db, &run, "\"" ++ dup_unique ++ "\""));
    try testing.expect(try stack.db.find(migrate.Applied, &run, number) != null);

    // Nothing is held: the lock was let go on every path out, so a version in
    // a transaction takes it at once.
    const after = [_]migrate.Step{.{ .kind = .data, .sql = "SELECT 1", .why = "" }};
    var d2: [64]u8 = undefined;
    try testing.expect(try migrate.apply(&stack.db, &run, .{ .number = versionFor(990_026), .name = "after", .steps = &after }, migrate.hashOf("", &after, &d2)));
    forgetVersion(&stack.db, &run, versionFor(990_026));
}

fn sleepStatement(db: *db_mod.Db, gpa: std.mem.Allocator) void {
    var run = nilo.Run.init(gpa);
    defer run.deinit();
    _ = db.exec(&run, "SELECT pg_sleep(3)", .{}) catch {};
}

test "a build waits out a transaction older than itself for longer than the connection's lock_timeout, and puts the setting back" {
    const gpa = testing.allocator;
    const own = (try OwnDatabase.open(gpa)) orelse return error.SkipZigTest;
    var stack = try Stack.openAt(gpa, own.url());
    defer stack.close(gpa);
    const io = stack.live.threaded.io();

    var run = nilo.Run.init(gpa);
    defer run.deinit();
    try migrate.ensureLedger(&stack.db, &run);
    // The connection is given one second, so the setting under test is the
    // one that matters: the sleeper below holds a snapshot for three.
    try testing.expectEqualStrings("1s", (try stack.db.rawOne([]const u8, &run, "SELECT current_setting('lock_timeout')", .{})).?);

    const number = versionFor(990_032);
    const older = "nilo_live_older_" ++ mode_suffix;
    forgetVersion(&stack.db, &run, number);
    defer forgetVersion(&stack.db, &run, number);
    defer _ = stack.db.exec(&run, "DROP TABLE IF EXISTS \"" ++ older ++ "\"", .{}) catch {};
    try fillBig(&stack.db, &run, older, 1_000);

    const steps = [_]migrate.Step{.{
        .kind = .create_index,
        .sql = "CREATE INDEX CONCURRENTLY IF NOT EXISTS \"" ++ older ++ "_v\" ON \"" ++ older ++ "\" (\"v\")",
        .why = "index",
        .index = "\"" ++ older ++ "_v\"",
    }};
    const v: migrate.Version = .{ .number = number, .name = "older", .steps = &steps, .transactional = false };
    var digest: [64]u8 = undefined;
    const hash = migrate.hashOf("", &steps, &digest);

    var sleeper = io.concurrent(sleepStatement, .{ &stack.db, gpa }) catch return error.SkipZigTest;
    try std.Io.sleep(io, .fromMilliseconds(300), .awake);
    const started = core.monotonicMicros();
    const ran = migrate.apply(&stack.db, &run, v, hash);
    const ms = @divFloor(core.monotonicMicros() - started, std.time.us_per_ms);
    sleeper.await(io);

    try testing.expect(try ran);
    try testing.expect(ms >= 2_000);
    try testing.expectEqual(@as(?bool, true), try indexIsValid(&stack.db, &run, "\"" ++ older ++ "_v\""));
    // Every connection of the pool has the setting it came with.
    for (0..4) |_| try testing.expectEqualStrings("1s", (try stack.db.rawOne([]const u8, &run, "SELECT current_setting('lock_timeout')", .{})).?);
}

test "two replicas applying a version outside a transaction build it once, each on a pool of one" {
    const gpa = testing.allocator;
    const own = (try OwnDatabase.open(gpa)) orelse return error.SkipZigTest;
    const url = own.url();

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var first = db_mod.Db.init(gpa, url, .{ .size = 1, .connect_on_init = 1, .unchecked = true });
    defer first.deinit();
    try first.nilo_start(io, .off);
    defer first.nilo_stop();
    var second = db_mod.Db.init(gpa, url, .{ .size = 1, .connect_on_init = 1, .unchecked = true });
    defer second.deinit();
    try second.nilo_start(io, .off);
    defer second.nilo_stop();

    var run = nilo.Run.init(gpa);
    defer run.deinit();
    try migrate.ensureLedger(&first, &run);

    const number = versionFor(990_028);
    forgetVersion(&first, &run, number);
    defer forgetVersion(&first, &run, number);
    defer _ = first.exec(&run, "DROP TABLE IF EXISTS \"" ++ big_table ++ "_pair\"", .{}) catch {};
    _ = try first.exec(&run, "DROP TABLE IF EXISTS \"" ++ big_table ++ "_pair\"", .{});
    _ = try first.exec(&run, "CREATE TABLE \"" ++ big_table ++ "_pair\" (\"id\" bigserial PRIMARY KEY, \"v\" text NOT NULL)", .{});
    _ = try first.exec(&run, "INSERT INTO \"" ++ big_table ++ "_pair\" (\"v\") SELECT md5(g::text) FROM generate_series(1, 400000) g", .{});

    // The second creation, not the first, is what the lock exists to stop: a
    // build under way looks like a failed one, and the replica that arrives
    // would drop the other's index from under it.
    const steps = [_]migrate.Step{.{
        .kind = .create_index,
        .sql = "CREATE INDEX CONCURRENTLY IF NOT EXISTS \"" ++ big_index ++ "_pair\" ON \"" ++ big_table ++ "_pair\" (\"v\")",
        .why = "index",
        .index = "\"" ++ big_index ++ "_pair\"",
    }};
    const v: migrate.Version = .{ .number = number, .name = "pair", .steps = &steps, .transactional = false };
    var digest: [64]u8 = undefined;
    const hash = migrate.hashOf("", &steps, &digest);

    var one = io.concurrent(applyAs, .{ &first, gpa, v, hash }) catch return error.SkipZigTest;
    try std.Io.sleep(io, .fromMilliseconds(100), .awake);
    var two = io.concurrent(applyAs, .{ &second, gpa, v, hash }) catch return error.SkipZigTest;

    const a = one.await(io);
    const b = two.await(io);
    try testing.expectEqual(Applying.ran, a);
    try testing.expectEqual(Applying.already, b);
    try testing.expectEqual(@as(?bool, true), try indexIsValid(&first, &run, "\"" ++ big_index ++ "_pair\""));
}

// -- a Problem accepted by name (ADR 270), against a real database ------------

const KeyedParent = struct {
    pub const nilo_table = .{ .name = "nilo_live_keyed_parents_" ++ mode_suffix, .key = .id };
    id: i64,
};

fn KeyedChild(comptime keyed: bool) type {
    return struct {
        pub const nilo_table = if (keyed) .{
            .name = "nilo_live_keyed_children_" ++ mode_suffix,
            .key = .id,
            .references = .{ .parent_id = .{ KeyedParent, .id } },
        } else .{
            .name = "nilo_live_keyed_children_" ++ mode_suffix,
            .key = .id,
        };
        id: i64,
        parent_id: i64,
    };
}

test "a key added to a column the table had is handled by a step of the person's, and the diff then stops raising it" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();
    const a = run.arena();
    try migrate.ensureLedger(&stack.db, &run);

    const children = "nilo_live_keyed_children_" ++ mode_suffix;
    const number = versionFor(990_030);
    forgetVersion(&stack.db, &run, number);
    defer forgetVersion(&stack.db, &run, number);
    _ = try stack.db.exec(&run, "DROP TABLE IF EXISTS \"" ++ children ++ "\"", .{});
    _ = try stack.db.exec(&run, "DROP TABLE IF EXISTS \"nilo_live_keyed_parents_" ++ mode_suffix ++ "\"", .{});
    defer _ = stack.db.exec(&run, "DROP TABLE IF EXISTS \"" ++ children ++ "\"", .{}) catch {};

    const D = dialect.Postgres;
    const before = comptime migrate.desiredOf(D, .{ .tables = &.{ KeyedParent, KeyedChild(false) } });
    const after = comptime migrate.desiredOf(D, .{ .tables = &.{ KeyedParent, KeyedChild(true) } });

    // The tables as the first version made them, with a row that has a parent.
    const made = try migrate.plan(a, D, before, migrate.snapshot.empty(D));
    for (made.steps) |s| _ = try stack.db.exec(&run, s.sql, .{});
    _ = try stack.db.exec(&run, "INSERT INTO \"nilo_live_keyed_parents_" ++ mode_suffix ++ "\" (\"id\") VALUES (1)", .{});
    _ = try stack.db.exec(&run, "INSERT INTO \"" ++ children ++ "\" (\"id\", \"parent_id\") VALUES (1, 1)", .{});

    // The types gained a key on a column that is there. The diff has no step,
    // and says so.
    const was = try migrate.snapshotOf(a, D, 1, before);
    const raised = try migrate.plan(a, D, after, was);
    try testing.expectEqual(@as(usize, 0), raised.steps.len);
    try testing.expectEqual(@as(usize, 1), raised.problems.len);
    try testing.expect(raised.problems[0].acceptable());

    // The person writes the step: the two-statement form the Problem names,
    // which they may put in two versions on a big table.
    const key = try raised.problems[0].key(a);
    try testing.expectEqual(@as(usize, 0), (try raised.unaccepted(a, &.{key})).len);
    const steps = [_]migrate.Step{
        .{ .kind = .data, .sql = "ALTER TABLE \"" ++ children ++ "\" ADD CONSTRAINT \"" ++ children ++ "_parent_id_fkey\" FOREIGN KEY (\"parent_id\") REFERENCES \"nilo_live_keyed_parents_" ++ mode_suffix ++ "\" (\"id\") NOT VALID", .why = "the key, without the scan" },
        .{ .kind = .data, .sql = "ALTER TABLE \"" ++ children ++ "\" VALIDATE CONSTRAINT \"" ++ children ++ "_parent_id_fkey\"", .why = "and the rows it covers" },
    };
    var digest: [64]u8 = undefined;
    try testing.expect(try migrate.apply(&stack.db, &run, .{ .number = number, .name = "key", .steps = &steps }, migrate.hashOf("", &steps, &digest)));

    // What `generate --accept` writes into the snapshot is the types as they
    // are, and the diff against it finds nothing.
    const accepted = try migrate.snapshotOf(a, D, 2, after);
    try testing.expect((try migrate.plan(a, D, after, accepted)).isEmpty());

    // The database now enforces the key the type declares.
    try testing.expectError(error.ForeignKeyViolated, stack.db.exec(&run, "INSERT INTO \"" ++ children ++ "\" (\"id\", \"parent_id\") VALUES (2, 99)", .{}));
}
