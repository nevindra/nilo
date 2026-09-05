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

/// The origins a deployment answers, filled before `listen()` and read on the
/// requests that carry an `Origin` (ADR 0110).
///
/// `with` settles its list while compiling, which is what makes a named origin
/// cost one `mem.eql` against a literal and no allocation. The cost of that is
/// that the same binary cannot serve staging and production, because the front
/// end's address is a fact about the deployment — and every other deployment
/// fact in nilo arrives through `nilo_config` at run time.
///
/// So this is the other half. A program declares one of these where it will
/// outlive the App, fills it from wherever its settings come from, and hands
/// its address to `cors.reading`:
///
/// ```zig
/// var origins: nilo.cors.Origins = .empty;
///
/// pub fn main() !void {
///     var buf: [4][]const u8 = undefined;
///     try origins.setSplit(&buf, settings.web_origins);   // "https://a.com,https://b.com"
///     try app.use(nilo.cors.reading(&origins, .{ .credentials = true }));
///     try app.listen(.{});
/// }
/// ```
///
/// **The text is borrowed, not copied.** The entries point at whatever the
/// caller passed — the environment block, a `.env`'s text, a literal — and
/// have to outlive the server, which is the same rule `nilo_config` states
/// for a `[]const u8` field.
pub const Origins = struct {
    /// Read on the request path, written before there is one. There is no
    /// lock: a program that rewrites this while the server is running is
    /// racing every in-flight request, and reloading configuration is a
    /// separate feature that does not exist.
    list: []const []const u8 = &.{},

    pub const empty: Origins = .{};

    pub const SetError = error{
        /// An entry with a capital letter in it. A browser lowercases the
        /// scheme and host before it sends them, so this would never match.
        OriginNotLowercase,
        /// An empty entry, which matches nothing.
        OriginEmpty,
        /// `"*"`. A runtime list names the deployments this server answers;
        /// answering anybody is `cors.permissive`, and it needs no list.
        OriginIsWildcard,
    };

    /// Take a list the caller assembled. The same four things `with` refuses
    /// while compiling, refused here as errors, because a list that arrives
    /// at run time cannot be refused any earlier.
    pub fn set(self: *Origins, list: []const []const u8) SetError!void {
        for (list) |origin| try checkOne(origin);
        self.list = list;
    }

    /// Split `text` on commas into `into`, trimming spaces, and take the
    /// result. `into` is the caller's — one array, no allocation, and its
    /// length is the most origins this program will answer.
    ///
    /// `error.TooManyOrigins` when the text names more than `into` holds,
    /// rather than a list quietly missing its last entry.
    pub fn setSplit(
        self: *Origins,
        into: [][]const u8,
        text: []const u8,
    ) (SetError || error{TooManyOrigins})!void {
        var n: usize = 0;
        var parts = std.mem.splitScalar(u8, text, ',');
        while (parts.next()) |raw| {
            const origin = std.mem.trim(u8, raw, " \t");
            if (origin.len == 0) continue;
            if (n == into.len) return error.TooManyOrigins;
            try checkOne(origin);
            into[n] = origin;
            n += 1;
        }
        self.list = into[0..n];
    }

    fn checkOne(origin: []const u8) SetError!void {
        if (origin.len == 0) return error.OriginEmpty;
        if (std.mem.eql(u8, origin, "*")) return error.OriginIsWildcard;
        for (origin) |byte| {
            if (byte >= 'A' and byte <= 'Z') return error.OriginNotLowercase;
        }
    }

    fn matches(self: *const Origins, sent: []const u8) ?[]const u8 {
        for (self.list) |allowed| {
            if (std.mem.eql(u8, sent, allowed)) return allowed;
        }
        return null;
    }
};

/// The CORS middleware, reading its origins from `held` rather than from a
/// list settled while compiling (ADR 0110).
///
/// Everything else — the preflight, the credentials, the exposed headers, the
/// max age — is comptime exactly as `with`'s is, because none of it is a fact
/// about the deployment. What changes is one compare: a walk over a list whose
/// length is known only at run time, instead of an unrolled compare against
/// literals. Nothing is allocated either way.
///
/// `held` is a comptime pointer, so it has to be a variable that outlives the
/// App — a container-level `var`, which is the shape the example above uses.
pub fn reading(comptime held: *Origins, comptime options: Options) mw.Middleware {
    comptime checkReading(options);

    return struct {
        /// Said once, on the first cross-origin request that finds the list
        /// empty. Not at startup: nothing here runs at startup, and a program
        /// that fills the list after `use` and before `listen` would be told
        /// off for something it was about to do.
        var said: std.atomic.Value(bool) = .init(false);

        fn run(c: *Ctx, next: mw.Next) anyerror!void {
            // Set whether or not anything matched, for the reason `with`
            // states: the response really does vary by origin, and a shared
            // cache that was not told so would hand one origin's response to
            // another.
            try c.setStaticHeader("Vary", "Origin");
            if (c.header("Origin")) |sent| {
                if (held.matches(sent.view())) |allowed| {
                    // Not copied, which is the whole reason `Origins` says its
                    // text has to outlive the server: that contract is what
                    // makes this `setStaticHeader` rather than an allocation
                    // on the request path, and it is what keeps the budget at
                    // one (ADR 0018).
                    try c.setStaticHeader("Access-Control-Allow-Origin", allowed);
                } else if (held.list.len == 0) {
                    sayItIsEmpty();
                }
            }

            if (comptime options.credentials) {
                try c.setStaticHeader("Access-Control-Allow-Credentials", "true");
            }
            if (comptime options.expose.len > 0) {
                try c.setStaticHeader("Access-Control-Expose-Headers", options.expose);
            }

            if (c.method == .OPTIONS and c.header("Access-Control-Request-Method") != null) {
                try c.setStaticHeader("Access-Control-Allow-Methods", options.methods);
                try c.setStaticHeader("Access-Control-Allow-Headers", options.headers);
                if (comptime options.max_age > 0) {
                    try c.setStaticHeader("Access-Control-Max-Age", maxAgeText(options));
                }
                return c.sendEmpty(204);
            }

            return next.run(c);
        }

        fn sayItIsEmpty() void {
            if (said.load(.monotonic)) return;
            if (said.swap(true, .monotonic)) return;
            std.log.warn(
                "cors.reading was given no origins, so every cross-origin request is " ++
                    "refused by the browser. Call set() or setSplit() on the Origins " ++
                    "before listen().",
                .{},
            );
        }
    }.run;
}

