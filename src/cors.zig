//! The CORS middleware.
//!
//! ```zig
//! try app.use(cors.permissive);                       // fine for a public API
//! try app.use(cors.with(.{
//!     .origin = "https://example.com",
//!     .credentials = true,
//! }));
//! ```
//!
//! Configured at compile time, so the header strings are all constants and
//! nothing is formatted per request.
//!
//! Headers go out through `c.setHeader` before the handler runs, because a
//! response is flushed the moment it is sent and there is nothing left to
//! add afterwards (ADR 0009).

const std = @import("std");
const Ctx = @import("ctx.zig").Ctx;
const mw = @import("middleware.zig");

pub const Options = struct {
    /// The value for `Access-Control-Allow-Origin`. `"*"` allows anyone.
    origin: []const u8 = "*",
    methods: []const u8 = "GET, POST, PUT, PATCH, DELETE, OPTIONS",
    headers: []const u8 = "Content-Type, Authorization",
    /// Sent as `Access-Control-Expose-Headers` when not empty.
    expose: []const u8 = "",
    /// Sends `Access-Control-Allow-Credentials: true`.
    credentials: bool = false,
    /// `Access-Control-Max-Age` in seconds. 0 leaves it off.
    max_age: u32 = 0,
};

/// Allow any origin, no credentials. Reasonable for a public API.
pub const permissive = with(.{});

pub fn with(comptime options: Options) mw.Middleware {
    // `*` and credentials together is rejected by every browser, and the
    // failure shows up as a CORS error with no mention of the real cause.
    // Better to stop it here than let someone debug it at runtime.
    if (comptime options.credentials and std.mem.eql(u8, options.origin, "*")) @compileError(
        "zfast: cors credentials cannot be combined with origin \"*\" — browsers reject it.\n" ++
            "  Name the origin explicitly, e.g. .origin = \"https://example.com\".",
    );

    const max_age_text = comptime if (options.max_age > 0)
        std.fmt.comptimePrint("{d}", .{options.max_age})
    else
        "";

    return struct {
        fn run(c: *Ctx, next: mw.Next) anyerror!void {
            try c.setHeader("Access-Control-Allow-Origin", options.origin);

            // A response that varies by origin must say so, or a shared
            // cache will hand one origin's response to another.
            if (comptime !std.mem.eql(u8, options.origin, "*")) {
                try c.setHeader("Vary", "Origin");
            }
            if (comptime options.credentials) {
                try c.setHeader("Access-Control-Allow-Credentials", "true");
            }
            if (comptime options.expose.len > 0) {
                try c.setHeader("Access-Control-Expose-Headers", options.expose);
            }

            // A preflight is answered here and never reaches the handler —
            // there is no route for it to reach.
            if (c.method == .OPTIONS and c.header("Access-Control-Request-Method") != null) {
                try c.setHeader("Access-Control-Allow-Methods", options.methods);
                try c.setHeader("Access-Control-Allow-Headers", options.headers);
                if (comptime options.max_age > 0) {
                    try c.setHeader("Access-Control-Max-Age", max_age_text);
                }
                return c.send(204, "text/plain", "");
            }

            return next.run(c);
        }
    }.run;
}
