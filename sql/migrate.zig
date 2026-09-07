//! Migrations: the diff, the plan, and the record of what has been applied
//! ([ADR 0153](../docs/adr/0153-a-migration-is-a-diff-against-a-snapshot.md)).
//!
//! ```zig
//! const tables = comptime sql.migrate.tablesOf(Db.Dialect, &.{ Org, User, Post });
//!
//! // No database anywhere in these two lines.
//! const before = try sql.migrate.snapshot.parse(run.arena(), text, null);
//! const change = try sql.migrate.plan(run.arena(), Db.Dialect, tables, before);
//! ```
//!
//! ## What is settled while compiling, and what is not
//!
//! `tablesOf` is the desired schema, and every byte of SQL in it is a constant
//! in the binary: the `CREATE TABLE`, every index, and the order they have to
//! run in. Only the diff against a snapshot is runtime work, because the
//! snapshot is a file.
//!
//! That split is what the two cheapest paths are built on.
//!
//! - **`createMissing` allocates nothing.** It creates every table a list of
//!   Rows describes, and every statement it sends is already in `.rodata`.
//!   That is the whole of what a SQLite application needs at startup, and it
//!   is what `stress/arsip` writes by hand today.
//! - **`expect` costs one query and allocates nothing when it passes**, which
//!   is every boot after the first. It is the check that stops a binary built
//!   for schema version 9 from serving a database that is still at 7.
//!
//! ## The create order is worked out while compiling
//!
//! Foreign keys are written inline (`ddl.zig` says why), so Postgres requires
//! that a table be created after the ones it points at. `tablesOf` sorts for
//! that, and **a cycle is a compile error** naming the tables in it rather than
//! a deadlock at apply time. A table pointing at itself is not a cycle and is
//! left alone.
//!
//! ## What the diff refuses rather than guesses
//!
//! Two things, and both are refused with every instance named at once rather
//! than the first — the same rule `nilo_config` follows for a bad setting.
//!
//! - **A type or nullability change on SQLite.** `ALTER TABLE` there adds,
//!   drops and renames a column and does nothing else, so the change is a
//!   four-statement rebuild that has to preserve every index and every row.
//!   The Problem spells the four out.
//! - **A foreign key added to a table that already exists**, on either
//!   database. Postgres can write it in one statement, and that statement takes
//!   an exclusive lock and scans the whole table. The safe form is two
//!   statements — `ADD CONSTRAINT … NOT VALID`, then `VALIDATE CONSTRAINT` —
//!   and which one somebody wants is an operational decision rather than
//!   something to pick for them at three in the morning.

const std = @import("std");
const core = @import("nilo_core");
const row_mod = @import("row.zig");
const table_mod = @import("table.zig");
const types = @import("types.zig");

pub const ddl = @import("ddl.zig");
pub const snapshot = @import("snapshot.zig");

const Desc = table_mod.Desc;
const Column = table_mod.Column;

// -- the desired side, which is entirely comptime -------------------------

/// One table as the types describe it, and the SQL that makes it.
pub const Table = struct {
    desc: Desc,
    created: ddl.Created,
};

pub fn tableOf(comptime D: type, comptime Row: type) Table {
    comptime {
        return .{ .desc = table_mod.descOf(D, Row), .created = ddl.createdFor(D, Row) };
    }
}

/// The Rows, in the order their tables have to be created.
///
/// **The sort is the whole reason this exists**, and it is settled while
/// compiling. Foreign keys are written inline (`ddl.zig` says why), so Postgres
/// checks that a referenced table is there, and a schema whose file order does
/// not match its reference order would fail on the first `CREATE`.
///
/// A plain repeated pass rather than anything clever: a schema has tens of
/// tables, this runs while compiling, and the version somebody can read is
/// worth more than the version that is asymptotically better. A table pointing
/// at itself is not a ring and is left alone.
pub fn orderOf(comptime D: type, comptime Rows: []const type) []const type {
    comptime {
        @setEvalBranchQuota(50_000 + 20_000 * Rows.len);

        var descs: [Rows.len]Desc = undefined;
        for (Rows, 0..) |R, i| descs[i] = table_mod.descOf(D, R);

        var out: [Rows.len]type = undefined;
        var placed: [Rows.len]bool = @splat(false);
        var n: usize = 0;

        while (n < Rows.len) {
            var moved = false;
            for (Rows, 0..) |R, i| {
                if (placed[i]) continue;
                if (!ready(&descs, &placed, descs[i], i)) continue;
                out[n] = R;
                placed[i] = true;
                n += 1;
                moved = true;
            }
            if (!moved) @compileError(
                "nilo: these tables point at each other in a ring, so none of them can " ++
                    "be created first:\n  " ++ ringNames(&descs, &placed) ++ "\n" ++
                    "  A foreign key is written inline, which is the only shape SQLite " ++
                    "has. Break the ring by leaving one `.references` out and adding " ++
                    "that constraint in a step of its own.",
            );
        }
        const frozen = out;
        return &frozen;
    }
}

/// Every table as the types describe it, in create order, with the SQL that
/// makes it. This is the desired half of every diff.
pub fn tablesOf(comptime D: type, comptime Rows: []const type) []const Table {
    comptime {
        const ordered = orderOf(D, Rows);
        var out: [ordered.len]Table = undefined;
        for (ordered, 0..) |R, i| out[i] = tableOf(D, R);
        const frozen = out;
        return &frozen;
    }
}

/// The same tables, in the same order, as statements that do nothing when the
/// table is already there. What `createMissing` sends.
pub fn missingOf(comptime D: type, comptime Rows: []const type) []const ddl.Created {
    comptime {
        const ordered = orderOf(D, Rows);
        var out: [ordered.len]ddl.Created = undefined;
        for (ordered, 0..) |R, i| out[i] = ddl.createdIfMissing(D, R);
        const frozen = out;
        return &frozen;
    }
}

fn ready(
    comptime descs: []const Desc,
    comptime placed: []const bool,
    comptime d: Desc,
    comptime self: usize,
) bool {
    comptime {
        for (d.references) |r| {
            for (descs, 0..) |other, j| {
                if (j == self) continue;
                if (placed[j]) continue;
                if (std.mem.eql(u8, other.table, r.table) and
                    table_mod.sameSchema(other.schema, r.schema)) return false;
            }
        }
        return true;
    }
}

fn ringNames(comptime descs: []const Desc, comptime placed: []const bool) []const u8 {
    comptime {
        var out: []const u8 = "";
        var first = true;
        for (descs, 0..) |d, i| {
            if (placed[i]) continue;
            out = out ++ (if (first) "" else ", ") ++ d.table;
            first = false;
        }
        return out;
    }
}

