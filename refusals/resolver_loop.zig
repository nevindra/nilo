//! Two resolved values, each worked out from the other. Left alone this is
//! a compiler that expands for ever rather than a message.

const nilo = @import("nilo");

const Caller = struct {
    name: nilo.Str,
    pub const nilo_resolve = fromTenant;
    fn fromTenant(tenant: Tenant) !Caller {
        return .{ .name = tenant.name };
    }
};

const Tenant = struct {
    name: nilo.Str,
    pub const nilo_resolve = fromCaller;
    fn fromCaller(caller: Caller) !Tenant {
        return .{ .name = caller.name };
    }
};

fn whoami(caller: Caller) nilo.Str {
    return caller.name;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/me", whoami) catch {};
}
