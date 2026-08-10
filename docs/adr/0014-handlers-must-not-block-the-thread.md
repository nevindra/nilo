# Handlers must not block the thread, and the way out comes from the Bulkhead

Found by using the framework the way its intended audience would: writing a handler that waits for something.

[ADR 0011](./0011-shared-services-need-a-lock-from-the-bulkhead.md) answered one instance of this — a Service with mutable state needs `zfast.Mutex`, not `std.Thread.Mutex`, because the latter stops the whole thread. That ADR got the reasoning right and the scope wrong. A lock is not a special case. It is the *first* case.

## What was wrong

zfast runs each connection in a fiber and many fibers on one OS thread. Anything a handler does that waits on the operating system stops every other request sharing that thread — not just the one waiting.

Measured, on a two-executor server, with one handler sitting in `nanosleep` for two seconds:

```
a second request, for a route that does nothing at all:  1.7s
four concurrent two-second handlers:                     6.0s
```

The second number is the shape of the problem. Four requests that each spend their time waiting, on a machine with two threads and nothing to compute, took six seconds. Under fibers they should have taken two.

Two things made this worse than a documentation gap:

- **zfast exposed nothing to fix it with.** The Bulkhead carried `Mutex` and a clock. It did not carry a way to wait, or a way to hand a blocking call somewhere it could block harmlessly. `zio` has both, and ADR 0002 says user code may not name zio — so a correct handler could not be written at all without breaking that promise.
- **The audience makes it the default mistake, not an edge case.** zfast is aimed at people coming from Go and Node. In Go every blocking call is safe because the runtime moves the goroutine; in Node the driver is async because there is no other option. Both groups arrive with "call the database from the handler" as a habit that has always worked. Here it compiles, passes every test, works perfectly under curl, and only shows up as a latency tail under load — the worst possible failure schedule.

The one sentence in the README that touched this said `std.Thread.Mutex` blocks the thread. Read as written, that is a fact about mutexes.

## What was decided

The Bulkhead gains two items, exposed as `zfast.blocking` and `zfast.sleep`.

```zig
fn getUser(db: *Db, id: u32) !User {
    return zfast.blocking(Db.query, .{ db, id });
}
```

`blocking` runs the call on the Engine's thread pool and parks this fiber until it returns — the arguments and the result stay on the calling fiber's stack, so nothing is allocated. `sleep` waits without occupying anything at all.

And the README gains a section stating the general rule, with the table of what needs wrapping. That is the half that actually prevents the mistake; the API is what makes the advice actionable rather than a warning to live with.

## Why this shape

- **It keeps ADR 0003.** Both fall back to running inline — `blocking` calls the function directly when there is no fiber, and `sleep` really does sleep. So a handler using either is still an ordinary function a unit test calls with no server running. This was the deciding property, exactly as it was for `Mutex` in ADR 0011. An escape hatch that only worked inside a running server would have bought correctness under load by taking away the thing the typed layer exists for.
- **It costs nothing to not use.** A handler that computes rather than waits never calls either, and pays nothing for their existence.
- **`sleep` fails the way `Mutex.lock` already does.** `error.Canceled` if the request went away while waiting, which has mapped to a 503 since ADR 0005. No new failure mode to explain.

## Why not the alternatives

- **Wrap handlers automatically**, running every one on the blocking pool. This makes the slow path safe by making the fast path slow: every request would pay a thread hand-off, including the overwhelming majority that only touch memory. It also throws away the reason for choosing a fiber Engine.
- **Detect blocking calls at compile time.** Zig has no effect system and no way to mark a function as blocking. Nothing to detect with.
- **Provide async drivers.** The real fix, and far outside v1 — it means an async Postgres client, an async file API, an async HTTP client. `blocking` is what makes the ecosystem that exists today usable in the meantime, and it is what Go's own `syscall` boundary does underneath.
- **Say nothing and let people find out.** This was the status quo, and it is the option this ADR exists to reject. The symptom is a p99 nobody can explain, on a metric zfast has declared primary since stage 1.

## Consequences

- The Bulkhead contract grows by two items. Every future Engine has to supply a way to offload a blocking call and a way to wait. A threaded Engine satisfies both trivially — `blocking` calls the function, `sleep` sleeps the thread — so this is a cheap obligation, unlike file IO ([ADR 0010](./0010-static-files-are-held-in-memory.md)).
- **Nothing forces it.** A handler calling the driver directly still compiles and still passes its tests. Same honest answer as ADR 0011: say it plainly in the docs, and put it where people copy from.
- The blocking pool is finite, so `blocking` converts "the thread stalls" into "the pool is the queue" rather than into unlimited concurrency. That is the correct trade for a database, which has a connection limit of its own, and it is worth saying out loud before someone expects otherwise.
- `zfast.monotonicNanos` was exported in the same pass. It is not part of this decision, but it came from the same cause: the README's timing middleware used `std.time.milliTimestamp`, which Zig 0.16 does not have, and the Engine's clock was sitting in the Bulkhead unexposed. A user could not write a timing middleware at all.
- Long computation is covered by the same tool and is not mentioned separately in the README's table. `zfast.blocking` around a CPU-bound call moves it off the executor thread just as well as it moves a syscall.
