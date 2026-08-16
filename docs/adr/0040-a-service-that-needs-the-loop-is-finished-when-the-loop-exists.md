# A service that needs the loop is finished when the loop exists

[ADR 0039](./0039-the-shape-of-a-query-is-settled-while-compiling.md) settled
what a query looks like and left one thing unstated, because it was not
visible until the driver was wired in: **a connection pool cannot be built
before `listen()`.**

It has to dial, dialling is IO, and the only IO nilo will tolerate on a
handler's thread is IO that goes through the event loop ([ADR
0014](./0014-handlers-must-not-block-the-thread.md)). The loop does not exist
until `serve` starts it. So the object a handler holds cannot be finished at
the moment a user naturally writes it:

```zig
var db = sql.Db.init(gpa, url, .{});   // no loop yet
try app.provide(&db);                  // still none
try app.listen(.{ .port = 8080 });     // the loop starts in here
```

pg.zig takes a `std.Io`, which is std's interface and not zio's — that part
is a gift, because handing one out names no Engine. What was missing is a
moment to hand it out *at*.

## What was decided

**`serve` gained one call.** The Bulkhead's contract now reads
`serve(gpa, options, stop, state, ready, handler)`, and `ready(state, io)`
runs once, on the thread that called `serve`, after the port is taken and
before the first connection is accepted.

**A service asks for it by declaring `nilo_start`.** The registry records a
type-erased thunk at `provide()` time for any service that has one, and
`listen()` runs them in the order they were provided. Nothing else changes:
a service without the declaration costs a null check at startup and nothing
at all per request.

```zig
pub fn nilo_start(self: *Db, io: std.Io) !void { … }
```

It joins `nilo_resolve`, `nilo_table`, `nilo_query` and `nilo_response` —
`src/resolve.zig` asks that the markers read alike, and this one does.

**The order is: bind, then start, then say "listening".** A port already in
use is the commonest way a server fails to start, so it is still reported
first. And the log line that claims the server is up is not printed until it
is: a pool that could not be built comes back as an error from `listen()`,
not as a surprise inside the first request that needed it.

**A `*const` service with a `nilo_start` is a compile error.** Finishing
means writing to yourself, and a const pointer has nothing to write into.
The message says to provide a `var`.

## Why not the alternatives

**A lazy pool, built by the first query.** The `std.Io` would come from the
running fiber, so no contract would change at all — genuinely tempting. It
was rejected on the request path: it puts a null check and a lock on a
pointer shared by every request, on the one path
[ADR 0018](./0018-the-trade-budget-has-three-axes.md) guards hardest, to
save a startup call that runs once. It also moves the report of a bad URL
from startup to whichever request happened to arrive first, which is the
wrong end of the day to find out.

**Making the user open the pool inside a handler.** No.

**Letting the Engine call a method on `state` by name.** `serve` could look
for `state.started` and call it if present. That couples the Engine to the
App's API, and the Bulkhead exists precisely so those two do not know each
other. Passing the function in keeps the Engine ignorant of what it is
calling.

**Giving `Db` its own `listen()`-shaped entry point.** A second way to start
a server, so that one of them could take a database. Two startup paths is
the cost, forever, of not adding one call to one contract.

## Three things the wiring settled that the design had not

**A transaction owns a connection; a pool hands one out per statement.** The
Wire's `run` acquires and releases around each call, which is right for
everything except the one case where it is silently catastrophic: a
transaction whose statements each took a different connection would run half
of itself somewhere else and commit on its own, with nothing failing. So a
transaction is a *type* with its own `run`, holding one connection for its
whole life, rather than a mode the Wire is in — and a result set opened
inside one carries `owns_conn = false` so that finishing with it does not
put the connection back mid-transaction.

**`Str` is a claim about text coming out, not going in.** A parameter bound
into a statement has to survive the call and nothing more, so a `Str` column
binds `[]const u8`. The first version used the column type as declared, and
`.email = "a@b.c"` did not compile — a string literal is not a `Str`, and
requiring the wrapper there would have been ceremony with nothing behind it.
The same mapping serves `stream`, where a borrowed row is exactly the same
question asked at the other end.

**A parameter is not always one value of its column's type.** `.in` compiles
to `= ANY($1)`, which is one placeholder holding a whole list — the thing
that keeps the statement a constant however long the list is, and the thing
that stops a scalar tuple field from being right. So what the where walker
records per placeholder is a `where.Param`: the column, and whether the value
is a list of it. That plus the two paragraphs above is why the record is a
struct rather than the column name it started as.

