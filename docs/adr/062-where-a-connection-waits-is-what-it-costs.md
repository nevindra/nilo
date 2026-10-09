# A handler's stack is per connection, and where it waits is what it costs

**Status:** accepted
**Topic:** [memory](../design/memory.md)

## Context

[ADR 017](./017-the-trade-budget-has-four-axes.md) makes memory per idle connection a hard axis, disclosed by every feature that spends it. What nobody had measured was what a **handler** adds on top of the framework's own floor, and the answer turned out to be the largest number in this cycle: a handler that does nothing but touch its own stack holds more per idle connection than one that runs a database query, because a suspended fiber does not give its stack back.

A first attempt to fix that (release the stack pages once a connection goes idle) changed nothing. `strace` showed the `madvise` firing on every idle connection, and `VmRSS` did not move by a byte. Finding out why is most of this ADR.

## Decision

### A suspended fiber holds its stack at its high-water mark

zio reserves 8 MiB of address space per fiber stack and commits pages as they are touched; nothing lowers the commit until the fiber exits or the fiber itself hands the pages back. A connection blocked in `read` inside a handler is a suspended fiber, so **every byte of stack a handler touches is resident for as long as that handler stays suspended, unless the wait is one that gives the pages below it back.** A handler that returns is another matter, and is the common one: the connection then waits in `waitForRequest`, the shallowest frame it has, and the pages below that frame are given back (the rest of this ADR). A route that touches 64 KiB of stack and returns costs 4,685 bytes an idle connection, the same as `/health` ([`bench/result/http.md`](../../bench/result/http.md)). What stays resident is the stack of a handler that does not return: a held event stream, a handler parked in a `Room`, or a WebSocket loop. Measured one for one: a WebSocket loop that `@memset`s 64 KiB (`/ws/deep` in `bench/ws_server.zig`) costs exactly 65,536 bytes more per idle socket than one that touches none, `5,183` against `70,719` ([`bench/result/http.md`](../../bench/result/http.md)).

