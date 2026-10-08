//! HTML forms — `application/x-www-form-urlencoded` and
//! `multipart/form-data`, read into a struct of your own (ADR 030).
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
//! where the handler drives the reading and nothing is held (ADR 019).

const std = @import("std");

const convert = @import("convert.zig");
const field_mod = @import("field.zig");
const ctx_mod = @import("ctx.zig");
const bulkhead = @import("bulkhead.zig");
const fail = @import("fail.zig");
const filebody = @import("filebody.zig");
const naming = @import("names.zig");
const router = @import("router.zig");
const str_mod = @import("nilo_core");

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
        /// What a nilo compile error calls this type, which is the name the
        /// reader's own import line gives it (ADR 074).
        pub const nilo_type_name = "nilo.Form(" ++ naming.of(T) ++ ")";

        value: T,
    };
}

/// One file out of a multipart form.
///
/// The three pieces are `Str`s, so they live exactly as long as the request
/// does and `keep` is what takes one out of it (ADR 003) — including
/// `bytes`, which is doing lifetime duty rather than claiming the contents
/// are text.
///
/// **`filename` is what the client said, and a client can say anything.**
/// `../../etc/passwd` is a filename a browser will happily send. Store the
/// bytes under a name of your own and treat this as a label to show back to
/// somebody, never as a path.
pub const Upload = struct {
    /// What a nilo compile error calls this type, which is the name the
    /// reader's own import line gives it (ADR 074).
    pub const nilo_type_name = "nilo.Upload";

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

    /// Write the file into `dir` under `name`, replacing whatever was there.
    ///
    /// ```zig
    /// fn setAvatar(uploads: *Uploads, account: u32, incoming: nilo.Form(Avatar)) !nilo.Status(201, void) {
    ///     var buf: [32]u8 = undefined;
    ///     const name = try std.fmt.bufPrint(&buf, "{d}.png", .{account});
    ///     try incoming.value.image.saveTo(uploads.dir, name);
    ///     return .{};
    /// }
    /// ```
    ///
    /// The `Dir` is a service opened once at startup, the same one a
    /// `FileBody` is handed to serve out of.
    ///
    /// **`name` is yours to choose and `filename` is the client's.** Handing
    /// `filename` straight in is `error.NameNotAllowed`, not a path resolved
    /// against the directory
    /// ([ADR 097](../docs/adr/097-a-file-is-written-by-the-engine.md)).
    ///
    /// **The file is replaced, or it is not touched.** A temporary name beside
    /// it and one rename, so a request serving that same name reads the old
    /// file or the new one and never a half-written one.
    ///
    /// The fiber parks for the write and its thread goes on serving. Nothing
    /// is buffered — one write of `len()` bytes, and no buffer on a stack the
    /// connection would then hold (ADR 062).
    pub fn saveTo(self: Upload, dir: bulkhead.Dir, name: []const u8) !void {
        if (filebody.checkName(name) != null) return error.NameNotAllowed;
        try dir.writeFileAtomic(name, self.bytes.view());
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
    /// would quietly answer with whichever the browser put at the end. A
    /// field declared as a list reads every occurrence instead
    /// ([ADR 132](../docs/adr/132-a-query-parameter-or-a-form-field-that-is-a-list.md)).
    pub fn find(self: Fields, name: []const u8) ?[]const u8 {
        for (self.text) |p| {
            if (std.mem.eql(u8, p.name, name)) return p.value;
        }
        return null;
    }

    /// How many non-empty values arrived under `name`: the size of the
    /// list a field of that name becomes. An empty value is what an
    /// unticked box never sends and an empty text box does, and it
    /// contributes nothing, the rule ADR 132 set for a query.
    pub fn count(self: Fields, name: []const u8) usize {
        var n: usize = 0;
        for (self.text) |p| {
            if (std.mem.eql(u8, p.name, name) and p.value.len > 0) n += 1;
        }
        return n;
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
    return fill(T, arena, fields, lifetime);
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
    outcomes: *[@typeInfo(T).@"struct".field_names.len]convert.Outcome,
) !T {
    const fields = try parsedFor(T, arena, content_type, body);
    return fillCollecting(T, arena, fields, lifetime, outcomes);
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

/// The most pairs one urlencoded form may hold, and the urlencoded half of
/// what `max_parts` is to multipart (ADR 034).
///
/// `parseQuery` sizes its array from a count of `&` before it reads a byte, so
/// the arena a form costs was the client's to choose: a megabyte of `&` is a
/// million empty pairs and 33 MB of `Param`, thirty times the body. 1,024 is
/// 32 KiB of arena at most, and past anything a browser sends: a page of a
/// thousand checkboxes is one pair each.
pub const max_pairs = 1024;

/// Said out loud rather than cut short, for `tooManyParts`' reason: the
/// fields past the wall would look exactly like fields never sent.
fn tooManyPairs() fail.Error {
    return fail.badRequest(
        "this form has more pairs than nilo reads from one, which is {d}",
        .{max_pairs},
    );
}

/// Take a form body apart, without yet knowing what struct it is going into.
pub fn parse(arena: std.mem.Allocator, kind: Kind, body: []const u8) !Fields {
    return switch (kind) {
        .urlencoded => blk: {
            // Counted before `parseQuery` allocates for it, which is the
            // whole point: it sizes its array from this same count.
            if (std.mem.count(u8, body, "&") >= max_pairs) return tooManyPairs();
            break :blk .{ .text = try ctx_mod.parseQuery(arena, body) };
        },
        .multipart => |boundary| try parseMultipart(arena, boundary, body),
        // Never reached from `readInto`, which refuses this above; here so
        // the switch is total for anyone calling `parse` directly.
        .other => .{},
    };
}

/// Fill `T` from an already-parsed form.
fn fill(comptime T: type, arena: std.mem.Allocator, fields: Fields, lifetime: *const str_mod.Lifetime) !T {
    const info = @typeInfo(T).@"struct";
    comptime @setEvalBranchQuota(convert.budget(info.field_names));
    var out: T = undefined;
    inline for (info.field_names, info.field_types, info.field_attrs) |f_name, f_type, f_attrs| {
        const label = "\"" ++ f_name ++ "\"";
        const rule = field_mod.FieldRule(f_type, f_attrs);
        const Inner = rule.Inner;

        if (comptime convert.listElement(f_type)) |Item| {
            // A list is never missing: a checkbox group with nothing ticked
            // sends nothing, and that is the empty list (ADR 132).
            @field(out, f_name) = try collectList(Item, arena, fields, f_name, lifetime, label);
        } else if (Inner == Upload) {
            if (fields.file(f_name)) |part| {
                @field(out, f_name) = Upload{
                    .filename = Str.fromRequest(part.filename, lifetime),
                    .content_type = Str.fromRequest(part.content_type, lifetime),
                    .bytes = Str.fromRequest(part.bytes, lifetime),
                };
            } else if (comptime rule.may_be_absent) {
                @field(out, f_name) = comptime rule.absent();
            } else {
                return fail.badRequest("the form is missing the file " ++ label, .{});
            }
        } else if (fields.find(f_name)) |raw| {
            const arrived = Str.fromRequest(raw, lifetime);
            if ((comptime rule.may_be_absent) and convert.emptyIsAbsent(Inner, .form, arrived)) {
                @field(out, f_name) = comptime rule.absent();
            } else {
                @field(out, f_name) = try convert.convert(Inner, .form, arrived, label);
            }
        } else if (comptime rule.may_be_absent) {
            @field(out, f_name) = comptime rule.absent();
        } else {
            return fail.badRequest(
                "the form is missing " ++ label ++ " ({s})",
                .{comptime ctx_mod.expectedOf(f_type)},
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
    arena: std.mem.Allocator,
    fields: Fields,
    lifetime: *const str_mod.Lifetime,
    outcomes: *[@typeInfo(T).@"struct".field_names.len]convert.Outcome,
) T {
    const info = @typeInfo(T).@"struct";
    comptime @setEvalBranchQuota(convert.budget(info.field_names));
    var out: T = undefined;
    inline for (info.field_names, info.field_types, info.field_attrs, 0..) |f_name, f_type, f_attrs, i| {
        const rule = field_mod.FieldRule(f_type, f_attrs);
        const Inner = rule.Inner;
        outcomes[i] = .{};

        if (comptime convert.listElement(f_type)) |Item| {
            @field(out, f_name) = collectListCollecting(Item, arena, fields, f_name, lifetime, &outcomes[i]) catch &.{};
        } else if (Inner == Upload) {
            if (fields.file(f_name)) |part| {
                @field(out, f_name) = Upload{
                    .filename = Str.fromRequest(part.filename, lifetime),
                    .content_type = Str.fromRequest(part.content_type, lifetime),
                    .bytes = Str.fromRequest(part.bytes, lifetime),
                };
            } else if (comptime rule.may_be_absent) {
                @field(out, f_name) = comptime rule.absent();
            } else {
                outcomes[i].reason = .missing;
            }
        } else if (fields.find(f_name)) |raw| {
            const arrived = Str.fromRequest(raw, lifetime);
            // Kept before the conversion is tried, and kept whether or not
            // it works: the box a form puts back on the page holds what was
            // typed, not what it would have become.
            outcomes[i].given = arrived;

            var converted: Inner = undefined;
            if ((comptime rule.may_be_absent) and convert.emptyIsAbsent(Inner, .form, arrived)) {
                @field(out, f_name) = comptime rule.absent();
            } else if (convert.tryConvert(Inner, .form, arrived, &converted)) |reason| {
                outcomes[i].reason = reason;
                if (f_attrs.defaultValue(f_type)) |default| @field(out, f_name) = default;
            } else {
                @field(out, f_name) = converted;
            }
        } else if (comptime rule.may_be_absent) {
            @field(out, f_name) = comptime rule.absent();
        } else {
            outcomes[i].reason = .missing;
        }
    }
    return out;
}

/// Every value that arrived under a repeated name, converted
/// ([ADR 132](../docs/adr/132-a-query-parameter-or-a-form-field-that-is-a-list.md)).
///
/// **A repeated name and nothing else.** A browser sends a `<select
/// multiple>` and a checkbox group as the same name once per value and
/// never comma-joined, so there is no second spelling to read: a comma in
/// a form value is a value with a comma in it. That is where this stops
/// being the query case one slot over (ADR 132), whose comma is a
/// contract written into the document for a client to send back.
///
/// **One allocation, for a form that asked for a list and no other.** The
/// elements point into the parsed body, which lives as long as the request;
/// what is allocated is the slice of them, sized by `count`, out of the
/// request arena (ADR 017). An empty value contributes nothing, so a row of
/// empty text boxes is an empty list rather than a list of empty strings.
fn collectList(
    comptime Item: type,
    arena: std.mem.Allocator,
    fields: Fields,
    comptime name: []const u8,
    lifetime: *const str_mod.Lifetime,
    comptime label: []const u8,
) ![]const Item {
    const n = fields.count(name);
    if (n == 0) return &.{};

    const out = arena.alloc(Item, n) catch
        return fail.internal("no room for the values of {s}", .{label});

    var at: usize = 0;
    for (fields.text) |p| {
        if (!std.mem.eql(u8, p.name, name) or p.value.len == 0) continue;
        out[at] = try convert.convert(Item, .form, Str.fromRequest(p.value, lifetime), label);
        at += 1;
    }
    return out[0..at];
}

/// `collectList`, recording what would not convert instead of answering
/// with it. The **first** bad value is the one the handler is told about,
/// and the rest of the list is still read, the rule ADR 132 set: a group
/// with one bad box in it is a group, not a form with nothing in it.
fn collectListCollecting(
    comptime Item: type,
    arena: std.mem.Allocator,
    fields: Fields,
    comptime name: []const u8,
    lifetime: *const str_mod.Lifetime,
    outcome: *convert.Outcome,
) ![]const Item {
    const n = fields.count(name);
    if (n == 0) return &.{};

    const out = try arena.alloc(Item, n);
    var at: usize = 0;
    for (fields.text) |p| {
        if (!std.mem.eql(u8, p.name, name) or p.value.len == 0) continue;
        const text = Str.fromRequest(p.value, lifetime);
        var converted: Item = undefined;
        if (convert.tryConvert(Item, .form, text, &converted)) |reason| {
            if (outcome.reason == null) {
                outcome.given = text;
                outcome.reason = reason;
            }
        } else {
            out[at] = converted;
            at += 1;
        }
    }
    return out[0..at];
}

/// Everything that can be wrong with the struct a form is read into.
///
/// `what` names the thing being complained about — the typed engine passes
/// the `Form(T)` and the route it is on, `c.form(T)` passes the type alone —
/// so one message serves both ways in without either of them guessing at the
/// other's context (ADR 026).
pub fn checkFields(comptime T: type, comptime what: []const u8) void {
    comptime {
        const info = switch (@typeInfo(T)) {
            .@"struct" => |s| s,
            else => @compileError(
                "nilo: " ++ what ++ " is not a struct.\n" ++
                    "  A form is read into a struct: one field per form field.",
            ),
        };

        if (info.field_names.len == 0) @compileError(
            "nilo: " ++ what ++ " has no fields, so it would read nothing.\n" ++
                "  Add one field per form field you want: `email: nilo.Str`.",
        );

        for (info.field_names, info.field_types) |f_name, f_type| {
            const Inner = switch (@typeInfo(f_type)) {
                .optional => |o| o.child,
                else => f_type,
            };
            if (Inner == Upload) continue;
            if (convert.convertible(f_type)) continue;
            // A list of anything a form value can become, filled from the
            // repeated name a checkbox group or a `<select multiple>` sends
            // (ADR 132). A list of files is not one: `Upload` is a part
            // rather than a value, and a field takes one.
            if (convert.listElement(f_type)) |Item| {
                if (Item != Upload and convert.convertible(Item) and @typeInfo(Item) != .optional) continue;
                @compileError(
                    "nilo: the field `" ++ f_name ++ ": " ++ naming.of(f_type) ++ "` of " ++ what ++
                        " is a list of something a form value cannot become.\n" ++
                        "  A list field takes every value sent under its name, and each is a " ++
                        "`nilo.Str`, a number, a `bool`, an enum, or a type that parses itself " ++
                        "with `nilo_parse` — not a file, and not an optional.",
                );
            }
            @compileError(
                "nilo: the field `" ++ f_name ++ ": " ++ naming.of(f_type) ++ "` of " ++ what ++
                    " is not something a form value can become.\n" ++
                    "  A form field arrives as text, so a field is a `nilo.Str`, a number, a " ++
                    "`bool`, an enum, or a type that parses itself with `nilo_parse` — or a " ++
                    "`nilo.Upload` for a file — optionally wrapped in `?` when it may be absent.",
            );
        }
    }
}

/// Whether any field of `T` is a file, and so whether this endpoint can be
/// served by a urlencoded form at all.
pub fn holdsAFile(comptime T: type) bool {
    comptime {
        const info = @typeInfo(T).@"struct";
        @setEvalBranchQuota(convert.budget(info.field_names));
        for (info.field_types) |f_type| {
            const Inner = switch (@typeInfo(f_type)) {
                .optional => |o| o.child,
                else => f_type,
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

/// The wall said out loud rather than walked past
/// ([ADR 034](../docs/adr/034-a-binding-hands-its-failures-to-the-handler.md)).
///
/// Reading 256 parts of a 300-part form and stopping would hand the handler a
/// form whose other 44 fields look exactly like fields the browser never
/// sent, and nothing downstream can tell those two apart: `Form(T)` would
/// report them missing, and a `Bound(Form(T))` would report them missing in a
/// 422 the user is then asked to act on. A refusal that names the ceiling is
/// the only answer that is true.
fn tooManyParts() fail.Error {
    return fail.badRequest(
        "this form has more parts than nilo reads from one, which is {d}",
        .{max_parts},
    );
}

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

        // A part that names its file **only** with `filename*` is refused
        // rather than read (ADR 073). `parameterOf` compares the key exactly,
        // so `filename*` does not match `filename` — which was right, and the
        // fallthrough was not: the part became a *text* field whose value is
        // the raw bytes of the upload, and the `Upload` the endpoint asked for
        // was then reported missing. So the 400 named the wrong thing, and the
        // one thing a caller could not do was find out what happened.
        //
        // The doc on `parameterOf` says the plain `filename` is always sent
        // alongside, and that is true of browsers and not of every HTTP
        // library. Refusing is the same call ADR 034 makes about a ceiling:
        // nilo need not read RFC 6266's encoding, it only has to stop
        // pretending the part was something else.
        if (parameterOf(disposition, "filename") == null and
            parameterOf(disposition, "filename*") != null)
        {
            return fail.badRequest(
                "the \"{s}\" part of this form names its file only with `filename*`, and nilo " ++
                    "reads `filename` — send both, as a browser does",
                .{name},
            );
        }

        // A part with a filename is a file, and so is a chosen file with no
        // bytes in it: the user picked an empty file, and that is a file.
        //
        // One part is neither: `filename=""` with no bytes. That is what a
        // browser sends for a file input with nothing chosen, so it is read
        // as the field being absent, the way Go's `FormFile`, Gin, Echo and
        // Fiber read it. It is dropped, not kept as an empty text value as
        // Go keeps it: a text value called `avatar` would reach any `Str`
        // field of that name as "", which the browser did not send. An empty
        // filename with bytes in it is a client that skipped the name, and
        // stays a file.
        if (parameterOf(disposition, "filename")) |filename| {
            if (filename.len == 0 and data.len == 0) continue;
            if (n_files == files.len) return tooManyParts();
            files[n_files] = .{
                .name = name,
                .filename = filename,
                .content_type = headerIn(head, "content-type") orelse "application/octet-stream",
                .bytes = data,
            };
            n_files += 1;
        } else {
            if (n_text == text.len) return tooManyParts();
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
///
/// **One walk, from line end to line end, that stops at whichever blank line
/// comes first.** It used to look for `\r\n\r\n` and then, to see whether a
/// bare-LF one came earlier, for `\n\n` over the rest of the whole body, once
/// per part: 255 parts and a megabyte of padding cost 78 ms of CPU where 1 ms
/// is enough, a cost in parts times bytes that `max_parts` did nothing about
/// (the audit of `http/` at `39896d2`). Neither search may now read past the
/// blank line that ends this head.
fn endOfPartHead(body: []const u8, from: usize) ?PartHead {
    var at = from;
    while (std.mem.indexOfScalarPos(u8, body, at, '\n')) |lf| : (at = lf + 1) {
        // `\n\n`: a bare-LF blank line, the head ends at the first of them.
        if (lf + 1 < body.len and body[lf + 1] == '\n') {
            return .{ .head_end = lf, .data_start = lf + 2 };
        }
        // `\r\n\r\n`: this LF is the first one's, and the line before it
        // was CRLF-terminated. The head ends at that `\r`.
        if (lf > from and body[lf - 1] == '\r' and
            lf + 2 < body.len and body[lf + 1] == '\r' and body[lf + 2] == '\n')
        {
            return .{ .head_end = lf - 1, .data_start = lf + 3 };
        }
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
const budget = @import("budget.zig");

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
/// trap working exactly as ADR 003 intends, and not what these tests are
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

test "a ticked checkbox arrives as `on`, and an unticked one does not arrive" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Exactly what a browser posts for `<input type="checkbox" name="newsletter">`:
    // the name and `on` when it is ticked, and the field absent when it is not.
    const ticked = try read(
        SignUp,
        arena.allocator(),
        "application/x-www-form-urlencoded",
        "email=wati%40example.dev&password=hunter2&newsletter=on",
    );
    try testing.expectEqual(true, ticked.newsletter);

    // The unticked half was never broken — an absent field takes its default,
    // which is what "unticked" means — and it is here so the pair is one test.
    const unticked = try read(
        SignUp,
        arena.allocator(),
        "application/x-www-form-urlencoded",
        "email=wati%40example.dev&password=hunter2",
    );
    try testing.expectEqual(false, unticked.newsletter);
}

test "a form field that is neither true, false nor on says all three" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try expectFails(
        SignUp,
        arena.allocator(),
        "application/x-www-form-urlencoded",
        "email=a%40b.dev&password=hunter2&newsletter=maybe",
        "\"newsletter\" has to be true, false or on, not \"maybe\"",
    );
}

test "a urlencoded form reads a plus as a space, the way a browser writes one" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const Note = struct { text: Str };
    const filled = try read(Note, arena.allocator(), "application/x-www-form-urlencoded", "text=hello+there");
    try testing.expectEqualStrings("hello there", filled.text.view());
}

fn expectFails(comptime T: type, arena: std.mem.Allocator, content_type: []const u8, body: []const u8, says: []const u8) !void {
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

// ---- a form list is a repeated name and nothing else (ADR 132) ----

const Kind2 = enum { comment, mention };

const Post = struct {
    title: Str,
    tags: []const Str = &.{},
    notify: []const Kind2 = &.{},
    scores: []const u32 = &.{},
};

test "a checkbox group binds to a list, one value per repeated name, in the order sent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const filled = try read(
        Post,
        arena.allocator(),
        "application/x-www-form-urlencoded",
        "title=hi&tags=zig&notify=comment&tags=http&notify=mention&scores=3&scores=1",
    );
    try testing.expectEqual(@as(usize, 2), filled.tags.len);
    try testing.expectEqualStrings("zig", filled.tags[0].view());
    try testing.expectEqualStrings("http", filled.tags[1].view());
    try testing.expectEqualSlices(Kind2, &.{ .comment, .mention }, filled.notify);
    try testing.expectEqualSlices(u32, &.{ 3, 1 }, filled.scores);
}

test "a list nobody sent is the empty list, and an empty value contributes nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Nothing ticked: no name arrives at all, and that is not "missing".
    const none = try read(Post, arena.allocator(), "application/x-www-form-urlencoded", "title=hi");
    try testing.expectEqual(@as(usize, 0), none.tags.len);
    try testing.expectEqual(@as(usize, 0), none.notify.len);

    // A row of text boxes with two left blank is a list of one, and a
    // value with a comma in it is one value with a comma in it: there is
    // no second spelling to split on.
    const some = try read(
        Post,
        arena.allocator(),
        "application/x-www-form-urlencoded",
        "title=hi&tags=&tags=a%2Cb&tags=",
    );
    try testing.expectEqual(@as(usize, 1), some.tags.len);
    try testing.expectEqualStrings("a,b", some.tags[0].view());
}

test "a select multiple in a multipart form binds the same way" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const filled = try read(Post, arena.allocator(), multipart_type, comptime multipart(&.{
        "Content-Disposition: form-data; name=\"title\"\r\n\r\nhi",
        "Content-Disposition: form-data; name=\"notify\"\r\n\r\nmention",
        "Content-Disposition: form-data; name=\"notify\"\r\n\r\ncomment",
    }));
    try testing.expectEqualSlices(Kind2, &.{ .mention, .comment }, filled.notify);
}

test "one value that will not convert names the field, and the binding still reads the rest" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    try expectFails(
        Post,
        arena.allocator(),
        "application/x-www-form-urlencoded",
        "title=hi&notify=comment&notify=nonsense",
        "\"notify\" is not one of the known choices (comment, mention): \"nonsense\"",
    );

    // Collecting: the first bad value is the one recorded, and the good
    // ones around it are still in the list, the way a query list reads.
    var outcomes: [@typeInfo(Post).@"struct".field_names.len]convert.Outcome = undefined;
    const filled = try readIntoCollecting(
        Post,
        arena.allocator(),
        &test_lifetime,
        "application/x-www-form-urlencoded",
        "title=hi&scores=1&scores=x&scores=y&scores=4",
        &outcomes,
    );
    try testing.expectEqualSlices(u32, &.{ 1, 4 }, filled.scores);
    try testing.expect(outcomes[3].reason != null);
    try testing.expectEqualStrings("x", outcomes[3].given.view());
    try testing.expect(outcomes[0].reason == null);
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

const browser_empty_file = "Content-Disposition: form-data; name=\"avatar\"; filename=\"\"\r\n" ++
    "Content-Type: application/octet-stream\r\n\r\n";

const WithOptionalAvatar = struct {
    email: Str,
    avatar: ?Upload = null,
};

test "a file field left empty by the browser is no file, so an optional Upload is null" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const filled = try read(WithOptionalAvatar, arena.allocator(), multipart_type, comptime multipart(&.{
        "Content-Disposition: form-data; name=\"email\"\r\n\r\nx@y.z",
        browser_empty_file,
    }));
    try testing.expectEqualStrings("x@y.z", filled.email.view());
    try testing.expect(filled.avatar == null);
}

test "a file field left empty by the browser is a missing file for a required Upload" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    try expectFails(
        WithAvatar,
        arena.allocator(),
        multipart_type,
        comptime multipart(&.{
            "Content-Disposition: form-data; name=\"email\"\r\n\r\nx@y.z",
            browser_empty_file,
        }),
        "the form is missing the file \"avatar\"",
    );
}

test "a file the user chose with nothing in it is still a file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const filled = try read(WithOptionalAvatar, arena.allocator(), multipart_type, comptime multipart(&.{
        "Content-Disposition: form-data; name=\"email\"\r\n\r\nx@y.z",
        "Content-Disposition: form-data; name=\"avatar\"; filename=\"empty.txt\"\r\n" ++
            "Content-Type: text/plain\r\n\r\n",
    }));
    try testing.expectEqualStrings("empty.txt", filled.avatar.?.filename.view());
    try testing.expectEqual(@as(usize, 0), filled.avatar.?.len());
}

test "a part with an empty filename but bytes in it is still a file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const filled = try read(WithOptionalAvatar, arena.allocator(), multipart_type, comptime multipart(&.{
        "Content-Disposition: form-data; name=\"email\"\r\n\r\nx@y.z",
        "Content-Disposition: form-data; name=\"avatar\"; filename=\"\"\r\n\r\nABC",
    }));
    try testing.expectEqualStrings("", filled.avatar.?.filename.view());
    try testing.expectEqualStrings("ABC", filled.avatar.?.bytes.view());
}

