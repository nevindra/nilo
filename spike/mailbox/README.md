# What does a connection you can broadcast to cost?

[ADR 0029](../../docs/adr/0029-a-spawned-fiber-belongs-to-the-server.md) killed
the only broadcast shape that worked at the time with one number: a second
fiber per connection, **8,673 bytes**, against a whole-connection budget of
8,767 in [ADR 0018](../../docs/adr/0018-the-trade-budget-has-three-axes.md).
Doubling the per-connection cost of every connection, for a feature most
applications do not use, was not a trade to make on a user's behalf.

That ADR also named the shape that would cost nothing extra — a mailbox the
*owning* fiber drains, adding no fiber at all — and recorded it as unreachable,
because zio exported no way to park a fiber on a completion.

[`spike/completion_queue/`](../completion_queue/) settled that it is reachable:
`zio.CompletionQueue` is public in the pinned v0.17.0, its cancel path holds,
and re-arming across a broadcast is lossless as long as only the completion is
rebuilt. So the question came back to the one ADR 0029 asked, and it is a
number again.

## Run it

```
./run.sh [connections] [repeats] [slot-counts]     # default 4000, 2, "0 4 16 64"
```

Two processes. The server accepts N connections, spawns exactly one fiber for
each, parks it, and prints `ready` once every fiber is parked — not merely once
every socket is accepted, because a fiber still on its way to `wait()` has not
paid for its completions yet. The RSS is then read from outside, from
`/proc/<pid>/status`, because a process measuring itself has to allocate to do
it.

**What is measured is the difference and nothing else.** Both modes accept the
same connections, spawn one fiber each, and park forever. `baseline` parks in a
read, which is what an idle WebSocket connection does today; `mailbox` parks on
a `CompletionQueue` holding the socket poll and an `Async`, and carries the ring
a broadcast would post into. Fiber stacks, executors, backlog and the runtime
are identical, so they cancel.

## Result, 4,000 idle connections

| optimize | slots | `@sizeOf` | baseline kB | mailbox kB | delta kB | bytes/connection |
|---|---|---|---|---|---|---|
| ReleaseFast | 0 | 320 | 21,552 | 23,552 | 2,000 | **512** |
| ReleaseFast | 4 | 384 | 21,556 | 23,556 | 2,000 | **512** |
| ReleaseFast | 16 | 576 | 21,552 | 25,552 | 4,000 | **1,024** |
| ReleaseFast | 64 | 1,344 | 21,556 | 29,552 | 7,996 | **2,046** |
| ReleaseSafe | 16 | 600 | 21,524 | 25,520 | 3,996 | **1,022** |

Repeats agree to the byte in every row but the two largest, where they differ
by 2 bytes per connection out of 2,046. The two optimize modes agree to within
3 bytes. ReleaseSafe's struct is 24 bytes bigger because `Completion.group`
carries an `in_list` flag under `runtime_safety`, and there are three
completions in the struct.

## The number is a power of two, and that is the finding

Every measured cost is exactly the next power of two at or above `@sizeOf`.
320 and 384 both cost 512; 576 costs 1,024; 1,344 costs 2,046.

**What is being paid is the allocator's size class, not the struct.** The spike
gives each connection its own allocation, which is the obvious way to write it
and the wrong way to ship it. Folded into the connection state zfast already
allocates, there is no second allocation and no rounding, and the cost is the
struct:

```
320 bytes  the machinery — CompletionQueue, Async, NetPoll, and the ring's
           head and tail
 16 bytes  per mailbox slot, a post being a pointer and a length
```

So a four-slot mailbox held inline is **384 bytes**, and the 512 in the table is
128 bytes of allocator that a different call site does not spend.

## Against the budget that rejected the last shape

| shape | bytes per idle connection | of ADR 0018's 8,767 |
|---|---|---|
| a second fiber per connection (ADR 0029, rejected) | 8,673 | 98.9% |
| mailbox, own allocation, 16 slots | 1,024 | 11.7% |
| mailbox, own allocation, 4 slots | 512 | 5.8% |
| **mailbox, inline in the connection, 4 slots** | **384** | **4.4%** |
| mailbox, inline in the connection, 16 slots | 576 | 6.6% |

The fiber was the price, and this shape does not pay it. What is left is small
enough to argue about rather than small enough to ignore, which is the right
size for a number that goes in an ADR.

## What this does not measure

- **zfast's connection, rather than a zio server's.** The delta is the
  machinery's marginal cost, and that is what transfers; the per-connection
  total for a real zfast server has to be re-measured on the real server when
  the feature lands, the way ADR 0029 measured the fiber.
- **A mailbox with anything in it.** The ring is written so its pages are
  resident, but the posts it would point at are somebody else's memory, and
  whose is exactly the question this spike does not answer. A post copied out
  of a request arena has to live somewhere, and that somewhere is not counted
  here.
- **Any policy.** A full mailbox has to do something — drop oldest, drop
  newest, disconnect — and [ADR 0020](../../docs/adr/0020-a-request-that-lasts-is-still-one-request.md)
  refuses to have such a queue at all. That refusal needs amending before any
  of this ships, and the amendment is a decision rather than a measurement.
