//! The SQL that changes a table's shape, written from a `Desc`
//! ([ADR 123](../docs/adr/123-a-migration-is-a-diff-against-a-snapshot.md)).
//!
//! **`CREATE` is settled while compiling and only `ALTER` is not**, which is
//! ADR 036's rule arriving one layer over and is worth stating because it is
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
const NamedText = table_mod.NamedText;

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
    /// The triggers the marker named, which run after the table and its
    /// indexes exist.
    ///
    /// **A list of their own rather than more `indexes`**, because a trigger is
    /// dropped by a different statement on each database and the diff has to
    /// tell the two apart by more than the text. The `CHECK` constraints have
    /// no entry here at all: they are written inside the `CREATE TABLE`, for
    /// the reason `referenceClause` gives.
    triggers: []const Named = &.{},
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
        @setEvalBranchQuota(20_000 + 4_000 * @typeInfo(Row).@"struct".field_names.len);
        const desc = table_mod.descOf(D, Row);
        var out: []const u8 = "CREATE TABLE " ++ D.qualify(desc.schema, desc.table) ++ " (";
        for (desc.columns, 0..) |c, i| {
            out = out ++ (if (i == 0) "\n  " else ",\n  ") ++ columnClause(D, desc, c);
        }
        // **A key spanning several columns is a table constraint, not a column
        // clause**, which is the one structural difference a composite key
        // makes to the DDL. `keyColumn` writes `… PRIMARY KEY` onto one column
        // and there is nowhere on a column to say *and that one too*, so the
        // key columns are written as ordinary `NOT NULL` columns and the
        // constraint goes on the end. Both databases take the same text.
        if (desc.keys.len > 1) out = out ++ ",\n  " ++ primaryKeyClause(D, desc.keys);
        // And a foreign key spanning several columns for exactly the same
        // reason: `REFERENCES` on a column clause says *this column*, and a key
        // of two has nowhere to write the second. A key of one stays inline,
        // which is what keeps every table written before this unchanged
        // ([ADR 181](../docs/adr/181-the-marker-has-two-kinds-of-word.md)).
        for (desc.references) |r| {
            if (r.columns.len == 1) continue;
            out = out ++ ",\n  " ++ foreignKeyClause(D, r);
        }
        // And a `CHECK` the marker named, for the third time for the same
        // reason: written at creation or not written at all, on SQLite
        // ([ADR 181](../docs/adr/181-the-marker-has-two-kinds-of-word.md)).
        for (desc.checks) |ck| {
            out = out ++ ",\n  " ++ checkConstraintClause(D, ck);
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
        @setEvalBranchQuota(20_000 + 4_000 * @typeInfo(Row).@"struct".field_names.len);
        const desc = table_mod.descOf(D, Row);
        var out: [desc.uniques.len + desc.indexes.len]Named = undefined;
        for (desc.uniques, 0..) |u, i| {
            out[i] = .{ .name = u.name, .sql = uniqueStatement(D, desc, u) };
        }
        for (desc.indexes, 0..) |x, i| {
            out[desc.uniques.len + i] = .{ .name = x.name, .sql = indexStatement(D, desc, x) };
        }
        const frozen = out;
        return .{
            .table = createTable(D, Row),
            .indexes = &frozen,
            .triggers = triggersFor(D, desc, "CREATE TRIGGER "),
        };
    }
}

/// Every trigger the marker named, under whichever `CREATE TRIGGER` head the
/// caller wants.
fn triggersFor(
    comptime D: type,
    comptime desc: Desc,
    comptime head: []const u8,
) []const Named {
    comptime {
        var out: [desc.triggers.len]Named = undefined;
        for (desc.triggers, 0..) |t, i| {
            out[i] = .{ .name = t.name, .sql = triggerStatement(D, desc, head, t) };
        }
        const frozen = out;
        return &frozen;
    }
}

/// `CREATE TRIGGER "n" BEFORE UPDATE ON "t" FOR EACH ROW EXECUTE FUNCTION f()`.
///
/// **nilo writes `ON "t"` and the marker writes neither half of it**, which is
/// the whole reason `.trigger` is two words. The table is the one thing the
/// marker already knows, and a trigger carrying its own copy is a copy that
/// stops matching the day the table is renamed.
pub fn triggerStatement(
    comptime D: type,
    comptime desc: Desc,
    comptime head: []const u8,
    comptime t: NamedText,
) []const u8 {
    comptime {
        return head ++ D.quote(t.name) ++ " " ++ t.body ++
            " ON " ++ D.qualify(desc.schema, desc.table) ++ " " ++ t.tail;
    }
}

/// `CONSTRAINT "name" CHECK (body)` — a check the marker named, as it goes
/// inside a `CREATE TABLE`.
fn checkConstraintClause(comptime D: type, comptime ck: NamedText) []const u8 {
    comptime {
        return "CONSTRAINT " ++ D.quote(ck.name) ++ " CHECK (" ++ ck.body ++ ")";
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
                (if (u.ignoring_case) D.foldedIndexColumn(quoted) else quoted);
        }
        return out ++ ")";
    }
}

