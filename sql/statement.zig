//! A whole statement, built while compiling (ADR 0039).
//!
//! `SELECT`, `INSERT`, `UPDATE`, `DELETE` and the aggregates, in one file
//! because they share more than they differ: the same column list, the same
//! table name, the same condition walker, the same Refusal when a column is
//! misspelled. A reader who knows how a `select` narrows knows how a
//! `delete` does, because it is the same code.
//!
//! Several come in pairs, and a pair is one function with a flag rather than
//! two: `select`/`one` differ by a `LIMIT 1`, `update`/`updateReturning` and
//! `delete`/`deleteReturning` by a trailing column list. Writing the second
//! of each separately would be a second place for the condition rules to
//! drift — an update with no `.where` has to be refused whether or not it
//! reports what it rewrote.
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
    /// What each parameter is for, in placeholder order. What reads this is
    /// the parameter tuple in `db.zig`, which needs a definite type for a
    /// literal that was written without one.
    params: []const where_mod.Param,
    /// The most rows this statement can answer with, when the statement says
    /// so itself. Set by a `LIMIT` that was written out, and by `one`, which
    /// compiles its own; null when the ceiling is a parameter or absent.
    ///
    /// This is a *ceiling* and not a count — knowing it bounds the list the
    /// rows go into but never says how many arrive, which is the sentence
    /// ADR 0039 originally got wrong. `fill` in `db.zig` is the only reader.
    reserve: ?usize = null,

    pub fn paramCount(self: Statement) usize {
        return self.paths.len;
    }
};

/// The option names a `SELECT` takes. Anything else is a Refusal, so a
/// misspelled `.limti` stops at `zig build` rather than being ignored.
const known = [_][]const u8{ "where", "order", "limit", "offset" };

/// The same list without `.limit`, for `one` — which compiles its own and so
/// has none to give away.
const known_one = [_][]const u8{ "where", "order", "offset" };

/// How many rows the caller is asking for. `one` is not a `select` somebody
/// narrowed: the ceiling is the module's rather than the caller's, which is
/// why writing a second one is a Refusal instead of a silent argument.
const Answers = enum { many, first };

/// Compile a `SELECT` for `Row` in `D`'s grammar from the options type `O`.
pub fn select(comptime D: type, comptime Row: type, comptime O: type) Statement {
    return comptime rowsOf(D, Row, O, .many);
}

/// The same statement with `LIMIT 1` on the end, for `db.one`.
///
/// It is compiled here rather than left to the caller because `one` answers
/// with a row or with nothing: without the ceiling, a condition matching a
/// thousand rows reads all thousand out of Postgres and copies every one into
/// the arena on the way to dropping 999 of them. Nobody writing
/// `db.one(User, c, .{ .where = .{ .email = e } })` is asking for that, and
/// on a column that is not unique it is what they got.
pub fn one(comptime D: type, comptime Row: type, comptime O: type) Statement {
    return comptime rowsOf(D, Row, O, .first);
}

fn rowsOf(
    comptime D: type,
    comptime Row: type,
    comptime O: type,
    comptime answers: Answers,
) Statement {
    return comptime blk: {
        dialect_mod.assertDialect(D);

        // Said before `assertOptions`, so that a `.limit` written on a `one`
        // gets the sentence about `one` rather than the generic list of what
        // a select takes.
        if (answers == .first and @hasField(O, "limit")) @compileError(
            "nilo: `db.one` on " ++ @typeName(Row) ++ " was given a `.limit`.\n" ++
                "  It answers with one row or with none, and compiles its own " ++
                "`LIMIT 1`. A page of rows is `db.select`.",
        );
        assertOptions(
            Row,
            O,
            if (answers == .first) &known_one else &known,
            if (answers == .first) "`db.one`" else "a select",
        );

        var sql: []const u8 = "SELECT " ++ columnList(D, Row) ++
            " FROM " ++ D.quote(row_mod.tableOf(Row));

        var paths: []const where_mod.Path = &.{};
        var params: []const where_mod.Param = &.{};
        var next: usize = 1;
        var reserve: ?usize = null;

        if (@hasField(O, "where")) {
            const p = where_mod.planAt(D, Row, @FieldType(O, "where"), next, &.{"where"});
            if (!p.isEmpty()) {
                sql = sql ++ " WHERE " ++ p.sql;
                paths = paths ++ p.paths;
                params = params ++ p.params;
                next += p.paths.len;
            }
        }

        if (@hasField(O, "order")) {
            sql = sql ++ orderBy(D, Row, @FieldType(O, "order"));
        }

        if (@hasField(O, "limit")) {
            const bound = boundary(D, O, "limit", next);
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
            const bound = boundary(D, O, "offset", next);
            sql = sql ++ D.offset(bound.text);
            if (bound.path) |path| {
                paths = paths ++ &[_]where_mod.Path{path};
                params = params ++ &[_]where_mod.Param{.{}};
                next += 1;
            }
        }

        break :blk .{ .sql = sql, .paths = paths, .params = params, .reserve = reserve };
    };
}

