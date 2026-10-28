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

**A body, a form or a query argument that did not fit adds `fields`**, one entry for each field that failed, in the order the type declares them:

```json
{"error": "2 fields did not fit: the request body is missing \"address.city\" (text); \"items.0.qty\" has to be a whole number, not text",
 "status": 400,
 "fields": [
   {"field": "address.city", "code": "missing", "message": "the request body is missing \"address.city\" (text)", "expected": "text"},
   {"field": "items.0.qty", "code": "not_that_type", "message": "\"items.0.qty\" has to be a whole number, not text", "expected": "a whole number"}
 ]}
```

`fields` is left out when there is nothing to list, so a 404, a 500, a 401 challenge, a fail function's sentence and the five answers that go out before there is a Ctx are the bytes they always were.
A client reads the sentence or the list, and the list is the one that does not need parsing English: `field` is the path as the client spelled it on the wire, with `.` between names and the index of a list element (`address.city`, `items.0.qty`; a renamed field is under the name it was sent as, [ADR 148](./148-a-field-name-is-a-spelling-too.md)), which is the key a form library's `setError` takes.
`code` is one of **`nilo.FieldCode`**: `missing`, `not_that_type`, `not_one_of`, `too_many`, `unknown_field`, `rule`. **Those tag names are public API.** A client compares against them, so one is not renamed or removed without a `CHANGELOG.md` entry saying what a client changes. They are a list of their own and not `Reason` ([ADR 034](./034-a-binding-hands-its-failures-to-the-handler.md)) shown through, because `Reason` is what a conversion can fail at inside nilo and may change with it, while this is what a client is told; `bound.codeOf` is the one `switch` between the two. `expected` is what the field would have taken, in the words the sentences use, when it is known, and a rule of the application's own has none.
**The value the client sent is not a field of its own**, so a password never reaches a log through the list; `message` carries the sentence the field already had, which quotes what arrived where that sentence always did (`not "soon"`) and nowhere else.

Every field that failed is listed, not the first. A plain `Form(T)`, a JSON body struct and a `Query(T)` stop at the first field they cannot read, as they must, and only after that read has failed read the same request again with the collecting readers `Bound` is built on; a request that fits runs none of it. A key the endpoint does not take is a field of its own (`unknown_field`) and, when an object has one, "what is missing" is not asked of that object: a typo is both at once and the second would count one mistake twice.
Past `fail.max_fields` (64) the list stops and the sentence still counts the rest.

The list lives in the request arena, behind a second marker in the Failure's slot beside the one a long message uses: its first eight bytes point at a `Detail` (the sentence and the entries), so `@sizeOf(Failure)` stays 256 and a connection pays nothing for it ([ADR 153](./153-an-authorization-header-a-handler-can-ask-for.md)). `Failure.fields()` is empty for every other failure, outside a request, and when the arena has no room, and then the sentence is the whole answer, as it was.
The body that carries it is built in the arena like a long message's, so `sendFailure`'s stack frame does not grow.

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

**A body of `error` and `status` and nothing else**, which was the default until a client could not mark the field that failed: an application that wanted its form to outline `email` parsed English, because nilo knew the field, what was wrong with it and what would have worked ([ADR 034](./034-a-binding-hands-its-failures-to-the-handler.md)) and joined them into one sentence in a 240-byte slot, ending in "and N more". The sentence stays, so nothing that read it breaks, and the list rides beside it.

**Copying RFC 9457 (RFC 7807) `application/problem+json`**, both as nilo's own default and as the alternative shape for the application that needed one.
It is still refused, now that nilo has per-field detail to put in it: the members it fixes (`type`, `title`, `detail`, `instance`) are ones nilo has nothing to say for, the list would be an extension member of the application's choosing anyway, and the content type is one most clients do not special-case, where `res.json()` on `application/json` is what every frontend already calls.
As the alternative: the team that needs a named shape has one already, and the team that does not is served by the default, so a third shape nilo invented would be exactly the switch already refused.

**Keeping the first field only for a plain argument**, `Bound` being the way to ask for the rest. It left the common endpoint, the one with no `Bound` in its signature, answering a form of five mistakes with one, and a client had to fix and resend five times.

**`code` as `Reason`'s own names** (`not_a_number`, `not_true_or_false`, `not_a_choice`, `wrong_kind`). They are a list written for nilo's sentences, and a client switching on them would be broken by the next conversion nilo learns; three of them differ only in the type, which `expected` already says.

**Every header the request collected going out on the failure**, which was the rule until the audit of `http/` at `39896d2` reproduced the gzip-labelled 409. A keep list was the other way to close it, and was rejected for dropping the headers nilo cannot know about: an application's request id or security header would vanish from exactly the responses somebody is debugging.

**A middleware that sees the response**, actix's `ErrorHandlers` and `add_response_mapper`.
nilo flushes on `send`, so the body would be rewritten after the head had already gone; and it is the shape that loses the sentence and the headers, above.

**The five pre-Ctx constants going through the application's shape too.** They would stop being constants. A 431 is the one of the five a real client can meet, a browser behind a single sign-on; if that ever matters, the shape can be applied to those five once, at `listen()`, into memory, and stay a single write. Not built until somebody meets it.

## What it costs

| Axis | Cost |
|---|---|
| Allocations per request | 0 on a request that succeeds, and on a failure that is not about fields. A failure that is, makes three allocations in the request arena for the list and the sentence, and one for each entry's message (`bound`'s sentences are formatted once into a scratch and copied; the JSON walk formats into the arena): the failure path only, for a request that was refused anyway |
| Memory per idle connection | 0: the buffer lives on `sendFailure`'s frame, `noinline` and entered only on a failure |
| Throughput and p99 | 0: one null check, on the failure path |
| Binary size, an App that never calls `failures` | +400 bytes on `hello`, +448 on `rest`, stripped `ReleaseFast`. The fields add the comptime sentence table of `bound.zig` to every `Form(T)` and `Query(T)` in a program (it was only `Bound`'s), and a walk that collects where it returned: **not measured** by `bench/release.py` yet |

The stack buffer is sized `fail.max_message * 6 + 256`: `fail.max_message` is the 240 bytes of the Failure's slot, escaping can turn each byte into six, and 256 is the envelope's own room. A message past the slot is kept whole in the request arena (up to 16 KiB, ADR 006), and its body is built in the arena as well, `len * 6 + 256` bytes, so the frame does not grow; if the arena has no room the message is cut to the slot's, as it was before ([ADR 286](./286-a-handler-may-answer-in-several-typed-statuses.md)). A gRPC call is told the first KiB of it, since `grpc-message` is a header.
A shape that outgrows the buffer gets nilo's own shape instead, sentence intact, which the first failure in development shows; there is no `std.log.warn` for it, because a log call site costs a kilobyte or two of formatting in the binary of every App, fired or not, whether or not that App ever calls `failures`.
An application that does call `failures` additionally pays its own `json.write` instantiation and `schemaOf`, the same as a handler returning that struct would.
`Refusals`: not a struct; no `nilo_failure`; a `nilo_failure` with the wrong signature.
