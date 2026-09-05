# A cleanup path is not cancellable

`Room.leave` took two locks and gave up on both the same way:

```zig
self.roster.lock() catch return;
…
seat.lock.lock() catch return;
```

The only error either can return is `Canceled`, which is what a fiber gets when
the server is shutting down. Both paths returned before `seat.taken = false`, so
the seat was never released and `seat.waker` still pointed into the `Socket` of
a handler on its way out. A later `say` walked the roll, found that seat still
on the taken half, pushed a post into its ring and rang a bell whose fiber had
ended.

**`nilo.Mutex.lockUncancelable` is added to the Bulkhead, and `Room.leave` takes
both of its locks with it.**

## The window, stated exactly

`zio.Mutex.lock` tries uncontended first and only then checks cancellation, so
this needs a broadcast in flight at the moment the connection is cancelled. It
is not the ordinary shutdown, where nothing is contended and `leave` completes
normally. It is narrow, and it is a use-after-free.

## Why not handle the error instead

There are two other things `leave` could do with a `Canceled` and both are
worse. Carrying on without the lock is a data race with the `say` that is
holding it. Propagating it means `leave` returns an error, which breaks
`defer room.leave(socket)` — and `defer` is the whole shape this API is written
around, in a function whose doc says it is safe to call twice and safe on a
socket that never joined.

**A cleanup path has nowhere to put a failure**, which is the general form and
is why this is an ADR rather than a bug fix. The Bulkhead now says so: taking a
lock can be refused, so the Engine has to offer a way of taking it that cannot
be.

`zio.Mutex.lockUncancelable` was already in the pinned v0.17.0, one file over,
written for exactly this — "cancellation requests are ignored during the lock
acquisition". Only the Bulkhead did not expose it. That is the check
[ADR 0063](./0063-a-handlers-stack-is-per-connection.md) taught this repository
to run before writing down a blocker, and it came back the same way it did
there.

## What makes it safe to make a section uninterruptible

Nothing can interrupt it, so the rule is that the section has to be short and
must not itself wait. Giving a seat up is a handful of stores and a drain of at
most `backlog` posts, and it takes no third lock. The cancellation is not lost
either — the Engine still holds the request, and the next call that can fail
will.

It is deliberately not offered as the easy default. `lock` stays the one to
reach for; this is for the path that has already decided it is leaving.

## While there: `Seat.dropped`

`Room.missed` read it with no lock and `put` wrote it under the seat's — the one
field in the file read outside the lock that guards it. Nothing tears on a
64-bit load, so this was a latent inconsistency rather than a bug.

It is now `std.atomic.Value(u64)`, written under the lock and read with a plain
monotonic load, rather than `missed` taking the lock. The doc on the field says
a number a handler can read beats a line in a log nobody is watching, and
putting that handler behind a broadcast would cost more than the number is
worth. The atomic says in the type what the comment used to say in prose.

## What it costs

Nothing. `lockUncancelable` is the same fast path as `lock` when the lock is
free, which on this path it almost always is, and it carries the same watchdog
bracket so a contended one is still not reported as a blocking handler
([ADR 0034](./0034-the-thing-a-handler-holds-is-watched-at-run-time.md)).
`dropped` is the same eight bytes it was.

## What is not tested

There is no test for the window. Reproducing it needs a broadcast in flight and
a cancellation landing between two instructions, and the suite has no way to
drive that — `bench/ws_server.zig` does not even use a Room. So this rests on
reading, which is worth saying out loud rather than implying by silence: the
change is small and the reasoning is above, and the thing that would raise
confidence is a harness the roadmap already asks for on another entry.
