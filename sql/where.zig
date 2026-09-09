//! The where walker — a struct of the caller's own turned into a SQL
//! fragment while compiling, and into a list of values at runtime (ADR 0039).
//!
//! ```zig
//! .where = .{ .age = .{ .gt = 18 }, .name = "bob" }
//! ```
//! ```sql
//! "age" > $1 AND "name" = $2
//! ```
//!
//! This is ADR 0039's rule at its narrowest: **which column, which operator
//! and how many parameters are settled here, while compiling. Only the 18 and
//! the "bob" are not.** A column that does not exist is a Refusal naming the
//! near miss; it never becomes a runtime error, because by the time the
//! program runs the question has already been answered.
//!
//! It is the same trick `Query(T)` plays one layer up — ADR 0012's *the query
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
//! Everything past that — joins, aggregates, subqueries, `HAVING` — is
//! `db.raw`. The boundary is one sentence, *one table, conditions that filter
//! rows*, and a boundary that can be stated is worth more than one that is
//! further out: a reader can predict what this does without opening the
//! reference.
//!
//! **A null is written, never held.** `.deleted_at = null` is `IS NULL` and
//! `.{ .ne = null }` is `IS NOT NULL`, because the compiler can see the null.
//! An optional that *might* be null is a Refusal — see `assertNotOptional`,
//! which is ADR 0039's rule at its sharpest.
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

/// The field name that means OR. A Row with a column of this name is refused,
/// because one word cannot mean both.
pub const any_field = "any";

/// The two field names that mean *a row over there matches*, and their
/// negation. Reserved the same way `any` is, and for the same reason.
pub const exists_field = "exists";
pub const not_exists_field = "not_exists";

/// Every word a condition reserves. One list, because `assertNoReservedColumn`
/// and the message it writes both read it and a word allowed in one and
/// refused in the other is the mistake this arrangement exists to prevent.
const reserved = [_][]const u8{ any_field, exists_field, not_exists_field };

/// The names an `.exists` entry may carry.
const exists_known = [_][]const u8{ "in", "on", "where" };

