# The fail-function Failure is bound to the fiber, not the thread

ADR 0005 decided that a fail function stores its message in "the request currently running". It did not say how it knows which request that is. That turns out to be the easiest part to get wrong.

The reflex answer is `threadlocal`. In nilo that answer is **wrong**, and wrong in a dangerous way. The Engine runs every connection in a fiber, and many fibers share one OS thread. This sequence can happen at any moment:

1. Fiber A enters a handler. The thread slot points at A's Failure.
2. A's handler waits on a database query, so A goes to sleep.
3. Fiber B runs on the same thread. The thread slot now points at B's Failure.
4. A wakes up and calls `fail.notFound("user 7 has insufficient balance")` — and writes it into B's Failure.
5. User B receives a 404 about user 7.

That is not a rare bug, it is a data leak between users, and it only shows up under load — exactly when it is most expensive.

So the Failure is bound to the **fiber**, through `zio.TaskLocal`: the value sticks to its fiber, travels with it if the fiber moves threads, and is invisible to other fibers. What `fail()` can reach is always the Failure of the request it is genuinely serving.

Because only `http/engine/` may name zio (ADR 0002), this joins the Bulkhead contract as one pointer bound to the unit of work currently running — `bindSlot`/`unbindSlot`/`slot`. An Engine built on ordinary threads rather than fibers satisfies the same contract with a `threadlocal`.

Outside the Engine there are no fibers at all — unit tests call `App` directly with in-memory buffers. For that the Bulkhead keeps a threadlocal fallback, used only when the fiber slot is empty. On a real server the fiber slot always exists and always wins, so the fallback is never read.

One small departure from ADR 0005: the message is not stored in the request arena but in a fixed buffer inside the Failure. The failure path must not have a failure path of its own — running out of memory while trying to report an error is the last place anyone wants to think about. The consequence is that messages are capped at 240 bytes and longer ones are truncated.

## Consequences

- Fail functions are safe to call from a handler that sleeps partway through — which is to say, from nearly every handler that touches a network or a database.
- One Failure per connection, not per request: it is reused and cleared at the start of every request. A message from the previous request cannot be carried along.
- The Bulkhead gains one obligation. Swapping the Engine now also means providing per-unit-of-work storage, not just sockets. This is a cost paid knowingly: the alternative is requiring handlers to hold a `*Ctx`, which collapses the entire typed layer.
- Tested under a mixed load of 200s and 404s across 64 concurrent connections: not one crossed message out of ~400,000 requests. That test is not part of `zig build test` because it needs a running server; it is run by hand through the script in `bench/`.
