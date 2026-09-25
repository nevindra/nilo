# Writing

Inserts, updates, deletes and upserts, one row or many, on the Row the
[tables page](./tables.md) declared. [Transactions](./transactions.md) is
what holds several of these together.

<!-- compiles: body -->
```zig
const made = try db.insert(User, c, .{ .email = "a@b.c", .name = "Ada", .age = 30 });
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

**A column nothing fills is not yours to leave out, and leaving it out does not compile.** The subset is for the columns something fills: the integer key a sequence fills, a column with a `.default` in the marker, an optional one that gets null, and one named in the marker's `.filled`, which is how you tell nilo the database fills it by means of its own (a `DEFAULT` written in a step, `gen_random_uuid()`, a trigger). Leave out anything else and the insert is refused, naming the columns, rather than failing with `NotNullViolated` the first time it runs. That is how a column added in one release and missed by an insert in the next is found by the compiler instead of by a user ([ADR 181](../../adr/181-the-marker-has-two-kinds-of-word.md)). A table this program only reads, `.managed = false`, is not checked: its defaults are the database's, and the marker does not know them.

**A `Str` column takes text in whatever shape you hold it.** The Row says
`email: Str`; the insert takes a literal, a `[]const u8`, a `[]u8` an
allocator handed back, or a `Str` off the request, and each is written the
same way. There is nothing to convert on the way in, and `made.email` is a
`Str` on the way out, the Scope's for as long as the request is
([ADR 116](../../adr/116-a-raw-parameter-is-converted-the-way-a-rows-is.md)).
An optional column takes `null` and an `?T` of the same shapes.

`update` and `delete` answer with the number of rows they touched, and both
**require** a condition. An update with no `.where` rewrites the table and a
delete with none empties it; each is reached by leaving something out rather
than by writing something down, so each is a compile error:

```
error: nilo: an update on User with no condition.
       That rewrites every row in the table. If it is meant, `db.raw` says
       so where somebody reading the code can see it.
```

A condition can also end up empty because of what the request sent. Say a
delete keeps a list of rows, `.where = .{ .id = .{ .not_in = keep } }`. On
the day `keep` arrives empty, that is `"id" <> ALL('{}')`, which is true for
every row. A search box left empty does the same through `.contains = ""`.
The compiler cannot see a value, so **an `update` or a `delete` whose
condition matches every row with the values it was given is refused before
it is sent**, as `error.QueryFailed` with a line naming the call. An empty
list next to a term that does narrow, such as
`.{ .tenant_id = t, .id = .{ .not_in = keep } }`, is an ordinary condition
and goes through.

**A count goes up where it is stored, not where it was read.**
`.set = .{ .views = .{ .plus = 1 } }` writes `SET "views" = "views" + $1`, and
`.minus` is the other direction. The database does the arithmetic on the value
the row holds when the statement runs. `.set = .{ .views = page.views + 1 }`
sends the number the handler read earlier, so two requests that read the same
number write the same answer, and one view is lost. Only a numeric column that
is not optional takes either operator.

<!-- compiles: body -->
```zig
// Take one, and only while there is one to take: the check and the change
// are the same statement, so two requests cannot both get the last.
const taken = try db.update(Item, c, .{
    .set = .{ .qty = .{ .minus = 1 } },
    .where = .{ .id = id, .qty = .{ .gt = 0 } },
});
if (taken == 0) return nilo.fail.conflict("out of stock", .{});
```

## Many rows at once

A loop of `db.insert` is a round trip per row, and inside a transaction it is
a round trip per row holding a pool connection. `insertMany` is one statement:

<!-- compiles -->
```zig
const Line = struct { sku: nilo.Str, qty: i32 };

