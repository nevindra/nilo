//! More headers written into a Response than it carries. The rest go on
//! with `c.setHeader`, which has no limit.

const zfast = @import("zfast");

fn index() zfast.Response([]const u8) {
    return .{
        .value = "",
        .headers = .of(&.{
            .{ .name = "a", .value = "1" },
            .{ .name = "b", .value = "1" },
            .{ .name = "c", .value = "1" },
            .{ .name = "d", .value = "1" },
            .{ .name = "e", .value = "1" },
            .{ .name = "f", .value = "1" },
            .{ .name = "g", .value = "1" },
            .{ .name = "h", .value = "1" },
            .{ .name = "i", .value = "1" },
        }),
    };
}

export fn refusal() void {
    var app: zfast.App = undefined;
    app.get("/", index) catch {};
}
