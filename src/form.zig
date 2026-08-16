//! HTML forms — `application/x-www-form-urlencoded` and
//! `multipart/form-data`, read into a struct of your own (ADR 0031).
//!
//! ```zig
//! const SignUp = struct {
//!     email: Str,
//!     password: Str,
//!     newsletter: bool = false,
//!     avatar: ?nilo.Upload = null,
//! };
//!
//! fn signUp(incoming: nilo.Form(SignUp)) !nilo.Redirect(303) {
//!     ... incoming.value.email ...
//!     return .to("/welcome");
//! }
//! ```
//!
//! **A form is the body, so a handler cannot ask for both.** `Form(T)` sits
//! where a plain struct argument would have read JSON, and the two are the
//! same slot; asking for both stops compilation.
//!
//! **The two encodings are one thing from here.** A browser sends
//! urlencoded until the form has a file in it and multipart afterwards, and
//! that is a fact about the browser rather than about the endpoint — so the
//! same `Form(T)` reads either, exactly as `c.body()` reads a chunked body
//! and a `Content-Length` one without saying which arrived.
//!
//! **The whole body is held in memory**, bounded by `listen()`'s `max_body`
//! (1 MB by default), because a form is read into a struct and a struct is
//! not something you can have half of. That is the same trade `c.json` makes
//! and the same ceiling. An upload too big for it is `c.bodyStream()`'s job,
//! where the handler drives the reading and nothing is held (ADR 0020).

const std = @import("std");

const convert = @import("convert.zig");
const ctx_mod = @import("ctx.zig");
const fail = @import("fail.zig");
const naming = @import("names.zig");
const router = @import("router.zig");
const str_mod = @import("str.zig");

const Str = str_mod.Str;

/// The declaration a `Form(T)` carries, so the compile-time engine can tell
/// it from a body and from a `Query(T)`.
pub const marker = "nilo_form";

/// A form body, read into a struct of your own — one field per form field.
///
/// The named counterpart to `Query(T)`, and the same rules: a field's type
/// says what its text has to become, a default is what "not filled in"
/// means, and `?T` is a field that may be absent. A field typed `Upload` is
/// a file, which only multipart can carry.
pub fn Form(comptime T: type) type {
    return struct {
        pub const nilo_form = T;

        value: T,
    };
}

/// One file out of a multipart form.
///
/// The three pieces are `Str`s, so they live exactly as long as the request
/// does and `keep` is what takes one out of it (ADR 0004) — including
/// `bytes`, which is doing lifetime duty rather than claiming the contents
/// are text.
///
/// **`filename` is what the client said, and a client can say anything.**
/// `../../etc/passwd` is a filename a browser will happily send. Store the
/// bytes under a name of your own and treat this as a label to show back to
/// somebody, never as a path.
pub const Upload = struct {
    /// What the browser called the file on the machine it came from.
    filename: Str,
    /// The type the client claimed. Also unverified — sniff the bytes if it
    /// matters.
    content_type: Str,
    /// The file itself.
    bytes: Str,

    /// How big the file is.
    pub fn len(self: Upload) usize {
        return self.bytes.len();
    }
};

/// How a form arrived.
pub const Kind = union(enum) {
    urlencoded,
    /// The boundary string, out of the content type's `boundary=` parameter.
    multipart: []const u8,
    /// Something that is not a form at all.
    other,
};

/// One file part, before it becomes an `Upload` — plain slices, because
/// nothing here has a request lifetime to stamp them with yet.
pub const Part = struct {
    name: []const u8,
    filename: []const u8,
    content_type: []const u8,
    bytes: []const u8,
};

/// A parsed form: its text fields and its files, each in the order it
/// arrived.
pub const Fields = struct {
    text: []const router.Param = &.{},
    files: []const Part = &.{},
    /// Whether this came in as multipart. Read only to explain, when an
    /// endpoint wanting a file was sent a form that cannot carry one.
    multipart: bool = false,

    /// The first field of this name, or null. First rather than last
    /// because a repeated name is a checkbox group, and taking the last
    /// would quietly answer with whichever the browser put at the end.
    pub fn find(self: Fields, name: []const u8) ?[]const u8 {
        for (self.text) |p| {
            if (std.mem.eql(u8, p.name, name)) return p.value;
        }
        return null;
    }

    pub fn file(self: Fields, name: []const u8) ?Part {
        for (self.files) |p| {
            if (std.mem.eql(u8, p.name, name)) return p;
        }
        return null;
    }
};

