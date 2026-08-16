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
| Core | `nilo_id` | needs none | [below](#nilo_id--identifiers) |
| Core | `nilo_config` | needs none | [below](#nilo_config--settings) |
| Core | `nilo_pw` | needs none | [below](#nilo_pw--hashing-a-password) |
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
for a request without naming a server. It is the smallest module on purpose: a
file earns its way in by being needed by two layers, not by having nowhere else
to live. `nilo_id` sits beside it in the same layer and below is only `std`
([ADR 0042](./adr/0042-the-bottom-layer-holds-more-than-one-module.md)).

### Next

1. **A per-thread entropy pool, if a number ever justifies one.** `c.entropy`
   reaches the operating system on every call, which is 56ns on a kernel that
   serves `getrandom` from a vDSO and roughly twenty times that on one that
   does not ([ADR 0046](./adr/0046-entropy-belongs-to-the-loop.md)). A CSPRNG
   seeded once per thread would remove it, and costs stored state, a fork
   hazard and a seeding moment. Nobody has a workload that needs it. This is
   here so that whoever finds one knows the design was priced rather than
   missed.

### Known gaps

- **A Service has no supported way to dial out.** The Bulkhead covers the way
  in and nothing covers the way out, so `sql` reaches the network through
  pg.zig's own zio and a Service written here would have to name zio — which
  [ADR 0002](./adr/0002-zio-as-the-engine-behind-the-bulkhead.md) permits in
  exactly one file. It is not urgent with one Service. It is the bill the
  second one arrives with, and it is its own decision — **not** the one
  [ADR 0046](./adr/0046-entropy-belongs-to-the-loop.md) answered, which was
  written down here as though the two were halves of one thing and is not.
  Reaching the operating system for bytes and reaching the network for a
  socket have a layer in common and nothing else.
- **The layering step cannot see that an import is only reached from a test.**
  `zig build layering` refuses an import that is not in that module's row of
  the `layers` table, and `sql/db.zig` legitimately names `nilo_http` from a
  `test` block. Telling the two apart needs a parser rather than a scan, so the
  table has an `in_tests` list the step allows and does not verify. A rule with
  a listed exception still beats a rule in a document; this is the part of it
  that is weaker than the rest.

### Not decided

- **Where `convert` belongs.** Turning text into a type is what a Core wants,
  but `convert.zig` reaches the Bulkhead to say a request failed. Either its
  failures come back as a value the caller turns into a 400, or it stays in the
  App layer and Core gets a smaller converter under the same rules.

  This was written down as waiting for a configuration module to be its second
  caller. `nilo_config` was built and **is not one**
  ([ADR 0043](./adr/0043-a-setting-is-a-field-and-every-bad-one-is-named-at-once.md)):
  sharing means naming `nilo_core` for `Str`, and a bottom-layer module that
  does gives up running under a plain `zig test`, which ADR 0042 made the entry
  condition for the layer. So the question is unchanged and the shape of its
  answer is not — **the caller that moves this has to be in the App or Service
  layer**, because one below cannot afford to reach for it. `percent.zig` is the
  likelier candidate for the same reason it always was: signing a URL needs the
  encoding half, and whoever signs one is not down here.

---

## `nilo_id` — identifiers

A `Uuid` and the two layouts anybody writes, v4 and v7. It imports nothing at
all, which is the strongest form of what the bottom layer is for.

### Known gaps

- **A v7 is not sortable within a millisecond.** Two made in the same one come
  back in random order relative to each other. RFC 9562 allows a counter in
  `rand_a` and this has none, on the grounds that it buys ordering nobody asked
  for at the price of a threadlocal — but a service inserting a batch in a tight
  loop is exactly the caller who would notice, and nobody has looked at whether
  that happens in practice.

### Not decided

- **Whether any other identifier belongs here.** ULID, nanoid and Snowflake are
  each a different trade of length against sortability against coordination, and
  a module that holds all of them is a catalogue rather than a decision. UUID is
  here because a database column has that type; nothing else has that argument
  yet, and "somebody might want it" is not one.
- **Whether v3 and v5 belong here.** They are a hash of a name in a namespace,
  which is a different job from making one nothing has ever used — and they need
  MD5 and SHA-1, which means this module would ship two broken hashes for the
  first caller who asks.

---

## `nilo_config` — settings

A struct of your own filled from the environment, with **every** bad setting
named at once rather than the first
([ADR 0043](./adr/0043-a-setting-is-a-field-and-every-bad-one-is-named-at-once.md)).
It imports nothing, allocates nothing, and is over before the socket opens.

### Next

1. **A name that is not the field's own.** `database_url` reads
   `DATABASE_URL` and there is no way to say otherwise, so a platform that
   already owns a name — `PGURL`, `PORT` meaning something else in the same
   container — has to be met by renaming the field. A marker in the reader's
   own struct is the shape the rest of nilo uses (`nilo_table`,
   `nilo_resolve`), and the work is one comptime lookup. What is missing is a
   caller who cannot rename the field, which is the same test every other
   marker had to pass.

### Known gaps

- **`config.Env` is POSIX only.** It reads the environment block where it lies,
  which is what makes the whole module allocate nothing — and Windows moves
  that block, so `getPosix` cannot be used there at all. `config.Map` is the
  portable half and takes the `environ_map` that `std.process.Init` already
  hands to `main`, so nothing is unreachable; it just costs the map. The
  `@compileError` on `Env.get` says which to use rather than letting the
  failure come out of the standard library.
- **A prefix is per reading, not per Config.** `fromWith(T, .{ .prefix = … })`
  has to be written at each call, so two places reading one Config can disagree
  about it. Making the prefix part of the type would fix that and cost
  `Read(T)` its one-type-per-`T` property, which is what lets a function take a
  reading without naming the prefix it was read with.

### Not decided

- **`.env`, and whether reading one file is still refusing file formats.** The
  refusal is real and argued — a parser is a dependency every importer carries,
  and `Fixed` is the seam for a program that wants one. But a `.env` is fifty
  lines rather than two thousand, it needs no dependency, and it is the one
  format whose whole purpose is to hold what this module already reads. Nobody
  has decided whether that makes it the exception or makes it the first step
  down the slope the refusal exists to avoid.
- **Whether a Config can say a setting is secret.** Marking one would let
  `report` and any future logging print `PGPASSWORD=***` rather than the value.
  It is a small feature with a large blast radius if it is trusted and wrong —
  a value marked secret and printed anyway is worse than one nobody claimed
  anything about — and nothing here logs a Config today, so there is nothing to
  redact yet.

---

## `nilo_pw` — hashing a password

argon2id as a pure function of a password, a salt and a Cost, plus the two `Ctx`
methods that take the salt from the loop and a permit from the Gate
([ADR 0048](./adr/0048-a-password-hash-is-gated-because-forgetting-is-silent.md)).
It imports nothing at all, and a project that never signs anybody in links none
of it — measured at 0 bytes.

### Known gaps

- **The Cost floor only weighs memory.** `Cost.floor_memory_kib` refuses
  anything under 7 MiB, which is OWASP's weakest published configuration — but
  that configuration is 7 MiB *and five passes*, and `.{ .memory_kib = 7 *
  1024, .passes = 1 }` is a quarter of the work and compiles. A floor on
  `memory_kib * passes` would catch it and would also refuse this repository's
  own test Cost, which is how the suite affords two optimize modes. What is
  missing is a way to be cheap in a test suite that is not also a way to be
  cheap in production
  ([ADR 0049](./adr/0049-a-hash-asks-for-the-pages-it-walks.md)).
- **A password longer than a page costs what it is.** Argon2 hashes the whole
  input, so a client posting a megabyte gets a megabyte hashed. `max_body`
  bounds it at one megabyte by default and the Gate bounds how many at once,
  so it is not an opening — but everybody else truncates at 72 bytes or
  pre-hashes with SHA-512, and nilo does neither and has not decided which.

### Not decided

- **Whether a memory-bound deployment gets bcrypt.** It is in `std`, it costs
  zero heap against argon2id's 19 MiB, and it is 2.6× slower for the trouble
  (ADR 0048 has the numbers). The trade is real for a small machine holding
  many connections; what is missing is somebody on one.
- **Whether the Gate belongs to more than passwords.** `bulkhead.Gate` is
  general — a counting lock that tells the detector it is waiting — and
  password hashing is its only caller. A second one (image resizing, a report
  that holds a core) would decide whether it is a public name or stays
  internal.
- **Who sends `std` a vectorised argon2.** `std.crypto.pwhash.argon2` does its
  16-word permutation one word at a time. Written as four `@Vector(4, u64)`
  lanes — the shape the reference implementation has had since 2015 — the same
  hash is **11.19 ms instead of 13.78**, and 8.98 out of `pw.huge_pages`, with
  byte-identical output at every shape it was checked at. nilo will not carry a
  copy of somebody else's crypto to get it
  ([ADR 0049](./adr/0049-a-hash-asks-for-the-pages-it-walks.md)); the patch is
  upstream's to take, and what is missing is somebody to send it.

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
- **Nothing runs the Autobahn suite against the WebSocket.** `wstest` is the
  thing every implementation of RFC 6455 is measured by, and nilo's framing
  tests are all its own — written from the RFC rather than from a failing
  report, which by
  [ADR 0033](./adr/0033-a-guard-is-not-a-guard-until-it-has-been-seen-to-fail.md)'s
  reading makes the close-code and UTF-8 rules
  ([ADR 0052](./adr/0052-a-message-is-copied-once-and-framed-once.md)) guards
  that have only ever been seen to pass. It needs a build step that listens on
  a port and drives a Python client at it — the same harness *The standing
  risks* already names as missing for `sendfile`, and neither exists.
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

1. **A SQLite Wire.** The Dialect is written and the seam held — twelve of
   thirteen declarations fitted unchanged, and the thirteenth widened
   `ListForm` to four values
   ([ADR 0061](./adr/0061-the-second-dialect-is-the-test-of-the-seam.md)). What
   is left is the half that speaks to the database, and it has a design
   question in front of it rather than a coding one: **SQLite is a blocking
   file read, not a socket.** A Postgres wait suspends the fiber and frees the
   thread, which is what buys 215,000 requests a second
   ([ADR 0059](./adr/0059-a-round-trip-is-not-the-cost-worth-chasing.md)); a
   SQLite call has no descriptor to wait on, so it either holds its thread or
   pays a `nilo.blocking` hop, and which is right depends on numbers nobody
   has — a local read is microseconds, a write behind a contended database
   lock is not. Measure that before writing anything. The C dependency is the
   smaller half.

### Known gaps

- **An enum column that has not named its type is not checked at startup.**
  An enum carrying `pub const nilo_column = "user_role"` is judged like any
  other column; one that does not is not, because a Postgres enum's type name
  lives in the database and guessing it would fail honest schemas. What is
  still open either way is the *values*: nothing compares the Zig enum's tags
  against the type's, so a Zig enum that has fallen behind its table is found
  by the first request that reads such a row. Closing that means asking the
  database which values the type has — a second introspection query, and a
  Dialect that can spell it.
- **Nothing tests what a transaction does when the socket dies.** `Tx.fresh`
  clears the connection's server error before each statement, so a broken
  pipe after a unique violation is no longer reported as `AlreadyExists` —
  but the fix has no test under it, because provoking a transport failure
  between two statements of one transaction needs a socket the suite never
  opens. It is the same shape as the `sendfile` gap in the risks table below,
  and it wants the same answer: a build step that listens on a real port.

  It now carries a second passenger. `Tx.revive` reads `conn.err` to tell an
  aborted transaction from a dead connection
  ([ADR 0047](./adr/0047-a-deadline-needs-a-connection-you-hold.md)), and only
  the first half of that has a test: a server error is easy to provoke and a
  transport failure mid-transaction is the thing the suite cannot stage.
- **A query outside a transaction still has no deadline.** `tx.deadline(ms)`
  covers the operation that holds a connection
  ([ADR 0047](./adr/0047-a-deadline-needs-a-connection-you-hold.md)); a plain
  `db.select` takes whichever connection is free and gives it straight back,
  so there is nowhere to put one that is not a second round trip per query.
  What would close it is a pool-wide floor handed over in the startup packet,
  which costs nothing per statement and **cannot be built against the pinned
  driver**: pg.zig's `auth.zig` builds its startup message without the
  `startup_parameters` map it accepts, so the field goes nowhere. One line
  upstream, then an option here. Until then it is
  `ALTER ROLE app SET statement_timeout`, from the side that can already do
  it.

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
  those axes measure. Nothing blocks it there any more: `nilo_sql` takes a
  Scope rather than a `Ctx`, so a migration is an ordinary program holding a
  `Run`.

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

- Indexes, unique constraints, foreign keys and check constraints: refused, on
  the record ([ADR 0056](./adr/0056-a-view-is-a-table-that-cannot-say-what-is-not-null.md)).
  A Row names its columns and its key and nothing else about the table is
  sayable, so nothing here can check or generate one — and a Row that *could*
  say it would be a migration file with Zig syntax. The work belongs to a
  migration tool, which is undecided below.
- Row-level security and Postgres extensions: nobody has looked.

**Reading**

- Set operations and common table expressions: refused, on the record
  ([ADR 0058](./adr/0058-a-set-operation-over-one-table-is-a-condition.md)).
  Over one table all three set operations are boolean algebra on the `WHERE`
  clause and the module writes all of it; over two they are a view, and a Row
  may name one. A CTE is `db.raw`, `WITH RECURSIVE` included.
- Joins, nested rows, aggregates and subqueries: one decision, above.

**Writing**

- Several statements in one round trip: refused, with the numbers
  ([ADR 0059](./adr/0059-a-round-trip-is-not-the-cost-worth-chasing.md)).
  pg.zig has no pipelining, the shape that matters is `insertMany` already,
  and a data-modifying CTE through `db.raw` is one round trip today. What it
  would buy is latency for one request on an axis the load test says is not
  short.

**Connection and session**

- [ ] A second driver — the Dialect is written, the Wire is Next 1
- Read replicas: the mechanism is built and the routing is refused
  ([ADR 0060](./adr/0060-a-second-database-is-a-second-type.md)).
  `sql.Named("replica")` is a second `Db` type, so two pools are two services
  and which one a statement takes is written in the handler's argument list.
  An automatic reader needs health checking, lag awareness and read-after-write
  safety — three background tasks this module does not have, and getting the
  last one wrong is silent.
- A query cache: refused, same ADR. Invalidation cannot be right from here —
  the module sees only the writes that go through it. A TTL is a policy and
  tagging is annotation; the value belongs in a Service of your own.

**Tooling.** None of it exists, and all of it is a CLI rather than a server —
which is why none of it can spend an axis, and why a `Run` is all any of it
needs to hold.

- [ ] `generate` — DDL out of the diff `schema.compare` already computes
- [ ] `migrate` — apply, and record what was applied
- [ ] `push` — the diff straight at a database, no files in between
- [ ] `pull` — Zig structs out of a database that already exists
- [ ] `check` — two migrations written against the same parent
- [ ] Seeding. The cheapest thing on this page: a seed is an ordinary program
      calling `db.insertMany` against a `Run`, with no design left in it.
      Deterministic values and per-table counts are what `drizzle-seed` adds on
      top, and they are library, not mechanism.
- A GUI over the database: not from here.

---

## Modules that do not exist yet

A section rather than a list inside somebody else's, because what decides
whether one of these gets built is a repository-level seam rather than anything
in a module that is already here.

- **`nilo_s3` — object storage.** Blocked, and not on the same thing. It needs
  an outbound socket, and the Bulkhead covers the way in only — see `nilo_core`'s
  known gaps. Signing a request is the half that is ready: it needs `percent`
  one layer down, which is the second caller that file has been waiting for.
- **A `nilo_mail`, a `nilo_redis`, anything else that dials.** All the same
  blocker as `nilo_s3`, and none of them is a reason to answer it on its own.
  The seam gets designed once, against two callers, or it gets fitted to
  whichever one turned up first.

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
- **A config file parser — TOML, YAML, or any other.** `nilo_config` reads the
  environment and hands `Fixed` to a program that has parsed something itself
  ([ADR 0043](./adr/0043-a-setting-is-a-field-and-every-bad-one-is-named-at-once.md)).
  Writing one means weeks to reach where somebody else already is; depending on
  one means every project importing the module fetches it. For TOML that
  somebody is [sam701/zig-toml](https://github.com/sam701/zig-toml) — ~2,000
  lines, arena-backed, already on 0.16's `std.Io`. For YAML there is no
  finished answer to depend on and that is the argument rather than a gap:
  [kubkon/zig-yaml](https://github.com/kubkon/zig-yaml) skips 322 of the ~400
  cases in the official suite, written by a Zig core contributor, and a partial
  YAML parser misreads real files quietly instead of refusing them. `.env` is
  the one that stays open, in that module's own list.
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
