//! `.omit_empty` leaves out a list that holds nothing. A number is never empty, and a null is `.omit_null`'s (ADR 282).

const nilo = @import("nilo_http");

const Page = struct {
    pub const nilo_json = .{ .omit_empty = &.{"count"} };

    name: []const u8,
    count: u32,
};

fn show() Page {
    return undefined;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/things", show) catch {};
}
