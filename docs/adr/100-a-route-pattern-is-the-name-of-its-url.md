# A route pattern is the name of its URL

**Status:** accepted
**Topic:** [routing](../design/routing.md)

Two things were missing and they turned out to be one question.

**Nothing could read the route table.** Nothing enumerated routes, nothing
printed them at startup — one `std.log.info` naming the address and that was
all — so "did my routes register" was answerable only by an app that also
served an API description ([ADR 016](016-the-api-description-comes-from-the-signatures.md)).

**Nothing could build a URL for a route.** Fiber gives a route a `Name` and
looks the pattern up again at run time with `GetRouteURL`; Gin has nothing.
Every application concatenated strings.

The obvious move is to copy Fiber: give a route a name, keep a map, look it up.
That is what this refuses.

## A name is a second thing to keep in step

A route name is a string that has to stay equal to a pattern that is already a
string. The failure it has is silent in both directions: rename the route and
keep the name, and the URL still builds — out of a pattern nothing serves. Add
a param to the pattern and the call site that fills the old ones still
compiles, because the lookup happens at run time with a map of values.

The pattern is already the name. It is a compile-time literal, it is what
`typed.wrap` reads to work out what the handler's arguments mean
([ADR 014](014-what-nilo-borrows-and-from-whom.md)), and it is what every
error message quotes back. There is nothing to add and nothing to keep in step.

## What it does now

```zig
const where = try c.url("/users/:id/posts/:slug", .{ .id = user.id, .slug = title });
try c.redirect(303, where.view());
```

**Every mistake is a compile error**, and each one names the field:

| written | said |
|---|---|
| a param with no value | `"/users/:id/posts/:slug" has a param `:slug` and nothing was given for it.` |
| a value with no param | `"/users/:id" has no param called `:slug`, so the value given for it would go nowhere. Its params are: :id.` |
| a struct where a segment goes | ``:id` in "/users/:id" was given a …, which is not something a path segment can carry.` |
| a `*` catch-all | `"/assets/*" has a `*` catch-all, and a URL cannot be built for one.` |

Four refusal files hold those messages ([ADR 026](026-the-rule-about-error-messages-is-held-by-a-build-step.md)).

**Matched by name, not by position.** A bare handler argument cannot say which
`:name` it is, because Zig does not keep argument names (ADR 002 reads a route
with two params through `Path(T)` for that reason). A struct's fields
do have names, so `.{ .slug = t, .id = 42 }` and `.{ .id = 42, .slug = t }` are
the same URL, and a two-param pattern is safe to write either way round.

**Every value is percent-encoded**, and that is a property rather than a
nicety: `url("/users/:id", .{ .id = "a/b" })` is `/users/a%2Fb`, one segment.
The alternative is a value out of a form deciding which route the URL it lands
in matches.

**A text value that is empty, `.` or `..` is refused**, `error.BadValue`, not
encoded. `.` survives percent-encoding, so `.id = ".."` once built
`/u/../settings`, which a browser following a redirect reads as `/settings`,
and `%2E%2E` is no way out because WHATWG treats a percent-encoded dot as a dot
too. An empty value built `/u//settings`, which the router gives no param. No
spelling of these names a segment, so the call fails instead of building a URL
that points elsewhere. `url.into` returns the error; `c.url` passes it up.

**Reading the table** is `app.routes()`, a view rather than a copy:

```zig
std.log.info("serving {d} routes:\n{f}", .{ app.routes().len(), app.routes() });
```

`Registered` carries the method and the joined pattern and nothing else — not
the handler, not the chain, not the split segments. A reader that could reach
those is a reader the router cannot change underneath.

## What it costs

**`app.routes()`: nothing.** No allocation, no copy; it points at the table the
router already scans and metrics already index into
([ADR 079](079-the-route-table-is-the-registry.md)).

**`c.url`: one arena allocation, on a request that asked for one.** The walk
over the pattern is unrolled at compile time — the literal segments are
`writeAll`s of comptime slices — so what runs is the encoding of the values and
nothing else. `url.into(buf, …)` is the same call with a caller's buffer and no
allocation at all, for code with no request in flight.

**Binary size**: `url.write` is generic and instantiated per pattern, so a
program that never calls it links none of it.

## What was rejected

**Fiber's `Name` and `GetRouteURL`.** A second string to keep in step, and a
run-time lookup that turns a rename into a URL nothing serves.

**Building the URL from the `Registered` entry.** Tempting, since the table is
now readable: `app.url(index, args)`. The pattern would arrive as run-time
text, so nothing could be checked while compiling, and the mistakes would come
back as a `:id` sitting literally in a redirect.

**Exposing `router.Route` directly.** It carries the handler pointer, the
resolved chain, the split segments, the specificity score and the first-segment
key. Every one of those is how the router does its job today, and publishing
them is a promise not to change them.

**Encoding `.` and `..` as `%2E` and `%2E%2E`.** The first answer to the audit of
`http/` at `39896d2`, dropped because a browser normalises a percent-encoded
dot segment exactly as it does a bare one, so the URL would still point one
level up.

**Taking a `*` catch-all.** `*` is not an identifier, so there is no field name
for it, and what it stands for is a whole tail of path rather than one segment
— which is not a thing to percent-encode as a unit. Refused, with a sentence
saying so.
