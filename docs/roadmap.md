# Roadmap

What is coming, what is refused, and what nobody has decided yet. How each piece
of 0.1.0 got built is in [`history.md`](./history.md); the decisions that are
binding are in [`adr/`](./adr/).

## Next

In order.

1. **A socket read that can be raced against something else, from zio.** This
   is now the thing broadcasting waits on, and it is one exported line
   upstream rather than a design. zio has every piece — `ev.NetPoll(.recv)`,
   `ev.Async.notify`, `ev.Group.init(.race)` — but no public way to park a
   fiber on a completion, so a fiber sitting in a socket read cannot also be
   waiting on a mailbox. Worth **8,673 bytes per connection**: with it, the
   fiber already serving a connection drains its own mailbox and nothing new
   is spent; without it, every connection that can be broadcast to needs a
   second fiber, which is the whole of
   [ADR 0018](./adr/0018-the-trade-budget-has-three-axes.md)'s per-connection
   budget over again
   ([ADR 0029](./adr/0029-a-spawned-fiber-belongs-to-the-server.md)). Asked
   for upstream as [zio#668](https://github.com/lalinsky/zio/issues/668),
   with the measurement — so this one is now somebody else's call rather than
   ours, and worth checking before anything below it is picked up.
2. **Sending to a WebSocket a handler does not hold.** Blocked on the above,
   and no longer blocked on knowing what to build.
   [ADR 0022](./adr/0022-a-websocket-is-a-handler-that-does-not-return.md)
   guessed at a per-socket outbox with its own lock; a spike measured that
   and it is exactly as dead as the naive version, because the problem is
   not locking — the speaker's own fiber does the writing, so it blocks on
   the first connection that has stopped reading. `zfast.spawn` shipped out
   of that work; broadcast did not.
3. ~~**Somewhere honest to measure.**~~ *Done, and it changed two of our own
   numbers.* [ADR 0001](./adr/0001-dx-wins-below-the-10-percent-threshold.md)'s
   10% rule is active: [`benchmarks.md`](./benchmarks.md) is zfast alone and
   [`comparison.md`](./comparison.md) is eight other servers through the same
   harness. What it cost to get right is in
   [`history.md`](./history.md) — an SMT core split that had both halves on the
   same eight cores, and a release build blamed on comptime when half of it was
   debug info. `bench/compare/` is the harness; `drive.py` runs it.
4. **Reloading static files without a restart.** A development annoyance rather
   than a design hole: a deploy restarts anyway. Wants a watch option.
5. **`sendfile`, and serving a file too big to hold in memory.** This is the part
   that contradicts [ADR 0010](./adr/0010-static-files-are-held-in-memory.md)
   rather than extending it, so it wants its own argument before any code.
6. **`permessage-deflate`.** Negotiated in the handshake, and a compressor per
   connection is memory that has not been budgeted.

## Known gaps

Things that are wrong or missing today, with what fixing them would take.

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
  happens when the pool is empty, what it does to a stream, what it does to
  SSE, which is the one thing that must never be buffered), and it has not been
  had yet. A proxy in front does this today and does it well.
- ~~**A static file served through any middleware costs one allocation.**~~
  *Done, and the test that was supposed to catch it had been written to step
  around it.* The chain, not the file: a path that matched no route had nothing
  precomputed, so `handleRequest` built its chain out of the request arena, and
  every asset behind a logger or a CORS paid one allocation —
  [ADR 0018](./adr/0018-the-trade-budget-has-three-axes.md)'s hard invariant,
  broken in the shape nearly every app deploys. What kept it invisible was the
  budget test's own opening line: *"No middleware, deliberately… it would hide
  the thing being measured here."* Chains are now resolved for static files at
  `listen()` beside the routes' — **per file, not per set**, which is the part
  worth keeping. A set has one URL prefix but a middleware can be scoped below
  it (`static("/assets")` with `useOn("/assets/private", auth)`), so one chain
  for a whole set would be the chain for `/assets` and that auth would silently
  never run. The budget test now puts middleware in front and counts that it
  ran, because "allocated nothing" is also what an empty chain looks like.

  What still costs one allocation is a 404 or a 405 with middleware
  registered, and it stays that way on purpose: the set of paths that are
  neither a route nor a file is every string there is, so there is nothing to
  precompute for. It is one arena allocation on a cold path, bounded by the
  number of `use` calls.

