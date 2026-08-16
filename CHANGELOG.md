# Changelog

What changed between one tag and the next — not what changed between commits.
What was measured and what was got wrong on the way is in
[`docs/history.md`](./docs/history.md); what is coming is in
[`docs/roadmap.md`](./docs/roadmap.md).

## Unreleased

**zfast is now nilo**, and the SQL module went from compiling queries to
running them. Needs Zig 0.16.

Install it pinned — `zig fetch --save git+https://github.com/nevindra/nilo?ref=v0.2.0`.

### Breaking: the rename

Everything spelled `zfast` is spelled `nilo`, and **the server's module is
`nilo_http` rather than `nilo`** — the bare name belongs to the project, which
now has three modules rather than one
([ADR 0041](./docs/adr/0041-a-module-sits-where-the-loop-puts-it.md)). A search
and replace covers all of it:

| Was | Is |
|---|---|
| `@import("zfast")` | `@import("nilo_http")` |
| `zfast_table`, `zfast_resolve`, `zfast_query`, `zfast_response` | `nilo_table`, `nilo_resolve`, … |
| `.zfast` in `build.zig.zon`, `zfast_sql` | `.nilo`, `nilo_sql` |
| `nilo.module("nilo")` in your `build.zig` | `nilo.module("nilo_http")` |

The markers are the ones worth knowing about, because they sit in **your**
structs rather than behind the import line — and they are the ones that
**do not** move again, because they are named after the project rather than
after a module. Alias the import back and the rest of your code is unchanged:

```zig
const nilo = @import("nilo_http");
```

Nothing else about the API changed in this release.

### `nilo_sql` runs

