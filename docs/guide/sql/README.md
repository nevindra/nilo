# Talking to a database

**`nilo_sql` reads and writes Postgres and SQLite through the structs you already wrote, and a query that does not fit the table is a build error.**

**Reference:** [`nilo_sql`](../../reference/sql.md#nilo_sql), [`Db`](../../reference/sql.md#db) · **Design:** [The query builder](../../design/sql-query.md), [The SQL runtime](../../design/sql-runtime.md)

## Adding it to a project

**`nilo_sql` is a separate module, and a project that never imports it links none of it**: not the driver, not TLS, nothing.

```zig
const nilo = @import("nilo_http");
const sql = @import("nilo_sql");
```

**Turn it on in `build.zig` first**, with one field beside the two you already pass:

```zig
const nilo = b.dependency("nilo", .{
    .target = target,
    .optimize = optimize,
    .sql = true,          // ← fetches pg.zig and zqlite; without it, this module refuses to build
});
```

The flag exists because the drivers are 11 MB and most projects want neither. If you leave it out and import `nilo_sql` anyway, you get a compile error that says so in one sentence, not a missing module or a confusing `pg` error. [ADR 066](../../adr/066-a-lazy-dependency-is-a-request.md) explains this, and why `.lazy = true` on its own was not enough.

The idea is the same one the HTTP side is built on, applied to a database: **the struct you already wrote is the contract, and the compiler is the check.**

There are two databases behind that one idea. **`sql.Db` is Postgres and `sql.Sqlite(…)` is SQLite**, and everything in this guide is written once and works against either: the same Rows, the same conditions, the same transactions. The guide uses Postgres throughout because it has more to explain. [SQLite](./sqlite.md) lists what changes: one line of wiring and five things SQLite refuses.

**[`examples/sqlite/`](../../../examples/sqlite/main.zig) is one complete program**: two Rows on one file, the tables created at boot with `createMissing` and checked afterwards, a list with a `Query`, a page of invoices with their customer as a parent, a customer with their invoices as children, a report of grouped Rows with one line left to `raw`, and a transaction. `zig build run-sqlite` starts it, and its tests run under `zig build test-sql`.

## The pages

Read them in order the first time; each assumes the ones before it.

1. [A table is a struct](./tables.md): the Row, what a field may be, money, lists, and a column type of your own.
2. [Reading](./reading.md): the query is a constant, conditions, optional filters, one row or all of them, counting, paging, a deep page without `OFFSET`, a query with no server, and a result set too big to hold.
3. [Parents, children and aggregates](./shapes.md): a parent joined in, children read after, a sum by group, and a total over everything.
4. [Writing](./writing.md): insert, update, delete, many rows at once, and a row that may already exist.
5. [Transactions](./transactions.md): deadlines, isolation, locking the rows you read, and undoing one statement without losing the rest.
6. [Raw SQL](./raw.md): `raw`, what a parameter may be, joins, aggregates, a paged join, a statement that returns nothing, and what SQLite does differently.
7. [SQLite](./sqlite.md): one line of wiring, the one question it makes you answer, the things it refuses, and dates out of a Timestamp.
8. [Migrations](./migrations.md): the same struct creates and changes the table, a diff that needs no database, and your own `db` command.
9. [Running a database](./running.md): the check at startup, the stack a handler holds, a second database, prepared statements, seeing what a request sent, and the ten errors.

## A complete example

<!-- compiles -->
```zig
const Coupon = struct {
    pub const nilo_table = .{ .name = "coupons", .key = .id };

    id: i64,
    code: nilo.Str,
    percent_off: i32,
};

fn generous(db: *sql.Db, c: *nilo.Ctx) ![]Coupon {
    return db.select(Coupon, c, .{
        .where = .{ .percent_off = .{ .gt = 20 } },
        .order = .{ .percent_off = .desc },
        .limit = 20,
    });
}
```

**The struct is the table and the call is the statement**, so a column that does not exist is a build error rather than a 500. The rows go into the request arena of the `Ctx`, so nothing is freed by hand. A query outside a request takes a [`nilo.Run`](../../reference/core.md#run) in the same place.

## Wiring it up

<!-- compiles -->
```zig
pub fn main() !void {
    const gpa = std.heap.smp_allocator;

    var db = sql.Db.init(gpa, "postgres://app:secret@localhost/shop", .{});
    defer db.deinit();
    db.checking(.{ .tables = &.{ User, Order } });     // optional — see Running it

    var app = nilo.App.init(gpa);
    defer app.deinit();

    try app.provide(&db);
    try app.get("/adults", listAdults);
    try app.listen(.{});
}
```

`listAdults` is the handler the [reading page](./reading.md) starts with.

**[`Db.init`](../../reference/sql.md#db) opens no connection.** It cannot: the pool has to dial, dialling needs the event loop, and the loop does not exist until `listen()` starts it. So the pool is built inside `listen()`, before the first connection is accepted.

This means **your server starts even when Postgres is down.** Working on an endpoint that never touches the database does not require starting a database first. The first request that does touch it gets `error.Disconnected`, and a handler that returns it answers 503: the request was fine, the database was not there.

Set `.connect_on_init = 2` if you would rather find out at startup. In production, that is usually what you want.

## Connecting over a unix socket

**If the database is on the same machine, connect over its unix socket instead of TCP.** This is the largest performance difference in the whole module, and it is a change to the connection string, not to your code:

<!-- compiles: body -->
```zig
// 458,000 req/s with a real query per request
var db = sql.Db.init(gpa,
    "postgres://app:secret@%2Fvar%2Frun%2Fpostgresql%2F.s.PGSQL.5432/shop", .{});
```

Measured on one machine, same server, same query: a Docker published port serves 197k requests a second, loopback TCP 359k, and **a unix socket 458k**, with p99 cut in half. The cost is conntrack and netfilter, paid per packet, twice per round trip ([`bench/result/sql.md`](../../../bench/result/sql.md)).

Two things about writing the address are easy to get wrong:

- The host is the **full socket path**, `/var/run/postgresql/.s.PGSQL.5432`, not the directory libpq expects.
- **Percent-encode the slashes** as `%2F`, or the URL parser will not keep them in the host field. Getting this wrong gives `error.Unexpected`.

A container that reaches a database on the host does this by mounting the socket directory; `sql/docker-compose.yml` shows the other direction.

## Why it is not an ORM

**`nilo_sql` has none of the features that make a library an ORM.** The word promises object-relational mapping, and Zig has no objects. Each ORM mechanism is left out on purpose: no change tracking, which costs a copy of every row; no lazy relations, which are queries nobody wrote; no identity map, which is a lifetime problem in a language with no garbage collector.

Calling it an ORM would promise a `.save()` that is never going to exist.

Migrations are included, and they are the only part of this guide that is not a query: [Migrations](./migrations.md). They are not an ORM feature either: nothing tracks a change or writes a statement you did not ask for.

## Compared with Drizzle

**[Drizzle](https://orm.drizzle.team/) is the fairest comparison**, and not because it is popular. It leaves out the same three things this module leaves out, so what it does include is a good list of what a library can offer a service without becoming an ORM. On speed the two are already compared, alongside eight other libraries, in [`bench/result/sql.md` §8](../../../bench/result/sql.md).

Two whole areas are out before the list starts:

- **Building a query at run time**, Drizzle's `$dynamic`: a builder kept in a variable and extended before it runs. This is the one thing this module cannot have, rather than has not built yet, because the statement is a comptime constant. The way past it is `db.raw`, and always will be.
- **The validation packages**, `drizzle-zod` and its five siblings. They exist because a TypeScript type is gone at run time. A Zig struct is not, which is why one Row already feeds the query, the JSON body and the API description with nothing generated in between. The same goes for the ESLint plugin that catches an `update` with no `where`: here that is a Refusal, and the compiler enforces it.

The rest falls into three groups:

- **Decided against**, each with its ADR: set operations and CTEs ([052](../../adr/052-a-set-operation-over-one-table-is-a-condition.md)); several statements in one round trip ([053](../../adr/053-a-round-trip-is-not-the-cost-worth-chasing.md)); automatic read-replica routing and a query cache ([054](../../adr/054-a-second-database-is-a-second-type.md)).
- **Waiting for someone who needs it**: children two levels deep, and children through a key of several columns. A parent, children one level deep and a group are declared on the Row and already ship ([ADR 218](../../adr/218-a-row-may-carry-its-parent-its-children-or-a-sum.md)), as does `.exists` ([ADR 218](../../adr/218-a-row-may-carry-its-parent-its-children-or-a-sum.md)). The tooling commands still missing are on [the todo list](../../todo.md) under `nilo_sql`. They wait on one open question, not on a design decision: [ADR 123](../../adr/123-a-migration-is-a-diff-against-a-snapshot.md) made that decision, and the library under them is built.
- **Not looked at yet**: row-level security, and Postgres extensions.

A GUI for the database is not planned here.

---

The reasoning behind all of it is in [ADR 036](../../adr/036-the-shape-of-a-query-is-settled-while-compiling.md), and how it was wired to a real driver is in [ADR 037](../../adr/037-a-service-that-needs-the-loop-is-finished-when-the-loop-exists.md). The whole API on one page is in [the reference](../../reference/sql.md#nilo_sql), and what it costs, including the connection string that makes the biggest difference, is in [`bench/result/sql.md`](../../../bench/result/sql.md).
