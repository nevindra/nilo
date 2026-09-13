# OpenAPI

You already wrote the contract. One line serves it:

```zig
app.docs(.{ .title = "Orders", .version = "2.1.0" });
```

An OpenAPI 3.1 document at `/openapi.json`, and a page for reading it at `/docs`.
Both are built when `listen()` runs, so it doesn't matter whether this line comes
before or after your routes.

## Nothing to keep in step

Nothing is annotated, because there's nothing to keep in step —
`fn getUser(db: *Db, id: u32) !User` is read by exactly the same pass that
decides what to pass in:

```json
"/users/{id}": { "get": {
  "operationId": "getUsersId",
  "parameters": [{"name":"id","in":"path","required":true,"schema":{"type":"integer"}}],
  "responses": {"200": {"content": {"application/json": {"schema": … User … }}}}
}}
```

| In the signature | In the document |
|---|---|
| a path param | a `path` parameter, typed, required |
| `Query(T)` | one query parameter per field; a defaulted field is not required |
| a struct argument | the request body schema |
| an enum | the list of its names |
| an optional field | a nullable property |
| `!T` | the 200 response schema |
| `!?T` | the 200 schema **and a 404** |
| `!Status(201, T)` | a `"201"` response, named |
| `!Response(T)` | `default` — the status is picked at runtime |
| a `*Ctx` and no return value | `default` — nilo cannot tell whether the handler wrote an answer of its own |
| anything nilo can refuse first | a 400 |

## The name of an operation

`operationId` is derived from the method and the path — `getUsersId` above —
which is a good default and a poor key. It is not a word anybody chose, and it
changes when the route moves path. If something on your side is written against
it, a route can say its own:

```zig
try app.named("addPartnerCapability")
    .put("/partners/:id/capabilities/:capability", addCapability);
```

That composes with groups and with `with`, and two routes sharing a name stop
the process at registration
([ADR 0149](../adr/0149-a-route-can-say-its-own-name.md)). It says what the
route is *called* and nothing about what it does — everything else in the
document still comes from the signature, which is the point of the whole page.

## Named shapes

A struct that came from a type with a name is written once under
`components/schemas` and referred to everywhere else:

```json
"components": {"schemas": {
  "Todo": {"type":"object","properties":{"id":{"type":"integer"}, …}},
  "Failure": {"type":"object","properties":{"error":{"type":"string"},"status":{"type":"integer"}}}
}}
```

so a route says `{"$ref":"#/components/schemas/Todo"}` rather than carrying a
copy. Generated clients get one `Todo` type instead of five identical ones.

An instantiated generic gets a name too, read back out of the one the compiler
gives it:

| Zig | in the document |
|---|---|
| `Page(Order)` | `Page_Order` |
| `Addressed(Str)` | `Addressed_Str` |
| `Addressed([]const u8)` | `Addressed_Text` |

That matters more than it looks. A generic is how Zig says "the same shape
twice", and the same shape twice is exactly what a request struct and a response
struct are — one holding `Str`, one holding `[]const u8`
([ADR 0004](../adr/0004-request-arena-and-the-str-type.md)). Writing them as
`Addressed(Text)` instead of two structs should not cost the shape its name in
every generated client.

An anonymous struct still has no name worth putting in anybody's client, so those
are written out in place. Two types that share a short name — an `a.User` and a
`b.User` — both keep their full names, because a generator handed one `User`
meaning two shapes produces code that does not compile; and where two *generics*
render to the same name and are not the same shape, neither gets it and both are
written out in place.

`Failure` is the shape every error body takes
([ADR 0025](../adr/0025-every-failure-answers-with-the-same-json-body.md)).

## What it won't claim

It won't say what your signature doesn't.

**Statuses.** A handler returning `Response(T)` picks its status at runtime, so
the document says `default` rather than guessing `200`. `Status(code, T)` puts
the code in the type, and then the document names it.

**Failures.** The only one a signature can state is "this might not be there",
which is `!?T` and comes out as a 404. A `fail.conflict(…)` inside a handler is
invisible here, and deliberately so: a compile-time check cannot read a function
body, and an annotation saying otherwise would be a second thing to keep in step
with the code — which is what this whole feature exists to avoid
([ADR 0024](../adr/0024-a-failure-mode-belongs-in-the-return-type.md)).

