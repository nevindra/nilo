# A spawned fiber belongs to the server, and broadcast waits for a cheaper one

zfast has had nowhere to put work that is not a request. Everything that
runs, runs because a socket asked for it. That is a good default and it is
why the per-connection numbers in ADR 0018 are as small as they are, but it
rules out a whole family of ordinary things: a metrics exporter that batches
before it sends, a job that runs every minute, and — the one that keeps
coming up — sending a WebSocket message to somebody else's connection.

ADR 0022 recorded that last one as not-here and guessed at two shapes for
it: "a per-socket outbox with its own lock, or a mailbox the owning fiber
drains". A spike (`spike/broadcast`, deleted with this ADR) built four
shapes and measured them. Both of ADR 0022's guesses turned out to be
wrong, and one of them is wrong in a way worth writing down.

## The thing that is not about locking

The obvious problem with broadcasting is that a connection's write buffer
belongs to the fiber serving it, so two fibers writing into it interleave.
That is true, and a lock per socket fixes it — no torn frames in any shape
the spike tried, at any depth.

It fixes nothing else. Eight clients, one of them handed a socket and then
never reading from it again, two healthy clients wanting only to talk to
each other:

| | can two healthy clients still talk? |
|---|---|
| the room's lock held across every write | **never arrived** (5s timeout) |
| a snapshot, then one lock per socket | **never arrived** (5s timeout) |

The second row is the finding. Holding a narrower lock is the fix anybody
reaches for, and it buys nothing, because contention was never what was
wrong. The broadcast is performed by the *speaker's own fiber*: it walks the
connections, reaches the one that has stopped reading, and blocks there. It
never gets back to reading its own socket. Everyone else's messages stop
because one client stopped.

> Any design in which fiber A writes to socket B ties A's liveness to B's
> readiness to read. Finer locking does not touch that. The write has to be
> performed by something whose stalling costs only B.

So the write has to be done by a fiber that serves B and nothing else. That
is not a lock, it is a fiber, and a fiber has a price.

## What the price is

A second fiber per connection, draining a queue, measured against 400 idle
connections and repeated until the number stopped moving — byte-identical
across runs:

| | bytes per idle connection |
|---|---|
| one fiber | 66,959 |
| two fibers | 75,633 |
| **difference** | **8,673** |

ADR 0018's hard invariant is **8,767 bytes per idle connection**. The writer
fiber costs, to within one percent, that entire budget a second time.

The spike then tried the obvious way to get it back — `zio.BroadcastChannel`,
one ring for the whole server instead of a queue per connection. It is
better in two ways that matter: delivery went from 5,925 of 12,000 messages
to 12,000 of 12,000, and the send path shrank to `wire.send(post)` with no
lock, no walk, and no touching another connection's memory at all. It made
no difference whatsoever to the number above. Idle, the two agree to the
byte, because a queue that is never written costs nothing and the fiber
costs the same either way.

**The fiber is the price, and no amount of cleverness about the queue
changes it.**

## What was decided

**`spawn` enters the Bulkhead. Broadcasting to other sockets does not ship.**

Splitting those two is the whole decision. They arrived together — the spike
needed `spawn` to build broadcast — but only one of them is paid for.

`spawn` is the piece every member of this family needs, including the ones
that cost nothing per connection: a batching exporter is one fiber for the
whole process, not one per socket. It is also unambiguously the Engine's:
what a fiber is, how one is started, and what happens to it at shutdown are
things only the Engine knows. That is the same argument ADR 0011 made for
`Mutex`, and the Bulkhead grows one item at a time for a reason each time.

Broadcast does not ship because 8,673 is not a number to spend quietly. A
process that broadcasts holds far fewer connections than `max_connections`
allows, so it may well be affordable — but the person running it has to be
the one to decide that, and today the only shape zfast could offer them is
the one that doubles the budget for every connection whether it is listening
to a broadcast or not.

### `spawn` is joined, not detached

The spike used a detached fiber, and shutdown said this:

```
info: zfast stopping: 8 request(s) still being answered, waiting up to 10000ms
```

There were sixteen fibers. Nothing spawned is counted by `Stop.in_flight`
or cancelled by `group.cancel()`; the writers only stopped because their
handlers' `defer` closed their queues on the way out. It did not hang — but
a `spawn` the shutdown path cannot see is a shutdown message that lies, and
work spawned *outside* a request would have no handler to close anything.

So the Bulkhead's `spawn` joins the accept loop's group: counted while it
runs, cancelled when the grace period ends, exactly like a connection. A
fiber nobody can see at shutdown is not something to hand users.

### `fail` in a spawned fiber says nothing, and that is correct

Checked rather than assumed, because ADR 0007 is about precisely this class
of bug. In a spawned fiber the task-local slot is unset, so `fail.notFound`
finds no `InFlight` and returns a plain `error.Failed` with no message —
which is the documented behaviour outside a request already.

