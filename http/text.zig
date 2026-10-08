//! Text with a shape, as a type
//! ([ADR 193](../docs/adr/193-text-with-a-shape-is-a-type-and-a-rule-about-the-struct-is-a-function-on-it.md)).
//!
//! ```zig
//! const SignUp = struct {
//!     email:    nilo.Email,
//!     password: nilo.Text(.{ .min = 10, .max = 72 }),
//!     nickname: nilo.Text(.{ .max = 30 }) = .of(""),
//!     sku:      nilo.Text(.{ .check = startsWithSku, .said = "has to be a SKU code" }),
//! };
//! ```
//!
//! What `Within(min, max)` is for a number (ADR 167), this is for text: a
//! `Str` that parses itself (ADR 113), so it is read wherever a `Str` is —
//! a path param, a query value, a form field, a JSON body — refused with one
//! sentence in all four, collected by `Bound` beside every other field, and
//! described in the document with `minLength`, `maxLength` and `format`,
//! read off a type that enforces them rather than off a claim.
//!
//! **A bound is not a validation, and neither is a check.** `convert.Reason`
//! refuses a validation language on purpose; a `u8` refuses 300 and nobody
//! calls that one. The type has a shape and the text did not fit it. `check`
//! is where a language would have needed an escape hatch, and it is a plain
//! function, so it is the escape hatch.
//!
//! **`min` and `max` count code points**, which is what JSON Schema's
//! `minLength` counts: the document and the server have to mean the same
//! thing by the same number, and `naïveté` is seven characters in both.
//!
//! **A `Text` never quotes the text back.** `Within` writes `not "500"`; a
//! password in a 422 body — and in the log line beside it — is a leak. The
//! sentence says the count: `"password" has to be text of 10 to 72
//! characters, not 6`. `Email` is a preset that does quote, because an
//! address is not a secret and seeing it is how the typo is found.
//!
//! **The `Str` is `.value`**, and `view`, `len`, `eql` and `blank` are
//! forwarded so the ordinary reads need no unwrapping. `.of("…")` for a
//! default checks it against the shape while compiling, because a default is
//! the one value a request never sends.

const std = @import("std");
const mark = @import("jsonmark.zig");
const str_mod = @import("nilo_core");

const Str = str_mod.Str;

/// What a `Text` is allowed to ask of the text.
pub const Options = struct {
    /// At least this many code points.
    min: ?usize = null,
    /// At most this many.
    max: ?usize = null,
    /// A predicate of your own over the bytes. Wants `said` beside it,
    /// because a check with no sentence is a 400 that cannot say why.
    check: ?*const fn ([]const u8) bool = null,
    /// The sentence after the label, in `must`'s shape: `"sku" has to be a
    /// SKU code`. Said instead of the count when the check is what failed.
    said: ?[]const u8 = null,
    /// OpenAPI's `format`, for a preset that has one.
    format: ?[]const u8 = null,
    /// Whether a refusal quotes the text. Off for a `Text` a caller writes,
    /// because a password is the ordinary case; on for `Email`.
    quotes: bool = false,
    /// What a compile error calls the type, for a preset.
    name: ?[]const u8 = null,
    /// What a 400 asks for — `the form is missing "email" (an address)` —
    /// when the shape's own wording would not read well. For a preset.
    expects: ?[]const u8 = null,
};

