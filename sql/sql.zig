//! nilo's SQL module — a query is a struct of your own, checked while
//! compiling (ADR 036).
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
//! A join through a condition rather than a reference, `DISTINCT`, window
//! functions, CTEs, unions, an aggregate over an expression. Past what a Row
//! can declare the answer is `db.raw`, which still fills a Row, still uses the
//! request arena and still follows the `Str` rule: it gives up the
//! compile-time column check and nothing else.
//!
//! **What a Row can declare is held to two properties**
//! ([ADR 218](../docs/adr/218-a-row-may-carry-its-parent-its-children-or-a-sum.md)): the
//! Row still describes the answer, and `.limit` still counts what is being
//! listed. `EXISTS` keeps both and is a condition. A parent keeps both because
//! a reference points at one row; children keep both because they are never
//! joined, and are read by a second statement once `.limit` has counted the
//! parents; a grouped Row keeps both because its rows are its groups and it
//! says so in its type
//! ([ADR 218](../docs/adr/218-a-row-may-carry-its-parent-its-children-or-a-sum.md)).
//! There is still no `.join` and no `.group_by` at the call site: the Row is
//! the whole description, and `shape.zig` writes the statement from it.
//!
//! Migrations **are** here, and they are the one thing in this module that
//! writes DDL rather than a statement over a table that already exists
//! ([ADR 123](../docs/adr/123-a-migration-is-a-diff-against-a-snapshot.md)).
//! They are also the one part that is not in a server: a diff is a tool, so it
//! spends nothing on any of ADR 017's four axes because it is not in the
//! process those axes measure.
//!
//! ## How it is put together
//!
//! | Piece | File | What it is |
//! |---|---|---|
//! | **Row** | `row.zig` | the marker, the borrow chain, the column list |
//! | **Shape** | `shape.zig` | a Row with a parent, children or aggregates: the joins, the groups, the children's statement |
//! | **Dialect** | `dialect.zig` | comptime, writes the SQL, may refuse |
//! | **where** | `where.zig` | a condition into a fragment and a value list |
//! | **statements** | `statement.zig` | every one of them, each as a constant |
//! | **types** | `types.zig` | Timestamp, Date and Json — value, not arithmetic. `Uuid` is `nilo_id`'s, and `AsText` is the door out |
//! | **schema** | `schema.zig` | Row against table, while the server starts |
//! | **table** | `table.zig` | what a Row says about the *table*: the marker's words |
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
//! ([ADR 064](../docs/adr/064-a-file-has-no-socket-to-wait-on.md),
//! [ADR 065](../docs/adr/065-one-writer-is-not-a-setting-it-is-the-database.md)) —
//! and the second of each is what turned the claim that the seams were in the
//! right place into evidence.
//!
//! **The dependency runs one way: this module imports `nilo`, and `nilo`
//! does not know this module exists.** That is what makes the feature cost
//! exactly zero to a project that does not import it — measured, not
//! assumed: the HTTP-only binary contains no pg or TLS content, and pg.zig
//! is `.lazy = true`, so it is not even downloaded (ADR 037).
//!
//! What it costs the projects that *do* import it is 733 KB, of which the
//! whole write half is 53 KB and the rest is pg.zig's TLS dependency. ADR
//! 037 has the numbers and the argument for why being a TLS client is not
//! the thing ADR 027 refused.
//!
//! **SQLite is 524,840 bytes on top of that, and only for a program that
//! names it.** Both drivers live here, so both are fetched and this module
//! links libc whichever one you use — but `sql/sqlite.zig` is analysed only
//! when something names it, so the amalgamation is dropped outright by the
//! linker. A binary holding `sql.Db` and nothing else contains zero SQLite
//! strings; `zig build size-sql` is the A/B, and ADR 064 has both numbers.

const std = @import("std");

