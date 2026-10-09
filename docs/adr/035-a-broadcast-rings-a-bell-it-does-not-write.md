# A broadcast rings a bell; it does not write

**Status:** accepted
**Topic:** [websocket](../design/websocket.md)

Sending to a WebSocket a handler does not hold was the last thing on the
roadmap and the one thing nilo recorded as not-here twice. ADR 021 called it
"a project rather than a function". ADR 028 measured it, priced it at 8,673
bytes per connection, and left it unbuilt with the reason written down: the
shape that would cost nothing needed a wait that ends on either the socket
becoming readable *or* somebody posting, and zio exported no way to park a
fiber on a completion.

That last sentence was wrong, and finding out cost two spikes.

## What changed

**`zio.CompletionQueue` is public in the v0.17.0 nilo already pins.**
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
fn chat(c: *nilo.Ctx, room: *nilo.Room) !void {
    var socket = try c.upgrade();
    try room.join(&socket);
    defer room.leave(&socket);

    var buf: [16 * 1024]u8 = undefined;
    while (try socket.receive(&buf)) |message| {
        try room.say(message.kind, message.data);
    }
}
```

The loop is ADR 021's, unchanged, and that is the whole design goal. `receive`
grew a second thing to wait for and did not grow a second shape: a post that
arrives while this connection is quiet is written out by *this* fiber, inside
`receive`, before it goes back to waiting. A handler never sees a post and never
writes a branch for one. A `Room` arrives by type like any other service, so
none of this is a registration API, a callback, or a shape of its own.

### The speaker never writes to anybody else's socket

This is ADR 028's finding, and it is the reason the design looks the way it
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
017 calls a hard invariant. With the bytes inline, memory per idle connection
becomes a function of how big a message you allow — a four-slot mailbox with a
128-byte ceiling is 832 bytes per connection and a *128-byte ceiling*. A budget
you can state turns into a budget you have to multiply, and the API gets worse
at the same time. Here a seat costs the same whether the room is silent or
shouting, and a message can be as big as the receiving buffer.

> **The block holds the frame header too now** ([ADR 046](./046-a-message-is-copied-once-and-framed-once.md)). A server frame carries no mask and nothing else that differs by recipient, so a thousand connections were building a thousand byte-identical headers for the same post. It is built once, here, and delivery is one `writeAll` of one slice — with one flush per burst rather than one per post.
>
> **And `say` no longer walks the seats it was sized for.** `roll` keeps the taken ones dense at the front, so a room of a thousand seats holding three visits three: 494ns to 161ns, and `join` stops being a scan as well. It costs 8 bytes a seat — four for the roll, four for the seat's place on it — which is per *seat* rather than per connection, so the "4 measured bytes per idle connection" below is unchanged.

### The policy is named at the room, which amends ADR 019

[ADR 019](./019-a-request-that-lasts-is-still-one-request.md) refused this
outright:

> A queue with a policy — drop oldest, drop newest, disconnect — is what a
> pub/sub layer wants, and nilo is not one.

A `Room` is one, so the refusal is amended rather than quietly ignored. What
survives of it is the part that was actually right: **nilo does not have a
queue with a policy; a Room does.** The policy is `Full.drop_oldest` (the
default, and what a chat wants — a client that fell behind wants to catch up at
the front) or `Full.drop_newest`. What it is not is a hidden default in the
connection layer, which is what ADR 019 was refusing.

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

### A socket sits in any number of rooms, and every seat left taken is given up for it

The era keeps a stale ticket from misdelivering; it does not free the seat.
A forgotten `leave` left the seat taken with its bell in the connection's
frame, and the next `say` rang that bell after the frame had returned: the
use-after-free [ADR 082](./082-a-cleanup-path-is-not-cancellable.md) closed for
a cancelled `leave`, reached by not calling it at all. So when the loop
returns, nilo gives up every seat the socket still holds.

**The chain of rooms lives in the seats, not on the socket.** A socket holds one `Seating`, the first room and its ticket, and each seat holds the next. `join` puts the new seat at the front, `leave` finds its room in the chain and points the link before it past it, and `receive` drains every seat on the way past with one flush for the whole burst. Joining the room a socket is already in does nothing, and `leave` on a room it is not in does nothing, as before.

Nothing but the socket's own fiber reads or writes the chain: it joins, it leaves, it drains, and the connection loop gives up what is left from the same fiber. A speaker touches a seat's ring and its bell and never `next`, so the chain has no lock of its own and no seat's lock is held while walking it.

`Ticket.index` became a `u32`, which the roll already was, so a `Seating` is sixteen bytes. The socket's two fields for one room were thirty-two.

### An event stream sits in a room beside the sockets

A seat is a bell and a ring, and nothing in it is a WebSocket's, so an event stream takes one the same way ([ADR 227](./227-an-event-stream-fed-by-rooms-waits-where-a-connection-waits.md)): `c.eventsFrom(room, .{})` seats the stream, and the connection loop drains its seats as `receive` drains a socket's. What differs is what a post becomes on the way out. A text post is an event's `data`, `room.event` adds the `event:` and `id:` a stream sends and a socket has nowhere to put, and a binary post is counted in `missed` rather than queued, because a stream's seat is marked text-only when it is taken.

### A Room can keep what it said, and can be lent to a key

Two things a Room gained after this ADR, each decided in its own. A Room made with `history` keeps its latest text posts for an event stream that comes back with `Last-Event-ID`, which is the one case where a post outlives every seat that took it ([ADR 229](./229-a-room-that-keeps-history-catches-a-returning-stream-up.md)). And a Room need not be made by the application: `nilo.Rooms` lends Rooms made up front to keys the application invents, one user's tabs under `"user:42"`, and a Room it lends carries a pointer back so the last seat given up returns it ([ADR 228](./228-a-room-for-a-key-is-lent-from-a-pool.md)).

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

**A second room costs a seat in it and nothing on the connection.** Measured when the chain moved into the seats, both sides built the same afternoon and run interleaved: idle WebSockets at 5,691 to 5,695 bytes before and 5,691 to 5,693 after, one room 5,691 to 5,693 before and 5,700 to 5,704 after, and two rooms 5,693, a spread of 13 bytes across all of it. The cost is in the room, up front: +370 kB of baseline for 24,000 seats, the sixteen bytes a seat grew by ([`bench/result/http.md`](../../bench/result/http.md#a-second-room-costs-a-seat-and-nothing-on-the-connection)).

**Throughput and p99: unmoved.** `wrk -t4 -c64`, two 15-second runs each:
1.110M/1.105M req/s before, 1.108M/1.102M after, with p99 varying more between
repeats of the same build than between builds. The allocations-per-request test
in `http/app.zig` passes unchanged — an ordinary request never touches any of
this.

## What was rejected

- **One room per socket, and `error.AlreadySeated` for a second.** What this shipped with. A socket held one ticket and `receive` drained one seat, and joining a second room used to overwrite the ticket, so `leave` on the first gave up a seat by an index into the wrong room and left the real one taken for good. Refusing the second join closed that, and made a lobby plus a room of one user's tabs impossible on one connection, which is the shape every notification feed wants. The chain above replaced it.
- **A fixed array of tickets on the socket**, four rooms say. The obvious way to hold more than one, and it charges every WebSocket for the rooms it might join: about 72 bytes more on each connection, including the ones that echo and never join anything, in the frame ADR 062 keeps under a page. It also puts a ceiling on rooms that says nothing about the application. The chain charges the seat instead, once, when the room is made.
- **A second fiber per connection to do the writing.** ADR 028's measurement,
  8,673 bytes against a budget of 8,767. It is the shape that works without any
  of the above, and it doubles the cost of every connection whether or not the
  application broadcasts.
- **A lock per socket, held by the speaker.** ADR 028 measured it: two healthy
  clients never hear each other once one client stops reading. Finer locking
  buys nothing, because contention was never the problem.
- **`zio.BroadcastChannel`.** Better delivery and a much smaller send path, and
  it aborts (or in `ReleaseFast` deadlocks) when a fiber parked in `receive` is
  cancelled, which every nilo connection is at shutdown. Reported as zio#667
  and fixed upstream in `ab6873eb`, which v0.18.0 carries; the fix does not
  change the answer, because a shared ring has no per-consumer close, which
  is what forces the cancel in the first place.
- **Waiting for zio#673 to land.** The fix belonged upstream and was in
  flight. Nothing here needed it: rebuilding only the completion was correct
  on v0.17.0 and stayed correct after, because it left `owner` null and
  satisfied the assert zio#674 adds. *Amended when the pin moved to v0.18.0:*
  zio#674 is in that release, the rebuild is gone from `Wake.wait`, and the
  spike's `plain` mode — the same object handed straight back to `submit`,
  which crashed 90 in 90 before — holds 180 runs in 180 across three optimize
  modes, `--window` included.

## Consequences

- **The Bulkhead grows one item**: `Waker.wait`/`Waker.post`. Every future
  Engine has to supply it. An Engine that waits on sockets can already wait on
  two things — it has to, to wait with a deadline at all.
- **`Ctx` carries a `Waker`**, defaulting to one with no Engine behind it, which
  answers "go and read" to everything. That default is what keeps the whole HTTP
  suite runnable against in-memory buffers with no server.
- **`receive` parks differently.** It only waits when its read buffer is empty:
  a reader holding a buffered frame is readable whatever the socket thinks.
  While it still holds its buffers, its 200 ms peek, the wait receives into
  them rather than polling, so the frame that ends it is already buffered;
  the wait after the buffers have gone back is the poll and the bell
  ([ADR 284](./284-a-connection-in-conversation-waits-by-receiving.md)).
- **ADR 019's refusal is amended**, ADR 021's "the thing this does not do" no
  longer describes nilo, and ADR 028's "blocked on one upstream line" is
  resolved. All three carry a note pointing here.
- **`permessage-deflate` is still not here**, and neither is any deadline on a
  quiet WebSocket. Both are ADR 021's, both unchanged.
