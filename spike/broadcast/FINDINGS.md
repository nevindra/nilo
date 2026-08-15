# Spike: writing to a socket this fiber does not own

Throwaway. This exists to answer the question ADR 0022 wrote down and left
open, so that the ADR after it is written from measurements rather than
from reasoning. Delete `spike/` once that ADR exists.

Everything below is measured against `spike/broadcast/main.zig`, driven by
`drive.py`, Debug build, 2 executors, loopback.

## The four shapes

| | who writes to socket B | what protects it |
|---|---|---|
| **A** | whichever fiber had something to say | the room's one lock, held across every write |
| **B** | same | the room's lock for a snapshot, then one lock per socket |
| **C** | a fiber that serves only B | a bounded outbox per connection, `trySend` |
| **D** | same | one `zio.BroadcastChannel` for the whole server, a read position per connection |

## 1. One client that stops reading kills the room — in A *and* in B

`drive.py slow`: eight clients, client 0 handed a socket and then never
read from it again, clients 2 and 3 healthy and only wanting to talk to
each other.

| | can two healthy clients still talk? |
|---|---|
| A | **never arrived** (5s timeout) |
| B | **never arrived** (5s timeout) |
| C | 0.2 ms typical, 35.6 ms worst |
| D | 0.2 ms typical, 35.2 ms worst |

**B failing is the finding.** Mode B is the fix everybody reaches for —
stop holding the big lock across I/O — and it buys exactly nothing, because
lock contention was never the problem. Client 2's own handler fiber does
the broadcast, so it walks the seats, reaches the wedged socket, and blocks
there. It never gets back to reading. Client 3 hears nothing, and neither
does anybody else.

> Any design in which fiber A writes to socket B ties A's liveness to B's
> readiness to read. Finer locking does not touch that. The write has to be
> performed by something whose stalling costs only B.

