# A file has no socket to wait on

[ADR 0061](./0061-the-second-dialect-is-the-test-of-the-seam.md) wrote the
SQLite Dialect, found the seam held, and stopped at the half that speaks to the
database. It named the reason and left it standing:

> **SQLite is a blocking file read, not a socket.** A Postgres wait suspends
> the fiber and frees the thread, which is what buys 215,000 requests a second
> ([ADR 0059](./0059-a-round-trip-is-not-the-cost-worth-chasing.md)); a SQLite
> call has no descriptor to wait on, so it either holds its thread or pays a
> `nilo.blocking` hop, and which is right depends on numbers nobody has.

That sentence is still true and it is not the whole problem. Two facts found
while designing the Wire make the question harder than "which of the two", and
one of them closes a door the sentence assumed was open.

## `nilo.blocking` is not reachable from here

`blocking` is `zio.blockInPlace`, and it lives in `http/bulkhead.zig:1014`. It
is `nilo_http`. `sql/` may not name `nilo_http` outside a `test` block, and
that is not a convention — `zig build layering` reads the `layers` table in
`build.zig` and fails the build ([ADR 0042](./0042-the-bottom-layer-holds-more-than-one-module.md)).

The obvious escape hatch is `std.Io`, which a Service is handed by
`ready(state, io)` and which is how `nilo_sql` already dials out
([ADR 0040](./0040-a-service-that-needs-the-loop-is-finished-when-the-loop-exists.md)).
`std.Io.concurrent` promises to run a function "such that the caller can
progress while waiting", which reads like the door.

**It is not.** zio implements that slot as `spawnTask` (`zio/src/io.zig:290`):
it starts a *fiber*, not a thread-pool job. A `sqlite3_step` inside one holds
an executor thread exactly as it would have held the caller's — the same cost,
relocated. Reading the vtable is what settled this, and it is written here
because the name says otherwise.

So the module that has to decide how SQLite reaches a thread **cannot reach the
mechanism that does it**. That is the decision this ADR is mostly about; which
default to run is the smaller half.

## The mechanism is a field, and leaving it out does not compile

A SQLite Wire is built with a threading choice it cannot supply itself:

```zig
// in the caller's own program, where both names are already in scope
const Wire = sqlite.Wire(.{ .threading = .{ .hop = nilo.blocking } });
// or, deliberately:
const Wire = sqlite.Wire(.{ .threading = .in_fiber });
```

`sql/` names nobody. The function pointer arrives from the program that already
imports `nilo_http` and `nilo_sql` and wires them together — the same shape by
which a `Db` becomes a Service today, and the same shape by which `nilo_sql`
and `nilo_http` have never named each other.

**The field has no default.** Omitting it is a Refusal with a message naming
both values and what each costs, because the two differ in *when the server
stops working* rather than in speed, and a silent default there is the kind of
choice that is discovered in production.

### What runs when the caller says `.hop`, and why that is the recommendation

Every statement goes to the Engine's thread pool; the fiber parks; the executor
thread serves other connections. It is slower than `.in_fiber` for the common
case and it has no case where the server stalls.

`.in_fiber` is the faster answer for a read served from SQLite's page cache — a
hop costs a few microseconds and so does the read, so hopping can cost more
than the work. It is the wrong answer for a read that misses the cache, a slow
disk, or a `db.raw` doing something large: those hold an executor thread for
their whole duration, and on a two-core box that is half the server.

**The recommendation is `.hop`, and it is explicitly provisional.** There is no
measurement behind the claim that `.in_fiber` wins on cached reads, and this
repository's rule is that a number with no run behind it decays into a claim
that gets planned against. What the field buys is that the measurement can be
taken later and change the advice without changing a line of the Wire.

The first run to take is in
[`bench/result/sql.md`](../../bench/result/sql.md)'s shape: the same statement
under both settings, unloaded and behind the pool, because a per-operation
saving measured only unloaded understated its worth at a pool by two to three
times once already.

## SQLite gets a Gate of its own

The thread pool is one pool, and password hashing is already on it behind
`bulkhead.Gate` — put there because
[ADR 0048](./0048-a-password-hash-is-gated-because-forgetting-is-silent.md)
found that forgetting to bound it is silent. Nothing else bounds anything on
that pool.

Under `.hop`, a burst of SQLite queries takes every worker and logins queue
behind them; a burst of logins does the reverse. Both look like "the server got
slow" and neither leaves a trace.