test "an empty file part ahead of a real one of the same name does not hide it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const filled = try read(WithOptionalAvatar, arena.allocator(), multipart_type, comptime multipart(&.{
        "Content-Disposition: form-data; name=\"email\"\r\n\r\nx@y.z",
        browser_empty_file,
        "Content-Disposition: form-data; name=\"avatar\"; filename=\"me.png\"\r\n\r\nPNG",
    }));
    try testing.expectEqualStrings("me.png", filled.avatar.?.filename.view());
}

test "an empty file part is not a text value either" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const fields = try parse(arena.allocator(), .{ .multipart = "niloBoundary" }, comptime multipart(&.{
        "Content-Disposition: form-data; name=\"email\"\r\n\r\nx@y.z",
        browser_empty_file,
    }));
    try testing.expectEqual(@as(usize, 1), fields.text.len);
    try testing.expectEqual(@as(usize, 0), fields.files.len);
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

test "a part that names its file only with filename* is refused, not read as text" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // What used to happen: `filename*` does not match `filename`, so the part
    // fell through to the text arm and `avatar` became a text field holding
    // the raw PNG. The 400 then said the *file* was missing, which is the one
    // thing that was not wrong with the request.
    try expectFails(
        WithAvatar,
        arena.allocator(),
        multipart_type,
        comptime multipart(&.{
            "Content-Disposition: form-data; name=\"email\"\r\n\r\nx@y.z",
            "Content-Disposition: form-data; name=\"avatar\"; filename*=UTF-8''caf%C3%A9.png\r\n" ++
                "Content-Type: image/png\r\n\r\nPNGDATA",
        }),
        "the \"avatar\" part of this form names its file only with `filename*`, and nilo " ++
            "reads `filename` — send both, as a browser does",
    );
}

