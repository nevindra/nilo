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
//! ([ADR 065](../docs/adr/065-one-writer-is-not-a-setting-it-is-the-database.md)).
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
        return initWith(gpa, name, .{ .size = 2, .unchecked = true }, null);
    }

    /// `expect` is what `expecting` would be told before the boot, or null
    /// for a `Db` with no version guard.
    fn initWith(gpa: std.mem.Allocator, name: []const u8, opts: Db.Opts, expect: ?i64) !*Fixture {
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
            .db = Db.init(gpa, path, opts),
            .run = .init(gpa),
        };
        if (expect) |want| self.db.expecting(want);
        try self.db.nilo_start(self.threaded.io(), .off);
        // The two guards run after the boot work, which a fixture with no
        // App has none of (ADR 180): straight after the pool, then.
        try self.db.nilo_check(self.threaded.io());
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

// -- what the six new shapes do against a real database ------------------
//
// Every test below exists because the comptime half only proves the statement
// is the string it should be. Whether the *database* agrees is a different
// question, and it is the one that decided at least two of these designs:
// a pattern is escaped by three `replace` calls the database runs, and a blob
// is a call zqlite makes rather than a type nilo hands over.

const Doc = struct {
    pub const nilo_table = .{ .name = "docs", .key = .id };

    id: i64,
    name: []const u8,
    digest: sql.Bytes,
};

const Seat = struct {
    pub const nilo_table = .{ .name = "seats", .key = .{ .tenant_id, .id } };

    tenant_id: i64,
    id: i64,
    label: []const u8,
    views: i64,
};

const Partner = struct {
    pub const nilo_table = .{ .name = "partners", .key = .id };

    id: i64,
    name: []const u8,
};

const Capability = struct {
    pub const nilo_table = .{
        .name = "partner_capabilities",
        .key = .{ .partner_id, .capability },
        .references = .{ .partner_id = .{ Partner, .id } },
    };

    partner_id: i64,
    capability: []const u8,
};

const Slot = struct {
    pub const nilo_table = .{ .name = "slots", .key = .id };

    id: i64,
    label: []const u8,
    rank: ?i64,
};

/// The other Wire's answer to a `date`, and it is a different answer: SQLite
/// has no date type at all, so the column is `TEXT` and the ten characters
/// are what is stored. Both halves are `Date`'s own — `writeIso` on the way
/// in, `nilo_parse` on the way out — which is what makes the round trip a
/// test of the pair rather than of SQLite.
const Holiday = struct {
    pub const nilo_table = .{ .name = "holidays", .key = .id };

    id: i64,
    name: []const u8,
    falls_on: types.Date,
    observed_on: ?types.Date,
};

test "a date is TEXT on SQLite, and the day that went in is the day that comes out" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa, "dates");
    defer fx.deinit(gpa);

    try migrate.createMissing(&fx.db, &fx.run, .{ .tables = &.{Holiday} });

    // Before the epoch, which the ISO text spells the same way as any other
    // day and the `days` field holds as a negative.
    const made = try fx.db.insert(Holiday, &fx.run, .{
        .name = "proklamasi",
        .falls_on = types.Date.nilo_parse("1945-08-17").?,
        .observed_on = @as(?types.Date, null),
    });
    try testing.expectEqual(@as(i32, -8903), made.falls_on.days);

    const found = (try fx.db.find(Holiday, &fx.run, made.id)).?;
    try testing.expectEqual(@as(i32, -8903), found.falls_on.days);
    try testing.expectEqual(@as(?types.Date, null), found.observed_on);

    // The same loop every column type here has to close: `columnType` writes
    // what `accepts` reads out of, or a generated schema stops the server it
    // was generated for.
    try testing.expectEqual(@as(usize, 0), try fx.db.checkSchema(&.{Holiday}));
}

test "the ten characters sort as days, which is why the text is ISO and not local" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa, "datesort");
    defer fx.deinit(gpa);

    try migrate.createMissing(&fx.db, &fx.run, .{ .tables = &.{Holiday} });

    // `17/08/1945` would compare as text in whatever order the day of the
    // month happened to fall in. This is the whole reason the stored spelling
    // is the one `date` prints.
    for ([_][]const u8{ "2026-01-01", "1945-08-17", "2025-12-31" }) |iso| {
        _ = try fx.db.insert(Holiday, &fx.run, .{
            .name = iso,
            .falls_on = types.Date.nilo_parse(iso).?,
            .observed_on = @as(?types.Date, null),
        });
    }

    const after = try fx.db.select(Holiday, &fx.run, .{
        .where = .{ .falls_on = .{ .gte = types.Date.nilo_parse("2025-01-01").? } },
        .order = .{ .falls_on = .asc },
    });
    try testing.expectEqual(@as(usize, 2), after.len);
    try testing.expectEqualStrings("2025-12-31", after[0].name);
    try testing.expectEqualStrings("2026-01-01", after[1].name);
}

