//! A Row — a struct of the caller's own, one field per column, carrying the
//! marker that names its table (ADR 036).
//!
//! ```zig
//! const User = struct {
//!     pub const nilo_table = .{ .name = "users", .key = .id };
//!
//!     id: i64,
//!     email: Str,
//!     age: i32,
//! };
//! ```
//!
//! The marker is the fourth of its kind. `nilo_resolve`, `nilo_query` and
//! `nilo_response` are the others, and `resolve.zig` asks that they all read
//! alike — so this is not a new mechanism, it is the one already in use.
//!
//! **The table name is written, never guessed.** `User` to `users` looks
//! clever until `Category`, and every framework that guesses ends up shipping
//! a list of irregular nouns. A rule that fits in one sentence beats a clever
//! one with exceptions. `.key` is the one thing allowed a default, because
//! `id` involves no guessing at all.
//!
//! A narrower Row — the two columns a list page needs, rather than the ten the
//! table has — names another Row instead of a table:
//!
//! ```zig
//! const UserCard = struct {
//!     pub const nilo_table = User;
//!
//!     id: i64,
//!     email: Str,
//! };
//! ```
//!
//! That is not a second concept. It is a Row whose table came from somewhere
//! else, and it is worth the overload for one reason: the fields are checked
//! against `User` **while compiling**, so a typo fails at `zig build` with no
//! database in the room. Written out longhand, the same typo would survive
//! until the schema comparison reached a live Postgres.
//!
//! And a third shape, for a Row that **no table has**: the merged page of a
//! `UNION ALL`, a `GROUP BY` rollup, a card joining four tables
//! ([ADR 125](../docs/adr/125-a-row-that-owns-no-table.md)).
//!
//! ```zig
//! const TimelineRow = struct {
//!     pub const nilo_table = .projection;
//!
//!     at: sql.Timestamp,
//!     kind: Str,
//! };
//! ```
//!
//! `db.raw` and `tx.raw` fill one, because there the caller wrote the
//! statement. Everything that writes its own SQL refuses it by name, which is
//! the point: before this, such a Row had to name a table it did not
//! represent, and `db.checking` would then take that name at its word.
//!
//! A narrower Row may also **carry more than its table's columns**
//! ([ADR 218](../docs/adr/218-a-row-may-carry-its-parent-its-children-or-a-sum.md)):
//! a field whose type is another Row is the **parent** its reference points
//! at, a field whose type is a slice of Rows is the **children** that point
//! back, and a Row that says `nilo_aggregate` is **grouped**: one row per
//! value of its other fields, with a count or a sum beside them.
//!
//! ```zig
//! const OrderCard = struct {
//!     pub const nilo_table = Order;
//!
//!     id: i64,
//!     total: i64,
//!     customer: CustomerName,
//!     lines: []const LineBrief,
//! };
//! ```
//!
//! This file says which field is which and nothing more. The type is the whole
//! of the declaration: a field is a parent because of what it holds, not
//! because anything names it, and `shape.zig` is where the joins that follow
//! from it are written.
//!
//! Everything here answers a question about a type rather than about a
//! request, so all of it is settled before the binary exists — the first half
//! of ADR 036's rule.

const std = @import("std");
/// Named here only so that `Borrowed` knows which field type means *text
/// that lives as long as the work does*. Nothing else in this file asks any
/// other layer anything — and what it asks is Core, not the framework
/// (ADR 038).
const core = @import("nilo_core");
const types_mod = @import("types.zig");
const dialect_mod = @import("dialect.zig");

/// The declaration a Row carries. Named the way `nilo_resolve`,
/// `nilo_query` and `nilo_response` are, so the markers the compile-time
/// engine looks for all read alike.
pub const marker = "nilo_table";

/// How far a Row may borrow another Row's table before this gives up. Nothing
/// legitimate nests this deep; the limit exists so that a type holding itself
/// stops with a message rather than an eval-quota crash. Same reason the
/// schema walker and the staleness trap have one.
const max_borrow_depth = 8;

/// Whether `T` is a Row. Asked before anything else, so that a plain struct
/// handed to `select` is refused by name rather than by a missing field.
pub fn isRow(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => @hasDecl(T, marker),
        else => false,
    };
}

/// The one word the marker may be instead of a table or another Row.
pub const projection_word = "projection";

/// The second declaration a Row may carry: the fields **beside** its columns
/// ([ADR 178](../docs/adr/178-a-row-can-carry-a-field-no-column-holds.md)).
///
/// ```zig
/// const Line = struct {
///     pub const nilo_table = .projection;
///     pub const nilo_beside = .{ .attachments };
///
///     id: i64,
///     body: Str,
///     attachments: []const Attachment = &.{},
/// };
/// ```
///
/// A field named here is on the Row, in its JSON and in its document, and in
/// **no statement**: no `SELECT` list reads it, no insert or update writes
/// it, no `WHERE` or `ORDER BY` may name it, `db.checking` does not look for
/// it, and a read leaves it at its default for the caller to fill. It is the
/// one place a Row that is the response could not be the response before
/// this: a comment line carrying its files, which no column holds and a
/// second struct copying the Row's fields would have carried instead.
pub const beside_marker = "nilo_beside";

/// The fields `Row` carries beside its columns, in the order the marker
/// names them; empty for a Row that carries none. Every name is checked here
/// — a field the Row has, with a default for a read to leave it at — so a
/// caller reading the list reads a true one.
pub fn besideOf(comptime Row: type) []const []const u8 {
    return comptime blk: {
        if (!@hasDecl(Row, beside_marker)) break :blk &.{};
        @setEvalBranchQuota(20_000);
        const decl = @field(Row, beside_marker);
        const D = @TypeOf(decl);
        const shape = "\n  It is the fields beside the columns, written as names: " ++
            "`pub const " ++ beside_marker ++ " = .{ .attachments };`.";
        if (@typeInfo(D) != .@"struct" or !@typeInfo(D).@"struct".is_tuple) @compileError(
            "nilo: " ++ @typeName(Row) ++ "'s " ++ beside_marker ++ " is a " ++ @typeName(D) ++ "." ++ shape,
        );
        const entries = @typeInfo(D).@"struct".fields;
        if (entries.len == 0) @compileError(
            "nilo: " ++ @typeName(Row) ++ "'s " ++ beside_marker ++ " names nothing.\n" ++
                "  A line that does nothing is a line somebody will read as doing " ++
                "something. Name a field, or take the declaration out.",
        );
        var out: [entries.len][]const u8 = undefined;
        for (entries, 0..) |e, i| {
            if (e.type != @TypeOf(.enum_literal)) @compileError(
                "nilo: " ++ @typeName(Row) ++ "'s " ++ beside_marker ++ " holds a " ++
                    @typeName(e.type) ++ "." ++ shape,
            );
            const name = @tagName(decl[i]);
            const field = for (@typeInfo(Row).@"struct".fields) |f| {
                if (std.mem.eql(u8, f.name, name)) break f;
            } else {
                const head = "nilo: " ++ @typeName(Row) ++ "'s " ++ beside_marker ++ " names `" ++
                    name ++ "`, which is not one of its fields.";
                if (nearest(Row, name)) |near| @compileError(head ++ "\n  Did you mean `" ++ near ++ "`?");
                @compileError(head ++ "\n  Its fields are: " ++ fieldList(Row) ++ ".");
            };
            if (field.default_value_ptr == null) @compileError(
                "nilo: " ++ @typeName(Row) ++ " carries `" ++ name ++ "` beside its columns, " ++
                    "and the field has no default.\n" ++
                    "  No statement fills it, so a read has to leave it at something: " ++
                    "write `" ++ name ++ ": " ++ @typeName(field.type) ++ " = …` — an " ++
                    "empty list, a null, whatever \"not filled yet\" is for it.",
            );
            for (out[0..i]) |seen| {
                if (std.mem.eql(u8, seen, name)) @compileError(
                    "nilo: " ++ @typeName(Row) ++ "'s " ++ beside_marker ++ " names `" ++
                        name ++ "` twice.",
                );
            }
            out[i] = name;
        }
        const frozen = out;
        break :blk &frozen;
    };
}

