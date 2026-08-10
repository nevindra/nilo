# Request data uses a request arena, wrapped in the Str type

Every request gets a request arena: one bag of memory thrown away all at once when the request finishes. Users never hold an allocator and never call `deinit`. Fast, and no ceremony in user code.

The dangerous consequence: all request data dies when the handler returns. Users coming from Go or Node have never debugged a use-after-free — in both those languages, holding on to a string from a request is impossible to get wrong. In Zig nothing stops you, and the crash shows up at random, hours later, in production.

This is exactly GoFiber's most famous flaw, inherited from fasthttp: the rule "do not keep anything from `c` after the handler returns". Fixing it is one of the reasons zfast deserves to exist.

So request data is not a bare `[]const u8` but a **Str**:

1. You cannot get the contents without asking for them — there is no way to keep it "by accident".
2. `.keep()` copies into longer-lived memory, one function with an obvious name.
3. Debug builds attach a lifetime marker; using a Str from a request that has finished stops hard, with a message that names `.keep()`. Release builds drop the marker, at no cost.

## Consequences

- The guarantee **cannot** be complete. Zig has no ownership system; there is no way to build a type the compiler refuses to let you store. What is being built is an API shape that makes the mistake visible, plus a trap that goes off on your laptop instead of in production.
- Which is why the debug-build trap is not a nice-to-have — it is the only thing that actually catches anything, and it has to exist from day one.
- Memory use grows with the number of requests in flight, not the number of connections. That is acceptable because the metrics being chased are throughput and p99, not connection density.
