# A route can say its own name

nilo writes an `operationId` from the method and the path, at one site, with
nothing to override it:

```
putApiPartnersIdCapabilitiesCapability
```

A caller's own name for the same endpoint is `addPartnerCapability`.

That is a good default and it was the only option. The gap turned up where it
matters: their authorisation model is a default-deny table keyed by
`operationId`, 267 entries, an operation missing from it is refused for
everybody, and a test reads the OpenAPI document in both directions to keep the
two honest. Under a derived name the keys stop being words anybody chose, and a
route that moves path silently changes its key.

It fails shut, which is the right direction. It is still a table nobody can
read.

## What a derived name is bad at

Two things, and they are the two a key needs.

**It is not a word anybody chose.** A generated client's method is
`putApiPartnersIdCapabilitiesCapability`, and so is the row in the caller's
table. Both are readable in the sense that a machine can read them.

**It moves when the path moves.** Mounting `/api/partners` under `/api/v2`
rewrites 30 keys. In the caller's case the rewrite is silent on their side and
loud on nobody's: the table still has the old keys, every moved operation is
missing from it, and every moved operation is refused for everybody. Correct,
and not what anybody meant to deploy.

## The shape

```zig
try app.named("addPartnerCapability")
    .put("/api/partners/:id/capabilities/:capability", addCapability);

const api = app.group("/api");
try api.named("listPartners").get("/partners", listPartners);
```

`named` is the vocabulary `with` and `without` already use
([ADR 0126](0126-a-route-can-say-what-covers-it.md),
[ADR 0080](0080-a-route-can-say-it-is-not-covered.md)): it hands back a group,
and which name a route carries is settled while compiling.
`GroupOf(prefix, excluded)` became `GroupWith(prefix, excluded, attached)` when
`with` landed, and is now `GroupWith(prefix, excluded, attached, name)` — so
nothing that named the old type broke, exactly as it did not the last time.

**A name is checked while compiling**: letters, digits and `_`, starting with a
letter or `_`. It is a word a client generator turns into a method, and the
refusal says so rather than letting the generator find out.

**Two routes with the same name stop the process at registration**, the way a
duplicate route does. The document would carry the same key twice, and
whichever consumer read it would see one of the two.

## What this is not

**It is not `huma.Operation` coming back.** Reading the signature is the whole
point of the library ([ADR 0017](0017-the-api-description-comes-from-the-signatures.md)),
and this changes nothing about what the document *says*: the parameters, the
body, the response and the failure still come from the argument list and the
return type. A name is not a description. It is what the endpoint is called.

That is the line, and it is worth being able to state: **a route may say what
it is called and may not say what it does.** Anything on the second side of it
is an annotation, which is the one thing this framework does not ask for.

## The alternative that was rejected

**A trailing options struct on each verb** — `app.get(pattern, handler, .{
.name = "listPartners" })`. One place to look and no new type, at the cost of
fourteen changed signatures across `App` and `Group`, and an options struct
with one field in it that would attract a second. The second field is the
problem: `.summary`, `.tags` and `.deprecated` all fit in a struct like that
and none of them fit the framework, and a shape that makes the wrong thing easy
to add is a shape that gets it added.

`named` cannot grow that way. It takes a name because it is called `named`.

## Consequences

- One comptime parameter on `GroupWith`, one method on `App` and one on the
  group, one refusal, and one field on `Operation`.
- Nothing at run time. The name is comptime and reaches the document as a
  slice of read-only memory, the way the pattern already does.
- A route that says nothing keeps the derived name it always had, and the
  derivation is untouched.
