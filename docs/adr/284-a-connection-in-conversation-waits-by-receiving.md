# A connection in conversation waits by receiving

**Status:** accepted
**Topic:** [engine](../design/engine.md)
**Extends:** [ADR 035](./035-a-broadcast-rings-a-bell-it-does-not-write.md),
[ADR 062](./062-where-a-connection-waits-is-what-it-costs.md).
**Applies:** [ADR 001](./001-zio-as-the-engine-behind-the-bulkhead.md),
[ADR 017](./017-the-trade-budget-has-four-axes.md),
[ADR 201](./201-a-response-is-flushed-before-the-connection-waits.md).
**Found by:** [HttpArena](https://github.com/MDA2AV/HttpArena)'s `echo-ws` profiles, where dusty, on the same zio, read 4.12M frames a second at 512 connections against nilo's 3.60M with the same CPU, and 2.11M against 1.22M on `echo-ws-limited` (`bench/result/http.md`, "A WebSocket frame cost two trips through the loop and three timers").

## Context

A connection that can be posted to waits on two things at once, its socket and a bell (ADR 035). The wait is `Wake.wait`: a `NetPoll` for the socket and an `Async` for the bell in one `CompletionQueue`, under the limit the caller gives it. It asks for readiness and reads nothing, because the connection's buffered reader does its own reading and because a wait that holds no buffer is what lets an idle connection give its pages back (ADR 062).

What that costs is paid on every message, not once per quiet spell. A WebSocket answering a frame did, per frame:

1. the wait: a poll submitted, the queue's wait with the 200 ms peek as its limit, which is a timer set and cleared under the loop's timer lock;
2. the read the poll announced: a receive through the loop, under the per-read limit an upgraded connection carries (`armEachRead`), which is a race group and a second timer, armed and cancelled around a receive that was never going to wait;
3. the answer: a send under the write limit, the third timer.

Two trips through the loop to get bytes the kernel already had, and three timers. dusty's `receive` is one receive and its `send` one send. On the arena that is 18.1 µs of CPU a frame for nilo against 15.5 for dusty at 512 connections, and on this machine 2.08 to 2.15 µs against 1.61 to 1.68. A profile of the server put the loop's timer and wait-group functions (`timedWaitForIoClock`, `setTimer`, `clearTimer`, `lockTimers`, `groupCallback`, `cancelLocal`, `CompletionQueue.waitTimeout`) at about 40% of user cycles. A build with the park taken out entirely, measurement only, came out level with dusty, so the park was the whole of the difference, and the park is also what makes posts, pings and the idle release work.

HTTP/2's connection waits the same way between frames (`h2conn.zig`), and so does a stream's park; the HTTP/1.1 keep-alive wait does not, because it is a read with a limit and no bell.

## Decision

**While a connection holds its buffers anyway, its wait receives into them.** `Waker.waitFilling` is `Waker.wait` with the bytes: the Engine submits a `NetRecv` into the free room of the reader nearest the socket (the cleartext one on a plain connection, the ciphertext one under TLS) in place of the poll, and `.readable` comes back with the bytes already buffered. The caller's next read is from memory: a frame whose header and payload arrived together is parsed with no read at all and no read timer.

- **Only for the peek.** The WebSocket's two peeks, HTTP/2's peek, its wait with calls in flight, and `waitQuiet`'s peek use it, because in each the buffers are held whatever happens. The wait after the pages have gone back stays `wait`: a receive pins the buffer it was given until it completes, and a connection quiet for an hour would hold its buffer for the hour, which is ADR 062's axis.
- **The receive never outlives the call.** A post or the limit cancels it through `CompletionQueue.cancel`, which waits for the loop to let go, and whatever it got first is counted as buffered. A post that crosses a frame loses neither: the caller hears `.posted`, delivers, and finds the frame in its buffer on the next round, where it does not wait at all.
- **A poll already in the loop's hands answers instead.** A `lookNow` (HTTP/2's look while writing) or a `.posted` can leave the poll armed. A receive beside it would race it for the same bytes and leave it to fire for bytes already taken, so `waitFilling` is then `wait`.
- **The caller has flushed**, as for `wait`. This is a read the writer's `Link` never sees, so ADR 201's guarantee, which sits on reads, does not reach it; every caller already flushes before it waits, and the contract says so.
- **TLS keeps `held`.** A whole record already in the ciphertext buffer is `.readable` without waiting, as before. A partial record is kept and moved to the front if the buffer is full, and the receive appends to it.
- A Waker with no Engine under it has no `wait_filling`, and `waitFilling` is `wait`, so `Waker.off` and the test fakes are unchanged.

