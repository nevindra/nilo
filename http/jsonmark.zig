//! What a type said about how its JSON is spelled.
//!
//! `std.json` knows one union encoding, externally tagged — `{"metrics":{…}}`,
//! one object with one key. Most REST APIs use the other one, with the
//! discriminator beside the variant's own fields:
//!
//! ```json
//! {"signal":"metrics","metric_name":"system.cpu.utilization","agg":"avg"}
//! ```
//!
//! There was no way to say that, so it was hand-written `jsonStringify` and
//! `jsonParse` per type. This is the marker that says it instead:
//!
//! ```zig
//! pub const nilo_json = .{ .tag = "signal", .rename_all = .lowercase };
//! ```
//!
//! **The marker is plain data, and it has to be** — the same rule and the same
//! reason as `nilo_openapi` ([ADR 0076](../docs/adr/0076-a-type-that-writes-its-own-json-says-so.md)):
//! a type in a module that imports nothing at all still has to be able to write
//! it, so there is no shared type to coerce it to and every field is read by
//! name. `rename_all` arrives as an enum literal for the same reason.
//!
//! ## Which half is nilo's, and which is std's
//!
//! Writing is nilo's, because nilo owns the call: `json.write` asks `covers`
//! and generates the writer. Reading is not — `std.json` decides which parser a
//! type gets, by asking `std.meta.hasFn(T, "jsonParse")`, and nothing can add a
//! declaration to a type somebody else wrote. So the read half is a function
//! nilo supplies and the type hands over:
//!
//! ```zig
//! pub const jsonParse = nilo.jsonParseFor(@This());
//! ```
//!
//! Two declarations rather than one, and that is the price of not writing a
//! second JSON parser. The alternative was for `ctx.json` to stop calling
//! `std.json` and drive a parser of nilo's own, which would put the unicode
//! escapes, the surrogate pairs and the number edges in this repository —
//! exactly what `json.zig` refuses to do for floats, for the same reason.
//!
//! ## What it costs
//!
//! Nothing per request and nothing per connection: the marker is read while
//! compiling and every name it produces is a comptime string. On the write
//! side it is a saving rather than a cost, because `covers` is answered for the
//! whole value — one union field anywhere used to send the entire response to
//! `std.json`, strings included. A 374-byte alert rule went 258ns → 93ns, and a
//! 104-byte one 85ns → 25ns ([`bench/result/http.md`](../bench/result/http.md)).

const std = @import("std");

/// The declaration a type writes to say how its JSON is spelled.
pub const marker = "nilo_json";

/// The case a name is written in on the wire.
///
/// The list is shorter than serde's, and deliberately: these are the transforms
/// that are unambiguous **from a Zig field name**, which is already snake_case.
/// `.snake_case` is not here because it would be the identity, and asking for it
/// is a misunderstanding worth a sentence rather than a no-op.
///
/// One of these is worth reading twice. `.lowercase` and `.UPPERCASE` join the
/// words rather than keeping the underscore — `not_found` becomes `notfound`,
/// not `not_found`. That is what serde does and what the name literally says,
/// one lowercase word. If the underscore is wanted, `.SCREAMING_SNAKE_CASE`
/// keeps it, and a field with no underscore in it is unaffected either way.
pub const Case = enum {
    /// `not_found` → `notfound`
    lowercase,
    /// `not_found` → `NOTFOUND`
    UPPERCASE,
    /// `not_found` → `notFound`
    camelCase,
    /// `not_found` → `NotFound`
    PascalCase,
    /// `not_found` → `NOT_FOUND`
    SCREAMING_SNAKE_CASE,
    /// `not_found` → `not-found`
    @"kebab-case",
};

/// A marker that has been read and checked.
pub const Mark = struct {
    /// The discriminator's key, when the type is an internally tagged union.
    tag: ?[]const u8 = null,
    /// How a name is spelled on the wire.
    rename_all: ?Case = null,
};

/// Whether `T` carries the marker at all. Cheap enough to ask first, and it is
/// what keeps every path below out of the way of a type that never asked.
pub fn marked(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, marker),
        else => false,
    };
}

