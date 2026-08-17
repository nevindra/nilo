# The improvement list

Everything arsip hit that nilo should change, as items to pick up rather than as
a narrative. **An item earns its place by being something a second user would
hit too** — a mistake only this app made is not one.

Each says what happens, who runs into it, and what would have to change. The
ranking is by how many users hit it and how badly, not by how hard it is to fix.

Found in: **M0** scaffolding, **M1** the JSON API, **M1b** forms, uploads,
streamed bodies, blocking work and wildcards.

| # | Item | Area | Sev |
|---|---|---|---|
| 1 | [Identical generic instantiations get two identical schemas](#1) | openapi | high |
| 2 | [A service you forgot is a 500 in tests, not a name](#2) | services, testing | high |
| 3 | [Past eight levels a body error says nothing at all](#3) | convert | high |
| 4 | [A `union(enum)` has a derivable schema and gets `{}`](#4) | openapi | medium |
| 5 | [`Bound(T)` cannot be built from the testing page](#5) | testing | medium |
| 6 | [The `Str`→`Text` walk is unaddressed past two levels](#6) | docs | medium |
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

**What to change.** Run the same check the first time a request goes through an
App, or expose it as `app.check()` and have `testing.Client.init` call it.
`guide/testing.md`'s worked example builds an App by hand and provides one
service, so the gap stays invisible until your second one.

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

**What to change.** Whether the build can see it at all is the open question: the
check compares the dependent's optimize mode against the one nilo was built with,
which is knowable at comptime. If it is reachable, it belongs beside the two
warnings `listen()` already gives.

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
