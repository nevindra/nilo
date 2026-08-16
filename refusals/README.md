# refusals

Programs written wrong on purpose. Each one has to fail to compile with a
message that nilo wrote, and `zig build test` checks that it does
([ADR 0027](../docs/adr/0027-the-rule-about-error-messages-is-held-by-a-build-step.md)).

Nothing here is ever run, and nothing here compiles.

## Adding one

Say a new comptime check is added. It needs two things.

**A file**, named after the mistake rather than the check, with a comment
saying what the person was trying to do:

```zig
//! A service asked for by value. `Store` is a service — it is meant to be
//! `*Store` — and by value it is a struct, so nilo reads it as a second
//! request body.

const nilo = @import("nilo");

const Store = struct { rows: u32 };
const NewOrder = struct { sku: nilo.Str };

fn placeOrder(store: Store, incoming: NewOrder) u32 {
    _ = incoming;
    return store.rows;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.post("/orders", placeOrder) catch {};
}
```

`export` is what gets the function analysed without a `main`, and
`var app: nilo.App = undefined` is fine because none of this runs — the
compiler stops at the route registration.

**A row in `build.zig`**, holding the first line of the message:

```zig
.{
    .name = "two_bodies",
    .says = "the handler for route \"/orders\" takes two structs by value — …",
},
```

Leave the `nilo: ` off. The build step puts it there, which is how a message
that does not start with it becomes impossible to write down as passing.

To find out what to put in `.says`, guess, run `zig build refusals`, and read
the failure — it prints what was expected beside what actually came out.

## When one of these fails

Two ways it happens, and they mean opposite things.

**"should contain / but not found", with text underneath.** A message changed.
Compare the two and decide which is better; if the new one is, paste it into
the table.

**"should contain / but not found", with nothing underneath.** The program
compiled. A check stopped firing, and the mistake in that file now ships.