/// `T.nilo_json`, read field by field and checked, or null if there is none.
///
/// Every way of writing this wrong gets a sentence here rather than a compiler
/// message pointing at a line of nilo's — the same reason `toldOf` in
/// `openapi.zig` reads `nilo_openapi` by hand (ADR 0027).
pub fn of(comptime T: type) ?Mark {
    comptime {
        if (!marked(T)) return null;

        const said = @field(T, marker);
        const Said = @TypeOf(said);
        const info = @typeInfo(Said);
        if (info != .@"struct") @compileError(
            "nilo: `" ++ @typeName(T) ++ "`'s `" ++ marker ++ "` is a " ++ @typeName(Said) ++
                ", and it says how this type's JSON is spelled, so it is written as a struct.\n" ++
                "    pub const " ++ marker ++ " = .{ .tag = \"signal\" };",
        );

        var mark = Mark{};
        for (info.@"struct".fields) |f| {
            if (std.mem.eql(u8, f.name, "tag")) {
                mark.tag = said.tag;
            } else if (std.mem.eql(u8, f.name, "rename_all")) {
                mark.rename_all = caseOf(T, said.rename_all);
            } else @compileError(
                "nilo: `" ++ @typeName(T) ++ "`'s `" ++ marker ++ "` has a field `" ++ f.name ++
                    "`, which is not something it can say.\n" ++
                    "  A marker says two things: `tag`, the key the variant's name goes under, " ++
                    "and `rename_all`, how a name is spelled on the wire.\n" ++
                    "    pub const " ++ marker ++ " = .{ .tag = \"signal\", .rename_all = .camelCase };",
            );
        }

        if (mark.tag == null and mark.rename_all == null) @compileError(
            "nilo: `" ++ @typeName(T) ++ "`'s `" ++ marker ++ "` is empty, so it says nothing " ++
                "about this type's JSON and nothing changes.\n" ++
                "  Either say what it is for, or take the declaration off:\n" ++
                "    pub const " ++ marker ++ " = .{ .tag = \"signal\" };        // a tagged union\n" ++
                "    pub const " ++ marker ++ " = .{ .rename_all = .camelCase }; // a cased enum",
        );

        if (mark.tag) |key| checkTag(T, key);
        if (mark.rename_all) |c| checkRenames(T, c);
        return mark;
    }
}

/// `said.rename_all` — an enum literal, because the marker is plain data and
/// the type writing it may not be able to name `Case`.
fn caseOf(comptime T: type, comptime said: anytype) Case {
    comptime {
        const name = @tagName(said);
        if (std.mem.eql(u8, name, "snake_case")) @compileError(
            "nilo: `" ++ @typeName(T) ++ "` asks for `.rename_all = .snake_case`, which is what a " ++
                "Zig field name already is, so it would change nothing.\n" ++
                "  Leave `rename_all` off to send the field names as they are written.\n" ++
                "  For the shouted version, `.SCREAMING_SNAKE_CASE` keeps the underscores.",
        );
        if (!@hasField(Case, name)) {
            var known: []const u8 = "";
            for (@typeInfo(Case).@"enum".fields, 0..) |f, i| {
                known = known ++ (if (i == 0) "" else ", ") ++ "." ++ f.name;
            }
            @compileError(
                "nilo: `" ++ @typeName(T) ++ "` asks for `.rename_all = ." ++ name ++
                    "`, which is not a case nilo writes.\n" ++
                    "  The ones it does: " ++ known ++ ".",
            );
        }
        return @field(Case, name);
    }
}

