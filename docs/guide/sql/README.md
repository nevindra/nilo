# Talking to a database

`nilo_sql` is a second module. You import it separately, and a project that
never imports it links none of it — not the driver, not TLS, nothing.

```zig
const nilo = @import("nilo_http");
const sql = @import("nilo_sql");
```

**Ask for it in `build.zig` first**, with one field beside the two you already
pass:

```zig
const nilo = b.dependency("nilo", .{
    .target = target,
    .optimize = optimize,
    .sql = true,          // ← fetches pg.zig and zqlite; without it, this module refuses to build
});
```

That flag exists because the drivers are 11 MB and most projects want neither.
Leaving it out and importing `nilo_sql` anyway is a compile error saying this
in one sentence, rather than a missing module or a mysterious `pg` — see
[ADR 066](../../adr/066-a-lazy-dependency-is-a-request.md), which is also the
account of why `.lazy = true` on its own was not enough.

The idea is the same one the HTTP half runs on, pointed at a database: **the
struct you already wrote is the contract, and the compiler is the check.**

There are two databases behind that one idea. **`sql.Db` is Postgres and
`sql.Sqlite(…)` is SQLite**, and everything in this guide is written once and
works against either — the same Rows, the same conditions, the same
transactions. The guide says Postgres throughout because that is the longer
story; [SQLite](./sqlite.md) says what changes, and it is one line of wiring
and five things SQLite refuses.

**One whole program is [`examples/sqlite/`](../../../examples/sqlite/main.zig)**:
two Rows on one file, the tables made at boot with `createMissing` and
checked after, a list with a `Query`, a page of invoices with their
customer as a parent, a customer with their invoices as children, a report
of grouped Rows with one line left to `raw`, and a transaction. `zig build
run-sqlite` starts it, and its tests run under `zig build test-sql`.

## The pages

Read them in order the first time; each assumes the ones above it.

1. [A table is a struct](./tables.md) — the Row, what a field may be, money,
   lists, and a column type of your own.
2. [Reading](./reading.md) — the query is a constant, conditions, a filter
   nobody set, one row or all of them, counting, paging, a deep page without
   `OFFSET`, a query with no server, and a result set too big to hold.
3. [A Row with more in it](./shapes.md) — a parent joined in, children read
   after, a sum by group, and a total over everything.
4. [Writing](./writing.md) — insert, update, delete, many rows at once, and
   a row that may already be there.
5. [Transactions](./transactions.md) — deadlines, isolation, holding the rows
   you read, and undoing one statement without losing the rest.
6. [Past one table](./raw.md) — `raw`, what a parameter may be, the join,
   the aggregate, the paged join, the statement that answers with nothing,
   and what SQLite does differently.
7. [SQLite](./sqlite.md) — one line of wiring, the one question it makes you
   answer, the five things it refuses, and dates out of a Timestamp.
8. [Making the tables](./migrations.md) — the same struct creates and changes
   the table, a diff that needs no database, and your own `db` command.
9. [Running it](./running.md) — the check at startup, the stack a handler
   holds, a second database, prepared statements, seeing what a request sent,
   and the nine errors.

## The whole of it

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

