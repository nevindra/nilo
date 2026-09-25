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
and all a compile error when wrong. The constant is readable, too:
`sql.selectFor(User, @TypeOf(options)).sql` is the text above, and
`sql.on(sql.SQLite).selectFor(User, @TypeOf(options)).sql` is the same
statement spelled with `?1` — `sql.on(D)` binds `selectFor` and the fourteen
beside it to a Dialect of your choosing.

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
`.not_like` and `.not_ilike` are the other two. `.ieq` is `=` that ignores
case, `lower("email") = lower($1)`, which is the lookup a `.unique` with
`.ignoring_case` is an index for; `.not_ieq` negates it. A column of type
`sql.Date` compares with `.today` and a `sql.Timestamp` with `.now`, the
database's clock with nothing bound: `.due_date = .{ .lt = .today }`. `.distinct_from` and
`.not_distinct_from` are the null-safe pair — see below. On SQLite, `.like`
and `.not_like` are Refusals naming `.ilike` and `.not_ilike`: that
database's `LIKE` folds ASCII case and cannot be told not to by a
statement, so the case-sensitive spelling would have matched more than it
said, on one database only — the same reason `.contains` is refused there
([ADR 055](../../adr/055-the-second-dialect-is-the-test-of-the-seam.md)).

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
([ADR 040](../../adr/040-a-condition-holds-a-value-not-a-maybe.md)).

## A filter nobody set

A search box that is empty is not a search for nothing. `.status = null` asks
for the rows whose status is null; a filter nobody set wants **no condition on
status at all**, which is the opposite — one matches a handful of rows and the
other matches every one.

`sql.given` is that, and it is a word rather than an optional so the two stay
tellable apart
([ADR 149](../../adr/149-a-filter-that-is-absent-is-not-a-filter-that-is-null.md)):

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
("email" ILIKE … OR $1 IS NULL) AND ("age" >= $2 OR $2 IS NULL)
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

A multi-select takes one too. `.stage = .{ .in = sql.given(q.stages) }` is no
condition when `?stage=` was not sent and the listed stages when it was; an
empty list is still an empty `.in`, which matches nothing, because a filter bar
that sends an empty list is asking something else.

The join came out of `PartnerCapability`'s `.references`. It is read off
either Row, so the same question from the other side — the capability rows
whose partner matches, where the key is `partner_id` on the Row the statement
is over — is the same line with the two swapped
([ADR 175](../../adr/175-an-exists-reads-the-reference-from-either-side.md)):

<!-- compiles: body -->
```zig
const of_partner = try db.select(PartnerCapability, c, .{
    .where = .{ .exists = .{
        .{ .in = Partner, .where = .{ .name = .{ .icontains = name } } },
    } },
});
```

A Row that points at the same parent from two columns says which with
`.via = .<column>` — a column of *this* Row, where `.on` is a column of the
one inside.

It is refused inside `.any` (OR reverses what dropping a term means), on `.in`
and `not_distinct_from`, on a value that is not optional, and **in the condition
of an `UPDATE` or a `DELETE`** — there a term that may not be there is the whole
table.

**A search box over several columns is not the `.any` case.** There the same
absent value sits on every column, and the whole bracket should drop as one —
which is `.across`, one condition tested against each column it names, with
**one parameter** taken once and named on every column
([ADR 172](../../adr/172-one-condition-over-several-columns-is-one-parameter.md)):

<!-- compiles: body -->
```zig
// search: ?[]const u8 — the box, over the email and the name.
const matched = try db.select(User, c, .{ .where = .{
    .age = .{ .gte = sql.given(least_age) },
    .across = .{ .columns = .{ .email, .name }, .icontains = sql.given(search) },
} });
```

```sql
("age" >= $1 OR $1 IS NULL)
AND (("email" ILIKE … $2 … OR "name" ILIKE … $2 …) OR $2 IS NULL)
```

The columns have to read as one Zig type — a nullable column beside one that
is not is fine, a number beside text is two conditions in `.any` — and a
`sql.given` beside a fixed operator in one entry is refused the way it is in
`.exists`: write a second entry.

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
([ADR 150](../../adr/150-a-page-knows-what-it-left-out.md)). It costs one integer
read per statement rather than per row: the window function answers the same
number on every row, so only the first is read.

`.limit` and `.order` are both required. With no ceiling this is the whole
table and the total is `rows.len`; with no order, Postgres owes the `LIMIT`
nothing, so two requests for the same page can hold one row twice and miss
another. `.lock` is refused — `FOR UPDATE` and a window function cannot be in
one statement. `tx.page` is the same call inside a transaction.

`db.count` is still the call when you want a total and no rows.

## An order the request chose

`.order = .{ .id = .asc }` is settled while compiling. A list sorted from its
column headings is not, and the way to let a request choose without letting a
request write SQL is to declare the set it chooses from
([ADR 165](../../adr/165-an-order-chosen-at-run-time-from-a-closed-set.md)):

<!-- compiles -->
```zig
const Sort = sql.Ordering(Order, .{
    .id = .id,
    .status = .{ .column = .status, .nulls = .last },
});

fn list(db: *sql.Db, c: *nilo.Ctx, q: nilo.Query(struct {
    order: Sort = Sort.by(&.{.{ .key = .id }}),
})) !sql.Page(Order) {
    return db.page(Order, c, .{ .order = q.value.order, .limit = 20 });
}
```