Measured on this machine against the same server without it and against dusty, interleaved, server and gcannon on separate cores (`bench/result/http.md`):

| | µs of CPU a frame | frames a second |
|---|---|---|
| `echo-ws`, 512 connections, before | 2.08–2.15 | 2.06–2.68M |
| after | 1.78–1.83 | 2.45–3.00M |
| dusty | 1.61–1.68 | 2.65–3.17M |
| `echo-ws-limited`, ten frames a connection, before | 3.46–3.53 | 1.62–1.72M |
| after | 3.05–3.09 | 1.87–1.88M |
| dusty | 2.79–2.87 | 1.90–1.96M |

HTTP/2 does not move outside its spread (h2c 1.18 to 1.24 µs a request either way, `json-h2c` 6.52 to 6.79 against 6.67 to 6.94), because one wait there is followed by many frames.

## What it costs

| Axis | Cost |
|---|---|
| Allocations per request | 0 |
| Memory per idle connection | 0: 4,684 bytes an idle HTTP/1.1 connection at 4,000 before and after, 5,186 an idle WebSocket in a Room, and `park-check` holds one page. `Wake` gains a `NetRecv`, an iovec and a pointer, in the frame it was already in |
| Throughput and p99 | A gain: 15% fewer µs a frame on `echo-ws` and 12% on `echo-ws-limited` |
| Binary size | +1,840 B on `hello`, +1,808 B on `rest`: the Bulkhead's vtable names `waitFilling`, so a program with no WebSocket links it ([ADR 017](./017-the-trade-budget-has-four-axes.md)) |

## What was rejected

**Skip the park while nobody can post.** A socket that never joined a Room cannot be posted to, so its wait could be the read. It would have fixed the arena's echo and left every chat and every HTTP/2 connection paying, and it trades the idle release for the read's limit, so a quiet socket would hold its buffers for the idle limit instead of 200 ms.

**Keep the poll and take the timer off the read after it.** One timer of three, and still two trips through the loop.

**Receive for the whole wait, idle included.** One shape for both waits, and a buffer pinned for as long as the connection is quiet: ADR 062's axis, refused.

**No timers at all, as dusty does.** dusty publishes a deadline to a watcher instead of arming a timer a read. Two timers a frame are left here, the peek's and the write's, and they are most of the distance to dusty that remains; taking them out is a change to how the Engine bounds a read and a write, not to how a connection waits, and it is in [`docs/todo.md`](../todo.md).

## Consequences

- `http/engine/zio.zig`: `Wake.fill`, `Wake.recv`, `Wake.waitFilling` and `received`; `Wake.init` takes the reader nearest the socket.
- `http/bulkhead.zig`: `Waker.VTable.wait_filling` and `Waker.waitFilling`.
- `http/websocket.zig` and `http/h2conn.zig` call it for their peeks and for HTTP/2's wait with calls in flight. A stream's park is unchanged: a feed's client sends nothing to receive.
- `http/live.zig` holds it over a real socket: a frame in the peek, one after the pages went back, one split, two in one write, and four hundred posts crossing four hundred frames, a test seen to fail with the bytes of a cancelled receive dropped (and three HTTP/2 tests with it).
