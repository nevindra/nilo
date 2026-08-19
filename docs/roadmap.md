# Roadmap

What is coming, what is refused, and what nobody has decided yet. Nothing else.
Once something is built its entry leaves this file: what shipped is in
[`CHANGELOG.md`](../CHANGELOG.md), what was measured and learned on the way is
in [`history.md`](./history.md), and the decisions that are binding are in
[`adr/`](./adr/).

What this document is measured against is
[ADR 0015](./adr/0015-what-nilo-borrows-and-from-whom.md): **the signature is
the whole contract**, on a server whose memory you can put a number on. A
feature that does not serve one of those two is not automatically refused, but
it has to say what it is for.

[How this file is written](#how-this-file-is-written) is at the bottom, and it
is the part to read before adding to it.

## How to read this

Every module carries the same three lists, in the same order, and a module says
so when one of them is empty.

| List | What is in it |
|---|---|
| **Next** | queued work. Somebody could start it on a Saturday |
| **Known gaps** | what is wrong today, with what fixing it would take |
| **Not decided** | a question nobody has answered. Not a backlog item |

**Every entry ends with one line saying what it is waiting for**, and that line
is the fastest way through this file. Search for `Waiting on: ready` and you
have the work that nothing is blocking.

| Waiting on | What it means |
|---|---|
| **ready** | nothing is in the way. It needs somebody's afternoon |
| **a caller** | the design is known and nobody has needed it yet. Bring the use case, not the patch |
| **a number** | somebody has to measure before this can be decided |
| **a machine** | a benchmark box rather than a shared vCPU |
| **a harness** | a test shape the suite does not have |
| **upstream** | the change is in somebody else's repository, and the entry names which |
| **accepted** | this is the answer rather than a gap waiting to close. It is written down so nobody re-derives it |

An entry under **Not decided** ends with `What would settle it` instead,
because an open question is not blocked. It is unanswered, and what a reader
wants to know is which evidence would end the argument.

**A `Waiting on: upstream` is the line to distrust.** This repository has
been wrong about a blocker four times, and three of those were somebody else's
code that turned out to already do the thing
([history](./history.md)). Nothing downstream ever re-tests a blocker, so
re-test it before repeating it.

## The modules

nilo is a toolkit whose largest module is a server, rather than a server with
things beside it ([ADR 0041](./adr/0041-a-module-sits-where-the-loop-puts-it.md)).
One queue mixing them together hides the fact that decides how the work gets
done: **two modules touch no file in common**, so two of the lists below can be
worked at the same time, by two people or by one person on two days. A number
under **Next** is a position in that module's queue and says nothing about any
other module's.

| Module | Layer | Where its work is |
|---|---|---|
| [`nilo_core`](#nilo_core-the-vocabulary) | needs no loop | one deadline that never got its second caller, and where `convert` belongs |
| [`nilo_id`](#nilo_id-identifiers) | needs no loop | quiet. Two questions about scope, one gap nobody has hit |
| [`nilo_config`](#nilo_config-settings) | needs no loop | reading a name the field is not called |
| [`nilo_pw`](#nilo_pw-hashing-a-password) | needs no loop | a Cost floor that weighs the wrong half, and a patch `std` should have |
| [`nilo_fetch`](#nilo_fetch-calling-somebody-elses-api) | borrows the loop | 16,495 bytes of stack per idle connection, and nothing measured through TLS |
| [`nilo_http`](#nilo_http-the-server) | owns the loop | the biggest list: a weak `If-Range`, a kilobyte of logger on a live frame, compression, counters |
| [`nilo_sql`](#nilo_sql-postgres-and-sqlite) | borrows the loop | which way a SQLite statement should run, and where migrations live |
| [`nilo_s3`](#nilo_s3-object-storage) | borrows the loop | nothing measured through TLS, and no `LIST`, `COPY` or multipart |

Everything that is about the repository rather than one module stays whole at
the bottom: [modules that do not exist yet](#modules-that-do-not-exist-yet),
[what is not coming](#not-coming), [which Zig](#zig-versions), and
[the standing risks](#the-standing-risks).

---

## `nilo_core`: the vocabulary

`Str`, the `Lifetime` behind it, and the `Scope` that lets a Service allocate
for a request without naming a server. It is the smallest module on purpose: a
file earns its way in by being needed by two layers, not by having nowhere else
to live ([ADR 0042](./adr/0042-the-bottom-layer-holds-more-than-one-module.md)).

### Next

**1. A per-thread entropy pool, if a number ever justifies one.** `c.entropy`
reaches the operating system on every call. That is 56ns on a kernel serving
`getrandom` from a vDSO and roughly twenty times that on one that does not
([ADR 0046](./adr/0046-entropy-belongs-to-the-loop.md)). A CSPRNG seeded once
per thread would remove it, and costs stored state, a fork hazard and a seeding
moment. This is written down so whoever finds the workload knows the design was
priced rather than missed.

**Waiting on: a caller.** Nobody has a workload that needs it.

### Known gaps

**A query outside a transaction cannot be bounded by time.** `core.Limits`
bounds an operation that is not a read or write of a connection nilo holds
([ADR 0065](./adr/0065-the-way-out-was-open-the-clock-was-not.md)), and
`nilo_fetch` uses it. `nilo_sql` does not: a plain `db.select` still has no
deadline, and the mechanism it would use exists.

This entry used to say a Service had no supported way to dial out at all, and
it was wrong in every detail it gave. pg.zig names no zio, and `std.Io` is
handed to a Service by `ready(state, io)`
([ADR 0040](./adr/0040-a-service-that-needs-the-loop-is-finished-when-the-loop-exists.md)).
The way out was already open. The paragraph that said otherwise was written
from the shape of the Bulkhead rather than from reading either dependency,
which is the reason the note above about upstream blockers is in this file.

**Waiting on: ready.** The remaining half is [`nilo_sql`'s](#nilo_sql-postgres-and-sqlite),
and it is a design question there rather than a missing mechanism here.

**The layering step cannot tell a test import from a real one.** `zig build
layering` refuses an import that is not in that module's row of the `layers`
table, and `sql/db.zig` legitimately names `nilo_http` from a `test` block.
Telling the two apart needs a parser rather than a scan, so the table has an
`in_tests` list the step allows and does not verify. A rule with a listed
exception still beats a rule in a document. This is the part of it that is
weaker than the rest.

**Waiting on: accepted**, until the exception list gets long enough to hide
something.

### Not decided

**Where `convert` belongs.** Turning text into a type is what a Core wants, but
`convert.zig` reaches the Bulkhead to say a request failed. Either its failures
come back as a value the caller turns into a 400, or it stays in the App layer
and Core gets a smaller converter under the same rules.

Two candidates have already come and gone. `nilo_config` was written down as
the second caller and **is not one**: sharing means naming `nilo_core` for
`Str`, and a bottom-layer module that does gives up running under a plain `zig
test`, which is the entry condition for the layer
([ADR 0043](./adr/0043-a-setting-is-a-field-and-every-bad-one-is-named-at-once.md)).
`percent.zig` was the likelier candidate and went to Core **without answering
this** ([ADR 0066](./adr/0066-percent-is-needed-by-two-layers.md)), because
neither direction of percent coding can fail, so there was no failure to hand
upward. That was the cheap half.

**What would settle it: a caller in the App or Service layer.** One below
cannot afford to reach for it, which is what both false starts proved.

---

## `nilo_id`: identifiers

A `Uuid` and the two layouts anybody writes, v4 and v7. It imports nothing at
all, which is the strongest form of what the bottom layer is for.

### Next

Nothing queued.

### Known gaps

**A v7 is not sortable within a millisecond.** Two made in the same one come
back in random order relative to each other. RFC 9562 allows a counter in
`rand_a` and this has none, on the grounds that it buys ordering nobody asked
for at the price of a threadlocal. A service inserting a batch in a tight loop
is exactly the caller who would notice.

**Waiting on: a caller.** Nobody has looked at whether that happens in
practice.

### Not decided

**Whether any other identifier belongs here.** ULID, nanoid and Snowflake are
each a different trade of length against sortability against coordination, and
a module holding all of them is a catalogue rather than a decision.

**What would settle it: the argument UUID had.** It is here because a database
column has that type. Nothing else has that argument yet, and "somebody might
want it" is not one.

**Whether v3 and v5 belong here.** They are a hash of a name in a namespace,
which is a different job from making one nothing has ever used.

**What would settle it: a way to have them without shipping two broken
hashes.** They need MD5 and SHA-1, so the first caller who asks makes this
module carry both.

---

## `nilo_config`: settings

A struct of your own filled from the environment, with **every** bad setting
named at once rather than the first
([ADR 0043](./adr/0043-a-setting-is-a-field-and-every-bad-one-is-named-at-once.md)).
It imports nothing, allocates nothing, and is over before the socket opens.

### Next

**1. A name that is not the field's own.** `database_url` reads `DATABASE_URL`
and there is no way to say otherwise, so a platform that already owns a name
has to be met by renaming the field. `PGURL`, or `PORT` meaning something else
in the same container. A marker in the reader's own struct is the shape the
rest of nilo uses (`nilo_table`, `nilo_resolve`), and the work is one comptime
lookup.

**Waiting on: a caller** who cannot rename the field, which is the same test
every other marker had to pass.

### Known gaps

**`config.Env` is POSIX only.** It reads the environment block where it lies,
which is what makes the whole module allocate nothing, and Windows moves that
block. `config.Map` is the portable half and takes the `environ_map` that
`std.process.Init` already hands to `main`, so nothing is unreachable. It just
costs the map, and the `@compileError` on `Env.get` says which to use rather
than letting the failure come out of the standard library.

**Waiting on: accepted.** The allocation-free property is worth more than one
uniform call.

**A prefix is per reading, not per Config.** `fromWith(T, .{ .prefix = … })`
has to be written at each call, so two places reading one Config can disagree
about it. Making the prefix part of the type would fix that and cost `Read(T)`
its one-type-per-`T` property, which is what lets a function take a reading
without naming the prefix it was read with.

**Waiting on: a caller** who has actually disagreed with themselves.

### Not decided

**Whether a Config can say a setting is secret.** Marking one would let
`report` and any future logging print `PGPASSWORD=***` rather than the value.
It is a small feature with a large blast radius if it is trusted and wrong: a
value marked secret and printed anyway is worse than one nobody claimed
anything about.

**What would settle it: something here logging a Config.** Nothing does, so
there is nothing to redact yet.

---

## `nilo_pw`: hashing a password

argon2id as a pure function of a password, a salt and a Cost, plus the two
`Ctx` methods that take the salt from the loop and a permit from the Gate
([ADR 0048](./adr/0048-a-password-hash-is-gated-because-forgetting-is-silent.md)).
It imports nothing at all, and a project that never signs anybody in links none
of it, measured at 0 bytes.

### Next

Nothing queued.

### Known gaps

**The Cost floor only weighs memory.** `Cost.floor_memory_kib` refuses anything
under 7 MiB, which is OWASP's weakest published configuration. But that
configuration is 7 MiB *and five passes*, and `.{ .memory_kib = 7 * 1024,
.passes = 1 }` is a quarter of the work and compiles. A floor on `memory_kib *
passes` would catch it, and would also refuse this repository's own test Cost,
which is how the suite affords two optimize modes
([ADR 0049](./adr/0049-a-hash-asks-for-the-pages-it-walks.md)).

**Waiting on: a design** for being cheap in a test suite that is not also a way
to be cheap in production.

**A password longer than a page costs what it is.** Argon2 hashes the whole
input, so a client posting a megabyte gets a megabyte hashed. `max_body` bounds
it at one megabyte by default and the Gate bounds how many at once, so it is
not an opening. But everybody else truncates at 72 bytes or pre-hashes with
SHA-512, and nilo does neither.

**Waiting on: a decision** about which of the two, which nobody has made.

### Not decided

**Whether a memory-bound deployment gets bcrypt.** It is in `std`, it costs
zero heap against argon2id's 19 MiB, and it is 2.6× slower for the trouble
(ADR 0048 has the numbers). The trade is real for a small machine holding many
connections.

**What would settle it: somebody on one.**

**Whether the Gate belongs to more than passwords.** `bulkhead.Gate` is
general, a counting lock that tells the detector it is waiting, and password
hashing is its only caller.

**What would settle it: a second caller.** Image resizing, or a report that
holds a core, would decide whether it is a public name or stays internal.

**Who sends `std` a vectorised argon2.** `std.crypto.pwhash.argon2` does its
16-word permutation one word at a time. Written as four `@Vector(4, u64)`
lanes, the shape the reference implementation has had since 2015, the same hash
is **11.19 ms instead of 13.78**, and 8.98 out of `pw.huge_pages`, with
byte-identical output at every shape it was checked at. nilo will not carry a
copy of somebody else's crypto to get it
([ADR 0049](./adr/0049-a-hash-asks-for-the-pages-it-walks.md)).

**What would settle it: somebody sending the patch.** It is upstream's to take.

---

## `nilo_fetch`: calling somebody else's API

Sixty-five lines of policy in front of `std.http.Client`: a gate on calls in
flight, a deadline per call, a bounded drain, a body ceiling, and a body that
comes back as a `Str` in the caller's Scope. The first **Fitting**, which
borrows the loop and owns no destination
([ADR 0070](./adr/0070-a-fitting-borrows-the-loop.md)).

### Next

Nothing queued.

### Known gaps

**A plain call costs 16,495 bytes on every idle connection**, which is the
largest per-connection number in the framework. It is fiber stack rather than
buffers: moving the two client buffers into the request arena was tried and is
worth −66 bytes. The lever is in `http/`, giving *stack* pages back between
requests, the `MADV_DONTNEED` treatment the connection buffers already get and
stacks never have
([ADR 0063](./adr/0063-a-handlers-stack-is-per-connection.md)). It would pay
for every handler in the framework rather than only this one.
[`bench/result/fetch.md`](../bench/result/fetch.md) has the routes and the two
theories that died.

**Waiting on: ready**, and it is the highest-value item in this file, because
it is one change that moves every handler.

**Nothing is measured through TLS.** Every figure in `bench/result/fetch.md` is
`http://`, and the 59,151 bytes per HTTPS connection is std's number read out
of its buffer sizes rather than one this repository has put on a scale. That is
3.6× the plain-HTTP figure, if it holds.

**Waiting on: ready.** `zig build smoke-tls -Dnetwork` already reaches a real
endpoint; what is missing is the measurement beside it.

**A certificate bundle is loaded per client, not per process.**
`std.http.Client` rescans the system roots the first time it makes an HTTPS
request. One client per program is the shape the docs push, so this has not
bitten, but two would pay twice and nothing says so at the call site.

**Waiting on: a caller** who genuinely wants two clients.

### Not decided

**Whether retries belong anywhere.** How many times, how long between, and what
counts as a failure are facts about somebody else's service. A caller who knows
them can write three lines. A default that guesses them turns one outage into a
thundering herd.

**What would settle it: a shape that takes the policy as a type rather than a
number**, which is the same test every other feature here has had to pass.

---

## `nilo_http`: the server

### Next

**1. Reloading without a restart: static files, then the server.** A
development annoyance rather than a design hole, because a deploy restarts
anyway. The static half is a watch option on `staticWith`, re-reading a
directory that has changed. The other half is the whole process and cannot live
inside `App`, because a running binary cannot rebuild itself, so it belongs in
the build alongside `zig build run`. jetzig's dev server sums the modification
times of its source tree and rebuilds when the sum moves, which is about as
much machinery as this deserves. The part to be careful about is that neither
half can end up in a release binary.

The static half stopped being purely a convenience when files began spilling to
disk. See the stale-length gap below, which this is the fix for.

**Waiting on: ready.**

**2. `permessage-deflate`.** Negotiated in the handshake, and a compressor per
connection is memory that has not been budgeted.

**Waiting on: a number.** The per-connection cost has to be priced against the
4,669 bytes an idle connection holds today.

**3. CORS that can name more than one origin.** `cors.Options.origin` is a
single compile-time string, so an application with a production front end and a
staging one cannot use the middleware at all and writes its own. The shape that
fits is `origins: []const []const u8`, compared against the request's `Origin`
header with one comptime-unrolled `eqlIgnoreCase` per entry, echoing back the
one that matched. Nothing is formatted and nothing is allocated: every candidate
is already a literal, and the value that goes out is one of them. A list of one
behaves exactly as today, and `"*"` stays the way to say "anyone".

The axis is throughput, and it is paid only by a request that carries an
`Origin` header: N compares against short literals, where N is what the
application wrote. Nothing per connection, nothing per request that is not
cross-origin.

`Vary: Origin` is already repeated rather than replaced
([ADR 0089](./adr/0089-two-layers-can-each-name-a-vary-axis.md)), so the caching
half of this is done and what is left is the matching.

**Waiting on: ready.**

### Known gaps

**`If-Range` accepts a weak validator, which is the one comparison the RFC says
must be strong.** `static.etagMatches` strips a `W/` prefix and honours `*`.
Both are right for `If-None-Match` and neither is right for `If-Range`: RFC 9110
§13.1.5 asks for strong comparison there, and a weak tag means "close enough to
reuse, not byte for byte the same", which is exactly the claim a resumed
download must not act on. `static.etagForSpilled`'s own doc states that rule as
the reason nilo's tags are strong, so the design knows it and the shared
comparison does not.

nilo only ever writes strong tags, so reaching it takes a client that wraps a
tag it was given in `W/`. Latent rather than live, and one function away from
being impossible.

There is a narrower second half. `sendfile.send` guards its `If-Range` with
`contents.etag.len > 0` and says why: `etagMatches` would otherwise let a bare
`*` stand in for a comparison that never happened. `App.serveHeldFile` has no
such guard. Unreachable today, because `static.load` gives every held file a
tag, but the two arms of one feature disagree while `serveHeldFile`'s own doc
claims there is exactly one copy of each rule.

A second entry point, `etagMatchesStrong`, used by both `If-Range` callers. A
cold header, no allocation, nothing per connection.

**Waiting on: ready.**

**`Expect: 100-continue` is never answered, so curl waits a second before
sending an upload.** Nothing under `http/` reads the header. A client that sends
it and waits gets no interim response, so it falls back on its own timer:
curl's is one second, and it is one second on every upload past its threshold.
RFC 9110 §10.1.1 also allows answering the *final* status without reading the
body at all, which is the better half of the feature and is what turns a
rejected 20 MB upload into a 413 that costs nothing to send.

The write is 25 bytes and the read is one more arm in `applyHeaderAt`'s switch
on name length. No allocation, nothing per connection, and nothing at all for a
request that does not send the header.

**Waiting on: ready.**

**A `Room`'s roster lock is held across the whole broadcast, and the field says
it is not.** `Room.roster`'s doc says it guards taking and giving up a seat and
is "not held while posting". `Room.handOut` takes it and holds it for the whole
loop over the roll, so `join` and `leave` queue behind every broadcast.

What is there is correct, and the doc is the half that is wrong, but it cannot
simply be rewritten to match. `Room.leave`'s own comment ("a `say` already past
the roster may be pushing into this ring right now") is written for the design
the doc describes, and `takeSeat` does not drain a seat's ring before handing it
out. Release the roster before the loop and a post landing between `leave`'s
drain and the next `takeSeat` is delivered to whoever sits down next, because
the era check passes.

So there are two ways out and they are not the same size. Correcting the doc is
a paragraph. Making the code match it means draining in `takeSeat` too, and then
showing the contention was real.

**Waiting on: a harness.** Nothing measures a Room at all. `bench/ws_server.zig`
runs the chat loop from `examples/chat/` with the room deliberately taken out,
so every WebSocket number in [`bench/result/http.md`](../bench/result/http.md)
is a socket that joined nothing.

**The logger puts a kilobyte on a frame that is live while the handler waits.**
`logger.with`'s inner `log` declares `var buf: [1024]u8` and is a plain `fn`, so
it is a candidate for inlining into `run`, whose frame is live across
`next.run(c)`.
[ADR 0071](./adr/0071-where-a-connection-waits-is-what-it-costs.md) §3 is the
rule this breaks, in its own words: a format string costs stack whether or not
it is ever printed, and four `std.log.warn` sites nobody hits were most of
`handleConnection`'s 4,184 bytes. The remedy there was `noinline` on seven
functions and nothing else.

A WebSocket is not affected: the socket loop runs from `App.handleConnection`
after the request has unwound (ADR 0071 §4). What is affected is anything that
suspends *inside* the handler, which is a database call, an outbound call, and
an SSE stream, and a stream suspends there for as long as it lives. ADR 0063
measured an ordinary database route at 17,022 bytes
([`bench/result/http.md`](../bench/result/http.md)).

**Waiting on: a number.** `noinline fn log` is a one-word change. Whether it
moves `python3 bench/mem.py` against a route holding a stream is what nobody
has run.

**Ten doc comments came unstuck from what they describe, and two of them name
things that are gone.** A doc block that loses its blank line runs into the next
one, and both land on the following declaration. It has happened ten times:
`App.findStatic`'s doc sits on `StaticHit`, `App.drain`'s on `checkRootWiring`,
`App.sameService`'s on `rebase`, `Ctx.body`'s on `aboutToRead`, `Ctx.events`'s
on `upgrade`, `bulkhead.dontNeed`'s on `releaseScratchPages`,
`bulkhead.Deadlines`'s on `Woken`, `zio.releaseIdleStack`'s on `margin`, and
twice more inside `websocket.Socket`. Every time, the function that was
described now has no doc and the one that inherited it has two.

The largest is the worst. `releaseIdleStack`'s doc is the whole account of ADR
0071's arithmetic, including the three properties that keep its `madvise` off a
neighbouring fiber's live stack, and it is filed under a constant.

Two also name identifiers that no longer exist. `websocket.zig` says
`App.waitOrRelease`, which ADR 0071 renamed to `waitForRequest`, and it says the
scratch slot points at `Ctx._ws_scratch`, which is not a field `Ctx` has. The
slot is on the handover value in `App.handleConnection`.

Nothing on any axis. It is a morning of reading, and the reason it is here
rather than done is that nothing catches the next one.

**Waiting on: ready.**

**Four files print nilo's own file names in their compile errors.** `names.zig`
exists because a message saying `str.Str` sends a reader looking for a `str`
module they never imported, when their import line says `nilo`. Three files ask
it: `session.zig`, `resolve.zig` and `service.zig`. Four do not, and between
them they carry twenty-five `@typeName` calls inside `@compileError` text.
`jsonmark.zig` has fourteen, `websocket.zig` eight, `typed.zig` two and
`openapi.zig` one. So a WebSocket loop whose first argument is wrong is told it
should be `*nilo.Socket` and that what it has is a `*ctx.Ctx`.

The table itself is hand-kept and has fallen behind `http.zig`'s exports:
`Bound`, `Session`, `FileBody`, `Dir`, `Stream`, `Events`, `Body`, `Socket`,
`Room`, `Limits` and `Gate` are all missing from `names.ours`. Its own doc says
a missing type is meant to be noticed in `refusals/`, and none of these was.

Comptime only, on a path that never reaches a binary. `refusals/` is where the
rule could stop being a paragraph
([ADR 0027](./adr/0027-the-rule-about-error-messages-is-held-by-a-build-step.md)).

**Waiting on: ready.**

**The two arms of static-file serving live in two files, and the rule they share
lives in a third.** `App.serveHeldFile` answers a file read at startup,
`sendfile.send` answers one that spilled, and `static.etagMatches` and
`range.parse` are what they have in common. `serveHeldFile` carries a twenty-line
doc explaining which lines are shared and which cannot be, which is the sign
that the seam is in the wrong place: it is the only part of `app.zig` that is
about static files rather than about serving requests, and it is where both
`If-Range` gaps above diverged.

`app.zig` is 7,053 lines, of which 1,878 are code and 5,175 are tests, so the
file is smaller than it looks. The code half still holds the App builder, route
registration, groups, `listen`, the connection loop, the request path, static
file serving and failure assembly. Lifting the static arm out next to
`sendfile.zig` is the one cut with an obvious line. `headerValue(c, name)` is
copied into both files as it stands, four lines each.

**Waiting on: a caller.** Nothing is wrong today, and moving code that works has
to be worth the diff. The next change to either `If-Range` arm is the caller.

**A service is found by scanning the registry on every request that wants one.**
`service.Registry.get` walks `entries` comparing type names, with a pointer
compare first and a content compare behind it, once per service argument per
request. Which services a route needs is settled while compiling and `listen`
already checks every one of them, so this is work repeated at request time that
a startup pass could turn into an index.

It may well be nothing. An app with four services and a handler taking one is
four pointer compares. It is written down because it is on the request path and
because `zig build profile` is exactly the harness for the question.

**Waiting on: a number.**

**`Router.add` and `Router.conflicting` disagree about a segment that is only a
colon.** `add` calls a segment a param when it starts with `:`
(`part.len > 0`), so `/a/:` registers a param with an empty name. `conflicting`
calls it a param only when something follows the colon (`part.len > 1`), so it
reads the same segment as the literal `":"`. Registering `/a/:` twice therefore
reports no conflict and leaves two routes matching the same requests, one of
them unreachable.

Degenerate, and nobody writes it on purpose. What earns it a line is that these
are two copies of one classification, and the copy deciding what a route *is*
has already drifted from the copy deciding whether two routes *collide*. One
function used by both is the fix.

`add` also asserts `std.mem.count(u8, pattern, ":") <= max_params`, which counts
a colon anywhere, so a literal segment containing one spends the param budget.
An assert, so it is a Debug panic and unchecked in `ReleaseFast`.

**Waiting on: ready.**

**`websocket.counted` and `room.sizeOf` are the same nine lines, comments
included.** Both take a writer function and a value, run it into a
`std.Io.Writer.Discarding` over a 256-byte scratch buffer, and hand back the
byte count. They differ in their return type (`u64` against `usize`) and in
nothing else, down to the wording of both comments. One copy belongs somewhere
both can reach, which inside `http/` is anywhere.

Nothing on any axis: the same code once instead of twice.

**Waiting on: ready.**

**What an open stream costs has not been measured since v1.**
`docs/guide/streaming.md` quoted **~21 KB** a stream and told the reader to plan
ten thousand of them around it. That figure predates both
[ADR 0063](./adr/0063-a-handlers-stack-is-per-connection.md), which found a
handler holds its stack at its high-water mark, and
[ADR 0071](./adr/0071-where-a-connection-waits-is-what-it-costs.md), which took
an idle connection to 4,669. A stream is neither: it is a handler that has not
returned, so it holds its buffers *and* its stack, and neither of the two
findings tells you what the total is. The guide now says that instead of
quoting the number, which is the honest state and not the useful one.

`bench/mem.py` is the harness and `examples/stream` is a server that holds one,
so this is a run rather than a design. What it wants beside it is a control —
the same server holding an ordinary keep-alive connection — for the reason
`bench/sql_server.zig`'s fourth route exists.

**Waiting on: ready.**

**An internally tagged union is read four times, and the module says the marker
costs nothing per request.** `jsonmark.zig`'s header says "Nothing per request
and nothing per connection: the marker is read while compiling", and on the
write side that is true and measured. On the read side `Reader.parse` calls
`skipValue` to find the span, `fromSpan` scans it for the discriminator,
`parseFromSliceLeaky` parses it for the variant's fields, and `refuseUnknown`
scans it a fourth time because `ignore_unknown_fields` had to be turned on to
get past the tag. `ctx.json` parses with default options, so the fourth pass is
not optional. Two of the four build a `std.json.Scanner` with an allocator.

The comment in `parse` says the second look "costs a scan and nothing else",
which is the honest description of one of the three extra passes.

It is per tagged value, not per body, so a small object is nothing and an array
of a thousand is four times the parse of every element. Nobody has measured
either.

**Waiting on: a number.** `bench/result/http.md` has the write side (258ns down
to 93ns on a 374-byte alert rule) and nothing at all for the read side.

**A multipart part that names its file only with `filename*` becomes a text
field.** `parseMultipart` decides a part is a file by asking `parameterOf` for
`filename`, and `parameterOf` compares the key exactly, so `filename*` does not
match. `form.zig` says the encoding is deliberately not read and gives the
reason: "the plain `filename` is always sent alongside it". That is true of
browsers and is not true of every HTTP library.

What happens when it is not true is the part with a wrong answer. The part is
not refused and is not read as a file; it is bound as a *text* field whose value
is the raw bytes of the upload, and the `Upload` field the endpoint asked for is
reported missing. So the 400 names the wrong thing.

Refusing a part that has `filename*` and no `filename` is a sentence rather than
a decoder, and it is the same call ADR 0081 makes about a ceiling: nilo need not
read the encoding, it only has to stop pretending the part was something else.

**Waiting on: ready.**

**`Socket.print` runs the format twice and never checks that the two agree.**
The frame's length is written from the counting pass and the bytes come from the
writing pass, so two passes that disagree put a length on the wire that is a lie
and the connection desynchronises. The doc names the hazard and hands it to the
caller: "the arguments are therefore read twice: pass values, not a window onto
memory another fiber is writing."

`Room.print` has the same two passes and asserts between them
(`std.debug.assert(into.end == post.len)`), because it writes into a buffer it
can measure. `Socket.print` and `Socket.json` write straight to the connection
and assert nothing, so the one place the mistake is unrecoverable is the one
place it is unchecked.

Counting the bytes `_out` actually took and asserting they match is a `Debug`
and `ReleaseSafe` check, which is where the suite runs and is not where anybody
deploys. Zero cost in `ReleaseFast`.

**Waiting on: ready.**

**`pw.verify` takes a `Ctx` it does not use.** The first line of `verifyWith` is
`_ = c;`. Hashing needs a `Ctx` because the salt comes from `Ctx.entropy`
([ADR 0046](./adr/0046-entropy-belongs-to-the-loop.md));
verifying reads the salt out of the stored string and needs nothing. So the
parameter is there for symmetry, and what it costs is that a password cannot be
checked outside a request: a CLI that resets an account, a migration that
re-hashes, a background job, and a test that wants neither an App nor a fake Ctx
all have to go through `nilo_pw` directly and lose the Gate.

Dropping the parameter is a breaking change to a signature that shipped, which
is why it is here rather than done. The other shape is a free function beside
it, which is a second name for one job.

**Waiting on: a caller** who wants to verify a password without a request in
flight.

**There are no counters.** Correlation is covered, with request ids and JSON
log lines ([Errors and logging](./guide/errors.md)), but metrics are not: how
many requests, at what statuses, how long. That is a much larger surface than a
log line. Where the numbers live, who reads them out, whether there is a
registry, and whether any of it can be had without an allocation per request.

**Waiting on: a design.** Nobody has drawn one.

**A response body is never compressed, and only a held file is.** Static files
under the spill threshold are gzipped once while the App is built, which is the
shape that costs nothing per request
([static files](./guide/static-files.md#compression)). A file over it is opened
per request and so has no "once" to be compressed in
([ADR 0037](./adr/0037-a-file-too-big-to-hold-is-opened-not-read.md)), and in
practice a file that large is a video or an archive and is compressed already.
A handler returning JSON gets no such thing either.

The reason is the one that shaped the static half. A deflate compressor needs a
64 KB window, so one per connection would multiply the 4,669 bytes an idle
connection holds, and one per request would break the allocation budget
([ADR 0018](./adr/0018-the-trade-budget-has-three-axes.md)). **The shape that
fits is a pool of compressors sized to the thread count rather than the
connection count.** Four cores, 256 KB, and a request borrows one for as long
as it is writing.

**Waiting on: a design.** What happens when the pool is empty, what it does to
a stream, and what it does to SSE, which is the one thing that must never be
buffered. A proxy in front does this today and does it well.

**Writing a megabyte costs 2.2× what axum charges for it, and nobody has
looked.** On a route that allocates a megabyte, fills it and writes it, with no
database and no object store anywhere near it, axum answers 18,160 req/s and
nilo 8,215 on the same three cores
([`bench/result/s3.md`](../bench/result/s3.md)). It turned up as a *control* in
the object-store comparison, which is the only reason it was seen.

The first hypothesis to kill is the arena. Allocating a megabyte per request
from an arena that resets keeping `arena_keep` bytes means fresh pages and 256
page faults every time, where a general allocator hands back the same warm
block. Raising `arena_keep` past a megabyte on that route is a one-line
experiment.

**Waiting on: ready.** Unrun, so the 2.2× is the only fact here.

**A spilled static file that changes on disk serves a stale length.** A file
over the threshold has its size, mtime and ETag recorded at load and its bytes
opened per request, so editing one under a running server splits what used to
be one consistent copy. Shrinking it is caught: fewer bytes arrive than the
head promised, so the connection closes rather than letting the client read the
next response as the rest of this body, and the log says which request it was.
Growing it is not caught. The first recorded-length bytes go out under the old
ETag, which is a complete, correct-looking response carrying a prefix of a file
that has moved on.

Both are the same instruction as before, that changing a file means restarting.
But a held file could not fail this way and a spilled one can.

**Waiting on: Next 1**, the watch option, which is why this is not an item of
its own.

**The API description is silent about authentication.** A handler taking a
`CurrentUser` needs an `Authorization` header and the document does not say so,
because the header is a line of Zig inside the resolver rather than something
in a type.

**Waiting on: a design** that does not become a second thing to keep in step
with the resolver. That drift is what the generated document exists to avoid.

**The API description names one failure, and endpoints have several.** `!?T`
puts a 404 in the document because the signature settles it
([ADR 0024](./adr/0024-a-failure-mode-belongs-in-the-return-type.md)). A
`fail.conflict` on a duplicate email is a line in a function body and stays
invisible. That is the rule rather than a gap, since the document promises what
the signature settles, but it is the rule that costs the most.

**Waiting on: a way to state a failure in a type** without inventing an
annotation.

**The linker cannot drop what nobody uses.** The API description costs +14 KB
on the hello example and +34 KB on rest whether or not `docs()` is called,
because the switch is a runtime `null` check
([ADR 0017](./adr/0017-the-api-description-comes-from-the-signatures.md)).
Fixing it needs a build option a `zig fetch` dependent has to thread through.
That argument was "a worse ergonomic problem than the one it solves" until
`.sql = true` shipped
([ADR 0075](./adr/0075-a-lazy-dependency-is-a-request.md)), so the shape is
known now and the objection is only about the size. One line in a
`b.dependency` call is a fair price for 11 MB of driver nobody downloads and a
poor one for 14 KB of binary nobody notices.

**Waiting on: a second option landing for another reason**, which this would
ride along with.

**`describeBadBody` walks eight levels and then stops.** Deeper than that the
400 says the ceiling was reached rather than which field is wrong
([ADR 0081](./adr/0081-a-ceiling-that-is-reached-is-said-out-loud.md)). Same
limit as the schema walker and the staleness trap, and for the same reason: a
type holding one of its own has to stop somewhere.

**Waiting on: a number.** Raising it is the part nobody has costed.

**The logged duration of a streamed response is its lifetime, not its latency.**
One line per request is the contract, and a stream's line arrives when the
stream ends. Time to first byte is a different number and wants a different
feature.

**Waiting on: a caller** who needs time to first byte.

**Nothing runs the Autobahn suite against the WebSocket.** `wstest` is the
thing every implementation of RFC 6455 is measured by, and nilo's framing tests
are all its own, written from the RFC rather than from a failing report. By
[ADR 0033](./adr/0033-a-guard-is-not-a-guard-until-it-has-been-seen-to-fail.md)'s
reading that makes the close-code and UTF-8 rules
([ADR 0052](./adr/0052-a-message-is-copied-once-and-framed-once.md)) guards
that have only ever been seen to pass.

**Waiting on: ready.** This used to want a harness that listens on a port and
drives a client at it, and **that harness now exists**: `fetch/deadline.zig`
and `zig build test-fetch-engine` stand a real server on a real socket and
assert on what comes back over it. What is left is writing the WebSocket and
`sendfile` cases into that shape.

**What a 60 KiB WebSocket message costs a busy server is unmeasured.** Every
WebSocket throughput figure in `bench/result/http.md` is a 64-byte payload,
which never leaves the first page of the buffer the executor lends a socket.
What a 60 KiB message costs at a thousand a second, where `http/scratch.zig`'s
byte budget starts refusing spares and the page allocator gets called on the
message path, is the number that would say whether `keep_bytes = 64 KiB` a
thread is the right size or a guess that happened to work.

**Waiting on: ready.** `bench/compare/wsload/` takes a `-payload`, so the run is
there. The interpretation is what is missing.

**The router is still a linear scan.** Indexing the first segment took 44% off
a hundred-route app and moved
[ADR 0001](./adr/0001-dx-wins-below-the-10-percent-threshold.md)'s 10% bar out
to around 40 routes, so what is left is the actual tree, for the app with
hundreds of them.

**Waiting on: a number.** The numbers no longer point at it urgently. `zig
build profile` is the harness for the day they do, and two attempts that lost
are written up in [`history.md`](./history.md) so they are not repeated.

**`inline_headers` went from six to seven and nobody has re-run the
per-connection figure.** Holding a seventh response header on the `Ctx` is 32
bytes on `serveRequest`'s frame, which is `noinline` and unwound before the
connection waits ([ADR 0089](./adr/0089-two-layers-can-each-name-a-vary-axis.md)),
so the reasoning says an idle connection is untouched at 4,669 bytes flat. The
reasoning is all there is: `bench/mem.py` reads `ss` and `/proc/<pid>/VmRSS` and
the change was made on Darwin, where neither exists.

ADR 0063 is the reason this is written down rather than assumed. A per-connection
claim reasoned from the shape of the code, and repeated in six files, was half
wrong for two milestones.

**Waiting on: a machine.** One Linux box and `python3 bench/mem.py --port 8787
--path /health` against `zig build run-hello` settles it in a minute.

**A 404 or a 405 with middleware registered costs one allocation.** Routes and
static files have their chains resolved at `listen()`, so neither pays for the
middleware in front of it. The set of paths that are neither is every string
there is, so there is nothing to precompute for.

**Waiting on: accepted.** One arena allocation on a cold path, bounded by the
number of `use` calls.

### Not decided

**Rotating the session secret.** Changing the secret today signs everybody out
at once, which is correct and blunt. Doing better means a second key to decrypt
with and a decision about how long to keep it: how many keys, where the list
comes from, and what a cookie sealed under a dropped one does.

**What would settle it: somebody who actually rotates.** The blunt version is
not wrong.

**Signing out everywhere.** The other thing a sealed cookie cannot do. It is
valid until it expires, so revocation is not in the mechanism. The answer today
is a version number in the session checked against the row the handler was
fetching anyway ([guide](./guide/sessions.md#what-it-cannot-do)).

**What would settle it: an argument that nilo should have more of an opinion
than that.** Anything further is a store, which is the design
[ADR 0035](./adr/0035-a-session-is-sealed-into-the-cookie.md) declined.

**Multipart, streamed.** `Form(T)` reads a multipart body whole, bounded by
`max_body` ([ADR 0031](./adr/0031-a-form-is-the-body-read-by-another-rule.md)),
which is right for a form with a photo in it and wrong for a 2 GB video. The
streaming version wants a parser that resumes across reads and an `Upload` that
is a reader rather than bytes.

It inherits no answer from `sendfile`, which settled the outgoing direction
([ADR 0037](./adr/0037-a-file-too-big-to-hold-is-opened-not-read.md)): sending
is a length and a descriptor handed to the kernel, and receiving is a parser
that has to hold its place across reads.

**What would settle it: somebody designing it.** Until then the answer is
`c.bodyStream()`, which holds nothing and makes the framing the handler's
problem.

**`Last-Modified` and `If-Modified-Since`, beside the ETag.** nilo answers
`If-None-Match` and `If-Range` and nothing else, so a client that only sends
`If-Modified-Since` is handed the whole file every time. A spilled file already
knows its modification time, because that is half of what its ETag is made of;
a held file would need a `stat` at load that `static.load` does not do.

The cost is small and the risk is not the cost. Two validators mean two answers
that have to agree, and a 304 issued on a date while the ETag says otherwise is
the sort of disagreement nobody finds for a year.

**What would settle it: a client that sends one.** An ETag is what every browser
and CDN made this century sends, and a second validator for a case nobody has
produced is a second thing to keep in step.

**A schedule, rather than a loop around a sleep.** `app.spawn` starts work that
is not a request and `nilo.sleep` paces it
([ADR 0086](./adr/0086-work-that-is-not-a-request-belongs-to-the-server.md)),
which covers "every so often" and nothing else. Wall-clock times, "at 03:00 on
Sundays", and what happens when one run overruns the next are all arithmetic
the caller writes today.

Each of those is a policy with no answer that is right for everybody: whether a
missed run is dropped or caught up, whether two may overlap, whether the first
is at zero or at the interval. A type that made the caller state them would be
a schedule worth having; an `every(ms, f)` that picked them quietly would not,
which is why ADR 0086 refused that shape rather than deferring it.

**What would settle it: somebody who has written the loop twice** and can say
which of those policies they had to pick, and what they picked.

---

## `nilo_sql`: Postgres and SQLite

### Next

**1. Decide whether a SQLite statement hops or runs in the fiber.** The Wire
ships with the choice as a field that has no default, so every program says
which it wants and neither is a guess
([ADR 0073](./adr/0073-a-file-has-no-socket-to-wait-on.md)). What nobody has is
the number that should make one of them the advised setting. A hop costs a few
microseconds and so does a cached read, so `.in_fiber` is plausibly faster for
a lookup service and plausibly fatal for one that scans.

Both settings have to be measured unloaded and behind the pool, because
[`bench/result/sql.md` §2](../bench/result/sql.md) is the standing warning that
a per-operation saving measured only unloaded understated its worth at a pool
by two to three times.

Half the harness is built. `zig build bench-sql` has a SQLite arm that needs no
server and answers the *unloaded* half, but only for `.in_fiber`, because a hop
needs the Engine that program does not have. The loaded half wants
`bench/sql_server.zig` pointed at a SQLite `Db`, which does not exist yet and
is the smaller of the two jobs.

**Waiting on: a machine.** The counters that could be taken on a shared vCPU
have been ([§9](../bench/result/sql.md),
[`spike/sqlite_facts`](../spike/sqlite_facts/)). This is the one that cannot.

### Known gaps

**The SQLite half has no live test against contention.** The Wire's own tests
run one process, so the case the reader and writer split exists for has a
design and no test: two writers meeting, `busy_timeout` expiring, `Locked`
coming back.

**Waiting on: a harness.** A build step that stands up a second writer, which
here is a second process on the same file rather than a socket.

**Nothing tests what a transaction does when the socket dies.** `Tx.fresh`
clears the connection's server error before each statement, so a broken pipe
after a unique violation is no longer reported as `AlreadyExists`. The fix has
no test under it, because provoking a transport failure between two statements
of one transaction needs a socket the suite never opens. `Tx.revive` rides
along: it reads `conn.err` to tell an aborted transaction from a dead
connection ([ADR 0047](./adr/0047-a-deadline-needs-a-connection-you-hold.md)),
and only the first half of that has a test.

**Waiting on: a harness**, the same one `nilo_http`'s Autobahn gap wants, and
it now exists. `zig build test-fetch-engine` opens a real port.

**A query outside a transaction still has no deadline.** `tx.deadline(ms)`
covers the operation that holds a connection
([ADR 0047](./adr/0047-a-deadline-needs-a-connection-you-hold.md)). A plain
`db.select` takes whichever connection is free and gives it straight back, so
there is nowhere to put one that is not a second round trip per query. What
would close it is a pool-wide floor handed over in the startup packet, which
costs nothing per statement.

**Waiting on: upstream (pg.zig).** `auth.zig` builds its startup message
without the `startup_parameters` map it accepts, so the field goes nowhere. One
line there, then an option here. Until then it is `ALTER ROLE app SET
statement_timeout`, from the side that can already do it.

**A SQLite pool connection is a per-connection cost nilo has not had before.**
28 KiB opened, growing to 1,876 KiB once it has touched `cache_size` worth of
pages ([§9](../bench/result/sql.md)). That is not an idle HTTP connection's
memory, because a pool connection is not a request's, but it is memory an
operator has to multiply, next to a framework whose whole per-connection story
is 4,669 bytes.

**Waiting on: accepted**, and written down so nobody is surprised by the
multiplication.

**A pool connection carries result state for 32 columns whatever the Row has.**
pg.zig's `result_state_size` defaults to 32 and nilo takes the default, so a
two-column Row pays for thirty it will never fill. A few hundred bytes a
connection, held for the life of the pool. This module is the one place that
can size it honestly, because every statement is a comptime constant, so the
widest Row a `Db` can ever read is known before the program runs.

**Waiting on: ready.** It is small next to the stack finding
([ADR 0063](./adr/0063-a-handlers-stack-is-per-connection.md)) and it is free,
which is the only reason it is written down.

**`db.raw` is routed by its first keyword.** Exact for everything the module
generates, because the module wrote the text. A guess for `db.raw`, where the
text is the caller's
([ADR 0074](./adr/0074-one-writer-is-not-a-setting-it-is-the-database.md)). A
guess that goes the wrong way lands on a read-only connection and fails loudly,
**on a file.** On an in-memory database it does not, because SQLite's URI
`mode=` takes precedence over the open flags, so the backstop is absent in
exactly the environment a test suite reaches for first.

**Waiting on: a design.** Refusing a bare `:memory:` at `open` is what stands
in for it today.

**`insertMany` on SQLite is a Refusal, so a Row is not portable by itself.**
There is no `unnest` and no array parameter, and the batch form SQLite has
grows its own statement text
([ADR 0061](./adr/0061-the-second-dialect-is-the-test-of-the-seam.md)). Code
written against Postgres does not compile against SQLite if it batches. The
same applies to `.lock` and `tx.deadline`.

**Waiting on: accepted.** This is the seam refusing rather than lying, and it
is worth knowing before somebody plans a migration on the assumption that
swapping the Dialect is free.

**An enum column that has not named its type is not checked at startup.** An
enum carrying `pub const nilo_column = "user_role"` is judged like any other
column. One that does not is not, because a Postgres enum's type name lives in
the database and guessing it would fail honest schemas. What is still open
either way is the *values*: nothing compares the Zig enum's tags against the
type's, so a Zig enum that has fallen behind its table is found by the first
request that reads such a row.

**Waiting on: ready.** It means asking the database which values the type has,
which is a second introspection query and a Dialect that can spell it.

### Not decided

**Whether the line past one table moves.** The module reads and writes a single
table and refuses everything past *one table, conditions that filter rows*
([ADR 0039](./adr/0039-the-shape-of-a-query-is-settled-while-compiling.md)),
with `db.raw` as the way out. A join is where dialects disagree most, and a
builder's surface grows with the builder.

Joins, nested rows fetched with their parent, aggregates, `GROUP BY` and
subqueries are all downstream of this one answer, which is why they are a line
here rather than five items above.

**What would settle it: a shape that keeps the statement a comptime constant.**
Every property in ADR 0039 is downstream of that one, so anything that gives it
up is a different module.

**Migrations, and where they run.** This was written down as the other half of
the join question, which was wrong. ADR 0039's line is about the shape of a
`SELECT`, and a migration is DDL. The two are undecided for different reasons
and neither waits on the other.

Half the machine is already built. `schema.compare` reads the catalog, knows
which Postgres types each Zig type may be read out of, and reports a column
that is missing, wrongly typed or wrongly nullable. What it cannot do is look
the other way, at a column the table has and the Row dropped, and
`dialect.accepts` answers with the *list* a column may read out of, where
`CREATE TABLE` needs the one to write.

Three questions have no answer, and not one of them is about Zig.

- **A rename cannot be told apart from a drop and an add.** drizzle-kit asks
  the developer. Asking means an interactive CLI, guessing means silent data
  loss, and refusing means a tool that only works on schemas nobody renames.
- **Where the record of what has been applied lives**, who commits it, and what
  two branches that each add a migration do when they meet.
- **A data migration cannot be derived from a struct diff.** There is a
  hand-written half whatever happens to the generated one.

What *is* settled is where it runs. A migration is a CLI rather than a server,
so it links no router and no accept loop, which means it spends nothing on any
of the four axes because it is not in the process those axes measure. Nothing
blocks it there any more: `nilo_sql` takes a Scope rather than a `Ctx`, so a
migration is an ordinary program holding a `Run`.

The tooling it would carry is `generate` (DDL out of the diff `schema.compare`
already computes), `migrate` (apply, and record what was applied), `push` (the
diff straight at a database, no files in between), `pull` (Zig structs out of a
database that already exists) and `check` (two migrations written against the
same parent). **Seeding is the cheapest thing on this page** and needs none of
the three answers above: a seed is an ordinary program calling `db.insertMany`
against a `Run`, with no design left in it.

**What would settle it: an answer to the rename question**, which the other two
are downstream of.

### Measured against Drizzle

[Drizzle](https://orm.drizzle.team/) is the fair yardstick, and not because it
is popular. It refuses the same three things this module refuses, so what it
*does* carry is a worked list of what a library can owe a service without
becoming an ORM. On speed the two are already side by side, with eight other
libraries, in [`bench/result/sql.md` §8](../bench/result/sql.md).

Two whole areas come off before the list starts.

- **Runtime query composition**, Drizzle's `$dynamic`: a builder held in a
  variable and added to before it runs. This is the one thing this module
  cannot have rather than has not got, because the statement is a comptime
  constant. The answer past it is `db.raw`, and it always will be.
- **The validation packages**, `drizzle-zod` and its five siblings: they exist
  because a TypeScript type is gone by run time. A Zig struct is not, which is
  why one Row already feeds the query, the JSON body and the API description
  with nothing generated in between. Same for the ESLint plugin that catches an
  `update` with no `where`. That is a Refusal here, and the compiler holds it.

What is left splits three ways.

- **Refused on the record**, each with its ADR: indexes, unique constraints,
  foreign keys and check constraints
  ([0056](./adr/0056-a-view-is-a-table-that-cannot-say-what-is-not-null.md));
  set operations and CTEs
  ([0058](./adr/0058-a-set-operation-over-one-table-is-a-condition.md));
  several statements in one round trip
  ([0059](./adr/0059-a-round-trip-is-not-the-cost-worth-chasing.md)); automatic
  read-replica routing and a query cache
  ([0060](./adr/0060-a-second-database-is-a-second-type.md)).
- **Waiting on the two decisions above**: joins, nested rows, aggregates and
  subqueries wait on the one-table line; every tooling command waits on
  migrations.
- **Nobody has looked**: row-level security, and Postgres extensions.

A GUI over the database is not coming from here.

---

## `nilo_s3`: object storage

SigV4 and S3's semantics; the HTTP underneath is `nilo_fetch`
([ADR 0067](./adr/0067-most-of-an-s3-client-is-not-s3.md),
[ADR 0072](./adr/0072-an-object-store-is-a-service-that-dials.md)). A bucket is
a type and a key is not
([ADR 0068](./adr/0068-a-bucket-is-a-type-and-a-key-is-not.md)); a signing key
changes once a day ([ADR 0069](./adr/0069-a-signing-key-changes-once-a-day.md)).

### Next

Nothing queued.

### Known gaps

**`LIST` and `COPY`.** One sentence covers both: they are where S3 stops being
bytes at a key and starts being a document format. A list result is XML and a
type AWS wrote rather than one the caller did, which is the opposite of what
every other call here does. `COPY` carries its own trap for whoever adds it,
because S3 can answer a copy with **200 and an error in the body**, so a client
that checks the status is wrong.

**Waiting on: a caller** who wants them enough to hold the XML.

**Multipart upload, and therefore upload of unknown size.** `putStream` frames
by length because S3 does not accept chunked, so a body whose length is not
known before it starts has no way in. Multipart is the only way S3 offers, and
it is a protocol rather than a call: initiate, N parts each with its own ETag,
then a completion document listing them. XML again.

**Waiting on: a caller.**

**Nothing is measured through TLS**, the same gap `nilo_fetch` has. Every
figure in [`bench/result/s3.md`](../bench/result/s3.md) is `http://` against a
MinIO in a container. The scheme is not cosmetic here, because it decides
whether payloads are hashed: the plaintext numbers carry a SHA-256 over every
body that the HTTPS ones would not, and the HTTPS ones carry a TLS record layer
the plaintext ones do not. Neither is a correction that can be applied to the
other on paper.

**Waiting on: ready.**

**The comparison holds four candidates to a contract enforced by reading the
source.** Each has to hold the object rather than proxy S3's socket, and a
proxy would produce the same bytes while doing less work.
[`bench/compare-s3/README.md`](../bench/compare-s3/README.md) names the fix, a
route answering a hash of what the client read.

**Waiting on: accepted.** Unbuilt because the risk is currently zero.

**`bench/compare-s3/drive.py` cannot record a candidate that dies.** Bun leaks
about a byte per byte read and was killed by the kernel at 27 GB mid-sweep,
which lost the whole run rather than one column. It needs a per-candidate route
set and a DNF. Five of Bun's seven routes are obtainable today, and the
Zig-against-Zig row is the one the comparison most wanted.

**Waiting on: ready.** Confine `bun` to a cgroup when working on this, because
the OOM killer is global and took MinIO and an unrelated container with it.

### Not decided

**Arbitrary object metadata, `x-amz-meta-*` set by the caller.** Refused on a
performance argument rather than a taste one, which means it can be revisited
with a measurement instead of an opinion. SigV4 signs a sorted list of header
names, and a fixed header set makes that list a compile-time constant. Letting
a caller add headers puts a sort in every request.

**What would settle it: the number for that sort**, brought by whoever wants
the feature.

---

## Modules that do not exist yet

A section rather than a list inside somebody else's, because what decides
whether one of these gets built is a repository-level seam rather than anything
in a module that is already here.

**A `nilo_mail`, a `nilo_redis`, anything else that dials.** Nothing structural
is in the way. Each is a Fitting or a Service by one question rather than a
seam to design first: does it hold a connection to a named system, or is it
given an address per call
([ADR 0070](./adr/0070-a-fitting-borrows-the-loop.md))? `nilo_s3` is the worked
example of the second answer, and the most useful thing it leaves behind is
that `nilo_fetch` turned out to be the right size. It needed one addition,
`Exchange`, and no changes.

**Waiting on: ready**, and this is the most useful thing an outside contributor
could take on.

---

## Not coming

Not "later". Decided against, with the reasoning written down. This list is
about the repository, so it is what to check before proposing a change,
whichever module the change is in.

**Templates.** nilo is for building APIs and services, and rendering a page is
the thing it is not for. Two arguments point the same way. Rendering means
producing a string per request, which is an allocation per request, which is
the one axis [ADR 0018](./adr/0018-the-trade-budget-has-three-axes.md) treats
as a hard invariant rather than a budget: the 4,669 bytes and the single
allocation are what nilo has to sell, and a template layer spends both. And the
two shapes Zig actually offers are far apart with nothing argued for in
between, comptime-checked templates being a compiler of their own and runtime
string interpolation being a worse `std.fmt`.
[jetzig](https://www.jetzig.dev/) is built for that job and does it with zmpl,
which is a better outcome for everybody than a second half-answer here.

A `<form>` posted to a handler still works.
[`examples/forms`](../examples/forms/) is that, and `Bound(Form(T))` is what
makes its failures legible
([ADR 0036](./adr/0036-a-binding-hands-its-failures-to-the-handler.md)). **This
is a refusal of templates, not of everything on that side of the line.**
Whether some other convenience from the batteries-included world earns its
place gets decided one feature at a time, against the two numbers above.

**A config file parser: TOML, YAML, or any other.** `nilo_config` reads the
environment and hands `Fixed` to a program that has parsed something itself
([ADR 0043](./adr/0043-a-setting-is-a-field-and-every-bad-one-is-named-at-once.md)).
Writing one means weeks to reach where somebody else already is, and depending
on one means every project importing the module fetches it. For TOML that
somebody is [sam701/zig-toml](https://github.com/sam701/zig-toml): about 2,000
lines, arena-backed, already on 0.16's `std.Io`. For YAML there is no finished
answer to depend on, and that is the argument rather than a gap.
[kubkon/zig-yaml](https://github.com/kubkon/zig-yaml) skips 322 of the roughly
400 cases in the official suite, written by a Zig core contributor, and a
partial YAML parser misreads real files quietly instead of refusing them.

`config.Dotenv` is not the exception it looks like. It takes *text*, opens no
file, and needs no dependency at all
([ADR 0064](./adr/0064-a-dotenv-is-text-somebody-else-read.md)). What the module
refuses is the filesystem, and a format whose parser somebody else has to
maintain.

**A `recover` middleware.** Zig cannot recover from a panic at all, so there is
nothing to build ([ADR 0008](./adr/0008-no-recover-middleware.md)).

**TLS, and with it HTTP/2 and a gRPC server.** Terminated in front, and that is
the answer rather than the plan
([ADR 0028](./adr/0028-tls-is-terminated-in-front.md)). Zig's standard library
can be a TLS client and not a TLS server, nobody in the comparison wrote their
own, and the two alternatives are a one-person crypto dependency or a C
toolchain in the install story. HTTP/2 and gRPC are said out loud because
nobody derives them from "no TLS". `Ctx.clientIp()` and `.trusted_hops` are
this decision's other half.

**An ORM.** `nilo_sql` is not one and the name is the promise. No change
tracking, which costs a copy of every row. No lazy relations, which are queries
nobody wrote. No identity map, which is a lifetime problem in a language with
no garbage collector
([ADR 0039](./adr/0039-the-shape-of-a-query-is-settled-while-compiling.md)).

**Auth contents.** The mechanism is provided, in middleware and resolved
values. The policy is yours.

**Benchmark claims without a benchmark machine.** A figure gets published only
alongside what it does *not* mean, and alongside the fact that a handler
touching a database flattens the whole comparison
([ADR 0001](./adr/0001-dx-wins-below-the-10-percent-threshold.md)).

---

## Zig versions

The latest stable release only, on one branch. The people this is aimed at
download Zig, run `zig build`, and give up if it fails. They are not going to
go hunting for the right branch. The consequence is that every new Zig release
brings a few awkward weeks, made worse by zio following a branch-per-version
pattern too.

**0.2.0 needs Zig 0.16.**

---

## The standing risks

What could go wrong that is not a bug and not a feature. Three groups, and the
last one is the one to read.

### Held by something

**zio is a one-person project, and it could stop when Zig 0.17 lands.** The
Bulkhead, fitted from the first stage rather than patched on later
([ADR 0002](./adr/0002-zio-as-the-engine-behind-the-bulkhead.md)). It is the
entire contract nilo asks of an Engine, listed in one file's header.

**The `Str` guarantee cannot be complete.** The debug-build staleness trap, on
from day one ([ADR 0004](./adr/0004-request-arena-and-the-str-type.md)). It
missed the case anybody would actually test it with, two separate `curl` calls
where the next connection started counting from the same number the stashed
`Str` held, until every connection was given a generation span of its own. What
it still cannot watch is a `Str` reached through something nothing walks: a
const slice, or an untagged union.

**A response could differ from what `std.json` would have written**, now that
something else usually writes it. `covers()` decides while compiling which
types the generated writer may touch, and it errs narrow. A tuple, a `[N]u8`, a
type with its own `jsonStringify`, and anything unrecognised all fall back.
Floats are handed to `std.json` field by field rather than reimplemented.

**Deadlines are on by default, so a client on a genuinely bad link could be cut
off where it used to be served.** The numbers are generous and each bounds one
wait rather than a whole request, so nothing legitimate and slow is hurried by
any of them: not a big upload, not an hour-long stream
([ADR 0023](./adr/0023-a-deadline-belongs-to-an-operation-not-to-a-request.md)).

**A WebSocket has no read limit, so a client that vanishes without a FIN holds
a fiber.** Caught by the write limit as soon as the server sends anything, and
a connection nobody writes to is caught by `.idle_ms`, 30 seconds by default,
`0` waiting forever. It is a ping rather than a deadline, because a quiet
WebSocket is a working one
([ADR 0022](./adr/0022-a-websocket-is-a-handler-that-does-not-return.md)).

**The request head is the one thing a stranger writes directly, and every test
of it was an input somebody thought of.** `http/fuzz.zig` states properties
instead: the head boundary and the framing fields are checked against a
byte-at-a-time reference implementation, over a corpus on every `zig build
test` and over a million generated inputs on every CI run (`zig build fuzz`).
Coverage-guided fuzzing is not available, because `zig build test --fuzz` fails
to compile inside std's own test runner on Zig 0.16.0, so the generator is the
substitute and the targets are written to become coverage-guided the day that
is fixed.

**Nothing bounds how many connections one process holds.**
`.max_connections`, 10,000 by default. Past it a connection is accepted and
closed at once, so the failure mode is a client that finds out immediately
rather than an OOM kill that takes every in-flight request with it.

**A file response holds a descriptor for as long as the send takes.** One per
request in flight, so `.max_connections` bounds it, which is the same number an
operator already multiplies for memory. It is closed on every exit from
`sendfile.send` including the error ones, and a test counts `/proc/self/fd`
across a request so it stays that way
([ADR 0037](./adr/0037-a-file-too-big-to-hold-is-opened-not-read.md)).

**A spilled file's ETag is its mtime and size, so two different contents could
share one.** Accepted, and argued rather than assumed. The alternative is
hashing gigabytes at startup, and a weak validator would make `If-Range`
unusable for exactly the large downloads that need resuming. It is the tag
nginx has served by default for twenty years, and a held file is unaffected,
because it keeps its content hash.

### Cannot be held, and said out loud instead

**A panic in any handler takes the whole process down, and Go people will
assume otherwise.** Cannot be fixed in Zig. Said plainly in the docs, with
`ReleaseSafe` and a supervisor recommended, and the in-flight request named in
the crash ([ADR 0008](./adr/0008-no-recover-middleware.md)).

**A Service is shared across threads and nothing makes a user notice.**
`nilo.Mutex`, in the guide and in the example everyone copies. Nothing forces
it, because Zig has no ownership tracking to force it with
([ADR 0011](./adr/0011-shared-services-need-a-lock-from-the-bulkhead.md)).

**Spawned work can capture a `Str`, or call a fail function, and both compile.**
Neither can be caught: Zig has no ownership tracking, and `spawn` takes a plain
function that nothing marks as being outside a request. Documented at the
function, in the reference and in
[ADR 0029](./adr/0029-a-spawned-fiber-belongs-to-the-server.md), and `spawn`
takes its arguments by value so the copy is at least the obvious thing to
write. A `Str` that escapes this way is the staleness trap's problem, and it is
the case that trap cannot watch.

### Open

**A file response's bytes leave by a route the tests never take.** Every test
runs through `testing.Client`, whose writer is `std.Io.Writer.fixed` and
carries no `sendFile` in its vtable, so the suite takes std's read and drain
fallback. The right bytes, by the route a platform without `sendfile` uses. The
splice chain the feature exists for needs a real socket, and **the suite now
opens one**: `fetch/deadline.zig` and `zig build test-fetch-engine` stand a
server on a real port and assert on what comes back over it. So the fix is no
longer a harness to invent, only a case to write in that shape.

**Waiting on: ready.** It is still not written.

**Two test files pick loopback ports and nothing makes their ranges agree.**
`fetch/live.zig` walks 39,200-40,199 and `s3/canned.zig` walks 40,200-41,199,
each from a start derived from the thread id so a rerun does not walk back over
the ports its own `TIME-WAIT` still holds. They used to overlap, s3 taking 200
ports from a fixed 39,600 inside `fetch`'s thousand, and ten consecutive `zig
build test-all` runs failed from the sixth on with `error.NoFreePort` in
whichever s3 test came next. Eight consecutive runs are clean now and the
in-range count falls between them, so the pool sustains itself.

What holds it is a comment in each file naming the other, and a third file
wanting a port has nothing to consult and no way to fail loudly. Binding zero
and reading the port back would end the whole class, and it is not available:
`std.Io.net.Server` cannot report the port it was given, re-checked against Zig
0.16 rather than believed. `docs/history.md` has the run.

**Waiting on: a design** that makes it a rule rather than two comments, or an
upstream way to read a bound port.

**A fail function in spawned work is safe only because of where a threadlocal
gets written.** `bulkhead.slot()` falls back to a threadlocal when a fiber has
no slot, which spawned fibers never do. It is null on executor threads only
because the one thing that sets it does so from inside `zio.blockInPlace`,
which runs on a thread-pool worker. Both ends carry a comment saying so.
Nothing enforces it, and if it broke, spawned work would write its message into
an unrelated request, which is
[ADR 0007](./adr/0007-failure-box-bound-to-the-fiber.md)'s leak by another
route.

**Waiting on: a design** that makes it a rule rather than a comment.

**`zio.BroadcastChannel` aborts, or in `ReleaseFast` deadlocks, when a fiber
parked in `receive` is cancelled.** Not used here, reported upstream with a
standalone reproduction, and **fixed upstream** in zio `ab6873eb` with a fresh
`Waiter` per receive attempt. A waiter node was pushed onto a queue it was
already linked into (`simple_queue.zig:43`, from `broadcast_channel.zig:72`).
Debug aborted 10 runs in 10, ReleaseSafe 3 in 3, and `ReleaseFast`, which has
no such assertion, **hung 17 runs in 20** where a clean run takes 200ms.
Cancellation was what reached it: the same program closing the channel and
waiting was clean 5 in 5
([zio#667](https://github.com/lalinsky/zio/issues/667)).

**Waiting on: a pin.** v0.17.0 predates the fix and is what `build.zig.zon`
holds, so it arrives whenever nilo next moves the pin. Nothing here depends on
it.

---

## How this file is written

Seven rules. They are why the file has the shape it has, and adding to it means
matching them.

**1. Nothing built is in here.** The moment something ships, its entry leaves
entirely: no strikethrough, no "**Built**", no account of how it went. What was
measured goes to [`history.md`](./history.md), what a reader has to change goes
to [`CHANGELOG.md`](../CHANGELOG.md), and the decision goes to an ADR. A gap
only *partly* closed keeps one sentence scoping what is left, never a paragraph
about the half that landed. **The test is that this file reads top to bottom as
work outstanding.**

**2. Three lists per module, in the same order, and no fourth.** Next, Known
gaps, Not decided. A module with an empty list says "Nothing queued" rather
than dropping the heading, because an omission and a deliberate blank look
identical otherwise.

**3. An entry opens with the whole claim, in bold.** Somebody who reads only
the bold lines has to come away with the right idea of what is outstanding. The
paragraph under it is the detail, not the reveal.

**4. An entry ends with what it is waiting for**, from the fixed list at the
[top of this file](#how-to-read-this), or with what would settle it under **Not
decided**. This is not optional and it is not prose. It is the field that makes
the file scannable, and it is the field that catches a blocker that has quietly
stopped being one.

**5. An entry is at most a screen.** Longer than that means it is an ADR, with
an entry here pointing at it. Migrations and templates are the two longest here
and both are near that line.

**6. No checkboxes, no dates, no owners.** A box implies a plan and this is not
one. What is queued is the numbered **Next** list, and a number is a position
in that module's queue and nothing more. Everything else is a condition rather
than a schedule.

**7. A number carries a link to where it was measured.**
[`bench/result/`](../bench/result/) is the record. A figure with no run behind
it decays into a claim, and a claim in a roadmap gets planned against, which is
worse than a wrong number in a changelog.

Adding a module means adding its section here **and** a row in
[the modules table](#the-modules), which is the only index this file keeps.
