//! The where walker — a struct of the caller's own turned into a SQL
//! fragment while compiling, and into a list of values at runtime (ADR 036).
//!
//! ```zig
//! .where = .{ .age = .{ .gt = 18 }, .name = "bob" }
//! ```
//! ```sql
//! "age" > $1 AND "name" = $2
//! ```
//!
//! This is ADR 036's rule at its narrowest: **which column, which operator
//! and how many parameters are settled here, while compiling. Only the 18 and
//! the "bob" are not.** A column that does not exist is a Refusal naming the
//! near miss; it never becomes a runtime error, because by the time the
//! program runs the question has already been answered.
//!
//! It is the same trick `Query(T)` plays one layer up — ADR 011's *the query
//! string is a struct of your own* — applied to the other end of the request.
//!
//! Three shapes, and no more:
//!
//! - **Different fields are ANDed.** That is what a struct is.
//! - **Several operators on one field are ANDed too**, so
//!   `.age = .{ .gt = 18, .lt = 65 }` needs no `between` and no second idea.
//! - **`.any` is OR**, holding a tuple of conditions. Not `.or`, which is a
//!   Zig keyword and would have to be written `.@"or"`. The cost is that
//!   `any` becomes a reserved column name, refused by name rather than
//!   silently misread.
//!
//! And one condition over several columns — `.across = .{ .columns = .{ .code,
//! .name }, .icontains = q }` — which is the three shapes again with one
//! parameter named on every column (ADR 172).
//!
//! A shaped Row adds two more: a parent's name is a way into its columns,
//! and a grouped Row's condition splits into a `WHERE` and a `HAVING` by what
//! each name is (`planScoped`, ADR 218). Everything past that, a join no
//! reference names, `DISTINCT`, a subquery that is not an `.exists`, is
//! `db.raw`.
//!
//! **A null is written, never held.** `.deleted_at = null` is `IS NULL` and
//! `.{ .ne = null }` is `IS NOT NULL`, because the compiler can see the null.
//! An optional that *might* be null is a Refusal — see `assertNotOptional`,
//! which is ADR 036's rule at its sharpest.
//!
//! **Except once, and the exception proves the rule rather than bending it.**
//! `.{ .not_distinct_from = maybe }` takes an optional, because
//! `IS NOT DISTINCT FROM` is `=` with null treated as an ordinary value: the
//! statement reads the same whether the value turns out to be null or not, so
//! nothing about its shape is left until run time. Every other operator would
//! have had to *become* a different statement, and that is what is refused.
//!
//! **The SQL and the values are generated from one walk, not two.** `plan`
//! produces the fragment and the list of paths to the values together, and
//! `each` reads the values back along those same paths. Two walks that had to
//! agree about ordering would be two walks that could stop agreeing.

const std = @import("std");
const core = @import("nilo_core");
const row_mod = @import("row.zig");
const table_mod = @import("table.zig");
const dialect_mod = @import("dialect.zig");
const types = @import("types.zig");

/// The field name that means OR. A Row with a column of this name is refused,
/// because one word cannot mean both.
pub const any_field = "any";

/// The two field names that mean *a row over there matches*, and their
/// negation. Reserved the same way `any` is, and for the same reason.
pub const exists_field = "exists";
pub const not_exists_field = "not_exists";

/// The field name that means *one condition, whichever of these columns meets
/// it* — a search box over the code, the name and the trademark
/// ([ADR 172](../docs/adr/172-one-condition-over-several-columns-is-one-parameter.md)).
/// Reserved the same way `any` is.
pub const across_field = "across";

/// The one name an `.across` entry carries beside its operators.
const across_columns = "columns";

/// Every word a condition reserves. One list, because `assertNoReservedColumn`
/// and the message it writes both read it and a word allowed in one and
/// refused in the other is the mistake this arrangement exists to prevent.
const reserved = [_][]const u8{ any_field, exists_field, not_exists_field, across_field };

/// The names an `.exists` entry may carry.
const exists_known = [_][]const u8{ "in", "on", "via", "where" };

/// A value a condition only has *sometimes* — the term is in the statement
/// when there is one, and out of it when there is not
/// ([ADR 149](../docs/adr/149-a-filter-that-is-absent-is-not-a-filter-that-is-null.md)).
///
/// ```zig
/// .where = .{
///     .name = .{ .icontains = sql.given(filter.search) },
///     .status = sql.given(filter.status),
/// }
/// ```
///
/// **Absent and null are two different questions**, which is why this is a
/// word rather than an optional the operators started taking. `.status = null`
/// is `IS NULL` and means *the rows whose status is nothing*; this means *no
/// condition on status at all*. Nobody with a search box wants the first, and
/// ADR 040 is why the second could not be spelled: an optional reaching `=`
/// sends `= NULL`, which runs, matches nothing, and says nothing.
///
/// What it compiles to is the guard a hand-written statement uses, with the
/// term first so that Postgres has typed the parameter before the null test
/// reads it (`guarded` says why):
///
/// ```sql
/// ("name" ILIKE '%' || $1 || '%' OR $1 IS NULL)
/// ```
///
/// One statement rather than one per combination of filters, so the plan cache
/// holds one entry and the parameter list is the same however the screen is
/// set. The ADR has the numbers and the alternative it rejected.
pub fn Given(comptime T: type) type {
    return struct {
        /// Read by name, the way every other marker in this repository is.
        /// The type it holds, so a walker that found one knows what the term
        /// is being written for without unwrapping the field.
        pub const nilo_given = T;

        /// What a nilo compile error calls this type (ADR 074).
        pub const nilo_type_name = "nilo.sql.Given";

        value: ?T,
    };
}

/// Wrap an optional so a condition drops its term when there is no value.
///
/// The argument has to be an optional: a value that is always there is an
/// ordinary condition, and writing this around one would compile to a guard
/// that is never taken.
pub fn given(value: anytype) Given(GivenValue(@TypeOf(value))) {
    return .{ .value = value };
}

/// The type inside the optional `given` was handed.
fn GivenValue(comptime T: type) type {
    comptime {
        return switch (@typeInfo(T)) {
            .optional => |o| o.child,
            .null => @compileError(
                "nilo: `sql.given(null)` is a term that is never there.\n" ++
                    "  It takes the optional itself — `sql.given(filter.status)` — and " ++
                    "leaves the term out when there is no value. A column compared against " ++
                    "nothing is `.status = null`, which is `IS NULL`.",
            ),
            else => @compileError(
                "nilo: `sql.given` was handed a " ++ @typeName(T) ++ ", which is not an " ++
                    "optional.\n" ++
                    "  A value that is always there is an ordinary condition: write " ++
                    "`.status = value`. `sql.given` is for the one a filter may not carry.",
            ),
        };
    }
}

/// Whether `T` is a `Given`, and what it holds.
pub fn givenValue(comptime T: type) ?type {
    comptime {
        return switch (@typeInfo(T)) {
            .@"struct" => if (@hasDecl(T, "nilo_given")) T.nilo_given else null,
            else => null,
        };
    }
}

/// A route from the root of the where struct to one value, as the field names
/// to follow. Comptime, so `each` can unroll it into `@field` calls.
pub const Path = []const []const u8;

/// What one placeholder is for.
///
/// The path says *where the value was written*; this says *what it has to
/// become on the way to the database*, which is a different question. A
/// literal is written without a type and a column has one; and `.in` is
/// written as a list where every other operator takes a single value.
pub const Param = struct {
    /// The column being compared or assigned, or `none` for a parameter
    /// that belongs to no column — a `LIMIT` is a count, not a value out of
    /// a row.
    column: []const u8 = none,
    /// The Row `column` belongs to, when it is **not** the statement's own.
    ///
    /// Null for every parameter a statement over one table writes, which is
    /// almost all of them. An `.exists` is what makes it necessary: the
    /// condition inside one compares a column of the *other* table, so
    /// looking its type up in the statement's Row would answer with a column
    /// that happens to share a name, or refuse a column that is really there.
    of: ?type = null,
    /// Whether the value is a list of that column's type rather than one of
    /// them. `.in` compiles to `= ANY($1)`: one placeholder holding many
    /// values, which is what keeps the statement a constant however long
    /// the list is.
    list: bool = false,
    /// Whether the value binds as an optional even though the column is not
    /// one. Set by `distinct_from`, and by `sql.given`: both are spellings
    /// whose SQL does not change when the value turns out to be null, which
    /// is the property that lets an optional reach a placeholder at all
    /// (`nullSafeSpelling`, ADR 149).
    nullable: bool = false,
    /// Whether the term this parameter belongs to disappears when the value
    /// is null — `sql.given`
    /// ([ADR 149](../docs/adr/149-a-filter-that-is-absent-is-not-a-filter-that-is-null.md)).
    ///
    /// Read by `statement.zig`, which refuses one in the condition of an
    /// `UPDATE` or a `DELETE`: what stands between those and the whole table
    /// is not something to leave to a value that may not arrive.
    droppable: bool = false,

    /// The `column` of a parameter that is not a column.
    pub const none = "";

    /// Whether this parameter counts rows rather than carrying a column's
    /// value — a `LIMIT` or an `OFFSET`, and nothing else. Named for what it
    /// is rather than for what it is not: `db.zig` reads this to decide what
    /// type the parameter binds as, and a name that answered the opposite
    /// question read as the negation of the branch it guards.
    pub fn isCount(self: Param) bool {
        return self.column.len == 0;
    }
};

/// The type a parameter's column is read into: the statement's own Row, unless
/// the parameter came from inside an `.exists` and named another one.
///
/// One function so that the five places in `db.zig` that used to write
/// `ColumnType(Row, param.column)` cannot disagree about which Row that is.
pub fn ParamType(comptime Row: type, comptime param: Param) type {
    return comptime row_mod.ColumnType(param.of orelse Row, param.column);
}

/// What a where struct compiles to.
pub const Plan = struct {
    /// The fragment, with no `WHERE` in front — the caller decides whether
    /// there is one, because an empty condition means there is not.
    sql: []const u8,
    /// Where each parameter's value lives, in the order the placeholders were
    /// numbered.
    paths: []const Path,
    /// What each parameter is for, in that same order — see `Param`.
    params: []const Param,
    /// The parents the condition named, by the path a statement over a shaped
    /// Row joins each one under (ADR 218). A count joins these and no others,
    /// because a join nothing reads is work the answer does not need.
    reached: []const []const u8 = &.{},

    pub fn isEmpty(self: Plan) bool {
        return self.sql.len == 0;
    }
};

/// Compile `W` — the type of a where struct literal — against `Row`, in `D`'s
/// grammar. `first` is the number the next placeholder takes, so a caller
/// that has already written parameters (an `UPDATE … SET`) can carry on
/// counting rather than restarting.
pub fn plan(
    comptime D: type,
    comptime Row: type,
    comptime W: type,
    comptime first: usize,
) Plan {
    return comptime planAt(D, Row, W, first, &.{});
}

/// The same, for a caller whose where struct sits inside a larger one — a
/// statement's options, where the paths have to be rooted at the options
/// rather than at the condition, or a Wire would not know where to read from.
pub fn planAt(
    comptime D: type,
    comptime Row: type,
    comptime W: type,
    comptime first: usize,
    comptime prefix: Path,
) Plan {
    return comptime blk: {
        dialect_mod.assertDialect(D);
        assertNoReservedColumn(Row);
        var state = State{ .next = first };
        const sql = walk(D, Row, W, prefix, &state);
        const frozen = state.paths[0..state.count].*;
        const frozen_params = state.params[0..state.count].*;
        break :blk .{ .sql = sql, .paths = &frozen, .params = &frozen_params };
    };
}

/// Which half of a grouped Row's condition a walk writes (ADR 218).
///
/// A grouped Row's `.where` is one struct and two clauses: a term on a column
/// of the table narrows the rows before they are grouped, and a term on an
/// aggregate narrows the groups. The caller writes neither `WHERE` nor
/// `HAVING`; the name says which, because the Row says what each name is.
pub const Phase = enum {
    /// Every term, for a Row that is not grouped.
    all,
    /// The terms on the table's rows: every name but an aggregate.
    rows,
    /// The terms on the groups: the aggregates, and nothing else.
    groups,
};

/// Where a walk over a shaped Row starts
/// ([ADR 218](../docs/adr/218-a-row-may-carry-its-parent-its-children-or-a-sum.md)).
pub const Scope = struct {
    /// The Row whose parents and aggregates a name in the condition may be.
    shape: type,
    /// The Row a plain column's name and type are looked up in: the shaped
    /// Row itself, or for a grouped one the table it groups, since a
    /// condition on the rows may name a column no group reports.
    columns: type,
    /// The relation the statement reads, as it is written after `FROM`.
    relation: []const u8,
    phase: Phase = .all,
};

/// `planAt` over a shaped Row: the same walk, with every column qualified by
/// the relation it belongs to, a parent's name read as a way into its
/// columns, and a grouped Row's condition split by `phase`.
pub fn planScoped(
    comptime D: type,
    comptime W: type,
    comptime first: usize,
    comptime prefix: Path,
    comptime scope: Scope,
) Plan {
    return comptime blk: {
        dialect_mod.assertDialect(D);
        assertNoReservedColumn(scope.columns);
        var state = State{
            .next = first,
            .shape = scope.shape,
            .qualifier = scope.relation ++ ".",
            .outer = scope.relation,
            .phase = scope.phase,
            // A grouped Row's rows are the table's, so a parameter's type is
            // the table's column's; everywhere else it is the Row's own.
            .inner = if (scope.columns == scope.shape) null else scope.columns,
        };
        const sql = walk(D, scope.columns, W, prefix, &state);
        const frozen = state.paths[0..state.count].*;
        const frozen_params = state.params[0..state.count].*;
        const frozen_reached = state.reached[0..state.reached_count].*;
        break :blk .{
            .sql = sql,
            .paths = &frozen,
            .params = &frozen_params,
            .reached = &frozen_reached,
        };
    };
}

/// An aggregate as a condition or a column spells it: the call, over the
/// column qualified by the relation the statement reads. The same text in
/// the `SELECT` list and the `HAVING`, which is what lets a condition on
/// `.owed` mean the number the row reports.
///
/// An entry with a `.where` takes it as `FILTER (WHERE …)`, with the values
/// written in (`table.literalCondition`): the condition is part of `Shape`'s
/// declaration, so it is the same for every statement and there is nothing
/// to bind. Both databases take the clause, SQLite since 3.30.
pub fn aggregateCall(
    comptime D: type,
    comptime Shape: type,
    comptime relation: []const u8,
    comptime aggregate: row_mod.Aggregate,
) []const u8 {
    return comptime blk: {
        const call = aggregate.kind.call(if (aggregate.column) |c| relation ++ "." ++ D.quote(c) else null);
        if (!aggregate.filtered) break :blk call;
        break :blk call ++ " FILTER (WHERE " ++ aggregateFilter(D, Shape, relation, aggregate).sql ++ ")";
    };
}

/// An aggregate's `.where`, and the tables it reaches through a reference
/// (`table.literalReaching`), which the statement joins once each.
fn aggregateFilter(
    comptime D: type,
    comptime Shape: type,
    comptime relation: []const u8,
    comptime aggregate: row_mod.Aggregate,
) table_mod.Reached {
    return comptime blk: {
        const where = @field(@field(Shape, row_mod.aggregate_marker), aggregate.field).where;
        const what = @typeName(Shape) ++ "'s `." ++ aggregate.field ++ "` `.where`";
        break :blk table_mod.literalReaching(D, row_mod.ownerOf(Shape), relation, what, where);
    };
}

/// Every table the aggregates' `.where`s reach, once each and in the order
/// they were first reached: the joins a grouped statement adds so the
/// `FILTER`s can read them (ADR 218).
pub fn aggregateHops(comptime D: type, comptime Shape: type, comptime relation: []const u8) []const table_mod.Hop {
    return comptime blk: {
        var out: []const table_mod.Hop = &.{};
        for (row_mod.aggregatesOf(Shape)) |aggregate| {
            if (!aggregate.filtered) continue;
            for (aggregateFilter(D, Shape, relation, aggregate).hops) |hop| {
                const seen = for (out) |h| {
                    if (std.mem.eql(u8, h.alias, hop.alias)) break true;
                } else false;
                if (!seen) out = out ++ &[_]table_mod.Hop{hop};
            }
        }
        break :blk out;
    };
}

