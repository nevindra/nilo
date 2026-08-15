//! Cookies: reading the `Cookie` header a request arrives with, and writing
//! the `Set-Cookie` headers a response leaves with (ADR 0030).
//!
//! ```zig
//! fn signIn(c: *zfast.Ctx, sessions: *Sessions) !void {
//!     try c.setCookie(.{ .name = "session", .value = try sessions.open() });
//! }
//!
//! fn whoAmI(c: *zfast.Ctx) !?User {
//!     const token = c.cookie("session") orelse return null;
//!     ...
//! }
//! ```
//!
//! **Reading allocates nothing.** A cookie value is handed back as a `Str`
//! pointing into the request head, exactly as `c.header` does — the header is
//! walked when somebody asks, not collected into a map on the way in. What
//! that costs is a scan per lookup; what it saves is an allocation on every
//! request that carries cookies and reads none, which is most of them.
//!
//! **What a value is not** is decoded. RFC 6265 says a cookie value is
//! opaque bytes and every framework then picks its own encoding on top —
//! percent, base64, signed-and-then-base64. Guessing would corrupt the ones
//! that guessed differently, so what went out is what comes back, minus the
//! quotes if the writer used them.

const std = @import("std");

/// What a browser is told about when to send a cookie back.
///
/// `unset` leaves the attribute off the header entirely, which is not the
/// same as `lax`: a browser with no `SameSite` applies its own default, and
/// which default that is has changed twice. Say what you mean.
pub const SameSite = enum { strict, lax, none, unset };

/// One cookie on the way out.
///
/// The defaults are the safe ones rather than the permissive ones: a cookie
/// set with `.{ .name = "session", .value = token }` is `Secure`, `HttpOnly`,
/// `SameSite=Lax` and scoped to `/`. Turning a protection off is then a
/// visible line in a diff, which is the right way round — the other way,
/// forgetting `HttpOnly` reads exactly like not needing it.
///
/// `Secure` on a server behind `http://localhost` is not a problem: browsers
/// have treated localhost as a secure context since 2020, so a development
/// server sets and receives these normally.
pub const Cookie = struct {
    name: []const u8,
    value: []const u8,

    /// The paths the cookie is sent back on. `/` — the whole site — rather
    /// than the path of whatever request happens to be setting it, which is
    /// what leaving this out would otherwise mean.
    path: []const u8 = "/",

    /// The hosts it is sent back to. Empty means this host and no
    /// subdomains, which is the narrower of the two readings and the one
    /// almost everybody wants.
    domain: []const u8 = "",

    /// How many seconds the cookie lives. Null is a session cookie — gone
    /// when the browser closes — which is what a login usually wants.
    max_age: ?i64 = null,

    /// An HTTP-date, for a caller that has one to hand. `max_age` is the
    /// one to reach for: it needs no clock, no formatting and no agreement
    /// about what time it is at the other end.
    expires: []const u8 = "",

    /// HTTPS only. On by default, and `SameSite=None` cannot be had without
    /// it — browsers refuse that combination outright.
    secure: bool = true,

    /// Kept away from JavaScript. On by default: a session token a script
    /// can read is a session token an injected script can send somewhere.
    http_only: bool = true,

    same_site: SameSite = .lax,
};

/// What `c.clearCookie` takes. A browser matches a deletion against the
/// name, the path *and* the domain, so a cookie set under `/admin` is not
/// cleared by a deletion at `/` — and the failure is silent, which is why
/// these three are spelled out rather than assumed.
pub const Clearing = struct {
    name: []const u8,
    path: []const u8 = "/",
    domain: []const u8 = "",
};

pub const Error = error{
    /// A cookie with no name is not a cookie.
    CookieNameEmpty,
    /// A character RFC 6265 does not allow in a cookie name.
    CookieNameInvalid,
    /// A character RFC 6265 does not allow in a cookie value — a space, a
    /// comma, a semicolon, a quote, a backslash or a control byte.
    CookieValueInvalid,
    /// `SameSite=None` without `Secure`, which every current browser drops.
    CookieNeedsSecure,
};

