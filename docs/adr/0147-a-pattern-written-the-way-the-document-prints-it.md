# A pattern written the way the document prints it

nilo's path param is `:id`. A route registered as `/partners/{id}` matched
those five literal characters, and nothing said so.

```zig
try app.get("/api/partners/{id}", showPartner);
```

That is a route. It answers requests for the path `/api/partners/{id}` and
nothing else.

## Why it is worth a refusal

`{}` is what OpenAPI writes. It is what nilo's own generated document prints,
at `http/openapi.zig`'s `writePathTemplate` — `/users/:id` goes out as
`/users/{id}`. It is what every framework a porter is arriving from spells. A
caller with 203 paths had all 203 of them written that way, because that is
what their existing document said.

The failure is quiet in the worst configuration. A handler that asks for the
param gets a compile error, and a good one:

```
http/typed.zig:666: error: nilo: argument 3 of the handler for route
"/api/partners/{id}" is a nilo.Str, so nilo reads it as a path param — but the
route has no path params at all.
```

A handler that takes no parameter gets nothing at all. The symptom is a 404 on
a URL the generated document promises, which is a long way from the mistake.

## Where it goes

`router.validatePattern`, beside the six refusals already there: an empty
pattern, no leading slash, a `*` that is not last, a `*` mixed with text, a
`:` with no name, and a param name used twice. Every route registered through
`App` goes through `typed.check`, which calls it, so there is one place.

The precedent is `colon_mid_segment`, which refuses `/users/id:id` — a param
written the way Rails spells it. This is the same mistake with a different
framework behind it.

```
nilo: the segment "{id}" of route "/users/{id}" is written with braces, and
nilo matches it as literal text.
  A path param is written `:name`: "/users/:id", not "/users/{id}". The `{}`
  form is what the OpenAPI document prints, so a path copied out of one
  arrives spelled that way and has to be turned back.
```

The second line names the source of the mistake rather than only the rule,
because a reader who wrote `{id}` did not guess.

## Why refusing the character is safe

`{` and `}` are excluded characters in RFC 3986. A URL carrying one unencoded
is malformed, so a pattern that means to match a literal brace has nothing to
lose. Nothing in this repository registers a route with one: the only `{}` in
a path anywhere is the document nilo emits, and the test that reads it back.

## Consequences

- One more compile-time refusal, `refusals/braces_where_a_colon_goes.zig`, and
  a row in the `refusals` table. It costs the ~270ms every refusal costs on
  `zig build test`.
- Nothing at run time. `validatePattern` is comptime and the check is two
  `indexOfScalar` calls over a segment that is already in a register.
