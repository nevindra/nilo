# Roadmap

What is coming, what is refused, and what nobody has decided yet. How each piece
of 0.1.0 got built is in [`history.md`](./history.md); the decisions that are
binding are in [`adr/`](./adr/).

## Next

In order. The first one is not close to the others in importance.

1. **Deadlines.** There is no read timeout, no header timeout, no write timeout.
   A client that opens a connection and goes quiet parks a fiber until TCP gives
   up, and streaming makes that easy to do on purpose: open an event stream,
   never read it, hold a fiber. This is the largest hole in the project. It wants
   one decision about deadlines — where they are set, what a handler sees when one
   fires, whether a stream can extend its own — rather than a knob bolted onto
   each feature. [ADR 0020](./adr/0020-a-request-that-lasts-is-still-one-request.md)
   records it and declines to solve it.
2. **Sending to a WebSocket a handler does not hold.** A connection's write
   buffer belongs to the fiber serving it, so broadcasting needs a per-socket
   outbox with its own lock rather than a loop over a list
   ([ADR 0022](./adr/0022-a-websocket-is-a-handler-that-does-not-return.md)).
   Phoenix Channels is the shape, and it is a project rather than a function.
3. **Somewhere honest to measure.** Until there is a machine nobody else is
   using, [ADR 0001](./adr/0001-dx-wins-below-the-10-percent-threshold.md) is not
   active and every conflict goes to DX. `bench/bench.sh` has been in the repo
   since the first stage so that when the machine turns up it is one command away.
4. **Reloading static files without a restart.** A development annoyance rather
   than a design hole: a deploy restarts anyway. Wants a watch option.
5. **`sendfile`, and serving a file too big to hold in memory.** This is the part
   that contradicts [ADR 0010](./adr/0010-static-files-are-held-in-memory.md)
   rather than extending it, so it wants its own argument before any code.
6. **`permessage-deflate`.** Negotiated in the handshake, and a compressor per
   connection is memory that has not been budgeted.

## Known gaps

Things that are wrong or missing today, with what fixing them would take.

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
- **A group prefix cannot carry a param.** `app.group("/orgs/:org")` is refused,
  because `use` scopes middleware by comparing the front of the request path
  against the prefix and `/orgs/:org` is the front of no real path. Making it
  work means teaching middleware scoping to match patterns rather than prefixes.
- **The logged duration of a streamed response is its lifetime, not its
  latency.** One line per request is the contract, and a stream's line arrives
  when the stream ends. Time to first byte is a different number and wants a
  different feature.
- **The router is still a linear scan.** Which structure replaces it — radix
  tree, per-method buckets, something else — needs numbers nobody has yet. What
  the scan costs was measured in-process: 3.7× at 50 routes, 1.4× at 5, worst
  case with the wanted route last. Whatever replaces it has to keep specificity
  ordering, which is a property of the structure rather than a cost added to it
  ([ADR 0013](./adr/0013-the-most-specific-route-wins-and-duplicates-are-refused.md)).
- **`std.json` sits on the hot path** of the metric that matters, at 13% of a
  request. It is the one thing on the profile with no ceiling on how much better
  it could get. Measure before replacing.

## Not coming

Not "later" — decided against, with the reasoning written down.

- **A `recover` middleware.** Zig cannot recover from a panic at all, so there is
  nothing to build ([ADR 0008](./adr/0008-no-recover-middleware.md)).
- **Auth contents.** The mechanism is provided — middleware, resolved values —
  and the policy is yours.
- **Benchmark claims without a benchmark machine.** No numbers in the README
  until there is somewhere honest to measure
  ([ADR 0001](./adr/0001-dx-wins-below-the-10-percent-threshold.md)).

## Not decided

- **TLS, sessions, templates.** Each is a real ask and none has a shape yet. TLS
  in particular may stay out on purpose: terminating it in front is what most
  deployments already do.
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
| The `Str` guarantee cannot be complete | The debug-build staleness trap, on from day one ([ADR 0004](./adr/0004-request-arena-and-the-str-type.md)) |
| A Service is shared across threads and nothing makes a user notice | `zfast.Mutex`, in the guide and in the example everyone copies. Nothing forces it — Zig has no ownership tracking to force it with ([ADR 0011](./adr/0011-shared-services-need-a-lock-from-the-bulkhead.md)) |
| A panic in any handler takes the whole process down, and Go people will assume otherwise | Cannot be fixed in Zig. Said plainly in the docs, `ReleaseSafe` and a supervisor recommended, and the in-flight request named in the crash ([ADR 0008](./adr/0008-no-recover-middleware.md)) |
| `std.json` may not be fast enough, and it sits on the hot path | A custom serialiser for the small-JSON path is likely needed; measure first |