/// The value of the cookie called `name` in a `Cookie` header, or null.
///
/// The header is `a=1; b=2`, so this walks pairs rather than splitting the
/// whole thing: a request carrying twenty cookies and asked for one compares
/// names until it matches and then stops.
///
/// A repeated name answers with the first, which is what browsers send when
/// the same cookie exists at two paths and what every other server does with
/// it. Nothing sensible can be done with the second.
pub fn find(header: []const u8, name: []const u8) ?[]const u8 {
    var pairs = iterate(header);
    while (pairs.next()) |pair| {
        if (std.mem.eql(u8, pair.name, name)) return pair.value;
    }
    return null;
}

pub const Pair = struct { name: []const u8, value: []const u8 };

pub fn iterate(header: []const u8) Iterator {
    return .{ .rest = header };
}

/// Every cookie in a `Cookie` header, in the order it was sent.
pub const Iterator = struct {
    rest: []const u8,

    pub fn next(self: *Iterator) ?Pair {
        while (self.rest.len > 0) {
            const end = std.mem.indexOfScalar(u8, self.rest, ';') orelse self.rest.len;
            const pair = std.mem.trim(u8, self.rest[0..end], " \t");
            self.rest = if (end < self.rest.len) self.rest[end + 1 ..] else "";

            // A run with no `=` is not a cookie pair. Skipped rather than
            // refused: a stray `;` in a header nobody controls should not
            // cost a request its session.
            const equals = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
            const name = std.mem.trim(u8, pair[0..equals], " \t");
            if (name.len == 0) continue;
            return .{ .name = name, .value = unquoted(std.mem.trim(u8, pair[equals + 1 ..], " \t")) };
        }
        return null;
    }
};

/// A value written as `"…"` is handed back without the quotes. RFC 6265
/// allows the form and some writers use it; nothing else about the value is
/// touched.
fn unquoted(value: []const u8) []const u8 {
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
        return value[1 .. value.len - 1];
    }
    return value;
}

// ---- writing one ----

/// Whether this cookie can be written at all. Asked before anything is
/// allocated, so a mistake costs a message rather than a malformed header.
///
/// The characters are the reason this exists. A `;` in a value does not
/// produce a broken cookie — it produces a *second attribute*, so
/// `.value = "a; Path=/admin"` is a cookie with a path nobody wrote. That is
/// response splitting with extra steps, and it is refused here rather than
/// escaped, because there is no escaping in this grammar to do it with.
pub fn check(c: Cookie) Error!void {
    if (c.name.len == 0) return error.CookieNameEmpty;
    for (c.name) |ch| {
        if (!isTokenByte(ch)) return error.CookieNameInvalid;
    }
    for (c.value) |ch| {
        if (!isValueByte(ch)) return error.CookieValueInvalid;
    }
    if (c.same_site == .none and !c.secure) return error.CookieNeedsSecure;
}

/// RFC 9110's `token`: what a header field name, and so a cookie name, may
/// be made of.
fn isTokenByte(ch: u8) bool {
    return switch (ch) {
        'a'...'z', 'A'...'Z', '0'...'9' => true,
        '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        else => false,
    };
}

/// RFC 6265's `cookie-octet`: anything printable except the five characters
/// that mean something to the grammar around it.
fn isValueByte(ch: u8) bool {
    return switch (ch) {
        0x21, 0x23...0x2b, 0x2d...0x3a, 0x3c...0x5b, 0x5d...0x7e => true,
        else => false,
    };
}

/// How long the header value will be, so it can be allocated once at exactly
/// the right size. Held against `write` by a test — a length that disagreed
/// with what is written is a buffer overrun or a truncated cookie.
pub fn lengthOf(c: Cookie) usize {
    var n = c.name.len + 1 + c.value.len;
    if (c.path.len > 0) n += "; Path=".len + c.path.len;
    if (c.domain.len > 0) n += "; Domain=".len + c.domain.len;
    if (c.max_age) |seconds| n += "; Max-Age=".len + decimalLen(seconds);
    if (c.expires.len > 0) n += "; Expires=".len + c.expires.len;
    if (c.secure) n += "; Secure".len;
    if (c.http_only) n += "; HttpOnly".len;
    if (sameSiteName(c.same_site)) |name| n += "; SameSite=".len + name.len;
    return n;
}

fn decimalLen(value: i64) usize {
    var n: usize = if (value < 0) 1 else 0;
    var left = @abs(value);
    n += 1;
    while (left >= 10) : (left /= 10) n += 1;
    return n;
}

