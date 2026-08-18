# 0085 — a type says how its JSON is spelled

**Status:** accepted
**Amends:** [ADR 0077](./0077-a-lifetime-has-no-rendering-in-json.md)

## Context

`std.json` knows one union encoding, externally tagged:

```json
{"metrics": {"metric_name": "system.cpu.utilization", "agg": "avg", "threshold": 0.9}}
```

Most REST APIs use the other one, with the discriminator beside the variant's
own fields:

```json
{"signal": "metrics", "metric_name": "system.cpu.utilization", "agg": "avg", "threshold": 0.9}
```

There was no way to say that, so it was a hand-written `jsonStringify` and
`jsonParse` per type. An outside reading brought the evidence
([`docs/input_from_photon.md`](../input_from_photon.md)): four such unions in
one application, five string-cased enums riding along with them, and an
estimated +300 lines of codec that has to be kept correct by hand as variants
are added. **The JSON is already in SQLite columns and is what a browser
speaks**, so adopting Zig's shape is a data migration rather than a formatting
preference.

Two things about nilo made this worth more than the boilerplate it removes.

**A union anywhere sent the whole response to `std.json`.** `covers` is answered
for the *entire* value — one field it does not recognise takes the struct with
it ([`json.zig`](../../http/json.zig)) — and it did not recognise unions at all.
So a response carrying one paid `std.json`'s byte-at-a-time string escaping for
every string in it, which is the exact cost the generated writer exists to
avoid. Measured on Photon's own alert rule, 374 bytes:

| | ns, across six runs |
|---|---|
| `std.json`, externally tagged — **what nilo sent** | 248–317 |
| generated writer, externally tagged — same bytes | 86–93 |
| generated writer, internally tagged | 88–95 |
| control: the union flattened by hand, no union at all | 88–94 |

**2.8× to 3.2×**, and 3.4× to 3.5× on a 104-byte payload (81–88ns → 24–25ns).
Six interleaved runs of five pairs of 200,000, ReleaseFast. It is quoted as a
band rather than a figure because `std.json`'s own row moves by 28% between
runs while the other three sit inside 8ns of each other, which is the shape
CLAUDE.md's rule about margins narrower than their spread was written for.
[`bench/result/http.md`](../../bench/result/http.md) has the run and the command.

The last two rows are the ones that decided the shape. **Internal tagging costs
nothing against a struct with no union in it** — the two rows swap places
between runs — so the hand-written flattening those +300 lines buy is worth no
speed at all. And the second row against the third says internal against
external is not a performance question; it is only a wire-format one.

**And a union as a *body* was a compile error**, which ADR 0077 recorded as
correct on the grounds that "nothing in the type says which arm arrived". That
was true. `.tag` is the type saying it.

## Decision

**A type says how its JSON is spelled, with a marker, and nilo reads it.**

```zig
const Condition = union(enum) {
    pub const nilo_json = .{ .tag = "signal", .rename_all = .lowercase };
    pub const jsonParse = nilo.jsonParseFor(@This());

    metrics: MetricCondition,
    logs: LogCondition,
};
```

`.tag` is the discriminator's key. `.rename_all` is how a variant or an enum
tag is spelled on the wire. Both are read while compiling, and every name they
produce is a comptime string in the same `writeAll` as the punctuation around
it — which is why the table above shows the feature costing nothing.

**The marker is plain data**, the same rule and the same reason as
`nilo_openapi` ([ADR 0076](./0076-a-type-that-writes-its-own-json-says-so.md)):
a type in a module that imports nothing at all still has to be able to write it,
so there is no shared type to coerce to and every field is read by name.
`rename_all` arrives as an enum literal for the same reason.

**Unions get the generated writer whether or not they are marked.** An unmarked
one is written externally tagged, byte for byte what `std.json` writes, and the
tests hold the two against each other value by value. That is where most of the
saving actually lives, and it arrives for every existing program with a union in
a response without anybody changing a line.

### Writing is nilo's, reading is handed over

The asymmetry in the example above is the load-bearing part of this decision.