/// One index, with its directions and its predicate if it has them.
///
/// **The `WHERE` goes in as the `Desc` already spelled it.** `table.zig`
/// rendered it while the caller's types were still in reach, which is the only
/// place a column name and a literal's type can be checked; by here it is text,
/// the same way `sql_type` is.
pub fn indexStatement(comptime D: type, comptime desc: Desc, comptime x: Index) []const u8 {
    comptime {
        var out: []const u8 = "CREATE INDEX " ++ D.quote(x.name) ++
            " ON " ++ D.qualify(desc.schema, desc.table) ++ " (";
        for (x.columns, 0..) |c, i| {
            out = out ++ (if (i == 0) "" else ", ") ++ D.quote(c) ++ direction(x, c);
        }
        out = out ++ ")";
        if (x.where.len > 0) out = out ++ " WHERE " ++ x.where;
        return out;
    }
}

fn direction(comptime x: Index, comptime column: []const u8) []const u8 {
    comptime {
        for (x.descending) |d| {
            if (std.mem.eql(u8, d, column)) return " DESC";
        }
        return "";
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
        return .{
            .table = createIfMissing(D, Row),
            .indexes = &frozen,
            .triggers = triggersFor(D, table_mod.descOf(D, Row), D.trigger_repeatable_head),
        };
    }
}

pub fn dropTable(comptime D: type, comptime Row: type) []const u8 {
    comptime {
        // Concatenating a clause per column is what costs branches here, so the
        // budget is a function of how wide the table is rather than a constant
        // somebody raises again every few years. Comptime only: none of this
        // exists at run time.
        @setEvalBranchQuota(20_000 + 4_000 * @typeInfo(Row).@"struct".field_names.len);
        const desc = table_mod.descOf(D, Row);
        return "DROP TABLE " ++ D.qualify(desc.schema, desc.table);
    }
}

/// One column, with everything that can be said about it inline: its type, its
/// nullability, whether it is the key, what it defaults to, which words it may
/// hold, and what it points at.
///
/// **All of it inline rather than added afterwards**, which is the same
/// decision `referenceClause` already forced: SQLite has no
/// `ALTER TABLE … ADD CONSTRAINT`, so a `CHECK` that is not written at creation
/// cannot be written at all. Postgres takes the same text.
fn columnClause(comptime D: type, comptime desc: Desc, comptime c: Column) []const u8 {
    comptime {
        const quoted = D.quote(c.name);
        // A key of one column carries the `PRIMARY KEY` itself; a key of
        // several is a constraint at the end of the table, so its columns are
        // written here as the plain `NOT NULL` columns they are.
        const head = if (c.key and desc.keys.len == 1)
            D.keyColumn(quoted, c.sql_type, c.generated)
        else
            quoted ++ " " ++ c.sql_type ++ (if (c.nullable) "" else " NOT NULL");
        return head ++ defaultClause(c) ++ checkClause(D, desc, c) ++
            referenceClause(D, desc, c.name);
    }
}

fn defaultClause(comptime c: Column) []const u8 {
    comptime {
        return if (c.default) |text| " DEFAULT " ++ text else "";
    }
}

/// `CONSTRAINT "t_col_check" CHECK ("col" IN ('a', 'b'))`, for a column the Row
/// reads as a Zig enum.
///
/// Named rather than anonymous, because the name is what the diff drops when a
/// word is added to the enum — and because an anonymous constraint is reported
/// by Postgres under a name it made up, which nothing on this side can predict.
fn checkClause(comptime D: type, comptime desc: Desc, comptime c: Column) []const u8 {
    comptime {
        if (c.values.len == 0) return "";
        return " CONSTRAINT " ++ D.quote(checkName(desc, c)) ++
            " CHECK (" ++ D.quote(c.name) ++ " IN (" ++ valueList(c.values) ++ "))";
    }
}

/// The name the check over a column's words goes in under: the one `.check`
/// gave it, or `<table>_<column>_check`, which is what Postgres would have
/// called it anyway ([ADR 181](../docs/adr/181-the-marker-has-two-kinds-of-word.md)).
pub fn checkName(comptime desc: Desc, comptime c: Column) []const u8 {
    comptime {
        if (c.check.len > 0) return c.check;
        return table_mod.constraintName(desc.table, &.{c.name}, "check");
    }
}

fn valueList(comptime values: []const []const u8) []const u8 {
    comptime {
        // One step for every byte of every word, and an enum of a thousand
        // values reaches the quota on its own
        // ([ADR 126](../docs/adr/126-a-check-pays-for-its-own-branches.md)).
        var bytes: usize = 0;
        @setEvalBranchQuota(10_000 + 2 * values.len);
        for (values) |v| bytes += v.len;
        @setEvalBranchQuota(10_000 + 8 * bytes + 100 * values.len);
        var out: []const u8 = "";
        // A quote inside a word doubled, as `writeLiteral` does at run time:
        // an enum tag `@"it's"` wrote `'it's'` and the CREATE TABLE failed.
        for (values, 0..) |v, i| {
            var quoted: []const u8 = "";
            for (v) |ch| quoted = quoted ++ (if (ch == '\'') "''" else &[_]u8{ch});
            out = out ++ (if (i == 0) "" else ", ") ++ "'" ++ quoted ++ "'";
        }
        return out;
    }
}

