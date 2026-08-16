//! A query field of a type no query value can become.

const nilo = @import("nilo");

const Search = struct { tags: []const u8 = "" };

fn list(search: nilo.Query(Search)) u32 {
    _ = search;
    return 0;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/users", list) catch {};
}
