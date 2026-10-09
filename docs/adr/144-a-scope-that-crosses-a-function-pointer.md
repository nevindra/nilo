# A Scope that crosses a function pointer

**Status:** accepted
**Topic:** [typed-handlers](../design/typed-handlers.md)

## Context

[ADR 038](./038-a-module-sits-where-the-loop-puts-it.md) made the Scope a shape checked while compiling rather than an interface with a function table, and the reason holds: a vtable would put an indirect call on every allocation `nilo_sql` makes, to buy a polymorphism nobody asked for.

There is exactly one place that shape cannot reach. Zig has no closures, so erasing a Scope is what storing a callback comes to. A bus handler is a function pointer, and a function pointer names one type per argument, so a reaction cannot be generic over the Scope it runs under, and it has to run under a request and under a `Run`, or a reaction written for the server cannot be tested at all. A caller wrote the answer themselves: fifty-seven lines of a pointer, a vtable and an `of()` that fills it, in their own event-bus module. Anything with a bus, a queue or a job registry writes those lines again, and each copy is a fresh chance to hand a handler the wrong lifetime.

Erasing `arena`, `str` and entropy was not the end of it. Every event a later port writes carries who is acting: the value is declared with `nilo_resolve`, worked out once, and asked for by the bus on whatever Scope it is handed, and sixty commands pass nothing. The one seam that erases, a context opening work on another's board through a function pointer that takes an `AnyScope` to avoid an import, would have written the event as a person's, silently: nothing in a test admits it. The workaround was a field on the seam's input, filled by whoever still held the `*Ctx`, and it is the sixty-call-sites shape in miniature: the next erased seam has to remember the same thing by hand. `resolve` was deliberately left off the erasure at first, generic over the type asked for, so it could not cross a function pointer either, and that was true of the mechanism and wrong about the need.

## Decision

**`AnyScope`, a pointer and a table of six function pointers, made by whoever is about to cross a function pointer and paid for only there.**

```zig
pub const AnyScope = struct {
    _scope: *anyopaque,
    _table: *const Table,

    pub const Table = struct {
        arena: *const fn (*anyopaque) std.mem.Allocator,
        str: *const fn (*anyopaque, []const u8) Str,
        entropyInto: *const fn (*anyopaque, []u8) anyerror!void,
        requestId: *const fn (*anyopaque) ?Str,
        resolved: *const fn (*anyopaque, []const u8) ?*const anyopaque,
    };

    pub fn of(scope: anytype) AnyScope
};
```

### Why each entry is shaped the way it is

`arena` and `str` are what every Scope already promises. `entropyInto` is third because minting a key is what a reaction does that a query does not: `entropy` answers `![n]u8`, a function pointer names one return type, so a Scope crossing one can carry a single width and a second caller is stuck ([ADR 134](./134-entropy-a-function-pointer-can-carry.md)). `AnyScope.entropy(n)` is written on top of `entropyInto`, so a function body written against a `*Ctx` compiles against this unchanged, which is the whole point of the erasure and would be lost if the only call here were the buffer one. `requestId` is the fourth, and the second entry that is optional on the Scope behind it: a `Ctx` has one and a `Run` has none, and a reaction that dials out wants to name the request that fired it ([ADR 158](./158-a-request-id-goes-out-with-the-call.md)).

### The table carries a lookup by name, for `resolve` too

`resolved: fn (*anyopaque, type_name) ?*const anyopaque` is the fifth entry, carried the way `entropy` is: a lookup by type name in the table, with the typed `resolve(comptime V)` written on top of it on `AnyScope`'s side. That is the same move `entropy` makes over `entropyInto`, and the same move `Run.resolve` already made over its own list of given values.

`serial: fn (*anyopaque) ?u64` is the sixth, so that `sql.problem` asked through an erased Scope still tells this request's failure from the previous one on the connection ([ADR 117](./117-a-statement-that-failed-says-what-the-database-said.md)). Null for a Scope that keeps no count.

