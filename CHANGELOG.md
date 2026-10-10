# Changelog

What changed between one tag and the next, not what changed between commits.
This file holds the release that has not been tagged yet;
[the releases page](https://github.com/nevindra/nilo/releases) holds the ones
that have, one page each. What was measured and what was got wrong on the way is
in [`docs/history.md`](./docs/history.md); what is coming is in
[`docs/todo.md`](./docs/todo.md), and what was refused or answered is in
[`docs/decided.md`](./docs/decided.md).

## Unreleased

Nothing yet. Work lands here under `### Breaking`, `### Added`, `### Changed` and `### Fixed`, newest first.

## Released

Every tagged release has a page of its own, written for the person upgrading: what to do before deploying, and what is new. Every entry of a release, the whole account, is that tag's own `CHANGELOG.md`, which the page links to.

- **[v0.8.0](https://github.com/nevindra/nilo/releases/tag/v0.8.0)** ([every entry](https://github.com/nevindra/nilo/blob/v0.8.0/CHANGELOG.md)): Zig 0.17, and HTTP/2 as a framing of every request on the port HTTP/1.1 is on, with RPC as plain functions over gRPC, Connect and JSON. More mistakes refused while compiling (two path params by name, a JWT check with no issuer or audience, a `Str` handed to `spawn`), a connection ended after about 1,000 requests, and what services meet in production across `nilo_fetch`, `nilo_job`, `nilo_sql` and `nilo_s3`. Forty entries ask something of you, the page says which first.
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
