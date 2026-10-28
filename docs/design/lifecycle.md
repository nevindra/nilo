# Lifecycle

**A service is not finished when you `provide` it, and not stopped when your `defer` runs: both happen on the event loop, at points `listen()` controls.**

**Guide:** [Deploying](../guide/deploying.md), [Work that is not a request](../guide/background.md) · **Reference:** [The App](../reference/app.md)

The code is `http/service.zig` (the four markers and the registry), `http/app.zig` (`provide`, `before`, `start`, `listen`, the boot phases) and `http/health.zig`.

## Overview

```
provide(&svc) ──► registry records nilo_start / nilo_stop / nilo_ready / nilo_check
                   (a null check per hook the service does not declare)

listen():
  1. every nilo_start(io[, limits])   ── opens what the service owns, on this loop
  2. every app.before(f, args)        ── a *nilo.Run, thrown away after
  3. every nilo_check(io)             ── looks at what step 2 made
  4. every spawn(...)                 ── may use any of the above
       … requests served …
  stop: connections cancelled, then nilo_stop() in reverse order, then the Runtime goes

app.start(io) runs phases 1-3 on the caller's own Io, for a program with no listen().
```

## Rules

1. **A service finishes setting itself up once a loop exists, not when it is provided.** It declares `pub fn nilo_start(self: *T, io: std.Io) !void`, which `listen()` calls once, in provide order. A service without one costs a single null check at startup. [ADR 037](../adr/037-a-service-that-needs-the-loop-is-finished-when-the-loop-exists.md)
2. **The startup order is: bind, then start services, then log "listening".** A port that is already taken is still reported first, and the line saying the server is up is only printed after every `nilo_start` has returned. [ADR 037](../adr/037-a-service-that-needs-the-loop-is-finished-when-the-loop-exists.md)
3. **Providing a `*const` service that has `nilo_start` is a compile error**, because finishing setup means writing to itself. [ADR 037](../adr/037-a-service-that-needs-the-loop-is-finished-when-the-loop-exists.md)
4. **A service is shut down before the loop is**, with `pub fn nilo_stop(self: *T) void`, called during `listen()`'s teardown after connections are cancelled and before the Runtime is destroyed. [ADR 121](../adr/121-a-service-is-stopped-before-the-loop-is.md)
5. **Services stop in the reverse of provide order**, and `nilo_stop` runs even when startup failed partway, so a pool that `ready` opened is still closed. [ADR 121](../adr/121-a-service-is-stopped-before-the-loop-is.md)
6. **A service that put work on the loop needs `nilo_stop`, or the loop cannot shut down.** A task still pending when the Runtime is destroyed fails an assertion instead of exiting cleanly. [ADR 121](../adr/121-a-service-is-stopped-before-the-loop-is.md)
7. **A health route asks the services, not the process.** `app.health(path)` answers `200 {"status":"ok"}`, a `503` naming which service is not ready and why, or `503 {"status":"stopping"}` once shutdown has started, always with `Cache-Control: no-store`. [ADR 154](../adr/154-a-health-route-asks-the-services.md)
8. **Readiness is a reason, not a bool.** `pub fn nilo_ready(self: *T, scope: *nilo_core.AnyScope) ?[]const u8` returns null when ready, or a string explaining why not. A service without it is assumed ready. [ADR 154](../adr/154-a-health-route-asks-the-services.md)
9. **There is one health route, and it means "ready", not just "alive".** Any route already answers a liveness check. A probe against a paid service such as S3 is not built, because one request a second to someone else's bucket is a bill, not a check. [ADR 154](../adr/154-a-health-route-asks-the-services.md)
10. **Work that needs a service runs on that service's own loop, in a fixed order, never before it or on a different loop.** `app.before(func, args)` calls `func` with a fresh `*nilo.Run` followed by `args`. If it fails, `listen()` does not start the server, and the services already started are stopped on the way out. [ADR 180](../adr/180-work-that-needs-the-services-runs-on-their-loop.md)
11. **Startup has four phases, always in this order**: every `nilo_start`, then every `app.before` call, then every `nilo_check`, then `spawn` work. `nilo_check` sees what `before` created, which is why the schema check moved out of `nilo_start` into its own hook. [ADR 180](../adr/180-work-that-needs-the-services-runs-on-their-loop.md)
12. **`app.start(io)` runs phases one to three on the caller's own `Io`, for programs that never call `listen()`**: a test through `testing.Client`, a script, a worker on `jobs.serveOn(io)`. A service keeps the `Io` it was started with, so calling `listen()` after `app.start(io)` is rejected once any service has started, naming it. [ADR 180](../adr/180-work-that-needs-the-services-runs-on-their-loop.md)
13. **`db.expecting(version)` is only the version check**, installed as a `nilo_check` on the pool that `nilo_start` already opened, with no `before` call needed. A database that is behind is rejected by name; one that is ahead is allowed and logged. [ADR 180](../adr/180-work-that-needs-the-services-runs-on-their-loop.md)
14. **A service's metrics are found when it is provided, not asked for at runtime.** `provide(&svc)` also records a table of the `nilo.Counter`, `nilo.Gauge` and `nilo.Histogram` fields of the type, and of its `nilo_metrics` rows, in the entry (null for a service with none); a scrape prints them and `listen()` refuses a page that cannot be one (a name that is two families, more than 1,024 series). It is a hook of a kind, read by the scrape and never by a request. [ADR 079](../adr/079-the-route-table-is-the-registry.md)

## Decisions

| ADR | What it decides |
|---|---|
| [037](../adr/037-a-service-that-needs-the-loop-is-finished-when-the-loop-exists.md) | The `nilo_start` hook: when a service finishes setting itself up, and the startup order around it |
| [121](../adr/121-a-service-is-stopped-before-the-loop-is.md) | The `nilo_stop` hook: a service is shut down before the Runtime, in reverse provide order |
| [154](../adr/154-a-health-route-asks-the-services.md) | The `nilo_ready` hook and `app.health`: readiness as a reason, asked of the services instead of the process |
| [180](../adr/180-work-that-needs-the-services-runs-on-their-loop.md) | `app.before`, `nilo_check`, `app.start(io)`, and the four-phase startup order that makes them safe together |

Related topics: why the only dependency of a plain build is zio, and why `serve` is the only place an `Io` is handed out, is [ADR 001](../adr/001-zio-as-the-engine-behind-the-bulkhead.md) (engine); why a handler must not block the loop (which `nilo_start` connecting a pool would otherwise do) is [ADR 013](../adr/013-handlers-must-not-block-the-thread.md); the four trade-off axes every cost on this page is measured against are [ADR 017](../adr/017-the-trade-budget-has-four-axes.md); startup opening only the connection its work needs, which `nilo_check` relies on, is [ADR 115](../adr/115-a-boot-dials-the-connection-its-work-needs.md); migrations, the most common thing to put in `app.before`, have their own page at [`sql-migrations.md`](./sql-migrations.md).

## Open questions

- **How many allocations a `select` makes during `app.before` or `nilo_start`** has not been measured; ADR 037 records it as still to check against the request-path allocation budget test.
