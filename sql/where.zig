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

/// What a where struct compiles to.
pub const Plan = struct {
    /// The fragment, with no `WHERE` in front — the caller decides whether
    /// there is one, because an empty condition means there is not.
    sql: []const u8,
    /// Where each parameter's value lives, in the order the placeholders were
    /// numbered.
    paths: []const Path,

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
        break :blk .{ .sql = sql, .paths = &frozen };
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

fn ValueAt(comptime W: type, comptime path: Path) type {
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
    count: usize = 0,

    fn take(self: *State, comptime path: Path) usize {
        if (self.count == max_params) @compileError(
            "zfast: a condition with more than " ++
                std.fmt.comptimePrint("{d}", .{max_params}) ++ " values.\n" ++
                "  That is past anything a hand-written condition reaches; " ++
                "`db.raw` is the way to send a statement this size.",
        );
        self.paths[self.count] = path;
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
                "zfast: a condition has to be a struct, and this one is a " ++
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
                "zfast: `.any` holds a list of conditions and this one is a " ++
                    @typeName(T) ++ ".\n" ++
                    "  Write `.any = .{ .{ … }, .{ … } }` — a condition per entry.",
            ),
        };
        // Empty first: `.{}` is a struct literal Zig does not call a tuple,
        // so asking about tuple-ness first would answer an emptiness mistake
        // with a message about shape.
        if (info.fields.len == 0) @compileError(
            "zfast: `.any` is empty.\n" ++
                "  An empty list of alternatives matches nothing, which is almost " ++
                "never what was meant; leave it out instead.",
        );
        if (!info.is_tuple) @compileError(
            "zfast: `.any` holds a list of conditions and this one is a single " ++
                "condition.\n  Write `.any = .{ .{ … }, .{ … } }`, with the outer " ++
                "braces holding one entry per alternative.",
        );

        var out: []const u8 = "(";
        for (info.fields, 0..) |f, i| {
            if (i > 0) out = out ++ " OR ";
            const sub = walk(D, Row, f.type, path ++ &[_][]const u8{f.name}, state);
            if (sub.len == 0) @compileError(
                "zfast: one of `.any`'s alternatives is empty.\n" ++
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

        if (operatorsOf(T)) |ops| {
            var out: []const u8 = "";
            for (ops, 0..) |op, i| {
                if (i > 0) out = out ++ " AND ";
                out = out ++ operator(D, Row, column, quoted, op, path, state);
            }
            return out;
        }

        return quoted ++ " = " ++ D.placeholder(state.take(path));
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
            if (spelling(f.name) == null and !std.mem.eql(u8, f.name, "in")) return null;
        }
        var out: [info.fields.len]Operator = undefined;
        for (info.fields, 0..) |f, i| out[i] = .{ .name = f.name, .T = f.type };
        const frozen = out;
        return &frozen;
    }
}

fn spelling(comptime name: []const u8) ?[]const u8 {
    const table = .{
        .{ "eq", "=" },      .{ "ne", "<>" },     .{ "gt", ">" },
        .{ "gte", ">=" },    .{ "lt", "<" },      .{ "lte", "<=" },
        .{ "like", "LIKE" }, .{ "ilike", "ILIKE" },
    };
    inline for (table) |pair| {
        if (std.mem.eql(u8, name, pair[0])) return pair[1];
    }
    return null;
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
        _ = Row;
        const path = prefix ++ &[_][]const u8{op.name};

        if (std.mem.eql(u8, op.name, "in")) {
            return switch (D.list_form) {
                .any_array => quoted ++ " = ANY(" ++ D.placeholder(state.take(path)) ++ ")",
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
                "zfast: `" ++ op.name ++ "` was given null on column `" ++ column ++ "`.\n" ++
                    "  Comparing with null is never true in SQL. `.col = null` asks " ++
                    "for IS NULL and `.col = .{ .ne = null }` for IS NOT NULL; nothing " ++
                    "else has a meaning.",
            );
        }

        return quoted ++ " " ++ spelled ++ " " ++ D.placeholder(state.take(path));
    }
}

/// A Row cannot have a column named `any`, because `.any` already means OR
/// inside a condition and one word cannot be both.
fn assertNoReservedColumn(comptime Row: type) void {
    comptime {
        if (row_mod.hasColumn(Row, any_field)) @compileError(
            "zfast: " ++ @typeName(Row) ++ " has a column named `" ++ any_field ++
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
    pub const zfast_table = .{ .name = "users", .key = .id };

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
