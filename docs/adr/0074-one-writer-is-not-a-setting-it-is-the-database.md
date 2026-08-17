# One writer is not a setting, it is the database

[ADR 0073](./0073-a-file-has-no-socket-to-wait-on.md) settled how a SQLite
statement reaches a thread and whose C brings SQLite in. What is left is
everything that follows from SQLite not being a server: a pool whose shape is
not a preference, a `db.raw` whose destination cannot be worked out while
compiling, a durability default that decides what a benchmark means, and a test
story with a trap in it that does not announce itself.

Postgres answers all four the same way — it is a server, it holds the rules,
and the pool is a set of interchangeable connections to it. None of that
survives the move to a file.

## The pool is one writer and several read-only readers

SQLite serialises writers over the whole database. In WAL mode readers do not
block behind the writer, which is why WAL is what almost every deployment runs;
what WAL does not do is make two writers possible.

A homogeneous pool — the shape pg.zig has and the shape `zqlite.Pool` has —
therefore **lies about the database**. Two connections both able to write means
two statements racing for the same lock, and the loser surfaces `SQLITE_BUSY`.
`wire.zig` is explicit about what `Locked` means:

> No default status. A row somebody else is holding is a 409 for one endpoint,
> a 503 for another, and a retry with `.update_skip_locked` for a third. It is
> the answer the caller asked the question to get.

An error that arrives because two of *our own* pool connections collided is not
an answer to anything the caller asked. So:

- **One writer connection.** Every `insert`, `update`, `delete`, every `Tx`,
  and every `db.rawWrite`.
- **N reader connections, opened with `OpenFlags.ReadOnly`.** Every `select`,
  and `db.raw`.
- **`busyTimeout` on all of them**, and its expiry is what becomes `Locked`.
  With one writer this should be reachable only from outside the process —
  another program, or a second instance on the same file — which is exactly the
  case worth reporting rather than hiding.

`zqlite.Pool` is not used, and that is not a criticism of it: it is a
thread-safe pool of equal connections, which is the right shape for the library
and the wrong one for this contract.

### Which connection a statement takes is known while compiling, except once

Every ordinary statement is a comptime constant
([ADR 0039](./0039-the-shape-of-a-query-is-settled-while-compiling.md)), so
`SELECT` versus `INSERT` is settled before the program runs and routing costs
nothing.

`db.raw` is the exception by construction: its text arrives at run time, so
nothing in the process knows whether it reads or writes. Three answers, and the
one chosen hands the question to something that cannot get it wrong.

- **Send every `raw` to the writer.** Safe, and it makes the slowest statements
  in the system queue behind the one connection that must never be held: a ten
  second report on the writer stops every write for ten seconds.
- **Read the first keyword.** Wrong on `WITH … INSERT`, and wrong quietly.
- **Send it to a reader, and let SQLite refuse.** The reader connections are
  open read-only, so a `raw` that writes fails with SQLite's own error, on the
  first call, naming the dialect. **This is the decision.**

The cost is honest and worth stating: a `raw` that writes compiles on both
dialects and fails at run time on this one. That is a failure this repository
normally refuses to accept. It is accepted here because the two alternatives
fail in the direction nobody notices — one makes the server slow for reasons
invisible at the call site, the other returns wrong answers for statements it
misread — and a loud failure on the first call is cheaper than either. A caller
who means it says `db.rawWrite`.

### `tx.raw` is not this rule, and the distinction is load-bearing

A `Tx` holds one connection for its whole life, which is what a transaction is
(`wire.zig`). `tx.raw` (`sql/db.zig:1070`) therefore goes down the
transaction's connection — the writer — and always did.

If `raw` inside a transaction went to a reader instead, it would read a
connection that **cannot see the transaction's uncommitted writes**: a
plausible answer, no error, no log line. The existing API already prevents it
by having two functions rather than one, so nothing needs building. It is
written down here because that safety is a property of the API's shape rather
than of anybody's intent, and the next person to touch this path would
reasonably think of merging them.

## Durability: WAL and `synchronous = NORMAL`

`PRAGMA synchronous = FULL` makes SQLite wait for the disk to confirm before
reporting success. `bench/result/sql.md` §8 already priced that on this
machine: one autocommitted INSERT is **660 µs, and every library measures the
same**, because what is being timed is an fsync.

`NORMAL` under WAL is the setting SQLite itself recommends for application use.
The database cannot corrupt; what can be lost is the most recent transactions
if the machine loses power, and only then. `OFF` — where corruption is possible
— is not offered at all.

**This is the one decision here that chooses somebody else's data-loss risk for
them**, which is why `FULL` is one field away and documented next to the
default rather than buried. The reason a default exists at all is that without
one, every deployment runs at 660 µs a write and concludes the module is slow.

### It makes a benchmark comparison unfair unless the benchmark says so

SQLite in the `nilo_sql` benchmark suite will sit beside a Postgres configured
for full durability. At `NORMAL` it will win the write shapes decisively, and
**the margin will be a difference in promises rather than in speed**.

That is the mistake `bench/result/s3.md` caught this month in another costume:
a control that produced the same bytes while doing less work, believed because
it was plausible and killed by one number being large in the wrong place. So
the SQLite arm carries one of two things and neither is optional:

