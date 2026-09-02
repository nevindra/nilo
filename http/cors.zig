//! The CORS middleware.
//!
//! ```zig
//! try app.use(cors.permissive);                       // fine for a public API
//! try app.use(cors.with(.{
//!     .origins = &.{ "https://example.com", "https://staging.example.com" },
//!     .credentials = true,
//! }));
//! ```
//!
//! Configured at compile time, so the header strings are all constants and
//! nothing is formatted per request.
//!
//! **More than one origin is a match, not a format.** `Access-Control-Allow-
//! Origin` carries one value, so a server that answers two front ends has to
//! read the request's `Origin` and send back the one that matched. The compare
//! is `inline for` over what the application wrote, so it is N `mem.eql`s
//! against short literals and no allocation: the value that goes out is one of
//! the literals, not a copy of what arrived. A request with no `Origin` is not
//! cross-origin and gets no such header, which is the same thing the browser
//! would do with it (ADR 0099).
//!
//! What a named list costs that `"*"` does not is **one walk of the request
//! headers per request**, because finding out a request has no `Origin` means
//! looking for one. `"*"` is settled while compiling and reads nothing; the
//! matching branch is not compiled into an application that does not name an
//! origin.
//!
//! Headers go out before the handler runs, because a response is flushed
//! the moment it is sent and there is nothing left to add afterwards (ADR
//! 0009). They go out through `setStaticHeader`: every value here is a
//! compile-time constant, so copying it into the request arena would be
//! work with nothing to show for it.

const std = @import("std");
const Ctx = @import("ctx.zig").Ctx;
const mw = @import("middleware.zig");

pub const Options = struct {
    /// The origins this server answers cross-origin requests from.
    ///
    /// The request's `Origin` is compared against each, and the one that
    /// matches is what goes out — so a browser is told about itself and
    /// nobody else. `&.{"*"}` allows anyone, which is what a public API
    /// wants and what `permissive` is.
    ///
    /// Each entry is the scheme, host and port with nothing after them:
    /// `"https://example.com"`, `"http://localhost:5173"`. **Lowercase**, and
    /// checked while compiling, because a browser lowercases the scheme and
    /// host before it sends them and the value that comes back has to be the
    /// bytes it sent.
    origins: []const []const u8 = &.{"*"},
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

/// Whether this list is the one that means "anybody".
fn allowsAnyone(comptime origins: []const []const u8) bool {
    return origins.len == 1 and std.mem.eql(u8, origins[0], "*");
}

pub fn with(comptime options: Options) mw.Middleware {
    comptime check(options);

    const any = comptime allowsAnyone(options.origins);
    const max_age_text = comptime if (options.max_age > 0)
        std.fmt.comptimePrint("{d}", .{options.max_age})
    else
        "";

    return struct {
        fn run(c: *Ctx, next: mw.Next) anyerror!void {
            if (comptime any) {
                try c.setStaticHeader("Access-Control-Allow-Origin", "*");
            } else {
                // Set whether or not anything matched: the response really
                // does vary by origin, and a shared cache that was not told
                // so would hand one origin's response to another. Saying it
                // on the misses too is what keeps a refusal from being
                // cached as an answer.
                try c.setStaticHeader("Vary", "Origin");
                if (c.header("Origin")) |sent| {
                    const from = sent.view();
                    // Unrolled, so this is a compare against each literal
                    // rather than a walk over a list. Exact rather than
                    // case-insensitive, because the value that goes back has
                    // to be the bytes the browser sent — `check` refuses an
                    // origin that is not already lowercase, so the two
                    // cannot disagree.
                    inline for (options.origins) |allowed| {
                        if (std.mem.eql(u8, from, allowed)) {
                            try c.setStaticHeader("Access-Control-Allow-Origin", allowed);
                            break;
                        }
                    }
                }
            }

            if (comptime options.credentials) {
                try c.setStaticHeader("Access-Control-Allow-Credentials", "true");
            }
            if (comptime options.expose.len > 0) {
                try c.setStaticHeader("Access-Control-Expose-Headers", options.expose);
            }

            // A preflight is answered here and never reaches the handler —
            // there is no route for it to reach. An origin that matched
            // nothing is answered too, without the header that would let it
            // through: the browser is what refuses it, which is where a CORS
            // decision belongs.
            if (c.method == .OPTIONS and c.header("Access-Control-Request-Method") != null) {
                try c.setStaticHeader("Access-Control-Allow-Methods", options.methods);
                try c.setStaticHeader("Access-Control-Allow-Headers", options.headers);
                if (comptime options.max_age > 0) {
                    try c.setStaticHeader("Access-Control-Max-Age", max_age_text);
                }
                return c.sendEmpty(204);
            }

            return next.run(c);
        }
    }.run;
}

/// Everything that can be wrong with a list of origins, said while compiling.
///
/// All four are mistakes whose symptom is a browser refusing a request with a
/// message about CORS and no mention of the cause — which is an afternoon
/// each, and none of them needs a running server to find.
fn check(comptime options: Options) void {
    comptime {
        if (options.origins.len == 0) @compileError(
            "nilo: cors was given no origins at all, so every cross-origin request would be " ++
                "refused.\n  `.origins = &.{\"*\"}` allows anyone, or name the ones you serve: " ++
                "`.origins = &.{\"https://example.com\"}`.",
        );

        // `*` and credentials together is rejected by every browser, and the
        // failure shows up as a CORS error with no mention of the real cause.
        // Better to stop it here than let someone debug it at runtime.
        if (options.credentials and allowsAnyone(options.origins)) @compileError(
            "nilo: cors credentials cannot be combined with origin \"*\" — browsers reject it.\n" ++
                "  Name the origins explicitly, e.g. " ++
                ".origins = &.{\"https://example.com\"}.",
        );

        for (options.origins) |origin| {
            if (origin.len == 0) @compileError(
                "nilo: cors was given an empty origin, which matches nothing.\n" ++
                    "  An origin is a scheme, a host and a port: " ++
                    "\"https://example.com\", \"http://localhost:5173\".",
            );

            if (std.mem.eql(u8, origin, "*")) {
                if (options.origins.len > 1) @compileError(
                    "nilo: cors was given \"*\" alongside " ++ num(options.origins.len - 1) ++
                        " named origin(s), and \"*\" already allows every one of them.\n" ++
                        "  Drop the \"*\" to answer only the origins you named, or drop the " ++
                        "names to answer anyone.",
                );
                continue;
            }

            for (origin) |byte| {
                if (byte >= 'A' and byte <= 'Z') @compileError(
                    "nilo: the cors origin \"" ++ origin ++ "\" has a capital letter in it, and " ++
                        "a browser sends its origin lowercased.\n  It would never match, and the " ++
                        "browser would refuse the response without saying why. Write \"" ++
                        lowered(origin) ++ "\".",
                );
            }
        }
    }
}

fn num(comptime n: usize) []const u8 {
    return std.fmt.comptimePrint("{d}", .{n});
}

fn lowered(comptime text: []const u8) []const u8 {
    comptime {
        var out: [text.len]u8 = undefined;
        for (text, 0..) |byte, i| out[i] = std.ascii.toLower(byte);
        const frozen = out;
        return &frozen;
    }
}
