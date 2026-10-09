//! A struct that leaves a field out, holding a shape nilo's own writer does not cover (an array of bytes, which `std.json` writes as a string). `std.json` does not read `nilo_json`, so the null would go out while the API description promised its absence (ADR 282).

const nilo = @import("nilo_http");

const Contact = struct {
    pub const nilo_json = .{ .omit_null = true };

    name: []const u8,
    nickname: ?[]const u8,
    avatar_hash: [16]u8,
};

fn show() Contact {
    return undefined;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/things", show) catch {};
}