/// Whether `name` is a field `Row` carries beside its columns.
pub fn isBeside(comptime Row: type, comptime name: []const u8) bool {
    return comptime blk: {
        for (besideOf(Row)) |b| {
            if (std.mem.eql(u8, b, name)) break :blk true;
        }
        break :blk false;
    };
}

/// The value a read leaves a beside field at: the default the field declares,
/// which `besideOf` has made sure it has.
pub fn besideDefault(comptime Row: type, comptime name: []const u8) @FieldType(Row, name) {
    comptime {
        for (@typeInfo(Row).@"struct".fields) |f| {
            if (std.mem.eql(u8, f.name, name)) return f.defaultValue().?;
        }
        unreachable; // `besideOf` checked the name
    }
}

/// Every field of `Row`, columns and beside alike, as one readable line.
fn fieldList(comptime Row: type) []const u8 {
    return comptime blk: {
        var out: []const u8 = "";
        for (@typeInfo(Row).@"struct".fields, 0..) |f, i| {
            out = out ++ (if (i == 0) "" else ", ") ++ "`" ++ f.name ++ "`";
        }
        break :blk out;
    };
}

// -- what each field is (ADR 218) --------------------------------------

/// What one field of a Row stands for.
///
/// **Read off the field's type, with one exception that is read off a
/// declaration**, and the exception is the one case a type cannot say: an
/// `i64` holding a sum looks exactly like an `i64` holding a column.
pub const Kind = enum {
    /// A column of the Row's own table, read by position.
    column,
    /// Named in `nilo_beside`: on the Row and in no statement (ADR 178).
    beside,
    /// A Row, or an optional one: the row its table's reference points at,
    /// joined into the same statement.
    parent,
    /// A slice of Rows: the rows whose reference points back at this one,
    /// read by a second statement.
    children,
    /// Named in `nilo_aggregate`: a count, a sum, a minimum over the rows of
    /// the group.
    aggregate,
    /// Named in `nilo_children` with a `.count`: how many rows of another
    /// table point at this one, read in the same statement.
    count,
};

/// The declaration that makes a Row grouped
/// ([ADR 218](../docs/adr/218-a-row-may-carry-its-parent-its-children-or-a-sum.md)).
///
/// ```zig
/// pub const nilo_aggregate = .{ .objects = .count, .owed = .{ .sum = .principal } };
/// ```
pub const aggregate_marker = "nilo_aggregate";

/// The declaration that says what a Row reads of the rows pointing back at
/// it, past the list itself: an order and a condition for a children field,
/// or a count in place of one
/// ([ADR 218](../docs/adr/218-a-row-may-carry-its-parent-its-children-or-a-sum.md)).
///
/// ```zig
/// pub const nilo_children = .{
///     .lines = .{ .order = .{ .position = .asc }, .where = .{ .state = .{ .ne = .void } } },
///     .line_count = .{ .count = Line },
/// };
/// ```
pub const children_marker = "nilo_children";

/// The declaration that says which reference a parent or children field
/// follows, when the schema declares more than one between the two tables.
///
/// ```zig
/// pub const nilo_via = .{ .owner = .owner_staff_id, .solution = .solution_staff_id };
/// ```
///
/// The field's twin of `.via` and `.on` on an `.exists`, and needed where
/// they are: only when the schema has said it twice.
pub const via_marker = "nilo_via";

/// One entry of `nilo_aggregate`: the field it fills, what it computes, and
/// over which column (none for `.count`, which counts rows).
pub const Aggregate = struct {
    field: []const u8,
    kind: dialect_mod.Aggregate,
    column: ?[]const u8,
    /// Whether the entry carries a `.where`, which only narrows the rows this
    /// one aggregate reads: `sum(…) FILTER (WHERE …)`. The condition itself
    /// is read off the declaration by `where.aggregateCall`, which has the
    /// table to check it against and this file does not.
    filtered: bool = false,
};

/// What `name` is on `Row`. A name that is not a field answers `.column`, so
/// that the caller's own "no such column" is the message it meets.
pub fn kindOf(comptime Row: type, comptime name: []const u8) Kind {
    const T = comptime fieldTypeOf(Row, name) orelse return .column;
    return comptime kindWith(Row, name, T);
}

/// The same, for a caller already holding the field's type: every loop over
/// a Row's fields, which would otherwise look each field up by name inside a
/// walk over the same fields and pay for the square of the Row's width
/// ([ADR 126](../docs/adr/126-a-check-pays-for-its-own-branches.md)).
pub fn kindWith(comptime Row: type, comptime name: []const u8, comptime T: type) Kind {
    return comptime blk: {
        // The two declarations first, and cheaply: a Row with neither, which is every
        // Row written before ADR 218, answers from the type alone.
        if (@hasDecl(Row, beside_marker) and isBeside(Row, name)) break :blk .beside;
        if (@hasDecl(Row, aggregate_marker) and aggregateNamed(Row, name)) break :blk .aggregate;
        if (@hasDecl(Row, children_marker) and countNamed(Row, name)) break :blk .count;
        if (parentRowOf(T) != null) break :blk .parent;
        if (childRowOf(T) != null) break :blk .children;
        break :blk .column;
    };
}

/// Whether `nilo_aggregate` has an entry for `name`, asked of the
/// declaration's type so that nothing is parsed to answer it. A declaration of
/// the wrong shape answers no, and `aggregatesOf` is what says why.
fn aggregateNamed(comptime Row: type, comptime name: []const u8) bool {
    const D = @TypeOf(@field(Row, aggregate_marker));
    return switch (@typeInfo(D)) {
        .@"struct" => |s| !s.is_tuple and @hasField(D, name),
        else => false,
    };
}

/// Whether `nilo_children` has an entry for `name` that is a count: a struct
/// with a `.count` in it. Asked of the types alone, the way `aggregateNamed`
/// is; `shape.zig` says what is wrong with an entry of any other shape.
fn countNamed(comptime Row: type, comptime name: []const u8) bool {
    const D = @TypeOf(@field(Row, children_marker));
    switch (@typeInfo(D)) {
        .@"struct" => |s| if (s.is_tuple or !@hasField(D, name)) return false,
        else => return false,
    }
    const E = @FieldType(D, name);
    return switch (@typeInfo(E)) {
        .@"struct" => |s| !s.is_tuple and @hasField(E, "count"),
        else => false,
    };
}

/// The Row a count field counts: the `.count` of its `nilo_children` entry.
pub fn countedRowOf(comptime Row: type, comptime name: []const u8) type {
    const counted = @field(@field(Row, children_marker), name).count;
    if (@TypeOf(counted) != type or !isRow(counted)) @compileError(
        "nilo: " ++ @typeName(Row) ++ "'s " ++ children_marker ++ " counts `." ++ name ++
            "` over a " ++ @typeName(@TypeOf(counted)) ++ ".\n" ++
            "  A count names the Row whose table points back at this one: `." ++ name ++
            " = .{ .count = Line }`.",
    );
    return counted;
}

/// Whether `name` is one of the Row's columns rather than anything else a
/// field can be. What every loop over a Row's fields asks before it treats
/// one as a column.
pub fn isColumnField(comptime Row: type, comptime name: []const u8) bool {
    return comptime kindOf(Row, name) == .column;
}

/// The Row a parent field holds, with the optional taken off, or null when
/// `T` is not one.
pub fn parentRowOf(comptime T: type) ?type {
    const Inner = switch (@typeInfo(T)) {
        .optional => |o| o.child,
        else => T,
    };
    return if (isRow(Inner)) Inner else null;
}

/// The Row a children field holds a slice of, or null when `T` is not one.
/// An optional slice answers too, so that it reaches the Refusal that says a
/// list of children is never null rather than a message about decoding.
pub fn childRowOf(comptime T: type) ?type {
    const Slice = switch (@typeInfo(T)) {
        .optional => |o| o.child,
        else => T,
    };
    return switch (@typeInfo(Slice)) {
        .pointer => |p| if (p.size == .slice and isRow(p.child)) p.child else null,
        else => null,
    };
}

/// The field's type, or null when `Row` has no field by that name.
pub fn fieldTypeOf(comptime Row: type, comptime name: []const u8) ?type {
    comptime {
        for (@typeInfo(Row).@"struct".fields) |f| {
            if (std.mem.eql(u8, f.name, name)) return f.type;
        }
        return null;
    }
}

