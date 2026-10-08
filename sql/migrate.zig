//! Migrations: the diff, the plan, and the record of what has been applied
//! ([ADR 123](../docs/adr/123-a-migration-is-a-diff-against-a-snapshot.md)).
//!
//! ```zig
//! const desired = comptime sql.migrate.desiredOf(Db.Dialect, .{ .tables = &.{ Org, User, Post } });
//!
//! // No database anywhere in these two lines.
//! const before = try sql.migrate.snapshot.parse(run.arena(), text, null);
//! const change = try sql.migrate.plan(run.arena(), Db.Dialect, desired, before);
//! ```
//!
//! ## What is settled while compiling, and what is not
//!
//! `desiredOf` is the desired schema, and every byte of SQL in it is a constant
//! in the binary: the `CREATE TABLE`, every index, every function and view,
//! and the order they have to run in. Only the diff against a snapshot is
//! runtime work, because the snapshot is a file.
//!
//! That split is what the two cheapest paths are built on.
//!
//! - **`createMissing` formats nothing.** It creates every table a list of
//!   Rows describes, and every statement it sends is already in `.rodata`;
//!   what it reads first is the columns of a table that has an index.
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
const wire_mod = @import("wire.zig");

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

/// What a program's database is: every table, and the three kinds of object
/// that hang off the schema rather than off a table
/// ([ADR 181](../docs/adr/181-the-marker-has-two-kinds-of-word.md)).
///
/// ```zig
/// pub const schema = sql.Schema{
///     .extensions = &.{"pgcrypto"},
///     .functions = &.{
///         .{ .name = "set_updated_at", .body = @embedFile("sql/set_updated_at.sql") },
///     },
///     .tables = &.{ Org, User, Post },
///     .views = &.{
///         .{ .name = "sku_catalogue", .body = @embedFile("sql/sku_catalogue.sql") },
///     },
/// };
/// ```
///
/// **The one value `cli.Tool`, `db.checking`, `createMissing` and the diff are
/// all given**, which is what keeps the four from drifting apart. Order inside
/// a list does not matter; the tool owns the order — extensions, functions,
/// tables by reference, each table's indexes and triggers, then views in the
/// order they read each other — and a
/// version file's `before` and `after` slots are for what is none of these.
///
/// `@embedFile` is the point of the two named lists: a sixty-line view belongs
/// in a `.sql` file with highlighting rather than in sixty `\\` lines, and the
/// snapshot records its name and a hash rather than the text (ADR 181).
pub const Schema = struct {
    /// Every Row whose table this program reads or builds, in any order.
    tables: []const type,
    /// Postgres extensions, by name: `CREATE EXTENSION IF NOT EXISTS "x"`,
    /// and `DROP EXTENSION` when the name leaves the list. Refused on
    /// SQLite, which has none to create.
    extensions: []const []const u8 = &.{},
    /// Each the **whole** `CREATE OR REPLACE FUNCTION <name> …` statement,
    /// and it has to begin with those words and that name — that is what
    /// makes applying it twice applying it once, and what lets a changed
    /// body be one step rather than a drop and a create. Refused on SQLite.
    functions: []const Text = &.{},
    /// Each the `SELECT`; nilo writes `CREATE VIEW "name" AS` in front of
    /// it, and drops and remakes the view when the text moves.
    views: []const Text = &.{},

    /// A name and its text — the same struct a table's `.check` and
    /// `.trigger` compile to, so the snapshot hashes all four the same way.
    pub const Text = table_mod.NamedText;
};

/// The desired half of every diff: the tables in create order with the SQL
/// that makes them, and the schema-level objects beside them. What `plan`,
/// `snapshotOf` and `migrations.generate` take.
pub const Desired = struct {
    tables: []const Table,
    extensions: []const []const u8 = &.{},
    functions: []const table_mod.NamedText = &.{},
    views: []const table_mod.NamedText = &.{},
};

/// The schema as the types describe it, settled while compiling.
pub fn desiredOf(comptime D: type, comptime schema: Schema) Desired {
    comptime {
        return .{
            .tables = tablesOf(D, schema),
            .extensions = schema.extensions,
            .functions = schema.functions,
            .views = viewOrder(schema.views),
        };
    }
}

/// The three lists a Dialect can refuse, and the two shapes an entry can be
/// written wrong in. Run from `orderOf`, the one place every schema reaches,
/// for the reason the foreign-key check runs there (ADR 181).
fn assertSchema(comptime D: type, comptime schema: Schema) void {
    comptime {
        if (schema.extensions.len > 0 and !D.has_extensions) @compileError(
            "nilo: `.extensions` names \"" ++ schema.extensions[0] ++ "\", and " ++ D.name ++
                " has no extensions to create. Leave the list out of this schema.",
        );
        if (schema.functions.len > 0 and !D.has_functions) @compileError(
            "nilo: `.functions` names \"" ++ schema.functions[0].name ++ "\", and " ++ D.name ++
                " has no `CREATE FUNCTION`. Leave the list out of this schema.",
        );
        for (schema.extensions) |name| {
            if (name.len == 0) @compileError("nilo: `.extensions` has an empty name in it.");
        }
        for (schema.functions) |f| {
            if (f.name.len == 0) @compileError("nilo: `.functions` has an entry with no name.");
            if (!beginsWithFunctionHead(f)) @compileError(
                "nilo: `.functions` entry \"" ++ f.name ++ "\" has to begin `CREATE OR REPLACE FUNCTION " ++
                    f.name ++ "`, so that applying it twice is applying it once. It begins `" ++
                    headOf(f.body) ++ "`.",
            );
        }
        for (schema.functions) |f| {
            // Postgres folds a name it was not given in quotes to lower case,
            // and `DROP FUNCTION` names it in quotes, so a function written
            // `setUpdatedAt` was dropped as `"setUpdatedAt"` and the `IF
            // EXISTS` skipped it without a word.
            if (!std.mem.eql(u8, f.name, lowerOf(f.name)) and !quotedHead(f)) @compileError(
                "nilo: `.functions` entry \"" ++ f.name ++ "\" names the function without quotes, " ++
                    "and Postgres keeps it as `" ++ lowerOf(f.name) ++ "`. nilo drops a function by " ++
                    "the name in the entry, in quotes, so that drop would find nothing. Write the " ++
                    "name in lower case, or quote it in the body: `CREATE OR REPLACE FUNCTION \"" ++
                    f.name ++ "\"`.",
            );
        }
        for (schema.views) |v| {
            if (v.name.len == 0) @compileError("nilo: `.views` has an entry with no name.");
            const trimmed = std.mem.trim(u8, v.body, &std.ascii.whitespace);
            if (trimmed.len == 0) @compileError(
                "nilo: `.views` entry \"" ++ v.name ++ "\" is empty.",
            );
            if (trimmed.len >= 6 and std.ascii.eqlIgnoreCase(trimmed[0..6], "CREATE")) @compileError(
                "nilo: `.views` entry \"" ++ v.name ++ "\" begins `CREATE`, and nilo writes the " ++
                    "`CREATE VIEW \"" ++ v.name ++ "\" AS` itself — the entry is the SELECT.",
            );
        }
    }
}

/// Whether the text opens `CREATE OR REPLACE FUNCTION <name>`, with any
/// whitespace between the words and the name quoted or bare.
fn beginsWithFunctionHead(comptime f: table_mod.NamedText) bool {
    comptime {
        var rest = std.mem.trimStart(u8, f.body, &std.ascii.whitespace);
        for ([_][]const u8{ "CREATE", "OR", "REPLACE", "FUNCTION" }) |word| {
            if (rest.len < word.len or !std.ascii.eqlIgnoreCase(rest[0..word.len], word)) return false;
            rest = std.mem.trimStart(u8, rest[word.len..], &std.ascii.whitespace);
        }
        if (std.mem.startsWith(u8, rest, f.name)) return true;
        return std.mem.startsWith(u8, rest, "\"" ++ f.name ++ "\"");
    }
}

/// Whether the body names the function in quotes, which keeps its case.
fn quotedHead(comptime f: table_mod.NamedText) bool {
    comptime {
        var rest = std.mem.trimStart(u8, f.body, &std.ascii.whitespace);
        for ([_][]const u8{ "CREATE", "OR", "REPLACE", "FUNCTION" }) |word| {
            rest = std.mem.trimStart(u8, rest[word.len..], &std.ascii.whitespace);
        }
        return std.mem.startsWith(u8, rest, "\"");
    }
}

fn lowerOf(comptime text: []const u8) []const u8 {
    comptime {
        var out: [text.len]u8 = undefined;
        _ = std.ascii.lowerString(&out, text);
        const frozen = out;
        return &frozen;
    }
}

/// The first forty characters of a text, for a refusal to quote.
fn headOf(comptime text: []const u8) []const u8 {
    comptime {
        const trimmed = std.mem.trimStart(u8, text, &std.ascii.whitespace);
        return if (trimmed.len <= 40) trimmed else trimmed[0..40] ++ "…";
    }
}

/// What `createMissing` sends before any table: the extensions, then the
/// functions, each in a form that may already have run.
pub fn leadingOf(comptime D: type, comptime schema: Schema) []const []const u8 {
    comptime {
        assertSchema(D, schema);
        var out: [schema.extensions.len + schema.functions.len][]const u8 = undefined;
        var n: usize = 0;
        for (schema.extensions) |name| {
            out[n] = ddl.createExtensionIfMissing(D, name);
            n += 1;
        }
        for (schema.functions) |f| {
            out[n] = f.body;
            n += 1;
        }
        const frozen = out;
        return &frozen;
    }
}

/// What `createMissing` sends after every table: the views, each under the
/// Dialect's repeatable head.
pub fn trailingOf(comptime D: type, comptime schema: Schema) []const []const u8 {
    comptime {
        const views = viewOrder(schema.views);
        var out: [views.len][]const u8 = undefined;
        for (views, 0..) |v, i| out[i] = ddl.viewStatement(D, D.view_repeatable_head, v);
        const frozen = out;
        return &frozen;
    }
}

/// What a view that is dropped and made again costs on Postgres, in the
/// `why` of the step that drops it. The diff has no way to read a view's
/// grants or comment (the snapshot is of Rows, not of a database), so it
/// cannot write them back; `createMissing` does not have this cost, because
/// `CREATE OR REPLACE VIEW` keeps them.
const view_grants_note = " (on Postgres its grants and comment go with it; grant them again in a later step)";

/// A view or a trigger as `createMissing` sends it: the statement that makes
/// it wherever it may already be, and what it takes to compare and replace
/// it on a database that cannot replace in place (`Dialect.stored_definitions`).
const Repeatable = struct {
    /// `view` or `trigger`, the first half of the key the stored text is
    /// found under.
    kind: []const u8,
    name: []const u8,
    /// Under the Dialect's repeatable head.
    sql: []const u8,
    /// The same statement under a plain `CREATE`, which is what SQLite stores
    /// once it has taken `IF NOT EXISTS` out.
    plain: []const u8,
    drop: []const u8,
};

/// The views of a schema as `Repeatable`s, each after every view it reads.
fn viewsRepeatable(comptime D: type, comptime schema: Schema) []const Repeatable {
    comptime {
        const views = viewOrder(schema.views);
        var out: [views.len]Repeatable = undefined;
        for (views, 0..) |v, i| out[i] = .{
            .kind = "view",
            .name = v.name,
            .sql = ddl.viewStatement(D, D.view_repeatable_head, v),
            .plain = ddl.viewStatement(D, "CREATE VIEW ", v),
            .drop = "DROP VIEW " ++ D.quote(v.name),
        };
        const frozen = out;
        return &frozen;
    }
}

/// The triggers a table's marker names, as `Repeatable`s.
fn triggersRepeatable(comptime D: type, comptime desc: Desc) []const Repeatable {
    comptime {
        var out: [desc.triggers.len]Repeatable = undefined;
        for (desc.triggers, 0..) |t, i| out[i] = .{
            .kind = "trigger",
            .name = t.name,
            .sql = ddl.triggerStatement(D, desc, D.trigger_repeatable_head, t),
            .plain = ddl.triggerStatement(D, desc, "CREATE TRIGGER ", t),
            .drop = "DROP TRIGGER IF EXISTS " ++ D.quote(t.name) ++
                (if (D.trigger_drop_names_table) " ON " ++ D.qualify(desc.schema, desc.table) else ""),
        };
        const frozen = out;
        return &frozen;
    }
}

/// What the database holds of the views and triggers, read at most once by a
/// `createMissing`, and only when a view or trigger is about to be sent.
const Stored = struct {
    entries: []const []const u8 = &.{},
    read: bool = false,
};

/// Send a view or a trigger so that it ends up as written, on either database.
///
/// **One behaviour for both** (the Views and triggers entry of the roadmap).
/// Postgres replaces in place with `CREATE OR REPLACE`, which keeps a view's
/// grants and comment. SQLite has only `IF NOT EXISTS`, which left a changed
/// definition as it was without a word, so there the stored text is read once
/// and compared, and a definition that differs is dropped and made again.
/// Nothing is sent for one that matches. A drop and a make are one
/// transaction with the rest of `createMissing`, so a failure keeps neither.
fn sendRepeatable(
    comptime D: type,
    tx: anytype,
    scope: anytype,
    stored: *Stored,
    comptime r: Repeatable,
) !void {
    if (comptime !@hasDecl(D, "stored_definitions")) return sendBounded(tx, scope, r.sql, "createMissing");
    if (!stored.read) {
        stored.entries = try tx.raw([]const u8, scope, D.stored_definitions, .{});
        stored.read = true;
    }
    const key = comptime r.kind ++ ":" ++ r.name;
    for (stored.entries) |entry| {
        const split = std.mem.indexOfScalar(u8, entry, 31) orelse continue;
        if (!std.ascii.eqlIgnoreCase(entry[0..split], key)) continue;
        if (std.mem.eql(u8, entry[split + 1 ..], r.plain)) return;
        try sendBounded(tx, scope, r.drop, "createMissing");
        break;
    }
    try sendBounded(tx, scope, r.sql, "createMissing");
}

