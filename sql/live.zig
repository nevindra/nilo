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
const nilo = @import("nilo");
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
const table = "nilo_live_people_" ++ switch (builtin.mode) {
    .Debug => "debug",
    .ReleaseSafe => "releasesafe",
    .ReleaseFast => "releasefast",
    .ReleaseSmall => "releasesmall",
};

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
const setup =
    "DROP TABLE IF EXISTS " ++ table ++ ";" ++
    "CREATE TABLE " ++ table ++ " (" ++
    "  id bigint PRIMARY KEY," ++
    "  email text NOT NULL," ++
    "  handle text," ++
    "  age integer NOT NULL," ++
    "  seen_at timestamptz NOT NULL DEFAULT '2026-08-16T09:30:00Z'," ++
    "  token uuid," ++
    "  settings jsonb" ++
    ");" ++
    "INSERT INTO " ++ table ++ " (id, email, handle, age, token, settings) VALUES" ++
    "  (1, 'ada@example.dev', 'ada', 36, '550e8400-e29b-41d4-a716-446655440000', '{\"theme\":\"dark\"}')," ++
    "  (2, 'grace@example.dev', NULL, 45, NULL, NULL)," ++
    "  (3, 'kid@example.dev', 'kid', 11, '550e8400-e29b-41d4-a716-446655440001', '{\"theme\":\"light\"}');";

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
    const actual = try live.wire.columnsOf(arena, dialect.Postgres.introspect, table);

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
    const actual = try live.wire.columnsOf(arena, dialect.Postgres.introspect, table);

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
        var tx = try db.begin(c);
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
        var tx = try db.begin(c);
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

comptime {
    _ = wire_mod;
}
