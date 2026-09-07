# A value that reaches the bottom

[ADR 0016](./0016-resolved-values-are-declared-by-their-type.md) settled how a
request-scoped value is produced: declare it with `nilo_resolve`, take it as a
handler argument, and the compiler answers "can this value be produced here".
It is the right answer to the question it was asked, and a port building an
event bus found the half it does not reach.

Their log records **who** acted and **what they were acting with** — a person,
and the Agent acting for them. The person is a field on the event, passed by
the command, and that is correct. The Agent cannot be: some sixty places
assemble an event, and each would have to carry a value the command has no
business knowing. A deal is won by the same fact whether a person or a bot
recorded it. **A field that is usually forgotten is worse than no field**,
because forgetting is silent: the write lands, the log reads fine, and the
column that says a bot was involved is quietly NULL.

Go answers this with `context.Context`. nilo had two things that nearly do and
neither arrives:

- `nilo_resolve` is worked out once per request and memoised — exactly right —
  but comes in as a **handler argument**. It stops at the top of the call stack.
  What needs it is the bottom.
- A Scope is threaded all the way down, and is a shape rather than an interface,
  which is what lets one service function run under a request and under a `Run`.
  But the shape is fixed at `arena` and `str`, and both concrete scopes are
  nilo's types, so an application cannot add to it.

That left two local answers, and both are shapes somebody has already refused.
Passing it explicitly at sixty call sites is what the port's own ADR 0092
rejected. Wrapping the Scope is `pgtest.Scope` — the shim
[ADR 0160](./0160-a-scope-that-can-mint-a-key.md) deleted three days earlier —
except this time on the **production** path, so every service function would
take the application's Scope rather than nilo's.

## What it does now

`Run` gains `give` and `resolve`, and `Ctx.resolve` was already public:

```zig
fn record(db: *Db, scope: anytype, what: Event) !void {
    const actor = try scope.resolve(Actor);
    _ = try db.insert(AuditRow, scope, .{ .agent = actor.agent, … });
}
```

**Where the value comes from is what differs between the two scopes, and that
difference is the design rather than an inconsistency.** Under a server, `Actor`
carries `nilo_resolve` and is worked out from the request itself — so ADR 0016's
first and deciding objection still holds: nothing has to remember to set it,
because producing it does not depend on the route. A tick has no request to work
anything out from, so it is told once, at the top, by the program that knows:

```zig
try run.give(Actor, .{ .agent = "nightly-import" });
```

**`error.NotGiven` rather than null**, for the reason this was reported over. A
column that is silently NULL is the failure; an error that names the type is
not. It is the same choice `Run.entropy` makes with `error.NoIo`, and the two
now read alike.

## Given-and-null is not not-given

The caller that asked for this reads the **acting Agent**: a request comes from
a person in a browser, or from software acting for that person. So there are
three states and only two are legal — given as null, which is the ordinary
human session; given an id, which the log has to record; and never given, which
is a bug in the wiring.

**Collapsing the first and the third is the failure this feature exists to
prevent.** A middleware nobody registered would make every bot write look like
a human one, for ever, with nothing on screen or in a test admitting it.

So `give` records that the type was given, whatever the value, and `resolve`
hands it back faithfully — including an optional holding null. `error.NotGiven`
means one thing: nobody called `give`. That falls out of storing the value
boxed and keyed by type rather than storing "the value if it is interesting",
and it is held by a test naming the three states rather than left to fall out,
because the two readings of this code are indistinguishable until one of them
is wrong in production.

## Which side uses which

**A request does not call `give`.** An acting Agent read from a header is
exactly a `nilo_resolve` — so declare it, and the third state stops existing:
the resolver *is* the wiring, it does not depend on the route, and a route
asking for the value does not compile without it. `give` would buy *detection*
of a wiring mistake; the resolver removes the possibility of one, and that is
the better trade wherever it is available.

**`give` is not the leftover case, and calling it one would be wrong.** A seed
that writes rows the way a person would, a test fixture that writes an event
directly, a CLI doing an import — these are not degenerate requests, they are
the ordinary shape of half the code that touches a database, and they have
nothing to derive an actor from because there is genuinely nothing there. What
they need is to say it once and have everything below hear it. `error.NotGiven`
is the right answer there rather than a consolation for the compiler not
helping: it is the loudest thing available at the only moment anybody could be
told.

The honest summary is that the compiler helps on one side and cannot on the
other, and this ADR says which is which instead of picking a design that
pretends the difference away.

## What it is not

**Not a type map on the request**, which ADR 0016 rejected on three counts and
which this leaves rejected. Nothing was added to `Ctx`: a request-scoped value
is still declared by its type and still checked while compiling, and there is
still no `c.locals("user")`. What was added is on the side that had no answer at
all — a tick, where the value cannot be derived and so must be stated.

ADR 0016's three counts, against this:

1. **Nothing checks that the value is there.** Under a request, unchanged: the
   resolver is declared and the check happens while compiling. Under a `Run` the
   check is `error.NotGiven` at the call, which is worse — and is the best
   available, because a CLI's actor is not derivable from anything the compiler
   can see. It is a real cost and it is written here rather than argued away.
2. **Untyped in a language that did not have to be.** `give` and `resolve` are
   both `comptime V: type`. The `*anyopaque` is inside, exactly as `Ctx`'s
   memoised values already are, and no caller casts anything.
3. **It costs every request something.** It costs a request *nothing*: no field
   was added to `Ctx` and no code on the request path changed. A `Run` grows one
   empty `ArrayList`, which allocates on the first `give` and never otherwise.

## The alternatives that were rejected

**A third required call in the Scope shape.** Making `resolve` part of what
`scope.check` demands would break every Scope a user wrote, to buy nothing: the
shape is duck-typed, so a function calling `scope.resolve` already fails to
compile against a scope without one, naming the call.

**`Ctx.give`, for symmetry.** It would let a middleware pre-empt a declared
resolver, which is ADR 0016's first objection walking back in through a door
marked symmetry. A request that wants a value at the bottom declares a resolver;
that is what they are for.

**Storing what was given outside the arena, so it survives `reset`.** Rejected
because a tick that answered with the previous tick's actor is wrong rather than
merely absent, and `reset` means *this tick is over*. The cost is that a loop
re-gives, which is one line at the top of the loop.

## Consequences

- `nilo_core` grows one field, two methods and a four-line helper. No allocation
  happens until something is given.
- The four axes: nothing on the request path, so allocations per request,
  throughput and per-connection memory are all unmoved. Binary size is the only
  one spent, and only in a program that calls `give` — the methods are generic,
  so a program that never names them instantiates nothing.
- `Run.reset` now clears what was given, which is a behaviour change to a method
  that previously had nothing to clear.
