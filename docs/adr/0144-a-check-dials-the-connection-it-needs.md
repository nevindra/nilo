# A check dials the connection it needs

`db.checking(&.{ User, Order })` compares every Row against the table it names
while the server is starting. The point of doing it at boot is that a Row
disagreeing with its table **stops a deploy**.

On the defaults it stopped nothing:

```
warning: nilo could not check the schema (Disconnected). The tables will be
checked by whichever request reaches them first, which is later than anybody
wanted.
info: nilo listening on 127.0.0.1:8081 across 16 thread(s)
```

The server starts. The deploy is green. Nothing was checked.

## Why

`Opts.connect_on_init` defaults to 0, which is what makes a server boot with
its database switched off
([ADR 0039](0039-the-shape-of-a-query-is-settled-while-compiling.md), and
[ADR 0062](0062-a-pool-that-dialled-itself-whatever-it-was-told.md) is where
it was made true). A pool that dialled nothing has nothing for the check to
borrow, so `pool.acquire()` answers `Disconnected` on the first line of the
check, every cold boot, on every program that wrote `.{}`.

This is not a race. It fires every time.

The roadmap already recorded that **forgetting** to call `checking` is silent.
This is a second way to end up with no check, and it does not involve
forgetting: it is the one you get by taking the defaults and doing everything
right.

## What it is now

A `Db` that has a check to run asks the pool for one connection:

```zig
const dialing_for_check = self.check != null and self.opts.connect_on_init == 0;
```

`connect_on_init` goes to 1 for that open. Nothing else about the pool
changes, and a caller who set the number themselves gets exactly what they
set.

**The dial is still allowed to fail.** ADR 0039's promise is older than this
one and it is not being traded away: a database that is merely down does not
stop the server. So a failed dial falls back to opening the pool the way `.{}`
asked for, and says in one line which of the two happened:

```
warning: nilo could not dial the database to check the schema against it
(ConnectionRefused), so it is starting without the check. `connect_on_init`
is 0, which is what asks for a server that starts while its database is down.
```

A URL nilo cannot read does not get the retry. That failure will not become a
different failure on a second attempt, and it already has a message written
for it.

## The alternative that was rejected

**Refuse to start when a check is pending and the pool would have nothing to
check with.** It guarantees the check runs whenever the server runs, which is
the strongest version of what this is for.

It also reopens the exact bug ADR 0062 closed. Every service that follows the
guide calls `db.checking`, so under this rule every one of them refuses to
start while its database is restarting, and a rolling deploy during a database
blip becomes an outage. The check is worth a connection. It is not worth that.

## What did not change

`schema_mismatch_is_fatal` still decides what a *disagreement* does, and still
defaults to stopping. This ADR is about the check running at all, not about
what it finds.

SQLite never had the problem: a file is opened or it is not, `connect_on_init`
is ignored there, and the connection exists by the time the check runs.

## Consequences

- One extra connection handshake in `nilo_start`, and only for a program that
  called `checking`. It is the same handshake the first request would have
  paid.
- A program with no database running takes one refused connection at boot
  before it carries on. Bounded by `timeout_ms`, which it was already.
- The warning that used to say "could not check the schema" now says which
  thing failed, because "the pool had nothing to lend" and "the database said
  no" want different sentences.
- This is the second time in this file's history that a behaviour survived
  because its only evidence was an absence. ADR 0062 closed on a warning about
  exactly that, and it was right.