/// The snapshot these tables would be written down as.
///
/// The `row` field is cleared on the way, which is the one difference between a
/// `Desc` and what goes in the file: renaming the Zig struct is not a schema
/// change and should not read as one.
pub fn snapshotOf(
    gpa: std.mem.Allocator,
    comptime D: type,
    version: u32,
    tables: []const Table,
) !snapshot.Doc {
    const out = try gpa.alloc(Desc, tables.len);
    for (tables, 0..) |t, i| {
        out[i] = t.desc;
        out[i].row = "";
        out[i].renames = &.{};
    }
    return .{ .version = version, .dialect = D.name, .tables = out };
}

// -- the plan ------------------------------------------------------------

pub const Kind = enum {
    create_table,
    drop_table,
    add_column,
    drop_column,
    rename_column,
    change_type,
    change_null,
    create_index,
    drop_index,

    /// A statement somebody wrote, which the diff never produces.
    ///
    /// **This is the variant that makes expand and contract expressible**, and
    /// it is why a version is a list of steps rather than one statement: the
    /// backfill that fills a new column goes between the `add_column` that made
    /// it and the `change_null` that tightens it, in one transaction, in one
    /// version. `up`/`down` cannot say that, and neither can a tool whose unit
    /// is a single generated statement.
    data,
};

pub const Step = struct {
    kind: Kind,
    sql: []const u8,
    /// One line saying why, for the generated file's comment and for `status`.
    why: []const u8,
    /// Running it loses data that nothing can bring back.
    destructive: bool = false,
    /// It can fail on a table that already has rows, and the failure is loud.
    /// A `NOT NULL` column added to a populated table is the whole of this.
    needs_backfill: bool = false,
};

/// Something the diff will not write, with the reason and what to do instead.
///
/// Every one of them is collected rather than the first being returned, because
/// finding out about the second one after fixing the first is the twenty
/// questions game `Bound(T)` exists to end, one layer down.
pub const Problem = struct {
    table: []const u8,
    column: []const u8 = "",
    text: []const u8,
};

pub const Plan = struct {
    steps: []const Step,
    problems: []const Problem,

    pub fn isEmpty(self: Plan) bool {
        return self.steps.len == 0;
    }

    /// Whether anything in it loses data. `generate` refuses to write a plan
    /// that does until the caller says so at the command line, and records the
    /// saying in the generated file's header.
    pub fn destructive(self: Plan) bool {
        for (self.steps) |s| {
            if (s.destructive) return true;
        }
        return false;
    }

    pub fn needsBackfill(self: Plan) bool {
        for (self.steps) |s| {
            if (s.needs_backfill) return true;
        }
        return false;
    }
};

/// The difference between what the types say and what the snapshot says.
///
/// Nothing here touches a database. Every allocation comes out of `gpa`, which
/// is meant to be a `Run`'s arena, so the whole plan is thrown away in one call.
pub fn plan(
    gpa: std.mem.Allocator,
    comptime D: type,
    desired: []const Table,
    before: snapshot.Doc,
) !Plan {
    var steps: std.ArrayList(Step) = .empty;
    var problems: std.ArrayList(Problem) = .empty;

    if (before.tables.len > 0 and !std.mem.eql(u8, before.dialect, D.name)) {
        try problems.append(gpa, .{
            .table = "",
            .text = try std.fmt.allocPrint(
                gpa,
                "the snapshot was written against the {s} dialect and these types are " ++
                    "being read as {s}. Every column would look changed, because `int8` " ++
                    "and `INTEGER` are the same column and not the same text.",
                .{ before.dialect, D.name },
            ),
        });
        return .{ .steps = &.{}, .problems = try problems.toOwnedSlice(gpa) };
    }

    for (desired) |t| {
        const old = before.table(t.desc.schema, t.desc.table) orelse {
            try steps.append(gpa, .{
                .kind = .create_table,
                .sql = t.created.table,
                .why = try std.fmt.allocPrint(gpa, "create {s}", .{t.desc.table}),
            });
            for (t.created.indexes) |made| {
                try steps.append(gpa, .{
                    .kind = .create_index,
                    .sql = made.sql,
                    .why = try std.fmt.allocPrint(gpa, "index {s}", .{made.name}),
                });
            }
            continue;
        };
        try diffTable(gpa, D, t, old, &steps, &problems);
    }

    // A table the snapshot has and the types do not. Dropped last, so that
    // anything still pointing at it has been dropped first.
    for (before.tables) |old| {
        if (has(desired, old)) continue;
        try steps.append(gpa, .{
            .kind = .drop_table,
            .sql = try dropTableSql(gpa, old),
            .why = try std.fmt.allocPrint(gpa, "drop {s}, which no Row describes", .{old.table}),
            .destructive = true,
        });
    }

    return .{
        .steps = try steps.toOwnedSlice(gpa),
        .problems = try problems.toOwnedSlice(gpa),
    };
}

fn has(desired: []const Table, old: Desc) bool {
    for (desired) |t| {
        if (std.mem.eql(u8, t.desc.table, old.table) and
            table_mod.sameSchema(t.desc.schema, old.schema)) return true;
    }
    return false;
}

