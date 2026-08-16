# Roadmap

What is coming, what is refused, and what nobody has decided yet — and nothing
else. Once something is built its entry leaves this file: what shipped is in
[`CHANGELOG.md`](../CHANGELOG.md), what was measured and learned on the way is in
[`history.md`](./history.md), and the decisions that are binding are in
[`adr/`](./adr/).

What this document is measured against is
[ADR 0015](./adr/0015-what-nilo-borrows-and-from-whom.md): **the signature is
the whole contract**, on a server whose memory you can put a number on. A
feature that does not serve one of those two is not automatically refused, but
it has to say what it is for.

## One list per module

nilo is a toolkit whose largest module is a server, rather than a server with
things beside it ([ADR 0041](./adr/0041-a-module-sits-where-the-loop-puts-it.md)).
One queue mixing the modules together hides the fact that decides how this work
gets done: **two modules touch no file in common**, so two of the lists below
can be worked at the same time, by two people or by one person on two days.

| Layer | Module | The loop | Its work |
|---|---|---|---|
| Core | `nilo_core` | needs none | [below](#nilo_core--the-vocabulary) |
| App | `nilo_http` | owns it | [below](#nilo_http--the-server) |
| Service | `nilo_sql` | needs it, does not own it | [below](#nilo_sql--postgres) |

Each module carries **Next**, numbered in its own order, and **Known gaps**,
which is what is wrong today with what fixing it would take. A number is a
position in that module's queue and says nothing about any other module's.

What is refused, which Zig this needs, and what could still go wrong are about
the repository rather than any one module, and stay whole at the bottom.

---

## `nilo_core` — the vocabulary

`Str`, the `Lifetime` behind it, and the `Scope` that lets a Service allocate
for a request without naming a server. It is the newest of the three and the
smallest on purpose: a file earns its way in by being needed by two layers, not
by having nowhere else to live.

### Next

1. **A build step that holds the layering.** ADR 0041 says a Core file may not
   import upward and nothing checks it, which makes it a paragraph rather than
   a rule — the same argument
   [ADR 0027](./adr/0027-the-rule-about-error-messages-is-held-by-a-build-step.md)
   made about error messages, and it eroded there the first afternoon somebody
   was in a hurry. An import scan over `core/` is a small step.

   What it has to allow is the exception the wiring turned up: a module's
   *tests* may name a layer above, because an import reached only from a `test`
   block is never analysed in a build that is not a test build. A scan that
   cannot tell those apart would refuse `sql/db.zig`, whose App-level tests are
   the ones most worth having.
2. **A second module in this layer, and the rule for what it may import.** The
   layering says a module imports downward and never a sibling, and with one
   Core module that has never been tested. `nilo_id` is the obvious first —
   UUID v4 and v7, where v7 is the sortable one a row wants for a key — and it
   immediately asks the question nobody has answered: `sql.Uuid` already
   exists, so either the Service imports the tool module, which makes *tool*
   a rank between Core and Service, or the type moves into Core, which the
   two-layer rule permits and the "not a drawer" rule resists. Building it
   without settling that is how the drawer starts.

### Known gaps

- **A Service has no supported way to dial out.** The Bulkhead covers the way
  in and nothing covers the way out, so `sql` reaches the network through
  pg.zig's own zio and a Service written here would have to name zio — which
  [ADR 0002](./adr/0002-zio-as-the-engine-behind-the-bulkhead.md) permits in
  exactly one file. It is not urgent with one Service. It is the bill the
  second one arrives with, and it is its own decision.

### Not decided

- **Where `convert` belongs.** Turning text into a type is what a Core wants —
  a configuration module would reuse it — but `convert.zig` reaches the
  Bulkhead to say a request failed. Either its failures come back as a value
  the caller turns into a 400, or it stays in the App layer and Core gets a
  smaller converter under the same rules. Deciding it wants the second caller
  to exist first, so there is something to design against rather than a guess.
  `percent.zig` is the same shape of question and the most likely file to earn
  its way down next, for the same reason: signing a URL needs the encoding half.

---

## `nilo_http` — the server

### Next

1. **Reloading without a restart — static files, then the server.** A
   development annoyance rather than a design hole: a deploy restarts anyway.
   The static half is a watch option on `staticWith`, re-reading a directory
   that has changed. The other half is the whole process, and it cannot live
   inside `App` — a running binary cannot rebuild itself, so it belongs in the
   build alongside `zig build run`. jetzig's dev server sums the modification
   times of its source tree and rebuilds when the sum moves, which is about as
   much machinery as this deserves; the part to be careful about is that neither
   half can end up in a release binary.

   The static half stopped being purely a convenience when files began spilling
   to disk: a spilled file's length and ETag are recorded at load while its bytes
   are read per request, so a file edited under a running server can now be
   served inconsistently rather than merely staying stale (known gaps, below).
2. **`permessage-deflate`.** Negotiated in the handshake, and a compressor per
   connection is memory that has not been budgeted.

### Known gaps

- **There are no counters.** Correlation is covered — request ids and JSON log
  lines ([Errors and logging](./guide/errors.md)) — but metrics are not: how many
  requests, at what statuses, how long. That is a much larger surface than a log
  line: where the numbers live, who reads them out, whether there is a registry,
  and whether any of it can be had without an allocation per request. Nobody has
  designed it.
- **A response body is never compressed, and only a held file is.** Static files
  under the spill threshold are gzipped once while the App is built, which is the
  shape that costs nothing per request
  ([static files](./guide/static-files.md#compression)). A file over it is opened
  per request and so has no "once" to be compressed in
  ([ADR 0037](./adr/0037-a-file-too-big-to-hold-is-opened-not-read.md)); in
  practice a file that large is a video or an archive and is compressed already.
  A handler returning JSON gets no such thing either, and the reason is the one
  that shaped the static half: a deflate compressor needs a 64 KB window, so one
  per connection would multiply the 8,767 bytes an idle connection holds and one
  per request would break the allocation budget
  ([ADR 0018](./adr/0018-the-trade-budget-has-three-axes.md)). The shape that
  fits is a pool of compressors sized to the thread count rather than the
  connection count — four cores, 256 KB, and a request borrows one for as long
  as it is writing. That is a real design with real questions in it (what
  happens when the pool is empty, what it does to a stream, what it does to SSE,
  which is the one thing that must never be buffered), and it has not been had
  yet. A proxy in front does this today and does it well.
- **A spilled static file that changes on disk serves a stale length.** A file
  over the threshold has its size, mtime and ETag recorded at load and its bytes
  opened per request, so editing one under a running server splits what used to
  be one consistent copy. Shrinking it is caught: fewer bytes arrive than the
  head promised, so the connection closes rather than letting the client read the
  next response as the rest of this body, and the log says which request it was.
  Growing it is not caught — the first recorded-length bytes go out under the old
  ETag, which is a complete, correct-looking response carrying a prefix of a file
  that has moved on. Both are the same instruction as before, that changing a
  file means restarting, but a held file could not fail this way and a spilled
  one can. The fix is the watch option in this section's first item, which is why
  this is not one of its own.
- **A 404 or a 405 with middleware registered costs one allocation.** Routes and
  static files have their chains resolved at `listen()`, so neither pays for the
  middleware in front of it. The set of paths that are neither is every string
  there is, so there is nothing to precompute for. It stays that way on purpose:
  one arena allocation on a cold path, bounded by the number of `use` calls.
- **The linker cannot drop what nobody uses.** The API description costs +14 KB
  on the hello example and +34 KB on rest whether or not `docs()` is called,
  because the switch is a runtime `null` check
  ([ADR 0017](./adr/0017-the-api-description-comes-from-the-signatures.md)).
  Fixing it needs a build option that a `zig fetch` dependent has to thread
  through, which is a worse ergonomic problem than the one it solves.
- **The API description is silent about authentication.** A handler taking a
  `CurrentUser` needs an `Authorization` header and the document does not say
  so, because the header is a line of Zig inside the resolver rather than
  something in a type. Whatever fixes this must not become a second thing to
  keep in step with the resolver — that drift is what the generated document
  exists to avoid.
- **The API description names one failure, and endpoints have several.** `!?T`
  puts a 404 in the document because the signature settles it
  ([ADR 0024](./adr/0024-a-failure-mode-belongs-in-the-return-type.md)). A
  `fail.conflict` on a duplicate email is a line in a function body and stays
  invisible. That is the rule rather than a gap — the document promises what the
  signature settles — but it is the rule that costs the most, and if a way is
  ever found to state a failure in a type without inventing an annotation, this
  is where it goes.
- **`describeBadBody` walks eight levels and then stops.** Deeper than that, a
  bad field is a plain 400 again. Same limit as the schema walker and the
  staleness trap, and for the same reason: a type holding one of its own has to
  stop somewhere.
- **The logged duration of a streamed response is its lifetime, not its
  latency.** One line per request is the contract, and a stream's line arrives
  when the stream ends. Time to first byte is a different number and wants a
  different feature.
- **The router is still a linear scan.** Indexing the first segment took 44% off
  a hundred-route app and moved
  [ADR 0001](./adr/0001-dx-wins-below-the-10-percent-threshold.md)'s 10% bar out
  to around 40 routes, so what is left is the actual tree, for the app with
  hundreds of them. The numbers no longer point at it urgently; `zig build
  profile` is the harness for the day they do, and two attempts that lost are
  written up in [`history.md`](./history.md) so they are not repeated.

### Not decided

- **Rotating the session secret.** Changing the secret today signs everybody out
  at once, which is correct and blunt. Doing better means a second key to
  decrypt with and a decision about how long to keep it — how many keys, where
  the list comes from, what a cookie sealed under a dropped one does. Nobody has
  asked yet, and the blunt version is not wrong, so this waits for somebody who
  actually rotates.
- **Signing out everywhere.** The other thing a sealed cookie cannot do: it is
  valid until it expires, so revocation is not in the mechanism. The answer
  today is a version number in the session checked against the row the handler
  was fetching anyway ([guide](./guide/sessions.md#what-it-cannot-do)), and it
  is not obvious nilo should have more of an opinion than that — anything
  further is a store, which is the design
  [ADR 0035](./adr/0035-a-session-is-sealed-into-the-cookie.md) declined.
- **Multipart, streamed.** `Form(T)` reads a multipart body whole, bounded by
  `max_body` ([ADR 0031](./adr/0031-a-form-is-the-body-read-by-another-rule.md)),
  which is right for a form with a photo in it and wrong for a 2 GB video. The
  streaming version wants a parser that resumes across reads and an `Upload`
  that is a reader rather than bytes.

  It inherits no answer from `sendfile`, which settled the outgoing direction
  ([ADR 0037](./adr/0037-a-file-too-big-to-hold-is-opened-not-read.md)): sending
  is a length and a descriptor handed to the kernel, and receiving is a parser
  that has to hold its place across reads. Until somebody designs it the answer
  is `c.bodyStream()`, which holds nothing and makes the framing the handler's
  problem.

---

## `nilo_sql` — Postgres

### Next

1. **The calls a service writes every day.** The module reads and writes one
   row at a time, and the shapes below are the ones a handler reaches for and
   does not find. Each is a statement this module could settle while compiling,
   so none of them moves
   [ADR 0039](./adr/0039-the-shape-of-a-query-is-settled-while-compiling.md)'s
   line; what they cost is surface, and each wants its axis numbers before it
   is written.
   - `db.find(Row, c, key)`. `row.keyOf` already works out the answer and has
     no caller — `.key` is a comptime check with nothing reading it.
   - Insert many. One round trip per row is the only shape there is.
   - Upsert. `ON CONFLICT` has no spelling, so idempotent writes are a caught
     `AlreadyExists` and a second statement, which is also a race.
   - `RETURNING` on `update` and `delete`. Both answer with a count, so a
     handler that wants the row it just changed pays for a second query.
   - `not in`, `not like`, and negation generally. `.ne` exists; its list and
     pattern halves do not.
   - `SELECT … FOR UPDATE`, savepoints, and an isolation level on `begin`.
     A `Tx` today is one connection and three verbs, which is not enough to
     write anything that actually contends.
2. **Prepared statements, measured first.** Every statement this module sends
   is already a comptime constant, which is the property that makes a cache
   cheap here and impossible in a framework that assembles its SQL per
   request — the key can be the statement's own identity. What is unknown is
   the number: `conn.queryOpts` re-parses and re-plans on every call, and
   nobody has measured what that is worth. `zig build profile` is the
   harness; [ADR 0001](./adr/0001-dx-wins-below-the-10-percent-threshold.md)'s
   10% is the bar, and `sql/postgres.zig` already says out loud that this is
   the measurement nobody has taken.
3. **The column types Postgres has and this module cannot read.** `numeric`
   is the one that matters — money in an `f64` is wrong, and a service that
   bills anybody needs it before it needs anything else on this list. Arrays
   (`text[]`, `int[]`) are the other half: pg.zig encodes them and
   `dialect.accepts` declines to judge them, so a Row that reads one fails to
   compile inside the driver rather than stopping here. `interval` and `inet`
   are the same shape of question and are worth less.
4. **A second Dialect.** The seam is fitted and only Postgres is filled in,
   so nothing is known about whether it holds. SQLite is the useful test,
   because it disagrees about the two things the seam abstracts: placeholders
   and list form (`sql/dialect.zig` already refuses a dialect with no
   `ANY(array)` rather than expanding a list into placeholders, which is the
   decision SQLite would challenge).

### Known gaps

- **A condition given an optional that happens to be null matches nothing,
  quietly.** `.{ .handle = null }` is `IS NULL` because the literal is a
  compile-time null. `.{ .handle = maybe }` with `maybe` a `?[]const u8` that
  is null takes the parameter path instead and sends `"handle" = $1` with
  NULL, which is never true in SQL — the query runs, answers nothing, and
  says nothing. It is the same failure `refusals/compared_with_null.zig`
  already refuses for `.{ .gt = null }`, reached by the other road. Filtering
  on a value the caller may or may not have is an ordinary shape, so the fix
  is a decision rather than a check: either an optional in a condition is a
  Refusal telling the caller to branch, or it means `IS NULL` the way the
  literal does. It cannot keep meaning `= NULL`.
- **A table that is not there is reported as every column being missing.** The
  introspection query answers nothing, so each column reports
  `no_such_column` — ten lines for one mistake, and not the one that was
  made. Forgetting to migrate is the most common way to see this, so it
  wants its own sentence: `schema.compare` checking `actual.len == 0` first.
- **A table can only be named, never qualified.** `.name = "app.users"` is
  quoted as one identifier, and the introspection query only looks in
  `current_schema()`. Anything with a `search_path` is out.
- **An enum column holding a value the Zig enum does not have panics.** It is
  `std.meta.stringToEnum(T, str).?` inside the driver, and
  `dialect.accepts` declines to judge enums, so this is the one column type
  that is unchecked at startup *and* fatal at run time. Reading it as
  `[]const u8` is the workaround; the fix is a decode that errors.
- **`translate` reads `conn.err` before it reads the error it was given.**
  pg.zig clears that field on `release`, so the pooled path is clean — but a
  `Tx` holds its connection across statements, and a non-server failure after
  a server one is reported with the older code. Narrow, and wrong when it
  happens.
- **A query has no deadline of its own.** `timeout_ms` bounds the wait for a
  free connection and nothing bounds the statement,
  which [ADR 0023](./adr/0023-a-deadline-belongs-to-an-operation-not-to-a-request.md)
  says an operation should have.

### Not decided

- **Whether the line past one table moves.** The module reads and writes a
  single table and refuses everything past *one table, conditions that filter
  rows*
  ([ADR 0039](./adr/0039-the-shape-of-a-query-is-settled-while-compiling.md)),
  with `db.raw` as the way out. A join is where dialects disagree most and a
  builder's surface grows with the builder, so this is not a queued feature —
  it is a decision nobody has made. Joins, nested rows fetched with their
  parent, aggregates, `GROUP BY` and subqueries are all downstream of this one
  answer, which is why they are a line here rather than six items above.
- **Migrations, and where they run.** Written down until now as the other half
  of the join question, which was wrong: ADR 0039's line is about the shape of
  a `SELECT`, and a migration is DDL. The two are undecided for different
  reasons and neither waits on the other.

  Half the machine is already built. `schema.compare` reads
  `information_schema`, knows which Postgres types each Zig type may be read
  out of, and reports a column that is missing, wrongly typed or wrongly
  nullable. What it cannot do is look the other way — a column the table has
  and the Row dropped — and `dialect.accepts` answers with the *list* a column
  may read out of, where `CREATE TABLE` needs the one to write.

  Three questions have no answer, and not one of them is about Zig:
  - **A rename cannot be told apart from a drop and an add.** drizzle-kit asks
    the developer. Asking means an interactive CLI, guessing means silent data
    loss, and refusing means a tool that only works on schemas nobody renames.
  - **Where the record of what has been applied lives**, who commits it, and
    what two branches that each add a migration do when they meet.
  - **A data migration cannot be derived from a struct diff.** There is a
    hand-written half whatever happens to the generated one.

  What *is* settled is where it runs. A migration is a CLI rather than a
  server, so it links no router and no accept loop — which makes it the first
  real caller of the Core layer
  ([ADR 0041](./adr/0041-a-module-sits-where-the-loop-puts-it.md)) and means it
  spends nothing on any of the four axes, because it is not in the process
  those axes measure. That also fixes its position: behind `nilo_sql` naming a
  Scope rather than a `Ctx`, which is Core's second item.

### Measured against Drizzle

[Drizzle](https://orm.drizzle.team/) is the fair yardstick, and not because it
is popular. It refuses the same three things this module refuses — no change
tracking, no lazy relations, no identity map — so what it *does* carry is a
worked list of what a library can owe a service without becoming an ORM.
Anything missing below is missing on merit rather than because ADR 0039 ruled
it out.

**Every box is empty, and that is the point.** This file holds nothing that is
built, so a line here is deleted when it ships rather than ticked and kept —
the box is for the afternoon between the two. A box is also not a schedule:
what is actually queued is the numbered list at the top of this section, and
most lines below point at it.

Two whole areas come off before the list starts.

- **Runtime query composition** — Drizzle's `$dynamic`, a builder held in a
  variable and added to before it runs. This is the one thing the module
  cannot have rather than has not got: the statement is a comptime constant,
  and every property in ADR 0039 is downstream of that. The answer past it is
  `db.raw`, and it always will be.
- **The validation packages** — `drizzle-zod` and its five siblings exist
  because a TypeScript type is gone by run time. A Zig struct is not, which is
  why one Row already feeds the query, the JSON body and the API description
  with nothing generated in between. Same for the ESLint plugin that catches an
  `update` with no `where`: that is a Refusal here, and the compiler holds it.

**Schema**

- [ ] `numeric`, arrays, `interval`, `inet` → Next 3
- [ ] Indexes, unique constraints, foreign keys, check constraints. A Row names
      its columns and its key and nothing else about the table is sayable, so
      `checking` cannot notice a missing index and nothing could generate one.
- [ ] Sequences, identity columns, generated columns
- [ ] Views and materialized views
- [ ] Schema qualification → known gaps, above
- [ ] A column type declared by a project rather than by this module. The
      schema half is already open — a struct with `pub const nilo_column` is
      judged by `dialect.accepts` — and the wire half is closed: `db.zig` knows
      `Str`, `Timestamp`, `Uuid` and `Json(T)` by identity, so anything else
      fails to compile inside the driver.
- Row-level security and Postgres extensions: nobody has looked.

**Reading**

- [ ] `not in`, `not like`, negation generally → Next 1. `eq`, `ne`, `gt`,
      `gte`, `lt`, `lte`, `like`, `ilike`, `in`, `IS NULL` and `IS NOT NULL`
      are there; `between` is deliberately absent, because two operators on one
      column are already ANDed.
- [ ] Set operations — `UNION`, `INTERSECT`, `EXCEPT`
- [ ] Common table expressions
- Joins, nested rows, aggregates and subqueries: one decision, above.

**Writing**

- [ ] Insert many, upsert, `RETURNING` on `update` and `delete` → Next 1
- [ ] Several statements in one round trip

**Connection and session**

- [ ] Isolation level, savepoints, nested transactions, `FOR UPDATE` → Next 1
- [ ] Prepared statements → Next 2
- [ ] A second driver → Next 4
- [ ] Read replicas — a second pool, and a rule for which one a statement takes
- [ ] A query cache

**Tooling.** None of it exists, and all of it is a CLI rather than a server —
which is why the whole group sits behind Core's Scope and why none of it can
spend an axis.

- [ ] `generate` — DDL out of the diff `schema.compare` already computes
- [ ] `migrate` — apply, and record what was applied
- [ ] `push` — the diff straight at a database, no files in between
- [ ] `pull` — Zig structs out of a database that already exists
- [ ] `check` — two migrations written against the same parent
- [ ] Seeding. The cheapest thing on this page once insert many and the Scope
      land: a seed is then an ordinary program calling `db.insert` in a loop,
      with no design left in it. Deterministic values and per-table counts are
      what `drizzle-seed` adds on top, and they are library, not mechanism.
- A GUI over the database: not from here.

---

## Not coming

Not "later" — decided against, with the reasoning written down. This list is
about the repository: it is what to check before proposing a change, whichever
module the change is in.

- **Templates.** nilo is for building APIs and services, and rendering a page
  is the thing it is not for. The mechanism argument and the scope argument
  point the same way. Rendering means producing a string per request, which is
  an allocation per request, which is the one axis
  [ADR 0018](./adr/0018-the-trade-budget-has-three-axes.md) treats as a hard
  invariant rather than a budget — the 8,767 bytes and the single allocation are
  what nilo has to sell, and a template layer spends both. And the two shapes
  Zig actually offers are far apart with nothing argued for in between:
  comptime-checked templates, which are a compiler of their own, and runtime
  string interpolation, which is a worse `std.fmt`. [jetzig](https://www.jetzig.dev/)
  is built for that job and does it with zmpl; that is a better outcome for
  everybody than a second half-answer here. A `<form>` posted to a handler
  still works — [`examples/forms`](../examples/forms/) is that, and
  `Bound(Form(T))` is what makes its failures legible
  ([ADR 0036](./adr/0036-a-binding-hands-its-failures-to-the-handler.md)).

  This is a refusal of templates, **not** of everything on that side of the
  line. Whether some other convenience from the batteries-included world earns
  its place gets decided one feature at a time, against the two numbers above.
- **A `recover` middleware.** Zig cannot recover from a panic at all, so there
  is nothing to build ([ADR 0008](./adr/0008-no-recover-middleware.md)).
- **TLS.** Terminated in front, and that is the answer rather than the plan
  ([ADR 0028](./adr/0028-tls-is-terminated-in-front.md)). Zig's standard library
  can be a TLS client and not a TLS server, nobody in the comparison wrote their
  own, and the two alternatives are a one-person crypto dependency or a C
  toolchain in the install story. HTTP/2 and a gRPC server go with it, which is
  said out loud because nobody derives it from "no TLS". `Ctx.clientIp()` and
  `.trusted_hops` are this decision's other half.
- **An ORM.** `nilo_sql` is not one and the name is the promise: no change
  tracking, which costs a copy of every row; no lazy relations, which are
  queries nobody wrote; no identity map, which is a lifetime problem in a
  language with no garbage collector
  ([ADR 0039](./adr/0039-the-shape-of-a-query-is-settled-while-compiling.md)).
- **Auth contents.** The mechanism is provided — middleware, resolved values —
  and the policy is yours.
- **Benchmark claims without a benchmark machine.** A figure gets published only
  alongside what it does *not* mean — and that a handler touching a database
  flattens the whole comparison
  ([ADR 0001](./adr/0001-dx-wins-below-the-10-percent-threshold.md)).

## Zig versions

The latest stable release only, on one branch. The people this is aimed at
download Zig, run `zig build`, and give up if it fails — they are not going to go
hunting for the right branch. The consequence is that every new Zig release
brings a few awkward weeks, made worse by zio following a branch-per-version
pattern too.

0.2.0 needs **Zig 0.16**.

## The standing risks

| Risk | How it is handled |
|---|---|
| zio is a one-person project; it could stop when Zig 0.17 lands | The Bulkhead, fitted from the first stage rather than patched on later ([ADR 0002](./adr/0002-zio-as-the-engine-behind-the-bulkhead.md)) |
| The `Str` guarantee cannot be complete | The debug-build staleness trap, on from day one ([ADR 0004](./adr/0004-request-arena-and-the-str-type.md)). It missed the case anybody would actually test it with — two separate `curl` calls, where the next connection started counting from the same number the stashed `Str` held — until every connection was given a generation span of its own. What it still cannot watch is a `Str` reached through something nothing walks: a const slice, an untagged union |
| A Service is shared across threads and nothing makes a user notice | `nilo.Mutex`, in the guide and in the example everyone copies. Nothing forces it — Zig has no ownership tracking to force it with ([ADR 0011](./adr/0011-shared-services-need-a-lock-from-the-bulkhead.md)) |
| A panic in any handler takes the whole process down, and Go people will assume otherwise | Cannot be fixed in Zig. Said plainly in the docs, `ReleaseSafe` and a supervisor recommended, and the in-flight request named in the crash ([ADR 0008](./adr/0008-no-recover-middleware.md)) |
| A response could differ from what `std.json` would have written, now that something else usually writes it | `covers()` decides while compiling which types the generated writer may touch, and it errs narrow: a tuple, a `[N]u8`, a type with its own `jsonStringify`, anything unrecognised, all fall back. Floats are handed to `std.json` field by field rather than reimplemented |
| Deadlines are on by default, so a client on a genuinely bad link could be cut off where it used to be served | The numbers are generous and each bounds one wait rather than a whole request, so nothing legitimate and slow — a big upload, an hour-long stream — is hurried by any of them ([ADR 0023](./adr/0023-a-deadline-belongs-to-an-operation-not-to-a-request.md)) |
| A WebSocket has no read limit, so a client that vanishes without a FIN holds a fiber | Caught by the write limit as soon as the server sends anything. A connection nobody writes to is caught by `.idle_ms` — 30 seconds by default, `0` waits forever. It is a ping rather than a deadline, because a quiet WebSocket is a working one: silence asks whether the client is still there, an answer buys another stretch, and a client that misses the next one is closed with 1001 ([ADR 0022](./adr/0022-a-websocket-is-a-handler-that-does-not-return.md)) |
| The request head is the one thing a stranger writes directly, and every test of it was an input somebody thought of | `http/fuzz.zig` states properties instead: the head boundary and the framing fields are checked against a byte-at-a-time reference implementation, over a corpus on every `zig build test` and over a million generated inputs on every CI run (`zig build fuzz`). Coverage-guided fuzzing is not available — `zig build test --fuzz` fails to compile inside std's own test runner on Zig 0.16.0 — so the generator is the substitute, and the targets are written to become coverage-guided the day that is fixed |
| Nothing bounds how many connections one process holds | `.max_connections`, 10,000 by default. Past it a connection is accepted and closed at once, so the failure mode is a client that finds out immediately rather than an OOM kill that takes every in-flight request with it |
| Spawned work can capture a `Str`, or call a fail function, and both compile | Neither can be caught: Zig has no ownership tracking, and `spawn` takes a plain function that nothing marks as being outside a request. Documented at the function, in the reference and in [ADR 0029](./adr/0029-a-spawned-fiber-belongs-to-the-server.md), and `spawn` takes its arguments by value so the copy is at least the obvious thing to write. A `Str` that escapes this way is the debug staleness trap's problem, and it is the case that trap cannot watch |
| A fail function in spawned work is safe only because of where a threadlocal gets written | `bulkhead.slot()` falls back to a threadlocal when a fiber has no slot, which spawned fibers never do. It is null on executor threads only because the one thing that sets it does so from inside `zio.blockInPlace`, which runs on a thread-pool worker. Both ends now carry a comment saying so; nothing enforces it, and if it broke, spawned work would write its message into an unrelated request — [ADR 0007](./adr/0007-failure-box-bound-to-the-fiber.md)'s leak by another route |
| A file response's bytes leave by a route the tests never take | **Not handled.** Every test runs through `testing.Client`, whose writer is `std.Io.Writer.fixed` and carries no `sendFile` in its vtable, so the suite takes std's read/drain fallback — the right bytes, by the route a platform without `sendfile` uses. The splice chain the feature exists for needs a real socket and nothing in the suite opens one. The fix is a build step that listens on port 0 and pulls a file over it; it is not written |
| A file response holds a descriptor for as long as the send takes | One per request in flight, so `.max_connections` bounds it — the same number an operator already multiplies for memory. It is closed on every exit from `sendfile.send` including the error ones, and a test counts `/proc/self/fd` across a request so it stays that way ([ADR 0037](./adr/0037-a-file-too-big-to-hold-is-opened-not-read.md)) |
| A spilled file's ETag is its mtime and size, so two different contents could share one | Accepted, and argued rather than assumed: the alternative is hashing gigabytes at startup, and a weak validator would make `If-Range` unusable for exactly the large downloads that need resuming. It is the tag nginx has served by default for twenty years. A held file is unaffected — it keeps its content hash |
| `zio.BroadcastChannel` aborts, or in `ReleaseFast` deadlocks, when a fiber parked in `receive` is cancelled | Not used, reported upstream with a standalone reproduction, and **fixed upstream** — a fresh `Waiter` per receive attempt, in zio `ab6873eb`. Not in a release yet: v0.17.0 predates it and is what `build.zig.zon` pins, so the fix arrives whenever nilo next moves the pin. Nothing here depends on it. A waiter node was pushed onto a queue it was already linked into (`simple_queue.zig:43`, from `broadcast_channel.zig:72`). Debug aborted 10 runs in 10, ReleaseSafe 3 in 3, and `ReleaseFast` — which has no such assertion — **hung 17 runs in 20** where a clean run takes 200ms. Cancellation was what reached it: the same program closing the channel and waiting was clean 5 in 5. A shared ring forces the cancel, having no per-consumer close ([ADR 0029](./adr/0029-a-spawned-fiber-belongs-to-the-server.md), [zio#667](https://github.com/lalinsky/zio/issues/667)) |
