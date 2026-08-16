# Can a fiber wait on a socket read and a wakeup at once?

Roadmap #1 and #2, asked as a program. Broadcasting to a WebSocket a handler
does not hold needs the fiber that already owns a connection to be woken by
*somebody else* while it sits in a read. Without that, every connection that
can be broadcast to needs a second fiber, which is 8,673 bytes each — the
whole of [ADR 0018](../../docs/adr/0018-the-trade-budget-has-three-axes.md)'s
per-connection budget over again.

[zio#668](https://github.com/lalinsky/zio/issues/668) asked for `waitForIo` to
be exported for this. The answer was that `zio.CompletionQueue` already does
it — and it does: it is public in v0.17.0, which is the version nilo already
pins, along with `ev.NetPoll`, `ev.Async` and `ev.Completion`. So **the issue's
premise was wrong and nothing upstream needs to change to make the API
reachable.**

That left two questions, asked in two passes.

1. **Does the cancel path hold?** [zio#667](https://github.com/lalinsky/zio/issues/667)
   is a defect where a waiter node is pushed onto a queue it is already linked
   into, hanging `ReleaseFast` 17 runs in 20. `CompletionQueue` is built on the
   same `SimpleQueue`, and every nilo connection is cancelled at shutdown.
2. **Can a connection re-arm forever without dropping a message?** A broadcast
   wakes the same connection over and over, so a wakeup that works once is no
   use. This is where [zio#673](https://github.com/lalinsky/zio/issues/673)
   lives, and where the first pass stopped with the wrong conclusion.

## Run it

```
./run.sh [runs-per-cell]     # default 20
./zig-out/bin/cq-spike [plain|reinit|recomplete] [--paced|--blind|--window]
```

One scenario per process, so a hang is a process that has to be killed rather
than a line in a log. Three optimize modes, because zio#667 needed all three
to be understood — Debug and ReleaseSafe aborted on an assertion, ReleaseFast
had no such assertion and hung instead.

## What it does

One fiber owns a real accepted socket. It submits two completions to one
`CompletionQueue` — `NetPoll(.recv)` on the socket, and an `Async` — and loops
on `wait()`. A **plain OS thread**, deliberately outside the runtime, posts to
a mailbox and notifies the `Async`, then writes a byte to the other end of the
socket, so both halves of the race are shown to reach the same parked fiber.
Then, with the fiber parked, `group.cancel()`.

The mailbox is two counters, `posted` and `drained`. That is deliberate:
counting *wakes* cannot answer the question, because `Async.notify` is
`pending.swap(1)` and two posts arriving before the fiber re-arms correctly
produce one wake. Coalescing is fine — the payload is in the mailbox, not in
the wake. What a broadcast cannot survive is the fiber parking with
`posted > drained`. So the assertion is `drained == posted`.

`--paced`, `--blind` and `--window` differ only in how hard the notifier leans
on the window between the fiber draining its mailbox and re-arming its `Async`.

## Result, 30 runs per cell, identical in Debug, ReleaseSafe and ReleaseFast

| re-arm | `--paced` | `--blind` | `--window` |
|---|---|---|---|
| `plain` | 30/30 **crash** | — | — |
| `reinit` | 30/30 ok | 30/30 ok | 30/30 **wrong** |
| `recomplete` | 30/30 ok | 30/30 ok | **30/30 ok** |

630 runs. No hangs, no aborts, no flakes, and every cell reads the same in all
three optimize modes.

### The cancel path holds

A fiber parked in `CompletionQueue.wait()` and then cancelled comes back with
`error.Canceled`, which is what a cancelled connection should see, and
`group.cancel()` — which blocks until every task has actually finished —
returns. **zio#667 does not reach `CompletionQueue`**, and reading the code
says why: `ownerCallback` removes the node from `pending` before pushing it to
`completed`, which is exactly the discipline `BroadcastChannel` fails to keep.

Both wakeup sources reach the same parked fiber, and `Async.notify` works from
a thread that is not part of the runtime. That is the whole shape broadcast
needs.

### Re-submitting a completion crashes zio

`plain` is the obvious thing to write — hand the completion that just fired
straight back to `submit`, which is what a connection would do forever. It
crashes 90 runs in 90:

```
thread panic: attempt to use null value
  runtime.zig:1085  drainDispatched   const waiter: *Waiter = @ptrCast(@alignCast(c.userdata.?));
  runtime.zig:894   park
```

`CompletionQueue.submit` sets `c.group.owner` and `c.group.owner_callback` and
links the completion into its `pending` list, then calls `loop.add`. For a
completion that has already run, `addInternal` sees `phase == .dead` and calls
`Completion.reset()` (`ev/loop.zig:831`), which clears **all three**
(`ev/completion.zig:411-414`). The queue's claim on the completion is wiped a
line after it was made.

What comes out is a completion with no owner callback and no callback, which
`finishCompletion` treats as a task wake and hands to `dispatched` — so
`drainDispatched` reads `c.userdata.?`, finds null, and panics.

`CompletionQueue`'s own tests do not catch it because none of them re-submits:
every test uses a fresh timer, and "dynamic submit during iteration" submits a
*second* object rather than the first one again.

Filed upstream as [zio#673](https://github.com/lalinsky/zio/issues/673) — by
lalinsky's own automation, found independently while documenting
`CompletionQueue`. Still open, no comments, no fix.

### The workaround is free after all, and the first pass said otherwise

Rebuilding the completion before re-submitting clears the crash, because a
completion in phase `.new` never reaches the `reset()` that wipes the queue's
claim on it. **The first pass then concluded that this costs a wakeup, and
recorded that broadcast was therefore blocked upstream. That was wrong.**

There are two ways to rebuild, and they are not the same:

| | what it does | `pending` |
|---|---|---|
| `reinit` | `wake = Async.init()` | thrown away with the rest of the handle |
| `recomplete` | `wake.c = .init(.async)` | untouched |

`pending` is a field of `Async`, not of `Completion` (`ev/completion.zig:571-574`),
and `Completion.reset` never had any business with it either way. So a notify
landing in the re-arm window sets a flag on a handle that keeps it, and the
next `submit` walks straight into `checkAndSetAsyncResult`
(`ev/loop.zig:872-883`), which swaps the flag back down and completes the
handle on the spot. **The wake is delivered late rather than lost.**

The `--window` column is that sentence held to a number. `reinit` loses the
post 30 times in 30; `recomplete` keeps it 30 times in 30; and it reads the
same in all three optimize modes.

> **Broadcast is not waiting on zio#673.** The fix is still the right one and
> still belongs upstream — `reset` clearing `group` corrupts anyone who links
> a completion before arming it, silently in ReleaseFast — but nilo does not
> have to sit still until it lands.

The one thing to say out loud: assigning a whole `Completion` is a plain store
across `c.loop`, which `Async.notify` reads atomically
(`ev/completion.zig:319-325`). One aligned word, so the read returns either the
old loop — a `wakeAsync` nobody needed, which is harmless — or null, which is
the case `submit` already covers. Benign on any real target, and not blessed by
the memory model.

### Why `--blind` is kept even though it decides nothing

`--blind` fires five posts as fast as a thread can go, which is what a
broadcast under load actually looks like. It does **not** separate `reinit`
from `recomplete`: the summary reads `async_wakes=1/5 drained=5/5` and both
pass, because all five notifies land before the fiber is scheduled even once.

That is a fact about the window worth keeping. It is nanoseconds wide, the
obvious hammer does not reach it, and a spike that only ran `--blind` would
have shipped `reinit` and met the lost wakeup in production instead. `--window`
does not race for it — the fiber holds the window open and the post is placed
inside it — because a mechanism made observable beats a race hopefully hit.

## A harness bug worth recording

The first matrix showed `reinit` failing 6 runs in 60 with `poll_wakes=0`,
which looked exactly like a lost wakeup in zio. It was not: the notifier
thread returned the instant it had written its byte, so `cancel()` raced the
poll completion and sometimes won. The notifier now waits for the wake to be
counted, and it is 90/90.

Worth writing down because the wrong conclusion was one commit away, and it
would have been filed upstream as a second zio defect.
