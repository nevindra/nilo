//! A statement over a shaped Row: a parent joined in, children read after, a
//! group counted and summed
//! ([ADR 218](../docs/adr/218-a-row-may-carry-its-parent-its-children-or-a-sum.md)).
//!
//! ```zig
//! const CustomerName = struct {
//!     pub const nilo_table = Customer;
//!     name: Str,
//! };
//!
//! const OrderCard = struct {
//!     pub const nilo_table = Order;
//!     id: i64,
//!     total: i64,
//!     customer: CustomerName,
//! };
//! ```
//! ```sql
//! SELECT "orders"."id" AS "id", "orders"."total" AS "total",
//!        "customer"."name" AS "customer.name"
//! FROM "orders"
//! JOIN "customers" AS "customer" ON "customer"."id" = "orders"."customer_id"
//! ```
//!
//! **ADR 036 drew its line at one table, and ADR 218 said what the line
//! protects**: the Row describes the answer, and `.limit` counts Rows. This
//! file is the three shapes that keep both, and each keeps them for its own
//! reason.
//!
//! - **A parent** is the row a reference points at, and a reference points at
//!   one row or none. Joining it changes neither the number of rows nor what
//!   one row is: it adds the columns the Row asked for, under the field that
//!   asked.
//! - **Children** are the rows that point back, and there can be any number of
//!   them. So they are never joined: they are a second statement, one for the
//!   whole list, and `.limit` has already counted the parents by the time it
//!   runs.
//! - **A grouped Row** is one row per group, and says so in its own type. What
//!   `.limit` counts is groups because that is what the Row is.
//!
//! `nilo_children` says the rest about the rows pointing back: a children
//! field's order and condition, and a count of them read by a correlated
//! subquery, which keeps both properties the way a parent does, one number
//! per row of the table.
//!
//! **The call site did not change.** It is `db.select`, `db.page`, `db.find`
//! with `.where`, `.order` and `.limit`, and there is still no `.join` and no
//! `.group_by` to write there. A chain of calls is what ADR 036 refused, and
//! the refusal stands. What moved is what a Row may say about itself.
//!
//! **Every column is answered under the path to its field**: `"id"`,
//! `"customer.name"`. That is what lets `.order` sort by a parent's column
//! or by a sum without a second vocabulary (an `ORDER BY` of a bare name
//! means the answer's column of that name in both databases), and it is why
//! every column is qualified: two tables joined both have an `id`.

const std = @import("std");
const row_mod = @import("row.zig");
const table_mod = @import("table.zig");
const where_mod = @import("where.zig");
const dialect_mod = @import("dialect.zig");
const types_mod = @import("types.zig");
const statement = @import("statement.zig");
const ordering = @import("ordering.zig");

const Statement = statement.Statement;
const Direction = statement.Direction;

/// The alias the numbered keys of a children statement are read under. `#`
/// cannot begin a field name, so it cannot meet a parent's alias.
const keys_alias = "#k";

/// The answer's column a page's total is read out of, named for the same
/// reason: a Row may have a field called `total`.
const total_name = "#total";

// -- what a shaped Row reads ----------------------------------------------

/// One table joined into the statement: a parent, under the path of the field
/// that holds it.
const Join = struct {
    /// The field's path, which is also the alias: `"customer"`,
    /// `"org_unit.customer"`.
    alias: []const u8,
    /// The text after `JOIN`, the `ON` clause included.
    text: []const u8,
};

/// One column of the answer.
const Output = struct {
    /// What the `SELECT` list reads, any cast included.
    read: []const u8,
    /// The name it is answered under.
    name: []const u8,
    /// What `GROUP BY` repeats for it, or null for an aggregate.
    group: ?[]const u8,
};

/// Everything a statement over a shaped Row is written from, worked out once.
const Layout = struct {
    relation: []const u8,
    joins: []const Join,
    outputs: []const Output,
};

/// How many columns of the answer a Row fills, parents included: what a
/// reader walks, and what the width check asks for.
pub fn width(comptime Row: type) usize {
    comptime {
        var n: usize = 0;
        for (@typeInfo(Row).@"struct".fields) |f| {
            n += switch (row_mod.kindWith(Row, f.name, f.type)) {
                .column, .aggregate, .count => 1,
                .parent => (if (@typeInfo(f.type) == .optional) 1 else 0) +
                    width(row_mod.parentRowOf(f.type).?),
                .children, .beside => 0,
            };
        }
        return n;
    }
}

/// The layout of a statement over `Row`: the joins its parents need and the
/// columns of its answer, in the order a reader fills them.
fn layoutOf(comptime D: type, comptime Row: type) Layout {
    comptime {
        @setEvalBranchQuota(200_000);
        const relation = statement.relation(D, Row);
        var joins: []const Join = &.{};
        var outputs: []const Output = &.{};
        visit(D, Row, Row, relation, &.{}, relation, false, &joins, &outputs);
        return .{ .relation = relation, .joins = joins, .outputs = outputs };
    }
}

/// One level of the Row: the Row itself, or a parent at `path`, written as
/// `here`: its relation, or the alias it was joined under.
fn visit(
    comptime D: type,
    comptime Top: type,
    comptime Level: type,
    comptime here: []const u8,
    comptime path: []const []const u8,
    comptime relation: []const u8,
    comptime optional_above: bool,
    comptime joins: *[]const Join,
    comptime outputs: *[]const Output,
) void {
    comptime {
        for (@typeInfo(Level).@"struct".fields) |f| {
            const at = path ++ &[_][]const u8{f.name};
            const name = row_mod.pathName(at);
            switch (row_mod.kindWith(Level, f.name, f.type)) {
                .column => {
                    const column = here ++ "." ++ D.quote(f.name);
                    outputs.* = outputs.* ++ &[_]Output{.{
                        .read = D.readAs(column, f.type),
                        .name = name,
                        .group = column,
                    }};
                },
                .aggregate => {
                    const aggregate = row_mod.aggregateOf(Level, f.name).?;
                    outputs.* = outputs.* ++ &[_]Output{.{
                        .read = D.readAggregate(where_mod.aggregateCall(D, Level, relation, aggregate), aggregate.kind, f.type),
                        .name = name,
                        .group = null,
                    }};
                },
                .parent => {
                    const Parent = row_mod.parentRowOf(f.type).?;
                    const link = parentLink(Level, f.name);
                    const optional = @typeInfo(f.type) == .optional;
                    const alias = D.quote(name);
                    if (std.mem.eql(u8, alias, relation)) @compileError(
                        "nilo: " ++ @typeName(Top) ++ "'s parent `" ++ name ++ "` would be joined " ++
                            "under the name of the table the statement reads.\n" ++
                            "  A parent is joined under its field's name, so two relations would be " ++
                            "called " ++ alias ++ ". Name the field something else.",
                    );
                    var on: []const u8 = "";
                    for (link.targets, link.columns, 0..) |target, column, i| {
                        on = on ++ (if (i == 0) "" else " AND ") ++ alias ++ "." ++ D.quote(target) ++
                            " = " ++ here ++ "." ++ D.quote(column);
                    }
                    // Outer the moment anything above it is: a row whose
                    // parent is missing still has to come back, with the
                    // grandparent missing too.
                    const left = optional_above or optional;
                    joins.* = joins.* ++ &[_]Join{.{
                        .alias = name,
                        .text = (if (left) " LEFT JOIN " else " JOIN ") ++
                            statement.relation(D, Parent) ++ " AS " ++ alias ++ " ON " ++ on,
                    }};
                    // A parent that may be missing answers one more column:
                    // whether the key it was joined on matched. Its own
                    // columns cannot say, because a parent that is there may
                    // hold nothing but nulls. Grouped by the same expression,
                    // so two groups do not split on which parent it was.
                    if (optional) {
                        const present = "(" ++ alias ++ "." ++ D.quote(link.targets[0]) ++ " IS NOT NULL)";
                        outputs.* = outputs.* ++ &[_]Output{.{
                            .read = present,
                            .name = name ++ ".#",
                            .group = present,
                        }};
                    }
                    visit(D, Top, Parent, alias, at, relation, left, joins, outputs);
                },
                .count => outputs.* = outputs.* ++ &[_]Output{.{
                    .read = countCall(D, Level, f.name, here),
                    .name = name,
                    .group = null,
                }},
                .children, .beside => {},
            }
        }
    }
}

// -- the links -------------------------------------------------------------

/// The columns two tables are joined by, one for one.
const Link = struct {
    /// The columns doing the pointing.
    columns: []const []const u8,
    /// The columns pointed at.
    targets: []const []const u8,
};

