//! A handler asking for the Idempotency-Key twice
//! ([ADR 0193](../docs/adr/0193-a-request-answered-once-is-answered-the-same-way-again.md)).

const nilo = @import("nilo_http");

const Replays = struct {
    pub const Held = [512]u8;
    pub const max_bytes: usize = 512;
    pub fn getInto(_: *Replays, _: []const u8, _: []u8) ?[]const u8 {
        unreachable;
    }
    pub fn putIfAbsent(_: *Replays, _: []const u8, _: []const u8) error{TooLarge}!bool {
        unreachable;
    }
    pub fn put(_: *Replays, _: []const u8, _: []const u8) error{TooLarge}!void {
        unreachable;
    }
    pub fn del(_: *Replays, _: []const u8) bool {
        unreachable;
    }
};

fn place(a: nilo.Idempotent(Replays, .{}), b: nilo.Idempotent(Replays, .{})) u32 {
    return @intCast(a.key.len() + b.key.len());
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.post("/orders", place) catch {};
}