pub fn Text(comptime opts: Options) type {
    comptime check(opts);
    return struct {
        const Self = @This();

        /// What a nilo compile error calls this type (ADR 074).
        pub const nilo_type_name = opts.name orelse spelled(opts);

        /// What a 400 asks for, in place of the type's name.
        pub const nilo_expects = opts.expects orelse expects(opts);

        /// The shape, for the document to say (`openapi.zig` reads it by
        /// name): `minLength`, `maxLength`, `format`.
        pub const nilo_text = .{ .min = opts.min, .max = opts.max, .format = opts.format };

        /// Text on the wire, and said so, so that a response carrying one
        /// is written by nilo's own writer around it (ADR 148).
        pub const nilo_openapi = .{ .type = "string", .format = opts.format };

        value: Str,

        /// A value known while compiling — the default a field falls back
        /// to — checked against the shape here rather than never.
        pub fn of(comptime text: []const u8) Self {
            comptime {
                if (fits(text) == null) @compileError(
                    "nilo: `" ++ nilo_type_name ++ ".of(\"" ++ text ++ "\")` does not fit its own shape.\n" ++
                        "  A default is the one value a request never sends, so it is the one " ++
                        "the shape would never catch — which is why it is checked here.",
                );
            }
            return .{ .value = .static(text) };
        }

        /// The bytes, refused with the same null a bad number gets
        /// (ADR 113). The `Str` built here has no lifetime marker; the
        /// engine stamps it with the one on the text it came from.
        pub fn nilo_parse(text: []const u8) ?Self {
            if (fits(text) == null) return null;
            return .{ .value = .static(text) };
        }

        /// The tail of the sentence after the label — `has to be text of 10
        /// to 72 characters, not 6` — written by the type because the type
        /// knows which part of the shape the text missed, and because it is
        /// the type's decision whether the text is quoted (ADR 193).
        pub fn nilo_explain(text: []const u8, w: *std.Io.Writer) !void {
            const n = count(text);
            if (opts.min != null and n < opts.min.?) return sayCount(n, w);
            if (opts.max != null and n > opts.max.?) return sayCount(n, w);
            // The check is what failed, and `said` is its sentence.
            try w.writeAll(opts.said.?);
            if (opts.quotes) try w.print(", not \"{s}\"", .{text});
        }

        fn sayCount(n: usize, w: *std.Io.Writer) !void {
            try w.print("has to be " ++ comptime expects(opts) ++ ", not {d}", .{n});
        }

        /// The count when the text fits, null when it does not — shared by
        /// the parse and the default so the two cannot disagree.
        fn fits(text: []const u8) ?usize {
            const n = count(text);
            if (opts.min) |min| if (n < min) return null;
            if (opts.max) |max| if (n > max) return null;
            if (opts.check) |c| if (!c(text)) return null;
            return n;
        }

        /// The third arrival, a JSON body: the string, handed to
        /// `nilo_parse` (ADR 166).
        pub const jsonParse = mark.parseFor(Self);

        pub fn jsonStringify(self: Self, jw: anytype) !void {
            try jw.write(self.value.view());
        }

        pub fn view(self: Self) []const u8 {
            return self.value.view();
        }

        pub fn len(self: Self) usize {
            return self.value.len();
        }

        pub fn eql(self: Self, other: []const u8) bool {
            return self.value.eql(other);
        }

        pub fn blank(self: Self) bool {
            return self.value.blank();
        }
    };
}

/// Code points, or bytes for text that is not UTF-8 — which then reads as
/// longer, never shorter, so a bound refuses it rather than lets it in.
fn count(text: []const u8) usize {
    return std.unicode.utf8CountCodepoints(text) catch text.len;
}

/// The declaration a type that parses itself may carry to word its own
/// refusal, read by `convert.zig` in place of the sentence ADR 113 wrote.
pub const explain_marker = "nilo_explain";

/// The declaration the document reads the shape off, by name.
pub const marker = "nilo_text";

fn check(comptime opts: Options) void {
    if (opts.min != null and opts.max != null and opts.min.? > opts.max.?) @compileError(std.fmt.comptimePrint(
        "nilo: `Text(.{{ .min = {d}, .max = {d} }})` has its bounds the wrong way round: " ++
            "nothing is at least {d} and at most {d} characters.\n" ++
            "  The smaller bound is `min`: `Text(.{{ .min = {d}, .max = {d} }})`.",
        .{ opts.min.?, opts.max.?, opts.min.?, opts.max.?, opts.max.?, opts.min.? },
    ));
    if (opts.min == null and opts.max == null and opts.check == null) @compileError(
        "nilo: `Text(.{})` asks nothing of the text, so it is a `Str` with a longer name.\n" ++
            "  Give it a shape — `.min`, `.max`, or a `.check` with its `.said` — or write `nilo.Str`.",
    );
    if (opts.check != null and opts.said == null) @compileError(
        "nilo: `Text(.{ .check = … })` has a check and no sentence, so text it refuses would get a 400 that cannot say why.\n" ++
            "  Say what the check wants, in the shape `must` uses: " ++
            "`Text(.{ .check = startsWithSku, .said = \"has to be a SKU code\" })`.",
    );
    if (opts.said != null and opts.check == null) @compileError(
        "nilo: `Text(.{ .said = … })` has a sentence and no check to say it for; a bound words its own refusal.\n" ++
            "  Drop `.said`, or add the `.check` it belongs to.",
    );
}

