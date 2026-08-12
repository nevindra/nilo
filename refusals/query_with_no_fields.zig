//! An empty query struct, which would read nothing.

const zfast = @import("zfast");

const Search = struct {};

fn list(search: zfast.Query(Search)) u32 {
    _ = search;
    return 0;
}

export fn refusal() void {
    var app: zfast.App = undefined;
    app.get("/users", list) catch {};
}