/// What a content type says the body is.
///
/// Only the media type is compared, so `application/x-www-form-urlencoded;
/// charset=utf-8` — which some clients send and the HTML spec does not — is
/// still a form.
pub fn kindOf(content_type: []const u8) Kind {
    const semicolon = std.mem.indexOfScalar(u8, content_type, ';') orelse content_type.len;
    const media = std.mem.trim(u8, content_type[0..semicolon], " \t");

    if (std.ascii.eqlIgnoreCase(media, "application/x-www-form-urlencoded")) return .urlencoded;
    if (!std.ascii.eqlIgnoreCase(media, "multipart/form-data")) return .other;

    // No boundary means no way to tell one part from the next, so this is
    // not a multipart body however it is labelled.
    const boundary = parameterOf(content_type[semicolon..], "boundary") orelse return .other;
    if (boundary.len == 0) return .other;
    return .{ .multipart = boundary };
}

/// Read a form body into `T`.
///
/// `lifetime` is the request's, so every `Str` this produces goes stale with
/// it exactly as one from the path or the query string does.
pub fn readInto(
    comptime T: type,
    arena: std.mem.Allocator,
    lifetime: *const str_mod.Lifetime,
    content_type: ?[]const u8,
    body: []const u8,
) !T {
    const fields = try parsedFor(T, arena, content_type, body);
    return fill(T, fields, lifetime);
}

/// Read a form body into `T`, recording why each field that would not bind
/// did not, rather than stopping at the first one.
///
/// The two things that can still end the request outright are the two above
/// `parsedFor`: a body that is not a form at all, and a form sent a way that
/// cannot carry the file this endpoint wants. Neither is a field's failure —
/// there is no binding to hand back and nothing to name — and the sentence
/// each already gets says more than a list of fields would (`bound.zig`).
pub fn readIntoCollecting(
    comptime T: type,
    arena: std.mem.Allocator,
    lifetime: *const str_mod.Lifetime,
    content_type: ?[]const u8,
    body: []const u8,
    outcomes: *[@typeInfo(T).@"struct".fields.len]convert.Outcome,
) !T {
    const fields = try parsedFor(T, arena, content_type, body);
    return fillCollecting(T, fields, lifetime, outcomes);
}

/// Everything that has to be true before a form body is worth taking apart,
/// and then taking it apart. Shared by both ways in, because what it refuses
/// is refused the same way whether or not the caller wanted its failures
/// back.
fn parsedFor(
    comptime T: type,
    arena: std.mem.Allocator,
    content_type: ?[]const u8,
    body: []const u8,
) !Fields {
    comptime checkFields(T, "the form struct " ++ naming.of(T));

    const kind = kindOf(content_type orelse "");
    if (kind == .other) {
        // The one message somebody sending the wrong thing needs, and the
        // one they get least often: what was sent, and what was wanted.
        if (content_type) |given| return fail.badRequest(
            "this endpoint takes a form, so the body has to be sent as " ++
                "application/x-www-form-urlencoded or multipart/form-data — this one arrived as \"{s}\"",
            .{given},
        );
        return fail.badRequest(
            "this endpoint takes a form, so the body has to be sent as " ++
                "application/x-www-form-urlencoded or multipart/form-data — " ++
                "this request said nothing about what its body is",
            .{},
        );
    }

    // Asked before parsing rather than after: a form with a file field that
    // arrived urlencoded is not a form missing a field, it is a form sent
    // the wrong way, and the difference is what somebody has to change.
    if (comptime holdsAFile(T)) {
        if (kind != .multipart) return fail.badRequest(
            "this endpoint takes a file, so the form has to be sent as multipart/form-data — " ++
                "this one arrived as application/x-www-form-urlencoded. In HTML that is " ++
                "<form enctype=\"multipart/form-data\">.",
            .{},
        );
    }

    return parse(arena, kind, body);
}

/// Take a form body apart, without yet knowing what struct it is going into.
pub fn parse(arena: std.mem.Allocator, kind: Kind, body: []const u8) !Fields {
    return switch (kind) {
        .urlencoded => .{ .text = try ctx_mod.parseQuery(arena, body) },
        .multipart => |boundary| try parseMultipart(arena, boundary, body),
        // Never reached from `readInto`, which refuses this above; here so
        // the switch is total for anyone calling `parse` directly.
        .other => .{},
    };
}

