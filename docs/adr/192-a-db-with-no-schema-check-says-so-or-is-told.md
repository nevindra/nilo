# A Db with no schema check says so, or is told

**Status:** accepted
**Topic:** [sql-runtime](../design/sql-runtime.md)
**Extends:** [ADR 115](./115-a-boot-dials-the-connection-its-work-needs.md),
which closed the second way to end up without a check; this closes the
first.
**Applies:** [ADR 036](./036-the-shape-of-a-query-is-settled-while-compiling.md),
[ADR 145](./145-a-suite-whose-database-is-down-is-not-a-suite-that-failed.md).

## Context

`db.checking(schema)` compares every Row against its table while the
server starts, and nothing warned when it was never called: the check
simply did not run, and the disagreement it would have caught arrived as a
500 on the first request that read the column. Zig cannot enumerate the
Rows a program declares, so there was nothing to derive the list from.

The roadmap held the entry at *waiting on a design* between two bad
answers: a warning at `nilo_start` for every `Db` with `check == null`,
which is noise for a program that meant it — a fixture, a scratch file,
a program whose every query is `db.raw` — and an explicit
`db.checking(.{ .tables = &.{} })` to say so, which is a second way to
spell nothing.

## Decision

**A `Db` that reaches `nilo_start` with `checking` never called warns
once, and `.unchecked = true` in its options is how a program says it
meant it.**

```
sql.Db is starting with no schema check: `db.checking(schema)` was never
called, so a Row that disagrees with its table is found by the first
request that reads it. If that is meant, say `.unchecked = true` in the
options.
```

**`checking` is called once.** A second call, with the same schema or another, used to replace the first without a word, so a program whose tables belong to several files could register it twice and have a check that covered less than it thought. It is now a refusal at boot: `nilo_check` returns `error.CheckedTwice` with a sentence saying `checking` was called twice on one `Db` and that the tables belong in one `sql.Schema` (`a.tables ++ b.tables`), the value ADR 181 hands to `checking`, the migrations tool and `createMissing` alike. It is not additive, because that would make three places that take a schema disagree about what one is. It is said at `warn` and the error is what stops the boot, because a test cannot take a path that logs `err` (ADR 145). It is checked before the dial, since it is a fact about the program and not the database.

**The option is a word rather than an empty list because the two mean
different things.** `checking(.{ .tables = &.{} })` claims to check and
checks nothing; `unchecked` says the check is off. A `Db` with `check ==
null` was a decision nobody had written down, and the fix is a place to
write it down whose name is what it means. A `checking` list that was
given still runs whatever the option says — a check asked for is a check.

**Said before the dial, at `warn`.** It is true whether or not the
database is up, so it does not wait for the pool; and `warn` rather than
`err` for the reason every line in `nilo_start` is one (ADR 145): a
logged `err` fails the test runner, and this is a line about a program's
shape rather than about a broken program.

**Every test fixture in the repository says `.unchecked = true`**, which
is two dozen lines and the honest reading of what they are. The one that did
not was the point.

## What it costs

Nothing per request: a bool on `Opts`, read once at `nilo_start`. One log
line per process for a program that has not decided.

## Alternatives

**Making a second `checking` add to the first.** Rejected: ADR 181 makes the schema one value, and an additive call is a second way to spell it that the migrations tool and `createMissing` cannot follow.

**Warn with no way to silence it.** Rejected by the roadmap: noise for a
program that meant it is a warning that gets tuned out, and then the one
that mattered is tuned out with it.

**`checking(.{ .tables = &.{} })` as the way to say so.** Rejected above:
it is a claim to have checked.

**Deriving the list.** There is nothing to derive it from; the Rows are
types, and a type is not enumerable from a program.

## Consequences

- `sql/db.zig`: `Opts.unchecked`, `forgotTheCheck`, the line in
  `nilo_start`, and `checked_twice` with its refusal in `nilo_check`.
- Every `Db` a test starts without a `checking` list says
  `.unchecked = true`.
- The guide's running page and the reference's `Opts` table carry the
  word; the roadmap loses "The schema check is opt-in, and forgetting it
  is silent".
