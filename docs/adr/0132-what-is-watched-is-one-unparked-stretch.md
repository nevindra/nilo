# What is watched is one unparked stretch

[ADR 0034](0034-the-thing-a-handler-holds-is-watched-at-run-time.md) measures a
handler with **elapsed time minus time the fiber spent parked**, summed over
the whole request, and reports at the end of it.

That works for a request that starts, answers and returns. It does not work at
all for one that takes the connection over — a stream, a body reader, a
WebSocket — so all three were excused entirely, and `watchdog.zig`'s header
said so:

> A blocking call inside a WebSocket loop is real and is not reported. That is
> a stated gap, not an oversight.

It was the wrong gap to leave open. A stalled fiber inside a WebSocket loop
holds its executor against **every other socket that executor is serving**, for
the life of the connection rather than for one request — which is where the
mistake costs the most, and the one place nothing was watching.

## Why the exemption was forced

Not laziness: a sum has no upper bound on a connection that stays open. A
WebSocket answering a thousand messages a second accumulates seconds of
perfectly correct handler time in a minute, and a total measured against a
250ms limit would report it. The metric had no meaning on a long-lived
connection, so the connection had to be taken out of the metric.

## What it measures now

**The longest stretch the fiber ran without parking.** A stretch ends wherever
the request waits on something that is not the handler's own code, and every
one of those already says so — that is what `waiting`/`waited` were for. The
change is what they do: `waiting` now *closes* a stretch and reports it if it
was too long, and `waited` opens a fresh one.

One stretch means the same thing on a request that lasts a millisecond and on a
connection that lasts a day, so the exemption goes. `finish` no longer takes
`excused`, and there is nothing left that takes it.

Three waits had to start saying so, because they were the reason those three
handlers were excused in the first place:

- a stream's writes (`stream.zig`'s `drain`),
- a body reader's reads (`body.zig`'s `streamFn` and `discardFn`),
- a WebSocket's park (`websocket.zig`'s `park`).

Each takes the `Watch` pointer the `Ctx` already holds rather than looking it
up through the fiber slot: it is one pointer copied at construction, and a
`null` one is what a `Stream` a test built against a buffer gets.

**A WebSocket's stretch is exactly one message.** `park` is where the loop
waits, so what lies between two of them is what the handler did with the
message it was handed — including the framework's own reassembly, which is
microseconds. Nothing had to be invented to scope it; the bracket was already
in the right place.

**Nested pairs are safe.** `nilo.sleep` inside `Ctx.body` is that shape: the
inner `waiting` finds the watch already parked, returns a zero token, and its
`waited` does nothing, so the stretch is reopened by the outermost `waited` and
by that one only.

## What changes for somebody who had it switched on

**A handler that yields between short stretches is no longer reported.** Ten
30ms stretches with a `nilo.blocking` between each pair summed to 300ms and
were caught; measured one at a time they are 30ms and are not. That is the
right answer rather than a loss: ADR 0034's advice is "hand the call that waits
to `nilo.blocking`", and a handler that yields every 30ms has already done it.

**A handler that blocks twice is now reported twice**, where the sum reported
once. The rate limit in `report` is what keeps that readable, and it was
already there.

**A stream, a body reader or a WebSocket can now be reported at all.** That is
the point.

## What it costs

**One subtraction and one comparison per wait**, on top of the clock read that
was already there, and only when the detector is on — `warn_ns == 0` is checked
first and is the whole cost on a server that turned it off.

**Nothing per request that does not wait.** The path from `begin` to `finish`
with no wait in between is what it was.

**`Watch` grows two slices** (32 bytes) so the report can name the request from
inside `waiting`, which has no `Ctx` to ask. It lives on `fail.InFlight`, one
per connection, which is memory an idle connection holds
([ADR 0071](0071-where-a-connection-waits-is-what-it-costs.md)) — 32 bytes
against 4,669. `fail.InFlight` holds the same two strings already, for the
panic handler; they are not copied, only pointed at, and they are arena slices
that live exactly as long as the request that set them.

**`waited_ns` is gone**, so the struct is a field smaller than the two slices
made it.

## What was rejected

**A message-scoped watch of its own**, started and stopped by `websocket.receive`.
It answers the WebSocket and leaves the stream and the body reader where they
were, and it needs a decision about where the room drain belongs. Bracketing
`park` needs no such decision — the drain is on the handler's side of it,
which is correct, because draining a Room is work that does not wait.

**Keeping the sum and adding a ceiling to it** — reset the total every N
seconds on a long-lived connection. It is a second number to explain and it
still cannot say whether the handler ever held the thread or merely used it.

**Reading the request's method and path through the fiber slot in `report`.**
`fail.inFlight()` has them, and a `Watch` living outside an `InFlight` is a
thing a test is allowed to build — `@fieldParentPtr` from one of those is a
garbage slice printed in a log line.