/// Which reference a parent field follows: out of `Holder`'s table, to the
/// table of the Row the field holds.
///
/// **The rules are `.exists`'s** ([ADR 218](../docs/adr/218-a-row-may-carry-its-parent-its-children-or-a-sum.md)),
/// because it is the same question asked by a field instead of a condition:
/// one reference is the join, none is a schema that has not said how the two
/// relate, and two is a schema that said it twice (`owner_staff_id` and
/// `solution_staff_id` both pointing at `staff`), where guessing would answer
/// a question somebody did not ask. `nilo_via` names the column then, the way
/// `.via` does on an `.exists`, and it may also name a column no `.references`
/// covers, which joins to the other table's key.
fn parentLink(comptime Holder: type, comptime field: []const u8) Link {
    comptime {
        const Parent = row_mod.parentRowOf(row_mod.fieldTypeOf(Holder, field).?).?;
        const Owner = row_mod.ownerOf(Holder);
        const Target = row_mod.ownerOf(Parent);
        const found = referencesBetween(Owner, Target);

        const link = if (row_mod.viaOf(Holder, field)) |via|
            linkVia(Holder, field, found, Owner, Target, via)
        else if (found.links.len == 1) found.links[0] else if (found.links.len == 0) @compileError(
            "nilo: " ++ @typeName(Holder) ++ " reads `" ++ field ++ "` as a parent, and " ++
                @typeName(Owner) ++ " declares no `.references` to " ++ @typeName(Target) ++
                "'s table `" ++ row_mod.qualifiedOf(Target).table ++ "`.\n" ++
                "  The join is read out of the schema rather than written here. Add " ++
                "`.references = .{ .<column> = .{ " ++ @typeName(Target) ++ ", .id } }` to " ++
                @typeName(Owner) ++ "'s " ++ row_mod.marker ++ ", or name the column: `pub const " ++
                row_mod.via_marker ++ " = .{ ." ++ field ++ " = .<column> };`.",
        ) else @compileError(
            "nilo: " ++ @typeName(Holder) ++ " reads `" ++ field ++ "` as a parent, and " ++
                @typeName(Owner) ++ " points at " ++ @typeName(Target) ++ "'s table from more than " ++
                "one column: " ++ found.named ++ ".\n" ++
                "  Which of them this field follows is a question about what it means, and " ++
                "guessing would answer a different one. Say which: `pub const " ++
                row_mod.via_marker ++ " = .{ ." ++ field ++ " = .<column> };`.",
        );

        // **The type says whether the parent can be missing, and it has to say
        // what the schema says.** A nullable reference is a `LEFT JOIN`, and a
        // field that could not hold its null would be filled from a row that
        // is not there; a reference that cannot be null makes the `?` a branch
        // no caller will ever take.
        var nullable = false;
        for (link.columns) |c| {
            if (@typeInfo(row_mod.ColumnType(Owner, c)) == .optional) nullable = true;
        }
        const optional = @typeInfo(row_mod.fieldTypeOf(Holder, field).?) == .optional;
        if (nullable and !optional) @compileError(
            "nilo: " ++ @typeName(Holder) ++ " reads `" ++ field ++ "` as " ++ @typeName(Parent) ++
                ", and " ++ nameList(link.columns) ++ " may be null.\n" ++
                "  A row whose reference is null has no parent to fill it from. Write `" ++ field ++
                ": ?" ++ @typeName(Parent) ++ "`.",
        );
        if (optional and !nullable) @compileError(
            "nilo: " ++ @typeName(Holder) ++ " reads `" ++ field ++ "` as ?" ++ @typeName(Parent) ++
                ", and " ++ nameList(link.columns) ++ " is never null.\n" ++
                "  Every row has its parent, so the `?` is a branch no caller will take. Write `" ++
                field ++ ": " ++ @typeName(Parent) ++ "`.",
        );
        return link;
    }
}

/// A children field, as the statement that reads it needs it.
const Children = struct {
    /// The Row each child is.
    Child: type,
    /// The column of the child's table that points at the Row.
    column: []const u8,
    /// The column of the Row it points at, which the Row reads.
    target: []const u8,
};

/// Which reference a children field follows: out of the child's table, back
/// to the Row's. The same rules as a parent's, from the other end.
fn childrenOf(comptime Row: type, comptime field: []const u8) Children {
    comptime {
        const F = row_mod.fieldTypeOf(Row, field).?;
        const Child = row_mod.childRowOf(F).?;
        if (@typeInfo(F) == .optional) @compileError(
            "nilo: " ++ @typeName(Row) ++ " reads `" ++ field ++ "` as an optional list of children.\n" ++
                "  A row with none has an empty list, which is not the same as no list. Write `" ++
                field ++ ": []const " ++ @typeName(Child) ++ "`.",
        );
        const Owner = row_mod.ownerOf(Row);
        const link = backLink(Row, field, Child, "as children");

        if (link.columns.len != 1) @compileError(
            "nilo: " ++ @typeName(Row) ++ " reads `" ++ field ++ "` as children through a " ++
                "reference of several columns, " ++ nameList(link.columns) ++ ".\n" ++
                "  The children are read for every parent at once, keyed by one value each, and a " ++
                "key of several columns is not one value. Read them with `db.select` and a " ++
                "condition, or with `db.raw`.",
        );
        if (!row_mod.hasColumn(Row, link.targets[0])) @compileError(
            "nilo: " ++ @typeName(Row) ++ " reads `" ++ field ++ "` as children, and does not read `" ++
                link.targets[0] ++ "`, which is what each child points at.\n" ++
                "  The children are handed to the rows they belong to by that value, so the Row has " ++
                "to carry it: add `" ++ link.targets[0] ++ ": " ++
                @typeName(row_mod.ColumnType(Owner, link.targets[0])) ++ "`.",
        );
        return .{ .Child = Child, .column = link.columns[0], .target = link.targets[0] };
    }
}

/// The reference out of `Child`'s table back to `Row`'s that a field reading
/// the rows pointing back follows: a list of children, or a count of them.
/// `how` is what the message says the field reads them as.
fn backLink(comptime Row: type, comptime field: []const u8, comptime Child: type, comptime how: []const u8) Link {
    comptime {
        const Owner = row_mod.ownerOf(Row);
        const ChildOwner = row_mod.ownerOf(Child);
        const found = referencesBetween(ChildOwner, Owner);

        return if (row_mod.viaOf(Row, field)) |via|
            linkVia(Row, field, found, ChildOwner, Owner, via)
        else if (found.links.len == 1) found.links[0] else if (found.links.len == 0) @compileError(
            "nilo: " ++ @typeName(Row) ++ " reads `" ++ field ++ "` " ++ how ++ ", and " ++
                @typeName(ChildOwner) ++ " declares no `.references` to " ++ @typeName(Owner) ++
                "'s table `" ++ row_mod.qualifiedOf(Owner).table ++ "`.\n" ++
                "  The join is read out of the schema rather than written here. Add " ++
                "`.references = .{ .<column> = .{ " ++ @typeName(Owner) ++ ", .id } }` to " ++
                @typeName(ChildOwner) ++ "'s " ++ row_mod.marker ++ ", or name the column: `pub const " ++
                row_mod.via_marker ++ " = .{ ." ++ field ++ " = .<column> };`.",
        ) else @compileError(
            "nilo: " ++ @typeName(Row) ++ " reads `" ++ field ++ "` " ++ how ++ ", and " ++
                @typeName(ChildOwner) ++ " points at " ++ @typeName(Owner) ++ "'s table from more " ++
                "than one column: " ++ found.named ++ ".\n" ++
                "  Which of them makes a row a child of this one is a question about what the " ++
                "field means. Say which: `pub const " ++ row_mod.via_marker ++ " = .{ ." ++ field ++
                " = .<column> };`.",
        );
    }
}

/// The alias the counted table is read under inside a count's subquery, so a
/// table that points at itself (a work item's sub-items) is two names rather
/// than one written twice. `#` begins no field name, so no alias outside
/// meets it.
const counted_alias = "#c";

/// A count field as its statement reads it: a subquery correlated with the
/// row it sits on, written `here`.
///
/// ```sql
/// (SELECT count(*) FROM "lines" AS "#c" WHERE "#c"."order_id" = "orders"."id")
/// ```
///
/// **A subquery per row rather than a join and a `GROUP BY`**, because it is
/// the shape that keeps the Row one row per row of its table and `.limit`
/// counting those: a page of twenty asks twenty index lookups of the counted
/// table's reference column, and never counts the rows of a parent the page
/// does not show. The same text in the `SELECT` list and in a condition, the
/// way an aggregate's call is. The entry's `.where` goes in with its values
/// written (`table.literalCondition`), as an aggregate's does.
pub fn countCall(comptime D: type, comptime Row: type, comptime field: []const u8, comptime here: []const u8) []const u8 {
    comptime {
        const Counted = row_mod.countedRowOf(Row, field);
        const link = backLink(Row, field, Counted, "as a count");
        const alias = D.quote(counted_alias);
        var joined: []const u8 = "";
        for (link.columns, link.targets, 0..) |column, target, i| {
            joined = joined ++ (if (i == 0) "" else " AND ") ++ alias ++ "." ++ D.quote(column) ++
                " = " ++ here ++ "." ++ D.quote(target);
        }
        const entry = @field(@field(Row, row_mod.children_marker), field);
        if (@hasField(@TypeOf(entry), "where")) {
            joined = joined ++ " AND " ++ table_mod.literalCondition(
                D,
                row_mod.ownerOf(Counted),
                alias ++ ".",
                @typeName(Row) ++ "'s `." ++ field ++ "` `.where`",
                entry.where,
            );
        }
        return "(SELECT count(*) FROM " ++ statement.relation(D, Counted) ++ " AS " ++ alias ++
            " WHERE " ++ joined ++ ")";
    }
}