/// Every field of `Row` of one kind, in the order the Row declares them.
pub fn fieldsOfKind(comptime Row: type, comptime kind: Kind) []const []const u8 {
    return comptime blk: {
        const fields = @typeInfo(Row).@"struct".fields;
        var out: [fields.len][]const u8 = undefined;
        var n: usize = 0;
        for (fields) |f| {
            if (kindWith(Row, f.name, f.type) != kind) continue;
            out[n] = f.name;
            n += 1;
        }
        const frozen = out[0..n].*;
        break :blk &frozen;
    };
}

/// Whether `Row` carries anything past its table's columns: a parent,
/// children, or a `nilo_aggregate`. Every statement over such a Row is
/// written by `shape.zig`; every other one by the flat path it always was.
pub fn isShaped(comptime Row: type) bool {
    return comptime blk: {
        if (!isRow(Row)) break :blk false;
        if (@hasDecl(Row, aggregate_marker)) break :blk true;
        for (@typeInfo(Row).@"struct".fields) |f| {
            switch (kindWith(Row, f.name, f.type)) {
                .parent, .children, .count => break :blk true,
                else => {},
            }
        }
        break :blk false;
    };
}

/// Whether `Row` is grouped: one row per value of its other fields.
pub fn isGrouped(comptime Row: type) bool {
    return comptime isRow(Row) and @hasDecl(Row, aggregate_marker);
}

/// Whether `Row` is grouped by nothing: every field an aggregate, so the
/// statement answers exactly one row whatever it matched. `db.exactlyOne`
/// reads one; everything that reads a list refuses it.
pub fn isTally(comptime Row: type) bool {
    return comptime isGrouped(Row) and
        fieldsOfKind(Row, .column).len == 0 and
        fieldsOfKind(Row, .parent).len == 0;
}

/// The entries of `nilo_aggregate`, in the order they were written. Empty for
/// a Row with none.
///
/// **Only the words are checked here.** Whether the column exists on the
/// table and whether the field's type can hold the answer are `shape.zig`'s,
/// because both need the table the Row borrows, and asking for it from here
/// would put this file inside its own borrow chain.
pub fn aggregatesOf(comptime Row: type) []const Aggregate {
    return comptime blk: {
        if (!@hasDecl(Row, aggregate_marker)) break :blk &.{};
        @setEvalBranchQuota(20_000);
        const decl = @field(Row, aggregate_marker);
        const D = @TypeOf(decl);
        const shape = "\n  It maps a field to what it computes: " ++
            "`pub const " ++ aggregate_marker ++ " = .{ .orders = .count, .owed = .{ .sum = .principal } };`.";
        if (@typeInfo(D) != .@"struct" or @typeInfo(D).@"struct".is_tuple) @compileError(
            "nilo: " ++ @typeName(Row) ++ "'s " ++ aggregate_marker ++ " is a " ++ @typeName(D) ++ "." ++ shape,
        );
        const entries = @typeInfo(D).@"struct".fields;
        if (entries.len == 0) @compileError(
            "nilo: " ++ @typeName(Row) ++ "'s " ++ aggregate_marker ++ " names nothing.\n" ++
                "  A grouped Row with no aggregate is the distinct values of its other fields, " ++
                "which is a question this module does not answer. Name what each group " ++
                "carries, or take the declaration out.",
        );
        var out: [entries.len]Aggregate = undefined;
        for (entries, 0..) |e, i| {
            if (fieldTypeOf(Row, e.name) == null) {
                const head = "nilo: " ++ @typeName(Row) ++ "'s " ++ aggregate_marker ++ " names `" ++
                    e.name ++ "`, which is not one of its fields.";
                if (nearest(Row, e.name)) |near| @compileError(head ++ "\n  Did you mean `" ++ near ++ "`?");
                @compileError(head ++ "\n  Its fields are: " ++ fieldList(Row) ++ ".");
            }
            if (isBeside(Row, e.name)) @compileError(
                "nilo: " ++ @typeName(Row) ++ " names `" ++ e.name ++ "` in both " ++
                    beside_marker ++ " and " ++ aggregate_marker ++ ".\n" ++
                    "  A field beside the columns is in no statement, and an aggregate is " ++
                    "read out of one. It is one or the other.",
            );
            out[i] = aggregateSpec(Row, e.name, @field(decl, e.name));
        }
        const frozen = out;
        break :blk &frozen;
    };
}

/// The one entry of `nilo_aggregate` that fills `name`, or null.
pub fn aggregateOf(comptime Row: type, comptime name: []const u8) ?Aggregate {
    return comptime blk: {
        if (!@hasDecl(Row, aggregate_marker)) break :blk null;
        if (!aggregateNamed(Row, name)) break :blk null;
        for (aggregatesOf(Row)) |a| {
            if (std.mem.eql(u8, a.field, name)) break :blk a;
        }
        unreachable;
    };
}

fn aggregateSpec(comptime Row: type, comptime field: []const u8, comptime said: anytype) Aggregate {
    comptime {
        const S = @TypeOf(said);
        const words = "`.count`, `.{ .count = .<column> }`, `.{ .count_distinct = .<column> }`, " ++
            "`.{ .sum = .<column> }`, `.{ .min = .<column> }`, `.{ .max = .<column> }` or " ++
            "`.{ .avg = .<column> }`, each but the first with a `.where` beside it if it " ++
            "reads only some of the rows";
        if (S == @TypeOf(.enum_literal)) {
            if (said == .count) return .{ .field = field, .kind = .count, .column = null };
            @compileError(
                "nilo: " ++ @typeName(Row) ++ "'s " ++ aggregate_marker ++ " says `." ++ field ++
                    " = ." ++ @tagName(said) ++ "`.\n" ++
                    "  Only `.count` stands alone, because it counts rows. Everything else " ++
                    "computes over a column and names it: " ++ words ++ ".",
            );
        }
        const info = switch (@typeInfo(S)) {
            .@"struct" => |s| s,
            else => @compileError(
                "nilo: " ++ @typeName(Row) ++ "'s " ++ aggregate_marker ++ " gives `." ++ field ++
                    "` a " ++ @typeName(S) ++ ".\n  It is " ++ words ++ ".",
            ),
        };
        // A `.where` beside the computation narrows what it reads, and is the
        // one other name an entry may carry.
        const filtered = !info.is_tuple and @hasField(S, "where");
        if (filtered and info.fields.len == 1) @compileError(
            "nilo: " ++ @typeName(Row) ++ "'s " ++ aggregate_marker ++ " gives `." ++ field ++
                "` a `.where` and nothing to compute.\n" ++
                "  The condition narrows a computation: `.{ .sum = .principal, .where = .{ .currency = \"IDR\" } }`. " ++
                "Rows that match are counted by naming a column that is never null: " ++
                "`.{ .count = .id, .where = … }`.",
        );
        if (info.is_tuple or info.fields.len != @as(usize, if (filtered) 2 else 1)) @compileError(
            "nilo: " ++ @typeName(Row) ++ "'s " ++ aggregate_marker ++ " gives `." ++ field ++
                "` more than one computation.\n  One field holds one answer: " ++ words ++ ".",
        );
        const word = if (std.mem.eql(u8, info.fields[0].name, "where")) info.fields[1].name else info.fields[0].name;
        const kind = std.meta.stringToEnum(dialect_mod.Aggregate, word) orelse @compileError(
            "nilo: " ++ @typeName(Row) ++ "'s " ++ aggregate_marker ++ " asks `." ++ field ++
                "` for `." ++ word ++ "`, which is not one it computes.\n  It is " ++ words ++
                ". Anything else is `db.raw`.",
        );
        const column = @field(said, word);
        if (@TypeOf(column) != @TypeOf(.enum_literal)) @compileError(
            "nilo: " ++ @typeName(Row) ++ "'s " ++ aggregate_marker ++ " gives `." ++ field ++
                "`'s `." ++ word ++ "` a " ++ @typeName(@TypeOf(column)) ++ ".\n" ++
                "  It names a column of the table, written as one: `.{ ." ++ word ++ " = .principal }`.",
        );
        return .{ .field = field, .kind = kind, .column = @tagName(column), .filtered = filtered };
    }
}