- **The linker cannot drop what nobody uses.** The API description costs +14 KB
  on the hello example and +34 KB on rest whether or not `docs()` is called,
  because the switch is a runtime `null` check
  ([ADR 0017](./adr/0017-the-api-description-comes-from-the-signatures.md)).
  Fixing it needs a build option that a `zig fetch` dependent has to thread
  through, which is a worse ergonomic problem than the one it solves.
- **The API description is silent about authentication.** A handler taking a
  `CurrentUser` needs an `Authorization` header and the document does not say so,
  because the header is a line of Zig inside the resolver rather than something
  in a type. Whatever fixes this must not become a second thing to keep in step
  with the resolver — that drift is what the generated document exists to avoid.
- **The API description names one failure, and endpoints have several.** `!?T`
  puts a 404 in the document because the signature settles it
  ([ADR 0024](./adr/0024-a-failure-mode-belongs-in-the-return-type.md)). A
  `fail.conflict` on a duplicate email is a line in a function body and stays
  invisible. That is the rule rather than a gap — the document promises what the
  signature settles — but it is the rule that costs the most, and if a way is
  ever found to state a failure in a type without inventing an annotation, this
  is where it goes.
- ~~**A route that drops to `*Ctx` drops out of the document.**~~ *It did not,
  and that was worse.* It stayed in and was described as answering an empty
  200 — so an endpoint that streamed a CSV or answered 202 was documented as
  answering nothing at all. A handler holding a `*Ctx` and returning nothing
  now says `"this endpoint writes its own response"`, and `listen()` counts
  them: `1 of 12 routes write their own response`. Holding a `*Ctx` is not
  itself the disqualification — a handler that reads a header and still
  returns its answer is described as fully as any other.
- **`describeBadBody` walks eight levels and then stops.** Deeper than that, a
  bad field is a plain 400 again. Same limit as the schema walker and the
  staleness trap, and for the same reason: a type holding one of its own has to
  stop somewhere.
- ~~**Nothing enforces the rule that a mistake stops in zfast's own words.**~~
  *Done, and it was holding less than it looked.* `refusals/` is 46 programs
  written wrong on purpose, each expected to fail with a named message, run by
  `zig build test`
  ([ADR 0027](./adr/0027-the-rule-about-error-messages-is-held-by-a-build-step.md)).
  Writing them found four defects: two messages with no `zfast:` prefix at all,
  a slice passed to `Headers.of` that stopped inside zfast instead of at its own
  message, a two-bodies message blaming the one argument that was already right,
  and zfast's types spelled with zfast's file names (`str.Str`) at people who
  have never opened them. It also showed that the *location* half of the rule
  was failing everywhere: the reader's own line sat one slot outside the
  reference trace Zig prints by default, so every frame they got was zfast's.
  Each registration method now runs the check itself, which puts their line
  first. Nothing asserts that it stays there — the build system has no way to
  make a claim about a reference trace.
- **A group prefix cannot carry a param.** `app.group("/orgs/:org")` is refused,
  because `use` scopes middleware by comparing the front of the request path
  against the prefix and `/orgs/:org` is the front of no real path. Making it
  work means teaching middleware scoping to match patterns rather than prefixes.
- **The logged duration of a streamed response is its lifetime, not its
  latency.** One line per request is the contract, and a stream's line arrives
  when the stream ends. Time to first byte is a different number and wants a
  different feature.