/// Every reference out of `From`'s table into `To`'s, with their columns
/// spelled out for the message that has to name them.
const Found = struct { links: []const Link, named: []const u8 };

fn referencesBetween(comptime From: type, comptime To: type) Found {
    comptime {
        const to = row_mod.qualifiedOf(To);
        var links: []const Link = &.{};
        var named: []const u8 = "";
        for (table_mod.foreignKeysOf(From)) |ref| {
            if (!std.mem.eql(u8, ref.table, to.table)) continue;
            if (!table_mod.sameSchema(ref.schema, to.schema)) continue;
            named = named ++ (if (links.len == 0) "" else ", ") ++ nameList(ref.columns);
            links = links ++ &[_]Link{.{ .columns = ref.columns, .targets = ref.targets }};
        }
        return .{ .links = links, .named = named };
    }
}

/// The link a field's `nilo_via` names: the reference its column is part of,
/// or, when no `.references` names the column, that column joined to `To`'s
/// key, which then has to be one column.
fn linkVia(
    comptime Holder: type,
    comptime field: []const u8,
    comptime found: Found,
    comptime From: type,
    comptime To: type,
    comptime via: []const u8,
) Link {
    comptime {
        for (found.links) |l| {
            for (l.columns) |c| {
                if (std.mem.eql(u8, c, via)) return l;
            }
        }
        if (!row_mod.hasColumn(From, via)) {
            row_mod.noSuchColumn(From, via, @typeName(Holder) ++ "'s " ++ row_mod.via_marker ++ " for `" ++ field ++ "`");
        }
        const keys = row_mod.keysOf(To);
        if (keys.len != 1) @compileError(
            "nilo: " ++ @typeName(Holder) ++ "'s " ++ row_mod.via_marker ++ " joins `" ++ field ++
                "` through `" ++ via ++ "`, which no `.references` names.\n" ++
                "  The other side would be " ++ @typeName(To) ++ "'s key, and that key is " ++
                row_mod.keyList(To) ++ ", which one column cannot match. Declare the foreign key.",
        );
        return .{ .columns = &.{via}, .targets = &.{keys[0]} };
    }
}

fn nameList(comptime columns: []const []const u8) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (columns, 0..) |c, i| out = out ++ (if (i == 0) "" else ", ") ++ "`" ++ c ++ "`";
        return out;
    }
}

// -- what a shaped Row may be ---------------------------------------------

/// Everything about a shaped Row that is a mistake in the type rather than in
/// a call: each is refused wherever the Row is first used, so the message is
/// about the Row and not about whichever statement happened to meet it.
pub fn assertShape(comptime Row: type) void {
    comptime {
        @setEvalBranchQuota(200_000);
        const decl = @field(Row, row_mod.marker);
        if (@TypeOf(decl) != type) @compileError(
            "nilo: " ++ @typeName(Row) ++ " carries a parent, children or an aggregate, and is " ++
                (if (@TypeOf(decl) == @TypeOf(.enum_literal)) "a projection" else "not a narrower Row") ++ ".\n" ++
                "  Those belong to a Row that reads a table without describing it: `pub const " ++
                row_mod.marker ++ " = <TheTablesRow>;`.",
        );
        const Owner = row_mod.ownerOf(Row);
        const grouped = row_mod.isGrouped(Row);

        for (@typeInfo(Row).@"struct".fields) |f| {
            switch (row_mod.kindWith(Row, f.name, f.type)) {
                .parent => assertParentRow(Row, f.name),
                .children => {
                    if (grouped) @compileError(
                        "nilo: " ++ @typeName(Row) ++ " is grouped and reads `" ++ f.name ++ "` as children.\n" ++
                            "  A group is many rows, and children belong to one. Read the children " ++
                            "through a Row that is not grouped.",
                    );
                    const found = childrenOf(Row, f.name);
                    if (row_mod.isGrouped(found.Child)) @compileError(
                        "nilo: " ++ @typeName(Row) ++ "'s children `" ++ f.name ++ "` are " ++
                            @typeName(found.Child) ++ ", which is grouped.\n" ++
                            "  A child is one row of the table that points back. A total over them " ++
                            "is a grouped Row read on its own.",
                    );
                    if (row_mod.fieldsOfKind(found.Child, .children).len > 0) @compileError(
                        "nilo: " ++ @typeName(Row) ++ "'s children `" ++ f.name ++ "` are " ++
                            @typeName(found.Child) ++ ", which has children of its own.\n" ++
                            "  One level is read for every parent at once; a second would be a " ++
                            "third statement per level. Read the grandchildren with their own call.",
                    );
                    assertChildRow(found.Child);
                },
                .aggregate => assertAggregate(Row, Owner, f.name, f.type),
                .count => {
                    if (grouped) @compileError(
                        "nilo: " ++ @typeName(Row) ++ " is grouped and counts `" ++ f.name ++ "`.\n" ++
                            "  A count of the rows pointing back belongs to one row, and a group is " ++
                            "many. Count them through a Row that is not grouped.",
                    );
                    if (f.type != i64) @compileError(
                        "nilo: " ++ @typeName(Row) ++ " reads `." ++ f.name ++ "`, a count, as " ++
                            @typeName(f.type) ++ ".\n" ++
                            "  A count is a whole number and is never null, none included: `" ++
                            f.name ++ ": i64`.",
                    );
                    _ = backLink(Row, f.name, row_mod.countedRowOf(Row, f.name), "as a count");
                },
                .column, .beside => {},
            }
        }
        if (@hasDecl(Row, row_mod.children_marker)) assertChildrenMarker(Row);
        if (@hasDecl(Row, row_mod.via_marker)) {
            for (@typeInfo(@TypeOf(@field(Row, row_mod.via_marker))).@"struct".fields) |e| {
                switch (row_mod.kindOf(Row, e.name)) {
                    .parent, .children, .count => {},
                    else => @compileError(
                        "nilo: " ++ @typeName(Row) ++ "'s " ++ row_mod.via_marker ++ " names `" ++ e.name ++
                            "`, which is not a parent or a list of children.\n" ++
                            "  It says which reference such a field follows, and only such a field " ++
                            "follows one.",
                    ),
                }
            }
        }
    }
}

/// Every entry of `nilo_children` names a field that reads the rows pointing
/// back, and says only what such a field may: `.order` and `.where` for a
/// list, `.count` and `.where` for a count.
fn assertChildrenMarker(comptime Row: type) void {
    comptime {
        const decl = @field(Row, row_mod.children_marker);
        const D = @TypeOf(decl);
        const head = "nilo: " ++ @typeName(Row) ++ "'s " ++ row_mod.children_marker;
        const shape = "\n  It is keyed by the field it describes: `pub const " ++ row_mod.children_marker ++
            " = .{ .lines = .{ .order = .{ .position = .asc } }, .line_count = .{ .count = Line } };`.";
        if (@typeInfo(D) != .@"struct" or @typeInfo(D).@"struct".is_tuple) @compileError(
            head ++ " is a " ++ @typeName(D) ++ "." ++ shape,
        );
        for (@typeInfo(D).@"struct".fields) |e| {
            if (row_mod.fieldTypeOf(Row, e.name) == null) @compileError(
                head ++ " names `" ++ e.name ++ "`, which is not one of its fields." ++ shape,
            );
            const E = e.type;
            if (@typeInfo(E) != .@"struct" or @typeInfo(E).@"struct".is_tuple) @compileError(
                head ++ " gives `." ++ e.name ++ "` a " ++ @typeName(E) ++ "." ++ shape,
            );
            const allowed: []const []const u8 = switch (row_mod.kindOf(Row, e.name)) {
                .children => &.{ "order", "where" },
                .count => &.{ "count", "where" },
                else => @compileError(
                    head ++ " names `" ++ e.name ++ "`, which is not a list of children.\n" ++
                        "  An entry orders or narrows a field of type `[]const <Row>`, or counts " ++
                        "with `.{ .count = <Row> }` into a field of type `i64`.",
                ),
            };
            for (@typeInfo(E).@"struct".fields) |w| {
                for (allowed) |ok| {
                    if (std.mem.eql(u8, w.name, ok)) break;
                } else @compileError(
                    head ++ " gives `." ++ e.name ++ "` a `." ++ w.name ++ "`, which it does not take.\n" ++
                        "  A list of children takes `.order` and `.where`; a count takes `.count` and `.where`.",
                );
            }
        }
    }
}

