# nilo

An HTTP framework for Zig, and the toolkit it is built from: twelve modules for the ordinary jobs, of which the largest is the framework. It puts the comfort of writing code first, and keeps performance alongside it rather than after it. It is aimed at people who are used to Go or Node and are giving Zig a try.

## Language

### Layers

**Toolkit**:
What the repository is: a set of modules held together by one idea — your types are the contract and the compiler is the check — rather than by an event loop. The Framework is the largest module and not the centre: it is built from the same modules a program without a server imports. A module earns its place by the job being common, and the ones a program does not import cost it nothing.
_Avoid_: library, suite, batteries-included, ecosystem; framework, for the repository as a whole

**Framework**:
What `nilo_http` is: it calls the code you wrote, where a module of the Toolkit is called by it. A route is a function nilo calls, and nilo owns what is around the call: the connection, the routing, the request's memory, the answer. The word names `nilo_http` and nothing else; the repository is the Toolkit, and "an HTTP framework for Zig, and the toolkit it is built from" is the two together.
_Avoid_: library

**Layer**:
Where a module sits, decided by one question — does it need the event loop? Core needs none, an App owns one, a Service needs one and does not own it. A module imports downward only and never a sibling, which is what makes two modules two separate pieces of work. Core is the layer that holds more than one module, and the vocabulary sits under the rest of it.
_Avoid_: tier, level, ring, package, workspace

**Core**:
The bottom module: the vocabulary every other layer agrees about, and no event loop. A file earns its place here by being needed by two layers, not by having nowhere else to live. It names no Engine, so it runs under a plain `zig test` and links into a program with no server in it.
_Avoid_: utils, common, shared, base, prelude

**Tool module**:
A module in the bottom layer that is not the vocabulary — one job, no event loop, and nothing above it in its imports. It may name Core, which is not a sibling because a vocabulary is not a peer of anything, and it may not name another tool module. Whether it runs under a plain `zig test` is the entry condition rather than a nicety: one that cannot is in the wrong layer.
_Avoid_: helper, utility, library, plugin, package

**Fitting**:
A module that borrows the event loop and owns no destination. It is handed `std.Io` and given an address on every call, so it holds no connection to any named system — which is what separates it from a Service. It may name Core and nothing above it, and its tests run under `std.Io.Threaded` with no engine and no module graph beyond Core: the entry condition rather than a nicety, the same way a Tool module's plain `zig test` is.
_Avoid_: adapter, client, transport, driver, connector, integration

**Engine**:
The bottom layer, the one that deals with the operating system: accepting connections, reading and writing bytes. Knows nothing about HTTP.
_Avoid_: runtime, backend, driver, event loop

**Bulkhead**:
The internal boundary between nilo and the Engine. Everything nilo needs from the Engine goes through here, so the Engine can be swapped without touching user code.
_Avoid_: adapter, abstraction layer, interface

**Ctx**:
The object standing for one request in flight, and all the control over it. This is nilo's real API — every layer above it turns into calls to this while compiling.
_Avoid_: Context, Request context, c

**Scope**:
One lifetime and the memory that belongs to it, asked for as exactly two calls: `arena()` and `str()`. A Ctx is the Scope a request has, and the only one the framework itself ever hands out. It is a shape checked while compiling rather than an interface with a function table, so a module that takes one generates the same code it would have generated naming Ctx.
_Avoid_: context, allocator, session, unit of work, lifetime

**Run**:
The Scope for work that is not a request — a CLI run, the tick of a scheduled task, a test that wants one with no App around it. It owns its arena and its lifetime, so text it stamps goes stale at the end of a tick exactly as a request's does, and the debug trap watches it on the same terms.
_Avoid_: job, task, batch, context, worker

**Typed handler**:
An ordinary function that takes only what it needs and returns data. nilo matches its arguments while compiling. This is nilo's face to its users.
_Avoid_: magic handler, extractor, auto handler

**Resolved value**:
Something nilo works out from the request before the handler runs — the signed-in user, usually. The type itself says how, by carrying the function that does it, and a handler asks for one by writing it in its argument list. Worked out once per request and shared by everyone who asks.
_Avoid_: extension, request-scoped state, locals, context value, extractor