test "a part sending both filename and filename* is read from the plain one" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // What every browser sends, and the reason the encoded form was never
    // read in the first place. Nothing here changes for it.
    const filled = try read(WithAvatar, arena.allocator(), multipart_type, comptime multipart(&.{
        "Content-Disposition: form-data; name=\"email\"\r\n\r\nx@y.z",
        "Content-Disposition: form-data; name=\"avatar\"; filename=\"cafe.png\"; " ++
            "filename*=UTF-8''caf%C3%A9.png\r\n" ++
            "Content-Type: image/png\r\n\r\nPNGDATA",
    }));
    try testing.expectEqualStrings("cafe.png", filled.avatar.filename.view());
    try testing.expectEqualStrings("PNGDATA", filled.avatar.bytes.view());
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

fn formOfParts(gpa: std.mem.Allocator, n: usize) !std.ArrayList(u8) {
    var body: std.ArrayList(u8) = .empty;
    errdefer body.deinit(gpa);
    for (0..n) |i| {
        try body.print(
            gpa,
            "--niloBoundary\r\nContent-Disposition: form-data; name=\"f{d}\"\r\n\r\nv\r\n",
            .{i},
        );
    }
    try body.appendSlice(gpa, "--niloBoundary--\r\n");
    return body;
}

test "the number of parts one form may hold is bounded" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Right up to the wall and no refusal: the bound is on what a client may
    // make nilo allocate, not on what an ordinary form may say.
    var body = try formOfParts(testing.allocator, max_parts);
    defer body.deinit(testing.allocator);

    const fields = try parse(arena.allocator(), kindOf(multipart_type), body.items);
    try testing.expectEqual(@as(usize, max_parts), fields.text.len);
    try testing.expectEqualStrings("f0", fields.text[0].name);
}

