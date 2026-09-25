# Changelog

What changed between one tag and the next, not what changed between commits.
This file holds the release that has not been tagged yet;
[the releases page](https://github.com/nevindra/nilo/releases) holds the ones
that have, one page each. What was measured and what was got wrong on the way is
in [`docs/history.md`](./docs/history.md); what is coming is in
[`docs/roadmap.md`](./docs/roadmap.md), and what was refused or answered is in
[`docs/decided.md`](./docs/decided.md).

## Unreleased

### Breaking

- **A WebSocket can sit in more than one `Room`**, and `error.AlreadySeated` is gone from `nilo.Room.Error`. Joining a second room used to be refused; it is now a seat in each, drained by the same `receive`, and `leave` gives up one room and keeps the rest. What to change: a `switch` on the error that names `error.AlreadySeated` drops that arm. `Socket.ticket()`, `inRoom()`, `seatedIn()` and `unseat()`, which were public for the Room's use, are replaced by `seating()` and `leaveRooms()`, and `room.Ticket.index` is a `u32` (ADR 035).
- **The session cookie is `__Host-session` wherever the prefix can hold** (`Secure`, `Path=/`, no `Domain`, the defaults), and that name is read before `session`. A sibling subdomain could plant a `session` cookie of its own under a path of this site, and the victim worked inside the attacker's account. Nobody is signed out: a `session` cookie still opens, and the next `set` moves it. What to change: `app.guard(…, "session")` becomes `app.guard(…, nilo.session.host_cookie_name)`, and a test or a client that reads the cookie by name reads the new one. A session with a `domain`, another `path` or `secure = false` keeps the plain name (ADR 033).

### Added

- **`c.eventsFrom(rooms, .{})` is an event stream fed by Rooms, handed to the connection rather than kept by its handler.** Every post said into the rooms goes out as an event, a comment keeps a quiet connection speaking every 30 seconds, and the stream ends when the client goes or the server stops. It costs 5,184 bytes a connection, an idle connection's figure, where a stream a handler holds costs 21,566. One Room can hold WebSockets and event streams together; a binary post is counted as missed for a stream rather than sent (ADR 227).
- **`room.event(.{ .name, .id, .data })` says one event with a name or an id.** An event stream sends all three; a WebSocket gets `data` as a text message. A line break in `name` or `id` is `error.EventFieldBreaksLine`, new in `nilo.Room.Error` (ADR 227).
- **`nilo.Rooms` lends a Room to a key the application makes up**, from a pool sized at `init`: every tab a user has open joins `"user:42"`, and `rooms.json("user:42", …)` from anywhere reaches all of them. A key nobody is under costs nothing to say into, the last one out gives the Room back, and when every Room is lent a new key is `error.NoRoomFree`, a 503 in `eventsFrom`. `c.eventsFrom` takes `rooms.named(key)` beside or instead of a Room (ADR 228).
- **A Room made with `.history` catches a returning event stream up.** It keeps its latest text posts, bounded by count and by `history_bytes` (64 KiB), and `c.eventsFrom` writes the ones after the client's `Last-Event-ID` before anything new. Give every post in such a Room an id with `room.event` (ADR 229).
- **`nilo.blockingReserved(f, args)` is `nilo.blocking` on a thread of its own**, rather than a place in the pool's queue behind a call already running. For a call made while holding a connection or a lock; every call that finds no idle worker starts one, so it is for callers that are already bounded (ADR 064).

### Changed

- **A gRPC call runs on its connection's thread** rather than the next one round-robin, which sent nearly every call to another thread and its answer back: 2.7x the unary calls a second at 256 connections, and the worst call at 52 ms rather than 1.5 s (ADR 220).
- **zio is pinned at `0299e57` on its `main`**, for `spawnInto` and the fix below, and built with its tasks pinned to the thread they start on through zio's own build option (ADR 199). Nothing to change in an application. One that also depends on zio itself passes `.scheduling = .pinned` to its own `b.dependency("zio", …)` as well, or it builds a second, differently configured zio beside nilo's. A stripped binary is 6.9 KB larger (ADR 017).
- **A cached Postgres statement takes one round trip rather than two.** pg.zig is pinned at `nevindra/pg.zig@0a8dab4`, lalinsky's `ec8cf27` plus two fixes from karlseguin's `master`: a cached statement no longer sends a `Sync` of its own and waits before Bind and Execute, 2.1–3.1 µs off every query over a unix socket and about three times that through a Docker port; and `startup_parameters` now reach the server. Nothing to change in an application. The pin moves back to lalinsky's once lalinsky/pg.zig#13 merges ([`sql.md` §16](bench/result/sql.md#16-the-round-trip-pgzig-wasted-taken-back)).

### Fixed

- **A job whose run is waiting on the database when the server stops goes back to the queue.** nilo_sql answers a statement a cancellation cut off with `QueryFailed` (ADR 223), and the worker only handed a row back on `error.Canceled`: it wrote the run off as a failed attempt instead, in a store call the same cancellation stopped, and the row stayed `running` until its lease ran out, which is the longest `timeout_ms` of any kind. The worker now asks the fiber whether it was cancelled, and what it writes about a row after a run cannot be interrupted, so a run that finished just before the shutdown is `done` too. A worker cut off in its claim no longer logs `claim: QueryFailed` (ADR 232).
- **Under `.{ .hop = nilo }`, one slow SQLite read no longer makes every write time out.** A statement queued on the thread pool behind the slow one while holding its connection, and the next write waited on it. Every statement now gets a worker of its own through `nilo.blockingReserved`, bounded by the Gate already in front of the connections ([zio#745](https://github.com/lalinsky/zio/issues/745), ADR 064).
- **An error returned from `main` in a Debug build exits with its trace**, where it printed `panic: cast causes pointer to be null` and hung, and a panic keeps its stack trace rather than ending in `aborting due to recursive panic`. Both came from zio v0.18.0 under `std_options_debug_io = nilo.debug_io` ([zio#744](https://github.com/lalinsky/zio/issues/744)).
- **A container's CPU quota sets the thread count.** With `threads` left at 0 nilo started one executor per core the host has, which a `docker --cpus`, Kubernetes or systemd quota does not hide, and the quota throttled them: on two CPUs of an eight-core machine, a p99.9 of 71 ms. The count is now the quota rounded up plus one, read from the tightest cgroup limit above the process, and startup says so when it is below the cores. At two CPUs that is 22% more throughput and a p99.9 of 10 ms; at four, 4% more and 0.5 ms; with no quota nothing changes. A `threads` past 64, or a machine with more cores than that, is held to 64 where the engine used to assert (ADR 230).

- **`host()` and `scheme()` believe `X-Forwarded-Host` and `X-Forwarded-Proto` only from a trusted proxy**, by the rule `clientIp()` uses: named in `trusted_proxies`, or counted by `trusted_hops` when none is named. They read `trusted_hops` alone, so an app that named its proxies got `scheme() == "http"` behind TLS, and one that set a hop count to fix that believed a forwarded host from any peer, the reset-link poisoning ADR 090 is there to stop. `scheme()` is `"https"` on a listener with its own TLS (ADR 102).
- **More than eight `X-Forwarded-For` fields no longer makes `clientIp()` answer with the proxy's address.** The last eight fields are read, which are the proxies' end of the list; a client that stuffed the head was read as the proxy, inside an allow-list of private addresses (ADR 102).
- **A control byte anywhere in a request head, a CR that does not end its line, and a method or header name that is not a token are a 400.** `Host: a\r, Upgrade` was one header to nilo and two to a front end that ends a line at the CR, and `Con,nection` a name a front end may split into one it reads. llhttp, Node's parser, refused every one of them; `zig build fuzz-llhttp -Dllhttp` found them (ADR 070, ADR 231). A hand-written client sending such bytes now gets a 400; no browser or HTTP library does.
- **A request-target in none of RFC 9112's four forms is a 400**, and so are an `http` authority a host cannot be spelled as (`http://|/y`) and `http:` with no `//`. `h;tp://x/y` used to be routed as a path (ADR 095).
- **`Connection` is read as a list, and `close` anywhere in it closes.** `keep-alive, close` kept an HTTP/1.1 connection open, and `keep-alive, Upgrade` closed an HTTP/1.0 one (ADR 073).
- **A chunk line ends at CRLF and nowhere else, a chunk extension may not carry a control byte, and a folded header line is a 400.** Each let nilo and a front end frame one request two ways, the TERM.EXT desync among them (ADR 070).
- **Three waits on a client that claimed a whole bound now have one.** The linger after a refused request is one second in all, not one second per read, which let a byte every 900 ms hold a fiber for eighteen hours (ADR 195). The body a handler never read is thrown away under `body()`'s rate floor, not a per-read limit, and a trailer section stops at 8 KiB (ADR 022). A WebSocket client that stops half way through a frame is closed after twice `idle_ms`, where it was never pinged and held its fiber for ever (ADR 021).
- **A box left blank on an optional or defaulted field is the field not given.** A browser sends an empty box as `age=`, and `Form(T)`, `Query(T)` and both `Bound` forms answered a 400 saying an optional age has to be a whole number. An empty `?Str` is still `""`, and a required field left blank is still refused (ADR 132).
- **`c.upgrade(loop, c)` is refused while compiling**, and so is a `*Ctx` anywhere in the loop's state. The Ctx is gone by the time the loop runs, so the loop read the next request's memory (ADR 062).

## Released

Every tagged release has its notes on its own page, which is where the whole
account of it lives:

- **[v0.6.0](https://github.com/nevindra/nilo/releases/tag/v0.6.0)**: nothing needed in front, and read line by line for what a stranger can do. HTTPS, gRPC, compression and a cross-site check behind an option or a flag; every executor accepting and a response flushed before the connection waits; a Row that carries its parent, its children or a sum; and what a client on the socket could forge, crash or read, closed. Eleven things to read before deploying, listed there.
- **[v0.5.0](https://github.com/nevindra/nilo/releases/tag/v0.5.0)** — the
  roadmap read back against the tree: a Row that says more about its own
  table and `sql.Schema` as the one value that reads it, `nilo.Verified` and
  `jwt.Keyring`, `fetch.Target`, `nilo.Text` and `nilo_check`, `nilo-dev`, a
  queue that wakes its workers. Seventy-nine entries; eight things to read
  before deploying, listed there.
- **[v0.4.0](https://github.com/nevindra/nilo/releases/tag/v0.4.0)** — one
  module, `nilo_job`, and the thirty-odd shapes a second port needed: a
  listing page in one statement, an order chosen from a closed set, a route
  answering once per key, a health page, and the two fixes that let the suite
  run on a Mac. Twelve things to read before deploying, listed there.
- **[v0.3.0](https://github.com/nevindra/nilo/releases/tag/v0.3.0)** — the
  release a real port wrote: migrations as a diff against a snapshot and the
  `db` command, deadlines and an allowance per route, a metrics page, sessions
  that expire, and eleven things to read before deploying, listed there.
- **[v0.2.0](https://github.com/nevindra/nilo/releases/tag/v0.2.0)** — 0.1.0 was
  an HTTP server called zfast. 0.2.0 is a toolkit called nilo, and that server
  is one of its eight modules. Includes what to change when upgrading from
  0.1.0.
- **[v0.1.0](https://github.com/nevindra/nilo/releases/tag/v0.1.0)** — the first
  release, published as zfast.
