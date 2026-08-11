# A failure mode belongs in the return type

[ADR 0017](./0017-the-api-description-comes-from-the-signatures.md) says the API description is read off the signatures, and [ADR 0015](./0015-what-zfast-borrows-and-from-whom.md) puts the ambition plainly: *the signature is the whole contract*. Building a CRUD app end to end is where that turns out not to be true yet.

A CRUD contract is three things: what goes in, what comes out, and how it fails. The signature carries the first two well. The third lived entirely in the function body:

```zig
fn getTodo(store: *Store, id: u32) !Todo {
    return store.find(id) orelse fail.notFound("no todo {d}", .{id});
}
```

Everything a client needs to know about the 404 is in that line, and a `@compileError` cannot read a function body. So the generated document said the endpoint answers 200, and nothing else. A generator handed that produces `getTodo(): Promise<Todo>` with no 404 branch anywhere in it — for the single most common endpoint there is.

The same gap, one step along, for the status:

```zig
fn createTodo(incoming: NewTodo) !Response(Todo) {
    return .{ .status = 201, .headers = …, .value = created };
}
```

`Response(T)`'s status is a runtime field, so the document writes `default`. That is honest — claiming 200 for a route that answers 201 would be worse — but a document whose every write endpoint says `default` is not one anybody can generate against.

## What was considered and refused

- **An annotation.** FastAPI's answer, `responses={404: …}`, and it works. It was refused because it is a second thing to keep in step with the code, which is the exact drift the generated document exists to prevent. The roadmap already refuses it once, for authentication.
- **Reading `fail.*` calls out of the body.** Zig has no reflection over a function body, and even if it did, a `fail.notFound` inside a helper three calls down would be missed — so the answer would be sometimes right, which is worse than always silent.
- **Documenting a 404 on every route with a path param.** Cheap, and wrong: `PUT /todos/:id` on an upsert never 404s, and a document that cries 404 everywhere is one people stop reading.

## The two decisions

**`!?T` means "this may not be there", and null goes out as a 404.**

```zig
fn getTodo(store: *Store, id: u32) !?Todo {
    return store.find(id);
}
```

The failure mode is in the signature, so `answerOf` reads it exactly as it reads the success shape. There is nothing extra to keep in step, because there is nothing extra.

The slot was free. `!?T` used to answer `200` with the body `null`, described as `anyOf: [Todo, null]` — a thing nobody means by a get-by-id, and a thing every client crashes on. Taking it costs nobody anything real and deletes the `orelse fail.notFound(…)` that was on the end of every read handler in the app.

**`Status(code, T)` puts the status in the type.**

```zig
fn createTodo(incoming: NewTodo) !Status(201, Todo) {
    return .{ .headers = .of(&.{…}), .value = created };
}

fn deleteTodo(store: *Store, id: u32) !Status(204, void) {
    if (!try store.remove(id)) return fail.notFound("no todo {d}", .{id});
    return .{};
}
```

It carries the same headers a `Response(T)` does and behaves identically at runtime; the only difference is that the code is settled while compiling, so the document writes `"201"` instead of `"default"`.

`Response(T)` stays, and is still right where the status genuinely depends on what the handler found — a 200 or a 201 out of the same upsert. What changed is that it stopped being the only choice, and so stopped being what everybody reached for by default.

## What is still not in the contract

Every other status. A 409 from a duplicate email, a 422 from a rule the types cannot state, a 403 from a resolver — those are still `fail.*` calls in a body and are still absent from the document. That is deliberate and not a staging post: the rule this ADR sets is that **the document promises what the signature settles, and nothing else**. A failure that is a matter of what the data turned out to be is not something a type can promise, and inventing a way to write it down would be inventing the annotation this refused.

## Consequences

- **`!?T` is a breaking change** for anybody relying on `200 null`. There is no deprecation path — the two behaviours are the same signature — and the old one is a bug magnet nobody asked for. Where the null really is the answer, `Response(?T)` is not the way out either; return a struct with a nullable field, which says what it means.
- The 404 message for one of these is `there is no /todos/99`, because the path is all the framework knows. A handler wanting a better sentence still writes `orelse fail.notFound(…)` and gets both: the message it chose, and the 404 in the document.
- `Response(void)` compiles, which it did not. `sendValue` had no `void` case while `answerOf` already had one — an unreachable branch on one side of a bridge that was out. `.{ .status = 204 }` and `Status(204, void)` both now answer a real 204, with neither `Content-Type` nor `Content-Length` (RFC 9112 §6.2).
- A bare `!void` answers an empty 200 with no `Content-Type`, where it used to send `text/plain` for a body of nothing.
- ADR 0018 is untouched: this is all comptime data and a branch that compiles away. Nothing allocates and no per-request work is added.
