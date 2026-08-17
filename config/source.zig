//! Where a Config's values are read from.
//!
//! A source is anything answering `get(name: []const u8) ?[]const u8`, and
//! it is a shape checked while compiling rather than an interface with a
//! function table. Four are supplied, and `Layered` puts them in an order.
//!
//! **None of them opens a file, and that is the decision** (ADR 0064).
//! `Dotenv` reads text somebody else read; `Fixed` takes pairs somebody else
//! parsed. What this module refuses is the filesystem, not a format — which
//! is why reading TOML is a dependency the program chooses rather than one
//! this module makes every importer carry.
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

/// Several sources in the order they win.
///
/// ```zig
/// const read = config.from(Settings, config.layered(.{
///     config.Env{ .environ = init.minimal.environ },  // wins
///     config.Dotenv{ .text = text },                  // falls back to
/// }));
/// ```
///
/// **The first layer that has the name answers**, which is `Fixed`'s
/// sentence about pairs raised one level: the order is the rule, so there is
/// nothing else to learn and nowhere to write a precedence down. A `.env`
/// under the real environment is the arrangement this exists for — the file
/// is what a machine has when nobody set anything, and a set variable is
/// somebody saying otherwise.
///
/// Nothing is allocated and nothing is merged: the tuple is held by value
/// and `inline for` unrolls it, so a two-layer lookup that misses the first
/// layer is the second layer's `get` and one comparison.
pub fn Layered(comptime Sources: type) type {
    checkLayers(Sources);

    return struct {
        sources: Sources,

        pub fn get(self: @This(), name: []const u8) ?[]const u8 {
            inline for (self.sources) |source| {
                if (source.get(name)) |value| return value;
            }
            return null;
        }
    };
}

/// Put sources in an order. See `Layered`.
///
/// The check is in `Layered` rather than here for the reason `Read` gives:
/// a return type is analysed before the body that would have checked it, so
/// a mistake in the tuple has to be refused by the type or it is refused
/// from inside the `inline for` instead.
pub fn layered(sources: anytype) Layered(@TypeOf(sources)) {
    return .{ .sources = sources };
}

const advice = "\n  A source answers `get(name: []const u8) ?[]const u8` — `config.Env`," ++
    " `config.Map`, `config.Dotenv`, or a `config.Fixed` of your own.";

/// Whether a type can be asked for a value at all.
///
/// A pointer to a source is a source, so a caller holding one does not have
/// to dereference it at the call.
pub fn isSource(comptime S: type) bool {
    const Holder = comptime switch (@typeInfo(S)) {
        .pointer => |p| if (p.size == .one) p.child else S,
        else => S,
    };

    return comptime switch (@typeInfo(Holder)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(Holder, "get"),
        else => false,
    };
}

/// Refuse anything that is not a source, in nilo's own words.
pub fn check(comptime S: type) void {
    comptime {
        const Holder = switch (@typeInfo(S)) {
            .pointer => |p| if (p.size == .one) p.child else S,
            else => S,
        };

        switch (@typeInfo(Holder)) {
            .@"struct", .@"union", .@"enum", .@"opaque" => {},
            else => @compileError("nilo: a Config is read from a source, and " ++
                @typeName(S) ++ " cannot be one." ++ advice),
        }

        if (!@hasDecl(Holder, "get")) @compileError(
            "nilo: a Config is read from a source and " ++ @typeName(S) ++ " is not one." ++ advice,
        );
    }
}

/// Refuse a layering that could never be read, while compiling.
///
/// Three ways to get it wrong and a sentence for each: the tuple that was
/// forgotten, the tuple that is empty, and the layer that is not a source.
/// Without these the failure comes out of the `inline for`, which is a
/// message about a struct field rather than about the call that was written.
fn checkLayers(comptime Sources: type) void {
    comptime {
        const info = @typeInfo(Sources);
        const is_tuple = info == .@"struct" and info.@"struct".is_tuple;
        if (!is_tuple) @compileError(
            "nilo: a layered source takes a tuple of sources, and " ++
                @typeName(Sources) ++ " is not one.\n" ++
                "  Write `config.layered(.{ first, second })` — braces and all," ++
                " in the order they win.",
        );

        const layers = info.@"struct".fields;
        if (layers.len == 0) @compileError(
            "nilo: a layered source with no layers would read nothing.",
        );

        for (layers, 0..) |layer, i| {
            if (!isSource(layer.type)) @compileError(
                "nilo: layer " ++ std.fmt.comptimePrint("{d}", .{i + 1}) ++
                    " of a layered source is " ++ @typeName(layer.type) ++
                    ", and that cannot be a source." ++ advice,
            );
        }
    }
}

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

test "the first layer that has the name answers" {
    const source = layered(.{
        Fixed{ .pairs = &.{.{ "PORT", "9000" }} },
        Fixed{ .pairs = &.{ .{ "PORT", "8080" }, .{ "DATABASE_URL", "postgres://" } } },
    });

    // The first layer wins where it has an answer...
    try testing.expectEqualStrings("9000", source.get("PORT").?);
    // ...and is skipped where it has none.
    try testing.expectEqualStrings("postgres://", source.get("DATABASE_URL").?);
    try testing.expectEqual(@as(?[]const u8, null), source.get("NOPE"));
}

test "a layer answering the empty string has answered" {
    // `PORT=` in the first layer is somebody setting it to nothing, not
    // somebody leaving it out. The layer below is not reached.
    const source = layered(.{
        Fixed{ .pairs = &.{.{ "PORT", "" }} },
        Fixed{ .pairs = &.{.{ "PORT", "8080" }} },
    });
    try testing.expectEqualStrings("", source.get("PORT").?);
}

test "one layer is a layering" {
    const source = layered(.{Fixed{ .pairs = &.{.{ "PORT", "9000" }} }});
    try testing.expectEqualStrings("9000", source.get("PORT").?);
}

test "layers can be of different kinds" {
    const source = layered(.{
        Fixed{ .pairs = &.{.{ "PORT", "9000" }} },
        @import("dotenv.zig").Dotenv{ .text = "PORT=8080\nDATABASE_URL=postgres://\n" },
    });
    try testing.expectEqualStrings("9000", source.get("PORT").?);
    try testing.expectEqualStrings("postgres://", source.get("DATABASE_URL").?);
}

test "a pointer to a source is a source" {
    const held = Fixed{ .pairs = &.{.{ "PORT", "9000" }} };
    try testing.expect(isSource(*const Fixed));
    const source = layered(.{&held});
    try testing.expectEqualStrings("9000", source.get("PORT").?);
}

test "what is not a source is not one" {
    try testing.expect(!isSource(u32));
    try testing.expect(!isSource(comptime_int));
    // A struct with no `get` is the near miss worth checking.
    try testing.expect(!isSource(struct { pairs: []const u8 }));
}
