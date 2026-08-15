# Can a fiber wait on a socket read and a wakeup at once?

Roadmap #1 and #2, asked as a program. Broadcasting to a WebSocket a handler
does not hold needs the fiber that already owns a connection to be woken by
*somebody else* while it sits in a read. Without that, every connection that
can be broadcast to needs a second fiber, which is 8,673 bytes each — the
whole of [ADR 0018](../../docs/adr/0018-the-trade-budget-has-three-axes.md)'s
per-connection budget over again.

[zio#668](https://github.com/lalinsky/zio/issues/668) asked for `waitForIo` to
be exported for this. The answer was that `zio.CompletionQueue` already does
it — and it does: it is public in v0.17.0, which is the version zfast already
pins, along with `ev.NetPoll`, `ev.Async` and `ev.Completion`. So **the issue's
premise was wrong and nothing upstream needs to change to make the API
reachable.**

That left the real question, which was never the API: zio#667 is a live defect
where a waiter node is pushed onto a queue it is already linked into, and it
hangs `ReleaseFast` 17 runs in 20. `CompletionQueue` is built on the same
`SimpleQueue`, and every zfast connection is cancelled at shutdown.

## Run it

```
./run.sh [runs-per-mode]     # default 20
```

One scenario per process, so a hang is a process that has to be killed rather
than a line in a log. Three optimize modes, because zio#667 needed all three
to be understood — Debug and ReleaseSafe aborted on an assertion, ReleaseFast
had no such assertion and hung instead.

## What it does

One fiber owns a real accepted socket. It submits two completions to one
`CompletionQueue` — `NetPoll(.recv)` on the socket, and an `Async` — and loops
on `wait()`. A **plain OS thread**, deliberately outside the runtime, notifies
the `Async` five times and then writes a byte to the other end of the socket,
so both halves of the race are shown to reach the same parked fiber. Then,
with the fiber parked, `group.cancel()`.

## Result, 30 runs per cell

| mode | re-arm | result |
|---|---|---|
| Debug | reinit | **30/30 ok** |
| ReleaseSafe | reinit | **30/30 ok** |
| ReleaseFast | reinit | **30/30 ok** |
| Debug | plain | 30/30 **crash** |
| ReleaseSafe | plain | 30/30 **crash** |
| ReleaseFast | plain | 30/30 **crash** |

### The cancel path holds

No hangs and no aborts anywhere, in any mode. A fiber parked in
`CompletionQueue.wait()` and then cancelled comes back with `error.Canceled`,
which is what a cancelled connection should see, and `group.cancel()` — which
blocks until every task has actually finished — returns. **zio#667 does not
reach `CompletionQueue`**, and reading the code says why: `ownerCallback`
removes the node from `pending` before pushing it to `completed`, which is
exactly the discipline `BroadcastChannel` fails to keep.

Both wakeup sources reach the same parked fiber, and `Async.notify` works from
a thread that is not part of the runtime. That is the whole shape broadcast
needs.

### But re-submitting a completion crashes zio

`plain` is the obvious thing to write — hand the completion that just fired
straight back to `submit`, which is what a connection would do forever. It
crashes 90 runs in 90:

```
thread panic: attempt to use null value
  runtime.zig:1085  drainDispatched   const waiter: *Waiter = @ptrCast(@alignCast(c.userdata.?));
  runtime.zig:894   park
```

The cause is a two-line window. `CompletionQueue.submit` sets
`c.group.owner` and `c.group.owner_callback` and links the completion into its
`pending` list, then calls `loop.add`. For a completion that has already run,
`addInternal` sees `phase == .dead` and calls `Completion.reset()`
(`ev/loop.zig:831`), which clears **all three** (`ev/completion.zig:411-414`).
The queue's claim on the completion is wiped a line after it was made.

What comes out is a completion with no owner callback and no callback, which
`finishCompletion` treats as a task wake and hands to `dispatched` — so
`drainDispatched` reads `c.userdata.?`, finds null, and panics.

`CompletionQueue`'s own tests do not catch it because none of them re-submits:
every test uses a fresh timer, and "dynamic submit during iteration" submits a
*second* object rather than the first one again.

**The workaround is to build the completion again before re-submitting**, which
is what `reinit` does and what the 90/90 above was measured with. It is not
free: re-initialising an `Async` also clears its `pending` flag, so a notify
landing between the fire and the re-init is dropped. This spike keeps that race
out of its numbers by waiting for each wake to be counted before sending the
next — which is fine for a measurement and is **not** fine for a broadcast,
where the whole point is that anyone may notify at any time.

So the workaround is not a design. Either zio's `submit` re-establishes the
owner after `reset` (a two-line fix upstream, and the right place for it), or
zfast carries a lost-wakeup window it cannot close.

## A harness bug worth recording

The first matrix showed `reinit` failing 6 runs in 60 with `poll_wakes=0`,
which looked exactly like a lost wakeup in zio. It was not: the notifier
thread returned the instant it had written its byte, so `cancel()` raced the
poll completion and sometimes won. The notifier now waits for the wake to be
counted, and it is 90/90.

Worth writing down because the wrong conclusion was one commit away, and it
would have been filed upstream as a second zio defect.
