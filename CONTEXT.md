# zfast

An HTTP framework for Zig that puts the comfort of writing code first, with performance as a consequence — not the other way round. It is aimed at people who are used to Go or Node and are giving Zig a try.

## Language

### Layers

**Engine**:
The bottom layer, the one that deals with the operating system: accepting connections, reading and writing bytes. Knows nothing about HTTP.
_Avoid_: runtime, backend, driver, event loop

**Bulkhead**:
The internal boundary between zfast and the Engine. Everything zfast needs from the Engine goes through here, so the Engine can be swapped without touching user code.
_Avoid_: adapter, abstraction layer, interface

**Ctx**:
The object standing for one request in flight, and all the control over it. This is zfast's real API — every layer above it turns into calls to this while compiling.
_Avoid_: Context, Request context, c

**Typed handler**:
An ordinary function that takes only what it needs and returns data. zfast matches its arguments while compiling. This is zfast's face to its users.
_Avoid_: magic handler, extractor, auto handler

**Resolved value**:
Something zfast works out from the request before the handler runs — the signed-in user, usually. The type itself says how, by carrying the function that does it, and a handler asks for one by writing it in its argument list. Worked out once per request and shared by everyone who asks.
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

**Query struct**:
A struct of the caller's own, one field per query param, asked for as `Query(T)`. Field names are the param names, and a field's default is what "absent" means. The named counterpart to a positional path param.
_Avoid_: query bag, params map, extractor

**Catch-all**:
A `*` as the last segment of a pattern, matching the whole rest of the path and handing it over under the name `*`. Always loses to a route that spells the path out.
_Avoid_: wildcard route, splat, glob

**Stream**:
A response written in pieces because its length is not known when the head goes out. Held by the handler, not returned by it. Nothing is allocated per piece, and `finish` is what says where the body ends.
_Avoid_: chunked response, writer, body writer

**Body reader**:
A request body taken in pieces rather than held whole, for the ones too big for the request arena. Bounded by the buffer the handler passes in, and allocates nothing. A body left half-read is finished off by zfast, so the connection stays usable.
_Avoid_: upload stream, multipart, file handle

**Event stream**:
A Stream carrying server-sent events — one long response a browser reads with `EventSource`. Each event is flushed on its own, and `live` is how the handler learns the server wants to stop.
_Avoid_: SSE channel, subscription, push, socket

### Assembly

**App**:
One self-contained HTTP application: a set of routes, middleware, and services. A single process may have more than one.
_Avoid_: Server, Router, Engine

**Service**:
A long-lived thing registered once when the App is built — a database connection, config, a logger — then asked for by handlers according to its type. Shared across every request being served at once, so one that gets written to needs a `zfast.Mutex`.
_Avoid_: dependency, state, context value, DI container

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
The OpenAPI document zfast writes from the handler signatures. Not maintained alongside the code — read off the same argument list the compile-time engine reads, and built once when the server starts.
_Avoid_: schema, spec file, swagger, annotations

**Blocking**:
Waiting on the operating system from inside a handler — a database driver, a file, a call out to another service. Many requests share one OS thread, so doing it directly stops all of them; `zfast.blocking` hands the call to a pool of real threads instead, and only the one request waits.
_Avoid_: offload, thread pool, async, await

**Fail function**:
A function callable from anywhere to stop a request with a given status and message, without having to hold a Ctx.
_Avoid_: abort, throw, bail

**Static set**:
One directory read into memory when the App is built, and answered from without touching the disk again. Not a middleware: it holds state, so it is a terminal handler the middleware chain wraps like any other.
_Avoid_: file server, asset middleware, public dir

**Socket**:
A WebSocket connection, held by an ordinary handler that does not return until it ends. zfast does the handshake, the framing and the housekeeping frames; the loop is the handler's. The buffer it reads into is the message ceiling.
_Avoid_: websocket connection, channel, ws, peer

**Range**:
A request for part of a file rather than all of it — a video being scrubbed, a download being resumed. One that cannot be understood is ignored and the whole file goes out, because that is a correct answer to every request.
_Avoid_: partial content, byte range, seek, chunk

**Test client**:
A stand-in for the other end of a connection, for testing a handler that writes its answer rather than returning one. Runs one request through the App with no server and no socket.
_Avoid_: mock, fixture, test server, harness
