# A refusal outside a request is still a refusal

```zig
pub fn status(code: u16, comptime fmt: []const u8, args: anytype) Error {
    if (current()) |f| f.set(code, fmt, args);
    return error.Failed;
}
```

Under a unit test there is no request, `current()` is null, and the status and
the sentence are dropped. A service function that refuses four different ways is
four identical `error.Failed`s to its caller:

```zig
try testing.expectError(error.Failed, comment.edit(&db, scope, id, someone_else, "hi"));
```

That test says "edit failed" where it used to say "editing somebody else's
comment is a 409". **In a project whose convention is that errors are sentences,
the sentence is the part worth asserting**, and it was the part that could not
be reached.

## The trade that was available, and who it was not available to

Moving such a test over the wire works: `testing.Client` drives a real request
into a real `App` and gives a real status, at the same cost as calling the
service directly. For an endpoint with a wire test that is a fair trade and
arguably the better one, since the status is what a client sees.

It is not a trade a service function called by a CLI, a seed or a scheduled task
can make. There is no endpoint to drive.

## What it does now

```zig
var refusals: nilo.testing.Refusals = .{};
refusals.begin();
defer refusals.end();

try testing.expectError(error.Failed, comment.edit(&db, run, id, someone_else, "hi"));
const said = refusals.caught().?;
try testing.expectEqual(@as(u16, 409), said.status);
try testing.expectEqualStrings("editing somebody else's comment", said.message);
```

The mechanism was already there and already public *within* the module:
`bulkhead.setFallbackSlot` is what a call made off the loop uses to keep the
in-flight request findable. What was missing is a supported way to reach it from
a test, which is what this is — in `nilo.testing`, beside `Client`, where
nothing that runs in a server lives.

`begin` is separate from a constructor because what goes into the slot is a
pointer to the `InFlight`, so it has to be at the address the test will keep it
at rather than at a returned temporary's. `end` restores whatever held the slot
before, so one test cannot leak into the next — asserted by a test of its own.

`clear` exists because the second assertion in a two-call test would otherwise
pass on the first call's sentence, which is the one way a test like this goes
quietly wrong.

## The alternatives that were rejected

**Making `fail.status` return the status in the error.** Zig error sets carry no
payload, so this means an error set per status or a second return value on every
fail function — which changes every handler in every program to serve the test
suite.

**Exporting `bulkhead` from `nilo`.** One line, and it hands out the slot, the
Peer, the blocking pool and the panic plumbing to buy one test helper. The
Bulkhead's whole contract is that it is the seam an Engine implements, not an
API.

**A `Failure` argument on service functions.** That is threading a test's needs
through production signatures, and it is what the fail functions exist not to
do.

## Consequences

- One struct and one small type in `http/testing.zig`. Nothing on the request
  path, nothing exported into a running server.
- A service function called by a CLI can now be tested for the words a person
  will read, which was the half with no route to it.