fn receive(db: *sql.Db, c: *nilo.Ctx, body: []const Line) ![]Item {
    return db.insertMany(Item, c, body);
}
```

The rows come back in the order they were sent. `tx.insertMany` is the same
call inside a transaction.

The rows are a slice of a **named** struct rather than a tuple of literals,
because the statement is compiled from the element type. What it compiles to
is one array parameter per column:

```sql
INSERT INTO "items" ("sku", "qty")
SELECT * FROM unnest($1::text[], $2::int4[])
RETURNING "id", "sku", "qty"
```

Two placeholders for any number of rows, which is what keeps the statement a
constant — the `VALUES ($1,$2),($3,$4),…` most libraries generate has the
batch size *in* it, so the SQL would be rebuilt per call and Postgres would
plan it again for every distinct size
([ADR 047](../../adr/047-a-batch-is-one-array-per-column.md)).

It is one statement, so a batch that violates a constraint stores **none** of
its rows — usually what was wanted, and the opposite of a loop of inserts with
nothing around it. An empty batch runs the statement, stores nothing and
answers with nothing.

Two columns cannot be batched, and both say so at compile time: a list column,
because `unnest` would flatten it into one row per element, and an enum that
has not declared what its Postgres type is called.

`updateMany` is the same trick joined against the table rather than selected
into it:

```zig
const Change = struct { id: i64, qty: i32 };
const changed = try db.updateMany(Item, c, changes);
```

```sql
UPDATE "items" AS t SET "qty" = v."qty"
FROM unnest($1::int8[], $2::int4[]) AS v("id", "qty")
WHERE t."id" = v."id"
RETURNING t."id", t."sku", t."qty"
```

Each row carries the Row's **key** and is found by it — that is why there is
no `.where` to write, and why a batch that does not carry the key is a compile
error. A key the table does not have matches nothing, so an answer shorter
than the batch tells you which landed.

Two things it does not promise, and both are properties of a join rather than
choices: the **order** rows come back in is the planner's, and a batch naming
the same key twice changes that row once, from whichever of the two Postgres
reached. Where either matters, `db.update` in a loop is the honest shape.

## Giving back the rows instead of the count

A `PATCH` endpoint changes a row and answers with it. Written with `update`
that is two round trips, and the second one may read what somebody else
changed in between:

<!-- compiles -->
```zig
fn rename(db: *sql.Db, c: *nilo.Ctx, id: i64, body: Rename) !?User {
    return db.updateReturningOne(User, c, .{
        .set = .{ .name = body.name },
        .where = .{ .id = id },
    });
}
```

`updateReturning` is the same statement answering with the slice, for a `.where`
that means to match many rows. `deleteReturning` is the other half, for a delete
that has to report or log what it took, and `deleteReturningOne` is its
one-row form. The clause they add is the `SELECT` list this module already
writes, so none of them costs a statement the compiler did not settle.

**The `…One` calls change one row, or they do not compile**
([ADR 146](../../adr/146-a-statement-with-a-key-in-it-has-a-single-row-answer.md)).
The `.where` has to hold the key, or every column of a `.unique`, with `=`. An
`UPDATE` matching several rows changes all of them, so an answer of one row
would hide the rest:

```
error: nilo: `updateReturningOne` on User has a condition that can match more than one row.
       It answers with one row, and the statement changes every row the condition matches.
       Hold the key with `=`: .{ .id = … }
       Or call `updateReturning`, which answers with every row it changed.
```

Terms beside the key only narrow, so `.{ .id = id, .owner_id = me }` is fine,
and it is how a handler says "this row, if it is mine". `!?User` is already a
404 in the typed layer, so the handler above is the whole endpoint.

A one-time token is `deleteReturningOne`. The row is found and removed by one
statement, so a link clicked twice at once works once:

<!-- compiles: body -->
```zig
const reset = try db.deleteReturningOne(Reset, c, .{ .where = .{ .digest = sql.Bytes.of(&digest) } }) orelse
    return nilo.fail.unauthorized("that link is not one", .{});
```

`db.rawOne` is the same shape for a statement you wrote yourself. **It adds no
`LIMIT 1`**, unlike `db.one`: this module did not write the statement and has
nowhere honest to put one.

## Writing a row that may already be there

The shape everybody writes first is a caught error and a second statement:

```zig
const user = db.insert(User, c, .{ .email = email, .name = name }) catch |err| switch (err) {
    error.AlreadyExists => try db.updateReturning(User, c, .{ … }),   // two round trips
    else => return err,
};
```

That is two round trips, and there is a window between them: two requests can
both fail the insert, both run the update, and the second one wins whatever
order they arrive in. `ON CONFLICT` is one statement and has no window.

<!-- compiles: body -->
```zig
// Leave the row that is there alone. `null` means it was already there.
const made = try db.insertOrIgnore(User, c, .{ .email = email, .name = name }, .email);

// Or write these values over it. Either way a row comes back.
const user = try db.insertOrUpdate(User, c, .{
    .email = email,
    .name = name,
}, .email);
```

The last argument is the **conflict target**: the column the database has a
unique constraint or index on, written the way a key is. For a constraint
spanning two columns it is a tuple, `.{ .tenant_id, .email }`. It is not
required to be the Row's key — an email is the ordinary case and is usually
not — and nothing on this side can check that a constraint exists, because a
constraint is not a column and a Row cannot name one. Postgres refuses the
statement if there is none.

**When it *is* the key, write `.key`**
([ADR 151](../../adr/151-a-key-is-named-once.md)):

<!-- compiles: body -->
```zig
_ = try tx.insertOrIgnore(UserTag, c, .{ .user_id = id, .tag = tag_name }, .key);
```

A join table already names its composite key in `nilo_table`, and spelling the
tuple again at the call site is two copies that can disagree — a key that gains
a column and a call site that does not is a statement conflicting on the *old*
columns, which inserts a duplicate where it used to ignore one. A Row that also
has a column called `key` is a compile error naming both readings.

**They are two calls rather than one call with an option**, because the answer
is a different shape. `DO NOTHING` stores no row, and `RETURNING` on a row
that was not stored gives nothing back — so `insertOrIgnore` returns `?User`
where `insertOrUpdate` returns `User`. It is the same reason `one` is not
`select` with a flag.

`insertOrUpdate` sets every column you passed **except the conflict target and
the key**. The target is the value the two rows were matched on. The key is
left out because a caller passing `.id` is filling in the insert half — nobody
means "renumber the row that is already there", and Postgres would do it
quietly, along with every foreign key pointing at that row. If that leaves
nothing to set, the compiler says so and names the call you wanted:

```
error: nilo: `db.insertOrUpdate` on User has nothing to set.
       Every column it was given is either the conflict target or the key
       `id`, and the update half writes neither.
       `db.insertOrIgnore` is the statement with nothing to set, and says so.
```
