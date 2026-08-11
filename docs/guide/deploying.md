# Deploying

## When it won't start

Everything that can stop a server before the socket opens says so in one line, in
words, with the fix in it:

```
error: port 8787 is already in use — something else is listening on 127.0.0.1:8787.
Stop it, or pass `.port = …` to listen() with a free one.

error: service *main.Db was never registered, but 4 routes need it
("/users", "/users/:id", "/admin/stats", …) — call app.provide() before app.listen()

error: zfast: static directory "public" could not be opened (FileNotFound) —
the path is relative to the working directory the server runs in

warning: std.log will block the event loop. Add to your root source file:
pub const std_options_debug_io = zfast.debug_io;
```

That line is the whole answer, so it is also the last thing on the screen:
`listen()` stops the process there rather than returning an error, which would
print a stack trace through zfast's own files on top of it. Which file inside the
engine noticed the port was taken is not your problem.

If you would rather handle it — a test, or a program that falls back to another
port — `tryListen()`, `tryRoute()` and `tryStatic()` are the same calls with the
error coming back as a value.

## Tuning

`listen()` takes the knobs that change how the server uses the machine:

```zig
try app.listen(.{
    .address = "0.0.0.0",     // IPv4 or IPv6 — "::" for every interface
    .port = 8080,
    .threads = 0,             // 0 = one per core
    .read_buffer = 8 * 1024,  // also the ceiling on a request head (431 past it)
    .write_buffer = 4 * 1024,
    .reuse_address = true,
    .shutdown_grace_ms = 10_000,
    .stop_on_signal = true,   // off if your program handles signals itself
});
```

`address` is an address to bind to, not a host name — nothing is resolved, so
which interface you land on is never a lookup's decision.

The two buffers are most of what an idle connection costs, so turn them down for
a server holding a lot of connections open and up for one sending large
responses. Measured on a 2-core Linux box across 1,000 held-open connections:
**~21 KB per idle connection** with the defaults, **~17 KB** at 2 KB each.

`threads = 1` makes handlers stop running at the same time, which removes the
reason for `zfast.Mutex` — and also removes the reason to have a machine with
more than one core. See [Services](./services.md).

On the request path, a routed GET returning JSON with CORS installed makes
**three allocations**, all of them bump allocations into a request arena that is
already warm. A test holds it there.

No requests-per-second figures, on purpose: that number needs a machine nobody
else is using, and there isn't one yet ([`../roadmap.md`](../roadmap.md)).

## Which build mode

**`ReleaseSafe`.** In `ReleaseFast` an integer overflow is undefined behaviour
instead of a loud crash, and a web server takes input from strangers — that is
exactly the code where the check earns its keep. `Debug` is for development;
zfast's own `Str` staleness trap only exists there.

## Panics

Zig cannot recover from a panic: an integer overflow or an out-of-bounds index
takes the whole process down, every in-flight connection with it. There is no
`recover` middleware because there cannot be one — see
[ADR 0008](../adr/0008-no-recover-middleware.md).

Handler *errors* are a different thing and are already handled — see
[Errors](./errors.md). For the rest: run behind a supervisor that restarts, and
add

```zig
pub const panic = zfast.panic;
```

to your root file so the crash says which request caused it:

```
thread 589880 panic: integer overflow (while handling GET /boom/50)
```

That is the difference between a stack trace and a reproduction.

## Stopping

`listen()` returns when the server is stopped — Ctrl-C, a `SIGTERM` from whatever
is supervising the process, or `app.shutdown()` from anywhere:

```zig
try app.listen(.{});      // returns on Ctrl-C or SIGTERM
std.log.info("bye", .{}); // and this runs
```

What happens in between is the part that matters for a deploy. The server stops
accepting; requests already being answered are finished, and their responses go
out saying `Connection: close` so the client opens a fresh connection to whatever
replaced this process. Connections merely sitting idle between keep-alive
requests are closed at once — they are holding no work, and waiting on them would
put the whole grace period behind every open browser tab.

A handler that runs past `.shutdown_grace_ms` (10 seconds by default) is cut off,
with a line in the log saying how many were. Pressing Ctrl-C a second time skips
the waiting entirely.

A stream or a WebSocket is the case that needs your cooperation: `live()` goes
false when the stop begins, and a loop that checks it lets the deploy finish
instead of sitting out the whole grace period. See
[Streaming](./streaming.md#ending-on-purpose-and-otherwise).

`app.shutdown()` is safe from any thread and from inside a handler, so an admin
endpoint that stops the server is an ordinary handler. The App is a service like
any other, so hand it to itself first:

```zig
fn quit(app: *zfast.App) []const u8 {
    app.shutdown();
    return "going down\n";
}

try app.provide(&app);          // …or `*zfast.App was never registered` at startup
try app.post("/admin/quit", quit);
```

## What isn't here yet

**No deadlines of any kind** — no read, header or write timeout. A client that
opens a connection and then goes quiet parks a fiber until TCP gives up on it,
and a WebSocket makes that cheap to do on purpose. This is the largest hole on
the list, and it wants one decision about deadlines rather than a knob per
feature. Put zfast behind a reverse proxy that has timeouts until then.

Also absent: **TLS** (terminate it in front), sessions, templates, `sendfile`,
`permessage-deflate`, and broadcasting to WebSockets a handler doesn't hold.

Each item is listed with its reason in [`../roadmap.md`](../roadmap.md); the ones
that are refusals rather than backlog are in [`../adr/`](../adr/).