/// The option names an aggregate takes: a condition, and nothing else.
///
/// `.order` on a statement answering one number sorts nothing, and `.limit`
/// on it truncates a result set of one. Both are Refusals rather than clauses
/// quietly dropped.
const known_tally = [_][]const u8{"where"};

/// `SELECT count(*)`, for the total a page needs.
///
/// The condition is compiled by the same walker a `select` uses, so a
/// misspelled column is the same Refusal in both and a count cannot drift
/// from the query it is counting. No `.where` is allowed and means the whole
/// table — unlike an update or a delete, a count with no condition is the
/// obvious thing rather than the dangerous one.
pub fn count(comptime D: type, comptime Row: type, comptime O: type) Statement {
    return comptime tally(D, Row, O, "SELECT count(*) FROM ", "");
}

/// `SELECT EXISTS(SELECT 1 …)`, which stops at the first matching row.
///
/// A count compared against zero would read every match to answer a question
/// that one row settles. What comes back is a `bool`, so the caller has
/// nothing to compare.
pub fn exists(comptime D: type, comptime Row: type, comptime O: type) Statement {
    return comptime tally(D, Row, O, "SELECT EXISTS(SELECT 1 FROM ", ")");
}

fn tally(
    comptime D: type,
    comptime Row: type,
    comptime O: type,
    comptime opening: []const u8,
    comptime closing: []const u8,
) Statement {
    return comptime blk: {
        dialect_mod.assertDialect(D);
        assertOptions(Row, O, &known_tally, "an aggregate");

        var sql: []const u8 = opening ++ D.quote(row_mod.tableOf(Row));
        var paths: []const where_mod.Path = &.{};
        var params: []const where_mod.Param = &.{};

        if (@hasField(O, "where")) {
            const p = where_mod.planAt(D, Row, @FieldType(O, "where"), 1, &.{"where"});
            if (!p.isEmpty()) {
                sql = sql ++ " WHERE " ++ p.sql;
                paths = p.paths;
                params = p.params;
            }
        }

        break :blk .{ .sql = sql ++ closing, .paths = paths, .params = params, .reserve = 1 };
    };
}

/// `SELECT … WHERE <key> = $1 LIMIT 1` — the one row a key identifies.
///
/// The shape `db.one(Row, c, .{ .where = .{ .id = id } })` already wrote,
/// with the column name taken from the Row's `.key` rather than repeated at
/// every call site. That is what `.key` was for: until this, `row.keyOf` had
/// no caller at all and the marker was a comptime check with nothing reading
/// it.
///
/// `K` is the type of the value handed in, and it is here only to be refused
/// when it is a condition — see `assertKeyValue`.
pub fn find(comptime D: type, comptime Row: type, comptime K: type) Statement {
    return comptime blk: {
        dialect_mod.assertDialect(D);
        const key = row_mod.keyOf(Row);
        assertKeyValue(Row, key, K);

        break :blk .{
            .sql = "SELECT " ++ columnList(D, Row) ++
                " FROM " ++ D.quote(row_mod.tableOf(Row)) ++
                " WHERE " ++ D.quote(key) ++ " = " ++ D.placeholder(1) ++
                D.limit("1"),
            // The empty path is the value itself: `find` takes a key rather
            // than a struct to read one out of, and `where.valueAt` with
            // nothing to follow answers with what it was given. So the same
            // `valuesOf` builds this statement's parameter tuple as builds
            // every other one's, and there is no second way to bind.
            .paths = &.{&.{}},
            .params = &.{.{ .column = key }},
            .reserve = 1,
        };
    };
}

