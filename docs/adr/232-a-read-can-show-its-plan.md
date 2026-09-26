# A read can show its plan

**Status:** accepted
**Topic:** [sql-runtime](../design/sql-runtime.md)
**Extends:** [ADR 108](108-a-statement-can-be-watched.md)

`db.watching` answers *which statement is slow* and, with the route on the
`Sent`, *on which page* ([ADR 108](108-a-statement-can-be-watched.md)). The
next question is *why*, and that is the plan. For a statement nilo wrote there
was no way to ask it: a typed or shaped read's text exists only while it runs,
its values are withheld from the watcher on purpose, and so an `EXPLAIN` of a
slow `db.page` over a Row with three parents meant rebuilding its text by hand
and guessing its values. nodeflux-os asked for it as item 93.

## Decision

**`db.explain(Row, c, options)` takes what `db.select` takes and answers the
plan of the statement `db.select` would send, with the same values bound**, as
text, one line of the plan per line.

```zig
const plan = try db.explain(DealCard, c, .{
    .where = .{ .stage = .won },
    .order = .{ .id = .desc },
    .limit = 20,
});
try testing.expect(std.mem.indexOf(u8, plan, "Seq Scan on deals") == null);
```

**Each Dialect says what it puts in front** (`explain`) **and how many columns a
line of the answer has** (`explain_width`, the plan's text last):

| Dialect | prefix | runs the read |
|---|---|---|
| Postgres | `EXPLAIN (ANALYZE, BUFFERS) ` | yes: what it did, with timings and how much came off the disk |
| SQLite | `EXPLAIN QUERY PLAN ` | no: SQLite has no `ANALYZE` form that reports timings |

The text is the statement `textOf` produces, so a request-chosen `ORDER BY`
is spliced in exactly as the read would have it. It is sent unprepared, since
it is asked once, and it goes through `filling`, so a watcher is told about it
like any other statement. A `.lock` is refused, as it is on `db.select`
without a transaction. A shaped Row's children are a second statement and are
not in the plan; the plan is of the statement that reads the parents.

**The test-side assertion the port asked for is a string search in the test**,
against seeded data. A missing index then fails the suite rather than a page.

## What it costs

| Axis | Cost |
|---|---|
| Allocations per request | none on any path that does not call it. A call allocates the prefixed text, the lines and the joined answer, in the Scope's arena. |
| Memory per idle connection | zero. |
| Throughput and p99 | none on any other statement. On Postgres a call runs the read, so it costs what the read costs plus the instrumentation `ANALYZE` adds. |
| Binary size | the linker drops it from a program that never calls it; a call costs one more instantiation of the row reader. |

## What was rejected

**An assertion API, `expectNoSeqScan(Row, options, "deals")`.** The plan's
text differs between the two databases and between versions of one, so the
matching rule would be a promise nilo could not keep; a string search written
in the test says what it looks for, and fails where the reader can see why.

**Debug only, by a compile error in the release modes.** ReleaseSafe is where
this repository's suite runs as the gate, and a test that asserts on a plan is
a test there too. The name says what it does, and it is a call nobody makes by
accident.

**The plan on the watcher**, an `auto_explain` inside this module. It would run
every slow statement twice, the second time after the moment it was slow in,
and hand the watcher the values' effects it was built not to see. Postgres's
`auto_explain` does this from the server's side for an operator who wants it.

**`EXPLAIN` without `ANALYZE` on Postgres**, which plans and does not run. It is
safer for a write and this is a read; the question a slow page asks is what the
database did, and an estimate is what a missing statistic makes wrong.

## What is still open

**A children statement cannot be explained.** It is the second statement of a
shaped read and takes the parents' keys; asking for its plan means reading the
parents first, which a call that answers text has no room to say. It waits for
somebody whose slow page is the children.
