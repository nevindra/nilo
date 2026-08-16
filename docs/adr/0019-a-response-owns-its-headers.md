# A `Response` owns its headers, because a slice of them was a use-after-return

Stage 6 gave `Response(T)` headers so that answering `201 Created` with a `Location` would not force a handler down to `*Ctx`. The field was the obvious one:

```zig
headers: []const Header = &.{},
```

It was wrong, and it was wrong in the way that costs the most: it worked in every test, in every example, and in the README, for a whole stage.

```zig
return .{
    .status = 201,
    .headers = &.{.{
        .name = "Location",
        .value = try std.fmt.allocPrint(arena, "/users/{d}", .{created.id}),
    }},
    .value = created,
};
```

`&.{…}` is a pointer to an array, and that array has to live somewhere. When every element is comptime-known, Zig puts it in static memory and the pointer is good for ever. When any element is not — and a `Location` never is — the array is a **temporary in the handler's own stack frame**. The handler returns, the frame is gone, and `sendResult` reads the headers out of it.

In `Debug` the bytes are usually still sitting there, so the wrong thing prints correctly. In `ReleaseSafe` and `ReleaseFast` it is a segfault. Two tests crashed; both were the two that computed a header value, and the one that passed used literals only.

## The fix has to change the type

There is no version of this that keeps the slice. Copying in `sendResult` is too late — the pointer handed over is already dangling — and there is no earlier place to copy from, because the handler's `return` is what destroys the array. The lifetime is the problem, not the contents, so the response has to hold the headers itself:

```zig
.headers = .of(&.{.{ .name = "Location", .value = where }}),
```

`of` runs at the call site, where the list is still alive, and copies it into a fixed array inside the `Response`. The list can be written the same way it always was; `.of(…)` around it is the whole diff.

## What was considered and refused

- **A `[]const Header` parameter to `of`.** Simpler to write, and it would have worked — the temporary is alive for the duration of the call. It was refused because a slice's length is not known until the program runs, so a ninth header on an eight-header response could only be a truncation or a panic. Taking the list as `anytype` keeps the length in the type, and overflowing is a compile error naming both numbers.
- **Storing the header bytes inline as well.** That would close the narrower footgun underneath this one — a `.value` pointing at a `var buf: [32]u8` in the handler still dangles. It was refused on size: a useful cap on name and value is a kilobyte or two per response, for a case the request arena already answers. The rule for the value is the same one `Ctx.setStaticHeader` documents, and the `arena` argument exists to satisfy it.
- **Leaving it and documenting it.** This was the state for exactly one commit, and it is not a documentation problem. The broken shape is the shape the README recommends.

## The cap is eight

Enough for what a handler decides for itself — `Location`, a couple of `Set-Cookie`, a cache directive, one of your own — and small enough that `@sizeOf(Headers)` is 264 bytes, paid only by handlers that return a `Response(T)`. A handler returning a plain `T` carries none of it, which is the shape the benchmark measures.

Past eight, `c.setHeader` has no limit and never had this bug: it copies into the request arena the moment it is called. The compile error says so rather than only refusing.

## The real finding is about the build, not the type

This bug was reachable from the front page of the README, and the suite was green. That is not because the tests were thin — 175 of them ran — but because they only ever ran one way.

`zig build test` now builds and runs the whole suite in `Debug` **and** `ReleaseSafe`, and `-Doptimize=` does not change that. A cold run went from about 7 seconds to about 90 seconds, almost all of it LLVM; a run with nothing changed is still about 6, since Zig caches per module. That is the price of a class of bug that only exists in one of the two modes — and it is the mode people deploy in. `Debug` alone was faster and reported a passing suite for code that could not serve a request in production.

**Amended after the first real measurement.** The rule above is unchanged — both modes, every time, before anything ships. What changed is where "every time" is enforced. Measured on Zig 0.16, a warm suite is **0.8s in `Debug` and 7.8s in both**, so charging the second mode to every local test run was taxing the loop somebody sits in by 10× to catch a bug at the moment it is least likely to have been written yet. `zig build test` is `Debug`; `zig build test-all` is both and is what [CI](../../.github/workflows/ci.yml) runs on every push. The reasoning that put both modes in is why `test-all` exists at all rather than being a flag somebody remembers — what moved is the clock, not the standard. The numbers behind the split are in [`comparison.md`](../comparison.md#build-time-and-binary-size).

## Consequences

- **`Response.headers` is a breaking change** for anybody who wrote one: `&.{…}` becomes `.of(&.{…})`, and reading them back is `.view()`. There is no deprecation path, because the old spelling still compiles and still crashes.
- `nilo.Headers` is exported, so the type can be named when a helper builds one.
- A `Response(T)` is 264 bytes larger than its payload. If that ever shows up in a measurement, the cap is the knob, and ADR 0018's allocation and per-connection invariants are both untouched — nothing here allocates.
- ADR 0018's fourth axis (binary size) is unaffected: the array replaces a slice, and `of` inlines to a handful of stores.
