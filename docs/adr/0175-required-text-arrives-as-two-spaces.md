# Required text arrives as two spaces

`Str` could say how long it was and whether it equalled something. It could not
say whether there was anything in it, so every write that takes a name, a title
or a body wrote this:

```zig
if (std.mem.trim(u8, in.full_name.view(), " \t\r\n").len == 0) {
```

A caller reported it eight times in one context, with the four-character charset
written out in six of them and pulled into a `blanks` const in the other two.

## Why it is not the caller's helper

Because the copies disagree, and the disagreement is invisible. A copy that
drops `\n` accepts a comment whose entire body is a newline: the required field
then holds a string that every screen renders as empty, the database is happy,
the API description is happy, and nothing anywhere failed.

That is the shape of every mistake this repository has decided to answer with a
type rather than a convention. `len() == 0` is already here and is the wrong
check for the ordinary case — required text arrives as `"  "` far more often
than as `""`, because a person tabbed through the field or a paste brought its
newline along.

## What was added

```zig
pub fn trimmed(self: Str) []const u8   // the middle, borrowed
pub fn blank(self: Str) bool           // whether there is nothing but whitespace
```

The set is `std.ascii.whitespace` — space, tab, newline, carriage return,
vertical tab and form feed — rather than a literal written in `core/str.zig`, so
*what counts as blank* has one answer and it is not this repository's opinion.
A non-breaking space is not in it and is not treated as one: it is a character
somebody typed, and guessing otherwise would be `Str` deciding what a name may
contain.

## Where the line is

**A read of the bytes, not a validation rule.** `blank()` says what is there;
whether a blank title is a 422 stays the caller's, exactly as `len()` and
`eql()` already leave it. nilo has no validation layer and this does not start
one — the same line ADR 0026 draws for `Patch(T)`, which tells absent from null
and says nothing about whether either is allowed.

Both go through `view()`, so a `Str` read after its request has finished trips
the Debug trap here as it does everywhere else. A `blank()` that quietly
answered `true` for dead memory would be the worst possible reading of it.

## Against ADR 0018's four axes

Zero on all four. `trimmed` is `std.mem.trim` over bytes already in the arena and
allocates nothing; `blank` is its length. Neither exists on a path nilo itself
takes — they are called from handler code, once per field.

## Consequences

- One charset, in `core/`, where `nilo_sql` and a Service can reach it as
  readily as a handler can.
- The eight call sites that reported this become `if (in.full_name.blank())`.
- Nothing changes for a caller who was happy with `len()`.
