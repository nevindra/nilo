# A page knows what it left out

A trimmed list has to say what it trimmed. *"20 of 47"* is the ordinary shape of
every list screen, and it needs two numbers out of one condition.

The documented answer was the pairing in §"Counting":

```zig
const where = .{ .status = "open" };
const total = try db.count(Order, c, .{ .where = where });
const page  = try db.select(Order, c, .{ .where = where, .order = .{ .id = .asc }, .limit = 20 });
```

## The round trip is the smaller half of the problem

That is two statements against a table somebody else can write between. Between
the count and the select, one order is closed and another opened: the screen
says *"20 of 47"* while holding 20 of 46, and nothing anywhere says so.

`count(*) OVER ()` rides on the page and cannot come apart from it, because
there is only one statement to be inconsistent with.

## `db.page`

```zig
const found = try db.page(Order, c, .{
    .where = .{ .status = "open" },
    .order = .{ .id = .asc },
    .limit = 20,
    .offset = page * 20,
});
// found.rows is []Order, found.total is every order that matched.
```

```sql
SELECT "id", "status", count(*) OVER () FROM "orders"
  WHERE "status" = $1 ORDER BY "id" ASC LIMIT 20 OFFSET $2
```

A type of its own rather than an out-parameter, for the reason `db.one` is not
`db.select`: the shape of the answer changed, and a caller who has to remember
to read a second thing is a caller who will forget.

**One extra integer read per statement, not per row.** The window function
answers the same number on every row of the result, so only the first is read; a
condition matching nothing answers with no rows and a total of zero, which is
the same branch the empty result already takes.

The same text in both Dialects. Window functions are SQL:2003 and SQLite has had
them since 3.25, so this is not a Postgres-only call and `dialect.zig` gains
nothing.

## Three Refusals

- **No `.limit`.** With no ceiling this is the whole table, and the window
  function it cost answers what `rows.len` already says. `db.select` is the call
  for every row that matched.
- **No `.order`.** Postgres owes a `LIMIT` nothing without one, so two requests
  for the same page can hold one row twice and miss another. It compiles, it
  passes, and the list is wrong — which is the shape of every item the port
  filed.
- **A `.lock`.** `FOR UPDATE` and a window function cannot be in one statement;
  Postgres refuses the pair at run time, on whichever request got there first. A
  page is a read.

The second is stricter than `db.select`, which takes a `.limit` with no `.order`
and always has. That is deliberate rather than an oversight: a `select` with a
ceiling is often *"give me any twenty of these"*, and a **page** is by name the
thing whose second page has to line up with its first.

## Against ADR 0018's four axes

- **Allocations per request: zero more than `db.select`.** The same arena list,
  reserved to the same `.limit`; the total is an `i64` on the caller's stack.
- **Memory per idle connection: zero.**
- **Throughput: one statement where the documented shape was two**, so one round
  trip rather than two and one prepared statement rather than two. Against
  `db.select` alone it is one `readColumn` per statement and the window
  function's own cost, which Postgres computes during the same scan.
- **Binary size: one more call**, generic over the Row like every other. `fill`
  is unchanged and `filling` is what it always was with one parameter added, so
  no call site is duplicated.

## Consequences

- With [ADR 0183](0183-a-filter-that-is-absent-is-not-a-filter-that-is-null.md)
  the ordinary list endpoint is one typed call. The report filed the two
  together and said plainly that either alone leaves the query raw.
- `tx.page` exists for the same reason `tx.select` does. A repeatable-read
  transaction is the *other* way to make a count and a page agree, and it costs
  a transaction where this costs a clause.
- `db.count` is unchanged and still right for the caller who wants a total and
  no rows.
- `wideEnough` takes the extra column into account, so a `db.page` against a
  result set that is one column short is the same named refusal a `db.raw` gets
  rather than a read past the end (ADR 0134).