fn diffTable(
    gpa: std.mem.Allocator,
    comptime D: type,
    t: Table,
    old: Desc,
    steps: *std.ArrayList(Step),
    problems: *std.ArrayList(Problem),
) !void {
    // **Renames come first, and everything after reads the table as though
    // they had already run.** Doing it the other way round turns one
    // `RENAME COLUMN` into a drop and an add, and the column arrives empty.
    var renamed: std.ArrayList(table_mod.Rename) = .empty;
    for (t.desc.renames) |r| {
        if (old.column(r.from) == null) continue; // already applied; the entry is spent
        if (old.column(r.to) != null) {
            try problems.append(gpa, .{
                .table = t.desc.table,
                .column = r.to,
                .text = try std.fmt.allocPrint(
                    gpa,
                    "`.was` says `{s}` used to be `{s}`, and the schema already has both. " ++
                        "Nothing can be renamed onto a column that is there.",
                    .{ r.to, r.from },
                ),
            });
            continue;
        }
        try steps.append(gpa, .{
            .kind = .rename_column,
            .sql = try ddl.renameColumn(D, gpa, t.desc, r.from, r.to),
            .why = try std.fmt.allocPrint(gpa, "rename {s}.{s} to {s}", .{ t.desc.table, r.from, r.to }),
        });
        try renamed.append(gpa, r);
    }

    for (t.desc.columns) |c| {
        const was = columnBefore(old, c.name, renamed.items) orelse {
            try steps.append(gpa, .{
                .kind = .add_column,
                .sql = try ddl.addColumn(D, gpa, t.desc, c),
                .why = try std.fmt.allocPrint(gpa, "add {s}.{s}", .{ t.desc.table, c.name }),
                .needs_backfill = !c.nullable,
            });
            continue;
        };
        if (c.sameAs(was)) continue;

        if (c.key != was.key or c.generated != was.generated) {
            try problems.append(gpa, .{
                .table = t.desc.table,
                .column = c.name,
                .text = try std.fmt.allocPrint(
                    gpa,
                    "the key moved, or stopped being generated. Neither database changes " ++
                        "a primary key in place, and doing it by halves leaves rows nothing " ++
                        "can address. Write it as a step.",
                    .{},
                ),
            });
            continue;
        }

        if (!D.can_alter_column) {
            try problems.append(gpa, .{
                .table = t.desc.table,
                .column = c.name,
                .text = try std.fmt.allocPrint(
                    gpa,
                    "{s}.{s} is {s} and was {s}. The {s} dialect cannot change a column's " ++
                        "type or nullability in place: `ALTER TABLE` adds, drops and renames " ++
                        "and does nothing else. The four statements are CREATE a new table " ++
                        "with the shape you want, INSERT INTO it SELECT from the old one, " ++
                        "DROP the old one, ALTER TABLE RENAME the new one. Write them as a " ++
                        "step, and recreate the indexes: they go with the table.",
                    .{ t.desc.table, c.name, c.sql_type, was.sql_type, D.name },
                ),
            });
            continue;
        }

        if (!std.mem.eql(u8, c.sql_type, was.sql_type)) {
            try steps.append(gpa, .{
                .kind = .change_type,
                .sql = try ddl.alterType(D, gpa, t.desc, c),
                .why = try std.fmt.allocPrint(
                    gpa,
                    "{s}.{s} becomes {s}, from {s}",
                    .{ t.desc.table, c.name, c.sql_type, was.sql_type },
                ),
            });
        }
        if (c.nullable != was.nullable) {
            try steps.append(gpa, .{
                .kind = .change_null,
                .sql = try ddl.alterNullability(D, gpa, t.desc, c),
                .why = try std.fmt.allocPrint(
                    gpa,
                    "{s}.{s} {s} be null",
                    .{ t.desc.table, c.name, if (c.nullable) "may now" else "may no longer" },
                ),
                .needs_backfill = !c.nullable,
            });
        }
    }

    for (old.columns) |oc| {
        if (t.desc.column(oc.name) != null) continue;
        if (wasRenamed(renamed.items, oc.name)) continue;
        try steps.append(gpa, .{
            .kind = .drop_column,
            .sql = try ddl.dropColumn(D, gpa, t.desc, oc.name),
            .why = try std.fmt.allocPrint(
                gpa,
                "drop {s}.{s}, which no field reads",
                .{ t.desc.table, oc.name },
            ),
            .destructive = true,
        });
    }

    try diffIndexes(gpa, D, t, old, steps);
    try diffReferences(gpa, t, old, problems);
}

/// A column as the snapshot had it, looking through any rename that has just
/// been written.
fn columnBefore(old: Desc, name: []const u8, renames: []const table_mod.Rename) ?Column {
    if (old.column(name)) |c| return c;
    for (renames) |r| {
        if (std.mem.eql(u8, r.to, name)) return old.column(r.from);
    }
    return null;
}

fn wasRenamed(renames: []const table_mod.Rename, from: []const u8) bool {
    for (renames) |r| {
        if (std.mem.eql(u8, r.from, from)) return true;
    }
    return false;
}

/// Indexes and uniques, matched by name.
///
/// **The name is the identity**, and it is derived from the table and the
/// columns (`users_email_key`), so an index whose columns changed has a
/// different name and reads as one dropped and one made. An index whose *name*
/// is the same and whose definition is not can only be the folding changing,
/// and that is a drop and a create too, because neither database alters an
/// index in place.
fn diffIndexes(
    gpa: std.mem.Allocator,
    comptime D: type,
    t: Table,
    old: Desc,
    steps: *std.ArrayList(Step),
) !void {
    for (t.desc.uniques) |u| {
        const before = findUnique(old.uniques, u.name);
        if (before != null and before.?.sameAs(u)) continue;
        if (before != null) try steps.append(gpa, .{
            .kind = .drop_index,
            .sql = try ddl.dropIndex(D, gpa, t.desc.schema, u.name),
            .why = try std.fmt.allocPrint(gpa, "{s} is defined differently now", .{u.name}),
        });
        try steps.append(gpa, .{
            .kind = .create_index,
            .sql = sqlFor(t, u.name),
            .why = try std.fmt.allocPrint(gpa, "unique {s}", .{u.name}),
        });
    }
    for (t.desc.indexes) |x| {
        const before = findIndex(old.indexes, x.name);
        if (before != null and before.?.sameAs(x)) continue;
        if (before != null) try steps.append(gpa, .{
            .kind = .drop_index,
            .sql = try ddl.dropIndex(D, gpa, t.desc.schema, x.name),
            .why = try std.fmt.allocPrint(gpa, "{s} is defined differently now", .{x.name}),
        });
        try steps.append(gpa, .{
            .kind = .create_index,
            .sql = sqlFor(t, x.name),
            .why = try std.fmt.allocPrint(gpa, "index {s}", .{x.name}),
        });
    }

    // Dropped: in the snapshot, named by nothing the types declare.
    for (old.uniques) |u| {
        if (findUnique(t.desc.uniques, u.name) != null) continue;
        try steps.append(gpa, .{
            .kind = .drop_index,
            .sql = try ddl.dropIndex(D, gpa, t.desc.schema, u.name),
            .why = try std.fmt.allocPrint(gpa, "drop unique {s}", .{u.name}),
        });
    }
    for (old.indexes) |x| {
        if (findIndex(t.desc.indexes, x.name) != null) continue;
        try steps.append(gpa, .{
            .kind = .drop_index,
            .sql = try ddl.dropIndex(D, gpa, t.desc.schema, x.name),
            .why = try std.fmt.allocPrint(gpa, "drop index {s}", .{x.name}),
        });
    }
}

