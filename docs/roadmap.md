# Roadmap

Where nilo is heading: a few directions, each larger than one change, each saying what it is for, what it depends on, and what would make it done, grouped by when. The concrete items live in [`todo.md`](./todo.md), ranked there by how much each matters; an entry that serves a direction says so on a `Direction:` line, and the list under each direction below is written from those lines by `zig build docs-index`. A direction never repeats an entry and never lists one that has left. Not every entry serves a direction, and that is the point: this file is where the framework is going, not everything that is open. The principles every direction is held to are at the top of [`CLAUDE.md`](../CLAUDE.md#guiding-principles) and in [ADR 017](./adr/017-the-trade-budget-has-four-axes.md)'s four axes.

[How this file is written](#how-this-file-is-written) is at the bottom.

## Where it is going

**One typed function answers whatever a client speaks, on a listener that can face the internet, beside a toolkit that covers the rest of a service; each of those is a type the caller already wrote, and each cost is a number on the record.** Today a route is HTTP/1.1, with gRPC beside it on a port of its own. The framing directions make a request one thing whether it came as HTTP/1.1, HTTP/2, gRPC or Connect, and a stream one shape for everything that does not end in one answer. The toolkit's database half already settles a query while compiling; what it has not met yet is the long life of a schema, a project years in. Under all of it the two hard axes stay numbers anybody can rerun, and a direction that moves one says so in its ADR before it lands. None of this is a promise of 1.0, which has no date and no criteria yet.

## Now

### A request is one thing, whatever framing carried it

**HTTP/1.1 and HTTP/2 become two framings of one request, and gRPC and Connect become envelopes over it, so one typed function can be a JSON route, a protobuf route and a gRPC method at once.** The seam is built: an answer is handed to the framing that carried its request, and an HTTP/2 call enters the App as what was read rather than as HTTP/1.1 text ([ADR 253](./adr/253-an-answer-is-handed-to-the-framing-that-carried-its-request.md)). A typed function now reads a protobuf message and answers one in the spelling it was asked in, JSON or protobuf, a gRPC call included ([ADR 256](./adr/256-a-body-is-read-as-what-its-type-says.md)), a Connect client that calls it is told a failure as the code it reads ([ADR 257](./adr/257-a-connect-client-is-told-its-failure-in-connect-words.md)), and a struct of such functions is a service served at the paths its `.proto` gives ([ADR 258](./adr/258-a-struct-of-typed-functions-is-an-rpc-service.md)). What it was built for is not yet: one request and one answer still has no room for HTTP/2 on an ordinary route.

What is left is designed whole in [ADR 259](./adr/259-http2-is-a-framing-of-every-request.md) and [ADR 260](./adr/260-a-request-on-http2-runs-from-its-headers.md) and laid out stage by stage on [the framing page](./design/framing.md#how-the-direction-is-built): HTTP/2 carrying every request on the port HTTP/1.1 is on, told apart by its first bytes; a request on HTTP/2 running from its headers, its body and its answer pipes under the client's windows, so a stream, a file, an upload and an event stream work on it as on HTTP/1.1; and then, only then, `h2` offered to a browser by ALPN on a `-Dtls` listener, which closes the gap [ADR 212](./adr/212-tls-is-an-option-a-build-asks-for.md) opened and revises [ADR 027](./adr/027-tls-is-terminated-in-front.md) in place. A session that pushes the numbers further follows it, with its list in the todo entries below.

<!-- gathered: `zig build docs-index` writes this list from the Direction lines in docs/todo.md -->

- [P1](./todo.md#p1-belongs-in-the-next-release) · `nilo_http` · The worst gRPC call is 1.4 s at 256 connections and 3.8 s at 1,024, where tonic's is about 1.1 s on the same four cores
- [P2](./todo.md#p2-evidence-it-matters) · `nilo_http` · `Ctx.header` reads the head again for every name it is asked, about 40 ns a time inside a request.
- [P2](./todo.md#p2-evidence-it-matters) · `nilo_http` · A message's `bytes` field is text in its JSON, where protobuf's JSON mapping makes it base64.
- [P2](./todo.md#p2-evidence-it-matters) · `nilo_http` · Whether a gRPC listener should keep an HPACK table, to stop decoding the same strings every call.
- [P2](./todo.md#p2-evidence-it-matters) · `nilo_http` · A gRPC listener has no health service, and the guide does not say how to write one.
- [P3](./todo.md#p3-no-evidence-yet) · `nilo_http` · Every request on HTTP/2 spawns a fiber, where HTTP/1.1 runs it on the connection's.
- [P3](./todo.md#p3-no-evidence-yet) · `nilo_http` · A file on HTTP/2 over plain TCP has no `sendfile`.
- [P3](./todo.md#p3-no-evidence-yet) · `nilo_http` · Priorities on HTTP/2 are ignored.
- [P3](./todo.md#p3-no-evidence-yet) · `nilo_http` · A Connect client's `Connect-Timeout-Ms` is not read.
- [P3](./todo.md#p3-no-evidence-yet) · `nilo_http` · A Connect GET is a 405.

<!-- /gathered -->

**What would settle it:** stages 4 and 5 of the framing page landed, each measured against the build before it on all four axes with the HTTP/1.1 path unchanged on the two hard ones, and the idle figure of an HTTP/2 connection serving ordinary routes on record before a browser is offered `h2`.

## Alongside

Independent of the order: each touches files no stage of the direction above does, so it is picked up between stages or by a second pair of hands ([ADR 038](./adr/038-a-module-sits-where-the-loop-puts-it.md)).

### Defects are caught by a build step before a reader

**The audits keep finding the same kinds of defect, so each kind becomes a rule the build refuses rather than a finding the next audit repeats.** A decision written in several places that stopped agreeing (whether a field may be absent is decided in six), an error swallowed on a connection path, an `unreachable` a request can reach, and a code example in a header that no longer compiles: three of those four are spellable, and the first is a fix that closes its defects for good where a patch to each copy closes them until the next copy. The public surface read back against the reference belongs here too, because a name that should not be public is a break before 1.0 and a promise after it.

<!-- gathered: `zig build docs-index` writes this list from the Direction lines in docs/todo.md -->

- [P1](./todo.md#p1-belongs-in-the-next-release) · `nilo_http` · `?T` with no default means optional in a query and required in a body.
- [P1](./todo.md#p1-belongs-in-the-next-release) · `nilo_http` · One rule, one function: the audit's largest source of defects is a decision written in several places that stopped agreeing.
- [P2](./todo.md#p2-evidence-it-matters) · Every module · The public surface has not been read back against the reference.
- [P2](./todo.md#p2-evidence-it-matters) · `nilo_http` · Several comments and pages describe code that is no longer there.
- [P2](./todo.md#p2-evidence-it-matters) · `nilo_http` · A rule a build step holds against the patterns the audit kept finding.
- [P2](./todo.md#p2-evidence-it-matters) · `nilo_http` · A mutation pass over the request path.

<!-- /gathered -->

**What would settle it:** each of those entries closed, and the next audit of `http/` finding no defect of a kind a step could have refused.

### Every byte an idle connection holds is on the record

**The idle figure is the number nilo sells, and it has stopped being one anybody can account for byte by byte.** An idle connection grew 512 bytes between v0.2.0 and v0.3.0 with no ADR stating it; the documents teach a 64 KiB stack buffer in a body stream that one page says costs every idle connection and another says costs none; and how close a plain connection parks to a page boundary is not known, so the next change to the connection loop could cost a page per connection and be noticed only by whoever next runs `bench/mem.py`. This direction puts each of those back on the record, with the outbound side's figures beside them ([ADR 017](./adr/017-the-trade-budget-has-four-axes.md), [ADR 062](./adr/062-where-a-connection-waits-is-what-it-costs.md)).

<!-- gathered: `zig build docs-index` writes this list from the Direction lines in docs/todo.md -->

- [P1](./todo.md#p1-belongs-in-the-next-release) · `nilo_http` · An idle connection grew 512 bytes between v0.2.0 and v0.3.0, and no ADR states it.
- [P1](./todo.md#p1-belongs-in-the-next-release) · `nilo_http` · Either every `bodyStream` example costs 64 KiB on every idle connection, or ADR 062 is wrong about it.
- [P2](./todo.md#p2-evidence-it-matters) · `nilo_fetch` · A plain call costs 4,139 bytes on every idle connection
- [P2](./todo.md#p2-evidence-it-matters) · `nilo_fetch` · What an outbound call costs through TLS is read off buffer sizes, not measured.
- [P2](./todo.md#p2-evidence-it-matters) · `nilo_http` · What a connection inside a request holds now that `read_buffer` is 16 KiB is arithmetic, not a reading.
- [P2](./todo.md#p2-evidence-it-matters) · `nilo_http` · How far under a page boundary a plain connection parks is not known, so every change to the connection loop is one page per idle connection away from going unnoticed.

<!-- /gathered -->

**What would settle it:** ADR 017's figure matching what `bench/release.py` reads on the benchmark server, every byte of the difference from 4,669 owned by an ADR, and the park depth printed by a run a change to the connection loop can be checked against.

## Next

### A stream is one shape

**A WebSocket, an event stream, a gRPC stream, a streamed upload and a compressed stream become one kind of handler: one that reads and writes in pieces, on a fiber that lives as long as the stream.** Each exists today in its own form or not at all: a WebSocket is a handler that does not return ([ADR 021](./adr/021-a-websocket-is-a-handler-that-does-not-return.md)), an event stream is written by hand, a gRPC call carries exactly one message, a multipart body is read whole, and a stream is never compressed. They share the one cost that matters, a fiber and its stack for the life of the stream ([ADR 062](./adr/062-where-a-connection-waits-is-what-it-costs.md)), so they should share the one shape that names it.

It depends on the direction under **Now**: the two pipes of [ADR 260](./adr/260-a-request-on-http2-runs-from-its-headers.md), a body read and an answer written in pieces under the client's windows, are what a gRPC stream is carried on, and what this direction adds is the shape a handler writes one in.

<!-- gathered: `zig build docs-index` writes this list from the Direction lines in docs/todo.md -->

- [P2](./todo.md#p2-evidence-it-matters) · `nilo_http` · A gRPC listener answers unary calls only.
- [P2](./todo.md#p2-evidence-it-matters) · `nilo_http` · Multipart, streamed.
- [P3](./todo.md#p3-no-evidence-yet) · `nilo_http` · A stream is never compressed, and neither is an event stream; and gzip is the only coding.

<!-- /gathered -->

**What would settle it:** a design that makes the existing WebSocket and event stream handlers instances of it rather than a fourth form beside them, a gRPC server stream as its first new use, and the per-stream figure for a stream held open measured the way `bench/mem.py --hold` measures an HTTP/1.1 one.

### A migration history a project can keep for years

**A schema that changes for years is the case `nilo_sql`'s migrations have not met yet: there is no way back for a laptop, no way to keep the version list short, and no way to change a big live table without blocking its writes.** Forward-only versions diffed against a snapshot ship ([ADR 123](./adr/123-a-migration-is-a-diff-against-a-snapshot.md)). What a project three years in meets is what is missing around them: `reset` and `squash`, an index built `CONCURRENTLY` outside its version's transaction, a table renamed rather than dropped, SQLite's rebuild as a step rather than a recipe, a Problem with a way out other than editing `snapshot.zon`, and the locks and words of each step made to match what runs. It depends on nothing in `http/`, so it can run beside the stream work.

<!-- gathered: `zig build docs-index` writes this list from the Direction lines in docs/todo.md -->

- [P1](./todo.md#p1-belongs-in-the-next-release) · `nilo_sql` · Whether two replicas applying migrations at once are safe under REPEATABLE READ.
- [P1](./todo.md#p1-belongs-in-the-next-release) · `nilo_sql` · Whether `expect` can boot under a role that may only read and write rows.
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

## Later

### A listener can face the internet with nothing in front

**[ADR 212](./adr/212-tls-is-an-option-a-build-asks-for.md) made a TLS listener something a build asks for, and what it has not met yet is a year in production with nothing in front of it.** A certificate that renews every sixty days is a restart every sixty days; a second name needs a second listener; a client whose first key share is not X25519 is refused rather than asked again; and the library is pinned to a fork until two commits reach upstream. Each is small, and together they are the difference between a listener that works in a test and one an operator leaves running. It depends on stage 5 of the direction under **Now**, since `h2` offered by ALPN is what a browser reaching such a listener expects. It revises nothing: [ADR 027](./adr/027-tls-is-terminated-in-front.md)'s proxy in front stays the default answer, and this is the build that asked otherwise.

<!-- gathered: `zig build docs-index` writes this list from the Direction lines in docs/todo.md -->

- [P1](./todo.md#p1-belongs-in-the-next-release) · `nilo_http` · Does a WebSocket over TLS park with a whole frame already decrypted-able in the record layer's buffer?
- [P2](./todo.md#p2-evidence-it-matters) · `nilo_http` · A TLS listener that reloads its certificate without a restart.
- [P2](./todo.md#p2-evidence-it-matters) · `nilo_http` · A client whose first key share is not X25519 is refused rather than asked again, because the TLS listener has no HelloRetryRequest.
- [P2](./todo.md#p2-evidence-it-matters) · `nilo_http` · The TLS pin is a fork, `nevindra/tls.zig`, until two commits reach upstream.
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
