# Services

A service is a long-lived thing registered once when the App is built — a
database connection, config, a logger — then asked for by handlers according to
its type.

```zig
var db = try Db.open("app.sqlite");
try app.provide(&db);

fn getUser(db: *Db, id: u32) !User { … }   // matched by type, no name anywhere
```

Registration order doesn't matter, and a service nobody asks for costs nothing. A
service somebody asks for and nobody registered stops `listen()` before the
socket opens:

```
error: service *main.Db was never registered, but 4 routes need it
("/users", "/users/:id", "/admin/stats", …) — call app.provide() before app.listen()
```

`*const Config` and `*Config` are different types and are looked up as such, so a
read-only service can say so. From a handler that took no typed arguments, or
from middleware, `c.service(*Db)` is the same lookup.

The App is a service like any other — `try app.provide(&app)` — which is how an
admin endpoint gets at `app.shutdown()`.

See [ADR 0006](../adr/0006-services-via-a-runtime-registry.md).

## They are shared across threads

Handlers run concurrently on several OS threads. A service you only read from is
fine as-is. One that gets written to needs a lock — and it needs
**`zfast.Mutex`**, not `std.Thread.Mutex`, because that one blocks the whole
thread and every other request being served on it:

```zig
const Store = struct {
    lock: zfast.Mutex = .init,
    users: std.ArrayList(User) = .empty,
};

fn addUser(store: *Store, incoming: NewUser) !User {
    try store.lock.lock();
    defer store.lock.unlock();
    ...
}
```

`lock()` can fail with `error.Canceled` if the request went away while waiting,
which maps to a 503 already. It still works with no server running, so a handler
that takes the lock is still testable as a plain function. See
[ADR 0011](../adr/0011-shared-services-need-a-lock-from-the-bulkhead.md).

## Handlers must not block

`zfast.Mutex` is one case of a rule that runs through everything: **many requests
share one OS thread, so a handler that waits stops all of them.** Not just the
request doing the waiting — every other request that happens to be on that
thread, including ones that had no work left to do.

It is easy to measure. One handler sitting in `nanosleep` for two seconds, and a
second request asking for a route that does nothing:

```
$ curl localhost:8787/slow &        # 2 seconds of blocking
$ curl -w '%{time_total}\n' localhost:8787/
1.701                               # ...paid by a request that had nothing to wait for
```

The way out is `zfast.blocking`, which hands the call to a pool of real threads
and parks only this request:

```zig
fn getUser(db: *Db, id: u32) !User {
    return zfast.blocking(Db.query, .{ db, id });   // instead of db.query(id)
}
```

Same arguments, same return value, errors included. It allocates nothing, and
outside a running server it just calls the function — so the handler is still an
ordinary function a test can call.

### What needs wrapping

| | |
|---|---|
| a database driver — `libpq`, SQLite, a socket you opened yourself | `zfast.blocking` |
| `std.fs` — reading or writing a file | `zfast.blocking` |
| `std.http.Client`, or any call out to another service | `zfast.blocking` |
| a `std.Thread.Mutex`, semaphore, or channel from `std` | `zfast.Mutex` |
| sleeping, backing off, waiting out a rate limit | `try zfast.sleep(ms)` |

Pure computation does not need it — parsing, JSON, a hash, a loop over a slice.
Those are *using* the thread, not waiting on it. A long computation is a
different problem, and `zfast.blocking` handles that one too.

`zfast.sleep` takes milliseconds and fails with `error.Canceled` if the request
went away while waiting, the same way `Mutex.lock` does.

Nothing forces any of this — Zig has no way to mark a function as blocking, so a
handler that calls the driver directly still compiles and still works. It just
takes the rest of its thread down with it under load. See
[ADR 0014](../adr/0014-handlers-must-not-block-the-thread.md).
