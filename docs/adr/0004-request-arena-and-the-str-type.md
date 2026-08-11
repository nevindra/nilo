# Request data uses a request arena, wrapped in the Str type

Every request gets a request arena: one bag of memory thrown away all at once when the request finishes. Users never hold an allocator and never call `deinit`. Fast, and no ceremony in user code.

The dangerous consequence: all request data dies when the handler returns. Users coming from Go or Node have never debugged a use-after-free — in both those languages, holding on to a string from a request is impossible to get wrong. In Zig nothing stops you, and the crash shows up at random, hours later, in production.

This is exactly GoFiber's most famous flaw, inherited from fasthttp: the rule "do not keep anything from `c` after the handler returns". Fixing it is one of the reasons zfast deserves to exist.

So request data is not a bare `[]const u8` but a **Str**:

1. You cannot get the contents without asking for them — there is no way to keep it "by accident".
2. `.keep()` copies into longer-lived memory, one function with an obvious name.
3. Debug builds attach a lifetime marker; using a Str from a request that has finished stops hard, with a message that names `.keep()`. Release builds drop the marker, at no cost.

## Every connection counts through numbers of its own

The trap compares a generation counter, and for a long time that counter started at zero on every connection. So it caught exactly the case it was tested with — stash a `Str`, read it back on the *same* keep-alive connection — and missed the case anybody would reach for first:

```
curl -X POST localhost:8787/stash -d '{"title":"secret"}'
curl localhost:8787/read            # → "secret", cheerfully
```

Two `curl` calls are two connections. The first one's `Lifetime` was gone, a new one started at zero in the same piece of fiber stack, and the stashed `Str` was holding zero — so the compare said *alive* and the stale bytes came back with nobody the wiser. The one mistake this type exists to catch, in the one shape a person would use to check that it worked.

Every `Lifetime` now takes a span of its own from a process-wide counter, so no two connections ever count through the same numbers, and a connection that ends moves its counter somewhere no live one can reach. What remains is that the marker still points at memory belonging to a finished connection: reading it is not something Zig defines, and the answer is either a mismatch (the trap fires, correctly) or a crash. Neither is the silent wrong answer, which was the thing worth fixing.

## Consequences

- The guarantee **cannot** be complete. Zig has no ownership system; there is no way to build a type the compiler refuses to let you store. What is being built is an API shape that makes the mistake visible, plus a trap that goes off on your laptop instead of in production.
- Which is why the debug-build trap is not a nice-to-have — it is the only thing that actually catches anything, and it has to exist from day one.
- A `Str` reached through something zfast does not walk carries no marker and is not watched: a const slice, an untagged union. The walk covers structs, optionals, arrays, mutable slices, and the active arm of a tagged union — which is how a `Str` inside a [`Patch`](./0026-a-patch-needs-three-answers-and-an-optional-has-two.md) is covered.
- The marker is 16 bytes rather than 12 in a debug build, which is the cost of a 64-bit generation. Release builds still carry none of it.
- Memory use grows with the number of requests in flight, not the number of connections. That is acceptable because the metrics being chased are throughput and p99, not connection density.
