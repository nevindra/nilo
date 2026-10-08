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
//! reason as `nilo_openapi` ([ADR 016](../docs/adr/016-the-api-description-comes-from-the-signatures.md)):
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
const naming = @import("names.zig");

/// The declaration a type writes to say how its JSON is spelled.
pub const marker = "nilo_json";

/// The declaration a type writes to say it parses itself from request text
/// (ADR 113). `convert.zig` is the reader of it for a path param and a
/// query value, and re-exports this name; it is declared here because this
/// file is the one that hands `std.json` a reader, and `convert.zig` imports
/// the fail path, which this file may not.
pub const parse_marker = "nilo_parse";

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
    /// The names spelled one at a time, which win over `rename_all`
    /// ([ADR 168](../docs/adr/168-one-field-can-be-spelled-on-its-own.md)).
    renames: []const Rename = &.{},
    /// Whether a struct reading a request body skips a key it has no field for
    /// instead of refusing it (`.unknown_fields = .ignore`, ADR 168). Per type:
    /// a struct nested inside this one still answers for its own keys.
    ignores_unknown: bool = false,
    /// The status a body read into this type is refused with when it is JSON
    /// and not this type's shape (`.misfit = 422`), or null for the 400 every
    /// type answers. Read off the type the body is read into, and only that
    /// one ([ADR 251](../docs/adr/251-json-that-does-not-fit-can-be-a-422.md)).
    misfit: ?u16 = null,

    /// Whether the marker changes how any field is spelled.
    pub fn renamesFields(self: Mark) bool {
        return self.rename_all != null or self.renames.len > 0;
    }
};

/// One name and the spelling it goes out under.
pub const Rename = struct {
    field: []const u8,
    wire: []const u8,
};

/// Whether `T` carries the marker at all. Cheap enough to ask first, and it is
/// what keeps every path below out of the way of a type that never asked.
pub fn marked(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, marker),
        else => false,
    };
}

/// The declaration a type writes to say it is exactly another type, held
/// under `.value` — a **document**
/// ([ADR 163](../docs/adr/163-a-document-is-its-value.md)).
pub const document_marker = "nilo_json_of";

/// What `T` is a document of: `pub const nilo_json_of = Inner;` beside
/// `value: Inner`, or null when `T` says no such thing.
///
/// `sql.Json(T)` is one — a `jsonb` column parsed into a struct of the
/// caller's own — and its `jsonStringify` is one line, `jw.write(self.value)`.
/// That is a type saying *I am exactly a `T`* in the sense a `Uuid` says *I am
/// exactly a string*, and for a writer it is the stronger promise: a scalar is
/// handed to `std.json` whole because nothing can be walked inside it, while a
/// `T` is a shape the generated writer can walk itself — and honour a
/// `rename_all` inside. So `json.write` writes a document as its value, and
/// `openapi.schemaWithin` describes it as one, rather than either treating the
/// wrapper as a wall the way ADR 148 drew the line for a type that writes
/// itself and says nothing.
///
/// Read by name rather than by type for the reason every marker here is: the
/// type declaring it lives in a module `http/` may not import (ADR 038).
pub fn documentOf(comptime T: type) ?type {
    comptime {
        if (@typeInfo(T) != .@"struct") return null;
        if (!@hasDecl(T, document_marker)) return null;
        const said = @field(T, document_marker);
        if (@TypeOf(said) != type) @compileError(
            "nilo: `" ++ naming.of(T) ++ "`'s `" ++ document_marker ++ "` is not a type.\n" ++
                "  A document says which type it holds: `pub const " ++ document_marker ++
                " = Payload;` beside `value: Payload`.",
        );
        if (!@hasField(T, "value") or @FieldType(T, "value") != said) @compileError(
            "nilo: `" ++ naming.of(T) ++ "` says it is a `" ++ naming.of(said) ++ "` (`" ++
                document_marker ++ "`) and has no `value: " ++ naming.of(said) ++ "` to be " ++
                "written as.\n" ++
                "  A document is written as its `value`, so the field has to be there and " ++
                "has to be that type.",
        );
        return said;
    }
}

/// `T.nilo_json`, read field by field and checked, or null if there is none.
///
/// Every way of writing this wrong gets a sentence here rather than a compiler
/// message pointing at a line of nilo's — the same reason `toldOf` in
/// `openapi.zig` reads `nilo_openapi` by hand (ADR 026).
pub fn of(comptime T: type) ?Mark {
    comptime {
        if (!marked(T)) return null;

        const said = @field(T, marker);
        const Said = @TypeOf(said);
        const info = @typeInfo(Said);
        if (info != .@"struct") @compileError(
            "nilo: `" ++ naming.of(T) ++ "`'s `" ++ marker ++ "` is a " ++ naming.of(Said) ++
                ", and it says how this type's JSON is spelled, so it is written as a struct.\n" ++
                "    pub const " ++ marker ++ " = .{ .tag = \"signal\" };",
        );

        var mark = Mark{};
        for (info.@"struct".fields) |f| {
            if (std.mem.eql(u8, f.name, "tag")) {
                mark.tag = said.tag;
            } else if (std.mem.eql(u8, f.name, "rename_all")) {
                mark.rename_all = caseOf(T, said.rename_all);
            } else if (std.mem.eql(u8, f.name, "rename")) {
                mark.renames = renamesOf(T, said.rename);
            } else if (std.mem.eql(u8, f.name, "unknown_fields")) {
                mark.ignores_unknown = unknownFieldsOf(T, said.unknown_fields);
            } else if (std.mem.eql(u8, f.name, "misfit")) {
                mark.misfit = misfitOf(T, said.misfit);
            } else @compileError(
                "nilo: `" ++ naming.of(T) ++ "`'s `" ++ marker ++ "` has a field `" ++ f.name ++
                    "`, which is not something it can say.\n" ++
                    "  A marker says five things: `tag`, the key the variant's name goes under; " ++
                    "`rename_all`, how every name is spelled on the wire; `rename`, the ones " ++
                    "spelled on their own; `unknown_fields`, whether a body key the struct " ++
                    "has no field for is skipped; and `misfit`, the status of a body that is " ++
                    "JSON and not this type's shape.\n" ++
                    "    pub const " ++ marker ++ " = .{ .tag = \"signal\", .rename_all = .camelCase, " ++
                    ".rename = .{ .amount_minor = \"amountMinor\" } };",
            );
        }

        // Asked once every field is read, because whether a union names its
        // tag can come after the `misfit` that needs it.
        if (mark.misfit != null) misfitBelongs(T, mark);

        if (mark.tag == null and !mark.renamesFields() and !mark.ignores_unknown and mark.misfit == null) @compileError(
            "nilo: `" ++ naming.of(T) ++ "`'s `" ++ marker ++ "` is empty, so it says nothing " ++
                "about this type's JSON and nothing changes.\n" ++
                "  Either say what it is for, or take the declaration off:\n" ++
                "    pub const " ++ marker ++ " = .{ .tag = \"signal\" };        // a tagged union\n" ++
                "    pub const " ++ marker ++ " = .{ .rename_all = .camelCase }; // a cased enum\n" ++
                "    pub const " ++ marker ++ " = .{ .unknown_fields = .ignore }; // a body struct that skips unknown keys\n" ++
                "    pub const " ++ marker ++ " = .{ .misfit = 422 };              // a body struct whose wrong shape is a 422",
        );

        if (mark.tag) |key| checkTag(T, key);
        if (mark.renamesFields()) checkRenames(T, mark);
        return mark;
    }
}

