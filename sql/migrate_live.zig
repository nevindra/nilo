//! The migration runner against a real database, which here is a SQLite file.
//!
//! It is a file of its own for the same reason `deadline.zig` is: `migrate.zig`
//! runs under a plain `zig test` with no module graph, and everything in it is
//! either comptime or a diff between two values. Naming a Wire there would cost
//! that property. So the half that sends statements is tested here, where the
//! module graph already exists.
//!
//! **A file rather than `:memory:`**, and that is not incidental. `db.raw` is
//! routed by its first keyword and an in-memory database's URI `mode=` beats
//! the flags a reader was opened with, so a statement that goes the wrong way
//! quietly succeeds there and fails on a file
//! ([ADR 0074](../docs/adr/0074-one-writer-is-not-a-setting-it-is-the-database.md)).
//! A test that cannot fail the way production does is worse than no test.
//!
//! **No Engine anywhere.** `.in_fiber` means a statement runs on the thread it
//! is on, so these need `std.Io.Threaded` and nothing else — the same standing
//! as the rest of `zig build test-sql`.

const std = @import("std");
const core = @import("nilo_core");
const sql = @import("sql.zig");
const migrate = @import("migrate.zig");
const table_mod = @import("table.zig");
const types = @import("types.zig");

const testing = std.testing;
const Db = sql.Sqlite(.{ .threading = .in_fiber });

const Org = struct {
    pub const nilo_table = .{ .name = "orgs", .key = .id };

    id: i64,
    name: []const u8,
};

const User = struct {
    pub const nilo_table = .{
        .name = "users",
        .key = .id,
        .unique = .{.{ .columns = .{.email}, .ignoring_case = true }},
        .index = .{.created_at},
        .references = .{ .org_id = .{ Org, .id, .cascade } },
    };

    id: i64,
    org_id: i64,
    email: []const u8,
    nickname: ?[]const u8,
    created_at: types.Timestamp,
};

/// A database in a temporary directory, its pool open, and a Scope to run
/// through. By pointer, because `db` is handed out by address.
const Fixture = struct {
    dir: std.testing.TmpDir,
    path: [:0]const u8,
    threaded: std.Io.Threaded,
    db: Db,
    run: core.Run,

    fn init(gpa: std.mem.Allocator, name: []const u8) !*Fixture {
        const self = try gpa.create(Fixture);
        errdefer gpa.destroy(self);

        var dir = std.testing.tmpDir(.{});
        errdefer dir.cleanup();

        const path = try std.fmt.allocPrintSentinel(
            gpa,
            ".zig-cache/tmp/{s}/{s}.db",
            .{ dir.sub_path, name },
            0,
        );
        errdefer gpa.free(path);

        self.* = .{
            .dir = dir,
            .path = path,
            // The `Io` has to outlive every query, not just the open: it is
            // what the pool was opened with. So it is a field.
            .threaded = .init(gpa, .{}),
            .db = Db.init(gpa, path, .{ .size = 2 }),
            .run = .init(gpa),
        };
        try self.db.nilo_start(self.threaded.io(), .off);
        return self;
    }

    fn deinit(self: *Fixture, gpa: std.mem.Allocator) void {
        self.run.deinit();
        self.db.deinit();
        self.threaded.deinit();
        self.dir.cleanup();
        gpa.free(self.path);
        gpa.destroy(self);
    }
};

/// One version, and its hash as the first link of a chain.
///
/// Every test below that applies a single version wants both, and writing the
/// pair out each time buries what is being tested under bookkeeping.
fn lone(number: i64, name: []const u8, steps: []const migrate.Step, out: *[64]u8) struct {
    migrate.Version,
    []const u8,
} {
    const v: migrate.Version = .{ .number = number, .name = name, .steps = steps };
    return .{ v, migrate.hashOf("", v.steps, out) };
}

test "createMissing creates every table the types describe, in reference order" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa, "create");
    defer fx.deinit(gpa);

    // `User` first in the list and `orgs` created first anyway, because the
    // order is worked out from the references while compiling.
    try migrate.createMissing(&fx.db, &fx.run, &.{ User, Org });

    const org = try fx.db.insert(Org, &fx.run, .{ .name = "nodeflux" });
    const user = try fx.db.insert(User, &fx.run, .{
        .org_id = org.id,
        .email = "wati@example.dev",
        .nickname = null,
        .created_at = types.Timestamp.now(),
    });
    try testing.expect(user.id > 0);
    try testing.expectEqualStrings("wati@example.dev", user.email);
}