test "bytes go into a BLOB and come back the same bytes" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa, "bytes");
    defer fx.deinit(gpa);

    try migrate.createMissing(&fx.db, &fx.run, .{ .tables = &.{Doc} });

    // A NUL in the middle, a byte no UTF-8 decoder accepts, and a `%`. The
    // first is what a text read would truncate at, the second is what a text
    // read would mangle, and the third is only here because binary data does
    // not care what SQL thinks of it.
    const raw = [_]u8{ 0xff, 0x00, 0x25, 0x41, 0xfe, 0x00 };
    const made = try fx.db.insert(Doc, &fx.run, .{
        .name = "report",
        .digest = sql.Bytes.of(&raw),
    });
    try testing.expectEqualSlices(u8, &raw, made.digest.bytes);

    // And read back on its own, which is the path that goes through the
    // column-type check rather than through `RETURNING`.
    const found = (try fx.db.find(Doc, &fx.run, made.id)).?;
    try testing.expectEqualSlices(u8, &raw, found.digest.bytes);
    try testing.expectEqual(@as(usize, 6), found.digest.bytes.len);
}

test "the column a bytes Row creates is the column the check accepts" {
    // The same loop every column type here has to close: `columnType` writes
    // what `accepts` will read out of, or `generate` writes a schema that
    // stops the server it was generated for.
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa, "bytescheck");
    defer fx.deinit(gpa);

    try migrate.createMissing(&fx.db, &fx.run, .{ .tables = &.{Doc} });
    try testing.expectEqual(@as(usize, 0), try fx.db.checkSchema(&.{Doc}));
}

test "a row keyed by two columns is found by both of them" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa, "composite");
    defer fx.deinit(gpa);

    try migrate.createMissing(&fx.db, &fx.run, .{ .tables = &.{Seat} });

    _ = try fx.db.insert(Seat, &fx.run, .{
        .tenant_id = 1,
        .id = 7,
        .label = "one",
        .views = 0,
    });
    // The same id under another tenant, which is the whole reason the key
    // spans two columns and the row a single-column find would have got wrong.
    _ = try fx.db.insert(Seat, &fx.run, .{
        .tenant_id = 2,
        .id = 7,
        .label = "two",
        .views = 0,
    });

    const first = (try fx.db.find(Seat, &fx.run, .{ .tenant_id = 1, .id = 7 })).?;
    try testing.expectEqualStrings("one", first.label);
    const second = (try fx.db.find(Seat, &fx.run, .{ .tenant_id = 2, .id = 7 })).?;
    try testing.expectEqualStrings("two", second.label);
    try testing.expectEqual(
        @as(?Seat, null),
        try fx.db.find(Seat, &fx.run, .{ .tenant_id = 3, .id = 7 }),
    );
}

test "the composite PRIMARY KEY is a real constraint, not a clause nobody enforces" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa, "compositepk");
    defer fx.deinit(gpa);

    try migrate.createMissing(&fx.db, &fx.run, .{ .tables = &.{Seat} });
    _ = try fx.db.insert(Seat, &fx.run, .{
        .tenant_id = 1,
        .id = 7,
        .label = "one",
        .views = 0,
    });
    try testing.expectError(error.AlreadyExists, fx.db.insert(Seat, &fx.run, .{
        .tenant_id = 1,
        .id = 7,
        .label = "again",
        .views = 0,
    }));
}

test "a counter adds to its own value, so two updates in a row make two" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa, "counter");
    defer fx.deinit(gpa);

    try migrate.createMissing(&fx.db, &fx.run, .{ .tables = &.{Seat} });
    _ = try fx.db.insert(Seat, &fx.run, .{
        .tenant_id = 1,
        .id = 7,
        .label = "one",
        .views = 41,
    });

    // No read in front of either of these, which is the point: the shape that
    // needs one is the shape that races.
    _ = try fx.db.update(Seat, &fx.run, .{
        .set = .{ .views = .{ .plus = 1 } },
        .where = .{ .tenant_id = 1, .id = 7 },
    });
    const bumped = (try fx.db.find(Seat, &fx.run, .{ .tenant_id = 1, .id = 7 })).?;
    try testing.expectEqual(@as(i64, 42), bumped.views);

    _ = try fx.db.update(Seat, &fx.run, .{
        .set = .{ .views = .{ .minus = 2 } },
        .where = .{ .tenant_id = 1, .id = 7 },
    });
    const down = (try fx.db.find(Seat, &fx.run, .{ .tenant_id = 1, .id = 7 })).?;
    try testing.expectEqual(@as(i64, 40), down.views);
}

