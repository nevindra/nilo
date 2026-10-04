# Roadmap input for nilo, from reading actix-web

Findings from reading **actix-web** at `ad0d97b` (2026-09-20) — `actix-http`
(the HTTP/1 dispatcher, decoder, encoder and payload), `actix-router`, and
`actix-web`'s extractors, handlers, middleware and server builder — against
`nilo_http` at `ab3c893`. Every line number below is in one of those two
trees. actix's is a shallow clone at `/tmp/actix-web`; it is not in this
repository and the numbers will drift, which is why each anchor also names
the symbol.

The question asked was what nilo can take from it on performance, memory and
DX. The short answer is that the two frameworks made the same trade-offs at
the protocol layer more often than not, and where they differ nilo's choice is
usually the one with a number behind it. What actix does that nilo does not is
a short list, and the first two items on it are the same 13 bytes.

Ordered by what each one changes, not by how hard it is. The last section is
what actix does *worse*, kept so nobody copies it.

---

## Summary

| # | Gap | Module | What it changes | Conflicts with a stated non-goal? |
|---|-----|--------|-----------------|-----------------------------------|
| 1 | No `Date` response header | `nilo_http` | RFC 9110 §6.6.1 compliance; caches and proxies in front compute freshness from it | No |
| 2 | `Connection: keep-alive` on every HTTP/1.1 response | `nilo_http` | 24 bytes a response that HTTP/1.1 already implies | No |
| 3 | Listen backlog is zio's default of 128 | `nilo_http` | connection bursts past 128 pending are dropped by the kernel and retried a second later | No |
| 4 | actix is not in `bench/compare/` | `bench/` | the thread-per-core question the engine measurement left open | No |
| 5 | The logger cannot skip a path | `nilo_http` | `/health` and `/metrics` lines in every production log | No |
| 6 | `Content-Length` and the status line go through `std.fmt` | `nilo_http` | a measurement, not a change, until `zig build profile` says otherwise | No |
| 7 | Named routes and reverse routing | `nilo_http` | a `Redirect` or a `Location` built from a route rather than a string | No — waiting for a caller |

Items 1 and 2 together move nilo's response from 1,110 bytes on the wire to
1,123, which is what Go, axum, Fiber and Bun all send for the same body
([`bench/compare/results/raw.json`](../bench/compare/results/raw.json)).
That is not a coincidence: 1,110 − 24 + 37 = 1,123. The comparison in
[`docs/comparison.md`](./comparison.md) currently credits nilo with a header it
should be sending and debits it for one it need not.

---

## 1. No `Date` response header

**What actix does.** A `DateService` per worker thread keeps a 29-byte
formatted date and a cached `Instant`, refreshed by a 500 ms interval task
(`actix-http/src/date.rs:64`, `date.rs:75`). The encoder writes it into every
response head unless the handler set one (`actix-http/src/h1/encoder.rs:221`,
`config.rs:332`): a 37-byte `memcpy`, no clock call, no formatting on the
request path.

**What nilo does.** `writeHead` writes status, `Content-Type`,
`Content-Length`, `Connection`, the extras, and nothing else
(`http/http1.zig:1057`). There is no `Date` anywhere under `http/`, and the
Bulkhead has a monotonic clock only (`http/bulkhead.zig`, `monotonicNanos`).

**Why it matters.** RFC 9110 §6.6.1: an origin server with a clock MUST send
`Date` on every response with a status of 2xx, 3xx, 4xx or 5xx. A cache in
front — a CDN, nginx's `proxy_cache`, a browser — computes freshness from
`Date`; without it, `Age` and `max-age` arithmetic is done against the time of
receipt, which is what the RFC calls "the recipient's best guess". Every
candidate in `bench/compare/` but http.zig sends one.

**What it costs, against ADR 017.** Allocations per request: none — the text
lives in a per-thread or per-engine buffer. Memory per idle connection: none.
Throughput: 37 more bytes per response, about 3% of the wire on the 1,110-byte
benchmark response and to be measured rather than estimated. Binary size: a
date formatter, a few hundred bytes.

**What it needs.** A wall clock in the Bulkhead (ADR 001 — the Engine is the
only file that names zio, and `zio.Timestamp.now(.realtime)` is where it
comes from), and a cache so the formatting is not per request: either actix's
interval task or the cheaper shape — format lazily, and reformat only when the
second has changed, which costs one monotonic read per response that the
logger is already taking. `Ctx.setHeader("Date", …)` by a handler should win,
the way actix's `has_date` check lets it.

## 2. `Connection: keep-alive` on every HTTP/1.1 response