/// A `tag` is a claim about a union, so it is checked against one.
fn checkTag(comptime T: type, comptime key: []const u8) void {
    comptime {
        const info = @typeInfo(T);
        if (info != .@"union") @compileError(
            "nilo: `" ++ @typeName(T) ++ "` says `.tag = \"" ++ key ++ "\"`, which puts the name of " ++
                "the live variant into the JSON — and this is a " ++ @tagName(info) ++ ", which has no variants.\n" ++
                "  `tag` belongs on a `union(enum)`. On anything else the marker says only `rename_all`.",
        );
        if (info.@"union".tag_type == null) @compileError(
            "nilo: `" ++ @typeName(T) ++ "` says `.tag = \"" ++ key ++ "\"` and is an untagged union, " ++
                "so nothing in it knows which variant is live and there is no name to write.\n" ++
                "  Write it as `union(enum)` and nilo can send and read it.",
        );
        if (key.len == 0) @compileError(
            "nilo: `" ++ @typeName(T) ++ "`'s `.tag` is the empty string, so the variant's name would " ++
                "go under a key with no name.\n" ++
                "    pub const " ++ marker ++ " = .{ .tag = \"signal\" };",
        );

        // The one mistake that would corrupt the wire rather than fail: a
        // variant whose own struct already has a field by the tag's name emits
        // that key twice, and which one a reader takes is its business.
        for (info.@"union".fields) |arm| {
            const Payload = arm.type;
            if (Payload == void) continue;
            const payload = @typeInfo(Payload);
            if (payload != .@"struct") @compileError(
                "nilo: `" ++ @typeName(T) ++ "`'s variant `" ++ arm.name ++ "` carries a " ++
                    @typeName(Payload) ++ ", and an internally tagged union writes the variant's " ++
                    "fields beside the tag — so the variant has to have fields.\n" ++
                    "  Give it a struct of its own, or leave the variant empty (`" ++ arm.name ++
                    ",`) to send `{\"" ++ key ++ "\":\"" ++ arm.name ++ "\"}` on its own.",
            );
            for (payload.@"struct".fields) |f| {
                if (std.mem.eql(u8, f.name, key)) @compileError(
                    "nilo: `" ++ @typeName(T) ++ "`'s `.tag` is \"" ++ key ++ "\" and its variant `" ++
                        arm.name ++ "` already has a field called `" ++ f.name ++ "`, so that key would " ++
                        "be written twice and a reader would pick one of them.\n" ++
                        "  Rename the tag, or rename the field.",
                );
            }
        }
    }
}

/// A `rename_all` maps one name at a time, and two names can land on one.
///
/// `.lowercase` and `.UPPERCASE` join the words rather than keeping the
/// underscore, so `not_found` and `notfound` both come out `notfound`. The
/// argument is `checkTag`'s, word for word: **this is a mistake that corrupts
/// the wire rather than failing.** A writer emits the same key or value twice
/// and `fromSpan` returns whichever variant the `inline for` reaches first —
/// which is declaration order, and nothing anywhere says so.
///
/// `O(n²)` over the names the type already produces, all of it while
/// compiling, on a path that never reaches a binary. A union of eight variants
/// is 28 comparisons of short literals, once.
fn checkRenames(comptime T: type, comptime c: Case) void {
    comptime {
        const fields = switch (@typeInfo(T)) {
            .@"enum" => |e| e.fields,
            .@"union" => |u| u.fields,
            // `rename_all` only ever renames a variant or an enum value —
            // a payload struct's own fields are left alone — so on anything
            // else there is nothing here that could collide.
            else => return,
        };
        const m = Mark{ .rename_all = c };
        const what = if (@typeInfo(T) == .@"enum") "value" else "variant";
        for (fields, 0..) |a, i| {
            const spelled = wire(a.name, m);
            for (fields[i + 1 ..]) |b| {
                if (!std.mem.eql(u8, spelled, wire(b.name, m))) continue;
                @compileError(
                    "nilo: `" ++ @typeName(T) ++ "` asks for `.rename_all = ." ++ @tagName(c) ++
                        "`, and its " ++ what ++ "s `" ++ a.name ++ "` and `" ++ b.name ++
                        "` both come out as \"" ++ spelled ++ "\".\n" ++
                        "  Two of them under one name on the wire is not a spelling problem: a reader " ++
                        "takes whichever it meets first, which is declaration order, and nothing says so.\n" ++
                        "  Rename one of them, or choose a case that keeps them apart — " ++
                        "`.SCREAMING_SNAKE_CASE` and `.kebab-case` both keep the underscore, " ++
                        "and `.lowercase` and `.UPPERCASE` are the two that drop it.",
                );
            }
        }
    }
}

