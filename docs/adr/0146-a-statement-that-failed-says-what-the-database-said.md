# A statement that failed says what the database said

`error.QueryFailed` was the whole debugging surface for a statement the
database refused. The reference said the server's text is "logged, never sent",
which was half true: it went to `std.log.err` and nowhere a program could
reach, so an operator with a log reader had it and the code did not.

The half that was not true is worse. When the driver refuses a statement
*before it leaves the process* — pg.zig declining to bind a value is the
ordinary way there — `conn.err` is null, the `else` arm logged nothing at all,
and Postgres logged nothing either because nothing arrived. A caller had one
word, `QueryFailed`, for a failure the database had never seen. The same SQL
pasted into `psql` ran.

That is what turned [ADR 0145](0145-a-raw-parameter-is-converted-the-way-a-rows-is.md)
into three iterations of somebody's afternoon. The missing word was
`CannotBindStruct`.

## Why an out-parameter and not a richer error

`run` and `exec` gained a `problem: ?*?Problem`. The Wire fills it only when
the statement fails, and only when somebody passed a slot.

The obvious alternative is a bigger error set, or an error union carrying the
text. Both are refused for the reason
[ADR 0137](0137-a-statement-can-be-watched.md) already gives about `Sent`: the
error set is what a handler switches on, and a set that grows breaks every
switch that was exhaustive before it grew. The seven errors stay. The text
rides beside them.

An out-parameter is not free of taste, but it is honest about what this is: a
Zig error is a control-flow decision and the server's message is data, and
those two do not want the same channel. Null is what a caller with nothing to
tell passes, and it costs one branch.

**It never reaches the client.** [ADR 0025](0025-every-failure-answers-with-the-same-json-body.md)
is unchanged: a 500 says the same thing it always did. This is for the watcher
and the log, which is where a database's own words belong.

## The message is never empty

`Problem.message` always says something, and the case that forced the rule is
the one this exists for. When there is no server answer, the Zig error's own
name goes in — `@errorName` points into the binary and needs no copy. So the
statement that never left the process reports `CannotBindStruct` rather than
nothing.

SQLite has its own version of that hole. `sqlite3_errmsg` answers
`"not an error"` when the failure never reached SQLite — a bind zqlite refused
— so that answer is dropped for the error name, which does say something.

## Empty rather than optional, and only what the database offers

`code`, `severity`, `detail`, `hint` and `constraint` default to `""`.

SQLite has no SQLSTATE, no severity word and no separate hint. Inventing a code
would be this module making something up in a field whose only value is that it
came from the database. So those stay empty, and `""` reads the same way in a
log line as a `null` would without making every reader unwrap.

`detail` is named separately rather than folded into `message` because it is
usually the values that collided. A watcher that logs it is logging data a
request supplied, which is worth being able to see before you turn it on, and
is the reason `Sent` carries no parameters.

## Every field is copied into the request's arena

`server.message` points into memory pg.zig owns per connection, and the
connection goes back to the pool on the next line. Same for SQLite's
`lastError()`.

So a `Problem` lives exactly as long as the request that produced it — the rule
every `Str` here already follows ([ADR 0004](0004-request-arena-and-the-str-type.md)),
and the reason a watcher that wants to keep one has to copy it.

**An allocation failure while copying is not an error.** This runs on a path
that is already failing, and turning "the statement was refused" into "we ran
out of memory telling you so" would lose the answer the caller came for. What
cannot be copied is left empty.

## How it is held

`Fake.refuses` is a `?Problem` the Fake answers every statement with. It is the
one thing a Fake can say that a real database cannot be made to say on demand:
*the driver said this*. So the path from a Wire's out-parameter through
`told` to `Sent.problem` is tested with no Postgres and no SQLite installed.

The live tests check the other end — that a real constraint violation arrives
with `23505` in `code` and the constraint's name in `constraint`.

## What it costs

Against [ADR 0018](0018-the-trade-budget-has-three-axes.md)'s axes:

- **Allocations per request: none on a statement that works.** The slot is a
  stack local, the Wire writes to it only on failure, and `told` reads it only
  when there is a watcher. A statement that fails allocates up to six short
  strings in the arena, on a path that is already returning an error.
- **Throughput:** one null check per statement, on the failure path.
- **Stack: 104 bytes** per statement call — `@sizeOf(?Problem)`, six slices
  plus the optional's tag, in the frame the call was already in. The pointer
  the Wire takes is 8. That matters here more than the number suggests,
  because a suspended fiber holds its stack for the life of the connection
  ([ADR 0063](0063-a-handlers-stack-is-per-connection.md)), and it is why
  `Problem` holds slices into the arena rather than buffers of its own: six
  fixed 256-byte fields would have put 1.5 KiB there instead.
- **Binary size:** the `reported` and `said` functions, in any program that
  links a driver.

## Consequences

- `wire.Problem`, and a `problem: ?*?Problem` parameter on `run` and `exec`
  in the Wire contract — so every Wire, including `Fake`, changed signature.
- `Sent.problem`, and `logging` prints it in front of the SQL.
- `translate`'s `else` arm names the driver's error rather than swallowing it,
  which fixes the log for callers who never touch a watcher.
- The two startup queries pass `null`: nobody is watching a schema check, and
  its one caller already has a sentence for a check it could not run.