/// A value a condition only has *sometimes* — the term is in the statement
/// when there is one, and out of it when there is not
/// ([ADR 0183](../docs/adr/0183-a-filter-that-is-absent-is-not-a-filter-that-is-null.md)).
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
/// ADR 0044 is why the second could not be spelled: an optional reaching `=`
/// sends `= NULL`, which runs, matches nothing, and says nothing.
///
/// What it compiles to is the guard a hand-written statement uses:
///
/// ```sql
/// ($1::text IS NULL OR "name" ILIKE '%' || $1 || '%')
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

        /// What a nilo compile error calls this type (ADR 0122).
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
    /// (`nullSafeSpelling`, ADR 0183).
    nullable: bool = false,
    /// Whether the term this parameter belongs to disappears when the value
    /// is null — `sql.given`
    /// ([ADR 0183](../docs/adr/0183-a-filter-that-is-absent-is-not-a-filter-that-is-null.md)).
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
    /// whatever its column is (ADR 0183).
    ///
    /// **On the State for the same reason the qualifier is**: the path and the
    /// two flags have to move together, and there is one walk.
    dropping: bool = false,
    /// Set while the walk is inside an `.exists`, where a `given` drops the
    /// whole subquery rather than one term of it — so the term writes no guard
    /// of its own and `oneExists` writes one around the lot.
    in_group: bool = false,

    fn take(self: *State, comptime path: Path, comptime param: Param) usize {
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
        // has to remember to set them (ADR 0183).
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
        for (info.fields, 0..) |f, i| {
            if (i > 0) out = out ++ " AND ";
            const path = prefix ++ &[_][]const u8{f.name};
            if (std.mem.eql(u8, f.name, any_field)) {
                out = out ++ anyOf(D, Row, f.type, path, state);
                continue;
            }
            if (std.mem.eql(u8, f.name, exists_field)) {
                out = out ++ existsOf(D, Row, f.type, path, state, false);
                continue;
            }
            if (std.mem.eql(u8, f.name, not_exists_field)) {
                out = out ++ existsOf(D, Row, f.type, path, state, true);
                continue;
            }
            if (!row_mod.hasColumn(Row, f.name)) {
                row_mod.noSuchColumn(Row, f.name, "a condition");
            }
            out = out ++ condition(D, Row, f.name, f.type, path, state);
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
            const sub = walk(D, Row, f.type, path ++ &[_][]const u8{f.name}, state);
            // **`.any` is OR, and that reverses what dropping a term means**
            // (ADR 0183). Everywhere else a term that is not there widens the
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

/// One column against one value or one set of operators.
/// `.exists = .{ .{ .in = Child, .where = .{ … } }, … }` — one `EXISTS`
/// subquery per entry, ANDed, and `.not_exists` for `NOT EXISTS`.
///
/// **This is the one place the line past *one table* moves, and it moves for a
/// reason that names itself** ([ADR 0171](../docs/adr/0171-a-row-over-there-is-a-condition.md)).
/// An `EXISTS` does not change the column list and does not change the row
/// count: the answer is still rows of this Row, one per matching row, so
/// `.limit` still means what the caller thinks it means. A join changes both,
/// and that is what is still refused — the boundary did not blur, it moved to
/// where those two properties actually hold.
///
/// **The correlation is read out of the child's own `.references`**, which is
/// already checked harder than anything else in this repository:
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
            "when the two tables are joined by a column no `.references` names.";

        if (@typeInfo(T) != .@"struct" or @typeInfo(T).@"struct".is_tuple) @compileError(
            "nilo: an entry of `." ++ word ++ "` is a " ++ @typeName(T) ++ ".\n" ++ shape,
        );
        for (@typeInfo(T).@"struct".fields) |f| {
            for (exists_known) |ok| {
                if (std.mem.eql(u8, f.name, ok)) break;
            } else @compileError(
                "nilo: an entry of `." ++ word ++ "` sets `." ++ f.name ++
                    "`, which is not part of it.\n" ++
                    "  It takes `.in`, `.where`, and `.on` when the join column is not " ++
                    "one a `.references` already names.",
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

        const link = correlation(Outer, Inner, T, word);

        const outer_rel = relationOf(D, Outer);
        const inner_rel = relationOf(D, Inner);
        if (std.mem.eql(u8, outer_rel, inner_rel)) @compileError(
            "nilo: `." ++ word ++ "` names " ++ @typeName(Inner) ++ ", which reads the same " ++
                "table as " ++ @typeName(Outer) ++ ".\n" ++
                "  Both sides would be written as " ++ inner_rel ++ ", so every column in " ++
                "the subquery would be ambiguous. A test against the same table needs an " ++
                "alias, which is `db.raw`.",
        );

        // The walk inside the subquery names the other table and the other
        // Row. Saved and put back, so a second entry beside this one is walked
        // against the outer Row again.
        const was_qualifier = state.qualifier;
        const was_inner = state.inner;
        const was_group = state.in_group;
        const before = state.count;
        const guard = state.next;
        state.qualifier = inner_rel ++ ".";
        state.inner = Inner;
        // A `given` in here drops the whole subquery rather than one term of
        // it, so the terms write no guards of their own (ADR 0183).
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

        // **A `given` inside an `.exists` is the whole test, or it is a
        // Refusal** (ADR 0183). Dropping one term of the subquery would leave
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

        const test_sql = (if (negate) "NOT EXISTS (SELECT 1 FROM " else "EXISTS (SELECT 1 FROM ") ++
            inner_rel ++ " WHERE " ++
            inner_rel ++ "." ++ D.quote(link.inner) ++ " = " ++
            outer_rel ++ "." ++ D.quote(link.outer) ++
            " AND " ++ inside ++ ")";
        if (droppable == 0) return test_sql;
        // The guard the terms inside did not write, around the whole test.
        // Nested inside another `.exists` it belongs to that one instead, and
        // the outer walk is what writes it.
        if (was_group) return test_sql;
        return "(" ++ D.placeholder(guard) ++ " IS NULL OR " ++ test_sql ++ ")";
    }
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

/// Which column of each side the two tables are joined by.
const Link = struct {
    inner: []const u8,
    outer: []const u8,
};

/// The join, taken from the child's `.references` — or from `.on` plus the
/// outer Row's key when the schema does not declare one.
///
/// **Zero matches and two matches are both Refusals**, and they are different
/// mistakes: nothing to join on is a schema that has not said how the tables
/// relate, and two ways to join is a schema that has said it twice — a table
/// with `.created_by` and `.updated_by` both pointing at `staff` is the
/// ordinary shape of the second, and guessing between them would be a query
/// that reads correctly and answers the wrong question.
fn correlation(
    comptime Outer: type,
    comptime Inner: type,
    comptime T: type,
    comptime word: []const u8,
) Link {
    comptime {
        const outer_q = row_mod.qualifiedOf(Outer);
        var found: []const Link = &.{};
        var named: []const u8 = "";

        for (table_mod.foreignKeysOf(Inner)) |ref| {
            if (!std.mem.eql(u8, ref.table, outer_q.table)) continue;
            if (!table_mod.sameSchema(ref.schema, outer_q.schema)) continue;
            named = named ++ (if (found.len == 0) "" else ", ") ++ "`" ++ ref.column ++ "`";
            found = found ++ &[_]Link{.{ .inner = ref.column, .outer = ref.target }};
        }

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
            // assuming the key.
            for (found) |link| {
                if (std.mem.eql(u8, link.inner, wanted)) return link;
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
            return .{ .inner = wanted, .outer = outer_keys[0] };
        }

        if (found.len == 0) @compileError(
            "nilo: `." ++ word ++ "` names " ++ @typeName(Inner) ++ ", which declares no " ++
                "`.references` to " ++ @typeName(Outer) ++ "'s table `" ++ outer_q.table ++
                "`.\n" ++
                "  The join is read out of the schema rather than written at the call site, " ++
                "so there has to be one. Add `.references = .{ .<column> = .{ " ++
                @typeName(Outer) ++ ", .<column> } }` to " ++ @typeName(Inner) ++ "'s " ++
                row_mod.marker ++ ", or say which column joins with `.on = .<column>`.",
        );
        if (found.len > 1) @compileError(
            "nilo: `." ++ word ++ "` names " ++ @typeName(Inner) ++ ", which points at " ++
                @typeName(Outer) ++ "'s table from more than one column: " ++ named ++ ".\n" ++
                "  Which of them joins is a question about what the query means, and " ++
                "guessing would answer a different one. Write `.on = .<column>`.",
        );
        return found[0];
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

fn condition(
    comptime D: type,
    comptime Row: type,
    comptime column: []const u8,
    comptime T: type,
    comptime path: Path,
    comptime state: *State,
) []const u8 {
    comptime {
        const quoted = state.qualifier ++ D.quote(column);

        // `.deleted_at = null` is `IS NULL`. It cannot mean anything else:
        // `= NULL` is never true in SQL, so reading it the other way would
        // produce a condition that silently matches nothing.
        if (@typeInfo(T) == .null) return quoted ++ " IS NULL";

        // A term that is only there when the filter carried a value
        // ([ADR 0183](../docs/adr/0183-a-filter-that-is-absent-is-not-a-filter-that-is-null.md)).
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
            return "(" ++ D.placeholder(n) ++ " IS NULL OR " ++ term ++ ")";
        }

        assertNotOptional(column, null, T);

        if (operatorsOf(T)) |ops| {
            var out: []const u8 = "";
            for (ops, 0..) |op, i| {
                if (i > 0) out = out ++ " AND ";
                out = out ++ operator(D, Row, column, quoted, op, path, state);
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
/// time and ADR 0039's rule is kept rather than bent.
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
/// the branch that knows the dialect (ADR 0061).
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
                "  A pattern matches text. On a column holding something else the " ++
                "database casts it to text first, which compares the digits it happens " ++
                "to print rather than the value.",
        );
        if (!isText(Value) and Value != @TypeOf(.enum_literal)) @compileError(
            "nilo: `." ++ column ++ " = .{ ." ++ op ++ " = … }` was given a " ++
                @typeName(Value) ++ ".\n" ++
                "  The pattern is built out of the text handed in, so what goes here is " ++
                "text — a `Str` from the request, or a `[]const u8`.",
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
        // (ADR 0183). Placed after `nullSafeSpelling`, whose operators already
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
            if (listSpelling(op.name) != null) @compileError(
                "nilo: the condition on `" ++ column ++ "` (as `" ++ op.name ++
                    "`) was given a `sql.given`.\n" ++
                    "  `" ++ op.name ++ "` takes a list, and a list that may be absent is " ++
                    "the empty list — which `" ++ op.name ++ "` already reads as *no row " ++
                    "matches*.\n" ++
                    "  Pass an empty slice, or branch.",
            );
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
            return "(" ++ D.placeholder(n) ++ " IS NULL OR " ++ term ++ ")";
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
                // the half of ADR 0039's rule this module exists to keep.
                .expanded, .unsupported => dialect_mod.noListForm(D, column),
            };
        }

        const spelled = spelling(op.name).?;

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

/// An optional in a condition is a Refusal, and it is ADR 0039's own rule
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

/// A Row cannot have a column named `any`, `exists` or `not_exists`, because
/// each already means something inside a condition and one word cannot be both.
fn assertNoReservedColumn(comptime Row: type) void {
    comptime {
        for (reserved) |word| {
            if (!row_mod.hasColumn(Row, word)) continue;
            const means = if (std.mem.eql(u8, word, any_field))
                "OR"
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
    // ADR 0058's argument that `EXCEPT` needs no mechanism rests on this, so
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
    // ADR 0058's closure argument needs this: a leaf that cannot go inside
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
    // [ADR 0058](../docs/adr/0058-a-set-operation-over-one-table-is-a-condition.md)
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
    // limit, the offset and the count beside it (ADR 0183).
    const p = comptime plan(Pg, User, @TypeOf(.{
        .age = given(@as(?i32, null)),
    }), 1);
    try testing.expectEqualStrings("($1 IS NULL OR \"age\" = $1)", p.sql);
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
        "($1 IS NULL OR \"email\" ILIKE '%' || " ++ escaped_one ++ " || '%' ESCAPE '\\')" ++
            " AND \"age\" > $2",
        p.sql,
    );
    try testing.expect(p.params[0].droppable);
    try testing.expect(!p.params[1].droppable);
    try testing.expectEqualStrings("value", p.paths[0][p.paths[0].len - 1]);
}

test "a filter inside an exists drops the subquery rather than a term of it" {
    // Dropping the term would leave the subquery asking whether any joined row
    // exists at all, which excludes every partner with no capabilities — the
    // opposite of no filter, and it compiles (ADR 0183).
    try testing.expectEqualStrings(
        "($1 IS NULL OR EXISTS (SELECT 1 FROM \"partner_capabilities\"" ++
            " WHERE \"partner_capabilities\".\"partner_id\" = \"partners\".\"id\"" ++
            " AND \"partner_capabilities\".\"capability\" = $1))",
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
        "($1 IS NULL OR \"name\" ILIKE '%' || " ++ escaped_one ++ " || '%' ESCAPE '\\')" ++
            " AND ($2 IS NULL OR EXISTS (SELECT 1 FROM \"partner_capabilities\"" ++
            " WHERE \"partner_capabilities\".\"partner_id\" = \"partners\".\"id\"" ++
            " AND \"partner_capabilities\".\"capability\" = $2))",
        p.sql,
    );
}