/// How `name` is spelled on the wire under `mark`. A comptime string, so it
/// costs a literal rather than a conversion (`json.zig` writes it as part of
/// the same `writeAll` the punctuation is in).
pub fn wire(comptime name: []const u8, comptime mark: ?Mark) []const u8 {
    comptime {
        const c = (mark orelse return name).rename_all orelse return name;
        var out: []const u8 = "";
        switch (c) {
            // Joined rather than separated — see the note on `Case`.
            .lowercase, .UPPERCASE => for (name) |ch| {
                if (ch == '_') continue;
                out = out ++ [_]u8{if (c == .UPPERCASE) std.ascii.toUpper(ch) else std.ascii.toLower(ch)};
            },
            .SCREAMING_SNAKE_CASE => for (name) |ch| {
                out = out ++ [_]u8{std.ascii.toUpper(ch)};
            },
            .@"kebab-case" => for (name) |ch| {
                out = out ++ [_]u8{if (ch == '_') '-' else ch};
            },
            .camelCase, .PascalCase => {
                var shout = c == .PascalCase;
                for (name) |ch| {
                    if (ch == '_') {
                        shout = true;
                        continue;
                    }
                    out = out ++ [_]u8{if (shout) std.ascii.toUpper(ch) else ch};
                    shout = false;
                }
            },
        }
        return out;
    }
}

/// The names of `T`'s fields as they go out, in declaration order. What the
/// API description lists as an enum's choices, and what the reader matches
/// against.
pub fn wireNames(comptime T: type) []const []const u8 {
    comptime {
        const mark = of(T);
        var names: []const []const u8 = &.{};
        const fields = switch (@typeInfo(T)) {
            .@"enum" => |e| e.fields,
            .@"union" => |u| u.fields,
            else => @compileError("nilo: `" ++ @typeName(T) ++ "` has no variants to name."),
        };
        for (fields) |f| names = names ++ [_][]const u8{wire(f.name, mark)};
        return names;
    }
}

/// The reader a marked type hands to `std.json`:
///
/// ```zig
/// pub const jsonParse = nilo.jsonParseFor(@This());
/// ```
///
/// It has to be spelled that way round because `std.json` is the one that
/// chooses a parser, by asking `std.meta.hasFn(T, "jsonParse")`, and nothing
/// can add a declaration to a type somebody else wrote. Handing the function
/// over rather than driving the parse from nilo's side is what keeps `std.json`
/// the only JSON parser in the process — nesting, escapes, surrogate pairs and
/// number edges all stay theirs.
pub fn parseFor(comptime T: type) @TypeOf(Reader(T).parse) {
    comptime {
        const m = of(T) orelse @compileError(
            "nilo: `" ++ @typeName(T) ++ "` asks for nilo's JSON reader and has no `" ++ marker ++
                "`, so there is nothing for the reader to do differently from `std.json`.\n" ++
                "  Say what its JSON looks like first, then hand the reader over:\n" ++
                "    pub const " ++ marker ++ " = .{ .tag = \"signal\" };\n" ++
                "    pub const jsonParse = nilo.jsonParseFor(@This());",
        );
        // Checked here rather than where it is used, so it fires on the line
        // somebody wrote instead of on the first request that carries one.
        if (m.tag == null and @typeInfo(T) != .@"enum") @compileError(
            "nilo: `" ++ @typeName(T) ++ "` hands nilo's JSON reader a `" ++ marker ++
                "` with only `rename_all` on it, and it is a " ++ @tagName(@typeInfo(T)) ++ ".\n" ++
                "  Renaming a variant changes the key `std.json` looks for, which nilo cannot read " ++
                "back without a tag to find it by. Add one:\n" ++
                "    pub const " ++ marker ++ " = .{ .tag = \"kind\", .rename_all = … };",
        );
    }
    return Reader(T).parse;
}

