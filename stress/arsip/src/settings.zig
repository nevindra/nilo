//! The settings, read out of the environment before the socket opens.
//!
//! Until M2 this file held defaults in Zig. It now holds the same struct read by
//! `nilo_config`, and the difference is worth stating: **a field with no default
//! is required, and every setting that failed is named at once** rather than the
//! first one stopping the program (ADR 0043).
//!
//! Registered as a service and asked for as a **`*const Settings`**, which is a
//! different type from `*Settings` and is looked up as such — a read-only
//! service saying so in the only place that cannot drift, the signature.
//!
//! `[]const u8` rather than `Str`, and that is not a slip: a bottom-layer module
//! that named `nilo_core` would give up running under a plain `zig test`, which
//! is the entry condition for its layer (ADR 0042, ADR 0043). The text these
//! fields point at is the environment block, so it outlives everything.

const std = @import("std");
const config = @import("nilo_config");

pub const Settings = struct {
    /// `ARSIP_PORT`, and so on for every field below.
    port: u16 = 8801,

    /// Exactly 32 bytes once base64 is undone. No default, because a default
    /// session key is a key everybody who has read this repository already has
    /// (guide/sessions.md).
    session_secret: []const u8,

    /// How big an attachment may be. Under `listen()`'s `max_body`, because a
    /// form is read whole into the request arena before a handler sees it.
    attachment_bytes: usize = 512 * 1024,

    /// How much a bulk import may send. Far over `max_body`, and legitimately
    /// so: the import reads its body in pieces and holds one line at a time.
    import_bytes: usize = 32 * 1024 * 1024,

    /// How much work the reindex pretends to be, in thousands of spins. High
    /// enough that a handler which forgets `nilo.blocking` trips the watchdog,
    /// whose default is a quarter of a second.
    reindex_rounds: u32 = 800_000,

    /// Whether the archive answers to anybody at all before there is an
    /// account. Off in production; on for a first run, so `zig build run` works
    /// with nothing set up.
    open_signup: bool = true,

    log_level: enum { debug, info, warn } = .info,
};

/// `ARSIP_` on the front of every name, so the archive's settings cannot be
/// confused with somebody else's `PORT`.
pub const prefix = "ARSIP_";

/// A `.env` is text somebody else read (ADR 0064) — the module opens no file, so
/// this does, and hands over the bytes. They have to outlive the Settings,
/// because a `[]const u8` field points into them.
pub const Sources = struct {
    env: config.Env,
    file: config.Dotenv,

    pub fn read(self: Sources) config.Read(Settings) {
        return config.fromWith(Settings, .{ .prefix = prefix }, config.layered(.{
            self.env, // a variable that is set wins
            self.file, // the file is the floor
        }));
    }
};

test "every missing setting is named at once, not just the first" {
    const read = config.fromWith(Settings, .{ .prefix = prefix }, config.Fixed{ .pairs = &.{
        .{ "ARSIP_PORT", "not-a-port" },
        .{ "ARSIP_LOG_LEVEL", "shouty" },
    } });

    try std.testing.expect(read.failed());
    // The port did not convert, the log level is not a choice, and the secret
    // was never set. Three, in one answer.
    try std.testing.expectEqual(@as(usize, 3), read.failedCount());
    try std.testing.expectEqual(@as(?Settings, null), read.value());
    try std.testing.expectEqualStrings("ARSIP_PORT", read.nameOf("port"));
}

test "a setting that is present and fits comes back as an ordinary struct" {
    const read = config.fromWith(Settings, .{ .prefix = prefix }, config.Fixed{ .pairs = &.{
        .{ "ARSIP_SESSION_SECRET", "0123456789abcdef0123456789abcdef" },
        .{ "ARSIP_PORT", "9000" },
        .{ "ARSIP_OPEN_SIGNUP", "false" },
    } });

    const settings = read.value() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u16, 9000), settings.port);
    try std.testing.expect(!settings.open_signup);
    // Untouched fields are their defaults, which is what "not set" means.
    try std.testing.expectEqual(@as(usize, 512 * 1024), settings.attachment_bytes);
}