/// How many parameters the fragment carries. The same number as
/// `plan(...).paths.len`, named separately because a caller sizing a buffer
/// wants to say what it is asking.
pub fn paramCount(
    comptime D: type,
    comptime Row: type,
    comptime W: type,
) usize {
    return comptime plan(D, Row, W, 1).paths.len;
}

/// Hand every value to `f`, in placeholder order. This is how a Wire binds:
/// the paths came out of the same walk that numbered the placeholders, so the
/// nth call is the value for `$n`.
pub fn each(
    comptime p: Plan,
    where: anytype,
    context: anytype,
    comptime f: anytype,
) !void {
    inline for (p.paths) |path| {
        try f(context, valueAt(where, path));
    }
}

/// The value at the end of a path. Unrolled at comptime, so this is a field
/// access chain and not a lookup.
pub fn valueAt(where: anytype, comptime path: Path) ValueAt(@TypeOf(where), path) {
    if (path.len == 0) return where;
    return valueAt(@field(where, path[0]), path[1..]);
}

/// The same value, coerced to `T` on the way out.
///
/// Necessary rather than convenient, and the reason is one Zig rule:
/// **a function whose return type is comptime-only is evaluated at comptime,
/// whole.** `ValueAt` of `.{ .set = .{ .age = 31 } }` is `comptime_int`, so
/// `valueAt` on that path is a comptime call — and a comptime call cannot read
/// the rest of an options struct that also carries a runtime value. The line
/// that hit it is the most ordinary one on the page:
///
/// ```zig
/// _ = try db.update(User, c, .{ .set = .{ .age = 31 }, .where = .{ .id = made.id } });
/// ```
///
/// which stopped with `unable to resolve comptime value` naming `options`,
/// three functions in and about a parameter the caller never wrote. Naming
/// the wanted type makes this an ordinary function whose *leaf* coerces, and
/// the coercion was going to happen one line later anyway (`db.valuesOf`).
///
/// `valueAt` above is kept for the callers that have a concrete value and
/// want its own type — the tests, and `each`.
pub fn valueAtAs(comptime T: type, where: anytype, comptime path: Path) T {
    if (path.len == 0) return where;
    return valueAtAs(T, @field(where, path[0]), path[1..]);
}

/// Whether a value of this type can only exist at comptime — a literal
/// number, a `null`, an enum name. These are the ones a caller writes and
/// the column gives a type to; everything else already has one.
pub fn comptimeOnly(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .comptime_int, .comptime_float, .null, .undefined, .enum_literal, .type => true,
        else => false,
    };
}

/// Whether a condition, with the values it was handed at run time, narrows
/// nothing: every row of the table passes it.
///
/// **An `UPDATE` or a `DELETE` whose condition narrows nothing is the one with
/// no condition, reached by a value rather than by leaving the condition
/// out.** The compiler refuses the second (`update_without_condition`); this
/// is how `statement.zig`'s callers refuse the first, because
/// `.id = .{ .not_in = keep }` with `keep` empty is `"id" <> ALL('{}')`, true
/// of every row, and a delete written to keep a list of rows empties the table
/// the day the list arrives empty. A pattern built from empty text is the
/// other way there: `.contains = ""` is `LIKE '%%'`, and matches every row
/// that has the column at all.
///
/// Read structurally, the way the walk writes the SQL: the terms of a
/// struct are ANDed, so it narrows nothing only when none of them does; the
/// alternatives of `.any` are ORed, so one that narrows nothing is enough.
/// Everything that is not a list or a pattern answers *narrows*, including a
/// parent's conditions and an `.exists`, which is the direction to be wrong
/// in. Unrolled while compiling, so a condition with no list and no pattern
/// in it compiles to `return false`.
pub fn filtersNothing(where: anytype) bool {
    const W = @TypeOf(where);
    const info = switch (@typeInfo(W)) {
        .@"struct" => |s| s,
        else => return false,
    };
    if (info.fields.len == 0) return true;
    inline for (info.fields) |f| {
        if (!termFiltersNothing(f.name, @field(where, f.name))) return false;
    }
    return true;
}

fn termFiltersNothing(comptime name: []const u8, value: anytype) bool {
    const T = @TypeOf(value);
    if (comptime std.mem.eql(u8, name, any_field)) {
        inline for (@typeInfo(T).@"struct".fields) |alt| {
            if (filtersNothing(@field(value, alt.name))) return true;
        }
        return false;
    }
    if (comptime std.mem.eql(u8, name, across_field)) {
        const info = @typeInfo(T).@"struct";
        if (!info.is_tuple) return entryFiltersNothing(value);
        inline for (info.fields) |entry| {
            if (!entryFiltersNothing(@field(value, entry.name))) return false;
        }
        return true;
    }
    if (comptime std.mem.eql(u8, name, exists_field) or std.mem.eql(u8, name, not_exists_field))
        return false;
    if (comptime operatorsOf(T) == null) return false;
    return entryFiltersNothing(value);
}

/// A column's operators, or an `.across` entry's: ANDed, so the set narrows
/// nothing only when every operator in it narrows nothing.
fn entryFiltersNothing(ops: anytype) bool {
    inline for (@typeInfo(@TypeOf(ops)).@"struct".fields) |f| {
        if (comptime std.mem.eql(u8, f.name, across_columns)) continue;
        if (!opFiltersNothing(f.name, @field(ops, f.name))) return false;
    }
    return true;
}

fn opFiltersNothing(comptime name: []const u8, value: anytype) bool {
    // A term that may drop never reaches an `UPDATE` or a `DELETE`: the
    // statement refuses it while compiling (`assertNothingDroppable`).
    if (comptime givenValue(@TypeOf(value)) != null) return false;
    if (comptime listSpelling(name)) |op| {
        // An empty `in` matches no row, which narrows as far as it goes.
        if (op == .in) return false;
        return value.len == 0;
    }
    if (comptime patternSpelling(name)) |pattern| {
        // `not_contains ""` is `NOT LIKE '%%'`, true of no row.
        if (pattern.negate) return false;
        return textLen(value) == 0;
    }
    return false;
}

fn textLen(value: anytype) usize {
    const T = @TypeOf(value);
    if (T == core.Str) return value.len();
    if (comptime !isText(T)) return 1;
    return value.len;
}

/// The type at the end of a path. Public because the parameter tuple a
/// statement is run with is built out of these, one per placeholder, and
/// that tuple's type has to exist before any of it is read (`db.zig`).
pub fn ValueAt(comptime W: type, comptime path: Path) type {
    comptime {
        if (path.len == 0) return W;
        return ValueAt(@FieldType(W, path[0]), path[1..]);
    }
}

// -- the walk ------------------------------------------------------------

/// The most parameters one condition may carry. A where struct is written by
/// hand, so this is far past anything legitimate; it is here so a mistake
/// stops with a message rather than an eval-quota crash.
const max_params = 64;

/// The most parents one condition may reach into. The same kind of number as
/// `max_params`: far past a hand-written condition, there to stop a mistake
/// with a sentence.
const max_reached = 16;

const State = struct {
    next: usize,
    paths: [max_params]Path = undefined,
    /// What each placeholder is for, in the same order — see `Param`.
    params: [max_params]Param = undefined,
    count: usize = 0,
    /// Set while the walk is inside an `.exists`: what every column written
    /// from here is qualified with, and which Row its type comes from.
    ///
    /// **On the State rather than threaded through six signatures**, because
    /// the two have to move together and there is exactly one walk. A
    /// qualifier that got out of step with the Row would write a column of one
    /// table and bind it as a column of another, which compiles.
    qualifier: []const u8 = "",
    inner: ?type = null,
    /// Set while the walk is inside a `sql.given`: the value lives one field
    /// deeper than the path says, and the parameter binds as an optional
    /// whatever its column is (ADR 149).
    ///
    /// **On the State for the same reason the qualifier is**: the path and the
    /// two flags have to move together, and there is one walk.
    dropping: bool = false,
    /// Set while the walk is inside an `.exists`, where a `given` drops the
    /// whole subquery rather than one term of it — so the term writes no guard
    /// of its own and `oneExists` writes one around the lot.
    in_group: bool = false,
    /// Placeholders being written a second time, for another column of an
    /// `.across` (ADR 172). `take` hands them back in order and records
    /// nothing: the value was recorded, once, when the first column took it,
    /// and the statement names the same `$n` on every column.
    replay: []const usize = &.{},
    replayed: usize = 0,
    /// Set while the walk is over a shaped Row (ADR 218): the Row whose
    /// parents and aggregates a name at this level may be, the path its
    /// parent is joined under (empty for the Row itself), and how the Row is
    /// written when an `.exists` below correlates with it.
    ///
    /// **Cleared inside an `.exists`**, whose subquery reads a table of its
    /// own: a name in there is that table's column, whatever the Row outside
    /// happens to carry under the same name.
    shape: ?type = null,
    alias: []const u8 = "",
    outer: []const u8 = "",
    phase: Phase = .all,
    /// Set while the walk is inside `.any`, where an aggregate may not be
    /// named: a term on the rows and a term on the groups cannot be ORed,
    /// because they are two clauses.
    nested: bool = false,
    /// What a term writes in place of the quoted column while it is a term on
    /// a group: the aggregate's call. Empty everywhere else.
    spelled: []const u8 = "",
    /// The parents the walk went into, for `Plan.reached`.
    reached: [max_reached][]const u8 = undefined,
    reached_count: usize = 0,

    fn reach(self: *State, comptime alias: []const u8) void {
        for (self.reached[0..self.reached_count]) |seen| {
            if (std.mem.eql(u8, seen, alias)) return;
        }
        if (self.reached_count == max_reached) @compileError(
            "nilo: a condition reaches more than " ++
                std.fmt.comptimePrint("{d}", .{max_reached}) ++ " parents.",
        );
        self.reached[self.reached_count] = alias;
        self.reached_count += 1;
    }

    fn take(self: *State, comptime path: Path, comptime param: Param) usize {
        if (self.replay.len > 0) {
            if (self.replayed == self.replay.len) @compileError(
                "nilo: an `.across` column took more parameters than the first column did.",
            );
            const n = self.replay[self.replayed];
            self.replayed += 1;
            return n;
        }
        if (self.count == max_params) @compileError(
            "nilo: a condition with more than " ++
                std.fmt.comptimePrint("{d}", .{max_params}) ++ " values.\n" ++
                "  That is past anything a hand-written condition reaches; " ++
                "`db.raw` is the way to send a statement this size.",
        );
        var owned = param;
        // Filled here rather than at the six call sites, so a parameter
        // written inside an `.exists` cannot be recorded as the outer Row's.
        if (owned.of == null) owned.of = self.inner;
        // The same argument for the other two: a `given` is recognised in one
        // place and every `take` under it carries the flags, so no operator
        // has to remember to set them (ADR 149).
        if (self.dropping) {
            owned.droppable = true;
            owned.nullable = true;
        }
        // The value is the optional inside the wrapper, so the path a Wire
        // reads by is one field longer than the one the walk built.
        const written = if (self.dropping) path ++ &[_][]const u8{"value"} else path;
        self.paths[self.count] = written;
        self.params[self.count] = owned;
        self.count += 1;
        const n = self.next;
        self.next += 1;
        return n;
    }
};

fn walk(
    comptime D: type,
    comptime Row: type,
    comptime W: type,
    comptime prefix: Path,
    comptime state: *State,
) []const u8 {
    comptime {
        const info = switch (@typeInfo(W)) {
            .@"struct" => |s| s,
            else => @compileError(
                "nilo: a condition has to be a struct, and this one is a " ++
                    @typeName(W) ++ ".\n" ++
                    "  Write it out where it is used: `.where = .{ .id = 7 }`.",
            ),
        };
        if (info.fields.len == 0) return "";

        var out: []const u8 = "";
        for (info.fields) |f| {
            const path = prefix ++ &[_][]const u8{f.name};
            const term = term: {
                // A name on a shaped Row may be something other than a column
                // (ADR 218), and which clause it belongs to follows from what
                // it is.
                if (state.shape) |Shape| switch (row_mod.kindOf(Shape, f.name)) {
                    .aggregate => {
                        if (state.nested) @compileError(
                            "nilo: `." ++ f.name ++ "` is an aggregate of " ++ @typeName(Shape) ++
                                ", named inside `.any`.\n" ++
                                "  A condition on a group is a `HAVING` and one on a row is a " ++
                                "`WHERE`, and an alternative cannot be half of each. Name the " ++
                                "aggregate beside the `.any`, where it narrows the groups.",
                        );
                        if (state.phase != .groups) continue;
                        break :term groupTerm(D, Shape, f.name, f.type, path, state);
                    },
                    .parent => {
                        if (state.phase == .groups) continue;
                        break :term parentTerm(D, Shape, f.name, f.type, path, state);
                    },
                    .count => {
                        if (state.phase == .groups) continue;
                        break :term countTerm(D, Shape, f.name, f.type, path, state);
                    },
                    .children => row_mod.noSuchColumn(Shape, f.name, "a condition"),
                    .column, .beside => {},
                };
                if (state.phase == .groups) continue;
                if (std.mem.eql(u8, f.name, any_field)) break :term anyOf(D, Row, f.type, path, state);
                if (std.mem.eql(u8, f.name, exists_field)) break :term existsOf(D, Row, f.type, path, state, false);
                if (std.mem.eql(u8, f.name, not_exists_field)) break :term existsOf(D, Row, f.type, path, state, true);
                if (std.mem.eql(u8, f.name, across_field)) break :term acrossOf(D, Row, f.type, path, state);
                if (!row_mod.hasColumn(Row, f.name)) {
                    row_mod.noSuchColumn(Row, f.name, "a condition");
                }
                // `.due_date = .today`: the database's clock, compared with
                // `=`, and nothing bound. Read here rather than in `condition`,
                // which is handed the type and not the struct the word sits in.
                if (f.type == @TypeOf(.enum_literal)) {
                    if (clockWord(D, Row, f.name, fieldValue(W, f.name), "`." ++ f.name ++ " = ." ++
                        @tagName(fieldValue(W, f.name)) ++ "`")) |clock|
                    {
                        break :term state.qualifier ++ D.quote(f.name) ++ " = " ++ clock;
                    }
                }
                break :term condition(D, Row, f.name, f.type, path, state);
            };
            if (term.len == 0) continue;
            out = out ++ (if (out.len == 0) "" else " AND ") ++ term;
        }
        return out;
    }
}