**What actix does.** The `Connection` header is written only when it carries
information: `keep-alive` on an HTTP/1.0 response that is being kept open,
`close` on an HTTP/1.1 response that is being closed, `upgrade` on a 101
(`actix-http/src/h1/encoder.rs:121–134`). An HTTP/1.1 keep-alive response
carries no `Connection` line at all, because persistence is the default.

**What nilo does.** `writeHead` writes `Connection: keep-alive` or
`Connection: close` on every response (`http/http1.zig:1057`, the `print`s at
`:1074` and `:1083`).

**Why it matters.** 24 bytes a response. Go's `net/http` omits it; hyper
omits it; nginx sends it. Both are correct, and the 24 bytes are the
difference between nilo's 1,110 on the wire and the 1,123 everybody else in
the comparison sends once item 1 is in.

**What it costs.** Nothing on any axis; it removes a `print`. The risk is a
client that reads the absence as "close", and no HTTP/1.1 client does — the
default has been persistent since RFC 2068. HTTP/1.0 keep-alive must keep the
header, and nilo already tracks which version arrived (`http1.zig:78`).

**What it needs.** One branch in `writeHead` and the tests under it that
assert the header; then a run of `bench/compare` to put the number in
`docs/comparison.md`.

## 3. Listen backlog is zio's default of 128

**What actix does.** `backlog(1024)` is the default on `HttpServer`
(`actix-web/src/server.rs:135`), documented as "generally set in the 64–2048
range". Go's `net.Listen` uses the kernel's `somaxconn`, 4,096 on a current
Linux; nginx's default is 511.

**What nilo does.** `addr.listen(.{ .reuse_address = … })` at
`http/engine/zio.zig:754` passes no `kernel_backlog`, so zio's default of 128
applies (zio `src/net.zig:34`). `Options` has no field for it.

**Why it matters.** The backlog is how many completed handshakes the kernel
holds for `accept`. Past it, a SYN is dropped and the client's TCP retries a
second later, which is invisible in a server log and visible as a p99 of one
second on connection setup. That happens exactly when a balancer reconnects
every client at once after a deploy — the moment nilo's `shutdown_grace_ms`
and `max_connections` exist for. `ws_idle.py` reached 10,000 connections, but
it opens them one at a time; nothing has measured a burst.

**What it costs.** Nothing per connection: a backlog is a queue *capacity*, and
the kernel allocates only for the connections actually in it. `max_connections`
already bounds what the process accepts, so the two are not in tension.

**What it needs.** A `backlog: u31 = 1024` on `Options`, threaded through to
`listen`, and a measurement — `wrk -c1000` against the current default, where
the connection phase is where the retries would show.

## 4. actix is not in `bench/compare/`

**What actix does.** One accept thread hands connections round-robin to N
workers, each a single-threaded runtime with its own `Rc`-based state,
its own request pools (`actix-http/src/message.rs:75`, `actix-web/src/request.rs:670`)
and its own blocking pool. A connection never migrates between threads, so
nothing in the request path is atomic.

**What nilo does.** zio, with work stealing across `threads` executors, and a
`nilo.Mutex` for any service written to.

**Why it matters.** The engine measurement of 2026-09-21 rejected building an
engine, on the strength of zio being ~10% of CPU. It did not answer whether a
thread-per-core design with no cross-thread traffic would place differently
from tokio's work-stealing one at four cores — axum is on tokio, and axum is the
only Rust row. actix is the other Rust model, the Rust toolchain is already a
requirement of the harness, and the candidate is the same forty lines every
other one is.

**What it costs.** An afternoon, and the box the comparison was taken on.

**What it needs.** `bench/compare/rustactix/` written to the same byte-for-byte
contract `drive.py` enforces (`bench/compare/README.md:83` is where axum is
listed), run interleaved with the existing rows, and a row in
`docs/comparison.md`.

## 5. The logger cannot skip a path

**What actix does.** `Logger::exclude("/health")` and `exclude_regex`
(`actix-web/src/middleware/logger.rs:111`, `:120`); the format string also
carries `%b` bytes sent and `%{Name}i` request headers.

**What nilo does.** `logger.Options` is `level`, `slow_micros`, `format` and
`request_id` (`http/logger.zig:33`). The chain runs on every route, so
`/health` and `/metrics` are logged on every probe, which in a container is
every ten seconds forever.

**Why it matters.** The first thing a production log gets is a filter for the
probe lines, and the second is a grep that has to skip them. `nilo.accept`
already shows the shape of a per-route opt-out.

**What it costs.** Nothing at runtime when unset, in the style the file already
has: `Options` is comptime, so a `skip: []const []const u8 = &.{}` compiles to
a comparison against a constant array, and to nothing when empty. Do not take
`exclude_regex`; a list of paths is the whole need.

