//! What the last `generate` believed the schema was, as a file the repository
//! holds ([ADR 123](../docs/adr/123-a-migration-is-a-diff-against-a-snapshot.md)).
//!
//! **This is the file that makes `generate` need no database.** A diff has two
//! sides: the caller's types, which are in the binary, and what the schema was
//! before, which has to come from somewhere. Every other tool asks a database
//! for the second half, and then a diff needs a server running, in CI as well
//! as on a laptop, and Prisma needs a *second* database to compute it in. Here
//! the second half is `migrations/snapshot.zon`, committed beside the steps
//! that produced it.
//!
//! Two things fall out of that, and both are the reason rather than a bonus:
//!
//! - `generate` and `check` run on a plane. They read files and nothing else.
//! - Two branches that both generate against the same parent **conflict in
//!   git**, in this file, which is a conflict worth having. A tool that asks
//!   the database instead finds out when the second one is applied.
//!
//! ## The format is `.zon`, and that is not a shrug
//!
//! Zig's own object notation, so there is no schema to invent, `std.zon` reads
//! and writes it, and a person can read the file. `std.zon` also omits a field
//! that equals its default, which is why `table.Desc` gives defaults to the
//! four lists: a table with no indexes says nothing about indexes, so the file
//! stays about as long as the schema is.
//!
//! **A snapshot is a `Desc`, not a shape of its own.** The same struct the
//! types compile to is the struct that is written down, so there is one
//! description of a table rather than two that have to agree. The one field
//! that does not go in is `row`, the Zig type name: renaming a struct would
//! otherwise read as a schema change, and it is not one.

const std = @import("std");
const table_mod = @import("table.zig");

const Desc = table_mod.Desc;

/// The whole file.
pub const Doc = struct {
    /// The version the last `generate` wrote. Zero for a repository that has
    /// generated nothing yet, which is also what `empty` is.
    version: u32 = 0,
    /// Which Dialect the column types are spelled in.
    ///
    /// It is here because a snapshot taken against Postgres cannot be diffed
    /// against SQLite types: `int8` and `INTEGER` are the same column and not
    /// the same text, so every column would read as changed. Catching that with
    /// one string compare beats handing somebody a migration that rewrites
    /// their whole schema.
    dialect: []const u8,
    tables: []const Desc = &.{},
    /// The three lists a `sql.Schema` carries beside its tables (ADR 181),
    /// each with a default so a file written before they existed reads as
    /// one with none. A function and a view go in as a name and a hash, the
    /// way a check does.
    extensions: []const []const u8 = &.{},
    functions: []const table_mod.NamedText = &.{},
    views: []const table_mod.NamedText = &.{},

    pub fn table(self: Doc, schema: ?[]const u8, name: []const u8) ?Desc {
        for (self.tables) |t| {
            if (!std.mem.eql(u8, t.table, name)) continue;
            if (sameSchema(t.schema, schema)) return t;
        }
        return null;
    }
};

/// A repository that has generated nothing yet. Diffing against this is what
/// makes the first `generate` write a `CREATE TABLE` for everything.
pub fn empty(comptime D: type) Doc {
    return .{ .version = 0, .dialect = D.name, .tables = &.{} };
}

fn sameSchema(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

/// The line the file opens with.
///
/// It says *generated* and it says *committed*, because the two together are
/// the whole of what somebody needs to know before they touch it: editing it by
/// hand is allowed and is how a `pull` gets fixed up, and it will be rewritten
/// by the next `generate`.
pub const header =
    \\// Written by `db generate`, and committed.
    \\//
    \\// This is what the last generate believed the schema was. It is the other
    \\// half of every diff, which is why a generate needs no database — and why
    \\// two branches that both generate will conflict here rather than at deploy.
    \\// Editing it by hand is allowed; the next generate rewrites it.
    \\
    \\
;

/// The file, as text. Caller frees.
pub fn render(gpa: std.mem.Allocator, doc: Doc) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();

    try aw.writer.writeAll(header);
    // `emit_default_optional_fields = false` is the whole reason the file stays
    // readable: a column that is not null, not a key and not generated says
    // only its name and its type.
    try std.zon.stringify.serialize(doc, .{ .emit_default_optional_fields = false }, &aw.writer);
    try aw.writer.writeAll("\n");
    return aw.toOwnedSlice();
}

