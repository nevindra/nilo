# A Scope that crosses a function pointer

ADR 0041 made the Scope a shape checked while compiling rather than an interface
with a function table, and the reason holds: a vtable would put an indirect call
on every allocation `nilo_sql` makes, to buy a polymorphism nobody asked for.

There is exactly one place that shape cannot reach, and ADR 0166 already named
it in passing: *Zig has no closures, so erasing a Scope is what storing a
callback comes to.* A bus handler is a function pointer. A function pointer names
one type per argument. So a reaction cannot be generic over the Scope it runs
under — and it has to run under a request *and* under a `Run`, or a reaction
written for the server cannot be tested at all.

A caller wrote the answer themselves: 57 lines of `AnyScope` in
`platform/events/events.zig` — a pointer, a three-entry vtable, and the `of()`
that fills it. Anything with a bus, a queue or a job registry writes those 57
lines again, and each copy is a fresh chance to hand a handler the wrong
lifetime.

## What was added

```zig
pub const AnyScope = struct {
    _scope: *anyopaque,
    _table: *const Table,

    pub const Table = struct {
        arena: *const fn (*anyopaque) std.mem.Allocator,
        str: *const fn (*anyopaque, []const u8) Str,
        entropyInto: *const fn (*anyopaque, []u8) anyerror!void,
    };

    pub fn of(scope: anytype) AnyScope
};
```

Three entries, and the third is the one ADR 0166 was written for: `entropy`
answers `![n]u8`, a function pointer names one return type, so a Scope crossing
one can carry a single width and the second caller is stuck. `entropyInto` takes
a buffer. `AnyScope.entropy(n)` is written on top of it, so a function body
written against a `*Ctx` compiles against this unchanged — which is the whole
point of the erasure and would be lost if the only call here were the buffer one.

`resolve` is deliberately absent. It is generic over the type asked for, so it
cannot cross a function pointer either, and there is no `resolveInto` that would
mean anything.

## What this is not

**It is not the Scope getting a vtable.** Every call in nilo and in `nilo_sql`
still takes `anytype` and still costs no indirect call. This is one erased
wrapper, made by whoever is about to cross a function pointer, and paid for only
there.

**It is not a second way to write a handler.** A handler takes a `*Ctx`. This is
for a callback the program stores, which is a different thing and a rarer one.

## It borrows

The pointer inside is the Scope's own, so an `AnyScope` may not outlive the `Ctx`
or `Run` it was made from. In practice it is a local beside the call — `var
erased = AnyScope.of(c); try reaction(&erased, payload);` — which is the only
shape that is obviously right. Nothing enforces it; the same is true of every
`*Ctx` a program stashes, and the `Str` trap catches the case that actually bites
(text that outlived its arena).

## Against ADR 0018's four axes

- **Allocations per request: zero.** `of` is two stores. The table is a comptime
  constant per Scope type, so it lives in `.rodata` and there is one of them per
  `(Scope, program)` pair.
- **Memory per idle connection: zero.** Nothing here is held across a wait.
- **Throughput: zero on any path nilo takes.** The indirect call is paid by
  whoever erased a Scope, on the calls they make through it. A reaction that
  allocates once pays one indirect call for it.
- **Binary size: dropped entirely by a program that never names it**, which is
  what putting it in `nilo_core` beside `Run` rather than inside the Engine
  buys.

## Consequences

- `nilo.AnyScope` and `nilo_core`'s `AnyScope` are the same type, so a Service
  and a handler erase the same way.
- `AnyScope` passes `checkScope`, so `db.select(Row, scope, …)` takes one — a
  reaction can query.
- A Scope with `entropy` and no `entropyInto` is refused by `of` with a sentence
  naming ADR 0166 rather than a message from inside `@ptrCast`.