/// A parent is a row of another table, so it is flat below its own parents:
/// no children, which would be a statement per parent, and no aggregate,
/// which has no group to be over.
fn assertParentRow(comptime Holder: type, comptime field: []const u8) void {
    comptime {
        const Parent = row_mod.parentRowOf(row_mod.fieldTypeOf(Holder, field).?).?;
        if (row_mod.isGrouped(Parent)) @compileError(
            "nilo: " ++ @typeName(Holder) ++ "'s parent `" ++ field ++ "` is " ++ @typeName(Parent) ++
                ", which is grouped.\n" ++
                "  A parent is the one row a reference points at, so there is nothing to group.",
        );
        for (@typeInfo(Parent).@"struct".fields) |f| {
            switch (row_mod.kindWith(Parent, f.name, f.type)) {
                .children => @compileError(
                    "nilo: " ++ @typeName(Holder) ++ "'s parent `" ++ field ++ "` is " ++ @typeName(Parent) ++
                        ", which reads children.\n" ++
                        "  Children are read for the rows of the statement, and a parent is joined " ++
                        "into it. Read them at the top of a Row of their own.",
                ),
                .parent => assertParentRow(Parent, f.name),
                else => {},
            }
        }
        _ = parentLink(Holder, field);
    }
}

/// A Row a children field holds, checked the way a statement over it would
/// check it: its parents resolve.
fn assertChildRow(comptime Row: type) void {
    comptime {
        for (@typeInfo(Row).@"struct".fields) |f| {
            if (row_mod.kindWith(Row, f.name, f.type) == .parent) assertParentRow(Row, f.name);
        }
    }
}

/// The type an aggregate's field has to be, said as a rule rather than
/// guessed: what the computation answers, and a `?` exactly when it can be
/// null.
fn assertAggregate(comptime Row: type, comptime Owner: type, comptime field: []const u8, comptime F: type) void {
    comptime {
        const aggregate = row_mod.aggregateOf(Row, field).?;
        const words = @tagName(aggregate.kind);
        const Bare = switch (@typeInfo(F)) {
            .optional => |o| o.child,
            else => F,
        };
        const optional = @typeInfo(F) == .optional;

        if (aggregate.kind == .count or aggregate.kind == .count_distinct) {
            if (aggregate.column) |c| {
                if (!row_mod.hasColumn(Owner, c)) row_mod.noSuchColumn(Owner, c, @typeName(Row) ++ "'s `." ++ field ++ "`");
            }
            if (F != i64) @compileError(
                "nilo: " ++ @typeName(Row) ++ " reads `." ++ field ++ "`, a " ++ words ++ ", as " ++
                    @typeName(F) ++ ".\n" ++
                    "  A count is a whole number and is never null, zero rows included: `" ++
                    field ++ ": i64`.",
            );
            return;
        }

        const column = aggregate.column.?;
        if (!row_mod.hasColumn(Owner, column)) row_mod.noSuchColumn(Owner, column, @typeName(Row) ++ "'s `." ++ field ++ "`");
        const C = row_mod.ColumnType(Owner, column);
        const CBare = switch (@typeInfo(C)) {
            .optional => |o| o.child,
            else => C,
        };

        const Want: type = switch (aggregate.kind) {
            .sum => switch (@typeInfo(CBare)) {
                .int => i64,
                .float => f64,
                else => if (types_mod.asText(CBare) != null) CBare else @compileError(
                    "nilo: " ++ @typeName(Row) ++ "'s `." ++ field ++ "` sums `" ++ column ++ "`, which is " ++
                        @typeName(C) ++ ".\n  A sum is over numbers.",
                ),
            },
            .avg => switch (@typeInfo(CBare)) {
                .int, .float => f64,
                else => @compileError(
                    "nilo: " ++ @typeName(Row) ++ "'s `." ++ field ++ "` averages `" ++ column ++ "`, which is " ++
                        @typeName(C) ++ ".\n  An average is over whole or floating numbers.",
                ),
            },
            .min, .max => CBare,
            .count, .count_distinct => unreachable,
        };
        if (Bare != Want) @compileError(
            "nilo: " ++ @typeName(Row) ++ " reads `." ++ field ++ "`, the " ++ words ++ " of `" ++ column ++
                "`, as " ++ @typeName(F) ++ ".\n" ++
                "  It answers " ++ @typeName(Want) ++
                (if (aggregate.kind == .min or aggregate.kind == .max) ", the column's own type" else ", whatever width the column is") ++
                ": `" ++ field ++
                ": " ++ (if (optional) "?" else "") ++ @typeName(Want) ++ "`.",
        );

        // Null when there is nothing to compute over: a group whose every
        // value is null, a group none of whose rows meets the entry's
        // `.where`, or, for a Row grouped by nothing, no rows at all.
        const nullable = @typeInfo(C) == .optional or row_mod.isTally(Row) or aggregate.filtered;
        const why = if (aggregate.filtered)
            "it reads only the rows its `.where` matches, and " ++ words ++ " over a group where none does is null"
        else if (row_mod.isTally(Row))
            "a Row grouped by nothing answers even when no row matched, and " ++ words ++ " over no rows is null"
        else
            "`" ++ column ++ "` may be null, and " ++ words ++ " over a group of nulls is null";
        if (nullable and !optional) @compileError(
            "nilo: " ++ @typeName(Row) ++ " reads `." ++ field ++ "` as " ++ @typeName(F) ++ ", and " ++
                why ++ ".\n  Write `" ++ field ++ ": ?" ++ @typeName(Want) ++ "`.",
        );
        if (optional and !nullable) @compileError(
            "nilo: " ++ @typeName(Row) ++ " reads `." ++ field ++ "` as " ++ @typeName(F) ++ ", and `" ++
                column ++ "` is never null, so neither is its " ++ words ++ " over a group.\n" ++
                "  Write `" ++ field ++ ": " ++ @typeName(Want) ++ "`.",
        );
    }
}

// -- the statements -------------------------------------------------------

/// How many rows a caller is asking for, the way `statement.zig` says it.
pub const Answers = enum { many, first, page };

/// What a read of a shaped Row takes. No `.lock`, which `assertNoLock` says
/// why; `db.one` has no `.limit`, because it compiles its own.
const known = [_][]const u8{ "where", "order", "limit", "offset" };
const known_first = [_][]const u8{ "where", "order", "offset" };

/// The `SELECT` list: every output under its name.
fn selectList(comptime D: type, comptime outputs: []const Output) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (outputs, 0..) |o, i| out = out ++ (if (i == 0) "" else ", ") ++ o.read ++ " AS " ++ D.quote(o.name);
        return out;
    }
}

/// A `SELECT` over a shaped Row: `db.select`, `db.one` and `db.page`.
pub fn rows(comptime D: type, comptime Row: type, comptime O: type, comptime answers: Answers) Statement {
    return comptime blk: {
        @setEvalBranchQuota(200_000);
        assertShape(Row);
        const call = switch (answers) {
            .many => "`db.select`",
            .first => "`db.one`",
            .page => "`db.page`",
        };
        if (row_mod.isTally(Row)) @compileError(
            "nilo: " ++ call ++ " on " ++ @typeName(Row) ++ ", whose every field is an aggregate.\n" ++
                "  A Row grouped by nothing is exactly one row whatever matched: a list of it would " ++
                "always hold one, and `db.one` would never say null. Read it with " ++
                "`db.exactlyOne(" ++ @typeName(Row) ++ ", c, .{ .where = … })`.",
        );
        assertNoLock(Row, O, call);
        if (answers == .first and @hasField(O, "limit")) @compileError(
            "nilo: `db.one` on " ++ @typeName(Row) ++ " was given a `.limit`.\n" ++
                "  It answers with one row or with none, and compiles its own `LIMIT 1`.",
        );
        if (answers == .page and !@hasField(O, "limit")) @compileError(
            "nilo: `db.page` on " ++ @typeName(Row) ++ " was given no `.limit`.\n" ++
                "  A page is a slice of the rows and a total for the rest of them. Add `.limit = 20`, " ++
                "or use `db.select`.",
        );
        if (answers == .page and !@hasField(O, "order")) @compileError(
            "nilo: `db.page` on " ++ @typeName(Row) ++ " was given no `.order`.\n" ++
                "  `LIMIT` without `ORDER BY` takes whichever rows the planner reached first, so one " ++
                "row can be on two pages and another on neither. Add `.order = .{ .<field> = .asc }`.",
        );
        statement.assertOptions(Row, O, if (answers == .first) &known_first else &known, call);

        const layout = layoutOf(D, Row);
        var select = selectList(D, layout.outputs);
        if (answers == .page) select = select ++ ", count(*) OVER () AS " ++ D.quote(total_name);

        const body = bodyOf(D, Row, O, layout, 1, .all_joins);
        var sql: []const u8 = "SELECT " ++ select ++ " FROM " ++ layout.relation ++ body.text;
        var paths = body.paths;
        var params = body.params;
        var next = body.next;
        var reserve: ?usize = null;

        var ordered = false;
        var head: []const u8 = "";
        if (@hasField(O, "order")) {
            const Sort = @FieldType(O, "order");
            if (ordering.orderingOf(Sort) != null) {
                ordering.assertFor(Sort, Row, call, true);
                ordered = true;
                head = sql;
                sql = "";
            } else {
                sql = sql ++ orderBy(D, Row, Sort);
            }
        }
        if (@hasField(O, "limit")) {
            const bound = statement.boundary(D, O, "limit", next);
            sql = sql ++ D.limit(bound.text);
            reserve = bound.written;
            if (bound.path) |path| {
                paths = paths ++ &[_]where_mod.Path{path};
                params = params ++ &[_]where_mod.Param{.{}};
                next += 1;
            }
        }
        if (answers == .first) {
            sql = sql ++ D.limit("1");
            reserve = 1;
        }
        if (@hasField(O, "offset")) {
            const bound = statement.boundary(D, O, "offset", next);
            sql = sql ++ D.offset(bound.text);
            if (bound.path) |path| {
                paths = paths ++ &[_]where_mod.Path{path};
                params = params ++ &[_]where_mod.Param{.{}};
                next += 1;
            }
        }

        if (ordered) break :blk .{
            .sql = head,
            .paths = paths,
            .params = params,
            .reserve = reserve,
            .ordered = true,
            .tail = sql,
        };
        break :blk .{ .sql = sql, .paths = paths, .params = params, .reserve = reserve };
    };
}