/// A foreign key that is not the one the snapshot recorded.
///
/// **Refused on both databases, and the Postgres half is refused on purpose.**
/// It can write `ALTER TABLE … ADD CONSTRAINT … FOREIGN KEY` in one statement,
/// and that statement takes an ACCESS EXCLUSIVE lock and scans the whole table
/// to check the rows already there. On a large table under load that is an
/// outage. The two-statement form does not lock, and choosing between them is
/// an operational decision rather than something to pick for somebody.
fn diffReferences(
    gpa: std.mem.Allocator,
    t: Table,
    old: Desc,
    problems: *std.ArrayList(Problem),
) !void {
    for (t.desc.references) |r| {
        const before = findReference(old.references, r.name);
        if (before != null and before.?.sameAs(r)) continue;
        try problems.append(gpa, .{
            .table = t.desc.table,
            .column = r.column,
            .text = try std.fmt.allocPrint(
                gpa,
                "the foreign key {s} is new or changed, and the table already exists. " ++
                    "Adding one in a single statement locks the table and scans every row " ++
                    "in it. Write it as a step, in two: `ALTER TABLE \"{s}\" ADD CONSTRAINT " ++
                    "\"{s}\" FOREIGN KEY (\"{s}\") REFERENCES \"{s}\" (\"{s}\") NOT VALID`, " ++
                    "then `ALTER TABLE \"{s}\" VALIDATE CONSTRAINT \"{s}\"`. SQLite has " ++
                    "neither statement and needs the table rebuilt.",
                .{ r.name, t.desc.table, r.name, r.column, r.table, r.target, t.desc.table, r.name },
            ),
        });
    }
    for (old.references) |o| {
        if (findReference(t.desc.references, o.name) != null) continue;
        try problems.append(gpa, .{
            .table = t.desc.table,
            .column = o.column,
            .text = try std.fmt.allocPrint(
                gpa,
                "the foreign key {s} is gone from the types and is still on the table. " ++
                    "`ALTER TABLE \"{s}\" DROP CONSTRAINT \"{s}\"` is the Postgres half; " ++
                    "SQLite needs the table rebuilt. Write it as a step.",
                .{ o.name, t.desc.table, o.name },
            ),
        });
    }
}

fn findUnique(list: []const table_mod.Unique, name: []const u8) ?table_mod.Unique {
    for (list) |u| {
        if (std.mem.eql(u8, u.name, name)) return u;
    }
    return null;
}

fn findIndex(list: []const table_mod.Index, name: []const u8) ?table_mod.Index {
    for (list) |x| {
        if (std.mem.eql(u8, x.name, name)) return x;
    }
    return null;
}

fn findReference(list: []const table_mod.Reference, name: []const u8) ?table_mod.Reference {
    for (list) |r| {
        if (std.mem.eql(u8, r.name, name)) return r;
    }
    return null;
}

/// The `CREATE INDEX` for one name, out of the constants the type compiled to.
/// It is always there: the diff only ever asks for a name it read off the same
/// `Desc` these were built from.
fn sqlFor(t: Table, name: []const u8) []const u8 {
    for (t.created.indexes) |made| {
        if (std.mem.eql(u8, made.name, name)) return made.sql;
    }
    unreachable;
}

fn dropTableSql(gpa: std.mem.Allocator, old: Desc) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    try aw.writer.writeAll("DROP TABLE ");
    if (old.schema) |s| {
        try ddl.writeIdent(&aw.writer, s);
        try aw.writer.writeAll(".");
    }
    try ddl.writeIdent(&aw.writer, old.table);
    return aw.toOwnedSlice();
}

// -- the record of what has been applied ---------------------------------

/// The ledger, and it is an ordinary Row.
///
/// That is worth a sentence: the table this module keeps its own record in is
/// created by the same `createTable`, checked by the same `db.checking` and read
/// by the same `db.select` as anything a caller writes. There is no second
/// mechanism to keep in step, and the ledger is the first test of the first one.
pub const Applied = struct {
    pub const nilo_table = .{ .name = "nilo_migrations", .key = .version };

    /// The number in the file name. Supplied rather than generated, which is
    /// why it is read back before anything is written.
    version: i64,
    name: []const u8,
    /// SHA-256 of the steps, as hex. What makes editing an applied migration a
    /// red build rather than a surprise in production.
    hash: []const u8,
    applied_at: types.Timestamp,
    /// How long it took. An operator asking "which migration is the slow one"
    /// is asking about a deploy that has already happened.
    ms: i64,
};

/// The hex SHA-256 of a version's steps, chained onto the one before it.
///
/// Over the SQL rather than over the file bytes, so reformatting a generated
/// file does not read as tampering and changing a statement does.
///
/// **The parent goes in first, which is what makes it a chain.** Editing
/// version 3 changes the hash of 3 and of every version after it, so `verify`
/// finds the edit by comparing the head rather than by walking the lot. `""` is
/// the parent of the first version.
pub fn hashOf(parent: []const u8, steps: []const Step, out: *[64]u8) []const u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(parent);
    h.update("\x00");
    for (steps) |s| {
        h.update(s.sql);
        h.update("\x00");
    }
    var digest: [32]u8 = undefined;
    h.final(&digest);
    return std.fmt.bufPrint(out, "{x}", .{&digest}) catch unreachable;
}

/// One version: the number in its file name, what it is called, and the steps
/// in order.
///
/// A value rather than four arguments, because this is exactly what one
/// generated file holds. The number is `i64` to match the ledger column rather
/// than the file name.
///
/// **There is no hash field, and that is deliberate.** See `Chain`.
pub const Version = struct {
    number: i64,
    name: []const u8,
    steps: []const Step,
};

/// Every version with its chained hash worked out.
///
/// **This is the only place a hash is computed, and the generated file does not
/// carry one.** A hash written in the same file as the statements it covers is
/// decoration: whoever edits a statement is looking straight at the hash, and
/// the thing that would recompute it is the `generate` they are bypassing. Left
/// out of the file and computed here, an edited migration disagrees with the
/// ledger the first time anything asks — which is what `drift` asks.
pub const Chain = struct {
    versions: []const Version,
    /// `hashes[i]` belongs to `versions[i]`. Same length, always.
    hashes: []const []const u8,

    pub fn len(self: Chain) usize {
        return self.versions.len;
    }

    /// The version this binary was built for, or zero for a repository with no
    /// migrations. What `expect` compares the database against.
    pub fn head(self: Chain) i64 {
        return if (self.versions.len == 0) 0 else self.versions[self.versions.len - 1].number;
    }

    /// The hash at the head, which `generate` chains the next version onto.
    pub fn headHash(self: Chain) []const u8 {
        return if (self.hashes.len == 0) "" else self.hashes[self.hashes.len - 1];
    }
};

