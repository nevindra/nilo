//! A renamed struct holding a shape nilo's own writer does not cover. `covers`
//! errs narrow on purpose, so one field it does not recognise — here an array of
//! bytes, which `std.json` writes as a string and `json.zig` deliberately leaves
//! to it — sends the whole value to `std.json`.
//!
//! `std.json` does not read `nilo_json`, so the keys would go out spelled the
//! way they are written while the API description promised the renamed ones.
//! Nothing would fail (ADR 0181).

const nilo = @import("nilo_http");

const Contact = struct {
    pub const nilo_json = .{ .rename_all = .camelCase };

    full_name: []const u8,
    // Not covered: an array of bytes is a *string* to `std.json`, and nilo's
    // writer leaves that rule to it rather than reproducing it.
    avatar_hash: [16]u8,
};

fn show() Contact {
    return .{ .full_name = "Wati", .avatar_hash = undefined };
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/contacts", show) catch {};
}
