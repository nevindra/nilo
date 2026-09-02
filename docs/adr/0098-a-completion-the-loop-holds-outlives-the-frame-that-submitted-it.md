# A completion the loop holds outlives the frame that submitted it

`Wake` is the Engine's half of a WebSocket's parking: a `CompletionQueue`, an
`Async` to be posted on and a `NetPoll` on the connection's socket, all three
living in the connection fiber's own frame so that parking costs pages that are
already mapped rather than an allocation
([ADR 0071](./0071-where-a-connection-waits-is-what-it-costs.md) is why that
frame is worth caring about). It had `init`, `wait` and `post`, and no way to
say it was finished.

**It has a `deinit` now, and the fiber does not return until the loop has given
the completions back.**

## What was wrong

`CompletionQueue.submit` does two things: it puts the completion on the queue's
own pending list, and it hands the pointer to `getCurrentExecutor().loop`. The
loop keeps it until the operation completes or is cancelled. Neither half is
undone by the queue going out of scope, because a struct going out of scope is
not an event anybody is told about.

So an ordinary WebSocket ended like this. The client sends its close frame, the
handler returns, `Conn.run` returns, and the fiber's frame — `cq`, `wake.c`,
`poll.c`, all of it — is handed back. `wake.c` was still submitted, because
`wait` re-submits it after every post and nothing ever takes it out. `poll.c`
was still submitted whenever the last wait ended in anything but `.readable`.
The loop was still holding both, and what it does with a completion is write to
it and call `c.group.owner_callback` — which is a pointer into a frame that has
been reused.

`bench/shutdown.py` at 24 connections a run: **23 of 25 SIGTERMs never came
back** before this, **0 of 25 after**. At 6 connections, 4 of 10 before and 0 of
20 after. The `--http` control is 0 either way, and always was: nothing but a
WebSocket ever arms either half, which is exactly why plain request serving
never showed it.

## Why it looked like somebody else's bug

The last log line was `nilo stopped`, which `drain` writes once `Stop.in_flight`
reaches zero — so nilo's own shutdown had run to completion and every connection
was accounted for. What was left was `group.cancel()` and `rt.deinit()`, both
zio's, and one executor thread spinning in userspace with no syscall
outstanding. Every visible symptom was downstream of nilo's last line of code.

The reading was wrong, and
[`roadmap.md`](../roadmap.md#how-this-file-is-written) had already written down
why it would be: **`Waiting on: upstream` is the line to distrust.** That makes
five blockers this repository has been wrong about, four of them somebody else's
code that turned out to already do the thing. What settled it was not a newer
zio — none was ever tried — but reading `completion_queue.zig`, where the answer
is in the last test in the file:

```zig
try std.testing.expectError(error.Timeout, cq.timedWait(.fromMilliseconds(10)));

// Clean up
cq.cancel();
```

zio says a queue with pending completions is cancelled before it is abandoned,
in a test, without a sentence of prose anywhere. **The dependency's tests are
part of its documentation**, and this one was three hundred lines from the
function nilo was calling.

## Why the fix is in the Engine and not the Bulkhead

`Waker` in `bulkhead.zig` carries `wait`, `post` and `release_stack`, and a
fourth entry could have been added for teardown. It was not, because there is
nothing for a Service or a handler to decide here: the Engine submitted the
completions, the Engine knows the fiber is ending, and the Engine is the only
file allowed to name zio at all
([ADR 0002](./0002-zio-as-the-engine-behind-the-bulkhead.md)).
A vtable entry would have put a lifetime rule that is purely the Engine's into a
contract every future Engine has to reimplement.

`Conn.run` registers `defer wake.deinit()` after both buffers and after
`stream.close`, so it unwinds before all three. Before the frame goes, because
that is the whole point; before the socket closes, because the poll is
registered on that handle and giving it back after the handle is gone is the
same class of mistake one layer down.

## The guard, and it has been seen to fail

`bench/shutdown.py` is the reproduction and it needs a process, a signal and
several connections in sequence, so it stays off `zig build test` for the reason
`smoke-tls` is off it. That left the fix with nothing in the suite behind it,
which
[ADR 0033](./0033-a-guard-is-not-a-guard-until-it-has-been-seen-to-fail.md)
does not accept.

`test "a Wake that parked hands its completions back before its frame goes"`
stands a one-executor `Runtime` up on the test's own thread — the shape zio's
`completion_queue.zig` tests use — parks a `Wake` on a listener nobody connects
to until it times out, and checks the queue is empty on the other side of
`deinit`. With `deinit` stubbed to return, it fails on the line after the call:
**612 pass, 1 fail.** Port 0, so it joins none of the three loopback ranges the
roadmap has an open risk about.

## The rule this leaves

**Anything submitted to the loop is borrowed, and the borrower says when it is
done.** A frame that holds a completion cannot simply return: `defer` the
cancel, and let the cancel drain. That is one line at the point of submission
and it is not optional, because the failure it prevents is invisible at the
place it happens and arrives somewhere else entirely — in this case as a
container that would not stop, in a process whose own shutdown had already
logged success.

## What it costs

Per connection: nothing at all. `Wake` gains no field; `deinit` is behaviour,
not state, so the 5,183 bytes an idle WebSocket holds is unmoved.

Throughput: nothing on any message path. The call happens once, when a
connection is already ending, and only for a connection that parked — the first
line is `if (!self.armed and !self.poll_armed) return;`, so an ordinary request
pays one branch on a path that is already closing a socket.

Allocations: none.

Binary size: a handful of instructions in one function.