/// The views, each after every view it reads.
///
/// **The Schema says order inside a list does not matter**, and for views
/// that was not so: one reading another listed after it was created first
/// and refused. A view reads another when its text names it (`mentions`).
/// A ring can only be a word that spells a view's name without being one,
/// since no database can create two views that read each other, so what is
/// left when nothing more can be placed keeps the order it was written in.
fn viewOrder(comptime views: []const table_mod.NamedText) []const table_mod.NamedText {
    comptime {
        var quota: usize = 1000;
        for (views) |v| quota += 50 * v.body.len * views.len;
        @setEvalBranchQuota(quota * views.len);
        var out: [views.len]table_mod.NamedText = undefined;
        var placed: [views.len]bool = @splat(false);
        var n: usize = 0;
        while (n < views.len) {
            var moved = false;
            for (views, 0..) |v, i| {
                if (placed[i]) continue;
                const waits = for (views, 0..) |other, j| {
                    if (j != i and !placed[j] and mentions(v.body, other.name)) break true;
                } else false;
                if (waits) continue;
                out[n] = v;
                placed[i] = true;
                n += 1;
                moved = true;
                // From the top again, so each view keeps the place the
                // list gave it unless it has to wait for one below it.
                break;
            }
            if (!moved) for (views, 0..) |v, i| {
                if (placed[i]) continue;
                out[n] = v;
                placed[i] = true;
                n += 1;
            };
        }
        const frozen = out;
        return &frozen;
    }
}

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
pub fn orderOf(comptime D: type, comptime schema: Schema) []const type {
    comptime {
        const Rows = schema.tables;
        @setEvalBranchQuota(50_000 + 20_000 * Rows.len);
        assertSchema(D, schema);

        var descs: [Rows.len]Desc = undefined;
        for (Rows, 0..) |R, i| descs[i] = table_mod.descOf(D, R);

        // **The one place every Row is in one list**, which is why the check
        // for a foreign key that named its table as text runs here rather than
        // inside the Row that wrote it
        // ([ADR 181](../docs/adr/181-the-marker-has-two-kinds-of-word.md)).
        // After the `Desc`s, so that an entry written wrong stops with what
        // `table.zig` says about its shape rather than with a missing field;
        // before the sort, because a name that resolves to nothing would
        // otherwise come back as a ring.
        table_mod.assertTargetsResolve(Rows);
        assertIndexNamesDiffer(&descs);

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
pub fn tablesOf(comptime D: type, comptime schema: Schema) []const Table {
    comptime {
        const ordered = orderOf(D, schema);
        var out: [ordered.len]Table = undefined;
        for (ordered, 0..) |R, i| out[i] = tableOf(D, R);
        const frozen = out;
        return &frozen;
    }
}

/// The same tables, in the same order, as statements that do nothing when the
/// table is already there. What `createMissing` sends.
pub fn missingOf(comptime D: type, comptime schema: Schema) []const ddl.Created {
    comptime {
        const ordered = orderOf(D, schema);
        var out: [ordered.len]ddl.Created = undefined;
        var n: usize = 0;
        for (ordered) |R| {
            // A table this program reads and does not build is not missing —
            // it is somebody else's (ADR 130). `createMissing` is the one
            // call that would otherwise create it, `IF NOT EXISTS` and all,
            // which is the same silence a `CREATE TABLE` for a table with
            // twenty columns this program never reads would leave behind.
            if (!row_mod.managedOf(R)) continue;
            out[n] = ddl.createdIfMissing(D, R);
            n += 1;
        }
        const frozen = out[0..n].*;
        return &frozen;
    }
}

/// A foreign key whose pointing columns no index of its table leads with.
/// What `db check` prints as a note and never fails on
/// ([ADR 123](../docs/adr/123-a-migration-is-a-diff-against-a-snapshot.md)).
pub const Unindexed = struct {
    /// The Row that owns the table, for the sentence that names the marker.
    row: []const u8,
    schema: ?[]const u8,
    table: []const u8,
    /// The constraint's name.
    name: []const u8,
    /// The columns doing the pointing, in the order the marker wrote them.
    columns: []const []const u8,
    /// The table pointed at.
    parent: []const u8,
    on_delete: table_mod.OnDelete,
    /// Whether the table already has an `.index` list, which decides whether
    /// the fix is a new line or one more entry.
    has_index: bool,
};

/// **Every reference of a table this program builds whose pointing columns are
/// not the leading columns of an index, a unique or the key**, in table order.
///
/// Postgres indexes the key a reference points *at* and not the column that
/// points, and neither database indexes that column on its own. Deleting a row
/// of the parent then reads every row of the child, once for the check that no
/// child still points at it and again for each `ON DELETE CASCADE` or
/// `SET NULL`; a parent with a million children is a million-row scan per
/// delete. Nothing is added by default, because an index costs every insert
/// into the child and a migration for every schema that exists
/// ([ADR 123](../docs/adr/123-a-migration-is-a-diff-against-a-snapshot.md)):
/// this only names the ones to consider.
///
/// **Worked from the tables the types describe, so it costs nothing at boot
/// and needs no database.** What counts as serving a reference is what a
/// lookup by equality on all its columns can use: the key, a unique, or a
/// plain index whose *leading* columns are the reference's, in any order. Not
/// counted, because equality on the raw column cannot use them: a partial
/// index (its `WHERE` excludes rows a delete has to find), and a unique that
/// ignores case (an index over `lower(col)` or `COLLATE NOCASE`). A composite
/// unique that has the column second (`(tenant_id, org_id)`) does not serve
/// `org_id`.
///
/// A table this program only reads is not asked: its indexes are somebody
/// else's to add.
pub fn unindexedReferences(gpa: std.mem.Allocator, tables: []const Table) ![]const Unindexed {
    var found: std.ArrayList(Unindexed) = .empty;
    for (tables) |t| {
        const d = t.desc;
        if (!d.managed) continue;
        for (d.references) |ref| {
            if (leadsWith(d.keys, ref.columns)) continue;
            var served = false;
            for (d.uniques) |u| {
                if (u.ignoring_case) continue;
                if (leadsWith(u.columns, ref.columns)) served = true;
            }
            for (d.indexes) |x| {
                if (x.where.len > 0) continue;
                if (leadsWith(x.columns, ref.columns)) served = true;
            }
            if (served) continue;
            try found.append(gpa, .{
                .row = d.row,
                .schema = d.schema,
                .table = d.table,
                .name = ref.name,
                .columns = ref.columns,
                .parent = ref.table,
                .on_delete = ref.on_delete,
                .has_index = d.indexes.len > 0,
            });
        }
    }
    return found.items;
}

/// Whether the first `wanted.len` of `have` are `wanted`, in any order.
fn leadsWith(have: []const []const u8, wanted: []const []const u8) bool {
    if (wanted.len == 0 or have.len < wanted.len) return false;
    for (wanted) |name| {
        if (!hasName(have[0..wanted.len], name)) return false;
    }
    return true;
}

/// Two tables naming an index alike, which planning passed and the second
/// `CREATE INDEX` refused at apply. An index's name is its schema's on both
/// databases, not its table's; within one table `table.zig` already refuses
/// two entries under one name.
fn assertIndexNamesDiffer(comptime descs: []const Desc) void {
    comptime {
        for (descs, 0..) |d, i| {
            for (indexNames(d)) |name| {
                for (descs[i + 1 ..]) |other| {
                    if (!table_mod.sameSchema(d.schema, other.schema)) continue;
                    for (indexNames(other)) |taken| {
                        if (std.mem.eql(u8, name, taken)) @compileError(
                            "nilo: `" ++ d.table ++ "` and `" ++ other.table ++ "` both have an index named `" ++
                                name ++ "`.\n  An index's name belongs to the schema, not the table, so " ++
                                "the second `CREATE INDEX` would fail when the version runs. Give one " ++
                                "entry a `.name` of its own.",
                        );
                    }
                }
            }
        }
    }
}

fn indexNames(comptime d: Desc) []const []const u8 {
    comptime {
        var out: []const []const u8 = &.{};
        for (d.uniques) |u| out = out ++ .{u.name};
        for (d.indexes) |x| out = out ++ .{x.name};
        return out;
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
    desired: Desired,
) !snapshot.Doc {
    const out = try gpa.alloc(Desc, desired.tables.len);
    for (desired.tables, 0..) |t, i| {
        out[i] = t.desc;
        out[i].row = "";
        out[i].renames = &.{};
        out[i].checks = try hashedOnly(gpa, t.desc.checks);
        out[i].triggers = try hashedOnly(gpa, t.desc.triggers);
    }
    return .{
        .version = version,
        .dialect = D.name,
        .tables = out,
        .extensions = desired.extensions,
        .functions = try hashedOnly(gpa, desired.functions),
        .views = try hashedOnly(gpa, desired.views),
    };
}

/// The named objects as a snapshot records them: the name, and sixteen hex
/// characters of the text.
///
/// **The text itself does not go in the file**, and that is the whole reason
/// there is a hash at all. A `CHECK` body is one line and a view is sixty, and
/// a `.zon` file carrying sixty lines of SQL stops being readable — which is
/// the property the format was chosen for. What a diff needs to know is whether
/// it moved, and a hash answers that in one line
/// ([ADR 181](../docs/adr/181-the-marker-has-two-kinds-of-word.md)).
fn hashedOnly(
    gpa: std.mem.Allocator,
    list: []const table_mod.NamedText,
) ![]const table_mod.NamedText {
    if (list.len == 0) return &.{};
    const out = try gpa.alloc(table_mod.NamedText, list.len);
    for (list, 0..) |n, i| {
        var buf: [16]u8 = undefined;
        out[i] = .{ .name = n.name, .hash = try gpa.dupe(u8, n.digest(&buf)) };
    }
    return out;
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
    /// `SET DEFAULT` or `DROP DEFAULT`. Its own kind rather than part of
    /// `change_type` because it is the one column change that cannot fail on a
    /// table with rows in it: a default is what the next insert gets.
    change_default,
    /// The check over a column's words, dropped and made again. Two kinds
    /// rather than one, because they are two statements and a reader of the
    /// generated file should see both.
    drop_check,
    create_check,
    create_index,
    drop_index,
    /// An index or a foreign key following a column `.was` renamed, on
    /// Postgres: `ALTER INDEX … RENAME TO` and `RENAME CONSTRAINT`. Its own
    /// pair because it moves no row and rebuilds nothing, where the drop and
    /// the create it replaces rebuilt the index under a lock.
    rename_index,
    rename_constraint,
    /// A trigger, made and unmade. Its own pair rather than `create_index`'s,
    /// because the statement that unmakes one names the table on Postgres and
    /// refuses to on SQLite, and a reader of the generated file should see
    /// which kind of object moved.
    create_trigger,
    drop_trigger,
    /// The three kinds that hang off the schema rather than off a table
    /// (ADR 181). An extension is made if missing and dropped when it
    /// leaves the list; a function is one `CREATE OR REPLACE` whether it is
    /// new or moved, and dropped by name; a view is dropped and remade when
    /// its text moves, because `CREATE OR REPLACE VIEW` refuses a column
    /// that went away.
    create_extension,
    drop_extension,
    create_function,
    drop_function,
    create_view,
    drop_view,

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
    /// What a destructive step loses, as `--drop` names it: `orders` for a
    /// table, `orders.note` for a column, `extension:pgcrypto` for an
    /// extension. Empty on every other step, and not part of the hash, which
    /// covers the SQL alone.
    ///
    /// **`--drop` names these rather than switching on**, because a switch
    /// covers the drop nobody read. A field renamed without `.was` is a
    /// dropped column and an added one, and the version that says so sits
    /// beside the drop that was meant, in the same list.
    target: []const u8 = "",
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
    /// that does until the caller names each loss at the command line, and
    /// records the names in the generated file's header.
    pub fn destructive(self: Plan) bool {
        for (self.steps) |s| {
            if (s.destructive) return true;
        }
        return false;
    }

    /// The destructive steps' targets that `named` does not list, in plan
    /// order. Empty is what lets `generate` write the version.
    pub fn unnamed(self: Plan, gpa: std.mem.Allocator, named: []const []const u8) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (self.steps) |s| {
            if (!s.destructive) continue;
            if (hasName(named, s.target)) continue;
            if (hasName(out.items, s.target)) continue;
            try out.append(gpa, s.target);
        }
        return out.items;
    }

    /// The names in `named` that no destructive step has as its target.
    ///
    /// **A name that matches nothing is refused rather than ignored.** It is
    /// usually a typo for the drop that was meant, and ignoring it writes a
    /// version with that drop still missing, which reads as done.
    pub fn stray(self: Plan, gpa: std.mem.Allocator, named: []const []const u8) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (named) |n| {
            const matched = for (self.steps) |s| {
                if (s.destructive and std.mem.eql(u8, s.target, n)) break true;
            } else false;
            if (!matched) try out.append(gpa, n);
        }
        return out.items;
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
    desired: Desired,
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

    // The tables first, into a list of their own, because which views have
    // to come down depends on what happens to the tables they read.
    var table_steps: std.ArrayList(Step) = .empty;
    // Every table a step changes under a view: a column dropped, renamed or
    // given another type, or the table itself dropped. Both databases refuse
    // each of those while a view still reads the table.
    var shaped: std.ArrayList([]const u8) = .empty;

    for (desired.tables) |t| {
        // A table this program reads and does not build
        // ([ADR 130](../docs/adr/130-a-table-this-program-reads-and-does-not-build.md)).
        // It stays in `desired` rather than being filtered out before the
        // call, because the drop loop below reads this same list: a Row that
        // stops being managed would otherwise look like a Row that was
        // deleted, and the plan would drop somebody else's table.
        if (!t.desc.managed) continue;
        const old = before.table(t.desc.schema, t.desc.table) orelse {
            try table_steps.append(gpa, .{
                .kind = .create_table,
                .sql = t.created.table,
                .why = try std.fmt.allocPrint(gpa, "create {s}", .{t.desc.table}),
            });
            for (t.created.indexes) |made| {
                try table_steps.append(gpa, .{
                    .kind = .create_index,
                    .sql = made.sql,
                    .why = try std.fmt.allocPrint(gpa, "index {s}", .{made.name}),
                });
            }
            // The checks are already inside the `CREATE TABLE`; the triggers
            // cannot be, so they come after it and after its indexes.
            for (t.created.triggers) |made| {
                try table_steps.append(gpa, .{
                    .kind = .create_trigger,
                    .sql = made.sql,
                    .why = try std.fmt.allocPrint(gpa, "trigger {s}", .{made.name}),
                });
            }
            continue;
        };
        const from = table_steps.items.len;
        try diffTable(gpa, D, t, old, &table_steps, &problems);
        for (table_steps.items[from..]) |step| switch (step.kind) {
            .drop_column, .rename_column, .change_type => {
                try shaped.append(gpa, t.desc.table);
                break;
            },
            else => {},
        };
    }

    // A table the snapshot has and the types do not. Dropped after every
    // table that is kept, and **in the reverse of the order they were
    // created in**: the snapshot lists them parent first, so a child going
    // in the same change is dropped before the parent it points at, which
    // Postgres otherwise refuses without `CASCADE`.
    var gone = before.tables.len;
    while (gone > 0) {
        gone -= 1;
        const old = before.tables[gone];
        if (has(desired.tables, old)) continue;
        try table_steps.append(gpa, .{
            .kind = .drop_table,
            .sql = try dropTableSql(gpa, old),
            .why = try std.fmt.allocPrint(gpa, "drop {s}, which no Row describes", .{old.table}),
            .destructive = true,
            .target = try targetOf(gpa, old.schema, old.table, null),
        });
        try shaped.append(gpa, old.table);
    }

    // **Which views come down, before any table moves, and go back up after
    // every table is in its final shape.** A view that is gone or whose text
    // moved; one that reads a table whose columns move; one that reads a
    // view coming down. `desired.views` is in the order they read each other
    // (`viewOrder`), so a view's dependencies are settled before it is.
    const remade = try gpa.alloc(bool, desired.views.len);
    for (desired.views, 0..) |v, i| {
        const old = findNamed(before.views, v.name);
        remade[i] = old != null and (!old.?.sameAs(v) or readsAny(v.body, shaped.items) or
            readsRemade(v.body, desired.views[0..i], remade[0..i]));
    }
    // Dropped in the reverse of the order the snapshot has them in, which is
    // the order they were created in, so a view goes before one it reads.
    var at = before.views.len;
    while (at > 0) {
        at -= 1;
        const old = before.views[at];
        const index = viewIndex(desired.views, old.name);
        if (index != null and !remade[index.?]) continue;
        const now = if (index) |i| desired.views[i] else null;
        try steps.append(gpa, .{
            .kind = .drop_view,
            .sql = try ddl.dropView(gpa, old.name),
            .why = if (now == null)
                try std.fmt.allocPrint(gpa, "drop view {s}, which the schema no longer names", .{old.name})
            else if (!now.?.sameAs(old))
                try std.fmt.allocPrint(gpa, "drop view {s}, whose text moved" ++ view_grants_note, .{old.name})
            else
                try std.fmt.allocPrint(gpa, "drop view {s} while what it reads changes" ++ view_grants_note, .{old.name}),
        });
    }
    // Extensions and functions before the tables, because a column type or
    // a trigger may name either.
    for (desired.extensions) |name| {
        if (hasName(before.extensions, name)) continue;
        try steps.append(gpa, .{
            .kind = .create_extension,
            .sql = try ddl.createExtension(gpa, name),
            .why = try std.fmt.allocPrint(gpa, "extension {s}", .{name}),
        });
    }
    for (desired.functions) |f| {
        const old = findNamed(before.functions, f.name);
        if (old != null and old.?.sameAs(f)) continue;
        try steps.append(gpa, .{
            .kind = .create_function,
            .sql = f.body,
            .why = if (old == null)
                try std.fmt.allocPrint(gpa, "function {s}", .{f.name})
            else
                try std.fmt.allocPrint(gpa, "function {s}, whose text moved", .{f.name}),
        });
    }
    try steps.appendSlice(gpa, table_steps.items);

    // Views after the tables they read are in their final shape.
    for (desired.views, 0..) |v, i| {
        if (findNamed(before.views, v.name) != null and !remade[i]) continue;
        try steps.append(gpa, .{
            .kind = .create_view,
            .sql = try ddl.createView(gpa, v),
            .why = try std.fmt.allocPrint(gpa, "view {s}", .{v.name}),
        });
    }
    // A function nothing names any more, after the triggers that named it
    // have gone with their tables; an extension last of all, and destructive,
    // because dropping one drops every object it made.
    for (before.functions) |old| {
        if (findNamed(desired.functions, old.name) != null) continue;
        try steps.append(gpa, .{
            .kind = .drop_function,
            .sql = try ddl.dropFunction(gpa, old.name),
            .why = try std.fmt.allocPrint(gpa, "drop function {s}, which the schema no longer names", .{old.name}),
        });
    }
    for (before.extensions) |name| {
        if (hasName(desired.extensions, name)) continue;
        try steps.append(gpa, .{
            .kind = .drop_extension,
            .sql = try ddl.dropExtension(gpa, name),
            .why = try std.fmt.allocPrint(gpa, "drop extension {s}, which the schema no longer names, and everything it made", .{name}),
            .destructive = true,
            .target = try std.fmt.allocPrint(gpa, "extension:{s}", .{name}),
        });
    }

    return .{
        .steps = try steps.toOwnedSlice(gpa),
        .problems = try problems.toOwnedSlice(gpa),
    };
}

/// What `--drop` calls a table or one of its columns: `orders`,
/// `billing.orders`, `orders.note`.
fn targetOf(gpa: std.mem.Allocator, schema: ?[]const u8, table: []const u8, column: ?[]const u8) ![]const u8 {
    const qualified = if (schema) |s| try std.fmt.allocPrint(gpa, "{s}.{s}", .{ s, table }) else table;
    const c = column orelse return qualified;
    return std.fmt.allocPrint(gpa, "{s}.{s}", .{ qualified, c });
}

fn hasName(list: []const []const u8, name: []const u8) bool {
    for (list) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

fn has(desired: []const Table, old: Desc) bool {
    for (desired) |t| {
        if (std.mem.eql(u8, t.desc.table, old.table) and
            table_mod.sameSchema(t.desc.schema, old.schema)) return true;
    }
    return false;
}

/// Whether a view's text names any of `tables`.
fn readsAny(body: []const u8, tables: []const []const u8) bool {
    for (tables) |t| if (mentions(body, t)) return true;
    return false;
}

/// Whether a view's text names a view before it that is being remade.
fn readsRemade(body: []const u8, earlier: []const table_mod.NamedText, remade: []const bool) bool {
    for (earlier, remade) |v, again| if (again and mentions(body, v.name)) return true;
    return false;
}

fn viewIndex(list: []const table_mod.NamedText, name: []const u8) ?usize {
    for (list, 0..) |v, i| if (std.mem.eql(u8, v.name, name)) return i;
    return null;
}

/// Whether SQLite takes `text` as the default of a column `ALTER TABLE …
/// ADD COLUMN` makes on a table with rows: a literal, and not an expression
/// in brackets or a `CURRENT_` clock, which it works out per row. Every
/// other Dialect alters with any default.
fn constantOnSqlite(comptime D: type, text: []const u8) bool {
    if (comptime !std.mem.eql(u8, D.name, "sqlite")) return true;
    const t = std.mem.trim(u8, text, &std.ascii.whitespace);
    if (t.len > 0 and t[0] == '(') return false;
    return !(t.len >= 8 and std.ascii.eqlIgnoreCase(t[0..8], "CURRENT_"));
}

/// The recipe every SQLite Problem that needs the table rebuilt ends with.
const sqlite_rebuild =
    "The four statements are CREATE a new table with the shape you want, INSERT INTO " ++
    "it SELECT from the old one, DROP the old one, ALTER TABLE RENAME the new one. " ++
    "Write them as a step, then make the indexes and triggers again, since they go " ++
    "with the old table, and drop any view that reads it before the DROP and make it " ++
    "after. `db migrate` runs a version that drops a table with foreign keys off, so " ++
    "the DROP does not delete the rows pointing at the old table; run by hand, " ++
    "`PRAGMA foreign_keys = OFF` goes before the BEGIN.";

/// Whether `text` names `name` as a whole identifier, bare, quoted or after a
/// schema's dot, compared without regard to case.
///
/// **A word match rather than a parse, and it errs one way.** A column or a
/// string that happens to spell a table's name reads as naming it, and the
/// cost is a view dropped and made again that did not need to be, which
/// holds no rows. A name it missed would be a version the database refuses,
/// and the only way to miss one is to build it out of text at run time,
/// which a view cannot.
fn mentions(text: []const u8, name: []const u8) bool {
    if (name.len == 0 or name.len > text.len) return false;
    var at: usize = 0;
    while (at + name.len <= text.len) : (at += 1) {
        if (!std.ascii.eqlIgnoreCase(text[at..][0..name.len], name)) continue;
        const end = at + name.len;
        if ((at == 0 or !identByte(text[at - 1])) and (end == text.len or !identByte(text[end]))) return true;
    }
    return false;
}

fn identByte(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '$';
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

    // **A trigger that names a column about to change type comes down first.**
    // Postgres refuses `ALTER COLUMN … TYPE` on a column a trigger names in
    // `UPDATE OF` or `WHEN`, so a trigger that has not moved, and that the
    // trigger diff below therefore leaves alone, failed the version.
    var retyped: std.ArrayList([]const u8) = .empty;
    if (comptime D.can_alter_column) {
        for (t.desc.columns) |c| {
            const before = columnBefore(old, c.name, renamed.items) orelse continue;
            if (!std.mem.eql(u8, c.sql_type, before.sql_type)) try retyped.append(gpa, c.name);
        }
    }
    const early = try dropTriggersNamingRetyped(gpa, D, t, old, retyped.items, steps);

    for (t.desc.columns) |c| {
        const was = columnBefore(old, c.name, renamed.items) orelse {
            // **A Problem on SQLite rather than a step that fails at the
            // deploy.** `ADD COLUMN … NOT NULL` with no default is refused on
            // a table with rows, and a plan cannot see the rows. The same
            // column is refused up front by `addMissingColumns`
            // ([ADR 123](../docs/adr/123-a-migration-is-a-diff-against-a-snapshot.md)).
            if (comptime std.mem.eql(u8, D.name, "sqlite")) if (!c.nullable and c.default == null) {
                try problems.append(gpa, .{
                    .table = t.desc.table,
                    .column = c.name,
                    .text = try std.fmt.allocPrint(
                        gpa,
                        "{s}.{s} is added required with no default, and SQLite refuses `ADD " ++
                            "COLUMN … NOT NULL` without one on a table with rows: the ALTER " ++
                            "fails at the deploy rather than here, and nothing fills the rows " ++
                            "already there. Give the field a `.default` in the marker, so the " ++
                            "rows get it as the column is added, or make it optional and fill " ++
                            "it in a step. Or rebuild the table. " ++ sqlite_rebuild,
                        .{ t.desc.table, c.name },
                    ),
                });
                continue;
            };
            if (c.default) |text| if (!constantOnSqlite(D, text)) {
                try problems.append(gpa, .{
                    .table = t.desc.table,
                    .column = c.name,
                    .text = try std.fmt.allocPrint(
                        gpa,
                        "{s}.{s} is added with a default SQLite works out per row, `{s}`, and " ++
                            "SQLite adds such a column only to a table with no rows: on one with " ++
                            "rows the ALTER fails, at the deploy rather than here. " ++
                            sqlite_rebuild ++ " Or add the field optional with no default, fill " ++
                            "it in a step, and let the Row write it from then on.",
                        .{ t.desc.table, c.name, text },
                    ),
                });
                continue;
            };
            try steps.append(gpa, .{
                .kind = .add_column,
                .sql = try ddl.addColumn(D, gpa, t.desc, c),
                .why = try std.fmt.allocPrint(gpa, "add {s}.{s}", .{ t.desc.table, c.name }),
                // A required column with a default fills the rows already
                // there as it is added, which is the whole of what the flag
                // was warning about ([ADR 181](../docs/adr/181-the-marker-has-two-kinds-of-word.md)).
                .needs_backfill = !c.nullable and c.default == null,
            });
            continue;
        };

        // **The check follows the column's name unless `.check` named it.**
        // Postgres keeps `t_old_check` through `RENAME COLUMN`, and the next
        // snapshot derives `t_new_check`, so a later change to the words would
        // `DROP CONSTRAINT` a name the database does not have. SQLite writes
        // the constraint at creation, never refers to it by name, and follows
        // the rename inside its text, so it has nothing to rename. When the
        // words moved as well, `diffWords` drops the old name and makes the
        // new one, which comes to the same.
        if (comptime D.can_alter_constraint) {
            if (!std.mem.eql(u8, was.name, c.name) and was.values.len > 0 and
                !was.checkNamed() and !c.checkNamed() and table_mod.sameWords(c.values, was.values))
            {
                try steps.append(gpa, .{
                    .kind = .rename_constraint,
                    .sql = try ddl.renameCheck(D, gpa, t.desc, was.name, c.name),
                    .why = try std.fmt.allocPrint(
                        gpa,
                        "{s}'s check over its words is called after {s} now",
                        .{ t.desc.table, c.name },
                    ),
                });
            }
        }

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

        const shape_changed = !std.mem.eql(u8, c.sql_type, was.sql_type) or
            c.nullable != was.nullable;
        const default_changed = !table_mod.sameOptionalText(c.default, was.default);
        const words_changed = !table_mod.sameWords(c.values, was.values);
        // The same constraint under another name is still a drop and a create:
        // the one in the database has the old name, and `.check` moving it is
        // exactly the case item 12 brought.
        const check_renamed = !std.mem.eql(u8, c.check, was.check) and
            (c.values.len > 0 or was.values.len > 0);

        // **One Problem naming everything that moved**, rather than one per
        // thing: a database that cannot alter a column in place cannot alter
        // any of them in place, and the answer to all four is the same
        // rebuild. Two Problems about one column would read as two jobs.
        //
        // The guard is `comptime` because the branch it skips has to go
        // unanalysed rather than merely unrun: `ddl.alterType` asserts the
        // Dialect can, and an assert reached while compiling is a compile
        // error whether or not the call would ever happen.
        const blocked = ((shape_changed or default_changed) and !D.can_alter_column) or
            ((words_changed or check_renamed) and !D.can_alter_constraint);
        if (blocked) {
            try problems.append(gpa, .{
                .table = t.desc.table,
                .column = c.name,
                .text = try std.fmt.allocPrint(
                    gpa,
                    "{s}.{s} changed: {s}. The {s} dialect cannot change a column in " ++
                        "place — `ALTER TABLE` adds, drops and renames and does nothing " ++
                        "else, so a type, a NOT NULL, a default and a check are all fixed " ++
                        "when the table is created. " ++ sqlite_rebuild,
                    .{ t.desc.table, c.name, try whatMoved(gpa, c, was), D.name },
                ),
            });
            continue;
        }

        if (comptime D.can_alter_column) if (shape_changed or default_changed) {
            if (!std.mem.eql(u8, c.sql_type, was.sql_type)) {
                // **Only a widening goes through on its own.** Anything else
                // either refuses rows the old type held, which is the loud
                // case, or converts them into something else, which is the
                // quiet one: `numeric(10,2)` to `numeric(10,1)` rounds every
                // row, `float8` to `float4` drops digits, `timestamptz` to
                // `timestamp` moves every value by the server's zone. None of
                // them can be told apart from here, so all of them are named
                // at the command line like a dropped column is.
                const safe = widens(was.sql_type, c.sql_type);
                // A widening that is not in place still writes every row
                // again under the strongest lock there is, which is the
                // step's real cost on a big table and the reason to say it.
                const rewrite: []const u8 = if (inPlace(was.sql_type, c.sql_type))
                    ""
                else
                    try std.fmt.allocPrint(gpa, rewrites ++ "{s} wait", .{t.desc.table});
                try steps.append(gpa, .{
                    .kind = .change_type,
                    .sql = try ddl.alterType(D, gpa, t.desc, c),
                    .why = if (safe) try std.fmt.allocPrint(
                        gpa,
                        "{s}.{s} becomes {s}, from {s}{s}",
                        .{ t.desc.table, c.name, c.sql_type, was.sql_type, rewrite },
                    ) else try std.fmt.allocPrint(
                        gpa,
                        "{s}.{s} becomes {s}, from {s}, which can refuse, round or reinterpret the rows already there{s}",
                        .{ t.desc.table, c.name, c.sql_type, was.sql_type, rewrite },
                    ),
                    .destructive = !safe,
                    .target = if (safe) "" else try targetOf(gpa, t.desc.schema, t.desc.table, c.name),
                });
            }
            if (c.nullable != was.nullable) {
                try steps.append(gpa, .{
                    .kind = .change_null,
                    .sql = try ddl.alterNullability(D, gpa, t.desc, c),
                    .why = if (c.nullable) try std.fmt.allocPrint(
                        gpa,
                        "{s}.{s} may now be null",
                        .{ t.desc.table, c.name },
                    ) else try std.fmt.allocPrint(
                        gpa,
                        "{s}.{s} may no longer be null" ++ reads_all ++ "{s} wait",
                        .{ t.desc.table, c.name, t.desc.table },
                    ),
                    // A column being tightened is filled by its own default
                    // from here on, and the rows already there are the
                    // question the flag asks about.
                    .needs_backfill = !c.nullable,
                });
            }
            if (default_changed) {
                try steps.append(gpa, .{
                    .kind = .change_default,
                    .sql = try ddl.alterDefault(D, gpa, t.desc, c),
                    .why = if (c.default) |text| try std.fmt.allocPrint(
                        gpa,
                        "{s}.{s} defaults to {s}",
                        .{ t.desc.table, c.name, text },
                    ) else try std.fmt.allocPrint(
                        gpa,
                        "{s}.{s} has no default any more",
                        .{ t.desc.table, c.name },
                    ),
                });
            }
        };

        if (comptime D.can_alter_constraint) {
            if (words_changed or check_renamed) {
                try diffWords(gpa, D, t, c, was, words_changed, steps);
            }
        }
    }

    // **Checks and triggers before any column goes**, for the reason indexes
    // are: a named check over a dropped column went with it on Postgres and
    // its `DROP CONSTRAINT` then named nothing, and a trigger `BEFORE UPDATE
    // OF` a column refuses the column's drop while it is there. Every column
    // they may name by now is added or renamed.
    try diffChecks(gpa, D, t, old, steps, problems);
    try diffTriggers(gpa, D, t, old, early, steps);

    // **An index that is going goes before a column that is going.** Postgres
    // drops a column's indexes with it, so a `DROP INDEX` after the column was
    // a statement about an index that was no longer there and failed the
    // version. SQLite will not drop an indexed column at all.
    try dropGoneIndexes(gpa, D, t, old, renamed.items, steps);

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
            .target = try targetOf(gpa, t.desc.schema, t.desc.table, oc.name),
        });
    }

    try diffIndexes(gpa, D, t, old, renamed.items, steps);
    try diffReferences(gpa, D, t, old, renamed.items, steps, problems);
}

