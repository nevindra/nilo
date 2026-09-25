# A statement that failed says what the database said, to the call that caused it

**Status:** accepted
**Topic:** [sql-runtime](../design/sql-runtime.md)

## Context

`error.QueryFailed` was the whole debugging surface for a statement the database refused. The reference said the server's text is logged, never sent, which was half true: it went to `std.log.err` and nowhere a program could reach, so an operator with a log reader had it and the code did not. The half that was not true was worse. When the driver refuses a statement before it leaves the process, pg.zig declining to bind a value is the ordinary way there, `conn.err` is null, the `else` arm logged nothing at all, and Postgres logged nothing either because nothing arrived. A caller had one word, `QueryFailed`, for a failure the database had never seen, and the same SQL pasted into `psql` ran. That gap turned [ADR 116](./116-a-raw-parameter-is-converted-the-way-a-rows-is.md) into three iterations of somebody's afternoon; the missing word was `CannotBindStruct`.

Once the database's own words reached a watcher, a second gap showed up porting a Go service. Two refusals there were the same shape, a constraint fires and the useful answer is a sentence about what somebody should do next:

```go
// org.DeleteStaff: the race between the footprint count and the DELETE
if isForeignKeyViolation(err) {
    return apperr.Conflict{Reason: "was given something to do a moment ago and can no longer be deleted. Set them inactive instead"}
}
// org.CreateStaff
if isUniqueViolation(err, "staff_email_key") { … "already listed as Rani Putri, in Engineering" }
```

`translate` mapped `23505` to `error.AlreadyExists` and everything else in class 23 to one word, `error.ConstraintViolated`, so a foreign key that lost a race, a check somebody wrote on purpose, and a null the code should never have sent all arrived indistinguishable. The first port above became a 500 with a comment beside it; the second was not ported at all. **An observer cannot tell a caller's own failure from a concurrent one on another connection, and the caller is the only thing that knows what sentence a given failure deserves**, so the whole `Problem` going to a watcher was the right answer for a log and the wrong one for a branch.

## Decision

**A failed statement reports two things, at two addresses: the database's own words go to whoever is watching, and a name precise enough to switch on, plus the constraint that fired, goes to the call that caused the failure.**

### The words: an out-parameter, because a Zig error is control flow and a database's message is data

`run` and `exec` gained a `problem: ?*?Problem` parameter. The Wire fills it only when the statement fails, and only when somebody passed a slot. The obvious alternative is a bigger error set, or an error union carrying the text; both are refused for the reason `Sent` already refuses parameters on itself: the error set is what a handler switches on, and a set that grows breaks every switch that was exhaustive before it grew. The seven errors stay, the text rides beside them, and null is what a caller with nothing to tell passes, at the cost of one branch. It never reaches the client: [ADR 024](./024-every-failure-answers-as-json.md) is unchanged, a 500 says the same thing it always did. This is for the watcher and the log.

A cancellation is the one failure that is neither reported as a refusal nor kept: the statement it cut off answers `QueryFailed` and the cancellation is re-armed for the caller's next cancellation point ([ADR 223](./223-a-statement-cut-off-by-a-cancellation-hands-it-back.md)).

`Problem.message` always says something. When there is no server answer, the Zig error's own name goes in, `@errorName` points into the binary and needs no copy, so the statement that never left the process reports `CannotBindStruct` rather than nothing. SQLite has its own version of the hole, `sqlite3_errmsg` answers `"not an error"` when the failure never reached SQLite, so that answer is dropped for the error name too. `code`, `severity`, `detail`, `hint` and `constraint` default to `""` rather than `?`: SQLite has no SQLSTATE, no severity word and no separate hint, and inventing one would be this module making something up in a field whose only value is that it came from the database, so those stay empty and read the same way in a log line as a `null` would without making every reader unwrap. `detail` is named apart from `message` because it is usually the values that collided, data a request supplied, worth being able to see before turning it on. Every field is copied into the request's arena, because the driver's own pointer goes back to the pool on the next line, the rule every `Str` here already follows; an allocation failure while copying is not itself an error, since that would turn "the statement was refused" into "we ran out of memory telling you so" on a path that is already failing, and what cannot be copied is left empty.

### The name: a SQLSTATE class a caller can act on gets a name, and a name gets a status only when the request cannot change what it means

