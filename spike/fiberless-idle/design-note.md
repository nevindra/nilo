# A fiberless idle HTTP/1.1 connection: design note

Status: proposal with a prototype and numbers. Not merged, not in any ADR. The prototype is `0002-fiberless-idle.patch` in this directory; `README.md` says what it applies to and how to run it.

## The proposal

A connection that has been quiet past `idle_peek_ms` stops being a fiber. Today it parks its fiber in `waitForRequest` and holds a stack page (4,096 of the 4,678 bytes) plus a 512-byte task. Proposed: the connection loop returns at that point, the fiber ends, and what is left is a heap record (the socket, the reader and writer, the peer text, a pointer to the listener's state, one poll completion). A reactor fiber waits on a `zio.CompletionQueue` the poll was submitted to, and when the socket is readable it spawns a connection fiber over the same record, which runs `waitForRequest` again and finds bytes waiting.

Everything a connection keeps between requests that is not in that record (the arena, the `Lifetime`, the in-flight slot, the `Wake`) is made again by the new fiber. Nothing about the request path changes. A connection under load never parks, because the 200 ms peek is what decides to.

## What it measured (prototype, [`bench/result/http.md`](../../bench/result/http.md), "A prototype: an idle HTTP/1.1 connection with no fiber")

| | with fibers | no fiber |
|---|---|---|
| bytes per idle connection, 10,000 connections | 4,678 | 892 and 843 (marginal 771 and 672) |
| bytes, zio's default stack pool (60 s shrink) | 4,678 | 4,919, after the pool has decayed; 9,351 at 1,000 connections |
| wrk, 64 busy connections, req/s | 1,326,652 to 1,340,330 | 1,337,148 to 1,337,977 |
| wrk, 1,000 connections, 300 ms think time, req/s | 3,225 to 3,230 | 3,228 to 3,230 |
| same, server CPU over 12 s | 61 to 64 ticks | 57 to 58 |
| first request after a quiet spell, p50 (client of one) | 29.6 to 29.8 µs | 34.7 to 42.6 µs |
| same, p99 | 133 to 144 µs | 193 to 224 µs |
| stripped ReleaseFast, `nilo-hello` | 1,018,616 | 1,020,504 |

The prototype is a plain listener of a default build. `zig build test` on it: 2781 of 2811 tests passed (30 skipped), and the one failing step is `park-check`, which measures the park depth of a stack the connection no longer has (it would be removed or reread as the depth of a connection mid-request).

**Against ADR 017's four axes.** Memory per idle connection: 4,678 down to about 700 to 770 as a floor, better than 6 times, level with Bun.serve x1 (700) in `docs/comparison.md`. Allocations per request: unchanged on a busy connection; the first request after a quiet spell pays one more (the arena's first block, which a parked connection no longer keeps) and a fiber spawn, so `arena_keep` stops being a per-idle-connection cost. Throughput and p99: level on a busy connection, 5 to 13 µs slower at the median and 60 to 80 µs at p99 for the first request after silence, in an unloaded run; under 300 ms of think time at 1,000 connections it was level or better. Binary size: +1.9 KB.

## What it costs

1. **A fiber spawn on every wake.** zio's task is 192 bytes plus the arguments; with one pointer argument it comes from the pool (384-byte class) with no allocation. The stack is acquired from the stack pool, so the first touch of its pages is a fault if the pool released them. Measured above as the 5 to 13 µs.
2. **The stack pool's retention becomes the idle figure.** A fiber that ends returns its stack to zio's pool, which keeps what recent demand needed and shrinks by half every `shrink_interval` (60 s by default), and each retained stack holds the page its base frames touched. 10,000 connections that all idle at once leave 10,000 stacks, so the figure reads 4,919 once decayed and 9,351 while the pool is full. The prototype passes `stack_pool.shrink_interval = 1 s` to `Runtime.init`, which is an option, not a change to zio; that makes a burst of new fibers re-fault stack pages that a longer retention would have kept. The right shape is probably one `madvise` of a stack's pages in zio at release, upstream. That is a change outside this repository and the decision is the user's.
3. **Code.** About 220 lines in the prototype. A real one adds: an idle deadline for a parked connection (a timer completion in the record, 100 bytes, or a sweep with a deadline field and a list link, 24), the shutdown of parked connections (a list and a lock, 16 bytes a connection), a reactor per executor with `spawnInto(.local)` so ADR 199 still holds (one reactor behind one mutex is a ceiling on the wake rate), and tests for the peer closing while parked, a stop while parked, and a pipelined request landing as the fiber ends.
4. **A new row in the Waker's table** (`park`), which is the Engine's promise that a connection can be put down and picked up. It names no zio type, so ADR 001 holds; `http/engine/zio.zig` still is the only file that names zio.

## What it breaks or closes off