/// What a step that reads the whole table under `ACCESS EXCLUSIVE` says about
/// it, followed by the table's name: a `SET NOT NULL`, or a check added in one
/// statement.
///
/// **Said rather than split into two steps.** The two-statement forms (`ADD
/// CONSTRAINT … NOT VALID` then `VALIDATE`, a check then `SET NOT NULL` over
/// it) take the weaker lock only when the second runs in a transaction of its
/// own, and a version is one transaction: in the same one, the first
/// statement's lock is still held when the second reads the table. A version
/// of its own for the second half is written by hand (ADR 240).
const reads_all = ", which reads every row while reads and writes to ";

/// The same, for a type change that writes every row again.
const rewrites = ", which writes every row again while reads and writes to ";

/// Whether Postgres changes a column's type without touching a row: a
/// `varchar` into `text` or a longer one, and a `numeric` given more digits
/// before the point or none at all. Every other change, a widening like
/// `int4` to `int8` included, writes the table again.
fn inPlace(from: []const u8, to: []const u8) bool {
    if (std.mem.startsWith(u8, from, "varchar")) return widens(from, to);
    if (std.mem.startsWith(u8, from, "numeric")) {
        if (std.mem.eql(u8, to, "numeric")) return true;
        const f = precision(from) orelse return false;
        const g = precision(to) orelse return false;
        return g.scale == f.scale and g.digits >= f.digits;
    }
    return false;
}

/// Whether every value `from` can hold is a value `to` holds unchanged.
///
/// **A short list on purpose**, and anything not on it is destructive. What is
/// here is what the Postgres documentation calls binary-coercible or what
/// cannot round: a wider integer, `float4` to `float8`, an integer or a bounded
/// `numeric` into an unbounded one, a `varchar` into `text` or into a longer
/// `varchar`. Case and spacing are the snapshot's own, because both sides were
/// written by the same Dialect.
fn widens(from: []const u8, to: []const u8) bool {
    const ints = [_][]const u8{ "int2", "int4", "int8" };
    if (rank(&ints, from)) |f| {
        if (rank(&ints, to)) |g| return g > f;
        return std.mem.eql(u8, to, "numeric");
    }
    if (std.mem.eql(u8, from, "float4")) return std.mem.eql(u8, to, "float8");
    if (std.mem.startsWith(u8, from, "numeric")) {
        if (std.mem.eql(u8, to, "numeric")) return true;
        const f = precision(from) orelse return false;
        const g = precision(to) orelse return false;
        // Room for every digit before the point, and every digit after it.
        return g.scale >= f.scale and g.digits - g.scale >= f.digits - f.scale;
    }
    if (std.mem.startsWith(u8, from, "varchar")) {
        if (std.mem.eql(u8, to, "text") or std.mem.eql(u8, to, "varchar")) return true;
        const f = length(from) orelse return false;
        const g = length(to) orelse return false;
        return g >= f;
    }
    return false;
}

fn rank(list: []const []const u8, name: []const u8) ?usize {
    for (list, 0..) |n, i| {
        if (std.mem.eql(u8, n, name)) return i;
    }
    return null;
}

/// The `n` of `varchar(n)`.
fn length(sql_type: []const u8) ?u32 {
    const open = std.mem.indexOfScalar(u8, sql_type, '(') orelse return null;
    if (!std.mem.eql(u8, sql_type[0..open], "varchar")) return null;
    const close = std.mem.indexOfScalarPos(u8, sql_type, open, ')') orelse return null;
    return std.fmt.parseInt(u32, std.mem.trim(u8, sql_type[open + 1 .. close], " "), 10) catch null;
}

const Precision = struct { digits: u32, scale: u32 };

/// The `p` and `s` of `numeric(p, s)`; `numeric(p)` has a scale of nought.
fn precision(sql_type: []const u8) ?Precision {
    const open = std.mem.indexOfScalar(u8, sql_type, '(') orelse return null;
    if (!std.mem.eql(u8, sql_type[0..open], "numeric")) return null;
    const close = std.mem.indexOfScalarPos(u8, sql_type, open, ')') orelse return null;
    var parts = std.mem.splitScalar(u8, sql_type[open + 1 .. close], ',');
    const p = std.fmt.parseInt(u32, std.mem.trim(u8, parts.next() orelse return null, " "), 10) catch return null;
    const s = if (parts.next()) |text|
        std.fmt.parseInt(u32, std.mem.trim(u8, text, " "), 10) catch return null
    else
        0;
    if (s > p) return null;
    return .{ .digits = p, .scale = s };
}

/// What about a column is not what the snapshot recorded, as one phrase for
/// the Problem that names it. Every reason at once rather than the first, the
/// same rule the Problem list itself follows.
fn whatMoved(gpa: std.mem.Allocator, c: Column, was: Column) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;
    var first = true;

    if (!std.mem.eql(u8, c.sql_type, was.sql_type)) {
        try w.print("it is {s} and was {s}", .{ c.sql_type, was.sql_type });
        first = false;
    }
    if (c.nullable != was.nullable) {
        if (!first) try w.writeAll(", ");
        try w.writeAll(if (c.nullable) "it may be null now" else "it may no longer be null");
        first = false;
    }
    if (!table_mod.sameOptionalText(c.default, was.default)) {
        if (!first) try w.writeAll(", ");
        if (c.default) |text| {
            try w.print("it defaults to {s}", .{text});
        } else {
            try w.writeAll("it has no default any more");
        }
        first = false;
    }
    if (!table_mod.sameWords(c.values, was.values)) {
        if (!first) try w.writeAll(", ");
        try w.print("the words it may hold are {d} and were {d}", .{ c.values.len, was.values.len });
        first = false;
    }
    if (!std.mem.eql(u8, c.check, was.check)) {
        if (!first) try w.writeAll(", ");
        try w.writeAll("the check over its words is called something else now");
    }
    return aw.toOwnedSlice();
}

/// The check over a column's words, when the Zig enum behind it gained, lost or
/// renamed one.
///
/// **Dropped and made again rather than altered**, because neither database
/// alters a check constraint in place and Postgres does both in one
/// `ALTER TABLE`. Losing a word is the case worth flagging: the rows holding it
/// are already there, the new constraint refuses them, and the statement fails
/// rather than removing anything — so it is a backfill rather than data loss,
/// and the `UPDATE` that moves those rows goes in the version beside it.
fn diffWords(
    gpa: std.mem.Allocator,
    comptime D: type,
    t: Table,
    c: Column,
    was: Column,
    words_changed: bool,
    steps: *std.ArrayList(Step),
) !void {
    comptime std.debug.assert(D.can_alter_constraint);

    if (was.values.len > 0) try steps.append(gpa, .{
        .kind = .drop_check,
        // **By the column as the snapshot had it**, which is the only thing
        // that knows the name the constraint is in the database under.
        .sql = try ddl.dropCheck(D, gpa, t.desc, was),
        .why = if (words_changed) try std.fmt.allocPrint(
            gpa,
            "{s}.{s}: the words it may hold have changed",
            .{ t.desc.table, c.name },
        ) else try std.fmt.allocPrint(
            gpa,
            "{s}.{s}: the check over its words is called something else now",
            .{ t.desc.table, c.name },
        ),
    });

    if (c.values.len > 0) try steps.append(gpa, .{
        .kind = .create_check,
        .sql = try ddl.addCheck(D, gpa, t.desc, c),
        .why = try std.fmt.allocPrint(
            gpa,
            "{s}.{s}: the {d} word(s) its type has now" ++ reads_all ++ "{s} wait",
            .{ t.desc.table, c.name, c.values.len, t.desc.table },
        ),
        // A column that held any text becoming one that holds a few words
        // is the same question: every row not holding one of them fails it.
        .needs_backfill = was.values.len == 0 or anyLost(was.values, c.values),
    });
}

