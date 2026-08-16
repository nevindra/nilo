# The second Dialect is the test of the seam

`sql/dialect.zig` has said the same thing since it was written: *"What ships
is one Dialect. The point of the seam is that `$1` is not hardcoded, not that
a second one exists yet."* That is a reasonable thing to say and it is not
evidence. A seam nothing has ever been passed through is a guess about where
the joins go.

So the second Dialect was written — **the SQL half only, and deliberately.** A
Dialect is comptime and touches no I/O, which means it can be finished and
tested on its own, with no dependency, no database and no event loop. What it
buys is the answer to the question the roadmap has carried as Next 1: *does
the seam hold?*

## What was found

**Twelve of the thirteen declarations fitted with nothing changed outside the
Dialect.** The whole statement compiler — `select`, `insert`, `update`,
`delete`, conditions, orders, limits, casts, `RETURNING`, the schema check's
query — writes correct SQLite through it. Placeholders, identifier quoting,
schema qualification, `LIMIT`/`OFFSET` and the write forms all came out right
on the first compile.

Four things needed saying, and one needed the seam widened.

### 1. `ListForm` had three answers and SQLite needs a fourth

This is the one that did not fit. Postgres writes `.in` as `= ANY($1)`, which
keeps the statement a constant however long the list is. The enum offered
three answers and SQLite would have taken the third:

- `.any_array` — Postgres. Not available: SQLite has no array type.
- `.expanded` — `IN ($1, $2, …)`. Makes the text depend on a runtime length,
  which breaks [ADR 0039](./0039-the-shape-of-a-query-is-settled-while-compiling.md).
- `.unsupported` — `.in` becomes a Refusal.

So the seam's answer for SQLite was **refuse `IN`**, on a database where every
real schema uses it. That is the seam being in the right place and having the
wrong number of settings in it.

The fourth answer is SQLite's own idiom:

```sql
"id" IN (SELECT value FROM json_each(?1))
```

One parameter carrying a JSON array as text, constant statement, any length.
It costs a Wire one thing that is not free — the list has to arrive as JSON
text rather than as a native array — and that is written into the enum value's
own doc comment rather than left to be discovered.

### 2. A Postgres spelling had leaked into the walker

`where.zig`'s `listSpelling` answered `"= ANY"` and `"<> ALL"` — Postgres's
words, handed straight to the writer. It survived review because with one
Dialect there was nothing to disagree with it. It now answers *which operator*
and the dialect branch spells it, which is the same correction the seam
already made everywhere else and had missed here.

**A hardcoded string does not look hardcoded while there is only one of it.**

### 3. Casts had to be whole expressions, and nearly were not

Postgres writes a suffix, `"balance"::text`. SQLite writes a function,
`CAST("balance" AS TEXT)`. `readAs` and `bindAs` return the entire expression
rather than the cast to append, and that was already the shape — a seam that
had asked a Dialect for "the cast suffix" would have had to be rewritten here.
It is worth recording as a near miss rather than as a success, because nothing
had tested it.

### 4. `introspect` has one loose joint

SQLite reads a table's columns with `pragma_table_info`, and **the schema
qualifies the function's name rather than sitting in a `WHERE`** — so it
cannot be a bound parameter, where Postgres binds it. `columnsOf` hands a Wire
the query text *and* both values, so a SQLite Wire can put the schema in the
text itself. It works; the contract does not currently say it may. Written
down here rather than discovered by whoever writes that Wire.

## What SQLite gives up, stated rather than discovered

- **No row locks.** SQLite serialises writers over the whole database, so
  there is no row to hold. `.lock` is the Refusal `noRowLock` writes, naming
  the dialect.
- **No `insertMany`.** There is no `unnest` and no array parameter. The batch
  form SQLite does have is `VALUES (…), (…), (…)`, whose text grows with the
  batch — a statement that is no longer a constant, which is the rule this
  module is built on. A row at a time inside one transaction is the answer,
  and it is cheaper here than it sounds because there is no round trip to pay
  per statement.
- **A coarser schema check.** A SQLite column's declared type is free text;
  what the database enforces is one of five *affinities*. So `accepts`
  answers with affinity names, and the check catches a `Str` field over an
  `INTEGER` column and does not catch an `i32` field over a column holding
  values that do not fit. It declines a `u64` rather than accepting it
  optimistically, which is the safe direction to be coarse in.

## What was decided

**The Dialect ships. The Wire does not, and the reason is architectural
rather than effort.**

`DbOf(W, D, name)` takes the two halves separately for exactly this reason, so
a program with a SQLite Wire can use this today. Writing that Wire is where
the remaining work is, and it runs into something the Postgres Wire never
had to answer:

**SQLite is a blocking file read, not a socket.** pg.zig holds an
`Io.net.Stream` and reads through the `Io` it was handed, so a Postgres wait
suspends the fiber and frees the thread — which
[ADR 0059](./0059-a-round-trip-is-not-the-cost-worth-chasing.md) measured at
215,000 requests a second. A SQLite query has no descriptor to wait on. Every
call would either hold its thread for the duration or go through
`nilo.blocking` and pay a thread-pool hop, and which of those is right depends
on numbers nobody has: a local read is microseconds, a write behind a
contended database lock is not.

That is a design question with a measurement in front of it, which is the
shape of work this project does in its own ADR rather than at the bottom of
somebody else's. Adding a C dependency is the smaller half.

## What it costs

Against [ADR 0018](./0018-the-trade-budget-has-three-axes.md)'s four axes:

- **Allocations per request.** None. A Dialect is comptime.
- **Memory per idle connection.** Nothing.
- **Throughput and p99.** Nothing. `listSpelling` returning an enum instead of
  a string moves a comparison from run time to — still comptime, where it
  always was.
- **Binary size.** +0 stripped ReleaseFast on every example. A Dialect nothing
  instantiates is code the compiler never analyses.

## Consequences

- The claim "the seam is in the right place" is now one widening and three
  notes rather than an assertion. `ListForm` has four values; the fourth has
  a user.
- **`sql/dialect.zig`'s header sentence is no longer true and has been
  changed.** Two Dialects ship; one of them has a Wire.
- A second driver is now exactly one thing — a Wire — and the question in
  front of it is written down.
- The Postgres Dialect gained a second reader, which is the cheapest kind of
  review there is: every one of the four findings above is a thing that was
  read past for a year.
