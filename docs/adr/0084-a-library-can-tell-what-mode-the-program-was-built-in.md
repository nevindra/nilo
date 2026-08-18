# 0084 — a library can tell what mode the program was built in

**Status:** accepted

## Context

Leaving `.optimize` out of `b.dependency("nilo", …)` builds nilo in `Debug`
under a `ReleaseFast` program. It is legal, it is slow, and until now the guide
said so in a sentence and nothing else did:

> Pass the same `.optimize` through to the dependency. Building nilo in `Debug`
> under a `ReleaseFast` program is legal and slow, and nothing warns about it.

What makes that worth an ADR is the symmetry. **Forgetting
`std_options_debug_io` has the same symptom** — a server that is merely slow —
and `listen()` has warned about that one from the beginning, on the grounds
that a symptom you cannot see is a symptom you will not go looking for. Two
identical symptoms, one warning.

And the case that costs most is a *test* build. An application following this
guide's own advice ran its suite in both optimize modes, looping over
`.{ .Debug, .ReleaseSafe }`, and passed the mode through for its executable and
not for the test step. So the ReleaseSafe half of its suite — the gate, the one
that exists because a lifetime bug passes in Debug and segfaults in release —
ran a ReleaseSafe program against a Debug nilo for two milestones. Nothing said
so. The only tell was `-OReleaseSafe` beside `-Mroot=` and `-ODebug` beside
`-Mnilo_http=` in a compile command nobody reads.

The open question was whether a library can see this at all. `@import("builtin")`
is per-module, so inside nilo it says what *nilo* was built at, and there is no
`@import("root").builtin` to compare it with.

## Decision

**`std` is one module per compilation and it takes the root's optimize mode, so
a constant of std's own says which that was — even read from a module built at
another.**

Measured, because this is the sort of thing that is either true or an afternoon:
a scratch project with a `Debug` module inside a `ReleaseFast` executable. Read
from the Debug module, `@import("builtin").mode` is `Debug` and
`std.debug.runtime_safety` is `false`. The second is std's, and std's is the
root's.

`std.log.default_level` is the more useful of the two, because it separates
three cases rather than two:

```zig
const program_mode: ?std.builtin.OptimizeMode = switch (std.log.default_level) {
    .debug => .Debug,
    .info => .ReleaseSafe,
    else => null,          // ReleaseFast or ReleaseSmall — one answer, not two
};
```

`null` is honest rather than lazy: nothing in std distinguishes `ReleaseFast`
from `ReleaseSmall`, so the message names them as a pair instead of picking one
and being wrong half the time. It is still enough to answer the question that
matters — a `Debug` or `ReleaseSafe` nilo under a fast release program is a
mismatch whichever of the two it is.

The warning goes where the other two go, in `checkRootWiring` off `listen()`,
and it says the fix:

```
nilo was built in Debug and this program in ReleaseSafe, which is legal and
slow. Pass the mode through: b.dependency("nilo", .{ .target = target,
.optimize = optimize }) — in the test step too, which is the one that usually
gets missed.
```

**And it fires from `nilo.testing.Client.init` as well**, once per process. That
is the whole reason this is worth building: `listen()` is not called in a test,
and the test step is where the mistake actually happened. A `Client` is what a
test makes before it does anything else.

The comparison is comptime on both sides, so a matching build compiles the
branch away entirely.

## What was rejected

**A compile error.** A mismatched mode is legal and is occasionally what
somebody wants — a Debug nilo under a release program is one way to get a stack
trace out of the framework. Refusing it would be nilo deciding how somebody
builds.

**Asking the root to declare its mode**, the way it declares `std_options`. It
is a third line of boilerplate to hold a fact the compiler already has, and the
person who forgot to pass `.optimize` through is exactly the person who will
forget the declaration.

**Reading `std.debug.runtime_safety` instead.** It is a bool, so it cannot tell
`Debug` from `ReleaseSafe` — which is the pair the test-step mistake is made
of, and the pair this exists to catch.

**Warning on every request, or once per `App`.** The answer cannot change
inside a process. Once at `listen()` and once at the first test client is the
whole of it.

## What it costs

Nothing on any of the four axes. Both sides of the comparison are comptime, so
a build that matches has no branch and no string; a build that does not gets one
`std.log.warn` at startup. The test client carries one `bool` in module scope.