- both sides configured to the same durability, or
- **SQLite measured at both settings**, with the difference stated above the
  table rather than in a footnote.

The batch shape needs the same treatment for a different reason. ADR 0061
already refused `insertMany` on SQLite — there is no `unnest` and no array
parameter, and `VALUES (…), (…), (…)` makes the statement text grow with the
batch, which is the rule the module is built on. So SQLite's batch column is a
row at a time inside one transaction: a **different shape**, not a slower one,
and it is written into the table rather than left blank. Silent truncation
reads as coverage.

## Tests: the in-memory database has a trap, and it is quiet

The best thing about SQLite for a test suite is that it needs no Docker. Two
facts spoil the obvious version of that, and both fail without saying anything.

**`:memory:` is private per connection.** A pool of one writer and N readers
opened on `:memory:` is N+1 separate empty databases. Writes go to one and
reads find nothing, which looks exactly like a bug in the code under test. So
`:memory:` is **refused, with a message that names the shared form** — the most
famous string in SQLite deserves a sentence, not silent data loss.

**It is refused at `open`, not while compiling**, and the first draft of this
ADR said Refusal without noticing why it could not be one: a database URL is a
run-time value. It arrives from `nilo_config`, from an environment variable, or
from a command line, so no comptime check can see it. This is the same
correction as the reader count two sections down and it has the same shape —
*the compiler can only refuse what the compiler can see* — which is worth
stating once rather than twice, because it is the boundary that decides which
of this module's guarantees are Refusals and which are startup checks.

**A shared in-memory database cannot use WAL.** WAL needs a shared-memory file
beside the database and an in-memory database has nowhere to put one;
`PRAGMA journal_mode = WAL` returns `memory` rather than failing. A suite that
runs entirely in memory therefore exercises a *different journal mode from
production*, which means the reader/writer split, `busy_timeout` and everything
`Locked` depends on are never tested at all.

**And the read-only flag does not survive `mode=memory`.** This one was found
by a test failing, which is the only way it was ever going to be: SQLite's URI
`mode=` parameter takes precedence over the flags handed to
`sqlite3_open_v2`, so a connection opened with `OpenFlags.ReadOnly` against
`file:x?mode=memory&cache=shared` **writes**. On a file the same flag refuses
with `error.ReadOnly`; check 6b and check 6c of the spike are the pair.

That is not a curiosity, it is the backstop this ADR leans on two sections up.
Routing `db.raw` by its first keyword is a guess, and the argument for
tolerating a guess is that a wrong one lands on a connection SQLite will not
let write. **In memory there is no such connection.** So the split below is a
correctness requirement rather than a coverage preference, and the test that
holds the backstop opens a file — where it now also asserts `journal_mode`
comes back `wal`, because the two things a file is needed for are the same
file.

So the suite is split, and the split is the rule rather than a preference:

- **Tests about statements** — does this Row read, does this condition compile
  to that SQL — run on the shared in-memory database. That is most of them.
- **Tests about locking, WAL, the pool and `Locked`** run against a file in a
  temporary directory. Nothing else can test them.

One operational consequence goes with the first: a shared in-memory database
is destroyed when its **last** connection closes, so the pool opens the writer
first and holds it for the pool's life. A pool that closed and reopened
connections opportunistically would drop the database underneath itself.

**Both SQLite behaviours above have now been run**, against zqlite 0.0.1 and
SQLite 3.53.0 — the library this module ships with rather than SQLite in the
abstract, because the flags a wrapper passes to `sqlite3_open_v2` decide
several of them. [`spike/sqlite_facts`](../../spike/sqlite_facts/) is the
program and its README is the result: both held, along with four other claims
this ADR makes.

Check 3 is worth one more sentence, because of *how* it passes: asking an
in-memory database for WAL returns `memory` rather than failing. The suite
would have run in the wrong journal mode and nothing anywhere would have said
so — which is the argument for the split above rather than a footnote to it.

One expectation in that run was wrong and it was this document's: the error a
read-only connection raises is `ReadOnly`, not `ReadOnlyDirectory`. That name
is what the Wire maps, so guessing it would have turned the deliberate refusal
two sections up into a `QueryFailed` with the reason thrown away.

## Reader count is checked at `listen()`, not while compiling

Under ADR 0073's `.hop`, every SQLite call runs on an Engine thread-pool worker.
A reader connection beyond the number of workers can never be busy: it holds
memory and waits.

**That memory was overstated in the first draft of this ADR, and the correction
is worth more than the original claim.** It said a connection holds "roughly
2 MB of page cache … for the life of the pool". 2 MB is `cache_size`'s default
(`-2000`, meaning 2,000 KiB) and it is a **ceiling**: SQLite grows the cache as
pages are touched and never past it. [`spike/sqlite_facts`](../../spike/sqlite_facts/)
measured what is actually held, one writer and eight readers over a 2.9 MB
table:

| | total | per connection |
|---|---|---|
| opened, idle | 252 KiB | **28 KiB** |
| after every reader has scanned the whole table | 16,892 KiB | **1,876 KiB** |

