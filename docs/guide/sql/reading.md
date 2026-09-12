# Reading

The statement is settled while compiling, the conditions are a struct, and
what comes back is the Row the [tables page](./tables.md) declared. This page
is every way of asking; [writing](./writing.md) and
[transactions](./transactions.md) are the other two, and
[past one table](./raw.md) is where the statement is yours.

## The query is a constant

<!-- compiles -->
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
statement stays a constant no matter how long the list is. Its negation is
`.not_in`, which is `<> ALL($1)` and costs the same one parameter;
`.not_like` and `.not_ilike` are the other two. `.distinct_from` and
`.not_distinct_from` are the null-safe pair — see below.

### A null is written, never held

`.deleted_at = null` above is `IS NULL` because the compiler can see the
null. This is not:

```zig
const maybe: ?[]const u8 = c.query.handle;      // may or may not be there
.where = .{ .handle = maybe }                   // ✗ compile error
```

The two readings are two different statements — `"handle" = $1` and
`"handle" IS NULL` — and which one is right depends on a value that arrives
after the statement is already a constant. Sending `= $1` with NULL in it is
legal SQL and *never true*, so the query would run, match nothing and report
nothing at all.

Usually what you meant is SQL's null-safe comparison, and that **is** one
statement:

```zig
.where = .{ .handle = .{ .not_distinct_from = maybe } }   // ✓
```

`IS NOT DISTINCT FROM` is `=` with null treated as an ordinary value: two
nulls match, and null against anything else does not. It takes an optional
where nothing else does, and the reason is the same rule read the other way
— the statement is the same six words whether the value turns out to be null
or not, so nothing about its shape waits for run time. `.distinct_from` is
the negation, and it finds the null rows that `<>` silently drops.

Where the two cases really are two different queries, write the branch:

```zig
const found = if (maybe) |handle|
    try db.select(User, c, .{ .where = .{ .handle = handle } })
else
    try db.select(User, c, .{ .where = .{ .handle = null } });
```

Only the value you write is judged. A `?[]const u8` column compared against a
plain `[]const u8` is an ordinary condition, and so is every `.set` and every
`insert` — `SET handle = $1` with NULL in it means exactly one thing
([ADR 0044](../../adr/0044-a-condition-holds-a-value-not-a-maybe.md)).

## A filter nobody set

A search box that is empty is not a search for nothing. `.status = null` asks
for the rows whose status is null; a filter nobody set wants **no condition on
status at all**, which is the opposite — one matches a handful of rows and the
other matches every one.

`sql.given` is that, and it is a word rather than an optional so the two stay
tellable apart
([ADR 0183](../../adr/0183-a-filter-that-is-absent-is-not-a-filter-that-is-null.md)):

<!-- compiles: body -->
```zig
// search: ?[]const u8 and least_age: ?i32, straight off the query string.
const found = try db.page(User, c, .{
    .where = .{
        .email = .{ .icontains = sql.given(search) },
        .age = .{ .gte = sql.given(least_age) },
    },
    .order = .{ .id = .asc },
    .limit = 20,
});
```

```sql
($1 IS NULL OR "email" ILIKE …) AND ($2 IS NULL OR "age" >= $2)
```

**One statement whatever the screen is set to**, so one parameter list and one
prepared plan. The alternative — a statement per combination of filters — is
four for two filters and sixteen for four, each with its own parameter tuple.
Postgres folds `$1 IS NULL` away while it is planning with the actual values,
which it does for the first five executions and for as long after that as the
custom plan wins, so a filter that *is* set plans as if the guard were not
written.

Inside an `.exists` it drops the **whole subquery**, not the term:

<!-- compiles: body -->
```zig
// capability: ?nilo.Str — the dropdown nobody has touched yet.
const partners = try db.page(Partner, c, .{
    .where = .{ .exists = .{
        .{ .in = PartnerCapability, .where = .{ .capability = sql.given(capability) } },
    } },
    .order = .{ .name = .asc },
    .limit = 20,
});
```

With the term dropped instead, the subquery would ask whether the partner has
*any* capability row — which quietly excludes every partner that has none. For
the same reason a `sql.given` cannot sit beside a condition that is always there
in one `.exists`; write a second entry.

It is refused inside `.any` (OR reverses what dropping a term means), on `.in`
and `not_distinct_from`, on a value that is not optional, and **in the condition
of an `UPDATE` or a `DELETE`** — there a term that may not be there is the whole
table.


## All of them, one of them, or one by key

<!-- compiles: body -->
```zig
const all   = try db.select(User, c, .{ .where = .{ .age = .{ .gt = 18 } } });
const maybe = try db.one(User, c, .{ .where = .{ .id = id } });
```

`one` returns `?User`, so a handler that returns `!?User` answers **404**
when there is nothing — and the OpenAPI document says so, because the `?`
already meant that. Two modules that never import each other, agreeing,
because they read the same struct you wrote.

It compiles its own `LIMIT 1`, so a condition on a column that is not unique
costs one row rather than every match. Writing a `.limit` beside it is a
compile error: the ceiling belongs to the call.

A lookup by key is the same thing with the condition already filled in:

<!-- compiles -->
```zig
fn show(db: *sql.Db, c: *nilo.Ctx, id: i64) !?User {
    return db.find(User, c, id);
}
```

That is a whole endpoint. The column comes from the Row's `.key`, so it is
not written out at every call site, and `?User` is the 404. A struct where
the key goes is a compile error pointing at `one` — `find` takes the value
itself.