/// Walk the versions once and work out each one's chained hash.
///
/// Allocates 64 bytes per version out of `gpa`, which is an arena in every
/// caller here. The versions themselves are borrowed, not copied.
pub fn chainOf(gpa: std.mem.Allocator, versions: []const Version) !Chain {
    const hashes = try gpa.alloc([]const u8, versions.len);
    var parent: []const u8 = "";
    for (versions, 0..) |v, i| {
        const out = try gpa.create([64]u8);
        hashes[i] = hashOf(parent, v.steps, out);
        parent = hashes[i];
    }
    return .{ .versions = versions, .hashes = hashes };
}

// -- running it ----------------------------------------------------------

pub const Error = error{
    /// The database is at a lower version than the binary was built for. The
    /// migration has not been run, and serving requests against that schema is
    /// how a deploy turns into an incident.
    SchemaBehind,
};

/// The key `pg_advisory_xact_lock` takes.
///
/// Derived from the ledger's own name, so two programs sharing a database agree
/// on it without either being configured, and a program using a *different*
/// ledger name would take a different lock — which is right, because it is
/// migrating a different thing.
pub const lock_key: i64 = @bitCast(std.hash.Wyhash.hash(0, row_mod.tableOf(Applied)));

/// The Dialect a `Db` writes with. `db` is a pointer, so this is the type
/// behind it.
fn DialectOf(comptime Db: type) type {
    const Bare = switch (@typeInfo(Db)) {
        .pointer => |p| p.child,
        else => Db,
    };
    if (!@hasDecl(Bare, "Dialect")) @compileError(
        "nilo: " ++ @typeName(Bare) ++ " is being migrated and is not a `Db`.\n" ++
            "  These take the database itself — `sql.Db`, `sql.Sqlite(…)` or a named " ++
            "one — rather than a transaction or a Wire.",
    );
    return Bare.Dialect;
}

/// Create every table these Rows describe, and every index and unique on them,
/// skipping whatever is already there.
///
/// **Nothing is formatted, concatenated or allocated to produce a statement.**
/// Every byte it sends is a constant in the binary, including the order the
/// tables go in. This is the whole of what a small SQLite application needs at
/// startup, and it replaces the ten hand-written lines
/// [ADR 0079](../docs/adr/0079-there-is-a-phase-before-the-server.md) found:
///
/// ```zig
/// try app.start(io);
/// try sql.migrate.createMissing(&db, &run, &.{ Account, Document });
/// try app.listen(.{ .port = 8080 });
/// ```
///
/// **It is not a migration runner and does not pretend to be one.** It creates
/// what is missing and never alters what is there, so a table whose shape has
/// moved is left exactly as it was and `db.checking` is what says so. A program
/// that has to change a table it already shipped wants `apply` and the files
/// behind it.
pub fn createMissing(db: anytype, scope: anytype, comptime Rows: []const type) !void {
    const D = comptime DialectOf(@TypeOf(db));
    comptime core.checkScope(@TypeOf(scope), "migrate.createMissing");

    var tx = try db.begin(scope, .{});
    errdefer tx.rollback();

    for (comptime missingOf(D, Rows)) |made| {
        _ = try tx.exec(scope, made.table, .{});
        for (made.indexes) |ix| _ = try tx.exec(scope, ix.sql, .{});
    }
    try tx.commit();
}

/// The ledger, made if it is not there. One statement, and it is the same
/// `CREATE TABLE IF NOT EXISTS` any other table gets.
pub fn ensureLedger(db: anytype, scope: anytype) !void {
    const D = comptime DialectOf(@TypeOf(db));
    _ = try db.exec(scope, comptime ddl.createIfMissing(D, Applied), .{});
}

/// The narrow Row `headVersion` reads. It borrows `Applied`'s table, so the
/// column list is checked against it while compiling.
const Head = struct {
    pub const nilo_table = Applied;
    version: i64,
};

/// The highest version applied, or zero for a database nothing has migrated.
///
/// One row, by an index, ordered by the key. The ledger is small and this is
/// the query a boot pays.
pub fn headVersion(db: anytype, scope: anytype) !i64 {
    const found = try db.one(Head, scope, .{ .order = .{ .version = .desc } });
    return if (found) |h| h.version else 0;
}

/// Where the database is against the version this binary was built for.
///
/// A value rather than a log line, so that a program which wants to decide for
/// itself can, and so that a test can provoke the failing case without the
/// suite counting a logged error as a failure. `expect` is this plus the
/// sentence and the refusal.
pub const Standing = struct {
    /// The highest version the ledger records.
    at: i64,
    /// What the binary was built for.
    want: i64,

    pub const Verdict = enum { level, ahead, behind };

    pub fn verdict(self: Standing) Verdict {
        if (self.at == self.want) return .level;
        return if (self.at > self.want) .ahead else .behind;
    }
};

/// One query, and the ledger made if it is not there.
pub fn standing(db: anytype, scope: anytype, want: i64) !Standing {
    try ensureLedger(db, scope);
    return .{ .at = try headVersion(db, scope), .want = want };
}

/// Refuse to serve a database that is behind the binary.
///
/// **This is the check almost nothing has, and it catches the incident with one
/// shape**: the code went out before the migration did, and every request that
/// touches the new column answers 500 until somebody notices. `want` is a
/// constant in the binary — the generated manifest's head — so the comparison
/// is an integer against one query.
///
/// The other direction is allowed and only noted. A database ahead of the code
/// is what expand and contract looks like from the middle, and refusing it
/// would make a two-stage deploy impossible.
pub fn expect(db: anytype, scope: anytype, want: i64) !void {
    const where = try standing(db, scope, want);
    switch (where.verdict()) {
        .level => {},
        .ahead => std.log.info(
            "nilo_sql: the database is at schema version {d} and this binary was built " ++
                "for {d}. That is the ordinary middle of a two-stage deploy.",
            .{ where.at, where.want },
        ),
        .behind => {
            std.log.err(
                "nilo_sql: this binary was built for schema version {d}, and the database " ++
                    "is at {d}. {d} migration(s) have not been applied. Run them before " ++
                    "serving: a request that reads a column the database does not have is " ++
                    "a 500, and the first one arrives the moment this process accepts a " ++
                    "connection.",
                .{ where.want, where.at, where.want - where.at },
            );
            return Error.SchemaBehind;
        },
    }
}

