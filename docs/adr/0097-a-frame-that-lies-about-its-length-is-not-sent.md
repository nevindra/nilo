# A frame that lies about its length is not sent

`Socket.print` and `Socket.json` run the format twice: once counting, so the
frame header can state a length, and once writing, straight into the connection.
The doc has always named the hazard and handed it to the caller — *"the
arguments are therefore read twice: pass values, not a window onto memory
another fiber is writing"* — and nothing checked that the two passes agreed.

**They are checked now, and a disagreement closes the connection rather than
desynchronising it.**

## Why this one and not the others

`Room.print` has the same two passes and has asserted between them since it was
written (`std.debug.assert(into.end == post.len)`), because it writes into a
buffer it can measure. `Socket.print` and `Socket.json` write straight to the
connection and asserted nothing. **So the one place where the mistake cannot be
recovered from was the one place that was unchecked.**

Unrecoverable is meant literally. A WebSocket frame states its length and then
its bytes; a length that is wrong by one leaves the reader at the wrong offset
for every frame after it, for the life of the connection. There is no
resynchronisation point in RFC 6455 and no way for the other end to notice
except as garbage.

## The check is `Writer.end`, and that is the whole trick

`std.Io.Writer` carries `buffer`, `end` and a vtable and no count of what has
been drained, so "how many bytes did the second pass write?" has no direct
answer. Two ways to get one were rejected:

- **A counting wrapper writer.** Exact at every size, and it puts an extra
  indirection on every byte of every formatted message. Compiled only in safe
  modes it would be worse still: the suite would then be exercising a write path
  that nobody deploys.
- **A third pass, counting again after the write.** No wrapper and no
  per-byte cost, but it is a whole extra run of the format — and on a message
  large enough to matter, in `ReleaseSafe`, which is the mode the documentation
  tells people to deploy in.

What is used instead costs a subtraction and a compare. While the payload still
fits in what is left of the connection's write buffer **nothing can drain** —
`Writer.VTable.drain`'s contract says it is not called for data that could have
been buffered — and while nothing drains, `end` is an exact count of the second
pass. `Framed` in `http/websocket.zig` holds the three numbers that says.

**A message bigger than the write buffer is not checked.** A drain moves `end`
and leaves nothing to compare against. `print` and `json` are for the small
structured messages a WebSocket carries — `send` takes bytes the caller already
has and needs none of this — so the gap is in the uncommon shape, and it is
written into the type's doc rather than papered over. One case does survive the
drain: if the promise *fitted* and a drain happened anyway, that is itself proof
the second pass wrote more than it promised, and it is caught.

## Close, not assert

The obvious shape was `std.debug.assert`, matching `Room.print`, free in
`ReleaseFast`. It was rejected for three reasons.

1. **An assert in `ReleaseSafe` takes the process down.** Zig cannot recover
   from a panic ([ADR 0008](./0008-no-recover-middleware.md)), so one connection
   whose handler formatted a moving value would kill every other connection in
   the process. Turning a corrupted socket into an outage is a worse trade than
   the one being fixed.
2. **A guard that only exists in the modes the suite runs never runs where the
   bug happens.** The failure needs another fiber writing the memory being
   formatted, which is a production shape, not a test shape.
3. **An assert cannot be seen to fail.**
   [ADR 0033](./0033-a-guard-is-not-a-guard-until-it-has-been-seen-to-fail.md)
   asks every guard here to have been watched failing, and a panic cannot be
   caught in Zig. Returning `error.WriteFailed` can, and
   `test "a format that disagrees with itself closes the connection instead of
   lying about a length"` does.

So the check is on in every optimize mode, and what it does is close with 1011
and hand the handler `error.WriteFailed`. Usually the bad frame is still sitting
in the write buffer unflushed, and then it is taken back off and never leaves
the building at all.

## What it costs

Throughput: one subtraction and one compare per `print` or `json`, against a
whole format pass. Nothing measurable, and nothing on `send`, which is the call
an echo loop at 1.7M messages a second makes.

Per connection: nothing. `Framed` is three numbers and a bool in the calling
frame, and that frame is gone before the socket parks.

Binary size: nothing the linker cannot fold; the check is a handful of
instructions in two functions.

Allocations: none, which is the property the two-pass shape exists to keep.
