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
| [`nilo_cache`](#nilo_cache-an-expiring-cache-in-this-process) | needs no loop | a read that costs two cache misses where a Go map costs one |
| [`nilo_jwt`](#nilo_jwt-checking-somebody-elses-token) | needs no loop | no number against a verification, and only RS256 |
| [`nilo_fetch`](#nilo_fetch-calling-somebody-elses-api) | borrows the loop | 4,139 bytes of stack per idle connection, and nothing measured through TLS |
| [`nilo_http`](#nilo_http-the-server) | owns the loop | a megabyte of request arena held per connection, nothing that reads a `Forwarded` header, and a long tail |
| [`nilo_sql`](#nilo_sql-postgres-and-sqlite) | borrows the loop | a migration library with no command that runs it, a `Timestamp` the two halves of SQLite disagree about, and a pool option dropped without a word |
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

## `nilo_cache`: an expiring cache in this process

A ring of bytes with a table over it, sized once and never grown
([ADR 0138](./adr/0138-a-cache-holds-its-bytes-under-a-lock-it-can-spin-on.md)).
It imports nothing, so `zig test cache/cache.zig` is the whole of its suite,
and a program that is not a server can take it on its own.

### Next

**1. A read costs two dependent cache misses where a Go map costs one, and
that is the whole of the small-value gap.** A slot points at a ring, so a
lookup misses on the bucket and then again on the entry. go-cache keeps the key
beside the probe and misses once, which is worth between a third and a half on
values of a few dozen bytes ([`bench/result/cache.md`](../bench/result/cache.md)).
Closing it means entries in the table, which is the design that cannot bound
its own memory — so it would be a second structure beside this one rather than
a change to it.

**Waiting on: a caller.** Nobody has a workload where the difference decides
anything, and the memory this buys instead is the reason the module exists.

**2. The clock is read on every `get`, whether or not anything in the Space
expires.** `CLOCK_MONOTONIC_COARSE` is about 5ns of a 230ns operation. Skipping
it needs the shard to know whether any entry it holds has an expiry, and
reading that flag outside the lock is a race worth about 2%.

**Waiting on: a number**, taken on a machine with cores to spare rather than
this one.

### Known gaps

**Nothing has been measured on a machine that is not a two-core shared box.**
Every ratio in `bench/result/cache.md` is from two cores with an operating
system also wanting one, and neither side of the go-cache comparison could be
pinned because there was nowhere to pin to. The ranges are wide enough that a
single run of either side would have been misleading, and they should be
re-taken before being quoted anywhere else.

**Waiting on: a machine.**

**A value of `[]const u8` is the only shape that is not flat.** A struct with a
`[]const u8` field in it is refused by name, and the caller encodes it. The
shape that would fix it — writing the slices' bytes after the fixed part and
pointing them back into the caller's buffer on the way out — is known and is
maybe 120 lines of comptime, and nobody has asked for it yet.

**Waiting on: a caller.**

**There is no `getOrPut`.** Every caller writes the miss, the compute and the
put, which is three lines rather than one and, more to the point, lets two
threads compute the same value at once. A cache stampede is a real thing and
this module has no answer to it. The answer is not obvious either: holding the
lock across the caller's computation is the one thing this module may never do
(ADR 0138).

**Waiting on: a design.**

### Not decided

**Whether a bucket should have sixteen ways rather than eight.** Eight
eight-byte slots are one cache line and that is where the number came from.
Sixteen would be two lines touched, better retention at high load, and a table
the same size. Nobody knows whether the second line costs more than the keys it
saves.

**What would settle it:** the retention curve and the read cost, both swept
across ways, on a machine where the read cost is not mostly memory latency.

---

## `nilo_jwt`: checking somebody else's token

RS256 and a JWKS document, and nothing else
([ADR 0140](./adr/0140-nilo-verifies-a-token-and-does-not-fetch-one.md)). The
arithmetic is `std.crypto.Certificate.rsa`'s; what this adds is the order the
checks happen in and the switch over key sizes. It imports nothing, so
`zig test jwt/jwt.zig` is the whole of its suite.

### Next

Nothing queued.

### Known gaps

**A verification has no number against it.** Nobody knows what one costs, so
nobody knows whether a sign-in endpoint should cache the answer or just do it.
An RSA modular exponentiation at 2048 bits is the whole of the work and it is
not small, which is the reason to expect the number to matter.

**Waiting on: a number**, and a row in [`bench/result/`](../bench/result/) to
put it in.

**Only RS256, and only 2048, 3072 and 4096 bits.** A key size with no branch
is `error.KeySizeNotSupported` rather than a best effort, which is the right
refusal and is still a refusal. The EC families are what an issuer moves to
when it moves.

**Waiting on: a caller** who has an issuer this cannot read.

**HS256 is absent on purpose and that is not free.** A shared-secret token is
what a service issues to itself, and the reason it is not here is that a
module verifying both algorithms has to be careful about the confusion attack
that a module verifying one cannot commit. A caller who needs it has to write
four lines of `HmacSha256` beside this module and get the constant-time
compare right on their own, which is the shape of mistake this module exists
to prevent.

**Waiting on: a caller.**

### Not decided

**Whether nilo should hold the key set as well as read it.** Today the caller
fetches with `nilo_fetch`, holds with `nilo_cache`, and decides when a `kid`
miss means "refetch" rather than "refuse". That is three lines and one real
decision, and every one of them is visible. A `Jwks.fetch(url)` that did all
three would be one line and would hide the decision.

**What would settle it:** two callers writing the same refresh policy. One
caller writing one is a caller, not a pattern.

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

**1. Reloading the server without a restart.** A development annoyance rather
than a design hole, because a deploy restarts anyway. The static half is built:
`staticWith(.{ .reload = true })` leaves every file on disk and opens it per
request ([ADR 0125](./adr/0125-a-file-is-described-by-the-descriptor-being-sent.md)),
and a file that changes under a running server is described by the descriptor
its bytes come out of. A file that did not exist at startup still needs a
restart. What
is left is the whole process, which cannot live inside `App` — a running binary
cannot rebuild itself — so it belongs in the build alongside `zig build run`.
jetzig's dev server sums the modification times of its source tree and rebuilds
when the sum moves, which is about as much machinery as this deserves. The part
to be careful about is that it cannot end up in a release binary.

**Waiting on: ready.**

**2. A form field cannot bind to a list.** A query parameter can, since
[ADR 0164](./adr/0164-a-query-parameter-that-is-a-list.md); a `<select multiple>`
or a checkbox group into a `Form(T)` is still a compile error naming the field.
`parseMultipart` already keeps every occurrence in order and `Fields.find`
deliberately returns the first, so the data is there and only the binding is
missing.

**Waiting on: a decision** about the separator, which is where this stops being
the query case one slot over. A browser sends a repeated name and never a
comma-joined one, so the reading that made sense for a query string — take both
spellings, write the comma into the document — is half wrong here: there is no
document to write, and a comma in a form value is a value with a comma in it.

**3. `permessage-deflate`.** Negotiated in the handshake, and a compressor per
connection is memory that has not been budgeted.

**Waiting on: a number.** The per-connection cost has to be priced against the
4,669 bytes an idle connection holds today.

### Known gaps

**A response whose text is not ASCII pays a byte-at-a-time UTF-8 walk.**
`json.zig` asks `std.unicode.utf8ValidateSlice` before writing a string, so a
byte that is not text comes out as `std.json`'s array rather than as invalid
JSON ([ADR 0121](./adr/0121-a-byte-that-is-not-text-is-not-a-string.md)). That
function clears 32 bytes of ASCII at a time and then walks everything from the
first byte over `0x7f` onwards one at a time: 10ns for the 365-byte payload this
repository measures, 278ns for a kilobyte with one `é` in the middle, and
2,404ns for a kilobyte of nothing but `é`
([`bench/result/http.md`](../bench/result/http.md)). The last of those is 19×
the whole JSON write.

`std.json` has always paid the same, so nothing got slower — but nilo's claim
is that it is eight times faster than `std.json` on this path, and on Japanese
or Arabic text it would be much closer to it. A vectorised validator of the
Keiser–Lemire shape runs at about a byte a cycle whatever the input.

**Waiting on: a caller** whose payloads are mostly not ASCII. Every payload in
`bench/` is English.

**`join` and `leave` queue behind a whole broadcast, and nothing says whether
that costs anything.** `Room.handOut` takes the roster lock and holds it for the
entire loop over the roll. The field says so now; it used to claim the opposite,
which is the half of this that is closed.

Shortening the hold is not the small change it reads as. `leave` drains a seat
under that lock and `takeSeat` does not drain before handing one out, so
releasing the roster before the loop would deliver a post to whoever sits down
next — `put` reads no era, and `take` reads the new occupant's, which matches.
Making it correct means draining in `takeSeat` as well, and showing the
contention was real first.

**Waiting on: a harness.** Nothing measures a Room under load at all.
`bench/ws_server.zig` runs the chat loop from `examples/chat/` with the room
deliberately taken out, so every WebSocket number in
[`bench/result/http.md`](../bench/result/http.md) is a socket that joined
nothing, and `zig build profile`'s `room: say to 8 of 1,000 seats` is one fiber
with nobody contending for the lock.

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
`service.Registry.get` walks `entries` comparing type names once per service
argument per request. Which services a route needs is settled while compiling
and `listen` already checks every one of them, so this is work at request time
that a startup pass could resolve into the route and remove entirely.

**It costs 1.2ns an entry, flatly linear, which makes it a threshold rather than
a yes or a no.** Four services is 4.5ns, 1.6% of a 289ns request and well under
[ADR 0001](./adr/0001-dx-wins-below-the-10-percent-threshold.md)'s bar;
thirty-two is 38.8ns and 13.4%, over it. And it is per service *argument*, so a
handler taking a database and a cache pays it twice. The rows are in
[`bench/result/http.md`](../bench/result/http.md), worst-case ordering, five
runs inside 4% of each other.

This entry used to say "it may well be nothing", which is a sentence nobody can
act on in either direction. Measuring it cost one afternoon and a row in the
profiler.

**Waiting on: a caller** with more than about sixteen services. Nothing in
`examples/` has four.

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

**The free list as described above cannot be built, and that is the finding
rather than the design.** A block recycled into another connection's arena
while an `io_uring` send still references it corrupts that response — the
completion holds the pointer, not a copy, and the arena has no idea a write is
outstanding. So a per-thread cache needs a block to be unreachable until every
operation naming it has completed, which is a lifetime rule the arena does not
have and `defer` cannot express.

**And the number that motivates it cannot be reproduced here.** 76.6 MB against
23.2 MB, and 10,229 req/s to 14,365, were taken where sixty-four connections
each hold a megabyte on a chip with 32 MB of L3. This box has two cores and no
such working set, so anybody picking this up starts by rebuilding the before
([`bench/result/http.md`](../bench/result/http.md)'s rule) on a machine where
the L3 argument is real. The cheaper alternative that keeps coming up — raise
`arena_keep` and let each connection hold its block — is the page-fault cost
[ADR 0096](./adr/0096-a-response-larger-than-the-arena-keep-is-a-page-fault-per-page.md)
measured, paid per connection instead of per request.

**Waiting on: a design** for when a block is safe to recycle, which is
[ADR 0004](./adr/0004-request-arena-and-the-str-type.md)'s territory and is a
harder question than the cache. Nobody has drawn one.

**The API description is silent about authentication.** A handler taking a
`CurrentUser` needs an `Authorization` header and the document does not say so,
because the header is a line of Zig inside the resolver rather than something
in a type.

**Waiting on: a design** that does not become a second thing to keep in step
with the resolver. That drift is what the generated document exists to avoid. A
consumer has now turned up who generates a frontend client from the document
and is not blocked by the omission, which is worth knowing: this is a gap in
what the document says rather than in what it is usable for.

**The API description names one failure, and endpoints have several.** `!?T`
puts a 404 in the document because the signature settles it
([ADR 0024](./adr/0024-a-failure-mode-belongs-in-the-return-type.md)). A
`fail.conflict` on a duplicate email is a line in a function body and stays
invisible. That is the rule rather than a gap, since the document promises what
the signature settles, but it is the rule that costs the most.

**Waiting on: accepted.** The document promises what the signature settles, and
that is the whole of ADR 0024. Widening it means a second place to write a
failure down, which is an annotation wearing another name and is the one thing
this framework does not ask for. It is here so nobody re-derives it as a gap. A
shape that states a failure *in the type* would reopen it; wanting one does not.

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

**Waiting on: accepted.** The last sentence above is the decision rather than a
step towards one: 14 KB does not buy a line in every dependent's `build.zig`. If
a third build option ever lands for a reason of its own this rides along with it
for nothing, which is a bonus and not a plan.

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

**Two type names nilo still cannot say the reader's way.** A nilo type inside a
*reader's* generic — `main.Page(nilo.Str)` — comes back spelled `main.Page(str.Str)`,
because the argument of somebody else's generic is not recoverable from its name,
and `Middleware` prints its whole signature because a function type cannot hold
the declaration a nilo type names itself with
([ADR 0122](./adr/0122-a-type-says-its-own-name.md)).

**Waiting on: accepted.** Both are the price of never renaming a reader's own
type into nilo's, which is the failure that was worth fixing.

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
are written up in [`history.md`](./history.md) so they are not repeated. An
application with 203 routes now exists, against a threshold measured at about
40, and has said it will report a number rather than ask for the work.

**A 404 or a 405 with middleware registered costs one allocation.** Routes and
static files have their chains resolved at `listen()`, so neither pays for the
middleware in front of it. The set of paths that are neither is every string
there is, so there is nothing to precompute for.

**Waiting on: accepted.** One arena allocation on a cold path, bounded by the
number of `use` calls.

**A listener somebody else opened cannot be taken over.** `.address =
"unix:/run/nilo.sock"` is there now
([ADR 0130](./adr/0130-a-path-is-an-address-to-listen-on.md)), so the proxy
[ADR 0028](./adr/0028-tls-is-terminated-in-front.md) puts in front no longer has
to reach the server over loopback TCP. The other half of that gap is not: a
process that cannot be handed an open descriptor cannot take the socket over
from the process it replaces, so a deploy with nothing in front of it still
drops the connections in flight whatever `shutdown_grace_ms` says.

It is one more variant on `address` again, and the work is in the Engine
([ADR 0002](./adr/0002-zio-as-the-engine-behind-the-bulkhead.md)). Two things
have to be settled with it: an inherited descriptor has to be put into
non-blocking mode before the loop may have it, and how it is named is a protocol
decision — systemd's `LISTEN_FDS` convention, or a bare number.

**Waiting on: a caller** with a deploy that has nothing in front of it, to say
which of the two spellings their supervisor actually uses.

**`Forwarded` is not read, only the `X-` headers are.** `clientIp`, `host` and
`scheme` read `X-Forwarded-For`, `X-Forwarded-Host` and `X-Forwarded-Proto`
under `trusted_hops`
([ADR 0112](./adr/0112-a-request-can-be-read-past-the-parts-a-handler-names.md)).
RFC 7239's `Forwarded: for=…;host=…;proto=…` says the same three things in one
header with a grammar of its own, and a deployment whose proxy writes only that
one gets the defaults — the socket's address, the `Host` header, and `"http"`.

Nothing in the comparison writes it by default: nginx, HAProxy, Envoy, the
cloud load balancers and Cloudflare all send the `X-` headers, and several send
both. So this is a gap with no reported caller rather than a hole.

**Waiting on: a caller** running a proxy that writes `Forwarded` and nothing
else.

**A response a handler wrote can never answer 304.** An ETag is made in
`static.zig` — `etagFor` over a held file's bytes, `etagForSpilled` over a
mtime and a size — and matched by `static.etagMatches` against an
`If-None-Match` or the `If-Range` that `range.parse` reads. Those are the file
paths, and they are the only paths there are. A JSON endpoint polled every
five seconds sends the whole body every time, and a handler that wants to do it
by hand gets no help either: it reads `c.header("If-None-Match")`, works
something out, and calls `c.sendEmpty(304)`.

The reason this is not simply a middleware is
[ADR 0018](./adr/0018-the-trade-budget-has-three-axes.md). Hashing a response
means the body exists before the head is written, which the streaming paths do
not do, and it means a buffer to hash over. A weak validator the handler hands
in — a row's `updated_at`, a version column — costs nothing and is the shape
worth designing.

**Waiting on: a design** for what the handler hands over, given that nothing in
this framework should be hashing a body per request.

**A cookie cannot be bound to a handler argument.** A header can, since
[ADR 0163](./adr/0163-a-header-a-handler-can-be-given.md) —
`FromHeader("X-Tenant-Id", T)` — and the same question about a cookie has a
different answer: a cookie's name is not the problem, `Session(T)` already owns
the one cookie most programs read, and what is left is a bare cookie converted
by hand with `c.cookie`.

**Waiting on: a caller.** The header half was built because authentication put
one argument on every command endpoint in fourteen contexts; nothing has yet
asked for the cookie half at that scale.

**Every method nilo does not name is the same method.** `http1.Method` holds
seven and `other`, and `methodFrom` maps everything else onto that one tag, so
a route registered for `.other` answers `PROPFIND`, `PURGE` and `LINK` alike
and no two of them can be told apart or registered separately. `CONNECT` and
`TRACE` are in the same bucket, which is the right thing to do with them and is
not a decision anybody wrote down.

**Waiting on: a caller.** WebDAV, a cache purge and a handful of internal APIs
are the whole audience, and the shape that fixes it — a method carrying its own
text — costs a string compare on the request path that an enum tag does not.

**A request body that arrives compressed is refused rather than decoded.** A
`Content-Encoding` other than `identity` is a 415 naming the header
([ADR 0111](./adr/0111-a-body-under-an-encoding-nilo-cannot-read-is-refused.md)),
which is the answer for a server that cannot read what a body carries. Decoding
one is the inbound twin of the response-compression gap above and inherits the
same 64 KB window problem.

**Waiting on: a design**, the same one — a pool of compressors sized to the
thread count, which would serve both directions.

**Nothing tells a handler its client has gone.** `error.Canceled` comes from a
shutdown or from one of the deadlines the Engine sets; a client closing its
connection in the middle of a handler produces neither, so the work runs to the
end and the response is written into a socket nobody is reading. The other half
of this — cutting a slow handler off — is `nilo.deadline(ms)` now
([ADR 0133](./adr/0133-a-route-can-say-how-long-it-has.md)). This half is not,
and it is not simply unbuilt: **the obvious implementation is wrong.** A
read-side EOF is not "the client left". A client that sent `Connection: close`
and then `shutdown(SHUT_WR)` produces exactly that and is still waiting for its
response, so answering "peer gone" from it would abandon correct requests. Gin
gets the disconnect from `net/http` for nothing; Fiber does not have it either.

**Waiting on: a design** that separates "the client half-closed and is waiting"
from "the socket is gone", which is two named signals rather than one flag. What
is already real is a write that fails, and a handler sees that today.

**A cookie's value arrives exactly as the client wrote it, decoded by nothing.**
`Ctx.cookie` hands back the bytes between the delimiters and allocates nothing,
which is the design and is stated in the reference. What is worth naming is the
interop: Gin and Fiber both percent-decode on the way in, so a front end
storing a cookie with `encodeURIComponent` reads one string from JavaScript and
a different one from Zig.

**Waiting on: accepted.** Decoding would cost an allocation per cookie read on
a path that is deliberately free of them, and `nilo.percent.decode` is one call
away for a caller who knows their cookie is encoded.

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

**Whether nilo answers in anything but JSON.** `c.sendJson`, a returned value
and the API description are the whole serialisation story, beside
`c.send(status, type, bytes)` for somebody who produced the bytes themselves.
Gin ships XML, YAML, TOML, ProtoBuf and three JSON variants; Fiber ships XML,
CBOR, MsgPack and JSONP, and lets the JSON encoder itself be replaced. Being
JSON-only is a real decision here — it is part of what lets the signature
settle the document
([ADR 0017](./adr/0017-the-api-description-comes-from-the-signatures.md)) — and
it has never been written as one, which is why this is here rather than in
[Not coming](#not-coming).

**What would settle it: an API that has to answer XML** because the consumer is
somebody else's system that will not change. The question after that is whether
the answer is `c.send` with a serialiser of the caller's, or a second writer
inside this module — and the second costs binary size for every program that
links it, the way the API description already does.

**Whether a rule like "this is an email address" belongs in this repository.**
`Bound` reports five reasons a field did not bind — `missing`, `not_a_number`,
`not_true_or_false`, `not_a_choice`, `wrong_kind` — and `must` lets a handler
add a rule of its own to the same 422
([ADR 0082](./adr/0082-a-rule-of-your-own-joins-the-answer.md)). What is not
here is the vocabulary everybody else ships: `email`, `min`, `max`, `len`,
`oneof`, `url`, and Gin's `dive` for the elements of a list. Every application
writes those predicates itself.

The shape that would fit is not an annotation, and that is what makes the
question live: a rule is already an ordinary Zig function handed to `must`, so
`nilo.rules.email` would be a constant that costs nothing to a handler that
does not name it. The argument against is that a validator's vocabulary never
stops growing, and the reference says plainly today that this is not a
validator.

**What would settle it: three applications having written the same predicate**,
which is the evidence that it is vocabulary rather than policy.

**Whether a route can be scoped by host.** Everything matches on path. Fiber has
`app.Domain(…)` and `c.Subdomains()`, and what people use them for is a tenant
per subdomain, an admin surface on a hostname of its own, and an API beside a
marketing site in one process. The `Host` header is required and checked here
already
([ADR 0101](./adr/0101-a-request-nobody-else-would-answer-is-refused.md)), so
the fact is parsed; what does not exist is a way to route on it, since `useOn`
and `group` both scope by path prefix.

**What would settle it: a deployment that cannot put two processes behind the
proxy instead**, since that is the answer today and it is a good one.

**Which of the small middleware everybody else ships earn a place here.** Fiber
ships thirty-two. Setting aside the ones already queued above — CSRF, security
headers, compression — and the allowance, what is left is `basicauth`, `keyauth`,
`healthcheck`, `favicon`, `etag`, `cache`, `idempotency`, `responsetime`,
`redirect` (a map of old paths to new), `rewrite`, `proxy` and `skip`. Gin adds
only `BasicAuth` to that list. Most are between three and ten lines against
nilo's own middleware shape, and that is the argument on both sides: cheap to
ship, and cheap for an application to write, which is how a framework
accumulates them without ever deciding to.

Three are worth more than the rest, on the evidence of what people reach for
first: basic auth, a health-check route, and an idempotency key. The last is
the only one with a design under it, because it has to keep what it already
answered somewhere, and nothing in this framework stores anything between
requests.

**What would settle it: one of the three arriving with its storage question
answered**, rather than the list being adopted as a list.

---

## `nilo_sql`: Postgres and SQLite

### Next

**1. Four migration commands are missing, and two of them are the debt that
forward-only creates.** `generate`, `check`, `status`, `migrate` and `verify`
ship ([ADR 0153](./adr/0153-a-migration-is-a-diff-against-a-snapshot.md)). The
four that do not are `push` and `pull`, which are the SQLite and the rescue
cases, and `reset` and `squash`.

`reset` and `squash` are the ones that matter. There is no `down`, so a
developer whose laptop database is in a state no version describes has nothing
to type, and a project three years in has four hundred version files every CI
run reads. Skipping them does not remove that pain, it moves it onto somebody's
laptop and into somebody's build. `squash` is the harder half: it has to leave
the ledger of every database that already ran the old versions alone, which
means writing a new first version that is only ever applied to a database that
has applied nothing.

**Waiting on: a design** for what `squash` writes into the ledger of a database
that is already past it. Rewriting rows is out — that is the thing `verify`
exists to catch.

**2. Decide whether a SQLite statement hops or runs in the fiber.** The Wire
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

**3. A watched statement cannot say which request it came from.**
`db.watching` shows the text, the plan, the duration and the rows
([ADR 0137](./adr/0137-a-statement-can-be-watched.md)), so *which statement is
slow* is answerable. *Slow on which page* is not: a `Sent` carries no request
id and no route, and the one thing that knows both is the fiber the statement
is running on.

**Waiting on: a design.** `fail`'s message box is bound to the fiber
([ADR 0007](./adr/0007-failure-box-bound-to-the-fiber.md)) and reaching the
same threadlocal from a Service is the arrangement the standing risk about
`bulkhead.slot()` is already about. Handing the watcher the Scope is the other
answer and costs the plain function pointer.

**The values a statement bound are not shown, and that is the decision rather
than the gap.** What would close it honestly is a second flag whose name says
it puts personal data in a log, which is a thing to design rather than a thing
to default.

### Known gaps

**SQLite stores a `Timestamp` as an integer, and there is no way to ask for
text.** The check and the write agree now
([ADR 0136](./adr/0136-a-timestamp-is-checked-against-the-column-it-is-bound-into.md)),
so the column that matches what is bound is the one that passes. What is not
there is the choice: a database file whose times are readable as RFC 3339 is
what many SQLite schemas hold, and reaching it means `sql.AsText("timestamptz")`
and a conversion the caller writes.

**Waiting on: a caller.** A `time_form` beside `uuid_form` is the shape, and the
half it was waiting on is there:
[ADR 0159](./adr/0159-what-a-server-prints-it-can-read.md) gave `Timestamp` the
RFC 3339 parser this needs, so what is left is the Dialect choice rather than
the arithmetic.

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

One of these was closed the hard way rather than by the general fix: `uuid[]`
had no case in `listAccepts` at all, so a Row reading one passed the check and
failed on the first read. It answers `_uuid` now
([ADR 0145](./adr/0145-a-raw-parameter-is-converted-the-way-a-rows-is.md)), and
the gap that let it through is untouched.

**Waiting on: ready.** `assertStreamable` is the shape: a comptime walk over the
Row's fields at the top of `fill`, refusing a type that is neither a Dialect's
nor one of the protocols in `types.zig`, naming the field and the four ways to
make it readable (`AsText`, `Json`, an enum with `nilo_column`, or leaving it
out of the Row).

**A fiber that queues for the SQLite writer it already holds is told it might
be, rather than that it is.** The wait is bounded now
([ADR 0135](./adr/0135-a-wait-for-a-connection-has-a-bound.md)), so the
one-character mistake — `db.exec` inside a handler holding a `tx` — ends in a
`TimedOut` and a line naming the likely cause instead of parking for the life
of the process. What is left is telling that apart from an honestly busy
database, which needs to know *which fiber* holds the writer.

**Waiting on: upstream (`std.Io`)**, or a design that identifies a fiber
without it. `std.Io` hands a Service no fiber identity, and a flag on the Wire
cannot stand in: two fibers, one holding the `Tx` and one calling `db.exec`,
set the same flag and only one of them is a mistake.

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

What is left here is only the forgetting. The *second* way to end up without a
check — calling `checking` and getting a warning because the default pool had
dialled nothing — is closed
([ADR 0144](./adr/0144-a-check-dials-the-connection-it-needs.md)).

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

**`.ilike` writes the word `ILIKE` on both Dialects, and SQLite has no such
word.** The operator table in `where.zig` spells its own SQL and predates the
second Dialect, so `.email = .{ .ilike = text }` compiles against
`sql.Sqlite` and comes back a syntax error from the database. Nobody is using it
successfully, because it has never worked there.

Found while building the pattern operators, which go through `dialect.pattern`
precisely so they do not inherit this
([ADR 0173](./adr/0173-the-database-escapes-the-pattern-it-is-going-to-match.md)).
It was left alone rather than changed under cover of another feature.

**Waiting on: ready.** The fix is a Refusal naming the dialect, the way `.lock`
and `insertMany` already refuse there — turning a runtime syntax error into a
compile error, which is strictly better because no working code can depend on
it. `.like` is unaffected: both databases have that word.

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

**A deep page is still `OFFSET`, and nothing writes down the keyset form.**
The database counts past every row it is not going to answer with, which is the
one pagination shape that gets slower as the table grows. The sort can be made
stable now that an order term says where NULLs go
([ADR 0173](./adr/0173-the-database-escapes-the-pattern-it-is-going-to-match.md)
is a different entry; the order half is
[ADR 0171](./adr/0171-a-row-over-there-is-a-condition.md)'s neighbour in the
same cycle), so what is left is a condition the caller writes by hand — and a
guide page saying which one.

`DISTINCT` is not in this entry and is not coming: over one table with a key
every row appears once, so asking for it is almost always a sign the query
wanted something else. ADR 0058 makes the same argument for `UNION`.

**Waiting on: ready.** It is a guide page rather than a feature.

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

**Whether the line past one table moves further.** It moved once:
`.exists` is a condition and ships
([ADR 0171](./adr/0171-a-row-over-there-is-a-condition.md)). What is still
refused is joins, nested rows fetched with their parent, aggregates and
`GROUP BY`, with `db.raw` as the way out.

**And the four are now grouped for a reason rather than by habit.** ADR 0171
names the two properties that let `EXISTS` across: it does not change the column
list, so the Row still describes the answer, and it does not change the row
count, so `.limit` still means what the caller thinks. Every one of the four
above breaks at least one. A join to a one-to-many breaks both, and the second
of those is the expensive one — the query runs, the page renders, and some rows
never appear.

**What would settle it: a shape that keeps those two properties and the
statement a comptime constant.** Every property in ADR 0039 is downstream of the
last one, so anything that gives it up is a different module.

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
- **Waiting on the one-table line**: joins, nested rows and aggregates.
  Subqueries came off this list — `.exists` is a condition and ships
  ([ADR 0171](./adr/0171-a-row-over-there-is-a-condition.md)). The tooling
  commands wait on Next 1 rather than on a decision:
  [ADR 0153](./adr/0153-a-migration-is-a-diff-against-a-snapshot.md) made it and
  the library under them is built.
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

**`nilo_redis`: the same keyspace shape against somebody else's process.** A
Service rather than a tool module, and deliberately not the one built first
([ADR 0139](./adr/0139-an-in-process-cache-and-a-redis-client-are-two-modules.md)).
Two of the three usual reasons to reach for a Redis are already gone here —
a session is sealed into a cookie and an allowance is a table in this process —
so what is left is several instances having to agree, and nobody has brought
one. **The two will not share an interface**: what can fail differs, and hiding
that turns "the cache is down" into "the cache is cold". Both existing Zig
clients are alpha and neither has pub/sub, so a dependency would not hand over
cross-instance fan-out either; ADR 0139 records what each one does have.

**Waiting on: a caller.** Bring the deployment with more than one instance in
it, not the patch.

**Anything else that dials — a `nilo_mail`, a queue, a second store.** Nothing
structural is in the way. Each is a Fitting or a Service by one question rather
than a seam to design first: does it hold a connection to a named system, or is
it given an address per call
([ADR 0070](./adr/0070-a-fitting-borrows-the-loop.md))? `nilo_s3` is the worked
example of the second answer, and the most useful thing it leaves behind is
that `nilo_fetch` turned out to be the right size. It needed one addition,
`Exchange`, and no changes.

**The bar is what a caller cannot already do**, and mail is the example of
failing it: transactional mail is an HTTPS POST to a provider, which
`nilo_fetch` sends today. A module wrapping that is fifty lines of somebody's
own program plus a vendor's API to keep in step.

**Waiting on: a caller**, and this is still the most useful place for an
outside contributor to look — with the bar above applied first.

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

**0.3.0 needs Zig 0.16.**

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

**A `<!-- compiles -->` on a page nobody added to a list is silent, and it looks
exactly like one that is checked.** `zig build snippets` does not scan the
documentation; it reads a `pages` list in `build.zig`. A block marked on a page
that is not in that list is never compiled and never complained about, so the
mark means "somebody believed this" rather than "a build step read this" — and
the two are indistinguishable from the page.

That is this repository's own stated failure, a rule nobody runs wearing the
costume of a rule that does. **What makes it a class rather than an oversight is
that it propagates by being read.** The way to find out how a block is marked
here is to open a neighbouring guide page and copy what is above the fence — and
a dead mark is copied exactly as readily as a live one, because from the page
they are the same three words. So the defect reproduces through the ordinary,
correct habit of matching the surrounding code, and "somebody forgot to join the
list" understates it: more care does not help a reader who cannot tell the two
apart.

What would end it is **the step finding its pages by looking for marks** rather
than reading a list. Then a mark cannot be written anywhere the step will not
read it, and imitation stops being able to carry a dead one. The cost is a
directory walk at build time, on a step that already caches.

`docs/guide/sql.md` is the page this matters most for and the one furthest from
fixed: 48 Zig blocks, more than the README and the reference together, and not
one of them marked.

**Waiting on: ready** for the instance, which is an afternoon rather than a
line — adding a page to `pages` compiles nothing until a block on it is marked,
and the marking is the work.
[ADR 0083](./adr/0083-the-guide-is-the-source-of-its-own-snippets.md) records
that doing it to one five-line example found seven mistakes. **The class is
`Waiting on: a design`**, and it is the half worth keeping when the instance
closes.

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