test "a search term holding a wildcard matches the wildcard and nothing else" {
    // **The bug this operator family was built for.** Wired straight to
    // `.like`, the term `100%` matches every label starting with `100` —
    // including `1000`, which nobody asked for and nothing reports.
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa, "search");
    defer fx.deinit(gpa);

    try migrate.createMissing(&fx.db, &fx.run, .{ .tables = &.{Slot} });
    for ([_][]const u8{ "100% cotton", "1000 threads", "a_b", "axb" }) |label| {
        _ = try fx.db.insert(Slot, &fx.run, .{ .label = label, .rank = null });
    }

    const percent = try fx.db.select(Slot, &fx.run, .{
        .where = .{ .label = .{ .icontains = @as([]const u8, "100%") } },
    });
    try testing.expectEqual(@as(usize, 1), percent.len);
    try testing.expectEqualStrings("100% cotton", percent[0].label);

    // `_` is the other one, and it is the one nobody remembers: unescaped it
    // matches any single character, so `a_b` would also find `axb`.
    const underscore = try fx.db.select(Slot, &fx.run, .{
        .where = .{ .label = .{ .icontains = @as([]const u8, "a_b") } },
    });
    try testing.expectEqual(@as(usize, 1), underscore.len);
    try testing.expectEqualStrings("a_b", underscore[0].label);
}

test "starts_with anchors, and a backslash in the term is still just a backslash" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa, "anchored");
    defer fx.deinit(gpa);

    try migrate.createMissing(&fx.db, &fx.run, .{ .tables = &.{Slot} });
    for ([_][]const u8{ "alpha", "beta alpha", "a\\b", "a%b" }) |label| {
        _ = try fx.db.insert(Slot, &fx.run, .{ .label = label, .rank = null });
    }

    const front = try fx.db.select(Slot, &fx.run, .{
        .where = .{ .label = .{ .istarts_with = @as([]const u8, "alpha") } },
    });
    try testing.expectEqual(@as(usize, 1), front.len);

    // The escape character itself, which is what the first of the three
    // `replace` calls is for — and the one that breaks if the order is wrong.
    const backslash = try fx.db.select(Slot, &fx.run, .{
        .where = .{ .label = .{ .icontains = @as([]const u8, "a\\b") } },
    });
    try testing.expectEqual(@as(usize, 1), backslash.len);
    try testing.expectEqualStrings("a\\b", backslash[0].label);
}

test "an exists narrows to the rows with a match over there, and counts the same" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa, "exists");
    defer fx.deinit(gpa);

    try migrate.createMissing(&fx.db, &fx.run, .{ .tables = &.{ Partner, Capability } });

    const one = try fx.db.insert(Partner, &fx.run, .{ .name = "acme" });
    const two = try fx.db.insert(Partner, &fx.run, .{ .name = "globex" });
    _ = try fx.db.insert(Capability, &fx.run, .{
        .partner_id = one.id,
        .capability = "vision",
    });
    _ = try fx.db.insert(Capability, &fx.run, .{
        .partner_id = two.id,
        .capability = "audio",
    });

    const with_vision = try fx.db.select(Partner, &fx.run, .{
        .where = .{ .exists = .{
            .{ .in = Capability, .where = .{ .capability = @as([]const u8, "vision") } },
        } },
        .order = .{ .name = .asc },
    });
    try testing.expectEqual(@as(usize, 1), with_vision.len);
    try testing.expectEqualStrings("acme", with_vision[0].name);

    // The count runs the same subquery, which is what makes a page's total
    // agree with the page — the reason `db.count` shares the walker at all.
    try testing.expectEqual(@as(usize, 1), try fx.db.count(Partner, &fx.run, .{
        .where = .{ .exists = .{
            .{ .in = Capability, .where = .{ .capability = @as([]const u8, "vision") } },
        } },
    }));

    const without = try fx.db.select(Partner, &fx.run, .{
        .where = .{ .not_exists = .{
            .{ .in = Capability, .where = .{ .capability = @as([]const u8, "vision") } },
        } },
    });
    try testing.expectEqual(@as(usize, 1), without.len);
    try testing.expectEqualStrings("globex", without[0].name);
}

