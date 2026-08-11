# Requests

Everything a request carries, and the argument that asks for it.

## Path params

A `:name` in the pattern arrives as the argument in the same position. The type
is the conversion:

```zig
try app.get("/users/:id", getUser);
fn getUser(db: *Db, id: u32) !User { … }

try app.get("/posts/:year/:slug", getPost);
fn getPost(year: u16, slug: zfast.Str) !Post { … }
```

`u32`, `i64`, `f64`, `bool`, an enum, or a `Str` for the text as it arrived. A
value that doesn't convert is a 400 saying which param and what was expected —
your handler doesn't run. Values are percent-decoded before conversion.

A `*` as the last segment matches the whole rest of the path and arrives under
the name `*`, which is not a legal Zig identifier — so that one is read from a
`*Ctx`: `c.param("*")`.

## Query params

A path param is positional; a query param is named and may be missing. So it
arrives as a struct, one field per param:

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

The types are checked before your handler runs, so the answers to a client that
gets it wrong are already written:

```
?q is required
?page has to be a whole number, not "soon"
?sort is not one of the known choices (newest, oldest): "sideways"
```

Values arrive percent-decoded, with `+` counting as a space the way an HTML form
sends one. `Query(Search)` is an ordinary struct, so a test builds one directly —
`listUsers(&db, .{ .value = .{ .page = 2 } })` — and never touches a query
string.

For one-off reads there is `c.query("q")` on a `*Ctx`, which gives a `?Str` and
converts nothing. See
[ADR 0012](../adr/0012-the-query-string-is-a-struct-of-your-own.md) for why the
struct is the default.

## JSON bodies

Any struct argument that isn't a `Query(T)`, a service or a resolved value is the
request body, parsed from JSON:

```zig
const NewUser = struct { name: Str, age: u32, plan: Plan = .free };

fn createUser(db: *Db, incoming: NewUser) !User {
    return db.add(incoming);
}
```

A body that does not fit gets the same treatment a query param does — the field
named, and what was wrong with it:

```
the request body has a field "titl" this endpoint does not know. It takes: title, done (optional)
the request body is missing "age" (a whole number)
"plan" has to be one of free, paid, not text
"name" has to be text, not a number
the request body is not valid JSON — it stops making sense at line 1, column 12
the request body is empty. This endpoint expects a JSON object with: title, done (optional)
```

A field with a default is what "absent" is allowed to mean, exactly as in a query
struct. Working out which of these to say costs a second parse, which is paid
only by a request that was already going to be refused.

A `Str` field lives in the request arena, so — like every `Str` — it stops being
valid when the request ends. `keep` it if the value goes into a service.

### Reading the body yourself

From a `*Ctx`:

| | |
|---|---|
| `c.body()` | the whole body as a `Str`, read once into the request arena |
| `c.json(T)` | the body parsed into `T`, the same as a struct argument |
| `c.bodyStream()` | the body in pieces, below |

`c.body()` reads whole and is refused past **1 MB**. That is right for JSON and
wrong for a file.

## Bodies too big to hold

```zig
fn upload(c: *zfast.Ctx, store: *Store) !Receipt {
    var incoming = c.bodyStreamWith(.{ .max_bytes = 8 * 1024 * 1024 }) catch
        return zfast.fail.tooLarge("this endpoint takes up to 8 MB", .{});

    var buf: [64 * 1024]u8 = undefined;
    while (try incoming.read(&buf)) |part| try store.append(part);

    return .{ .bytes = incoming.seen() };
}
```

The 64 KB above is the only memory involved — **this allocates nothing at all**,
not even the one buffer a response stream takes, because a body reader has
somewhere to put bytes already. `Content-Length` and chunked look the same from
here, exactly as they do to `c.body()`: a handler asks for the body, not for the
way it arrived.

Measured on the streaming example: 5 × (a 3 MB upload plus a 50,000-row streamed
report) moved the server's RSS by **72 KB**.

`max_bytes` has a default of 64 MB and there has to be a number, because a
chunked body announces no size and "however much they send" is a client's
decision about your memory. A `Content-Length` past the ceiling is refused before
a byte is read.

| | |
|---|---|
| `incoming.read(&buf)` | the next piece, or `null` at the end |
| `incoming.writeTo(w)` | pump the lot into a `std.Io.Writer`, returning the count |
| `incoming.discardRest()` | give up on the rest, deliberately |
| `incoming.seen()` | bytes read so far |
| `incoming.size()` | what the request announced, or `null` if it was chunked |
| `incoming.reader` | a plain `std.Io.Reader`, for handing to the standard library |

A body left half-read is fine — zfast discards the rest so the connection is
clean for the next request.

See [ADR 0020](../adr/0020-a-request-that-lasts-is-still-one-request.md).

## Headers, and the rest

```zig
c.method            // .GET, .POST, …
c.path()            // the path, without the query string
c.header("X-Token") // a request header, name matched case-insensitively
c.param("id")       // a path param, percent-decoded
c.query("q")        // a query param, percent-decoded
```

The whole request head has to fit in the connection's `read_buffer` (8 KB by
default); one that doesn't is answered with a 431. Turn it up in `listen()` if
you serve clients with enormous cookies.