Writing needs no extra line, because nilo owns the call: `json.write` asks
`covers`, which asks the marker. Reading does, because **`std.json` is what
chooses a parser for a type** — it asks `std.meta.hasFn(T, "jsonParse")` — and
nothing can add a declaration to a type somebody else wrote. So the type hands
over a function nilo supplies.

An internally tagged object cannot be read in one pass: the variant is not known
until the discriminator turns up, and it may turn up after fields that belong to
it. The reader looks at the object twice. Over a complete input — which is every
parse nilo performs, because a body is read whole and bounded by `max_body` —
the bytes are already in memory, so the second look is a scan and no allocation:
`peekNextTokenType` puts the cursor on the value, `skipValue` finds its end, and
the span between them is read again for the discriminator and then handed to
`std.json` as the variant's own type. Anything streaming falls back to holding
the object as a `std.json.Value`.

`ignore_unknown_fields` has to be turned on to get the variant past the
discriminator, so **the check it would have done is put back by hand**: the
span's top-level keys are walked and anything that is neither the tag nor a
field of the variant is refused. Without that, a typo inside a tagged variant
would be dropped in silence where the same typo outside one is a 400 naming the
field, and nilo's error messages are a feature.

### The document says which encoding

A tagged union is `oneOf` with `discriminator`, each arm joined to its tag by
`allOf` — because the arm may already be a named component and nothing can be
merged into a `$ref`. Each arm pins its own value with a one-item `enum`, which
is what makes the choice unambiguous without a `mapping` that an anonymous
struct could not be given anyway.

**The two encodings are two shapes, not two renderings of one.** `rendersTheSame`
compares the tag, so ADR 0077's merge cannot put a client's one name on both.

## What was rejected

**A JSON parser of nilo's own**, so the marker could be the only line. It would
put unicode escapes, surrogate pairs and number edges in this repository, which
is exactly what `json.zig` refuses to do for floats and for the same reason. Two
declarations is the price of not owning that, and it is the cheaper half of the
trade.

**Deriving the encoding from a hand-written `jsonStringify`.** ADR 0076 rejected
this for schemas and the argument is unchanged: the function is arbitrary Zig,
there is no comptime reading of a function body, and a guess would be wrong in
the cases that matter.

**`rename_all` over struct field names.** serde's third-most-used attribute, and
the one shape here where the name is not a *value* on the wire. A variant's name
and an enum's tag are data; a field name is a key, and renaming keys is a second
naming scheme running beside the one the type already has. Nobody asked for it.

**serde's full case list.** `.snake_case` is what a Zig field name already is, so
asking for it is a misunderstanding rather than a no-op and gets a sentence.
What is left is the set that is unambiguous *from* snake_case. `.lowercase` and
`.UPPERCASE` join the words rather than keeping the underscore — `not_found`
becomes `notfound` — which is what serde does and what the names literally say;
`.SCREAMING_SNAKE_CASE` is the one that keeps it.

**A `select!`-shaped surface generally.** `.tag` and `.rename_all` are most of
what serde's attributes are actually used for. `content`, `flatten`, `skip`,
`default` and `with` are each a different feature and each has to arrive with a
caller, the same test every other marker here has had to pass.

## What it costs

**Allocations per request: none added.** The write side allocates nothing. The
read side scans a span already in memory; only a streaming source, which nilo
never hands it, holds a `std.json.Value`.

**Memory per idle connection: unchanged**, 4,669 bytes. Nothing here is held
across a request.

**Throughput: a saving**, 2.8× to 3.2× on a 374-byte payload carrying a union
and 3.4× to 3.5× on a 104-byte one, for every response with a union in it
whether or not the type is marked.

**Binary size: paid only by types that use it.** The marker generates no code
for a type that does not carry one, and `covers` reaches `jsonmark` only through
comptime branches the linker never sees.

Twelve refusals hold the ways of writing the marker wrong, taking the framework's
table from 63 to 75. The one worth naming is a tag whose name a variant already
uses: that is the only mistake here that would corrupt the wire — the key gets
written twice and a reader keeps whichever it likes — rather than fail.