- **WebSocket, event streams, a held `bodyStream`, anything that suspends inside a handler** are not touched, and not helped: the fiber is the handler's, they never reach `waitForRequest`, and ADR 062's cost (5,183 for a WebSocket, a stack that stays at its high-water mark) still applies to them. The memory page keeps its rules 5 to 7 for those.
- **ADR 062** keeps its truth for suspended handlers and loses its reason to exist for an idle plain connection: the stack release, the page cliff and `zig build park-check` have nothing to measure on a connection with no stack. The depth would still matter for the first page of a connection that is mid-request, not at rest.
- **TLS.** The record layer, the key schedule and the sealing writer live in `runTls`'s frame today. Parked, they must move to the record: tls.zig's `Connection` plus the 49 KB of record buffers already given back at idle. I have not measured their size; a guess of 1 to 2 KB would put an idle TLS connection near 2 to 3 KB against 8,847 now, and would close the `-Dtls` extra page (4,109 bytes) by making the stack irrelevant. This is the largest piece of work and the one with the most unknowns (a record half-read when the fiber ends, `Wake.held`, a `close_notify`).
- **HTTP/2.** A connection holds a HPACK table, a stream table and flow-control windows in `h2conn.zig`'s frame, and it parks differently (it is woken by streams as well as by its socket, stage 6.3). It could keep its fiber, as it does now; nothing in this proposal needs it to change, and that is why the plain HTTP/1.1 case is the one proposed.
- **Per-fiber state that is bound once per connection**: `bulkhead.bindSlot` (the in-flight slot, ADR 006), `Lifetime`'s span (ADR 003), the Debug-only `Str` trap. Each is made again per fiber, so a `Str` kept across the park is stale by design, which is what `.keep()` already says.
- **Deadlines.** `Clocks` sets timeouts on the reader and writer, and `AutoCancel` cancels a fiber. A parked connection has neither, so the idle limit needs a new mechanism, and an idle limit is measured in seconds, which makes a periodic sweep enough.
- **Graceful stop** (ADR 028): parked connections are not in the `connections` group, so `drain` does not see them and they must be listed to be closed. The prototype does not do this.
- **The Engine is no longer "a fiber per connection" in prose.** README and ADR 028 say one; it becomes "a fiber per connection in flight".
- It closes off nothing for a later `io_uring` engine; it is closer to what such an engine would do (a registered buffer ring and no per-connection fiber).

## What nginx, h2o and Go do

Measured in this repository (`docs/comparison.md`, an older run): Bun.serve 338 to 700 bytes an idle connection, Node 10,543, http.zig 11,218, Go net/http 19,897, Rust axum 19,259, nilo 8,767 then and 4,678 now. From the projects' own documentation and design, not measured here: nginx keeps an idle keep-alive connection as a connection struct and two event structs on an epoll registration with the request pool and buffers freed (its own site says about 2.5 MB for 10,000 idle keep-alive connections, which is about 250 bytes; quoted from memory, not re-read); h2o is the same shape on its own loop, a socket object and a small connection struct per connection. Go runs a goroutine per connection blocked in `read`, which is the shape nilo has now, with a 2 KB-and-growing stack and buffered readers that net/http returns to a pool between requests. So the proposal moves nilo from Go's model to nginx's for the idle case and keeps Go's for the busy one, which is the combination the other two do not have (they have no fiber to keep for a handler that wants to read as straight-line code).

## What I would recommend, and where this is weak

Recommend building it for plain HTTP/1.1 and TLS together, in that order, behind no flag, as a replacement for the stack-release path rather than beside it. The reason is the third principle in `CLAUDE.md`: ADR 062's machinery (the peek, the stack release, the page cliff, `park-check`) exists to approximate what this does outright, and keeping both is the two-shapes problem ADR 062 itself refuses for WebSockets.

Where it is weak, and where I could be wrong: (a) every number above is from a default-build plain listener on one machine; the TLS saving is a guess. (b) The 700 to 770 bytes is a floor before the idle deadline, shutdown list and per-executor reactors, which add 40 to 140 bytes. (c) The stack pool's behaviour is the dominant effect on the reading, and the fix I would want is in zio, which is the user's call. (d) The wake is slower for the first request after a quiet spell, and a deployment whose clients each send one request a second would feel it at the margin; the throughput and p99 axes are level at the sample sizes here, but a 60 to 80 µs p99 step is not nothing and the unloaded run is noisy. (e) It does not help a WebSocket-heavy or stream-heavy deployment at all. (f) `park_mode` is a comptime switch in the prototype; making it unconditional means every Entry (h2, TLS) either parks or says why it does not.

If the number that matters to a deployment is idle connections per gigabyte, this is roughly 1.3 million against 230 thousand a gigabyte of process memory at 770 and 4,678 bytes (the kernel's socket memory is separate and none of it changes).

## What the prototype does not cover

TLS, HTTP/2 and gRPC; the idle deadline; stopping with parked connections; multiple reactors; `zig build test-all` (the ReleaseSafe gate); the fuzzers; the Debug-only `Str` trap across a park; unix sockets (the poll is on the handle, so it should work, untested); `max_connections` is respected because the capacity count is released only on close.