### Data

**Str**:
Text that came from a request. It lives only as long as that request is running, and its contents cannot be taken out without deliberately asking for them.
_Avoid_: string, slice, []const u8

**keep**:
The act of copying a Str into longer-lived memory, so it is safe to hold after the request finishes.
_Avoid_: dupe, clone, copy, to_owned

**Request arena**:
The bag of memory belonging to one request. All of it is thrown away at once when the request finishes. A handler that has to build something outliving its own stack frame — a `Location` header, usually — asks for it as a `std.mem.Allocator` argument.
_Avoid_: request allocator, pool, scratch

**Patch**:
A body field that can say three things rather than two: not sent, sent as null, or sent with a value. What a PATCH needs and an optional cannot express. The default `.absent` is what "not sent" means.
_Avoid_: tri-state optional, maybe, undefined, nullable wrapper

**Query struct**:
A struct of the caller's own, one field per query param, asked for as `Query(T)`. Field names are the param names, and a field's default is what "absent" means. The named counterpart to a positional path param.
_Avoid_: query bag, params map, extractor

**Form**:
The request body when it came from an HTML form, read into a struct of the caller's own — one field per form field, asked for as `Form(T)`. The same slot a JSON body occupies and the same rules a Query struct follows. Whether it arrived urlencoded or as multipart is the browser's business, not the endpoint's.
_Avoid_: form data, post data, multipart, body parser

**Upload**:
One file out of a Form. Three Strs — the bytes, the name the client gave it, and the type it claimed — of which only the first is a fact. Held whole in the request arena, so the ceiling is the Request arena's.
_Avoid_: file, attachment, part, blob

**Cookie**:
A name and a value the client stores and sends back. Read out of the head where it lies and never decoded, because what a value means is whoever wrote it's convention. On the way out it is the one response header that may be sent twice rather than replaced.
_Avoid_: session, token, crumb

**Session**:
A struct of the caller's own, sealed into one Cookie and held by the client. Encrypted and signed, so the client can tell that it has one and not what is in it. Nothing is kept on the server, which is why it cannot be revoked and why its size has to be settled while compiling. Asked for as `Session(T)`, and a Resolved value like any other.
_Avoid_: session store, session id, token, JWT, login

**Fallback secret**:
A secret a Session is opened under and never sealed under, so the secret can change without signing anybody out. Usually the old secret, kept for one `max_age` after the switch, because the expiry inside the seal means nothing sealed under it opens after that; on several instances, first the new one, staged a deploy ahead. Not what a leaked secret becomes: that one is dropped.
_Avoid_: retired secret, secondary key, key ring

**Redirect**:
An answer that is a status and a `Location` rather than a body, returned by the handler with its status in the type. `Redirect(303)` is the one a form POST wants, because it turns the follow-up into a GET.
_Avoid_: forward, 302, location header

**Catch-all**:
A `*` as the last segment of a pattern, matching the whole rest of the path and handing it over under the name `*`. Always loses to a route that spells the path out.
_Avoid_: wildcard route, splat, glob

**Stream**:
A response written in pieces because its length is not known when the head goes out. Held by the handler, not returned by it. Nothing is allocated per piece, and `finish` is what says where the body ends.
_Avoid_: chunked response, writer, body writer

**Trailer**:
A field sent after the body, for what is known only once the body is. Set with `c.setTrailer` until the body ends; HTTP/2 sends it after the body, a chunked HTTP/1.1 stream as its trailer section, and a whole HTTP/1.1 answer only when the client sent `TE: trailers`.
_Avoid_: footer, late header, trailing header

**Held answer**:
An answer a middleware kept back with `next.hold(c)`, so it can read and change it before the chain unwinds and it is written. A body sent under a hold is copied into the request arena.
_Avoid_: buffered response, deferred response, post-processing

**Body reader**:
A request body taken in pieces rather than held whole, for the ones too big for the request arena. Bounded by the buffer the handler passes in, and allocates nothing. A body left half-read is finished off by nilo, so the connection stays usable.
_Avoid_: upload stream, multipart, file handle