fn spelled(comptime opts: Options) []const u8 {
    comptime {
        var out: []const u8 = "nilo.Text(.{";
        var first = true;
        if (opts.min) |min| {
            out = out ++ std.fmt.comptimePrint(" .min = {d}", .{min});
            first = false;
        }
        if (opts.max) |max| {
            out = out ++ (if (first) "" else ",") ++ std.fmt.comptimePrint(" .max = {d}", .{max});
            first = false;
        }
        if (opts.check != null) out = out ++ (if (first) "" else ",") ++ " .check = …";
        return out ++ " })";
    }
}

fn expects(comptime opts: Options) []const u8 {
    comptime {
        if (opts.min != null and opts.max != null) return std.fmt.comptimePrint(
            "text of {d} to {d} characters",
            .{ opts.min.?, opts.max.? },
        );
        if (opts.min) |min| return std.fmt.comptimePrint("text of at least {d} characters", .{min});
        if (opts.max) |max| return std.fmt.comptimePrint("text of at most {d} characters", .{max});
        return "text";
    }
}

// ---- the presets ----

/// An address, checked the way every application checked it by hand: one
/// `@` with something before it, a dot after it, no whitespace, 254
/// characters at most. Not RFC 5322 — the check that matters is sending the
/// mail — and `format: email` in the document.
pub const Email = Text(.{
    .max = 254,
    .check = emailShaped,
    .said = "has to look like an address",
    .format = "email",
    .quotes = true,
    .name = "nilo.Email",
    .expects = "an email address",
});

/// A URL with a scheme and a host, by `std.Uri`'s reading, and `format: uri`
/// in the document.
pub const Url = Text(.{
    .max = 2048,
    .check = urlShaped,
    .said = "has to be a URL with a scheme and a host",
    .format = "uri",
    .quotes = true,
    .name = "nilo.Url",
    .expects = "a URL",
});

fn emailShaped(text: []const u8) bool {
    const at = std.mem.indexOfScalar(u8, text, '@') orelse return false;
    if (at == 0) return false;
    const domain = text[at + 1 ..];
    if (std.mem.indexOfScalar(u8, domain, '@') != null) return false;
    const dot = std.mem.lastIndexOfScalar(u8, domain, '.') orelse return false;
    if (dot == 0 or dot == domain.len - 1) return false;
    for (text) |ch| {
        if (ch <= ' ' or ch == 0x7f) return false;
    }
    return true;
}

fn urlShaped(text: []const u8) bool {
    const uri = std.Uri.parse(text) catch return false;
    const host = uri.host orelse return false;
    return uri.scheme.len > 0 and !host.isEmpty();
}

// ---- tests ----

const testing = std.testing;

fn startsWithSku(text: []const u8) bool {
    return std.mem.startsWith(u8, text, "SKU-");
}

test "a Text within its bounds parses and one outside does not" {
    const Password = Text(.{ .min = 10, .max = 72 });
    try testing.expect(Password.nilo_parse("correct horse") != null);
    try testing.expect(Password.nilo_parse("short") == null);
    try testing.expect(Password.nilo_parse(&@as([73]u8, @splat('x'))) == null);
    try testing.expectEqualStrings("correct horse", Password.nilo_parse("correct horse").?.view());
}

test "a bound counts characters rather than bytes" {
    const Seven = Text(.{ .min = 7, .max = 7 });
    try testing.expect(Seven.nilo_parse("naïveté") != null);
    try testing.expect(Seven.nilo_parse("naivete") != null);
    try testing.expect(Seven.nilo_parse("naïvetés") == null);
}

test "a check refuses what the bounds would have let through" {
    const Sku = Text(.{ .check = startsWithSku, .said = "has to be a SKU code" });
    try testing.expect(Sku.nilo_parse("SKU-1") != null);
    try testing.expect(Sku.nilo_parse("sku-1") == null);
}

