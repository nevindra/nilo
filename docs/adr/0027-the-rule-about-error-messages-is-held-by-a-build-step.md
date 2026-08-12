# The rule about error messages is held by a build step

[ADR 0015](./0015-what-zfast-borrows-and-from-whom.md) borrowed Elm's standard and wrote it as a rule with teeth:

> Every new comptime check in v2 fires at the first place a human named the thing, says what is wrong in words, and says the fix — **or it does not ship**.

Nothing held it. It was a sentence in a document, checked by whoever happened to be reading, and building a CRUD app found two checks that had already got past it: one mistake landed inside `std.json.Stringify`, another inside a struct initialiser. Both were fixed the day they were found, which is the problem — they were found by accident.

A rule nobody enforces is a rule that decays in one direction only, because the way to break it is to add a feature and not think about it.

## The decision

`refusals/` is a directory of programs written wrong on purpose. One file, one mistake, with a comment saying what a person was trying to do. `build.zig` carries a table of what each has to fail with, and `zig build test` compiles all of them and checks.

```zig
const refusals = [_]Refusal{
    .{
        .name = "param_is_a_slice",
        .says = "argument 1 of the handler for route \"/greet/:name\" is a []const u8.",
    },
    …
};
```

```zig
const refused = b.addObject(.{ .name = refusal.name, .root_module = module });
refused.expect_errors = .{ .contains = b.fmt("error: zfast: {s}", .{refusal.says}) };
```

**The `zfast: ` prefix is supplied by the build script, not written in the table.** That is the load-bearing detail. Writing an expectation is how a check gets recorded as acceptable, and there is no way to record one whose message does not start with `zfast:` — a check that stopped somewhere else in the standard library cannot be written down as passing, only deleted or fixed. The general rule is structural rather than a string somebody remembers to compare.

The rest is a plain expectation of the message's first line. It locks the wording, which means changing a message is a build failure that shows the old text beside the new — a diff to approve rather than a change that lands unread.

## What it found on the first run

Thirty-nine checks were covered. Writing the cases and watching them fail found four defects that had been shipped, in a codebase where the message quality had been argued about repeatedly:

**Two messages had no `zfast:` prefix at all.** The two on `Response.headers` — the exact thing the prefix rule exists to catch, sitting in the file that documents the rule.

**A slice passed to `Headers.of` never reached its message.** `of` accepted `anytype` and dereferenced any pointer, and a slice is a pointer, so `.of(built[0..n])` stopped with `index syntax required for slice type '[]http1.Header'` — an error from inside zfast about zfast, which is precisely axum's failure mode named in ADR 0015. The message it was supposed to produce was three lines below and unreachable.

**The message for two request bodies blamed the wrong argument.** A handler taking a service by value — `fn placeOrder(store: Store, incoming: NewOrder)` — was told argument 2, `NewOrder`, was the surplus body, and advised to make `NewOrder` a pointer. `NewOrder` was the one thing in that signature that was already right. zfast cannot know which of two structs was meant to be the body, so the message now names both and states the rule that tells them apart.

**Messages spelled zfast's types with zfast's file names.** A resolver returning the wrong type was told it returned `str.Str`; a slice of headers was called `[]http1.Header`. Both true, both about a source tree the reader does not have and a `str` they never imported. `src/names.zig` rewrites the names zfast's own compile errors print into the ones the import line gives them — `zfast.Str`, `[]zfast.Header` — and leaves a type of the reader's own exactly where they wrote it.

## The half of the rule this does not hold, and what was done about it

The rule has two halves. The harness holds *says what is wrong in words*. It says nothing about *fires at the first place a human named the thing*, and writing it exposed how badly that half was doing.

Zig reports a `@compileError` at the `@compileError`, which is always inside zfast. What points back at the reader is the reference trace underneath, and Zig prints two frames of it by default. The chain was:

```
referenced by:
    route__anon_702: src/app.zig:284:22
    post__anon_685: src/app.zig:244:23
    6 reference(s) hidden; use '-freference-trace=8' to see all references
```

The reader's own line was the third entry — hidden by exactly one slot, behind a flag they would have to know to pass. Every one of the two frames they did get was zfast's.

The fix is that each registration method checks for itself, rather than letting the error surface from wherever the work happens to be done:

```zig
pub fn post(self: *App, comptime pattern: []const u8, comptime handler: anytype) !void {
    comptime typed.check(pattern, handler);
    try self.route(.POST, pattern, handler);
}
```

`typed.check` runs the same checks and produces the same messages; what changes is that it is called from the method the reader wrote. The trace is now:

```
referenced by:
    refusal: refusals/two_bodies.zig:17:13
```

Their line, first, with no flag. Done for all seven verbs on `App` and on `Group`, and for `route` and `tryRoute`, which are entry points somebody may call directly. The check running more than once along a path costs nothing at runtime and nothing in the binary — Zig memoizes a comptime call with the same arguments.

## What it costs

**Binary: nothing.** Measured stripped, `ReleaseFast`: `hello`, `rest` and `orders` are byte-for-byte the size they were. Both pieces are comptime-only — a message that is never produced is a string that never exists.

~~**Build time: about 9 seconds on every `zig build test`.** A warm suite went from 6.4s to 15.4s. These steps never cache: the compiler does not keep the output of a compilation that failed, so all 39 are re-analysed every run. That is the real price and it is worth naming rather than discovering.~~

**Corrected on Zig 0.16: 0.5 seconds, and they do cache.** Measured warm, `zig build refusals` is 0.5s for all 39 — the compiler now keeps enough from a failed compilation to skip re-analysing one that has not changed. The paragraph above was true when it was written and is left visible because the argument it lost is the interesting part: the price was named, accepted, and then went away on its own. Nothing was done to earn that.

It goes on `test` anyway, not on a step of its own. A rule whose enforcement is opt-in is back to being a sentence in a document, and the failure this exists to prevent — a check that quietly stops saying anything useful — is exactly the kind nobody would think to go looking for.

## What it does not cover

Two checks cannot be reached from Zig source at all: the ones for a parameter with no type, on a handler and on a resolver. A non-generic function's parameters always have types, and a generic one is stopped by the check above. They stay in, as the thing that fires if that ever stops being true, and they have no case here.

The count that matters is not 39 out of 41. It is that adding a check without adding a case is now a decision somebody makes, rather than something that happens.

## Consequences

- A new comptime check ships with a file in `refusals/` and a row in the table. Reviewing that row is reviewing the message.
- Changing a message is a build failure showing both texts. That is the point.
- `refusals/` doubles as the only place every compile-time refusal is written out in one list, which is what made the four defects above visible at all — they were found by reading the messages side by side, not by any check the harness performs.
- The location half of ADR 0015's rule is now true for route registration and untested. Nothing asserts that the reader's line stays first in the trace, because the build system has no way to assert on a reference trace.
