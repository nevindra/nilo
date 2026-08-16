# The trade budget has three axes, and only one of them is 10%

ADR 0001 says: **the comfort of writing code wins, unless it costs more than 10%.** That rule got v1 built and none of it is being taken back. What v2 needs is for it to say *10% of what*, because "performance" is three different numbers and they do not recover in the same way.

The metrics section of `docs/history.md` already separated them; this ADR turns that separation into the rule.

## The three axes

| Axis | Rule | Where it is held |
|---|---|---|
| **Throughput and p99** | DX wins below 10%, as ADR 0001 says | Nowhere yet — no quiet machine |
| **Allocations per request** | Hard invariant. A DX feature may not add one to a path that did not ask for it | A test: *the request path stays inside its allocation budget* |
| **Memory per idle connection** | Hard invariant. Every new feature states its cost or has none | Measured across 1,000 held-open connections |

The reason for the split is that the three are not the same kind of number.

**Throughput is elastic.** Ten percent off 140k requests per second is not something the audience — people living at 30–80k today — will ever feel. It disappears into the first database query. That is ADR 0001's whole argument and it still holds.

**Allocations are not elastic, because they are what p99 is made of.** An allocation added to the request path is not 10% slower on average; it is fine a million times and then it is a `mmap`, and that one request is the tail. p99 is a primary metric precisely so that winning on throughput while stalling the tail does not count, and the way to keep p99 flat is TigerBeetle's: allocate at startup, then stop (ADR 0015). Three is the number, it is what a test enforces, and a fourth needs a reason rather than a benchmark that came out level.

**Memory per connection is not elastic either, because it decides what the server can hold.** At ~21 KB, a hundred thousand idle keep-alive connections is 2 GB. A feature that adds 4 KB to `Ctx` does not make anything slower; it makes the same box hold a fifth fewer connections, and nobody notices until the box is full. So the rule is not a percentage, it is a disclosure: a feature that costs per-connection memory says how much, in the ADR that introduces it.

## What "low memory" is allowed to mean

nilo can honestly say "low memory" only because of the bottom two rows. They are the claim; throughput is the headline. Getting that backwards — trading an allocation to win a benchmark — would be spending the thing that is actually true to improve the thing that is not measured yet.

## The fourth number: binary size

v2 turned up an axis v1 never had to think about, and it is worth naming rather than quietly leaving out of the table.

nginx's discipline, quoted approvingly in ADR 0015, is that a module is compiled in or absent. nilo is not currently able to honour that. The generated API description costs **+14 KB on the hello example whether or not `app.docs()` is called** (ADR 0017), because the switch is a runtime `null` check and the linker cannot see through it.

The rule adopted, which is weaker than nginx's and honest about being so:

> A feature that cannot be dropped by the linker states its unconditional binary cost in its own ADR, as a measured number against a stripped `ReleaseFast` build — not an estimate, and not the size of the code that was written for it. No feature may cost unconditional *request-path* or *per-connection* cost; those two stay absent, not merely small.

The insistence on measuring is not pedantry. That +14 KB was first reported as +43 KB, and the difference was not the feature at all — it was one extra instantiation of `std.sort.block` that the feature made reachable, 37 KB of machine code for sorting two files. The number a feature costs in Zig is rarely the code you can see; it is whichever generic you woke up.

14 KB on a 1 MB static binary is a trade worth making once. It is not one worth making five times, so the number goes in the table each time and somebody gets to notice the day it stops being reasonable.

### The running total

Measured stripped, `ReleaseFast`, on the examples in this repository.

