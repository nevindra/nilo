//! Comparing a Row to the table it claims to read (ADR 036).
//!
//! The struct describes what it reads; the database owns what is there. When
//! they disagree, somebody has to be told, and the question is only when.
//!
//! **The comparison runs once, on the first connection that succeeds** — not
//! at `listen()`. Checking at `listen()` was the first draft and it was wrong
//! in a specific way: it makes the server refuse to start whenever Postgres is
//! briefly unreachable, so a rolling restart during a database blip becomes an
//! outage, and a developer working on routes that touch nothing still needs a
//! database running.
//!
//! Tying it to the connection instead puts the choice where it already lives.
//! pg.zig's pool takes `connect_on_init_count`: left at its default it dials
//! during `init`, so the check happens at boot; set to `0` the pool comes up
//! without touching Postgres and the check happens whenever the first query
//! does. nilo therefore adds **no option of its own**. A `check_schema =
//! false` was drafted and dropped — a switch that turns off a correctness
//! check is a place to hide from a failure, and it is unnecessary when what
//! the user actually wants to control is when to connect.
//!
//! What is left of that trade is honest and worth saying: with the pool set to
//! connect lazily, a mismatched Row is found at the first request that touches
//! the database rather than at boot. It is still every Row at once, once,
//! rather than the request that happens to read the wrong column.
//!
//! Nothing here does any I/O. The columns come from the Dialect's
//! `introspect` query through a Wire, and everything after that is a
//! comparison over two lists — which is why it is tested with no Postgres in
//! the room, the same reason `App.handleRequest` is tested against in-memory
//! buffers.

const std = @import("std");
const row_mod = @import("row.zig");
const table_mod = @import("table.zig");
const wire_mod = @import("wire.zig");
const rawcheck = @import("rawcheck.zig");
const types_mod = @import("types.zig");

pub const Mismatch = enum {
    /// There is no table of that name at all, so none of the columns below
    /// can be asked about. Reported alone — see `compare`.
    no_such_table,
    /// The Row reads a column the table does not have.
    no_such_column,
    /// The column is there and holds something else.
    wrong_type,
    /// The column may be null and the Row does not allow for it.
    unexpected_null,
    /// The database's enum has a value the Zig enum does not. The dangerous
    /// direction: a row holding it reads as an error on the first request,
    /// which is what `ALTER TYPE … ADD VALUE` leaves behind.
    value_zig_lacks,
    /// The Zig enum has a value the database's enum does not. A write of it
    /// is refused by the database; said here rather than there.
    value_type_lacks,
};

pub const Problem = struct {
    row: []const u8,
    table: []const u8,
    column: []const u8,
    kind: Mismatch,
    /// What the Row will accept, as a readable list. Empty when the Dialect
    /// declined to judge the type.
    expected: []const u8,
    /// What the database actually has. Empty when there is no column at all.
    found: []const u8,

    pub fn write(self: Problem, w: *std.Io.Writer) !void {
        switch (self.kind) {
            .no_such_table => try w.print(
                "nilo: {s} reads table \"{s}\", and the database has no table by that name",
                .{ self.row, self.table },
            ),
            .no_such_column => try w.print(
                "nilo: {s}.{s} has no column in table \"{s}\"",
                .{ self.row, self.column, self.table },
            ),
            .wrong_type => {
                try w.print(
                    "nilo: {s}.{s} expects {s}, but {s}.{s} is {s}",
                    .{ self.row, self.column, self.expected, self.table, self.column, self.found },
                );
                // The one mismatch whose fix is not "change the field": a
                // zoneless column moves `.now` by the session's zone, and
                // what nilo wrote into it before is UTC wall time, which this
                // `USING` keeps.
                if (std.mem.eql(u8, self.expected, "timestamptz") and std.mem.eql(u8, self.found, "timestamp"))
                    try w.print(
                        " — `ALTER TABLE \"{s}\" ALTER COLUMN \"{s}\" TYPE timestamptz " ++
                            "USING \"{s}\" AT TIME ZONE 'UTC'`",
                        .{ self.table, self.column, self.column },
                    );
            },
            .unexpected_null => try w.print(
                "nilo: {s}.{s} is not optional, but {s}.{s} may be null",
                .{ self.row, self.column, self.table, self.column },
            ),
            // For the three below `expected` is the enum type's name and
            // `found` the value in question.
            .value_zig_lacks => try w.print(
                "nilo: {s}.{s} has no `{s}`, which enum type \"{s}\" has — a row holding it will not read",
                .{ self.row, self.column, self.found, self.expected },
            ),
            .value_type_lacks => try w.print(
                "nilo: {s}.{s} has `{s}`, which enum type \"{s}\" does not — a row holding it will not write",
                .{ self.row, self.column, self.found, self.expected },
            ),
        }
    }
};

