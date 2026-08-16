//! A resolver still holding an `anytype`, so nothing about it is settled —
//! not its arguments and not what it hands back.

const nilo = @import("nilo_http");

const Caller = struct {
    name: nilo.Str,
    pub const nilo_resolve = identify;
    fn identify(c: anytype) !Caller {
        _ = c;
        return .{ .name = .static("") };
    }
};

fn whoami(caller: Caller) nilo.Str {
    return caller.name;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/me", whoami) catch {};
}
