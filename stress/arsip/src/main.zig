//! arsip — milestone 0: a dependent that builds.
//!
//! There is nothing here worth reading as an application yet. What this
//! milestone answers is narrower and is the reason the app lives out here
//! rather than in `examples/`: can somebody who has only the published package
//! — the directories listed in nilo's `.paths`, no repository around them —
//! write a `build.zig`, import a module, and get a server that answers?
//!
//! Everything after this grows on top. `MILESTONES.md` is the plan and `DX.md`
//! is what fought back.

const std = @import("std");
const nilo = @import("nilo_http");

pub const std_options = nilo.std_options;
pub const std_options_debug_io = nilo.debug_io;
pub const panic = nilo.panic;

const Health = struct {
    status: []const u8,
    milestone: u8,
};

fn health() Health {
    return .{ .status = "ok", .milestone = 0 };
}

fn echo(name: nilo.Str) nilo.Str {
    return name;
}

pub fn main() !void {
    var app = nilo.App.init(std.heap.smp_allocator);
    defer app.deinit();

    try app.use(nilo.logger.standard);

    try app.get("/health", health);
    try app.get("/echo/:name", echo);

    try app.listen(.{ .port = 8801 });
}

test "a handler is an ordinary function, callable without a server" {
    const h = health();
    try std.testing.expectEqualStrings("ok", h.status);
    try std.testing.expectEqual(@as(u8, 0), h.milestone);
}