/// What `Row` expects of each of its columns, worked out while compiling so
/// that the comparison itself is a walk over two lists.
pub const Expectation = struct {
    column: []const u8,
    /// The column types the Dialect will read this into. Empty means it
    /// declined to judge — a Zig enum read out of a Postgres enum, whose type
    /// name lives in the database.
    accepts: []const []const u8,
    /// The same list as one readable phrase, built while compiling so that
    /// the comparison itself has no comptime work left in it.
    expected: []const u8,
    optional: bool,

    /// **A column with no declared type fits any field** (ADR 055). SQLite's
    /// `pragma_table_info` answers an empty type for `CREATE TABLE t (x)` and
    /// for an expression in a view, and such a column has BLOB affinity, which
    /// converts nothing and stores whatever it is given. The SQLite
    /// `introspect` says `ANY` for it, in capitals no Postgres `typname`
    /// uses, so the one test here serves both Dialects. Refusing it would be
    /// the check refusing a correct table again.
    pub const untyped = "ANY";

    pub fn accepted(self: Expectation, udt: []const u8) bool {
        if (self.accepts.len == 0) return true;
        if (std.mem.eql(u8, udt, untyped)) return true;
        for (self.accepts) |name| {
            if (std.mem.eql(u8, name, udt)) return true;
        }
        return false;
    }
};

/// The expectations `Row` carries, in the order it declares its columns.
///
/// **An enum column on a Row this program builds is judged, and on one it only
/// reads it is not**, which is the one place the check asks whether the table is
/// nilo's. A Dialect declines to judge a Zig enum because the column may be a
/// Postgres `ENUM` whose type name lives in the database and cannot be derived
/// from this side. On a managed Row it can: nilo wrote the `CREATE TABLE`, and
/// what it wrote was `text` plus a check over the enum's words
/// ([ADR 181](../docs/adr/181-the-marker-has-two-kinds-of-word.md)). So the
/// gap closes exactly where the answer is known, and stays open where it is not.
///
/// What this does *not* read is the constraint's body. Holding the enum's words
/// against `pg_constraint` needs a second introspection query, and it is not
/// here — so a database whose check lost a word while the type kept it is
/// caught by the migration diff and not by the boot check.
pub fn expectationsOf(comptime D: type, comptime Row: type) []const Expectation {
    return comptime blk: {
        const info = @typeInfo(Row).@"struct";
        const builds = row_mod.managedOf(Row);
        var out: [info.field_names.len]Expectation = undefined;
        var n: usize = 0;
        for (info.field_names, info.field_types) |f_name, f_type| {
            // Carried beside the columns, so there is nothing in the table
            // to expect (ADR 178).
            if (!row_mod.isColumnField(Row, f_name)) continue;
            const accepts: []const []const u8 = D.accepts(f_type) orelse
                (if (builds and table_mod.enumValues(f_type).len > 0)
                    D.text_accepts
                else
                    &.{});
            out[n] = .{
                .column = f_name,
                .accepts = accepts,
                .expected = list(accepts),
                .optional = @typeInfo(f_type) == .optional,
            };
            n += 1;
        }
        // The columns its `.unread` declares are the table's too, and a
        // boot check that skipped them would let one be dropped under a
        // `.where` that names it (item 102).
        const frozen = out[0..n].*;
        var all: []const Expectation = &frozen;
        for (row_mod.unreadOf(Row)) |u| {
            const accepts: []const []const u8 = D.accepts(u.T) orelse
                (if (builds and table_mod.enumValues(u.T).len > 0) D.text_accepts else &.{});
            all = all ++ &[_]Expectation{.{
                .column = u.name,
                .accepts = accepts,
                .expected = list(accepts),
                .optional = @typeInfo(u.T) == .optional,
            }};
        }
        break :blk all;
    };
}