/// Fill `T` from an already-parsed form.
fn fill(comptime T: type, fields: Fields, lifetime: *const str_mod.Lifetime) !T {
    var out: T = undefined;
    inline for (@typeInfo(T).@"struct".fields) |f| {
        const label = "\"" ++ f.name ++ "\"";
        const Inner = switch (@typeInfo(f.type)) {
            .optional => |o| o.child,
            else => f.type,
        };

        if (Inner == Upload) {
            if (fields.file(f.name)) |part| {
                @field(out, f.name) = Upload{
                    .filename = Str.fromRequest(part.filename, lifetime),
                    .content_type = Str.fromRequest(part.content_type, lifetime),
                    .bytes = Str.fromRequest(part.bytes, lifetime),
                };
            } else if (f.defaultValue()) |default| {
                @field(out, f.name) = default;
            } else if (@typeInfo(f.type) == .optional) {
                @field(out, f.name) = null;
            } else {
                return fail.badRequest("the form is missing the file " ++ label, .{});
            }
        } else if (fields.find(f.name)) |raw| {
            @field(out, f.name) = try convert.convert(Inner, Str.fromRequest(raw, lifetime), label);
        } else if (f.defaultValue()) |default| {
            @field(out, f.name) = default;
        } else if (@typeInfo(f.type) == .optional) {
            @field(out, f.name) = null;
        } else {
            return fail.badRequest(
                "the form is missing " ++ label ++ " ({s})",
                .{comptime ctx_mod.expectedOf(f.type)},
            );
        }
    }
    return out;
}

/// Fill `T` from an already-parsed form, recording why each field that would
/// not bind did not, rather than stopping at the first one.
///
/// A field that did not bind is left as its default if it has one and
/// `undefined` if it does not. That is safe rather than sloppy: the only way
/// to this struct is `Bound.value()`, which hands back nothing at all while
/// any outcome still carries a reason. The text that arrived is kept either
/// way, which is what a form showing itself again needs.
fn fillCollecting(
    comptime T: type,
    fields: Fields,
    lifetime: *const str_mod.Lifetime,
    outcomes: *[@typeInfo(T).@"struct".fields.len]convert.Outcome,
) T {
    var out: T = undefined;
    inline for (@typeInfo(T).@"struct".fields, 0..) |f, i| {
        const Inner = switch (@typeInfo(f.type)) {
            .optional => |o| o.child,
            else => f.type,
        };
        outcomes[i] = .{};

        if (Inner == Upload) {
            if (fields.file(f.name)) |part| {
                @field(out, f.name) = Upload{
                    .filename = Str.fromRequest(part.filename, lifetime),
                    .content_type = Str.fromRequest(part.content_type, lifetime),
                    .bytes = Str.fromRequest(part.bytes, lifetime),
                };
            } else if (f.defaultValue()) |default| {
                @field(out, f.name) = default;
            } else if (@typeInfo(f.type) == .optional) {
                @field(out, f.name) = null;
            } else {
                outcomes[i].reason = .missing;
            }
        } else if (fields.find(f.name)) |raw| {
            const arrived = Str.fromRequest(raw, lifetime);
            // Kept before the conversion is tried, and kept whether or not
            // it works: the box a form puts back on the page holds what was
            // typed, not what it would have become.
            outcomes[i].given = arrived;

            var converted: Inner = undefined;
            if (convert.tryConvert(Inner, arrived, &converted)) |reason| {
                outcomes[i].reason = reason;
                if (f.defaultValue()) |default| @field(out, f.name) = default;
            } else {
                @field(out, f.name) = converted;
            }
        } else if (f.defaultValue()) |default| {
            @field(out, f.name) = default;
        } else if (@typeInfo(f.type) == .optional) {
            @field(out, f.name) = null;
        } else {
            outcomes[i].reason = .missing;
        }
    }
    return out;
}

