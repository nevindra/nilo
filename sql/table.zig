//! What a Row says about the **table** rather than about a query
//! ([ADR 0153](../docs/adr/0153-a-migration-is-a-diff-against-a-snapshot.md)).
//!
//! `row.zig` answers what a `SELECT` needs: the name, the key, the column
//! list. That is not enough to create anything. A table also has a unique
//! constraint, an index and a foreign key, and none of the three can be
//! derived from a struct.
//!
//! So the marker grows by three words, and the bar each one had to pass is
//! **the compiler can check it**:
//!
//! ```zig
//! pub const nilo_table = .{
//!     .name = "users",
//!     .key = .id,
//!     .unique = .{ .{ .columns = .{.email}, .ignoring_case = true } },
//!     .index = .{ .{ .tenant_id, .created_at } },
//!     .references = .{ .org_id = .{ Org, .id, .cascade } },
//! };
//! ```
//!
//! `.unique` and `.index` are checked against the Row's own columns.
//! `.references` is checked harder, and it is the reason the three are worth
//! having at all: `Org` has to be a Row, `.id` has to be one of its columns,
//! **and `org_id`'s Zig type has to be the same as `Org.id`'s**. A foreign key
//! whose two sides do not line up is a bug that arrives at the first insert in
//! production, and here it does not compile. `.set_null` on a column that is
//! not optional is refused for the same reason.
//!
//! **A check constraint, a partial index, a collation on a column, a generated
//! column, a trigger and a view are all absent, and none of them is a gap.**
//! Each would be a string the database reads, so nothing about it could be
//! checked while compiling, and a vocabulary that stops being checked starts
//! growing. Those go in a step as SQL, and the snapshot marks them as objects
//! nilo does not own so that a diff never tries to drop one. A fourth word
//! needs a caller with a case and a check that runs while compiling, which is
//! the bar every other feature here has had.
//!
//! **Nothing in this file allocates, and none of it is reachable from a
//! request.** A `Desc` is a comptime value, so the whole description of a table
//! is in `.rodata` before the program runs, which is the same property
//! `statement.zig` has and for the same reason.

const std = @import("std");
const core = @import("nilo_core");
const row_mod = @import("row.zig");

/// What happens to a referencing row when the row it points at is deleted.
///
/// Four, and they are the four the standard has that mean something different.
/// `SET DEFAULT` is left out because a default is not a word this marker has,
/// so naming it would promise something nothing else here can express.
pub const OnDelete = enum {
    /// No clause at all, which is the database's own default. Deleting a
    /// referenced row fails while anything points at it.
    no_action,
    cascade,
    restrict,
    /// Only on a column that is optional, and refused otherwise. The database
    /// would refuse it too, at the moment of the delete rather than at the
    /// moment somebody wrote it.
    set_null,

    pub fn clause(self: OnDelete) []const u8 {
        return switch (self) {
            .no_action => "",
            .cascade => " ON DELETE CASCADE",
            .restrict => " ON DELETE RESTRICT",
            .set_null => " ON DELETE SET NULL",
        };
    }
};

pub const Column = struct {
    name: []const u8,
    /// What this Dialect would write for the column, which is the first entry
    /// of `accepts` and therefore the type the startup check expects.
    sql_type: []const u8,
    nullable: bool = false,
    /// Whether `.key` names this column. True of several columns when the key
    /// spans several, which is what a join table and a multi-tenant table both
    /// are.
    key: bool = false,
    /// The database makes the value. True for an integer key of one column and
    /// nothing else — see `generatedKey`.
    generated: bool = false,

    /// Whether two columns describe the same thing. The name is matched by the
    /// caller, so this is the part that decides whether an `ALTER` is needed.
    pub fn sameAs(self: Column, other: Column) bool {
        return std.mem.eql(u8, self.sql_type, other.sql_type) and
            self.nullable == other.nullable and
            self.key == other.key and
            self.generated == other.generated;
    }
};