/// `.any = .{ …, … }` — a tuple of conditions, ORed, in brackets so that it
/// binds the way it reads next to an AND.
fn anyOf(
    comptime D: type,
    comptime Row: type,
    comptime T: type,
    comptime path: Path,
    comptime state: *State,
) []const u8 {
    comptime {
        const info = switch (@typeInfo(T)) {
            .@"struct" => |s| s,
            else => @compileError(
                "nilo: `.any` holds a list of conditions and this one is a " ++
                    @typeName(T) ++ ".\n" ++
                    "  Write `.any = .{ .{ … }, .{ … } }` — a condition per entry.",
            ),
        };
        // Empty first: `.{}` is a struct literal Zig does not call a tuple,
        // so asking about tuple-ness first would answer an emptiness mistake
        // with a message about shape.
        if (info.fields.len == 0) @compileError(
            "nilo: `.any` is empty.\n" ++
                "  An empty list of alternatives matches nothing, which is almost " ++
                "never what was meant; leave it out instead.",
        );
        if (!info.is_tuple) @compileError(
            "nilo: `.any` holds a list of conditions and this one is a single " ++
                "condition.\n  Write `.any = .{ .{ … }, .{ … } }`, with the outer " ++
                "braces holding one entry per alternative.",
        );

        var out: []const u8 = "(";
        for (info.fields, 0..) |f, i| {
            if (i > 0) out = out ++ " OR ";
            const before = state.count;
            const was_nested = state.nested;
            state.nested = true;
            const sub = walk(D, Row, f.type, path ++ &[_][]const u8{f.name}, state);
            state.nested = was_nested;
            // **`.any` is OR, and that reverses what dropping a term means**
            // (ADR 149). Everywhere else a term that is not there widens the
            // answer; an alternative that is not there narrows it, because the
            // rows it would have matched are gone. Two opposite meanings for
            // one word is what this refuses.
            for (state.params[before..state.count]) |p| {
                if (p.droppable) @compileError(
                    "nilo: an alternative of `.any` holds a `sql.given`.\n" ++
                        "  `.any` is OR, so an alternative that is not there makes the " ++
                        "condition match *fewer* rows — the opposite of what a filter " ++
                        "nobody set should do, and of what `sql.given` means everywhere " ++
                        "else.\n" ++
                        "  Put the optional filter beside the `.any` rather than inside it.",
                );
            }
            if (sub.len == 0) @compileError(
                "nilo: one of `.any`'s alternatives is empty.\n" ++
                    "  An empty condition matches every row, which makes the whole " ++
                    "`.any` mean nothing.",
            );
            out = out ++ sub;
        }
        return out ++ ")";
    }
}

/// `.customer = .{ .name = … }` on a shaped Row: the conditions on a parent's
/// columns, written against the alias the statement joins it under
/// ([ADR 218](../docs/adr/218-a-row-may-carry-its-parent-its-children-or-a-sum.md)).
///
/// **The same walk one level down**, with the qualifier and the Row it reads
/// moved together for the reason `.exists` moves them: a qualifier out of step
/// with the Row would write one table's column and bind it as another's. A
/// parent of the parent is reached the same way, so `.org_unit = .{ .customer
/// = .{ .name = … } }` is two steps of this and nothing new.
fn parentTerm(
    comptime D: type,
    comptime Shape: type,
    comptime name: []const u8,
    comptime T: type,
    comptime path: Path,
    comptime state: *State,
) []const u8 {
    comptime {
        const Parent = row_mod.parentRowOf(row_mod.fieldTypeOf(Shape, name).?).?;
        if (@typeInfo(T) == .null) @compileError(
            "nilo: `." ++ name ++ " = null` on " ++ @typeName(Shape) ++ " asks for rows with no " ++
                "parent, and a parent is a row rather than a value.\n" ++
                "  Ask the reference column instead, on a Row that reads it: `.<column> = null`.",
        );
        const shape = "  A parent takes conditions on its own columns: `." ++ name ++
            " = .{ .<column> = … }`.";
        switch (@typeInfo(T)) {
            .@"struct" => |s| if (s.is_tuple) @compileError(
                "nilo: `." ++ name ++ "` on " ++ @typeName(Shape) ++ " is given a list.\n" ++ shape,
            ),
            else => @compileError(
                "nilo: `." ++ name ++ "` on " ++ @typeName(Shape) ++ " is a parent, and is given a " ++
                    @typeName(T) ++ ".\n" ++ shape,
            ),
        }

        const alias = if (state.alias.len == 0) name else state.alias ++ "." ++ name;
        state.reach(alias);

        const was_shape = state.shape;
        const was_alias = state.alias;
        const was_qualifier = state.qualifier;
        const was_outer = state.outer;
        const was_inner = state.inner;
        state.shape = Parent;
        state.alias = alias;
        state.qualifier = D.quote(alias) ++ ".";
        state.outer = D.quote(alias);
        state.inner = Parent;
        const inside = walk(D, Parent, T, path, state);
        state.shape = was_shape;
        state.alias = was_alias;
        state.qualifier = was_qualifier;
        state.outer = was_outer;
        state.inner = was_inner;
        return inside;
    }
}

/// `.owed = .{ .gt = 0 }` on a grouped Row: a term on the groups, written
/// against the aggregate the field reports (ADR 218). The operators and the
/// binding are a column's; what they compare is the call.
fn groupTerm(
    comptime D: type,
    comptime Shape: type,
    comptime name: []const u8,
    comptime T: type,
    comptime path: Path,
    comptime state: *State,
) []const u8 {
    comptime {
        const aggregate = row_mod.aggregateOf(Shape, name).?;
        const was_spelled = state.spelled;
        const was_inner = state.inner;
        // The qualifier here is the grouped relation's, because a term on the
        // groups is only ever written at the top of the walk.
        state.spelled = aggregateCall(D, Shape, state.outer, aggregate);
        state.inner = Shape;
        const term = condition(D, Shape, name, T, path, state);
        state.spelled = was_spelled;
        state.inner = was_inner;
        return term;
    }
}

/// `.line_count = .{ .gt = 0 }` on a Row that counts its children: the
/// count's subquery in place of the column (ADR 218), the way `groupTerm`
/// puts an aggregate's call there. Correlated with `state.outer`, which is
/// the relation at the top of the walk and a parent's alias inside one.
fn countTerm(
    comptime D: type,
    comptime Shape: type,
    comptime name: []const u8,
    comptime T: type,
    comptime path: Path,
    comptime state: *State,
) []const u8 {
    comptime {
        const was_spelled = state.spelled;
        const was_inner = state.inner;
        state.spelled = @import("shape.zig").countCall(D, Shape, name, state.outer);
        state.inner = Shape;
        const term = condition(D, Shape, name, T, path, state);
        state.spelled = was_spelled;
        state.inner = was_inner;
        return term;
    }
}

/// One column against one value or one set of operators.
/// `.exists = .{ .{ .in = Child, .where = .{ … } }, … }` — one `EXISTS`
/// subquery per entry, ANDed, and `.not_exists` for `NOT EXISTS`.
///
/// **This is the one place the line past *one table* moves, and it moves for a
/// reason that names itself** ([ADR 218](../docs/adr/218-a-row-may-carry-its-parent-its-children-or-a-sum.md)).
/// An `EXISTS` does not change the column list and does not change the row
/// count: the answer is still rows of this Row, one per matching row, so
/// `.limit` still means what the caller thinks it means. A join changes both,
/// and that is what is still refused — the boundary did not blur, it moved to
/// where those two properties actually hold.
///
/// **The correlation is read out of a `.references` one of the two Rows
/// declared** — the child's, pointing at this table, or this Row's own,
/// pointing at the child's ([ADR 175](../docs/adr/175-an-exists-reads-the-reference-from-either-side.md))
/// — which is already checked harder than anything else in this repository:
/// `table.oneReference` makes the target be a Row, the target column be one of
/// its columns, and the two Zig types be the same. So joining on it costs no
/// new vocabulary at the call site and no new check — the fact was already
/// declared, for the migration tool, and this is the second reader of it.
fn existsOf(
    comptime D: type,
    comptime Outer: type,
    comptime T: type,
    comptime path: Path,
    comptime state: *State,
    comptime negate: bool,
) []const u8 {
    comptime {
        const word = if (negate) not_exists_field else exists_field;
        const info = switch (@typeInfo(T)) {
            .@"struct" => |s| s,
            else => @compileError(
                "nilo: `." ++ word ++ "` holds a list of tests and this one is a " ++
                    @typeName(T) ++ ".\n" ++
                    "  Write `." ++ word ++ " = .{ .{ .in = OtherRow, .where = .{ … } } }`, " ++
                    "one entry per test.",
            ),
        };
        if (info.fields.len == 0) @compileError(
            "nilo: `." ++ word ++ "` is empty.\n" ++
                "  A test over no table matches nothing, which is almost never what was " ++
                "meant; leave it out instead.",
        );
        // A tuple, for the same reason `.any` is one: two tests on a Row cannot
        // be two fields of the same name, and a filter page that narrows on two
        // capabilities is the ordinary case rather than the exotic one.
        if (!info.is_tuple) @compileError(
            "nilo: `." ++ word ++ "` holds a list of tests and this one is a single " ++
                "test.\n  Write `." ++ word ++ " = .{ .{ .in = OtherRow, .where = .{ … } } }`, " ++
                "with the outer braces holding one entry per test — a struct cannot carry " ++
                "the same field twice, so a single test written bare could never become two.",
        );

        var out: []const u8 = "";
        for (info.fields, 0..) |f, i| {
            if (i > 0) out = out ++ " AND ";
            out = out ++ oneExists(
                D,
                Outer,
                f.type,
                path ++ &[_][]const u8{f.name},
                state,
                negate,
                word,
            );
        }
        return out;
    }
}

fn oneExists(
    comptime D: type,
    comptime Outer: type,
    comptime T: type,
    comptime path: Path,
    comptime state: *State,
    comptime negate: bool,
    comptime word: []const u8,
) []const u8 {
    comptime {
        const shape = "  Write `.{ .in = OtherRow, .where = .{ … } }`, and `.on = .<column>` " ++
            "(or `.via = .<column>` for a column of this Row) when the two tables are " ++
            "joined by a column no `.references` names.";

        if (@typeInfo(T) != .@"struct" or @typeInfo(T).@"struct".is_tuple) @compileError(
            "nilo: an entry of `." ++ word ++ "` is a " ++ @typeName(T) ++ ".\n" ++ shape,
        );
        for (@typeInfo(T).@"struct".fields) |f| {
            for (exists_known) |ok| {
                if (std.mem.eql(u8, f.name, ok)) break;
            } else @compileError(
                "nilo: an entry of `." ++ word ++ "` sets `." ++ f.name ++
                    "`, which is not part of it.\n" ++
                    "  It takes `.in`, `.where`, and `.on` or `.via` when the join column " ++
                    "is not one a `.references` already names.",
            );
        }
        if (!@hasField(T, "in")) @compileError(
            "nilo: an entry of `." ++ word ++ "` does not say `.in`.\n" ++
                "  That is the Row the matching row would be over.\n" ++ shape,
        );
        if (!@hasField(T, "where")) @compileError(
            "nilo: an entry of `." ++ word ++ "` does not say `.where`.\n" ++
                "  Without one it asks whether the other table has any row joined to " ++
                "this one at all, which the join column already answers — and answers " ++
                "without a subquery.\n" ++ shape,
        );

        const Child = @FieldType(T, "in");
        if (Child != type) @compileError(
            "nilo: `." ++ word ++ "`'s `.in` is a " ++ @typeName(Child) ++ ".\n" ++
                "  It is the Row itself, written where it is used: `.in = PartnerCapability`.",
        );
        // The **value** written there, which is the Row itself. `@FieldType`
        // would answer `type`, which is what `.in`'s field holds rather than
        // what it says.
        const Inner = fieldValue(T, "in");
        row_mod.assertRow(Inner);

        // Before the join is looked for, because a self-reference is a
        // reference in both directions and would be refused as that instead.
        // The Row outside is written the way the statement wrote it: its
        // relation, or the alias a parent was joined under (ADR 218).
        const outer_rel = if (state.outer.len > 0) state.outer else relationOf(D, Outer);
        const inner_rel = relationOf(D, Inner);
        if (std.mem.eql(u8, outer_rel, inner_rel)) @compileError(
            "nilo: `." ++ word ++ "` names " ++ @typeName(Inner) ++ ", which reads the same " ++
                "table as " ++ @typeName(Outer) ++ ".\n" ++
                "  Both sides would be written as " ++ inner_rel ++ ", so every column in " ++
                "the subquery would be ambiguous. A test against the same table needs an " ++
                "alias, which is `db.raw`.",
        );

        const link = correlation(Outer, Inner, T, word);

        // The walk inside the subquery names the other table and the other
        // Row. Saved and put back, so a second entry beside this one is walked
        // against the outer Row again.
        const was_qualifier = state.qualifier;
        const was_inner = state.inner;
        const was_group = state.in_group;
        const was_shape = state.shape;
        const was_outer = state.outer;
        const before = state.count;
        const guard = state.next;
        state.qualifier = inner_rel ++ ".";
        state.inner = Inner;
        state.shape = null;
        state.outer = inner_rel;
        // A `given` in here drops the whole subquery rather than one term of
        // it, so the terms write no guards of their own (ADR 149).
        state.in_group = true;
        // The **type** of the condition, because that is what a walk reads —
        // the mirror of the line above, and the one place the two are easy to
        // mix up.
        const inside = walk(
            D,
            Inner,
            @FieldType(T, "where"),
            path ++ &[_][]const u8{"where"},
            state,
        );
        state.qualifier = was_qualifier;
        state.inner = was_inner;
        state.in_group = was_group;
        state.shape = was_shape;
        state.outer = was_outer;

        // **A `given` inside an `.exists` is the whole test, or it is a
        // Refusal** (ADR 149). Dropping one term of the subquery would leave
        // it asking whether *any* joined row exists, which excludes every row
        // with none — the opposite of no filter, and it compiles.
        var droppable = 0;
        for (state.params[before..state.count]) |p| {
            if (p.droppable) droppable += 1;
        }
        if (droppable > 0 and state.count - before > 1) @compileError(
            "nilo: an entry of `." ++ word ++ "` over " ++ @typeName(Inner) ++
                " holds a `sql.given` beside another condition.\n" ++
                "  Inside a subquery a `sql.given` is what makes the whole `" ++
                (if (negate) "NOT EXISTS" else "EXISTS") ++ "` drop, because dropping one " ++
                "term of it would leave it asking whether any joined row exists at all — " ++
                "which excludes every row that has none.\n" ++
                "  Write a second `." ++ word ++ "` entry for the condition that is always " ++
                "there.",
        );

        if (inside.len == 0) @compileError(
            "nilo: an entry of `." ++ word ++ "` has an empty `.where`.\n" ++
                "  An empty condition matches every row of " ++ @typeName(Inner) ++ ", so " ++
                "the test asks only whether one is joined to this row — which the join " ++
                "column answers without a subquery.",
        );

        var joined: []const u8 = "";
        for (link.inner, link.outer) |mine, theirs| {
            joined = joined ++ (if (joined.len == 0) "" else " AND ") ++
                inner_rel ++ "." ++ D.quote(mine) ++ " = " ++
                outer_rel ++ "." ++ D.quote(theirs);
        }
        const test_sql = (if (negate) "NOT EXISTS (SELECT 1 FROM " else "EXISTS (SELECT 1 FROM ") ++
            inner_rel ++ " WHERE " ++ joined ++ " AND " ++ inside ++ ")";
        if (droppable == 0) return test_sql;
        // The guard the terms inside did not write, around the whole test.
        // Nested inside another `.exists` it belongs to that one instead, and
        // the outer walk is what writes it. The subquery goes first, for the
        // reason `guarded` gives.
        if (was_group) return test_sql;
        return guarded(D, test_sql, guard);
    }
}

/// `.across = .{ .columns = .{ .code, .name }, .icontains = q }` — one
/// condition, and the row matches when any of the columns meets it
/// ([ADR 172](../docs/adr/172-one-condition-over-several-columns-is-one-parameter.md)).
/// A tuple of entries is several, ANDed, the way `.exists` takes several.
fn acrossOf(
    comptime D: type,
    comptime Row: type,
    comptime T: type,
    comptime path: Path,
    comptime state: *State,
) []const u8 {
    comptime {
        const info = switch (@typeInfo(T)) {
            .@"struct" => |s| s,
            else => @compileError(
                "nilo: `.across` is a " ++ @typeName(T) ++ ".\n" ++ across_shape,
            ),
        };
        if (!info.is_tuple) return oneAcross(D, Row, T, path, state);
        if (info.fields.len == 0) @compileError(
            "nilo: `.across` is empty.\n  Leave it out instead.",
        );
        var out: []const u8 = "";
        for (info.fields, 0..) |f, i| {
            if (i > 0) out = out ++ " AND ";
            out = out ++ oneAcross(D, Row, f.type, path ++ &[_][]const u8{f.name}, state);
        }
        return out;
    }
}