/// Whether the old set holds a word the new one does not — the rows already
/// written with it are what the new constraint would refuse.
fn anyLost(before: []const []const u8, now: []const []const u8) bool {
    for (before) |old| {
        for (now) |new| {
            if (std.mem.eql(u8, old, new)) break;
        } else return true;
    }
    return false;
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
///
/// **A column `.was` renamed is not a change of columns.** `RENAME COLUMN`
/// carries every index over it on both databases, so an index whose columns
/// are the old ones under their new names is the same index: with the name
/// it had, nothing to do; under the name derived from the new columns, one
/// `ALTER INDEX … RENAME` on Postgres, and a drop and a create on SQLite,
/// which cannot rename an index.
fn diffIndexes(
    gpa: std.mem.Allocator,
    comptime D: type,
    t: Table,
    old: Desc,
    renames: []const table_mod.Rename,
    steps: *std.ArrayList(Step),
) !void {
    for (t.desc.uniques) |u| {
        const before = findUnique(old.uniques, u.name);
        if (before != null and sameUniqueThrough(before.?, u, renames)) continue;
        if (comptime D.can_alter_constraint) if (before == null) if (carriedUnique(D, old, t.desc, u, renames)) |was| {
            try steps.append(gpa, .{
                .kind = .rename_index,
                .sql = try ddl.renameIndex(D, gpa, t.desc.schema, was, u.name),
                .why = try std.fmt.allocPrint(gpa, "{s} is {s} now, with the column it is over", .{ was, u.name }),
            });
            continue;
        };
        // A redefined one was dropped by `dropGoneIndexes`, before any column.
        try steps.append(gpa, .{
            .kind = .create_index,
            .sql = sqlFor(t, u.name),
            .why = try std.fmt.allocPrint(gpa, "unique {s}; writes to {s} wait while it builds", .{ u.name, t.desc.table }),
        });
    }
    for (t.desc.indexes) |x| {
        const before = findIndex(old.indexes, x.name);
        if (before != null and try sameIndexThrough(gpa, before.?, x, renames)) continue;
        if (comptime D.can_alter_constraint) if (before == null) if (try carriedIndex(gpa, D, old, t.desc, x, renames)) |was| {
            try steps.append(gpa, .{
                .kind = .rename_index,
                .sql = try ddl.renameIndex(D, gpa, t.desc.schema, was, x.name),
                .why = try std.fmt.allocPrint(gpa, "{s} is {s} now, with the column it is over", .{ was, x.name }),
            });
            continue;
        };
        try steps.append(gpa, .{
            .kind = .create_index,
            .sql = sqlFor(t, x.name),
            // A version is one transaction, and `CONCURRENTLY` refuses one,
            // so this build locks writes out; the roadmap has the way past.
            .why = try std.fmt.allocPrint(gpa, "index {s}; writes to {s} wait while it builds", .{ x.name, t.desc.table }),
        });
    }
}

/// Dropped: in the snapshot and named by nothing the types declare (and not
/// renamed onto a name they do), or named by them and defined differently.
///
/// **Both kinds before any column goes**, because a redefined index is as
/// much in a dropped column's way as a gone one: Postgres takes an index down
/// with the column it covers or its partial `WHERE` reads, so a `DROP INDEX`
/// after the column names nothing and fails the version, and SQLite refuses
/// the column's drop while the index is there. `diffIndexes` makes the new
/// one, after the columns (ADR 123).
fn dropGoneIndexes(
    gpa: std.mem.Allocator,
    comptime D: type,
    t: Table,
    old: Desc,
    renames: []const table_mod.Rename,
    steps: *std.ArrayList(Step),
) !void {
    for (old.uniques) |u| {
        if (findUnique(t.desc.uniques, u.name)) |now| {
            if (!sameUniqueThrough(u, now, renames)) try steps.append(gpa, .{
                .kind = .drop_index,
                .sql = try ddl.dropIndex(D, gpa, t.desc.schema, u.name),
                .why = try std.fmt.allocPrint(gpa, "{s} is defined differently now", .{u.name}),
            });
            continue;
        }
        if (renamedUnique(D, u, t.desc, renames)) continue;
        try steps.append(gpa, .{
            .kind = .drop_index,
            .sql = try ddl.dropIndex(D, gpa, t.desc.schema, u.name),
            .why = try std.fmt.allocPrint(gpa, "drop unique {s}", .{u.name}),
        });
    }
    for (old.indexes) |x| {
        if (findIndex(t.desc.indexes, x.name)) |now| {
            if (!try sameIndexThrough(gpa, x, now, renames)) try steps.append(gpa, .{
                .kind = .drop_index,
                .sql = try ddl.dropIndex(D, gpa, t.desc.schema, x.name),
                .why = try std.fmt.allocPrint(gpa, "{s} is defined differently now", .{x.name}),
            });
            continue;
        }
        if (try renamedIndex(gpa, D, x, t.desc, renames)) continue;
        try steps.append(gpa, .{
            .kind = .drop_index,
            .sql = try ddl.dropIndex(D, gpa, t.desc.schema, x.name),
            .why = try std.fmt.allocPrint(gpa, "drop index {s}", .{x.name}),
        });
    }
}

/// A column's name after `renames`, which is its own when none names it.
fn renamedTo(renames: []const table_mod.Rename, name: []const u8) []const u8 {
    for (renames) |r| if (std.mem.eql(u8, r.from, name)) return r.to;
    return name;
}

/// Two column lists, the first read through `renames`.
fn sameColumnsThrough(was: []const []const u8, now: []const []const u8, renames: []const table_mod.Rename) bool {
    if (was.len != now.len) return false;
    for (was, now) |a, b| if (!std.mem.eql(u8, renamedTo(renames, a), b)) return false;
    return true;
}

/// A partial index's `WHERE` with every renamed column's quoted name
/// replaced, which is what `RENAME COLUMN` does to the one in the database.
fn whereThrough(gpa: std.mem.Allocator, where: []const u8, renames: []const table_mod.Rename) ![]const u8 {
    var out = where;
    for (renames) |r| {
        const from = try std.fmt.allocPrint(gpa, "\"{s}\"", .{r.from});
        const to = try std.fmt.allocPrint(gpa, "\"{s}\"", .{r.to});
        out = try std.mem.replaceOwned(u8, gpa, out, from, to);
    }
    return out;
}

fn sameUniqueThrough(was: table_mod.Unique, now: table_mod.Unique, renames: []const table_mod.Rename) bool {
    return was.ignoring_case == now.ignoring_case and sameColumnsThrough(was.columns, now.columns, renames);
}

fn sameIndexThrough(gpa: std.mem.Allocator, was: table_mod.Index, now: table_mod.Index, renames: []const table_mod.Rename) !bool {
    return sameColumnsThrough(was.columns, now.columns, renames) and
        sameColumnsThrough(was.descending, now.descending, renames) and
        std.mem.eql(u8, try whereThrough(gpa, was.where, renames), now.where);
}

/// The old unique that `u` is once `renames` have run, when the Dialect
/// can rename an index and none of the new ones has the old one's name.
fn carriedUnique(comptime D: type, old: Desc, now: Desc, u: table_mod.Unique, renames: []const table_mod.Rename) ?[]const u8 {
    if (comptime !D.can_alter_constraint) return null;
    if (renames.len == 0) return null;
    for (old.uniques) |o| {
        if (findUnique(now.uniques, o.name) != null) continue;
        if (sameUniqueThrough(o, u, renames)) return o.name;
    }
    return null;
}

fn carriedIndex(gpa: std.mem.Allocator, comptime D: type, old: Desc, now: Desc, x: table_mod.Index, renames: []const table_mod.Rename) !?[]const u8 {
    if (comptime !D.can_alter_constraint) return null;
    if (renames.len == 0) return null;
    for (old.indexes) |o| {
        if (findIndex(now.indexes, o.name) != null) continue;
        if (try sameIndexThrough(gpa, o, x, renames)) return o.name;
    }
    return null;
}

/// Whether an old unique goes on under a new name, so is renamed and not
/// dropped.
fn renamedUnique(comptime D: type, o: table_mod.Unique, now: Desc, renames: []const table_mod.Rename) bool {
    if (comptime !D.can_alter_constraint) return false;
    if (renames.len == 0) return false;
    for (now.uniques) |u| if (sameUniqueThrough(o, u, renames)) return true;
    return false;
}

fn renamedIndex(gpa: std.mem.Allocator, comptime D: type, o: table_mod.Index, now: Desc, renames: []const table_mod.Rename) !bool {
    if (comptime !D.can_alter_constraint) return false;
    if (renames.len == 0) return false;
    for (now.indexes) |x| {
        if (try sameIndexThrough(gpa, o, x, renames)) return true;
    }
    return false;
}

/// A `CHECK` the marker named, matched by name and compared by hash.
///
/// **Three cases and nothing else**, which is the whole claim ADR 181 makes
/// about this kind of word: same name and same hash, nothing to do; same name
/// and a different hash, drop and add; a name the types no longer have, drop.
/// nilo never reads the body, so there is no fourth case where it decides the
/// change was harmless.
///
/// On SQLite all three are a Problem rather than a step, for the reason every
/// other constraint change there is: a table constraint is written at creation
/// and is part of the table from then on.
fn diffChecks(
    gpa: std.mem.Allocator,
    comptime D: type,
    t: Table,
    old: Desc,
    steps: *std.ArrayList(Step),
    problems: *std.ArrayList(Problem),
) !void {
    for (t.desc.checks) |ck| {
        const before = findNamed(old.checks, ck.name);
        if (before != null and before.?.sameAs(ck)) continue;
        if (comptime !D.can_alter_constraint) {
            try problems.append(gpa, .{
                .table = t.desc.table,
                .text = try std.fmt.allocPrint(
                    gpa,
                    "the check {s} is new or its body changed, and the {s} dialect writes " ++
                        "a table constraint when the table is created and never again. " ++ sqlite_rebuild,
                    .{ ck.name, D.name },
                ),
            });
            continue;
        }
        if (before != null) try steps.append(gpa, .{
            .kind = .drop_check,
            .sql = try ddl.dropConstraint(D, gpa, t.desc, ck.name),
            .why = try std.fmt.allocPrint(gpa, "{s} says something else now", .{ck.name}),
        });
        try steps.append(gpa, .{
            .kind = .create_check,
            .sql = try ddl.addNamedCheck(D, gpa, t.desc, ck),
            .why = try std.fmt.allocPrint(gpa, "check {s}" ++ reads_all ++ "{s} wait", .{ ck.name, t.desc.table }),
            // The rows already there are what the database tests the moment
            // this runs, and it refuses the lot rather than removing any. That
            // is a backfill, the same way a word taken off an enum is.
            .needs_backfill = before == null,
        });
    }

    for (old.checks) |o| {
        if (findNamed(t.desc.checks, o.name) != null) continue;
        if (comptime !D.can_alter_constraint) {
            try problems.append(gpa, .{
                .table = t.desc.table,
                .text = try std.fmt.allocPrint(
                    gpa,
                    "the check {s} is gone from the types and is still on the table. The " ++
                        "{s} dialect cannot drop a table constraint, so the table has to be " ++
                        "rebuilt. " ++ sqlite_rebuild,
                    .{ o.name, D.name },
                ),
            });
            continue;
        }
        try steps.append(gpa, .{
            .kind = .drop_check,
            .sql = try ddl.dropConstraint(D, gpa, t.desc, o.name),
            .why = try std.fmt.allocPrint(gpa, "drop check {s}", .{o.name}),
        });
    }
}

/// The same three cases for a trigger, and both databases can do all three.
///
/// **Dropped and made again rather than replaced**, even on Postgres, which has
/// `CREATE OR REPLACE TRIGGER`. A replace keeps the old definition if the new
/// one fails to parse halfway through a version, and two statements a reader
/// can see is what the generated file is for.
fn diffTriggers(
    gpa: std.mem.Allocator,
    comptime D: type,
    t: Table,
    old: Desc,
    early: []const []const u8,
    steps: *std.ArrayList(Step),
) !void {
    for (t.desc.triggers) |tr| {
        const before = findNamed(old.triggers, tr.name);
        // Already dropped by `dropTriggersNamingRetyped`, so it is made again
        // here whether or not its text moved.
        const down = hasName(early, tr.name);
        if (before != null and !down and before.?.sameAs(tr)) continue;
        if (before != null and !down) try steps.append(gpa, .{
            .kind = .drop_trigger,
            .sql = try ddl.dropTrigger(D, gpa, t.desc, tr.name),
            .why = try std.fmt.allocPrint(gpa, "{s} runs something else now", .{tr.name}),
        });
        try steps.append(gpa, .{
            .kind = .create_trigger,
            .sql = try ddl.createTrigger(D, gpa, t.desc, tr),
            .why = try std.fmt.allocPrint(gpa, "trigger {s}", .{tr.name}),
        });
    }

    for (old.triggers) |o| {
        if (findNamed(t.desc.triggers, o.name) != null) continue;
        if (hasName(early, o.name)) continue;
        try steps.append(gpa, .{
            .kind = .drop_trigger,
            .sql = try ddl.dropTrigger(D, gpa, t.desc, o.name),
            .why = try std.fmt.allocPrint(gpa, "drop trigger {s}", .{o.name}),
        });
    }
}

/// The triggers dropped before a column changes type, by name, so
/// `diffTriggers` neither drops them twice nor leaves them unmade.
///
/// **Which ones**: a trigger that is changing or going comes down anyway, and
/// the snapshot holds only a hash of its old text, so there is no telling
/// whether it names the column and it comes down now. One that has not moved
/// is the text the database holds, and a word match (`mentions`, which errs
/// toward dropping one that did not need it) says whether it names a column
/// being retyped, in `UPDATE OF`, in `WHEN` or anywhere else. A trigger that
/// does not is left standing; it costs nothing and keeps the step list short.
fn dropTriggersNamingRetyped(
    gpa: std.mem.Allocator,
    comptime D: type,
    t: Table,
    old: Desc,
    retyped: []const []const u8,
    steps: *std.ArrayList(Step),
) ![]const []const u8 {
    if (retyped.len == 0) return &.{};
    var early: std.ArrayList([]const u8) = .empty;
    for (old.triggers) |o| {
        if (findNamed(t.desc.triggers, o.name)) |now| {
            if (now.sameAs(o) and !mentionsAny(now.body, retyped) and !mentionsAny(now.tail, retyped)) continue;
        }
        try steps.append(gpa, .{
            .kind = .drop_trigger,
            .sql = try ddl.dropTrigger(D, gpa, t.desc, o.name),
            .why = try std.fmt.allocPrint(
                gpa,
                "drop trigger {s} while a column of {s} changes type, which Postgres refuses under a trigger that names it",
                .{ o.name, t.desc.table },
            ),
        });
        try early.append(gpa, o.name);
    }
    return early.items;
}

/// Whether `text` names any of `names` as a whole identifier.
fn mentionsAny(text: []const u8, names: []const []const u8) bool {
    for (names) |n| if (mentions(text, n)) return true;
    return false;
}

fn findNamed(list: []const table_mod.NamedText, name: []const u8) ?table_mod.NamedText {
    for (list) |n| {
        if (std.mem.eql(u8, n.name, name)) return n;
    }
    return null;
}

/// A foreign key that is not the one the snapshot recorded.
///
/// **Refused on both databases, and the Postgres half is refused on purpose.**
/// It can write `ALTER TABLE … ADD CONSTRAINT … FOREIGN KEY` in one statement,
/// and that statement takes an ACCESS EXCLUSIVE lock and scans the whole table
/// to check the rows already there. On a large table under load that is an
/// outage. The two-statement form does not lock, and choosing between them is
/// an operational decision rather than something to pick for somebody.
///
/// **A column `.was` renamed is not a new key**: `RENAME COLUMN` carries the
/// constraint on both databases. Under its old name it needs nothing; under
/// the name derived from the new column, Postgres gets one `RENAME
/// CONSTRAINT`, and SQLite, whose constraints nothing here drops by name,
/// needs nothing either.
fn diffReferences(
    gpa: std.mem.Allocator,
    comptime D: type,
    t: Table,
    old: Desc,
    renames: []const table_mod.Rename,
    steps: *std.ArrayList(Step),
    problems: *std.ArrayList(Problem),
) !void {
    for (t.desc.references) |r| {
        const before = findReference(old.references, r.name);
        if (before != null and sameReferenceThrough(before.?, r, renames)) continue;
        if (before == null) if (carriedReference(old, t.desc, r, renames)) |was| {
            if (comptime D.can_alter_constraint) try steps.append(gpa, .{
                .kind = .rename_constraint,
                .sql = try ddl.renameConstraint(D, gpa, t.desc, was, r.name),
                .why = try std.fmt.allocPrint(gpa, "{s} is {s} now, with the column it is over", .{ was, r.name }),
            });
            continue;
        };
        const mine = try quotedList(gpa, r.columns);
        const theirs = try quotedList(gpa, r.targets);
        try problems.append(gpa, .{
            .table = t.desc.table,
            .column = try plainList(gpa, r.columns),
            .text = try std.fmt.allocPrint(
                gpa,
                "the foreign key {s} is new or changed, and the table already exists. " ++
                    "Adding one in a single statement locks the table and scans every row " ++
                    "in it. Write it as a step, in two: `ALTER TABLE \"{s}\" ADD CONSTRAINT " ++
                    "\"{s}\" FOREIGN KEY ({s}) REFERENCES \"{s}\" ({s}) NOT VALID`, " ++
                    "then `ALTER TABLE \"{s}\" VALIDATE CONSTRAINT \"{s}\"`. SQLite has " ++
                    "neither statement and needs the table rebuilt.",
                .{ r.name, t.desc.table, r.name, mine, r.table, theirs, t.desc.table, r.name },
            ),
        });
    }
    for (old.references) |o| {
        if (findReference(t.desc.references, o.name) != null) continue;
        if (renamedReference(o, t.desc, renames)) continue;
        try problems.append(gpa, .{
            .table = t.desc.table,
            .column = try plainList(gpa, o.columns),
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

fn sameReferenceThrough(was: table_mod.Reference, now: table_mod.Reference, renames: []const table_mod.Rename) bool {
    return sameColumnsThrough(was.columns, now.columns, renames) and
        std.mem.eql(u8, was.table, now.table) and
        table_mod.sameSchema(was.schema, now.schema) and
        table_mod.sameColumns(was.targets, now.targets) and
        was.on_delete == now.on_delete;
}

/// The old foreign key `r` is once `renames` have run, under a name no new
/// key has.
fn carriedReference(old: Desc, now: Desc, r: table_mod.Reference, renames: []const table_mod.Rename) ?[]const u8 {
    if (renames.len == 0) return null;
    for (old.references) |o| {
        if (findReference(now.references, o.name) != null) continue;
        if (sameReferenceThrough(o, r, renames)) return o.name;
    }
    return null;
}

fn renamedReference(o: table_mod.Reference, now: Desc, renames: []const table_mod.Rename) bool {
    if (renames.len == 0) return false;
    for (now.references) |r| if (sameReferenceThrough(o, r, renames)) return true;
    return false;
}

/// `"a", "b"` — the columns of a foreign key as they go inside a statement.
fn quotedList(gpa: std.mem.Allocator, columns: []const []const u8) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    for (columns, 0..) |c, i| {
        if (i > 0) try aw.writer.writeAll(", ");
        try aw.writer.print("\"{s}\"", .{c});
    }
    return aw.toOwnedSlice();
}

/// The same list unquoted, for the `column` a `Problem` is reported against.
fn plainList(gpa: std.mem.Allocator, columns: []const []const u8) ![]const u8 {
    if (columns.len == 1) return columns[0];
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    for (columns, 0..) |c, i| {
        if (i > 0) try aw.writer.writeAll(", ");
        try aw.writer.writeAll(c);
    }
    return aw.toOwnedSlice();
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
    /// How long one step may wait for a lock before the version gives up,
    /// in milliseconds; `0` waits for as long as it takes. Postgres only.
    ///
    /// **An `ALTER` waiting for its lock stops every read and write to the
    /// table behind it**, because Postgres queues a request behind a waiting
    /// stronger one. So this is the longest a migration can stall a table
    /// before it has done anything, not how long it runs: once a step holds
    /// its lock, it keeps it to the commit. Not part of the hash, which
    /// covers the statements alone, so moving it after a version ran is
    /// not drift ([ADR 240](../docs/adr/240-a-migration-waits-five-seconds-for-a-table.md)).
    lock_timeout_ms: u32 = default_lock_timeout_ms,
};

/// Five seconds: a stall a request sits out well inside the thirty to sixty
/// a proxy usually gives it, and longer than a request's own transaction. What is holding a
/// table longer than this is a report, a stuck transaction or somebody's
/// `psql`, and waiting behind it is the outage (ADR 240).
pub const default_lock_timeout_ms: u32 = 5_000;

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
    /// `addMissingColumns` found a required column with no default, which is
    /// an `ALTER` that fails on a table with rows in it. Nothing was sent.
    NeedsBackfill,
    /// `addMissingColumns` found a new column inside a foreign key of several
    /// columns, on SQLite, which writes such a key only when it creates the
    /// table, or one defaulting to the clock on a SQLite table with rows,
    /// which SQLite refuses. Nothing was kept.
    NeedsVersion,
    /// `applyPending` found a version the ledger has under another hash: its
    /// steps were edited after it ran. Nothing was applied, including the
    /// versions after it, which were written against what it used to say.
    SchemaDrift,
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
/// **Nothing is formatted or concatenated to produce a statement.** Every byte
/// it sends is a constant in the binary, including the order the tables go
/// in. What it reads first is the columns of each table that has an index,
/// out of the Scope's arena, so an index over a field the table has not got
/// yet waits for `addMissingColumns`. This is the whole of what a small SQLite application needs at
/// startup, and it replaces the ten hand-written lines
/// [ADR 180](../docs/adr/180-work-that-needs-the-services-runs-on-their-loop.md) found:
///
/// ```zig
/// fn makeTables(run: *nilo.Run, db: *sql.Db) !void {
///     try sql.migrate.createMissing(db, run, .{ .tables = &.{ Account, Document } });
/// }
///
/// try app.before(makeTables, .{&db});
/// try app.listen(.{ .port = 8080 });
/// ```
///
/// Inside `listen()` rather than before it, because the pool is dialled
/// through the loop `listen()` builds (ADR 180).
///
/// **It is not a migration runner and does not pretend to be one.** It creates
/// what is missing and never alters what is there, so a table whose shape has
/// moved is left exactly as it was and `db.checking` is what says so. A program
/// that has to change a table it already shipped wants `apply` and the files
/// behind it.
pub fn createMissing(db: anytype, scope: anytype, comptime schema: Schema) !void {
    const D = comptime DialectOf(@TypeOf(db));
    comptime core.checkScope(@TypeOf(scope), "migrate.createMissing");

    var tx = try db.begin(scope, .{ .isolation = comptime schemaLevel(D) });
    errdefer tx.rollback();
    try enterLocked(D, &tx, scope, default_lock_timeout_ms);

    // **The columns of each table that has an index, read under the lock and
    // through the transaction.** A field added to a shipped Row with a unique
    // or an index on it is a column the table has not got until
    // `addMissingColumns` runs, and the `CREATE INDEX IF NOT EXISTS` over it
    // came first: Postgres refused it, and SQLite, reading a double-quoted
    // name it cannot find as a string, indexed the constant and refused the
    // second row. Such an index is left to `addMissingColumns`, which makes it
    // with the column. Read under the lock because another replica may be
    // adding that column this moment.
    const ordered = comptime orderOf(D, schema);
    var live: [ordered.len][]const wire_mod.Column = @splat(&.{});
    inline for (ordered, 0..) |R, i| {
        if (comptime row_mod.managedOf(R) and ddl.createdIfMissing(D, R).indexes.len > 0) {
            const q = comptime row_mod.qualifiedOf(R);
            live[i] = try tx.liveColumns(scope, q.schema, q.table);
        }
    }

    // The order the tool owns: extensions, functions, tables, views (ADR 181).
    // A view or trigger goes through `sendRepeatable`, which on SQLite reads
    // the stored definitions once and sends only those that changed.
    var stored: Stored = .{};
    for (comptime leadingOf(D, schema)) |sql| try sendBounded(&tx, scope, sql, "createMissing");
    inline for (ordered, 0..) |R, i| {
        if (comptime row_mod.managedOf(R)) {
            const made = comptime ddl.createdIfMissing(D, R);
            const t = comptime tableOf(D, R);
            try sendBounded(&tx, scope, made.table, "createMissing");
            for (made.indexes) |ix| {
                // A table that was not there has every column now.
                if (live[i].len == 0 or !overMissing(D, t.desc, ix.name, live[i]))
                    try sendBounded(&tx, scope, ix.sql, "createMissing");
            }
            inline for (comptime triggersRepeatable(D, t.desc)) |tr| try sendRepeatable(D, &tx, scope, &stored, tr);
        }
    }
    inline for (comptime viewsRepeatable(D, schema)) |v| try sendRepeatable(D, &tx, scope, &stored, v);
    try tx.commit();
}

/// What every transaction that changes a schema does first: the advisory lock
/// `apply` takes, then the bound on how long a step waits for a table's lock
/// (ADR 240). One place, so `createMissing` and `addMissingColumns` cannot
/// drift from `apply`.
///
/// **The lock first, the bound after it**, for the reason `apply` gives:
/// waiting for another replica is the wait the advisory lock exists for, and
/// it holds no table. `apply` reads the ledger between the two.
fn enterLocked(comptime D: type, tx: anytype, scope: anytype, lock_timeout_ms: u32) !void {
    try takeAdvisory(D, tx, scope);
    try boundTableWaits(D, tx, scope, lock_timeout_ms);
}

/// The level a transaction that takes the advisory lock begins at, or null for
/// a database that has no weaker one to name.
///
/// **Named, never left to the role.** A plain `BEGIN` is whatever the role's
/// `default_transaction_isolation` says, and under REPEATABLE READ the snapshot
/// is taken when the lock's `SELECT` starts: the replica that then waits for
/// the lock reads a ledger from before the other committed, does not see the
/// version, and runs it again. At READ COMMITTED the `find` after the lock is a
/// new statement and sees what the other replica left. Whether a role may be
/// set to the stricter level is the DBA's business; whether a migration is
/// safe under it is not left to chance.
fn schemaLevel(comptime D: type) ?wire_mod.Isolation {
    return if (D.has_read_committed) .read_committed else null;
}

fn takeAdvisory(comptime D: type, tx: anytype, scope: anytype) !void {
    if (comptime D.advisoryLock(lock_key)) |held| _ = try tx.exec(scope, held, .{});
}

/// Set for the transaction alone, and always, so a `0` also overrides a
/// `lock_timeout` the connection's URL gave it.
fn boundTableWaits(comptime D: type, tx: anytype, scope: anytype, lock_timeout_ms: u32) !void {
    if (comptime D.lock_timeout) |bound| {
        var digits: [10]u8 = undefined;
        const ms = std.fmt.bufPrint(&digits, "{d}", .{lock_timeout_ms}) catch unreachable;
        _ = try tx.exec(scope, bound, .{ms});
    }
}

/// One statement of `createMissing` or `addMissingColumns`, with the line an
/// operator needs when the table lock it waited for never came.
fn sendBounded(tx: anytype, scope: anytype, sql: []const u8, comptime who: []const u8) !void {
    _ = tx.exec(scope, sql, .{}) catch |err| {
        if (err == error.Locked) std.log.warn(
            "nilo_sql: " ++ who ++ " waited {d} ms for a lock on a table at `{s}`, and gave up. " ++
                "Nothing was kept. A transaction open on that table is in the way; run it " ++
                "again once that transaction ends.",
            .{ default_lock_timeout_ms, sql },
        );
        return err;
    };
}

/// Whether the index or unique called `name` names a column `live` lacks,
/// in its columns or in a partial index's `WHERE`.
fn overMissing(comptime D: type, desc: Desc, name: []const u8, live: []const wire_mod.Column) bool {
    for (desc.columns) |c| {
        if (hasNamed(live, c.name)) continue;
        const missing: []const []const u8 = &.{c.name};
        for (desc.uniques) |u| if (std.mem.eql(u8, u.name, name) and namesAny(u.columns, missing)) return true;
        for (desc.indexes) |x| if (std.mem.eql(u8, x.name, name) and
            (namesAny(x.columns, missing) or whereNamesAny(D, x.where, missing))) return true;
    }
    return false;
}

/// The step between `createMissing` and `apply`: one `ALTER TABLE … ADD
/// COLUMN` per field a shipped table has not got, typed the way
/// `createMissing` would have typed it, and how many were added
/// ([ADR 123](../docs/adr/123-a-migration-is-a-diff-against-a-snapshot.md)).
///
/// ```zig
/// try sql.migrate.createMissing(&db, &run, schema);
/// _ = try sql.migrate.addMissingColumns(&db, &run, schema);
/// ```
///
/// **For the program that keeps its own SQLite file and added a field.** A
/// CLI that shipped `downloads` with five columns and now has a Row with
/// eight does not want a ledger table and version files for three `ADD
/// COLUMN`s, and it does not want to write them by hand either: a type
/// mapping copied out of `createMissing`'s output is a type mapping that
/// drifts from it the next time this module's moves. The column is
/// described once, in the Row, and this reads the same `Desc` the create
/// does — `pragma_table_info` on SQLite, `pg_catalog` on Postgres, and
/// `ddl.addColumn` for each name the table lacks.
///
/// **A required column with no default is refused**, `error.NeedsBackfill`,
/// with the statement it would have sent in the log. SQLite refuses that
/// `ALTER` outright and Postgres refuses it on a table with rows, so on
/// neither is it a statement this can send and mean. Give the field a
/// `.default` in the marker — the rows already there get it and there is
/// nothing to backfill — or make it optional, or write the version.
///
/// **A table that is not there is skipped**, because it is `createMissing`'s,
/// and calling that first is the order the two lines above show. Nothing
/// else is touched: a column the table has that the Row does not is left,
/// a type that moved is left, and `db.checking` is what says so — this adds
/// and does not alter, the same line `createMissing` draws.
pub fn addMissingColumns(db: anytype, scope: anytype, comptime schema: Schema) !usize {
    const D = comptime DialectOf(@TypeOf(db));
    comptime core.checkScope(@TypeOf(scope), "migrate.addMissingColumns");
    const arena = scope.arena();

    var tx = try db.begin(scope, .{ .isolation = comptime schemaLevel(D) });
    errdefer tx.rollback();
    try enterLocked(D, &tx, scope, default_lock_timeout_ms);

    var added: usize = 0;
    inline for (schema.tables) |R| {
        if (comptime row_mod.managedOf(R)) {
            const t = comptime tableOf(D, R);
            const q = comptime row_mod.qualifiedOf(R);
            const live = try tx.liveColumns(scope, q.schema, q.table);
            if (live.len != 0) {
                var fresh: std.ArrayList([]const u8) = .empty;
                inline for (t.desc.columns) |c| {
                    if (!hasNamed(live, c.name)) {
                        // **With its `REFERENCES`**, which `ddl.addColumn` leaves
                        // off because the diff refuses a key on a table that
                        // exists and names the safe statements instead. Here the
                        // column is new and empty, so the key costs no scan and
                        // cannot fail; without it an insert pointing at a parent
                        // that is not there succeeded for ever, and the startup
                        // check, which reads columns only, never said.
                        const sql = try std.mem.concat(arena, u8, &.{
                            try ddl.addColumn(D, arena, t.desc, c),
                            comptime ddl.referenceClause(D, t.desc, c.name),
                        });
                        if (!c.nullable and c.default == null) {
                            // A warning rather than an error, for the reason
                            // `wireOf`'s is one: the call already fails on its
                            // own, and `std.log.err` fails the test runner for
                            // the test that provokes it.
                            std.log.warn(
                                "nilo_sql: {s} has a required column `{s}` that the table has not got, and no default to fill the rows already there. " ++
                                    "Not sent: `{s}`. Give the field a `.default` in the marker, make it optional, or write the version.",
                                .{ @typeName(R), c.name, sql },
                            );
                            return Error.NeedsBackfill;
                        }
                        _ = tx.exec(scope, sql, .{}) catch |err| {
                            // SQLite adds a column whose default it works
                            // out per row, `.now`, only to a table with no
                            // rows, and says nothing more than that it failed.
                            if (comptime c.default != null and !constantOnSqlite(D, c.default.?)) {
                                std.log.warn(
                                    "nilo_sql: {s}'s `{s}` defaults to the clock, and SQLite adds such a column only to a table with no rows. " ++
                                        "Not kept: `{s}`. Make the field optional with no default and fill it in a step, or write the version that rebuilds the table.",
                                    .{ @typeName(R), c.name, sql },
                                );
                                return Error.NeedsVersion;
                            }
                            if (err == error.Locked) std.log.warn(
                                "nilo_sql: addMissingColumns waited {d} ms for a lock on {s} at `{s}`, and gave up. " ++
                                    "Nothing was kept. A transaction open on that table is in the way; run it " ++
                                    "again once that transaction ends.",
                                .{ default_lock_timeout_ms, t.desc.table, sql },
                            );
                            return err;
                        };
                        added += 1;
                        try fresh.append(arena, c.name);
                    }
                }
                if (fresh.items.len != 0) try keysOfAdded(D, R, &tx, scope, fresh.items);
            }
        }
    }
    try tx.commit();
    return added;
}

/// What a column `addMissingColumns` just added carries besides itself: a
/// foreign key of several columns that names it, and every unique and index
/// over it, each of which `createMissing` would have written with the table.
fn keysOfAdded(
    comptime D: type,
    comptime R: type,
    tx: anytype,
    scope: anytype,
    fresh: []const []const u8,
) !void {
    const t = comptime tableOf(D, R);
    inline for (t.desc.references) |r| {
        if (r.columns.len > 1 and namesAny(r.columns, fresh)) {
            if (comptime !D.can_alter_constraint) {
                std.log.warn(
                    "nilo_sql: {s} adds a column to the foreign key {s}, which SQLite writes only " ++
                        "when it creates the table. Nothing was kept; write a version that rebuilds it.",
                    .{ @typeName(R), r.name },
                );
                return Error.NeedsVersion;
            }
            _ = try tx.exec(scope, comptime "ALTER TABLE " ++ D.qualify(t.desc.schema, t.desc.table) ++
                " ADD " ++ ddl.foreignKeyClause(D, r), .{});
        }
    }
    inline for (t.desc.uniques) |u| {
        if (namesAny(u.columns, fresh)) _ = try tx.exec(scope, comptime sqlFor(t, u.name), .{});
    }
    inline for (t.desc.indexes) |x| {
        if (namesAny(x.columns, fresh) or whereNamesAny(D, x.where, fresh))
            _ = try tx.exec(scope, comptime sqlFor(t, x.name), .{});
    }
}

fn namesAny(columns: []const []const u8, fresh: []const []const u8) bool {
    for (columns) |c| for (fresh) |f| if (std.mem.eql(u8, c, f)) return true;
    return false;
}

/// Whether a partial index's `WHERE` names one of `fresh`, by its quoted name,
/// which is how the Dialect rendered it.
fn whereNamesAny(comptime D: type, where: []const u8, fresh: []const []const u8) bool {
    if (where.len == 0) return false;
    const quote = D.quote("")[0];
    for (fresh) |f| {
        var at: usize = 0;
        while (std.mem.indexOfPos(u8, where, at, f)) |i| : (at = i + 1) {
            if (i > 0 and where[i - 1] == quote and i + f.len < where.len and where[i + f.len] == quote)
                return true;
        }
    }
    return false;
}

fn hasNamed(columns: []const wire_mod.Column, name: []const u8) bool {
    for (columns) |c| if (std.mem.eql(u8, c.name, name)) return true;
    return false;
}

/// The ledger, made if it is not there: the same `CREATE TABLE IF NOT
/// EXISTS` any other table gets, behind the lock `apply` takes.
///
/// **A ledger that is already there is one catalog read and nothing else**, and
/// that is the case that matters most. `CREATE TABLE IF NOT EXISTS` is checked
/// against the schema's CREATE privilege *before* it looks for the table, so
/// asking it of a database that has the ledger refused an application role
/// that may read and write rows and may not create anything, which is the role
/// an application that is not the migration's owner connects as. `expect` runs
/// on every boot, so it would have refused to start for a table that was right
/// there. The read is of the catalog, which needs no privilege on the table.
///
/// **The lock is not ceremony when it is not there.** Two Postgres sessions
/// running `CREATE TABLE IF NOT EXISTS` for the same new table at the same
/// moment can both pass the "not there" check, and the second fails on the
/// catalog's own unique index, which arrives as `AlreadyExists`. Ten replicas
/// booting against a fresh database is exactly that moment, so a ledger that is
/// not there is made behind the lock: four round trips instead of one, once.
pub fn ensureLedger(db: anytype, scope: anytype) !void {
    const D = comptime DialectOf(@TypeOf(db));
    const create = comptime ddl.createIfMissing(D, Applied);
    const lock = comptime D.advisoryLock(lock_key);
    if (lock == null) {
        _ = try db.exec(scope, create, .{});
        return;
    }
    const q = comptime row_mod.qualifiedOf(Applied);
    if ((try db.liveColumns(scope, q.schema, q.table)).len > 0) return;

    var tx = try db.begin(scope, .{ .isolation = comptime schemaLevel(D) });
    defer tx.deinit();
    _ = try tx.exec(scope, lock.?, .{});
    _ = try tx.exec(scope, create, .{});
    try tx.commit();
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
/// itself can. `expect` is this plus the sentence and the refusal.
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
            // `warn` rather than `err`, though this stops the process: the
            // refusal is the error handed back, which `main` returns and the
            // runtime prints. The line is the explanation, and at `err` it
            // made the one branch that matters untestable (ADR 145).
            std.log.warn(
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

/// Whether a version drops a table, which on SQLite is what a rebuild does
/// and the one statement foreign keys being on changes the meaning of.
///
/// **Read off the words, and wrong only the safe way.** `DROP` then `TABLE`
/// anywhere in a step, a comment or a string included, turns foreign keys
/// off for the version and checks every one before its COMMIT, which is what
/// every version did before. What it cannot do is miss a rebuild: there is no
/// way to drop a table without writing those two words.
pub fn rebuilds(steps: []const Step) bool {
    for (steps) |step| {
        var words = std.mem.tokenizeAny(u8, step.sql, " \t\r\n;(");
        var dropped = false;
        while (words.next()) |word| {
            if (dropped and std.ascii.eqlIgnoreCase(word, "TABLE")) return true;
            dropped = std.ascii.eqlIgnoreCase(word, "DROP");
        }
    }
    return false;
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
///
/// Between the check and the steps, Postgres is told how long a step may wait
/// for a table's lock (`Version.lock_timeout_ms`). A step that waits longer
/// fails with `error.Locked` and a line naming it, and nothing is kept.
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
    // migration ([ADR 041](../docs/adr/041-core-knows-what-time-it-is.md)).
    const started = core.monotonicMicros();
    // On SQLite, a version that drops a table runs with foreign keys off
    // until the COMMIT checks them once: a rebuild drops the old table, and
    // with them on that DROP deletes every row first and fires every `ON
    // DELETE CASCADE` pointing at it (`wire.Begin.rebuilding`). Any other
    // version keeps them on, so a `DELETE` of a parent cascades as the
    // schema says and nothing reads every key in the file at its end. A
    // dialect that alters a column in place has no rebuild to protect.
    //
    // **At READ COMMITTED where the database has it** (`schemaLevel`): the
    // ledger is read after the advisory lock, and only a statement that starts
    // after the lock is granted sees what the replica that held it committed.
    var tx = if (comptime !D.can_alter_column) (if (rebuilds(v.steps))
        try db.begin(scope, .{ .rebuilding = true, .isolation = comptime schemaLevel(D) })
    else
        try db.begin(scope, .{ .isolation = comptime schemaLevel(D) })) else try db.begin(scope, .{ .isolation = comptime schemaLevel(D) });
    errdefer tx.rollback();

    try takeAdvisory(D, &tx, scope);
    if (try tx.find(Applied, scope, v.number) != null) {
        try tx.commit();
        return false;
    }

    // **After the advisory lock, not before**: see `enterLocked`.
    try boundTableWaits(D, &tx, scope, v.lock_timeout_ms);

    for (v.steps) |s| _ = tx.exec(scope, s.sql, .{}) catch |err| {
        // `warn`, as `expect`'s refusal is: the error is the refusal, and
        // this is the sentence an operator needs to act on it (ADR 145).
        if (err == error.Locked) std.log.warn(
            "nilo_sql: version {d} ({s}) waited {d} ms for a lock on a table at the step " ++
                "\"{s}\", and gave up. Nothing was applied. A transaction open on that table " ++
                "is in the way, and every read and write to it was queued behind this step " ++
                "while it waited. Run it again once that transaction ends, or set " ++
                "`.lock_timeout_ms` in the version file (0 waits for good).",
            .{ v.number, v.name, v.lock_timeout_ms, s.why },
        );
        return err;
    };

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
/// **This is the in-process runner**, called from `app.before` inside
/// `listen()` by a program that has nowhere else to run its DDL — which is
/// every single-file SQLite application, and plenty of Postgres ones. One
/// transaction per version, each behind the same advisory lock, so ten
/// replicas booting together still run each version once.
///
/// **The ledger is read once, before anything runs**, and it answers two
/// things. A version recorded under another hash was edited after it ran,
/// and nothing is applied: the versions after it were written against what
/// it used to say, which is `db migrate`'s refusal made where a program
/// migrates itself (`Error.SchemaDrift`). And a version already recorded is
/// skipped without a transaction, so a boot with nothing to do is one read
/// rather than a BEGIN, a lock and a COMMIT per version. A version that is
/// not recorded still goes through `apply`, which checks again under the
/// lock, because another process may have applied it since.
pub fn applyPending(db: anytype, scope: anytype, chain: Chain) !usize {
    comptime core.checkScope(@TypeOf(scope), "migrate.applyPending");
    try ensureLedger(db, scope);
    return applyRecorded(db, scope, chain, try readLedger(db, scope));
}

/// `applyPending` for a caller that has already made the ledger and read it,
/// which `db migrate` has: it asks the ledger what has drifted, and then what
/// is waiting, of one read (and one `ensureLedger`, which is a BEGIN, a lock,
/// a CREATE and a COMMIT on Postgres). Same refusal, same order.
pub fn applyRecorded(db: anytype, scope: anytype, chain: Chain, recorded: []const Recorded) !usize {
    comptime core.checkScope(@TypeOf(scope), "migrate.applyRecorded");
    for (chain.versions, chain.hashes) |v, hash| {
        const hash_then = switch (seen(recorded, v.number, hash)) {
            .absent, .same => continue,
            .moved => |then| then,
        };
        std.log.warn(
            "nilo_sql: version {d} ({s}) has been edited since it was applied here: the ledger " ++
                "has it as {s} and the binary as {s}. Nothing was applied. Put that version " ++
                "back, and write what you meant as a new one; `db verify` lists every version it moved.",
            .{ v.number, v.name, hash_then[0..@min(16, hash_then.len)], hash[0..16] },
        );
        return Error.SchemaDrift;
    }

    var ran: usize = 0;
    for (chain.versions, chain.hashes) |v, hash| {
        switch (seen(recorded, v.number, hash)) {
            .absent => {},
            .same, .moved => continue,
        }
        if (try apply(db, scope, v, hash)) ran += 1;
    }
    return ran;
}

/// The two columns of the ledger a boot, `status`, `verify` and `migrate`
/// read. Narrow, so nothing carries every name and timestamp across.
pub const Recorded = struct {
    pub const nilo_table = Applied;
    version: i64,
    hash: []const u8,
};

/// **The whole ledger, in one query, in version order.** Every reader of it
/// (`applyPending`, `drift`, and the `db` tool's `status`) used to ask for
/// its versions one `find` at a time, a round trip per version in the
/// manifest; a boot with nothing to do is this one read. The ledger is small
/// and holds a version per migration ever applied, which is the same order of
/// magnitude as the manifest. Does not make the ledger: `ensureLedger` first.
pub fn readLedger(db: anytype, scope: anytype) ![]const Recorded {
    comptime core.checkScope(@TypeOf(scope), "migrate.readLedger");
    return db.select(Recorded, scope, .{ .order = .{ .version = .asc } });
}

/// What the ledger says of one version of the binary's chain.
pub const Seen = union(enum) {
    /// Not applied here.
    absent,
    /// Applied, and its steps hash to what they did then.
    same,
    /// Applied under the hash it carries, and the steps hash to something
    /// else now: the file was edited after it ran.
    moved: []const u8,

    /// Whether the ledger has the version at all, edited or not.
    pub fn applied(self: Seen) bool {
        return switch (self) {
            .absent => false,
            .same, .moved => true,
        };
    }

    /// Whether the version ran and its file has been edited since.
    pub fn edited(self: Seen) bool {
        return switch (self) {
            .moved => true,
            .absent, .same => false,
        };
    }
};

/// **The one comparison of a recorded hash with a chain's**, which
/// `applyRecorded`, `drift` and the tool's `status` each wrote by hand. A
/// version is in the ledger or it is not; if it is, the hashes are equal or
/// the file was edited.
pub fn seen(recorded: []const Recorded, number: i64, hash: []const u8) Seen {
    const row = findVersion(recorded, number) orelse return .absent;
    if (std.mem.eql(u8, row.hash, hash)) return .same;
    return .{ .moved = row.hash };
}

/// The highest version the ledger records, or zero: `headVersion`, of a ledger
/// already read.
pub fn headOfLedger(recorded: []const Recorded) i64 {
    var top: i64 = 0;
    for (recorded) |r| top = @max(top, r.version);
    return top;
}

fn findVersion(recorded: []const Recorded, number: i64) ?Recorded {
    for (recorded) |r| {
        if (r.version == number) return r;
    }
    return null;
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
    return driftIn(scope.arena(), try readLedger(db, scope), chain);
}

/// `drift` over a ledger already read, so `db migrate` asks the database
/// once for what `drift` and `applyRecorded` both need.
pub fn driftIn(arena: std.mem.Allocator, recorded: []const Recorded, chain: Chain) ![]const Drift {
    var found: std.ArrayList(Drift) = .empty;
    for (chain.versions, chain.hashes) |v, hash| {
        const then = switch (seen(recorded, v.number, hash)) {
            .absent, .same => continue,
            .moved => |was| was,
        };
        try found.append(arena, .{
            .version = v.number,
            .name = v.name,
            .recorded = then,
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
    return snapshotOf(gpa, D, 1, comptime desiredOf(D, .{ .tables = Rows }));
}

test "a schema that has never been generated is one CREATE TABLE per Row" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tables = comptime desiredOf(Pg, .{ .tables = &.{ User, Org } });
    const change = try plan(a, Pg, tables, snapshot.empty(Pg));

    try testing.expectEqual(@as(usize, 0), change.problems.len);
    // orgs, users, then the two indexes users declares.
    try testing.expectEqual(@as(usize, 4), change.steps.len);
    try testing.expectEqual(Kind.create_table, change.steps[0].kind);
    try testing.expectEqual(Kind.create_table, change.steps[1].kind);
    try testing.expectEqual(Kind.create_index, change.steps[2].kind);
    try testing.expect(!change.destructive());
}

/// The table this program reads and does not build: a `Staff` that exists so
/// that `.references` can point at it, on a schema another tool owns
/// (ADR 130).
const Staff = struct {
    pub const nilo_table = .{ .name = "staff", .key = .id, .managed = false };
    id: i64,
    name: []const u8,
};

const Comment = struct {
    pub const nilo_table = .{
        .name = "comments",
        .key = .id,
        .references = .{ .author_staff_id = .{ Staff, .id } },
    };

    id: i64,
    author_staff_id: i64,
    body: []const u8,
};

test "a table this program only reads is never created, and the one pointing at it is" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tables = comptime desiredOf(Pg, .{ .tables = &.{ Comment, Staff } });
    const change = try plan(a, Pg, tables, snapshot.empty(Pg));

    try testing.expectEqual(@as(usize, 0), change.problems.len);
    // One table, not two: `comments` is this program's and `staff` is not.
    // Before this, declaring `Staff` at all meant a `CREATE TABLE staff` for
    // a table that had been there for a year.
    try testing.expectEqual(@as(usize, 1), change.steps.len);
    try testing.expectEqual(Kind.create_table, change.steps[0].kind);
    try testing.expect(std.mem.indexOf(u8, change.steps[0].sql, "comments") != null);

    // And the foreign key onto it is still written, which is the whole reason
    // the Row has to exist.
    try testing.expect(std.mem.indexOf(u8, change.steps[0].sql, "staff") != null);
}

// ---- the schema-level objects (ADR 181) ----

const touch_v1 = "CREATE OR REPLACE FUNCTION set_updated_at() RETURNS trigger AS $$ BEGIN NEW.updated_at = now(); RETURN NEW; END $$ LANGUAGE plpgsql";
const touch_v2 = "CREATE OR REPLACE FUNCTION set_updated_at() RETURNS trigger AS $$ BEGIN NEW.updated_at = clock_timestamp(); RETURN NEW; END $$ LANGUAGE plpgsql";

const full_v1: Schema = .{
    .extensions = &.{"pgcrypto"},
    .functions = &.{.{ .name = "set_updated_at", .body = touch_v1 }},
    .tables = &.{ User, Org },
    .views = &.{
        .{ .name = "org_names", .body = "SELECT id, name FROM orgs" },
        .{ .name = "user_emails", .body = "SELECT id, email FROM users" },
    },
};

test "a schema's extensions, functions and views are planned around the tables in the order the tool owns" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const change = try plan(a, Pg, comptime desiredOf(Pg, full_v1), snapshot.empty(Pg));
    try testing.expectEqual(@as(usize, 0), change.problems.len);

    // Extension, function, the two tables in reference order with the
    // unique and the index, then the views — nothing the caller wrote
    // decided that.
    const kinds = [_]Kind{ .create_extension, .create_function, .create_table, .create_table, .create_index, .create_index, .create_view, .create_view };
    try testing.expectEqual(kinds.len, change.steps.len);
    for (kinds, change.steps) |want, step| try testing.expectEqual(want, step.kind);
    try testing.expectEqualStrings("CREATE EXTENSION IF NOT EXISTS \"pgcrypto\"", change.steps[0].sql);
    try testing.expectEqualStrings(touch_v1, change.steps[1].sql);
    try testing.expectEqualStrings("CREATE VIEW \"org_names\" AS SELECT id, name FROM orgs", change.steps[6].sql);
    try testing.expect(!change.destructive());
}

test "a view whose text moved is dropped before any table moves and remade after, and a function's is one replace" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const before = try snapshotOf(a, Pg, 1, comptime desiredOf(Pg, full_v1));
    const moved: Schema = .{
        .extensions = full_v1.extensions,
        .functions = &.{.{ .name = "set_updated_at", .body = touch_v2 }},
        .tables = &.{ User, Org },
        .views = &.{
            .{ .name = "org_names", .body = "SELECT id, name FROM orgs" },
            .{ .name = "user_emails", .body = "SELECT id, email, nickname FROM users" },
        },
    };
    const change = try plan(a, Pg, comptime desiredOf(Pg, moved), before);
    try testing.expectEqual(@as(usize, 0), change.problems.len);

    // The unchanged extension and view plan nothing; the moved view is a
    // drop first and a create last, and the moved function is one step.
    try testing.expectEqual(@as(usize, 3), change.steps.len);
    try testing.expectEqual(Kind.drop_view, change.steps[0].kind);
    try testing.expectEqualStrings("DROP VIEW IF EXISTS \"user_emails\"", change.steps[0].sql);
    try testing.expectEqual(Kind.create_function, change.steps[1].kind);
    try testing.expectEqualStrings(touch_v2, change.steps[1].sql);
    try testing.expectEqual(Kind.create_view, change.steps[2].kind);
    try testing.expect(std.mem.indexOf(u8, change.steps[2].sql, "nickname") != null);
    try testing.expect(!change.destructive());
}

test "a function or an extension that left the schema is dropped after everything else, and only the extension is destructive" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const before = try snapshotOf(a, Pg, 1, comptime desiredOf(Pg, full_v1));
    const change = try plan(a, Pg, comptime desiredOf(Pg, .{ .tables = &.{ User, Org } }), before);

    try testing.expectEqual(@as(usize, 4), change.steps.len);
    try testing.expectEqual(Kind.drop_view, change.steps[0].kind);
    try testing.expectEqual(Kind.drop_view, change.steps[1].kind);
    try testing.expectEqual(Kind.drop_function, change.steps[2].kind);
    try testing.expectEqualStrings("DROP FUNCTION IF EXISTS \"set_updated_at\"", change.steps[2].sql);
    try testing.expect(!change.steps[2].destructive);
    try testing.expectEqual(Kind.drop_extension, change.steps[3].kind);
    try testing.expectEqualStrings("DROP EXTENSION IF EXISTS \"pgcrypto\"", change.steps[3].sql);
    try testing.expect(change.steps[3].destructive);
    try testing.expect(change.destructive());
}

test "a schema that has not moved plans nothing, functions and views included" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const before = try snapshotOf(a, Pg, 1, comptime desiredOf(Pg, full_v1));
    const change = try plan(a, Pg, comptime desiredOf(Pg, full_v1), before);
    try testing.expect(change.isEmpty());
}

test "createMissing's statements go extensions, functions, tables, views, and a view on SQLite is IF NOT EXISTS" {
    const leading = comptime leadingOf(Pg, full_v1);
    try testing.expectEqual(@as(usize, 2), leading.len);
    try testing.expectEqualStrings("CREATE EXTENSION IF NOT EXISTS \"pgcrypto\"", leading[0]);
    try testing.expectEqualStrings(touch_v1, leading[1]);

    const trailing = comptime trailingOf(Pg, full_v1);
    try testing.expectEqual(@as(usize, 2), trailing.len);
    try testing.expectEqualStrings("CREATE OR REPLACE VIEW \"org_names\" AS SELECT id, name FROM orgs", trailing[0]);

    const lite = comptime trailingOf(Lite, .{
        .tables = &.{Org},
        .views = &.{.{ .name = "org_names", .body = "  SELECT id, name FROM orgs\n" }},
    });
    try testing.expectEqualStrings("CREATE VIEW IF NOT EXISTS \"org_names\" AS SELECT id, name FROM orgs", lite[0]);
}

test "a table this program only reads is not created by createMissing either" {
    // The other call that would have made it, `IF NOT EXISTS` and all.
    const missing = comptime missingOf(Pg, .{ .tables = &.{ Comment, Staff } });
    try testing.expectEqual(@as(usize, 1), missing.len);
    try testing.expect(std.mem.indexOf(u8, missing[0].table, "comments") != null);
}

// -- the words that live inside one Row (ADR 181) ------------------------

const Level = enum { low, high };
const WiderLevel = enum { low, mid, high };

const Ticket = struct {
    pub const nilo_table = .{
        .name = "tickets",
        .key = .id,
        .default = .{ .level = .low },
        .index = .{.{ .columns = .{.closed_at}, .where = .{ .closed_at = null } }},
    };
    id: i64,
    level: Level,
    note: []const u8,
    closed_at: ?types.Timestamp,
};

const WiderTicket = struct {
    pub const nilo_table = .{
        .name = "tickets",
        .key = .id,
        .default = .{ .level = .high, .note = "none" },
        .index = .{.{ .columns = .{.closed_at}, .where = .{ .closed_at = .{ .ne = null } } }},
    };
    id: i64,
    level: WiderLevel,
    note: []const u8,
    closed_at: ?types.Timestamp,
};

test "a changed default and a changed set of words are three statements, not a rebuild" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const before = try snapshotFrom(a, Pg, &.{Ticket});
    const change = try plan(a, Pg, comptime desiredOf(Pg, .{ .tables = &.{WiderTicket} }), before);

    try testing.expectEqual(@as(usize, 0), change.problems.len);
    // level's default, level's words dropped and made again, note's default,
    // then the index whose predicate turned over.
    try testing.expectEqual(@as(usize, 6), change.steps.len);
    try testing.expectEqual(Kind.change_default, change.steps[0].kind);
    try testing.expect(std.mem.indexOf(u8, change.steps[0].sql, "SET DEFAULT 'high'") != null);
    try testing.expectEqual(Kind.drop_check, change.steps[1].kind);
    try testing.expectEqual(Kind.create_check, change.steps[2].kind);
    try testing.expect(std.mem.indexOf(u8, change.steps[2].sql, "'mid'") != null);
    try testing.expectEqual(Kind.change_default, change.steps[3].kind);

    // Nothing here loses data, and nothing needs a backfill: every word the
    // old type had, the new one still has.
    try testing.expect(!change.destructive());
    try testing.expect(!change.needsBackfill());
}

test "an index whose predicate turned over is dropped and made again" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const before = try snapshotFrom(a, Pg, &.{Ticket});
    const change = try plan(a, Pg, comptime desiredOf(Pg, .{ .tables = &.{WiderTicket} }), before);

    // The name is the same, so the pair is a drop and a create rather than
    // two indexes: neither database alters one in place.
    const dropped = change.steps[4];
    const made = change.steps[5];
    try testing.expectEqual(Kind.drop_index, dropped.kind);
    try testing.expectEqual(Kind.create_index, made.kind);
    try testing.expect(std.mem.indexOf(u8, made.sql, "WHERE \"closed_at\" IS NOT NULL") != null);
}

test "a word taken off an enum is a backfill, because the rows holding it are there" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The other direction: what was three words is two, and the rows written
    // with the third are already in the table. The new constraint refuses
    // them, so the statement fails rather than removing anything — which is a
    // backfill to write beside it, not data loss.
    const before = try snapshotFrom(a, Pg, &.{WiderTicket});
    const change = try plan(a, Pg, comptime desiredOf(Pg, .{ .tables = &.{Ticket} }), before);

    try testing.expectEqual(@as(usize, 0), change.problems.len);
    try testing.expect(change.needsBackfill());
    try testing.expect(!change.destructive());
}

test "SQLite names everything that moved on one column, in one Problem" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const before = try snapshotFrom(a, Lite, &.{Ticket});
    const change = try plan(a, Lite, comptime desiredOf(Lite, .{ .tables = &.{WiderTicket} }), before);

    // One Problem for `level` and one for `note`, and none of the column's
    // three changes becomes a Problem of its own: the answer to all of them
    // is the same rebuild, so two would read as two jobs.
    try testing.expectEqual(@as(usize, 2), change.problems.len);
    try testing.expectEqualStrings("level", change.problems[0].column);
    const text = change.problems[0].text;
    try testing.expect(std.mem.indexOf(u8, text, "it defaults to 'high'") != null);
    try testing.expect(std.mem.indexOf(u8, text, "the words it may hold are 3 and were 2") != null);
    try testing.expect(std.mem.indexOf(u8, text, "cannot change a column in place") != null);

    // And no half-done plan beside them: the index is still diffed, because
    // an index is dropped and made again on both databases.
    for (change.steps) |s| try testing.expect(s.kind == .drop_index or s.kind == .create_index);
}

