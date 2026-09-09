# A suite whose database is down is not a suite that failed

```
Build Summary: 7/9 steps succeeded (1 failed); 11/106 tests passed (95 skipped)
error: 'project.project_test.test.stopping requires a reason' logged 2 errors:
       [pg] (err): connect error: error.ConnectionRefused
       [default] (err): nilo could not open 2 of the 2 connections to "…"
```

No test failed. 95 skipped exactly as the caller's `pgtest.Db.start` means them
to, and the build still exited 1 behind 190 error log lines — because the Zig
test runner counts a logged `err` as a failed test, and `nilo_start` logged one
per test.

## The rule, which was already written here

`sqlite.zig` states it, and `db.wireOf` states it before that:

> `warn` rather than `err` … `std.log.err` fails the test runner for every test
> that provokes it, which is how a diagnostic ends up deleted rather than fixed.
> The error is what the caller acts on.

`nilo_start` is the one call in this module that both logs and returns. Both
lines in its `opened catch` — the URL one and the connect one — say something a
person needs and then hand the error back for the caller to act on. They are
diagnostics beside an answer, not the answer, so they are `warn` now.

## What stays at `err`, and why the line is there

The schema-mismatch pair does. A database that is not running is a fact about the
machine the suite is on; **a Row that disagrees with its table is a broken
program**, and a test runner going red for it is the correct answer rather than
noise. `checkSchema` lists each disagreement at `err` for the same reason, and
`db.zig`'s own tests say in a comment that this is why the SQLite rowid cases are
checked one layer down.

## Half of this was never nilo's, and that half is the useful one

The other error line in the report is `[pg]`'s. Lowering nilo's own leaves a
suite red anyway if nothing turns pg.zig's scope down.

What answers it is `std.testing.log_level`, a plain `pub var` the runner compares
against on every line. Where that was written down is the header of
`http/test_root.zig`, which is not a file a caller opens — and the same header
carries the finding that costs an afternoon first: **`std_options` in a tested
file is never consulted**, because the root of a test build is the compiler's own
`test_runner.zig`, which declares `std_options` itself.

So the fix here is a documentation one, and it is in
[`docs/reference.md`](../reference.md) next to `connect_on_init`, which is where
somebody setting a suite up against a real database is already reading.

## Against ADR 0018's four axes

Zero on all four. A log level is the same call either way, and neither line is on
the request path.

## Consequences

- A suite whose database is down now goes green, with two warnings per `Db`
  saying so.
- A `Db` that fails to start still returns its error, and `listen()` still
  refuses to come up. Nothing about the running server changed.
- The two sentences themselves are untouched — they were the right words, at the
  wrong level.
