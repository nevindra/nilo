//! Building a URL out of the route pattern it belongs to, checked while
//! compiling ([ADR 100](../docs/adr/100-a-route-pattern-is-the-name-of-its-url.md)).
//!
//! ```zig
//! const where = try c.url("/users/:id/posts/:slug", .{ .id = 42, .slug = title });
//! try c.redirect(303, where);
//! ```
//!
//! **The pattern is the name.** Fiber gives a route a `Name` and looks the
//! pattern up again at run time with `GetRouteURL`; Gin has nothing. A name is
//! a second string to keep in step with the route, and the failure it has is
//! silent — rename the route, keep the name, and the URL still builds out of a
//! pattern nothing serves. Here the pattern *is* what you write, so there is
//! nothing to keep in step, and the mistakes that are left are compile errors:
//! a param with no value, a value with no param, a type that cannot be written
//! into a path.
//!
//! **Matched by name, unlike a handler's arguments.** `typed.zig` matches path
//! params by position because Zig does not keep argument names. A struct's
//! fields do have names, so `.{ .id = 42 }` is checked against `:id` by the
//! name a reader can see — which is what makes a two-param pattern safe to
//! write in either order.
//!
//! **Every value is percent-encoded.** A slash in a value is a character
//! somebody typed rather than a path segment they get to invent:
//! `url("/users/:id", .{ .id = "a/b" })` is `/users/a%2Fb`, one segment. That
//! is a property rather than a nicety — the alternative is a value from a form
//! deciding which route the URL it lands in matches. The same property is why
//! a text value of `.`, `..` or nothing at all is refused with
//! `error.BadValue`: encoding cannot save them, because a browser reads `%2E`
//! as a dot, so they would still drop or add a segment.

const std = @import("std");
const core = @import("nilo_core");
const percent = core.percent;
const naming = @import("names.zig");

const Str = core.Str;

/// What building a URL can fail with: the writer, or a value that is not a
/// path segment.
pub const WriteError = std.Io.Writer.Error || error{
    /// A text value that is empty, `.` or `..`. Each is a segment that does
    /// something other than name itself: `/u/../settings` is `/settings` once
    /// a browser has followed it, `%2E%2E` is the same to one (WHATWG reads a
    /// percent-encoded dot as a dot), and an empty one is `/u//settings`,
    /// which the router gives no param. Refused rather than rewritten, because
    /// there is no spelling of these that names a segment.
    BadValue,
};

/// Write the URL for `pattern`, with `args` filling its params.
///
/// The whole check is at compile time and the run-time work is a walk over the
/// pattern: no allocation, no lookup, and nothing that can fail but the writer
/// itself.
pub fn write(w: *std.Io.Writer, comptime pattern: []const u8, args: anytype) WriteError!void {
    comptime check(pattern, @TypeOf(args));

    comptime var at: usize = 0;
    inline while (at < pattern.len) {
        const rest = pattern[at..];
        const found = comptime std.mem.indexOfScalar(u8, rest, ':');
        if (found == null) {
            try w.writeAll(rest);
            return;
        }
        const colon = comptime found.?;
        try w.writeAll(rest[0..colon]);

        const name_and_rest = rest[colon + 1 ..];
        const name_len = comptime segmentEnd(name_and_rest);
        try writeValue(w, @field(args, name_and_rest[0..name_len]));

        at += colon + 1 + name_len;
    }
}

/// The URL for `pattern` written into a caller's buffer, for somebody who has
/// no `Ctx` — a link in an email sent from spawned work, a test.
///
/// `error.NoSpaceLeft` is how it fails when the URL does not fit, and
/// `Ctx.url` is the call that does not have to think about the size.
/// `error.BadValue` is a text value that is not a segment (see `WriteError`).
pub fn into(buf: []u8, comptime pattern: []const u8, args: anytype) error{ NoSpaceLeft, BadValue }![]u8 {
    var w: std.Io.Writer = .fixed(buf);
    write(&w, pattern, args) catch |err| switch (err) {
        error.BadValue => return error.BadValue,
        error.WriteFailed => return error.NoSpaceLeft,
    };
    return w.buffered();
}