const Plain = struct {
    pub const nilo_table = .{ .name = "notes", .key = .id };
    id: i64,
    body: []const u8,
};

const PlainWithCount = struct {
    pub const nilo_table = .{ .name = "notes", .key = .id, .default = .{ .views = 0 } };
    id: i64,
    body: []const u8,
    views: i64,
};

test "a required column added with a default fills the rows that are there, so it is no backfill" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const before = try snapshotFrom(a, Pg, &.{Plain});
    const change = try plan(a, Pg, comptime desiredOf(Pg, .{ .tables = &.{PlainWithCount} }), before);

    try testing.expectEqual(@as(usize, 1), change.steps.len);
    try testing.expectEqual(Kind.add_column, change.steps[0].kind);
    try testing.expect(std.mem.indexOf(u8, change.steps[0].sql, "DEFAULT 0") != null);
    // The case ADR 123 named as the one where a default is load-bearing,
    // answered by the word rather than by a warning.
    try testing.expect(!change.needsBackfill());
}

test "the same column with no default is still the loud one" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Bare = struct {
        pub const nilo_table = .{ .name = "notes", .key = .id };
        id: i64,
        body: []const u8,
        views: i64,
    };
    const before = try snapshotFrom(a, Pg, &.{Plain});
    const change = try plan(a, Pg, comptime desiredOf(Pg, .{ .tables = &.{Bare} }), before);

    try testing.expectEqual(@as(usize, 1), change.steps.len);
    try testing.expect(change.needsBackfill());
}