/// `said.unknown_fields`, which is `.ignore` or it is refused: an unknown key
/// is a 400 by default (ADR 016) and the marker is the one way to say the
/// opposite, so the default has no spelling of its own to write out. Only a
/// struct has keys of its own to skip; a union reads the keys of the variant's
/// payload struct, which is where the marker goes
/// ([ADR 168](../docs/adr/168-one-field-can-be-spelled-on-its-own.md)).
fn unknownFieldsOf(comptime T: type, comptime said: anytype) bool {
    comptime {
        const Said = @TypeOf(said);
        if (Said != @TypeOf(.enum_literal)) @compileError(
            "nilo: `" ++ naming.of(T) ++ "`'s `unknown_fields` is a " ++ naming.of(Said) ++
                ", and it says what is done with a key the struct has no field for, which is " ++
                "written as `.ignore`.\n" ++
                "    pub const " ++ marker ++ " = .{ .unknown_fields = .ignore };",
        );
        const name = @tagName(said);
        if (std.mem.eql(u8, name, "refuse")) @compileError(
            "nilo: `" ++ naming.of(T) ++ "` says `.unknown_fields = .refuse`, which is what every " ++
                "type already does with a key it has no field for, so it would change nothing.\n" ++
                "  Take the entry off, or say `.ignore` to skip the key instead.",
        );
        if (!std.mem.eql(u8, name, "ignore")) @compileError(
            "nilo: `" ++ naming.of(T) ++ "` says `.unknown_fields = ." ++ name ++ "`, which is not " ++
                "something it can do with a key it has no field for.\n" ++
                "  The one choice is `.ignore`; refusing is what a type does when it says nothing.",
        );
        switch (@typeInfo(T)) {
            .@"struct" => {},
            .@"enum" => @compileError(
                "nilo: `" ++ naming.of(T) ++ "` says `.unknown_fields`, and it is an enum, which " ++
                    "is read from one string and has no keys to skip.\n" ++
                    "  `unknown_fields` belongs on the struct a body is read into.",
            ),
            .@"union" => @compileError(
                "nilo: `" ++ naming.of(T) ++ "` says `.unknown_fields`, and it is a union, whose " ++
                    "keys are the ones its variant's struct has.\n" ++
                    "  Put `pub const " ++ marker ++ " = .{ .unknown_fields = .ignore };` on the " ++
                    "struct each variant carries that should skip them.",
            ),
            else => @compileError(
                "nilo: `" ++ naming.of(T) ++ "` says `.unknown_fields`, and it is a " ++
                    @tagName(@typeInfo(T)) ++ ", which has no keys to skip.",
            ),
        }
        return true;
    }
}

/// `said.misfit`, which is 422 or it is refused. A body that is JSON and not
/// this type's shape is a 400 by default, like every other request that does
/// not fit (ADR 034), and the only other answer for it is the one RFC 9110
/// §15.5.21 defines for exactly that body: the syntax is right and the content
/// cannot be processed. So the marker is a number, the one a client contract
/// states, and it has one value
/// ([ADR 251](../docs/adr/251-json-that-does-not-fit-can-be-a-422.md)).
fn misfitOf(comptime T: type, comptime said: anytype) u16 {
    comptime {
        const Said = @TypeOf(said);
        switch (@typeInfo(Said)) {
            .comptime_int, .int => {},
            else => @compileError(
                "nilo: `" ++ naming.of(T) ++ "`'s `misfit` is a " ++ naming.of(Said) ++
                    ", and it is the status a body that is JSON and not this type's shape is " ++
                    "refused with, which is written as a number.\n" ++
                    "    pub const " ++ marker ++ " = .{ .misfit = 422 };",
            ),
        }
        if (said == 400) @compileError(
            "nilo: `" ++ naming.of(T) ++ "` says `.misfit = 400`, which is what every type already " ++
                "answers for a body that is JSON and not its shape, so it would change nothing.\n" ++
                "  Take the entry off, or say `.misfit = 422` to answer such a body the way " ++
                "RFC 9110 names it.",
        );
        if (said != 422) @compileError(
            "nilo: `" ++ naming.of(T) ++ "` says `.misfit = " ++ std.fmt.comptimePrint("{d}", .{said}) ++
                "`, and a body that is JSON and not this type's shape is a 400 or a 422, nothing else.\n" ++
                "  422 is what RFC 9110 (section 15.5.21) gives content whose syntax is right and which " ++
                "cannot be processed, and 400, the default, is every other request that does not fit. " ++
                "Say `.misfit = 422`, or take the entry off.",
        );
        return said;
    }
}