const across_shape = "  Write `.across = .{ .columns = .{ .code, .name, .trademark }, .icontains = q }`: " ++
    "the columns, then the condition every one of them is tested against.";

/// One `.across` entry: the operators walked once against the first column,
/// taking their parameters, and once more against each other column with
/// the same placeholders handed back — so `$3` is bound once and named three
/// times, and a `sql.given` on it guards the whole bracket.
fn oneAcross(
    comptime D: type,
    comptime Row: type,
    comptime T: type,
    comptime path: Path,
    comptime state: *State,
) []const u8 {
    comptime {
        const info = switch (@typeInfo(T)) {
            .@"struct" => |s| if (s.is_tuple) @compileError(
                "nilo: an entry of `.across` is a tuple.\n" ++ across_shape,
            ) else s,
            else => @compileError(
                "nilo: an entry of `.across` is a " ++ @typeName(T) ++ ".\n" ++ across_shape,
            ),
        };
        if (!@hasField(T, across_columns)) @compileError(
            "nilo: an entry of `.across` does not say `.columns`.\n" ++ across_shape,
        );

        // The columns: a tuple of enum literals, two or more, each a column
        // of the Row, and all of them read as one Zig type — the parameter is
        // bound once, as the first column's type, and a second type would be
        // a cast nobody wrote.
        const Columns = @FieldType(T, across_columns);
        const columns_info = switch (@typeInfo(Columns)) {
            .@"struct" => |s| if (s.is_tuple) s else @compileError(
                "nilo: `.across`'s `.columns` is not a list.\n" ++ across_shape,
            ),
            else => @compileError(
                "nilo: `.across`'s `.columns` is a " ++ @typeName(Columns) ++ ".\n" ++ across_shape,
            ),
        };
        if (columns_info.fields.len < 2) @compileError(
            "nilo: `.across` names " ++ (if (columns_info.fields.len == 0) "no column" else "one column") ++
                ".\n  One column is an ordinary condition: write `." ++
                (if (columns_info.fields.len == 1) @tagName(fieldValue(Columns, "0")) else "code") ++
                " = …`. `.across` is for a value tested against several.",
        );
        var columns: [columns_info.fields.len][]const u8 = undefined;
        for (columns_info.fields, 0..) |f, i| {
            if (f.type != @TypeOf(.enum_literal)) @compileError(
                "nilo: `.across`'s `.columns` holds a " ++ @typeName(f.type) ++
                    ".\n  A column is named as it is in a condition: `.code`.",
            );
            const name = @tagName(fieldValue(Columns, f.name));
            if (!row_mod.hasColumn(Row, name)) row_mod.noSuchColumn(Row, name, "an `.across`");
            columns[i] = name;
        }
        const First = bareOf(row_mod.ColumnType(Row, columns[0]));
        for (columns[1..]) |name| {
            const Other = bareOf(row_mod.ColumnType(Row, name));
            if (Other != First) @compileError(
                "nilo: `.across` on " ++ @typeName(Row) ++ " names `" ++ columns[0] ++ "`, which is " ++
                    @typeName(row_mod.ColumnType(Row, columns[0])) ++ ", and `" ++ name ++ "`, which is " ++
                    @typeName(row_mod.ColumnType(Row, name)) ++ ".\n" ++
                    "  One parameter is bound as one type and tested against every column, " ++
                    "so the columns have to read as one. Two types is two conditions, in `.any`.",
            );
        }

        // The operators: everything else in the entry, ANDed per column the
        // way a column's own operators are.
        var ops: []const Operator = &.{};
        for (info.fields) |f| {
            if (std.mem.eql(u8, f.name, across_columns)) continue;
            if (spelling(f.name) == null and patternSpelling(f.name) == null and
                listSpelling(f.name) == null and nullSafeSpelling(f.name) == null and
                foldedSpelling(f.name) == null)
            {
                @compileError(
                    "nilo: an entry of `.across` sets `." ++ f.name ++ "`, which is not an operator.\n" ++
                        "  Beside `.columns` it takes what a column takes: `.eq`, `.icontains`, " ++
                        "`.gt` and the rest, each with its value.",
                );
            }
            ops = ops ++ &[_]Operator{.{ .name = f.name, .T = f.type }};
        }
        if (ops.len == 0) @compileError(
            "nilo: an entry of `.across` names its columns and no condition.\n" ++ across_shape,
        );

        const was_group = state.in_group;
        const before = state.count;
        const guard = state.next;
        // The terms write no guard of their own: one goes around the whole
        // bracket below, for the reason `oneExists` gives.
        state.in_group = true;

        var out: []const u8 = "(";
        for (columns, 0..) |column, i| {
            if (i > 0) out = out ++ " OR ";
            const quoted = state.qualifier ++ D.quote(column);
            // The first column takes the parameters; every other column is
            // handed the same numbers back.
            var numbers: [max_params]usize = undefined;
            if (i > 0) {
                for (guard..state.next, 0..) |n, j| numbers[j] = n;
                state.replay = numbers[0 .. state.next - guard];
                state.replayed = 0;
            }
            var term: []const u8 = "";
            for (ops, 0..) |op, j| {
                if (j > 0) term = term ++ " AND ";
                term = term ++ operator(D, Row, column, quoted, op, path, state);
            }
            if (i > 0) {
                if (state.replayed != state.replay.len) @compileError(
                    "nilo: an `.across` column took fewer parameters than the first column did.",
                );
                state.replay = &.{};
                state.replayed = 0;
            }
            out = out ++ (if (ops.len > 1) "(" ++ term ++ ")" else term);
        }
        out = out ++ ")";
        state.in_group = was_group;

        // A `sql.given` here is the whole bracket, or it is a Refusal — the
        // rule `oneExists` has, for the same reason: dropping one operator
        // of several would leave the others deciding on their own.
        var droppable = 0;
        for (state.params[before..state.count]) |p| {
            if (p.droppable) droppable += 1;
        }
        if (droppable > 0 and state.count - before > 1) @compileError(
            "nilo: an entry of `.across` holds a `sql.given` beside another condition.\n" ++
                "  The `sql.given` is what makes the whole bracket drop, and dropping one " ++
                "condition of it would leave the others deciding on their own.\n" ++
                "  Write a second `.across` entry for the condition that is always there.",
        );
        if (droppable == 0) return out;
        if (was_group) return out;
        return guarded(D, out, guard);
    }
}

/// The column's type without its optional, for saying whether two columns
/// bind as one: a nullable `trademark` and a `name` are both text.
fn bareOf(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .optional => |o| o.child,
        else => T,
    };
}

/// A term that is only there when its parameter is: `(term OR $n IS NULL)`.
///
/// **The term comes first, and on Postgres that is the whole of what makes
/// this run.** pg.zig sends a `Parse` with no parameter types, so the server
/// works each one out from its first use — and `$1 IS NULL` is a null test on
/// a value of unknown type, which fixes nothing. Written guard-first, the
/// statement compiles here, passes the schema check, and is *could not
/// determine data type of parameter $1* (`42P08`) from the database on the
/// first request. Written term-first, `"name" = $1` or `'%' || $1` or
/// `EXISTS (… = $1)` has already given the parameter its type by the time the
/// null test reads it, for every column type there is — an enum and a `uuid`
/// included, which is what a cast on the guard could not have done, since
/// `accepts` declines to name an enum. The two orders mean the same thing:
/// `OR` is commutative in SQL's three-valued logic and the planner does not
/// care which side it read first. Found by the port whose list endpoint was
/// the ADR's own example; the comptime tests asserted the guard-first string
/// and passed, and `live.zig` now runs each shape against Postgres.
fn guarded(comptime D: type, comptime term: []const u8, comptime n: usize) []const u8 {
    return "(" ++ term ++ " OR " ++ D.placeholder(n) ++ " IS NULL)";
}

/// The relation a Row reads, quoted and schema-qualified — the same text
/// `statement.relation` writes, computed here because a subquery names two of
/// them and neither is the statement's own.
fn relationOf(comptime D: type, comptime Row: type) []const u8 {
    comptime {
        const q = row_mod.qualifiedOf(Row);
        return D.qualify(q.schema, q.table);
    }
}

/// A column list for a message: `` `epic_id`, `department_id` ``.
fn nameList(comptime columns: []const []const u8) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (columns, 0..) |c, i| out = out ++ (if (i == 0) "" else ", ") ++ "`" ++ c ++ "`";
        return out;
    }
}

/// Which columns of each side the two tables are joined by, one for one.
///
/// **A list rather than a name since a foreign key can span two columns**
/// (ADR 181). Joining a composite key on its first column alone is the shape
/// of mistake this module exists to refuse: the query runs, reads correctly and
/// answers a wider question than the schema asked.
const Link = struct {
    inner: []const []const u8,
    outer: []const []const u8,
};

/// The join, taken from a `.references` on either Row — the child's, pointing
/// at the outer table, or the outer Row's own, pointing at the inner one —
/// or from `.on` / `.via` plus the far side's key when the schema does not
/// declare one.
///
/// **Zero matches and two matches are both Refusals**, and they are different
/// mistakes: nothing to join on is a schema that has not said how the tables
/// relate, and two ways to join is a schema that has said it twice — a table
/// with `.created_by` and `.updated_by` both pointing at `staff` is the
/// ordinary shape of the second, and guessing between them would be a query
/// that reads correctly and answers the wrong question. Two tables that point
/// at each other are the second mistake in a different coat: which direction
/// the query means is the same question, and `.on` names the inner column
/// while `.via` names the outer one, so an answer cannot be read as the other
/// ([ADR 175](../docs/adr/175-an-exists-reads-the-reference-from-either-side.md)).
fn correlation(
    comptime Outer: type,
    comptime Inner: type,
    comptime T: type,
    comptime word: []const u8,
) Link {
    comptime {
        const outer_q = row_mod.qualifiedOf(Outer);
        const inner_q = row_mod.qualifiedOf(Inner);
        // The child direction: a column of Inner that points at Outer.
        var found: []const Link = &.{};
        var named: []const u8 = "";
        for (table_mod.foreignKeysOf(Inner)) |ref| {
            if (!std.mem.eql(u8, ref.table, outer_q.table)) continue;
            if (!table_mod.sameSchema(ref.schema, outer_q.schema)) continue;
            named = named ++ (if (found.len == 0) "" else ", ") ++ nameList(ref.columns);
            found = found ++ &[_]Link{.{ .inner = ref.columns, .outer = ref.targets }};
        }
        // The parent direction: a column of Outer that points at Inner.
        var back: []const Link = &.{};
        var back_named: []const u8 = "";
        for (table_mod.foreignKeysOf(Outer)) |ref| {
            if (!std.mem.eql(u8, ref.table, inner_q.table)) continue;
            if (!table_mod.sameSchema(ref.schema, inner_q.schema)) continue;
            back_named = back_named ++ (if (back.len == 0) "" else ", ") ++ nameList(ref.columns);
            back = back ++ &[_]Link{.{ .inner = ref.targets, .outer = ref.columns }};
        }

        if (@hasField(T, "on") and @hasField(T, "via")) @compileError(
            "nilo: an entry of `." ++ word ++ "` says both `.on` and `.via`.\n" ++
                "  They are the two ends of one join: `.on` is the column of " ++
                @typeName(Inner) ++ " that points at " ++ @typeName(Outer) ++ ", and `.via` " ++
                "is the column of " ++ @typeName(Outer) ++ " that points at " ++
                @typeName(Inner) ++ ". Write whichever side holds the key, and only that one.",
        );

        if (@hasField(T, "on")) {
            const On = @FieldType(T, "on");
            if (On != @TypeOf(.enum_literal)) @compileError(
                "nilo: `." ++ word ++ "`'s `.on` is a " ++ @typeName(On) ++ ".\n" ++
                    "  It is the column of " ++ @typeName(Inner) ++ " that points at " ++
                    @typeName(Outer) ++ ", written as a name: `.on = .partner_id`.",
            );
            const wanted = @tagName(fieldValue(T, "on"));
            if (!row_mod.hasColumn(Inner, wanted)) {
                row_mod.noSuchColumn(Inner, wanted, "`." ++ word ++ "`'s `.on`");
            }
            // A declared foreign key on that column still wins, because it
            // names the column on the *other* side exactly rather than
            // assuming the key. A composite one counts: `.on` picks which
            // foreign key is meant, and the join is still all of its columns.
            for (found) |link| {
                for (link.inner) |c| {
                    if (std.mem.eql(u8, c, wanted)) return link;
                }
            }
            const outer_keys = row_mod.keysOf(Outer);
            if (outer_keys.len != 1) @compileError(
                "nilo: `." ++ word ++ "`'s `.on = ." ++ wanted ++ "` has nothing to join to.\n" ++
                    "  " ++ @typeName(Inner) ++ " declares no `.references` from that column, " ++
                    "so the other side would be " ++ @typeName(Outer) ++ "'s key — and that " ++
                    "key is " ++ row_mod.keyList(Outer) ++ ", which one column cannot match.\n" ++
                    "  Declare the foreign key: `.references = .{ ." ++ wanted ++ " = .{ " ++
                    @typeName(Outer) ++ ", .<column> } }`.",
            );
            return .{ .inner = &.{wanted}, .outer = &.{outer_keys[0]} };
        }

        if (@hasField(T, "via")) {
            const Via = @FieldType(T, "via");
            if (Via != @TypeOf(.enum_literal)) @compileError(
                "nilo: `." ++ word ++ "`'s `.via` is a " ++ @typeName(Via) ++ ".\n" ++
                    "  It is the column of " ++ @typeName(Outer) ++ " that points at " ++
                    @typeName(Inner) ++ ", written as a name: `.via = .department_id`.",
            );
            const wanted = @tagName(fieldValue(T, "via"));
            if (!row_mod.hasColumn(Outer, wanted)) {
                row_mod.noSuchColumn(Outer, wanted, "`." ++ word ++ "`'s `.via`");
            }
            for (back) |link| {
                for (link.outer) |c| {
                    if (std.mem.eql(u8, c, wanted)) return link;
                }
            }
            const inner_keys = row_mod.keysOf(Inner);
            if (inner_keys.len != 1) @compileError(
                "nilo: `." ++ word ++ "`'s `.via = ." ++ wanted ++ "` has nothing to join to.\n" ++
                    "  " ++ @typeName(Outer) ++ " declares no `.references` from that column, " ++
                    "so the other side would be " ++ @typeName(Inner) ++ "'s key — and that " ++
                    "key is " ++ row_mod.keyList(Inner) ++ ", which one column cannot match.\n" ++
                    "  Declare the foreign key: `.references = .{ ." ++ wanted ++ " = .{ " ++
                    @typeName(Inner) ++ ", .<column> } }`.",
            );
            return .{ .inner = &.{inner_keys[0]}, .outer = &.{wanted} };
        }

        if (found.len == 0 and back.len == 0) @compileError(
            "nilo: `." ++ word ++ "` names " ++ @typeName(Inner) ++ ", which declares no " ++
                "`.references` to " ++ @typeName(Outer) ++ "'s table `" ++ outer_q.table ++
                "`.\n" ++
                "  And " ++ @typeName(Outer) ++ " declares none to " ++ @typeName(Inner) ++
                "'s table `" ++ inner_q.table ++ "`, so neither side says how the two " ++
                "relate. The join is read out of the schema rather than written at the " ++
                "call site, so there has to be one. Add `.references = .{ .<column> = .{ " ++
                @typeName(Outer) ++ ", .<column> } }` to " ++ @typeName(Inner) ++ "'s " ++
                row_mod.marker ++ " (or the reverse to " ++ @typeName(Outer) ++ "'s), or say " ++
                "which column joins: `.on = .<column>` of " ++ @typeName(Inner) ++ ", or " ++
                "`.via = .<column>` of " ++ @typeName(Outer) ++ ".",
        );
        if (found.len > 0 and back.len > 0) @compileError(
            "nilo: `." ++ word ++ "` names " ++ @typeName(Inner) ++ ", and the two tables " ++
                "point at each other: " ++ @typeName(Inner) ++ " at " ++ @typeName(Outer) ++
                "'s table from " ++ named ++ ", and " ++ @typeName(Outer) ++ " at " ++
                @typeName(Inner) ++ "'s from " ++ back_named ++ ".\n" ++
                "  Which direction the query means is a question about what it asks, and " ++
                "guessing would answer the other one. Write `.on = .<column>` for a column " ++
                "of " ++ @typeName(Inner) ++ ", or `.via = .<column>` for a column of " ++
                @typeName(Outer) ++ ".",
        );
        if (found.len > 1) @compileError(
            "nilo: `." ++ word ++ "` names " ++ @typeName(Inner) ++ ", which points at " ++
                @typeName(Outer) ++ "'s table from more than one column: " ++ named ++ ".\n" ++
                "  Which of them joins is a question about what the query means, and " ++
                "guessing would answer a different one. Write `.on = .<column>`.",
        );
        if (back.len > 1) @compileError(
            "nilo: `." ++ word ++ "` names " ++ @typeName(Inner) ++ ", which " ++
                @typeName(Outer) ++ " points at from more than one column: " ++ back_named ++
                ".\n" ++
                "  Which of them joins is a question about what the query means, and " ++
                "guessing would answer a different one. Write `.via = .<column>`.",
        );
        if (found.len == 1) return found[0];
        return back[0];
    }
}