test "an order term decides where NULLs go, rather than the database deciding" {
    // SQLite sorts NULLs first ascending and Postgres sorts them last, so this
    // is the one order term whose answer used to depend on which database was
    // underneath — and a page boundary that moves with the database is a page
    // that skips rows.
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa, "nulls");
    defer fx.deinit(gpa);

    try migrate.createMissing(&fx.db, &fx.run, .{ .tables = &.{Slot} });
    _ = try fx.db.insert(Slot, &fx.run, .{ .label = "has", .rank = 1 });
    _ = try fx.db.insert(Slot, &fx.run, .{ .label = "none", .rank = null });

    const last = try fx.db.select(Slot, &fx.run, .{ .order = .{ .rank = .asc_nulls_last } });
    try testing.expectEqualStrings("has", last[0].label);
    try testing.expectEqualStrings("none", last[1].label);

    const first = try fx.db.select(Slot, &fx.run, .{ .order = .{ .rank = .asc_nulls_first } });
    try testing.expectEqualStrings("none", first[0].label);
    try testing.expectEqualStrings("has", first[1].label);
}

test "createMissing creates every table the types describe, in reference order" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa, "create");
    defer fx.deinit(gpa);

    // `User` first in the list and `orgs` created first anyway, because the
    // order is worked out from the references while compiling.
    try migrate.createMissing(&fx.db, &fx.run, .{ .tables = &.{ User, Org } });

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

/// The rule a composite foreign key exists to hold: a Card belongs to a Board,
/// and both belong to the same org. One column cannot say that, and the
/// alternative is a `.data` step beside the `.unique` it needs — one rule in
/// two files and a string ([ADR 181](../docs/adr/181-the-marker-has-two-kinds-of-word.md)).
const Board = struct {
    pub const nilo_table = .{ .name = "boards", .key = .{ .org_id, .id } };

    org_id: i64,
    id: i64,
    title: []const u8,
};

/// And the other half of the round: this one points at `boards` by **name**,
/// which is what a program whose contexts may not import each other has to
/// write. The type check runs against the list `createMissing` is given.
const Card = struct {
    pub const nilo_table = .{
        .name = "cards",
        .key = .id,
        .references = .{
            .board = .{
                .columns = .{ .org_id, .board_id },
                .to = .{ "boards", .{ .org_id, .id } },
                .on_delete = .cascade,
            },
        },
    };

    id: i64,
    org_id: i64,
    board_id: i64,
    label: []const u8,
};

test "a foreign key of two columns is a constraint the database enforces, not a clause" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa, "compositefk");
    defer fx.deinit(gpa);

    // Cards before boards in the list, and boards created first anyway: the
    // order comes from the reference, and a reference written as text orders
    // exactly as one written as a type.
    try migrate.createMissing(&fx.db, &fx.run, .{ .tables = &.{ Card, Board } });
    // SQLite checks foreign keys only when it is told to, per connection.
    _ = try fx.db.exec(&fx.run, "PRAGMA foreign_keys = ON", .{});

    _ = try fx.db.insert(Board, &fx.run, .{ .org_id = 1, .id = 10, .title = "roadmap" });

    const card = try fx.db.insert(Card, &fx.run, .{
        .org_id = 1,
        .board_id = 10,
        .label = "port the schema",
    });
    try testing.expectEqual(@as(i64, 10), card.board_id);

    // The whole point, and the thing one column could not have refused: board
    // 10 exists, org 2 exists, and the pair does not. A single-column key on
    // `board_id` would have taken this row.
    try testing.expectError(error.ForeignKeyViolated, fx.db.insert(Card, &fx.run, .{
        .org_id = 2,
        .board_id = 10,
        .label = "somebody else's board",
    }));
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

    try migrate.createMissing(&fx.db, &fx.run, .{ .tables = &.{ User, Org } });

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

    try migrate.createMissing(&fx.db, &fx.run, .{ .tables = &.{ Org, User } });
    const org = try fx.db.insert(Org, &fx.run, .{ .name = "kept" });

    try migrate.createMissing(&fx.db, &fx.run, .{ .tables = &.{ Org, User } });

    // The row is still there, so nothing was recreated.
    const found = try fx.db.find(Org, &fx.run, org.id);
    try testing.expectEqualStrings("kept", found.?.name);
}