/// The one thing that can be wrong with a `reading` call: naming origins in
/// two places at once. Said while compiling, because a list that is ignored
/// is a list somebody will edit and then wonder about.
fn checkReading(comptime options: Options) void {
    comptime {
        if (options.origins.len != 1 or !std.mem.eql(u8, options.origins[0], "*")) @compileError(
            "nilo: cors.reading takes its origins from the Origins you hand it, so the " ++
                "`.origins` field has nothing to do.\n  Drop it, and call " ++
                "`set()` or `setSplit()` on the Origins before listen() — or use " ++
                "`cors.with(.{ .origins = … })` if the list is known while compiling.",
        );
    }
}

fn maxAgeText(comptime options: Options) []const u8 {
    return comptime std.fmt.comptimePrint("{d}", .{options.max_age});
}

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

const testing = std.testing;

test "a runtime list is taken, and matched exactly" {
    var origins: Origins = .empty;
    try origins.set(&.{ "https://app.example.com", "http://localhost:5173" });

    try testing.expectEqualStrings(
        "https://app.example.com",
        origins.matches("https://app.example.com").?,
    );
    try testing.expect(origins.matches("https://evil.example.com") == null);
    // A prefix is not a match: `https://app.example.com.evil.com` is somebody
    // else's host, and so is a shorter one.
    try testing.expect(origins.matches("https://app.example.com.evil.com") == null);
    try testing.expect(origins.matches("https://app.example.co") == null);
}

test "the three things a runtime origin cannot be, refused where they arrive" {
    var origins: Origins = .empty;

    // The same mistakes `with` refuses while compiling. A list that arrives at
    // run time cannot be refused any earlier than this, so `set` is where the
    // program finds out — and it finds out at startup rather than from a
    // browser saying nothing in particular months later.
    try testing.expectError(error.OriginNotLowercase, origins.set(&.{"https://App.example.com"}));
    try testing.expectError(error.OriginEmpty, origins.set(&.{""}));
    try testing.expectError(error.OriginIsWildcard, origins.set(&.{"*"}));

    // And a refused list is not half-taken.
    try testing.expectEqual(@as(usize, 0), origins.list.len);
}

test "a comma-separated setting becomes a list, in the caller's own array" {
    var buf: [4][]const u8 = undefined;
    var origins: Origins = .empty;
    try origins.setSplit(&buf, "https://app.example.com, https://staging.example.com");

    try testing.expectEqual(@as(usize, 2), origins.list.len);
    try testing.expectEqualStrings("https://app.example.com", origins.list[0]);
    try testing.expectEqualStrings("https://staging.example.com", origins.list[1]);

    // An empty setting is an empty list rather than one empty origin, which is
    // what an unset environment variable looks like.
    try origins.setSplit(&buf, "");
    try testing.expectEqual(@as(usize, 0), origins.list.len);

    // Trailing and doubled commas say nothing and are skipped.
    try origins.setSplit(&buf, "https://a.example.com,,");
    try testing.expectEqual(@as(usize, 1), origins.list.len);
}

test "more origins than the array holds is an error, not a list missing its last entry" {
    var buf: [2][]const u8 = undefined;
    var origins: Origins = .empty;
    try testing.expectError(error.TooManyOrigins, origins.setSplit(
        &buf,
        "https://a.example.com,https://b.example.com,https://c.example.com",
    ));
}

test "a bad entry in the middle of a setting stops the whole list" {
    var buf: [4][]const u8 = undefined;
    var origins: Origins = .empty;
    try testing.expectError(error.OriginNotLowercase, origins.setSplit(
        &buf,
        "https://a.example.com,https://B.example.com",
    ));
    try testing.expectEqual(@as(usize, 0), origins.list.len);
}
