//! `.omit_empty` names the struct's own fields; a name it does not have is a typo that would leave the real list on the wire (ADR 282).

const nilo = @import("nilo_http");

const Page = struct {
    pub const nilo_json = .{ .omit_empty = &.{"root_attributes"} };

    name: []const u8,
    roots: []const u32,
};

fn show() Page {
    return undefined;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/things", show) catch {};
}
