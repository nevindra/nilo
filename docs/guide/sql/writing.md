# Writing

**Inserts, updates, deletes and upserts, one row or many, on the Row the [tables page](./tables.md) declared.**

**Reference:** [Queries](../../reference/sql.md#queries), [A batch](../../reference/sql.md#a-batch), [Upserts](../../reference/sql.md#upserts), [Options](../../reference/sql.md#options) · **Design:** [The query builder](../../design/sql-query.md)

[Transactions](./transactions.md) covers grouping several of these together.

## Inserting, updating and deleting

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

**[`db.insert`](../../reference/sql.md#queries) takes a subset of the columns and returns the whole stored row.** The columns the database fills in, such as a generated key or a `DEFAULT now()`, are the ones you have nothing to say about. The whole row comes back through `RETURNING`, so there is no second query to fetch what the database just wrote.

### Columns an insert may leave out

**You may only leave out a column that something fills in; leaving out any other column does not compile.** The columns that count as filled in are: the integer key a sequence fills, a column with a `.default` in the marker, an optional column (which gets null), and a column named in the marker's `.filled`. `.filled` tells nilo the database fills the column itself (a `DEFAULT` written in a migration step, `gen_random_uuid()`, a trigger). Leave out anything else and the insert is rejected with the column names, instead of failing with `NotNullViolated` the first time it runs. That way a column added in one release and missed by an insert in the next is caught by the compiler, not by a user ([ADR 181](../../adr/181-the-marker-has-two-kinds-of-word.md)). A table this program only reads, `.managed = false`, is not checked: its defaults belong to the database, and the marker does not know them.

**A `Str` column accepts text in whatever form you have it.** The Row says `email: Str`; the insert accepts a literal, a `[]const u8`, a `[]u8` an allocator returned, or a `Str` from the request, and writes each the same way. Nothing needs converting on the way in, and `made.email` is a `Str` on the way out, owned by the Scope for as long as the request lasts ([ADR 116](../../adr/116-a-raw-parameter-is-converted-the-way-a-rows-is.md)). An optional column accepts `null` and a `?T` of any of those forms.

### Update and delete need a condition

**`update` and `delete` return the number of rows they touched, and both require a condition.** An update with no `.where` rewrites the whole table and a delete with none empties it. Both happen by leaving something out rather than by writing something, so both are compile errors:

```
error: nilo: an update on User with no condition.
       That rewrites every row in the table. If it is meant, `db.raw` says
       so where somebody reading the code can see it.
```

A condition can also turn out to be empty because of what the request sent. Say a delete keeps a list of rows: `.where = .{ .id = .{ .not_in = keep } }`. On the day `keep` arrives empty, that is `"id" <> ALL('{}')`, which is true for every row. An empty search box does the same through `.contains = ""`, and a box holding `%` does it through `.ilike`, which uses the text as the pattern unchanged. The compiler cannot see values, so **an `update` or a `delete` whose condition would match every row with the values it was given is rejected before it is sent**, as `error.QueryFailed` with a log line naming the call. An empty list next to a term that does narrow the rows, such as `.{ .tenant_id = t, .id = .{ .not_in = keep } }`, is an ordinary condition and goes through.

### Updating a count in place

**To change a count, let the database do the arithmetic on the stored value.** `.set = .{ .views = .{ .plus = 1 } }` writes `SET "views" = "views" + $1`, and `.minus` goes the other way. The database adds to the value the row holds when the statement runs. `.set = .{ .views = page.views + 1 }` sends the number the handler read earlier, so two requests that read the same number write the same result, and one view is lost. Only a numeric column that is not optional accepts either operator.

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

### A PATCH in one statement

**`sql.given` in a `.set` updates a column only when the client sent a value for it.** A PATCH body is a struct of optionals, and a field the client left out is a column nothing should touch. With `sql.given`, the column takes the value when there is one and keeps what the row holds when there is not.

<!-- compiles -->
```zig
const Draft = struct {
    pub const nilo_table = .{ .name = "drafts", .key = .id };

    id: i64,
    title: nilo.Str,
    words: i32,
    edited_at: sql.Timestamp,
};

/// What the client sent. A field it left out is null.
const DraftPatch = struct {
    title: ?nilo.Str = null,
    words: ?i32 = null,
};

fn patchDraft(db: *sql.Db, c: *nilo.Ctx, draft_id: i64, body: DraftPatch) !?Draft {
    return db.updateReturningOne(Draft, c, .{
        .set = .{
            .title = sql.given(body.title),
            .words = sql.given(body.words),
            .edited_at = .now,
        },
        .where = .{ .id = draft_id },
    });
}
```

```sql
UPDATE "drafts" SET "title" = COALESCE($1, "title"), "words" = COALESCE($2, "words"),
  "edited_at" = now() WHERE "id" = $3 RETURNING …
```

It is one statement whichever fields arrived, so it is prepared once. A `sql.given` on a column that may be NULL does not compile: there, `null` in the body could mean *clear it*, and `COALESCE` would keep the old value and still answer 200. Set that column with a plain value, where null writes NULL.

`.now` is the database's clock, the same expression `.default = .now` writes, and it binds nothing. On Postgres it is the moment the transaction began, so every row one `Tx` stamps gets the same time. On SQLite it is the moment each statement runs: every row one `UPDATE` stamps gets the same time, and two statements in one `Tx` get two. Where two writes have to agree, take `sql.Timestamp.now()` once and pass it to both. It works on a `sql.Timestamp` column and is rejected anywhere else.

## Inserting and updating many rows

**[`insertMany`](../../reference/sql.md#a-batch) inserts a whole batch in one statement.** A loop of `db.insert` is a round trip per row, and inside a transaction it is a round trip per row while holding a pool connection.

<!-- compiles -->
```zig
const Line = struct { sku: nilo.Str, qty: i32 };

fn receive(db: *sql.Db, c: *nilo.Ctx, body: []const Line) ![]Item {
    return db.insertMany(Item, c, body);
}
```

The rows come back in the order they were sent, and the statement orders them so: the `ORDER BY` is on the ordinal `WITH ORDINALITY` adds, which costs no sort. `tx.insertMany` is the same call inside a transaction.

The rows are a slice of a **named** struct, not a tuple of literals, because the statement is compiled from the element type. It compiles to one array parameter per column:

```sql
INSERT INTO "items" ("sku", "qty")
SELECT "sku", "qty"
FROM unnest($1::text[], $2::int4[]) WITH ORDINALITY AS "v"("sku", "qty", "#n")
ORDER BY "#n"
RETURNING "id", "sku", "qty"
```

Two placeholders for any number of rows keeps the statement a constant. The `VALUES ($1,$2),($3,$4),…` most libraries generate has the batch size built into it, so the SQL would be rebuilt on every call and Postgres would plan it again for every different size ([ADR 047](../../adr/047-a-batch-is-one-array-per-column.md)).

Because it is one statement, a batch that violates a constraint stores **none** of its rows. That is usually what you want, and the opposite of a loop of inserts with no transaction around it. An empty batch runs the statement, stores nothing and returns nothing.

Two kinds of column cannot be batched, and both are compile errors: a list column, because `unnest` would flatten it into one row per element, and an enum that has not declared the name of its Postgres type.

**`updateMany` updates a batch the same way**, joining the arrays against the table instead of selecting them into it:

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

Each row carries the Row's **key** and is matched by it. That is why there is no `.where` to write, and why a batch without the key is a compile error. A key the table does not have matches nothing, so a result shorter than the batch tells you which rows were updated.

Two things are not guaranteed, and both come from how a join works: the **order** of the returned rows is the planner's, and a batch with the same key twice changes that row once, from whichever of the two Postgres reached. Where either matters, use `db.update` in a loop.

## Returning the changed rows

**`updateReturningOne` changes a row and returns it in one statement.** A `PATCH` endpoint changes a row and responds with it. Written with `update`, that is two round trips, and the second may read what somebody else changed in between:

<!-- compiles -->
```zig
fn rename(db: *sql.Db, c: *nilo.Ctx, id: i64, body: Rename) !?User {
    return db.updateReturningOne(User, c, .{
        .set = .{ .name = body.name },
        .where = .{ .id = id },
    });
}
```

`updateReturning` is the same statement returning a slice, for a `.where` meant to match many rows. `deleteReturning` is the delete version, for a delete that has to report or log what it removed, and `deleteReturningOne` is its one-row form. The clause they add is the `SELECT` list this module already writes, so none of them costs a statement the compiler did not already build ([reference](../../reference/sql.md#queries)).

**The `…One` calls change at most one row, or they do not compile** ([ADR 146](../../adr/146-a-statement-with-a-key-in-it-has-a-single-row-answer.md)). The `.where` has to hold the key, or every column of a `.unique`, with `=`. An `UPDATE` that matches several rows changes all of them, so returning one row would hide the rest:

```
error: nilo: `updateReturningOne` on User has a condition that can match more than one row.
       It answers with one row, and the statement changes every row the condition matches.
       Hold the key with `=`: .{ .id = … }
       Or call `updateReturning`, which answers with every row it changed.
```

Extra terms beside the key only narrow the match, so `.{ .id = id, .owner_id = me }` is fine; it is how a handler says "this row, if it is mine". `!?User` is already a 404 in the typed layer, so the handler above is the whole endpoint.

A one-time token uses `deleteReturningOne`. The row is found and removed by one statement, so a link clicked twice at the same moment works only once:

<!-- compiles: body -->
```zig
const reset = try db.deleteReturningOne(Reset, c, .{ .where = .{ .digest = sql.Bytes.of(&digest) } }) orelse
    return nilo.fail.unauthorized("that link is not one", .{});
```

`db.rawOne` is the same for a statement you wrote yourself. **It adds no `LIMIT 1`**, unlike `db.one`: this module did not write the statement and has no safe place to put one.

## Upserts: insert or update

**`insertOrIgnore` and `insertOrUpdate` handle a row that may already exist in one statement, with `ON CONFLICT`.** The version everybody writes first catches an error and runs a second statement:

```zig
const user = db.insert(User, c, .{ .email = email, .name = name }) catch |err| switch (err) {
    error.AlreadyExists => try db.updateReturning(User, c, .{ … }),   // two round trips
    else => return err,
};
```

That is two round trips with a gap between them: two requests can both fail the insert, both run the update, and the second one wins regardless of which arrived first. `ON CONFLICT` is one statement and has no gap.

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

The last argument is the **conflict target**: the column the database has a unique constraint or index on, written the way a key is. For a constraint over two columns it is a tuple, `.{ .tenant_id, .email }`. It does not have to be the Row's key. An email is the usual case, and it is the `.unique = .{.email}` the [tables page](./tables.md) declared ([reference](../../reference/sql.md#upserts)).

**The target has to be the key or a `.unique` the marker declares**, or the upsert does not compile. The database would reject it anyway, but only when the statement runs, which is the first request down that path in production. A unique that ignores case does not count either: both databases build it on the lowercased value, and `ON CONFLICT ("email")` does not match it. A table with `.managed = false` is declared by somebody else and is not checked.

**When the target is the key, write `.key`** ([ADR 151](../../adr/151-a-key-is-named-once.md)):

<!-- compiles: body -->
```zig
_ = try tx.insertOrIgnore(UserTag, c, .{ .user_id = id, .tag = tag_name }, .key);
```

A join table already names its composite key in `nilo_table`, and writing the tuple again at the call site gives two copies that can drift apart. If the key gains a column and the call site does not, the statement conflicts on the *old* columns and inserts a duplicate where it used to ignore one. A Row that also has a column called `key` is a compile error naming both meanings.

**They are two calls rather than one call with an option**, because the result has a different type. `DO NOTHING` stores no row, and `RETURNING` on a row that was not stored returns nothing, so `insertOrIgnore` returns `?User` where `insertOrUpdate` returns `User`. It is the same reason `one` is not `select` with a flag.

`insertOrUpdate` sets every column you passed **except the conflict target and the key**. The target is the value the two rows were matched on. The key is left out because a caller passing `.id` is filling in the insert half: nobody means "renumber the existing row", and Postgres would do it silently, along with every foreign key pointing at that row. If that leaves nothing to set, the compiler says so and names the call you wanted:

```
error: nilo: `db.insertOrUpdate` on User has nothing to set.
       Every column it was given is either the conflict target or the key
       `id`, and the update half writes neither.
       `db.insertOrIgnore` is the statement with nothing to set, and says so.
```
