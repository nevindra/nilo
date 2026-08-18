# 0082 — a rule of your own joins the answer, not a second answer

**Status:** accepted
**Amends:** [ADR 0036](./0036-a-binding-hands-its-failures-to-the-handler.md)

## Context

`Bound(T)` ends the twenty-questions game for everything a *type* can settle.
Three fields that would not convert come back as one 422 naming three fields,
and that is the feature working:

```json
{"error":"2 fields did not fit: \"kind\" is not one of the known choices (note, invoice, photo, contract): \"gold\"; \"visibility\" is not one of the known choices (private, team, public): \"loud\"","status":422}
```

Then the handler starts checking the rules a Zig type cannot state — a minimum
length, an `@` in an address, an end date after a start date — and those are a
sequence of `fail` functions, where **the first one wins**:

```
POST /v1/sign-up {"email":"bukan-alamat","name":"X","password":"pendek"}
{"error":"a password wants at least 10 characters; that one has 6","status":422}
```

Two things are wrong and the client is told about one. Fix it, post again, learn
about the other — the game `Bound` exists to end, back one layer up. Worse, the
application now answers 422 in **two shapes**: nilo's collected sentence for a
type failure and its own single sentence for a rule, and a client has to handle
both.

The rules themselves are not nilo's business and this ADR does not make them so.
ADR 0036 is right: a reason set that grew to answer "is this age plausible"
would be a validator wearing a smaller name. But **the answer is nilo's
business** — the 422, the wording, the shape — and the application had no way to
put anything into it.

## Decision

**`must` adds the application's own sentence to the failures the binding
already holds.**

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

nilo writes no rule and knows none. It supplies the **label** — `"email"` in a
body or a form, `?page` in a query string — and the collecting, and the status,
and the order; the application supplies the words. That split is the whole
design: everything nilo contributes is something it already contributes to its
own sentences, so the two cannot come out looking like they were written by
different programs.

Four smaller decisions fell out of it.

**The bool is the rule *holding*, not failing.** `must("password", len >= 10,
…)` reads as the sentence it makes. A `fails` parameter would have read
backwards at every call site and been negated wrong at some of them.

**`reason` becomes `?Reason`.** A rule failure genuinely has no conversion
reason, and `Reason` is a closed list with a paragraph in `convert.zig` saying
so. Making it optional is the type stating which kind of failure this is;
adding a `.rule` member would have widened the one vocabulary this framework
promised not to widen, in the file that promises it.

**nilo's own sentence wins, and on one field the first rule wins.** A rule
checked against a field that never bound was checked against nothing. And two
sentences about one field is one too many — the same reason one conversion
failure per field is all there ever was.

**`must` returns a different type.** `Checked` is `Bound` plus one `[]const u8`
per field, and it is built on the handler's frame by the first `must`. A handler
that checks no rules never builds one. That matters because a handler's stack is
per-connection ([ADR 0063](./0063-a-handlers-stack-is-per-connection.md)): had
the room lived on `Bound` itself, every connection touching any bound route
would have paid for a feature it does not use.

Alongside it, **`Bound(W).ok(value)`** — the binding where everything bound.
`from(value, outcomes)` is the engine's constructor and wants an `Outcome` per
field; a test calling a handler directly had to write
`Bound(NewDoc).from(value, @splat(.{}))` and therefore had to know that
`Outcome` exists, that its fields all default, and that `@splat` is what "all
fine" spells. None of that was on the testing page, so the route to it was
reading `bound.zig`.

## What was rejected

**A validation DSL** — `@"min(10)"` in a field name, a `nilo_rules` decl, a
`Validate(T)` wrapper. This is the framework growing a second language to say
things Zig can already say in an `if`, and every one of them ends up needing an
escape hatch for the rule it cannot express. nilo's position is that the type is
the contract; a rule that is not in the type stays in the handler.

**`b.also("password", "wants at least 10 characters")`, unconditional.** It is
what the report that found this suggested, and it needs a statement rather than
an expression: `if (…) checked = checked.also(…)`, with the reassignment written
out at every rule because a handler parameter is immutable. The condition inside
is what makes a chain possible, and a chain is what makes the collected answer
the *default* rather than something you can half-do.

**Mutating the binding in place** — `b.must(…)` taking `*Self`. A handler
parameter is const in Zig, so this needs `var mine = b;` first, which is a line
about Zig rather than about the request.

**Keeping `Reason` non-optional by giving a rule failure `.wrong_kind`.** It
would have kept one field's type unchanged and made every reader of it wrong.

**A paragraph in the guide saying rules do not join the collected 422.** The
honest fallback, and the report named it as one. It documents the seam instead
of closing it, and every application then writes the same accumulator.

## What it costs

**Nothing on three axes, and stack on the fourth — only when used.**

- Allocations per request: none. `Checked` is one `[]const u8` per field, on the
  handler's frame; the message is written into the same fixed `max_message`
  buffer `fail` already uses.
- Memory per idle connection: `@sizeOf(Bound(W)) + fields.len * 16` while a
  handler that calls `must` is on the stack, against `@sizeOf(Bound(W))` before.
  A five-field form is 80 bytes, for the connections that reach that route. A
  handler that calls no `must` is unchanged, which is why `Checked` is a
  separate type.
- Throughput and p99: unchanged. Nothing here is on the path of a request that
  binds — `must` is reached only after a handler has already decided to refuse.
- Binary size: one `say_rule` function pointer per field in the comptime table,
  and one more sayer instantiation per bound struct in the program. Under the
  noise floor of the `size` step, which did not move.
