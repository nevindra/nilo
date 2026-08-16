# The shape of a query is settled while compiling, and only its values are not

nilo has said since [ADR 0001](./0001-dx-wins-below-the-10-percent-threshold.md) that a handler touching a database flattens every benchmark in the comparison. It has never had anything to say about the handler itself. `nilo.blocking` exists so that calling a database does not stop the thread ([ADR 0014](./0014-handlers-must-not-block-the-thread.md)), and that is the whole of it: the call itself is somebody else's problem, written by hand, checked by nothing.

This adds a second module — `sql`, alongside `nilo`, not inside it — that turns a struct into a query and a result back into that struct, with the column names checked while compiling.

## Why this is not the refusal templates got

`docs/roadmap.md` refuses templates on two arguments, and it is worth being precise about which of them applies here, because from a distance this looks like the same request.

The scope argument does not apply. Templates were refused because **nilo is for building APIs and services, and rendering a page is the thing it is not for**. Querying a database is not a thing it is not for; it is the first thing every service in the audience does after routing.

The mechanism argument does not apply either, and that is the load-bearing half. Rendering means producing a string per request, which is an allocation per request, which is the axis [ADR 0018](./0018-the-trade-budget-has-three-axes.md) treats as an invariant. A query does the opposite: the string is produced **once, while compiling**, and what is left at runtime is a constant and its parameters.

The roadmap already said this decision was available:

> This is a refusal of templates, **not** of everything on that side of the line. Whether some other convenience from the batteries-included world earns its place gets decided one feature at a time, against the two numbers above.

This is that decision, taken once, for this feature.

## The rule

> **The shape of a query is settled while compiling. Only its values are not.**

Which table, which columns, which operators, which order — all shape, all fixed before the binary exists, all a compile error when wrong. The `18` in `age > 18` is the only part that arrives at runtime.

It is the same sentence `typed.zig` lives by — *a pointer is a service, a value is request data* — applied one layer over.

```zig
const User = struct {
    pub const nilo_table = .{ .name = "users", .key = .id };

    id: i64,
    email: Str,
    age: i32,
    created_at: Timestamp,
};

const adults = try db.select(User, c, .{
    .where = .{ .age = .{ .gt = 18 } },
    .order = .{ .created_at = .desc },
    .limit = 10,
});
```

What reaches the socket is a `const` in the binary —

```sql
SELECT id, email, age, created_at FROM users WHERE age > $1 ORDER BY created_at DESC LIMIT 10
```

— and one parameter. Drizzle, which this borrows its spine from, cannot do that: JavaScript has no compile step, so it reassembles that string on every request. Zig does, so the string is not built at runtime at all.

`.age = .{ .agee = … }` is a compile error naming the column and the near miss. That is a Refusal, held by the build step, the same as every other comptime check nilo makes ([ADR 0027](./0027-the-rule-about-error-messages-is-held-by-a-build-step.md)).

## It is not an ORM, and it does not use the word

The word promises object-relational mapping. Zig has no objects, and every mechanism that makes people call GORM and Prisma ORMs is refused here:

**Change tracking** — knowing which fields moved so `save()` can write only those — needs a copy of the original row kept alive per row per request. That is an allocation per row on a path that did not ask for one, which [ADR 0018](./0018-the-trade-budget-has-three-axes.md) does not permit.

**Lazy relations** — a query firing because a field was touched — is a query nobody wrote, and N+1 is what it produces at scale. Joins are written out, the way Drizzle writes them.

**An identity map** — a live object graph the framework owns — is a lifetime problem in a language with no garbage collector, and it is the direct opposite of `Str` never escaping its request.

So `ORM` goes in `CONTEXT.md` under `_Avoid_`, and the module is called `sql`. A name is a promise, and `orm` would promise a `.save()` that will never exist. The README does the finding instead — *if you are looking for an ORM for Zig, this is not one, and here is why* — which turns away the wrong reader in the same sentence that attracts the right one.

## A struct of options, not a chain of calls

Drizzle reads `db.select().from(users).where(eq(users.age, 18))`, and the temptation to transliterate it is strong. It was refused, and the reason is not taste.

A chain has to carry its accumulated state in the return type: `.where()` hands back one type, `.limit()` hands back another wrapping it. When something does not fit, what the compiler prints is the tower. Diesel is the worked example — compile-checked queries whose failures are unreadable, which is the same as not being checked for anybody who has not already learned to read them.

