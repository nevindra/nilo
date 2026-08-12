//! A resolver that hands back something other than the type it belongs to —
//! usually a copy-and-paste from the resolver next to it.

const zfast = @import("zfast");

const Caller = struct {
    name: zfast.Str,
    pub const zfast_resolve = identify;
    fn identify(c: *zfast.Ctx) !zfast.Str {
        return c.header("authorization") orelse .static("");
    }
};

fn whoami(caller: Caller) zfast.Str {
    return caller.name;
}

export fn refusal() void {
    var app: zfast.App = undefined;
    app.get("/me", whoami) catch {};
}
