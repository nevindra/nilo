# 0092 — a checkbox is a bool in a form, and nowhere else

**Status:** accepted

## Context

`convert.boolFrom` took `"true"` and `"false"` and nothing else, for every
place a value can arrive from. A ticked HTML checkbox posts `on`.

So `newsletter: bool = false` inside a `Form(T)` was a 400 the first time
somebody ticked the box — and a `bool` is one of the types `form.zig`'s own
compile error offers as an example of what a form may hold. The guide's opening
example worked around it without saying so, declaring `remember: nilo.Str =
.static("")` where the field is plainly a boolean.

The absent half already worked, and that is worth stating because it is half the
feature: a field that does not arrive takes its default, everywhere in nilo, and
"unticked" *is* the field not arriving. Only the present half was wrong.

## Decision

**`boolFrom` takes `on` as well, and only out of a form.**

`bound.Slot` — `body`, `form`, `query` — already travelled with a binding to
settle what a field is called in a message (`?page`, `"email"`) and how "it was
not sent" is worded. It now settles this too, and the enum moves from
`bound.zig` down into `convert.zig` so the parsing half can reach it;
`bound.Slot` is a re-export, so the name a caller writes is unchanged. That is
the move `Outcome` already made, for the same reason and in the same direction:
`bound.zig` imports `convert.zig` and not the other way round.

The slot is a **comptime** parameter on `tryConvert`, `convert` and `sayWhy`,
required at every call site rather than defaulted. There are five, and a default
would be a sixth caller's silent bug:

| call site | slot |
|---|---|
| `form.fill`, `form.fillCollecting` | `.form` |
| `typed.queryValue`, `typed.queryValueCollecting` | `.query` |
| `typed.paramValue` | `.query` — a path param is URL text and parses identically |

`sayWhy` words a form's failure as `has to be true, false or on`, and every
other slot's as `has to be true or false`, so the sentence lists what that slot
will actually take.

## What was rejected

**Widening `boolFrom` for everybody.** One line instead of a threaded
parameter, and it trades one wrong answer for another: `on` is not a JSON
boolean, and a client posting `{"newsletter":"on"}` has a bug that is more
useful heard than guessed at. The roadmap entry that asked for this named the
trade before the work started, which is why the parameter was threaded rather
than discovered to be necessary halfway through.

**Accepting `off` as false.** No browser sends it — an unticked box sends
nothing, which is what the default is for — so `off` would only ever come from
a hand-written client, and inventing a meaning for it is how a parser starts
accepting things nobody specified. A client that wants an explicit false has
`false`.

**Case-insensitive `on`.** `ON` and `On` are not what any browser posts. The
same argument: the list is what HTML actually sends, plus the two words a
non-browser client would reasonably write.

**A `.path` slot for path params.** `Slot` is public as `bound.Slot` and its
three values are the three places a *binding* is read from; a fourth would
widen a published enum to record a distinction that changes nothing. A path
param and a query value are both URL text and parse the same way, and `.form`
is the only slot that differs from either.

## What it costs

**Allocations per request: unchanged at zero.** `boolFrom` compares against two
string literals and, in a form, a third.

**Throughput: nothing measurable, and nothing at all outside a form.** The slot
is comptime, so `slot == .form` is folded before the binary exists: a query or
body `bool` compiles to exactly the two comparisons it compiled to before, and
a form `bool` gets one more `mem.eql` against a two-byte literal on the path
where the first two already missed. The primary metric — `GET /users/:id` — has
no `bool` in it at all.

**Memory per idle connection: unchanged.** Nothing is stored and nothing is
added to any frame that waits.

**Binary size: 0 bytes, and the binaries are byte-identical.** Stripped
`ReleaseFast`, built against `HEAD` in a `git archive` scratch tree rather than
quoted, on the four examples ADR 0087 used:

| | before | after | delta | md5 |
|---|---|---|---|---|
| `hello` | 895,064 | 895,064 | 0 | same |
| `rest` | 1,034,440 | 1,034,440 | 0 | same |
| `orders` | 1,155,640 | 1,155,640 | 0 | same |
| `forms` | 967,624 | 967,624 | 0 | same |

Identical checksums are the stronger claim and they are the honest one here:
the slot is comptime, so a program with no `bool` in a form compiles to what it
compiled to before, down to the byte. That is unlike ADR 0087, where the
binaries differed and 0 meant "fitted in existing padding".

**The measurement had to be taken twice, and the first one was wrong.** Run
against the working tree it read +64, +32, +32, +64 — which was the `zio.zig`
capacity-warning string from the *other* change in the same tree, not this one.
Two changes in one tree is one measurement, and the axis it reports belongs to
whichever of them the reader assumes. The fix was to commit the first and
re-measure from the new `HEAD`.

**What a `bool` in a form costs the program that asks for one is separate, and
it is +704 bytes.** `examples/forms` moves from `remember: Str = .static("")`
to `remember: bool = false`, which instantiates a conversion and a 400 sentence
where there was raw text and no failure path. That is the cost of a typed field
rather than the cost of this change — measured by building the same framework
twice, once with the example's old field and once with the new one, which is
the only way to tell the two apart.

Nothing to add to ADR 0018's running total.

## Consequences

- A `bool` in a `Form(T)` binds from a real browser, which is what the type
  always claimed.
- `docs/guide/forms.md`'s opening example says `remember: bool = false` instead
  of working around the gap with a `Str`.
- `bound.Slot` is `convert.Slot` re-exported. Any code naming `bound.Slot`
  is unaffected; nothing outside `http/` could name either.