test "createMissing makes a schema's views after its tables, and a second run leaves them" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa, "views");
    defer fx.deinit(gpa);

    const schema: sql.Schema = .{
        .tables = &.{ Org, User },
        .views = &.{.{ .name = "org_names", .body = "SELECT name FROM orgs ORDER BY name" }},
    };
    try migrate.createMissing(&fx.db, &fx.run, schema);
    _ = try fx.db.insert(Org, &fx.run, .{ .name = "beta" });
    _ = try fx.db.insert(Org, &fx.run, .{ .name = "alpha" });
    try migrate.createMissing(&fx.db, &fx.run, schema);

    const names = try fx.db.raw([]const u8, &fx.run, "SELECT name FROM org_names", .{});
    try testing.expectEqual(@as(usize, 2), names.len);
    try testing.expectEqualStrings("alpha", names[0]);
}

test "the case-folding unique is the one that stops two addresses differing only in case" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa, "folding");
    defer fx.deinit(gpa);

    try migrate.createMissing(&fx.db, &fx.run, .{ .tables = &.{ Org, User } });
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

    // And `.ieq` is the lookup that unique is an index for (item 84): the
    // row, whatever case it is asked for in, found through the index rather
    // than by reading the table.
    const found = (try fx.db.one(User, &fx.run, .{
        .where = .{ .email = .{ .ieq = @as([]const u8, "WATI@example.DEV") } },
    })).?;
    try testing.expectEqualStrings("Wati@Example.dev", found.email);

    const Step = struct {
        pub const nilo_table = .projection;
        id: i64,
        parent: i64,
        notused: i64,
        detail: []const u8,
    };
    const where_ieq = comptime sql.on(Db.Dialect).selectFor(User, @TypeOf(.{
        .where = .{ .email = .{ .ieq = @as([]const u8, "") } },
    })).sql;
    try testing.expect(std.mem.endsWith(u8, where_ieq, "WHERE \"email\" COLLATE NOCASE = ?1 COLLATE NOCASE"));
    const plan = try fx.db.raw(Step, &fx.run,
        "EXPLAIN QUERY PLAN SELECT * FROM \"users\" WHERE \"email\" COLLATE NOCASE = $1 COLLATE NOCASE",
        .{@as([]const u8, "wati@example.dev")});
    try testing.expect(plan.len > 0);
    try testing.expect(std.mem.indexOf(u8, plan[0].detail, "USING INDEX") != null);
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

test "a Db told what to expect asks the ledger at boot, on the pool it just opened" {
    // ADR 180: the version guard is a call on the `Db`, so it runs inside
    // `listen()` on the server's own loop with nothing for the caller to
    // sequence — from `nilo_check`, after the boot work, which is where the
    // guard sees the ledger a migration in `before` just wrote (ADR 180).
    // What is pinned here is that boot *reaches* the ledger — a fresh file
    // has none, and after this boot it has one — and that level and ahead go
    // through. Behind is `migrate.expect`'s own refusal, pinned above
    // through `standing` for the reason given there.
    const gpa = testing.allocator;
    var fx = try Fixture.initWith(gpa, "expect_at_boot", .{ .size = 2, .unchecked = true }, 0);
    defer fx.deinit(gpa);

    // No `ensureLedger` here: boot made it, or this query has no table.
    try testing.expectEqual(@as(i64, 0), try migrate.headVersion(&fx.db, &fx.run));

    var d3: [64]u8 = undefined;
    const three, const three_hash = lone(3, "three", &.{
        .{ .kind = .create_table, .sql = "CREATE TABLE \"three\" (\"id\" INTEGER)", .why = "" },
    }, &d3);
    _ = try migrate.apply(&fx.db, &fx.run, three, three_hash);

    // A second `Db` on the same file, booted the way a deploy would be.
    var level = Db.init(gpa, fx.path, .{ .size = 1, .unchecked = true });
    defer level.deinit();
    level.expecting(3);
    try level.nilo_start(fx.threaded.io(), .off);
    try level.nilo_check(fx.threaded.io());

    // And one built before the migration that is already in: the middle of
    // a two-stage deploy, allowed.
    var ahead = Db.init(gpa, fx.path, .{ .size = 1, .unchecked = true });
    defer ahead.deinit();
    ahead.expecting(2);
    try ahead.nilo_start(fx.threaded.io(), .off);
    try ahead.nilo_check(fx.threaded.io());
}

