# The clock, entropy, and a UUID

**Core provides the current time, randomness comes through the event loop, and a UUID is a format built from both without owning either.**

**Guide:** [Identifiers](../guide/id.md) · **Reference:** [What time it is](../reference/core.md#the-clock), [`c.entropy`, `c.entropyInto`](../reference/ctx.md#reading), [`nilo_id`](../reference/id.md)

The code is `core/clock.zig`, `http/ctx.zig` and `http/bulkhead.zig` (`randomSecure`), and `id/uuid.zig`.

## Overview

```
core/clock.zig      nowMillis(), nowMicros()      no Io, a vDSO read on every platform
http/bulkhead.zig    c.entropy(n) / c.entropyInto(buf)   parks the fiber, an App-layer call
id/uuid.zig          v7(entropy, ms)     the format only, and its own clock read for v7Now
```

The clock is in Core because two layers below the App needed it (`nilo_sql`'s `Timestamp.now()` and `nilo_id`'s millisecond) and reading it never waits. Entropy is one layer up, on `Ctx`, because a real operating-system call can wait, and only the App has a loop to absorb that wait. `id.v7Now(scope)` combines the two for any scope that can supply `entropy`, and reads the clock itself, because `nilo_id` cannot import `nilo_core` without leaving its layer.

## Rules

1. **`nilo_core.nowMillis()`, `nowMicros()` and `monotonicMicros()` are free functions, not methods on a Scope.** Nobody owns the time: there is no lifetime to carry and nothing to release, so a Scope has nothing to hold. [ADR 041](../adr/041-core-knows-what-time-it-is.md)
2. **The layering question is "does it need the event loop", not "does it do IO".** Reading the clock is technically a syscall, but in practice it reads a memory page the kernel keeps mapped, so a fiber never waits on it. That is why it can live in Core, even though `nilo_core` does none of the App's IO. [ADR 041](../adr/041-core-knows-what-time-it-is.md)
3. **The clock also works on Windows**, through `RtlGetSystemTimePrecise` and `RtlQueryPerformanceCounter`, which read the page the kernel maps into every process, the same reasoning as the vDSO on Linux. This does not make an Engine run on Windows; it means the three layers below the Engine are already correct there. [ADR 041](../adr/041-core-knows-what-time-it-is.md)
4. **The unit is in the function name.** `nowMillis` and `nowMicros`, not a bare `now()`, because an `i64` that does not say what it counts is exactly the mistake `sql/types.zig` exists to prevent. [ADR 041](../adr/041-core-knows-what-time-it-is.md)
5. **`Ctx.entropy(comptime n)` returns `[n]u8` through `bulkhead.randomSecure`, and it is deliberately a method, not a free function.** An operating-system call made directly from a fiber stops every request on that thread. Going through the Bulkhead parks the fiber on the blocking pool and tells the blocking detector this wait is not the handler's fault. [ADR 042](../adr/042-entropy-belongs-to-the-loop.md)
6. **Entropy is an App-layer call, because the only question about it is how to absorb the wait, and only the App has a loop for that.** A `Run` gets no entropy call of its own: a program that has a `Run` already has an `Io` and can call `std.Io.randomSecure` directly. [ADR 042](../adr/042-entropy-belongs-to-the-loop.md)
7. **`nilo_id` receives its randomness and its millisecond as arguments and fetches neither.** It has no Bulkhead to call, so `v4(entropy)` and `v7(entropy, ms)` are only the format. `zig build layering`, and the requirement that a plain `zig test id/id.zig` works, keep it that way. [ADR 038](../adr/038-a-module-sits-where-the-loop-puts-it.md), [ADR 042](../adr/042-entropy-belongs-to-the-loop.md)
8. **`entropyInto(buf)` sits next to `entropy(n)` on `Ctx` and `Run`, for callers that cannot fix the width at compile time.** A type-erased Scope passed through a function pointer needs a vtable entry whose signature is not tied to one caller's byte count. `entropy` is now written on top of `entropyInto`, so there is one implementation instead of two that could drift apart. [ADR 134](../adr/134-entropy-a-function-pointer-can-carry.md)
9. **`id.v7Now(scope)` reads the millisecond itself instead of calling `core/clock.zig`.** `nilo_id` imports nothing, and pulling in Core's clock would move the module out of its layer. `v7Now` calls `clock_gettime(.REALTIME, ...)`, the same clock Core reads, so both return the same instant. `v7` (with the millisecond passed in) stays, for backfilling a key for a row that already existed. [ADR 143](../adr/143-a-key-that-can-be-printed-and-a-key-that-can-be-made.md)
10. **`Uuid` prints with `{f}`, not `{s}`.** `{s}` is for byte slices and a `Uuid` is a struct. `format` writes the same thirty-six characters as `writeText`, and `{f}` is how nilo already prints `Str` everywhere in messages. [ADR 143](../adr/143-a-key-that-can-be-printed-and-a-key-that-can-be-made.md)
11. **`v7Now` only checks that the scope has `entropy`, not that it is a whole Scope**, because that is all it uses. A second definition of "what a Scope is", in a module that cannot import `core/scope.zig`, could drift from the one the compiler actually enforces. [ADR 143](../adr/143-a-key-that-can-be-printed-and-a-key-that-can-be-made.md)

## Decisions

| ADR | What it decides |
|---|---|
| [041](../adr/041-core-knows-what-time-it-is.md) | The clock lives in Core as a free function, and why that does not break "no event loop" |
| [042](../adr/042-entropy-belongs-to-the-loop.md) | Entropy is an App-layer call on `Ctx`, not a Core function or something `nilo_id` fetches |
| [134](../adr/134-entropy-a-function-pointer-can-carry.md) | `entropyInto` for a width chosen at run time, for callers going through a function pointer |
| [143](../adr/143-a-key-that-can-be-printed-and-a-key-that-can-be-made.md) | `Uuid.format` and `v7Now(scope)`, and why `nilo_id` reads its own clock instead of importing Core's |

Related topics: the layer rule that both the clock and entropy decisions extend and apply is [ADR 038](../adr/038-a-module-sits-where-the-loop-puts-it.md), see [layering](layering.md); `nilo_pw`'s salt reuses the same entropy call, [ADR 044](../adr/044-a-password-hash-is-gated-because-forgetting-is-silent.md); a `Session(T)`'s nonce reaches the same Bulkhead call by another path, see [cookies-sessions](cookies-sessions.md).

## Open questions

- **A per-thread entropy pool**, caching what `getrandom` returns instead of making a syscall every time, is open in [the todo list](../todo.md). It waits for a measurement that justifies the stored state, the fork hazard and the seeding step it would add.