pub const Unique = struct {
    name: []const u8,
    columns: []const []const u8,
    /// Compared without regard to case, which the two databases reach by
    /// different mechanisms. That is the Dialect's business, not this file's.
    ignoring_case: bool = false,

    pub fn sameAs(self: Unique, other: Unique) bool {
        return self.ignoring_case == other.ignoring_case and
            sameColumns(self.columns, other.columns);
    }
};

/// Two column lists, in order. Order matters in an index: `(a, b)` and
/// `(b, a)` serve different queries, so they are two indexes rather than one
/// written twice.
pub fn sameColumns(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.mem.eql(u8, x, y)) return false;
    }
    return true;
}

pub const Index = struct {
    name: []const u8,
    columns: []const []const u8,

    pub fn sameAs(self: Index, other: Index) bool {
        return sameColumns(self.columns, other.columns);
    }
};

pub const Reference = struct {
    name: []const u8,
    column: []const u8,
    /// The table pointed at, split the same way the Row's own name is. Taken
    /// from the target Row rather than from a string, so renaming that table
    /// moves this with it — and split rather than written whole so that the
    /// create order can be worked out by comparing two names rather than by
    /// parsing one.
    schema: ?[]const u8 = null,
    table: []const u8,
    target: []const u8,
    on_delete: OnDelete = .no_action,

    pub fn sameAs(self: Reference, other: Reference) bool {
        return std.mem.eql(u8, self.column, other.column) and
            std.mem.eql(u8, self.table, other.table) and
            sameSchema(self.schema, other.schema) and
            std.mem.eql(u8, self.target, other.target) and
            self.on_delete == other.on_delete;
    }
};