**What it answers is what the Scope behind it holds, and never more.** A `Run` answers from what it was given; a `Ctx` from what the request already resolved, through `resolvedNamed` (which `Ctx.cachedResolved` now reads through too); a hand-made Scope with neither answers nothing. An erased Scope cannot run a resolver: a resolver may take services, and a function pointer has no type to look them up by. So a `nilo_resolve` type nobody asked for before the erasure is `error.NotGiven`, the same answer a `Run` nobody told gives, and for the same reason. In practice the value a reaction wants is the one a middleware or the handler's own argument list resolved on the way in, which is before anybody erased anything, and a value nobody set has to be louder than a value nobody read.

**So a value is resolved in the middleware that proves it, not at the bottom.** The natural first draft declares the type with `nilo_resolve` and lets the bus ask for it, and a type only the bus ever asks for is `NotGiven` behind the pointer, because nobody up the stack asked first. The line that holds the property is a `_ = try c.resolve(V);` before `next.run` in the middleware that authenticated the caller, and a test that reads the actor off an event written behind the seam is what fails without it.

### A Scope may carry a deadline, and an erased one carries none

The shape `check` reads has one more optional declaration, `timeLeftMs() ?u32`, beside `routeName`, `serial` and `requestId`: the milliseconds the Scope's work has left, `null` for none, `0` once gone. `Ctx` declares it (it already did, as `c.timeLeftMs()`); a `Run` does not. `core.within(scope, own_ms)` is the shorter of a call's own bound and that, `core.timeLeftOf(scope)` the bare answer, and both are resolved with `@hasDecl` while compiling ([ADR 105](105-a-route-can-say-how-long-it-has.md)). **`AnyScope` leaves it out of the table**: a reaction runs after the request that fired it has been answered, and a deadline that crossed the pointer would cut its queries off at a time that meant something else.

## What was rejected

**Running the resolver through the erasure.** It would need the table to carry, per resolvable type, a function that finds that type's services on a `*Ctx`: a table entry per type the program declares, built where the erasure is made, for a call the erased side almost never makes. `NotGiven` is the honest answer, and it is loud rather than silent.

**A `resolveInto(type_name, buf)`.** The value's size is a property of the type, which the erased side names; a copy into a buffer would be a second copy of something the arena already holds, and the pointer is enough.

**A vtable on every Scope**, which is what `check`'s comptime shape refuses at the root ([ADR 038](./038-a-module-sits-where-the-loop-puts-it.md)). `AnyScope` is not a second way to write a handler and not the Scope growing an interface: a handler still takes a `*Ctx`, `AnyScope` is for a callback the program stores, and every call in nilo and in `nilo_sql` still takes `anytype` and still costs no indirect call.

## What it costs

| Axis | Cost |
|---|---|
| Allocations per request | zero. `of` is two stores, and the table is a comptime constant per Scope type, so it lives in `.rodata` with one copy per `(Scope, program)` pair. |
| Memory per idle connection | zero. Nothing here is held across a wait. |
| Throughput and p99 | zero on any path nilo itself takes. The indirect call is paid by whoever erased a Scope, on the calls they make through it: a reaction that allocates once pays one indirect call for it, and `resolve` is one more entry in a table that already existed. |
| Binary size | dropped entirely by a program that never names it, which is what putting `AnyScope` in `nilo_core` beside `Run` rather than inside the Engine buys. |

## Consequences

- The pointer inside `AnyScope` is the Scope's own, so an `AnyScope` may not outlive the `Ctx` or `Run` it was made from. In practice it is a local beside the call: `var erased = AnyScope.of(c); try reaction(&erased, payload);`. Nothing enforces it, the same as any `*Ctx` a program stashes, and the `Str` trap catches the case that actually bites: text that outlived its arena.
- A Scope with `entropy` and no `entropyInto` is refused by `of` with a sentence naming [ADR 134](./134-entropy-a-function-pointer-can-carry.md) rather than a message from inside `@ptrCast`.
- `AnyScope` passes `check`, so `db.select(Row, scope, …)` takes one and a reaction can query.
- `AnyScope.resolve(V)`, `Ctx.resolvedNamed` and `Run.resolvedNamed` are the same shape on every Scope, so an attribution value carried on the seam's own input is no longer needed: the seam carries nothing, and reading who is acting is one line on every side.
