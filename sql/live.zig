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
//! being run every thirty seconds. CI sets the variable, so the coverage is
//! not optional there.
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
const dialect = @import("dialect.zig");
const migrate = @import("migrate.zig");
const postgres = @import("postgres.zig");
const schema = @import("schema.zig");
const types = @import("types.zig");
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
    .Debug => "debug",
    .ReleaseSafe => "releasesafe",
    .ReleaseFast => "releasefast",
    .ReleaseSmall => "releasesmall",
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
    pub const nilo_table = .{ .name = table, .key = .id };

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

    fn close(self: *Live, gpa: std.mem.Allocator) void {
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
    try tx.commit();
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
        const live = (try Live.open(gpa)) orelse return null;
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
        "[{\"id\":1,\"seen_at\":\"2026-08-16T09:30:00Z\"," ++
            "\"token\":\"550e8400-e29b-41d4-a716-446655440000\"," ++
            "\"settings\":{\"theme\":\"dark\"}}," ++
            "{\"id\":2,\"seen_at\":\"2026-08-16T09:30:00Z\"," ++
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
        "[{\"id\":2,\"seen_at\":\"2026-08-17T09:30:00Z\"," ++
            "\"token\":\"11111111-2222-3333-4444-555555555555\"," ++
            "\"settings\":{\"theme\":\"midnight\"}}]",
        answer.body,
    );
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
        "1:2026-08-16T09:30:00Z:550e8400-e29b-41d4-a716-446655440000;",
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

test "a slice of optionals reads the array the strict one refused" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    const found = try stack.db.select(Loose, &run, .{ .where = .{ .id = @as(i64, 3) } });
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqual(@as(usize, 2), found[0].tags.len);
    try testing.expectEqualStrings("solo", found[0].tags[0].?.view());
    try testing.expectEqual(@as(?nilo.Str, null), found[0].tags[1]);
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
    };
    id: i64,
    url: []const u8,
    sha256: ?[]const u8,
    named: bool,
    tries: i64,
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
    try testing.expectEqual(@as(usize, 3), try migrate.addMissingColumns(&db, &run, .{ .tables = &.{Widened} }));
    try testing.expectEqual(@as(usize, 0), try migrate.addMissingColumns(&db, &run, .{ .tables = &.{Widened} }));

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
    try testing.expectEqual(@as(usize, 5), names.len);
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

test "an empty batch is a statement that stores nothing, not a special case" {
    const gpa = testing.allocator;
    var stack = (try Stack.open(gpa)) orelse return error.SkipZigTest;
    defer stack.close(gpa);

    var run = nilo.Run.init(gpa);
    defer run.deinit();

    const before = try stack.db.count(Person, &run, .{});
    const none: []const Newcomer = &.{};
    const stored = try stack.db.insertMany(Person, &run, none);

    // `unnest` of empty arrays yields no rows, so the statement runs, inserts
    // nothing and answers with nothing. Writing a `if (rows.len == 0) return`
    // here would be a second answer to a question the database already has
    // one for.
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

    // A name that is not one never reaches the database, and neither does a
    // statement with more placeholders than values.
    var bad = stack.db.compose(&run);
    try testing.expectError(error.NotAnIdentifier, bad.ident("people; DROP TABLE people"));
    try testing.expectError(error.ParamCountMismatch, stack.db.composed(i64, &run, s, .{}));
}

// -- shaped Rows ---------------------------------------------------------
//
// What SQLite cannot say about ADR 218: that `sum` over a `bigint` comes
// back as the `numeric` Postgres makes of it unless it is cast, that a list
// of uuids is one `uuid[]` parameter `unnest` numbers, and that a presence
// test reads as a `bool`.

const ShapeCustomer = struct {
    pub const nilo_table = .{ .name = "nilo_shape_customers" };
    id: i64,
    name: []const u8,
};

const ShapeOrder = struct {
    pub const nilo_table = .{
        .name = "nilo_shape_orders",
        .references = .{ .customer_id = .{ ShapeCustomer, .id }, .referrer_id = .{ ShapeCustomer, .id } },
    };
    id: types.Uuid,
    customer_id: i64,
    referrer_id: ?i64,
    total: i64,
    weight: f32,
};

const ShapeLine = struct {
    pub const nilo_table = .{ .name = "nilo_shape_lines", .references = .{ .order_id = .{ ShapeOrder, .id } } };
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

const shape_setup = [_][]const u8{
    "DROP TABLE IF EXISTS nilo_shape_lines",
    "DROP TABLE IF EXISTS nilo_shape_orders",
    "DROP TABLE IF EXISTS nilo_shape_customers",
    "CREATE TABLE nilo_shape_customers (id bigint PRIMARY KEY, name text NOT NULL)",
    "CREATE TABLE nilo_shape_orders (id uuid PRIMARY KEY, customer_id bigint NOT NULL, " ++
        "referrer_id bigint, total bigint NOT NULL, weight real NOT NULL)",
    "CREATE TABLE nilo_shape_lines (id bigint PRIMARY KEY, order_id uuid NOT NULL, sku text NOT NULL)",
    "INSERT INTO nilo_shape_customers VALUES (1, 'Acme'), (2, 'Borealis')",
    "INSERT INTO nilo_shape_orders VALUES " ++
        "('00000000-0000-7000-8000-000000000001', 1, 2, 100, 1.5), " ++
        "('00000000-0000-7000-8000-000000000002', 1, NULL, 250, 2.5), " ++
        "('00000000-0000-7000-8000-000000000003', 2, 1, 40, 0.5)",
    "INSERT INTO nilo_shape_lines VALUES " ++
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

    for (shape_setup[0..3]) |text| _ = try stack.db.exec(&run, text, .{});
}
