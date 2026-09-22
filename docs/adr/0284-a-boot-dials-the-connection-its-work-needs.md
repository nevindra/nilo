# 0284 — a boot dials the connection its work needs

**Status:** accepted
**Extends:** [ADR 0144](./0144-a-check-dials-the-connection-it-needs.md)
(a `Db` with a check dials one connection for it),
[ADR 0220](./0220-work-that-needs-the-services-runs-on-their-loop.md)
(`app.before` is where a migration runs).
**Keeps:** [ADR 0039](./0039-the-shape-of-a-query-is-settled-while-compiling.md)
and [ADR 0062](./0062-a-pool-that-dialled-itself-whatever-it-was-told.md)
(a server starts with its database down).
**Found by:** a query engine whose tables are its own DDL — `.unchecked =
true`, nothing else set — loading its models in `app.before`. Every cold
boot: `Disconnected`, from `pool.acquire()`, with Postgres up.

## Context

ADR 0144 found that a `Db` written `.{}` reached its schema check with an
empty pool, and had the boot dial one connection so the check has something
to ask. It scoped the dial to a `Db` that *has* a check:

```zig
const dialing_for_check = self.check != null and self.opts.connect_on_init == 0;
```

The check is not the only work that runs before the first request. ADR 0220
made `app.before` the place for a migration, a version guard or a key set,
and the reference's own example is `app.before(migrate, .{&db})`. `listen()`
starts the services and runs those hooks a moment later — while pg.zig's
reconnector is still dialling the pool from its own task. `acquire` on a
pool with nothing alive answers `PoolExhausted` at once rather than waiting
its `timeout_ms`, and nilo carries that out as `Disconnected`.

[ADR 0277](./0277-the-schema-check-runs-after-the-boot-work.md) then moved
the check itself to after `before`, so the hook is now the *first* thing to
borrow a connection, and the one dial that was gated on `self.check` is the
one it needs.

So the shape ADR 0144 closed for the check was still open for the hook, and
a `Db` that says `.unchecked = true` — the one whose tables are somebody
else's DDL, which is exactly the `Db` that runs a migration by hand — was
the one that hit it. Deterministically, on the documented path, with the
database up.

## Decision

`nilo_start` dials one connection whenever `connect_on_init` is 0, whether
or not there is a check:

```zig
const dialing_for_check = self.opts.connect_on_init == 0;
```

The rest of the pool fills lazily as before. `nilo_start` cannot see what
the App will run next, and it does not need to: a schema check, a version
guard and a `before` hook all want the same one connection, so it is dialled
for whatever they turn out to be.

**The dial is still allowed to fail.** ADR 0039's promise stands: a
database that is merely down does not stop the server. The fallback is the
same as ADR 0144's — open the pool as `.{}` asked, say in one line what was
skipped. The line now names `app.before` beside the check, because a hook
that then fails with `Disconnected` stops the server (ADR 0220), and the
reason should be one line above it.

## The alternatives that were rejected

**Wait in `acquire` while the pool is still filling.** `PoolExhausted`
from a pool that has never had a connection and one that lost them all in
an outage are the same state to pg.zig. Waiting on it would turn the
outage's fail-fast into a wait of `timeout_ms` per request, on every
request, which is the parked fiber ADR 0071 counts against every
connection — and it would read pg.zig's `_missing`, which is that pool's
own business.

**Have the App tell the `Db` there is a `before` hook.** A new service
hook for a phase the App already runs, so that one service can make a
decision the boot already makes for the check. The `Db` would learn about
`App`'s phases; the layering (`sql/` under `http/`) says it must not.

**Keep the scope and document the workaround** — `connect_on_init = 1`
on any `Db` that has a `before` hook. That is ADR 0144's own rejected
shape: the check that was correct where it was written and the option
that was correct where it was written, with the bug in neither file. A
default that the documented example fails on is not a default.

## Consequences

- One connection handshake in `nilo_start` for every `Db` on the default
  `connect_on_init`, where before it was every `Db` but an `unchecked`
  one. The same handshake the first request would have paid.
- A program whose database is down takes one refused dial at boot before it
  carries on, bounded by `timeout_ms` — as a checked `Db` already did.
- `sql/live.zig` holds it: an `unchecked` `Db` on the defaults answers a
  query the moment `nilo_start` returns. It goes red on ADR 0144's rule.
- Third time in this file that a behaviour survived on an absence — ADR
  0062, ADR 0144, this. The generalisation the second one drew holds:
  **an option whose default disables a feature somewhere else is not
  visible from either place.** This one adds: when the fix for it is
  scoped to the one caller that found it, the next caller finds it again.