Every call takes the `Ctx`. Not to read the request: for the request arena,
which is where the rows go. They live exactly as long as the response that
carries them, and nothing is freed by hand.

## Counting

<!-- compiles: body -->
```zig
const total = try db.count(User, c, .{ .where = .{ .age = .{ .gt = 18 } } });
const taken = try db.exists(User, c, .{ .where = .{ .email = email } });
```

`count` answers a `usize` and `exists` a `bool`. Both take a condition and
nothing else — there is nothing to sort and nothing to narrow in an answer
one row wide, so `.order` and `.limit` are compile errors rather than clauses
quietly dropped. A `count` with no condition counts the table.

`exists` is `SELECT EXISTS(…)` rather than a count compared against zero, so
the database stops at the first matching row instead of counting every one of
them to settle a question the first one settles.

The condition goes through the same walker `select` uses, so a column
misspelled in either is the same compile error.

## A page and its total

A trimmed list has to say what it trimmed. `db.page` answers both numbers out
of one statement:

<!-- compiles: body -->
```zig
const found = try db.page(Order, c, .{
    .where = .{ .status = "open" },
    .order = .{ .id = .asc },
    .limit = 20,
    .offset = 40,
});
// found.rows is []Order, found.total is every order that matched.
```

```sql
SELECT "id", "status", count(*) OVER () FROM "orders"
  WHERE "status" = $1 ORDER BY "id" ASC LIMIT 20 OFFSET $2
```

**The round trip is the smaller half of why.** A `db.count` beside a
`db.select` is two statements against a table somebody else can write between,
so the screen says *"20 of 47"* while holding 20 of 46 and nothing says so.
`count(*) OVER ()` rides on the page and cannot come apart from it
([ADR 0185](../../adr/0185-a-page-knows-what-it-left-out.md)). It costs one integer
read per statement rather than per row: the window function answers the same
number on every row, so only the first is read.

`.limit` and `.order` are both required. With no ceiling this is the whole
table and the total is `rows.len`; with no order, Postgres owes the `LIMIT`
nothing, so two requests for the same page can hold one row twice and miss
another. `.lock` is refused — `FOR UPDATE` and a window function cannot be in
one statement. `tx.page` is the same call inside a transaction.

`db.count` is still the call when you want a total and no rows.

## Why writing the limit out is worth it

A `.limit` written as a literal is baked into the SQL, and that buys two
things. Postgres gets a number to plan with, which `LIMIT $2` does not give
it. And nilo knows before the first row arrives how many can possibly come,
so the list they go into is built once at that size.

Measured over a 32-byte row: **one** allocation with the limit written out,
the same at ten rows and at a hundred thousand. Without it, 2, 3, 5 and 9 at
ten, a hundred, a thousand and a hundred thousand — the list doubling its way
there, and each doubling abandons the buffer before it, because a request
arena has no way to take one back.

The ceiling is not a promise about how many rows arrive. Asking for a
thousand and getting three reserves room for a thousand, and the difference is
held until the request ends. The number you wrote is believed.

## A query with no server

What a call actually asks the `Ctx` for is two calls — `arena()` and `str()` — so
what it takes is a **Scope**, and a `*Ctx` is one
([ADR 0041](../../adr/0041-a-module-sits-where-the-loop-puts-it.md)). Where there
is no request there is `nilo.Run`, which owns an arena and a lifetime of its
own:

<!-- compiles: body -->
```zig
var run = nilo.Run.init(gpa);
defer run.deinit();

const adults = try db.select(User, &run, .{ .where = .{ .age = .{ .gt = 18 } } });
```

Same query, same rows, no server in the process.

**A `Run` is an arena and a lifetime. What it is not is a connection.** The
pool is opened by `nilo_start`, and until something calls it every query answers
`error.Disconnected` — so a script, a migration, or a test needs one more line
than the snippet above
([ADR 0079](../../adr/0079-there-is-a-phase-before-the-server.md)):

<!-- compiles: body -->
```zig
var threaded: std.Io.Threaded = .init(gpa, .{});   // std's own, not the Engine
defer threaded.deinit();
try db.nilo_start(threaded.io(), .off);                  // the pool is open from here

var run = nilo.Run.init(gpa);
defer run.deinit();
```

Inside a program that also serves, `app.start(io)` is the same thing for every
service the App holds at once — the phase after the pool and before the server:

<!-- compiles: body -->
```zig
var threaded: std.Io.Threaded = .init(gpa, .{});
defer threaded.deinit();

try app.provide(&db);
try app.start(threaded.io());        // services checked, pools open, schema checked

var run = nilo.Run.init(gpa);
defer run.deinit();
_ = try db.exec(&run, schema_sql, .{});

try app.listen(.{ .port = 8080 });   // does not open them a second time
```

**A SQLite application needs this and most Postgres ones do not**: there is no
server to have created the tables somewhere else, so `zig build run` on a fresh
machine has to do it.


## Streaming a result set too big to hold

<!-- compiles -->
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

Two kinds of column cannot be streamed, and each is a compile error rather
than a footnote: a `sql.Json(T)`, and an **array**. The rule behind both is one
sentence — **a streamed row holds only what the read buffer already holds.**
A borrowed row allocates nothing, which is what makes a million of them run
flat; parsing a document costs one allocation per row, and so does building a
slice out of a run of length-prefixed elements. Read either with `select`, or
leave the column out of the Row being streamed — a Json column read as
`[]const u8` streams as bytes you can parse where you need them.
