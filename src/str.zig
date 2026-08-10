//! Str — text that came from a request (ADR 0004).
//!
//! It lives only as long as the request does, because its bytes belong to
//! the request arena. You cannot get at the contents without asking for
//! them: `.view()` borrows for the duration of the request, `.keep()`
//! copies into longer-lived memory.
//!
//! The guarantee cannot be complete — Zig has no ownership system. So
//! debug builds attach a lifetime marker: using a Str after its request
//! has finished stops hard on your laptop instead of crashing at random
//! in production. Release builds drop the marker entirely, at no cost.

const std = @import("std");
const builtin = @import("builtin");

pub const trap_enabled = builtin.mode == .Debug;

/// Lifetime marker for one request arena. One per connection, bumped
/// every time a request finishes; every Str from the old request goes
/// stale at once.
pub const Lifetime = struct {
    gen: Gen = if (trap_enabled) 0 else {},

    const Gen = if (trap_enabled) u32 else void;

    pub fn end(self: *Lifetime) void {
        if (trap_enabled) self.gen +%= 1;
    }
};

pub const Str = struct {
    _bytes: []const u8,
    _marker: Marker,

    const Marker = if (trap_enabled) ?struct { gen_ptr: *const u32, gen: u32 } else void;

    /// A Str tied to a request's lifetime. Used internally by zfast.
    pub fn fromRequest(bytes: []const u8, lifetime: *const Lifetime) Str {
        return .{
            ._bytes = bytes,
            ._marker = if (trap_enabled) .{ .gen_ptr = &lifetime.gen, .gen = lifetime.gen } else {},
        };
    }

    /// A Str with no lifetime marker, for literals in handler unit tests.
    /// Never considered stale.
    pub fn static(bytes: []const u8) Str {
        return .{ ._bytes = bytes, ._marker = if (trap_enabled) null else {} };
    }

    // ---- travelling through JSON ----
    //
    // So that `struct { name: Str }` works as an incoming body as well as
    // an outgoing response, instead of the bare `[]const u8` that ADR 0004
    // exists to avoid.

    /// Goes out as a plain JSON string, not as an object of internal
    /// fields.
    pub fn jsonStringify(self: Str, jw: anytype) !void {
        try jw.write(self.view());
    }

    /// Comes in from a JSON string. The marker is not attached here — the
    /// parser has no idea which request is running — so App calls `stamp`
    /// once parsing is done.
    pub fn jsonParse(gpa: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Str {
        return static(try std.json.innerParse([]const u8, gpa, source, options));
    }

    pub fn jsonParseFromValue(gpa: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !Str {
        return static(try std.json.innerParseFromValue([]const u8, gpa, source, options));
    }

    /// Borrow the contents. Only valid while the request is still running —
    /// to hold on to it for longer, use `.keep()`.
    pub fn view(self: Str) []const u8 {
        self.assertAlive();
        return self._bytes;
    }

    /// Copy into longer-lived memory owned by the caller, so it is safe to
    /// hold after the request finishes. The caller frees it.
    pub fn keep(self: Str, gpa: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        self.assertAlive();
        return gpa.dupe(u8, self._bytes);
    }

    pub fn len(self: Str) usize {
        self.assertAlive();
        return self._bytes.len;
    }

    pub fn eql(self: Str, other: []const u8) bool {
        return std.mem.eql(u8, self.view(), other);
    }

    /// Parse as a base-10 integer.
    pub fn int(self: Str, comptime T: type) std.fmt.ParseIntError!T {
        return std.fmt.parseInt(T, self.view(), 10);
    }

    /// Whether the lifetime marker is still valid. Only exists while the
    /// trap is enabled; used in tests.
    pub fn alive(self: Str) bool {
        comptime std.debug.assert(trap_enabled);
        const m = self._marker orelse return true;
        return m.gen_ptr.* == m.gen;
    }

    fn assertAlive(self: Str) void {
        if (trap_enabled) {
            if (!self.alive()) @panic(
                "Str used after its request finished. Request data dies with " ++
                    "the request; copy it with .keep() while the handler is still " ++
                    "running if you need to hold on to it.",
            );
        }
    }
};

/// Attach the lifetime marker `lifetime` to every Str inside `value` (a
/// pointer). Used by App after parsing a request body: the parse result
/// lives in the request arena, so the Strs inside it have to die when the
/// request does.
///
/// What gets walked: Str, struct fields, the payload of an optional,
/// array elements, and the elements of a mutable slice. Const slices and
/// unions are skipped — Strs there still work, they just don't get the
/// debug trap watching over them.
pub fn stamp(value: anytype, lifetime: *const Lifetime) void {
    if (!trap_enabled) return;
    stampInner(value, lifetime, 8);
}

fn stampInner(value: anytype, lifetime: *const Lifetime, comptime depth: u8) void {
    if (depth == 0) return;
    const T = @typeInfo(@TypeOf(value)).pointer.child;
    if (comptime !containsStr(T, depth)) return;

    if (T == Str) {
        value._marker = .{ .gen_ptr = &lifetime.gen, .gen = lifetime.gen };
        return;
    }
    switch (@typeInfo(T)) {
        .@"struct" => |s| inline for (s.fields) |f| {
            stampInner(&@field(value, f.name), lifetime, depth - 1);
        },
        .optional => if (value.*) |*payload| stampInner(payload, lifetime, depth - 1),
        .array => for (value) |*item| stampInner(item, lifetime, depth - 1),
        .pointer => |p| switch (p.size) {
            .slice => if (!p.is_const) for (value.*) |*item| stampInner(item, lifetime, depth - 1),
            else => {},
        },
        else => {},
    }
}

/// Whether `T` could hold a Str anywhere inside it. Types that hold none
/// at all — most of them — generate no code.
fn containsStr(comptime T: type, comptime depth: u8) bool {
    if (depth == 0) return false;
    if (T == Str) return true;
    return switch (@typeInfo(T)) {
        .@"struct" => |s| for (s.fields) |f| {
            if (containsStr(f.type, depth - 1)) break true;
        } else false,
        .optional => |o| containsStr(o.child, depth - 1),
        .array => |a| containsStr(a.child, depth - 1),
        .pointer => |p| p.size == .slice and !p.is_const and containsStr(p.child, depth - 1),
        else => false,
    };
}

const testing = std.testing;

test "view and eql" {
    var lifetime = Lifetime{};
    const s = Str.fromRequest("hello", &lifetime);
    try testing.expectEqualStrings("hello", s.view());
    try testing.expect(s.eql("hello"));
    try testing.expect(!s.eql("other"));
}

test "keep copies into the caller's memory" {
    var lifetime = Lifetime{};
    const s = Str.fromRequest("hello", &lifetime);
    const copy = try s.keep(testing.allocator);
    defer testing.allocator.free(copy);
    lifetime.end();
    try testing.expectEqualStrings("hello", copy);
}

test "int" {
    var lifetime = Lifetime{};
    try testing.expectEqual(@as(u32, 42), try Str.fromRequest("42", &lifetime).int(u32));
    try testing.expectError(error.InvalidCharacter, Str.fromRequest("4x", &lifetime).int(u32));
}

test "the marker goes stale once the request finishes" {
    if (!trap_enabled) return;
    var lifetime = Lifetime{};
    const s = Str.fromRequest("hello", &lifetime);
    try testing.expect(s.alive());
    lifetime.end();
    try testing.expect(!s.alive());
}

test "a static Str never goes stale" {
    if (!trap_enabled) return;
    const s = Str.static("literal");
    try testing.expect(s.alive());
    try testing.expectEqualStrings("literal", s.view());
}

test "Str goes out as a plain JSON string" {
    var lifetime = Lifetime{};
    const Message = struct { name: Str, age: u8 };
    const json = try std.json.Stringify.valueAlloc(
        testing.allocator,
        Message{ .name = Str.fromRequest("wati", &lifetime), .age = 30 },
        .{},
    );
    defer testing.allocator.free(json);
    try testing.expectEqualStrings("{\"name\":\"wati\",\"age\":30}", json);
}

test "Str comes in from JSON and gets stamped with the request lifetime" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var lifetime = Lifetime{};

    const Incoming = struct { name: Str, tags: []Str };
    var value = try std.json.parseFromSliceLeaky(
        Incoming,
        arena.allocator(),
        "{\"name\":\"wati\",\"tags\":[\"a\",\"b\"]}",
        .{},
    );
    stamp(&value, &lifetime);

    try testing.expectEqualStrings("wati", value.name.view());
    try testing.expectEqualStrings("b", value.tags[1].view());

    if (!trap_enabled) return;
    lifetime.end();
    try testing.expect(!value.name.alive());
    try testing.expect(!value.tags[1].alive()); // goes stale inside the slice too
}

test "stamp leaves types without a Str alone" {
    var lifetime = Lifetime{};
    var plain = struct { a: u32, b: [2]f64 }{ .a = 1, .b = .{ 2, 3 } };
    stamp(&plain, &lifetime);
    try testing.expectEqual(@as(u32, 1), plain.a);
}

test "stamp reaches through optionals and nested structs" {
    if (!trap_enabled) return;
    var lifetime = Lifetime{};
    const Inner = struct { text: Str };
    var value = struct { maybe: ?Inner }{ .maybe = .{ .text = Str.static("hello") } };
    stamp(&value, &lifetime);

    try testing.expect(value.maybe.?.text.alive());
    lifetime.end();
    try testing.expect(!value.maybe.?.text.alive());
}