/// Everything that can be wrong with the struct a form is read into.
///
/// `what` names the thing being complained about — the typed engine passes
/// the `Form(T)` and the route it is on, `c.form(T)` passes the type alone —
/// so one message serves both ways in without either of them guessing at the
/// other's context (ADR 0027).
pub fn checkFields(comptime T: type, comptime what: []const u8) void {
    comptime {
        const info = switch (@typeInfo(T)) {
            .@"struct" => |s| s,
            else => @compileError(
                "nilo: " ++ what ++ " is not a struct.\n" ++
                    "  A form is read into a struct: one field per form field.",
            ),
        };

        if (info.fields.len == 0) @compileError(
            "nilo: " ++ what ++ " has no fields, so it would read nothing.\n" ++
                "  Add one field per form field you want: `email: nilo.Str`.",
        );

        for (info.fields) |f| {
            const Inner = switch (@typeInfo(f.type)) {
                .optional => |o| o.child,
                else => f.type,
            };
            if (Inner == Upload) continue;
            if (convert.convertible(f.type)) continue;
            @compileError(
                "nilo: the field `" ++ f.name ++ ": " ++ naming.of(f.type) ++ "` of " ++ what ++
                    " is not something a form value can become.\n" ++
                    "  A form field arrives as text, so a field is a `nilo.Str`, a number, a " ++
                    "`bool`, or an enum — or a `nilo.Upload` for a file — optionally wrapped in " ++
                    "`?` when it may be absent.",
            );
        }
    }
}

/// Whether any field of `T` is a file, and so whether this endpoint can be
/// served by a urlencoded form at all.
pub fn holdsAFile(comptime T: type) bool {
    comptime {
        for (@typeInfo(T).@"struct".fields) |f| {
            const Inner = switch (@typeInfo(f.type)) {
                .optional => |o| o.child,
                else => f.type,
            };
            if (Inner == Upload) return true;
        }
        return false;
    }
}

// ---- multipart ----
//
// ```
// --BOUNDARY\r\n
// Content-Disposition: form-data; name="email"\r\n
// \r\n
// wati@example.dev\r\n
// --BOUNDARY\r\n
// Content-Disposition: form-data; name="avatar"; filename="me.png"\r\n
// Content-Type: image/png\r\n
// \r\n
// <the bytes>\r\n
// --BOUNDARY--\r\n
// ```
//
// Nothing here copies a byte. Every name, filename and file is a slice of
// the body already sitting in the request arena, which is what makes a 900 KB
// upload cost the one allocation `c.body()` made and not a second one.

/// The most parts one form may hold.
///
/// A bound rather than a budget: the arrays below are sized from a count of
/// boundaries in the body, and a body is already bounded by `max_body`. What
/// this stops is a megabyte of nothing but boundaries — ~15,000 of them in
/// the default 1 MB — turning into two arrays of 15,000 structs, which is
/// half a megabyte of arena for a request carrying no data at all.
pub const max_parts = 256;

fn parseMultipart(arena: std.mem.Allocator, boundary: []const u8, body: []const u8) !Fields {
    // `--boundary` at the start of the body, and `\r\n--boundary` everywhere
    // after it. Built once, in the arena, rather than compared piece by
    // piece at every position.
    const dashed = try std.mem.concat(arena, u8, &.{ "--", boundary });

    var i = if (std.mem.startsWith(u8, body, dashed))
        dashed.len
    else
        (indexOfBoundary(body, 0, dashed) orelse return fail.badRequest(
            "this form says it is multipart, but its body does not begin with the boundary " ++
                "the Content-Type named",
            .{},
        )) + dashed.len;

    // One pass to size the arrays, so the parts cost one allocation each
    // rather than a doubling per part. Both are sized for the worst case —
    // every part a file, or none — because which it is is not known until
    // the parts are read, and the arena is emptied when the request ends.
    const room = @min(countBoundaries(body, dashed) + 1, max_parts);
    const text = try arena.alloc(router.Param, room);
    const files = try arena.alloc(Part, room);
    var n_text: usize = 0;
    var n_files: usize = 0;

    while (true) {
        // `--boundary--` is the end of the form. Anything after it is an
        // epilogue nobody reads.
        if (i + 2 <= body.len and body[i] == '-' and body[i + 1] == '-') break;

        // The rest of the boundary line: transport padding, then a newline.
        const line_end = std.mem.indexOfScalarPos(u8, body, i, '\n') orelse break;
        const part_start = line_end + 1;

        const head_end = endOfPartHead(body, part_start) orelse return fail.badRequest(
            "a part of this multipart form has no blank line between its headers and its contents",
            .{},
        );
        const data_start = head_end.data_start;

        const at = indexOfBoundary(body, data_start, dashed) orelse return fail.badRequest(
            "a part of this multipart form is not closed by the boundary the Content-Type named",
            .{},
        );
        // The line break in front of the boundary belongs to the framing and
        // not to the file. A byte too many or too few here corrupts every
        // upload that goes through, silently — `indexOfBoundary` guarantees
        // the `\n`, and the `\r` before it is there whenever the sender used
        // CRLF, which every browser does.
        var data_end = at;
        if (data_end > data_start) data_end -= 1;
        if (data_end > data_start and body[data_end - 1] == '\r') data_end -= 1;

        const head = body[part_start..head_end.head_end];
        const data = body[data_start..data_end];
        i = at + dashed.len;

        const disposition = headerIn(head, "content-disposition") orelse continue;
        const name = parameterOf(disposition, "name") orelse continue;

        // A part with a filename is a file even when the file is empty:
        // that is a browser saying "the field was there and nothing was
        // chosen", and it must not become a text field called `avatar`.
        if (parameterOf(disposition, "filename")) |filename| {
            if (n_files == files.len) continue;
            files[n_files] = .{
                .name = name,
                .filename = filename,
                .content_type = headerIn(head, "content-type") orelse "application/octet-stream",
                .bytes = data,
            };
            n_files += 1;
        } else {
            if (n_text == text.len) continue;
            text[n_text] = .{ .name = name, .value = data };
            n_text += 1;
        }
    }

    return .{
        .text = text[0..n_text],
        .files = files[0..n_files],
        .multipart = true,
    };
}

