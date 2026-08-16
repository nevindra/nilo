//! A whole `SELECT`, built while compiling (ADR 0039).
//!
//! This is where the claim gets paid. Given a Row and a struct of options,
//! what comes out is a `[]const u8` that exists before the program does:
//!
//! ```zig
//! .{ .where = .{ .age = .{ .gt = 18 } }, .order = .{ .created_at = .desc }, .limit = 10 }
//! ```
//! ```sql
//! SELECT "id", "email", "age" FROM "users" WHERE "age" > $1 ORDER BY "created_at" DESC LIMIT 10
//! ```
//!
//! At runtime what is sent is that constant and one value. Drizzle, whose
//! spine this borrows, reassembles its string on every request because
//! JavaScript has no other moment to do it in. Zig has one, so nothing is
//! built per request and the axis ADR 0018 guards is never touched by the
//! statement itself.
//!
//! **A literal limit is baked in; a limit held in a variable is a parameter.**
//! That is the rule of ADR 0039 read strictly rather than an inconsistency:
//! `10` written in the source is shape, and shape is settled while compiling.
//! It also gives Postgres a number to plan with, which `LIMIT $2` does not.
//!
//! The options are a flat struct rather than a chain of calls, and the reason
//! is in ADR 0039: a chain carries its state in its return type, and what a
//! reader gets when it does not fit is Diesel's tower rather than a sentence.
//! One flat type means one message that can name the field.

const std = @import("std");
const row_mod = @import("row.zig");
const where_mod = @import("where.zig");
const dialect_mod = @import("dialect.zig");

/// The direction an order term reads. Always comptime — which way a sort runs
/// is shape, and a sort direction chosen at runtime is two statements.
pub const Direction = enum { asc, desc };

/// What a statement compiles to: the text, and where to read each value from
/// inside the options struct it came from.
pub const Statement = struct {
    sql: []const u8,
    paths: []const where_mod.Path,

    pub fn paramCount(self: Statement) usize {
        return self.paths.len;
    }
};

/// The option names a `SELECT` takes. Anything else is a Refusal, so a
/// misspelled `.limti` stops at `zig build` rather than being ignored.
const known = [_][]const u8{ "where", "order", "limit", "offset" };

/// Compile a `SELECT` for `Row` in `D`'s grammar from the options type `O`.
pub fn select(comptime D: type, comptime Row: type, comptime O: type) Statement {
    return comptime blk: {
        dialect_mod.assertDialect(D);
        assertOptions(Row, O, &known, "a select");

        var sql: []const u8 = "SELECT " ++ columnList(D, Row) ++
            " FROM " ++ D.quote(row_mod.tableOf(Row));

        var paths: []const where_mod.Path = &.{};
        var next: usize = 1;

        if (@hasField(O, "where")) {
            const p = where_mod.planAt(D, Row, @FieldType(O, "where"), next, &.{"where"});
            if (!p.isEmpty()) {
                sql = sql ++ " WHERE " ++ p.sql;
                paths = paths ++ p.paths;
                next += p.paths.len;
            }
        }

        if (@hasField(O, "order")) {
            sql = sql ++ orderBy(D, Row, @FieldType(O, "order"));
        }

        if (@hasField(O, "limit")) {
            const bound = boundary(D, O, "limit", next);
            sql = sql ++ D.limit(bound.text);
            if (bound.path) |path| {
                paths = paths ++ &[_]where_mod.Path{path};
                next += 1;
            }
        }

        if (@hasField(O, "offset")) {
            const bound = boundary(D, O, "offset", next);
            sql = sql ++ D.offset(bound.text);
            if (bound.path) |path| {
                paths = paths ++ &[_]where_mod.Path{path};
                next += 1;
            }
        }

        break :blk .{ .sql = sql, .paths = paths };
    };
}

/// `DELETE`, which is a `SELECT` with no columns and no ordering. Sharing the
/// where walker rather than growing a second one is the point: a condition
/// that reads one way in a select cannot read another way in a delete.
pub fn delete(comptime D: type, comptime Row: type, comptime O: type) Statement {
    return comptime blk: {
        dialect_mod.assertDialect(D);
        assertOptions(Row, O, &[_][]const u8{"where"}, "a delete");

        var sql: []const u8 = "DELETE FROM " ++ D.quote(row_mod.tableOf(Row));
        var paths: []const where_mod.Path = &.{};

        if (@hasField(O, "where")) {
            const p = where_mod.planAt(D, Row, @FieldType(O, "where"), 1, &.{"where"});
            if (!p.isEmpty()) {
                sql = sql ++ " WHERE " ++ p.sql;
                paths = p.paths;
            }
        }

        // A delete with no condition empties the table. That is a legal
        // statement and almost never the intended one, so it is written out
        // rather than reached by leaving something off. `.where = .{}` counts
        // as leaving it off: an empty condition matches every row, and the
        // braces make it look like a decision was made.
        if (paths.len == 0) @compileError(
            "zfast: a delete on " ++ @typeName(Row) ++ " with no condition.\n" ++
                "  That empties the table. If it is meant, `db.raw` says so where " ++
                "somebody reading the code can see it.",
        );

        break :blk .{ .sql = sql, .paths = paths };
    };
}