test "a form past that bound is refused rather than quietly cut short" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // A body made of nothing but boundaries: the arrays are sized from the
    // count, and this is what stops that count being the client's to choose.
    // It used to bind the first 256 and walk past the rest, which a handler
    // reads as 256 fields sent and the others left blank (ADR 034).
    var body = try formOfParts(testing.allocator, max_parts * 2);
    defer body.deinit(testing.allocator);

    var in_flight = fail.InFlight{};
    in_flight.startRequest("POST", "/form");
    const previous = bulkhead.setFallbackSlot(&in_flight);
    defer _ = bulkhead.setFallbackSlot(previous);

    try testing.expectError(
        error.Failed,
        parse(arena.allocator(), kindOf(multipart_type), body.items),
    );
    try testing.expectEqualStrings(
        "this form has more parts than nilo reads from one, which is 256",
        in_flight.failure.message(),
    );
}

test "an upload is written under a name the handler chose, and the client's own name is refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // The filename a stranger can send, arriving intact — the parser's job is
    // to hand it over unchanged, and `saveTo`'s is to refuse it.
    const filled = try read(WithAvatar, arena.allocator(), multipart_type, comptime multipart(&.{
        "Content-Disposition: form-data; name=\"email\"\r\n\r\nwati@example.dev",
        "Content-Disposition: form-data; name=\"avatar\"; filename=\"../../etc/cron.d/anything\"\r\n" ++
            "Content-Type: image/png\r\n\r\n\x89PNG\r\n\x1a\n bits",
    }));

    // nilo's rather than std's because the leftovers are listed below, and
    // std's directory panics inside the standard library when it is listed
    // unless it was opened with `.iterate` (ADR 250).
    var tmp = str_mod.tmpDir();
    defer tmp.cleanup();
    // Something longer already under the name, so a short write that left the
    // tail of it behind would read back wrong.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "avatar-7.png", .data = "an older and much longer avatar" });

    var path_buf: [128]u8 = undefined;
    const path = try tmp.path(&path_buf, "");
    const dir = try bulkhead.Dir.open(path);
    defer dir.close();

    try filled.avatar.saveTo(dir, "avatar-7.png");

    var read_buf: [64]u8 = undefined;
    try testing.expectEqualStrings(
        "\x89PNG\r\n\x1a\n bits",
        try tmp.dir.readFile(std.testing.io, "avatar-7.png", &read_buf),
    );

    // The temporary file the rename came from is gone: a directory an
    // application serves out of would otherwise fill with 16-hex-digit
    // leftovers, one per upload.
    var count: usize = 0;
    var entries = tmp.dir.iterate();
    while (try entries.next(std.testing.io)) |entry| {
        try testing.expectEqualStrings("avatar-7.png", entry.name);
        count += 1;
    }
    try testing.expectEqual(@as(usize, 1), count);

    // And the name the client sent is an error rather than a path resolved
    // against the directory, which is the whole reason this method exists.
    try testing.expectError(
        error.NameNotAllowed,
        filled.avatar.saveTo(dir, filled.avatar.filename.view()),
    );
}

