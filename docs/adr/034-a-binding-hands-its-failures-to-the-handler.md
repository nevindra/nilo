# A binding hands its failures to the handler

**Status:** accepted
**Topic:** [request-input](../design/request-input.md)

## Context

`Form(T)` and a JSON body were all-or-nothing. One field that would not convert was a 400 out of a fail function and the request was over, with nothing saying *which* field, one sentence about the first mistake found, and no way to ask about the rest. For a framework whose claim is that the signature is the whole contract ([ADR 014](./014-what-nilo-borrows-and-from-whom.md)), not being able to name the field that broke the contract is the gap that contradicts the most. A 422 listing the fields is what a REST client expects, and showing a form again with one box marked needs the same thing from the other direction.

Naming a field runs into two walls of its own. First, the walk that names a nested field (`"lines[1].qty" has to be a whole number, not text`) has to stop somewhere: an application with a settings document nine levels deep hit a mistake four levels below where the naming stops, a string where a number went, and the 400 that came back said nothing at all, because the fallback for "nothing here can do better" was the same fallback for "text that is not JSON at all". From the client's side those two are indistinguishable. Second, once a type's own failures are named, the rules a Zig type cannot state (a minimum length, an `@` in an address, two passwords matching) are still a sequence of `fail` calls where the first one wins, and the application ends up answering 422 in two shapes: nilo's collected sentence for a type failure and its own single sentence for a rule.

## Decision

**A binding wraps the slot rather than replacing it, hands back an optional value, names every field that did not fit (including why the walk itself gave up), and lets the application add its own sentence to the same answer.**

### `Bound(W)` wraps the slot

```zig
fn signUp(b: nilo.Bound(nilo.Form(SignUp))) !nilo.Redirect(303) {
    const form = b.value() orelse return b.fail();
    …
}
```

One name over all three slots, `Bound(Form(T))`, `Bound(Query(T))`, `Bound(T)` for a JSON body, because the thing being decided is not *what* is read but *what happens when it does not fit*, and that is the same question in all three. The default stays fail-fast, unwrapped: most endpoints want the 400 without writing a line for it.

### `value()` is optional, and there is no way past it

A field that did not bind holds nothing worth reading, so the binding does not hand back a struct at all while any outcome carries a reason: `value()` returns `?T`, and the `orelse` is the compiler making the check happen. The alternative, a `.value` field and a `.failed()` beside it, reads shorter and is the whole bug: a handler that forgets the check reads a zero nobody sent, silently.

**The box holds what the person typed, not what it would have become.** You put `"soon"` back in the age field, not `0`, so what re-rendering needs is the text, and `b.given("age")` gives it for every field, bound or not. The field name is checked while compiling.

### The reasons are the conversions that already existed, and stop there

`.missing`, `.not_a_number`, `.not_true_or_false`, `.not_a_choice`, `.wrong_kind`, `.not_that_type` (a type that parses itself said no, [ADR 113](./113-a-path-param-can-parse-itself.md)). That is the whole vocabulary. nilo's job stops at "this did not convert to a `u32`"; whether the age is plausible, whether the email has an `@`, whether two passwords match is the application's, and a reason set that grew to answer any of it would be a validation language wearing a smaller name.

### Three things stay a hard 400

The rule: **a per-field failure needs a field to fail.** Everything else is about the request rather than about one of this endpoint's fields.

- **A body that is not a form at all**, or text that is not JSON. There is no binding to hand back.
- **A field the endpoint has never heard of.** It is not one of `T`'s fields, so there is nowhere to record it. Every such key is named, together, in the list of fields the 400 carries (`unknown_field`, [ADR 024](./024-every-failure-answers-as-json.md)).
- **A mistake nested inside a field.** `describeField` names it down to eight levels, the same limit `openapi.schemaOf` and `str.stamp` use because a type holding one of its own has to stop somewhere, and every one of them is in the list, under the path the client sent (`address.street`, `items.0.qty`).

Hard means the handler never sees it, not that the status is fixed. A JSON body whose type says `.misfit = 422` answers the ones that are JSON of the wrong shape (a body that is not an object, an unknown key, a nested mistake) with that 422 instead, and text that is not JSON stays the 400 ([ADR 251](./251-json-that-does-not-fit-can-be-a-422.md)).

### The answer carries the fields, not only a sentence about them

`b.fail()` and `checked.fail()` stop the request with a 422 whose body is the sentence and, beside it, `fields`: one entry for each failure with `field`, `code`, `message` and `expected` (ADR 024). A form outlines `email` from `field` and does not parse English out of "and N more". The entries are the same `Failures` the handler iterates, in the same order, so the list and `b.failures()` cannot disagree; a rule of the application's own (`must`, `nilo_check`) is `code: "rule"` and has no `expected`. The sentence is still the 240 bytes it was, ending in "and N more"; **the list is not cut to fit it**, because each entry is kept whole in the request arena (at most 64 of them), so a form of thirty boxes names thirty. `Reason` is not what a client sees: `bound.codeOf` maps it onto `nilo.FieldCode` in one `switch`.