/// The value a caller wrote out for one field of a struct literal, the way
/// `statement.writtenValue` reads one — one field, never the whole struct, so
/// a sibling holding a runtime value is not demanded to be comptime as well.
fn fieldValue(comptime T: type, comptime field: []const u8) blk: {
    for (@typeInfo(T).@"struct".fields) |f| {
        if (std.mem.eql(u8, f.name, field)) break :blk f.type;
    }
    break :blk void;
} {
    comptime {
        for (@typeInfo(T).@"struct".fields) |f| {
            if (!std.mem.eql(u8, f.name, field)) continue;
            const written = f.default_value_ptr orelse @compileError(
                "nilo: `." ++ field ++ "` has no value written out where it is used.\n" ++
                    "  It is settled while compiling, so it has to be a literal rather " ++
                    "than something worked out at run time.",
            );
            return @as(*const f.type, @ptrCast(@alignCast(written))).*;
        }
        unreachable;
    }
}

/// **The database's clock, as a word**: `.now` on a `sql.Timestamp` column and
/// `.today` on a `sql.Date` one, the expression the database evaluates in
/// place of a value. Null when the word is neither, and on a column whose type
/// is an enum, where `.now` is that enum's value as it always was.
///
/// Read by a `.set` (`statement.zig`) and by a condition, so the start-date
/// stamp is one statement: `.set = .{ .start_date = .today }` where
/// `.start_date = .{ .gt = .today }`. `.now` is `D.now_default`, the
/// expression a `.default` of `.now` puts in the schema. `.today` is
/// `CURRENT_DATE`, which both databases spell the same: a `date` on Postgres,
/// in the session's time zone, and the ten characters a `Date` is stored as on
/// SQLite, in UTC.
///
/// `said` is how the caller wrote it, for the message that refuses the word on
/// a column it does not fit.
pub fn clockWord(
    comptime D: type,
    comptime Row: type,
    comptime column: []const u8,
    comptime word: @TypeOf(.enum_literal),
    comptime said: []const u8,
) ?[]const u8 {
    comptime {
        const name = @tagName(word);
        const now = std.mem.eql(u8, name, "now");
        const today = std.mem.eql(u8, name, "today");
        if (!now and !today) return null;
        const F = row_mod.ColumnType(Row, column);
        const C = switch (@typeInfo(F)) {
            .optional => |o| o.child,
            else => F,
        };
        if (@typeInfo(C) == .@"enum") return null;
        if (now and C == types.Timestamp) return D.now_default;
        if (today and C == types.Date) return "CURRENT_DATE";
        @compileError(
            "nilo: " ++ said ++ " on " ++ @typeName(Row) ++ ", whose `" ++ column ++ "` is " ++
                @typeName(F) ++ ".\n" ++
                (if (now)
                    "  `.now` is the moment the statement runs, so it goes in a `sql.Timestamp`." ++
                        (if (C == types.Date) " A `sql.Date` takes `.today`." else "")
                else
                    "  `.today` is the day the statement runs, so it goes in a `sql.Date`." ++
                        (if (C == types.Timestamp) " A `sql.Timestamp` takes `.now`." else "")),
        );
    }
}

fn condition(
    comptime D: type,
    comptime Row: type,
    comptime column: []const u8,
    comptime T: type,
    comptime path: Path,
    comptime state: *State,
) []const u8 {
    comptime {
        // A term on a group names the aggregate rather than a column (ADR 218).
        const quoted = if (state.spelled.len > 0) state.spelled else state.qualifier ++ D.quote(column);

        // `.deleted_at = null` is `IS NULL`. It cannot mean anything else:
        // `= NULL` is never true in SQL, so reading it the other way would
        // produce a condition that silently matches nothing.
        if (@typeInfo(T) == .null) return quoted ++ " IS NULL";

        // A term that is only there when the filter carried a value
        // ([ADR 149](../docs/adr/149-a-filter-that-is-absent-is-not-a-filter-that-is-null.md)).
        // Asked before `assertNotOptional`, because a `Given` is a struct
        // holding an optional rather than an optional, and before
        // `operatorsOf`, which would read it as a value being compared whole.
        if (givenValue(T)) |Held| {
            const n = state.next;
            const was = state.dropping;
            state.dropping = true;
            const term = condition(D, Row, column, Held, path, state);
            state.dropping = was;
            // Inside an `.exists` the guard goes around the whole subquery
            // instead, because a term that drops there would leave the
            // subquery asking whether *any* joined row exists. `oneExists`
            // writes that one.
            if (state.in_group) return term;
            return guarded(D, term, n);
        }

        assertNotOptional(column, null, T);

        if (operatorsOf(T)) |ops| {
            var out: []const u8 = "";
            for (ops, 0..) |op, i| {
                if (i > 0) out = out ++ " AND ";
                out = out ++ (clockTerm(D, Row, column, quoted, T, op) orelse
                    operator(D, Row, column, quoted, op, path, state));
            }
            return out;
        }

        return quoted ++ " = " ++ D.bindAs(
            D.placeholder(state.take(path, .{ .column = column })),
            row_mod.ColumnType(Row, column),
            false,
        );
    }
}

/// `.{ .gt = .today }`: a comparison against the database's clock
/// (`clockWord`), or null for every operator and value that is not one. Only
/// the six comparisons take it; a list, a pattern and a null-safe comparison
/// have no clock to be compared with.
fn clockTerm(
    comptime D: type,
    comptime Row: type,
    comptime column: []const u8,
    comptime quoted: []const u8,
    comptime T: type,
    comptime op: Operator,
) ?[]const u8 {
    comptime {
        if (op.T != @TypeOf(.enum_literal)) return null;
        const spelled = spelling(op.name) orelse return null;
        if (std.mem.indexOf(u8, spelled, "LIKE") != null) return null;
        const word = fieldValue(T, op.name);
        const clock = clockWord(D, Row, column, word, "`." ++ column ++ " = .{ ." ++ op.name ++
            " = ." ++ @tagName(word) ++ " }`") orelse return null;
        return quoted ++ " " ++ spelled ++ " " ++ clock;
    }
}

/// Whether a term of type `T` compares its column with `=` to one value that
/// is always there: a plain value, or `.{ .eq = value }`. Not `null`, which
/// is `IS NULL`; not an optional, which may be; not a `sql.given`, which may
/// drop out; not any other operator, which can match a range.
///
/// What `updateReturningOne` and `deleteReturningOne` ask of every column of
/// a key or a unique before they promise one row
/// ([ADR 146](../docs/adr/146-a-statement-with-a-key-in-it-has-a-single-row-answer.md)).
pub fn pinsEquality(comptime T: type) bool {
    comptime {
        switch (@typeInfo(T)) {
            .null, .optional => return false,
            else => {},
        }
        if (givenValue(T) != null) return false;
        if (operatorsOf(T)) |ops| {
            return ops.len == 1 and std.mem.eql(u8, ops[0].name, "eq") and pinsEquality(ops[0].T);
        }
        return true;
    }
}

const Operator = struct {
    name: []const u8,
    T: type,
};

/// Whether `T` is a set of operators rather than a value. A struct that is
/// not a tuple and whose every field is a known operator name is one; a
/// struct that is neither is a value being compared whole, which is what a
/// `Uuid` or a `Timestamp` is.
fn operatorsOf(comptime T: type) ?[]const Operator {
    comptime {
        const info = switch (@typeInfo(T)) {
            .@"struct" => |s| s,
            else => return null,
        };
        if (info.is_tuple or info.fields.len == 0) return null;
        for (info.fields) |f| {
            if (spelling(f.name) != null) continue;
            if (listSpelling(f.name) != null) continue;
            if (nullSafeSpelling(f.name) != null) continue;
            if (patternSpelling(f.name) != null) continue;
            if (foldedSpelling(f.name) != null) continue;
            return null;
        }
        var out: [info.fields.len]Operator = undefined;
        for (info.fields, 0..) |f, i| out[i] = .{ .name = f.name, .T = f.type };
        const frozen = out;
        return &frozen;
    }
}

fn spelling(comptime name: []const u8) ?[]const u8 {
    const table = .{
        .{ "eq", "=" },              .{ "ne", "<>" },
        .{ "gt", ">" },              .{ "gte", ">=" },
        .{ "lt", "<" },              .{ "lte", "<=" },
        .{ "like", "LIKE" },         .{ "ilike", "ILIKE" },
        .{ "not_like", "NOT LIKE" }, .{ "not_ilike", "NOT ILIKE" },
    };
    inline for (table) |pair| {
        if (std.mem.eql(u8, name, pair[0])) return pair[1];
    }
    return null;
}

/// The two operators that compare **null-safely**, and the one place an
/// optional is allowed in a condition.
///
/// `IS DISTINCT FROM` is `<>` with NULL treated as an ordinary value: two
/// nulls are not distinct, and a null against anything else is. That is the
/// whole of why an optional may reach it and reaches nothing else — see
/// `assertNotOptional`, whose argument is that the *shape* of the statement
/// would otherwise depend on a value that arrives at run time. Here it does
/// not: `"col" IS DISTINCT FROM $1` is the same six words whether `$1` turns
/// out to be null or not, so nothing about the statement is left until run
/// time and ADR 036's rule is kept rather than bent.
///
/// This is also the operator that closes the branch `assertNotOptional` asks
/// for. `if (maybe) |v| … else …` is two statements written out because the
/// null case is a different question; `.{ .not_distinct_from = maybe }` is one
/// statement because it is not.
fn nullSafeSpelling(comptime name: []const u8) ?[]const u8 {
    comptime {
        if (std.mem.eql(u8, name, "distinct_from")) return "IS DISTINCT FROM";
        if (std.mem.eql(u8, name, "not_distinct_from")) return "IS NOT DISTINCT FROM";
        return null;
    }
}

/// The operators that take a list rather than a value, and what each becomes
/// in front of the one placeholder holding it.
///
/// `not_in` is `<> ALL` rather than `NOT (… = ANY(…))`, which is the same
/// question asked of every element instead of the negation of a whole
/// comparison — and it keeps the shape of the fragment identical to `in`'s,
/// so one placeholder still holds the whole list however long it is.
/// Which of the two list operators this is, rather than how it is spelled.
///
/// It used to answer `"= ANY"` and `"<> ALL"` — Postgres's words, handed
/// straight to the writer. That worked while one Dialect existed and stopped
/// the moment a second one spelled the same test another way, so the
/// question this answers is now *which operator* and the spelling belongs to
/// the branch that knows the dialect (ADR 055).
const ListOp = enum { in, not_in };

fn listSpelling(comptime name: []const u8) ?ListOp {
    comptime {
        if (std.mem.eql(u8, name, "in")) return .in;
        if (std.mem.eql(u8, name, "not_in")) return .not_in;
        return null;
    }
}

/// The **pattern** operators: the three shapes a search box actually asks for,
/// each in a case-folding and a case-sensitive spelling, each negatable.
///
/// **They exist because `like` hands the escaping to the caller and nothing
/// says so.** `.name = .{ .like = text }` binds the caller's text unchanged, so
/// a user typing `%` matches far more than they should and one typing `_`
/// matches a character they should not. Nothing is smuggled — it is a bound
/// parameter — and it is still the wrong answer, on the one input nobody tried.
/// Every caller ended up writing the same escape, and most of them did not.
///
/// Twelve names out of three rows, because a name written by hand twelve times
/// is a name spelled wrong once. The shape is the row; `i` in front folds case
/// and `not_` in front negates, which is the spelling `like`/`ilike`/`not_like`
/// already set.
///
/// **All twelve cost no allocation**, which is what took this from a design
/// nobody had to a Dialect call: the pattern is assembled and escaped inside
/// the statement (`dialect.pattern`), so what binds is the caller's own text
/// and the statement is the same constant every other one here is.
const PatternOp = struct {
    shape: dialect_mod.Pattern,
    fold: bool,
    negate: bool,
    /// The folding spelling of this shape, for the Refusal on a Dialect whose
    /// `LIKE` cannot be told to respect case.
    folding: []const u8,
};

const pattern_shapes = [_]struct { name: []const u8, shape: dialect_mod.Pattern }{
    .{ .name = "contains", .shape = .contains },
    .{ .name = "starts_with", .shape = .starts_with },
    .{ .name = "ends_with", .shape = .ends_with },
};

fn patternSpelling(comptime name: []const u8) ?PatternOp {
    comptime {
        for (pattern_shapes) |row| {
            const folding = "i" ++ row.name;
            for ([_]bool{ false, true }) |fold| {
                const base = if (fold) folding else row.name;
                for ([_]bool{ false, true }) |negate| {
                    const spelled = if (negate) "not_" ++ base else base;
                    if (std.mem.eql(u8, name, spelled)) return .{
                        .shape = row.shape,
                        .fold = fold,
                        .negate = negate,
                        .folding = folding,
                    };
                }
            }
        }
        return null;
    }
}

/// **Equality that ignores case**: `.ieq`, and `.not_ieq` so the leaf keeps
/// its negation ([ADR 052](../docs/adr/052-a-set-operation-over-one-table-is-a-condition.md)).
/// The answer is whether the operator negates.
///
/// **It is written as the lookup a `.unique` that ignores case serves**, which
/// is the reason it exists rather than `.ilike`: that unique is an index on
/// `lower(…)` on Postgres and a `COLLATE NOCASE` one on SQLite
/// (`dialect.foldedColumn`), and a plain `=` uses neither. So both sides go
/// through the same `foldedColumn` the index was built with, and the planner
/// sees the expression it indexed. `.ilike` would fold case too and read an
/// `_` in an email address as a wildcard; `.icontains` escapes it and matches
/// a substring. The upsert Refusal on a folded unique sends people here
/// ([ADR 151](../docs/adr/151-a-key-is-named-once.md)).
fn foldedSpelling(comptime name: []const u8) ?bool {
    comptime {
        if (std.mem.eql(u8, name, "ieq")) return false;
        if (std.mem.eql(u8, name, "not_ieq")) return true;
        return null;
    }
}

/// A pattern operator compares text against text, and both halves are checked.
///
/// The column, because `"age" LIKE …` is a comparison Postgres will make by
/// casting the number to text — an answer nobody wants and no error at all.
/// And the value, because a pattern is built out of the caller's own text and
/// there is nothing to build one out of otherwise.
fn assertTextPattern(
    comptime Row: type,
    comptime column: []const u8,
    comptime op: []const u8,
    comptime Value: type,
) void {
    comptime {
        const F = row_mod.ColumnType(Row, column);
        if (!isText(F)) @compileError(
            "nilo: `." ++ column ++ " = .{ ." ++ op ++ " = … }` on " ++ @typeName(Row) ++
                ", whose `" ++ column ++ "` is " ++ @typeName(F) ++ ".\n" ++
                "  `." ++ op ++ "` compares text. On a column holding something else the " ++
                "database casts it to text first, which compares the digits it happens " ++
                "to print rather than the value.",
        );
        if (!isText(Value) and Value != @TypeOf(.enum_literal)) @compileError(
            "nilo: `." ++ column ++ " = .{ ." ++ op ++ " = … }` was given a " ++
                @typeName(Value) ++ ".\n" ++
                "  It is compared as text, so what goes here is text — a `Str` from the " ++
                "request, or a `[]const u8`.",
        );
    }
}