/// Where the next boundary is, counting from `from` — matched only at the
/// start of a line, so a boundary string that also occurs inside a file does
/// not end the part it is in. The index returned is of the newline's
/// position + 1, i.e. of the first `-`.
fn indexOfBoundary(body: []const u8, from: usize, dashed: []const u8) ?usize {
    var at = from;
    while (std.mem.indexOfPos(u8, body, at, dashed)) |found| {
        if (found > 0 and body[found - 1] == '\n') return found;
        at = found + 1;
    }
    return null;
}

fn countBoundaries(body: []const u8, dashed: []const u8) usize {
    var n: usize = 0;
    var at: usize = 0;
    while (indexOfBoundary(body, at, dashed)) |found| : (n += 1) {
        at = found + dashed.len;
    }
    return n;
}

const PartHead = struct { head_end: usize, data_start: usize };

/// The blank line between a part's headers and its contents. CRLF is what a
/// browser sends; a bare LF is accepted for the same reason the request head
/// parser accepts one — a handwritten test fixture should not be a 400.
fn endOfPartHead(body: []const u8, from: usize) ?PartHead {
    if (std.mem.indexOfPos(u8, body, from, "\r\n\r\n")) |at| {
        // A bare-LF blank line could still come first, so whichever is
        // nearer wins.
        if (std.mem.indexOfPos(u8, body, from, "\n\n")) |bare| {
            if (bare < at) return .{ .head_end = bare, .data_start = bare + 2 };
        }
        return .{ .head_end = at, .data_start = at + 4 };
    }
    if (std.mem.indexOfPos(u8, body, from, "\n\n")) |bare| {
        return .{ .head_end = bare, .data_start = bare + 2 };
    }
    return null;
}

/// The value of one header inside a part's own little head. `name` is given
/// in lower case; the comparison is case-insensitive either way.
fn headerIn(head: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, head, '\n');
    while (lines.next()) |raw| {
        const line = if (raw.len > 0 and raw[raw.len - 1] == '\r') raw[0 .. raw.len - 1] else raw;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), name)) {
            return std.mem.trim(u8, line[colon + 1 ..], " \t");
        }
    }
    return null;
}