`?order=status:desc,id` reads straight into the field — `key[:asc|:desc]`,
comma-separated — and a key that is not declared is a 400 in the type's own
words: *?order has to be an ordering by id or status, each with an optional
:asc or :desc, comma-separated, not "height"*. Each key is a column of the
Row, checked while compiling, and the clause is written from fragments the
type built then; nothing the request sent reaches the statement. What it costs
is the prepared name: a statement whose order is chosen per request runs
unnamed, about 12 µs a call, and one arena allocation for its text.

A key that is a string — `.value = "value_currency, value_minor"` — is SQL of
your own, and only `db.rawOrdered` and `db.rawPageOrdered` take it, with
`{order}` in your statement where the whole clause goes ([Raw SQL](./raw.md)).

A literal `.order` on a narrower Row may name any column of its table, not
only the ones the Row carries, so a tiebreak such as `created_at` does not
have to go on the wire: `.order = .{ .position = .asc, .created_at = .asc }`.

## The keyset form of a deep page

`db.page` above is `OFFSET`, and `OFFSET` costs the database every row it is
not going to answer with: page 4,000 of `/orders` scans and discards 12,000
rows to reach the twenty this call wants, and it gets slower the deeper a
caller goes. No index fixes that — an index tells the database *where* a row
is, not how many came before it.

**Keyset pagination** asks a different question: not *the twenty after the
twelve-thousandth*, but *the twenty after this one*. The caller carries the
last row it saw instead of a page number, and the condition is the tuple
comparison a book uses to find its place — `(created_at, id) < (…)` —
written the way this module writes every OR, as `.any`:

<!-- compiles -->
```zig
fn olderThan(db: *sql.Db, c: *nilo.Ctx, after: sql.Timestamp, after_id: i64) ![]User {
    return db.select(User, c, .{
        .where = .{ .any = .{
            .{ .created_at = .{ .lt = after } },
            .{ .created_at = after, .id = .{ .lt = after_id } },
        } },
        .order = .{ .created_at = .desc_nulls_last, .id = .desc },
        .limit = 20,
    });
}
```

`after` and `after_id` are the `created_at` and `id` off the last row the
previous call answered with — a cursor the caller carries rather than a page
number the database counts up to. The first call has none to carry: read the
first page with `.order` and `.limit` alone, and start carrying a cursor once
there is a last row to take it from.

`.order` is doing two jobs. `.desc_nulls_last` is one of the four directions
beside plain `.asc` and `.desc` that also say where a NULL goes, so a row
with no `created_at` sorts to the same place on every call rather than
wherever the database happens to put one; `id` beside it breaks a tie
between two rows sharing one `created_at`, which is why the condition needs
two terms and not one — drop either and two calls can disagree about where
the boundary was, the same failure `.limit` with no `.order` already has
against `OFFSET`.

**The trade is the running total.** `db.page`'s `count(*) OVER ()` rides on
the page it counts; a keyset condition has nothing to ride it on, because
there is no "page 4,000" for a count to be relative to. Ask for one row more
than the page needs and drop it to know whether there is a next page, or keep
`db.count` beside the call for a total that does not have to be exact this
second.

`DISTINCT` is not part of this and is not coming: over one table with a key
every row appears once anyway, which is the same argument
[ADR 052](../../adr/052-a-set-operation-over-one-table-is-a-condition.md)
makes for `UNION`.

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
([ADR 038](../../adr/038-a-module-sits-where-the-loop-puts-it.md)). Where there
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
([ADR 180](../../adr/180-work-that-needs-the-services-runs-on-their-loop.md)):

<!-- compiles: body -->
```zig
var threaded: std.Io.Threaded = .init(gpa, .{});   // std's own, not the Engine
defer threaded.deinit();
try db.nilo_start(threaded.io(), .none);                  // the pool is open from here

var run = nilo.Run.init(gpa);
defer run.deinit();
```

Inside a program that also serves, the same work goes in `app.before`, which
`listen()` runs on the server's own loop after the pools are open and before
the first request
([ADR 180](../../adr/180-work-that-needs-the-services-runs-on-their-loop.md)):

<!-- compiles -->
```zig
fn makeTables(run: *nilo.Run, db: *sql.Db) !void {
    _ = try db.exec(run, "CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT)", .{});
}
```

<!-- compiles: body -->
```zig
try app.provide(&db);
try app.before(makeTables, .{&db});  // runs once, inside listen()
try app.listen(.{ .port = 8080 });
```

The function takes the boot's `nilo.Run` first — made by `listen()` on the
loop the pool was dialled through, so a key can be minted from it — and then
whatever it was registered with. If it fails, the server does not start.

**A SQLite application needs this and most Postgres ones do not**: there is no
server to have created the tables somewhere else, so `zig build run` on a fresh
machine has to do it.

`app.start(io)` — services checked, pools open on an `Io` of yours — is for a
program that never listens: a test through `testing.Client`, a script. Followed
by `listen()` it is refused, because a pool dialled through one loop cannot be
driven from another (ADR 180).


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
