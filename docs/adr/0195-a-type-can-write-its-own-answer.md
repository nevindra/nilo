# A type can write its own answer

A handler's return value is JSON. Bytes and a `Str` are `text/plain`. A
`FileBody` is a file and a `Redirect` is a `Location`. That was the whole list,
and the roadmap carried the question of whether it should be longer for as
long as the file has existed: Gin ships XML, YAML, TOML and ProtoBuf writers,
Fiber ships XML, CBOR and MsgPack, and nilo shipped none and had never written
down why.

The question got its caller. An API whose consumer is somebody else's system
that will not change — a government gateway, a bank — has to answer XML, and
the shape it took here was a `*Ctx` handler calling `c.send` with bytes it
assembled itself. That works, and it costs the route its description: the
generated document says the handler *writes* something, because there is no
return type to read the answer off.

## The answer is a declaration, not a serialiser

axum is where the shape was checked. Its `IntoResponse` is a trait a type of
the caller's implements, and a handler returning that type answers with
whatever the type said — the framework never learns what XML is. nilo already
has three declarations of exactly that kind, all read by name so a type in any
layer can carry them without an import: `nilo_parse` reads a path param,
`nilo_json` spells a struct's JSON, `nilo_openapi` describes it
([ADR 0142](0142-a-path-param-can-parse-itself.md),
[ADR 0085](0085-a-type-says-how-its-json-is-spelled.md),
[ADR 0076](0076-a-type-that-writes-its-own-json-says-so.md)).
This is the fourth, on the way out:

```zig
const Invoice = struct {
    number: u32,
    total: i64,

    pub const nilo_content_type = "application/xml";

    pub fn nilo_write(self: Invoice, w: *std.Io.Writer) !void {
        try w.print("<invoice><number>{d}</number><total>{d}</total></invoice>", .{ self.number, self.total });
    }
};

fn showInvoice(db: *Db, id: u32) !?Invoice { … }
```

`?Invoice` is a 404 when it is null, `Status(201, Invoice)` is a 201,
`Response(Invoice)` carries headers — every wrapper that works for a JSON
answer works for this one, because the dispatch happens after all of them are
taken apart, in the one place `sendValue` decides between text and JSON.

**Two declarations, and both or neither.** A content type with nothing written
under it, or bytes with no label, is each a refusal at the route. So is an
empty content type, one with a control character in it — which would end the
header line — and a `nilo_write` with any other signature.

## What the document says

`nilo_content_type` goes into the document as the answer's content type, which
is the first time the description has named one it did not choose. The schema
is whatever the type says with `nilo_openapi`, and `{}` with a note when it
says nothing — the same rule ADR 0076 set for a type that writes its own JSON:
visibly silent beats confidently wrong, and nilo cannot read a schema off a
function that writes XML.

## An idempotent route keeps it too

A kept answer ([ADR 0193](0193-a-request-answered-once-is-answered-the-same-way-again.md))
recorded its shape as one of three kinds — empty, text, JSON — and the content
type was implied by the kind. A fourth kind, `own`, carries the content type in
the record ahead of the body, so a replay goes out under the same label the
handler's type chose. Twelve bytes and a string more per kept answer of this
kind, and none for the other three.

## What it costs

**Exactly what JSON costs.** The body is written into the request arena
through the same `Writer.Allocating` that `sendJson` uses, starting at the same
`json_hint`, and goes out through `c.send`. One allocation per answer, which
is the one a JSON answer already makes; the allocation-budget test does not
move. Nothing per idle connection.

**Binary size: nothing for a program without such a type.** Every check is
`comptime` on the return type, and `sendValue`'s branch is resolved while
compiling — a program whose handlers all answer JSON links the same code it
did.

**Five refusals**, one per way of writing the pair wrong.

## What was rejected

**A serialiser in this module** — `Xml(T)` that reflects a struct into
elements, the way `json.write` reflects one into JSON. XML has namespaces,
attributes-versus-elements, CDATA and a dozen encodings of a date; a
reflection that picks one of each is right for nobody's consumer, and the
consumer here is by definition the side that will not change. What the caller
needs is *their* XML, and only they can write it. The same goes for CSV
(quoting rules), HTML (a template language) and MsgPack (a schema): every one
of them is a dependency or a design, and ADR 0018 prices both.

**Content negotiation** — one type, several encodings, chosen by `Accept`.
[ADR 0025](0025-every-failure-answers-with-the-same-json-body.md) already
found the header does not carry the information: `fetch()` and `curl` send
`*/*`. A route that answers XML answers XML.

**A `nilo_respond` returning bytes** — `fn (self) []const u8`. Where do the
bytes live? A slice into the value is fine; a slice into a buffer the function
built is a use-after-return; and nothing in the signature tells the two apart.
A writer has one answer to that, and it is the answer `sendJson` already has.

**Reading `nilo_write` alone as the marker**, with `text/plain` when there is
no content type. It is the guess `contentTypeFor` makes for bytes, and it is
wrong for every type that would bother to write itself. A label is part of the
answer.