pub fn sameSchema(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

pub const Rename = struct {
    /// What the column used to be called, and what the database still has.
    from: []const u8,
    /// What the Row calls it now.
    to: []const u8,
};

/// One table, entirely. A comptime value, and every slice in it points into
/// the binary.
pub const Desc = struct {
    /// `@typeName` of the Row, for a message rather than for the SQL. Empty in
    /// a snapshot: renaming the Zig type would otherwise read as a schema
    /// change, and it is not one.
    row: []const u8 = "",
    schema: ?[]const u8 = null,
    table: []const u8,
    /// The columns that identify a row, in the order the marker wrote them —
    /// which is also the order they go into the `PRIMARY KEY`, and therefore
    /// the order of the index behind it.
    ///
    /// **A list rather than a name, and the snapshot says `.keys` because of
    /// it.** A file written by an older `generate` says `.key` and no longer
    /// parses; `db generate` rewrites it from the types, which is the same
    /// thing that fixes every other snapshot disagreement.
    keys: []const []const u8,
    columns: []const Column,
    /// The four below default to nothing so that a snapshot file carries only
    /// what a table actually has. `std.zon` omits a field equal to its default,
    /// which is what keeps the file readable and its diffs small.
    uniques: []const Unique = &.{},
    indexes: []const Index = &.{},
    references: []const Reference = &.{},
    /// Never written to a snapshot. A rename is how a schema got somewhere,
    /// not part of where it is.
    renames: []const Rename = &.{},
    /// Whether this program builds the table
    /// ([ADR 0162](../docs/adr/0162-a-table-this-program-reads-and-does-not-build.md)).
    /// Written to a snapshot, unlike the two above: a table this program
    /// starts or stops building is a change somebody should see in the file's
    /// diff, and `std.zon` omits a field equal to its default — so `false` is
    /// a line and `true` is silence.
    managed: bool = true,

    pub fn column(self: Desc, name: []const u8) ?Column {
        for (self.columns) |c| {
            if (std.mem.eql(u8, c.name, name)) return c;
        }
        return null;
    }
};

/// The whole table `Row` describes, as `D` would write it.
///
/// Every Refusal this file has fires from here, so a Row that does not
/// describe a table stops at the first call rather than at the third.
pub fn descOf(comptime D: type, comptime Row: type) Desc {
    return comptime blk: {
        const owner = row_mod.ownerOf(Row);
        const qualified = row_mod.qualifiedOf(owner);
        const keys = row_mod.keysOf(owner);
        const decl = @field(owner, row_mod.marker);

        break :blk .{
            .row = @typeName(owner),
            .schema = qualified.schema,
            .table = qualified.table,
            .keys = keys,
            .columns = columnsOf(D, owner, keys),
            .uniques = uniquesOf(owner, qualified.table, decl),
            .indexes = indexesOf(owner, qualified.table, decl),
            .references = referencesOf(owner, qualified.table, decl),
            .renames = renamesOf(owner, decl),
            .managed = row_mod.managedOf(owner),
        };
    };
}

/// The foreign keys `Row`'s marker declares, **with no Dialect involved.**
///
/// `descOf` answers this too, and asking it costs a `columnType` for every
/// column of the table — which can refuse, for a column type the Dialect has
/// no name for, in the middle of a question that has nothing to do with column
/// types. The where walker asks this one, to find how two tables are joined
/// for an `.exists`, and it has no Dialect's opinion to spend
/// ([ADR 0171](../docs/adr/0171-a-row-over-there-is-a-condition.md)).
pub fn foreignKeysOf(comptime Row: type) []const Reference {
    return comptime blk: {
        const owner = row_mod.ownerOf(Row);
        const decl = @field(owner, row_mod.marker);
        break :blk referencesOf(owner, row_mod.qualifiedOf(owner).table, decl);
    };
}

// -- the columns ---------------------------------------------------------

fn columnsOf(
    comptime D: type,
    comptime Row: type,
    comptime keys: []const []const u8,
) []const Column {
    comptime {
        const fields = @typeInfo(Row).@"struct".fields;
        var out: [fields.len]Column = undefined;
        for (fields, 0..) |f, i| {
            var is_key = false;
            for (keys) |key| {
                if (std.mem.eql(u8, f.name, key)) is_key = true;
            }
            const optional = @typeInfo(f.type) == .optional;

            if (is_key and optional) @compileError(
                "nilo: " ++ @typeName(Row) ++ "'s key `" ++ f.name ++ "` is optional.\n" ++
                    "  A key identifies a row, so there is no row for it to be null on. " ++
                    "Drop the `?`, or name another column with `.key`.",
            );

            out[i] = .{
                .name = f.name,
                .sql_type = D.columnType(f.type) orelse noColumnType(D, Row, f.name, f.type),
                .nullable = optional,
                .key = is_key,
                // **Only a key of one column is ever generated**, and that is
                // the rule rather than a limitation. A sequence fills in one
                // column; a key spanning two is made of values the program
                // already holds — a tenant and an id, two sides of a join —
                // so there is nothing for the database to invent.
                .generated = is_key and keys.len == 1 and generatedKey(f.type),
            };
        }
        const frozen = out;
        return &frozen;
    }
}

/// Whether the database makes this key rather than the program.
///
/// **An integer key is generated and anything else is supplied.** That is a
/// rule rather than a marker word, and it is the right way round: a `Uuid` key
/// is made by the program before the insert, and an integer one is what a
/// sequence exists for. A program that supplies its own integer key writes the
/// create step by hand and gets a word here the day it says so.
fn generatedKey(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int => |i| i.signedness == .signed,
        else => false,
    };
}

fn noColumnType(
    comptime D: type,
    comptime Row: type,
    comptime name: []const u8,
    comptime T: type,
) noreturn {
    @compileError(
        "nilo: the " ++ D.name ++ " dialect has no column type for " ++ @typeName(Row) ++
            "." ++ name ++ ", which it reads as " ++ @typeName(T) ++ ".\n" ++
            "  A table cannot be created for a column nothing can name. Four ways " ++
            "out: `sql.AsText(\"<type>\")` for a type the database prints, " ++
            "`sql.Json(T)` for a document, a `pub const nilo_column = \"…\"` on the " ++
            "type so it says which column it belongs in, or leaving the column out " ++
            "of the Row and writing it in a step.",
    );
}