/// `.misfit` is said by the type a body is read into, so it goes where nilo
/// reads a body's fields and names what did not fit: a struct, or a union
/// that names its tag. An externally tagged union is read by `std.json`
/// itself, which says nothing about why, so nilo never learns whether the
/// body was JSON of the wrong shape.
fn misfitBelongs(comptime T: type, comptime mark: Mark) void {
    comptime switch (@typeInfo(T)) {
        .@"struct" => {},
        .@"union" => if (mark.tag == null) @compileError(
            "nilo: `" ++ naming.of(T) ++ "` says `.misfit`, and it is a union with no `.tag`, " ++
                "which `std.json` reads by itself, so nilo cannot tell JSON of the wrong shape " ++
                "from anything else it refuses.\n" ++
                "  Give the union a `.tag`, or read the body into a struct that holds it:\n" ++
                "    pub const " ++ marker ++ " = .{ .tag = \"kind\", .misfit = 422 };",
        ),
        .@"enum" => @compileError(
            "nilo: `" ++ naming.of(T) ++ "` says `.misfit`, and it is an enum, which is read " ++
                "from one string and is never a body of its own.\n" ++
                "  `misfit` belongs on the struct a body is read into.",
        ),
        else => @compileError(
            "nilo: `" ++ naming.of(T) ++ "` says `.misfit`, and it is a " ++
                @tagName(@typeInfo(T)) ++ ", which a body is never read into.",
        ),
    };
}

/// The status `T` answers a body that is JSON and not its shape with, when it
/// chose one, or null for the 400 every other type answers. Null for a type
/// with no marker before anything else is asked, so the reader of a body that
/// says nothing compiles exactly as it did.
pub fn misfitStatus(comptime T: type) ?u16 {
    comptime {
        if (!marked(T)) return null;
        @setEvalBranchQuota(20_000);
        return of(T).?.misfit;
    }
}

/// Whether `T` skips a key it has no field for when it is read from a body.
/// Asked by the reader for every struct it walks, so it is the marker's one
/// declaration looked up first and nothing more for the type that has none.
pub fn ignoresUnknown(comptime T: type) bool {
    comptime {
        if (@typeInfo(T) != .@"struct" or !@hasDecl(T, marker)) return false;
        @setEvalBranchQuota(20_000);
        return of(T).?.ignores_unknown;
    }
}

/// Whether `T`, or anything it holds, skips unknown keys. What decides that a
/// body read into `T` is bounded in depth even when `T` cannot nest without
/// bound itself: a skipped value is read by no field, so nothing else holds
/// it to a depth (ADR 226).
pub fn ignoresUnknownWithin(comptime T: type) bool {
    comptime {
        @setEvalBranchQuota(100_000);
        return ignoringWithin(T, &.{});
    }
}

fn ignoringWithin(comptime T: type, comptime path: []const type) bool {
    comptime {
        for (path) |seen| if (seen == T) return false;
        const deeper = path ++ [_]type{T};
        switch (@typeInfo(T)) {
            .@"struct" => |s| {
                if (ignoresUnknown(T)) return true;
                for (s.fields) |f| if (ignoringWithin(f.type, deeper)) return true;
            },
            .@"union" => |u| for (u.fields) |f| if (ignoringWithin(f.type, deeper)) return true,
            .optional => |o| return ignoringWithin(o.child, deeper),
            .pointer => |p| return ignoringWithin(p.child, deeper),
            .array => |a| return ignoringWithin(a.child, deeper),
            else => {},
        }
        return false;
    }
}

/// `said.rename_all` — an enum literal, because the marker is plain data and
/// the type writing it may not be able to name `Case`.
fn caseOf(comptime T: type, comptime said: anytype) Case {
    comptime {
        const name = @tagName(said);
        if (std.mem.eql(u8, name, "snake_case")) @compileError(
            "nilo: `" ++ naming.of(T) ++ "` asks for `.rename_all = .snake_case`, which is what a " ++
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
                "nilo: `" ++ naming.of(T) ++ "` asks for `.rename_all = ." ++ name ++
                    "`, which is not a case nilo writes.\n" ++
                    "  The ones it does: " ++ known ++ ".",
            );
        }
        return @field(Case, name);
    }
}

/// `said.rename` — a struct of names, each the field it renames, read and
/// checked against the type: every name has to be one of its fields, every
/// spelling has to be text, and a spelling that is the name itself changes
/// nothing and is refused the way `.snake_case` is
/// ([ADR 168](../docs/adr/168-one-field-can-be-spelled-on-its-own.md)).
fn renamesOf(comptime T: type, comptime said: anytype) []const Rename {
    comptime {
        const Said = @TypeOf(said);
        if (@typeInfo(Said) != .@"struct" or @typeInfo(Said).@"struct".is_tuple) @compileError(
            "nilo: `" ++ naming.of(T) ++ "`'s `.rename` is a " ++ naming.of(Said) ++ ", and it " ++
                "names the fields that are spelled on their own, so it is written as a struct " ++
                "of them.\n" ++
                "    pub const " ++ marker ++ " = .{ .rename = .{ .amount_minor = \"amountMinor\" } };",
        );
        const what = switch (@typeInfo(T)) {
            .@"enum" => "value",
            .@"union" => "variant",
            .@"struct" => "field",
            else => @compileError(
                "nilo: `" ++ naming.of(T) ++ "` says `.rename`, and it is a " ++ @tagName(@typeInfo(T)) ++
                    ", which has no fields to spell.",
            ),
        };
        var out: []const Rename = &.{};
        for (@typeInfo(Said).@"struct".fields) |f| {
            if (!@hasField(T, f.name)) @compileError(
                "nilo: `" ++ naming.of(T) ++ "` renames a " ++ what ++ " `" ++ f.name ++ "` it does " ++
                    "not have.\n" ++
                    "  `.rename` names this type's own " ++ what ++ "s, spelled as they are written: " ++
                    "`.{ .amount_minor = \"amountMinor\" }`.",
            );
            const spelling = @field(said, f.name);
            if (!isText(@TypeOf(spelling))) @compileError(
                "nilo: `" ++ naming.of(T) ++ "` renames `" ++ f.name ++ "` to a " ++
                    naming.of(@TypeOf(spelling)) ++ ", and a spelling is text.\n" ++
                    "    .rename = .{ ." ++ f.name ++ " = \"amountMinor\" }",
            );
            const wire_name: []const u8 = spelling;
            if (wire_name.len == 0) @compileError(
                "nilo: `" ++ naming.of(T) ++ "` renames `" ++ f.name ++ "` to the empty string, " ++
                    "so the value would go out under a key with no name.",
            );
            if (std.mem.eql(u8, wire_name, f.name)) @compileError(
                "nilo: `" ++ naming.of(T) ++ "` renames `" ++ f.name ++ "` to \"" ++ f.name ++
                    "\", which is what it is already called, so it would change nothing.\n" ++
                    "  Take the entry off, or spell it differently.",
            );
            out = out ++ [_]Rename{.{ .field = f.name, .wire = wire_name }};
        }
        return out;
    }
}