/// Where the `Doc` that came back was written in the shape this version
/// writes, or in one an older nilo wrote and this one still reads.
pub const Origin = enum { current, upgraded };

/// Read one back.
///
/// `diag` is optional and worth passing: `std.zon` formats a parse failure with
/// the line, the column and the offending text, which is a better sentence than
/// anything this file would write about a file somebody edited. **Every caller
/// that shows a person the failure passes one** — `sql/cli.zig` does, and a
/// `null` there is how a stack trace reached a user once.
///
/// **The `Doc` and the diagnostics are allocated out of `arena` and given back
/// with it.** `std.zon` allocates a result and its diagnostics in one arena
/// since Zig 0.17, so nothing here can be freed one piece at a time.
pub fn parse(
    arena: std.mem.Allocator,
    text: [:0]const u8,
    diag: ?*std.zon.parse.Diagnostics,
) !Doc {
    return parseWith(arena, text, diag, null);
}

/// The same, saying which shape the file turned out to be in.
pub fn parseWith(
    arena: std.mem.Allocator,
    text: [:0]const u8,
    diag: ?*std.zon.parse.Diagnostics,
    origin: ?*Origin,
) !Doc {
    // `std.zon` fills a `Diagnostics` whether or not a caller wants it, so a
    // caller that passed none gets one it never reads.
    var unread: std.zon.parse.Diagnostics = undefined;
    if (std.zon.parse.fromSlice(Doc, .{
        .gpa = arena,
        .arena = arena,
        .source = text,
        .diagnostics = diag orelse &unread,
    })) |doc| {
        if (origin) |o| o.* = .current;
        return doc;
    } else |err| {
        if (err != error.ParseZon) return err;
        // The older shape, tried second and with no `diag` of its own: the
        // caller's is already full of what is wrong with the file read as the
        // current shape, which is the message they want when this fails too.
        const older = upgraded(arena, text) catch return err;
        if (origin) |o| o.* = .upgraded;
        return older;
    }
}

/// v0.4.0's shape, which is the one field rename this module has made
/// ([ADR 181](../docs/adr/181-the-marker-has-two-kinds-of-word.md)).
///
/// **Read, never written**, and it is here because the alternative is a dead
/// end rather than an inconvenience. `db generate` is what every page tells
/// somebody to run when their snapshot is older, and `generate` reads the
/// snapshot before it writes one — so without this the instruction is false
/// for any repository past version 1, where `--baseline` cannot stand in
/// because it refuses to re-derive under a version 2.
///
/// One mirror struct per shape that renamed a field, and they go at 1.0 with a
/// line in the CHANGELOG. Nothing else from v0.4.0 needs one: every other word
/// the marker gained since arrived as a field with a default, and `std.zon`
/// fills a missing field from its default, which is the property every new word
/// keeps and a renamed field does not (ADR 181).
fn upgraded(arena: std.mem.Allocator, text: [:0]const u8) !Doc {
    // A `Diagnostics` nobody reads, because `std.zon.parse.fromSlice` takes
    // one. Before Zig 0.17 a null one **leaked on a failing parse**, `zig test`
    // on four lines of std and no nilo said so; now the diagnostics and the
    // result are allocated in the arena, so there is nothing left to own.
    var scratch: std.zon.parse.Diagnostics = undefined;

    const old = try std.zon.parse.fromSlice(Older, .{
        .gpa = arena,
        .arena = arena,
        .source = text,
        .diagnostics = &scratch,
    });

    const tables = try arena.alloc(Desc, old.tables.len);
    for (old.tables, 0..) |t, i| {
        const refs = try arena.alloc(table_mod.Reference, t.references.len);
        for (t.references, 0..) |r, j| {
            const columns = try arena.alloc([]const u8, 1);
            columns[0] = r.column;
            const targets = try arena.alloc([]const u8, 1);
            targets[0] = r.target;
            refs[j] = .{
                .name = r.name,
                .columns = columns,
                .schema = r.schema,
                .table = r.table,
                .targets = targets,
                .on_delete = r.on_delete,
            };
        }
        tables[i] = .{
            .schema = t.schema,
            .table = t.table,
            .keys = t.keys,
            .columns = t.columns,
            .uniques = t.uniques,
            .indexes = t.indexes,
            .references = refs,
            .managed = t.managed,
        };
    }
    return .{ .version = old.version, .dialect = old.dialect, .tables = tables };
}

