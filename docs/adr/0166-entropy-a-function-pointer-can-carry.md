# Entropy a function pointer can carry

`entropy` answers `![n]u8` with `n` comptime, which is the right shape for the
call it was built for: a v7 key, in the expression that uses it, on the stack,
allocating nothing.

It is the wrong shape for a **vtable**. A function pointer has to name one
return type, so a Scope that was type-erased to cross one can carry exactly one
width — the port that reported this wrote
`anyerror![id.Uuid.v7_entropy]u8` into its vtable and noted that the second
caller wanting a different number of bytes has nowhere to go.

**Type-erasing a Scope is not exotic.** Zig has no closures, so a reaction — a
callback stored in a list and run later — is a function pointer, which cannot be
generic over the Scope it will be handed. The way out is the one
`std.mem.Allocator` takes: a pointer plus a table of `arena` and `str`. Anybody
who stores a callback arrives here, and they arrive at the same line.

## What it does now

`entropyInto(buf: []u8) !void`, on `Ctx` and on `Run`, beside the existing
`entropy`. Same syscall, same Bulkhead on the request side, same `error.NoIo`
off it; the width is a value rather than a type. `entropy` is now written in
terms of it, so there is one implementation and not two that can drift.

## Why not replace `entropy`

Because the comptime spelling is better where it fits, and it fits nearly
everywhere:

```zig
const key = id.v7(try c.entropy(id.Uuid.v7_entropy), nilo.nowMillis());
```

Against `entropyInto` that is a declared buffer, a statement, and a name for
something with no meaning. The array version stays the one the guide shows; the
slice version is what a vtable, a loop over widths, or a caller reading a length
from configuration uses.

## Consequences

- Two methods, four lines each, no new state and no allocation.
- **It does not remove a vtable entry, and the win is not that it might.** A
  caller that erases a Scope still needs one, because `entropyInto` reads the
  Run's own `Io`. What changes is the entry's *signature*: the old one was
  frozen at whatever single width its first caller wanted, and this one takes
  the width as a value, so the second caller — a session token, a v4 — has
  somewhere to put its number. One entry that fits every width is worth more
  than one entry fewer.
- Nothing on any measured axis: it is the same call, and `entropy` still
  compiles to the same thing because the array is still on the caller's stack.
- The Scope header in `core/scope.zig` says a vtable was rejected "to buy a
  polymorphism nobody has asked for". Somebody has now asked. This does not
  reopen that decision — nilo still hands out no vtable, and the shape is still
  checked while compiling — but it stops nilo's own API from being the reason an
  application cannot build one.
