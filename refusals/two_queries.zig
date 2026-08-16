//! Two query structs, one per group of fields. The query string is one thing.

const nilo = @import("nilo_http");

const Paging = struct { page: u32 = 1 };
const Sorting = struct { sort: nilo.Str = .static("id") };

fn list(paging: nilo.Query(Paging), sorting: nilo.Query(Sorting)) u32 {
    _ = sorting;
    return paging.value.page;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/users", list) catch {};
}
