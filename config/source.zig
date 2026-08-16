//! Where a Config's values are read from.
//!
//! A source is anything answering `get(name: []const u8) ?[]const u8`, and
//! it is a shape checked while compiling rather than an interface with a
//! function table. Three are supplied. **A file format is not among them,
//! and that is a decision** (ADR 0043): `Fixed` is the seam a program hands
//! its own parsed values through, so reading TOML is a dependency the
//! program chooses rather than one this module makes it carry.
//!
//! ```zig
//! // std.zon.parse, sam701/zig-toml, a file you read yourself — whatever
//! // produced these pairs, this module never had to know.
//! const read = config.from(Settings, config.Fixed{ .pairs = &.{
//!     .{ "PORT", "9000" },
//!     .{ "DATABASE_URL", url },
//! } });
//! ```

const std = @import("std");
const builtin = @import("builtin");

/// The process environment, read where it lies.
///
/// `getPosix` hands back a slice of the block the operating system gave the
/// process, so nothing is copied and nothing is allocated — which is what
/// lets a Config of `[]const u8` fields be held for the life of the program
/// without a keep.
pub const Env = struct {
    environ: std.process.Environ,

    pub fn get(self: Env, name: []const u8) ?[]const u8 {
        if (builtin.os.tag == .windows) @compileError(
            "nilo: `config.Env` reads the environment block in place, and Windows moves it.\n" ++
                "  Use `config.Map` with the `environ_map` that `std.process.Init` hands to main.",
        );
        const value = self.environ.getPosix(name) orelse return null;
        return value;
    }
};

/// The environment as a map — the portable half, and what a program on
/// Windows reads from.
///
/// `std.process.Init` hands one to `main` already built, so taking it costs
/// the program nothing it was not already paying.
pub const Map = struct {
    map: *const std.process.Environ.Map,

    pub fn get(self: Map, name: []const u8) ?[]const u8 {
        return self.map.get(name);
    }
};

/// A source of pairs written out where they are used: what the tests read
/// from, and what a program hands over once it has parsed a file of its own.
///
/// A linear scan, because a Config has a dozen settings and is read once
/// before the socket opens. A hash map here would be machinery bought with
/// an allocation, to save a comparison that happens ten times in the life of
/// the process.
pub const Fixed = struct {
    pub const Pair = struct { []const u8, []const u8 };

    pairs: []const Pair,

    /// The first pair with this name wins, so a caller can put its overrides
    /// in front of its defaults and let the order say which is which.
    pub fn get(self: Fixed, name: []const u8) ?[]const u8 {
        for (self.pairs) |pair| {
            if (std.mem.eql(u8, pair[0], name)) return pair[1];
        }
        return null;
    }
};

const testing = std.testing;

test "a fixed source answers what it was given" {
    const source = Fixed{ .pairs = &.{
        .{ "PORT", "9000" },
        .{ "DATABASE_URL", "postgres://" },
    } };

    try testing.expectEqualStrings("9000", source.get("PORT").?);
    try testing.expectEqualStrings("postgres://", source.get("DATABASE_URL").?);
    try testing.expectEqual(@as(?[]const u8, null), source.get("NOPE"));
}

test "a fixed source is empty when it has no pairs" {
    const source = Fixed{ .pairs = &.{} };
    try testing.expectEqual(@as(?[]const u8, null), source.get("PORT"));
}

test "the first pair with a name wins" {
    const source = Fixed{ .pairs = &.{
        .{ "PORT", "9000" },
        .{ "PORT", "8080" },
    } };
    try testing.expectEqualStrings("9000", source.get("PORT").?);
}

test "a name is matched whole, not by prefix" {
    const source = Fixed{ .pairs = &.{.{ "PORT", "9000" }} };
    try testing.expectEqual(@as(?[]const u8, null), source.get("PORT_RANGE"));
    try testing.expectEqual(@as(?[]const u8, null), source.get("POR"));
}

test "a value set to the empty string is set" {
    const source = Fixed{ .pairs = &.{.{ "PORT", "" }} };
    try testing.expectEqualStrings("", source.get("PORT").?);
}

test "a map source answers out of the environment map" {
    var map: std.process.Environ.Map = .init(testing.allocator);
    defer map.deinit();
    try map.put("PORT", "9000");

    const source = Map{ .map = &map };
    try testing.expectEqualStrings("9000", source.get("PORT").?);
    try testing.expectEqual(@as(?[]const u8, null), source.get("DATABASE_URL"));
}
