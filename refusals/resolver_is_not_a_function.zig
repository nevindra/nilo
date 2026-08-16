//! The marker set to a value instead of the function that works the value
//! out from a request.

const nilo = @import("nilo");

const Caller = struct {
    name: nilo.Str,
    pub const nilo_resolve = 42;
};

fn whoami(caller: Caller) nilo.Str {
    return caller.name;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/me", whoami) catch {};
}