/// One `; key=value` parameter out of a header value — `boundary` out of a
/// content type, `name` and `filename` out of a content disposition.
///
/// A quoted value is handed back without its quotes and otherwise untouched.
/// RFC 6266's `filename*=UTF-8''…` is not read: it is the encoding a browser
/// falls back to for a name that is not Latin-1, and reading half of that
/// convention would be worse than reading none — the plain `filename` is
/// always sent alongside it.
fn parameterOf(header_value: []const u8, key: []const u8) ?[]const u8 {
    var rest = header_value;
    while (std.mem.indexOfScalar(u8, rest, '=')) |equals| {
        const name = std.mem.trim(u8, beforeParameter(rest[0..equals]), " \t");
        var value = rest[equals + 1 ..];

        if (value.len > 0 and value[0] == '"') {
            const close = std.mem.indexOfScalarPos(u8, value, 1, '"') orelse return null;
            if (std.ascii.eqlIgnoreCase(name, key)) return value[1..close];
            rest = value[close + 1 ..];
            continue;
        }

        const end = std.mem.indexOfScalar(u8, value, ';') orelse value.len;
        if (std.ascii.eqlIgnoreCase(name, key)) return std.mem.trim(u8, value[0..end], " \t");
        if (end == value.len) return null;
        rest = value[end + 1 ..];
    }
    return null;
}

/// The last `;`-separated run of `text`, which is the name of the parameter
/// whose `=` was just found.
fn beforeParameter(text: []const u8) []const u8 {
    const at = std.mem.lastIndexOfScalar(u8, text, ';') orelse return text;
    return text[at + 1 ..];
}

// ---- tests ----

const testing = std.testing;

test "a content type says which kind of form it is, or that it is not one" {
    try testing.expectEqual(Kind.urlencoded, kindOf("application/x-www-form-urlencoded"));
    try testing.expectEqual(Kind.urlencoded, kindOf("application/x-www-form-urlencoded; charset=utf-8"));
    try testing.expectEqual(Kind.urlencoded, kindOf("APPLICATION/X-WWW-FORM-URLENCODED"));
    try testing.expectEqual(Kind.other, kindOf("application/json"));
    try testing.expectEqual(Kind.other, kindOf(""));

    switch (kindOf("multipart/form-data; boundary=abc123")) {
        .multipart => |b| try testing.expectEqualStrings("abc123", b),
        else => return error.TestUnexpectedResult,
    }
    switch (kindOf("multipart/form-data; boundary=\"a b c\"")) {
        .multipart => |b| try testing.expectEqualStrings("a b c", b),
        else => return error.TestUnexpectedResult,
    }
    // Multipart with nothing to split the parts on is not a multipart body.
    try testing.expectEqual(Kind.other, kindOf("multipart/form-data"));
}

const SignUp = struct {
    email: Str,
    password: Str,
    newsletter: bool = false,
    referrer: ?Str = null,
};

/// One lifetime for the tests below, at file scope rather than inside the
/// helper. A `Lifetime` on `read`'s own stack dies when `read` returns and
/// every `Str` it stamped goes stale on the next line — which is the staleness
/// trap working exactly as ADR 0004 intends, and not what these tests are
/// about.
var test_lifetime: str_mod.Lifetime = .{};

fn read(comptime T: type, arena: std.mem.Allocator, content_type: []const u8, body: []const u8) !T {
    return readInto(T, arena, &test_lifetime, content_type, body);
}

test "a urlencoded form fills a struct, defaults and all" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const filled = try read(
        SignUp,
        arena.allocator(),
        "application/x-www-form-urlencoded",
        "email=wati%40example.dev&password=hunter2&newsletter=true",
    );
    try testing.expectEqualStrings("wati@example.dev", filled.email.view());
    try testing.expectEqualStrings("hunter2", filled.password.view());
    try testing.expectEqual(true, filled.newsletter);
    try testing.expect(filled.referrer == null);
}

test "a urlencoded form reads a plus as a space, the way a browser writes one" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const Note = struct { text: Str };
    const filled = try read(Note, arena.allocator(), "application/x-www-form-urlencoded", "text=hello+there");
    try testing.expectEqualStrings("hello there", filled.text.view());
}

fn expectFails(comptime T: type, arena: std.mem.Allocator, content_type: []const u8, body: []const u8, says: []const u8) !void {
    const bulkhead = @import("bulkhead.zig");
    var in_flight = fail.InFlight{};
    in_flight.startRequest("POST", "/form");
    const previous = bulkhead.setFallbackSlot(&in_flight);
    defer _ = bulkhead.setFallbackSlot(previous);

    try testing.expectError(error.Failed, read(T, arena, content_type, body));
    try testing.expectEqualStrings(says, in_flight.failure.message());
}

test "a missing field says which one, and what it would have been" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try expectFails(
        SignUp,
        arena.allocator(),
        "application/x-www-form-urlencoded",
        "email=wati%40example.dev",
        "the form is missing \"password\" (text)",
    );
}

