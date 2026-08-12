//! The leading slash left off, which is how the path is spelled in a
//! router that takes them without one.

const zfast = @import("zfast");

fn index() []const u8 {
    return "";
}

export fn refusal() void {
    var app: zfast.App = undefined;
    app.get("users", index) catch {};
}
