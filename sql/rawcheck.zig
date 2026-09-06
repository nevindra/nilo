//! Reading the `SELECT` list of a statement this module did not write, while
//! compiling ([ADR 0148](../docs/adr/0148-a-raw-statement-is-counted-while-compiling.md)).
//!
//! `db.raw` fills a Row **by position**, and until its text was comptime that
//! was the whole of the contract: a `SELECT` list and a struct agreeing by
//! hand. On a schema with 145 `uuid` columns and 106 `timestamptz` columns,
//! two swapped columns of the same type decode cleanly and answer wrong.
//!
//! So this counts. It does not parse SQL and it does not need to — the
//! question is only where one column ends and the next begins, which is
//! bracket depth, quote state and commas. Two things come out:
//!
//! - **how many columns**, compared against the Row's field count;
//! - **each column's name, when it plainly has one**, compared against the
//!   field in the same position.
//!
//! A name is only taken when the column is an identifier path (`id`,
//! `u.email`, `"created at"`) or ends in an explicit `AS name`. Anything else
//! is nameless here, on purpose: the trailing word of `pg_sleep(10) IS NULL`
//! is `NULL`, and guessing that it names the column would turn a working
//! statement into a compile error.
//!
//! **What it cannot check is types**, because a comptime pass has no schema.
//! That is what `db.checking` is for, and the two halves are different
//! (ADR 0148 argues why closing only one of them is still worth doing).

const std = @import("std");

/// What one pass over a statement found.
pub const List = struct {
    /// How many top-level columns, or null when nothing countable was found:
    /// no `SELECT` and no `RETURNING`, or a `*` in the list itself.
    count: ?usize,
    /// One entry per column, in order. Empty string where the column has no
    /// name this is willing to claim.
    names: []const []const u8,
};

/// Count the columns a statement answers with.
pub fn scan(comptime sql: []const u8) List {
    return comptime blk: {
        @setEvalBranchQuota(200 * sql.len + 10_000);

        const start = listStart(sql) orelse break :blk .{ .count = null, .names = &.{} };

        var names: []const []const u8 = &.{};
        var n: usize = 0;
        var depth: usize = 0;
        var i: usize = start;
        var from: usize = start;
        var starred = false;

        while (i < sql.len) {
            const skipped = skipPast(sql, i);
            if (skipped != i) {
                i = skipped;
                continue;
            }
            const ch = sql[i];
            if (ch == '(' or ch == '[') {
                depth += 1;
            } else if (ch == ')' or ch == ']') {
                // A `)` at depth 0 closes something that started before this
                // list, so the list ends here too.
                if (depth == 0) break;
                depth -= 1;
            } else if (depth == 0 and ch == '*') {
                starred = true;
            } else if (depth == 0 and ch == ',') {
                names = names ++ [_][]const u8{nameOf(sql[from..i])};
                n += 1;
                from = i + 1;
            } else if (depth == 0 and endsList(sql, i)) {
                break;
            }
            i += 1;
        }

        names = names ++ [_][]const u8{nameOf(sql[from..i])};
        n += 1;

        // `*` cannot be counted: how many columns it stands for is the
        // database's answer, not this file's.
        if (starred) break :blk .{ .count = null, .names = &.{} };
        break :blk .{ .count = n, .names = names };
    };
}

/// Hold a raw statement against the Row it fills, while compiling
/// ([ADR 0148](../docs/adr/0148-a-raw-statement-is-counted-while-compiling.md)).
///
/// `call` is the name the caller reads in the message — `db.raw` or `tx.raw`
/// — because the wrong one sends somebody looking at the wrong line.
///
/// **Nothing countable is not a failure.** A `*` in the list, and a statement
/// with no `SELECT` and no `RETURNING`, both answer "not counted" and pass.
/// Guessing at either would turn working statements into compile errors,
/// which is the one outcome a check like this cannot afford.
pub fn assertList(
    comptime Row: type,
    comptime sql: []const u8,
    comptime call: []const u8,
) void {
    comptime {
        const list = scan(sql);
        const count = list.count orelse return;
        const fields = @typeInfo(Row).@"struct".fields;

        if (count != fields.len) @compileError(std.fmt.comptimePrint(
            "nilo: the statement handed to `{s}` selects {d} column{s}, and {s} has {d} field{s}.\n" ++
                "  A raw statement fills the Row by position, so the SELECT list and the " ++
                "struct have to be the same length. Add the missing column to the list, or " ++
                "take the field out of the Row.",
            .{ call, count, plural(count), @typeName(Row), fields.len, plural(fields.len) },
        ));

        for (list.names, fields, 1..) |name, field, at| {
            // Empty is a column this file will not claim a name for, which is
            // most expressions. Only counted, never matched.
            if (name.len == 0) continue;
            if (std.mem.eql(u8, name, field.name)) continue;
            @compileError(std.fmt.comptimePrint(
                "nilo: column {d} of the statement handed to `{s}` is named `{s}`, and " ++
                    "field {d} of {s} is `{s}`.\n" ++
                    "  A raw statement fills the Row by position, so column {d} becomes " ++
                    "field {d}. Reorder the SELECT list, or alias the column: `… AS \"{s}\"`.",
                .{ at, call, name, at, @typeName(Row), field.name, at, at, field.name },
            ));
        }
    }
}

