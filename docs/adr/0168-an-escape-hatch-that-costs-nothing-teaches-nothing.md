# An escape hatch that costs nothing teaches nothing

Every item in `docs/nilo-feedback.md` before this one arrived with an error
message copied from a build log. This one has none, and that is the whole of
what it is about. Five times, across three contexts, a port wrote the untyped
call when a typed one existed:

| what was written | what existed |
|---|---|
| `RETURNING 1` into a one-field projection | `db.exec` |
| a hand-rolled `SELECT count(*)` | `db.count` |
| `scope.str` for a constant | `Str.static` |
| "nilo has no answer for a per-request value" | `Ctx.resolve`, already public |
| a `.projection` of two columns plus `db.raw` | `db.select(events.Row, …, .{ .where = … })` |

All five compiled. All five passed their tests. All five would have shipped.
The last is the sharpest: `events.Row` was **their own**, eleven lines up in the
same import, already declaring the three fields they redeclared.

## The mechanism, which is not carelessness

`db.raw` always works. There is no failure that teaches, and it is reached for
at exactly the moment the typed surface *looks* insufficient — which is the
moment somebody is least able to judge whether it actually is.

[ADR 0155](./0155-a-row-that-owns-no-table.md) made this cheaper without
meaning to. It is right, and it means declaring a throwaway projection is now
inexpensive **and blessed by the compiler**: the port's wrong shape compiled,
had its columns checked, and was still the wrong shape.

The comparison the port drew is the useful one. They came from sqlc, whose
escape hatch *hurts* — leaving the generated layer means writing your own scan —
so you feel yourself leaving. nilo's costs about the same as staying inside.
**A better API, and a worse teacher.**

## Why there is no compile check here

The obvious one was designed and then counted against the five instances. The
rule: a `.projection` handed to `db.raw`, whose select list is bare column paths
from a single table with no join and no aggregate — `rawcheck` already reads the
select list and would only need the `FROM`.

It catches **one of the five**. `RETURNING 1` is not a bare column list;
`count(*)` is the aggregate the rule excludes; and `Str.static` and `Ctx.resolve`
are not SQL at all. **Three of the five are not in `nilo_sql`**, which is the
finding: the pattern is not about `db.raw`. It is about the whole public
surface, and it ran identically in `str`, in `Ctx` and in `db`.

Two things then decide it.

**A check that lands makes the problem look solved.** Instance six through
`db.raw` would be caught, instances seven through ten in other modules would
not, and nobody would go looking, because there is a check now. For a pattern
that cuts across every module, a narrow check is worse than none — it converts
an open question into a closed one while leaving four fifths of it open.

**And it would refuse a working statement.**
[ADR 0154](./0154-a-raw-statement-cannot-cast-what-it-did-not-write.md) binds
here: reading a table this program declares no Row for is legitimate, and that
program would be refused. The port corrected the *frequency* — somebody living
in a `.managed = false` schema tends to declare the Row anyway, two fields, for
`db.checking` alone — but frequency is not the test. "Almost always wrong" is
what they reported, honestly, and a refusal needs *always*.

## What this is instead

A named failure mode, on the record, that the next report can cite rather than
rediscover — which is what the port asked for and is the reason this is an ADR
and not a paragraph in `db.raw`'s doc comment.

**The rule it leaves behind, for both sides.** When the typed surface looks
insufficient, that impression is evidence about the *reader's search*, not about
the surface. The port's own second rule is the practical half — report the thing
nilo cannot spell **before** writing the patch for it — and this ADR is why:
after the patch exists and passes, nothing pulls anybody back.

nilo's half is that the search has to succeed from where somebody is standing.
Three of these five were already documented; two of those were documented in the
right file in the wrong place. That is
[ADR 0163](./0163-a-header-a-handler-can-be-given.md)'s neighbour problem and
`docs/history.md` carries the rule.

## What would change this

A shape that is **always** wrong rather than almost always, in a place that is
not one module's escape hatch. If one turns up, it gets a refusal and this ADR
gets superseded. Nothing here argues that a check is impossible — only that the
one available buys a fifth of the problem at the price of making the other four
fifths invisible.