/// Apply one version, in one transaction, under a lock.
///
/// Answers `false` when the version is already in the ledger, which is what
/// makes running it twice safe and what makes ten replicas booting together
/// cost one migration and nine no-ops.
///
/// Three things happen in an order that matters:
///
/// 1. **The lock, inside the transaction.** `pg_advisory_xact_lock` is released
///    by the commit or the rollback, so a process that dies mid-migration
///    releases it when its connection closes. SQLite has no advisory lock and
///    needs none in one process; `dialect.SQLite.advisoryLock` says what covers
///    it across two.
/// 2. **The check, after the lock.** Reading the ledger before taking the lock
///    is the race: two processes both read "not applied" and both then apply.
/// 3. **The record, in the same transaction as the steps.** A ledger row that
///    can be committed without its own DDL is a database nobody can reason
///    about afterwards.
pub fn apply(
    db: anytype,
    scope: anytype,
    v: Version,
    hash: []const u8,
) !bool {
    const D = comptime DialectOf(@TypeOf(db));
    comptime core.checkScope(@TypeOf(scope), "migrate.apply");

    // Core's monotonic clock rather than the wall one. A duration read off a
    // wall clock can come back negative when an operator moves it, and the
    // number here goes in a column an operator reads to find the slow
    // migration ([ADR 0045](../docs/adr/0045-core-knows-what-time-it-is.md)).
    const started = core.monotonicMicros();
    var tx = try db.begin(scope, .{});
    errdefer tx.rollback();

    if (comptime D.advisoryLock(lock_key)) |held| _ = try tx.exec(scope, held, .{});
    if (try tx.find(Applied, scope, v.number) != null) {
        try tx.commit();
        return false;
    }

    for (v.steps) |s| _ = try tx.exec(scope, s.sql, .{});

    _ = try tx.insert(Applied, scope, .{
        .version = v.number,
        .name = v.name,
        .hash = hash,
        .applied_at = types.Timestamp.now(),
        .ms = @divFloor(core.monotonicMicros() - started, std.time.us_per_ms),
    });
    try tx.commit();
    return true;
}

/// Every version the database has not got, in order. Answers how many ran.
///
/// **This is the in-process runner**, called between `app.start(io)` and
/// `listen()` by a program that has nowhere else to run its DDL — which is
/// every single-file SQLite application, and plenty of Postgres ones. One
/// transaction per version, each behind the same advisory lock, so ten
/// replicas booting together still run each version once.
pub fn applyPending(db: anytype, scope: anytype, chain: Chain) !usize {
    var ran: usize = 0;
    for (chain.versions, chain.hashes) |v, hash| {
        if (try apply(db, scope, v, hash)) ran += 1;
    }
    return ran;
}

/// A version whose recorded hash is not the hash of the steps in the binary.
pub const Drift = struct {
    version: i64,
    name: []const u8,
    /// What was in the ledger when it was applied.
    recorded: []const u8,
    /// What the steps hash to now.
    now: []const u8,
};

/// Every applied version whose steps have been edited since, in order.
///
/// **A version that has run is history, and history does not get rewritten.**
/// Editing one is usually somebody fixing a typo in a file that has already
/// been applied everywhere, which makes the file and the database disagree in a
/// way nothing else would ever report. The chain in `hashOf` means one edit
/// shows up on that version and every version after it, so the first row here
/// is the one to look at.
///
/// Allocates out of the Scope's arena, so a `Run` throws it away with the tick.
pub fn drift(db: anytype, scope: anytype, chain: Chain) ![]const Drift {
    comptime core.checkScope(@TypeOf(scope), "migrate.drift");
    try ensureLedger(db, scope);

    var found: std.ArrayList(Drift) = .empty;
    const arena = scope.arena();
    for (chain.versions, chain.hashes) |v, hash| {
        const row = try db.find(Applied, scope, v.number) orelse continue;
        if (std.mem.eql(u8, row.hash, hash)) continue;
        try found.append(arena, .{
            .version = v.number,
            .name = v.name,
            .recorded = row.hash,
            .now = hash,
        });
    }
    return found.items;
}

// -- tests ---------------------------------------------------------------

const testing = std.testing;
const Pg = @import("dialect.zig").Postgres;
const Lite = @import("dialect.zig").SQLite;

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

/// A snapshot built from a list of Rows, which is how every test below states
/// "the schema before" without writing a `.zon` file out by hand.
fn snapshotFrom(gpa: std.mem.Allocator, comptime D: type, comptime Rows: []const type) !snapshot.Doc {
    const tables = comptime tablesOf(D, Rows);
    return snapshotOf(gpa, D, 1, tables);
}

test "a schema that has never been generated is one CREATE TABLE per Row" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tables = comptime tablesOf(Pg, &.{ User, Org });
    const change = try plan(a, Pg, tables, snapshot.empty(Pg));

    try testing.expectEqual(@as(usize, 0), change.problems.len);
    // orgs, users, then the two indexes users declares.
    try testing.expectEqual(@as(usize, 4), change.steps.len);
    try testing.expectEqual(Kind.create_table, change.steps[0].kind);
    try testing.expectEqual(Kind.create_table, change.steps[1].kind);
    try testing.expectEqual(Kind.create_index, change.steps[2].kind);
    try testing.expect(!change.destructive());
}

test "a table is created after the tables it points at, and the order is a constant" {
    // `User` is written first and `Org` second, and the plan reverses them,
    // because Postgres checks that `orgs` is there when `users` names it.
    const tables = comptime tablesOf(Pg, &.{ User, Org });
    try testing.expectEqualStrings("orgs", tables[0].desc.table);
    try testing.expectEqualStrings("users", tables[1].desc.table);
}

test "a table pointing at itself is not a ring" {
    const Node = struct {
        pub const nilo_table = .{
            .name = "nodes",
            .key = .id,
            .references = .{ .parent_id = .{ @This(), .id } },
        };
        id: i64,
        parent_id: ?i64,
    };
    const tables = comptime tablesOf(Pg, &.{Node});
    try testing.expectEqualStrings("nodes", tables[0].desc.table);
}

test "a schema that has not moved plans nothing at all" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const before = try snapshotFrom(a, Pg, &.{ Org, User });
    const change = try plan(a, Pg, comptime tablesOf(Pg, &.{ Org, User }), before);

    try testing.expect(change.isEmpty());
    try testing.expectEqual(@as(usize, 0), change.problems.len);
}

