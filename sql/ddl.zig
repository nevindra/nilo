//! The SQL that changes a table's shape, written from a `Desc`
//! ([ADR 0153](../docs/adr/0153-a-migration-is-a-diff-against-a-snapshot.md)).
//!
//! **`CREATE` is settled while compiling and only `ALTER` is not**, which is
//! ADR 0039's rule arriving one layer over and is worth stating because it is
//! not obvious. A table that does not exist yet is described entirely by the
//! caller's types, so its whole `CREATE TABLE` is a constant in the binary
//! before the program runs. An `ALTER` is a sentence about the difference
//! between the types and something a previous run wrote down, and the second
//! half of that is a file. So it is built into an arena, and it is the only
//! half that is.
//!
//! The consequence is the one that matters for the smallest kind of program:
//! `migrate.createMissing` creates every table a list of Rows describes and
//! **allocates nothing at all**, because every byte it sends is already in
//! `.rodata`. That is the whole of what a SQLite application needs at startup,
//! and it is what `stress/arsip` writes by hand today.
//!
//! ## Identifiers at run time
//!
//! A Dialect's `quote` takes comptime text, because every identifier this
//! module writes is a Zig field name. The names that reach `ALTER` came out of
//! a snapshot file instead, so they are quoted here by `writeIdent`, which
//! applies the rule both Dialects apply today: double quotes, and a refusal for
//! text carrying one of its own. When a third Dialect spells it differently
//! this moves onto the Dialect and nothing else changes.

const std = @import("std");
const table_mod = @import("table.zig");

const Desc = table_mod.Desc;
const Column = table_mod.Column;
const Unique = table_mod.Unique;
const Index = table_mod.Index;

pub const Error = error{
    /// An identifier carried a double quote, so quoting it would end the
    /// identifier early. Only reachable from a hand-edited snapshot.
    BadIdentifier,
    /// What an `Allocating` writer answers when the arena is out. It is
    /// `OutOfMemory` wearing the writer's name, and both are here because
    /// `toOwnedSlice` hands back the other one.
    WriteFailed,
    OutOfMemory,
};

/// One statement and the name of the thing it makes, so a diff can drop the
/// old one by name and make the new one without matching text against text.
pub const Named = struct {
    name: []const u8,
    sql: []const u8,
};

/// Everything it takes to make one table, in the order it has to run.
pub const Created = struct {
    table: []const u8,
    /// The uniques first and the plain indexes after, in the order the marker
    /// declares them.
    indexes: []const Named,
};

// -- what is settled while compiling -------------------------------------

/// The whole `CREATE TABLE`, as a constant.
///
/// Foreign keys are written **inline** rather than added afterwards, and that
/// is a decision about SQLite rather than about tidiness: it has no
/// `ALTER TABLE … ADD CONSTRAINT`, so a key that is not written at creation
/// cannot be written at all. Postgres takes the same text, so one shape serves
/// both.
///
/// What it costs is an ordering: Postgres checks that the referenced table
/// exists, so a table has to be created after the ones it points at. That sort
/// happens once, over the whole plan, in `migrate.zig`.
pub fn createTable(comptime D: type, comptime Row: type) []const u8 {
    comptime {
        // Concatenating a clause per column is what costs branches here, so the
        // budget is a function of how wide the table is rather than a constant
        // somebody raises again every few years. Comptime only: none of this
        // exists at run time.
        @setEvalBranchQuota(20_000 + 4_000 * @typeInfo(Row).@"struct".fields.len);
        const desc = table_mod.descOf(D, Row);
        var out: []const u8 = "CREATE TABLE " ++ D.qualify(desc.schema, desc.table) ++ " (";
        for (desc.columns, 0..) |c, i| {
            out = out ++ (if (i == 0) "\n  " else ",\n  ") ++ columnClause(D, desc, c);
        }
        return out ++ "\n)";
    }
}

/// The `CREATE TABLE` and every index and unique that goes with it.
pub fn createdFor(comptime D: type, comptime Row: type) Created {
    comptime {
        // Concatenating a clause per column is what costs branches here, so the
        // budget is a function of how wide the table is rather than a constant
        // somebody raises again every few years. Comptime only: none of this
        // exists at run time.
        @setEvalBranchQuota(20_000 + 4_000 * @typeInfo(Row).@"struct".fields.len);
        const desc = table_mod.descOf(D, Row);
        var out: [desc.uniques.len + desc.indexes.len]Named = undefined;
        for (desc.uniques, 0..) |u, i| {
            out[i] = .{ .name = u.name, .sql = uniqueStatement(D, desc, u) };
        }
        for (desc.indexes, 0..) |x, i| {
            out[desc.uniques.len + i] = .{ .name = x.name, .sql = indexStatement(D, desc, x) };
        }
        const frozen = out;
        return .{ .table = createTable(D, Row), .indexes = &frozen };
    }
}

