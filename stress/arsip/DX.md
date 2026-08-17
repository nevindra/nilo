# What fought back

The findings log. One entry per thing that cost time, in the milestone that
found it, with what it would take to fix. **An entry earns its place by being
something a second user would hit too** — a mistake only this app made is not a
finding.

Severity is about the user, not the code:

- **blocker** — there is no way to do it; you stop.
- **friction** — there is a way, and you had to find it somewhere other than
  where you looked first.
- **paper cut** — you found it, it just cost a minute you did not expect.
- **note** — nothing is wrong; it is worth writing down before it becomes one.

---

## M0 — Scaffold

### `zig init` gives you a `build.zig` you delete rather than edit — paper cut

`docs/guide/getting-started.md` says `zig init` first, correctly: `zig fetch
--save` refuses without a `build.zig`. But the `build.zig` it writes is a
library-and-executable template around `src/root.zig`, and the guide's snippet
is a fragment that assumes a different file. You replace the file rather than
paste into it, and you delete `src/root.zig`.

That is Zig's template rather than nilo's, and nothing can be done about the
template. What could be done is one sentence in the guide: *replace the
generated `build.zig` with this, and delete `src/root.zig`.*

### A dependent has to guess `.optimize` matters — note

The guide does say to pass `.optimize` through to the dependency, and says
plainly that not doing so is "legal and slow, and nothing warns about it". It
is in the right place and it is easy to skim past, which is what makes it worth
recording: the failure mode is a server that is merely slow, and that is the
same failure mode `std_options_debug_io` has — which nilo *does* warn about at
`listen()`. Two symptoms, one warning.

Whether the build can see it at all is the open question: the check would have
to compare the dependent's optimize mode against the one nilo was built with,
which is knowable at comptime. Worth asking before M7.

### Four of the eight modules have no guide page — note, to be tested at M2–M5

`docs/guide/README.md` is explicit about it rather than silent: `nilo_s3`,
`nilo_fetch`, `nilo_config` and `nilo_id` are pointed at sections of
`docs/reference.md`, and `nilo_pw` at the Sessions page. So this is a stated
position, not an oversight, and the interesting question is whether it holds:
**can you adopt a module from a reference section alone?**

M2 answers it for `nilo_config` and `nilo_id`, M4 for `nilo_s3`, M5 for
`nilo_fetch`. Recording it now so the answer is measured rather than
remembered — if the reference turns out to be enough, that is a finding worth
having too, and it costs the project four pages it was going to write.

---

## M1 — The API

1,381 lines across six files, 42 tests, both optimize modes. Everything the
milestone set out to build got built; nothing had to be given up. What follows
is what it cost.

### Two generic instantiations that render identically get two identical schemas — friction

`Meta(Str)` is the body half and `Meta(Text)` is the row half — one shape, the
`Str`/`[]const u8` split the framework itself asks for
([ADR 0004](../../docs/adr/0004-request-arena-and-the-str-type.md)). The
generated document holds both, under `Meta_Str` and `Meta_Text`, and they are
**byte-identical**:

```
"Meta_Str":  {"properties":{"author":{"type":"string"}, …}}
"Meta_Text": {"properties":{"author":{"type":"string"}, …}}   # the same object
```

Same again for `Section_Str` and `Section_Text`. A generated client gets four
types where two would do, and no field of any of them differs — because the
thing that distinguishes the two instantiations is a *Zig* lifetime, and a
lifetime has no rendering in JSON.

`guide/openapi.md` names the near-miss and stops one short of it: where two
generics render to the **same name** and are not the same shape, neither keeps
the name. The case here is the mirror — **different names, the same shape** —
and it is not the exotic one. It is what happens to every application that
follows the `Str`-in/`Text`-out rule on a shape more than one level deep, which
is to say every application past the size of `examples/rest`.

The fix looks small and is a decision rather than a patch: when two schemas
render byte-identically, emit one and point both `$ref`s at it. The name to
keep would presumably be the one without the suffix. Worth an ADR, because
"identical rendering" is a weaker equality than "the same type" and the
document should say which one it means.

### An alias does not name a generic instantiation — paper cut

`pub const NewDoc = Filing(Str);` reads well in Zig and the API description
calls the shape `Filing_Str`, because the name comes from the compiler's name
for the instantiation and a Zig alias creates no new one. Nothing is wrong; it
is just that the name a client sees is decided somewhere other than where you
thought you decided it. One sentence in `guide/openapi.md#named-shapes` would
cover it — *an alias is not a name; write the struct out if the client's type
name matters.*