/// One param's value, written the way a path segment is allowed to carry it.
///
/// Which types get here is settled by `writable` in `check`, so there is no
/// `else` to fall down: a type that cannot go in a path was a compile error
/// naming the field, back where somebody wrote it.
fn writeValue(w: *std.Io.Writer, value: anytype) WriteError!void {
    const V = @TypeOf(value);
    if (V == Str) return writeText(w, value.view());
    return switch (@typeInfo(V)) {
        // A number needs no escaping and a bool is two words, so neither pays
        // for the encoder.
        .int, .comptime_int => w.print("{d}", .{value}),
        .bool => w.writeAll(if (value) "true" else "false"),
        .@"enum" => percent.encodeWrite(w, @tagName(value), .unreserved),
        else => writeText(w, value),
    };
}

/// Text as one path segment: percent-encoded, and refused when it is empty or
/// a dot segment, which no encoding makes safe (see `WriteError`).
fn writeText(w: *std.Io.Writer, text: []const u8) WriteError!void {
    if (text.len == 0 or std.mem.eql(u8, text, ".") or std.mem.eql(u8, text, "..")) return error.BadValue;
    return percent.encodeWrite(w, text, .unreserved);
}

/// Whether a value of this type can be written into a path segment.
///
/// The accepted list is `convert.convertible`'s minus floats, and that
/// symmetry is the point: a value that arrived as a path param can go back out
/// as one. A float is left out because the text it round-trips through is the
/// one thing here nobody agrees about, and a URL built out of `0.1` is a URL
/// somebody has to match again later.
fn writable(comptime T: type) bool {
    if (T == Str) return true;
    return switch (@typeInfo(T)) {
        .int, .comptime_int, .bool, .@"enum" => true,
        .pointer => |p| switch (p.size) {
            .slice => p.child == u8,
            .one => @typeInfo(p.child) == .array and std.meta.Elem(p.child) == u8,
            else => false,
        },
        else => false,
    };
}

/// How far the param name that starts here runs: to the next `/` or to the end
/// of the pattern.
fn segmentEnd(rest: []const u8) usize {
    return std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
}

/// Every `:name` in `pattern`, in the order they appear.
fn paramsOf(comptime pattern: []const u8) []const []const u8 {
    comptime {
        var found: []const []const u8 = &.{};
        var at: usize = 0;
        while (std.mem.indexOfScalarPos(u8, pattern, at, ':')) |colon| {
            const name_and_rest = pattern[colon + 1 ..];
            found = found ++ &[_][]const u8{name_and_rest[0..segmentEnd(name_and_rest)]};
            at = colon + 1;
        }
        return found;
    }
}

/// Everything that can be wrong, said where it is written.
fn check(comptime pattern: []const u8, comptime Args: type) void {
    comptime {
        if (pattern.len == 0 or pattern[0] != '/') @compileError(
            "nilo: a route pattern starts with \"/\", and \"" ++ pattern ++ "\" does not.",
        );

        // A catch-all has no name a struct field could carry — `*` is not an
        // identifier — and what it stands for is a whole tail of path rather
        // than one segment, which is not a thing to percent-encode as a unit.
        if (std.mem.indexOfScalar(u8, pattern, '*') != null) @compileError(
            "nilo: \"" ++ pattern ++ "\" has a `*` catch-all, and a URL cannot be built for one.\n" ++
                "  A `*` stands for however much path is left, so there is no single value to " ++
                "put there. Write the URL out, or give the route a pattern with named params.",
        );

        const info = @typeInfo(Args);
        // `.{}` is a tuple with no fields, and it is the right thing to write
        // for a pattern with no params — so a tuple is only wrong once it has
        // something in it to be positional about.
        if (info != .@"struct" or (info.@"struct".is_tuple and info.@"struct".field_names.len > 0))
            @compileError(
                "nilo: the values for \"" ++ pattern ++ "\" are given by name — " ++
                    ".{ .id = 42 } — and this is " ++ naming.of(Args) ++ ".",
            );

        const params = paramsOf(pattern);
        const field_names = info.@"struct".field_names;
        const field_types = info.@"struct".field_types;

        for (params) |name| {
            if (name.len == 0) @compileError(
                "nilo: \"" ++ pattern ++ "\" has a \":\" with no name after it.",
            );
            if (!@hasField(Args, name)) @compileError(
                "nilo: \"" ++ pattern ++ "\" has a param `:" ++ name ++ "` and nothing was " ++
                    "given for it.\n" ++
                    "  Add `." ++ name ++ " = …` to the values.",
            );
        }

        for (field_names, field_types) |field_name, field_type| {
            var wanted = false;
            for (params) |name| {
                if (std.mem.eql(u8, name, field_name)) wanted = true;
            }
            if (!wanted) @compileError(
                "nilo: \"" ++ pattern ++ "\" has no param called `:" ++ field_name ++ "`, so the " ++
                    "value given for it would go nowhere.\n" ++
                    "  Its params are: " ++ list(params) ++ ".",
            );
            if (!writable(field_type)) @compileError(
                "nilo: `:" ++ field_name ++ "` in \"" ++ pattern ++ "\" was given a " ++
                    naming.of(field_type) ++ ", which is not something a path segment can carry.\n" ++
                    "  A param can be text, a number, a bool or an enum — the same types one " ++
                    "arrives as.",
            );
        }
    }
}