nilo has a whole build step whose only job is to keep that from happening. A flat options struct has one type, so the message can name the field and suggest the near miss.

It is also the shape the repo already uses everywhere — `listen(.{ .max_connections = 10_000 })`, `Options` in `bulkhead.zig` — so it is not a new thing to learn.

The cost is real: a half-built query cannot be stashed and extended later, the way `baseQuery` works in Drizzle. A query is written once, whole.

## The table's shape belongs to the database

Three positions were available. **The code owns it** — the struct is the schema, migrations are generated from it, GORM and Prisma both work this way. **The database owns it** — migrations are written in SQL by hand and the struct only describes what is being read. **The database owns it and the disagreement is caught.**

The first was rejected on scope. A struct that owns the schema has to express everything a table has and a row does not: column widths, defaults, uniqueness, indexes, foreign keys, cascade rules. Every one of those needs a spelling in Zig with no annotations available, and the honest end of that road is annotations under another name. Auto-migration against a production database is the other half of the bill, and it is the half that deletes columns.

The third was taken. The struct describes what it reads; a query against `information_schema` compares every registered Row to what is actually there:

```
nilo: User.age expects int4, but users.age is text
nilo: User.nickname has no column in table 'users'
```

**The check runs once, on the first connection that succeeds** — not at `listen()`. That distinction is the whole of it. Checking at `listen()` was the first draft and it was wrong: it makes the server refuse to start when Postgres is briefly unreachable, which turns a rolling restart during a database blip into an outage, and makes a developer working on routes that touch nothing need a database running.

Tying it to the connection instead means the choice is already the user's, through a knob that already exists one layer down. pg.zig's pool takes `connect_on_init_count`; left at its default it connects during `init`, so the check happens at boot. Set to `0` the pool comes up without touching Postgres, and the check happens whenever the first query does.

nilo therefore adds **no option of its own** for this. A `check_schema = false` was drafted and dropped: a switch that turns off a correctness check is a place to hide from a failure, and it is unnecessary here, because what the user wants to control is when to connect, not whether to be checked.

The residue is honest and worth stating: with the pool set to connect lazily, a mismatched struct is found on the first request that touches the database rather than at boot. That is still every Row at once, once, rather than the request that happens to read the wrong column.

## Two seams, because there are two kinds of replacement

The first draft had one seam — hand over SQL and parameters, get rows back — on the argument that `pg.zig` is a fork maintained by the same person as zio, which [ADR 0002](./0002-zio-as-the-engine-behind-the-bulkhead.md) already names as a standing risk. Fitting the seam before it is needed is that ADR's own lesson.

One seam is not enough, because two different things get replaced and they are replaced independently.

Swapping the Postgres driver changes **how bytes reach the socket**. The SQL is identical. Adding a second database changes **the SQL itself** — `$1` against `?`, `= ANY($1)` against an `IN` list, `information_schema` against `pragma_table_info` — and that happens long before anything reaches a seam placed at the socket.

So:

- **Dialect** — comptime, pure, no I/O. Writes the SQL. It is also allowed to *refuse*: a dialect whose database has no arrays fails `in` at compile time rather than emitting something that means something else.
- **Wire** — runtime. Runs a query, hands back rows, begins and ends transactions. That is the whole list.

The seam falls on the line the code already splits along, which is why it costs almost nothing to fit now — a call to `dialect.placeholder(n)` instead of a literal `$` — and would cost a rewrite later, once every generated string has Postgres baked into it.

**What ships is one dialect and one wire.** SQLite is not being built. The point is that `$1` is not hardcoded.

This is deliberately **not** called a Bulkhead, and the difference matters. The Bulkhead is a wall: user code never names zio, and one file does. Here user code *does* name pg.zig — to build the pool, and for everything outside this module's scope, `LISTEN`/`NOTIFY` and `COPY` among it. Calling this a Bulkhead would promise a guarantee it does not make.

## Where `Str` stops, and why that is the honest answer

A hundred rows with three text columns must not be three hundred allocations. The row bytes are copied into the request arena once and every `Str` points into that copy, so a result set costs what the arena costs and not more.

Rows read one at a time cannot work that way, and this is where the design nearly went wrong. Reusing one buffer per row makes the text valid only until the next row is pulled — and `CONTEXT.md` defines `Str` as text that lives as long as the request, with no asterisk. A `Str` whose lifetime is shorter than that is precisely the bug class this repo fears most: correct in Debug, where the bytes a dangling pointer points at happen to still be there, and a segfault in ReleaseSafe.

