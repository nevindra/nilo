# A pool that dialled itself whatever it was told

`sql/db.zig`'s header has said this since the module was wired to a database:

> That is also what makes a server boot with its database switched off:
> `connect_on_init` defaults to zero, so startup asks for a pool rather than
> for a connection. Somebody working on an endpoint that never touches
> Postgres does not need Postgres running.

It was false. Every pool nilo ever opened dialled itself in full at startup,
and a server whose database was not up **refused to start**.

## How it was found, and why nothing had

It was not found by reading. It was found by pointing a load generator at
`bench/sql_server.zig` with the pool size turned up, and getting

```
error(pg): connect error: sorry, too many clients already
```

at a pool size of 128 against a Postgres with `max_connections = 100` — while
`connect_on_init` was 8. Eight connections cannot exhaust a hundred. So
`connect_on_init` was not the number being dialled.

```zig
// pg.zig, pool.zig
pub fn initUri(io: Io, allocator: Allocator, uri: std.Uri, opts: Opts) !*Pool {
    var po = try lib.parseOpts(uri, allocator);
    defer po.deinit();
    po.opts.size = opts.size;         // copied
    po.opts.timeout = opts.timeout;   // copied
    return init(io, allocator, po.opts);
}                                     // connect_on_init_count: dropped
```

`parseOpts` leaves `connect_on_init_count` at `null`, and `Pool.init` reads it
as `orelse size`. So the value nilo passed was overwritten by the largest one
available, every time.

**Nothing caught it because the test suite always has a database.** The whole
of what this option does is visible only when Postgres is *absent*, and no
test can arrange an absence — the live tests skip without a database rather
than assert something about not having one. It is the same shape as the
`std.log.err` finding in `docs/history.md`: a behaviour whose only expression
is a thing not happening.

## What was decided

**`sql/postgres.zig` parses the URI itself and calls `pg.Pool.init` with a
whole `Opts`.**

Forty lines mirroring pg.zig's `parseOpts`, which is `pub` in its `lib.zig`
and not re-exported through its module root, so it cannot be called. The copy
is tested against pg.zig's own defaults — username `postgres`, a ten-second
auth timeout, `sslmode` and `tcp_user_timeout` and nothing else — so a drift
is a failing test rather than a connection to the wrong database.

The shape is the point: `poolOpts` returns **one struct literal** naming every
field, so a field added upstream is a compile error rather than a default
nobody chose. That is exactly what `initUri` gave up by building the value
internally and letting three of its fields be overwritten.

It works. `bench/sql_server.zig` against a port nothing is listening on now
boots, serves `/health` 200 and answers `/people/:id` with a 500 — which is
the documented sentence, finally true.

## The reconnector, which had never run

Fixing it turned on a code path that had been dead since the module was
written. `Pool.init` hands `size - connect_on_init_count` connections to a
`Reconnector`, which spawns an OS thread and retries every two seconds.

Under the engine that is fine — measured, not assumed: a server with
`connect_on_init = 0` boots with the database down, connects when it comes up,
serves 134,967 requests a second at a pool of eight, and shuts down clean.

**Under `std.Io.Threaded` it panics, and it took 77 tests with it.** The
reconnector's thread parks on an `xsync.Mutex` against the `Io` it was handed,
and `Threaded` cannot park a caller that is not one of its own tasks — it
reaches `unreachable` in `Mutex.zig`. zio parks across threads, which is why
the server is fine and the test harness is not.

So `sql/live.zig` dials its whole pool, with the reason written where the
harness is, and `Opts.connect_on_init` says the same thing to anybody driving
a `Db` from a `std.Io.Threaded` — **set it to `size`.**

That is a sharp edge and it is left rather than papered over. The alternatives
were worse: nilo cannot see which `Io` it was given, and building a second
pool lifecycle of its own to avoid a driver's would be inventing a connection
manager to work around a mutex.

## What is upstream and what is here

Two defects in pg.zig, both worth reporting:

- `initUri` drops `connect_on_init_count`. Worked around here.
- `Reconnector.run` cannot run against `std.Io.Threaded`. Not worked around;
  documented, and avoided in the one place nilo controls.

`sql/postgres.zig` is the only file allowed to name pg.zig
([ADR 0039](./0039-the-shape-of-a-query-is-settled-while-compiling.md)), which
is why the workaround has exactly one address.

## What it costs

Against [ADR 0018](./0018-the-trade-budget-has-three-axes.md)'s four axes:

- **Allocations per request.** None. The URI is parsed once, at
  `nilo_start`, into a scratch arena that goes back before `open` returns.
- **Memory per idle connection.** Nothing — and *less* at startup for anybody
  who left `connect_on_init` at its default, because the pool no longer
  opens `size` Postgres backends before serving its first request.
- **Throughput and p99.** Nothing on the request path.
- **Binary size.** +0 stripped ReleaseFast on every example; the forty lines
  replace a call into forty lines of pg.zig.

## Consequences

- A rolling deploy no longer stampedes the database: `size` backends per new
  instance used to be opened at boot whether the traffic needed them or not.
- A `size` larger than the server's `max_connections` is no longer a server
  that will not start. It is a pool that fills as far as it can.
- The claim in `sql/db.zig`'s header is held by something runnable rather than
  by having been written down, and the header says which.
- **The next behaviour to distrust is the next one whose evidence is an
  absence.** This one survived because every test has a database.