pub const row = @import("row.zig");
pub const table = @import("table.zig");
pub const dialect = @import("dialect.zig");
pub const wire = @import("wire.zig");
pub const where = @import("where.zig");
pub const statement = @import("statement.zig");
pub const ordering = @import("ordering.zig");
pub const shape = @import("shape.zig");
pub const composed = @import("composed.zig");
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
/// ([ADR 123](../docs/adr/123-a-migration-is-a-diff-against-a-snapshot.md)).
///
/// **Nothing here is on the request path and nothing here is in a server.** A
/// program that never names it links none of it, the same way `sqlite.zig` is
/// dropped by a program holding only `sql.Db`.
///
/// Two calls cover the two ends. `migrate.createMissing(&db, &run, .{ .tables = &.{ … } })` is
/// a small application's whole startup, and every statement it sends is a
/// constant in the binary. `migrate.plan(…)` is the diff a tool generates from,
/// and it touches no database at all.
pub const migrate = @import("migrate.zig");

/// What a handler holds. `*sql.Db` in a signature is a service like any
/// other, so `listen()` checks it is registered before the first request
/// rather than after (ADR 005).
pub const Db = db.Db;
pub const Schema = migrate.Schema;

/// One statement that has run, as `db.watching`'s function is told about it
/// ([ADR 108](../docs/adr/108-a-statement-can-be-watched.md)). The text,
/// the plan name, how long it took and how many rows moved — and not the
/// values, which is the decision rather than the first version.
pub const Sent = db.Sent;

/// What `db.page` answers with: the rows on this page and how many the
/// condition matched before the `.limit` cut it
/// ([ADR 150](../docs/adr/150-a-page-knows-what-it-left-out.md)).
///
/// Naming it is for a caller keeping one in a struct of their own — a handler
/// returning `!sql.Page(Order)` sends `{"rows":[…],"total":47}`.
pub const Page = db.Db.Page;

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
/// Two names are two types and two types are two services (ADR 010), so
/// which pool a statement takes is written where a reader will see it: the
/// handler's argument list
/// ([ADR 054](../docs/adr/054-a-second-database-is-a-second-type.md)).
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
/// ([ADR 055](../docs/adr/055-the-second-dialect-is-the-test-of-the-seam.md)).
/// What is *not* the same is written where it happens rather than here:
/// `insertMany` and `tx.deadline` are Refusals, `.lock` is a Refusal, and a
/// list column has nowhere to live.
///
/// **`threading` has no default and that is deliberate**, so this call is one
/// line longer than `sql.Db` is. SQLite runs inside this process, so a
/// statement either holds the executor thread it is on or pays a hop to the
/// Engine's thread pool, and which is right is a fact about a deployment
/// ([ADR 064](../docs/adr/064-a-file-has-no-socket-to-wait-on.md)).
pub fn Sqlite(comptime opts: sqlite.Options) type {
    return db.DbOf(sqlite.Wire(opts), dialect.SQLite, "");
}

/// A second SQLite database, named the way `Named` names a second Postgres
/// one — and the same call to reach for when a program holds both kinds at
/// once, which [ADR 054](../docs/adr/054-a-second-database-is-a-second-type.md)
/// already made expressible.
pub fn SqliteNamed(comptime name: []const u8, comptime opts: sqlite.Options) type {
    if (name.len == 0) @compileError(
        "nilo: `sql.SqliteNamed(\"\")` has no name, so it is `sql.Sqlite` with extra steps.\n" ++
            "  Give it the one a reader would want in the argument list: " ++
            "`sql.SqliteNamed(\"cache\", …)`, `sql.SqliteNamed(\"audit\", …)`.",
    );
    return db.DbOf(sqlite.Wire(opts), dialect.SQLite, name);
}

/// The Dialect used unless something says otherwise. `sql.SQLite` is the
/// second, and what building it found is in
/// [ADR 055](../docs/adr/055-the-second-dialect-is-the-test-of-the-seam.md).
/// This comment said for a year that SQLite was "SQL half only"; it has had
/// a Wire since ADR 064.
pub const Postgres = dialect.Postgres;
pub const SQLite = dialect.SQLite;

pub const Timestamp = types.Timestamp;
/// A calendar day, read out of the column rather than out of a `::text`
/// ([ADR 181](../docs/adr/181-the-marker-has-two-kinds-of-word.md)).
pub const Date = types.Date;
pub const Uuid = types.Uuid;
pub const Json = types.Json;
pub const Decimal = types.Decimal;
pub const Interval = types.Interval;
pub const Inet = types.Inet;

