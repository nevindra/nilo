//! Two query structs, one per group of fields. The query string is one thing.

const zfast = @import("zfast");

const Paging = struct { page: u32 = 1 };
const Sorting = struct { sort: zfast.Str = .static("id") };

fn list(paging: zfast.Query(Paging), sorting: zfast.Query(Sorting)) u32 {
    _ = sorting;
    return paging.value.page;
}

export fn refusal() void {
    var app: zfast.App = undefined;
    app.get("/users", list) catch {};
}