// -- the three words -----------------------------------------------------

/// One entry of `.unique` or `.index`, in whichever of the shapes it was
/// written in. The three exist so the common case stays short:
///
/// - `.email` — one column
/// - `.{ .tenant_id, .name }` — several, as one constraint
/// - `.{ .columns = .{.email}, .ignoring_case = true }` — the full form
///
/// The named form is what makes the second one unambiguous. Without it,
/// `.{ .email, .ignoring_case }` could be a composite over a column honestly
/// called `ignoring_case`, and a marker that guesses is worse than one that
/// asks for a field name.
fn entryColumns(
    comptime Row: type,
    comptime what: []const u8,
    comptime entry: anytype,
) []const []const u8 {
    comptime {
        const E = @TypeOf(entry);
        if (@typeInfo(E) == .enum_literal) {
            checkColumn(Row, what, @tagName(entry));
            const one = [_][]const u8{@tagName(entry)};
            const frozen = one;
            return &frozen;
        }
        if (@typeInfo(E) != .@"struct") @compileError(
            "nilo: " ++ @typeName(Row) ++ "'s `." ++ what ++ "` holds a " ++
                @typeName(E) ++ ".\n" ++
                "  Each entry is a column (`.email`), several as one constraint " ++
                "(`.{ .tenant_id, .name }`), or the named form " ++
                "(`.{ .columns = .{.email}, … }`).",
        );

        const inner = if (@hasField(E, "columns")) entry.columns else entry;
        const fields = @typeInfo(@TypeOf(inner)).@"struct".fields;
        if (fields.len == 0) @compileError(
            "nilo: " ++ @typeName(Row) ++ " has an empty entry in `." ++ what ++ "`.\n" ++
                "  A constraint over no columns is nothing, and writing it is more " ++
                "likely a half-finished line than a decision.",
        );

        var out: [fields.len][]const u8 = undefined;
        for (fields, 0..) |f, i| {
            const value = @field(inner, f.name);
            if (@typeInfo(@TypeOf(value)) != .enum_literal) @compileError(
                "nilo: " ++ @typeName(Row) ++ "'s `." ++ what ++ "` names a column as " ++
                    @typeName(@TypeOf(value)) ++ ".\n" ++
                    "  A column is written the way it is everywhere else here, as " ++
                    "`.<name>` rather than as text.",
            );
            checkColumn(Row, what, @tagName(value));
            out[i] = @tagName(value);
        }
        const frozen = out;
        return &frozen;
    }
}

fn checkColumn(comptime Row: type, comptime what: []const u8, comptime name: []const u8) void {
    comptime {
        if (!row_mod.hasColumn(Row, name)) row_mod.noSuchColumn(Row, name, "`." ++ what ++ "`");
    }
}

fn uniquesOf(
    comptime Row: type,
    comptime table: []const u8,
    comptime decl: anytype,
) []const Unique {
    comptime {
        if (!@hasField(@TypeOf(decl), "unique")) return &.{};
        const entries = @typeInfo(@TypeOf(decl.unique)).@"struct".fields;
        var out: [entries.len]Unique = undefined;
        for (entries, 0..) |f, i| {
            const entry = @field(decl.unique, f.name);
            const columns = entryColumns(Row, "unique", entry);
            const E = @TypeOf(entry);
            const folding = @typeInfo(E) == .@"struct" and
                @hasField(E, "ignoring_case") and entry.ignoring_case;
            if (folding) for (columns) |c| checkText(Row, c);
            out[i] = .{
                .name = constraintName(table, columns, "key"),
                .columns = columns,
                .ignoring_case = folding,
            };
        }
        const frozen = out;
        return &frozen;
    }
}

