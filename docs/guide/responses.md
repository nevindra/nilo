# Responses

**Most handlers answer by returning a value; this page covers what a `*Ctx` can send directly, and the rules both follow: headers, redirects, files, ETags, JSON names, keep-alive and compression.**

**Reference:** [`Ctx`: answering](../reference/ctx.md#answering), [handler returns](../reference/handlers.md#handler-returns), [JSON shapes](../reference/handlers.md#json-shapes), [`compress` options](../reference/app.md#compress-options) · **Design:** [Responses](../design/responses.md), [JSON](../design/json.md)

Returning a value is covered in [Handlers](./handlers.md#what-a-handler-returns). This page is the layer underneath.

## Sending from a `Ctx`

```zig
fn handler(c: *nilo.Ctx) !void { … }
```

| | |
|---|---|
| `c.sendText(200, "hi")` | `text/plain` |
| `c.sendJson(201, value)` | serialised and sent |
| `c.send(200, "text/csv", bytes)` | a content type of your own |
| `c.sendFile(.{ .file = f, … })` | an open file, closed here. See [Files](#files) |
| `c.stream(200, "text/csv")` | a response written in pieces. See [Streaming](./streaming.md) |
| `c.events()` | a stream of server-sent events |
| `c.upgrade(loop, state)` | turn the connection into a [WebSocket](./websocket.md) and hand it to `loop` |

Every call is listed in [the reference](../reference/ctx.md#answering).

**JSON that is already bytes goes out through `send`.** A body serialised somewhere else (kept in a cache, built by another library, read from a file) is `c.send(200, "application/json", bytes)`, and nothing parses or re-encodes it. The bytes are written before `send` returns, compressed first when [compression](#compression) is on, so a buffer of your own can be freed or reused on the next line. What it costs is the API description: a handler that returns nothing is documented as `default`, because its signature cannot say what it sent ([OpenAPI](./openapi.md)), and returning the typed value is what documents it.

## Headers

| | |
|---|---|
| `c.setHeader(name, value)` | copied into the request arena |
| `c.setStaticHeader(name, value)` | for text that already outlives the request (a literal), so nothing is copied |

**Set headers before sending.** A response is finished the moment it is sent, so nothing can change afterwards. A header set after the head has gone is refused with an error sentence, never lost silently. A middleware that needs to change an answer on the way out holds it first ([`next.hold`](./middleware.md#changing-an-answer-after-next)).

nilo writes `Content-Type`, `Content-Length`, `Transfer-Encoding` and `Connection` itself, and setting them is refused, because a response carrying two of any of those is malformed. Pass the content type to `send` instead.

**`Set-Cookie` and `Vary` add a line instead of replacing one.** Two cookies need two lines because they cannot be folded into one. Two `Vary` lines happen because the CORS middleware and a gzipped static file each name a different part of the same response, and replacing one lost the other ([ADR 029](../adr/029-a-header-is-checked-once-and-two-of-them-repeat.md)). Setting either with a name and value that is already there adds nothing.

**A value may not contain a control byte, and a name has to be a token.** A header is `name: value\r\n` with no escaping, so a value containing a newline does not make a broken header: it makes a second header, and two of them start a second response. Both are refused with a 500 naming the header ([ADR 029](../adr/029-a-header-is-checked-once-and-two-of-them-repeat.md)). Watch for this with values that did not come from you, such as a `Location` read from a database or a filename from an upload. Percent-encode those, or strip them.

A handler that returns a value sets the same headers through `.headers`, which is copied rather than borrowed:

```zig
// The status is part of the signature — `!Status(201, User)` — so the API
// description names it. `Response(T)` is the same thing with the status as
// a runtime field, for when it depends on what the handler found.
return .{ .headers = .of(&.{
    .{ .name = "Location", .value = url },
}), .value = created };
```

The limit there is eight per response. A ninth is a compile error that points you to `c.setHeader`, which has no limit ([ADR 018](../adr/018-a-response-owns-its-headers.md)).

## Trailers

**A trailer is a field sent after the body**, for what is only known once the body is out, such as a checksum or a gRPC status. `c.setTrailer(name, value)` sets one, and `c.trailers()` lists what is set:

```zig
fn export_(c: *nilo.Ctx) !void {
    try c.setTrailer("x-rows", "1204");
    try c.send(200, "text/csv", csv);
}
```

A trailer can be set until the body ends: before `send` for a whole answer, before `finish` for [a stream](./streaming.md#trailers), and after `next` only from a middleware that called [`next.hold`](./middleware.md#changing-an-answer-after-next). Setting a name twice keeps the last value.

**Where a trailer goes depends on the protocol.** On HTTP/2, which is gRPC, it is a HEADERS frame after the body. On an HTTP/1.1 stream it is the trailer section of the chunked body. A whole HTTP/1.1 answer has a length, so carrying a trailer means sending it chunked, and nilo does that only when the request said `TE: trailers` (and is not a HEAD, and the status has a body). Without that header the trailers are left off, which RFC 9110 allows, because a client that did not ask may not read them. `c.clientReadsTrailers()` says which case this request is.

**Some names are refused**: the ones RFC 9110 section 6.5.1 bars from a trailer (`content-length`, `transfer-encoding`, `host`, `authorization`, `set-cookie`, `cache-control`, `content-type`, `content-encoding` and the like) and any pseudo-header ([ADR 254](../adr/254-an-answer-can-carry-trailers.md)).

A handler that returns a value sets trailers through `.trailers`, beside `.headers`, on `nilo.Response(T)` and `nilo.Status(code)`:

```zig
return .{ .trailers = .of(&.{
    .{ .name = "x-rows", .value = "1204" },
}), .value = report };
```

The limit there is eight, as for headers, and a ninth is a compile error that points to `c.setTrailer`.

## Redirects

[`Redirect(status)`](../reference/handlers.md#handler-returns) carries its status in the type, so the API description names it and says the answer carries a `Location`:

```zig
fn shortLink(db: *Db, code: nilo.Str) !nilo.Redirect(302) {
    return .to(try db.target(code.view()));
}
```

The only hard part is choosing the status:

| | |
|---|---|
| **301** | moved for good |
| **302** | found, temporary |
| **303** | see other. **Use this to answer a form POST**: it turns the follow-up into a GET, so the reload button re-reads the page instead of posting the form again |
| **307** | temporary, and the method is kept |
| **308** | permanent, and the method is kept |

Any other status is a compile error, because a `Location` on a status that does not carry one means nothing to a client.

A redirect can carry headers, which is how a sign-in answers:

```zig
return .with("/", .of(&.{.{ .name = "Set-Cookie", .value = session }}));
```

[`c.redirect(status, location)`](../reference/ctx.md#answering) sends the same response from a `*Ctx`, for when the status is only known while the request is running.

There is no body. Browsers follow the header and never look at it ([ADR 031](../adr/031-a-redirect-puts-its-status-in-the-type.md)).

## Files

**[`FileBody`](../reference/handlers.md#handler-returns) is a file as a return value.** The handler names it, nilo opens it, and the bytes go from the disk to the socket without passing through your process ([ADR 009](../adr/009-static-files-are-held-in-memory-or-opened.md)).

```zig
fn invoice(files: *Files, id: u32) !?nilo.FileBody {
    const name = try files.nameOf(id) orelse return null;
    return .{ .dir = files.dir, .name = name, .content_type = "application/pdf" };
}
```

It is a return type rather than a call for the same reason a redirect is: the signature is the contract, so the API description says the endpoint answers with bytes, and the `?` says it can answer 404, exactly as it does for a `?User`.

| | |
|---|---|
| `dir` | the directory to open the file in, a [`nilo.Dir`](../reference/streaming.md#dir) |
| `name` | the name inside it |
| `content_type` | default `"application/octet-stream"` |
| `cache_control` | empty leaves the header off |
| `headers` | up to eight, the same list a `Redirect` carries |

The `dir` matters. It is opened once, at startup, and held as a service:

```zig
var files: Files = .{ .dir = try nilo.Dir.open("uploads") };
defer files.dir.close();
try app.provide(&files);
```

A name is opened relative to that directory rather than joined onto a path, so nothing a request carries is ever resolved as a path. What is left (a `..` segment, an absolute path, a NUL byte, and on Windows a backslash or a drive letter) is refused before anything is opened. It answers the same 404 a missing file does, word for word, so a probe cannot tell the two apart. The log line says which it was.

A download's filename is a header, and goes with the other headers:

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

There is deliberately no `download_as` field. Quoting a filename properly is RFC 6266, not one line, and `attachment` is not the only answer: a PDF that should open in a browser tab wants `inline` with a filename.

`Range`, `If-Range`, `If-None-Match` and `HEAD` work here exactly as they do for a [static file](./static-files.md#range-requests). The API description says the body is `application/octet-stream` with `format: binary` rather than the content type you set, because that one is a runtime field and the document does not guess.

[`c.sendFile(.{ .file = f, .content_type = … })`](../reference/ctx.md#answering) sends the same response from a `*Ctx`, for a handler that already holds an open file and has its own `etag`, `size` or `cache_control` to give it. It closes the file on every way out.

### Bytes already in memory

**[`nilo.Bytes`](../reference/handlers.md#handler-returns) is `FileBody` with the bytes in memory.** Use it for a proxy that downloads a bundle from another service and hands it to the browser with *that* service's `Content-Type`: there is no file and no `Dir`, and the content type is only known per request ([ADR 173](../adr/173-bytes-handed-on-are-an-answer.md)):

<!-- compiles -->
```zig
fn bundle(licences: *Licences, c: *nilo.Ctx, number: u32) !?nilo.Bytes {
    const got = try licences.download(c, number) orelse return null;
    return .{
        .body = got.body,
        .content_type = got.content_type,
        .headers = .of(&.{.{ .name = "Content-Disposition", .value = "attachment" }}),
    };
}
```

Nothing is copied: the body belongs to the handler, in the request arena or in a response it still holds. `?Bytes` means 404, as it does everywhere else. Unlike a `FileBody` it accepts a status wrapper, so `Status(201, Bytes)` does what it says. The document describes it as `format: binary`, for the same reason as `FileBody`. Before `Bytes`, the choices were `c.send` from a `*Ctx` handler, which the document could not see, or a `nilo_write` type naming a content type it did not know.

## ETags and 304 Not Modified

**[`nilo.Versioned(T)`](../reference/handlers.md#handler-returns) is `T` with a version, sent as a weak `ETag`, so a client that already has the answer gets a 304.** A list a dashboard polls every five seconds is the same list nearly every time. A client that sends the tag back as `If-None-Match` gets a 304 and no body, and if the handler checks first, no query runs either ([ADR 189](../adr/189-a-version-a-handler-names-is-an-etag.md)):

<!-- compiles -->
```zig
const Order = struct {
    pub const nilo_table = .{ .name = "orders", .key = .id };

    id: i64,
    total: i64,
    revision: i64,
};

fn listOrders(c: *nilo.Ctx, db: *Db) !nilo.Versioned([]Order) {
    const revision = try db.rawOne(i64, c, "select coalesce(max(revision), 0) from orders", .{}) orelse 0;
    const version: u64 = @intCast(revision);
    if (c.clientHas(version)) return .unchanged(version);
    return .{ .version = version, .value = try db.select(Order, c, .{ .order = .{ .id = .asc } }) };
}
```

You choose the version, because only you know what it is: a revision column, a `max(updated_at)`, a counter the writer increments. It has to be known *before* the body is built, which is what lets [`c.clientHas`](../reference/ctx.md#reading) skip the query and not just the bytes. A handler that never checks still answers 304, because nilo compares on the way out, but it has already done the work.

The version is a `u64`. A timestamp in milliseconds fits. Text, such as an `updated_at` kept as a string, is one hash away:

```zig
const version = std.hash.Wyhash.hash(0, row.updated_at.view());
```

The tag is weak, `W/"1a"`, because a version says the content is the same and promises nothing about the bytes: the same value goes out gzipped to one client and plain to another. `If-None-Match` only ever compares weakly anyway. `headers` on the value go out on both the 200 and the 304, which is where a `Cache-Control` belongs; `.unchangedWith(version, headers)` is the 304 with them. Returning `.unchanged(version)` to a client that did *not* send the version is a 500 naming the route, because the handler skipped the work without checking.

`Versioned(?T)` is a compile error, because `null` would mean both "404" and "you have it"; a missing thing is `nilo.fail.notFound`. A `Versioned` inside a `Status` or a `Response` is also a compile error, and so is one under a `Cached` or an `Idempotent`, where a 304 decided for the first client would be replayed to everyone else. **Only a `GET` or a `HEAD` is answered 304.** A `PUT` that returns a `Versioned(T)` has already run when the tag is compared, so it answers its ordinary 200 with the `ETag` on it, whatever `If-None-Match` says. The API description puts the `ETag` on the 200 and lists a 304 beside it on a `GET` or a `HEAD`.

## JSON field names and union tags

**A struct becomes a JSON object and an enum becomes its tag name; one declaration on a type changes how its names or union tags are written.** That default covers nearly everything. The two cases it does not cover are common in REST APIs ([ADR 016](../adr/016-the-api-description-comes-from-the-signatures.md)). The full list is [JSON shapes in the reference](../reference/handlers.md#json-shapes).

**A float is written the way serde_json writes it.** The shortest digits that read back as the same value, with a whole number keeping its `.0` (`1.0`, `0.0`, `1000000000000000.0`) so a typed client can tell it from an integer, a sign-carrying exponent outside 1e-5 to 1e15 (`1e+16`, `1e-7`, never a 300-digit `f64::MAX`), an `f32` from its own digits (`1.1`), and `null` for infinity and NaN. It is the same on every path a value takes out, a `std.json.Value` and a `jsonStringify(self, jw: anytype)` included, and a body is read as before: `1` fills an `f64` ([ADR 096](../adr/096-a-byte-that-is-not-text-is-not-a-string.md)).

**A union is externally tagged by default**: `{"metrics":{…}}`, one object with one key, which is what `std.json` writes and what nilo sends if you say nothing. `.tag` asks for the other encoding, with the variant's name next to its own fields:

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

A variant carrying nothing is just the tag: `{"signal":"disabled"}`. Read as a request body, an object with the tag key twice is a 400 naming the key, since a client that keeps the other one would mean another variant ([ADR 016](../adr/016-the-api-description-comes-from-the-signatures.md)).

**`rename_all` spells names the way the wire wants them**: an enum's tags, a union's variant names, and a struct's field names.

| | `not_found` becomes |
|---|---|
| `.lowercase` | `notfound` |
| `.UPPERCASE` | `NOTFOUND` |
| `.camelCase` | `notFound` |
| `.PascalCase` | `NotFound` |
| `.SCREAMING_SNAKE_CASE` | `NOT_FOUND` |
| `.@"kebab-case"` | `not-found` |

The first two join the words rather than keeping the underscore, which is what serde does and what the names literally say. `.SCREAMING_SNAKE_CASE` is the one that keeps it. There is no `.snake_case`, because a Zig field name already is snake_case. Two names that end up the same are a compile error, because they would put the same key in an object twice.

### camelCase keys

**One declaration sends snake_case fields as camelCase keys.** Your Rows are snake_case because Postgres is, and your wire is camelCase because the browser is. Declaring it once is better than a mapping function written out field by field, which is what a DTO layer is. Nothing checks such a mapping against the Row it came from, so a column added to the Row reaches the wire only if somebody remembers the second file ([ADR 148](../adr/148-a-field-name-is-a-spelling-too.md)).

<!-- compiles -->
```zig
const Contact = struct {
    pub const nilo_json = .{ .rename_all = .camelCase };

    id: u32,
    full_name: []const u8,   // goes out as "fullName"
    partner_id: u32,         // and "partnerId"
};
```

The API description uses the same keys, so a generated client reads what the server sends. It costs nothing per request: the name is settled at compile time either way.

**A field no case rule reaches can be spelled on its own.** A column called `estimated_cost_amount_minor` that the frontend knows as `estimatedCostMinor` is one `.rename` entry, and the entry wins over the case rule for that field only ([ADR 168](../adr/168-one-field-can-be-spelled-on-its-own.md)):

<!-- compiles -->
```zig
const Summary = struct {
    pub const nilo_json = .{
        .rename_all = .camelCase,
        .rename = .{ .estimated_cost_amount_minor = "estimatedCostMinor" },
    };

    id: u32,
    estimated_cost_amount_minor: i64,   // goes out as "estimatedCostMinor"
    due_at: ?[]const u8,                // and "dueAt", by the case
};
```

`.rename` on its own, with no case rule, is fine too. Each of these is a compile error where the marker is written: a name that is not a field, a spelling that is the field's own name, and an entry that lands on a key another field already uses.

**The spelling applies to a request body too.** The same Row you send can be posted: a body is matched against the renamed keys (`fullName`, not `full_name`), and a 400 about a key quotes the spelling the client sent or should have sent. A form and a query string read field names as written, so a struct with `rename_all`, `.rename` or `.skip` used as one of those is a compile error naming the route: give it a struct of its own.

**A field can stay off the wire.** `.skip = &.{"password_hash"}` names fields that are never written in a response and never read from a body. A client sending the key gets the answer any unknown key gets, and the field is left out of the API description. Because nothing fills a skipped field when a body is read, it needs a default value (or a `?T`) if the struct is ever read; a struct that is only returned needs nothing.

**A key can be left out when it has no value.** Go's `omitempty` is two entries here ([ADR 282](../adr/282-an-answer-can-leave-a-field-out.md)): `.omit_null = true` leaves out every optional field that is null, and `.omit_empty = &.{"root_attributes"}` leaves out the named lists that are empty. A list you do not name is still written as `[]`, because an empty list is often the answer.

<!-- compiles -->
```zig
const Page = struct {
    pub const nilo_json = .{ .omit_null = true, .omit_empty = &.{"root_attributes"} };

    id: u32,
    title: ?[]const u8,                  // no "title" key when null
    root_attributes: []const []const u8, // no key when empty
    tags: []const []const u8,            // "tags":[] when empty
};
```

The generated writer does it, so the type is still written at full speed and still takes `rename_all`. The API description stops listing those fields as `required`. It means nothing when a body is read: a `?T` or a field with a default is already optional there. As with `rename_all`, a type that nilo's own writer cannot handle (see below) is a compile error rather than a quiet `null`.

A renamed or omitting struct that nilo's own writer cannot handle is also refused. The writer is deliberately narrow: one shape it does not recognise (a tuple, an array of bytes, an untagged union, a type that writes its own JSON without describing it, anything more than eight levels deep) sends the whole value to `std.json`, which ignores the marker.

**A type that writes its own JSON and describes it is not one of those.** `sql.Uuid`, `sql.Timestamp`, `sql.AsText` and `id.Uuid` all carry a `nilo_openapi` next to their `jsonStringify`, and a marker may only name a scalar. So nilo knows the value is one string or one number and keeps writing the object around it ([ADR 148](../adr/148-a-field-name-is-a-spelling-too.md)). A Row holding uuids can rename its fields, which is the ordinary case and the whole reason this was reopened.

That also makes such a response faster whether or not it renames anything, by more than you might expect: the writer is chosen for the *whole* value, so a single field it could not handle used to send every string next to it to `std.json` too. **250ns → 165ns on a 305-byte row with three uuids in it.** Your own type gets the same speed by writing the same two declarations.

**The marker applies to one type and is not inherited.** A struct renames its own fields. A union renames its *variants* and leaves a payload struct's fields to that struct's own marker. A nested struct with no marker keeps its own spelling.

**Why the `jsonParse` line is needed.** For a struct it is not: nilo reads a body into a struct itself and reads the marker while it does. An enum or a union that is read back does need it, because `std.json` picks the parser for those and nothing can add a declaration to a type you wrote, so the type hands over a parser nilo supplies. Leave the line off if the type is only ever sent; nilo tells you if you add it to a struct, or to a type whose JSON spelling was never changed.

The generated API description follows either encoding, so a client generated from it reads what the server actually sends ([the API description](./openapi.md)).

## When a response is sent

**A response is written in one go, and only once.** There is no "start the response, then change your mind" state, so a header set too late is refused with an error rather than lost. If you need to decide as you go, use [a stream](./streaming.md); even there the head goes out first and cannot change after that.

The response is on the wire before the connection next waits for the client. For a client that sends a request and waits for the answer, which is every browser, that is the moment `send` returns. A client that pipelines, sending its next request before reading this answer, gets the answers in one write instead of one each. It was not waiting, and the batch is bounded by `write_buffer` ([ADR 201](../adr/201-a-response-is-flushed-before-the-connection-waits.md)).

Sending twice is an assertion failure, not two responses on the wire. A handler that fails *after* sending gets its connection closed, because a half-sent response cannot be taken back and the next request on that connection would read bytes of unclear origin. It is logged:

```
warning: handler GET /report failed after answering: WriteFailed
```

## Keep-alive

**nilo decides whether the connection stays open.** HTTP/1.1 keeps it open unless the client says `Connection: close`. HTTP/1.0 closes it unless the client asks otherwise. A failed stream or an unreadable body closes it. [`c.keepAlive()`](../reference/ctx.md#reading) reports what will happen. A handler never has to think about it: a 404 is a normal answer, not a reason to hang up.

The response only mentions it when there is something to say: `Connection: close` when it is closing, `Connection: keep-alive` to an HTTP/1.0 client being kept, and nothing on an HTTP/1.1 connection staying open, because that is what HTTP/1.1 means by default ([ADR 197](../adr/197-a-response-says-when-it-was-sent.md)). Every response also carries a `Date`, which a cache in front reads to decide how old the answer is.

## Compression

**Compression is off unless you turn it on.** One line turns it on:

<!-- compiles: body -->
```zig
try app.compress(.{});
```

From then on, every answer that is text, at least a kilobyte long, and going to a client whose `Accept-Encoding` accepts gzip goes out gzipped, whether it came from `sendJson`, `sendText`, `send` or a typed handler returning a value. The response carries `Content-Encoding: gzip`, `Vary: Accept-Encoding` and the compressed length. A client that sent no `Accept-Encoding`, or `gzip;q=0`, gets the body unchanged and no `Content-Encoding`.

| | Default |
|---|---|
| `min_bytes` | `1024`: shorter bodies go out as they are; compressing a hundred bytes makes them longer |
| `max_bytes` | `1048576` (1 MiB): longer bodies go out as they are, because gzipping one holds its thread for the whole of it, about 7 ms a megabyte at `.default` and 130 ms for 20 MB. `0` means no limit |
| `level` | `.default`, zlib's level 6. `.fastest` is level 1, roughly a fifth larger and a little quicker; `.best` is level 9, under one percent smaller and five to nine percent slower. In a libdeflate build (below) they are levels 1, 6 and 7 |

The options are in [the reference](../reference/app.md#compress-options).

Text means the same list static files use: `text/*`, JSON, JavaScript, XML, WASM, and the `+json` and `+xml` structured types. A PNG, a woff2 or an `application/octet-stream` is left alone, as is a body under `min_bytes` or over `max_bytes`, a 204, and an answer whose handler set `Content-Encoding` itself: a body you gzipped is not gzipped twice. **What a handler said about the representation stands**: a 206, a 416, an answer with a `Content-Range` and one with `Cache-Control: no-transform` are never compressed, because a range is an offset into the plain bytes and `no-transform` is a request not to. A strong `ETag` on an answer that is compressed goes out weak (`W/"…"`), since the gzipped and the plain body are different bytes and a strong tag promises identical ones. A HEAD carries the length its GET would have.

**Three things are never compressed here.** A static file, because it was gzipped once when the App was built and that copy costs nothing per request ([Static files](./static-files.md#compression)). A stream, because it has no whole body to compress and would hold a compressor across every write. An event stream, because it must never be buffered at all ([ADR 211](../adr/211-a-response-is-compressed-on-a-compressor-borrowed-from-a-pool.md)).

**What it costs.** One compressor per thread, about 288 KB each, allocated once when the chains are resolved and never on a connection's stack: 4.6 MB on sixteen threads. One arena allocation on a compressed request, for the compressed body, and none on a request that is not compressed. And the gzip itself: for a 4 KB JSON answer at `.default`, about 37 µs on one core, of which 6 µs is resetting the compressor. `zig build bench-compress` prints the table for your machine. Nothing per connection, and nothing on a request under the threshold, which a test checks.

**A build can gzip in a quarter of the time.** The default compressor is the standard library's; passing `.libdeflate = true` to the dependency gzips with [libdeflate](https://github.com/ebiggers/libdeflate) instead, for answers and for static files alike ([ADR 248](../adr/248-gzip-is-libdeflate-when-a-build-asks-for-it.md)):

```zig
// build.zig
const nilo = b.dependency("nilo", .{ .target = target, .optimize = optimize, .libdeflate = true });
```

Nothing in your code changes, and the same bodies go out gzipped. A 4 KB JSON answer takes about 9 µs rather than 37 and comes out a little smaller, a megabyte about 2.4 ms rather than 7, and a server on sixteen threads holds less memory than the default build, because a libdeflate compressor costs nothing resident until it is used. What you pay is about 42 KB of binary and a C library compiled into it, with no libc needed; a build without the flag fetches and compiles none of it.

## Content types

| Returned | Sent as |
|---|---|
| `void` | no body, and no `Content-Type` either |
| `Str`, `[]const u8` | `text/plain` |
| `FileBody` | its `content_type`, `application/octet-stream` by default |
| a type with `nilo_content_type` | that, and the bytes its `nilo_write` wrote. See [below](#xml-csv-and-other-formats) |
| anything else | `application/json` |

A failure is always `application/json`, whether it came from a `fail.*` function, from an error, or from nilo refusing a request. See [Errors](./errors.md).

For anything else, use `c.send(status, content_type, bytes)`, or `c.stream(status, content_type)` when the length is not known yet.

## XML, CSV and other formats

**A type of yours can write its own body under a content type it names.** nilo answers JSON, and it will not learn XML, CSV or a template language ([ADR 157](../adr/157-a-type-can-write-its-own-answer.md) says why). What it will do is send bytes your type wrote, under the label the type names. That is what a consumer that only reads XML needs, and before this a `*Ctx` handler calling `c.send` was the only way to get it:

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

Return it the way you would return a struct (bare, in a `?`, in a `Status(201, …)` or a `Response(…)`) and the wrappers mean what they always mean. The difference from `c.send` is that the route is described: the document names `application/xml`, and says what the body looks like if the type adds `pub const nilo_openapi = .{ .type = "string" };`. See [the reference](../reference/handlers.md#a-type-that-writes-its-own-answer).

Write both declarations or neither: a content type with no `nilo_write`, or the other way round, is a compile error naming the route. The same content type with `nilo_decode` reads the format on the way in ([Requests](./requests.md#protobuf-and-other-formats)).

**A protobuf message answers in the spelling it was asked in**: a struct with a `wire` table goes out as protobuf to a request that sent protobuf and as JSON to everything else, with no declaration ([Requests](./requests.md#protobuf-and-other-formats)).

Static files get their type from the file extension. See [Static files](./static-files.md).
