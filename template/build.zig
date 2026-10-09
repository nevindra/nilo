const std = @import("std");
const nilo = @import("nilo");

pub fn build(b: *std.Build) void {
    _ = nilo.app(b, .{ .name = "hello", .root = b.path("src/main.zig") });
}