fn Reader(comptime T: type) type {
    return struct {
        pub fn parse(
            gpa: std.mem.Allocator,
            source: anytype,
            options: std.json.ParseOptions,
        ) std.json.ParseError(@TypeOf(source.*))!T {
            const m = comptime of(T).?;

            if (comptime m.tag == null) return readRenamed(gpa, source, options);

            // An internally tagged object cannot be read in one pass: the
            // variant is not known until the discriminator turns up, and it may
            // turn up after fields that belong to it. So the object is looked
            // at twice.
            //
            // Over a complete input the bytes are already in memory, so the
            // second look costs a scan and nothing else.
            if (comptime @TypeOf(source) == *std.json.Scanner) {
                // Peeking is what puts the cursor on the value's first byte.
                // Taking it before that leaves the `:` after the field name — or
                // the `,` after the previous element — inside the span, which is
                // a syntax error the moment the span is read on its own. A union
                // at the top of a body happens to work either way, which is
                // exactly why this is worth a comment.
                _ = try source.peekNextTokenType();
                const start = source.cursor;
                try source.skipValue();
                return fromSpan(gpa, source.input[start..source.cursor], options);
            }

            // Anything streaming has to hold the object before it can be
            // looked at twice, and `std.json.Value` is what holds it.
            const held = try std.json.innerParse(std.json.Value, gpa, source, options);
            return fromValue(gpa, held, options);
        }

        /// An enum, or a union that renames its variants without tagging them.
        fn readRenamed(
            gpa: std.mem.Allocator,
            source: anytype,
            options: std.json.ParseOptions,
        ) std.json.ParseError(@TypeOf(source.*))!T {
            // `parseFor` refused anything else before handing this over.
            comptime std.debug.assert(@typeInfo(T) == .@"enum");

            const token = try source.nextAllocMax(gpa, .alloc_if_needed, options.max_value_len.?);
            const text = switch (token) {
                inline .string, .allocated_string => |slice| slice,
                else => return error.UnexpectedToken,
            };
            defer switch (token) {
                .allocated_string => gpa.free(text),
                else => {},
            };
            return named(text) orelse error.InvalidEnumTag;
        }

        /// The bytes of one object, read twice: once for the discriminator,
        /// once for the variant it names.
        fn fromSpan(
            gpa: std.mem.Allocator,
            span: []const u8,
            options: std.json.ParseOptions,
        ) std.json.ParseError(std.json.Scanner)!T {
            const key = comptime of(T).?.tag.?;

            var scan = std.json.Scanner.initCompleteInput(gpa, span);
            defer scan.deinit();
            if (.object_begin != try scan.next()) return error.UnexpectedToken;

            const found = while (true) {
                const token = try scan.nextAllocMax(gpa, .alloc_if_needed, options.max_value_len.?);
                const name = switch (token) {
                    inline .string, .allocated_string => |slice| slice,
                    .object_end => break null,
                    else => return error.UnexpectedToken,
                };
                if (!std.mem.eql(u8, name, key)) {
                    try scan.skipValue();
                    continue;
                }
                const value = try scan.nextAllocMax(gpa, .alloc_if_needed, options.max_value_len.?);
                break switch (value) {
                    inline .string, .allocated_string => |slice| slice,
                    else => return error.UnexpectedToken,
                };
            } else null;

            const arm = found orelse return error.MissingField;

            // The variant's own fields are read out of the same bytes, with the
            // discriminator among them — which is why unknown fields have to be
            // allowed here and are checked separately below.
            var inner = options;
            inner.ignore_unknown_fields = true;

            inline for (@typeInfo(T).@"union".fields, comptime wireNames(T)) |f, on_the_wire| {
                if (std.mem.eql(u8, arm, on_the_wire)) {
                    if (f.type == void) return @unionInit(T, f.name, {});
                    const payload = try std.json.parseFromSliceLeaky(f.type, gpa, span, inner);
                    if (!options.ignore_unknown_fields) try refuseUnknown(f.type, gpa, span, options);
                    return @unionInit(T, f.name, payload);
                }
            }
            return error.InvalidEnumTag;
        }

        /// The same, for a source that had to be held rather than rewound.
        fn fromValue(
            gpa: std.mem.Allocator,
            held: std.json.Value,
            options: std.json.ParseOptions,
        ) std.json.ParseFromValueError!T {
            const key = comptime of(T).?.tag.?;
            const object = switch (held) {
                .object => |o| o,
                else => return error.UnexpectedToken,
            };
            const arm = switch (object.get(key) orelse return error.MissingField) {
                .string => |s| s,
                else => return error.UnexpectedToken,
            };

            var inner = options;
            inner.ignore_unknown_fields = true;

            inline for (@typeInfo(T).@"union".fields, comptime wireNames(T)) |f, on_the_wire| {
                if (std.mem.eql(u8, arm, on_the_wire)) {
                    if (f.type == void) return @unionInit(T, f.name, {});
                    return @unionInit(T, f.name, try std.json.parseFromValueLeaky(f.type, gpa, held, inner));
                }
            }
            return error.InvalidEnumTag;
        }

        /// `ignore_unknown_fields` had to be turned on to get past the
        /// discriminator, so the check it would have done is done here instead.
        /// Without this a typo inside a tagged variant would be dropped in
        /// silence, where the same typo outside one is a 400 naming the field.
        fn refuseUnknown(
            comptime Payload: type,
            gpa: std.mem.Allocator,
            span: []const u8,
            options: std.json.ParseOptions,
        ) std.json.ParseError(std.json.Scanner)!void {
            const key = comptime of(T).?.tag.?;

            var scan = std.json.Scanner.initCompleteInput(gpa, span);
            defer scan.deinit();
            if (.object_begin != try scan.next()) return error.UnexpectedToken;

            while (true) {
                const token = try scan.nextAllocMax(gpa, .alloc_if_needed, options.max_value_len.?);
                const name = switch (token) {
                    inline .string, .allocated_string => |slice| slice,
                    .object_end => return,
                    else => return error.UnexpectedToken,
                };
                try scan.skipValue();

                if (std.mem.eql(u8, name, key)) continue;
                var known = false;
                inline for (@typeInfo(Payload).@"struct".fields) |f| {
                    if (std.mem.eql(u8, name, f.name)) known = true;
                }
                if (!known) return error.UnknownField;
            }
        }

        /// The variant `text` names, or null.
        fn named(text: []const u8) ?T {
            inline for (@typeInfo(T).@"enum".fields, comptime wireNames(T)) |f, on_the_wire| {
                if (std.mem.eql(u8, text, on_the_wire)) return @field(T, f.name);
            }
            return null;
        }
    };
}