test "the sentence says the count and never the text" {
    const Password = Text(.{ .min = 10, .max = 72 });
    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try Password.nilo_explain("hunter2", &w);
    try testing.expectEqualStrings("has to be text of 10 to 72 characters, not 7", w.buffered());
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "hunter2") == null);
}

test "the sentence for a failed check is the caller's, and quotes only when asked" {
    const Sku = Text(.{ .check = startsWithSku, .said = "has to be a SKU code" });
    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try Sku.nilo_explain("abc", &w);
    try testing.expectEqualStrings("has to be a SKU code", w.buffered());

    w = std.Io.Writer.fixed(&buf);
    try Email.nilo_explain("wati-at-example.com", &w);
    try testing.expectEqualStrings("has to look like an address, not \"wati-at-example.com\"", w.buffered());
}

test "what a 400 asks for reads as the shape" {
    try testing.expectEqualStrings("text of 10 to 72 characters", Text(.{ .min = 10, .max = 72 }).nilo_expects);
    try testing.expectEqualStrings("text of at least 1 characters", Text(.{ .min = 1 }).nilo_expects);
    try testing.expectEqualStrings("text of at most 30 characters", Text(.{ .max = 30 }).nilo_expects);
    try testing.expectEqualStrings("nilo.Text(.{ .min = 10, .max = 72 })", Text(.{ .min = 10, .max = 72 }).nilo_type_name);
    try testing.expectEqualStrings("nilo.Email", Email.nilo_type_name);
    try testing.expectEqualStrings("an email address", Email.nilo_expects);
}

test "Email takes what an address looks like and refuses what it does not" {
    for ([_][]const u8{ "wati@example.com", "a.b+c@sub.example.co.id", "x@y.z" }) |good| {
        try testing.expect(Email.nilo_parse(good) != null);
    }
    for ([_][]const u8{ "wati", "@example.com", "wati@", "wati@example", "wati@.com", "wati@example.", "wa ti@example.com", "a@b@c.com", "" }) |bad| {
        try testing.expect(Email.nilo_parse(bad) == null);
    }
}

test "Url wants a scheme and a host" {
    try testing.expect(Url.nilo_parse("https://example.com/path?q=1") != null);
    try testing.expect(Url.nilo_parse("http://localhost:8080") != null);
    try testing.expect(Url.nilo_parse("example.com") == null);
    try testing.expect(Url.nilo_parse("mailto:wati@example.com") == null);
    try testing.expect(Url.nilo_parse("") == null);
}

test "a default is checked while compiling and reads as its text" {
    const Nick = Text(.{ .max = 30 });
    const d = Nick.of("");
    try testing.expectEqualStrings("", d.view());
    try testing.expect(d.blank());
    try testing.expect(Nick.of("wati").eql("wati"));
    try testing.expectEqual(@as(usize, 4), Nick.of("wati").len());
}

test "the document reads the shape off the type" {
    const Password = Text(.{ .min = 10, .max = 72 });
    try testing.expectEqual(@as(?usize, 10), Password.nilo_text.min);
    try testing.expectEqual(@as(?usize, 72), Password.nilo_text.max);
    try testing.expect(Password.nilo_text.format == null);
    try testing.expectEqualStrings("email", Email.nilo_text.format.?);
    try testing.expectEqualStrings("string", Email.nilo_openapi.type);
}

test "a Text travels through JSON as the string it holds" {
    const Nick = Text(.{ .max = 30 });
    const Body = struct { nick: Nick };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const parsed = try std.json.parseFromSliceLeaky(Body, arena.allocator(), "{\"nick\":\"wa\\u0074i\"}", .{});
    try testing.expectEqualStrings("wati", parsed.nick.view());
    try testing.expectError(error.InvalidCharacter, std.json.parseFromSliceLeaky(Body, arena.allocator(), "{\"nick\":\"" ++ &@as([31]u8, @splat('x')) ++ "\"}", .{}));

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try std.json.Stringify.value(Body{ .nick = .of("wati") }, .{}, &out.writer);
    try testing.expectEqualStrings("{\"nick\":\"wati\"}", out.written());
}
