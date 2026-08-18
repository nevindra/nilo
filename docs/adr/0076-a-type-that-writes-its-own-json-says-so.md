# 0076 — a type that writes its own JSON says what it writes

**Status:** accepted
**Amends:** [ADR 0017](./0017-the-api-description-comes-from-the-signatures.md)

## Context

`nilo_id`'s `Uuid` carries a `jsonStringify`, and that is the whole reason
`nilo_http` needs no knowledge of `nilo_id` ([ADR 0046](./0046-randomness-is-an-argument.md)):
a `Uuid` in a response comes out as text and the HTTP module never learns the
type exists. Over the wire, from a running server:

```json
{"public":"01a01053-4b22-7677-a5ba-b46a1f52d384","email":"wati@example.dev"}
```

And `GET /openapi.json`, from the same process, the same field:

```json
"Uuid": {"type":"object","properties":{"bytes":{"type":"string"}},"required":["bytes"]}
```

**The description said object-with-a-`bytes`-field and the server sent a
36-character string.** `openapi.zig` reflected the struct; `std.json` called
`jsonStringify`; nothing reconciled the two. A client generated from that
document fails to parse every response carrying a `public` — in the application
that found it, all three account endpoints.

It was the only wrong schema in a 29-schema document, and that is what made it
dangerous. `Upload` renders as `{"type":"string","format":"binary"}`, `Patch(T)`
as `anyOf: [T, null]` and out of `required`, enums as their choices. The document
was trustworthy enough that nobody checked the one field it lied about.

The same applies to every `nilo_sql` Row with a `Timestamp` or a `Decimal` in
it, for the same reason: both write themselves.

## Decision

**A type whose fields are not its JSON is described by what it says, and a type
that says nothing gets `{}` and a note.**

`schemaOf` now asks the same question ADR 0039's `covers()` asks — does this
type have a `jsonStringify` — and stops reflecting when the answer is yes.

```zig
pub fn jsonStringify(self: Uuid, jw: anytype) !void { … }
pub const nilo_openapi = .{ .type = "string", .format = "uuid" };
```

`nilo_openapi` is **plain data, and it has to be**: `nilo_id` imports nothing at
all ([ADR 0042](./0042-the-bottom-layer-holds-more-than-one-module.md)), so it
cannot name a `Schema` to say this with. Two fields, `type` and an optional
`format`, read field by field rather than coerced. A marker with no `type` is a
Refusal in nilo's own words rather than a `has no member named 'type'` pointing
at a line of ours.

`Uuid`, `Timestamp` and `AsText` — which is `Decimal`, `Interval` and `Inet` —
each gained one line.

**Silence is answered honestly rather than guessed at.** A third-party type with
a custom writer and no marker becomes:

```json
{"description":"This type writes its own JSON, and has not said what it looks like. Add `pub const nilo_openapi = .{ .type = \"string\" };` to it to describe the value it sends."}
```

`{}` is JSON Schema for "anything", which is true. The description is there
because a reader who meets `{}` in an otherwise precise document should know it
is a gap somebody can close.

## What was rejected

**Deriving it from `jsonStringify`.** The function is arbitrary Zig; there is no
comptime reading of a function body, and a framework that guessed would be wrong
in exactly the cases that matter.

**Refusing a custom writer with no marker.** That breaks every existing program
with a `jsonStringify` on a type it puts in a response, to fix a document those
programs may not even generate. Visibly silent is the smaller hammer, and the
description says how to stop being silent.

**A general JSON Schema builder** — `pattern`, `minimum`, `examples`. That is a
second language for describing types beside the one nilo already has, and
ADR 0018 prices features that spend the DX budget on a thing the type already
says. Two fields is what a custom writer needs to stop lying; anything past that
is a different feature.

## What it costs

Nothing on any axis. `Schema` gained two variants of comptime data, the check is
one `@hasDecl` while compiling, and no code moved onto the request path — the
document is still built once in `listen()` and served from memory (ADR 0010).
Binary size is unmoved: the generator's code is linked whether or not `docs()`
is called, which `guide/openapi.md` already says.