/// Bytes rather than text: a `bytea` on Postgres and a `BLOB` on SQLite.
/// `sql.Bytes.of(hash)` at a call site; the slice a read hands back lives in
/// the request arena, the way a `Str` does.
pub const Bytes = types.Bytes;

/// A column type declared by whoever owns it rather than by this module: any
/// struct or enum with `nilo_column`, `nilo_read(text, arena)` and
/// `nilo_write(arena)`. `AsText("money")` is the smallest instance of that
/// protocol — the value *is* the text Postgres prints
/// ([ADR 049](../docs/adr/049-a-column-type-can-come-from-outside-this-module.md)).
pub const AsText = types.AsText;

pub const Column = wire.Column;
pub const Error = wire.Error;

/// What the database said about a statement it refused, as `Sent.problem`
/// carries it ([ADR 117](../docs/adr/117-a-statement-that-failed-says-what-the-database-said.md)).
///
/// `Error` is what a handler switches on; this is the text behind it, and
/// before it existed the whole of that text was a `std.log.err` line no
/// program could reach. It lives in the Scope's arena, so a watcher keeping
/// one past the request copies it.
pub const Problem = wire.Problem;

/// What the database said about the last statement **this fiber** ran, or
/// null when it worked
/// ([ADR 117](../docs/adr/117-a-statement-that-failed-says-what-the-database-said.md)).
///
/// ```zig
/// db.delete(Staff, c, .{ .where = .{ .id = id } }) catch |err| switch (err) {
///     error.ForeignKeyViolated => return nilo.fail.conflict(
///         "{s} was given something to do a moment ago and can no longer be deleted.",
///         .{name},
///     ),
///     else => return err,
/// };
/// ```
///
/// `Error` is the word to switch on and this is what to read after it —
/// `problem.constraint` names *which* unique index fired, which is the half
/// an error name cannot carry. Read it in the `catch`: it lives as long as
/// the request does, and the next statement on this fiber replaces it.
pub const problem = db.lastProblem;
/// Whether the last statement broke the key or the `.unique` over these
/// columns, checked against the marker while compiling (ADR 117).
pub const violated = db.violated;

/// What a transaction is begun with, and what a read holds on to. Both are
/// written as literals at the call — `db.begin(c, .{ .isolation = .serializable })`,
/// `.lock = .update` — so naming either type is for a caller keeping one in a
/// struct of their own.
/// A value a condition only has *sometimes*: the term is in the statement
/// when the filter carried one, and out of it when it did not
/// ([ADR 149](../docs/adr/149-a-filter-that-is-absent-is-not-a-filter-that-is-null.md)).
///
/// ```zig
/// const found = try db.page(Partner, c, .{
///     .where = .{
///         .name = .{ .icontains = sql.given(filter.search) },
///         .exists = .{.{ .in = PartnerCapability, .where = .{
///             .capability = sql.given(filter.capability),
///         } }},
///     },
///     .order = .{ .name = .asc },
///     .limit = 20,
/// });
/// ```
///
/// **Absent and null are two different questions.** `.status = null` is `IS
/// NULL` and asks for the rows whose status is nothing; this asks for no
/// condition on status at all. Nobody with a search box wants the first.
///
/// Inside an `.exists` it drops the whole subquery, and it has to be the only
/// condition in that subquery — the ADR says why. It is refused in the
/// condition of an `UPDATE` or a `DELETE`, and inside `.any`.
pub const given = where.given;

/// The type `sql.given` produces, for a caller naming one in a struct of
/// their own.
pub const Given = where.Given;

/// An `ORDER BY` chosen per request from a closed set declared while
/// compiling ([ADR 165](../docs/adr/165-an-order-chosen-at-run-time-from-a-closed-set.md)).
///
/// ```zig
/// const Sort = sql.Ordering(Commitment, .{
///     .due = .{ .column = .due_at, .nulls = .last },
///     .title = .title,
/// });
///
/// // `?order=due:desc,title` reads straight into the field
/// fn list(db: *sql.Db, c: *nilo.Ctx, q: nilo.Query(struct {
///     order: Sort = Sort.by(&.{.{ .key = .due }}),
/// })) !sql.Page(Commitment) {
///     return db.page(Commitment, c, .{ .order = q.value.order, .limit = 20 });
/// }
/// ```
///
/// A key that is a column orders `db.select`, `db.one` and `db.page`; one
/// that is the caller's own SQL is for `db.rawOrdered`, which writes the
/// clause where the statement says `{order}`. No run-time string reaches
/// the statement either way — a term picks a fragment settled while
/// compiling. What an ordered statement gives up is its plan name.
pub const Ordering = ordering.Ordering;