/// `PRIMARY KEY ("tenant_id", "id")`, in the order the marker wrote them —
/// which decides the order of the index the constraint creates, and therefore
/// which prefix of the key a lookup can use.
fn primaryKeyClause(comptime D: type, comptime keys: []const []const u8) []const u8 {
    comptime {
        var out: []const u8 = "PRIMARY KEY (";
        for (keys, 0..) |k, i| {
            out = out ++ (if (i == 0) "" else ", ") ++ D.quote(k);
        }
        return out ++ ")";
    }
}

pub fn referenceClause(comptime D: type, comptime desc: Desc, comptime name: []const u8) []const u8 {
    comptime {
        for (desc.references) |r| {
            if (r.columns.len != 1) continue;
            if (!std.mem.eql(u8, r.columns[0], name)) continue;
            // The referenced table is qualified the way the Row that owns it
            // qualifies itself. Writing the bare name would resolve through
            // `search_path` instead, which is a different table on a bad day.
            return " REFERENCES " ++ D.qualify(r.schema, r.table) ++
                " (" ++ D.quote(r.targets[0]) ++ ")" ++ r.on_delete.clause();
        }
        return "";
    }
}

/// `CONSTRAINT "t_a_b_fkey" FOREIGN KEY ("a", "b") REFERENCES "u" ("x", "y")`,
/// for a key of several columns.
///
/// **Named, where the inline one is not**, and that is the database's doing
/// rather than a choice: an inline `REFERENCES` gets the name Postgres derives,
/// which is the same one `constraintName` derives, and a table constraint gets
/// whatever Postgres feels like unless it is told. The diff drops a foreign key
/// by name, so it has to be the name nilo wrote down.
pub fn foreignKeyClause(comptime D: type, comptime r: table_mod.Reference) []const u8 {
    comptime {
        return "CONSTRAINT " ++ D.quote(r.name) ++ " FOREIGN KEY (" ++
            quotedList(D, r.columns) ++ ") REFERENCES " ++ D.qualify(r.schema, r.table) ++
            " (" ++ quotedList(D, r.targets) ++ ")" ++ r.on_delete.clause();
    }
}

fn quotedList(comptime D: type, comptime columns: []const []const u8) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (columns, 0..) |c, i| out = out ++ (if (i == 0) "" else ", ") ++ D.quote(c);
        return out;
    }
}

// -- what a diff has to build ---------------------------------------------