/// `.ignoring_case` on a column that is not text has nothing to fold.
///
/// Both databases would accept the DDL and neither would do anything with it,
/// which is the shape of mistake that survives a review and is found by a
/// duplicate row.
fn checkText(comptime Row: type, comptime name: []const u8) void {
    comptime {
        const T = row_mod.ColumnType(Row, name);
        const Inner = switch (@typeInfo(T)) {
            .optional => |o| o.child,
            else => T,
        };
        // The same two shapes `dialect.acceptsInner` calls text, asked here in
        // the same order, so a column that reads as text is a column that can
        // have its case folded.
        const text = Inner == core.Str or switch (@typeInfo(Inner)) {
            .pointer => |p| p.size == .slice and p.child == u8,
            else => false,
        };
        if (!text) @compileError(
            "nilo: " ++ @typeName(Row) ++ "'s unique on `" ++ name ++
                "` asks to ignore case, and the column is " ++ @typeName(T) ++ ".\n" ++
                "  Only text has a case to ignore. Both databases would take the " ++
                "clause and neither would do anything with it.",
        );
    }
}

fn indexesOf(
    comptime Row: type,
    comptime table: []const u8,
    comptime decl: anytype,
) []const Index {
    comptime {
        if (!@hasField(@TypeOf(decl), "index")) return &.{};
        const entries = @typeInfo(@TypeOf(decl.index)).@"struct".fields;
        var out: [entries.len]Index = undefined;
        for (entries, 0..) |f, i| {
            const columns = entryColumns(Row, "index", @field(decl.index, f.name));
            out[i] = .{ .name = constraintName(table, columns, "idx"), .columns = columns };
        }
        const frozen = out;
        return &frozen;
    }
}

fn referencesOf(
    comptime Row: type,
    comptime table: []const u8,
    comptime decl: anytype,
) []const Reference {
    comptime {
        if (!@hasField(@TypeOf(decl), "references")) return &.{};
        const D = @TypeOf(decl.references);
        const entries = @typeInfo(D).@"struct".fields;
        if (entries.len > 0 and entries[0].name[0] >= '0' and entries[0].name[0] <= '9')
            @compileError(
                "nilo: " ++ @typeName(Row) ++ "'s `.references` is a list.\n" ++
                    "  It is keyed by the column doing the pointing: " ++
                    "`.references = .{ .org_id = .{ Org, .id } }`.",
            );

        var out: [entries.len]Reference = undefined;
        for (entries, 0..) |f, i| {
            checkColumn(Row, "references", f.name);
            out[i] = oneReference(Row, table, f.name, @field(decl.references, f.name));
        }
        const frozen = out;
        return &frozen;
    }
}

