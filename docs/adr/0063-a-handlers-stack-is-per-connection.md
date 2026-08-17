# A handler's stack is per connection, not per request

> **Half of this was overturned by
> [ADR 0071](./0071-where-a-connection-waits-is-what-it-costs.md).** The
> finding below — a suspended fiber holds every byte of stack its handler
> touched — is right and unchanged. The conclusion, "the shape that fits
> cannot be built because zio does not expose the running fiber's stack", was
> wrong on both counts: it can (`zio.coro.Coroutine.getCurrent()`), and doing
> it alone changes nothing, because the connection walks back down and sleeps
> deeper than the release ran. The floor is now **4,669 bytes**, not 8,767.
> Read this for the rule and 0065 for what came of it.

[ADR 0018](./0018-the-trade-budget-has-three-axes.md) makes memory per idle
connection a hard axis and gives it a number: **8,767 bytes, flat.**
`CLAUDE.md` repeats it and adds *"Every feature that costs per-connection
memory states the number in its own ADR."*

The number is right and it is a floor, not a total. What nobody had measured
is what a **handler** adds to it — and the answer turns out to be the most
surprising thing in this cycle.

## What was measured

`bench/sql_server.zig` grew three routes beside its database one, so that each
number has the next one standing next to it. 500 keep-alive connections, one
request on each, then read `VmRSS` while they sit idle:

| route | what it does | bytes per idle connection |
|---|---|---|
| `/health` | returns a constant `[]const u8`, no `Ctx` | **8,749** |
| `/fixed/:id` | a `Ctx`, a four-field struct, the JSON serialiser | **9,756** |
| `/people/:id` | the same, plus one `db.find` | **17,022** |
| `/deep/:id` | the same as `/fixed`, plus 8 KiB of stack touched — **no database** | **17,932** |

The first row confirms ADR 0018's figure to within eighteen bytes, which is
what a floor should do.

**The fourth row is the finding.** A handler that does nothing but `@memset`
an eight-kilobyte array on its own stack holds *more* per idle connection than
one that runs a query. So the 7.3 kB the database route appeared to cost is
not the database. It is how deep pg.zig's protocol code goes.

### It is one for one

| stack touched by the handler | bytes per idle connection | over the 9,756 baseline |
|---|---|---|
| 8 KiB | 17,924 | +8,168 |
| 32 KiB | 42,491 | +32,735 |
| 128 KiB | 140,787 | +131,031 |

**Every byte of stack a handler touches is a byte held for the life of the
connection**, to within a rounding error.

### What it is not

- **Not the arena.** `arena_keep` was swept from 0 to 64 KiB and changed
  nothing: at `arena_keep = 0` the database route still held 18,440 bytes per
  connection. Throughput across the whole sweep was 178k–186k req/s, which is
  noise — so the 16 KiB retained block is buying less than it looks like it
  is, and is not what this is.
- **Not a leak.** 500 connections × 1 request grew 8,384 kB; 50 connections ×
  10 requests — the same 500 requests — grew 868 kB; 50 × 100 requests, ten
  times the work, grew 876 kB. It scales with **connections**, not requests.

## Why

A connection blocked in `read` is a **suspended fiber**, and a suspended fiber
holds its stack. zio reserves 8 MiB of address space per stack and commits
256 KiB of it, but resident memory follows the pages actually *touched* — so
the high-water mark of a fiber's stack is resident from the moment it is
reached until the connection closes. Nothing lowers it. A handler that reached
128 KiB once holds 128 KiB while it waits for the next request that may never
come.

## What was decided

**The rule is written down and the axis is restated. Nothing is changed in the
engine, and the shape that fits is already in the repository one layer up — it cannot be
built yet.**

`waitOrRelease` in `http/app.zig` already gives a connection's read and write
buffers back with `MADV_DONTNEED` — and only once a short read has come back
empty, because doing it unconditionally measured **1.31M req/s down to 626k**,
a 52% loss from TLB shootdown across every thread. The gate exists, it fires
exactly when a connection goes quiet, and a busy connection never reaches it.
Releasing the stack below the frame pointer belongs in `releaseIdlePages`
beside the two buffers, at no extra cost on any path that matters.

What blocks it is one number: **the low end of the running fiber's stack.**

The block is narrower than it first looks, and worth stating precisely because
it decides what to ask upstream for. **The operation is already public**:
`zio.coro.stackRecycle(info)` does the `madvise` over `[limit, base)`, guard
page and uncommitted region excluded, and `zio.coro.Stack` — `StackInfo`, with
`base` and `limit` on it — is public too. What is missing is the *argument*.
There is no supported way to obtain the `StackInfo` of the **running** fiber:
`runtime.getCurrentTaskOrNull()` is `pub` but `zio.zig` imports `runtime.zig`
with `const` rather than `pub const`, and the one threadlocal that holds it is
called `current_context_DO_NOT_ACCESS_DIRECTLY` and is not re-exported. So a
public function's only argument cannot be publicly obtained for the case that
wants it — checked against `main` as well as the pinned `v0.17.0`, and filed
upstream as [zio#677](https://github.com/lalinsky/zio/issues/677).

Guessing a floor is not an option and it is worth saying why, because it is the
tempting shortcut: **zio carves 64 stacks out of one slab mapping.** An
`madvise` that ran a page past `limit` would succeed and zero another
connection's live stack — a corruption that is silent, rare, and in another
module. So this waits for zio to answer "where does this fiber's stack start",
and it is on the roadmap in exactly those terms.

### The guidance, which is the opposite of the usual

**In this framework the arena is cheaper than the stack.**

```zig
fn report(c: *nilo.Ctx) ![]const u8 {
    var buf: [64 * 1024]u8 = undefined;      // ✗ 64 KiB × every connection
    …
}

fn report(c: *nilo.Ctx) ![]const u8 {
    const buf = try c.arena().alloc(u8, 64 * 1024);   // ✓ reset per request
    …
}
```

A big stack buffer is the idiomatic Zig way to avoid an allocator, and here it
is a **per-connection** cost that never comes back, while the arena is reset
per request and capped at `arena_keep`. The intuition that "the stack is free"
is true per request and false per connection, and a server is measured per
connection.

## What it costs

Against ADR 0018's four axes: nothing. Three routes were added to a benchmark
and no module code changed.

## Consequences

- **ADR 0018's memory axis is restated**: 8,767 bytes is the floor, and a
  handler adds every byte of stack it touches. The flat number was true of the
  framework and never of a program.
- A service sizing itself for 10,000 idle keep-alive connections was working
  from 88 MB and the real figure for an ordinary database route is 170 MB.
- `arena_keep = 16 KiB` is now known to buy nothing measurable on this
  workload. It is left alone rather than tuned on one measurement, but it is
  no longer a number anybody should defend.
- **The next thing to distrust is the next flat number.** This one was correct,
  published, repeated in two files, and describing a case nobody deploys.