test "a field that does not fit its type is named, exactly as a query param is" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const Ages = struct { age: u32 };
    try expectFails(
        Ages,
        arena.allocator(),
        "application/x-www-form-urlencoded",
        "age=soon",
        "\"age\" has to be a whole number, not \"soon\"",
    );
}

test "a body that is not a form at all says what it was" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try expectFails(
        SignUp,
        arena.allocator(),
        "application/json",
        "{}",
        "this endpoint takes a form, so the body has to be sent as " ++
            "application/x-www-form-urlencoded or multipart/form-data — this one arrived as \"application/json\"",
    );
}

/// A multipart body written the way a browser writes one, so the tests are
/// arguing with the real framing rather than with a tidied version of it.
fn multipart(comptime parts: []const []const u8) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (parts) |part| out = out ++ "--niloBoundary\r\n" ++ part ++ "\r\n";
        return out ++ "--niloBoundary--\r\n";
    }
}

const multipart_type = "multipart/form-data; boundary=niloBoundary";

test "a multipart form fills the same struct a urlencoded one does" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const filled = try read(SignUp, arena.allocator(), multipart_type, comptime multipart(&.{
        "Content-Disposition: form-data; name=\"email\"\r\n\r\nwati@example.dev",
        "Content-Disposition: form-data; name=\"password\"\r\n\r\nhunter2",
        "Content-Disposition: form-data; name=\"newsletter\"\r\n\r\ntrue",
    }));
    try testing.expectEqualStrings("wati@example.dev", filled.email.view());
    try testing.expectEqualStrings("hunter2", filled.password.view());
    try testing.expectEqual(true, filled.newsletter);
}

const WithAvatar = struct {
    email: Str,
    avatar: Upload,
};

test "a file part arrives with its bytes, its name and the type it claimed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const filled = try read(WithAvatar, arena.allocator(), multipart_type, comptime multipart(&.{
        "Content-Disposition: form-data; name=\"email\"\r\n\r\nwati@example.dev",
        "Content-Disposition: form-data; name=\"avatar\"; filename=\"me.png\"\r\n" ++
            "Content-Type: image/png\r\n\r\n\x89PNG\r\n\x1a\n binary bits",
    }));

    try testing.expectEqualStrings("wati@example.dev", filled.email.view());
    try testing.expectEqualStrings("me.png", filled.avatar.filename.view());
    try testing.expectEqualStrings("image/png", filled.avatar.content_type.view());
    // Including the CRLF inside the file, which the framing must not have
    // mistaken for the end of the part.
    try testing.expectEqualStrings("\x89PNG\r\n\x1a\n binary bits", filled.avatar.bytes.view());
    try testing.expectEqual(@as(usize, 20), filled.avatar.len());
}

test "the bytes of a file are the body's own, not a copy of them" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const body = comptime multipart(&.{
        "Content-Disposition: form-data; name=\"email\"\r\n\r\nx@y.z",
        "Content-Disposition: form-data; name=\"avatar\"; filename=\"a.bin\"\r\n\r\nABCDEF",
    });
    const filled = try read(WithAvatar, arena.allocator(), multipart_type, body);
    // The whole point of the parser: a 900 KB upload is not memcpy'd out of
    // the body it already sits in.
    try testing.expectEqual(
        @intFromPtr(body.ptr) + std.mem.indexOf(u8, body, "ABCDEF").?,
        @intFromPtr(filled.avatar.bytes.view().ptr),
    );
}

test "a file field left empty by the browser is still a file, not a text field" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const filled = try read(WithAvatar, arena.allocator(), multipart_type, comptime multipart(&.{
        "Content-Disposition: form-data; name=\"email\"\r\n\r\nx@y.z",
        "Content-Disposition: form-data; name=\"avatar\"; filename=\"\"\r\n" ++
            "Content-Type: application/octet-stream\r\n\r\n",
    }));
    try testing.expectEqualStrings("", filled.avatar.filename.view());
    try testing.expectEqual(@as(usize, 0), filled.avatar.len());
}