/// `ALTER TABLE … ADD COLUMN`.
///
/// **A column that may not be null and has no default is the one statement here
/// that can fail on a table with rows in it**, and it fails loudly rather than
/// quietly. The diff says so before it writes the step.
///
/// A `.default` in the marker closes that case rather than flagging it: the
/// clause goes in here, the rows already there get the value, and there is
/// nothing left to backfill. That is the case ADR 123 named as the one where a
/// default is load-bearing, answered by the word rather than by a warning.
pub fn addColumn(comptime D: type, gpa: std.mem.Allocator, desc: Desc, c: Column) Error![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;

    try alterHead(w, desc);
    try w.writeAll(" ADD COLUMN ");
    try writeIdent(w, c.name);
    try w.print(" {s}", .{c.sql_type});
    if (!c.nullable) try w.writeAll(" NOT NULL");
    if (c.default) |text| try w.print(" DEFAULT {s}", .{text});
    if (c.values.len > 0) {
        try w.writeAll(" CONSTRAINT ");
        try writeCheckIdent(w, desc.table, c);
        try w.writeAll(" CHECK (");
        try writeIdent(w, c.name);
        try w.writeAll(" IN (");
        for (c.values, 0..) |v, i| {
            if (i > 0) try w.writeAll(", ");
            try writeLiteral(w, v);
        }
        try w.writeAll("))");
    }
    // **A key of one column goes on the column, as `CREATE TABLE` writes it.**
    // The column is new, so every row holds NULL and the key cannot fail on
    // the rows already there; SQLite has no other way to add one, and it asks
    // for a column that defaults to NULL, which the diff checks. A key of
    // several columns is a table constraint, which `addMissingColumns` and the
    // diff each write their own way.
    for (desc.references) |r| {
        if (r.columns.len != 1 or !std.mem.eql(u8, r.columns[0], c.name)) continue;
        try w.writeAll(" REFERENCES ");
        if (r.schema) |s| {
            try writeIdent(w, s);
            try w.writeAll(".");
        }
        try writeIdent(w, r.table);
        try w.writeAll(" (");
        try writeIdent(w, r.targets[0]);
        try w.writeAll(")");
        try w.writeAll(r.on_delete.clause());
        break;
    }
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

/// `SET DEFAULT` or `DROP DEFAULT`.
///
/// Neither can fail on a table with rows in it: a default is what the *next*
/// insert gets, and the rows already there keep whatever they were written
/// with. That is the difference between this and `SET NOT NULL`, and it is why
/// a column added with a default is no longer a backfill waiting to happen.
pub fn alterDefault(
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
    if (c.default) |text| {
        try w.print(" SET DEFAULT {s}", .{text});
    } else {
        try w.writeAll(" DROP DEFAULT");
    }
    return aw.toOwnedSlice();
}

/// `ALTER TABLE … DROP CONSTRAINT`, for the check over a column's words.
pub fn dropCheck(
    comptime D: type,
    gpa: std.mem.Allocator,
    desc: Desc,
    was: Column,
) Error![]const u8 {
    comptime std.debug.assert(D.can_alter_constraint);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;

    try alterHead(w, desc);
    try w.writeAll(" DROP CONSTRAINT ");
    // **The column as the snapshot had it**, because that is the name the
    // constraint is actually in the database under. A `.check` entry that gave
    // it a name, or took one away, moves the name and not the constraint.
    try writeCheckIdent(w, desc.table, was);
    return aw.toOwnedSlice();
}

/// `ALTER TABLE … DROP CONSTRAINT "name"`, for a check the marker named and no
/// longer does.
pub fn dropConstraint(
    comptime D: type,
    gpa: std.mem.Allocator,
    desc: Desc,
    name: []const u8,
) Error![]const u8 {
    comptime std.debug.assert(D.can_alter_constraint);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;

    try alterHead(w, desc);
    try w.writeAll(" DROP CONSTRAINT ");
    try writeIdent(w, name);
    return aw.toOwnedSlice();
}

/// `ALTER TABLE … ADD CONSTRAINT "name" CHECK (…)`, for a check the marker
/// named on a table that is already there.
///
/// The body goes in as it was written. nilo does not read it, and the database
/// refuses the whole version inside its transaction if it is not SQL — which is
/// the same moment a `.data` step is checked.
pub fn addNamedCheck(
    comptime D: type,
    gpa: std.mem.Allocator,
    desc: Desc,
    ck: NamedText,
) Error![]const u8 {
    comptime std.debug.assert(D.can_alter_constraint);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;

    try alterHead(w, desc);
    try w.writeAll(" ADD CONSTRAINT ");
    try writeIdent(w, ck.name);
    try w.writeAll(" CHECK (");
    try w.writeAll(ck.body);
    try w.writeAll(")");
    return aw.toOwnedSlice();
}

/// `CREATE TRIGGER "n" <when> ON "t" <run>`, built where the halves are runtime
/// text — the diff's side of `triggerStatement`.
pub fn createTrigger(
    comptime D: type,
    gpa: std.mem.Allocator,
    desc: Desc,
    t: NamedText,
) Error![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;

    try w.writeAll("CREATE TRIGGER ");
    try writeIdent(w, t.name);
    try w.writeAll(" ");
    try w.writeAll(t.body);
    try w.writeAll(" ON ");
    try alterTail(w, desc);
    try w.writeAll(" ");
    try w.writeAll(t.tail);
    _ = D;
    return aw.toOwnedSlice();
}

/// `CREATE EXTENSION IF NOT EXISTS "n"`, as a constant — what `createMissing`
/// sends (ADR 181).
pub fn createExtensionIfMissing(comptime D: type, comptime name: []const u8) []const u8 {
    comptime {
        return "CREATE EXTENSION IF NOT EXISTS " ++ D.quote(name);
    }
}

/// `CREATE VIEW "n" AS <select>` under whichever head the caller wants, as a
/// constant. The entry is the SELECT and nilo writes the head, for the reason
/// a trigger is two words: the name is the thing the schema already knows.
pub fn viewStatement(comptime D: type, comptime head: []const u8, comptime v: NamedText) []const u8 {
    comptime {
        return head ++ D.quote(v.name) ++ " AS " ++ std.mem.trim(u8, v.body, &std.ascii.whitespace);
    }
}

/// The same four, built where the name is runtime text — the diff's side.
pub fn createExtension(gpa: std.mem.Allocator, name: []const u8) Error![]const u8 {
    return oneIdent(gpa, "CREATE EXTENSION IF NOT EXISTS ", name);
}

pub fn dropExtension(gpa: std.mem.Allocator, name: []const u8) Error![]const u8 {
    return oneIdent(gpa, "DROP EXTENSION IF EXISTS ", name);
}

pub fn dropFunction(gpa: std.mem.Allocator, name: []const u8) Error![]const u8 {
    return oneIdent(gpa, "DROP FUNCTION IF EXISTS ", name);
}

pub fn dropView(gpa: std.mem.Allocator, name: []const u8) Error![]const u8 {
    return oneIdent(gpa, "DROP VIEW IF EXISTS ", name);
}

pub fn createView(gpa: std.mem.Allocator, v: NamedText) Error![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("CREATE VIEW ");
    try writeIdent(w, v.name);
    try w.writeAll(" AS ");
    try w.writeAll(std.mem.trim(u8, v.body, &std.ascii.whitespace));
    return aw.toOwnedSlice();
}

fn oneIdent(gpa: std.mem.Allocator, head: []const u8, name: []const u8) Error![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    try aw.writer.writeAll(head);
    try writeIdent(&aw.writer, name);
    return aw.toOwnedSlice();
}

/// `DROP TRIGGER "n" ON "t"` on Postgres, `DROP TRIGGER "n"` on SQLite.
///
/// The two databases scope a trigger name differently — per table on one, per
/// database on the other — and each refuses the other's spelling, so this is
/// one of the few places a Dialect answers with a `bool` rather than with text.
pub fn dropTrigger(
    comptime D: type,
    gpa: std.mem.Allocator,
    desc: Desc,
    name: []const u8,
) Error![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;

    try w.writeAll("DROP TRIGGER ");
    try writeIdent(w, name);
    if (comptime D.trigger_drop_names_table) {
        try w.writeAll(" ON ");
        try alterTail(w, desc);
    }
    return aw.toOwnedSlice();
}

/// `ALTER TABLE … ADD CONSTRAINT … CHECK (… IN (…))`, from the words the Row's
/// enum has now.
pub fn addCheck(
    comptime D: type,
    gpa: std.mem.Allocator,
    desc: Desc,
    c: Column,
) Error![]const u8 {
    comptime std.debug.assert(D.can_alter_constraint);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;

    try alterHead(w, desc);
    try w.writeAll(" ADD CONSTRAINT ");
    try writeCheckIdent(w, desc.table, c);
    try w.writeAll(" CHECK (");
    try writeIdent(w, c.name);
    try w.writeAll(" IN (");
    for (c.values, 0..) |v, i| {
        if (i > 0) try w.writeAll(", ");
        try writeLiteral(w, v);
    }
    try w.writeAll("))");
    return aw.toOwnedSlice();
}

/// `"<table>_<column>_check"`, or the name `.check` gave it, built where the
/// halves are runtime text.
///
/// The comptime half of this is `checkName`, and the two have to agree: one
/// writes the constraint at `CREATE` and the other drops it at `ALTER`.
fn writeCheckIdent(w: *std.Io.Writer, table: []const u8, c: Column) Error!void {
    if (c.check.len > 0) return writeIdent(w, c.check);
    if (table.len == 0 or c.name.len == 0) return error.BadIdentifier;
    if (std.mem.indexOfScalar(u8, table, '"') != null) return error.BadIdentifier;
    if (std.mem.indexOfScalar(u8, c.name, '"') != null) return error.BadIdentifier;
    try w.print("\"{s}_{s}_check\"", .{ table, c.name });
}

/// One word as a SQL literal, with a quote inside it doubled — the same rule
/// `table.zig` applies while compiling, applied here to text out of a snapshot.
fn writeLiteral(w: *std.Io.Writer, text: []const u8) Error!void {
    try w.writeAll("'");
    for (text) |ch| {
        if (ch == '\'') try w.writeAll("'");
        try w.writeByte(ch);
    }
    try w.writeAll("'");
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

/// `ALTER INDEX … RENAME TO`, for an index following a column `.was`
/// renamed. Postgres only; SQLite has no statement that renames an index.
pub fn renameIndex(
    comptime D: type,
    gpa: std.mem.Allocator,
    schema: ?[]const u8,
    from: []const u8,
    to: []const u8,
) Error![]const u8 {
    comptime std.debug.assert(D.can_alter_constraint);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;

    try w.writeAll("ALTER INDEX ");
    if (schema) |s| {
        try writeIdent(w, s);
        try w.writeAll(".");
    }
    try writeIdent(w, from);
    try w.writeAll(" RENAME TO ");
    try writeIdent(w, to);
    return aw.toOwnedSlice();
}

/// `ALTER TABLE … RENAME CONSTRAINT`, for a foreign key following a column
/// `.was` renamed.
pub fn renameConstraint(
    comptime D: type,
    gpa: std.mem.Allocator,
    desc: Desc,
    from: []const u8,
    to: []const u8,
) Error![]const u8 {
    comptime std.debug.assert(D.can_alter_constraint);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;

    try alterHead(w, desc);
    try w.writeAll(" RENAME CONSTRAINT ");
    try writeIdent(w, from);
    try w.writeAll(" TO ");
    try writeIdent(w, to);
    return aw.toOwnedSlice();
}

/// `ALTER TABLE … RENAME CONSTRAINT` for the derived check over a column's
/// words, from `<table>_<from>_check` to `<table>_<to>_check`: what a column
/// `.was` renamed leaves behind on Postgres (ADR 123).
pub fn renameCheck(
    comptime D: type,
    gpa: std.mem.Allocator,
    desc: Desc,
    from: []const u8,
    to: []const u8,
) Error![]const u8 {
    comptime std.debug.assert(D.can_alter_constraint);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;

    try alterHead(w, desc);
    try w.writeAll(" RENAME CONSTRAINT ");
    try writeCheckIdent(w, desc.table, .{ .name = from, .sql_type = "" });
    try w.writeAll(" TO ");
    try writeCheckIdent(w, desc.table, .{ .name = to, .sql_type = "" });
    return aw.toOwnedSlice();
}

fn alterHead(w: *std.Io.Writer, desc: Desc) Error!void {
    try w.writeAll("ALTER TABLE ");
    try alterTail(w, desc);
}

/// The table, qualified the way the Row qualifies itself.
fn alterTail(w: *std.Io.Writer, desc: Desc) Error!void {
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

test "an enum tag holding a quote is written with the quote doubled" {
    const Said = enum { @"it's", plain };
    const Remark = struct {
        pub const nilo_table = .{ .name = "remarks", .key = .id };
        id: i64,
        said: Said,
    };
    const sql = comptime createTable(Pg, Remark);
    try testing.expect(std.mem.indexOf(u8, sql, "IN ('it''s', 'plain')") != null);
}

test "a foreign key of two columns is a table constraint, and one of one stays inline" {
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
                .org_id = .{ Org, .id },
                .board = .{
                    .columns = .{ .board_id, .org_id },
                    .to = .{ Board, .{ .id, .org_id } },
                    .on_delete = .cascade,
                },
            },
        };
        id: i64,
        org_id: i64,
        board_id: i64,
    };

    // `org_id` carries the one-column key inline and appears again inside the
    // two-column one, which is the ordinary shape of "on the same board": the
    // tenant column is half of every key on the table.
    try testing.expectEqualStrings(
        \\CREATE TABLE "cards" (
        \\  "id" int8 GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
        \\  "org_id" int8 NOT NULL REFERENCES "orgs" ("id"),
        \\  "board_id" int8 NOT NULL,
        \\  CONSTRAINT "cards_board_id_org_id_fkey" FOREIGN KEY ("board_id", "org_id") REFERENCES "boards" ("id", "org_id") ON DELETE CASCADE
        \\)
    , comptime createTable(Pg, Card));

    // SQLite takes the same text, which is the whole reason a foreign key is
    // written at creation rather than added afterwards.
    try testing.expect(std.mem.indexOf(
        u8,
        comptime createTable(Lite, Card),
        "CONSTRAINT \"cards_board_id_org_id_fkey\" FOREIGN KEY (\"board_id\", \"org_id\")",
    ) != null);
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
        "CREATE UNIQUE INDEX \"users_email_key\" ON \"users\" (lower(\"email\") text_pattern_ops)",
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

const Seat = struct {
    pub const nilo_table = .{ .name = "seats", .key = .{ .tenant_id, .id } };

    tenant_id: i64,
    id: i64,
    label: []const u8,
};

test "a key spanning two columns is a table constraint, not a clause on a column" {
    try testing.expectEqualStrings(
        "CREATE TABLE \"seats\" (\n" ++
            "  \"tenant_id\" int8 NOT NULL,\n" ++
            "  \"id\" int8 NOT NULL,\n" ++
            "  \"label\" text NOT NULL,\n" ++
            "  PRIMARY KEY (\"tenant_id\", \"id\")\n)",
        comptime createTable(Pg, Seat),
    );
}

test "both databases take the same composite key clause" {
    try testing.expect(std.mem.indexOf(
        u8,
        comptime createTable(Lite, Seat),
        "PRIMARY KEY (\"tenant_id\", \"id\")",
    ) != null);
    // And no column carries `INTEGER PRIMARY KEY`, which on SQLite would be
    // the rowid alias and a second, contradicting key (ADR 050).
    try testing.expect(std.mem.indexOf(
        u8,
        comptime createTable(Lite, Seat),
        "INTEGER PRIMARY KEY",
    ) == null);
}

test "a composite key is never generated, because there is nothing to invent" {
    // An integer key of one column is what a sequence is for; two columns are
    // a tenant and an id the program already holds.
    const desc = comptime table_mod.descOf(Pg, Seat);
    try testing.expect(desc.column("id").?.key);
    try testing.expect(desc.column("tenant_id").?.key);
    try testing.expect(!desc.column("id").?.generated);
}

test "a key of one column still writes PRIMARY KEY on the column itself" {
    try testing.expect(std.mem.indexOf(
        u8,
        comptime createTable(Pg, Org),
        "GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY",
    ) != null);
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

// -- the words that live inside one Row (ADR 181) ------------------------

const Priority = enum { urgent, normal };

const Task = struct {
    pub const nilo_table = .{
        .name = "tasks",
        .key = .id,
        .default = .{ .created_at = .now, .priority = .normal, .done = false },
        .index = .{
            .{ .columns = .{.assignee_id}, .where = .{ .assignee_id = .{ .ne = null } } },
            .{ .columns = .{ .org_id, .{ .created_at = .desc } }, .name = "tasks_newest_first" },
        },
    };

    id: i64,
    org_id: i64,
    priority: Priority,
    done: bool,
    assignee_id: ?i64,
    created_at: types.Timestamp,
};

test "a default and a column's words are written inline, beside the type and the reference" {
    // Inline rather than added afterwards, and that is SQLite's constraint
    // rather than tidiness: it has no `ALTER TABLE … ADD CONSTRAINT`, so a
    // CHECK not written at creation cannot be written at all.
    try testing.expectEqualStrings(
        \\CREATE TABLE "tasks" (
        \\  "id" int8 GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
        \\  "org_id" int8 NOT NULL,
        \\  "priority" text NOT NULL DEFAULT 'normal' CONSTRAINT "tasks_priority_check" CHECK ("priority" IN ('urgent', 'normal')),
        \\  "done" bool NOT NULL DEFAULT FALSE,
        \\  "assignee_id" int8,
        \\  "created_at" timestamptz NOT NULL DEFAULT now()
        \\)
    , comptime createTable(Pg, Task));
}

test "the same table on SQLite moves only what SQLite spells differently" {
    // The literal defaults are the same text. `now()` is not: a Timestamp
    // there is microseconds in an INTEGER column (ADR 067), so the Dialect
    // spells the clock.
    const sql = comptime createTable(Lite, Task);
    try testing.expect(std.mem.indexOf(u8, sql, "\"done\" INTEGER NOT NULL DEFAULT FALSE") != null);
    try testing.expect(std.mem.indexOf(u8, sql, "DEFAULT " ++ Lite.now_default) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        sql,
        "CONSTRAINT \"tasks_priority_check\" CHECK (\"priority\" IN ('urgent', 'normal'))",
    ) != null);
}

test "a partial index carries its WHERE, and an ordered one its DESC" {
    const made = comptime createdFor(Pg, Task);
    try testing.expectEqualStrings(
        "CREATE INDEX \"tasks_assignee_id_idx\" ON \"tasks\" (\"assignee_id\") " ++
            "WHERE \"assignee_id\" IS NOT NULL",
        made.indexes[0].sql,
    );
    try testing.expectEqualStrings(
        "CREATE INDEX \"tasks_newest_first\" ON \"tasks\" (\"org_id\", \"created_at\" DESC)",
        made.indexes[1].sql,
    );

    // And the `IF NOT EXISTS` form is still the same statement with four words
    // moved into the front of it, predicate and all.
    const guarded = comptime createdIfMissing(Pg, Task);
    try testing.expect(std.mem.endsWith(u8, guarded.indexes[0].sql, "WHERE \"assignee_id\" IS NOT NULL"));
    try testing.expect(std.mem.startsWith(u8, guarded.indexes[0].sql, "CREATE INDEX IF NOT EXISTS "));
}

test "a column added to a table that already has rows takes its default with it" {
    const gpa = testing.allocator;
    const desc = comptime table_mod.descOf(Pg, Task);

    const added = try addColumn(Pg, gpa, desc, desc.column("done").?);
    defer gpa.free(added);
    try testing.expectEqualStrings(
        "ALTER TABLE \"tasks\" ADD COLUMN \"done\" bool NOT NULL DEFAULT FALSE",
        added,
    );

    // And a column with words brings its check, which is the one nilo can
    // write here: SQLite refuses the whole change one layer up.
    const worded = try addColumn(Pg, gpa, desc, desc.column("priority").?);
    defer gpa.free(worded);
    try testing.expectEqualStrings(
        "ALTER TABLE \"tasks\" ADD COLUMN \"priority\" text NOT NULL DEFAULT 'normal' " ++
            "CONSTRAINT \"tasks_priority_check\" CHECK (\"priority\" IN ('urgent', 'normal'))",
        worded,
    );
}

test "a default is set and dropped by name, and a check is replaced by dropping it" {
    const gpa = testing.allocator;
    const desc = comptime table_mod.descOf(Pg, Task);

    const set = try alterDefault(Pg, gpa, desc, desc.column("created_at").?);
    defer gpa.free(set);
    try testing.expectEqualStrings(
        "ALTER TABLE \"tasks\" ALTER COLUMN \"created_at\" SET DEFAULT now()",
        set,
    );

    var gone = desc.column("created_at").?;
    gone.default = null;
    const dropped = try alterDefault(Pg, gpa, desc, gone);
    defer gpa.free(dropped);
    try testing.expectEqualStrings(
        "ALTER TABLE \"tasks\" ALTER COLUMN \"created_at\" DROP DEFAULT",
        dropped,
    );

    const off = try dropCheck(Pg, gpa, desc, desc.column("priority").?);
    defer gpa.free(off);
    try testing.expectEqualStrings(
        "ALTER TABLE \"tasks\" DROP CONSTRAINT \"tasks_priority_check\"",
        off,
    );

    const on = try addCheck(Pg, gpa, desc, desc.column("priority").?);
    defer gpa.free(on);
    try testing.expectEqualStrings(
        "ALTER TABLE \"tasks\" ADD CONSTRAINT \"tasks_priority_check\" " ++
            "CHECK (\"priority\" IN ('urgent', 'normal'))",
        on,
    );
    // The name the `ALTER` drops is the name the `CREATE` wrote, which is the
    // one thing these two have to agree about.
    const named = comptime checkName(desc, desc.column("priority").?);
    try testing.expect(std.mem.indexOf(u8, comptime createTable(Pg, Task), named) != null);
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
        "CREATE UNIQUE INDEX IF NOT EXISTS \"users_email_key\" ON \"users\" (lower(\"email\") text_pattern_ops)",
        made.indexes[0].sql,
    );
    try testing.expectEqualStrings(
        "CREATE INDEX IF NOT EXISTS \"users_created_at_idx\" ON \"users\" (\"created_at\")",
        made.indexes[2].sql,
    );
}

