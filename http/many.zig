//! A list with a length, as a type
//! ([ADR 266](../docs/adr/266-a-list-with-a-length-is-a-type.md)).
//!
//! ```zig
//! const NewPost = struct {
//!     title: nilo.Text(.{ .min = 1, .max = 120 }),
//!     tags:  nilo.Many(nilo.Str, .{ .min = 1, .max = 5 }),
//! };
//! ```
//!
//! What `Text` is for a string's length (ADR 193) and `Within` for a number's
//! range (ADR 167), this is for how many a list holds: `minItems` and
//! `maxItems` in the document, and one sentence when the list is outside them,
//! naming the field, the count and the bound: `"tags" has to be a list of 1
//! to 5 items, not a list of 7`. It is read where a list is read, which is a
//! JSON body and a form (a checkbox group or a `<select multiple>`), collected
//! by `Bound` beside every other field. A query string is not one of them:
//! `?tag=a,b` has no count the client is told of in the document, and the
//! element-wise refusals it already has are enough there (ADR 132).
//!
//! **The elements are read as they are in a plain `[]const Item`**: a number
//! in a list is spelled as a query's is (ADR 084), a `Text` in it is held to
//! its shape, and a bad element is named by its position (`"tags[2]"`). The
//! length is checked after the list has been read whole, so a list that is
//! too long is not cut short and then reported as the wrong kind of thing.
//!
//! **The slice is `.value`**, and `len` is forwarded, for the reason `Text`
//! and `Within` read as `.value`: a struct is what nilo can read a bound off.
//! `.of(&.{})` for a default, checked against the bound while compiling.
//!
//! **A response that carries one writes its slice.** A `Many` is a document
//! of its slice (`nilo_json_of`, ADR 163), so nilo's writer walks the items
//! as it walks a plain `[]const Item` and a `rename_all` inside them applies
//! (ADR 148).

const std = @import("std");
const json = @import("json.zig");
const naming = @import("names.zig");

/// What a `Many` is allowed to ask of the count.
pub const Options = struct {
    /// At least this many.
    min: ?usize = null,
    /// At most this many.
    max: ?usize = null,
};

pub fn Many(comptime Item: type, comptime opts: Options) type {
    comptime check(Item, opts);
    return struct {
        const Self = @This();

        /// What a nilo compile error calls this type (ADR 074).
        pub const nilo_type_name = spelled(Item, opts);

        /// What a 400 asks for, in place of the type's name.
        pub const nilo_expects = expects(opts);

        /// The element and the bounds, for the document and for the readers
        /// to find by name (`openapi.zig`, `form.zig`).
        pub const nilo_many = .{ .Item = Item, .min = opts.min, .max = opts.max };

        /// A document of its slice (ADR 163), so the generated writer walks
        /// the items as it walks a plain slice and `rename_all`, `.rename`
        /// and `.skip` inside them apply (ADR 148).
        pub const nilo_json_of = []const Item;

        value: []const Item,

        /// A list known while compiling, the default a field falls back to,
        /// checked against the bound here rather than never.
        pub fn of(comptime items: []const Item) Self {
            comptime {
                if (!fitsCount(items.len)) @compileError(std.fmt.comptimePrint(
                    "nilo: `{s}.of(…)` is given {d} items, which is outside its own bound.\n" ++
                        "  A default is the one value a request never sends, so it is the one " ++
                        "the bound would never catch, which is why it is checked here.",
                    .{ nilo_type_name, items.len },
                ));
            }
            return .{ .value = items };
        }

        /// Whether a list of `n` is inside the bound. Public because the
        /// form reader counts before it wraps, and the diagnosis counts a
        /// JSON array it has not read.
        pub fn fitsCount(n: usize) bool {
            if (opts.min) |min| if (n < min) return false;
            if (opts.max) |max| if (n > max) return false;
            return true;
        }

        /// The second arrival, a form: the values already converted, wrapped
        /// when there are as many as the bound wants.
        pub fn nilo_wrap(items: []const Item) ?Self {
            if (!fitsCount(items.len)) return null;
            return .{ .value = items };
        }

        /// The third arrival, a JSON body: the array read as a plain list
        /// is, then counted.
        pub fn jsonParse(
            gpa: std.mem.Allocator,
            source: anytype,
            options: std.json.ParseOptions,
        ) std.json.ParseError(@TypeOf(source.*))!Self {
            const items = try json.innerRead([]const Item, gpa, source, options);
            return nilo_wrap(items) orelse error.LengthMismatch;
        }

        pub fn jsonStringify(self: Self, jw: anytype) !void {
            try jw.write(self.value);
        }

        pub fn len(self: Self) usize {
            return self.value.len;
        }
    };
}

/// The element of a field that is a `Many`, or null when it is not one.
pub fn itemOf(comptime T: type) ?type {
    return switch (@typeInfo(T)) {
        .@"struct" => if (@hasDecl(T, "nilo_many")) T.nilo_many.Item else null,
        else => null,
    };
}