/// A statement composed at run time from literals, checked identifiers and
/// parameters — what a query engine hands `db.composed` (ADR 208).
/// `db.compose(c)` makes one spelled for the Db; `Composed.init(arena,
/// Spelling.of(Dialect))` where no Db is in scope.
pub const Composed = composed.Composed;
pub const Spelling = composed.Spelling;

pub const Begin = wire.Begin;
pub const Isolation = wire.Isolation;
pub const Lock = dialect.Lock;

/// The marker a Row carries, exported so that a caller writing one can name
/// it rather than remembering the spelling.
pub const table_marker = row.marker;

/// The `SELECT` a Row and a set of options compile to. The headline of ADR
/// 036 in one call: what comes back exists before the program runs.
pub fn selectFor(comptime Row: type, comptime Options: type) statement.Statement {
    return comptime statement.select(Postgres, Row, Options);
}

/// The same `SELECT` with the `LIMIT 1` `db.one` compiles for itself. A
/// `.limit` written alongside it is a Refusal — the ceiling belongs to the
/// call rather than to the caller.
pub fn oneFor(comptime Row: type, comptime Options: type) statement.Statement {
    return comptime statement.one(Postgres, Row, Options);
}

/// The same `SELECT` with `count(*) OVER ()` on the end of its column list,
/// which is what `db.page` compiles (ADR 150). `.limit` and `.order` are
/// both required and `.lock` is refused.
pub fn pageFor(comptime Row: type, comptime Options: type) statement.Statement {
    return comptime statement.page(Postgres, Row, Options);
}

/// The `UPDATE … RETURNING` and `DELETE … RETURNING` behind the two calls
/// that answer with one row. The same statements as the plural calls; what
/// these add is the Refusal of a `.where` that could match more than one row
/// (ADR 146).
pub fn updateReturningOneFor(comptime Row: type, comptime Options: type) statement.Statement {
    return comptime statement.updateReturningOne(Postgres, Row, Options);
}

