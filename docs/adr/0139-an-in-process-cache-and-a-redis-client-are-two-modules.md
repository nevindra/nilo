# An in-process cache and a Redis client are two modules

`nilo_cache` keeps bytes in this process. A Redis client keeps them in
somebody else's. They answer different questions and only one of them is being
built, and this file is here because the *tempting* third option — one module
with two backends behind one interface — has to be refused before either
exists rather than after both do.

## They cannot be one module, and the build step is what says so

[ADR 0041](0041-a-module-sits-where-the-loop-puts-it.md) decides a module's
layer with one question: does it need the event loop? A cache in this process
hashes a key, indexes a table and copies bytes. Nothing waits, so it needs no
loop, so it is a **tool module** beside `nilo_id`, `nilo_config` and `nilo_pw`
— importing nothing, and running under a plain `zig test cache/cache.zig` with
no build graph.

Reading a socket waits. A Redis client therefore borrows the loop and holds a
named system, which makes it a **Service** beside `nilo_sql` and `nilo_s3`.

Merging them drags a socket into the bottom layer, and `zig build layering`
refuses the import before anybody argues about it. The same question gives
opposite answers for the two, and both answers land in the right place, which
is the rule working rather than a coincidence.

## And they must not share an interface

One `Space(name, T)` shape reads the same in both, which is deliberate: nobody
should have to learn it twice. **That is not the same as being swappable, and
the difference is what a handler has to handle.**

| | in this process | Redis |
|---|---|---|
| the call times out | never | yes |
| the connection drops | never | yes |
| a value another instance wrote comes back | never | yes |
| survives a restart | no | yes |

An interface over both has to pretend those rows are the same. It has two ways
to do that and both are worse than having no interface: give the in-process
cache an error set it can never return, so every caller writes a `catch` for a
thing that cannot happen, or give the Redis one the in-process signature and
swallow a network failure into a miss — which turns "the cache is down" into
"the cache is cold", and a service that silently stops caching under load is a
service that falls over at the worst moment.

**A caller who moves from one to the other is changing what can fail, and that
is a rewrite of the error handling by definition.** Making the two types look
interchangeable hides exactly the work the move consists of.

## `nilo_redis` is not being built

Not "later" and not refused: it is waiting for somebody who needs it. The
roadmap carries it as `Waiting on: a caller`, which means the design is settled
and the use case is what is missing.

The reason it can wait is a property of nilo rather than a guess about
fashion. Most of what a Redis is doing in a deployment elsewhere is making
several processes agree, and nilo's whole argument is that one process serves
what a fleet serves elsewhere. Two of the three usual reasons are already gone
here and neither went on purpose:

- **Session storage.** `http/session.zig` seals the whole session into a
  cookie: no table, no sweep, no store
  ([ADR 0088](0088-an-expiry-a-client-can-ignore-is-not-one.md)).
- **Rate limiting.** `http/allowance.zig` is a fixed table in this process
  ([ADR 0114](0114-an-allowance-is-a-table-sized-while-compiling.md)).

`nilo_cache` is the third, and the three together are a position rather than
three coincidences: **one process, and most of what is said to need a second
service does not.**

## What that position costs, said out loud

At two instances, three things go wrong **quietly** rather than loudly, and
quiet is the part that matters:

- The cache answers differently depending on which instance a request lands on.
- An allowance of `.per_window = 100` admits 200, because each instance keeps
  its own table.
- A WebSocket message reaches only the clients attached to the instance that
  sent it.

None of those raise an error, and a failure that raises nothing is discovered
in production. So the assumption is documented in the README and in each
module's header rather than left to be inferred — **a reader who runs four
instances should find that out in the first hour**, not after building on it.

This is a positioning bet and there is no number that settles it, which is
unusual here and worth naming: what makes it survivable is that it is stated
loudly enough to be contradicted early.

## What was rejected

**One module with a backend option.** Above: the failure modes differ, and an
interface over them has to lie about one side.

**Naming the in-process one `nilo_cache` and making Redis a backend of it.**
The name is the promise, the way it is for `nilo_sql`
([ADR 0039](0039-the-shape-of-a-query-is-settled-while-compiling.md)). `cache`
is a use rather than a system — the same module is where rate-limit counters
and locks would go — and a name that implies a swappable layer promises the
thing above.

**Building the Redis client first.** It is a Service: a pool, `nilo_start`, a
protocol and a container to test against. The cache is a tool module and needs
none of that, and it settles the typed-keyspace shape and the lifetime question
on the easy side first. Getting that shape wrong costs a week here and a month
there. The spike that produced
[ADR 0138](0138-a-cache-holds-its-bytes-under-a-lock-it-can-spin-on.md) is what
that week bought: the first design was wrong, and it was wrong in a way no
amount of reading would have shown.

**Depending on an existing Zig Redis client when the time comes.** Not
rejected — deferred, with what was found written down so it is not looked up
twice. [okredis](https://github.com/kristoff-it/zig-okredis) is the fuller of
the two: RESP3, typed zero-allocation replies decoded by comptime reflection,
pipelining, transactions, and command builders whose syntax is checked while
compiling. It has no pub/sub, the author having said in `CLIENT.md` that he
could not find an allocation-free shape for it, and no connection pooling —
"managing the connection is your responsibility". Its Zig 0.16 port arrived as
a pull request from outside the project in July 2026, after nothing since
November 2025. [redis.zig](https://github.com/lalinsky/redis.zig) is by zio and
pg.zig's author, has pooling and retry, and covers strings, TTLs and hashes on
RESP2; its last commit of substance was May 2026 and pipelining, pub/sub,
transactions, lists, sets, Lua and cluster are all unticked on its roadmap.
**Both are alpha and neither has pub/sub**, so cross-instance WebSocket fan-out
is not something a dependency would hand over.