test "a table nilo created is a table nilo's own check accepts" {
    // **The loop this whole thing turns on.** `columnType` writes the first
    // entry of `accepts`, so a generated table has to pass the comparison
    // `db.checking` runs against the same Rows. If those two ever disagree,
    // `generate` writes a schema that stops the server at startup — which is
    // the worst failure this module could ship, and the reason this test exists
    // against a real catalog rather than against two lists in a unit test.
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa, "checked");
    defer fx.deinit(gpa);

    try migrate.createMissing(&fx.db, &fx.run, &.{ User, Org });

    try migrate.ensureLedger(&fx.db, &fx.run);

    // `checkSchema` is what `nilo_start` calls when `db.checking` has been set,
    // and it answers how many disagreements it found. Calling it directly
    // rather than opening the pool a second time: `nilo_start` opens one every
    // time it is called, so a test that ran it twice would leak the first.
    try testing.expectEqual(
        @as(usize, 0),
        try fx.db.checkSchema(&.{ User, Org, migrate.Applied }),
    );
}

test "createMissing run twice changes nothing, which is what a boot needs" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa, "twice");
    defer fx.deinit(gpa);

    try migrate.createMissing(&fx.db, &fx.run, &.{ Org, User });
    const org = try fx.db.insert(Org, &fx.run, .{ .name = "kept" });

    try migrate.createMissing(&fx.db, &fx.run, &.{ Org, User });

    // The row is still there, so nothing was recreated.
    const found = try fx.db.find(Org, &fx.run, org.id);
    try testing.expectEqualStrings("kept", found.?.name);
}

test "the case-folding unique is the one that stops two addresses differing only in case" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa, "folding");
    defer fx.deinit(gpa);

    try migrate.createMissing(&fx.db, &fx.run, &.{ Org, User });
    const org = try fx.db.insert(Org, &fx.run, .{ .name = "one" });

    _ = try fx.db.insert(User, &fx.run, .{
        .org_id = org.id,
        .email = "Wati@Example.dev",
        .nickname = null,
        .created_at = types.Timestamp.now(),
    });

    // Different bytes, same address. A plain UNIQUE takes this row.
    try testing.expectError(error.AlreadyExists, fx.db.insert(User, &fx.run, .{
        .org_id = org.id,
        .email = "wati@example.dev",
        .nickname = null,
        .created_at = types.Timestamp.now(),
    }));
}

test "a version applies once, records itself, and answers false the second time" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa, "apply");
    defer fx.deinit(gpa);

    try migrate.ensureLedger(&fx.db, &fx.run);

    const steps: []const migrate.Step = &.{
        .{
            .kind = .create_table,
            .sql = "CREATE TABLE \"widgets\" (\"id\" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL)",
            .why = "create widgets",
        },
    };

    var digest: [64]u8 = undefined;
    const v, const hash = lone(1, "create_widgets", steps, &digest);

    try testing.expect(try migrate.apply(&fx.db, &fx.run, v, hash));
    // Ten replicas booting together is nine of these.
    try testing.expect(!try migrate.apply(&fx.db, &fx.run, v, hash));

    const row = (try fx.db.find(migrate.Applied, &fx.run, 1)).?;
    try testing.expectEqualStrings("create_widgets", row.name);
    try testing.expectEqual(@as(usize, 64), row.hash.len);
    try testing.expect(row.applied_at.micros > 0);
    try testing.expectEqualStrings(hash, row.hash);
}