The struct is the table, the call is the statement, and a column that is not
there is a build error rather than a 500. The `Ctx` is where the rows go —
the request arena — so nothing is freed by hand; a query outside a request
takes a [`nilo.Run`](../../reference/core.md#run) in the same slot.

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

`listAdults` is the handler the [reading page](./reading.md) opens with.

`init` opens nothing. It cannot: the pool has to dial, dialling needs the
event loop, and the loop does not exist until `listen()` starts it. So the
pool is built inside `listen()`, before the first connection is accepted.

That has a consequence worth relying on: **your server starts with Postgres
switched off.** Working on an endpoint that never touches the database does
not mean starting a database first. The first request that *does* touch it
gets `error.Disconnected`, which is the truth, and a handler that returns it
answers 503: the request was fine, and the database was not there.

Set `.connect_on_init = 2` if you would rather find out at startup — in
production, that is usually what you want.

## If the database is on the same box, do not use TCP

This is the largest performance number in the whole module and it is a
connection string rather than anything in your code:

<!-- compiles: body -->
```zig
// 458,000 req/s with a real query per request
var db = sql.Db.init(gpa,
    "postgres://app:secret@%2Fvar%2Frun%2Fpostgresql%2F.s.PGSQL.5432/shop", .{});
```

Measured on one box, same server, same query: a Docker published port serves
197k requests a second, loopback TCP 359k, **a unix socket 458k** — and p99
halves. The cost is conntrack and netfilter, paid per packet, twice a round
trip ([`bench/result/sql.md`](../../../bench/result/sql.md)).

Two things about the spelling, because both are easy to get wrong:

- The host is the **full socket path**, `/var/run/postgresql/.s.PGSQL.5432`,
  not the directory libpq wants.
- **Percent-encode the slashes** — `%2F` — or the URL parser will not keep them
  in the host field. Getting it wrong is `error.Unexpected`.

A container reaching a database on the host does this by mounting the socket
directory; `sql/docker-compose.yml` shows the other direction.

## It is not an ORM

The word promises object-relational mapping, Zig has no objects, and every
mechanism that earns the name is refused: no change tracking, which costs a
copy of every row; no lazy relations, which are queries nobody wrote; no
identity map, which is a lifetime problem in a language with no garbage
collector.

A name is a promise, and `orm` would promise a `.save()` that is never going
to exist.

Migrations *are* here, and they are the one thing in this guide that is not a
query: [Making the tables](./migrations.md). They are not an ORM feature either —
nothing tracks a change or writes a statement you did not ask for.

## Measured against Drizzle

[Drizzle](https://orm.drizzle.team/) is the fair yardstick, and not because it
is popular. It refuses the same three things this module refuses, so what it
*does* carry is a worked list of what a library can owe a service without
becoming an ORM. On speed the two are already side by side, with eight other
libraries, in [`bench/result/sql.md` §8](../../../bench/result/sql.md).

Two whole areas come off before the list starts.

- **Runtime query composition**, Drizzle's `$dynamic`: a builder held in a
  variable and added to before it runs. This is the one thing this module
  cannot have rather than has not got, because the statement is a comptime
  constant. The answer past it is `db.raw`, and it always will be.
- **The validation packages**, `drizzle-zod` and its five siblings: they exist
  because a TypeScript type is gone by run time. A Zig struct is not, which is
  why one Row already feeds the query, the JSON body and the API description
  with nothing generated in between. Same for the ESLint plugin that catches an
  `update` with no `where`. That is a Refusal here, and the compiler holds it.

What is left splits three ways.

- **Refused on the record**, each with its ADR: set operations and CTEs
  ([052](../../adr/052-a-set-operation-over-one-table-is-a-condition.md));
  several statements in one round trip
  ([053](../../adr/053-a-round-trip-is-not-the-cost-worth-chasing.md)); automatic
  read-replica routing and a query cache
  ([054](../../adr/054-a-second-database-is-a-second-type.md)).
- **Waiting on a caller**: children two levels deep, and children through a
  key of several columns. A parent, children one level deep and a group are
  declared on the Row and ship
  ([ADR 218](../../adr/218-a-row-may-carry-its-parent-its-children-or-a-sum.md)),
  as does `.exists`
  ([ADR 218](../../adr/218-a-row-may-carry-its-parent-its-children-or-a-sum.md)). The tooling
  commands still missing are on [the roadmap](../../roadmap.md#next) under
  `nilo_sql`, and they wait on one question rather than on a decision:
  [ADR 123](../../adr/123-a-migration-is-a-diff-against-a-snapshot.md) made that,
  and the library under them is built.
- **Nobody has looked**: row-level security, and Postgres extensions.

A GUI over the database is not coming from here.

---

The reasoning behind all of it is in
[ADR 036](../../adr/036-the-shape-of-a-query-is-settled-while-compiling.md),
and how it was wired to a real driver is in
[ADR 037](../../adr/037-a-service-that-needs-the-loop-is-finished-when-the-loop-exists.md).
The whole surface on one page is in [the reference](../../reference/sql.md#nilo_sql),
and what it costs — including the connection string that is the largest
number in the module — is in [`bench/result/sql.md`](../../../bench/result/sql.md).