/// Compare `Row` against the columns the database reported, appending what
/// does not line up. Returns how many problems were found.
///
/// A column that may be null read into a `?T` is fine, and so is one that may
/// not be null read into a `?T` — the second is harmless, so it is not
/// reported. A check that flags things nobody needs to fix is a check people
/// learn to skim.
///
/// **No columns at all is one problem, not one per column.** The
/// introspection query answers nothing for a table that is not there, and
/// every column then reports `no_such_column` — ten lines for one mistake,
/// and not the mistake that was made. Forgetting to migrate is the most
/// common way to reach this, so it gets a sentence of its own and the column
/// walk is skipped: there is nothing to say about a column of a table that
/// does not exist.
pub fn compare(
    comptime D: type,
    comptime Row: type,
    actual: []const wire_mod.Column,
    out: *std.ArrayList(Problem),
    gpa: std.mem.Allocator,
) !usize {
    const table = comptime row_mod.tableOf(Row);
    const name = comptime @typeName(Row);
    var found: usize = 0;

    if (actual.len == 0) {
        try out.append(gpa, .{
            .row = name,
            .table = table,
            .column = "",
            .kind = .no_such_table,
            .expected = "",
            .found = "",
        });
        return 1;
    }

    for (comptime expectationsOf(D, Row)) |want| {
        if (problemFor(name, table, want, actual)) |problem| {
            try out.append(gpa, problem);
            found += 1;
        }
    }
    return found;
}

/// One column's verdict. A plain function rather than the body of an
/// `inline for`, because every expectation is already a value by the time it
/// gets here — the comptime work was done in `expectationsOf`.
fn problemFor(
    name: []const u8,
    table: []const u8,
    want: Expectation,
    actual: []const wire_mod.Column,
) ?Problem {
    const base = Problem{
        .row = name,
        .table = table,
        .column = want.column,
        .kind = .no_such_column,
        .expected = want.expected,
        .found = "",
    };

    const column = findColumn(actual, want.column) orelse return base;
    if (!want.accepted(column.udt)) {
        var out = base;
        out.kind = .wrong_type;
        out.found = column.udt;
        return out;
    }
    // `null` is the database saying it does not know, which a view is
    // (ADR 050). Nothing is claimed either way, so nothing is reported.
    if ((column.nullable orelse false) and !want.optional) {
        var out = base;
        out.kind = .unexpected_null;
        out.found = column.udt;
        return out;
    }
    return null;
}

/// The enum columns of `Row` that named their type — the only ones whose
/// values can be held against the database's, because a Postgres enum's
/// type name lives there and a Zig enum that did not say it is judged like
/// text. Each is the column name and the type name, worked out while
/// compiling so the check is a loop over a list.
pub const EnumColumn = struct { column: []const u8, type_name: []const u8, E: type };

pub fn enumColumnsOf(comptime Row: type) []const EnumColumn {
    return comptime blk: {
        const info = @typeInfo(Row).@"struct";
        var out: [info.field_names.len]EnumColumn = undefined;
        var n: usize = 0;
        for (info.field_names, info.field_types) |f_name, f_type| {
            if (!row_mod.isColumnField(Row, f_name)) continue;
            const Inner = switch (@typeInfo(f_type)) {
                .optional => |o| o.child,
                else => f_type,
            };
            if (@typeInfo(Inner) != .@"enum") continue;
            if (!@hasDecl(Inner, "nilo_column")) continue;
            out[n] = .{ .column = f_name, .type_name = Inner.nilo_column, .E = Inner };
            n += 1;
        }
        const frozen = out[0..n].*;
        break :blk &frozen;
    };
}

/// The tables of a list of Rows that live in one schema, each once. What the
/// startup check asks the catalog about in one query (`Wire.columnsOfMany`):
/// two Rows over one table share an entry, and Rows in different schemas
/// fall into different groups because a catalog query names one schema.
pub const Group = struct {
    schema: ?[]const u8,
    tables: []const []const u8,
};

/// Where a Row's table is in `groupsOf`'s answer: the group, and the place in
/// that group's `tables`, which is the place in the Wire's answer too.
pub const Place = struct { group: usize, table: usize };

/// The groups, in the order their schemas first appear among `Rows`.
pub fn groupsOf(comptime Rows: []const type) []const Group {
    return comptime blk: {
        @setEvalBranchQuota(20_000 + 5_000 * Rows.len * Rows.len);
        var groups: [Rows.len]Group = undefined;
        var n: usize = 0;
        for (Rows) |Row| {
            const q = row_mod.qualifiedOf(Row);
            var g: usize = 0;
            while (g < n) : (g += 1) {
                if (table_mod.sameSchema(groups[g].schema, q.schema)) break;
            }
            if (g == n) {
                groups[n] = .{ .schema = q.schema, .tables = &.{} };
                n += 1;
            }
            var seen = false;
            for (groups[g].tables) |t| {
                if (std.mem.eql(u8, t, q.table)) seen = true;
            }
            if (!seen) groups[g].tables = groups[g].tables ++ &[_][]const u8{q.table};
        }
        const frozen = groups[0..n].*;
        break :blk &frozen;
    };
}