**Event stream**:
A Stream carrying server-sent events — one long response a browser reads with `EventSource`. Each event is flushed on its own, and `live` is how the handler learns the server wants to stop. One whose every event comes from Rooms is handed to the connection instead of held, and ends when the client sends anything or hangs up.
_Avoid_: SSE channel, subscription, push, socket

**Exchange**:
One outbound call with its answer left on the socket: the response head is read and decided on, and only then are the bytes moved — into a Scope, into a writer, or nowhere at all. What a Body reader is for a request coming in, this is for an answer going the other way. It holds a live request, so it is declared where it stands and never copied.
_Avoid_: streaming response, handle, cursor, pipe, connection

### Assembly

**App**:
One self-contained HTTP application: a set of routes, middleware, and services. A single process may have more than one.
_Avoid_: Server, Router, Engine

**Service**:
A long-lived thing registered once when the App is built — a database connection, config, a logger — then asked for by handlers according to its type. Shared across every request being served at once, so one that gets written to needs a `nilo.Mutex`.
_Avoid_: dependency, state, context value, DI container

**RPC service**:
A struct of typed functions given to `app.rpc`, served as the service its `nilo_service` names: each `pub fn` is a method at `/<package>.<Service>/<Method>`, reached by gRPC, Connect or plain JSON alike. Called a service only with "RPC" in front, because a Service alone is the thing `app.provide` registers.
_Avoid_: service (alone), controller, handler group

**Config**:
A struct of the caller's own, one field per setting, filled from a Source before the socket opens. Field names are the variable names upper-cased, a field's default is what "not set" means, and reading one either answers the struct or names every setting that could not be read. It is text and numbers and nothing else: a Config opens no files, and what it cannot become is a compile error rather than a startup one.
_Avoid_: settings object, options, env, configuration file

**Setting**:
One field of a Config, and the one environment variable it is read from. Its type is the whole of what it may be — text, a number, a bool, an enum, or any of those wrapped in `?` — and nilo's opinion about it stops at whether the text converts.
_Avoid_: option, flag, variable, key, parameter, knob

**Source**:
Where a Config's values come from — anything answering `get(name) ?[]const u8`, checked as a shape while compiling rather than through a vtable. Four are supplied (`Env`, `Map`, `Fixed`, `Dotenv`) and `layered` puts them in the order they win, first one with the name answering. A Source holds text somebody else read; none of them touches the filesystem.
_Avoid_: provider, backend, loader, store

**Dotenv**:
A `.env`'s text read as a Source — the file is the caller's to open, and the text has to outlive the Config read through it. A line that meant to be a setting and is not is reported with its number, never skipped, and a report never quotes a value.
_Avoid_: dotenv file, env file, envfile

**Middleware**:
A piece of work that runs before and after a handler, operates at the Ctx layer, and produces no value for the handler. Middleware enforces; a Resolved value provides.
_Avoid_: filter, interceptor, hook, guard

**Allowance**:
How many requests one address may make inside a window, and the 429 it gets for asking again. The table that remembers is sized while compiling and lives in `.bss`, so it costs no allocation at startup and none per request; a bucket with no room forgets its stalest address rather than making two share one allowance, and contention lets the request through. It is against the client that asks too often, not against a flood — that is `max_connections`.
_Avoid_: rate limit, limiter, throttle, quota, token bucket, budget, credits

**Group**:
One path prefix and everything registered beneath it — routes, middleware, static files, further groups. The prefix is compile-time text joined onto each pattern, so a Group leaves nothing behind at runtime.
_Avoid_: router, scope, mount, namespace

**Plugin**:
An ordinary function that takes a Group and registers into it. There is no plugin type and no registration protocol; that a plugin can be mounted at any prefix, or twice, follows from being handed the Group rather than the App.
_Avoid_: extension, module, add-on, middleware bundle

