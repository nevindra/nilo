# 0118 — a NULL is refused by both Wires, or it is a zero on one of them

**Status:** accepted

## Context

The two Wires disagreed about the same row.

pg.zig's safe row refuses a NULL read into a type that cannot hold one, and
`postgres.read` turns that into `QueryFailed`. `sqlite.read` tested for it
**inside the branch it takes for an optional field**:

```zig
if (optional and stmt.columnType(col) == .null) return null;
```

So a NULL arriving in a column the Row says is not optional fell straight
through to the reads below. `stmt.int` answers `0`. `stmt.text` answers the
empty string, because zqlite's `text` returns `""` whenever
`sqlite3_column_bytes` is zero, which is what a NULL gives it.

A wrong answer that looks like a right one — which is exactly what the same
function already refuses two lines further down, for an integer too wide for
its field, in a test that says so:

> a truncated id is a wrong answer that looks like a right one

The startup check catches the case where the table declares the column
nullable. It cannot catch a **view**, which answers `UNKNOWN` and is skipped by
design (ADR 0056), and it does not run at all for a `Db` nobody called
`checking` on — which is its own open entry, because forgetting it is silent.

## Decision

**The null test runs for every column, and a NULL in a field that cannot hold
one is `QueryFailed` on both Wires.**

```zig
if (stmt.columnType(col) == .null) {
    if (optional) return null;
    std.log.warn("nilo_sql: column {d} came back NULL and the Row reads it as {s}, …");
    return error.QueryFailed;
}
```

**`warn` rather than `err`**, and that is deliberate rather than timid: the
error is what the caller acts on, and `std.log.err` fails the test runner for
every test that provokes it — which is how a diagnostic ends up deleted rather
than fixed. `db.wireOf`'s warning is there for the same reason and says so.

The message names the column index and the Zig type, and it names the case the
startup check cannot see, because a reader who has a schema check running and
still got this needs to be told where to look.

## What was rejected

**Testing only when the value read back looks like a NULL sentinel** — zero for
an integer, empty for text — so the extra `columnType` call is paid only in the
rare case. It is free where it matters and it spreads one question over four
branches of a switch. The saving is a couple of loads.

**Leaving it to the schema check.** That is what was happening, and it has two
holes with names: a view, and a `Db` nobody called `checking` on.

**Matching Postgres's silence.** pg.zig's refusal arrives with no log line of
nilo's, and copying that here would be consistent and less useful: SQLite is
the Wire where the startup check is weakest, so this is where a reader most
needs to be told which column.

## What it costs

**One `sqlite3_column_type` per non-optional column per row** — a couple of
loads through the statement's memory, no allocation, no branch that the
optional path was not already taking. The optional columns were already paying
it.

Nothing on Postgres, which never ran this code.

## What holds it

`sql/sqlite.zig`'s NULL test now reads the same NULL three ways: as `?i64`
(null), as `i64` (`QueryFailed`), and the text column as both. It sits directly
beside the too-wide-integer refusal, which is the same class of failure
arriving from the other side.
