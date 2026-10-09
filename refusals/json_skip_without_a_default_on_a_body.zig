//! A skipped field read from a body. `.skip` keeps a field out of the wire in
//! both directions, so a reader never fills it, and a field with no default
//! and no `?` has nothing to hold instead (ADR 148).

const nilo = @import("nilo_http");

const Account = struct {
    pub const nilo_json = .{ .skip = &.{"password_hash"} };

    name: []const u8,
    password_hash: []const u8,
};

fn signUp(incoming: Account) u32 {
    _ = incoming;
    return 0;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.post("/accounts", signUp) catch {};
}
