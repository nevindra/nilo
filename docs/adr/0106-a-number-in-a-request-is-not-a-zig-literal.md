# A number in a request is not a Zig literal

`convert.tryConvert` is the one place a stranger's text becomes a number a
handler asked for — a path param, a query value, a form field. It handed the
text straight to `std.fmt`:

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

## Why this is [ADR 0090](./0090-a-body-framed-twice-is-refused.md), one layer down

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
[ADR 0043](./0043-a-setting-is-a-field-and-every-bad-one-is-named-at-once.md)'s
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
