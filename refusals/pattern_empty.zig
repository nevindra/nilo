//! A route registered with no pattern at all.

const zfast = @import("zfast");

fn index() []const u8 {
    return "";
}

export fn refusal() void {
    var app: zfast.App = undefined;
    app.get("", index) catch {};
}
