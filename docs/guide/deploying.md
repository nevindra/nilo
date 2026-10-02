# Deploying

**Running nilo in production: what stops it starting, every limit it enforces and what happens when one is hit, the client address behind a proxy, TLS, stopping, and health checks.**

**Reference:** [`listen` options](../reference/app.md#listen-options), [`App`](../reference/app.md#app) · **Design:** [Lifecycle](../design/lifecycle.md), [Deadlines](../design/deadlines.md), [Memory](../design/memory.md), [TLS](../design/tls.md), [The engine](../design/engine.md), [CORS and the proxy in front](../design/cors-proxy.md)

## Startup errors

**Anything that can stop the server before the socket opens is reported as one plain line that includes the fix:**

```
error: port 8787 is already in use — something else is listening on 127.0.0.1:8787.
Stop it, or pass `.port = …` to listen() with a free one.

error: service *main.Db was never registered, but 4 routes need it
("/users", "/users/:id", "/admin/stats", …) — call app.provide() before app.listen()

error: nilo: static directory "public" could not be opened (FileNotFound) —
the path is relative to the working directory the server runs in

warning: std.log will block the event loop. Add to your root source file:
pub const std_options_debug_io = nilo.debug_io;

warning: nilo was built in Debug and this program in ReleaseSafe, which is legal
and slow. Pass the mode through: b.dependency("nilo", .{ .target = target,
.optimize = optimize }) — in the test step too, which is the one that usually
gets missed.
```

That line is the whole answer, so it is also the last thing on the screen. `listen()` stops the process there instead of returning an error, because a returned error would print a stack trace through nilo's own files on top of it. You don't need to know which file inside the engine noticed the port was taken.

If you want to handle the error yourself (in a test, or in a program that falls back to another port), [`tryListen()`, `tryRoute()` and `tryStatic()`](../reference/app.md#app) are the same calls with the error returned as a value.

## Tuning

`listen()` takes the options that change how the server uses the machine. The full list is [`listen` options](../reference/app.md#listen-options):

```zig
try app.listen(.{
    .address = "0.0.0.0",     // IPv4 or IPv6 — "::" for every interface
    .port = 8080,
    .threads = 0,             // 0 = one per core, or the container's CPU quota plus one
    .read_buffer = 16 * 1024, // also the ceiling on a request head (431 past it)
    .write_buffer = 4 * 1024,
    .reuse_address = true,
    .backlog = 4096,          // handshakes the kernel queues for accept; past it a SYN waits a second
    .shutdown_grace_ms = 10_000,
    .stop_on_signal = true,   // off if your program handles signals itself

    .header_timeout_ms = 10_000,  // first byte of a head to the blank line
    .idle_timeout_ms = 75_000,    // a connection between requests
    .body_timeout_ms = 30_000,    // any one read of a body
    .body_min_rate = 8 * 1024,    // bytes a second a body has to keep up
    .body_grace_ms = 10_000,      // before that rate is asked for
    .write_timeout_ms = 30_000,   // any one write to the client
    .request_deadline_ms = 0,     // a deadline every request starts with; 0 = none

    .max_connections = 10_000,    // held at once; 0 = no limit

    .max_body = 1024 * 1024,      // the most `c.body()` reads into the arena
    .trusted_proxies = &.{},      // which machines may say who they forward for
    .trusted_hops = 0,            // or, older: how many stand in front
});
```

`address` is an address to bind to, not a host name. Nothing is resolved, so a DNS lookup never decides which interface you land on.

**The two buffers are what a connection costs while it is being served, not while it waits.** A connection that has gone quiet gives both of them back, along with its stack pages, and waits at the shallowest frame it ever has ([ADR 062](../adr/062-where-a-connection-waits-is-what-it-costs.md)). So size them for the responses you send, not for the number of connections you hold: **an idle connection is 4,669 bytes whatever these two are set to.**

`threads = 1` means handlers never run at the same time, which removes the need for `nilo.Mutex`, and also removes the reason to have a machine with more than one core. See [Services](./services.md). Whatever the count, a connection is served by the thread it was given to, and a handler runs on that one OS thread from its first line to its last, across every wait in it. There is no work stealing between threads, because stealing cost a second wakeup on every request of a server that is not busy ([ADR 199](../adr/199-a-connection-is-served-by-the-thread-it-was-dealt-to.md)). Every thread also accepts: one fiber per thread waits in `accept` on the listening socket, so the rate of new connections grows with `threads` instead of being limited to what one fiber can do. One fiber managed about 43,000 a second, which is where a server that closes connections after a few requests used to stop ([ADR 200](../adr/200-every-executor-accepts.md)). See [Concurrency](../reference/app.md#concurrency) in the reference.

On the request path, a routed GET returning JSON with CORS installed makes **one allocation**: the JSON body, and nothing else. A test holds it there.

## What happens at each limit

**Every limit above has a behaviour behind it, and during an incident the behaviour is what matters:** what the client saw, what the log said, and what has to happen before the server takes that work again. The table has one row per limit, so you can look the answer up. The sections after it explain why each one works the way it does.

| Limit | Default | Past it | What frees it again |
|---|---|---|---|
| `max_connections` | 10,000 | The connection is accepted and closed at once. Nothing is read and no status is written, so the client usually sees a reset. The log says so once a minute with a running count | A held connection ends: a keep-alive one idles out, a WebSocket tab closes, a stream finishes |
| the process's descriptor limit (`ulimit -n`) | usually 1,024 | `accept` fails with `ProcessFdQuotaExceeded`. The loop waits (5 ms, doubling up to a second) and tries again, and the log says so once per shortage. Meanwhile connections wait in the kernel's backlog. `listen()` warned at startup if this was below `max_connections` ([ADR 194](../adr/194-an-accept-loop-that-is-out-of-descriptors-waits.md)) | A held connection ends |
| `backlog` | 4,096 | The kernel drops the SYN (no reset, and no log line from nilo), and the client's TCP retries it one second later, so the connection succeeds late. `ListenOverflows` in `/proc/net/netstat` is the only trace; `bench/burst.py` reads it ([ADR 198](../adr/198-a-backlog-is-sized-for-the-burst-not-the-load.md)) | An acceptor takes the next handshake. There is one per thread, so the queue drains at the rate all of them accept ([ADR 200](../adr/200-every-executor-accepts.md)) |
| `max_in_flight` | off | The head is read, then the answer is `503` with `Retry-After: 1` and `Connection: close`: one write of a constant, no queue. Counted under `<shed>` on the metrics page | A request inside its handler finishes |
| `header_timeout_ms` | 10,000 | A client partway through a head gets a `408` and the connection is closed. One that sent nothing is closed without a status, because there is nothing to answer | Nothing to free: the connection is gone |
| `read_buffer` | 16 KiB | A head that does not fit is a `431`, and the connection is closed, send side first, so the `431` reaches a client that would otherwise see a reset ([ADR 195](../adr/195-a-refused-request-is-hung-up-on-with-a-fin.md)) | Nothing to free |
| `idle_timeout_ms` | 75,000 | A keep-alive connection that has asked for nothing is closed, with no status | Nothing to free |
| `body_timeout_ms` | 30,000 | A read of the body that takes longer fails the handler's `c.body()` with a `408`, and the connection is closed. `c.bodyStream()` sees the same read fail | Nothing to free |
| `body_min_rate` after `body_grace_ms` | 8 KiB/s after 10,000 | A body that `c.body()` is assembling gets a deadline calculated from its announced length. Too slow is a `408`, however steadily the bytes arrived. `c.bodyStream()` is not affected | Nothing to free |
| `max_body`, or `nilo.maxBody` on the route | 1 MiB | `c.body()` refuses with a `413` before reading past it. A body nobody read that is over the limit is not drained after the answer: the response goes out and the connection is closed instead of being read to the end, send side first, so the `413` arrives ([ADR 195](../adr/195-a-refused-request-is-hung-up-on-with-a-fin.md)) | Nothing to free. The next request needs a new connection |
| `request_deadline_ms` | off | Every wait of the request (body reads, and the write when what is left of the deadline is under `write_timeout_ms`) is cut short to fit it, and `c.overdue()` tells a handler doing its own work. The failure is the wait's own (`408`, or the write given up), the same as `nilo.deadline(ms)` on one route. A stream, a WebSocket or a `bodyStream()` drops the deadline ([ADR 105](../adr/105-a-route-can-say-how-long-it-has.md)) | n/a |
| `write_timeout_ms` | 30,000 | One write to the client that takes longer gives the response up. A route's `nilo.deadline(ms)` nearer than this makes the deadline the limit for that answer's writes; a deadline further off leaves this as it is, so it stops a client that has stopped reading and not one that takes a little every few seconds. No status can be sent by then, the connection is closed, and the log says `gave up writing after 30000ms — the client stopped reading` instead of blaming the handler | Nothing to free |
| `shutdown_grace_ms` | 10,000 | A stop waits this long for requests inside their handlers. Idle connections are closed at once, not waited for. After that the rest are cut off and the log says how many | n/a |
| `arena_keep` | 16 KiB | Not a refusal: a response built in `c.arena()` that is larger than this is built in memory the arena gives back after the request, so the next one faults it in a page at a time ([ADR 075](../adr/075-a-response-larger-than-the-arena-keep-is-a-page-fault-per-page.md)) | Raise it to just above the largest response, and no further: it is held per connection |

Two things are true of every row. **A status goes out only when nothing has been written yet**: a `408` or `413` reached in the middle of a response cannot take back the part already on the wire, so the connection is closed instead. And **none of the deadlines limits a whole request**: an hour-long stream, a WebSocket and a 4 GB upload through `c.bodyStream()` are all fine, because each deadline limits one wait for the network and nothing else. The next section explains this.

## Deadlines

**The four `_timeout_ms` options limit how long the server waits on a client, and they are on by default.** Zero turns one off. Per-route deadlines are [`nilo.deadline`](../reference/middleware.md#nilodeadline) in the reference.

They limit one wait for the network, not a request ([ADR 022](../adr/022-a-deadline-belongs-to-an-operation-not-to-a-request.md)), which is what makes them safe to leave on. A stream that runs for an hour, a WebSocket, and a 4 GB upload are all requests, and none of them is rushed by any of this. What gets cut off is a client that has stopped talking.

`header_timeout_ms` matters most, and it is the one that is not per read: the whole head has that long from its first byte, so a client sending one byte a second is caught instead of being given an extension every time. It ends in a 408. An idle keep-alive connection that has asked for nothing is closed without a status, because there is nothing to answer.

`body_min_rate` is the same idea for a body. Read this one twice, because **it is an admission policy, not a safety net**. A per-read limit cannot catch a client sending one byte every twenty-nine seconds, since every byte arrives on time. So a body nilo is assembling in the arena gets a deadline calculated from the length the client announced: `body_grace_ms` plus the time those bytes need at `body_min_rate`. A megabyte gets 138 seconds at the defaults, and a client slower than 8 KiB/s gets a 408 however honest it is ([ADR 022](../adr/022-a-deadline-belongs-to-an-operation-not-to-a-request.md)).

If your clients upload from places where that is not generous, lower the rate instead of raising the timeout. `body_min_rate = 0` turns it off entirely and leaves the per-read limit on its own. A chunked body announces no length, so its deadline is calculated from `max_body`: the same worst case as a body that announced the largest size it may be. **`c.bodyStream()` is not affected by any of this.** Nothing is held on the client's behalf there, and a long upload through it is a request that lasts, not a request that stalls.

`idle_timeout_ms` is really a memory setting: an idle connection costs 4,669 bytes, so a server with many visitors and few of them active wants it lower than the default.

A WebSocket has no read limit once the handshake is done, because a chat tab with nobody typing is working correctly. Its writes keep their limit, which is how the server finds out the client is gone.

## How many connections at once

**`max_connections` is the most connections this process holds at one time.** The default is ten thousand, and the number comes from the measurement this project keeps repeating: **an idle connection costs 4,669 bytes before it has asked for anything**, so the default is around 45 MB of connections and no more.

That figure is **a floor, not a total**. A suspended fiber holds its stack at its high-water mark, so a handler adds every byte of stack it ever touched, for the life of the connection. An ordinary database route measures 17,022 bytes ([ADR 062](../adr/062-where-a-connection-waits-is-what-it-costs.md)). Budget from 4,669 only for connections that are idle between requests; budget from what your own handlers measure for the ones in flight.

That is why the limit exists. A server with no limit does not fail at a number somebody chose. It keeps accepting until the machine runs out, and then the OOM killer takes the process down, along with every request that was being answered correctly. A limit turns "we ran out of memory" into "we ran out of connections", which you can read in a log and set a number for.

Past the limit, a connection is accepted and closed at once. No request is read and no status is sent, so the client sees the connection close immediately, often as a reset, since the request it sent was never read. This is deliberate:

- **Not "stop accepting".** Connections left in the kernel's backlog hang until something times out, and the load balancer in front cannot try another instance until then. Closing tells it now.
- **Not a 503.** Writing to a client the server has just decided it cannot afford to serve is work an attacker gets to choose, and it would put a write (with a deadline on it) inside the accept loop, which is the one loop that must not stall.

The log says so once a minute for as long as it lasts, with a running total:

```
warning: nilo is holding its limit of 10000 connections, so new ones are being
closed unanswered (417 so far). Raise `.max_connections` in listen() if the
machine has the memory — an idle connection costs 4,669 bytes, plus whatever
stack the handler touches — or put fewer of them on this process.
```

It counts connections, not requests. One connection makes many requests in a row, and a WebSocket is one connection for as long as the tab is open. A chat server holding open tabs wants this raised, multiplied by 5,183 first, which is what an idle WebSocket costs. `.max_connections = 0` turns it off, which is how nilo behaved before this existed.

It also limits file descriptors. A response that sends a file (a static file over `max_file_bytes`, or a handler returning a `FileBody`) holds one open for as long as the send takes, and there is one of those per request in flight ([ADR 009](../adr/009-static-files-are-held-in-memory-or-opened.md)). So this number already covers them, and there is no second number to budget for.

## How many requests at once

**`max_in_flight` limits requests being answered, not sockets held.** It is off by default. Set it, and a request whose head arrives while that many are already inside their handlers is answered `503` with `Retry-After: 1` at once and the connection is closed: no queue, no wait, one write of a constant. A load balancer in front then sends the retry to a replica with room, and the requests already running finish on time ([ADR 159](../adr/159-a-server-past-its-limit-says-so-at-once.md)).

```zig
try app.listen(.{ .max_in_flight = 256 });
```

Pick the number from `nilo_requests_in_flight` on the metrics page under real load, not from a guess. 256 is right for a 40 ms handler and wrong for a 4 s one, which is why there is no default. Rejected requests are counted under `<shed>` on the same page, separately from the routes they never reached.

This is deliberately different from `max_connections`. Over the connection limit nothing is read and nothing is written, because the accept loop must not stall. Over the request limit the head has already been read on a connection fiber, and a 503 is something a load balancer can act on, where a reset is not.

## How big a body may be

**`max_body` is the most `c.body()` will read into the request arena.** Past it, the answer is a 413. The default, a megabyte, is deliberately a JSON body's worth: this body is held whole, in memory, per request, so raising it raises how much a handful of concurrent clients can make the server hold.

`c.bodyStream()` has no such limit, because it holds nothing at all. It is limited by the buffer the handler passes in ([Requests](./requests.md)). An endpoint that takes files wants that, not a bigger `max_body`.

A reverse proxy in front cannot do this for you. A proxy can lower the limit (most already do), but nothing in front of nilo can raise a limit inside it. An app that takes uploads has to set it here.

**One route can have its own limit** with [`nilo.maxBody`](../reference/middleware.md#nilomaxbody). The one on `listen()` is for the whole server, and an import that takes fifty megabytes should not make the sign-in route beside it accept fifty megabytes too:

```zig
try app.with(nilo.maxBody(50 << 20)).post("/import", importCsv);
```

It works both ways: a route can also accept *less* than `listen()` allows ([ADR 156](../adr/156-a-route-can-say-how-much-body-it-takes.md)).

**When the limit is a setting, hand it the address of a `usize`.** An ingest route whose cap differs between staging and production cannot write the number into the program, so it keeps the number in a variable filled from configuration before `listen()`, and the route reads it on each request:

```zig
var ingest_limit: usize = 16 << 20;

pub fn main() !void {
    ingest_limit = settings.ingest_max_body;
    try app.with(nilo.maxBody(&ingest_limit)).post("/v1/logs", ingest);
    try app.listen(.{});
}
```

A setting of `0` leaves `listen()`'s `max_body` in force and logs a warning once, rather than refusing every body.

## Client IP address behind a proxy

**Use `c.clientIp()` for the client's address, and tell nilo which machines are your proxies.** [`c.peer()`](../reference/ctx.md#reading) is the address the connection came from. It comes from the kernel, so it cannot be forged, but behind a proxy it is the proxy's address, which is the same for every client.

[`c.clientIp()`](../reference/ctx.md#reading) is the one to use, and by default it returns exactly what `peer()` does. `X-Forwarded-For` is a header like any other: anyone can send one, so a server that believed it without being told to would let every client claim any address it liked. The things that read a client address (rate limits, audit logs, blocklists) are exactly the things worth lying to.

**Set `trusted_proxies`**: name the networks your proxies are on, and the number of proxies stops mattering.

```zig
try app.listen(.{ .trusted_proxies = &.{"private"} });
```

Each entry is a CIDR (`10.0.0.0/8`, `fd00::/8`), a bare address meaning that one host, or one of two names: `"private"` for the RFC 1918 ranges plus carrier-grade NAT, link-local, unique-local v6 and the loopback, and `"loopback"` for the loopback alone. The header is not read at all unless the connection came from one of them. Entries written by one of them are skipped from the right, and the first one left is the client. An entry that is not an address stops the server at `listen()` with a sentence naming it ([ADR 102](../adr/102-a-proxy-is-trusted-by-which-one-it-is.md)).

Prefer it over a count because **a wrong count fails silently**. Add a CDN in front of the load balancer and the count is one short from that afternoon on, and the server keeps answering, with the load balancer's address or with whatever the client wrote in the header. Nothing logs and no test fails.

`trusted_hops` is the older option and still works. It is the number of proxies you actually run:

```zig
try app.listen(.{ .trusted_hops = 1 });   // one Caddy, nginx or ALB in front
```

When both are set, `trusted_proxies` wins.

**`c.scheme()` and `c.host()` follow the same rule.** They read `X-Forwarded-Proto` and `X-Forwarded-Host` only from a connection one of your named proxies made, or, with none named, when `trusted_hops` is set. So a request that reached the pod directly cannot put its own host into a password-reset link. Behind TLS terminated in front, this is what makes `scheme()` return `"https"`. A listener that terminates TLS itself returns `"https"` from the connection and reads no header ([ADR 102](../adr/102-a-proxy-is-trusted-by-which-one-it-is.md)).

Set `trusted_hops` to the number of proxies, **not** to the number of entries you have seen in a header. Each proxy appends the address it heard from, so the entries are counted from the right: the rightmost was written by the proxy nearest this server, and the leftmost is whatever the original client claimed.

That direction is what makes it safe. With one proxy in front, a client sending `X-Forwarded-For: 1.2.3.4` arrives as `1.2.3.4, 203.0.113.9`. Counting one from the right reads `203.0.113.9`, the address the proxy actually saw, while the forged entry sits to the left and is never read.

A header with fewer entries than there are hops means the chain is not the one configured, so `clientIp()` falls back to `peer()` instead of reading the closest entry, which would be the forged one.

**`allowance.with` is the first thing in nilo that acts on this**, so getting it wrong stops being an inconvenience and becomes an outage. Leave it at zero behind a proxy and every request looks like it came from the proxy: one address uses up the whole allowance, and everybody else gets a 429. nilo logs this the first time it refuses a request that carried an `X-Forwarded-For` and was counted against the connection's own address. See [Middleware](./middleware.md#rate-limiting).

Requests-per-second figures exist, measured on one quiet machine: [`bench/result/http.md`](../../bench/result/http.md) for nilo alone and [`../comparison.md`](../comparison.md) against eight other servers. Read the caveats in both: loopback, no TLS, no database. A handler that touches Postgres makes every row in them the same.

## Which build mode

**Use `ReleaseSafe`.** In `ReleaseFast` an integer overflow is undefined behaviour instead of a loud crash, and a web server takes input from strangers, which is exactly the code where the check is worth having. `Debug` is for development; nilo's own `Str` staleness trap only exists there.

## Debug info, and what a build costs

**Keep debug info in anything you deploy.** Half of a Zig release build is debug info. Measured on this repo, warm: 14.7s with it and 7.4s without, and the binary goes from 6.0 MB to 0.8 MB. At runtime it costs nothing measurable. What you lose without it is the file and line on every frame of a panic, which is also why the mode recommended above is not the one where nilo turns it off. The full breakdown is in [`../comparison.md`](../comparison.md).

`zig build -Doptimize=ReleaseFast` in this repo builds the benchmark binary, whose only job is to be measured, and leaves debug info out of it. Nothing else here does, and `-Dstrip=false` turns even that off. Your own `build.zig` decides for your own binaries: pass `.strip = true` to the module if you want the smaller, faster-to-build binary and can give up the line numbers.

## Panics

**A panic takes the whole process down, so run under a supervisor that restarts it.** Zig cannot recover from a panic: an integer overflow or an out-of-bounds index takes the process down, and every in-flight connection with it. There is no `recover` middleware because there cannot be one; see [ADR 007](../adr/007-no-recover-middleware.md).

Handler *errors* are a different thing and are already handled; see [Errors](./errors.md). For panics, run behind a supervisor that restarts, and add [`nilo.panic`](../reference/README.md#declarations-in-the-root-file)

```zig
pub const panic = nilo.panic;
```

to your root file so the crash says which request caused it:

```
thread 589880 panic: integer overflow (while handling GET /boom/50)
```

That is the difference between a stack trace and a way to reproduce it.

## Stopping

**`listen()` returns when the server is stopped**: by Ctrl-C, by a `SIGTERM` from whatever supervises the process, or by [`app.shutdown()`](../reference/app.md#app) from anywhere.

```zig
try app.listen(.{});      // returns on Ctrl-C or SIGTERM
std.log.info("bye", .{}); // and this runs
```

What happens in between is what matters for a deploy. The server stops accepting. Requests already being answered are finished, and their responses go out with `Connection: close`, so the client opens a fresh connection to whatever replaced this process. Connections sitting idle between keep-alive requests are closed at once: they hold no work, and waiting on them would put the whole grace period behind every open browser tab.

A handler that runs past `.shutdown_grace_ms` (10 seconds by default) is cut off, and the log says how many were. Pressing Ctrl-C a second time skips the wait entirely; the count is of signals, so a first signal after `app.shutdown()` still gets the grace period.

A stream or a WebSocket needs your help: `live()` becomes false when the stop begins, and a loop that checks it lets the deploy finish instead of waiting out the whole grace period. See [Streaming](./streaming.md#when-a-stream-ends).

Work that is not a request uses the same grace period and finds out differently: `nilo.sleep` fails with `error.Canceled` when it ends, and `catch return` is all a ticker needs to do. See [Work that is not a request](./background.md).

`app.shutdown()` is safe from any thread and from inside a handler, so an admin endpoint that stops the server is an ordinary handler. The App is a service like any other, so register it with itself first:

```zig
fn quit(app: *nilo.App) []const u8 {
    app.shutdown();
    return "going down\n";
}

try app.provide(&app);          // …or `*nilo.App was never registered` at startup
try app.post("/admin/quit", quit);
```

## TLS and a reverse proxy

**nilo does not speak TLS unless the build asks for it, and a proxy in front is still the recommendation** ([ADR 027](../adr/027-tls-is-terminated-in-front.md)). Zig's standard library can be a TLS client but not a TLS server; the alternatives were a crypto dependency maintained by one person, or a C toolchain in the install steps. The first of those is now an option, described below, for a server with nothing in front of it. Everything else on this page is about a server with a proxy in front, which is most of them.

On Fly.io, Railway, Render, Cloud Run, a Kubernetes ingress, an ALB or Cloudflare this changes nothing: every one of them terminates TLS before the request arrives. Set `.trusted_proxies = &.{"private"}` and carry on.

On a bare VPS, all you need is a Caddyfile:

```
example.com {
    reverse_proxy 127.0.0.1:8787
}
```

Caddy gets the certificate, renews it, redirects `:80`, and sends `X-Forwarded-For`. The nginx equivalent has to set the header explicitly:

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

Either way, bind nilo to `127.0.0.1` so nothing reaches it except through the proxy, and set `.trusted_proxies = &.{"loopback"}` so `clientIp()` reads the address the proxy saw.

**Or listen on a unix socket instead of a port.** `.address = "unix:/run/nilo.sock"` listens on a path, and then "who may connect" becomes "who may write to that directory": `proxy_pass http://unix:/run/nilo.sock;` in nginx, `reverse_proxy unix//run/nilo.sock` in Caddy. `port` is not read. A request that arrives this way has no client address of its own, so `clientIp()` reads the proxy's header through `.trusted_proxies`, and it is allowed to because nothing remote can open a unix socket ([ADR 103](../adr/103-a-path-is-an-address-to-listen-on.md)).

One consequence is worth knowing before you need it: **HTTP/2 is not available for your routes.** Browsers only speak it over TLS, negotiated during the handshake, and the listener below offers only `http/1.1`. **gRPC is the exception**, because it runs over HTTP/2 without TLS: a build that asks for it serves unary calls on a listener of its own ([gRPC](./grpc.md)).

### TLS without a proxy

**For a server with nothing in front of it, TLS 1.3 is available behind a build flag.** This is for an internal tool on a VM, a service on a private network whose policy requires encryption, or a machine with one port and a certificate where nobody wants to run a second process. It uses [ianic/tls.zig](https://github.com/ianic/tls.zig), and it has to be built in ([ADR 212](../adr/212-tls-is-an-option-a-build-asks-for.md)):

```zig
// build.zig
const nilo = b.dependency("nilo", .{ .target = target, .optimize = optimize, .tls = true });
```

The library is fetched and linked only with that flag, so a build without it is exactly the build the rest of this page describes. With it, the listener takes two PEM files:

<!-- compiles: body -->
```zig
try app.listen(.{ .tls = .{
    .cert = "/etc/nilo/fullchain.pem",
    .key = "/etc/nilo/privkey.pem",
} });
```

The certificate chain comes leaf first, the way every issuer hands it out, and the key unencrypted; `certbot` and `step` both write exactly that. Paths are relative to the directory the server is started in, unless absolute. A certificate that cannot be read stops the server before it takes the port, with one line saying which file. A `.tls` on a build without the flag is refused the same way, instead of being served as plain HTTP. So is a key that does not belong to the certificate, which is the mistake you make when the two files come from different `letsencrypt/live/` directories: both files parse, so without that check the server started and failed every handshake, with the reason visible only to the client ([ADR 212](../adr/212-tls-is-an-option-a-build-asks-for.md)). Rotating a certificate means a restart, which is how this server is already deployed.

What it costs, so the choice is an informed one ([ADR 212](../adr/212-tls-is-an-option-a-build-asks-for.md) has the tables):

- **560 KB of binary**, before a certificate is loaded, in every build that passes the flag. A build without it pays 2,760 bytes.
- **One page per idle connection**, on every listener of that build, TLS or not: 9,293 bytes against 5,191. A TLS connection's 33 KB of record buffers are not in that figure, because they go back to the kernel when idle, like the rest.
- **About 300 µs of CPU per new connection with an ECDSA certificate, and 2.6 ms with an RSA-2048 one**, for the handshake: twenty times a plain accept for the first, and nine times that for the second, so an ECDSA P-256 certificate is the cheap choice when you pick the key. Half a microsecond per request either way on a connection kept alive. A service whose clients hold a connection does not notice. One whose clients connect per request pays the handshake per request, and that is the case a proxy with session resumption is for, because this listener has none. Build for the CPU you run on: without AES instructions in the target (`-Dcpu`), a request costs six times as much.
- **One certificate per listener**, no client certificates, and no reload without a restart. TLS 1.3 only, which every browser and client library of the last six years speaks.
- **The library has not been audited.** ADR 027's trust argument still holds: a deployment that chooses this is deliberately choosing an unaudited TLS stack over an audited one, for a server that would otherwise have none. On the internet, put Caddy in front and leave this off.

`.tls` together with a unix socket is refused: the socket file's permissions already control access, and there is nobody on the path to encrypt against. The handshake is limited by `header_timeout_ms`, because until it is done a connection is a client that has not yet sent a request. A scanner that connects and goes quiet, or speaks plain HTTP to the port, is dropped when that runs out. `clientIp()` on this listener is the real address, since no proxy is in the way.

### Listening on more than one address

**A server listens on one address by default, and on as many as you list** ([ADR 213](../adr/213-a-server-answers-on-more-than-one-address.md)). The main use is the other half of the section above: HTTPS for people outside, and plain HTTP for whatever is already inside.

<!-- compiles: body -->
```zig
try app.listen(.{
    .port = 8080,
    .also = &.{
        .{ .port = 8081, .tls = .{ .cert = "cert.pem", .key = "key.pem" } },
    },
});
```

An entry has an address, a port and a certificate, and nothing else. Every other `listen()` option belongs to the server, not to one of its addresses: the buffers, the deadlines, the thread count, and `max_connections`, which counts the sockets this process holds, not the sockets one port holds.

**A route is answered on every listener unless you bind it to some.** A server with an ingest port and a public port wants the ingest routes off the public one, and a session-cookie route off the ingest one. Number the listeners by their position in the list (`0` is `.port`, `1` is `also[0]`) and bind at the registration ([ADR 252](../adr/252-a-request-knows-which-listener-it-came-in-on.md)):

<!-- compiles: body -->
```zig
const public = 0;
const ingest = 1;
const h = struct {
    fn ok(ctx: *nilo.Ctx) !void {
        try ctx.sendText(200, "ok");
    }
};

try app.get("/healthz", h.ok); // both
try app.onListener(&.{ingest}).post("/v1/logs", h.ok);
try app.group("/api").onListener(&.{public}).get("/users", h.ok);

try app.listen(.{ .port = 8080, .also = &.{.{ .port = 4317 }} });
```

A request that arrives on the other listener finds no such route: a 404, the one an unknown path gets, decided before the route's middleware runs and with no `Allow` header to give it away. Nothing is allocated and a connection costs the same. One path is still one route, so `/healthz` cannot answer differently on two listeners.

**`c.listener()` is the same number, for what a binding does not say**, such as a middleware that refuses a prefix on the wrong listener, or a limit that differs per port. It is read from the connection, so no header can claim it:

<!-- compiles: body -->
```zig
const refuseOffIngest = struct {
    fn run(ctx: *nilo.Ctx, next: nilo.Next) !void {
        if (ctx.listener() != 1) return ctx.sendText(404, "not found");
        try next.run(ctx);
    }
}.run;
try app.useOn("/internal", refuseOffIngest);
```

In a test, `.listener = 1` in the client's options is the request arriving on `also[0]`.

Three things to know before you use it:

- `boundPort()` returns the port of `port`, the first listener. An extra listener may ask for port 0 and the kernel will give it one, but nothing reports which.
- Two entries with the same address are refused at `listen()`, naming both, instead of failing with the kernel's `AddressInUse`, which reads as if another process held the port and sends you looking for one.
- Each extra listener costs about **82 KB** of resident memory on a sixteen-thread server: one socket, and one acceptor fiber per thread waiting in `accept` for the life of the server. Nothing per connection and nothing per request; an idle connection costs exactly what it did.

## Health checks

**`app.health` answers the question a load balancer, Kubernetes or a restart script asks every second or so: can this instance take traffic?** It is [`app.health(path)`](../reference/app.md#app) in the reference.

<!-- compiles: body -->
```zig
try app.health("/healthz");
```

```
GET /healthz
200 {"status":"ok"}
503 {"status":"unavailable","waiting":[{"service":"sql.Db","why":"the database is not answering"}]}
503 {"status":"stopping"}
```

**This route answers "ready", not just "alive".** A route that says `ok` because the process is up sends traffic to a server whose database is down, and the application cannot write the honest version by hand because it does not know what the pool knows. So the page asks each service that declares `nilo_ready`, and the three modules that hold a connection to something answer: `sql.Db` sends `SELECT 1` down the pool and reports what came back, an `s3` Store says whether it started, and a service with no hook (a config struct, a cache) is assumed ready. A service of your own joins in with one function ([ADR 154](../adr/154-a-health-route-asks-the-services.md)):

<!-- compiles -->
```zig
const Mailer = struct {
    connected: bool = false,

    pub fn nilo_ready(self: *Mailer, scope: *nilo.AnyScope) ?[]const u8 {
        _ = scope;                       // an arena, for a reason with a number in it
        return if (self.connected) null else "the mail relay has not accepted a connection yet";
    }
};
```

Null means ready; a sentence says why not, and it appears on the page beside the service's name. **As soon as the server is told to stop, the page says `stopping`**, which is how a load balancer learns to drain this instance before its listener closes, not after. This is the other half of [Stopping](#stopping). Every answer carries `Cache-Control: no-store`.

It is an ordinary route, like the metrics page: mount it where the load balancer can reach it and nothing else needs to, and keep it out of the [logger](./middleware.md) if a line a second is noise. It does not affect any request other than the probe.

## Monitoring

**`app.metrics(.{})` puts a Prometheus page on `/metrics`**: requests per route, status classes, a latency histogram, exact status codes for the process, and requests in flight. It is an ordinary route, so where you mount it and what you `use` in front of it is what protects it; nilo puts no authentication on it. See [Metrics](./metrics.md) and [`metrics` options](../reference/app.md#metrics-options).

That covers the *service*. For a single *request*, a request id you can match to a log line is in [Errors](./errors.md). The two answer different questions: metrics tell you something is wrong, and a request id tells you which request.

## Not supported yet

**`permessage-deflate`, and compression of a stream or an event stream, are not supported.** A whole answer is compressed, per request ([Responses](./responses.md#compression)), and a file is compressed once, when it is loaded ([Static files](./static-files.md#compression)).

Templates are refused, not planned: nilo is for building APIs and services, and rendering pages is not what it is for. The reasoning is in [`decided.md`](../decided.md#not-coming).

What is still open is listed, with what it is waiting for, in [`../todo.md`](../todo.md). What has been refused, with the reason, is in [`../decided.md`](../decided.md) and the ADR each entry names.
