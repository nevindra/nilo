//! What the last `generate` believed the schema was, as a file the repository
//! holds ([ADR 0153](../docs/adr/0153-a-migration-is-a-diff-against-a-snapshot.md)).
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

/// Read one back.
///
/// `diag` is optional and worth passing: `std.zon` formats a parse failure with
/// the line, the column and the offending text, which is a better sentence than
/// anything this file would write about a file somebody edited.
pub fn parse(
    gpa: std.mem.Allocator,
    text: [:0]const u8,
    diag: ?*std.zon.parse.Diagnostics,
) !Doc {
    return std.zon.parse.fromSliceAlloc(Doc, gpa, text, diag, .{});
}

/// Give back what `parse` took. Unnecessary when the allocator was an arena,
/// which is how a `Run` holds one, and that is the shape to prefer.
pub fn free(gpa: std.mem.Allocator, doc: Doc) void {
    std.zon.parse.free(gpa, doc);
}

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

    const zeroed = try gpa.dupeZ(u8, text);
    defer gpa.free(zeroed);

    const back = try parse(gpa, zeroed, null);
    defer free(gpa, back);

    try testing.expectEqual(@as(u32, 7), back.version);
    try testing.expectEqualStrings("postgres", back.dialect);
    try testing.expectEqual(@as(usize, 1), back.tables.len);

    const t = back.table(null, "users").?;
    try testing.expectEqualStrings("id", t.key);
    try testing.expectEqual(@as(usize, 5), t.columns.len);
    try testing.expectEqualStrings("int8", t.column("id").?.sql_type);
    try testing.expect(t.column("id").?.generated);
    try testing.expect(t.column("nickname").?.nullable);
    try testing.expect(!t.column("email").?.nullable);
}

test "the three words survive the round trip, because they are what a diff compares" {
    const gpa = testing.allocator;

    const doc = try docOf(gpa);
    defer gpa.free(doc.tables);
    const text = try render(gpa, doc);
    defer gpa.free(text);
    const zeroed = try gpa.dupeZ(u8, text);
    defer gpa.free(zeroed);
    const back = try parse(gpa, zeroed, null);
    defer free(gpa, back);

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

test "a snapshot somebody broke says where, rather than failing silently" {
    const gpa = testing.allocator;
    var diag: std.zon.parse.Diagnostics = .{};
    defer diag.deinit(gpa);

    const broken =
        \\.{ .version = 1, .dialect = "postgres", .tables = .{ .{ .table = "users" } } }
    ;
    try testing.expectError(error.ParseZon, parse(gpa, broken, &diag));

    // `std.zon` writes the sentence, and it names the field that is missing.
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try w.print("{f}", .{diag});
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "key") != null);
}
