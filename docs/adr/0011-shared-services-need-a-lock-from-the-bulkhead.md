# A shared Service needs a lock, and it has to come from the Bulkhead

Found while writing `examples/rest`, which is the point of writing examples.

The example has a `Store` service holding an `ArrayList` of users and a `POST /users` handler that appends to it. That is the most ordinary shape a small API has. It was also, as first written, a data race.

## What was wrong

Handlers run on several OS threads at once, so two of them can be inside the same Service at the same moment.

That last sentence was not true when this ADR was first written, and finding out why is part of the decision. zio's own default is **one** executor — the right default for a library that might be embedded in somebody else's thread, and the wrong one for a server process, which would otherwise leave every core but one idle. nilo now asks for one executor per core (`Options.threads`), which makes the concurrency real and this ADR necessary rather than merely prudent. Nothing in nilo serialises them — the request arena is per request, the fail slot is per fiber, and a Service is by definition shared. That is correct and deliberate, but it means **a Service with mutable state needs a lock, and until now nilo gave users no way to say so.**

Worse, the obvious answer is wrong. `std.Thread.Mutex` blocks the OS thread. Under a fiber runtime the thread is running many other connections, so blocking it stalls all of them. If the fiber holding the lock is parked waiting on I/O and can only be resumed by that same thread, nothing gets unstuck. A framework whose documented Service pattern deadlocks under load is not one to ship.

Meanwhile a user cannot simply reach for `zio.Mutex`: ADR 0002 exists so that nothing above `src/engine/` names zio, and that promise is worth nothing if user code has to break it to write a correct handler.

## What was decided

The Bulkhead gains one item: **`Mutex`** — a lock that parks the unit of work rather than the OS thread under it. Exposed as `nilo.Mutex`.

```zig
const Store = struct {
    lock: nilo.Mutex = .init,
    users: std.ArrayList(User) = .empty,
};

try store.lock.lock();
defer store.lock.unlock();
```

Two properties made this an easy call rather than a reluctant one:

- **It works with no Engine underneath.** zio's mutex falls back to a plain futex when there is no fiber, so a handler that takes the lock is still callable from a unit test with no server running. That mattered more than anything else here: "a handler is an ordinary function you can test like one" is ADR 0003, and a lock that only works inside a running server would have quietly taken it away.
- **`lock()` can fail, and the failure is already handled.** It returns `error.Canceled` if the request was cancelled while waiting, and `Canceled` has mapped to a 503 in the table since ADR 0005. Nothing new to explain.

## Why the Bulkhead rather than anywhere else

Because the correct implementation depends entirely on the Engine. A threaded Engine wants `std.Thread.Mutex`; a fiber Engine wants its own. Anything nilo wrote itself would be right for one of them and a deadlock for the other. This is precisely what the Bulkhead is for, and it is the second time the answer has been "the Engine already has one" — the first was the monotonic clock.

## Consequences

- The Bulkhead contract grows by one item. Every future Engine has to supply a lock. This is a small obligation compared to file IO (ADR 0010), and unlike file IO it is needed by *every* application, not by one feature.
- The documentation has to say plainly that **handlers run concurrently across OS threads**. People coming from Node in particular will assume otherwise, and the assumption is silent until it is a corrupted list under load.
- Nothing forces the lock. A Service with mutable state and no lock still compiles and still races. Catching that would need ownership tracking Zig does not have; the honest answer is to say so in the docs and put the lock in the example everyone copies.
- Running on every core makes the per-fiber failure slot (ADR 0007) load-bearing in a way it was not before: fibers now really do move between threads. Re-verified under load once the threads were real — **0 crossed responses out of 1,008,130**, where a thread-local would have leaked one request's message into another's response.
- `Options.threads` exists so a single-threaded run is still one line away, for anyone who wants the old behaviour while they audit their Services.
- `nilo.RwLock`, condition variables and channels are all sitting there in zio unexposed. They stay unexposed until something needs them — the Bulkhead grows one item at a time, for a reason each time.