The compile-time half shipped in 0.1.0 and could not reach a socket. It can
now, over [pg.zig](https://github.com/lalinsky/pg.zig), checked against a
real Postgres on every push.

- **Reading** — `db.select`, `db.one`, and `db.stream` for a result set too
  big to hold. `one` returns `?Row`, so a handler returning `!?User` answers
  404 and the OpenAPI document says so, and it compiles its own `LIMIT 1` —
  a lookup on a column that is not unique costs one row rather than every
  match.
- **`db.find(User, c, id)`** — `one` with the condition already filled in,
  on the column the Row's `.key` names. `fn show(db, c, id: i64) !?User` is
  then a whole endpoint, 404 included.
- **`db.count` and `db.exists`** — the total a page needs, and whether
  anything matches at all. Both take a condition and nothing else, both go
  through the same walker `select` uses, so a page and its total are one
  condition written once and a misspelled column is the same compile error in
  both. `exists` is `SELECT EXISTS(…)`, which stops at the first row.
- **A written-out `.limit` now costs one allocation, at any size.** The limit
  is a ceiling known before the first row arrives, so the list the rows go
  into is built to it instead of doubling its way there. Measured over a
  32-byte row: one allocation from ten rows to a hundred thousand, against 2,
  3, 5 and 9 without it. [ADR 0039](./docs/adr/0039-the-shape-of-a-query-is-settled-while-compiling.md)
  claimed a number here for a year and the number was wrong; it is corrected
  in place and a test now holds it.
- **Writing** — `db.insert` (with `RETURNING`, so the generated key comes
  back), `db.update` and `db.delete`, both answering with the number of rows
  they touched and both refusing to compile without a condition.
- **`db.updateReturning` and `db.deleteReturning`** — the rows themselves
  rather than a count. A `PATCH` that changes a row and answers with it was
  an update and then a select: two round trips, and a read that could find
  what somebody else changed in between. The clause they add is the `SELECT`
  list this module already writes.
- **`.not_in`, `.not_like` and `.not_ilike`.** `.ne` was the only negation
  there was, so `not in` — as common as `in` — meant a second query or
  `db.raw`. `.not_in` is `<> ALL($1)`: one parameter however long the list
  is, exactly as `.in` is.
- **An optional in a condition no longer compiles.** `.handle = null` written
  out is `IS NULL`; `.handle = maybe` with `maybe` a `?[]const u8` used to
  take the parameter path and send `"handle" = $1` with NULL in it, which is
  never true in SQL — the query ran, matched nothing and said nothing. Which
  of the two statements is right depends on a value that arrives after the
  statement is a constant, so it is a Refusal asking for the branch
  ([ADR 0044](./docs/adr/0044-a-condition-holds-a-value-not-a-maybe.md)).
  Writes are untouched: `.set = .{ .handle = maybe }` is how a column is set
  to NULL and means one thing.
- **Transactions** — `db.begin(c)`, held and released the way every other
  resource in nilo is: `defer tx.deinit()` rolls back unless committed.
- **`db.raw`** — the way past *one table, conditions that filter rows*. Still
  fills your struct, still uses the arena; gives up the column check only.
- **`db.checking(&.{ User, Order })`** — each Row compared against its table
  while the server starts, instead of on whichever request got there first. A
  table that is not there at all is one line saying so, rather than one
  `no_such_column` per column of a table nobody created.
- **`sql.Timestamp`, `sql.Uuid` and `sql.Json(T)`** — the three columns Zig
  has no word for, read and written as themselves. A `timestamptz` arrives as
  microseconds since the epoch, a `uuid` as its sixteen bytes and a `jsonb`
  parsed into the struct you named; each writes itself into a JSON body the
  way the API description promises.
- Rows come out of the request arena. A streamed row is `sql.Borrowed(User)`,
  which is `User` with every `Str` replaced by `[]const u8` — because that
  text dies at the next row, and the type says so. `stream` refuses a Row
  with a `Json` column: a borrowed row allocates nothing, and parsing a
  document per row cannot.
- **A `.limit` or an `.offset` binds as whatever integer you are holding**,
  `usize` included, rather than only the ones that coerce to `i64`.

- A failure inside a transaction is now reported as its own. `translate`
  reads the server's code off the connection, and a transaction holds one
  across statements — so a broken pipe after a unique violation came back as
  `AlreadyExists`, the previous statement's answer. Narrow, and wrong when it
  happened.

**28 Refusals** hold the module's own error messages — a Row written wrong, a
column misspelled, an update with no condition, a key where a condition
belongs. Each is a program in `sql/refusals/` that must fail to compile with
the sentence nilo wrote
([ADR 0027](./docs/adr/0027-the-rule-about-error-messages-is-held-by-a-build-step.md)).
The module is still not an ORM and still refuses joins, aggregates and
migrations
([ADR 0039](./docs/adr/0039-the-shape-of-a-query-is-settled-while-compiling.md)).

### A WebSocket message, once through

Receiving one used to copy every byte into your buffer and then walk the same
bytes again to unmask them. It is one pass now — unmasked on the way across —
and a message too big to have arrived whole is read straight into your buffer,
past the connection's read buffer entirely
([ADR 0052](./docs/adr/0052-a-message-is-copied-once-and-framed-once.md)).

| `zig build profile` | was | is | |
|---|---|---|---|
| `websocket: frame overhead` | 9ns | 6ns | 1.5× |
| `websocket: receive 48 B` | 15ns | 12ns | 1.25× |
| `websocket: receive 16 KiB` | 196ns — 88.1 GB/s | 73ns — 244.5 GB/s | 2.7× |
| `room: say to 8 of 1,000 seats` | 494ns | 161ns | 3.1× |

Nothing about the API changed to get any of it. What *did* change:

- **`socket.print(fmt, args)` and `socket.json(value)`**, and the same pair on
  a `Room`. One text message, formatted or serialised straight onto the wire,
  with no stack buffer of yours to size:

  ```zig
  try room.print("welcome, {d} here", .{room.count()});
  try socket.json(.{ .kind = "joined", .who = name });
  ```

  Neither allocates on a Socket; on a Room they reuse the allocation `say` was
  going to make. Both run the format twice, once to size the frame and once to
  write it, because a frame states its length before its bytes.
- **`receive` ends when the server is stopping**, after telling the client so
  with a 1001. A message loop no longer needs `if (!socket.live()) break;` in
  it, which was a rule ADR 0020 stated and every handler had to remember.
  `live()` stays, for a handler doing work of its own between messages.
- **Sending on a socket that has already closed writes nothing** rather than
  failing. The other end closing between two of your sends is not a bug you
  can prevent, so it is not one you have to branch on.
- **A malformed close frame is refused with a 1002 rather than echoed.** A
  one-byte payload, a code nobody assigned, or a reason that is not UTF-8 —
  echoing those put the same broken frame back on the wire. A reason of your
  own that is too long for a close frame is now cut on a character boundary
  rather than through the middle of one.
- **A fragment is measured against what is left of your buffer**, not all of
  it, so a continuation that cannot fit beside what came before is refused on
  its header.
- **Sizing a `Room` generously is a memory decision and nothing else.** `join`
  and `say` cost what the room holds rather than what it was sized for, and a
  `say` into an empty room allocates nothing at all.
- **Removed: `nilo.websocket.Handshake`**, a struct wrapping the array
  `accept()` already returns. Nothing had ever used it.

### Also

- **`error.AlreadyExists` is a 409.** A unique violation is the one database
  error whose meaning does not change with the request around it, so it is
  the only one given a default answer. The rest reach your handler as errors
  that read.
- **`Ctx.arena()` and `Ctx.str()`** — memory that lasts exactly one request,
  and text stamped with that request's lifetime. A module beside the
  framework needed a supported way to allocate for a request.
- **`listen()` finishes services that need the event loop.** A service
  declaring `nilo_start` is handed the loop once it exists and before the
  first connection is accepted, which is the only reason a connection pool
  can exist at all ([ADR 0040](./docs/adr/0040-a-service-that-needs-the-loop-is-finished-when-the-loop-exists.md)).
- **`nilo.nowMicros()` and `nilo.nowMillis()`** — what time it is, which
  nothing in nilo could answer before. They are `nilo_core`'s, so a program
  with no server in it has them too, and they are plain functions rather than
  calls on a `Ctx`: reading a wall clock needs no event loop and nobody owns
  the time ([ADR 0045](./docs/adr/0045-core-knows-what-time-it-is.md)). 15ns a
  call. Use `nilo.monotonicNanos()` for a duration — a wall clock moves when
  an operator moves it.
- **`c.entropy(n)`** — `n` unguessable bytes from the operating system,
  returned by value, with the wait paid for by the Bulkhead rather than by
  the thread every other request is sharing
  ([ADR 0046](./docs/adr/0046-entropy-belongs-to-the-loop.md)).
  `nilo.randomSecure(&buf)` is the same bytes into a buffer you already hold.
  Together with the clock this is what `nilo_id` was waiting for:

  ```zig
  const key = id.v7(try c.entropy(id.Uuid.v7_entropy), nilo.nowMillis());
  ```
- **`sql.Timestamp.now()`** — so `created_at` is a field a handler fills
  rather than a database default it has to remember to set.
- **`sql.Decimal`** — a `numeric` column, which this module could not read at
  all. Money in an `f64` is wrong quietly, and reading the column type that
  exists to prevent that into a float gave the whole thing back. It holds the
  digits, it does not calculate, and **in a JSON body it is a string** —
  `"1234.56"`, not `1234.56`, because a bare number is exact on the wire and
  becomes a double the moment a consumer parses it
  ([ADR 0050](./docs/adr/0050-a-numeric-is-digits-and-a-string-in-json.md)).
  Comparisons are numeric, it costs the same one arena copy a text column
  always has, and unlike `sql.Json(T)` it streams.
- **`db.insertOrIgnore` and `db.insertOrUpdate`** — `ON CONFLICT`, which had
  no spelling, so an idempotent write was a caught `AlreadyExists` and a
  second statement: two round trips with a window between them that a retry
  does not close. Now one statement and no window. The conflict target is the
  last argument, written the way a key is — `.email`, or
  `.{ .tenant_id, .email }` — and does not have to be the Row's key, which is
  the case it exists for.

  Two calls rather than an option on `insert`, because the answers differ:
  `DO NOTHING` stores no row so `insertOrIgnore` returns `?User`, and
  `insertOrUpdate` returns `User`. `db.insert` is untouched. The update half
  writes every column you passed except the conflict target and the key —
  `"id" = EXCLUDED."id"` would renumber the row that was already there.
- **`tx.deadline(ms)`** — bound how long each statement in a transaction may
  run, and get `error.TimedOut` when one goes past it
  ([ADR 0047](./docs/adr/0047-a-deadline-needs-a-connection-you-hold.md)). It
  is on the transaction rather than on `Db` because a deadline is always a
  second command and has to travel down the same connection as the statement
  it bounds — which is what a transaction already holds and a plain
  `db.select` does not. One round trip, paid by the caller who asks for it.
- **A failed statement inside a transaction no longer costs a reconnect.**
  Postgres marks an aborted transaction with a ReadyForQuery status pg.zig
  maps to the same state it uses for a dead socket, so the `ROLLBACK` that
  follows was refused and nilo destroyed the connection rather than return
  one it could not vouch for. Nothing downstream could tell — the pool
  re-dialled — so this is a latency and connection-churn fix rather than a
  correctness one, and it applies to every failed statement in a transaction,
  not only a timed-out one.
- **An enum column that has fallen behind its table fails the request instead
  of the process.** A Postgres enum grows a value with `ALTER TYPE … ADD
  VALUE`; a Zig enum that has not grown it used to reach
  `std.meta.stringToEnum(T, str).?` inside the driver and panic, which in Zig
  takes every in-flight request with it
  ([ADR 0008](./docs/adr/0008-no-recover-middleware.md)). It is a 500 now, with
  the value and the type named in the log. Nothing changes for a Row whose enum
  is up to date, and the column is still the one type `checking` cannot judge
  at startup — unless it says what it is called: an enum carrying `pub const
  nilo_column = "user_role"` is now compared against the column like any
  other type.
- **Array columns.** `text[]` and `int4[]` are read as plain Zig slices —
  `tags: []const Str`, `scores: ?[]const i32` — with no wrapper type to learn
  ([ADR 0051](./docs/adr/0051-an-array-is-a-slice-and-a-slice-is-one-deep.md)).
  A Row that declared one used to fail to compile four frames inside pg.zig.
  `[]const u8` is still text, so a list of text is `[]const Str` or
  `[]const []const u8`, and an array whose elements can be NULL is read as a
  slice of optionals.

  Two shapes Postgres allows and a slice cannot hold — an array with a NULL in
  it read into a non-optional element, and an array more than one dimension
  deep — now fail the request. Both used to be an assert inside the driver:
  a panic in Debug and ReleaseSafe, a read past the end of the buffer in
  ReleaseFast. A Row that reads an array cannot be streamed, for the reason a
  `Json` column cannot: a streamed row holds only what the read buffer already
  holds.
- **A Row can read a view or a materialized view.** The schema check asked
  `information_schema`, which cannot see a materialized view at all, hides
  columns the role has no privilege on, and reports every view column as
  nullable — so a Row over a view was one disagreement per field and, by
  default, a server that refused to start. It asks `pg_catalog` now, and a
  column's nullability has a third answer for the case the database does not
  know ([ADR 0056](docs/adr/0056-a-view-is-a-table-that-cannot-say-what-is-not-null.md)).
  A driver's `Column.nullable` is `?bool`.

- **A column type can come from outside this module.** Any struct or enum with
  `nilo_column`, `nilo_read(text, arena)` and `nilo_write(arena)` is one, and
  it travels as the text Postgres prints — so an `interval`, a `money`, a
  PostGIS `geometry` or anything an extension adds is readable without this
  module knowing it exists. `sql.AsText("money")` is that protocol's smallest
  instance ([ADR 0055](docs/adr/0055-a-column-type-can-come-from-outside-this-module.md)).
- **`sql.Interval` and `sql.Inet`**, which are two lines of `AsText` each.
  **`sql.Decimal` is now one too** — same field, same JSON-as-a-string, no
  special case left in the Dialect or the driver.

- **A transaction takes what it is on the `BEGIN`.** `db.begin(c, .{ .isolation
  = .serializable, .read_only = true })` — comptime, folded into the statement,
  so neither option costs a round trip. **`db.begin` now takes an options
  struct**: an existing call becomes `db.begin(c, .{})`.
- **A read inside a transaction can hold what it matched.** `.lock = .update`,
  `.update_nowait`, `.update_skip_locked` or `.share`, written where the
  condition is. `.update_skip_locked` is a work queue in one option;
  `.update_nowait` answers `error.Locked`, which is new. A `.lock` on
  `db.select`, `db.one` or `db.stream` is a compile error, because a lock with
  no transaction around it is taken and dropped before the handler reads a row
  ([ADR 0054](docs/adr/0054-contention-is-what-a-transaction-is-for.md)).
- **`tx.savepoint()`** — a mark one part of a transaction can be undone back
  to. `sp.release()` keeps the work, `sp.rollback()` undoes it, `sp.deinit()`
  undoes unless something kept it. This is what a nested transaction is:
  Postgres has no nested `BEGIN`, and an inner commit is not durable. It is the
  only way to survive a failed statement inside a transaction, which otherwise
  aborts all of it.

- **`db.updateMany(Row, c, rows)`** — the batch's other half, and the same
  `unnest` joined against the table rather than selected into it. Each row
  carries the Row's key and is found by it, so there is no `.where` and a
  batch that does not carry the key is a compile error. `tx.updateMany` is
  the same call inside a transaction. Order is the planner's and a repeated
  key changes its row once — both are what a join is, and `db.update` in a
  loop is the answer where either matters.
- **A table can be qualified.** `.name = "app.users"` is a schema and a
  table now, quoted as two identifiers and introspected in that schema.
  Before, it was quoted as *one* identifier — `"app.users"`, a relation
  nobody created — and the error arrived at run time. A bare name still
  means whatever `search_path` resolves to. More than one dot is a compile
  error rather than a run-time surprise.
- **`.distinct_from` and `.not_distinct_from`** — SQL's null-safe comparison,
  and **the one operator a condition takes an optional for**:

  ```zig
  var handle: ?[]const u8 = maybe_from_the_request;
  const found = try db.select(User, c, .{
      .where = .{ .handle = .{ .not_distinct_from = handle } },
  });
  ```

  Every other operator refuses an optional, because whether the statement
  says `= $1` or `IS NULL` would depend on a value arriving after the
  statement is a constant. This one does not have that problem: it is `=`
  with null treated as an ordinary value, so the SQL is the same six words
  either way. It also finds the null rows `<>` silently drops. The compile
  error for an optional now points here first and at the branch second.
- **`db.insertMany(Row, c, rows)`** — a whole batch in one statement and one
  round trip, whatever the batch size
  ([ADR 0053](./docs/adr/0053-a-batch-is-one-array-per-column.md)). The rows
  come back in the order they were sent:

  ```zig
  const Line = struct { sku: Str, qty: i32 };
  const stored = try db.insertMany(Item, c, lines);   // lines: []const Line
  ```

  It sends one array per column and lets Postgres `unnest` them, rather than
  the `VALUES ($1,$2),($3,$4),…` most libraries generate — whose placeholder
  count *is* the batch size, so the SQL would have to be built per call and
  Postgres would plan a new statement for every size. Here the text is a
  constant and the size is data. `tx.insertMany` is the same call inside a
  transaction. It costs one allocation per column, not per row; a batch that
  violates a constraint takes all of its rows with it, because it is one
  statement.

### A third module, below the other two

nilo is now a toolkit whose largest module is a server, rather than a server
with things beside it
([ADR 0041](./docs/adr/0041-a-module-sits-where-the-loop-puts-it.md)). Which
module a file belongs in is decided by one question — does it need the event
loop? — and **a module imports downward only, never a sibling.**

Nothing you wrote changes. `nilo.Str` is the same declaration it always was.

- **`nilo_core`** holds `Str` and the Scope, needs no event loop, and can be
  imported on its own by a program that serves nothing.
- **A Scope is `arena()` and `str()`**, and nothing else. That pair was all
  `nilo_sql` ever wanted from a `Ctx`, so a query now takes either — the
  `*Ctx` a handler was given, or a **`nilo.Run`** where there is no request.
  `db.select(User, &run, .{ … })` runs in a CLI, in a scheduled tick, or in a
  test with no App in it. Handing over something that is neither is a Refusal
  naming the call.
- **`zig build test-core`** runs the bottom layer in both modes, and
  `zig test core/core.zig` runs it with no `build.zig` at all. That this works
  is the property the layering exists for, not a convenience.

### `nilo_id`, and a fourth module

The bottom layer holds more than one module now: `nilo_core` is the vocabulary
and sits under the rest of it, and **`nilo_id`** is the first *tool module* —
one job, no event loop, and it imports nothing at all
([ADR 0042](./docs/adr/0042-the-bottom-layer-holds-more-than-one-module.md)).

```zig
const id = @import("nilo_id");

const key = id.v7(random, ms);            // sortable — the millisecond first
const token = id.v4(random);              // 122 random bits
try w.print("/users/{s}", .{&key.toText()});
```

- **`sql.Uuid` is `nilo_id`'s `Uuid`.** Same declaration, re-exported, so
  nothing you wrote changes and a generated key goes straight into
  `db.insert`. What did *not* move down is the opinion about the column: a
  module that has never heard of Postgres does not carry `nilo_column`.
- **`v4` and `v7` are given their randomness rather than fetching it**, and
  `v7` is given its millisecond. In Zig 0.16 entropy and the wall clock are
  both IO, `Ctx` exposes neither, and a module in the bottom layer has no
  Bulkhead to reach through — so this release ships the *format* and says so.
  A v4 built from a seeded `DefaultPrng` is a session token anybody can
  predict; the doc comment says that at the function. The seam is
  [the roadmap's](./docs/roadmap.md) next item for `nilo_core`.
- `toText()` answers a `[36]u8` by value, `parse` takes hyphens or not,
  `millis()` reads a v7's clock back and answers null for anything else. A
  `Uuid` in a returned struct leaves as text rather than as sixteen numbers.
- **`zig build layering`** reads the `@import`s under `core/`, `id/` and
  `sql/` and refuses one that is not in that module's row of the `layers`
  table in `build.zig`. ADR 0041 said the layering needed a build step or it
  was a paragraph; it has one, and it hangs off `zig build test`.
- **`zig build test-id`**, and `zig test id/id.zig` with no `build.zig` at
  all. For a module down there that is the entry condition rather than a
  nicety.

### `nilo_config`, and a fifth module

Settings, read into a struct of your own before the socket opens
([ADR 0043](./docs/adr/0043-a-setting-is-a-field-and-every-bad-one-is-named-at-once.md)).
The second tool module, and it imports nothing either.

```zig
const config = @import("nilo_config");

const Settings = struct {
    port: u16 = 8080,
    database_url: []const u8,
    log_level: enum { debug, info, warn } = .info,
    workers: ?u8 = null,
};

pub fn main(init: std.process.Init) !void {
    const read = config.fromEnv(Settings, init.minimal.environ);
    const settings = read.value() orelse {
        try read.report(stderr);
        std.process.exit(2);
    };
}
```

- **The field is the setting and its name is the variable.** `database_url` is
  read from `DATABASE_URL`, a default is what "not set" means, and a `?T` is a
  setting that may be absent — the same three sentences a `Query(T)` follows.
  `fromWith(T, .{ .prefix = "NILO_" }, …)` puts a prefix in front of every one.
- **Every bad setting is named at once**, which is the reason this exists
  rather than the reading. `value()` is `?T` the way `Bound`'s is, so there is
  no way to reach past a failure into a half-filled struct:

  ```
  3 settings could not be read from the environment:
    PORT has to be a whole number, not "soon"
    DATABASE_URL is not set
    LOG_LEVEL has to be one of debug, info, warn, not "verbose"
  ```

  `read.failures()` walks them if you would rather write your own.
- **It parses no files, and that is a decision.** `config.Fixed` is the seam a
  program hands its own parsed pairs through, so TOML is a dependency you pick
  rather than one this module makes every project carry. `std.zon.parse` is in
  the standard library and costs nothing.
- **Text is `[]const u8`, not `Str`.** Settings are read once and held for the
  life of the process; the lifetime a `Str` carries has nothing to say about
  them, and `config.Env` reads the environment block where it lies rather than
  copying out of it. On Windows use `config.Map` with the `environ_map`
  `std.process.Init` already hands to `main`.
- **`zig build test-config`**, and `zig test config/config.zig` with no
  `build.zig` at all — the same entry condition `nilo_id` has.

### `nilo_pw`, and a sixth module

Password hashing: argon2id, and the two `Ctx` methods that make it safe to call
from a handler
([ADR 0048](./docs/adr/0048-a-password-hash-is-gated-because-forgetting-is-silent.md)).
The third tool module, and it imports nothing either.

```zig
// signing up
const stored = try c.hashPassword(pw.huge_pages, form.password);
_ = try db.insert(User, conn, .{ .email = form.email, .password = stored.text() });

// signing in
const row = try db.find(User, conn, .{ .email = form.email });
if (!try c.verifyPassword(pw.huge_pages, if (row) |r| r.password else null, form.password))
    return nilo.fail(401, "that is not a sign-in");
```

- **`stored` is optional, and null means there is no such account.** It does
  the work anyway and answers false, which costs the same as an account that
  exists. A sign-in that returns early on an unknown address answers in a
  millisecond instead of thirty and turns the form into a query for which
  addresses are registered. There is no signature here that lets the fast
  wrong version be written.
- **The methods are on `Ctx` because forgetting is silent.** One hash is 13 ms
  and 19 MiB. Thirteen milliseconds is *under* `block_warning_ms`, so a
  handler calling the pure module directly holds its thread on every sign-in
  and nothing in the log ever says so. These take the salt from `c.entropy`,
  park the fiber on the blocking pool, and hold a permit from a Gate.
- **`Options.password_hashes_at_once` defaults to 8**, and the number is
  measured. Argon2id is bound by memory bandwidth, not cores: on 16 cores the
  throughput ceiling is ~280 hash/s and eight reaches 91% of it for 152 MiB,
  where the ungated 32 reaches *less* for 608 MiB.
- **The stored form is the PHC string everybody else writes** —
  `$argon2id$v=19$m=19456,t=2,p=1$…` — so a hash of nilo's can be migrated off,
  and one made elsewhere at any parallelism verifies here.
- **A Cost below OWASP's weakest published configuration is a compile error**,
  and so is one with more lanes than memory to divide between them. Turning the
  Cost down to make a test suite fast is the mistake worth catching, because a
  weak hash looks exactly like a strong one afterwards.
- **`pw.huge_pages` is the allocator to hand it.** The same 19 MiB asked for in
  2 MiB pages rather than 4,864 of 4 KiB: **13.6 ms a hash becomes 11.0**, and
  nothing is held between hashes
  ([ADR 0049](./docs/adr/0049-a-hash-asks-for-the-pages-it-walks.md)). It is
  `std.heap.page_allocator` on anything that is not Linux, so a call site does
  not have to ask what it is running on.
- **`c.verifyPasswordWith(cost, …)` if you hash at anything but the default.**
  The no-account path does the work of a hash rather than returning early, and
  the Cost is what that work is measured out at — left at the default while
  your rows are 46 MiB, the two answers take visibly different lengths of time
  and the form is a list of addresses again.
- **`pw.needsRehash(stored, .default)`** answers whether a row was written at a
  weaker Cost than the one in force, for the sign-in that just succeeded to
  write it forward. Fewer kibibytes, fewer passes, a shorter salt or a shorter
  digest; lanes are not in it.
- **`pw.hash` fails one way**, `error.OutOfMemory`. `NotAHash` is something only
  a stored string can be, and hashing never answered it.
- **`zig build test-pw`**, and `zig test pw/pw.zig` with no `build.zig` at all
   — the same entry condition `nilo_id` and `nilo_config` have.

### What it costs

A project that never signs anybody in links **0 bytes** of `nilo_pw` — measured,
a stripped `ReleaseFast` build before and after is byte-identical in every
section. One that calls `Ctx.hashPassword` pays **149 KB**, which is argon2id,
blake2b, the PHC encoder and the Gate, plus **820 bytes** if it uses
`huge_pages`, `verifyWith` and `needsRehash` as well.

A project that does not import `nilo_sql` links none of it — not the driver,
not TLS — and pays **560 bytes** for the startup hook. One that uses the
whole module pays **733 KB**, of which the entire write half is 53 KB and the
rest is pg.zig's TLS dependency. Allocations per request, memory per idle
connection and p99 are unchanged.

The WebSocket work costs **896 bytes** on the chat example, stripped
`ReleaseFast`, and **0 bytes** on hello — a server that never upgrades still
links none of it. A seat in a `Room` costs **8 bytes** more than it did, so a
room of the default 1,024 seats is 8 KB larger, once; memory per idle
connection and allocations per request are unchanged.

Splitting Core out cost **zero bytes**, measured on three binaries rather than
assumed; adding `nilo_id` beside it cost the same three binaries nothing at
all, and adding `nilo_config` cost them nothing again — the same three numbers,
read a third time. A program that does import `nilo_id` and generates a v7 pays
**16 bytes**; one that reads a two-field Config and reports its failures pays
**3,392 bytes**.

## 0.1.0

The first release, published as **zfast**. Needs Zig 0.16.

Install it pinned — `zig fetch --save git+https://github.com/nevindra/zfast?ref=v0.1.0`.
Without the `?ref=` you get whatever `main` is that day.

### What is in it

- **Handlers are ordinary functions.** What each argument means is worked out
  while compiling, by one rule: a pointer is a service, a value is request data.
  A test calls the function directly — no server, no fake request.
- **Routing** — path params, wildcards, groups, plugins. The most specific route
  wins and duplicates are refused
  ([ADR 0013](./docs/adr/0013-the-most-specific-route-wins-and-duplicates-are-refused.md)).
- **Requests** — path params, query strings and JSON bodies as structs of your
  own; bodies too big to hold, read as a stream.
- **HTML forms and file uploads**, url-encoded and multipart.
- **Bindings that name the field that broke.** `Bound(Form(T))`, `Bound(T)` and
  `Bound(Query(T))` hand the handler every field that would not bind, by name,
  with the text that arrived — a 422 listing them is one line, and a page
  showing the form again with one box marked is a few more
  ([ADR 0036](./docs/adr/0036-a-binding-hands-its-failures-to-the-handler.md)).
- **Responses** — a status in the type (`Status(201, T)`), typed redirects,
  response headers, and a `Ctx` layer underneath for full control.
- **Cookies, and sessions sealed into one** with `XChaCha20Poly1305` — no server
  store, no expiry sweep, nothing added to what an idle connection costs
  ([ADR 0035](./docs/adr/0035-a-session-is-sealed-into-the-cookie.md)).
- **Middleware** as an onion of `Ctx` functions, and resolved values declared by
  their type. A group prefix may carry a param — `app.group("/orgs/:org")` —
  and middleware scoped to it matches whole segments.
- **Request ids and JSON log lines.**
  `logger.with(.{ .format = .json, .request_id = true })` writes one JSON object
  per line and puts an `X-Request-Id` on every response, adopting the proxy's id
  when it sent a usable one. `c.requestId()` reaches the same id from a handler.
- **Static files** held in memory, gzipped once at startup, with ETags and range
  requests. A file over `max_file_bytes` is not refused but opened per request
  and sent with `sendfile`, so a directory with a video in it still starts and
  the memory figure still holds
  ([ADR 0037](./docs/adr/0037-a-file-too-big-to-hold-is-opened-not-read.md)).
- **A handler can answer with a file.** `?nilo.FileBody` serves one out of a
  directory opened on purpose, with ranges, `If-Range`, conditional requests and
  `HEAD` handled for it — and null still meaning 404. The name is checked a
  segment at a time, and the path handed to the kernel never comes from a
  request.
- **Streamed responses and server-sent events.**
- **WebSocket** — handshake, framing, masking, pings, closing handshake. A
  connection that goes quiet is asked whether it is still there and closed with
  1001 if it does not answer; a quiet WebSocket is a working one, so this is a
  ping rather than a deadline (`.idle_ms`, 30 seconds, `0` waits forever).
- **Broadcast — `nilo.Room`.** Saying something to sockets a handler does not
  hold. Provide a `Room` like any other service, `join` on the way in,
  `defer leave` on the way out, and `say` reaches everybody in it:

  ```zig
  fn chat(c: *nilo.Ctx, room: *nilo.Room) !void {
      var socket = try c.upgrade();
      try room.join(&socket);
      defer room.leave(&socket);

      var buf: [16 * 1024]u8 = undefined;
      while (try socket.receive(&buf)) |message| {
          try room.say(message.kind, message.data);
      }
  }
  ```

  That loop is the one an echo server writes. A post arriving while a
  connection is quiet is written out by *that connection's own fiber*, inside
  `receive`, so a handler never sees one — and one client that stops reading
  costs that client and nobody else. It adds **4 measured bytes per idle
  connection**, with throughput and p99 unmoved
  ([ADR 0038](./docs/adr/0038-a-broadcast-rings-a-bell-it-does-not-write.md)).
- **A generated OpenAPI document**, written from the signatures rather than from
  annotations ([ADR 0017](./docs/adr/0017-the-api-description-comes-from-the-signatures.md)).
- **Failure in nilo's own words.** Get a handler wrong and compilation stops
  with a sentence naming your route, your argument and the fix; `refusals/` is
  56 programs written wrong on purpose that keep it that way
  ([ADR 0027](./docs/adr/0027-the-rule-about-error-messages-is-held-by-a-build-step.md)).
- **`nilo.spawn`** for work that is not a request, owned by the server so
  shutdown counts it ([ADR 0029](./docs/adr/0029-a-spawned-fiber-belongs-to-the-server.md)).

A full `Room` backlog drops the oldest post by default, or the newest if you say
so, and `room.missed(&socket)` says how many were dropped. That amends
[ADR 0020](./docs/adr/0020-a-request-that-lasts-is-still-one-request.md), which
refused to have such a queue at all.

### What it holds itself to

One allocation per request and 8,767 bytes per idle connection, both hard
invariants held by tests rather than by intent
([ADR 0018](./docs/adr/0018-the-trade-budget-has-three-axes.md)). Measured
numbers and the method behind them are in
[`docs/benchmarks.md`](./docs/benchmarks.md), with eight other servers through
the same harness in [`docs/comparison.md`](./docs/comparison.md).

### What is not in it

- **Templates** — a refusal rather than a backlog item. nilo is for building
  APIs and services; rendering pages is not what it is for, and the reasoning is
  in [the roadmap](./docs/roadmap.md#not-coming).
- **Counters.** Requests carry an id and lines can be JSON, but how many
  requests, at what statuses, and how long is not collected anywhere.
- **TLS**, and with it HTTP/2 and a gRPC server. This is a refusal rather than a
  gap — terminate in front
  ([ADR 0028](./docs/adr/0028-tls-is-terminated-in-front.md)).
- **A `recover` middleware.** Zig cannot recover from a panic, so there is
  nothing to build ([ADR 0008](./docs/adr/0008-no-recover-middleware.md)).
- **Compressing a handler's response**, `permessage-deflate`, and streamed
  multipart. Static files under the spill threshold *are* compressed, once, at
  startup; one above it is sent as it lies on disk.

`zfast` was a working name, and it changed in 0.2.0.
