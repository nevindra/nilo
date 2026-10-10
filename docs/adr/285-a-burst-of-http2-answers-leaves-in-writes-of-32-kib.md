# A burst of HTTP/2 answers leaves in writes of 32 KiB

**Status:** accepted
**Topic:** [framing](../design/framing.md)
**Extends:** [ADR 260](./260-a-request-on-http2-runs-from-its-headers.md).
**Applies:** [ADR 017](./017-the-trade-budget-has-four-axes.md),
[ADR 062](./062-where-a-connection-waits-is-what-it-costs.md),
[ADR 201](./201-a-response-is-flushed-before-the-connection-waits.md).
**Found by:** [HttpArena](https://github.com/MDA2AV/HttpArena)'s `json-h2c` profile, where nilo sent 6.2 KB a TCP segment against the leader's 50.8 KB and the load generator spent 3.4 times its CPU a request reading nilo (`bench/result/http.md`, "Why the board's HTTP/2 run sat below the rig's projection, and what a burst's writes cost").

## Context

An HTTP/2 connection answers every stream that finished since it last waited and flushes once before it waits again (ADR 201). That flush was meant to make a burst one write. It did for small answers, which fill the connection's 4 KiB write page dozens at a time, and not for answers of a few kilobytes: `std.Io.Writer` drains its buffer and the bytes it was handed together whenever they do not fit, so an answer larger than the room left in the page went to the socket at once. A burst of thirty-two 4 KB JSON answers left as about thirty `writev`s, and each one was a read for the client.

The page is a page because it is most of what an idle connection holds (ADR 062), so making it larger moves the hard axis for every connection, HTTP/1.1 and idle ones included.

## Decision

**While an HTTP/2 connection answers a burst it may write into a burst buffer of 32 KiB instead of its page** (`http/burst.zig`). The buffer goes to the connection's writer, behind what the page already held, when it is full and at the flush before the wait; that flush gives it back to the allocator (`Conn.flushOut`).

**It is taken by the first answer whose body is 1 KiB to under 16 KiB and does not fit the room left in the page** (`Conn.roomFor`, before the answer's `HEADERS`). Smaller answers already share a page's write with many others. A body of 16 KiB or more is a frame's worth and is written from where it lies (`framing.Collected.borrow_from`); copying it once more costs more than the write it saves.

**32 KiB is the allocator's largest slab class**, so the buffer is a slab taken and returned, never a mapping of its own. The header of the `Burst` is inside those 32 KiB.

## What it costs

- **Memory per idle connection: nothing.** An idle connection never holds a burst buffer; `park-check` and `bench/mem.py --h2` read the same as before.
- **Memory while answering:** 32 KiB a connection for the length of a burst of mid-sized answers.
- **Allocations:** one a burst, not a request, and none on a burst of small answers or on HTTP/1.1.
- **CPU:** each answer that takes the buffer is copied once more. On the rig that is paid for many times over by the writes it saves (below).
- **Binary size:** in `-Dhttp2` builds only; the default build has no HTTP/2 connection to link it.

Measured on the local rig (server on 8 threads, h2load on 8 others, the tree before against this one, two interleaved rounds, `bench/result/http.md`, "A burst of HTTP/2 answers leaves in writes of 32 KiB"): `json-h2c` from 1.17M to 1.63M requests a second at 1,024 connections and from 0.95M to about 1.5M at 4,096, server CPU from 5.9 to 4.6 µs a request; `h2c`, `h2` over TLS and unary gRPC unchanged or slightly better; `static-h2` at 1,024 connections within 2%.

## What was rejected

**Lend each body to one vectored write at the flush instead of copying it.** The body lives in its stream's arena, so the stream could not be recycled until the flush; every request in a burst then made a stream and an arena of its own where one was reused, and the server's CPU a request rose from 5.99 to 7.30 µs while the client's fell.

**A larger `write_buffer`.** 4.35 µs a request against this buffer's 4.59, but every connection would hold it for its whole life, which is ADR 062's axis spent on connections that never answer a burst, and past 32 KiB it is an `mmap` for every connection opened.

**A burst buffer of 12 KiB.** 6.05 µs, no better than the page, since it is still a write for every three answers.

**A burst buffer for every answer.** A unary gRPC call went from 2.37 to 2.70 µs and `static-h2` over TLS at 1,024 connections from 27.1 to 30.1 µs: the first already shared its writes, the second paid a copy of 16 KiB frames for nothing. Hence the 1 KiB to 16 KiB window.

## Consequences

- `http/burst.zig`: `Burst`, a `std.Io.Writer` over a 32 KiB slab that drains into the connection's writer.
- `http/h2conn.zig`: `Conn.wire` is the Engine's writer and `Conn.out` is it or the burst; `roomFor` takes the burst, `flushOut` flushes and gives it back, and every flush before a wait goes through `flushOut`. The idle release reads `wire`.
- Tests: `burst.zig` holds the order and the write count of what goes through it; `h2conn.zig` holds that ten 5 KB answers leave in two writes with every body whole, and that small answers take no burst.
