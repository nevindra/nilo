//! A query field of a type no query value can become.

const zfast = @import("zfast");

const Search = struct { tags: []const u8 = "" };

fn list(search: zfast.Query(Search)) u32 {
    _ = search;
    return 0;
}

export fn refusal() void {
    var app: zfast.App = undefined;
    app.get("/users", list) catch {};
}
