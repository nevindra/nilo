# Errors

**A handler fails a request by calling a `fail` function from anywhere, and the client always gets the status and a message as JSON.**

**Reference:** [`fail` functions](../reference/ctx.md#failing), [`app.failures`](../reference/app.md#app), [`c.requestId`](../reference/ctx.md#reading) · **Design:** [Errors](../design/errors.md)

## Failing a request

**`fail.notFound(...)` and the other `fail` functions work anywhere, with no `Ctx` in hand:** in a handler, in a resolver, in a helper three calls deep, or inside `nilo.blocking`.

```zig
fn getUser(db: *Db, id: u32) !User {
    return db.find(id) orelse nilo.fail.notFound("no user {d}", .{id});
}
```

Each of them stores the status and the message where the request will find them, then returns `error.Failed`. So a handler's signature stays `!User` instead of growing an error set, and a test checks for `error.Failed` plus the message. The full list is [in the reference](../reference/ctx.md#failing):

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
| `fail.internal(…)` | 500, and the message **is sent** to the client, so keep the database's words and anything else internal out of it |
| `fail.status(code, …)` | any status you like |

The message is formatted into a fixed slot of **240 bytes**, with no allocation. A longer message is cut short, not refused; a list of field names in a body's 400 is shortened to `…, and 6 more` before it can be. The message is for the person reading the response, so say what was wrong and what would work: `fail.notFound("no user {d}", .{id})` is better than `fail.notFound("not found", .{})`.

[ADR 004](../adr/004-http-errors-via-fail-functions.md) and [ADR 006](../adr/006-failure-box-bound-to-the-fiber.md) explain how the message gets back to the response without a `Ctx`.

## How other errors map to a status

**Any error other than `error.Failed` goes through a fixed table:**

- `error.FileNotFound` is a 404.
- The JSON and number-parsing errors (`error.InvalidCharacter`, `error.SyntaxError`, `error.MissingField`, …) are 400s.
- `error.BodyTruncated` is a 400: a body read through `c.bodyStream()` that the client cut short. `c.body()` answers the same cut with a 400 of its own, and both close the connection.
- `error.BodyTooLarge` is a 413.
- `error.BodyTooSlow` is a 408: the body the client announced never finished arriving.
- `error.Timeout` and `error.Canceled` are 503s.
- Anything else is a **500. The error name is logged but not sent to the client**, because `error.DatabaseSchemaMismatch` is your business, not your caller's.

In every case the connection stays open. A 404 is a normal answer, not a reason to hang up.

The exception is a handler that fails *after* it has already started answering. A half-sent response can't be taken back, so the connection is closed and the log says so:

```
warning: handler GET /report failed after answering: WriteFailed
```

## The error response body

**The client gets the status and the message as JSON, always**, whatever the endpoint returns when it succeeds:

```
$ curl -i localhost:8787/users/99
HTTP/1.1 404 Not Found
Content-Type: application/json

{"error":"no user 99","status":404}
```

Every failure has this one shape, whatever caused it: a `fail` function, an error returned by a handler, a body nilo refused, or a request head that never finished arriving. There is nothing to configure or negotiate. A frontend can call `res.json()` in the same `catch` where it shows the user what went wrong ([ADR 024](../adr/024-every-failure-answers-as-json.md)).

A failure with no message of its own gets the status phrase. Nothing about nilo's internals is sent: no stack trace, no file name, and no Zig error name unless a `fail` function put it in the message on purpose. A 500 logs the error name and sends `internal server error`.

### Using your own error shape

**If your frontend already reads another shape, such as `{"code":…,"detail":…}` from three other services, declare a struct and nilo fills it:**

<!-- compiles -->
```zig
const ApiError = struct {
    code: u16,
    detail: []const u8,

    pub fn nilo_failure(status: u16, message: []const u8) ApiError {
        return .{ .code = status, .detail = message };
    }
};
```

<!-- compiles: body -->
```zig
try app.failures(ApiError);
```

```
$ curl -i localhost:8787/users/99
HTTP/1.1 404 Not Found
Content-Type: application/json

{"code":404,"detail":"no user 99"}
```

The struct's fields become the JSON, and `nilo_failure` fills them from the status and the message. A nested struct for `{"error":{"code":…}}` works the same way. Every failure nilo builds uses the shape, with the headers the request collected: a 405 still carries its `Allow`, a 401 its `WWW-Authenticate`, and the CORS headers, cookies and your own headers still go out. What described the answer the failure replaced does not: `Content-Encoding`, `ETag`, `Last-Modified`, `Content-Range`, `Content-Disposition`, `Location`, `Expires`, and a `Cache-Control` that does not say `no-store` are dropped, so a failure is never labelled gzip or kept by a cache for a year ([ADR 024](../adr/024-every-failure-answers-as-json.md)). The OpenAPI document's `Failure` schema is read from the same fields, so it matches what is sent.

A few answers keep nilo's own shape: the ones written before there is a request to route (a malformed head, a head that is too long, a 503 when the server sheds load), because those are constants written in one call. The body is written into a fixed buffer with 256 bytes of room for the fields around the message. A shape that needs more gets nilo's own shape instead, with the message intact, and the first failure in development shows it ([ADR 024](../adr/024-every-failure-answers-as-json.md)).

In tests, read the field instead of matching the raw response:

```zig
const parsed = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
defer parsed.deinit();
try expectEqualStrings("no user 99", parsed.value.object.get("error").?.string);
```

### A Connect client's failure

**A request that says it is a Connect call is answered in Connect's shape**, in a program with a route that reads or answers a protobuf message ([Protobuf and other formats](./requests.md#protobuf-and-other-formats)). Connect clients send `Connect-Protocol-Version: 1`, and when one fails it gets:

```json
{"code": "not_found", "message": "no order 7"}
```

The message is the sentence any other client would get. The code comes from the error first, `error.AlreadyExists` as `already_exists` and `error.RolledBack` as `aborted`, and from the status otherwise, by the table [gRPC](./grpc.md#errors-and-grpc-status-codes) uses. The status stays the one nilo chose, so your logs and metrics read the same either way. Connect's shape wins over one you named with `app.failures`, because a Connect client reads nothing else; every request without the header still gets yours ([ADR 257](../adr/257-a-connect-client-is-told-its-failure-in-connect-words.md)).

## Request ids

**Turn on request ids to match a failed response to its log lines.** Behind the proxy nilo assumes is in front ([ADR 027](../adr/027-tls-is-terminated-in-front.md)), the thing you cannot work out afterwards is *which* log lines belong to the request that went wrong. With request ids on, the answer is on the response:

```zig
try app.use(logger.with(.{ .format = .json, .request_id = true }));
```

```
$ curl -i localhost:8787/users/99
HTTP/1.1 404 Not Found
X-Request-Id: 4f2ba81c9d3e7a05

{"method":"GET","path":"/users/99","status":404,"us":59,"request_id":"4f2ba81c9d3e7a05"}
```

Somebody reports "it failed around 14:02" and pastes the header, and you grep for it. [`c.requestId()`](../reference/ctx.md#reading) gives the same id inside a handler, so anything you log yourself can carry it too, whether or not the [logger](../reference/middleware.md#built-in-middleware) is installed. A call the handler makes through `nilo_fetch` sends it as `X-Request-Id` on the outbound request, so the service on the other end can grep for the same string ([ADR 158](../adr/158-a-request-id-goes-out-with-the-call.md)).

If the proxy already sent an `X-Request-Id`, that one is used, so the id is the same on both sides. **A client's id is checked, not trusted**: it may be up to 64 bytes of letters, digits, `.`, `_` and `-`, which every id generator in use produces. Anything else is ignored and nilo makes its own id. Otherwise a newline in a header could forge a log line and split a response.

Both options are off by default: the id costs a header on every response, and the plain-text line is what a person reads in a terminal.

## Errors nilo writes for you

**These are the answers a client gets when the request never reaches your handler.** You don't write any of them.

| | |
|---|---|
| 400 | a path param that doesn't convert, a query param that doesn't fit, a body that isn't valid JSON, a form sent in the wrong encoding, a WebSocket upgrade that isn't one |
| 401 | an `Authorization(…)` argument with no header behind it, another scheme, an empty token, or Basic that will not decode, with `WWW-Authenticate` saying what would have worked ([Handlers](./handlers.md#arguments-a-handler-can-take)) |
| 403 | a WebSocket handshake from an origin the route did not name ([WebSocket](./websocket.md#origin-check)); an `Idempotent(…)` whose `by` found nobody behind the request |
| 404 | no route, and no static file |
| 405 | the path exists under another method, with an `Allow` header |
| 409 | an `Idempotency-Key` that is still being answered ([Answering once](./idempotency.md)) |
| 408 | a request head or a body that stopped arriving within the [deadlines](./deploying.md#deadlines) |
| 413 | a body past `c.body()`'s megabyte, or a stream's `max_bytes` |
| 422 | a `Bound(…)` argument whose handler answered `b.fail()` ([Forms](./forms.md#collecting-every-field-error-bound)); a JSON body of the wrong shape whose type says `.misfit = 422` ([Requests](./requests.md#json-bodies)); an `Idempotency-Key` reused on a different request |
| 429 | an address past its [allowance](./middleware.md#rate-limiting), with a `Retry-After` |
| 431 | a request head bigger than `read_buffer` |
| 500 | a `Session(T)` asked for with no `session_secret` set, a header value with a control byte in it, a cookie value with a `;` |
| 503 | the request was cancelled while waiting on a lock or a sleep; the [health page](./deploying.md#health-checks) while a service is not ready or the server is stopping |

Each of them names what was wrong. [Requests](./requests.md) shows what the 400s say.

## Panics

**A panic is not an error a handler returns: it stops the whole process**, and every connection in flight with it. An integer overflow or an out-of-bounds index does this. There is no `recover` middleware because there cannot be one. See [Deploying](./deploying.md#panics) and [ADR 007](../adr/007-no-recover-middleware.md).
