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

zfast can honestly say "low memory" only because of the bottom two rows. They are the claim; throughput is the headline. Getting that backwards — trading an allocation to win a benchmark — would be spending the thing that is actually true to improve the thing that is not measured yet.

## The fourth number: binary size

v2 turned up an axis v1 never had to think about, and it is worth naming rather than quietly leaving out of the table.

nginx's discipline, quoted approvingly in ADR 0015, is that a module is compiled in or absent. zfast is not currently able to honour that. The generated API description costs **+14 KB on the hello example whether or not `app.docs()` is called** (ADR 0017), because the switch is a runtime `null` check and the linker cannot see through it.

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

The second row is one measurement of six changes because they landed together, which is a worse record than the first row and is noted as such. The split it does show is the useful part: `hello` has one route returning text and pays +6 KB, which is the failure-body writer and nothing else — that part is unconditional. The remaining +8 KB on `rest` is the body describer and the schema walker, and those are generated per body type, so they are paid by applications that have bodies.

## Consequences

- ADR 0001 is not superseded. Its rule is now the first row of a table, and its reasoning about the audience is unchanged.
- The 10% row is still inactive: there is no machine to measure throughput on, so every conflict on that axis still goes to DX automatically. The other two rows *are* active, have been since v1, and are the only budget currently enforced by anything.
- Two v2 features were built to this: resolved values allocate nothing on a route that asks for none, and the OpenAPI document is built at `listen()` rather than per request. Neither moved the allocation count, and a test records the count for a route that resolves nothing so that a future change cannot move it quietly.
- Making the linker able to drop unused features needs a build option that a `zig fetch` dependent has to thread through. That is a worse ergonomic problem than the one it solves, so it stays open in `docs/roadmap.md` rather than being decided here.
