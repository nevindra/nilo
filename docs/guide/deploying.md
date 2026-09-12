# Deploying

## When it won't start

Everything that can stop a server before the socket opens says so in one line, in
words, with the fix in it:

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

That line is the whole answer, so it is also the last thing on the screen:
`listen()` stops the process there rather than returning an error, which would
print a stack trace through nilo's own files on top of it. Which file inside the
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
    .body_min_rate = 8 * 1024,    // bytes a second a body has to keep up
    .body_grace_ms = 10_000,      // before that rate is asked for
    .write_timeout_ms = 30_000,   // any one write to the client

    .max_connections = 10_000,    // held at once; 0 = no limit

    .max_body = 1024 * 1024,      // the most `c.body()` reads into the arena
    .trusted_proxies = &.{},      // which machines may say who they forward for
    .trusted_hops = 0,            // or, older: how many stand in front
});
```

`address` is an address to bind to, not a host name — nothing is resolved, so
which interface you land on is never a lookup's decision.

The two buffers are what a connection costs **while it is being served**, not
while it waits: a connection that has gone quiet gives both of them back, along
with its stack pages, and waits at the shallowest frame it ever has
([ADR 0071](../adr/0071-where-a-connection-waits-is-what-it-costs.md)). So size
them for the responses you send rather than for the connections you hold —
**an idle connection is 4,669 bytes whatever these two say.**

`threads = 1` makes handlers stop running at the same time, which removes the
reason for `nilo.Mutex` — and also removes the reason to have a machine with
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

`body_min_rate` is the same idea for a body, and it is the one to read twice
because **it is an admission policy rather than a safety net**. A per-read limit
cannot catch a client sending one byte every twenty-nine seconds — every byte
arrives on time — so a body nilo is assembling in the arena gets a deadline
worked out from the length the client announced: `body_grace_ms` plus what those
bytes need at `body_min_rate`. A megabyte has 138 seconds at the defaults, and a
client slower than 8 KiB/s is a 408 however honest it is
([ADR 0124](../adr/0124-a-buffered-body-arrives-at-a-rate.md)).

If your clients upload from places where that is not generous, lower the rate
rather than raising the timeout — `body_min_rate = 0` turns it off entirely and
leaves the per-read limit on its own. A chunked body announces no length, so it
is sized from `max_body`: the same worst case as a body that announced the
largest it may be. **`c.bodyStream()` is not touched by any of this** — nothing
is being held on the client's behalf there, and a long upload through it is a
request that lasts rather than a request that stalls.

`idle_timeout_ms` is the knob whose real units are memory: an idle connection
costs 4,669 bytes, so a server with many visitors and few of them active wants
this lower than the default.

A WebSocket has no read limit once the handshake is done — a chat tab with
nobody typing is working correctly. Its writes keep theirs, which is how the
server finds out the client is gone.

## How many connections at once

`max_connections` is the most this process holds at one time. Ten thousand by
default, and the arithmetic behind that number is the one measurement this
project keeps repeating: **an idle connection costs 4,669 bytes before it has
asked for anything**, so the default is around 45 MB of connections and no more.

That figure is a **floor, not a total**. A suspended fiber holds its stack at
its high-water mark, so a handler adds every byte of stack it ever touched, for
the life of the connection — an ordinary database route measures 17,022
([ADR 0063](../adr/0063-a-handlers-stack-is-per-connection.md)). Budget from
4,669 only for connections that are idle between requests; budget from what
your own handlers measure for the ones in flight.

That is the whole reason it exists. A server with no cap does not fail at a
number somebody chose — it keeps accepting until the machine runs out, and what
notices is the OOM killer, which takes the process down along with every request
that was being answered correctly. A cap turns "we ran out of memory" into "we
ran out of connections", which is a thing you can read in a log and set a number
for.

Past the limit, a connection is accepted and closed at once. No request is read
and no status is sent, so a client sees the connection go immediately — often as
a reset, since the request it sent was never read. That is on purpose:

- **Not "stop accepting".** Connections left in the kernel's backlog hang until
  something times out, and the load balancer in front cannot try another
  instance until it does. Closing tells it now.
- **Not a 503.** Writing to a client the server has just decided it cannot
  afford to serve is work an attacker gets to choose, and it would put a write —
  with a deadline on it — inside the accept loop, which is the one loop that must
  not stall.

The log says so once a minute for as long as it lasts, with a running total:

```
warning: nilo is holding its limit of 10000 connections, so new ones are being
closed unanswered (417 so far). Raise `.max_connections` in listen() if the
machine has the memory — an idle connection costs 4,669 bytes, plus whatever
stack the handler touches — or put fewer of them on this process.
```

It counts connections, not requests. One connection makes many requests in a
row, and a WebSocket is one connection for as long as the tab is open — a chat
server holding open tabs wants this raised, and multiplied by 5,183 first, which
is what an idle WebSocket costs.
`.max_connections = 0` turns it off, which is what nilo did before this
existed.

It is also what bounds file descriptors. A response that sends a file — a static
file over `max_file_bytes`, or a handler returning a `FileBody` — holds one open
for as long as the send takes, and there is one of those per request in flight
([ADR 0037](../adr/0037-a-file-too-big-to-hold-is-opened-not-read.md)). So it is
a number that was already being multiplied rather than a second one to budget
for.

## How big a body may be

`max_body` is the most `c.body()` will read into the request arena. Past it, a
413. A megabyte, the default, is a JSON body's worth on purpose: this body is
held whole, in memory, per request, so raising it raises what a handful of
concurrent clients can make the server hold.

`c.bodyStream()` has no such ceiling, because it holds nothing at all — it is
bounded by the buffer the handler passes in ([Requests](./requests.md)). An
endpoint taking files wants that one, not a bigger `max_body`.

This is the knob a reverse proxy in front cannot stand in for. A proxy can bring
the limit **down** — most already do — but nothing in front of nilo can raise a
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

**`trusted_proxies` is the one to use**: name the networks your proxies are on
and the count stops mattering.

```zig
try app.listen(.{ .trusted_proxies = &.{"private"} });
```

Each entry is a CIDR (`10.0.0.0/8`, `fd00::/8`), a bare address meaning that
host alone, or one of two names — `"private"` for the RFC 1918 ranges plus
carrier-grade NAT, link-local, unique-local v6 and the loopback, and
`"loopback"` for the loopback alone. The header is not read at all unless the
connection came from one of them; entries written by one of them are skipped
from the right; the first one left is the client. A rule that is not an address
stops the server at `listen()` with a sentence naming it
([ADR 0129](../adr/0129-a-proxy-is-trusted-by-which-one-it-is.md)).

The reason to prefer it over a count is that **a wrong count says nothing**.
Add a CDN in front of the load balancer and the number is one short from that
afternoon on — and the server goes on answering, with the load balancer's
address, or with whatever the client wrote in the header. Nothing logs and no
test turns red.

`trusted_hops` is the older shape and still works. It is how many proxies you
actually run:

```zig
try app.listen(.{ .trusted_hops = 1 });   // one Caddy, nginx or ALB in front
```

When both are set, the description wins.

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

**`allowance.with` is the first thing in nilo that acts on this**, so getting
this wrong stops being an inconvenience and becomes an outage: leave
it at zero behind a proxy and every request looks like it came from the proxy,
one address spends the whole allowance, and everybody else gets a 429. nilo says
so in the log the first time it refuses a request that carried an
`X-Forwarded-For` and was counted against the connection's own address — see
[Middleware](./middleware.md#when-one-client-asks-too-often).

Requests-per-second figures now exist, on one quiet box:
[`bench/result/http.md`](../../bench/result/http.md) for nilo alone and
[`../comparison.md`](../comparison.md) against eight other servers. Read the
caveats in both — loopback, no TLS, no database, and a handler that touches
Postgres makes every row in them the same.

## Which build mode

**`ReleaseSafe`.** In `ReleaseFast` an integer overflow is undefined behaviour
instead of a loud crash, and a web server takes input from strangers — that is
exactly the code where the check earns its keep. `Debug` is for development;
nilo's own `Str` staleness trap only exists there.

## Debug info, and what a build costs

Half of a Zig release build is debug info. Measured on this repo, warm: 14.7s
with it and 7.4s without, and the binary goes from 6.0 MB to 0.8 MB. At runtime
it costs nothing measurable. What it costs is the file and the line on every
frame of a panic — so **keep it for anything you deploy**, which is also why the
mode recommended above is not the one where nilo turns it off. The full
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
pub const panic = nilo.panic;
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

Work that is not a request cooperates through the same grace period, and finds
out a different way: `nilo.sleep` fails with `error.Canceled` when it ends, and
`catch return` is the whole of what a ticker owes the deploy. See
[Work that is not a request](./background.md).

`app.shutdown()` is safe from any thread and from inside a handler, so an admin
endpoint that stops the server is an ordinary handler. The App is a service like
any other, so hand it to itself first:

```zig
fn quit(app: *nilo.App) []const u8 {
    app.shutdown();
    return "going down\n";
}

