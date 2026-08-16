# A guard is not a guard until it has been seen to fail

nilo has a habit of writing something down and then trusting it. The habit
produces good documents. It has also, three separate times, produced a guard
that was not guarding anything, and each time the discovery was an accident.

They are worth putting side by side, because separately each looked like a
one-off and together they are a pattern.

**The suite whose green runs were not evidence.** `zig build test` printed a
red block that read exactly like a failure and exited 0, often enough to be
written off as flakiness under load. Two mistakes, each hiding the other. The
first: `http/test_root.zig` set a `std_options` with a log function that threw
every line away, and `build.zig` carried a comment explaining why that was
necessary. It had never run once — in a test build the root module is the
compiler's own test runner, which declares `std_options` itself. The second is
why "every time" looked like "sometimes": a run step that already succeeded is
cached, so six `zig build test` in a row execute the binary once. Forcing the
run gave the warning eight times out of eight.

**The budget test written to look the other way.** One allocation per request
is a hard invariant (ADR 0018). The test asserting it opened with a comment
saying it used no middleware, because a path with middleware allocated and
that would hide what was being measured. Every word of the comment was true.
Together they meant the shape nearly every app deploys — assets behind a
logger — was the one shape the invariant was never checked against. It had
been broken the whole time.

**The build-time number that improved on its own.** ADR 0027 recorded that the
refusals harness cost about 9 seconds, then recorded a correction: on Zig 0.16
it had dropped to 0.5 seconds and started caching. Nobody had done any work to
make that happen. It was written down anyway, and it was wrong — rerunning it
on a clean checkout of the very commit that claimed it gives 10.6 seconds.

## What they have in common

Not carelessness. Every one was written by somebody who had thought about it,
and all three sit in files full of correct, careful reasoning about the thing
next to them. The middleware comment in the second one is three lines of
accurate analysis arriving at the wrong conclusion.

What they have in common is that **each was only ever observed passing.**

A check that has only been seen to pass and a check that cannot fail look
exactly alike from the outside. That is the whole difficulty: passing is the
default state of a broken check, and it is also the default state of a working
one. There is no way to tell them apart by reading, and all three were read,
repeatedly, by people looking for something else.

The first one adds a second lesson on top: **a green run only means something
if the run actually ran.** Caching makes "I ran it and it passed" and "I ran it
and it did nothing" produce identical output.

## The decision

**A guard ships with the observation of it failing.**

Concretely, one of these, in descending order of preference:

1. **A test that fails without the guard**, checked by taking the guard away
   and watching it go red — run, not reasoned about. This is what `refusals/`
   does for compile errors (ADR 0027): each file is a program written wrong on
   purpose, and the build asserts the exact message it stops with. It is also
   what the fixed budget test does — reverted against the old behaviour it
   reads `expected 0, found 1`.
2. **A counter-test beside the positive one**, asserting the guard stays quiet
   on correct code. Half of a detector's job is not firing, and one that cries
   wolf gets switched off — at which point it is worth less than nothing,
   because its absence now looks like its silence.
3. **A recorded measurement of the failure**, where neither is possible: the
   number, the machine, and the command that produced it.

And the rule that makes the third incident impossible to repeat:

**A number saying a cost went away on its own gets more scrutiny than one
saying work made something faster, not less.** A good result nobody worked for
has nobody to check it against.

## What this is not

It is not "test everything". nilo has plenty of code whose failure is obvious
the moment it happens — a router that matches the wrong route, a parser that
reads the wrong header. Those announce themselves.

This is about the narrow class of things whose failure mode is **silence**: a
check, a limit, an assertion, a detector, a build step. For those, silence is
also what success looks like, so nothing tells the two apart but having
watched.

## What writing this entry found

The first draft listed four incidents. Two of them were the same one — the
budget test and "a third guard that caught nothing" are one event in
`history.md`, written up under a title that made it sound like two — and the
description of the first incident said the suite "passed with the
implementation deleted", which is not what happened and is not written
anywhere. Both were caught by going back to `history.md` and reading it
instead of remembering it.

An entry about only ever having observed something passing, drafted from
memory of the observation. It is left here rather than tidied away, because it
is the cheapest available demonstration that the failure mode is not about
being careless.

## Consequences

- A change adding a check adds the case that trips it. Reviewing the case is
  reviewing the check.
- The blocking detector (ADR 0034) ships with seven tests, of which three
  exist only to prove it stays quiet: on `nilo.blocking` used correctly, on a
  stream, and on a server that turned it off. That balance is deliberate and
  is what this entry asks for.
- ADR 0027's wrong number stays in that document struck through rather than
  deleted. The correction is the useful half of the entry.
- This costs real time. The detector's tests spend about 150ms of wall clock
  proving something about wall clock, which is the price of measuring a thing
  whose unit is time. Paid rather than skipped.