// -- the second kind of word (ADR 181) ----------------------------------

const Audited = struct {
    pub const nilo_table = .{
        .name = "app.audited",
        .key = .id,
        .check = .{
            .audited_amount_is_positive = "amount > 0",
            .audited_kind_is_known = .{ .words_of = .kind },
        },
        .trigger = .{
            .audited_touch = .{
                .when = "BEFORE UPDATE",
                .run = "FOR EACH ROW EXECUTE FUNCTION set_updated_at()",
            },
        },
    };

    id: i64,
    amount: i64,
    kind: Priority,
};

test "a check the marker named is a table constraint, and a named enum check moves the name" {
    // The body goes in as written and the name is the key: both halves of what
    // a check is, and nilo parses neither.
    try testing.expectEqualStrings(
        \\CREATE TABLE "app"."audited" (
        \\  "id" int8 GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
        \\  "amount" int8 NOT NULL,
        \\  "kind" text NOT NULL CONSTRAINT "audited_kind_is_known" CHECK ("kind" IN ('urgent', 'normal')),
        \\  CONSTRAINT "audited_amount_is_positive" CHECK (amount > 0)
        \\)
    , comptime createTable(Pg, Audited));
}

test "a trigger is one statement after the table, with the table written between the halves" {
    const made = comptime createdFor(Pg, Audited);
    try testing.expectEqual(@as(usize, 1), made.triggers.len);
    try testing.expectEqualStrings("audited_touch", made.triggers[0].name);
    try testing.expectEqualStrings(
        "CREATE TRIGGER \"audited_touch\" BEFORE UPDATE ON \"app\".\"audited\" " ++
            "FOR EACH ROW EXECUTE FUNCTION set_updated_at()",
        made.triggers[0].sql,
    );

    // And nothing at all for a Row that named none.
    try testing.expectEqual(@as(usize, 0), comptime createdFor(Pg, User).triggers.len);
}