- ~~**The request head is walked twice**, which together is 34% of a
  request.~~ *Done.* Both walks read 32 bytes at a time now, and the colons
  are handled as a bitmask rather than searched for line by line — a head has
  one colon per header that matters and a great many that do not. Finding the
  end went 183ns → 51ns and parsing 303ns → 163ns. It is still two passes:
  merging them would mean recording line boundaries during a scan that has to
  resume where it left off, and the two passes cost 214ns between them.
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
  and it leaves specificity ordering exactly where it was: the routes are still
  walked in registration order and still ranked by `score`, so
  [ADR 0013](./adr/0013-the-most-specific-route-wins-and-duplicates-are-refused.md)
  costs nothing extra to keep. A key collision is not a correctness problem —
  it only means the `mem.eql` that would have run anyway does run — which is
  what allows a key this cheap instead of a real hash.

  **It is not a clean win, and the row that says so is the first one.** At one
  route the key is computed and nothing can be skipped with it, so matching
  goes 26ns → 28ns; the whole-request profile, which runs one route, moves its
  "match the route" line 41ns → 44ns. Three nanoseconds of a ~600ns request,
  spent to take 44% off a hundred-route app. The trade is stated here rather
  than left for somebody to find in a profile.

  Where that leaves the bar: one request is ~610ns of zfast's own work, so a
  25-route app now spends ~7% of it matching, a 50-route app ~13%, and a
  100-route app ~18%. **The scan passes
  [ADR 0001](./adr/0001-dx-wins-below-the-10-percent-threshold.md)'s 10% bar at
  around 40 routes** rather than 30. Better, not solved — and measured
  in-process with no kernel in it, so it is a share of zfast's work rather than
  of a request's wall clock.

  Two things were tried before this and are worth not repeating. A packed
  parallel array of the four fields the scan reads made **mixed 7% faster and
  same-shape 10% slower** — a wash bought with eight bytes per route of
  duplicated state, reverted. And a real hash of the first segment was the
  obvious version of what shipped, but a hash worth the name costs more at one
  route than the `mem.eql` it saves, which is the size most apps are.

  What is left is the actual tree, for the app with hundreds of routes. The
  numbers no longer point at it urgently.
- ~~**`std.json` sits on the hot path** of the metric that matters, at 13% of a
  request.~~ *Done, and it was not 13% — it was 63%.* The profile had been taken
  on a 25-byte payload while the benchmark target answered a kilobyte, and
  `std.json` spends its time escaping strings a byte at a time. `src/json.zig`
  generates a writer from the response type instead, producing byte-for-byte the
  same output; 1038ns → 126ns on that payload. What is left of `std.json` on the
  request path is float formatting and the types the generated writer declines to
  touch.

## Not coming

Not "later" — decided against, with the reasoning written down.

- **A `recover` middleware.** Zig cannot recover from a panic at all, so there is
  nothing to build ([ADR 0008](./adr/0008-no-recover-middleware.md)).
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

- **Sessions.** The cookie half is here now
  ([ADR 0030](./adr/0030-a-cookie-is-a-header-and-set-cookie-is-the-one-that-repeats.md)):
  `c.setCookie`, `c.cookie`, `c.clearCookie`, and a resolved value reading the
  cookie is the whole of a signed-in user. What is not here is the half that
  is policy — where the session is stored, whether the cookie carries an id or
  a signed payload, what signs it, and how it is rotated. That is the same
  line [ADR 0016](./adr/0016-resolved-values-are-declared-by-their-type.md)
  draws around authentication, and it is not obvious there is a shape zfast
  should have an opinion about rather than an example of.
  [`examples/forms`](../examples/forms/main.zig) is the example.
- **Templates.** A real ask, and no shape yet. What makes it hard in Zig is
  that the two obvious answers are far apart: comptime-checked templates,
  which are a compiler of their own, and runtime string interpolation, which
  is a worse `std.fmt`. Nothing in between has been argued for.
- **Multipart, streamed.** `Form(T)` reads a multipart body whole, bounded by
  `max_body` ([ADR 0031](./adr/0031-a-form-is-the-body-read-by-another-rule.md)),
  which is right for a form with a photo in it and wrong for a 2 GB video.
  The streaming version wants a parser that resumes across reads and an
  `Upload` that is a reader rather than bytes — a real design, and one that
  belongs next to `sendfile` above rather than on its own. Until then the
  answer is `c.bodyStream()`, which holds nothing and makes the framing the
  handler's problem.
- ~~**Somewhere to put work that is not a request.**~~ *Decided and shipped.*
  It is `zfast.spawn(f, args)`, a fiber owned by the running server rather
  than by whatever started it, so shutdown counts it and cuts it off exactly
  like a connection
  ([ADR 0029](./adr/0029-a-spawned-fiber-belongs-to-the-server.md)). The two
  open questions this entry ended on both got answers: a fail function there
  has no request to fail and says so, and a `Str` must not travel into one at
  all — it points into an arena that is about to be reset, and nothing in the
  compiler will stop you.