// ---- tests ----

const testing = std.testing;

test "a name is spelled the way the case says" {
    try testing.expectEqualStrings("notfound", comptime wire("not_found", .{ .rename_all = .lowercase }));
    try testing.expectEqualStrings("NOTFOUND", comptime wire("not_found", .{ .rename_all = .UPPERCASE }));
    try testing.expectEqualStrings("notFound", comptime wire("not_found", .{ .rename_all = .camelCase }));
    try testing.expectEqualStrings("NotFound", comptime wire("not_found", .{ .rename_all = .PascalCase }));
    try testing.expectEqualStrings("NOT_FOUND", comptime wire("not_found", .{ .rename_all = .SCREAMING_SNAKE_CASE }));
    try testing.expectEqualStrings("not-found", comptime wire("not_found", .{ .rename_all = .@"kebab-case" }));
}

test "a name with no underscore in it is the same under every case that keeps its letters" {
    try testing.expectEqualStrings("critical", comptime wire("critical", .{ .rename_all = .lowercase }));
    try testing.expectEqualStrings("critical", comptime wire("critical", .{ .rename_all = .camelCase }));
    try testing.expectEqualStrings("CRITICAL", comptime wire("critical", .{ .rename_all = .SCREAMING_SNAKE_CASE }));
    try testing.expectEqualStrings("Critical", comptime wire("critical", .{ .rename_all = .PascalCase }));
}

test "a type that says nothing is spelled the way it is written" {
    try testing.expectEqualStrings("not_found", comptime wire("not_found", null));
    try testing.expectEqualStrings("not_found", comptime wire("not_found", .{ .tag = "kind" }));
}