fn check(comptime Item: type, comptime opts: Options) void {
    comptime {
        if (Item == u8) @compileError(
            "nilo: `Many(u8, …)` is a list of bytes, and bytes are text in a request.\n" ++
                "  Bound the text's length with `nilo.Text(.{ .max = 100 })`, or ask for a list of numbers with a wider type.",
        );
        if (opts.min == null and opts.max == null) @compileError(
            "nilo: `Many(" ++ naming.of(Item) ++ ", .{})` asks nothing of the count, so it is a `[]const " ++ naming.of(Item) ++ "` with a longer name.\n" ++
                "  Give it a bound, `.min` or `.max`, or write the slice.",
        );
        if (opts.min != null and opts.max != null and opts.min.? > opts.max.?) @compileError(std.fmt.comptimePrint(
            "nilo: `Many(" ++ naming.of(Item) ++ ", .{{ .min = {d}, .max = {d} }})` has its bounds the wrong way round: " ++
                "nothing is at least {d} and at most {d} items.\n" ++
                "  The smaller bound is `min`: `.{{ .min = {d}, .max = {d} }}`.",
            .{ opts.min.?, opts.max.?, opts.min.?, opts.max.?, opts.max.?, opts.min.? },
        ));
    }
}

fn spelled(comptime Item: type, comptime opts: Options) []const u8 {
    comptime {
        var out: []const u8 = "nilo.Many(" ++ naming.of(Item) ++ ", .{";
        var first = true;
        if (opts.min) |min| {
            out = out ++ std.fmt.comptimePrint(" .min = {d}", .{min});
            first = false;
        }
        if (opts.max) |max| out = out ++ (if (first) "" else ",") ++ std.fmt.comptimePrint(" .max = {d}", .{max});
        return out ++ " })";
    }
}

fn noun(comptime n: usize) []const u8 {
    return if (n == 1) "item" else "items";
}

fn expects(comptime opts: Options) []const u8 {
    comptime {
        if (opts.min != null and opts.max != null) return std.fmt.comptimePrint(
            "a list of {d} to {d} items",
            .{ opts.min.?, opts.max.? },
        );
        if (opts.min) |min| return std.fmt.comptimePrint("a list of at least {d} {s}", .{ min, noun(min) });
        const max = opts.max.?;
        return std.fmt.comptimePrint("a list of at most {d} {s}", .{ max, noun(max) });
    }
}

// ---- tests ----

const testing = std.testing;
const Str = @import("nilo_core").Str;

test "the count is inclusive at both ends" {
    const Tags = Many(u32, .{ .min = 1, .max = 3 });
    try testing.expect(!Tags.fitsCount(0));
    try testing.expect(Tags.fitsCount(1));
    try testing.expect(Tags.fitsCount(3));
    try testing.expect(!Tags.fitsCount(4));
    try testing.expect(Many(u32, .{ .min = 2 }).fitsCount(1000));
    try testing.expect(Many(u32, .{ .max = 2 }).fitsCount(0));
}

test "what a 400 asks for reads as the bound" {
    try testing.expectEqualStrings("a list of 1 to 5 items", Many(u32, .{ .min = 1, .max = 5 }).nilo_expects);
    try testing.expectEqualStrings("a list of at least 1 item", Many(u32, .{ .min = 1 }).nilo_expects);
    try testing.expectEqualStrings("a list of at most 4 items", Many(u32, .{ .max = 4 }).nilo_expects);
    try testing.expectEqualStrings("nilo.Many(u32, .{ .min = 1, .max = 5 })", Many(u32, .{ .min = 1, .max = 5 }).nilo_type_name);
}

test "in a JSON body the list is read and counted, and the default is checked" {
    const Tags = Many(u32, .{ .min = 1, .max = 3 });
    const Body = struct { tags: Tags = .of(&.{7}) };

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const ok = try json.parseLeaky(Body, gpa, "{\"tags\":[1,2,3]}", .{});
    try testing.expectEqual(@as(usize, 3), ok.tags.len());

    const absent = try json.parseLeaky(Body, gpa, "{}", .{});
    try testing.expectEqual(@as(u32, 7), absent.tags.value[0]);

    try testing.expectError(error.LengthMismatch, json.parseLeaky(Body, gpa, "{\"tags\":[]}", .{}));
    try testing.expectError(error.LengthMismatch, json.parseLeaky(Body, gpa, "{\"tags\":[1,2,3,4]}", .{}));
    try testing.expectError(error.UnexpectedToken, json.parseLeaky(Body, gpa, "{\"tags\":3}", .{}));
}

test "itemOf finds the element of a Many and nothing else" {
    try testing.expectEqual(u32, itemOf(Many(u32, .{ .min = 1 })).?);
    try testing.expect(itemOf([]const u32) == null);
    try testing.expect(itemOf(Str) == null);
}