/// The column `nilo_via` names for a parent or children field, or null when
/// it names none. Only read here; `shape.zig` checks that the field is one
/// and that the column is where the direction says it is.
pub fn viaOf(comptime Row: type, comptime field: []const u8) ?[]const u8 {
    return comptime blk: {
        if (!@hasDecl(Row, via_marker)) break :blk null;
        const decl = @field(Row, via_marker);
        const D = @TypeOf(decl);
        if (@typeInfo(D) != .@"struct" or @typeInfo(D).@"struct".is_tuple) @compileError(
            "nilo: " ++ @typeName(Row) ++ "'s " ++ via_marker ++ " is a " ++ @typeName(D) ++ ".\n" ++
                "  It maps a parent or children field to the column its join goes through: " ++
                "`pub const " ++ via_marker ++ " = .{ .owner = .owner_staff_id };`.",
        );
        if (!@hasField(D, field)) break :blk null;
        const column = @field(decl, field);
        if (@TypeOf(column) != @TypeOf(.enum_literal)) @compileError(
            "nilo: " ++ @typeName(Row) ++ "'s " ++ via_marker ++ " gives `." ++ field ++ "` a " ++
                @typeName(@TypeOf(column)) ++ ".\n" ++
                "  It is the column the join goes through, written as a name: `." ++ field ++
                " = .owner_staff_id`.",
        );
        break :blk @tagName(column);
    };
}

/// The name a column is answered under in a statement over a shaped Row: the
/// path to its field, parents first, joined by a dot. `"id"` for a column of
/// the Row itself, `"customer.name"` for one read through a parent.
///
/// One function because three things have to agree on it: the `SELECT` list
/// that writes it, the `ORDER BY` that sorts by it, and the ordering a
/// request chooses at run time, which writes nothing else.
pub fn pathName(comptime path: []const []const u8) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (path, 0..) |part, i| out = out ++ (if (i == 0) "" else ".") ++ part;
        return out;
    }
}

/// Whether `T` is a **projection**: a Row that reads and owns no table
/// ([ADR 125](../docs/adr/125-a-row-that-owns-no-table.md)).
///
/// A `UNION ALL` over two tables, a `GROUP BY` rollup, a search across seven
/// tables, a card joining four — none of them is a table's shape, and until
/// this existed each one had to name a table it did not represent so that
/// `assertRow` would pass. That is a lie in the source, and the comment above
/// each saying the name is decoration does not make it a true one.
///
/// What it buys is a **sharper** refusal rather than a looser one: a
/// projection is fillable by `db.raw` and `tx.raw`, and everything that names
/// a table — `select`, `find`, `count`, `insert`, `update`, `delete`,
/// `db.checking`, the migration tool — now refuses it by name instead of
/// going to a live database looking for `events.body`.
pub fn isProjection(comptime T: type) bool {
    // `comptime` on the condition rather than on the block: it folds the
    // branch, so `@field` below is never analysed for a type that has no
    // marker to read.
    if (comptime !isRow(T)) return false;
    const decl = @field(T, marker);
    if (@TypeOf(decl) != @TypeOf(.enum_literal)) return false;
    // `==` rather than comparing `@tagName` with `std.mem.eql`: the compiler
    // settles two enum literals in one step, and the string version spends a
    // caller's backwards branches on a ten-byte comparison (ADR 126 is the
    // same lesson one module over).
    return decl == .projection;
}

/// The table `Row` reads, following a borrowed marker to the Row that names
/// one. Every other entry point goes through here, so the chain is walked in
/// exactly one place.
pub fn tableOf(comptime Row: type) []const u8 {
    return comptime specOf(Row).name;
}

/// A table name taken apart. `.name = "app.users"` is two identifiers and one
/// of them decides which schema the introspection query looks in, so the split
/// happens once, here, rather than in each of the seven places that write a
/// `FROM`.
pub const Qualified = struct {
    /// Null means *whatever `search_path` resolves to*, which is what a bare
    /// name has always meant and stays the default.
    schema: ?[]const u8,
    table: []const u8,
};

/// The table `Row` reads, split on the dot.
///
/// **One dot, and both halves have to be there.** `"app.users"` is a schema
/// and a table; `"users"` is a table; anything else — `"a.b.c"`, `".users"`,
/// `"app."` — is a mistake with a plausible cause and no plausible meaning, so
/// it stops here rather than reaching Postgres as a relation nobody named.
pub fn qualifiedOf(comptime Row: type) Qualified {
    return comptime qualifiedName(tableOf(Row), @typeName(Row) ++ " names");
}

/// The same split, for a table named as text rather than by a Row — which a
/// `.references` may do when the Row that owns it cannot be imported
/// ([ADR 181](../docs/adr/181-the-marker-has-two-kinds-of-word.md)).
/// `whose` is what the message calls the thing that wrote the name.
pub fn qualifiedName(comptime written: []const u8, comptime whose: []const u8) Qualified {
    return comptime blk: {
        const dot = std.mem.indexOfScalar(u8, written, '.') orelse
            break :blk .{ .schema = null, .table = written };

        const schema = written[0..dot];
        const table = written[dot + 1 ..];
        if (schema.len == 0 or table.len == 0 or
            std.mem.indexOfScalar(u8, table, '.') != null) @compileError(
            "nilo: " ++ whose ++ " the table `" ++ written ++
                "`, which is not a schema and a table.\n" ++
                "  A qualified name is `schema.table` — one dot, and something on " ++
                "either side of it. A table whose name really contains a dot is out " ++
                "of reach here and is `db.raw`.",
        );
        break :blk .{ .schema = schema, .table = table };
    };
}

/// The columns that identify a row, in the order the marker wrote them.
///
/// `.key` defaults to `id` when the Row has a field of that name and is
/// required when it does not — there is nothing to infer from a Row whose
/// identity column is `user_id`.
///
/// **One column or several, and the several is not an edge case.** Every
/// multi-tenant table is keyed `(tenant_id, id)` and every join table is keyed
/// by the two things it joins, so `.key = .{ .tenant_id, .id }` is the ordinary
/// shape rather than the exotic one. It is written as a tuple of column names,
/// which is the spelling `conflictColumns` already reads for an upsert target:
/// one way to name a set of columns, not two.
pub fn keysOf(comptime Row: type) []const []const u8 {
    return comptime blk: {
        const spec = specOf(Row);
        const named = spec.key orelse {
            if (!hasColumn(Row, "id")) @compileError(
                "nilo: " ++ @typeName(Row) ++ " has no column `id`, so its " ++
                    marker ++ " has to say which column identifies a row.\n" ++
                    "  Write `.key = .<column>` alongside `.name`, or " ++
                    "`.key = .{ .<column>, .<column> }` when it takes two.",
            );
            break :blk &[_][]const u8{"id"};
        };
        for (named) |column| {
            if (isBeside(Row, column)) @compileError(
                "nilo: " ++ @typeName(Row) ++ "'s key names `" ++ column ++ "`, which it " ++
                    "carries beside its columns.\n" ++
                    "  A field in " ++ beside_marker ++ " is in no column and no statement, " ++
                    "and a key is what a statement finds a row by. Name a column.",
            );
            if (!hasColumn(Row, column)) @compileError(
                "nilo: " ++ @typeName(Row) ++ "'s key names the column `" ++ column ++
                    "`, which is not one of its columns.\n" ++
                    "  The key has to be a column the Row reads, or nothing can " ++
                    "identify what was read.",
            );
        }
        break :blk named;
    };
}

/// The one column that identifies a row, for the callers that can only mean
/// one. A composite key is a Refusal here rather than a silent first column:
/// picking `tenant_id` out of `(tenant_id, id)` and calling it the key would
/// find the wrong row and report nothing.
pub fn keyOf(comptime Row: type) []const u8 {
    return comptime blk: {
        const keys = keysOf(Row);
        if (keys.len != 1) @compileError(
            "nilo: " ++ @typeName(Row) ++ " is keyed by " ++ keyList(Row) ++
                ", and this call takes a key of one column.\n" ++
                "  A statement that identifies a row by several columns names them " ++
                "all: `db.find(Row, c, .{ ." ++ keys[0] ++ " = …, ." ++ keys[1] ++
                " = … })`.",
        );
        break :blk keys[0];
    };
}

