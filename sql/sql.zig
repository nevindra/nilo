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
//! Migrations **are** here, and they are the one thing in this module that
//! writes DDL rather than a statement over a table that already exists
//! ([ADR 0153](../docs/adr/0153-a-migration-is-a-diff-against-a-snapshot.md)).
//! They are also the one part that is not in a server: a diff is a tool, so it
//! spends nothing on any of ADR 0018's four axes because it is not in the
//! process those axes measure.
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
//! | **table** | `table.zig` | what a Row says about the *table*: the three marker words |
//! | **ddl** | `ddl.zig` | the SQL that changes a table's shape. `CREATE` is a constant |
//! | **snapshot** | `snapshot.zig` | what the last generate believed, as a `.zon` file |
//! | **migrate** | `migrate.zig` | the diff, the plan, and the record of what ran |
//! | **Wire** | `wire.zig` | the contract a driver meets |
//! | **the drivers** | `postgres.zig`, `sqlite.zig` | pg.zig and zqlite, and the only two files that name either |
//! | **Db** | `db.zig` | what a handler holds, and where `Str` stops |
//! | **live tests** | `live.zig` | the half that needs a real Postgres |
//!
//! Two seams rather than one, because two different things get replaced
//! independently: swapping the driver changes how bytes reach the socket,
//! adding a database changes the SQL itself. **Both are filled in twice
//! now** — Postgres over a socket and SQLite over a file
//! ([ADR 0073](../docs/adr/0073-a-file-has-no-socket-to-wait-on.md),
//! [ADR 0074](../docs/adr/0074-one-writer-is-not-a-setting-it-is-the-database.md)) —
//! and the second of each is what turned the claim that the seams were in the
//! right place into evidence.
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
//!
//! **SQLite is 524,840 bytes on top of that, and only for a program that
//! names it.** Both drivers live here, so both are fetched and this module
//! links libc whichever one you use — but `sql/sqlite.zig` is analysed only
//! when something names it, so the amalgamation is dropped outright by the
//! linker. A binary holding `sql.Db` and nothing else contains zero SQLite
//! strings; `zig build size-sql` is the A/B, and ADR 0073 has both numbers.

const std = @import("std");

pub const row = @import("row.zig");
pub const table = @import("table.zig");
pub const dialect = @import("dialect.zig");
pub const wire = @import("wire.zig");
pub const where = @import("where.zig");
pub const statement = @import("statement.zig");
pub const schema = @import("schema.zig");
pub const types = @import("types.zig");
pub const postgres = @import("postgres.zig");
pub const sqlite = @import("sqlite.zig");
pub const db = @import("db.zig");
pub const ddl = @import("ddl.zig");
pub const snapshot = @import("snapshot.zig");
pub const migrations = @import("migrations.zig");
pub const cli = @import("cli.zig");

/// Migrations: the diff between the types and a snapshot the repository holds,
/// and the record of what has been applied
/// ([ADR 0153](../docs/adr/0153-a-migration-is-a-diff-against-a-snapshot.md)).
///
/// **Nothing here is on the request path and nothing here is in a server.** A
/// program that never names it links none of it, the same way `sqlite.zig` is
/// dropped by a program holding only `sql.Db`.
///
/// Two calls cover the two ends. `migrate.createMissing(&db, &run, &.{ … })` is
/// a small application's whole startup, and every statement it sends is a
/// constant in the binary. `migrate.plan(…)` is the diff a tool generates from,
/// and it touches no database at all.
pub const migrate = @import("migrate.zig");

/// What a handler holds. `*sql.Db` in a signature is a service like any
/// other, so `listen()` checks it is registered before the first request
/// rather than after (ADR 0006).
pub const Db = db.Db;

/// One statement that has run, as `db.watching`'s function is told about it
/// ([ADR 0137](../docs/adr/0137-a-statement-can-be-watched.md)). The text,
/// the plan name, how long it took and how many rows moved — and not the
/// values, which is the decision rather than the first version.
pub const Sent = db.Sent;

/// What `db.watching` takes: `fn (sql.Sent) void`.
pub const Watcher = db.Watcher;

