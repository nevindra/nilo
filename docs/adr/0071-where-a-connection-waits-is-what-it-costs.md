# Where a connection waits is what it costs

[ADR 0063](./0063-a-handlers-stack-is-per-connection.md) established that a
suspended fiber holds its stack, wrote the rule down, and recorded the fix as
blocked on zio. **Both halves of that were wrong.** The block did not exist,
and releasing the stack was not the fix. This ADR is what replaced it, and it
took a keep-alive connection from **8,767 bytes to 4,669** and an idle
WebSocket from **9,290 to 5,183**.

## The block that was not there

ADR 0063 said there was no supported way to obtain the running fiber's
`StackInfo`, having looked for it through `runtime.getCurrentTaskOrNull`, and
filed [zio#677](https://github.com/lalinsky/zio/issues/677). The answer was to
point at another door: `zio.coro.Coroutine.getCurrent()` is public in the
pinned v0.17.0 and carries `context.stack_info`, with `base` and `limit` on it.
`releaseIdleStack` in `http/engine/zio.zig` is nine lines and needed nothing
from upstream.

**A conclusion of "blocked on somebody else" is worth one more hour than it
usually gets.** This one was written down in an ADR, put on the roadmap, and
filed as an issue, and it was answered by reading a different file in the same
package.

## Releasing the stack changed nothing

With `releaseIdleStack` wired into the idle path, every idle connection ran the
`madvise` — `strace -c` confirms the count — and **`VmRSS` per connection did
not move by a byte.** 8,767 before, 8,767 after.

Two mistakes, and the second is the one worth keeping.

**A page of margin is not a page of safety.** The first version left four pages
below the frame untouched, on the reasoning that more slack is safer. The chain
it was trying to release is four to six kilobytes deep, so sixteen kilobytes of
margin reached past every page there was to give back. What actually has to be
protected is this frame and the 128-byte red zone below it, which subtracting
512 bytes *before* rounding down to a page does at every alignment.

**And then the connection walked straight back down and slept there.** This is
the finding. `waitOrRelease` released the pages and returned; the connection
loop then called `handleRequest` → `readHead` → `fillMore` and suspended
**four kilobytes deeper than the frame the madvise had just been measured
from**, faulting in everything it had given away. The release was real, the
saving was real, and it lasted about two microseconds.

> **Where a fiber is suspended is what the connection costs, and it is not
> where the release runs.**

## What was decided

**The waiting moves up, and the WebSocket loop moves up with it.**

### 1. The idle wait happens at the connection loop's frame

`waitForRequest` (was `waitOrRelease`) now does the whole wait: peek for
`idle_peek_ms`, release the buffers and the stack if that comes back empty, and
then **wait for the next request there**, at the shallowest frame the
connection ever has. `readHead` finds the bytes already buffered.

### 2. The request's machinery is a frame of its own

`App.serveRequest` is `noinline`. Inlined into the connection loop, its 1,608
bytes — the `Ctx`, the parsed head, the route match — were part of the frame
the connection sleeps in. As a callee they are below the sleeping frame and
dead, which is exactly what the release is for.

### 3. The cold half of a request does not get to cost anything

**A format string costs stack whether or not it is ever printed.** Zig builds
the argument tuple and the `Io.Writer` state in the frame of whatever function
the call is inlined into; four `std.log.warn` sites nobody hits were most of
`handleConnection`'s 4,184 bytes. `warnFailedAfterAnswering`, `sendFailure`,
`endAbandonedStream`, `warnSocketFailed`, `Socket.deliver`, `handleControl` and
`ping` are `noinline` for that reason and no other.

### 4. A WebSocket handler hands its loop back

This is the API change, and it breaks
[ADR 0022](./0022-a-websocket-is-a-handler-that-does-not-return.md)'s shape on
purpose.

```zig
// before — the handler keeps the loop
fn chat(c: *nilo.Ctx, room: *nilo.Room) !void {
    var socket = try c.upgrade();
    while (try socket.receive()) |m| try room.say(m.kind, m.data);
}

// after — the handler answers the handshake and says who reads the socket
fn chat(c: *nilo.Ctx, room: *nilo.Room) !void {
    return c.upgrade(chatLoop, room);
}

fn chatLoop(socket: *nilo.Socket, room: *nilo.Room) !void {
    while (try socket.receive()) |m| try room.say(m.kind, m.data);
}
```

A handler that keeps the loop is suspended *inside* `serveRequest` for the life
of the socket — holding the `Ctx`, the head and the match, none of which the
loop can reach. `Ctx.upgrade` answers the handshake, leaves a `Handover` in a
slot belonging to the connection loop, and returns. The connection loop runs
the loop from its own frame, with the request unwound. Measured at the park
point: **4,345 bytes of live chain down to 2,617** — the difference between two
pages resident and one.

`state` is what the handler knows and the loop needs. It travels in the
connection's frame, so it has a ceiling of `websocket.state_max` = 128 bytes;
anything larger goes in the request arena — which is alive for as long as the
loop is — with a pointer carried across. `refusals/ws_state_too_big.zig` says
so at compile time.

That number was 32 for an afternoon, and what it caught is worth keeping:
**a `Str` is 40 bytes in Debug and 16 in release**, because the
use-after-request trap's marker is compiled out. So `c.upgrade(loop,
c.query("name").?)` was refused by `zig build test` and accepted by
`-Doptimize=ReleaseFast`. **A comptime refusal that depends on the optimize
mode is worse than no refusal**: it turns a design rule into a
build-configuration surprise, in a repository whose whole error-message
discipline is that a mistake stops in nilo's own words at the place it was
made. 128 is set past anything a caller would plausibly carry by value in
either mode.

## What was rejected

**Shaving the last 761 bytes off `receive` and the typed wrapper instead of
changing the API.** It reaches one page and leaves 3,573 bytes against a 3,584
threshold: one future field on `Ctx` and every WebSocket in every deployment
silently costs 4 KB more, with no test that could catch it. A number that
passes by eleven bytes is not an invariant.

**Running the socket loop on a second fiber and letting the connection fiber
die.** The `Wake` an engine posts to lives in the connection fiber's frame
(ADR 0029), and the read and write buffers are the accept loop's — all three
would have to move into the engine's contract. It also costs a spawn per
upgrade, and zio's `stackRecycle` uses `MADV_FREE`, which is lazy and leaves
the pages in `VmRSS` regardless.

**Keeping both upgrade shapes.** Two ways to open a WebSocket where one
silently costs 4,096 bytes a connection more is the "the option is a lie"
problem ADR 0022 refused a `max_message` over. There is one way and it is the
cheap one.

## What it costs

Against [ADR 0018](./0018-the-trade-budget-has-three-axes.md)'s four axes, on
the merged tree (`dcadb46`) against a `git archive` rebuild of the commit it
sits on (`0492be0`), the two servers run alternately in one session so a
machine that drifts drifts under both. `bench/result/http.md` has every run:

| axis | before | after |
|---|---|---|
| Allocations per request | 1 | 1 — unchanged, nothing here allocates |
| Memory per idle keep-alive connection | 8,767 | **4,669** |
| Memory per idle WebSocket | 9,290 | **5,183** |
| Throughput, `GET /users/:id` | 1,420,424 req/s | 1,429,293 — **unchanged** |
| p99, the same | 59–82µs | 58–98µs — unchanged |
| Throughput, 64-byte echo | 1,704,321 msg/s | 1,672,617–1,685,719 — unchanged |
| Binary size, stripped `ReleaseFast`, `examples/hello` | 886,680 B | **887,920 B** — +1,240 |

**Only the memory row moved, and that is the whole of the claim.** An earlier
draft of this ADR read a single 1,485,190 against a single 1,424,878 and said
throughput had gone up, reasoning that one page of stack instead of two costs
fewer TLB entries. Four interleaved pairs put the difference at +0.6% with the
sign changing between pairs and a spread of 8% inside each column — **one run
each is not a comparison.** The claim is withdrawn rather than restated more
carefully; a change that spends binary size to buy memory does not also need to
have been free, and saying so would have cost this ADR its credibility on the
row that is real.

The 1,240 bytes are the cold paths becoming real functions instead of inlined
copies — `sendFailure`, `endAbandonedStream`, the two log helpers,
`Socket.deliver`, `handleControl`, `ping` — plus one trampoline per distinct
socket loop in the program. `examples/hello` has no WebSocket route at all and
still pays it, which is the disclosure ADR 0018 asks for rather than a defence
of it: it is 0.14% of the binary, and it buys 4,096 bytes on every connection
the process ever holds. `examples/chat`, which does open a socket, pays 2,480.

## Consequences

- **ADR 0018's memory axis is 4,669 bytes**, still a floor and still not a
  total: ADR 0063's finding stands unchanged, and a handler still adds every
  byte of stack it touches. `/ws/deep` — a loop that `@memset`s 64 KiB —
  measures 70,719.
- **ADR 0022's shape is superseded.** "A WebSocket is a handler that does not
  return" becomes "a WebSocket is a handler that hands its loop back". The rest
  of that ADR — the framing, the housekeeping frames, the closing handshake —
  is untouched.
- **The comparison that prompted this is now won on both axes, and narrowly on
  one of them.** [gws](https://github.com/lxzan/gws) was ahead on an idle
  socket by up to 19% and on a socket that had seen a 60 KiB message by 9×;
  it is now behind on every memory row by 1.5× to 4.2×, and behind on echo
  throughput by 5–8% with both sides pinned to the same four cores. **The
  throughput margin is small enough that it must be quoted as a band**, and
  `bench/result/http.md` says why: four runs put it at 7.0, 8.2, 7.1 and 4.7
  percent. The tail is the firmer claim — p999 is better in every run by more
  than either side's spread. gws stays the control for this axis; a change that
  regresses one of those rows should be visible in one command.
- **An open WebSocket no longer counts as a request in flight.** It used to,
  because the loop ran inside `serveRequest` and the counter bracketed it, so
  every idle chat tab added the full grace period to a shutdown. That
  contradicted the counter's own stated rule — "requests, not connections,
  because a connection parked in a read is holding no work" — and the new shape
  brings the two into line.
- **The next flat number to distrust is this one.** 8,767 was correct,
  published, repeated in six files, and describing a shape that had never been
  re-measured after the code around it moved. This one has `bench/ws_idle.py`
  behind it and five control routes beside it, and it should still be re-run
  rather than quoted.