/// Whether `column` is one of the columns the key is made of.
pub fn isKey(comptime Row: type, comptime column: []const u8) bool {
    return comptime blk: {
        for (keysOf(Row)) |name| {
            if (std.mem.eql(u8, name, column)) break :blk true;
        }
        break :blk false;
    };
}

/// The key's columns as one readable line, for a message.
pub fn keyList(comptime Row: type) []const u8 {
    return comptime blk: {
        var out: []const u8 = "";
        for (keysOf(Row), 0..) |c, i| {
            out = out ++ (if (i == 0) "" else ", ") ++ "`" ++ c ++ "`";
        }
        break :blk out;
    };
}

/// Whether this program builds the table `Row` reads, or only reads it
/// ([ADR 130](../docs/adr/130-a-table-this-program-reads-and-does-not-build.md)).
///
/// **The default is true, and the word exists for a port.** A `.references`
/// names the Row that owns the table, so a foreign key onto `staff` needs a
/// `Staff` Row — and the moment one exists the migration tool wants to create
/// `staff`, which has been there for a year with twenty columns this program
/// has never read. That made the tool all-or-nothing on a schema a program
/// owns part of: usable at 59 tables of 59, unusable at 47 of 59.
///
/// The key the marker names, or `id` when there is a column by that name, or
/// nothing: `keysOf` without its refusal. For a question that is not "which
/// row", such as which columns an insert may leave out, where a Row with no
/// key is still a Row an `insertOrIgnore` may write (ADR 151).
pub fn keysIfAnyOf(comptime Row: type) []const []const u8 {
    return comptime blk: {
        if (specOf(Row).key) |named| break :blk named;
        if (hasColumn(Row, "id")) break :blk &[_][]const u8{"id"};
        break :blk &.{};
    };
}

/// What `.managed = false` changes is only who builds it. The Row is still a
/// Row: `.references` may point at it, `db.checking` still holds it against
/// the live schema, and every statement reads it the same way. `plan`,
/// `createMissing` and `generate` leave it alone.
pub fn managedOf(comptime Row: type) bool {
    return comptime specOf(Row).managed;
}

/// The columns `Row` reads, in the order it declares them. This is the
/// `SELECT` list and the order results are filled in, so the two cannot drift.
pub fn columnsOf(comptime Row: type) []const []const u8 {
    return comptime blk: {
        assertRow(Row);
        const fields = @typeInfo(Row).@"struct".fields;
        var out: [fields.len][]const u8 = undefined;
        var n: usize = 0;
        for (fields) |f| {
            // A field beside the columns is not one (ADR 178), and neither
            // is a parent, children or an aggregate (ADR 218).
            if (kindWith(Row, f.name, f.type) != .column) continue;
            out[n] = f.name;
            n += 1;
        }
        const frozen = out[0..n].*;
        break :blk &frozen;
    };
}

/// `Row` with every `Str` replaced by `[]const u8`.
///
/// This is the shape a row takes when it is read one at a time: its text
/// belongs to the driver's read buffer and is good only until the next row
/// is pulled. `Str` means *text that lives as long as the request*, with no
/// asterisk — so text that does not is not called one. The type tells the
/// truth rather than hiding the rule behind a name that promises safety
/// (ADR 036).
///
/// It is the same rule `Body.read` already followed by returning `[]u8`.
/// Nothing here is new; it is applied one layer over.
///
/// The result carries no `nilo_table`, so it is not itself a Row and cannot
/// be handed back to `select`. That is deliberate: what you may do with a
/// borrowed row is read it before the next `next()`, and nothing else.
pub fn Borrowed(comptime Row: type) type {
    return comptime blk: {
        assertRow(Row);
        const fields = @typeInfo(Row).@"struct".fields;
        var names: [fields.len][]const u8 = undefined;
        var types: [fields.len]type = undefined;
        for (fields, 0..) |f, i| {
            names[i] = f.name;
            types[i] = switch (kindWith(Row, f.name, f.type)) {
                // A field beside the columns is never read out of the buffer,
                // so it keeps its own type and its default fills it (ADR 178).
                .beside => f.type,
                // A parent is borrowed whole, the same rule one level down: its
                // text dies at the next row like the Row's own (ADR 218).
                .parent => if (@typeInfo(f.type) == .optional)
                    ?Borrowed(parentRowOf(f.type).?)
                else
                    Borrowed(f.type),
                // Read by a second statement after the rows it belongs to,
                // which a stream never reaches; `db.stream` refuses the Row
                // before this type is ever built. Kept so the refusal is the
                // one the caller meets rather than one about this struct.
                .children => f.type,
                .column, .aggregate, .count => borrowedType(f.type),
            };
        }
        const frozen_names = names;
        const frozen_types = types;
        // The field order is the Row's, which is also the `SELECT` list's,
        // which is also the order columns are read back in. One order, kept
        // in one place, so the three cannot drift.
        break :blk @Struct(.auto, null, &frozen_names, &frozen_types, &@splat(.{}));
    };
}

/// What one column's type becomes when the row is borrowed. Only `Str` moves;
/// an `i64` is a value and has nothing to outlive.
fn borrowedType(comptime T: type) type {
    comptime {
        if (T == core.Str) return []const u8;
        if (T == ?core.Str) return ?[]const u8;
        // A `Decimal` is digits rather than a number, so it points into the
        // read buffer exactly as text does and moves for the same reason. It
        // becomes `[]const u8` rather than a borrowed `Decimal`, because a
        // type whose whole content is a slice should say out loud how long
        // that slice is good for.
        if (types_mod.asText(T) != null) return if (@typeInfo(T) == .optional) ?[]const u8 else []const u8;
        return T;
    }
}

/// Whether `Row` reads a column by that name. The one question the where
/// walker asks, and the one that turns a typo into a Refusal.
pub fn hasColumn(comptime Row: type, comptime column: []const u8) bool {
    return comptime blk: {
        if (fieldTypeOf(Row, column) == null) break :blk false;
        break :blk isColumnField(Row, column);
    };
}

/// Whether the table `Row` reads has a column by that name, whether or not
/// `Row` carries it: the owner's columns, for a narrower Row. What `.order`
/// asks, because a tiebreak the response does not show is still a column the
/// statement can sort by. A projection owns no table and answers only for
/// itself.
pub fn tableHasColumn(comptime Row: type, comptime column: []const u8) bool {
    return comptime blk: {
        const Owner = ownerOf(Row);
        break :blk hasColumn(Owner, column);
    };
}

/// The type `Row` reads a column into.
pub fn ColumnType(comptime Row: type, comptime column: []const u8) type {
    comptime {
        for (@typeInfo(Row).@"struct".fields) |f| {
            if (std.mem.eql(u8, f.name, column)) return f.type;
        }
        @compileError("nilo: " ++ @typeName(Row) ++ " has no column `" ++ column ++ "`.");
    }
}

/// The column name closest to `wrong`, when one is close enough to be worth
/// naming. A message that says what was meant is the difference between a
/// Refusal that helps and one that only stops you (ADR 026).
pub fn nearest(comptime Row: type, comptime wrong: []const u8) ?[]const u8 {
    return comptime blk: {
        var best: ?[]const u8 = null;
        var best_distance: usize = std.math.maxInt(usize);
        for (@typeInfo(Row).@"struct".fields) |f| {
            const d = distance(wrong, f.name);
            if (d < best_distance) {
                best_distance = d;
                best = f.name;
            }
        }
        // Past a third of the name, "did you mean" is a guess rather than a
        // help, and a wrong suggestion costs more than none.
        const room = @max(wrong.len, 1) / 3 + 1;
        break :blk if (best_distance <= room) best else null;
    };
}

