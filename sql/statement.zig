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
const types_mod = @import("types.zig");

/// The direction an order term reads. Always comptime — which way a sort runs
/// is shape, and a sort direction chosen at runtime is two statements.
pub const Direction = enum { asc, desc };

/// The name a statement is prepared under, on a connection that keeps plans.
///
/// **Derived from the text, which is what makes it possible at all.** Every
/// statement this module sends is a comptime constant (ADR 0039), so the same
/// query always hashes to the same name and the set of names a program can
/// ever use is fixed when the binary is built. A library that assembles its
/// SQL per request has neither property: its cache would be keyed on a string
/// it just built, and would grow with traffic rather than with the program.
///
/// **Two independent 64-bit hashes rather than one, and the reason is what a
/// collision would do.** A cache hit re-binds against the *stored* describe
/// without looking at the SQL again, so two statements sharing a name means
/// one of them silently runs the other's plan. pg.zig catches the case where
/// the parameter counts differ — that is how this was found — and says
/// nothing at all when they match. At 128 bits, a thousand distinct
/// statements collide with probability around 10⁻³⁴; at 64 it would be 10⁻¹⁴,
/// which is small and is not the same kind of small as impossible
/// ([ADR 0057](../docs/adr/0057-a-statement-that-is-a-constant-can-be-prepared-once.md)).
///
/// 37 characters, comfortably inside Postgres's 63-byte identifier limit.
pub fn planName(comptime sql: []const u8) []const u8 {
    return comptime blk: {
        @setEvalBranchQuota(20 * sql.len + 1_000);
        const low = std.hash.Wyhash.hash(0, sql);
        const high = std.hash.Wyhash.hash(0x9e3779b97f4a7c15, sql);
        break :blk std.fmt.comptimePrint("nilo_{x:0>16}{x:0>16}", .{ low, high });
    };
}

/// The Row's table, quoted, with its schema in front when the Row named one.
/// One function rather than seven call sites, because a `FROM` and an
/// `INSERT INTO` have to spell the same relation the same way.
fn relation(comptime D: type, comptime Row: type) []const u8 {
    return comptime blk: {
        const q = row_mod.qualifiedOf(Row);
        break :blk D.qualify(q.schema, q.table);
    };
}

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
const known = [_][]const u8{ "where", "order", "limit", "offset", "lock" };

/// The same list without `.limit`, for `one` — which compiles its own and so
/// has none to give away.
const known_one = [_][]const u8{ "where", "order", "offset", "lock" };

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
            " FROM " ++ relation(D, Row);

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

        // Last, which is where the grammar puts it: a lock holds the rows
        // that came back, so it is written after the clauses that decide
        // which those are.
        if (@hasField(O, "lock")) sql = sql ++ lockedBy(D, Row, O);

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

        var sql: []const u8 = opening ++ relation(D, Row);
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
                " FROM " ++ relation(D, Row) ++
                " WHERE " ++ D.quote(key) ++ " = " ++
                D.bindAs(D.placeholder(1), row_mod.ColumnType(Row, key), false) ++
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

        var sql: []const u8 = "DELETE FROM " ++ relation(D, Row);
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
            places = places ++ D.bindAs(
                D.placeholder(i + 1),
                row_mod.ColumnType(Row, f.name),
                false,
            );
            paths = paths ++ &[_]where_mod.Path{&[_][]const u8{f.name}};
            params = params ++ &[_]where_mod.Param{.{ .column = f.name }};
        }

        break :blk .{
            .sql = "INSERT INTO " ++ relation(D, Row) ++
                " (" ++ names ++ ") VALUES (" ++ places ++ ")" ++
                " RETURNING " ++ columnList(D, Row),
            .paths = paths,
            .params = params,
        };
    };
}

