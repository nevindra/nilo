# Core knows what time it is, and the layering rule is the loop rather than IO

Two layers wanted the wall clock and neither could have it.

`nilo_sql` has had `Timestamp` since 0.2.0 and no `Timestamp.now()`, so a
service filling `created_at` either wrote the integer by hand or left the
column to a database default. `nilo_id` shipped `v7(entropy, ms)` in
[ADR 0042](./0042-the-bottom-layer-holds-more-than-one-module.md) and `Ctx`
exposes no clock, so the millisecond was an argument a handler had nowhere to
get.

Zig 0.16 is why it is a decision rather than a line of code. `std.time` holds
constants and nothing else now — `milliTimestamp` is gone, and what replaced it
is `Io.Clock.now`, which takes an `Io`. So on the face of it the clock is IO,
and [ADR 0041](./0041-a-module-sits-where-the-loop-puts-it.md) says Core does
none.

## What was decided

**`nilo_core.nowMicros()` and `nowMillis()`**, in `core/clock.zig`, re-exported
by `nilo_http` so a handler writes `nilo.nowMillis()`.

**Free functions rather than calls on a Scope**, and that is the shape of the
decision rather than a detail. `arena()` and `str()` are on a Scope because
something has to *own* what they hand out — memory has to be released and text
has to go stale. Nobody owns the time. There is no permission to ask for, no
lifetime to carry and nothing to release, so there is nothing for a Scope to be
the holder of.

**ADR 0041's *no IO at all* is amended to *needs no event loop*.** Reading a
clock is a syscall by the letter and a read from a page the kernel keeps mapped
in practice — no context switch, nothing to wait on, so nothing for a fiber to
be parked on. `http/bulkhead.zig` has read the monotonic clock exactly this way
since ADR 0034 and for exactly this reason.

The amendment is small and it is worth making explicitly, because **needing the
loop is the question the layering has always actually been asking.** "Does it
do IO" was a proxy that happened to agree until now. The rule that survives is
the one ADR 0041's table is built on, and the next thing that turns up gets
asked the real question.

**The unit is in the name.** `created_at: i64` not saying whether it counts
seconds or microseconds is the mistake `sql/types.zig` was written to stop, and
a clock called `now()` would make it again one layer down.

## Why not the alternatives

**Put it on the Bulkhead.** That file is *the entire contract nilo asks of an
Engine*, and reading a clock asks an Engine for nothing — it would be the first
entry there that the Engine does not implement. It also fails the case that
started this: `nilo_sql` cannot reach the Bulkhead, so `Timestamp.now()` would
still be impossible and the Service half of the problem would be untouched.

**Put it on the Scope.** Then every Scope has to have a clock, including the
ones that only ever wanted an arena, and `db.select` would take a shape with
three calls in it to use two. The Scope is two calls because two is what
`nilo_sql` asked for; growing it for an unrelated caller is how a shape becomes
an interface.

**A `nilo_time` tool module.** Fifteen lines with two callers in two different
layers is the definition of Core's own membership rule, and a module boundary
for two functions is ceremony with a build row attached. It would also invite
the thing `sql/types.zig` refuses at length — a zone is a history rather than
an offset, and the expensive half of a date library has nothing to do with
knowing what time it is. A module called `nilo_time` would be read as an offer
to build that; two functions in Core are not.

**Move `sql.Timestamp` down instead.** ADR 0042 said `Timestamp` stays in
`nilo_sql` until something outside it wants to *make* one, and this is not that
moment: the clock answers an `i64`, so `Timestamp.now()` is one line in `sql`
and nothing moves. The `Uuid` precedent does not apply, because a `Uuid` is a
value a column happens to hold and a `Timestamp` is a column type a handler
happens to return.

**`CLOCK_REALTIME_COARSE`.** Measured and not taken: 2ns against 15ns, and it
moves once a millisecond. It would make `nowMicros` a lie about its own
resolution while `nowMillis` would be perfectly happy with it. The 13ns buys a
branch, a Linux-only path and two clocks to explain, on a call nothing in the
framework makes per request — it is the caller's own, made once or twice. The
note is in `core/clock.zig` so that whoever turns up reading the clock in a
loop knows where the 13ns went.

**Return an error rather than panic when the clock cannot be read.**
`CLOCK_REALTIME` with a valid pointer has no failure POSIX admits to. An error
union would put a `try` on every call site forever to handle something that
cannot happen, and returning the epoch instead would be a plausible wrong time
— the one answer worse than stopping.

## What it costs

Put against the four axes
([ADR 0018](./0018-the-trade-budget-has-three-axes.md)).

| Axis | Cost |
|---|---|
| Allocations per request | **none.** Nothing is on the request path; the framework never calls this. |
| Memory per idle connection | **none.** No new field on `Ctx`. |
| Throughput and p99 | **none** for anything that does not call it; **15ns** for a caller that does. |
| Binary size | **zero**, measured. |

`example-hello` 885,504, `example-rest` 1,031,744, `nilo-hello` 890,384 —
byte for byte the same as the parent commit, stripped `ReleaseFast`, built in a
`git worktree`. Nothing calls the clock, so nothing links it.

The 15ns is best of five runs of five million in `ReleaseFast`.

## What the measurement corrected

**A comment in `http/bulkhead.zig` recorded a gap that no longer exists.** It
said reading the clock through `std.posix.system` rather than `std.os.linux`
was *the difference between the vDSO and a real syscall once libc is linked*,
and put numbers on it: 5ns the right way, 600ns the wrong way. Re-measured on
Zig 0.16, on this machine:

| Clock | linking libc | not linking libc |
|---|---|---|
| `CLOCK_REALTIME` | 15ns | 15ns |
| `CLOCK_REALTIME_COARSE` | 2ns | 1ns |
| `CLOCK_MONOTONIC` | 15ns | 15ns |
| `CLOCK_MONOTONIC_COARSE` | 2ns | 1ns |

`std.os.linux` reaches the vDSO too now, so the libc distinction is worth
nothing and the 600ns is gone. What survives is the *other* half of that
comment, and it is the half the code depends on: the coarse clock really is
about eight times cheaper than the plain one, which is why the blocking
detector reads it four times a request. The comment is corrected in place
rather than deleted, because a number that turned out false is worth more than
the space it takes.

This is the second time a premise about the standard library has decided a
design in this repository within a week, and the shape is the same both times:
**measure the platform before designing around it, not after.** The first was
entropy and the clock becoming IO at all
([ADR 0042](./0042-the-bottom-layer-holds-more-than-one-module.md)); this is
the correction that came from checking it.

## Consequences

- `sql.Timestamp.now()` exists, so `created_at` is a field a handler can fill
  rather than a database default it has to remember to set.
- `nilo.nowMillis()` is the second argument `id.v7` wanted, so a sortable key
  is now one expression in a handler.
- Core has a call that names `std.posix`. It is guarded to say so on Windows
  rather than fail obscurely, and because Zig analyses nothing that is never
  called, a Windows program importing `nilo_core` for `Str` alone still
  compiles.
- Nothing here measures a duration, and nothing should. A wall clock moves when
  an operator moves it; the monotonic one behind the Bulkhead is what
  [ADR 0034](./0034-the-thing-a-handler-holds-is-watched-at-run-time.md) uses
  and it stays there.
