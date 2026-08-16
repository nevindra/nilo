# A message is copied once, and a broadcast is framed once

ADR 0022 settled what a WebSocket *is* — a handler that does not return yet —
and ADR 0038 settled how one connection reaches another. Neither looked at what
a message costs on the way through, and the answer was: about twice what it
should.

Receiving one went like this. The bytes arrive in the connection's read buffer.
`readSliceAll` copies them into the handler's buffer. Then `unmask` walks the
same bytes again, in place, XORing each against the client's four-byte key.
**Two walks over the same cache lines to produce one result**, and the second
one exists only because the first one was written as a copy rather than as a
copy that does something.

Sending to a room had the mirror of it. `say` hands one post to a thousand
seats, and each of the thousand connections then built the same two-to-ten-byte
frame header in front of the same bytes — a server frame carries no mask and
nothing else that differs by recipient, so all thousand headers were identical
by construction.

And `say` walked *every seat the room was sized for*. A room with a thousand
seats and three people in it did a thousand iterations per message, so sizing a
room generously was a per-message tax rather than a memory decision.

## What was decided

### The copy and the unmask are one pass

`unmaskInto(dst, src, key, offset)` reads from one slice and writes to another,
which may be the same slice — so the in-place `unmask` is one call to it and
there is one implementation rather than two. `receive` then has two paths and
between them no byte is copied twice:

| | |
|---|---|
| The frame is in the read buffer already | unmasked straight out of it into the handler's buffer |
| It is bigger than one read | read straight into the handler's buffer, past the read buffer entirely, and unmasked where it lands |

The first is nearly every frame and *every* frame under the size of one read,
which is 8 KB by default. The second never copies either — `readSliceAll` reads
into the destination — so it pays exactly what it paid before and the first pays
half.

### A header is parsed out of bytes in hand, by a function that cannot fail

`headerFrom(bytes) ?Frame` is pure: no reader, no socket, no refusals. It
returns null when there are not yet enough bytes to say, and carries `reserved`
and `masked` as facts rather than judging them, because every refusal needs a
close frame to send and only the connection has one.

That is worth more than the three reader calls it saves. The whole of RFC 6455
§5.2 is now checked against a table of byte strings instead of through a
connection, and the fast path in `receive` is one call against
`self._in.buffered()` with no fill, no copy and no reader call at all. Only a
header split across reads takes `peek`.

### The widths the unmasking steps down through are 128, 32, 8, 4

The key is four bytes, so every one of those tiles it exactly. 128 is where the
throughput stopped improving; 256 was worth another 6% and twice the unrolled
code. The ladder underneath it is not tidiness — a chat line is forty bytes and
would otherwise fall straight past a 128-byte tile into a byte-at-a-time tail
almost as long as the message.

`std.simd.suggestVectorLength(u8)` was the obvious alternative and is the wrong
question: it answers with the target's register width, and what this loop wants
is an *unroll factor*. On the machine below that answer would have been 64,
which measures 30% slower than 128.

### A post is framed once, by the room

The WebSocket header lives in the post's own allocation, immediately in front of
the bytes, so `deliver` is one `writeAll` of one slice. The room builds it once
for everybody; a connection catching up works out nothing per message.

The header is built by `websocket.headerFor`, which is the same function
`writeFrame` uses, and a test asserts the two agree at every length across all
three length forms. A second copy of the framing rules in `room.zig` would have
been the obvious way to do this and is the one thing here that could go wrong
silently.

### A broadcast costs what the room holds, not what it was sized for

`roll` is every seat index exactly once, with the taken ones in front. `join`
takes the one sitting at `here`; `leave` swaps the leaver with the last taken
one. Both are a handful of stores rather than a walk, and `say` iterates
`roll[0..here]`.

The invariant — a permutation, taken half dense, every taken seat's `slot`
pointing back at where it sits — is what a broadcast delivering twice or not at
all would come from, so it has a test that fills a room, empties it from the
middle, the front and the back, and checks the whole permutation after each
(ADR 0033: this is exactly the kind of guard that would otherwise only ever be
seen passing).

### `receive` ends when the server is stopping

It sends a 1001 and returns null, which is a `null` a handler's loop already
handles. Before this, ending on a shutdown was something every WebSocket
handler had to remember to write:

```zig
while (try socket.receive(&buf)) |message| {
    if (!socket.live()) break;      // gone
    try room.say(message.kind, message.data);
}
```

ADR 0020 says a handler that ignores the stopping flag holds the deploy open.
A framework that knows this and leaves it to a branch in every loop has put the
rule somewhere it cannot enforce it. `live()` stays, for the handler doing work
of its own between messages — a computation, a timer, a queue — which nilo
cannot see and cannot end on its behalf.

### Sending on a closed socket writes nothing

Not an error. The case a handler cannot prevent is the other end closing
between two of its own sends, and an error there is one every handler in the
world would have to branch on for something that is not its fault. It is the
same reading ADR 0022 gave a client that vanished, applied to the other
direction.

### A goodbye that is not one is a framing error

