# Requests

**Everything a request carries (path, query, body, headers), and the handler argument that reads each one.**

**Reference:** [handler arguments](../reference/handlers.md#handler-arguments), [reading a request from `Ctx`](../reference/ctx.md#reading), [`Body`](../reference/streaming.md#body) · **Design:** [Request input](../design/request-input.md)

## Path params

**A `:name` in the pattern arrives as the argument in the same position, and the argument's type decides the conversion:**

```zig
try app.get("/users/:id", getUser);
fn getUser(db: *Db, id: u32) !User { … }

try app.get("/posts/:year/:slug", getPost);
fn getPost(year: u16, slug: nilo.Str) !Post { … }
```

The type can be `u32`, `i64`, `f64`, `bool`, an enum, or a `Str` for the text as it arrived. A value that doesn't convert is a 400 saying which param and what was expected, and your handler doesn't run. Values are percent-decoded before conversion.

A `*` as the last segment matches the whole rest of the path and arrives under the name `*`. That is not a legal Zig identifier, so you read it from a `*Ctx`: [`c.param("*")`](../reference/ctx.md#reading).

## Query params

**Query params arrive as a struct, one field per param**, because unlike a path param a query param is named and may be missing:

```zig
const Search = struct {
    q: Str,             // no default: absent is a 400 saying which one
    page: u32 = 1,      // a default is what "absent" means
    sort: Sort = .newest,
    tag: ?Str = null,   // optional: absent is null
};

fn search(db: *Db, params: Query(Search)) ![]const Item {
    return db.search(params.value.q.view(), params.value.page);
}
```

The types are checked before your handler runs, so the answers to a client that gets it wrong are already written:

```
?q is required
?page has to be a whole number, not "soon"
?sort is not one of the known choices (newest, oldest): "sideways"
```

Values arrive percent-decoded, with `+` counting as a space the way an HTML form sends one. `Query(Search)` is an ordinary struct, so a test builds one directly (`listUsers(&db, .{ .value = .{ .page = 2 } })`) and never touches a query string.

For one-off reads, [`c.query("q")`](../reference/ctx.md#reading) on a `*Ctx` gives a `?Str` and converts nothing. [ADR 011](../adr/011-the-query-string-is-a-struct-of-your-own.md) explains why the struct is the default.

## JSON bodies

**Any struct argument that isn't a `Query(T)`, a service or a resolved value is the request body, parsed from JSON:**

```zig
const NewUser = struct { name: Str, age: u32, plan: Plan = .free };

fn createUser(db: *Db, incoming: NewUser) !User {
    return db.add(incoming);
}
```

A body that does not fit gets the same treatment as a query param: a 400 that names the field and what was wrong with it.

```
the request body has a field "titl" this endpoint does not know. It takes: title, done (optional)
the request body is missing "age" (a whole number)
"plan" is not one of the known choices (free, paid): "gold"
"plan" has to be one of free, paid, not a number
"name" has to be text, not a number
the request body is not valid JSON — it stops making sense at line 1, column 12
the request body is empty. This endpoint expects a JSON object with: title, done (optional)
```

A field with a default may be absent, exactly as in a query struct. Working out which message to send costs a second parse, and only a request that was already going to be refused pays it.

Nested objects and lists are named by where the problem is, not by the top-level field that contains it:

```
the request body is missing "address.city" (text)
the request body has a field "address.zip" this endpoint does not know. It takes: street, city
"lines[1].qty" has to be a whole number, not text
```

A body field that is an internally tagged union ([ADR 016](../adr/016-the-api-description-comes-from-the-signatures.md)) is described the same way, naming the variant it was read as:

```
"condition.signal" is not one of the known variants (metrics, logs): "traces"
the request body has a field "condition.metric_nme" the "metrics" variant does not know. It takes: signal, metric_name, agg (optional)
the request body is missing "condition.signal", which names the variant: one of metrics, logs
```

A tagged union that is the whole body is described the same way, with the discriminator and the variants:

```
the request body is missing "kind", which names the variant: one of loose, tight, off
"kind" is not one of the known variants (loose, tight, off): "nope"
the request body has a field "x" the "tight" variant does not know. It takes: kind, n
the request body is empty. This endpoint expects an object whose "kind" is one of loose, tight, off
```

**To accept a body that carries keys your type does not list**, say so on the type with `pub const nilo_json = .{ .unknown_fields = .ignore };`. That is for a webhook or an OTLP/HTTP JSON receiver whose sender adds fields over time; it applies to that struct alone and not to the ones it holds ([reference](../reference/handlers.md#skipping-the-keys-a-body-struct-does-not-know)).

**To answer JSON of the wrong shape with a 422 rather than a 400**, the line an axum server draws and its clients read, say so on the body's type with `pub const nilo_json = .{ .misfit = 422 };`. Text that is not JSON, an empty body and one nested past 64 levels stay a 400, because none of them is a body of any shape. A missing field, a value of the wrong kind, a key the type does not know, a key given twice and a body that is not an object become a 422 with the same sentence. It holds under `Bound(T)` for what the binding cannot collect, and the API document lists the 422 beside the 400 ([reference](../reference/handlers.md#answering-json-of-the-wrong-shape-with-a-422), [ADR 251](../adr/251-json-that-does-not-fit-can-be-a-422.md)).

A struct with many fields lists the first of them and says how many it left out: `It takes: alpha, bravo, charlie, and 9 more`.

That goes eight levels down, the same depth the API description and the staleness check follow. Below that there is no field name left to quote, so the 400 says which limit it hit instead of saying nothing:

```
the request body is valid JSON and does not fit this endpoint, but it is nested
deeper than 8 levels — which is as far as nilo follows a body — so it cannot say
which part is wrong. The mistake is somewhere below that.
```

That message means the shape is too deep to name, not that the depth is refused: a body that *fits* is parsed however deep it goes.

A `Str` field lives in the request arena, so like every `Str` it stops being valid when the request ends. `keep` it if the value goes into a service.

### Reporting every bad field at once

**`Bound(T)` collects every bad field and hands them to the handler**, where the plain 400 above names only one, because the parse stops at the first thing it cannot do:

```zig
fn placeOrder(b: nilo.Bound(NewOrder)) !nilo.Status(201, Order) {
    const order = b.value() orelse return b.fail();
    ...
}
```

`b.fail()` is a 422 naming each one, and `b.failures()` is there when the answer needs a shape of its own. `b.must("total", order.total > 0, "has to be more than nothing")` adds a rule of your own to the same answer, so an endpoint does not end up rejecting requests in two different shapes. `Bound(Query(T))` does the same for the query string. The full explanation, including the three cases that stay a plain 400, is under [Forms](./forms.md#collecting-every-field-error-bound), where it matters most. The type is [`Bound(W)`](../reference/handlers.md#boundw) in the reference.

One difference to know: in JSON a quoted value **is** text, so `{"quantity":"12"}` fails as `"quantity" has to be a whole number, not text`, not as a number that would not parse. A form has only text to work with; a JSON body says what kind each value is.

**A number in a body is read by the same rule a query's is** ([ADR 084](../adr/084-a-number-in-a-request-is-not-a-zig-literal.md)). Digits, a `-` where the type has one, and for a real number a fraction and an exponent, so a quoted `"10"` is still ten and `"1_0"`, `"+7"` and `"nan"` are refused. A whole number is digits: `5.0` and `1e2` are not read as 5 and 100, and `1e999` is not read as infinity. A number that is the right kind and does not fit its field says so and quotes the number, as a query does:

```
"age" has to be a whole number, not 300, which is outside 0 to 255
"qty" has to be a whole number, not 1.5
"count" has to be a whole number, not -1, which is outside 0 to 4294967295
```

Under `Bound` those are collected with the other fields. A key that appears twice in an object is a 400 naming it, and nilo does not guess which one was meant.

### PATCH: telling "not sent" from "sent as null"

**`Patch(T)` tells apart a field that was not sent, one sent as null, and one sent with a value.** `?T` has two states and a PATCH needs three. With `due: ?Str = null`, the bodies `{}` and `{"due":null}` arrive identical, so "leave the due date alone" and "clear the due date" cannot be told apart. `Patch(T)` keeps all three:

```zig
const EditTodo = struct {
    title: nilo.Patch(nilo.Str) = .absent,
    due: nilo.Patch(nilo.Str) = .absent,
};

fn editTodo(store: *Store, id: u32, incoming: EditTodo) !?Todo {
    const current = store.find(id) orelse return null;

    const due: ?[]const u8 = switch (incoming.due) {
        .absent => current.due,   // not mentioned: leave it
        .cleared => null,         // sent as null: empty it
        .value => |v| v.view(),   // sent with a value
    };
    …
}
```

The `= .absent` default is required: it is what "the field was not in the body" means, and it also makes the field optional in the generated description. Where "leave it" and "clear it" really are the same, `incoming.due.orNull()` merges the two.

See [ADR 025](../adr/025-a-patch-needs-three-answers-and-an-optional-has-two.md).

### Reading the body yourself

From a `*Ctx`:

| | |
|---|---|
| `c.body()` | the whole body as a `Str`, read once into the request arena |
| `c.json(T)` | the body parsed into `T`, the same as a struct argument |
| `c.bodyStream()` | the body in pieces, below |

**`c.body()` reads the whole body and refuses anything past 1 MB.** That is right for JSON and wrong for a file.

It takes arena memory as the bytes arrive, not as `Content-Length` promises them, so a client that announces a megabyte and then trickles holds a page, not a megabyte ([ADR 083](../adr/083-a-body-is-taken-as-it-arrives.md)). A body that arrives normally pays nothing for this: under a page it is still one allocation, over a page it is two.

**A body sent as `Content-Encoding: gzip` is decompressed before anything reads it.** `c.body()`, `c.json`, a struct argument and a `Form(T)` all see the JSON, not the compressed stream, just as they never see the framing. The stock OpenTelemetry Collector and most agents that push to a server gzip by default, and until [ADR 089](../adr/089-a-body-under-an-encoding-other-than-gzip-is-refused.md) that default got a 415.

The limits: the compressed bytes are bounded by `max_body`, and so is what they decompress to. That is checked against the length the stream announces before a byte is decompressed, so a small body that would expand into a large one is a 413, not a megabyte. A stream that does not decode is a 400 naming the coding. Every other coding (`br`, `deflate`, `zstd`, two stacked) is still a 415 naming the header. A gzipped request costs one more arena allocation, of exactly the decompressed size; a request that is not gzipped pays nothing.

`c.bodyStream()` is the exception: a stream hands bytes out as they arrive and holds nothing, so there is nowhere to decompress into, and a gzipped body on a streaming route is a 415 that says so.

## Protobuf and other formats

**A struct with a `wire` table is read as protobuf or as JSON, whichever the request sent, and answered in the same.** One function serves a browser's `fetch` in JSON and another service's client in protobuf, and is a gRPC method too:

<!-- compiles -->
```zig
const SumRequest = struct {
    pub const wire = .{ .a = 1, .b = 2 };
    a: i32 = 0,
    b: i32 = 0,
};

const SumReply = struct {
    pub const wire = .{ .total = 1 };
    total: i32 = 0,
};

fn sum(in: SumRequest) SumReply {
    return .{ .total = in.a + in.b };
}
```

`Content-Type: application/proto` is protobuf, the field numbers [`nilo_proto`](./proto.md)'s, and anything else is JSON, as for any struct. Bytes that are not the message are a 400 that says what was wrong with them.

**A format nilo does not know is read by the type itself**: declare the content type and a `nilo_decode` that turns the body's bytes into the value, and the route reads it only when it arrives under that label. MsgPack, a vendor's binary or a CSV upload all fit; see [the reference](../reference/handlers.md#a-body-in-another-format) for both, and what each refuses.

## Streaming a large body

```zig
fn upload(c: *nilo.Ctx, store: *Store) !Receipt {
    var incoming = c.bodyStreamWith(.{ .max_bytes = 8 * 1024 * 1024 }) catch
        return nilo.fail.tooLarge("this endpoint takes up to 8 MB", .{});

    var buf: [64 * 1024]u8 = undefined;
    while (try incoming.read(&buf)) |part| try store.append(part);

    return .{ .bytes = incoming.seen() };
}
```

**A body read in pieces allocates nothing at all.** The 64 KB above is the only memory involved. It does not even take the one buffer a response stream takes, because a body reader already has somewhere to put bytes. `Content-Length` and chunked bodies look the same from here, exactly as they do to `c.body()`: a handler asks for the body, not for how it arrived. The reader is [`Body`](../reference/streaming.md#body) in the reference.

Measured on the streaming example: 5 × (a 3 MB upload plus a 50,000-row streamed report) moved the server's RSS by **72 KB**.

`max_bytes` defaults to 64 MB and must be a number, because a chunked body announces no size, and "however much they send" would let a client decide how much of your memory to use. A `Content-Length` past the limit is refused before a byte is read.

**A client that asks first is answered first.** A client sending `Expect: 100-continue` (curl does, for bodies over 1 KB) waits for the server before it sends the body. nilo answers `100 Continue` only when it commits to reading, so a request refused before that gets its final status and **never sends the body at all**: over the limit, no such route, wrong method, or a handler that never asks for the body ([ADR 073](../adr/073-a-header-is-answered-as-asked-or-refused.md)). There is nothing to turn on and nothing to write.

| | |
|---|---|
| `incoming.read(&buf)` | the next piece, or `null` at the end |
| `incoming.writeTo(w)` | pump the lot into a `std.Io.Writer`, returning the count |
| `incoming.discardRest()` | give up on the rest, deliberately |
| `incoming.seen()` | bytes read so far |
| `incoming.size()` | what the request announced, or `null` if it was chunked |
| `incoming.reader` | a plain `std.Io.Reader`, for handing to the standard library |

A body left half-read is fine: nilo discards the rest so the connection is clean for the next request.

**An upload the client cut short is an error, not a short file.** If the connection ends while bytes are still owed (`Content-Length: 1000000` and the client stops at 300,000), `read`, `writeTo` and `discardRest` fail with `error.BodyTruncated`, which is a 400 if you let it through, and the connection is closed afterwards. The same cut under `c.body()` is the same 400, `the request body ended before all of it had been sent`. You do not need to compare `seen()` with `size()` to know the file is whole.

See [ADR 019](../adr/019-a-request-that-lasts-is-still-one-request.md).

## Headers, method and path

```zig
c.method            // .GET, .POST, …
c.path()            // the path, without the query string
c.header("X-Token") // a request header, name matched case-insensitively
c.param("id")       // a path param, percent-decoded
c.query("q")        // a query param, percent-decoded
```

**[`c.header`](../reference/ctx.md#reading) returns the first header of that name.** To read the others, or in a middleware that does not know the names in advance, walk them all:

```zig
var it = c.headers();
while (it.next()) |h| {
    // h.name and h.value are both Str, and both die with the request
    std.log.debug("{s}: {s}", .{ h.name.view(), h.value.view() });
}
```

Neither allocates: both read the head where it already is.

The whole request head has to fit in the connection's `read_buffer` (16 KB by default, which is enough for a browser behind a single sign-on). A head that doesn't fit is answered with a 431. Raise it in `listen()` if your clients send cookies bigger than that.