/// The params of a pattern, for the sentence that says which they are.
fn list(comptime params: []const []const u8) []const u8 {
    comptime {
        if (params.len == 0) return "none";
        var out: []const u8 = "";
        for (params, 0..) |name, i| {
            out = out ++ (if (i == 0) "" else ", ") ++ ":" ++ name;
        }
        return out;
    }
}

const testing = std.testing;

fn built(buf: []u8, comptime pattern: []const u8, args: anytype) ![]u8 {
    return into(buf, pattern, args);
}

test "a pattern with no params is itself" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("/health", try built(&buf, "/health", .{}));
}

test "a param is filled by the field of the same name, in either order" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings(
        "/users/42/posts/hello",
        try built(&buf, "/users/:id/posts/:slug", .{ .id = 42, .slug = "hello" }),
    );
    // The names are what match, so writing them the other way round is the
    // same URL — which is the difference between this and a handler's
    // positional params.
    try testing.expectEqualStrings(
        "/users/42/posts/hello",
        try built(&buf, "/users/:id/posts/:slug", .{ .slug = "hello", .id = 42 }),
    );
}

test "a value cannot invent a path segment" {
    // The property this exists for: a slash inside a value is a character
    // somebody typed, and a URL built from it still names one segment.
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings(
        "/users/a%2Fb",
        try built(&buf, "/users/:id", .{ .id = "a/b" }),
    );
    // And the rest of what a path is not allowed to carry loose.
    try testing.expectEqualStrings(
        "/q/one%20two%3F%23",
        try built(&buf, "/q/:term", .{ .term = "one two?#" }),
    );
}

test "the types a param arrives as are the types it goes back out as" {
    var buf: [64]u8 = undefined;
    const Colour = enum { red, blue };
    try testing.expectEqualStrings("/n/-7", try built(&buf, "/n/:v", .{ .v = @as(i32, -7) }));
    try testing.expectEqualStrings("/b/true", try built(&buf, "/b/:v", .{ .v = true }));
    try testing.expectEqualStrings("/c/blue", try built(&buf, "/c/:v", .{ .v = Colour.blue }));
}

test "a param at the very end and one in the middle are both filled" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("/a/1/b", try built(&buf, "/a/:x/b", .{ .x = 1 }));
    try testing.expectEqualStrings("/a/1", try built(&buf, "/a/:x", .{ .x = 1 }));
}

test "a buffer too small says so rather than writing half a URL" {
    var buf: [4]u8 = undefined;
    try testing.expectError(error.NoSpaceLeft, into(&buf, "/users/:id", .{ .id = 42 }));
}

test "a value that is empty or a dot segment is refused rather than built into the path" {
    // `/u/../settings` is `/settings` once a browser has followed it, and
    // `%2E%2E` is the same thing to one (WHATWG reads it as a dot segment
    // too), so encoding is not a way out. An empty value is `/u//settings`.
    var buf: [64]u8 = undefined;
    try testing.expectError(error.BadValue, into(&buf, "/u/:name/settings", .{ .name = ".." }));
    try testing.expectError(error.BadValue, into(&buf, "/u/:name/settings", .{ .name = "." }));
    try testing.expectError(error.BadValue, into(&buf, "/u/:name/settings", .{ .name = "" }));
    // A value that merely contains dots is an ordinary name.
    try testing.expectEqualStrings("/u/a..b/settings", try into(&buf, "/u/:name/settings", .{ .name = "a..b" }));
    try testing.expectEqualStrings("/u/...", try into(&buf, "/u/:name", .{ .name = "..." }));
}