/// The message a column that does not exist stops with. One function so that
/// every caller — the where walker, the order list, an update's `set` — says
/// it the same way.
pub fn noSuchColumn(
    comptime Row: type,
    comptime wrong: []const u8,
    comptime what: []const u8,
) noreturn {
    comptime {
        if (isBeside(Row, wrong)) @compileError(
            "nilo: " ++ @typeName(Row) ++ " carries `" ++ wrong ++ "` beside its columns, " ++
                "and " ++ what ++ " asks for it as one.\n" ++
                "  A field named in " ++ beside_marker ++ " is filled by the caller after " ++
                "the read, and no statement reads or writes it. Take it out of " ++ what ++
                ", or out of " ++ beside_marker ++ " if it is a column after all.",
        );
        // A field that is there and is not a column: said as what it is, so
        // the caller learns the spelling that does reach it (ADR 218).
        if (fieldTypeOf(Row, wrong) != null) switch (kindOf(Row, wrong)) {
            .parent => @compileError(
                "nilo: `" ++ wrong ++ "` on " ++ @typeName(Row) ++ " is a parent, asked for in " ++
                    what ++ " as if it were a column.\n" ++
                    "  A parent is a row, and what " ++ what ++ " can name is one of its columns: `." ++
                    wrong ++ " = .{ .<column> = … }`.",
            ),
            .children => @compileError(
                "nilo: `" ++ wrong ++ "` on " ++ @typeName(Row) ++ " is a list of children, asked for in " ++
                    what ++ ".\n" ++
                    "  The children are read after the rows they belong to, so no statement over " ++
                    @typeName(Row) ++ " can see them. To keep the rows that have a matching child, " ++
                    "write `.exists = .{ .{ .in = <ChildRow>, .where = .{ … } } }`.",
            ),
            .aggregate => @compileError(
                "nilo: `" ++ wrong ++ "` on " ++ @typeName(Row) ++ " is an aggregate, asked for in " ++
                    what ++ ".\n" ++
                    "  It is computed over each group, so it can be sorted by and filtered on from " ++
                    "`.order` and `.where`, and from nowhere that reads one row at a time.",
            ),
            .count => @compileError(
                "nilo: `" ++ wrong ++ "` on " ++ @typeName(Row) ++ " is a count of the rows pointing " ++
                    "back, asked for in " ++ what ++ ".\n" ++
                    "  It is computed by a subquery, so it can be sorted by and filtered on from " ++
                    "`.order` and `.where` of a read, and from nowhere else.",
            ),
            .column, .beside => {},
        };
        const head = "nilo: " ++ @typeName(Row) ++ " has no column `" ++ wrong ++
            "`, asked for in " ++ what ++ ".";
        if (nearest(Row, wrong)) |near| {
            @compileError(head ++ "\n  Did you mean `" ++ near ++ "`?");
        }
        @compileError(head ++ "\n  Its columns are: " ++ columnList(Row) ++ ".");
    }
}

/// The columns of `Row` as one readable line, for a message that has no
/// better suggestion to make than the whole list.
pub fn columnList(comptime Row: type) []const u8 {
    return comptime blk: {
        var out: []const u8 = "";
        for (columnsOf(Row), 0..) |c, i| {
            out = out ++ (if (i == 0) "" else ", ") ++ "`" ++ c ++ "`";
        }
        break :blk out;
    };
}

// -- the marker, and the chain it may point along ------------------------

const Spec = struct {
    name: []const u8,
    /// The key's columns, or null when the marker said nothing and `id` is
    /// the answer. A list rather than a name because a key spanning two
    /// columns is the ordinary shape of a join table and of every
    /// multi-tenant one.
    key: ?[]const []const u8,
    /// Whether this program **builds** the table, as against merely reading
    /// it ([ADR 130](../docs/adr/130-a-table-this-program-reads-and-does-not-build.md)).
    /// True unless the Row says otherwise, because that is what every Row
    /// written before this meant.
    managed: bool = true,
};

/// What may be written in the marker. `.name` and `.key` are read here;
/// `sql/table.zig` reads the rest, and this list is what stops a typo in
/// one of them being silently ignored. One list rather than a check in each
/// file, because a word allowed in one place and refused in another is the
/// mistake this whole arrangement exists to make impossible.
const allowed = [_][]const u8{
    "name",    "key",        "unique", "index",
    "default", "references", "was",    "managed",
    "check",   "trigger",    "filled",
};

/// The table spec `Row` resolves to, following `nilo_table = OtherRow` until
/// a spec that names a table is reached. Every borrowed Row is checked against
/// the one it borrows from on the way past, so the check cannot be skipped by
/// asking a question that does not need it.
/// The Row at the end of the borrow chain: the one that names a table rather
/// than another Row.
///
/// **This is the only Row allowed to describe the table**, which is what keeps
/// a query type from becoming a migration file in disguise
/// ([ADR 123](../docs/adr/123-a-migration-is-a-diff-against-a-snapshot.md)).
/// Nothing enforces it, because the language does: a borrowing Row's marker is
/// a `type`, and there is nowhere on a type to write `.unique`.
pub fn ownerOf(comptime Row: type) type {
    comptime {
        assertRow(Row);
        var current = Row;
        var depth: usize = 0;
        while (depth < max_borrow_depth) : (depth += 1) {
            const decl = @field(current, marker);
            // A projection owns no table, so every question that starts
            // "which table" ends here rather than at a live database looking
            // for a column of a table nobody meant (ADR 125). This is the
            // one funnel: `tableOf`, `keyOf` and `qualifiedOf` all come
            // through, and so does everything in `table.zig`.
            if (@TypeOf(decl) == @TypeOf(.enum_literal)) {
                if (decl != .projection) @compileError(
                    "nilo: " ++ @typeName(current) ++ "'s " ++ marker ++ " is `." ++
                        @tagName(decl) ++ "`, which is not a word it takes.\n" ++
                        "  The only one is `." ++ projection_word ++ "`, for a Row that no " ++
                        "table has the shape of. Otherwise it is `.{ .name = \"<table>\" }` " ++
                        "or another Row.",
                );
                @compileError(
                    "nilo: " ++ @typeName(Row) ++ " is a projection, so it has no table to " ++
                        (if (current == Row) "read." else "borrow from " ++ @typeName(current) ++ ".") ++
                        "\n  A projection is filled by `db.raw` and `tx.raw` and by nothing " ++
                        "else: everything here that writes its own SQL has to name a table, " ++
                        "and this Row is the shape of an answer rather than of a table. Give " ++
                        "the statement to `db.raw`, or write `." ++ marker ++
                        " = .{ .name = \"<table>\" }` if there really is one.",
                );
            }
            if (@TypeOf(decl) == type) {
                if (!isRow(decl)) @compileError(
                    "nilo: " ++ @typeName(current) ++ "'s " ++ marker ++ " names " ++
                        @typeName(decl) ++ ", which is not a Row.\n" ++
                        "  A Row borrows a table from another Row, or names one itself " ++
                        "with `.{ .name = \"…\" }`.",
                );
                assertSubset(current, decl);
                current = decl;
                continue;
            }
            assertDescribesItsTable(current);
            return current;
        }
        @compileError(
            "nilo: " ++ @typeName(Row) ++ " borrows a table through more than " ++
                std.fmt.comptimePrint("{d}", .{max_borrow_depth}) ++ " Rows.\n" ++
                "  A Row that borrows from itself, directly or in a ring, never " ++
                "reaches a table.",
        );
    }
}

fn specOf(comptime Row: type) Spec {
    comptime {
        const owner = ownerOf(Row);
        return readSpec(owner, @field(owner, marker));
    }
}

fn readSpec(comptime Row: type, comptime decl: anytype) Spec {
    comptime {
        // Every field of the marker is compared against the six words allowed
        // in it, and every Row in a schema comes through here — so a program
        // with tens of tables spends the default 1,000 backwards branches on
        // `std.mem.eql` alone, and the compile stops in a file of std's
        // ([ADR 126](../docs/adr/126-a-check-pays-for-its-own-branches.md)).
        // Generous rather than exact, for the reason that ADR gives: the
        // budget is the caller's whole evaluation and this raises a ceiling
        // rather than spending an allowance.
        @setEvalBranchQuota(50_000);
        const D = @TypeOf(decl);
        if (@typeInfo(D) != .@"struct") @compileError(
            "nilo: " ++ @typeName(Row) ++ "'s " ++ marker ++ " is a " ++
                @typeName(D) ++ ".\n" ++
                "  It is either `.{ .name = \"users\" }` or another Row to take " ++
                "the table from.",
        );
        if (!@hasField(D, "name")) @compileError(
            "nilo: " ++ @typeName(Row) ++ "'s " ++ marker ++ " does not say `.name`.\n" ++
                "  The table name is written rather than guessed from the type — " ++
                "`User` to `users` reads well until `Category`.",
        );
        for (@typeInfo(D).@"struct".fields) |f| {
            for (allowed) |ok| {
                if (std.mem.eql(u8, f.name, ok)) break;
            } else @compileError(
                "nilo: " ++ @typeName(Row) ++ "'s " ++ marker ++ " sets `." ++ f.name ++
                    "`, which is not part of it.\n" ++
                    "  It takes `.name`, and `.key` when the identity column is not " ++
                    "`id`. The words a migration reads are `.unique`, `.index`, " ++
                    "`.default`, `.references`, `.was`, `.check` and `.trigger`; " ++
                    "everything else about the table is SQL in a step, which nilo " ++
                    "will not touch.",
            );
        }
        const key: ?[]const []const u8 = if (@hasField(D, "key")) keyNames(Row, decl.key) else null;
        const managed: bool = if (@hasField(D, "managed")) decl.managed else true;
        return .{ .name = decl.name, .key = key, .managed = managed };
    }
}

