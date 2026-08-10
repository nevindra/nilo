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

### Assembly

**App**:
One self-contained HTTP application: a set of routes, middleware, and services. A single process may have more than one.
_Avoid_: Server, Router, Engine

**Service**:
A long-lived thing registered once when the App is built — a database connection, config, a logger — then asked for by handlers according to its type. Shared across every request being served at once, so one that gets written to needs a `zfast.Mutex`.
_Avoid_: dependency, state, context value, DI container

**Middleware**:
A piece of work that runs before and after a handler, operates at the Ctx layer, and produces no value for the handler.
_Avoid_: filter, interceptor, hook, guard

**Fail function**:
A function callable from anywhere to stop a request with a given status and message, without having to hold a Ctx.
_Avoid_: abort, throw, bail

**Static set**:
One directory read into memory when the App is built, and answered from without touching the disk again. Not a middleware: it holds state, so it is a terminal handler the middleware chain wraps like any other.
_Avoid_: file server, asset middleware, public dir