The near miss is worth recording. `bulkhead.slot()` is
`engine.slot() orelse fallback_slot`, and `fallback_slot` is a **threadlocal**.
If it were ever set on an executor thread, a spawned fiber running there
would read it and write its message into some unrelated request's Failure —
ADR 0007's leak, reintroduced. It is safe only because the one thing that
sets it, `bulkhead.blocking`, does so inside `zio.blockInPlace`, which
submits to the thread *pool*; the assignment happens on a pool thread and
spawned fibers run on executor threads.

That is a real coupling holding up a real invariant, and nothing says so at
either end. Both ends now carry a comment pointing here.

### A `Str` must not cross into spawned work

A `Str` points into the request arena (ADR 0004), which is reset when the
request ends. A spawned fiber outlives the call that started it by
definition, so a `Str` captured into one is a use-after-free the moment the
request finishes first — and it will not look like one, because in
development the fiber usually wins the race.

Zig cannot catch this, so it is documentation plus the shape of the API:
`spawn` takes arguments by value, and the guide says plainly that anything
borrowed from a request has to be copied before it goes in. This is the same
footgun ADR 0015 names as Fiber v1's best-known one, arriving from a new
direction.

## What was rejected, and why

- **Accepting the doubled budget and shipping broadcast anyway.** ADR 0018
  calls the per-connection figure a hard invariant. Doubling it for a
  feature most applications do not use, silently, for every connection, is
  not a trade to make on a user's behalf.

- **`zio.BroadcastChannel`, for now.** Better delivery and a much smaller
  send path, and it crashed 2 runs out of 4 under connection churn —
  `simple_queue.zig:43`, a waiter node pushed onto a queue while already in
  a list, reached from `BroadcastChannel.receive`. The same test crashed 0
  of 2 with no spawned fiber and 0 of 4 with a per-connection queue, so it
  is not churn on its own. The difference is forced: a shared ring has no
  per-consumer close, so the only way to stop one reader is to cancel its
  fiber.

  This is not a diagnosis — the race is in zio's wait queue and the spike
  did not go and find it. It was enough to keep it out.

  > **Chased down afterwards, on a standalone reproduction, and one guess
  > here was wrong.** `in_list` is a `bool` under `runtime_safety` and
  > `void` otherwise, so this ADR reasoned that ReleaseFast would relink a
  > node silently. It does not — the flag is only ever asserted on, never
  > read for linking. What ReleaseFast does instead is **deadlock**: 17 runs
  > in 20 hung where a clean run takes 200ms. Debug and ReleaseSafe abort
  > 10 in 10 and 3 in 3. Cancellation is required to reach it: the same
  > program closing the channel and waiting instead is clean 5 times in 5.
  > Reported upstream with a standalone reproduction as
  > [zio#667](https://github.com/lalinsky/zio/issues/667).

- **A mailbox the owning fiber drains** — ADR 0022's second guess, and the
  shape that would cost nothing per idle connection, because the fiber
  already exists. It needs one thing: a wait that ends when the socket
  becomes readable *or* when somebody posts. zio has every piece —
  `ev.NetPoll(.recv)`, `ev.Async.notify` (thread-safe), and
  `ev.Group.init(.race)`, which is exactly how `timedWaitForIo` already
  races a read against a timer. What it does not have is any exported way to
  park a fiber on a completion: `common.waitForIo` is `pub`, but
  `common.zig` is private to the package, and nothing reachable from
  `@import("zio")` takes a `*ev.Completion`.

  So this is blocked on one upstream line, not on a design. It is the right
  shape and it is where this should go.

  > **Resolved, and the premise here was wrong.**
  > [ADR 0038](./0038-a-broadcast-rings-a-bell-it-does-not-write.md) built it.
  > There *is* an exported way to park a fiber on a completion —
  > `zio.CompletionQueue`, public in the v0.17.0 this repo already pinned when
  > the paragraph above was written. The shape was right, the price was right,
  > and what stood in the way was a missing search rather than a missing line
  > upstream. It costs 4 bytes per idle connection, measured, which is to say
  > nothing: the machinery lives in the connection's own fiber frame.

## Consequences

- The Bulkhead grows one item: `spawn`, joined to the server's lifetime.
  Every future Engine has to supply it. A threaded Engine satisfies it with
  a thread and a join handle.

- **Broadcast WebSocket stays unbuilt, and the reason is now a number
  rather than a shrug.** ADR 0022 said "a project rather than a function";
  it is more precise than that — it is one measurement away from being
  affordable, and the measurement is upstream.

  > **It was one measurement away, and the measurement was not upstream.**
  > See ADR 0038: 8,777 bytes per idle connection before, 8,773 after.

- The OTel batching exporter and periodic jobs are unblocked, because they
  need `spawn` and none of the rest of this.

- `docs/roadmap.md` gains the upstream dependency as a standing item, with
  what it would be worth: 8,673 bytes per connection, and ADR 0018's
  invariant kept instead of doubled.

- The spike's `zfast.Channel` and `zfast.BroadcastChannel` are withdrawn.
  They were added to measure, and measuring is done. `zio.RwLock`, condition
  variables and channels go back to sitting there unexposed, which is where
  ADR 0011 left them and for the same reason.
