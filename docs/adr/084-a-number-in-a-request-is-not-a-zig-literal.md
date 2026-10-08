# A number in a request is not a Zig literal

**Status:** accepted
**Topic:** [request-input](../design/request-input.md)

`convert.tryConvert` is the one place a stranger's text becomes a number a
handler asked for — a path param, a query value, a form field — and
`json.parseLeaky` is the other, for a JSON body. `tryConvert` handed the text
straight to `std.fmt`:

```zig
.int => out.* = std.fmt.parseInt(P, text, 10) catch return .not_a_number,
.float => out.* = std.fmt.parseFloat(P, text) catch return .not_a_number,
```

`std.fmt` reads **Zig's literal grammar**, which is a larger language than
anybody types into a URL:

```
/users/+7      -> user 7
?page=1_0      -> page ten
?ratio=nan     -> a f64 that loses every comparison it is ever in
?ratio=0x1p3   -> 8.0
```

**A number in request text is digits, with a leading `-` only where the type
has one, and for a real number a fractional part and an exponent.** Checked
before `std.fmt` rather than instead of it, since the shape says nothing about
whether the value fits in a `u8`.

**A real number is also finite.** `1e999` is well spelled, and `parseFloat`
answers infinity for it, the other half of what `nan` was: a value that sails
through every bound a handler writes. It is `.not_a_number`, and "finite" is
asked of the width the field has, so `1e39` is refused for an `f32`.

## A body reads numbers by the same grammar

A JSON body used to be `std.json`'s to read, on the premise that JSON has no
spelling for `nan` and so cannot disagree with a query about what a number is.
The premise was wrong in three places. `std.json` hands a *string* token to
`parseInt` and `parseFloat` too, so `{"page":"1_0"}` was ten, `"+7"` was seven
and `"nan"` was a NaN. A number token `1e999` was infinity. And `{"n":2e38}` into
a `u128` panicked inside `std.json` in ReleaseSafe, because it converts through
an `i128` and the cast is out of range.

`std.json` has no hook for a number, so `json.parseLeaky` is the walk it makes
over a struct, an optional, a list and a fixed array, with the integer and the
float leaf swapped for `spelledAsNumber` followed by `parseInt` or `parseFloat`.
A map (`std.json.ArrayHashMap`) and a tuple are walked the same way, so their numbers
are read by the rule; what it does not enter, a type with its own `jsonParse` or an
externally tagged union, it hands back to `std.json.innerParse` unchanged. The consequences, each the query's rule:

- A quoted number is still a number if it is spelled like one (`"10"`), and
  `"1_0"`, `"+7"`, `"nan"` and `"0x1p3"` are refused.
- **A whole number is digits.** `5.0` and `1e2` are refused for an integer field,
  which `std.json` read as 5 and 100, because `?page=5.0` is refused too and a
  front end that writes `5.0` for a count is two clients disagreeing about the
  type. The `u128` case is this rule: `2e38` is not digits, so it never reaches
  the cast that panicked, and the same number written as digits is read exactly.
- A float that does not fit its width is refused, never read as infinity.
- A number that is the right kind and not a value of its field (`300` for a
  `u8`, `1.5` or `-1` for an integer) names the field and quotes the number, as
  `?age=300` does, and under `Bound` it is collected like any other field
  (`ctx.fits` checks range and kind for a number now).

The cost is none that could be told from the spread: the walk is the one
`std.json` makes, one pass, the same allocations, and on a 220-byte order body
it ran 567ns against `std.json`'s 589ns, on 177 bytes of numbers 971ns against
1003ns, and on a body with no number in it 143ns against 143ns
(`ReleaseFast`, best of nine runs of 200,000, interleaved in one binary,
`bench/result/http.md`).

## Why this is [ADR 070](./070-a-request-nobody-else-would-answer-is-refused.md), one layer down

That decision refused a `Content-Length` that was not purely digits, and
`http1.digitsOnly` is the four lines it became. `range.zig` carries the same
four for the same reason. The argument was that a front end and nilo reading
the same bytes as different numbers is where a smuggled request travels.

Nothing is smuggled through `?page=1_0`. What travels is the same shape of
disagreement one layer up: the client wrote `+7` meaning something, a proxy or
a log or a cache read it as text, and nilo read it as 7. Two clients
disagreeing about which page they asked for is a bug that presents as
"sometimes it shows the wrong results" and is never found.

`nan` is worse than the other three and is the reason the float half is in
scope, which the gap as written was not. It is not a misreading — it is a value
that makes `<`, `>` and `==` all false, so a handler that bounds a ratio lets it
through every bound it has. JSON has no spelling for it, so a body binding to
the same `f64` field already refuses it: the query string and the body
disagreed about what a `f64` is.

## What is deliberately still accepted

**A leading zero.** `05` is five in every grammar that has digits, nobody
disagrees about it, and refusing it turns a request everyone reads the same way
into a 400. `digitsOnly` made the same call for the same reason.

**A `+` in an exponent.** `1e+3` is how every JSON writer spells it. A leading
`+` is not, because nothing produces `+7`.

**A leading `-` on a signed field.** That was the one open question in the gap
as filed, and the answer is the obvious one: an `i32` param that would not take
a negative number is a different bug.

## What it costs

Nothing measurable, and nothing at all on the failure path. The scan is one
pass over text that `std.fmt` is about to walk anyway, on values that are
almost always one to ten bytes, and it is only reached for a field whose type is
a number. No message changed, so no refusal moved.

## `nilo_config` is deliberately not changed

It carries forty lines of converter of its own rather than sharing this one, for
[ADR 039](./039-a-setting-is-a-field-and-every-bad-one-is-named-at-once.md)'s
reason, and it still hands `PORT` to `std.fmt`. That is not an oversight to fix
later: a setting is read from the environment of the process, written by whoever
deploys it, once, before the socket opens. `PORT=+8080` is an operator typing
something odd about their own machine and being understood. This file reads what
a stranger sent over the network, which is a different question with a different
answer.

## What it does not do

It does not bound the *value*. `?page=99999999999` is still a `u32` that does
not fit and still comes back `.not_a_number`, and `?age=900` is still an
application's question rather than nilo's — the `Reason` set stays five wide on
purpose, and a sixth for "out of range" would be the first word of a validation
language.

## What was rejected

**Leaving a body to `std.json`'s number reading**, on the premise that a body
"already refuses" what a query does. It did not: see above. Reading it was the
cheaper half of the audit of `http/` at `39896d2` and the wrong half to leave.

**Driving a parser of nilo's own for a body.** That would put the unicode
escapes, the surrogate pairs and the number edges in this repository, which
`jsonmark.zig`'s header refuses for the same reason. The walk here stops at the
number.

**Accepting `5.0` and `1e2` for an integer, as `std.json` did.** Considered, for
the clients whose JSON writer spells a count as a float. Refused because the
query refuses it, and "the same grammar" is the point; the client's fix is one
character.

**A number inside a type the walk does not enter** (an externally tagged union)
still goes by `std.json`'s rules, and a `std.json.Value` was never a gap: it keeps
a string a string, and a number that is not a finite float as the text it was
written in. A map was one until `readMap`, which reads each value through the
same walk, and a tuple likewise.