pub fn deleteReturningOneFor(comptime Row: type, comptime Options: type) statement.Statement {
    return comptime statement.deleteReturningOne(Postgres, Row, Options);
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

/// The one-row `SELECT` behind `db.exactlyOne`, for a Row grouped by
/// nothing: every aggregate it declares, over the rows the condition matched
/// (ADR 218).
pub fn exactlyOneFor(comptime Row: type, comptime Options: type) statement.Statement {
    return comptime shape.exactlyOne(Postgres, Row, Options);
}

/// The second statement a children field is read by: every child of every
/// parent, numbered by the parent it belongs to (ADR 218).
pub fn childrenFor(comptime Row: type, comptime field: []const u8) statement.Statement {
    return comptime shape.children(Postgres, Row, field);
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
    comptime conflict: anytype,
) statement.Statement {
    return comptime statement.insertOrIgnore(Postgres, Row, Values, conflict);
}

pub fn insertOrUpdateFor(
    comptime Row: type,
    comptime Values: type,
    comptime conflict: anytype,
) statement.Statement {
    return comptime statement.insertOrUpdate(Postgres, Row, Values, conflict);
}

/// The `UPDATE`. Both `.set` and `.where` are required, and the numbering
/// runs through them in that order.
pub fn updateFor(comptime Row: type, comptime Options: type) statement.Statement {
    return comptime statement.update(Postgres, Row, Options);
}

/// The seventeen `…For` functions above, bound to a Dialect of the caller's
/// choosing: `sql.on(sql.SQLite).selectFor(User, Options)` is what a program
/// on SQLite compiles to, spelled with `?1` and `LIKE` where the Postgres
/// version says `$1` and `ILIKE`. The bare `selectFor` is `on(Postgres)`,
/// which is the default Dialect and was, until this existed, the only one a
/// reader could ask — so a program on SQLite could not see the constant
/// ADR 036 is about.
///
/// A namespace rather than a Dialect parameter on each of the seventeen,
/// because every existing call and every refusal names them with two
/// arguments and nothing about the Postgres default was wrong.
pub fn on(comptime D: type) type {
    return struct {
        pub fn selectFor(comptime Row: type, comptime Options: type) statement.Statement {
            return comptime statement.select(D, Row, Options);
        }
        pub fn oneFor(comptime Row: type, comptime Options: type) statement.Statement {
            return comptime statement.one(D, Row, Options);
        }
        pub fn pageFor(comptime Row: type, comptime Options: type) statement.Statement {
            return comptime statement.page(D, Row, Options);
        }
        pub fn countFor(comptime Row: type, comptime Options: type) statement.Statement {
            return comptime statement.count(D, Row, Options);
        }
        pub fn existsFor(comptime Row: type, comptime Options: type) statement.Statement {
            return comptime statement.exists(D, Row, Options);
        }
        pub fn findFor(comptime Row: type, comptime Key: type) statement.Statement {
            return comptime statement.find(D, Row, Key);
        }
        pub fn exactlyOneFor(comptime Row: type, comptime Options: type) statement.Statement {
            return comptime shape.exactlyOne(D, Row, Options);
        }
        pub fn childrenFor(comptime Row: type, comptime field: []const u8) statement.Statement {
            return comptime shape.children(D, Row, field);
        }
        pub fn deleteFor(comptime Row: type, comptime Options: type) statement.Statement {
            return comptime statement.delete(D, Row, Options);
        }
        pub fn updateReturningFor(comptime Row: type, comptime Options: type) statement.Statement {
            return comptime statement.updateReturning(D, Row, Options);
        }
        pub fn deleteReturningFor(comptime Row: type, comptime Options: type) statement.Statement {
            return comptime statement.deleteReturning(D, Row, Options);
        }
        pub fn insertFor(comptime Row: type, comptime Values: type) statement.Statement {
            return comptime statement.insert(D, Row, Values);
        }
        pub fn insertManyFor(comptime Row: type, comptime Values: type) statement.Statement {
            return comptime statement.insertMany(D, Row, Values);
        }
        pub fn updateManyFor(comptime Row: type, comptime Values: type) statement.Statement {
            return comptime statement.updateMany(D, Row, Values);
        }
        pub fn insertOrIgnoreFor(comptime Row: type, comptime Values: type, comptime conflict: anytype) statement.Statement {
            return comptime statement.insertOrIgnore(D, Row, Values, conflict);
        }
        pub fn insertOrUpdateFor(comptime Row: type, comptime Values: type, comptime conflict: anytype) statement.Statement {
            return comptime statement.insertOrUpdate(D, Row, Values, conflict);
        }
        pub fn updateFor(comptime Row: type, comptime Options: type) statement.Statement {
            return comptime statement.update(D, Row, Options);
        }
    };
}

/// A Row with every `Str` replaced by `[]const u8` — what `db.stream` hands
/// back, and a type that says its text dies at the next row rather than
/// leaving that to a comment (ADR 036).
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
    _ = ordering;
    _ = shape;
    _ = composed;
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

test "on(SQLite) spells the same statement the way that database reads it" {
    const options = @TypeOf(.{ .where = .{ .email = .{ .ilike = @as([]const u8, "%@b.com") } }, .limit = 10 });
    const pg = comptime selectFor(User, options);
    const lite = comptime on(SQLite).selectFor(User, options);
    try testing.expectEqualStrings(pg.sql, comptime on(Postgres).selectFor(User, options).sql);
    try testing.expectEqualStrings(
        "SELECT \"id\", \"email\", \"age\", \"created_at\" FROM \"users\" WHERE \"email\" LIKE ?1 LIMIT 10",
        lite.sql,
    );
    try testing.expect(std.mem.indexOf(u8, pg.sql, "ILIKE $1") != null);
}

test "a delete shares the walker rather than having a second one" {
    const found = comptime deleteFor(User, @TypeOf(.{ .where = .{ .id = 7 } }));
    try testing.expectEqualStrings("DELETE FROM \"users\" WHERE \"id\" = $1", found.sql);
}
