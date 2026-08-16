//! nilo's SQL module — a query is a struct of your own, checked while
//! compiling (ADR 0039).
//!
//! ```zig
//! const sql = @import("nilo_sql");
//!
//! const User = struct {
//!     pub const nilo_table = .{ .name = "users", .key = .id };
//!
//!     id: i64,
//!     email: nilo.Str,
//!     age: i32,
//!     created_at: sql.Timestamp,
//! };
//!
//! fn listAdults(db: *sql.Db, c: *nilo.Ctx) ![]User {
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
//! | **where** | `where.zig` | a condition into a fragment and a value list |
//! | **statements** | `statement.zig` | every one of them, each as a constant |
//! | **types** | `types.zig` | Timestamp and Json — value, not arithmetic. `Uuid` is `nilo_id`'s, and `AsText` is the door out |
//! | **schema** | `schema.zig` | Row against table, while the server starts |
//! | **Wire** | `wire.zig` | the contract a driver meets |
//! | **the driver** | `postgres.zig` | pg.zig, and the only file that names it |
//! | **Db** | `db.zig` | what a handler holds, and where `Str` stops |
//! | **live tests** | `live.zig` | the half that needs a real Postgres |
//!
//! Two seams rather than one, because two different things get replaced
//! independently: swapping the driver changes how bytes reach the socket,
//! adding a database changes the SQL itself. Both are fitted now, and only
//! Postgres is filled in — the point is that `$1` is not hardcoded, not that
//! a second dialect exists.
//!
//! **The dependency runs one way: this module imports `nilo`, and `nilo`
//! does not know this module exists.** That is what makes the feature cost
//! exactly zero to a project that does not import it — measured, not
//! assumed: the HTTP-only binary contains no pg or TLS content, and pg.zig
//! is `.lazy = true`, so it is not even downloaded (ADR 0040).
//!
//! What it costs the projects that *do* import it is 733 KB, of which the
//! whole write half is 53 KB and the rest is pg.zig's TLS dependency. ADR
//! 0040 has the numbers and the argument for why being a TLS client is not
//! the thing ADR 0028 refused.

const std = @import("std");

pub const row = @import("row.zig");
pub const dialect = @import("dialect.zig");
pub const wire = @import("wire.zig");
pub const where = @import("where.zig");
pub const statement = @import("statement.zig");
pub const schema = @import("schema.zig");
pub const types = @import("types.zig");
pub const postgres = @import("postgres.zig");
pub const db = @import("db.zig");

/// What a handler holds. `*sql.Db` in a signature is a service like any
/// other, so `listen()` checks it is registered before the first request
/// rather than after (ADR 0006).
pub const Db = db.Db;

/// The Dialect used unless something says otherwise. One exists; the seam is
/// there so that the second one is an addition rather than a rewrite.
pub const Postgres = dialect.Postgres;

pub const Timestamp = types.Timestamp;
pub const Uuid = types.Uuid;
pub const Json = types.Json;
pub const Decimal = types.Decimal;
pub const Interval = types.Interval;
pub const Inet = types.Inet;

/// A column type declared by whoever owns it rather than by this module: any
/// struct or enum with `nilo_column`, `nilo_read(text, arena)` and
/// `nilo_write(arena)`. `AsText("money")` is the smallest instance of that
/// protocol — the value *is* the text Postgres prints
/// ([ADR 0055](../docs/adr/0055-a-column-type-can-come-from-outside-this-module.md)).
pub const AsText = types.AsText;

pub const Column = wire.Column;
pub const Error = wire.Error;

/// What a transaction is begun with, and what a read holds on to. Both are
/// written as literals at the call — `db.begin(c, .{ .isolation = .serializable })`,
/// `.lock = .update` — so naming either type is for a caller keeping one in a
/// struct of their own.
pub const Begin = wire.Begin;
pub const Isolation = wire.Isolation;
pub const Lock = dialect.Lock;

/// The marker a Row carries, exported so that a caller writing one can name
/// it rather than remembering the spelling.
pub const table_marker = row.marker;

/// The `SELECT` a Row and a set of options compile to. The headline of ADR
/// 0039 in one call: what comes back exists before the program runs.
pub fn selectFor(comptime Row: type, comptime Options: type) statement.Statement {
    return comptime statement.select(Postgres, Row, Options);
}