// -- the pieces ----------------------------------------------------------

fn columnList(comptime D: type, comptime Row: type) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (row_mod.columnsOf(Row), 0..) |c, i| {
            out = out ++ (if (i == 0) "" else ", ") ++ D.quote(c);
        }
        return out;
    }
}

fn orderBy(comptime D: type, comptime Row: type, comptime T: type) []const u8 {
    comptime {
        const info = switch (@typeInfo(T)) {
            .@"struct" => |s| s,
            else => @compileError(
                "zfast: `.order` has to be a struct and this one is a " ++
                    @typeName(T) ++ ".\n" ++
                    "  Write `.order = .{ .created_at = .desc }`, one column per field.",
            ),
        };
        if (info.fields.len == 0) return "";

        var out: []const u8 = " ORDER BY ";
        for (info.fields, 0..) |f, i| {
            if (!row_mod.hasColumn(Row, f.name)) {
                row_mod.noSuchColumn(Row, f.name, "`.order`");
            }
            if (f.type != Direction and f.type != @TypeOf(.enum_literal)) @compileError(
                "zfast: `.order` on column `" ++ f.name ++ "` was given a " ++
                    @typeName(f.type) ++ ".\n" ++
                    "  A direction is `.asc` or `.desc`, and it is settled while " ++
                    "compiling — a sort chosen at run time is two statements.",
            );
            const direction: Direction = writtenValue(T, f.name, Direction);
            if (i > 0) out = out ++ ", ";
            out = out ++ D.quote(f.name) ++ (if (direction == .asc) " ASC" else " DESC");
        }
        return out;
    }
}

/// The value a caller wrote out for one field of a struct literal.
///
/// **One field, never the whole struct.** Reading the whole struct's defaults
/// would demand one from every other field too, and a sibling holding a
/// runtime value — `.where = .{ .id = some_id }` beside a written-out
/// `.limit` — has none. Getting that wrong meant a written limit only worked
/// when everything around it was also written out, which is exactly the kind
/// of rule nobody could have guessed.
fn writtenValue(comptime T: type, comptime field: []const u8, comptime As: type) As {
    comptime {
        for (@typeInfo(T).@"struct".fields) |f| {
            if (!std.mem.eql(u8, f.name, field)) continue;
            const written = f.default_value_ptr orelse @compileError(
                "zfast: `." ++ field ++ "` has no value written out where it is used.\n" ++
                    "  It is settled while compiling, so it has to be a literal " ++
                    "rather than something worked out at run time.",
            );
            return @as(*const f.type, @ptrCast(@alignCast(written))).*;
        }
        unreachable;
    }
}

const Bound = struct {
    text: []const u8,
    path: ?where_mod.Path,
};

/// `LIMIT`/`OFFSET`. A `comptime_int` is written into the statement; anything
/// else is a value and takes a placeholder.
fn boundary(
    comptime D: type,
    comptime O: type,
    comptime field: []const u8,
    comptime next: usize,
) Bound {
    comptime {
        const T = @FieldType(O, field);
        if (T == comptime_int) {
            const value = writtenValue(O, field, comptime_int);
            if (value < 0) @compileError(
                "zfast: `." ++ field ++ "` is " ++
                    std.fmt.comptimePrint("{d}", .{value}) ++ ".\n" ++
                    "  It counts rows, so it cannot be negative.",
            );
            return .{ .text = std.fmt.comptimePrint("{d}", .{value}), .path = null };
        }
        if (@typeInfo(T) != .int) @compileError(
            "zfast: `." ++ field ++ "` was given a " ++ @typeName(T) ++ ".\n" ++
                "  It counts rows, so it is a whole number — written out, or held " ++
                "in an integer.",
        );
        return .{
            .text = D.placeholder(next),
            .path = &[_][]const u8{field},
        };
    }
}