const Older = struct {
    version: u32 = 0,
    dialect: []const u8,
    tables: []const Table = &.{},

    const Table = struct {
        row: []const u8 = "",
        schema: ?[]const u8 = null,
        table: []const u8,
        keys: []const []const u8,
        columns: []const table_mod.Column,
        uniques: []const table_mod.Unique = &.{},
        indexes: []const table_mod.Index = &.{},
        references: []const Reference = &.{},
        managed: bool = true,
    };

    /// The whole of the difference: one column each side rather than a list.
    const Reference = struct {
        name: []const u8,
        column: []const u8,
        schema: ?[]const u8 = null,
        table: []const u8,
        target: []const u8,
        on_delete: table_mod.OnDelete = .no_action,
    };
};

// -- tests ---------------------------------------------------------------

const testing = std.testing;
const Pg = @import("dialect.zig").Postgres;
const core = @import("nilo_core");
const types = @import("types.zig");

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
    email: core.Str,
    nickname: ?[]const u8,
    created_at: types.Timestamp,
};

fn docOf(gpa: std.mem.Allocator) !Doc {
    var desc = comptime table_mod.descOf(Pg, User);
    desc.row = "";
    const tables = try gpa.dupe(Desc, &.{desc});
    return .{ .version = 7, .dialect = Pg.name, .tables = tables };
}

test "a snapshot written and read back describes the same table" {
    const gpa = testing.allocator;

    const doc = try docOf(gpa);
    defer gpa.free(doc.tables);

    const text = try render(gpa, doc);
    defer gpa.free(text);

    const zeroed = try gpa.dupeSentinel(u8, text, 0);
    defer gpa.free(zeroed);

    var parsed: std.heap.ArenaAllocator = .init(gpa);
    defer parsed.deinit();
    const back = try parse(parsed.allocator(), zeroed, null);

    try testing.expectEqual(@as(u32, 7), back.version);
    try testing.expectEqualStrings("postgres", back.dialect);
    try testing.expectEqual(@as(usize, 1), back.tables.len);

    const t = back.table(null, "users").?;
    try testing.expectEqual(@as(usize, 1), t.keys.len);
    try testing.expectEqualStrings("id", t.keys[0]);
    try testing.expectEqual(@as(usize, 5), t.columns.len);
    try testing.expectEqualStrings("int8", t.column("id").?.sql_type);
    try testing.expect(t.column("id").?.generated);
    try testing.expect(t.column("nickname").?.nullable);
    try testing.expect(!t.column("email").?.nullable);
}

test "what a Row says about its table survives the round trip, because that is what a diff compares" {
    const gpa = testing.allocator;

    const doc = try docOf(gpa);
    defer gpa.free(doc.tables);
    const text = try render(gpa, doc);
    defer gpa.free(text);
    const zeroed = try gpa.dupeSentinel(u8, text, 0);
    defer gpa.free(zeroed);
    var parsed: std.heap.ArenaAllocator = .init(gpa);
    defer parsed.deinit();
    const back = try parse(parsed.allocator(), zeroed, null);

    const t = back.table(null, "users").?;

    try testing.expectEqual(@as(usize, 1), t.uniques.len);
    try testing.expectEqualStrings("users_email_key", t.uniques[0].name);
    try testing.expect(t.uniques[0].ignoring_case);

    try testing.expectEqual(@as(usize, 1), t.indexes.len);
    try testing.expectEqualStrings("users_created_at_idx", t.indexes[0].name);

    try testing.expectEqual(@as(usize, 1), t.references.len);
    try testing.expectEqualStrings("orgs", t.references[0].table);
    try testing.expectEqual(table_mod.OnDelete.cascade, t.references[0].on_delete);
}