| SQLSTATE | | default |
|---|---|---|
| `23505` | `error.AlreadyExists` | 409 |
| `23503` | `error.ForeignKeyViolated` | none |
| `23502` | `error.NotNullViolated` | none |
| `23514` | `error.CheckViolated` | none |
| rest of class 23 | `error.ConstraintViolated` | none |
| `40001`, `40P01` | `error.RolledBack` | 503 |
| `0A000` *cached plan must not change result type*, inside a transaction | `error.RolledBack` | 503 |
| the connection went, or never came | `error.Disconnected` | 503 |
| `25P02`, a statement in an aborted transaction | `error.QueryFailed`, with a line naming the earlier failure | 500 |

`23503` is the one that matters in class 23: it is the only member that is routinely a race rather than a bug, a delete guarded by a count is correct right up until somebody writes a child row between the two statements. It deliberately has no default status: it is a 409 for the delete above and a 400 for an insert naming a parent that was never there, and nothing in `http/` can tell those apart, which is why it is a name rather than a status.

**`RolledBack` is the one error in the set where the same code, run again, is correct.** A serialization failure under `.repeatable_read` or `.serializable` and a deadlock under any level both mean Postgres rolled the whole transaction back to keep the ones beside it consistent. Before it had a name they were `QueryFailed`, the word a typo gets, so a handler that asked for `.serializable`, which [ADR 048](./048-contention-is-what-a-transaction-is-for.md) offers and which costs retries by definition, had no way to write the retry. A plan a running migration has changed the answer of lands on the same name inside a transaction: the refusal aborted it, and the next attempt prepares the statement fresh ([ADR 051](./051-a-statement-that-is-a-constant-can-be-prepared-once.md)). `40003`, *statement completion unknown*, is left out on purpose: it is the one member of class 40 that must not be answered with a name that says nothing was kept.

`AlreadyExists`, `RolledBack` and `Disconnected` have a status in `fail.statusFor` because each means the same thing whatever the request was: the client asked for something already there, or the database gave the work up, or the database was not there. The last two are a 503 because the request was sound and the same request sent again may go through. Both Wires answer the same word for the same failure: SQLite's extended result codes name the class-23 three natively, so `sqlite.zig` is a switch where `postgres.zig` is a SQLSTATE comparison, which is what lets a handler tested against SQLite branch on what Postgres will send it.

### The constraint: `sql.problem(c)`, threadlocal, cleared by every statement

An error name cannot say which unique index fired, `staff_email_key` is the whole of the second port above:

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

It is not a field on the `Db`: a `Db` is one Service shared by every request in flight, so a slot on it would be the last failure anywhere, which is exactly the property this exists to avoid, the design asked to keep it belonging to the call rather than to the `Db`. It is `threadlocal`, and a fiber owns its thread for as long as it is running: there is no suspension point between a statement failing and the `catch` that reads it, the recording happens after the watcher has been told, so a watcher that suspends cannot get between them either. Two things make that safe rather than nearly safe: every statement clears the slot, not only a failing one, because the strings live in the request arena, reset between requests on one connection, and a slot written only on failure would hand back freed bytes to whoever asked after a statement that worked; and the arena is compared, two pointers, so a problem left behind by a fiber that moved is unreadable rather than wrong, and the answer is null rather than a plausible sentence about somebody else's row.

**`sql.violated(c, Row, columns)` is the typed form of that comparison.** The columns are checked while compiling against the key and the marker's `.unique` entries, and the answer is true when `constraint` is either spelling of that one: the name Postgres reports, which `table.constraintName` derives the way Postgres does, or `table.a, table.b`, which is what SQLite puts after `constraint failed:` because it does not report an index's name. The SQLite Wire fills `constraint` from that text. A string compared against `"staff_email_key"` was a name nothing checked and the second database never said; a unique renamed in the marker is now a build error at every branch on it. A foreign key is refused, since SQLite names none.

SQLite reports an `INSERT … RETURNING`'s constraint at the first step rather than when the statement is prepared, and the `Db` asked the Wire for a problem only when the statement was sent. The read path now asks again when a step fails (`stepProblem`), so the watcher and `sql.problem` hear about the duplicate a signup form branches on.

### How it is held