/// `db.find` over a shaped Row: its key, which the Row reads, and `LIMIT 1`.
/// A grouped Row has none to find by, because a group is not a row of the
/// table.
pub fn find(comptime D: type, comptime Row: type, comptime K: type) Statement {
    return comptime blk: {
        @setEvalBranchQuota(200_000);
        assertShape(Row);
        if (row_mod.isGrouped(Row)) @compileError(
            "nilo: `db.find` on " ++ @typeName(Row) ++ ", which is grouped.\n" ++
                "  A group is not a row of the table, so no key identifies one. Narrow with " ++
                "`db.one(" ++ @typeName(Row) ++ ", c, .{ .where = … })`.",
        );
        const keys = row_mod.keysOf(Row);
        if (keys.len == 1) statement.assertKeyValue(Row, keys[0], K) else statement.assertCompositeKey(Row, keys, K);
        const layout = layoutOf(D, Row);
        var joins: []const u8 = "";
        for (layout.joins) |j| joins = joins ++ j.text;

        var conditions: []const u8 = "";
        var paths: []const where_mod.Path = &.{};
        var params: []const where_mod.Param = &.{};
        for (keys, 0..) |key, i| {
            conditions = conditions ++ (if (i == 0) "" else " AND ") ++ layout.relation ++ "." ++
                D.quote(key) ++ " = " ++
                D.bindAs(D.placeholder(i + 1), row_mod.ColumnType(Row, key), false);
            // A key of one column is handed over bare, and the empty path is
            // the value itself, which is `statement.find`'s arrangement.
            paths = paths ++ &[_]where_mod.Path{if (keys.len == 1) &.{} else &.{key}};
            params = params ++ &[_]where_mod.Param{.{ .column = key }};
        }
        break :blk .{
            .sql = "SELECT " ++ selectList(D, layout.outputs) ++ " FROM " ++ layout.relation ++ joins ++
                " WHERE " ++ conditions ++ D.limit("1"),
            .paths = paths,
            .params = params,
            .reserve = 1,
        };
    };
}

/// `db.count` and `db.exists` over a shaped Row.
///
/// **A grouped Row counts groups**, because what `db.page` would have listed
/// is groups: the grouped statement goes inside a subquery and is counted
/// from outside. **Any other counts its own table's rows**, joined only to the
/// parents its condition names: a parent reference cannot change how many
/// rows there are, so a join nothing reads is work the answer does not need.
pub fn tally(comptime D: type, comptime Row: type, comptime O: type, comptime exists: bool) Statement {
    return comptime blk: {
        @setEvalBranchQuota(200_000);
        assertShape(Row);
        const call = if (exists) "`db.exists`" else "`db.count`";
        if (row_mod.isTally(Row)) @compileError(
            "nilo: " ++ call ++ " on " ++ @typeName(Row) ++ ", whose every field is an aggregate.\n" ++
                "  A Row grouped by nothing is always exactly one row. Count the table's rows with " ++
                "`.count` in its " ++ row_mod.aggregate_marker ++ ", or with " ++ call ++
                " on the Row it borrows.",
        );
        statement.assertOptions(Row, O, &.{"where"}, call);
        const layout = layoutOf(D, Row);
        const grouped = row_mod.isGrouped(Row);
        const body = bodyOf(D, Row, O, layout, 1, if (grouped) .all_joins else .reached_joins);
        const inner = "SELECT 1 FROM " ++ layout.relation ++ body.text;
        const sql = if (exists)
            "SELECT EXISTS(" ++ inner ++ ")"
        else if (grouped)
            "SELECT count(*) FROM (" ++ inner ++ ") AS " ++ D.quote("#groups")
        else
            "SELECT count(*) FROM " ++ layout.relation ++ body.text;
        break :blk .{ .sql = sql, .paths = body.paths, .params = body.params, .reserve = 1 };
    };
}

/// `db.exactlyOne` over a Row grouped by nothing: every aggregate over the
/// rows its condition matched, which is one row whether it matched any or not.
pub fn exactlyOne(comptime D: type, comptime Row: type, comptime O: type) Statement {
    return comptime blk: {
        @setEvalBranchQuota(200_000);
        row_mod.assertRow(Row);
        if (!row_mod.isTally(Row)) @compileError(
            "nilo: `db.exactlyOne` on " ++ @typeName(Row) ++ ", which is not grouped by nothing.\n" ++
                "  It reads a Row whose every field is an aggregate, because that is the one Row that " ++
                "is exactly one row whatever matched. A row found by a condition is `db.one`, which " ++
                "says null when there is none; a statement you wrote is `db.rawExactlyOne`.",
        );
        assertShape(Row);
        statement.assertOptions(Row, O, &.{"where"}, "`db.exactlyOne`");
        const layout = layoutOf(D, Row);
        const body = bodyOf(D, Row, O, layout, 1, .all_joins);
        break :blk .{
            .sql = "SELECT " ++ selectList(D, layout.outputs) ++ " FROM " ++ layout.relation ++ body.text,
            .paths = body.paths,
            .params = body.params,
            .reserve = 1,
        };
    };
}

/// The statement a children field is read by: every child of every parent in
/// one round trip, numbered by the parent it belongs to.
///
/// ```sql
/// SELECT "lines"."sku" AS "sku", "#k"."key" AS "#parent"
/// FROM unnest($1::int8[]) WITH ORDINALITY AS "#k"("value", "key")
/// JOIN "lines" ON "lines"."order_id" = "#k"."value"
/// ORDER BY "#k"."key", "lines"."id"
/// ```
///
/// **The parents' keys go in as one list and come back as numbers**, so the
/// rows arrive grouped by parent and in the parents' own order: the reader
/// walks the two lists in step and never compares a key. Within one parent
/// the children are in their table's key order.
///
/// Its one parameter is read out of `.{ .keys = … }`, the keys of the
/// parents in the order they were read.
pub fn children(comptime D: type, comptime Row: type, comptime field: []const u8) Statement {
    return comptime blk: {
        @setEvalBranchQuota(200_000);
        const found = childrenOf(Row, field);
        const Key = row_mod.ColumnType(Row, found.target);
        const listed = D.ordinalList(D.placeholder(1), Key, D.quote(keys_alias)) orelse @compileError(
            "nilo: " ++ @typeName(Row) ++ "'s children `" ++ field ++ "` are handed out by `" ++
                found.target ++ "`, a " ++ @typeName(Key) ++ ", and the " ++ D.name ++
                " dialect has no list of that type.",
        );
        const layout = layoutOf(D, found.Child);
        const numbered = D.quote(keys_alias) ++ "." ++ D.quote("key");
        const select = selectList(D, layout.outputs) ++ ", " ++ numbered ++ " AS " ++ D.quote("#parent");

        var joins: []const u8 = "";
        for (layout.joins) |j| joins = joins ++ j.text;
        var order: []const u8 = " ORDER BY " ++ numbered;
        const ChildOwner = row_mod.ownerOf(found.Child);
        const what = @typeName(Row) ++ "'s `." ++ field ++ "`";
        if (childEntry(Row, field)) |E| {
            const entry = @field(@field(Row, row_mod.children_marker), field);
            if (@hasField(E, "where")) joins = joins ++ " WHERE " ++ table_mod.literalCondition(
                D,
                ChildOwner,
                layout.relation ++ ".",
                what ++ " `.where`",
                entry.where,
            );
            if (@hasField(E, "order")) order = order ++ ", " ++ childOrder(D, ChildOwner, layout.relation, what, @TypeOf(entry.order));
        }
        // The key last, whatever the entry said, so two children the order
        // ties come back the same way every time.
        for (row_mod.keysIfAnyOf(ChildOwner)) |key| {
            order = order ++ ", " ++ layout.relation ++ "." ++ D.quote(key);
        }
        break :blk .{
            .sql = "SELECT " ++ select ++ " FROM " ++ listed ++ " JOIN " ++ layout.relation ++ " ON " ++
                layout.relation ++ "." ++ D.quote(found.column) ++ " = " ++
                D.quote(keys_alias) ++ "." ++ D.quote("value") ++ joins ++ order,
            .paths = &.{&.{"keys"}},
            .params = &.{.{ .column = found.target, .of = Row, .list = true }},
        };
    };
}

/// The `nilo_children` entry's type for a children field, or null when the
/// Row says nothing about it.
fn childEntry(comptime Row: type, comptime field: []const u8) ?type {
    comptime {
        if (!@hasDecl(Row, row_mod.children_marker)) return null;
        const D = @TypeOf(@field(Row, row_mod.children_marker));
        if (!@hasField(D, field)) return null;
        return @FieldType(D, field);
    }
}

