# A broadcast rings a bell; it does not write

Sending to a WebSocket a handler does not hold was the last thing on the
roadmap and the one thing zfast recorded as not-here twice. ADR 0022 called it
"a project rather than a function". ADR 0029 measured it, priced it at 8,673
bytes per connection, and left it unbuilt with the reason written down: the
shape that would cost nothing needed a wait that ends on either the socket
becoming readable *or* somebody posting, and zio exported no way to park a
fiber on a completion.

That last sentence was wrong, and finding out cost two spikes.

## What changed

**`zio.CompletionQueue` is public in the v0.17.0 zfast already pins.**
`spike/completion_queue/` parked a fiber on a `NetPoll(.recv)` and an `Async`
at once, woke it from a plain OS thread, and cancelled it mid-park: clean 30
runs in 30 in Debug, ReleaseSafe and ReleaseFast alike. The worry that it would
inherit [zio#667](https://github.com/lalinsky/zio/issues/667) was settled by
running it — `ownerCallback` removes a node from `pending` before pushing it to
`completed`, which is the discipline `BroadcastChannel` fails to keep.

**A second defect was found on the way, and it does not block us.** Handing a
completion that has already fired straight back to `submit` crashes zio 90 runs
in 90 ([zio#673](https://github.com/lalinsky/zio/issues/673), fix in flight as
zio#674). Rebuilding it first clears that, and the spike's first pass concluded
the rebuild costs a wakeup — `Async.init()` clears the `pending` flag that holds
a notify landing in the re-arm window.

That conclusion was also wrong. There are two ways to rebuild:

| | | `pending` |
|---|---|---|
| `wake = Async.init()` | the whole handle | thrown away with it |
| `wake.c = .init(.async)` | only the completion | untouched |

`pending` is a field of `Async`; the phase that triggers the crash is a field of
`Completion`. Rebuilding only the completion dodges the crash *and* keeps the
flag, so the next `submit` finds it in `checkAndSetAsyncResult` and completes on
the spot — the wake arrives late rather than never. Held to a number in the
spike's `--window` mode, where the fiber holds the re-arm window open and the
post is placed inside it deliberately: rebuilding the whole handle loses the
post 30 runs in 30, rebuilding only the completion keeps it 30 in 30, identical
in all three optimize modes. 630 runs across the matrix, no hangs, no flakes.

Worth recording that the obvious hammer does not reach this. Firing five posts
as fast as a thread can go — which is what a broadcast under load looks like —
passes with *either* rebuild, because all five land before the fiber is
scheduled once. A spike that only ran that would have shipped the lossy one.

## What was decided

**A `Room`: a service you provide, that connections join, and that says things
to all of them.**

```zig
fn chat(c: *zfast.Ctx, room: *zfast.Room) !void {
    var socket = try c.upgrade();
    try room.join(&socket);
    defer room.leave(&socket);

    var buf: [16 * 1024]u8 = undefined;
    while (try socket.receive(&buf)) |message| {
        try room.say(message.kind, message.data);
    }
}
```

The loop is ADR 0022's, unchanged, and that is the whole design goal. `receive`
grew a second thing to wait for and did not grow a second shape: a post that
arrives while this connection is quiet is written out by *this* fiber, inside
`receive`, before it goes back to waiting. A handler never sees a post and never
writes a branch for one. A `Room` arrives by type like any other service, so
none of this is a registration API, a callback, or a shape of its own.

### The speaker never writes to anybody else's socket

This is ADR 0029's finding, and it is the reason the design looks the way it
does. When the broadcast is performed by the speaker's own fiber, that fiber
walks the connections, reaches the first client that has stopped reading, and
blocks there — and everybody else's messages stop because one client stopped. A
lock per socket does not touch it. It was never contention.

> Any design in which fiber A writes to socket B ties A's liveness to B's
> readiness to read.

So `say` copies a pointer into each seat and rings a bell. The writing is done
by the fiber that already serves that connection, whose stalling costs that
connection alone. A client that goes quiet mid-frame still parks its own fiber
in a read and still stops draining its own seat — and the blast radius is its
own backlog, which fills and then drops under the policy below.

### A post is one allocation, refcounted, not one copy per recipient

`say` allocates the header and the bytes as one block, hands each seat a
pointer, and whichever seat drains it last frees it.

The alternative was an inline copy into every seat: no refcount, no allocator,
no lifetime question at all, and rejected for what it does to the number ADR
0018 calls a hard invariant. With the bytes inline, memory per idle connection
becomes a function of how big a message you allow — a four-slot mailbox with a
128-byte ceiling is 832 bytes per connection and a *128-byte ceiling*. A budget
you can state turns into a budget you have to multiply, and the API gets worse
at the same time. Here a seat costs the same whether the room is silent or
shouting, and a message can be as big as the receiving buffer.

### The policy is named at the room, which amends ADR 0020

[ADR 0020](./0020-a-request-that-lasts-is-still-one-request.md) refused this
outright:

> A queue with a policy — drop oldest, drop newest, disconnect — is what a
> pub/sub layer wants, and zfast is not one.

A `Room` is one, so the refusal is amended rather than quietly ignored. What
survives of it is the part that was actually right: **zfast does not have a
queue with a policy; a Room does.** The policy is `Full.drop_oldest` (the
default, and what a chat wants — a client that fell behind wants to catch up at
the front) or `Full.drop_newest`. What it is not is a hidden default in the
connection layer, which is what ADR 0020 was refusing.

Disconnecting on a full backlog is deliberately not offered. A server that
closes connections because it was slow is a server whose worst behaviour arrives
exactly when it is busiest.

A seat also counts what it dropped, and `room.missed(&socket)` reports it. A
number a handler can read beats a line in a log nobody is watching.

### A seat has an era, so a forgotten `defer` cannot misdeliver

`join` hands back a `Ticket` of index and era, and the era is bumped every time
a seat is taken. A stale ticket from a connection that has already left cannot
be mistaken for the one now sitting there. Without it a handler that lost track
of its `leave` would have its posts delivered to whoever arrived next, which is
the kind of bug that shows up as one user seeing another's messages.

`leave` is safe twice and safe on a socket that never joined, so
`defer room.leave(&socket)` is correct on every path out of a handler,
including the ones that failed before joining.

### A socket with no Engine is seated anyway

A `Socket` over a fixed buffer — what a test has — has nothing that can ring
its bell. It is seated regardless, because `receive` drains its seat before it
reads either way, so posts still arrive and the whole feature is testable with
no server. A feature only reachable through a real socket is a feature tested by
hand.

## What it costs

Measured, not reasoned about.

**Per idle connection: nothing.** 2,000 idle connections against the benchmark
server, `ReleaseFast`, before and after this change:

| | bytes per idle connection |
|---|---|
| before | 8,777 |
| after | 8,773 |

The `Wake` is 320 bytes in the connection's own fiber frame — pages already
mapped — rather than an allocation of its own. `spike/mailbox/` measured why
that distinction matters: given its own allocation the cost is not the struct
but the next power of two above it, 320 measured as 512 and 576 as 1,024, every
row exact.

**A room costs what it says it costs**, up front: `seats × backlog` pointers
plus a seat each, 1,024 seats and a backlog of 4 by default. A post costs one
allocation for as long as the slowest seat holds it.

**Throughput and p99: unmoved.** `wrk -t4 -c64`, two 15-second runs each:
1.110M/1.105M req/s before, 1.108M/1.102M after, with p99 varying more between
repeats of the same build than between builds. The allocations-per-request test
in `src/app.zig` passes unchanged — an ordinary request never touches any of
this.

## What was rejected

- **A second fiber per connection to do the writing.** ADR 0029's measurement,
  8,673 bytes against a budget of 8,767. It is the shape that works without any
  of the above, and it doubles the cost of every connection whether or not the
  application broadcasts.
- **A lock per socket, held by the speaker.** ADR 0029 measured it: two healthy
  clients never hear each other once one client stops reading. Finer locking
  buys nothing, because contention was never the problem.
- **`zio.BroadcastChannel`.** Better delivery and a much smaller send path, and
  it aborts (or in `ReleaseFast` deadlocks) when a fiber parked in `receive` is
  cancelled, which every zfast connection is at shutdown. Reported as zio#667
  and fixed upstream in `ab6873eb`; still not in a release, and a shared ring
  has no per-consumer close, which is what forces the cancel in the first place.
- **Waiting for zio#673 to land.** The fix belongs upstream and is in flight.
  Nothing here needs it: rebuilding only the completion is correct on the pinned
  v0.17.0 and stays correct after, because it leaves `owner` null and satisfies
  the assert zio#674 adds.

## Consequences

- **The Bulkhead grows one item**: `Waker.wait`/`Waker.post`. Every future
  Engine has to supply it. An Engine that waits on sockets can already wait on
  two things — it has to, to wait with a deadline at all.
- **`Ctx` carries a `Waker`**, defaulting to one with no Engine behind it, which
  answers "go and read" to everything. That default is what keeps the whole HTTP
  suite runnable against in-memory buffers with no server.
- **`receive` parks differently.** It only waits when its read buffer is empty:
  a reader holding a buffered frame is readable whatever the socket thinks.
- **ADR 0020's refusal is amended**, ADR 0022's "the thing this does not do" no
  longer describes zfast, and ADR 0029's "blocked on one upstream line" is
  resolved. All three carry a note pointing here.
- **`permessage-deflate` is still not here**, and neither is any deadline on a
  quiet WebSocket. Both are ADR 0022's, both unchanged.
