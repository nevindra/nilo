//! A list with a length in a query string, which carries no count a client
//! is told of ([ADR 266](../docs/adr/266-a-list-with-a-length-is-a-type.md)).

const nilo = @import("nilo_http");

const Search = struct { tags: nilo.Many(u32, .{ .max = 3 }) };

fn list(search: nilo.Query(Search)) u32 {
    _ = search;
    return 0;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/users", list) catch {};
}
