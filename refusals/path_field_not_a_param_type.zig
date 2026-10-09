//! A field of a type path text cannot become.

const nilo = @import("nilo_http");

const Inner = struct { a: u32 };
const Params = struct { id: Inner };

fn member(p: nilo.Path(Params)) u32 {
    return p.value.id.a;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/members/:id", member) catch {};
}