**It is touched bytes, not declared ones.** `bench/s3_server.zig` has a route that pulls a megabyte into the request arena and one that declares `[64 << 10]u8` and streams the same megabyte through it, touching none of it beyond the buffer. Out to 10,000 connections: `/health` 4,674, `/o/1k` (1 KB, arena) 6,731, `/o/1m` (1 MB, arena) 8,782, `/stream/1m` 12,876. Rebuilding the streaming route with an 8 KiB buffer instead of 64 KiB moves the number by one byte. **The stack was not what that 12,876 measured**, and this ADR said it was until the reading was repeated on a route with no store behind it: a handler that touches 64 KiB of stack, with or without `c.bodyStream()`, and returns costs 4,685 at 10,000 connections, the floor; a handler that does only `c.stream()` and writes 16 KiB costs 12,876 (to the byte what `/stream/1m` read), and 4,715 with `.arena_keep = 0`. The extra is 8,191 bytes, 12,876 less the 4,685 of a returning handler read on the same server (`s3.md` subtracts its own `/health`, 4,674, and says 8,202; the 11 bytes are the two runs' floors). It is the stream's 4 KiB output buffer, which `c.stream()` takes from the request arena and `arena_keep` (16 KiB by default) then retains, touched, for the life of the connection ([ADR 075](./075-a-response-larger-than-the-arena-keep-is-a-page-fault-per-page.md)); with a 256-byte buffer it is 5,806, 1,121 over the floor. One buffer of 4,096 bytes is one page only if it starts on a page boundary, and an arena block does not: it covers two pages, and a 16 KiB response writes through both, which is the 8,192. That reading fits all three figures and I did not check the buffer's address.

**So a stack buffer that is gone when the handler returns is free at rest, and the arena is not:**

```zig
fn upload(c: *nilo.Ctx) !void {
    var buf: [64 * 1024]u8 = undefined;      // ✓ 0 bytes at rest once the handler returns
    …
}

fn live(c: *nilo.Ctx) !void {
    var buf: [64 * 1024]u8 = undefined;      // ✗ 64 KiB for as long as this handler stays suspended
    …                                         //   below it: a WebSocket loop, a held stream
}
```

A big stack buffer is the idiomatic way to avoid an allocator, and for a handler that returns it costs nothing once the connection is idle, because the connection then waits in `waitForRequest` and gives the pages below that frame back (the rest of this ADR). It is a per-connection cost for exactly as long as the handler holds the frame, which is the whole of a WebSocket's or an event stream's life. The cost tracks live connections that are *inside* such a handler, not requests served. What a returning handler leaves behind is what it put in the arena and `arena_keep` kept: that, not the stack, is the number to read for a route that answers and goes quiet.

### Releasing the pages is not the fix; where the wait happens is

The first attempt left the connection loop waiting exactly where it always had, four to six kilobytes down the call chain, and added a release of the pages below that point. The release ran, and cost nothing: **the connection then called `readHead` → `fillMore` and suspended again, faulting every released page back in from the same depth the release had just measured from.** The saving was real for about two microseconds.

> Where a fiber is suspended is what the connection costs, and it is not where the release runs.

So the wait moves up instead:

1. **The idle wait happens at the connection loop's own frame.** `waitForRequest` in `http/serve.zig` does the whole wait: peek for `idle_peek_ms`, release the read and write buffers and the stack if that comes back empty, then wait for the next request there, at the shallowest frame the connection ever has.
2. **The request's machinery is a frame of its own.** `App.serveRequest` is `noinline`; its `Ctx`, parsed head and route match are a callee's frame, below the sleeping one and dead by the time the connection parks.
3. **The cold half of a request costs nothing until it runs.** A format string builds its argument tuple and `Io.Writer` state in the frame of whatever it is inlined into, so `sendFailure`, `endAbandonedStream`, `warnFailedAfterAnswering`, `warnSocketFailed`, `Socket.deliver`, `handleControl` and `ping` are `noinline` for that reason alone.
4. **A WebSocket handler hands its loop back instead of keeping it**, which breaks [ADR 021](./021-a-websocket-is-a-handler-that-does-not-return.md)'s shape on purpose:

```zig
// before — the handler keeps the loop, suspended inside serveRequest
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

`Ctx.upgrade` answers the handshake, leaves a `Handover` in a slot the connection loop owns, and returns; the connection loop then runs the socket loop from its own frame, with the request unwound underneath it. `state` is what the handler knows and the loop needs, and it travels in the connection's frame with a ceiling of `websocket.state_max = 128` bytes; anything larger goes in the request arena, which stays alive for the loop's life, with a pointer carried across (`refusals/ws_state_too_big.zig`). 128 rather than the 32 it briefly was, because a `Str` is 40 bytes in Debug and 16 in `ReleaseFast` (the use-after-request marker compiles out), so a state that fit in Debug and not in release would be a mistake the optimize mode decides rather than nilo. **A `*Ctx` in the state is refused while compiling**, as the state itself or anywhere in its fields, optionals and arrays (`refusals/ws_state_is_ctx.zig`, `ws_state_holds_ctx.zig`): the Ctx lives in the frame that has unwound by the time the loop runs, so `c.upgrade(loop, c)` passed every other check and had the loop read the next request's memory. A pointer of the caller's is not walked, because what is behind it is the caller's to know.

### A blocker is a claim too, and it deserves the scrutiny a number gets

The stack release was first recorded as blocked on zio: no supported way to read the *running* fiber's `StackInfo`, filed as [zio#677](https://github.com/lalinsky/zio/issues/677). The call was public all along, one file over: `zio.coro.Coroutine.getCurrent()`, carrying `context.stack_info`. **A conclusion of "blocked on somebody else" is worth one more hour than it usually gets**, and this one had been written into an ADR, put on the roadmap and filed upstream before somebody read a different file in the same package.

Two later cases showed the rule aimed one step short of where it needed to: a blocker naming an upstream invites somebody to go and check it, but a blocker naming a design or a mechanism invites nothing, because there is visibly nothing to re-examine. `Upload.saveTo` was argued at length as blocked on a design, from a premise about nilo's own wrapper that nobody opened the manifest to check ([ADR 097](./097-a-file-is-written-by-the-engine.md)). The whole-body deadline was blocked on a union's arms, "zio's `Timeout` cannot express both", which is true and is a sentence about a type rather than about the slow client the feature exists to catch ([ADR 022](./022-a-deadline-belongs-to-an-operation-not-to-a-request.md)). An allowance's key was recorded as a choice between two named mechanisms, either arm true and the pair not exhaustive, and the answer was a third neither one named. So the rule generalizes past attribution, to grammar:

> **A requirement written as one mechanism reads as a blocker. Written as what it has to catch, it reads as a choice.**

An enumeration of alternatives is the easiest version of this to fall for, because weighing two named mechanisms looks like diligence, and the question of whether the pair is exhaustive never gets asked.

### What the engine allocates for a connection is part of the floor, and the page the park sits under is held by a build step

**The floor moved 512 bytes between v0.2.0 and v0.3.0 and nothing in the framework's frames did it.** `serve` handed each connection's task a copy of `Options` (264 bytes) among its spawn arguments. zio's task is its own 192-byte header, 8 bytes for the group and the argument tuple; one that fits 384 bytes comes from a pool, and a larger one from the allocator, which rounds to a power of two. The copy took the task from the 512 class to the 1,024 class, and every connection kept the extra half kilobyte resident: 5,188 bytes at 10,000 connections against 4,678 after. The connection now reads its sizes through a pointer in the listener's state (a heap copy made once in `serve`, because taking the address of the parameter itself defeats scalar replacement and cost 20 KB of binary), and a `comptime` check in `http/engine/zio.zig` fails the build when an argument list would cross the class again. The same change reads the same on every listener kind (`-Dtls`, `-Dhttp2`, h2c), in [`bench/result/http.md`](../../bench/result/http.md).

**Whether the plain park holds one page or two is a build step.** The stack of a plain idle connection stays at one page while its park depth is under the boundary and goes to two above it, found by adding ballast to the frame in steps of 16: 2,793 held one page and 2,825 held two in the `park-check` program (the benchmark server reads 2,809 and 2,841). Depth in the program, read with a store-only probe in `releaseIdleStack` that is not in the tree: 2,505 for the default build (288 under the boundary), 2,729 for `-Dhttp2` (64), 2,889 for `-Dtls` (96 over) and 2,937 for both (144 over). A figure of this kind moves by 16 or 32 bytes with anything that changes the layout, a print in the frame included, so read a depth as a place on the page and not as a constant.

`zig build park-check`, run by `zig build test`, **fails on the crossing and on nothing else**: it opens 48 connections, leaves them quiet past `idle_peek_ms`, counts in `/proc/self/smaps` the 256 KiB stacks holding more than one page and more than two, and compares the count with the build's pin. Every build is pinned at one page and fails if any connection holds a second (`-Dtls` was pinned at two until the run recorded in `bench/result/http.md`, "A TLS build's plain listener holds one page", which read 4,692 bytes a connection for its plain listener). A few bytes of drift costs nothing and does not trip it. The program is built `ReleaseFast` with the build's own flags (a Debug frame is several times larger). It runs only when host and target are both Linux on x86-64; anywhere else the step is named "skipped" and succeeds. The step parks plain connections only, so a TLS connection (3,994 bytes deep, two pages, [ADR 212](./212-tls-is-an-option-a-build-asks-for.md)) is read by `bench/mem.py --tls` and not by it.

## What was rejected

**Guessing a floor for the stack release rather than reading `StackInfo`.** zio carves 64 stacks out of one slab mapping; an `madvise` that ran a page past `limit` would succeed and zero another connection's live stack, a corruption that is silent and lands in another module.

**Releasing the stack pages without moving the wait.** The first position, and it measured no change at all: 8,767 bytes before and after. The pages come back the instant the fiber suspends again at its old depth, which is deeper than the release ever reached.

**Shaving the last 761 bytes off `receive` and the typed wrapper instead of changing the upgrade API.** It reaches one page and leaves 3,573 bytes against a 3,584 threshold: one future field on `Ctx` and every WebSocket in every deployment silently costs 4 KB more, with no test that could catch it. A number that passes by eleven bytes is not an invariant.

**Running the socket loop on a second fiber and letting the connection fiber die.** The `Wake` an engine posts to lives in the connection fiber's frame ([ADR 028](./028-a-spawned-fiber-belongs-to-the-server.md)), and the read and write buffers are the accept loop's; all three would have to move into the engine's contract. It also costs a spawn per upgrade, and zio's `stackRecycle` uses `MADV_FREE`, which is lazy and leaves the pages in `VmRSS` regardless.

**Keeping both upgrade shapes.** Two ways to open a WebSocket where one silently costs 4,096 bytes a connection more is the same "the option is a lie" problem ADR 021 refused a `max_message` over.

**Reading the stack's cost as a leak, or as the arena's fault.** For a suspended handler it scales with live connections, not with requests served, and sweeping `arena_keep` from 0 to 64 KiB changed nothing about it: the resident bytes are the stack's, not the arena's. That holds for the WebSocket loop it was measured on and not for a response stream, whose 12,876 was first read as the stack and is the arena's (above).

## What it costs

Against [ADR 017](./017-the-trade-budget-has-four-axes.md)'s four axes, before and after the connection-loop change, the two servers run alternately in one session so a machine that drifts drifts under both ([`bench/result/http.md`](../../bench/result/http.md) has every run):

| Axis | Before | After |
|---|---|---|
| Allocations per request | 1 | 1, unchanged: nothing here allocates |
| Memory per idle connection | 8,767 bytes | **4,669 bytes** |
| Memory per idle WebSocket | 9,290 bytes | **5,183 bytes** |
| Throughput, `GET /users/:id` | 1,420,424 req/s | 1,429,293, unchanged |
| p99, the same | 59–82µs | 58–98µs, unchanged |
| Binary size, stripped `ReleaseFast`, `examples/hello` | 886,680 B | **887,920 B**, +1,240 |

**Both numbers stand as the floor, and both are still that: a floor, not a total.** A handler that stays suspended adds every byte of stack it touches on top of them, as measured above; `/ws/deep` holds 70,719. A handler that returns adds none of its stack (the 64 KiB `bodyStream` route reads 4,685) and adds whatever it left in the arena, which `arena_keep` retains. The +1,240 bytes are the cold paths becoming real functions instead of inlined copies, plus one trampoline per distinct socket loop in the program; `examples/hello` has no WebSocket route and still pays it, which is the disclosure [ADR 017](./017-the-trade-budget-has-four-axes.md) asks for rather than a defence of it.

An open WebSocket no longer counts as a request in flight, because the loop now runs from the connection loop's own frame rather than inside `serveRequest`, which brings the shutdown counter into line with its own stated rule: requests, not connections, because a connection parked in a read is holding no work.

**The next flat number to distrust is this one.** 8,767 was correct, published, repeated in six files, and described a shape that had never been re-measured after the code around it moved; this one has `bench/ws_idle.py` behind it and five control routes beside it, and it should still be re-run rather than quoted.