test "the plan a diff produces is the plan that runs, end to end" {
    // The two halves meet here: `plan` writes statements with no database in
    // the room, and `apply` sends exactly those. Nothing in between rewrites
    // them, which is what makes a generated file readable and trustworthy.
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa, "endtoend");
    defer fx.deinit(gpa);

    try migrate.ensureLedger(&fx.db, &fx.run);

    const tables = comptime migrate.desiredOf(Db.Dialect, .{ .tables = &.{ Org, User } });
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
    try migrate.createMissing(&fx.db, &fx.run, .{ .tables = &.{Before} });
    _ = try fx.db.insert(Before, &fx.run, .{ .name = "kept across the alter" });

    const a = fx.run.arena();
    const before = try migrate.snapshotOf(a, Db.Dialect, 1, comptime migrate.desiredOf(Db.Dialect, .{ .tables = &.{Before} }));
    const change = try migrate.plan(a, Db.Dialect, comptime migrate.desiredOf(Db.Dialect, .{ .tables = &.{After} }), before);

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

test "addMissingColumns adds what the Row has and the table has not, typed as createMissing would" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa, "widened");
    defer fx.deinit(gpa);

    const Before = struct {
        pub const nilo_table = .{ .name = "downloads", .key = .id };
        id: i64,
        url: []const u8,
    };
    // The three fdm added after its first release: text that may be null, a
    // flag with a default, and a required count with a default.
    const After = struct {
        pub const nilo_table = .{
            .name = "downloads",
            .key = .id,
            .default = .{ .named = false, .tries = 0 },
        };
        id: i64,
        url: []const u8,
        sha256: ?[]const u8,
        named: bool,
        tries: i64,
    };

    try migrate.createMissing(&fx.db, &fx.run, .{ .tables = &.{Before} });
    _ = try fx.db.insert(Before, &fx.run, .{ .url = "http://a/1" });

    // Three columns, once; then nothing, which is what a boot needs.
    try testing.expectEqual(@as(usize, 3), try migrate.addMissingColumns(&fx.db, &fx.run, .{ .tables = &.{After} }));
    try testing.expectEqual(@as(usize, 0), try migrate.addMissingColumns(&fx.db, &fx.run, .{ .tables = &.{After} }));

    // The row survived, the defaults filled it, and the shape the check
    // accepts is the shape it would have accepted from `createMissing`.
    const rows = try fx.db.select(After, &fx.run, .{});
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqual(@as(?[]const u8, null), rows[0].sha256);
    try testing.expect(!rows[0].named);
    try testing.expectEqual(@as(i64, 0), rows[0].tries);
    try testing.expectEqual(@as(usize, 0), try fx.db.checkSchema(&.{After}));

    // A table that is not there is skipped, not altered.
    const Elsewhere = struct {
        pub const nilo_table = .{ .name = "nowhere", .key = .id };
        id: i64,
        note: ?[]const u8,
    };
    try testing.expectEqual(@as(usize, 0), try migrate.addMissingColumns(&fx.db, &fx.run, .{ .tables = &.{Elsewhere} }));
}

test "addMissingColumns refuses a required column with no default, and sends nothing" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa, "refused");
    defer fx.deinit(gpa);

    const Before = struct {
        pub const nilo_table = .{ .name = "downloads", .key = .id };
        id: i64,
        url: []const u8,
    };
    const After = struct {
        pub const nilo_table = .{ .name = "downloads", .key = .id };
        id: i64,
        url: []const u8,
        // Would be added first and is fine on its own …
        note: ?[]const u8,
        // … and this one has nothing to fill the rows already there.
        owner: []const u8,
    };

    try migrate.createMissing(&fx.db, &fx.run, .{ .tables = &.{Before} });
    try testing.expectError(error.NeedsBackfill, migrate.addMissingColumns(&fx.db, &fx.run, .{ .tables = &.{After} }));
    // One transaction: the column that was fine did not land either.
    try testing.expectEqual(@as(usize, 0), try migrate.addMissingColumns(&fx.db, &fx.run, .{ .tables = &.{Before} }));
    const live = try fx.db.liveColumns(&fx.run, null, "downloads");
    try testing.expectEqual(@as(usize, 2), live.len);
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