/// Whether `T` is text this module will match a pattern against. `Str` is
/// Core's and is the ordinary one, because the text a search box sends arrives
/// as one.
fn isText(comptime T: type) bool {
    comptime {
        const Inner = switch (@typeInfo(T)) {
            .optional => |o| o.child,
            else => T,
        };
        if (Inner == core.Str) return true;
        return switch (@typeInfo(Inner)) {
            .pointer => |p| p.size == .slice and p.child == u8,
            .array => |a| a.child == u8,
            else => false,
        };
    }
}

fn operator(
    comptime D: type,
    comptime Row: type,
    comptime column: []const u8,
    comptime quoted: []const u8,
    comptime op: Operator,
    comptime prefix: Path,
    comptime state: *State,
) []const u8 {
    comptime {
        const path = prefix ++ &[_][]const u8{op.name};

        // Before the optional check, because this is the operator the check
        // exists to send people to.
        if (nullSafeSpelling(op.name)) |spelled| {
            // A null written as a literal needs no parameter at all — the
            // comparison is against NULL itself, which is a keyword.
            if (@typeInfo(op.T) == .null) return quoted ++ " " ++ spelled ++ " NULL";
            return quoted ++ " " ++ spelled ++ " " ++ D.bindAs(
                D.placeholder(state.take(path, .{
                    .column = column,
                    .nullable = @typeInfo(op.T) == .optional,
                })),
                row_mod.ColumnType(Row, column),
                false,
            );
        }

        // The same as the one in `condition`, one level down: `.name = .{
        // .icontains = sql.given(search) }` is the shape a search box has
        // (ADR 149). Placed after `nullSafeSpelling`, whose operators already
        // take an optional and mean something else by it.
        if (givenValue(op.T)) |Held| {
            if (nullSafeSpelling(op.name) != null) @compileError(
                "nilo: the condition on `" ++ column ++ "` (as `" ++ op.name ++
                    "`) was given a `sql.given`.\n" ++
                    "  `" ++ op.name ++ "` already takes an optional and treats null as an " ++
                    "ordinary value, so it is one statement either way — there is no term " ++
                    "for `sql.given` to drop.\n" ++
                    "  Write `." ++ column ++ " = .{ ." ++ op.name ++ " = maybe }`.",
            );
            // A list is no exception (ADR 149). A filter bar's multi-select
            // asks two questions: absent is *no filter*, and a list is *these*.
            // An empty list keeps meaning what `.in` says it means, and null
            // drops the term the way it does for one value.
            const n = state.next;
            const was = state.dropping;
            state.dropping = true;
            // `operator` builds the path from `prefix` itself, and `take`
            // appends the wrapper's own field — so the value is read at
            // `.where.<column>.<operator>.value`.
            const term = operator(D, Row, column, quoted, .{
                .name = op.name,
                .T = Held,
            }, prefix, state);
            state.dropping = was;
            if (state.in_group) return term;
            return guarded(D, term, n);
        }

        assertNotOptional(column, op.name, op.T);

        // A pattern, whose text is assembled and escaped by the statement
        // rather than by this side — so the parameter is the caller's own
        // text and nothing here allocates (`dialect.pattern`).
        if (patternSpelling(op.name)) |pat| {
            assertTextPattern(Row, column, op.name, op.T);
            const bound = D.bindAs(
                D.placeholder(state.take(path, .{ .column = column })),
                row_mod.ColumnType(Row, column),
                false,
            );
            return D.pattern(quoted, bound, pat.shape, pat.fold, pat.negate) orelse
                dialect_mod.noPatternForm(D, column, op.name, pat.folding);
        }

        // Both sides folded the way the index over the column was, so the
        // lookup a `.unique` that ignores case exists for can use it.
        if (foldedSpelling(op.name)) |negate| {
            assertTextPattern(Row, column, op.name, op.T);
            const bound = D.bindAs(
                D.placeholder(state.take(path, .{ .column = column })),
                row_mod.ColumnType(Row, column),
                false,
            );
            return D.foldedColumn(quoted) ++ (if (negate) " <> " else " = ") ++ D.foldedColumn(bound);
        }

        if (listSpelling(op.name)) |list_op| {
            // Taken once, outside the switch: the counter is what numbers
            // every placeholder in the statement, and a branch that took it
            // twice or not at all would renumber everything after it.
            const bound = D.bindAs(
                D.placeholder(state.take(path, .{ .column = column, .list = true })),
                row_mod.ColumnType(Row, column),
                true,
            );
            return switch (D.list_form) {
                .any_array => quoted ++ switch (list_op) {
                    .in => " = ANY(",
                    .not_in => " <> ALL(",
                } ++ bound ++ ")",
                // The list arrives as one JSON array and the statement takes
                // it apart, which is how a database with no array type keeps
                // the text a constant.
                .json_each => quoted ++ switch (list_op) {
                    .in => " IN ",
                    .not_in => " NOT IN ",
                } ++ "(SELECT value FROM json_each(" ++ bound ++ "))",
                // Expanding the list into one placeholder each would make the
                // statement depend on a length only known at runtime, which is
                // the half of ADR 036's rule this module exists to keep.
                .expanded, .unsupported => dialect_mod.noListForm(D, column),
            };
        }

        // `ILIKE` is Postgres's word for what SQLite's `LIKE` already does, so
        // on a Dialect whose `LIKE` folds the folding spelling drops the `I` —
        // the same swap `dialect.SQLite.pattern` makes for `icontains`
        // (ADR 055). The table below predates the second Dialect and wrote
        // `ILIKE` on both, which compiled and came back a syntax error.
        //
        // And the case-sensitive pair is the Refusal `contains` already is
        // there: `.like` on SQLite compiled and folded, matching more than
        // it was asked to on one database only, which is the lie the seam
        // exists not to tell (ADR 055). The message names `ilike`, which
        // is what that database was doing all along.
        const spelled = if (D.like_folds and std.mem.eql(u8, op.name, "ilike"))
            "LIKE"
        else if (D.like_folds and std.mem.eql(u8, op.name, "not_ilike"))
            "NOT LIKE"
        else if (D.like_folds and std.mem.eql(u8, op.name, "like"))
            dialect_mod.noPatternForm(D, column, "like", "ilike")
        else if (D.like_folds and std.mem.eql(u8, op.name, "not_like"))
            dialect_mod.noPatternForm(D, column, "not_like", "not_ilike")
        else
            spelling(op.name).?;

        // `.ne = null` is `IS NOT NULL`, for the same reason `= null` is
        // `IS NULL`: `<> NULL` is never true either.
        if (@typeInfo(op.T) == .null) {
            if (std.mem.eql(u8, op.name, "ne")) return quoted ++ " IS NOT NULL";
            @compileError(
                "nilo: `" ++ op.name ++ "` was given null on column `" ++ column ++ "`.\n" ++
                    "  Comparing with null is never true in SQL. `.col = null` asks " ++
                    "for IS NULL and `.col = .{ .ne = null }` for IS NOT NULL; nothing " ++
                    "else has a meaning.",
            );
        }

        return quoted ++ " " ++ spelled ++ " " ++ D.bindAs(
            D.placeholder(state.take(path, .{ .column = column })),
            row_mod.ColumnType(Row, column),
            false,
        );
    }
}

/// An optional in a condition is a Refusal, and it is ADR 036's own rule
/// rather than a taste: **the shape of a query is settled while compiling.**
///
/// `.handle = null` written as a literal is `IS NULL`, because the compiler
/// can see the null. `.handle = maybe`, with `maybe` a `?[]const u8`, cannot
/// be read the same way — whether the statement should say `= $1` or
/// `IS NULL` would depend on a value that arrives at run time, and the
/// statement is a constant by then. Sending `= $1` with NULL in it is legal
/// SQL and never true, so the query runs, answers nothing, and reports no
/// error at all. That is the same failure `compared_with_null` already
/// refuses for `.{ .gt = null }`, reached by the other road.
///
/// The two ways out were: refuse, or read an optional as `IS NULL` when it
/// happens to be null. The second is one statement whose meaning changes with
/// its parameter, which is the property this whole module exists not to have.
///
/// **There is a third way now, and it is SQL's own** (`nullSafeSpelling`).
/// `IS NOT DISTINCT FROM` compares null-safely, so its statement reads the
/// same whether the value turns out to be null or not — nothing is left until
/// run time and the rule is kept rather than bent. An optional reaches that
/// operator and no other, and the message below says so, because "branch"
/// was the whole answer for a case where SQL has a one-liner.
fn assertNotOptional(
    comptime column: []const u8,
    comptime op: ?[]const u8,
    comptime T: type,
) void {
    comptime {
        if (@typeInfo(T) != .optional) return;
        const named = if (op) |name| " (as `" ++ name ++ "`)" else "";
        @compileError(
            "nilo: the condition on `" ++ column ++ "`" ++ named ++ " was given a " ++
                @typeName(T) ++ ".\n" ++
                "  Which SQL that is — `= $1` or `IS NULL` — is shape, and shape is " ++
                "settled while compiling. An optional only answers at run time, and a " ++
                "null one sends `= NULL`, which is never true in SQL: the query runs, " ++
                "matches nothing, and says nothing.\n" ++
                "  `." ++ column ++ " = .{ .not_distinct_from = maybe }` is one statement " ++
                "that means what you want — it is `=` with null treated as a value. " ++
                "Or branch: `if (maybe) |value| … else …`, with `." ++ column ++
                " = null` on the null side.",
        );
    }
}

/// A Row cannot have a column named `any`, `exists`, `not_exists` or
/// `across`, because each already means something inside a condition and one
/// word cannot be both.
fn assertNoReservedColumn(comptime Row: type) void {
    comptime {
        for (reserved) |word| {
            if (!row_mod.hasColumn(Row, word)) continue;
            const means = if (std.mem.eql(u8, word, any_field))
                "OR"
            else if (std.mem.eql(u8, word, across_field))
                "one condition over several columns"
            else
                "a matching row in another table";
            @compileError(
                "nilo: " ++ @typeName(Row) ++ " has a column named `" ++ word ++
                    "`, which is the word a condition uses for " ++ means ++ ".\n" ++
                    "  Read it under another name in the Row and reach the column " ++
                    "itself with `db.raw`.",
            );
        }
    }
}

// -- tests ---------------------------------------------------------------

const testing = std.testing;
const Pg = dialect_mod.Postgres;

const User = struct {
    pub const nilo_table = .{ .name = "users", .key = .id };

    id: i64,
    email: []const u8,
    age: i32,
    deleted_at: ?i64,
    role: []const u8,
};

fn sqlOf(comptime w: anytype) []const u8 {
    return comptime plan(Pg, User, @TypeOf(w), 1).sql;
}

test "one column and one value is an equality" {
    try testing.expectEqualStrings("\"id\" = $1", sqlOf(.{ .id = 7 }));
}

test "different columns are ANDed, and numbered in the order they are written" {
    try testing.expectEqualStrings(
        "\"age\" > $1 AND \"email\" = $2",
        sqlOf(.{ .age = .{ .gt = 18 }, .email = "a@b.com" }),
    );
}

test "two operators on one column are ANDed, so a range needs no new idea" {
    try testing.expectEqualStrings(
        "\"age\" > $1 AND \"age\" < $2",
        sqlOf(.{ .age = .{ .gt = 18, .lt = 65 } }),
    );
}

test "a contains builds its pattern in the statement, and escapes what it wraps" {
    // The three `replace` calls are the feature. Without them a search term
    // holding `%` matches far more than it should, and one holding `_` matches
    // a character it should not — quietly, on the input nobody tried.
    try testing.expectEqualStrings(
        "\"email\" LIKE '%' || replace(replace(replace($1, '\\', '\\\\')," ++
            " '%', '\\%'), '_', '\\_') || '%' ESCAPE '\\'",
        sqlOf(.{ .email = .{ .contains = @as([]const u8, "a") } }),
    );
}

test "the escape character is doubled first, or the escaping escapes itself" {
    // Order is not style here. Doubling `\` after putting one in front of `%`
    // would turn the escape into a literal backslash and let the `%` through.
    const written = sqlOf(.{ .email = .{ .contains = @as([]const u8, "a") } });
    const doubles = std.mem.indexOf(u8, written, "'\\', '\\\\'").?;
    const percents = std.mem.indexOf(u8, written, "'%', '\\%'").?;
    try testing.expect(doubles < percents);
}

test "starts_with anchors the front, ends_with the back" {
    try testing.expect(std.mem.endsWith(
        u8,
        sqlOf(.{ .email = .{ .starts_with = @as([]const u8, "a") } }),
        "'\\_') || '%' ESCAPE '\\'",
    ));
    try testing.expect(std.mem.indexOf(
        u8,
        sqlOf(.{ .email = .{ .ends_with = @as([]const u8, "a") } }),
        "LIKE '%' || replace",
    ) != null);
    // And the anchored end carries no `%` of its own, which is the whole
    // difference between the two.
    try testing.expect(std.mem.endsWith(
        u8,
        sqlOf(.{ .email = .{ .ends_with = @as([]const u8, "a") } }),
        "'\\_') ESCAPE '\\'",
    ));
}

test "the folding spelling is ILIKE and the negation is NOT, on the same expression" {
    try testing.expect(std.mem.indexOf(
        u8,
        sqlOf(.{ .email = .{ .icontains = @as([]const u8, "a") } }),
        "\"email\" ILIKE '%'",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        sqlOf(.{ .email = .{ .not_contains = @as([]const u8, "a") } }),
        "\"email\" NOT LIKE '%'",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        sqlOf(.{ .email = .{ .not_icontains = @as([]const u8, "a") } }),
        "\"email\" NOT ILIKE '%'",
    ) != null);
}

test "every leaf still has a negation, which is what keeps the algebra closed" {
    // ADR 052's argument that `EXCEPT` needs no mechanism rests on this, so
    // an operator family arriving without its negations would quietly break a
    // decision that is on the record.
    inline for (.{
        "contains",      "starts_with",      "ends_with",
        "icontains",     "istarts_with",     "iends_with",
        "not_contains",  "not_starts_with",  "not_ends_with",
        "not_icontains", "not_istarts_with", "not_iends_with",
    }) |name| {
        try testing.expect(comptime patternSpelling(name) != null);
    }
}

test "one parameter per pattern, holding the caller's own text and nothing built" {
    const p = comptime plan(Pg, User, @TypeOf(.{
        .email = .{ .contains = @as([]const u8, "a") },
    }), 1);
    try testing.expectEqual(@as(usize, 1), p.paths.len);
    try testing.expectEqualStrings("email", p.params[0].column);
    // Not a list and not nullable: it binds exactly as an `=` on the same
    // column would, which is why this family needed no change in `db.zig`.
    try testing.expect(!p.params[0].list);
    try testing.expect(!p.params[0].nullable);
}

test "sqlite writes LIKE where postgres writes ILIKE, because that is what its LIKE is" {
    const Lite = dialect_mod.SQLite;
    const written = comptime plan(Lite, User, @TypeOf(.{
        .email = .{ .icontains = @as([]const u8, "a") },
    }), 1).sql;
    try testing.expect(std.mem.indexOf(u8, written, "\"email\" LIKE '%'") != null);
    try testing.expect(std.mem.indexOf(u8, written, "ILIKE") == null);
    // And the escaping survives the swap, which is the half that would be easy
    // to lose in a string splice.
    try testing.expect(std.mem.endsWith(u8, written, "ESCAPE '\\'"));
}