fn oneReference(
    comptime Row: type,
    comptime table: []const u8,
    comptime column: []const u8,
    comptime entry: anytype,
) Reference {
    comptime {
        const E = @TypeOf(entry);
        const shape = "nilo: " ++ @typeName(Row) ++ "'s `.references." ++ column ++
            "` is not a table and a column.\n" ++
            "  It is written `.{ <Row>, .<column> }`, with `.cascade`, `.restrict` " ++
            "or `.set_null` after it when the delete should do something.";
        if (@typeInfo(E) != .@"struct") @compileError(shape);
        const parts = @typeInfo(E).@"struct".fields;
        if (parts.len < 2 or parts.len > 3) @compileError(shape);

        const Target = entry[0];
        if (@TypeOf(Target) != type or !row_mod.isRow(Target)) @compileError(
            "nilo: " ++ @typeName(Row) ++ "'s `.references." ++ column ++
                "` points at something that is not a Row.\n" ++
                "  A foreign key names the Row that owns the table, so that renaming " ++
                "that table moves this with it. A string would not.",
        );
        if (@typeInfo(@TypeOf(entry[1])) != .enum_literal) @compileError(shape);
        const target = @tagName(entry[1]);
        if (!row_mod.hasColumn(Target, target))
            row_mod.noSuchColumn(Target, target, "`.references." ++ column ++ "`");

        // The check the whole word is worth having. Two sides of a foreign key
        // that hold different types is a bug the database finds at the first
        // insert, in a message about a cast rather than about a design.
        const mine = row_mod.ColumnType(Row, column);
        const theirs = row_mod.ColumnType(Target, target);
        const bare = switch (@typeInfo(mine)) {
            .optional => |o| o.child,
            else => mine,
        };
        if (bare != theirs) @compileError(
            "nilo: " ++ @typeName(Row) ++ "." ++ column ++ " is " ++ @typeName(mine) ++
                " and points at " ++ @typeName(Target) ++ "." ++ target ++ ", which is " ++
                @typeName(theirs) ++ ".\n" ++
                "  Two sides of a foreign key hold the same value, so they are the " ++
                "same type. One of the two is wrong about its column.",
        );

        const on_delete: OnDelete = if (parts.len == 3) named: {
            if (@typeInfo(@TypeOf(entry[2])) != .enum_literal) @compileError(shape);
            break :named std.meta.stringToEnum(OnDelete, @tagName(entry[2])) orelse @compileError(
                "nilo: " ++ @typeName(Row) ++ "'s `.references." ++ column ++ "` says `." ++
                    @tagName(entry[2]) ++ "` happens on delete.\n" ++
                    "  The three it can say are `.cascade`, `.restrict` and `.set_null`.",
            );
        } else .no_action;

        if (on_delete == .set_null and @typeInfo(mine) != .optional) @compileError(
            "nilo: " ++ @typeName(Row) ++ "." ++ column ++ " is set to null on delete, " ++
                "and it is " ++ @typeName(mine) ++ ".\n" ++
                "  A column the database will write a null into is optional in the Row, " ++
                "or the first cascading delete is a row nothing can read.",
        );

        const pointed = row_mod.qualifiedOf(Target);
        return .{
            .name = constraintName(table, &.{column}, "fkey"),
            .column = column,
            .schema = pointed.schema,
            .table = pointed.table,
            .target = target,
            .on_delete = on_delete,
        };
    }
}

fn renamesOf(comptime Row: type, comptime decl: anytype) []const Rename {
    comptime {
        if (!@hasField(@TypeOf(decl), "was")) return &.{};
        const entries = @typeInfo(@TypeOf(decl.was)).@"struct".fields;
        var out: [entries.len]Rename = undefined;
        for (entries, 0..) |f, i| {
            checkColumn(Row, "was", f.name);
            const from = @field(decl.was, f.name);
            if (@typeInfo(@TypeOf(from)) == .enum_literal) @compileError(
                "nilo: " ++ @typeName(Row) ++ "'s `.was." ++ f.name ++ "` is `." ++
                    @tagName(from) ++ "`.\n" ++
                    "  The old name is text rather than a column, because it is not one " ++
                    "any more: `.was = .{ ." ++ f.name ++ " = \"" ++ @tagName(from) ++ "\" }`.",
            );
            // The old name being a column too would mean the Row has both, and
            // then a rename and a drop are the same statement written twice.
            if (row_mod.hasColumn(Row, from)) @compileError(
                "nilo: " ++ @typeName(Row) ++ " says `" ++ f.name ++ "` was called `" ++
                    from ++ "`, and it reads a column called `" ++ from ++ "` as well.\n" ++
                    "  Both cannot be true. A rename leaves one column, so one of the " ++
                    "two fields is the one that should go.",
            );
            out[i] = .{ .from = from, .to = f.name };
        }
        const frozen = out;
        return &frozen;
    }
}

/// The name nilo gives a constraint it creates.
///
/// Postgres's own convention, deliberately: `users_email_key`,
/// `users_org_id_fkey`. A `pull` from a database somebody else made then lines
/// up with what `generate` would have written, so the first diff against an
/// existing schema is empty rather than a rename of every index.
fn constraintName(
    comptime table: []const u8,
    comptime columns: []const []const u8,
    comptime suffix: []const u8,
) []const u8 {
    comptime {
        var out: []const u8 = table;
        for (columns) |c| out = out ++ "_" ++ c;
        return out ++ "_" ++ suffix;
    }
}

