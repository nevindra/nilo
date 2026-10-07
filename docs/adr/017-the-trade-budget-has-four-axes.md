# The trade budget has four axes, and only one of them is 10%

**Status:** accepted
**Topic:** [principles](../design/principles.md)

## Context

v1's rule was one threshold for everything: **the comfort of writing code wins, unless it costs more than 10%.** That got v1 built and none of it is being taken back, but "performance" turned out to be four different numbers that do not recover the same way, so a single percentage cannot hold all of them. `docs/history.md`'s metrics section had already separated them in practice; this ADR turns that separation into the rule.

## Decision

**Performance is four numbers, and each is held the way its own recovery cost demands.**

| Axis | Rule | Where it is held |
|---|---|---|
| **Throughput and p99** | A nicer API wins if it costs under 10% | Measured against a real machine: [HttpArena](https://www.http-arena.com/frameworks/nilo/)'s independent board, and `bench/`'s own scripts pinned to physical cores |
| **Allocations per request** | Hard invariant. A DX feature may not add one to a path that did not ask for it | A test: *the request path stays inside its allocation budget* |
| **Memory per idle connection** | Hard invariant, and **4,669 bytes** as of [ADR 062](./062-where-a-connection-waits-is-what-it-costs.md). Every new feature states its cost or has none. **A floor, not a total**: a handler adds every byte of stack it touches ([ADR 062](./062-where-a-connection-waits-is-what-it-costs.md)) | Measured out to 10,000 held-open connections, because a reading whose marginal and average still disagree is a transient |
| **Binary size** | A feature the linker cannot drop states its unconditional cost, as a measured number against a stripped `ReleaseFast` build, in the running total below. No feature may cost unconditional *request-path* or *per-connection* size; those two stay absent, not merely small | The running total, this ADR |

### Why they do not recover the same way

**Throughput is elastic.** Ten percent off 140k requests per second is not something the audience, people living at 30 to 80k today on Go or Node, will ever feel: it disappears into the first database query. That is the whole of the 10% argument, and it still holds; what changed is that a real machine now exists to measure it against, rather than the reasoning standing alone.

**Allocations are not elastic, because they are what p99 is made of.** An allocation added to the request path is not 10% slower on average; it is fine a million times and then it is a `mmap`, and that one request is the tail. The way to keep p99 flat is to allocate at startup and then stop ([ADR 014](./014-what-nilo-borrows-and-from-whom.md)).

**Memory per connection is not elastic either, because it decides what the server can hold.** At 8,767 bytes a hundred thousand idle keep-alive connections was 877 MB; at 4,669 it is 467 MB, and the whole of that difference was where the connection was suspended rather than what it held ([ADR 062](./062-where-a-connection-waits-is-what-it-costs.md)). A feature that adds 4 KB to `Ctx` does not make anything slower; it makes the same box hold a fifth fewer connections, and nobody notices until the box is full. So the rule is not a percentage, it is a disclosure: a feature that costs per-connection memory says how much, in the ADR that introduces it.

**Binary size is nginx's discipline, honoured only partway.** nginx compiles a module in or leaves it absent; nilo cannot always do that, because a feature reachable only behind a runtime `null` check is invisible to the linker even when nothing calls it. The measuring is not pedantry: a reported +14 KB for the API description was first read as +43 KB, and the difference was one extra instantiation of `std.sort.block` the feature made reachable, 37 KB for sorting two files. The number a feature costs in Zig is rarely the code that was written for it; it is whichever generic got woken up.

**What "low memory" is allowed to mean.** nilo can say it honestly only because of the two hard invariants above; they are the claim, and throughput is the headline. Trading an allocation to win a throughput benchmark would be spending the thing that is actually true to improve the thing that recovers on its own.

### The running total

Measured stripped, `ReleaseFast`, on the examples in this repository.

| Change | hello | rest |
|---|---|---|
| The API description ([ADR 016](./016-the-api-description-comes-from-the-signatures.md)) | +14 KB | +34 KB |
| JSON failure bodies, `Status`, `?T` → 404, nested body messages, `components`, `Patch` ([ADRs 023](./023-a-failure-mode-belongs-in-the-return-type.md)–[025](./025-a-patch-needs-three-answers-and-an-optional-has-two.md)) | +6 KB | +14 KB |
| Names for generic shapes, an honest answer for a handler that writes its own, and the enum wording | +3.3 KB | +3.2 KB |
| Holding the rule about error messages ([ADR 026](./026-the-rule-about-error-messages-is-held-by-a-build-step.md)) | +0 | +0 |
| Core as a module of its own, and a Scope in place of a `Ctx` ([ADR 038](./038-a-module-sits-where-the-loop-puts-it.md)) | +0 | +0 |
| A second module in the bottom layer, `nilo_id` ([ADR 038](./038-a-module-sits-where-the-loop-puts-it.md)) | +0 | +0 |
| A third, `nilo_config` ([ADR 039](./039-a-setting-is-a-field-and-every-bad-one-is-named-at-once.md)) | +0 | +0 |
| A clock in Core and entropy on the `Ctx` ([ADR 041](./041-core-knows-what-time-it-is.md), [ADR 042](./042-entropy-belongs-to-the-loop.md)) | +0 | +0 |
| One pass through a WebSocket message, and a broadcast framed once ([ADR 046](./046-a-message-is-copied-once-and-framed-once.md)) | +0 | +0 |
| Everything `nilo_sql` gained in this cycle — `Decimal`, `ON CONFLICT`, `tx.deadline`, array columns, `insertMany` ([ADRs 043](./043-a-deadline-needs-a-connection-you-hold.md), [045](./045-an-array-is-a-slice-and-a-slice-is-one-deep.md), [047](./047-a-batch-is-one-array-per-column.md), [049](./049-a-column-type-can-come-from-outside-this-module.md)) | +0 | +0 |
| Isolation levels, row locks and savepoints ([ADR 048](./048-contention-is-what-a-transaction-is-for.md)) | +0 | +0 |
| A column type declared outside this module ([ADR 049](./049-a-column-type-can-come-from-outside-this-module.md)) | +0 | +0 |
| Reading a view, and a nullability the database does not know ([ADR 050](./050-a-view-or-a-rowid-alias-is-not-a-nullable-column.md)) | +0 | +0 |
| A statement kept prepared on the connection it went down ([ADR 051](./051-a-statement-that-is-a-constant-can-be-prepared-once.md)) | +0 | +0 |
| Set operations, CTEs and pipelining, all refused ([ADRs 052](./052-a-set-operation-over-one-table-is-a-condition.md)–[053](./053-a-round-trip-is-not-the-cost-worth-chasing.md)) | +0 | +0 |
| A second database as a second type ([ADR 054](./054-a-second-database-is-a-second-type.md)) | +0 | +0 |
| A second Dialect, SQL half only ([ADR 055](./055-the-second-dialect-is-the-test-of-the-seam.md)) | +0 | +0 |
| Parsing the database URL rather than letting a driver drop half the options ([ADR 115](./115-a-boot-dials-the-connection-its-work-needs.md)) | +0 | +0 |
| Four routes in a benchmark, to find out what the memory axis actually measures ([ADR 062](./062-where-a-connection-waits-is-what-it-costs.md)) | +0 | +0 |
| An outbound HTTP client, `nilo_fetch` ([ADR 061](./061-a-fitting-borrows-the-loop.md)) | +0 | +0 |
| Waiting at the connection loop's frame, and a WebSocket loop handed back to it ([ADR 062](./062-where-a-connection-waits-is-what-it-costs.md)) | +1,240 B | +1,336 B |
| An object store as a Service, `nilo_s3` ([ADRs 058](./058-most-of-an-s3-client-is-not-s3.md)–[063](./063-an-object-store-is-a-service-that-dials.md)) | +0 | +0 |
| Twenty findings from an application, closed together ([ADRs 066](./066-a-lazy-dependency-is-a-request.md)–[069](./069-a-library-can-tell-what-mode-the-program-was-built-in.md)) | +11,400 B | +17,272 B |
| Counters ([ADR 079](./079-the-route-table-is-the-registry.md)) | +1,984 B | +1,984 B |
| An allowance ([ADR 092](./092-an-allowance-is-a-table-sized-while-compiling.md)) | +0 | +0 |
| A body limit per route, a type that writes its own answer, a request id on the way out, and a server that sheds past its limit ([ADRs 156](./156-a-route-can-say-how-much-body-it-takes.md)–[159](./159-a-server-past-its-limit-says-so-at-once.md)) | +896 B | +944 B |
| A `Date` on every response, and no `Connection: keep-alive` on HTTP/1.1 ([ADR 197](./197-a-response-says-when-it-was-sent.md)) | +6,064 B | +6,072 B |
| A failure body the application names ([ADR 024](./024-every-failure-answers-as-json.md)) | +400 B | +448 B |
| Response compression on a pooled compressor ([ADR 211](./211-a-response-is-compressed-on-a-compressor-borrowed-from-a-pool.md)), and the `Accept-Encoding` reader no longer waking `parseFloat` | +4,896 B, then −24,608 B net | +4,064 B, then −3,648 B net |
| A TLS listener the build has to ask for ([ADR 212](./212-tls-is-an-option-a-build-asks-for.md)); the build that asks pays +573,152 B and +574,320 B on top | +2,872 B | +2,720 B |
| A server answering on more than one address ([ADR 213](./213-a-server-answers-on-more-than-one-address.md)); the `-Dtls` build pays +1,872 B, where a listener's certificate is real | +256 B | +256 B |
| An RSA key signed through its CRT form, in the pinned tls.zig ([the run](../../bench/result/http.md#what-an-rsa-certificate-costs-a-handshake)); the `-Dtls` build pays +26,768 B and +26,832 B, a second `ff.Modulus` instantiation | +0 | +0 |
| Unary gRPC over h2c, and over TLS by ALPN, on a listener the build has to ask for ([ADR 220](./220-grpc-is-served-over-h2c-behind-a-flag.md)); the `-Dhttp2` build pays +115,720 B and +52,432 B on top | +8 B | +112 B |
| A route table searched as a tree rather than scanned ([ADR 012](./012-the-most-specific-route-wins-and-duplicates-are-refused.md)); measured with the CSRF middleware of [ADR 224](./224-a-request-that-changes-something-says-where-it-came-from.md) in the same tree, which neither example names | +1,616 B | +1,408 B |
| Fallback session secrets, checked at `listen()` ([ADR 225](./225-a-fallback-session-secret-opens-and-never-seals.md)) | +624 B | +592 B |
| A socket in any number of Rooms ([ADR 035](./035-a-broadcast-rings-a-bell-it-does-not-write.md)), and an event stream fed by Rooms handed to the connection ([ADR 227](./227-an-event-stream-fed-by-rooms-waits-where-a-connection-waits.md)); called directly rather than through a pointer, the stream's loop was +6,720 B on both | +656 B | +656 B |
| Rooms lent to a key from a pool ([ADR 228](./228-a-room-for-a-key-is-lent-from-a-pool.md)), and a Room that keeps history for a stream coming back ([ADR 229](./229-a-room-that-keeps-history-catches-a-returning-stream-up.md)); `chat`, which has a Room, pays +1,056 B | +80 B | +80 B |
| A thread count read from a container's CPU quota, held to the engine's 64 ([ADR 230](./230-a-cpu-quota-sets-the-thread-count.md)); read once at startup, nothing on the request path | +5,680 B | +5,200 B |
| Every byte of a head checked for a control or a bare CR, every method and name for a token, every target for a form ([ADR 070](./070-a-request-nobody-else-would-answer-is-refused.md), [ADR 095](./095-a-target-is-read-in-the-form-it-arrived-in.md)) | +4,176 B | +4,144 B |
| zio from v0.18.0 to `0299e57` on its `main`, built pinned ([ADR 199](./199-a-connection-is-served-by-the-thread-it-was-dealt-to.md)); zio's own code, and `spawnLocal` ([ADR 220](./220-grpc-is-served-over-h2c-behind-a-flag.md)) is +0 on both because only a `-Dhttp2` build calls it | +6,888 B | +6,904 B |
| A raw statement held against its Row the first time it runs ([ADR 233](./233-a-raw-statement-is-held-against-its-row-the-first-time-it-runs.md)); neither example has a raw statement. A program whose one route is a `db.raw` pays +30,864 B on Postgres and +10,816 B on SQLite, and +368 B for each statement after the first | +0 | +0 |
| A request serial in every build, so `sql.problem` can tell one request on a connection from the next ([ADR 117](./117-a-statement-that-failed-says-what-the-database-said.md)) | +24 B | +24 B |
| Floats written the way serde_json writes them ([ADR 096](./096-a-byte-that-is-not-text-is-not-a-string.md)); neither example writes a float, so both are byte-identical. A program that writes one is **8,864 B smaller**: `hello` with an `f64` and an `f32` field, 1,029,584 → 1,020,720, because the decimal printer `print("{}")` brought is no longer linked | +0 | +0 |
| Security headers as one block ([ADR 246](./246-the-headers-a-browser-reads-as-policy-are-one-block.md)) and tracing ([ADR 247](./247-a-request-is-a-span-and-the-trace-leaves-as-otlp.md)), each behind a pointer only its own call sets | +432 B | +384 B |
| gzip through libdeflate in a build that asks ([ADR 248](./248-gzip-is-libdeflate-when-a-build-asks-for-it.md)), and a static file gzipped through the same backend; the `-Dlibdeflate` build pays +41,696 B and +42,104 B on top, libdeflate less the `std.flate` compressor that leaves | +0 | +0 |
| A JSON body type that answers its wrong shape with a 422 ([ADR 251](./251-json-that-does-not-fit-can-be-a-422.md)); neither example marks a type, and what both pay is the document writer's branch and the one sentence it adds to the Idempotency-Key 422, the three descriptions sliced from one string. A runtime body limit ([ADR 156](./156-a-route-can-say-how-much-body-it-takes.md)), the test directory ([ADR 250](./250-a-test-directory-hands-back-its-path.md)) and SQLite compiled `ReleaseFast` ([ADR 249](./249-sqlite-is-compiled-releasefast-whatever-the-program-is.md)) are +0 on both | +144 B | +144 B |
| A request that knows its listener, and a route bound to listeners ([ADR 252](./252-a-request-knows-which-listener-it-came-in-on.md)); one byte on `Peer`, a bit test in the dispatch and a second `allowedFor` entry | +448 B | +448 B |
| A gRPC call collected under its route's `maxBody` ([ADR 156](./156-a-route-can-say-how-much-body-it-takes.md), [ADR 220](./220-grpc-is-served-over-h2c-behind-a-flag.md)); neither example uses gRPC or `maxBody`, and what both pay is the registration noting a `Limited` and the gRPC host's two new fields, measured on that change alone against `689b034` | +144 B | +176 B |
| A body read as what its type says, protobuf or a type's own ([ADR 256](./256-a-body-is-read-as-what-its-type-says.md)); neither example has a message, and what both pay is the API document's content types kept as lists decided while compiling, measured against `40e9f45`. Nothing on the request path | +64 B | −48 B |
| A Connect call's failure in Connect's shape ([ADR 257](./257-a-connect-client-is-told-its-failure-in-connect-words.md)); neither example has a message route, and what both pay is the choice on the failure path, a null check and a call, measured against ADR 256's tree. A program with one pays about 1.7 KB more | +96 B | +96 B |
| A struct of typed functions served as an RPC service ([ADR 258](./258-a-struct-of-typed-functions-is-an-rpc-service.md)); worked out while compiling and handed to `post`, so a program that does not call `app.rpc` is byte-identical | 0 B | 0 B |

`nilo_fetch` is +0 on both examples because neither imports it, and that is the whole of the row rather than an accident: a module nothing names is never analysed, so the linker has nothing to drop. Measured on a program that *does* import it, against the same program calling `std.http.Client` itself, it is **+1,688 bytes**; `std.http.Client` and the TLS stack under it are the other 655,600, the price of dialling out in Zig rather than of this module ([`bench/result/fetch.md`](../../bench/result/fetch.md)).

`nilo_s3` is +0 for the same reason and measured the same way: two servers with one route each, differing only in where the bytes come from (`bench/size/s3_none.zig` against `bench/size/s3_get.zig`), 1,007,496 bytes against 1,716,072, so **object storage costs +708,576**, 692 KB and 1.70×. `std.http.Client` and TLS are 655,600 of that by `fetch.md`'s own split and `nilo_fetch` is 1,688, leaving roughly 51 KB that is SigV4, the bucket and the rest of `nilo_s3`. That a program storing nothing pays none of it is checked, not assumed: `strings` finds zero occurrences of `aws4`, `x-amz` or `s3` in the control.

The counters row is the same figure on both examples, and on `bench/main.zig` as well, because neither example calls `app.metrics`: what they pay is the `Record` on `serveRequest`'s frame and the `observe` it can reach, which the linker cannot drop because the call is behind a runtime `null` check rather than a comptime one. An application that *does* call it pays **17,416 more**, measured as two builds of `bench/main.zig` differing by one line ([`bench/result/http.md`](../../bench/result/http.md)).

The failure-body row is one measurement of six changes landed together, which is a worse record than most and is noted as such: `hello` has one route returning text and pays +6 KB, the failure-body writer and nothing else, unconditional; the remaining +8 KB on `rest` is the body describer and the schema walker, generated per body type and so paid only by applications that have bodies.

The names-for-generic-shapes row is nearly the same on both, which says what it is: the name renderer and the extra descriptions live in the document writer, which is linked in whether or not `docs()` is called, the same unconditional cost the API-description row is about.

The ADR 062 row is the only one here that is a cost bought deliberately: cold paths that used to be inlined copies are now real functions, which is what makes the connection loop's frame small enough to fit in a page. `hello` has no WebSocket route and pays all 1,240 bytes of it; the spread across all eight examples is 1,240 to 2,480 bytes, the top of it `chat`, the one example that opens a socket and so also links the handover.

The allowance row is a zero checked by *removing* the feature: `pub const allowance` was taken out of `http/http.zig` and both examples rebuilt byte-for-byte identical, because Zig never analyses a `pub` namespace nothing references. An application that does call it pays **+7,200 bytes** on `hello` and **+7,088** on `rest`, not counting the table itself: 131,072 bytes of `.bss`, `NOBITS` in the ELF, so 128 KiB of RSS and nothing on disk.

The twenty-findings row is the worst-recorded one here, written down as such: ten ADRs in one figure, because they landed as one pass over a list somebody else wrote. `hello` 881,296 → 892,696 and `rest` 1,014,736 → 1,032,008, both `-Doptimize=ReleaseFast -Dstrip=true`. On `hello` the split is `.text` +8,128, `.data.rel.ro` +2,632 and `.rodata` +567, so it is code rather than message strings, what an unconditional cost looks like; nothing here was attributed further, and a later change to any one of the ten should re-measure rather than subtract from this. The same pass costs +16,880 bytes on `bench/size/pg_only.zig` and +15,392 on `sqlite_only.zig`, which moves the published difference between them, what SQLite costs a program that uses it, from 524,840 to **523,352**: a number quoted in four places and reproduced exactly twice is a different number now ([`bench/result/sql.md`](../../bench/result/sql.md)).

The compression row is two numbers on purpose: the feature (`Ctx.squeezed`, the eligibility check, the type allowlist, the pool's `gzip`, kept by the linker because the switch is a runtime null on the `Ctx`) and what the same change took out (the `Accept-Encoding` reader's `std.fmt.parseFloat(f32, …)`, 25 KB of machine code in a binary that parses no other float and 3.7 KB in one that does), the generic-you-woke-up lesson met in the other direction ([`bench/result/http.md`](../../bench/result/http.md)).

`nilo_sql` is +0 for a reason worth stating rather than glossing: no example in this repository imports the module, so none of the seven links a byte of it, not the driver, not its four transitive dependencies ([ADR 037](./037-a-service-that-needs-the-loop-is-finished-when-the-loop-exists.md)'s property observed rather than argued). What the module's own additions cost is paid by a project that imports it, and each is instantiated per Row and per call site: a service that never reads an array column links no `readList`, one that never batches links no `unnest` statement.

The body-limit row is one figure for the same reason the twenty-findings row is, and is almost all one change: `hello` 922,840 → 923,736, `.text` +608, `.rodata` +271 and `.data.rel.ro` +32, the 503 a shed request is answered with, the comparison in front of it, and the fifth fixed slot in the metrics table, none of which the linker can drop because `serve.zig` always names them. `outbound`, the one example that imports `nilo_fetch`, is +2,416: the same ~900 plus `.text` +1,456 for the header merge in [ADR 158](./158-a-request-id-goes-out-with-the-call.md).

The security-header and tracing row is small because of how it was built, not because there is little behind it. The first build called the tracer behind a runtime null check, the way the counters row does, and every program paid 12,032 bytes on `hello` for ids, a header walk, a ring and a URL parse it never ran. Moved behind pointers that only `app.trace` and `Ctx.putPolicy` set, the code is reached only from calls a program that does not trace never makes, and what stays is the null checks and `writeExtra`. `outbound`, which calls through `nilo_fetch`, pays +3,024 for the `traceparent` header it would send. A program that traces pays **+690,224** (`nilo-size-trace_on` against `nilo-size-s3_none`, `zig build size-trace size-s3`), nearly all of it `std.http.Client` and TLS under the exporter ([ADR 247](./247-a-request-is-a-span-and-the-trace-leaves-as-otlp.md)).

`orders`, the largest example, is 1,327,992 bytes stripped, byte-identical across measurements; it carries no row here because it has no before.

## What was rejected

**One 10% threshold for every kind of performance**, v1's rule and the position this ADR narrows rather than discards. It held for throughput because throughput is elastic; applied to allocations it would have let a 9%-slower path through on a benchmark that came out level while the tail moved, and applied to per-connection memory it would have let a feature that halves how many connections a box holds through on the strength of an average. Both are hard invariants instead, disclosed rather than budgeted.

**Leaving the throughput axis inactive until a machine existed to measure it.** That was true when this ADR was first written: v2 had no quiet box, so every conflict on that axis went to DX by default. It no longer is: [HttpArena](https://www.http-arena.com/frameworks/nilo/) runs every entry on the same 64-core machine, and `bench/`'s own scripts are pinned to physical cores for the runs this repository publishes. The axis is measured now, not merely reasoned about.

**A build option a `zig fetch` dependent has to thread through, to let the linker drop a feature nobody calls.** Weighed against what it solves (a handful of unconditional bytes on two examples) it is a worse ergonomic problem than the one it removes, so features that cost unconditional binary size disclose the number here instead of hiding behind a flag only some callers know to pass. Flags exist for whole modules a dependent may not want at all (`.sql`, `.tls`, `.http2`), which is a coarser, earlier-stage answer to a related question, not this one.

## What it costs

This ADR spends nothing itself; it is the ledger every other one is checked against.

| Axis | Cost |
|---|---|
| Allocations per request | 0 |
| Memory per idle connection | 0 |
| Throughput and p99 | 0 |
| Binary size | 0: the table above is the running total other ADRs add to, not a cost of its own |
| HTTP/2 for every request on the port HTTP/1.1 is on, its connection split from the gRPC envelope ([ADR 259](./259-http2-is-a-framing-of-every-request.md), stages 5.1 to 5.3 of [framing](../design/framing.md)); a build without `-Dhttp2` is byte-identical, and the `-Dhttp2` build pays +12,816 B and +12,800 B more than the `-Dgrpc` build it replaces ([the runs](../../bench/result/http.md#what-any-request-on-http2-costs)) | +0 | +0 |
| An event stream handed to the HTTP/2 connection ([ADR 260](./260-a-request-on-http2-runs-from-its-headers.md), stage 6.3 of [framing](../design/framing.md)); a build without `-Dhttp2` is `cmp`-identical, and the `-Dhttp2` build pays +5,136 B on `hello` and `rest`, and 9,800 B more for a program that calls `eventsFrom` ([the run](../../bench/result/http.md#what-an-event-stream-handed-to-the-http2-connection-costs)) | +0 | +0 |