**API description**:
The OpenAPI document nilo writes from the handler signatures. Not maintained alongside the code — read off the same argument list the compile-time engine reads, and built once when the server starts. It promises what the signature settles and nothing else.
_Avoid_: schema, spec file, swagger, annotations

**Listener**:
One address the server answers on. `listen()` is given a list of them, and a request knows its position in it with `c.listener()`. A route can belong to some, and a request that arrives on another gets the 404 an unknown path gets, before any middleware runs.
_Avoid_: port, socket, bind, endpoint, interface

**Span**:
One timed piece of work inside a request that `app.trace` sends to a collector: the request itself, every outbound call under it, and whatever a handler measures with `c.span`. A request carrying a `traceparent` joins that trace, and an outbound call passes it on.
_Avoid_: segment, timer, measurement, trace (which is the whole tree of them)

**Metrics page**:
What `app.metrics` puts on `/metrics`: requests, status classes, a latency histogram and exact status codes, in the text format Prometheus scrapes. An ordinary route, counted per **route** rather than per path, because a counter is the route's index in the table rather than a key somebody hashed.
_Avoid_: telemetry, instrumentation, observability endpoint, stats

**Exposed number**:
A `std.atomic.Value(u64)` the application owns and `app.expose` publishes on the metrics page. nilo names it once at startup and reads it once per scrape; incrementing it is the application's. There is no registry to add a name to at run time — that is the point, and it is why nothing here costs a request anything.
_Avoid_: custom metric, registry entry, user counter, instrument

**Blocking**:
Waiting on the operating system from inside a handler — a database driver, a file, a call out to another service. Many requests share one OS thread, so doing it directly stops all of them; `nilo.blocking` hands the call to a pool of real threads instead, and only the one request waits.
_Avoid_: offload, thread pool, async, await

**Held thread**:
What a handler that forgot the rule above is doing: running without yielding while the requests sharing its thread wait. The compiler cannot see it and one request cannot feel it, so the server times each handler — everything it spent legitimately waiting subtracted — and says so in the log by name.
_Avoid_: event loop lag, starvation, watchdog, stall

**Gate**:
A lock that lets a fixed number of requests through at once and parks the rest. What a Mutex is with a number bigger than one, and what `nilo.blocking` is not: blocking says *do this off the loop*, a Gate says *and not more than this many at a time*. For work that is expensive rather than slow, where the ceiling the Engine's pool happens to have is the wrong one.
_Avoid_: semaphore, limiter, throttle, pool, permit

**Password hash**:
What is stored instead of a password: argon2id over the password and a salt, written as the PHC string every other library reads. A value rather than a thing with a lifetime — there is nothing to free and nothing to keep. Checking one is the same work as making one, which is why a sign-in for an address with no account does it anyway.
_Avoid_: digest, encrypted password, credential, secret

**Fail function**:
A function callable from anywhere to stop a request with a given status and message, without having to hold a Ctx.
_Avoid_: abort, throw, bail

**Static set**:
One directory read when the App is built — or one list of files the binary carries — and answered from a list fixed before the socket opens. Files small enough are held in memory and never touch the disk again; the rest are Spilled. An embedded tree is the same Set with the read taken out: nothing in it can spill. Not a middleware: it holds state, so it is a terminal handler the middleware chain wraps like any other.
_Avoid_: file server, asset middleware, public dir

**Spilled file**:
A file in a Static set too big to hold, kept in the list by its size, its modification time and the path the directory walk gave it, and opened again on every request that asks for it. It costs no memory and one descriptor while it is being sent. Its ETag is its modification time and size rather than a hash of its contents, and it is never gzipped, because there is no single moment to do either in.
_Avoid_: streamed file, large file, disk file, external file

**Dir**:
A directory opened once and held, so that a file can be served out of it by name without any path ever being resolved. What makes traversal impossible rather than defended against: the name is checked a segment at a time and opened against this descriptor, never against the filesystem's root.
_Avoid_: folder, root, base path, document root

**FileBody**:
An answer that is a file on disk rather than a value, returned by the handler the way a Redirect is. It names the Dir to serve out of and the name within it, and `?FileBody` means the same 404 that `?T` means anywhere else.
_Avoid_: file response, download, attachment, send file