/// A key is one value. A struct where one goes is almost always a condition
/// written out of habit — `db.find(User, c, .{ .where = .{ .id = id } })` —
/// and the sentence it needs is the name of the call that does take one.
///
/// The check is by type rather than by shape, because the types that *are*
/// legitimately structs are the column's own: a `Uuid` key is the ordinary
/// case, and it is exactly `ColumnType(Row, key)`.
fn assertKeyValue(comptime Row: type, comptime key: []const u8, comptime K: type) void {
    comptime {
        if (@typeInfo(K) != .@"struct") return;
        if (K == row_mod.ColumnType(Row, key)) return;
        @compileError(
            "nilo: `db.find` on " ++ @typeName(Row) ++ " was given a struct where its " ++
                "key goes.\n" ++
                "  It takes the value of `" ++ key ++ "` itself: `db.find(Row, c, id)`. " ++
                "A condition — `.{ .where = … }` — is `db.one`.",
        );
    }
}

/// `DELETE`, which is a `SELECT` with no columns and no ordering. Sharing the
/// where walker rather than growing a second one is the point: a condition
/// that reads one way in a select cannot read another way in a delete.
pub fn delete(comptime D: type, comptime Row: type, comptime O: type) Statement {
    return comptime deleting(D, Row, O, false);
}

/// The same, answering with the rows it removed rather than with how many.
///
/// A handler that has to say what it deleted paid for a `SELECT` before the
/// `DELETE` and raced anything running beside it; `RETURNING` is one
/// statement and no race. It costs the `SELECT` list, which is the one this
/// file already writes.
pub fn deleteReturning(comptime D: type, comptime Row: type, comptime O: type) Statement {
    return comptime deleting(D, Row, O, true);
}

fn deleting(
    comptime D: type,
    comptime Row: type,
    comptime O: type,
    comptime returning: bool,
) Statement {
    return comptime blk: {
        dialect_mod.assertDialect(D);
        assertOptions(Row, O, &[_][]const u8{"where"}, "a delete");

        var sql: []const u8 = "DELETE FROM " ++ D.quote(row_mod.tableOf(Row));
        var paths: []const where_mod.Path = &.{};
        var params: []const where_mod.Param = &.{};

        if (@hasField(O, "where")) {
            const p = where_mod.planAt(D, Row, @FieldType(O, "where"), 1, &.{"where"});
            if (!p.isEmpty()) {
                sql = sql ++ " WHERE " ++ p.sql;
                paths = p.paths;
                params = p.params;
            }
        }

        // A delete with no condition empties the table. That is a legal
        // statement and almost never the intended one, so it is written out
        // rather than reached by leaving something off. `.where = .{}` counts
        // as leaving it off: an empty condition matches every row, and the
        // braces make it look like a decision was made.
        if (paths.len == 0) @compileError(
            "nilo: a delete on " ++ @typeName(Row) ++ " with no condition.\n" ++
                "  That empties the table. If it is meant, `db.raw` says so where " ++
                "somebody reading the code can see it.",
        );

        if (returning) sql = sql ++ " RETURNING " ++ columnList(D, Row);
        break :blk .{ .sql = sql, .paths = paths, .params = params };
    };
}