/// Where `Row`'s table is among `groups`.
pub fn placeOf(comptime groups: []const Group, comptime Row: type) Place {
    return comptime blk: {
        const q = row_mod.qualifiedOf(Row);
        for (groups, 0..) |g, gi| {
            if (!table_mod.sameSchema(g.schema, q.schema)) continue;
            for (g.tables, 0..) |t, ti| {
                if (std.mem.eql(u8, t, q.table)) break :blk .{ .group = gi, .table = ti };
            }
        }
        @compileError("nilo: " ++ @typeName(Row) ++ " is in no group of tables; this is a bug in `schema.groupsOf`.");
    };
}

/// Every enum type name the Rows' columns declared, each once: what the
/// startup check asks the catalog for in one query (`Wire.labelsOfMany`).
pub fn enumTypesOf(comptime Rows: []const type) []const []const u8 {
    return comptime blk: {
        @setEvalBranchQuota(20_000 + 5_000 * Rows.len * Rows.len);
        var out: []const []const u8 = &.{};
        for (Rows) |Row| {
            for (enumColumnsOf(Row)) |col| {
                if (enumTypeAt(out, col.type_name) == null) out = out ++ &[_][]const u8{col.type_name};
            }
        }
        const frozen = out[0..out.len].*;
        break :blk &frozen;
    };
}

/// The place of `name` among `names`, or null.
pub fn enumTypeAt(names: []const []const u8, name: []const u8) ?usize {
    for (names, 0..) |t, i| {
        if (std.mem.eql(u8, t, name)) return i;
    }
    return null;
}

/// Hold a Zig enum against the values the database's type has, appending
/// what does not line up. Returns how many problems were found.
///
/// Both directions are reported, because they fail differently and both
/// fail at run time otherwise: a value the Zig enum lacks is an error on the
/// first row that holds it (`enumOf` in `db.zig`), and a value the type
/// lacks is a database error on the first write of it. No labels at all is
/// nothing to compare rather than a problem: an enum whose `nilo_column`
/// names `text` or `varchar` is held as text, and the type name itself was
/// already judged by `compare`, column by column.
pub fn compareEnum(
    comptime E: type,
    row: []const u8,
    table: []const u8,
    column: []const u8,
    type_name: []const u8,
    labels: []const []const u8,
    out: *std.ArrayList(Problem),
    gpa: std.mem.Allocator,
) !usize {
    if (labels.len == 0) return 0;
    const base = Problem{
        .row = row,
        .table = table,
        .column = column,
        .kind = .value_zig_lacks,
        .expected = type_name,
        .found = "",
    };

    var found: usize = 0;
    for (labels) |label| {
        if (std.meta.stringToEnum(E, label) == null) {
            var problem = base;
            problem.kind = .value_zig_lacks;
            problem.found = label;
            try out.append(gpa, problem);
            found += 1;
        }
    }
    const e_info = @typeInfo(E).@"enum";
    inline for (e_info.field_names) |f_name| {
        var present = false;
        for (labels) |label| {
            if (std.mem.eql(u8, label, f_name)) present = true;
        }
        if (!present) {
            var problem = base;
            problem.kind = .value_type_lacks;
            problem.found = f_name;
            try out.append(gpa, problem);
            found += 1;
        }
    }
    return found;
}

fn findColumn(actual: []const wire_mod.Column, name: []const u8) ?wire_mod.Column {
    for (actual) |c| {
        if (std.mem.eql(u8, c.name, name)) return c;
    }
    return null;
}

// -- a raw statement against its Row --------------------------------------
//
// The same comparison for a statement this module did not write, made the
// first time it runs rather than at startup, because a raw statement's
// columns are the statement's and not a table's: nothing can be asked about
// them until there is a statement to ask about
// ([ADR 233](../docs/adr/233-a-raw-statement-is-held-against-its-row-the-first-time-it-runs.md)).

/// One column a raw statement fills, as the first-run check holds it.
pub const Reading = struct {
    /// The field the column fills, or the type's name for a scalar read.
    field: []const u8,
    /// The column types it reads out of, from `Dialect.reads`. Empty is a
    /// field the Dialect will not judge.
    reads: []const []const u8,
    expected: []const u8,
    /// Whether the field reads text, so that a column the database sends as
    /// a string fits it whatever its type is called (`wire.Described.textual`).
    text: bool,
    optional: bool,
};

/// What `Row` expects of the columns of a raw statement, in order. `scalar`
/// is a read into one value rather than a Row (ADR 125), and `total` is the
/// `count(*) OVER ()` a `rawPage` reads after the Row's last field (ADR 205).
pub fn readingsOf(
    comptime D: type,
    comptime Row: type,
    comptime scalar: bool,
    comptime total: bool,
) []const Reading {
    return comptime blk: {
        var out: []const Reading = &.{};
        if (scalar) {
            out = out ++ [_]Reading{reading(D, @typeName(Row), Row)};
        } else {
            for (rawcheck.columnFields(Row)) |f| out = out ++ [_]Reading{reading(D, f.name, f.type)};
        }
        if (total) out = out ++ [_]Reading{reading(D, "the total", i64)};
        break :blk out;
    };
}

