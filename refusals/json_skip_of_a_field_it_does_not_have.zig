//! `.skip` names the struct's own fields; a name it does not have is a typo
//! that would leave the real field on the wire (ADR 148).

const nilo = @import("nilo_http");

const Account = struct {
    pub const nilo_json = .{ .skip = &.{"password_hash"} };

    name: []const u8,
    pw_hash: []const u8,
};

fn show() Account {
    return .{ .name = "Wati", .pw_hash = "x" };
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/accounts", show) catch {};
}
