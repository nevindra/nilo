//! An `ORDER BY` chosen at run time, from a closed set declared while
//! compiling ([ADR 165](../docs/adr/165-an-order-chosen-at-run-time-from-a-closed-set.md)).
//!
//! `.order = .{ .created_at = .desc }` is settled while compiling, and
//! `Direction`'s own comment says why: a sort chosen at run time is two
//! statements. A list screen with fifteen sortable headings and three tiers
//! is twenty thousand, and the port that hit that wrote a page of `CASE WHEN
//! $13 = 'due:asc' THEN c.due_date END ASC` — ninety-six terms, sent on every
//! request, to say what `ORDER BY c.due_date ASC` says in six words.
//!
//! This is the other reading of "two statements": the *pieces* are settled
//! while compiling, and which of them are live is decided per request.
//!
//! ```zig
//! const Sort = sql.Ordering(Commitment, .{
//!     .due = .due_date,                                  // a column, quoted
//!     .title = .{ .column = .title, .nulls = .last },    // and where NULLs go
//!     .value = "c.value_currency, c.value_minor",        // the caller's own SQL
//! });
//!
//! fn list(db: *sql.Db, c: *nilo.Ctx, q: nilo.Query(struct {
//!     order: Sort = Sort.by(&.{.{ .key = .due }}),
//! })) !sql.Page(Commitment) {
//!     return db.page(Commitment, c, .{ .order = q.value.order, .limit = 20 });
//! }
//! ```
//!
//! `?order=due:desc,title` reads straight into the field: the type parses
//! itself (`nilo_parse`, ADR 113), so a key that is not one of the three is
//! the same 400 a bad number gets, and the document says the field is text.
//!
//! **What stays true is that no run-time string reaches the statement.** A
//! term is an index into a table of fragments built while compiling, one per
//! key per direction, and the clause is those fragments written in order.
//! The request decides *which*; it never decides *what*.
//!
//! **What is given up is the plan name.** A statement whose text is assembled
//! per request is not a constant, and ADR 051's argument for keeping one
//! prepared is that the set of names a program can use is fixed when it is
//! built — here it is fixed too, but at (2·keys)^tiers, and a cache that size
//! on every pooled connection is not a cache. So an ordered statement runs
//! unnamed, which is the 12 µs a prepared statement was measured to save
//! (`bench/result/sql.md`), on a read that is usually the widest in the
//! program. The text itself is one arena allocation, sized while compiling.

const std = @import("std");
const statement = @import("statement.zig");
const dialect_mod = @import("dialect.zig");
const row_mod = @import("row.zig");

pub const Direction = statement.Direction;

/// The declaration an ordering carries — the Row it was declared for. Read
/// by name, the way every marker here is.
pub const marker = "nilo_ordering";

/// The text a raw statement leaves for the clause
/// (`db.rawOrdered`). The whole clause goes there, `ORDER BY` included.
pub const hole = "{order}";

/// One thing a list can be ordered by, as the caller declared it.
const Key = struct {
    /// What the request says: `due`.
    name: []const u8,
    /// A column of the Row, to be quoted by the Dialect — or null when the
    /// key is an expression.
    column: ?[]const u8,
    /// The caller's own SQL, sent as written — or null when the key is a
    /// column.
    expr: ?[]const u8,
    /// Where NULLs go under either direction, when the caller said.
    nulls: ?dialect_mod.Nulls,
};

