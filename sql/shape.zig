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
    /// Whether the join leaves out a row of the table the statement reads:
    /// inner over a reference that may be null (item 109), or a required
    /// parent, whose row may be missing. A count joins it whatever its
    /// condition names, or it would count rows the list leaves out.
    narrows: bool = false,
};

/// One column of the answer.
const Output = struct {
    /// What the `SELECT` list reads, any cast included.
    read: []const u8,
    /// The name it is answered under.
    name: []const u8,
    /// What `GROUP BY` repeats for it, or null for an aggregate.
    group: ?[]const u8,
    /// What an `ORDER BY` writes for it in place of its name, or null to write
    /// the name. Set for a column read as text (`Decimal`, `Interval`, `Inet`
    /// and an aggregate over one): Postgres reads a bare name in `ORDER BY`
    /// against the answer's names first, so `ORDER BY "total"` sorts the text
    /// `"total"::text` and puts `9.00` after `100.5`. The expression under the
    /// cast is not an answer's name, so it sorts the number
    /// ([ADR 218](../docs/adr/218-a-row-may-carry-its-parent-its-children-or-a-sum.md)).
    bare: ?[]const u8 = null,
};

/// A term `GROUP BY` names that the answer does not carry: the key of a
/// parent whose columns are read, or of the row a `nilo_through` value came from.
const GroupKey = struct {
    /// Never a name an `.order` can say, so a run-time ordering never
    /// mistakes it for one it already has.
    name: []const u8,
    expr: []const u8,
};

/// Everything a statement over a shaped Row is written from, worked out once.
const Layout = struct {
    relation: []const u8,
    joins: []const Join,
    outputs: []const Output,
    /// For a grouped Row, the key of each parent it reads, which `GROUP BY`
    /// repeats without selecting: a group is one parent, not every parent
    /// that shares a name ([ADR 218](../docs/adr/218-a-row-may-carry-its-parent-its-children-or-a-sum.md)).
    keys: []const GroupKey = &.{},
};

