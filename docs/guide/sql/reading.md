# Reading

**Every way of reading rows: the statement is built while compiling, the conditions are a struct, and the result is the Row you declared.**

**Reference:** [Queries](../../reference/sql.md#queries), [Conditions](../../reference/sql.md#conditions), [Streaming](../../reference/sql.md#streaming) · **Design:** [The query builder](../../design/sql-query.md)

The Row comes from the [tables page](./tables.md). [Writing](./writing.md) and [transactions](./transactions.md) are the other two kinds of call, and [past one table](./raw.md) is where you write the statement yourself.

## Selecting rows

**The statement is fixed while compiling; only the values arrive at run time.**

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

[`db.select`](../../reference/sql.md#queries) compiles to this, before the program runs:

```sql
SELECT "id", "email", "age", "created_at" FROM "users"
WHERE "age" > $1 ORDER BY "created_at" DESC, "id" DESC LIMIT 10
```

The `"id"` at the end of the order is the table's key, added to any order a `LIMIT` or an `OFFSET` cuts that does not name it already, so rows the order ties still come back in one order and a page never repeats or skips one. An index that serves a paged order should end in the key as well, `(created_at, id)` rather than `(created_at)`, or Postgres sorts every row that ties with the page's. Only the `18` reaches run time. The table, the columns, the operators and the number of parameters are all decided while compiling, and each is a compile error when wrong. You can read the constant too: `sql.selectFor(User, @TypeOf(options)).sql` is the text above, and `sql.on(sql.SQLite).selectFor(User, @TypeOf(options)).sql` is the same statement written with `?1`. `sql.on(D)` binds `selectFor` and the fourteen functions beside it to a Dialect you choose.

```
$ zig build
error: nilo: User has no column `agee`, asked for in a condition.
       Did you mean `age`?
```

Note the `limit`. A literal is written into the SQL, which also gives Postgres a number to plan with. A limit held in a variable becomes a parameter instead. This is the same rule applied strictly, not an inconsistency: `10` written in the source is part of the statement's shape, and the shape is decided early.

## Conditions

**Conditions on different fields are joined with AND, because that is what a struct is.** Several operators on one field are ANDed too, so a range needs no `between`.

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

OR is written `.any` rather than `.or` because `or` is a Zig keyword and would have to be written `.@"or"`. The cost is that `any` becomes a reserved column name: a Row with a column called `any` is rejected with a message naming it, rather than silently misread.

The full list of operators is in [the reference](../../reference/sql.md#conditions). The ones worth knowing:

- `.in` takes a list and compiles to `= ANY($1)`: **one** parameter, so the statement stays a constant however long the list is. Its negation is `.not_in`, which is `<> ALL($1)` and also costs one parameter. `.not_like` and `.not_ilike` are the other two negations.
- `.ieq` is `=` ignoring case, `lower("email") = lower($1)`, the lookup a `.unique` with `.ignoring_case` is an index for. `.not_ieq` negates it.
- A `sql.Date` column compares with `.today` and a `sql.Timestamp` column with `.now`, using the database's clock with nothing bound: `.due_date = .{ .lt = .today }`. A column read as text takes the word its column type names: `.today` on `sql.AsText("date")` and `.now` on `sql.AsText("timestamptz")`. A `timestamp` column, which has no zone, takes neither: the session's time zone would decide what `now()` means in it.
- Either one can be moved by a number written out, for a window that ends now: `.closed_at = .{ .gte = .{ .today = -90 } }` is the last ninety days by the database's calendar, and `.seen_at = .{ .gt = .{ .now = .{ .hours = -24 } } }` is the last day by its clock.
- `.distinct_from` and `.not_distinct_from` are the null-safe pair; see below.

On SQLite, `.like` and `.not_like` are Refusals that point you to `.ilike` and `.not_ilike`. SQLite's `LIKE` ignores ASCII case and a statement cannot turn that off, so the case-sensitive version would match more than it says, on one database only. `.contains` is refused there for the same reason ([ADR 055](../../adr/055-the-second-dialect-is-the-test-of-the-seam.md)).

### Comparing with null

**A null in a condition has to be written in the source; a value that may be null is a compile error.** `.deleted_at = null` above is `IS NULL` because the compiler can see the null. This is not allowed:

```zig
const maybe: ?[]const u8 = c.query.handle;      // may or may not be there
.where = .{ .handle = maybe }                   // ✗ compile error
```

The two readings are two different statements, `"handle" = $1` and `"handle" IS NULL`, and which one is right depends on a value that arrives after the statement is already a constant. Sending `= $1` with NULL in it is legal SQL and *never true*, so the query would run, match nothing and report nothing.

Usually what you meant is SQL's null-safe comparison, and that **is** one statement:

```zig
.where = .{ .handle = .{ .not_distinct_from = maybe } }   // ✓
```

`IS NOT DISTINCT FROM` is `=` with null treated as an ordinary value: two nulls match, and null against anything else does not. It is the only operator that takes an optional, and for the same reason: the statement is the same six words whether the value is null or not, so nothing about its shape waits for run time. `.distinct_from` is the negation, and it finds the null rows that `<>` silently drops.

Where the two cases really are two different queries, write the branch:

```zig
const found = if (maybe) |handle|
    try db.select(User, c, .{ .where = .{ .handle = handle } })
else
    try db.select(User, c, .{ .where = .{ .handle = null } });
```

Only the value you compare with is checked. A `?[]const u8` column compared against a plain `[]const u8` is an ordinary condition, and so is every `.set` and every `insert`: `SET handle = $1` with NULL in it means exactly one thing ([ADR 040](../../adr/040-a-condition-holds-a-value-not-a-maybe.md)).

## Optional filters

**`sql.given(value)` is a filter that disappears when the value is null.** An empty search box is not a search for nothing. `.status = null` asks for the rows whose status is null; a filter nobody set wants **no condition on status at all**. That is the opposite: one matches a handful of rows and the other matches every row.

`sql.given` is a word rather than an optional so the two cases stay distinguishable ([ADR 149](../../adr/149-a-filter-that-is-absent-is-not-a-filter-that-is-null.md)):

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

**It is one statement whatever the filters are set to**, so one parameter list. The alternative, a statement per combination of filters, is four statements for two filters and sixteen for four, each with its own parameters. What is sent leaves the guard out: a filter that is set is written as its term alone, and one that is not as a test that is always true, so the database plans for the filters that are there and an index is used on both Postgres and SQLite. Up to three filters in one statement, each combination is kept prepared; past that the text is prepared on every call, which costs microseconds.

Inside an `.exists` it drops the **whole subquery**, not just the term:

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

If only the term were dropped, the subquery would ask whether the partner has *any* capability row, which silently excludes every partner that has none. For the same reason a `sql.given` cannot sit beside a fixed condition in one `.exists`; write a second entry.

A multi-select can use it too. `.stage = .{ .in = sql.given(q.stages) }` adds no condition when `?stage=` was not sent, and filters by the listed stages when it was. An empty list is still an empty `.in`, which matches nothing, because a filter bar that sends an empty list is asking something different.

The join comes from `PartnerCapability`'s `.references`. It is read from either Row, so asking the same question from the other side (the capability rows whose partner matches, where the key is `partner_id` on the Row the statement reads) is the same line with the two swapped ([ADR 175](../../adr/175-an-exists-reads-the-reference-from-either-side.md)):

<!-- compiles: body -->
```zig
const of_partner = try db.select(PartnerCapability, c, .{
    .where = .{ .exists = .{
        .{ .in = Partner, .where = .{ .name = .{ .icontains = name } } },
    } },
});
```

A Row that points at the same parent from two columns says which one with `.via = .<column>`, a column of *this* Row, whereas `.on` is a column of the Row inside.

`sql.given` is rejected inside `.any` (with OR, dropping a term means the opposite), on `.in` and `not_distinct_from`, on a value that is not optional, and **in the condition of an `UPDATE` or a `DELETE`**, where a term that might be missing means the whole table.

### Searching several columns

**A search box over several columns uses `.across`, not `.any`.** The same possibly-absent value applies to every column, and the whole bracket should drop at once. `.across` tests one condition against each column it names, with **one parameter** bound once and used for every column ([ADR 172](../../adr/172-one-condition-over-several-columns-is-one-parameter.md)):

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

The columns have to read as one Zig type: a nullable column beside a non-nullable one is fine, but a number beside text needs two conditions in `.any`. A `sql.given` beside a fixed operator in one entry is rejected, as it is in `.exists`; write a second entry.

**A negated operator is rejected in `.across`** (`.not_icontains`, `.ne`, `.not_in` and the rest): ORed, "does not contain it" would keep a row whose other column still does. "None of these columns contains it" is one condition per column, each with its own `sql.given` if the box may be empty: `.code = .{ .not_icontains = q }, .name = .{ .not_icontains = q }`.

## Fetching all rows, one row, or a row by key

<!-- compiles: body -->
```zig
const all   = try db.select(User, c, .{ .where = .{ .age = .{ .gt = 18 } } });
const maybe = try db.one(User, c, .{ .where = .{ .id = id } });
```

**[`db.one`](../../reference/sql.md#queries) returns `?User`, so a handler that returns `!?User` answers 404 when there is no row**, and the OpenAPI document says so, because the `?` already meant that. The two modules never import each other; they agree because they read the same struct.

`one` adds its own `LIMIT 1`, so a condition on a column that is not unique reads one row rather than every match. Writing a `.limit` beside it is a compile error: the call sets the limit.

A lookup by key is the same thing with the condition already filled in:

<!-- compiles -->
```zig
fn show(db: *sql.Db, c: *nilo.Ctx, id: i64) !?User {
    return db.find(User, c, id);
}
```

That is a whole endpoint. The column comes from the Row's `.key`, so you do not repeat it at every call site, and `?User` is the 404. Passing a struct where the key goes is a compile error that points you to `one`: `find` takes the key value itself.

Every call takes the `Ctx`, not to read the request but for the request arena, which is where the rows go. They live exactly as long as the response that carries them, and nothing is freed by hand.

## Counting

<!-- compiles: body -->
```zig
const total = try db.count(User, c, .{ .where = .{ .age = .{ .gt = 18 } } });
const taken = try db.exists(User, c, .{ .where = .{ .email = email } });
```

**`count` returns a `usize` and `exists` a `bool`.** Both take a condition and nothing else. There is nothing to sort or trim in a one-row answer, so `.order` and `.limit` are compile errors rather than clauses silently dropped. A `count` with no condition counts the whole table.

`exists` is `SELECT EXISTS(…)` rather than a count compared against zero, so the database stops at the first matching row instead of counting all of them.

The condition goes through the same code `select` uses, so a misspelled column is the same compile error in each.

## Paging with a total

**[`db.page`](../../reference/sql.md#queries) returns one page of rows and the total number of matches, from one statement.** A trimmed list has to say how much it left out:

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

**Saving a round trip is the smaller reason.** A `db.count` beside a `db.select` is two statements against a table someone else can write to in between, so the screen could say *"20 of 47"* while there are really 46, and nothing would tell you. `count(*) OVER ()` is part of the page query and cannot disagree with it ([ADR 150](../../adr/150-a-page-knows-what-it-left-out.md)). It costs one integer read per statement, not per row: the window function returns the same number on every row, so only the first is read.

`.limit` and `.order` are both required. With no limit this is the whole table and the total is just `rows.len`. With no order, Postgres does not guarantee which rows `LIMIT` returns, so two requests for the same page can show one row twice and miss another. `.lock` is rejected, because `FOR UPDATE` and a window function cannot be in one statement. `tx.page` is the same call inside a transaction.

Use `db.count` when you want a total and no rows.

## Sorting chosen by the request

**[`sql.Ordering`](../../reference/sql.md#sqlordering-an-order-chosen-at-run-time) lets a request choose the sort order from a set you declare, without letting it write SQL.** `.order = .{ .id = .asc }` is fixed while compiling. A list sorted by clicking column headings is not, so you declare the set of allowed orders ([ADR 165](../../adr/165-an-order-chosen-at-run-time-from-a-closed-set.md)):

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

`?order=status:desc,id` is read straight into the field, as `key[:asc|:desc]` separated by commas. A key that is not declared is a 400 with a message from the type itself: *?order has to be an ordering by id or status, each with an optional :asc or :desc, comma-separated, not "height"*. Each key is a column of the Row, checked while compiling, and the clause is built from fragments the type prepared at that time; nothing the request sent reaches the statement. The cost is the prepared statement name: a statement whose order is chosen per request runs unnamed, at about 12 µs a call, plus one arena allocation for its text.

A key given as a string, `.value = "value_currency, value_minor"`, is your own SQL. Only `db.rawOrdered` and `db.rawPageOrdered` accept it, with `{order}` in your statement where the whole clause goes ([Raw SQL](./raw.md)).

A literal `.order` on a narrower Row may name any column of its table, not only the ones the Row has, so a tiebreaker such as `created_at` does not have to be sent to the client: `.order = .{ .position = .asc, .created_at = .asc }`.

A `.where` may name such a column too, so a lookup by email does not need `email` on a Row that only returns `id` and `name`: `.where = .{ .email = e }`. The value is bound as the table's column type, since the Row has no field to give its type.

## Keyset pagination for deep pages

**For deep pages, carry the last row seen instead of an offset.** `db.page` above uses `OFFSET`, and `OFFSET` makes the database read every row it skips: page 4,000 of `/orders` scans and throws away 12,000 rows to reach the twenty this call wants, and it gets slower the deeper a caller goes. No index fixes that, because an index tells the database *where* a row is, not how many rows come before it.

**Keyset pagination** asks a different question: not *the twenty after the twelve-thousandth*, but *the twenty after this one*. The caller keeps the last row it saw instead of a page number, and hands it back as `.after`:

<!-- compiles -->
```zig
const Post = struct {
    pub const nilo_table = .{ .name = "posts", .key = .id };
    id: i64,
    title: []const u8,
    created_at: sql.Timestamp,
};

fn older(db: *sql.Db, c: *nilo.Ctx, last: ?Post) !sql.Feed(Post) {
    const order = .{ .created_at = .desc, .id = .desc };
    const seen = last orelse return db.feed(Post, c, .{ .order = order, .limit = 20 });
    return db.feed(Post, c, .{
        .order = order,
        .after = .{ .created_at = seen.created_at, .id = seen.id },
        .limit = 20,
    });
}

comptime {
    _ = &older;
}
```

`.after` becomes one row comparison, `("created_at", "id") < ($1, $2)`, which the database answers by seeking straight to the cursor on an index over `(created_at, id)`: 0.013 ms at a million rows, the same as the first screen. The `.any` of `<` and `= … AND <` this page used to show filtered from the first row instead and cost 17.8 ms, what the `OFFSET` did. The first screen has no cursor, so it is the call without `.after`.

`db.feed` answers `found.rows` and `found.more`, whether any row came after them, which is what a "load more" button needs. It reads one row past the limit to know, and counts nothing, so it costs what `db.select` does. `db.page`'s total is a pass over every matching row, 124 ms at a million, which a list with no "20 of 47" on it should not pay.

**Each rule the compiler holds `.after` to is a cursor that would skip or repeat rows:**

- `.after` names the columns `.order` sorts by, in the same order;
- every term runs the same way: all `.desc` here, since a row comparison runs one way;
- no column may be null, since a row comparison with a NULL in it is true of nothing, and no direction says where NULLs go;
- the order ends in the table's key, here `id`: two posts written in the same microsecond stand at one cursor, and the key is what puts one after the other.

`DISTINCT` is not supported and is not planned: over one table with a key, every row appears once anyway. [ADR 052](../../adr/052-a-set-operation-over-one-table-is-a-condition.md) makes the same argument for `UNION`.

## Writing the limit as a literal

**A literal `.limit` lets both Postgres and nilo plan for the size of the result.** It is written into the SQL, so Postgres gets a number to plan with, which `LIMIT $2` does not give it. And nilo knows before the first row arrives how many rows can come, so the list they go into is allocated once at that size.

Measured with a 32-byte row: **one** allocation with the limit written out, the same at ten rows and at a hundred thousand. Without it, 2, 3, 5 and 9 allocations at ten, a hundred, a thousand and a hundred thousand rows, as the list doubles its way there. Each doubling abandons the previous buffer, because a request arena cannot take memory back.

The limit is not a promise about how many rows arrive. Asking for a thousand and getting three reserves room for a thousand, and the unused space is held until the request ends. nilo trusts the number you wrote.

## Queries outside a request

**Outside a request, pass a [`nilo.Run`](../../reference/core.md#run) where the `Ctx` goes.** A query only needs two things from the `Ctx`, `arena()` and `str()`, so what it takes is a **Scope**, and a `*Ctx` is one ([ADR 038](../../adr/038-a-module-sits-where-the-loop-puts-it.md)). With no request, `nilo.Run` is the Scope: it owns an arena and a lifetime of its own.

<!-- compiles: body -->
```zig
var run = nilo.Run.init(gpa);
defer run.deinit();

const adults = try db.select(User, &run, .{ .where = .{ .age = .{ .gt = 18 } } });
```

Same query, same rows, no server in the process.

**A `Run` is an arena and a lifetime, not a connection.** The pool is opened by `nilo_start`, and until something calls it every query returns `error.Disconnected`. So a script, a migration or a test needs one more step than the snippet above ([ADR 180](../../adr/180-work-that-needs-the-services-runs-on-their-loop.md)):

<!-- compiles: body -->
```zig
var threaded: std.Io.Threaded = .init(gpa, .{});   // std's own, not the Engine
defer threaded.deinit();
try db.nilo_start(threaded.io(), .none);                  // the pool is open from here

var run = nilo.Run.init(gpa);
defer run.deinit();
```

In a program that also serves requests, the same work goes in [`app.before`](../../reference/app.md#app). `listen()` runs it on the server's own loop, after the pools are open and before the first request ([ADR 180](../../adr/180-work-that-needs-the-services-runs-on-their-loop.md)):

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

The function receives the boot's `nilo.Run` first, then whatever it was registered with. `listen()` creates that `Run` on the loop the pool was dialled through, so you can use it to mint a key. If the function fails, the server does not start.

**A SQLite application needs this, and most Postgres ones do not**: there is no separate server that already created the tables, so `zig build run` on a fresh machine has to create them.

`app.start(io)` checks the services and opens the pools on an `Io` you provide. It is for a program that never listens: a test through `testing.Client`, or a script. Calling `listen()` after it is rejected, because a pool dialled through one loop cannot be driven from another (ADR 180).


## Streaming a large result set

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

**[`db.stream`](../../reference/sql.md#streaming) reads a million rows in constant memory.** Postgres sends all the rows without being asked, but they are read off the socket as they arrive, so memory stays bounded by the read buffer and TCP holds the rest. No cursor is needed.

The rows come back as `sql.Borrowed(User)`, which is `User` with every `Str` replaced by `[]const u8`. That is deliberate: the text points into the buffer the rows arrive in, and it becomes invalid at the next `next()`. A `Str` means *text that lives as long as the request*, with no exceptions, so text that does not live that long is not called one. Copy it if you need to keep it.

`defer rows.close()` is required. A result set abandoned half-read holds a connection, and unlike a transaction, which is rolled back when the request ends, nothing else will ever close it. In Debug, forgetting it is caught by the same counter that watches transactions. Breaking out of the loop early is fine: `close` reads up to a megabyte of what Postgres already sent, and past that swaps the connection for a fresh one, so the first matching row out of millions costs a connect at most.

Two kinds of column cannot be streamed, and each is a compile error: a `sql.Json(T)`, and an **array**. The rule behind both: **a streamed row holds only what is already in the read buffer.** A borrowed row allocates nothing, which is what keeps a million of them in constant memory. Parsing a JSON document costs one allocation per row, and so does building a slice from a run of length-prefixed elements. Read such columns with `select`, or leave the column out of the Row you stream: a Json column read as `[]const u8` streams as bytes you can parse where you need them.
