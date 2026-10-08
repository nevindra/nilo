//! Reading the `SELECT` list of a statement this module did not write, while
//! compiling ([ADR 051](../docs/adr/051-a-statement-that-is-a-constant-can-be-prepared-once.md)).
//!
//! `db.raw` fills a Row **by position**, and until its text was comptime that
//! was the whole of the contract: a `SELECT` list and a struct agreeing by
//! hand. On a schema with 145 `uuid` columns and 106 `timestamptz` columns,
//! two swapped columns of the same type decode cleanly and answer wrong.
//!
//! So this counts. It does not parse SQL and it does not need to — the
//! question is only where one column ends and the next begins, which is
//! bracket depth, quote state and commas. **Every reader in this file reads
//! the same token list** (`tokens`, one pass over the text): what is a
//! string, a quoted name, a comment or a `$n` is decided there once, so a
//! `$$…$$` or a nested comment cannot be understood by one reader and not
//! another. A text the tokenizer cannot finish (an unterminated quote) is
//! read by nobody, and every check passes it: the first run holds it
//! (ADR 233). Two things come out:
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
//! That half is asked of the database the first time a statement runs, with
//! whether an outer join can make a column NULL
//! ([ADR 233](../docs/adr/233-a-raw-statement-is-held-against-its-row-the-first-time-it-runs.md)).

const std = @import("std");
/// For `asText` alone: which Row fields are read as the text the database
/// printed, and therefore have to be asked for that way (ADR 124).
const types = @import("types.zig");
/// For `columnsOf`: which of the Row's fields a statement fills, which is
/// every one but those carried beside the columns (ADR 178).
const row_mod = @import("row.zig");

/// What one pass over a statement found.
pub const List = struct {
    /// How many top-level columns, or null when nothing countable was found:
    /// no `SELECT` and no `RETURNING`, or a `*` in the list itself.
    count: ?usize,
    /// One entry per column, in order. Empty string where the column has no
    /// name this is willing to claim.
    names: []const []const u8,
    /// Whether each name was written quoted. Postgres folds an unquoted name
    /// to lower case and keeps a quoted one as it is, so `names` holds the
    /// folded form of an unquoted one and `nameFits` compares accordingly.
    quoted: []const bool,
    /// The text of each column, from its first token to its last, in the
    /// same order — what the caller actually wrote, alias and all. `names`
    /// is what it is *called*; this is what it *is*, and a text column has to
    /// be asked for as text
    /// ([ADR 124](../docs/adr/124-a-raw-statement-cannot-cast-what-it-did-not-write.md)).
    exprs: []const []const u8,
    /// The column as a bare path (`total`, `i.total`, `"total due"`) with its
    /// alias and any `DISTINCT` / `ALL` in front taken off, or "" when it is
    /// anything else. The one shape that cannot have a cast in it.
    paths: []const []const u8,
    /// Whether a `*` stands at the top level of the list. Reported rather than
    /// folded into `count = null`, because a `*` is countable by the database
    /// and uncastable by anybody — two different answers that used to be one.
    starred: bool,
};

/// Count the columns a statement answers with.
pub fn scan(comptime sql: []const u8) List {
    return comptime blk: {
        @setEvalBranchQuota(200 * sql.len + 10_000);

        const empty = List{ .count = null, .names = &.{}, .quoted = &.{}, .exprs = &.{}, .paths = &.{}, .starred = false };
        const tk = tokens(sql);
        const toks = tk.list;
        if (!tk.ok) break :blk empty;
        const start = listStart(sql, toks) orelse break :blk empty;

        // Where each column starts, then the columns read off those cuts.
        var cuts: [toks.len + 1]usize = undefined;
        cuts[0] = start;
        var cut_count: usize = 1;
        var depth: usize = 0;
        var k: usize = start;
        while (k < toks.len) : (k += 1) {
            const t = toks[k];
            if (t.kind == .punct) {
                const ch = sql[t.start];
                if (ch == '(' or ch == '[') {
                    depth += 1;
                } else if (ch == ')' or ch == ']') {
                    // A `)` at depth 0 closes something that started before
                    // this list, so the list ends here too.
                    if (depth == 0) break;
                    depth -= 1;
                } else if (depth == 0 and ch == ';') {
                    break;
                } else if (depth == 0 and ch == ',') {
                    cuts[cut_count] = k + 1;
                    cut_count += 1;
                }
            } else if (depth == 0 and t.kind == .word and endsList(sql, toks, k)) {
                break;
            }
        }

        var names: []const []const u8 = &.{};
        var quoted: []const bool = &.{};
        var exprs: []const []const u8 = &.{};
        var paths: []const []const u8 = &.{};
        var starred = false;
        for (0..cut_count) |c| {
            const to = if (c + 1 < cut_count) cuts[c + 1] - 1 else k;
            const col = columnOf(sql, toks, cuts[c], to);
            names = names ++ [_][]const u8{col.name};
            quoted = quoted ++ [_]bool{col.quoted};
            exprs = exprs ++ [_][]const u8{col.expr};
            paths = paths ++ [_][]const u8{col.path};
            if (hasStar(sql, toks, cuts[c], to)) starred = true;
        }

        // `*` cannot be counted: how many columns it stands for is the
        // database's answer, not this file's. It is still reported, because
        // what a `*` cannot do is carry a cast, and that is a different
        // question from how many columns it stands for (ADR 124).
        if (starred) break :blk List{ .count = null, .names = &.{}, .quoted = &.{}, .exprs = &.{}, .paths = &.{}, .starred = true };
        break :blk List{ .count = cut_count, .names = names, .quoted = quoted, .exprs = exprs, .paths = paths, .starred = false };
    };
}

/// Whether a column's name, as `scan` found it, is the field's. An unquoted
/// name was folded to lower case by the database, so it matches a field of
/// any case; a quoted one is exactly what it says.
fn nameFits(comptime name: []const u8, comptime quoted: bool, comptime field: []const u8) bool {
    if (std.mem.eql(u8, name, field)) return true;
    return !quoted and std.ascii.eqlIgnoreCase(name, field);
}

