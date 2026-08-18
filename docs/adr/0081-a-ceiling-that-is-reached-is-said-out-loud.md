# 0081 — a ceiling that is reached is said out loud

**Status:** accepted
**Amends:** [ADR 0036](./0036-a-binding-hands-its-failures-to-the-handler.md)

## Context

nilo's answer to a body that does not fit is one of its better sentences. It
names the field, says what the field takes, says what arrived instead, and does
it through nested objects and lists: `"lines[1].qty" has to be a whole number,
not text`.

The walk stops at eight levels — the same limit `openapi.schemaOf` and
`str.stamp` use, because a type holding one of its own has to stop somewhere.
That limit was documented in three places. **What was documented nowhere is what
the client is handed once it is reached**, and the answer was nothing at all:

```
HTTP/1.1 400 Bad Request

{"error":"Bad Request","status":400}
```

Not a worse sentence — *no* sentence. `describeBadBody` returned the original
`err`, and the fallback for "nothing here can do better" is the same fallback
for "text that is not JSON at all". From the client's side those two are
indistinguishable, so the first move on receiving it is to go back and check
whether the body is even valid JSON, which it is.

The application that found this had a settings document nine levels deep. The
mistake was a string where a number went, four levels below where the naming
stops, and the 400 arrived with nothing in it. Everything the framework knew —
that the JSON parsed, that it was an object, that the shape is wrong somewhere
below a known ceiling — was thrown away on the way out.

## Decision

**When the walk finds nothing to name but did reach the ceiling, it says the
ceiling was reached.**

```
the request body is valid JSON and does not fit this endpoint, but it is nested
deeper than 8 levels — which is as far as nilo follows a body — so it cannot say
which part is wrong. The mistake is somewhere below that.
```

Three facts, and the client had none of them: the JSON is fine, the shape is
not, and the reason nobody is naming a field is a limit rather than a mystery.
The last sentence is the one that saves the hour — it says where to look.

The walk still stops. Raising the ceiling is a different question with a
comptime cost attached and is not answered here; **saying which wall was hit is
free**, and is the whole of this change.

Mechanically it is an out-parameter. `describeField` and `describeObject` take a
`deeper: *bool`, and the one place that returns early on the budget sets it —
but only when the value it is looking at actually has something inside it:

```zig
if (depth == 0) {
    if (hasInsides(T, given)) deeper.* = true;
    return null;
}
```

`hasInsides` is what keeps the message honest. A `Str` sitting at level eight is
the *bottom* of a body that fits, not evidence of one that does not, and an
empty list has nothing below it either. Without that check every deep-but-fine
body that failed for some other reason would be told it was too deep.

Both callers get it — the single-sentence 400 and the collected 422's fallback
path — because a `Bound(T)` whose refusal is nested has the same dead end.

## What was rejected

**Raising `max_body_depth`.** It moves the cliff without removing it, and the
walk is `inline for` over the fields at every level: the depth is a comptime
parameter, so each extra level is more instantiations of `describeObject` for
every body type in the program. The number would still be documented in three
places and still be silent at the bottom.

**Describing the value with no name — "something nested is a number where an
object goes".** The type is known at the ceiling, so this is writable. It reads
as though the framework is being coy: it clearly knows something, and will not
say where. Naming the limit is more useful than naming the type, because the
limit is what the reader can act on.

**Quoting the deepest name reached** — `down.down.down.down.down.down.down.down`
and then "below here". Tempting, and wrong in the common case: the ceiling is
reached by walking *every* field, so the name that happens to be in hand when
`deeper` is set is whichever field the `inline for` visited last. It would point
confidently at the wrong branch.

## What it costs

Nothing on any of the four axes. `deeper` is one stack `bool` in a function that
runs only on a request already refused; the ceiling branch was there and now
sets a flag. A body that parses never reaches any of this. Binary size is
unchanged beyond the one string, which is in a `.rodata` the failure path
already pays for.
