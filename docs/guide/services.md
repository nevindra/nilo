# Services

**A service is a long-lived thing (a database connection, config, a logger) registered once when the App is built, then asked for by handlers by its type.**

**Reference:** [`app.provide`](../reference/app.md#app), [`nilo.blocking` and `nilo.Mutex`](../reference/app.md#concurrency) · **Design:** [Lifecycle](../design/lifecycle.md), [Memory](../design/memory.md)

```zig
var db = try Db.open("app.sqlite");
try app.provide(&db);

fn getUser(db: *Db, id: u32) !User { … }   // matched by type, no name anywhere
```

## Registering a service

**Registration order doesn't matter, and a service nobody asks for costs nothing.** A service a handler asks for that nobody registered stops `listen()` before the socket opens:

```
error: service *main.Db was never registered, but 4 routes need it
("/users", "/users/:id", "/admin/stats", …) — call app.provide() before app.listen()
```

`*const Config` and `*Config` are different types and are looked up separately, so a read-only service can say so. From a handler that took no typed arguments, `c.service(*Db)` does the same lookup. A middleware takes a service as an argument after `Next`, like a handler, and `listen()` refuses to start when it is missing; `c.service` inside a middleware is a `?*Db`, which fails open if it is written `orelse return next.run(c)` ([Middleware](./middleware.md#giving-a-middleware-what-it-needs)).

The App is a service like any other (`try app.provide(&app)`), which is how an admin endpoint gets at `app.shutdown()`.

See [ADR 005](../adr/005-services-via-a-runtime-registry.md).

## Two of the same type

**A service is found by its type, so a second one of the same type is refused when it is provided.** A primary and a replica, or two upstream clients, are both a `Db` or a `Client`; the way round it is a struct of its own per instance, which is a different type and so a different service:

```zig
const Primary = struct { db: Db };
const Replica = struct { db: Db };

var primary: Primary = .{ .db = try Db.open("primary.sqlite") };
var replica: Replica = .{ .db = try Db.open("replica.sqlite") };
try app.provide(&primary);
try app.provide(&replica);

fn getUser(r: *Replica, id: u32) !User { return r.db.find(id); }
fn saveUser(p: *Primary, body: NewUser) !User { return p.db.insert(body); }
```

Providing a second `Db` instead stops with a sentence naming the type and this fix, and `app.provide` returns `error.ServiceAlreadyRegistered` for a caller that wants to branch on it. A group's `provide` is App-wide too, so this holds inside a plugin as well (ADR 002, ADR 005).

## Locking a shared service

**Handlers run at the same time on several OS threads, so a service that gets written to needs a lock, and it has to be `nilo.Mutex`, not `std.Thread.Mutex`.** A service you only read from is fine as it is. `std.Thread.Mutex` blocks the whole thread and every other request being served on it:

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

`lock()` can fail with `error.Canceled` if the request went away while waiting, and that already maps to a 503. It also works with no server running, so a handler that takes the lock can still be tested as a plain function. See [ADR 010](../adr/010-shared-services-need-a-lock-from-the-bulkhead.md).

## Storing request text in a service

**A service must copy request text before storing it.** This is the first problem most people coming from Go or Node hit, and it is worth spelling out because the compiler will not catch it.

Text from a request is a [`Str`](./handlers.md#request-text-str), and it points into memory that is thrown away when the request ends. A service outlives the request. So this compiles, passes every test you write for it, and serves the *next* request's bytes to the one that asked:

```zig
fn addTodo(store: *Store, incoming: NewTodo) !Todo {
    const todo = Todo{ .id = store.next_id, .title = incoming.title };  // ✗
    try store.todos.append(store.gpa, todo);
    …
}
```

In a debug build nilo panics on the read instead, and names the request that did it. The fix is to copy:

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

Two habits cover the rest:

- **The service takes `[]const u8`, not `Str`.** `Str` is a request type, and a service that never names it cannot store one by accident. The handler calls `.view()` at the boundary, the one line where the lifetime matters. `.keep(gpa)` makes the same copy when a handler does it itself.
- **One `free` per stored type, called from `deinit` and from every replace and remove.** When replacing a row, allocate the new string *before* freeing the old one, so a failed allocation leaves the row as it was instead of pointing at freed memory.

None of this is specific to nilo: it is what owning memory costs in Zig, and a real part of the work in a CRUD app in this language. What nilo adds is that getting it wrong fails on your laptop, not in production.

### One arena per row

**When a row holds nested text, give each row its own arena**, so freeing it is one call that stays correct when the type changes. A `free` per stored type stops scaling once a row holds a customer, an address and a list of lines, each with text of its own:

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

Hold the rows **by pointer**, not by value: if an `ArenaAllocator` moves when the list grows, any `allocator()` handle taken from it points at where the arena used to be.

### Returning text a service owns

**A read returns a copy in the request arena, not a view into the store.** A handler returns to nilo, and nilo writes the response *after* it returns. In between, another request on another thread can delete that row and free the text the response is about to be written from:

```zig
fn get(self: *Orders, into: std.mem.Allocator, id: u32) !?Order {
    try self.lock.lock();
    defer self.lock.unlock();
    const row = self.rowFor(id) orelse return null;
    return try copyOut(into, row.order);   // under the lock, into the request
}
```

It costs one walk of a structure that is about to be walked again anyway, and the copy is thrown away with the request. A store that nothing ever deletes from does not need it, but "nothing ever deletes from it" can stop being true without anyone noticing.

[`examples/orders`](../../examples/orders/main.zig) does all of this on a domain with lines, an address and a customer.

### Converting deeply nested types

**Past two levels of nesting, write the converter once, using reflection.** Count the walks: a service takes `[]const u8` and a handler has `Str`, so something converts on the way **in**. A row that owns its text copies on the way in as well. A read returns a copy in the request arena, so something walks it on the way **out**. That is three walks of one shape. `orders` writes all three by hand, because at that size hand-written is clearer.

That stops being true quickly. A document with an optional `meta`, a list of `sections` each holding a list of `lines`, and a list of `tags` needs three hand-written recursive walks, and those are three places to forget the field somebody adds next month, silently, with the compiler agreeing.

```zig
/// `source` walked into `Target`, borrowing its text or copying it.
fn into(comptime Target: type, gpa: std.mem.Allocator, source: anytype, own: enum { borrow, own }) !Target
```

It is one function over `@typeInfo`, about a hundred lines with comments, and it covers every field because it never names one. nilo does not ship it, on purpose: a converter that walks *your* types has to decide what "the same shape" means (whether a null `?T` is a field at all, what happens to a `Str` inside a union), and shipping it would mean owning those decisions in every future version. Yours can just decide.

The point of this section is to notice when you need it, which is the hard part. The application that went looking for it had already written its fourth `dupe` loop.

## Handlers must not block

**Many requests share one OS thread, so a handler that waits stops all of them.** `nilo.Mutex` is one case of this rule. It is not just the waiting request that stalls: every other request on that thread does too, including ones with no work left to do.

It is easy to measure. One handler sits in `nanosleep` for two seconds, and a second request asks for a route that does nothing:

```
$ curl localhost:8787/slow &        # 2 seconds of blocking
$ curl -w '%{time_total}\n' localhost:8787/
1.701                               # ...paid by a request that had nothing to wait for
```

The fix is [`nilo.blocking`](../reference/app.md#concurrency), which hands the call to a pool of real threads and parks only this request:

```zig
fn getUser(db: *Db, id: u32) !User {
    return nilo.blocking(Db.query, .{ db, id });   // instead of db.query(id)
}
```

It takes the same arguments and returns the same value, errors included. It allocates nothing, and outside a running server it just calls the function, so the handler is still an ordinary function a test can call.

### What needs wrapping

| | |
|---|---|
| a database driver: `libpq`, SQLite, a socket you opened yourself | `nilo.blocking` |
| `std.fs`: reading or writing a file | `nilo.blocking` |
| a call out to another service | [`nilo_fetch`](./fetch.md), which parks; `std.http.Client` parks too when it is given `c.io()` ([ADR 244](../adr/244-a-handler-is-given-the-loop-it-runs-on.md)), and needs `nilo.blocking` only when it is given an `Io` of its own |
| a `std.Thread.Mutex`, semaphore, or channel from `std` | `nilo.Mutex` |
| sleeping, backing off, waiting out a rate limit | `try nilo.sleep(ms)` |

Pure computation does not need it: parsing, JSON, a hash, a loop over a slice. Those *use* the thread, they do not wait on it. A long computation is a different problem, and `nilo.blocking` handles that too.

`nilo.sleep` takes milliseconds and fails with `error.Canceled` if the request went away while waiting, the same way `Mutex.lock` does.

### A blocking call that fans out

**The pool bounds the calls it runs, not the threads a call starts.** `nilo.blocking` takes one worker for as long as the function runs, and the Engine's pool has a ceiling on how many it runs at once. A function that then spawns threads of its own, to split a CPU-bound scan across cores, is outside that count: eight searches at four threads each are thirty-two busy threads while the pool shows eight in use. Nothing in nilo sees them, and the blocking warning does not either, since the handler is parked the whole time.

**So the fan-out is the caller's to bound**, and there are two ways that keep a number on it:

- **A per-call thread cap read from configuration**, passed into the function as an argument, so one request can use at most that many. It bounds one call, not a burst of them: the total is the pool's ceiling times the cap, and the cap should be chosen with that product in mind.
- **Several `nilo.blocking` calls instead of one with threads inside.** The handler splits the work and issues each part as its own call, which the pool's limit holds the way it holds any other. The parts of one request run one after another, which is slower for that request and is the price of the pool's limit meaning something.

**The threads may allocate their results from `c.arena()`.** It is a `std.heap.ArenaAllocator` over the App's allocator, which is thread-safe when its child is, so a handler can pass it to the function it hands `nilo.blocking`, join its threads there, and return a typed value that borrows from it: the arena is reset after the response is written, not when the handler returns. An arena of the function's own, freed by a `defer` in the handler, is gone before the return value is serialised.

Do not reach for `nilo.blockingReserved` to fan out. It starts a thread whenever it finds none idle, past the pool's ceiling, which is the unbounded growth this section is about ([ADR 064](../adr/064-a-file-has-no-socket-to-wait-on.md#a-statement-under-hop-gets-a-thread-of-its-own)). For a call that is expensive rather than slow, a [`nilo.Gate`](../reference/app.md#concurrency) sized to what the machine can afford is the tool, and it is what password hashing does.

**On glibc, cap malloc's arenas when calls spawn threads and allocate with `std.heap.c_allocator`.** glibc gives each new thread an arena of its own, up to eight per core, and keeps what is freed in it, so memory allocated on one thread and freed on another fragments across them. The photon port saw RSS climb from 204 MiB past 500 MiB under repeated identical queries while its own accounting returned to zero; with two arenas the same load settled at 35 to 50 MiB between requests, and the peak under 16 clients fell from 708 to 403 MiB, with no change in latency. One call at the top of `main` does it, and `MALLOC_ARENA_MAX` in the environment still overrides it:

```zig
extern "c" fn mallopt(param: c_int, value: c_int) c_int;
const M_ARENA_MAX = -8;

pub fn main() !void {
    _ = mallopt(M_ARENA_MAX, 2);
    // ...
}
```

A program that allocates with Zig's own allocators (`std.heap.smp_allocator`, a `DebugAllocator`), or links musl, has no such arenas and nothing to cap.

### A failure that carries data

**An error union does cross `nilo.blocking`, and an error carries only its name.** `nilo.blocking(f, args)` returns whatever `f` returns, error set included (`ReturnType(func)` in `http/bulkhead.zig`). `error.InvalidQuery` arrives intact, and so does nothing else: a message, a byte offset or a list of what was wrong has nowhere to ride on it.

**Two cases, and nilo already answers the first.** When the data is a status and a sentence, call a `fail` function inside the blocking call: it works there, because the request travels to the worker with the call, and the handler gets `error.Failed` with the message as if it had failed on the fiber ([Errors](./errors.md#failing-a-request)). When the data is structured and the handler decides what to do with it, **return a value instead of an error**: a union of the result and the failure with its data, and map it to a nilo failure in the handler, on the fiber.

<!-- compiles -->
```zig
const Found = union(enum) {
    ok: u32,
    invalid: struct { at: usize, why: []const u8 },
};

/// The kernel runs on a pool thread and reports a bad query as a value.
fn kernel(text: []const u8) Found {
    if (text.len == 0) return .{ .invalid = .{ .at = 0, .why = "the query is empty" } };
    return .{ .ok = @intCast(text.len) };
}

fn search(q: Str) !u32 {
    return switch (nilo.blocking(kernel, .{q.view()})) {
        .ok => |count| count,
        .invalid => |bad| nilo.fail.unprocessable("{s} (at byte {d})", .{ bad.why, bad.at }),
    };
}
```

That is the intended shape, not a workaround: the kernel stays a plain function with no request and no `nilo` in it, a test calls it directly and matches on the union, and the handler is the one place that knows what a failure means to a client. A kernel used by six handlers gets one `switch` in each and nothing more. Passing a diagnostic out-parameter (`diag: *Diag`) into the call works too, and is the same recipe with the data in a place the caller owns; what to avoid is an error the handler has to guess the details of.

### State shared between fibers and blocking workers

**`nilo.Mutex` is the lock for state that fibers and blocking workers both touch.** It is zio's mutex behind the watchdog wrapper in `http/bulkhead.zig`, and the engine documents that it also works from a plain thread with no fiber, which is what a `nilo.blocking` worker is. A fiber that waits on it parks and the thread keeps serving; a worker that waits on it holds only its own pool thread. It needs no `Io`, so it is the one lock that is the same in both places:

<!-- compiles -->
```zig
const Manifest = struct {
    lock: nilo.Mutex = .init,
    files: u32 = 0,

    /// Called from a handler, and from inside `nilo.blocking`.
    fn add(self: *Manifest) !void {
        try self.lock.lock();
        defer self.lock.unlock();
        self.files += 1;
    }
};
```

Two rules go with it:

- **Hold it for the copy or the swap, not across the slow part.** A compactor that holds the manifest lock across an `fsync` makes every search that wants the manifest wait for the disk. Take it to read or replace the list, release it, then do the long work on the copy; a second lock for writers, taken across the `fsync`, keeps them in order without holding readers up.
- **`lock()` fails with `error.Canceled` when the request went away**, so a cleanup path with no one to report to uses `lockUncancelable()` for a short section that does not itself wait.

**A spin lock is for a module that has no loop at all.** `nilo_cache` spins because `std.Io.Mutex.lock` takes an `Io` that layer does not have, and it is safe there only because the lock is held across a `memcpy` and nothing else, ever. A program on nilo has `nilo.Mutex`, so it does not need to copy that.

**A blocking worker is an ordinary thread, so a blocking file call is fine in it.** That is the point of handing it there. What the call needs is an `std.Io`, because Zig 0.16's file API (`std.Io.Dir`) takes one: a program that wants the worker's file work independent of the server's loop owns a `std.Io.Threaded` and passes its `io()`, which is what nilo's own static file loader does (`http/static.zig`, `load`). Plain libc calls (`open`, `pread`, `fsync`, `mkdir`) need none and are what a program that already links libc may use. `nilo.io()` can be read from a pool thread ([ADR 244](../adr/244-a-handler-is-given-the-loop-it-runs-on.md)), but nothing here has measured file calls through the server's `Io` from a worker, so this guide does not recommend it for them. nilo ships no file helpers for workers (`mkdirAll`, `listDir`, `writeFileAtomic`); a program that needs the same forty lines in two modules writes them once.

### The blocking warning

**A handler that blocks its thread is reported in the log, on the first request.** Nothing *forces* you to wrap a call: Zig has no way to mark a function as blocking, so a handler that calls the driver directly still compiles and still passes its tests. But it does not go unnoticed. The server times each handler, minus the time it spent legitimately waiting, and says so:

```
handler GET /users/7 held its thread for 2003ms. Every other request being
served on that thread waited the whole time. Hand the call that waits to
nilo.blocking (ADR 013).
```

The useful part is *when*: on the first request, with nobody else on the server. That is what makes this bug hard. One `curl` against a handler that queries the database synchronously gives the right answer at the right speed, and looks correct in every way you can check. It only misbehaves once there is a second request, which usually means production.

The default threshold is a quarter of a second. `listen(.{ .block_warning_ms = … })` changes it and `0` turns it off. A handler that keeps doing it is logged once a second with a count of the rest, not once per request.

It measures the longest stretch the fiber ran **without parking**, not the total. That is what lets it watch a handler that never returns: a stream, a body reader and a WebSocket used to be excused entirely, because a total has no upper bound on a connection that stays open for an hour. One stretch means the same thing on a request that lasts a millisecond and on a connection that lasts a day, so a blocking call inside a WebSocket loop is now reported. That is where the mistake costs the most, since a stalled fiber there holds its executor against every other socket that executor serves ([ADR 013](../adr/013-handlers-must-not-block-the-thread.md)).

A handler that yields every 30ms is not holding its thread, however long the request takes overall, and is not reported.

See [ADR 013](../adr/013-handlers-must-not-block-the-thread.md) for the rule and what enforces it.