/// A unique constraint, as an index rather than as a table constraint.
///
/// `CREATE UNIQUE INDEX` rather than `ALTER TABLE … ADD CONSTRAINT UNIQUE` for
/// two reasons that point the same way. SQLite has the first and not the
/// second; and the case-folding form has to be an index on an expression, which
/// a table constraint cannot be. One shape, both databases, both forms.
pub fn uniqueStatement(comptime D: type, comptime desc: Desc, comptime u: Unique) []const u8 {
    comptime {
        var out: []const u8 = "CREATE UNIQUE INDEX " ++ D.quote(u.name) ++
            " ON " ++ D.qualify(desc.schema, desc.table) ++ " (";
        for (u.columns, 0..) |c, i| {
            const quoted = D.quote(c);
            out = out ++ (if (i == 0) "" else ", ") ++
                (if (u.ignoring_case) D.foldedColumn(quoted) else quoted);
        }
        return out ++ ")";
    }
}

pub fn indexStatement(comptime D: type, comptime desc: Desc, comptime x: Index) []const u8 {
    comptime {
        var out: []const u8 = "CREATE INDEX " ++ D.quote(x.name) ++
            " ON " ++ D.qualify(desc.schema, desc.table) ++ " (";
        for (x.columns, 0..) |c, i| {
            out = out ++ (if (i == 0) "" else ", ") ++ D.quote(c);
        }
        return out ++ ")";
    }
}

/// The same `CREATE TABLE`, with `IF NOT EXISTS` in it.
///
/// **Spliced rather than written twice**, which is the point: one function
/// decides what a table looks like, and this one moves four words into the
/// front of what it said. Two builders would be two places to add a column type
/// to, and the second would be the one that got forgotten.
///
/// It is a separate call rather than an option because the two mean different
/// things. `createTable` is a migration step and a table that is already there
/// is a real disagreement. This is `createMissing`, where a table that is
/// already there is the ordinary case and the whole point.
pub fn createIfMissing(comptime D: type, comptime Row: type) []const u8 {
    comptime {
        const head = "CREATE TABLE ";
        return head ++ "IF NOT EXISTS " ++ createTable(D, Row)[head.len..];
    }
}

/// The same for every index and unique a table declares.
pub fn createdIfMissing(comptime D: type, comptime Row: type) Created {
    comptime {
        const plain = createdFor(D, Row);
        var out: [plain.indexes.len]Named = undefined;
        for (plain.indexes, 0..) |made, i| {
            const head = if (std.mem.startsWith(u8, made.sql, "CREATE UNIQUE INDEX "))
                "CREATE UNIQUE INDEX "
            else
                "CREATE INDEX ";
            out[i] = .{
                .name = made.name,
                .sql = head ++ "IF NOT EXISTS " ++ made.sql[head.len..],
            };
        }
        const frozen = out;
        return .{ .table = createIfMissing(D, Row), .indexes = &frozen };
    }
}

pub fn dropTable(comptime D: type, comptime Row: type) []const u8 {
    comptime {
        // Concatenating a clause per column is what costs branches here, so the
        // budget is a function of how wide the table is rather than a constant
        // somebody raises again every few years. Comptime only: none of this
        // exists at run time.
        @setEvalBranchQuota(20_000 + 4_000 * @typeInfo(Row).@"struct".fields.len);
        const desc = table_mod.descOf(D, Row);
        return "DROP TABLE " ++ D.qualify(desc.schema, desc.table);
    }
}

/// One column, with everything that can be said about it inline: its type, its
/// nullability, whether it is the key, and what it points at.
fn columnClause(comptime D: type, comptime desc: Desc, comptime c: Column) []const u8 {
    comptime {
        const quoted = D.quote(c.name);
        const head = if (c.key)
            D.keyColumn(quoted, c.sql_type, c.generated)
        else
            quoted ++ " " ++ c.sql_type ++ (if (c.nullable) "" else " NOT NULL");
        return head ++ referenceClause(D, desc, c.name);
    }
}