/// A children entry's `.order`: columns of the child's table, each with a
/// direction, written through the relation the children statement reads.
/// A column the child Row does not carry is allowed, the way it is on a
/// narrower Row's own `.order`, because every row of the table is still one
/// child.
fn childOrder(comptime D: type, comptime Table: type, comptime relation: []const u8, comptime what: []const u8, comptime T: type) []const u8 {
    comptime {
        const info = switch (@typeInfo(T)) {
            .@"struct" => |s| s,
            else => @compileError(
                "nilo: " ++ what ++ " `.order` is a " ++ @typeName(T) ++ ".\n" ++
                    "  Write `.order = .{ .position = .asc }`, one field per term.",
            ),
        };
        if (info.is_tuple or info.fields.len == 0) @compileError(
            "nilo: " ++ what ++ " `.order` names no column.\n" ++
                "  Write `.order = .{ .position = .asc }`, one field per term, or leave it out " ++
                "for the child table's key order.",
        );
        var out: []const u8 = "";
        for (info.fields) |f| {
            if (!row_mod.hasColumn(Table, f.name)) row_mod.noSuchColumn(Table, f.name, what ++ " `.order`");
            if (f.type != Direction and f.type != @TypeOf(.enum_literal)) @compileError(
                "nilo: " ++ what ++ " `.order` gives `" ++ f.name ++ "` a " ++ @typeName(f.type) ++
                    ".\n  A direction is `.asc` or `.desc`, or one of the four that also say where NULLs go.",
            );
            const direction: Direction = statement.writtenValue(T, f.name, Direction);
            var one = relation ++ "." ++ D.quote(f.name) ++ (if (direction.descending()) " DESC" else " ASC");
            if (direction.placement()) |where_nulls| {
                one = one ++ (D.nulls(where_nulls) orelse dialect_mod.noNullsOrder(D, Table, f.name));
            }
            out = out ++ (if (out.len == 0) "" else ", ") ++ one;
        }
        return out;
    }
}

/// The children fields of `Row`: what `db.zig` reads after the parents, one
/// statement each.
pub fn childFields(comptime Row: type) []const []const u8 {
    return comptime row_mod.fieldsOfKind(Row, .children);
}

/// The column of the parent a children field is handed out by.
pub fn childTarget(comptime Row: type, comptime field: []const u8) []const u8 {
    return comptime childrenOf(Row, field).target;
}

// -- the middle of every statement ----------------------------------------

const Body = struct {
    /// Everything after the relation: the joins, the condition, the groups.
    text: []const u8,
    paths: []const where_mod.Path,
    params: []const where_mod.Param,
    next: usize,
};

const Joining = enum { all_joins, reached_joins };

/// The joins, the `WHERE`, and for a grouped Row the `GROUP BY` and `HAVING`,
/// numbered from `first`.
fn bodyOf(
    comptime D: type,
    comptime Row: type,
    comptime O: type,
    comptime layout: Layout,
    comptime first: usize,
    comptime joining: Joining,
) Body {
    comptime {
        const grouped = row_mod.isGrouped(Row);
        const Owner = row_mod.ownerOf(Row);
        var paths: []const where_mod.Path = &.{};
        var params: []const where_mod.Param = &.{};
        var next = first;
        var where: []const u8 = "";
        var having: []const u8 = "";
        var reached: []const []const u8 = &.{};

        if (@hasField(O, "where")) {
            const W = @FieldType(O, "where");
            const rows_plan = where_mod.planScoped(D, W, next, &.{"where"}, .{
                .shape = Row,
                .columns = if (grouped) Owner else Row,
                .relation = layout.relation,
                .phase = if (grouped) .rows else .all,
            });
            where = rows_plan.sql;
            paths = paths ++ rows_plan.paths;
            params = params ++ rows_plan.params;
            next += rows_plan.paths.len;
            reached = rows_plan.reached;
            if (grouped) {
                const groups_plan = where_mod.planScoped(D, W, next, &.{"where"}, .{
                    .shape = Row,
                    .columns = Owner,
                    .relation = layout.relation,
                    .phase = .groups,
                });
                if (groups_plan.paths.len > 0 and row_mod.isTally(Row)) @compileError(
                    "nilo: the condition on " ++ @typeName(Row) ++ " names an aggregate, and the Row is " ++
                        "grouped by nothing.\n" ++
                        "  A condition on the one group would make the answer no row at all when it " ++
                        "failed, and this Row is exactly one row. Read it and compare the number.",
                );
                having = groups_plan.sql;
                paths = paths ++ groups_plan.paths;
                params = params ++ groups_plan.params;
                next += groups_plan.paths.len;
            }
        }

        var text: []const u8 = "";
        for (layout.joins) |j| {
            if (joining == .reached_joins and !reachedBy(reached, j.alias)) continue;
            text = text ++ j.text;
        }
        if (where.len > 0) text = text ++ " WHERE " ++ where;
        if (grouped) {
            var groups: []const u8 = "";
            for (layout.outputs) |o| {
                const g = o.group orelse continue;
                groups = groups ++ (if (groups.len == 0) "" else ", ") ++ g;
            }
            if (groups.len > 0) text = text ++ " GROUP BY " ++ groups;
            if (having.len > 0) text = text ++ " HAVING " ++ having;
        }
        return .{ .text = text, .paths = paths, .params = params, .next = next };
    }
}

/// Whether a join is needed by a condition that reached `reached`: named
/// itself, or the parent of one that was: `org_unit` is joined for a
/// condition on `org_unit.customer`.
fn reachedBy(comptime reached: []const []const u8, comptime alias: []const u8) bool {
    comptime {
        for (reached) |r| {
            if (std.mem.eql(u8, r, alias)) return true;
            if (r.len > alias.len and std.mem.startsWith(u8, r, alias) and r[alias.len] == '.') return true;
        }
        return false;
    }
}

/// A read over a shaped Row takes no lock: holding the rows of a join locks
/// every table in it, and a group is not a row that can be held.
fn assertNoLock(comptime Row: type, comptime O: type, comptime call: []const u8) void {
    if (@hasField(O, "lock")) @compileError(
        "nilo: " ++ call ++ " on " ++ @typeName(Row) ++ " was given a `.lock`.\n" ++
            "  A Row with a parent would hold a row of every table it joins, and a group is not a " ++
            "row that can be held. Lock the rows of the table itself with `tx.select(" ++
            @typeName(row_mod.ownerOf(Row)) ++ ", c, .{ …, .lock = .update })`, and read the shape after.",
    );
}

/// `ORDER BY`, written against the names the answer carries: a field of the
/// Row, an aggregate, or a parent's column through the parent's field:
/// `.order = .{ .customer = .{ .name = .asc } }`.
fn orderBy(comptime D: type, comptime Row: type, comptime T: type) []const u8 {
    comptime {
        const terms = orderTerms(D, Row, T, &.{}, statement.relation(D, Row));
        return if (terms.len == 0) "" else " ORDER BY " ++ terms;
    }
}

/// `relation` is the Row's own table as the statement names it, for a column
/// of that table the Row does not carry (`tableHasColumn`): written through
/// the table rather than through the answer, so it is only for a Row that is
/// not grouped, where every row of the table is still a row of the answer.
fn orderTerms(comptime D: type, comptime Level: type, comptime T: type, comptime path: []const []const u8, comptime relation: []const u8) []const u8 {
    comptime {
        const info = switch (@typeInfo(T)) {
            .@"struct" => |s| s,
            else => @compileError(
                "nilo: `.order` has to be a struct and this one is a " ++ @typeName(T) ++ ".\n" ++
                    "  Write `.order = .{ .created_at = .desc }`, one field per term.",
            ),
        };
        var out: []const u8 = "";
        for (info.fields) |f| {
            const at = path ++ &[_][]const u8{f.name};
            const kind: row_mod.Kind = if (row_mod.fieldTypeOf(Level, f.name) == null) .column else row_mod.kindOf(Level, f.name);
            const term = switch (kind) {
                .parent => orderTerms(D, row_mod.parentRowOf(row_mod.fieldTypeOf(Level, f.name).?).?, f.type, at, ""),
                .column, .aggregate, .count => term: {
                    const carried = row_mod.fieldTypeOf(Level, f.name) != null;
                    const through_table = !carried and path.len == 0 and
                        !@hasDecl(Level, row_mod.aggregate_marker) and
                        row_mod.tableHasColumn(Level, f.name);
                    if (!carried and path.len == 0 and @hasDecl(Level, row_mod.aggregate_marker) and
                        row_mod.tableHasColumn(Level, f.name)) @compileError(
                        "nilo: `.order` on " ++ @typeName(Level) ++ " names `" ++ f.name ++
                            "`, a column of its table that the Row does not carry, and the Row is grouped.\n" ++
                            "  A grouped Row is one row per group, and a column of the table has one value " ++
                            "per row of the table rather than per group. Order by a field the Row groups by, " ++
                            "or by one of its aggregates.",
                    );
                    if (!carried and !through_table) row_mod.noSuchColumn(Level, f.name, "`.order`");
                    if (f.type != Direction and f.type != @TypeOf(.enum_literal)) @compileError(
                        "nilo: `.order` on `" ++ row_mod.pathName(at) ++ "` was given a " ++ @typeName(f.type) ++
                            ".\n  A direction is `.asc` or `.desc`, or one of the four that also say " ++
                            "where NULLs go. A parent takes the terms for its own columns: `." ++ f.name ++
                            " = .{ .<column> = .asc }`.",
                    );
                    const direction: Direction = statement.writtenValue(T, f.name, Direction);
                    const named = if (through_table) relation ++ "." ++ D.quote(f.name) else D.quote(row_mod.pathName(at));
                    var one = named ++ (if (direction.descending()) " DESC" else " ASC");
                    if (direction.placement()) |where_nulls| {
                        one = one ++ (D.nulls(where_nulls) orelse
                            dialect_mod.noNullsOrder(D, Level, f.name));
                    }
                    break :term one;
                },
                .children, .beside => row_mod.noSuchColumn(Level, f.name, "`.order`"),
            };
            out = out ++ (if (out.len == 0) "" else ", ") ++ term;
        }
        return out;
    }
}

