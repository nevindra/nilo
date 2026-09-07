# What a server prints, it can read

`sql.Timestamp` writes RFC 3339, declares `format: "date-time"` in the generated
document, and could not read one back.

Every keyset cursor in a paged list is a value the same server printed one
request ago. Reading it back was 82 lines in the port that reported this —
`parseRfc3339` for the offset, the optional fraction and the refusal of a bare
local time, plus Howard Hinnant's `days_from_civil` — and 40 more lines of test
asserting that their parser agreed with nilo's writer. **The tests were there
because a parser that disagrees with the writer pages past rows or repeats them,
silently.**

## What it does now

`Timestamp.nilo_parse`, which is the declaration that makes a type a path param
(ADR 0142) and, since [ADR 0158](./0158-one-arrival-one-answer.md), a query
field. So a cursor is an ordinary typed argument:

```zig
const Page = struct { after: ?sql.Timestamp = null, limit: u32 = 50 };
fn feed(db: *Db, page: Query(Page)) ![]Event { … }
```

**The round trip is the property**, and the test asserts the pair rather than
each half: for a set of instants, what `writeRfc3339` prints, `nilo_parse` reads
back to the same microsecond. A parser held only against a spec can be correct
and still not be the inverse of the writer beside it.

## What it accepts, and the one thing it refuses

Wider than what the writer prints, because both of these arrive from clients
that were never told what nilo emits and both have exactly one reading:

- an offset — `2026-08-16T16:30:00+07:00` is the same moment as
  `2026-08-16T09:30:00Z`;
- fractional seconds, truncated at microseconds because that is the resolution
  the column has. Digits past the sixth are somebody else's precision, dropped
  rather than refused.

**A time with no zone at all is refused**, and that is the decision worth
naming. Guessing UTC is how a cursor moves by seven hours at a customer running
their browser in Jakarta — and it fails in the direction where nothing errors.

A leap second is refused too, one notch narrower than RFC 3339: `:60` has no
microsecond to come back to, so accepting it would break the round trip in the
one place this type is used for.

## Why the date arithmetic is written out

`std.time.epoch` walks days into a civil date and nothing in std walks one back.
`days_from_civil` is the standard inverse, twelve lines, and the alternative was
a dependency or a loop over years.

`fixed` rather than `std.fmt.parseInt` for each field: `parseInt` accepts `+7`
and `-0`, neither of which is a field of a timestamp, and would read `2026-1O-01`
as far as the letter and stop somewhere useless. That is the same argument
`convert.spelledAsNumber` already makes about request text.

## What is deliberately not done

**`jsonParse`.** A `Timestamp` in a request *body* still parses as whatever
`std.json` makes of a struct, which is not a string. That is a real gap and a
different one — it belongs to `std.json`'s protocol, not to this file's — and
doing it here would have made this change two changes.

## Consequences

- One `nilo_parse` and four private helpers on `Timestamp`, in `sql/types.zig`,
  which imports nothing new to say it.
- 82 lines and 40 lines of test delete themselves in the port that reported it,
  along with a class of bug it stops owning.
- `parsesItself(Timestamp)` is now true, so a `Timestamp` is also a path param.
  That is a widening: nothing refused one before, and nothing was asking.
