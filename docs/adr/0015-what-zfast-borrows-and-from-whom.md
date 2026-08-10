# What zfast borrows, and from whom

`docs/plan.md` has said since stage 1 that **the model is GoFiber**. That was the right call for v1 and it is the wrong one for v2, so this ADR replaces it.

Fiber was chosen for a good reason: the audience is people coming from Go and Node, and Fiber is what "comfortable" looks like to them. What it is not is a design zfast can keep following, because v1 already overtook it in the two places that decide the shape of everything above `Ctx`:

- **Fiber has no typed handlers.** Every handler is `func(c *fiber.Ctx) error`. The compile-time argument matching in `src/typed.zig` is a different kind of framework, and there is nothing left in Fiber to copy for it.
- **Fiber's best-known footgun is the one v1 closed.** `c.Params()` returns text pointing into a buffer that the next request reuses, and the rule saying so lives in the documentation. `Str` and `keep` (ADR 0004) put that rule in the type system. Fiber gave up where zfast did the work.

So Fiber stays as the **tone** — familiar, unceremonious, running in ten minutes — and stops being the architecture. What follows is where the architecture comes from instead.

## FastAPI: the signature is the only source of truth

FastAPI's contribution is not that it made Python fast. It is that **you write the function signature once and everything else is derived from it** — validation, the error messages, the OpenAPI document, and a page you can click through.

zfast already has the hard half. `fn getUser(db: *Db, id: u32) !User` is a contract the compile-time engine reads, and it already produces the argument matching and the 400s. What it did not produce was a description of the API, and that gap has an unusually good price in Zig: the whole thing is comptime type information, so a generated OpenAPI document costs **nothing on the request path**. It is the largest DX gain available that ADR 0001 does not even get a vote on.

Landed as `app.docs(…)` — see ADR 0017.

## Elysia: values are resolved, and plugins carry their own routes

Elysia is the closest philosophical neighbour zfast has, despite sharing no language. It compiles each route ahead of time into a specialised function that prepares only what that handler actually touches — the same move as `typed.wrap`, done at startup with codegen instead of at compile time.

Two of its mechanisms answer questions v1 deliberately left open.

**`resolve` answers ADR 0009's one real gap.** Middleware cannot hand a value to a handler, and the concrete cost of that is auth: it can reject a request but cannot pass the user it just looked up. The tempting fix is Go's `context.Value` or axum's `Extensions` — a runtime map keyed by type, stored as `anyopaque`, cast on the way out. ADR 0009 already refused that shape by name ("a `c.locals` map that would smuggle untyped state back in through the side door") and it was right to.

Elysia's answer is that the value is *declared*, not stashed, and Zig can do it better than either: a type says how it is worked out, a handler asks for it by writing it in its argument list, and the chain is checked while compiling. Landed as **resolved values** — see ADR 0016.

**Scoped plugins answer the route-group deferral.** ADR 0009 deferred groups on the grounds that they only save repeating a prefix, which is true of groups as a naming convenience and false of them as a packaging unit. What is actually missing is a way to hand somebody a thing that carries its own routes *and* its own middleware, mountable wherever they want it — the difference between a framework people extend and one they only use. Landed as `app.group(...)`; a plugin is an ordinary function that takes one.

## nginx and TigerBeetle: memory is bounded, not merely fast

For the "kenceng dan low memory" half, the framework not to copy is fasthttp. Its instinct — reuse everything, allocate nothing per request — is correct, and it leaked into its API, which is where Fiber's footgun came from. Reuse is right; making the user carry the rule is not.

The two worth copying both hold the same line:

- **nginx**: memory for a request is taken from a pool and dropped in one go (v1's request arena is this), and **a module is either compiled in or absent**. In Zig that reads as: a v2 feature nobody calls must not cost a byte of binary, a field on `Ctx`, or a branch on the request path. Resolved values and the OpenAPI document are both built this way — a route that asks for neither runs exactly the code it ran before.
- **TigerBeetle**: allocate at startup, then stop allocating, and put a number on every limit. That is what keeps p99 flat, and it is the discipline behind v1's "three allocations per request, held there by a test".

This is what ADR 0018's per-axis budget is made of.

## Elm: the compiler is on your side

The standard the compile-time layer is held to already exists and has a name. Elm's error-message culture — say what is wrong, in words, and say what to do about it — is what Rust borrowed and what stages 6 through 8 of v1 were converging on independently.

Worth stating as a rule because v2 makes it harder: a chain of resolved values is exactly the sort of thing that produces a wall of `@compileError` from four frames deep. The failure mode to avoid is **axum's**, whose extractors are a good idea served with 200 lines of unreadable trait errors. Every new comptime check in v2 fires at the first place a human named the thing, says what is wrong in words, and says the fix — or it does not ship.

## What is deliberately not copied

- **Rails, NestJS, Spring.** Convention-over-configuration plus runtime DI plus reflection. For this audience it reads as a framework that is hiding something, and every gram of it is paid at runtime.
- **Batteries-included as a goal.** v1's rejections are worth as much as its acceptances (`docs/plan.md`), and that stays true.

## Consequences

- `docs/plan.md`'s "the model is GoFiber" is replaced by this document. The README's audience sentence does not change: still people coming from Go and Node.
- Three v2 items now have a decided shape rather than an open question: resolved values, groups and plugins, and generated API documentation.
- The claim being chased changes. v1 chased "http.zig for Go people". v2 chases **"the signature is the whole contract"** — a handler you can read, test as a plain function, and get documentation from, on a server whose memory you can put a number on.
- What this ADR does *not* decide: streaming responses, bodies over 1 MB, WebSocket and SSE, range requests and `sendfile`. Those are engine-shaped rather than DX-shaped, they each need the request arena to stop being the only answer to where memory comes from, and none of them is waiting on a philosophy. They stay in `docs/plan.md` as work.