test "ilike on sqlite is spelled LIKE, and not_ilike NOT LIKE, for the same reason" {
    // The pattern operators went through the Dialect from the day they were
    // written; `.ilike` predates the second Dialect and wrote `ILIKE` on both,
    // which SQLite refused at run time. Nothing could depend on that.
    const Lite = dialect_mod.SQLite;
    try testing.expectEqualStrings(
        "\"email\" LIKE ?1",
        comptime plan(Lite, User, @TypeOf(.{ .email = .{ .ilike = @as([]const u8, "%@b.com") } }), 1).sql,
    );
    try testing.expectEqualStrings(
        "\"email\" NOT LIKE ?1",
        comptime plan(Lite, User, @TypeOf(.{ .email = .{ .not_ilike = @as([]const u8, "%@b.com") } }), 1).sql,
    );
    // And Postgres keeps its own word.
    try testing.expectEqualStrings("\"email\" ILIKE $1", sqlOf(.{ .email = .{ .ilike = "%@B.com" } }));
}

test "ieq folds both sides the way a unique that ignores case was built, on both databases" {
    // `lower(…)` is the expression the Postgres index is over, so a lookup
    // written this way is one the index serves; `= $1` would not be.
    try testing.expectEqualStrings(
        "lower(\"email\") = lower($1)",
        sqlOf(.{ .email = .{ .ieq = @as([]const u8, "Ana@Example.com") } }),
    );
    try testing.expectEqualStrings(
        "lower(\"email\") <> lower($1)",
        sqlOf(.{ .email = .{ .not_ieq = @as([]const u8, "Ana@Example.com") } }),
    );
    const Lite = dialect_mod.SQLite;
    try testing.expectEqualStrings(
        "\"email\" COLLATE NOCASE = ?1 COLLATE NOCASE",
        comptime plan(Lite, User, @TypeOf(.{ .email = .{ .ieq = @as([]const u8, "a") } }), 1).sql,
    );
    // It takes a `sql.given` the way a pattern does: the lookup box that may
    // be empty.
    try testing.expectEqualStrings(
        "(lower(\"email\") = lower($1) OR $1 IS NULL)",
        sqlOf(.{ .email = .{ .ieq = given(@as(?[]const u8, null)) } }),
    );
    // An underscore is a character here, not the wildcard `.ilike` would read.
    try testing.expect(!filtersNothing(.{ .email = .{ .ieq = @as([]const u8, "") } }));
}

// -- a row over there ----------------------------------------------------

const Partner = struct {
    pub const nilo_table = .{ .name = "partners", .key = .id };

    id: i64,
    name: []const u8,
};

const Capability = struct {
    pub const nilo_table = .{
        .name = "partner_capabilities",
        .key = .{ .partner_id, .capability },
        .references = .{ .partner_id = .{ Partner, .id } },
    };

    partner_id: i64,
    capability: []const u8,
};

fn partnerSql(comptime w: anytype) []const u8 {
    return comptime plan(Pg, Partner, @TypeOf(w), 1).sql;
}

/// The other direction: a Row that points at the one an `.exists` is over.
const Department = struct {
    pub const nilo_table = .{ .name = "departments", .key = .id };

    id: i64,
    name: []const u8,
};

const Region = struct {
    pub const nilo_table = .{ .name = "regions", .key = .id };

    id: i64,
    name: []const u8,
};

const Staff = struct {
    pub const nilo_table = .{
        .name = "staff",
        .key = .id,
        .references = .{
            .department_id = .{ Department, .id },
            .home_region = .{ Region, .id },
            .work_region = .{ Region, .id },
        },
    };

    id: i64,
    department_id: i64,
    home_region: i64,
    work_region: i64,
    team_id: i64,
};

fn staffSql(comptime w: anytype) []const u8 {
    return comptime plan(Pg, Staff, @TypeOf(w), 1).sql;
}

test "an exists joins on the reference the child already declared" {
    try testing.expectEqualStrings(
        "EXISTS (SELECT 1 FROM \"partner_capabilities\"" ++
            " WHERE \"partner_capabilities\".\"partner_id\" = \"partners\".\"id\"" ++
            " AND \"partner_capabilities\".\"capability\" = $1)",
        partnerSql(.{ .exists = .{
            .{ .in = Capability, .where = .{ .capability = @as([]const u8, "vision") } },
        } }),
    );
}

const Epic = struct {
    pub const nilo_table = .{ .name = "work_epics", .key = .{ .id, .department_id } };

    id: i64,
    department_id: i64,
    title: []const u8,
};

const WorkItem = struct {
    pub const nilo_table = .{
        .name = "work_items",
        .key = .id,
        .references = .{
            .epic = .{
                .columns = .{ .epic_id, .department_id },
                .to = .{ Epic, .{ .id, .department_id } },
            },
        },
    };

    id: i64,
    epic_id: i64,
    department_id: i64,
    state: []const u8,
};

test "an exists over a foreign key of two columns joins on both of them" {
    // **Joining on the first column alone would run, read correctly and answer
    // a wider question**: every item whose epic id matches, on any board. The
    // schema said the pair, so the subquery says the pair (ADR 181).
    try testing.expectEqualStrings(
        "EXISTS (SELECT 1 FROM \"work_items\"" ++
            " WHERE \"work_items\".\"epic_id\" = \"work_epics\".\"id\"" ++
            " AND \"work_items\".\"department_id\" = \"work_epics\".\"department_id\"" ++
            " AND \"work_items\".\"state\" = $1)",
        comptime plan(Pg, Epic, @TypeOf(.{ .exists = .{
            .{ .in = WorkItem, .where = .{ .state = @as([]const u8, "open") } },
        } }), 1).sql,
    );
}

test "every column inside the subquery is qualified, or a shared name is ambiguous" {
    // `partner_capabilities` and `partners` both have a column the other
    // could have. Unqualified, the database picks one and does not say which.
    const written = partnerSql(.{ .exists = .{
        .{ .in = Capability, .where = .{ .capability = @as([]const u8, "vision") } },
    } });
    try testing.expect(std.mem.indexOf(u8, written, " \"capability\" = ") == null);
    try testing.expect(std.mem.indexOf(
        u8,
        written,
        "\"partner_capabilities\".\"capability\" = $1",
    ) != null);
}

test "the parameter inside an exists is typed against the other Row" {
    const p = comptime plan(Pg, Partner, @TypeOf(.{ .exists = .{
        .{ .in = Capability, .where = .{ .capability = @as([]const u8, "vision") } },
    } }), 1);
    try testing.expectEqual(@as(usize, 1), p.params.len);
    try testing.expectEqualStrings("capability", p.params[0].column);
    // Without this the type would be looked up on `Partner`, which has no
    // `capability` at all — so the mistake would be a Refusal here and a
    // wrongly-bound value on a Row that happened to share the name.
    try testing.expectEqual(Capability, p.params[0].of.?);
}

test "an exists numbers its placeholders in the one walk, beside the outer ones" {
    const p = comptime plan(Pg, Partner, @TypeOf(.{
        .name = @as([]const u8, "acme"),
        .exists = .{
            .{ .in = Capability, .where = .{ .capability = @as([]const u8, "vision") } },
        },
    }), 1);
    try testing.expectEqual(@as(usize, 2), p.params.len);
    try testing.expect(std.mem.indexOf(u8, p.sql, "\"name\" = $1") != null);
    try testing.expect(std.mem.indexOf(u8, p.sql, "\"capability\" = $2") != null);
    // And the outer parameter is still the outer Row's.
    try testing.expectEqual(@as(?type, null), p.params[0].of);
}

test "the walk goes back to the outer Row after a subquery, not on to the next one" {
    // Two tests side by side is the shape a filter page with two facets has,
    // and getting the restore wrong would walk the second against the first's
    // Row without ever failing to compile.
    const written = partnerSql(.{
        .exists = .{
            .{ .in = Capability, .where = .{ .capability = @as([]const u8, "a") } },
            .{ .in = Capability, .where = .{ .capability = @as([]const u8, "b") } },
        },
        .name = @as([]const u8, "acme"),
    });
    try testing.expect(std.mem.indexOf(u8, written, "\"capability\" = $1) AND EXISTS") != null);
    // Unqualified, which is the outer walk's own spelling — the qualifier is
    // put back when the subquery ends, so a statement with an `.exists` in it
    // writes its own columns exactly as it did before one existed.
    try testing.expect(std.mem.endsWith(u8, written, "AND \"name\" = $3"));
}

test "not_exists is the same subquery with two words in front" {
    try testing.expect(std.mem.startsWith(
        u8,
        partnerSql(.{ .not_exists = .{
            .{ .in = Capability, .where = .{ .capability = @as([]const u8, "vision") } },
        } }),
        "NOT EXISTS (SELECT 1 FROM \"partner_capabilities\"",
    ));
}

test "an exists nests inside any, because it is a condition like any other" {
    // ADR 052's closure argument needs this: a leaf that cannot go inside
    // `.any` is a leaf the OR half of the algebra cannot reach.
    const written = partnerSql(.{ .any = .{
        .{ .name = @as([]const u8, "acme") },
        .{ .exists = .{
            .{ .in = Capability, .where = .{ .capability = @as([]const u8, "vision") } },
        } },
    } });
    try testing.expect(std.mem.indexOf(u8, written, " OR EXISTS (SELECT 1") != null);
}

test "an explicit on wins where the schema declares nothing" {
    const Loose = struct {
        pub const nilo_table = .{ .name = "notes", .key = .id };
        id: i64,
        partner_id: i64,
        body: []const u8,
    };
    try testing.expect(std.mem.indexOf(
        u8,
        partnerSql(.{ .exists = .{
            .{ .in = Loose, .on = .partner_id, .where = .{ .body = @as([]const u8, "x") } },
        } }),
        "\"notes\".\"partner_id\" = \"partners\".\"id\"",
    ) != null);
}

test "an exists reads the reference from the outer Row too, so a child can ask about its parent" {
    // Item 75 of the port: `staff WHERE EXISTS (department WHERE name …)`.
    // The key is `staff.department_id`, declared on the *outer* Row, and the
    // subquery correlates `departments.id = staff.department_id` (ADR 175).
    try testing.expectEqualStrings(
        "EXISTS (SELECT 1 FROM \"departments\"" ++
            " WHERE \"departments\".\"id\" = \"staff\".\"department_id\"" ++
            " AND \"departments\".\"name\" = $1)",
        staffSql(.{ .exists = .{
            .{ .in = Department, .where = .{ .name = @as([]const u8, "vision") } },
        } }),
    );
    // And the parameter is typed against the parent, the way a child's is.
    const p = comptime plan(Pg, Staff, @TypeOf(.{ .exists = .{
        .{ .in = Department, .where = .{ .name = @as([]const u8, "vision") } },
    } }), 1);
    try testing.expectEqual(Department, p.params[0].of.?);
}

test "via names the outer column, so two references at the same parent are told apart" {
    // `.on` is a column of the inner Row and `.via` a column of the outer one:
    // the two directions cannot be read as each other by mistake.
    try testing.expect(std.mem.indexOf(
        u8,
        staffSql(.{ .exists = .{
            .{ .in = Region, .via = .home_region, .where = .{ .name = @as([]const u8, "west") } },
        } }),
        "\"regions\".\"id\" = \"staff\".\"home_region\"",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        staffSql(.{ .exists = .{
            .{ .in = Region, .via = .work_region, .where = .{ .name = @as([]const u8, "west") } },
        } }),
        "\"regions\".\"id\" = \"staff\".\"work_region\"",
    ) != null);
}

test "an explicit via joins to the inner key where the schema declares nothing" {
    const Team = struct {
        pub const nilo_table = .{ .name = "teams", .key = .id };
        id: i64,
        name: []const u8,
    };
    try testing.expect(std.mem.indexOf(
        u8,
        staffSql(.{ .exists = .{
            .{ .in = Team, .via = .team_id, .where = .{ .name = @as([]const u8, "x") } },
        } }),
        "\"teams\".\"id\" = \"staff\".\"team_id\"",
    ) != null);
}

test "null means IS NULL, because = NULL is never true" {
    try testing.expectEqualStrings("\"deleted_at\" IS NULL", sqlOf(.{ .deleted_at = null }));
}

test "the other side of that is IS NOT NULL" {
    try testing.expectEqualStrings(
        "\"deleted_at\" IS NOT NULL",
        sqlOf(.{ .deleted_at = .{ .ne = null } }),
    );
}

test "a column that may be null still takes a value that is not" {
    // The Refusal `assertNotOptional` carries is about the type of the value
    // *written*, never the column's: `deleted_at` is a `?i64` in the Row, and
    // comparing it against a plain `i64` is an ordinary condition. This is
    // also what each side of the branch it asks for produces.
    try testing.expectEqualStrings("\"deleted_at\" = $1", sqlOf(.{ .deleted_at = @as(i64, 5) }));
}

test "in becomes = ANY on postgres, so the statement stays one constant" {
    const ids = [_]i64{ 1, 2, 3 };
    try testing.expectEqualStrings("\"id\" = ANY($1)", sqlOf(.{ .id = .{ .in = &ids } }));

    // The whole point: a longer list is the same SQL and the same parameter
    // count. Expanding into placeholders would make both depend on the list.
    const longer = [_]i64{ 1, 2, 3, 4, 5, 6, 7 };
    try testing.expectEqualStrings("\"id\" = ANY($1)", sqlOf(.{ .id = .{ .in = &longer } }));
    try testing.expectEqual(@as(usize, 1), paramCount(Pg, User, @TypeOf(.{ .id = .{ .in = &longer } })));
}

test "every comparison has a spelling" {
    try testing.expectEqualStrings("\"age\" <> $1", sqlOf(.{ .age = .{ .ne = 1 } }));
    try testing.expectEqualStrings("\"age\" >= $1", sqlOf(.{ .age = .{ .gte = 1 } }));
    try testing.expectEqualStrings("\"age\" <= $1", sqlOf(.{ .age = .{ .lte = 1 } }));
    try testing.expectEqualStrings("\"email\" LIKE $1", sqlOf(.{ .email = .{ .like = "%@b.com" } }));
    try testing.expectEqualStrings("\"email\" ILIKE $1", sqlOf(.{ .email = .{ .ilike = "%@B.com" } }));
}

test "every comparison that has a spelling has the negation of it too" {
    // `ne` was the only negation there was, so `not in` — which is as common
    // as `in` — meant either a second query or `db.raw`.
    try testing.expectEqualStrings(
        "\"email\" NOT LIKE $1",
        sqlOf(.{ .email = .{ .not_like = "%@spam.example" } }),
    );
    try testing.expectEqualStrings(
        "\"email\" NOT ILIKE $1",
        sqlOf(.{ .email = .{ .not_ilike = "%@SPAM.example" } }),
    );
}

test "not in is one placeholder too, so a longer list is the same statement" {
    const ids = [_]i64{ 1, 2, 3 };
    try testing.expectEqualStrings("\"id\" <> ALL($1)", sqlOf(.{ .id = .{ .not_in = &ids } }));

    // `<> ALL` rather than `NOT (… = ANY(…))`: the same question asked of
    // every element, and the same shape as `in`, so the property that makes
    // `in` a constant survives the negation.
    const longer = [_]i64{ 1, 2, 3, 4, 5, 6, 7 };
    try testing.expectEqualStrings("\"id\" <> ALL($1)", sqlOf(.{ .id = .{ .not_in = &longer } }));
    try testing.expectEqual(
        @as(usize, 1),
        paramCount(Pg, User, @TypeOf(.{ .id = .{ .not_in = &longer } })),
    );
}