/// A watcher that writes one `std.log.debug` line per statement, for the
/// nine programs in ten that want exactly that.
///
/// ```zig
/// db.watching(sql.logging);
/// ```
pub const logging = db.logging;

/// A second database, told apart from the first by its name — a read
/// replica, a reporting warehouse, a database somebody else owns.
///
/// ```zig
/// const Replica = sql.Named("replica");
/// fn listing(rdb: *Replica, c: *nilo.Ctx) ![]Product { … }
/// ```
///
/// Two names are two types and two types are two services (ADR 0011), so
/// which pool a statement takes is written where a reader will see it: the
/// handler's argument list
/// ([ADR 0060](../docs/adr/0060-a-second-database-is-a-second-type.md)).
pub const Named = db.Named;

/// The same thing over SQLite: a database in a file rather than behind a
/// socket.
///
/// ```zig
/// const Db = sql.Sqlite(.{ .threading = .{ .hop = nilo } });
///
/// fn show(db: *Db, c: *nilo.Ctx, id: i64) !?User {
///     return db.find(User, c, id);
/// }
/// ```
///
/// Everything above this line is the same — the same Row, the same
/// conditions, the same `Str` rule — because the Dialect writes the SQL and
/// the Wire carries it, and a handler names neither
/// ([ADR 0061](../docs/adr/0061-the-second-dialect-is-the-test-of-the-seam.md)).
/// What is *not* the same is written where it happens rather than here:
/// `insertMany` and `tx.deadline` are Refusals, `.lock` is a Refusal, and a
/// list column has nowhere to live.
///
/// **`threading` has no default and that is deliberate**, so this call is one
/// line longer than `sql.Db` is. SQLite runs inside this process, so a
/// statement either holds the executor thread it is on or pays a hop to the
/// Engine's thread pool, and which is right is a fact about a deployment
/// ([ADR 0073](../docs/adr/0073-a-file-has-no-socket-to-wait-on.md)).
pub fn Sqlite(comptime opts: sqlite.Options) type {
    return db.DbOf(sqlite.Wire(opts), dialect.SQLite, "");
}

/// A second SQLite database, named the way `Named` names a second Postgres
/// one — and the same call to reach for when a program holds both kinds at
/// once, which [ADR 0060](../docs/adr/0060-a-second-database-is-a-second-type.md)
/// already made expressible.
pub fn SqliteNamed(comptime name: []const u8, comptime opts: sqlite.Options) type {
    if (name.len == 0) @compileError(
        "nilo: `sql.SqliteNamed(\"\")` has no name, so it is `sql.Sqlite` with extra steps.\n" ++
            "  Give it the one a reader would want in the argument list: " ++
            "`sql.SqliteNamed(\"cache\", …)`, `sql.SqliteNamed(\"audit\", …)`.",
    );
    return db.DbOf(sqlite.Wire(opts), dialect.SQLite, name);
}

/// The Dialect used unless something says otherwise — and the only one with
/// a Wire behind it. `sql.dialect.SQLite` is the second, SQL half only, and
/// what it found is in
/// [ADR 0061](../docs/adr/0061-the-second-dialect-is-the-test-of-the-seam.md).
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

/// What the database said about a statement it refused, as `Sent.problem`
/// carries it ([ADR 0146](../docs/adr/0146-a-statement-that-failed-says-what-the-database-said.md)).
///
/// `Error` is what a handler switches on; this is the text behind it, and
/// before it existed the whole of that text was a `std.log.err` line no
/// program could reach. It lives in the Scope's arena, so a watcher keeping
/// one past the request copies it.
pub const Problem = wire.Problem;

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
    _ = table;
    _ = dialect;
    _ = wire;
    _ = where;
    _ = statement;
    _ = schema;
    _ = types;
    _ = postgres;
    _ = sqlite;
    _ = db;
    _ = ddl;
    _ = snapshot;
    _ = migrate;
    // The migration runner against a real SQLite file. It needs the module
    // graph and no server, which is why it is here rather than in
    // `migrate.zig`'s own test block: that file runs under a plain `zig test`
    // and keeping it that way is worth a second file.
    _ = migrations;
    _ = cli;
    _ = @import("migrate_live.zig");
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
