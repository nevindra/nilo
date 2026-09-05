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
| **a design** | the mechanism is known and the policy is not. What is missing is a decision somebody has to make, not code |
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
| [`nilo_fetch`](#nilo_fetch-calling-somebody-elses-api) | borrows the loop | 4,139 bytes of stack per idle connection, and nothing measured through TLS |
| [`nilo_http`](#nilo_http-the-server) | owns the loop | no rate limiting at all, a WebSocket route no test can drive, and a long tail |
| [`nilo_sql`](#nilo_sql-postgres-and-sqlite) | borrows the loop | a `Timestamp` the two halves of SQLite disagree about, a pool option dropped without a word, and where migrations live |
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

**A plain call costs 4,139 bytes on every idle connection**, still the largest
per-connection figure in the framework and no longer by three orders of
magnitude. It is fiber stack rather than buffers, at the depth
`std.http.Client` drives it to.

This entry said 16,495 for a month and named the fix as unbuilt. The fix
shipped two days after the measurement — `releaseIdleStack` gives a quiet
connection's stack pages back ([ADR 0063](./adr/0063-a-handlers-stack-is-per-connection.md)) —
and nothing re-ran the number, which is the fourth time this repository has
planned against a premise that had already stopped being true.

Two levers are left and both are small.
[`bench/result/fetch.md`](../bench/result/fetch.md) ranks them, and the one at
the top is shrinking the 2 KB redirect buffer and the 4 KB transfer buffer
rather than moving them: moving them into the arena has now been measured twice
and costs +4,096 bytes since the stack release.

**Waiting on: a caller** who is holding enough connections for 4 KB to matter.

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

The longest list here. It used to open with a group of five things a stranger on
the internet could do to a server running exactly as written, and that group is
down to one — a slow client can still buy more of the arena than it has paid
for, at a fixed exchange rate rather than for free. Everything else here is work
nilo has not done well enough yet.

The three that left first were a
`Transfer-Encoding` nilo could not decode being served as a request with no
body, a request with no `Host` or two of them being served, and a WebSocket
handshake that never looked at `Origin` —
[ADR 0101](./adr/0101-a-request-nobody-else-would-answer-is-refused.md) and
[ADR 0102](./adr/0102-a-websocket-handshake-is-same-origin-unless-the-route-says-otherwise.md).
The last two were a `Content-Length` committed before a byte of it arrived
([ADR 0105](./adr/0105-a-body-is-taken-as-it-arrives.md)) and a number that
accepted Zig's own literal grammar
([ADR 0106](./adr/0106-a-number-in-a-request-is-not-a-zig-literal.md)).

### Next

**1. Nothing refuses a client that asks too often.** There is no rate limiting
anywhere in nilo — not a middleware, not an option, not a type. `fail.tooManyRequests`
exists and returns 429, and **nothing in the framework ever calls it**.
`Ctx.clientIp()` and `listen(.{ .trusted_hops = … })` were built for the three
readers [ADR 0028](./adr/0028-tls-is-terminated-in-front.md) names — rate limits,
audit logs, blocklists — and the first of those three has no caller. What stands
in for it today is `.max_connections`, and that counts sockets **per process
rather than per address** (`Capacity` in `http/engine/zio.zig`), so one client
opening ten thousand connections closes the door on everybody else and the log
line blames the machine.

The shape has to pass [ADR 0018](./adr/0018-the-trade-budget-has-three-axes.md)
before it is worth writing, and that rules out how every other framework does it:
a map keyed by an address string means a hash and an allocation on the path of
every request it guards. What fits is the shape `app.metrics` already proved — a
**fixed table sized once at `listen()`**, indexed by a hash of `clientIp()`, with
the window and the ceiling settled while compiling, registered like CORS is
(`app.use(…with(.{ … }))`) so a route that is not guarded pays nothing.

Three questions decide it and none is answered:

- **What a full table does.** A fixed number of slots means two clients can land
  on one, and "your neighbour used your allowance" is a worse failure than no
  limiting at all. Eviction, or slots-per-shard, or a counter that decays.
- **Fixed window or sliding.** A fixed window lets twice the ceiling through
  across a boundary; a sliding one costs more state per slot.
- **What it is called.** [CONTEXT.md](../CONTEXT.md) already refuses *limiter*
  and *throttle* under the Gate's entry, so this needs a noun of its own before
  it has an API.

**Waiting on: a design.** The mechanism is ordinary; the three answers above are
what makes it shippable rather than a default that guesses.

**2. Reloading without a restart: static files, then the server.** A development
annoyance rather than a design hole, because a deploy restarts anyway. The static
half is a watch option on `staticWith`, re-reading a directory that has changed.
The other half is the whole process and cannot live inside `App`, because a
running binary cannot rebuild itself, so it belongs in the build alongside `zig
build run`. jetzig's dev server sums the modification times of its source tree
and rebuilds when the sum moves, which is about as much machinery as this
deserves. The part to be careful about is that neither half can end up in a
release binary.

The static half stopped being purely a convenience when files began spilling to
disk. See the stale-length gap below, which this is the fix for.

**Waiting on: ready.**

**3. A repeated name cannot bind to a list.** `convert.convertible` accepts a
`Str`, a number, a `bool`, an enum and optionals of those, and nothing else — so
`?tag=a&tag=b` into `tags: []const Str`, and a `<select multiple>` or a checkbox
group into a `Form(T)`, are both a compile error naming the field. `parseQuery`
and `parseMultipart` already keep every occurrence in order and `Fields.find`
deliberately returns the first, so the data is there and only the binding is
missing. It costs a slice per list field out of the request arena, on requests
that ask for one.

**Waiting on: a design** for where the slice lives when the same struct is also
what `Bound(Query(T))` hands back — an `Outcome` is one reason per field, and a
list can fail at element three.

**4. A WebSocket route cannot be driven from a test at all.**
`testing.Client` can send a header and keep a cookie now
([ADR 0108](./adr/0108-the-test-client-can-do-what-a-client-does.md)), and this
is the half that was left: there is no way to hand the App a reader that answers
frames, so every WebSocket behaviour in the suite is tested through
`app.handleRequest` against a fixed buffer that cannot answer back.

**Waiting on: a design.** A fixed reader cannot carry a conversation, so this
wants a reader the test drives turn by turn — which is a shape the harness does
not have and is the same one `bench/ws_server.zig` would want for a Room.

**5. `permessage-deflate`.** Negotiated in the handshake, and a compressor per
connection is memory that has not been budgeted.

**Waiting on: a number.** The per-connection cost has to be priced against the
4,669 bytes an idle connection holds today.

### Known gaps

**A slow client can still buy more of the arena than it has paid for, and the
exchange rate is the only thing that changed.** `c.body()` now takes a step
first and commits the announced `Content-Length` only once the client has
delivered it ([ADR 0105](./adr/0105-a-body-is-taken-as-it-arrives.md)), which
turns unbounded amplification into a fixed multiple of the step. It does not
turn it into nothing: a stranger who sends the step gets `max_body` of address
space and can then stall forever, because `body_timeout_ms` is per read rather
than for the body and that is deliberate
([ADR 0023](./adr/0023-a-deadline-belongs-to-an-operation-not-to-a-request.md)).

What would close it properly is a deadline for the whole body, which ADR 0023
argued against for an operation and has never been argued about for a *request*.
`core.Limits` is the mechanism and it is already used for an outbound call.

**Waiting on: a design** for where a whole-request deadline lives, given that
a stream and a WebSocket must not have one.

**A single-page app answers 200 with `index.html` for an asset that is not
there.** `static.Set.find` falls through to `self.fallback` for every path under
the prefix once the lookup and the index have missed, so `staticWith(.{
.spa_fallback = "index.html" })` turns a stale build hash, a typo'd import and a
deleted file into a 200 carrying `text/html`. A browser fetching `app.abc123.js`
gets HTML and reports a syntax error on line 1; a `fetch()` gets HTML and reports
a JSON parse error. Neither names the missing file.

The fix is the rule every SPA server ends up with — fall back only for a request
that could be a navigation, which is a path with no file extension, or an
`Accept` that prefers `text/html`. `App.findStatic` already asks the docs set
first for the same class of reason.

**Waiting on: a design.** Which of the two tests to use, and whether an app can
turn it off, given that the current behaviour is what shipped.

**A CORS origin list is settled while compiling, so it cannot come from the
environment.** `cors.with` takes `comptime Options` and unrolls the compare over
the literals, which is what makes a named origin cost no allocation
([ADR 0099](./adr/0099-one-allow-origin-header-means-the-list-is-matched-not-formatted.md)).
The consequence is that the same binary cannot serve staging and production,
because the front end's address is a fact about the deployment and every other
deployment fact in nilo arrives through `nilo_config` at run time. Today the
answer is to recompile, or to write the middleware yourself.

**Waiting on: a design** that keeps the comptime path for an app that names its
origins in code, since that path is the measured one, while letting a runtime
list in beside it.

**A byte slice that is not UTF-8 goes out as a JSON string, and `std.json` would
have written a list of numbers.** `json.writeString` escapes quotes, backslashes
and control characters and passes everything else through, so a `[]const u8`
holding `\xff` is written inside quotes and the response is not valid JSON.
`std.json` asks `utf8ValidateSlice` first and falls back to an array when the
answer is no.

That is the one place left where this file's stated contract — "the output is
byte-for-byte what `std.json` would have written" — is untrue, and it predates
the sentinel-slice fix rather than arriving with it
([ADR 0103](./adr/0103-one-file-decides-what-counts-as-text.md)). `expectSame`
never asks, because every string in it is text somebody typed.

Two ways out and they are different arguments. Validating in `writeString` costs
a UTF-8 pass on every string a response carries, on the request path, to catch
something almost nothing sends. Refusing the type is not available — `[]const u8`
is the ordinary spelling of text. The third answer is that the contract is wrong
and a server should not be sending unvalidated bytes as JSON at all, which is a
decision rather than a fix.

**Waiting on: a design**, and the number that goes with the first option.

**An absolute-form request target matches no route.** `GET
http://example.com/users/7 HTTP/1.1` is legal — RFC 9112 §3.2.2 says a server
**must** accept it, and a client talking to what it believes is a proxy sends
it — and `parseRequestLine` hands the whole thing to the router as a path, which
splits it into `http:`, ``, `example.com`, `users`, `7` and matches nothing. The
answer is a 404 on a route that plainly exists.

Nobody has hit it, because a browser sends origin-form and the proxy in front
rewrites. It is here because it is four lines and because the shape of the
mistake — reading a target without deciding what form it is in — is the one
[ADR 0101](./adr/0101-a-request-nobody-else-would-answer-is-refused.md) closed
two of, one header over.

**Waiting on: a caller**, and a cheap one to answer if it ever turns up.

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

**The two arms of static-file serving live in two files, and the rule they share
lives in a third.** `App.serveHeldFile` answers a file read at startup,
`sendfile.send` answers one that spilled, and `static.etagMatches` and
`range.parse` are what they have in common. `serveHeldFile` carries a twenty-line
doc explaining which lines are shared and which cannot be, which is the sign
that the seam is in the wrong place: it is the only part of `app.zig` that is
about static files rather than about serving requests, and it is where both
`If-Range` gaps above diverged.

`app.zig` is 8,027 lines, of which 2,250 are code and the rest are tests, so the
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

**An internally tagged union is read four times, and the module says the marker
costs nothing per request.** `jsonmark.zig`'s header says "Nothing per request
and nothing per connection: the marker is read while compiling", and on the
write side that is true and measured. On the read side `Reader.parse` calls
`skipValue` to find the span, `fromSpan` scans it for the discriminator,
`parseFromSliceLeaky` parses it for the variant's fields, and `refuseUnknown`
scans it a fourth time because `ignore_unknown_fields` had to be turned on to
get past the tag. `ctx.json` parses with default options, so the fourth pass is
not optional. Two of the four build a `std.json.Scanner` with an allocator.

It is per tagged value, not per body, so a small object is nothing and an array
of a thousand is four times the parse of every element. Nobody has measured
either.

**Waiting on: a number.** `bench/result/http.md` has the write side (258ns down
to 93ns on a 374-byte alert rule) and nothing at all for the read side.

**A `print` or `json` message bigger than the write buffer is still unchecked.**
[ADR 0097](./adr/0097-a-frame-that-lies-about-its-length-is-not-sent.md) holds
the two passes to each other by reading `Writer.end`, which is exact only while
nothing drains. Past the write buffer a drain moves it and there is nothing left
to compare against, so a large formatted message can still put a length on the
wire that its bytes do not match.

**Waiting on: accepted.** The two calls are for the small structured messages a
WebSocket carries, and the alternatives — a wrapper writer on every byte, or a
third pass over the arguments — both cost more than the shape they would guard.

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

**Bytes sent and connections are not counted, and neither is sharded.**
`app.metrics` counts requests, statuses and durations
([ADR 0100](./adr/0100-the-route-table-is-the-registry.md)); it does not count
response bytes, which is one more atomic on the write path that nothing has
measured, and it does not count sockets, which belong at the accept layer rather
than in `serveRequest`. The counters are also plain shared atomics: four
interleaved pairs put the cost inside the noise on a two-core box, which is the
weakest possible place to look for cache-line contention. If eight threads on
one hot route turn out to cost something, the fix is already named — shard per
executor, pad to 64 bytes, sum at scrape time.

**Waiting on: a number**, from the same pair run on the eight-core box.

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

**A megabyte assembled in the request arena costs a per-thread block cache
nobody has built.** `listen(.{ .arena_keep = … })` closed the page-fault half
of this: a response bigger than the keep was 257 minor faults a request, and
setting the option past it is worth +40%
([ADR 0096](./adr/0096-a-response-larger-than-the-arena-keep-is-a-page-fault-per-page.md)).
What the option does not fix is that the memory is retained **per connection**,
so sixty-four connections holding a megabyte each is a 76.6 MB working set
against axum's 23.2 MB on a chip with 32 MB of L3. Moving the buffer to one per
thread, changing nothing else, is worth 10,229 req/s to 14,365. The shape is an
arena whose large nodes come from a per-thread free list rather than from the
gpa, and it would need no option at all.

The rest of that gap is `@memset`, which is Zig's rather than nilo's, and on the
write path itself nilo already answers **22,018 req/s to axum's 17,209**
([`bench/result/s3.md`](../bench/result/s3.md)).

**Waiting on: a design.** It changes where request memory lives, which is
[ADR 0004](./adr/0004-request-arena-and-the-str-type.md)'s territory, and nobody
has drawn one.

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

**Waiting on: Next 2**, the watch option, which is why this is not an item of
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

**What a 60 KiB WebSocket message costs a busy server is unmeasured.** Every
WebSocket throughput figure in `bench/result/http.md` is a 64-byte payload,
which never leaves the first page of the buffer the executor lends a socket.
What a 60 KiB message costs at a thousand a second, where `http/scratch.zig`'s
byte budget starts refusing spares and the page allocator gets called on the
message path, is the number that would say whether `keep_bytes = 64 KiB` a
thread is the right size or a guess that happened to work.

**Waiting on: ready.** `bench/compare/wsload/` takes a `-payload`, so the run is
there. The interpretation is what is missing.

**The blocking detector is switched off for exactly the handlers that hold a
thread longest.** `watchdog.finish` takes an `excused` flag, and a request that
took the connection over — a WebSocket, a stream, a body reader — passes it. The
reasoning is sound: those handlers hold their fiber legitimately, for as long as
they like, and most of that time is socket I/O the watch does not account for.
The consequence is that a `std.fs` call or a synchronous driver inside a
WebSocket loop is never reported, and a WebSocket loop is where it costs the
most — a stalled fiber there holds its executor against every other socket that
executor is serving, for the life of the connection rather than for one request.

`watchdog.zig`'s own header states this ("a stated gap, not an oversight") and
nowhere else does, which is why it is here: a gap recorded only in the file that
has it is a gap nobody planning work will find.

The machinery is not missing. `Socket.receive` already parks, and `waiting`/
`waited` is exactly the bracket that would tell a per-message watch which part
of the loop was the socket and which was the handler.

**Waiting on: a design** for what a message-scoped watch starts and stops at,
given that `receive` also drains a Room before it reads.

**A type of the reader's own can be renamed into nilo's in nilo's own error
messages.** `names.zig` rewrites a type name by searching for an unqualified
`module.Type` substring, so the table matches on the reader's file name as
readily as on nilo's:

```
room.Room   -> nilo.Room
body.Body   -> nilo.Body
models.Room -> models.Room
```

An application with `src/session.zig` holding a `pub const Session`, or
`src/room.zig` holding a `Room`, is told by a nilo compile error that its type
is `nilo.Session` — and sent looking for a type it never imported. That is
word-for-word the failure this file exists to prevent, described in its own
header ("a true sentence about a source tree the reader does not have"), running
the other way round.

`session`, `room`, `body`, `stream`, `form`, `cookie` and `app` are all ordinary
names for a file in an application that uses this framework, which is what makes
the collision worth fixing rather than noting.

**Waiting on: a design.** Matching the whole `@typeName` prefix rather than a
substring is the obvious answer and it is not free: the table exists because a
nilo type appears *inside* a generic's name — `typed.Response(str.Str)` has to
rewrite both — so the rule has to keep matching mid-string while stopping short
of somebody else's file.

**Every number in this module was measured on one x86-64 machine.** `scan.lanes`
is 32 because `std.simd.suggestVectorLength(u8)` reports 32 on x86-64 with AVX2,
and it is a constant rather than a query; `json.zig` hard-codes the same 32 for
its escape scan. On aarch64 a 32-lane compare is two NEON registers, which is
probably still ahead of the scalar loop it replaced and has never been run. The
head-parsing figures (183ns → 51ns, 303ns → 163ns) and the JSON figures
(1038ns → 126ns) are all from the same box.

**Waiting on: a machine.** Nothing suggests a problem; there is simply no second
architecture in [`bench/result/`](../bench/result/), so "portable" is an
assumption rather than a reading.

**The router is still a linear scan.** Indexing the first segment took 44% off
a hundred-route app and moved
[ADR 0001](./adr/0001-dx-wins-below-the-10-percent-threshold.md)'s 10% bar out
to around 40 routes, so what is left is the actual tree, for the app with
hundreds of them.

**Waiting on: a number.** The numbers no longer point at it urgently. `zig
build profile` is the harness for the day they do, and two attempts that lost
are written up in [`history.md`](./history.md) so they are not repeated.

**A 404 or a 405 with middleware registered costs one allocation.** Routes and
static files have their chains resolved at `listen()`, so neither pays for the
middleware in front of it. The set of paths that are neither is every string
there is, so there is nothing to precompute for.

**Waiting on: accepted.** One arena allocation on a cold path, bounded by the
number of `use` calls.

### Not decided

**Whether nilo ships the response headers a browser reads as policy.**
`X-Content-Type-Options`, `Referrer-Policy`, `X-Frame-Options` and a
`Content-Security-Policy` are four constant headers, so a middleware setting
them would be `cors.zig`'s shape exactly — comptime options, `setStaticHeader`,
nothing per request. The argument against is that
[ADR 0028](./adr/0028-tls-is-terminated-in-front.md) puts a proxy in front and
the proxy is where an operator already writes these, and a framework that sets
half of them invites the belief that it set all of them. HSTS is genuinely the
proxy's, because nilo does not speak TLS and cannot know whether the client did.

**What would settle it: an application that got one of them wrong**, or an
argument that a CSP belongs with the handlers that decide what a page loads
rather than with the deployment.

**Whether a request carries a CSRF token nilo knows about.** A session cookie
defaults to `SameSite=Lax`, which is what stops a cross-site form POST from
carrying it, and that covers the case almost everybody has. What it does not
cover is a `SameSite=None` cookie, a `GET` that changes something, and a browser
old enough not to enforce Lax. Every framework that has this ends up with a
token in the session, a hidden field in the form and a comparison in a
middleware, and all three would fit here — `Session(T)` already carries fixed
`[N]u8` fields, and `Form(T)` already reads a hidden input.

**What would settle it: somebody who has to turn `SameSite` off**, since Lax is
what makes the feature unnecessary for everybody else.

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

**2. An update cannot change a column using its own value.** `.set` binds
values, so `SET "views" = "views" + 1` has no spelling and an atomic counter is
`db.exec` with the SQL written out. Read-modify-write is the alternative, which
is two round trips and wrong under load unless it is wrapped in a transaction
with `.lock = .update` — so the shape everybody reaches for first is the one
that races. What fits is the shape a condition already has: a value that is a
struct of operators rather than a value, `.set = .{ .views = .{ .plus = 1 } }`,
with the column name written into the fragment and the operand bound. It is one
more branch in `updating` in `sql/statement.zig` and it keeps the statement a
constant.

**Waiting on: a design** for which operators are in it. `plus`/`minus` on a
number is obvious; concatenation, `coalesce` and array append are each a
dialect disagreement, and a set of one operator is not worth a mechanism.

**3. Nothing shows the statements a request sent.** `logger.zig` writes one
line per request and there is no way to see the SQL underneath it — not in
Debug, not behind an option, not on a slow query. Every other framework has
this because it is the first thing anybody reaches for when a page is slow, and
here it is cheaper than anywhere else: the text is a comptime constant, the
plan name is already derived from it (`statement.planName`), and the parameter
tuple is already built. So a hook on `Wire.run`/`Wire.exec` costs a branch on a
null function pointer per statement.

**Waiting on: a design** for what it is given. The values are the interesting
half and printing them puts credentials and personal data in a log, which is
the thing [ADR 0025](./adr/0025-every-failure-answers-with-the-same-json-body.md)
is careful about one layer up.

### Known gaps

**A `Timestamp` is written to SQLite as an integer and checked against a TEXT
column.** `WireWrite` answers `i64` whatever the Dialect is, and `acceptsSqlite`
routes every type carrying a declared column name to `TEXT`, `VARCHAR` or
`CLOB`. So `created_at INTEGER` — the column that matches what is actually
bound, and the one anybody would write — fails the startup check, while the
column that passes it stores microseconds as digits in a text column, where
`ORDER BY` sorts them as text and no SQLite date function reads them as a time.

`bench/sql.zig` already works around it by declaring its column `i64` rather
than `sql.Timestamp`, and says so in a comment: the symptom recorded and the
cause left alone. `Uuid` had exactly this disagreement and `uuid_form` closed
it; this is the second row that table needs.

**Waiting on: a design** — a `time_form` beside `uuid_form`, or an
`acceptsSqlite` that answers `INTEGER` for the one declared column type this
module does not send as text.

**`db.raw` reads by position and nothing checks how many columns came back.**
`fill` walks the Row's fields and asks the Wire for column `i` of each, and
pg.zig's `Row.get` is `const value = self.values[col]` with no bound on `col`
(`zig-pkg/pg-…/src/result.zig:266`). A `SELECT` list shorter than the Row —
a column dropped from a hand-written join, a `RETURNING` that lost a field — is
therefore an out-of-range index rather than an error: a panic in ReleaseSafe,
which takes the whole process down for one request, and undefined in
ReleaseFast. This is the mode of failure
[ADR 0008](./adr/0008-no-recover-middleware.md) says nilo cannot recover from,
and the module already refuses to let the driver panic in two other places —
`enumOf` for a tag the Zig enum lacks, and `arrayFits` for an array shape
pg.zig asserts on.

`db.raw` gives up the *compile-time* column check and nothing else, which is
what its doc says; it should not also give up being answerable.

**Waiting on: ready.** `pg.Result` carries `number_of_columns`, so this is one
comparison per statement against `columnsOf(Row).len`, in `fill`, with a
message naming both numbers.

**A Row column of a type no Dialect knows fails in pg.zig's words, not nilo's.**
`dialect.accepts` answers `null` for any struct it does not recognise, and
`schema.Expectation.accepted` reads an empty list as *accept anything* — so
such a column passes the startup check, and the first read reaches pg.zig:

```
zig-pkg/pg-…/src/types.zig:1580:21: error: cannot decode value of type pg_only.User__struct_3276
referenced by: get__anon → read__anon: sql/postgres.zig:456
```

The type name is a mangled anonymous struct and the file is a dependency the
reader did not write. `dialect.listAccepts` already carries a comment saying
this exact failure "is what a Row reading an array used to get" and that
catching it is why arrays are judged — the same fix was never applied to the
scalar case, which is the one a first-time reader hits by writing a plain struct
field.

**Waiting on: ready.** `assertStreamable` is the shape: a comptime walk over the
Row's fields at the top of `fill`, refusing a type that is neither a Dialect's
nor one of the protocols in `types.zig`, naming the field and the four ways to
make it readable (`AsText`, `Json`, an enum with `nilo_column`, or leaving it
out of the Row).

**`Db.Opts.timeout_ms` does nothing on SQLite, and a fiber that asks for the
writer twice parks forever.** `sqlite.Wire.open` reads `open_opts.size` and
ignores the rest; `connect_on_init` is documented as meaningless there and
`timeout_ms` is not, so the option a caller sets to bound a queue is silently
dropped. `takeWriter` then waits on a `std.Io.Condition` with no deadline at
all. There is one writer, so a handler holding a `Tx` that calls `db.exec` —
`db`, not `tx`, which is a one-character mistake — waits on a connection it is
itself holding, with nothing to time it out and nothing in the log. On Postgres
the same code takes a second pool connection and merely runs outside the
transaction.

**Waiting on: a design.** Honouring `timeout_ms` in the two `take` calls is the
small half. The self-deadlock wants either a `Locked` when the asking fiber is
already the writer, which means knowing which fiber holds it, or a Refusal that
cannot be written — and neither is obviously right.

**The batch Refusal on SQLite blames the column type, and a batch update calls
itself an insert.** `noArrayForm` in `sql/statement.zig` is reached from both
`insertMany` and `updateMany` and its first line always says "a batch insert".
Its third branch is the one SQLite always takes, and it is wrong about why:

```
error: nilo: a batch insert into sqlite_only.User cannot send `id`, which it reads as i64.
  The sqlite dialect has no column type for it, so there is no array of it to send either.
  `dialect.accepts` is the list of what it knows.
```

`acceptsSqlite(i64)` answers `INTEGER, INT, BIGINT, NUMERIC`, so the sentence is
false and the reader it sends to `dialect.accepts` will find it is false. The
true reason is the one the guide and ADR 0061 give — SQLite has no `unnest` and
no array parameter, so a batch is not available at all there — and the message
never says it. Error messages are a feature here with a build step behind them
([ADR 0027](./adr/0027-the-rule-about-error-messages-is-held-by-a-build-step.md)),
and `sql/refusals/` has no file for this path.

**Waiting on: ready.** A fourth branch keyed on the Dialect having no `arrayOf`
at all, a `what` argument so the verb matches the call, and two rows in
`sql_refusals`.

**A `[]const Str` cannot be written back into the column it came out of.**
`db.select` fills a `[]const Str` list column by walking the slice a second time
to attach the lifetime marker — that is `keptList`'s stated cost — and there is
no way back. `forWire` handles a scalar `Str` and falls off the end for a slice
of them:

```
sql/db.zig:1945:12: error: expected type '…![]const []const u8', found '[]const str.Str'
  note: pointer type child 'str.Str' cannot cast into pointer type child '[]const u8'
```

So reading a row, changing one field and inserting it again does not compile for
a list-of-text column, and the message is Zig's, pointing inside `db.zig`. That
is the same shape as the scalar `Str` case the snippet check found and
[ADR 0083](./adr/0083-the-guide-is-the-source-of-its-own-snippets.md) fixed —
`.where = .{ .email = form.email }` used to fail here too. The list half was
missed because no snippet writes one.

**Waiting on: ready.** It is one allocation in `forWire`, the mirror of the one
`keptList` already pays, and a marked snippet in the guide's *Lists* section so
it cannot silently break again.

**The schema check is opt-in, and forgetting it is silent.** `db.checking(&.{ … })`
takes the Row list by hand and nothing warns when it is never called or when a
Row is left out of it — the check simply does not run for that Row, and the
disagreement it would have caught arrives as a 500 on the first request that
reads the column. Zig cannot enumerate the Rows a program declares, so there is
nothing to derive the list from; what there *is* is the fact that a `Db` with
`check == null` is a decision nobody wrote down.

**Waiting on: a design.** A warning at `nilo_start` for a `Db` nobody called
`checking` on is one line and is also noise for a program that meant it; an
explicit `db.checking(&.{})` to say so is a second way to spell nothing.

**A key is one column, so a composite key has no `find` and no batch update.**
`row.keyOf` answers a single name, `statement.find` writes one `=` against it,
and `updateMany` joins on it. A table keyed by `(tenant_id, id)` — which is what
every multi-tenant schema is — reaches `db.one` with the condition written out
and has no batch update at all. `.key = .{ .tenant_id, .id }` is the spelling
the rest of the module already uses for a tuple of columns, since
`conflictColumns` reads exactly that shape for an upsert target.

**Waiting on: a caller.** The `find` half is small; `updateMany` joining on two
columns is a second `AND` in the fragment and nothing else.

**An upsert cannot name a constraint or a partial index.** `ON CONFLICT` takes
only a column tuple, so a unique constraint by name
(`ON CONFLICT ON CONSTRAINT users_email_key`) and a partial unique index
(`ON CONFLICT (email) WHERE deleted_at IS NULL`) are both out of reach, and so
is a `DO UPDATE … WHERE`, which is how an upsert refuses to write a row that is
already newer. Postgres refuses the statement at run time when the target has no
matching index, which the doc on `insertOrIgnore` already says — so today the
answer for all three is `db.raw`, and `db.raw` cannot express `RETURNING` into a
Row plus a conflict target without giving up the column check.

**Waiting on: a caller.** A constraint name is a string this module would have
to take on trust, which is the one place it takes nothing on trust, so the
design question is real rather than clerical.

**`like` hands `%` and `_` escaping to the caller and nothing says so.**
`.email = .{ .like = text }` puts the caller's text in the parameter, so a
user-supplied search term containing `%` matches far more than it should and one
containing `_` matches a character it should not. Nothing is smuggled — it is a
bound parameter — but a search box wired straight to `.like` is wrong in a way
that only shows up on the input nobody tried. Every caller ends up writing the
same escape.

**Waiting on: a design.** The fix everybody wants is `contains`, `starts_with`
and `ends_with`, which build the pattern *and* escape it — and that means an
allocation per condition in a module whose whole claim is that a statement costs
none, plus an `ESCAPE` clause the two Dialects spell the same way but SQLite
applies differently to `LIKE` on a `BLOB`.

**`selectFor` and its six siblings are Postgres-only.** `sql.selectFor(Row,
Options)` and the rest hard-code `dialect.Postgres`, so a program on
`sql.Sqlite` cannot ask what SQL its own query compiles to — which is the one
call in the module that exists purely so a reader can see the constant ADR 0039
is about. `statement.select(D, Row, O)` takes the Dialect and is the module's
own spelling; only the re-export in `sql.zig` fixes it.

**Waiting on: ready.** Either a Dialect parameter on each, or `sql.dialect` and
`sql.statement` being enough now that both are already exported.

**Nothing reports how the pool is doing.** `app.metrics` counts requests,
statuses and durations
([ADR 0100](./adr/0100-the-route-table-is-the-registry.md)); a `Db` counts
nothing. Connections in use, how long a caller waited for one, statements run,
and how many the pool threw away are all questions an operator asks first when a
service slows down, and the last of them is already reachable —
`postgres.dirtyConnections()` parses it out of pg.zig's own metrics text and is
marked test-facing because nothing else reveals it.

**Waiting on: a design** that does not become a second metrics registry.
`app.metrics` is the shape and a `Db` is a Service, which knows nothing about an
App — so where the numbers meet is the question, not how to count them.

**A connection URL carrying an ordinary parameter stops the server.**
`postgres.dialOpts` understands `sslmode` and `tcp_user_timeout` and refuses
everything else — `sslmode=prefer`, `allow` and `verify-ca` included. The
refusal is right about the risk, since an `sslmode` nobody read is a plaintext
connection whose URL says otherwise, and wrong about how often it fires: the URL
a managed Postgres hands out carries `channel_binding`, `application_name`,
`options` or a pooler's own parameter, so pasting one in is a server that will
not start. What the operator gets is `UnsupportedConnectionParam` and no list of
what *is* understood, and `nilo_start`'s message then sends them to re-read a
URL that is correct.

**Waiting on: a design** — which parameters are safe to drop, which are worth
carrying, and whether the refusal names the two it knows.

**There is no binary column.** `Postgres.accepts` answers `text`, `varchar`,
`bpchar`, `char` and `name` for a `[]const u8`, and nothing anywhere answers
`bytea`, so a Row cannot read one. SQLite is the same the other way round:
`acceptsSqlite` already lists `BLOB` for a byte slice, and nothing can write one
there, because `WireWrite` sends a `[]const u8` as text and zqlite needs its
`Blob` wrapper to do anything else. A file hash, a sealed token, a signature, an
encoded document — the most ordinary column this module cannot name.
`sql.AsText("bytea")` reaches it through Postgres's hex text and costs a
conversion each way, and nothing anywhere says so.

**Waiting on: a design.** The `nilo_column`/`nilo_read`/`nilo_write` protocol
([ADR 0055](./adr/0055-a-column-type-can-come-from-outside-this-module.md)) is
text on the wire by definition, so bytes want a second protocol beside it rather
than another instance of it.

**A `SELECT` has four options and a listing page wants three more.** No
`DISTINCT`. No `NULLS FIRST`/`NULLS LAST` on an order term, which is what a
nullable sort column needs before it can be paginated at all — the two dialects
disagree by default, Postgres putting NULLs last ascending and SQLite putting
them first, so a Row that sorts on one is already not portable. And no keyset
form, so a deep page is `OFFSET` and the database counts past every row it is
not going to answer with, which is the one pagination shape that gets slower as
the table grows.

The first two are a widening of `.order`, which today takes a direction and
nothing else. The third is a condition the caller can write by hand once the
sort is stable, so what is missing there is the guide saying so.

**Waiting on: a caller.**

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

**Waiting on: a harness**, and it exists twice over now:
`zig build test-fetch-engine` and `http/live.zig` both stand a server on a real
port and drive a real socket at it. What is left is writing the case.

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

**`sqlite_master` in the introspection query is not schema-qualified.**
`columnsOf` in `sql/sqlite.zig` rewrites `pragma_table_info` to
`"archive".pragma_table_info` when a Row names a schema, and leaves the
`LEFT JOIN sqlite_master` beside it alone — so a Row over a table in an attached
database asks `main.sqlite_master` whether that name is a view. It finds
nothing, `m.type` is null, and the `UNKNOWN` answer that exists so a view's
columns are not all reported as nullable
([ADR 0056](./adr/0056-a-view-is-a-table-that-cannot-say-what-is-not-null.md))
is unreachable there. A Row over a view in an attached database gets exactly the
failure ADR 0056 was written to remove.

**Waiting on: ready.** The same rewrite `columnsOf` already does, applied to the
second relation in the query.

**pg.zig spends a whole round trip it does not need on every prepared
statement.** `conn.zig:243` writes a standalone `Sync` on the cache-hit path and
waits for `ReadyForQuery` before it sends Bind and Execute, where pgx and
tokio-postgres send one. It is ~2.6 µs, and
[`bench/result/sql.md`](../bench/result/sql.md) §8 says it is **the whole of
nilo's single-row deficit against Rust**. This is not the pipelining
[ADR 0059](./adr/0059-a-round-trip-is-not-the-cost-worth-chasing.md) refused —
that argument was about the round trip being mostly kernel and only amortisable
in bulk, and this is one message that does not have to be sent at all.

**Waiting on: upstream (pg.zig)**, and it is a local change there rather than a
protocol rewrite. The note at the [top of this file](#how-to-read-this) about
distrusting an upstream blocker applies: nobody has opened the file since the
measurement.

**Every library in the ten-way comparison was measured on one connection.**
[`bench/result/sql.md`](../bench/result/sql.md) §8 ranks ten clients across
eleven operations, and §2 of the same file is the standing warning that a
per-operation figure taken unloaded understates what a pool sees by two to three
times — because a pool connection is a serial queue. So the ordering in §8 is
the ordering of an unloaded round trip, and nothing says whether it survives the
shape a service actually runs in.

**Waiting on: a machine.** The harness exists; what it needs is a box where the
generator, the database and ten candidates are not sharing eight cores with each
other.

**Row locks and contention between writers have correctness tests and no
benchmark.** `live.zig` proves `.update_nowait` refuses a held row and
`.update_skip_locked` steps over one, and §8's write half is insert, batch,
update, delete and a transaction **on one connection**. What a contended row
costs — how long a writer queues, what `serializable` retries are worth, where
`FOR UPDATE SKIP LOCKED` stops scaling as a work queue — is unmeasured on both
Wires.

**Waiting on: a machine**, and the same one the entry above wants.

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

**This one has gone off, which is why it is worth reading rather than nodding
at.** `[:0]const u8` was recognised by neither and went out as a JSON array of
byte values under an `application/json` label, while the generated document
described it as a string
([ADR 0103](./adr/0103-one-file-decides-what-counts-as-text.md)). The tests did
not catch it because every value in them was a type somebody sat down and
wrote. One case is still open — a byte slice that is not valid UTF-8 — and it is
a gap above rather than a risk here.

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

**What it cannot catch is a reading both sides share**, and it did not: the
reference parser read `Transfer-Encoding: gzip` exactly as wrongly as
`http1.zig` did, so the corpus entry for it passed
([ADR 0101](./adr/0101-a-request-nobody-else-would-answer-is-refused.md)). A
differential test proves the two implementations agree, which is not the same
as either being right. Only the RFC settles that.

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

**Three test files pick loopback ports and nothing makes their ranges agree.**
`fetch/live.zig` walks 39,200-40,199, `s3/canned.zig` walks 40,200-41,199 and
`http/live.zig` walks 41,200-42,199, each from a start derived from the thread
id so a rerun does not walk back over the ports its own `TIME-WAIT` still holds.
Two of them used to overlap, s3 taking 200 ports from a fixed 39,600 inside
`fetch`'s thousand, and ten consecutive `zig build test-all` runs failed from
the sixth on with `error.NoFreePort` in whichever s3 test came next.

What holds it is a comment in each file naming the others, and **the third file
arriving is the evidence that the comment is the wrong mechanism**: nothing
checked the new range, nothing could have failed loudly if it had collided, and
the only reason it does not is that somebody read three files first. Binding
zero and reading the port back would end the whole class, and it is not
available: `std.Io.net.Server` cannot report the port it was given, re-checked
against Zig 0.16 rather than believed. `docs/history.md` has the run.

**Waiting on: a design** that makes it a rule rather than two comments, or an
upstream way to read a bound port.

**Three published snippets carry a mark saying they compile, and no build step
opens the page they are on.** `zig build snippets` reads a `pages` list in
`build.zig` holding four entries — `README.md`, `docs/reference.md`,
`docs/guide/sessions.md` and `docs/guide/config.md`. Twenty-four pages carry
Zig blocks, 206 of them altogether, and the other twenty are never opened.

Most of those blocks are simply unmarked, which is honest: `<!-- compiles -->`
is opt-in per block and an unmarked block claims nothing. **The three that are
not honest are `docs/guide/metrics.md:8`, `:129` and
`docs/guide/responses.md:186`** — marked, and never compiled by anything,
because their page is not in the list. Somebody wrote the mark believing it was
a guarantee. That is this repository's own stated failure, a rule nobody runs,
wearing the costume of a rule that does.

`docs/guide/sql.md` is the page this matters most for and the one furthest from
fixed: 48 Zig blocks, more than the README and the reference together, and not
one of them marked.

**Waiting on: ready**, and it is an afternoon rather than a line. Adding a page
to `pages` compiles nothing until a block on it is marked, and the marking is
the work: [ADR 0083](./adr/0083-the-guide-is-the-source-of-its-own-snippets.md)
records that doing it to one five-line example found seven mistakes. The three
dead marks are the cheap half and need not wait for the rest. What would end
the class rather than this instance is the step reading every page that has a
marked block, instead of a list somebody has to remember to join.

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

**Nothing checks that a completion handed to the loop is given back before its
frame goes.** `Wake` submitted two and never did, and the cost was a server that
would not come back from a SIGTERM three runs in four
([ADR 0098](./adr/0098-a-completion-the-loop-holds-outlives-the-frame-that-submitted-it.md)).
What makes it a standing risk rather than a closed bug is that the fix is one
`defer` and the next `submit` anybody writes is under no obligation to match it.

The failure gives nothing away at the place it happens: the loop writes into
memory that has been handed on, and what arrives is a spinning thread somewhere
else entirely, after a shutdown that has already logged success. Only the Engine
may name zio, so the whole surface is one file — but one file is what the
threadlocal entry above says too.

**Waiting on: a design** that makes it a rule rather than a `defer` somebody has
to remember. This particular one is guarded — a test in the Engine parks a
`Wake` and checks the queue is empty after `deinit` — but the guard names
`Wake`, and the next `submit` will not be in `Wake`.

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