/// `INSERT`, one statement for however many rows there are.
///
/// The shape is Postgres's own answer to "many rows, one statement, and the
/// statement is still a constant":
///
/// ```sql
/// INSERT INTO "items" ("sku", "qty")
/// SELECT * FROM unnest($1::text[], $2::int4[])
/// RETURNING "id", "sku", "qty"
/// ```
///
/// **One parameter per column, holding that column for every row** — so the
/// text does not depend on how many rows there are, which is what keeps it a
/// comptime constant (ADR 0039). `VALUES ($1,$2),($3,$4),…` is the shape most
/// libraries generate and it is the shape this cannot have: the placeholder
/// count is the batch size, so the SQL would have to be built per call, and
/// Postgres would re-plan it every time the batch size changed.
///
/// `RETURNING` is the Row's column list, the same as `insert`'s and for the
/// same reason. Rows come back in the order the arrays were given.
pub fn insertMany(comptime D: type, comptime Row: type, comptime V: type) Statement {
    return comptime blk: {
        dialect_mod.assertDialect(D);
        row_mod.assertRow(Row);

        const info = switch (@typeInfo(V)) {
            .@"struct" => |s| s,
            else => @compileError(
                "nilo: a batch insert into " ++ @typeName(Row) ++ " takes a slice of " ++
                    "structs of columns, and its element is a " ++ @typeName(V) ++ ".\n" ++
                    "  Give the rows a named struct: `const Line = struct { sku: []const u8, " ++
                    "qty: i32 };` and pass a `[]const Line`.",
            ),
        };
        if (info.fields.len == 0) @compileError(
            "nilo: a batch insert into " ++ @typeName(Row) ++ " with no columns.\n" ++
                "  Every row would be nothing but defaults, and there would be no " ++
                "array to say how many of them there are.",
        );

        var names: []const u8 = "";
        var arrays: []const u8 = "";
        var paths: []const where_mod.Path = &.{};
        var params: []const where_mod.Param = &.{};

        for (info.fields, 0..) |f, i| {
            if (!row_mod.hasColumn(Row, f.name)) {
                row_mod.noSuchColumn(Row, f.name, "a batch insert");
            }
            const F = row_mod.ColumnType(Row, f.name);
            const cast = D.arrayOf(F) orelse noArrayForm(D, Row, f.name, F);
            if (i > 0) {
                names = names ++ ", ";
                arrays = arrays ++ ", ";
            }
            names = names ++ D.quote(f.name);
            arrays = arrays ++ D.placeholder(i + 1) ++ "::" ++ cast;
            paths = paths ++ &[_]where_mod.Path{&[_][]const u8{f.name}};
            // `.list` is what `Values` in `db.zig` reads to make the tuple
            // field a slice of the column's type rather than one of it. It is
            // the same field `.in` sets, because it is the same question:
            // does this placeholder hold one value or many?
            params = params ++ &[_]where_mod.Param{.{ .column = f.name, .list = true }};
        }

        break :blk .{
            .sql = "INSERT INTO " ++ relation(D, Row) ++
                " (" ++ names ++ ") SELECT * FROM unnest(" ++ arrays ++ ")" ++
                " RETURNING " ++ columnList(D, Row),
            .paths = paths,
            .params = params,
        };
    };
}

/// The relation aliases a batched update needs. Two names in one place, so
/// the four fragments that have to agree about them cannot drift.
const batch_target = "t";
const batch_source = "v";

