# A run cut off by a shutdown goes back to the queue, whatever the statement said

**Status:** accepted
**Topic:** [job](../design/job.md)
**Extends:** [ADR 160](./160-a-queue-is-a-table-in-the-database-you-already-have.md) (a row a shutdown interrupts goes back untouched)
**Applies:** [ADR 223](./223-a-statement-cut-off-by-a-cancellation-hands-it-back.md) (a cut-off statement answers `QueryFailed` and leaves the cancellation pending), [ADR 082](./082-a-cleanup-path-is-not-cancellable.md) (a cleanup path is not cancellable)

## Context

ADR 160 says what happens to a row when the server stops in the middle of
its run: it goes back to the queue untouched, and whoever starts next takes
it. `executeKind` did that on one condition, `err == error.Canceled`.

Since ADR 223, a run that is waiting on a statement when the shutdown comes
never returns `error.Canceled`. nilo_sql answers `QueryFailed` and re-arms the
cancellation for the caller's next wait. So the condition was false for
exactly the runs it was written for, the ones doing database work, and the
row took the failure path instead: `retry`, a store write on the same fiber,
which met the re-armed cancellation and failed too. The row stayed
`running`. Nothing reclaims a `running` row until its lease is over, and the
lease is the longest `timeout_ms` of any kind the program declares: one
application measured it at two hours for a ten-minute kind, during which the
work the row stood for was not done by anybody.

The worker loop's claim has the same shape. A claim the shutdown cut off
answered `QueryFailed`, and the loop logged `claim: QueryFailed` as an error
before its sleep collected the cancellation.

`Bound.fired` was also asked twice on a failure, once in the condition and
once for the error name, though its answer is consumed by the first ask.

## Decision

**After a run, the worker asks the fiber rather than the error.** A run that
failed without its own deadline firing, and either returned `error.Canceled`
or left a cancellation pending (`checkCancel`, then `recancel` so the loop
still leaves on it), was cut off by the server going: its row is released,
with the attempt given back, as ADR 160 says.

**Everything the worker then writes about the row is cleanup** and runs with
cancellation held off (`swapCancelProtection(.blocked)`), the way nilo_sql
holds off a `ROLLBACK`: `done`, `retry`, `dead` and `release` alike. A run
that finished one instruction before the shutdown is recorded `done` rather
than left `running`. The cancellation stays pending, and the loop leaves on
it at its next check.

**A claim that fails while the fiber is cancelled leaves the loop** without
logging a failure.

`Bound.fired` is asked once, after the run, and the answer is kept.

## Rejected

**Treat `QueryFailed` as a shutdown.** A statement fails for many reasons; a
real failure would be released forever instead of retried and, in the end,
declared dead. The fiber knows which it was; the error does not.

**Make nilo_sql return `error.Canceled`.** ADR 223 considered it and kept one
error word for callers; this module is one caller among them and adapts to
the rule rather than reopening it.

**A shorter lease, per kind.** It would bound the damage, not remove it: the
row would still be counted as a failed attempt and wait out its lease. The
lease is the answer for a process that *dies*; a process that is *told to
stop* can say so. A lease per kind is a separate question.

## Consequences

- A shutdown in the middle of a run that is waiting on the database hands its
  row back at once; the next process to start takes it, with its attempt
  count unchanged.
- A worker cut off in its claim leaves quietly.
- The store writes after a run can no longer be interrupted. When the
  database is the thing that is down they wait out the pool's own bounds
  before the process exits, as a `ROLLBACK` does under ADR 223.
- No new allocation, no new round trip: one `checkCancel` on a failed run.
- Held by `job/live.zig`: "on Postgres a run cut off by a shutdown in the
  middle of a statement goes back to the queue".