/// The columns `.key` names, out of `.id` or `.{ .tenant_id, .id }`.
///
/// The same two spellings `conflictColumns` reads for an upsert target, and
/// deliberately so: a set of columns is written one way in this repository,
/// and a second way to say it is a second thing to remember.
fn keyNames(comptime Row: type, comptime written: anytype) []const []const u8 {
    comptime {
        const K = @TypeOf(written);
        if (K == @TypeOf(.enum_literal)) {
            const one = [_][]const u8{@tagName(written)};
            return &one;
        }
        const info = switch (@typeInfo(K)) {
            .@"struct" => |s| s,
            else => notAKey(Row, K),
        };
        if (!info.is_tuple) notAKey(Row, K);
        if (info.fields.len == 0) @compileError(
            "nilo: " ++ @typeName(Row) ++ "'s `.key` is empty.\n" ++
                "  A row with nothing identifying it cannot be found, updated in a " ++
                "batch, or pointed at by a `.references`. Name the column: " ++
                "`.key = .id`.",
        );
        // One column written as a tuple is the same key written the long way,
        // and reading it as one keeps `db.find` taking a bare value for it.
        var names: []const []const u8 = &.{};
        for (info.fields) |f| {
            const value = @field(written, f.name);
            if (@TypeOf(value) != @TypeOf(.enum_literal)) notAKey(Row, K);
            for (names) |already| {
                if (std.mem.eql(u8, already, @tagName(value))) @compileError(
                    "nilo: " ++ @typeName(Row) ++ "'s `.key` names `" ++ @tagName(value) ++
                        "` twice.\n" ++
                        "  Each column of a key identifies a different part of the row.",
                );
            }
            names = names ++ &[_][]const u8{@tagName(value)};
        }
        return names;
    }
}

fn notAKey(comptime Row: type, comptime K: type) noreturn {
    @compileError(
        "nilo: " ++ @typeName(Row) ++ "'s `.key` is a " ++ @typeName(K) ++ ".\n" ++
            "  It is the column that identifies a row, written as a name — `.key = .id` " ++
            "— or `.key = .{ .tenant_id, .id }` for a key spanning two of them.",
    );
}

/// A Row that names its table describes that table, one field per column,
/// and that is what the migration tool and the schema check read it as. So a
/// parent, children, `nilo_aggregate` or `nilo_via` on one is refused: each
/// belongs to a narrower Row, which reads the table without describing it
/// (ADR 218).
fn assertDescribesItsTable(comptime Row: type) void {
    comptime {
        const narrower = "  A Row that names its table describes it column by column, which is what " ++
            "the migration tool builds from. Read the rest through a narrower Row: " ++
            "`pub const " ++ marker ++ " = " ++ @typeName(Row) ++ ";`.";
        for (@typeInfo(Row).@"struct".fields) |f| {
            const what = switch (kindWith(Row, f.name, f.type)) {
                .parent => "a parent",
                .children => "a list of children",
                else => continue,
            };
            @compileError(
                "nilo: " ++ @typeName(Row) ++ " names its table and reads `" ++ f.name ++ "` as " ++
                    what ++ ".\n" ++ narrower,
            );
        }
        for ([_][]const u8{ aggregate_marker, via_marker, children_marker }) |decl| {
            if (@hasDecl(Row, decl)) @compileError(
                "nilo: " ++ @typeName(Row) ++ " names its table and says `" ++ decl ++ "`.\n" ++ narrower,
            );
        }
    }
}

/// Every column a borrowed Row reads has to be one the Row it borrows from
/// reads, at the same type. This is the check the overload is worth having:
/// without it a narrower Row's typo would live until a live Postgres saw it.
fn assertSubset(comptime Narrow: type, comptime Wide: type) void {
    comptime {
        // The aggregate list first: a field it misspells reads as a column
        // the table has not got, and the misspelling is the thing to say.
        if (@hasDecl(Narrow, aggregate_marker)) _ = aggregatesOf(Narrow);
        for (@typeInfo(Narrow).@"struct".fields) |f| {
            // Carried beside the columns rather than read, so the table it
            // borrows need not have it (ADR 178). A parent, children and an
            // aggregate are not columns of this table either, and
            // `shape.zig` checks each against the table it does read
            // (ADR 218).
            if (kindWith(Narrow, f.name, f.type) != .column) continue;
            if (!hasColumn(Wide, f.name)) {
                const head = "nilo: " ++ @typeName(Narrow) ++ " reads `" ++ f.name ++
                    "`, which " ++ @typeName(Wide) ++ " does not have.";
                if (nearest(Wide, f.name)) |near| {
                    @compileError(head ++ "\n  Did you mean `" ++ near ++ "`?");
                }
                @compileError(head ++ "\n  Its columns are: " ++ columnList(Wide) ++ ".");
            }
            const theirs = ColumnType(Wide, f.name);
            if (f.type != theirs) @compileError(
                "nilo: " ++ @typeName(Narrow) ++ " reads `" ++ f.name ++ "` as " ++
                    @typeName(f.type) ++ ", and " ++ @typeName(Wide) ++ " reads it as " ++
                    @typeName(theirs) ++ ".\n" ++
                    "  Two Rows over one column have to agree, or one of them is " ++
                    "wrong about the table.",
            );
        }
    }
}

/// Stop, in this module's own words, if `T` is not a Row. Public because
/// `db.zig` is the first thing a mistyped call reaches, and being told
/// "`User` has no `nilo_table`" beats being told a field is missing from
/// somewhere three functions further in.
pub fn assertRow(comptime T: type) void {
    comptime {
        if (@typeInfo(T) != .@"struct") @compileError(
            "nilo: " ++ @typeName(T) ++ " is not a struct, so it cannot be a Row.\n" ++
                "  A Row is a struct of your own, one field per column.",
        );
        if (!@hasDecl(T, marker)) @compileError(
            "nilo: " ++ @typeName(T) ++ " is not a Row — it has no `" ++ marker ++ "`.\n" ++
                "  Add `pub const " ++ marker ++ " = .{ .name = \"<table>\" };` to it, " ++
                "`= <OtherRow>` to read the same table as another Row, or `= ." ++
                projection_word ++ "` when no table has this shape and `db.raw` is what " ++
                "fills it (ADR 125).",
        );
    }
}

/// Levenshtein, for `nearest`. Comptime and over short names, so the square
/// table is cheaper than being clever about it.
fn distance(comptime a: []const u8, comptime b: []const u8) usize {
    comptime {
        @setEvalBranchQuota(10_000 + 64 * (a.len + 1) * (b.len + 1));
        var prev: [64]usize = undefined;
        var cur: [64]usize = undefined;
        if (a.len >= prev.len or b.len >= prev.len) return std.math.maxInt(usize);

        for (0..b.len + 1) |j| prev[j] = j;
        for (a, 0..) |ca, i| {
            cur[0] = i + 1;
            for (b, 0..) |cb, j| {
                const swap: usize = if (ca == cb) 0 else 1;
                cur[j + 1] = @min(@min(cur[j] + 1, prev[j + 1] + 1), prev[j] + swap);
            }
            prev = cur;
        }
        return prev[b.len];
    }
}

// -- tests ---------------------------------------------------------------

const testing = std.testing;

const User = struct {
    pub const nilo_table = .{ .name = "users", .key = .id };

    id: i64,
    email: []const u8,
    age: i32,
};

const UserCard = struct {
    pub const nilo_table = User;

    id: i64,
    email: []const u8,
};

