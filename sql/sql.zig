//! zfast's SQL module — a query is a struct of your own, checked while
//! compiling (ADR 0039).
//!
//! ```zig
//! const sql = @import("zfast_sql");
//!
//! const User = struct {
//!     pub const zfast_table = .{ .name = "users", .key = .id };
//!
//!     id: i64,
//!     email: zfast.Str,
//!     age: i32,
//!     created_at: sql.Timestamp,
//! };
//!
//! fn listAdults(db: *sql.Db, c: *zfast.Ctx) ![]User {
//!     return db.select(User, c, .{ .where = .{ .age = .{ .gt = 18 } } });
//! }
//! ```
//!
//! ## The rule everything here follows
//!
//! > **The shape of a query is settled while compiling. Only its values are
//! > not.**
//!
//! Which table, which columns, which operators, how many parameters — all of
//! it fixed before the binary exists, all of it a compile error when wrong.
//! The `18` is the only part that arrives at run time. It is the sentence
//! `typed.zig` lives by — *a pointer is a service, a value is request data* —
//! one layer over.
//!
//! ## It is not an ORM
//!
//! The word promises object-relational mapping, Zig has no objects, and every
//! mechanism that earns the name is refused here: no change tracking, which
//! costs a copy of every row; no lazy relations, which are queries nobody
//! wrote; no identity map, which is a lifetime problem in a language with no
//! garbage collector and the opposite of a `Str` never escaping its request.
//!
//! A name is a promise, and `orm` would promise a `.save()` that is never
//! going to exist. If you came here looking for one, the README says plainly
//! that this is not it, and why.
//!
//! ## What it will not do
//!
//! Joins, aggregates, subqueries, `HAVING`, window functions, CTEs. The line
//! is **one table, conditions that filter rows**, and past it the answer is
//! `db.raw`, which still fills a Row, still uses the request arena and still
//! follows the `Str` rule — it gives up the compile-time column check and
//! nothing else. A boundary that fits in one sentence is worth more than one
//! that is further out, because it can be predicted without reading the
//! reference.
//!
//! Migrations are not here and are not implied. Nothing in this design
//! forecloses them.
//!
//! ## How it is put together
//!
//! | Piece | File | What it is |
//! |---|---|---|
//! | **Row** | `row.zig` | the marker, the borrow chain, the column list |
//! | **Dialect** | `dialect.zig` | comptime, writes the SQL, may refuse |
//! | **Wire** | `wire.zig` | runtime, speaks to the database |
//! | **where** | `where.zig` | a condition into a fragment and a value list |
//! | **statements** | `select.zig` | the whole `SELECT`, as a constant |
//! | **schema** | `schema.zig` | Row against table, on the first connection |
//! | **types** | `types.zig` | Timestamp, Uuid, Json — value, not arithmetic |
//!
//! Two seams rather than one, because two different things get replaced
//! independently: swapping the driver changes how bytes reach the socket,
//! adding a database changes the SQL itself. Both are fitted now, and only
//! Postgres is filled in — the point is that `$1` is not hardcoded, not that
//! a second dialect exists.
//!
//! Nothing here imports `zfast`, and `zfast` does not know this module
//! exists. That one-way dependency is what makes this feature cost exactly
//! zero bytes to a project that does not import it.

const std = @import("std");

pub const row = @import("row.zig");
pub const dialect = @import("dialect.zig");
pub const wire = @import("wire.zig");
pub const where = @import("where.zig");
pub const statement = @import("select.zig");
pub const schema = @import("schema.zig");
pub const types = @import("types.zig");

/// The Dialect used unless something says otherwise. One exists; the seam is
/// there so that the second one is an addition rather than a rewrite.
pub const Postgres = dialect.Postgres;

pub const Timestamp = types.Timestamp;
pub const Uuid = types.Uuid;
pub const Json = types.Json;

pub const Column = wire.Column;
pub const Error = wire.Error;

/// The marker a Row carries, exported so that a caller writing one can name
/// it rather than remembering the spelling.
pub const table_marker = row.marker;

/// The `SELECT` a Row and a set of options compile to. The headline of ADR
/// 0039 in one call: what comes back exists before the program runs.
pub fn selectFor(comptime Row: type, comptime Options: type) statement.Statement {
    return comptime statement.select(Postgres, Row, Options);
}

/// The `DELETE`, likewise. It shares the where walker with `selectFor` rather
/// than having one of its own, so a condition cannot read one way here and
/// another way there.
pub fn deleteFor(comptime Row: type, comptime Options: type) statement.Statement {
    return comptime statement.delete(Postgres, Row, Options);
}

test {
    // Every file in this module, or its tests never run — the same rule
    // `src/zfast.zig` states for the framework. This module is deliberately
    // not reachable from there: a `_ = @import` line pointing the other way
    // would compile the whole of it into every zfast build.
    _ = row;
    _ = dialect;
    _ = wire;
    _ = where;
    _ = statement;
    _ = schema;
    _ = types;
}

// -- tests ---------------------------------------------------------------

const testing = std.testing;

const User = struct {
    pub const zfast_table = .{ .name = "users", .key = .id };

    id: i64,
    email: []const u8,
    age: i32,
    created_at: Timestamp,
};

test "the whole statement is a constant, which is the claim this module makes" {
    const options = .{
        .where = .{ .age = .{ .gt = 18 } },
        .order = .{ .created_at = .desc },
        .limit = 10,
    };
    const found = comptime selectFor(User, @TypeOf(options));

    try testing.expectEqualStrings(
        "SELECT \"id\", \"email\", \"age\", \"created_at\" FROM \"users\"" ++
            " WHERE \"age\" > $1 ORDER BY \"created_at\" DESC LIMIT 10",
        found.sql,
    );

    // One value reaches run time, and it is the 18.
    try testing.expectEqual(@as(usize, 1), found.paramCount());
    try testing.expectEqual(@as(i32, 18), where.valueAt(options, found.paths[0]));
}

test "the statement text is comptime-known, not merely computed early" {
    // If any of it were runtime work, this would not compile.
    const found = comptime selectFor(User, @TypeOf(.{ .where = .{ .id = 7 } }));
    comptime std.debug.assert(found.sql.len > 0);
    const in_binary: [found.sql.len]u8 = found.sql[0..found.sql.len].*;
    try testing.expectEqualStrings(found.sql, &in_binary);
}

test "a delete shares the walker rather than having a second one" {
    const found = comptime deleteFor(User, @TypeOf(.{ .where = .{ .id = 7 } }));
    try testing.expectEqualStrings("DELETE FROM \"users\" WHERE \"id\" = $1", found.sql);
}
