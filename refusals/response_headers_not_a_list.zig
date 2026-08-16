//! Response headers passed as a slice. They have to be written out where
//! they are set, because a slice would not say how many there are until the
//! program runs and the response has to hold them itself (ADR 0019).

const nilo = @import("nilo");

var built: [2]nilo.Header = undefined;
var how_many: usize = 2;

fn index() nilo.Response([]const u8) {
    return .{ .value = "", .headers = .of(built[0..how_many]) };
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/", index) catch {};
}
