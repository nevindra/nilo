# `DO NOTHING` has no key to leave out

A pure join table has a composite primary key and no `id`:

```sql
CREATE TABLE partner_capabilities (
    partner_id uuid NOT NULL REFERENCES partners(id) ON DELETE CASCADE,
    capability text NOT NULL,
    PRIMARY KEY (partner_id, capability)
);
```

`db.insertOrIgnore` on it did not compile:

```
sql/row.zig:125: error: nilo: partner.rows.PartnerCapability has no column `id`,
so its nilo_table has to say which column identifies a row.
Write `.key = .<column>` alongside `.name`.
```

It was asking for a key the table does not have, to write a clause it does not
write.

## Why the key was there at all

`insertOrIgnore` and `insertOrUpdate` are the same function,
`statement.upserting`, differing by four words of SQL. The update half leaves
two kinds of column out of its `SET` list: the conflict target, and the Row's
key. The second is deliberate and is worth keeping —
`SET id = EXCLUDED.id` is a primary key change Postgres will do quietly, and
take every foreign key pointing at that row with it.

So `upserting` called `row_mod.keyOf(Row)` at the top, for both actions.
`DO NOTHING` writes no `SET` clause. It is the one upsert with nothing to
exclude a key from, and it was still being made to name one.

## The fix is a comptime `if`

```zig
const key = if (action == .update) row_mod.keyOf(Row) else "";
```

`action` is comptime, so the branch prunes the call entirely and the Row is
never asked a question this statement does not ask. Nothing else in the
function moves: the `SET` loop compares against an empty string, matches
nothing, and its result is read only by the `.update` arm of the clause
switch.

## Why this is separable from the composite-key gap

The roadmap has an entry saying a composite key costs `find` and `updateMany`,
and that entry is still true: both of those genuinely need to identify one
row, and a Row with two key columns cannot say so. This is a third thing the
same table lost, and it is the one that was lost for no reason. The conflict
target had already been given explicitly at the call site:

```zig
_ = try db.insertOrIgnore(rows.PartnerCapability, c, .{ … }, .{ .partner_id, .capability });
```

That tuple is the only identity the statement needs.

## What this does not change

`db.insertOrUpdate` still demands a key, and still refuses a Row that has no
`id` and no `.key`. `sql/refusals/no_id_and_no_key.zig` still pins that
message, because it exercises `sql.row.keyOf` directly rather than through an
upsert.

## Consequences

- A join table with no `id` can be written idempotently, which is what
  `insertOrIgnore` is for.
- One test, `"a join table with no id can still be inserted-or-ignored"`, in
  `sql/statement.zig`. It is a comptime test: the statement either compiles or
  it does not, and there is nothing to run.
- No axis moves. The call that changed produces the same SQL it always did for
  every Row that already compiled.