try app.provide(&app);          // …or `*nilo.App was never registered` at startup
try app.post("/admin/quit", quit);
```

## TLS, and the proxy in front

**nilo does not speak TLS, and is not going to**
([ADR 0028](../adr/0028-tls-is-terminated-in-front.md)). Zig's standard library
can be a TLS client and not a TLS server; the alternatives were a one-person
crypto dependency or a C toolchain in the install story, and both cost the
per-connection memory figure this project publishes.

On Fly.io, Railway, Render, Cloud Run, a Kubernetes ingress, an ALB or
Cloudflare this changes nothing — every one of them terminates TLS before the
request arrives. Set `.trusted_proxies = &.{"private"}` and carry on.

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

Either way, bind nilo to `127.0.0.1` so nothing reaches it except through the
proxy, and say `.trusted_proxies = &.{"loopback"}` so `clientIp()` reads the
address the proxy saw.

**Or take the port away entirely.** `.address = "unix:/run/nilo.sock"` listens
on a path instead, and then the answer to "who may connect" is the answer to
"who may write to that directory" — `proxy_pass http://unix:/run/nilo.sock;` in
nginx, `reverse_proxy unix//run/nilo.sock` in Caddy. `port` is not read. A
request that arrives that way has no client address of its own, so
`.trusted_proxies` is what `clientIp()` reads, and it is allowed to because
nothing remote can open a unix socket
([ADR 0130](../adr/0130-a-path-is-an-address-to-listen-on.md)).