**`error.AlreadyExists` reaches 409 through `fail.zig`, and that costs no
dependency.** ADR 0039 promised the row and nothing implemented it. A Zig
error is a member of one global set, so `src/fail.zig` can match on the name
without importing the module that raises it: the arrow still runs one way.
It is the only one of the SQL module's four errors given a default, because
a unique violation means the same thing whatever the request around it was.

## What it costs

Put against the four axes ([ADR 0018](./0018-the-trade-budget-has-three-axes.md)),
measured on this machine, stripped `ReleaseFast`:

| Axis | Cost |
|---|---|
| Allocations per request | **none.** The hook runs once, at startup. The budget test in `app.zig` is unchanged. |
| Memory per idle connection | **none.** 8,767 bytes, flat. Nothing here is per-connection. |
| Throughput and p99 | **none on the request path.** No branch was added to it. |
| Binary size | **+560 bytes** for the hook and the 409 row, and neither is free when unused. |

That 560 bytes is the honest number: `nilo-hello` registers no service and
touches no database, and still grew from 889,824 to 890,384 bytes, because
`serve` calls `ready` unconditionally and the error union travels back out
through it. A build of the parent commit in a `git worktree` is where the
before came from, which is the method [`docs/history.md`](../history.md)
settled on after stashing produced two contradictory readings half an hour
apart.

**The SQL module's own cost is large and is paid only by those who import
it**, measured on the same machine, stripped `ReleaseFast`:

| A server with | Bytes | Over HTTP-only |
|---|---|---|
| one route, no database | 890,384 | — |
| `select` and nothing else | 1,587,240 | **+680 KB** |
| `select`, `insert`, `update`, `delete`, `raw`, a transaction, a stream and the schema check | 1,641,192 | **+733 KB** |

Nearly all of the first jump is pg.zig's dependency on ianic/tls.zig, which
has no build option to turn off; the whole write half, transactions and
streaming included, is the 53 KB between the last two rows. A project that
does not import `nilo_sql` links none of it — the dependency is marked
`.lazy = true` in `build.zig.zon` and is not even downloaded — and the
HTTP-only binary contains no pg or TLS content at all, checked rather than
assumed.

## The TLS question, which ADR 0028 does not answer

[ADR 0028](./0028-tls-is-terminated-in-front.md) refuses TLS, and this
module links a TLS library. That is not a reversal, and the distinction is
worth writing down because the next reader will notice the contradiction
before they notice the difference.

0028 is about **being a TLS server**: terminating connections from the
public internet, which brings certificate lifecycle, ALPN, session
resumption and a decade of protocol bugs into a project that has a load
balancer in front of it. This is **being a TLS client**, to one host the
operator chose, against a certificate somebody else renews. Every managed
Postgres — RDS, Supabase, Neon — refuses plaintext, so a driver without it
is a driver that cannot reach the databases people actually have.

Refusing to be a server and being willing to be a client is the ordinary
position, and it costs 676 KB in a binary nobody has to build.

## Consequences

- The Bulkhead is one call wider. Any future Engine owes `ready` — and any
  Engine that runs an event loop already has the `std.Io` to pass.
- `Ctx` gained `arena()` and `str()`. A module beside the framework needed a
  supported way to allocate for a request and to stamp bytes with its
  lifetime; reaching into `_arena` from another module would have made the
  underscore a lie. The `Lifetime` itself stays private, because the trap
  only means anything while the stamp is true.
- **Still to measure: the allocation count of a `select`.** The rows go in
  the request arena and pg.zig reads into it too, so the expectation is that
  it is arena traffic rather than general-allocator traffic — but ADR 0018's
  budget test counts calls to the arena, which is the stricter reading, and
  nobody has put a number on this path yet.
- `CLAUDE.md` said "the one dependency is zio" and now has to say when.
- **The transaction trap is weaker than `Str`'s, and knowingly so.** A `Tx`
  that is never `deinit`ed holds a connection until the process ends, and
  what catches it is a Debug-only counter asserted at `Db.deinit` — so the
  message arrives at shutdown rather than at the mistake. `Str`'s trap can
  do better because a `Lifetime` has a moment it ends at and a `Tx` has
  none. Ten leaks against a pool of ten is a deadlock, which is loud but not
  diagnostic; the counter is what turns that into a sentence.
- **The live tests own a table per optimize mode.** `test-sql` runs Debug
  and ReleaseSafe at once, and one fixture between them is a race that
  reports itself as a duplicate key in whichever test lost. Named
  `nilo_live_people_debug` and `…_releasesafe`, in lower case, because
  Postgres folds an unquoted identifier and the Dialect always quotes.
