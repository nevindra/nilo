# A type says its own name

An application with `src/room.zig` in it, holding an ordinary `pub const Room`,
was told by a nilo compile error that its type was `nilo.Room` — and sent
looking for a type it never imported.

That is word-for-word the failure `http/names.zig` exists to prevent, described
in its own header ("a true sentence about a source tree the reader does not
have"), running the other way round. `session`, `room`, `body`, `stream`,
`form`, `cookie` and `app` are all ordinary names for a file in an application
that uses this framework.

**nilo's own types now carry `pub const nilo_type_name`, and `names.of` reads
it.** The table of `file.Type` substrings is gone.

## The experiment that killed the obvious fix

The obvious fix is to anchor the match: require it at the start of the name, or
on a `.` boundary, rather than anywhere inside it. That was written down as the
answer for months and it does not work, and one twenty-line program says why.

`@typeName` spells a type as its path from **its own module's root**:

| where the type is declared | what `@typeName` says |
|---|---|
| nilo's `http/str.zig`, module rooted at `http/http.zig` | `str.Str` |
| an app's `src/room.zig`, module rooted at `main.zig` | `src.room.Room` |
| an app's `src/room.zig`, **module rooted at `src/main.zig`** | `room.Room` |

The third row is the layout nearly every Zig project has, and it produces a
string byte-for-byte identical to what nilo produces for its own type. No rule
over the name can tell them apart, because there is nothing there to tell apart.
Anchoring fixes the second row, which is the rarer one.

## Why a declaration rather than an identity table

The exact answer is to compare types rather than names —
`if (T == str.Str) return "nilo.Str"` — and it cannot be written here.
`names.zig` is imported by `session.zig`, `service.zig`, `resolve.zig`,
`websocket.zig`, `jsonmark.zig` and `metrics.zig`, so a table of types in
`names.zig` would import those files back and analyse them while they are
half-analysed.

Inverting it costs one line per type and removes the cycle entirely:

```zig
pub const Room = struct {
    pub const nilo_type_name = "nilo.Room";
    …
};
```

**`names.zig` now imports nothing but `std`.** That is the property worth
having: no future import can make a type unnameable here, and the file that
decides what an error message says cannot itself be caught in a cycle.

A generic computes its own from its argument, next to the markers it already
carried:

```zig
pub const nilo_query = T;
pub const nilo_type_name = "nilo.Query(" ++ naming.of(T) ++ ")";
```

## What it deletes

The table, `replaced`, and the branch quota that had to be sized from the
table's length times the name's length — a quota that had already broken three
callers that had not changed a character, when `ours` grew from 20 rows to 35
([ADR 0095](./0095-a-rule-instead-of-a-table-nobody-reads.md)). None of that
has anywhere to go now: reading a declaration costs no scanning.

It also deleted two rows that could never have matched anything, which is the
sort of thing a table hides and a declaration cannot. `scope.Scope` names a type
that **does not exist** — a Scope here is a duck-typed contract checked by
`scope.check`, not a struct — and `app.Group` names a function whose instances
are all spelled `app.GroupOf(…)`. Both sat in the table looking like coverage.

## What it gives up, and where the residue is

**A nilo type inside a reader's generic.** `main.Page(str.Str)` used to come
back as `main.Page(nilo.Str)` and now keeps `str.Str`, because the argument of
somebody else's generic is not recoverable from its name. Rewriting it would
mean going back to substring matching, which is the bug. A reader who sees
`str.Str` inside their own generic has at least been told the truth about the
half that is theirs.

**A type that cannot hold a declaration.** `Middleware` is
`*const fn (*Ctx, Next) anyerror!void`, and a function type has no declarations,
so it cannot say its name. It prints its signature, spelled with nilo's file
names in it. The suite's export walk lists it as exempt rather than silently
passing it, so it is a stated gap.

**Wrappers are taken apart instead**: `?nilo.Str`, `[]nilo.Header`,
`*const nilo.Ctx` are built from the child's name, and a wrapper around
somebody else's type is left to `@typeName` untouched — so `?u32` and
`[]const u8` are still exactly what they were.

## What it costs

Nothing at run time and nothing in the binary: `nilo_type_name` is a comptime
declaration, and a declaration nobody reads is not compiled into anything. What
it costs at compile time is less than the table did — one `@hasDecl` where there
were up to 35 substring scans of the whole name.

The check that a new export has a name is the same shape as before
([ADR 0095](./0095-a-rule-instead-of-a-table-nobody-reads.md)): `http.zig`'s
suite walks every type the module exports and refuses one that cannot name
itself. What changed is that it now asks the type rather than a table, so it
cannot be satisfied by a row that happens to match.