test "a column added to a Row is one ALTER, and a required one says it needs a backfill" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Before = struct {
        pub const nilo_table = .{ .name = "orgs", .key = .id };
        id: i64,
        name: []const u8,
    };
    const After = struct {
        pub const nilo_table = .{ .name = "orgs", .key = .id };
        id: i64,
        name: []const u8,
        slug: []const u8,
        note: ?[]const u8,
    };

    const before = try snapshotFrom(a, Pg, &.{Before});
    const change = try plan(a, Pg, comptime tablesOf(Pg, &.{After}), before);

    try testing.expectEqual(@as(usize, 2), change.steps.len);
    try testing.expectEqualStrings(
        "ALTER TABLE \"orgs\" ADD COLUMN \"slug\" text NOT NULL",
        change.steps[0].sql,
    );
    try testing.expect(change.steps[0].needs_backfill);
    try testing.expectEqualStrings(
        "ALTER TABLE \"orgs\" ADD COLUMN \"note\" text",
        change.steps[1].sql,
    );
    try testing.expect(!change.steps[1].needs_backfill);
    try testing.expect(!change.destructive());
}

test "a column that left the Row is a drop, and the plan says it loses data" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Before = struct {
        pub const nilo_table = .{ .name = "orgs", .key = .id };
        id: i64,
        name: []const u8,
        nickname: ?[]const u8,
    };
    const After = struct {
        pub const nilo_table = .{ .name = "orgs", .key = .id };
        id: i64,
        name: []const u8,
    };

    const before = try snapshotFrom(a, Pg, &.{Before});
    const change = try plan(a, Pg, comptime tablesOf(Pg, &.{After}), before);

    try testing.expectEqual(@as(usize, 1), change.steps.len);
    try testing.expectEqual(Kind.drop_column, change.steps[0].kind);
    try testing.expect(change.steps[0].destructive);
    try testing.expect(change.destructive());
}

test "`.was` turns the same change into one rename, and the data comes with it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Before = struct {
        pub const nilo_table = .{ .name = "orgs", .key = .id };
        id: i64,
        e_mail: []const u8,
    };
    const After = struct {
        pub const nilo_table = .{ .name = "orgs", .key = .id, .was = .{ .email = "e_mail" } };
        id: i64,
        email: []const u8,
    };

    const before = try snapshotFrom(a, Pg, &.{Before});
    const change = try plan(a, Pg, comptime tablesOf(Pg, &.{After}), before);

    // One statement, not two. Without `.was` this is a drop and an add.
    try testing.expectEqual(@as(usize, 1), change.steps.len);
    try testing.expectEqual(Kind.rename_column, change.steps[0].kind);
    try testing.expectEqualStrings(
        "ALTER TABLE \"orgs\" RENAME COLUMN \"e_mail\" TO \"email\"",
        change.steps[0].sql,
    );
    try testing.expect(!change.destructive());
}

test "a `.was` that has already run plans nothing, which is how the entry becomes spent" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const After = struct {
        pub const nilo_table = .{ .name = "orgs", .key = .id, .was = .{ .email = "e_mail" } };
        id: i64,
        email: []const u8,
    };

    // The snapshot already calls it `email`, so the rename happened last time.
    const before = try snapshotFrom(a, Pg, &.{After});
    const change = try plan(a, Pg, comptime tablesOf(Pg, &.{After}), before);
    try testing.expect(change.isEmpty());
}

test "a type change is one statement on Postgres and a named Refusal on SQLite" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Before = struct {
        pub const nilo_table = .{ .name = "orgs", .key = .id };
        id: i64,
        seats: i32,
    };
    const After = struct {
        pub const nilo_table = .{ .name = "orgs", .key = .id };
        id: i64,
        seats: i64,
    };

    const pg_before = try snapshotFrom(a, Pg, &.{Before});
    const pg = try plan(a, Pg, comptime tablesOf(Pg, &.{After}), pg_before);
    try testing.expectEqual(@as(usize, 1), pg.steps.len);
    try testing.expectEqualStrings(
        "ALTER TABLE \"orgs\" ALTER COLUMN \"seats\" TYPE int8",
        pg.steps[0].sql,
    );

    // SQLite reads both as INTEGER, so that particular change is not one there.
    // A text column becoming an integer is.
    const Wide = struct {
        pub const nilo_table = .{ .name = "orgs", .key = .id };
        id: i64,
        seats: []const u8,
    };
    const lite_before = try snapshotFrom(a, Lite, &.{Before});
    const lite = try plan(a, Lite, comptime tablesOf(Lite, &.{Wide}), lite_before);
    try testing.expectEqual(@as(usize, 0), lite.steps.len);
    try testing.expectEqual(@as(usize, 1), lite.problems.len);
    try testing.expectEqualStrings("seats", lite.problems[0].column);
    try testing.expect(std.mem.indexOf(u8, lite.problems[0].text, "cannot change a column") != null);
    // And it says what to write instead, rather than only what it will not do.
    try testing.expect(std.mem.indexOf(u8, lite.problems[0].text, "RENAME") != null);
}

test "a nullability change is a statement in each direction, and tightening needs a backfill" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Loose = struct {
        pub const nilo_table = .{ .name = "orgs", .key = .id };
        id: i64,
        note: ?[]const u8,
    };
    const Tight = struct {
        pub const nilo_table = .{ .name = "orgs", .key = .id };
        id: i64,
        note: []const u8,
    };

    const before = try snapshotFrom(a, Pg, &.{Loose});
    const tightened = try plan(a, Pg, comptime tablesOf(Pg, &.{Tight}), before);
    try testing.expectEqual(@as(usize, 1), tightened.steps.len);
    try testing.expectEqual(Kind.change_null, tightened.steps[0].kind);
    try testing.expect(tightened.steps[0].needs_backfill);
    try testing.expect(tightened.needsBackfill());

    const after = try snapshotFrom(a, Pg, &.{Tight});
    const loosened = try plan(a, Pg, comptime tablesOf(Pg, &.{Loose}), after);
    try testing.expectEqualStrings(
        "ALTER TABLE \"orgs\" ALTER COLUMN \"note\" DROP NOT NULL",
        loosened.steps[0].sql,
    );
    try testing.expect(!loosened.steps[0].needs_backfill);
}