**What it needs.** The field, and a line in `docs/reference/middleware.md`.

## 6. `Content-Length` and the status line go through `std.fmt`

**What actix does.** The status line is three byte writes from a `u16`
(`actix-http/src/helpers.rs:8`) and `Content-Length` uses `itoa`
(`helpers.rs:44`); the header loop writes through a raw pointer to skip
bounds checks (`encoder.rs:142`).

**What nilo does.** Twenty-four common statuses are comptime strings
(`http/http1.zig:1040`, `:1044`), which is better than actix's; but
`Content-Length: {d}` and `Content-Type: {s}` go through `out.print`
(`http1.zig:1074`, `:1083`), which is `std.fmt` parsing a comptime format and
formatting an integer at runtime.

**Why it is last.** The three-week lesson in `bench/result/build.md` and the
`http.md` profile both say to measure before believing a formatter is the
cost. `zig build profile` on `GET /users/:id` is the run; if `writeHead` is
under 2% of a request, this item is closed as "measured, not worth it" in
`docs/decided.md`. If it is not, a hand-written decimal writer for a `u64` is
thirty lines.

## 7. Named routes and reverse routing

**What actix does.** `.name("foo")` on a resource and
`req.url_for("foo", &["1"])` (`actix-web/src/request.rs:294`) build a URL from
the pattern, so a redirect after a `POST` does not spell the path twice.

**What nilo does.** Routes have no names; a `Redirect` takes a string
(`nilo.Redirect(status)`, ADR 031). With templates refused (ADR 027) there
is no template engine asking for `url_for`, which is where most frameworks'
demand for it comes from.

**Why it is here at all.** The one place the second spelling bites is a
`POST /items` that answers `Location: /items/42` — the pattern the router
already holds is `/items/:id`. A compile-time
`nilo.pathOf("/items/:id", .{42})` that refuses a pattern no route registered
would be in character; it is a Refusal, not a runtime lookup.

**What would settle it:** a caller with more than a handful of them. Until
then it is a string.

---

## What actix does that nilo already does, or does better

Kept so the next reader does not re-derive them.

- **Zero-copy head, no per-request allocation.** actix parses with `httparse`
  into an uninitialised `[Header; 96]` (`decoder.rs:15`, `:246`), then builds a
  `HeaderMap` — an `ahash` map, one insert per header per request — and keeps
  the values as refcounted `Bytes` slices. nilo borrows the head from the
  connection buffer and scans it on lookup (`http/ctx.zig:442`). For the ten to
  thirty headers a real request carries the scan is cheaper than the hashing,
  and it is why actix needs a `MessagePool` of 128 heads per thread
  (`message.rs:75`, `:103`) and an `HttpRequestPool` of 128
  (`request.rs:670`) to stay allocation-free, and nilo needs a per-connection
  arena and `test "the request path stays inside its allocation budget"`.