const Membership = struct {
    pub const nilo_table = .{ .name = "memberships", .key = .user_id };

    user_id: i64,
    plan: []const u8,
};

const Timeline = struct {
    pub const nilo_table = .projection;

    at: i64,
    kind: []const u8,
};

test "a Row names the table it reads" {
    try testing.expectEqualStrings("users", tableOf(User));
    try testing.expectEqualStrings("id", keyOf(User));
}

test "a projection is a Row, and is the one Row that names no table" {
    // Both halves matter. It has to pass `assertRow`, or `db.raw` would not
    // take it; and it has to be recognisable as a projection, or everything
    // that writes SQL would go looking for a table called `.projection`
    // (ADR 125).
    try testing.expect(isRow(Timeline));
    try testing.expect(isProjection(Timeline));

    // And the Rows that do own a table are not projections, including the one
    // that borrows: a borrowed marker is a `type`, not a word.
    try testing.expect(!isProjection(User));
    try testing.expect(!isProjection(UserCard));
    try testing.expect(!isProjection(struct { id: i64 }));
}

test "a key that is not id has to be written, and is" {
    try testing.expectEqualStrings("memberships", tableOf(Membership));
    try testing.expectEqualStrings("user_id", keyOf(Membership));
}

const Seat = struct {
    pub const nilo_table = .{ .name = "seats", .key = .{ .tenant_id, .id } };

    tenant_id: i64,
    id: i64,
    label: []const u8,
};

test "a key can span two columns, which is what every multi-tenant table is" {
    const keys = keysOf(Seat);
    try testing.expectEqual(@as(usize, 2), keys.len);
    try testing.expectEqualStrings("tenant_id", keys[0]);
    try testing.expectEqualStrings("id", keys[1]);
}

test "the key's columns keep the order the marker wrote them in" {
    // Order is not decoration: it is the order of the index the PRIMARY KEY
    // creates, so `(tenant_id, id)` and `(id, tenant_id)` serve different
    // lookups. The Row's own field order is the other one, and is not it.
    const Reversed = struct {
        pub const nilo_table = .{ .name = "seats", .key = .{ .id, .tenant_id } };
        tenant_id: i64,
        id: i64,
    };
    try testing.expectEqualStrings("id", keysOf(Reversed)[0]);
    try testing.expectEqualStrings("tenant_id", keysOf(Reversed)[1]);
}

test "a key of one column written as a tuple is the same key written the long way" {
    const Long = struct {
        pub const nilo_table = .{ .name = "users", .key = .{.id} };
        id: i64,
    };
    try testing.expectEqual(@as(usize, 1), keysOf(Long).len);
    // And it still reaches the callers that can only mean one column, which is
    // what makes the two spellings one key rather than two shapes.
    try testing.expectEqualStrings("id", keyOf(Long));
}

test "isKey answers for every column of a composite key, not just the first" {
    try testing.expect(isKey(Seat, "tenant_id"));
    try testing.expect(isKey(Seat, "id"));
    try testing.expect(!isKey(Seat, "label"));
}

test "the key reads as a sentence, for the messages that have to name it" {
    try testing.expectEqualStrings("`tenant_id`, `id`", keyList(Seat));
    try testing.expectEqualStrings("`id`", keyList(User));
}

test "a narrower Row reads the table of the Row it borrows from" {
    try testing.expectEqualStrings("users", tableOf(UserCard));
    try testing.expectEqualStrings("id", keyOf(UserCard));
}

test "the columns come out in the order the Row declares them" {
    const columns = columnsOf(User);
    try testing.expectEqual(@as(usize, 3), columns.len);
    try testing.expectEqualStrings("id", columns[0]);
    try testing.expectEqualStrings("email", columns[1]);
    try testing.expectEqualStrings("age", columns[2]);
}

test "a borrowed Row keeps its own column list rather than the wider one" {
    try testing.expectEqual(@as(usize, 2), columnsOf(UserCard).len);
    try testing.expectEqual(@as(usize, 3), columnsOf(User).len);
}

const Attachment = struct { id: i64, filename: []const u8 };

/// A comment line on a timeline, carrying its files — which no column holds
/// and the caller fills after the read (ADR 178).
const CommentLine = struct {
    pub const nilo_table = .{ .name = "comments", .key = .id };
    pub const nilo_beside = .{ .attachments, .mine };

    id: i64,
    body: []const u8,
    attachments: []const Attachment = &.{},
    mine: bool = false,
};

/// The same idea on a Row that borrows a table: the field beside the columns
/// need not be one the wider Row has.
const CommentCard = struct {
    pub const nilo_table = CommentLine;
    pub const nilo_beside = .{.attachments};

    id: i64,
    attachments: []const Attachment = &.{},
};

test "a field beside the columns is on the Row and in no column list" {
    const beside = comptime besideOf(CommentLine);
    try testing.expectEqual(@as(usize, 2), beside.len);
    try testing.expectEqualStrings("attachments", beside[0]);
    try testing.expectEqualStrings("mine", beside[1]);
    try testing.expectEqual(@as(usize, 0), comptime besideOf(User).len);

    // The SELECT list, and therefore what a read fills by position, is the
    // columns only — in the Row's order, with the beside ones stepped over.
    const columns = comptime columnsOf(CommentLine);
    try testing.expectEqual(@as(usize, 2), columns.len);
    try testing.expectEqualStrings("id", columns[0]);
    try testing.expectEqualStrings("body", columns[1]);
    try testing.expectEqualStrings("`id`, `body`", columnList(CommentLine));

    // Not a column, so a `.where` or a `.set` naming it is a Refusal rather
    // than a statement asking Postgres for a column it has never had.
    try testing.expect(!hasColumn(CommentLine, "attachments"));
    try testing.expect(comptime isBeside(CommentLine, "mine"));
    try testing.expect(!comptime isBeside(CommentLine, "body"));

    // And a read leaves it at the default the field declares.
    try testing.expectEqual(@as(usize, 0), comptime besideDefault(CommentLine, "attachments").len);
    try testing.expectEqual(false, comptime besideDefault(CommentLine, "mine"));
}

test "a borrowed Row may carry a field beside the columns its table lacks" {
    try testing.expectEqualStrings("comments", tableOf(CommentCard));
    try testing.expectEqual(@as(usize, 1), comptime columnsOf(CommentCard).len);
}

test "a streamed row keeps a beside field's own type rather than borrowing it" {
    // `body` is text and moves to the read buffer's `[]const u8`; the field
    // beside the columns is never in that buffer, so it stays what it is.
    const B = Borrowed(CommentLine);
    try testing.expectEqual([]const Attachment, @FieldType(B, "attachments"));
    try testing.expectEqual(bool, @FieldType(B, "mine"));
}

test "a column is looked up by name and by type" {
    try testing.expect(hasColumn(User, "email"));
    try testing.expect(!hasColumn(User, "emial"));
    try testing.expectEqual(i32, ColumnType(User, "age"));
}

test "a near miss is named, and something unrelated is not guessed at" {
    try testing.expectEqualStrings("email", nearest(User, "emial").?);
    try testing.expectEqualStrings("age", nearest(User, "ag").?);
    try testing.expectEqual(@as(?[]const u8, null), nearest(User, "created_at"));
}

test "the column list reads as a sentence when there is nothing to suggest" {
    try testing.expectEqualStrings("`id`, `email`, `age`", columnList(User));
}

test "a table name splits on the dot into a schema and a table" {
    const Qualified_ = struct {
        pub const nilo_table = .{ .name = "app.users", .key = .id };
        id: i64,
    };
    const q = qualifiedOf(Qualified_);
    try testing.expectEqualStrings("app", q.schema.?);
    try testing.expectEqualStrings("users", q.table);
}

test "a bare name has no schema, which means whatever the search_path says" {
    const q = qualifiedOf(User);
    try testing.expectEqual(@as(?[]const u8, null), q.schema);
    try testing.expectEqualStrings("users", q.table);
    // `tableOf` still answers what was written, because that is what a
    // message about the Row should say.
    try testing.expectEqualStrings("users", tableOf(User));
}

test "a struct that is not a Row is not mistaken for one" {
    try testing.expect(isRow(User));
    try testing.expect(!isRow(struct { id: i64 }));
    try testing.expect(!isRow(i64));
}
