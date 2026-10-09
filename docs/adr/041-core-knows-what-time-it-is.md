# Core knows what time it is

**Status:** accepted
**Topic:** [id-clock-entropy](../design/id-clock-entropy.md)

## Context

Two layers wanted the wall clock and neither could have it. `nilo_sql` had `Timestamp` since 0.2.0 and no `Timestamp.now()`, so a service filling `created_at` either wrote the integer by hand or left the column to a database default. `nilo_id` shipped `v7(entropy, ms)` in [ADR 038](./038-a-module-sits-where-the-loop-puts-it.md) and `Ctx` exposed no clock, so the millisecond was an argument a handler had nowhere to get.

Zig 0.16 is why it is a decision rather than a line of code. `std.time` holds constants and nothing else now: `milliTimestamp` is gone, and what replaced it is `Io.Clock.now`, which takes an `Io`. So on the face of it the clock is IO, and [ADR 038](./038-a-module-sits-where-the-loop-puts-it.md) says Core does none.

A second finding came from the same call once a program with no Engine turned up. A program on the Fitting and Service layers alone, `nilo_fetch` for the wire, `nilo_sql` for the file, `nilo_job` for the queue, no `nilo_http` anywhere, has no Engine to be unsupported by, and `std.Io.Threaded` runs on Windows. Cross-compiling one for `x86_64-windows` failed on exactly two lines in the whole dependency graph: a `@compileError` guard on each of the two clock functions, put there on the reasoning that Windows is not a platform the Engine supports either, so nothing would ever get as far as calling them. Everything else in the four modules compiled as it stood.

## Decision

**`nilo_core.nowMicros()` and `nowMillis()`**, in `core/clock.zig`, re-exported by `nilo_http` so a handler writes `nilo.nowMillis()`. `monotonicMicros()` sits beside them for measuring a duration.

### Free functions rather than calls on a Scope

`arena()` and `str()` are on a Scope because something has to *own* what they hand out: memory has to be released and text has to go stale. Nobody owns the time. There is no permission to ask for, no lifetime to carry and nothing to release, so there is nothing for a Scope to be the holder of.

### The layering rule is the loop, not IO

**[ADR 038](./038-a-module-sits-where-the-loop-puts-it.md)'s *no IO at all* is amended to *needs no event loop*.** Reading a clock is a syscall by the letter and a read from a page the kernel keeps mapped in practice: no context switch, nothing to wait on, so nothing for a fiber to be parked on. `http/bulkhead.zig` has read the monotonic clock exactly this way since ADR 013, and for exactly this reason.

The amendment is small and worth making explicitly, because needing the loop is the question the layering has always actually been asking. "Does it do IO" was a proxy that happened to agree until now. The rule that survives is the one ADR 038's table is built on, and the next thing that turns up gets asked the real question.

### It reads the clock on Windows too

**`nowMicros` and `monotonicMicros` read the clock on Windows** the way `std.Io.Threaded` does: `RtlGetSystemTimePrecise` for the wall clock, in 100 ns units from 1601, and `RtlQueryPerformanceCounter` over `RtlQueryPerformanceFrequency` for the monotonic one. Both are reads from `KUSER_SHARED_DATA`, the page the kernel maps into every process: the same argument this ADR makes for the vDSO, and the reason this stays in Core rather than moving up a layer. Neither function takes an `Io` and neither gains any arithmetic; a program with an Engine still never runs on Windows, and this does not change that, it changes that the three layers under the Engine already did.

### The unit is in the name

`created_at: i64` not saying whether it counts seconds or microseconds is the mistake `sql/types.zig` was written to stop, and a clock called `now()` would make it again one layer down.

## What was rejected

**Put it on the Bulkhead.** That file is the entire contract nilo asks of an Engine, and reading a clock asks an Engine for nothing: it would be the first entry there the Engine does not implement. It also fails the case that started this, since `nilo_sql` cannot reach the Bulkhead, so `Timestamp.now()` would still be impossible and the Service half of the problem would be untouched.

**Put it on the Scope.** Then every Scope has to have a clock, including the ones that only ever wanted an arena, and `db.select` would take a shape with three calls in it to use two. The Scope is two calls because two is what `nilo_sql` asked for; growing it for an unrelated caller is how a shape becomes an interface.