/// `INSERT`, with the Row's own column list as the `RETURNING` clause.
///
/// `V` is the type of a struct naming the columns being written, and it is
/// deliberately a *subset* of the Row's: the columns a database fills in
/// — a generated key, a `DEFAULT now()` — are exactly the ones a caller has
/// nothing to say about. A name that is not a column is the same Refusal a
/// condition gets, which is what makes the subset safe rather than sloppy.
///
/// `RETURNING` is not optional, and that is a decision. The generated key is
/// almost always the next thing the caller needs, and a second `SELECT` to
/// fetch what the database just had in its hand is a round trip nobody meant
/// to pay for. It costs nothing here: the column list is the one `select`
/// already writes.
pub fn insert(comptime D: type, comptime Row: type, comptime V: type) Statement {
    return comptime blk: {
        dialect_mod.assertDialect(D);
        row_mod.assertRow(Row);

        const info = switch (@typeInfo(V)) {
            .@"struct" => |s| s,
            else => @compileError(
                "nilo: an insert into " ++ @typeName(Row) ++ " takes a struct of columns " ++
                    "and was given a " ++ @typeName(V) ++ ".\n" ++
                    "  Write it out where it is used: `.{ .email = \"…\", .age = 30 }`.",
            ),
        };
        if (info.fields.len == 0) @compileError(
            "nilo: an insert into " ++ @typeName(Row) ++ " with no columns.\n" ++
                "  A row of nothing but defaults is `db.raw` with `DEFAULT VALUES`; " ++
                "written this way it is much more likely that the values were left out " ++
                "by accident.",
        );

        var names: []const u8 = "";
        var places: []const u8 = "";
        var paths: []const where_mod.Path = &.{};
        var params: []const where_mod.Param = &.{};

        for (info.fields, 0..) |f, i| {
            if (!row_mod.hasColumn(Row, f.name)) {
                row_mod.noSuchColumn(Row, f.name, "an insert");
            }
            if (i > 0) {
                names = names ++ ", ";
                places = places ++ ", ";
            }
            names = names ++ D.quote(f.name);
            places = places ++ D.placeholder(i + 1);
            paths = paths ++ &[_]where_mod.Path{&[_][]const u8{f.name}};
            params = params ++ &[_]where_mod.Param{.{ .column = f.name }};
        }

        break :blk .{
            .sql = "INSERT INTO " ++ D.quote(row_mod.tableOf(Row)) ++
                " (" ++ names ++ ") VALUES (" ++ places ++ ")" ++
                " RETURNING " ++ columnList(D, Row),
            .paths = paths,
            .params = params,
        };
    };
}

/// The option names an `UPDATE` takes.
const update_known = [_][]const u8{ "set", "where" };

/// `UPDATE … SET … WHERE …`, with both halves required.
///
/// `.set` shares nothing with `.where` except the column check, because they
/// are different questions: `.set` is columns to new values, `.where` is the
/// same condition language `select` and `delete` use. Numbering runs through
/// both, `SET` first, which is why the where walker takes a starting number
/// rather than always beginning at one.
pub fn update(comptime D: type, comptime Row: type, comptime O: type) Statement {
    return comptime updating(D, Row, O, false);
}

/// The same, answering with the rows as they now are rather than with how
/// many were touched.
///
/// This is the shape a `PATCH` endpoint is: change one row, answer with it.
/// Written without `RETURNING` it is an `UPDATE` and then a `SELECT` — two
/// round trips, and a second statement that may read what somebody else has
/// changed in between.
pub fn updateReturning(comptime D: type, comptime Row: type, comptime O: type) Statement {
    return comptime updating(D, Row, O, true);
}

