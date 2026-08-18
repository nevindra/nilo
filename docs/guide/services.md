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
**`nilo.Mutex`**, not `std.Thread.Mutex`, because that one blocks the whole
thread and every other request being served on it:

```zig
const Store = struct {
    lock: nilo.Mutex = .init,
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

In a debug build nilo panics on the read instead, and names the request that
did it. That is the trap doing its job — but the fix is the point:

```zig
const Store = struct {
    gpa: std.mem.Allocator,
    lock: nilo.Mutex = .init,
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

None of this is nilo's — it is what owning memory costs in Zig, and it is a real
part of what a CRUD app in this language weighs. The framework's part is that
getting it wrong stops on your laptop instead of in production.

### Once a row is more than one string

A `free` per stored type stops scaling the moment a row holds a customer, an
address and a list of lines, each with text of its own. Give the row an arena
instead, and freeing it is one call that cannot fall behind the type:

```zig
const Row = struct { memory: std.heap.ArenaAllocator, order: Order };

fn place(self: *Orders, incoming: NewOrder) !Order {
    const row = try self.gpa.create(Row);
    row.* = .{ .memory = .init(self.gpa), .order = undefined };
    errdefer row.memory.deinit();

    const mine = row.memory.allocator();
    row.order = .{ .customer = try keepCustomer(mine, incoming.customer), … };
    …
}

fn drop(self: *Orders, row: *Row) void {
    row.memory.deinit();       // the customer, the address, every line
    self.gpa.destroy(row);
}
```

Hold the rows **by pointer**, not by value: an `ArenaAllocator` that moves when
the list grows leaves any `allocator()` handle taken from it pointing at where
the arena used to be.

### Returning text a service owns

A handler returns to nilo, and nilo writes the response *after* it returns. In
between, another request on another thread can delete that row and free the text
the response is about to be written from.

So a read hands back a copy in the request arena rather than a view into the
store:

```zig
fn get(self: *Orders, into: std.mem.Allocator, id: u32) !?Order {
    try self.lock.lock();
    defer self.lock.unlock();
    const row = self.rowFor(id) orelse return null;
    return try copyOut(into, row.order);   // under the lock, into the request
}
```

It costs one walk of a structure that is about to be walked again anyway, and the
copy is thrown away with the request. A store nothing ever deletes from does not
need it — but "nothing ever deletes from it" is a property that stops being true
quietly.

[`examples/orders`](../../examples/orders/main.zig) does the whole of this on a
domain with lines, an address and a customer in it.

### Past two levels, write the walk once

Count the walks. A service takes `[]const u8` and a handler has `Str`, so
something converts on the way **in**. A row that owns its text copies on the way
in as well. A read hands back a copy in the request arena, so something walks it
on the way **out**. That is three walks of one shape, and `orders` writes all
three by hand because at that size hand-written is clearer.

It stops being clearer quickly. A document with an optional `meta`, a list of
`sections` each holding a list of `lines`, and a list of `tags` is three
hand-written recursive walks — and three places to forget the field somebody
adds next month, silently, with the compiler agreeing.

**Past two levels of nesting, write the converter once by reflection**:

```zig
/// `source` walked into `Target`, borrowing its text or copying it.
fn into(comptime Target: type, gpa: std.mem.Allocator, source: anytype, own: enum { borrow, own }) !Target
```

One function over `@typeInfo`, a hundred lines with the comments, and every
field is covered because it never names one. nilo does not ship it, and that is
deliberate rather than an omission: a converter that walks *your* types has
opinions about what "the same shape" means — whether a `?T` that is null is a
field at all, what happens to a `Str` inside a union — and shipping it means
owning those opinions in every future version. Yours can just decide.

What this paragraph is for is the *realising*, which is the expensive half. The
application that went looking for it wrote the fourth `dupe` loop first.

## Handlers must not block

`nilo.Mutex` is one case of a rule that runs through everything: **many requests
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

The way out is `nilo.blocking`, which hands the call to a pool of real threads
and parks only this request:

```zig
fn getUser(db: *Db, id: u32) !User {
    return nilo.blocking(Db.query, .{ db, id });   // instead of db.query(id)
}
```

Same arguments, same return value, errors included. It allocates nothing, and
outside a running server it just calls the function — so the handler is still an
ordinary function a test can call.

### What needs wrapping

| | |
|---|---|
| a database driver — `libpq`, SQLite, a socket you opened yourself | `nilo.blocking` |
| `std.fs` — reading or writing a file | `nilo.blocking` |
| `std.http.Client`, or any call out to another service | `nilo.blocking` |
| a `std.Thread.Mutex`, semaphore, or channel from `std` | `nilo.Mutex` |
| sleeping, backing off, waiting out a rate limit | `try nilo.sleep(ms)` |

Pure computation does not need it — parsing, JSON, a hash, a loop over a slice.
Those are *using* the thread, not waiting on it. A long computation is a
different problem, and `nilo.blocking` handles that one too.

`nilo.sleep` takes milliseconds and fails with `error.Canceled` if the request
went away while waiting, the same way `Mutex.lock` does.

### nilo says so when you forget

Nothing *forces* any of this — Zig has no way to mark a function as blocking, so
a handler that calls the driver directly still compiles and still passes its
tests. What it does not do is go unnoticed. The server times each handler, minus
whatever it spent legitimately waiting, and says so:

```
handler GET /users/7 held its thread for 2003ms. Every other request being
served on that thread waited the whole time. Hand the call that waits to
nilo.blocking (ADR 0014).
```

The useful part is *when*: on the first request, with nobody else on the server.
That is the whole difficulty with this bug — one `curl` against a handler that
queries the database synchronously gives the right answer at the right speed,
and looks correct in every way you can check by looking. It only misbehaves once
there is a second request, which normally means production.

A quarter of a second is the default; `listen(.{ .block_warning_ms = … })` moves
it and `0` turns it off. A repeat offender is logged once a second with a count
of the rest, rather than once per request.

Three things are not watched, because holding the connection is exactly what
they are for: a stream, a body reader, and a WebSocket. A blocking call inside a
WebSocket loop is real and will not be reported.

See [ADR 0014](../adr/0014-handlers-must-not-block-the-thread.md) for the rule
and [ADR 0034](../adr/0034-the-thing-a-handler-holds-is-watched-at-run-time.md)
for what watches it.