Both are real, and they are two different deployments rather than a range to
split. A service doing primary-key lookups — the shape
[`bench/result/sql.md`](../../bench/result/sql.md) measures — stays near the
first row. One running reports over a table larger than the cache converges on
the second. Each connection also keeps its own copies of the statements
[ADR 0057](./0057-a-statement-that-is-a-constant-can-be-prepared-once.md) says
to keep prepared, which is on top of both figures and unmeasured.

The same spike asked what the ceiling buys, in `pread64` calls rather than in
time, because reads are a counter and the box it ran on cannot be trusted for a
timing. **Nothing, at either shape.** Five thousand primary-key lookups over a
hot set of 200 rows issue **10 reads at −2000 KiB and 10 at −32 KiB**; three
full scans of a table larger than every cache tried issue 2,261 and 2,265. The
point-lookup case falls off a cliff between −32 and −8 KiB — 15,005 reads —
which is the working set no longer fitting, and that cliff sits wherever the
working set sits rather than at a number this repository can publish.

So the ceiling is a field with SQLite's default kept, and the guide says what
the two rows above say: the number a deployment pays is its working set, and
lowering the ceiling is close to free for a service that scans.

The obvious form for the guard is a Refusal, and **it cannot be one**: the
worker count is a run-time value, usually derived from the machine's CPU count,
and the reader count comes from configuration. Nothing in the compiler can see
both. So it is a startup check in the same place the service registry is
checked — at `listen()`, once, loudly, before the socket opens.

The reader default is the worker count.

## `tx.deadline` is refused, and the dialect is named

[ADR 0047](./0047-a-deadline-needs-a-connection-you-hold.md) put `deadline` on
the `Tx` because a deadline has to be set on the connection the statement will
travel down. On Postgres that is a message to a server. SQLite has no server:
the only mechanism is `sqlite3_interrupt`, called **from another thread** while
the statement runs.

ADR 0073 establishes that the call is reachable — zqlite exposes
`conn: *c.sqlite3` — so this is a refusal on merit rather than on access.

- It needs a timer and a cross-thread poke, which is machinery this module does
  not have and which has failure modes of its own.
- `sqlite3_interrupt` is **connection-wide**, not statement-wide. It aborts
  whatever that connection is running. Under `.hop` the fiber that set the
  deadline is parked inside `blockInPlace` and cannot be woken to fire it
  anyway, so the timer would have to live somewhere else entirely.
- `busy_timeout` already covers the case that actually happens — waiting on a
  lock that is not being released — and it is per connection and already set.

So `tx.deadline` is a Refusal naming the dialect, in the shape ADR 0061 chose
for `.lock`: `noRowLock` refuses rather than emitting something that means
something else.

The cost is real and worth naming: `tx.deadline` was published as a promise of
the module, and it is now a promise one dialect keeps. A deadline that
sometimes aborts a neighbouring statement would be worse than one that says
plainly it is not available here.

## What it costs

Against [ADR 0018](./0018-the-trade-budget-has-three-axes.md)'s four axes, and
the honest summary is that this ADR spends **memory** and nothing else — but it
spends it in a place nilo has never spent it before, which is per *pool
connection* rather than per HTTP connection.

| axis | what it costs | |
|---|---|---|
| **Allocations per request** | **0** | routing is a comptime branch; the pool is built at `listen()`. |
| **Memory per idle connection** | **0 B on an HTTP connection** | a pool connection is not a request's. What is new is a per-*pool*-connection cost: **28 KiB opened and idle, growing to 1,876 KiB** once a connection has touched `cache_size` worth of pages, times the reader count ([`spike/sqlite_facts`](../../spike/sqlite_facts/)). Prepared statements are on top of both and are still unmeasured. |
| **Throughput and p99** | **not taken** | and the durability setting has to be stated with any figure, or the figure is about fsync. |
| **Binary size** | **counted in [ADR 0073](./0073-a-file-has-no-socket-to-wait-on.md)** | nothing here links anything 0073 does not. |

## Consequences

- **The pool is nilo's, not zqlite's.** One writer, N read-only readers, WAL,
  `busy_timeout`, opened writer-first and held.
- **`db.rawWrite` is new API.** `db.raw` goes to a reader, `db.rawWrite` to the
  writer, and `tx.raw` keeps going where it always went. On the Postgres Wire
  all three take a pooled connection as before, so the name is available on
  both dialects and means something on one — which is the same trade `.lock`
  makes in the other direction.
- **One Refusal and two startup checks**, and which is which follows from what
  the compiler can see. `tx.deadline` and a weaker isolation level are
  Refusals, because both are written in the source: they are rows in
  `sql_refusals` in `build.zig`, and adding a row to one table while running
  another is a check that silently never ran — there are five tables now.
  `:memory:` and the reader count are checked at `open`, because a URL and a
  worker count both arrive at run time.
- **The suite gains a temporary-directory arm.** Tests about locking cannot run
  in memory, and a suite that ran entirely in memory would report a WAL
  configuration it never used.
- **`bench-sql` gains a SQLite arm with a stated durability setting**, and its
  batch column carries a different shape rather than a blank.
