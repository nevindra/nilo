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
| anything zfast can refuse first | a 400 |

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

An anonymous struct and an instantiated generic have no name worth putting in
somebody's client, so those are still written out in place. Two types that share
a short name — an `a.User` and a `b.User` — both keep their full names, because a
generator handed one `User` meaning two shapes produces code that does not
compile.

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

**Shapes.** A type with no JSON shape is `{}` — "anything", which is true. A
handler that takes a `*Ctx` and digs the body out by hand documents nothing,
which is an accurate description of what it told anybody. That includes the
route itself: dropping to `*Ctx` for one endpoint is a fine thing to do and it
takes that endpoint out of the document.

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
