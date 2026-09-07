# A query parameter that is a list

```
error: nilo: the field `types: ?[]const nilo.Str` of the `Query(FeedQuery)` on
route "/api/activity" is not something a query value can become.
```

Every multi-select filter in a product is this field. The workaround is thirteen
lines called `commaList`, multiplied by most list screens.

## Why it is not only ergonomics

`?type=A&type=B` and `?type=A,B` are **two different wire contracts**, and
picking the wrong one is invisible: a server that takes the first repeated key
and drops the rest answers with fewer rows, which looks exactly like a filter
that worked.

The Go original this came from pins the choice in two places that must agree —
`explode: false` in the OpenAPI document and a matching `querySerializer` in the
generated client. nilo could say neither half: there was no field type for a
list, so the document said nothing, and the convention lived in a private helper
in the caller's own code.

## What it does now

```zig
const Feed = struct {
    tag: []const Str = &.{},
    kind: []const Kind = &.{},
    limit: u32 = 50,
};
```

**Both spellings are read.** `?tag=a,b` and `?tag=a&tag=b` both give two values,
and so does `?tag=a,b&tag=c`. Reading both costs one comparison and *removes*
the failure mode above rather than documenting it.

**One of them is written down.** The parameter carries `style: form,
explode: false` — the comma — so a client generated from the document sends the
one nilo would also have printed. That is the half a helper in the caller could
never supply.

The element may be anything a query value can become, which makes a list of
enums the ordinary case: `?kind=comment,nonsense` is a 400 before the handler
runs, and the fourteen valid words are in the document. A `commaList` helper
returning `[]const []const u8` can say neither.

## The rules a separator forces

- **Absent is the empty list**, not a 400 and not null-unless-optional. Every
  filter written against a list already means "no filter" by not being sent, so
  a list field is never `required` in the document.
- **An empty value contributes nothing**: `?tag=` is an empty list rather than a
  list holding one empty string, which is what an empty text box submits.
- **A value containing a comma cannot be sent.** That is the cost of the
  separator, it is the cost the comma-joined contract has everywhere, and it is
  why the alternative below was weighed rather than assumed away.
- **"Not sent" and "sent empty" are the same thing**, and there is no spelling
  that separates them. `?[]const Str` is the shape somebody reaching for the
  difference will try, and it does not buy it: nothing found is null whether the
  parameter was absent or arrived as `?tag=`. It only changes what nothing is
  called. Telling the two apart would mean a second sentinel on the wire for a
  distinction no filter has yet wanted; the port that asked said both mean the
  same to it, which is the answer this expects to keep giving.

## What it costs

**One allocation, on a route that asked for a list and on no other.** The
elements point into the query string, which lives as long as the request; what
is allocated is the slice of them, sized by a first pass, out of the request
arena. `test "the request path stays inside its allocation budget"` covers a
route with no list field and is unmoved, which is the invariant ADR 0018 guards:
a DX feature may not add an allocation to a path that did not ask for it.

## The alternatives that were rejected

**Repeated keys as the written contract** (`explode: true`), which is OpenAPI's
default and what a browser's own multi-select sends. Comma-joined wins on one
argument: it is **one value on the wire and therefore one thing to log**. A
request line that carries the whole filter in one parameter can be read, grepped
and pasted back; six repetitions of a key cannot. Both are still *read*, so the
choice costs a caller nothing either way.

**Letting the caller pick the separator.** A second knob whose two settings are
invisible from the outside, on the exact axis that made this worth building.
nilo picks, and says which in the document.

**Widening `convert.convertible` instead of checking in `checkQueryFields`.**
`convertible` is shared with `Form(T)` and with a JSON body, and a form reads a
body this file does not: promising a list there would compile and fill nothing.
The list is a query-slot question, so it is asked in the query slot.

## Consequences

- `queryList`, `countList`, `collectList` and `collectListCollecting` in
  `typed.zig`; one field on `openapi.Field` and two clauses in the writer.
- `Bound(Query(T))` reads a list too, and records the **first** value that would
  not convert while still reading the rest — a filter with one typo in it is a
  filter, not a request with nothing in it.
- Thirteen lines and a paragraph of convention delete themselves in the port
  that reported it, per list screen.
