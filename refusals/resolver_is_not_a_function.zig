//! The marker set to a value instead of the function that works the value
//! out from a request.

const zfast = @import("zfast");

const Caller = struct {
    name: zfast.Str,
    pub const zfast_resolve = 42;
};

fn whoami(caller: Caller) zfast.Str {
    return caller.name;
}

export fn refusal() void {
    var app: zfast.App = undefined;
    app.get("/me", whoami) catch {};
}
