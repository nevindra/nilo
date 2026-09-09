# A statement with a key in it has a single-row answer

`db.one` is the typed select's answer to *this row or none*. `db.raw` and
`db.updateReturning` had no such thing, so a statement whose `WHERE` holds a
primary key ended in the same unwrap:

```zig
const found = try db.raw(rows.WorkItemCard, c, …, .{id});
return if (found.len > 0) found[0] else null;
```

Six times in four files in one context — three mention cards, `partner.rename`,
`contact.update` and `comment.edit`. Nothing fails. It is six copies of one line,
and the handler wants `!?T` because `?Row` is already a 404 in the typed layer
(ADR 0024).

## What was added

```zig
db.rawOne(Row, c, sql, values)                 // and tx.rawOne
db.updateReturningOne(Row, c, options)         // and tx.updateReturningOne
```

Both answer `!?Row`. Both send exactly the statement the plural call sends.

## No `LIMIT 1` is added, and that is the whole of how `rawOne` differs from `one`

`db.one` compiles its own `LIMIT 1`, which is why a condition on a column that is
not unique costs one row there rather than every match. `rawOne` cannot: this
module did not write the statement and has nowhere honest to put one — a `LIMIT`
after a `UNION ALL` or inside a CTE means something else, and appending text to
somebody else's SQL is the thing `db.raw` exists not to do.

So a statement matching many rows still costs every one of them. **It is a
shorter way to write the unwrap, not a cheaper statement**, and saying so here is
the point: a caller who reads `rawOne` as "and it limits" would be wrong about
the cost of a page.

The same is true of `updateReturningOne` for a different reason: the `.where` is
the caller's condition and an `UPDATE` matching several rows updates all of them.
Handing back the first is the shape of the call site, exactly as `db.one` does
for a condition that is not unique — not a promise about the statement.

## What was deliberately not added

`deleteReturningOne`. The shape is identical and no caller has hit it. The
roadmap's status for that kind of gap is *waiting on a caller*, and a call that
exists only for symmetry is a call whose message nobody has ever read.

## Against ADR 0018's four axes

Zero on all four. Each is the plural call with `if (rows.len == 0) null else
rows[0]` after it, which is what the caller was writing. No new statement is
compiled — `rawOne` reuses `rawcheck.assertList` and `updateReturningOne` reuses
`statement.updateReturning`, so the prepared-statement name is the same one and
a program using both spellings prepares one statement, not two.

## Consequences

- The `SELECT`-list check `db.raw` gets while compiling (ADR 0148) applies to
  `rawOne` unchanged, and names `db.rawOne` in its message.
- A projection works here as it does everywhere `raw` does.
- Four calls, not two: the `Tx` half exists because a transaction that could not
  do this would send the caller back to the unwrap inside the one place it
  matters most.