test "a step that fails takes the ledger row with it, so a half-applied version is not recorded" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa, "atomic");
    defer fx.deinit(gpa);

    try migrate.ensureLedger(&fx.db, &fx.run);

    var d1: [64]u8 = undefined;
    const made, const made_hash = lone(1, "make", &.{
        .{
            .kind = .create_table,
            .sql = "CREATE TABLE \"half\" (\"tag\" TEXT NOT NULL UNIQUE)",
            .why = "",
        },
    }, &d1);
    try testing.expect(try migrate.apply(&fx.db, &fx.run, made, made_hash));

    // The second row breaks the unique. Both steps are in one transaction, so
    // the first has to go back too, and nothing may end up in the ledger.
    //
    // **A constraint rather than a broken statement, and that is not a
    // softening of the test.** A statement the database refuses outright is
    // logged at `err` by the driver, and the test runner counts a single `err`
    // line as a failed run — so the version of this test that wrote
    // `CREATE TABLE "half"` twice could never pass, whatever the rollback did.
    // What is being held here is that the transaction takes everything with it,
    // and a duplicate row exercises exactly that.
    const steps: []const migrate.Step = &.{
        .{ .kind = .data, .sql = "INSERT INTO \"half\" (\"tag\") VALUES ('one')", .why = "" },
        .{ .kind = .data, .sql = "INSERT INTO \"half\" (\"tag\") VALUES ('one')", .why = "" },
    };
    var d2: [64]u8 = undefined;
    const broken, const broken_hash = lone(2, "broken", steps, &d2);
    try testing.expectError(
        error.AlreadyExists,
        migrate.apply(&fx.db, &fx.run, broken, broken_hash),
    );

    // The ledger never heard of version 2.
    try testing.expectEqual(@as(i64, 1), try migrate.headVersion(&fx.db, &fx.run));
    try testing.expectEqual(@as(?migrate.Applied, null), try fx.db.find(migrate.Applied, &fx.run, 2));

    // And the first INSERT went back with it, so the same first step can run
    // again as its own version and succeed.
    var d3: [64]u8 = undefined;
    const again, const again_hash = lone(2, "again", steps[0..1], &d3);
    try testing.expect(try migrate.apply(&fx.db, &fx.run, again, again_hash));
}

test "the head version is zero on a database nothing has migrated" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa, "head");
    defer fx.deinit(gpa);

    try migrate.ensureLedger(&fx.db, &fx.run);
    try testing.expectEqual(@as(i64, 0), try migrate.headVersion(&fx.db, &fx.run));

    const steps: []const migrate.Step = &.{
        .{ .kind = .create_table, .sql = "CREATE TABLE \"a\" (\"id\" INTEGER)", .why = "" },
    };
    var d3: [64]u8 = undefined;
    var d7: [64]u8 = undefined;
    const three, const three_hash = lone(3, "three", steps, &d3);
    const seven, const seven_hash = lone(7, "seven", &.{
        .{ .kind = .create_table, .sql = "CREATE TABLE \"b\" (\"id\" INTEGER)", .why = "" },
    }, &d7);
    _ = try migrate.apply(&fx.db, &fx.run, three, three_hash);
    _ = try migrate.apply(&fx.db, &fx.run, seven, seven_hash);
    try testing.expectEqual(@as(i64, 7), try migrate.headVersion(&fx.db, &fx.run));
}

test "a binary built for a version the database has not reached refuses to serve" {
    // The incident with one shape: the code went out before the migration did.
    // `expect` is one integer against one query, and it is the only thing in
    // this module that stops a process rather than a statement.
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa, "expect");
    defer fx.deinit(gpa);

    // `standing` rather than `expect` for the failing direction. The sentence
    // `expect` logs is the feature, and a test that provokes it would have the
    // suite count a deliberate `std.log.err` as a failure.
    const behind = try migrate.standing(&fx.db, &fx.run, 9);
    try testing.expectEqual(@as(i64, 0), behind.at);
    try testing.expectEqual(migrate.Standing.Verdict.behind, behind.verdict());

    var d9: [64]u8 = undefined;
    const nine, const nine_hash = lone(9, "nine", &.{
        .{ .kind = .create_table, .sql = "CREATE TABLE \"nine\" (\"id\" INTEGER)", .why = "" },
    }, &d9);
    _ = try migrate.apply(&fx.db, &fx.run, nine, nine_hash);
    try migrate.expect(&fx.db, &fx.run, 9);

    // A database ahead of the code is the middle of a two-stage deploy, and it
    // is allowed. Refusing it would make expand and contract impossible.
    try testing.expectEqual(
        migrate.Standing.Verdict.ahead,
        (try migrate.standing(&fx.db, &fx.run, 8)).verdict(),
    );
    try migrate.expect(&fx.db, &fx.run, 8);
}

