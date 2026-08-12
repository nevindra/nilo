# Roadmap

What is coming, what is refused, and what nobody has decided yet. How each piece
of 0.1.0 got built is in [`history.md`](./history.md); the decisions that are
binding are in [`adr/`](./adr/).

## Next

In order.

1. **Sending to a WebSocket a handler does not hold.** A connection's write
   buffer belongs to the fiber serving it, so broadcasting needs a per-socket
   outbox with its own lock rather than a loop over a list
   ([ADR 0022](./adr/0022-a-websocket-is-a-handler-that-does-not-return.md)).
   Phoenix Channels is the shape, and it is a project rather than a function.
2. **Somewhere honest to measure.** Until there is a machine nobody else is
   using, [ADR 0001](./adr/0001-dx-wins-below-the-10-percent-threshold.md) is not
   active and every conflict goes to DX. `bench/bench.sh` has been in the repo
   since the first stage so that when the machine turns up it is one command away.
3. **Reloading static files without a restart.** A development annoyance rather
   than a design hole: a deploy restarts anyway. Wants a watch option.
4. **`sendfile`, and serving a file too big to hold in memory.** This is the part
   that contradicts [ADR 0010](./adr/0010-static-files-are-held-in-memory.md)
   rather than extending it, so it wants its own argument before any code.
5. **`permessage-deflate`.** Negotiated in the handshake, and a compressor per
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
  *Done, and it was holding less than it looked.* `refusals/` is 39 programs
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
- **The router is still a linear scan.** Which structure replaces it — radix
  tree, per-method buckets, something else — needs numbers nobody has yet. What
  the scan costs was measured in-process: 3.7× at 50 routes, 1.4× at 5, worst
  case with the wanted route last. Whatever replaces it has to keep specificity
  ordering, which is a property of the structure rather than a cost added to it
  ([ADR 0013](./adr/0013-the-most-specific-route-wins-and-duplicates-are-refused.md)).
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
| The `Str` guarantee cannot be complete | The debug-build staleness trap, on from day one ([ADR 0004](./adr/0004-request-arena-and-the-str-type.md)). It missed the case anybody would actually test it with — two separate `curl` calls, where the next connection started counting from the same number the stashed `Str` held — until every connection was given a generation span of its own. What it still cannot watch is a `Str` reached through something nothing walks: a const slice, an untagged union |
| A Service is shared across threads and nothing makes a user notice | `zfast.Mutex`, in the guide and in the example everyone copies. Nothing forces it — Zig has no ownership tracking to force it with ([ADR 0011](./adr/0011-shared-services-need-a-lock-from-the-bulkhead.md)) |
| A panic in any handler takes the whole process down, and Go people will assume otherwise | Cannot be fixed in Zig. Said plainly in the docs, `ReleaseSafe` and a supervisor recommended, and the in-flight request named in the crash ([ADR 0008](./adr/0008-no-recover-middleware.md)) |
| ~~`std.json` may not be fast enough, and it sits on the hot path~~ *Bit, and was fixed.* It was worse than this line imagined, and hid behind a profile taken on the wrong payload | `src/json.zig`, a writer generated from the response type, with `std.json` as the fallback and the tests asserting the two produce identical bytes |
| A response could differ from what `std.json` would have written, now that something else usually writes it | `covers()` decides while compiling which types the generated writer may touch, and it errs narrow: a tuple, a `[N]u8`, a type with its own `jsonStringify`, anything unrecognised, all fall back. Floats are handed to `std.json` field by field rather than reimplemented |
| Deadlines are on by default, so a client on a genuinely bad link could be cut off where it used to be served | The numbers are generous and each bounds one wait rather than a whole request, so nothing legitimate and slow — a big upload, an hour-long stream — is hurried by any of them ([ADR 0023](./adr/0023-a-deadline-belongs-to-an-operation-not-to-a-request.md)) |
| A WebSocket has no read limit, so a client that vanishes without a FIN holds a fiber | Caught by the write limit as soon as the server sends anything. A connection nobody writes to is not, and the answer to that is a ping it fails to answer — a WebSocket feature with its own design, not a number in `Options` |
