# A second database is a second type

**Read replicas** and **a query cache** were the last two lines under
*Connection and session* in the Drizzle checklist. They get one ADR because
they failed the same test in opposite directions: one is a mechanism this
module was one type parameter away from having, and the other is a policy it
could not be right about from here.

## Read replicas

### What was actually in the way

The Service registry is keyed by type
([ADR 0011](./0011-shared-services-need-a-lock-from-the-bulkhead.md)). So
`*sql.Db` is *the* database, singular, and `app.provide` a second one and the
two collide. That — not routing, not pooling — is what made a replica
impossible to write. A user could not even build it by hand, because the
wrapper struct that would work has to forward every method on `Db`.

### What was decided

```zig
const Replica = sql.Named("replica");

fn listing(rdb: *Replica, c: *nilo.Ctx) ![]Product { … }   // may be stale
fn buy(db: *sql.Db, c: *nilo.Ctx) !Order { … }             // must not be
```

`sql.Named(name)` gives back a `Db` type distinguished by its name, and two
types are two services. **Which pool a statement takes is written in the
handler's argument list**, which is where this framework already puts that
kind of decision — a pointer is a service, and now the service says which
database it is.

It generalises past replicas for free: a reporting warehouse, a second
tenant's database, a legacy one somebody else owns.

The implementation is one comptime parameter and one constant:

```zig
pub fn DbOf(comptime W: type, comptime D: type, comptime name: []const u8) type {
    return struct {
        pub const db_name = name;
        …
    };
}
```

**The name has to be *kept* to work.** Zig memoises a generic on the type it
returns, so a parameter the body never mentions gives the same type back
twice — measured, not assumed: an unused `name` makes `Thing(u8, "a") ==
Thing(u8, "b")`. Keeping it in `db_name` is what separates them, and the
compiler holds the rule for free, because dropping it is an unused-parameter
error.

`db_name` is not decoration either: the two Debug traps read it, so "a
transaction was begun and never ended" says *which* database — the one
question having two of them creates.

### Why no routing, and why that is the design

An automatic reader — writes to the primary, reads to a replica — is the
obvious next step and is the shape that must not ship. It needs four things:

1. **Routing.** Easy, and the only one of the four this module could do.
2. **Health checking and failover.** A replica that is down has to leave the
   rotation, which is a background task. There are none here.
3. **Lag awareness.** `pg_last_xact_replay_timestamp()` is a poll, which is
   also a background task. Without it there is no bound on how stale a read
   is.
4. **Read-after-write safety.** A handler that writes and then reads gets its
   own write back only if the routing tracks the session's LSN. Getting this
   wrong is **silent**, which is the failure mode this project consistently
   refuses — the null-in-a-condition compile error, the third nullability
   answer in [ADR 0056](./0056-a-view-is-a-table-that-cannot-say-what-is-not-null.md),
   and `prepared`'s default all turn on the same rule.

Shipping 1 without 2, 3 and 4 is a feature that works in the demo and rots in
production. `CLAUDE.md` has a name for that: **a feature that cannot be made
to fit does not ship in a worse shape.**

So the mechanism ships and the policy does not. The caller writing `*Replica`
in a signature is a caller saying *this read may be stale*, once, where a
reader will see it — which is a better contract than a router guessing.

## A query cache

**Refused, and the performance case for it is the strong half.**

[ADR 0059](./0059-a-round-trip-is-not-the-cost-worth-chasing.md) measured a
round trip at 24 µs against 2.3 µs of query. An in-process cache would turn a
hot read into approximately nothing, and it would be the largest single win
available. That is not why it is refused.

**Invalidation cannot be right from here.** A cache has to know when a row
changed, and this module sees only the writes that go through *it* — not
another process, not a second replica of the same service, not a migration,
not psql, not a trigger, not a foreign data wrapper. A cache that is correct
only when nilo is the sole writer is a cache that is wrong in production and
right in the test suite, which is the worst arrangement available.

The two escapes both fail on this project's own terms:

- **A TTL** makes staleness a number the caller guesses, and moves the bug
  from "wrong" to "wrong for up to N seconds". It is a policy, and it belongs
  where the policy is known.
- **Manual invalidation** — Drizzle's tagging — is annotation, and the first
  line of this project's README is that nothing is annotated anywhere.

There is a second cost, and it is on the axis held hardest. The prepared
statement cache ([ADR 0057](./0057-a-statement-that-is-a-constant-can-be-prepared-once.md))
is bounded by the *program*, because the statements are comptime constants. A
result cache is bounded by **traffic** — same keys, but the values are rows,
and how many is a question about the day rather than about the binary.

What a caller should do instead is what a caller was always going to do: hold
the value in a Service. A Service is a struct of your own with your own
state, its lifetime is the process, and a memoised lookup with the
invalidation rule *you* know is a dozen lines. The module does not need to be
in the middle of that, and being in the middle is the only way it could be
wrong.

## What it costs

Against [ADR 0018](./0018-the-trade-budget-has-three-axes.md)'s four axes:

- **Allocations per request.** None. `sql.Named` adds a comptime constant.
- **Memory per idle connection.** Nothing on an HTTP connection. A second
  `Db` is a second pool, and that is `size` connections the caller asked for
  by writing the second `init`.
- **Throughput and p99.** Nothing. There is no routing branch, because there
  is no routing.
- **Binary size.** +0 unless used. A named `Db` is a second instantiation, so
  a program that drives the *same* Rows through both pays a second copy of
  the calls it actually makes through the second one. Opt-in and proportional
  to use.

## Consequences

- `DbOf` takes three parameters. It is not exported from `sql.zig`, so
  nothing outside the module noticed.
- The two Debug traps name the database. With one `Db` that reads exactly as
  it did before.
- `sql.Named("")` is a Refusal: the name is the mechanism, and an empty one
  gives back `sql.Db` under a second spelling, which would make
  `app.provide` fail much further from the mistake.
- The roadmap's "read replicas" line is closed by the mechanism and its
  "query cache" line by the refusal. Neither is a gap.