/// The orderings a list can be read in, declared once.
///
/// `keys` is a struct of names: each field is what a request may say, and its
/// value is what that means — an enum literal naming a column of `Row`, a
/// string of the caller's own SQL, or a struct `.{ .column = …, .nulls =
/// .last }` / `.{ .expr = …, .nulls = .last }` saying where NULLs go as well.
///
/// A column is checked against the Row and quoted by the Dialect, so it may
/// order a `db.select` or a `db.page`. An expression is text this module did
/// not write, so it is for `db.rawOrdered` alone — the same line `db.raw`
/// draws, one clause narrower.
pub fn Ordering(comptime Row: type, comptime keys: anytype) type {
    const specs = comptime readKeys(Row, keys);
    return struct {
        const Self = @This();

        /// The Row this ordering was declared for. A statement on another
        /// Row is refused, because the columns were checked against this one.
        pub const nilo_ordering = Row;

        /// What a nilo compile error calls this type (ADR 074).
        pub const nilo_type_name = "sql.Ordering(" ++ @typeName(Row) ++ ")";

        /// What a 400 says the value has to be, in place of the type's name.
        pub const nilo_expects = "an ordering by " ++ spelled() ++
            ", each with an optional :asc or :desc, comma-separated";

        /// Text on the wire — `due:desc,title` — and said so, so a document
        /// generated from a query struct carrying one describes a string.
        pub const nilo_openapi = .{ .type = "string" };

        /// The keys, as an enum: `.due`, `.title`.
        pub const Key = KeyEnum(specs);

        /// One tier of the order: a key and which way it runs.
        pub const Term = struct {
            key: Self.Key,
            direction: Direction = .asc,
        };

        /// As many tiers as there are keys — past that a term repeats one.
        pub const max = specs.len;

        terms: [max]Term = undefined,
        len: usize = 0,

        /// An ordering built by the caller — from its own parsing, or as the
        /// default a query field falls back to. At least one term, and at
        /// most `max`.
        pub fn by(terms: []const Term) Self {
            std.debug.assert(terms.len > 0 and terms.len <= max);
            var self: Self = .{};
            for (terms, 0..) |t, i| self.terms[i] = t;
            self.len = terms.len;
            return self;
        }

        /// The tiers, in the order they apply.
        pub fn chosen(self: *const Self) []const Term {
            return self.terms[0..self.len];
        }

        /// `due:desc,title` — one key per term, `:asc` or `:desc` behind it
        /// or nothing for ascending. A key that is not declared, an empty
        /// term, and more terms than keys are all null, which is the 400 a
        /// bad number gets (ADR 113).
        pub fn nilo_parse(text: []const u8) ?Self {
            var self: Self = .{};
            var pieces = std.mem.splitScalar(u8, text, ',');
            while (pieces.next()) |piece| {
                if (self.len == max) return null;
                const colon = std.mem.indexOfScalar(u8, piece, ':');
                const name = if (colon) |at| piece[0..at] else piece;
                const key = std.meta.stringToEnum(Self.Key, name) orelse return null;
                const direction: Direction = if (colon) |at| blk: {
                    const said = piece[at + 1 ..];
                    if (std.mem.eql(u8, said, "asc")) break :blk .asc;
                    if (std.mem.eql(u8, said, "desc")) break :blk .desc;
                    return null;
                } else .asc;
                self.terms[self.len] = .{ .key = key, .direction = direction };
                self.len += 1;
            }
            if (self.len == 0) return null;
            return self;
        }

        /// The clause, ` ORDER BY …` with the space in front, in `D`'s
        /// grammar. Every byte written is a fragment settled while compiling;
        /// the request only chose which ones.
        pub fn write(self: *const Self, comptime D: type, w: *std.Io.Writer) !void {
            const table = comptime fragments(D);
            for (self.chosen(), 0..) |t, i| {
                try w.writeAll(if (i == 0) " ORDER BY " else ", ");
                try w.writeAll(table[@intFromEnum(t.key)][@intFromEnum(t.direction)]);
            }
        }

        /// The longest clause `write` can produce in `D`'s grammar, so the
        /// statement it goes into can be sized while compiling.
        pub fn most(comptime D: type) usize {
            return comptime blk: {
                var longest: usize = 0;
                for (fragments(D)) |per_key| {
                    for (per_key) |frag| longest = @max(longest, frag.len);
                }
                break :blk " ORDER BY ".len + max * (longest + ", ".len);
            };
        }

        /// Whether every key names a column, which is what a statement this
        /// module writes needs — an expression is text it did not write.
        pub fn onlyColumns() bool {
            return comptime blk: {
                for (specs) |s| if (s.expr != null) break :blk false;
                break :blk true;
            };
        }

        /// The first key that is an expression, for the message that refuses
        /// it on a typed statement.
        pub fn firstExpression() []const u8 {
            return comptime blk: {
                for (specs) |s| if (s.expr != null) break :blk s.name;
                unreachable;
            };
        }

        /// One fragment per key per direction: `"due_date" ASC NULLS LAST`.
        fn fragments(comptime D: type) [max][directions][]const u8 {
            return comptime blk: {
                var bytes: usize = 0;
                for (specs) |s| bytes += (s.column orelse s.expr.?).len;
                @setEvalBranchQuota(10_000 + 8 * directions * (bytes + specs.len * 24));

                var out: [max][directions][]const u8 = undefined;
                for (specs, 0..) |s, i| {
                    const what = if (s.column) |c| D.quote(c) else s.expr.?;
                    for (@typeInfo(Direction).@"enum".fields) |f| {
                        const d: Direction = @field(Direction, f.name);
                        var frag: []const u8 = what ++ (if (d.descending()) " DESC" else " ASC");
                        // The term's own placement wins; the key's is what
                        // applies when the request said only which way.
                        const placed: ?dialect_mod.Nulls = if (d.placement()) |p| p else s.nulls;
                        if (placed) |where_nulls| {
                            frag = frag ++ (D.nulls(where_nulls) orelse
                                dialect_mod.noNullsOrder(D, Row, s.name));
                        }
                        out[i][f.value] = frag;
                    }
                }
                break :blk out;
            };
        }

        /// `due, title or value`, for the sentence a 400 carries.
        fn spelled() []const u8 {
            var out: []const u8 = "";
            for (specs, 0..) |s, i| {
                const sep = if (i == 0) "" else if (i + 1 == specs.len) " or " else ", ";
                out = out ++ sep ++ s.name;
            }
            return out;
        }
    };
}