fn reading(comptime D: type, comptime field: []const u8, comptime F: type) Reading {
    const reads: []const []const u8 = D.reads(F) orelse &.{};
    var text = types_mod.jsonPayload(switch (@typeInfo(F)) {
        .optional => |o| o.child,
        else => F,
    }) != null;
    for (reads) |name| {
        if (std.mem.eql(u8, name, D.text_accepts[0])) text = true;
    }
    return .{
        .field = field,
        .reads = reads,
        .expected = list(reads),
        .text = text,
        .optional = @typeInfo(F) == .optional,
    };
}

/// What `fit` found wrong with one column.
pub const Misfit = struct {
    /// Counted from one, as the `SELECT` list is read.
    column: usize,
    field: []const u8,
    kind: enum { wrong_type, outer_null },
    expected: []const u8,
    found: []const u8,

    pub fn write(self: Misfit, w: *std.Io.Writer) !void {
        switch (self.kind) {
            .wrong_type => try w.print(
                "  column {d} fills `{s}`, which reads {s}, and the statement answers {s} there. " ++
                    "Cast the column in the statement, or change the field's type.\n",
                .{ self.column, self.field, self.expected, self.found },
            ),
            .outer_null => try w.print(
                "  column {d} fills `{s}`, which is not optional, and comes from the side of an " ++
                    "outer join that may find nothing, where it is NULL. Make the field optional, " ++
                    "or `coalesce` the column.\n",
                .{ self.column, self.field },
            ),
        }
    }
};

/// Hold what `describe` said against the readings, appending what does not
/// fit. A column the database did not describe, and one past the end of
/// either list, is not judged: the width is `fill`'s check (ADR 106).
pub fn fit(
    readings: []const Reading,
    described: []const wire_mod.Described,
    out: *std.ArrayList(Misfit),
    gpa: std.mem.Allocator,
) !void {
    const n = @min(readings.len, described.len);
    for (readings[0..n], described[0..n], 1..) |want, got, at| {
        if (got.udt) |udt| {
            if (!fits(want, udt, got.textual)) try out.append(gpa, .{
                .column = at,
                .field = want.field,
                .kind = .wrong_type,
                .expected = want.expected,
                .found = udt,
            });
        }
        if (got.outer_null and !want.optional) try out.append(gpa, .{
            .column = at,
            .field = want.field,
            .kind = .outer_null,
            .expected = want.expected,
            .found = got.udt orelse "",
        });
    }
}

fn fits(want: Reading, udt: []const u8, textual: bool) bool {
    if (want.reads.len == 0) return true;
    if (want.text and textual) return true;
    for (want.reads) |name| {
        if (std.mem.eql(u8, name, udt)) return true;
    }
    return false;
}

fn list(comptime names: []const []const u8) []const u8 {
    comptime {
        if (names.len == 0) return "";
        if (names.len == 1) return names[0];
        var out: []const u8 = names[0];
        for (names[1..], 1..) |n, i| {
            out = out ++ (if (i == names.len - 1) " or " else ", ") ++ n;
        }
        return out;
    }
}

// -- tests ---------------------------------------------------------------

const testing = std.testing;
const Pg = @import("dialect.zig").Postgres;
const types = @import("types.zig");

const User = struct {
    pub const nilo_table = .{ .name = "users", .key = .id };

    id: i64,
    email: []const u8,
    age: i32,
    deleted_at: ?i64,
    created_at: types.Timestamp,
};

fn problemsFor(comptime Row: type, actual: []const wire_mod.Column) !std.ArrayList(Problem) {
    var out: std.ArrayList(Problem) = .empty;
    _ = try compare(Pg, Row, actual, &out, testing.allocator);
    return out;
}

fn textOf(problem: Problem, buf: []u8) ![]const u8 {
    var w = std.Io.Writer.fixed(buf);
    try problem.write(&w);
    return w.buffered();
}

const good = [_]wire_mod.Column{
    .{ .name = "id", .udt = "int8", .nullable = false },
    .{ .name = "email", .udt = "text", .nullable = false },
    .{ .name = "age", .udt = "int4", .nullable = false },
    .{ .name = "deleted_at", .udt = "int8", .nullable = true },
    .{ .name = "created_at", .udt = "timestamptz", .nullable = false },
};

test "a Row that matches its table has nothing to report" {
    var problems = try problemsFor(User, &good);
    defer problems.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), problems.items.len);
}

