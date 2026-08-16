//! An empty query struct, which would read nothing.

const nilo = @import("nilo");

const Search = struct {};

fn list(search: nilo.Query(Search)) u32 {
    _ = search;
    return 0;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/users", list) catch {};
}
