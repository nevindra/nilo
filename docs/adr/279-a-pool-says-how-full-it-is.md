# A pool says how full it is

**Status:** accepted
**Topic:** [sql-runtime](../design/sql-runtime.md)
**Applies:** [ADR 017](./017-the-trade-budget-has-four-axes.md),
[ADR 108](./108-a-statement-can-be-watched.md),
[ADR 115](./115-a-boot-dials-the-connection-its-work-needs.md).
**Found by:** the arena's `async-db` profile reading 57k and 66k requests a second at 830% and 755% of sixty-four CPUs where dusty on the same pg.zig reads 290k, and nothing in the framework able to say whether the pool was full, being filled, losing connections or waiting (`bench/result/sql.md`, section 29).

## Context

The numbers that decide whether a database-bound server is waiting on its pool are four: how many connections are open, how many are lent out, how many statements found none, and how many connections were thrown away. pg.zig's pool has all four (`Pool.stats()` and the `pg_pool_empty` and `pg_pool_dirty` counters) and `nilo_sql` showed none of them. The statement watcher (ADR 108) says how long a statement took from the call to the rows, which is the wait for a connection and the database's answer added together, and cannot split them. Little's law on the pool can: connections in use over statements a second is how long one is held. But the first number was not readable, so a run on a machine with sixty-four cores that came out five times slow could not say whether the pool had been filled by then (ADR 115 leaves the fill to pg.zig's reconnector, one dial at a time, behind the first request), whether it was at its size, or whether it was losing connections to cancelled statements.

## Decision

**`db.poolStats()` returns `?sql.PoolStats`**: `size`, `available`, `missing` and `in_use`, taken under the pool's lock and exact at that moment, and three process-wide counters from pg.zig, `waited` (one per look at an empty pool, so a waiter woken to find its connection taken counts again), `dropped` (connections replaced rather than taken back) and `statements`. Null before `listen()` has opened the pool and on a `Db` whose Wire has no pool of connections (SQLite).

**It costs nothing until it is called, and that is the rule it is held to.** Nothing is added to a statement's path: no clock read, no atomic, no field. The counters are the ones pg.zig already keeps. A call is one short hold of the pool's lock, one render of pg.zig's metrics text into 1,024 bytes of stack, and three reads out of it. A program that never calls it links none of it: the stripped `ReleaseFast` binary of the arena entry is 2,574,704 bytes with the change and without it (byte for byte identical). Allocations per request and memory per idle connection are unchanged, because nothing runs per request or per connection.

**A reading of how full the pool is says `in_use` and `missing` separately on purpose.** A pool dialling itself is `missing` falling and a pool at its size is `in_use` equal to `size`, and the two have different cures (`connect_on_init` raises the first, `size` the second), which is what the field is for.

## What was rejected

**Counting the wait and the hold in `nilo_sql`, per statement.** A clock read before and after the pool's `acquire` and `release`, and a histogram, would give the split directly. It puts two clock reads and two atomics on the path of every statement of every program, for the sake of a number that a program which wants it can already have as `in_use` over `statements` once a second, and the watcher gives the sum. The statement path is the one ADR 017's axes are about.

**Handing out the `pg.Pool`.** It would give the program every counter and every method pg.zig has, and make pg.zig's API nilo's, which a pin change can break (ADR 122 is the account of one). Five numbers are what the question needs.

**A once-a-second line from the framework itself.** A thread and a log line in every program with a database, to answer a question most programs never ask. The arena entry prints one (`bench/result/sql.md`, section 29) and costs what that section says.
