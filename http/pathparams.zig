//! Path params read by name, `Path(T)` (ADR 002, ADR 015).
//!
//! ```zig
//! const Member = struct { org: u32, id: u32 };
//!
//! fn member(db: *Db, p: nilo.Path(Member)) !?User { ... p.value.org ... }
//! app.get("/orgs/:org/members/:id", member);
//! ```
//!
//! Zig keeps no argument names, so a bare `fn member(id: u32, org: u32)` on
//! `/orgs/:org/members/:id` would read the two ids swapped, compile, and run a
//! tenant-scoped query with the wrong tenant. **A struct keeps its field
//! names**, so the struct is the route's params: each field is the `:name` of
//! the pattern (a trailing wildcard is `@"*"`), its type is what the text
//! becomes, and the compiler holds the two together. The positional form
//! stays only where it cannot be ambiguous, a pattern with one param.
//!
//! **Zero cost for the routes that ask, and for the ones that do not.** The
//! slot of each field in the matched route's params is worked out while
//! compiling from its name, so a typed handler reads `c._params[i]` and
//! compares no string. A resolver is not tied to one route (a middleware
//! reaches it through `c.resolve(T)`), so it reads by name at run time, and a
//! name the matched route lacks is a 500 naming the resolver, the param and
//! the route, never a panic. `readByName` is the one function that does it,
//! so a `listen()`-time check can reuse the lookup later.

const std = @import("std");
const naming = @import("names.zig");
const convert_mod = @import("convert.zig");
const ctx_mod = @import("ctx.zig");
const router = @import("router.zig");
const fail = @import("fail.zig");
const str_mod = @import("nilo_core");

const Ctx = ctx_mod.Ctx;
const Str = str_mod.Str;

/// The declaration a `Path(T)` carries, named the way `nilo_query` is.
pub const marker = "nilo_path";

/// The path params of a route, read into a struct of your own, by name.
///
/// ```zig
/// const Member = struct { org: u32, id: u32 };
/// fn member(p: nilo.Path(Member)) !?User { ... p.value.org, p.value.id ... }
/// ```
///
/// Field names are the pattern's `:names`, and the field types are anything a
/// path param can be: a number, a `bool`, an enum, a `Str`, a type carrying
/// `nilo_parse`. A field that names no param of the route, a param with no
/// field, and an optional field all stop compilation with a sentence naming
/// the route.
pub fn Path(comptime T: type) type {
    return struct {
        pub const nilo_path = T;
        /// What a nilo compile error calls this type, which is the name the
        /// reader's own import line gives it (ADR 074).
        pub const nilo_type_name = "nilo.Path(" ++ naming.of(T) ++ ")";

        value: T,
    };
}

/// Whether `P` is a `Path(T)`.
pub fn isPath(comptime P: type) bool {
    return switch (@typeInfo(P)) {
        .@"struct" => @hasDecl(P, marker),
        else => false,
    };
}

/// The name of everything the pattern captures, in order of appearance:
/// each `:param`, and a trailing `*` under the name `"*"`.
pub fn namesOf(comptime pattern: []const u8) []const []const u8 {
    comptime {
        var names: []const []const u8 = &.{};
        var segs = std.mem.splitScalar(u8, pattern, '/');
        while (segs.next()) |s| {
            if (s.len > 1 and s[0] == ':') names = names ++ [_][]const u8{s[1..]};
            if (std.mem.eql(u8, s, router.wildcard)) names = names ++ [_][]const u8{router.wildcard};
        }
        return names;
    }
}

/// How a param is spelled as a struct field: `@"*"` for the wildcard.
pub fn fieldSpelling(comptime name: []const u8) []const u8 {
    comptime {
        for (name) |ch| {
            if (!std.ascii.isAlphanumeric(ch) and ch != '_') return "@\"" ++ name ++ "\"";
        }
        return name;
    }
}

fn indexOf(comptime names: []const []const u8, comptime name: []const u8) ?usize {
    comptime {
        for (names, 0..) |n, i| if (std.mem.eql(u8, n, name)) return i;
        return null;
    }
}

fn join(comptime parts: []const []const u8, comptime separator: []const u8) []const u8 {
    comptime {
        var result: []const u8 = "";
        for (parts, 0..) |p, i| result = result ++ (if (i == 0) "" else separator) ++ p;
        return result;
    }
}

/// `:org, :id`, or "no path params" for a route with none.
fn listed(comptime names: []const []const u8) []const u8 {
    comptime {
        if (names.len == 0) return "no path params";
        var out: []const u8 = "";
        for (names, 0..) |n, i| out = out ++ (if (i == 0) "" else ", ") ++ ":" ++ n;
        return out;
    }
}

/// The struct to write for a route, from the types known so far, in pattern
/// order, with `nilo.Str` where nothing is known. The fix a refusal writes.
pub fn suggestion(
    comptime names: []const []const u8,
    comptime known: []const type,
) []const u8 {
    comptime {
        var out: []const u8 = "nilo.Path(struct { ";
        for (names, 0..) |n, i| {
            const T = if (i < known.len) naming.of(known[i]) else "nilo.Str";
            out = out ++ (if (i == 0) "" else ", ") ++ fieldSpelling(n) ++ ": " ++ T;
        }
        return out ++ " })";
    }
}

