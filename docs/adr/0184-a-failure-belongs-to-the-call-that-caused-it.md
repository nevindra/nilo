# A failure belongs to the call that caused it

[ADR 0146](0146-a-statement-that-failed-says-what-the-database-said.md) gave the
whole `Problem` — code, constraint, detail, message — to `db.watching`, and the
call site kept `error.QueryFailed`.

That is the right split for a log and the wrong one for a branch. **An observer
cannot tell a caller's own failure from a concurrent one on another
connection**, and the caller is the only thing that knows what sentence the
failure deserves.

## What was unportable

Two refusals in the Go original the port is replacing, both the same shape: a
constraint fires, and the useful answer is a sentence about what somebody should
do next.

```go
// org.DeleteStaff — the race between the footprint count and the DELETE
if isForeignKeyViolation(err) {
    return apperr.Conflict{Reason: "was given something to do a moment ago and can no longer be deleted. Set them inactive instead"}
}

// org.CreateStaff
if isUniqueViolation(err, "staff_email_key") { … "already listed as Rani Putri, in Engineering" }
```

The first became a 500 with a comment beside it. The second is not ported.

## Half of it is a name

`translate` mapped `23505` to `error.AlreadyExists` and **everything else in
class 23 to one word**: a foreign key that lost a race, a check somebody wrote
on purpose, and a null the code should never have sent, all arriving as
`error.ConstraintViolated`.

Four names where there was one, which is what the report asked for and as far as
it asked:

| SQLSTATE | | |
|---|---|---|
| `23505` | `error.AlreadyExists` | unchanged; the only one with a default status |
| `23503` | `error.ForeignKeyViolated` | **new** |
| `23502` | `error.NotNullViolated` | **new** |
| `23514` | `error.CheckViolated` | **new** |
| rest of 23 | `error.ConstraintViolated` | exclusion, `RESTRICT` |

`23503` is the one that matters. It is the only member of the class that is
routinely a *race* rather than a bug: a delete guarded by a count is correct
right up until somebody writes a child row between the two statements.

**No new default status.** `AlreadyExists` is still the only one with a row in
`fail.statusFor`, and `ForeignKeyViolated` deliberately has none — it is a 409
for the delete above and a 400 for an insert naming a parent that was never
there, and nothing in `http/` can tell those apart. That is why it is a name
rather than a status.

Both Wires answer the same word for the same failure. SQLite's extended result
codes name all three natively, so `sqlite.zig` is a switch where `postgres.zig`
is a SQLSTATE comparison — which is what lets a handler tested against SQLite
branch on what Postgres will send it.

## The other half is `sql.problem(c)`

An error name cannot say *which* unique index fired, and `staff_email_key` is
the whole of the second refusal above.

```zig
db.delete(Staff, c, .{ .where = .{ .id = id } }) catch |err| switch (err) {
    error.ForeignKeyViolated => return fail.conflict(
        "{s} was given something to do a moment ago and can no longer be deleted.",
        .{name},
    ),
    else => return err,
};
```

```zig
const said = sql.problem(c) orelse return err;
if (std.mem.eql(u8, said.constraint, "staff_email_key")) …
```

**It is not a field on the `Db`**, and that is the design rather than a detail.
A `Db` is one Service shared by every request in flight, so a slot on it would
be the last failure *anywhere* — which is the property the report asked to keep:
*"it belongs to the call rather than to the `Db`."*

It is `threadlocal`, and a fiber owns its thread for as long as it is running. A
fiber only moves when it suspends, and **there is no suspension point between a
statement failing and the `catch` that reads this** — the recording happens
after the watcher has been told, so a watcher that suspends cannot get between
them either.

Two things make that safe rather than nearly safe:

- **Every statement clears it, not only a failing one.** The strings live in the
  request arena, which is reset between requests on one connection, so a slot
  written only on failure would hand back freed bytes to whoever asked after a
  statement that worked.
- **The arena is compared.** Two fibers are two connections and two arenas, so a
  problem left behind by a fiber that moved is unreadable rather than wrong.
  Two pointer comparisons, and the answer is null rather than a plausible
  sentence about somebody else's row.

## What was rejected

- **An out-parameter per call** — `db.insert(Row, c, values, &problem)`. Twenty
  signatures, and the parameter is null at nineteen of the twenty call sites
  that would have to write it.
- **A second set of calls** — `db.insertWatching(…)`. A parallel API for one
  field.
- **The Bulkhead's fiber slot**, which is what `fail.zig` uses (ADR 0007). It
  lives in `http/`, and `sql/` may not name `nilo_http` (ADR 0041). Reproducing
  it here would be a second fiber registry that has to agree with the first.

## Against ADR 0018's four axes

- **Allocations per request: zero.** The `Problem` is already copied into the
  request arena by ADR 0146; this stores the struct, not a copy of it.
- **Memory per idle connection: zero.** One `?Problem` **per thread** —
  128 bytes on a sixteen-thread process, once, not per connection.
- **Throughput: one store per statement**, on the success path where it writes a
  null tag and a null allocator. Against a round trip, nothing.
- **Binary size: unchanged** on the measured binaries, neither of which links
  `nilo_sql`.

## Consequences

- **A caller catching `error.ConstraintViolated` for a foreign key stops
  catching it.** That is the one breaking edge, and it is in the CHANGELOG.
- `sql.problem` is `db.lastProblem` under another name, because `problem` is
  what every statement in `db.zig` already calls the slot it hands the Wire.
- `db.watching` is unchanged and is still the way to log every statement. The
  two answer different questions and now both can be asked.