/// `s` where a count is not one. Written out because a message that reads
/// "selects 1 columns" is a message somebody stops trusting.
fn plural(comptime n: usize) []const u8 {
    return if (n == 1) "" else "s";
}

/// Just past the `SELECT` or `RETURNING` that opens the list nilo will read,
/// or null when the statement has neither at the top level.
///
/// The first `SELECT` at depth 0 is the outer one: a CTE's own `SELECT` is
/// inside brackets, and so is a subquery's.
fn listStart(comptime sql: []const u8) ?usize {
    comptime {
        var depth: usize = 0;
        var i: usize = 0;
        var selecting: ?usize = null;
        var returning: ?usize = null;
        while (i < sql.len) {
            const skipped = skipPast(sql, i);
            if (skipped != i) {
                i = skipped;
                continue;
            }
            const ch = sql[i];
            if (ch == '(' or ch == '[') {
                depth += 1;
            } else if (ch == ')' or ch == ']') {
                if (depth > 0) depth -= 1;
            } else if (depth == 0) {
                if (selecting == null and wordAt(sql, i, "SELECT")) selecting = i + "SELECT".len;
                // An `INSERT … RETURNING` answers with rows too, and the last
                // one is the statement's own rather than a sub-statement's.
                if (wordAt(sql, i, "RETURNING")) returning = i + "RETURNING".len;
            }
            i += 1;
        }
        // **A top-level `RETURNING` wins over a top-level `SELECT`**, and the
        // statement that forced it is in the guide: `INSERT INTO audit (…)
        // SELECT 'x', id FROM gone RETURNING ref AS id`. Both words are at
        // depth 0, the `SELECT` is the insert's *source* and the `RETURNING`
        // is what the caller gets back. Taking the first word found read the
        // wrong list and refused a working statement, which is the one thing
        // this file must not do.
        //
        // The other order needs no case: `WITH x AS (… RETURNING id) SELECT …`
        // has its `RETURNING` inside brackets, so only the `SELECT` is seen.
        return returning orelse selecting;
    }
}

/// The keywords that end a `SELECT` list. `FROM` covers almost everything;
/// the rest are for a list with no table under it.
fn endsList(comptime sql: []const u8, comptime i: usize) bool {
    comptime {
        for ([_][]const u8{ "FROM", "WHERE", "GROUP", "ORDER", "LIMIT", "UNION", "HAVING", "WINDOW", "OFFSET" }) |word| {
            if (wordAt(sql, i, word)) return true;
        }
        return false;
    }
}

/// A whole-word, case-insensitive match at `i`.
fn wordAt(comptime sql: []const u8, comptime i: usize, comptime word: []const u8) bool {
    comptime {
        if (i + word.len > sql.len) return false;
        if (i > 0 and isWordByte(sql[i - 1])) return false;
        if (i + word.len < sql.len and isWordByte(sql[i + word.len])) return false;
        for (word, 0..) |w, k| {
            if (std.ascii.toUpper(sql[i + k]) != w) return false;
        }
        return true;
    }
}

fn isWordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '$';
}

