# A health route asks the services

A route that answers `ok` because the process is up is a route that sends
traffic to a server whose database is down.

## What it does now

```zig
try app.health("/healthz");
```

```
200 {"status":"ok"}
503 {"status":"unavailable","waiting":[{"service":"sql.Db","why":"the database is not answering"}]}
503 {"status":"stopping"}
```

One route, registered like the metrics page and protected the same way — by
where it is mounted. It asks every service in the registry that declared

```zig
pub fn nilo_ready(self: *T, scope: *nilo_core.AnyScope) ?[]const u8
```

and a service that declared none is assumed ready. Null is ready; a string
is why not, and it goes on the page beside the service's name. From the
moment the server has been told to stop, the page answers `stopping` with a
503, which is how a load balancer learns to drain this instance before its
listener closes rather than after — the same flag a draining response reads
to say `Connection: close` ([ADR 0020](./0020-a-request-that-lasts-is-still-one-request.md)).
Every answer carries `Cache-Control: no-store`.

Two of the modules that hold something answer. **`sql.Db` sends `SELECT 1`
down the pool** and reports what came back — `Disconnected`, `TimedOut`, or
the statement refused — because that is the only honest reading of "the
database is up", and because `connect_on_init = 0` is a server that starts
with its database down on purpose ([ADR 0062](./0062-a-pool-that-dialled-itself-whatever-it-was-told.md)):
without this, that server's health page would say `ok` over a pool with
nothing in it. **An `s3` Store answers whether it started**, and does not
send a request: a balancer asks every second, and a HEAD to somebody else's
bucket at that rate is a bill and a rate limit rather than a check.

## Why the hook takes a Scope

The obvious signature was `nilo_ready(self) bool`. It is wrong twice over.

A bool makes the 503 a list of type names, and what an operator wants at
three in the morning is the reason beside the name. So the answer is an
optional string — null for ready, and the sentence otherwise — and the
sentence is a literal or lives as long as the Scope, which is what
`scope.arena()` is there for.

A hook with no Scope cannot send a statement, and a statement is what the
honest probe is. The erased `AnyScope` ([ADR 0166](./0166-entropy-a-function-pointer-can-carry.md))
is what lets the registry hold one kind of function pointer while `sql`
keeps naming `anytype` everywhere else: `db.exec(scope, "SELECT 1", .{})`
takes it because it has `arena` and `str`, and nothing in `sql/` learned a
new type.

## What it costs

Put against [ADR 0018](./0018-the-trade-budget-has-three-axes.md)'s four
axes before it was written:

- **Allocations per request.** None on any request that is not the probe.
  The probe takes one arena allocation for the page, the way the metrics
  readout does.
- **Memory per idle connection.** None. The hook is one nullable function
  pointer per *service entry* in the registry, set once at `provide`, and
  `Entry` gained a display name beside it — sixteen bytes per service,
  once, not per connection.
- **Throughput.** Nothing per request. Per probe, one `SELECT 1` if there is
  a `Db`, on the balancer's schedule.
- **Binary size.** One handler and a JSON writer of a dozen lines.

## What is deliberately not built

**Two routes, one for alive and one for ready.** Kubernetes distinguishes
them, and the distinction is real: a liveness probe that fails restarts the
process, a readiness probe that fails only stops traffic. But the alive half
is answered by *any* route on this server, `/` included, and a second route
that says nothing more than "the process answered" is a route the balancer
could point at the first one. One page, and it means ready.

**A probe to the S3 endpoint.** Said above: a request a second to a metered
service is not a health check. A Store that started can sign, and signing
is what it is for.

**A registry of checks the application adds by name.** `app.healthCheck("redis",
fn)` is the shape most frameworks have, and it is the `c.locals` map with a
different label ([ADR 0009](./0009-middleware-is-an-onion-of-ctx-functions.md)): a string
key, a function pointer, nothing checked while compiling. A service that can
be unready says so on its own type, the way it says how it starts and stops,
and the registry finds the hook the way it finds those.

## The alternative that was rejected

**A `fn health() []const u8 { return "ok"; }` in the guide**, which is what
the guide's config page shows and what most applications write. It is three
lines and it is the wrong three lines, because it cannot know what the pool
knows. The application does not have the pool's connection count, and it
should not: that is the module's, and the module is the one to say whether
it can do its job.

## Consequences

- One file, `http/health.zig`, outside the core, handed the pieces; one
  handler and one method on `App`; one hook and one name on
  `service.Registry.Entry`; `Ctx.stopping()`.
- `nilo_ready` on `sql.Db` and `s3.Store`. A third module that holds
  something — a queue, a mail relay — joins in with one function.
- One refusal: a `nilo_ready` of the wrong shape.
- The roadmap's list of small middleware loses `healthcheck`.
