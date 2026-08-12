//! Two resolved values, each worked out from the other. Left alone this is
//! a compiler that expands for ever rather than a message.

const zfast = @import("zfast");

const Caller = struct {
    name: zfast.Str,
    pub const zfast_resolve = fromTenant;
    fn fromTenant(tenant: Tenant) !Caller {
        return .{ .name = tenant.name };
    }
};

const Tenant = struct {
    name: zfast.Str,
    pub const zfast_resolve = fromCaller;
    fn fromCaller(caller: Caller) !Tenant {
        return .{ .name = caller.name };
    }
};

fn whoami(caller: Caller) zfast.Str {
    return caller.name;
}

export fn refusal() void {
    var app: zfast.App = undefined;
    app.get("/me", whoami) catch {};
}