test "a megabyte of ampersands is refused for its pair count, before an arena byte is spent on it" {
    var counting = budget.Counting{ .child = testing.allocator };

    const body = try testing.allocator.alloc(u8, 1024 * 1024);
    defer testing.allocator.free(body);
    @memset(body, '&');

    var in_flight = fail.InFlight{};
    in_flight.startRequest("POST", "/form");
    const previous = bulkhead.setFallbackSlot(&in_flight);
    defer _ = bulkhead.setFallbackSlot(previous);

    // It used to be 33 MB of `Param`s for a request carrying no data at all.
    try testing.expectError(error.Failed, parse(counting.allocator(), .urlencoded, body));
    try testing.expectEqual(@as(usize, 0), counting.bytes);
    try testing.expectEqualStrings(
        "this form has more pairs than nilo reads from one, which is 1024",
        in_flight.failure.message(),
    );
    try testing.expectEqual(@as(u16, 400), in_flight.failure.status);
}

test "a urlencoded form of exactly max_pairs pairs is read, and one more is not" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(testing.allocator);
    for (0..max_pairs) |i| try body.print(testing.allocator, "{s}f{d}=v", .{ if (i == 0) "" else "&", i });

    const fields = try parse(arena.allocator(), .urlencoded, body.items);
    try testing.expectEqual(@as(usize, max_pairs), fields.text.len);

    try body.appendSlice(testing.allocator, "&one=more");
    var in_flight = fail.InFlight{};
    in_flight.startRequest("POST", "/form");
    const previous = bulkhead.setFallbackSlot(&in_flight);
    defer _ = bulkhead.setFallbackSlot(previous);
    try testing.expectError(error.Failed, parse(arena.allocator(), .urlencoded, body.items));
}

test "a multipart body's parts are not each searched for a blank line to the end of the body" {
    // 255 parts, then a megabyte of epilogue that holds no `\n\n` at all.
    // The search for a part's bare-LF blank line ran to the end of the body
    // for every part, 78 ms of CPU where one pass is enough (the audit of
    // `http/` at `39896d2`).
    var body = try formOfParts(testing.allocator, max_parts - 1);
    defer body.deinit(testing.allocator);
    try body.appendNTimes(testing.allocator, 'x', 1024 * 1024);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // What one pass over the body costs, taken twenty times over so the
    // clock's grain is not what is being compared.
    var passes: usize = 0;
    const reference_start = str_mod.monotonicMicros();
    for (0..20) |_| passes += std.mem.count(u8, body.items, "\n\n");
    const reference = str_mod.monotonicMicros() - reference_start;
    try testing.expectEqual(@as(usize, 0), passes);

    const start = str_mod.monotonicMicros();
    const fields = try parse(arena.allocator(), kindOf(multipart_type), body.items);
    const spent = str_mod.monotonicMicros() - start;

    try testing.expectEqual(@as(usize, max_parts - 1), fields.text.len);
    // A parse is a handful of passes. Searching to the end per part is 255.
    try testing.expect(spent < reference);
}
