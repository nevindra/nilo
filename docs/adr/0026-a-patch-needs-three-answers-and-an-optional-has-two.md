# A PATCH needs three answers and an optional has two

The obvious way to write a PATCH body is the way everybody writes it:

```zig
const PatchTodo = struct {
    title: ?Str = null,
    due: ?Str = null,
};
```

and it cannot do the job. These two requests arrive identical:

```
PATCH /todos/3   {}                 → title is null, due is null
PATCH /todos/3   {"due": null}      → title is null, due is null
```

The first means *leave the due date alone*. The second means *empty the due date out*. A PATCH has three things a field can be — not mentioned, mentioned as null, mentioned with a value — and `?T` has two, so one of the three has to be given up. In practice what gets given up is "clear this field", and the API grows a `POST /todos/3/clear-due` to make up for it.

## `Patch(T)`

```zig
const PatchTodo = struct {
    title: Patch(Str) = .absent,
    due: Patch(Str) = .absent,
};

switch (incoming.due) {
    .absent => {},                       // not mentioned: leave it
    .cleared => todo.due = null,         // sent as null: empty it
    .value => |v| todo.due = try v.keep(gpa),
}
```

A three-armed tagged union with a `jsonParse` of its own. The parser is where the three states come from and it is not clever: `std.json` leaves an absent field at its default, which is why the default is `.absent` and why writing it is not optional; a `null` token is `.cleared`; anything else parses as `T`.

`.cleared` rather than `.null` is a deliberate choice of word. `null` describes what was on the wire; `cleared` describes what the client asked for, and the handler is deciding what to do about the ask. It also avoids `@"null"`, which is what the keyword would have cost.

For the fields where "leave it" and "clear it" really are the same thing, `orNull()` collapses the two and the three-way switch is not forced on anybody.

## What was considered and refused

- **A second struct of `has_x: bool` flags.** Works, and is what people do by hand. Refused for the reason [ADR 0012](./0012-the-query-string-is-a-struct-of-your-own.md) refuses a params map: two things that have to be kept in step, where one type could carry both.
- **Reading the raw body a second time to see which keys were present.** No new type, and a parse per PATCH plus a name lookup per field, on the request path. The wrong side of [ADR 0018](./0018-the-trade-budget-has-three-axes.md), and it puts the answer in a lookup rather than in the type.
- **`??T`.** It does express three states, and nobody can read it. This is the kind of cleverness that costs a paragraph of documentation per use.

## What it touches

Being a union rather than an optional means the parts of zfast that walk a type had to learn about it, and in each case the general fix was the better one:

- **The staleness trap.** `str.stamp` skipped unions entirely, so a `Str` inside a `Patch` would have had no lifetime marker on it. It now walks the active arm of any tagged union, which is right for a user's own union too.
- **The message that says what is wrong.** `"due" has to be text or null` — the third state is not a value, so it is not something to describe here.
- **The API description.** On the wire a `Patch(T)` is the value or null. The third state is "the field was not there", which JSON Schema says with `required`, and the `= .absent` default already takes care of that.
- **The response writer.** A union is not a shape `json.zig`'s generated writer covers, so a type carrying one falls back to `std.json` — which is the existing rule working, not an exception to it.

## Consequences

- New in the vocabulary and in `zfast.zig`. Nothing else changed shape, and nobody has to use it: `?T` in a body still means exactly what it meant.
- Writing `Patch(T)` as a handler argument is a compile error that says it belongs in a body struct and shows the two lines that put it there.
- A `Patch(T)` in a *response* goes out as its value, or as null for both of the empty cases. That is the honest limit of the type in that direction — JSON has no way to leave a field out of a value that has it — and it is why this is documented as a type for reading a PATCH body rather than for describing a resource.