/// Hold a raw statement against the Row it fills, while compiling
/// ([ADR 051](../docs/adr/051-a-statement-that-is-a-constant-can-be-prepared-once.md)).
///
/// `call` is the name the caller reads in the message — `db.raw` or `tx.raw`
/// — because the wrong one sends somebody looking at the wrong line.
///
/// **Nothing countable is not a failure.** A `*` in the list, and a statement
/// with no `SELECT` and no `RETURNING`, both answer "not counted" and pass.
/// Guessing at either would turn working statements into compile errors,
/// which is the one outcome a check like this cannot afford.
pub fn assertList(
    comptime D: type,
    comptime Row: type,
    comptime sql: []const u8,
    comptime call: []const u8,
) void {
    comptime {
        assertFlat(Row, call);
        // The framework's own walk, paid for by the framework
        // ([ADR 126](../docs/adr/126-a-check-pays-for-its-own-branches.md)).
        // `scan` sizes its own; what this covers is the two comparisons per
        // column below and the `comptimePrint` a refusal builds, both of which
        // are spent out of the caller's budget for every raw statement in the
        // program rather than for this one.
        @setEvalBranchQuota(20_000 + 200 * sql.len);
        const list = scan(sql);
        assertCasts(D, Row, list, call);
        const count = list.count orelse return;
        const fields = columnFields(Row);

        if (count != fields.len) @compileError(std.fmt.comptimePrint(
            "nilo: the statement handed to `{s}` selects {d} column{s}, and {s} has {d} field{s}.\n" ++
                "  A raw statement fills the Row by position, so the SELECT list and the " ++
                "struct have to be the same length. Add the missing column to the list, or " ++
                "take the field out of the Row.",
            .{ call, count, plural(count), @typeName(Row), fields.len, plural(fields.len) },
        ));

        for (list.names, list.quoted, fields, 1..) |name, quoted, field, at| {
            // Empty is a column this file will not claim a name for, which is
            // most expressions. Only counted, never matched.
            if (name.len == 0) continue;
            if (nameFits(name, quoted, field.name)) continue;
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

/// `assertList` for a statement read into **one value** rather than a Row
/// ([ADR 125](../docs/adr/125-a-row-that-owns-no-table.md)): the list, when it
/// can be counted, is one column. Nothing to match a name against, and no
/// cast to check — a scalar has no field for a `::text` to have been left
/// off.
pub fn assertOne(
    comptime T: type,
    comptime sql: []const u8,
    comptime call: []const u8,
) void {
    comptime {
        @setEvalBranchQuota(20_000 + 200 * sql.len);
        const list = scan(sql);
        const count = list.count orelse return;
        if (count != 1) @compileError(std.fmt.comptimePrint(
            "nilo: the statement handed to `{s}` selects {d} column{s}, and {s} is one value.\n" ++
                "  A scalar reads column one and nothing else. Select one column, or read " ++
                "into a struct with a field per column and `pub const nilo_table = .projection;`.",
            .{ call, count, plural(count), @typeName(T) },
        ));
    }
}

/// **A parent or children are filled from a statement this module wrote**
/// (ADR 218): a parent from its columns and one more saying whether it was
/// there, children from a second statement keyed by the first. Neither is
/// something a statement handed in can promise, so a raw call refuses them.
///
/// **Every other field is one column**, and one column is what a raw
/// statement fills by position: a column read through a reference, an
/// aggregate, a count of children (item 108). The Row saying how nilo would
/// compute it does not stop a hand-written statement computing it, and the
/// first run holds the type the way it holds any column's (ADR 233).
pub fn assertFlat(comptime Row: type, comptime call: []const u8) void {
    comptime {
        if (!row_mod.isRow(Row)) return;
        @setEvalBranchQuota(row_mod.budget(Row));
        const row_info = @typeInfo(Row).@"struct";
        for (row_info.field_names, row_info.field_types) |f_name, f_type| {
            switch (row_mod.kindWith(Row, f_name, f_type)) {
                .parent, .children => @compileError(
                    "nilo: `" ++ call ++ "` into " ++ @typeName(Row) ++ ", which reads `" ++ f_name ++
                        "` as a " ++ (if (row_mod.kindWith(Row, f_name, f_type) == .parent) "parent" else "list of children") ++ ".\n" ++
                        "  That is filled from a statement nilo writes, and a raw statement fills one " ++
                        "field per column. Read it with `db.select`, or give the raw statement a Row " ++
                        "with one field per column it selects.",
                ),
                else => {},
            }
        }
    }
}

/// The Row's fields a statement fills, in order: every one but those carried
/// beside the columns (ADR 178).
pub fn columnFields(comptime Row: type) []const row_mod.Field {
    comptime {
        @setEvalBranchQuota(row_mod.budget(Row));
        const all = row_mod.fieldsOf(Row);
        var out: [all.len]row_mod.Field = undefined;
        var n: usize = 0;
        for (all) |f| {
            if (row_mod.isBeside(Row, f.name)) continue;
            out[n] = f;
            n += 1;
        }
        const frozen = out[0..n].*;
        return &frozen;
    }
}

/// Hold the columns a **text column** is filled from against the one thing
/// they have to be: asked for as text
/// ([ADR 124](../docs/adr/124-a-raw-statement-cannot-cast-what-it-did-not-write.md)).
///
/// A text column — `Decimal`, `Interval`, `Inet`, and anything a project
/// declared the same way with `AsText` (ADR 049) — is read as the text the
/// database printed. In every statement this module writes, the Dialect adds
/// the cast that makes that true. In a statement it did not write, nobody
/// does: the driver hands over whatever wire format it chose, and `nilo_read`
/// keeps those bytes as if they were the digits. A `date` comes back as the
/// four bytes of its binary form and **nothing fails**, which is the only
/// silent wrong answer in this module.
///
/// **What is refused is narrow on purpose: a bare column, and a `*`.** Those
/// are the two shapes that cannot possibly have a cast in them. Any
/// expression at all — `total::text`, `coalesce(a::text, '')`, `to_char(…)`,
/// a literal — is left alone, because reading a cast out of an expression
/// means parsing SQL, and refusing a statement that works is the one outcome
/// this file must not have.
fn assertCasts(
    comptime D: type,
    comptime Row: type,
    comptime list: List,
    comptime call: []const u8,
) void {
    comptime {
        if (@typeInfo(Row) != .@"struct") return;
        const fields = columnFields(Row);

        // A `*` stands for columns nobody named, so no cast reached any of
        // them. Refused for the Row that has a text column in it and for no
        // other, which is why this is not a rule about `*`.
        if (list.starred) {
            for (fields, 1..) |field, at| {
                if (types.asText(field.type) == null) continue;
                // **The first line names the column type rather than the Zig
                // type**, and that is not only for reading: `@typeName` of an
                // `AsText` renders as `types.AsText("numeric"[0..7])`, and the
                // build step matches the whole first line of a refusal
                // (ADR 026), so a message ending in a compiler rendering
                // detail is a check that breaks when the rendering changes.
                @compileError(std.fmt.comptimePrint(
                    "nilo: the statement handed to `{s}` selects `*`, and field {d} of {s} is " ++
                        "a `{s}` column read as text.\n" ++
                        "  A text column arrives as the text the database printed, and a `*` " ++
                        "cannot ask for one: what comes back is the wire format, kept as if it " ++
                        "were digits. Write the columns out and cast `{s}` — " ++
                        "`{s} AS \"{s}\"`.",
                    .{
                        call,
                        at,
                        @typeName(Row),
                        types.asText(field.type).?,
                        field.name,
                        D.readAs(field.name, field.type),
                        field.name,
                    },
                ));
            }
            return;
        }
        if (list.count == null) return;
        // A list that is not the Row's length is the count check's to report,
        // and it says it better than a cast complaint about column three of
        // two would.
        if (list.exprs.len != fields.len) return;

        for (list.paths, fields, 1..) |source, field, at| {
            if (types.asText(field.type) == null) continue;
            // Anything that is not a bare column already does something to the
            // value, and this file does not read SQL well enough to say what.
            if (source.len == 0) continue;
            @compileError(std.fmt.comptimePrint(
                "nilo: column {d} of the statement handed to `{s}` is `{s}`, and field {d} of " ++
                    "{s} is a `{s}` column read as text.\n" ++
                    "  A text column arrives as the text the database printed. nilo adds that " ++
                    "cast to every statement it writes; this one it did not write, so `{s}` " ++
                    "comes back in the wire format and is kept as if it were digits — " ++
                    "a `date` becomes four characters and nothing fails. " ++
                    "Ask for it as `{s} AS \"{s}\"`.",
                .{
                    at,
                    call,
                    source,
                    at,
                    @typeName(Row),
                    types.asText(field.type).?,
                    field.name,
                    D.readAs(source, field.type),
                    field.name,
                },
            ));
        }
    }
}

/// `assertList` for a statement read as a **page**: the Row's columns and
/// one more on the end, the `count(*) OVER ()` that `db.rawPage` reads the
/// total from ([ADR 205](../docs/adr/205-a-raw-statement-can-carry-its-total.md)).
/// The names are checked against the fields as before; the last column is
/// counted and nothing else, because `count(*) OVER () AS total` and a bare
/// window are both fine and this file cannot tell them apart.
pub fn assertPaged(
    comptime D: type,
    comptime Row: type,
    comptime sql: []const u8,
    comptime call: []const u8,
) void {
    comptime {
        assertFlat(Row, call);
        @setEvalBranchQuota(20_000 + 200 * sql.len);
        const list = scan(sql);
        const count = list.count orelse return;
        const fields = columnFields(Row);

        if (count != fields.len + 1) @compileError(std.fmt.comptimePrint(
            "nilo: the statement handed to `{s}` selects {d} column{s}, and {s} has {d} field{s} " ++
                "and wants one more.\n" ++
                "  A paged statement fills the Row by position and reads the total from the " ++
                "column after the last field: `SELECT …, count(*) OVER () FROM …`. Add the " ++
                "window on the end, or read the rows with `raw`.",
            .{ call, count, plural(count), @typeName(Row), fields.len, plural(fields.len) },
        ));

        // The Row's own columns, checked the way `assertList` checks them;
        // the total on the end has no field to be held against.
        const narrowed = List{
            .count = fields.len,
            .names = list.names[0..fields.len],
            .quoted = list.quoted[0..fields.len],
            .exprs = list.exprs[0..fields.len],
            .paths = list.paths[0..fields.len],
            .starred = false,
        };
        assertCasts(D, Row, narrowed, call);
        for (narrowed.names, narrowed.quoted, fields, 1..) |name, quoted, field, at| {
            if (name.len == 0) continue;
            if (nameFits(name, quoted, field.name)) continue;
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

/// Which values a paged statement's own `LIMIT` and `OFFSET` are, by
/// position in the tuple: what `db.rawPage` needs to ask the same statement
/// again from its first row when the page came back empty
/// ([ADR 205](../docs/adr/205-a-raw-statement-can-carry-its-total.md)).
pub const Paging = struct {
    /// The tuple index `OFFSET $n` binds, or null when the statement skips
    /// nothing: no `OFFSET`, or `OFFSET 0`.
    offset: ?usize,
    /// The tuple index `LIMIT $n` binds, when that placeholder is used
    /// nowhere else. Null when the limit is written out, absent, or shared,
    /// which only means the second ask reads the rows it reads.
    limit: ?usize,

    /// Whether an empty page can have rows behind it at all. A statement
    /// with neither bound as a value skips nothing and asks for rows, so
    /// empty is nothing matched, and the second ask is not compiled.
    pub fn asksAgain(self: Paging) bool {
        return self.offset != null or self.limit != null;
    }
};

/// Read a paged statement's `LIMIT` and `OFFSET`, and refuse one whose
/// offset nilo could not set back to zero.
///
/// **Why a page cares.** `count(*) OVER ()` rides on the rows, so a page
/// past the last row has no row to carry the total and answered zero: a list
/// of 150 asked for rows 200 onward read as "nothing matches". nilo cannot
/// write a count of a statement it did not write, but it can send the same
/// statement again with `OFFSET 0` and `LIMIT 1`, and the window on that one
/// row is the total. That takes knowing which value is the offset, so the
/// offset has to be a placeholder of its own: `OFFSET $3`, a cast (`$3::int`)
/// and `ROWS` allowed.
///
/// The clauses read are the statement's own, at the top level: a
/// subquery's or a CTE's is inside brackets and is not the page's.
pub fn paging(comptime sql: []const u8, comptime V: type, comptime call: []const u8) Paging {
    return comptime blk: {
        @setEvalBranchQuota(400 * sql.len + 10_000);
        const tk = tokens(sql);
        const toks = tk.list;
        // Text the tokenizer could not finish is nobody's to read.
        if (!tk.ok) break :blk Paging{ .offset = null, .limit = null };
        var depth: usize = 0;
        var limit_at: ?usize = null;
        var offset_at: ?usize = null;
        for (toks, 0..) |t, k| {
            if (t.kind == .punct) {
                const ch = sql[t.start];
                if (ch == '(' or ch == '[') {
                    depth += 1;
                } else if ((ch == ')' or ch == ']') and depth > 0) {
                    depth -= 1;
                }
            } else if (depth == 0) {
                // The index of the token after the keyword, where the bound is.
                if (kw(sql, toks, k, "LIMIT")) limit_at = k + 1;
                if (kw(sql, toks, k, "OFFSET")) offset_at = k + 1;
            }
        }

        const tuple = @typeInfo(V) == .@"struct" and @typeInfo(V).@"struct".is_tuple;
        var out: Paging = .{ .offset = null, .limit = null };

        if (limit_at) |at| {
            const bound = boundAt(sql, toks, at);
            // SQLite's `LIMIT <offset>, <count>` puts the offset first, where
            // nothing here would look for it.
            if (bound.comma) @compileError(std.fmt.comptimePrint(
                "nilo: the statement handed to `{s}` writes `LIMIT a, b`.\n" ++
                    "  A page answers its total even past the last row by asking the same statement " ++
                    "again from row one, which needs to find the offset. Write it the way both " ++
                    "databases read: `LIMIT $2 OFFSET $3`.",
                .{call},
            ));
            if (bound.param) |n| {
                if (tuple and uses(sql, n) == 1) out.limit = n - 1;
            }
        }

        if (offset_at) |at| {
            const bound = boundAt(sql, toks, at);
            if (bound.written) |value| {
                if (value != 0) @compileError(std.fmt.comptimePrint(
                    "nilo: the statement handed to `{s}` writes `OFFSET {d}`.\n" ++
                        "  A page past its last row has no row to carry `count(*) OVER ()`, so nilo " ++
                        "asks the same statement again with the offset at 0 — and an offset written " ++
                        "into the text cannot be. Pass it as a value: `OFFSET $n`.",
                    .{ call, value },
                ));
            } else if (bound.param) |n| {
                if (!tuple) @compileError(
                    "nilo: `" ++ call ++ "` was given its values in a struct with named fields.\n" ++
                        "  A page past its last row is asked again with its `OFFSET` at 0, and the " ++
                        "offset is found by position. Pass the values as a tuple: `.{ a, limit, offset }`.",
                );
                if (uses(sql, n) != 1) @compileError(std.fmt.comptimePrint(
                    "nilo: the statement handed to `{s}` uses its offset, ${d}, somewhere besides " ++
                        "`OFFSET`.\n" ++
                        "  A page past its last row is asked again with the offset at 0, which would " ++
                        "change the other use too. Give the offset a placeholder of its own.",
                    .{ call, n },
                ));
                out.offset = n - 1;
            } else @compileError(
                "nilo: the statement handed to `" ++ call ++ "` has an `OFFSET` that is not one " ++
                    "placeholder.\n" ++
                    "  A page past its last row has no row to carry `count(*) OVER ()`, so nilo asks " ++
                    "the same statement again with the offset at 0, and that means finding the " ++
                    "offset among the values. Work the number out in Zig and write `OFFSET $n`; a " ++
                    "cast, `$n::int`, is fine.",
            );
        }
        break :blk out;
    };
}

/// What stands after a `LIMIT` or `OFFSET` starting at `at`: one
/// placeholder, one number, or something else, and whether a comma follows.
fn boundAt(comptime sql: []const u8, comptime toks: []const Token, comptime at: usize) struct { param: ?usize = null, written: ?u64 = null, comma: bool = false } {
    comptime {
        var j = at;
        if (j >= toks.len) return .{};
        var param: ?usize = null;
        var written: ?u64 = null;
        const first = toks[j];
        if (first.kind == .param and first.dollar) {
            param = first.n;
        } else if (first.kind == .number) {
            written = std.fmt.parseInt(u64, sql[first.start..first.end], 10) catch return .{};
        } else return .{};
        j += 1;
        // A cast on the placeholder is the value's type, not arithmetic on it.
        if (j < toks.len and toks[j].kind == .op and std.mem.eql(u8, sql[toks[j].start..toks[j].end], "::")) {
            j += 1;
            if (j < toks.len and toks[j].kind == .word) j += 1;
        }
        if (j >= toks.len) return .{ .param = param, .written = written };
        const next = toks[j];
        if (next.kind == .punct and sql[next.start] == ',') return .{ .param = param, .written = written, .comma = true };
        // What may follow is the end, a `;`, or the next clause's keyword
        // (`OFFSET`, `ROWS`, `FOR`). An operator means the bound is an
        // expression, and nothing here can set an expression to zero.
        if (next.kind == .word or (next.kind == .punct and sql[next.start] == ';')) {
            return .{ .param = param, .written = written };
        }
        return .{};
    }
}

/// How many times `$n` appears in a statement, quotes and comments skipped.
fn uses(comptime sql: []const u8, comptime n: usize) usize {
    comptime {
        var count: usize = 0;
        for (tokens(sql).list) |t| {
            if (t.kind == .param and t.dollar and t.n == n) count += 1;
        }
        return count;
    }
}

/// `s` where a count is not one. Written out because a message that reads
/// "selects 1 columns" is a message somebody stops trusting.
fn plural(comptime n: usize) []const u8 {
    return if (n == 1) "" else "s";
}

// ---- parameters ----

/// The highest `$n` in a statement, or null when it has none
/// ([ADR 204](../docs/adr/204-a-raw-placeholder-is-spelled-for-the-dialect.md)).
///
/// Read off the token list, so a `$` inside a literal, a comment or a
/// `$$…$$` body is text, and a `$` glued to a word (`a$1`) is part of the
/// word. Only `$n`: a `?n` is the driver's own spelling and is counted by
/// `assertParams`, not respelled.
pub fn highestParam(comptime sql: []const u8) ?usize {
    return comptime blk: {
        const tk = tokens(sql);
        if (!tk.ok) break :blk null;
        var highest: ?usize = null;
        for (tk.list) |t| {
            if (t.kind != .param or !t.dollar or t.n == 0) continue;
            if (highest == null or t.n > highest.?) highest = t.n;
        }
        break :blk highest;
    };
}

/// The statement with every `$n` respelled the way `D` spells its `n`th
/// placeholder ([ADR 204](../docs/adr/204-a-raw-placeholder-is-spelled-for-the-dialect.md)).
///
/// **Why a rewrite and not a rule.** `$1` is what the Postgres guide has
/// always shown, and on SQLite `$1` is a *named* parameter whose index is
/// the order it first appeared in, while nilo binds by position. A
/// statement using `$2` alone bound its first value to `$2` and answered
/// wrong with no error; the same text on Postgres was right. SQLite's
/// numbered form is `?1`, which is what the Dialect writes for every
/// statement nilo composes, so a raw statement is put in the same spelling
/// and one text means one thing on both. The identity for a dialect whose
/// own spelling is `$n`, so Postgres pays nothing and nothing changes.
pub fn spelled(comptime D: type, comptime sql: []const u8) []const u8 {
    return comptime blk: {
        if (std.mem.eql(u8, D.placeholder(1), "$1")) break :blk sql;
        const tk = tokens(sql);
        // Text the tokenizer could not finish is sent as it was written; the
        // database reads what it can, and says so if it cannot.
        if (!tk.ok) break :blk sql;
        var out: []const u8 = "";
        var from: usize = 0;
        for (tk.list) |t| {
            if (t.kind != .param or !t.dollar) continue;
            out = out ++ sql[from..t.start] ++ D.placeholder(t.n);
            from = t.end;
        }
        break :blk out ++ sql[from..];
    };
}

/// Hold the values handed to a raw call against the `$n` its text names
/// ([ADR 204](../docs/adr/204-a-raw-placeholder-is-spelled-for-the-dialect.md)).
///
/// The rule is Postgres's own, said while compiling: the placeholders are
/// `$1` up to `$n` with no gap, and there are `n` values. On Postgres a
/// mismatch is a run-time error naming the parameter; on SQLite, after
/// `spelled`, a `?3` with two values bound is NULL and nothing says so,
/// which is the silent wrong answer this refuses. **A gap is refused too**:
/// `$1` and `$3` with three values leaves the second unread, and on SQLite
/// the value is dropped with nothing said.
///
/// A statement with no `$n` is held by its `?n` instead, the driver's own
/// numbered spelling, unless it also has a `?` of another kind (a bare `?`
/// takes the next free number, which this does not track, and on Postgres it
/// is an operator). Then, and for a named struct of values, nothing is asked.
pub fn assertParams(comptime sql: []const u8, comptime V: type, comptime call: []const u8) void {
    comptime {
        // A tuple is one value per placeholder. Anything else (a named
        // struct, which zqlite binds by `:name`) is the driver's to read.
        const info = @typeInfo(V);
        if (info != .@"struct" or !info.@"struct".is_tuple) return;
        const given = info.@"struct".field_names.len;
        const found = paramMisfit(sql, given) orelse return;
        switch (found.kind) {
            .count => @compileError(std.fmt.comptimePrint(
                "nilo: the statement handed to `{s}` names {s}{d} and was given {d} value{s}.\n" ++
                    "  Parameters are numbered from $1 with no gaps, and the tuple holds one value " ++
                    "for each: `.{{ a, b }}` for `$1` and `$2`. A `$n` used twice is one value; " ++
                    "on SQLite a placeholder with no value binds NULL and nothing says so.",
                .{ call, found.mark, found.highest, given, plural(given) },
            )),
            .gap => @compileError(std.fmt.comptimePrint(
                "nilo: the statement handed to `{s}` names {s}{d} and never uses {s}{d}.\n" ++
                    "  Parameters are numbered from $1 with no gaps, and the tuple binds its values " ++
                    "by position, so the value for {s}{d} would have nothing to go to. Number the " ++
                    "placeholders from 1, or leave the value out of the tuple.",
                .{ call, found.mark, found.highest, found.mark, found.missing, found.mark, found.missing },
            )),
        }
    }
}

/// What `assertParams` refuses, as a value so a test can hold both sides of
/// it: null when the placeholders are `1..given` with none missing, or when
/// the text is not one this reads.
const ParamMisfit = struct {
    kind: enum { count, gap },
    mark: []const u8,
    highest: usize,
    /// The lowest number below `highest` nothing uses, for a `gap`.
    missing: usize,
};

fn paramMisfit(comptime sql: []const u8, comptime given: usize) ?ParamMisfit {
    return comptime blk: {
        @setEvalBranchQuota(100 * sql.len + 10_000);
        const tk = tokens(sql);
        if (!tk.ok) break :blk null;
        var dollars = false;
        var numbered = false;
        var bare = false;
        for (tk.list) |t| {
            if (t.kind == .param and t.n > 0) {
                if (t.dollar) dollars = true else numbered = true;
            }
            if (t.kind == .op and std.mem.indexOfScalar(u8, sql[t.start..t.end], '?') != null) bare = true;
        }
        if (!dollars and (!numbered or bare)) break :blk null;

        var highest: usize = 0;
        for (tk.list) |t| {
            if (t.kind == .param and t.dollar == dollars and t.n > highest) highest = t.n;
        }
        const mark: []const u8 = if (dollars) "$" else "?";
        if (highest != given) break :blk ParamMisfit{ .kind = .count, .mark = mark, .highest = highest, .missing = 0 };

        var seen = @as([(given + 1)]bool, @splat(false));
        for (tk.list) |t| {
            if (t.kind == .param and t.dollar == dollars) seen[t.n] = true;
        }
        for (1..given + 1) |k| {
            if (!seen[k]) break :blk ParamMisfit{ .kind = .gap, .mark = mark, .highest = highest, .missing = k };
        }
        break :blk null;
    };
}

/// Just past the `SELECT` or `RETURNING` that opens the list nilo will read,
/// or null when the statement has neither at the top level.
///
/// The first `SELECT` at depth 0 is the outer one: a CTE's own `SELECT` is
/// inside brackets, and so is a subquery's.
fn listStart(comptime sql: []const u8, comptime toks: []const Token) ?usize {
    comptime {
        var depth: usize = 0;
        var selecting: ?usize = null;
        var returning: ?usize = null;
        for (toks, 0..) |t, k| {
            if (t.kind == .punct) {
                const ch = sql[t.start];
                if (ch == '(' or ch == '[') {
                    depth += 1;
                } else if ((ch == ')' or ch == ']') and depth > 0) {
                    depth -= 1;
                }
            } else if (depth == 0) {
                // Both are token indexes: the list starts at the token after.
                if (selecting == null and kw(sql, toks, k, "SELECT")) selecting = k + 1;
                // An `INSERT … RETURNING` answers with rows too, and the last
                // one is the statement's own rather than a sub-statement's.
                if (kw(sql, toks, k, "RETURNING")) returning = k + 1;
            }
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
///
/// `GROUP` and `ORDER` only count with their `BY`, because both words
/// stand on their own inside a list: `percentile_cont(0.5) WITHIN GROUP
/// (ORDER BY v)` has a `GROUP` at depth 0 before its bracket opens, and
/// reading it as `GROUP BY` ended the list one column early.
///
/// `EXCEPT` and `INTERSECT` end it like `UNION`. **`FROM` after `DISTINCT` is
/// `IS [NOT] DISTINCT FROM`**, an operator inside the column. A keyword that
/// is a qualified name (`p.offset`) or an alias (`AS offset`) is not one; `kw`
/// says so.
fn endsList(comptime sql: []const u8, comptime toks: []const Token, comptime k: usize) bool {
    comptime {
        for ([_][]const u8{ "FROM", "WHERE", "LIMIT", "UNION", "EXCEPT", "INTERSECT", "HAVING", "WINDOW", "OFFSET", "FETCH" }) |word| {
            if (!kw(sql, toks, k, word)) continue;
            if (std.mem.eql(u8, word, "FROM") and k > 0 and isWord(sql, toks[k - 1], "DISTINCT")) return false;
            return true;
        }
        return (kw(sql, toks, k, "GROUP") or kw(sql, toks, k, "ORDER")) and kw(sql, toks, k + 1, "BY");
    }
}

// ---- the tokenizer ----

const Kind = enum {
    /// A bare word: a keyword, a name, a function. Never starts with a digit.
    word,
    /// A quoted name: `"created at"`, or a SQLite `` `name` ``.
    ident,
    /// A string literal of any kind: `'a'`, `E'\''`, `$$a$$`, `$tag$a$tag$`.
    string,
    number,
    /// `$n` (`dollar`) or `?n`.
    param,
    /// One of `( ) [ ] , ; .` and a lone `:`.
    punct,
    /// A run of operator characters, `::` included.
    op,
    /// Anything else, one byte.
    other,
};

const Token = struct {
    kind: Kind,
    start: usize,
    end: usize,
    /// The number of a `param`, else zero.
    n: usize = 0,
    /// Whether a `param` was spelled `$n` rather than `?n`.
    dollar: bool = false,
};

const Tokens = struct {
    list: []const Token,
    /// False when a string, quoted name or comment never ended. Postgres
    /// refuses that text, so nothing here is worth saying about it, and every
    /// reader passes it instead of guessing where things would have ended.
    ok: bool,
};

/// **The one place a statement's text is read** while compiling: one pass, no
/// allocation beyond a token per lexeme, and memoized by the compiler for the
/// same text, so `scan`, `paging`, `spelled` and `assertParams` on one
/// statement tokenize it once.
///
/// Comments and whitespace are dropped. Postgres nests `/* /* */ */`, and
/// this does too: a comment that ends early on SQLite (which does not nest)
/// leaves text this takes for comment, and the worst that does is an
/// unfinished text, which is passed.
fn tokens(comptime sql: []const u8) Tokens {
    return comptime blk: {
        @setEvalBranchQuota(100 * sql.len + 10_000);
        var buf: [sql.len]Token = undefined;
        var n: usize = 0;
        var ok = true;
        var i: usize = 0;
        while (i < sql.len) {
            const c = sql[i];
            if (std.ascii.isWhitespace(c)) {
                i += 1;
                continue;
            }
            if (c == '-' and byteAt(sql, i + 1) == '-') {
                while (i < sql.len and sql[i] != '\n') i += 1;
                continue;
            }
            if (c == '/' and byteAt(sql, i + 1) == '*') {
                i = blockEnd(sql, i) orelse {
                    ok = false;
                    break;
                };
                continue;
            }

            var tok = Token{ .kind = .other, .start = i, .end = i + 1 };
            if (c == '\'') {
                tok.kind = .string;
                tok.end = quoteEnd(sql, i, '\'', false) orelse {
                    ok = false;
                    break;
                };
            } else if (c == '"' or c == '`') {
                tok.kind = .ident;
                tok.end = quoteEnd(sql, i, c, false) orelse {
                    ok = false;
                    break;
                };
            } else if (isWordStart(c)) {
                var j = i + 1;
                while (j < sql.len and isWordByte(sql[j])) j += 1;
                tok.kind = .word;
                tok.end = j;
                // `E'…'` is the one string in which a backslash escapes.
                if (j == i + 1 and (c == 'e' or c == 'E') and byteAt(sql, j) == '\'') {
                    tok.kind = .string;
                    tok.end = quoteEnd(sql, j, '\'', true) orelse {
                        ok = false;
                        break;
                    };
                }
            } else if (std.ascii.isDigit(c) or (c == '.' and std.ascii.isDigit(byteAt(sql, i + 1)) and !afterOperand(sql, i))) {
                var j = i + 1;
                while (j < sql.len and (std.ascii.isAlphanumeric(sql[j]) or sql[j] == '_' or sql[j] == '.')) j += 1;
                tok.kind = .number;
                tok.end = j;
            } else if (c == '$') {
                if (std.ascii.isDigit(byteAt(sql, i + 1))) {
                    var j = i + 1;
                    while (j < sql.len and std.ascii.isDigit(sql[j])) j += 1;
                    // `$1abc` is not a parameter, and nothing here names it.
                    if (!isWordByte(byteAt(sql, j))) {
                        if (std.fmt.parseInt(usize, sql[i + 1 .. j], 10)) |value| {
                            tok.kind = .param;
                            tok.end = j;
                            tok.n = value;
                            tok.dollar = true;
                        } else |_| {}
                    }
                } else {
                    // `$$` or `$tag$`: the text up to the same again is a string.
                    var j = i + 1;
                    if (isWordStart(byteAt(sql, j)) and byteAt(sql, j) < 0x80) {
                        while (isTagByte(byteAt(sql, j))) j += 1;
                    }
                    if (byteAt(sql, j) == '$') {
                        tok.kind = .string;
                        tok.end = dollarEnd(sql, j + 1, sql[i .. j + 1]) orelse {
                            ok = false;
                            break;
                        };
                    }
                }
            } else if (c == '?' and std.ascii.isDigit(byteAt(sql, i + 1))) {
                var j = i + 1;
                while (j < sql.len and std.ascii.isDigit(sql[j])) j += 1;
                if (!isWordByte(byteAt(sql, j))) {
                    if (std.fmt.parseInt(usize, sql[i + 1 .. j], 10)) |value| {
                        tok.kind = .param;
                        tok.end = j;
                        tok.n = value;
                    } else |_| {}
                }
            } else if (c == ':' and byteAt(sql, i + 1) == ':') {
                tok.kind = .op;
                tok.end = i + 2;
            } else if (c == '(' or c == ')' or c == '[' or c == ']' or c == ',' or c == ';' or c == '.' or c == ':') {
                tok.kind = .punct;
            } else if (isOpByte(c)) {
                var j = i;
                var special = false;
                while (j < sql.len and isOpByte(sql[j])) {
                    if (sql[j] == '-' and byteAt(sql, j + 1) == '-') break;
                    if (sql[j] == '/' and byteAt(sql, j + 1) == '*') break;
                    // `col=?1`: the `?1` is a parameter, not part of `=?`.
                    if (j > i and sql[j] == '?' and std.ascii.isDigit(byteAt(sql, j + 1))) break;
                    if (std.mem.indexOfScalar(u8, "~!@#%^&|?", sql[j]) != null) special = true;
                    j += 1;
                }
                // An operator cannot end in `+` or `-` unless it has one of
                // those characters in it: `2*-1` is `*` and `-`.
                while (!special and j > i + 1 and (sql[j - 1] == '+' or sql[j - 1] == '-')) j -= 1;
                tok.kind = .op;
                tok.end = j;
            }
            buf[n] = tok;
            n += 1;
            i = tok.end;
        }
        const frozen = buf[0..n].*;
        break :blk Tokens{ .list = &frozen, .ok = ok };
    };
}

fn byteAt(comptime sql: []const u8, comptime i: usize) u8 {
    return if (i < sql.len) sql[i] else 0;
}

fn isWordStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c >= 0x80;
}

fn isWordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '$' or c >= 0x80;
}

/// A dollar-quote tag is a name without the `$`.
fn isTagByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c >= 0x80;
}

fn isOpByte(c: u8) bool {
    return std.mem.indexOfScalar(u8, "+-*/<>=~!@#%^&|?", c) != null;
}

/// Whether the byte before `i` ends an operand, which is what makes a `.`
/// before a digit a dot and not the start of `.5`.
fn afterOperand(comptime sql: []const u8, comptime i: usize) bool {
    if (i == 0) return false;
    const p = sql[i - 1];
    return isWordByte(p) or p == ')' or p == ']' or p == '"';
}

/// Just past the quote that closes the one at `i`, or null when it never
/// closes. `''` and `""` are the escapes; in an `E` string a backslash also
/// escapes the byte after it, which is how `E'\''` stays open.
fn quoteEnd(comptime sql: []const u8, comptime i: usize, comptime q: u8, comptime backslash: bool) ?usize {
    comptime {
        var j = i + 1;
        while (j < sql.len) {
            if (backslash and sql[j] == '\\') {
                j += 2;
                continue;
            }
            if (sql[j] == q) {
                if (byteAt(sql, j + 1) == q) {
                    j += 2;
                    continue;
                }
                return j + 1;
            }
            j += 1;
        }
        return null;
    }
}

/// Just past the `*/` that closes the comment at `i`, counting the ones
/// opened inside it.
fn blockEnd(comptime sql: []const u8, comptime i: usize) ?usize {
    comptime {
        var depth: usize = 1;
        var j = i + 2;
        while (j < sql.len) {
            if (sql[j] == '/' and byteAt(sql, j + 1) == '*') {
                depth += 1;
                j += 2;
            } else if (sql[j] == '*' and byteAt(sql, j + 1) == '/') {
                depth -= 1;
                j += 2;
                if (depth == 0) return j;
            } else {
                j += 1;
            }
        }
        return null;
    }
}

/// Just past the next `delim` from `from`, or null.
fn dollarEnd(comptime sql: []const u8, comptime from: usize, comptime delim: []const u8) ?usize {
    comptime {
        var j = from;
        while (j + delim.len <= sql.len) : (j += 1) {
            if (sql[j] == '$' and std.mem.eql(u8, sql[j .. j + delim.len], delim)) return j + delim.len;
        }
        return null;
    }
}

/// Whether the token is this word, whatever its case.
fn isWord(comptime sql: []const u8, comptime t: Token, comptime word: []const u8) bool {
    comptime {
        if (t.kind != .word or t.end - t.start != word.len) return false;
        for (word, 0..) |w, q| {
            if (std.ascii.toUpper(sql[t.start + q]) != w) return false;
        }
        return true;
    }
}

fn isPunct(comptime sql: []const u8, comptime t: Token, comptime ch: u8) bool {
    return t.kind == .punct and sql[t.start] == ch;
}

/// Token `k` is this **keyword**: the word, and not a name that spells it. A
/// word after a `.` is a column (`p.offset`) and one after `AS` is an alias.
fn kw(comptime sql: []const u8, comptime toks: []const Token, comptime k: usize, comptime word: []const u8) bool {
    comptime {
        if (k >= toks.len or !isWord(sql, toks[k], word)) return false;
        if (k == 0) return true;
        return !isPunct(sql, toks[k - 1], '.') and !isWord(sql, toks[k - 1], "AS");
    }
}

// ---- columns ----

const Column = struct { name: []const u8, quoted: bool, expr: []const u8, path: []const u8 };

/// One column of the list, tokens `from` up to `to`.
///
/// **A name is only claimed for two shapes**: an explicit `AS name` closing
/// the column, and a bare identifier path. Everything else is nameless,
/// because the alternative is reading the last word of an expression and
/// calling it a name: the trailing word of `pg_sleep(10) IS NULL` is `NULL`.
fn columnOf(comptime sql: []const u8, comptime toks: []const Token, comptime from: usize, comptime to: usize) Column {
    comptime {
        var col = Column{ .name = "", .quoted = false, .expr = "", .path = "" };
        if (from >= to) return col;
        col.expr = sql[toks[from].start..toks[to - 1].end];

        // What is asked for: past a `DISTINCT` or `ALL` in front (they do
        // nothing to the value), up to the last top-level `AS`, the last
        // because `CASE … END AS kind` may have one inside.
        const first = leading(sql, toks, from, to);
        var depth: usize = 0;
        var as_at: ?usize = null;
        for (first..to) |k| {
            const t = toks[k];
            if (t.kind == .punct) {
                const ch = sql[t.start];
                if (ch == '(' or ch == '[') depth += 1;
                if ((ch == ')' or ch == ']') and depth > 0) depth -= 1;
            } else if (depth == 0 and kw(sql, toks, k, "AS")) {
                as_at = k;
            }
        }
        const value_end = as_at orelse to;
        const path = isPath(sql, toks, first, value_end);
        if (path) col.path = sql[toks[first].start..toks[value_end - 1].end];

        if (as_at) |a| {
            if (a + 2 == to) named(sql, toks[a + 1], &col);
        } else if (path) {
            named(sql, toks[to - 1], &col);
        }
        return col;
    }
}

/// Set the column's name from an identifier token: folded to lower case when
/// it was not quoted, as Postgres does. A quoted name with a quote inside it
/// is left unnamed, which only means it is not compared.
fn named(comptime sql: []const u8, comptime t: Token, comptime col: *Column) void {
    comptime {
        if (t.kind == .word) {
            col.name = lower(sql[t.start..t.end]);
        } else if (t.kind == .ident) {
            const inner = sql[t.start + 1 .. t.end - 1];
            if (std.mem.indexOfScalar(u8, inner, sql[t.start]) != null) return;
            col.name = inner;
            col.quoted = true;
        }
    }
}

fn lower(comptime s: []const u8) []const u8 {
    comptime {
        var out: [s.len]u8 = undefined;
        for (s, 0..) |c, q| out[q] = std.ascii.toLower(c);
        const frozen = out;
        return &frozen;
    }
}

/// The first token of the column that is not a `DISTINCT`, an `ALL` or a
/// `DISTINCT ON (…)`: what does nothing to the value, and stands in front of
/// the first column. `isPath` is only as good as what it is handed, and
/// `DISTINCT total` is a bare column to the database (ADR 124).
fn leading(comptime sql: []const u8, comptime toks: []const Token, comptime from: usize, comptime to: usize) usize {
    comptime {
        var k = from;
        while (k < to) {
            if (kw(sql, toks, k, "ALL")) {
                k += 1;
            } else if (kw(sql, toks, k, "DISTINCT")) {
                k += 1;
                if (k < to and kw(sql, toks, k, "ON")) {
                    k += 1;
                    if (k < to and isPunct(sql, toks[k], '(')) {
                        var depth: usize = 0;
                        while (k < to) : (k += 1) {
                            if (isPunct(sql, toks[k], '(')) depth += 1;
                            if (isPunct(sql, toks[k], ')')) {
                                depth -= 1;
                                if (depth == 0) {
                                    k += 1;
                                    break;
                                }
                            }
                        }
                    }
                }
            } else break;
        }
        return k;
    }
}

/// Whether the tokens `from` up to `to` are an identifier path and nothing
/// else: `total`, `i.total`, `u."created at"`. The one shape with no cast in
/// it. A lone `NULL`, `true` or `current_date` is a value, not a column, and
/// so is a number.
fn isPath(comptime sql: []const u8, comptime toks: []const Token, comptime from: usize, comptime to: usize) bool {
    comptime {
        if (from >= to or (to - from) % 2 == 0) return false;
        for (from..to) |k| {
            const t = toks[k];
            if ((k - from) % 2 == 1) {
                if (!isPunct(sql, t, '.')) return false;
            } else if (t.kind == .word) {
                if (to - from == 1) {
                    for ([_][]const u8{ "NULL", "TRUE", "FALSE", "CURRENT_DATE", "CURRENT_TIME", "CURRENT_TIMESTAMP", "LOCALTIME", "LOCALTIMESTAMP", "CURRENT_USER", "SESSION_USER", "USER", "CURRENT_ROLE", "CURRENT_CATALOG", "CURRENT_SCHEMA" }) |lit| {
                        if (isWord(sql, t, lit)) return false;
                    }
                }
            } else if (t.kind != .ident) return false;
        }
        return true;
    }
}

/// Whether the column, tokens `from` up to `to`, has a `*` of its own at the
/// top level: `*` first (after a `DISTINCT` or `ALL`), or after a `.`
/// (`u.*`). Anywhere else it is multiplication (`a * b`, `count(*) * 2`).
fn hasStar(comptime sql: []const u8, comptime toks: []const Token, comptime from: usize, comptime to: usize) bool {
    comptime {
        const first = leading(sql, toks, from, to);
        var depth: usize = 0;
        for (from..to) |k| {
            const t = toks[k];
            if (t.kind == .punct) {
                const ch = sql[t.start];
                if (ch == '(' or ch == '[') depth += 1;
                if ((ch == ')' or ch == ']') and depth > 0) depth -= 1;
            } else if (depth == 0 and t.kind == .op and t.end - t.start == 1 and sql[t.start] == '*') {
                if (k == first) return true;
                if (k > from and isPunct(sql, toks[k - 1], '.')) return true;
            }
        }
        return false;
    }
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

test "WITHIN GROUP is part of a column, and GROUP BY is where the list ends" {
    const found = comptime scan(
        "SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY v) AS median, count(*) AS n FROM t GROUP BY k",
    );
    try testing.expectEqual(@as(?usize, 2), found.count);
    try testing.expectEqualStrings("median", found.names[0]);
    try testing.expectEqualStrings("n", found.names[1]);
    // A list with no table under it still stops at the clause.
    try testing.expectEqual(@as(?usize, 1), comptime scan("SELECT 1 ORDER BY 1").count);
    try testing.expectEqual(@as(?usize, 2), comptime scan("SELECT a, b FROM t GROUP\n  BY a").count);
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

test "a DISTINCT, an ALL or a comment in front of a column leaves it a bare column" {
    try testing.expectEqualStrings("total", (comptime scan("SELECT DISTINCT total FROM t")).paths[0]);
    try testing.expectEqualStrings("total", (comptime scan("SELECT distinct on (id, \"a)\") total FROM t")).paths[0]);
    try testing.expectEqualStrings("total", (comptime scan("SELECT ALL total FROM t")).paths[0]);
    try testing.expectEqualStrings("total", (comptime scan("SELECT /* amount */ total FROM t")).paths[0]);
    try testing.expectEqualStrings("total", (comptime scan("SELECT -- amount\n total FROM t")).paths[0]);
    // And an expression stays one, so a working statement is not refused.
    try testing.expectEqualStrings("", (comptime scan("SELECT DISTINCT total::text FROM t")).paths[0]);
    try testing.expectEqualStrings("", (comptime scan("SELECT '/* not a comment */' FROM t")).paths[0]);
}

test "lower case reads the same as upper" {
    const found = comptime scan("select id, email from users");
    try testing.expectEqual(@as(?usize, 2), found.count);
    try testing.expectEqualStrings("email", found.names[1]);
}

/// The Dialect these tests hold statements against. `assertList` needs one
/// only to spell the cast it suggests, and Postgres is the one whose spelling
/// the messages were written against.
const Pg = @import("dialect.zig").Postgres;

test "a list that lines up with the Row passes, by name and by count" {
    const Tally = struct { country: []const u8, n: i64 };
    comptime assertList(
        Pg,
        Tally,
        "SELECT u.country, count(*)::bigint AS n FROM users u GROUP BY u.country",
        "db.raw",
    );
}

test "a star is not counted, so a narrow Row over `SELECT *` still compiles" {
    const Narrow = struct { id: i64 };
    comptime assertList(Pg, Narrow, "SELECT * FROM users", "db.raw");
}

test "a column with no name this file will claim is counted and not matched" {
    const Two = struct { id: i64, alive: bool };
    comptime assertList(Pg, Two, "SELECT id, deleted_at IS NULL FROM users", "db.raw");
}

test "a text column asked for as text passes, however the cast is written" {
    const Money = struct { id: i64, total: types.Decimal };
    // The cast nilo would have written itself.
    comptime assertList(Pg, Money, "SELECT id, total::text AS total FROM invoices", "db.raw");
    // And the ones it would not: an alias is not required, and an expression
    // this file cannot read is left alone rather than guessed at.
    comptime assertList(Pg, Money, "SELECT id, i.total::text FROM invoices i", "db.raw");
    comptime assertList(
        Pg,
        Money,
        "SELECT id, coalesce(total::text, '0') AS total FROM invoices",
        "db.raw",
    );
    comptime assertList(Pg, Money, "SELECT id, CAST(total AS text) AS total FROM invoices", "db.raw");
}

test "a column that is not read as text is nobody's business here" {
    const Plain = struct { id: i64, email: []const u8 };
    comptime assertList(Pg, Plain, "SELECT id, email FROM users", "db.raw");
}

test "the shapes a cast cannot be hiding in are the only ones refused" {
    // What the refusal files hold as compile errors, asserted here as the
    // *predicate* they turn on — a bare column, aliased or not, is a path and
    // everything else is not.
    const found = comptime scan(
        "SELECT total, i.total, \"total due\", total::text, CAST(total AS text), " ++
            "coalesce(total::text, '0'), '0', 1, NULL, total AS amount, i.total::text AS amount FROM t i",
    );
    try testing.expectEqualStrings("total", found.paths[0]);
    try testing.expectEqualStrings("i.total", found.paths[1]);
    try testing.expectEqualStrings("\"total due\"", found.paths[2]);
    for (found.paths[3..9]) |p| try testing.expectEqualStrings("", p);
    // The alias comes off, and the column is still a bare one.
    try testing.expectEqualStrings("total", found.paths[9]);
    try testing.expectEqualStrings("", found.paths[10]);
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

// ---- parameters (ADR 204) ----

/// Two dialects for the tests below, spelled the way the real ones spell a
/// placeholder and nothing else: `rawcheck` reads one function off a
/// Dialect and `dialect.zig` is a bigger import than the question needs.
const Dollar = struct {
    pub fn placeholder(comptime n: usize) []const u8 {
        return "$" ++ std.fmt.comptimePrint("{d}", .{n});
    }
};
const Question = struct {
    pub fn placeholder(comptime n: usize) []const u8 {
        return "?" ++ std.fmt.comptimePrint("{d}", .{n});
    }
};

test "the highest $n is read past quotes and comments, and a bare $ is not one" {
    try testing.expectEqual(@as(?usize, 3), comptime highestParam("SELECT a FROM t WHERE b = $1 AND c IN ($3, $2)"));
    // The same number twice is one parameter, which is the shape an `IS NULL`
    // guard takes: `($2 IS NULL OR x = $2)`.
    try testing.expectEqual(@as(?usize, 2), comptime highestParam("WHERE ($2 IS NULL OR o.kabupaten = $2) AND y = $1"));
    // Inside a literal or a comment it is text.
    try testing.expectEqual(@as(?usize, 1), comptime highestParam("SELECT '$9', a -- and $8\nFROM t WHERE b = $1"));
    // Nothing to bind, and nothing numbered: `?1` and a bare `?` are left to
    // the driver.
    try testing.expectEqual(@as(?usize, null), comptime highestParam("SELECT count(*) FROM t"));
    try testing.expectEqual(@as(?usize, null), comptime highestParam("SELECT a FROM t WHERE b = ?1 AND c = ?"));
    // Postgres's dollar quoting has no digits after the `$`.
    try testing.expectEqual(@as(?usize, 1), comptime highestParam("SELECT $$a$$, b FROM t WHERE c = $1"));
}

test "a $n is respelled for a dialect that numbers with ?, and left alone for one that does not" {
    const text = "SELECT a FROM t WHERE ($2 IS NULL OR b = $2) AND c = $1 AND d = '$3'";
    try testing.expectEqualStrings(text, comptime spelled(Dollar, text));
    try testing.expectEqualStrings(
        "SELECT a FROM t WHERE (?2 IS NULL OR b = ?2) AND c = ?1 AND d = '$3'",
        comptime spelled(Question, text),
    );
    // A statement with nothing to respell is the same text, not a copy that
    // differs by a byte somewhere.
    try testing.expectEqualStrings("SELECT count(*) FROM t", comptime spelled(Question, "SELECT count(*) FROM t"));
}

test "a paged statement is the Row's columns and one more" {
    const Line = struct {
        pub const nilo_table = .projection;
        id: i64,
        owner: []const u8,
    };
    // Held rather than refused: three columns for two fields is the window
    // on the end, whatever it is called.
    comptime assertPaged(Dollar, Line, "SELECT o.id, o.owner, count(*) OVER () FROM objects o", "db.rawPage");
    comptime assertPaged(Dollar, Line, "SELECT id, owner, count(*) OVER () AS total FROM objects", "db.rawPage");
    // And a list this file cannot count is left to the run-time width check,
    // the way `assertList` leaves it.
    comptime assertPaged(Dollar, Line, "SELECT * FROM objects", "db.rawPage");
}

test "a page's own offset and limit are found by position, past a cast and a subquery's" {
    const T3 = struct { i64, i64, i64 };
    const T4 = struct { i64, i64, i64, i64 };
    const plain = comptime paging("SELECT id, count(*) OVER () FROM t WHERE a > $1 ORDER BY id LIMIT $2 OFFSET $3", T3, "db.rawPage");
    try testing.expectEqual(@as(?usize, 2), plain.offset);
    try testing.expectEqual(@as(?usize, 1), plain.limit);

    // The port's shape: a cast on each, and `ROWS` after the offset.
    const cast = comptime paging("SELECT id, count(*) OVER () FROM t ORDER BY id LIMIT $13::int OFFSET $14 :: int ROWS", struct { i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64 }, "db.rawPage");
    try testing.expectEqual(@as(?usize, 13), cast.offset);
    try testing.expectEqual(@as(?usize, 12), cast.limit);

    // A subquery's clauses are its own; the page's are the outer ones.
    const inner = comptime paging(
        "SELECT id, count(*) OVER () FROM (SELECT id FROM t LIMIT $1 OFFSET $2) s ORDER BY id LIMIT $3 OFFSET $4",
        T4,
        "db.rawPage",
    );
    try testing.expectEqual(@as(?usize, 3), inner.offset);
    try testing.expectEqual(@as(?usize, 2), inner.limit);

    // Nothing skipped: no offset at all, or a written zero.
    const first = comptime paging("SELECT id, count(*) OVER () FROM t ORDER BY id LIMIT 20", struct {}, "db.rawPage");
    try testing.expectEqual(@as(?usize, null), first.offset);
    try testing.expectEqual(@as(?usize, null), first.limit);
    try testing.expectEqual(@as(?usize, null), (comptime paging("SELECT 1, 2 FROM t LIMIT 5 OFFSET 0", struct {}, "db.rawPage")).offset);

    // A limit whose placeholder is also a condition cannot be set to one on
    // the second ask, so it is left as it is.
    const shared = comptime paging("SELECT id, count(*) OVER () FROM t WHERE rn <= $1 ORDER BY id LIMIT $1 OFFSET $2", struct { i64, i64 }, "db.rawPage");
    try testing.expectEqual(@as(?usize, null), shared.limit);
    try testing.expectEqual(@as(?usize, 1), shared.offset);
}

// ---- what Postgres runs and the reader used to refuse (roadmap: defects) ----

test "a trailing comment or semicolon is not part of the alias" {
    const found = comptime scan("SELECT id, email AS mail -- the address\n FROM users;");
    try testing.expectEqual(@as(?usize, 2), found.count);
    try testing.expectEqualStrings("mail", found.names[1]);
    // No FROM to end the list, only the comment and the `;`.
    const bare_list = comptime scan("SELECT 1 AS a, 2 AS b /* two */ ; ");
    try testing.expectEqual(@as(?usize, 2), bare_list.count);
    try testing.expectEqualStrings("b", bare_list.names[1]);
    const Row = struct { id: i64, mail: []const u8 };
    comptime assertList(Pg, Row, "SELECT id, email AS mail -- the address\n FROM users;", "db.raw");
    // And a real disagreement is still one: the names are compared.
    try testing.expect(!nameFits("email", false, "mail"));
}

test "IS DISTINCT FROM is inside a column and does not end the list" {
    const found = comptime scan("SELECT a IS DISTINCT FROM b AS changed, c IS NOT DISTINCT FROM d, e FROM t");
    try testing.expectEqual(@as(?usize, 3), found.count);
    try testing.expectEqualStrings("changed", found.names[0]);
    // And the FROM after a DISTINCT that opens the list is not there at all.
    try testing.expectEqual(@as(?usize, 2), (comptime scan("SELECT DISTINCT a, b FROM t")).count);
}

test "a star is only a star where a column could be all columns" {
    // Multiplication: neither is a star, and both are counted.
    const product = comptime scan("SELECT price * qty AS line, count(*) * 2, (a) * 3 FROM t");
    try testing.expectEqual(@as(?usize, 3), product.count);
    try testing.expect(!product.starred);
    try testing.expectEqualStrings("line", product.names[0]);
    // A `Decimal` behind a product is not refused as though it were a `*`.
    const Money = struct { line: types.Decimal };
    comptime assertList(Pg, Money, "SELECT price * qty AS line FROM t", "db.raw");
    // The stars that are stars.
    try testing.expect((comptime scan("SELECT * FROM t")).starred);
    try testing.expect((comptime scan("SELECT t.*, x FROM t")).starred);
    try testing.expect((comptime scan("SELECT DISTINCT * FROM t")).starred);
    try testing.expect((comptime scan("SELECT ALL * FROM t")).starred);
    try testing.expect((comptime scan("SELECT DISTINCT ON (a) * FROM t")).starred);
    // `2*-1` is a `*` and a `-`.
    try testing.expectEqual(@as(?usize, 2), (comptime scan("SELECT 2*-1, 3 FROM t")).count);
}

test "an unquoted name is folded to lower case and a quoted one is kept" {
    const found = comptime scan("SELECT ID, u.Email, \"Total\" AS \"Total\", n AS Alias FROM u");
    try testing.expectEqualStrings("id", found.names[0]);
    try testing.expectEqualStrings("email", found.names[1]);
    try testing.expectEqualStrings("Total", found.names[2]);
    try testing.expect(found.quoted[2]);
    try testing.expectEqualStrings("alias", found.names[3]);
    comptime assertList(Pg, struct { id: i64 }, "SELECT ID FROM t", "db.raw");
    // A quoted name is exactly what it says; an unquoted one is what the
    // database folded, so a field of another case still fits it.
    try testing.expect(nameFits("id", false, "ID"));
    try testing.expect(!nameFits("ID", true, "id"));
    try testing.expect(nameFits("ID", true, "ID"));
}

test "dollar quotes and E strings hide what is inside them" {
    // Commas, keywords and `$5` inside the bodies are text.
    const found = comptime scan("SELECT $$a, FROM $5$$ AS one, $tag$b, $6$tag$, E'\\'', 2, E'a\\\\', 3 FROM t WHERE x = $1");
    try testing.expectEqual(@as(?usize, 6), found.count);
    try testing.expectEqualStrings("one", found.names[0]);
    try testing.expectEqual(@as(?usize, 1), comptime highestParam("SELECT $$ $5 $$, $t$ $7 $t$, E'\\' $9', 1 WHERE a = $1"));
    // The parameter count sees the same statement.
    comptime assertParams("SELECT $$ $5 $$ WHERE a = $1", struct { i64 }, "db.raw");
    // A `$` glued to a word, or with nothing after it, is not a parameter.
    try testing.expectEqual(@as(?usize, null), comptime highestParam("SELECT a$1, $x FROM t"));
    // A plain string does not escape with a backslash (standard strings).
    try testing.expectEqual(@as(?usize, 2), (comptime scan("SELECT 'a\\', 'b' FROM t")).count);
    // What is not finished is nobody's to read.
    try testing.expectEqual(@as(?usize, null), (comptime scan("SELECT $$a, b FROM t")).count);
    try testing.expectEqual(@as(?usize, null), (comptime scan("SELECT 'a, b FROM t")).count);
    try testing.expectEqual(@as(?usize, null), comptime highestParam("SELECT 'a $3"));
}

test "block comments nest" {
    const found = comptime scan("SELECT a /* one /* two, three */ still comment, */, b FROM t");
    try testing.expectEqual(@as(?usize, 2), found.count);
    try testing.expectEqual(@as(?usize, 1), comptime highestParam("SELECT 1 /* /* $9 */ $8 */ WHERE a = $1"));
}

test "EXCEPT and INTERSECT end the list like UNION" {
    try testing.expectEqual(@as(?usize, 1), (comptime scan("SELECT 1 EXCEPT SELECT 2, 3")).count);
    try testing.expectEqual(@as(?usize, 2), (comptime scan("SELECT 1, 2 INTERSECT SELECT 3")).count);
    try testing.expectEqual(@as(?usize, 1), (comptime scan("SELECT a FROM t EXCEPT SELECT b FROM u")).count);
}

test "a keyword that is a qualified name or an alias is not the keyword" {
    const found = comptime scan("SELECT p.offset, p.limit, n AS offset, p.\"from\" FROM p");
    try testing.expectEqual(@as(?usize, 4), found.count);
    try testing.expectEqualStrings("offset", found.names[0]);
    try testing.expectEqualStrings("limit", found.names[1]);
    try testing.expectEqualStrings("offset", found.names[2]);
    // And the clauses of a page are still the page's.
    const page = comptime paging("SELECT p.offset, count(*) OVER () FROM p ORDER BY p.limit LIMIT $1 OFFSET $2", struct { i64, i64 }, "db.rawPage");
    try testing.expectEqual(@as(?usize, 1), page.offset);
    try testing.expectEqual(@as(?usize, 0), page.limit);
}

test "SQLite's backticks quote a name like double quotes do" {
    const found = comptime scan("SELECT `a,b`, t.`c d` AS `e`, x FROM t");
    try testing.expectEqual(@as(?usize, 3), found.count);
    try testing.expectEqualStrings("a,b", found.names[0]);
    try testing.expectEqualStrings("e", found.names[1]);
}

test "a gap in the placeholders is refused, and a full run is not" {
    // `$1` and `$3` with three values: the second value has nothing to go to.
    const gap = comptime paramMisfit("SELECT a FROM t WHERE b = $1 AND c = $3", 3).?;
    try testing.expect(gap.kind == .gap);
    try testing.expectEqual(@as(usize, 2), gap.missing);
    // The count is still what it was.
    const short = comptime paramMisfit("SELECT a FROM t WHERE b = $1 AND c = $2", 1).?;
    try testing.expect(short.kind == .count);
    try testing.expectEqual(@as(usize, 2), short.highest);
    // Out of order and repeated are fine, the way an `IS NULL` guard is.
    try testing.expectEqual(@as(?ParamMisfit, null), comptime paramMisfit("WHERE ($2 IS NULL OR x = $2) AND y = $1", 2));
    // A `$5` inside a literal is not a use, and a `$2` in one is not either.
    try testing.expect((comptime paramMisfit("SELECT '$2', $$ $2 $$ WHERE a = $1 AND b = $3", 3)).?.kind == .gap);
    try testing.expectEqual(@as(?ParamMisfit, null), comptime paramMisfit("SELECT $$ $5 $$ WHERE a = $1", 1));
    // Nothing to bind.
    try testing.expectEqual(@as(?ParamMisfit, null), comptime paramMisfit("SELECT count(*) FROM t", 0));
}

test "SQLite's own numbered placeholders are held the same way" {
    const gap = comptime paramMisfit("SELECT a FROM t WHERE b=?1 AND c=?3", 3).?;
    try testing.expect(gap.kind == .gap);
    try testing.expectEqualStrings("?", gap.mark);
    try testing.expectEqual(@as(usize, 2), gap.missing);
    const short = comptime paramMisfit("SELECT a FROM t WHERE b = ?1 AND c = ?2", 1).?;
    try testing.expect(short.kind == .count);
    try testing.expectEqual(@as(?ParamMisfit, null), comptime paramMisfit("SELECT a FROM t WHERE b = ?2 AND c = ?1", 2));
    // A bare `?` takes the next free number, which is not tracked here, and
    // on Postgres it is an operator: neither is asked anything.
    try testing.expectEqual(@as(?ParamMisfit, null), comptime paramMisfit("SELECT a FROM t WHERE b = ? AND c = ?3", 3));
    try testing.expectEqual(@as(?ParamMisfit, null), comptime paramMisfit("SELECT a FROM t WHERE data ?| $$x$$", 0));
    // And `$n` wins when the text has both.
    try testing.expectEqual(@as(?ParamMisfit, null), comptime paramMisfit("SELECT a FROM t WHERE b = $1 AND c = ?7", 1));
}

test "respelling leaves a dollar quote alone" {
    const text = "SELECT $$ $1 $$, a FROM t WHERE b = $1 AND c = E'\\' $2'";
    try testing.expectEqualStrings(
        "SELECT $$ $1 $$, a FROM t WHERE b = ?1 AND c = E'\\' $2'",
        comptime spelled(Question, text),
    );
}