- **Request smuggling.** Both refuse a second `Content-Length`, a
  `Transfer-Encoding` beside a `Content-Length`, a `Transfer-Encoding` on
  HTTP/1.0, and treat `Content-Length: 0` as no body (`decoder.rs:305`;
  nilo's `http1.zig:285–335`, ADR 070). nilo additionally refuses a second
  `Host` (`http1.zig:738`); actix does not check.

- **`Expect: 100-continue`.** actix's default `expect` service answers
  `100 Continue` *before* the handler runs (`dispatcher.rs`, `ExpectCall`), so
  a handler that would refuse on the head — a 401, a 413 — has already invited
  the body. nilo sends the interim response at the moment something reads the
  body (ADR 073), which is what the mechanism is for.

- **An unread body.** actix closes the connection after any response to a
  request whose `Content-Length` body the handler never read, and drains only
  chunked ones (`dispatcher.rs:1476`, `should_close_for_unread_payload`). nilo
  discards up to a bound and keeps the connection (`http1.zig`,
  `discardBody`), which is what a JSON `POST` that fails validation wants.

- **Idle memory.** actix's read buffer starts at 8 KiB and grows to 128 KiB
  as a head demands (`dispatcher.rs:39–40`, `:1209`); the write buffer is
  32 KiB (`config.rs:51`). nilo's are 16 KiB and 4 KiB and both are handed
  back to the kernel while a connection is idle (ADR 062,
  `bulkhead.releaseIdlePages`), which is how it holds 4,669 bytes a connection
  where actix's grows with the largest head it ever saw. The 4 KiB write
  buffer is not a limit on response size: zio's writer drains buffered head
  and body slice in one `writev` (zio `src/net.zig:1349`), so a 20 KiB JSON
  response is still one syscall.

- **Pipelining.** actix decodes up to sixteen requests ahead
  (`dispatcher.rs:41`) and answers them in order; nilo leaves the next head in
  the read buffer and answers in order. The order on the wire is the same; the
  number of writes was not, because nilo flushed each response and actix
  flushes once its loop has nothing left to decode. Closed by
  [ADR 201](./adr/201-a-response-is-flushed-before-the-connection-waits.md):
  nilo now holds a response whose successor is already buffered, and the
  Engine flushes before any read that could wait.

- **Backpressure on a body.** actix pauses the socket read when 32 KiB of
  unread chunks are buffered (`payload.rs:17`, `:236`). nilo's `bodyStream`
  reads into the caller's buffer on demand and buffers nothing, so there is
  nothing to pause.

- **Route matching.** Both are a linear scan (`actix-router/src/router.rs:54`);
  actix compiles each pattern to a regex with a static fast path, nilo splits
  once at registration and rejects on segment count. actix caps a pattern at
  16 dynamic segments (`resource.rs:16`). The tree question is already a
  roadmap measurement row.

- **Metrics by route.** actix's `match_pattern()` (`request.rs:226`) builds a
  `String` per call; nilo's counter is the route index the request already
  holds (`http/metrics.zig:15`, ADR 079).

- **Extractors.** actix's `FromRequest` tuples reach 16 arguments
  (`extract.rs:422`) with `Option<T>` and `Result<T, E>` wrappers
  (`extract.rs:144`, `:229`); `JsonConfig` gives a per-scope limit, error
  handler and content-type predicate, 2 MiB by default (`types/json.rs:279`),
  and the raw payload 256 KiB (`types/payload.rs:330`). nilo's typed layer has
  the same shape plus what actix leaves to `serde`: `Within`, `Text`,
  `nilo_check`, `Bound(W)` for the `Result` case, `?T` on a header or a field
  for the `Option` case, `nilo.maxBody` per route, and the OpenAPI document
  from all of it. The one thing actix has here that nilo does not is
  `content_type_required`, and nilo's lenient default — a JSON body is read
  whatever the `Content-Type` says — is the friendlier of the two.

- **Middleware on the response.** actix middleware sees the `ServiceResponse`
  and can rewrite it, which is how `DefaultHeaders`, `ErrorHandlers` and
  `Compress` are built. nilo flushes on `send` (ADR 008), so a header is set
  before `next.run` — `logger.request_id` is the worked example — and the
  error page is a fail function (ADR 004). This is a decision, not a gap.

- **Compression.** actix ships `Compress` with a 64 KiB deflate window per
  response in flight. nilo's shape for the same thing is on the roadmap with
  its cost written down, and it is not being shipped in a worse shape
  meanwhile (ADR 017).

- **Streamed multipart.** `actix-multipart` streams fields and offers a
  `MultipartForm` derive with `TempFile` and per-field limits. nilo's entry is
  already in `docs/todo.md`, under `nilo_http`; the actix
  crate is the design to read when somebody picks it up.

## What actix does worse, so nobody copies it

- **The head timeout applies to the first request only.** `head_timer` is
  armed once, on the first read of a connection, and cleared when the first
  head decodes (`dispatcher.rs:906`, `:1033`). After that the keep-alive
  timer is the only one, and it is cleared the moment a byte arrives — so, as
  far as the state machine reads, a client that sends half of its *second*
  request head and stops holds the connection with no timer running. nilo's
  `header_timeout_ms` is armed for every head, counted from its first byte
  (`bulkhead.zig:272`, ADR 022). Keep that.

- **Keep-alive is five seconds.** `KeepAlive::default()` is 5 s
  (`keep_alive.rs`, `config.rs:200`), below what any browser holds a
  connection for, so in practice the server closes and the client reconnects.
  nilo's 75 s (`bulkhead.zig:283`) is chosen so the client closes, and costs
  4,669 bytes a connection to hold. The two are different answers to the
  same question and nilo's has the number beside it.

- **Half-closed connections are a config flag.** `h1_allow_half_closed`
  (`dispatcher.rs:1426`) exists because the dispatcher once aborted on a
  client FIN and somebody's load balancer sent one after every request. nilo
  answers the request and then reads the FIN, which is the only correct
  behaviour and needs no flag.

- **The linger timeout defaults to zero at one layer and one second at the
  other.** `ServiceConfig` says `client_disconnect_timeout: 0`
  (`config.rs`), `HttpServer` says 1 s (`server.rs:128`). nilo's is one
  number, `linger_ms = 1000` beside `linger_limit = 64 KiB`
  (`http/serve.zig:103–104`), and ADR 195 says why both.