/// Past a string literal, a quoted identifier or a comment, when `i` opens
/// one. Otherwise `i` itself. This is what keeps a comma inside `'a,b'` out
/// of the count.
fn skipPast(comptime sql: []const u8, comptime i: usize) usize {
    comptime {
        if (i >= sql.len) return i;
        switch (sql[i]) {
            '\'', '"' => {
                const q = sql[i];
                var j = i + 1;
                while (j < sql.len) : (j += 1) {
                    if (sql[j] != q) continue;
                    // `''` and `""` are the escapes, so a doubled quote is
                    // still inside.
                    if (j + 1 < sql.len and sql[j + 1] == q) {
                        j += 1;
                        continue;
                    }
                    return j + 1;
                }
                return sql.len;
            },
            '-' => {
                if (i + 1 < sql.len and sql[i + 1] == '-') {
                    var j = i + 2;
                    while (j < sql.len and sql[j] != '\n') : (j += 1) {}
                    return j;
                }
                return i;
            },
            '/' => {
                if (i + 1 < sql.len and sql[i + 1] == '*') {
                    var j = i + 2;
                    while (j + 1 < sql.len) : (j += 1) {
                        if (sql[j] == '*' and sql[j + 1] == '/') return j + 2;
                    }
                    return sql.len;
                }
                return i;
            },
            else => return i,
        }
    }
}

/// The name a column plainly has, or "" when it has none this is willing to
/// claim.
///
/// Two shapes only. An explicit `AS name`, and an identifier path with
/// nothing else in it. Everything else is nameless, because the alternative
/// is reading the last word of an expression and calling it a name.
fn nameOf(comptime column: []const u8) []const u8 {
    comptime {
        const text = trim(column);
        if (text.len == 0) return "";

        // `… AS name`, which is the one that always means what it says.
        var i: usize = 0;
        var depth: usize = 0;
        var alias: ?usize = null;
        while (i < text.len) {
            const skipped = skipPast(text, i);
            if (skipped != i) {
                i = skipped;
                continue;
            }
            const ch = text[i];
            if (ch == '(' or ch == '[') {
                depth += 1;
            } else if (ch == ')' or ch == ']') {
                if (depth > 0) depth -= 1;
            } else if (depth == 0 and wordAt(text, i, "AS")) {
                alias = i + 2;
            }
            i += 1;
        }
        if (alias) |at| return bare(trim(text[at..]));

        // Or an identifier path and nothing else: `id`, `u.email`,
        // `"created at"`, `u."created at"`.
        var j: usize = 0;
        var last: usize = 0;
        while (j < text.len) {
            if (text[j] == '"') {
                const past = skipPast(text, j);
                if (past == j) return "";
                last = j;
                j = past;
                continue;
            }
            if (text[j] == '.') {
                last = j + 1;
                j += 1;
                continue;
            }
            if (!isWordByte(text[j])) return "";
            j += 1;
        }
        return bare(text[last..]);
    }
}

/// `"email"` and `email` are the same name.
fn bare(comptime text: []const u8) []const u8 {
    comptime {
        if (text.len >= 2 and text[0] == '"' and text[text.len - 1] == '"') return text[1 .. text.len - 1];
        return text;
    }
}

fn trim(comptime text: []const u8) []const u8 {
    return comptime std.mem.trim(u8, text, " \t\r\n");
}

const testing = std.testing;

test "a plain select list is counted and every column names itself" {
    const found = comptime scan("SELECT id, email, age FROM users");
    try testing.expectEqual(@as(?usize, 3), found.count);
    try testing.expectEqualStrings("id", found.names[0]);
    try testing.expectEqualStrings("email", found.names[1]);
    try testing.expectEqualStrings("age", found.names[2]);
}

test "a comma inside brackets or quotes is not a column boundary" {
    const found = comptime scan("SELECT coalesce(a, b), 'x,y', greatest(1, 2, 3) FROM t");
    try testing.expectEqual(@as(?usize, 3), found.count);
}

test "an alias is the name and an expression without one has none" {
    const found = comptime scan("SELECT count(*)::bigint AS n, sum(total) FROM orders");
    try testing.expectEqual(@as(?usize, 2), found.count);
    try testing.expectEqualStrings("n", found.names[0]);
    try testing.expectEqualStrings("", found.names[1]);
}

test "a qualified column is named by its last part, quoted or not" {
    const found = comptime scan("SELECT u.id, u.\"created at\", \"email\" FROM users u");
    try testing.expectEqual(@as(?usize, 3), found.count);
    try testing.expectEqualStrings("id", found.names[0]);
    try testing.expectEqualStrings("created at", found.names[1]);
    try testing.expectEqualStrings("email", found.names[2]);
}

test "a star cannot be counted and says so rather than guessing" {
    try testing.expectEqual(@as(?usize, null), comptime scan("SELECT * FROM users").count);
    try testing.expectEqual(@as(?usize, null), comptime scan("SELECT u.*, o.id FROM users u, orders o").count);
}

