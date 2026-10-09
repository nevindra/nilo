//! A form field that is a list of optionals. An absent value in a list is
//! simply not in it, so the element says what each value is and `?` has
//! nothing to add (ADR 132).

const nilo = @import("nilo_http");

const Tags = struct { tags: []const ?nilo.Str = &.{} };

fn tag(incoming: nilo.Form(Tags)) u32 {
    _ = incoming;
    return 0;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.post("/tags", tag) catch {};
}