test "a table this program only reads is not dropped for not being described" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The snapshot has both, which is what `generate` writes: an external
    // table is recorded rather than forgotten, so that a program which starts
    // building one is a visible line in the file.
    const before = try snapshotFrom(a, Pg, &.{ Comment, Staff });
    try testing.expectEqual(@as(usize, 2), before.tables.len);
    for (before.tables) |t| {
        if (std.mem.eql(u8, t.table, "staff")) try testing.expect(!t.managed);
        if (std.mem.eql(u8, t.table, "comments")) try testing.expect(t.managed);
    }

    // Nothing to do, and in particular no `DROP TABLE staff` — the drop loop
    // reads the same desired list, so a table that is merely unmanaged still
    // counts as described.
    const change = try plan(a, Pg, comptime desiredOf(Pg, .{ .tables = &.{ Comment, Staff } }), before);
    try testing.expectEqual(@as(usize, 0), change.steps.len);
    try testing.expectEqual(@as(usize, 0), change.problems.len);
}

test "a table is created after the tables it points at, and the order is a constant" {
    // `User` is written first and `Org` second, and the plan reverses them,
    // because Postgres checks that `orgs` is there when `users` names it.
    const tables = comptime tablesOf(Pg, .{ .tables = &.{ User, Org } });
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
    const tables = comptime tablesOf(Pg, .{ .tables = &.{Node} });
    try testing.expectEqualStrings("nodes", tables[0].desc.table);
}

test "a schema that has not moved plans nothing at all" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const before = try snapshotFrom(a, Pg, &.{ Org, User });
    const change = try plan(a, Pg, comptime desiredOf(Pg, .{ .tables = &.{ Org, User } }), before);

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
    const change = try plan(a, Pg, comptime desiredOf(Pg, .{ .tables = &.{After} }), before);

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
    const change = try plan(a, Pg, comptime desiredOf(Pg, .{ .tables = &.{After} }), before);

    try testing.expectEqual(@as(usize, 1), change.steps.len);
    try testing.expectEqual(Kind.drop_column, change.steps[0].kind);
    try testing.expect(change.steps[0].destructive);
    try testing.expect(change.destructive());
}

test "a dropped column is named by its table and column, and a dropped table by its name" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Wide = struct {
        pub const nilo_table = .{ .name = "orgs", .key = .id };
        id: i64,
        note: ?[]const u8,
    };
    const Gone = struct {
        pub const nilo_table = .{ .name = "notes", .key = .id };
        id: i64,
    };
    const Narrow = struct {
        pub const nilo_table = .{ .name = "orgs", .key = .id };
        id: i64,
    };

    const before = try snapshotFrom(a, Pg, &.{ Wide, Gone });
    const change = try plan(a, Pg, comptime desiredOf(Pg, .{ .tables = &.{Narrow} }), before);

    // What `--drop` takes, and what a held version prints for it to take.
    const unnamed = try change.unnamed(a, &.{});
    try testing.expectEqual(@as(usize, 2), unnamed.len);
    try testing.expectEqualStrings("orgs.note", unnamed[0]);
    try testing.expectEqualStrings("notes", unnamed[1]);
    try testing.expectEqual(@as(usize, 0), (try change.unnamed(a, &.{ "notes", "orgs.note" })).len);
    // A name for something this plan does not drop is its own answer.
    const stray = try change.stray(a, &.{ "orgs.note", "orgs.nte" });
    try testing.expectEqual(@as(usize, 1), stray.len);
    try testing.expectEqualStrings("orgs.nte", stray[0]);
}

test "an index on a dropped column is dropped before the column is" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Before = struct {
        pub const nilo_table = .{
            .name = "orgs",
            .key = .id,
            .unique = .{.{ .columns = .{.slug} }},
            .index = .{.region},
        };
        id: i64,
        slug: []const u8,
        region: []const u8,
    };
    const After = struct {
        pub const nilo_table = .{ .name = "orgs", .key = .id };
        id: i64,
    };

    const before = try snapshotFrom(a, Pg, &.{Before});
    const change = try plan(a, Pg, comptime desiredOf(Pg, .{ .tables = &.{After} }), before);

    // Postgres drops a column's indexes with it, so a `DROP INDEX` after the
    // column named an index that was gone and failed the whole version; and
    // SQLite will not drop an indexed column at all.
    var first_column: ?usize = null;
    var last_index: usize = 0;
    for (change.steps, 0..) |s, i| switch (s.kind) {
        .drop_column => {
            if (first_column == null) first_column = i;
        },
        .drop_index => last_index = i,
        else => {},
    };
    try testing.expect(first_column != null);
    try testing.expect(last_index < first_column.?);
}

test "a type that widens goes through, and one that may not fit has to be named" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Before = struct {
        pub const nilo_table = .{ .name = "readings", .key = .id };
        id: i64,
        count: i32,
        total: i64,
        ratio: f64,
    };
    const After = struct {
        pub const nilo_table = .{ .name = "readings", .key = .id };
        id: i64,
        count: i64, // wider: every int4 is an int8
        total: i32, // narrower: a row over two billion is refused
        ratio: f32, // narrower: every row loses digits, quietly
    };

    const before = try snapshotFrom(a, Pg, &.{Before});
    const change = try plan(a, Pg, comptime desiredOf(Pg, .{ .tables = &.{After} }), before);

    try testing.expectEqual(@as(usize, 3), change.steps.len);
    for (change.steps) |s| try testing.expectEqual(Kind.change_type, s.kind);
    try testing.expect(!change.steps[0].destructive);
    try testing.expectEqualStrings("", change.steps[0].target);
    try testing.expect(change.steps[1].destructive);
    try testing.expectEqualStrings("readings.total", change.steps[1].target);
    try testing.expect(change.steps[2].destructive);
    try testing.expectEqualStrings("readings.ratio", change.steps[2].target);
}