fn referenceClause(comptime D: type, comptime desc: Desc, comptime name: []const u8) []const u8 {
    comptime {
        for (desc.references) |r| {
            if (!std.mem.eql(u8, r.column, name)) continue;
            // The referenced table is qualified the way the Row that owns it
            // qualifies itself. Writing the bare name would resolve through
            // `search_path` instead, which is a different table on a bad day.
            return " REFERENCES " ++ D.qualify(r.schema, r.table) ++
                " (" ++ D.quote(r.target) ++ ")" ++ r.on_delete.clause();
        }
        return "";
    }
}

// -- what a diff has to build ---------------------------------------------

/// `ALTER TABLE … ADD COLUMN`.
///
/// **A column that may not be null is the one statement here that can fail on a
/// table with rows in it**, and it fails loudly rather than quietly. The diff
/// says so before it writes the step, because the answer is a default in the
/// step or a backfill beside it, and neither is something to guess.
pub fn addColumn(comptime D: type, gpa: std.mem.Allocator, desc: Desc, c: Column) Error![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;

    try alterHead(w, desc);
    try w.writeAll(" ADD COLUMN ");
    try writeIdent(w, c.name);
    try w.print(" {s}", .{c.sql_type});
    if (!c.nullable) try w.writeAll(" NOT NULL");
    _ = D;
    return aw.toOwnedSlice();
}

pub fn dropColumn(
    comptime D: type,
    gpa: std.mem.Allocator,
    desc: Desc,
    name: []const u8,
) Error![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;

    try alterHead(w, desc);
    try w.writeAll(" DROP COLUMN ");
    try writeIdent(w, name);
    _ = D;
    return aw.toOwnedSlice();
}

/// `ALTER TABLE … RENAME COLUMN`, which both databases have and spell alike.
///
/// This is the statement `.was` exists to produce, and the reason it is worth a
/// marker word: without it the same change is a drop and an add, and the column
/// arrives empty.
pub fn renameColumn(
    comptime D: type,
    gpa: std.mem.Allocator,
    desc: Desc,
    from: []const u8,
    to: []const u8,
) Error![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;

    try alterHead(w, desc);
    try w.writeAll(" RENAME COLUMN ");
    try writeIdent(w, from);
    try w.writeAll(" TO ");
    try writeIdent(w, to);
    _ = D;
    return aw.toOwnedSlice();
}

/// `ALTER TABLE … ALTER COLUMN … TYPE`. Only reachable on a Dialect whose
/// `can_alter_column` is true; the diff refuses before it gets here otherwise.
pub fn alterType(
    comptime D: type,
    gpa: std.mem.Allocator,
    desc: Desc,
    c: Column,
) Error![]const u8 {
    comptime std.debug.assert(D.can_alter_column);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;

    try alterHead(w, desc);
    try w.writeAll(" ALTER COLUMN ");
    try writeIdent(w, c.name);
    try w.print(" TYPE {s}", .{c.sql_type});
    return aw.toOwnedSlice();
}

/// `SET NOT NULL` or `DROP NOT NULL`. The first can fail on a table already
/// holding a null, which is the same shape of failure `addColumn` has and is
/// flagged the same way.
pub fn alterNullability(
    comptime D: type,
    gpa: std.mem.Allocator,
    desc: Desc,
    c: Column,
) Error![]const u8 {
    comptime std.debug.assert(D.can_alter_column);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;

    try alterHead(w, desc);
    try w.writeAll(" ALTER COLUMN ");
    try writeIdent(w, c.name);
    try w.writeAll(if (c.nullable) " DROP NOT NULL" else " SET NOT NULL");
    return aw.toOwnedSlice();
}

/// `DROP INDEX`, by the name the snapshot recorded.
///
/// The schema goes in front of the index rather than the table, because that is
/// where both databases put it: an index lives in a schema of its own right.
pub fn dropIndex(
    comptime D: type,
    gpa: std.mem.Allocator,
    schema: ?[]const u8,
    name: []const u8,
) Error![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;

    try w.writeAll("DROP INDEX ");
    if (schema) |s| {
        try writeIdent(w, s);
        try w.writeAll(".");
    }
    try writeIdent(w, name);
    _ = D;
    return aw.toOwnedSlice();
}

fn alterHead(w: *std.Io.Writer, desc: Desc) Error!void {
    try w.writeAll("ALTER TABLE ");
    if (desc.schema) |s| {
        try writeIdent(w, s);
        try w.writeAll(".");
    }
    try writeIdent(w, desc.table);
}

