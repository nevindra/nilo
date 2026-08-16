# Roadmap

What is coming, what is refused, and what nobody has decided yet. How each piece
of 0.1.0 got built — and what has already been finished and measured — is in
[`history.md`](./history.md); the decisions that are binding are in
[`adr/`](./adr/).

What this document is measured against is
[ADR 0015](./adr/0015-what-zfast-borrows-and-from-whom.md): **the signature is
the whole contract**, on a server whose memory you can put a number on. A
feature that does not serve one of those two is not automatically refused, but
it has to say what it is for.

## Next

In order.

1. **A binding failure that names the field.** `Form(T)` and a JSON body today
   either bind or fail: one field that will not convert is a 400 out of `fail`
   and the request is over, with nothing saying *which* field. For a framework
   whose claim is that the signature is the contract, not being able to name the
   field that broke the contract is the gap that contradicts the most.

   The wanted shape is a handler that can ask for the binding *and* its
   failures, by field name, and choose what to answer — a 422 naming the fields
   is what a REST client expects, and it is the same mechanism a server-rendered
   form would need. jetzig has the thin version (`expectParams(T)` returns null
   when anything is missing), which says *something* was wrong and not *what*;
   naming the fields is the part worth building.

   Two constraints it has to hold: nothing allocated per failed field, and it
   does not become a validation language — zfast's job stops at "this did not
   convert to a `u32`", and whether the age is plausible stays the
   application's.
