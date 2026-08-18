# 0079 — there is a phase after the pool and before the server

**Status:** accepted
**Amends:** [ADR 0040](./0040-a-service-that-needs-the-loop-is-finished-when-the-loop-exists.md)

## Context

`guide/sql.md` was clear that a query needs no request:

> Where there is no request there is `nilo.Run`, which owns an arena and a
> lifetime of its own. […] That is the whole of what a migration script or a
> nightly job needs from this module.

It was not the whole. **A `Run` is an arena and a lifetime; what it is not is a
connection.** The pool is opened by `nilo_start(io)`, which `listen()` calls on
every provided service that declares one — and there is no event loop before
`listen()` and no "before the server" after it, because the call does not
return. So every query outside a running server was:

```
error.Disconnected
```

which named neither the pool, nor `listen()`, nor anything a reader could act
on.

That is not an edge case. **A SQLite application has to create its tables at
startup**, because there is no server to have run the DDL somewhere else, and
[ADR 0073](./0073-a-file-has-no-socket-to-wait-on.md) made SQLite the Wire aimed
at exactly the project that has no operations team. The application that found
this ended up with ten lines: stand up `std.Io.Threaded`, open a **second** `Db`
on the same file, `nilo_start` it by hand, create the table, close it, and only
then hand the real `Db` to the App.

The same shape hit every test. `testing.Client` does not call `listen()` either,
so a test driving an App with a database had to open the pool itself and hold
its `Io` alive for as long as it served.

And a third thing rode along on the same gap: `db.checking` runs inside
`nilo_start`, so **a Row that disagrees with its table passed an entire suite**.
The application's `accounts` table declared `id INTEGER PRIMARY KEY
AUTOINCREMENT`, which SQLite reports as nullable and `id: i64` is not. Forty
tests passed in both optimize modes against that schema; the first `zig build
run` stopped dead with the right sentence. The suite was not testing the thing
the server checks.

## Decision

**`app.start(io)` is the phase, and `listen()` is it plus a socket.**

```zig
var threaded: std.Io.Threaded = .init(gpa, .{});
defer threaded.deinit();

try app.provide(&db);
try app.start(threaded.io());        // services checked, chains resolved,
                                     // pools open, schemas checked
try migrate(&db);
try app.listen(.{ .port = 8080 });   // does not start them twice
```

It runs `checkServices`, `resolveChains` and `services.start` — the three things
`listen()` does before it accepts anything — and comes back. `services_started`
on the App makes it idempotent, because a program that migrates before it serves
reaches the same code twice and opening a pool twice leaks the first one.

**And `error.Disconnected` from a pool that was never opened now says which
mistake it is.** The error value is unchanged, because a handler has nothing
different to do with it; what is new is one log line naming `nilo_start`,
`app.start(io)` and the fact that a `Run` is not a connection.

## What was tried and taken out again

**`testing.Client.send` calling `app.checkServices()`.** It is what the finding
asked for, it lasted an afternoon, and it refused a test in this repository's own
`examples/orders` that drives an App to fetch `/openapi.json` and never touches
the routes whose services are missing. That is a fair thing to write and not a
mistake, so a gate that fails it is wrong.

The complaint underneath was narrower and is answered where it belongs: a route
that needs a service nobody registered now **logs the type and the pattern** at
the moment it needs one, in `typed.zig`, beside the 500 it already answered.
That has no false positive to have, because it fires only on the route that
actually wanted the service. `app.checkServices()` stays public and
`guide/testing.md` now points at it for a test that wants the whole gate.

The general lesson is worth keeping: **a diagnostic that fires on a program's
shape can be wrong about the program; one that fires on what the program did
cannot.**

## What was rejected

**Letting `nilo.Run` hold an `Io` and start services.** It puts the App's
registry inside Core's Scope type, which is upward, and `zig build layering`
would refuse it — correctly. A `Run` is deliberately the smallest thing a query
can take.

**Opening the pool lazily at the first query.** It would need an `Io` from
somewhere at an arbitrary moment, it moves a connect onto the request path, and
it makes "the database is unreachable" a runtime surprise rather than a startup
one, which is the property ADR 0040 bought.

## What it costs

One `bool` on the App and one branch in a function that runs once. Nothing on
the request path, and nothing at all for a program that only ever calls
`listen()`.