test "an unmarked type has no mark, and a marked one has what it said" {
    const Plain = enum { info, warning };
    const Cased = enum {
        pub const nilo_json = .{ .rename_all = .SCREAMING_SNAKE_CASE };
        info,
        warning,
    };

    try testing.expect(comptime of(Plain) == null);
    try testing.expect(comptime of(u32) == null);

    const mark = comptime of(Cased).?;
    try testing.expect(mark.tag == null);
    try testing.expectEqual(Case.SCREAMING_SNAKE_CASE, mark.rename_all.?);
}

test "a tagged union's mark carries the key, and the arms keep their own names" {
    const Signal = union(enum) {
        pub const nilo_json = .{ .tag = "signal" };
        metrics: struct { threshold: f64 },
        logs: struct { query: []const u8 },
    };

    const mark = comptime of(Signal).?;
    try testing.expectEqualStrings("signal", mark.tag.?);
    try testing.expect(mark.rename_all == null);

    const names = comptime wireNames(Signal);
    try testing.expectEqual(@as(usize, 2), names.len);
    try testing.expectEqualStrings("metrics", names[0]);
    try testing.expectEqualStrings("logs", names[1]);
}

test "a tagged union may rename its arms as well as tag them" {
    const Channel = union(enum) {
        pub const nilo_json = .{ .tag = "kind", .rename_all = .@"kebab-case" };
        web_hook: struct { url: []const u8 },
        discord_dm: struct { user: []const u8 },
    };

    const names = comptime wireNames(Channel);
    try testing.expectEqualStrings("web-hook", names[0]);
    try testing.expectEqualStrings("discord-dm", names[1]);
}

test "the case that would collide two names is the only one refused" {
    // The pair `refusals/json_rename_all_collides_on_an_enum.zig` refuses:
    // `.lowercase` drops the underscore, so these two land on one name. Here
    // the same two names are checked under every case that keeps them apart,
    // because a check that refuses too much is the failure mode a comptime
    // rule cannot be argued with about.
    const Kept = enum {
        pub const nilo_json = .{ .rename_all = .SCREAMING_SNAKE_CASE };
        not_found,
        notfound,
    };
    const kept = comptime wireNames(Kept);
    try testing.expectEqualStrings("NOT_FOUND", kept[0]);
    try testing.expectEqualStrings("NOTFOUND", kept[1]);

    const Kebab = enum {
        pub const nilo_json = .{ .rename_all = .@"kebab-case" };
        not_found,
        notfound,
    };
    const kebab = comptime wireNames(Kebab);
    try testing.expectEqualStrings("not-found", kebab[0]);
    try testing.expectEqualStrings("notfound", kebab[1]);

    // camelCase drops the underscore too, and still keeps these two apart
    // because it shouts the letter after it.
    const Camel = enum {
        pub const nilo_json = .{ .rename_all = .camelCase };
        not_found,
        notfound,
    };
    const camel = comptime wireNames(Camel);
    try testing.expectEqualStrings("notFound", camel[0]);
    try testing.expectEqualStrings("notfound", camel[1]);

    // And a single value cannot collide with anything, which is the edge the
    // `i + 1 ..` slice has to get right.
    const One = enum {
        pub const nilo_json = .{ .rename_all = .lowercase };
        not_found,
    };
    try testing.expectEqualStrings("notfound", comptime wireNames(One)[0]);
}

test "an enum's choices come out renamed" {
    const Agg = enum {
        pub const nilo_json = .{ .rename_all = .SCREAMING_SNAKE_CASE };
        avg,
        p99,
        rate_per_second,
    };

    const names = comptime wireNames(Agg);
    try testing.expectEqualStrings("AVG", names[0]);
    try testing.expectEqualStrings("P99", names[1]);
    try testing.expectEqualStrings("RATE_PER_SECOND", names[2]);
}

// ---- reading ----

const Condition = union(enum) {
    pub const nilo_json = .{ .tag = "signal" };
    pub const jsonParse = parseFor(@This());

    metrics: struct { metric_name: []const u8, threshold: f64 },
    logs: struct { query: []const u8, count_over: u32 = 1 },
    queued,
};