**Shapes.** A type with no JSON shape is `{}` — "anything", which is true. An
**untagged** union is one: nothing in the type says which arm is live. A
`union(enum)` is not, and gets a `oneOf` of whichever encoding it actually
sends — the one `std.json` writes by default, or, if the type carries
`nilo_json`, a discriminated one with `discriminator` and each arm pinned to its
own tag value ([JSON shapes](./responses.md#json-shapes-of-your-own)).

## One shape, two lifetimes

`Meta(Str)` for the body and `Meta(Text)` for the row is the split nilo asks
for, and it used to cost a generated client two identical types. It doesn't:
where a `_Str` and a `_Text` half render the same all the way down, they are one
component called `Meta`
([ADR 0077](../adr/0077-a-lifetime-has-no-rendering-in-json.md)). Two shapes
that merely look alike — `Page_Order` and `Page_User` — keep their own names.

## A type that writes its own JSON

If your type has a `jsonStringify`, `std.json` calls it and never looks at your
fields — so nilo doesn't either. Reflecting the struct would describe something
the server doesn't send, which is worse than saying nothing: it broke every
generated client that read a `nilo_id` value, because a `Uuid` goes out as 36
characters and its struct is sixteen bytes
([ADR 0076](../adr/0076-a-type-that-writes-its-own-json-says-so.md)).

So say what you send, beside the function that sends it:

```zig
const Uuid = struct {
    bytes: [16]u8,

    pub fn jsonStringify(self: Uuid, jw: anytype) !void {
        try jw.write(&self.toText());
    }

    pub const nilo_openapi = .{ .type = "string", .format = "uuid" };
};
```

`type` is required and is one of `"string"`, `"integer"`, `"number"`,
`"boolean"`. `format` is optional and is a hint to a client generator —
`"uuid"`, `"date-time"`, `"email"`. Two fields is the whole of it; this is a way
for a custom writer to stop lying, not a second language for describing types.

nilo's own types already do it: `nilo_id`'s `Uuid`, and `nilo_sql`'s
`Timestamp`, `Decimal`, `Interval` and `Inet`. You need this only for a type of
your own that writes itself.

**A custom writer that says nothing gets `{}` and a note** saying the writer is
custom and how to describe it. Visibly silent, rather than confidently wrong.

## A type that writes its own answer

The same rule, one step further out. A type carrying `nilo_content_type` and
`nilo_write` answers with whatever bytes it wrote, under its own label
([Responses](./responses.md#a-type-that-writes-its-own-answer)), and the
document says so: the response's content key is the type's own
`application/xml` or `text/csv` rather than `application/json`, which is the
first time the description names a content type it did not pick. The schema
under it is whatever the type says with `nilo_openapi`, and `{}` with a note —
*this type writes its own body, and has not said what it looks like* — when it
says nothing. nilo cannot read a schema off a function that writes XML, and
does not try ([ADR 0195](../adr/0195-a-type-can-write-its-own-answer.md)).

**An alias is not a name.** `pub const NewDoc = Filing(Str);` reads well in Zig
and the document still calls the shape `Filing_Str` — the name comes from the
compiler's name for the instantiation, and a Zig alias creates no new one. Write
the struct out if the client's type name matters.

**Answers it cannot see.** A handler that takes a `*Ctx` and returns nothing
*may* have sent its answer itself, somewhere in its body, and no reading of its
signature will find out whether it did. The document says exactly that:

```json
"responses": {"default": {"description": "this endpoint holds the Ctx and returns
                                          nothing, so it may write its own response
                                          — its signature does not settle what it
                                          answers"}}
```

and `listen()` says how many there are, once, at the moment somebody is looking:

```
info: 1 of 12 routes hold the Ctx and return nothing, so the API description
      cannot say what they answer — a handler that means "200, empty" says so by
      returning `Status(200, void)` (ADR 0150)
```

Holding a `*Ctx` is not itself the disqualification — a handler that reads a
header and then returns its answer is described like any other. Returning
nothing while holding one is.

**A handler that really does mean "200, empty" says so.** `Status(200, void)` is
the return type for it, and the document then carries the 200 rather than the
`default`. nilo cannot tell the two apart from the signature, which is why the
wording hedges rather than guesses
([ADR 0150](../adr/0150-a-ctx-handler-that-returns-nothing-may-have-written-it.md)).

That is the trade the whole feature rests on: a document that under-promises is
useful, and one that guesses is worse than none
([ADR 0017](../adr/0017-the-api-description-comes-from-the-signatures.md)).

Authentication is not described at all — there is nothing in a signature that
says a route needs a token, since that lives in middleware. That is a known gap
rather than a decision.

## Options

| | |
|---|---|
| `title` | default `"API"` |
| `version` | default `"1.0.0"` |
| `description` | |
| `path` | where the document is served. Default `/openapi.json` |
| `ui_path` | where the reading page is served. Default `/docs`; empty for none |

The `/docs` page pulls its viewer from a CDN, so set `.ui_path = ""` on a server
with no outbound network. The document itself never needs one.

## What it costs

The document is served from memory like a static file, so it arrives with an ETag
and a repeat visit is a 304. It costs the request path nothing.

What it does cost is binary size, and **unconditionally**: +14 KB on the hello
example, +34 KB on rest, whether or not `docs()` is ever called. The linker can't
see that nobody wants it. Making that conditional needs a build option every
dependent would have to thread through, which is not there yet.
