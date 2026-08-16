# Talking to Postgres

`nilo_sql` is a second module. You import it separately, and a project that
never imports it links none of it — not the driver, not TLS, nothing.

```zig
const nilo = @import("nilo");
const sql = @import("nilo_sql");
```

The idea is the same one the HTTP half runs on, pointed at a database: **the
struct you already wrote is the contract, and the compiler is the check.**

## A table is a struct

```zig
const User = struct {
    pub const nilo_table = .{ .name = "users", .key = .id };

    id: i64,
    email: nilo.Str,
    age: i32,
    created_at: sql.Timestamp,
};
```

The table name is written out, never guessed. `User` → `users` looks clever
until `Category`, and every framework that guesses ends up shipping a list of
irregular nouns.

`.key` names the column that identifies a row, and defaults to `id` when
there is a field called that.

## The query is a constant

```zig
fn listAdults(db: *sql.Db, c: *nilo.Ctx) ![]User {
    return db.select(User, c, .{
        .where = .{ .age = .{ .gt = 18 } },
        .order = .{ .created_at = .desc },
        .limit = 10,
    });
}
```

That compiles to this, before the program runs:

```sql
SELECT "id", "email", "age", "created_at" FROM "users"
WHERE "age" > $1 ORDER BY "created_at" DESC LIMIT 10
```

Exactly one thing reaches run time and it is the `18`. Which table, which
columns, which operators, how many parameters — all settled while compiling,
and all a compile error when wrong:

```
$ zig build
error: nilo: User has no column `agee`, asked for in a condition.
       Did you mean `age`?
```

Note the `limit`. A literal is baked into the SQL, which also gives Postgres
a number to plan with. A limit held in a variable becomes a parameter
instead. That is the same rule read strictly, not an inconsistency: `10`
written in the source is shape, and shape is settled early.

## Conditions

Different fields are ANDed, because that is what a struct is. Several
operators on one field are ANDed too, so a range needs no `between` and no
second idea.

```zig
.where = .{
    .age = .{ .gte = 18, .lt = 65 },
    .email = .{ .like = "%@example.dev" },
    .deleted_at = null,                      // IS NULL
    .any = .{                                // OR, bracketed
        .{ .role = "admin" },
        .{ .verified = true },
    },
}
```

`.any` rather than `.or` because `or` is a Zig keyword and would have to be
written `.@"or"`. The cost is that `any` becomes a reserved column name, and
a Row with a column called that is refused by name rather than quietly
misread.

`.in` takes a list and compiles to `= ANY($1)` — **one** parameter, so the
statement stays a constant no matter how long the list is.

## Wiring it up

```zig
pub fn main() !void {
    const gpa = std.heap.smp_allocator;

    var db = sql.Db.init(gpa, "postgres://app:secret@localhost/shop", .{});
    defer db.deinit();
    db.checking(&.{ User, Order });     // optional, see below

    var app = nilo.App.init(gpa);
    defer app.deinit();

    try app.provide(&db);
    try app.get("/adults", listAdults);
    try app.listen(.{});
}
```

`init` opens nothing. It cannot: the pool has to dial, dialling needs the
event loop, and the loop does not exist until `listen()` starts it. So the
pool is built inside `listen()`, before the first connection is accepted.

That has a consequence worth relying on: **your server starts with Postgres
switched off.** Working on an endpoint that never touches the database does
not mean starting a database first. The first request that *does* touch it
gets `error.Disconnected`, which is the truth.

Set `.connect_on_init = 2` if you would rather find out at startup — in
production, that is usually what you want.

## Reading

```zig
const all   = try db.select(User, c, .{ .where = .{ .age = .{ .gt = 18 } } });
const maybe = try db.one(User, c, .{ .where = .{ .id = id } });
```

`one` returns `?User`, so a handler that returns `!?User` answers **404**
when there is nothing — and the OpenAPI document says so, because the `?`
already meant that. Two modules that never import each other, agreeing,
because they read the same struct you wrote.

Every call takes the `Ctx`. Not to read the request: for the request arena,
which is where the rows go. They live exactly as long as the response that
carries them, and nothing is freed by hand.

## Writing

```zig
const made = try db.insert(User, c, .{ .email = "a@b.c", .age = 30 });
// made.id is the generated key

const changed = try db.update(User, c, .{
    .set = .{ .age = 31 },
    .where = .{ .id = made.id },
});

const gone = try db.delete(User, c, .{ .where = .{ .id = made.id } });
```

`insert` names a **subset** of the columns, because the ones the database
fills in — a generated key, a `DEFAULT now()` — are exactly the ones you have
nothing to say about. What comes back is the whole row, via `RETURNING`, so
there is no second query to fetch what the database just had in its hand.

`update` and `delete` answer with the number of rows they touched, and both
**require** a condition. An update with no `.where` rewrites the table and a
delete with none empties it; each is reached by leaving something out rather
than by writing something down, so each is a compile error:

```
error: nilo: an update on User with no condition.
       That rewrites every row in the table. If it is meant, `db.raw` says
       so where somebody reading the code can see it.
```

## Transactions

```zig
var tx = try db.begin(c);
defer tx.deinit();                  // rolls back unless committed

const order = try tx.insert(Order, c, .{ .user_id = user.id, .total = 4200 });
_ = try tx.update(User, c, .{ .set = .{ .orders = user.orders + 1 }, .where = .{ .id = user.id } });

try tx.commit();
```

`tx` carries the same calls `db` does, all down the one connection it holds.
The `defer` is not decoration: a connection returned to the pool inside an
open transaction is a connection the *next* request runs inside a stranger's
transaction. `deinit` rolls back on every path out, including the ones nobody
wrote.

Forgetting it is caught in Debug by a counter checked at `db.deinit()`.

## Streaming a result set too big to hold

```zig
fn exportUsers(db: *sql.Db, c: *nilo.Ctx) !void {
    var s = try c.stream(200, "text/csv");

    var rows = try db.stream(User, c, .{});
    defer rows.close();

    while (try rows.next()) |u| try s.print("{d},{s}\n", .{ u.id, u.email });
    try s.finish();
}
```

A million rows runs flat. Postgres sends them all without being asked, but
they are read off the socket as they arrive, so memory stays bounded by the
read buffer and TCP carries the rest. No cursor needed.

The rows come back as `sql.Borrowed(User)`, which is `User` with every `Str`
replaced by `[]const u8`. That is deliberate and it is the type telling you
the truth: the text points into the buffer the rows arrive in and is invalid
after the next `next()`. A `Str` means *text that lives as long as the
request*, with no asterisk, so text that does not is not called one. Copy it
if you need to keep it.

`defer rows.close()` is required. A result set walked away from half-read
costs a connection — and unlike a transaction, which is rolled back when the
request ends, nothing else will ever close this one. Forgetting it is caught
in Debug by the same counter that watches transactions.

A Row with a `sql.Json(T)` column cannot be streamed, and that is a compile
error rather than a footnote. A borrowed row allocates nothing, which is what
makes a million of them run flat; parsing a document costs one allocation per
row. Read it with `select`, or read the column as `[]const u8` in a Row of
its own and parse it where you need it.

## Past one table

Joins, aggregates, subqueries, `HAVING`, window functions, CTEs — none of
them. The line is one sentence, **one table, conditions that filter rows**,
and past it the answer is `raw`:

```zig
const tally = try db.raw(Report, c,
    "SELECT u.country, count(*)::bigint AS n FROM users u " ++
    "JOIN orders o ON o.user_id = u.id GROUP BY u.country",
    .{},
);
```

`raw` still fills your struct, still uses the arena, still follows the `Str`
rule. It gives up the compile-time column check and nothing else; the
`SELECT` list has to line up with the struct's fields by position.

The line is drawn there because a builder's dialect surface grows with the
builder, and joins and aggregates are where databases disagree most. A
boundary you can state in a sentence is worth more than one further out,
because you can predict what it does without opening this page.

## When a Row and its table disagree

```zig
db.checking(&.{ User, Order });
```

Each Row is compared against the table it names, once, while the server
starts. A column that is missing, or is `text` where the struct says `i32`,
stops startup with a line naming it — instead of becoming a 500 at three in
the morning on whichever request reached it first.

Set `.schema_mismatch_is_fatal = false` to log and carry on.

## Errors

The module raises four, and they read:

| | |
|---|---|
| `error.AlreadyExists` | a unique violation — **409** by default |
| `error.ConstraintViolated` | foreign key, check or not-null — 500 |
| `error.Disconnected` | the database went away, or was never there |
| `error.QueryFailed` | anything else. The server's text is logged, never sent |

Only the first has a default answer, and that is on purpose. A duplicate
email on a signup is a 409; the same code inside a background import is not
an HTTP answer at all; on a table used to win a race it is the expected
outcome. The module does not know which request it is inside, so it hands you
an error that reads and lets you decide:

```zig
const made = db.insert(User, c, .{ .email = email }) catch |err| switch (err) {
    error.AlreadyExists => return nilo.fail.conflict("{s} is already taken", .{email}),
    else => return err,
};
```

## It is not an ORM

The word promises object-relational mapping, Zig has no objects, and every
mechanism that earns the name is refused: no change tracking, which costs a
copy of every row; no lazy relations, which are queries nobody wrote; no
identity map, which is a lifetime problem in a language with no garbage
collector.

A name is a promise, and `orm` would promise a `.save()` that is never going
to exist.

Migrations are not here and are not implied. Nothing in the design forecloses
them.

---

The reasoning behind all of it is in
[ADR 0039](../adr/0039-the-shape-of-a-query-is-settled-while-compiling.md),
and how it was wired to a real driver is in
[ADR 0040](../adr/0040-a-service-that-needs-the-loop-is-finished-when-the-loop-exists.md).
The whole surface on one page is in [the reference](../reference.md#nilo_sql).