- **The name.** `zfast` is a working name. The `z-` prefix is crowded in the Zig
  ecosystem already (`zap`, `zzz`, `zon`, a dozen `zig-*`), so it is easy to
  confuse. The module name has to stay easy to change without touching user code,
  which is why nothing above the import line spells it.

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
| ~~`std.json` may not be fast enough, and it sits on the hot path~~ *Bit, and was fixed.* It was worse than this line imagined, and hid behind a profile taken on the wrong payload | `src/json.zig`, a writer generated from the response type, with `std.json` as the fallback and the tests asserting the two produce identical bytes |
| A response could differ from what `std.json` would have written, now that something else usually writes it | `covers()` decides while compiling which types the generated writer may touch, and it errs narrow: a tuple, a `[N]u8`, a type with its own `jsonStringify`, anything unrecognised, all fall back. Floats are handed to `std.json` field by field rather than reimplemented |
| Deadlines are on by default, so a client on a genuinely bad link could be cut off where it used to be served | The numbers are generous and each bounds one wait rather than a whole request, so nothing legitimate and slow — a big upload, an hour-long stream — is hurried by any of them ([ADR 0023](./adr/0023-a-deadline-belongs-to-an-operation-not-to-a-request.md)) |
| A WebSocket has no read limit, so a client that vanishes without a FIN holds a fiber | Caught by the write limit as soon as the server sends anything. A connection nobody writes to is not, and the answer to that is a ping it fails to answer — a WebSocket feature with its own design, not a number in `Options` |
| The request head is the one thing a stranger writes directly, and every test of it was an input somebody thought of | `src/fuzz.zig` states properties instead: the head boundary and the framing fields are checked against a byte-at-a-time reference implementation, over a corpus on every `zig build test` and over a million generated inputs on every CI run (`zig build fuzz`). Coverage-guided fuzzing is not available — `zig build test --fuzz` fails to compile inside std's own test runner on Zig 0.16.0 — so the generator is the substitute, and the targets are written to become coverage-guided the day that is fixed |
| Nothing bounds how many connections one process holds | `.max_connections`, 10,000 by default. Past it a connection is accepted and closed at once, so the failure mode is a client that finds out immediately rather than an OOM kill that takes every in-flight request with it |
| Spawned work can capture a `Str`, or call a fail function, and both compile | Neither can be caught: Zig has no ownership tracking, and `spawn` takes a plain function that nothing marks as being outside a request. Documented at the function, in the reference and in [ADR 0029](./adr/0029-a-spawned-fiber-belongs-to-the-server.md), and `spawn` takes its arguments by value so the copy is at least the obvious thing to write. A `Str` that escapes this way is the debug staleness trap's problem, and it is the case that trap cannot watch |
| A fail function in spawned work is safe only because of where a threadlocal gets written | `bulkhead.slot()` falls back to a threadlocal when a fiber has no slot, which spawned fibers never do. It is null on executor threads only because the one thing that sets it does so from inside `zio.blockInPlace`, which runs on a thread-pool worker. Both ends now carry a comment saying so; nothing enforces it, and if it broke, spawned work would write its message into an unrelated request — [ADR 0007](./adr/0007-failure-box-bound-to-the-fiber.md)'s leak by another route |
| `zio.BroadcastChannel` aborts, or in `ReleaseFast` deadlocks, when a fiber parked in `receive` is cancelled | Not used, and now reported upstream with a standalone reproduction. A waiter node is pushed onto a queue it is already linked into (`simple_queue.zig:43`, from `broadcast_channel.zig:72`). Debug aborts 10 runs in 10, ReleaseSafe 3 in 3, and `ReleaseFast` — which has no such assertion — **hangs 17 runs in 20** where a clean run takes 200ms. Cancellation is what reaches it: the same program closing the channel and waiting is clean 5 in 5. A shared ring forces the cancel, having no per-consumer close ([ADR 0029](./adr/0029-a-spawned-fiber-belongs-to-the-server.md), [zio#667](https://github.com/lalinsky/zio/issues/667)) |