| Change | hello | rest |
|---|---|---|
| The API description ([ADR 0017](./0017-the-api-description-comes-from-the-signatures.md)) | +14 KB | +34 KB |
| JSON failure bodies, `Status`, `?T` → 404, nested body messages, `components`, `Patch` ([ADRs 0024](./0024-a-failure-mode-belongs-in-the-return-type.md)–[0026](./0026-a-patch-needs-three-answers-and-an-optional-has-two.md)) | +6 KB | +14 KB |
| Names for generic shapes, an honest answer for a handler that writes its own, and the enum wording | +3.3 KB | +3.2 KB |
| Holding the rule about error messages ([ADR 0027](./0027-the-rule-about-error-messages-is-held-by-a-build-step.md)) | +0 | +0 |
| Core as a module of its own, and a Scope in place of a `Ctx` ([ADR 0041](./0041-a-module-sits-where-the-loop-puts-it.md)) | +0 | +0 |
| A second module in the bottom layer, `nilo_id` ([ADR 0042](./0042-the-bottom-layer-holds-more-than-one-module.md)) | +0 | +0 |
| A third, `nilo_config` ([ADR 0043](./0043-a-setting-is-a-field-and-every-bad-one-is-named-at-once.md)) | +0 | +0 |
| A clock in Core and entropy on the `Ctx` ([ADR 0045](./0045-core-knows-what-time-it-is.md), [ADR 0046](./0046-entropy-belongs-to-the-loop.md)) | +0 | +0 |
| One pass through a WebSocket message, and a broadcast framed once ([ADR 0052](./0052-a-message-is-copied-once-and-framed-once.md)) | +0 | +0 |
| Everything `nilo_sql` gained in this cycle — `Decimal`, `ON CONFLICT`, `tx.deadline`, array columns, `insertMany` ([ADRs 0047](./0047-a-deadline-needs-a-connection-you-hold.md), [0050](./0050-a-numeric-is-digits-and-a-string-in-json.md)–[0051](./0051-an-array-is-a-slice-and-a-slice-is-one-deep.md), [0053](./0053-a-batch-is-one-array-per-column.md)) | +0 | +0 |
| Isolation levels, row locks and savepoints ([ADR 0054](./0054-contention-is-what-a-transaction-is-for.md)) | +0 | +0 |
| A column type declared outside this module ([ADR 0055](./0055-a-column-type-can-come-from-outside-this-module.md)) | +0 | +0 |

The second row is one measurement of six changes because they landed together, which is a worse record than the first row and is noted as such. The split it does show is the useful part: `hello` has one route returning text and pays +6 KB, which is the failure-body writer and nothing else — that part is unconditional. The remaining +8 KB on `rest` is the body describer and the schema walker, and those are generated per body type, so they are paid by applications that have bodies.

The third row is nearly the same on both, which says what it is: the name renderer and the extra descriptions live in the document writer, and the document writer is linked in whether or not `docs()` is called — the same unconditional cost the first row is about, and the same open question in `docs/roadmap.md`.

The fourth row is a real zero rather than a rounded one: the same three examples came out byte-for-byte identical, because both halves of that change — the message rewriting and the earlier check — happen while compiling and a message that is never produced is a string that never exists. It is a row rather than an omission because the rule is that a feature states its cost, and "none" is a number somebody may want to check later.

The last row is +0 on both because neither example opens a WebSocket, which is the property that row exists to record: the linker still drops the whole of it. `chat`, which does, pays **+896 bytes** — the 128-wide unmasking, the close-frame validation, `print`, `json` and the room's roll. It is the first entry here measured on an example other than these two, because these two would have shown nothing.

The `nilo_sql` row is +0 for a reason worth stating rather than glossing: **no example in this repository imports the module**, so none of the seven links a byte of it — not the driver, not its four transitive dependencies. That is [ADR 0040](./0040-a-service-that-needs-the-loop-is-finished-when-the-loop-exists.md)'s property observed rather than argued, and it is why a row of SQL work can be measured here at all. What the module's own additions cost is paid by a project that imports it, and inside that project each of these is instantiated per Row and per call site: a service that never reads an array column links no `readList`, and one that never batches links no `unnest` statement.

`orders`, the largest example, is 1,327,992 bytes stripped. It is not a row here because it has no before.

## Consequences

- ADR 0001 is not superseded. Its rule is now the first row of a table, and its reasoning about the audience is unchanged.
- The 10% row is still inactive: there is no machine to measure throughput on, so every conflict on that axis still goes to DX automatically. The other two rows *are* active, have been since v1, and are the only budget currently enforced by anything.
- Two v2 features were built to this: resolved values allocate nothing on a route that asks for none, and the OpenAPI document is built at `listen()` rather than per request. Neither moved the allocation count, and a test records the count for a route that resolves nothing so that a future change cannot move it quietly.
- Making the linker able to drop unused features needs a build option that a `zig fetch` dependent has to thread through. That is a worse ergonomic problem than the one it solves, so it stays open in `docs/roadmap.md` rather than being decided here.
