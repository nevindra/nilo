//! A resolver still holding an `anytype`, so nothing about it is settled —
//! not its arguments and not what it hands back.

const zfast = @import("zfast");

const Caller = struct {
    name: zfast.Str,
    pub const zfast_resolve = identify;
    fn identify(c: anytype) !Caller {
        _ = c;
        return .{ .name = .static("") };
    }
};

fn whoami(caller: Caller) zfast.Str {
    return caller.name;
}

export fn refusal() void {
    var app: zfast.App = undefined;
    app.get("/me", whoami) catch {};
}