`Fake.refuses` is a `?Problem` the Fake answers every statement with, the one thing a Fake can say that a real database cannot be made to say on demand: the driver said this. The path from a Wire's out-parameter through `told` to `Sent.problem` is tested with no Postgres and no SQLite installed. The live tests check the other end, that a real constraint violation arrives with `23505` in `code` and the constraint's name in `constraint`.

## What was rejected

**A richer error set, or an error union carrying the text**, in place of the out-parameter. A Zig error is a control-flow decision and the server's message is data; the two do not want the same channel, and a growing error set breaks an exhaustive switch that used to compile.

**An out-parameter per call for the constraint too**, `db.insert(Row, c, values, &problem)`. Twenty signatures, and the parameter is null at nineteen of the twenty call sites that would have to write it.

**A second set of calls**, `db.insertWatching(…)`, for the same reason. A parallel API for one field.

**`AlreadyExists` as the only error with a default status.** Held until a serialization failure, a deadlock and a database that was down all reached a client as 500, the status that says the server has a bug, when what was true was that it was busy or waiting on its database. A default is refused only where the request decides what the error means; for these two it does not.

**`RolledBack` as a flag on `QueryFailed`, read off `sql.problem(c).code`.** It is the one failure a handler is expected to branch on in a loop, and a branch that has to compare `"40001"` and `"40P01"` by hand, on the Postgres Wire only, is the Go code this ADR opened with.

**The Bulkhead's fiber slot**, what `fail.zig` already uses. It lives in `http/`, and `sql/` may not name `nilo_http` ([ADR 038](./038-a-module-sits-where-the-loop-puts-it.md)); reproducing it here would be a second fiber registry that has to agree with the first.

## What it costs

Against [ADR 017](./017-the-trade-budget-has-four-axes.md)'s four axes:

| Axis | Cost |
|---|---|
| Allocations per request | Zero on a statement that works. The out-parameter slot is a stack local; the `Problem` struct is stored, not copied again, into the threadlocal. A statement that fails allocates up to six short strings in the arena, on a path that is already returning an error. |
| Memory per idle connection | Zero. One `?Problem` per **thread**, 128 bytes on a sixteen-thread process once, not per connection. |
| Throughput and p99 | One null check per statement on the failure path, plus one store per statement on the success path (a null tag and a null allocator). Against a round trip, nothing. |
| Binary size | Unchanged on the measured binaries, neither of which links `nilo_sql`. The `reported` and `said` functions land in any program that links a driver. |

Stack, separately from the four axes: 104 bytes per statement call, `@sizeOf(?Problem)`, six slices plus the optional's tag, in the frame the call was already in; the pointer the Wire takes is 8. That matters more than the number suggests, because a suspended fiber holds its stack for the life of the connection ([ADR 062](./062-where-a-connection-waits-is-what-it-costs.md)), which is why `Problem` holds slices into the arena rather than buffers of its own: six fixed 256-byte fields would have put 1.5 KiB there instead.

## Consequences

- `wire.Problem`, and a `problem: ?*?Problem` parameter on `run` and `exec` in the Wire contract, so every Wire, including `Fake`, changed signature.
- `Sent.problem`, and `logging` prints it in front of the SQL. The two startup queries pass `null`: nobody is watching a schema check, and its one caller already has a sentence for a check it could not run.
- `translate`'s `else` arm names the driver's error rather than swallowing it, fixing the log for callers who never touch a watcher.
- `sql.problem` is `db.lastProblem` under another name, because `problem` is what every statement in `db.zig` already calls the slot it hands the Wire.
- `db.watching` is unchanged and is still how every statement gets logged; `sql.problem` answers a different question, and now both can be asked.
- **A caller catching `error.ConstraintViolated` for a foreign key stops catching it**, since that failure now arrives as `error.ForeignKeyViolated`. The one breaking edge, carried in `CHANGELOG.md`.
- **A caller catching `error.QueryFailed` for a serialization failure or a deadlock stops catching it**, since those now arrive as `error.RolledBack`; and a handler that let `Disconnected` or `RolledBack` escape answers 503 where it answered 500. Both in `CHANGELOG.md`.
- The log line for a statement the server refused is `warn`, not `err`: it is a request failing, and `err` is the level that says the server is refusing to start.
