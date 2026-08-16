# Errors

## Failing a request

`fail.notFound(...)` and friends can be called from anywhere, with no `Ctx` in
hand — from a handler, from a resolver, from a helper three calls deep, from
inside `zfast.blocking`:

```zig
fn getUser(db: *Db, id: u32) !User {
    return db.find(id) orelse zfast.fail.notFound("no user {d}", .{id});
}
```

Every one of them returns `error.Failed`, having put the status and the message
somewhere the request will find them. So a handler's signature stays `!User`
rather than growing an error set, and a test asserts on `error.Failed` plus the
message.

| | |
|---|---|
| `fail.badRequest(fmt, args)` | 400 |
| `fail.unauthorized(…)` | 401 |
| `fail.forbidden(…)` | 403 |
| `fail.notFound(…)` | 404 |
| `fail.conflict(…)` | 409 |
| `fail.tooLarge(…)` | 413 |
| `fail.unprocessable(…)` | 422 |
| `fail.tooManyRequests(…)` | 429 |
| `fail.internal(…)` | 500 — the message is logged, not sent |
| `fail.status(code, …)` | any status you like |

The message is formatted into a fixed slot — **240 bytes**, no allocation — and
one longer than that is truncated rather than refused. It is written for the
person reading the response, so say what was wrong and what would work:
`fail.notFound("no user {d}", .{id})` beats `fail.notFound("not found", .{})`.

See [ADR 0005](../adr/0005-http-errors-via-fail-functions.md) and
[ADR 0007](../adr/0007-failure-box-bound-to-the-fiber.md) for how the message
finds its way back without a `Ctx`.

## Any other error

An error a handler returns that isn't `error.Failed` goes through a mapping
table: `error.FileNotFound` is a 404, the JSON and number-parsing errors
(`error.InvalidCharacter`, `error.SyntaxError`, `error.MissingField`, …) are
400s, `error.BodyTooLarge` is a 413, `error.Timeout` and `error.Canceled` are
503s. Anything unrecognised becomes a **500 whose error name is logged but not
sent to the client** — `error.DatabaseSchemaMismatch` is your business, not your
caller's.

Either way the connection stays alive: a 404 is a normal thing to answer, not a
reason to hang up.

The one exception is a handler that fails *after* it has already answered. A
half-sent response can't be taken back, so the connection is closed and the log
says so:

```
warning: handler GET /report failed after answering: WriteFailed
```

## What the client is told

The status, and the message — as JSON, always, whatever the endpoint returns on
its happy path:

```
$ curl -i localhost:8787/users/99
HTTP/1.1 404 Not Found
Content-Type: application/json

{"error":"no user 99","status":404}
```

One shape for every failure, from every source: a `fail` function, an error out
of a handler, a body zfast refused, a request head that never finished arriving.
Nothing to configure and nothing to negotiate — a frontend calls `res.json()` in
the same `catch` where it shows the user what went wrong, and it works
([ADR 0025](../adr/0025-every-failure-answers-with-the-same-json-body.md)).

A failure with no message of its own gets the status phrase. Nothing about
zfast's internals goes out — no stack trace, no file name, no Zig error name
unless a `fail` function put it in the message on purpose. A 500 logs the error
name and sends `internal server error`.

In tests, read the field rather than matching the wire:

```zig
const parsed = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
defer parsed.deinit();
try expectEqualStrings("no user 99", parsed.value.object.get("error").?.string);
```

## Tying a failure to its log line

Behind the proxy that zfast assumes in front
([ADR 0028](../adr/0028-tls-is-terminated-in-front.md)), the one thing you
cannot reconstruct afterwards is *which* log lines belong to the request that
went wrong. Switch on request ids and the answer is on the response:

```zig
try app.use(logger.with(.{ .format = .json, .request_id = true }));
```

```
$ curl -i localhost:8787/users/99
HTTP/1.1 404 Not Found
X-Request-Id: 4f2ba81c9d3e7a05

{"method":"GET","path":"/users/99","status":404,"us":59,"request_id":"4f2ba81c9d3e7a05"}
```

Somebody reports "it failed around 14:02" and pastes the header; you grep for
it. `c.requestId()` reaches the same id from inside a handler, so anything you
log yourself can carry it too — and it works whether or not the logger is
installed.

If the proxy already sent an `X-Request-Id`, that one is used, so the id is the
same on both sides. **A client's id is checked, not trusted**: up to 64 bytes of
letters, digits, `.`, `_` and `-` — which every id generator in use produces —
and anything else is ignored in favour of one of zfast's own. Otherwise a
newline in a header would forge a log line and split a response.

Both options are off by default: the id costs a header on every response, and
the plain-text line is what a person reads in a terminal.

## Errors zfast writes for you

You don't have to write any of these; they are what the request never reaching
your handler looks like.

| | |
|---|---|
| 400 | a path param that doesn't convert, a query param that doesn't fit, a body that isn't valid JSON |
| 404 | no route, and no static file |
| 405 | the path exists under another method — with an `Allow` header |
| 413 | a body past `c.body()`'s megabyte, or a stream's `max_bytes` |
| 431 | a request head bigger than `read_buffer` |
| 503 | the request was cancelled while waiting on a lock or a sleep |

Each of them names the thing that was wrong. See
[Requests](./requests.md) for what the 400s actually say.

## Panics are not errors

An integer overflow or an out-of-bounds index is not an error a handler returns —
it takes the whole process down, every in-flight connection with it. There is no
`recover` middleware because there cannot be one. See
[Deploying](./deploying.md#panics) and
[ADR 0008](../adr/0008-no-recover-middleware.md).