fn read(comptime T: type, gpa: std.mem.Allocator, body: []const u8) !T {
    return std.json.parseFromSliceLeaky(T, gpa, body, .{});
}

test "an internally tagged union is read back into the variant its tag names" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const got = try read(Condition,
        gpa,
        \\{"signal":"metrics","metric_name":"system.cpu.utilization","threshold":0.9}
    );
    try testing.expectEqualStrings("metrics", @tagName(got));
    try testing.expectEqualStrings("system.cpu.utilization", got.metrics.metric_name);
    try testing.expectEqual(@as(f64, 0.9), got.metrics.threshold);
}

test "the tag does not have to come first" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    // This is the case that decides the whole shape of the reader: the variant
    // is not known until the discriminator turns up, and here two of its own
    // fields come before it.
    const got = try read(Condition,
        gpa,
        \\{"query":"level:error","count_over":5,"signal":"logs"}
    );
    try testing.expectEqualStrings("logs", @tagName(got));
    try testing.expectEqualStrings("level:error", got.logs.query);
    try testing.expectEqual(@as(u32, 5), got.logs.count_over);
}

test "a variant carrying nothing needs only its tag" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const got = try read(Condition, arena.allocator(),
        \\{"signal":"queued"}
    );
    try testing.expectEqualStrings("queued", @tagName(got));
}

test "a field with a default may be left out of a variant" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const got = try read(Condition, arena.allocator(),
        \\{"signal":"logs","query":"level:warn"}
    );
    try testing.expectEqual(@as(u32, 1), got.logs.count_over);
}

test "a tag naming no variant, and a body carrying no tag, are both refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    try testing.expectError(error.InvalidEnumTag, read(Condition, gpa,
        \\{"signal":"traces","span_name":"GET /users"}
    ));
    try testing.expectError(error.MissingField, read(Condition, gpa,
        \\{"query":"level:error"}
    ));
}

test "an unknown field inside a variant is still refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // The discriminator is an unknown field as far as the variant's own struct
    // is concerned, so reading one means allowing unknown fields — and then
    // putting the check back by hand. Without that this typo would be dropped
    // in silence, where the same typo outside a variant is a 400 naming it.
    try testing.expectError(error.UnknownField, read(Condition, arena.allocator(),
        \\{"signal":"logs","query":"level:error","cont_over":5}
    ));
}

test "a renamed enum is read back by the name it goes out under" {
    const Agg = enum {
        pub const nilo_json = .{ .rename_all = .SCREAMING_SNAKE_CASE };
        pub const jsonParse = parseFor(@This());

        avg,
        rate_per_second,
    };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    try testing.expectEqual(Agg.rate_per_second, try read(Agg, gpa,
        \\"RATE_PER_SECOND"
    ));
    // And the Zig spelling is not a second way in, because the wire name is
    // the only name there is.
    try testing.expectError(error.InvalidEnumTag, read(Agg, gpa,
        \\"rate_per_second"
    ));
}

test "a marked union survives a round trip through a struct" {
    const json = @import("json.zig");

    const Rule = struct { id: u32, condition: Condition };
    const rule = Rule{ .id = 3, .condition = .{ .logs = .{ .query = "level:error", .count_over = 5 } } };

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try json.write(&out.writer, rule);
    try testing.expectEqualStrings(
        \\{"id":3,"condition":{"signal":"logs","query":"level:error","count_over":5}}
    , out.written());

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const back = try read(Rule, arena.allocator(), out.written());
    try testing.expectEqual(@as(u32, 3), back.id);
    try testing.expectEqualStrings("level:error", back.condition.logs.query);
}

test "a variant with no payload is a tag on its own" {
    const Step = union(enum) {
        pub const nilo_json = .{ .tag = "step" };
        queued,
        running: struct { pid: u32 },
    };

    // The check is that this compiles at all: a void arm has no fields to
    // flatten and is not a mistake.
    const mark = comptime of(Step).?;
    try testing.expectEqualStrings("step", mark.tag.?);
}
