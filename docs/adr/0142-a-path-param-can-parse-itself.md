# A path param can parse itself

A path parameter could be a number, a `nilo.Str`, a `bool` or an enum. So a
uuid arrived as text, was parsed in the handler, and the generated document
described it as a bare string:

```json
{ "name": "id", "in": "path", "required": true, "schema": { "type": "string" } }
```

On a schema where 203 paths carry an `{id}` and almost every one of them is a
uuid, that is one hand-written parse per endpoint and a generated client that
has lost the format. The framework the caller came from declared
`format: "uuid"` on the input struct, which both refused a malformed id at the
router and put the format in the document.

## The marker, and why it is a marker

```zig
pub fn nilo_parse(text: []const u8) ?Self
```

Null means "that is not one of these", and becomes the same 400 a bad number
gets. `nilo_id`'s `Uuid` carries the declaration, so `sql.Uuid` works with
nothing to do on the caller's side.

**It is a declaration and not a shape.** The obvious alternative is sniffing:
a struct with a `parse` function is a path param. That would silently promote
any struct with a `parse` method — a config type, a date type, somebody's
domain object — into something a route argument can be, and change what an
existing program means without anybody writing a line. A marker is a decision
the type makes.

**It is read by name and never imported.** `http/` may not import `nilo_id` or
`nilo_sql`, and `zig build layering` holds that. So this joins the eleven
marker protocols already read the same way — `nilo_openapi`, `nilo_form`,
`nilo_query`, `nilo_resolve`, `nilo_redirect`, `nilo_bound`, `nilo_patch`,
`nilo_column`, `nilo_read`, `nilo_write`, `nilo_start` (and now `nilo_stop`) — and is the reason a
module in the bottom layer can offer something to the top one at all.

**A `nilo_parse` of the wrong shape is refused where the type is named**, five
ways: not a function, still generic, wrong arity, wrong argument, wrong return.
Not `!Self`, not `Self`. The refusal is read the first time anything reads the
marker, which is the rule ADR 0085 already set.

## The document needed nothing

`openapi.schemaWithin` already consults `nilo_openapi` for any type a
signature mentions, and `Uuid` already declares
`.{ .type = "string", .format = "uuid" }`. So the moment a `Uuid` reached
`schemaOf` as a path param's type, the document said
`{"type":"string","format":"uuid"}` on its own. Nothing in `openapi.zig`
changed.

That is worth writing down because it is the layering paying for itself: two
modules that cannot see each other agreed about a uuid, through a declaration
neither of them owns.

## It closed a second complaint

A handler written `fn update(id: sql.Uuid, body: UpdateBody)` got this:

```
nilo: the handler for route "/api/partners/{id}" takes two structs by value —
argument 3 is a uuid.Uuid and argument 4 is a partner.http.UpdateBody — and a
request only has one body.
A value is request data and a pointer is a service, so whichever of the two is
not read from the body is asked for as a pointer: `*uuid.Uuid`.
```

Correct about the ambiguity and wrong about the fix. `roleOf` classified every
struct as `.body` without ever looking at whether the route had a path-param
slot still unclaimed, so the message assumed the argument nilo could not place
was a service — and following it ends at a missing service.

For a `Uuid` the case is now gone, because a `Uuid` is a path param. For any
other struct the message was still wrong, so it gained a third sentence, and
only when there is a slot to fill:

```
  Or, if it is meant to be the path param `:sku`: a path param is a number, a
  `nilo.Str`, a `bool`, an enum, or a type carrying
  `pub fn nilo_parse(text: []const u8) ?Self`.
```

## What it cost

**One `@setEvalBranchQuota`, and it was not optional.** `operation()` was
already close to the default 1,000 branches through `openapi.nameOf` walking
type names; one marker check per handler argument took `examples/orders` over
it and the build stopped. Not a slow compile, a failed one. The quota is now
20,000 there.

**Nothing at run time.** `parsesItself` is comptime and answers false for every
type that does not carry the marker, so a program with none generates nothing.
The allocation budget test still passes.

## Where it stops

**`nilo.url` cannot build a URL for one.** `url.zig` leans on
`convert.convertible`, which was deliberately not widened: going the other way
needs a counterpart declaration — a type saying how it writes itself into a
path — and that is a second decision rather than the same one.

**A `Query(T)` or `Form(T)` field is still a `Str`, a number, a `bool` or an
enum.** The same marker would work there and it has not been done, because
nobody has asked and a feature that spreads by symmetry rather than by demand
is how a framework gets large.

## Consequences

- Five refusal files for the marker's shape, one for the amended two-structs
  message, and six rows in the `refusals` table.
- `Uuid` gained a `nilo_type_name` of `"Uuid"` — bare rather than qualified,
  because `id.Uuid` and `sql.Uuid` are both real import lines for one
  declaration and neither is the reader's (ADR 0122).
- `Reason` gained `not_that_type`, which is the 400 a type that parses itself
  answers with when it says no.