A plain `Form(T)`, JSON body or `Query(T)` has the same answer as a `Bound` that failed, as a 400: when its read stops at a field, the request is read again with the collecting readers this section is about, and `bound.refuseAll` words what they found. One field wrong is the sentence it always was.

### The walk says when it hit its own ceiling

The eight-level walk used to go silent exactly where it ran out of room: a shape past the ceiling produced the same bare `{"error":"Bad Request","status":400}` as text that was not JSON at all, throwing away everything the framework did know (that the JSON parsed, that it was an object, that the shape is wrong somewhere below a known depth).

**When the walk finds nothing to name but did reach the ceiling, it says the ceiling was reached:**

```
the request body is valid JSON and does not fit this endpoint, but it is nested
deeper than 8 levels, which is as far as nilo follows a body, so it cannot say
which part is wrong. The mistake is somewhere below that.
```

Mechanically it is an out-parameter: `describeField` and `describeObject` take a `deeper: *bool`, and the one place that returns early on the budget sets it, but only when the value it is looking at actually has something inside it (`hasInsides`). A `Str` sitting at level eight is the *bottom* of a body that fits, not evidence of one that does not, and an empty list has nothing below it either; without that check every deep-but-fine body that failed for some other reason would be told it was too deep. Both callers get it, the 400 that lists fields and the collected 422's fallback path, because a `Bound(T)` whose refusal is nested has the same dead end.

### An application's own rule joins the answer, not a second answer

`Bound(T)` ends the twenty-questions game for everything a *type* can settle, but the rules a Zig type cannot state (a minimum length, an `@` in an address, an end date after a start date) used to be a sequence of `fail` calls answering one problem at a time, in a second shape from nilo's own collected sentence.

**`must` adds the application's own sentence to the failures the binding already holds:**

```zig
const in = b.value() orelse return b.fail();

const checked = b
    .must("password", in.password.view().len >= 10, "wants at least 10 characters")
    .must("email", hasAt(in.email.view()), "has to look like an address");
if (checked.failed()) return checked.fail();
```

```
2 fields did not fit: "email" has to look like an address;
"password" wants at least 10 characters
```

nilo writes no rule and knows none. It supplies the label (`"email"` in a body or a form, `?page` in a query string), the collecting, the status and the order, all things it already supplies to its own sentences, and the application supplies the words. Four smaller decisions follow:

- **The bool is the rule *holding*, not failing.** `must("password", len >= 10, …)` reads as the sentence it makes.
- **`reason` on an outcome stays `?Reason`.** A rule failure has no conversion reason, and `Reason` is a closed list; adding a `.rule` member would widen the one vocabulary this framework promises not to widen.
- **nilo's own sentence wins, and on one field the first rule wins.** A rule checked against a field that never bound was checked against nothing, and two sentences about one field is one too many.
- **`must` returns a different type, `Checked`.** `Checked` is `Bound` plus one `[]const u8` per field, built on the handler's frame by the first `must`, so a handler that checks no rules never builds one, which matters because a handler's stack is per-connection ([ADR 062](./062-where-a-connection-waits-is-what-it-costs.md)).

Alongside it, `Bound(W).ok(value)` is the binding where everything bound, for a test calling a handler directly without going through `from(value, outcomes)` and having to know what an all-fine `Outcome` looks like.

### A rule about the struct goes on the struct

`must` in a handler is for a rule that needs the request, such as "already registered" needing a database. A rule the struct can settle on its own, such as "confirm matches password", is instead a `nilo_check` declaration read off the struct itself, run once every field has bound: [ADR 193](./193-text-with-a-shape-is-a-type-and-a-rule-about-the-struct-is-a-function-on-it.md) is what built it and is where that design and its own rejected alternatives live.

### One place writes the sentence

`convert.convert` used to convert and fail in the same expression. It is split: `tryConvert` answers whether the text fits, `sayWhy` writes the sentence, and `convert` is the fail-fast wrapper over both. A binding prints through the same `sayWhy`, so a binding's 422 and the endpoint next door's 400 read as one program having written both; a test asserts the two are byte-identical rather than trusting that they are. `convert` prints its sentence into a stack buffer and hands it on as a single `{s}`, which is what makes `sayWhy` the only copy, and fixed a message containing `{d}` once being handed to the formatter as a format string.

### The document promises less, which is the correct amount