/// How many columns of the answer a Row fills, parents included: what a
/// reader walks, and what the width check asks for.
pub fn width(comptime Row: type) usize {
    comptime {
        var n: usize = 0;
        const row_info = @typeInfo(Row).@"struct";
        for (row_info.field_names, row_info.field_types) |f_name, f_type| {
            n += switch (row_mod.kindWith(Row, f_name, f_type)) {
                .column, .aggregate, .over_children, .through => 1,
                .parent => (if (@typeInfo(f_type) == .optional) 1 else 0) +
                    width(row_mod.parentRowOf(f_type).?),
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
        @setEvalBranchQuota(row_mod.shapeBudget(Row));
        const relation = statement.relation(D, Row);
        var joins: []const Join = &.{};
        var outputs: []const Output = &.{};
        var wanted: []const GroupKey = &.{};
        visit(D, Row, Row, relation, &.{}, relation, false, &joins, &outputs, &wanted);
        // A key the answer already groups by is not written twice.
        var keys: []const GroupKey = &.{};
        for (wanted) |k| {
            var seen = false;
            for (outputs) |o| {
                if (o.group) |g| if (std.mem.eql(u8, g, k.expr)) {
                    seen = true;
                };
            }
            for (keys) |had| if (std.mem.eql(u8, had.expr, k.expr)) {
                seen = true;
            };
            if (!seen) keys = keys ++ &[_]GroupKey{k};
        }
        // The tables an aggregate's `.where` reaches through a reference,
        // after the parents: a hop's `ON` names the relation or another
        // hop, never a parent's alias.
        if (row_mod.isGrouped(Row)) {
            for (where_mod.aggregateHops(D, Row, relation)) |hop| {
                joins = joins ++ &[_]Join{.{ .alias = hop.alias, .text = hop.text }};
            }
        }
        return .{ .relation = relation, .joins = joins, .outputs = outputs, .keys = keys };
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
    comptime keys: *[]const GroupKey,
) void {
    comptime {
        const level_info = @typeInfo(Level).@"struct";
        for (level_info.field_names, level_info.field_types) |f_name, f_type| {
            const at = path ++ &[_][]const u8{f_name};
            const name = row_mod.pathName(at);
            switch (row_mod.kindWith(Level, f_name, f_type)) {
                .column => {
                    const column = here ++ "." ++ D.quote(f_name);
                    outputs.* = outputs.* ++ &[_]Output{.{
                        .read = D.readAs(column, f_type),
                        .name = name,
                        .group = column,
                        .bare = if (types_mod.asText(f_type) != null) column else null,
                    }};
                },
                .aggregate => {
                    const aggregate = row_mod.aggregateOf(Level, f_name).?;
                    const call = where_mod.aggregateCall(D, Level, relation, aggregate);
                    outputs.* = outputs.* ++ &[_]Output{.{
                        .read = D.readAggregate(call, aggregate.kind, f_type),
                        .name = name,
                        .group = null,
                        .bare = if (types_mod.asText(f_type) != null) call else null,
                    }};
                },
                .parent => {
                    const Parent = row_mod.parentRowOf(f_type).?;
                    const link = parentLink(Level, f_name);
                    const optional = @typeInfo(f_type) == .optional;
                    const alias = D.quote(name);
                    // Against the bare table name as well as the relation: a
                    // table with a schema is `"app"."orders"`, whose name in
                    // the `FROM` is still `"orders"`, and Postgres refuses
                    // *table name specified more than once* for the pair.
                    if (std.mem.eql(u8, alias, relation) or
                        std.mem.eql(u8, alias, D.quote(row_mod.qualifiedOf(Top).table))) @compileError(
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
                        // An inner join leaves out a row whose parent is not
                        // there, which a table without the foreign key, or
                        // one deferred inside a transaction, can hold. So a
                        // count joins it too, or it counts rows the list
                        // drops: a page at offset 1 read a total of 1 over a
                        // list that was empty.
                        .narrows = !left,
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
                    // A grouped Row groups by what identifies the parent, or two
                    // parents that share a name are one row with their sums added.
                    if (row_mod.isGrouped(Top)) {
                        for (link.targets) |target| keys.* = keys.* ++ &[_]GroupKey{.{
                            .name = name ++ ".#" ++ target,
                            .expr = alias ++ "." ++ D.quote(target),
                        }};
                    }
                    visit(D, Top, Parent, alias, at, relation, left, joins, outputs, keys);
                },
                .over_children => outputs.* = outputs.* ++ &[_]Output{.{
                    .read = overChildrenRead(D, Level, f_name, f_type, here),
                    .name = name,
                    .group = null,
                }},
                .through => {
                    if (optional_above and row_mod.throughEntry(Level, f_name).inner) @compileError(
                        "nilo: " ++ @typeName(Top) ++ " reads `." ++ row_mod.pathName(at) ++ "` with `.join = " ++
                            ".inner`, inside a parent that may be missing.\n" ++
                            "  The parent is an outer join, and an inner one after it would leave out " ++
                            "every row whose parent is missing, not only those the path does not reach. " ++
                            "Read the field as optional, or say `.otherwise`.",
                    );
                    const reached = throughOf(D, Level, f_name, here, row_mod.pathName(path), optional_above);
                    for (reached.joins) |j| {
                        const seen = for (joins.*) |had| {
                            if (std.mem.eql(u8, had.alias, j.alias)) break true;
                        } else false;
                        if (!seen) joins.* = joins.* ++ &[_]Join{j};
                    }
                    outputs.* = outputs.* ++ &[_]Output{.{
                        .read = D.readAs(reached.read, f_type),
                        .name = name,
                        .group = reached.read,
                        .bare = if (types_mod.asText(f_type) != null) reached.read else null,
                    }};
                    // Grouped by the referenced row too, not only its value: two
                    // customers named alike are two groups.
                    if (row_mod.isGrouped(Top) and reached.key.len > 0) {
                        keys.* = keys.* ++ &[_]GroupKey{.{ .name = name ++ ".#through", .expr = reached.key }};
                    }
                },
                .children, .beside => {},
            }
        }
    }
}

// -- a column through a reference -----------------------------------------

/// The alias every table a `nilo_through` field reaches is joined under
/// starts with this, then the path of the level the field sits on, a `/`,
/// and the reference columns followed: `"#t/customer_id"`,
/// `"#t.approver/org_unit_id.customer_id"`. `#` begins no field name, so no
/// parent's alias meets one, and the `.` after a hop keeps `reachedBy`
/// joining the hops before it.
const through_prefix = "#t";

/// What a `nilo_through` field reads, with no Dialect involved: the column's
/// type, whether a join on the way may find nothing, and the Row and column
/// at the end, which an `.otherwise` is written for.
const ThroughColumn = struct {
    T: type,
    nullable_reference: bool,
    /// Whether a join on the way is inner over a reference that may be null,
    /// so that the row is left out rather than read with nothing there.
    narrows: bool,
    Target: type,
    last: []const u8,
};

fn throughColumn(comptime Level: type, comptime field: []const u8) ThroughColumn {
    comptime {
        const steps = row_mod.throughPath(Level, field);
        const what = @typeName(Level) ++ "'s `." ++ field ++ "`";
        var R = row_mod.ownerOf(Level);
        var nullable = false;
        var narrows = false;
        var chain: []const u8 = "";
        for (steps[0 .. steps.len - 1], 0..) |column, i| {
            if (!row_mod.hasColumn(R, column)) row_mod.noSuchColumn(R, column, what);
            const pointed = table_mod.pointedFrom(R, column) orelse throughWithoutReference(Level, field, R, column);
            chain = chain ++ (if (i == 0) "" else ".") ++ column;
            if (@typeInfo(row_mod.ColumnType(R, column)) == .optional) {
                if (joinedInner(Level, chain)) narrows = true else nullable = true;
            }
            R = pointed.row;
        }
        const last = steps[steps.len - 1];
        if (!row_mod.hasColumn(R, last)) row_mod.noSuchColumn(R, last, what);
        return .{
            .T = row_mod.ColumnType(R, last),
            .nullable_reference = nullable,
            .narrows = narrows,
            .Target = R,
            .last = last,
        };
    }
}

/// Whether the hop `chain` (`"deal_id"`, `"org_unit_id.customer_id"`) is an
/// inner join on `Level`: some field there says `.join = .inner` and goes
/// through it. **Asked of the Row rather than of one field**, because two
/// fields that go the same way share the join (item 109): once one of them
/// leaves out a row the path does not reach, every field through that hop
/// reads a row that is there, and is held to the type that says so.
fn joinedInner(comptime Level: type, comptime chain: []const u8) bool {
    comptime {
        for (row_mod.fieldsOfKind(Level, .through)) |name| {
            const entry = row_mod.throughEntry(Level, name);
            if (!entry.inner) continue;
            var own: []const u8 = "";
            for (entry.path[0 .. entry.path.len - 1], 0..) |column, i| {
                own = own ++ (if (i == 0) "" else ".") ++ column;
                if (std.mem.eql(u8, own, chain)) return true;
            }
        }
        return false;
    }
}

fn throughWithoutReference(comptime Level: type, comptime field: []const u8, comptime R: type, comptime column: []const u8) noreturn {
    @compileError(
        "nilo: " ++ @typeName(Level) ++ "'s `." ++ field ++ "` goes through `" ++ column ++ "`, and " ++
            @typeName(R) ++ " declares no `.references` of that one column to a Row.\n" ++
            "  A field read through a reference follows one the schema already says. Add " ++
            "`.references = .{ ." ++ column ++ " = .{ <Row>, .id } }` to " ++ @typeName(R) ++
            "'s " ++ row_mod.marker ++ ", or read the column from a Row that has it.",
    );
}

/// The joins a `nilo_through` field needs and what it reads, written from
/// `here`, the relation or alias of the level it sits on. A join is outer
/// when its reference may be null or anything above it is, the way a
/// parent's is, and inner when a field through it says `.join = .inner`.
/// `read` is the column, or `COALESCE(column, value)` for an `.otherwise`,
/// which is what the `SELECT` list, a condition, an order and a group all
/// name, so the four agree about a row the path did not reach.
///
/// `key` is the first referenced row's key under its alias, or empty when the
/// field sits on its own level: what identifies the row the value came from,
/// which a grouped Row's `GROUP BY` needs beside the value.
const Through = struct { joins: []const Join, read: []const u8, alias: []const u8, key: []const u8 = "" };

pub fn throughOf(
    comptime D: type,
    comptime Level: type,
    comptime field: []const u8,
    comptime here: []const u8,
    comptime level: []const u8,
    comptime optional_above: bool,
) Through {
    comptime {
        const entry = row_mod.throughEntry(Level, field);
        const steps = entry.path;
        var R = row_mod.ownerOf(Level);
        var at = here;
        var alias: []const u8 = through_prefix ++ (if (level.len == 0) "" else "." ++ level) ++ "/";
        var chain: []const u8 = "";
        var left = optional_above;
        var joins: []const Join = &.{};
        var key: []const u8 = "";
        for (steps[0 .. steps.len - 1], 0..) |column, i| {
            const pointed = table_mod.pointedFrom(R, column) orelse throughWithoutReference(Level, field, R, column);
            chain = chain ++ (if (i == 0) "" else ".") ++ column;
            const nullable = @typeInfo(row_mod.ColumnType(R, column)) == .optional;
            const inner = joinedInner(Level, chain);
            if (nullable and !inner) left = true;
            alias = alias ++ (if (i == 0) "" else ".") ++ column;
            const quoted = D.quote(alias);
            joins = joins ++ &[_]Join{.{
                .alias = alias,
                .text = (if (left) " LEFT JOIN " else " JOIN ") ++ statement.relation(D, pointed.row) ++
                    " AS " ++ quoted ++ " ON " ++ quoted ++ "." ++ D.quote(pointed.target) ++
                    " = " ++ at ++ "." ++ D.quote(column),
                // Inner is inner: a row whose referenced row is missing is
                // left out, whether or not the reference can be null, and a
                // count that skipped the join would count it (the parent's
                // join says the same, above).
                .narrows = !left,
            }};
            if (i == 0) key = quoted ++ "." ++ D.quote(pointed.target);
            at = quoted;
            R = pointed.row;
        }
        const last = steps[steps.len - 1];
        const column = at ++ "." ++ D.quote(last);
        const read = if (entry.otherwise)
            "COALESCE(" ++ column ++ ", " ++ table_mod.literalText(
                R,
                @typeName(Level) ++ "'s " ++ row_mod.through_marker ++ " `." ++ field ++ "` `.otherwise`",
                last,
                @field(@field(Level, row_mod.through_marker), field).otherwise,
            ) ++ ")"
        else
            column;
        return .{ .joins = joins, .read = read, .alias = alias, .key = key };
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
/// meets it. The tables the entry's `.where` reaches are joined inside the
/// subquery under aliases that start with it: `"#c.state_id"`.
const counted_alias = "#c";

/// A figure over the rows pointing back as its statement reads it: a
/// subquery correlated with the row it sits on, written `here`.
///
/// ```sql
/// (SELECT count(*) FROM "lines" AS "#c" WHERE "#c"."order_id" = "orders"."id")
/// (SELECT max("#c"."target_date") FROM "work_items" AS "#c"
///    JOIN "work_item_states" AS "#c.state_id" ON "#c.state_id"."id" = "#c"."state_id"
///  WHERE "#c"."epic_id" = "work_epics"."id" AND "#c.state_id"."category" NOT IN ('done'))
/// ```
///
/// **A subquery per row rather than a join and a `GROUP BY`**, because it is
/// the shape that keeps the Row one row per row of its table and `.limit`
/// counting those: a page of twenty asks twenty index lookups of the counted
/// table's reference column, and never counts the rows of a parent the page
/// does not show. The same text in the `SELECT` list and in a condition, the
/// way an aggregate's call is. The entry's `.where` goes in with its values
/// written (`table.literalReaching`), as an aggregate's does, and a table it
/// reaches through a reference is joined inside the subquery: a reference
/// points at one row or none, so the rows counted stay the rows pointing back
/// (item 100).
pub fn overChildrenCall(comptime D: type, comptime Row: type, comptime field: []const u8, comptime here: []const u8) []const u8 {
    comptime {
        const over = row_mod.overChildrenOf(Row, field);
        if (over.column) |c| dialect_mod.assertDecimalCompares(
            D,
            over.Child,
            c,
            row_mod.ColumnType(row_mod.ownerOf(over.Child), c),
            "`" ++ over.word ++ "` (field `." ++ field ++ "`)",
        );
        const link = backLink(Row, field, over.Child, overHow(over));
        const alias = D.quote(counted_alias);
        var joined: []const u8 = "";
        for (link.columns, link.targets, 0..) |column, target, i| {
            joined = joined ++ (if (i == 0) "" else " AND ") ++ alias ++ "." ++ D.quote(column) ++
                " = " ++ here ++ "." ++ D.quote(target);
        }
        var hops: []const u8 = "";
        const entry = @field(@field(Row, row_mod.children_marker), field);
        if (@hasField(@TypeOf(entry), "where")) {
            const reached = table_mod.literalReaching(
                D,
                row_mod.ownerOf(over.Child),
                alias,
                counted_alias,
                @typeName(Row) ++ "'s `." ++ field ++ "` `.where`",
                entry.where,
            );
            for (reached.hops) |h| hops = hops ++ h.text;
            joined = joined ++ " AND " ++ reached.sql;
        }
        const call = if (over.column) |c| over.word ++ "(" ++ alias ++ "." ++ D.quote(c) ++ ")" else "count(*)";
        return "(SELECT " ++ call ++ " FROM " ++ statement.relation(D, over.Child) ++ " AS " ++ alias ++
            hops ++ " WHERE " ++ joined ++ ")";
    }
}

/// The same subquery as the `SELECT` list reads it: a `.max` or `.min` cast
/// the way a grouped Row's is (`D.readAggregate`), since a column read as
/// text is read as text here too. A count is already the `int8` its field is.
fn overChildrenRead(comptime D: type, comptime Row: type, comptime field: []const u8, comptime F: type, comptime here: []const u8) []const u8 {
    comptime {
        const over = row_mod.overChildrenOf(Row, field);
        const call = overChildrenCall(D, Row, field, here);
        if (over.column == null) return call;
        return D.readAggregate(call, std.meta.stringToEnum(dialect_mod.Aggregate, over.word).?, F);
    }
}

/// What a message says a figure over the rows pointing back reads them as.
fn overHow(comptime over: row_mod.OverChildren) []const u8 {
    return if (over.column) |c| "as the " ++ over.word ++ " of `" ++ c ++ "`" else "as a count";
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
        @setEvalBranchQuota(row_mod.shapeBudget(Row));
        const decl = @field(Row, row_mod.marker);
        if (@TypeOf(decl) != type) @compileError(
            "nilo: " ++ @typeName(Row) ++ " carries a parent, children or an aggregate, and is " ++
                (if (@TypeOf(decl) == @TypeOf(.enum_literal)) "a projection" else "not a narrower Row") ++ ".\n" ++
                "  Those belong to a Row that reads a table without describing it: `pub const " ++
                row_mod.marker ++ " = <TheTablesRow>;`.",
        );
        const Owner = row_mod.ownerOf(Row);
        const grouped = row_mod.isGrouped(Row);

        const row_info = @typeInfo(Row).@"struct";
        for (row_info.field_names, row_info.field_types) |f_name, f_type| {
            switch (row_mod.kindWith(Row, f_name, f_type)) {
                .parent => assertParentRow(Row, f_name),
                .children => {
                    if (grouped) @compileError(
                        "nilo: " ++ @typeName(Row) ++ " is grouped and reads `" ++ f_name ++ "` as children.\n" ++
                            "  A group is many rows, and children belong to one. Read the children " ++
                            "through a Row that is not grouped.",
                    );
                    const found = childrenOf(Row, f_name);
                    if (row_mod.isGrouped(found.Child)) @compileError(
                        "nilo: " ++ @typeName(Row) ++ "'s children `" ++ f_name ++ "` are " ++
                            @typeName(found.Child) ++ ", which is grouped.\n" ++
                            "  A child is one row of the table that points back. A total over them " ++
                            "is a grouped Row read on its own.",
                    );
                    if (row_mod.fieldsOfKind(found.Child, .children).len > 0) @compileError(
                        "nilo: " ++ @typeName(Row) ++ "'s children `" ++ f_name ++ "` are " ++
                            @typeName(found.Child) ++ ", which has children of its own.\n" ++
                            "  One level is read for every parent at once; a second would be a " ++
                            "third statement per level. Read the grandchildren with their own call.",
                    );
                    assertChildRow(found.Child);
                },
                .aggregate => assertAggregate(Row, Owner, f_name, f_type),
                .through => assertThrough(Row, f_name, f_type),
                .over_children => {
                    const over = row_mod.overChildrenOf(Row, f_name);
                    if (grouped) @compileError(
                        "nilo: " ++ @typeName(Row) ++ " is grouped and reads `" ++ f_name ++ "` " ++
                            overHow(over) ++ " over the rows pointing back.\n" ++
                            "  That belongs to one row, and a group is many. Read it through a Row " ++
                            "that is not grouped.",
                    );
                    if (over.column) |column| {
                        const C = row_mod.ColumnType(row_mod.ownerOf(over.Child), column);
                        assertOrdersForMinMax(Row, f_name, over.word, column, C);
                        const Bare = switch (@typeInfo(C)) {
                            .optional => |o| o.child,
                            else => C,
                        };
                        if (f_type != ?Bare) @compileError(
                            "nilo: " ++ @typeName(Row) ++ " reads `." ++ f_name ++ "`, the " ++ over.word ++
                                " of `" ++ column ++ "` over the rows pointing back, as " ++
                                @typeName(f_type) ++ ".\n" ++
                                "  It answers the column's own type, and null for a row none point " ++
                                "back at: `" ++ f_name ++ ": ?" ++ @typeName(Bare) ++ "`.",
                        );
                    } else if (f_type != i64) @compileError(
                        "nilo: " ++ @typeName(Row) ++ " reads `." ++ f_name ++ "`, a count, as " ++
                            @typeName(f_type) ++ ".\n" ++
                            "  A count is a whole number and is never null, none included: `" ++
                            f_name ++ ": i64`.",
                    );
                    _ = backLink(Row, f_name, over.Child, overHow(over));
                },
                .column, .beside => {},
            }
        }
        if (@hasDecl(Row, row_mod.children_marker)) assertChildrenMarker(Row);
        if (@hasDecl(Row, row_mod.via_marker)) {
            const via_info = @typeInfo(@TypeOf(@field(Row, row_mod.via_marker))).@"struct";
            for (via_info.field_names) |e_name| {
                switch (row_mod.kindOf(Row, e_name)) {
                    .parent, .children, .over_children => {},
                    else => @compileError(
                        "nilo: " ++ @typeName(Row) ++ "'s " ++ row_mod.via_marker ++ " names `" ++ e_name ++
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
/// list, one of `.count`, `.max` and `.min` and a `.where` for a figure over
/// them.
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
        const d_info = @typeInfo(D).@"struct";
        for (d_info.field_names, d_info.field_types) |e_name, e_type| {
            if (row_mod.fieldTypeOf(Row, e_name) == null) @compileError(
                head ++ " names `" ++ e_name ++ "`, which is not one of its fields." ++ shape,
            );
            const E = e_type;
            if (@typeInfo(E) != .@"struct" or @typeInfo(E).@"struct".is_tuple) @compileError(
                head ++ " gives `." ++ e_name ++ "` a " ++ @typeName(E) ++ "." ++ shape,
            );
            const allowed: []const []const u8 = switch (row_mod.kindOf(Row, e_name)) {
                .children => &.{ "order", "where" },
                .over_children => &.{ "count", "max", "min", "where" },
                else => @compileError(
                    head ++ " names `" ++ e_name ++ "`, which is not a list of children.\n" ++
                        "  An entry orders or narrows a field of type `[]const <Row>`, counts " ++
                        "with `.{ .count = <Row> }` into a field of type `i64`, or reads " ++
                        "`.{ .max = .{ <Row>, .<column> } }` or `.min` into an optional of the column's type.",
                ),
            };
            const e_info = @typeInfo(E).@"struct";
            for (e_info.field_names) |w_name| {
                for (allowed) |ok| {
                    if (std.mem.eql(u8, w_name, ok)) break;
                } else @compileError(
                    head ++ " gives `." ++ e_name ++ "` a `." ++ w_name ++ "`, which it does not take.\n" ++
                        "  A list of children takes `.order` and `.where`; a figure over them takes " ++
                        "one of `.count`, `.max` and `.min`, and `.where`.",
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
        const parent_info = @typeInfo(Parent).@"struct";
        for (parent_info.field_names, parent_info.field_types) |f_name, f_type| {
            switch (row_mod.kindWith(Parent, f_name, f_type)) {
                .children => @compileError(
                    "nilo: " ++ @typeName(Holder) ++ "'s parent `" ++ field ++ "` is " ++ @typeName(Parent) ++
                        ", which reads children.\n" ++
                        "  Children are read for the rows of the statement, and a parent is joined " ++
                        "into it. Read them at the top of a Row of their own.",
                ),
                .parent => assertParentRow(Parent, f_name),
                .through => assertThrough(Parent, f_name, f_type),
                else => {},
            }
        }
        _ = parentLink(Holder, field);
    }
}

/// A `nilo_through` field has the column's type, optional exactly when a
/// reference on the way or the column itself may be null: the rule a parent
/// field is held to, for the same two reasons. An `.otherwise` stands in for
/// that null, so the field is the column's own type then, and `.join =
/// .inner` takes the reference's null away by leaving the row out (item 109).
fn assertThrough(comptime Row: type, comptime field: []const u8, comptime F: type) void {
    comptime {
        const entry = row_mod.throughEntry(Row, field);
        const read = throughColumn(Row, field);
        const head = "nilo: " ++ @typeName(Row) ++ "'s " ++ row_mod.through_marker ++ " `." ++ field ++ "`";
        if (entry.inner and !read.narrows) @compileError(
            head ++ " says `.join = .inner`, and no reference on its path may be null.\n" ++
                "  Every row reaches the column already, so there is no row to leave out. " ++
                "Take `.join` off.",
        );
        const Bare = switch (@typeInfo(read.T)) {
            .optional => |o| o.child,
            else => read.T,
        };
        const nullable = read.nullable_reference or @typeInfo(read.T) == .optional;
        if (entry.otherwise and !nullable) @compileError(
            head ++ " says `.otherwise`, and the column is " ++ @typeName(read.T) ++
                (if (read.narrows) " behind an inner join" else "") ++ ", so it is never null.\n" ++
                "  Every row has a value for it to stand in for. Take `.otherwise` off.",
        );
        if (entry.otherwise) {
            if (F != Bare) @compileError(
                "nilo: " ++ @typeName(Row) ++ " reads `." ++ field ++ "` through a reference as " ++
                    @typeName(F) ++ ", and its `.otherwise` stands in for every null.\n" ++
                    "  Write `" ++ field ++ ": " ++ @typeName(Bare) ++ "`: a row the path does not " ++
                    "reach reads the `.otherwise`.",
            );
            return;
        }
        const Want = if (nullable) ?Bare else Bare;
        if (F != Want) @compileError(
            "nilo: " ++ @typeName(Row) ++ " reads `." ++ field ++ "` through a reference as " ++
                @typeName(F) ++ ", and the column is " ++ @typeName(read.T) ++
                (if (read.nullable_reference) " behind a reference that may be null" else "") ++ ".\n" ++
                "  Write `" ++ field ++ ": " ++ @typeName(Want) ++ "`" ++
                (if (nullable)
                    ": a row whose reference or column is null has nothing to read. `.otherwise = " ++
                        "<value>` says what it reads instead, and `.join = .inner` leaves it out."
                else
                    ": every row has one, so a `?` is a branch no caller takes."),
        );
    }
}

/// A Row a children field holds, checked the way a statement over it would
/// check it: its parents resolve.
fn assertChildRow(comptime Row: type) void {
    comptime {
        const row_info = @typeInfo(Row).@"struct";
        for (row_info.field_names, row_info.field_types) |f_name, f_type| {
            switch (row_mod.kindWith(Row, f_name, f_type)) {
                .parent => assertParentRow(Row, f_name),
                .through => assertThrough(Row, f_name, f_type),
                else => {},
            }
        }
    }
}

/// `min` and `max` are over a column with an order the database defines for
/// it. Postgres has no `max(boolean)`, `max(uuid)`, `max(json)`, `max(jsonb)`
/// or `max(bytea)` (17.10: *function max(boolean) does not exist*), so a Row
/// reading one compiled and failed on the first request; and SQLite would
/// answer for all of them, by its storage class's order, which is not an order
/// anybody asked for and is not the one Postgres would give. So the four are
/// refused on both (ADR 055). An enum is not in the four: Postgres orders it
/// by declaration and SQLite by its name as text, which is a difference this
/// does not close.
///
/// `over_children` (`word` is `max` or `min`) is asked the same, so both places
/// a `min` or `max` is read say the same words.
fn assertOrdersForMinMax(
    comptime Row: type,
    comptime field: []const u8,
    comptime word: []const u8,
    comptime column: []const u8,
    comptime C: type,
) void {
    comptime {
        const Bare = switch (@typeInfo(C)) {
            .optional => |o| o.child,
            else => C,
        };
        const kind: ?[]const u8 = if (Bare == bool)
            "a bool"
        else if (Bare == types_mod.Uuid)
            "a Uuid"
        else if (types_mod.isBytes(Bare))
            "Bytes"
        else if (types_mod.jsonPayload(Bare) != null)
            "Json"
        else if (types_mod.asText(Bare)) |named| blk: {
            const unordered = [_][]const u8{ "json", "jsonb", "uuid", "bytea", "bool", "boolean" };
            for (unordered) |name| {
                if (std.mem.eql(u8, named, name)) break :blk "a " ++ named ++ " column";
            }
            break :blk null;
        } else null;
        if (kind) |what| @compileError(
            "nilo: " ++ @typeName(Row) ++ " reads `." ++ field ++ "`, the " ++ word ++ " of `" ++ column ++
                "`, which is " ++ what ++ ".\n" ++
                "  Postgres has no `" ++ word ++ "` over it (*function " ++ word ++
                "(…) does not exist*), and SQLite would answer in an order nobody chose. " ++
                "Count the rows with the value you mean, or read the first row in the order " ++
                "you mean with `.order` and a limit of one.",
        );
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
            .min, .max => blk: {
                assertOrdersForMinMax(Row, field, words, column, C);
                break :blk CBare;
            },
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
pub const Answers = enum { many, first, page, feed };

/// What a read of a shaped Row takes. No `.lock`, which `assertNoLock` says
/// why; `db.one` has no `.limit`, because it compiles its own.
const known = [_][]const u8{ "where", "order", "limit", "offset", "after" };
const known_first = [_][]const u8{ "where", "order", "offset" };

/// The terms a grouped Row's rows are told apart by: every column it groups
/// by, and the key of each parent, in the order the statement groups them. A
/// group has no key of its own, and its `GROUP BY` list is what identifies it.
fn groupTerms(comptime layout: Layout) []const GroupKey {
    comptime {
        var out: []const GroupKey = &.{};
        for (layout.outputs) |o| {
            const g = o.group orelse continue;
            // Whether a parent is there follows from its key.
            if (std.mem.endsWith(u8, o.name, ".#")) continue;
            out = out ++ &[_]GroupKey{.{ .name = o.name, .expr = g }};
        }
        return out ++ layout.keys;
    }
}

/// The field paths an `.order` names, as the answer calls them:
/// `.{ .revenue = .desc, .customer = .{ .name = .asc } }` names `revenue` and
/// `customer.name`.
fn orderNames(comptime T: type, comptime path: []const []const u8) []const []const u8 {
    comptime {
        var out: []const []const u8 = &.{};
        const t_info = @typeInfo(T).@"struct";
        for (t_info.field_names, t_info.field_types) |f_name, f_type| {
            const at = path ++ &[_][]const u8{f_name};
            if (@typeInfo(f_type) == .@"struct") {
                out = out ++ orderNames(f_type, at);
            } else out = out ++ &[_][]const u8{row_mod.pathName(at)};
        }
        return out;
    }
}

/// `statement.tiebreak` for a shaped Row. A grouped Row's tiebreak is every
/// term it groups by that the `.order` did not name, running the way the
/// order's last term runs ([ADR 150](../docs/adr/150-a-page-knows-what-it-left-out.md#a-page-ends-in-the-key)):
/// two groups with the same revenue would otherwise change places between the
/// request for page one and the request for page two.
fn tiebreakFor(comptime D: type, comptime Row: type, comptime Sort: type, comptime layout: Layout) []const u8 {
    comptime {
        if (!row_mod.isGrouped(Row)) return statement.tiebreak(D, Row, Sort, layout.relation ++ ".");
        const named = orderNames(Sort, &.{});
        const way = if (statement.lastDescending(Sort)) " DESC" else " ASC";
        var out: []const u8 = "";
        for (groupTerms(layout)) |k| {
            const said = for (named) |n| {
                if (std.mem.eql(u8, n, k.name)) break true;
            } else false;
            if (said) continue;
            out = out ++ (if (out.len == 0) "" else ", ") ++ k.expr ++ way;
        }
        return out;
    }
}

/// `statement.tiesOf` for a shaped Row.
fn tiesFor(comptime D: type, comptime Row: type, comptime layout: Layout) []const statement.Tie {
    comptime {
        if (!row_mod.isGrouped(Row)) return statement.tiesOf(D, Row, layout.relation ++ ".");
        var out: []const statement.Tie = &.{};
        for (groupTerms(layout)) |k| {
            out = out ++ &[_]statement.Tie{.{ .column = k.name, .text = k.expr ++ " ASC" }};
        }
        return out;
    }
}

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
        @setEvalBranchQuota(row_mod.shapeBudget(Row));
        assertShape(Row);
        const call = switch (answers) {
            .many => "`db.select`",
            .first => "`db.one`",
            .page => "`db.page`",
            .feed => "`db.feed`",
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
        if (answers == .feed) statement.assertFeed(Row, O);
        if (answers == .page and @hasField(O, "after")) @compileError(
            "nilo: `db.page` on " ++ @typeName(Row) ++ " was given an `.after`.\n" ++
                "  A page skips rows by `OFFSET` and counts every match; a cursor reads the rows " ++
                "after one and has no page for a count to be relative to. Read it with `db.feed`, " ++
                "which says whether there are more.",
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
        var ties: []const statement.Tie = &.{};
        var head: []const u8 = "";
        if (@hasField(O, "order")) {
            const Sort = @FieldType(O, "order");
            const cut = @hasField(O, "limit") or @hasField(O, "offset") or answers != .many;
            if (ordering.orderingOf(Sort) != null) {
                ordering.assertFor(Sort, Row, call, true);
                ordered = true;
                if (cut) ties = tiesFor(D, Row, layout);
                head = sql;
                sql = "";
            } else {
                const written = orderBy(D, Row, Sort, layout.outputs);
                sql = sql ++ if (cut)
                    statement.cutOrder(written, tiebreakFor(D, Row, Sort, layout))
                else
                    written;
            }
        }
        if (@hasField(O, "limit")) {
            const bound = if (answers == .feed)
                statement.past(statement.boundary(D, O, "limit", next))
            else
                statement.boundary(D, O, "limit", next);
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
            sql = sql ++ D.offset(bound.text, @hasField(O, "limit") or answers == .first);
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
            .ties = ties,
        };
        break :blk .{ .sql = sql, .paths = paths, .params = params, .reserve = reserve };
    };
}

/// `db.find` over a shaped Row: its key, which the Row reads, and `LIMIT 1`.
/// A grouped Row has none to find by, because a group is not a row of the
/// table.
pub fn find(comptime D: type, comptime Row: type, comptime K: type) Statement {
    return comptime blk: {
        @setEvalBranchQuota(row_mod.shapeBudget(Row));
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
        @setEvalBranchQuota(row_mod.shapeBudget(Row));
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
        @setEvalBranchQuota(row_mod.shapeBudget(Row));
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
        @setEvalBranchQuota(row_mod.shapeBudget(Row));
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
            // A table the condition reaches through a reference is joined
            // under `"#f.<column>"`, after the child's own parents: one row
            // or none per child, so the children stay the rows pointing back
            // (item 100).
            if (@hasField(E, "where")) {
                const reached = table_mod.literalReaching(
                    D,
                    ChildOwner,
                    layout.relation,
                    table_mod.reach_prefix,
                    what ++ " `.where`",
                    entry.where,
                );
                for (reached.hops) |h| joins = joins ++ h.text;
                joins = joins ++ " WHERE " ++ reached.sql;
            }
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
        if (info.is_tuple or info.field_names.len == 0) @compileError(
            "nilo: " ++ what ++ " `.order` names no column.\n" ++
                "  Write `.order = .{ .position = .asc }`, one field per term, or leave it out " ++
                "for the child table's key order.",
        );
        var out: []const u8 = "";
        for (info.field_names, info.field_types) |f_name, f_type| {
            if (!row_mod.hasColumn(Table, f_name)) row_mod.noSuchColumn(Table, f_name, what ++ " `.order`");
            if (f_type != Direction and f_type != @TypeOf(.enum_literal)) @compileError(
                "nilo: " ++ what ++ " `.order` gives `" ++ f_name ++ "` a " ++ @typeName(f_type) ++
                    ".\n  A direction is `.asc` or `.desc`, or one of the four that also say where NULLs go.",
            );
            dialect_mod.assertDecimalCompares(
                D,
                Table,
                f_name,
                row_mod.ColumnType(Table, f_name),
                what ++ " `.order." ++ f_name ++ "`",
            );
            const direction: Direction = statement.writtenValue(T, f_name, Direction);
            // A slice rather than the array `++` would infer, or a `NULLS`
            // clause appended below is a different length and does not fit.
            var one: []const u8 = relation ++ "." ++ D.quote(f_name) ++ (if (direction.descending()) " DESC" else " ASC");
            if (direction.placement()) |where_nulls| {
                one = one ++ (D.nulls(where_nulls) orelse dialect_mod.noNullsOrder(D, Table, f_name));
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

        // A cursor, on the table's own columns, beside whatever `.where` said.
        if (@hasField(O, "after")) {
            if (grouped) @compileError(
                "nilo: " ++ @typeName(Row) ++ " is read after a cursor, and its rows are groups, which have " ++
                    "no key to end the order in.\n" ++
                    "  Page the groups with `.offset`.",
            );
            const k = statement.afterOf(D, Row, O, layout.relation ++ ".", next, "a read");
            where = if (where.len > 0) where ++ " AND " ++ k.sql else k.sql;
            paths = paths ++ k.paths;
            params = params ++ k.params;
            next += k.paths.len;
        }

        // A join that leaves rows out is reached by every count, with the
        // hops before it that its `ON` names.
        for (layout.joins) |j| {
            if (j.narrows) reached = reached ++ &[_][]const u8{j.alias};
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
            for (layout.keys) |k| groups = groups ++ (if (groups.len == 0) "" else ", ") ++ k.expr;
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
fn orderBy(comptime D: type, comptime Row: type, comptime T: type, comptime outputs: []const Output) []const u8 {
    comptime {
        const terms = orderTerms(D, Row, T, &.{}, statement.relation(D, Row), outputs);
        return if (terms.len == 0) "" else " ORDER BY " ++ terms;
    }
}

/// The expression under the cast of the answer's column `name`, when the
/// column is read as text: what an `ORDER BY` writes so that it sorts the
/// value and not its printing. Null for every other column, which an `ORDER
/// BY` names by its answer's name as it always did.
fn bareOf(comptime outputs: []const Output, comptime name: []const u8) ?[]const u8 {
    comptime {
        for (outputs) |o| {
            if (std.mem.eql(u8, o.name, name)) return o.bare;
        }
        return null;
    }
}

/// `bareOf` for a Row the caller has not laid out: an `Ordering` key over a
/// shaped Row asks for the column it names (`ordering.zig`).
pub fn orderExpr(comptime D: type, comptime Row: type, comptime name: []const u8) ?[]const u8 {
    return comptime bareOf(layoutOf(D, Row).outputs, name);
}

/// `relation` is the Row's own table as the statement names it, for a column
/// of that table the Row does not carry (`tableHasColumn`): written through
/// the table rather than through the answer, so it is only for a Row that is
/// not grouped, where every row of the table is still a row of the answer.
fn orderTerms(
    comptime D: type,
    comptime Level: type,
    comptime T: type,
    comptime path: []const []const u8,
    comptime relation: []const u8,
    comptime outputs: []const Output,
) []const u8 {
    comptime {
        const info = switch (@typeInfo(T)) {
            .@"struct" => |s| s,
            else => @compileError(
                "nilo: `.order` has to be a struct and this one is a " ++ @typeName(T) ++ ".\n" ++
                    "  Write `.order = .{ .created_at = .desc }`, one field per term.",
            ),
        };
        var out: []const u8 = "";
        for (info.field_names, info.field_types) |f_name, f_type| {
            const at = path ++ &[_][]const u8{f_name};
            const kind: row_mod.Kind = if (row_mod.fieldTypeOf(Level, f_name) == null) .column else row_mod.kindOf(Level, f_name);
            const term = switch (kind) {
                .parent => orderTerms(D, row_mod.parentRowOf(row_mod.fieldTypeOf(Level, f_name).?).?, f_type, at, "", outputs),
                .column, .aggregate, .over_children, .through => term: {
                    const carried = row_mod.fieldTypeOf(Level, f_name) != null;
                    const through_table = !carried and path.len == 0 and
                        !@hasDecl(Level, row_mod.aggregate_marker) and
                        row_mod.tableHasColumn(Level, f_name);
                    if (!carried and path.len == 0 and @hasDecl(Level, row_mod.aggregate_marker) and
                        row_mod.tableHasColumn(Level, f_name)) @compileError(
                        "nilo: `.order` on " ++ @typeName(Level) ++ " names `" ++ f_name ++
                            "`, a column of its table that the Row does not carry, and the Row is grouped.\n" ++
                            "  A grouped Row is one row per group, and a column of the table has one value " ++
                            "per row of the table rather than per group. Order by a field the Row groups by, " ++
                            "or by one of its aggregates.",
                    );
                    if (!carried and !through_table) row_mod.noSuchColumn(Level, f_name, "`.order`");
                    if (f_type != Direction and f_type != @TypeOf(.enum_literal)) @compileError(
                        "nilo: `.order` on `" ++ row_mod.pathName(at) ++ "` was given a " ++ @typeName(f_type) ++
                            ".\n  A direction is `.asc` or `.desc`, or one of the four that also say " ++
                            "where NULLs go. A parent takes the terms for its own columns: `." ++ f_name ++
                            " = .{ .<column> = .asc }`.",
                    );
                    // A column, or a `.through` field read at the end of a path,
                    // is what the database sorts as it stores it. An aggregate
                    // and a figure over the children were checked against the
                    // column they read when they were laid out.
                    if (kind == .column or kind == .through) dialect_mod.assertDecimalCompares(
                        D,
                        Level,
                        f_name,
                        if (carried) row_mod.fieldTypeOf(Level, f_name).? else row_mod.ColumnType(row_mod.ownerOf(Level), f_name),
                        "`.order." ++ row_mod.pathName(at) ++ "`",
                    );
                    const direction: Direction = statement.writtenValue(T, f_name, Direction);
                    const named = if (through_table)
                        relation ++ "." ++ D.quote(f_name)
                    else
                        bareOf(outputs, row_mod.pathName(at)) orelse D.quote(row_mod.pathName(at));
                    // A slice, for the reason `childOrder` gives.
                    var one: []const u8 = named ++ (if (direction.descending()) " DESC" else " ASC");
                    if (direction.placement()) |where_nulls| {
                        one = one ++ (D.nulls(where_nulls) orelse
                            dialect_mod.noNullsOrder(D, Level, f_name));
                    }
                    break :term one;
                },
                .children, .beside => row_mod.noSuchColumn(Level, f_name, "`.order`"),
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

/// The order card of a product whose responses are flat (item 83).
const OrderFlat = struct {
    pub const nilo_table = Order;
    pub const nilo_through = .{
        .customer_name = .{ .customer_id, .name },
        .customer_region = .{ .customer_id, .region },
        .approver_name = .{ .approver_id, .full_name },
    };
    id: i64,
    customer_name: []const u8,
    customer_region: ?[]const u8,
    approver_name: ?[]const u8,
};

const LineFlat = struct {
    pub const nilo_table = Line;
    pub const nilo_through = .{ .customer = .{ .order_id, .customer_id, .name } };
    sku: []const u8,
    customer: []const u8,
};

const ByCustomerName = struct {
    pub const nilo_table = Order;
    pub const nilo_through = .{ .customer_name = .{ .customer_id, .name } };
    pub const nilo_aggregate = .{ .orders = .count };
    customer_name: []const u8,
    orders: i64,
};

test "a column read through a reference is a field of its own, joined once and named like a column" {
    const joins = "FROM \"orders\" JOIN \"customers\" AS \"#t/customer_id\" ON \"#t/customer_id\".\"id\" = \"orders\".\"customer_id\" " ++
        "LEFT JOIN \"staff\" AS \"#t/approver_id\" ON \"#t/approver_id\".\"id\" = \"orders\".\"approver_id\"";
    const found = comptime rows(Pg, OrderFlat, @TypeOf(.{
        .where = .{ .customer_name = @as([]const u8, "Acme") },
        .order = .{ .approver_name = .asc },
    }), .many);
    try testing.expectEqualStrings(
        "SELECT \"orders\".\"id\" AS \"id\", \"#t/customer_id\".\"name\" AS \"customer_name\", " ++
            "\"#t/customer_id\".\"region\" AS \"customer_region\", \"#t/approver_id\".\"full_name\" AS \"approver_name\" " ++
            joins ++ " WHERE \"#t/customer_id\".\"name\" = $1 ORDER BY \"approver_name\" ASC",
        found.sql,
    );
    // A count joins what leaves rows out, which is `customer_name`'s inner
    // join (its reference cannot be null, but the referenced row can be
    // missing), and otherwise only what its condition reads.
    try testing.expectEqualStrings(
        "SELECT count(*) FROM \"orders\" JOIN \"customers\" AS \"#t/customer_id\" ON " ++
            "\"#t/customer_id\".\"id\" = \"orders\".\"customer_id\" " ++
            "LEFT JOIN \"staff\" AS \"#t/approver_id\" ON " ++
            "\"#t/approver_id\".\"id\" = \"orders\".\"approver_id\" WHERE \"#t/approver_id\".\"full_name\" = $1",
        (comptime tally(Pg, OrderFlat, @TypeOf(.{ .where = .{ .approver_name = @as([]const u8, "Budi") } }), false)).sql,
    );
    // Two references away, each hop joined from the one before.
    const lines = comptime rows(Lite, LineFlat, @TypeOf(.{}), .many);
    try testing.expect(std.mem.indexOf(u8, lines.sql, "JOIN \"orders\" AS \"#t/order_id\" ON \"#t/order_id\".\"id\" = \"lines\".\"order_id\" " ++
        "JOIN \"customers\" AS \"#t/order_id.customer_id\" ON \"#t/order_id.customer_id\".\"id\" = \"#t/order_id\".\"customer_id\"") != null);
    try testing.expect(std.mem.indexOf(u8, lines.sql, "\"#t/order_id.customer_id\".\"name\" AS \"customer\"") != null);
    // And a key of a group, like a column of the table.
    const grouped = comptime rows(Pg, ByCustomerName, @TypeOf(.{}), .many);
    // and by the referenced row's key, or two customers of one name are one group.
    try testing.expect(std.mem.endsWith(u8, grouped.sql, "GROUP BY \"#t/customer_id\".\"name\", \"#t/customer_id\".\"id\""));
}

test "a grouped Row groups by the key of the row a through value came from, once, on both dialects" {
    const pg = comptime rows(Pg, ByCustomerName, @TypeOf(.{}), .many);
    try testing.expect(std.mem.endsWith(u8, pg.sql, " GROUP BY \"#t/customer_id\".\"name\", \"#t/customer_id\".\"id\""));
    const lite = comptime rows(Lite, ByCustomerName, @TypeOf(.{}), .many);
    try testing.expect(std.mem.endsWith(u8, lite.sql, " GROUP BY \"#t/customer_id\".\"name\", \"#t/customer_id\".\"id\""));
    // The key is not selected, and a page ends in it.
    try testing.expect(std.mem.indexOf(u8, pg.sql, "\"id\" AS") == null);
    const page = comptime rows(Pg, ByCustomerName, @TypeOf(.{ .order = .{ .orders = .desc } }), .many);
    try testing.expect(std.mem.indexOf(u8, page.sql, "ORDER BY \"orders\" DESC") != null);
}

/// A row the path does not reach reads a value, or is left out (item 109).
/// `approver_key` says neither and shares `approver_name`'s hop, so the
/// inner join is its too, and it is never null.
const OrderReached = struct {
    pub const nilo_table = Order;
    pub const nilo_through = .{
        .customer_region = .{ .path = .{ .customer_id, .region }, .otherwise = "none" },
        .approver_name = .{ .path = .{ .approver_id, .full_name }, .join = .inner },
        .approver_key = .{ .approver_id, .id },
    };
    id: i64,
    customer_region: []const u8,
    approver_name: []const u8,
    approver_key: i64,
};

test "a through field says what a row its path does not reach reads, or leaves the row out" {
    const region = "COALESCE(\"#t/customer_id\".\"region\", 'none')";
    const approver = " JOIN \"staff\" AS \"#t/approver_id\" ON \"#t/approver_id\".\"id\" = \"orders\".\"approver_id\"";
    const found = comptime rows(Pg, OrderReached, @TypeOf(.{
        .where = .{ .customer_region = @as([]const u8, "none") },
        .order = .{ .customer_region = .asc },
    }), .many);
    try testing.expectEqualStrings(
        "SELECT \"orders\".\"id\" AS \"id\", " ++ region ++ " AS \"customer_region\", " ++
            "\"#t/approver_id\".\"full_name\" AS \"approver_name\", \"#t/approver_id\".\"id\" AS \"approver_key\" " ++
            "FROM \"orders\" JOIN \"customers\" AS \"#t/customer_id\" ON \"#t/customer_id\".\"id\" = \"orders\".\"customer_id\"" ++
            approver ++ " WHERE " ++ region ++ " = $1 ORDER BY \"customer_region\" ASC",
        found.sql,
    );
    // A count joins what leaves rows out whatever its condition reads, so it
    // counts the rows the list answers.
    const customer = " JOIN \"customers\" AS \"#t/customer_id\" ON \"#t/customer_id\".\"id\" = \"orders\".\"customer_id\"";
    try testing.expectEqualStrings(
        "SELECT count(*) FROM \"orders\"" ++ customer ++ approver,
        (comptime tally(Pg, OrderReached, @TypeOf(.{}), false)).sql,
    );
}

const Region = struct {
    pub const nilo_table = .{ .name = "regions", .unread = .{ .code = []const u8 } };
    id: i64,
    name: []const u8,
};

const Branch = struct {
    pub const nilo_table = .{ .name = "branches", .references = .{ .region_id = .{ Region, .id } } };
    id: i64,
    region_id: i64,
};

const BranchFlat = struct {
    pub const nilo_table = Branch;
    pub const nilo_through = .{ .region_code = .{ .region_id, .code } };
    id: i64,
    region_code: []const u8,
};

const OrderCustomerName = struct {
    pub const nilo_table = Order;
    pub const nilo_through = .{ .customer_name = .{ .customer_id, .name } };
    customer_name: []const u8,
};

const LineOfOrder = struct {
    pub const nilo_table = Line;
    sku: []const u8,
    placed: OrderCustomerName,
};

test "a parent's Row reads through a reference too, and so does a Row into a column its table leaves unread" {
    const found = comptime rows(Pg, LineOfOrder, @TypeOf(.{ .where = .{ .placed = .{ .customer_name = @as([]const u8, "Acme") } } }), .many);
    try testing.expectEqualStrings(
        "SELECT \"lines\".\"sku\" AS \"sku\", \"#t.placed/customer_id\".\"name\" AS \"placed.customer_name\" " ++
            "FROM \"lines\" JOIN \"orders\" AS \"placed\" ON \"placed\".\"id\" = \"lines\".\"order_id\" " ++
            "JOIN \"customers\" AS \"#t.placed/customer_id\" ON \"#t.placed/customer_id\".\"id\" = \"placed\".\"customer_id\" " ++
            "WHERE \"#t.placed/customer_id\".\"name\" = $1",
        found.sql,
    );
    const branch = comptime rows(Pg, BranchFlat, @TypeOf(.{}), .many);
    try testing.expect(std.mem.indexOf(u8, branch.sql, "\"#t/region_id\".\"code\" AS \"region_code\"") != null);
}

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

test "a condition may name a column of the table the Row does not carry, through the table" {
    // Item 96: as an order may (item 86), and qualified the same way.
    const found = comptime rows(Pg, OrderCard, @TypeOf(.{
        .where = .{ .status = "open", .customer = .{ .name = "Acme" } },
    }), .many);
    try testing.expect(std.mem.endsWith(
        u8,
        found.sql,
        " WHERE \"orders\".\"status\" = $1 AND \"customer\".\"name\" = $2",
    ));
    try testing.expect(found.params[0].of.? == Order);
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
            "WHERE \"orders\".\"year\" = $1 GROUP BY \"customer\".\"name\", \"customer\".\"id\" " ++
            "HAVING sum(\"orders\".\"total\") > $2 " ++
            "ORDER BY \"revenue\" DESC, \"customer\".\"name\" DESC, \"customer\".\"id\" DESC LIMIT 10",
        found.sql,
    );
    // The condition on the rows binds as the table's column, the one on the
    // groups as the field's.
    try testing.expect(found.params[0].of.? == Order);
    try testing.expect(found.params[1].of.? == ByCustomer);
}

const CustomerKeyed = struct {
    pub const nilo_table = Customer;
    id: i64,
    name: []const u8,
};

const ByCustomerKeyed = struct {
    pub const nilo_table = Order;
    pub const nilo_aggregate = .{ .orders = .count };
    customer: CustomerKeyed,
    orders: i64,
};

test "a grouped Row groups by its parent's key, which it does not select, so two parents with one name stay two rows" {
    const found = comptime rows(Pg, ByCustomer, @TypeOf(.{}), .many);
    try testing.expect(std.mem.indexOf(u8, found.sql, "SELECT \"customer\".\"name\" AS \"customer.name\", count(*)") != null);
    try testing.expect(std.mem.endsWith(u8, found.sql, " GROUP BY \"customer\".\"name\", \"customer\".\"id\""));
    // A parent whose key the Row reads already is grouped by it once.
    const keyed = comptime rows(Lite, ByCustomerKeyed, @TypeOf(.{}), .many);
    try testing.expect(std.mem.endsWith(u8, keyed.sql, " GROUP BY \"customer\".\"id\", \"customer\".\"name\""));
}

test "a page over a grouped Row ends in the columns it groups by, the way its last term runs" {
    const asc = comptime rows(Pg, ByCustomer, @TypeOf(.{ .order = .{ .revenue = .asc }, .limit = 10 }), .many);
    try testing.expect(std.mem.endsWith(
        u8,
        asc.sql,
        " ORDER BY \"revenue\" ASC, \"customer\".\"name\" ASC, \"customer\".\"id\" ASC LIMIT 10",
    ));
    // What the order names is not written twice.
    const named = comptime rows(Pg, ByCustomer, @TypeOf(.{
        .order = .{ .customer = .{ .name = .desc }, .revenue = .desc },
        .limit = 10,
    }), .many);
    try testing.expect(std.mem.endsWith(
        u8,
        named.sql,
        " ORDER BY \"customer.name\" DESC, \"revenue\" DESC, \"customer\".\"id\" DESC LIMIT 10",
    ));
    // An answer nothing cuts is left as written.
    const whole = comptime rows(Pg, ByCustomer, @TypeOf(.{ .order = .{ .revenue = .asc } }), .many);
    try testing.expect(std.mem.endsWith(u8, whole.sql, " ORDER BY \"revenue\" ASC"));
    // A run-time ordering is told which terms a group is told apart by.
    const chosen = comptime rows(Pg, ByCustomer, @TypeOf(.{
        .order = ordering.Ordering(ByCustomer, .{ .revenue = .revenue }).by(&.{.{ .key = .revenue }}),
        .limit = 10,
    }), .many);
    try testing.expectEqual(@as(usize, 2), chosen.ties.len);
    try testing.expectEqualStrings("customer.name", chosen.ties[0].column);
    try testing.expectEqualStrings("\"customer\".\"id\" ASC", chosen.ties[1].text);
}

const Invoice = struct {
    pub const nilo_table = .{ .name = "invoices", .references = .{ .customer_id = .{ Customer, .id } } };
    id: i64,
    customer_id: i64,
    amount: types_mod.Decimal,
};

const InvoiceCard = struct {
    pub const nilo_table = Invoice;
    id: i64,
    amount: types_mod.Decimal,
    customer: CustomerName,
};

const BilledByCustomer = struct {
    pub const nilo_table = Invoice;
    pub const nilo_aggregate = .{ .billed = .{ .sum = .amount } };
    customer: CustomerName,
    billed: types_mod.Decimal,
};

test "an order over a column read as text names the value under the cast, or Postgres sorts the printing" {
    // `"amount"::text AS "amount"` is an answer called `amount`, and a bare
    // `ORDER BY "amount"` is read against the answers first: 9.00, 100.5, 10.00.
    const found = comptime rows(Pg, InvoiceCard, @TypeOf(.{ .order = .{ .amount = .desc }, .limit = 5 }), .many);
    try testing.expect(std.mem.indexOf(u8, found.sql, "\"invoices\".\"amount\"::text AS \"amount\"") != null);
    try testing.expect(std.mem.endsWith(u8, found.sql, " ORDER BY \"invoices\".\"amount\" DESC, \"invoices\".\"id\" DESC LIMIT 5"));
    // A column that is not read as text is still named by its answer.
    const plain = comptime rows(Pg, InvoiceCard, @TypeOf(.{ .order = .{ .id = .desc } }), .many);
    try testing.expect(std.mem.endsWith(u8, plain.sql, " ORDER BY \"id\" DESC"));
    // A sum over one repeats the aggregate, not its answer's name.
    const billed = comptime rows(Pg, BilledByCustomer, @TypeOf(.{ .order = .{ .billed = .desc } }), .many);
    try testing.expect(std.mem.indexOf(u8, billed.sql, "sum(\"invoices\".\"amount\")::text AS \"billed\"") != null);
    try testing.expect(std.mem.endsWith(u8, billed.sql, " ORDER BY sum(\"invoices\".\"amount\") DESC"));
    // And so does an ordering chosen at run time.
    const Sort = ordering.Ordering(BilledByCustomer, .{ .billed = .billed });
    var buf: [Sort.most(Pg)]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try Sort.by(&.{.{ .key = .billed, .direction = .desc }}).write(Pg, &w);
    try testing.expectEqualStrings(" ORDER BY sum(\"invoices\".\"amount\") DESC", w.buffered());
}

test "an inner join through a reference that cannot be null says it narrows, so a count keeps it" {
    const joined = comptime rows(Pg, OrderFlat, @TypeOf(.{}), .many);
    const count = comptime tally(Pg, OrderFlat, @TypeOf(.{}), false);
    try testing.expect(std.mem.indexOf(u8, joined.sql, " JOIN \"customers\" AS \"#t/customer_id\"") != null);
    try testing.expect(std.mem.indexOf(u8, count.sql, " JOIN \"customers\" AS \"#t/customer_id\"") != null);
    // The join of a reference that may be null is outer, and a count leaves it out.
    try testing.expect(std.mem.indexOf(u8, count.sql, "#t/approver_id") == null);
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
            "GROUP BY \"customer\".\"name\", \"customer\".\"id\" " ++
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

const LineTally = struct {
    pub const nilo_table = Line;
    pub const nilo_aggregate = .{
        .west = .{ .sum = .qty, .where = .{ .order_id = .{ .customer_id = .{ .region = "west" } } } },
        .approved = .{ .count = .id, .where = .{ .order_id = .{ .approver_id = .{ .ne = null }, .status = "paid" } } },
        .unapproved = .{ .count = .id, .where = .{ .order_id = .{ .approver_id = .{ .full_name = "Budi" } } } },
    };
    west: ?i64,
    approved: i64,
    unapproved: i64,
};

test "an aggregate's .where reaches through a reference, and the table is joined once" {
    // The port's case: a count by the category of a work item's state, which
    // no field of the Row holds.
    const found = comptime exactlyOne(Pg, LineTally, @TypeOf(.{}));
    try testing.expectEqualStrings(
        "SELECT sum(\"lines\".\"qty\") FILTER (WHERE \"#f.order_id.customer_id\".\"region\" = 'west')::int8 AS \"west\", " ++
            "count(\"lines\".\"id\") FILTER (WHERE \"#f.order_id\".\"approver_id\" IS NOT NULL AND \"#f.order_id\".\"status\" = 'paid') AS \"approved\", " ++
            "count(\"lines\".\"id\") FILTER (WHERE \"#f.order_id.approver_id\".\"full_name\" = 'Budi') AS \"unapproved\" " ++
            "FROM \"lines\" JOIN \"orders\" AS \"#f.order_id\" ON \"#f.order_id\".\"id\" = \"lines\".\"order_id\" " ++
            "JOIN \"customers\" AS \"#f.order_id.customer_id\" ON \"#f.order_id.customer_id\".\"id\" = \"#f.order_id\".\"customer_id\" " ++
            // `approver_id` may be null, so its table is an outer join and
            // an order with no approver still counts for the other two.
            "LEFT JOIN \"staff\" AS \"#f.order_id.approver_id\" ON \"#f.order_id.approver_id\".\"id\" = \"#f.order_id\".\"approver_id\"",
        found.sql,
    );
}

const Category = enum { open, done, cancelled };

const WorkState = struct {
    pub const nilo_table = .{ .name = "work_states", .key = .id };
    id: i64,
    category: Category,
};

const WorkItem = struct {
    pub const nilo_table = .{
        .name = "work_items",
        .key = .id,
        .references = .{ .state_id = .{ WorkState, .id } },
    };
    id: i64,
    state_id: i64,
};

/// Declared once and named twice, which is what a program that already has
/// the set somewhere writes (item 104).
const finished = [_]Category{ .done, .cancelled };

const WorkTally = struct {
    pub const nilo_table = WorkItem;
    pub const nilo_aggregate = .{
        .open = .{ .count = .id, .where = .{ .state_id = .{ .category = .{ .not_in = &finished } } } },
        .closed = .{ .count = .id, .where = .{ .state_id = .{ .category = .{ .in = .{ .done, .cancelled } } } } },
        .done = .{ .count = .id, .where = .{ .state_id = .{ .category = Category.done } } },
    };
    open: i64,
    closed: i64,
    done: i64,
};

test "an aggregate's .where takes the column's own enum values where it takes its words" {
    // The port wrote `.not_in = &finished` and was told not to write a
    // string, which it had not. A value of the column's enum is the word.
    const found = comptime exactlyOne(Pg, WorkTally, @TypeOf(.{}));
    try testing.expect(std.mem.indexOf(u8, found.sql, "\"#f.state_id\".\"category\" NOT IN ('done', 'cancelled')") != null);
    try testing.expect(std.mem.indexOf(u8, found.sql, "\"#f.state_id\".\"category\" IN ('done', 'cancelled')") != null);
    try testing.expect(std.mem.indexOf(u8, found.sql, "\"#f.state_id\".\"category\" = 'done'") != null);
}

const WorkEpic = struct {
    pub const nilo_table = .{ .name = "work_epics", .key = .id };
    id: i64,
    title: []const u8,
};

const EpicItem = struct {
    pub const nilo_table = .{
        .name = "epic_items",
        .key = .id,
        .references = .{ .epic_id = .{ WorkEpic, .id }, .state_id = .{ WorkState, .id } },
    };
    id: i64,
    epic_id: i64,
    state_id: i64,
    target_date: ?types_mod.Date,
};

const EpicItemBrief = struct {
    pub const nilo_table = EpicItem;
    id: i64,
};

/// The Epic list of item 100: how many, how many unfinished, and the latest
/// target among the unfinished, where "finished" is the state's category.
const EpicCard = struct {
    pub const nilo_table = WorkEpic;
    pub const nilo_children = .{
        .items = .{ .count = EpicItem },
        .open_items = .{ .count = EpicItem, .where = .{ .state_id = .{ .category = .{ .not_in = &finished } } } },
        .latest_target = .{ .max = .{ EpicItem, .target_date }, .where = .{ .state_id = .{ .category = .{ .not_in = &finished } } } },
        .first_target = .{ .min = .{ EpicItem, .target_date } },
        .open = .{ .where = .{ .state_id = .{ .category = .open } } },
    };
    id: i64,
    items: i64,
    open_items: i64,
    latest_target: ?types_mod.Date,
    first_target: ?types_mod.Date,
    open: []const EpicItemBrief,
};

test "a figure over the children reaches through a reference, and may be a max or a min" {
    const unfinished = "JOIN \"work_states\" AS \"#c.state_id\" ON \"#c.state_id\".\"id\" = \"#c\".\"state_id\" " ++
        "WHERE \"#c\".\"epic_id\" = \"work_epics\".\"id\" AND \"#c.state_id\".\"category\" NOT IN ('done', 'cancelled'))";
    const found = comptime rows(Pg, EpicCard, @TypeOf(.{
        .where = .{ .open_items = .{ .gt = @as(i64, 0) } },
        .order = .{ .latest_target = .desc },
    }), .many);
    try testing.expect(std.mem.indexOf(u8, found.sql, "(SELECT count(*) FROM \"epic_items\" AS \"#c\" " ++
        "WHERE \"#c\".\"epic_id\" = \"work_epics\".\"id\") AS \"items\"") != null);
    try testing.expect(std.mem.indexOf(u8, found.sql, "(SELECT count(*) FROM \"epic_items\" AS \"#c\" " ++ unfinished ++
        " AS \"open_items\"") != null);
    try testing.expect(std.mem.indexOf(u8, found.sql, "(SELECT max(\"#c\".\"target_date\") FROM \"epic_items\" AS \"#c\" " ++
        unfinished) != null);
    try testing.expect(std.mem.indexOf(u8, found.sql, "(SELECT min(\"#c\".\"target_date\") FROM \"epic_items\" AS \"#c\" " ++
        "WHERE \"#c\".\"epic_id\" = \"work_epics\".\"id\")") != null);
    // The condition is the same subquery, bound like a column.
    try testing.expect(std.mem.indexOf(u8, found.sql, "WHERE (SELECT count(*) FROM \"epic_items\" AS \"#c\" " ++
        unfinished ++ " > $1") != null);

    // A children list's `.where` goes the same way, joined under the
    // statement's own prefix after the child's parents.
    const listed = comptime children(Pg, EpicCard, "open");
    try testing.expect(std.mem.indexOf(u8, listed.sql, "JOIN \"work_states\" AS \"#f.state_id\" ON " ++
        "\"#f.state_id\".\"id\" = \"epic_items\".\"state_id\" WHERE \"#f.state_id\".\"category\" = 'open' ORDER BY") != null);
    const lite = comptime children(Lite, EpicCard, "open");
    try testing.expect(std.mem.indexOf(u8, lite.sql, "WHERE \"#f.state_id\".\"category\" = 'open'") != null);
}

const Deal = struct {
    pub const nilo_table = .{ .name = "deals", .key = .id };
    id: i64,
    closed_at: ?types_mod.Date,
    touched_at: types_mod.Timestamp,
};

const DealPulse = struct {
    pub const nilo_table = Deal;
    pub const nilo_aggregate = .{
        .recent = .{ .count = .id, .where = .{ .closed_at = .{ .gte = .{ .today = -90 } } } },
        .closed_today = .{ .count = .id, .where = .{ .closed_at = .today } },
        .touched = .{ .count = .id, .where = .{ .touched_at = .{ .gt = .{ .now = .{ .hours = -24 } } } } },
    };
    recent: i64,
    closed_today: i64,
    touched: i64,
};

test "an aggregate's .where compares with the database's clock, moved or not" {
    // Item 105: the Deal snapshot's "closed in the last 90 days" is a day in
    // the database's zone, so it cannot be a value the program worked out.
    const pg = comptime exactlyOne(Pg, DealPulse, @TypeOf(.{}));
    try testing.expect(std.mem.indexOf(u8, pg.sql, "\"deals\".\"closed_at\" >= (CURRENT_DATE - 90)") != null);
    try testing.expect(std.mem.indexOf(u8, pg.sql, "\"deals\".\"closed_at\" = CURRENT_DATE") != null);
    try testing.expect(std.mem.indexOf(u8, pg.sql, "\"deals\".\"touched_at\" > (now() - interval '24 hours')") != null);
    const lite = comptime exactlyOne(Lite, DealPulse, @TypeOf(.{}));
    try testing.expect(std.mem.indexOf(u8, lite.sql, "\"deals\".\"closed_at\" >= date('now', '-90 days')") != null);
    try testing.expect(std.mem.indexOf(u8, lite.sql, "julianday('now', '-24 hours')") != null);
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
            "GROUP BY \"customer\".\"name\", \"customer\".\"id\") AS \"#groups\"",
        found.sql,
    );
}

test "a count of a Row with parents joins the required ones and those its condition names" {
    // `customer` and `owner` are inner joins, which leave out an order whose
    // row there is missing, so the count joins them to agree with the list.
    // `approver` may be missing and drops nothing, so it is joined only when
    // a condition reaches it.
    const none = comptime tally(Pg, OrderCard, @TypeOf(.{ .where = .{ .total = @as(i64, 1) } }), false);
    try testing.expectEqualStrings(
        "SELECT count(*) FROM \"orders\" JOIN \"customers\" AS \"customer\" ON \"customer\".\"id\" = " ++
            "\"orders\".\"customer_id\" JOIN \"staff\" AS \"owner\" ON \"owner\".\"id\" = " ++
            "\"orders\".\"owner_id\" WHERE \"orders\".\"total\" = $1",
        none.sql,
    );
    const approved = comptime tally(Pg, OrderCard, @TypeOf(.{ .where = .{ .approver = .{ .full_name = @as([]const u8, "x") } } }), false);
    try testing.expect(std.mem.indexOf(u8, approved.sql, "LEFT JOIN \"staff\" AS \"approver\"") != null);
    const one = comptime tally(Pg, OrderCard, @TypeOf(.{ .where = .{ .owner = .{ .full_name = @as([]const u8, "x") } } }), true);
    try testing.expectEqualStrings(
        "SELECT EXISTS(SELECT 1 FROM \"orders\" JOIN \"customers\" AS \"customer\" ON \"customer\".\"id\" = " ++
            "\"orders\".\"customer_id\" JOIN \"staff\" AS \"owner\" ON \"owner\".\"id\" = " ++
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
            "ORDER BY \"big_lines\" DESC, \"orders\".\"id\" DESC LIMIT 20",
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

test "an order on a shaped Row says where the nulls go, through a parent and on a filtered sum" {
    // A filtered sum is always optional, and `.desc` alone puts the groups
    // with none first on Postgres: a leaderboard needs `NULLS LAST`.
    const grouped = comptime rows(Pg, ByCustomerOpen, @TypeOf(.{
        .order = .{ .paid = .desc_nulls_last, .customer = .{ .name = .asc_nulls_first } },
    }), .many);
    try testing.expect(std.mem.endsWith(
        u8,
        grouped.sql,
        " ORDER BY \"paid\" DESC NULLS LAST, \"customer.name\" ASC NULLS FIRST",
    ));
    const lite = comptime rows(Lite, ByCustomerOpen, @TypeOf(.{ .order = .{ .paid = .desc_nulls_last } }), .many);
    try testing.expect(std.mem.endsWith(u8, lite.sql, " ORDER BY \"paid\" DESC NULLS LAST"));
    // Through the table, on a Row that is not grouped.
    const flat = comptime rows(Pg, OrderCard, @TypeOf(.{ .order = .{ .year = .desc_nulls_first } }), .many);
    try testing.expect(std.mem.endsWith(u8, flat.sql, " ORDER BY \"orders\".\"year\" DESC NULLS FIRST"));
}

const OrderWithLinesNullsLast = struct {
    pub const nilo_table = Order;
    pub const nilo_children = .{ .lines = .{ .order = .{ .qty = .desc_nulls_last } } };
    id: i64,
    lines: []const LineBrief,
};

test "a children field's order says where the nulls go" {
    const pg = comptime children(Pg, OrderWithLinesNullsLast, "lines");
    try testing.expect(std.mem.endsWith(
        u8,
        pg.sql,
        "ORDER BY \"#k\".\"key\", \"lines\".\"qty\" DESC NULLS LAST, \"lines\".\"id\"",
    ));
}

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