// -- tests ----------------------------------------------------------------

const testing = std.testing;
const Pg = dialect_mod.Postgres;
const Lite = dialect_mod.SQLite;

const Customer = struct {
    pub const nilo_table = .{ .name = "customers" };
    id: i64,
    name: []const u8,
    region: ?[]const u8,
};

const Staff = struct {
    pub const nilo_table = .{ .name = "staff" };
    id: i64,
    full_name: []const u8,
};

const Order = struct {
    pub const nilo_table = .{
        .name = "orders",
        .references = .{
            .customer_id = .{ Customer, .id },
            .owner_id = .{ Staff, .id },
            .approver_id = .{ Staff, .id },
        },
    };
    id: i64,
    status: []const u8,
    total: i64,
    discount: ?i64,
    customer_id: i64,
    owner_id: i64,
    approver_id: ?i64,
    year: i32,
};

const Line = struct {
    pub const nilo_table = .{ .name = "lines", .references = .{ .order_id = .{ Order, .id } } };
    id: i64,
    order_id: i64,
    sku: []const u8,
    qty: i32,
};

const CustomerName = struct {
    pub const nilo_table = Customer;
    name: []const u8,
};

const StaffName = struct {
    pub const nilo_table = Staff;
    full_name: []const u8,
};

const LineBrief = struct {
    pub const nilo_table = Line;
    sku: []const u8,
    qty: i32,
};

const OrderCard = struct {
    pub const nilo_table = Order;
    pub const nilo_via = .{ .owner = .owner_id, .approver = .approver_id };
    id: i64,
    total: i64,
    customer: CustomerName,
    owner: StaffName,
    approver: ?StaffName,
};

const OrderWithLines = struct {
    pub const nilo_table = Order;
    id: i64,
    lines: []const LineBrief,
};

const ByCustomer = struct {
    pub const nilo_table = Order;
    pub const nilo_aggregate = .{ .orders = .count, .revenue = .{ .sum = .total }, .off = .{ .sum = .discount } };
    customer: CustomerName,
    orders: i64,
    revenue: i64,
    off: ?i64,
};

const Totals = struct {
    pub const nilo_table = Order;
    pub const nilo_aggregate = .{ .orders = .count, .revenue = .{ .sum = .total } };
    orders: i64,
    revenue: ?i64,
};

test "a parent is joined under its field's name, and its columns are answered under their path" {
    const found = comptime rows(Pg, OrderCard, @TypeOf(.{}), .many);
    try testing.expectEqualStrings(
        "SELECT \"orders\".\"id\" AS \"id\", \"orders\".\"total\" AS \"total\", " ++
            "\"customer\".\"name\" AS \"customer.name\", \"owner\".\"full_name\" AS \"owner.full_name\", " ++
            "(\"approver\".\"id\" IS NOT NULL) AS \"approver.#\", \"approver\".\"full_name\" AS \"approver.full_name\" " ++
            "FROM \"orders\" JOIN \"customers\" AS \"customer\" ON \"customer\".\"id\" = \"orders\".\"customer_id\" " ++
            "JOIN \"staff\" AS \"owner\" ON \"owner\".\"id\" = \"orders\".\"owner_id\" " ++
            "LEFT JOIN \"staff\" AS \"approver\" ON \"approver\".\"id\" = \"orders\".\"approver_id\"",
        found.sql,
    );
}

test "the width of a shaped Row counts a parent's columns and the key that says it is there" {
    // id, total, customer.name, owner.full_name, approver.#, approver.full_name
    try testing.expectEqual(@as(usize, 6), comptime width(OrderCard));
    try testing.expectEqual(@as(usize, 1), comptime width(OrderWithLines));
}

test "a condition reaches into a parent through its field, and is qualified by its alias" {
    const found = comptime rows(Pg, OrderCard, @TypeOf(.{
        .where = .{ .total = .{ .gt = @as(i64, 10) }, .customer = .{ .name = @as([]const u8, "Acme") } },
    }), .many);
    try testing.expect(std.mem.endsWith(
        u8,
        found.sql,
        " WHERE \"orders\".\"total\" > $1 AND \"customer\".\"name\" = $2",
    ));
    try testing.expectEqual(@as(usize, 2), found.paths.len);
    try testing.expect(found.params[1].of.? == CustomerName);
}

test "an order names the answer's columns, a parent's through its field" {
    const found = comptime rows(Pg, OrderCard, @TypeOf(.{
        .order = .{ .customer = .{ .name = .asc }, .id = .desc },
        .limit = 20,
    }), .many);
    try testing.expect(std.mem.endsWith(u8, found.sql, " ORDER BY \"customer.name\" ASC, \"id\" DESC LIMIT 20"));
    try testing.expectEqual(@as(?usize, 20), found.reserve);
}

test "an order may name a column of the table the Row does not carry, through the table" {
    // Item 86: a tiebreak is a column of the table and not of the answer, so
    // it is written as the table's rather than under an answer's name.
    const found = comptime rows(Pg, OrderCard, @TypeOf(.{
        .order = .{ .customer = .{ .name = .asc }, .year = .desc, .id = .asc },
    }), .many);
    try testing.expect(std.mem.endsWith(
        u8,
        found.sql,
        " ORDER BY \"customer.name\" ASC, \"orders\".\"year\" DESC, \"id\" ASC",
    ));
}

test "a page carries its total under a name no field can have" {
    const found = comptime rows(Pg, OrderCard, @TypeOf(.{ .order = .{ .id = .asc }, .limit = 20 }), .page);
    try testing.expect(std.mem.indexOf(u8, found.sql, ", count(*) OVER () AS \"#total\" FROM") != null);
}

test "a grouped Row groups by its other fields and sums the rest, cast to what the field reads" {
    const found = comptime rows(Pg, ByCustomer, @TypeOf(.{
        .where = .{ .year = @as(i32, 2026), .revenue = .{ .gt = @as(i64, 0) } },
        .order = .{ .revenue = .desc },
        .limit = 10,
    }), .many);
    try testing.expectEqualStrings(
        "SELECT \"customer\".\"name\" AS \"customer.name\", count(*) AS \"orders\", " ++
            "sum(\"orders\".\"total\")::int8 AS \"revenue\", sum(\"orders\".\"discount\")::int8 AS \"off\" " ++
            "FROM \"orders\" JOIN \"customers\" AS \"customer\" ON \"customer\".\"id\" = \"orders\".\"customer_id\" " ++
            "WHERE \"orders\".\"year\" = $1 GROUP BY \"customer\".\"name\" HAVING sum(\"orders\".\"total\") > $2 " ++
            "ORDER BY \"revenue\" DESC LIMIT 10",
        found.sql,
    );
    // The condition on the rows binds as the table's column, the one on the
    // groups as the field's.
    try testing.expect(found.params[0].of.? == Order);
    try testing.expect(found.params[1].of.? == ByCustomer);
}

const ByCustomerOpen = struct {
    pub const nilo_table = Order;
    pub const nilo_aggregate = .{
        .open = .{ .count = .id, .where = .{ .status = .{ .not_in = .{ "paid", "void" } } } },
        .paid = .{ .sum = .total, .where = .{ .status = "paid", .discount = null } },
        .rest = .{ .count = .id, .where = .{ .status = .{ .ne = "it's" }, .year = .{ .gte = 2020, .lt = 2030 } } },
    };
    customer: CustomerName,
    open: i64,
    paid: ?i64,
    rest: i64,
};

