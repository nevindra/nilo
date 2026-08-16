//! A resolver asking for a path param. It belongs to the request rather
//! than to a route, so there is no `:id` to hand it.

const nilo = @import("nilo_http");

const Caller = struct {
    name: nilo.Str,
    pub const nilo_resolve = identify;
    fn identify(id: u32) !Caller {
        _ = id;
        return .{ .name = .static("") };
    }
};

fn whoami(id: u32, caller: Caller) nilo.Str {
    _ = id;
    return caller.name;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/users/:id/me", whoami) catch {};
}
