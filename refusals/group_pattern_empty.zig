//! An empty pattern inside a group, meaning to register the group itself.

const zfast = @import("zfast");

fn index() []const u8 {
    return "";
}

export fn refusal() void {
    var app: zfast.App = undefined;
    const api = app.group("/api");
    api.get("", index) catch {};
}