Two things go with this decision and are worth knowing before you need them:
**HTTP/2 is not available** — browsers only speak it over TLS, negotiated during
the handshake — and therefore **nilo cannot be a gRPC server**, since gRPC is
HTTP/2. Neither follows from "no TLS" on its own, which is why both are here.

## Knowing whether it is ready

A load balancer, Kubernetes, or the script that restarts the process all ask
the same question every second or so: *can this instance take traffic?*
`app.health` answers it:

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

**Alive is not ready, and this route answers the second.** A route that says
`ok` because the process is up sends traffic to a server whose database is
down, and the application cannot write the honest version by hand because it
does not know what the pool knows. So the page asks each service that
declared `nilo_ready`, and the three modules that hold something answer:
`sql.Db` sends `SELECT 1` down the pool and says what came back, an `s3`
Store says whether it started, and a service with no hook — a config struct,
a cache — is assumed ready. A service of your own joins in with one function
([ADR 0192](../adr/0192-a-health-route-asks-the-services.md)):

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

Null is ready; a sentence is why not, and it goes on the page beside the
service's name. **The moment the server is told to stop, the page says
`stopping`**, which is how a balancer learns to drain this instance before its
listener closes rather than after — the other half of [Stopping](#stopping).
Every answer carries `Cache-Control: no-store`.

It is an ordinary route, like the metrics page: mount it where the balancer
can reach it and nothing else needs to, and keep it out of the
[logger](./middleware.md) if a line a second is noise. Nothing about it
touches a request that is not the probe.

## Knowing whether it is working

`app.metrics(.{})` puts a Prometheus page on `/metrics`: requests per route,
status classes, a latency histogram, exact status codes for the process, and
requests in flight. It is an ordinary route, so where you mount it and what you
`use` in front of it is what protects it — nilo puts no authentication on it.
See [Metrics](./metrics.md).

That is the *service* half. The *request* half — a request id you can tie a log
line to — is in [Errors](./errors.md), and the two answer different questions:
metrics tell you something is wrong, a request id tells you which request.

## What isn't here yet

`permessage-deflate`, and compression of a handler's response (files are
compressed — see [Static files](./static-files.md#compression)).

Templates are a refusal rather than a backlog item: nilo is for building APIs
and services, and rendering pages is not what it is for. The reasoning is in
[the roadmap](../roadmap.md#not-coming).

Each item is listed with its reason in [`../roadmap.md`](../roadmap.md); the ones
that are refusals rather than backlog are in [`../adr/`](../adr/).