test "the plan a diff produces is the plan that runs, end to end" {
    // The two halves meet here: `plan` writes statements with no database in
    // the room, and `apply` sends exactly those. Nothing in between rewrites
    // them, which is what makes a generated file readable and trustworthy.
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa, "endtoend");
    defer fx.deinit(gpa);

    try migrate.ensureLedger(&fx.db, &fx.run);

    const tables = comptime migrate.tablesOf(Db.Dialect, &.{ Org, User });
    const first = try migrate.plan(fx.run.arena(), Db.Dialect, tables, migrate.snapshot.empty(Db.Dialect));
    try testing.expectEqual(@as(usize, 0), first.problems.len);
    var d1: [64]u8 = undefined;
    const initial, const initial_hash = lone(1, "initial", first.steps, &d1);
    try testing.expect(try migrate.apply(&fx.db, &fx.run, initial, initial_hash));

    // The schema is now what the types say, so a second plan against the
    // snapshot those types produce is empty.
    const after = try migrate.snapshotOf(fx.run.arena(), Db.Dialect, 1, tables);
    const second = try migrate.plan(fx.run.arena(), Db.Dialect, tables, after);
    try testing.expect(second.isEmpty());

    // And the tables really are there.
    const org = try fx.db.insert(Org, &fx.run, .{ .name = "end" });
    try testing.expect(org.id > 0);
}

test "an added column is one ALTER, planned with no database and applied to one" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa, "altered");
    defer fx.deinit(gpa);

    const Before = struct {
        pub const nilo_table = .{ .name = "orgs", .key = .id };
        id: i64,
        name: []const u8,
    };
    const After = struct {
        pub const nilo_table = .{ .name = "orgs", .key = .id };
        id: i64,
        name: []const u8,
        note: ?[]const u8,
    };

    try migrate.ensureLedger(&fx.db, &fx.run);
    try migrate.createMissing(&fx.db, &fx.run, &.{Before});
    _ = try fx.db.insert(Before, &fx.run, .{ .name = "kept across the alter" });

    const a = fx.run.arena();
    const before = try migrate.snapshotOf(a, Db.Dialect, 1, comptime migrate.tablesOf(Db.Dialect, &.{Before}));
    const change = try migrate.plan(a, Db.Dialect, comptime migrate.tablesOf(Db.Dialect, &.{After}), before);

    try testing.expectEqual(@as(usize, 1), change.steps.len);
    var d2: [64]u8 = undefined;
    const noted, const noted_hash = lone(2, "add_note", change.steps, &d2);
    try testing.expect(try migrate.apply(&fx.db, &fx.run, noted, noted_hash));

    // The row survived, and the new column reads as null.
    const rows = try fx.db.select(After, &fx.run, .{});
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqualStrings("kept across the alter", rows[0].name);
    try testing.expectEqual(@as(?[]const u8, null), rows[0].note);
}

test "applyPending runs what is missing and leaves what is there, in order" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa, "pending");
    defer fx.deinit(gpa);

    const a = fx.run.arena();
    const all: []const migrate.Version = &.{
        .{ .number = 1, .name = "make_a", .steps = &.{
            .{ .kind = .create_table, .sql = "CREATE TABLE \"a\" (\"id\" INTEGER)", .why = "" },
        } },
        .{ .number = 2, .name = "add_b", .steps = &.{
            .{ .kind = .add_column, .sql = "ALTER TABLE \"a\" ADD COLUMN \"b\" TEXT", .why = "" },
        } },
        .{ .number = 3, .name = "make_c", .steps = &.{
            .{ .kind = .create_table, .sql = "CREATE TABLE \"c\" (\"id\" INTEGER)", .why = "" },
        } },
    };

    try migrate.ensureLedger(&fx.db, &fx.run);
    const first = try migrate.chainOf(a, all[0..2]);
    try testing.expectEqual(@as(usize, 2), try migrate.applyPending(&fx.db, &fx.run, first));
    try testing.expectEqual(@as(i64, 2), first.head());

    // The boot after the next deploy: two are there, one is not.
    const whole = try migrate.chainOf(a, all);
    try testing.expectEqual(@as(usize, 1), try migrate.applyPending(&fx.db, &fx.run, whole));
    try testing.expectEqual(@as(i64, 3), try migrate.headVersion(&fx.db, &fx.run));
    try testing.expectEqual(@as(i64, 3), whole.head());

    // The chain carries on from where the shorter one stopped: two versions of
    // the same prefix hash the same.
    try testing.expectEqualStrings(first.headHash(), whole.hashes[1]);

    // And a boot with nothing new does no work at all.
    try testing.expectEqual(@as(usize, 0), try migrate.applyPending(&fx.db, &fx.run, whole));
}

