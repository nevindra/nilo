# Memory per request and per connection

**Request data has a type that cannot leak by accident, and an idle connection has a minimum memory cost that a handler can only add to, never reduce.**

**Guide:** [Deploying](../guide/deploying.md) (the tuning and "knowing whether it is working" sections) · **Reference:** [`Str`](../reference/core.md#str), [The App](../reference/app.md) (the `arena_keep` row)

The code is `core/str.zig` (`Str`, `Lifetime`, the walk that stamps a value), `core/scope.zig` (`arena()`, `str()`), and `http/serve.zig` (`waitForRequest`, the connection loop's own frame).

## Overview

```
request arrives ──► request arena (reset per request, arena_keep bytes retained)
                     every Str born here carries the connection's current Lifetime span

handler returns ──► Lifetime.end(): the span moves out of reach
                     a Str read afterwards either mismatches (Debug: trap fires) or is UB (Release)

connection idles ──► waitForRequest, the shallowest frame the connection has:
                      release the read/write buffers, and the stack if it comes back empty
                      floor: 4,669 bytes; 5,183 for a WebSocket, whose loop hands its own frame back
                      a handler that stays suspended adds its stack's high-water mark; one that returns adds nothing
```

## Rules

1. **Request data is a `Str`, never a bare `[]const u8`.** You cannot read its contents without asking explicitly, so there is no way to keep one by accident. `.keep()` is the one function that copies it into memory that outlives the request. [ADR 003](../adr/003-request-arena-and-the-str-type.md)
2. **In a Debug build, every `Str` is stamped with a `Lifetime` marker**, including those inside structs, optionals, arrays, mutable slices and the active field of a tagged union. Reading one after its request has ended stops the program with a message pointing to `.keep()`. A Release build has none of this and pays nothing. [ADR 003](../adr/003-request-arena-and-the-str-type.md)
3. **Every `Lifetime` gets its own span from a process-wide counter**, so two connections never share numbers. A stale `Str` from a finished connection either mismatches (the trap fires) or reads undefined memory; it can never silently return a plausible old answer, which was the old bug. [ADR 003](../adr/003-request-arena-and-the-str-type.md)
4. **A `Str` reached through something the walk does not cover has no marker.** A `const` slice or an untagged union is outside the trap's reach. The guarantee is a design that makes the mistake visible, not a proof the compiler enforces. [ADR 003](../adr/003-request-arena-and-the-str-type.md)
5. **A fiber that stays suspended inside a handler keeps its stack at its highest point.** zio commits stack pages as a fiber touches them and never releases them itself, so a WebSocket loop or a held stream pays every byte of stack it ever touched for as long as it waits. A handler that returns does not: the connection loop gives every page below its own wait back when the connection goes idle, so what the handler touched costs nothing at rest. [ADR 062](../adr/062-where-a-connection-waits-is-what-it-costs.md)
6. **A large stack buffer in a handler that returns is free at rest, and the arena is what to watch.** `var buf: [64 * 1024]u8` in a body-stream handler leaves an idle connection at the floor (read with `bench/mem.py --hold`: 4,685 bytes). What did cost was `c.stream()`'s own 4 KiB buffer, taken from the request arena and kept by `arena_keep`: 12,876 bytes a connection at the 16 KiB default, 4,715 with `.arena_keep = 0`. A buffer costs at idle where it is held, not where it is declared. [ADR 062](../adr/062-where-a-connection-waits-is-what-it-costs.md)
7. **What a waiting fiber costs depends on where it waits, not on whether its pages are released.** Releasing stack pages below the point where a connection actually waits achieves nothing, because the next wait faults them straight back in from the same depth. The fix was to move the wait itself into the connection loop's own, shallowest frame (`waitForRequest`). [ADR 062](../adr/062-where-a-connection-waits-is-what-it-costs.md)
8. **The rarely used half of request handling is deliberately `noinline`**, so its formatting code and argument tuples live in a frame that is gone once the connection waits, instead of in the frame that lives as long as the connection. [ADR 062](../adr/062-where-a-connection-waits-is-what-it-costs.md)
9. **A WebSocket handler hands its loop back to the connection loop instead of keeping it**, through `Ctx.upgrade(loop, state)`. `state` travels in the connection's own frame, up to `websocket.state_max = 128` bytes; anything larger goes in the request arena. [ADR 062](../adr/062-where-a-connection-waits-is-what-it-costs.md)
10. **The minimum is 4,669 bytes per idle connection and 5,183 per idle WebSocket, and both are a minimum, not a total.** A handler that stays suspended adds every byte of stack it touches, and a handler that returns adds what it left in the arena up to `arena_keep`. The benchmark server reads 4,678 at 10,000 connections. [ADR 062](../adr/062-where-a-connection-waits-is-what-it-costs.md)
11. **A response larger than `arena_keep` costs one page fault per page, on every request.** Once the arena block grows past the kept size it is given back, and the kernel zeroes it again for the next request that needs it: 257 minor faults for a megabyte at the 16 KiB default. [ADR 075](../adr/075-a-response-larger-than-the-arena-keep-is-a-page-fault-per-page.md)
12. **`arena_keep` is a `listen()` option, and its default stays where it is.** The memory it keeps is per connection, so raising the default would multiply by every connection a server holds, not only by the responses that need it. If you know your response size, set it just above your largest response, and no higher. [ADR 075](../adr/075-a-response-larger-than-the-arena-keep-is-a-page-fault-per-page.md)
13. **Filling a large buffer is the caller's cost, and nilo does not hide it.** `@memset` being slower than glibc's `memset` is for Zig to fix; nilo does not quietly replace a builtin the caller wrote with inline assembly. [ADR 075](../adr/075-a-response-larger-than-the-arena-keep-is-a-page-fault-per-page.md)
14. **What zio allocates for a connection's task is part of the idle figure, and a size class is a cliff.** zio takes a task of up to 384 bytes from its pool and sends a larger one to the allocator, which rounds to a power of two. The `Options` copy that `serve` once handed each connection (264 bytes) took the task to the 1,024 class and cost 512 bytes on every connection for two releases; the connection now reads its sizes through a pointer in the listener's state, and a `comptime` check in `http/engine/zio.zig` refuses an argument list that would cross the class again. [ADR 062](../adr/062-where-a-connection-waits-is-what-it-costs.md)
15. **Whether the plain park holds one page or two is a build step.** `zig build park-check`, run by `zig build test` on Linux x86-64, parks 48 connections and fails when a connection holds a second page in any build (every build is pinned at one page, `-Dtls` included since the run in `bench/result/http.md`, "A TLS build's plain listener holds one page"). It parks plain connections only: a connection that did the TLS handshake parks at 3,994 bytes and holds two, which `bench/mem.py --tls` reads. It fails on a crossing and not on drift: the park sat 288 bytes under the boundary on the default build and 64 on `-Dhttp2` when last read with a depth probe. [ADR 062](../adr/062-where-a-connection-waits-is-what-it-costs.md), [ADR 212](../adr/212-tls-is-an-option-a-build-asks-for.md)

## Decisions

| ADR | What it decides |
|---|---|
| [003](../adr/003-request-arena-and-the-str-type.md) | Request data is a `Str` over the request arena; the Debug-only lifetime trap and its per-connection counter |
| [062](../adr/062-where-a-connection-waits-is-what-it-costs.md) | A suspended fiber's stack stays resident at its highest point; the idle wait must happen in the connection loop's own frame for a release to help |
| [075](../adr/075-a-response-larger-than-the-arena-keep-is-a-page-fault-per-page.md) | `arena_keep`: a response larger than it costs a page fault per page, and why the default stays |

Related topics: the four trade-off axes that memory per idle connection is measured against are [ADR 017](../adr/017-the-trade-budget-has-four-axes.md) (topic principles, no page); why a header's name and value are `Str` instead of plain slices, and when the request head is borrowed instead of copied, is covered from the request side in [`request-input.md`](./request-input.md); a `-Dtls` build's extra page per idle connection comes on top of this page's minimum, see [`tls.md`](./tls.md); a WebSocket's upgrade design and state limit are covered from the protocol side in [`websocket.md`](./websocket.md); the Engine's one-fiber-per-connection model these numbers are measured on is [`engine.md`](./engine.md) (ADR 001).

## Open questions

- **The next fixed number to distrust is 4,669 (and 5,183).** It was off by 512 bytes for two releases because a connection's spawn arguments crossed a size class of the allocator under zio, nothing in the framework measured it, and `zig build park-check` now holds the depth but not that figure; `bench/release.py` is what notices. ADR 062 says so itself: the previous fixed figure, 8,767, went unquestioned for a year after the code around it changed. `bench/ws_idle.py` and the control routes exist so it can be re-measured instead of quoted.
- **A per-thread block cache under the arena** would close the remaining gap to a per-request allocator without anyone setting `arena_keep`. ADR 075 describes the design but it is not built: it changes where request memory lives, which is ADR 003's area.