test "a column the table does not have is named, with the table" {
    var columns = good;
    columns[1].name = "e_mail";

    var problems = try problemsFor(User, &columns);
    defer problems.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), problems.items.len);
    try testing.expectEqual(Mismatch.no_such_column, problems.items[0].kind);

    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings(
        "nilo: schema.User.email has no column in table \"users\"",
        try textOf(problems.items[0], &buf),
    );
}

test "a table that is not there is one sentence, not one per column" {
    // The introspection query answers nothing, and every column used to
    // report `no_such_column` off the back of it: five lines here, ten on a
    // real Row, and none of them saying what actually happened.
    var problems = try problemsFor(User, &.{});
    defer problems.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), problems.items.len);
    try testing.expectEqual(Mismatch.no_such_table, problems.items[0].kind);

    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings(
        "nilo: schema.User reads table \"users\", and the database has no table by that name",
        try textOf(problems.items[0], &buf),
    );
}

test "a column holding something else says both types" {
    var columns = good;
    columns[2].udt = "text";

    var problems = try problemsFor(User, &columns);
    defer problems.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), problems.items.len);
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings(
        "nilo: schema.User.age expects int4 or int8, but users.age is text",
        try textOf(problems.items[0], &buf),
    );
}

test "a Timestamp over a zoneless timestamp column is refused, with the ALTER that keeps its values" {
    var cols = good;
    cols[4].udt = "timestamp";
    var problems = try problemsFor(User, &cols);
    defer problems.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), problems.items.len);
    try testing.expectEqual(Mismatch.wrong_type, problems.items[0].kind);

    var buf: [512]u8 = undefined;
    try testing.expectEqualStrings(
        "nilo: schema.User.created_at expects timestamptz, but users.created_at is timestamp — " ++
            "`ALTER TABLE \"users\" ALTER COLUMN \"created_at\" TYPE timestamptz " ++
            "USING \"created_at\" AT TIME ZONE 'UTC'`",
        try textOf(problems.items[0], &buf),
    );
}

test "a nullable column read into a plain field is caught before a null arrives" {
    var columns = good;
    columns[1].nullable = true;

    var problems = try problemsFor(User, &columns);
    defer problems.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), problems.items.len);
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings(
        "nilo: schema.User.email is not optional, but users.email may be null",
        try textOf(problems.items[0], &buf),
    );
}

test "a column that cannot be null read into an optional is not worth reporting" {
    var columns = good;
    columns[3].nullable = false;

    var problems = try problemsFor(User, &columns);
    defer problems.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), problems.items.len);
}

test "a column the Row does not read is not its business" {
    const extra = good ++ [_]wire_mod.Column{
        .{ .name = "password_hash", .udt = "text", .nullable = false },
    };

    var problems = try problemsFor(User, &extra);
    defer problems.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), problems.items.len);
}

test "every mismatch is reported, not just the first" {
    var columns = good;
    columns[0].udt = "text";
    columns[2].udt = "text";

    var problems = try problemsFor(User, &columns);
    defer problems.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), problems.items.len);
}

test "an enum column is judged on a table this program builds and not on one it only reads" {
    // A Dialect declines to judge a Zig enum, because the column may be a
    // Postgres `ENUM` whose type name lives in the database. On a Row this
    // program built the table for it does not have to guess: what nilo wrote
    // was `text` plus a check over the enum's words (ADR 181).
    const Role = enum { admin, user };
    const Member = struct {
        pub const nilo_table = .{ .name = "members", .key = .id };
        id: i64,
        role: Role,
    };
    const Somebody = struct {
        pub const nilo_table = .{ .name = "members", .key = .id, .managed = false };
        id: i64,
        role: Role,
    };

    const postgres_enum: []const wire_mod.Column = &.{
        .{ .name = "id", .udt = "int8", .nullable = false },
        .{ .name = "role", .udt = "member_role", .nullable = false },
    };

    // Somebody else's table, so the column may be whatever they made it.
    var borrowed = try problemsFor(Somebody, postgres_enum);
    defer borrowed.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), borrowed.items.len);

    // This program's table, so `member_role` is a column nilo never wrote —
    // which is a schema that drifted, and the gap the check used to have.
    var built = try problemsFor(Member, postgres_enum);
    defer built.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), built.items.len);
    try testing.expectEqual(Mismatch.wrong_type, built.items[0].kind);

    // And the column nilo did write passes.
    var mine = try problemsFor(Member, &.{
        .{ .name = "id", .udt = "int8", .nullable = false },
        .{ .name = "role", .udt = "text", .nullable = false },
    });
    defer mine.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), mine.items.len);
}

