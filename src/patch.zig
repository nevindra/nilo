//! `Patch(T)` — a body field that can tell "not sent" from "sent as null"
//! (ADR 0026).
//!
//! ```zig
//! const EditTodo = struct {
//!     title: Patch(Str) = .absent,
//!     due: Patch(Str) = .absent,
//! };
//!
//! fn editTodo(store: *Store, id: u32, incoming: EditTodo) !?Todo {
//!     switch (incoming.title) {
//!         .absent => {},                       // not mentioned: leave it
//!         .cleared => todo.title = null,       // sent as null: clear it
//!         .value => |v| todo.title = try v.keep(gpa),
//!     }
//! }
//! ```
//!
//! `?T` has two states and a PATCH needs three, which is the whole reason
//! this type exists. With `title: ?Str = null`, `{}` and `{"title":null}`
//! arrive identical, so "leave this alone" and "empty this out" cannot be
//! told apart and one of them has to be given up.
//!
//! The default belongs on the field — `= .absent` — and is what makes the
//! field optional everywhere else: the body parser, the message that says
//! what is missing, and the API description all read a default the same way.

const std = @import("std");

pub fn Patch(comptime T: type) type {
    return union(enum) {
        /// The field was not in the body at all.
        absent,
        /// The field was in the body as `null` — a deliberate "empty this".
        cleared,
        /// The field was in the body with a value.
        value: T,

        /// What this is a patch of. Read by the body parser, by the message
        /// that says what a field will accept, and by the API description.
        pub const zfast_patch = T;

        const Self = @This();

        /// The value, or null for both of the other two — for the fields
        /// where "leave it" and "clear it" really are the same thing, and
        /// the three-way switch would be ceremony.
        pub fn orNull(self: Self) ?T {
            return switch (self) {
                .value => |v| v,
                else => null,
            };
        }

        /// Whether the body mentioned this field at all.
        pub fn sent(self: Self) bool {
            return self != .absent;
        }

        pub fn jsonParse(
            gpa: std.mem.Allocator,
            source: anytype,
            options: std.json.ParseOptions,
        ) !Self {
            // Only reached when the field is in the body: std.json leaves an
            // absent field at its default, which is what `.absent` is for.
            if (try source.peekNextTokenType() == .null) {
                _ = try source.next();
                return .cleared;
            }
            return .{ .value = try std.json.innerParse(T, gpa, source, options) };
        }

        pub fn jsonParseFromValue(
            gpa: std.mem.Allocator,
            source: std.json.Value,
            options: std.json.ParseOptions,
        ) !Self {
            if (source == .null) return .cleared;
            return .{ .value = try std.json.innerParseFromValue(T, gpa, source, options) };
        }

        /// So that a type carrying one can still be sent back. A field that
        /// was never sent has nothing to say, and JSON has no way to leave a
        /// field out of a value that has it, so both of the empty cases go
        /// out as null. This type is for reading a PATCH body, not for
        /// describing a resource.
        pub fn jsonStringify(self: Self, jw: anytype) !void {
            return switch (self) {
                .value => |v| jw.write(v),
                else => jw.write(null),
            };
        }
    };
}

/// Whether `T` is a `Patch(…)`. Asked by the parts of zfast that have to
/// treat one as "the value, or null, or not there".
pub fn isPatch(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"union" => @hasDecl(T, "zfast_patch"),
        else => false,
    };
}

const testing = std.testing;

const Edit = struct {
    title: Patch([]const u8) = .absent,
    done: Patch(bool) = .absent,
};

fn parse(text: []const u8) !Edit {
    return std.json.parseFromSliceLeaky(Edit, testing.allocator, text, .{});
}

test "absent, null and a value are three different answers" {
    const nothing = try parse("{}");
    try testing.expect(nothing.title == .absent);
    try testing.expect(!nothing.title.sent());

    const cleared = try parse("{\"title\":null}");
    try testing.expect(cleared.title == .cleared);
    try testing.expect(cleared.title.sent());

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const given = try std.json.parseFromSliceLeaky(
        Edit,
        arena.allocator(),
        "{\"title\":\"buy milk\",\"done\":true}",
        .{},
    );
    try testing.expectEqualStrings("buy milk", given.title.value);
    try testing.expectEqual(true, given.done.value);
}

test "orNull collapses the two empty answers, for the fields that do not care" {
    try testing.expect((try parse("{}")).title.orNull() == null);
    try testing.expect((try parse("{\"title\":null}")).title.orNull() == null);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const given = try std.json.parseFromSliceLeaky(
        Edit,
        arena.allocator(),
        "{\"title\":\"x\"}",
        .{},
    );
    try testing.expectEqualStrings("x", given.title.orNull().?);
}

test "one goes back out as its value, and as null when there is none" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const json = try std.json.Stringify.valueAlloc(
        arena.allocator(),
        Edit{ .title = .{ .value = "hi" }, .done = .cleared },
        .{},
    );
    try testing.expectEqualStrings("{\"title\":\"hi\",\"done\":null}", json);
}

test "a Patch is recognised by its marker, and nothing else is" {
    try testing.expect(isPatch(Patch(u32)));
    try testing.expect(!isPatch(?u32));
    try testing.expect(!isPatch(struct { a: u8 }));
    try testing.expect(!isPatch(u32));
}
