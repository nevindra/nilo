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
//! `stderr` there is the one piece of shorthand in this comment, because
//! getting a `*std.Io.Writer` for it is Zig's question rather than this
//! module's: `std.Io.File.stderr().writer(init.io, &buf)`, and `.interface`
//! is the writer. The `io` comes from `main`'s own argument, which is also
//! what opens a `.env` — `docs/guide/config.md` writes the whole `main` out,
//! and that page's version is compiled by `zig build snippets` (ADR 0083).
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
//! **What it will not do is open a file** (ADR 0064). No path is passed to
//! anything here and `std.fs` is not imported, which is what keeps the
//! module allocation-free and runnable under a plain `zig test`. A `.env` is
//! read as *text somebody else read*, and TOML or YAML arrive as pairs
//! through `Fixed` — so a parser is a dependency the program chooses rather
//! than one every importer carries. What this module owns is the half no
//! parser does: a struct of your own, filled or refused, with **every** bad
//! setting named at once rather than the first.
//!
//! ```zig
//! 3 settings could not be read from the environment:
//!   PORT has to be a whole number, not "soon"
//!   DATABASE_URL is not set
//!   LOG_LEVEL has to be one of debug, info, warn, not "verbose"
//! ```
//!
//! **A `.env` is a source, and sources go in an order.** The first layer
//! that has the name answers, so a variable somebody actually set beats the
//! file without anything having to know it did:
//!
//! ```zig
//! const text = std.fs.cwd().readFileAlloc(arena, ".env", 64 * 1024) catch "";
//! const file = config.Dotenv{ .text = text };
//!
//! const read = config.from(Settings, config.layered(.{
//!     config.Env{ .environ = init.minimal.environ },
//!     file,
//! }));
//!
//! try file.report(stderr);   // writes nothing when the file is clean
//! ```

const std = @import("std");
const dotenv_mod = @import("dotenv.zig");
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
/// A `.env`'s text, read as a source. The file is the caller's to open
/// (ADR 0064).
pub const Dotenv = dotenv_mod.Dotenv;
/// One line of a `.env` that meant to be a setting and is not.
pub const BadLine = dotenv_mod.BadLine;
/// Why one line of a `.env` is not a setting.
pub const Wrong = dotenv_mod.Wrong;

/// Several sources in the order they win — the first that has the name
/// answers. See `Layered`.
pub const layered = source_mod.layered;
/// The type `layered` returns, for a program that wants to name it.
pub const Layered = source_mod.Layered;

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

test "a Config is read from a .env" {
    const r = from(Settings, Dotenv{ .text =
    \\# what this thing serves on
    \\PORT=9000
    \\DATABASE_URL="postgres://localhost/app"
    \\LOG_LEVEL=warn
    \\
    });

    const settings = r.value().?;
    try testing.expectEqual(@as(u16, 9000), settings.port);
    try testing.expectEqualStrings("postgres://localhost/app", settings.database_url);
    try testing.expectEqual(.warn, settings.log_level);
}

test "a set variable beats the .env under it" {
    // The arrangement the whole feature exists for: the file is what a
    // machine has when nobody said otherwise, and the environment is
    // somebody saying otherwise.
    const r = from(Settings, layered(.{
        Fixed{ .pairs = &.{.{ "PORT", "3000" }} },
        Dotenv{ .text = "PORT=9000\nDATABASE_URL=postgres://localhost/app\n" },
    }));

    const settings = r.value().?;
    try testing.expectEqual(@as(u16, 3000), settings.port);
    // And what the environment does not set still comes from the file.
    try testing.expectEqualStrings("postgres://localhost/app", settings.database_url);
}

test "a .env that sets nothing leaves the Config on its defaults" {
    // What a missing file looks like once `readFileAlloc` has been `catch ""`d,
    // which is the shape the doc comment shows.
    const r = from(Settings, layered(.{
        Fixed{ .pairs = &.{.{ "DATABASE_URL", "postgres://" }} },
        Dotenv{ .text = "" },
    }));
    try testing.expectEqual(@as(u16, 8080), r.value().?.port);
}

test "a line that is not a setting is a mistake the .env reports, not the Config" {
    // The two reports answer different questions and neither guesses at the
    // other's: the file says line 2 is not a setting, and the Config says
    // DATABASE_URL is not set. A program prints both.
    const file = Dotenv{ .text = "PORT=9000\nDATABASE_URL postgres://localhost\n" };
    const r = from(Settings, file);

    try testing.expect(file.failed());
    try testing.expectEqual(@as(usize, 1), file.failedCount());
    try testing.expectEqual(@as(?Settings, null), r.value());
    try testing.expectEqual(@as(usize, 1), r.failedCount());

    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try file.report(&w);
    try r.report(&w);

    try testing.expectEqualStrings(
        \\1 line is not a setting:
        \\  line 2 has no `=`, so it sets nothing
        \\1 setting could not be read from the environment:
        \\  DATABASE_URL is not set
        \\
    , buf[0..w.end]);
}

test "a prefix reads a .env the same way it reads the environment" {
    const r = fromWith(Settings, .{ .prefix = "NILO_" }, Dotenv{ .text =
    \\NILO_PORT=9000
    \\NILO_DATABASE_URL=postgres://
    \\
    });
    try testing.expect(!r.failed());
    try testing.expectEqual(@as(u16, 9000), r.value().?.port);
}

test {
    _ = @import("convert.zig");
    _ = @import("dotenv.zig");
    _ = @import("read.zig");
    _ = @import("source.zig");
}