test "the repeatable form of a trigger is each database's own, because neither has the other's" {
    // Postgres has no `CREATE TRIGGER IF NOT EXISTS` in any version, and SQLite
    // has no `OR REPLACE`. This is the one statement where the two spellings do
    // not overlap at all.
    try testing.expect(std.mem.startsWith(
        u8,
        comptime createdIfMissing(Pg, Audited).triggers[0].sql,
        "CREATE OR REPLACE TRIGGER \"audited_touch\" ",
    ));
    try testing.expect(std.mem.startsWith(
        u8,
        comptime createdIfMissing(Lite, Audited).triggers[0].sql,
        "CREATE TRIGGER IF NOT EXISTS \"audited_touch\" ",
    ));
}

test "a check is added and dropped by the name the marker gave it, and a trigger by each database's rule" {
    const gpa = testing.allocator;
    const desc = comptime table_mod.descOf(Pg, Audited);

    const added = try addNamedCheck(Pg, gpa, desc, desc.checks[0]);
    defer gpa.free(added);
    try testing.expectEqualStrings(
        "ALTER TABLE \"app\".\"audited\" ADD CONSTRAINT \"audited_amount_is_positive\" " ++
            "CHECK (amount > 0)",
        added,
    );

    const gone = try dropConstraint(Pg, gpa, desc, "audited_amount_is_positive");
    defer gpa.free(gone);
    try testing.expectEqualStrings(
        "ALTER TABLE \"app\".\"audited\" DROP CONSTRAINT \"audited_amount_is_positive\"",
        gone,
    );

    // The enum column's check now drops by the name `.check` gave it rather
    // than by `<table>_<column>_check`, which is the whole of item 12.
    const off = try dropCheck(Pg, gpa, desc, desc.column("kind").?);
    defer gpa.free(off);
    try testing.expectEqualStrings(
        "ALTER TABLE \"app\".\"audited\" DROP CONSTRAINT \"audited_kind_is_known\"",
        off,
    );

    const made = try createTrigger(Pg, gpa, desc, desc.triggers[0]);
    defer gpa.free(made);
    try testing.expectEqualStrings(comptime createdFor(Pg, Audited).triggers[0].sql, made);

    const pg_drop = try dropTrigger(Pg, gpa, desc, "audited_touch");
    defer gpa.free(pg_drop);
    try testing.expectEqualStrings(
        "DROP TRIGGER \"audited_touch\" ON \"app\".\"audited\"",
        pg_drop,
    );

    const lite_drop = try dropTrigger(Lite, gpa, desc, "audited_touch");
    defer gpa.free(lite_drop);
    try testing.expectEqualStrings("DROP TRIGGER \"audited_touch\"", lite_drop);
}
