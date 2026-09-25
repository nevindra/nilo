# A statement that is a constant can be prepared once

**Status:** accepted
**Topic:** [sql-runtime](../design/sql-runtime.md)

## Context

Every statement `nilo_sql` sends is settled while compiling ([ADR 036](./036-the-shape-of-a-query-is-settled-while-compiling.md)). That was decided for the compiler's sake, a query whose shape is known can be type-checked, and it hands over a second property nobody was asking for: the set of distinct statements a binary can ever send is fixed when the binary is built. That is exactly the precondition a per-connection prepared-statement cache wants, and exactly what a library assembling SQL per request cannot have.

## What was measured

`bench/sql.zig`, 20,000 rounds a side after 2,000 warm-up, one connection, Postgres 16 over a loopback socket:

| | parsed every time | prepared once | saved |
|---|---|---|---|
| a key lookup | 37,690 ns | 26,506 ns | 11,184 ns (29.7%) |
| a page with a sort | 94,539 ns | 81,210 ns | 13,329 ns (14.1%) |
| `db.find`, whole module | 37,788 ns | 26,432 ns | 11,356 ns (30.1%) |

The saving is a fixed cost, not a share, about 12 µs either way (Parse and Describe), which is why the cheap query saves 30% and the expensive one 14%. `db.find` costs about 100 ns more than the raw driver call it wraps, a quarter of one percent of a key lookup: the whole run-time price of the typed layer over this driver.

A server is not one connection sending one statement at a time, and the difference matters more there. `bench/sql_server.zig`, `PREPARED=0` against the same binary with it on, wrk, same box, across a Docker published port (the absolutes are a floor for that reason and the ratios are not affected; see [`bench/result/sql.md`](../../bench/result/sql.md)):

| | before | after | |
|---|---|---|---|
| one request at a time (c=1) | 14,876 req/s, p50 64.5 µs | 18,456 req/s, p50 52 µs | +24% |
| pool 8, c=32 | 89,293 req/s, p99 848 µs | 134,971 req/s, p99 564 µs | +51% |
| pool 32, c=64 | 105,667 req/s, p99 1.38 ms | 176,635 req/s, p99 0.99 ms | +67% |
| pool 64, c=64 | 112,030 req/s, p99 1.99 ms | 190,945 req/s, p99 1.88 ms | +70% |

A pool connection is a serial queue, so time not spent holding one is capacity: cutting 30% off how long a query holds its connection raises what that connection can push by about 43%, and Postgres spending less of itself on Parse gives back the rest. The caveat belongs next to the number: this benchmark's request *is* the query, and a service that does other work per request sees the same absolute 12 µs against a larger total.

## Decision

**On by default, keyed by a 128-bit hash of the statement text, for every statement this module builds and for `db.raw`.**

```zig
fn planOf(self: *Self, comptime stmt: statement.Statement) ?[]const u8 {
    if (!self.opts.prepared) return null;
    return comptime statement.planName(stmt.sql);
}
```

The name is a comptime constant, so the run-time cost of the whole feature is one load and one test per query.

### Why the name is the text, and why it is 128 bits

A cache hit re-binds against the stored describe without looking at the SQL again, so two statements sharing a name means one of them silently runs the other's plan. `bench/sql.zig` reused one `cache_name` for two statements while it was being written, and pg.zig answered `WrongNumberOfParameters`, comparing only the parameter count against the cached describe. Two statements with the same arity would have said nothing at all and returned the wrong rows.

```zig
const low = std.hash.Wyhash.hash(0, sql);
const high = std.hash.Wyhash.hash(0x9e3779b97f4a7c15, sql);
break :blk std.fmt.comptimePrint("nilo_{x:0>16}{x:0>16}", .{ low, high });
```

Two independent 64-bit hashes: at 128 bits a thousand distinct statements collide with probability around 10⁻³⁴, at 64 it would be 10⁻¹⁴, small in a different way than impossible. The result is 37 characters, comfortably inside Postgres's 63-byte identifier limit; over it the name is truncated, turning a unique name back into a colliding one, so the length is asserted rather than assumed. Hashing the text rather than the Row or the call site is the other half: the cache is keyed by what Postgres parsed, so anything else would be unique and still wrong.

### `db.raw` and `tx.raw` are prepared too, because their text is now comptime

`db.raw`'s `sql` parameter was runtime text when this feature shipped, so it was never given a plan name: no comptime name could be derived, and no bound existed on how many there would be. That premise turned out false for the traffic that actually exists: a caller with 398 named queries had 156 of them on `db.raw`, and every one, there and in this repository's own tests, live tests, benches and marked guide snippets, was a Zig string literal.

`db.raw` and `tx.raw` now take `comptime sql`. `rawPlanOf` sits beside `planOf` and honours `Opts.prepared` the same way, so the 12 µs to 70% this section measured now applies to a call site that used to pay Parse and Describe on every one of its 156 statements. `sql` arriving at run time, built from parts a request supplied, no longer compiles: there is no comptime name to derive for it, and there never will be, which is the property this whole design still rests on.

A comptime `sql` buys two more checks the run-time version could not have had. `sql/rawcheck.zig` walks the `SELECT` list at bracket depth zero, outside quotes and comments, and compares the count to the Row's field count; a mismatch is a compile error naming both. Each column that plainly has a name (an explicit `AS`, or a column that is an identifier path and nothing else) is checked against the field in its position, which is the half that matters most: a schema with 145 `uuid` columns and 106 `timestamptz` columns has two swapped columns of the same type decode cleanly and answer wrong, with no run-time symptom at all. What cannot be counted, a `*` in the list, or a statement with no `SELECT` and no `RETURNING`, answers "not counted" rather than guessing, and nothing is refused on its account; that width is what the run-time check in [ADR 106](./106-a-select-list-shorter-than-the-row-is-refused.md) still holds.