test "applyPending runs nothing once a version it has run was edited, not even the new one" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa, "pending-drift");
    defer fx.deinit(gpa);

    const a = fx.run.arena();
    const one: []const migrate.Version = &.{
        .{ .number = 1, .name = "make_a", .steps = &.{
            .{ .kind = .create_table, .sql = "CREATE TABLE \"a\" (\"id\" INTEGER)", .why = "" },
        } },
    };
    // No `ensureLedger` first: the in-process runner makes its own.
    try testing.expectEqual(@as(usize, 1), try migrate.applyPending(&fx.db, &fx.run, try migrate.chainOf(a, one)));

    // Version 1 edited after it ran, and a version 2 written after it. The
    // second was written against a schema the first no longer describes.
    const edited: []const migrate.Version = &.{
        .{ .number = 1, .name = "make_a", .steps = &.{
            .{ .kind = .create_table, .sql = "CREATE TABLE \"a\" (\"id\" BIGINT)", .why = "" },
        } },
        .{ .number = 2, .name = "make_b", .steps = &.{
            .{ .kind = .create_table, .sql = "CREATE TABLE \"b\" (\"id\" INTEGER)", .why = "" },
        } },
    };
    try testing.expectError(
        migrate.Error.SchemaDrift,
        migrate.applyPending(&fx.db, &fx.run, try migrate.chainOf(a, edited)),
    );
    try testing.expectEqual(@as(i64, 1), try migrate.headVersion(&fx.db, &fx.run));
    // `db migrate` refused this already; a program migrating itself at boot
    // used to apply version 2 on top of it.
    try testing.expectEqual(@as(usize, 0), (try fx.db.liveColumns(&fx.run, null, "b")).len);
}

const Parent = struct {
    pub const nilo_table = .{ .name = "parents", .key = .id };
    id: i64,
    name: []const u8,
};

const Child = struct {
    pub const nilo_table = .{
        .name = "children",
        .key = .id,
        .references = .{ .parent_id = .{ Parent, .id, .cascade } },
    };
    id: i64,
    parent_id: i64,
};

/// Two parents and a child of each, with `ON DELETE CASCADE` between them:
/// the shape a table rebuild on SQLite used to empty.
fn family(fx: *Fixture) !void {
    try migrate.ensureLedger(&fx.db, &fx.run);
    try migrate.createMissing(&fx.db, &fx.run, .{ .tables = &.{ Parent, Child } });
    _ = try fx.db.insert(Parent, &fx.run, .{ .id = 1, .name = "one" });
    _ = try fx.db.insert(Parent, &fx.run, .{ .id = 2, .name = "two" });
    _ = try fx.db.insert(Child, &fx.run, .{ .id = 1, .parent_id = 1 });
    _ = try fx.db.insert(Child, &fx.run, .{ .id = 2, .parent_id = 2 });
}

test "a version that rebuilds a table keeps the rows pointing at it" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa, "rebuild");
    defer fx.deinit(gpa);
    try family(fx);

    // The four statements the diff's own Problem spells out for a column
    // SQLite cannot change in place.
    var digest: [64]u8 = undefined;
    const v, const hash = lone(1, "rebuild_parents", &.{
        .{ .kind = .data, .why = "", .sql = "CREATE TABLE \"parents_new\" (\"id\" INTEGER PRIMARY KEY NOT NULL, \"name\" TEXT NOT NULL)" },
        .{ .kind = .data, .why = "", .sql = "INSERT INTO \"parents_new\" SELECT \"id\", \"name\" FROM \"parents\"" },
        .{ .kind = .data, .why = "", .sql = "DROP TABLE \"parents\"" },
        .{ .kind = .data, .why = "", .sql = "ALTER TABLE \"parents_new\" RENAME TO \"parents\"" },
    }, &digest);
    try testing.expect(try migrate.apply(&fx.db, &fx.run, v, hash));

    // With foreign keys on, that DROP deleted both parents first and the
    // cascade took both children with them, inside the version's own
    // transaction, and the COMMIT kept it.
    try testing.expectEqual(@as(usize, 2), (try fx.db.select(Child, &fx.run, .{})).len);
    try testing.expectEqual(@as(usize, 2), (try fx.db.select(Parent, &fx.run, .{})).len);

    // And they are on again for everything after: a child of nobody is refused.
    try testing.expectError(
        error.ForeignKeyViolated,
        fx.db.insert(Child, &fx.run, .{ .id = 3, .parent_id = 99 }),
    );
    // Still pointed at the rebuilt table, by name.
    _ = try fx.db.delete(Parent, &fx.run, .{ .where = .{ .id = 1 } });
    try testing.expectEqual(@as(usize, 1), (try fx.db.select(Child, &fx.run, .{})).len);
}

