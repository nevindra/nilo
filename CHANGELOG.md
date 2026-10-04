# Changelog

What changed between one tag and the next, not what changed between commits.
This file holds the release that has not been tagged yet;
[the releases page](https://github.com/nevindra/nilo/releases) holds the ones
that have, one page each. What was measured and what was got wrong on the way is
in [`docs/history.md`](./docs/history.md); what is coming is in
[`docs/todo.md`](./docs/todo.md), and what was refused or answered is in
[`docs/decided.md`](./docs/decided.md).

## Unreleased

### Breaking

- **`nilo.Stream.init` and `initClosing` take the request's `Framing` where they took the connection's `*std.Io.Writer`.** Both are what `Ctx.stream` builds, and nothing in the reference shows them; a test that built a `Stream` by hand against a buffer builds a `Framing` around that buffer first (`.{ .http1 = .{ .in = &reader, .out = &writer, .minor_version = 1 } }`). Every answer now leaves through the framing that carried its request, which is the first stage of HTTP/2 for more than gRPC ([ADR 253](docs/adr/253-an-answer-is-handed-to-the-framing-that-carried-its-request.md)).
- **A header set after the answer's head was written is refused with an error**, where it used to be dropped without a word. A middleware that set a header after `try next.run(c)` and saw it reach the client never did; it calls `next.hold(c)` instead, or sets the header before `next`, or with `defer c.setHeader(...) catch {};` for one that must cover failures too ([ADR 008](docs/adr/008-middleware-is-an-onion-of-ctx-functions.md)).
- **`c.setHeader("grpc-status", …)` and `c.setHeader("grpc-message", …)` are refused.** Set them with `c.setTrailer`, which works the same on HTTP/2 and HTTP/1.1 ([ADR 254](docs/adr/254-an-answer-can-carry-trailers.md)).
- **A gRPC call that fails with `error.AlreadyExists` answers `ALREADY_EXISTS` (6), and one that fails with `error.RolledBack` answers `ABORTED` (10)**, where they answered `ABORTED` and `UNAVAILABLE` from their HTTP status. A client that retried on those codes sees the right ones now.
- **`App.grpcHost` is a compile error in a build without `-Dgrpc`**, where it compiled and was undefined behaviour in ReleaseFast if reached.
- **The idempotency and cache record encoders take the answer's trailers** beside its headers. A record written before reads the same.

### Added

- **`c.setTrailer(name, value)`**, a field sent after the body: a HEADERS frame on HTTP/2, a trailer section on a chunked HTTP/1.1 stream, and on a whole HTTP/1.1 answer when the client sent `TE: trailers`. With it `c.trailers()`, `c.clientReadsTrailers()`, `Ctx.checkTrailer`, and `.trailers` on `nilo.Response(T)` and `nilo.Status(code)`. A route that sets none pays nothing ([ADR 254](docs/adr/254-an-answer-can-carry-trailers.md)).
- **`next.hold(c)`**, which hands a middleware the answer below it unwritten as a `nilo.Answer` (`status`, `body`, `setHeader`, `setTrailer`, `replace`), written when the chain has unwound. A body sent with `c.send` under a hold is copied into the arena, free under 16 KiB and costly above it; **`c.sendKept`** sends one that already outlives the chain without the copy ([ADR 008](docs/adr/008-middleware-is-an-onion-of-ctx-functions.md)).
- **A unary gRPC call is about a fifth faster in process, makes one allocation fewer, and a `-Dgrpc` build is 46 KB smaller**: the call reaches the App as what was read and its answer is collected by the framing, where both used to be written as HTTP/1.1 and parsed back (876 to 887 ns a call, from 1,083 to 1,118; [ADR 253](docs/adr/253-an-answer-is-handed-to-the-framing-that-carried-its-request.md)). Its metadata is held to the same rules an HTTP/1.1 head is, as it was.

## Released

Every tagged release has a page of its own, written for the person upgrading: what to do before deploying, and what is new. Every entry of a release, the whole account, is that tag's own `CHANGELOG.md`, which the page links to.

- **[v0.7.0](https://github.com/nevindra/nilo/releases/tag/v0.7.0)** ([every entry](https://github.com/nevindra/nilo/blob/v0.7.0/CHANGELOG.md)): a long list of wrong results returned without an error, fixed, and what was missing when a log server was ported onto nilo. A failed statement that committed as success, a delete a search box could empty a table with, pages that repeated rows, a cache hit an old slot could forge, closed; routes per listener, a body limit from configuration, OpenTelemetry tracing and `nilo_proto`, Rooms shared by sockets and event streams, and a Row that reads a feed, a cursor and a column of another table. Seventy-one things to read before deploying, grouped by who meets them there.
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
