# Handlers

**What a handler's arguments mean, what it may return, and how its JSON is shaped.**

**Guide:** [Handlers](../guide/handlers.md), [Requests](../guide/requests.md), [Forms](../guide/forms.md), [Responses](../guide/responses.md) · **Design:** [Typed handlers](../design/typed-handlers.md), [Request input](../design/request-input.md), [Responses](../design/responses.md), [JSON](../design/json.md)

## Handler arguments

| Argument | Passed in |
|---|---|
| `*Ctx` | the request itself |
| `*Db`, `*const Config` | a service, by type |
| `u32`, `f64`, `Str`, `bool`, an enum | the path param, on a route with exactly one |
| `Path(T)` | the path params, read by name into a struct; required from two params up (see [`Path(T)`](#patht)) |
| a type with `nilo_parse` | also a path param; `sql.Uuid` is one |
| `Within(1, 200)`, `Within(0.0, 1.0)` | a number inside a range, whole or real; `.value` is the number |
| `Text(…)`, `Email`, `Many(T, …)` | text, an address, a list with a length; `.value` is the `Str` or the slice |
| `Query(T)` | the query string as a struct |
| `FromHeader("X-Staff-Id", T)` | one request header, converted like a path param |
| `Authorization(.bearer)`, `Authorization(.{ .basic = "realm" })` | the `Authorization` header as one scheme. Missing, or another scheme, is a 401 with the challenge header |
| `Idempotent(Replays, .{ .by = fn })` | the `Idempotency-Key` header, which makes the route answer once per key: a retry gets the stored answer back and the handler does not run |
| `Cached(Pages, .{ .ttl_s = 60 })` | the answer stored for a minute under the path and query: the next request gets it back and the handler does not run. GET and HEAD only |
| `Form(T)` | the body as an HTML form, urlencoded or multipart |
| `Bound(W)` | any of the three above, with its failures handed to you instead of a 400 |
| `Session(T)` | the session, read from its cookie |
| `Bearer(T)` | the same sealed value, read from `Authorization: Bearer …` |
| `std.mem.Allocator` | the request arena |
| `std.Io` | the server's loop, for a `std.Io.Queue` or `std.Io.Event` a handler waits on while a fiber from `app.spawn` answers ([ADR 244](../adr/244-a-handler-is-given-the-loop-it-runs-on.md)). A resolver may take it too |
| a type with `nilo_resolve` | a resolved value |
| a struct with a `wire` table | the body as a protobuf message, read as JSON or protobuf by its `Content-Type`; the answer goes back in the same ([below](#a-body-in-another-format)) |
| a type with `nilo_content_type` and `nilo_decode` | the body, read by the type itself, and only under its own content type |
| any other struct | the body, parsed from JSON |

**A body field may be `Patch(T)`, which tells "not sent" apart from "sent as null"**: `.absent`, `.cleared`, `.value`. Give it `= .absent` as its default; `.orNull()` merges the two empty cases.

### Types that parse themselves

**A path param may be a type that parses itself.** Give a type `pub fn nilo_parse(text: []const u8) ?Self`, and nilo calls it with the path segment and answers 400 when it returns null, so a malformed uuid is rejected at the router instead of in every handler. `sql.Uuid` already has it:

<!-- compiles -->
```zig
fn showDoc(db: *Db, c: *nilo.Ctx, doc_id: sql.Uuid) !?Doc {
    return db.find(Doc, c, doc_id);
}
```

on `/docs/:doc_id` is all it takes. What the document says about the param also comes from the type: a `Uuid` publishes `{"type":"string","format":"uuid"}` through its `nilo_openapi`, so a generated client gets the format instead of a bare string. The declaration is looked up by name and never imported, which is what lets a module in the bottom layer provide it ([ADR 113](../adr/113-a-path-param-can-parse-itself.md)).

**A `Query(T)` or `Form(T)` field can be one too**, for the same reason: a value arriving one way has one meaning, so `/deals/:id` and `?actor=<uuid>` cannot read the same type in two different ways ([ADR 113](../adr/113-a-path-param-can-parse-itself.md)). So a field is a `Str`, a number, a `bool`, an enum, **or a type with `nilo_parse`** (`sql.Uuid` and `sql.Timestamp` both are), optionally wrapped in `?`, and a `Form(T)` field may also be an `Upload`.

**A body field can be one as well** ([ADR 166](../adr/166-a-body-field-that-parses-itself.md)). `std.json` reads the body, and it picks the parser by looking for `jsonParse` on the type; `sql.Uuid` and `sql.Timestamp` have one, and a `[]const sql.Uuid` reads a list of them. A type of your own that parses itself adds one line next to `nilo_parse`:

```zig
pub const jsonParse = nilo.jsonParseFor(@This());
```

A body containing a type that parses itself but has no `jsonParse` is a compile error naming the route. The 400 for text the type rejected quotes it back, the same way a query value's does (`"sku" has to be a Sku, not "abc"`), and a type can describe itself better than its name with `pub const nilo_expects = "a ticket number like T-1234"`, which every error message then uses.

### `Within(min, max)`

**`Within(min, max)` is a number inside a range, both ends inclusive** ([ADR 167](../adr/167-a-whole-number-inside-a-range-is-a-type.md)). It is a type that parses itself, so it can be used anywhere a `u8` can. A value outside the range is rejected with `?limit has to be a whole number from 1 to 200, not "500"`, and the document describes it with `minimum` and `maximum`. The number is `.value`; a default goes through `.of`, which checks it against the range while compiling. **A bound written with a point makes it a real number**: `Within(0.0, 1.0)` holds an `f64` (`Within.Number` is the type), is read the way an `f64` field is (`nan`, `inf`, `1e999` and a hex float are refused), says `a number from 0 to 1` in a 400, and is `type: number` with `minimum` and `maximum` in the document. A bound that is not a number, a bound the wrong way round and a default outside the range are compile errors:

<!-- compiles -->
```zig
const ListQuery = struct {
    limit: nilo.Within(1, 200) = .of(50),
    offset: u32 = 0,   // refuses -1 already, and the document says `minimum: 0`
};
```

```zig
const Rated = struct {
    score: nilo.Within(0.0, 1.0) = .of(0.5),   // an f64, 0 to 1
    stars: nilo.Within(1, 5),                    // a u3, 1 to 5
};
```

### `Text`, `Email` and `Url`

**`Text(.{ .min, .max, .check, .said })` is text with a shape, and `Email` and `Url` are presets of it** ([ADR 193](../adr/193-text-with-a-shape-is-a-type-and-a-rule-about-the-struct-is-a-function-on-it.md)). It is a `Str` that parses itself, usable wherever a `Str` is, rejected with one sentence wherever it appears, and described with `minLength`, `maxLength` and `format`. `min` and `max` count code points. `check` is a `fn ([]const u8) bool` of your own and needs `said` next to it: its error sentence, in the same form as `must`'s. A `Text` never quotes the text back (`"password" has to be text of 10 to 72 characters, not 7`), but the presets do. The `Str` is `.value`, with `view`, `len`, `eql` and `blank` forwarded; `.of("…")` is a default, checked against the shape while compiling. Each of these is a compile error: bounds in the wrong order, a `Text` with no bound and no check, a check with no `said`, and a default outside the shape.


### `Many(T, .{ .min, .max })`

**`Many(T, opts)` is a list with a length** ([ADR 266](../adr/266-a-list-with-a-length-is-a-type.md)). The slice is `.value` (a `[]const T`) and `len()` is forwarded; `.of(&.{…})` is a default, checked against the count while compiling. A list outside the bound is a 400 naming the field, the bound and the count (`"tags" has to be a list of 1 to 5 items, not a list of 7`), a bad element is named by its position (`"tags[2]"`), `Bound` collects it beside the other fields, and the document says `minItems` and `maxItems` around the element's own schema. It is read where a list is read: a JSON body and a form (every value under one name is counted). A query string is a compile error naming the field, because `?tag=a,b` is a plain `[]const T` there. Each of these is a compile error: a `Many` with neither bound, bounds in the wrong order, `Many(u8, …)` (bytes are text; use `Text`), and a default outside the bound. A `Many` in a response is written as its array, with `rename_all` inside its items applied as for a plain slice.

<!-- compiles -->
```zig
const NewPost = struct {
    tags: nilo.Many(Str, .{ .min = 1, .max = 5 }),
};
```
### `nilo_check`

**`nilo_check` is a rule about the whole struct, declared on the struct** (same ADR): `pub fn nilo_check(self: T, r: *nilo.Rules(T)) void`. It runs once every field has bound, in a form, a query string, a JSON body, and under `Bound`, with `r.must(field, holds, sentence)` in the same form as `Bound.must`. On a plain argument, any rule that did not hold makes a 422 naming every failed rule; under `Bound`, the sentences join the other failures. It does not run on a value with a field that failed to bind, it takes only the value, and a different signature is a compile error.

<!-- compiles -->
```zig
const SignUp = struct {
    email: nilo.Email,
    password: nilo.Text(.{ .min = 10, .max = 72 }),
    confirm: Str,

    pub fn nilo_check(self: SignUp, r: *nilo.Rules(SignUp)) void {
        r.must("confirm", self.password.eql(self.confirm.view()), "has to match the password");
    }
};
```

### `Path(T)`

**The path params of the route, read by name into a struct of yours.** Each field is spelled like a `:name` of the pattern (`@"*"` for a trailing wildcard) and typed as anything a bare path param may be: a number, a `bool`, an enum, a `Str`, a type with `nilo_parse`. `.value` is the struct.

```zig
fn member(p: nilo.Path(struct { org: u32, id: u32 })) !?User { … p.value.org … }
try app.get("/orgs/:org/members/:id", member);
```

**It is required from two params up, and a bare path param there is a Refusal** that writes the `Path(…)` to use from the handler's own types, because two bare `u32` cannot say which `:name` each is. A route with one param may use either form. Refusals, each naming the route: a field that names no param (with the route's params and the likeliest spelling), a param with no field (unless the handler holds a `*Ctx`), an optional field, a field a path param cannot be, two `Path(T)` arguments, and a `Path(T)` beside a bare path param. A value that does not convert is the 400 the bare form gives, naming the field. The fields are located while compiling, so reading costs no string comparison and no allocation ([ADR 002](../adr/002-typed-handlers-are-a-thin-layer-over-ctx.md)).

**A resolver may take it** ([ADR 015](../adr/015-resolved-values-are-declared-by-their-type.md)): from a typed handler its fields are checked against that route while compiling and need not cover every param; from a bare middleware (`c.resolve(T)`) they are read by name at run time, and a name the matched route lacks is a 500 naming the resolver, the param and the route. The document lists each path parameter by its name, typed from its field.

### `Form(T)`

**`Form(T)` and a plain struct fill the same argument slot** (a form *is* the body), so asking for both is a compile error. A `Form(T)` field is a `Str`, a number, a `bool`, an enum or an `Upload`, optionally in a `?`, or a slice of any of them but an optional: `[]const Upload` takes every file under the name. A default is what "not sent" means. An empty value on an optional or defaulted field whose type has no empty value (`age=` on a `?u32`) also counts as "not sent", in a `Query(T)` too. An empty `?Str` is `""`.

**A field that is a slice of one of those types is a list**, with one element per occurrence of the name (a checkbox group, a `<select multiple>`), in the order sent. Nothing sent is an empty list and never a 400, an empty value adds nothing, and a comma is part of the data, because a browser never joins a group with commas, so there is no second spelling like there is for a query. A list of `Upload` is a Refusal. Under `Bound(Form(T))`, the first value that fails to convert is the one reported, and the rest are still read ([ADR 132](../adr/132-a-query-parameter-or-a-form-field-that-is-a-list.md)). See [Forms](../guide/forms.md#checkbox-groups-and-multiple-selects).

### `FromHeader(name, T)`

**One request header, as an argument the signature declares** ([ADR 131](../adr/131-a-header-a-handler-can-be-given.md)):

<!-- compiles -->
```zig
fn addComment(
    actor: nilo.FromHeader("X-Staff-Id", sql.Uuid),
    tracing: nilo.FromHeader("X-Request-Id", ?Str),
) !usize {
    _ = actor.value;
    const asked = tracing.value orelse return 0;
    return asked.len();
}
```

`.value` is the header, converted the same way a path param is. A `?T` is null when the header is not sent; any other type makes a missing header a 400 saying which header is required, and text that does not convert is the same 400 in the same words. Two of them on one handler is normal, unlike `Query(T)`, which is one struct.

`c.header("X-Staff-Id")` still reads the header and is not going away. What the wrapper adds is the generated document: a header parameter, so a client generated from the OpenAPI knows the endpoint needs one. The name is checked while compiling: an empty name, or anything that is not a valid header token, is a Refusal.

**It is `FromHeader`, not `Header`**, because `nilo.Header` is the response side, and has been since 0.2.0.

### `Authorization(scheme)`

**The `Authorization` header, read as the one scheme the endpoint accepts** ([ADR 153](../adr/153-an-authorization-header-a-handler-can-ask-for.md)):

<!-- compiles -->
```zig
fn whose(auth: nilo.Authorization(.bearer), db: *sql.Db, c: *nilo.Ctx) !User {
    return try db.one(User, c, .{ .where = .{ .email = auth.value } }) orelse
        return nilo.Authorization(.bearer).refuse("that token is not one of ours", .{});
}

fn admin(auth: nilo.Authorization(.{ .basic = "admin" })) !nilo.Status(204, void) {
    if (!std.mem.eql(u8, auth.user.view(), "root")) {
        return nilo.Authorization(.{ .basic = "admin" }).refuse("not for {s}", .{auth.user.view()});
    }
    return .{};
}
```

| | |
|---|---|
| `.bearer` | `.value` is the token as sent: the bytes after the scheme, whitespace trimmed, nothing decoded |
| `.{ .basic = "realm" }` | `.user` and `.password`, base64-decoded and split at the **first** colon. The realm is required (RFC 7617) and is what the browser's login prompt shows |
| `T.challenge` | the `WWW-Authenticate` value: `Bearer`, or `Basic realm="…"` |
| `T.refuse(fmt, args)` | `fail.unauthorized` with `T.challenge` attached, for rejecting *after* reading, when the token did not verify or the password did not match |
| `c.authorization(scheme)` | the same, read from a resolver or a middleware, which have no argument list |

**The scheme is matched case-insensitively (RFC 9110 §11.1), and every 401 carries `WWW-Authenticate` (§15.5.2).** Those are the two things the hand-written six-line versions got wrong in both places this repository had them. A missing header, another scheme, an empty token, or Basic that is not base64 or has no colon: each is a 401 saying which, before the handler runs. In the document it is a `security` entry and a 401, not a parameter, so a generated client knows to sign in.

Bearer allocates nothing; Basic decodes into the request arena, once. There is deliberately no fallback that also looks in the query string or a cookie: a token in a query string ends up in every access log along the way.

### `Verified(V)`

**The same header, verified: the claims behind a bearer token**, read through the `jwt.Verifier` the argument names, or a 401 with the challenge before the handler runs ([ADR 191](../adr/191-verified-claims-are-a-handler-argument.md)):

<!-- compiles -->
```zig
const Claims = struct { sub: []const u8, email: []const u8 };
const Google = jwt.Verifier(Claims, fetch.Client);

fn me(user: nilo.Verified(Google), db: *sql.Db, c: *nilo.Ctx) !User {
    return try db.one(User, c, .{ .where = .{ .email = user.claims.email } }) orelse
        return nilo.Verified(Google).refuse("that account is closed", .{});
}
```

| | |
|---|---|
| `V` | a `jwt.Verifier(Claims, Client)`: the key ring, the client its refresh needs, and the claims type, held as one service ([`jwt.Verifier`](./jwt.md#jwtverifierclaims-client)). Provided like any other service; `listen()` refuses to start without it |
| `.claims` | the payload as `Claims`, with strings in the request arena |
| `.token` | the token as sent, for a handler that passes it on |
| `T.challenge` | `Bearer` |
| `T.refuse(fmt, args)` | `fail.unauthorized` with the challenge attached, for rejecting *after* verifying |
| `c.verified(V)` | the same, read from a middleware guarding a prefix; a handler under it that asks again verifies again |

A missing header, another scheme, or a token the ring rejects (expired, wrong audience, unknown `kid` after one bounded fetch, bad signature) is a 401 with `WWW-Authenticate: Bearer` and the reason in the body. If the issuer's keys cannot be reached when a refresh is needed, the answer is a 503, since the token was never judged. In the document it is the bearer scheme and a 401. It costs what `Authorization(.bearer)` plus one `verify` cost: the claims are the one allocation, into the arena, and the signature check is the work.

### `Idempotent(Replays, options)`

**The `Idempotency-Key` header, as the argument that makes a route answer once per key** ([ADR 155](../adr/155-a-request-answered-once-is-answered-the-same-way-again.md)):

<!-- compiles -->
```zig
const Replays = cache.Space("orders-replay", []const u8, .{ .ttl_s = 86_400, .max_bytes = 16 << 10 });

fn account(c: *nilo.Ctx) ?Str {
    return c.header("X-Account");
}

const NewOrder = struct { sku: Str, qty: u32 };
const Placed = struct { id: u64, sku: Str };

fn placeOrder(key: nilo.Idempotent(Replays, .{ .by = account }), body: NewOrder) !nilo.Status(201, Placed) {
    _ = key;                                 // the header as sent, if the handler wants it
    return .{ .value = .{ .id = 7, .sku = body.sku } };
}
```

The first request with a key runs the handler and **stores what it returned**: the status, the `Response(T)` headers and trailers, and the body. Every later request with that key gets the stored answer back, byte for byte, with `Idempotent-Replayed: true`, and the handler does not run. A failure is not stored, so a retry after a `fail.…` or an error runs the handler again.

| | |
|---|---|
| `Replays` | where answers are stored: a `cache.Space` holding `[]const u8`, registered with `app.provide`. Any type with `getInto`, `putIfAbsentFor`, `put`, `del`, `max_bytes` and `Held` works, which is what a Redis-backed table would provide. It is a service the route needs, so `listen()` names it when it is missing |
| `.by` | whose key it is: a function of one `*Ctx` returning `?Str`. Two callers who pick the same key must never see each other's answer, so leave it null only on an endpoint with a single caller. Null from the function is a 403 |
| `.key` | the header as sent |

**Checked before the handler runs, each answer naming the header:** **400** with no `Idempotency-Key`, one over 255 bytes, or one too long for the Space to hold a key to (a long `.by`, or a Space sized small), refused before the handler runs; **409** when the same key is still being answered; **422** when the key is reused on a different request (the method, path, query and body are fingerprinted). In the document: a required header parameter and the two extra responses. A handler that returns nothing, a file or a redirect has no answer nilo can store, and is a Refusal.

**What it costs, only on the route that uses it:** one arena allocation of the Space's `max_bytes` to read a stored answer into, one to encode the answer being stored, and the JSON buffer the answer was using anyway. Nothing on the stack.

### `Cached(Pages, options)`

**A stored answer served again for a while, as an argument that makes a GET declare it in its signature** ([ADR 188](../adr/188-a-route-can-say-cache-this-answer-for-a-minute.md)):

<!-- compiles -->
```zig
const Pages = cache.Space("pages", []const u8, .{ .max_bytes = 32 << 10 });

const Front = struct { headline: Str, stories: u32 };

fn frontPage(page: nilo.Cached(Pages, .{ .ttl_s = 60 })) !Front {
    _ = page;                                // `.key` is what the answer is kept under
    return .{ .headline = .static("Selamat pagi"), .stories = 12 };
}
```

The first request runs the handler and **stores what it returned** (status, the `Response(T)` headers and trailers, the body) under the path and query. Every request for the same path and query within `ttl_s` gets the stored answer back, byte for byte, with `Cache-Status: nilo; hit`, and the handler does not run; a fresh answer carries `Cache-Status: nilo; fwd=miss`. A failure is not stored, so the next request runs the handler again. **An answer that sets a cookie, or carries a header `setHeader` refuses, is sent and not kept**, with a `warn`, so the first visitor's `Set-Cookie` is never replayed to everybody ([ADR 188](../adr/188-a-route-can-say-cache-this-answer-for-a-minute.md)).

| | |
|---|---|
| `Pages` | where answers are stored: a `cache.Space` holding `[]const u8`, registered with `app.provide`. Any type with `getInto`, `putIfAbsent`, `putFor`, `del`, `max_bytes` and `Held` works. It is a service the route needs, so `listen()` names it when it is missing |
| `.ttl_s` | how long a stored answer is served, in seconds. No default, and 0 is a Refusal |
| `.by` | what the key is made of: `.path_and_query` (the default), `.path`, or `.{ .header = "Accept-Language" }` for the path, the query and one header's value. The query is used as it arrived, so `?a=1&b=2` and `?b=2&a=1` are two entries. `Cookie` and `Authorization` are refused as keys |
| `.key` | what the answer was stored under, as a `Str` |

**A request that finds the answer still being built waits for it**, instead of getting a 409: it checks again every 10 ms, for at most 2 s or half of what `nilo.deadline(ms)` left the route, and after that runs the handler itself. **GET and HEAD only**: `app.post(…)` and the others refuse it while compiling, and `app.route(.POST, …)` refuses it at registration with `error.CachedWrite`. A handler that returns nothing, a file or a redirect has no answer nilo can store, and is a Refusal, and so is one that also takes an `Idempotent(…)`.

**A handler that reads who the caller is cannot be cached**, because the first caller's answer would be served to every caller after them. A `Cached(…)` next to a `Session(T)`, an `Authorization`, a `Verified(…)` or a `FromHeader` of `Cookie` or `Authorization` is a Refusal. A resolved type of your own that represents the caller declares it with `pub const nilo_reads_caller = true;` and is refused the same way. A `*Ctx` can read anything and is not checked.

It costs what `Idempotent` costs, only on the route that uses it, plus one arena allocation to join the path and the query when there is a query. Nothing on the stack.

### A query field that is a list

**A `Query(T)` field may be a slice, and every occurrence of that name is one element** ([ADR 132](../adr/132-a-query-parameter-or-a-form-field-that-is-a-list.md)):

<!-- compiles -->
```zig
const Filter = struct {
    tag: []const Str = &.{},
    limit: u32 = 20,
};

fn search(q: nilo.Query(Filter)) !usize {
    return q.value.tag.len;
}
```

**Both spellings are read**: `?tag=a&tag=b&tag=c` and `?tag=a,b,c` give the same three elements, in the order they arrived, allocated from the request arena. `?tag=a,b` is what nilo writes into the document (`"style":"form"`, `"explode":false`), and `?tag=a&tag=b` is what half the clients in the world send anyway. A server that takes the first and drops the rest returns fewer rows, which looks exactly like a filter that worked.

An empty value adds nothing, so `?tag=` is an empty list, not a list with one empty string. That is also why a list field should default to `= &.{}` instead of being required, and why it is never `required` in the document. The cost of the comma separator is that a value containing a comma cannot be sent.

**"Not sent" and "sent empty" cannot be told apart**, and `?[]const Str` does not solve it: it compiles, and returns null for both. An optional list only changes how *nothing* is represented (null instead of `&.{}`), not which kind of nothing it was. Every filter written against a list so far has meant the same thing by either, which is why there is no second way to express it.

Each element converts exactly like a single field would, so `[]const Kind` for an enum rejects `?kind=nope` with the same sentence a single `kind` gets, and under `Bound(Query(T))` the **first** bad value is the one reported. A list of something a query value cannot become at all is a Refusal.

### `Bound(W)`

**`Bound(Form(T))`, `Bound(Query(T))`, or `Bound(T)` for a JSON body**, in the same argument slot as what it wraps. It hands the handler the binding failures instead of answering 400.

| | |
|---|---|
| `b.value()` | `?T`: the bound value, or null if **any** field failed |
| `b.fail()` | a 422 naming every field that did not bind |
| `b.failed()`, `b.failedCount()` | whether any failed, and how many |
| `b.failures()` | an iterator of `Failure` |
| `b.given("name")` | `Str`: the text that arrived, bound or not. The name is checked while compiling |
| `b.must("name", holds, "wants …")` | adds a rule of your own to the same answer, and returns a `Checked` |
| `Bound(W).ok(value)` | a binding where everything bound, for a test that calls the handler directly |

A `Failure` has `field`, `reason`, `given`, `kind`, `expected`, `said`, and `say(w)`, which writes nilo's own sentence for it. `reason` is one of `.missing`, `.not_a_number`, `.not_true_or_false`, `.not_a_choice`, `.wrong_kind`, or **null when the failure comes from one of your rules**. That is the whole list: it is not a validation library. Nothing is allocated per failed field. See [Forms](../guide/forms.md#collecting-every-field-error-bound) and [ADR 034](../adr/034-a-binding-hands-its-failures-to-the-handler.md).

`must` returns a `Checked`, which has the same `value`, `failed`, `failedCount`, `given`, `failures` and `fail`, and another `must` for chaining. `holds` is true when the rule holds, not when it fails. A handler that checks no rules never builds a `Checked` and pays nothing ([ADR 034](../adr/034-a-binding-hands-its-failures-to-the-handler.md)).

### A body in another format

**A struct with a `wire` table is a protobuf message, and the request says which of its two spellings it sent** ([ADR 256](../adr/256-a-body-is-read-as-what-its-type-says.md)). `application/proto`, `application/protobuf`, `application/x-protobuf` and gRPC's `application/grpc` are read by [`nilo_proto`](./proto.md); anything else, no content type included, is read as JSON like any other struct, so `curl -d` works against it.

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

**The answer goes back in the spelling the request came in**: protobuf under `application/proto` to a request that sent protobuf, `application/grpc` to a gRPC call, and JSON to everything else, a GET included. It is the request's `Content-Type` that decides, never `Accept`. A route whose body is a message answers a message or nothing, and anything else is a compile error.

| | |
|---|---|
| bytes that are not the message | 400, naming the type and what was wrong: `it ends in the middle of a field` |
| `Bound(T)` around a message | a compile error: protobuf has no field that fails on its own |
| in the document | filed under both `application/json` and `application/proto`, with one schema |
| a failure, to a request carrying `Connect-Protocol-Version: 1` | `{"code":"not_found","message":"…"}`, the code from the error first and the status otherwise ([ADR 257](../adr/257-a-connect-client-is-told-its-failure-in-connect-words.md)) |

Its JSON is nilo's JSON, the same as any other struct's: field names as written, a 64-bit integer as a number, and a `bytes` field as text, where protobuf's own JSON mapping uses base64 ([todo](../todo.md)).

**Any other type that knows its own bytes declares `nilo_content_type` and `nilo_decode`**, the mirror of [a type that writes its own answer](#a-type-that-writes-its-own-answer):

<!-- compiles -->
```zig
const Reading = struct {
    sensor: u16,
    tenths: u32,

    pub const nilo_content_type = "application/x-reading";

    pub fn nilo_decode(body: []const u8, arena: std.mem.Allocator) !Reading {
        _ = arena;
        if (body.len != 6) return error.NotSixBytes;
        return .{
            .sensor = std.mem.readInt(u16, body[0..2], .big),
            .tenths = std.mem.readInt(u32, body[2..6], .big),
        };
    }
};

fn record(r: Reading) u32 {
    return r.tenths;
}
```

It is read only when the request's media type is its own, compared without case and without parameters; anything else, or no content type at all, is a 415 saying what it reads. An error `nilo_decode` returns is a 400 naming it, and a fail function it calls answers with its own status and sentence. The bytes live as long as the request, so the value may point into them. The document files the body under the type's content type, described by its `nilo_openapi` or by `{}` with a note.

A `nilo_decode` without `nilo_content_type`, one with any other signature, a type with both `nilo_decode` and a `wire` table, and one with both `nilo_decode` and `nilo_parse` are each a compile error naming the route.

## Handler returns

| Returned | Response |
|---|---|
| `void` | 200, empty, no `Content-Type` |
| `Str`, `[]const u8` | 200, `text/plain` |
| anything else | 200, that value as JSON |
| `?T` | 200 with the value, **404** when null |
| `Status(code, T)` | that status, and the API description names it |
| `Response(T)` | a status chosen at run time; the description says `default` |
| `Redirect(code)` | that status and a `Location`, no body |
| `FileBody` | a file on disk, opened and sent without being held in memory |
| `Bytes` | bytes already in hand, under a content type chosen per request, for example somebody else's download passed on ([ADR 173](../adr/173-bytes-handed-on-are-an-answer.md)) |
| `Versioned(T)` | `T` with a weak `ETag` made from a `u64` the handler provides; **304** with no body when `If-None-Match` matches it on a GET or a HEAD, and the ordinary 200 on any other method ([ADR 189](../adr/189-a-version-a-handler-names-is-an-etag.md)) |
| a type with `nilo_content_type` and `nilo_write` | 200, the bytes `nilo_write` wrote, under that content type: see [below](#a-type-that-writes-its-own-answer) |

```zig
Status(201, User){ .headers = .of(&.{…}), .value = user }
Status(204, void){}                                        // an empty response
Response(User){ .status = if (made) 201 else 200, .value = user }
Redirect(303).to("/welcome")                               // written `return .to(…)`
Redirect(303).with("/welcome", .of(&.{…}))                 // …with headers of its own
FileBody{ .dir = files.dir, .name = name }                 // `?FileBody` — null is a 404
Bytes{ .body = got.body, .content_type = got.content_type } // `?Bytes` likewise; takes a wrapper's status
Versioned([]Order){ .version = revision, .value = orders }  // `W/"…"`; `.unchanged(revision)` when `c.clientHas(revision)`
```

`Headers` holds up to 8 headers by value; a ninth is a compile error.

**`Status(code, T)` and `Response(T)` also take `.trailers: Headers = .{}`**, sent after the body the way `c.setTrailer` sends them, under the same rules and refusals ([ADR 254](../adr/254-an-answer-can-carry-trailers.md), [Trailers](ctx.md#trailers)). Costs nothing when empty.

### A `*Ctx` handler that returns `void`

**This is the one case the document cannot describe.** It sends 200 with an empty body if the handler wrote nothing, and whatever the handler wrote if it did, and nilo cannot tell which from the signature. So the description says it does not know, and `listen()` reports how many routes are in that state. A handler that means "200, empty" says so by returning `Status(200, void)`, and is described like anything else ([ADR 120](../adr/120-a-ctx-handler-that-returns-nothing-may-have-written-it.md)).

### A `?` inside a wrapper

**A `?` goes inside a wrapper, never around it.** `Status(201, ?T)` and `Response(?T)` mean the value or a 404. `?Status(201, T)`, `?Response(T)`, `?Redirect(code)` and `?Versioned(T)` are each a compile error naming the form to write instead, since the `?` is about the body, and those have no body for it to be about ([ADR 203](../adr/203-a-question-mark-goes-inside-the-wrapper.md)). The [guide](../guide/handlers.md#combining--with-status-and-response) has the two tables.

### `Redirect(code)`

`Redirect` takes 301, 302, 303, 307 or 308; anything else is a compile error. 303 is the one to use after a form POST.

### `FileBody`

**Fields:** `dir` (a [`Dir`](./streaming.md#dir)), `name`, `content_type` (`"application/octet-stream"`), `cache_control` (`""`) and `headers`. A `Content-Disposition` goes in `headers`; there is no `download_as`. The name is checked before the file is opened: a `..` segment, an absolute path, a NUL byte, and on Windows a backslash or a drive letter, all get the same 404 a missing file does. `Range`, `If-Range`, `If-None-Match` and `HEAD` work as they do for a static file. The API description says the body is `application/octet-stream` with `format: binary`, whatever the content type is at run time. See [Responses](../guide/responses.md#files).

### `Bytes`

**Fields:** `body`, `content_type` (`"application/octet-stream"`) and `headers`, as for `FileBody`. Nothing is copied: the body belongs to the handler (the request arena, or a response it still holds) and is sent as it is. The document says `format: binary` for the same reason as `FileBody`: the content type is decided while the request runs, and a document that guessed `application/zip` would be wrong the first time the upstream sent something else. It is the answer for a proxy that downloads from one service and passes the bytes to the browser with *their* `Content-Type` and a `Content-Disposition`, which a `*Ctx` handler calling `c.send` could not describe.

### `Versioned(T)`

**Fields:** `version` (a `u64`), `headers`, and `value` (`?T`; null is `.unchanged(version)`, the answer for a client that `c.clientHas(version)` said already has it; use `.unchangedWith(version, headers)` when the 304 should carry the same `Cache-Control` as the 200). The tag is `W/"<hex>"`: weak, because a version says the representation is the same, not that the bytes are. `headers` are sent on both the 200 and the 304. `.unchanged` sent to a client that did not send the version is a 500 naming the route. `Versioned(?T)`, `Versioned(void)`, a `Versioned` inside a `Status` or a `Response`, and one under a `Cached` or an `Idempotent` are each a compile error saying what to write instead; for something that does not exist, use `fail.notFound`. The document puts the `ETag` on the 200 and, for a GET or a HEAD, adds a `304`. See [Responses](../guide/responses.md#etags-and-304-not-modified).

### A type that writes its own answer

**A type with two declarations is sent as whatever it writes, under the content type it names**: XML for a consumer that will not change, CSV for a spreadsheet, HTML from your own template ([ADR 157](../adr/157-a-type-can-write-its-own-answer.md)).

<!-- compiles -->
```zig
const Invoice = struct {
    number: u32,
    total: i64,

    pub const nilo_content_type = "application/xml";
    pub const nilo_openapi = .{ .type = "string" };

    pub fn nilo_write(self: Invoice, w: *std.Io.Writer) !void {
        try w.print("<invoice><number>{d}</number><total>{d}</total></invoice>", .{ self.number, self.total });
    }
};

fn showInvoice(number: u32) ?Invoice {
    if (number == 0) return null;
    return .{ .number = number, .total = 1500 };
}
```

Every wrapper works the way it does for JSON: `?Invoice` is a 404 when null, `Status(201, Invoice)` is a 201, `Response(Invoice)` carries headers, and an `Idempotent` route stores the answer with its content type. The body is written into the request arena the same way a JSON body is (one allocation, the same one), and a program with no such type links none of it.

**Both declarations or neither.** One without the other is a compile error, and so is an empty content type, one containing a control character, or a `nilo_write` with any other signature. The document names the content type and describes the body with `nilo_openapi` if the type has one, or with `{}` and a note otherwise, the same as for a type that writes its own JSON. nilo knows nothing about XML, CSV or HTML; a type that reads one from a request declares `nilo_decode` beside its content type ([a body in another format](#a-body-in-another-format)).

## JSON shapes

**A struct is written as its fields, and an enum as its tag name.** A type that wants something else declares it with `nilo_json`, which is plain data read while compiling ([ADR 016](../adr/016-the-api-description-comes-from-the-signatures.md)).

<!-- compiles -->
```zig
const nilo = @import("nilo_http");

const Condition = union(enum) {
    pub const nilo_json = .{ .tag = "signal", .rename_all = .@"kebab-case" };
    pub const jsonParse = nilo.jsonParseFor(@This());

    metrics: struct { threshold: f64 },
    log_volume: struct { query: []const u8 },
    disabled,
};
```

| | |
|---|---|
| `.tag` | the discriminator's key. For a `union(enum)` only: the variant's name goes under it, and the variant's own fields go beside it in the same object |
| `.rename_all` | how names are spelled on the wire: an enum's tags, a union's variants, or **a struct's field names** |
| `.rename` | names spelled one at a time, such as `.{ .amount_minor = "amountMinor" }`, which take priority over `.rename_all` ([ADR 168](../adr/168-one-field-can-be-spelled-on-its-own.md)) |
| `.skip` | a struct's fields that are never written and never read: `&.{"password_hash"}`. A client sending one has sent an unknown key; the API description leaves it out; read from a body it needs a default or a `?T` ([ADR 148](../adr/148-a-field-name-is-a-spelling-too.md)) |

`.rename_all` takes `.lowercase`, `.UPPERCASE`, `.camelCase`, `.PascalCase`, `.SCREAMING_SNAKE_CASE` and `.@"kebab-case"`. The first two join the words (`not_found` becomes `notfound`); `.SCREAMING_SNAKE_CASE` keeps the underscore. There is no `.snake_case`, because that is what a Zig field name already is, and asking for it is a compile error instead of a silent no-op. Two names that end up the same are also a compile error, in every case, because the object would have the same key twice.

### A struct that renames its fields

**Declare the wire spelling once on the struct.** A Row is snake_case because Postgres is, and the wire is camelCase because the browser is. Declaring it once is better than a mapping function written out field by field, which is what a DTO layer is, and which nothing checks against the Row it came from ([ADR 148](../adr/148-a-field-name-is-a-spelling-too.md)):

<!-- compiles -->
```zig
const Contact = struct {
    pub const nilo_json = .{ .rename_all = .camelCase };

    id: u32,
    full_name: []const u8,   // goes out as "fullName"
    partner_id: u32,         // and "partnerId"
};
```

The API description uses the same keys, so a generated client reads what the server sends. It costs nothing per request: the name is a comptime string either way, written in the same call as the punctuation around it.

#### Renaming one field

**A field no case rule can reach is spelled on its own**, next to the case rule, and the entry takes priority ([ADR 168](../adr/168-one-field-can-be-spelled-on-its-own.md)):

<!-- compiles -->
```zig
const Summary = struct {
    pub const nilo_json = .{
        .rename_all = .camelCase,
        .rename = .{ .estimated_cost_amount_minor = "estimatedCostMinor" },
    };

    id: u32,
    estimated_cost_amount_minor: i64,   // "estimatedCostMinor"
    due_at: []const u8,                 // "dueAt", by the case
};
```

An entry naming a field the struct does not have, one that spells a field the way it is already written, and one that lands on another field's key are each a compile error.

#### Renamed types are for output only

**A renamed spelling is for what goes out and what comes in as JSON.** A request body is matched against the wire names (`fullName`, not `full_name`), the sentences of a 400 or a `Bound` 422 quote the name the client sent, and the API description lists the same keys, so one Row is posted and returned under one spelling. A form and a query string read field names as written, so a struct with `rename_all`, `.rename` or `.skip` used as one of those is a compile error naming the route; give it its own struct. A skipped field read from a body needs a default value or a `?T`, and a type without one is a compile error naming the field.

A renamed or skipping struct that nilo's own writer cannot handle is also refused. A shape it does not recognise (a tuple, an array of bytes, an untagged union, a type that writes its own JSON without describing it, anything more than eight levels deep) sends the whole value to `std.json`, which does not read the marker.

#### Leaf types

**A type that writes its own JSON *and describes what it looks like* is treated as a leaf**, and that is what decides whether it can appear in a renamed struct ([ADR 148](../adr/148-a-field-name-is-a-spelling-too.md)). A `nilo_openapi` may only name `"string"`, `"integer"`, `"number"` or `"boolean"`, so a type that has one has promised its JSON is a single scalar, which is the promise the writer needs to keep writing the object around it. `sql.Uuid`, `sql.Timestamp`, `sql.AsText` and `id.Uuid` are all leaves, so a Row-shaped response containing any of them can rename its fields:

```zig
const Contact = struct {
    pub const nilo_json = .{ .rename_all = .camelCase };

    id: sql.Uuid,            // still "id", and still 36 characters
    full_name: nilo.Str,     // goes out as "fullName"
    created_at: sql.Timestamp,  // "createdAt", still RFC 3339
};
```

It also makes such a response 33% faster whether or not anything is renamed: `covers` is decided for the *whole* value, so one leaf used to send every string next to it to `std.json` as well. That was 250 ns and is now 165 ns, on a 305-byte row with three uuids ([`bench/result/http.md`](../../bench/result/http.md)). Your own type gets the same by adding the same two declarations.

#### Skipping the keys a body struct does not know

**A request body struct refuses a key it has no field for, and a type can say it should skip them instead**, with `.unknown_fields = .ignore` ([ADR 168](../adr/168-one-field-can-be-spelled-on-its-own.md)):

```zig
const Span = struct {
    pub const nilo_json = .{ .unknown_fields = .ignore };

    name: nilo.Str,
    start_unix_nano: u64,
};
```

It is for payloads whose sender is allowed to grow: OTLP/HTTP JSON must be read ignoring unknown fields, and a third-party webhook adds them without warning. **It is per type**: a strict struct holding this one still refuses its own unknown keys, and this one holding a strict struct still has that child refuse. Put it on a union variant's payload struct to make that variant skip them; the others keep refusing. A known key given twice is still a 400, and a skipped value is held to the same 64 levels of nesting a body is.

The API document says `additionalProperties: true` for such a type and says nothing for any other. Four things are compile errors: `.unknown_fields = .refuse` (it is the default), the marker on an enum or on a union, and any value but `.ignore`.

**A payload under an externally tagged union** (`{"metrics":{...}}`, with no `nilo_json` on the union) is read by `std.json`, which cannot see the marker, so it stays strict. Give the union a `.tag` to get the marker honoured.

#### Answering JSON of the wrong shape with a 422

**A body that does not fit is a 400, and a type can say that JSON of the wrong shape is a 422 instead**, with `.misfit = 422` ([ADR 251](../adr/251-json-that-does-not-fit-can-be-a-422.md)):

```zig
const SearchRequest = struct {
    pub const nilo_json = .{ .unknown_fields = .ignore, .misfit = 422 };

    start_ts_nanos: nilo.Str,
    limit: u32 = 500,
};
```

| the body | without the entry | with `.misfit = 422` |
|---|---|---|
| text that is not JSON, empty, or nested past 64 levels | 400 | 400 |
| JSON with a field missing, a value of the wrong kind, a mistake nested inside a field, a key the type does not know, a key given twice, or not an object | 400 | 422 |
| a rule a `nilo_check` reports | 422 | 422 |

The sentence is the same either way; only the status moves. It applies wherever the type is read as a body: a typed argument, `c.json(T)`, and `Bound(T)`, where the refusals the binding cannot collect take the type's status and what it does collect is still answered by `b.fail()`. It is read off the type the body is read into: a struct nested inside it is answered for by the body's type. The API document lists a 422 beside the 400 for a typed body argument whose type says it.

Five things are compile errors: `.misfit = 400` (it is the default), any other status, a value that is not a number, and the entry on an enum or on a union with no `.tag`, which `std.json` reads by itself.

#### The marker is not inherited

**The marker is per type.** A struct renames its own fields; a union renames its *variants* and leaves a payload struct's fields to that struct's own marker; a nested struct without a marker keeps its own spelling.

### `nilo.jsonParseFor`

**`nilo.jsonParseFor(@This())` is the parser, and it is a separate line** because `std.json` picks the parser from the type, and nothing can add a declaration to a type you wrote. You only need it if the type arrives in a request; sending needs nothing. On a type with `nilo_parse`, it is the parser that passes the string to `nilo_parse` ([ADR 166](../adr/166-a-body-field-that-parses-itself.md)). Adding it to a type with neither a `nilo_json` nor a `nilo_parse` is a compile error, and so is adding it to a struct that only renames or skips, because nilo already reads a struct's marker.

### Unions

**Without a marker, a `union(enum)` is externally tagged**: `{"metrics":{…}}`, which is what `std.json` writes. It is written by nilo's own writer either way. An *untagged* union has nothing saying which variant is active, and is left entirely to `std.json`. A variant with no payload is allowed under `.tag` and is just the discriminator; under the default encoding it is not supported. A tagged object read from a body with its discriminator twice is a 400 naming the key. Every other mistake inside one is a 400 that says what arrived and what would have been taken: `"condition.signal" is not one of the known variants (metrics, logs, off): "traces"`, `a field "condition.metric_nme" the "metrics" variant does not know. It takes: signal, metric_name, agg (optional)`, or a missing discriminator with the variants listed. A key beside a variant that has no fields is refused the same way.

The generated API description follows whichever encoding the type chose: `oneOf` of one-key objects for the default, and `oneOf` with a `discriminator` plus a per-variant `allOf` for a tagged one. See [Responses](../guide/responses.md#json-field-names-and-union-tags).

### Writing JSON outside a request

**`nilo.writeJson(w, value)` writes `value` by the rules a response is written by, with no request in hand**: for a job's payload, an alert body, or the expected text in a test. It is the function `c.json` calls, so the two cannot disagree: fields in declaration order, a float the way serde_json spells it (`1.0` not `1`, `1e+16` not seventeen digits, `null` when it is not finite), a `Str` as text, `nilo_json` markers honoured, and the bytes `std.json` writes for anything the generated writer does not cover. `nilo.jsonAlloc(gpa, value)` is the same into a slice you free.

<!-- compiles -->
```zig
fn alertBody(gpa: std.mem.Allocator, w: *std.Io.Writer, free: f64) !void {
    // To a writer you already hold: a file, a socket, a buffer.
    try nilo.writeJson(w, .{ .alert = "disk", .free = free });

    // Or to memory you own.
    const text = try nilo.jsonAlloc(gpa, .{ .alert = "disk", .free = free });
    defer gpa.free(text);
}
```

`writeJson` returns `std.Io.Writer.Error` and `jsonAlloc` returns `error.OutOfMemory`; neither allocates beyond what the writer or `gpa` is asked for. Only writing is public: reading is `std.json`, with `nilo.jsonParseFor` on a type that needs it.

### Text that is not UTF-8

**A `[]const u8` or a `Str` that is not valid UTF-8 is sent as an array of byte values**, such as `{"name":[255]}`, because JSON has no way to carry a byte that is not text. That is what `std.json` does with the same value, and this writer's whole contract is to write what `std.json` writes ([ADR 096](../adr/096-a-byte-that-is-not-text-is-not-a-string.md)). The description still calls the field a string, since the type is text and only the value is not.