test "count(*) is not a star, because the star is inside the brackets" {
    try testing.expectEqual(@as(?usize, 1), comptime scan("SELECT count(*) FROM users").count);
}

test "the outer select of a CTE is the one that is read" {
    const found = comptime scan(
        "WITH recent AS (SELECT id, at, kind FROM events WHERE at > $1)" ++
            " SELECT id, at FROM recent",
    );
    try testing.expectEqual(@as(?usize, 2), found.count);
    try testing.expectEqualStrings("id", found.names[0]);
    try testing.expectEqualStrings("at", found.names[1]);
}

test "a subquery in the select list is one column, not three" {
    const found = comptime scan(
        "SELECT id, (SELECT count(*) FROM orders o WHERE o.user_id = u.id) AS orders FROM users u",
    );
    try testing.expectEqual(@as(?usize, 2), found.count);
    try testing.expectEqualStrings("orders", found.names[1]);
}

test "a RETURNING list is read when there is no select" {
    const found = comptime scan("INSERT INTO users (email) VALUES ($1) RETURNING id, email");
    try testing.expectEqual(@as(?usize, 2), found.count);
    try testing.expectEqualStrings("id", found.names[0]);
}

test "a statement with neither is not counted rather than refused" {
    try testing.expectEqual(@as(?usize, null), comptime scan("SHOW transaction_read_only").count);
}

test "a select list with no FROM under it still ends where it ends" {
    try testing.expectEqual(@as(?usize, 1), comptime scan("SELECT 1").count);
    try testing.expectEqual(@as(?usize, 2), comptime scan("SELECT 1, 2").count);
    try testing.expectEqual(@as(?usize, 1), comptime scan("SELECT pg_sleep(10) IS NULL").count);
}

test "a keyword at the end of an expression is not taken for a name" {
    const found = comptime scan("SELECT pg_sleep(10) IS NULL");
    try testing.expectEqualStrings("", found.names[0]);
}

test "a comment does not hide a comma or invent one" {
    const found = comptime scan("SELECT id, -- , not a column\n email FROM users");
    try testing.expectEqual(@as(?usize, 2), found.count);
    const block = comptime scan("SELECT id /* , */, email FROM users");
    try testing.expectEqual(@as(?usize, 2), block.count);
}

test "DISTINCT does not become a column of its own" {
    try testing.expectEqual(@as(?usize, 2), comptime scan("SELECT DISTINCT id, email FROM users").count);
    try testing.expectEqual(@as(?usize, 2), comptime scan("SELECT DISTINCT ON (id) id, email FROM users").count);
}

test "lower case reads the same as upper" {
    const found = comptime scan("select id, email from users");
    try testing.expectEqual(@as(?usize, 2), found.count);
    try testing.expectEqualStrings("email", found.names[1]);
}

test "a list that lines up with the Row passes, by name and by count" {
    const Tally = struct { country: []const u8, n: i64 };
    comptime assertList(
        Tally,
        "SELECT u.country, count(*)::bigint AS n FROM users u GROUP BY u.country",
        "db.raw",
    );
}

test "a star is not counted, so a narrow Row over `SELECT *` still compiles" {
    const Narrow = struct { id: i64 };
    comptime assertList(Narrow, "SELECT * FROM users", "db.raw");
}

test "a column with no name this file will claim is counted and not matched" {
    const Two = struct { id: i64, alive: bool };
    comptime assertList(Two, "SELECT id, deleted_at IS NULL FROM users", "db.raw");
}

test "a data-modifying CTE answers with its RETURNING, not with the insert's source SELECT" {
    const found = comptime scan(
        "WITH gone AS (DELETE FROM sessions WHERE user_id = $1 RETURNING id) " ++
            "INSERT INTO audit (kind, ref) SELECT 'session_revoked', id FROM gone " ++
            "RETURNING ref AS id",
    );
    try testing.expectEqual(@as(?usize, 1), found.count);
    try testing.expectEqualStrings("id", found.names[0]);
}

test "a RETURNING inside brackets leaves the outer SELECT as the list" {
    const found = comptime scan(
        "WITH made AS (INSERT INTO t (a) VALUES ($1) RETURNING id, a) SELECT id FROM made",
    );
    try testing.expectEqual(@as(?usize, 1), found.count);
    try testing.expectEqualStrings("id", found.names[0]);
}
