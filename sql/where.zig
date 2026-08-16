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
const row_mod = @import("row.zig");
const dialect_mod = @import("dialect.zig");

/// The field name that means OR. A Row with a column of this name is refused,
/// because one word cannot mean both.
pub const any_field = "any";

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
    /// Whether the value is a list of that column's type rather than one of
    /// them. `.in` compiles to `= ANY($1)`: one placeholder holding many
    /// values, which is what keeps the statement a constant however long
    /// the list is.
    list: bool = false,
    /// Whether the value binds as an optional even though the column is not
    /// one. Set by `distinct_from` and by nothing else: it is the only
    /// operator whose SQL does not change when its value turns out to be
    /// null, so it is the only one an optional may reach (`nullSafeSpelling`).
    nullable: bool = false,

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

    fn take(self: *State, comptime path: Path, comptime param: Param) usize {
        if (self.count == max_params) @compileError(
            "nilo: a condition with more than " ++
                std.fmt.comptimePrint("{d}", .{max_params}) ++ " values.\n" ++
                "  That is past anything a hand-written condition reaches; " ++
                "`db.raw` is the way to send a statement this size.",
        );
        self.paths[self.count] = path;
        self.params[self.count] = param;
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
            const sub = walk(D, Row, f.type, path ++ &[_][]const u8{f.name}, state);
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
fn condition(
    comptime D: type,
    comptime Row: type,
    comptime column: []const u8,
    comptime T: type,
    comptime path: Path,
    comptime state: *State,
) []const u8 {
    comptime {
        const quoted = D.quote(column);

        // `.deleted_at = null` is `IS NULL`. It cannot mean anything else:
        // `= NULL` is never true in SQL, so reading it the other way would
        // produce a condition that silently matches nothing.
        if (@typeInfo(T) == .null) return quoted ++ " IS NULL";
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

        assertNotOptional(column, op.name, op.T);

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

/// A Row cannot have a column named `any`, because `.any` already means OR
/// inside a condition and one word cannot be both.
fn assertNoReservedColumn(comptime Row: type) void {
    comptime {
        if (row_mod.hasColumn(Row, any_field)) @compileError(
            "nilo: " ++ @typeName(Row) ++ " has a column named `" ++ any_field ++
                "`, which is the word a condition uses for OR.\n" ++
                "  Read it under another name in the Row and reach the column " ++
                "itself with `db.raw`.",
        );
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
