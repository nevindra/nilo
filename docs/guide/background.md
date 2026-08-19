# Work that is not a request

Everything else in this guide starts because somebody connected. This page is
about the other kind: a summary written every minute, a queue drained every few
seconds, a cache warmed once at startup and refreshed after that.

nilo has one primitive for it — a fiber of its own, owned by the server — and
the only thing to decide is when it starts.

## The shape

```zig
const std = @import("std");
const nilo = @import("nilo_http");

const Exporter = struct {
    lock: nilo.Mutex = .{},
    pending: u64 = 0,

    fn flush(self: *Exporter) !void {
        try self.lock.lock();
        defer self.lock.unlock();
        // …send them somewhere…
        self.pending = 0;
    }
};

fn flushEvery(exporter: *Exporter) void {
    while (true) {
        nilo.sleep(60_000) catch return;   // Canceled — the server is going
        exporter.flush() catch |err| std.log.err("flush: {t}", .{err});
    }
}

pub fn main() !void {
    var app = nilo.App.init(std.heap.smp_allocator);
    defer app.deinit();

    var exporter: Exporter = .{};
    try app.provide(&exporter);
    try app.spawn(flushEvery, .{&exporter});

    try app.listen(.{});
}
```

`zig build run-scheduled` is this, smaller, with a route that gives the ticker
something to count.

Three things about that loop are load-bearing.

**`nilo.sleep` parks the fiber, not the thread.** Many requests share one OS
thread. `std.Thread.sleep` in there would stop every one of them for a minute;
this stops only itself.

**`error.Canceled` is the shutdown, and it is the only way out.** The fiber is
owned by the server exactly as a connection is: counted while it runs, and cut
off when the shutdown grace period ends. Nothing else ends the loop, so `catch
return` is not tidiness — it is how the process gets to exit.

**It may not fail.** There is no request to answer and nobody to answer it, so
an error has nowhere to go but the log.

## `app.spawn` or `nilo.spawn`

The same fiber. The difference is *when*.

| | |
|---|---|
| `app.spawn(f, args)` | registered before the server, started once it is up |
| `nilo.spawn(f, args)` | started now; `error.NoServer` if nothing is listening |

`nilo.spawn` is what a handler calls — a request that kicks off something
outliving it. It needs a running server, and inside a handler there always is
one.

`app.spawn` is what `main` calls. It exists because `listen()` does not return,
so there is no "after the server started" to write a line in. Registered
beside the routes, it starts after the port is taken and before the first
connection is accepted.

**It does not matter which order you start things in.** A program with a
database does this ([Talking to a database](./sql.md)):

```zig
try app.start(threaded.io());        // the pool is open from here
try migrate(&db);
try app.listen(.{ .port = 8080 });
```

That first phase has no server in it — the `Io` is yours, not the Engine's — so
anything spawned *there* would have nothing to be owned by. Registering with
`app.spawn` sidesteps the question: it is started by `listen()`, whichever of
the two ran first ([ADR 0086](../adr/0086-work-that-is-not-a-request-belongs-to-the-server.md)).

## Two things must not travel in

Neither is caught by the compiler, and both are the same two `nilo.spawn`
names.

**A `Str`.** It points into the request arena, which is reset when the request
ends, and this work outlives the request that started it by definition. Copy
anything borrowed from a request before it goes in — `.keep()`, or your own
allocation.

**A fail function.** `fail.notFound` and friends write their sentence into the
request being served. There is no request here, so it returns a plain error
with no message and nobody assembles a response from it. Log instead.

## What it costs

Nothing per request and nothing per connection: the request path is untouched,
and one of these is one fiber for the whole process rather than one per socket.

The fiber itself is not free. A suspended fiber holds its stack at the
high-water mark it ever reached for as long as it lives
([ADR 0063](../adr/0063-a-handlers-stack-is-per-connection.md)), which for a
fiber like this one is a few kilobytes that never come back — paid once per
thing you spawn. Spawn a handful, not one per row in a table.

## What is not here

There is no schedule language: no cron expressions, no "at 03:00 on Sundays",
no policy for what happens when one tick overruns the next. `sleep` in a loop
is the whole of it, and that is deliberate — every one of those policies has an
answer that is right for somebody and wrong for somebody else, and the loop is
written where you can read it. If you need wall-clock times, compute the next
one and sleep until it.

There is also no way to send a message to another connection's socket from
here. That is a `Room`, and it is [its own section](./websocket.md#sending-to-a-socket-you-dont-hold).
