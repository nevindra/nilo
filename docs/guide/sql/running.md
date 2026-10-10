# Running a database: checks, logging and errors

**What happens between `init` and the first query, and what a query returns when it cannot return a Row: the startup check, stack memory, a second database, prepared statements, statement logging, and the ten errors.**

**Reference:** [`Db`](../../reference/sql.md#db), [errors](../../reference/sql.md#errors) · **Design:** [The SQL runtime](../../design/sql-runtime.md)

## Checking Rows against tables at startup

<!-- compiles: body -->
```zig
db.checking(.{ .tables = &.{ User, Order } });
```

**Each Row is compared against the table it names, once, while the server starts.** A column that is missing, or is `text` where the struct says `i32`, stops startup with a line naming it, instead of becoming a 500 at three in the morning on whichever request reaches it first.

A table that does not exist at all is reported in **one** line rather than one per column, because it is one mistake:

```
nilo_sql: nilo: User reads table "users", and the database has no table by
that name
```

This usually means a migration has not run.

Set `.schema_mismatch_is_fatal = false` to log the mismatch and carry on. The lines are then `warn` and not `err`, since nothing is refusing to start.

**A `Db` that never had `checking` called on it logs one `warn` line at startup** saying so: its Rows will only be checked by the first request that reads them, which is later than anybody wants. It is one line and not a failure, because a program with a `Db` and no Rows is a perfectly good program. If that is what you meant, set `.unchecked = true` in the options and the line goes away ([ADR 192](../../adr/192-a-db-with-no-schema-check-says-so-or-is-told.md)):

```zig
var scratch = sql.Db.init(gpa, url, .{ .unchecked = true });
```

The two cases used to look the same, and the unchecked one was what reached production: a Row that disagreed with its table, on a `Db` nobody had thought to check.

## Scratch memory: use the arena, not the stack

**A buffer on the stack is held for as long as the connection stays open; the same buffer in the arena is freed after the request.** This is the opposite of the usual Zig advice, so it is worth knowing before you write a handler that needs a scratch buffer:

```zig
fn report(db: *sql.Db, c: *nilo.Ctx) ![]const u8 {
    var buf: [64 * 1024]u8 = undefined;               // ✗ per connection
    const buf = try c.arena().alloc(u8, 64 * 1024);   // ✓ per request
```

A connection waiting for its next request is a **suspended fiber**, and a suspended fiber keeps its stack at the deepest point it ever reached. So a 64 KiB stack buffer is 64 KiB held for as long as that connection stays open. This was measured byte for byte, from 8 KiB to 128 KiB ([ADR 062](../../adr/062-where-a-connection-waits-is-what-it-costs.md)). The arena is reset after every request.

It applies to the database path too, which is where the number came from: a route that reads one row and returns JSON holds **17,022 bytes** per idle connection, against **8,749** for a route that returns a constant. Most of the difference is how deep the driver's protocol code goes, and none of it comes from the query itself.

## A second database

**`sql.Named` gives a second database its own type, so it can be a second service.** The service registry is keyed by type, so `*sql.Db` is *the* database, and a second one had nowhere to go:

<!-- compiles -->
```zig
const Replica = sql.Named("replica");

fn listing(rdb: *Replica, c: *nilo.Ctx) ![]Product {     // may be stale
    return rdb.select(Product, c, .{ .order = .{ .name = .asc } });
}

fn buy(db: *sql.Db, c: *nilo.Ctx) !Order {               // must not be
    return db.insert(Order, c, .{ .user_id = 1, .total = 4200, .status = "new" });
}
```

Two names are two types, and two types are two services, so both are registered with `app.provide` and both are checked at `listen()` like any other. **Which pool a statement uses is visible in the argument list**, without leaving the line.

Nothing routes queries automatically, on purpose. A router that sent writes to the primary and reads to a replica would need health checks, replication lag awareness and read-after-write safety: three background tasks this module does not have, and the last one fails *silently* ([ADR 054](../../adr/054-a-second-database-is-a-second-type.md)). Writing `*Replica` in a signature is you saying "stale is fine here", once, on purpose.

It is not only for replicas: a reporting warehouse, a second tenant, or a database somebody else owns all work the same way. `sql.Named("")` is a compile error, because the name is what makes the type distinct.

There is no query cache and there will not be one. The speed argument is real (a round trip is 24 µs and the query inside it is 2), but cache invalidation cannot be correct from here, because this module only sees the writes that go through it. Keep the value in a Service of your own, where you know the rule for when it goes stale.

## Prepared statements

**Every statement is prepared automatically, and you do not have to ask for it.** Every statement this module sends is fixed while compiling, so there is a fixed set of them, and each one is kept prepared on the connection it was sent on. The second time a connection sends it, Postgres skips Parse and Describe.

It saves about **12 µs a query**: 30% of a lookup by key, 14% of a page with a sort and a range ([ADR 051](../../adr/051-a-statement-that-is-a-constant-can-be-prepared-once.md)). The saving is fixed per query, so it helps most with the cheap queries a service runs most often. Nothing in your code changes.

`db.raw` statements are prepared too. Their text is comptime, so their name is derived the same way ([ADR 051](../../adr/051-a-statement-that-is-a-constant-can-be-prepared-once.md)).

**Turn it off behind pgbouncer in transaction mode:**

<!-- compiles: body -->
```zig
var db = sql.Db.init(gpa, url, .{ .prepared = false });
```

A transaction-mode pooler hands out a different server connection for each transaction, so a statement prepared on one connection is missing on the next. The failure is loud (Postgres says the prepared statement does not exist), which is why the default is the fast setting rather than the safe one.

A URL that says `pgbouncer=true` (or `pool_mode=transaction`) turns it off for you, so the line above is only for a pooler whose URL does not say so ([ADR 241](../../adr/241-a-postgres-url-without-sslmode-is-encrypted-unless-it-stays-on-this-machine.md)).

## Logging statements (`db.watching`)

**`db.watching` shows you each statement a request sent, with its duration.** One log line per request tells you a page is slow; the statements tell you what was slow *in* it:

<!-- compiles: body -->
```zig
db.watching(sql.logging);       // one debug line per statement
```

Set it before `listen()`. `sql.logging` writes the duration, the row count and the text at debug level. For anything more selective, write your own function:

<!-- compiles -->
```zig
fn slowOnes(sent: sql.Sent) void {
    if (sent.micros < 50_000) return;
    std.log.warn("slow query: {d}us, {s}", .{ sent.micros, sent.sql });
}
```

Pass it as `db.watching(slowOnes)`; nothing else changes. A `sql.Sent` carries:

- the statement text, and the name it is kept prepared under;
- how long the database took, how many rows were affected, and whether it failed;
- `route`: the name of the route whose request sent it (the `operationId` that `c.routeName()` returns), or null for a statement sent under a `Run`. That is how you tell that a slow `SELECT` belongs to `listDeals` and not to the facet count next to it that sends the same text.

A `db.raw` statement has a name too, so a watcher can count heavy raw reads by name rather than by text. The statements without a name are `db.exec`, a statement whose `ORDER BY` the request chose, and anything on a `Db` with `prepared = false`.

**The bound values are not included.** They are the interesting half, but they are also somebody's password, so putting them in a log is your decision, not a default ([ADR 108](../../adr/108-a-statement-can-be-watched.md)).

### What the database said about a failure

**A failed statement also carries `sent.problem`: what the database said when it rejected it.**

<!-- compiles -->
```zig
fn whyItFailed(sent: sql.Sent) void {
    const said = sent.problem orelse return;
    std.log.warn("{s} [{s}] on {s}: {s}", .{
        said.message, said.code, said.constraint, sent.sql,
    });
}
```

`message` always has something. When the driver rejected the statement before it left the process (a value it will not bind), there is no server message, so the Zig error's name goes there instead. `code` is the SQLSTATE, such as `23505` for a duplicate key; `severity`, `detail`, `hint` and `constraint` are the rest of what Postgres reported. Fields a database does not provide are empty rather than null, because SQLite has no SQLSTATE and nilo does not invent one ([ADR 117](../../adr/117-a-statement-that-failed-says-what-the-database-said.md)).

It lives in the request's arena, so keeping it past the request means copying it. **`detail` usually contains the values that collided**, which is worth knowing before you log it. None of it is ever sent to the client.

A `Db` nobody is watching pays one null check per statement, and a watched one pays two clock reads at 15 ns each.

### Query plans (`db.explain`)

**`db.explain` takes the same arguments as `db.select` and returns the plan of the statement that read would send, with the same values bound** ([ADR 232](../../adr/232-a-read-can-show-its-plan.md)):

<!-- compiles -->
```zig
fn planOfTheList(db: *sql.Db, c: *nilo.Ctx) ![]const u8 {
    return db.explain(User, c, .{ .where = .{ .age = .{ .gt = 18 } }, .limit = 20 });
}
```

On Postgres it is `EXPLAIN (ANALYZE, BUFFERS)`, which **runs the read** and reports what it did. On SQLite it is `EXPLAIN QUERY PLAN`, which only plans it. Use it from a test or a development endpoint. Against seeded data, a test can check the plan, so an index that goes missing fails the test suite instead of a page in production:

```zig
const plan = try db.explain(DealCard, &run, .{ .where = .{ .stage = .won }, .order = .{ .id = .desc }, .limit = 20 });
try std.testing.expect(std.mem.indexOf(u8, plan, "Seq Scan on deals") == null);
```

The plan covers the statement that reads the rows. A Row's children are read by a second statement, which is not included.

For a statement you wrote yourself, use `db.rawExplain` with the text and values `db.raw` would take, or `db.rawExplainOrdered` for one with the `{order}` placeholder:

<!-- compiles -->
```zig
fn planOfTheInvoices(db: *sql.Db, c: *nilo.Ctx) ![]const u8 {
    return db.rawExplain(c,
        "SELECT i.id, u.name FROM invoices i JOIN users u ON u.id = i.user_id WHERE i.total > $1",
        .{@as(i64, 100)});
}
```

It runs inside a transaction that is rolled back, because `ANALYZE` executes what it plans: the plan of an `UPDATE` leaves no row changed.

**On a test database with only a few rows, assert on the shape of the plan, not on which index it chose.** The planner prices a plan by the number of rows it expects, and over ten rows a sequential scan and a nested loop are the cheapest choice whatever indexes exist. An assertion of "no `Seq Scan`" then fails on a correct schema. What holds at any size is what the statement's shape decides: a `SubPlan` is there, a `Join` is not. An assertion about an index needs enough seeded rows for the index to win, and `ANALYZE` on the table after seeding.

## Views

**A Row can name a view or a materialized view instead of a table, and everything works the same way:** reading it, checking it, and `db.raw` against it.

One half of the startup check is skipped for views, and it has to be. Postgres does not track `NOT NULL` through a view, so every column of a view reads as nullable, whatever its source column was. Checking nullability would flag every non-optional field of a Row over a view, so only the column's **type** is compared ([ADR 050](../../adr/050-a-view-or-a-rowid-alias-is-not-a-nullable-column.md)).

## Generated columns and identity keys

**An identity key, a sequence default and a generated column all work with no extra setup**, because an insert names only **some** of the Row's columns and always uses `RETURNING`:

<!-- compiles: body -->
```zig
const Auto = struct {
    pub const nilo_table = .{ .name = "auto", .key = .id };

    id: i64,               // GENERATED ALWAYS AS IDENTITY
    label: nilo.Str,
    slug: ?nilo.Str,       // GENERATED ALWAYS AS (label || '-x') STORED
};

const made = try db.insert(Auto, c, .{ .label = "alpha" });
// made.id is the database's, made.slug is "alpha-x"
```

A batch works the same way: the arrays hold only the columns that were written. Note that a generated column has no `NOT NULL` unless you wrote one, so the Row reads it as an optional.

A Row can declare more about its table than its columns: a default, a unique, an index and its condition, a foreign key. That is the subject of [Making the tables](./migrations.md). Anything beyond those, such as a check constraint you wrote yourself or a trigger, goes wherever you write the rest of your DDL. The part a handler sees works either way: a unique violation is `error.AlreadyExists` and a 409.

## Errors

**The module returns ten errors, and three of them have a default HTTP answer:**

| | |
|---|---|
| `error.AlreadyExists` | a unique violation. **409** by default |
| `error.ForeignKeyViolated` | a row this statement refers to is not there, or a row it removes is still referred to by another. No default |
| `error.NotNullViolated` | a `NOT NULL` column was sent a null. No default |
| `error.CheckViolated` | a `CHECK` constraint failed |
| `error.ConstraintViolated` | any other constraint: an exclusion constraint, a `RESTRICT` |
| `error.Locked` | a `.lock = .update_nowait` found a row somebody else holds. No default |
| `error.Disconnected` | the database went away, or was never there. **503** by default |
| `error.RolledBack` | the database rolled the transaction back (a serialization failure, a deadlock). Run it again ([Transactions](./transactions.md#retrying-a-rolled-back-transaction)). **503** by default |
| `error.TimedOut` | a statement ran past the `tx.deadline` you set, a wait for a free connection ran out of `timeout_ms`, or the route's `nilo.deadline` ran out |
| `error.QueryFailed` | anything else. The server's text is logged, never sent |

Each of the three defaults means the same thing whatever the request was. A duplicate is a conflict. A database that is not there, or that rolled the work back, is a 503, and the client may send the request again. The rest have no default, on purpose: a failed check is a 422 for one endpoint and a 500 for another, and the module does not know which request it is running in. So it gives you an error you can read and lets you decide. A default is only a default: catch the error before it leaves the handler and the answer is yours:

<!-- compiles: body -->
```zig
const made = db.insert(User, c, .{ .email = email, .name = name }) catch |err| switch (err) {
    error.AlreadyExists => return nilo.fail.conflict("{s} is already taken", .{email}),
    else => return err,
};
```

**`ForeignKeyViolated` is the one worth knowing about.** It has no default for the same reason, and it is the only constraint failure that is usually a race rather than a bug: a delete that first checks a count is correct until somebody adds a child row between the two statements.

<!-- compiles: body -->
```zig
_ = db.delete(User, c, .{ .where = .{ .id = id } }) catch |err| switch (err) {
    error.ForeignKeyViolated => return nilo.fail.conflict(
        "{s} placed an order a moment ago and can no longer be deleted. " ++
            "Deactivate them instead.",
        .{name},
    ),
    else => return err,
};
```

### Which constraint failed (`sql.problem`, `sql.violated`)

**When the error name is not enough, `sql.problem(c)` returns what the database actually said** ([ADR 117](../../adr/117-a-statement-that-failed-says-what-the-database-said.md)). A table with two unique indexes raises the same error for both, and the `constraint` field tells you which one:

```zig
const said = sql.problem(c) orelse return err;
if (std.mem.eql(u8, said.constraint, "users_email_key")) {
    return nilo.fail.conflict("that email is already listed", .{});
}
```

For a unique declared on the Row, `sql.violated` asks the same question by column names, and checks them while compiling:

<!-- compiles: body -->
```zig
_ = db.insert(User, c, .{ .email = email, .name = name, .age = 30 }) catch |err| switch (err) {
    error.AlreadyExists => if (sql.violated(c, User, .{.email}))
        return nilo.fail.conflict("that email is already listed", .{})
    else
        return err,
    else => return err,
};
```

`users_email_key` in a string is a name nothing checks, and SQLite does not use it (it reports `users.email`). `sql.violated` accepts either, and a column list that is neither the key nor a `.unique` does not compile.

It answers for the last statement **this fiber** ran, and returns null when that statement worked. Read it inside the `catch`: it lives as long as the request, and the next statement replaces it. `db.watching` gives you the same information from the other end, for logging every statement rather than acting on one.