test "a version edited after it ran is drift, and so is every version after it" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa, "drift");
    defer fx.deinit(gpa);

    const a = fx.run.arena();
    const two: []const migrate.Version = &.{
        .{ .number = 1, .name = "make_a", .steps = &.{
            .{ .kind = .create_table, .sql = "CREATE TABLE \"a\" (\"id\" INTEGER)", .why = "" },
        } },
        .{ .number = 2, .name = "make_b", .steps = &.{
            .{ .kind = .create_table, .sql = "CREATE TABLE \"b\" (\"id\" INTEGER)", .why = "" },
        } },
    };

    try migrate.ensureLedger(&fx.db, &fx.run);
    const before = try migrate.chainOf(a, two);
    _ = try migrate.applyPending(&fx.db, &fx.run, before);
    try testing.expectEqual(@as(usize, 0), (try migrate.drift(&fx.db, &fx.run, before)).len);

    // Somebody fixes a typo in version 1, which has already run everywhere.
    // Version 2 is not touched.
    const patched: []const migrate.Version = &.{
        .{ .number = 1, .name = "make_a", .steps = &.{
            .{ .kind = .create_table, .sql = "CREATE TABLE \"a\" (\"id\" BIGINT)", .why = "" },
        } },
        two[1],
    };

    const moved = try migrate.drift(&fx.db, &fx.run, try migrate.chainOf(a, patched));
    // Both, and version 2 was not touched. That is the chain doing its job.
    try testing.expectEqual(@as(usize, 2), moved.len);
    try testing.expectEqual(@as(i64, 1), moved[0].version);
    try testing.expectEqual(@as(i64, 2), moved[1].version);
    try testing.expectEqualStrings(before.hashes[0], moved[0].recorded);
    try testing.expect(!std.mem.eql(u8, moved[0].recorded, moved[0].now));
}

test "`status` says `edited` for a version whose file no longer matches what ran" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa, "status");
    defer fx.deinit(gpa);

    const Tool = sql.cli.Tool(Db, &.{ User, Org });
    const two: []const migrate.Version = &.{
        .{ .number = 1, .name = "make_a", .steps = &.{
            .{ .kind = .create_table, .sql = "CREATE TABLE \"a\" (\"id\" INTEGER)", .why = "" },
        } },
        .{ .number = 2, .name = "make_b", .steps = &.{
            .{ .kind = .create_table, .sql = "CREATE TABLE \"b\" (\"id\" INTEGER)", .why = "" },
        } },
    };

    try migrate.ensureLedger(&fx.db, &fx.run);
    _ = try migrate.applyPending(&fx.db, &fx.run, try migrate.chainOf(fx.run.arena(), two));

    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const clean = try Tool.run(gpa, fx.threaded.io(), &w, .{ .command = .status }, &fx.db, two);
    try testing.expectEqual(sql.cli.ok, clean);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "applied 0001  make_a") != null);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "Nothing waiting.") != null);

    // The same two versions, one of them edited since it ran. `status` is the
    // command people run first, so it has to be the one that stops saying
    // "applied" — otherwise the only warning is a `verify` nobody typed.
    const patched: []const migrate.Version = &.{
        .{ .number = 1, .name = "make_a", .steps = &.{
            .{ .kind = .create_table, .sql = "CREATE TABLE \"a\" (\"id\" BIGINT)", .why = "" },
        } },
        two[1],
    };

    w = std.Io.Writer.fixed(&buf);
    const dirty = try Tool.run(gpa, fx.threaded.io(), &w, .{ .command = .status }, &fx.db, patched);
    try testing.expectEqual(sql.cli.acted, dirty);
    const text = w.buffered();
    try testing.expect(std.mem.indexOf(u8, text, "edited  0001  make_a") != null);
    try testing.expect(std.mem.indexOf(u8, text, "edited  0002  make_b") != null);
    try testing.expect(std.mem.indexOf(u8, text, "2 applied version(s) no longer match") != null);
    // And it points at the command that says which, rather than at nothing.
    try testing.expect(std.mem.indexOf(u8, text, "`db verify`") != null);
}
