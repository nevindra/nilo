# A deployment fact is a value stated in the program or filled before listen

**Status:** accepted
**Topic:** [cors-proxy](../design/cors-proxy.md)
**Extends:** [ADR 088](./088-an-origin-is-a-fact-about-the-deployment.md) (CORS origins were the first deployment fact read at run time; the rate limit and the Content-Security-Policy are two more), [ADR 156](./156-a-route-can-say-how-much-body-it-takes.md) (`maxBody`'s `usize` is the same shape), [ADR 092](./092-an-allowance-is-a-table-sized-while-compiling.md) (the allowance's counts), [ADR 246](./246-the-headers-a-browser-reads-as-policy-are-one-block.md) (`secure`'s `.csp`)
**Applies:** [ADR 017](./017-the-trade-budget-has-four-axes.md), [ADR 062](./062-where-a-connection-waits-is-what-it-costs.md)

## Context

A rate limit is not the same number in staging and in production, and a Content-Security-Policy names the CDN and the API host of the deployment. Both were `comptime`: `allowance.with(.{ .per_window, .window_s })` took two `u16`s and `secure`'s `.csp` a string literal, so changing either meant rebuilding, the problem ADR 088 solved for CORS origins. Two middleware had already grown an answer each (`cors.reading`'s `Origins`, `maxBody`'s `*const usize`), and a third and fourth spelling was about to be written.

## Decision

**`nilo.Late(T)` is `union(enum) { value: T, held: *const T }`: a value the program states, or the address of one it fills before `listen()`.** It is the shape `Limited.Limit` already was, written once, and `maxBody` now uses it.

- **A literal still means a stated value.** Options that take a `Late` are read from a struct literal of any shape (`late.fill`), each field passed through `Late(T).of`: `100` is `.value`, `&settings.rate` is `.held`, a `Late` is itself. An option the struct does not have (`.perwindow`) is a compile error, which an `anytype` would otherwise swallow, and so is the address of the wrong type (`*u16` for a `u32`), with a sentence saying which type it takes.
- **`allowance.with` and `allowance.keyed`**: `.per_window` and `.window_s` are `Late(u32)`. A stated pair is settled while compiling as before (the two refusals for zero stay compile errors). A held pair is read on each request, and checked on each: zero, or a count the slot cannot hold, answers 500 naming the allowance. The slot type is settled while compiling, so a held count is bounded by the slot's widest counter: 1023 for an address (ten bits, the fingerprint keeps 28), 16,777,215 for a keyed one (24 bits each beside the window, which also makes a million an hour writable). A stated count keeps the narrowest slot it fits in. `.slots` stays a constant because it sizes `.bss`. The table identity rule stands: `with` and `keyed` hand the filled options to an inner generic, so two calls with the same options (a held pair compares by address) are one table, and `.name` tells them apart.
- **`secure`'s `.csp`** is `?Late([]const u8)`. A stated policy is part of the one comptime block, a store and nothing else, as before. A held policy is the block without that line and the policy set beside it with `setStaticHeader` (one more header slot, no copy), so a handler's own `Content-Security-Policy` replaces it by name as it replaces the block's line. The empty and control-byte refusals run on the first request as a 500, once passed they are not repeated.
- **No hook at `listen()`.** A middleware is a bare function pointer and nothing in `listen()` visits the chain, so what cannot be refused while compiling is refused by the middleware on the request path with a sentence, as `cors.reading` and `maxBody` already say theirs (ADR 088). A listen-time hook was not added: it would be a registry every middleware registers in, for three checks.
- **`allowance` sends `RateLimit-Policy` and `RateLimit` on every answer through it**, allowed or refused (draft-ietf-httpapi-ratelimit-headers: `"name";q=<count>;w=<seconds>` and `"name";r=<remaining>;t=<seconds to the window's end>`), beside `Retry-After` on a 429. `.headers = false` turns them off. `t` is when the window being counted ends, not when the quota is whole again (the window slides); `Retry-After` stays the whole window.

## What it costs, by axis (ADR 017)

- **Allocations per request**: none for a stated allowance. The `RateLimit` line is built in `Ctx.headerScratch`, 64 bytes of the Ctx (the request id's neighbour), and handed to `setStaticHeader`, which does not copy; a stated policy line is a comptime string. A held quota's policy line is worked out per request and pays one arena allocation (a held quota asked for a number that changes, and a 40-byte buffer per held pair on the Ctx would charge every request of every program). The allocation test in `behaviour.zig` still holds an allowance route at the JSON body's one.
- **Memory per idle connection**: 64 bytes on the Ctx, on the fiber's stack and not the connection; `zig build park-check` holds the page. A route that carries no allowance writes nothing into it.
- **Throughput and p99**: a stated allowance reads constants. A held one is two loads, a division by a run-time window length and a check per request; no measurement was taken, and the two ten-nanosecond figures are below the 10% bar by a wide margin against a 429-less request of several microseconds.
- **Binary size**: not measured. A program with no allowance links none of `announce`; one that states everything links the same arithmetic with run-time arguments.

## What was rejected

**A new `reading` entry point per middleware** (`allowance.reading(&rate, …)`, `secure.pagesReading(…)`), as `cors.reading` is. Two entry points per middleware and a third spelling for the same idea; CORS's list is a structure that needs its own type, a number and a string do not.

**Making the options `anytype` and reading whatever comes.** No refusal for a misspelt field, no named type. `late.fill` keeps the struct as the documentation and checks the names.

**A tagged union written out at the call site** (`.per_window = .{ .value = 100 }`). The break would have touched every caller for no gain; `Late(T).of` keeps the literal.

**`u16` counts widened for held values only.** The slot's counters are packed beside the fingerprint, so the bound is the slot's, not the integer's; the bound is stated per kind of allowance instead.

**A listen-time registry for checks.** See above.

**A `RateLimit` line in the arena for every answer.** One allocation on every request through an allowance, which the allocation budget forbids.

**Waiting on the draft.** The field names and syntax are the draft's current ones (`RateLimit-Policy`, `RateLimit` as structured fields); it is a draft, and a change to its syntax is a change to `announce` and this ADR.