**It refuses rather than reorders.** The obvious move for a column found out of position is to bind by name: read the trailing alias, match it to the field, fill in whatever order the `SELECT` list happens to be in. Reordering silently repairs a statement that is wrong and the reader never learns their `SELECT` list and their struct disagree; refusing puts the disagreement in front of them, in the file they can fix, and costs no run-time machinery, no permutation array, no second index per column:

```
nilo: column 2 of the statement handed to `db.raw` is named `email`,
and field 2 of partner.Person is `age`.
  A raw statement fills the Row by position, so the second column becomes
  the second field. Reorder the SELECT list, or alias the column:
  … AS "age".
```

Types are not checked here: a comptime pass has no schema, so `SELECT id, email` into `struct { id: i64, email: Str }` is checked for shape and not for whether `email` is really `text`. That half belongs to `db.checking`, which asks the database.

**The break is deliberate and total.** A program that built SQL text at run time cannot call `db.raw` any more, and there is no second call with the old signature kept around: that would have left the unchecked path exactly where it was, under a name suggesting it is merely the one to reach for less often. What a caller who assembled text at run time does instead is assemble it at comptime, a `switch` over an enum of the orderings the application actually supports, a shape that also stops the injection nobody meant to allow.

### A plan a migration made stale is prepared again

A plan kept on a connection outlives the table it was prepared against. A
migration that changes a column's type under a running server leaves every
connection holding a plan Postgres now refuses with `0A000`, *cached plan
must not change result type*, and before this each of them failed the
statement that owned it on every use, until the pool happened to replace the
connection. That is the middle of every rolling deploy.

Outside a transaction nothing ran before the statement, so the Wire
deallocates the plan and sends the statement once more, and the caller sees
the rows. Once, and only on that refusal, read by its code and its message,
because `0A000` is *feature_not_supported* and most of it has nothing to do
with a plan. Inside a transaction the refusal has already aborted it, so the
answer is `error.RolledBack`, whose meaning is *run the transaction again*
([ADR 117](./117-a-statement-that-failed-says-what-the-database-said.md)),
and the plan is deallocated once the rollback lets the connection take a
statement. A connection that cannot deallocate it is dropped rather than
returned, because the next prepare under the same name would collide with it.
Nothing is paid on a statement that works: the check is on the failure path.

### Why there is an off switch

A connection pooler in transaction mode: pgbouncer hands out a different server connection per transaction, so a statement prepared on one is missing on the next. `Opts.prepared = false` is the escape hatch, and it exists because that deployment is common rather than exotic. The failure it avoids is loud, Postgres says the prepared statement does not exist, which is why the default is the fast one; a silent failure mode would have argued the other way. `db.raw` under `.prepared = false` is covered by the same option.

## What was rejected

**Never preparing `db.raw`, the module's original position.** Sound while its text arrived at run time, and wrong once measured against real call sites: `db.raw` was carrying a feature, run-time SQL, that essentially nobody used, and charging every literal call site the escape hatch's cost. The correction is `comptime sql`, above, not a second prepared/unprepared pair of calls: a caller who still assembles text at run time cannot call `db.raw` any more and has no replacement, the deliberate breaking half of that decision, kept here because it is this ADR's own position being reversed by evidence rather than by preference.

**Binding by name instead of by hash of the text**, or keying the cache by the Row or the call site. Any of those would let two different statements share a name, which is a wrong answer with no error, not a slow one.

**Reordering a raw statement's columns to match the Row rather than refusing the mismatch.** Silently repairs a statement that is wrong, and the reader never learns their `SELECT` list and their struct disagree.

## What it costs

Against [ADR 017](./017-the-trade-budget-has-four-axes.md)'s four axes:

| Axis | Cost |
|---|---|
| Allocations per request | None. The name is a comptime constant; the driver's cache is per connection and allocated when the connection is. |
| Memory per idle connection | Nothing on an HTTP connection. On a database connection, one entry per distinct statement that connection has sent, bounded by the program and paid by pg.zig. Measured at a pool of 64 with one statement in flight: 56 kB across the pool, 0.9 kB a connection. |
| Throughput and p99 | The axis this bought: −11.4 µs on a key lookup through `db.find` (30.1%), −13.3 µs on a page with a sort (14.1%) at the driver; +51% to +70% requests a second through a server, p50 down 33-45%. |
| Binary size | +0 stripped ReleaseFast on every example: the name is a string constant per distinct statement, and a program that sends none pays nothing. |

## Consequences

- `wire.run` and `wire.exec` take a `plan: ?[]const u8`. A second driver either honours it or ignores it; the Fake records it, which is how the tests hold the name without a database.
- The `db.find` row in the table above is the typed layer's run-time cost, and `bench/sql.zig` measures it every time it runs.
- A pooler in transaction mode is a documented configuration rather than a discovered one.
- `db.raw` and `tx.raw` taking `comptime sql` is a breaking change with no replacement for run-time text, in `CHANGELOG.md`. Turning the check on refused four of this repository's own call sites: a `db.raw` that selected one column into a four-field Row only to make an old call compile, now written out; two run-time tests written as a short literal list, now `SELECT *` against a Fake that still answers two columns for a four-field Row, since `*` is the shape the run-time width check exists for and the two checks do not overlap; and one test asserting the reverse of this ADR's own position, that `db.raw` sends no plan name, now asserting the name, with a second test beside it for `.prepared = false`.
- Two refusals, `raw_select_list_short` and `raw_column_in_another_fields_place`, with rows in `sql_refusals` in `build.zig`.
