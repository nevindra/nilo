# Errors

**A request is failed by calling a plain function from anywhere, the failure is tied to the fiber serving that request, and the client gets JSON in a shape the application can choose.**

**Guide:** [Errors](../guide/errors.md) · **Reference:** [Failing](../reference/ctx.md#failing)

The code is `http/fail.zig` (`Failure`, `InFlight`, `fail.*`), `http/serve.zig` (`sendFailure`), and `http/http.zig` (the panic handler).

## Overview

```
  handler body
     │
     ├─ fail.notFound("no user {d}", .{id})   ──► Failure (240-byte slot, bound to the fiber)
     │                                                │
     ├─ an ordinary Zig error (db, allocator, …) ─────┤
     │                                                ▼
     └─ !?T returning null ──► 404, in the type ──► sendFailure ──► {"error": "...", "status": 404}
                                                       (or app.failures(T)'s shape)

  a panic ──► process aborts; the panic handler names the request that was running, nothing recovers it
```

## Rules

1. **A fail function stores a message and returns an error, and it can be called without a `*Ctx`.** `fail.notFound("no user {d}", .{id})` works in any function a handler calls, so the typed layer does not collapse into everything needing a Ctx. [ADR 004](../adr/004-http-errors-via-fail-functions.md)
2. **An ordinary Zig error is still answered.** Any error a handler returns that did not come from a fail function goes through a mapping table; an unknown error becomes a 500 and is logged by name. `app.errors` adds the App's own rows to that table, read first, so a service layer's `error.EmailTaken` is a 409 without importing `nilo_http`; a 5xx never sends the error's name, the logger reads the same rows, and the document lists them for routes whose inferred error set holds the error. [ADR 004](../adr/004-http-errors-via-fail-functions.md)
3. **The message is stored in a fixed 240-byte slot on the `Failure`; one that does not fit is kept whole in the request arena, up to 16 KiB, when a request holds one.** Failing must not be able to fail, so the common message never allocates, the slot never grows, and outside a request, or when the arena has no room, the message is cut at 240 bytes as it always was. [ADR 006](../adr/006-failure-box-bound-to-the-fiber.md), [ADR 286](../adr/286-a-handler-may-answer-in-several-typed-statuses.md)
4. **The `Failure` is tied to the fiber (through `zio.TaskLocal`), never to the OS thread.** Many fibers share a thread, and a handler that sleeps can resume on a different one. With a `threadlocal`, fiber A's message could end up in fiber B's response, leaking data between users. [ADR 006](../adr/006-failure-box-bound-to-the-fiber.md)
5. **Each connection has one `Failure`, cleared at the start of every request.** A message from a previous request on a reused connection can never carry over. [ADR 006](../adr/006-failure-box-bound-to-the-fiber.md)
6. **Outside the Engine, a threadlocal fallback stands in for the fiber slot.** Unit tests call `App` directly with no fiber and no socket. On a real server the fiber slot always exists and always takes priority. [ADR 006](../adr/006-failure-box-bound-to-the-fiber.md)
7. **`!?T` means the value may be missing: returning null answers 404, and the return type says so.** The API document reads this exactly as it reads the success type, so there is nothing extra to keep in sync (full rule on [`openapi`](./openapi.md)). [ADR 023](../adr/023-a-failure-mode-belongs-in-the-return-type.md)
8. **A handler may return a `union(enum)` of `Status(code, T)` arms**, and the document lists one response per arm; two arms with one status are a compile error. [ADR 286](../adr/286-a-handler-may-answer-in-several-typed-statuses.md)
8. **`Status(code, T)` puts a chosen status in the type; `Response(T)` keeps it a runtime field.** Both carry the same headers and behave the same at run time; only the first lets the document show the real code instead of `default`. [ADR 023](../adr/023-a-failure-mode-belongs-in-the-return-type.md)
9. **Every failure answers as JSON, `{"error": "…", "status": …}` by default, and one about the fields of a body, form or query argument adds `"fields": […]`.** Each entry is `field` (the path as the client spelled it, `items.0.qty`), `code` (a `nilo.FieldCode` tag, public API), `message` and `expected`; the value the client sent is not in it. The list is kept in the request arena behind a second marker in the 240-byte slot, so the `Failure` stays 256 bytes; a failure of no fields, one outside a request, or one the arena had no room for is the sentence alone. The body goes out through the same send path as a handler's own answer, so a 405 keeps its `Allow` header and a 401 its challenge. [ADR 024](../adr/024-every-failure-answers-as-json.md), [ADR 034](../adr/034-a-binding-hands-its-failures-to-the-handler.md)
10. **`app.failures(T)` lets the application define its own error shape once.** `T.nilo_failure(status, message) T` fills it in, nilo writes it with the same JSON writer a handler's answer uses, and the document builds `components.schemas.Failure` from `T`'s fields, so the wire and the document cannot disagree. Calling it a second time returns `error.FailureShapeAlreadySet`. [ADR 024](../adr/024-every-failure-answers-as-json.md)
11. **The five answers sent before a `Ctx` exists always use nilo's own shape, never the application's**: a malformed head, a head too long, a head that timed out, a body in an encoding nilo cannot read, and a request shed past `max_in_flight`. There is no failure struct to fill yet, and keeping a shed request to one write matters more than its format. [ADR 024](../adr/024-every-failure-answers-as-json.md)
12. **A Connect call that fails is answered in Connect's shape over the App's own**, `{"code","message"}` with the same sentence, in a program that has a message route; every other request keeps the shape above. [ADR 257](../adr/257-a-connect-client-is-told-its-failure-in-connect-words.md)
12. **When nilo names a type in a message, it uses the name the reader actually imported**: `nilo.Str`, not the file it lives in inside this repository. Each type has a `pub const nilo_type_name`, and a test at the bottom of `http.zig` rejects an exported type that cannot name itself. [ADR 074](../adr/074-a-type-says-its-own-name.md)
13. **A panic is not a failure, and nothing recovers from one.** Zig cannot unwind and resume, so a panic stops the process. The panic handler names the request that was running (`panic while handling GET /users/42`) using the same fiber slot as `fail`, but the process still exits. [ADR 007](../adr/007-no-recover-middleware.md)

## Decisions

| ADR | What it decides |
|---|---|
| [004](../adr/004-http-errors-via-fail-functions.md) | Fail functions, callable from anywhere, storing a message for the request currently running |
| [006](../adr/006-failure-box-bound-to-the-fiber.md) | The `Failure` is tied to the fiber, not the thread; its slot is 240 bytes with no allocation, and a longer message goes to the request arena (286) |
| [023](../adr/023-a-failure-mode-belongs-in-the-return-type.md) | `!?T` documents a 404 and `Status(code, T)` a chosen status; every other failure is a body-only `fail.*` call |
| [286](../adr/286-a-handler-may-answer-in-several-typed-statuses.md) | A union of `Status` arms answers in several typed statuses, one response each in the document; a fail message past 240 bytes is kept whole in the request arena up to 16 KiB |
| [024](../adr/024-every-failure-answers-as-json.md) | Every failure answers as JSON; `app.failures(T)` lets the application define its own shape once |
| [257](../adr/257-a-connect-client-is-told-its-failure-in-connect-words.md) | A Connect call's failure is `{"code","message"}`, over the App's shape (topic framing) |
| [074](../adr/074-a-type-says-its-own-name.md) | A nilo type carries `nilo_type_name`, so a message names the type the reader imported |

Related topics: a panic stopping the process and naming the request, instead of being recovered, is in [`middleware`](./middleware.md) (ADR 007), because that decision was made where a `recover` middleware would otherwise have gone. What a signature puts in the document, and what stays hidden in a `fail.*` call, is the same rule seen from the other side in [`openapi`](./openapi.md) (ADR 016, ADR 023, ADR 024). A body field reporting its own failures instead of the handler's is [ADR 034](../adr/034-a-binding-hands-its-failures-to-the-handler.md) (request-input).

## Open questions

- **A `fail.conflict` on a duplicate email is a line inside a function and stays out of the document.** `!?T` puts a 404 there because the signature says so, and a `union(enum)` of `Status` arms puts each of its statuses there (ADR 286); a failure thrown from a body is still a sentence the document does not see. The per-field failure list is built for nilo's own shape (ADR 024, ADR 034); what is not is a failure shape of the application's own that receives it (`nilo_failure` has two parameters), and an App-wide error-to-status table (`fail.statusFor`). Those are the two pieces of the roadmap direction "A failure is a type" still open; ADR 286 says how each sits on this.
