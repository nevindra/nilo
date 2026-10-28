# HTTP errors are sent through fail functions, callable from anywhere

**Status:** accepted
**Topic:** [errors](../design/errors.md)

Errors in Zig cannot carry a message — `error.NotFound` is just a name. There is no `error.NotFound{"user 7 does not exist"}`. So "how do I return a 404 with a clear message" is not a question of style but a technical problem that has to be solved.

The usual road — fetch the message through a context object — would collapse the typed handler: if returning a 404 requires holding a `*Ctx`, then nearly every real handler will hold a `*Ctx`, and the tidy shape only ever gets used in the README example.

Hence **fail functions**: free functions that store a message in the request currently running, then return an error.

```zig
fn getUser(db: *Db, id: u32) !User {
    return db.find(id) orelse fail.notFound("no user {d}", .{id});
}
```

Ordinary Zig errors coming from anywhere (a database, a parser, an allocator) are still served: they go through a mapping table, and anything unrecognised becomes a 500 and is logged with its error name.

### The App can add to that table

Code that does not know about HTTP returns its own errors, and `app.errors` gives them a status once, for the whole App:

```zig
try app.errors(.{
    .{ error.EmailTaken, 409 },
    .{ error.NoSuchOrder, 404, "no such order" },
});
```

- **Order of reading:** a fail function's own status, then `app.errors`, then the built-in table, then 500. The table can move an error the built-in one knows (`error.Timeout` to 504, say); a fail function wins because it was said at the place that knew the request.
- **Checked while compiling:** an entry is a tuple of an error, a status from 400 to 599 and optionally a sentence no longer than a failure carries. A status outside the range, an error listed twice and an entry of any other shape are compile errors with refusals. Called twice, the second call is `error.ErrorMapAlreadySet`, as `app.failures` is `error.FailureShapeAlreadySet`.
- **Message policy:** a row without a sentence answers the status's reason phrase; a row with one sends it. A 5xx never sends the error's name, and the log line names it. An error that is not listed is what it was.
- **Lookup:** `ErrorMap.find` is generated while compiling as a run of integer comparisons, one per row, called on the failure path only. A route that never fails runs none of it; the Ctx carries one more pointer (`_errors`, eight bytes) so the logger, which runs inside the chain and has no App, reads the table `sendFailure` reads, and the line and the response agree.
- **The document:** `Operation.errors` holds the names in the handler's error set. Zig 0.17 reads an inferred set (`!T`) through `@typeInfo(...).error_set.error_names` once the body is analysed, which a handler's registration forces anyway; a `*Ctx` handler returns `anyerror` and names nothing. At `listen()` a row adds its status to a route whose set holds the error, unless the document already writes that status for the route. A route with `anyerror` gets nothing from the table, and the document does not guess.

## Consequences

- There is hidden per-request state. This is acceptable because the Engine already knows which request is running, so the cost is close to zero — but it is still hidden state, and the documentation has to say so plainly.
- Called outside a request (inside a handler's unit test, for instance), a fail function just returns a plain error with no message. Handlers stay testable as ordinary functions.
- The message goes out inside a JSON object, the same one for every failure nilo assembles ([ADR 024](./024-every-failure-answers-as-json.md)). Nothing about writing a fail function changed; what changed is what the client parses.
- A message written here is invisible to the generated API description, because it is a call in a function body. The failure a signature *can* state is `!?T`, which is a 404 ([ADR 023](./023-a-failure-mode-belongs-in-the-return-type.md)); writing the `orelse fail.notFound(…)` on top of one gets both the better sentence and the documented status.

## What was rejected

- **A middleware that catches what `next.run(c)` returns.** It works today and nothing says so; it needs the Ctx, runs on every request, cannot be read by the logger (which sits in the same chain and sees the error first) and cannot tell the API document anything. echo's `HTTPErrorHandler`, Fastify's `setErrorHandler` and Nest's exception filters put this mapping in one place for the same reason.
- **A runtime table (`StaticStringMap` or a slice scanned by name).** The error set a handler can return is known while compiling, so the lookup and the document's reading of it need no data; a table would be a second place to forget a row.
- **Mapping only through `fail`.** The reason for this ADR in the first place: the service layer would import `nilo_http`.
