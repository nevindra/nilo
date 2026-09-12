# Running it

What happens between `init` and the first query, and what a query answers
when it cannot answer a Row: the check at startup, the stack a handler
holds, a second database, the prepared statements you did not ask for, the
log line that shows them, and the nine errors.

## When a Row and its table disagree

<!-- compiles: body -->
```zig
db.checking(&.{ User, Order });
```

Each Row is compared against the table it names, once, while the server
starts. A column that is missing, or is `text` where the struct says `i32`,
stops startup with a line naming it — instead of becoming a 500 at three in
the morning on whichever request reached it first.

A table that is not there at all is **one** line rather than one per column,
because the mistake is one mistake:

```
nilo_sql: nilo: User reads table "users", and the database has no table by
that name
```

which is usually a migration that has not run.

Set `.schema_mismatch_is_fatal = false` to log and carry on.

## The arena is cheaper than the stack

Worth knowing before you write a handler that needs a scratch buffer, because
it is the opposite of the usual Zig advice:

```zig
fn report(db: *sql.Db, c: *nilo.Ctx) ![]const u8 {
    var buf: [64 * 1024]u8 = undefined;               // ✗ per connection
    const buf = try c.arena().alloc(u8, 64 * 1024);   // ✓ per request
```

A connection waiting for its next request is a **suspended fiber**, and a
suspended fiber holds its stack at the deepest point it ever reached. So a
64 KiB stack buffer is 64 KiB held for as long as that connection stays open —
measured one byte per byte, from 8 KiB to 128 KiB
([ADR 0063](../../adr/0063-a-handlers-stack-is-per-connection.md)). The arena is
reset after every request.

It applies to the database path too, and that is where the number came from: a
route that reads one row and answers JSON holds **17,022 bytes** per idle
connection against **8,749** for one that returns a constant. Most of the
difference is how deep the driver's protocol code goes, and none of it is
something the query did.

## A second database

The Service registry is keyed by type, so `*sql.Db` is *the* database and a
second one had nowhere to live. `sql.Named` gives it a type of its own:

<!-- compiles -->
```zig
const Replica = sql.Named("replica");

fn listing(rdb: *Replica, c: *nilo.Ctx) ![]Product {     // may be stale
    return rdb.select(Product, c, .{ .order = .{ .name = .asc } });
}

fn buy(db: *sql.Db, c: *nilo.Ctx) !Order {               // must not be
    return db.insert(Order, c, .{ .user_id = 1, .total = 4200 });
}
```

Two names are two types and two types are two services, so both are
`app.provide`d and both are checked at `listen()` like any other. **Which
pool a statement takes is in the argument list**, which is where you can see
it without leaving the line.

Nothing routes anything, and that is deliberate. A reader that sent writes to
the primary and reads to a replica would need health checking, lag awareness
and read-after-write safety — three background tasks this module does not
have, and the last one fails *silently*
([ADR 0060](../../adr/0060-a-second-database-is-a-second-type.md)). Writing
`*Replica` in a signature is you saying "stale is fine here", once, on
purpose.

It is not only for replicas: a reporting warehouse, a second tenant, a
database somebody else owns. `sql.Named("")` is a compile error, because the
name is the whole mechanism.

There is no query cache and there will not be one. The speed case is the
strong half — a round trip is 24 µs and the query inside it is 2 — but
invalidation cannot be right from here, because this module sees only the
writes that go through it. Hold the value in a Service of your own, where the
rule for when it goes stale is a rule you know.

## Statements are prepared, and you did nothing to ask for it

Every statement this module sends is settled while compiling, so there is a
fixed set of them and each one is kept prepared on the connection it went
down. The second time a connection sends it, Postgres skips Parse and
Describe.

It is worth about **12 µs a query** — 30% of a key lookup, 14% of a page with
a sort and a range
([ADR 0057](../../adr/0057-a-statement-that-is-a-constant-can-be-prepared-once.md)).
A fixed saving, so the cheap queries a service runs most of are the ones it
helps most. Nothing in your code changes.

`db.raw` is in it too. Its text is comptime, so its name is derived the same
way ([ADR 0148](../../adr/0148-a-raw-statement-is-counted-while-compiling.md)).

**Turn it off behind pgbouncer in transaction mode.**

<!-- compiles: body -->
```zig
var db = sql.Db.init(gpa, url, .{ .prepared = false });
```

A transaction-mode pooler hands out a different server connection per
transaction, so a statement prepared on one is missing on the next. The
failure is loud — Postgres says the prepared statement does not exist — which
is why the default is the fast one rather than the safe one.

## Seeing the statements a request sent

One line per request tells you a page is slow. What was slow *in* it is the
statements, and `db.watching` is how they are shown:

<!-- compiles: body -->
```zig
db.watching(sql.logging);       // one debug line per statement
```

Set it before `listen()`. `sql.logging` writes the duration, the row count and
the text at debug level; anything narrower is a function of your own:

<!-- compiles -->
```zig
fn slowOnes(sent: sql.Sent) void {
    if (sent.micros < 50_000) return;
    std.log.warn("slow query: {d}us, {s}", .{ sent.micros, sent.sql });
}
```

`db.watching(slowOnes)`, and nothing else changes. A `sql.Sent` carries the
statement, the name it is kept prepared under, how long the database took, how
many rows moved, and whether it failed. **Not the
values it bound** — those are the interesting half and they are also somebody's
password, so putting them in a log is a decision rather than a default
([ADR 0137](../../adr/0137-a-statement-can-be-watched.md)).

A statement that failed carries one thing more: `sent.problem`, which is what
the database said about refusing it.

<!-- compiles -->
```zig
fn whyItFailed(sent: sql.Sent) void {
    const said = sent.problem orelse return;
    std.log.warn("{s} [{s}] on {s}: {s}", .{
        said.message, said.code, said.constraint, sent.sql,
    });
}
```

`message` always says something. When the driver refused the statement before
it left the process — a value it will not bind — there is no server message, so
the Zig error's own name goes there instead. `code` is the SQLSTATE, `23505`
for a duplicate key; `severity`, `detail`, `hint` and `constraint` are the rest
of what Postgres knew. Fields a database does not answer are empty rather than
null, because SQLite has no SQLSTATE and does not invent one
([ADR 0146](../../adr/0146-a-statement-that-failed-says-what-the-database-said.md)).

It lives in the request's arena, so keeping one past the request means copying
it. **`detail` is usually the values that collided**, which is worth knowing
before you log it. None of it ever reaches the client.

A `Db` nobody is watching pays one null test per statement, and a watched one
pays two clock reads at 15ns each.

## Views, and the one thing a check cannot know

A Row can name a **view** or a **materialized view** instead of a table, and
everything works the same way — reading it, checking it, `db.raw` past it.

One half of the check is skipped there, and it has to be: Postgres does not
track `NOT NULL` through a view, so every column of one reads as nullable
whatever its source column was. Checking that would flag every non-optional
field of a Row over a view, so the column's **type** is compared and its
nullability is left alone
([ADR 0056](../../adr/0056-a-view-is-a-table-that-cannot-say-what-is-not-null.md)).

## Columns the database fills in

An identity key, a sequence default and a generated column all work with
nothing said about them, because an insert names a **subset** of the Row's
columns and `RETURNING` is not optional:

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

A batch is the same: the arrays hold only the columns that were written. Note
that a generated column carries no `NOT NULL` unless one was written, so the
Row reads it as an optional.

A Row can say three more things about its table, and they are the subject of
[Making the tables](./migrations.md). Everything past those three — a check
constraint, a partial index, a trigger — is written where you write the rest of
your DDL. The half that reaches a handler is already done either way: a unique
violation is `error.AlreadyExists` and a 409.


## Errors

The module raises nine, and they read:

| | |
|---|---|
| `error.AlreadyExists` | a unique violation — **409** by default |
| `error.ForeignKeyViolated` | a row this statement names is not there, or a row it removes is still named by another. No default |
| `error.NotNullViolated` | a `NOT NULL` column was sent a null — 500 |
| `error.CheckViolated` | a `CHECK` said no |
| `error.ConstraintViolated` | whatever is left — an exclusion constraint, a `RESTRICT` |
| `error.Locked` | a `.lock = .update_nowait` found a row somebody else holds. No default |
| `error.Disconnected` | the database went away, or was never there |
| `error.TimedOut` | a statement ran past the `tx.deadline` you set |
| `error.QueryFailed` | anything else. The server's text is logged, never sent |

Only the first has a default answer, and that is on purpose. A duplicate
email on a signup is a 409; the same code inside a background import is not
an HTTP answer at all; on a table used to win a race it is the expected
outcome. The module does not know which request it is inside, so it hands you
an error that reads and lets you decide:

<!-- compiles: body -->
```zig
const made = db.insert(User, c, .{ .email = email }) catch |err| switch (err) {
    error.AlreadyExists => return nilo.fail.conflict("{s} is already taken", .{email}),
    else => return err,
};
```

**`ForeignKeyViolated` has no default for the same reason, and it is the one
worth knowing about.** It is the only constraint failure that is routinely a
race rather than a bug: a delete guarded by a count is right up until somebody
adds a child row between the two statements.

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

**And when the name is not enough, `sql.problem(c)` is what the database
actually said** ([ADR 0184](../../adr/0184-a-failure-belongs-to-the-call-that-caused-it.md)).
A table with two unique indexes on it raises one error for both; the
`constraint` field is what says which:

```zig
const said = sql.problem(c) orelse return err;
if (std.mem.eql(u8, said.constraint, "users_email_key")) {
    return nilo.fail.conflict("that email is already listed", .{});
}
```

It answers for the last statement **this fiber** ran, and null when it worked.
Read it in the `catch`: it lives as long as the request does, and the next
statement replaces it. `db.watching` is the other end of the same information
and is for logging every statement rather than branching on one.