test "the file says what it is, and says nothing a table does not have" {
    const gpa = testing.allocator;

    const Plain = struct {
        pub const nilo_table = .{ .name = "plain", .key = .id };
        id: i64,
        label: []const u8,
    };
    var desc = comptime table_mod.descOf(Pg, Plain);
    desc.row = "";
    const tables = try gpa.dupe(Desc, &.{desc});
    defer gpa.free(tables);

    const text = try render(gpa, .{ .version = 1, .dialect = Pg.name, .tables = tables });
    defer gpa.free(text);

    try testing.expect(std.mem.startsWith(u8, text, "// Written by `db generate`"));
    // A table with no indexes says nothing about indexes, which is what keeps
    // the file about as long as the schema is.
    try testing.expect(std.mem.indexOf(u8, text, "uniques") == null);
    try testing.expect(std.mem.indexOf(u8, text, "indexes") == null);
    try testing.expect(std.mem.indexOf(u8, text, "references") == null);
    try testing.expect(std.mem.indexOf(u8, text, "renames") == null);
    // And the Zig type name is not in it, so renaming a struct is not a
    // schema change.
    try testing.expect(std.mem.indexOf(u8, text, ".row") == null);
}

test "a repository that has generated nothing has a snapshot, and it is empty" {
    const doc = empty(Pg);
    try testing.expectEqual(@as(u32, 0), doc.version);
    try testing.expectEqualStrings("postgres", doc.dialect);
    try testing.expectEqual(@as(usize, 0), doc.tables.len);
    try testing.expectEqual(@as(?Desc, null), doc.table(null, "users"));
}

test "a table is found by its schema as well as its name" {
    const gpa = testing.allocator;

    const Bare = struct {
        pub const nilo_table = .{ .name = "audit", .key = .id };
        id: i64,
    };
    const Qualified = struct {
        pub const nilo_table = .{ .name = "app.audit", .key = .id };
        id: i64,
    };
    var one = comptime table_mod.descOf(Pg, Bare);
    var two = comptime table_mod.descOf(Pg, Qualified);
    one.row = "";
    two.row = "";
    const tables = try gpa.dupe(Desc, &.{ one, two });
    defer gpa.free(tables);

    const doc: Doc = .{ .version = 1, .dialect = Pg.name, .tables = tables };
    try testing.expectEqual(@as(?[]const u8, null), doc.table(null, "audit").?.schema);
    try testing.expectEqualStrings("app", doc.table("app", "audit").?.schema.?);
    try testing.expectEqual(@as(?Desc, null), doc.table("other", "audit"));
}

// -- the words that live inside one Row (ADR 181) ------------------------

const Level = enum { low, high };

const Ticket = struct {
    pub const nilo_table = .{
        .name = "tickets",
        .key = .id,
        .default = .{ .level = .low, .opened_at = .now },
        .index = .{.{
            .columns = .{ .org_id, .{ .opened_at = .desc } },
            .where = .{ .closed_at = null },
            .name = "tickets_open_newest_first",
        }},
    };

    id: i64,
    org_id: i64,
    level: Level,
    opened_at: types.Timestamp,
    closed_at: ?types.Timestamp,
};

test "a default, a column's words and a partial index survive the round trip" {
    const gpa = testing.allocator;

    var desc = comptime table_mod.descOf(Pg, Ticket);
    desc.row = "";
    const tables = try gpa.dupe(Desc, &.{desc});
    defer gpa.free(tables);

    const text = try render(gpa, .{ .version = 3, .dialect = Pg.name, .tables = tables });
    defer gpa.free(text);
    const zeroed = try gpa.dupeSentinel(u8, text, 0);
    defer gpa.free(zeroed);
    var parsed: std.heap.ArenaAllocator = .init(gpa);
    defer parsed.deinit();
    const back = try parse(parsed.allocator(), zeroed, null);

    const t = back.table(null, "tickets").?;
    try testing.expectEqualStrings("now()", t.column("opened_at").?.default.?);
    try testing.expectEqualStrings("'low'", t.column("level").?.default.?);
    try testing.expectEqual(@as(?[]const u8, null), t.column("org_id").?.default);

    try testing.expectEqual(@as(usize, 2), t.column("level").?.values.len);
    try testing.expectEqualStrings("low", t.column("level").?.values[0]);
    try testing.expectEqual(@as(usize, 0), t.column("org_id").?.values.len);

    const idx = t.indexes[0];
    try testing.expectEqualStrings("tickets_open_newest_first", idx.name);
    try testing.expectEqualStrings("\"closed_at\" IS NULL", idx.where);
    try testing.expectEqualStrings("opened_at", idx.descending[0]);

    // And a column the marker said nothing about says nothing in the file,
    // which is what keeps a diff small.
    try testing.expect(std.mem.indexOf(u8, text, ".values = .{}") == null);
    try testing.expect(std.mem.indexOf(u8, text, ".descending = .{}") == null);
}