So the SQLite Wire holds a Gate sized to its reader count. That also answers a
question the roadmap has carried since `nilo_pw` shipped — *whether the Gate
belongs to more than passwords* — with the second caller it was waiting for
rather than with an opinion.

## Whose C

SQLite is a C library and nilo is Zig, so something has to bring it. Four ways,
and two of them were ruled out by reading rather than by taste.

**[vrischmann/zig-sqlite](https://github.com/vrischmann/zig-sqlite) is out on
the first line.** It tracks Zig master with a branch for 0.15.1, and nilo
supports the latest stable release only, on one branch — a library following
master cannot be pinned to what nilo pins to. Its maintainer states they are on
a break from Zig work with no new features planned, which makes the version
problem a standing one rather than a moment. Its comptime-checked bind
parameters are the one thing it offers that nilo would want, and `statement.zig`
already does that job better: every statement here is a comptime constant.

**[karlseguin/zqlite.zig](https://github.com/karlseguin/zqlite.zig) is the
choice.** Three files, 47 KB of Zig, and every property this Wire needs:

- **Zig 0.16.0**, which is what nilo pins.
- **Zero dependencies of its own**, against pg.zig's four. It bundles and
  statically links the SQLite amalgamation (3.53.0), with `system_sqlite3 =
  true` for a deployment that would rather link the system's.
- **`conn: *c.sqlite3` is a public field and `pub const c` re-exports the C
  API.** So the calls it does not wrap are still ours — `sqlite3_interrupt`
  among them, which is why
  [ADR 0074](./0074-one-writer-is-not-a-setting-it-is-the-database.md) can
  refuse `tx.deadline` on its own merits rather than because the door was shut.
- **`Stmt` exposes `*c.sqlite3_stmt` with `reset`, `clearBindings` and
  `bind`.** That is what
  [ADR 0057](./0057-a-statement-that-is-a-constant-can-be-prepared-once.md)'s
  `plan` needs to mean anything here: a statement kept prepared on the
  connection it went down.
- **`OpenFlags.ReadOnly` and `busyTimeout(ms)`** — the two mechanisms ADR 0074
  is built on.
- **A row's text points into SQLite's own buffer and is valid only until the
  next step.** That is `wire.zig`'s rule verbatim, which it inherited from
  pg.zig and passes along unwrapped on purpose. The two Wires agree about the
  one lifetime rule that matters, so nothing has to be adapted at the seam.

Its own `Pool` is not used. It is homogeneous and ADR 0074 needs one writer and
several read-only readers, which is a property of SQLite rather than a tuning
preference.

**Vendoring the amalgamation was rejected**: ~9 MB in the repository, and it
makes this project the party that has to notice a SQLite security release.
**Linking the system library was rejected** for the reason
[ADR 0028](./0028-tls-is-terminated-in-front.md) rejected a TLS dependency — an
OS package in the install story, for people whose whole first experience is
`zig build`. `system_sqlite3` keeps that available to anybody who wants it
without putting it in the path everybody walks.

### The maintenance argument, and why the seam already answered it

zqlite is version 0.0.1 with one maintainer, which is the objection to make.
Its commits at the time of writing are 6–11 August 2026, including a fix for a
Zig 0.17 change — so it is being kept up rather than parked, which is precisely
where zig-sqlite differs.

Past that, `wire.zig`'s own header answered this before SQLite existed as a
question, about pg.zig:

> pg.zig is a fork maintained by the same person as zio, which is already the
> project's first standing risk. If it stops, one file is rewritten rather than
> every call site.

Refusing zqlite on one-maintainer grounds is refusing the reason the Wire seam
was cut. And the surface used from it is thin — `open`, `prepare`, `Stmt`, and
the raw handles — so "one file is rewritten" is a description rather than a
hope.

## Why not the alternatives

**Give the Wire its own thread pool.** Self-contained, names nobody, and it
would work: `std.Io`'s vtable has futex wait and wake, so a worker could signal
completion and the fiber could park on it. It is rejected because it puts a
second pool of threads in a process whose selling point is that you can put a
number on it, sized by nobody and visible to no operator. Two pools competing
for the same cores is a worse failure than the boilerplate it saves.

**Never hop — hold the thread, and let the watchdog notice.**
[ADR 0034](./0034-the-thing-a-handler-holds-is-watched-at-run-time.md) already
watches a handler that holds its thread, so the machinery exists. Rejected as a
*decision*: it contradicts
[ADR 0014](./0014-handlers-must-not-block-the-thread.md) with no number behind
it, and a watchdog reports a stall rather than preventing one. It survives as
`.in_fiber`, chosen deliberately by a caller who knows their database fits in
cache.

**Let `sql/` name zio.** One line, and it ends the seam
[ADR 0002](./0002-zio-as-the-engine-behind-the-bulkhead.md) exists to hold.
Exactly one file in this repository names zio; a second one makes the Bulkhead
a comment.

## What it costs

Against [ADR 0018](./0018-the-trade-budget-has-three-axes.md)'s four axes.
**A program that does not import `nilo_sql` pays nothing on any of them.**
For one that does, three of the four numbers do not exist yet, and saying so is
the point rather than an omission.

| axis | what it costs | |
|---|---|---|
| **Allocations per request** | **unchanged** | the Wire allocates where the Postgres one does — into the request arena, when a value does not fit the driver's own buffer. The threading choice adds none: a hop moves a call, not memory. To be held by the existing budget test rather than a new one. |
| **Memory per idle connection** | **0 B expected, unmeasured** | a SQLite connection is held by the pool, not by a request, so an idle HTTP connection should be untouched. Under `.hop` a parked fiber's stack high-water mark is what a handler adds ([ADR 0063](./0063-a-handlers-stack-is-per-connection.md)), and the pool's own per-connection cost is ADR 0074's number. |
| **Throughput and p99** | **not taken** | the run that matters is `.hop` against `.in_fiber`, unloaded and at the pool, and it is the run this ADR defers rather than guesses. |
| **Binary size** | **+524,840 B to a program that uses it, 0 B to one that does not** | `zig build size-sql -Doptimize=ReleaseFast` builds two programs that differ by one line — which database the one route reads. Stripped `ReleaseFast`: 1,677,464 B naming `sql.Db`, 2,202,304 B naming `sql.Sqlite`. |

**The zero is the number worth having, and it was a claim until it was
checked.** Both drivers live in one module, so a program naming `nilo_sql`
fetches pg.zig with its four dependencies *and* zqlite with its amalgamation
whichever it uses, and the module links libc either way. What that must not
cost is the C: `sql/sqlite.zig` is only analysed when something names it, so
the linker should drop the lot. It does —

```
$ strings zig-out/bin/nilo-size-pg_only    | grep -ci sqlite
0
$ strings zig-out/bin/nilo-size-sqlite_only | grep -ci sqlite
71
```

— and that is a fact about this linker on this target rather than a guarantee
of the language, which is why it is a build step and two greppable binaries
rather than a sentence.

What is still unmeasured is the part that is not the binary: **download size
and build seconds**, both of which every `nilo_sql` user now pays for a driver
half of them will not use. The amalgamation is the slow half — a cold
`zig build test-sql` spent about a minute of CPU inside `zig clang` on it. The
alternative is a build option a `zig fetch` dependent has to thread through,
which is the ergonomic problem
[ADR 0017](./0017-the-api-description-comes-from-the-signatures.md) declined to
take on for `docs()`; the trade is worth revisiting when somebody has both
numbers rather than one impression.

## Consequences

- **`sql/sqlite.zig` is the second Wire**, in the same module as the first.
  A separate `nilo_sqlite` was not an option: it would be a Service beside
  `nilo_sql`, and a sibling import is what `zig build layering` refuses — so it
  would have had to duplicate `statement.zig`, `where.zig` and `row.zig`.
- **`build.zig.zon` gains `zqlite`, lazy**, and the `sql` row of the `layers`
  table gains `"zqlite"`. Both are one line, and the second is the one that
  makes this checkable.
- **`zig build test-sql` links libc and compiles C.** The bottom layer's
  property — tests with no module graph — was never `sql/`'s, so nothing is
  lost that this module had; but the suite gets slower and that shows up in
  every run.
- **The Gate stops being password-only.** `bulkhead.Gate` gains a second
  caller, which is the evidence the roadmap asked for before deciding whether
  it is a public name.
- **ADR 0061's open question is answered in mechanism and left open in
  fact.** *Which* of the two is right is still unmeasured, and the field is
  there so that answering it later costs a default rather than a rewrite.
