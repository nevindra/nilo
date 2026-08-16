//! Comparing a Row to the table it claims to read (ADR 0039).
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
const wire_mod = @import("wire.zig");

pub const Mismatch = enum {
    /// The Row reads a column the table does not have.
    no_such_column,
    /// The column is there and holds something else.
    wrong_type,
    /// The column may be null and the Row does not allow for it.
    unexpected_null,
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
            .no_such_column => try w.print(
                "nilo: {s}.{s} has no column in table \"{s}\"",
                .{ self.row, self.column, self.table },
            ),
            .wrong_type => try w.print(
                "nilo: {s}.{s} expects {s}, but {s}.{s} is {s}",
                .{ self.row, self.column, self.expected, self.table, self.column, self.found },
            ),
            .unexpected_null => try w.print(
                "nilo: {s}.{s} is not optional, but {s}.{s} may be null",
                .{ self.row, self.column, self.table, self.column },
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

    pub fn accepted(self: Expectation, udt: []const u8) bool {
        if (self.accepts.len == 0) return true;
        for (self.accepts) |name| {
            if (std.mem.eql(u8, name, udt)) return true;
        }
        return false;
    }
};

/// The expectations `Row` carries, in the order it declares its columns.
pub fn expectationsOf(comptime D: type, comptime Row: type) []const Expectation {
    return comptime blk: {
        const fields = @typeInfo(Row).@"struct".fields;
        var out: [fields.len]Expectation = undefined;
        for (fields, 0..) |f, i| {
            const accepts = D.accepts(f.type) orelse &.{};
            out[i] = .{
                .column = f.name,
                .accepts = accepts,
                .expected = list(accepts),
                .optional = @typeInfo(f.type) == .optional,
            };
        }
        const frozen = out;
        break :blk &frozen;
    };
}

/// Compare `Row` against the columns the database reported, appending what
/// does not line up. Returns how many problems were found.
///
/// A column that may be null read into a `?T` is fine, and so is one that may
/// not be null read into a `?T` — the second is harmless, so it is not
/// reported. A check that flags things nobody needs to fix is a check people
/// learn to skim.
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
    if (column.nullable and !want.optional) {
        var out = base;
        out.kind = .unexpected_null;
        out.found = column.udt;
        return out;
    }
    return null;
}

fn findColumn(actual: []const wire_mod.Column, name: []const u8) ?wire_mod.Column {
    for (actual) |c| {
        if (std.mem.eql(u8, c.name, name)) return c;
    }
    return null;
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

test "a type the Dialect declines to judge passes whatever the column holds" {
    const Role = enum { admin, user };
    const Member = struct {
        pub const nilo_table = .{ .name = "members", .key = .id };
        id: i64,
        role: Role,
    };

    var problems = try problemsFor(Member, &.{
        .{ .name = "id", .udt = "int8", .nullable = false },
        .{ .name = "role", .udt = "member_role", .nullable = false },
    });
    defer problems.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), problems.items.len);
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