const directions = @typeInfo(Direction).@"enum".fields.len;

/// Whether `T` is an `Ordering`, and for which Row.
pub fn orderingOf(comptime T: type) ?type {
    comptime {
        return switch (@typeInfo(T)) {
            .@"struct" => if (@hasDecl(T, marker)) @field(T, marker) else null,
            else => null,
        };
    }
}

/// Hold an ordering against the Row of the statement it is being used on,
/// and against what that statement can carry. `call` is what the caller
/// wrote — `db.select`, `db.rawOrdered` — so the message points at it.
pub fn assertFor(
    comptime T: type,
    comptime Row: type,
    comptime call: []const u8,
    comptime typed: bool,
) void {
    comptime {
        const For = orderingOf(T) orelse @compileError(
            "nilo: " ++ call ++ " on " ++ @typeName(Row) ++ " was given a " ++ @typeName(T) ++
                " as its ordering.\n" ++
                "  An ordering chosen at run time is a `sql.Ordering(Row, .{ … })` — declare " ++
                "the keys once, and hand over the value the request chose: `Sort.by(&.{ … })`, " ++
                "or a query field of that type.",
        );
        if (For != Row) @compileError(
            "nilo: " ++ call ++ " on " ++ @typeName(Row) ++ " was given an ordering declared " ++
                "for " ++ @typeName(For) ++ ".\n" ++
                "  The keys were checked against that Row's columns, so it orders that Row " ++
                "and no other. Declare one for " ++ @typeName(Row) ++ ".",
        );
        if (typed and !T.onlyColumns()) @compileError(
            "nilo: " ++ call ++ " on " ++ @typeName(Row) ++ " was given an ordering whose key `" ++
                T.firstExpression() ++ "` is an expression, and a statement nilo writes " ++
                "orders by columns.\n" ++
                "  Name the column — `.{ ." ++ T.firstExpression() ++ " = .<column> }` — or " ++
                "write the statement yourself and hand the ordering to `db.rawOrdered`.",
        );
    }
}

/// The text on either side of `{order}` in a raw statement, or a Refusal
/// when the hole is not there exactly once.
pub const Split = struct { head: []const u8, tail: []const u8 };

pub fn split(comptime sql: []const u8, comptime call: []const u8) Split {
    return comptime blk: {
        @setEvalBranchQuota(20 * sql.len + 1_000);
        const at = std.mem.indexOf(u8, sql, hole) orelse @compileError(
            "nilo: the statement handed to " ++ call ++ " has no `" ++ hole ++ "` in it, so " ++
                "there is nowhere to write the ordering.\n" ++
                "  Put `" ++ hole ++ "` where the whole `ORDER BY` clause goes — after the " ++
                "`WHERE`, before any `LIMIT`: `… WHERE c.state = $1 " ++ hole ++ " LIMIT $2`.",
        );
        const rest = sql[at + hole.len ..];
        if (std.mem.indexOf(u8, rest, hole) != null) @compileError(
            "nilo: the statement handed to " ++ call ++ " has `" ++ hole ++ "` in it twice, " ++
                "and one ordering goes in one place.\n" ++
                "  A statement ordered in two places — a subquery and its outer query — is " ++
                "two orderings, and only the outer one is this one.",
        );
        // The clause carries its own leading space, so whatever the caller
        // put before the hole is trimmed and whatever comes after it keeps
        // one — `?1 {order} LIMIT` and `?1{order}LIMIT` write the same text.
        const head = std.mem.trimEnd(u8, sql[0..at], " \t\r\n");
        const tail = if (rest.len == 0 or std.ascii.isWhitespace(rest[0])) rest else " " ++ rest;
        break :blk .{ .head = head, .tail = tail };
    };
}

