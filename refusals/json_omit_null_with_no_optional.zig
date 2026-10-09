//! `.omit_null` leaves out an optional that is null. A struct with no optional field has nothing for it to do (ADR 282).

const nilo = @import("nilo_http");

const Page = struct {
    pub const nilo_json = .{ .omit_null = true };

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
