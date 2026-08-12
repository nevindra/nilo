//! `Query` given the type of a single param rather than a struct of them.

const zfast = @import("zfast");

fn list(page: zfast.Query(u32)) u32 {
    return page.value;
}

export fn refusal() void {
    var app: zfast.App = undefined;
    app.get("/users", list) catch {};
}