fn sameSiteName(same_site: SameSite) ?[]const u8 {
    return switch (same_site) {
        .strict => "Strict",
        .lax => "Lax",
        .none => "None",
        .unset => null,
    };
}

/// The `Set-Cookie` value itself. `check` has to have passed first — this
/// writes what it is given.
pub fn write(w: *std.Io.Writer, c: Cookie) !void {
    try w.writeAll(c.name);
    try w.writeByte('=');
    try w.writeAll(c.value);
    if (c.path.len > 0) {
        try w.writeAll("; Path=");
        try w.writeAll(c.path);
    }
    if (c.domain.len > 0) {
        try w.writeAll("; Domain=");
        try w.writeAll(c.domain);
    }
    if (c.max_age) |seconds| try w.print("; Max-Age={d}", .{seconds});
    if (c.expires.len > 0) {
        try w.writeAll("; Expires=");
        try w.writeAll(c.expires);
    }
    if (c.secure) try w.writeAll("; Secure");
    if (c.http_only) try w.writeAll("; HttpOnly");
    if (sameSiteName(c.same_site)) |name| {
        try w.writeAll("; SameSite=");
        try w.writeAll(name);
    }
}

/// The cookie that deletes the one `clearing` names: no value, and an age
/// that has already run out.
///
/// `Max-Age=0` and a date in the past say the same thing; both are sent
/// because a handful of old browsers only ever understood one of them, and
/// two attributes cost nine bytes.
pub fn deletion(clearing: Clearing) Cookie {
    return .{
        .name = clearing.name,
        .value = "",
        .path = clearing.path,
        .domain = clearing.domain,
        .max_age = 0,
        .expires = "Thu, 01 Jan 1970 00:00:00 GMT",
        // A deletion has to match the flags loosely enough to land whatever
        // the original was set with; the browser keys on name, path and
        // domain and nothing else.
        .secure = false,
        .http_only = false,
        .same_site = .unset,
    };
}

const testing = std.testing;

test "a cookie header is read pair by pair" {
    try testing.expectEqualStrings("1", find("a=1; b=2", "a").?);
    try testing.expectEqualStrings("2", find("a=1; b=2", "b").?);
    try testing.expect(find("a=1; b=2", "c") == null);

    // No space after the semicolon, which is legal and which some clients send.
    try testing.expectEqualStrings("2", find("a=1;b=2", "b").?);
    // One cookie, no separator at all.
    try testing.expectEqualStrings("xyz", find("session=xyz", "session").?);
    try testing.expect(find("", "session") == null);
}

test "a quoted value comes back without its quotes" {
    try testing.expectEqualStrings("a b", find("q=\"a b\"", "q").?);
    // A quote that is not a pair of them is data.
    try testing.expectEqualStrings("\"half", find("q=\"half", "q").?);
}

test "a value may hold the characters a value is allowed to hold" {
    // Base64 and its URL-safe spelling, which is what a session token is.
    try testing.expectEqualStrings(
        "eyJhbGciOiJIUzI1NiJ9.e30=",
        find("t=eyJhbGciOiJIUzI1NiJ9.e30=", "t").?,
    );
    // An `=` inside the value does not split the pair a second time.
    try testing.expectEqualStrings("a=b=c", find("x=a=b=c", "x").?);
}

test "rubbish in a cookie header costs nothing but the cookie it is in" {
    // A run with no `=` is stepped over, and the pairs around it still read.
    try testing.expectEqualStrings("1", find("junk; a=1", "a").?);
    try testing.expectEqualStrings("1", find("a=1; junk", "a").?);
    try testing.expectEqualStrings("1", find("; ; a=1 ;;", "a").?);
    try testing.expect(find("=novalue", "") == null);
}

test "the first of a repeated name is the answer" {
    try testing.expectEqualStrings("first", find("a=first; a=second", "a").?);
}

test "every cookie in a header can be walked" {
    var pairs = iterate("a=1; b=2; c=3");
    var seen: usize = 0;
    while (pairs.next()) |pair| : (seen += 1) {
        switch (seen) {
            0 => try testing.expectEqualStrings("a", pair.name),
            1 => try testing.expectEqualStrings("b", pair.name),
            2 => try testing.expectEqualStrings("3", pair.value),
            else => unreachable,
        }
    }
    try testing.expectEqual(@as(usize, 3), seen);
}