test "distinct_from is the one operator an optional may reach" {
    // The statement is the same six words whether the value turns out to be
    // null or not, which is exactly why the optional is allowed here and
    // nowhere else: nothing about the shape is left until run time.
    const maybe = @as(?i64, null);
    try testing.expectEqualStrings(
        "\"deleted_at\" IS NOT DISTINCT FROM $1",
        sqlOf(.{ .deleted_at = .{ .not_distinct_from = maybe } }),
    );
    try testing.expectEqualStrings(
        "\"deleted_at\" IS DISTINCT FROM $1",
        sqlOf(.{ .deleted_at = .{ .distinct_from = maybe } }),
    );

    // And the parameter binds as an optional even on a column that is not
    // one, because the comparison is about the value rather than the column.
    const p = comptime plan(Pg, User, @TypeOf(.{ .age = .{ .distinct_from = @as(?i32, 1) } }), 1);
    try testing.expect(p.params[0].nullable);
    try testing.expect(!comptime plan(Pg, User, @TypeOf(.{ .age = .{ .gt = 1 } }), 1).params[0].nullable);
}

test "distinct_from takes a plain value too, and is then an ordinary comparison" {
    try testing.expectEqualStrings(
        "\"age\" IS DISTINCT FROM $1",
        sqlOf(.{ .age = .{ .distinct_from = @as(i32, 30) } }),
    );
    try testing.expect(
        !comptime plan(Pg, User, @TypeOf(.{ .age = .{ .distinct_from = @as(i32, 1) } }), 1).params[0].nullable,
    );
}

test "distinct_from against a written null needs no parameter at all" {
    // `IS DISTINCT FROM NULL` is a keyword on both sides, so there is nothing
    // to bind — the same reason `= null` compiles to `IS NULL`.
    const w = .{ .deleted_at = .{ .distinct_from = null } };
    try testing.expectEqualStrings("\"deleted_at\" IS DISTINCT FROM NULL", sqlOf(w));
    try testing.expectEqual(@as(usize, 0), paramCount(Pg, User, @TypeOf(w)));
}

test "a negation ANDs beside its positive, because it is an operator like any other" {
    try testing.expectEqualStrings(
        "\"email\" LIKE $1 AND \"email\" NOT LIKE $2",
        sqlOf(.{ .email = .{ .like = "%@example.dev", .not_like = "%+test@%" } }),
    );
}

test "any is OR, in brackets, and ANDs with what sits beside it" {
    try testing.expectEqualStrings(
        "\"age\" > $1 AND (\"role\" = $2 OR \"email\" = $3)",
        sqlOf(.{
            .age = .{ .gt = 18 },
            .any = .{
                .{ .role = "admin" },
                .{ .email = "root@b.com" },
            },
        }),
    );
}

test "an alternative inside any may itself be several conditions" {
    try testing.expectEqualStrings(
        "(\"role\" = $1 AND \"age\" > $2 OR \"email\" = $3)",
        sqlOf(.{
            .any = .{
                .{ .role = "admin", .age = .{ .gt = 18 } },
                .{ .email = "root@b.com" },
            },
        }),
    );
}

test "an any nests inside an any, which is what closes the boolean algebra" {
    // The reachability argument in
    // [ADR 052](../docs/adr/052-a-set-operation-over-one-table-is-a-condition.md)
    // rests on this: AND is a struct, OR is `.any`, every leaf has a
    // negation, and De Morgan holds in SQL's three-valued logic — so any
    // boolean combination over one table is writable, `EXCEPT` included.
    // It only holds if `.any` composes with itself, which nothing asserted
    // until now.
    try testing.expectEqualStrings(
        "(\"role\" <> $1 OR (\"age\" < $2 OR \"email\" IS NULL))",
        sqlOf(.{
            .any = .{
                .{ .role = .{ .ne = "admin" } },
                .{ .any = .{
                    .{ .age = .{ .lt = 18 } },
                    .{ .email = null },
                } },
            },
        }),
    );
}

test "an empty condition is an empty fragment, not a WHERE with nothing after it" {
    const p = comptime plan(Pg, User, @TypeOf(.{}), 1);
    try testing.expect(p.isEmpty());
    try testing.expectEqual(@as(usize, 0), p.paths.len);
}

test "placeholders can start from a number a caller has already reached" {
    try testing.expectEqualStrings(
        "\"id\" = $4",
        comptime plan(Pg, User, @TypeOf(.{ .id = 7 }), 4).sql,
    );
}

test "the values come back in placeholder order" {
    const w = .{ .age = .{ .gt = 18, .lt = 65 }, .email = "a@b.com" };
    const p = comptime plan(Pg, User, @TypeOf(w), 1);

    try testing.expectEqual(@as(usize, 3), p.paths.len);
    try testing.expectEqual(@as(i32, 18), valueAt(w, p.paths[0]));
    try testing.expectEqual(@as(i32, 65), valueAt(w, p.paths[1]));
    try testing.expectEqualStrings("a@b.com", valueAt(w, p.paths[2]));
}

test "a value inside any is reached by the same paths" {
    const w = .{ .age = .{ .gt = 18 }, .any = .{ .{ .role = "admin" }, .{ .id = 7 } } };
    const p = comptime plan(Pg, User, @TypeOf(w), 1);

    try testing.expectEqual(@as(usize, 3), p.paths.len);
    try testing.expectEqual(@as(i32, 18), valueAt(w, p.paths[0]));
    try testing.expectEqualStrings("admin", valueAt(w, p.paths[1]));
    try testing.expectEqual(@as(i64, 7), valueAt(w, p.paths[2]));
}

test "a counter walks every value once, which is what a Wire will do" {
    const w = .{ .age = .{ .gt = 18, .lt = 65 }, .id = 7 };
    const p = comptime plan(Pg, User, @TypeOf(w), 1);

    var seen: usize = 0;
    const bump = struct {
        fn f(count: *usize, value: anytype) !void {
            _ = value;
            count.* += 1;
        }
    }.f;
    try each(p, w, &seen, bump);
    try testing.expectEqual(@as(usize, 3), seen);
}

// -- a filter that is absent ---------------------------------------------

/// What `dialect.pattern` wraps `$1` in so a `%` a user typed is a per cent
/// sign rather than a wildcard. Spelled once here because two of the tests
/// below are about the guard around it rather than about the escaping.
const escaped_one = "replace(replace(replace($1, '\\', '\\\\'), '%', '\\%'), '_', '\\_')";

test "a filter that may be absent guards its own term" {
    // Item 54: `.age = maybe` was a Refusal, and the advice it gave — branch —
    // is four arms for two optional filters, each repeating the order, the
    // limit, the offset and the count beside it (ADR 149).
    const p = comptime plan(Pg, User, @TypeOf(.{
        .age = given(@as(?i32, null)),
    }), 1);
    try testing.expectEqualStrings("(\"age\" = $1 OR $1 IS NULL)", p.sql);
    // One parameter, whichever way the filter goes — which is what makes this
    // one statement rather than one per combination of filters.
    try testing.expectEqual(@as(usize, 1), p.paths.len);
    try testing.expect(p.params[0].droppable);
    try testing.expect(p.params[0].nullable);
    // The value is read one field deeper than the condition is written, which
    // is where the wrapper keeps it.
    try testing.expectEqual(@as(usize, 2), p.paths[0].len);
    try testing.expectEqualStrings("age", p.paths[0][0]);
    try testing.expectEqualStrings("value", p.paths[0][1]);
}

test "an operator takes one too, and the fixed terms beside it are untouched" {
    const p = comptime plan(Pg, User, @TypeOf(.{
        .email = .{ .icontains = given(@as(?[]const u8, null)) },
        .age = .{ .gt = @as(i32, 18) },
    }), 1);
    try testing.expectEqualStrings(
        "(\"email\" ILIKE '%' || " ++ escaped_one ++ " || '%' ESCAPE '\\' OR $1 IS NULL)" ++
            " AND \"age\" > $2",
        p.sql,
    );
    try testing.expect(p.params[0].droppable);
    try testing.expect(!p.params[1].droppable);
    try testing.expectEqualStrings("value", p.paths[0][p.paths[0].len - 1]);
}

test "a list that may be absent drops its term, and an empty one still means what in means" {
    // Item 81: a multi-select on a filter bar is absent (*no filter*) or a
    // list (*these*), and the refusal that stood here read the first as the
    // empty list, which `.in` answers with no rows (ADR 149).
    const p = comptime plan(Pg, User, @TypeOf(.{
        .id = .{ .in = given(@as(?[]const i64, null)) },
        .age = .{ .not_in = given(@as(?[]const i32, null)) },
    }), 1);
    try testing.expectEqualStrings(
        "(\"id\" = ANY($1) OR $1 IS NULL) AND (\"age\" <> ALL($2) OR $2 IS NULL)",
        p.sql,
    );
    try testing.expect(p.params[0].list and p.params[0].droppable and p.params[0].nullable);
    try testing.expectEqualStrings("value", p.paths[0][p.paths[0].len - 1]);

    // SQLite reads the list out of one JSON parameter, and `json_each(NULL)`
    // is no rows, which the guard beside it never has to ask about.
    try testing.expectEqualStrings(
        "(\"id\" IN (SELECT value FROM json_each(?1)) OR ?1 IS NULL)",
        comptime plan(dialect_mod.SQLite, User, @TypeOf(.{
            .id = .{ .in = given(@as(?[]const i64, null)) },
        }), 1).sql,
    );
}

test "one condition over several columns is one parameter, and the guard goes around the bracket" {
    // Item 72: a search box over the code, the name and the trademark was two
    // statements, one with the `.any` and one without, with every other
    // `sql.given` filter written twice (ADR 172).
    const p = comptime plan(Pg, User, @TypeOf(.{
        .age = given(@as(?i32, null)),
        .across = .{ .columns = .{ .email, .role }, .icontains = given(@as(?[]const u8, null)) },
    }), 1);
    const escaped_two = "replace(replace(replace($2, '\\', '\\\\'), '%', '\\%'), '_', '\\_')";
    try testing.expectEqualStrings(
        "(\"age\" = $1 OR $1 IS NULL) AND " ++
            "((\"email\" ILIKE '%' || " ++ escaped_two ++ " || '%' ESCAPE '\\'" ++
            " OR \"role\" ILIKE '%' || " ++ escaped_two ++ " || '%' ESCAPE '\\') OR $2 IS NULL)",
        p.sql,
    );
    // Two parameters for three terms: the search is bound once and named
    // twice, so the plan and the parameter list are the same however the
    // screen is set.
    try testing.expectEqual(@as(usize, 2), p.paths.len);
    try testing.expect(p.params[1].droppable);
    try testing.expectEqualStrings("across", p.paths[1][0]);
    try testing.expectEqualStrings("icontains", p.paths[1][1]);
    try testing.expectEqualStrings("value", p.paths[1][2]);

    // A value that is always there is the bracket with no guard, and several
    // operators AND inside each alternative.
    try testing.expectEqualStrings(
        "(\"email\" = $1 OR \"role\" = $1) AND ((\"id\" > $2 AND \"id\" < $3) OR (\"deleted_at\" > $2 AND \"deleted_at\" < $3))",
        sqlOf(.{
            .across = .{
                .{ .columns = .{ .email, .role }, .eq = "x" },
                .{ .columns = .{ .id, .deleted_at }, .gt = @as(i64, 1), .lt = @as(i64, 9) },
            },
        }),
    );
}

test "a filter inside an exists drops the subquery rather than a term of it" {
    // Dropping the term would leave the subquery asking whether any joined row
    // exists at all, which excludes every partner with no capabilities — the
    // opposite of no filter, and it compiles (ADR 149).
    try testing.expectEqualStrings(
        "(EXISTS (SELECT 1 FROM \"partner_capabilities\"" ++
            " WHERE \"partner_capabilities\".\"partner_id\" = \"partners\".\"id\"" ++
            " AND \"partner_capabilities\".\"capability\" = $1) OR $1 IS NULL)",
        partnerSql(.{ .exists = .{
            .{ .in = Capability, .where = .{ .capability = given(@as(?[]const u8, null)) } },
        } }),
    );
}

test "the whole of the reporting product's list endpoint is one statement" {
    // A search box and a dropdown, either of which may be empty, over a
    // partner list. Four arms of `db.select` beside four of `db.count`
    // becomes this.
    const p = comptime plan(Pg, Partner, @TypeOf(.{
        .name = .{ .icontains = given(@as(?[]const u8, null)) },
        .exists = .{
            .{ .in = Capability, .where = .{ .capability = given(@as(?[]const u8, null)) } },
        },
    }), 1);
    try testing.expectEqual(@as(usize, 2), p.paths.len);
    try testing.expectEqualStrings(
        "(\"name\" ILIKE '%' || " ++ escaped_one ++ " || '%' ESCAPE '\\' OR $1 IS NULL)" ++
            " AND (EXISTS (SELECT 1 FROM \"partner_capabilities\"" ++
            " WHERE \"partner_capabilities\".\"partner_id\" = \"partners\".\"id\"" ++
            " AND \"partner_capabilities\".\"capability\" = $2) OR $2 IS NULL)",
        p.sql,
    );
}

test "a condition narrows nothing only when every term it ANDs narrows nothing" {
    const none: []const i64 = &.{};
    const some: []const i64 = &.{ 1, 2 };
    const blank: []const u8 = "";
    const text: []const u8 = "ada";

    // The two ways a request empties a term.
    try testing.expect(filtersNothing(.{ .id = .{ .not_in = none } }));
    try testing.expect(filtersNothing(.{ .name = .{ .icontains = blank } }));
    try testing.expect(filtersNothing(.{ .name = .{ .starts_with = core.Str.static(blank) } }));

    // And the terms that narrow whatever they are handed.
    try testing.expect(!filtersNothing(.{ .id = .{ .not_in = some } }));
    try testing.expect(!filtersNothing(.{ .id = .{ .in = none } }));
    try testing.expect(!filtersNothing(.{ .name = .{ .not_icontains = blank } }));
    try testing.expect(!filtersNothing(.{ .name = .{ .icontains = text } }));
    try testing.expect(!filtersNothing(.{ .id = @as(i64, 7) }));
    try testing.expect(!filtersNothing(.{ .deleted_at = null }));
    try testing.expect(!filtersNothing(.{ .id = .{ .gt = 3 } }));

    // AND: one term that narrows is enough to narrow.
    try testing.expect(!filtersNothing(.{ .tenant = @as(i64, 1), .id = .{ .not_in = none } }));
    // A column's own operators are ANDed the same way.
    try testing.expect(!filtersNothing(.{ .id = .{ .not_in = none, .lt = 10 } }));
    try testing.expect(filtersNothing(.{ .id = .{ .not_in = none }, .name = .{ .icontains = blank } }));

    // OR: one alternative that narrows nothing is enough to narrow nothing.
    try testing.expect(filtersNothing(.{ .any = .{ .{ .id = @as(i64, 1) }, .{ .id = .{ .not_in = none } } } }));
    try testing.expect(!filtersNothing(.{ .any = .{ .{ .id = @as(i64, 1) }, .{ .id = .{ .not_in = some } } } }));

    // `.across` is its operators, once per column, ORed across the columns.
    try testing.expect(filtersNothing(.{ .across = .{ .columns = .{ .code, .name }, .icontains = blank } }));
    try testing.expect(!filtersNothing(.{ .across = .{ .columns = .{ .code, .name }, .icontains = text } }));

    // An `.exists` is judged to narrow, which is the direction to be wrong in.
    try testing.expect(!filtersNothing(.{ .exists = .{ .on = .owner, .where = .{ .id = .{ .not_in = none } } } }));
}

test "a term pins its column only when it is `=` to a value that is always there" {
    try testing.expect(comptime pinsEquality(i64));
    try testing.expect(comptime pinsEquality([]const u8));
    try testing.expect(comptime pinsEquality(struct { eq: i64 }));

    try testing.expect(comptime !pinsEquality(@TypeOf(null)));
    try testing.expect(comptime !pinsEquality(?i64));
    try testing.expect(comptime !pinsEquality(struct { gt: i64 }));
    try testing.expect(comptime !pinsEquality(struct { eq: ?i64 }));
    try testing.expect(comptime !pinsEquality(struct { in: []const i64 }));
    try testing.expect(comptime !pinsEquality(Given(i64)));
}
