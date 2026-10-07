# A request knows which listener it came in on, and a route can belong to some

**Status:** accepted
**Topic:** [engine](../design/engine.md)
**Applies:** [ADR 017](./017-the-trade-budget-has-four-axes.md) (what a feature spends, and the number), [ADR 062](./062-where-a-connection-waits-is-what-it-costs.md) (a connection's frame is its memory), [ADR 008](./008-middleware-is-an-onion-of-ctx-functions.md) (a 404 still runs the middleware)
**Extends:** [ADR 213](./213-a-server-answers-on-more-than-one-address.md) (more than one listener; this reverses its "the handler is never told")
**Found by:** the photon port, whose Rust server binds the OTLP HTTP receiver, the OTLP gRPC receiver and the REST API to three addresses, each with its own router

## Context

[ADR 213](./213-a-server-answers-on-more-than-one-address.md) let one server answer on several addresses and decided that nothing above the listener would know which one carried a request, "until somebody brings the case". The case arrived in the first real port of a multi-listener server. A route that checks a bearer token (an ingest receiver) was reachable on the public UI port, and a route that checks a session cookie was reachable on the ingest port. Route prefixes do not express it: the two surfaces have to share nothing but a process, and the prefix is a part of the URL clients already use.

The honest alternatives the port had were a second `App` per address, which ADR 213 measured as thirty-two executors polling on a sixteen-thread box and which splits the services, or an `if` in every handler, which is a guard nobody can see from the route table.

## Decision

**A request carries the number of the listener it arrived on, `c.listener()` answers it, and a route can be bound to listeners with `onListener`, so a request on another listener finds no such route.**

```zig
const public = 0;
const ingest = 1;

try app.get("/healthz", health);                              // every listener
try app.onListener(&.{ingest}).post("/v1/logs", receiveLogs); // listener 1 only
try app.group("/api").onListener(&.{public}).get("/users", users);

try app.listen(.{ .port = 8080, .also = &.{.{ .port = 4317 }} });
```

**The number is the position in the list `listen()` was given.** `0` is the listener `.address` and `.port` name, `1` is `also[0]`, and so on. A number the program wrote by writing the list, not a port, because a port can be 0 (the kernel's choice, ADR 213) and a unix socket has none. It is a `u8`, so a server answers on at most 256 addresses, which `listen()` refuses past with `error.TooManyListeners`.

**Step one, `c.listener()`: one byte on `Peer`, set at accept.** `Peer` is already what every connection carries beside its address and its `tls` bit, and `Ctx.peer()` already reaches it. The acceptor's per-listener state (`Accepting`, which a connection fiber holds by pointer) gains an `index`, and the connection copies it into its `Peer` when it is accepted, the way it copies `tls`. No `Ctx` field, no allocation, nothing computed per request. It is read off the connection, so no header can claim it.

**Step two, `onListener(&.{n, …})` on an App and on a group.** It is the shape `with` and `without` already have: a comptime parameter of the group type, so the binding is settled while compiling, and `onListener` on a bound group narrows it (the intersection), never widens. `Route` gains a `listeners` word, one bit a listener, every bit set for a route nobody bound. The seam is `serveRequest`, one compare after the router has matched: a route whose word excludes this request's listener is treated as unmatched, which sends it to the branch an unknown path takes. So it is **decided before any middleware of that route runs**, it is a 404 and not a 403, and a path that only a route of another listener spells out is not a 405 either: `allowedFor` takes the listener and skips routes bound elsewhere, so no `Allow` header gives the route away.

**What stays the same.** Middleware still runs on the 404 (ADR 008), as it does for any unknown path. A route bound to nothing is answered on every listener, as before. The route table is still one table: `GET /x` registered twice is `DuplicateRoute` whichever listeners the two are bound to, so the same path cannot answer differently per listener (that is the router's rule, and a second table is the cost this ADR declines to pay). Only listeners 0 to 31 can be bound, checked while compiling. Static mounts and the generated documents are not bound; serve them from a listener-aware middleware if one must be hidden.

### What it costs

Measured on the Ryzen 7 9700X (8 cores, 16 threads), Linux 7.2.5, Zig 0.16.0, `ReleaseFast`, stripped, against the tree at `689b034` built from `git archive` in a scratch directory, same flags, same afternoon.

| axis | before | after |
|---|---|---|
| memory per idle connection, `nilo-hello`, 2,000 / 5,000 / 10,000 connections | 5,218 / 5,199 / 5,191 B | **5,220 / 5,198 / 5,191 B** |
| binary, `example-hello` stripped | 1,009,360 B | **+448 B** |
| binary, `example-rest` stripped | 1,211,912 B | **+448 B** |
| binary, `nilo-hello` stripped | 1,016,936 B | **+448 B** |
| allocations per request | 1 | 1 |
| throughput and p99 | | one compare of a word per matched route; not measured: it is one compare, and ADR 017 puts DX below 10% inside the spread |

**The per-connection row had to hold and does, to the byte at 10,000.** It was a risk by construction: ADR 212 measured that the plain park frame sits under 300 bytes short of a page boundary, and `Peer` lives on the connection fiber's frame. The byte is `u8` after the `bool`s that already end the struct, which the size of `Peer` rounds over (50 bytes become 52), and `bench/mem.py` run twice per side, interleaved, at 2,000, 5,000 and 10,000 connections is what says so: the two sides differ by 2 bytes at 2,000 connections in the one direction and by 1 at 5,000 in the other, which is the run-to-run spread (the two runs of one side differ by the same), and are equal at 10,000. The index travels in `Accepting`, which the fiber reaches through a pointer it already held, so the frame holds no new argument.

**The 448 bytes** are the bit test in the dispatch, the second `allowedFor` entry, the `u8` copied into each of the two `Peer` builds, and the listener-count check. An App that never calls `onListener` carries none of the group types and none of `listenerBits`.

## What was rejected

**`.routes = &group` on a `Listener`**, the form the port suggested first. It makes the listener own a set of routes, which means a second route table built at `listen()` and a type for "a set of routes" that nothing else in nilo has: a route is registered through the App, in a group, with its middleware, and it would have to be registered *and* named in a list. Binding at the registration puts the statement where the route is, so renaming the route moves it (ADR 008, ADR 099), and the compiler checks the numbers. The listener does not learn about routes.

**Only `c.listener()`, with the refusal in a middleware.** It ships, as step one, and covers the case where the check is not "this route belongs here" (rate limits that differ per listener, a header written only for one). Alone it is a guard each program writes and each new route can forget: the default stays "every listener answers", so a route added later is exposed by accident. A route bound at registration is refused whatever the middleware says, and it is not in the table the listener answers.

**A listener passed as a name or a port.** A port can be 0 and an extra listener has no way to report the one it got (ADR 213), a path has none, and two listeners can share a port number on different addresses. The index is the one thing every listener has, and it is as stable as the list.

**A `Ctx` field instead of `Peer`.** The same number, copied into every request instead of read through the pointer to the connection's `Peer`, which a `Ctx` already holds. A field on the hot type for nothing the existing path does not reach.

**A 403 or a 421 for a route on the wrong listener.** A route that exists, and is refused, tells a scanner on the public port that the ingest path is real. A 404 is what a server that never had the route says.

**A second table, so one path answers differently per listener.** The router's tree is keyed on the pattern and the method; a second answer for one shape means a second tree or a key with a listener in it, on a path whose allocation and instruction budget is held (ADR 017). The case, the same path on two surfaces with two meanings, has not been brought.

## What this does not do

- **The gRPC adapter's route probe is not listener-aware.** A gRPC listener asks the router whether a `POST` route exists at a path before it answers `UNIMPLEMENTED`; a route bound to another listener passes that probe and then 404s in `handleRequest`, which a gRPC client sees as `NOT_FOUND` instead of `UNIMPLEMENTED`. Bind a gRPC method to the gRPC listener and the two agree.
- **No per-listener `max_body`, buffers or deadlines.** The route-level limits (`maxBody`, `deadline`) are what a route says about itself, and a listener-wide number remains ADR 213's "not yet", with the listener's memory cost to be measured against.
- **No reporting of an `also` listener's port**, still ADR 213's.