/// `keys`, read field by field and checked against the Row.
fn readKeys(comptime Row: type, comptime keys: anytype) []const Key {
    comptime {
        const K = @TypeOf(keys);
        if (@typeInfo(K) != .@"struct" or @typeInfo(K).@"struct".is_tuple) @compileError(
            "nilo: `sql.Ordering(" ++ @typeName(Row) ++ ", …)` was given a " ++ @typeName(K) ++
                " as its keys, and the keys are a struct of names.\n" ++
                "  Each field is what a request may say, and its value is what that means: " ++
                "`.{ .due = .due_date, .title = \"lower(title)\" }`.",
        );
        const fields = @typeInfo(K).@"struct".fields;
        if (fields.len == 0) @compileError(
            "nilo: `sql.Ordering(" ++ @typeName(Row) ++ ", .{})` declares no keys, so " ++
                "there is nothing a request could choose.\n" ++
                "  Name at least one: `.{ .due = .due_date }`.",
        );
        var out: []const Key = &.{};
        for (fields) |f| {
            const said = @field(keys, f.name);
            out = out ++ [_]Key{readKey(Row, f.name, said)};
        }
        return out;
    }
}

fn readKey(comptime Row: type, comptime name: []const u8, comptime said: anytype) Key {
    comptime {
        const S = @TypeOf(said);
        if (S == @TypeOf(.enum_literal) or isPath(S)) {
            return .{ .name = name, .column = columnOf(Row, name, said), .expr = null, .nulls = null };
        }
        if (isText(S)) {
            return .{ .name = name, .column = null, .expr = textOf(Row, name, said), .nulls = null };
        }
        if (@typeInfo(S) == .@"struct" and !@typeInfo(S).@"struct".is_tuple) {
            var key = Key{ .name = name, .column = null, .expr = null, .nulls = null };
            for (@typeInfo(S).@"struct".fields) |f| {
                if (std.mem.eql(u8, f.name, "column")) {
                    key.column = columnOf(Row, name, said.column);
                } else if (std.mem.eql(u8, f.name, "expr")) {
                    key.expr = textOf(Row, name, said.expr);
                } else if (std.mem.eql(u8, f.name, "nulls")) {
                    key.nulls = nullsOf(Row, name, said.nulls);
                } else @compileError(
                    "nilo: the ordering key `" ++ name ++ "` on " ++ @typeName(Row) ++ " says `." ++
                        f.name ++ "`, which is not something a key can say.\n" ++
                        "  A key is `.column` or `.expr`, and may add `.nulls = .first` or `.last`.",
                );
            }
            if (key.column == null and key.expr == null) @compileError(
                "nilo: the ordering key `" ++ name ++ "` on " ++ @typeName(Row) ++ " names " ++
                    "neither a `.column` nor an `.expr`, so there is nothing to order by.\n" ++
                    "  `.{ .column = .due_date, .nulls = .last }` or `.{ .expr = \"c.due_date\", .nulls = .last }`.",
            );
            if (key.column != null and key.expr != null) @compileError(
                "nilo: the ordering key `" ++ name ++ "` on " ++ @typeName(Row) ++ " names " ++
                    "both a `.column` and an `.expr`, and one term orders by one thing.\n" ++
                    "  Keep the column, or keep the expression.",
            );
            return key;
        }
        @compileError(
            "nilo: the ordering key `" ++ name ++ "` on " ++ @typeName(Row) ++ " is a " ++
                @typeName(S) ++ ", which is not something a key can be.\n" ++
                "  A key is a column of the Row (`.due_date`), the caller's own SQL " ++
                "(`\"c.due_date\"`), or a struct saying either plus where NULLs go " ++
                "(`.{ .column = .due_date, .nulls = .last }`).",
        );
    }
}