**A `nilo_time` tool module.** Two functions with two callers in two different layers is Core's own membership rule, not a case for a module boundary with a build row attached. It would also invite a zone-as-history date library that the expensive half of `sql/types.zig` refuses at length; two functions in Core read as knowing what time it is, a module called `nilo_time` reads as an offer to build the rest.

**Move `sql.Timestamp` down instead.** ADR 038 said `Timestamp` stays in `nilo_sql` until something outside it wants to *make* one, and this was not that moment (it became one later: a handler reads and writes a `Timestamp` in a body with no database in the build, so [ADR 057](./057-percent-is-needed-by-two-layers.md) moved it and `Date` down, with the column names left behind in `nilo_sql`): the clock answers an `i64`, so `Timestamp.now()` is one line in `sql` and nothing moves. The `Uuid` precedent does not apply, because a `Uuid` is a value a column happens to hold and a `Timestamp` is a column type a handler happens to return.

**`CLOCK_REALTIME_COARSE`.** Measured and not taken: 2ns against 15ns, and it moves once a millisecond. It would make `nowMicros` a lie about its own resolution while `nowMillis` would be perfectly happy with it. The 13ns buys a branch, a Linux-only path and two clocks to explain, on a call nothing in the framework made per request at the time. The note is in `core/clock.zig` so that whoever turns up reading the clock in a loop knows where the 13ns went.

**Return an error rather than panic when the clock cannot be read.** `CLOCK_REALTIME` with a valid pointer has no failure POSIX admits to. An error union would put a `try` on every call site forever to handle something that cannot happen, and returning the epoch instead would be a plausible wrong time, the one answer worse than stopping.

**Leave the Windows guard and tell the program to bring its own clock.** The two calls are made by `nilo_job`, `nilo_id.v7` and `sql.Timestamp.now`, none of which the program calls directly. It would have to fork three modules to supply ten lines.

**Take an `Io` and call `Io.Clock.now`.** A Scope owns nothing about the time, and threading an `Io` through `id.v7` to read a page is the wrong cost for the right answer.

## What it costs

| Axis | Cost |
|---|---|
| Allocations per request | none. Nothing is on the request path; the framework never calls this itself. |
| Memory per idle connection | none. No new field on `Ctx`. |
| Throughput and p99 | none for anything that does not call it; **15ns** for a caller that does, on `ReleaseFast`, best of five runs of five million, and the same 15ns whether or not the build links libc. `http/date.zig` now makes this call once per response for the `Date` header (ADR 197), which is where that 15ns goes. |
| Binary size | zero, measured. `example-hello` 885,504, `example-rest` 1,031,744, `nilo-hello` 890,384, byte for byte the same as the parent commit, stripped `ReleaseFast`, built in a `git worktree`. Nothing calls the clock, so nothing links it; the Windows path adds no code to a build that never targets Windows. |

`std.os.linux` reaches the vDSO the same way libc does now, so a comment in `http/bulkhead.zig` recording a 5ns-against-600ns gap between the two no longer describes anything: re-measured on Zig 0.16, `CLOCK_REALTIME` and `CLOCK_MONOTONIC` are both 15ns whether or not the build links libc, and `CLOCK_REALTIME_COARSE` and `CLOCK_MONOTONIC_COARSE` are both about 2ns. What survives is the other half of that comment, and it is the half the code depends on: the coarse clock really is about eight times cheaper than the plain one, which is why the blocking detector reads it four times a request. The comment was corrected in place rather than deleted, because a number that turned out false is worth more than the space it takes.

## Consequences

- `sql.Timestamp.now()` exists, so `created_at` is a field a handler can fill rather than a database default it has to remember to set.
- `nilo.nowMillis()` is the second argument `id.v7` wanted, so a sortable key is now one expression in a handler.
- `core/clock.zig` names `std.posix` on every platform but Windows, and `std.os.windows` there; neither guard remains.
- Nothing here measures a duration, and nothing should. A wall clock moves when an operator moves it; the monotonic one behind the Bulkhead is what [ADR 013](./013-handlers-must-not-block-the-thread.md) uses and it stays there.
