//! A resolver that hands back something other than the type it belongs to —
//! usually a copy-and-paste from the resolver next to it.

const nilo = @import("nilo_http");

const Caller = struct {
    name: nilo.Str,
    pub const nilo_resolve = identify;
    fn identify(c: *nilo.Ctx) !nilo.Str {
        return c.header("authorization") orelse .static("");
    }
};

fn whoami(caller: Caller) nilo.Str {
    return caller.name;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/me", whoami) catch {};
}
