# nilo

An HTTP framework for Zig that puts the comfort of writing code first, with performance as a consequence — not the other way round. It is aimed at people who are used to Go or Node and are giving Zig a try.

## Language

### Layers

**Layer**:
Where a module sits, decided by one question — does it need the event loop? Core needs none, an App owns one, a Service needs one and does not own it. A module imports downward only and never a sibling, which is what makes two modules two separate pieces of work. Core is the layer that holds more than one module, and the vocabulary sits under the rest of it.
_Avoid_: tier, level, ring, package, workspace

**Core**:
The bottom module: the vocabulary every other layer agrees about, and no IO at all. A file earns its place here by being needed by two layers, not by having nowhere else to live. It names no Engine, so it runs under a plain `zig test` and links into a program with no server in it.
_Avoid_: utils, common, shared, base, prelude

**Tool module**:
A module in the bottom layer that is not the vocabulary — one job, no event loop, and nothing above it in its imports. It may name Core, which is not a sibling because a vocabulary is not a peer of anything, and it may not name another tool module. Whether it runs under a plain `zig test` is the entry condition rather than a nicety: one that cannot is in the wrong layer.
_Avoid_: helper, utility, library, plugin, package

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

**Redirect**:
An answer that is a status and a `Location` rather than a body, returned by the handler with its status in the type. `Redirect(303)` is the one a form POST wants, because it turns the follow-up into a GET.
_Avoid_: forward, 302, location header

**Catch-all**:
A `*` as the last segment of a pattern, matching the whole rest of the path and handing it over under the name `*`. Always loses to a route that spells the path out.
_Avoid_: wildcard route, splat, glob

**Stream**:
A response written in pieces because its length is not known when the head goes out. Held by the handler, not returned by it. Nothing is allocated per piece, and `finish` is what says where the body ends.
_Avoid_: chunked response, writer, body writer

**Body reader**:
A request body taken in pieces rather than held whole, for the ones too big for the request arena. Bounded by the buffer the handler passes in, and allocates nothing. A body left half-read is finished off by nilo, so the connection stays usable.
_Avoid_: upload stream, multipart, file handle

**Event stream**:
A Stream carrying server-sent events — one long response a browser reads with `EventSource`. Each event is flushed on its own, and `live` is how the handler learns the server wants to stop.
_Avoid_: SSE channel, subscription, push, socket

### Assembly

**App**:
One self-contained HTTP application: a set of routes, middleware, and services. A single process may have more than one.
_Avoid_: Server, Router, Engine

**Service**:
A long-lived thing registered once when the App is built — a database connection, config, a logger — then asked for by handlers according to its type. Shared across every request being served at once, so one that gets written to needs a `nilo.Mutex`.
_Avoid_: dependency, state, context value, DI container

**Config**:
A struct of the caller's own, one field per setting, filled from the environment before the socket opens. Field names are the variable names upper-cased, a field's default is what "not set" means, and reading one either answers the struct or names every setting that could not be read. It is text and numbers and nothing else: a Config parses no files, and what it cannot become is a compile error rather than a startup one.
_Avoid_: settings object, options, env, dotenv, configuration file

**Setting**:
One field of a Config, and the one environment variable it is read from. Its type is the whole of what it may be — text, a number, a bool, an enum, or any of those wrapped in `?` — and nilo's opinion about it stops at whether the text converts.
_Avoid_: option, flag, variable, key, parameter, knob

**Middleware**:
A piece of work that runs before and after a handler, operates at the Ctx layer, and produces no value for the handler. Middleware enforces; a Resolved value provides.
_Avoid_: filter, interceptor, hook, guard

**Group**:
One path prefix and everything registered beneath it — routes, middleware, static files, further groups. The prefix is compile-time text joined onto each pattern, so a Group leaves nothing behind at runtime.
_Avoid_: router, scope, mount, namespace

**Plugin**:
An ordinary function that takes a Group and registers into it. There is no plugin type and no registration protocol; that a plugin can be mounted at any prefix, or twice, follows from being handed the Group rather than the App.
_Avoid_: extension, module, add-on, middleware bundle

**API description**:
The OpenAPI document nilo writes from the handler signatures. Not maintained alongside the code — read off the same argument list the compile-time engine reads, and built once when the server starts. It promises what the signature settles and nothing else.
_Avoid_: schema, spec file, swagger, annotations

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
One directory read when the App is built, and answered from a list fixed before the socket opens. Files small enough are held in memory and never touch the disk again; the rest are Spilled. Not a middleware: it holds state, so it is a terminal handler the middleware chain wraps like any other.
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
A WebSocket connection, held by an ordinary handler that does not return until it ends. nilo does the handshake, the framing and the housekeeping frames; the loop is the handler's. The buffer it reads into is the message ceiling.
_Avoid_: websocket connection, channel, ws, peer

**Range**:
A request for part of a file rather than all of it — a video being scrubbed, a download being resumed. One that cannot be understood is ignored and the whole file goes out, because that is a correct answer to every request.
_Avoid_: partial content, byte range, seek, chunk

**Refusal**:
A program written wrong on purpose, kept so that the message it stops with stays the one nilo wrote. Never run and never compiles; the build checks the wording of the error, and a mistake that stops somewhere inside the standard library instead cannot be recorded as acceptable.
_Avoid_: negative test, compile-fail case, error test, fixture

**Test client**:
A stand-in for the other end of a connection, for testing a handler that writes its answer rather than returning one. Runs one request through the App with no server and no socket.
_Avoid_: mock, fixture, test server, harness

### SQL

**Row**:
A struct of the caller's own, one field per column, carrying the marker that names its table. A narrower one names another Row instead of a table, and is checked against it while compiling.
_Avoid_: ORM, model, entity, record, schema, DTO

**Borrowed row**:
One Row read on its own rather than with the rest, its text pointing into the buffer the rows arrive in and valid only until the next one is pulled. That text is a plain slice and not a Str, which is what keeps the Str guarantee free of exceptions.
_Avoid_: view, ref, unowned, cursor row

**Statement**:
A whole piece of SQL and the list of places its values are read from, both worked out while compiling. Which table, which columns, which operators and how many parameters are all settled; only the values are not.
_Avoid_: query builder, prepared statement, expression tree

**Dialect**:
The half that writes the SQL, worked out entirely while compiling. It says how a parameter is spelled and how a condition is phrased, and it may refuse a condition its database cannot express rather than emit one that means something else.
_Avoid_: backend, flavor, adapter, driver

**Wire**:
The half that speaks to the database: run this query with these values, hand back rows, begin and end a transaction. Everything a database can do that this module does not is reached directly, not through here.
_Avoid_: driver, client, connection layer, bulkhead

**Tx**:
One transaction in flight, holding a connection until it ends. It ends however the handler leaves — committed, rolled back, or abandoned — because the connection has to go back fit for whoever takes it next.
_Avoid_: transaction, unit of work, session, scope — and "scope" stays on this list now that a Scope is a thing here, because it is the wrong word for this one specifically: a Scope ends one way and a Tx ends three.