test "widening is a short list, and everything off it is a loss" {
    try testing.expect(widens("int2", "int4"));
    try testing.expect(widens("int4", "int8"));
    try testing.expect(widens("int8", "numeric"));
    try testing.expect(widens("float4", "float8"));
    try testing.expect(widens("varchar(20)", "text"));
    try testing.expect(widens("varchar(20)", "varchar(40)"));
    try testing.expect(widens("numeric(10,2)", "numeric(12,2)"));
    try testing.expect(widens("numeric(10,2)", "numeric"));

    try testing.expect(!widens("int8", "int4"));
    try testing.expect(!widens("float8", "float4"));
    try testing.expect(!widens("int8", "float8")); // past 2^53 it rounds
    try testing.expect(!widens("text", "varchar(40)"));
    try testing.expect(!widens("varchar(40)", "varchar(20)"));
    try testing.expect(!widens("numeric(10,2)", "numeric(10,1)")); // rounds every row
    try testing.expect(!widens("numeric(10,2)", "numeric(10,3)")); // one digit less before the point
    try testing.expect(!widens("int8", "numeric(10,0)"));
    try testing.expect(!widens("timestamptz", "timestamp"));
    try testing.expect(!widens("text", "int8"));
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
    const change = try plan(a, Pg, comptime desiredOf(Pg, .{ .tables = &.{After} }), before);

    // One statement, not two. Without `.was` this is a drop and an add.
    try testing.expectEqual(@as(usize, 1), change.steps.len);
    try testing.expectEqual(Kind.rename_column, change.steps[0].kind);
    try testing.expectEqualStrings(
        "ALTER TABLE \"orgs\" RENAME COLUMN \"e_mail\" TO \"email\"",
        change.steps[0].sql,
    );
    try testing.expect(!change.destructive());
}

const Written = struct {
    pub const nilo_table = .{
        .name = "posts",
        .key = .id,
        .references = .{ .author_id = .{ Org, .id } },
        .unique = .{.slug},
        .index = .{.author_id},
    };
    id: i64,
    author_id: i64,
    slug: []const u8,
};

const Rewritten = struct {
    pub const nilo_table = .{
        .name = "posts",
        .key = .id,
        .was = .{ .writer_id = "author_id", .handle = "slug" },
        .references = .{ .writer_id = .{ Org, .id } },
        .unique = .{.handle},
        .index = .{.writer_id},
    };
    id: i64,
    writer_id: i64,
    handle: []const u8,
};

test "a column `.was` renamed takes its index and its foreign key with it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Postgres: two column renames and three renames of what they carried.
    // The foreign key was refused as a new one, and the index and the unique
    // were dropped and built again under a lock.
    const pg = try plan(a, Pg, comptime desiredOf(Pg, .{ .tables = &.{ Org, Rewritten } }), try snapshotFrom(a, Pg, &.{ Org, Written }));
    try testing.expectEqual(@as(usize, 0), pg.problems.len);
    const kinds = [_]Kind{ .rename_column, .rename_column, .rename_index, .rename_index, .rename_constraint };
    try testing.expectEqual(kinds.len, pg.steps.len);
    for (kinds, pg.steps) |want, step| try testing.expectEqual(want, step.kind);
    try testing.expectEqualStrings("ALTER INDEX \"posts_slug_key\" RENAME TO \"posts_handle_key\"", pg.steps[2].sql);
    try testing.expectEqualStrings("ALTER INDEX \"posts_author_id_idx\" RENAME TO \"posts_writer_id_idx\"", pg.steps[3].sql);
    try testing.expectEqualStrings(
        "ALTER TABLE \"posts\" RENAME CONSTRAINT \"posts_author_id_fkey\" TO \"posts_writer_id_fkey\"",
        pg.steps[4].sql,
    );

    // SQLite renames no index, so each is a drop and a create, and a foreign
    // key it never drops by name needs nothing.
    const lite = try plan(a, Lite, comptime desiredOf(Lite, .{ .tables = &.{ Org, Rewritten } }), try snapshotFrom(a, Lite, &.{ Org, Written }));
    try testing.expectEqual(@as(usize, 0), lite.problems.len);
    const lite_kinds = [_]Kind{ .rename_column, .rename_column, .drop_index, .drop_index, .create_index, .create_index };
    try testing.expectEqual(lite_kinds.len, lite.steps.len);
    for (lite_kinds, lite.steps) |want, step| try testing.expectEqual(want, step.kind);
}

const Mood = enum { calm, cross, glad };
const MoodTurned = enum { glad, calm, cross };

test "an enum whose tags only moved is no change, and a text column becoming one is a backfill" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Before = struct {
        pub const nilo_table = .{ .name = "moods", .key = .id };
        id: i64,
        mood: Mood,
    };
    const Turned = struct {
        pub const nilo_table = .{ .name = "moods", .key = .id };
        id: i64,
        mood: MoodTurned,
    };
    const Text = struct {
        pub const nilo_table = .{ .name = "moods", .key = .id };
        id: i64,
        mood: []const u8,
    };

    // A drop and an add of the check was a scan under ACCESS EXCLUSIVE on
    // Postgres and a rebuild Problem on SQLite, for nothing.
    try testing.expect((try plan(a, Pg, comptime desiredOf(Pg, .{ .tables = &.{Turned} }), try snapshotFrom(a, Pg, &.{Before}))).isEmpty());
    const lite = try plan(a, Lite, comptime desiredOf(Lite, .{ .tables = &.{Turned} }), try snapshotFrom(a, Lite, &.{Before}));
    try testing.expect(lite.isEmpty());
    try testing.expectEqual(@as(usize, 0), lite.problems.len);

    // Any text a row holds that is not one of the three fails the new check.
    const tightened = try plan(a, Pg, comptime desiredOf(Pg, .{ .tables = &.{Before} }), try snapshotFrom(a, Pg, &.{Text}));
    try testing.expectEqual(Kind.create_check, tightened.steps[tightened.steps.len - 1].kind);
    try testing.expect(tightened.steps[tightened.steps.len - 1].needs_backfill);
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
    const change = try plan(a, Pg, comptime desiredOf(Pg, .{ .tables = &.{After} }), before);
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
    const pg = try plan(a, Pg, comptime desiredOf(Pg, .{ .tables = &.{After} }), pg_before);
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
    const lite = try plan(a, Lite, comptime desiredOf(Lite, .{ .tables = &.{Wide} }), lite_before);
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
    const tightened = try plan(a, Pg, comptime desiredOf(Pg, .{ .tables = &.{Tight} }), before);
    try testing.expectEqual(@as(usize, 1), tightened.steps.len);
    try testing.expectEqual(Kind.change_null, tightened.steps[0].kind);
    try testing.expect(tightened.steps[0].needs_backfill);
    try testing.expect(tightened.needsBackfill());

    const after = try snapshotFrom(a, Pg, &.{Tight});
    const loosened = try plan(a, Pg, comptime desiredOf(Pg, .{ .tables = &.{Loose} }), after);
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
    const change = try plan(a, Pg, comptime desiredOf(Pg, .{ .tables = &.{After} }), before);

    // The old one goes first, with every index that is going: they go before
    // the columns, and a column that went could have been under this one.
    // One transaction either way, so nobody sees the table with neither.
    try testing.expectEqual(@as(usize, 2), change.steps.len);
    try testing.expectEqual(Kind.drop_index, change.steps[0].kind);
    try testing.expectEqualStrings("DROP INDEX \"orgs_name_idx\"", change.steps[0].sql);
    try testing.expectEqual(Kind.create_index, change.steps[1].kind);
    try testing.expect(std.mem.indexOf(u8, change.steps[1].sql, "orgs_name_at_idx") != null);
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
    const change = try plan(a, Pg, comptime desiredOf(Pg, .{ .tables = &.{After} }), before);

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
    const change = try plan(a, Pg, comptime desiredOf(Pg, .{ .tables = &.{ Org, After } }), before);

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
    const change = try plan(a, Pg, comptime desiredOf(Pg, .{ .tables = &.{Org} }), before);

    try testing.expectEqual(@as(usize, 1), change.steps.len);
    try testing.expectEqual(Kind.drop_table, change.steps[0].kind);
    try testing.expectEqualStrings("DROP TABLE \"users\"", change.steps[0].sql);
    try testing.expect(change.destructive());
}

test "two tables dropped in one change go child first, so neither needs a CASCADE" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const before = try snapshotFrom(a, Pg, &.{ Org, User });
    const change = try plan(a, Pg, comptime desiredOf(Pg, .{ .tables = &.{} }), before);

    try testing.expectEqual(@as(usize, 2), change.steps.len);
    try testing.expectEqualStrings("DROP TABLE \"users\"", change.steps[0].sql);
    try testing.expectEqualStrings("DROP TABLE \"orgs\"", change.steps[1].sql);
}

const Noted = struct {
    pub const nilo_table = .{
        .name = "notes",
        .key = .id,
        .check = .{ .notes_note_is_said = "note <> ''" },
        .trigger = .{
            .notes_touch = .{
                .when = "BEFORE UPDATE OF note",
                .run = "FOR EACH ROW EXECUTE FUNCTION set_updated_at()",
            },
        },
    };
    id: i64,
    note: ?[]const u8,
};

const Unnoted = struct {
    pub const nilo_table = .{ .name = "notes", .key = .id };
    id: i64,
};

test "a check and a trigger over a column that goes are dropped before the column is" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const before = try snapshotFrom(a, Pg, &.{Noted});
    const change = try plan(a, Pg, comptime desiredOf(Pg, .{ .tables = &.{Unnoted} }), before);

    // A `DROP CONSTRAINT` after the column named a check Postgres had
    // already dropped with it, and the trigger refused the column's drop.
    const kinds = [_]Kind{ .drop_check, .drop_trigger, .drop_column };
    try testing.expectEqual(kinds.len, change.steps.len);
    for (kinds, change.steps) |want, step| try testing.expectEqual(want, step.kind);
}

const Counter = struct {
    pub const nilo_table = .{ .name = "counters", .key = .id };
    id: i64,
    count: i32,
};

const CounterWide = struct {
    pub const nilo_table = .{ .name = "counters", .key = .id };
    id: i64,
    count: i64,
};

/// Listed with the view that reads the other first, which is what the
/// Schema's "order inside a list does not matter" allows.
const counted_views = [_]Schema.Text{
    .{ .name = "top_counts", .body = "SELECT * FROM count_list WHERE count > 10" },
    .{ .name = "count_list", .body = "SELECT id, \"count\" FROM counters" },
    .{ .name = "constants", .body = "SELECT 1 AS one" },
};

test "a view is created after the view it reads, whatever order the list has" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const schema: Schema = .{ .tables = &.{Counter}, .views = &counted_views };
    const change = try plan(a, Pg, comptime desiredOf(Pg, schema), snapshot.empty(Pg));
    try testing.expectEqual(@as(usize, 4), change.steps.len);
    try testing.expectEqualStrings("view count_list", change.steps[1].why);
    try testing.expectEqualStrings("view top_counts", change.steps[2].why);
    try testing.expectEqualStrings("view constants", change.steps[3].why);

    // `createMissing` sends them in the same order.
    const trailing = comptime trailingOf(Pg, schema);
    try testing.expect(std.mem.indexOf(u8, trailing[0], "\"count_list\"") != null);
    try testing.expect(std.mem.indexOf(u8, trailing[1], "\"top_counts\"") != null);
}

test "a view over a column whose type changes comes down before it and goes back up after, and so does a view reading it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const before = try snapshotOf(a, Pg, 1, comptime desiredOf(Pg, .{ .tables = &.{Counter}, .views = &counted_views }));
    const change = try plan(a, Pg, comptime desiredOf(Pg, .{ .tables = &.{CounterWide}, .views = &counted_views }), before);
    try testing.expectEqual(@as(usize, 0), change.problems.len);

    // Neither view's text moved, and Postgres refuses the `ALTER … TYPE`
    // while either stands. The view that reads nothing stays up.
    const kinds = [_]Kind{ .drop_view, .drop_view, .change_type, .create_view, .create_view };
    try testing.expectEqual(kinds.len, change.steps.len);
    for (kinds, change.steps) |want, step| try testing.expectEqual(want, step.kind);
    try testing.expectEqualStrings("DROP VIEW IF EXISTS \"top_counts\"", change.steps[0].sql);
    try testing.expectEqualStrings("DROP VIEW IF EXISTS \"count_list\"", change.steps[1].sql);
    try testing.expectEqualStrings("view count_list", change.steps[3].why);
    try testing.expectEqualStrings("view top_counts", change.steps[4].why);
}

test "a view names a table only as a whole word" {
    try testing.expect(mentions("SELECT * FROM counters", "counters"));
    try testing.expect(mentions("SELECT * FROM \"Counters\" c", "counters"));
    try testing.expect(mentions("SELECT * FROM billing.counters", "counters"));
    try testing.expect(!mentions("SELECT * FROM counters_old", "counters"));
    try testing.expect(!mentions("SELECT recounters FROM x", "counters"));
    try testing.expect(!mentions("SELECT 1", ""));
}

const Stamped = struct {
    pub const nilo_table = .{ .name = "stamps", .key = .id, .default = .{ .at = .now } };
    id: i64,
    at: types.Timestamp,
};

const Unstamped = struct {
    pub const nilo_table = .{ .name = "stamps", .key = .id };
    id: i64,
};

test "a column added with `.now` on SQLite is a Problem, since a table with rows refuses it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const lite = try plan(a, Lite, comptime desiredOf(Lite, .{ .tables = &.{Stamped} }), try snapshotFrom(a, Lite, &.{Unstamped}));
    try testing.expectEqual(@as(usize, 0), lite.steps.len);
    try testing.expectEqual(@as(usize, 1), lite.problems.len);
    try testing.expectEqualStrings("at", lite.problems[0].column);
    try testing.expect(std.mem.indexOf(u8, lite.problems[0].text, "only to a table with no rows") != null);

    // Postgres takes `now()` on a table with rows, and a new table takes it
    // on SQLite too.
    const pg = try plan(a, Pg, comptime desiredOf(Pg, .{ .tables = &.{Stamped} }), try snapshotFrom(a, Pg, &.{Unstamped}));
    try testing.expectEqual(@as(usize, 0), pg.problems.len);
    try testing.expectEqual(Kind.add_column, pg.steps[0].kind);
    const fresh = try plan(a, Lite, comptime desiredOf(Lite, .{ .tables = &.{Stamped} }), snapshot.empty(Lite));
    try testing.expectEqual(@as(usize, 0), fresh.problems.len);
}

test "a version rebuilds when a step drops a table, and not otherwise" {
    try testing.expect(rebuilds(&.{.{ .kind = .data, .why = "", .sql = "drop  table \"parents\"" }}));
    try testing.expect(rebuilds(&.{
        .{ .kind = .data, .why = "", .sql = "INSERT INTO a SELECT * FROM b" },
        .{ .kind = .drop_table, .why = "", .sql = "DROP TABLE \"b\"" },
    }));
    try testing.expect(!rebuilds(&.{.{ .kind = .data, .why = "", .sql = "DELETE FROM \"parents\" WHERE id = 1" }}));
    try testing.expect(!rebuilds(&.{.{ .kind = .drop_index, .why = "", .sql = "DROP INDEX \"tables_x\"" }}));
}

test "a snapshot from the other dialect is one sentence, not a schema rewritten" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const before = try snapshotFrom(a, Lite, &.{Org});
    const change = try plan(a, Pg, comptime desiredOf(Pg, .{ .tables = &.{Org} }), before);

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
    try testing.expectEqual(@as(usize, 1), desc.keys.len);
    try testing.expectEqualStrings("version", desc.keys[0]);
    try testing.expect(desc.column("version").?.key);

    // And its DDL is a constant like any other table's.
    const sql = comptime ddl.createTable(Pg, Applied);
    try testing.expect(std.mem.indexOf(u8, sql, "\"hash\" text NOT NULL") != null);
    try testing.expect(std.mem.indexOf(u8, sql, "\"applied_at\" timestamptz NOT NULL") != null);
    try testing.expect(std.mem.indexOf(u8, comptime ddl.createTable(Lite, Applied), "INTEGER PRIMARY KEY") != null);
}

// -- the second kind of word (ADR 181) ----------------------------------

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

const LedgerMoved = struct {
    pub const nilo_table = .{
        .name = "ledgers",
        .key = .id,
        // The same name, a different body — which is the one case the hash is
        // here to notice.
        .check = .{ .ledgers_amount_is_positive = "amount >= 0" },
        .trigger = .{
            .ledgers_touch = .{
                .when = "AFTER UPDATE",
                .run = "FOR EACH ROW EXECUTE FUNCTION set_updated_at()",
            },
        },
    };

    id: i64,
    amount: i64,
};

const LedgerBare = struct {
    pub const nilo_table = .{ .name = "ledgers", .key = .id };

    id: i64,
    amount: i64,
};

test "a table with a check and a trigger is created with one inside it and one after it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const change = try plan(a, Pg, comptime desiredOf(Pg, .{ .tables = &.{Ledger} }), snapshot.empty(Pg));

    try testing.expectEqual(@as(usize, 2), change.steps.len);
    try testing.expectEqual(Kind.create_table, change.steps[0].kind);
    // The check rides inside the `CREATE TABLE`, for the reason every other
    // table constraint does: SQLite writes one at creation or never.
    try testing.expect(std.mem.indexOf(
        u8,
        change.steps[0].sql,
        "CONSTRAINT \"ledgers_amount_is_positive\" CHECK (amount > 0)",
    ) != null);
    try testing.expectEqual(Kind.create_trigger, change.steps[1].kind);
    try testing.expectEqualStrings(
        "CREATE TRIGGER \"ledgers_touch\" BEFORE UPDATE ON \"ledgers\" " ++
            "FOR EACH ROW EXECUTE FUNCTION set_updated_at()",
        change.steps[1].sql,
    );
}

test "a check and a trigger that have not moved plan nothing, because the hash is what is compared" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const before = try snapshotFrom(a, Pg, &.{Ledger});
    // What the snapshot actually holds: a name and sixteen hex characters, and
    // no SQL at all.
    const recorded = before.table(null, "ledgers").?;
    try testing.expectEqualStrings("", recorded.checks[0].body);
    try testing.expectEqual(@as(usize, 16), recorded.checks[0].hash.len);
    try testing.expectEqualStrings("", recorded.triggers[0].tail);

    const change = try plan(a, Pg, comptime desiredOf(Pg, .{ .tables = &.{Ledger} }), before);
    try testing.expect(change.isEmpty());
    try testing.expectEqual(@as(usize, 0), change.problems.len);
}

test "a step that holds the whole table while it reads or writes every row says so in its why" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Before = struct {
        pub const nilo_table = .{ .name = "readings", .key = .id };
        id: i64,
        count: i32,
        note: ?[]const u8,
        label: ?[]const u8,
    };
    const After = struct {
        pub const nilo_table = .{
            .name = "readings",
            .key = .id,
            .check = .{ .readings_count_is_positive = "count > 0" },
        };
        id: i64,
        count: i64, // a widening, and still a rewrite
        note: []const u8, // SET NOT NULL reads every row
        label: ?[]const u8, // untouched, so no step
    };

    const before = try snapshotFrom(a, Pg, &.{Before});
    const change = try plan(a, Pg, comptime desiredOf(Pg, .{ .tables = &.{After} }), before);
    try testing.expectEqual(@as(usize, 0), change.problems.len);

    var said: usize = 0;
    for (change.steps) |step| switch (step.kind) {
        .change_type => {
            try testing.expectEqualStrings(
                "readings.count becomes int8, from int4, which writes every row again " ++
                    "while reads and writes to readings wait",
                step.why,
            );
            said += 1;
        },
        .change_null => {
            try testing.expectEqualStrings(
                "readings.note may no longer be null, which reads every row " ++
                    "while reads and writes to readings wait",
                step.why,
            );
            said += 1;
        },
        .create_check => {
            try testing.expectEqualStrings(
                "check readings_count_is_positive, which reads every row " ++
                    "while reads and writes to readings wait",
                step.why,
            );
            said += 1;
        },
        else => {},
    };
    try testing.expectEqual(@as(usize, 3), said);
}

