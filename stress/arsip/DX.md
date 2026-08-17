# The improvement list

Everything arsip hit that nilo should change, as items to pick up rather than as
a narrative. **An item earns its place by being something a second user would
hit too** — a mistake only this app made is not one.

Each says what happens, who runs into it, and what would have to change. The
ranking is by how many users hit it and how badly, not by how hard it is to fix.

Found in: **M0** scaffolding, **M1** the JSON API, **M1b** forms, uploads,
streamed bodies, blocking work and wildcards, **M2** accounts, passwords, sealed
sessions and settings from the environment.

**The number is an id, not a rank.** The table is sorted worst first, so a new
item can land at the top without renumbering the ones below it.

| # | Item | Area | Sev |
|---|---|---|---|
| 14 | [A type with its own `jsonStringify` gets a schema that contradicts the wire](#14) | openapi | **critical** |
| 11 | [Three published examples of the password and id API do not compile](#11) | docs | high |
| 13 | [There is no way to guard a prefix except two paths in it](#13) | middleware | high |
| 1 | [Identical generic instantiations get two identical schemas](#1) | openapi | high |
| 2 | [A service you forgot is a 500 in tests, not a name](#2) | services, testing | high |
| 3 | [Past eight levels a body error says nothing at all](#3) | convert | high |
| 15 | [A 422 has two shapes, and only one of them is nilo's](#15) | convert, docs | medium |
| 4 | [A `union(enum)` has a derivable schema and gets `{}`](#4) | openapi | medium |
| 5 | [`Bound(T)` cannot be built from the testing page](#5) | testing | medium |
| 6 | [The `Str`→`Text` walk is unaddressed past two levels](#6) | docs | medium |
| 12 | [Settings are read before the loop, and Zig 0.16 wants a loop to read them](#12) | config, docs | medium |
| 7 | [An alias does not name a generic instantiation](#7) | openapi docs | low |
| 8 | [The `zig init` template is not the one the guide edits](#8) | docs | low |
| 9 | [A mismatched `.optimize` has no warning, but its twin does](#9) | build | low |
| 10 | [A ReleaseSafe build is a minute and 677 MB](#10) | build | open |

---

<a name="1"></a>
## 1. Identical generic instantiations get two identical schemas

**What happens.** `Meta(Str)` is the body half of a shape and `Meta(Text)` is the
row half — the split nilo itself asks for
([ADR 0004](../../docs/adr/0004-request-arena-and-the-str-type.md)). Both end up
in `components/schemas`, as `Meta_Str` and `Meta_Text`, and they are
**byte-identical**. Same for `Section_Str` and `Section_Text`. A generated client
gets four types where two would do, and no field of any of them differs —
because what distinguishes the two instantiations is a Zig lifetime, and a
lifetime has no rendering in JSON.

**Who hits it.** Every application that follows the `Str`-in / `Text`-out rule on
a shape more than one level deep. That is everything past the size of
`examples/rest`.

**What to change.** When two schemas render byte-identically, emit one and point
both `$ref`s at it; keep the name without the suffix.
`guide/openapi.md#named-shapes` already handles the mirror case — two generics
that render to the *same name* and are *not* the same shape lose the name — so
the machinery to compare is close by. It wants an ADR rather than a patch,
because "renders identically" is a weaker equality than "is the same type" and
the document should say which one it means.

<a name="2"></a>
## 2. A service you forgot is a 500 in tests, not a name

**What happens.** `listen()` refuses to open the socket when a route needs a
service nobody registered, and the message is excellent:

```
error: service *main.Db was never registered, but 4 routes need it
("/users", "/users/:id", "/admin/stats", …) — call app.provide() before app.listen()
```

`nilo.testing.Client` does not call `listen()`. So in a test the same mistake is
a **500 with no explanation**, on every route that needed the service, and
nothing anywhere names the type. Two of arsip's tests failed exactly this way,
and the routes they tested worked perfectly over a real socket — which is the
worst possible shape for a clue, because the evidence points at the test.

**Who hits it.** Anybody who does what `guide/testing.md` recommends — builds an
App in a test and drives requests through it — and adds a service later. The
better the test coverage, the more places it lands at once.

**What to change.** **The check is already public.** `app.checkServices()` exists
and returns `error.MissingService`; `listen()` calls it and nothing else does. So
the fix is not new machinery, it is one call — `testing.Client.init` running it, or
`App.handleRequest` running it once on the first request. Failing that, one line in
`guide/testing.md` telling a reader to call it themselves, because a public
function nobody is told about is a function nobody calls. arsip hit this twice in
M1 and once more in M2 (`*const Settings`, newly required) before finding out it
existed.

<a name="3"></a>
## 3. Past eight levels a body error says nothing at all

**What happens.** nilo names the field that broke, at depth, and it is one of the
best things about it:

```
"sections[0].lines[0]" has to be text, not a number
"down.down.down.down.down.down.down.down" has to be an object, not text
```

At the ninth level that becomes:

```
{"error":"Bad Request","status":400}
```

Not a worse sentence — **no sentence**. No field, no reason, no hint that depth
is what happened. `guide/requests.md` does say "below that a mistake is a plain
400 again", so this is documented; what is not documented is how sheer the cliff
is from the client's side.

The happy path is unaffected at any depth: a valid nine-level body parses and
round-trips.

**Who hits it.** Anybody whose body wraps a domain shape in two envelopes. Eight
is generous, but it is a fixed budget spent by the *outer* structure, so the
first person to add a `{"data":{"attributes":…}}` wrapper pays it on shapes that
used to fit.

**What to change.** Cheapest useful fix: keep the fallback and say why —
*this body is nested deeper than nilo names fields to, so it cannot say which
part is wrong.* That turns a dead end into a fact. Raising the depth is a
separate question with a comptime cost attached.

<a name="4"></a>
## 4. A `union(enum)` has a derivable schema and gets `{}`

**What happens.** Two different answers to one question:

- As a **body**, a compile error in nilo's own words, naming the route and
  listing what a handler may ask for. Good message, found immediately.
- As a **return type**, it compiles and serialises correctly —
  `{"link":{"url":"…"}}`, externally tagged, exactly what `std.json` does. The
  API description says `"schema": {}`.

So the wire format is well defined and the document declines to describe it.
`guide/openapi.md` covers this under "a type with no JSON shape is `{}` —
anything, which is true", which is the honest answer for an *untagged* union. For
a `union(enum)` it is not: the shape is a `oneOf` of one-key objects, derivable
from the type with no annotation anywhere — which is the standard this feature
holds itself to everywhere else.

**Who hits it.** Anybody modelling a result that is one of several shapes. It is
the natural Zig way to say that, and the two halves of nilo currently disagree
about whether it is a thing nilo knows.

**What to change.** Either derive the `oneOf` for a tagged union, or refuse it in
the return position the way it is already refused in the argument position. The
one thing not worth keeping is the split, where it works and is undescribed.

<a name="5"></a>
## 5. `Bound(T)` cannot be built from the testing page

**What happens.** `guide/testing.md` shows every handler argument built by hand —
a query struct is `.{ .value = … }`, a body is the struct, a resolved value is
the struct. `Bound(T)` is none of those: it has private fields and is built by

```zig
nilo.Bound(NewDoc).from(value, @splat(.{}))
```

where the second argument is `[fields.len]convert.Outcome` and `@splat(.{})`
means "every field bound fine". `from` is public and `Outcome`'s fields all have
defaults, which is what makes the `@splat` work — none of which is in the guide,
so the route to it is reading `http/bound.zig`.

**Who hits it.** Anybody who takes the advice in
`guide/forms.md#when-one-field-is-wrong-and-the-rest-are-fine` and then writes a
test for that handler.

**What to change.** A `Bound(T).ok(value)` helper, plus the snippet in
`guide/testing.md`. The helper is the smaller change and removes the need to know
`Outcome` exists at all.

<a name="6"></a>
## 6. The `Str`→`Text` walk is unaddressed past two levels

**What happens.** `guide/services.md` gives two rules that are both right and
both cost the same thing. **A service takes `[]const u8`, not `Str`** — so
something converts at the boundary. **A read hands back a copy in the request
arena** — so something walks the shape on the way out. A row that owns its text
walks it on the way in. Three walks of one shape.

For `examples/rest` that is two `dupe` calls and the guide writes them inline.
For a document with an optional `meta`, a list of `sections` each holding a list
of `lines`, and a list of `tags`, it is three hand-written walks — three places
to forget a field the day somebody adds one.

arsip wrote [`src/copy.zig`](./src/copy.zig) instead: 137 lines, mostly comment,
one reflective `into(Target, allocator, source, .borrow|.own)` serving all three.
Writing it was not the friction — **realising it was needed was**, somewhere
around the fourth hand-written `dupe` loop.

**Who hits it.** Everybody, at the point their domain stops being flat.

**What to change.** Not necessarily the code: a converter that walks a user's own
types has opinions about what "the same shape" means, and shipping it means
owning those opinions forever. But `guide/services.md` currently ends at
"[`examples/orders`] does the whole of this on a domain with lines, an address
and a customer in it" — and what `orders` does is write the walks by hand. A
paragraph saying *past two levels, write the converter once by reflection* costs
nothing and saves the discovery.

<a name="7"></a>
## 7. An alias does not name a generic instantiation

**What happens.** `pub const NewDoc = Filing(Str);` reads well in Zig, and the API
description calls the shape `Filing_Str` — the name comes from the compiler's
name for the instantiation, and a Zig alias creates no new one.

**What to change.** One sentence in `guide/openapi.md#named-shapes`: *an alias is
not a name; write the struct out if the client's type name matters.*

<a name="8"></a>
## 8. The `zig init` template is not the one the guide edits

**What happens.** `guide/getting-started.md` correctly says `zig init` first —
`zig fetch --save` refuses without a `build.zig`. But the template it writes is a
library-and-executable scaffold around `src/root.zig`, and the guide's snippet is
a fragment assuming a different file. You replace the file rather than paste into
it, and delete `src/root.zig`.

**What to change.** One sentence: *replace the generated `build.zig` with this,
and delete `src/root.zig`.* The template is Zig's and cannot be changed here.

<a name="9"></a>
## 9. A mismatched `.optimize` has no warning, but its twin does

**What happens.** Not passing `.optimize` through to `b.dependency("nilo", …)`
builds nilo in Debug under a `ReleaseFast` program. The guide says so, and says
plainly that it is "legal and slow, and nothing warns about it".

What makes it an item is the symmetry: **forgetting `std_options_debug_io` has
the same symptom** — a server that is merely slow — and `listen()` *does* warn
about that one, on the grounds that a symptom you cannot see is one you will not
find. Two identical symptoms, one warning.

**What arsip added to this in M2.** It made the mistake itself, and in the place
that costs most. arsip's own `build.zig` passed `.optimize` through for the
executable and *not* for the test step, which loops over `.{ .Debug,
.ReleaseSafe }` — so the ReleaseSafe half of the suite ran a ReleaseSafe program
against a Debug nilo for two milestones, and the gate
`guide/testing.md` recommends was checking a configuration nobody deploys. Nothing
said so. The tell, once you know to look, is in the compile command line:
`-OReleaseSafe` next to `-Mroot=` and `-ODebug` next to `-Mnilo_http=`.

**Who hits it.** Anybody following the guide's own advice to run their suite in
both modes, because that is the code where the dependency is fetched twice.

**What to change.** Whether the build can see it at all is the open question: the
check compares the dependent's optimize mode against the one nilo was built with,
which is knowable at comptime. If it is reachable, it belongs beside the two
warnings `listen()` already gives — and it wants to fire for *test* artifacts too,
which is where it would actually have caught this.

<a name="10"></a>
## 10. A ReleaseSafe build is a minute and 677 MB

**What happens.** Measured on arsip at ~1,900 lines, this machine, cold compile:

| Mode | Compile | Compiler RSS |
|---|---|---|
| Debug | 3–6s | 199 MB |
| ReleaseSafe | 65–105s | 626–677 MB |

`guide/testing.md` recommends running your own suite in both modes, and is right
to — the bug behind
[ADR 0019](../../docs/adr/0019-a-response-owns-its-headers.md) passed 175 tests
in Debug and segfaulted in release. But a minute a run puts the second mode
outside the loop anybody actually runs.

**What is not established.** Whether any of it is attributable to a nilo feature.
`app.docs()` looked like ~15s until the runs were repeated: two docs-on builds
came in at 80s and 105s, so the gap sits inside the spread of one configuration
and the honest answer is *unchanged*. The binary difference is real and tiny —
536 bytes — consistent with `guide/openapi.md`'s own claim that the generator's
code is linked whether or not `docs()` is ever called.

**What to change.** Nothing yet. This is here so the next person starts from a
measured baseline rather than from "release builds feel slow". The first useful
run is the same measurement against a nilo example of known size, which would say
whether this is nilo, zio, or Zig.

<a name="11"></a>
## 11. Three published examples of the password and id API do not compile

**What happens.** Three separate published snippets, each one line, each wrong in
a way the compiler catches immediately:

| Where | What it shows | Why it does not compile |
|---|---|---|
| `guide/sessions.md`, `docs/reference.md`, `http/ctx.zig`'s own doc comment | `c.hashPassword(pw.huge_pages, form.password)` | `hashPassword` takes a `[]const u8`; `form.password` is a `Str`. Wants `.view()`. |
| `docs/reference.md`, `nilo_id` section | `uuid.v7(entropy, nilo.nowMillis())` | `nowMillis()` answers an `i64` and `v7` takes a `u64`. Wants `@intCast`. |
| `docs/reference.md`, the failing section | `nilo.fail(401, "…")` | `fail` is a namespace, not a function. Wants `fail.unauthorized`. |

None of them is hard to fix once you see the error, and every one of them is the
*first* thing a person writes when they reach that page. The third is the worst,
because it makes the reader think they have misunderstood the API rather than
found a typo.

**Who hits it.** Everybody who copies a line rather than retyping it, which is
everybody, and it is the same three lines for all of them. The `Str`/`[]const u8`
one is in **three** places, so it is a copy that has already been made twice.

**What to change.** The wording is not the fix — the fix is a build step, and this
repository already has the shape of one. `refusals/` is a directory of programs
that must *fail* to compile with a message nilo wrote, held by a table in
`build.zig`. The mirror image is a directory of the guide's own snippets that must
*succeed*, held the same way — `zig build examples-compile`, one file a snippet,
and a doc example that drifts becomes a red build rather than a reader's evening.
That is a bigger change than three edits and it is the one that stops the fourth.

<a name="12"></a>
## 12. Settings are read before the loop, and Zig 0.16 wants a loop to read them

**What happens.** `nilo_config` is built to run before anything opens — it reads
the environment where it lies and it opens no file, which is right and is
[ADR 0064](../../docs/adr/0064-a-dotenv-is-text-somebody-else-read.md). Two things
then need an `std.Io` that does not exist yet, because the thing that will supply
one is `listen()`, further down the same function:

- **reading the `.env`.** `config.Dotenv` takes *text*, so the program opens the
  file. In Zig 0.16 that is `std.Io.Dir.cwd().readFileAlloc(io, …)`, and `io` has
  to come from somewhere — so arsip stands up `std.Io.Threaded` for the length of
  one 98-byte read and tears it down again. Nine lines where the reference shows
  one.
- **printing the report.** `read.report(w)` wants a `*std.Io.Writer`, and getting
  one for stderr wants an `Io` for the same reason. arsip renders into a
  `std.Io.Writer.fixed(&buf)` and prints the buffer with `std.debug.print`, which
  needs nothing.

Both workarounds are three lines and neither is discoverable; the second one also
puts a fixed ceiling (8 KB here) on a report whose length depends on how many
settings are wrong.

**Who hits it.** Every program that wants a `.env` on a laptop, which the guide
itself recommends. The report half hits everybody, because a config failure is the
one thing you print before you have a server.

**What to change.** Nothing about the layering — `nilo_config` opening a file
would be the wrong fix and ADR 0064 says why. What is missing is
`guide/config.md` showing the whole of a real `main`: the threaded `Io` for the
read, the fixed writer for the report, and why each is there. Fifteen lines of
guide against a shape every reader has to rediscover.

<a name="13"></a>
## 13. There is no way to guard a prefix except two paths in it

**What happens.** Every API with accounts has the same shape: one prefix, almost
all of it behind a session, and two routes inside it that cannot be — you cannot
require a session to create one. nilo offers `app.use(mw)` and
`app.useOn(prefix, mw)`, and a `Group` offers `use` and `useOn(sub, mw)`. There is
nothing that removes a middleware, nothing that attaches one to a single route,
and no `exceptOn`. So `g.use(requireOperator)` on `/v1` guards `/v1/sign-up` too,
and sign-up answers 401 — **which is what it did**, on the first run of M2, in ten
tests at once.

Registering the open routes first does not help and is worth saying out loud:
chains are resolved in `listen()`, so mounting order carries no meaning
([ADR 0009](../../docs/adr/0009-middleware-is-an-onion-with-one-hole.md)). It
looks like it should work, which is the expensive part.

The three ways out, all bad in different ways:

1. **A path skip-list inside the middleware.** What arsip does
   ([`src/auth.zig`](./src/auth.zig), `guardOperator`). Default-deny, so a route
   added later is guarded by accident rather than exposed by accident — which is
   the right direction. The cost is that the exception is a **string** compared
   against `c.path()`, in a framework whose claim is that the compiler checks the
   contract. Rename the route and the guard protects a 404 while the real one goes
   open, and nothing fails to compile.
2. **`useOn` per resource subgroup.** Declarative, and default-*allow*: every new
   prefix is unguarded until somebody remembers. This is the one that ships a
   security hole eventually.
3. **Move the open routes out of the prefix** — `/sign-in` beside `/v1` rather
   than inside it. Free, and it means the URL layout is decided by the middleware
   rather than by the API.

There is a second cost stacked on (1): a `Middleware` is a bare
`*const fn (*Ctx, Next) anyerror!void` with nowhere to keep state, so the prefix
has to be a comptime parameter of a function returning one — and **a `Group` does
not publish the prefix it was built with**. `Group(prefix)` has `prefix` as a
comptime parameter of the type and no `pub const prefix` inside it, so a
`mount(g: anytype)` plugin cannot ask `g` where it is mounted. arsip's
`handlers.mount` therefore takes the prefix as a second argument and `main.zig`
keeps the two in step with a local constant. Parsing `@typeName(@TypeOf(g))` is
the only alternative and is not something to ship.

**Who hits it.** Everybody with a login form. This is not an edge case; it is the
second thing built after the first CRUD route.

**What to change.** Two changes, and the second is smaller than the first:

- `pub const prefix = prefix;` inside `Group(prefix)`. One line, and it makes a
  plugin able to know where it is — which is a thing several other features would
  want too.
- `useOn`'s opposite. The honest version is not a string skip-list promoted into
  the framework; it is **per-route middleware** — `g.postWith(mw_list, "/x", h)`,
  or a `g.open("/sign-up", signUp)` that marks a route as exempt from the group's
  chain. Either puts the exception where the route is declared, so renaming the
  route moves the exception with it and the compiler stays in the loop. That is the
  property nilo sells and the one the workaround gives up.

<a name="14"></a>
## 14. A type with its own `jsonStringify` gets a schema that contradicts the wire

**What happens.** `nilo_id`'s `Uuid` carries a `jsonStringify`, and that is the
whole reason `nilo_http` needs no knowledge of `nilo_id`
([ADR 0046](../../docs/adr/0046-randomness-is-an-argument.md)) — a `Uuid` in a
response comes out as text and the HTTP module never learns the type exists. It
works. Over the wire:

```json
{"public":"01a01053-4b22-7677-a5ba-b46a1f52d384","email":"wati@example.dev",…}
```

And `GET /openapi.json`, from the same running server, same field:

```json
"Uuid": {"type":"object","properties":{"bytes":{"type":"string"}},"required":["bytes"]}
```

**The description says object-with-a-`bytes`-field. The server sends a
36-character string.** `openapi.zig` reflects the struct's fields; `std.json` calls
`jsonStringify`; nothing reconciles the two. A client generated from this document
fails to parse **every response carrying a `public`** — which here is sign-up,
sign-in and whoami, i.e. all three account endpoints.

This is the only wrong schema in a 29-schema document, and everything around it is
right: `Upload` renders as `{"type":"string","format":"binary"}` under
`multipart/form-data`, `Patch(T)` renders as `anyOf: [T, null]` and drops out of
`required`, enums render their choices. That is what makes it dangerous — the
document is trustworthy enough that nobody checks this field.

**Who hits it.** Every application that returns a `nilo_id` value, which is the
one the reference recommends for public ids. Also every application returning a
`nilo_sql` `Row` with a `Timestamp` or a `Uuid` in it, for the same reason — those
two carry `jsonStringify` as well
([ADR 0039](../../docs/adr/0039-the-shape-of-a-query-is-settled-while-compiling.md)).

**What to change.** The repository already has the machinery and pointed it at the
other half of the problem: ADR 0039's `covers()` decides at comptime which types
the generated writer may touch and **sends anything with its own `jsonStringify`
down the general path**. The same test — `@hasDecl(T, "jsonStringify")` — is what
`openapi.zig` needs, and there are two honest answers once it has it:

1. Let a type say what it renders as. `pub const openapi_schema = .{ .type = "string", .format = "uuid" };` beside the `jsonStringify`, which is where the author of the custom writer already is, and is the same shape as `nilo_resolve` and `nilo_sql_type`. `Uuid` and `Timestamp` each gain one line and every downstream document is right.
2. Refuse to guess. A type with a `jsonStringify` and no `openapi_schema` becomes `{}` with a description saying the writer is custom — wrong but *visibly* wrong, which beats confidently wrong.

(1) is the fix; (2) is what should happen to a third-party type that has not
opted in. Both are better than reflecting fields the writer does not use.

<a name="15"></a>
## 15. A 422 has two shapes, and only one of them is nilo's

**What happens.** `Bound(T)` collects every field that would not *convert* and
answers one 422 naming all of them:

```json
{"error":"2 fields did not fit: \"kind\" is not one of the known choices (note, invoice, photo, contract): \"gold\"; \"visibility\" is not one of the known choices (private, team, public): \"loud\"","status":422}
```

That is the feature working, and it is genuinely good. But *validation* — the
rules a type cannot state, which is most of them — is a sequence of `fail`
functions, and the first one wins:

```
POST /v1/sign-up {"email":"bukan-alamat","name":"X","password":"pendek"}
{"error":"a password wants at least 10 characters; that one has 6","status":422}
```

Two things are wrong with that body and the client is told about one. Fix it, post
again, get told about the other — the twenty-questions game `Bound(T)` exists to
end, back again one layer up. So an application ends up answering 422 in two
shapes: nilo's collected one for type failures and its own single-sentence one for
rule failures, and a client has to handle both.

**Who hits it.** Everybody, at the first rule a Zig type cannot express: a minimum
length, an `@` in an address, an end date after a start date.

**What to change.** Not a validation DSL — that is a framework growing a second
language, and nilo's whole position is that the type is the contract. The smaller
thing is to let an application *add* to the collection `Bound` already has, so the
two kinds of failure come out as one answer in one shape. Something like
`body.also("password", "wants at least 10 characters")` before `body.fail()`, and
the existing message machinery does the rest. Failing that, the honest move is a
paragraph in `guide/forms.md` saying that rule checks do not join the collected
422 and showing how to accumulate them by hand — because right now the guide shows
the good half and stops.
