//! The root of `zig build test`, and nothing else. It exists for one
//! reason: several tests deliberately drive a request into failure, and the
//! log lines they produce are correct behaviour being checked, not news.
//!
//! Left alone they go to stderr, where Zig's build runner prints
//! `failed command` beside a suite that passed — so a green run looks red.
//! Setting the log function here rather than in `zfast.zig` keeps the
//! library's own root clean: `std_options` only takes effect in the file
//! that happens to be the root, and for the library that file is the user's.

const std = @import("std");

pub const std_options: std.Options = .{ .logFn = swallow };

fn swallow(
    comptime _: std.log.Level,
    comptime _: @EnumLiteral(),
    comptime _: []const u8,
    _: anytype,
) void {}

test {
    _ = @import("zfast.zig");
}