/// The shape of the struct, whatever route it is on: a struct with at least
/// one field, no optionals, every field something path text can become.
/// `what` opens the sentence: "the `Path(X)` on route \"/a/:b\"".
pub fn checkShape(comptime T: type, comptime what: []const u8) void {
    comptime {
        const info = switch (@typeInfo(T)) {
            .@"struct" => |s| s,
            else => @compileError(
                "nilo: " ++ what ++ " is read into " ++ naming.of(T) ++ ", which is not a struct.\n" ++
                    "  Path params are read into a struct: one field per `:name` of the pattern.",
            ),
        };
        if (info.field_names.len == 0) @compileError(
            "nilo: " ++ what ++ " has no fields, so it would read nothing.\n" ++
                "  Add one field per path param: `id: u32`.",
        );
        for (info.field_names, info.field_types) |f_name, f_type| {
            if (@typeInfo(f_type) == .optional) @compileError(
                "nilo: the field `" ++ f_name ++ ": " ++ naming.of(f_type) ++ "` of " ++ what ++
                    " is optional.\n" ++
                    "  A path param on a route that matched is always present, so an optional " ++
                    "means nothing here. The thing that may be absent is a query param: " ++
                    "`nilo.Query(T)`.",
            );
            if (!convert_mod.convertible(f_type)) @compileError(
                "nilo: the field `" ++ f_name ++ ": " ++ naming.of(f_type) ++ "` of " ++ what ++
                    " is not something a path param can become.\n" ++
                    "  A path param arrives as text, so a field is a `nilo.Str`, a number, a " ++
                    "`bool`, an enum, or a type that parses itself with `nilo_parse`.",
            );
        }
    }
}

/// Hold the struct against the route: every field names a param of the
/// pattern, and, when `covers_all`, every param of the pattern has a field.
/// A resolver's struct is a subset by design, so it passes `false`.
pub fn checkAgainst(
    comptime T: type,
    comptime pattern: []const u8,
    comptime what: []const u8,
    comptime covers_all: bool,
) void {
    comptime {
        const names = namesOf(pattern);
        const info = @typeInfo(T).@"struct";

        for (info.field_names, info.field_types) |f_name, f_type| {
            if (indexOf(names, f_name) != null) continue;
            // Cheap suggestion: when exactly one param of the route has no
            // field, that is almost certainly the one meant.
            var spare: ?[]const u8 = null;
            var spares: usize = 0;
            for (names) |n| {
                if (@hasField(T, n)) continue;
                spare = n;
                spares += 1;
            }
            @compileError(
                "nilo: the field `" ++ f_name ++ ": " ++ naming.of(f_type) ++ "` of " ++ what ++
                    " names no path param of route \"" ++ pattern ++ "\", which has " ++
                    listed(names) ++ ".\n" ++
                    (if (spares == 1) "  Did you mean `" ++ fieldSpelling(spare.?) ++ "`? " else "  ") ++
                    "A field is read by its name, so it has to be spelled like the `:name` in " ++
                    "the pattern.",
            );
        }

        if (!covers_all) return;
        for (names) |n| {
            if (@hasField(T, n)) continue;
            @compileError(
                "nilo: the route \"" ++ pattern ++ "\" has the path param :" ++ n ++ ", and " ++
                    what ++ " has no field `" ++ fieldSpelling(n) ++ "` for it.\n" ++
                    "  Every param of the pattern gets a field, or ask for a `*Ctx` and read the " ++
                    "ones you leave out with `c.param(\"" ++ n ++ "\")`.",
            );
        }
    }
}

/// Read every field of `T` from the matched route by its position, which was
/// worked out while compiling. A typed handler's way in.
pub fn read(comptime T: type, comptime pattern: []const u8, c: *const Ctx) !T {
    const names = comptime namesOf(pattern);
    const info = @typeInfo(T).@"struct";
    var out: T = undefined;
    inline for (info.field_names, info.field_types) |f_name, F| {
        const at = comptime indexOf(names, f_name).?;
        if (at >= c._params.len) return fail.internal(
            "path param :{s} was not filled in by the router",
            .{f_name},
        );
        const p = c._params[at];
        std.debug.assert(std.mem.eql(u8, p.name, f_name));
        @field(out, f_name) = try convert_mod.convert(F, .query, Str.fromRequest(p.value, c._lifetime), ":" ++ f_name);
    }
    return out;
}

/// Whether `pattern` captures `name`, at run time: a `:name` segment, or the
/// trailing `*` as `"*"`. `listen()`'s way to hold a typed middleware's
/// `Path(T)` against each route it covers (ADR 008), the run-time twin of
/// `namesOf`.
pub fn captures(pattern: []const u8, name: []const u8) bool {
    var segs = std.mem.splitScalar(u8, pattern, '/');
    while (segs.next()) |s| {
        if (s.len > 1 and s[0] == ':' and std.mem.eql(u8, s[1..], name)) return true;
        if (std.mem.eql(u8, s, router.wildcard) and std.mem.eql(u8, name, router.wildcard)) return true;
    }
    return false;
}

/// Read every field of `T` from the matched route by its name, at run time.
/// A resolver's way in: it is not tied to a route, so the names cannot be
/// held against one while compiling when a bare middleware reaches it, and a
/// typed middleware's are held at `listen()` instead (ADR 008). A name the
/// route lacks is a 500 naming `who`, the param and the route. `who` opens the
/// sentence: "the resolver `X`", "the middleware taking (…)".
pub fn readByName(comptime T: type, comptime who: []const u8, c: *const Ctx) !T {
    const info = @typeInfo(T).@"struct";
    var out: T = undefined;
    inline for (info.field_names, info.field_types) |f_name, F| {
        const s = c.param(f_name) orelse return fail.internal(
            "{s} reads the path param :{s}, and route \"{s}\" has no such param",
            .{ who, f_name, routePattern(c) },
        );
        @field(out, f_name) = try convert_mod.convert(F, .query, s, ":" ++ f_name);
    }
    return out;
}

fn routePattern(c: *const Ctx) []const u8 {
    const route = c._route orelse return c._path;
    return route.pattern;
}