### A tagged union: refused going in, undescribed coming out — friction

Two different answers to one question, and both are defensible on their own:

- **As a body** it is a compile error, in nilo's own words, naming the route and
  listing what a handler may ask for. Good message, found immediately.
- **As a return type** it compiles, and serialises correctly —
  `{"link":{"url":"…"}}`, externally tagged, exactly what `std.json` does.
  The API description says `"schema": {}`.

So the wire format is well-defined and the document declines to describe it.
`guide/openapi.md` covers this under "a type with no JSON shape is `{}` —
anything, which is true", and for an untagged union that is the honest answer.
For a `union(enum)` it is not: the shape is a `oneOf` of one-key objects and it
is derivable from the type with no annotation anywhere, which is the standard
this feature holds itself to everywhere else.

Nothing was blocked — `Advanced` is a union inside the store and never crosses
the wire, and where a union *would* have crossed, an explicit struct was
clearer anyway. Recording it because the next person will spend the same twenty
minutes finding out, and because the two halves currently disagree about
whether a union is a thing nilo knows.

### `Bound(T)` is the one handler argument a test cannot build from the guide — friction

`guide/testing.md` shows every other argument built by hand — a query struct is
`.{ .value = … }`, a body is the struct, a resolved value is the struct. A
`Bound(T)` is neither: it has private fields and is built by

```zig
nilo.Bound(NewDoc).from(value, @splat(.{}))
```

where the second argument is `[fields.len]convert.Outcome` and `@splat(.{})`
means "every field bound fine". `from` is public and documented in
`http/bound.zig`; `Outcome`'s fields all have defaults, which is what makes the
`@splat` work. None of that is in the guide, so the route to it is reading the
framework's source — which is exactly the thing a testing page exists to save.

Two sentences and the snippet above in `guide/testing.md` closes it. A
`Bound(T).ok(value)` helper would close it better, and is the smaller change of
the two.

### The `Str` boundary is one walk per shape, and the walk is yours to write — note

`guide/services.md` gives two rules that are both right and both cost the same
thing on a nested shape. **A service takes `[]const u8`, not `Str`** — so
something has to convert at the boundary. **A read hands back a copy in the
request arena** — so something has to walk the shape on the way out too. And a
row that owns its text has to walk it on the way in. Three walks of one shape.

For `examples/rest` that is two `dupe` calls and the guide writes them inline.
For a document with an optional `meta`, a list of `sections` each holding a list
of `lines`, and a list of `tags`, it is three hand-written walks — three places
to forget a field the day somebody adds one.

What this app did instead is [`src/copy.zig`](./src/copy.zig): 137 lines,
mostly comment, one reflective `into(Target, allocator, source, .borrow|.own)`
that serves all three. It is not hard code and writing it was not the friction
— **realising it was needed was**, somewhere around the fourth hand-written
`dupe` loop.

This is a note rather than a finding because there is a real argument for
leaving it out: it is `@typeInfo` walking a user's own types, it has opinions
about what "the same shape" means, and a framework that shipped it would own
those opinions forever. But `guide/services.md` currently ends at "[`examples/
orders`] does the whole of this on a domain with lines, an address and a
customer in it" — and what `orders` actually does is write the walks by hand.
A paragraph saying *past two levels, write the converter once by reflection*
would have saved the discovery, whether or not the converter ever ships.

### What did not fight back

Worth recording, because a stress test that only lists complaints is not a
measurement:

- **The keyword field.** `@"type"` round-trips as `type` through the body, the
  response, the enum error message (`"type" is not one of the known choices`)
  and the API description. It was on the list as a likely break and was not one.
- **Depth.** `"sections[0].lines[0]" has to be text, not a number` — a list,
  inside a struct, inside a list, named exactly. Nothing else in this class of
  framework does that.
- **`Patch(T)` over a struct.** The guide only shows `Patch(Str)`.
  `Patch(Meta(Str))` works, and `{"meta":null}` versus `{}` versus
  `{"meta":{…}}` arrive as three distinguishable things.
- **The positional rule across a group prefix.** `group("/v1")` +
  `"/folders/:folder/docs"` + `fn (…, folder: Str, …)` needed no thought at all.
- **`listen()` counting the undescribed route.** `1 of 13 routes write their
  own response` is exactly right, and it is the sort of thing that is normally
  found six months later by a client generator.
