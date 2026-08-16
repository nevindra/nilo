//! nilo_config — settings out of the environment, and nothing that needs a
//! loop (ADR 0043).
//!
//! A **tool module**: one job, no event loop, and it imports nothing at all
//! — not even `nilo_core`, which is why `zig test config/config.zig` runs
//! the whole of it (ADR 0042).
//!
//! ```zig
//! const config = @import("nilo_config");
//!
//! const Settings = struct {
//!     port: u16 = 8080,
//!     database_url: []const u8,
//!     log_level: enum { debug, info, warn } = .info,
//!     workers: ?u8 = null,
//! };
//!
//! pub fn main(init: std.process.Init) !void {
//!     const read = config.fromEnv(Settings, init.minimal.environ);
//!     const settings = read.value() orelse {
//!         try read.report(stderr);
//!         std.process.exit(2);
//!     };
//!     // `settings` is an ordinary struct, and a Service like any other.
//! }
//! ```
//!
//! **A field is a setting and its name is the variable.** `database_url` is
//! read from `DATABASE_URL`; a default is what "not set" means; a `?T` is a
//! setting that may be absent. That is the same sentence
//! [ADR 0012](../docs/adr/0012-the-query-string-is-a-struct-of-your-own.md)
//! wrote about a query string, and the same one
//! [ADR 0036](../docs/adr/0036-a-binding-hands-its-failures-to-the-handler.md)
//! wrote about a binding — which is the argument for this module existing
//! at all. A person who has read a `Query(T)` has already read this.
//!
//! **What it will not do is parse a file.** No TOML, no YAML, no `.env`
//! (ADR 0043). `std.zon.parse` is in the standard library and costs a
//! project nothing; a program that wants TOML picks its own parser and
//! hands the pairs over as a `Fixed`. What this module owns is the half
//! neither of those does: a struct of your own, filled or refused, with
//! **every** bad setting named at once rather than the first.
//!
//! ```zig
//! 3 settings could not be read from the environment:
//!   PORT has to be a whole number, not "soon"
//!   DATABASE_URL is not set
//!   LOG_LEVEL has to be one of debug, info, warn, not "verbose"
//! ```

const std = @import("std");
const read_mod = @import("read.zig");
const source_mod = @import("source.zig");

/// A Config filled as far as the environment allowed, and why each field
/// that is not filled is not.
pub const Read = read_mod.Read;
/// One setting that could not be read.
pub const Failure = read_mod.Failure;
/// Why one setting could not be read — four, and it stays four.
pub const Reason = read_mod.Reason;
/// What became of one field.
pub const Outcome = read_mod.Outcome;

/// The process environment, read where it lies. Allocates nothing.
pub const Env = source_mod.Env;
/// The environment as a map — the portable half.
pub const Map = source_mod.Map;
/// Pairs written out where they are used, and the seam a program hands its
/// own parsed values through.
pub const Fixed = source_mod.Fixed;

pub const Options = struct {
    /// Put in front of every name before it is looked up: `.{ .prefix =
    /// "NILO_" }` reads `database_url` from `NILO_DATABASE_URL`.
    ///
    /// Empty by default, because a program that owns its process owns its
    /// environment, and a prefix is what you reach for when it does not —
    /// two services in one container, or a name that would collide with
    /// something the platform sets.
    prefix: []const u8 = "",
};

/// Read a Config out of the process environment.
///
/// `environ` is what `std.process.Init` hands to `main` as
/// `init.minimal.environ`. Nothing is copied: a `[]const u8` field points
/// into the block the operating system gave the process, which outlives
/// every use of it.
pub fn fromEnv(comptime T: type, environ: std.process.Environ) Read(T) {
    return from(T, Env{ .environ = environ });
}

/// Read a Config out of anything answering `get(name) ?[]const u8`.
pub fn from(comptime T: type, source: anytype) Read(T) {
    return fromWith(T, .{}, source);
}

/// The same, with a prefix in front of every name.
pub fn fromWith(comptime T: type, comptime options: Options, source: anytype) Read(T) {
    return read_mod.fill(T, options.prefix, source);
}

const testing = std.testing;

const Settings = struct {
    port: u16 = 8080,
    database_url: []const u8,
    log_level: enum { debug, info, warn } = .info,
};

test "a Config is read from any source" {
    const r = from(Settings, Fixed{ .pairs = &.{
        .{ "DATABASE_URL", "postgres://localhost/app" },
        .{ "PORT", "9000" },
    } });

    const settings = r.value().?;
    try testing.expectEqual(@as(u16, 9000), settings.port);
    try testing.expectEqualStrings("postgres://localhost/app", settings.database_url);
    try testing.expectEqual(.info, settings.log_level);
}

test "a prefix is asked for where the Config is read, not where it is declared" {
    const r = fromWith(Settings, .{ .prefix = "NILO_" }, Fixed{ .pairs = &.{
        .{ "NILO_DATABASE_URL", "postgres://" },
        .{ "NILO_PORT", "9000" },
    } });

    try testing.expect(!r.failed());
    try testing.expectEqual(@as(u16, 9000), r.value().?.port);
    try testing.expectEqualStrings("NILO_PORT", r.nameOf("port"));
}

test "one Config type is read the same whatever the prefix was" {
    // `Read(T)` and not `Read(T, prefix)`: both of these are one type, so a
    // function taking a reading does not have to name the prefix it was
    // read with.
    const bare = from(Settings, Fixed{ .pairs = &.{.{ "DATABASE_URL", "a" }} });
    const prefixed = fromWith(Settings, .{ .prefix = "X_" }, Fixed{ .pairs = &.{
        .{ "X_DATABASE_URL", "b" },
    } });
    try testing.expectEqual(@TypeOf(bare), @TypeOf(prefixed));
    try testing.expectEqualStrings("a", bare.value().?.database_url);
    try testing.expectEqualStrings("b", prefixed.value().?.database_url);
}

test "a Config that cannot be read hands back every reason at once" {
    const r = from(Settings, Fixed{ .pairs = &.{
        .{ "PORT", "soon" },
        .{ "LOG_LEVEL", "verbose" },
    } });

    try testing.expectEqual(@as(?Settings, null), r.value());
    try testing.expectEqual(@as(usize, 3), r.failedCount());
}

test {
    _ = @import("convert.zig");
    _ = @import("read.zig");
    _ = @import("source.zig");
}
