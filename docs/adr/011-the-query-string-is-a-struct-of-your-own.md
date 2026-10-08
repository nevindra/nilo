# The query string is a struct of your own, asked for as Query(T)

**Status:** accepted
**Topic:** [request-input](../design/request-input.md)

## The problem

Path params were typed from the start: `/users/:id` with a `u32` argument gave conversion, a 400 with a real message when it failed, and a compile error when the counts did not line up. The query string had none of it. `?page=2` meant taking a `*Ctx` and writing this:

```zig
fn search(c: *Ctx) !void {
    const q = c.query("q") orelse return fail.badRequest("q is required", .{});
    const page: u32 = if (c.query("page")) |p|
        std.fmt.parseInt(u32, p.view(), 10) catch
            return fail.badRequest("page has to be a number, not \"{s}\"", .{p.view()})
    else
        1;
    ...
}
```

Ten lines of exactly the boilerplate the typed layer exists to remove — and, worse, taking a `*Ctx` gives up the typed return value and the typed path params too. Sorting and pagination are not edge cases; a listing endpoint without them is unusual. So the most ordinary thing a REST service does was the thing that pushed people out of the layer that makes nilo worth using.

`docs/history.md` records that "Router: path params, query params" in the v1 scope since stage 1. Only half of it was built.

## The decision

The query string arrives as a struct the caller declares, wrapped in `Query(T)`:

```zig
const Search = struct {
    q: Str,             // no default: absent is a 400 naming it
    page: u32 = 1,      // a default is what "absent" means
    sort: Sort = .newest,
    tag: ?Str = null,   // optional: absent is null
};

fn search(db: *Db, params: Query(Search)) ![]const Item { ... }
```

**The same rule holds for a form and for a JSON body, nested as deep as a body goes.** A field with a default may be absent and is its default. A `?T` may be absent and is null, with or without `= null`. Any other field is the client's to send, and leaving it out is a 400 naming it. `http/field.zig` holds this as one `FieldRule`, and every reader (`queryValue`, `Form(T)`, the JSON reader), every sentence that names a missing field or lists what an endpoint takes, and the API description ask it, so the next change reaches one place. `Patch(T)` is not an optional: it is absent by the `= .absent` its author writes, which is a default like any other (ADR 025).

Field names are the query names, because Zig keeps field names and does not keep argument names — the same fact that forces path params to be positional makes query params nameable. Conversion and its error messages are shared with path params, so `?page=soon` and `:id` being wrong read the same way apart from the sigil.

## Why a wrapper rather than a marker on the struct

The obvious alternative was to leave it a plain struct and mark it, `pub const nilo_query = {}`, letting handlers write `fn search(s: Search)`. That reads better at the use site — `s.page` rather than `params.value.page`.

It was rejected on two counts. A plain struct argument is already the request body, so with a marker the question "is this the body or the query?" moves out of the signature and into the struct's definition, possibly in another file. And the marker has to live in the caller's own type, which stops that type being an ordinary struct shared with code that has never heard of nilo.

`Query(T)` costs one `.value` at each use and buys back a signature that can be read on its own. It also matches `Response(T)`, which already works this way, so there is one shape to learn rather than two.

## What was rejected

**`?T` with no default as required in a body.** That is what `std.json` does, so for a body it was the rule by accident and not by decision: a query and a form read the same field as null from the start, the API description said both followed one rule, and every example here writes `= null`, which is why nobody met the difference. The cost was a 400 for leaving out a field the same struct would have taken in a query, and a client writing `"nickname": null` for every field it had nothing to say about. A body that wants to tell "not sent" from "sent as null" asks for `Patch(T)`.

## What it rules out

Nested structs, arrays and repeated params (`?tag=a&tag=b` keeps the first). Each of those needs a decision about representation that no reported use has forced yet, and every one of them can be had today by taking a `*Ctx` alongside the `Query(T)` and reading the raw string. Adding them later takes nothing away.

## Consequences

- Absent, malformed and out-of-range are answered before the handler runs, so a handler that has one of these arguments cannot be given a value that does not fit its type.
- The enum message lists what it would have accepted, which the path-param version now does too.
- `Query(T)` is a struct, so a handler taking one is still called directly from a test: `listUsers(&db, .{ .value = .{ .page = 2 } })`. No server, no query string.
- A field type that could not come from text is a compile error naming the field, not a runtime surprise.
