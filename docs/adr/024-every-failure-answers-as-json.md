# Every failure answers as JSON, in a shape the application may name

**Status:** accepted
**Topic:** [errors](../design/errors.md)

## Context

nilo's error messages are the part of it most worth keeping: a body field that does not fit gets `the request body is missing "title" (text)`, not a blob of validator output somebody has to decode first.
That message used to go out as `text/plain`.
Every endpoint nilo is built for answers JSON, so every client of one calls `res.json()`; on a 422 that threw, in the `catch` where the frontend was going to show the user what went wrong.
The best message in the ecosystem was arriving in the one format the code reading it could not accept, and the first thing anybody would write against that is middleware to turn it into JSON, reformatted by hand in every application that uses nilo.

Wrapping the sentence in `{"error":"…","status":400}` fixed that, and for a long time it was the whole answer: one shape, no switch, because a choice between two shapes nilo itself invented gives a caller nothing to base the choice on.
Then a caller turned up for whom that was not true: the fourth service behind one frontend, where the other three had already chosen `{"code":…,"detail":…}` and the frontend's `catch` already reads it from all of them.
That team has no decision to make on their first day, they have a shape, and nilo would not send it.
What they wrote instead was a middleware that caught the error and rewrote the response, and what that loses is everything the fail function built: the sentence sits in a box the middleware has to know about, and the `Allow` a 405 carries, the `WWW-Authenticate` a 401 carries and the CORS headers a request collected are each set by whoever failed, not by a middleware that runs after.
[actix-web](https://github.com/actix/actix-web) took four years and three mechanisms (`ResponseError`, `ErrorHandlers`, `Error::add_response_mapper()`) to reach "the application can rewrite the error body without a middleware", and every one of them leaves the OpenAPI document describing a body the server does not send.

## Decision

### The default shape

```json
{"error": "the request body is missing \"title\" (text)", "status": 400}
```

The sentence is unchanged; `curl` still shows it, one pair of braces further in, and `res.json()` now works.
`status` is in the body as well as the status line because a client that has already given up on the response object still has it.

### A struct the application names

**`app.failures(T)` names a struct, and the struct is the whole contract.**

```zig
const ApiError = struct {
    code: u16,
    detail: []const u8,

    pub fn nilo_failure(status: u16, message: []const u8) ApiError {
        return .{ .code = status, .detail = message };
    }
};

try app.failures(ApiError);
```

The fields are the JSON, the way a handler's return type is.
`nilo_failure` is the one function the type carries: given the status and the fail function's sentence, fill the struct.
nilo writes the value with the same JSON writer a handler's answer goes through, into the same fixed stack buffer the default shape uses, and sends it through the same path, so a 405 keeps its `Allow`, a 401 its challenge, and every failure the headers the request collected.
The API description derives `components.schemas.Failure` from the struct's fields, written inline under that name, so the document and the wire cannot disagree.

**Not a writer.** A shape a type could carry instead, `nilo_write(status, message, w) !void`, was built first and taken out: a writer has to be trusted about what it wrote, so the document would need a second declaration saying what the bytes look like, and the two would drift.
A struct needs no second declaration, and `nilo_failure` cannot fail by signature, because the failure path must not have a failure path of its own and a writer's `!void` would have had one.

**Once.** A second `app.failures` is `error.FailureShapeAlreadySet`, the way a second `app.metrics` is.

### One place writes an error response

The built-in 404 and 405 handlers *fail* rather than answer, so they go through the same function that assembles every other failure body instead of writing one of their own.
A 405 still carries its `Allow` header, and an unset `WWW-Authenticate` challenge is set the same way (`serve.zig`'s `sendFailure`), because a failure response goes out with whatever headers the request collected: that is the same mechanism that keeps CORS headers on an error, and an error response that quietly loses its CORS headers is one the browser refuses to show, at the worst possible moment.

**Except the headers that described the answer the failure replaces.** A handler that set `Content-Encoding: gzip`, `Cache-Control: public, max-age=31536000` and an `ETag` and then failed sent a JSON 409 labelled gzip and cacheable for a year, which a browser cannot read and a CDN keeps. `sendFailure` drops, before it writes, what `http1.describesAnswer` names: `Content-Encoding`, `Content-Language`, `Content-Location`, `Content-Range`, `Content-Disposition`, `Content-Digest`, `Repr-Digest`, `Digest`, `ETag`, `Last-Modified`, `Accept-Ranges`, `Expires`, `Age`, `Location`, and a `Cache-Control` that does not say `no-store`. Everything else stays: `Allow`, `WWW-Authenticate`, CORS and the `Vary` it adds, `Set-Cookie` (a session a middleware refreshed is still refreshed), `Retry-After`, a request id, a security header. **A drop list, not a keep list**, because what a failure must keep is open-ended and an application adds to it, while what describes a body is the closed set RFC 9110 §8, RFC 9111 §5 and RFC 9530 name; a header nilo has not heard of survives, which is the failure a caller can see. **`Cache-Control: no-store` survives** because it forbade keeping the answer, and a failure is no more fit to keep; any other `Cache-Control` granted keeping something that is not going out.

**The five answers that go out before there is a Ctx keep nilo's own shape, never the application's.** A malformed head, a head too long, a head that timed out, a body under a coding nilo cannot read, and a request shed past `max_in_flight` are constants written in one `writeAll`, to a client that did not manage to send a request nilo could route; a shed request costing one write is worth more than an application's envelope.

**A Connect call is answered in Connect's shape, over the application's.** A request carrying `Connect-Protocol-Version: 1`, to a program with a route that reads or answers a message, fails as `{"code":"not_found","message":"…"}` with the same sentence, because its client reads nothing else; every other request keeps the shape above ([ADR 257](./257-a-connect-client-is-told-its-failure-in-connect-words.md)).

## What was rejected

**Negotiating on `Accept`.** `fetch()` sends `Accept: */*` and so does `curl`, so the header cannot tell the browser from the terminal, the two cases this would exist to separate; choosing JSON for `*/*` is the same as choosing JSON always, with a rule on top that never fires.

**A switch between two shapes nilo itself invents**, `errors: .text | .json`.
This was the first position, rejected as two behaviours to test, two to document, and a decision every user has to make on their first day with nothing to base it on: the whole point of one shape was that there was one shape.
It was reversed, not for a switch between nilo's own shapes (that refusal stands), but for a shape the *application* already has: a team behind three other services with a frontend that already reads `{"code":…,"detail":…}` has no decision to make on day one, they have a shape, and the only alternative was a middleware that loses the sentence, the `Allow`, the `WWW-Authenticate` and the CORS headers, four things to get right to change two field names.

**Copying RFC 7807 `application/problem+json`**, both as nilo's own default and as the alternative shape for the application that needed one.
As a default: more fields (`type`, `title`, `detail`, `instance`), a content type most clients do not special-case, and nothing to put in the fields nilo actually knows; `error` and `status` is what there is.
As the alternative: the team that needs a named shape has one already, and the team that does not is served by the default, so a third shape nilo invented would be exactly the switch already refused.

**Every header the request collected going out on the failure**, which was the rule until the audit of `http/` at `39896d2` reproduced the gzip-labelled 409. A keep list was the other way to close it, and was rejected for dropping the headers nilo cannot know about: an application's request id or security header would vanish from exactly the responses somebody is debugging.

**A middleware that sees the response**, actix's `ErrorHandlers` and `add_response_mapper`.
nilo flushes on `send`, so the body would be rewritten after the head had already gone; and it is the shape that loses the sentence and the headers, above.

**The five pre-Ctx constants going through the application's shape too.** They would stop being constants. A 431 is the one of the five a real client can meet, a browser behind a single sign-on; if that ever matters, the shape can be applied to those five once, at `listen()`, into memory, and stay a single write. Not built until somebody meets it.

## What it costs

| Axis | Cost |
|---|---|
| Allocations per request | 0, on either path: a request that succeeds never reads the field |
| Memory per idle connection | 0: the buffer lives on `sendFailure`'s frame, `noinline` and entered only on a failure |
| Throughput and p99 | 0: one null check, on the failure path |
| Binary size, an App that never calls `failures` | +400 bytes on `hello`, +448 on `rest`, stripped `ReleaseFast` |

The stack buffer is sized `fail.max_message * 6 + 256`: `fail.max_message` is a fixed 240 bytes, escaping can turn each byte into six, and 256 is the envelope's own room.
A shape that outgrows the buffer gets nilo's own shape instead, sentence intact, which the first failure in development shows; there is no `std.log.warn` for it, because a log call site costs a kilobyte or two of formatting in the binary of every App, fired or not, whether or not that App ever calls `failures`.
An application that does call `failures` additionally pays its own `json.write` instantiation and `schemaOf`, the same as a handler returning that struct would.
`Refusals`: not a struct; no `nilo_failure`; a `nilo_failure` with the wrong signature.