test "a part with no content type of its own gets the one the spec says to assume" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const Only = struct { f: Upload };
    const filled = try read(Only, arena.allocator(), multipart_type, comptime multipart(&.{
        "Content-Disposition: form-data; name=\"f\"; filename=\"a.txt\"\r\n\r\nhi",
    }));
    try testing.expectEqualStrings("application/octet-stream", filled.f.content_type.view());
    try testing.expectEqualStrings("hi", filled.f.bytes.view());
}

test "an optional file that was not sent is null" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const Maybe = struct { email: Str, avatar: ?Upload = null };
    const filled = try read(Maybe, arena.allocator(), multipart_type, comptime multipart(&.{
        "Content-Disposition: form-data; name=\"email\"\r\n\r\nx@y.z",
    }));
    try testing.expect(filled.avatar == null);
}

test "an endpoint wanting a file, sent a form that cannot carry one, says so" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try expectFails(
        WithAvatar,
        arena.allocator(),
        "application/x-www-form-urlencoded",
        "email=x%40y.z&avatar=oops",
        "this endpoint takes a file, so the form has to be sent as multipart/form-data — " ++
            "this one arrived as application/x-www-form-urlencoded. In HTML that is " ++
            "<form enctype=\"multipart/form-data\">.",
    );
}

test "a multipart body that does not start with its boundary is refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try expectFails(
        SignUp,
        arena.allocator(),
        multipart_type,
        "there is no boundary anywhere in here",
        "this form says it is multipart, but its body does not begin with the boundary " ++
            "the Content-Type named",
    );
}

test "a part that never closes is refused rather than read to the end of the body" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try expectFails(
        SignUp,
        arena.allocator(),
        multipart_type,
        "--niloBoundary\r\nContent-Disposition: form-data; name=\"email\"\r\n\r\nwati",
        "a part of this multipart form is not closed by the boundary the Content-Type named",
    );
}

test "a boundary string occurring inside a file does not end the part" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Not at the start of a line, so it is data — which is exactly the case
    // a naive `indexOf` gets wrong and truncates the upload at.
    const Only = struct { f: Upload };
    const filled = try read(Only, arena.allocator(), multipart_type, comptime multipart(&.{
        "Content-Disposition: form-data; name=\"f\"; filename=\"a.txt\"\r\n\r\n" ++
            "before --niloBoundary after",
    }));
    try testing.expectEqualStrings("before --niloBoundary after", filled.f.bytes.view());
}

test "a part with no name is stepped over, and the rest of the form still reads" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const Only = struct { email: Str };
    const filled = try read(Only, arena.allocator(), multipart_type, comptime multipart(&.{
        "Content-Type: text/plain\r\n\r\norphan",
        "Content-Disposition: form-data; name=\"email\"\r\n\r\nx@y.z",
    }));
    try testing.expectEqualStrings("x@y.z", filled.email.view());
}

test "an unquoted parameter is read too, and one parameter does not eat the next" {
    try testing.expectEqualStrings("abc", parameterOf("form-data; name=abc", "name").?);
    try testing.expectEqualStrings("abc", parameterOf("form-data; name=abc; filename=x.txt", "name").?);
    try testing.expectEqualStrings("x.txt", parameterOf("form-data; name=abc; filename=x.txt", "filename").?);
    // A filename with a semicolon in it, which is why quoting exists.
    try testing.expectEqualStrings("a;b.txt", parameterOf("form-data; name=\"f\"; filename=\"a;b.txt\"", "filename").?);
    try testing.expect(parameterOf("form-data; name=abc", "filename") == null);
    // `name` inside another parameter's value must not answer for it.
    try testing.expectEqualStrings("real", parameterOf("form-data; filename=\"name=fake\"; name=real", "name").?);
}

test "the number of parts one form may hold is bounded" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // A body made of nothing but boundaries: the arrays are sized from the
    // count, and this is what stops that count being the client's to choose.
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(testing.allocator);
    for (0..max_parts * 2) |i| {
        try body.print(
            testing.allocator,
            "--niloBoundary\r\nContent-Disposition: form-data; name=\"f{d}\"\r\n\r\nv\r\n",
            .{i},
        );
    }
    try body.appendSlice(testing.allocator, "--niloBoundary--\r\n");

    const fields = try parse(arena.allocator(), kindOf(multipart_type), body.items);
    try testing.expectEqual(@as(usize, max_parts), fields.text.len);
    // The ones that did fit are the ones that arrived first.
    try testing.expectEqualStrings("f0", fields.text[0].name);
}