fn updating(
    comptime D: type,
    comptime Row: type,
    comptime O: type,
    comptime returning: bool,
) Statement {
    return comptime blk: {
        dialect_mod.assertDialect(D);
        assertOptions(Row, O, &update_known, "an update");

        if (!@hasField(O, "set")) @compileError(
            "nilo: an update on " ++ @typeName(Row) ++ " with no `.set`.\n" ++
                "  An update that changes no column is not a statement worth sending; " ++
                "write `.set = .{ .column = value }`.",
        );

        const S = @FieldType(O, "set");
        const set_info = switch (@typeInfo(S)) {
            .@"struct" => |s| s,
            else => @compileError(
                "nilo: `.set` has to be a struct and this one is a " ++ @typeName(S) ++ ".\n" ++
                    "  Write `.set = .{ .age = 31 }`, one column per field.",
            ),
        };
        if (set_info.fields.len == 0) @compileError(
            "nilo: `.set` on " ++ @typeName(Row) ++ " is empty.\n" ++
                "  An update that changes no column is not a statement worth sending.",
        );

        var sql: []const u8 = "UPDATE " ++ D.quote(row_mod.tableOf(Row)) ++ " SET ";
        var paths: []const where_mod.Path = &.{};
        var params: []const where_mod.Param = &.{};
        var next: usize = 1;

        for (set_info.fields, 0..) |f, i| {
            if (!row_mod.hasColumn(Row, f.name)) {
                row_mod.noSuchColumn(Row, f.name, "`.set`");
            }
            if (i > 0) sql = sql ++ ", ";
            sql = sql ++ D.quote(f.name) ++ " = " ++ D.placeholder(next);
            paths = paths ++ &[_]where_mod.Path{&[_][]const u8{ "set", f.name }};
            params = params ++ &[_]where_mod.Param{.{ .column = f.name }};
            next += 1;
        }

        const before_where = paths.len;
        if (@hasField(O, "where")) {
            const p = where_mod.planAt(D, Row, @FieldType(O, "where"), next, &.{"where"});
            if (!p.isEmpty()) {
                sql = sql ++ " WHERE " ++ p.sql;
                paths = paths ++ p.paths;
                params = params ++ p.params;
            }
        }

        // The same rule `delete` follows, for the same reason: an update
        // with no condition rewrites every row in the table, and it is
        // reached by leaving something out rather than by writing something
        // down. `.where = .{}` counts as leaving it out.
        if (paths.len == before_where) @compileError(
            "nilo: an update on " ++ @typeName(Row) ++ " with no condition.\n" ++
                "  That rewrites every row in the table. If it is meant, `db.raw` says " ++
                "so where somebody reading the code can see it.",
        );

        if (returning) sql = sql ++ " RETURNING " ++ columnList(D, Row);
        break :blk .{ .sql = sql, .paths = paths, .params = params };
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
                "nilo: `.order` has to be a struct and this one is a " ++
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
                "nilo: `.order` on column `" ++ f.name ++ "` was given a " ++
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
                "nilo: `." ++ field ++ "` has no value written out where it is used.\n" ++
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
    /// The literal, when there was one. What reads it is `select`, which
    /// carries it out as the statement's `reserve` so that the list the rows
    /// go into is sized once instead of doubled into place.
    written: ?usize = null,
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
                "nilo: `." ++ field ++ "` is " ++
                    std.fmt.comptimePrint("{d}", .{value}) ++ ".\n" ++
                    "  It counts rows, so it cannot be negative.",
            );
            return .{
                .text = std.fmt.comptimePrint("{d}", .{value}),
                .path = null,
                .written = value,
            };
        }
        if (@typeInfo(T) != .int) @compileError(
            "nilo: `." ++ field ++ "` was given a " ++ @typeName(T) ++ ".\n" ++
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
            "nilo: " ++ what ++ " takes a struct of options and was given a " ++
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
                "nilo: " ++ what ++ " on " ++ @typeName(Row) ++ " was given `." ++
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
    pub const nilo_table = .{ .name = "users", .key = .id };

    id: i64,
    email: []const u8,
    age: i32,
    created_at: i64,
};