// -- tests ---------------------------------------------------------------

const testing = std.testing;
const Pg = @import("dialect.zig").Postgres;
const Lite = @import("dialect.zig").SQLite;
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
        .index = .{ .created_at, .{ .org_id, .created_at } },
        .references = .{ .org_id = .{ Org, .id, .cascade } },
    };

    id: i64,
    org_id: i64,
    email: core.Str,
    handle: []const u8,
    nickname: ?[]const u8,
    created_at: types.Timestamp,
};

test "a table is described entirely from the type, and the description is a constant" {
    const desc = comptime descOf(Pg, User);

    // If any of this were runtime work, the array below would not compile.
    const in_binary: [desc.columns.len]Column = desc.columns[0..desc.columns.len].*;
    try testing.expectEqual(@as(usize, 6), in_binary.len);

    try testing.expectEqualStrings("users", desc.table);
    try testing.expectEqual(@as(?[]const u8, null), desc.schema);
    try testing.expectEqual(@as(usize, 1), desc.keys.len);
    try testing.expectEqualStrings("id", desc.keys[0]);
}

test "a column's type is the one the dialect would write, and nullability is the `?`" {
    const desc = comptime descOf(Pg, User);

    try testing.expectEqualStrings("int8", desc.column("id").?.sql_type);
    try testing.expectEqualStrings("text", desc.column("email").?.sql_type);
    try testing.expectEqualStrings("timestamptz", desc.column("created_at").?.sql_type);

    try testing.expect(!desc.column("email").?.nullable);
    try testing.expect(desc.column("nickname").?.nullable);
}

test "an integer key is generated and a supplied one is not" {
    const desc = comptime descOf(Pg, User);
    try testing.expect(desc.column("id").?.key);
    try testing.expect(desc.column("id").?.generated);
    try testing.expect(!desc.column("org_id").?.key);

    const Doc = struct {
        pub const nilo_table = .{ .name = "docs", .key = .public };
        public: types.Uuid,
        title: []const u8,
    };
    const doc = comptime descOf(Pg, Doc);
    try testing.expect(doc.column("public").?.key);
    try testing.expect(!doc.column("public").?.generated);
}

test "the same type describes two databases, and only the column types move" {
    const pg = comptime descOf(Pg, User);
    const lite = comptime descOf(Lite, User);

    try testing.expectEqualStrings(pg.table, lite.table);
    try testing.expectEqual(pg.columns.len, lite.columns.len);
    try testing.expectEqual(pg.uniques.len, lite.uniques.len);

    try testing.expectEqualStrings("int8", pg.column("id").?.sql_type);
    try testing.expectEqualStrings("INTEGER", lite.column("id").?.sql_type);
    try testing.expectEqualStrings("timestamptz", pg.column("created_at").?.sql_type);
    // The one SQLite stores as an integer rather than as text (ADR 0136).
    try testing.expectEqualStrings("INTEGER", lite.column("created_at").?.sql_type);
}

test "a unique is written in whichever of the three shapes fits, and named the same way" {
    const desc = comptime descOf(Pg, User);
    try testing.expectEqual(@as(usize, 2), desc.uniques.len);

    try testing.expectEqualStrings("users_email_key", desc.uniques[0].name);
    try testing.expectEqual(@as(usize, 1), desc.uniques[0].columns.len);
    try testing.expect(desc.uniques[0].ignoring_case);

    try testing.expectEqualStrings("users_org_id_handle_key", desc.uniques[1].name);
    try testing.expectEqual(@as(usize, 2), desc.uniques[1].columns.len);
    try testing.expect(!desc.uniques[1].ignoring_case);
}

