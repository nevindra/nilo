# A statement cut off by a cancellation hands the cancellation back

**Status:** accepted
**Topic:** [sql-runtime](../design/sql-runtime.md)
**Extends:** [ADR 117](./117-a-statement-that-failed-says-what-the-database-said.md) (a cancellation is the one failure that is not logged as a refusal, and is handed on)
**Applies:** [ADR 028](./028-a-spawned-fiber-belongs-to-the-server.md) (a spawned fiber leaves on its cancellation), [ADR 107](./107-a-wait-for-a-connection-has-a-bound.md) (a wait for a connection is a cancellation point too)

## Context

A cancellation is reported once. Whichever cancellation point sees it returns
`error.Canceled` and the request is spent; `std.Io.recancel` exists for code
that turns it into some other result, so the next point reports it again.

nilo_sql turned it into another result and did not re-arm it. `translate`
sent `error.Canceled` down the branch for errors that never reached the
server — logged as "the driver refused a statement before it reached the
database (Canceled)" — and returned `QueryFailed`; the three `pool.acquire`
sites returned `Disconnected`. The caller had one error word, and nothing
left to see the cancellation with.

The fiber that pays for that is the one `docs/guide/background.md` shows:

```zig
while (true) {
    nilo.sleep(5_000) catch return;   // Canceled — the server is going
    work() catch |err| std.log.warn(...);
}
```

At shutdown the server cancels it once. If the cancellation lands in the
`sleep`, the loop returns. If it lands in a statement inside `work`, the
statement fails, the failure is logged, and every `sleep` after that
sleeps: the fiber runs on, and the process never exits. An engine with a
five-second tick of catalog reads measured it: SIGTERM while a tick statement
was on the wire hung the process 10 times in 10, after "nilo stopped", with
the tick still querying every five seconds.

Re-arming in `translate` was not enough on its own. After the statement,
nilo gives the connection back, and pg.zig's `release` dials a replacement
for one a cancelled statement left mid-conversation. That dial is a
cancellation point: it took the re-armed cancellation, logged "connect
error: Canceled", and swallowed it.

## Decision

nilo_sql hands a cancellation back. Where it turns `error.Canceled` into one
of its own errors (`translate`, a failed `pool.acquire`, and `drain`, which
throws away the rest of a result) it calls `recancel` first; and it gives
connections back with cancellation held off (`swapCancelProtection(.blocked)`
around `release`), because returning a connection is cleanup and must not
spend a cancellation meant for the caller. The `Io` it does both through is
the one `Wire.open` was handed, kept on the `Wire`, not read back out of
pg.zig's own fields.

The error the caller sees does not change: `QueryFailed` from a statement,
`Disconnected` from an acquire. `translate` no longer logs a cancellation as a
driver refusal, since nothing was refused.

**A rollback is cleanup too.** It runs with cancellation held off, and when a
cancellation is what ended the transaction it does not log a failure to roll
back: the statement the cancellation cut off left the connection mid-answer,
the `ROLLBACK` cannot be sent at all (`ConnectionBusy`), the connection is
dropped, and the server rolls the transaction back as it goes. Without a
cancellation behind it, a rollback that fails is still logged as it was.

**A `COMMIT` is held off too, for the opposite reason.** It is not cleanup,
it is the one statement whose outcome the caller has to know. Cut off after
it was written and before its answer was read, the transaction may have
committed on the server while the caller hears `QueryFailed`, and a handler
that retries on that writes the order twice. Held off, the `COMMIT` runs to
its answer, and a cancellation that arrived first or meanwhile is re-armed for
the caller's next cancellation point, the same hand-back as everywhere else.
The cost is the round trip the `COMMIT` was going to take anyway.

## What was rejected

**Letting a cancellation cut a `COMMIT` off like any other statement**, the
rule until 2026-09. It answered `QueryFailed` for a transaction that may have
landed, which is the one answer about a commit nobody can act on.

**Add `Canceled` to `wire.Error`.** It is the more honest word, and it breaks
every exhaustive switch over `wire.Error` in every caller for a case most of
them handle the same as `QueryFailed`. Re-arming gives the caller the
cancellation where it already looks for it — its next wait.

**Make the guide's loop check a stop flag.** `Ctx.stopping` exists for
handlers; a spawned fiber has none. A flag would fix the loops that remember
to read it, and every Service that swallows a cancellation would still break
the ones that do not.

**Leave `release` unprotected and re-arm after it.** It would need the
cancellation carried from `translate` past a `defer` in six places;
protecting the release is one function, and it is right on its own terms.

**Read the `Io` from pg.zig's connection and pool.** It worked, through
`conn._io` and `pool._io`, and an underscore field is the first thing to move
when the pin does.

## Consequences

- A background loop written as the guide shows exits at shutdown whichever
  call the cancellation lands in.
- A cancelled request's later statements fail at once rather than running: a
  handler that catches `QueryFailed` and tries a second statement gets
  `QueryFailed` again, which is what a request that went away should get.
- `release` cannot be interrupted, so a replacement dial after a cancelled
  statement runs to its own timeout. It ran before too, and only swallowed the
  cancellation on the way. **When the database is the thing that is down**,
  a shutdown that cut statements off waits out the connect timeout once for
  each such connection before the process exits. That is accepted: a process
  that exits late on an outage is better than one that never exits, and the
  bound is the pool's own connect timeout, not something new.
