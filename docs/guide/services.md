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

## Holding on to request text

The first wall anybody arriving from Go or Node hits, and it is worth spelling
out because the compiler will not.

Text from a request is a [`Str`](./handlers.md#str-and-text-that-belongs-to-the-request),
and it points into memory that is thrown away when the request ends. A service
outlives the request. So this compiles, passes every test you write for it, and
serves the *next* request's bytes to the one that asked:

```zig
fn addTodo(store: *Store, incoming: NewTodo) !Todo {
    const todo = Todo{ .id = store.next_id, .title = incoming.title };  // ✗
    try store.todos.append(store.gpa, todo);
    …
}
```

In a debug build zfast panics on the read instead, and names the request that
did it. That is the trap doing its job — but the fix is the point:

```zig
const Store = struct {
    gpa: std.mem.Allocator,
    lock: zfast.Mutex = .init,
    todos: std.ArrayList(Todo) = .empty,

    /// Everything a Todo owns, freed in one place. Worth having even for one
    /// string: the day a `due` is added, this is the only function to change.
    fn free(self: *Store, todo: Todo) void {
        self.gpa.free(todo.title);
    }

    fn deinit(self: *Store) void {
        for (self.todos.items) |t| self.free(t);
        self.todos.deinit(self.gpa);
    }

    fn add(self: *Store, title: []const u8) !Todo {
        try self.lock.lock();
        defer self.lock.unlock();
        // The copy, and the whole of the rule: the store owns its strings.
        const todo = Todo{ .id = self.next_id, .title = try self.gpa.dupe(u8, title) };
        try self.todos.append(self.gpa, todo);
        self.next_id += 1;
        return todo;
    }
};

fn addTodo(store: *Store, incoming: NewTodo) !Todo {
    return store.add(incoming.title.view());   // ✓ view() to read, add() copies
}
```

Two habits make the rest of it fall out:

- **The service takes `[]const u8`, not `Str`.** `Str` is a request type; a
  service that never names it cannot accidentally store one. The handler calls
  `.view()` at the boundary, which is the one line where the lifetime matters.
  `.keep(gpa)` is the same copy for the times a handler does it itself.
- **One `free` per stored type, called from `deinit` and from every replace and
  remove.** Replacing a row means allocating the new string *before* freeing the
  old one, so a failed allocation leaves the row as it was rather than holding a
  pointer to freed memory.

None of this is zfast's — it is what owning memory costs in Zig, and it is a real
part of what a CRUD app in this language weighs. The framework's part is that
getting it wrong stops on your laptop instead of in production.

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
