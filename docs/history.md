# How nilo was built

Not what shipped — that is [`CHANGELOG.md`](../CHANGELOG.md) — and not what is coming, which is [`roadmap.md`](./roadmap.md). This is what was *learned*: numbers that were measured, premises that turned out false, designs that were tried and lost. Kept because how a mistake hid is usually worth more than what the mistake was. The decisions that are binding are in [`adr/`](./adr/); the vocabulary is in [`CONTEXT.md`](../CONTEXT.md).

## Where it came from

Through v1 the model was **GoFiber**: the feel of Express, a fast engine underneath, aimed at Go and Node people giving Zig a try. From v2 the architecture comes from elsewhere and Fiber stays only as the tone ([ADR 0015](./adr/0015-what-nilo-borrows-and-from-whom.md)). The audience did not change; the claim did. v1 chased "http.zig for Go people". v2 chases **"the signature is the whole contract"** — a handler you can read, test as a plain function, and get documentation from, on a server whose memory you can put a number on.

**v1's rejections were worth as much as its acceptances**, and the pattern in them is the useful part: range requests, `sendfile`, streaming, groups and hand-offs from middleware were all deferred for want of a *decided shape* rather than for want of work, and each landed later as an addition rather than a rewrite. The one that was not a deferral was a `recover` middleware — Zig cannot recover from a panic at all ([ADR 0008](./adr/0008-no-recover-middleware.md)).

One entry was worse than a deferral. "Router: path params, query params" sat in the v1 scope from stage 1 with only half of it built, and nobody noticed until somebody wrote a handler that wanted the other half ([ADR 0012](./adr/0012-the-query-string-is-a-struct-of-your-own.md)).

## What was measured

- **Primary:** requests per second **and p99** on a routed GET with a path param returning ~1 KB of JSON, keep-alive, no pipelining.
- **Secondary:** memory per idle connection.

p99 is counted so that winning on throughput while stalling the tail does not count. [ADR 0018](./adr/0018-the-trade-budget-has-three-axes.md) turned that separation into the rule: throughput may slip 10% for DX, while allocations per request and memory per idle connection are hard invariants. Published figures are in [`bench/result/http.md`](../bench/result/http.md) and [`comparison.md`](./comparison.md).

Two numbers never needed a quiet machine. **Allocations per request is 1** — the JSON body and nothing else; it was 6, then 3. **Memory per idle connection** was first recorded at ~21 KB, then 16,961 on the real machine, then 8,767 flat once a keep-alive connection stopped holding every buffer page it had ever touched until close, and is **4,669** since the waiting moved to the shallowest frame a connection has ([ADR 0071](./adr/0071-where-a-connection-waits-is-what-it-costs.md)).

### Where the time inside a request goes

**Two things about the profile were wrong for the whole of v1 and v2, and both flattered the framework.**

The first: the end-to-end figure it divided by was the very first loop the program ran, so it paid for a cold arena, a cold instruction cache and a CPU that had not clocked up — 1343ns where the warmed figure was 643ns, so *every percentage was understated by about half*.

The second is worse, because it hid a microsecond. The profiler measured a 25-byte `{id,name}` payload while `main.zig` — the benchmark target, the thing the primary metric is *defined* on — answered with a kilobyte. The row reading `serialise the body 97ns 16.4%` was measuring a response the server never sends; on the real payload `std.json` took **1038ns**, more than everything else in the request put together, invisible for two versions. **A profiler measuring a different payload from the thing being profiled is worse than no profiler.**

### The optimisation pass before 0.1.0

The method mattered as much as the result: each change was A/B'd end to end against a build of the previous commit, best of five runs of 1.5M requests, **on five request shapes at once** — because a change that helps a 121-byte head can hurt a 556-byte one, and only measuring both catches it. The primary metric went 1684ns → 605ns.

What did it, in order of worth: a **JSON writer generated from the type**, since `std.json` writes each brace and field name through the writer separately and escapes a byte at a time (1038ns → 126ns on the primary payload); a **request head walked once** instead of once per line per delimiter, with the colons handled as a mask rather than walked, because a header *value* is full of colons and none of them is interesting (finding the end 183ns → 51ns, parsing 303ns → 163ns); **not copying the head** when nothing will read from the connection again; the **first four response headers inline in the `Ctx`**; and the **query string walked once** the same way as the head.

**What was measured and dropped is worth the same as what landed.** Filtering header lines by their first byte alone was the fastest thing tried — 255ns → 137ns — and it silently accepts a header line with no colon, which this parser explicitly promises not to do. Shrinking `Match` from its eight-param room was worth about 10ns, not worth a public limit. A larger `json_hint` made no measurable difference at all, because the arena extends its most recent allocation in place — a documented constant should not change without a number behind it.

### How the work grows

A third kind of number needs no machine: how the work grows. Finding the end of a request head restarted from byte zero on every read, so a head dribbled in a byte at a time cost a pass per byte — quadratic, and reachable by any client that chooses to be slow. Route matching re-split the request path for every route it tried. Both were fixed on that basis rather than on a benchmark.

## Guards that were only ever observed passing

Three times a guard turned out not to be guarding anything, and each time it was found by accident. Separately each read as bad luck; side by side the shape is visible, and it became [ADR 0033](./adr/0033-a-guard-is-not-a-guard-until-it-has-been-seen-to-fail.md): **a check that has only been seen to pass and a check that cannot fail look identical from the outside**, because passing is the default state of both.

**The suite that was never failing.** `zig build test` printed a red block that reads exactly like a failure report, often enough to be written off as flakiness under load. Underneath it every run said `722/722 tests passed` and exited 0. Two mistakes, each hiding the other: `http/test_root.zig` set a log function that threw every line away and *had never run*, because in a test build the root module is the compiler's own test runner, which declares `std_options` itself — and a run step that already succeeded is cached, so six runs in a row execute the binary once. Green runs were not evidence of anything. **A green run only means something if the run actually ran.**

**The allocation-budget test written to look the other way.** It opened with a comment explaining that it used no middleware deliberately, every word of which was true, and together they meant the one shape nearly every app deploys — assets behind a logger — was the shape the invariant never checked. Static files went down the no-route path and built a chain per request. Chains are resolved at `listen()` now, **per file rather than per set**: a set has one URL prefix, so one chain looks obviously sufficient, but a middleware can be scoped *below* that prefix and would then never run — a silent failure that fails open. The test now counts that the middleware *ran*, because zero allocations is also what an empty chain looks like.

**The build-time number that improved on its own.** [ADR 0027](./adr/0027-the-rule-about-error-messages-is-held-by-a-build-step.md) recorded the refusals as ~9 seconds that "never cache"; a later measurement said they cached and cost 0.5s, and that got written down as a happy accident. They never cached — 46 refusals are ~12.8s of a ~17s run, about 270ms each. **A number saying a cost went away on its own deserves more scrutiny than one saying work made something faster**, not less: there is nobody to argue with it.

Writing ADR 0033 immediately produced a fourth instance. Its first draft listed four incidents of which two were the same one, and misdescribed the first — both caught by opening this file and reading it rather than remembering it.

## The types that were only ever tested against themselves

`sql.Timestamp`, `sql.Uuid` and `sql.Json(T)` each had unit tests — RFC 3339 out of a `Timestamp`, sixteen bytes into a hyphenated `Uuid`, the column name each one claims — and all of them passed. Not one of the three could be read out of a database. pg.zig decodes a struct only when it carries `fromPgzRow` and hits a `@compileError` when it does not, so **a Row with `created_at: Timestamp` in it did not compile** — which is the shape the README, the guide and [ADR 0039](./adr/0039-the-shape-of-a-query-is-settled-while-compiling.md) all open with.

What hid it was the fixture. `sql/live.zig` created a table of `bigint`, `text` and `integer`, so every Row the suite built was made of types the driver already understood — and those live tests are also the module's *only* compile coverage of the driver, because everything else runs against the Fake and a generic method is analysed only where it is called. **A fixture standing in for the real thing has to be made of the hard cases, not the easy ones.** It now carries a `timestamptz`, a `uuid` and a `jsonb`, and asserts on the response body, which pins the read and the `jsonStringify` that was equally untested. The fix needed nothing from the driver — a `Timestamp` is read as the `i64` pg.zig has already moved to the epoch, a `Uuid` as its sixteen bytes, a `Json(T)` as the document's text — so `sql/postgres.zig` is still the only file that names pg.zig.

**And then the same fixture hid a fourth one, because the fix was scoped to the instances instead of to the class.** The three types that were broken went into the fixture and nothing else did — while the roadmap, on the same page, already named an enum column as *the one column type unchecked at startup and fatal at run time*. It was `std.meta.stringToEnum(T, str).?` inside the driver, so a value added by an `ALTER TYPE … ADD VALUE` took the process down rather than the request. Nothing caught it for the same reason as before: no fixture column had that type, so no test ever read one. **A known gap and an untested path are the same fact written in two places, and only one of them fails a build.** The fixture now carries a Postgres enum whose third row holds a value the Zig enum deliberately does not have.

## The cost that no behaviour could reveal

**Every failed statement inside a transaction was paying for a reconnect, and the suite could not have found it by looking at answers.** Postgres marks an aborted transaction with a ReadyForQuery status byte of `E`, which is recoverable by exactly one command; pg.zig maps that byte to the same internal state it uses for a dead socket, and refuses to send anything down either. So `ROLLBACK` came back `ConnectionBusy` and nilo destroyed the connection — correct, and priced in TCP, TLS and auth. It had been true for as long as transactions had, and turned up under a live test written for something else entirely ([ADR 0047](./adr/0047-a-deadline-needs-a-connection-you-hold.md)).

What is worth keeping is why it hid. `Pool.release` destroys the connection *and dials a replacement in the same call*, so the rows arrive, the pool's own `stats()` reads the same, and the next request is served. **A defect whose only symptom is a number nobody prints is invisible to every test written against behaviour** — the fix had to be pinned by reading pg.zig's `pg_pool_dirty` counter, and the assertion was watched to fail before it was kept ([ADR 0033](./adr/0033-a-guard-is-not-a-guard-until-it-has-been-seen-to-fail.md) again, from the other end: not a guard that could not fail, but a fix that could not be seen to work).

The other half is about reading a dependency rather than trusting its shape. Three pg.zig fields looked like features and were not: `QueryOpts.timeout` is commented out behind a `// FIX:`, `AuthOpts.startup_parameters` is accepted and never written to the startup message, and `.fail` means two different things. **A field that exists is not a feature that works, and the check costs one `grep` of the dependency's own source.**

## The cast that was written for a reason that turned out to be false

**`sql.Decimal` reads a `numeric` as `"total"::text`, on the premise that it would otherwise arrive as Postgres's binary sign-weight-scale-limbs form. The premise was not checked until after the code was written, and it is wrong** — with the cast removed the live round trip still returns all twenty-nine significant digits, so pg.zig is handing the column over as text already. The cast was kept, and the reason changed: what it removes is not a decoding bug but a *dependency* on a driver's choice of result format, which nilo does not make and did not design. The number is in the comment so nobody has to re-derive it to decide whether the line can go ([ADR 0050](./adr/0050-a-numeric-is-digits-and-a-string-in-json.md)).

The half that *is* load-bearing was found the same way and is the more useful lesson: pg.zig's `numeric` encoder takes a **float** — `math.isNan(v)`, then `print("{d}")` — so writing through it puts every value through the exact binary-floating-point round trip the column type is chosen to avoid. **The read looked like the hard direction and the write was the one that could silently corrupt.** `$1::numeric` over the digits is what makes it exact.

## What an assert in a dependency means for a public API

**Three of the four things pg.zig gets wrong about arrays are asserts rather than errors**, and an assert is `std.debug.assert` — a panic in Debug and ReleaseSafe, and in ReleaseFast nothing at all, which is the worse half. An array with a NULL in it read into a non-optional element, and an array more than one dimension deep, are both shapes an honest Postgres table produces: any array may hold a NULL, and a column declared `integer[]` will store a two-dimensional value without complaint. So the panic was reachable from ordinary data, and `nilo_sql` reads the array header itself before handing the column to the driver ([ADR 0051](./adr/0051-an-array-is-a-slice-and-a-slice-is-one-deep.md)). The guard was watched to fail — with the check disabled the live test aborts inside `fromPgzRow` — which is [ADR 0033](./adr/0033-a-guard-is-not-a-guard-until-it-has-been-seen-to-fail.md) doing its job for the third time in this module.

The fourth is a plain arithmetic bug and is the one worth remembering the shape of: pg.zig's `jsonb[]` encoder reserves **five** bytes of prefix per element — four for the length, one for the version byte — and writes **four** for a NULL, because the null marker skips the version. The array is then one byte too long per NULL and Postgres answers *incorrect binary data format*. Its `text[]` encoder, which is the same function written once more, sizes what it writes. **Where a dependency has two encoders for the same shape, the one used less is the one to distrust** — and the workaround, casting `$n::text[]::jsonb[]`, is the route the correct encoder already takes.

## The type that could not be built where it was needed

`[]const Str` costs two allocations per row where `[]const []const u8` costs one, and the reason is structural rather than an oversight: a `Str` carries a lifetime marker that comes from the Scope, and the Wire — which is where the slice is built — has no Scope and never will. So the slice is walked a second time above the Wire to attach them. **A type whose construction needs context the producing layer does not have will be built twice, and the place to decide whether that is worth it is before the layer boundary is drawn, not after.** Here it is worth it and the number is stated; the alternative was making a list of text the one place in the module where text is not a `Str`.

## The rule that was published and then not followed

[ADR 0011](./adr/0011-shared-services-need-a-lock-from-the-bulkhead.md) tells users that a Service is shared across threads and mutable state in one needs a lock. `Db` is a Service, and its Debug-only transaction counter was a plain `+= 1`. A trap that fires on correct code is worse than no trap: drift upward makes `deinit` accuse a program of a leak that never happened, drift downward underflows a `usize` and panics. Beside it sat the other half of the same oversight — the trap watched the **cheaper** mistake. An abandoned transaction holds a pool connection until the request ends; an abandoned `stream` holds one until the process does, and nothing was counting those at all.

## The bug that only exists in the mode you deploy in

`Response(T).headers` was a `[]const Header` filled from a literal. When every part of such a literal is comptime-known Zig promotes the array to static memory and the slice is valid for ever; when any part is not — and a `Location` value never is — the array is a **temporary in the handler's own stack frame**, read after that frame is gone. In `Debug` the bytes happen to still be there, so 175 tests passed. In `ReleaseSafe` and `ReleaseFast` it was a segfault, reachable from the README's flagship example, in the mode the README tells people to deploy in.

**What hid it was which tests existed.** The one that passed used literal values only. A `Response` owns its headers now ([ADR 0019](./adr/0019-a-response-owns-its-headers.md)), and `zig build test-all` runs everything in both modes — which caught the same bug from the user's side later, six tests in `examples/orders` passing in `Debug` and failing in `ReleaseSafe` because `&.{ … }` written inside a function is a pointer into that function's frame.

## What the outside passes found

Three passes installed nilo into an empty project and used it — one writing handlers, one running them, one following the README literally, each finding a different class of gap. Then two application trips: a todo API, and deliberately the opposite, an orders domain with lines, an address, a state machine and an upload ([`examples/orders`](../examples/orders/main.zig), kept because a stress test nobody can run again is an anecdote).

What generalises:

