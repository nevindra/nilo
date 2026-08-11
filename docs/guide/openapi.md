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
| an optional | a nullable field |
| the return type | the 200 response schema |

## What it won't claim

It won't say what your signature doesn't. A handler returning `Response(T)` picks
its status at runtime, so the document says `default` rather than guessing `200`.
A type with no JSON shape is `{}` — "anything", which is true. A handler that
takes a `*Ctx` and digs the body out by hand documents nothing, which is an
accurate description of what it told anybody.

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