The answer was already in the repo. `Body.read` returns `[]u8`, not a `Str`. The rule nilo actually follows is not *text from a request is a `Str`* but **text that outlives the call is a `Str`, and text that does not is not called one**. The type tells the truth.

So a streamed row is `Borrowed(User)`: `User` with every `Str` replaced by `[]const u8`, filled into a buffer the handler passes in, allocating nothing.

```zig
fn exportUsers(db: *Db, c: *Ctx) !void {
    var s = try c.stream("text/csv");

    var rows = try db.stream(User, c, .{});
    defer rows.close();
    while (try rows.next()) |u| try s.print("{d},{s}\n", .{ u.id, u.email });
    try s.finish();
}
```

> **Amended when it was built.** This sketch passed a caller's buffer in,
> and the built version does not: a borrowed row points straight at the
> driver's read buffer, so there was nothing for a second buffer to do
> except copy bytes with the same lifetime to a different address. What
> replaced it is `defer rows.close()`, which the sketch was missing and
> which is not optional — a result set walked away from half-read costs a
> connection ([ADR 0040](./0040-a-service-that-needs-the-loop-is-finished-when-the-loop-exists.md)).

pg.zig documents the same rule for its own rows — *valid only until the next call to `next`, `deinit` or `drain`* — so this is not a hazard being invented here. It is a hazard one layer down being passed along without a wrapper over it. Had `select` handed back a `Str` in this path, nilo would have been **hiding** that rule behind a type whose whole meaning is that holding it is safe.

Postgres sends every row without being asked, but the rows are read off the socket as they arrive, so memory stays bounded by the read buffer and TCP carries the rest. A million-row export runs flat, and no cursor is needed.

## Not found is not an error, and neither is most of what Postgres calls one

`db.one` returns `?Row`. A handler returning `!?User` therefore answers 404 and *says so in the generated document*, because [ADR 0024](./0024-a-failure-mode-belongs-in-the-return-type.md) already settled that the signature decides. Nothing was added for this; it fell out.

A unique violation is the opposite case. Left alone it would arrive as an unrecognised error and become a 500 through [ADR 0005](./0005-http-errors-via-fail-functions.md)'s table, which is wrong — a duplicate email is the client's mistake.

Translating them all inside this module was rejected. It does not know what the request is. `23505` on a signup is a 409; the same code inside a background import is not an HTTP answer at all; on a table used to win a race it is the expected outcome. Worse, it can come from any unique index reachable through a trigger, so a blanket 409 can tell a client that something is already taken when the collision was in a table it has never heard of.

So the module raises errors that read — `error.AlreadyExists`, not `error.PgError23505` — and the handler decides. Exactly one gets a default row in ADR 0005's table, `AlreadyExists` to 409, because it is the one whose meaning does not change with context. Foreign key, check and not-null violations stay 500: all three usually mean the code is wrong, not the client.

## Whatever the handler did, the connection goes back usable

This rule appears three times in this design, and it was already in the repo twice before it did.

A request body left half-read is finished off by nilo so the connection stays usable. A result set left half-read must be drained, or the rows still on the socket become the next query's answer. **A transaction left open is worse than either.**

pg.zig's own source settles how much worse. `Pool.release` reads:

```zig
if (conn._state != .idle) {
    lib.metrics.poolDirty();
    conn.deinit();
    ...
}
```

No `ROLLBACK`, no `DISCARD ALL`. A connection that is not idle is destroyed and replaced rather than cleaned, which means the two halves land differently: **unread rows are caught**, at the cost of burning a connection and dialling a new one, so forgetting to drain is expensive rather than wrong. An open transaction is server-side state that leaves the *protocol* idle, so it most likely passes that check and goes back into the pool inside a transaction, where the next request to take it runs inside a stranger's.

That last step is an inference about what `_state` tracks rather than something the documentation states, and it is the assumption this design is built on because it is the only safe one.

A `Tx` is held and released the way every other resource in nilo is held and released:

```zig
var tx = try db.begin(c);
defer tx.deinit();          // rolls back unless committed; the connection always returns clean
```