test "a type change is in place only where Postgres touches no row" {
    try testing.expect(inPlace("varchar(20)", "text"));
    try testing.expect(inPlace("varchar(20)", "varchar(40)"));
    try testing.expect(inPlace("numeric(10,2)", "numeric(12,2)"));
    try testing.expect(inPlace("numeric(10,2)", "numeric"));

    try testing.expect(!inPlace("int4", "int8"));
    try testing.expect(!inPlace("float4", "float8"));
    try testing.expect(!inPlace("int8", "numeric"));
    // More digits after the point is a widening, and every value is written
    // again with the new scale.
    try testing.expect(!inPlace("numeric(10,2)", "numeric(12,3)"));
    try testing.expect(!inPlace("varchar(40)", "varchar(20)"));
}

test "a changed body under the same name is one drop and one create, for both kinds" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const before = try snapshotFrom(a, Pg, &.{Ledger});
    const change = try plan(a, Pg, comptime desiredOf(Pg, .{ .tables = &.{LedgerMoved} }), before);

    try testing.expectEqual(@as(usize, 0), change.problems.len);
    try testing.expectEqual(@as(usize, 4), change.steps.len);

    try testing.expectEqual(Kind.drop_check, change.steps[0].kind);
    try testing.expectEqualStrings(
        "ALTER TABLE \"ledgers\" DROP CONSTRAINT \"ledgers_amount_is_positive\"",
        change.steps[0].sql,
    );
    try testing.expectEqual(Kind.create_check, change.steps[1].kind);
    try testing.expectEqualStrings(
        "ALTER TABLE \"ledgers\" ADD CONSTRAINT \"ledgers_amount_is_positive\" " ++
            "CHECK (amount >= 0)",
        change.steps[1].sql,
    );
    // Not a backfill: the constraint was already there, so the rows that are
    // there have been through one already.
    try testing.expect(!change.steps[1].needs_backfill);

    try testing.expectEqual(Kind.drop_trigger, change.steps[2].kind);
    try testing.expectEqualStrings(
        "DROP TRIGGER \"ledgers_touch\" ON \"ledgers\"",
        change.steps[2].sql,
    );
    try testing.expectEqual(Kind.create_trigger, change.steps[3].kind);
    try testing.expect(std.mem.indexOf(u8, change.steps[3].sql, "AFTER UPDATE") != null);
}

/// A table with a trigger on `UPDATE OF count`, and the same table with that
/// column wider. Postgres refuses to retype a column a trigger names, whether
/// or not the trigger moved with it (`dropTriggersNamingRetyped`).
fn Metered(comptime count: type, comptime when: []const u8) type {
    return struct {
        pub const nilo_table = .{
            .name = "meters",
            .key = .id,
            .trigger = .{ .meters_touch = .{
                .when = when,
                .run = "FOR EACH ROW EXECUTE FUNCTION set_updated_at()",
            } },
        };
        id: i64,
        count: count,
        note: ?[]const u8,
    };
}

const MeterNarrow = Metered(i32, "BEFORE UPDATE OF count");
const MeterWide = Metered(i64, "BEFORE UPDATE OF count");
const MeterWideMoved = Metered(i64, "AFTER UPDATE OF count");
const NoteNarrow = Metered(i32, "BEFORE UPDATE OF note");
const NoteWide = Metered(i64, "BEFORE UPDATE OF note");
const MeterWideBare = struct {
    pub const nilo_table = .{ .name = "meters", .key = .id };
    id: i64,
    count: i64,
    note: ?[]const u8,
};

test "a trigger that names a column about to change type comes down before it and is made again after" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const before = try snapshotFrom(a, Pg, &.{MeterNarrow});
    const change = try plan(a, Pg, comptime desiredOf(Pg, .{ .tables = &.{MeterWide} }), before);

    // The trigger has not moved, and Postgres refuses the `ALTER` under it
    // all the same: it comes down, the column changes, it goes back.
    const kinds = [_]Kind{ .drop_trigger, .change_type, .create_trigger };
    try testing.expectEqual(kinds.len, change.steps.len);
    for (kinds, change.steps) |want, step| try testing.expectEqual(want, step.kind);
    try testing.expectEqualStrings("DROP TRIGGER \"meters_touch\" ON \"meters\"", change.steps[0].sql);
    try testing.expect(std.mem.indexOf(u8, change.steps[2].sql, "CREATE TRIGGER \"meters_touch\" BEFORE UPDATE OF count") != null);
}

test "a trigger that names another column is left standing while a column changes type" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const before = try snapshotFrom(a, Pg, &.{NoteNarrow});
    const change = try plan(a, Pg, comptime desiredOf(Pg, .{ .tables = &.{NoteWide} }), before);

    try testing.expectEqual(@as(usize, 1), change.steps.len);
    try testing.expectEqual(Kind.change_type, change.steps[0].kind);
}

test "a trigger that moves while its column changes type is dropped once, before the change, and made once, after" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const before = try snapshotFrom(a, Pg, &.{MeterNarrow});
    const change = try plan(a, Pg, comptime desiredOf(Pg, .{ .tables = &.{MeterWideMoved} }), before);

    // The drop used to follow the `ALTER`, which the old trigger refused.
    const kinds = [_]Kind{ .drop_trigger, .change_type, .create_trigger };
    try testing.expectEqual(kinds.len, change.steps.len);
    for (kinds, change.steps) |want, step| try testing.expectEqual(want, step.kind);
    try testing.expect(std.mem.indexOf(u8, change.steps[2].sql, "AFTER UPDATE OF count") != null);
}

test "a trigger the types dropped comes down before a column changes type, not after" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const before = try snapshotFrom(a, Pg, &.{MeterNarrow});
    const change = try plan(a, Pg, comptime desiredOf(Pg, .{ .tables = &.{MeterWideBare} }), before);

    const kinds = [_]Kind{ .drop_trigger, .change_type };
    try testing.expectEqual(kinds.len, change.steps.len);
    for (kinds, change.steps) |want, step| try testing.expectEqual(want, step.kind);
}

test "a check the types no longer name is dropped, and so is a trigger" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const before = try snapshotFrom(a, Pg, &.{Ledger});
    const change = try plan(a, Pg, comptime desiredOf(Pg, .{ .tables = &.{LedgerBare} }), before);

    try testing.expectEqual(@as(usize, 2), change.steps.len);
    try testing.expectEqual(Kind.drop_check, change.steps[0].kind);
    try testing.expectEqualStrings("drop check ledgers_amount_is_positive", change.steps[0].why);
    try testing.expectEqual(Kind.drop_trigger, change.steps[1].kind);
    try testing.expectEqualStrings("drop trigger ledgers_touch", change.steps[1].why);
}

test "a check added to a table that has rows says so, because the database tests them all" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const before = try snapshotFrom(a, Pg, &.{LedgerBare});
    const change = try plan(a, Pg, comptime desiredOf(Pg, .{ .tables = &.{Ledger} }), before);

    try testing.expectEqual(Kind.create_check, change.steps[0].kind);
    try testing.expect(change.steps[0].needs_backfill);
    try testing.expect(change.needsBackfill());
}

test "SQLite says the four statements for a check, because a table constraint there is the table" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const before = try snapshotFrom(a, Lite, &.{Ledger});
    const change = try plan(a, Lite, comptime desiredOf(Lite, .{ .tables = &.{LedgerMoved} }), before);

    try testing.expectEqual(@as(usize, 1), change.problems.len);
    try testing.expect(std.mem.indexOf(
        u8,
        change.problems[0].text,
        "the check ledgers_amount_is_positive is new or its body changed",
    ) != null);
    // A trigger is not a table constraint, so SQLite does that one as steps.
    try testing.expectEqual(@as(usize, 2), change.steps.len);
    try testing.expectEqualStrings("DROP TRIGGER \"ledgers_touch\"", change.steps[0].sql);
}

const Sku = struct {
    pub const nilo_table = .{ .name = "skus", .key = .id };

    id: i64,
    kind: Level,
};

const SkuNamed = struct {
    pub const nilo_table = .{
        .name = "skus",
        .key = .id,
        .check = .{ .skus_kind_is_known = .{ .words_of = .kind } },
    };

    id: i64,
    kind: Level,
};

test "naming an enum column's check is one drop by the old name and one add by the new" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const before = try snapshotFrom(a, Pg, &.{Sku});
    const change = try plan(a, Pg, comptime desiredOf(Pg, .{ .tables = &.{SkuNamed} }), before);

    try testing.expectEqual(@as(usize, 0), change.problems.len);
    try testing.expectEqual(@as(usize, 2), change.steps.len);
    // The old name is the one the database has, and it is the snapshot that
    // knows it. Dropping by the new name would find nothing.
    try testing.expectEqualStrings(
        "ALTER TABLE \"skus\" DROP CONSTRAINT \"skus_kind_check\"",
        change.steps[0].sql,
    );
    try testing.expectEqualStrings(
        "skus.kind: the check over its words is called something else now",
        change.steps[0].why,
    );
    try testing.expectEqualStrings(
        "ALTER TABLE \"skus\" ADD CONSTRAINT \"skus_kind_is_known\" " ++
            "CHECK (\"kind\" IN ('low', 'high'))",
        change.steps[1].sql,
    );
}

test "an index redefined over a column that is dropped goes before the column and comes back after it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The partial index's `WHERE` reads `closed_at`, and the column goes. The
    // name is derived from the columns, so it stays and the definition moves:
    // Postgres took the index down with the column, and a `DROP INDEX` after it
    // named nothing; SQLite refuses the column while the index is there.
    const Before = struct {
        pub const nilo_table = .{
            .name = "jobs",
            .key = .id,
            .index = .{.{ .columns = .{.owner}, .where = .{ .closed_at = null } }},
        };
        id: i64,
        owner: i64,
        closed_at: ?types.Timestamp,
    };
    const After = struct {
        pub const nilo_table = .{ .name = "jobs", .key = .id, .index = .{.owner} };
        id: i64,
        owner: i64,
    };

    inline for (.{ Pg, Lite }) |D| {
        const change = try plan(a, D, comptime desiredOf(D, .{ .tables = &.{After} }), try snapshotFrom(a, D, &.{Before}));
        try testing.expectEqual(@as(usize, 0), change.problems.len);
        const kinds = [_]Kind{ .drop_index, .drop_column, .create_index };
        try testing.expectEqual(kinds.len, change.steps.len);
        for (kinds, change.steps) |want, step| try testing.expectEqual(want, step.kind);
    }
}

test "renaming an enum column with `.was` renames its check on Postgres, and SQLite has none to rename" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Before = struct {
        pub const nilo_table = .{ .name = "moods", .key = .id };
        id: i64,
        mood: Mood,
    };
    const After = struct {
        pub const nilo_table = .{ .name = "moods", .key = .id, .was = .{ .feeling = "mood" } };
        id: i64,
        feeling: Mood,
    };

    // The database keeps `moods_mood_check` through the rename, and the next
    // snapshot derives `moods_feeling_check`: a later change to the words
    // would drop a name the database does not have.
    const pg = try plan(a, Pg, comptime desiredOf(Pg, .{ .tables = &.{After} }), try snapshotFrom(a, Pg, &.{Before}));
    try testing.expectEqual(@as(usize, 0), pg.problems.len);
    try testing.expectEqual(@as(usize, 2), pg.steps.len);
    try testing.expectEqual(Kind.rename_column, pg.steps[0].kind);
    try testing.expectEqual(Kind.rename_constraint, pg.steps[1].kind);
    try testing.expectEqualStrings(
        "ALTER TABLE \"moods\" RENAME CONSTRAINT \"moods_mood_check\" TO \"moods_feeling_check\"",
        pg.steps[1].sql,
    );

    // SQLite follows the rename inside the constraint's text and never names it.
    const lite = try plan(a, Lite, comptime desiredOf(Lite, .{ .tables = &.{After} }), try snapshotFrom(a, Lite, &.{Before}));
    try testing.expectEqual(@as(usize, 0), lite.problems.len);
    try testing.expectEqual(@as(usize, 1), lite.steps.len);
    try testing.expectEqual(Kind.rename_column, lite.steps[0].kind);

    // The words changing as well: the old name is dropped and the new one made,
    // which needs no rename.
    const Fewer = enum { calm, glad };
    const Changed = struct {
        pub const nilo_table = .{ .name = "moods", .key = .id, .was = .{ .feeling = "mood" } };
        id: i64,
        feeling: Fewer,
    };
    const both = try plan(a, Pg, comptime desiredOf(Pg, .{ .tables = &.{Changed} }), try snapshotFrom(a, Pg, &.{Before}));
    const kinds = [_]Kind{ .rename_column, .drop_check, .create_check };
    try testing.expectEqual(kinds.len, both.steps.len);
    for (kinds, both.steps) |want, step| try testing.expectEqual(want, step.kind);
    try testing.expect(std.mem.indexOf(u8, both.steps[1].sql, "\"moods_mood_check\"") != null);
}

test "a required column with no default is a Problem on SQLite, which refuses the ALTER, and a backfill on Postgres" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Bare = struct {
        pub const nilo_table = .{ .name = "notes", .key = .id };
        id: i64,
        body: []const u8,
        views: i64,
    };

    const lite = try plan(a, Lite, comptime desiredOf(Lite, .{ .tables = &.{Bare} }), try snapshotFrom(a, Lite, &.{Plain}));
    try testing.expectEqual(@as(usize, 0), lite.steps.len);
    try testing.expectEqual(@as(usize, 1), lite.problems.len);
    try testing.expectEqualStrings("views", lite.problems[0].column);
    try testing.expect(std.mem.indexOf(u8, lite.problems[0].text, "NOT NULL") != null);
    try testing.expect(std.mem.indexOf(u8, lite.problems[0].text, "CREATE a new table") != null);

    const pg = try plan(a, Pg, comptime desiredOf(Pg, .{ .tables = &.{Bare} }), try snapshotFrom(a, Pg, &.{Plain}));
    try testing.expectEqual(@as(usize, 0), pg.problems.len);
    try testing.expect(pg.needsBackfill());

    // With a default, or optional, SQLite takes it as it always did.
    const filled = try plan(a, Lite, comptime desiredOf(Lite, .{ .tables = &.{PlainWithCount} }), try snapshotFrom(a, Lite, &.{Plain}));
    try testing.expectEqual(@as(usize, 0), filled.problems.len);
    try testing.expectEqual(@as(usize, 1), filled.steps.len);
}

test {
    _ = ddl;
    _ = snapshot;
    _ = table_mod;
}

test "one ledger read answers whether a version is waiting, applied or edited, and where the head is" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const one: []const Step = &.{.{ .kind = .create_table, .sql = "CREATE TABLE a (id int)", .why = "a" }};
    const two: []const Step = &.{.{ .kind = .create_table, .sql = "CREATE TABLE b (id int)", .why = "b" }};
    const three: []const Step = &.{.{ .kind = .create_table, .sql = "CREATE TABLE c (id int)", .why = "c" }};
    const chain = try chainOf(a, &.{
        .{ .number = 1, .name = "a", .steps = one },
        .{ .number = 2, .name = "b", .steps = two },
        .{ .number = 3, .name = "c", .steps = three },
    });

    // 1 ran as it is, 2 ran under another hash, 3 never ran.
    const ledger = [_]Recorded{
        .{ .version = 1, .hash = chain.hashes[0] },
        .{ .version = 2, .hash = "not-what-it-hashes-to-now" },
    };

    try testing.expect(seen(&ledger, 1, chain.hashes[0]).applied());
    try testing.expect(!seen(&ledger, 1, chain.hashes[0]).edited());
    try testing.expect(seen(&ledger, 2, chain.hashes[1]).edited());
    try testing.expectEqualStrings("not-what-it-hashes-to-now", seen(&ledger, 2, chain.hashes[1]).moved);
    try testing.expect(!seen(&ledger, 3, chain.hashes[2]).applied());

    // The three readers of the ledger are all this one comparison: `drift`
    // reports exactly the edited version and not the waiting one.
    const moved = try driftIn(a, &ledger, chain);
    try testing.expectEqual(@as(usize, 1), moved.len);
    try testing.expectEqual(@as(i64, 2), moved[0].version);
    try testing.expectEqualStrings("not-what-it-hashes-to-now", moved[0].recorded);
    try testing.expectEqualStrings(chain.hashes[1], moved[0].now);

    try testing.expectEqual(@as(i64, 2), headOfLedger(&ledger));
    try testing.expectEqual(@as(i64, 0), headOfLedger(&.{}));
}

const Unmarked = struct {
    pub const nilo_table = .{
        .name = "unmarked",
        .key = .id,
        .references = .{ .org_id = .{ Org, .id, .cascade } },
    };
    id: i64,
    org_id: i64,
};

const Marked = struct {
    pub const nilo_table = .{
        .name = "marked",
        .key = .id,
        .index = .{.org_id},
        .references = .{ .org_id = .{ Org, .id, .cascade } },
    };
    id: i64,
    org_id: i64,
};

/// The column is second in the only unique, so an equality on it alone
/// cannot use that unique.
const Second = struct {
    pub const nilo_table = .{
        .name = "second",
        .key = .id,
        .unique = .{.{ .columns = .{ .tenant_id, .org_id } }},
        .references = .{ .org_id = .{ Org, .id } },
    };
    id: i64,
    tenant_id: i64,
    org_id: i64,
};

/// The column leads a unique, so the unique serves it.
const First = struct {
    pub const nilo_table = .{
        .name = "first",
        .key = .id,
        .unique = .{.{ .columns = .{ .org_id, .slot } }},
        .references = .{ .org_id = .{ Org, .id } },
    };
    id: i64,
    org_id: i64,
    slot: i64,
};

/// A partial index leaves out rows a delete of the parent has to find.
const Unhelped = struct {
    pub const nilo_table = .{
        .name = "unhelped",
        .key = .id,
        .index = .{.{ .columns = .{.org_id}, .where = .{ .deleted_at = null } }},
        .references = .{ .org_id = .{ Org, .id } },
    };
    id: i64,
    org_id: i64,
    deleted_at: ?i64,
};

/// The key is an index: a reference that is the key is served.
const Extension = struct {
    pub const nilo_table = .{
        .name = "extension",
        .key = .org_id,
        .references = .{ .org_id = .{ Org, .id } },
    };
    org_id: i64,
    note: []const u8,
};

/// Somebody else's table, and somebody else's indexes.
const Borrowed = struct {
    pub const nilo_table = .{
        .name = "borrowed",
        .key = .id,
        .managed = false,
        .references = .{ .org_id = .{ Org, .id } },
    };
    id: i64,
    org_id: i64,
};

test "a reference nothing indexes is reported with the table, the column and where the marker goes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tables = comptime desiredOf(Pg, .{ .tables = &.{ Org, Unmarked } }).tables;
    const found = try unindexedReferences(a, tables);

    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqualStrings("unmarked", found[0].table);
    try testing.expectEqualStrings("orgs", found[0].parent);
    try testing.expectEqual(@as(usize, 1), found[0].columns.len);
    try testing.expectEqualStrings("org_id", found[0].columns[0]);
    try testing.expectEqual(table_mod.OnDelete.cascade, found[0].on_delete);
    try testing.expect(!found[0].has_index);
}

test "a reference whose column leads an index, a unique or the key is not reported" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tables = comptime desiredOf(Pg, .{ .tables = &.{ Org, Marked, First, Extension } }).tables;
    try testing.expectEqual(@as(usize, 0), (try unindexedReferences(a, tables)).len);
}

test "a reference whose column is second in a composite unique is reported, and so is one only a partial index covers" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tables = comptime desiredOf(Pg, .{ .tables = &.{ Org, Second, Unhelped } }).tables;
    const found = try unindexedReferences(a, tables);

    try testing.expectEqual(@as(usize, 2), found.len);
    try testing.expectEqualStrings("second", found[0].table);
    try testing.expect(!found[0].has_index);
    try testing.expectEqualStrings("unhelped", found[1].table);
    try testing.expect(found[1].has_index);
}

test "a table this program only reads is not asked for its indexes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tables = comptime desiredOf(Pg, .{ .tables = &.{ Org, Borrowed } }).tables;
    try testing.expectEqual(@as(usize, 0), (try unindexedReferences(a, tables)).len);
}