fn written(c: Cookie) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    try write(&out.writer, c);
    return out.toOwnedSlice();
}

test "the defaults are the safe ones" {
    const text = try written(.{ .name = "session", .value = "abc" });
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("session=abc; Path=/; Secure; HttpOnly; SameSite=Lax", text);
}

test "every attribute has somewhere to go" {
    const text = try written(.{
        .name = "session",
        .value = "abc",
        .path = "/admin",
        .domain = "example.dev",
        .max_age = 3600,
        .expires = "Thu, 01 Jan 1970 00:00:00 GMT",
        .secure = false,
        .http_only = false,
        .same_site = .strict,
    });
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(
        "session=abc; Path=/admin; Domain=example.dev; Max-Age=3600; " ++
            "Expires=Thu, 01 Jan 1970 00:00:00 GMT; SameSite=Strict",
        text,
    );
}

test "SameSite=unset leaves the attribute off rather than writing a word" {
    const text = try written(.{ .name = "a", .value = "b", .same_site = .unset, .path = "" });
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("a=b; Secure; HttpOnly", text);
}

test "the length worked out up front is the length that gets written" {
    const cases = [_]Cookie{
        .{ .name = "session", .value = "abc" },
        .{ .name = "a", .value = "" },
        .{ .name = "a", .value = "b", .path = "", .secure = false, .http_only = false, .same_site = .unset },
        .{ .name = "n", .value = "v", .max_age = 0 },
        .{ .name = "n", .value = "v", .max_age = -1 },
        .{ .name = "n", .value = "v", .max_age = 315360000 },
        .{ .name = "n", .value = "v", .domain = "example.dev", .expires = "Thu, 01 Jan 1970 00:00:00 GMT" },
        deletion(.{ .name = "session" }),
        deletion(.{ .name = "session", .path = "/admin", .domain = "example.dev" }),
    };
    for (cases) |c| {
        const text = try written(c);
        defer testing.allocator.free(text);
        try testing.expectEqual(text.len, lengthOf(c));
    }
}

test "a value that would smuggle a second attribute is refused" {
    // The one that matters: without this, `.value` decides the Path.
    try testing.expectError(error.CookieValueInvalid, check(.{
        .name = "session",
        .value = "abc; Path=/admin",
    }));
    try testing.expectError(error.CookieValueInvalid, check(.{ .name = "a", .value = "a b" }));
    try testing.expectError(error.CookieValueInvalid, check(.{ .name = "a", .value = "a,b" }));
    try testing.expectError(error.CookieValueInvalid, check(.{ .name = "a", .value = "a\"b" }));
    try testing.expectError(error.CookieValueInvalid, check(.{ .name = "a", .value = "a\\b" }));
    try testing.expectError(error.CookieValueInvalid, check(.{ .name = "a", .value = "a\r\nX: y" }));
}

test "a name has to be a name" {
    try testing.expectError(error.CookieNameEmpty, check(.{ .name = "", .value = "v" }));
    try testing.expectError(error.CookieNameInvalid, check(.{ .name = "a b", .value = "v" }));
    try testing.expectError(error.CookieNameInvalid, check(.{ .name = "a=b", .value = "v" }));
    try testing.expectError(error.CookieNameInvalid, check(.{ .name = "a;b", .value = "v" }));
}

test "SameSite=None without Secure is refused, because browsers drop it" {
    try testing.expectError(error.CookieNeedsSecure, check(.{
        .name = "a",
        .value = "b",
        .same_site = .none,
        .secure = false,
    }));
    try check(.{ .name = "a", .value = "b", .same_site = .none, .secure = true });
}

test "the ordinary shapes pass" {
    try check(.{ .name = "session", .value = "eyJhbGciOiJIUzI1NiJ9.e30=" });
    try check(.{ .name = "a", .value = "" });
    try check(deletion(.{ .name = "session" }));
}

test "what is written can be read back" {
    const text = try written(.{ .name = "session", .value = "abc123", .path = "" });
    defer testing.allocator.free(text);
    // A browser sends back the pair and none of the attributes, so the pair
    // is what has to survive the round trip.
    const pair_end = std.mem.indexOfScalar(u8, text, ';') orelse text.len;
    try testing.expectEqualStrings("abc123", find(text[0..pair_end], "session").?);
}
