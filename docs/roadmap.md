# Roadmap

Where nilo is heading: a few directions, each larger than one change, each saying what it is for, what it depends on, and what would make it done, grouped by when. The concrete items live in [`todo.md`](./todo.md), ranked there by how much each matters; an entry that serves a direction says so on a `Direction:` line, and the list under each direction below is written from those lines by `zig build docs-index`. A direction never repeats an entry and never lists one that has left. Not every entry serves a direction, and that is the point: this file is where the framework is going, not everything that is open. The principles every direction is held to are at the top of [`CLAUDE.md`](../CLAUDE.md#guiding-principles) and in [ADR 017](./adr/017-the-trade-budget-has-four-axes.md)'s four axes.

[How this file is written](#how-this-file-is-written) is at the bottom.

## Where it is going

**One typed function answers whatever a client speaks, on a listener that can face the internet, beside a toolkit that covers the rest of a service; each of those is a type the caller already wrote, and each cost is a number on the record.** A route is one thing whether it came as HTTP/1.1, HTTP/2, gRPC or Connect; what is left is a stream that is one shape for everything that does not end in one answer. The toolkit's database half already settles a query while compiling; what it has not met yet is the long life of a schema, a project years in. Under all of it the two hard axes stay numbers anybody can rerun, and a direction that moves one says so in its ADR before it lands. None of this is a promise of 1.0, which has no date and no criteria yet.

## Now

Nothing is being built as a direction at present.

## Alongside

Independent of the order: each touches files no stage of the direction above does, so it is picked up between stages or by a second pair of hands ([ADR 038](./adr/038-a-module-sits-where-the-loop-puts-it.md)).

### Defects are caught by a build step before a reader

**The audits keep finding the same kinds of defect, so each kind becomes a rule the build refuses rather than a finding the next audit repeats.** A decision written in several places that stopped agreeing (whether a field may be absent is decided in six), an error swallowed on a connection path, an `unreachable` a request can reach, and a code example in a header that no longer compiles: three of those four are spellable, and the first is a fix that closes its defects for good where a patch to each copy closes them until the next copy. The public surface read back against the reference belongs here too, because a name that should not be public is a break before 1.0 and a promise after it.

<!-- gathered: `zig build docs-index` writes this list from the Direction lines in docs/todo.md -->

- [P1](./todo.md#p1-belongs-in-the-next-release) · `nilo_http` · One rule, one function: the audit's largest source of defects is a decision written in several places that stopped agreeing.
- [P2](./todo.md#p2-evidence-it-matters) · Every module · The public surface has not been read back against the reference.
- [P2](./todo.md#p2-evidence-it-matters) · `nilo_http` · Several comments and pages describe code that is no longer there.
- [P2](./todo.md#p2-evidence-it-matters) · `nilo_http` · A rule a build step holds against the patterns the audit kept finding.
- [P2](./todo.md#p2-evidence-it-matters) · `nilo_http` · A mutation pass over the request path.

<!-- /gathered -->

**What would settle it:** each of those entries closed, and the next audit of `http/` finding no defect of a kind a step could have refused.

### Every byte an idle connection holds is on the record

**The idle figure is the number nilo sells, and what it is made of is not yet all on the record.** What is open is the `-Dtls` build's second page, whether an idle HTTP/1.1 connection needs a fiber at all, `nilo_fetch`'s per-call figures and what a connection inside a request holds, and this direction puts each on the record ([ADR 017](./adr/017-the-trade-budget-has-four-axes.md), [ADR 062](./adr/062-where-a-connection-waits-is-what-it-costs.md)).

<!-- gathered: `zig build docs-index` writes this list from the Direction lines in docs/todo.md -->

- [P2](./todo.md#p2-evidence-it-matters) · `nilo_fetch` · A plain call costs 4,139 bytes on every idle connection
- [P2](./todo.md#p2-evidence-it-matters) · `nilo_fetch` · What an outbound call costs through TLS is read off buffer sizes, not measured.
- [P2](./todo.md#p2-evidence-it-matters) · `nilo_http` · What a connection inside a request holds now that `read_buffer` is 16 KiB is arithmetic, not a reading.
- [P2](./todo.md#p2-evidence-it-matters) · `nilo_http` · A `-Dtls` build parks 96 bytes past a page boundary, which costs 4,109 bytes on every idle connection of its plain listener, and a `-Dhttp2` build sits 64 bytes under it.
- [P2](./todo.md#p2-evidence-it-matters) · `nilo_http` · An idle HTTP/1.1 connection that has no fiber costs about 700 to 770 bytes in a prototype, where one with a fiber costs 4,678, and nothing about it is decided.

<!-- /gathered -->

**What would settle it:** the `-Dtls` page given back or recorded as the cost of that build in ADR 017, and the outbound figures read instead of derived.

## Next

### A stream is one shape

**A WebSocket, an event stream, a gRPC stream, a streamed upload and a compressed stream become one kind of handler: one that reads and writes in pieces, on a fiber that lives as long as the stream.** Each exists today in its own form or not at all: a WebSocket is a handler that does not return ([ADR 021](./adr/021-a-websocket-is-a-handler-that-does-not-return.md)), an event stream is written by hand, a gRPC call carries exactly one message, a multipart body is read whole, and a stream is never compressed. They share the one cost that matters, a fiber and its stack for the life of the stream ([ADR 062](./adr/062-where-a-connection-waits-is-what-it-costs.md)), so they should share the one shape that names it.

It builds on the HTTP/2 framing that has landed: the two pipes of [ADR 260](./adr/260-a-request-on-http2-runs-from-its-headers.md), a body read and an answer written in pieces under the client's windows, are what a gRPC stream is carried on, and what this direction adds is the shape a handler writes one in.

<!-- gathered: `zig build docs-index` writes this list from the Direction lines in docs/todo.md -->

- [P2](./todo.md#p2-evidence-it-matters) · `nilo_http` · A gRPC listener answers unary calls only.
- [P2](./todo.md#p2-evidence-it-matters) · `nilo_http` · Multipart, streamed.
- [P3](./todo.md#p3-no-evidence-yet) · `nilo_http` · A stream is never compressed, and neither is an event stream; and gzip is the only coding.

<!-- /gathered -->

**What would settle it:** a design that makes the existing WebSocket and event stream handlers instances of it rather than a fourth form beside them, a gRPC server stream as its first new use, and the per-stream figure for a stream held open measured the way `bench/mem.py --hold` measures an HTTP/1.1 one.

### A migration history a project can keep for years

**A schema that changes for years is the case `nilo_sql`'s migrations have not met yet: there is no way back for a laptop, no way to keep the version list short, and no way to change a big live table without blocking its writes.** Forward-only versions diffed against a snapshot ship ([ADR 123](./adr/123-a-migration-is-a-diff-against-a-snapshot.md)). What a project three years in meets is what is missing around them: `reset` and `squash`, an index built `CONCURRENTLY` outside its version's transaction, a table renamed rather than dropped, SQLite's rebuild as a step rather than a recipe, a Problem with a way out other than editing `snapshot.zon`, and the locks and words of each step made to match what runs. It depends on nothing in `http/`, so it can run beside the stream work.

<!-- gathered: `zig build docs-index` writes this list from the Direction lines in docs/todo.md -->

- [P2](./todo.md#p2-evidence-it-matters) · `nilo_sql` · Migration steps and their words disagree with what runs.
- [P2](./todo.md#p2-evidence-it-matters) · `nilo_sql` · `reset` and `squash` are missing from the migrations, and they are the debt that forward-only creates.
- [P2](./todo.md#p2-evidence-it-matters) · `nilo_sql` · An index on a big live Postgres table cannot be built without blocking its writes.
- [P2](./todo.md#p2-evidence-it-matters) · `nilo_sql` · A case-folding unique made before `text_pattern_ops` keeps the index `istarts_with` cannot read.
- [P2](./todo.md#p2-evidence-it-matters) · `nilo_sql` · `db generate` reuses a version number when the snapshot is ahead of the newest file.
- [P2](./todo.md#p2-evidence-it-matters) · `nilo_sql` · A table cannot be renamed, and a foreign key has no `ON UPDATE`.
- [P2](./todo.md#p2-evidence-it-matters) · `nilo_sql` · The SQLite rebuild is a recipe in a Problem rather than a step.
- [P2](./todo.md#p2-evidence-it-matters) · `nilo_sql` · `expect` compares the ledger's head only, and the startup check reads columns only.
- [P2](./todo.md#p2-evidence-it-matters) · `nilo_sql` · Migrations write more statements, and take more locks, than the change needs.
- [P2](./todo.md#p2-evidence-it-matters) · `nilo_sql` · A Problem from the diff has no way out but editing `snapshot.zon` by hand.

<!-- /gathered -->

**What would settle it:** a history replayed from its first version and from a squash to the same schema, a `CONCURRENTLY` index built on a table large enough to take seconds while writes go on, and every step's `why` matching what it locks, each held by a live test.

### A failure is a type

**A failure becomes something a handler states in its signature and a client can read field by field, the way a success already is.** Three decisions hold the failure side to one sentence today: a failure body is a status and a message ([ADR 024](./adr/024-every-failure-answers-as-json.md)), an error the mapping table does not name is a 500 (`fail.statusFor`), and the document names one failure an endpoint ([decided](./decided.md)). Each was right when it was made, and what has been built since has moved them: `Bound` knows every field that failed and why ([ADR 034](./adr/034-a-binding-hands-its-failures-to-the-handler.md)), and a `union(enum)` of `Status(code, T)` is the "shape that states a failure in the type" the decided entry waits for. Echo, Fastify, Nest and Hono all give an application one place to map a domain error to a status and a per-field body a form can read, so this is the gap a migrant from either side meets first after the happy path works. It costs the failure path only, and its one number to state is the bytes it adds to the failure slot.

<!-- gathered: `zig build docs-index` writes this list from the Direction lines in docs/todo.md -->

- [P2](./todo.md#p2-evidence-it-matters) · `nilo_http` · A failure is one sentence, so a client cannot mark the field that failed.
- [P2](./todo.md#p2-evidence-it-matters) · `nilo_http` · An error from code that does not know about HTTP cannot be given a status once, for the whole App.
- [P2](./todo.md#p2-evidence-it-matters) · `nilo_http` · A handler answers one body type, so a second status with a different shape is a sentence the document never sees.

<!-- /gathered -->

**What would settle it:** a form that marks the field that failed from the body alone, a service-layer `error.EmailTaken` answered as a 409 with no `fail` call and no `catch`, and a handler with two typed answers whose document lists both, with the success path's allocations and instructions unchanged in `bench/release.py`.

### A developer from Go or Node meets no silent trap in the first week

**The habits a Go or Node developer brings either work in nilo or stop the compiler, and none of them compiles and does the wrong thing.** The traps the design review at 0.7.0 found are of one kind: a path param matched by position, so two ids swap without a word; a middleware with no arguments, so its key store is a global or a lookup that fails open; a renamed struct that cannot be read back; a JSON log line that is not JSON; a route deadline that the calls it makes never hear of; a server in a container listening on loopback; a panic that takes every connection with no warning that the root cannot name the request. Around them are the things that are only slow to find: validation taught under forms, a second service of the same type, dates that live in `nilo_sql`, and six steps before the first route. Most of these change the API every user writes, so they are paid before 1.0 under principle 3 rather than carried past it.

<!-- gathered: `zig build docs-index` writes this list from the Direction lines in docs/todo.md -->

- [P2](./todo.md#p2-evidence-it-matters) · `nilo_http` · Path params are matched by position, so two of the same type in the wrong order compile and read the wrong row.
- [P2](./todo.md#p2-evidence-it-matters) · `nilo_http` · A middleware is a bare function pointer, so it cannot be given a setting or a service, and the first one a team writes reaches for a global or for a lookup that fails open.
- [P2](./todo.md#p2-evidence-it-matters) · `nilo_http` · A renamed struct cannot be a request body, and the reason the guide gives no longer holds.
- [P2](./todo.md#p2-evidence-it-matters) · `nilo_http` · A JSON log line is not JSON, and a line a handler logs cannot be joined to its request.
- [P2](./todo.md#p2-evidence-it-matters) · `nilo_http` · `Timestamp` and `Date` are in `nilo_sql`, so an HTTP-only service with a date in its body turns on `-Dsql` or carries text.
- [P2](./todo.md#p2-evidence-it-matters) · `nilo_http` · A route's deadline stops at the route: the calls it makes keep their own.
- [P2](./todo.md#p2-evidence-it-matters) · `nilo_http` · A rate limit, the access log's level and the CSP are fixed while compiling, so a deployment cannot set them from its environment.
- [P2](./todo.md#p2-evidence-it-matters) · `nilo_http` · The validation types are taught under forms only, and the two largest examples check by hand.
- [P2](./todo.md#p2-evidence-it-matters) · `nilo_http` · A second service of the same type is refused with a bare error, and the way round it is written only in an ADR.
- [P2](./todo.md#p2-evidence-it-matters) · `nilo_http` · A first project is six steps before its first route, and nothing writes them.
- [P2](./todo.md#p2-evidence-it-matters) · `nilo_http` · A server in a container listens where nothing can reach it, and no page shows a container build.
- [P2](./todo.md#p2-evidence-it-matters) · `nilo_http` · A panic ends the process, and `listen()` does not say so when the root file has no `nilo.panic` to name the request that did it.

<!-- /gathered -->

**What would settle it:** a person who has written Go or Node services and not nilo builds `examples/rest` again from the getting-started page with a database, a login middleware and a container, and every mistake they make is a compile error or a refusal at `listen()` naming the fix.

### A second instance changes no answer

**A program behind a balancer gives the same answer whichever instance a request reaches, or says at startup and in its pages that it does not.** [ADR 110](./adr/110-an-in-process-cache-and-a-redis-client-are-two-modules.md) bet on one process, and named what goes quietly wrong at two: a cache that answers by instance, an allowance that admits N times its limit, and a Room that reaches only its own sockets. `Idempotent` is the costly one, because a retry is exactly what reaches the other instance, and a rolling deploy is two instances for everybody. The bet stays the default: nothing here costs a route that does not ask. What changes is that each in-process store gets a seam a shared one plugs into, `Idempotent` first because a database it can use is already in most programs ([ADR 160](./adr/160-a-queue-is-a-table-in-the-database-you-already-have.md)), and that the pages say what ADR 110 promised they would. It meets the toolkit direction under Later at the Room: that direction builds the store, this one builds the hook.

<!-- gathered: `zig build docs-index` writes this list from the Direction lines in docs/todo.md -->

- [P2](./todo.md#p2-evidence-it-matters) · `nilo_http` · `Idempotent` answers once per key per process, so a retry that the balancer sends to another instance runs the handler again.
- [P2](./todo.md#p2-evidence-it-matters) · `nilo_http` · `allowance` keeps its table in the process and has no seam for a shared one
- [P2](./todo.md#p2-evidence-it-matters) · `nilo_http` · A Room belongs to one process and has no hook a bridge could use, so a chat served from two instances is two chats.
- [P3](./todo.md#p3-no-evidence-yet) · `nilo_http` · Whether a pre-fork worker mode is worth what it costs is not known.

<!-- /gathered -->

**What would settle it:** an `Idempotent` route answering a retry once across two instances through a rolling restart, an allowance holding its limit across two, and the chat example delivering across two, each in a live test.

## Later

### A listener can face the internet with nothing in front

**[ADR 212](./adr/212-tls-is-an-option-a-build-asks-for.md) made a TLS listener something a build asks for, and what it has not met yet is a year in production with nothing in front of it.** A certificate that renews every sixty days is a restart every sixty days; a second name needs a second listener; a client whose first key share is not X25519 is refused rather than asked again; and the library is pinned to a fork until two commits reach upstream. Each is small, and together they are the difference between a listener that works in a test and one an operator leaves running. `h2` offered by ALPN, which a browser reaching such a listener expects, has landed ([ADR 259](./adr/259-http2-is-a-framing-of-every-request.md)). It revises nothing: [ADR 027](./adr/027-tls-is-terminated-in-front.md)'s proxy in front stays the default answer, and this is the build that asked otherwise.

<!-- gathered: `zig build docs-index` writes this list from the Direction lines in docs/todo.md -->

- [P2](./todo.md#p2-evidence-it-matters) · `nilo_http` · A WebSocket over TLS has no test of its own for a second frame that arrived with the first.
- [P2](./todo.md#p2-evidence-it-matters) · `nilo_http` · A TLS listener that reloads its certificate without a restart.
- [P2](./todo.md#p2-evidence-it-matters) · `nilo_http` · A client whose first key share is not X25519 is refused rather than asked again, because the TLS listener has no HelloRetryRequest.
- [P2](./todo.md#p2-evidence-it-matters) · `nilo_http` · The TLS pin is a fork, `nevindra/tls.zig`, until two commits reach upstream's `main`.
- [P3](./todo.md#p3-no-evidence-yet) · `nilo_http` · Client certificates on a TLS listener.
- [P3](./todo.md#p3-no-evidence-yet) · `nilo_http` · Session resumption on a TLS listener.
- [P3](./todo.md#p3-no-evidence-yet) · `nilo_http` · More than one certificate on a listener, chosen by SNI.
- [P3](./todo.md#p3-no-evidence-yet) · `nilo_http` · What kernel TLS would buy a TLS listener is not measured.
- [P3](./todo.md#p3-no-evidence-yet) · `nilo_http` · A ClientHello split across two records is refused by the TLS listener rather than reassembled
- [P3](./todo.md#p3-no-evidence-yet) · `nilo_http` · Plain HTTP sent to a TLS port is held as a 12 KB record that never finishes rather than refused on sight.

<!-- /gathered -->

**What would settle it:** a certificate renewed under load with no restart and no failed handshake, every client in ADR 212's set completing a handshake, one that offers P-256 first included, and the pin back on upstream's tls.zig.

### The toolkit grows by the jobs people have

**A module gets built because the job is common, and the evidence for that is a program that needs it, one of the examples here as much as a stranger's** ([ADR 017](./adr/017-the-trade-budget-has-four-axes.md), [ADR 038](./adr/038-a-module-sits-where-the-loop-puts-it.md)). The bar is what a caller cannot already do, and mail is the example of failing it: transactional mail is an HTTPS POST to a provider, which `nilo_fetch` sends today.

**`nilo_redis` is the next module, and the job that would show it is the chat example served from two instances.** A Service rather than a tool module, and deliberately not the one built first ([ADR 110](./adr/110-an-in-process-cache-and-a-redis-client-are-two-modules.md)). Two of the three usual reasons to reach for a Redis are already gone here, a session is sealed into a cookie and an allowance is a table in this process, and the first case of several instances having to agree, a queue shared by several servers, was answered by the database they already share ([ADR 160](./adr/160-a-queue-is-a-table-in-the-database-you-already-have.md)). What is left is a message one instance has to hand to the sockets another holds, which is pub/sub. **The two will not share an interface**: what can fail differs, and hiding that turns "the cache is down" into "the cache is cold". Both existing Zig clients are alpha and neither has pub/sub; ADR 110 records what each one does have.

**Anything else that dials, a second store or another protocol, is a Fitting or a Service by one question**: does it hold a connection to a named system, or is it given an address per call ([ADR 061](./adr/061-a-fitting-borrows-the-loop.md))? `nilo_s3` is the worked example of the second answer, and the most useful thing it leaves behind is that `nilo_fetch` turned out to be the right size: it needed one addition, `Exchange`, and no changes.

<!-- gathered: `zig build docs-index` writes this list from the Direction lines in docs/todo.md -->

No entry in the todo list names this direction yet.

<!-- /gathered -->

**What would settle it:** the chat example running on two instances with a message sent to one reaching a socket held by the other, either through `nilo_redis` or through Postgres' `LISTEN/NOTIFY` measured against it, whichever the numbers pick. This is still the most useful place for an outside contributor to look.

---

## How this file is written

**1. A direction is larger than one change.** Anything that fits in one change is an entry in [`todo.md`](./todo.md), and its rules are there. A direction says what it is for, which ADRs it revises, what it depends on, and closes with `What would settle it:`.

**2. A direction lists its entries by being named, never by naming them.** A todo entry that serves a direction carries a `**Direction:**` line linking the direction's heading, and `zig build docs-index` writes the list between the two `gathered` markers under that heading from those lines; `docs-check` refuses a list out of step and a direction with no markers. Prose here may mention an entry's subject, never maintain a list of entries by hand.

**3. Nothing built and nothing decided is in here.** A direction that has landed leaves entirely, the way a todo entry does; what was learned goes to [`history.md`](./history.md) and the decision to an ADR.

**4. The order is when, and the headings say it.** **Now** is the direction being built; **Alongside** is work that depends on no direction and is picked up between stages; **Next** is what starts when **Now** lands or frees a hand; **Later** is the rest. A direction that needs another says so. There are no dates, owners or tiers here: how much one entry matters is the todo list's tier, and how much a direction matters is where it sits.

**5. A direction is held to the principles, not exempt from them.** Breaking a public API is allowed when the result is the cleaner design, and the four axes of [ADR 017](./adr/017-the-trade-budget-has-four-axes.md) are not: a direction that cannot fit them waits for the shape that does.

**6. The order is read again at each release**, when the todo list is ranked again ([its rule 9](./todo.md#how-this-file-is-written)): a direction whose **What would settle it** has come true leaves, and the one under **Next** that the numbers favour moves up.
