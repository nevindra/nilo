//! A session with nothing in it. It would compile, seal five bytes and
//! remember nothing, which is a cookie's worth of work for no answer.

const zfast = @import("zfast");

const Empty = struct {};

fn me(s: zfast.Session(Empty)) u32 {
    _ = s;
    return 0;
}

export fn refusal() void {
    var app: zfast.App = undefined;
    app.get("/me", me) catch {};
}
