# A binding hands its failures to the handler

`Form(T)` and a JSON body were all-or-nothing. One field that would not convert was a 400 out of a fail function and the request was over, with nothing saying *which* field — one sentence about the first mistake found, and no way to ask about the rest.

For a framework whose claim is that the signature is the whole contract ([ADR 0015](./0015-what-zfast-borrows-and-from-whom.md)), not being able to name the field that broke the contract is the gap that contradicts the most. A 422 listing the fields is what a REST client expects, and showing a form again with one box marked needs the same thing from the other direction.

jetzig has the thin version — `expectParams(T)` returns null when anything is missing, which says *something* was wrong and not *what*. Naming the fields is the part worth building.

## `Bound(W)` wraps the slot rather than replacing it

```zig
fn signUp(b: zfast.Bound(zfast.Form(SignUp))) !zfast.Redirect(303) {
    const form = b.value() orelse return b.fail();
    …
}
```

One name over all three slots — `Bound(Form(T))`, `Bound(Query(T))`, `Bound(T)` for a JSON body — because the thing being decided is not *what* is read but *what happens when it does not fit*, and that is the same question in all three. Three names would have been three markers in the engine, three sets of refusals, and three places to keep in step.

The default stays fail-fast, unwrapped. Most endpoints want the 400 without writing a line for it, and an API that made every handler ask twice would be paying for the web's problem everywhere.

## `value()` is optional, and there is no way past it

A field that did not bind holds nothing worth reading. So the binding does not hand back a struct at all while any outcome carries a reason: `value()` returns `?T`, and the `orelse` is the compiler making the check happen.

The alternative — a `.value` field and a `.failed()` beside it — reads shorter and is the whole bug. A handler that forgets the check reads a zero nobody sent, silently, and that is a worse failure than the one this exists to fix. Zig has no other way to make a read conditional on a check, so the optional is the mechanism.

What that appears to cost is the form case: re-showing a page needs the fields that *did* work. It turns out not to be what a form wants. **The box holds what the person typed, not what it would have become** — you put `"soon"` back in the age field, not `0` — so what re-rendering needs is the text, and `b.given("age")` gives it for every field, bound or not. The field name is checked while compiling, because a typo there is otherwise an empty box nobody notices.

## The reasons are the conversions that already existed, and stop there

`.missing`, `.not_a_number`, `.not_true_or_false`, `.not_a_choice`, `.wrong_kind`. That is the whole vocabulary and it is meant to stay that way.

zfast's job stops at "this did not convert to a `u32`". Whether the age is plausible, whether the email has an `@`, whether the two passwords match — all of that is the application's, and a reason set that grew to answer any of it would be a validation language wearing a smaller name. That is the line [ADR 0018](./0018-the-trade-budget-has-three-axes.md)'s scope argument draws, and it is easier to hold now than after the first `.too_long`.

## Three things stay a hard 400

The rule: **a per-field failure needs a field to fail.** Everything else is about the request rather than about one of this endpoint's fields, so it keeps the answer it already had.

- **A body that is not a form at all**, or text that is not JSON. There is no binding to hand back, and `this endpoint takes a form, so the body has to be sent as …` says more than any list of field names could.
- **A field the endpoint has never heard of.** It is not one of `T`'s fields, so there is nowhere to record it — and `you sent "nme"` ends somebody's search, where `"name" is missing` sends them looking at the wrong end of the problem.
- **A mistake nested inside a field.** `describeField` names it down to eight levels (`address.street`), and collapsing that to "the `address` field is wrong" would trade a good sentence for a worse one. The outcomes array is one slot per top-level field by design; anything deeper is about the shape of the request.

## One place writes the sentence

`convert.convert` used to convert and fail in the same expression. It is split: `tryConvert` answers whether the text fits, `sayWhy` writes the sentence, and `convert` is the fail-fast wrapper over both. A binding prints through the same `sayWhy`.

This matters more than it looks. A binding's 422 and the endpoint next door's 400 are read side by side in one application, and two wordings for one mistake is what somebody files a bug about. A test asserts the two are byte-identical rather than trusting that they are.

`convert` now prints its sentence into a stack buffer and hands it on as a single `{s}`, which is what makes `sayWhy` the only copy. It costs 240 bytes of stack on a path where the request is already over, and it fixed something on the way: a message containing `{d}` used to be handed to the formatter as a format string.

## The document promises less, which is the correct amount

`typed.zig` already carried a flag for this — `can_reject`, "whether zfast can refuse this request before the handler runs". A binding sets it false.

So the generated document stops promising a 400 for that endpoint, and **nothing replaces it**. What the handler answers instead is a line in a function body, and [ADR 0024](./0024-a-failure-mode-belongs-in-the-return-type.md) is explicit that the document promises what the signature settles and nothing else. A 422 that appeared because `Bound` was in the argument list would be a guess: the handler may answer 200 with the form again, and often should.

That is the rule already written down, applied without amendment. No new machinery, and the schema for the body is unchanged — the request looks identical on the wire either way.

## What it costs

Nothing per failed field, which was the constraint going in.

`T`'s field count is settled while compiling, so the outcomes are one fixed array inside the value the handler already receives — on the fiber's stack, where the allocation budget cannot see it ([ADR 0018](./0018-the-trade-budget-has-three-axes.md)). `b.fail()` writes into the 240-byte failure buffer that already exists, so the 422 allocates nothing either, and the body is the one every failure answers with ([ADR 0025](./0025-every-failure-answers-with-the-same-json-body.md)) — this only fills in the sentence.

A body that parses pays for none of it: one parse, no second pass, every outcome left clear. The second parse on the failure path is the one `describeBadBody` was already paying for, on a request that was going to be refused anyway.

## Consequences

- `zfast.Bound`, plus `c.formCollecting`, `c.jsonCollecting` for a handler holding a `*Ctx`.
- A JSON body says `"quantity" has to be a whole number, not text` where a form says `not "soon"`, and that difference is kept rather than smoothed. In JSON a quoted value **is** text, so sending text where a number belongs is a mistake about the kind — which is the sentence the body parser has always given, and collecting several of them does not earn the right to reword it.
- The struct behind a failed binding has undefined fields in it and is deliberately never stamped with the request lifetime: `stamp` walks the struct writing markers, and following an undefined slice is the crash the marker exists to prevent. Safe because `value()` withholds the struct; the text that *is* reachable is stamped one field at a time.
- Five refusals: a binding of a binding, a binding of a non-struct, a bound form beside a plain one, a bound form whose field no form value can become, and `given("…")` for a field the struct does not have.
- The README stops explaining this absence. Templates remain refused, so the page-rendering half of that paragraph stands — what changes is that a mistyped email is now answerable.
