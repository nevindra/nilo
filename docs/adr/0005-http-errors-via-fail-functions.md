# HTTP errors are sent through fail functions, callable from anywhere

Errors in Zig cannot carry a message — `error.NotFound` is just a name. There is no `error.NotFound{"user 7 does not exist"}`. So "how do I return a 404 with a clear message" is not a question of style but a technical problem that has to be solved.

The usual road — fetch the message through a context object — would collapse the typed handler: if returning a 404 requires holding a `*Ctx`, then nearly every real handler will hold a `*Ctx`, and the tidy shape only ever gets used in the README example.

Hence **fail functions**: free functions that store a message in the request currently running, then return an error.

```zig
fn getUser(db: *Db, id: u32) !User {
    return db.find(id) orelse fail.notFound("no user {d}", .{id});
}
```

Ordinary Zig errors coming from anywhere (a database, a parser, an allocator) are still served: they go through a mapping table, and anything unrecognised becomes a 500 and is logged with its error name.

## Consequences

- There is hidden per-request state. This is acceptable because the Engine already knows which request is running, so the cost is close to zero — but it is still hidden state, and the documentation has to say so plainly.
- Called outside a request (inside a handler's unit test, for instance), a fail function just returns a plain error with no message. Handlers stay testable as ordinary functions.
