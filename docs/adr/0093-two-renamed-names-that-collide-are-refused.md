# 0093 — two renamed names that collide are refused

**Status:** accepted

## Context

`rename_all` maps a name to its wire spelling one name at a time. Nothing
looked at the set.

`.lowercase` and `.UPPERCASE` join the words rather than keeping the
underscore — that is what serde does and what the name literally says — so
`not_found` and `notfound` both come out `notfound`. Two variants under one
name on the wire is not a spelling problem. The writer emits the same key or
value twice, and `fromSpan` returns whichever variant the `inline for` reaches
first, which is **declaration order**, and nothing anywhere says so. Reordering
two variants would then silently change which one a request parses into.

`checkTag` already refuses the neighbouring mistake, and its comment is the
whole argument for this one:

> a variant whose own struct already has a field by the tag's name emits that
> key twice, and which one a reader takes is its business.

The same sentence applies here word for word, and that is what made this worth
doing rather than noting: the repository had already decided how it feels about
this class of bug, in a comment, one function away.

## Decision

**`of(T)` checks the renamed names against each other, the way it already
checks the tag.**

`checkRenames(T, case)` is an `O(n²)` compare over the names the type already
produces, beside `checkTag` in the one function every marked type goes through.
It runs while compiling, on a path that never reaches a binary; a union of
eight variants is 28 comparisons of short literals, once.

It applies to an **enum's values** and a **union's variants**, which is exactly
what `rename_all` renames — a payload struct's own fields are left alone
(`json.zig`'s "a tag and a case together rename the variant but not its
fields"). On anything else it returns without looking, because there is nothing
there that could collide.

The message names both names, what they both became, and the way out:

```
nilo: `Severity` asks for `.rename_all = .lowercase`, and its values
`not_found` and `notfound` both come out as "notfound".
  Two of them under one name on the wire is not a spelling problem: a reader
takes whichever it meets first, which is declaration order, and nothing says so.
  Rename one of them, or choose a case that keeps them apart —
`.SCREAMING_SNAKE_CASE` and `.kebab-case` both keep the underscore, and
`.lowercase` and `.UPPERCASE` are the two that drop it.
```

The last clause is the part that earns its length. A reader who has just hit
this wants to know which case to switch to, and the answer is a property of the
six cases rather than of their type.

**Two refusal files rather than one** (ADR 0027) — `refusals/`'s
`json_rename_all_collides_on_an_enum.zig` and `…_on_a_union.zig`. The message
says "values" for one and "variants" for the other, and a branch with no
refusal behind it is a branch that has only been seen to pass (ADR 0033). The
framework's table goes 75 → 77 and the five tables 141 → 143.

## What was rejected

**Refusing `.lowercase` and `.UPPERCASE` outright**, on the grounds that they
are the two that drop the underscore. They are also the two anybody wanting
`notfound` from `not_found` reaches for, and it is a legitimate thing to want.
Refusing a whole case because a *pair* of names can collide under it would
refuse every type that has no such pair, which is nearly all of them.

**Checking at the point of use — in `wire`, or in `wireNames`.** `wire` sees
one name and cannot see a collision by construction. `wireNames` sees the set
and is called from three places, so the check would fire from whichever
happened to be reached first and the error would point at the API description
rather than at the type. `of(T)` is where the marker is already validated, and
it is what `checkTag` chose for the same reason.

**Warning rather than refusing.** There is nowhere to warn to at compile time
that a build does not swallow, and the failure mode is silent wire corruption.
This is the shape ADR 0081 argues about ceilings: the loud answer is the one
worth having.

## What it costs

**Allocations per request, memory per idle connection, throughput: nothing at
all.** This is comptime work in a function that already ran at comptime.

**Binary size: 0 bytes**, and the binaries are byte-identical — the check emits
no code, it only decides whether the compilation continues. Verified the way
ADR 0092 was, on `hello`, `rest`, `orders` and `forms` against a `git archive`
rebuild of `HEAD`.

**Compile time is the axis this spends, and it is the refusals that pay it.**
Two more files in `refusals/`, which never cache (ADR 0027), on a step that is
already the slow part of `zig build test`. The `O(n²)` itself is not
measurable: it runs once per marked type per compilation, against types that
have a handful of variants.

## Consequences

- A `rename_all` that would put two names on one is a compile error naming both
  and saying which cases keep them apart.
- The check is in `of(T)`, so it fires on the type rather than on the first
  request or the first API description that touches it.
- `.lowercase` and `.UPPERCASE` stay available and stay documented as the two
  that drop the underscore, which is now enforced rather than only described.
