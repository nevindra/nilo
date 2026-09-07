# A Scope that can mint a key

nilo's own refusal says this, and has since a Service first needed request
memory:

```
Pass the `*Ctx` the handler was given, or a `nilo.Run` if there is no request.
```

Every statement in `nilo_sql` honours it: `core.checkScope` asks a type for
`arena` and `str` and nothing else, so a service function written against a
Scope runs under a request and under a `Run` alike. A port leaned on exactly
that — free functions taking a Scope, so a CLI, a seed and a test call the same
code the handler does.

It broke on the most common function in any context:

```
error: no field or member function named 'entropy' in 'scope.Run'
    const seed = try c.entropy(nid.Uuid.v7_entropy);
```

Every `create` mints a key, so following the sentence literally failed at
`createPartner` and at its equivalent in fourteen contexts.

## The asymmetry was right, and it was not the whole answer

`Ctx.entropy` goes through the Bulkhead, and its doc comment says why: entropy
comes from a syscall, and a syscall made straight from a fiber stops every
request sharing that thread (ADR 0046). Being reachable only from a `Ctx` is
what says *this call costs a wait, and here is where the wait is paid for*.

That reasoning is about **what the call does**, and the refusal above is a
promise about **what a caller may write**. Both can be kept: the same spelling,
two implementations, each honest about its own layer.

```zig
pub fn entropy(self: *Run, comptime n: usize) ![n]u8 {
    const io = self._io orelse return error.NoIo;
    var out: [n]u8 = undefined;
    try std.Io.randomSecure(io, &out);
    return out;
}
```

`Ctx.entropy`'s own comment had already written the second half:

> A program with no loop in it needs none of this: `std.Io.randomSecure` is the
> same bytes, and there is no fiber to park.

So the answer existed and what was missing was a spelling at the Scope level.

## Where the Io comes from

`Run` gained an optional `std.Io` and a second constructor:

```zig
var run = nilo.Run.initIo(gpa, threaded.io());
```

`Run.init(gpa)` is unchanged, and a Run built that way answers `error.NoIo`
rather than inventing bytes. Two reasons for the optional rather than a required
argument:

- the two things a Run does — hand out memory, stamp a lifetime — need no Io at
  all, and most Runs in a test suite never mint anything. Requiring one would
  make every existing `Run.init` a compile error to buy a call they do not make;
- a CLI, a seed and a test all have an Io in hand by the time they build a Run:
  they needed one to open the database.

**Not a compile error**, which would be better, and cannot be had: the Io is a
value, not a type. Splitting `Run` into two types to move it into the type
system would put the split in front of every caller of a Scope-taking function
to catch a mistake that names itself the first time it runs.

## What is deliberately not moved

**`hashPassword`.** It is on `Ctx` for a stronger version of the same reason —
13 ms and 19 MiB, *under* `block_warning_ms`, so calling `nilo_pw` from a
handler holds the thread and nothing in the log says so (ADR 0048). A seed
creating the first admin account wants it and will hit this next. That one may
genuinely belong to `Ctx` alone, and it is a separate argument rather than a
consequence of this one.

## Consequences

- One field, one constructor and one method on `core.Run`. `core/` still names
  no Engine: `std.Io` is std's, and `zig test core/core.zig` still runs the
  whole module with no build graph (ADR 0041).
- A service function that mints a key is now writable against a Scope, which is
  what the refusal has been telling people to do.
- The workaround it replaces was a hand-written Scope struct in the caller's own
  test file, which is a type nobody should have to know how to write.
