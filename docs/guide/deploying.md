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

    .header_timeout_ms = 10_000,  // first byte of a head to the blank line
    .idle_timeout_ms = 75_000,    // a connection between requests
    .body_timeout_ms = 30_000,    // any one read of a body
    .write_timeout_ms = 30_000,   // any one write to the client

    .max_body = 1024 * 1024,      // the most `c.body()` reads into the arena
    .trusted_hops = 0,            // how many proxies stand in front
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
**one allocation** — the JSON body, and nothing else. A test holds it there.

## Deadlines

The four `_timeout_ms` knobs above bound how long the server waits on a client,
and they are on by default. Zero turns one off.

They are limits on one wait for the network, not on a request
([ADR 0023](../adr/0023-a-deadline-belongs-to-an-operation-not-to-a-request.md)),
which is what makes them safe to leave on: a stream that runs for an hour, a
WebSocket, and a 4 GB upload are all requests, and none of them is hurried by
any of this. What gets cut off is a client that has stopped talking.

`header_timeout_ms` is the one that matters most, and it is the one that is not
per read: the whole head has that long from its first byte, so a client sending
one byte a second is caught rather than granted an extension every time. It ends
in a 408. An idle keep-alive connection that has asked for nothing is closed
without a status — there is nothing to answer.

`idle_timeout_ms` is the knob whose real units are memory: an idle connection
costs about 21 KB, so a server with many visitors and few of them active wants
this lower than the default.

A WebSocket has no read limit once the handshake is done — a chat tab with
nobody typing is working correctly. Its writes keep theirs, which is how the
server finds out the client is gone.

## How big a body may be

`max_body` is the most `c.body()` will read into the request arena. Past it, a
413. A megabyte, the default, is a JSON body's worth on purpose: this body is
held whole, in memory, per request, so raising it raises what a handful of
concurrent clients can make the server hold.

`c.bodyStream()` has no such ceiling, because it holds nothing at all — it is
bounded by the buffer the handler passes in ([Requests](./requests.md)). An
endpoint taking files wants that one, not a bigger `max_body`.

This is the knob a reverse proxy in front cannot stand in for. A proxy can bring
the limit **down** — most already do — but nothing in front of zfast can raise a
limit inside it. An app taking uploads has to say so here.

## Who the client is

`c.peer()` is the address the connection came from. It is what the kernel says,
so it cannot be forged — and behind a proxy it is the proxy's address, which is
the same for every client.

`c.clientIp()` is the one to reach for, and by default it answers exactly what
`peer()` does. `X-Forwarded-For` is a header like any other: anyone can send one,
so a server that believed it without being told to would let every client claim
any address it liked. The things that read a client address — rate limits, audit
logs, blocklists — are precisely the things worth lying to.

`trusted_hops` is how many proxies you actually run:

```zig
try app.listen(.{ .trusted_hops = 1 });   // one Caddy, nginx or ALB in front
```

Set it to the number of proxies, **not** to the number of entries you have seen
in a header. Each proxy appends the address it heard from, so the entries are
counted from the right — the rightmost was written by the proxy nearest this
server, and the leftmost is whatever the original client claimed.

That direction is the whole safety property. With one proxy in front, a client
sending `X-Forwarded-For: 1.2.3.4` arrives as `1.2.3.4, 203.0.113.9`. Counting
one from the right reads `203.0.113.9` — the address the proxy actually saw —
while the forgery sits to the left and is never looked at.

A header with fewer entries than there are hops means the chain is not the one
configured, so `clientIp()` falls back to `peer()` rather than reading the
closest thing to hand, which would be the forgery.

Requests-per-second figures now exist, on one quiet box:
[`../benchmarks.md`](../benchmarks.md) for zfast alone and
[`../comparison.md`](../comparison.md) against eight other servers. Read the
caveats in both — loopback, no TLS, no database, and a handler that touches
Postgres makes every row in them the same.

## Which build mode

**`ReleaseSafe`.** In `ReleaseFast` an integer overflow is undefined behaviour
instead of a loud crash, and a web server takes input from strangers — that is
exactly the code where the check earns its keep. `Debug` is for development;
zfast's own `Str` staleness trap only exists there.

## Debug info, and what a build costs

Half of a Zig release build is debug info. Measured on this repo, warm: 14.7s
with it and 7.4s without, and the binary goes from 6.0 MB to 0.8 MB. At runtime
it costs nothing measurable. What it costs is the file and the line on every
frame of a panic — so **keep it for anything you deploy**, which is also why the
mode recommended above is not the one where zfast turns it off. The full
decomposition is in [`../comparison.md`](../comparison.md).

`zig build -Doptimize=ReleaseFast` in this repo builds the benchmark binary,
whose only job is to be measured, and leaves debug info out of it. Nothing else
here does, and `-Dstrip=false` turns even that off. Your own `build.zig` decides
for your own binaries: pass `.strip = true` to the module if you want the
smaller, faster-to-build one and can give up the line numbers.

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

## TLS, and the proxy in front

**zfast does not speak TLS, and is not going to**
([ADR 0028](../adr/0028-tls-is-terminated-in-front.md)). Zig's standard library
can be a TLS client and not a TLS server; the alternatives were a one-person
crypto dependency or a C toolchain in the install story, and both cost the
per-connection memory figure this project publishes.

On Fly.io, Railway, Render, Cloud Run, a Kubernetes ingress, an ALB or
Cloudflare this changes nothing — every one of them terminates TLS before the
request arrives. Set `trusted_hops` to 1 and carry on.

On a bare VPS, the whole of it is a Caddyfile:

```
example.com {
    reverse_proxy 127.0.0.1:8787
}
```

Caddy gets the certificate, renews it, redirects `:80`, and sends
`X-Forwarded-For`. The nginx equivalent needs the header said out loud:

```nginx
server {
    listen 443 ssl;
    server_name example.com;
    ssl_certificate     /etc/letsencrypt/live/example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/example.com/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:8787;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header Host $host;
        # A stream, a WebSocket and SSE all need this pair.
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
    }
}
```

Either way, bind zfast to `127.0.0.1` so nothing reaches it except through the
proxy, and say `.trusted_hops = 1` so `clientIp()` reads the address the proxy
saw.

Two things go with this decision and are worth knowing before you need them:
**HTTP/2 is not available** — browsers only speak it over TLS, negotiated during
the handshake — and therefore **zfast cannot be a gRPC server**, since gRPC is
HTTP/2. Neither follows from "no TLS" on its own, which is why both are here.

## What isn't here yet

Sessions, templates, `sendfile`, `permessage-deflate`, compression, and
broadcasting to WebSockets a handler doesn't hold.

Each item is listed with its reason in [`../roadmap.md`](../roadmap.md); the ones
that are refusals rather than backlog are in [`../adr/`](../adr/).