/// `UPDATE`, one statement for however many rows there are.
///
/// The mirror of `insertMany`, and the same array-per-column trick joined
/// against the table instead of selected into it:
///
/// ```sql
/// UPDATE "items" AS t SET "qty" = v."qty"
/// FROM unnest($1::int8[], $2::int4[]) AS v("id", "qty")
/// WHERE t."id" = v."id"
/// RETURNING t."id", t."sku", t."qty"
/// ```
///
/// **The key is a column of the batch and is what each row is found by**, so
/// it is the one field `V` has to carry; everything else it carries is set.
/// That is the same division `insertOrUpdate` already makes — a key
/// identifies, it is not written — and it is why this needs no `.where`:
/// the condition is the join, and a batched update with a condition of its
/// own would be two ideas in one call.
///
/// **Order is not promised and duplicates are not merged.** A join is a join:
/// which row `RETURNING` answers with first is the planner's business, and a
/// batch naming the same key twice updates that row once, from whichever of
/// the two Postgres reached. Both are properties of the shape rather than
/// choices, and `db.update` in a loop is the answer where either matters.
pub fn updateMany(comptime D: type, comptime Row: type, comptime V: type) Statement {
    return comptime blk: {
        dialect_mod.assertDialect(D);
        row_mod.assertRow(Row);

        const info = switch (@typeInfo(V)) {
            .@"struct" => |s| s,
            else => @compileError(
                "nilo: a batch update of " ++ @typeName(Row) ++ " takes a slice of " ++
                    "structs of columns, and its element is a " ++ @typeName(V) ++ ".\n" ++
                    "  Give the rows a named struct: `const Change = struct { id: i64, " ++
                    "qty: i32 };` and pass a `[]const Change`.",
            ),
        };

        const key = row_mod.keyOf(Row);
        var has_key = false;
        for (info.fields) |f| {
            if (std.mem.eql(u8, f.name, key)) has_key = true;
        }
        if (!has_key) @compileError(
            "nilo: a batch update of " ++ @typeName(Row) ++ " does not carry `" ++ key ++
                "`.\n  Every row in a batch is found by its key, because the join is " ++
                "the condition — there is no `.where` to write instead. Add `" ++ key ++
                "` to the struct the rows are written as.",
        );
        if (info.fields.len < 2) @compileError(
            "nilo: a batch update of " ++ @typeName(Row) ++ " has nothing to set.\n" ++
                "  It carries `" ++ key ++ "` and no other column, so every row would " ++
                "be found and then left alone.",
        );

        var arrays: []const u8 = "";
        var aliases: []const u8 = "";
        var sets: []const u8 = "";
        var written: usize = 0;
        var paths: []const where_mod.Path = &.{};
        var params: []const where_mod.Param = &.{};

        for (info.fields, 0..) |f, i| {
            if (!row_mod.hasColumn(Row, f.name)) {
                row_mod.noSuchColumn(Row, f.name, "a batch update");
            }
            const F = row_mod.ColumnType(Row, f.name);
            const cast = D.arrayOf(F) orelse noArrayForm(D, Row, f.name, F);
            if (i > 0) {
                arrays = arrays ++ ", ";
                aliases = aliases ++ ", ";
            }
            arrays = arrays ++ D.placeholder(i + 1) ++ "::" ++ cast;
            aliases = aliases ++ D.quote(f.name);

            // The key joins rather than being written. Postgres would take
            // `SET "id" = v."id"` without complaint and renumber nothing,
            // but it is a column in the SET list that can never change and
            // reads as though it might — the same argument `upserting` makes.
            if (!std.mem.eql(u8, f.name, key)) {
                if (written > 0) sets = sets ++ ", ";
                sets = sets ++ D.quote(f.name) ++ " = " ++ batch_source ++ "." ++ D.quote(f.name);
                written += 1;
            }

            paths = paths ++ &[_]where_mod.Path{&[_][]const u8{f.name}};
            params = params ++ &[_]where_mod.Param{.{ .column = f.name, .list = true }};
        }

        const quoted_key = D.quote(key);
        break :blk .{
            .sql = "UPDATE " ++ relation(D, Row) ++ " AS " ++ batch_target ++
                " SET " ++ sets ++
                " FROM unnest(" ++ arrays ++ ") AS " ++ batch_source ++ "(" ++ aliases ++ ")" ++
                " WHERE " ++ batch_target ++ "." ++ quoted_key ++
                " = " ++ batch_source ++ "." ++ quoted_key ++
                " RETURNING " ++ columnListFrom(D, Row, batch_target ++ "."),
            .paths = paths,
            .params = params,
        };
    };
}

/// The Refusal for a column a batch cannot send as one parameter. Two
/// different mistakes reach it and each gets its own sentence, because the
/// fix is different: a list column cannot be batched at all, and an enum
/// only needs to be told what it is called.
fn noArrayForm(
    comptime D: type,
    comptime Row: type,
    comptime column: []const u8,
    comptime F: type,
) noreturn {
    const head = "nilo: a batch insert into " ++ @typeName(Row) ++ " cannot send `" ++
        column ++ "`, which it reads as " ++ @typeName(F) ++ ".";

    if (types_mod.listElement(F) != null) @compileError(
        head ++ "\n  A batch sends one array per column and `unnest` flattens what it " ++
            "is given, so a column that is itself a list would come back one element " ++
            "per row. Insert those rows one at a time with `db.insert`.",
    );

    if (@typeInfo(F) == .@"enum") @compileError(
        head ++ "\n  A Postgres enum's type name lives in the database, so nothing here " ++
            "can work out what to cast the parameter to. Add `pub const nilo_column = " ++
            "\"<the type name>\";` to " ++ @typeName(F) ++ " — the schema check will use " ++
            "it too.",
    );

    @compileError(
        head ++ "\n  The " ++ D.name ++ " dialect has no column type for it, so there is " ++
            "no array of it to send either. `dialect.accepts` is the list of what it knows.",
    );
}

/// What a conflict does to the row that was already there.
const OnConflict = enum {
    /// `DO NOTHING`. The statement answers with no rows, which is why the
    /// call that compiles this returns an optional.
    nothing,
    /// `DO UPDATE SET`, every written column except the ones being conflicted
    /// on, each taken from the row that was proposed.
    update,
};