/// The same `SELECT` with the `LIMIT 1` `db.one` compiles for itself. A
/// `.limit` written alongside it is a Refusal — the ceiling belongs to the
/// call rather than to the caller.
pub fn oneFor(comptime Row: type, comptime Options: type) statement.Statement {
    return comptime statement.one(Postgres, Row, Options);
}

/// `SELECT count(*)`, and `SELECT EXISTS(…)`. Both take a condition and
/// nothing else: there is nothing to order and nothing to narrow in an
/// answer that is one row wide.
pub fn countFor(comptime Row: type, comptime Options: type) statement.Statement {
    return comptime statement.count(Postgres, Row, Options);
}

pub fn existsFor(comptime Row: type, comptime Options: type) statement.Statement {
    return comptime statement.exists(Postgres, Row, Options);
}

/// The `SELECT … WHERE <key> = $1 LIMIT 1` behind `db.find`. `Key` is the
/// type of the value handed in, which is the half that can be got wrong: a
/// condition where a key goes is a Refusal.
pub fn findFor(comptime Row: type, comptime Key: type) statement.Statement {
    return comptime statement.find(Postgres, Row, Key);
}

/// The `DELETE`, likewise. It shares the where walker with `selectFor` rather
/// than having one of its own, so a condition cannot read one way here and
/// another way there.
pub fn deleteFor(comptime Row: type, comptime Options: type) statement.Statement {
    return comptime statement.delete(Postgres, Row, Options);
}

/// The `UPDATE` and the `DELETE` that answer with their rows rather than with
/// a count — the same statements with the `SELECT` list on the end.
pub fn updateReturningFor(comptime Row: type, comptime Options: type) statement.Statement {
    return comptime statement.updateReturning(Postgres, Row, Options);
}

pub fn deleteReturningFor(comptime Row: type, comptime Options: type) statement.Statement {
    return comptime statement.deleteReturning(Postgres, Row, Options);
}

/// The `INSERT`, with the Row's column list as its `RETURNING`.
pub fn insertFor(comptime Row: type, comptime Values: type) statement.Statement {
    return comptime statement.insert(Postgres, Row, Values);
}

/// The batch `INSERT`: one array per column, `unnest`ed. `Values` is the type
/// of one row of the batch, not of the slice.
pub fn insertManyFor(comptime Row: type, comptime Values: type) statement.Statement {
    return comptime statement.insertMany(Postgres, Row, Values);
}

/// The batch `UPDATE`: the same arrays, joined against the table.
pub fn updateManyFor(comptime Row: type, comptime Values: type) statement.Statement {
    return comptime statement.updateMany(Postgres, Row, Values);
}

/// The two upserts. `on` is the conflict target — a column written the way a
/// key is, `.email`, or a tuple of them for a constraint spanning more than
/// one. It is a value rather than a type because the column *names* are what
/// the statement needs, and Zig keeps those on the literal.
pub fn insertOrIgnoreFor(
    comptime Row: type,
    comptime Values: type,
    comptime on: anytype,
) statement.Statement {
    return comptime statement.insertOrIgnore(Postgres, Row, Values, on);
}

pub fn insertOrUpdateFor(
    comptime Row: type,
    comptime Values: type,
    comptime on: anytype,
) statement.Statement {
    return comptime statement.insertOrUpdate(Postgres, Row, Values, on);
}

/// The `UPDATE`. Both `.set` and `.where` are required, and the numbering
/// runs through them in that order.
pub fn updateFor(comptime Row: type, comptime Options: type) statement.Statement {
    return comptime statement.update(Postgres, Row, Options);
}

/// A Row with every `Str` replaced by `[]const u8` — what `db.stream` hands
/// back, and a type that says its text dies at the next row rather than
/// leaving that to a comment (ADR 0039).
pub const Borrowed = row.Borrowed;

test {
    // Every file in this module, or its tests never run — the same rule
    // `src/nilo.zig` states for the framework. This module is deliberately
    // not reachable from there: a `_ = @import` line pointing the other way
    // would compile the whole of it into every nilo build.
    _ = row;
    _ = dialect;
    _ = wire;
    _ = where;
    _ = statement;
    _ = schema;
    _ = types;
    _ = postgres;
    _ = db;
    // The tests that need a database. Every one of them skips when
    // `DATABASE_URL` is unset, so this line costs nothing to somebody who
    // has not started one (`sql/live.zig`).
    _ = @import("live.zig");
}

// -- tests ---------------------------------------------------------------

const testing = std.testing;

const User = struct {
    pub const nilo_table = .{ .name = "users", .key = .id };

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