test "a bare column is one index and a tuple is one composite, which is the whole grammar" {
    const desc = comptime descOf(Pg, User);
    try testing.expectEqual(@as(usize, 2), desc.indexes.len);
    try testing.expectEqualStrings("users_created_at_idx", desc.indexes[0].name);
    try testing.expectEqualStrings("users_org_id_created_at_idx", desc.indexes[1].name);
    try testing.expectEqualStrings("org_id", desc.indexes[1].columns[0]);
    try testing.expectEqualStrings("created_at", desc.indexes[1].columns[1]);
}

test "a foreign key names the Row it points at, so the table comes from the type" {
    const desc = comptime descOf(Pg, User);
    try testing.expectEqual(@as(usize, 1), desc.references.len);

    const fk = desc.references[0];
    try testing.expectEqualStrings("users_org_id_fkey", fk.name);
    try testing.expectEqualStrings("org_id", fk.column);
    try testing.expectEqualStrings("orgs", fk.table);
    try testing.expectEqualStrings("id", fk.target);
    try testing.expectEqual(OnDelete.cascade, fk.on_delete);
    try testing.expectEqualStrings(" ON DELETE CASCADE", fk.on_delete.clause());
}

test "no delete behaviour written is no clause, rather than a guess at one" {
    const Post = struct {
        pub const nilo_table = .{
            .name = "posts",
            .key = .id,
            .references = .{ .org_id = .{ Org, .id } },
        };
        id: i64,
        org_id: i64,
    };
    const desc = comptime descOf(Pg, Post);
    try testing.expectEqual(OnDelete.no_action, desc.references[0].on_delete);
    try testing.expectEqualStrings("", desc.references[0].on_delete.clause());
}

test "a renamed column carries the name the database still has" {
    const Renamed = struct {
        pub const nilo_table = .{
            .name = "users",
            .key = .id,
            .was = .{ .email = "e_mail" },
        };
        id: i64,
        email: []const u8,
    };
    const desc = comptime descOf(Pg, Renamed);
    try testing.expectEqual(@as(usize, 1), desc.renames.len);
    try testing.expectEqualStrings("e_mail", desc.renames[0].from);
    try testing.expectEqualStrings("email", desc.renames[0].to);
}

test "a Row with none of the three words describes a table with none of them" {
    const Plain = struct {
        pub const nilo_table = .{ .name = "plain", .key = .id };
        id: i64,
        label: []const u8,
    };
    const desc = comptime descOf(Pg, Plain);
    try testing.expectEqual(@as(usize, 0), desc.uniques.len);
    try testing.expectEqual(@as(usize, 0), desc.indexes.len);
    try testing.expectEqual(@as(usize, 0), desc.references.len);
    try testing.expectEqual(@as(usize, 0), desc.renames.len);
    try testing.expectEqual(@as(usize, 2), desc.columns.len);
}

test "a narrower Row describes the table it borrows, not a table of its own" {
    // The three words live on the Row that names the table, and a borrowing
    // Row's marker is a `type` — so there is nowhere to write them and nothing
    // to refuse. The language holds the rule.
    const UserCard = struct {
        pub const nilo_table = User;
        id: i64,
        email: core.Str,
    };
    const desc = comptime descOf(Pg, UserCard);
    try testing.expectEqualStrings("users", desc.table);
    try testing.expectEqual(@as(usize, 6), desc.columns.len);
    try testing.expectEqual(@as(usize, 2), desc.uniques.len);
}

test "a schema-qualified table keeps the schema out of its constraint names" {
    const Audit = struct {
        pub const nilo_table = .{
            .name = "app.audit",
            .key = .id,
            .index = .{.at},
        };
        id: i64,
        at: types.Timestamp,
    };
    const desc = comptime descOf(Pg, Audit);
    try testing.expectEqualStrings("app", desc.schema.?);
    try testing.expectEqualStrings("audit", desc.table);
    try testing.expectEqualStrings("audit_at_idx", desc.indexes[0].name);
}
