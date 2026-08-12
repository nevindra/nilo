//! A resolver asking for a path param. It belongs to the request rather
//! than to a route, so there is no `:id` to hand it.

const zfast = @import("zfast");

const Caller = struct {
    name: zfast.Str,
    pub const zfast_resolve = identify;
    fn identify(id: u32) !Caller {
        _ = id;
        return .{ .name = .static("") };
    }
};

fn whoami(id: u32, caller: Caller) zfast.Str {
    _ = id;
    return caller.name;
}

export fn refusal() void {
    var app: zfast.App = undefined;
    app.get("/users/:id/me", whoami) catch {};
}
