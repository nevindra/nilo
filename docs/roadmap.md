# Roadmap

What is next, what is known and waiting for somebody to need it, and what nobody has decided. Nothing else. Once something is built its entry leaves this file: what shipped is in [`CHANGELOG.md`](../CHANGELOG.md), what was measured and learned on the way is in [`history.md`](./history.md), and the decisions that are binding are in [`adr/`](./adr/). What nilo has decided *not* to do, and the questions that have been answered so they are not asked again, are in [`decided.md`](./decided.md). The risks that have no mechanism under them yet are in [`risks.md`](./risks.md#open).

What this document is measured against is [ADR 014](./adr/014-what-nilo-borrows-and-from-whom.md): **the signature is the whole contract**, on a server whose memory you can put a number on. A feature that does not serve one of those two is not automatically refused, but it has to say what it is for.

[How this file is written](#how-this-file-is-written) is at the bottom, and it is the part to read before adding to it.

## How to read this

Six sections, and an entry is in exactly one of them by what it is waiting for:

| Section | What is in it | Ends with |
|---|---|---|
| [**Defects**](#defects) | behaviour that is wrong today: it contradicts its own ADR or design page, loses data, or hands a stranger something. Found and checked against the code, not yet fixed | `Needs:` the fix, and the test that would have caught it |
| [**Next**](#next) | work somebody could start. The mechanism is known; what is missing is a decision, and the entry says which | `Needs:` the decision |
| [**Known, waiting for a caller**](#known-waiting-for-a-caller) | the design is known and nobody has needed it yet. Bring the use case, not the patch | `Needs:` the caller |
| [**Open questions**](#open-questions) | a question nobody has answered. Not a backlog item | `What would settle it:` |
| [**Measurements outstanding**](#measurements-outstanding) | a decision waiting on a number, and the run that would produce it | the table's last column |
| [**Waiting on upstream**](#waiting-on-upstream) | the change is in somebody else's repository, with the pin it was last checked at | the table's last column |

Inside the first four, entries are grouped by module, because **two modules touch no file in common** ([ADR 038](./adr/038-a-module-sits-where-the-loop-puts-it.md)): two entries under different modules can be worked at the same time, by two people or by one person on two days.

**A `Waiting on upstream` row is the line to distrust.** This repository has been wrong about a blocker six times, and each time the code it was waiting for already did the thing ([history](./history.md)): the latest was a signer hook in tls.zig, whose fork nilo already publishes. Nothing downstream ever re-tests a blocker, so re-test it before repeating it.

**0.6.0 needs Zig 0.16.** The latest stable release only, on one branch: the people this is aimed at download Zig, run `zig build`, and give up if it fails, and they are not going to go hunting for the right branch. Every new Zig release brings a few awkward weeks, made worse by zio following a branch-per-version pattern too.

---

## Defects

Behaviour that is wrong today. Each entry was found by reading a design page against the code under it and checked in the code; **reproduced** means it was also run. An entry leaves once its fix and the test that would have caught it land, and a claim an ADR makes that the code does not keep is corrected in that ADR with the fix, not before.

### `nilo_http`

**`nilo.deadline(ms)` never shortens the write limit.** The write limit is armed once per connection before any request, and `giveDeadline` stores `until_ns` without re-arming it, so a route with a two-second deadline sending a large body to a slow reader runs for minutes, where `deadline.zig`'s header and [the deadlines page](./design/deadlines.md) say the clamp covers the write.

**Needs:** the write limit clamped with the read ones, or the claim narrowed in both places.

**Three HTTP/1.1 edges are read differently from the RFC.** `Transfer-Encoding: gzip, chunked` is accepted and the handler reads gzip as its body, where RFC 9110 says 501. An HTTP/1.0 request carrying `Transfer-Encoding` stays open. A CRLF before the request line is a 400 rather than skipped (RFC 9112 §2.2).

**Needs:** each one answered as its RFC section says, with a test per section in the parser's file.

**A form body can cost thirty times its size, and a multipart one CPU in proportion to parts times bytes.** `parseQuery` allocates a `Param` per `&` before it reads anything, so a megabyte of `&` to a `Form(T)` route is 33 MB of arena; multipart has `max_parts` against exactly this and urlencoded has nothing. `endOfPartHead` searches for `\n\n` to the end of the body for every part, so 255 parts and a megabyte of padding cost 78 ms of CPU where 1 ms is enough. Reproduced.

**Needs:** a pair limit on urlencoded, and the bare-LF search bounded by the CRLF match.

**An `Idempotent` replay leaves out what the handler set through `*Ctx`.** Only a `Response(T)`'s or a `Bytes`' own headers are kept, so a sign-up that sets its session and is retried gets the kept 201 with no `Set-Cookie`, where [the idempotency page](./design/idempotency.md) promises the answer byte for byte. The in-flight marker is kept under the Space's own TTL, so with a Space that outlives the process, a crash mid-handler answers 409 for the whole TTL.

**Needs:** every header of the answer kept, and a lifetime of its own for the marker.

**A failure keeps the representation headers the handler set before it failed.** `sendFailure` writes every collected header, which [ADR 024](./adr/024-every-failure-answers-as-json.md) decides for `Allow`, `WWW-Authenticate` and CORS, and which also carries `Content-Encoding`, `Cache-Control`, `ETag`, `Content-Range`, `Location` and `Content-Disposition`: a JSON 409 labelled gzip and cacheable for a year. Reproduced.

**Needs:** the representation headers dropped on the failure path, and ADR 024 naming which ones survive.

**The text log writes the request path's control bytes as they came.** The target is not checked for control bytes and the `.text` format prints it with `{s}`, so `GET /a\x1b[31mRED\rFAKE` puts a terminal escape and a line-overwriting CR into the default logger's output; `.json` escapes it. Reproduced.

**Needs:** control bytes escaped in `.text`, or refused in the target.

**A static file whose name has a space or a non-ASCII character is never served.** The lookup uses the raw target, the table is built from names as they are on disk, and neither side is decoded, so `café.png` and `My Doc.pdf` are a 404 to every browser. Reproduced. Symlinks are also skipped at the walk without a line, and a spilled or `.reload` file replaced by one after startup is followed out of the tree, because the open has no `O_NOFOLLOW`.

**Needs:** the table keyed by the decoded path, with `/` and `..` refused after decoding, and a symlink either served by a stated rule or named at load and refused at open.

**The WebSocket subprotocol is echoed rather than negotiated.** `Options.protocol` is written back whether or not the client offered it, and a browser fails a connection whose answer names a protocol it did not offer (RFC 6455 §4.1), so `new WebSocket(url)` against such a route fails and a client offering two protocols cannot be met. `Sec-WebSocket-Key` is not checked to be sixteen bytes of base64, and a malformed close frame still reports `closedCleanly()`.

**Needs:** the offer read and matched against a list in `Options`.

**A request can bind infinity, and a body still reaches the Zig literal grammar.** `spelledAsNumber("1e999")` passes and `parseFloat` returns `inf`, which [ADR 084](./adr/084-a-number-in-a-request-is-not-a-zig-literal.md) refuses by name, and echoed back it writes `{"p":inf}`, which is not JSON. In a body, std.json converts a string token with `parseInt` and `parseFloat`, so `"1_0"` is 10, `"+7"` is 7 and `"nan"` is NaN, where ADR 084 says a body already refuses them. A `u128` field posted as `2e38` panics inside std in ReleaseSafe.

**Needs:** an overflowing exponent refused in `convert`, a non-finite float refused on the way out, and a body's numbers read by the same grammar, which also brings the `u128` case onto nilo's side of std.

**`?T` with no default means optional in a query and required in a body.** `Query(T)` reads an absent field as null and std.json refuses it, while `openapi.zig` says both follow the same rule. The guides always write `= null`, which is why nobody has met it.

**Needs:** one rule, and the description following it.

**A `*` route stops matching past sixteen segments.** `router.split` gives up at `max_segments` and both `matchInto` and `allowedFor` then answer nothing, so `/files/*` and a root `/*` single-page fallback are a 404 for a path seventeen segments deep. The comment says no pattern can have more, which a `*` does.

**Needs:** the rest of the path handed to a `*` once the budget is reached.

**A target without a leading `/` is routed as though it had one.** `GET users/7` matches `/users/:id` and `OPTIONS *` matches a root `/*`, while `http1.zig` says these keep the 404 or 405 they had; a middleware checking `c.path()` for `/admin` is walked round by `GET admin/x`. The `Allow` header on an OPTIONS 204 also leaves out OPTIONS.

**Needs:** an origin-form target required to begin with `/`, and `*` kept for a server-wide OPTIONS.

**`c.url` lets a value be a dot segment.** Values are encoded as `.unreserved`, which keeps `.`, so `.name = ".."` builds `/u/../settings`, which a browser following a redirect normalises to `/settings`; [the routing page](./design/routing.md) says a value cannot smuggle a segment. An empty value gives `/u//settings`.

**Needs:** a value of `.` or `..` encoded or refused, and an empty one refused.

**The OpenAPI document is looser than the server.** An unsigned integer gets `minimum: 0` and no `maximum`, although a `u8` refuses 256 with a 400, and a field with a default is marked not required in a response schema, although the writer always sends it, so a generated client null-checks every one.

**Needs:** `maximum` taken from the type, and `required` in a response schema meaning "always written".

---

## Next

### Every module

**The public surface has not been read back against the reference.** 1.0 freezes what a dependent may write, and nothing yet checks that every `pub` in a module is on its page in `docs/reference/`, or that every name on a page is still `pub`. Found by reading, a name that should not be public is a break before 1.0 and a promise after it.

**Needs:** the read-back, one module at a time, and a decision on each name the code and the page disagree about: document it, or take it out of the surface.

**Some ADRs only correct an older one.** [ADR 221](./adr/221-an-adr-is-the-rule-in-force-and-a-topic-page-joins-them.md) makes a revision an edit to the ADR it revises, and the ADRs numbered before that rule still include corrections filed under a number of their own, so the rule in force is read in two files.

**Needs:** which ADRs are corrections rather than decisions, each folded into the one it corrects with its reasoning moved under "What was rejected", and the numbers kept as pointers so no link breaks.

### `nilo_pw`

**The Cost floor only weighs memory.** `Cost.floor_memory_kib` refuses anything under 7 MiB, which is OWASP's weakest published configuration. But that configuration is 7 MiB *and five passes*, and `.{ .memory_kib = 7 * 1024, .passes = 1 }` is a quarter of the work and compiles. A floor on `memory_kib * passes` would catch it, and would also refuse this repository's own test Cost, which is how the suite affords two optimize modes ([ADR 044](./adr/044-a-password-hash-is-gated-because-forgetting-is-silent.md)).

**Needs:** a way of being cheap in a test suite that is not also a way of being cheap in production.

**A password longer than a page costs what it is.** Argon2 hashes the whole input, so a client posting a megabyte gets a megabyte hashed. `max_body` bounds it at one megabyte by default and the Gate bounds how many at once, so it is not an opening. But everybody else truncates at 72 bytes or pre-hashes with SHA-512, and nilo does neither.

**Needs:** which of the two.

### `nilo_cache`

**Counting a read costs 4.2% on eight threads and 7.0% on one.** The increment has to be atomic now that a read holds no lock, and there is no cheaper exact version: per-thread counter lanes were built with a thread-local and with a lane hashed off the stack address, and measured 1.5% better on eight threads and 3% worse on one ([`bench/result/cache.md`](../bench/result/cache.md)). quick_cache's answer is to put its counters behind a cargo feature that is off by default. Doing the same here is a build flag and a documented default, not a measurement.

**Needs:** whether `Stats` may be absent.

### `nilo_job`

**A schedule is UTC.** `0 3 * * *` is three in the morning in Greenwich, and a program in Jakarta writes `0 20 * * *` with a comment. A time zone is a table of rules that changes twice a year and a dependency to carry it.

**Needs:** tzdata without a dependency, or a caller for whom the comment is not enough.

### `nilo_http`

**A handler that reads a body nilo does not know takes a `*Ctx`, and the document says nothing about it.** [ADR 157](./adr/157-a-type-can-write-its-own-answer.md) closed this on the way out: a type carrying `nilo_content_type` and `nilo_write` goes out as whatever it writes, under its own label, and the description names it. On the way in there is no third answer yet — a body is JSON, a form, or `c.body()` — so a route receiving protobuf, MsgPack or a vendor's binary takes a `*Ctx`, decodes by hand, and the API description cannot say what the route reads. The mirror is one declaration on the type: the same `nilo_content_type`, and a reader from the body's bytes into `Self`, checked and refused where the type is named the way `nilo_parse` is ([ADR 113](./adr/113-a-path-param-can-parse-itself.md)). nilo supplies the door and the caller brings the codec, which is what "no protobuf" ([decided](./decided.md#not-coming)) should cost.

**Needs:** two things. The name — `nilo_read(text, arena) !Self` is already the column protocol ([ADR 049](./adr/049-a-column-type-can-come-from-outside-this-module.md)) with the same shape, and a type can legitimately be both a column and a body. And what the document says for a body with no JSON schema: the content type and a bare description, the way [ADR 016](./adr/016-the-api-description-comes-from-the-signatures.md) words a type that writes its own body, or a `nilo_openapi` the type declares.

**Nothing tells a handler its client has gone.** `error.Canceled` comes from a shutdown or from one of the deadlines the Engine sets; a client closing its connection in the middle of a handler produces neither, so the work runs to the end and the response is written into a socket nobody is reading. The other half of this — cutting a slow handler off — is `nilo.deadline(ms)` ([ADR 105](./adr/105-a-route-can-say-how-long-it-has.md)). This half is not simply unbuilt: **the obvious implementation is wrong.** A read-side EOF is not "the client left" — a client that sent `Connection: close` and then `shutdown(SHUT_WR)` produces exactly that and is still waiting for its response, so answering "peer gone" from it would abandon correct requests. Gin gets the disconnect from `net/http` for nothing; Fiber does not have it either.

**Needs:** two named signals rather than one flag — "the client half-closed and is waiting" and "the socket is gone". What is already real is a write that fails, and a handler sees that today.

### `nilo_sql`

**`reset` and `squash` are missing from the migrations, and they are the debt that forward-only creates.** `generate`, `check`, `status`, `migrate` and `verify` ship ([ADR 123](./adr/123-a-migration-is-a-diff-against-a-snapshot.md)); `push` and `pull` — the SQLite and the rescue cases — are the other two that do not. There is no `down`, so a developer whose laptop database is in a state no version describes has nothing to type, and a project three years in has four hundred version files every CI run reads. Skipping them does not remove that pain, it moves it onto somebody's laptop and into somebody's build. `squash` is the harder half: it has to leave the ledger of every database that already ran the old versions alone, which means writing a new first version that is only ever applied to a database that has applied nothing.

**Needs:** what `squash` writes into the ledger of a database that is already past it. Rewriting rows is out — that is the thing `verify` exists to catch.

**An index on a big live Postgres table cannot be built without blocking its writes.** Every version is one transaction, and Postgres refuses `CREATE INDEX CONCURRENTLY` inside one, so a generated `create_index` on an existing table takes a lock that makes every write to it wait until the build finishes. On a table of a few thousand rows that is milliseconds; on one of fifty million it is an outage. The step's `why` says so today, and that is a warning rather than a way out. The way out is a step that runs outside its version's transaction and is recorded in the ledger on its own, because a `CONCURRENTLY` build that fails halfway leaves an invalid index behind that has to be dropped before the next attempt.

**Needs:** a caller with a table that size, and a decision on how a step outside the transaction is recorded when the version around it fails.

**Nothing reports how the pool is doing.** `app.metrics` counts requests, statuses and durations ([ADR 079](./adr/079-the-route-table-is-the-registry.md)); a `Db` counts nothing. Connections in use, how long a caller waited for one, statements run, and how many the pool threw away are the questions an operator asks first when a service slows down, and the last of them is already reachable — `postgres.dirtyConnections()` parses it out of pg.zig's own metrics text and is marked test-facing because nothing else reveals it.

**Needs:** a shape that does not become a second metrics registry. `app.metrics` is the shape and a `Db` is a Service, which knows nothing about an App — so where the numbers meet is the question, not how to count them.

**A Row over an attached SQLite database has nowhere to `ATTACH` it.** A schema in `nilo_table` means an attached database there ([ADR 055](./adr/055-the-second-dialect-is-the-test-of-the-seam.md)), and `ATTACH` is per connection — but the Wire holds a writer and a pool of readers, opens them itself, and `db.exec("ATTACH …")` reaches the writer alone. The introspection then asks a reader that has never heard the name, which is how the test for the schema-qualified `sqlite_master` found this: it attaches on every `conns[i].handle` by hand, and a program cannot.

**Needs:** a statement list run on every connection at open — which is also where a `PRAGMA` of the caller's own would go.

**Children are one level deep, and only through a reference of one column.** A Row's `[]const C` field is read by one statement for every parent, keyed by each parent's position in a list of one value apiece ([ADR 218](./adr/218-a-row-may-carry-its-parent-its-children-or-a-sum.md)); a child with children of its own is refused, and so is a reference of several columns. The second is the list carrying a row of values per parent (`unnest` takes several arrays, `json_each` a list of lists), and the first is the same pass run once more per level over the children just read.

**Needs:** a caller with a screen that nests three deep, or a table keyed by a tenant and an id that has children.

**The SQLite half has no live test against contention.** The Wire's own tests run one process, so the case the reader and writer split exists for has a design and no test: two writers meeting, `busy_timeout` expiring, `Locked` coming back.

**Needs:** a harness — a build step that stands up a second writer, which here is a second process on the same file rather than a socket.

**A pool-wide `statement_timeout` rides in the startup packet, and nothing upstream blocks it any more.** It is the only way a plain `db.select` gets a deadline without a second round trip ([ADR 043](./adr/043-a-deadline-needs-a-connection-you-hold.md)). The pin has sent `startup_parameters` since `nevindra/pg.zig@0a8dab4`, so what is left is nilo's side: `Db.Opts.statement_timeout_ms` handed to `Conn.Opts.startup_parameters`, and `options=` and `client_encoding` in a URL carried on the same packet instead of refused. Meanwhile it is `ALTER ROLE app SET statement_timeout`, from the side that can already do it.

**Needs:** a live test that a statement past the number comes back `error.TimedOut` on a connection nobody set anything on, and that a reconnect sends it again.

---

## Known, waiting for a caller

The design is known and priced; what is missing is somebody who needs it. Bring the deployment or the workload, not the patch — every marker and every module here had to pass that test, and the entries below say what passing it looks like.

### `nilo_core`

**A per-thread entropy pool, if a number ever justifies one.** `c.entropy` reaches the operating system on every call: 56ns on a kernel serving `getrandom` from a vDSO and roughly twenty times that on one that does not ([ADR 042](./adr/042-entropy-belongs-to-the-loop.md)). A CSPRNG seeded once per thread would remove it, and costs stored state, a fork hazard and a seeding moment.

**Needs:** a workload where it shows.

### `nilo_id`

**A v7 is not sortable within a millisecond.** Two made in the same one come back in random order relative to each other. RFC 9562 allows a counter in `rand_a` and this has none, on the grounds that it buys ordering nobody asked for at the price of a threadlocal.

**Needs:** a service inserting a batch in a tight loop that has noticed.

### `nilo_config`

**A name that is not the field's own.** `database_url` reads `DATABASE_URL` and there is no way to say otherwise, so a platform that already owns a name — `PGURL`, or `PORT` meaning something else in the same container — has to be met by renaming the field. A marker in the reader's own struct is the shape the rest of nilo uses (`nilo_table`, `nilo_resolve`), and the work is one comptime lookup.

**Needs:** a caller who cannot rename the field.

**A prefix is per reading, not per Config.** `fromWith(T, .{ .prefix = … })` has to be written at each call, so two places reading one Config can disagree about it. Making the prefix part of the type would fix that and cost `Read(T)` its one-type-per-`T` property.

**Needs:** a caller who has actually disagreed with themselves.

### `nilo_cache`

**A value of `[]const u8` is the only shape that is not flat.** A struct with a `[]const u8` field in it is refused by name, and the caller encodes it. The shape that would fix it — writing the slices' bytes after the fixed part and pointing them back into the caller's buffer on the way out — is known and is maybe 120 lines of comptime.

**Needs:** a caller for whom JSON into a bytes Space is not enough.

### `nilo_jwt`

**Only 2048, 3072 and 4096 bits of RSA, and only P-256 of EC.** A key size with no branch is `error.KeySizeNotSupported` and a curve with none is `error.CurveNotSupported`, rather than a best effort. ES384 is the same twenty lines over `EcdsaP384Sha384`; ES512 wants P-521, which std does not carry; Ed25519 (`EdDSA`) is a different key type again.

**Needs:** an issuer that publishes one, which none in the comparison does.

**HS256 is absent on purpose and that is not free.** A shared-secret token is what a service issues to itself, and a module verifying both algorithms has to be careful about the confusion attack that a module verifying one cannot commit. A caller who needs it writes four lines of `HmacSha256` beside this module and gets the constant-time compare right on their own, which is the shape of mistake this module exists to prevent.

**Needs:** a caller, brought with the reason a sealed cookie or an RS256 issuer will not do.

### `nilo_fetch`

**An `Exchange` cannot be begun on a target.** `Exchange.begin` takes the client and a URL, and a target's `url(c, path, args)` is the URL — so the streamed call reaches the base and the template, and not the standing headers or the target's own gate. The shape is a `begin` on the target that takes a path and hands the Exchange the `Standing` the whole-body calls already pass ([ADR 061](./adr/061-a-fitting-borrows-the-loop.md)).

**Needs:** a caller who streams from a service that has standing headers, since a signed request sets its own and an unsigned download has none.

**A plain call costs 4,139 bytes on every idle connection**, still the largest per-connection figure in the framework. It is fiber stack rather than buffers, at the depth `std.http.Client` drives it to. [`bench/result/fetch.md`](../bench/result/fetch.md) ranks the levers: moving the buffers into the arena costs +4,096 bytes since the stack release, shrinking them is worth nothing because a stack buffer no byte touches is never a resident page ([ADR 186](./adr/186-the-transfer-buffer-serves-nothing-here.md)), and what is left is the frame `std.http.Client` waits in.

**Needs:** a caller holding enough connections for 4 KB to matter.

**A certificate bundle is loaded per client, not per process.** `std.http.Client` rescans the system roots the first time it makes an HTTPS request. One client per program is the shape the docs push, so this has not bitten, but two would pay twice and nothing says so at the call site.

**Needs:** a caller who genuinely wants two clients.

### `nilo_job`

**`stats` is three numbers for the whole queue.** What an operator wants on a dashboard is how old the oldest `queued` row is (the lag) and the counts by kind, so that a thousand queued thumbnails and one queued invoice do not read as the same number. One more query, run only when asked.

**Needs:** a dashboard.

**`job.Memory` scans its slots.** 3–6 µs a claim over a few thousand fixed slots under a spin lock. Fine for a test and for the small program it is for; a heap would be 200 ns and an allocation-free heap somebody writes.

**Needs:** a memory queue big enough to notice.

**A worker started under `app.start(io)` and never `listen()`ed is a worker nobody stops.** `serveOn(io)` for a worker process returns when cancelled, and cancelling it is the caller's — there is no signal handler here, because the one in `http/` belongs to the server. A worker binary writes the four lines that catch SIGTERM and cancel the future.

**Needs:** a caller who has written those four lines twice.

### `nilo_s3`

**`COPY`.** Where S3 stops being bytes at a key and starts being a document format, and it carries its own trap for whoever adds it: S3 can answer a copy with **200 and an error in the body**, so a client that checks the status is wrong.

**Needs:** a caller who wants it enough to hold the XML.

**Multipart upload, and therefore upload of unknown size.** `putStream` frames by length because S3 does not accept chunked, so a body whose length is not known before it starts has no way in. Multipart is a protocol rather than a call: initiate, N parts each with its own ETag, then a completion document listing them. XML again.

**Needs:** a caller.

### `nilo_http`

**A TLS listener that reloads its certificate without a restart.** `listen(.{ .tls = … })` reads the two files once ([ADR 212](./adr/212-tls-is-an-option-a-build-asks-for.md)), and a certificate that renews every sixty days is a restart every sixty days. The shape that costs nothing per connection is a second `CertKeyPair` swapped in under the acceptors on a signal or a file's mtime, with the old one freed once the last handshake that took it is over, which is a count the Engine does not keep yet.

**Needs:** the deployment that renews in place. `certbot --deploy-hook 'systemctl restart …'` is what every other one does.

**Client certificates on a TLS listener.** The library has `client_auth` with a CA bundle and `.require`/`.request`; nothing in `Options.tls` names it, and nothing on `Ctx` would say who the client was. The second half is the design question: a verified subject is request data, so it wants to be a typed argument the way `Session(T)` is, not a header.

**Needs:** the service mesh that wants it, and the answer to what a handler is handed.

**Session resumption on a TLS listener.** Every connection is a full handshake, about 300 µs of CPU on the machine in [`http.md`](../bench/result/http.md), and a client that reconnects per request pays it per request. The library has no session tickets; when it does, the option is a key to encrypt them with and a lifetime, and the number to re-measure is that one.

**Needs:** the library first (the row under Waiting on upstream), then a deployment whose clients reconnect and cannot sit behind a proxy.

**More than one certificate on a listener, chosen by SNI.** One `CertKeyPair` per listener today. Two names on one certificate is the answer for most of the cases; the one it does not cover is two tenants whose certificates cannot share a file.

**Needs:** that deployment.

**A handler cannot tell which listener a request arrived on.** `listen(.{ .also = … })` answers on as many addresses as it is given, and deliberately tells nothing above the listener which one carried the bytes ([ADR 213](./adr/213-a-server-answers-on-more-than-one-address.md)): a listener decides how bytes move and a route is a route on every address. The case that would change that is an admin surface on a port of its own, where the point is precisely that the public listener must not reach it, and route prefixes do not express "only from this socket". The shape is a field on `Ctx` or a route scoped to a listener, and both cost something on the hot type for a use case nobody has brought yet.

**Needs:** a caller with an admin or metrics port that must not be reachable from the public one, and a reading of what it costs the park frame, which ADR 212 showed is one page away from noticing anything.

**An extra listener that asked the kernel for a port cannot say which one it got.** `boundPort()` answers for `port`, the first listener, and an entry in `also` with `.port = 0` binds fine and reports nothing ([ADR 213](./adr/213-a-server-answers-on-more-than-one-address.md)). It costs the tests something already: they give a second listener a unix path rather than a port, because a path is knowable and a kernel-chosen port is not. The shape is `boundPorts()` returning the lot, or `boundPort(n)`.

**Needs:** somebody who binds more than one listener to port 0 outside a test, or a test here that cannot be written with a path.

**A gRPC listener answers unary calls only.** A call with a second message is refused as `INTERNAL` ([ADR 220](./adr/220-grpc-is-served-over-h2c-behind-a-flag.md)). Server, client and bidirectional streaming are the shape that holds a fiber and its stack for the whole call, and the translation a unary call goes through (one HTTP/1.1 request, one answer) has no place for a second message; a streaming method would be a handler that reads and writes messages on the stream, much as a WebSocket handler does its frames.

**Needs:** a caller with a streaming method, and the per-stream figure for a stream held open measured the way `bench/mem.py --hold` measures an HTTP/1.1 one.

**One port cannot speak both HTTP/1.1 and h2c.** A gRPC listener is a listener of its own ([ADR 220](./adr/220-grpc-is-served-over-h2c-behind-a-flag.md)), and a connection that does not open with the HTTP/2 preface gets a 505. Choosing on the first 24 bytes would put a branch in front of every HTTP/1.1 connection's first read on that port, where a listener of its own leaves that path as it was; it is also what HttpArena's `unary-grpc` profile needs, along with HTTP/2 for plain GET routes, which stays refused.

**Needs:** a deployment that can open one port and not two.

**A stream is never compressed, and neither is an event stream; and gzip is the only coding.** `app.compress` gzips a whole body on a compressor borrowed for the CPU it takes and handed back before the socket is written, which is what keeps one compressor per thread enough ([ADR 211](./adr/211-a-response-is-compressed-on-a-compressor-borrowed-from-a-pool.md)). A stream has no whole body and would hold its compressor across every write, so its shape is a second pool larger than the thread count and chunked framing; an event stream must never be buffered and stays out on principle. Brotli is a C dependency, and a decision of its own.

**Needs:** a caller streaming something text and large enough that the bandwidth matters, or a scoreboard reason for brotli that survives the dependency it brings.

**A gRPC listener has no health service, and the guide does not say how to write one.** Kubernetes' gRPC probe and most load balancers call `grpc.health.v1.Health/Check`, which is an ordinary route under [ADR 220](./adr/220-grpc-is-served-over-h2c-behind-a-flag.md) and nothing documents; server reflection, which `grpcurl` wants, is not on record either way.

**Needs:** a deployment probing a gRPC listener, which is a guide section before it is code.

**A `testing.Conversation` does not share a `testing.Client`'s cookie jar.** A test that signs in over HTTP and then opens a socket copies the cookie across with `setHeader` by hand ([ADR 091](./adr/091-a-websocket-route-can-be-driven-from-a-test.md)).

**Needs:** a second test that has had to copy it.

### Modules that do not exist yet

**`nilo_redis`: the same keyspace shape against somebody else's process.** A Service rather than a tool module, and deliberately not the one built first ([ADR 110](./adr/110-an-in-process-cache-and-a-redis-client-are-two-modules.md)). Two of the three usual reasons to reach for a Redis are already gone here — a session is sealed into a cookie and an allowance is a table in this process — and the first case of several instances having to agree, a queue shared by several servers, was answered by the database they already share ([ADR 160](./adr/160-a-queue-is-a-table-in-the-database-you-already-have.md)). **The two will not share an interface**: what can fail differs, and hiding that turns "the cache is down" into "the cache is cold". Both existing Zig clients are alpha and neither has pub/sub; ADR 110 records what each one does have.

**Needs:** the deployment with more than one instance in it.

**Anything else that dials — a `nilo_mail`, a second store.** Nothing structural is in the way. Each is a Fitting or a Service by one question: does it hold a connection to a named system, or is it given an address per call ([ADR 061](./adr/061-a-fitting-borrows-the-loop.md))? `nilo_s3` is the worked example of the second answer, and the most useful thing it leaves behind is that `nilo_fetch` turned out to be the right size — it needed one addition, `Exchange`, and no changes. **The bar is what a caller cannot already do**, and mail is the example of failing it: transactional mail is an HTTPS POST to a provider, which `nilo_fetch` sends today.

**Needs:** a caller, with the bar above applied first. This is still the most useful place for an outside contributor to look.

---

## Open questions

A question nobody has answered. Not a backlog item, and not blocked: what a reader wants to know is which evidence would end the argument.

### `nilo_core`

**Where `convert` belongs.** Turning text into a type is what a Core wants, but `convert.zig` reaches the Bulkhead to say a request failed. Either its failures come back as a value the caller turns into a 400, or it stays in the App layer and Core gets a smaller converter under the same rules. Two candidates have already come and gone: `nilo_config` is not a second caller, because sharing means naming `nilo_core` and giving up a plain `zig test` ([ADR 039](./adr/039-a-setting-is-a-field-and-every-bad-one-is-named-at-once.md)); `percent.zig` went to Core without answering this, because neither direction of percent coding can fail ([ADR 057](./adr/057-percent-is-needed-by-two-layers.md)).

**What would settle it:** a caller in the App or Service layer. One below cannot afford to reach for it, which is what both false starts proved.

### `nilo_pw`

**Whether a memory-bound deployment gets bcrypt.** It is in `std`, it costs zero heap against argon2id's 19 MiB, and it is 2.6× slower for the trouble ([ADR 044](./adr/044-a-password-hash-is-gated-because-forgetting-is-silent.md) has the numbers). The trade is real for a small machine holding many connections.

**What would settle it:** somebody on one.

**Whether a second factor belongs here.** TOTP (RFC 6238) is HMAC-SHA1 over a counter derived from the clock, a base32 secret, and a window; forty lines, and the trap is quiet: a code accepted twice inside its own thirty-second window is a replay, and a verifier that forgets to record the last counter it accepted passes every test. The same argument that put `pw.Token` here applies ([ADR 044](./adr/044-a-password-hash-is-gated-because-forgetting-is-silent.md)). Against it is that the audience is narrower, and that the enrolment half (a QR code, a provisioning URI) is a page rather than a function.

**What would settle it:** an application that is asked for a second factor.

### `nilo_jwt`

**Whether nilo signs a token for a client that cannot hold a cookie.** [ADR 111](./adr/111-nilo-verifies-a-token-and-does-not-fetch-one.md) refuses signing because a server issuing its own sessions has `Session(T)`, and that holds for a browser. The client it does not obviously hold for is a native mobile application talking to the same API, where a bearer token is the convention and a cookie jar is a thing the developer has to go and find. HS256 sign and verify is forty lines; a signer here would have to be a type that cannot be handed an RSA public key as its secret, which is a Refusal rather than a runtime check.

**What would settle it:** a client that genuinely cannot hold a cookie, brought with the reason, since "the convention is a bearer token" is not one.

**Whether a key ring may be built without an audience.** `audience` and `issuer` default to null, so a ring over Google's keys with no `audience` accepts an ID token minted for any other application signed by the same keys. The guide says so; [ADR 044](./adr/044-a-password-hash-is-gated-because-forgetting-is-silent.md)'s rule is that a check forgetting costs silently is enforced rather than documented, and an audience is that check for a token.

**What would settle it:** an issuer whose tokens carry no audience, which is the case a required field would refuse.

### `nilo_fetch`

**Whether retries belong anywhere.** How many times, how long between, and what counts as a failure are facts about somebody else's service. A caller who knows them can write three lines. A default that guesses them turns one outage into a thundering herd.

**What would settle it:** a shape that takes the policy as a type rather than a number, which is the same test every other feature here has had to pass.

### `nilo_job`

**Whether a job has a result.** `status(id)` says `done` and not what came of it: the URL of the export, how many rows the import took, the thumbnail's key. Today every "is it ready?" route builds a table of its own to hold that. A `pub const Result = T` on the kind, a `result` column written as JSON when `run` returns one, and `jobs.result(scope, id)` to read it is the shape; the cost is a column that is null on most rows.

**What would settle it:** a caller whose second table exists only to answer that route.

**Whether a job may say how many of it run at once.** "At most two calls to the payment provider in flight" is a `nilo.Gate` inside `run` today, which works and is invisible to the queue: a third row is claimed, waits at the gate, and holds a worker while it does. A per-kind ceiling the claim respected would leave the worker free.

**What would settle it:** a caller with a provider that rate-limits harder than their workers count.

### `nilo_http`

**Whether nilo ships the response headers a browser reads as policy.** `X-Content-Type-Options`, `Referrer-Policy`, `X-Frame-Options` and a `Content-Security-Policy` are four constant headers, so a middleware setting them would be `cors.zig`'s shape exactly. The argument against is that [ADR 027](./adr/027-tls-is-terminated-in-front.md) puts a proxy in front of the default build and the proxy is where an operator already writes these, and a framework that sets half of them invites the belief that it set all of them. HSTS is the proxy's where a proxy terminates TLS; a `-Dtls` listener ([ADR 212](./adr/212-tls-is-an-option-a-build-asks-for.md)) is its own terminator, and nothing sets it there.

**What would settle it:** an application that got one of them wrong, or an argument that a CSP belongs with the handlers that decide what a page loads rather than with the deployment.

**Multipart, streamed.** `Form(T)` reads a multipart body whole, bounded by `max_body` ([ADR 030](./adr/030-a-form-is-the-body-read-by-another-rule.md)), which is right for a form with a photo in it and wrong for a 2 GB video. The streaming version wants a parser that resumes across reads and an `Upload` that is a reader rather than bytes; it inherits nothing from `sendfile`, because sending is a descriptor handed to the kernel and receiving is a parser holding its place.

**What would settle it:** somebody designing it. Until then the answer is `c.bodyStream()`, which holds nothing and makes the framing the handler's problem.

---

## Measurements outstanding

A decision that is waiting on a number, and the run that would produce it. [`bench/result/`](../bench/result/) is where the number goes when it exists; a run that changes nothing still earns an entry there if somebody would otherwise repeat it. **A box** means a benchmark machine rather than the shared two-core vCPU everything so far was taken on.

| Module | What the number decides | The run | Needs |
|---|---|---|---|
| `nilo_sql` | why the arena's `async-db` profile reads 66k req/s at 874% of sixty-four CPUs with neither the server nor Postgres busy — 3.9 ms a query for a 0.1 ms scan. Decoding is 116 µs of nilo's 284 µs a request and none of the wait ([`sql.md` §12](../bench/result/sql.md#12-the-arenas-query-at-one-connection)); the suspect is pg.zig's one pool mutex taken twice a request by 1,024 fibers on 64 threads, which two threads cannot convoy. The arena's rerun with stealing off (ADR 199) read 59.7k with the p99 at 245–362 ms from 50, which is what a fiber queued on a mutex that no other thread can now run looks like, and does not yet name the lock ([`http.md`](../bench/result/http.md#the-arenas-two-readings-and-what-changed-between-them)) | `bench-sql-server`'s three `/async-db*` routes under `wrk -c1024`, pool 256 then 32, Postgres on `--network host` | a box |
| `nilo_cache` | where the 60% between nilo and quick_cache on eight threads goes — the levers named so far are each a few percent ([`cache.md`](../bench/result/cache.md)) | `perf` on both binaries, not another guess | a box |
| `nilo_cache` | whether a bucket should have sixteen ways rather than eight: two cache lines touched against better retention at load | the retention curve and the read cost, both swept across ways | a box where the read cost is not mostly memory latency |
| `nilo_jwt` | whether a sign-in endpoint should cache a verification or just do it — an RSA exponentiation at 2048 bits is not small | one verify of each kind, and a row in `bench/result/` for it | an afternoon |
| `nilo_fetch` | whether the second arena allocation a whole-body call makes — the header block kept before the body reads over it ([ADR 187](./adr/187-a-head-that-outlives-its-body.md)) — shows up for anybody; head and body in one buffer is the shape if it does | a caller for whom it shows, since it is a bump and a `memcpy` inside the noise of a round trip | a caller |
| `nilo_fetch` | what a call costs through TLS: 59,151 bytes per HTTPS connection is std's number read out of its buffer sizes, 3.6× plain HTTP if it holds | `zig build smoke-tls -Dnetwork` already reaches a real endpoint; the measurement beside it is missing | an afternoon |
| `nilo_http` | whether a connection should start on the executor whose acceptor took it (`spawnInto(.local)`, which a gRPC call already does, 2.7x there: [`http.md`](../bench/result/http.md#what-placing-a-grpc-call-on-its-own-executor-buys)) rather than be dealt round-robin: it removes the last per-connection cross-thread hop, and it leaves the spread across threads to whichever acceptor the kernel wakes ([ADR 200](./adr/200-every-executor-accepts.md)) | gcannon's short-lived and keep-alive shapes, `.local` against round-robin, interleaved, with the connections each executor ends up holding | an afternoon |
| `nilo_job` | whether a claim should take ten rows rather than one: a Postgres claim is 1.2 ms across a Docker port ([`job.md`](../bench/result/job.md)), and the price of ten is ten rows held by a worker that may die | `bench-job` extended to several workers | a box |
| `nilo_job` | whether `LISTEN/NOTIFY` is worth a pool connection held open: a push wakes a worker in the same process ([ADR 160](./adr/160-a-queue-is-a-table-in-the-database-you-already-have.md)), so `poll_ms` is only the latency of a row a *second* binary pushed | who is running two processes on one queue, and what they wait | a caller |
| `nilo_job` | whether sixteen workers on one SQLite file cost the lock: a single claimer handing rows over a channel takes fifteen of them off it, and ADR 160 chose the wake without measuring the lock | a queue on one SQLite file with more workers than cores | a box |
| `nilo_http` | what `permessage-deflate` costs per connection, against the 4,669 bytes an idle one holds | a compressor per connection, weighed | an afternoon |
| `nilo_http` | whether one acceptor per executor ([ADR 200](./adr/200-every-executor-accepts.md)) is past the knee on a machine with many threads. dusty measured 12 and 24 accept loops losing 20–40% on one request per connection against 5, on 24 threads; at 8 threads on the 9700X log2's 3 gained 2–4% there and lost 5–6% at ten requests per connection ([`http.md`](../bench/result/http.md#how-many-acceptors-eight-threads-want)) | the same sweep, acceptors at threads, 2×log2 and log2, on 24 threads or more, with one and ten requests per connection | a box |
| `nilo_http` | what an internally tagged union costs to read: four passes over each tagged value (`skipValue`, the discriminator scan, `parseFromSliceLeaky`, `refuseUnknown`), two of them building a `std.json.Scanner`; `jsonmark.zig`'s header says nothing per request, which is true only on the write side | an array of a thousand tagged values, against the same array untagged; `http.md` has the write side (248–317 → 88–95 ns across six runs) and nothing for the read | an afternoon |
| `nilo_http` | whether `app.metrics`' plain shared atomics cost anything on a hot route, and whether response bytes and sockets should be counted too: four interleaved pairs put it inside the noise on two cores, which is the weakest place to look for cache-line contention. The same question for the two `Stop.in_flight` read-modify-writes every request makes for a graceful stop: per-thread lanes measured −1.1% on the same two cores with the sign changing, and the arithmetic caps the gain at 1–2% of sixteen cores ([`http.md`](../bench/result/http.md#what-the-two-atomics-a-request-always-makes-cost-on-two-cores)) | the same pair on eight cores, both counters at once; the fix is already named for both — shard per executor, pad to 64 bytes, sum at scrape or at drain | a box |
| `nilo_http` | whether `keep_bytes = 64 KiB` a thread is the right size: every WebSocket figure is a 64-byte payload that never leaves the first page; a 60 KiB message at a thousand a second is where `scratch.zig` starts refusing spares | `bench/compare/wsload/` with `-payload`; the run exists, the interpretation does not | an afternoon |
| `nilo_http` | whether the 32-lane scans (`scan.lanes`, `json.zig`'s escape scan) hold on aarch64, where 32 lanes is two NEON registers; every head-parsing and JSON figure is from one x86-64 box | `zig build run` and `bench/bench.sh` on the M1 Pro that has already run the cache and the build | an afternoon |
| `nilo_sql` | whether a SQLite statement should hop or run in the fiber, which the Wire makes every program choose ([ADR 064](./adr/064-a-file-has-no-socket-to-wait-on.md)): a hop and a cached read both cost a few microseconds, so `.in_fiber` is plausibly faster for a lookup service and fatal for one that scans | unloaded and behind the pool ([`sql.md` §2](../bench/result/sql.md) is why both); `bench-sql` has the unloaded `.in_fiber` half, `bench/sql_server.zig` on a SQLite `Db` is the rest | a box |
| `nilo_sql` | what the write half of the ten-way comparison costs under contention: `live.zig` proves `.update_nowait` and `.update_skip_locked` do what they say and nothing says what either costs, or where `FOR UPDATE SKIP LOCKED` stops scaling as a queue | the harness exists | a box where the generator, the database and ten candidates are not sharing eight cores |
| `nilo_s3` | what a request costs through TLS, which decides whether payloads are hashed: the plaintext numbers carry a SHA-256 over every body that the HTTPS ones would not, and neither corrects the other on paper | the same runs against a MinIO with a certificate | an afternoon |
| `nilo_http` | what a connection inside a request holds now that `read_buffer` is 16 KiB: the idle figure is unchanged by construction (ADR 062 gives the pages back) and the active one is two pages of arithmetic rather than a reading ([ADR 196](./adr/196-a-head-is-mostly-cookies-and-sixteen-kilobytes-of-them.md)) | `bench/mem.py --hold` against `bench-stream-server`, which is the one server that holds connections mid-request, at 8 and at 16 | an afternoon |
| `nilo_s3` | whether caller-set `x-amz-meta-*` headers cost enough to refuse: SigV4 signs a sorted header list, a fixed set makes it a constant, and letting a caller add one puts a sort in every request | the sort, priced | a caller who wants the feature, bringing the number |
| `nilo_http` | how far under a page boundary a plain connection parks, and what buys the headroom: 2,618 bytes live on the plain build and 2,890 on the `-Dtls` build, one page against two, with the difference being the inliner's and not TLS's ([ADR 212](./adr/212-tls-is-an-option-a-build-asks-for.md), the section on the page). Every future change to the connection loop is one page per idle connection away from being noticed until this is known | the park-depth instrumentation ADR 212 describes (the live stack at `releaseIdleStack`, printed once per connection), run on `main` and after each candidate: `noinline` on `waitForRequest`'s wait, a smaller `Peer` on the frame, the handler's frame measured on its own | an afternoon with the instrumentation, which is four lines |
| `nilo_http` | whether a 64 KiB stack buffer in a handler costs per idle connection: [ADR 062](./adr/062-where-a-connection-waits-is-what-it-costs.md) marks `var buf: [64 * 1024]u8` as 64 KiB on every connection for ever, and [the memory page](./design/memory.md) says the pages below `waitForRequest` are given back at idle, which would make that true only of a WebSocket. Every `bodyStream` example (`body.zig`, `ctx.zig`, `guide/requests.md`, `examples/stream`) teaches the stack buffer, so one of the two is wrong | `bench/mem.py --hold` against a route that streams its body through a 64 KiB stack buffer, read while the connection is idle | an afternoon |
| `nilo_http` | what kernel TLS would buy a TLS listener: the library has a `Ktls` mode in which the kernel does the record layer after the handshake, so the 33 KB of buffers go away and every read and write is one syscall shorter; what is known is that the buffers already cost nothing at idle ([ADR 212](./adr/212-tls-is-an-option-a-build-asks-for.md)), so the win is the page and the half microsecond a request, if it is a win | `bench-tls-server` with `Ktls` against without, `bench/mem.py --tls` and `wrk` over `https://`, on a kernel with `tls` loaded | a Linux box, which every one of the measurements so far was |
| `nilo_http` | why the worst gRPC call is 1.4 s at 256 connections and 3.8 s at 1,024 when tonic's is about 1.1 s, on the same four cores ([`http.md`](../bench/result/http.md#a-grpc-listener-built)); h2load gives mean and maximum and no percentiles | `ghz` or another client with a latency histogram against `spike/grpc/server`, before and after a spawn homed on the calling executor | an afternoon |
| `nilo_http` | why 0.05–0.1% of short-lived connections log "handler … failed after answering: WriteFailed": a response, or a WebSocket's 101, written to a socket the client had already reset, under a client (`gcannon -r 10`) that resets only after reading its tenth answer. 403 in 879K connections on HTTP, 934 in 794K on WebSocket, 163 in 435K on the one-acceptor build, so older than ADR 200; gcannon's own `read` error count is the same order and not the same number ([`http.md`](../bench/result/http.md#a-reset-between-frames-is-a-client-that-has-gone)). If it is the client's, the line is still ADR 022's misreport on a reset rather than a timeout | `tcpdump` on one such connection, both sides, or gcannon with `--json` for the per-error breakdown against the server's count | an afternoon |

---

## Waiting on upstream

The change is in somebody else's repository. The last column is the pin it was last checked at, and the check is the point: re-test before repeating any row here.

| Module | What is blocked | Where | Checked at |
|---|---|---|---|
| `nilo_http` | `zig build dev -- --incremental` without LLVM: `-fincremental` with the self-hosted backend and the new ELF linker rebuilds `examples/hello` in 0.12 s and leaves `.zig-cache` flat, and its output dies at exec with `undefined symbol: main` whenever libc is linked, which every nilo server is; the old ELF linker spins on the first update instead ([ADR 190](./adr/190-a-restart-on-save-watches-the-binary-not-the-sources.md), [`build.md`](../bench/result/build.md#what-a-restart-on-save-costs-per-save)). `zig build-exe main.zig -lc -fincremental` on a five-line program reproduces it | zig | 0.16.0; re-test with `zig build dev-hello -- --incremental` and no `-Dllvm` on each release |
| `nilo_http` | a ClientHello split across two records is refused by the TLS listener rather than reassembled ([tls.zig#36](https://github.com/ianic/tls.zig/issues/36)); every client ADR 212 tried sends it whole, and the one that does not, or a middlebox that fragments, gets a failed handshake rather than a slow one | [ianic/tls.zig](https://github.com/ianic/tls.zig), `handshake_server.zig` | `e04ae44` on `zig-0.16.x` |
| `nilo_http` | HelloRetryRequest on the TLS listener: a client that offers a key share for a group the server does not take is refused rather than asked again, and a client whose first offer is not X25519 is that client; with it, so is a session ticket, which is the row above under Known that turns a full handshake per reconnection into a resumption | the same | `e04ae44` |
| `nilo_http` | a record's length is read before its content type is checked, so plain HTTP sent to a TLS port is held as a 12 KB record that never finishes rather than refused on sight; the header deadline is what ends it, which is why `header_timeout_ms` bounds the handshake ([ADR 212](./adr/212-tls-is-an-option-a-build-asks-for.md)) | the same, `record.zig` | `e04ae44` |
| `nilo_http` | the TLS pin back on upstream: `build.zig.zon` pins `nevindra/tls.zig`, which is upstream's `zig-0.16.x` plus two commits: one signs an RSA key through its CRT form, 13.7 ms of handshake CPU down to 2.6 ([the run](../bench/result/http.md#what-an-rsa-certificate-costs-a-handshake)), and one adds the server's `offload` option, which runs the signature off the executor ([ADR 217](./adr/217-a-handshakes-signature-is-computed-off-the-executor.md)). The first is offered upstream; the second is not yet. Once both merge, the pin moves to upstream's commit and the fork is not used again | [ianic/tls.zig#59](https://github.com/ianic/tls.zig/pull/59) | `73290ca` |
| `nilo_sql` | the pg.zig pin back on lalinsky's: `build.zig.zon` pins `nevindra/pg.zig`, which is `lalinsky/pg.zig@ec8cf27` plus two cherry-picks from karlseguin's `master`. `2907296` sends `startup_parameters`; `2c7c6ca` stops a cached statement paying a second round trip, 2.1–3.1 µs a query over a unix socket ([`sql.md` §16](../bench/result/sql.md#16-the-round-trip-pgzig-wasted-taken-back)). Once they merge, the pin moves to lalinsky's commit, `bench/compare-sql/zigsql` moves with it, and the fork is not used again | [lalinsky/pg.zig#13](https://github.com/lalinsky/pg.zig/pull/13) | `0a8dab4` |
| `nilo_sql` | telling a fiber that queues for the SQLite writer it already holds that it *is*, rather than that it might be: the wait is bounded ([ADR 107](./adr/107-a-wait-for-a-connection-has-a-bound.md)) and ends in a `TimedOut` naming the likely cause; telling that apart from an honestly busy database needs to know which fiber holds the writer | `std.Io` handing a Service a fiber identity, or a design that gets one without it | 0.16.0 |

---

## How this file is written

Seven rules. They are why the file has the shape it has, and adding to it means matching them.

**1. Nothing built is in here.** The moment something ships, its entry leaves entirely: no strikethrough, no "**Built**", no account of how it went. What was measured goes to [`history.md`](./history.md), what a reader has to change goes to [`CHANGELOG.md`](../CHANGELOG.md), and the decision goes to an ADR. A gap only *partly* closed keeps one sentence scoping what is left, never a paragraph about the half that landed. **The test is that this file reads top to bottom as work outstanding.**

**2. Nothing decided is in here either.** An answer that is the answer — a question closed so it is not re-derived, a feature refused with its reason — goes to [`decided.md`](./decided.md), and a risk with no mechanism under it yet goes to [`risks.md`](./risks.md#open). This file is what is still open.

**3. An entry is in one section, by what it is waiting for.** A fix goes under **Defects**, a decision under **Next**, a use case under **Known, waiting for a caller**, an argument under **Open questions**, a number under **Measurements outstanding**, somebody else's commit under **Waiting on upstream**. Inside the first four, entries sit under their module's heading; a module with nothing in a section has no heading there, because the sections are the index and an empty heading says nothing.

**4. An entry opens with the whole claim, in bold**, and closes with one line: `Needs:` for the first three sections, `What would settle it:` for the fourth, the last column for the two tables. Somebody who reads only the bold lines has to come away with the right idea of what is outstanding, and somebody who reads only the closing lines has to know what to bring. Neither is optional and neither is prose.

**5. An entry is at most a screen.** Longer than that means it is an ADR, with an entry here pointing at it. A table row is at most a paragraph.

**6. No checkboxes, no dates, no owners.** A box implies a plan and this is not one. Nothing here is ordered; a module heading is a grouping, not a queue, and everything is a condition rather than a schedule.

**7. A number carries a link to where it was measured.** [`bench/result/`](../bench/result/) is the record. A figure with no run behind it decays into a claim, and a claim in a roadmap gets planned against, which is worse than a wrong number in a changelog.

Adding a module means a heading for it under whichever sections have entries for it, and nothing else — there is no index to keep in step.