fn assertOptions(
    comptime Row: type,
    comptime O: type,
    comptime allowed: []const []const u8,
    comptime what: []const u8,
) void {
    comptime {
        if (@typeInfo(O) != .@"struct") @compileError(
            "zfast: " ++ what ++ " takes a struct of options and was given a " ++
                @typeName(O) ++ ".\n" ++
                "  Write it out where it is used: `.{ .where = .{ … } }`.",
        );
        fields: for (@typeInfo(O).@"struct".fields) |f| {
            for (allowed) |name| {
                if (std.mem.eql(u8, f.name, name)) continue :fields;
            }
            var list: []const u8 = "";
            for (allowed, 0..) |name, i| {
                list = list ++ (if (i == 0) "" else ", ") ++ "`." ++ name ++ "`";
            }
            @compileError(
                "zfast: " ++ what ++ " on " ++ @typeName(Row) ++ " was given `." ++
                    f.name ++ "`, which is not one of its options.\n" ++
                    "  It takes " ++ list ++ ".",
            );
        }
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
    created_at: i64,
};

const UserCard = struct {
    pub const zfast_table = User;

    id: i64,
    email: []const u8,
};

fn sqlOf(comptime o: anytype) []const u8 {
    return comptime select(Pg, User, @TypeOf(o)).sql;
}

test "a select with no options reads every column of the table" {
    try testing.expectEqualStrings(
        "SELECT \"id\", \"email\", \"age\", \"created_at\" FROM \"users\"",
        sqlOf(.{}),
    );
}

test "a narrower Row selects only what it reads, from the table it borrows" {
    try testing.expectEqualStrings(
        "SELECT \"id\", \"email\" FROM \"users\"",
        comptime select(Pg, UserCard, @TypeOf(.{})).sql,
    );
}

test "the whole statement is one constant, condition and order and limit" {
    try testing.expectEqualStrings(
        "SELECT \"id\", \"email\", \"age\", \"created_at\" FROM \"users\"" ++
            " WHERE \"age\" > $1 ORDER BY \"created_at\" DESC LIMIT 10",
        sqlOf(.{
            .where = .{ .age = .{ .gt = 18 } },
            .order = .{ .created_at = .desc },
            .limit = 10,
        }),
    );
}

test "a limit written out is in the statement, and carries no parameter" {
    const s = comptime select(Pg, User, @TypeOf(.{ .limit = 10 }));
    try testing.expectEqual(@as(usize, 0), s.paramCount());
    try testing.expect(std.mem.endsWith(u8, s.sql, "LIMIT 10"));
}

test "a limit held in a variable is a parameter, numbered after the condition" {
    const n: u32 = 10;
    const o = .{ .where = .{ .age = .{ .gt = 18 } }, .limit = n };
    const s = comptime select(Pg, User, @TypeOf(o));

    try testing.expect(std.mem.endsWith(u8, s.sql, "WHERE \"age\" > $1 LIMIT $2"));
    try testing.expectEqual(@as(usize, 2), s.paramCount());
    try testing.expectEqual(@as(i32, 18), where_mod.valueAt(o, s.paths[0]));
    try testing.expectEqual(@as(u32, 10), where_mod.valueAt(o, s.paths[1]));
}

test "a written limit works beside a condition holding a value from elsewhere" {
    // The condition's value has no literal to read, and the limit does. Reading
    // the whole options struct's defaults to find the limit would have demanded
    // one from the condition too, so this compiles only because the limit is
    // read on its own.
    var age: i32 = 18;
    age += 0;
    const o = .{ .where = .{ .age = .{ .gt = age } }, .limit = 10 };
    const s = comptime select(Pg, User, @TypeOf(o));

    try testing.expect(std.mem.endsWith(u8, s.sql, "WHERE \"age\" > $1 LIMIT 10"));
    try testing.expectEqual(@as(usize, 1), s.paramCount());
    try testing.expectEqual(@as(i32, 18), where_mod.valueAt(o, s.paths[0]));
}

test "offset is numbered after limit" {
    const lim: u32 = 10;
    const off: u32 = 20;
    const s = comptime select(Pg, User, @TypeOf(.{ .limit = lim, .offset = off }));
    try testing.expect(std.mem.endsWith(u8, s.sql, "LIMIT $1 OFFSET $2"));
    try testing.expectEqual(@as(usize, 2), s.paramCount());
}

test "several order terms keep the order they were written in" {
    try testing.expect(std.mem.endsWith(
        u8,
        sqlOf(.{ .order = .{ .created_at = .desc, .id = .asc } }),
        "ORDER BY \"created_at\" DESC, \"id\" ASC",
    ));
}

test "a condition's values are read out of the options struct, not the condition" {
    const o = .{ .where = .{ .id = 7 } };
    const s = comptime select(Pg, User, @TypeOf(o));
    try testing.expectEqual(@as(usize, 2), s.paths[0].len);
    try testing.expectEqualStrings("where", s.paths[0][0]);
    try testing.expectEqualStrings("id", s.paths[0][1]);
    try testing.expectEqual(@as(i64, 7), where_mod.valueAt(o, s.paths[0]));
}

test "an empty condition leaves the WHERE off rather than writing an empty one" {
    try testing.expectEqualStrings(
        "SELECT \"id\", \"email\", \"age\", \"created_at\" FROM \"users\"",
        sqlOf(.{ .where = .{} }),
    );
}

test "a delete carries its condition and nothing else" {
    const o = .{ .where = .{ .id = 7 } };
    const s = comptime delete(Pg, User, @TypeOf(o));
    try testing.expectEqualStrings("DELETE FROM \"users\" WHERE \"id\" = $1", s.sql);
    try testing.expectEqual(@as(usize, 1), s.paramCount());
}