/// The column a key names, spelled the way the answer carries it.
///
/// **A shaped Row is ordered by the names in its answer**
/// ([ADR 218](../docs/adr/218-a-row-may-carry-its-parent-its-children-or-a-sum.md)):
/// an aggregate by its field, and a parent's column by the path to it,
/// `.{ .customer, .name }`, answered as `"customer.name"`. A flat Row's
/// columns are the one-element case of the same thing.
fn columnOf(comptime Row: type, comptime name: []const u8, comptime said: anytype) []const u8 {
    comptime {
        const what = "the ordering key `" ++ name ++ "`";
        if (@TypeOf(said) == @TypeOf(.enum_literal)) {
            const column = @tagName(said);
            if (row_mod.hasColumn(Row, column)) return column;
            if (row_mod.fieldTypeOf(Row, column) != null) switch (row_mod.kindOf(Row, column)) {
                .aggregate, .count => return column,
                else => {},
            };
            row_mod.noSuchColumn(Row, column, what);
        }
        if (!isPath(@TypeOf(said))) @compileError(
            "nilo: " ++ what ++ " on " ++ @typeName(Row) ++ " names its column with a " ++
                @typeName(@TypeOf(said)) ++ ".\n" ++
                "  A column is `.due_date`, and a parent's column is the path to it: " ++
                "`.{ .customer, .name }`.",
        );
        var Level = Row;
        var path: []const []const u8 = &.{};
        for (said, 0..) |step, i| {
            const field = @tagName(step);
            path = path ++ &[_][]const u8{field};
            if (i + 1 == said.len) {
                if (!row_mod.hasColumn(Level, field)) row_mod.noSuchColumn(Level, field, what);
                break;
            }
            const T = row_mod.fieldTypeOf(Level, field) orelse row_mod.noSuchColumn(Level, field, what);
            if (row_mod.kindOf(Level, field) != .parent) @compileError(
                "nilo: " ++ what ++ " on " ++ @typeName(Row) ++ " goes through `" ++ field ++
                    "`, which is not a parent.\n" ++
                    "  A path steps into a field that holds the row a reference points at, and " ++
                    "ends on one of that row's columns.",
            );
            Level = row_mod.parentRowOf(T).?;
        }
        return row_mod.pathName(path);
    }
}

/// A tuple of two or more enum literals: a path to a parent's column.
fn isPath(comptime S: type) bool {
    comptime {
        const info = switch (@typeInfo(S)) {
            .@"struct" => |s| s,
            else => return false,
        };
        if (!info.is_tuple or info.fields.len < 2) return false;
        for (info.fields) |f| if (f.type != @TypeOf(.enum_literal)) return false;
        return true;
    }
}

fn textOf(comptime Row: type, comptime name: []const u8, comptime expr: []const u8) []const u8 {
    comptime {
        if (std.mem.trim(u8, expr, " \t\r\n").len == 0) @compileError(
            "nilo: the ordering key `" ++ name ++ "` on " ++ @typeName(Row) ++ " is an empty " ++
                "expression, which would leave a term with nothing in it.\n" ++
                "  Write the SQL the term sorts by: `\"c.due_date\"`.",
        );
        return expr;
    }
}

fn nullsOf(comptime Row: type, comptime name: []const u8, comptime said: anytype) dialect_mod.Nulls {
    comptime {
        const tag = @tagName(said);
        if (std.mem.eql(u8, tag, "first")) return .first;
        if (std.mem.eql(u8, tag, "last")) return .last;
        @compileError(
            "nilo: the ordering key `" ++ name ++ "` on " ++ @typeName(Row) ++ " says " ++
                "`.nulls = ." ++ tag ++ "`, and NULLs go `.first` or `.last`.",
        );
    }
}

fn isText(comptime S: type) bool {
    comptime {
        return switch (@typeInfo(S)) {
            .pointer => |p| switch (p.size) {
                .slice => p.child == u8,
                .one => switch (@typeInfo(p.child)) {
                    .array => |a| a.child == u8,
                    else => false,
                },
                else => false,
            },
            else => false,
        };
    }
}

/// The keys as an exhaustive enum, in the order they were declared — which
/// is the index into the fragment table.
fn KeyEnum(comptime specs: []const Key) type {
    comptime {
        var names: [specs.len][:0]const u8 = undefined;
        for (specs, 0..) |s, i| names[i] = s.name ++ "";
        const Tag = std.math.IntFittingRange(0, specs.len -| 1);
        return @Enum(Tag, .exhaustive, &names, &std.simd.iota(Tag, specs.len));
    }
}

// ---- tests ----

const testing = std.testing;

const Ticket = struct {
    pub const nilo_table = .{ .name = "tickets", .key = .id };
    id: i64,
    title: []const u8,
    due_at: ?i64,
    weight: i32,
};

const Sort = Ordering(Ticket, .{
    .due = .{ .column = .due_at, .nulls = .last },
    .title = .title,
    .weight = "abs(weight)",
});

fn clauseOf(comptime D: type, order: Sort) ![]const u8 {
    var buf: [Sort.most(D)]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try order.write(D, &w);
    return try testing.allocator.dupe(u8, w.buffered());
}