The closure form — `db.transaction(c, run, args)`, impossible to get wrong — was rejected for being a second dialect. Zig has no closures, so it means a struct holding a function and every capture passed by hand, and nothing else in nilo is shaped that way: `Stream`, `Socket` and `Body` are all *hold the thing, `defer` the cleanup*.

Forgetting the `defer` is caught the way forgetting `.keep()` is caught — a trap that only exists in Debug. Zig cannot enforce it, so the next best thing is making the mistake loud where somebody is looking.

## What it rules out

Joins, aggregates, subqueries, `HAVING`, window functions, CTEs. The line is one sentence — **one table, conditions that filter rows** — and past it the answer is `db.raw`, which still maps rows into a Row, still uses the arena, still follows the `Str` rule, and only gives up the compile-time column check.

That line is drawn where it is because a builder's dialect surface grows with the builder, and joins and aggregates are exactly where databases disagree most. A boundary that can be stated in one sentence is worth more than one that is further out, because a reader can predict what this does without opening the reference.

Migrations are not here and are not implied. Nothing about this design forecloses them; they can be added over it without changing anything above.

## Consequences

- **A second module, `sql/`, at the repo root — not under `src/`.** The dependency runs one way, `sql` on `nilo`, never back, which is what makes the binary-size cost of this feature exactly zero for anyone who does not import it. `src/` was rejected because `CLAUDE.md` tells contributors that a new file under `src/` gets an `_ = @import(…)` line in `nilo.zig`'s test block, and following that rule for a file under `src/sql/` would compile this module into every nilo build. A convention that points the wrong way is more dangerous than a `.paths` entry that can be forgotten, and the `.paths` entry is held by a test.
- **pg.zig is a lazy dependency.** `b.lazyDependency` returns null until something asks for it, so a project using only the HTTP framework never fetches a Postgres driver.
- **Four test steps.** `test` stays exactly as fast as it is. `test-sql` covers generated SQL, row filling and this module's Refusals with no database at all — both halves are pure functions, the same reason `App.handleRequest` is tested against in-memory buffers. `test-all` runs both and is what CI runs. `test-sql-live` needs a real Postgres, takes its address from the environment, and is deliberately outside `test-all`.
- **Four vocabulary entries and one banned word**: Row, Borrowed row, Dialect, Wire, Tx — and `ORM` under `_Avoid_`.
- **A long export holds a pool connection for its whole duration.** Ten concurrent million-row downloads against a pool of ten is every other request waiting. This is a property, not a defect, and it is documented rather than discovered.
- **Numbers this owes**, per `CLAUDE.md`'s rule that every change is put against all four axes before it is written:
  - The allocation count for `select`. That `select` allocates at all does not put it in breach, because the invariant is that a DX feature adds nothing to *a path that did not ask for one*, and a handler running a query has asked. It does mean the number has to be stated, and this entry stated one that was wrong for a year — *exactly two when `.limit` is written out, since the row count is then known before the first row arrives*. Two things were false. `fill` never read the limit, so writing one changed nothing; and a limit is a **ceiling**, not a count, so even reading it does not say how many rows arrive. What is true now, measured by `test "a select with a written-out limit reaches past the arena exactly once"` over a 32-byte Row: **one** allocation with a written-out limit, flat from ten rows to a hundred thousand, because the list is built to the ceiling before the first row lands. Without one it is 2, 3, 5 and 9 at ten, a hundred, a thousand and a hundred thousand rows — the list doubling its way there, each step abandoning the buffer before it, which an arena cannot take back. That is a reason to write the limit, and the guide says so. What the ceiling costs when it is not reached is `(limit - rows) * @sizeOf(Row)` bytes, handed back by `toOwnedSlice` when the list is still the arena's last allocation and held until the arena resets when it is not.
  - Throughput against hand-written pg.zig. The bar is ADR 0001's 10%.
  - Binary size for a project that does import this. Zero for one that does not is already settled by the module split.
  - pg.zig's `read_buffer`, which its own documentation says matters most for exactly the row-heavy queries this module produces.
- **One question deferred until it is measured.** `Timestamp` and `Uuid` carry `jsonStringify` so that a Row can be returned from a handler and come out right. `covers()` sends any type with its own `jsonStringify` to `std.json` rather than the generated writer — and `created_at` is in nearly every table, so this is the common path, not a corner. Measure it with `zig build profile` first. Under ADR 0001's 10% it is settled; over it, there is an argument to have about whether this module may reach into nilo's JSON writer, and not before.
