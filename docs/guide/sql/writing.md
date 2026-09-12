# Writing

Inserts, updates, deletes and upserts, one row or many, on the Row the
[tables page](./tables.md) declared. [Transactions](./transactions.md) is
what holds several of these together.

<!-- compiles: body -->
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
([ADR 0053](../../adr/0053-a-batch-is-one-array-per-column.md)).

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
that has to report or log what it took. The clause they add is the `SELECT` list
this module already writes, so none of them costs a statement the compiler did
not settle.

**`updateReturningOne` is the unwrap, not a narrower statement**
([ADR 0179](../../adr/0179-a-statement-with-a-key-in-it-has-a-single-row-answer.md)).
The `.where` is yours: an `UPDATE` matching several rows updates all of them, and
this hands back the first. What it saves is `if (changed.len == 0) null else
changed[0]` at every call site — and `!?User` is already a 404 in the typed
layer, so the handler above is the whole endpoint.

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
const made = try db.insertOrIgnore(User, c, .{ .email = email }, .email);

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
([ADR 0186](../../adr/0186-a-key-is-named-once.md)):

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