test "a term is a fragment settled while compiling, written in the order the request chose" {
    const chosen = Sort.by(&.{
        .{ .key = .due, .direction = .desc },
        .{ .key = .title },
    });
    const text = try clauseOf(dialect_mod.Postgres, chosen);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(" ORDER BY \"due_at\" DESC NULLS LAST, \"title\" ASC", text);
}

test "the request says which way, and the key says where NULLs go under either" {
    const asc = try clauseOf(dialect_mod.Postgres, Sort.nilo_parse("due:asc").?);
    defer testing.allocator.free(asc);
    try testing.expectEqualStrings(" ORDER BY \"due_at\" ASC NULLS LAST", asc);

    const desc = try clauseOf(dialect_mod.Postgres, Sort.nilo_parse("due:desc").?);
    defer testing.allocator.free(desc);
    try testing.expectEqualStrings(" ORDER BY \"due_at\" DESC NULLS LAST", desc);

    // A term that says where NULLs go itself is not overruled by the key.
    const own = try clauseOf(dialect_mod.Postgres, Sort.by(&.{.{ .key = .due, .direction = .asc_nulls_first }}));
    defer testing.allocator.free(own);
    try testing.expectEqualStrings(" ORDER BY \"due_at\" ASC NULLS FIRST", own);
}

test "an expression key is sent as the caller wrote it" {
    const text = try clauseOf(dialect_mod.SQLite, Sort.nilo_parse("weight:desc,title").?);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(" ORDER BY abs(weight) DESC, \"title\" ASC", text);
}

test "the text a request sends is read the way a query field is read, and what is not one is null" {
    const one = Sort.nilo_parse("title").?;
    try testing.expectEqual(@as(usize, 1), one.len);
    try testing.expectEqual(Sort.Key.title, one.terms[0].key);
    try testing.expectEqual(Direction.asc, one.terms[0].direction);

    const three = Sort.nilo_parse("due:desc,title:asc,weight").?;
    try testing.expectEqual(@as(usize, 3), three.len);
    try testing.expectEqual(Direction.desc, three.terms[0].direction);

    try testing.expectEqual(@as(?Sort, null), Sort.nilo_parse(""));
    try testing.expectEqual(@as(?Sort, null), Sort.nilo_parse("nope"));
    try testing.expectEqual(@as(?Sort, null), Sort.nilo_parse("due:sideways"));
    try testing.expectEqual(@as(?Sort, null), Sort.nilo_parse("due,,title"));
    try testing.expectEqual(@as(?Sort, null), Sort.nilo_parse("due,title,weight,due"));
    try testing.expectEqual(@as(?Sort, null), Sort.nilo_parse("DUE"));
}

test "the widest clause is known while compiling, and a clause never exceeds it" {
    // Three keys, each at most `"due_at" DESC NULLS LAST` wide, plus the
    // keyword and two separators.
    const widest = comptime Sort.most(dialect_mod.Postgres);
    try testing.expect(widest >= " ORDER BY ".len + 3 * "\"due_at\" DESC NULLS LAST".len + 2 * ", ".len);

    var buf: [widest]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try Sort.nilo_parse("due:desc,weight:desc,title:desc").?.write(dialect_mod.Postgres, &w);
    try testing.expect(w.buffered().len <= widest);
}

test "a raw statement is split at its one hole, and the spacing around it is the clause's" {
    const parts = comptime split("SELECT id FROM t WHERE x = $1 {order} LIMIT $2", "db.rawOrdered");
    try testing.expectEqualStrings("SELECT id FROM t WHERE x = $1", parts.head);
    try testing.expectEqualStrings(" LIMIT $2", parts.tail);

    const tight = comptime split("SELECT id FROM t{order}", "db.rawOrdered");
    try testing.expectEqualStrings("SELECT id FROM t", tight.head);
    try testing.expectEqualStrings("", tight.tail);

    const closed = comptime split("SELECT * FROM (SELECT id FROM t {order}) AS s", "db.rawOrdered");
    try testing.expectEqualStrings(" ) AS s", closed.tail);
}

test "what a 400 says an ordering has to be names every key" {
    try testing.expectEqualStrings(
        "an ordering by due, title or weight, each with an optional :asc or :desc, comma-separated",
        Sort.nilo_expects,
    );
    try testing.expect(Sort.onlyColumns() == false);
    try testing.expect(Ordering(Ticket, .{ .due = .due_at }).onlyColumns());
}