const UserCard = struct {
    pub const nilo_table = User;

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

test "find takes the key column out of the Row rather than the call site" {
    const s = comptime find(Pg, User, i64);
    try testing.expectEqualStrings(
        "SELECT \"id\", \"email\", \"age\", \"created_at\" FROM \"users\"" ++
            " WHERE \"id\" = $1 LIMIT 1",
        s.sql,
    );
    try testing.expectEqual(@as(usize, 1), s.paramCount());
    try testing.expectEqualStrings("id", s.params[0].column);
    try testing.expectEqual(@as(?usize, 1), s.reserve);
}

test "find on a Row whose key is not id reads that column instead" {
    const Membership = struct {
        pub const nilo_table = .{ .name = "memberships", .key = .user_id };

        user_id: i64,
        plan: []const u8,
    };
    try testing.expectEqualStrings(
        "SELECT \"user_id\", \"plan\" FROM \"memberships\" WHERE \"user_id\" = $1 LIMIT 1",
        comptime find(Pg, Membership, i64).sql,
    );
}

test "the value a find binds is the one handed in, reached by an empty path" {
    // `find` takes a key rather than a struct holding one, so the path the
    // statement carries has nothing to follow — which is what lets the same
    // `valuesOf` in `db.zig` build this tuple as builds every other.
    const s = comptime find(Pg, User, i64);
    const key: i64 = 7;
    try testing.expectEqual(@as(usize, 0), s.paths[0].len);
    try testing.expectEqual(@as(i64, 7), where_mod.valueAt(key, s.paths[0]));
}

// -- writes ---------------------------------------------------------------

test "an insert names the columns it was given and returns the whole row" {
    const found = comptime insert(Pg, User, @TypeOf(.{ .email = "a@b.c", .age = 30 }));
    try testing.expectEqualStrings(
        "INSERT INTO \"users\" (\"email\", \"age\") VALUES ($1, $2)" ++
            " RETURNING \"id\", \"email\", \"age\", \"created_at\"",
        found.sql,
    );
    try testing.expectEqual(@as(usize, 2), found.paramCount());
    try testing.expectEqualStrings("email", found.params[0].column);
    try testing.expectEqualStrings("age", found.params[1].column);
}

test "an insert writes a subset, because the database fills the rest in" {
    // No `id` and no `created_at`: a generated key and a DEFAULT are exactly
    // the columns a caller has nothing to say about.
    const found = comptime insert(Pg, User, @TypeOf(.{ .email = "a@b.c" }));
    try testing.expectEqualStrings(
        "INSERT INTO \"users\" (\"email\") VALUES ($1)" ++
            " RETURNING \"id\", \"email\", \"age\", \"created_at\"",
        found.sql,
    );
}

test "an update numbers its set columns before its condition" {
    const found = comptime update(Pg, User, @TypeOf(.{
        .set = .{ .email = "new@b.c", .age = 31 },
        .where = .{ .id = 7 },
    }));
    try testing.expectEqualStrings(
        "UPDATE \"users\" SET \"email\" = $1, \"age\" = $2 WHERE \"id\" = $3",
        found.sql,
    );
    try testing.expectEqual(@as(usize, 3), found.paramCount());
    try testing.expectEqualStrings("id", found.params[2].column);
}

test "an update's condition is the same language a select's is" {
    const found = comptime update(Pg, User, @TypeOf(.{
        .set = .{ .age = 0 },
        .where = .{ .age = .{ .lt = 18 }, .email = .{ .like = "%@spam.example" } },
    }));
    try testing.expectEqualStrings(
        "UPDATE \"users\" SET \"age\" = $1 WHERE \"age\" < $2 AND \"email\" LIKE $3",
        found.sql,
    );
}

test "an update that returns its rows carries the same column list a select does" {
    const found = comptime updateReturning(Pg, User, @TypeOf(.{
        .set = .{ .age = 31 },
        .where = .{ .id = 7 },
    }));
    try testing.expectEqualStrings(
        "UPDATE \"users\" SET \"age\" = $1 WHERE \"id\" = $2" ++
            " RETURNING \"id\", \"email\", \"age\", \"created_at\"",
        found.sql,
    );
    // The clause is on the end and changes nothing about the numbering, which
    // is why it can be a flag on the same walk rather than a second statement.
    try testing.expectEqual(@as(usize, 2), found.paramCount());
}

test "a delete that returns its rows says what it removed, in one statement" {
    const found = comptime deleteReturning(Pg, User, @TypeOf(.{ .where = .{ .id = 7 } }));
    try testing.expectEqualStrings(
        "DELETE FROM \"users\" WHERE \"id\" = $1" ++
            " RETURNING \"id\", \"email\", \"age\", \"created_at\"",
        found.sql,
    );
}

test "the condition rules survive the returning clause, because it is the same walk" {
    // A delete with no condition still empties the table, whether or not it
    // reports what it emptied. The Refusal is `deleting`'s and both callers
    // reach it — `refusals/delete_without_condition.zig` holds the other side.
    const found = comptime deleteReturning(Pg, UserCard, @TypeOf(.{ .where = .{ .id = 7 } }));
    try testing.expectEqualStrings(
        "DELETE FROM \"users\" WHERE \"id\" = $1 RETURNING \"id\", \"email\"",
        found.sql,
    );
}

test "a write on a narrower Row goes to the table it borrows" {
    const found = comptime insert(Pg, UserCard, @TypeOf(.{ .email = "a@b.c" }));
    try testing.expectEqualStrings(
        "INSERT INTO \"users\" (\"email\") VALUES ($1) RETURNING \"id\", \"email\"",
        found.sql,
    );
}