- **A dead branch on one side of a boundary is evidence the other side is missing one.** `Response(void)` did not compile: `answerOf` had a branch for it and `sendValue` had no `void` case, so one side documented a case the other could not reach. Two of that trip's errors came from inside `std` rather than from nilo, which breaks the rule below.
- **A failure stated in a function body cannot reach a generated document.** Every read handler ended `orelse fail.notFound(…)` and not one of those 404s appeared, because comptime cannot read a call. The fix moved the failure into the return type — `!?T` and `Status(code, T)` ([ADR 0024](./adr/0024-a-failure-mode-belongs-in-the-return-type.md)) — rather than adding the annotation FastAPI uses, which would have been a second thing to keep in step.
- **A wrong entry in a generated document is worse than a missing one**, because nobody goes looking for it. The roadmap expected handlers dropping to `*Ctx` to fall *out* of the document; they stayed in and lied, describing a 202 with a JSON body as "an empty response".
- **The `Str` staleness trap missed the way anybody would test it.** Two `curl` calls stashed a `Str` and read back stale bytes with no complaint, while the same thing on one keep-alive connection panicked correctly — every connection started its generation counter at zero. The lesson is not about counters: **the case the trap was tested with was the case that could not fail.**
- **Two-fifths of the CRUD app was memory bookkeeping** — 58 lines of dupe/free/lock against 84 lines of handler. That is what owning memory costs in Zig rather than anything nilo does, but the audience is people for whom it is new, so it is in [Services](./guide/services.md#holding-on-to-request-text) now.
- **`rest` had no `DELETE`**, which is why nobody found that `Response(void)` could not compile. An example that shows the easy half is an example that tests the easy half.

## The error-message rule, and the build step that holds it

[ADR 0015](./adr/0015-what-nilo-borrows-and-from-whom.md) borrowed Elm's standard and wrote it with teeth — *fires where a human named the thing, says what is wrong, says the fix, or it does not ship* — and then nothing held it, so checks got past it and were found by accident. `refusals/` is programs written wrong on purpose, each of which has to fail with a message named in a table in `build.zig` ([ADR 0027](./adr/0027-the-rule-about-error-messages-is-held-by-a-build-step.md)). The detail that makes it a rule rather than a pile of assertions is that **the build script supplies the `nilo: ` prefix**, so a check that stops somewhere inside the standard library cannot be written down as passing — only fixed or deleted.

Writing the cases found four defects in the part of the codebase whose message quality had been argued about most, including two messages with no prefix at all *in the file that documents the rule*, and a two-bodies message that blamed the one correct argument in the signature.

Then it exposed something bigger: only the *second* half of the rule was being checked. On the first — fires where a human named the thing — nilo was failing everywhere, because Zig reports a `@compileError` with a reference trace two frames deep and both frames were `http/app.zig`; the reader's own line was third, behind a flag they would have to know to pass. Every registration method runs the check itself now, so the trace starts at the user's line. Measured stripped `ReleaseFast`: **+0 bytes**, all of it comptime.

## Deadlines

The one thing 0.1.0 shipped without that made it unsafe to expose directly: `nc host 8787`, say nothing, and a fiber was parked until TCP gave up.

The decision went the other way from where it looked like it was going ([ADR 0023](./adr/0023-a-deadline-belongs-to-an-operation-not-to-a-request.md)). Not a deadline per request — **a limit on one wait for the network**. A request deadline would have had to kill an hour-long stream and a 4 GB upload on a domestic line, both working correctly, and implementing it honestly would have meant interrupting a handler, which Zig cannot do safely — the same fact that rules out a `recover` middleware. The subtle one is the head, and it is the whole defence: an *absolute* deadline shared by every read, because a client sending one byte a second satisfies a per-read limit of any size forever and never finishes.

**The Engine needed nothing new** — zio already applies a timeout to every operation, so a limit is a field store: no timer, no watchdog fiber, nothing per connection. What the Bulkhead added was the split, and **that split is also the test seam**: `Deadlines` reaches its target through a vtable, so a test hands `App` one that writes down what it was asked for. "The header deadline is armed once, however many reads the head takes" is then a counting assertion that runs in a millisecond, where a socket test would have to wait out a real deadline to prove a negative.

## Broadcast: three dead designs and two false blockers

The question ADR 0022 left open — what does it take to write to a socket this fiber does not own — took two stages to answer, and most of the delay was believing things that were not true.

**The obvious problem is not the problem.** A connection's write buffer belongs to the fiber serving it, so two fibers writing into it interleave frames, and a lock per socket fixes that. It fixes nothing else. Holding the room's lock across every write and holding it only long enough to copy out who was there are **exactly as dead as each other**: eight clients, one handed a socket and then never reading, two healthy clients wanting only to talk to each other — their messages never arrived, in either version. The broadcast is done by the *speaker's own fiber*, which walks the connections, reaches the wedged one and blocks there. **Any design where fiber A writes to socket B ties A's liveness to B's readiness to read**, and no lock granularity touches that.

**So the write has to be done by a fiber that serves only B, and a fiber costs 8,673 bytes** — measured at 400 idle connections, byte-identical across runs. ADR 0018 calls 8,767 a hard invariant, so a writer fiber spends that entire budget a second time. `zio.BroadcastChannel` fixed everything except the number: delivery went from 5,925 of 12,000 messages to 12,000 of 12,000 and the send path collapsed to one call, and idle the two agree to the byte, because a queue that is never written costs nothing. The fiber is the price. It also crashed under connection churn inside zio's own wait queue — a waiter node pushed onto a list it was already in, `runtime_safety`-only, so in `ReleaseFast` the same race relinks the node with nothing said.

**Then the blocking sentence turned out to be false, and it had been false the whole time.** ADR 0029 recorded broadcast as waiting on one exported line upstream: nothing public parked a fiber on a completion. `zio.CompletionQueue` was public in the v0.17.0 this repo already pinned, and had been for the whole time the item sat on the roadmap. The upstream issue asking for the missing API got the answer "there is already `CompletionQueue`". What stood in the way was a search that was not done.

**Then the same thing happened one level down.** A spike proved the wait works and found a real defect on the way — handing a completion that has already fired straight back to `submit` crashes zio 90 runs in 90. The workaround is to rebuild first, the spike measured that the rebuild drops a wakeup, and broadcast was recorded as blocked again. Wrong again, because **there are two ways to rebuild and only one had been tried**: `Async.init()` returns a fresh struct and clears the `pending` flag, while `wake.c = .init(.async)` rebuilds only the completion and leaves the flag alone, so a notify landing in the re-arm window arrives late instead of never.

**The hammer that should have found it could not.** Firing five posts as fast as an OS thread can go — what a broadcast under load looks like — passes with *either* rebuild: all five land before the fiber is scheduled once, and the re-arm window is never occupied. Holding the window open on purpose and posting into it separates them, 30 runs in 30 each way. **A race narrow enough that the obvious stress test cannot reach it is a race the stress test will certify as absent.**

**The price came out at zero**, because ADR 0029's 8,673 bytes were a *fiber* and the mailbox shape adds none — the connection already has one, it just gains a second way to be woken. On the real server at 2,000 idle connections: **8,777 bytes before, 8,773 after**. One warning came out of the spike worth more than the number: given its own allocation, what you pay is not the struct but the next power of two above it — 320 measured as 512, 576 as 1,024, every row exact — so the state lives in the connection's own fiber frame instead.

Two smaller things kept. A spawned fiber has no task-local slot, so `bulkhead.slot()` falls through to a threadlocal, which is what [ADR 0007](./adr/0007-failure-box-bound-to-the-fiber.md) exists to call the wrong answer; spawned work would write its failure message into an unrelated user's response if anything ever set it on an executor thread. Nothing does, because the one place that writes it runs on a thread-pool worker — **a real invariant held up by a coincidence of scheduling**, now commented at both ends. And the first version of `join` refused a socket with no Engine behind it, which was correct and made the entire feature untestable without a running server; seating it anyway costs nothing and let eight tests drive the whole thing over fixed buffers.

## After 0.1.0: what the router scan actually costs

"No machine to measure on" had been doing more work than it should. It is true of *throughput*; it is not true of the pieces, which `zig build profile` measures in-process and always could. The linear scan had been sitting under the first excuse while being answerable by the second.

Measured: one request is 585ns of nilo's own work, a 25-route app spends ~9% of it matching and a 100-route app ~23%, so the scan passed [ADR 0001](./adr/0001-dx-wins-below-the-10-percent-threshold.md)'s bar at **around 30 routes** — an ordinary app rather than a pathological one. That turned the roadmap entry from *needs numbers nobody has* into a threshold, with the caveat that this is a share of nilo's work and not of a real request's wall clock.

**A hypothesis was tried and was wrong**, which is the other half of what measuring is for. Rejecting a route reads about ten bytes and a `Route` is seven times that, so the scan looked like it was pulling in cache lines to read four fields. Lifting those into a packed parallel array made the mixed set 7% faster and the same-shape set 10% slower — a wash, bought with eight bytes per route of duplicated state. Reverted.

## After 0.1.0: four bytes that let the scan skip a route unread

Four bytes per route stand for its first segment — length, first byte, last byte, middle byte — compared as one `u32` before any `mem.eql` runs. A radix tree's first level without the tree. It filters rather than reorders, so [ADR 0013](./adr/0013-the-most-specific-route-wins-and-duplicates-are-refused.md) survives untouched and a key collision costs only the `mem.eql` that would have run anyway.

| routes | 1 | 5 | 25 | 50 | 100 |
|---|---|---|---|---|---|
| mixed, before | 26ns | 48ns | 62ns | 116ns | 193ns |
| **mixed** | 28ns | 48ns | **45ns** | **81ns** | **108ns** |
| same shape, before | 52ns | 82ns | 245ns | 445ns | 855ns |
| **same shape** | 55ns | 60ns | **99ns** | **150ns** | **271ns** |

**It is not a clean win, and the row that says so is the first one.** At one route the key is computed and nothing can be skipped with it: 26ns → 28ns. Three nanoseconds of a ~610ns request, spent to take 44% off a hundred-route app — which moves ADR 0001's 10% crossing from around 30 routes to around 40.

**The obvious version lost, for the second time on this same function.** A real hash of the first segment costs more at one route than the `mem.eql` it saves, and one route is the size most apps are. With the packed parallel array above, that is two attempts at making the scan cleverer that both lost to making it read less.

## The machine turned up, and one of the numbers was about us

**The useful part was being wrong twice in one afternoon, in public, about our own build.**

The first flattered nobody. The server was pinned to CPUs 0–7 and the load generator to 8–15, which reads like eight cores each; on this machine 8–15 are the SMT siblings of 0–7, so both halves were sharing all eight cores. Splitting by physical core made the server **faster on half as many cores**, 1.14M to 1.31M req/s, and every number taken before that was wrong in the same direction.

The second was an accusation: "nilo has the slowest edit-rebuild loop in the field, 75× Go's", cause named as the comptime typed layer. Both halves false. **`zig build` is `Debug`, and `Debug` is 0.4s** — nobody's edit loop was ever 15 seconds. And **comptime is nearly free**: a Zig hello world with no nilo is 7.1s in `ReleaseFast`, nilo with zero routes 14.6s, thirty-two routes 16.6s, so a specialised handler per route costs 59ms each. **A number is not a finding until you know what is in it.**

That left one sentence still naming the wrong cause. Stopping the same build at each stage: the frontend, every comptime handler included, is **0.5s**; LLVM without debug info takes it to 7.3s; the debug info takes it to 14.7s; the linker does not appear at all. **Half of a release build is debug info** — 1.9 MB of DWARF generated and then carried through every optimisation pass, plus machine code that stops existing once std's stack-trace machinery has nothing to read. **And the comparison had been unfair in the same place**: Rust's release profile leaves debug info out unless asked and Zig makes you opt out, so "nilo 15.0s against axum 4.8s" was a build that does the work sitting next to one that skips it. Both ways: axum 6.5s and 4.7s, nilo 14.7s and 7.4s. Still last — by 2.7s rather than by 10.2s, and the difference between those readings was nobody's code.

**A mistake made while doing it, caught by re-measuring something that should not have moved.** The helper deciding this returned `bool`, so every mode that had not asked for debug info was told to keep it — and `ReleaseSmall`, where Zig already leaves it out, went from 3.7s to 6.9s quietly, in a change whose entire subject was build time. It was noticed only because the mode table was measured again rather than assumed unchanged. The return type is `?bool` now, and `null` means *the mode decides*.

**One dead end, recorded because it looks alive.** `-fno-llvm` builds the same executable in 0.31s — 47× faster — and the binary does 615,264 req/s against 1,988,414 with a p99 of 555ms. For the loop where build speed matters, `Debug` is already 0.4s.

## The fuzzer, and what it found

The request head is the one piece of nilo a stranger writes directly, and every test of it was an input somebody thought of. **The coverage-guided fuzzer was the plan and it does not work**: `zig build test --fuzz` fails to compile inside std's own test runner on Zig 0.16, reproducible from a five-line file with no imports of ours. So the targets are written to become coverage-guided the day that is fixed, and a corpus plus a generator drive them meanwhile — three quarters of generated inputs built to be nearly valid and then damaged in one place, because random bytes are almost never a request. CI runs a million per push seeded with the commit SHA, so a red job re-run gives the same answer rather than a coin toss.

**Two of the three properties are differential**, which is what makes them worth having. "It does not crash" is a low bar for a parser; the question is whether the fast implementation and an obvious one agree about where a head *ends* and about the two fields a smuggled request is built out of. A disagreement there is a security bug rather than a wrong answer.

What it found:

- **A header line with no name was accepted** — `: value`, colon first. nilo already refused a line with *no* colon, so this was the same rule applied inconsistently. Precisely the kind of leniency that ends up in a smuggling write-up years later.
- **`readChunkedBody` is arena-only and nothing said so.** A body of no chunks comes back as a slice that was never allocated, which panics under a general allocator and is correct against the request arena — the only thing that ever calls it. The contract is written down now.
- **The corpus was decoding to nothing.** The helper writing length prefixes used `std.mem.toBytes(@as(u32, text.len))`; every entry came out with `0xaa` where the length should be, the undefined-memory pattern. Every corpus entry was silently replaying as an empty input and **the suite was green while testing air**. What caught it was a test whose whole job is to check one corpus entry arrives as the bytes it was written as — added because a corpus you cannot see decode is a corpus you are trusting.
- **The first thing it caught was the oracle.** The reference request-line parser split on spaces and called `GET /x` an unsupported version, where nilo said malformed request line; nilo was right. **A differential test that has never disagreed with anything is not evidence of much.**

## Premises that expired

**ADR 0010 priced file IO as "owed by every replacement Engine forever"**, which was true when written and stopped being true when `sendFile` became a slot in the `std.Io.Writer` vtable and zio 0.17 — the version already pinned — filled it in. The obligation did not shrink; it stopped being nilo's to define, and the Bulkhead grew four names. **The seam had been named three stages earlier**, in ADR 0010's own last paragraph, so the decision was revisited by reading a dependency rather than by arguing ([ADR 0037](./adr/0037-a-file-too-big-to-hold-is-opened-not-read.md)).

**The bigger gap was not on the roadmap at all.** The item tracked was "the static tree cannot serve a large file". What nobody had written down is that a handler could not serve a file *at all* — an invoice behind an authorisation check was unwritable. The roadmap tracked the half with an ADR attached, because that is the half that had generated an argument. **Absence generates no argument.**

**The obvious ETag was the wrong one.** A file too big to hash wants a cheap validator, and a *weak* one looks like the honest answer: it promises "equivalent", not "identical", which is exactly what mtime and size can support. RFC 9110 then makes it useless — an `If-Range` carrying a weak validator must be ignored, so every client resuming a large download would start again from zero, and resuming is what large files are for.

**Two bugs came out of reading rather than failing.** `std.Io.Limit` is `usize`-backed, so on a 32-bit build a file over four gigabytes clamps and a complete transfer would have been read as a short send and had its connection closed for it. And `load` had a latent double free where `set.deinit()` ran while an `errdefer` on the same slice was still live. Neither had a failing test to find it, because neither is reachable on the machine the tests run on.

## The rule with no guard at all

[ADR 0014](./adr/0014-handlers-must-not-block-the-thread.md) said it outright — *"Nothing forces it"* — and rejected compile-time detection in one line, because Zig has no effect system. That is true and it answers the wrong question. "Can the compiler prove this function blocks" is no. **"Can the server notice that one just did" is yes, with a stopwatch, and nobody had asked.**

It matters more than the ADR's wording suggests, because the bug is invisible in development *because* there is no load. One `curl` against a handler that queries a database synchronously returns the right answer at the right speed. Two handlers both waiting 600ms, one holding its thread and one going through `nilo.blocking`, are three milliseconds apart from the client. With four in flight and one trivial request behind them, `/quick` takes 1.654s behind the blocking one and 0.0026s behind the proper one — **six hundred times, paid by a request that had nothing to wait for.**

**The clock trap is the part worth keeping.** `CLOCK_MONOTONIC` costs 27ns and four reads per request was 116ns of a 612ns request, twice ADR 0001's budget. `CLOCK_MONOTONIC_COARSE` costs 5ns — but reached through `std.os.linux.clock_gettime` it costs **571ns**, because nilo links libc and that path skips the vDSO. The first attempt at the optimisation was a hundred times slower than the thing it replaced and **looked identical on the page**; it showed up only because the profile went from 728ns to 3040ns and there was no story that fit.

Final cost 610ns → 668ns, 9.5% — inside the budget and not comfortably. Six runs of each, **interleaved**, with the before taken from a `git worktree` at the parent commit rather than by stashing. That mattered: uninterleaved passes on this same machine read 612 against 728 half an hour apart, and 681 against 673 ten minutes later. The second pair would have been quoted as "under the noise" and would have been wrong.

**Half of a detector's job is not firing.** Three of the watchdog's seven tests exist to prove it stays quiet — a wait through `nilo.blocking`, a stream, a server with the warning turned off. One that cries wolf gets switched off, and then it is worth less than nothing, because its absence looks exactly like its silence.

## Answers that were already in the file

The binding work ([ADR 0036](./adr/0036-a-binding-hands-its-failures-to-the-handler.md)) is the clearest case of the hard parts being solved already, and finding that out cost reading rather than building.

**The flag was already there.** The worry was whether a handler that can now answer a 422 forces the document to say so. `typed.zig` had `can_reject`, commented *"whether nilo can refuse this request before the handler runs"* — named for one purpose and describing a more general fact than the one it was written for. A `documents_422` beside it would have compiled just as well and been a second thing to keep in step.

**The gap was two thirds smaller than its own description**, and a refusal kept the wrong diagnosis alive. The compile error said a param in a group prefix meant every middleware on that group would never run; two of `chainFor`'s three callers resolve against the route *pattern*, which contains the param text, so only the cold no-route path was broken. `refusals/group_prefix_has_param.zig` asserted the wording, so the sentence was enforced, tested and re-read on every build — and none of that made it true. **A guard on the wording of an explanation is not a guard on the explanation.**

**One of two places knew a rule.** `covers` used `std.mem.startsWith`, so `app.use("/api", …)` also covered `/apiary`, while `static.zig` had been doing the whole-segment comparison correctly since static files were built.

**And a comment written for one feature answered another that did not exist yet.** `session.zig` already said randomness goes through the Bulkhead rather than `std.crypto.random`, *because this is a syscall and a syscall made straight from a fiber stops every request sharing its thread*. A correlation id on every request is exactly the wrong place for a syscall; the base is drawn once per process and what is left on the request path is one atomic add.

**A gap filed as an open decision had been decided a year earlier.** An optional in a SQL condition was written into the roadmap as *"either a Refusal or `IS NULL`; it cannot keep meaning `= NULL`"* — two live options and nobody to pick between them. There was nothing to pick: the two readings are two different statements, [ADR 0039](./adr/0039-the-shape-of-a-query-is-settled-while-compiling.md) says the statement is settled while compiling, and an optional only answers afterwards. The whole decision is one line of that ADR read out loud ([ADR 0044](./adr/0044-a-condition-holds-a-value-not-a-maybe.md)). **Filing something as undecided is a claim, and it is worth checking against the ADRs before it is written down** — an open question in the roadmap is read as work that needs a designer, and this one needed a morning.

## Bugs that would have had no symptom

`Ctx.setHeader` replaces, which is right for every response header there is except one. RFC 6265 says a server sending two cookies sends two `Set-Cookie` lines and — unlike every other repeatable field — that they may **not** be folded into one comma-separated value. (A cookie's `Expires` attribute contains a comma. That is how it came to be true.) Applied unchanged, the replace rule would have delivered only the second of a session cookie and a preference cookie: no error, no log line, no failing test unless somebody wrote one that set two.

**A cookie value carrying `;` is refused rather than escaped.** `"abc; Path=/admin"` is not a malformed cookie — it is a cookie with a path nobody wrote, and RFC 6265's grammar has no escaping to defend with, while `\r\n` in the same position is response splitting outright. Base64 and hex, which is what a session token actually is, pass untouched.

**The multipart parser's three careful parts all fail silently**, which is why each has a test named after the mistake rather than after the feature: a boundary matched mid-line truncates only the uploads that happen to contain the boundary string, a byte wrong in the framing corrupts every file and looks fine on a text one, and a `filename` part read as a text field puts an empty string where a handler expected an `Upload`. One test pins the file's bytes to the body's own address, because "it works" and "it does not memcpy a 900 KB upload" look identical from outside.

**And one compile error is really documentation.** `Redirect(200)` stops compilation with the five statuses that carry a `Location` and what each is for, because **303 after a POST is the one people get wrong** and getting it wrong means a browser's reload button submits the form again. That is ADR 0027's argument applied to something that is not a mistake in nilo's terms at all.

**`nilo_fetch`'s bounded drain never fired on the case it was written for**, and it took a second module needing the same code to find out. The policy asked `conn.reader().bufferedLen()` — how much of the body had already arrived in one 8 KiB read buffer — and compared *that* to `max_drain`. A refused 500 MB body has at most 8 KiB buffered, so it was never over the 64 KiB ceiling, and `Request.deinit` dutifully downloaded all five hundred megabytes to keep a pooled connection. **The number was in the wrong unit**: the question is how many bytes are still owed, which `std.http.Reader.State` knows and the buffer does not. Nothing could have shown it — the symptom is a connection that takes a long time to give back, which looks exactly like a slow server. It is the fifth time this repository has published a sentence with no run behind it, and the shape is the usual one: *"so refusing a 500 MB response does not download it"* was in the module header, the CHANGELOG and the reference, three copies of a claim nobody had put on a scale. The pairing that now holds it is one test whose control differs **only** by `max_drain` ([ADR 0072](./adr/0072-an-object-store-is-a-service-that-dials.md)).

## The name was cheaper to change than the markers

**One pass: 1,581 occurrences across 216 files, and 1,212/1,212 tests on both sides of it.** The import name is the consumer's to choose — their `build.zig` names the module, and `http/names.zig` rewrites every type our own compile errors print — so no path inside the framework depended on the spelling. The only step that is not textual is `build.zig.zon`'s fingerprint, which has the package name hashed into its low half and has to be regenerated from the value the compiler prints in the error.

**The roadmap claimed "nothing above the import line spells it", and that was false.** The markers do, and they sit in the reader's own structs: `pub const nilo_resolve = authenticate` on their service, `pub const nilo_table = .{ … }` on their row. Renaming the framework breaks every one of those lines. The name is cheap for us and not for them, which is the argument for settling it before there are users rather than after.

## Wiring the SQL module to a database

**The premise the whole design was argued from was wrong, and the truth was better.** ADR 0039 was written believing pg.zig was "already async on zio". Its manifest names no zio at all: it takes a `std.Io`, which is std's interface, and zio merely implements one. Two consequences neither the ADR nor the grilling session had anticipated. The Bulkhead hands out a std type, so `ready(state, io)` widens the contract without leaking the Engine. And the live tests need no server and no zio — they build a `std.Io.Threaded`, hand it to `nilo_start` exactly as `listen()` would, and the Wire cannot tell the difference. **A dependency's manifest is worth reading before its README.**

**"Settled while compiling" had a hole where the types were, and it took three goes to close.** The where walker recorded *where* each value was written and nothing about what it had to become. `.{ .age = .{ .gt = 18 } }` writes a `comptime_int` — no size, nothing that can go on a wire — so the walker had to carry the column too. Then `.{ .handle = null }` did not compile, because stripping the `?` is right for a comparison and destroys the only thing a write can mean. Then `.in = &.{1,2,3}` did not, because one placeholder holds *many* values there. Each was a separate afternoon and each was the same missing idea: the claim was about the shape of the statement and had quietly not covered the shape of its parameters. What the walker records now is a `Param` — the column, and whether the value is a list of that column's type — and the tuple is built from that rather than from what the literal happened to look like.

**Every one of those was found by writing a test that called each method once.** A method on a generic struct is only analysed where it is called, so `db.one`, `tx.raw` and a condition using `.in` had compiled exactly never while appearing finished. The route that calls all of them is the cheapest test in the module and found three real defects in one build.

**The write half found three things the design had got wrong, all of the same shape: a rule stated for reading that does not survive being read backwards.** A `Str` column could not be written to, because `.email = "a@b.c"` is a string literal and the parameter tuple demanded a `Str` — but `Str` means *text that lives as long as the request*, which is a claim about text coming **out**; a value going in has to survive the call and nothing more. An optional column could not be set to NULL, because stripping the `?` is right for a condition (`.nickname = "bo"` compares against a value) and destroys the only thing `.handle = null` could mean. And `error.AlreadyExists` had a promised 409 that nothing implemented. **Each was invisible until something ran in the other direction**, which is the argument for building the write half rather than declaring the read half done.

**A transaction cannot be a mode; it has to be a type.** The Wire acquires a connection per statement and gives it back, which is right everywhere except inside a transaction — where it would run half the statements on a different connection and commit on its own, with nothing failing and no error to find. So `begin` returns something that owns one connection for its life, and a result set opened inside it is marked as not owning what it is reading from. **The failure mode had no symptom**, which is the only reason it was worth an ADR entry rather than a comment.

**Two numbers, and the second is the one to argue about.** The startup hook and the 409 row cost **+560 bytes** in a binary that registers no service and touches no database, because `serve` calls the hook unconditionally: a contract widening is not free merely because nothing uses it. And a server that uses the whole module is **1,641,192 bytes against 890,384** without it — **+733 KB**, of which the entire write half, transactions and streaming included, is 53 KB and the rest is pg.zig's hard dependency on a TLS library with no build option to turn it off. That is only tolerable because it is zero for anybody who does not import the module, which is a property of `.lazy = true` in `build.zig.zon` and was checked in the binary rather than assumed ([ADR 0040](./adr/0040-a-service-that-needs-the-loop-is-finished-when-the-loop-exists.md)).

**A test suite that runs two optimize modes at once needs two of everything it writes to.** The live tests dropped and recreated one fixture table from both binaries simultaneously, which surfaced as a duplicate-key failure in a different test each run — the shape of a race seen from outside. One table per mode fixed it; the follow-on was that `@tagName(builtin.mode)` gives `Debug`, Postgres folds an unquoted identifier to lower case, and the Dialect always quotes, so the table was created as `…_debug` and looked for as `…_Debug`.

## Cutting the repository into layers

**"Compiles with `std` alone" and "belongs in the shared layer" are two different properties, and the first draft of [ADR 0041](./adr/0041-a-module-sits-where-the-loop-puts-it.md) confused them.** Seven files under `http/` import nothing but `std`, which is a fact about the cost of moving them; exactly one of them is used by two layers, which is the question that decides whether they should move. Listing the cheap ones as the move-list would have put Cookie and Range into the vocabulary every module shares on the strength of their import lines. The rule that survived — *needed by two layers, not having nowhere else to live* — makes Core two files rather than seven, and it is the rule that stops the bottom layer becoming the drawer.

**An import named only from a `test` block is never analysed in a build that is not a test build.** That one fact is what made the layering affordable. The tests worth having for a Service are the ones that drive a whole request through a real App, they live at the bottom of `sql/db.zig` by convention, and they looked like they would force the published `nilo_sql` to declare `nilo` after all — which is the thing the layer exists to prevent. Checked rather than reasoned about: `zig build-obj` on a file importing a module that does not exist passes when only a test names it, and `zig test` on that same file fails pointing at the test. So the rule binds a module's code and its tests may reach one layer up, and the build wires the extra name into the test module only.

**Two modules built from the same root file are two different types, and getting that wrong would have had no symptom.** Had `build.zig` handed `nilo_sql` a Core of its own rather than the one the App was given, `nilo_core.Str` and `nilo.Str` would have been distinct types, `kept`'s `F == core.Str` would have quietly answered false for every Row, and text would have stopped being copied out of the driver's read buffer — while everything still compiled. One Core per optimize mode, shared by both modules, and a test asserting `core.Str == nilo.Str` so the day somebody adds a third root it fails loudly instead.

**Moving declarations between modules cost nothing, and the prediction was written down before the measurement to make that checkable.** Zero bytes on `example-hello`, `example-rest` and `nilo-hello`, byte for byte, stripped `ReleaseFast` against a `git worktree` of the parent commit; the row is in [ADR 0018](./adr/0018-the-trade-budget-has-three-axes.md)'s running total.

## A number that was stated and never held

**A published number with no test under it was wrong in two ways at once, and neither was the arithmetic.** [ADR 0039](./adr/0039-the-shape-of-a-query-is-settled-while-compiling.md) promised *exactly two allocations when `.limit` is written out, since the row count is then known before the first row arrives*. `fill` never read the limit, so writing one changed nothing — and even had it read it, **a limit is a ceiling and not a count**, so the sentence would still have been false for every query that matches fewer rows than it asks for. The first error is the kind a test catches. The second is the kind only writing the sentence out again catches, which is why the corrected entry says *ceiling* in bold and the code says it twice.

**The rule this repository already had was the one that would have caught it: the HTTP path's allocation budget is a test, and the SQL path's was a paragraph.** Both were written by the same person in the same month. What made the difference was that one of them had somewhere obvious to live — `test "the request path stays inside its allocation budget"` sits at the bottom of the file it measures — and the other would have needed a Wire, a Scope and an allocator that counts, none of which existed yet when the claim was written. **A number stated before there is anywhere to hold it is a number that will not be held.** The fix was one line of code and forty of scaffolding, and the scaffolding is what had been missing.

**`std.testing.FailingAllocator` counts allocations and never has to fail.** Reaching for the App layer's `budget.Counting` would have meant either exporting a test helper from the framework's public surface or moving it into Core to satisfy one caller — the drawer [ADR 0041](./adr/0041-a-module-sits-where-the-loop-puts-it.md) opened by refusing. std already had the thing, under a name that describes its other use.

**One change that read as an obvious win was measured and turned out to be nothing.** `toOwnedSlice` on an arena-backed list looked like a wasted copy — and for a Row carrying text it genuinely cannot shrink in place, so it allocates the result a second time. Replacing it with `out.items` changed the measured allocation count by zero at every size, because the second allocation comes out of an arena page that is already there. It was reverted, and keeping it turned out to matter for the opposite reason: now that a written-out limit reserves the whole ceiling, `toOwnedSlice` is what hands the unused tail back. **The change that looks free is the one to measure, because there is nothing else stopping it.**


## What the bottom layer cannot reach

**The premise that a UUID module needs nothing was false, and the standard library is what made it false.** `nilo_id` was designed as the module that proves the bottom layer works — one job, no dependencies, `zig test id/id.zig` and done. Zig 0.16 deleted `std.crypto.random` and `std.time.milliTimestamp` and put both behind an `Io`, so **entropy and the wall clock are IO now**, and a module that may not name an Engine can reach neither. That is not std being awkward; it is std agreeing with the question [ADR 0041](./adr/0041-a-module-sits-where-the-loop-puts-it.md) uses to sort modules. What shipped is the format — `v4(entropy)`, `v7(entropy, ms)` — and the missing seam is written down rather than invented under time pressure ([ADR 0042](./adr/0042-the-bottom-layer-holds-more-than-one-module.md)). **The check worth copying is the one that found it: build the module standalone before designing around it, not after.**

**A marker on a type is an import nothing can see.** `sql.Uuid` carried `pub const nilo_column = "uuid"`, and moving the type down a layer would have moved a database's opinion into a module that has never heard of one — imports still pointing downward while knowledge had quietly stopped. The rule that came out of it is in ADR 0042 and the fix was one line in `declaredColumn`. **The layering step cannot catch this class**, because a marker is not an `@import` — which is worth knowing about the step as much as about the markers.

**The first run of the layering step refused two modules for documenting themselves correctly.** Every module root here opens with `//! const id = @import("nilo_id");`, which is what a scan looking for `@import` finds first. Skipping `//` lines fixed it in three lines, and the general shape is worth keeping: **a check that reads source has to survive the source that is about source.**

## The second caller that was named and did not turn up

**[ADR 0041](./adr/0041-a-module-sits-where-the-loop-puts-it.md) deferred a decision to a caller it named in advance, and the caller arrived and could not take it.** `convert.zig` was to move down *when a configuration module exists to design against rather than a guess*. `nilo_config` exists and is not that caller: sharing means naming `nilo_core` for `Str`, and ADR 0042 had meanwhile made *runs under a plain `zig test`* the entry condition for the bottom layer rather than a property one module happened to have. The two rules were written one ADR apart and only collided when something tried to use both. **Deferring to a named future caller is still better than guessing — but the thing that decides is the rules in force when it turns up, not the ones in force when the note was written.** ADR 0043 has the resolution and the roadmap entry now says which layer the caller has to be in.

**A permission nothing had exercised was two rules that could not both hold.** ADR 0042's table says a tool module may import `nilo_core`; its text says a module down there runs under a plain `zig test` or it is in the wrong layer. `zig test` supplies no modules, so any module actually using the permission fails the condition. `nilo_id` imports nothing and never asked. **A rule with no caller is a rule with no test**, and this one sat unexercised for exactly one module before the second one found it.

**The wording that was allowed to fork, and the argument for letting it.** `http/convert.zig` keeps one copy of its sentences because a handler shows a field's failure *next to* a 400 from the endpoint beside it. A config report goes to stderr once, before the socket opens, from a process about to exit — never beside anything — so the drift the shared copy exists to prevent has nowhere to happen. Forty duplicated lines bought the layer property. **A rule about consistency is worth re-deriving at each new caller rather than applied because it is the rule**, and re-deriving it is what turned up that this one did not transfer.

## Two numbers about the platform, both of which changed a design

**A comment in `http/bulkhead.zig` had recorded a gap that stopped existing.** It said reading a clock through `std.posix.system` rather than `std.os.linux` was *the difference between the vDSO and a real syscall once libc is linked* — 5ns one way, 600ns the other. Re-measured on Zig 0.16: `CLOCK_REALTIME` is 15ns and `CLOCK_MONOTONIC_COARSE` is 1–2ns, and **both are the same with and without libc**, because `std.os.linux` reaches the vDSO too now. The code was never wrong; only the reason under it was, which is the kind of staleness nothing fails on. What survived is the half the code actually depends on — the coarse clock is about eight times cheaper than the plain one — and that is what the comment says now. **A number in a comment is a claim with no test under it, and this repository keeps re-learning it** ([ADR 0045](./adr/0045-core-knows-what-time-it-is.md)).

**Entropy turned out to cost 56ns, and the number is what killed the cache.** `Ctx.entropy` was designed expecting a syscall worth avoiding, and a per-thread CSPRNG seeded at `listen()` was the obvious next step: stored state, a fork hazard and a seeding moment, in exchange for skipping the kernel. Measured first — Linux 6.11 and later serve `getrandom` from a vDSO-backed pool, so the thing the cache would remove is 56ns. **The design was priced before it was built and did not survive the price** ([ADR 0046](./adr/0046-entropy-belongs-to-the-loop.md)). It is written down rather than forgotten, because the same call is a real syscall on an older kernel and roughly twenty times dearer — which is the argument for the Bulkhead owning it either way.

**Core was described by a proxy for what its rule actually was.** ADR 0041's layer table sorts modules by *does it need the event loop*, and the same ADR describes Core as *no IO at all* — two sentences that agreed until the first thing sat between them. A clock is IO by the letter and a read from a mapped page in practice, so it needs no loop and does not fit the description. Amending the description was the whole fix, and it took one paragraph. **The lesson is that the proxy is the sentence people quote**: nobody was going to argue about the table, they were going to argue about "no IO", and the day the two disagreed is the only day anybody was ever going to notice which one was load-bearing.

## The cost that was too small to be caught

**A roadmap entry said password hashing "deliberately takes 100ms"; measured, argon2id at OWASP's own parameters is 13.3ms — and the gap is what the design turned on.** At 100ms a handler that forgets `nilo.blocking` trips the blocking detector, which fires at `block_warning_ms`. At 13ms it never fires at any setting anybody uses, so the mistake is invisible: 13ms of held thread on every sign-in, showing up as p99 on endpoints that have nothing to do with signing in. **The detector has a floor, and anything that costs less than the threshold but more than nothing falls through it** — which is why `Ctx.hashPassword` exists at all instead of a documented rule to wrap the call ([ADR 0048](./adr/0048-a-password-hash-is-gated-because-forgetting-is-silent.md)). The premise was wrong in the direction that looks harmless.

**The concurrency ceiling was set by a pool sized for a different kind of call.** `nilo.blocking` hands work to zio's thread pool, whose default is `cpu_count * 2` — right for calls waiting on a disk, wrong for one eating a core and 19 MiB. Measured, argon2id is bound by memory bandwidth rather than cores: throughput peaks at 16 concurrent and **falls** at 32, so the ungated default would have been the slowest setting *and* the most expensive, 608 MiB against 152 MiB at eight. Eight reaches 91% of the ceiling. The same pool serves `c.entropy`, so ungated sign-ins would also have queued every session cookie in the server behind them — **a shared resource whose size was decided by somebody else's use case is not a default, it is an accident that has not happened yet.**

**Two premises in a roadmap entry were wrong and the third was the API.** The same entry said the caller would supply the salt; `std.crypto.pwhash.argon2` in Zig 0.16 generates its own through an `Io` it demands in the signature — the one thing a module with no event loop does not have. `std.Io.Threaded.init_single_threaded` turned out to be a comptime constant that spawns nothing, and it agrees byte for byte with a real runtime at p = 1, 2, 4 and 8. **A plan written against an API nobody opened is a guess with a citation**, and the part that survived contact was the shape, not the mechanics.

## A fifth of a hash was not hashing

**Nineteen megabytes of fresh memory costs 2.2ms before argon2 does anything with it**, because it is 4,864 pages and the first pass faults every one of them. Asked for with `MADV_HUGEPAGE` it is ten faults and a hash is 11.0ms instead of 13.6. The measurement that decided the design is the one that was nearly skipped: **a mapping kept warm and re-used is 10.5ms — no faster than a fresh huge-page one** — so the buffer pool behind the Gate, which was the obvious next step and would have held 152 MiB resident, buys nothing at all. **Price the cache against the cheap fix before building it**, and measure where a cost is rather than where it looks like it is ([ADR 0049](./adr/0049-a-hash-asks-for-the-pages-it-walks.md)).

**A constant-time claim was true of the default and of nothing else.** ADR 0048 shipped `verify(null, …)` doing the work anyway so that an unknown address could not be told apart from a wrong password — and hard-coded the decoy at `Cost.default`, so any deployment hashing at anything else answered the two in visibly different times. The optional closed the early return and left the stopwatch open. **A claim of the form "both paths cost the same" has a parameter hidden in it, and the parameter has to be an argument** — `verifyWith` takes the Cost now. The same reading turned up an `unreachable` that was reachable: `checkCost` refused three of argon2's four parameter preconditions, and a Cost with more lanes than memory got past it into a panic. **Mapping a callee's error set to `unreachable` is a promise about every precondition, not the ones that came to mind.**

## The rows that had never been printed

**The measurement was two lines apart in the same table, and the table had never been on a screen.** `websocket: receive 16 KiB` read 88.1 GB/s next to `websocket: send 16 KiB` at 199.8 GB/s. A send is a copy; a receive is a copy and an XOR against a repeating four-byte pattern, which is free — so there is no reading of those two numbers under which the first should be less than half the second. Fusing the copy and the unmask into one pass made it **73ns and 244.5 GB/s, 2.7×, and faster than the send row** ([ADR 0052](./adr/0052-a-message-is-copied-once-and-framed-once.md)). **A number is only a measurement once something is standing next to it**, and this one had its comparison built in.

**Both rows were added by the same commit that stopped `zig build profile` compiling**, so neither had ever been printed: `b662f01` gave `App.handleRequest` a `waker` argument and left the profiler passing seven. Nine commits later the first thing this work had to do was fix a build nobody had run. The profiler is deliberately not in `zig build test` — a number that moves with the weather has no business failing a build — but that argument is about the *numbers*, and it was quietly extended to the compile. [ADR 0033](./adr/0033-a-guard-is-not-a-guard-until-it-has-been-seen-to-fail.md) is about a check only ever seen to pass; this is the same shape one step earlier, a check nobody ever started.

**`std.simd.suggestVectorLength` answers a different question from the one an unmasking loop asks.** It reports the target's register width. What the loop wants is an unroll factor, and LLVM gets there from a wide `@Vector` better than from a hand-written unroll: on this machine the suggestion is 64 and **128 measures 30% faster**, with 256 worth a further 6% and twice the code. The general-looking call is the one that leaves the win on the floor, and it would have looked more portable while doing it.

**`Room.seats` read as a memory knob and was a per-message tax.** `say` walked every seat the room was sized for, so a thousand-seat room holding three paid a thousand iterations per message — 494ns, against 161ns once the taken seats are kept dense at the front of a permutation. The option's own doc comment described the memory it costs and said nothing about the walk, which is how an O(capacity) cost ends up sitting behind a number users are told to raise.

## A behaviour whose only signal is a log cannot be tested here

**Zig's test runner counts `std.log.err` calls and fails the run on any of them**, and `log_err_count` is a private global in the runner — a test cannot expect one, reset one, or opt out. So a path whose entire observable behaviour is a line in the log is a path no test in this repository can take. It has now cost two tests: the schema check, which reports a disagreeing column at `err`, and a write inside a read-only transaction, which reaches `translate` and logs the server's `25006` on the way to `QueryFailed`. The second was rewritten to ask Postgres `SHOW transaction_read_only` instead, which is the better test anyway — **what nilo owes is that the words reached the `BEGIN`; that Postgres then refuses writes is Postgres's and documented.** The general form: when a behaviour cannot be asserted, check the input the other system was given rather than the answer it gave back.

**`revive` was written for two callers and there were three.** [ADR 0047](./adr/0047-a-deadline-needs-a-connection-you-hold.md) found that pg.zig maps an aborted transaction and a dead socket to the same `.fail` state, and let `COMMIT` and `ROLLBACK` out of it. Savepoints arrived and `ROLLBACK TO SAVEPOINT` is the third — and it is the *only* statement whose whole purpose is to run after a failure, so without the same escape the feature does not work on the one path it exists for. A workaround written as "these two calls need it" is a rule with its scope guessed; the rule was always **any statement that has to run on a transaction the server has already aborted** ([ADR 0054](./adr/0054-contention-is-what-a-transaction-is-for.md)).

## The typed layer costs 100 nanoseconds

**`db.find` is ~100 ns more expensive than the raw `conn.queryOpts` it wraps**, and until `bench/sql.zig` measured both sides nobody had a number for it. On a 37.7 µs key lookup that is a quarter of one percent: the parameter tuple, the Row fill, the `Str` copy into the arena, all the comptime work ADR 0039 is about. The measurement was taken for a different reason — to check the module was not eating the prepared-statement saving — and the check is the point. **The saving through `db.find` came out 0.4 points *higher* than at the driver, so the layer being measured had to be free for the arithmetic to work, and now that is a number in the bench output rather than a belief.** Any DX feature that makes the typed path expensive shows up there ([ADR 0057](./adr/0057-a-statement-that-is-a-constant-can-be-prepared-once.md)).

**A prepared statement is a fixed saving, which decides who it is for.** ~12 µs a query either way: 30% of a key lookup and 14% of a page with a sort. The instinct is to read the smaller share as the disappointing case; it is the same absolute win against a query doing four times the work. **A service's request mix is mostly cheap queries, so a fixed cost removed is worth most where the percentage looks best** — and it is why the default is on rather than a tuning knob.

**Two statements sharing a cache name is a silent wrong answer, and the driver only catches half of it.** Reusing one `cache_name` for two statements while writing the bench got `WrongNumberOfParameters` out of pg.zig — which compares the parameter *count* against the stored describe and nothing else. Had the two had the same arity it would have re-bound one statement's parameters against the other's plan and returned rows with no complaint at all. **A collision that the layer below catches for one reason is not caught; it is postponed until the reason does not apply.** Hence 128 bits of hash rather than 64, and a live test that interleaves four statements of three different arities down one connection.

## The query was never the cost

**A round trip to Postgres is 24 µs and the query inside it is 2.3.** Measured with `SELECT 1` prepared, next to a prepared key lookup at 26.2 µs — so 91% of what a cheap query costs is two syscalls, two process wakeups and the kernel's loopback path. `/usr/bin/time -v` agrees from the other side: 6.79 s of wall clock for 0.88 s of CPU, one voluntary context switch per query. **Every optimisation aimed at the statement is aimed at the last 9%**, which is worth knowing before the next one is proposed — prepared statements ([ADR 0057](./adr/0057-a-statement-that-is-a-constant-can-be-prepared-once.md)) cleared the bar by taking a bite out of that 9% *and* out of the round trip's own parse, and there is no second bite of that size available.

**The load-bearing claim about this module had never been measured, and it is the one the module is judged on.** If a Postgres read blocks its OS thread, every application built here is capped at `threads ÷ 24 µs` — the failure ADR 0014 names. Reading pg.zig says it suspends the fiber; `bench/sql_server.zig` says **215,000 requests a second with a real query in every one**, against the ~41,000 one blocked thread would allow, holding flat from 128 connections to 256 rather than collapsing. **A design argument about somebody else's source is not a measurement, and this one was three years old before anybody pointed a load generator at it.**

**The server costs 6.13 µs of CPU per request without a query and 21.8 with**, sampled under load. That 15.7 µs gap is nearly all syscalls — during the run the machine sits at 45% system and 20% softirq against 21% user, the Postgres backends take eight cores and the nilo server takes 4.7 and does not make the top twenty processes. **The place a database layer looks expensive and the place it is expensive are different places**, and the second one is not reachable from comptime.

## An unused comptime parameter is not a parameter

**Zig memoises a generic on the type it returns, so `Thing(u8, "a") == Thing(u8, "b")` when the body never mentions `name`.** That was the whole of what stood between this module and a second database: the Service registry is keyed by type, so `*sql.Db` was the only database a program could ask for, and a name that the struct *keeps* — `pub const db_name = name;` — is what makes the second type. The instinct was to write the parameter and ignore it; the language would have handed back one type and the failure would have been `app.provide` complaining about a duplicate service, a long way from the cause. **The rule is held by the compiler for free: dropping the name is an unused-parameter error** ([ADR 0060](./adr/0060-a-second-database-is-a-second-type.md)).

**Two features refused in one cycle for the same reason, and it is not effort.** Automatic replica routing and a query cache both work in a test suite and both go wrong in production, because read-after-write staleness and stale-cache invalidation are *silent*. The performance case for the cache is the strong half — a round trip is 24 µs and the query inside it is 2.3, so an in-process cache is the largest single win on the table. **A win on the axis with the numbers loses to a correctness failure with no symptom**, and the pattern is the same one behind the null-in-a-condition compile error and the third nullability answer for a view.

## A hardcoded string does not look hardcoded while there is only one of it

**The seam held on twelve of thirteen declarations, and the value of writing the second Dialect was the other four things.** `sql/dialect.zig` had said for a year that the point of the seam was that `$1` was not hardcoded, not that a second Dialect existed — reasonable, and not evidence. Writing SQLite's SQL half found: a `ListForm` enum whose three answers would have made `.in` a Refusal on a database where every schema uses it; `listSpelling` handing `"= ANY"` and `"<> ALL"` straight to the writer, which is Postgres's words in a dialect-neutral file; and a cast seam that returned whole expressions rather than suffixes, which was right and had never been tested. **The header's own prediction was wrong in the interesting direction** — it said SQLite would have to expand a list into placeholders, and SQLite binds it as one JSON document and takes it apart with `json_each`. Right about the constraint, wrong about the conclusion, unchallenged because nobody wrote the Dialect ([ADR 0061](./adr/0061-the-second-dialect-is-the-test-of-the-seam.md)).

**The half worth stopping at was the half with no I/O in it.** A Dialect is comptime, so it compiles and tests with no dependency, no database and no event loop — which is why finishing it was an afternoon and finishing the Wire is not. The Wire runs into a question the Postgres one never had: SQLite is a blocking file read with no descriptor to wait on, so every call either holds its thread or pays a `nilo.blocking` hop, and the choice needs numbers. **Splitting a seam so that one half can be finished alone is worth more than it looks**, and that split was made for tidiness rather than for this.

## The behaviour whose evidence is an absence

**A documented feature had never worked, and nothing caught it because every test has a database.** `connect_on_init` defaults to zero and three files say that means a server boots with Postgres switched off; `pg.Pool.initUri` copies `size` and `timeout` onto the options it parsed and drops `connect_on_init_count`, which then falls to `orelse size`. So every pool nilo ever opened dialled itself in full and died on the first refusal. **The whole of what the option does is visible only when the database is absent, and a test cannot arrange an absence** — the live tests skip without a database rather than assert something about not having one. Same shape as the `std.log.err` finding above: a behaviour whose only expression is a thing not happening ([ADR 0062](./adr/0062-a-pool-that-dialled-itself-whatever-it-was-told.md)).

**It was found by turning a knob up, not by reading the code.** A pool of 128 against a Postgres with `max_connections = 100` said *sorry, too many clients already* while `connect_on_init` was 8 — and eight cannot exhaust a hundred. The bug had been read past for as long as it existed; the load generator found it in one run. **A parameter sweep is a code review that does not get bored.**

**Fixing it turned on a code path that had been dead since the module was written, and that path panics under the harness the tests use.** pg.zig's reconnector spawns an OS thread that parks on a mutex against the `Io` it was handed; `std.Io.Threaded` cannot park a caller that is not one of its tasks and reaches `unreachable`, taking 77 tests with it. zio parks across threads, so a server is fine and a test harness is not. **A fix is not finished when the thing it fixed works** — the question is what else it switched on.

## The pool is the knob, and it has a curve

**Connections against throughput, at 64 client connections across a Docker published port: 2 → 60k req/s, 4 → 99k, 8 → 133k, 16 → 148k, 32 → 180k, 64 → 206k.** The default is 10. **p99 is best at 32 (784 µs) and worse at 64 (1.03 ms)** while throughput is still climbing — the tail turns around before the headline does, which is the usual sign that the database has more connections than it can use. A query costs the server **11.4 µs of kernel time and 3.1 µs of user time**, so it is the socket rather than the module: nothing in nilo's half is what a bigger pool is buying past.

## The flat number was flat because nothing was happening

**Memory per idle connection is 8,767 bytes plus every byte of stack the handler ever touched, one for one.** The published figure was measured against a handler returning a constant `[]const u8` — and it is exactly right for that: 8,749 bytes, eighteen off. An ordinary route that takes a `Ctx`, reads one row and answers JSON holds **17,022**. A handler that only `@memset`s an 8 KiB array and touches no database holds **17,932**, which is *more* — so the database was never the cause. 32 KiB of stack gives 42,491 and 128 KiB gives 140,787: linear, one byte held per byte touched, for the life of the connection.

**A suspended fiber holds its stack at its high-water mark, and nothing lowers it.** Which inverts the usual advice: **in this framework the arena is cheaper than the stack**, because the arena is reset per request and a stack buffer is per *connection*. `var buf: [64 * 1024]u8` in a handler — the idiomatic Zig way to avoid an allocator — is 64 KiB × every connection that ever reached that route.

**This is the same bug that was already found and fixed one layer up.** The entry above records the per-connection figure falling to 8,767 "since a keep-alive connection stopped holding every buffer page it had ever touched until close". Buffer pages were fixed; stack pages were never looked at. **A fix that names the mechanism should be checked against everything else that has that mechanism**, and this one had a second address for a year.

**Two things it was not, and ruling them out was most of the work.** Not the arena: `arena_keep` swept from 0 to 64 KiB changed neither the memory nor the throughput (178k–186k req/s across the whole range), so the 16 KiB retained block is buying less than it looks like. Not a leak: 500 connections × 1 request grew 8.4 MB, and 50 connections × 100 requests — ten times the work — grew 0.88 MB. **Scaling with connections rather than with requests is what tells a retention from a leak**, and it takes two runs to ask.

## A build step that only ran a quarter of what its name said

**`zig build refusals` runs 56 of the repository's 105 compile-error checks, and nothing said so.** The other three tables — `sql_refusals`, `config_refusals`, `pw_refusals` — have their own steps by design (ADR 0027 hangs each off its own module's tests), but the *name* `refusals` promises all of them and the step description said "check that each mistake stops in nilo's own words". So a new `sql/refusals/` file plus a run of `zig build refusals` is a green build and a check that never executed — which is exactly what happened while writing ADR 0060, and it was caught only because the falsification step afterwards also printed nothing. **A guard that has never been seen to fail is ADR 0033's problem; a guard that was never *run* looks identical from the outside**, and the tell was silence where a failure was expected. The step names say which table they cover now, and `CLAUDE.md` had the count wrong at 96 as well.

## A pool connection is a serial queue, so latency saved is capacity gained

**Prepared statements measured 30% at one connection and 51–70% through a server**, and the gap is the useful part. `bench/sql_server.zig` with `PREPARED=0` against the same binary with it on: 89k → 135k req/s at a pool of eight, 106k → 177k at thirty-two, 112k → 191k at sixty-four. At one request in flight it is +24%, which is what the arithmetic predicts — 12 µs off a 64 µs request.

The rest comes from where the queueing is. **A pool connection serves one query at a time, so the time a query holds it is not latency, it is occupancy** — cut 30% off the hold and that connection can push about 43% more, before counting the CPU Postgres stops spending on Parse. Which means **a per-query saving is worth measuring twice: once unloaded, where it tells the truth about the work, and once at the pool, where it tells the truth about the service.** The first number was the one this ADR nearly shipped with, and it understates by a factor of two and a half.

## Half the throughput was in the connection string

**The same server and the same query: 197k req/s across a Docker published port, 359k over loopback TCP, 458k over a unix socket.** Bridge → unix is **+133%**, and p99 halves from 1.65 ms to 0.91 ms. There is no `docker-proxy` in that path — it is plain iptables DNAT to a container address, which is the *fast* way to do the slow thing, and it still costs 57% of the throughput to conntrack and a second netfilter traversal per packet, paid twice a round trip several hundred thousand times a second.

**Every database figure in this cycle was taken through the slow one, and the whole set was published before anybody asked what it was measured through.** The ratios all survived — prepared statements are worth the same fraction either way — but the absolutes were understated by half, and ADR 0059's "215,000 requests a second" was really the floor rather than the number. **A transport is part of a figure, not a footnote on one**, and the fix is procedural: `bench/result/` now says which transport every table used, and `CLAUDE.md` makes it one of three standing habits.

The load generator was checked before any of this was believed: wrk at 2, 4 and 8 threads gave 496k, 482k and 483k req/s, flat and slightly *down* with more threads. **~490k is what this box does with three programs on eight physical cores**, so the unix-socket figure is 94% of the machine and not 94% of nilo. A ceiling nobody measured is a ceiling that gets attributed to the wrong program.

The advice this produces costs nothing to take: **a co-located Postgres should be reached over its unix socket**, `postgres://user:pass@%2Fvar%2Frun%2Fpostgresql%2F.s.PGSQL.5432/app` — pg.zig wants the full socket path, not libpq's directory, and percent-encoded so the URL parser keeps the slashes in the host.

## A refusal was narrower than its own headline

**ADR 0043 said `nilo_config` "does not parse a file". Both arguments it actually made were about dependencies, and neither one reached a `.env`.** zig-toml is ~2,000 lines every importer would fetch; zig-yaml skips 322 of ~400 conformance cases. A fifty-line `NAME=value` scanner that needs no dependency was never on the far side of either sentence — it was on the far side of the *summary* of them. Moving the line to **"does not open a file"** kept everything the refusal was defending (no allocation, no `std.fs`, tests that run under a plain `zig test`) and cost nothing it was defending, because `Dotenv` takes text rather than a path ([ADR 0064](./adr/0064-a-dotenv-is-text-somebody-else-read.md)).

**Re-read the argument, not the headline, before extending a refusal.** A refusal compresses into a slogan over time, and the slogan is what gets quoted in four files while the reasoning sits in one.

**The binary-size measurement that mattered was the one that did not move.** 237,528 bytes before and after for a program that reads a Config and never names `Dotenv` — byte for byte, against a `git worktree` of the parent commit. Measuring only the with-feature program would have produced 6,448 bytes and no way to tell whether existing users were paying part of it. `pub` declarations nobody names cost nothing because Zig never analyses them, and that is a claim worth a second binary rather than a sentence. Both runs are in [`bench/RESULTS.md`](../bench/RESULTS.md).

## A blocker nobody had checked, and a second caller that did turn up

**Three modules were listed as blocked on a seam that already existed.** The roadmap had `nilo_s3`, `nilo_mail` and `nilo_redis` waiting on a supported way to dial out, and said `nilo_sql` reached the network "through pg.zig's own zio". pg.zig has no zio — its `build.zig.zon` names buffer, metrics, xsync and tls — and it dials through `std.Io.net`, which a Service is handed by `ready(state, io)` ([ADR 0040](./adr/0040-a-service-that-needs-the-loop-is-finished-when-the-loop-exists.md)). The way out had been open since that ADR landed; what is missing is a clock on the operation, which is [ADR 0065](./adr/0065-the-way-out-was-open-the-clock-was-not.md). **This is the third claim here repeated across files with no run behind it** — after `connect_on_init` ([ADR 0062](./adr/0062-a-pool-that-dialled-itself-whatever-it-was-told.md)) and the flat 8,767 bytes ([ADR 0063](./adr/0063-a-handlers-stack-is-per-connection.md)) — and the first found by reading a dependency's manifest rather than by measuring. **A premise decays the same way a number does, and costs more, because a wrong premise gets planned against.**

**The named caller that did turn up moved a different file than the one it was named for.** The roadmap had `percent.zig` down as the likelier candidate to settle where `convert` belongs, on the grounds that whoever signs a URL is not in Core. That caller arrived — an object store signs — and `percent` went to Core without answering the `convert` question at all ([ADR 0066](./adr/0066-percent-is-needed-by-two-layers.md)): what keeps `convert` in the App layer is that it reaches the Bulkhead to say a request failed, and **neither direction of percent coding can fail**. The half that could move was the half with no failure in it. **A deferred decision can sometimes be split along the property that deferred it**, which is cheaper than waiting for a caller who can take the whole of it.

## A layer that was measured before it was designed around

**Two sessions reached the same wall from opposite ends, and the argument that settled it was a line count.** An object store and a handler calling Stripe both needed policy in front of `std.http.Client`, and neither could reach the other's copy: `http/` is a sibling to a Service, Core does no IO, and a module that dials is a Service too. The three shapes on the table — a fourth layer, a relaxed never-a-sibling rule, two copies — were all repository-level decisions, and nobody had asked how big the thing being housed was. `spike/outbound/` answered it: **65 lines of policy against 3,537 lines of `std.http.Client` and `std.crypto.tls.Client`, under 2%.** The spike also settled whether a fourth layer could be *held* rather than merely declared, by running its tests under `std.Io.Threaded` with an empty dependency list. **The check worth copying is the one [`nilo_id`](./adr/0042-the-bottom-layer-holds-more-than-one-module.md) already taught: build the module standalone before designing around it.** It was cheaper the second time because somebody wrote it down the first.

**The layer shipped anyway, and the number that argues against it is inside its own ADR.** 65 lines does not justify a layer by volume, and [ADR 0070](./adr/0070-a-fitting-borrows-the-loop.md) says so where the next person will find it: it justifies itself by `zig build layering` being able to enforce the rule, and the second Fitting is what will decide whether that was right. **A decision whose weakest number is missing from its own ADR is one somebody re-derives from scratch in a year.**

**A design sketch in an accepted ADR was unimplementable, and building it was the only thing that could have found out.** ADR 0065 specified `var bound = limits.arm(2_000)` — a handle returned by value. zio's `AutoCancel` stores `&self` as its timer's userdata, so arming a temporary and copying it leaves the event loop pointing at a dead stack slot. The API takes `*Bound` instead and the ADR carries the correction. In the same file the slot for the engine's state was guessed at 56 bytes and is **176**; the `comptime` check in `http/bulkhead.zig` named the right number on the first build. **A check that reports the measurement it wanted is worth more than one that only says no** — that one turned a wrong guess into a two-minute fix instead of a buffer overrun in a module nobody suspected.

**The same sketch got the error wrong, and only a real timer could show it.** Both ADR 0065 and the first `nilo_fetch` wrote `error.Canceled => if (bound.fired())`, which reads correctly and is wrong: `std.Io.Reader`'s error set is fixed, so a cancellation crossing it arrives as **`error.ReadFailed`** with the cause kept in a field the caller never sees. Every timeout was being reported as a broken upstream. `fetch/live.zig` could not catch it — `std.Io.Threaded` cannot cancel a fiber, so no deadline it arms has ever fired — and `fetch/deadline.zig`, the first test here to open a real port, caught it on the first run. **The bound is the authority, not the error**, and asking it is also what *spends* the cancellation: zio holds a pending count on the task, so a bound that fires and is never asked leaves the next operation — writing the response — cancelled too. `Bound.release` now asks on behalf of anyone who did not. **[ADR 0033](./adr/0033-a-guard-is-not-a-guard-until-it-has-been-seen-to-fail.md) applies to the error a guard returns, not only to whether it fires.**

**Two theories about 16 KB per idle connection, both wrong, both killed by a control route.** An outbound call costs **16,495 bytes on every idle connection** — by far the largest per-connection cost in the framework, and held for as long as the *inbound* connection stays open. The obvious cause was the two client buffers on the handler's stack; moving them into the request arena is worth **−66 bytes**. The next was the retained arena, since 16,384 of it is exactly `arena_keep`; a route serving the same kilobyte out of the same arena with no client in it costs **2,048**. What is left is fiber stack at the depth `std.http.Client` drives it to. **A number that matches a constant you recognise is the most convincing wrong answer available** — both theories arrived with arithmetic that worked. The numbers, and what `nilo_fetch` itself costs against a bare `std.http.Client` (1 byte, ±1% throughput, +1,640 bytes stripped), are in [`bench/result/fetch.md`](../bench/result/fetch.md).

**Three benchmark runs were thrown away because a sibling worktree's server held the port.** `nilo-bench-fetch-server` never bound, so `mem.py` read the wrong process's `VmRSS` and `wrk` reported another server's 404s as "Non-2xx" — numbers that looked plausible for two of the six routes. **A load generator cannot tell you it is pointed at the wrong process**, so the harness has to: the server fails loudly when its upstream has nowhere to listen, and `bench/mem.py` prints the pid it is reading.

## Where a connection waits is what it costs

**Memory per idle connection is 4,669 bytes, not 8,767, and the whole of the difference was where the fiber was suspended.** [ADR 0071](./adr/0071-where-a-connection-waits-is-what-it-costs.md) has the decision; three premises died getting there and each is worth more than the number. The 8,767 is **the fourth published claim here to fail on re-measurement**, and the second time this same number has — it was corrected once in ADR 0063 and republished in six more files still wrong by a page.

**"Blocked on upstream" was wrong, and it was wrong in an ADR, on the roadmap and in a filed issue.** ADR 0063 concluded that zio exposes no way to obtain the running fiber's stack, having looked through `runtime.getCurrentTaskOrNull`. `zio.coro.Coroutine.getCurrent()` is public in the pinned version and carries exactly that. **A conclusion of "somebody else has to move first" deserves one more hour than it usually gets**, because it is the one kind of finding nothing downstream will ever re-test.

**Then releasing the stack changed nothing at all.** `strace -c` confirmed the `madvise` fired on every idle connection and `VmRSS` did not move by a byte. The first cause was a margin: four *pages* left below the frame, on a call chain four to six kilobytes deep, reached past everything there was to give back — **a page of margin is not a page of safety.** The second is the finding: the connection released its pages and then walked back down into `readHead` and slept four kilobytes deeper, faulting straight back in what it had just handed over. **A release is measured at the frame the fiber sleeps in, not the frame the release ran in.**

**Most of a connection's frame was log lines nobody hits.** `handleConnection` was 4,184 bytes; four `std.log.warn` sites on cold paths were most of it, because Zig builds the format arguments and the writer state in whatever frame the call is inlined into. **A format string costs stack whether or not it is ever printed**, and that cost is per *connection* for anything inlined into a connection loop. Making the cold half `noinline` — and `serveRequest` with it — took the live chain from 5,561 bytes to 1,721.

**The WebSocket needed an API change, and the measurement is what said so.** With the request frame out of line the HTTP chain fell to 1,721 and the WebSocket's did not move, because a handler that keeps `while (try socket.receive())` is suspended *inside* that frame for the life of the socket. So `c.upgrade` takes the loop as a function and the connection loop runs it: 4,345 bytes down to 2,617, which is the crossing from two resident pages to one. An idle socket went from 9,290 bytes to **5,183** — and against [gws](https://github.com/lxzan/gws), which prompted the whole exercise, from losing that row by up to 19% to winning it by 34%.

**A comptime refusal that depends on the optimize mode is worse than no refusal.** The state a handler carries into its loop has a byte ceiling, and 32 looked generous until `c.upgrade(loop, c.query("name").?)` was refused by `zig build test` and accepted by `-Doptimize=ReleaseFast`: **a `Str` is 40 bytes in Debug and 16 in release**, because the use-after-request trap's marker is compiled out. Any fixed byte ceiling is mode-dependent somewhere; the fix is to put it past anything a caller would plausibly write, not to pick a tighter number.

**Building the before is not enough if you only run it once.** The change was measured against a `git archive` rebuild of its parent, which is the rule this repository already had — and then a single 1,485,190 against a single 1,424,878 was published as "throughput went up, and here is why". Run interleaved, four pairs, the difference is +0.6% with the sign changing between pairs and an 8% spread inside each column. **Two samples from the same noisy distribution are not a comparison**, and the reasoning offered for the win — one page of stack instead of two, so fewer TLB entries — was plausible enough to stop anyone asking for a third run. The claim is withdrawn in ADR 0071 and in `bench/result/http.md` rather than restated more carefully. **A mechanism that explains a result is the most expensive thing you can be given before you have one.**

**A marginal figure can still be a transient, and the tell is that it disagrees with the average.** Two rows of the WebSocket table read about 60 bytes above the rows beside them at 2,000 sockets, which looked like a property of a socket that had received a message. Taking the same run to 10,000 collapsed all four rows onto 5,183–5,186: what was being measured was the first message's buffer divided by too small an N. **Marginal meeting average is the thing that says a cost belongs to a connection**, and the earlier stages of this file quote marginal figures at 2,000 without checking it. Each step costs about fifteen seconds; there was never a reason not to run out to 10,000. **The same run was then given to gws, which moved its best row in gws's favour** — 8,206 at 2,000 against 7,836 at 10,000, so the published margin on that row is 1.5× rather than 1.6×. A comparison where one side is converged and the other is not has a thumb on it, and the side to check first is theirs.

**Both sides of a comparison have to be pinned or the number is about the scheduler, and a margin narrower than its own spread is a band rather than a figure.** Unpinned, gws echoes 1,029,308 messages a second on this machine; pinned to the same cores it gets 1,558,146 against nilo's 1,685,719. The first run would have published a 68% win. The fourth said 4.7% and the second said 8.2%, so what goes in the table is **5–8%** — quoting any one of them to a decimal place would have been the same mistake in a smaller size.

## A confidence interval pooled across passes is over-confident

**Ten SQL libraries, eleven operations, and the first sweep nearly published five differences that do not exist.** Every arm was interleaved block by block inside one process, the reported figure was the median of per-block differences, and each 95% interval on `nilo_sql` against pg.zig excluded zero — the whole discipline of ADR 0059's era, applied correctly. Then the same blocks were split back into the three passes they came from and the *sign* moved: `key` read +212, +178, **-147** ns, and the thousand-row-by-twenty-column shape read **-35,008 ns in one run and +5,387 in the next.** Pooling 900 blocks narrows an interval on the assumption that the blocks are exchangeable, and **passes are not exchangeable** — each is a separate session with its own thermal state, so pooling shrinks the error bar around a centre that is itself moving.

The tell is that it only happened to one library. GORM, Drizzle, Prisma and diesel-async held their sign across all six pass-measurements with swings of 0.4-7%, because their differences are 20 to 6,500 times larger. **So the split does not separate a reliable machine from an unreliable one; it separates a difference the harness can resolve from one it cannot** — and `nilo_sql`'s mapper cost is under the floor on nine of eleven shapes, which is a stronger result than the +0.29 ns per value the pooled interval was offering. The rule is now a check in three scripts: real needs the interval to exclude zero **and** all six pass-measurements to agree which arm was faster.

**The mirror of the mistake was waiting on the re-run.** The first sweep overlapped a peer session's multicore build for 13 of its 28 minutes, so passes 1 and 2 were dirty and pass 3 was clean — which makes the old *pooled* median the wrong "before", since two thirds of it was measured on a busy box. Comparing against it would have credited the re-run with an improvement it did not earn. `compare_runs.py` takes pass 3 alone. Two other things fell out of the same episode: contamination is **monotone in its window**, so a scattered slowest-pass count (8/5/8 here) is not contamination but something in your own session, and `subprocess.run` waits on the direct child and nothing else, so a candidate's orphaned grandchild burns cores under the next candidate's measurement. Both are `pgrep` calls now rather than paragraphs.

**The one nilo-specific cost the sweep found had a plausible cause, and counting packets killed it.** `insert` costs `nilo_sql` +2,966 ns over raw pg.zig and `delete` +1,673 ns — the only two of eleven shapes where the difference survives all six measurements — while `update`, which does nearly the same work, is not measurable at all. Both figures sit within a whisker of one unix-socket round trip, so the extra-packet theory was the obvious one, and `OPS_ARMS=nilo|raw` was built to test it because `strace` cannot separate two interleaved arms. The counts came back **identical to two decimal places** — 4.04 socket calls an insert, 4.00 an update, 4.12 a delete, in both arms, `readv` and `sendmsg` splitting evenly. **Same packets, so the cost is CPU inside the process and the next probe is a profile.** Worth the hour: the theory was coherent, matched the magnitude, and would have sent the next person to read protocol code.

**And the driver question the sweep was run to answer had a one-line answer.** pg.zig spends **two network round trips per prepared query where pgx and tokio-postgres spend one**: `conn.zig:243` writes a standalone `Sync` on the cache-hit branch and waits for `ReadyForQuery` before sending Bind and Execute, so caching a statement saves the server's Parse and does not save the trip. ~2.6 us over a unix socket, ~9.2 us over the Docker bridge, which is why its deficit triples with the transport and why it is last on `SELECT 1` while being **first in the field at decoding a thousand rows**. That splits an old lever in two: pipelining is still upstream work of the size ADR 0059 refused, and this is a local coalesce worth all of nilo's single-row deficit against Rust.

## The control that produced the right bytes and did the wrong work

**A payload check compares bytes, and the bug was in how they were produced.** `bench/compare-s3/` subtracts a `/warm/N` route — the same N bytes with no object store behind them — from `/o/N`, and the subtraction *is* the result. Three of the four candidates built that payload once at startup and handed out the same slice per request; Rust's was a `Bytes::clone`, a refcount bump and no allocation at all. nilo allocated from the request arena and filled it every time, because that is what its bounded `get` does. All four returned byte-identical output and all four passed verification, so the control was doing strictly less work than the route it is subtracted from — for three candidates and not the fourth. **A control has to perform the allocation the real path performs, not merely produce the same bytes.**

**What caught it was a number that was large in the wrong place, not a code review.** Go answered a megabyte 2.2× faster than nilo on `/warm/1m` — the route with no S3 in it — while losing to nilo on every route that did real work. Go beating nilo on `/o/1m` would have been a finding worth investigating slowly; beating it by 2.2× on the route that does nothing contradicts what `bench/result/http.md` already establishes about this server, and the contradiction is the whole signal. **Check a new number against what is already known to be true, and open the file on the one that fights it** — it is cheaper than reviewing code there is no reason to suspect.

**A counter on the wrong side of the arena reads zero, and zero looks like a better result than the truth.** `nilo_s3` claimed *one allocation per bounded get* in three doc comments with nothing holding it — the first of ADR 0018's four axes, unheld, which is the shape this file already records four other instances of. The test written to hold it wrapped the allocator a `core.Run` is *built on*, so it counted the arena's trips to the backing allocator; a warmed arena makes none of those, and it read **zero**. A budget test that passes by measuring the wrong layer is worse than no budget test, because the number it prints is the number somebody quotes. The counter belongs where the caller's allocations land — above the arena, which is the way round `http/app.zig`'s budget test already had it. It reads one, and the one is the body, the content type and the ETag in a single block.

**A rule that filters noise was being read as though it certified the number.** The same harness only reports a paired difference when all three interleaved passes agree on its sign — a good rule, adopted from the ORM comparison next door, where every one of one candidate's differences flipped sign once the passes were separated and every one had a pooled interval that excluded zero. It passed here on `/o/1m − /warm/1m` at −226,266 ns CPU/req, three passes, tightly clustered — and the number is meaningless, because the two routes are bounded by different resources: the control saturates memory bandwidth, **where a stalled cycle still counts as CPU time**, while the store route sits waiting on MinIO and stalls less per byte. A route doing strictly more work then reports less CPU per request than its own control. **Sign agreement says a difference is not noise; it says nothing about whether it is a cost.**

**The second test is cheaper than reading the code paths, and it generalises.** A client cannot cost negative CPU, and two candidates running the same operation cannot disagree about the sign of its cost — nilo's megabyte pair came out at −198,702 ns and Go's at +403,929 on the same run. Either condition means the subtraction is measuring the machine, whatever the CPU percentages say, and `bench/compare-s3/table.py` refuses the row rather than printing it. A saturation threshold does **not** catch this case: the binding resource there is memory bandwidth and both routes sat under any sensible CPU ceiling. The weaker case is worth a mark of its own rather than a pass — where the floor is saturated and the store route is not, the subtrahend is measured under contention the other half never sees, so the answer is a *lower bound* on the cost. It biases every candidate the same way, so the ratio between them survives where the absolute does not.

## The control routes were where both of the interesting findings were

**The route with nothing in it found nilo's biggest gap.** `/warm/1m` exists only to be subtracted — a megabyte allocated, filled and written, no object store anywhere near it. Once the control was fixed to do equal work, axum answers it at **18,160 req/s and nilo at 8,215** on the same three cores. That is 2.2× on nilo's own HTTP write path for a large body, larger than any gap on the routes the benchmark was built to measure, and it belongs to `nilo_http` rather than to `nilo_s3`. **A control route is a measurement, not scaffolding**; this file already records the reverse mistake, where a wrong control hid a gap, and the same run shows a right one uncovering a different one.

**A candidate that dies is a result, and the harness has to be able to record it.** Bun 1.3.13 verified clean on all seven routes, including the presigned fetch, and then retained about one byte for every byte `Bun.S3Client` read — 4.5 GB in five seconds on `/o/64k` — until the kernel killed it at 27 GB. `drive.py` has no DNF, so the death took the whole sweep with it and the three candidates that *had* finished had to be re-run. **A comparison harness needs a way to record "did not finish" before it needs another candidate.**

**Growth is consistent with three different problems and the numbers separate them cheaply.** RSS rising under load could be a leak, a collector falling behind, or an allocator keeping pages it will reuse — and only the first is fatal. Three measurements settle it and each is one command: growth tracked bytes read one for one (110 MB read, 112 MB grown); fifteen seconds idle plus a request to poke the event loop returned 24 MB of 2,960; four identical rounds climbed 2,945 → 5,677 → killed instead of plateauing. **The control that closed it was the other warm route** — `/warm/1m` allocated 20.8 GB in the same five seconds and grew 32 MB, so the collector keeps up with allocation at sixty times the rate and what is retained is specific to one path.

## A suite that hangs reports nothing, and three tests had never run

**`zig build test-all` sat at 0% CPU for as long as anybody let it, and the reason it was never chased is that it looked slow rather than stuck.** The number that separates those is not the clock: seven and a half minutes of wall time against **two seconds of CPU**, with four test binaries each holding a listening socket and a connection to themselves. `ps -o cputime` is one flag and would have said "this is a deadlock" at any point in the preceding fortnight. The refusals are genuinely the slow part of this suite and that is written down in `CLAUDE.md`, which is exactly why "tests take a while" was an available explanation and a wrong one — **a documented slow path is the best possible hiding place for a hang.**

**The hang was a test tuned against a kernel default with no margin.** `fetch/live.zig` serves a body the client under test deliberately stops reading, so every byte has to sit in socket buffers; the first draft used a megabyte and hung, and the fix was 128 KiB — which is *precisely* this machine's `net.ipv4.tcp_rmem` default of 131072. It hung intermittently from then on, depending on where send-buffer autotuning happened to be, which is worse than hanging always. The body is 32 KiB now and the ratio to `max_drain` moved with it, because the ratio is what the test is about and the absolute size is only about the kernel. The durable half is that the server takes the next connection on a failed write instead of parking: **the worst case is now a wrong tally with a line number, rather than a suite that never returns.**

**Two more tests were wrong underneath it, and neither had ever been observed running.** One asserted against response headers a `Canned.serveOne` never sent — `extra` was added to the struct and wired into one of the two serving functions. The other asserted that a refused body under the drain ceiling keeps its connection, and **nothing in the module could have made that true**: `std.http.Client.Request.deinit` drains only from `.received_head`, where the body was never touched, and a body that was started and stopped falls into its switch's `else` and marks the connection closing however little is left. Since `take` reads up to `max_body` *before* refusing, every refusal took that path. `max_drain` was a documented ceiling that decided nothing, the test that would have caught it was in the same file as the hang, and all three shipped together in a commit whose suite could not complete. **Work that lands behind a hang is unreviewed by definition.**

**Fixing the drain then moved the hang instead of removing it, and one green run said it was gone.** With `max_drain` finally deciding, the client did the right thing and *kept* its connection — so the canned server, still looping `for (0..count)` over accepts, parked waiting for a second connection nobody was going to open. Whether the suite finished came down to whether the test's `cancel` won a race against a blocked `accept`, and it won here and lost on the next machine to try it. The loop counts **requests** now, which is what the client makes and what the test asserts about, so the server always runs out of work on its own and no race decides anything. **A race that a clean run cannot distinguish from a fix is the case for re-running with fresh seeds** — eight of them here, against the one that had been treated as proof.

**Then the fix segfaulted on the one response shape that has no body.** Draining the leftover is right for a body that was started and stopped, and wrong everywhere else: a HEAD announces a `content-length` and sends nothing, its transfer buffer is empty, and `discardRemaining` on it walks off the end. It took `s3/bucket.zig`'s `head` down on the next run. The lesson is not "handle HEAD" — it is that **a `content-length` is a claim about a body, not evidence there is one**, and the state machine already knew the difference. The branch that was collapsed into one ceiling is now four arms that each say which of std's behaviours they are correcting, because that is the thing nobody can infer from the code.

**Confine a foreign runtime before you load it, because the OOM killer is global.** Bun taking 27 GB did not only kill Bun: it killed MinIO, an unrelated Postgres container and the session driving the benchmark, twice, and the first of those looks exactly like a flaky harness. `systemd-run --user --scope -p MemoryMax=6G -p MemorySwapMax=0` turns a dead machine into a dead candidate, and the whole diagnosis above ran under it. **The kernel log is also the first place to look and was not the first place looked** — `journalctl -k` named the process, the RSS and the constraint in one line, after two rounds of guessing at the harness.

## The second Wire, and the four things reading could not have settled

**A configured maximum is not a cost.** ADR 0074 was written saying a SQLite
pool connection holds "roughly 2 MB of page cache … for the life of the pool",
from `cache_size`'s documented default of 2,000 KiB. Measured, a connection
holds **28 KiB opened and 1,876 KiB once it has touched that many pages** —
the default is a ceiling SQLite grows towards, and the two rows are two
different deployments rather than a range. The follow-up was cheaper than the
correction and worth more: at 5,000 primary-key lookups the ceiling buys
**ten `pread64` at 2,000 KiB and ten at 32 KiB**, and on scans larger than any
cache it buys four reads out of 2,265. **A number lifted from a default page is
a claim about configuration, not about behaviour**, and this one had already
been written into an ADR before anybody ran it.

**The shortcut environment is not a faster version of the real one.** The Wire
routes `db.raw` by its first keyword and leans on read-only reader connections
as the backstop when that guess goes wrong. The test asserting the backstop
**failed**, because SQLite's URI `mode=` parameter takes precedence over the
flags handed to `sqlite3_open_v2` — so `OpenFlags.ReadOnly` against
`file:x?mode=memory&cache=shared` writes, where the same flag against a file
refuses. The in-memory database used to avoid needing Docker had silently
removed the mechanism the design rests on. It sits beside a second one found
the same afternoon: `PRAGMA journal_mode = WAL` in memory returns `memory`
rather than failing, so a suite that ran entirely there would never once have
executed in the journal mode it ships in. **Both are invisible from the
documentation and from the code; only a file shows either.**

**An escape hatch that reads like one, and is not.** `nilo.blocking` lives in
`http/bulkhead.zig`, which `sql/` may not name — `zig build layering` refuses
it — so the obvious way out was `std.Io.concurrent`, whose doc comment promises
to run a function "such that the caller can progress while waiting". zio
implements that vtable slot as `spawnTask`: it starts a **fiber**, so a
blocking C call inside one holds an executor thread exactly as it would have
held the caller's. Reading the implementation took one grep and changed the
whole shape of the module — the threading choice became a field the caller
fills in, because the module that has to make the decision cannot reach the
mechanism. **A promise in a doc comment is about the interface; what it costs
is in whoever implements it.**

**And the loss that was an upgrade.** `std.Thread.Mutex` is gone in Zig 0.16.
Its replacement is `std.Io.Mutex`, which takes the `Io` on every call and waits
through the vtable's futex slots — so a fiber queueing for the single writer
connection *parks* rather than holding its thread, through zio under a server
and through `std.Io.Threaded` in a test. The `io` argument this Wire had been
ignoring, on the grounds that a file has no socket to dial, turned out to be
the one thing it needed: **there is nothing to wait on, and there is still
something to wait for.**

**A benchmark that takes one pass has no way to know it is measuring the
neighbours.** `bench/sql.zig` gained a SQLite half, and its first three
consecutive runs put the same side of the same comparison at 4,537, 6,158 and
8,281 ns — a 1.8× spread, on a box whose `uptime` read **load average 5.03 on
two cores**. Nothing in the printout said so: one pass produces one number and
one number looks like a measurement. The harness now runs five interleaved
passes and prints the *range* of the saving beside the best, which turned a
tidy "60.5%" into "49.2% … 72.2%" — the honest answer, and the one that stops
the number being copied into a document. Taking the minimum did not rescue it
either; a later best-of-five came in worse than an earlier single pass.
**CLAUDE.md's "interleave them, and if the margin is inside the spread the
answer is unchanged" is a property a harness should hold, not a habit a person
should remember**, and §1's Postgres tables predate it.

**The zero was a claim until it was grepped.** Both drivers live in one module,
so every `nilo_sql` user fetches pg.zig and zqlite and links libc whichever they
use. The argument that a program naming only `sql.Db` still links no SQLite
rests on Zig analysing `sql/sqlite.zig` lazily and the linker dropping the
amalgamation — true, and true about *this* linker on *this* target rather than
guaranteed by the language. `strings … | grep -ci sqlite` answers 0 against the
Postgres-only binary and 71 against the other, which is why the A/B is a build
step and two greppable binaries instead of a sentence.

## Twenty findings from somebody else's application

An application was written against the published pages and kept a ranked list
of everything that cost it an hour. Working through all twenty is what this
stage is; six things in it are worth keeping.

**A published snippet decays exactly the way a published number does, and for
the same reason: nobody runs it.** Three one-liners in the guide and the
reference did not compile, each the first thing somebody types on reaching that
page. Writing the build step that compiles them
([ADR 0083](./adr/0083-the-guide-is-the-source-of-its-own-snippets.md)) found
**four more in one five-line sign-in example** — a `db.acquire()` that has never
existed, `find` handed a condition where a key goes, a `Form(T)` read without
its `.value`, and a session set with the wrong struct — plus a real gap in
`nilo_sql`: `.where = .{ .email = form.email }` with a `Str` did not compile at
all, which is the most ordinary thing anybody does with request text. Six of the
seven were invisible to reading, and the seventh was a gap nobody had reason to
look for. The snippet stays in the page and the step extracts it; a directory of
copies would drift, which this file already has four entries about.

**A loud diagnostic on a path that tests exercise has to be a warning.** The
Zig test runner counts an `err`-level log as a failed test, whatever
`testing.log_level` says. Two new diagnostics — an unopened pool, a service
nobody provided — fire exactly where a test drives them, so at `err` they turned
a passing suite red and the pressure is then to delete the diagnostic rather
than fix it. Both are `warn`, which is also what `listen()` has always used for
the mistakes that are about the shape of the program rather than about this
request.

**A diagnostic that fires on a program's shape can be wrong about the program;
one that fires on what the program did cannot.** `testing.Client.send` briefly
checked every route for a missing service and broke a legitimate example test
that never calls the route in question. The check that survived is per-route and
fires when the handler actually asks
([ADR 0079](./adr/0079-there-is-a-phase-before-the-server.md)).

**A library can read the optimize mode of the program that imports it.** This
was written down as an open question and it is a fifteen-minute experiment:
`std` is one module per compilation and takes the *root's* mode, so
`std.log.default_level` read from inside nilo says what the program was built
at, while `@import("builtin").mode` says what nilo was built at. Comparing them
is the warning that had been assumed impossible
([ADR 0084](./adr/0084-a-library-can-tell-what-mode-the-program-was-built-in.md)).
The case it exists for is a test step, so it fires from the test client too.

**`b.lazyDependency` is a request, not a conditional**, and measuring what a
dependent downloads has two caches to clear rather than one — the project's
`zig-pkg/` and the global cache's `p/`. Warm either one and the measurement
gives a confident wrong answer in either direction: nothing downloaded, or
everything unpacked
([ADR 0075](./adr/0075-a-lazy-dependency-is-a-request.md)). Both wrong versions
looked like passes.

**A figure that reproduces twice is on its way to being a constant.** "SQLite
costs 524,840 bytes" was measured, published in four places, and reproduced
exactly by the application that went looking for something wrong with it — the
one item on its list of twenty that turned out to be *right*. It is 523,352
now. Nothing about SQLite changed; the framework around it grew by about 11 KB
and the two probes carry different amounts of it. **A difference between two
binaries is not a property of the thing that differs**, and the way to notice
is to build the before rather than quote it: `git archive HEAD | tar -x` into a
scratch directory, both trees built with the same flags, on the same afternoon.

**A build step that succeeds caches; one that fails does not.** All 46 refusals
are re-analysed on every run because the compiler keeps nothing from a failed
compilation — which is why they are the slow part of `zig build test` and why
the snippet checks, which are the same shape pointed the other way, cost ~30ms
each warm. That asymmetry decides which of the two can afford to grow.

## Getting 0.2.0 to a tag

Four things were held open before the release. Closing them turned up three
bugs, and all three were in code written this cycle.

**The warning about a mismatched build mode fired at the people who got it
right.** `std` is one module per compilation and takes the root's optimize
mode, so a constant of std's own can tell a library what the *program* was
built at, which is [ADR 0084](./adr/0084-a-library-can-tell-what-mode-the-program-was-built-in.md)'s
whole idea and it is sound. The constant chosen was not.
`std.log.default_level` is `.debug` for `Debug` and `.info` for **all three**
release modes, so reading `.info` as ReleaseSafe answered ReleaseSafe for
every correctly built `ReleaseFast` program. `std.debug.runtime_safety` is the
other half and splits the pair.

What makes it worth an entry is the test. There was one, it switched on the
current mode, and its `ReleaseFast` arm was **the one the suite never builds**
(Debug and ReleaseSafe are what `test-all` runs, and both of those arms
passed). A guard with an arm that cannot execute is
[ADR 0033](./adr/0033-a-guard-is-not-a-guard-until-it-has-been-seen-to-fail.md)
with the failure moved one level up: not a guard that has only been seen to
pass, but a guard with a branch that could not be reached at all. The fix was
to make the derivation a function of its two inputs, so all four modes are
checkable from a suite that builds in two.

**A decision can be recorded, moved, and lost in the move.** ADR 0067 decided
that a pooled connection the peer had already closed gets one retry, and
argued it was correctness rather than policy. ADR 0070 then took the gate, the
drain and the deadline into `nilo_fetch` under the heading "no retries", which
is right about somebody else's *service* and swallowed this one, which is
about a socket. Both documents were correct in isolation and nothing re-read
the first. **An amendment belongs in the move, not after it.** 0067 carries
one now.

**And the obvious fix was half a fix, which the measurement caught and the
reasoning had not.** 32 spurious 500s per run after an idle period; one retry
took it to 13. When a whole pool goes stale together, a retry draws a second
corpse about as often as a live socket, because one attempt can only evict the
connection it was handed. Bounding by the pool's own `free_size` takes it to
zero. **The count was the clue all along**: exactly 32, deterministic across
runs and processes, is `std.http.Client.ConnectionPool.free_size`. A
deterministic number is a name you have not looked up yet.

**Two axes recorded as pending had nothing behind them.** `bench/result/s3.md`
said binary size had "the two scratch programs written and no number taken".
The programs did not exist. Writing them took twenty minutes: 708,576 bytes,
of which roughly 51 KB is the module and the rest is `std.http.Client` and TLS.

**And the memory axis was where the release paid for itself.** Two harness
bugs first: the baseline was being read on a server that had already served a
load test, so RSS *fell* as connections were added; and `bench/mem.py` drained
only `Content-Length`, so on a chunked route it stopped after the head and
called a socket with a megabyte backed up in it idle. The second one printed
13,222 B at 500 connections, 45,878 at 5,000 and 26,273 at 10,000. **A
per-connection cost that rises and then falls is not one**, and that is enough
to throw a run out without knowing why.

Corrected, the pair of routes `bench/s3_server.zig` carries for this purpose
finally answered: `/o/1m`, which pulls a whole megabyte into the request
arena, costs **8,782 bytes** an idle connection; `/stream/1m`, which holds none
of it and moves it through 64 KiB of stack, costs **12,876**. The frugal-looking
route is 47% dearer, because the arena is reset at the end of the request and
the stack is reset by nothing.
[ADR 0063](./adr/0063-a-handlers-stack-is-per-connection.md) said this in a
sentence and now has the pair under it.

**The 64 KiB buffer is not what is paid for, either.** Rebuilt at 8 KiB with
nothing else changed: 12,875 against 12,876. Fifty-six kilobytes off the
declaration moved one byte, so the cost is the depth of the streaming call path
rather than what it carries. `nilo_fetch` found the same thing from the other
end (−66 bytes for its buffers). Twice now the visible allocation was not the
thing being bought, which makes **"shrink the buffer" the lever to check last
and "move where it waits" the one to check first.**
[ADR 0071](./adr/0071-where-a-connection-waits-is-what-it-costs.md) by another
route.

**Two more, found by running the suite rather than by reading it.** The canned
server `fetch/live.zig` uses walked a fixed 200-port window, and a server that
closes a connection leaves its port in `TIME-WAIT` for a minute, so three
`zig build test-all` runs in a row exhausted it. The failure arrived as
`error.NoFreePort` inside whichever test was next, which named the wrong thing
entirely. A thousand ports and a start derived from the thread id survives six
runs back to back with 221 ports still held. `reuse_address` was the one-line
version and is refused in a comment: std sets `SO_REUSEPORT` with it, and two
test binaries silently sharing a port is worse than one failing to bind.

And the snippet checker ([ADR 0083](./adr/0083-the-guide-is-the-source-of-its-own-snippets.md))
had never seen `nilo_s3` or `nilo_fetch`, which is why a published object-store
example with two type errors in three lines survived a release cycle. Both
modules are in its world now, and the object-store example is the first block
checked in **declaration** mode rather than body mode, so that half of the
harness has now run at all. Marking it turned up a third thing: the prelude
exports `id`, so a handler parameter called `id` will not compile there. The
parameter is `key`, which is what an object store calls it anyway.


## A mechanism that errs narrow, and what the narrowness was costing

`covers` decides while compiling which types nilo's own JSON writer may touch,
and everything else goes to `std.json` unchanged. That is the right design and
it is stated as such in the file's own header: the cost of being wrong is a
response that differs from what nilo used to send, so it errs narrow. What
nobody had done was price the erring.

**It is answered for the whole value, not per field.** One type it does not
recognise takes the entire struct to `std.json` with it — every string in the
response included, which is the exact work the generated writer exists to avoid.
It did not recognise a `union(enum)` at all, so any response with a union
anywhere in it was paying between 2.8× and 3.2×
([`bench/result/http.md`](../bench/result/http.md)). Nothing was wrong; the
fallback simply had a price and the price had never been on a scale. **The
lesson generalises past this one: a fast path with a fallback has two numbers,
and this repository had only ever measured the first.**

**The control is what turned it from plausible into decided.** The run put four
things side by side, and the one that mattered was the payload with the union
flattened into a plain struct by hand — what somebody writes today to stay on
the fast path. The new encoding landed on it, the two swapping places between
runs, which says the union support is free and the hand-written flattening buys
boilerplate rather than speed. Without that row the honest claim would have
stopped at "faster than before".

It is also a band rather than a figure, 2.8× to 3.2×, because `std.json`'s own
row moves 28% between runs while the other three sit inside 8ns of each other.
Quoting the best pair would have read 3.6×.

**A refusal was right and still became a feature.**
[ADR 0077](./adr/0077-a-lifetime-has-no-rendering-in-json.md) refused a
`union(enum)` as a request body because "nothing in the type says which arm
arrived", which was true and is still true. The way past it was to give the type
a way to say it rather than to weaken the check
([ADR 0085](./adr/0085-a-type-says-how-its-json-is-spelled.md)). Worth keeping
because the reflex on meeting one of this repository's refusals is to argue with
the refusal, and the argument that worked was about the type.

**And the half nilo could not have: `std.json` picks the parser.** Writing is
nilo's call, so a marker is enough. Reading is `std.json`'s, dispatched on
`std.meta.hasFn(T, "jsonParse")`, and nothing can add a declaration to a type
somebody else wrote — so the type hands over a function nilo supplies, and the
feature is two declarations rather than one. The alternative was a JSON parser
in this repository, with the unicode escapes and number edges that come with
one. Same trade the header of `json.zig` already made for floats, arriving on
the other side of the same file.

## Four gaps in `http/`, and the habits that hid them

A scan of `http/` across bugs, consolidation and DX turned up 23 things. Five
were taken. What is worth keeping is not the fixes, which are in
[ADR 0090](./adr/0090-a-body-framed-twice-is-refused.md) and the two
applications of [ADR 0081](./adr/0081-a-ceiling-that-is-reached-is-said-out-loud.md).
It is how four of them stayed hidden while the repository looked straight at
them.

The fifth, a response header that could split its own response, was found
independently on `main` at the same time and is written up under *The right
decision, taken twice, in two places too narrow to help* below. Two scans
reaching the same bug from opposite ends is the strongest evidence in this file
that the choke-point question is worth asking out loud.

**A differential test only finds what its two halves disagree about.**
`fuzz.zig` has held a hand-written reference parser against the fast one since
it was written, and the doc comment on the comparison names request smuggling as
the thing it is for. It never caught any of the four framing bugs, because the
reference parser was written from the same reading of the spec as the parser it
checks: `parseInt` on both sides, `indexOfIgnoreCase(value, "chunked")` on
both sides. Two implementations of one misunderstanding agree perfectly. The
rewrite deliberately took the other route through the coding list, forwards
where `http1` goes backwards, and that is the only version of this test worth
having.

**The one lifetime with no trap behind it was the one whose doc was wrong.**
`Message.data`'s comment said the bytes were "the caller's memory and lives
exactly as long as the caller decides". `receive` takes no buffer: the slice
points into a page borrowed from the executor's free list, handed back when the
connection falls quiet. `docs/reference.md` had it right, "the buffer is the
executor's, lent for one message", so the two copies had disagreed for as long
as both existed, and the wrong one was the one a reader hits from the code.
Every other borrowed thing in `http/` has a Debug-mode trap under it (ADR 0004);
this one had a sentence, and the sentence was backwards.

**A SIMD helper that is fast where it was written is not fast where it is
reused.** The header check was first written with `scan.positionsOf` and cost
9ns of a 192ns request. `positionsOf` falls to a scalar tail below one 32-byte
block, so three delimiters over a 27-byte header name is three passes of 27
iterations. One branchless pass over a 256-byte table is 3ns.
[`bench/result/http.md`](../bench/result/http.md) has the run; the general form
is that `scan.zig`'s header names three callers and all three have long inputs.
The table itself did not ship — the predicate that merged is the RFC grammar
from ADR 0087, a plain per-byte loop — and the lesson outlived the code that
taught it, which is the only reason this paragraph is still here.

**And one correction worth the line it costs.** `Content-Length: 05` went on the
refuse list beside `+5` and `1_0`, on the strength of "leading zeroes" sounding
like the same class of thing. It is two digits, so it is legal, and every parser
in the chain reads it as 5. The test caught it before the commit did.

## A flaky test that was a fair coin

`a pooled connection the peer already closed costs one retry, not a failure`
failed about one `zig build test-all` run in three and passed three of three
under `zig build test-fetch`. Everything about that shape says "the test is
racy under load, stabilise the test". It was not racy. It was a fair coin, and
one side of it was a bug in `fetch/`
([ADR 0091](./adr/0091-a-reaped-connection-arrives-two-ways.md)).

**Take the error before believing the diagnosis.** The failure was reproduced
by making the race deterministic rather than by running the suite more times:
one delay in the canned server, one `catch` that printed the error name, and
what came back was `ReadFailed` from `ECONNRESET` rather than the
`HttpConnectionClosing` the retry was bounded to. Two minutes, and it turned
"flaky under load" into a named defect. Seventy-two parallel runs of the test
binary beforehand had produced zero failures and would have gone on producing
zero, because the load that matters was not CPU.

**A generic error is where information goes to die, and the fix is usually
downstream of somebody else's honest decision.** `std.http.receiveHead` splits
`EndOfStream` by how much of the head arrived (`HttpConnectionClosing` at zero
bytes, `HttpRequestTruncated` past it) and deliberately does not split
`ReadFailed`, because a read can fail for reasons that have nothing to do with
reaping. std keeps both pieces needed to make that split, in `Reader.err` and
in what the reader still holds buffered; it just does not join them up, and it
is not std's job to. Reaching for those two fields is what closed this.

**A test that cannot fail is not covering the thing it names.** The first
`serveThenReset` waited for the client's second request through the connection's
ordinary 4 KB reader, which pulled the whole request into user space and left
the receive queue empty, so `close` sent a FIN and the test passed through the
branch it was written to avoid. It went on passing with its own branch switched
off. What proved it was switching the branch off on purpose and requiring a
failure, which is worth doing for any test written to cover a specific line.

**And the port ranges two files picked did not agree.** Soaking `test-all` ten
times running turned up a second failure with a completely different cause:
`s3/canned.zig` walked 200 ports from a fixed 39,600, inside `fetch/live.zig`'s
39,200–40,199, so `fetch` rolled over s3's whole window and s3 ran out with
`error.NoFreePort` from the sixth run on. `fetch/live.zig` had already learned
both halves of this and written them down in its own `open`; nothing carried
the lesson across the repository, because nothing could. `std.Io.net.Server`
still has no way to read back the port it was given, which was re-checked
rather than believed, so binding zero is not available and two files picking
loopback ports remains an agreement held by two comments pointing at each other.

## The comment that was already the argument for the next check

`rename_all` mapped names one at a time and nothing looked at the set, so
`.lowercase` turned `not_found` and `notfound` into one name and a reader took
whichever variant declaration order put first
([ADR 0093](./adr/0093-two-renamed-names-that-collide-are-refused.md)).

**The reasoning for the fix was already written, one function away, about a
different bug.** `checkTag` refuses a variant whose own struct has a field by
the tag's name, and its comment says why: *"emits that key twice, and which one
a reader takes is its business."* That sentence describes the rename collision
exactly, and it had been sitting beside the code that needed it.

The habit worth keeping is narrow and cheap: **when a check refuses one way of
corrupting the wire, read its comment and ask what else the sentence is true
of.** A comment that explains a hazard in general terms and is attached to one
specific case is a list of unwritten checks. This is the second time in this
file that the repository knew something in one place and not in the neighbouring
one — the first was a header value refused in two files and not the third — and
both were found by reading the justification rather than the code.

## A workaround written into the guide, twice, instead of a bug report

A ticked checkbox posts `on`, `bool` took only `true` and `false`, and so a
`bool` in a `Form(T)` was a 400 the first time anybody ticked a box
([ADR 0092](./adr/0092-a-checkbox-is-a-bool-in-a-form-and-nowhere-else.md)).
What is worth keeping is not the fix, which is one `mem.eql` behind a comptime
slot.

**Both places that met the gap wrote around it and explained why.**
`docs/guide/forms.md`'s opening example declared `remember: nilo.Str =
.static("")`, and `examples/forms` declared the same field with a doc comment
saying *"a ticked one arrives as `remember=on` rather than as `true`, which is
why this is a `Str` and not a `bool`"*. That comment is a correct and complete
bug report. It sat in the repository, in an example that is built and tested by
`zig build test`, describing a defect in the type system's own promise — and it
read as a design note because it explained itself.

**A workaround that documents its reason stops looking like a workaround.** The
question that finds these is not "is this code wrong" — it is *"why is this
field not the type it obviously is?"* Every `Str` standing where a `bool`,
a `u32` or an enum belongs is either a conversion nilo does not do or one it
does badly, and the comment next to it usually says which.

**And the binary measurement was taken wrong first.** The working tree held two
unrelated changes, and the +64/+32/+32/+64 that came back was the other one's
log-message string. `CLAUDE.md` already says to build the before rather than
quote it; the half it did not say is that the *after* has to be the change on
its own. Committing the first change and re-measuring from the new `HEAD` took
one minute and turned a wrong number into byte-identical binaries.

## A family that was named, priced and never given a door

[ADR 0029](./adr/0029-a-spawned-fiber-belongs-to-the-server.md) is careful
work. It measured the fiber it was about to ship, priced the one it refused at
8,673 bytes a connection, chased a zio crash to a standalone reproduction, and
opened by naming what `spawn` was *for*: "a metrics exporter that batches
before it sends, a job that runs every minute". Then it shipped the fiber and
no way to start one.

`listen()` does not return. `nilo.spawn` needs a running server and answers
`error.NoServer` otherwise, correctly. Between those two sentences there is no
line of a program where a ticker can be started, and nothing noticed for a
year: no example spawned anything, and the two mentions in the whole
repository were a table row and a five-line snippet in the reference, neither
of which is executed. **The feature was reachable only from inside a request
handler**, which is the one place nobody wanted it.

What makes it worth writing down is the second half, because the obvious fix
was four lines and was wrong. `serve` set the fiber group *after* it called
the startup hook, so moving one line up lets a Service start its own work from
`nilo_start` — and every example in this repository would have proved it. The
case it misses is the one the guide publishes:
[ADR 0079](./adr/0079-there-is-a-phase-before-the-server.md)'s
`app.start(io)` → `migrate` → `listen()`, where the services are finished in a
phase with **no server in it at all** — the `Io` belongs to the caller — and
`startServices` is idempotent, so `listen()` never asks again. A ticker started
from `nilo_start` under that order gets `error.NoServer` and is never retried.

So the seam was wrong rather than the ordering: `nilo_start` is the phase after
the pool and before the socket, and this work needs the phase after the socket.
[ADR 0086](./adr/0086-work-that-is-not-a-request-belongs-to-the-server.md)
registers it on the App instead, where neither order can skip it.

Two habits caught it and both are already written down here. **A conclusion of
"blocked on somebody else" gets one more hour than it feels like it needs** —
this was the same shape one layer over: a feature recorded as *shipped*, whose
only evidence was a table row. And a check that has only ever been seen to pass
([ADR 0033](./adr/0033-a-guard-is-not-a-guard-until-it-has-been-seen-to-fail.md))
has a sibling: **a feature that has only ever been seen to compile.** The fix
here is the same one — `http/live.zig` is the framework suite's first test to
stand a real server up, because a registration nothing has been seen to *run*
is not evidence that anything runs.

## Two tests that could not fail, on a machine nobody had run them on

Adding `app.spawn` meant running the suite on Apple silicon, and two tests that
had passed everywhere else came apart. Neither was about the change.

**16 KiB pages.** `http/scratch.zig` asked for a 4096-byte buffer and an
8192-byte one and asserted the free list emptied between them, because the
sizes differ. `take` rounds up to `std.heap.page_size_min`, which is 4 KiB on
x86-64 Linux and **16 KiB here** — so both requests were one page, the list was
never asked to hold two sizes, and the test had been asserting nothing for as
long as it existed. It is written in pages now, which is what the test one line
below it had always done.

**A wait with no bound, in the file `CLAUDE.md` already names.** `fetch/deadline.zig`
scans 39,500–39,699 for a port and gives up by returning — without setting the
flag the test then waits on, forever. Six copies of that binary at once was
enough: 10 minutes of wall against 6 seconds of CPU, which is the exact reading
`CLAUDE.md` says to take before believing a suite is slow, in the exact file it
says held a deadlock for a fortnight. **The second one was found by the
procedure written down after the first.**

Both are the same shape and it is [ADR 0033](./adr/0033-a-guard-is-not-a-guard-until-it-has-been-seen-to-fail.md)'s
with a wider brim: a check that cannot fail and a check that has only been seen
to pass look identical — and so does one that hangs instead of failing, because
a suite that never finishes reports nothing at all. The fix was to make the
failure reachable and then reach it: with all 200 ports held, the old binary
runs until it is killed and the new one prints
`FAIL (NoFreePortForTheQuietEndpoint)` in a tenth of a second and carries on
with the other twenty-two.

**A machine you have not run on is a set of constants you have not tested.**
The page size was the one that bit here; it will not be the last.

## The right decision, taken twice, in two places too narrow to help

Response header values were never checked for a newline, so a handler could
split its own response ([ADR 0087](./adr/0087-a-header-value-cannot-end-its-own-line.md)).
The interesting part is not that the check was missing. It is that **nilo had
already made this exact decision twice, correctly, and both times scoped it to
the caller in front of it.**

`cookie.check` refuses a `;` in a cookie value, and says why in its comment:
*"That is response splitting with extra steps, and it is refused here rather
than escaped."* `Ctx.requestId` refuses a forged `X-Request-Id`, and says why in
its comment: *"a newline forges a line of its own, and in a response header it
splits the response."* Two comments, in two files, naming the attack — with
`putHeader` sitting under both of them checking only whether the name was one of
the framework's own.

So the reviewer's question is not "is this input validated?" — twice, the answer
was visibly yes. It is **"is it validated where every caller goes through, or
where this caller does?"** `Set-Cookie` is the proof that the distinction was
load-bearing rather than tidy: `c.setCookie` validates, and a `Set-Cookie`
written through a `Response`'s `.headers` — which is the documented way a
sign-in answers — reached the wire without ever meeting `cookie.check`. The hole
was in the feature that had the check.

The fix is one choke point, which is `aboutToRead`'s shape from
[ADR 0004](./adr/0004-request-arena-and-the-str-type.md): the
place every path already goes through is where a rule survives the next caller
being added. There were five, and the one that would have forgotten —
`Response.headers` — arrived a year after `setHeader`.

**Four binary measurements to establish it cost nothing** — 0 bytes on `hello`,
`rest`, `orders` and `forms`, with the checksums differing to prove the build
happened. A refusal on a path nothing hot reaches is the cheapest kind of
correctness there is, and the reason to measure was to be able to say so.

## Two sentences on one page, describing different behaviour

A session carried no expiry: the seal held a version, a shape fingerprint and
the fields, and nothing about time ([ADR 0088](./adr/0088-an-expiry-a-client-can-ignore-is-not-one.md)).
What bounded a session was `Max-Age` on the cookie, which a browser obeys and a
copy of the cookie does not.

**The documentation had already caught it and nobody read the two halves
together.** `docs/guide/sessions.md` offers `.max_age = 30 * 24 * 60 * 60` under
*Staying signed in*, and three paragraphs later, under *What it cannot do*, says
*"a cookie somebody copied still opens"*. Put side by side those describe
different systems: one where the copy dies in thirty days and one where it never
does. Both sentences were written deliberately, both were accurate about the
half they were describing, and the contradiction sat between them.

That is a different failure from the four this file already records. Those were
premises nobody re-tested — a number, a manifest, a blocker. **This one was two
statements that were each true and could not both be.** No amount of
re-measuring finds it, because there is nothing to measure; it is found by
reading one page end to end and asking whether it agrees with itself.

The fix needed no store and no sweep, which is the part worth remembering: the
reason it had not been done was never cost. `expires_at` is eight bytes inside a
plaintext that was already fixed-size, and the expiry a server writes is a
number the server already has. What it needed was noticing.

**And the check needed `openAt` before it needed the check.** An expiry only a
wall clock can pass is a guard that will only ever be seen to pass, which is
[ADR 0033](./adr/0033-a-guard-is-not-a-guard-until-it-has-been-seen-to-fail.md)
exactly. Splitting the pure half out — `openAt(T, text, key, now)`, with `open`
reading the clock and calling it — turns "wait a day" into three lines naming
three numbers, and is the same shape `modeFrom` has in `app.zig` for the same
reason. Where a guard is *hard to reach*, reaching it is the design problem, not
an afterthought.

## A rule written from inside one function

`Ctx.setHeader` replaced, and `http1.repeats` listed the exceptions. There was
one, `Set-Cookie`, and the comment arguing for it named `Vary` in passing as an
obvious case where replacing is right: *"which is right for `Vary` or a cache
directive, where a second call is somebody changing their mind"*.

**The counter-example was already in the repository, two files away**
([ADR 0089](./adr/0089-two-layers-can-each-name-a-vary-axis.md)). `cors.zig` sets
`Vary: Origin`; `app.zig` sets `Vary: Accept-Encoding` on a gzipped file. Both
have a comment explaining that a shared cache goes wrong without theirs.
Middleware runs before the handler, always, so CORS's was written and then
overwritten on every such response.

The lesson is about where the sentence was written from. *"A second call is
somebody changing their mind"* is true — of one author, in one function, calling
`setHeader` twice. It is false of a stack, where two layers that have never
heard of each other each state something independently true about the same
response. **A rule about an API is a rule about all of its callers, and the
callers to check are the ones in other files.**

Two things about the fix are worth more than the fix.

**The cheap correct answer was the one that fit the budget.** Joining the values
with a comma is tidier on the wire and needs a third string; two header lines
mean the same thing to every cache (`Vary` is a list field, unlike `Set-Cookie`)
and cost two entries in a list that already existed. The RFC distinction — which
field may be folded and which may not — is what made the free option available.

**Raising `inline_headers` was found by a test, not by arithmetic.** The fixed
shape sets seven headers and six were held on the `Ctx`, so the first version of
this change quietly added an arena allocation to the exact path it was fixing.
The budget test was written before the constant moved and failed with `expected
0, found 1`. Writing the measurement first is what turned a plausible change
into a checked one — and the other half of the same cost, memory per idle
connection, could not be measured on the machine at hand and went to the roadmap
as a number owed rather than into the ADR as a claim.

## The number was owed, and the instruction for paying it named the wrong binary

The debt above was paid on a Linux box: four interleaved runs of `bench/mem.py`,
two per side, `d04d1a2` against a `git archive` rebuild of `v0.2.0`. **The
seventh inline header costs an idle connection nothing** and the spread across
all four runs is one byte, so ADR 0089's reasoning holds and the roadmap entry
is gone ([`bench/result/http.md`](../bench/result/http.md)).

The finding is the other half. The roadmap said to settle it with
`bench/mem.py --port 8787 --path /health` against **`zig build run-hello`**, and
that reads **4,810 bytes**, not the 4,669 published in thirteen places. Nothing
had regressed. `run-hello` is `examples/hello` and every published figure was
taken on `bench/main.zig`, which read 4,674 on the same afternoon — two programs
136 bytes apart whose names differ by one character.

**A per-connection figure belongs to a binary, not to a framework.** The floor is
a band of roughly 4,670 to 4,810 depending on which program carries it, and the
constant that gets quoted is the benchmark server's end of it. Nothing said so
anywhere, and `bench/result/http.md` had already been bitten by the same pair on
the binary-size axis — it carries a paragraph warning that `nilo-hello` is
`bench/main.zig` and not `examples/hello`. That warning was one axis short.

The near miss is what earns this a section. Somebody paying a documented debt,
running the exact command the roadmap gave them, would have read 4,810 against a
published 4,669 and reported a 141-byte regression introduced by a change that
costs nothing. **An instruction for reproducing a number is part of the number**,
and it decays the same way — the command was written from the shape of the claim
rather than from the run that produced it.

## Three headers that were read and answered with something else

`Expect: 100-continue`, `If-Range` and a multipart `filename*` were each known to
the parser and each given an adjacent answer rather than the defined one — a
second on every curl upload, the weak-validator comparison on the one header RFC
9110 says must be strong, and an upload bound as a text field with the 400 naming
the wrong thing
([ADR 0094](./adr/0094-a-header-is-answered-as-asked-or-refused.md)).

The lesson that is not in the ADR is about **where the fix goes**. The obvious
place to answer `100 Continue` is where the header is parsed, and that throws the
feature's better half away: answer at the parse and the client sends its body, so
a 413 for an oversized upload arrives *after* the 20 MB. Answering where nilo
commits to reading instead makes "refuse without reading" fall out for free,
because every refusal already happens above that line. **The cheap version and
the right version were the same size, and only one of them was on the roadmap.**

The roadmap's own one-line description of the work — "one more arm in
`applyHeaderAt`'s switch on name length" — was half of it. `parseHead` filters on
the *first byte* before it measures a name, and it passed only `c` and `t`;
`Expect` begins with neither, so the new arm would have been dead code. **A plan
written from reading one function names the change that function needs.**

## A number that grows with a table has to name the table

`http/names.zig`'s rewrite table had fallen fifteen types behind the exports, and
its own doc said `refusals/` was where that would be noticed. Nothing had noticed
([ADR 0095](./adr/0095-the-name-table-is-checked-against-the-exports.md)) — a
refusal proves one message is right and says nothing about the ones nobody
thought to write one for. The replacement is a test that walks the exports.

Filling the table in then broke three files that had not changed a character.
`textOf` set its branch quota as `64 * (name.len + 1) + 4_000`, with a comment
approving of itself: *"The quota tracks the input rather than being a number that
happened to be enough once."* Every row scans the whole name, so the cost is
length times rows, and the table went from 20 rows to 35. The failure surfaced
inside `std.mem` with nothing naming `names.zig`. **The comment was right about
the trap and wrong about the second variable**, which is the same mistake as the
paragraph it sat above.

## The third deadlock in one struct, and a benchmark is what reached it

`zig build test` sat at **ten minutes of wall clock against zero seconds of
CPU**. `ps -o etime,cputime -C zig`, which `CLAUDE.md` names as the one command
that settles this, took one run; `pstree` found two test binaries parked in
`futex_do_wait`.

`fetch/deadline.zig`'s `Quiet` endpoint has a `done` flag, and `done` bounds the
sleep loop at the bottom of `run`. It does not bound the `accept` above it, and
nothing in the file ever connects to `Quiet` directly — the test's request goes
to the *nilo* server, which is what then dials it. So any failure before that
request left `run` parked in `accept` with `done` set and nobody to read it, and
the teardown's `join` waited for a thread that was never coming back. **The suite
hung instead of reporting the failure that caused it**, which is strictly worse
than the failure. The fix is a self-connect in the teardown; before/after with a
deliberate early failure is 2 minutes and no output against 27 seconds and a
named error.

Two things are worth more than the fix.

**This is the third deadlock in that struct and it is six lines below the
second.** The `no_port` field exists because the port scan gave up by returning
and left a wait with no bound — the field's doc says so in those words. The same
reading did not continue down the function.

**What reached it was `bench/mem.py`.** Five runs of 10,000 keep-alive
connections leave the ephemeral range full of TIME_WAIT, so the nilo server under
test could not bind and the test failed early for the first time in its life.
The memory run three sections up and this hang are the same afternoon:
**a benchmark is a machine state, not just a number**, and it is the cheapest way
this repository has found to make a rare failure path ordinary.

## The control was doing work the route it was subtracted from never did

`bench/result/s3.md` ranked "axum answers a megabyte 2.2× faster than nilo, and
it is nilo's own write path" as the biggest gap in the table, and the roadmap
carried it as **nobody has looked**. Somebody looked.
[ADR 0096](./adr/0096-a-response-larger-than-the-arena-keep-is-a-page-fault-per-page.md)
is the decision; four things are worth keeping here.

**It was not the write path, and the file said it was.** On the same `send` over
the same socket with nothing assembled per request, nilo answers 22,018 req/s to
axum's 17,209. `sys` time per request is within 1% of axum's on every variant
measured. The whole difference was user time in the *handler* — an `@memset`
that costs 2.01 s per 20 GiB where glibc's `memset` costs 0.75 and a hand-written
`rep stosb` costs 0.66. **A lever named in a results file is a hypothesis with a
number attached, and it inherits the confidence of the number rather than of the
hypothesis.**

**One constant was 40% of it.** `arena_keep` is 16 KiB, so a megabyte did not
fit in what the arena retains and every request faulted 257 pages back in. It is
a `listen()` option now, with the default unchanged, because the memory is per
connection and that is ADR 0018's hard axis.

**The published before did not reproduce: 8,215 became 7,908 on the same box.**
Measuring against the published figure would have claimed 4% that was the
machine. This is the fourth time that rule has paid here.

**And it explains a row the file had already refused.** The 1 MB CPU subtraction
came out negative and was recorded as void with no cause given. The cause is
that the floor route costs more user CPU than the store route it is subtracted
from, because filling a megabyte is dearer than receiving one. **A control that
is "the same work minus X" has to be checked for a plus as well as a minus** —
`/warm/1m` was the store route minus S3 *plus* a fill, and at a megabyte the
addition was the larger of the two. A negative result is the check working; the
cause was one layer below where the check could see.

## The suite passed, and somebody else's suite found the thing it could not

The WebSocket had never been run against
[Autobahn](https://github.com/crossbario/autobahn-testsuite), which
[`roadmap.md`](./roadmap.md) had carried as a gap on
[ADR 0033](./adr/0033-a-guard-is-not-a-guard-until-it-has-been-seen-to-fail.md)'s
reading: every framing test under `http/` was written from RFC 6455 by whoever
wrote the framing, so the close-code and UTF-8 rules had only ever been seen to
pass. `bench/autobahn/` is the run and
[`bench/result/http.md`](../bench/result/http.md) has it: **294 OK, 4 NON-STRICT,
0 FAILED** of 301 cases, the four being 6.4.x, which want a fail-fast on invalid
UTF-8 mid-message where nilo validates the message whole and closes with the
right code anyway.

So the framing was right, and that is not the lesson.

**The lesson is what the suite left behind.** When it finished, the server was
holding five cores at 100% and would not exit. `ps -o etime,cputime` — the same
one command as the entry above — said 66 minutes of CPU against 13 of wall.
Bisecting it down took a `--http` control and a Docker-free reproduction, and the
answer is in [`bench/shutdown.py`](../bench/shutdown.py): **six ordinary
WebSocket connections, then a SIGTERM, and three runs in four never come back.**
Framework defaults. The control, the same script doing plain requests, is 0 in
10.

Three things this cost, and all three are about how the failure was reached
rather than about the bug.

**No test could have found it, and no test was ever going to.** Every WebSocket
test in the repository drives frames through in-memory buffers, and this needs a
real process, a real signal and several connections in sequence. It took a
conformance suite that nobody wrote for this, run for an unrelated reason.
**A harness borrowed from outside finds what the local one is shaped not to
see** — and here it was not even the harness's verdict that found it, it was the
machine the harness left behind.

**The bisect by case family said 3, 4, 7 and 10 were clean, and they were not.**
Nine families, five hung, four did not, and the pattern looked like a property of
what those families send. It is a race: the same family hangs or does not
between runs. **A flaky failure bisected once produces a clean-looking table and
a wrong theory**, and the only thing that caught it was re-running the "clean"
side.

**It was not upstream, and this file said so before anybody looked.** The
server's last log line is `nilo stopped`, which `drain` writes once
`Stop.in_flight` is zero, so nilo's own shutdown completed and what was left was
`group.cancel()` and `rt.deinit()` — every visible symptom downstream of nilo's
last line of code. It was nilo's: `Wake` submitted two completions to the loop
and never gave them back, so the loop wrote into a fiber frame that had been
handed on. No newer zio was ever tried; the answer was in the last test of
`completion_queue.zig`, which calls `cancel()` after a timeout and says nothing
in prose. **A dependency's tests are part of its documentation.**
[ADR 0098](./adr/0098-a-completion-the-loop-holds-outlives-the-frame-that-submitted-it.md)
is the decision. That makes five blockers this repository has been wrong about,
four of them somebody else's code.

## The number nobody had taken was the number that had been there all along

Two entries in [`roadmap.md`](./roadmap.md) waited on the same measurement and
came back with opposite answers, and neither answer was a fix.

**A held stream costs 21,058 bytes**, against 4,674 for an idle keep-alive
connection on the same server and the same run, and 53,825 for the same stream
with 32 KiB touched on the handler's stack first — 32,767 bytes more, which is
[ADR 0063](./adr/0063-a-handlers-stack-is-per-connection.md) charged one for
one. `docs/guide/streaming.md` used to quote **~21 KB** from v1 and had the
figure removed for predating both the stack finding and the release-while-idle
work. **It was right.** Removing it was still correct — a number nothing stands
behind decays into a claim whether or not it happens to be true — but the file
was more useful wrong-and-checkable than silent, and it was silent for two
stages.

**The logger's kilobyte was not there.** `logger.with`'s inner `log` declares
`var buf: [1024]u8` and was a plain `fn`, so it read as a candidate for inlining
into `run`, whose frame is live across `next.run(c)` — exactly the mistake
[ADR 0071](./adr/0071-where-a-connection-waits-is-what-it-costs.md) §3 found in
`handleConnection`. Building it both ways produced **byte-identical binaries**:
LLVM was already not inlining it. A route with the logger in front and one
exempt from it measure 21,058 and 21,057 bytes.

**A reading of the source that names the right rule can still be about nothing.**
The rule was ADR 0071's own, the shape matched it, and the conclusion was still
wrong — which is the argument for `Waiting on: a number` being a real state
rather than a polite way of saying somebody should get around to it. The
`noinline` is kept as a pin: free today, provably, and what an optimiser chooses
is not a guarantee.

**And the harness was what was missing, not the machine.** `bench/mem.py` drains
a response before calling a connection idle, and a stream being held open has no
end to drain to, so the tool read the head and then waited for a body that was
never coming. That is why the run had not happened; `--hold` is nine lines. The
first table taken with it was wrong in the other direction — 4,852 bytes a
stream — because all four rows ran against one server and RSS does not come back
down, so every row after the first was measured against a baseline full of
memory the allocator was about to hand out again. **One fresh server per row**,
and marginal met average at every step from 500 up.

## A gap written down from reading two functions described a third one wrong

`roadmap.md` carried `Router.add` and `Router.conflicting` classifying a segment
that is only a colon differently — `add` at `part.len > 0` and `conflicting` at
`part.len > 1` — and said the consequence was that registering `/a/:` twice
"reports no conflict and leaves two routes matching the same requests, one of
them unreachable". **The drift was real and the consequence was not.** `add`
runs its own `Route.sameShape` check over the routes already registered, so the
second one is refused whatever `conflicting` said; and `validatePattern` refuses
a `:` with no name after it while compiling, so nothing but a direct caller of
`Router` could reach the pattern at all. What the disagreement actually cost was
the error message: `App.tryRoute` skipped the one that names both patterns and
let `add` answer with a bare `error.DuplicateRoute`.

**The reachable bug was the line the entry mentioned last.** `add` asserted
`std.mem.count(u8, pattern, ":") <= max_params`, and a `*` carries no colon
while `fill` writes it into `Match.params` like any other capture — so eight
params beside a catch-all is nine captures, and the assert that exists to stop
`fill` running off the end of an eight-slot array read it as eight. Counting the
segments that are not literals is the same three lines and counts what is
actually captured.

**Two functions were read and the third was assumed.** Both halves of this were
written down from `add` and `conflicting`; neither `sameShape`, which sits inside
`add`, nor `validatePattern`, which every `App` route goes through first, was
opened. **A consequence is a claim like any other**, and this file's own rule
about numbers applies to it: it decays the moment nothing re-derives it, and a
consequence decays quietly because nothing fails when it is wrong.

## Half the cost of a feature was a float printer nobody asked for

Metrics shipped ([ADR 0100](./adr/0100-the-route-table-is-the-registry.md)), and
the design question the roadmap had left open — *can any of it be had without an
allocation per request* — turned out to be answered by something the router had
from the first week. **The set of routes is closed at `listen()` and already
numbered**, so a counter is an array index the request is holding anyway rather
than a key somebody hashes. That is the whole reason `/users/1` and `/users/2`
cannot make two series, and it is why counting a request allocates nothing.

**Two of the four measurements moved a decision, and both went against the first
draft.**

The first was the binary. `le="0.0001"` was being printed with `{d}` on an
`f64`, which links Zig's shortest-round-trip float formatter: the feature
measured **37,112 bytes**, and writing the six decimal places out with integer
division took it to **17,416**. More than half the cost of metrics was a float
printer, linked for a page that is read every fifteen seconds. **Reach for
`{d}` on a float and something large arrives with it** — worth knowing before
the next feature formats a number.

The second was the throughput, and it moved a decision by refusing to say
anything. Four interleaved pairs came back at −2.2%, +2.0%, −5.1% and +2.3%:
the sign changes twice, the spread is seven points wide, and the means differ by
0.8% inside it. Sharded per-thread counters were the obvious next step and are
**not built**, because nothing has measured a reason to build them — and the
run that would settle it is named in the roadmap rather than left implied.

**The refusal needed a hole in it, and the review found it.** "No registry" was
right — a name per increment is a hash and a lock on the request path — but it
is only sound if a counter the application already owns can be published.
Without that, an app with an `orders_placed` of its own runs a second metrics
server, and nilo's page is not incomplete, it is a decoy. `app.expose` is the
answer and it costs nothing per request: **a refusal is only as good as the
thing it leaves you able to do instead.**

## An oracle that shares your reading proves nothing

Five gaps closed at once, and two of them had been sitting in front of a test
written to catch exactly that class of bug.

**`fuzz.zig` carried `Transfer-Encoding: chunked, identity` in its corpus, and
the reference parser read it the same wrong way `http1.zig` did.** The two
agreed, the differential passed, and a request framed as having no body while
its body sat in the read buffer went unnoticed
([ADR 0101](./adr/0101-a-request-nobody-else-would-answer-is-refused.md)). A
differential test whose oracle was written from the same reading of the spec
checks that the reading is *consistent*, not that it is right. Nothing about the
harness finds that; reading the RFC again does.

**A rule that refuses more can silently retire the corpus that was testing
everything else.** Requiring a `Host` would have made all forty entries fail for
want of one, so the forty checks about framing would have stopped running while
staying green. Every framing entry grew a `Host`; the block-edge trio deliberately
did not, because their byte offsets are the point and a header line in front
would move all of them. **When a new refusal lands upstream of an existing test
corpus, the corpus is part of the change.**

**And the throughput number was measured on the wrong instrument.** Four
interleaved wrk pairs on a two-core box put the parser change at −3.6%, −5.3%,
+0.3%, −4.5% — three negatives and a spread as wide as the margin. `zig build
profile` put the row that actually changed, *parse the head*, at 100ns → 109ns
across four interleaved rounds with every "after" above every "before". Eight
nanoseconds of arithmetic cannot be 5% of a 26µs request; what wrk was measuring
was the box. **Reach for the instrument that contains the change**, and when the
whole-system number and the component number disagree by an order of magnitude,
the component number is the one that means something.

## A blocker that closed itself, and a gap the instrument could not see

Five more gaps, and the first of them was not work — it was a number that had
already been earned and nobody collected.

**`nilo_fetch`'s 16,495 bytes an idle connection was measured two days before
the fix for it shipped, and the entry describing the fix as unbuilt stood for a
month.** `bench/result/fetch.md` ranked "give the fiber's stack pages back
between requests" first and called it an `http/` change nobody had made;
`releaseIdleStack` had made it, in the commit after the one that wrote the
ranking. Re-running the same harness put the figure at **4,139**. Nothing was
built to earn that; a benchmark was re-run.

That is the fourth premise this repository has planned against after it stopped
being true, and the first three are all above. What is new is the shape:
previous ones were somebody else's code. This one was **our own commit, two
days later, in a file the entry links to.** So the rule "a conclusion of blocked
on somebody else gets one more hour" does not go far enough. **A number is a
claim about a commit, and the next commit can retire it.** The cheap habit that
would have caught it is re-running the ranked lever before quoting the ranking.

**The same run inverted a lever that had been measured and dismissed.** Moving
`std.http.Client`'s two buffers off the stack into the request arena was worth
−66 bytes and was written up as "tried and lost". It is now worth **+4,096, one
page, every time** — because stack is handed back when a connection goes quiet
and the retained arena is not, so a lever that used to move bytes between two
places that both held them now moves them out of the only one that lets go.
**A result of "no difference" is the one nobody re-runs, and it is the one most
likely to have changed sign.**

**And a security gap was invisible to the instrument this repository reaches
for first.** `c.body()` took the announced `Content-Length` out of the arena
before reading a byte, and `bench/mem.py` reads `VmRSS` — which does not count
a page nobody has written to. The first run said a stuck connection cost 17,281
bytes either way and the gap did not exist. `VmData` said 1,852,080 against
316,080. **A mapping nobody has touched is free in the instrument and not free
in the machine**, so the right reading for "what did this commit *ask* for" is
`VmData` and `VmRSS` is the reading for "what is it using".

The honest half of that finding is that the roadmap's "ten gigabytes a server
will commit" was right in kind and wrong about which resource, and the resident
figure never moves. It was still worth fixing — but the fix had to be argued on
address space and `vm.max_map_count`, not on RAM, and the two shapes tried
before the one that shipped were both rejected on throughput rather than on
memory ([ADR 0105](./adr/0105-a-body-is-taken-as-it-arrives.md)).

**A growth loop is not free just because the copying is cheap.** Fixed 16 KiB
steps into a `std.ArrayList` cost 35% of a 64 KiB body and 45% of a megabyte;
explicit doubling saved almost none of it. The copying was never the cost —
every growth past the retained arena block is a fresh node from the page
allocator, and on two cores an `mmap`/`munmap` pair costs more than the rest of
the request. What fits is one step of proof and then one allocation.

## The mechanism the roadmap named was the one thing it got wrong

The rate-limiting entry had sat under **Next** for two cycles with three
questions on it, and it named the shape as well: *a fixed table sized once at
`listen()`*, on the model of what `app.metrics` does. That sentence was wrong,
and finding out why was the whole design.

**A middleware has no startup hook.** `use()` takes a function pointer; there is
nothing for one to run when the routes resolve. So "sized at `listen()`" would
have meant a hook on `App`, or a registration protocol, or a Service — machinery
in three files for a feature that is one. What replaces it is smaller than what
was asked for: a table **sized while compiling**, in `.bss`, which is no
allocation at startup either and no change to `App`, `Ctx` or the Bulkhead
([ADR 0114](./adr/0114-an-allowance-is-a-table-sized-while-compiling.md)).

The lesson is about how a roadmap entry decays. The *gap* stayed true for two
cycles; the *mechanism* named beside it was a guess made before anybody tried to
write it, and a guess in a plan is read as a constraint by whoever picks it up.
An entry that names a shape should say whether the shape was tried.

## A benchmark whose client is the bottleneck can only say "unchanged" quietly

Four interleaved pairs put the allowance at +5.1%, −1.4%, +0.7% and −0.8%
against its control — sign changing, spread wider than the margin, which by this
repository's own rule reads as unchanged. It is a weaker "unchanged" than it
looks. Both sides ran at **30k req/s on a two-core box** where the server does
1.4M on the machine the rest of `bench/result/http.md` was taken on, because
`wrk`'s per-request Lua callback defeats its own precomputed request buffer and
the client ate the machine. **A cost of 50ns a request would have been invisible
there, and 50ns is 7% of the real thing.**

The rule that came out of it: *no difference* has a resolution, and the
resolution belongs next to the result. "Unchanged" from an instrument that could
not have seen the change is not the same claim as "unchanged" from one that
could, and only the second one closes the question.

## A name cannot say whose file it came from

`@typeName` spells a type as its path from **its own module's root**, so an
application rooted at `src/main.zig` names a sibling's type `room.Room` — byte
for byte what nilo names its own. Anchoring the rewrite table's match, which had
been written down as the fix for months, could not have worked, and a twenty-line
program in `/tmp` settled it in one run
([ADR 0122](./adr/0122-a-type-says-its-own-name.md)).

The lesson is about which experiments are cheap. The entry had sat under
*Waiting on: a design* through several cycles while the question it turned on —
what does `@typeName` actually print for somebody else's file — was one program
away the whole time. **A design blocked on what a compiler does is blocked on
nothing.**

## A microbenchmark on a shared box needs its minimum, and needs running twice

Best of five put `utf8ValidateSlice` at 38ns on the payload nilo measures and
6,585ns on a kilobyte of non-ASCII. Best of 25, run three times, put the same
two at 10ns and 2,404ns — 3.8× and 2.7× apart, with the last two runs within 1%
of each other. Three of this session's own builds were on the box for the first
attempt.

38ns would have been 30% of the JSON write and the wrong side of ADR 0001's bar;
10ns is 8% and under it. **The bad number would have blocked a correctness fix**,
which is the direction that costs the most: a measurement that is too pessimistic
does not announce itself, because the answer it produces is "don't".

## The fourth blocker that had already gone

The roadmap said an `Upload` could not reach a disk because `bulkhead.Dir` can
only open, and that adding a write meant deciding what a two-megabyte write does
to the fiber issuing it. The pinned zio had `Dir.createFile`, `File.stdWriter`
and `Dir.createFileAtomic` all along, and routes a descriptor the loop cannot
poll to its own thread pool — so the write parks the fiber and nothing needed
`nilo.blocking` ([ADR 0123](./adr/0123-a-file-is-written-by-the-engine.md)).

That is the fourth time here, after [ADR 0063](./adr/0063-a-handlers-stack-is-per-connection.md)
made re-reading a blocker a rule. What is new is *why this one survived*: the
entry did not say "blocked on zio", it said "blocked on a design", and it
argued the design at length and well. **An entry that reasons carefully from an
unchecked premise reads as the most finished item on the page.** The premise
here was one line — `engine.Dir` has no `createFile` — true of nilo's wrapper
and never of the thing being wrapped. The rule it generalises into is now the
last section of ADR 0063.

## A standard-library trap that accuses the Engine

`std.testing.tmpDir(.{})` in Zig 0.16 hands back a directory that cannot be
iterated, and iterating it anyway does not return an error. It panics inside
`std.Io.Threaded` — "programmer bug caused syscall error: BADF" — from a seek
on the directory's descriptor, which reads as a file descriptor used after it
was closed. **The symptom names the layer nilo owns**: a test that had just
written a file through `bulkhead.Dir` looked exactly like a Bulkhead or an
Engine bug, and the next person to hit it will go and read zio.
`.{ .iterate = true }` is the whole fix.

That is the second std 0.16 trap here whose symptom accuses the wrong layer,
after `async_limit`. Both are worth the two lines they take, because the cost
of one is not the fix — it is the hour spent reading the innocent file.

## The blocker was the exact semantics, not the goal

A buffered body needed a whole-body deadline and the roadmap had it blocked on
the Engine, with the reasoning written out and correct: the wanted rule is
"each read gets `body_timeout_ms`, and no read may pass an absolute instant",
zio's `Timeout` is `none | duration | deadline`, and it cannot express both.
True, checked, and the wrong question.

What shipped is a deadline per read *run*, sized from the bytes that run is
waiting for ([ADR 0124](./adr/0124-a-buffered-body-arrives-at-a-rate.md)). It
catches the same client at the same instant, needs nothing from zio, and the
only thing it gives up is *where inside the run* the client is cut. Nobody
wanted that.

**A requirement written as one mechanism reads as a blocker; written as what it
has to catch, it reads as a choice.** The entry said "neither layer can express
that today", which is a sentence about a union's arms rather than about a slow
client. That one planned against an unchecked premise, this one against an
over-specified goal; the rule both of them fell to is in ADR 0063's last
section, and that is the canonical copy from here.

## The whole write half of a dialect had never been compiled

Five gaps in `nilo_sql` closed at once, and three of them were one gap wearing
three faces: **a method on a generic struct is analysed only where it is
called, so `DbOf(sqlite.Wire, …)`'s write path had never been compiled by
anything on `zig build test`.** `sql.Sqlite`'s only caller was `bench/sql.zig`,
which is not on `test`; `sql/live.zig` is Postgres only; `sql/sqlite.zig`
drives the Wire and not `db.zig`. So `.in`, a `Json(T)` column and an enum
column were each a `@compileError` four frames inside zqlite, and `.in` was
documented as working in three places
([ADR 0119](./adr/0119-the-sqlite-write-path-is-compiled.md)).

**A generic that is never instantiated is not tested, it is not even parsed for
meaning — and a green suite says nothing about it.** `touchEverything` exists
in this repository precisely because somebody knew that; it had simply never
been pointed at the second Wire. The lesson is narrower than "write more
tests": when a type is generic over a seam, the *number of seams the tests
instantiate* is the coverage figure that matters, and it is not the one any
tool reports.

**Two of the five were hidden by the fixture that was supposed to prove them.**
The suite's SQLite schema-check test declared `id INTEGER PRIMARY KEY
AUTOINCREMENT NOT NULL`; the redundant `NOT NULL` walked around the fact that
nilo read a rowid alias as nullable and refused to start on the table every
SQLite tutorial writes
([ADR 0115](./adr/0115-an-integer-primary-key-is-the-rowid.md)). And
`streamAndClose` closed a result set twice — the exact provocation — while
asserting only on a Debug-only counter, so in ReleaseSafe it ran the buggy path
and checked nothing
([ADR 0117](./adr/0117-a-guard-against-double-release-is-not-a-debug-trap.md)).
**A fixture written in a spelling nobody uses tests a path nobody takes**, and
**an assertion behind `if (traps_enabled)` is not an assertion in the mode
people deploy in.**

**A stuck build has a third cause, and it looks like the two already written
down.** CLAUDE.md says to take a stuck build's CPU time before believing it is
slow, because `etime` high with `cputime` near zero is a deadlock. It happened
here — a test hung — and the first two hypotheses were both wrong before the
right one: the box had three `zig build test-all` runs on two cores, and
`2>&1 | tail` buffers everything until the pipe closes, so a live run and a
dead one both show an empty output file. Three readings all pointed at an OOM
kill that never happened. **`ps --ppid <pid>` is the reading that settles it**:
the parent is in `do_wait` either way, and only the child's own `cputime` says
whether anything is running. Redirect to a file rather than piping to `tail`,
or the log is invisible until the end.

**And there is a fourth signature, which is the dangerous one because it does
not look like a failure at all: a green run about a tree that no longer
exists.** A build reads each file when its step starts, so editing while one is
in flight produces a pass that validated bytes nobody has. It happened twice
here on a box where a suite takes forty minutes — the edit window is wide
enough to walk through without noticing — and the second time the reported-green
run was thrown away and re-run on the frozen tree rather than believed. So the
three readings that all look like "the build is being slow" are now four:

| what you see | what it is |
|---|---|
| `etime` high, `cputime` near zero | a deadlock |
| both high, `free` near zero | an OOM kill |
| empty output file | `2>&1 \| tail` holding the log until the pipe closes |
| green | possibly about a tree you have since edited |

**Stop editing, then run, then commit** — in that order, and the discipline is
worth more the slower the box is.

The hang itself was real and was in the new test rather than in the code under
it. **`std.Io.Threaded`'s default `async_limit` is one less than the number of
logical cores, and past that limit `io.async` runs the task inline on the
caller's thread** — documented behaviour, not a fallback for an error. On a
two-core box that is one, so a test wanting two parked fibers deadlocks in a
way that looks exactly like the bug it was written to catch
([ADR 0116](./adr/0116-a-queue-per-question-not-one-condition-for-two.md)).

**That claim was then checked rather than believed, and the checking is the
part worth copying.** A reader pointed out that fifteen files construct a
`std.Io.Threaded` with default options and the suite is green, so either the
hazard was latent or the reading was wrong — two findings of very different
size. Ten lines of `zig test` settled the first half: `cpuCount = 2`,
`async_limit = 1`, and a second outstanding `io.async` reporting **the main
thread's** id. Counting the call sites settled the second: every `io.async`
here is one per test body, sixteen in `fetch/live.zig` and fourteen in
`s3/canned.zig`, all of them "stand a canned server up, then be the client",
and the files named as most at risk turned out to have none at all. **Latent,
not active** — no existing site needs changing, and the one that needs to know
is the next one written. A hazard nobody is standing on is a paragraph; a
hazard fifteen files are standing on is a change to two modules, and picking
between them by reasoning would have been the expensive kind of wrong.

## The paragraph was believed instead of the file it describes

Two sessions gated one merge by running seven module steps by hand, because
`CLAUDE.md` lists each of them as its own command and never said that `test-all`
depends on all of them. It does: `build.zig` has `test_all_step.dependOn(test_sql_step)`
and `test_sql_step.dependOn(refusals_sql_step)`. One grep of the file the
paragraph describes would have settled it, and neither reading of the
paragraph produced one — the second even arrived with a mechanism attached
("the module is behind `-Dsql`"), which is what makes a reader stop checking.

**A mechanism asserted is worse than a conclusion asserted**, for the reason
[ADR 0063](./adr/0063-a-handlers-stack-is-per-connection.md)'s last section
gives: it reads as the work of checking, already done.

This is the same shape as `connect_on_init`, documented in three files and never
implemented ([ADR 0062](./adr/0062-a-pool-that-dialled-itself-whatever-it-was-told.md)),
and as five `<!-- compiles -->` marks on pages no build step opened. Each time,
**the documentation was believed and the thing it documents was not opened.**
The fix here was to the paragraph, not the build.

There is a third variety with nobody at fault, and it turned up an hour later in
the paragraph describing those marks. It said three marks on four pages, which
was true of the tree it was written on; the merge brought a fifth page and two
more marks, and the sentence went stale without anybody touching it. **A count
is a claim with an expiry date, and a merge is when it expires** — so the line
worth writing beside one is its closing condition. "Delete this when `pages`
names every page below and `snippets` is green" survives a merge; "three marks,
at these line numbers" cannot. This entry proved it on itself inside two hours:
it cited those two `dependOn` calls as `:1989` and `:2018`, and the next batch
to land moved them to `:1997` and `:2026`. A line number is a count. **Cite what
a line says, not where it sits.**

## A design nobody attacked was three defects wide

The Allowance shipped with its trade written down and argued for
([ADR 0114](./adr/0114-an-allowance-is-a-table-sized-while-compiling.md)), the
four axes measured, 1,186 tests green, and five refusals holding the
misconfigurations. Then it was put to an outside reviewer with its four load-
bearing judgements named as things to attack, and three of them fell.

The one worth the entry is not any of the three. It is **which** three:

- **The blanket fail-open.** "Four failed compare-and-swaps let the request
  through" was written as caution and reasoned about as one case. It is two.
  Losing the race while *claiming* a slot is contention with a stranger, and
  letting it through protects somebody who has made no requests. Losing it on a
  slot that already matches your fingerprint is your own traffic against
  itself — and the shipped code treated them the same, which made the ceiling
  *the server's concurrency* rather than `per_window`. A synchronised wave from
  one address walked past the limit, repeatedly, with no botnet and no hash
  work.
- **The IPv4 fast path.** "The kernel writes it canonically, so hash the text"
  is true of the kernel and false of `X-Forwarded-For`. `10.0.0.1`,
  `010.0.0.1` and `::ffff:10.0.0.1` were three keys for one address.
- **A fixed hash seed.** Nobody had asked what the *index* costs to guess. It is
  twelve bits: grind a key into the victim's bucket, send one request, and their
  count restarts. The fingerprint was sized against collision and was never the
  thing under attack.

The pattern behind all three is the same, and it is the lesson: **each was a
sentence that had been reasoned about once, at the level of the whole feature,
and never re-read against a case that splits it.** "It fails open on purpose" is
a decision about one situation applied to two. "IPv4 arrives canonical" is a
fact about one source applied to every source. "The fingerprint is 34 bits" is a
defence against the wrong half of the key. Every one reads as settled, and the
ADR made them harder to re-examine rather than easier, because writing the
reason down is what makes a claim look finished.

So: **the four axes cannot tell you a feature is right, only that it is
affordable.** ADR 0018's budget was satisfied throughout — the defects cost
nothing and changed no number. What found them was handing the design to
somebody with no stake in it and asking for the attack rather than the opinion,
which took one prompt and about ten minutes, against roughly a day of building.
Two of the four judgements did survive, and knowing which two is worth as much
as the corrections: the fingerprint-versus-eviction ordering holds, and a
decaying counter is **not** strictly better than two counters in the same 64
bits, which closes a question the roadmap had open.

The correction that is not in the code belongs here too, because it is about
reading the structure honestly rather than fixing it: **eviction is the dominant
loss, not collision.** At 100,000 addresses through 16,384 slots every bucket is
full and about 84,000 insertions displace somebody. "Your neighbour used your
allowance" was the failure this design was built to avoid, and it arrives anyway
through the front door.

## A false guarantee spread by being copied, in under an hour

`<!-- compiles -->` above a fenced block means a build step extracts it and
compiles it ([ADR 0083](./adr/0083-the-guide-is-the-source-of-its-own-snippets.md)). The
step reads a list of pages in `build.zig`, and a marked block on a page that is
not in that list is silent — it looks exactly like a checked one and claims
exactly as much.

Three such blocks had been sitting in `docs/guide/metrics.md` and
`docs/guide/responses.md`. Two more were added to `docs/guide/middleware.md`
**the same evening the gap was being discussed**, by somebody who had been told
about it an hour earlier. All five compiled once the pages were listed, so the
marks were truthful about the code and false about being checked.

The two new ones are the useful half, because the old ones can be explained as
drift and these cannot. **They were produced by imitation.** Looking for the
right way to mark a block, the thing to do in this repository is to match the
surrounding code — so `docs/guide/metrics.md` was opened, the
`<!-- compiles: body -->` above `try app.metrics(.{});` was read, and the
pattern was copied. That page was one of the three already dead. The confidence
came from precedent rather than from verification, and the precedent was the
bug.

So the failure mode is not forgetfulness, which is what "somebody has to
remember to join the list" suggests and which more care would fix. **It is that
a broken instance of a convention is indistinguishable from a working one when
read, and reading is how conventions spread.** Two people looking at the gap
directly, on the same evening, produced two more of it.

What ends the class is not a bigger list: it is the step finding the pages
itself — every page that *contains* a marked block — so that a mark cannot be
written anywhere the step will not read. Until then the list is a rule that
looks like a build step and is not one, which is the thing this repository
already says it will not keep.


## Two conventions that only a test runner enforces

Zig's test runner fails a run when `std.log.err` is called during it, whatever
`std.testing.log_level` says — the level decides whether the line is *printed*,
and the counter increments either way. Nothing in this repository knew that,
because nothing had ever logged at that level from a path a test takes.

That turned out to be a convention rather than luck: **every `std.log.err` in
nilo means the server is refusing to start.** Twenty-three call sites, all of
them a `listen()` that returns instead of binding, and everything on the request
path — including a handler that failed — is `warn`. Three new lines broke it in
one evening, and the compiler had nothing to say about any of them.

The fix for the two on the request path was to match the convention. The third
was a genuine startup refusal, and it moved the *message* into `listen()` and
left the parse returning a plain error — which is what the three older startup
refusals do, and is why none of them had ever been unit-tested. The test got
better rather than worse: it now also checks that the sentence names the rule
that was wrong instead of the one before it.

**The general shape is worth keeping.** A rule the codebase follows perfectly
and states nowhere is a rule the next change breaks, and it breaks quietly if
the thing that catches it is a test runner's exit code inside a build step that
prints `failed command:` lines on a good day
([`CLAUDE.md`](../CLAUDE.md)).

## A stack trace on the ordinary restart path

A unix socket left behind by a killed process is cleared by connecting to it:
a live server accepts, a stale path refuses. The probe went through `std`, and
`std.Io.net.UnixAddress.ConnectError` does not list `ConnectionRefused` — so
std answers the refusal *the probe is looking for* with `error.Unexpected`,
`unexpected errno: 111`, and a stack trace on stderr, in every Debug build.

`catch {}` does not help: the trace is printed before the error is returned.
zio maps the same errno properly, so the probe uses zio and the `stat` beside
it still uses std.

The same shape then appeared in the test client, where a connect racing a
server that had not bound yet produced the same trace and the same "this suite
is failing" appearance. Waiting on the filesystem was not enough — on a path
that already held a stale socket the file is there before the server is, and
the inode of the replacement is routinely the one just freed. What answers it
is asking the *server*: a fiber registered with `app.spawn` cannot run until
the loop is up and the socket is bound
([ADR 0029](./adr/0029-a-spawned-fiber-belongs-to-the-server.md)).

**`error.Unexpected` from `std` is not a quiet error**, and a path that expects
one should be read as a path that prints a stack trace.

## The exemption that was forced by the metric, not by the feature

`watchdog.zig` excused a stream, a body reader and a WebSocket from the blocking
detector, and its header called that "a stated gap, not an oversight". The
roadmap wanted a message-scoped watch and was waiting on a design for where one
would start and stop.

Neither was the real question. The exemption was forced by the *metric*:
elapsed-minus-parked, summed over a request, has no upper bound on a connection
that stays open, so a WebSocket answering a thousand messages a second
accumulates seconds of perfectly correct handler time. Change the metric to the
longest stretch between two parks and the exemption evaporates — one stretch
means the same thing on a request that lasts a millisecond and on a connection
that lasts a day ([ADR 0132](./adr/0132-what-is-watched-is-one-unparked-stretch.md)).

What it needed was three waits saying so, and each of the three was the reason
its handler had been excused in the first place. The machinery was already
there; `waiting`/`waited` were doing the wrong arithmetic with it.

**A gap that has been waiting on a design for a while is worth re-reading as a
question about the measurement rather than about the feature.** This one had
been stated three times, in three files, always as "what should a per-message
watch bracket".

## Two numbers from other people's code, and only one of them meant what it said

Both halves of this cycle's SQLite work turned on a fact taken from a
dependency without opening it.

**`pg.Result.number_of_columns` meant what it says.** So the width check for
`db.raw` ([ADR 0134](./adr/0134-a-select-list-shorter-than-the-row-is-refused.md))
was written to ask before pulling a row, which is where a check belongs.

**zqlite's `columnCount` did not.** It is `sqlite3_data_count`, which answers
`0` until the statement has been stepped onto a row — where
`sqlite3_column_count`, the one the name suggests, is settled by preparing. The
check refused eight of the module's own tests on the first run, all of them
generated `INSERT … RETURNING`s against a result set that had not started. The
fix was to ask on the first row, which is the one moment both drivers can
answer and costs nothing to be at: a result set with no rows has no column for
anybody to read past.

It cost one build to find because both Wires are compiled by `zig build
test-sql` ([ADR 0119](./adr/0119-the-sqlite-write-path-is-compiled.md)). Before
that ADR it would have compiled, passed, and been wrong only on SQLite.

**And the second half's stated fix named a mechanism that does not exist.** The
roadmap said honouring `timeout_ms` in the two `take` calls was "the small
half" — but `std.Io.Condition` has `wait` and `waitUncancelable` and **no timed
wait**, so there was nothing small to do. What there was instead sat one layer
down and was already carrying two other modules: `core.Limits`, the Engine's
timer reaching a parked fiber as a cancellation
([ADR 0135](./adr/0135-a-wait-for-a-connection-has-a-bound.md)).

That is the second time a roadmap entry's *mechanism* has been the wrong half
of it while the *gap* stayed true — the first is
[above](#the-mechanism-the-roadmap-named-was-the-one-thing-it-got-wrong), and
the rule it produced applies unchanged: an entry that names a shape should say
whether the shape was tried.

## The page that teaches a thing is the page whose examples fit nothing

Marking `docs/guide/sql.md` for `zig build snippets` took 37 of its 51 blocks
and cost four changes to the machinery, none of which was foreseen from the
eight pages already marked
([ADR 0083](./adr/0083-the-guide-is-the-source-of-its-own-snippets.md)). What
they have in common is the same cause: the shared prelude works for a page that
*uses* a `User` and not for the page that *teaches* one.

The lesson that generalises is about what the marking then found. **Three of
the four findings were in the running example rather than in a snippet.** The
guide's `User` had no `name` column and no `orders` column, and two examples
four screens below it set both. `db.raw` was shown twice with a struct that is
not a Row, which does not compile and never did. And the one real bug —
`.set = .{ .age = 31 }` beside a runtime `id` failing to compile — was reachable
from the most ordinary line on the page.

**A page's examples drift from each other before any single one of them is
wrong**, which is exactly what no reviewer catches: each block reads correctly
on its own screen. Compiling them against one world is what makes the drift a
build failure. This is the same failure mode as
[a number that was stated and never held](#a-number-that-was-stated-and-never-held),
one layer over: a second copy that nothing checks.

## The thread nobody thought about was the one writing

`nilo_cache`'s ring was reasoned through carefully and shipped nothing, because
the reasoning covered the wrong thread. A reader copying bytes out of a ring
checks afterwards that the window still holds the position it copied from; if
it does, nothing can have overwritten those bytes. That is true, and it is
about readers. **A *writer* descheduled inside its own `memcpy` is lapped by
the ring and writes over an entry newer than itself**, and the victim's
position is recent enough to pass every check a reader makes
([ADR 0138](./adr/0138-a-cache-holds-its-bytes-under-a-lock-it-can-spin-on.md)).

Seven wrong values in 1.9 million hits. Two details are the transferable part:

**It only appeared with more threads than cores.** One writer and one reader on
two cores produced zero wrong answers in 34.9 million gets — a run that would
have been read as a pass. A concurrency test that does not oversubscribe the
machine is testing the interleavings the scheduler happened to pick.

**Sharding read like a fix and measured as none.** Sixteen rings gave eight
wrong rather than seven, because the race lives inside one ring. The plausible
mitigation was refuted by the same run that found the bug, which is the only
reason it did not get built.

The other finding came from the compiler rather than the measurement, and no
amount of thinking about layers would have produced it: **Zig 0.16's
`std.Io.Mutex.lock` takes an `io: Io`.** Parking on a futex is a runtime's job,
so a module with no event loop cannot hold a mutex without putting `Io` into
its signature and leaving the layer that
[ADR 0042](./adr/0042-the-bottom-layer-holds-more-than-one-module.md) defines.
What is left is `tryLock` and a spin, which turns a preference into a rule the
module keeps forever: nothing that waits, ever, inside a critical section.

Both were found in an afternoon in [`spike/cache_ring/`](../spike/cache_ring/),
before a module existed to be wrong. That is the argument for spiking the one
part whose answer is unknown rather than the parts that merely have to be
written.

## The cache that used more memory than the thing it was built to beat

`nilo_cache`'s first working version cost **125.8 bytes an entry against
go-cache's 96.9**, which was the opposite of the point of building it. Nothing
was wrong with it. Two roundings were.

**A masked ring has to be a power of two, and a power of two is a rounding a
caller pays for.** A 12 MiB budget became an 8 MiB ring with a third of it
unreachable. Storing an offset and a pass number instead of a
forever-increasing position needs no mask, so the ring is sized exactly — and
it also took the split `memcpy` out of every read and write, because an entry
that will not fit before the end now starts again at the beginning instead of
straddling the seam.

**And a slot is paid for whether or not anything is in it.** Halving it from
sixteen bytes to eight and doubling the ways from four to eight is the same
64-byte cache line touched, half the table, and *better* retention — a key
arriving at a full bucket is what a set-associative table loses, and eight ways
lose far fewer than four. The two together: **63.3 bytes an entry at 99.1%
retrievable**.

The generalisable half is that both roundings were invisible in the code and
obvious in one measurement against somebody else's implementation. Neither
would have been found by reading, and neither showed up in this module's own
numbers — they only appeared next to a competitor's.

## A benchmark can hand the other language a shortcut it has no way to take

The first comparison put go-cache 1.64× ahead on small values. It is 1.3–1.5×.

The Go benchmark looked keys up with the very string objects it had stored, and
Go compares two strings by checking their data pointers before their bytes.
Every probe took that shortcut, so its key comparison cost nothing. The other
side compares bytes out of a ring and has no such path. Giving Go a separate
copy of the same text — `string([]byte(k))`, which is what a key built from a
request actually is — moved the gap by twenty per cent.

**Neither side's source shows this.** It is a property of how the harness got
its keys, and the harness looked symmetrical. Two more of the same shape turned
up in the same afternoon and both also produced *higher* numbers, which is the
direction nobody investigates: a row that measured a cache an earlier row had
emptied, reporting 0% hits at 7.4 million lookups a second, and a warm-up that
filled the cache with the values the row was not going to read.

Written down in [`bench/result/cache.md`](../bench/result/cache.md) with the
rule they produce: **when a benchmark row is faster than expected, find out
why before keeping it.**

## An entry that guesses at its own answer stops anybody taking the number

`service.Registry.get` scans a list on the request path. The roadmap said it
"may well be nothing", named `zig build profile` as exactly the harness for the
question, and then sat at `Waiting on: a number` for a cycle. Adding the row was
an afternoon.

It is 1.2ns an entry, flatly linear. Four services is 4.5ns, 1.6% of a 289ns
request; thirty-two is 38.8ns and 13.4%, the wrong side of ADR 0001's bar. So
the answer was neither of the two the entry could hold: **it is a threshold, and
"it may well be nothing" has no room in it for one.** Five runs agreed within
4%. Nothing hard was ever in the way.

The part worth keeping is why it sat there. A hedge reads as though somebody has
already half-decided, so nobody picks it up to decide it — and unlike a wrong
number, it never gets contradicted by anything, because it never said enough to
be wrong. This is the quiet cousin of the four premises this repository has
already been wrong about: those decayed because nobody re-measured them, and
this one because measuring it had been made to look optional.

Rows in [`bench/result/http.md`](../bench/result/http.md). The rule: **an entry
may state a number or state that nobody has taken one. Guessing at it in the
entry is what stops it being taken.**

## Both optimize modes are one gate and two processes

The live test for `presignPost` failed twice out of two under `zig build test-s3`
and passed both of its own binaries when run by hand. It was not a signature
problem and not a MinIO problem: `test-s3` builds Debug and ReleaseSafe and runs
them **at the same time**, against one server, and both were writing and deleting
`live/posted.txt`. The other binary's cleanup landed between this one's POST and
its read.

Every other test in `s3/live.zig` shares a key across the two and gets away with
it, which is why nobody had met this. The POST is the slow one: a multipart body
through a fresh connection with no pool behind it, and that is enough window.
The key now carries `@tagName(builtin.mode)`.

The rule is about reading the failure rather than about S3. **"Both optimize
modes matter" means two processes, and shared external state is shared between
them.** A test that passes standalone and fails under `zig build` has said which
kind of bug it is, and it is never the one being tested.

## The check that could not run was the one you get by writing `.{}`

`db.checking(&.{ … })` exists so that a Row disagreeing with its table stops a
deploy. On the defaults it stopped nothing: `connect_on_init` is 0, so the pool
reached the check having dialled no connection, `pool.acquire()` answered
`Disconnected`, and startup carried on with a warning
([ADR 0144](./adr/0144-a-check-dials-the-connection-it-needs.md)). Not a race.
Every cold boot, on every program that took the defaults and did everything
else right.

The roadmap already carried "the schema check is opt-in and forgetting it is
silent". This is the other one, and it is worse, because forgetting is at least
something a person did.

**It is the second time in this file that a behaviour survived because its only
evidence was an absence.** ADR 0062 closed on exactly that warning after
`connect_on_init` turned out never to have worked, and named the reason: every
test in the suite has a database, so the *absence* of one is never exercised.
The same sentence covers this one. A check that cannot run and a check that
passes look identical in a log nobody reads and in a green deploy.

The generalisation worth carrying: **an option whose default disables a feature
somewhere else is not visible from either place.** `connect_on_init = 0` is
correct where it is written, `checking` is correct where it is written, and the
interaction between them was in neither file.

## A search that stopped at the filename

A survey of `std.crypto` for RSA looked for `rsa.zig` under `lib/std/crypto/`,
found none, and concluded that RSA is not in the standard library — so RS256
would have to be written from scratch or vendored, and probably refused.

`std.crypto.Certificate.rsa` is public. `PublicKey.fromBytes`,
`PKCS1v1_5Signature.verify` and the DigestInfo prefix table are all there, in
`Certificate.zig`, because that is the code that verifies a TLS certificate
chain. The whole module was a switch over key sizes on top of it.

The person who filed the request had read the file and cited the line. The
survey had grepped the directory listing.

**A public API is not filed where its name says.** When the question is "does
this exist", the answer is in the declarations, not in the filenames — and a
"no" reached by listing a directory is not an answer, it is a search that has
not finished. This is the same shape as the four blockers in this file that had
already gone, and it cost less only because somebody else had done the reading.

## A framework's own output is a spelling somebody hands back

nilo's path param is `:id`. Its generated OpenAPI document prints `/users/{id}`,
because that is what OpenAPI writes. A caller with 203 paths had every one of
them spelled that way, pasted them into route registrations, and got 203 routes
matching five literal characters
([ADR 0147](./adr/0147-a-pattern-written-the-way-the-document-prints-it.md)).

On a route whose handler asked for the param it was already a compile error and
a good one. On a route whose handler did not, there was no error at all, and
the symptom was a 404 on a URL nilo's own document promised.

**Anything the framework emits will come back as input**, from a person copying
it or a tool generating from it. Every such spelling is worth one refusal, and
the message is worth naming where the reader got it from rather than only what
the rule is — "the `{}` form is what the OpenAPI document prints" is the
sentence that stops them thinking they misread the guide.

## The converter was there; one path had never called it

`db.raw` and `db.exec` could not take a `sql.Uuid`. On Postgres that is
`error.QueryFailed` at run time; on SQLite it is a `@compileError` from inside
zqlite. Every statement this module writes takes one without complaint.

The obvious reading is that a raw statement has no Row, so there is nothing to
look the parameter up in. It is wrong. `forWire` switches on the **value's**
type and `WireWrite` takes a Dialect and a bare type — neither has ever
consulted a Row. The conversion a `db.select` parameter goes through was
already available on the raw path
([ADR 0145](./adr/0145-a-raw-parameter-is-converted-the-way-a-rows-is.md)), and
the whole fix is one walk over the tuple.

The same shape, twice more in the same afternoon. `[]const Uuid` did not bind,
because the helper that knew a `Uuid` is a slice inside an array was called
`BatchWrite` and a batch was its only caller — an `.in` list is the identical
problem and nobody looked at a function named after somebody else's feature. And
`dialect.Postgres.accepts` had no case for `uuid[]` at all, so it answered null,
which `schema.Expectation.accepted` reads as *accept anything*: a Row with that
column passed the startup check without anything having looked at the column.

**A gap that looks like a missing feature is worth ten minutes as a missing
call.** All three cost more to report than to fix, and the reason all three
survived is that each one was correct in the file it was written in.

## Nothing was logged, and the sentence saying otherwise was half true

The reference said the server's text for a failed statement is "logged, never
sent". A caller got `error.QueryFailed`, found nothing at any level they could
switch on, found nothing in Postgres's log either, and pasted the same SQL into
`psql`, where it ran.

`translate` logged inside `if (conn.err) |server|`. `conn.err` is set by an
ErrorResponse, so it is null whenever the statement never left the process — a
value pg.zig refuses to bind is the ordinary way there. The `else` arm returned
`error.QueryFailed` and dropped `@errorName(err)` on the floor. The missing word
was `CannotBindStruct`.

So the documented sentence was true on the path with a database behind it and
false on the path without one, and every test in the suite has a database. The
fix is two things and the second is the general one: the server's own words now
ride on `Sent.problem` where a program can read them
([ADR 0146](./adr/0146-a-statement-that-failed-says-what-the-database-said.md)),
and the catch-all arm names the error instead of swallowing it.

**A `switch` arm that turns an error into a coarser one deletes the only
information the failure had**, and the deletion is invisible, because what would
have shown it is a log line nobody wrote. This is the third time in this file
that a behaviour survived because its only evidence was an absence.

## The first thing a new comptime check catches is your own code

Turning on the `SELECT`-list count for `db.raw`
([ADR 0148](./adr/0148-a-raw-statement-is-counted-while-compiling.md)) refused
four call sites in this repository, after the ADR had said none would have to
change. Two were placeholders — `db.raw(Person, c, "SELECT 1", .{})`, written
to make a call compile rather than to mean anything — and two were tests
asserting the behaviour the ADR reverses.

The fifth was a bug in the check, and it was found by a published snippet.
`WITH gone AS (DELETE … RETURNING id) INSERT INTO audit (…) SELECT 'x', id
FROM gone RETURNING ref AS id` has a `SELECT` and a `RETURNING` at depth zero.
The scanner took the first word it found, read the insert's *source* list, and
refused a statement that works. **A check that refuses working code is the one
failure this kind of check cannot have**, and the guide is where the hardest
statement in the repository lives — because the guide is written to show the
hard case.

So the rule to carry: **a comptime check ships with `zig build snippets`, not
after it.** ADR 0083 made the guide compile so it could not drift; the second
thing it buys is a corpus of deliberately awkward real statements, and it is
the only one this repository has.

## Two panics stacked, and the upstream one was on top

A caller reported that nilo panics when it decides *not* to start. The trace
named pg.zig, and it was right: `Reconnector.run` unlocks its mutex inside the
loop and then `return`s while unlocked, so the `defer` at the top unlocks a
second time and xsync's `unreachable` fires. Upstream had fixed it eight days
earlier and the pin was two commits behind
([ADR 0152](./adr/0152-the-panic-under-the-panic.md)).

Bumping the pin did not fix it. It changed it. The same commit moved the
reconnector from `Thread.spawn` to `Io.Group`, so the work became a task on
nilo's own loop — and nilo has no way to stop a service before tearing that
loop down. The panic came back from zio instead, as `task_count == 0`
([ADR 0151](./adr/0151-a-service-is-stopped-before-the-loop-is.md)).

**Reading the trace would have stopped one frame too early.** What found the
second bug was building two throwaway programs — one that refuses to start, one
that boots with the database down and is then stopped normally — and running
both against *both* pins. That is also what found the row nobody reported:
ordinary shutdown panics too, on both pins, whenever the pool never filled.
Which is every deploy where Postgres is down.

`zig build test-all` was green on the new pin while both programs still
panicked. **A dependency bump is not verified by the suite that passes after
it** — the suite has a database and never watches a server refuse to start.

## A sentence with four clauses needs four runs

[ADR 0062](./adr/0062-a-pool-that-dialled-itself-whatever-it-was-told.md)
recorded a server that "boots with the database down, connects when it comes
up, serves 134,967 requests a second at a pool of eight, and shuts down clean."
Three of those were measured. The fourth was written in the same breath and
never exercised, because the run behind the sentence used a database that came
up — so the shutdown it measured was not the shutdown the clause claims.

This is the fifth premise in this file that decayed, and the first that decayed
*inside* a sentence whose other half was solid. The earlier four were whole
claims nobody re-tested. This one had a run behind it, which is what made it
read as safe. **The unit that needs evidence is the clause, not the sentence.**

## A function that decides and announces cannot be tested on the branch that announces

`migrate.expect` refuses to serve a database that is behind the binary. It was
one function: read the ledger, compare, and either return, log `info`, or log
`err` and fail. The test that drove the failing direction could never pass — the
test runner counts one `std.log.err` line as a failed run, and
`std.testing.log_level` has nothing below `err` to turn down to. This repository
already knew that rule and wrote it into `sql/db.zig`. What it did not have is
the fix, which is not "log at `warn` instead":

**Split the decision from the sentence.** `migrate.standing` answers a value —
`.at`, `.want`, and a verdict of `.level`, `.ahead` or `.behind`. `expect` is
that plus the sentence and the refusal. The test drives `standing` for the
behind case and `expect` for the two that pass. The shipped API came out better
than the one being tested around: a program that would rather decide for itself
now can, which nothing had asked for and everything wanted.

The same rule killed a second test in the same file and improved that one too.
"A step that fails takes the ledger row with it" ran `CREATE TABLE "half"` twice
in one version, and the driver logs a refused statement at `err`. Rewritten as a
unique violation, which maps to `error.AlreadyExists` and logs nothing, it now
also proves the *first* step went back — the table is empty afterwards — which
the original never checked.

**A diagnostic that cannot be provoked is a diagnostic that gets deleted rather
than fixed.** The pressure the test runner puts on `std.log.err` is worth
keeping; the thing to reach for when it bites is a value the caller can read,
not a quieter level.

## Eighteen passing tests and three bugs, all found by the first real dependent

`sql/migrations.zig` and `sql/cli.zig` shipped with eighteen tests, green in
both optimize modes. Then a throwaway project in a scratch directory imported
`nilo_sql` the way anybody would — `b.dependency("nilo", .{ .sql = true })`, a
`main` of ten lines, two Rows — and building it found three defects in the first
five minutes:

- **`std.Io.Dir` has no `makeDir`.** `openDir` in the CLI called it. No test
  reached that line, because every test hands the functions a `tmpDir` that is
  already open. A dependent has to make the directory.
- **The generated manifest declared an array, not a slice.** `pub const versions
  = [_]migrate.Version{…}` compiles, and every test that checked the manifest
  text passed. The first caller who wrote `manifest.versions` got a coercion
  error and would have had to write `&manifest.versions` forever.
- **Multi-line SQL printed at column zero.** `writeSteps` did `w.print("    {s}",
  …)`, which indents the first line of a six-line `CREATE TABLE` and leaves the
  other five hard against the margin, where they read as five more steps. Every
  test used a one-line `ALTER TABLE`.

None of the three is subtle, and none was findable from inside the module. They
share a shape: **a test calls a function, a dependent uses it.** The test picks
the argument that is convenient, which is the open directory, the one-line
statement, and the text buffer nobody coerces.

The scratch project cost about fifteen minutes to write and was deleted
afterwards. **Build one before calling a module done**, and drive it the way the
documentation says to — first build, first `generate`, first `migrate`, then
tamper with a version and watch `verify` catch it. Four of the six commands had
never been run in one process against one database until that afternoon.

It also produced a fourth finding that no test would have called a bug:
`status` said `applied` for a version whose file no longer matched what ran.
`verify` reported it correctly, and `status` is the command people type. The row
already carried the hash, so saying `edited` there cost one comparison.

## What a build step matches, and two ways a check can silently not run

`refusals/` holds the wording of 195 error messages, and the whole mechanism
rests on one line of `std.Build.Step.Compile`:

```zig
fn matchCompileError(actual: []const u8, expected: []const u8) bool {
    if (mem.endsWith(u8, actual, expected)) return true;
```

**`endsWith`, not `contains`.** A `.says` that is a *prefix* of the message —
which is the natural thing to write when the rest of the line holds a generated
type name — never matches, and the step fails with "should contain" printed
above an actual that visibly contains it. Two new refusals were written that way
and the mismatch took a probe of the raw compiler output to see, because the
report reads as though the compiler were lying.

So a `.says` is **the whole tail of the first line**, and the message has to be
worth ending there. That is a constraint on the message, not only on the table:
`@typeName` of an `AsText` renders as `types.AsText("numeric"[0..7])`, and a
check whose text ends in a compiler rendering detail breaks the day the
rendering changes. Both messages were rewritten to name the *column* type —
`` a `numeric` column read as text `` — which is stabler and reads better
anyway.

The neighbouring way to have a check that never runs is already in
`CLAUDE.md`: six tables, six steps, and a row added to one while another is run.
Both failures look like a passing suite.

## A comptime budget belongs to whoever spends it

Sixteen `named` routes on one group stopped compiling with `evaluation exceeded
1000 backwards branches` pointing into `app.zig`. Before fixing it, two things
about `@setEvalBranchQuota` were worth measuring rather than assuming, because
the fix is wrong under either alternative:

- **it reaches the caller.** A comptime call is analysed inside the caller's
  evaluation, so a quota raised inside a framework function raises the budget
  the caller's whole `register` is spending;
- **a smaller value later does not lower it.** The compiler keeps the larger, so
  a library raising a ceiling cannot undo a caller who raised it higher.

Both were confirmed with a ten-line program before the change was written. What
follows from them is that a per-call *exact* size is the wrong shape: the budget
is one ceiling for an entire evaluation, so a formula sized from one route's
name is right for the first route and short by the two hundredth. Raise
generously ([ADR 0157](./adr/0157-a-check-pays-for-its-own-branches.md)).

The same evaluation then found two more places spending a caller's budget
without paying for it — `row.readSpec`, which compares every marker field
against six allowed words for every Row in a schema, and `rawcheck.assertList`.
Neither had been reachable before because no program had had enough Rows.

## Eleven items from a port, and what the shape of the list said

A backend port on 0.3.0 — two contexts, 29 endpoints, 84 tests against a real
database — handed back eleven items in one file, each with the error copied from
a build log rather than paraphrased. The distribution is the part worth keeping:

- **one was wrong at run time and silent** — a `date` read through `db.raw` came
  back as the four bytes of its wire format and nothing failed
  ([ADR 0154](./adr/0154-a-raw-statement-cannot-cast-what-it-did-not-write.md)).
  It cost them an afternoon of suspecting the driver.
- **three were a mechanism stopping one clause short.** `convertible` did not
  reach the `parsesItself` branch `tryConvert` already had; `forWire` had a
  `Str` scalar and a `Uuid` list and no `Str` list; `checkName` never raised the
  quota `row.zig`'s `distance` has always raised. In each, the work existed and
  the last clause did not.
- **two were a rule written as its mechanism.** "A `nilo_parse` makes a type a
  path param, and a path param does not come through here" is a true sentence
  about a call graph, and it reads as a decision. Stated as what the caller sees
  — *the same text off the same request line means two things* — there is
  nothing left to decide
  ([ADR 0158](./adr/0158-one-arrival-one-answer.md)). This is the third time a
  requirement phrased as a mechanism read as a blocker; ADR 0063 is the first.

**Nothing in the list needed a design nobody had.** The expensive part was not
the building; it was that a caller had to find each one by hitting it. The one
that cost the most — the silent `date` — is also the one nothing in the
repository could have found, because every test that reads a text column reads
it through a statement nilo wrote.

## The sentence a reader hits first is the one that has to change

The same port came back a week later having actually used the eleven, and two
of its findings were about this repository's own pages rather than its code.
The one worth keeping: `docs/reference.md` still said *this is for a path param;
a `Query(T)` or `Form(T)` field is still a `Str`, a number, a `bool` or an
enum* — the exact thing [ADR 0158](./adr/0158-one-arrival-one-answer.md) had
just made false. The correct sentence was a hundred lines below it, in the
section about list fields, which is what made the stale one read as deliberate
rather than as a leftover.

**A feature that widens what a type may be has to go and delete the sentence
that said it may not**, and the place to look is above where the new sentence
went — a reader meets the restriction before they meet the capability, and a
reader who believes the restriction writes the workaround and never comes back.
This one would have cost the next port a `uuidOf` helper for the second time.

The other finding needed no change at all: `Str.static` was already in the
reference, one row of one table, and the port did not find it while building a
`[]const Str` and reached for a Scope per element instead. A declaration is
findable from where somebody is standing when they need it, not from where it
belongs.

**Both had the same cause, and the port named it better than this file had.** It
did not merely find another way — it *wrote* one, and `uuidOf` and `commaList`
passed their tests and read sensibly, so nothing ever pulled it back to the
page. **A workaround that has been written is a reason never to ask again**,
which is why a gap survives long after it stops being one and why the eleven
arrived together rather than as they were hit. The practical form is the port's
own and belongs to both sides of this: report the thing nilo cannot spell
*before* writing the patch for it, not after.

## An artefact somebody else builds against cannot need the thing running

The same port hit its first hard seam — an event bus — and the item it filed as
the largest was not about Zig at all. nilo's OpenAPI document is a good one, and
it existed in exactly one place: `GET /openapi.json`, on a server that is
listening. Their frontend generates a typed client from a **checked-in** file,
and the diff of that file in review is how somebody sees a breaking change
before it ships.

Producing it meant booting, and booting runs `db.checking`. **So a file
describing a set of types required a migrated database.** Nothing was missing to
fix it: `openapi.write` was already public and `App` already collected the
operations at registration. What was missing was a door, and the reason nobody
had noticed is that the framework's own use of the document — read it in a
browser — is satisfied by the server that serves it
([ADR 0167](./adr/0167-the-document-is-a-build-artefact.md)).

**Ask where an output has to be readable from, not just whether it can be
produced.** A thing other people build against has to be producible by a build,
which means without a port, a database or a network — and a feature that is only
reachable from a running server has quietly picked one answer to that.

The same round found the two shapes that come of Zig having no closures. A
callback is a function pointer, so it cannot be generic over the Scope it is
handed, so the caller type-erases the Scope into a vtable — and then `entropy`,
which answers `![n]u8`, cannot go in it, because a function pointer names one
return type ([ADR 0166](./adr/0166-entropy-a-function-pointer-can-carry.md)).
`core/scope.zig` says a vtable was rejected "to buy a polymorphism nobody has
asked for". Somebody asked within a fortnight of the first caller arriving. The
decision stands; what changed is that nilo's own API is no longer the reason
they cannot build one.

## An escape hatch that costs nothing teaches nothing

The most expensive thing a port found had no error message behind it. Five
times, in three contexts, it wrote the untyped call while a typed one existed —
`db.exec`, `db.count`, `Str.static`, `Ctx.resolve`, `db.select` — and all five
compiled, passed their tests, and would have shipped. The last redeclared a
subset of a Row that was eleven lines up in the same import.

**A compile check was designed and then counted against the five, and caught
one.** Three of the five are not SQL at all, which is the finding: the pattern
runs on the whole public surface and is not about `db.raw`. Two things then
decided it, and the first is the one worth keeping — **a check that lands makes
the problem look solved**. Instance six through `db.raw` would be caught,
instances seven to ten elsewhere would not, and nobody would look, because there
is a check now. For a pattern that cuts across modules, a narrow check is worse
than none. The account is
[ADR 0168](./adr/0168-an-escape-hatch-that-costs-nothing-teaches-nothing.md).

Two more general things came out of the same round.

**A decision that makes a wrong shape cheaper is a cost of that decision.**
[ADR 0155](./adr/0155-a-row-that-owns-no-table.md) is right and it made
declaring a throwaway projection inexpensive *and blessed by the compiler*. The
port's wrong shape compiled and had its columns checked. Ask what a new
affordance makes easier that nobody wanted.

**"The layer below cannot fix it" is not "nobody can".** The port nearly did not
file the unreadable test output at all, because `std.testing` prints with
`{any}` and `{any}` skips custom formatters by design — two true facts and a
conclusion that does not follow. `nilo.testing` sits one layer up and had the
rendering already
([ADR 0169](./adr/0169-a-failed-assertion-that-can-be-read.md)).

The first shape built for it was an `expectEqual`, and the caller it was built
for argued it down before it shipped. **An assertion helper pulls the whole
assertion surface behind it** — once `nilo.testing.expectEqual` exists,
`expectEqualDeep`, `expectEqualSlices` and `expectError` are all asked for, each
missing one reads as a gap, and each present one has to follow `std.testing`
for ever. The deciding argument was smaller and better: the failure actually
reported was an `expectError` finding a payload, which an equality helper cannot
help with at all. **Check the fix against the instance that was reported, not
against the category it was filed under.**

## A workaround needs a test for the reason it exists

`nilo.testing.show` exists because `std.testing` prints with `{any}` and `{any}`
skips a type's own formatter. Its first test asserted that `show` renders
readably, which is the obvious half and is not enough: if `{any}` ever started
honouring custom formatters, `show` would become dead weight with **every test
still green** — nothing failing, just nothing left to justify it.

So the test asserts both sides. That `show` calls the type's rendering, and that
`{any}` prints `"wati"` as `119, 97, 116, 105`. The second is what makes the
first worth having, and it is the half that is usually missing.

**Any code that exists to work around something else needs a test for the
something else.** Otherwise the day it stops being true is silent, and the
workaround outlives its reason — which in a repository whose rule is that
nothing load-bearing may live only in somebody's head is the same failure in a
different costume.

**And the two halves have to be bound, not merely both present.** The port
checked its own code against this rule and found the interesting case: it had
both sides, 580 lines apart in one file, with nothing tying them. Delete or
narrow the half that proves the behaviour still matters and the half that
asserts its absence stays green, pointing at nothing. `show`'s test is stronger
only because both halves sit in one test, which was convenience rather than
judgement. Put them in one test where the shape allows it, and where it does not,
have each name the other — a pair nothing references is a pair that decays into
one.

The same round's other lesson is smaller and came from the same test failing
first: it named `Uuid`, which `http/` may not import (ADR 0042). The fix was not
a different import. **A test should hold the property, not an instance of it** —
a local type with a `jsonStringify` of its own holds "a value that knows how to
write itself gets to", where the `Uuid` version would have stayed green while
the property broke for every other type.

## The slow build had an explanation on file, and it was the wrong one

`zig build test` took 30.6s after one edit under `http/`. CLAUDE.md had said since
16 August that **the refusals are the slow part**, and that sentence is why
nobody looked: it is true for a run that changes nothing, where the refusals are
2.6s of a 2.9s floor, and it is false for the run anybody actually does. On the
edit run the refusals were 15.9s of CPU spread over sixteen cores, and one
`ReleaseSafe` compile was thirty seconds on its own.

**110s of CPU finishing in 30.6s of wall on sixteen cores is the whole
diagnosis, and it takes one command.** A perfectly parallel build would have
been seven seconds. It was not, so something big ran alone, and a single
compilation is the one thing in a build that cannot be split. `--time-report`
then said 25.977s of that compilation's 27.614s was LLVM Emit, 94.1%, against a
`Debug` build of the same root that has no such phase at all
([ADR 0170](./adr/0170-a-test-does-not-need-the-optimiser.md)).

The repository had already been near this twice. `stripMeasured` records that
LLVM is the cost of a release build and reaches for debug info, which is half of
it. ADR 0041 sells ten modules and a layering step, and one of them still pulls
712 files into a single compilation, because LLVM has no crate boundary to stop
at. **Neither note was wrong. Both answered a question nobody had timed.**

Two habits came out of it. **Compare CPU against wall before believing any
theory about a slow build**, because the ratio names the shape of the problem
before you know anything else. And **`--time-report` stands up a web server and
waits**, so from a terminal it is ten minutes of elapsed time against one second
of CPU, which is the deadlock signature this file already documents. That
procedure has now caught three things, and the third was not a deadlock.

**Then the interleaving rule was broken within the hour by the person writing it
down.** `--watch` looked like a 2s saving, from two un-interleaved runs against
a remembered number. Interleaved, alternating one fresh run with one watch
rebuild, it lost all three rounds, and the fresh column alone spanned 5.7s. The
honest answer is no measurable difference. **A margin you found without
interleaving is not a small result, it is not a result**, and knowing the rule
is plainly no protection against skipping it when a number is the one you
wanted.

## Two blockers that were sentences about one implementation

Both of these sat under **Waiting on: a design** for a cycle, and neither design
question was real. The pattern is the one
[ADR 0063](./adr/0063-a-handlers-stack-is-per-connection.md) already named — a
requirement written as one mechanism reads as a blocker, and written as what it
has to catch it reads as a choice — and this is the second and third time it has
cost something.

**`contains` was blocked on an allocation it did not have to make.** The roadmap
said the fix meant *an allocation per condition in a module whose whole claim is
that a statement costs none*, which is true of building the pattern in the
request arena and is not true of the feature. Put the three `replace` calls and
the `ESCAPE` inside the statement and the database escapes the text it is about
to match: what binds is the caller's own bytes, and the cost is zero
([ADR 0173](./adr/0173-the-database-escapes-the-pattern-it-is-going-to-match.md)).
The unescaped `like` it replaces had been shipping a wrong answer on every
search term containing `%` or `_`, silently, the whole time.

**The binary column was blocked on a second protocol it did not need.** The
sentence was *the `nilo_column` protocol is text on the wire by definition, so
bytes want a second protocol beside it* — and both halves are true. The
conclusion is not, because that protocol exists for a column type this module
has never heard of, declared by whoever owns it. There is one binary column,
both databases have it, and it is one more type the two Wires know by name the
way `Uuid` already is
([ADR 0174](./adr/0174-bytes-are-a-type-not-a-second-protocol.md)).

**What to take from both: read a blocker as a sentence about a mechanism and
ask what it would say about the requirement.** "An allocation per condition" is
about arenas; "the `%` in the caller's text has to match itself" is about the
requirement, and the second one has an answer the first hides.

## An operator family arriving without its negations breaks a decision on file

[ADR 0058](./adr/0058-a-set-operation-over-one-table-is-a-condition.md) argues
that `EXCEPT` needs no mechanism because **every leaf has a negation** and the
algebra is therefore closed. Adding `contains`, `starts_with` and `ends_with`
without `not_contains` and its siblings would have made that false, quietly, in
a file nobody would re-read. Twelve names came out of a three-row table for that
reason, and there is now a test that walks all twelve.

**A closure argument is a claim about a set that keeps growing**, which makes it
the kind of documented property that decays without a test under it. The same
went for `.exists`: it nests inside `.any`, and there is a test saying so,
because a leaf that cannot go inside `.any` is a leaf the OR half cannot reach.

## The composite key had a hole in a statement nobody would have looked at

`upserting` left the Row's key out of the `DO UPDATE SET` list — *the* key,
singular. On a Row keyed by two columns that meant the second one was being
written to the value it had just been matched on. It is a no-op in the ordinary
case and it is a column in the SET list that can never change reading as though
it might, which is the exact footgun the surrounding comment already warned
about for the conflict target.

**A rule stated for one column does not survive the column becoming a list**,
and the places to check are the ones that said "the key" and meant it.