2. **Sending to a WebSocket a handler does not hold.** Not blocked on a design
   and not blocked on a missing API — blocked on a defect upstream.

   The API is `zio.CompletionQueue`, already public in the v0.17.0 that zfast
   pins, along with `ev.NetPoll`, `ev.Async` and `ev.Completion`
   ([zio#668](https://github.com/lalinsky/zio/issues/668)); nothing upstream has
   to change to make it reachable. The worry that it might inherit
   [zio#667](https://github.com/lalinsky/zio/issues/667) — a waiter node pushed
   onto a queue it is already linked into, which hangs `ReleaseFast` 17 runs in
   20 — was settled by [`spike/completion_queue/`](../spike/completion_queue/):
   **it does not.** A fiber parked on a `NetPoll(.recv)` and an `Async` at once,
   woken from a plain OS thread, then cancelled mid-park, is clean 30 runs in 30
   in Debug, ReleaseSafe and ReleaseFast alike. `ownerCallback` removes a node
   from `pending` before pushing it to `completed`, which is the discipline
   `BroadcastChannel` fails to keep.

   **What blocks it is a different defect, found on the way.** Handing a
   completion that has already fired straight back to `submit` — the obvious
   thing to write, and what a connection would do forever — crashes zio 90 runs
   in 90. `CompletionQueue.submit` sets `c.group.owner` and
   `c.group.owner_callback`, then calls `loop.add`, which for a completion in
   phase `.dead` calls `Completion.reset()` and clears both
   (`ev/loop.zig:831`, `ev/completion.zig:411-414`). The completion then fires
   as a task wake with a null `userdata` and panics in `runtime.zig:1085`.
   `CompletionQueue`'s own tests never re-submit, which is why it has not been
   seen. Building the completion again first works around it, but not for free:
   re-initialising an `Async` clears its `pending` flag, so a notify landing in
   the gap is lost — fine for a spike, not fine for a broadcast, where the whole
   point is that anyone may notify at any time. **Report it upstream before
   building on top.**

   A connection's fiber has to re-arm its wakeup after every message, which is
   exactly the crashing case, so this waits on a two-line fix upstream.
   [ADR 0022](./adr/0022-a-websocket-is-a-handler-that-does-not-return.md)
   guessed at a per-socket outbox with its own lock; a spike measured that and
   it is exactly as dead as the naive version, because the problem is not
   locking — the speaker's own fiber does the writing, so it blocks on the first
   connection that has stopped reading. `zfast.spawn` shipped out of that work;
   broadcast did not.
3. **Reloading without a restart — static files, then the server.** A
   development annoyance rather than a design hole: a deploy restarts anyway.
   The static half is a watch option on `staticWith`, re-reading a directory
   that has changed. The other half is the whole process, and it cannot live
   inside `App` — a running binary cannot rebuild itself, so it belongs in the
   build alongside `zig build run`. jetzig's dev server sums the modification
   times of its source tree and rebuilds when the sum moves, which is about as
   much machinery as this deserves; the part to be careful about is that neither
   half can end up in a release binary.
4. **`sendfile`, and serving a file too big to hold in memory.** This is the
   part that contradicts
   [ADR 0010](./adr/0010-static-files-are-held-in-memory.md) rather than
   extending it, so it wants its own argument before any code.
5. **`permessage-deflate`.** Negotiated in the handshake, and a compressor per
   connection is memory that has not been budgeted.

## Known gaps

Things that are wrong or missing today, with what fixing them would take.

- **Nothing ties a log line to anything else.** The logger writes one plain-text
  line per request — `GET /users/7 200 59µs` — with no request id, no structured
  output, and no counters. Behind the proxy that
  [ADR 0028](./adr/0028-tls-is-terminated-in-front.md) assumes, that is the one
  thing an operator cannot reconstruct afterwards: which log lines belong to the
  request that timed out. The people this is aimed at arrive from ecosystems
  where a correlation id is the default, and it is cheap here — an id read from
  a header or generated per request, carried on `Ctx`, and a JSON line shape as
  an option on `logger.with`. What needs deciding is whether the id is a
  resolved value (so a handler can log with it) or purely the logger's business,
  and metrics are a separate question with a much larger surface.
- **A response body is never compressed, only a file is.** Static files are
  gzipped once while the App is built, which is the shape that costs nothing per
  request ([static files](./guide/static-files.md#compression)). A handler
  returning JSON gets no such thing, and the reason is the one that shaped the
  static half: a deflate compressor needs a 64 KB window, so one per connection
  would multiply the 8,767 bytes an idle connection holds and one per request
  would break the allocation budget
  ([ADR 0018](./adr/0018-the-trade-budget-has-three-axes.md)). The shape that
  fits is a pool of compressors sized to the thread count rather than the
  connection count — four cores, 256 KB, and a request borrows one for as long
  as it is writing. That is a real design with real questions in it (what
  happens when the pool is empty, what it does to a stream, what it does to SSE,
  which is the one thing that must never be buffered), and it has not been had
  yet. A proxy in front does this today and does it well.
- **A 404 or a 405 with middleware registered costs one allocation.** Routes and
  static files have their chains resolved at `listen()`, so neither pays for the
  middleware in front of it. The set of paths that are neither is every string
  there is, so there is nothing to precompute for. It stays that way on purpose:
  one arena allocation on a cold path, bounded by the number of `use` calls.
- **The linker cannot drop what nobody uses.** The API description costs +14 KB
  on the hello example and +34 KB on rest whether or not `docs()` is called,
  because the switch is a runtime `null` check
  ([ADR 0017](./adr/0017-the-api-description-comes-from-the-signatures.md)).
  Fixing it needs a build option that a `zig fetch` dependent has to thread
  through, which is a worse ergonomic problem than the one it solves.
- **The API description is silent about authentication.** A handler taking a
  `CurrentUser` needs an `Authorization` header and the document does not say
  so, because the header is a line of Zig inside the resolver rather than
  something in a type. Whatever fixes this must not become a second thing to
  keep in step with the resolver — that drift is what the generated document
  exists to avoid.
- **The API description names one failure, and endpoints have several.** `!?T`
  puts a 404 in the document because the signature settles it
  ([ADR 0024](./adr/0024-a-failure-mode-belongs-in-the-return-type.md)). A
  `fail.conflict` on a duplicate email is a line in a function body and stays
  invisible. That is the rule rather than a gap — the document promises what the
  signature settles — but it is the rule that costs the most, and if a way is
  ever found to state a failure in a type without inventing an annotation, this
  is where it goes.
- **`describeBadBody` walks eight levels and then stops.** Deeper than that, a
  bad field is a plain 400 again. Same limit as the schema walker and the
  staleness trap, and for the same reason: a type holding one of its own has to
  stop somewhere.
- **A group prefix cannot carry a param.** `app.group("/orgs/:org")` is refused,
  because `use` scopes middleware by comparing the front of the request path
  against the prefix and `/orgs/:org` is the front of no real path. Making it
  work means teaching middleware scoping to match patterns rather than prefixes.
- **The logged duration of a streamed response is its lifetime, not its
  latency.** One line per request is the contract, and a stream's line arrives
  when the stream ends. Time to first byte is a different number and wants a
  different feature.
- **The router is still a linear scan**, but the first segment is indexed now
  and the scan is roughly half of what it was. `zig build profile` measures two
  route sets at five sizes, wanted route last so nothing is captured early.
  **Mixed** is what an app looks like — four methods, three depths — so nearly
  every route is thrown out on the method or the segment count. **Same shape**
  is every route `GET /thingN/:id/leaf`, where not one can be rejected cheaply;
  no real app looks like that, and it is the ceiling.

  | routes | 1 | 5 | 25 | 50 | 100 |
  |---|---|---|---|---|---|
  | mixed, before | 26ns | 48ns | 62ns | 116ns | 193ns |
  | **mixed** | 28ns | 48ns | **45ns** | **81ns** | **108ns** |
  | same shape, before | 52ns | 82ns | 245ns | 445ns | 855ns |
  | **same shape** | 55ns | 60ns | **99ns** | **150ns** | **271ns** |

  What was added is four bytes per route standing for its first segment — its
  length, first byte, last byte and middle byte — compared as one `u32` before
  any `mem.eql` runs. That is the first level of a radix tree without the tree,
  and it leaves specificity ordering exactly where it was, so
  [ADR 0013](./adr/0013-the-most-specific-route-wins-and-duplicates-are-refused.md)
  costs nothing extra to keep. A key collision is not a correctness problem — it
  only means the `mem.eql` that would have run anyway does run.

  **It is not a clean win, and the row that says so is the first one.** At one
  route the key is computed and nothing can be skipped with it, so matching goes
  26ns → 28ns. Three nanoseconds of a ~600ns request, spent to take 44% off a
  hundred-route app.

  Where that leaves the bar: one request is ~610ns of zfast's own work, so a
  25-route app spends ~7% of it matching, a 50-route app ~13%, and a 100-route
  app ~18%. **The scan passes
  [ADR 0001](./adr/0001-dx-wins-below-the-10-percent-threshold.md)'s 10% bar at
  around 40 routes.** Measured in-process with no kernel in it, so it is a share
  of zfast's work rather than of a request's wall clock.

  Two things were tried before this and are worth not repeating. A packed
  parallel array of the four fields the scan reads made **mixed 7% faster and
  same-shape 10% slower** — a wash bought with eight bytes per route of
  duplicated state, reverted. And a real hash of the first segment was the
  obvious version of what shipped, but a hash worth the name costs more at one
  route than the `mem.eql` it saves, which is the size most apps are.

  What is left is the actual tree, for the app with hundreds of routes. The
  numbers no longer point at it urgently.

## Not coming

Not "later" — decided against, with the reasoning written down.

- **Templates.** zfast is for building APIs and services, and rendering a page
  is the thing it is not for. The mechanism argument and the scope argument
  point the same way. Rendering means producing a string per request, which is
  an allocation per request, which is the one axis
  [ADR 0018](./adr/0018-the-trade-budget-has-three-axes.md) treats as a hard
  invariant rather than a budget — the 8,767 bytes and the single allocation are
  what zfast has to sell, and a template layer spends both. And the two shapes
  Zig actually offers are far apart with nothing argued for in between:
  comptime-checked templates, which are a compiler of their own, and runtime
  string interpolation, which is a worse `std.fmt`. [jetzig](https://www.jetzig.dev/)
  is built for that job and does it with zmpl; that is a better outcome for
  everybody than a second half-answer here. A `<form>` posted to a handler
  still works — [`examples/forms`](../examples/forms/) is that, and item 1 above
  is what makes its failures legible.

  This is a refusal of templates, **not** of everything on that side of the
  line. Whether some other convenience from the batteries-included world earns
  its place gets decided one feature at a time, against the two numbers above.
- **A `recover` middleware.** Zig cannot recover from a panic at all, so there
  is nothing to build ([ADR 0008](./adr/0008-no-recover-middleware.md)).
- **TLS.** Terminated in front, and that is the answer rather than the plan
  ([ADR 0028](./adr/0028-tls-is-terminated-in-front.md)). Zig's standard library
  can be a TLS client and not a TLS server, nobody in the comparison wrote their
  own, and the two alternatives are a one-person crypto dependency or a C
  toolchain in the install story. HTTP/2 and a gRPC server go with it, which is
  said out loud because nobody derives it from "no TLS". `Ctx.clientIp()` and
  `.trusted_hops` are this decision's other half.
- **Auth contents.** The mechanism is provided — middleware, resolved values —
  and the policy is yours.
- **Benchmark claims without a benchmark machine.** The condition has since been
  met, so the README carries numbers — but the rule it was protecting still
  holds, and the README states the caveats in the same breath as the figures:
  what the throughput number does *not* mean, and that a handler touching a
  database flattens the whole comparison
  ([ADR 0001](./adr/0001-dx-wins-below-the-10-percent-threshold.md)).

## Not decided

- **Rotating the session secret.** Changing the secret today signs everybody out
  at once, which is correct and blunt. Doing better means a second key to
  decrypt with and a decision about how long to keep it — how many keys, where
  the list comes from, what a cookie sealed under a dropped one does. Nobody has
  asked yet, and the blunt version is not wrong, so this waits for somebody who
  actually rotates.
- **Signing out everywhere.** The other thing a sealed cookie cannot do: it is
  valid until it expires, so revocation is not in the mechanism. The answer
  today is a version number in the session checked against the row the handler
  was fetching anyway ([guide](./guide/sessions.md#what-it-cannot-do)), and it
  is not obvious zfast should have more of an opinion than that — anything
  further is a store, which is the design
  [ADR 0035](./adr/0035-a-session-is-sealed-into-the-cookie.md) declined.
- **Multipart, streamed.** `Form(T)` reads a multipart body whole, bounded by
  `max_body` ([ADR 0031](./adr/0031-a-form-is-the-body-read-by-another-rule.md)),
  which is right for a form with a photo in it and wrong for a 2 GB video. The
  streaming version wants a parser that resumes across reads and an `Upload`
  that is a reader rather than bytes — a real design, and one that belongs next
  to `sendfile` above rather than on its own. Until then the answer is
  `c.bodyStream()`, which holds nothing and makes the framing the handler's
  problem.
- **The name.** `zfast` is a working name. The `z-` prefix is crowded in the Zig
  ecosystem already (`zap`, `zzz`, `zon`, a dozen `zig-*`), so it is easy to
  confuse. The module name has to stay easy to change without touching user
  code, which is why nothing above the import line spells it.

## Zig versions

The latest stable release only, on one branch. The people this is aimed at
download Zig, run `zig build`, and give up if it fails — they are not going to go
hunting for the right branch. The consequence is that every new Zig release
brings a few awkward weeks, made worse by zio following a branch-per-version
pattern too.

0.1.0 needs **Zig 0.16**.

## The standing risks

| Risk | How it is handled |
|---|---|
| zio is a one-person project; it could stop when Zig 0.17 lands | The Bulkhead, fitted from the first stage rather than patched on later ([ADR 0002](./adr/0002-zio-as-the-engine-behind-the-bulkhead.md)) |
| The `Str` guarantee cannot be complete | The debug-build staleness trap, on from day one ([ADR 0004](./adr/0004-request-arena-and-the-str-type.md)). It missed the case anybody would actually test it with — two separate `curl` calls, where the next connection started counting from the same number the stashed `Str` held — until every connection was given a generation span of its own. What it still cannot watch is a `Str` reached through something nothing walks: a const slice, an untagged union |
| A Service is shared across threads and nothing makes a user notice | `zfast.Mutex`, in the guide and in the example everyone copies. Nothing forces it — Zig has no ownership tracking to force it with ([ADR 0011](./adr/0011-shared-services-need-a-lock-from-the-bulkhead.md)) |
| A panic in any handler takes the whole process down, and Go people will assume otherwise | Cannot be fixed in Zig. Said plainly in the docs, `ReleaseSafe` and a supervisor recommended, and the in-flight request named in the crash ([ADR 0008](./adr/0008-no-recover-middleware.md)) |
| A response could differ from what `std.json` would have written, now that something else usually writes it | `covers()` decides while compiling which types the generated writer may touch, and it errs narrow: a tuple, a `[N]u8`, a type with its own `jsonStringify`, anything unrecognised, all fall back. Floats are handed to `std.json` field by field rather than reimplemented |
| Deadlines are on by default, so a client on a genuinely bad link could be cut off where it used to be served | The numbers are generous and each bounds one wait rather than a whole request, so nothing legitimate and slow — a big upload, an hour-long stream — is hurried by any of them ([ADR 0023](./adr/0023-a-deadline-belongs-to-an-operation-not-to-a-request.md)) |
| A WebSocket has no read limit, so a client that vanishes without a FIN holds a fiber | Caught by the write limit as soon as the server sends anything. A connection nobody writes to is not, and the answer to that is a ping it fails to answer — a WebSocket feature with its own design, not a number in `Options` |
| The request head is the one thing a stranger writes directly, and every test of it was an input somebody thought of | `src/fuzz.zig` states properties instead: the head boundary and the framing fields are checked against a byte-at-a-time reference implementation, over a corpus on every `zig build test` and over a million generated inputs on every CI run (`zig build fuzz`). Coverage-guided fuzzing is not available — `zig build test --fuzz` fails to compile inside std's own test runner on Zig 0.16.0 — so the generator is the substitute, and the targets are written to become coverage-guided the day that is fixed |
| Nothing bounds how many connections one process holds | `.max_connections`, 10,000 by default. Past it a connection is accepted and closed at once, so the failure mode is a client that finds out immediately rather than an OOM kill that takes every in-flight request with it |
| Spawned work can capture a `Str`, or call a fail function, and both compile | Neither can be caught: Zig has no ownership tracking, and `spawn` takes a plain function that nothing marks as being outside a request. Documented at the function, in the reference and in [ADR 0029](./adr/0029-a-spawned-fiber-belongs-to-the-server.md), and `spawn` takes its arguments by value so the copy is at least the obvious thing to write. A `Str` that escapes this way is the debug staleness trap's problem, and it is the case that trap cannot watch |
| A fail function in spawned work is safe only because of where a threadlocal gets written | `bulkhead.slot()` falls back to a threadlocal when a fiber has no slot, which spawned fibers never do. It is null on executor threads only because the one thing that sets it does so from inside `zio.blockInPlace`, which runs on a thread-pool worker. Both ends now carry a comment saying so; nothing enforces it, and if it broke, spawned work would write its message into an unrelated request — [ADR 0007](./adr/0007-failure-box-bound-to-the-fiber.md)'s leak by another route |
| `zio.BroadcastChannel` aborts, or in `ReleaseFast` deadlocks, when a fiber parked in `receive` is cancelled | Not used, and now reported upstream with a standalone reproduction. A waiter node is pushed onto a queue it is already linked into (`simple_queue.zig:43`, from `broadcast_channel.zig:72`). Debug aborts 10 runs in 10, ReleaseSafe 3 in 3, and `ReleaseFast` — which has no such assertion — **hangs 17 runs in 20** where a clean run takes 200ms. Cancellation is what reaches it: the same program closing the channel and waiting is clean 5 in 5. A shared ring forces the cancel, having no per-consumer close ([ADR 0029](./adr/0029-a-spawned-fiber-belongs-to-the-server.md), [zio#667](https://github.com/lalinsky/zio/issues/667)) |