/// One identifier, quoted the way both Dialects quote.
///
/// The refusal is not defensive theatre. Every name that reaches here has been
/// through a Zig field name once, and the one route that has not is a snapshot
/// somebody edited, which is exactly the input worth refusing rather than
/// concatenating.
pub fn writeIdent(w: *std.Io.Writer, ident: []const u8) Error!void {
    if (ident.len == 0) return error.BadIdentifier;
    if (std.mem.indexOfScalar(u8, ident, '"') != null) return error.BadIdentifier;
    try w.writeAll("\"");
    try w.writeAll(ident);
    try w.writeAll("\"");
}

// -- tests ---------------------------------------------------------------

const testing = std.testing;
const Pg = @import("dialect.zig").Postgres;
const Lite = @import("dialect.zig").SQLite;
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
        .unique = .{
            .{ .columns = .{.email}, .ignoring_case = true },
            .{ .org_id, .handle },
        },
        .index = .{.created_at},
        .references = .{ .org_id = .{ Org, .id, .cascade } },
    };

    id: i64,
    org_id: i64,
    email: core.Str,
    handle: []const u8,
    nickname: ?[]const u8,
    created_at: types.Timestamp,
};

test "a CREATE TABLE is a constant, which is the claim this file makes" {
    const sql = comptime createTable(Pg, User);

    // If any of it were runtime work, this array would not compile.
    const in_binary: [sql.len]u8 = sql[0..sql.len].*;
    try testing.expect(in_binary.len > 0);

    try testing.expectEqualStrings(
        \\CREATE TABLE "users" (
        \\  "id" int8 GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
        \\  "org_id" int8 NOT NULL REFERENCES "orgs" ("id") ON DELETE CASCADE,
        \\  "email" text NOT NULL,
        \\  "handle" text NOT NULL,
        \\  "nickname" text,
        \\  "created_at" timestamptz NOT NULL
        \\)
    , sql);
}

test "the same type creates a SQLite table, and only what SQLite spells differently moves" {
    try testing.expectEqualStrings(
        \\CREATE TABLE "users" (
        \\  "id" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
        \\  "org_id" INTEGER NOT NULL REFERENCES "orgs" ("id") ON DELETE CASCADE,
        \\  "email" TEXT NOT NULL,
        \\  "handle" TEXT NOT NULL,
        \\  "nickname" TEXT,
        \\  "created_at" INTEGER NOT NULL
        \\)
    , comptime createTable(Lite, User));
}

test "a case-folding unique is an index on an expression, and each database has its own" {
    const pg = comptime createdFor(Pg, User);
    const lite = comptime createdFor(Lite, User);

    try testing.expectEqual(@as(usize, 3), pg.indexes.len);
    try testing.expectEqualStrings("users_email_key", pg.indexes[0].name);
    try testing.expectEqualStrings(
        "CREATE UNIQUE INDEX \"users_email_key\" ON \"users\" (lower(\"email\"))",
        pg.indexes[0].sql,
    );
    try testing.expectEqualStrings(
        "CREATE UNIQUE INDEX \"users_email_key\" ON \"users\" (\"email\" COLLATE NOCASE)",
        lite.indexes[0].sql,
    );
}

test "a composite unique and a plain index are the same statement without the folding" {
    const pg = comptime createdFor(Pg, User);
    try testing.expectEqualStrings(
        "CREATE UNIQUE INDEX \"users_org_id_handle_key\" ON \"users\" (\"org_id\", \"handle\")",
        pg.indexes[1].sql,
    );
    try testing.expectEqualStrings(
        "CREATE INDEX \"users_created_at_idx\" ON \"users\" (\"created_at\")",
        pg.indexes[2].sql,
    );
}

test "a key the program supplies is a column and a key, not a sequence" {
    const Doc = struct {
        pub const nilo_table = .{ .name = "docs", .key = .public };
        public: types.Uuid,
        title: []const u8,
    };
    try testing.expectEqualStrings(
        \\CREATE TABLE "docs" (
        \\  "public" uuid NOT NULL PRIMARY KEY,
        \\  "title" text NOT NULL
        \\)
    , comptime createTable(Pg, Doc));
}