test "a foreign key of two columns is written down as two, and read back as two" {
    const gpa = testing.allocator;

    const Board = struct {
        pub const nilo_table = .{ .name = "boards", .key = .{ .id, .org_id } };
        id: i64,
        org_id: i64,
    };
    const Card = struct {
        pub const nilo_table = .{
            .name = "cards",
            .key = .id,
            .references = .{
                .board = .{
                    .columns = .{ .board_id, .org_id },
                    .to = .{ Board, .{ .id, .org_id } },
                    .on_delete = .cascade,
                },
            },
        };
        id: i64,
        board_id: i64,
        org_id: i64,
    };

    var desc = comptime table_mod.descOf(Pg, Card);
    desc.row = "";
    const tables = try gpa.dupe(Desc, &.{desc});
    defer gpa.free(tables);

    const text = try render(gpa, .{ .version = 5, .dialect = Pg.name, .tables = tables });
    defer gpa.free(text);
    const zeroed = try gpa.dupeSentinel(u8, text, 0);
    defer gpa.free(zeroed);
    var parsed: std.heap.ArenaAllocator = .init(gpa);
    defer parsed.deinit();
    const back = try parse(parsed.allocator(), zeroed, null);

    const fk = back.table(null, "cards").?.references[0];
    try testing.expectEqualStrings("cards_board_id_org_id_fkey", fk.name);
    try testing.expectEqualStrings("board_id", fk.columns[0]);
    try testing.expectEqualStrings("org_id", fk.columns[1]);
    try testing.expectEqualStrings("id", fk.targets[0]);
    try testing.expectEqualStrings("org_id", fk.targets[1]);
    try testing.expectEqual(table_mod.OnDelete.cascade, fk.on_delete);
}

test "a snapshot whose foreign keys are the older single-column shape is upgraded, not refused" {
    // **The break this round makes, and the way back from it.**
    // `Reference.column` became `columns` and `target` became `targets`, which
    // is what a foreign key of two columns needs. `std.zon` fills a *missing*
    // field from its default and has nothing to say about a renamed one, so
    // the current shape cannot read the old spelling — and the answer every
    // page gives, `db generate`, reads the snapshot before it writes one. So
    // the older shape is read by a mirror struct and handed back as the
    // current one, and the file is rewritten by the generate that follows
    // ([ADR 181](../docs/adr/181-the-marker-has-two-kinds-of-word.md)).
    const gpa = testing.allocator;

    const older =
        \\.{
        \\    .version = 4,
        \\    .dialect = "postgres",
        \\    .tables = .{
        \\        .{
        \\            .table = "users",
        \\            .keys = .{"id"},
        \\            .columns = .{ .{ .name = "id", .sql_type = "int8", .key = true } },
        \\            .references = .{
        \\                .{
        \\                    .name = "users_org_id_fkey",
        \\                    .column = "org_id",
        \\                    .table = "orgs",
        \\                    .target = "id",
        \\                    .on_delete = .cascade,
        \\                },
        \\            },
        \\        },
        \\    },
        \\}
    ;

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var origin: Origin = .current;
    const doc = try parseWith(arena.allocator(), older, null, &origin);
    try testing.expectEqual(Origin.upgraded, origin);
    try testing.expectEqual(@as(u32, 4), doc.version);

    // The one field that moved, read into the list it became — and everything
    // beside it carried across rather than defaulted.
    const users = doc.table(null, "users").?;
    try testing.expectEqual(@as(usize, 1), users.references.len);
    const fk = users.references[0];
    try testing.expectEqualStrings("users_org_id_fkey", fk.name);
    try testing.expectEqual(@as(usize, 1), fk.columns.len);
    try testing.expectEqualStrings("org_id", fk.columns[0]);
    try testing.expectEqualStrings("orgs", fk.table);
    try testing.expectEqual(@as(usize, 1), fk.targets.len);
    try testing.expectEqualStrings("id", fk.targets[0]);
    try testing.expectEqual(table_mod.OnDelete.cascade, fk.on_delete);
}

