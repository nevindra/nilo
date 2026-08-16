//! The tests that need a database, and the only ones in this module that
//! do (ADR 0039).
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
//! nothing outside `src/engine/` may name (ADR 0002). It does not have to
//! be zio's: `std.Io.Threaded` is std's own implementation, so these tests
//! build one, hand it to `nilo_start` exactly as `listen()` would, and
//! never start a server at all. That the Wire cannot tell the difference is
//! the point of it taking a `std.Io` rather than a runtime.

const std = @import("std");
const nilo = @import("nilo_http");
const live_config = @import("live_config");

const db_mod = @import("db.zig");
const dialect = @import("dialect.zig");
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

/// A schema of its own, so that a qualified name is tested against a table
/// that **only** exists there. A table in `public` with the same name would
/// let a broken `qualify` pass by finding the wrong relation, which is the
/// failure a test for this has to rule out rather than reproduce.
const other_schema = "nilo_live_other_" ++ mode_suffix;
const scoped_table = other_schema ++ ".widgets";

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
    "  balance numeric NOT NULL DEFAULT 0" ++
    ");" ++
    "INSERT INTO " ++ table ++ " (id, email, handle, age, token, settings, role) VALUES" ++
    "  (1, 'ada@example.dev', 'ada', 36, '550e8400-e29b-41d4-a716-446655440000', '{\"theme\":\"dark\"}', 'admin')," ++
    "  (2, 'grace@example.dev', NULL, 45, NULL, NULL, 'member')," ++
    "  (3, 'kid@example.dev', 'kid', 11, '550e8400-e29b-41d4-a716-446655440001', '{\"theme\":\"light\"}', 'moderator');" ++
    "DROP TABLE IF EXISTS " ++ list_table ++ ";" ++
    "CREATE TABLE " ++ list_table ++ " (" ++
    "  id bigint PRIMARY KEY," ++
    "  tags text[] NOT NULL," ++
    "  scores integer[]" ++
    ");" ++
    // Row 1 is the ordinary case, row 2 the two edge cases an array has that
    // nothing else does — empty, and null — and rows 3 and 4 are the two
    // shapes Postgres allows and a Zig slice cannot hold.
    "INSERT INTO " ++ list_table ++ " (id, tags, scores) VALUES" ++
    "  (1, ARRAY['urgent','billing'], ARRAY[10,20,30])," ++
    "  (2, ARRAY[]::text[], NULL)," ++
    "  (3, ARRAY['solo',NULL], NULL)," ++
    "  (4, ARRAY['deep'], ARRAY[[1,2],[3,4]]);" ++
    "DROP SCHEMA IF EXISTS " ++ other_schema ++ " CASCADE;" ++
    "CREATE SCHEMA " ++ other_schema ++ ";" ++
    "CREATE TABLE " ++ scoped_table ++ " (" ++
    "  id bigint PRIMARY KEY," ++
    "  label text NOT NULL" ++
    ");" ++
    "INSERT INTO " ++ scoped_table ++ " (id, label) VALUES (1, 'in another schema');";

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

        var wire = try postgres.Wire.open(threaded.io(), gpa, url, .{ .size = 2 });
        errdefer wire.close();

        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();

        // The fixture is several statements, which the extended protocol
        // will not take in one message, so they go one at a time.
        var it = std.mem.splitScalar(u8, setup, ';');
        while (it.next()) |raw| {
            const statement = std.mem.trim(u8, raw, " \n\r\t");
            if (statement.len == 0) continue;
            var rows = try wire.run(arena.allocator(), statement, .{});
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

    var rows = try live.wire.run(live.arena.allocator(), stmt.sql, .{@as(i32, 18)});
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
        var rows = try live.wire.run(arena, all, .{});
        try testing.expect(try live.wire.next(&rows));
        live.wire.drain(&rows);
    }

    var rows = try live.wire.run(arena, all, .{});
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
    // ADR 0005's table gives `AlreadyExists` a 409 and nothing else a
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
    // `!?Person` a whole endpoint (ADR 0024).
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

test "the schema check runs from nilo_start and passes on a table that agrees" {
    const gpa = testing.allocator;
    var live = (try Live.open(gpa)) orelse return error.SkipZigTest;
    defer live.close(gpa);

    var db = db_mod.Db.init(gpa, "already open", .{});
    db.wire = live.wire;
    db.checking(&.{Person});

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

// -- the column type nothing checks at startup ----------------------------

/// The Row that reads `role`, and **`Role` is missing `moderator` on
/// purpose** — the fixture's third row has it. This is a Zig enum that has
/// fallen behind its Postgres one, which is what an `ALTER TYPE … ADD VALUE`
/// leaves behind and the only way this column type goes wrong.
const Staff = struct {
    pub const nilo_table = .{ .name = table, .key = .id };

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
    // a panic (ADR 0008). One request failing is the whole of the fix.
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

comptime {
    _ = wire_mod;
}