test "the columns are read out of the table a narrower Row borrows" {
    const UserCard = struct {
        pub const nilo_table = User;
        id: i64,
        email: []const u8,
    };

    var problems = try problemsFor(UserCard, &good);
    defer problems.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), problems.items.len);
}

test "an enum column is judged in both directions, and text is not judged" {
    const Role = enum {
        admin,
        member,
        pub const nilo_column = "staff_role";
    };
    var problems: std.ArrayList(Problem) = .empty;
    defer problems.deinit(testing.allocator);

    // The database gained `moderator`; the Zig enum has `member` the type lacks.
    const labels = [_][]const u8{ "admin", "moderator" };
    try testing.expectEqual(@as(usize, 2), try compareEnum(Role, "Staff", "staff", "role", "staff_role", &labels, &problems, testing.allocator));
    try testing.expectEqual(Mismatch.value_zig_lacks, problems.items[0].kind);
    try testing.expectEqualStrings("moderator", problems.items[0].found);
    try testing.expectEqual(Mismatch.value_type_lacks, problems.items[1].kind);
    try testing.expectEqualStrings("member", problems.items[1].found);

    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try problems.items[0].write(&w);
    try testing.expectEqualStrings(
        "nilo: Staff.role has no `moderator`, which enum type \"staff_role\" has — a row holding it will not read",
        w.buffered(),
    );

    // Agreement is silence.
    problems.clearRetainingCapacity();
    const same = [_][]const u8{ "admin", "member" };
    try testing.expectEqual(@as(usize, 0), try compareEnum(Role, "Staff", "staff", "role", "staff_role", &same, &problems, testing.allocator));

    // And no labels is a column held as text, which `compare` has judged
    // already: nothing to say.
    try testing.expectEqual(@as(usize, 0), try compareEnum(Role, "Staff", "staff", "role", "staff_role", &.{}, &problems, testing.allocator));
}

test "only an enum that named its type is held against the database" {
    const Named = enum {
        a,
        pub const nilo_column = "t";
    };
    const Bare = enum { a };
    const Row = struct {
        pub const nilo_table = .{ .name = "r", .key = .id };
        id: i64,
        named: Named,
        maybe: ?Named,
        bare: Bare,
    };
    const cols = comptime enumColumnsOf(Row);
    try testing.expectEqual(@as(usize, 2), cols.len);
    try testing.expectEqualStrings("named", cols[0].column);
    try testing.expectEqualStrings("maybe", cols[1].column);
    try testing.expectEqualStrings("t", cols[1].type_name);
}

test "a raw column is held to the read the driver makes, not to the table's looser list" {
    const Line = struct {
        pub const nilo_table = .projection;
        id: i32,
        title: []const u8,
        doc: types.Json(struct { a: i64 }),
        note: ?[]const u8,
    };
    const readings = comptime readingsOf(Pg, Line, false, true);
    try testing.expectEqual(@as(usize, 5), readings.len);
    try testing.expectEqualStrings("the total", readings[4].field);

    var out: std.ArrayList(Misfit) = .empty;
    defer out.deinit(testing.allocator);
    try fit(readings, &.{
        // `count(*)`, which `accepts` lets an `i32` column stand over.
        .{ .udt = "int8" },
        // An enum's label, which a text field reads whatever its name is.
        .{ .udt = "deal_state", .textual = true },
        // A document cast to text, which `Json` parses the same.
        .{ .udt = "text", .textual = true },
        // A NULL the join may leave, into an optional.
        .{ .udt = "text", .textual = true, .outer_null = true },
        .{ .udt = "int8" },
    }, &out, testing.allocator);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqual(@as(usize, 1), out.items[0].column);
    try testing.expectEqualStrings("int4 or int2", out.items[0].expected);
    try testing.expectEqualStrings("int8", out.items[0].found);
}

test "a raw column nobody described, or past the Row's end, is not judged" {
    const One = struct {
        pub const nilo_table = .projection;
        id: i64,
    };
    var out: std.ArrayList(Misfit) = .empty;
    defer out.deinit(testing.allocator);
    try fit(comptime readingsOf(Pg, One, false, false), &.{
        .{ .udt = null, .outer_null = false },
        .{ .udt = "uuid", .outer_null = true },
    }, &out, testing.allocator);
    try testing.expectEqual(@as(usize, 0), out.items.len);

    // A scalar read is one column named after its type.
    const scalar = comptime readingsOf(Pg, i64, true, false);
    try testing.expectEqualStrings("i64", scalar[0].field);
    try fit(scalar, &.{.{ .udt = "numeric" }}, &out, testing.allocator);
    try testing.expectEqual(@as(usize, 1), out.items.len);

    var said: std.Io.Writer.Allocating = .init(testing.allocator);
    defer said.deinit();
    try out.items[0].write(&said.writer);
    try testing.expect(std.mem.indexOf(u8, said.written(), "reads int8, int4 or int2, and the statement answers numeric") != null);
}

