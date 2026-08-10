# There is no recover middleware, because Zig cannot recover

The v1 scope lists four built-in middlewares: logger, CORS, recover, static files. That list was written by looking at Fiber. Three of them port over. **`recover` does not, and cannot.**

In Go, `recover()` catches a panic, unwinds to the deferred call that caught it, and lets the goroutine carry on serving. Zig has none of that machinery. `@panic` calls the panic handler, which aborts the process. There is no unwinding, no resumption, and no per-fiber isolation — an integer overflow in one handler takes down every other connection in the process with it.

This was measured, not assumed. A handler that overflows a `u8` under a running server:

```
thread 561176 panic: integer overflow
    n += @intCast(...);
Aborted (core dumped)
```

The process is gone. `setjmp`/`longjmp` could technically jump out, but Zig runs no `defer` blocks while doing it, so every buffer, arena, and socket in flight leaks and whatever invariant the panic was announcing stays broken. Building a framework feature on that would be worse than having nothing.

## What people actually want from recover, and where it already comes from

The real requirement is "one bad request must not take down the server". That requirement splits in two, and only one half was ever about recover.

**Handler errors** — the half that matters in practice — are already handled, since stage 3. Anything a handler returns as an error becomes a response through the mapping table or a fail function (ADR 0005), and the connection stays alive. That is the recover middleware's actual job, and it lives in the request loop where it belongs, not in an optional middleware a user has to remember to install. A safety net you can forget to switch on is not a safety net.

**Panics** — integer overflow, index out of bounds, unwrapping a null — cannot be caught by anyone, and pretending otherwise is the dangerous part. Shipping something called `recover` that silently fails to recover would leave users believing they are protected when they are not.

## What is built instead

Not a middleware: a panic handler that names the request that was in flight.

When a server dies at three in the morning, the difference between `panic: integer overflow` and `panic while handling GET /users/42: integer overflow` is the difference between a day of guessing and a five-minute fix. The per-fiber slot from ADR 0007 already knows which request each fiber is serving, so the information is right there.

The one open question was whether that slot is still readable once the panic starts — zio's crash path calls `markCrashed()`, which clears the current-task pointer. A spike confirmed a user panic handler runs *before* that happens and can read the fiber slot correctly. If a future zio release reverses that order, the handler logs nothing rather than guessing: a wrong path in a crash log is worse than no path, because it sends you off debugging the wrong endpoint.

Deliberately not done: reading the slot from a `threadlocal` instead. That would be readable at panic time too, but it would report whichever request most recently *started* on that thread, not the one that actually panicked — the exact bug ADR 0007 exists to prevent, reintroduced in the one place it would be hardest to notice.

## Consequences

- v1 ships **three** built-in middlewares, not four: logger, CORS, static files.
- The documentation has to say out loud that a panic kills the process, and that production deployments need a supervisor (systemd, Kubernetes) to restart it. Users coming from Go will assume otherwise, and that assumption is expensive.
- `ReleaseSafe` becomes the recommended production build. In `ReleaseFast` an integer overflow is undefined behaviour instead of a panic, which trades a loud crash for a silent wrong answer. That trade is worth naming in the docs rather than leaving to the default.
- The Bulkhead gains no new obligation: the panic handler reuses the slot that ADR 0007 already requires.
