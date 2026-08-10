//! The logger middleware — one line per request, with the status and how
//! long it took.
//!
//! ```zig
//! try app.use(logger.standard);
//! try app.use(logger.with(.{ .level = .debug, .slow_micros = 50_000 }));
//! ```
//!
//! Configured at compile time, so an option nobody switched on costs
//! nothing at runtime.

const std = @import("std");
const Ctx = @import("ctx.zig").Ctx;
const mw = @import("middleware.zig");
const fail = @import("fail.zig");
const bulkhead = @import("bulkhead.zig");

pub const Options = struct {
    /// The level ordinary requests are logged at.
    level: std.log.Level = .info,
    /// Requests taking longer than this are logged at `.warn` instead, so
    /// they stand out without needing a second tool. 0 turns that off.
    slow_micros: u64 = 0,
};

/// The default: one `info` line per request.
pub const standard = with(.{});

pub fn with(comptime options: Options) mw.Middleware {
    return struct {
        fn run(c: *Ctx, next: mw.Next) anyerror!void {
            const started = bulkhead.monotonicNanos();

            // The handler's error is reported and then passed along
            // untouched — App is what turns it into a response, and a
            // logger that swallowed it would change behaviour just by
            // being installed.
            next.run(c) catch |err| {
                log(c, statusOf(err), microsSince(started), @errorName(err));
                return err;
            };

            log(c, c._status, microsSince(started), null);
        }

        fn log(c: *Ctx, status: u16, took: u64, err_name: ?[]const u8) void {
            const slow = options.slow_micros > 0 and took > options.slow_micros;
            const level: std.log.Level = if (slow) .warn else options.level;
            const method = @tagName(c.method);
            const path = c._path;

            // std.log's level is comptime, so the branch is unrolled here
            // rather than passed along as a value.
            if (err_name) |name| switch (level) {
                .err => std.log.err("{s} {s} {d} {d}µs error={s}", .{ method, path, status, took, name }),
                .warn => std.log.warn("{s} {s} {d} {d}µs error={s}", .{ method, path, status, took, name }),
                .info => std.log.info("{s} {s} {d} {d}µs error={s}", .{ method, path, status, took, name }),
                .debug => std.log.debug("{s} {s} {d} {d}µs error={s}", .{ method, path, status, took, name }),
            } else switch (level) {
                .err => std.log.err("{s} {s} {d} {d}µs", .{ method, path, status, took }),
                .warn => std.log.warn("{s} {s} {d} {d}µs", .{ method, path, status, took }),
                .info => std.log.info("{s} {s} {d} {d}µs", .{ method, path, status, took }),
                .debug => std.log.debug("{s} {s} {d} {d}µs", .{ method, path, status, took }),
            }
        }
    }.run;
}

/// What App is about to answer with. Asking `fail` rather than working it
/// out again keeps the logged status and the sent status from drifting
/// apart.
fn statusOf(err: anyerror) u16 {
    const failure = fail.current() orelse return fail.statusFor(err);
    return fail.resolveStatus(failure, err);
}

fn microsSince(started: u64) u64 {
    return (bulkhead.monotonicNanos() -| started) / std.time.ns_per_us;
}