fn isText(comptime S: type) bool {
    return switch (@typeInfo(S)) {
        .pointer => |p| switch (p.size) {
            .slice => p.child == u8,
            .one => @typeInfo(p.child) == .array and @typeInfo(p.child).array.child == u8,
            else => false,
        },
        else => false,
    };
}

/// A `tag` is a claim about a union, so it is checked against one.
fn checkTag(comptime T: type, comptime key: []const u8) void {
    comptime {
        const info = @typeInfo(T);
        if (info != .@"union") @compileError(
            "nilo: `" ++ naming.of(T) ++ "` says `.tag = \"" ++ key ++ "\"`, which puts the name of " ++
                "the live variant into the JSON — and this is a " ++ @tagName(info) ++ ", which has no variants.\n" ++
                "  `tag` belongs on a `union(enum)`. On anything else the marker says only `rename_all`.",
        );
        if (info.@"union".tag_type == null) @compileError(
            "nilo: `" ++ naming.of(T) ++ "` says `.tag = \"" ++ key ++ "\"` and is an untagged union, " ++
                "so nothing in it knows which variant is live and there is no name to write.\n" ++
                "  Write it as `union(enum)` and nilo can send and read it.",
        );
        if (key.len == 0) @compileError(
            "nilo: `" ++ naming.of(T) ++ "`'s `.tag` is the empty string, so the variant's name would " ++
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
                "nilo: `" ++ naming.of(T) ++ "`'s variant `" ++ arm.name ++ "` carries a " ++
                    naming.of(Payload) ++ ", and an internally tagged union writes the variant's " ++
                    "fields beside the tag — so the variant has to have fields.\n" ++
                    "  Give it a struct of its own, or leave the variant empty (`" ++ arm.name ++
                    ",`) to send `{\"" ++ key ++ "\":\"" ++ arm.name ++ "\"}` on its own.",
            );
            // Compared against the name the field goes out under rather than
            // the one it is written as, because a payload struct may rename its
            // own fields (ADR 148) — and it is the wire spelling that would
            // land on the tag's key.
            for (payload.@"struct".fields, wireNames(Payload)) |f, on_the_wire| {
                if (std.mem.eql(u8, on_the_wire, key)) @compileError(
                    "nilo: `" ++ naming.of(T) ++ "`'s `.tag` is \"" ++ key ++ "\" and its variant `" ++
                        arm.name ++ "` already has a field called `" ++ f.name ++ "`" ++
                        (if (std.mem.eql(u8, f.name, on_the_wire)) "" else ", which goes out as \"" ++
                            on_the_wire ++ "\"") ++ ", so that key would " ++
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
/// On a struct it is the same mistake with the same shape: two fields under one
/// key means the object carries that key twice, and which one a reader takes is
/// its business ([ADR 148](../docs/adr/148-a-field-name-is-a-spelling-too.md)).
///
/// `O(n²)` over the names the type already produces, all of it while
/// compiling, on a path that never reaches a binary. A union of eight variants
/// is 28 comparisons of short literals, once.
///
/// **Each name is spelled once, and the check sizes its own branch budget**
/// ([ADR 126](../docs/adr/126-a-check-pays-for-its-own-branches.md)). As
/// first written the inner loop called `wire` on both names of every pair —
/// `n(n−1)/2` pairs, two names, a loop over every character building a
/// comptime string — and a Row of **ten** snake_case fields was `evaluation
/// exceeded 1000 backwards branches` pointing at `std.ascii`, before the
/// writer had run at all. Ten is not a wide table: the port that hit it had
/// `staff` at ten and `deals` past that, and `rename_all` covered its small
/// responses and not the ones a list screen is made of. Spelling each name
/// once takes it from `n²·len` to `n·len + n²`, and the quota below is
/// generous rather than exact for the reason `app.zig`'s `checkName` gives:
/// it is a ceiling on the caller's whole evaluation, and nilo's own walk
/// must never be the thing that runs out.
fn checkRenames(comptime T: type, comptime m: Mark) void {
    comptime {
        const fields = switch (@typeInfo(T)) {
            .@"enum" => |e| e.fields,
            .@"union" => |u| u.fields,
            // A struct renames its own fields and nothing else — the payload
            // struct of a renamed *variant* is still left alone, which is the
            // line `json.zig`'s own test names (ADR 148).
            .@"struct" => |s| s.fields,
            else => return,
        };
        var bytes: usize = 0;
        var longest: usize = 0;
        for (fields) |f| {
            bytes += f.name.len;
            if (f.name.len > longest) longest = f.name.len;
        }
        @setEvalBranchQuota(10_000 + 4 * (bytes + fields.len * fields.len * (longest + 1) + m.renames.len * fields.len));

        const what = switch (@typeInfo(T)) {
            .@"enum" => "value",
            .@"union" => "variant",
            else => "field",
        };
        var spelled: [fields.len][]const u8 = undefined;
        for (fields, 0..) |f, i| spelled[i] = wire(f.name, m);
        for (fields, 0..) |a, i| {
            for (fields[i + 1 ..], i + 1..) |b, j| {
                if (!std.mem.eql(u8, spelled[i], spelled[j])) continue;
                // Which of the two markers put them there decides the advice.
                // A collision under `rename_all` alone is answered with the
                // cases that keep names apart; one a `.rename` entry caused is
                // answered by pointing at the entry.
                if (renamedOnItsOwn(m, a.name) or renamedOnItsOwn(m, b.name)) @compileError(
                    "nilo: `" ++ naming.of(T) ++ "` spells its " ++ what ++ "s `" ++ a.name ++
                        "` and `" ++ b.name ++ "` both as \"" ++ spelled[i] ++ "\" — one of them by " ++
                        "a `.rename` entry.\n" ++
                        "  Two of them under one name on the wire is not a spelling problem: a reader " ++
                        "takes whichever it meets first, which is declaration order, and nothing says so.\n" ++
                        "  Spell the entry differently, or rename the other one too.",
                );
                @compileError(
                    "nilo: `" ++ naming.of(T) ++ "` asks for `.rename_all = ." ++ @tagName(m.rename_all.?) ++
                        "`, and its " ++ what ++ "s `" ++ a.name ++ "` and `" ++ b.name ++
                        "` both come out as \"" ++ spelled[i] ++ "\".\n" ++
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

fn renamedOnItsOwn(comptime m: Mark, comptime name: []const u8) bool {
    comptime {
        for (m.renames) |r| if (std.mem.eql(u8, r.field, name)) return true;
        return false;
    }
}

/// How `name` is spelled on the wire under `mark`. A comptime string, so it
/// costs a literal rather than a conversion (`json.zig` writes it as part of
/// the same `writeAll` the punctuation is in).
pub fn wire(comptime name: []const u8, comptime mark: ?Mark) []const u8 {
    comptime {
        const m = mark orelse return name;
        // A name spelled on its own wins over the case (ADR 168).
        for (m.renames) |r| if (std.mem.eql(u8, r.field, name)) return r.wire;
        const c = m.rename_all orelse return name;
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
/// API description lists as an enum's choices, what the reader matches against,
/// and — since [ADR 148](../docs/adr/148-a-field-name-is-a-spelling-too.md) —
/// the keys a struct's own object carries.
pub fn wireNames(comptime T: type) []const []const u8 {
    comptime {
        const mark = of(T);
        var names: []const []const u8 = &.{};
        const fields = switch (@typeInfo(T)) {
            .@"enum" => |e| e.fields,
            .@"union" => |u| u.fields,
            .@"struct" => |s| s.fields,
            else => @compileError("nilo: `" ++ naming.of(T) ++ "` has no fields to name."),
        };
        // One evaluation spelling every name, so the budget is the bytes of
        // all of them — sized here for the reason `checkRenames` gives.
        var bytes: usize = 0;
        for (fields) |f| bytes += f.name.len;
        @setEvalBranchQuota(10_000 + 4 * (bytes + fields.len));
        for (fields) |f| names = names ++ [_][]const u8{wire(f.name, mark)};
        return names;
    }
}

/// The first struct at or inside `T` that renames its own fields, or null
/// ([ADR 148](../docs/adr/148-a-field-name-is-a-spelling-too.md)).
///
/// **What it is for: refusing one on the way *in*.** `rename_all` on a struct
/// is a write spelling — `json.write` sends the renamed keys and the API
/// description promises them — and `std.json` reads a body into the field names
/// as they are written. A type used for both would send `fullName` and refuse
/// to read it back, and nothing would say so until a client built from the
/// document got a 400 naming every field.
///
/// A *union* is not this, and neither is an enum: both read back through
/// `jsonParseFor`, which is the supported way in (ADR 016). Only a struct has
/// no reader, and only a struct is answered here.
///
/// Eight deep, the same ceiling `covers` and `schemaWithin` have and for the
/// same reason — a type holding a list of its own type has no bottom.
pub fn renamedFieldsWithin(comptime T: type) ?type {
    comptime {
        // This walk and `unreadableWithin` run inside the body slot's own
        // evaluation, and `of` reading `.rename` on every struct they pass
        // took a plain body over the default 1,000. Raised here because this
        // is where the work is asked for (ADR 126): eight deep over every
        // field is bounded by the type, and 20,000 is `typed.wrap`'s figure.
        @setEvalBranchQuota(20_000);
        return renamedWithin(T, 0);
    }
}

fn renamedWithin(comptime T: type, comptime depth: usize) ?type {
    comptime {
        if (depth >= 8) return null;
        switch (@typeInfo(T)) {
            .@"struct" => |s| {
                if (of(T)) |m| {
                    if (m.renamesFields()) return T;
                }
                for (s.fields) |f| {
                    if (renamedWithin(f.type, depth + 1)) |found| return found;
                }
                return null;
            },
            .@"union" => |u| {
                for (u.fields) |f| {
                    if (renamedWithin(f.type, depth + 1)) |found| return found;
                }
                return null;
            },
            .optional => |o| return renamedWithin(o.child, depth + 1),
            .array => |a| return renamedWithin(a.child, depth + 1),
            .pointer => |p| return switch (p.size) {
                .slice, .one => renamedWithin(p.child, depth + 1),
                else => null,
            },
            else => return null,
        }
    }
}

/// The first type at or inside `T` that parses itself and has not handed
/// `std.json` a reader, or null ([ADR 166](../docs/adr/166-a-body-field-that-parses-itself.md)).
///
/// A path param and a query value are read through `nilo_parse` by nilo; a
/// body is read by `std.json`, which reads a struct into its fields unless
/// the type carries `jsonParse`. A type that says it parses itself and does
/// not carry one would be read as its fields, which is the mistake this is
/// asked in order to refuse. Eight deep, for `renamedFieldsWithin`'s reason.
pub fn unreadableWithin(comptime T: type) ?type {
    comptime {
        // Sized for `renamedFieldsWithin`'s reason.
        @setEvalBranchQuota(20_000);
        return unreadable(T, 0);
    }
}

fn unreadable(comptime T: type, comptime depth: usize) ?type {
    comptime {
        if (depth >= 8) return null;
        switch (@typeInfo(T)) {
            .@"struct", .@"union", .@"enum", .@"opaque" => {
                // A type that parses itself is one value, so the walk stops
                // at it whether or not it has a reader; what is inside it is
                // its own. A `Patch(T)` and a tagged union are walked into,
                // because their readers hand the payload back to `std.json`.
                if (parsesItself(T)) return if (std.meta.hasFn(T, "jsonParse")) null else T;
            },
            else => {},
        }
        switch (@typeInfo(T)) {
            .@"struct" => |s| {
                for (s.fields) |f| {
                    if (unreadable(f.type, depth + 1)) |found| return found;
                }
                return null;
            },
            .@"union" => |u| {
                for (u.fields) |f| {
                    if (unreadable(f.type, depth + 1)) |found| return found;
                }
                return null;
            },
            .optional => |o| return unreadable(o.child, depth + 1),
            .array => |a| return unreadable(a.child, depth + 1),
            .pointer => |p| return switch (p.size) {
                .slice, .one => unreadable(p.child, depth + 1),
                else => null,
            },
            else => return null,
        }
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
pub fn parseFor(comptime T: type) ParserFor(T) {
    comptime {
        // A type that parses itself from text has said how it is read, and
        // it is the same reading a path param gets: the one string, handed
        // to `nilo_parse` ([ADR 166](../docs/adr/166-a-body-field-that-parses-itself.md)).
        if (parsesItself(T) and !marked(T)) return Parsed(T).parse;
        const m = of(T) orelse @compileError(
            "nilo: `" ++ naming.of(T) ++ "` asks for nilo's JSON reader and has no `" ++ marker ++
                "`, so there is nothing for the reader to do differently from `std.json`.\n" ++
                "  Say what its JSON looks like first, then hand the reader over:\n" ++
                "    pub const " ++ marker ++ " = .{ .tag = \"signal\" };\n" ++
                "    pub const jsonParse = nilo.jsonParseFor(@This());",
        );
        // Checked here rather than where it is used, so it fires on the line
        // somebody wrote instead of on the first request that carries one.
        //
        // A struct gets its own sentence, because since ADR 148 it is a thing
        // somebody can reasonably have written — a response type with
        // `rename_all` on it — and the answer is not "add a tag".
        if (m.tag == null and @typeInfo(T) == .@"struct") @compileError(
            "nilo: `" ++ naming.of(T) ++ "` hands nilo's JSON reader a `" ++ marker ++
                "` that only renames its fields, and renaming a struct's fields is a **write**" ++
                " spelling (ADR 148, ADR 168).\n" ++
                "  There is nothing for the reader to do differently: nilo writes the renamed" ++
                " keys and `std.json` reads the body into the field names as they are written.\n" ++
                "  Take the `jsonParse` line off, and keep this type for what goes out. A body" ++
                " coming in is its own struct, spelled the way the wire spells it.",
        );
        if (m.tag == null and @typeInfo(T) != .@"enum") @compileError(
            "nilo: `" ++ naming.of(T) ++ "` hands nilo's JSON reader a `" ++ marker ++
                "` that only renames, and it is a " ++ @tagName(@typeInfo(T)) ++ ".\n" ++
                "  Renaming a variant changes the key `std.json` looks for, which nilo cannot read " ++
                "back without a tag to find it by. Add one:\n" ++
                "    pub const " ++ marker ++ " = .{ .tag = \"kind\", .rename_all = … };",
        );
    }
    return Reader(T).parse;
}

/// The reader `parseFor` hands over: the marker's, or — for a type that
/// parses itself and carries no marker — the one that reads a string.
fn ParserFor(comptime T: type) type {
    comptime {
        if (parsesItself(T) and !marked(T)) return @TypeOf(Parsed(T).parse);
        return @TypeOf(Reader(T).parse);
    }
}

/// Whether `T` declares `nilo_parse`. The shape of the declaration is checked
/// where a path param or a query value is read (`convert.parsesItself`); by
/// the time a body is read the type has been through that.
fn parsesItself(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, parse_marker),
        else => false,
    };
}

/// The reader for a type that parses itself: one token, which is text or a
/// number — a bounded integer arrives as a JSON number and is still the
/// digits — handed to `nilo_parse`. Null from the type is `InvalidCharacter`,
/// which is what `std.fmt` answers for a digit that is not one; any other
/// kind of token is the wrong kind.
fn Parsed(comptime T: type) type {
    return struct {
        pub fn parse(
            gpa: std.mem.Allocator,
            source: anytype,
            options: std.json.ParseOptions,
        ) std.json.ParseError(@TypeOf(source.*))!T {
            const token = try source.nextAllocMax(gpa, .alloc_if_needed, options.max_value_len.?);
            const text = switch (token) {
                inline .string, .allocated_string, .number, .allocated_number => |slice| slice,
                else => return error.UnexpectedToken,
            };
            // An allocated token — a string with an escape in it — is not
            // freed: `gpa` is the request arena here, and a type that keeps
            // the text it was parsed from (a `nilo.Text`, ADR 193) points
            // at it for the rest of the request.
            return T.nilo_parse(text) orelse error.InvalidCharacter;
        }
    };
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
                //
                // **A stray `}` or `]` is peeked as what it is, and `skipValue`
                // is `unreachable` on both**, so a body such as
                // `[{"signal":"queued"},}]` would abort the process in
                // ReleaseFast. They and the end of the input are a syntax
                // error here, before anything skips.
                switch (try source.peekNextTokenType()) {
                    .object_end, .array_end, .end_of_document => return error.SyntaxError,
                    else => {},
                }
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

            // The whole object is walked rather than stopping at the first
            // discriminator, because a second one is refused: `std.json` refuses
            // a repeated key everywhere else, and a front end that keeps the
            // last one would see another variant than the one read here
            // (ADR 016). `json.parseLeaky` says which key on the way out.
            var found: ?[]const u8 = null;
            while (true) {
                const token = try scan.nextAllocMax(gpa, .alloc_if_needed, options.max_value_len.?);
                const name = switch (token) {
                    inline .string, .allocated_string => |slice| slice,
                    .object_end => break,
                    else => return error.UnexpectedToken,
                };
                if (!std.mem.eql(u8, name, key)) {
                    try scan.skipValue();
                    continue;
                }
                if (found != null) return error.DuplicateField;
                const value = try scan.nextAllocMax(gpa, .alloc_if_needed, options.max_value_len.?);
                found = switch (value) {
                    inline .string, .allocated_string => |slice| slice,
                    else => return error.UnexpectedToken,
                };
            }

            const arm = found orelse return error.MissingField;

            // The variant's own fields are read out of the same bytes, with the
            // discriminator among them — which is why unknown fields have to be
            // allowed here and are checked separately below.
            var inner = options;
            inner.ignore_unknown_fields = true;

            inline for (@typeInfo(T).@"union".fields, comptime wireNames(T)) |f, on_the_wire| {
                if (std.mem.eql(u8, arm, on_the_wire)) {
                    if (f.type == void) {
                        // A key beside a variant with no fields is a typo
                        // like any other, and was dropped in silence.
                        if (!options.ignore_unknown_fields) try refuseUnknown(void, gpa, span, options);
                        return @unionInit(T, f.name, {});
                    }
                    const payload = try @import("json.zig").parseLeaky(f.type, gpa, span, inner);
                    if (!options.ignore_unknown_fields and !comptime ignoresUnknown(f.type)) {
                        try refuseUnknown(f.type, gpa, span, options);
                    }
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
                if (comptime Payload != void) {
                    inline for (@typeInfo(Payload).@"struct".fields) |f| {
                        if (std.mem.eql(u8, name, f.name)) known = true;
                    }
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

test "a type that parses itself hands std.json the reading a path param gets" {
    const Sku = struct {
        letters: [3]u8,
        pub fn nilo_parse(text: []const u8) ?@This() {
            if (text.len != 3) return null;
            return .{ .letters = text[0..3].* };
        }
        pub const jsonParse = parseFor(@This());
    };
    const Bounded = struct {
        value: u8,
        pub fn nilo_parse(text: []const u8) ?@This() {
            const n = std.fmt.parseInt(u8, text, 10) catch return null;
            return if (n >= 1 and n <= 200) .{ .value = n } else null;
        }
        pub const jsonParse = parseFor(@This());
    };
    const Body = struct { sku: Sku, limit: Bounded, parent: ?Sku = null };

    const parsed = try std.json.parseFromSlice(Body, testing.allocator, "{\"sku\":\"ABC\",\"limit\":50}", .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("ABC", &parsed.value.sku.letters);
    try testing.expectEqual(@as(u8, 50), parsed.value.limit.value);
    try testing.expectEqual(@as(?Sku, null), parsed.value.parent);

    // Text the type refuses, a number out of its range, and the wrong kind
    // of value altogether — three refusals, and `ctx.zig` words each.
    try testing.expectError(error.InvalidCharacter, std.json.parseFromSlice(Body, testing.allocator, "{\"sku\":\"ABCD\",\"limit\":50}", .{}));
    try testing.expectError(error.InvalidCharacter, std.json.parseFromSlice(Body, testing.allocator, "{\"sku\":\"ABC\",\"limit\":500}", .{}));
    try testing.expectError(error.UnexpectedToken, std.json.parseFromSlice(Body, testing.allocator, "{\"sku\":[\"A\"],\"limit\":50}", .{}));
}

test "a name spelled on its own is spelled that way, whatever the case says" {
    const m = Mark{
        .rename_all = .camelCase,
        .renames = &.{.{ .field = "amount_minor", .wire = "amountMinorValue" }},
    };
    try testing.expectEqualStrings("amountMinorValue", comptime wire("amount_minor", m));
    try testing.expectEqualStrings("dueAt", comptime wire("due_at", m));

    // Read off a type, the entry and the case land in the same Mark, and an
    // enum's values are names too.
    const Level = enum {
        pub const nilo_json = .{ .rename_all = .UPPERCASE, .rename = .{ .very_high = "critical" } };
        low,
        very_high,
    };
    try testing.expectEqualStrings("LOW", comptime wireNames(Level)[0]);
    try testing.expectEqualStrings("critical", comptime wireNames(Level)[1]);
    try testing.expect(comptime of(Level).?.renamesFields());
}

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

/// A Row as wide as a real table: thirteen snake_case columns of a dozen
/// characters, which is the `projects` row of the port that reported it.
const WideRow = struct {
    pub const nilo_json = .{ .rename_all = .camelCase };

    project_id: u32,
    customer_name: []const u8,
    customer_code: []const u8,
    started_on_date: []const u8,
    finished_on_date: ?[]const u8,
    contract_value: u64,
    contract_currency: []const u8,
    owner_staff_id: u32,
    owner_full_name: []const u8,
    department_name: []const u8,
    status_label: []const u8,
    created_at_time: []const u8,
    updated_at_time: []const u8,
};

test "a renamed struct thirteen fields wide is a struct, not a branch budget" {
    // Ten fields was `evaluation exceeded 1000 backwards branches` pointing at
    // `std.ascii`, from the pair loop calling `wire` on both names of every
    // pair. Each name is spelled once now and the check sizes its own quota;
    // this is wide enough that the old shape would not compile.
    const names = comptime wireNames(WideRow);
    try testing.expectEqual(@as(usize, 13), names.len);
    try testing.expectEqualStrings("projectId", names[0]);
    try testing.expectEqualStrings("finishedOnDate", names[4]);
    try testing.expectEqualStrings("updatedAtTime", names[12]);
    // And `of` — which is what runs the collision check — is reached.
    try testing.expectEqual(Case.camelCase, comptime of(WideRow).?.rename_all.?);
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

test "a second discriminator is refused, wherever it sits and whatever it says" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectError(error.DuplicateField, read(
        Condition,
        a,
        "{\"signal\":\"metrics\",\"signal\":\"logs\",\"metric_name\":\"x\",\"threshold\":1}",
    ));
    try testing.expectError(error.DuplicateField, read(
        Condition,
        a,
        "{\"signal\":\"logs\",\"query\":\"q\",\"signal\":\"logs\"}",
    ));
    // One is still one.
    const only = try read(Condition, a, "{\"query\":\"q\",\"signal\":\"logs\"}");
    try testing.expectEqualStrings("q", only.logs.query);
}

test "an internally tagged union is read back into the variant its tag names" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const got = try read(Condition, gpa,
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
    const got = try read(Condition, gpa,
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
    const json_mod = @import("json.zig");

    const Rule = struct { id: u32, condition: Condition };
    const rule = Rule{ .id = 3, .condition = .{ .logs = .{ .query = "level:error", .count_over = 5 } } };

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try json_mod.write(&out.writer, rule);
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

const parseLeakyBody = @import("json.zig").parseLeaky;

test "a struct that says .ignore has a mark that says so, and one that does not, does not" {
    const Loose = struct {
        pub const nilo_json = .{ .unknown_fields = .ignore };
        id: u32,
    };
    const Cased = struct {
        pub const nilo_json = .{ .rename_all = .camelCase, .unknown_fields = .ignore };
        full_name: []const u8,
    };
    const Plain = struct { id: u32 };
    const Renamed = struct {
        pub const nilo_json = .{ .rename_all = .camelCase };
        full_name: []const u8,
    };

    try testing.expect(comptime of(Loose).?.ignores_unknown);
    try testing.expect(comptime of(Cased).?.ignores_unknown);
    try testing.expect(comptime of(Cased).?.rename_all.? == .camelCase);
    try testing.expect(!comptime of(Renamed).?.ignores_unknown);
    try testing.expect(comptime ignoresUnknown(Loose));
    try testing.expect(!comptime ignoresUnknown(Plain));
    try testing.expect(!comptime ignoresUnknown(Renamed));
    try testing.expect(!comptime ignoresUnknown(u32));
}

test "a struct that says .ignore skips the keys it has no field for, and only its own" {
    const Loose = struct {
        pub const nilo_json = .{ .unknown_fields = .ignore };
        id: u32,
    };
    const Tight = struct { id: u32 };
    const LooseOuter = struct {
        pub const nilo_json = .{ .unknown_fields = .ignore };
        inner: Tight,
    };
    const TightOuter = struct { inner: Loose };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const got = try parseLeakyBody(Loose, a, "{\"x\":{\"y\":[1,2]},\"id\":7,\"z\":null}", .{});
    try testing.expectEqual(@as(u32, 7), got.id);
    try testing.expectError(error.UnknownField, parseLeakyBody(Tight, a, "{\"id\":7,\"x\":1}", .{}));

    // The parent's choice is the parent's, in both directions.
    _ = try parseLeakyBody(LooseOuter, a, "{\"x\":1,\"inner\":{\"id\":1}}", .{});
    try testing.expectError(error.UnknownField, parseLeakyBody(LooseOuter, a, "{\"inner\":{\"id\":1,\"x\":1}}", .{}));
    _ = try parseLeakyBody(TightOuter, a, "{\"inner\":{\"id\":1,\"x\":1}}", .{});
    try testing.expectError(error.UnknownField, parseLeakyBody(TightOuter, a, "{\"x\":1,\"inner\":{\"id\":1}}", .{}));

    // Skipping a key is not skipping a mistake about one it knows.
    try testing.expectError(error.DuplicateField, parseLeakyBody(Loose, a, "{\"id\":1,\"x\":0,\"id\":2}", .{}));
    try testing.expectError(error.MissingField, parseLeakyBody(Loose, a, "{\"x\":0}", .{}));
}

test "a variant whose payload says .ignore skips unknown keys, and a sibling that does not refuses them" {
    const Either = union(enum) {
        pub const nilo_json = .{ .tag = "kind" };
        pub const jsonParse = parseFor(@This());

        loose: struct {
            pub const nilo_json = .{ .unknown_fields = .ignore };
            n: u8,
        },
        tight: struct { n: u8 },
    };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const got = try read(Either, a, "{\"kind\":\"loose\",\"n\":3,\"extra\":{\"k\":[1]}}");
    try testing.expectEqual(@as(u8, 3), got.loose.n);
    try testing.expectError(error.UnknownField, read(Either, a, "{\"kind\":\"tight\",\"n\":3,\"extra\":1}"));
}

test "a type that reaches an ignoring struct is asked to bound what it skips" {
    const Loose = struct {
        pub const nilo_json = .{ .unknown_fields = .ignore };
        id: u32,
    };
    const Holder = struct { items: []const ?Loose };
    const Plain = struct { items: []const u32 };
    const Node = struct { next: ?*const @This() = null };

    try testing.expect(comptime ignoresUnknownWithin(Loose));
    try testing.expect(comptime ignoresUnknownWithin(Holder));
    try testing.expect(!comptime ignoresUnknownWithin(Plain));
    // A type that reaches itself is the walk's own cycle, and ends it.
    try testing.expect(!comptime ignoresUnknownWithin(Node));
}

test "a type that says .misfit = 422 has a mark that says so, and every other type answers nothing" {
    const Search = struct {
        pub const nilo_json = .{ .misfit = 422 };
        start: []const u8,
    };
    const Loose = struct {
        pub const nilo_json = .{ .unknown_fields = .ignore, .misfit = 422 };
        start: []const u8,
    };
    const Tagged = union(enum) {
        pub const nilo_json = .{ .misfit = 422, .tag = "kind" };
        on: struct { at: u32 },
        off,
    };
    const Renamed = struct {
        pub const nilo_json = .{ .rename_all = .camelCase };
        full_name: []const u8,
    };
    const Plain = struct { start: []const u8 };

    try testing.expectEqual(@as(?u16, 422), comptime misfitStatus(Search));
    try testing.expectEqual(@as(?u16, 422), comptime misfitStatus(Loose));
    try testing.expect(comptime of(Loose).?.ignores_unknown);
    // The tag can come after the `misfit` that needs it.
    try testing.expectEqual(@as(?u16, 422), comptime misfitStatus(Tagged));
    try testing.expectEqual(@as(?u16, null), comptime misfitStatus(Renamed));
    try testing.expectEqual(@as(?u16, null), comptime misfitStatus(Plain));
    try testing.expectEqual(@as(?u16, null), comptime misfitStatus(u32));
}