`typed.zig` carries `can_reject`, whether nilo can refuse this request before the handler runs, and a binding sets it false. The generated document stops promising a 400 for that endpoint, and nothing replaces it: [ADR 023](./023-a-failure-mode-belongs-in-the-return-type.md) is explicit that the document promises what the signature settles and nothing else. A 422 that appeared because `Bound` was in the argument list would be a guess, since the handler may answer 200 with the form again, and often should.

## What was rejected

**A validation DSL**, `@"min(10)"` in a field name, a `nilo_rules` decl, a `Validate(T)` wrapper. This is the framework growing a second language to say things Zig can already say in an `if`, and every one of them ends up needing an escape hatch for the rule it cannot express. nilo's position is that the type is the contract; a rule that is not in the type stays in the handler (or, once it can be settled on the struct alone, in `nilo_check`).

**`b.also("password", "…")`, unconditional.** It needs a statement rather than an expression, with the reassignment written out at every rule because a handler parameter is immutable. The condition inside `must` is what makes a chain possible, and a chain is what makes the collected answer the default rather than something you can half-do.

**Mutating the binding in place**, `b.must(…)` taking `*Self`. A handler parameter is const in Zig, so this needs `var mine = b;` first, a line about Zig rather than about the request.

**Keeping `Reason` non-optional by giving a rule failure `.wrong_kind`.** It would keep one field's type unchanged and make every reader of it wrong.

**A paragraph in the guide saying rules do not join the collected 422.** The honest fallback; it documents the seam instead of closing it, and every application then writes the same accumulator.

**Raising `max_body_depth`.** It moves the ceiling without removing it: the walk is `inline for` over the fields at every level, the depth is a comptime parameter, and each extra level is more instantiations of `describeObject` for every body type in the program. The number would still be silent at the bottom.

**Describing the value with no name**, "something nested is a number where an object goes". The type is known at the ceiling, so this is writable, but it reads as though the framework is being coy: it clearly knows something and will not say where.

**Quoting the deepest name reached**, `down.down.down.down.down.down.down.down` and then "below here". Wrong in the common case: the ceiling is reached by walking *every* field, so the name in hand when `deeper` is set is whichever field the `inline for` visited last, and it would point confidently at the wrong branch.

## What it costs

| Axis | Cost |
|---|---|
| Allocations per request | None. `T`'s field count is settled while compiling, so the outcomes are one fixed array inside the value the handler already receives, on the fiber's stack, where the allocation budget cannot see it ([ADR 017](./017-the-trade-budget-has-four-axes.md)). |
| Memory per idle connection | None from the binding itself. `Checked` adds `fields.len * 16` bytes, only while a handler that calls `must` is on the stack (a five-field form is 80 bytes), and a handler that calls no `must` is unchanged, which is why `Checked` is a separate type from `Bound`. |
| Throughput and p99 | Unchanged for a body that parses: one parse, no second pass, every outcome left clear. The second parse on the failure path is the one `describeBadBody` was already paying for, on a request that was going to be refused anyway. `must` runs only after a handler has already decided to refuse. |
| Binary size | One `say_rule` function pointer per field in the comptime table, and one more sayer instantiation per bound struct in the program; under the noise floor of the size step. |

`b.fail()` and `checked.fail()` write the sentence into the 240-byte failure buffer every connection already carries (`@sizeOf(Failure)` is 256, [ADR 024](./024-every-failure-answers-as-json.md)), and the list into the request arena: three allocations and one for each failed field, on the failure path of a request that was refused anyway, where this used to allocate nothing. The binding's own `Outcomes` are still on the fiber's stack and still cost the success path nothing. The ceiling message adds one string in `.rodata` the failure path already pays for, and `deeper` is one stack `bool` in a function that runs only on a request already refused.

## Consequences

- `nilo.Bound`, `nilo.Bound(W).Checked`, plus `c.formCollecting`, `c.jsonCollecting` for a handler holding a `*Ctx`.
- A JSON body says `"quantity" has to be a whole number, not text` where a form says `not "soon"`, and that difference is kept rather than smoothed: in JSON a quoted value **is** text.
- The struct behind a failed binding has undefined fields in it and is deliberately never stamped with the request lifetime: `stamp` walks the struct writing markers, and following an undefined slice is the crash the marker exists to prevent. Safe because `value()` withholds the struct; the text that *is* reachable is stamped one field at a time.
- Refusals: a binding of a binding, a binding of a non-struct, a bound form beside a plain one, a bound form whose field no form value can become, and `given("…")` for a field the struct does not have.
- The README stops explaining the silent-ceiling gap: templates remain refused, so the page-rendering half of that paragraph stands, and what changes is that a mistyped email, or a body nested past the ceiling, is now answerable.