test "a qualified table carries its schema into every statement it appears in" {
    const Audit = struct {
        pub const nilo_table = .{ .name = "app.audit", .key = .id, .index = .{.at} };
        id: i64,
        at: types.Timestamp,
    };
    const made = comptime createdFor(Pg, Audit);
    try testing.expect(std.mem.startsWith(u8, made.table, "CREATE TABLE \"app\".\"audit\" ("));
    try testing.expectEqualStrings(
        "CREATE INDEX \"audit_at_idx\" ON \"app\".\"audit\" (\"at\")",
        made.indexes[0].sql,
    );
}

test "the statements a diff builds name the table and the column and nothing else" {
    const gpa = testing.allocator;
    const desc = comptime table_mod.descOf(Pg, User);

    const added = try addColumn(Pg, gpa, desc, desc.column("nickname").?);
    defer gpa.free(added);
    try testing.expectEqualStrings("ALTER TABLE \"users\" ADD COLUMN \"nickname\" text", added);

    const required = try addColumn(Pg, gpa, desc, desc.column("handle").?);
    defer gpa.free(required);
    try testing.expectEqualStrings(
        "ALTER TABLE \"users\" ADD COLUMN \"handle\" text NOT NULL",
        required,
    );

    const dropped = try dropColumn(Pg, gpa, desc, "nickname");
    defer gpa.free(dropped);
    try testing.expectEqualStrings("ALTER TABLE \"users\" DROP COLUMN \"nickname\"", dropped);

    const renamed = try renameColumn(Pg, gpa, desc, "e_mail", "email");
    defer gpa.free(renamed);
    try testing.expectEqualStrings(
        "ALTER TABLE \"users\" RENAME COLUMN \"e_mail\" TO \"email\"",
        renamed,
    );
}

test "a type change and a nullability change are two statements on the database that has them" {
    const gpa = testing.allocator;
    const desc = comptime table_mod.descOf(Pg, User);

    const typed = try alterType(Pg, gpa, desc, desc.column("handle").?);
    defer gpa.free(typed);
    try testing.expectEqualStrings(
        "ALTER TABLE \"users\" ALTER COLUMN \"handle\" TYPE text",
        typed,
    );

    const tightened = try alterNullability(Pg, gpa, desc, desc.column("handle").?);
    defer gpa.free(tightened);
    try testing.expectEqualStrings(
        "ALTER TABLE \"users\" ALTER COLUMN \"handle\" SET NOT NULL",
        tightened,
    );

    const loosened = try alterNullability(Pg, gpa, desc, desc.column("nickname").?);
    defer gpa.free(loosened);
    try testing.expectEqualStrings(
        "ALTER TABLE \"users\" ALTER COLUMN \"nickname\" DROP NOT NULL",
        loosened,
    );
}

test "an index is dropped by the name the snapshot recorded, in its own schema" {
    const gpa = testing.allocator;

    const plain = try dropIndex(Pg, gpa, null, "users_email_key");
    defer gpa.free(plain);
    try testing.expectEqualStrings("DROP INDEX \"users_email_key\"", plain);

    const qualified = try dropIndex(Pg, gpa, "app", "audit_at_idx");
    defer gpa.free(qualified);
    try testing.expectEqualStrings("DROP INDEX \"app\".\"audit_at_idx\"", qualified);
}

test "an identifier that would end its own quoting is refused rather than concatenated" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try testing.expectError(error.BadIdentifier, writeIdent(&w, "ev\"il"));
    try testing.expectError(error.BadIdentifier, writeIdent(&w, ""));
}

test "the IF NOT EXISTS form is the same statement with four words moved in" {
    // One builder decides what a table looks like. This one splices, so a
    // column type added to `createTable` cannot go missing here.
    const plain = comptime createTable(Pg, User);
    const guarded = comptime createIfMissing(Pg, User);
    try testing.expect(std.mem.startsWith(u8, guarded, "CREATE TABLE IF NOT EXISTS \"users\" ("));
    try testing.expectEqualStrings(
        plain["CREATE TABLE ".len..],
        guarded["CREATE TABLE IF NOT EXISTS ".len..],
    );

    const made = comptime createdIfMissing(Pg, User);
    try testing.expectEqualStrings(
        "CREATE UNIQUE INDEX IF NOT EXISTS \"users_email_key\" ON \"users\" (lower(\"email\"))",
        made.indexes[0].sql,
    );
    try testing.expectEqualStrings(
        "CREATE INDEX IF NOT EXISTS \"users_created_at_idx\" ON \"users\" (\"created_at\")",
        made.indexes[2].sql,
    );
}
