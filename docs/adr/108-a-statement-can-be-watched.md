# A statement can be watched

**Status:** accepted
**Topic:** [sql-runtime](../design/sql-runtime.md)

`logger.zig` writes one line per request and there was no way to see the SQL
underneath it — not in Debug, not behind an option, not on a slow query. Every
other framework has this, because it is the first thing anybody reaches for
when a page is slow.

It is cheaper here than anywhere else, and that is the argument for building it
rather than a wish: the statement text is a **comptime constant** this module
wrote, the plan name is already derived from it, and the parameter tuple is
already built. Nothing has to be assembled for a watcher to be told.

```zig
db.watching(sql.logging);       // one debug line per statement
```

```zig
fn slowOnes(sent: sql.Sent) void {
    if (sent.micros < 50_000) return;
    std.log.warn("slow: {d}us {s}", .{ sent.micros, sent.sql });
}
db.watching(slowOnes);
```

## What it is given, and the one thing it is not

```zig
pub const Sent = struct {
    sql: []const u8,
    plan: ?[]const u8,
    micros: u64,
    rows: ?usize,
    failed: bool,
    problem: ?wire.Problem = null,   // ADR 117
    route: ?[]const u8 = null,
};
```

**The parameter values are not in it.** They are the interesting half — the
question after *which statement is slow* is usually *slow for which id* — and
they are also a password, an email address, and whatever else a request
carried. [ADR 024](024-every-failure-answers-as-json.md) is
careful about exactly this one layer up, where a failure's own text never
reaches the client; a log line is read by more people than a response is, and
kept for longer.

So the first version answers the question somebody opens this for and stops
there. A `values` half can be added later behind a flag whose name says what it
does; it cannot be taken back out of a log.

`rows` is null where nobody can honestly say: a statement that failed, and
`db.stream`, whose rows are pulled by the handler long after this call returned.
For a stream, `micros` is how long the statement took to **open**, which is the
half that is worth reporting and the half that can be reported truthfully.

**`route` is the `operationId` of the route whose request sent the
statement**, what `c.routeName()` answers
([ADR 162](162-a-middleware-can-learn-which-route-it-is-in-front-of.md)), and
null under a `Run` or for a request nothing matched. It is what joins a slow
`SELECT` to the page that paid for it: one list, its count and seven facets
are often the same text, and the text alone cannot say which request each
came from. It is read off the Scope every statement is already handed, by
`core.routeNameOf`, which asks for a declaration rather than naming `Ctx`:
`nilo_sql` may not import the HTTP layer, and a Scope without a `routeName`
answers null. A pointer the App already holds, so nothing is allocated, and a
watcher may keep it past the request.

## On the `Db` rather than on the Wire

The roadmap sketched a hook on `Wire.run`/`Wire.exec`. That is one layer too
low: it would make every Wire owe the timing code — two implementations and the
`Fake` — and it would put the same call in six places instead of four.

`fill`, `only`, `execTold` and `stream` are the four funnels every statement in
this module goes through, and they are already where the plan name and the
statement text are both in hand. `fill` and `only` took a `*W` and now take the
`*Db`, which they can get the `*W` from — inside a transaction it is the same
pointer, because the `Tx` took it from there.

**A plain function pointer, not an interface.** Everything a watcher needs is
in the `Sent`. A `Db` is a Service, shared by every request in flight
([ADR 010](010-shared-services-need-a-lock-from-the-bulkhead.md)),
so anything a watcher closed over would need a lock this module cannot see —
and the two things people actually write, a log line and a counter, need
neither.

**One watcher, not a list.** A second one is a function that calls two, which
is a line the caller writes rather than a registry this module has to own,
size and lock.

## What it costs

**One null test per statement when nobody is watching**, which is the default
and is what every existing program pays. Nothing is allocated on any path.

**Two monotonic clock reads when somebody is** — 15ns each
(`core/clock.zig`), against a statement that is measured in microseconds even
against SQLite in the same process.

**The monotonic clock rather than the wall clock**, which is why
`core.monotonicMicros` is new. `nowMicros` is `CLOCK_REALTIME` and is allowed
to step: NTP moves it, an operator moves it, and a query straddling either
would be reported as having taken an hour or as having finished before it
started.

**Binary**: the `Sent` struct and four call sites. `sql.logging` links only if
it is named.

## What was rejected

**A `slow_query_ms` option.** One number in the wrong place: what is slow for a
health check is not slow for a report, and a watcher that wants a threshold
writes `if (sent.micros < …) return;` — which is the second example above.

**Handing the watcher the Scope.** It would make a request id reachable, which
is the obvious next thing to want. It also makes the signature generic over the
Scope, which means the watcher becomes a comptime shape rather than a function
pointer, and every program that stores one has to name a type it did not write.
The route is read off the Scope before the call instead, into the `Sent`.

**The request id on the `Sent` beside the route.** `Ctx.requestId` mints one
when the request carried none, which is an allocation on a path that did not
ask for it, once per statement ([ADR 017](017-the-trade-budget-has-four-axes.md)).
The route answers *which page*; *which request* is the log line the request
writes, and a watcher that needs both joins them there.

**The fiber's threadlocal**, where `fail`'s message box lives
([ADR 006](006-failure-box-bound-to-the-fiber.md)): the other way the route
could have reached a Service. It is the arrangement the standing risk about
`bulkhead.slot()` is about, and the Scope was already in the call.

**Printing from inside this module.** `std.log` with no way to turn it off is
what "not in Debug, not behind an option" was already too much of.

## What is still open

**An `AnyScope` carries no route.** Its table has five calls and `routeName`
is not one, so a statement sent from the far side of a function pointer is
reported with none. The sixth call is a line when somebody meets it.
