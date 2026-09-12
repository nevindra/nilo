# Responses

Most handlers answer by returning a value — see
[Handlers](./handlers.md#what-a-handler-returns). This page is the layer
underneath: what a `*Ctx` can send, and the rules that apply to both.

## Sending from a `Ctx`

```zig
fn handler(c: *nilo.Ctx) !void { … }
```

| | |
|---|---|
| `c.sendText(200, "hi")` | `text/plain` |
| `c.sendJson(201, value)` | serialised and sent |
| `c.send(200, "text/csv", bytes)` | a content type of your own |
| `c.sendFile(.{ .file = f, … })` | an open file, closed here — see [Files](#files) |
| `c.stream(200, "text/csv")` | a response written in pieces — [Streaming](./streaming.md) |
| `c.events()` | a stream of server-sent events |
| `c.upgrade(loop, state)` | turn the connection into a [WebSocket](./websocket.md) and hand it to `loop` |

## Headers

| | |
|---|---|
| `c.setHeader(name, value)` | copied into the request arena |
| `c.setStaticHeader(name, value)` | for text that already outlives the request (a literal), so nothing is copied |

**Set them before sending.** A response is flushed the moment it is sent, so
there is nothing left to change afterwards.

`Content-Type`, `Content-Length`, `Transfer-Encoding` and `Connection` are the
framework's to write, and setting them is refused — a response carrying two of
any of those is malformed. Pass the content type to `send` instead.

**`Set-Cookie` and `Vary` are the two that add rather than replace.** Two
cookies are two lines because they cannot be folded into one; two `Vary` lines
happen because the CORS middleware and a gzipped static file each name a
different axis of the same response, and replacing lost one of them
([ADR 0089](../adr/0089-two-layers-can-each-name-a-vary-axis.md)). Setting
either with a name and value already there adds nothing.

**A value may not hold a control byte, and a name has to be a token.** A header
is `name: value\r\n` with no escaping in it, so a value carrying a newline does
not make a broken header — it makes a second one, and two of them start a second
response. Both are refused with a 500 naming the header
([ADR 0087](../adr/0087-a-header-value-cannot-end-its-own-line.md)). This is
worth knowing about for the values that did not come from you: a `Location` read
out of a database, a filename off an upload. Percent-encode those, or strip
them.

For a handler that returns a value, the same headers are set through
`.headers`, which is copied rather than borrowed:

```zig
// The status is part of the signature — `!Status(201, User)` — so the API
// description names it. `Response(T)` is the same thing with the status as
// a runtime field, for when it depends on what the handler found.
return .{ .headers = .of(&.{
    .{ .name = "Location", .value = url },
}), .value = created };
```

Eight per response there, and a ninth is a compile error pointing you at
`c.setHeader`, which has no limit
([ADR 0019](../adr/0019-a-response-owns-its-headers.md)).

## Redirects

`Redirect(status)` carries its status in the type, so the API description
names it and says the answer carries a `Location`:

```zig
fn shortLink(db: *Db, code: nilo.Str) !nilo.Redirect(302) {
    return .to(try db.target(code.view()));
}
```

Which one to use is the only difficulty, and it is worth getting right:

| | |
|---|---|
| **301** | moved for good |
| **302** | found — temporary |
| **303** | see other. **What a form POST answers with**, because it turns the follow-up into a GET, so the reload button re-reads the page instead of posting the form again |
| **307** | temporary, and the method is kept |
| **308** | permanent, and the method is kept |

Anything else is a compile error — a `Location` on a status that does not carry
one means nothing to a client.

A redirect can carry headers, which is how a sign-in answers:

```zig
return .with("/", .of(&.{.{ .name = "Set-Cookie", .value = session }}));
```

`c.redirect(status, location)` is the same response from a `*Ctx`, for a status
only known while the request is running.

There is no body. Browsers follow the header and never look
([ADR 0032](../adr/0032-a-redirect-puts-its-status-in-the-type.md)).

## Files

`FileBody` is a file as a return value: the handler names it, nilo opens it,
and the bytes go from the disk to the socket without passing through your
process ([ADR 0037](../adr/0037-a-file-too-big-to-hold-is-opened-not-read.md)).

```zig
fn invoice(files: *Files, id: u32) !?nilo.FileBody {
    const name = try files.nameOf(id) orelse return null;
    return .{ .dir = files.dir, .name = name, .content_type = "application/pdf" };
}
```

A return type rather than a call, for the reason a redirect is one: the
signature is the contract, so the API description says the endpoint answers with
bytes — and the `?` says it answers 404, exactly as it does for a `?User`.

| | |
|---|---|
| `dir` | the directory to open the file in — a `nilo.Dir` |
| `name` | the name inside it |
| `content_type` | default `"application/octet-stream"` |
| `cache_control` | empty leaves the header off |
| `headers` | up to eight, the same list a `Redirect` carries |

The `dir` is not decoration. It is opened once, at startup, and held as a
service:

```zig
var files: Files = .{ .dir = try nilo.Dir.open("uploads") };
defer files.dir.close();
try app.provide(&files);
```

A name is opened relative to that descriptor rather than joined onto a path, so
nothing a request carries is ever resolved as one. What is left — a `..`
segment, an absolute path, a NUL byte, and on Windows a backslash or a drive
letter — is refused before anything is opened, and answers the same 404 a
missing file does, word for word, so a probe cannot tell the two apart. The log
line says which it was.

A download's filename is a header, and goes where the other headers go:

```zig
return .{
    .dir = files.dir,
    .name = name,
    .content_type = "application/pdf",
    .headers = .of(&.{.{
        .name = "Content-Disposition",
        .value = "attachment; filename=\"invoice-42.pdf\"",
    }}),
};
```

There is deliberately no `download_as` field. Quoting a filename properly is RFC
6266 rather than one line, and `attachment` is not the only answer — a PDF
opening in a browser tab wants `inline` with a filename.

`Range`, `If-Range`, `If-None-Match` and `HEAD` work here exactly as they do for
a [static file](./static-files.md#range-requests). The API description says the
body is `application/octet-stream` with `format: binary` rather than the content
type you set, because that one is a runtime field and the document does not
guess.

`c.sendFile(.{ .file = f, .content_type = … })` is the same response from a
`*Ctx`, for a handler that already holds an open file and has its own `etag`,
`size` or `cache_control` to give it. It closes the file, on every way out.

## JSON shapes of your own

A struct is its JSON and an enum is its tag name, and that covers nearly
everything. Two shapes it doesn't cover are the ones a REST API tends to be full
of, and a type says which it wants with one declaration
([ADR 0085](../adr/0085-a-type-says-how-its-json-is-spelled.md)).

**A union is externally tagged by default** — `{"metrics":{…}}`, one object with
one key — which is what `std.json` writes and what nilo sends if you say
nothing. `.tag` asks for the other encoding, with the variant's name beside its
own fields:

<!-- compiles -->
```zig
const nilo = @import("nilo_http");

const Condition = union(enum) {
    pub const nilo_json = .{ .tag = "signal" };
    pub const jsonParse = nilo.jsonParseFor(@This());

    metrics: struct { metric_name: []const u8, threshold: f64 },
    logs: struct { query: []const u8, count_over: u32 = 1 },
    disabled,
};

const Severity = enum {
    pub const nilo_json = .{ .rename_all = .SCREAMING_SNAKE_CASE };
    pub const jsonParse = nilo.jsonParseFor(@This());

    info,
    needs_attention,
};

const Rule = struct { id: u32, severity: Severity, condition: Condition };
```

```json
{"id":3,"severity":"NEEDS_ATTENTION","condition":{"signal":"logs","query":"level:error","count_over":5}}
```

A variant carrying nothing is the tag on its own — `{"signal":"disabled"}`.

**`rename_all` spells a name the way the wire wants it.** An enum's tags, a
union's variant names, and a struct's field names.

| | `not_found` becomes |
|---|---|
| `.lowercase` | `notfound` |
| `.UPPERCASE` | `NOTFOUND` |
| `.camelCase` | `notFound` |
| `.PascalCase` | `NotFound` |
| `.SCREAMING_SNAKE_CASE` | `NOT_FOUND` |
| `.@"kebab-case"` | `not-found` |

The first two join the words rather than keeping the underscore, which is what
serde does and what the names literally say. `.SCREAMING_SNAKE_CASE` is the one
that keeps it. There is no `.snake_case`, because that is what a Zig field name
already is. Two names that land on one is a compile error — it would put the
same key in an object twice.

### A response whose keys are camelCase

Your Rows are snake_case because Postgres is, and your wire is camelCase because
the browser is. Saying so once beats a mapping function written out field by
field, which is what a DTO layer is — and which nothing holds against the Row it
came from, so a column added to the Row reaches the wire only if somebody
remembers the second file
([ADR 0181](../adr/0181-a-field-name-is-a-spelling-too.md)).

<!-- compiles -->
```zig
const Contact = struct {
    pub const nilo_json = .{ .rename_all = .camelCase };

    id: u32,
    full_name: []const u8,   // goes out as "fullName"
    partner_id: u32,         // and "partnerId"
};
```

The API description says the same keys, so a generated client reads what the
server sends. It costs nothing per request: the name is settled while compiling
either way.

**It is a spelling for what goes *out*.** `std.json` picks the parser for a body
and reads it into the field names as they are written, so a struct with
`rename_all` used as a request body, a form or a query string is a compile error
naming the route — that route would document `fullName` and answer 400 to a
client that sent it. Give what comes in a struct of its own, spelled the way the
wire spells it. One direction that works beats two that can disagree about one
field.

A renamed struct nilo's own writer cannot reach is refused too. It errs narrow on
purpose, so one shape it does not recognise — a tuple, an array of bytes, an
untagged union, a type that writes its own JSON and says nothing about it,
anything past eight deep — sends the whole value to `std.json`, which does not
read the marker.

**A type that writes its own JSON and says what it looks like is not one of
those.** `sql.Uuid`, `sql.Timestamp`, `sql.AsText` and `id.Uuid` all carry a
`nilo_openapi` beside their `jsonStringify`, and a marker may only name a scalar
— so nilo knows the value is one string or one number and keeps writing the
object around it
([ADR 0182](../adr/0182-a-leaf-that-says-what-it-is-can-be-carried.md)). A Row
holding uuids can rename its fields, which is the ordinary case and was the
whole reason this reopened.

That also makes such a response faster whether or not it renames anything, and
by more than it sounds: the writer is chosen for the *whole* value, so one field
it would not touch used to send every string beside it to `std.json` too.
**250ns → 165ns on a 305-byte row with three uuids in it.** Your own type gets
the same by writing the same two declarations.

**The marker is per type, not inherited.** A struct renames its own fields; a
union renames its *variants* and leaves a payload struct's fields to that
struct's own marker; a nested struct that says nothing keeps its own spelling.

**Why the second line.** Writing needs no `jsonParse` — nilo makes the call, so
it reads the marker itself. Reading does, because `std.json` is what picks a
parser for a type and nothing can add a declaration to a type you wrote. So the
type hands over a reader nilo supplies. Leave the line off if the type is only
ever sent and never received; nilo will say so if you add it to a type that
never said its JSON was spelled differently.

The generated API description follows either encoding, so a client generated
from it reads what the server actually sends
([the API description](./openapi.md)).

## One request, one response

A response is written and flushed in one go. There is no "start the response,
change your mind" — that state doesn't exist, so neither do the bugs where a
header set too late silently vanishes. If you need to decide as you go, that's
what [a stream](./streaming.md) is for, and even there the head goes out first
and is fixed once written.

Sending twice is an assertion failure rather than two responses on the wire. A
handler that fails *after* sending gets its connection closed, because a
half-sent response can't be taken back and the next request on that connection
would read bytes of unclear provenance. It is logged:

```
warning: handler GET /report failed after answering: WriteFailed
```

## Keep-alive

nilo decides. HTTP/1.1 keeps the connection open unless the client says
`Connection: close`; HTTP/1.0 closes unless it asks otherwise; a failed stream or
an unreadable body closes. `c.keepAlive()` reports what will happen. Nothing a
handler does has to think about it — a 404 is a normal thing to answer, not a
reason to hang up.

## Content types

| Returned | Sent as |
|---|---|
| `void` | no body, and no `Content-Type` either |
| `Str`, `[]const u8` | `text/plain` |
| `FileBody` | its `content_type`, `application/octet-stream` by default |
| a type with `nilo_content_type` | that, and the bytes its `nilo_write` wrote — [below](#a-type-that-writes-its-own-answer) |
| anything else | `application/json` |

A failure — from a `fail.*` function, from an error, from nilo refusing a
request — is always `application/json`. See [Errors](./errors.md).

For anything else, `c.send(status, content_type, bytes)`, or `c.stream(status,
content_type)` when the length isn't known yet.

## A type that writes its own answer

nilo answers JSON, and it is not going to learn XML, CSV or a template
language ([ADR 0195](../adr/0195-a-type-can-write-its-own-answer.md) says
why). What it will do is send bytes a type of yours wrote, under a label the
type names — which is what a consumer that only reads XML needs, and what a
`*Ctx` handler calling `c.send` used to be the only way to get:

<!-- compiles -->
```zig
const Invoice = struct {
    number: u32,
    total: i64,

    pub const nilo_content_type = "application/xml";

    pub fn nilo_write(self: Invoice, w: *std.Io.Writer) !void {
        try w.print("<invoice><number>{d}</number><total>{d}</total></invoice>", .{ self.number, self.total });
    }
};

fn showInvoice(number: u32) ?Invoice {
    if (number == 0) return null;
    return .{ .number = number, .total = 1500 };
}
```

Return it the way you would return a struct — bare, in a `?`, in a
`Status(201, …)` or a `Response(…)` — and the wrappers mean what they always
mean. The difference from `c.send` is that the route is described: the
document names `application/xml`, and says what the body looks like if the
type adds `pub const nilo_openapi = .{ .type = "string" };`.

Both declarations, or neither: a content type with no `nilo_write`, or the
other way round, is a compile error naming the route.

Static files get their type from the file extension — see
[Static files](./static-files.md).