test "an aggregate with a .where reads only the rows it matches, the values written in" {
    // Item 85: a sum in one currency beside a count of the rest, the condition
    // on the rows the one aggregate reads rather than on the statement.
    const found = comptime rows(Pg, ByCustomerOpen, @TypeOf(.{
        .where = .{ .paid = .{ .gt = @as(i64, 0) } },
        .order = .{ .paid = .desc },
    }), .many);
    try testing.expectEqualStrings(
        "SELECT \"customer\".\"name\" AS \"customer.name\", " ++
            "count(\"orders\".\"id\") FILTER (WHERE \"orders\".\"status\" NOT IN ('paid', 'void')) AS \"open\", " ++
            "sum(\"orders\".\"total\") FILTER (WHERE \"orders\".\"status\" = 'paid' AND \"orders\".\"discount\" IS NULL)::int8 AS \"paid\", " ++
            "count(\"orders\".\"id\") FILTER (WHERE \"orders\".\"status\" <> 'it''s' AND \"orders\".\"year\" >= 2020 AND \"orders\".\"year\" < 2030) AS \"rest\" " ++
            "FROM \"orders\" JOIN \"customers\" AS \"customer\" ON \"customer\".\"id\" = \"orders\".\"customer_id\" " ++
            "GROUP BY \"customer\".\"name\" " ++
            "HAVING sum(\"orders\".\"total\") FILTER (WHERE \"orders\".\"status\" = 'paid' AND \"orders\".\"discount\" IS NULL) > $1 " ++
            "ORDER BY \"paid\" DESC",
        found.sql,
    );
    // Nothing of the filters binds: the one parameter is the HAVING's.
    try testing.expectEqual(@as(usize, 1), found.paths.len);
    const lite = comptime rows(Lite, ByCustomerOpen, @TypeOf(.{}), .many);
    try testing.expect(std.mem.indexOf(
        u8,
        lite.sql,
        "sum(\"orders\".\"total\") FILTER (WHERE \"orders\".\"status\" = 'paid' AND \"orders\".\"discount\" IS NULL) AS \"paid\"",
    ) != null);
}

test "SQLite reads the same aggregate with no cast, because it answers in the field's type" {
    const found = comptime rows(Lite, ByCustomer, @TypeOf(.{}), .many);
    try testing.expect(std.mem.indexOf(u8, found.sql, "sum(\"orders\".\"total\") AS \"revenue\"") != null);
}

test "a count of a grouped Row counts the groups" {
    const found = comptime tally(Pg, ByCustomer, @TypeOf(.{ .where = .{ .year = @as(i32, 2026) } }), false);
    try testing.expectEqualStrings(
        "SELECT count(*) FROM (SELECT 1 FROM \"orders\" JOIN \"customers\" AS \"customer\" ON " ++
            "\"customer\".\"id\" = \"orders\".\"customer_id\" WHERE \"orders\".\"year\" = $1 " ++
            "GROUP BY \"customer\".\"name\") AS \"#groups\"",
        found.sql,
    );
}

test "a count of a Row with parents joins only the parents its condition names" {
    const none = comptime tally(Pg, OrderCard, @TypeOf(.{ .where = .{ .total = @as(i64, 1) } }), false);
    try testing.expectEqualStrings("SELECT count(*) FROM \"orders\" WHERE \"orders\".\"total\" = $1", none.sql);
    const one = comptime tally(Pg, OrderCard, @TypeOf(.{ .where = .{ .owner = .{ .full_name = @as([]const u8, "x") } } }), true);
    try testing.expectEqualStrings(
        "SELECT EXISTS(SELECT 1 FROM \"orders\" JOIN \"staff\" AS \"owner\" ON \"owner\".\"id\" = " ++
            "\"orders\".\"owner_id\" WHERE \"owner\".\"full_name\" = $1)",
        one.sql,
    );
}

test "a Row grouped by nothing is read with exactlyOne, and has no GROUP BY" {
    const found = comptime exactlyOne(Pg, Totals, @TypeOf(.{ .where = .{ .status = @as([]const u8, "open") } }));
    try testing.expectEqualStrings(
        "SELECT count(*) AS \"orders\", sum(\"orders\".\"total\")::int8 AS \"revenue\" FROM \"orders\" " ++
            "WHERE \"orders\".\"status\" = $1",
        found.sql,
    );
}

const OrderCounted = struct {
    pub const nilo_table = Order;
    pub const nilo_children = .{
        .line_count = .{ .count = Line },
        .big_lines = .{ .count = Line, .where = .{ .qty = .{ .gte = 10 } } },
    };
    id: i64,
    line_count: i64,
    big_lines: i64,
};

const CustomerOrders = struct {
    pub const nilo_table = Customer;
    pub const nilo_children = .{ .orders = .{ .count = Order } };
    name: []const u8,
    orders: i64,
};

const OrderWithCustomerCount = struct {
    pub const nilo_table = Order;
    id: i64,
    customer: CustomerOrders,
};

test "a count of children is a subquery per row, sortable and a condition like a column" {
    // Item 87: how many rather than which.
    const found = comptime rows(Pg, OrderCounted, @TypeOf(.{
        .where = .{ .line_count = .{ .gt = @as(i64, 0) } },
        .order = .{ .big_lines = .desc },
        .limit = 20,
    }), .page);
    const lines = "(SELECT count(*) FROM \"lines\" AS \"#c\" WHERE \"#c\".\"order_id\" = \"orders\".\"id\")";
    try testing.expectEqualStrings(
        "SELECT \"orders\".\"id\" AS \"id\", " ++ lines ++ " AS \"line_count\", " ++
            "(SELECT count(*) FROM \"lines\" AS \"#c\" WHERE \"#c\".\"order_id\" = \"orders\".\"id\" AND \"#c\".\"qty\" >= 10) AS \"big_lines\", " ++
            "count(*) OVER () AS \"#total\" FROM \"orders\" WHERE " ++ lines ++ " > $1 " ++
            "ORDER BY \"big_lines\" DESC LIMIT 20",
        found.sql,
    );
    // A count of a Row that is not the top one correlates with its alias.
    const through = comptime rows(Pg, OrderWithCustomerCount, @TypeOf(.{
        .where = .{ .customer = .{ .orders = .{ .gt = @as(i64, 1) } } },
    }), .many);
    const counted = "(SELECT count(*) FROM \"orders\" AS \"#c\" WHERE \"#c\".\"customer_id\" = \"customer\".\"id\")";
    try testing.expectEqualStrings(
        "SELECT \"orders\".\"id\" AS \"id\", \"customer\".\"name\" AS \"customer.name\", " ++
            counted ++ " AS \"customer.orders\" FROM \"orders\" JOIN \"customers\" AS \"customer\" ON " ++
            "\"customer\".\"id\" = \"orders\".\"customer_id\" WHERE " ++ counted ++ " > $1",
        through.sql,
    );
}

const OrderWithOrderedLines = struct {
    pub const nilo_table = Order;
    pub const nilo_children = .{ .lines = .{ .order = .{ .qty = .desc }, .where = .{ .sku = .{ .ne = "void" } } } };
    id: i64,
    lines: []const LineBrief,
};

test "a children field takes an order and a condition, and the key still breaks a tie" {
    const pg = comptime children(Pg, OrderWithOrderedLines, "lines");
    try testing.expectEqualStrings(
        "SELECT \"lines\".\"sku\" AS \"sku\", \"lines\".\"qty\" AS \"qty\", \"#k\".\"key\" AS \"#parent\" " ++
            "FROM unnest($1::int8[]) WITH ORDINALITY AS \"#k\"(\"value\", \"key\") " ++
            "JOIN \"lines\" ON \"lines\".\"order_id\" = \"#k\".\"value\" WHERE \"lines\".\"sku\" <> 'void' " ++
            "ORDER BY \"#k\".\"key\", \"lines\".\"qty\" DESC, \"lines\".\"id\"",
        pg.sql,
    );
}

test "children are one statement for every parent, numbered by the parent they belong to" {
    const pg = comptime children(Pg, OrderWithLines, "lines");
    try testing.expectEqualStrings(
        "SELECT \"lines\".\"sku\" AS \"sku\", \"lines\".\"qty\" AS \"qty\", \"#k\".\"key\" AS \"#parent\" " ++
            "FROM unnest($1::int8[]) WITH ORDINALITY AS \"#k\"(\"value\", \"key\") " ++
            "JOIN \"lines\" ON \"lines\".\"order_id\" = \"#k\".\"value\" ORDER BY \"#k\".\"key\", \"lines\".\"id\"",
        pg.sql,
    );
    const lite = comptime children(Lite, OrderWithLines, "lines");
    try testing.expect(std.mem.indexOf(u8, lite.sql, "FROM json_each(?1) AS \"#k\" JOIN \"lines\"") != null);
    try testing.expect(pg.params[0].list);
}

test "a find over a shaped Row names its key through the relation" {
    const found = comptime find(Pg, OrderCard, i64);
    try testing.expect(std.mem.endsWith(u8, found.sql, " WHERE \"orders\".\"id\" = $1 LIMIT 1"));
}

test "a condition inside an exists correlates with the table the statement reads" {
    const found = comptime rows(Pg, OrderWithLines, @TypeOf(.{
        .where = .{ .exists = .{.{ .in = Line, .where = .{ .qty = .{ .gt = @as(i32, 5) } } }} },
    }), .many);
    try testing.expect(std.mem.indexOf(
        u8,
        found.sql,
        "EXISTS (SELECT 1 FROM \"lines\" WHERE \"lines\".\"order_id\" = \"orders\".\"id\" AND \"lines\".\"qty\" > $1)",
    ) != null);
}