test "a file that is in neither shape fails with what is wrong about the current one" {
    // The older shape is tried second and with no diagnostics of its own, so
    // what a person is shown is still about the file they have rather than
    // about a struct this module no longer writes.
    const gpa = testing.allocator;
    var parsed: std.heap.ArenaAllocator = .init(gpa);
    defer parsed.deinit();
    var diag: std.zon.parse.Diagnostics = undefined;

    const broken =
        \\.{ .version = 1, .dialect = "postgres", .tables = .{ .{ .tabel = "users" } } }
    ;
    try testing.expectError(error.ParseZon, parse(parsed.allocator(), broken, &diag));

    var buf: [512]u8 = undefined;
    const said = try std.fmt.bufPrint(&buf, "{f}", .{diag.fmt("snapshot.zon")});
    try testing.expect(std.mem.indexOf(u8, said, "tabel") != null);
}

test "a snapshot written before these fields existed still parses as the schema it was" {
    // **Every field the marker gained has a default**, which is what lets
    // round one land without rewriting anybody's file: `std.zon` fills a
    // missing field from its default, so an older snapshot reads as a schema
    // with no defaults, no enum words and no partial indexes — which is what
    // it was. The round that reshapes `Reference` does not have that property
    // and says so.
    const gpa = testing.allocator;
    const older =
        \\.{
        \\    .version = 4,
        \\    .dialect = "postgres",
        \\    .tables = .{
        \\        .{
        \\            .table = "tickets",
        \\            .keys = .{"id"},
        \\            .columns = .{
        \\                .{ .name = "id", .sql_type = "int8", .key = true, .generated = true },
        \\                .{ .name = "level", .sql_type = "text" },
        \\            },
        \\            .indexes = .{ .{ .name = "tickets_level_idx", .columns = .{"level"} } },
        \\        },
        \\    },
        \\}
    ;
    var parsed: std.heap.ArenaAllocator = .init(gpa);
    defer parsed.deinit();
    const back = try parse(parsed.allocator(), older, null);

    const t = back.table(null, "tickets").?;
    try testing.expectEqual(@as(?[]const u8, null), t.column("level").?.default);
    try testing.expectEqual(@as(usize, 0), t.column("level").?.values.len);
    try testing.expectEqualStrings("", t.indexes[0].where);
    try testing.expectEqual(@as(usize, 0), t.indexes[0].descending.len);
}

test "a snapshot somebody broke says where, rather than failing silently" {
    const gpa = testing.allocator;
    var parsed: std.heap.ArenaAllocator = .init(gpa);
    defer parsed.deinit();
    var diag: std.zon.parse.Diagnostics = undefined;

    const broken =
        \\.{ .version = 1, .dialect = "postgres", .tables = .{ .{ .table = "users" } } }
    ;
    try testing.expectError(error.ParseZon, parse(parsed.allocator(), broken, &diag));

    // `std.zon` writes the sentence, and it names the field that is missing.
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try w.print("{f}", .{diag.fmt("snapshot.zon")});
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "key") != null);
}