test "SQLite columns are judged by affinity, so a hand-written declared type passes and a wrong affinity does not" {
    const Lite = @import("dialect.zig").SQLite;
    const Hand = struct {
        pub const nilo_table = .{ .name = "hand", .key = .id };

        id: i64,
        name: []const u8,
        born: types.Date,
        ref: types.Uuid,
        price: f64,
        active: bool,
        seen: types.Timestamp,
        note: ?[]const u8,
    };
    // What `introspect` answers for `id INTEGER`, `name VARCHAR(255)`,
    // `born DATE`, `ref UUID`, `price DOUBLE PRECISION`, `active BOOLEAN`,
    // `seen DATETIME` and `note` with no type at all.
    const columns = [_]wire_mod.Column{
        .{ .name = "id", .udt = "INTEGER", .nullable = false },
        .{ .name = "name", .udt = "TEXT", .nullable = false },
        .{ .name = "born", .udt = "NUMERIC", .nullable = false },
        .{ .name = "ref", .udt = "NUMERIC", .nullable = false },
        .{ .name = "price", .udt = "REAL", .nullable = false },
        .{ .name = "active", .udt = "NUMERIC", .nullable = false },
        .{ .name = "seen", .udt = "NUMERIC", .nullable = false },
        .{ .name = "note", .udt = Expectation.untyped, .nullable = true },
    };
    var out: std.ArrayList(Problem) = .empty;
    defer out.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), try compare(Lite, Hand, &columns, &out, testing.allocator));

    // A `Str` over INTEGER affinity is still the mismatch this check is for,
    // and a column with no type fits any field, not only the optional one.
    var wrong = columns;
    wrong[1].udt = "INTEGER";
    wrong[4].udt = Expectation.untyped;
    try testing.expectEqual(@as(usize, 1), try compare(Lite, Hand, &wrong, &out, testing.allocator));
    try testing.expectEqualStrings("name", out.items[0].column);
    try testing.expectEqualStrings("INTEGER", out.items[0].found);
}

test "Rows are grouped by schema and share the entry of a table they both read" {
    const Card = struct {
        pub const nilo_table = User;
        id: i64,
    };
    const Event = struct {
        pub const nilo_table = .{ .name = "audit.events", .key = .id };
        id: i64,
    };
    const Other = struct {
        pub const nilo_table = .{ .name = "orders", .key = .id };
        id: i64,
    };
    const Rows = &[_]type{ User, Event, Card, Other };

    const groups = comptime groupsOf(Rows);
    // Two groups: the session's own schema, and `audit`.
    try testing.expectEqual(@as(usize, 2), groups.len);
    try testing.expectEqual(@as(?[]const u8, null), groups[0].schema);
    try testing.expectEqualStrings("audit", groups[1].schema.?);
    // `Card` reads `users` too, so the group holds it once.
    try testing.expectEqual(@as(usize, 2), groups[0].tables.len);
    try testing.expectEqualStrings("users", groups[0].tables[0]);
    try testing.expectEqualStrings("orders", groups[0].tables[1]);

    try testing.expectEqual(Place{ .group = 0, .table = 0 }, comptime placeOf(groups, Card));
    try testing.expectEqual(Place{ .group = 1, .table = 0 }, comptime placeOf(groups, Event));
    try testing.expectEqual(Place{ .group = 0, .table = 1 }, comptime placeOf(groups, Other));
}

test "an enum type two columns name is asked about once" {
    const Level = enum {
        low,
        high,
        pub const nilo_column = "level_kind";
    };
    const Mood = enum {
        calm,
        cross,
        pub const nilo_column = "mood_kind";
    };
    const A = struct {
        pub const nilo_table = .{ .name = "a", .key = .id };
        id: i64,
        level: Level,
        mood: Mood,
    };
    const B = struct {
        pub const nilo_table = .{ .name = "b", .key = .id };
        id: i64,
        level: ?Level,
    };
    const names = comptime enumTypesOf(&.{ A, B });
    try testing.expectEqual(@as(usize, 2), names.len);
    try testing.expectEqual(@as(?usize, 0), enumTypeAt(names, "level_kind"));
    try testing.expectEqual(@as(?usize, 1), enumTypeAt(names, "mood_kind"));
    try testing.expectEqual(@as(?usize, null), enumTypeAt(names, "nope"));
}