That single sentence is what this spike was for, and it rules out both of
the shapes ADR 0022 guessed at ("a per-socket outbox with its own lock, or
a mailbox the owning fiber drains") — the first outright, the second for
the reason in §4.

## 2. Mode C works, and drops messages to do it

`trySend` rather than `send`: a full outbox means that connection is not
keeping up, so its copy is thrown away rather than the speaker being held
up. The talker pushed all 2000 messages through without ever blocking.

The dropping is not theoretical. `drive.py talk`, 16 clients all reading,
outbox depth 32:

```
sent 800 messages, 5925 of an expected 12000 arrived
no torn frames
```

Half. With every client healthy. Depth is a real, user-visible dial, and
whatever ships has to say plainly that a broadcast is not a delivery.

No torn frames in any mode, at any depth — the per-socket lock held across
a whole frame is enough for that much.

## 3. The second fiber costs one whole connection budget

`drive.py idle`, 400 idle connections, RSS delta, repeated twice per mode
and byte-identical both times:

| | bytes per idle connection |
|---|---|
| A (one fiber) | 67,123 |
| C (two fibers) | 75,796 |
| **difference** | **8,673** |

The absolute numbers are a Debug build with a 16 KB message buffer on the
handler's stack and are *not* comparable to ADR 0018's 8,767 — only the
delta is, and both modes carry the identical `Member`, so the delta is the
writer fiber and nothing else.

**8,673 against a budget of 8,767.** The writer fiber costs, to within one
percent, the entire per-connection budget a second time. Add the outbox
storage — 8 KB at depth 32 × 256 bytes — and a connection that can be
broadcast to costs roughly three times one that cannot.

That is the number the ADR has to argue with. It does not obviously lose:
a process that broadcasts is a process holding far fewer connections than
`max_connections` allows. But it cannot be spent quietly, and it cannot be
spent on connections that never asked to hear from anyone.

## 4. Why C needs a second fiber and not just a mailbox

The cheap version — no new fiber, the existing handler drains its own
mailbox between messages — does not work with what zio has. `zio.select`
takes futures, and `zio.net` exposes none: there is no `asyncRecv` on a
`Stream`. A fiber sitting in `socket.receive()` cannot also be waiting on a
channel.

The alternatives are a read deadline short enough to poll the mailbox —
which at 50 ms and 10,000 connections is 200,000 wakeups a second to
deliver nothing — or a selectable socket read in the Engine. The second is
a real option and it belongs in the ADR, because it makes the mailbox shape
possible and the mailbox shape is the one that costs nothing per idle
connection.

## 5. Shutdown does not know about spawned work

Wedged client held open, `SIGTERM`:

```
info: zfast stopping: 8 request(s) still being answered, waiting up to 10000ms
warning: zfast stopped with 8 request(s) still unanswered after 10000ms — they were cut off.
```

There were sixteen fibers, not eight. `zio.spawn` is detached and outside
the accept loop's `Group`, so nothing spawned is counted by `Stop.in_flight`
or cancelled by `group.cancel()` — the writers only stopped because their
handlers' `defer` closed the outboxes on the way out.

It exited (11s — the full grace period; 1s with nobody wedged), so this is
not a hang. But a `spawn` that the shutdown path cannot see is a shutdown
message that lies, and anything spawned *outside* a request would have
nothing to close its outbox at all.

**Whatever `spawn` becomes has to be joinable by the thing that owns the
shutdown.** That is a Bulkhead question, not a zfast one.

## 6. The registry holds pointers into other fibers' stacks

`Member.socket` points at a local in the handler's frame. It is valid only
while that handler is inside its loop, so `leave` has to be exclusive with
anything walking the registry — and in mode C the handler additionally has
to close the outbox and *wait* for the writer before returning, or the
writer outlives the frame it writes into.

Mode C's `defer` does this in the right order and it is still the most
delicate thing in the file. A design that hands users a registry of live
sockets hands them this.

## 7. Mode D delivers better, costs the same idle, and crashes

`zio.BroadcastChannel` is the hand-rolled outbox of §2 written by someone
else: one ring, a read position per consumer, `send` that never blocks and
overwrites, `error.Lagged` for whoever fell behind. Mode D uses it.

**What it is better at.** Delivery, and by a lot — the same `talk` run that
mode C lost half of:

| | arrived, of 12,000 |
|---|---|
| C, 32-deep queue per connection | 5,925 |
| D, 256-deep ring for everybody | **12,000** |

And the send path gets much smaller. `wire.send(post)` is the whole
broadcast: no walking the seats, no room lock, no touching another
connection's memory at all. **The entire §6 hazard disappears from the send
path** — the registry is left holding nothing but a seat count.

**What it does not fix.** The memory, at idle. Repeated twice per mode,
byte-identical both times:

| | idle | under traffic |
|---|---|---|
| A | 66,959 | 70,226 |
| C | 75,633 | 96,113 |
| D | **75,633** | 92,017 |

Idle, C and D agree to the byte: the queue is never written, so it costs
nothing, and the 8,674 is the writer fiber and only the writer fiber. Under
traffic D saves 4,096 bytes per connection — exactly one page — which is
real but is not the 8 KB the data structure suggested.

> The shared ring is worth having for delivery and for the shape of the
> send path. It is not the answer to §3. **The second fiber is the cost,
> and nothing about the queue changes it.**

**What it broke.** Mode D crashes under connection churn — 3,600 clients
joining and leaving abruptly while the room is busy:

| | crashed |
|---|---|
| A (no spawned fiber at all) | 0 of 2 |
| C (fiber stopped by closing a channel it owns) | 0 of 4 |
| D (fiber stopped by cancelling it) | **2 of 4** |

Both crashes are the same assertion, inside zio:

```
thread 800482 panic: reached unreachable code
utils/simple_queue.zig:43   std.debug.assert(!item.in_list);   in push
sync/broadcast_channel.zig:72   self.wait_queue.push(&waiter.node);   in receive
spike/broadcast/main.zig:249    m.room.wire.receive(&m.consumer)      in drainWire
```

A waiter node being pushed onto the wait queue while it is already in a
list. Intermittent, so it is a race, and mode A and mode C ruling
themselves out across six runs says it is not churn on its own.

The difference mode D has is forced: **a shared ring has no per-consumer
close, so the only way to stop one reader is to cancel its fiber.** Mode C
closes a channel it owns and never cancels anything. So the suspect is
cancelling a fiber parked in `BroadcastChannel.receive`.

That is not a proof — the race is in zio's wait queue and this spike did
not go in and find it. But it is enough to say the ADR cannot lean on
`BroadcastChannel` until somebody does, because of what the check is: the
`in_list` field is `bool` under `runtime_safety` and `void` otherwise, so
in ReleaseFast there is no assertion, and the same race relinks a node
belonging to another list with nothing said.

## Not tried, and worth trying before the ADR

- **A selectable socket read in the Engine** (§4). Now the most valuable
  of these by a distance: it is the only route that removes the second
  fiber, and the second fiber is the whole of §3 — mode D just demonstrated
  that no amount of cleverness about the queue touches it.
- **Finding the zio race in §7**, or reproducing it in twenty lines away
  from zfast, so it can go upstream as a report rather than as a rumour.
- Whether the outbox should carry bytes or frames. Framing once for N
  receivers instead of N times is most of the CPU in a broadcast, and this
  spike framed per receiver without measuring the difference.

## Unrelated, found while running this

`zig build test` and `zig build test-all` failed twice under load, then
passed 8 times out of 8 when the machine was quiet. Reproduced with the
spike's changes stashed, on clean `main` at 0125848 — so it is not the
spike. Both test binaries pass standalone with exit 0 and all 339 tests.
Worth chasing separately; a suite that is red only sometimes is worse than
one that is red.