**Socket**:
A WebSocket connection, held by an ordinary handler that does not return until it ends. nilo does the handshake, the framing and the housekeeping frames; the loop is the handler's, and the connection runs it after the handler has returned. `Options.max_message` is the message ceiling.
_Avoid_: websocket connection, channel, ws, peer

**Room**:
A Service that reaches Sockets and Event streams a handler does not hold. Saying something puts one post in each seat and rings a bell; the writing is done by the fiber that already owns that connection, so a client that stops reading costs that client alone. A connection can sit in any number of Rooms. A seat is given up by the handler that took it, because Zig has no destructor, and whatever is left is given up when the connection's wait ends.
_Avoid_: channel, topic, hub, pub/sub, broadcaster

**Rooms**:
A pool of Rooms made up front and lent to a key the application makes up, `"user:42"`, for as long as somebody is under it. How one user is reached on every tab: each joins the key, and anything that wants them says into it. A key nobody is under has no Room and costs nothing to say into; when every Room is lent, a new key is refused rather than given more memory.
_Avoid_: channel registry, topics, user channels, hub

**History**:
The latest text posts a Room keeps, bounded by a count and by bytes, for an Event stream that comes back with `Last-Event-ID`. What followed that id is written before anything new. Found by the id the application gave each post, so a Room that keeps history wants one on every post.
_Avoid_: replay buffer, backlog (which is a seat's), cache

**Range**:
A request for part of a file rather than all of it — a video being scrubbed, a download being resumed. One that cannot be understood is ignored and the whole file goes out, because that is a correct answer to every request.
_Avoid_: partial content, byte range, seek, chunk

**Refusal**:
A program written wrong on purpose, kept so that the message it stops with stays the one nilo wrote. Never run and never compiles; the build checks the wording of the error, and a mistake that stops somewhere inside the standard library instead cannot be recorded as acceptable.
_Avoid_: negative test, compile-fail case, error test, fixture

**Test client**:
A stand-in for the other end of a connection, for testing a handler that writes its answer rather than returning one. Runs one request through the App with no server and no socket. It may carry sticky headers and a jar; `send` is the raw entry point and carries neither.
_Avoid_: mock, fixture, test server, harness

**Jar**:
What a test client keeps of the cookies the answers set, and sends back on the requests that follow. Off unless asked for. A browser's word, kept because that is what it imitates.
_Avoid_: cookie store, session store, cookie cache

**Live server**:
A real server a test starts, with `testing.Live`: the real Engine on a port the kernel chose, stopped by the test. For what only a running server does, such as a spawned fiber or an idle deadline. A Test client is the other choice, and the one for everything that fits in it.
_Avoid_: integration server, end-to-end harness, spawned process

### SQL

**Row**:
A struct of the caller's own, one field per column, carrying the marker that names its table. A narrower one names another Row instead of a table, and is checked against it while compiling.
_Avoid_: ORM, model, entity, record, schema, DTO

**Marker**:
The `pub const nilo_table` on a Row: what the type says about its **table** rather than about a query. Its words are checked while compiling, which is the condition for being a word at all — the name, the key, a column's default, a unique, an index and its predicate, a foreign key and its two sides. A foreign key may name the other table as text rather than its Row, and the check on the two sides then runs against the list every Row is in rather than being given up (ADR 181). A word whose body only a database can read is a second kind — a **named text** — checked by the database and diffed by name and hash (ADR 181); anything that is neither is SQL in a step, and the snapshot marks it as an object nilo does not own.
_Avoid_: annotation, decorator, attribute, tag, metadata, schema DSL

**Named text**:
The second kind of word: an object whose **name** the compiler checks and whose **body** only the database can read. `.check` and `.trigger` are the two a table has. nilo writes the body, hashes it and never parses it, so a diff is three cases and no fourth — same name and same hash, nothing; a new hash, drop and create; a name the types no longer have, drop. The snapshot records the name and sixteen hex characters, not the body (ADR 181).
_Avoid_: raw SQL, escape hatch, opaque blob, passthrough

**Twin**:
The `.sql` file `generate` writes beside every version file: the same steps, wrapped in a transaction, with the ledger row on the end, for a database no Zig toolchain can reach. An **output** — nilo reads the `.zig` and never this, and a version written in SQL by somebody else is not picked up (ADR 123).
_Avoid_: export, dump, migration file, plain SQL migration

**Borrowed row**:
One Row read on its own rather than with the rest, its text pointing into the buffer the rows arrive in and valid only until the next one is pulled. That text is a plain slice and not a Str, which is what keeps the Str guarantee free of exceptions.
_Avoid_: view, ref, unowned, cursor row

**Parent field**:
A field of a narrower Row whose type is another table's Row: the row a reference points at, joined in the same statement and read into the field. Optional exactly when the reference may be null.
_Avoid_: relation, association, include, eager load, belongs-to

**Children field**:
A field of a narrower Row that is a list of another table's Row: every row pointing back at this one, read by one more statement for all the rows at once.
_Avoid_: has-many, preload, populate, nested query, subcollection

**Through field**:
A field of a narrower Row that reads one column of another table flat, by naming the references to cross: `.customer_name = .{ .customer_id, .name }`. The joined column arrives in a field of its own, so a response whose contract is flat needs no second struct. Not a Parent field, which brings the whole row.
_Avoid_: flattened join, projection, alias, denormalised column

**Unread column**:
A column the table has and its Row does not read, named in the marker with `.unread`. It is in the table and the migration diff, and a condition, an order or a write may name it on this Row, but the Row's `SELECT` and its JSON leave it out.
_Avoid_: hidden column, ignored field, write-only column

**Feed**:
The rows of a page up to a limit and whether any came after them, with no count of the rest. What a "load more" button needs, read as one row past the limit. A page is the other shape, and pays for a total.
_Avoid_: infinite scroll, cursor page, timeline

**Grouped Row**:
A narrower Row that names its computed fields in `nilo_aggregate`, so each of its rows is a group and every other field is a key of it. One with no keys at all is exactly one row, and is read with `exactlyOne`.
_Avoid_: aggregate query, rollup, report row, group-by

**Statement**:
A whole piece of SQL and the list of places its values are read from, both worked out while compiling. Which table, which columns, which operators and how many parameters are all settled; only the values are not.
_Avoid_: query builder, prepared statement, expression tree

**Dialect**:
The half that writes the SQL, worked out entirely while compiling. It says how a parameter is spelled and how a condition is phrased, and it may refuse a condition its database cannot express rather than emit one that means something else.
_Avoid_: backend, flavor, adapter, driver

**Wire**:
The half that speaks to the database: run this query with these values, hand back rows, begin and end a transaction. Everything a database can do that this module does not is reached directly, not through here.
_Avoid_: driver, client, connection layer, bulkhead

**Writer and reader**:
The two roles a pooled connection can have when the database is a file rather than a server: one connection that may write, and several opened read-only. Not a tuning choice — SQLite serialises writers over the whole database, so the split is what the database is, and a pool of equal connections would be describing something that does not exist.
_Avoid_: primary and replica, leader and follower, read replica, master — all four name a second database, which is a second type here (ADR 054), and these are two roles against one file.

**Tx**:
One transaction in flight, holding a connection until it ends. It ends however the handler leaves — committed, rolled back, or abandoned — because the connection has to go back fit for whoever takes it next.
_Avoid_: transaction, unit of work, session, scope — and "scope" stays on this list now that a Scope is a thing here, because it is the wrong word for this one specifically: a Scope ends one way and a Tx ends three.

**Savepoint**:
A mark inside a Tx that one part of it can be undone back to without ending the whole thing. It is what a nested transaction actually is — Postgres has no nested `BEGIN` — and calling it one would promise a durability an inner mark does not have. Ends the three ways a Tx does, one level in: released, rolled back, or abandoned.
_Avoid_: nested transaction, subtransaction, checkpoint, partial rollback

**Lock**:
What a read inside a Tx holds its rows with, until that Tx ends. Written where the condition is, settled while compiling, and refused outside a transaction — because there the statement still runs and the promise is gone.
_Avoid_: row lock, pessimistic locking, select for update, mutex

### Object store

**Store**:
Whatever every named place in a module shares, held once for the program. In `nilo_s3` that is the endpoint, the region, the credentials and the signing key they turn into, plus one connection pool — what changes between a laptop and production, which is why nothing on it is settled while compiling. In `nilo_cache` it is the memory itself. The word is the same in both because the role is: the Store is opened, and the named places hang off it.
_Avoid_: client, connection, session, provider, backend

**Bucket**:
A named place objects go, and a type rather than a string. The name is a compiled-in default, so the host and the path prefix are built once and a name that could never work is refused before the program runs; a program whose name is configuration opens the same type under a run-time name, refused by the same rules with `error.BadBucketName`. Two buckets over one Store are two types and one pool.
_Avoid_: container, namespace, folder, prefix, handle

**Key**:
Where one object sits inside a bucket. A plain runtime string, deliberately — it is data the way a path param is data, and a program that knows all of its keys while compiling does not need an object store. Encoded once on the way out, and never twice.
_Avoid_: path, filename, object name, id, blob key

**Object**:
What a bounded read hands back: the bytes, what they are, the tag they carry, and how many there were, all in the Scope's memory and all from one allocation. Refused before a byte moves if it is larger than the bucket allows.
_Avoid_: blob, file, payload, download, buffer

**Derived key**:
What actually signs a request — the secret, the date, the region and the service, folded together once and then kept for the day. It changes when the date does and not when the request does, which is what makes signing one hash and one HMAC rather than five.
_Avoid_: signing secret, session key, token, derived credential

**Canonical request**:
The exact shape a request has to be reduced to before it can be signed: method, path, query, the signed headers in order, and the payload hash. It is never assembled as bytes — it is written straight into the hash — because the bytes would be a buffer on a handler's stack and a handler's stack is per connection.
_Avoid_: string to sign, signing payload, request digest, normalized request

**Presigned URL**:
A link that carries its own signature in the query, so somebody with no credentials can use it once, for a while. The while it reports is the true one — the smallest of what was asked for, what the bucket allows, and what the credentials themselves have left.
_Avoid_: signed link, temporary URL, share link, token URL

### Cache

**Space**:
A named, typed keyspace inside one Store — the cache's answer to what a Bucket is to an object store. The name is compiled in and the type is the contract: a Space of `Cart` hands back a `Cart` and a Space of bytes fills a buffer you declared. Two Spaces over one Store share its memory and cannot read each other's keys.
_Avoid_: namespace, region, partition, table, prefix

**Flat value**:
A type a cached value is allowed to be: no pointer anywhere inside it, at any depth. The cache holds bytes and has no collector to keep the other end alive, so a pointer stored in it would outlive what it points at. A value that breaks the rule is refused while compiling, by the field path that broke it.
_Avoid_: POD, plain type, value type, serialisable

**Ring**:
Where the bytes live: one run of memory, sized once, written forwards. An entry is live if the cursor has not come round and passed it. Nothing is owned individually, so nothing is freed, no free list fragments and no size class wastes.
_Avoid_: heap, pool, buffer, arena, log

**Slot**:
Eight bytes in the table saying where an entry sits in the Ring, which pass over it wrote it, and a fingerprint of the key. Eight of them are one cache line, which is what a lookup touches. The key itself is in the Ring rather than the Slot, so a fingerprint match is confirmed rather than trusted.
_Avoid_: bucket entry, index entry, handle, reference

**Budget**:
The bytes a Store is opened with, and the whole of what it will ever hold. It is not a target it drifts around or a limit a sweep restores — the table and the Ring are taken out of it at `open` and never grow, which is what a cache in front of a database is for.
_Avoid_: capacity, limit, quota, max size, high water mark

**Eviction**:
Not something that runs. Writing an entry is what forgets an older one, either by lapping it in the Ring or by displacing the stalest of the eight ways when a key's line is full. A cache is allowed to miss, and this one says how often it did.
_Avoid_: expiry, reaping, sweeping, LRU, purge
### Tokens

**Token**:
A JWT somebody else signed and this program has to believe or refuse. The word is only ever about a credential that arrived from outside — a Google ID token, an Auth0 access token. A Session is not a token, never call it one, and nilo signs none of its own.
_Avoid_: JWT as a verb, bearer, credential, ticket, id token

**Key set**:
An issuer's public keys, as they come back from its JWKS endpoint, read into the ones a token can be checked against — RSA for RS256, EC on P-256 for ES256 — and each one's type is what decides which check a token under it gets. Keys of another type in the same document are skipped rather than refused, because an issuer adding a key type is not a reason to stop signing people in. Fetching it and deciding when it is stale are the caller's.
_Avoid_: JWKS as a noun on its own, keyring, key store, certificate

**Claims**:
A struct of the caller's own, one field per thing the application wants out of a token. Fields the token carries and the struct does not name are ignored. Separate from the registered claims — `iss`, `aud`, `exp`, `nbf` — which nilo checks whether or not the struct mentions them.
_Avoid_: payload, body, subject, principal, identity

### Protobuf

**Message**:
A struct of the caller's own that `nilo_proto` reads and writes, with a `wire` table naming each field's number. The type is the schema: there is no `.proto` file and nothing generated. Not a Job's payload, not a WebSocket frame.
_Avoid_: proto message type, generated class, schema file

**Wire table**:
The `pub const wire = .{ .field = 1, ... }` on a message, or on a oneof's union, that says what number each field has and, where its Zig type allows more than one way to travel, which. Complete or the build fails, naming the field.
_Avoid_: tag map, field options, annotations, descriptor

**Oneof**:
A `?union(enum)` with its own wire table, at most one member on the wire, `null` for none. The numbers sit on its members.
_Avoid_: variant, either, sum type (in the docs for this module)

### Jobs

**Job**:
A struct of the caller's own whose fields are the payload and whose `run` is the work, done later, on a worker, outside any request. Named by `nilo_job`, so a row pushed by one binary can be run by another that knows the name. Written to be safe to run twice, because it will be.
_Avoid_: task, worker (for the job — a worker is what runs one), message, event, handler

**Queue**:
The table the jobs wait in — `nilo_jobs`, a Row like any other, in the database the program already has. Not a second service, not a Redis, and `job.Memory` is the same contract in this process for a test or a program that can lose it.
_Avoid_: broker, bus, topic, stream, channel

**Claim**:
Taking the next due row and marking it running, in one statement, so that ten workers on ten machines take ten different rows. Postgres skips a locked row; SQLite has one writer and needs no skipping.
_Avoid_: dequeue, pop, poll (which is the wait, not the take), fetch, reserve

**Lease**:
How long a claimed row stays somebody's before anybody else may take it. A worker that dies mid-run leaves a row whose lease runs out, which is the whole of why a job is at least once and never exactly once.
_Avoid_: lock, visibility timeout, ack deadline, heartbeat

**Dead**:
A row that failed for the last time — every retry spent, or a payload this binary cannot read. Kept, with the error's name, until somebody retries or sweeps it. Not deleted, not hidden, and counted.
_Avoid_: dead letter queue, DLQ, failed, poison, discarded

**Schedule**:
When a job that nobody pushes runs: a cron expression or an interval, in UTC, parsed while compiling. The next tick is a row with a unique key, so a schedule on ten instances is one row. A schedule declares what an overlap and a missed tick mean, or it does not compile.
_Avoid_: cron job, timer, ticker, interval (for the whole — an interval is one kind of schedule), recurring task

**Tick**:
One run of one row: the row's id, which attempt this is, when it was due, and whether `retry` allows another. What a `run` is handed when it asks for `job.Tick` beside its deps — by value, because after the job and the Run a pointer is a service and this is not one. Everything in it was in the worker's hand at the claim, so asking costs nothing. Under `drainAt` a test says what time the tick is.
_Avoid_: job context, execution, invocation, attempt (for the whole — an attempt is one field of it), metadata
