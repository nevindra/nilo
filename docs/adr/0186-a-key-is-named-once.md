# A key is named once

Since [ADR 0172](0172-a-key-is-as-many-columns-as-it-takes.md) a Row names its
key, composite or not. `insertOrIgnore` and `insertOrUpdate` still made the call
site spell the same tuple a second time.

```zig
pub const nilo_table = .{ .name = "staff_roles", .key = .{ .staff_id, .role }, .managed = false };

// …and then, at the only place that writes one:
try tx.insertOrIgnore(rows.StaffRole, c, .{ .staff_id = id, .role = role }, .{ .staff_id, .role })
```

## Why it is a decision rather than a shrug

The two copies can disagree, and the way they disagree does not fail.

A Row whose key gains a column and a call site that does not is a statement
conflicting on the **old** columns. `ON CONFLICT (staff_id)` on a table whose
primary key is now `(staff_id, role)` does not error — it matches a different
set of rows, so it inserts a duplicate where it used to ignore one. It compiles,
it passes, and the row count is wrong.

## `.key`

```zig
try tx.insertOrIgnore(rows.StaffRole, c, .{ .staff_id = id, .role = role }, .key);
```

An enum literal, the way every other column is named at a call site. It reads
off `nilo_table`, so the two spellings are one spelling.

**The explicit form stays for what the reference already says it is for**: a
unique index that is not the key. That case is real — an `email` column with a
`UNIQUE` on it and a generated `id` for a key — and nothing about it changes.

**Not a dropped fourth argument, which is what the report asked for.** Zig has
no default arguments, so the choice was between a shorter word in the same
position and a second call named for having one fewer parameter. The word also
says something the missing argument would not have: *the key*, rather than
*whatever nilo picks*.

## One Refusal

A Row with a column called `key` is an ordinary table to have — a table of API
keys, a settings table of key and value. There the word would mean two things at
one call site, so it is refused with both readings written out: `.{ .key }` for
the column, or the key's columns named one by one.

It is refused **only where the two would both apply**, which is a conflict
target. `key` stays an ordinary column name everywhere else, including in a
condition and in a `.set` — unlike `any`, `exists` and `not_exists`, which
`where.zig` reserves across the whole Row because a condition could carry either
meaning anywhere.

## Against ADR 0018's four axes

- **Allocations per request: zero.** The conflict target is a comptime list of
  column names, and this reads it from one place instead of another.
- **Memory per idle connection: zero.**
- **Throughput: zero.** Same statement, same parameters, same plan name — the
  test asserts the two spellings compile to the same SQL, which is the whole
  claim.
- **Binary size: zero.**

## Consequences

- `db.insertOrUpdate(Row, c, values, .key)` compiles and is usually a Refusal
  one line later, correctly: the update half leaves out both the conflict target
  and the Row's key, and with `.key` those are the same columns, so a call whose
  values are only key columns has nothing to set. The message already points at
  `insertOrIgnore`.
- `notAConflictTarget` and the empty-target message both name `.key` now, so
  somebody who reaches either one is told the short form exists.