A close payload of one byte, a code nobody assigned, or a reason that is not
UTF-8 is refused with 1002 rather than echoed. Echoing was the old behaviour
and it put the same broken frame back on the wire — which is a server agreeing
with a client that something impossible happened.

1005 and 1006 are the interesting ones: they mean "no code was sent" and "the
connection died", neither of which an end can observe *about itself* and put in
a frame.

## The numbers

`zig build profile`, best of five runs each, AMD Ryzen 7 9700X, ReleaseFast.
The 48-byte row is new and is the shape a chat actually has: the 16 KiB row
says what the unmasking is worth, and this one says what a real message costs.

| | before | after | |
|---|---|---|---|
| `websocket: frame overhead` | 9ns | **6ns** | 1.5× |
| `websocket: receive 48 B` | 15ns | **12ns** | 1.25× |
| `websocket: receive 16 KiB` | 196ns — 88.1 GB/s | **73ns — 244.5 GB/s** | **2.7×** |
| `websocket: send 16 KiB` | 80ns | 76ns | 1.05× |
| `room: say to 8 of 1,000 seats` | 494ns | **161ns** | **3.1×** |

Receiving 16 KiB is now faster than sending it, which reads as a mistake and is
not: sending is a `memcpy` into the write buffer, receiving is a load, an XOR
and a store over the same traffic, and both are memory-bound rather than
instruction-bound. The XOR is free; the second pass was not.

Delivery has no row, deliberately. What changed there is the number of writes
and flushes a burst costs — one each, rather than one per post — and a
measurement in this harness would be reporting `DebugAllocator` and a fixed
writer, neither of which a connection has.

## What it costs

**Binary size.** +896 bytes on the chat example, stripped `ReleaseFast`
(917,808 → 918,704), which covers the 128-wide unroll, the close validation,
`print`, `json` and the roll. **The hello example does not move by one byte**,
so a server that never upgrades still links none of this — the property ADR
0018 asks for, and the one the running total is kept to notice losing.

**Memory per seat: +8 bytes.** Four for the roll's entry and four for the
seat's `slot`. A room of the default 1,024 seats costs 8 KB more, once, and not
per connection — the number ADR 0018 calls hard is untouched, and ADR 0038's
"4 measured bytes per idle connection" is unchanged.

**Allocations per request: unchanged.** Nothing here allocates. `print` and
`json` on a Socket allocate nothing at all; on a Room they reuse the one
allocation `say` was going to make.

**The format string runs twice** for `print` and `json`. A frame states its
length before its bytes, and the only places to hold them meanwhile are an
allocation or a fixed buffer whose size the caller guesses — which is the
`bufPrint` dance these exist to delete. The arguments are therefore read twice:
pass values, not a window onto memory another fiber is writing.

## What was rejected

**A `Message` that points into the read buffer.** Zero copies rather than one,
and it would make the handler's buffer optional. It also makes the message
valid only until the next `receive`, which is a lifetime rule in a place ADR
0022 promised there would not be one — "the buffer you pass is the memory, and
it lives exactly as long as you decide". A fused pass gets most of the win and
costs the caller nothing to understand.

**Making the reserved-bit and mask-bit checks part of `headerFrom`.** It would
save carrying two bools. It would also mean the pure function has an error set,
and an error set means the close frame is somebody's business, and then it is
not a pure function any more. The two bools are the price of the table test.

**Keeping the 32-byte tile and adding an unroll by hand.** LLVM does this
better from a wider vector than from a `comptime` loop, and the wider vector is
one number to change when a machine turns up where it is wrong.

**A free-list separate from the roll.** Two arrays where a single permutation
does the same job: the free seats are simply `roll[here..]`, and the one that
`join` wants is the first of them.

**Growing `Post` with a capacity field so a short format pass could shrink it.**
`free` needs the length it allocated, so shrinking `len` after the fact would
hand the allocator the wrong size. The counting pass and the writing pass agree
for any arguments that did not change between them, and an assert says so.

## Consequences

- `Options.max_message` is still absent and this changes nothing about that.
  The buffer handed to `receive` is still the one ceiling (ADR 0022).
- A fragment is now measured against **what is left** of that buffer rather
  than all of it, so a second fragment that cannot fit beside the first is
  refused on its header, before its bytes are read.
- `websocket.Handshake` is gone. It was a struct wrapping the array `accept`
  already returns, and nothing had ever used it.
- `Socket.print`, `Socket.json`, `Room.print` and `Room.json` join the
  `Stream.print`/`Stream.json` pair, which is the shape a handler already
  knows.
- **A frame arriving a few bytes at a time now has a test.** A fixed reader has
  the whole conversation in memory before the first call, so it never once
  reached the paths that exist for a split frame — which is what a network does
  with everything over a kilobyte. `Trickle` is a reader that hands over three
  bytes at a time, and it is how the second path above is checked at all.
- **The Autobahn suite still does not run against this.** The close-code and
  UTF-8 rules here were written from RFC 6455 §5.5.1 and §7.4.1 rather than
  from a failing report, which makes them the kind of guard ADR 0033 is about.
  Wiring up `wstest` is on the roadmap as a known gap rather than done.