test "a check and a trigger go into the file as a name and a hash, and no SQL at all" {
    const gpa = testing.allocator;

    const Ledger = struct {
        pub const nilo_table = .{
            .name = "ledgers",
            .key = .id,
            .check = .{ .ledgers_amount_is_positive = "amount > 0" },
            .trigger = .{
                .ledgers_touch = .{
                    .when = "BEFORE UPDATE",
                    .run = "FOR EACH ROW EXECUTE FUNCTION set_updated_at()",
                },
            },
        };

        id: i64,
        amount: i64,
    };

    const migrate = @import("migrate.zig");
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const doc = try migrate.snapshotOf(arena.allocator(), Pg, 1, comptime migrate.desiredOf(
        Pg,
        .{ .tables = &.{Ledger} },
    ));

    const text = try render(gpa, doc);
    defer gpa.free(text);

    // **The body is not in the file**, which is the property that keeps a
    // `.zon` snapshot readable once a schema has sixty-line views in it.
    try testing.expect(std.mem.indexOf(u8, text, "amount > 0") == null);
    try testing.expect(std.mem.indexOf(u8, text, "EXECUTE FUNCTION") == null);
    try testing.expect(std.mem.indexOf(u8, text, "ledgers_amount_is_positive") != null);
    try testing.expect(std.mem.indexOf(u8, text, "ledgers_touch") != null);

    const zeroed = try gpa.dupeSentinel(u8, text, 0);
    defer gpa.free(zeroed);
    var parsed: std.heap.ArenaAllocator = .init(gpa);
    defer parsed.deinit();
    const back = try parse(parsed.allocator(), zeroed, null);
    const t = back.table(null, "ledgers").?;
    try testing.expectEqual(@as(usize, 1), t.checks.len);
    try testing.expectEqualStrings("ledgers_amount_is_positive", t.checks[0].name);
    try testing.expectEqual(@as(usize, 16), t.checks[0].hash.len);
    try testing.expectEqualStrings("", t.checks[0].body);
    try testing.expectEqual(@as(usize, 1), t.triggers.len);
    try testing.expectEqualStrings("ledgers_touch", t.triggers[0].name);
}

test "a schema's extensions go into the file by name, and its functions and views as a name and a hash" {
    const gpa = testing.allocator;
    const migrate = @import("migrate.zig");
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const doc = try migrate.snapshotOf(arena.allocator(), Pg, 3, comptime migrate.desiredOf(Pg, .{
        .extensions = &.{"pgcrypto"},
        .functions = &.{.{ .name = "touch", .body = "CREATE OR REPLACE FUNCTION touch() RETURNS trigger AS $$ BEGIN RETURN NEW; END $$ LANGUAGE plpgsql" }},
        .tables = &.{Org},
        .views = &.{.{ .name = "org_names", .body = "SELECT id, name FROM orgs" }},
    }));

    const text = try render(gpa, doc);
    defer gpa.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "pgcrypto") != null);
    try testing.expect(std.mem.indexOf(u8, text, "LANGUAGE plpgsql") == null);
    try testing.expect(std.mem.indexOf(u8, text, "FROM orgs") == null);

    const zeroed = try gpa.dupeSentinel(u8, text, 0);
    defer gpa.free(zeroed);
    var parsed: std.heap.ArenaAllocator = .init(gpa);
    defer parsed.deinit();
    const back = try parse(parsed.allocator(), zeroed, null);
    try testing.expectEqual(@as(usize, 1), back.extensions.len);
    try testing.expectEqualStrings("pgcrypto", back.extensions[0]);
    try testing.expectEqualStrings("touch", back.functions[0].name);
    try testing.expectEqual(@as(usize, 16), back.functions[0].hash.len);
    try testing.expectEqualStrings("org_names", back.views[0].name);
    try testing.expectEqual(@as(usize, 16), back.views[0].hash.len);
    // And the hash is the one the types compute, so a diff sees no move.
    try testing.expect(back.views[0].sameAs(.{ .name = "org_names", .body = "SELECT id, name FROM orgs" }));
}

test "a snapshot written before a table could carry a check reads back as one with none" {
    const gpa = testing.allocator;
    const text =
        \\.{
        \\    .version = 3,
        \\    .dialect = "postgres",
        \\    .tables = .{
        \\        .{
        \\            .table = "ledgers",
        \\            .keys = .{"id"},
        \\            .columns = .{ .{ .name = "id", .sql_type = "int8", .key = true } },
        \\        },
        \\    },
        \\}
    ;

    var parsed: std.heap.ArenaAllocator = .init(gpa);
    defer parsed.deinit();
    const doc = try parse(parsed.allocator(), text, null);
    // `std.zon` fills a missing field from its default, which is the property
    // ADR 181 was careful to keep — so a word added to the marker never needs
    // a mirror struct the way the `.references` rename did.
    const t = doc.table(null, "ledgers").?;
    try testing.expectEqual(@as(usize, 0), t.checks.len);
    try testing.expectEqual(@as(usize, 0), t.triggers.len);
}