test "an index whose columns changed is a new name, so it is one drop and one create" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Before = struct {
        pub const nilo_table = .{ .name = "orgs", .key = .id, .index = .{.name} };
        id: i64,
        name: []const u8,
        at: types.Timestamp,
    };
    const After = struct {
        pub const nilo_table = .{ .name = "orgs", .key = .id, .index = .{.{ .name, .at }} };
        id: i64,
        name: []const u8,
        at: types.Timestamp,
    };

    const before = try snapshotFrom(a, Pg, &.{Before});
    const change = try plan(a, Pg, comptime tablesOf(Pg, &.{After}), before);

    try testing.expectEqual(@as(usize, 2), change.steps.len);
    try testing.expectEqual(Kind.create_index, change.steps[0].kind);
    try testing.expect(std.mem.indexOf(u8, change.steps[0].sql, "orgs_name_at_idx") != null);
    try testing.expectEqual(Kind.drop_index, change.steps[1].kind);
    try testing.expectEqualStrings("DROP INDEX \"orgs_name_idx\"", change.steps[1].sql);
}

test "a unique that starts ignoring case keeps its name and is rebuilt" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Before = struct {
        pub const nilo_table = .{ .name = "orgs", .key = .id, .unique = .{.email} };
        id: i64,
        email: []const u8,
    };
    const After = struct {
        pub const nilo_table = .{
            .name = "orgs",
            .key = .id,
            .unique = .{.{ .columns = .{.email}, .ignoring_case = true }},
        };
        id: i64,
        email: []const u8,
    };

    const before = try snapshotFrom(a, Pg, &.{Before});
    const change = try plan(a, Pg, comptime tablesOf(Pg, &.{After}), before);

    try testing.expectEqual(@as(usize, 2), change.steps.len);
    try testing.expectEqual(Kind.drop_index, change.steps[0].kind);
    try testing.expectEqual(Kind.create_index, change.steps[1].kind);
    try testing.expect(std.mem.indexOf(u8, change.steps[1].sql, "lower(\"email\")") != null);
}

test "a foreign key on a table that exists is refused, with the two safe statements" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Before = struct {
        pub const nilo_table = .{ .name = "posts", .key = .id };
        id: i64,
        org_id: i64,
    };
    const After = struct {
        pub const nilo_table = .{
            .name = "posts",
            .key = .id,
            .references = .{ .org_id = .{ Org, .id } },
        };
        id: i64,
        org_id: i64,
    };

    const before = try snapshotFrom(a, Pg, &.{ Org, Before });
    const change = try plan(a, Pg, comptime tablesOf(Pg, &.{ Org, After }), before);

    try testing.expectEqual(@as(usize, 0), change.steps.len);
    try testing.expectEqual(@as(usize, 1), change.problems.len);
    try testing.expect(std.mem.indexOf(u8, change.problems[0].text, "NOT VALID") != null);
    try testing.expect(std.mem.indexOf(u8, change.problems[0].text, "VALIDATE CONSTRAINT") != null);
}

test "a table no Row describes is dropped, and it is the last thing to happen" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const before = try snapshotFrom(a, Pg, &.{ Org, User });
    const change = try plan(a, Pg, comptime tablesOf(Pg, &.{Org}), before);

    try testing.expectEqual(@as(usize, 1), change.steps.len);
    try testing.expectEqual(Kind.drop_table, change.steps[0].kind);
    try testing.expectEqualStrings("DROP TABLE \"users\"", change.steps[0].sql);
    try testing.expect(change.destructive());
}

test "a snapshot from the other dialect is one sentence, not a schema rewritten" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const before = try snapshotFrom(a, Lite, &.{Org});
    const change = try plan(a, Pg, comptime tablesOf(Pg, &.{Org}), before);

    try testing.expect(change.isEmpty());
    try testing.expectEqual(@as(usize, 1), change.problems.len);
    try testing.expect(std.mem.indexOf(u8, change.problems[0].text, "sqlite") != null);
    try testing.expect(std.mem.indexOf(u8, change.problems[0].text, "postgres") != null);
}

test "a hash is over the statements, so reformatting a file is not tampering" {
    const one: []const Step = &.{
        .{ .kind = .create_table, .sql = "CREATE TABLE \"a\" (\"id\" int8)", .why = "" },
    };
    const same: []const Step = &.{
        .{ .kind = .create_table, .sql = "CREATE TABLE \"a\" (\"id\" int8)", .why = "and a different comment" },
    };
    const other: []const Step = &.{
        .{ .kind = .create_table, .sql = "CREATE TABLE \"a\" (\"id\" int4)", .why = "" },
    };

    var a: [64]u8 = undefined;
    var b: [64]u8 = undefined;
    var c: [64]u8 = undefined;

    try testing.expectEqualStrings(hashOf("", one, &a), hashOf("", same, &b));
    try testing.expect(!std.mem.eql(u8, hashOf("", one, &a), hashOf("", other, &c)));
    try testing.expectEqual(@as(usize, 64), hashOf("", one, &a).len);
}

test "the hash is chained, so editing one version moves every version after it" {
    const three: []const Step = &.{
        .{ .kind = .create_table, .sql = "CREATE TABLE \"c\" (\"id\" int8)", .why = "" },
    };
    const four: []const Step = &.{
        .{ .kind = .add_column, .sql = "ALTER TABLE \"c\" ADD COLUMN \"n\" int8", .why = "" },
    };
    const edited: []const Step = &.{
        .{ .kind = .create_table, .sql = "CREATE TABLE \"c\" (\"id\" int4)", .why = "" },
    };

    var h3: [64]u8 = undefined;
    var h4: [64]u8 = undefined;
    var e3: [64]u8 = undefined;
    var e4: [64]u8 = undefined;

    const was3 = hashOf("", three, &h3);
    const was4 = hashOf(was3, four, &h4);

    // Version 4 is untouched, and its hash moves anyway. That is the whole
    // point: `verify` finds an edit to 3 by looking at the head.
    const now3 = hashOf("", edited, &e3);
    const now4 = hashOf(now3, four, &e4);
    try testing.expect(!std.mem.eql(u8, was4, now4));
}

test "the ledger is an ordinary Row, so the same machinery creates and checks it" {
    const desc = comptime table_mod.descOf(Pg, Applied);
    try testing.expectEqualStrings("nilo_migrations", desc.table);
    try testing.expectEqualStrings("version", desc.key);
    try testing.expect(desc.column("version").?.key);

    // And its DDL is a constant like any other table's.
    const sql = comptime ddl.createTable(Pg, Applied);
    try testing.expect(std.mem.indexOf(u8, sql, "\"hash\" text NOT NULL") != null);
    try testing.expect(std.mem.indexOf(u8, sql, "\"applied_at\" timestamptz NOT NULL") != null);
    try testing.expect(std.mem.indexOf(u8, comptime ddl.createTable(Lite, Applied), "INTEGER PRIMARY KEY") != null);
}

test {
    _ = ddl;
    _ = snapshot;
    _ = table_mod;
}