/// `INSERT … ON CONFLICT (…) DO NOTHING`, answering with the row when one was
/// stored and with nothing when one was already there.
pub fn insertOrIgnore(
    comptime D: type,
    comptime Row: type,
    comptime V: type,
    comptime on: anytype,
) Statement {
    return comptime upserting(D, Row, V, on, .nothing);
}

/// `INSERT … ON CONFLICT (…) DO UPDATE SET …`, which always answers with a
/// row: the one that was stored, or the one that was already there with the
/// proposed values written over it.
pub fn insertOrUpdate(
    comptime D: type,
    comptime Row: type,
    comptime V: type,
    comptime on: anytype,
) Statement {
    return comptime upserting(D, Row, V, on, .update);
}

/// The columns a conflict is judged on, out of `.email` or
/// `.{ .tenant_id, .email }`.
///
/// An enum literal rather than a string because that is how a column is
/// already named everywhere else a caller writes one — `.key = .id` in a
/// `nilo_table`, `.{ .email = … }` in a condition. A tuple is the composite
/// case, and there is no third spelling.
fn conflictColumns(comptime Row: type, comptime on: anytype) []const []const u8 {
    comptime {
        const On = @TypeOf(on);
        var names: []const []const u8 = &.{};

        if (On == @TypeOf(.enum_literal)) {
            names = &[_][]const u8{@tagName(on)};
        } else switch (@typeInfo(On)) {
            .@"struct" => |s| {
                if (!s.is_tuple) notAConflictTarget(Row, On);
                if (s.fields.len == 0) @compileError(
                    "nilo: an upsert on " ++ @typeName(Row) ++ " was given an empty conflict " ++
                        "target.\n" ++
                        "  Name the column the unique constraint is on: " ++
                        "`db.insertOrIgnore(Row, c, values, .email)`.",
                );
                for (s.fields) |f| {
                    const value = @field(on, f.name);
                    if (@TypeOf(value) != @TypeOf(.enum_literal)) notAConflictTarget(Row, On);
                    names = names ++ &[_][]const u8{@tagName(value)};
                }
            },
            else => notAConflictTarget(Row, On),
        }

        for (names) |name| {
            if (!row_mod.hasColumn(Row, name)) row_mod.noSuchColumn(Row, name, "an upsert");
        }
        return names;
    }
}

fn notAConflictTarget(comptime Row: type, comptime On: type) noreturn {
    @compileError(
        "nilo: an upsert on " ++ @typeName(Row) ++ " was given a " ++ @typeName(On) ++
            " as its conflict target.\n" ++
            "  It takes the column the unique constraint is on, written the way a key is: " ++
            "`.email`, or `.{ .tenant_id, .email }` for one spanning two columns.",
    );
}

