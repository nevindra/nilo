# A statement with a key in it has a single-row answer

**Status:** accepted
**Topic:** [sql-raw](../design/sql-raw.md)

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
(ADR 023).

## What was added

```zig
db.rawOne(Row, c, sql, values)                 // and tx.rawOne
db.updateReturningOne(Row, c, options)         // and tx.updateReturningOne
db.deleteReturningOne(Row, c, options)         // and tx.deleteReturningOne
```

All three answer `!?Row`, and each sends exactly the statement the plural call
sends.

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

## A write that answers with one row changes one row, or does not compile

**`updateReturningOne` and `deleteReturningOne` refuse a `.where` that could
match more than one row.** It has to hold every column of the key, or every
column of one `.unique` in the marker, each compared with `=` (or `.eq`) to a
value that is always there. Not `null`, which is `IS NULL`. Not an optional,
which may be. Not a `sql.given`, which may drop out. Other terms beside them
only narrow further and are allowed.

The typed builder wrote the `WHERE`, so unlike `rawOne` it can see the
condition, and the cost of not looking is not a slow page. An `UPDATE` matching
several rows changes all of them, and the call handed back the first: a `PATCH`
written against an email that was not unique rewrote every row with that
address and answered with one, and nothing in the answer said so. A caller who
means several rows has `updateReturning` and `deleteReturning`, whose answer is
a slice.

`deleteReturningOne` arrived with the rule. It is what taking a one-time token
is: the row is found and removed by one statement, so two requests presenting
the same link cannot both read it before either deletes it. The sessions guide's
reset flow is written with it.

## What was rejected

**The unwrap alone, for the two writes**, which is how this decision first
shipped: "handing back the first is the shape of the call site, exactly as
`db.one` does". `db.one` is a read, and a read of the wrong row is a wrong
answer. A write of every row is lost data, and the call's name is what told the
caller it would be one.

**Adding `LIMIT 1` to the write.** Postgres has no `UPDATE … LIMIT`, and a
subquery picking "some" row is a statement nobody asked for.

**`deleteReturningOne` left out for symmetry's sake**, which is what the first
version of this ADR said: no caller had hit it. The sessions guide was the
caller, reading a reset row and deleting it after in two statements with a race
between them.

## Against ADR 017's four axes

Zero on all four. Each is the plural call with `if (rows.len == 0) null else
rows[0]` after it, which is what the caller was writing. No new statement is
compiled — `rawOne` reuses `rawcheck.assertList` and the two writes reuse
`statement.updateReturning` and `statement.deleteReturning`, so the prepared-statement name is the same one and
a program using both spellings prepares one statement, not two.

## Consequences

- The `SELECT`-list check `db.raw` gets while compiling (ADR 051) applies to
  `rawOne` unchanged, and names `db.rawOne` in its message.
- A projection works here as it does everywhere `raw` does.
- The single-row rule is two Refusals, `returning_one_on_a_column_not_unique`
  and `returning_one_with_a_range_on_the_key`, in `sql/refusals/`.
- Six calls, not three: the `Tx` half exists because a transaction that could not
  do this would send the caller back to the unwrap inside the one place it
  matters most.