test "a version that leaves a row pointing at nothing is refused at its commit, and keeps nothing" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa, "rebuild-broken");
    defer fx.deinit(gpa);
    try family(fx);

    // A copy that skipped a row. With foreign keys off nothing stops it as it
    // runs, so the check before the COMMIT is the whole of what does.
    var digest: [64]u8 = undefined;
    const v, const hash = lone(1, "lossy_rebuild", &.{
        .{ .kind = .data, .why = "", .sql = "CREATE TABLE \"parents_new\" (\"id\" INTEGER PRIMARY KEY NOT NULL, \"name\" TEXT NOT NULL)" },
        .{ .kind = .data, .why = "", .sql = "INSERT INTO \"parents_new\" SELECT \"id\", \"name\" FROM \"parents\" WHERE \"id\" = 2" },
        .{ .kind = .data, .why = "", .sql = "DROP TABLE \"parents\"" },
        .{ .kind = .data, .why = "", .sql = "ALTER TABLE \"parents_new\" RENAME TO \"parents\"" },
    }, &digest);
    try testing.expectError(error.ForeignKeyViolated, migrate.apply(&fx.db, &fx.run, v, hash));

    try testing.expectEqual(@as(i64, 0), try migrate.headVersion(&fx.db, &fx.run));
    try testing.expectEqual(@as(usize, 2), (try fx.db.select(Parent, &fx.run, .{})).len);
    try testing.expectEqual(@as(usize, 2), (try fx.db.select(Child, &fx.run, .{})).len);
    // And the writer went back with its foreign keys on.
    try testing.expectError(
        error.ForeignKeyViolated,
        fx.db.insert(Child, &fx.run, .{ .id = 3, .parent_id = 99 }),
    );
}

test "`status` says `edited` for a version whose file no longer matches what ran" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa, "status");
    defer fx.deinit(gpa);

    const Tool = sql.cli.Tool(Db, .{ .tables = &.{ User, Org } });
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

// -- the `.sql` twin, applied by something that is not nilo (ADR 123) -----

test "a twin brings a database to head on its own, ledger row and all" {
    // **The one test that makes the twin a file rather than a claim.** Every
    // other check on it compares text against text; this one hands the
    // statements to a database in order and then asks `expect`, which is what a
    // server does at boot. A twin that does not satisfy that is a twin nobody
    // should apply.
    const gpa = testing.allocator;
    // One connection, so `BEGIN` and `COMMIT` in the file are the same
    // transaction rather than two connections out of a pool.
    var fx = try Fixture.initWith(gpa, "twin", .{ .size = 1, .unchecked = true }, null);
    defer fx.deinit(gpa);

    const migrations = @import("migrations.zig");
    const D = Db.Dialect;

    const tables = comptime migrate.desiredOf(D, .{ .tables = &.{ User, Org } });
    const change = try migrate.plan(fx.run.arena(), D, tables, migrate.snapshot.empty(D));

    var hash: [64]u8 = undefined;
    const text = try migrations.renderSql(
        fx.run.arena(),
        D,
        .{ .number = 1, .name = "initial", .steps = change.steps },
        "initial",
        migrate.hashOf("", change.steps, &hash),
        "0001_initial.zig",
    );

    // The split is the test's, not nilo's: the file is meant for `psql -f` and
    // friends, which read a script. What is under test is the statements and
    // their order.
    var it = std.mem.splitSequence(u8, text, ";\n");
    while (it.next()) |chunk| {
        const statement = std.mem.trim(u8, stripComments(chunk), " \n");
        if (statement.len == 0) continue;
        _ = try fx.db.exec(&fx.run, statement, .{});
    }

    // The tables are there, and so is the row that says so.
    try testing.expectEqual(@as(i64, 1), try migrate.headVersion(&fx.db, &fx.run));
    try migrate.expect(&fx.db, &fx.run, 1);

    const applied = (try fx.db.find(migrate.Applied, &fx.run, @as(i64, 1))).?;
    try testing.expectEqualStrings("initial", applied.name);
    try testing.expectEqualStrings(&hash, applied.hash);
    try testing.expectEqual(@as(i64, 0), applied.ms);

    // And the schema the twin built is one nilo's own check accepts, which is
    // the loop `createMissing` is held to as well.
    try testing.expectEqual(
        @as(usize, 0),
        try fx.db.checkSchema(&.{ User, Org, migrate.Applied }),
    );
}

/// The leading `--` lines of one chunk, dropped. A comment is part of the file
/// and not part of the statement, and only this test ever separates them.
fn stripComments(chunk: []const u8) []const u8 {
    var rest = chunk;
    while (true) {
        const start = std.mem.indexOfNone(u8, rest, " \n") orelse return "";
        rest = rest[start..];
        if (!std.mem.startsWith(u8, rest, "--")) return rest;
        const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse return "";
        rest = rest[nl + 1 ..];
    }
}