/// Both upserts, which differ by four words of SQL and by whether the answer
/// can be empty.
///
/// **`ON CONFLICT` is why this exists at all.** Without it an idempotent write
/// is a caught `AlreadyExists` and a second statement — two round trips, and a
/// race between them that a retry does not close: two requests can both see
/// nothing, both insert, and one of them still loses.
fn upserting(
    comptime D: type,
    comptime Row: type,
    comptime V: type,
    comptime on: anytype,
    comptime action: OnConflict,
) Statement {
    return comptime blk: {
        const base = insert(D, Row, V);
        const targets = conflictColumns(Row, on);

        var conflict: []const u8 = "";
        for (targets, 0..) |name, i| {
            if (i > 0) conflict = conflict ++ ", ";
            conflict = conflict ++ D.quote(name);
        }

        // `insert` has already refused a name that is not a column and a
        // struct that is not one, so what is left to check is the overlap.
        //
        // **Two kinds of column are left out of the update.** The conflict
        // target, because writing a column to the value it was matched on is
        // a no-op with a footgun attached — and the Row's key, because a
        // caller passing `.id` is filling in the *insert* half and nobody
        // means "change the primary key of the row that is already there".
        // Postgres would do it, quietly, and take every foreign key pointing
        // at that row with it.
        const key = row_mod.keyOf(Row);
        var sets: []const u8 = "";
        var written: usize = 0;
        for (@typeInfo(V).@"struct".fields) |f| {
            if (std.mem.eql(u8, key, f.name)) continue;
            var is_target = false;
            for (targets) |name| {
                if (std.mem.eql(u8, name, f.name)) is_target = true;
            }
            if (is_target) continue;
            if (written > 0) sets = sets ++ ", ";
            // `EXCLUDED` is the row the insert proposed, so the update writes
            // the values the caller passed without binding them a second time
            // — the parameter tuple is `insert`'s, unchanged.
            sets = sets ++ D.quote(f.name) ++ " = EXCLUDED." ++ D.quote(f.name);
            written += 1;
        }

        if (action == .update and written == 0) @compileError(
            "nilo: `db.insertOrUpdate` on " ++ @typeName(Row) ++ " has nothing to set.\n" ++
                "  Every column it was given is either the conflict target or the key `" ++
                key ++ "`, and the update half writes neither — the first is the value the " ++
                "rows were matched on, and the second identifies the row that is already " ++
                "there.\n" ++
                "  `db.insertOrIgnore` is the statement with nothing to set, and says so.",
        );

        const clause = switch (action) {
            .nothing => " ON CONFLICT (" ++ conflict ++ ") DO NOTHING",
            .update => " ON CONFLICT (" ++ conflict ++ ") DO UPDATE SET " ++ sets,
        };

        // Rebuilt rather than patched: `RETURNING` has to come last, and
        // `insert` has already put it on the end.
        const marker = " RETURNING ";
        const at = std.mem.lastIndexOf(u8, base.sql, marker).?;

        break :blk .{
            .sql = base.sql[0..at] ++ clause ++ base.sql[at..],
            .paths = base.paths,
            .params = base.params,
            .reserve = 1,
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

        var sql: []const u8 = "UPDATE " ++ relation(D, Row) ++ " SET ";
        var paths: []const where_mod.Path = &.{};
        var params: []const where_mod.Param = &.{};
        var next: usize = 1;

        for (set_info.fields, 0..) |f, i| {
            if (!row_mod.hasColumn(Row, f.name)) {
                row_mod.noSuchColumn(Row, f.name, "`.set`");
            }
            if (i > 0) sql = sql ++ ", ";
            sql = sql ++ D.quote(f.name) ++ " = " ++ D.bindAs(
                D.placeholder(next),
                row_mod.ColumnType(Row, f.name),
                false,
            );
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

/// The `SELECT` list, each column asked for the way its type wants — see
/// `dialect.readAs`, which is where the one exception lives.
fn columnList(comptime D: type, comptime Row: type) []const u8 {
    return comptime columnListFrom(D, Row, "");
}

/// The same list, every column reached through a relation alias. Wanted by
/// exactly one statement — a batched update, whose `FROM` puts a second
/// relation with the same column names in scope, so an unqualified
/// `RETURNING "id"` is *column reference "id" is ambiguous* rather than an
/// answer.
fn columnListFrom(
    comptime D: type,
    comptime Row: type,
    comptime prefix: []const u8,
) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (row_mod.columnsOf(Row), 0..) |c, i| {
            const asked = D.readAs(prefix ++ D.quote(c), row_mod.ColumnType(Row, c));
            out = out ++ (if (i == 0) "" else ", ") ++ asked;
        }
        return out;
    }
}

/// The locking clause a `.lock` compiles to.
///
/// Written out where it is used, like a sort direction and for the same
/// reason: which lock a read takes is shape, and a lock chosen at run time is
/// two statements. The Dialect may have none, and then this is a Refusal
/// naming it rather than a select that holds nothing.
fn lockedBy(comptime D: type, comptime Row: type, comptime O: type) []const u8 {
    comptime {
        const T = @FieldType(O, "lock");
        if (T != dialect_mod.Lock and T != @TypeOf(.enum_literal)) @compileError(
            "nilo: `.lock` was given a " ++ @typeName(T) ++ ".\n" ++
                "  It is `.update`, `.update_nowait`, `.update_skip_locked` or " ++
                "`.share`, written out where it is used — which lock a read takes " ++
                "is settled while compiling.",
        );
        const mode: dialect_mod.Lock = writtenValue(O, "lock", dialect_mod.Lock);
        return D.lock(mode) orelse dialect_mod.noRowLock(D, Row);
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

test "a lock goes on the end, after everything that decides which rows it holds" {
    try testing.expectEqualStrings(
        "SELECT \"id\", \"email\", \"age\", \"created_at\" FROM \"users\"" ++
            " WHERE \"id\" = $1 FOR UPDATE",
        sqlOf(.{ .where = .{ .id = 7 }, .lock = .update }),
    );
    // Past the limit and the offset, which is where the grammar puts it.
    try testing.expect(std.mem.endsWith(
        u8,
        sqlOf(.{ .order = .{ .id = .asc }, .limit = 5, .offset = 2, .lock = .update_skip_locked }),
        "ORDER BY \"id\" ASC LIMIT 5 OFFSET 2 FOR UPDATE SKIP LOCKED",
    ));
    try testing.expect(std.mem.endsWith(u8, sqlOf(.{ .lock = .share }), "FOR SHARE"));
    try testing.expect(std.mem.endsWith(u8, sqlOf(.{ .lock = .update_nowait }), "FOR UPDATE NOWAIT"));
}

test "a lock carries no parameter, because which lock it is was settled while compiling" {
    const s = comptime select(Pg, User, @TypeOf(.{ .where = .{ .id = 7 }, .lock = .update }));
    try testing.expectEqual(@as(usize, 1), s.paramCount());
}

test "one compiles its LIMIT 1 before the lock, so the lock is still last" {
    try testing.expectEqualStrings(
        "SELECT \"id\", \"email\", \"age\", \"created_at\" FROM \"users\"" ++
            " WHERE \"id\" = $1 LIMIT 1 FOR UPDATE",
        comptime one(Pg, User, @TypeOf(.{ .where = .{ .id = 7 }, .lock = .update })).sql,
    );
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

test "a qualified table is two identifiers everywhere a relation is written" {
    const Scoped = struct {
        pub const nilo_table = .{ .name = "app.users", .key = .id };

        id: i64,
        email: []const u8,
    };

    try testing.expectEqualStrings(
        "SELECT \"id\", \"email\" FROM \"app\".\"users\"",
        comptime select(Pg, Scoped, @TypeOf(.{})).sql,
    );
    try testing.expectEqualStrings(
        "INSERT INTO \"app\".\"users\" (\"email\") VALUES ($1)" ++
            " RETURNING \"id\", \"email\"",
        comptime insert(Pg, Scoped, @TypeOf(.{ .email = "a@b.c" })).sql,
    );
    try testing.expectEqualStrings(
        "DELETE FROM \"app\".\"users\" WHERE \"id\" = $1",
        comptime delete(Pg, Scoped, @TypeOf(.{ .where = .{ .id = 1 } })).sql,
    );
    try testing.expectEqualStrings(
        "UPDATE \"app\".\"users\" SET \"email\" = $1 WHERE \"id\" = $2",
        comptime update(Pg, Scoped, @TypeOf(.{
            .set = .{ .email = "a@b.c" },
            .where = .{ .id = 1 },
        })).sql,
    );
}

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

test "a batch insert is one array per column, and the text never mentions a count" {
    const Line = struct { email: []const u8, age: i32 };
    const found = comptime insertMany(Pg, User, Line);
    try testing.expectEqualStrings(
        "INSERT INTO \"users\" (\"email\", \"age\")" ++
            " SELECT * FROM unnest($1::text[], $2::int4[])" ++
            " RETURNING \"id\", \"email\", \"age\", \"created_at\"",
        found.sql,
    );
    // Two placeholders for any number of rows. That is the property: the SQL
    // is the same constant for a batch of one and a batch of ten thousand,
    // which is what lets it be built while compiling at all.
    try testing.expectEqual(@as(usize, 2), found.paramCount());
    try testing.expect(found.params[0].list);
    try testing.expect(found.params[1].list);
}

test "a batch update joins the arrays against the table and sets the rest" {
    const Change = struct { id: i64, email: []const u8, age: i32 };
    try testing.expectEqualStrings(
        "UPDATE \"users\" AS t SET \"email\" = v.\"email\", \"age\" = v.\"age\"" ++
            " FROM unnest($1::int8[], $2::text[], $3::int4[]) AS v(\"id\", \"email\", \"age\")" ++
            " WHERE t.\"id\" = v.\"id\"" ++
            " RETURNING t.\"id\", t.\"email\", t.\"age\", t.\"created_at\"",
        comptime updateMany(Pg, User, Change).sql,
    );
}

test "a batch update returns through the alias, because the join made the name ambiguous" {
    // `RETURNING "id"` with a second relation in scope is *column reference
    // "id" is ambiguous*, and Postgres says so at run time. The alias is what
    // keeps it a compile-time-settled statement that actually runs.
    const Change = struct { id: i64, age: i32 };
    const sql_text = comptime updateMany(Pg, User, Change).sql;
    try testing.expect(std.mem.containsAtLeast(u8, sql_text, 1, "RETURNING t.\"id\""));
    try testing.expect(!std.mem.containsAtLeast(u8, sql_text, 1, "RETURNING \"id\""));
}

test "the key of a batch update joins rather than being written" {
    const Change = struct { id: i64, age: i32 };
    const sql_text = comptime updateMany(Pg, User, Change).sql;
    // It is in the arrays, in the alias list and in the join — and not in
    // the SET list, where it could only ever set a column to itself.
    try testing.expect(std.mem.containsAtLeast(u8, sql_text, 1, "SET \"age\" = v.\"age\" FROM"));
    try testing.expect(!std.mem.containsAtLeast(u8, sql_text, 1, "\"id\" = v.\"id\","));
}

test "a batch names the array of what the column is, not of what was written" {
    // `age` is `i32` in the Row and a `comptime_int` in the literal a caller
    // writes. The cast comes from the column, the same way the parameter tuple
    // takes its type from the column.
    const Ages = struct { age: i32 };
    try testing.expect(std.mem.containsAtLeast(
        u8,
        comptime insertMany(Pg, User, Ages).sql,
        1,
        "$1::int4[]",
    ));

    // And a widened one is named by what the Dialect would accept: a `u32`
    // does not fit an `int4`, so `accepts` says `int8` and so does this.
    const Wide = struct {
        pub const nilo_table = .{ .name = "wide", .key = .id };
        id: i64,
        n: u32,
    };
    try testing.expect(std.mem.containsAtLeast(
        u8,
        comptime insertMany(Pg, Wide, struct { n: u32 }).sql,
        1,
        "$1::int8[]",
    ));
}

test "an enum column can be batched once it says what it is called" {
    const Named = struct {
        pub const nilo_table = .{ .name = "staff", .key = .id };
        id: i64,
        role: Role,

        const Role = enum {
            admin,
            member,

            pub const nilo_column = "user_role";
        };
    };
    try testing.expect(std.mem.containsAtLeast(
        u8,
        comptime insertMany(Pg, Named, struct { role: Named.Role }).sql,
        1,
        "$1::user_role[]",
    ));

    // And the same declaration is what lets the schema check judge the column
    // at startup, which it otherwise declines to do.
    try testing.expectEqualStrings("user_role", Pg.accepts(Named.Role).?[0]);
}

const Invoice = struct {
    pub const nilo_table = .{ .name = "invoices", .key = .id };

    id: i64,
    total: types_mod.Decimal,
    refunded: ?types_mod.Decimal,
};

test "a numeric column is read as text and written back as numeric" {
    // Both casts in one statement, which is the whole of what makes the round
    // trip exact — the digits never become a float in either direction.
    try testing.expectEqualStrings(
        "SELECT \"id\", \"total\"::text, \"refunded\"::text FROM \"invoices\"" ++
            " WHERE \"total\" > $1::numeric",
        comptime select(Pg, Invoice, @TypeOf(.{
            .where = .{ .total = .{ .gt = types_mod.Decimal{ .text = "0" } } },
        })).sql,
    );
}

test "a numeric is cast where it is inserted, and where it is set" {
    try testing.expectEqualStrings(
        "INSERT INTO \"invoices\" (\"id\", \"total\") VALUES ($1, $2::numeric)" ++
            " RETURNING \"id\", \"total\"::text, \"refunded\"::text",
        comptime insert(Pg, Invoice, @TypeOf(.{
            .id = 1,
            .total = types_mod.Decimal{ .text = "1.00" },
        })).sql,
    );
    try testing.expectEqualStrings(
        "UPDATE \"invoices\" SET \"total\" = $1::numeric WHERE \"id\" = $2",
        comptime update(Pg, Invoice, @TypeOf(.{
            .set = .{ .total = types_mod.Decimal{ .text = "2.00" } },
            .where = .{ .id = @as(i64, 1) },
        })).sql,
    );
}

test "a numeric in a list is cast as an array, so the statement stays a constant" {
    try testing.expectEqualStrings(
        "SELECT \"id\", \"total\"::text, \"refunded\"::text FROM \"invoices\"" ++
            " WHERE \"total\" = ANY($1::numeric[])",
        comptime select(Pg, Invoice, @TypeOf(.{
            .where = .{ .total = .{ .in = &[_]types_mod.Decimal{} } },
        })).sql,
    );
}

test "an upsert that ignores a conflict adds four words and no parameters" {
    const values = @TypeOf(.{ .email = "a@b.c", .age = 30 });
    const found = comptime insertOrIgnore(Pg, User, values, .email);
    try testing.expectEqualStrings(
        "INSERT INTO \"users\" (\"email\", \"age\") VALUES ($1, $2)" ++
            " ON CONFLICT (\"email\") DO NOTHING" ++
            " RETURNING \"id\", \"email\", \"age\", \"created_at\"",
        found.sql,
    );
    // The conflict clause binds nothing of its own, so this is the same tuple
    // the plain insert builds.
    try testing.expectEqual(
        comptime insert(Pg, User, values).paramCount(),
        found.paramCount(),
    );
}

test "an upsert that updates writes every column it was given but the target" {
    const found = comptime insertOrUpdate(
        Pg,
        User,
        @TypeOf(.{ .email = "a@b.c", .age = 30, .created_at = 0 }),
        .email,
    );
    try testing.expectEqualStrings(
        "INSERT INTO \"users\" (\"email\", \"age\", \"created_at\") VALUES ($1, $2, $3)" ++
            " ON CONFLICT (\"email\") DO UPDATE SET" ++
            " \"age\" = EXCLUDED.\"age\", \"created_at\" = EXCLUDED.\"created_at\"" ++
            " RETURNING \"id\", \"email\", \"age\", \"created_at\"",
        found.sql,
    );
    // `EXCLUDED` is the proposed row, so the update half costs no second
    // binding of the same values.
    try testing.expectEqual(@as(usize, 3), found.paramCount());
}

test "the update half never writes the key, even when it was given one" {
    // A caller passing `.id` is filling in the insert; Postgres would take
    // `"id" = EXCLUDED."id"` at its word and renumber the row that was
    // already there, along with every foreign key pointing at it.
    const found = comptime insertOrUpdate(
        Pg,
        User,
        @TypeOf(.{ .id = 99, .email = "a@b.c", .age = 30 }),
        .email,
    );
    try testing.expectEqualStrings(
        "INSERT INTO \"users\" (\"id\", \"email\", \"age\") VALUES ($1, $2, $3)" ++
            " ON CONFLICT (\"email\") DO UPDATE SET \"age\" = EXCLUDED.\"age\"" ++
            " RETURNING \"id\", \"email\", \"age\", \"created_at\"",
        found.sql,
    );
    // Still bound, because the insert half needs it.
    try testing.expectEqual(@as(usize, 3), found.paramCount());
}

test "a conflict target spanning two columns is a tuple, and stays one statement" {
    const found = comptime insertOrIgnore(
        Pg,
        User,
        @TypeOf(.{ .id = 1, .email = "a@b.c", .age = 30 }),
        .{ .id, .email },
    );
    try testing.expectEqualStrings(
        "INSERT INTO \"users\" (\"id\", \"email\", \"age\") VALUES ($1, $2, $3)" ++
            " ON CONFLICT (\"id\", \"email\") DO NOTHING" ++
            " RETURNING \"id\", \"email\", \"age\", \"created_at\"",
        found.sql,
    );
}

test "an upsert reserves one row, because at most one comes back" {
    const one_row = comptime insertOrIgnore(Pg, User, @TypeOf(.{ .email = "a@b.c" }), .email);
    try testing.expectEqual(@as(?usize, 1), one_row.reserve);
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

test "two statements that differ by one character are prepared under two names" {
    // The failure this rules out is silent: a cache hit re-binds against the
    // stored describe without reading the SQL, so a shared name means one
    // statement quietly runs the other's plan. `email`/`emaiL` is the
    // smallest difference SQL can have.
    const a = comptime planName("SELECT \"email\" FROM \"people\" WHERE \"id\" = $1");
    const b = comptime planName("SELECT \"emaiL\" FROM \"people\" WHERE \"id\" = $1");
    try testing.expect(!std.mem.eql(u8, a, b));

    // And the same text always gives the same name, or nothing would ever
    // hit the cache at all.
    try testing.expectEqualStrings(
        a,
        comptime planName("SELECT \"email\" FROM \"people\" WHERE \"id\" = $1"),
    );
}

test "a plan name is an identifier Postgres will accept" {
    // 63 bytes is Postgres's limit, and a name over it is silently truncated
    // — which turns a unique name back into a colliding one. The leading
    // character has to be a letter or an underscore, so the prefix is not
    // decoration.
    const name = comptime planName(select(Pg, User, @TypeOf(.{})).sql);
    try testing.expect(name.len < 63);
    try testing.expect(std.mem.startsWith(u8, name, "nilo_"));
    for (name) |ch| try testing.expect(std.ascii.isAlphanumeric(ch) or ch == '_');
}
