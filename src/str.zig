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
///
/// The counter is not simply "requests so far on this connection", and the
/// difference is what makes the trap worth having. Every Lifetime starts in
/// a span of its own, handed out once per connection, so no two connections
/// ever count through the same numbers. Without that, a connection closing
/// and the next one starting from zero in the same piece of stack meant a
/// Str stashed by the first compared equal to the second and came back with
/// nobody the wiser — which is the one mistake this type exists to catch,
/// and the shape it takes when somebody tests it with two `curl` calls.
pub const Lifetime = struct {
    gen: Gen = if (trap_enabled) 0 else {},

    const Gen = if (trap_enabled) u64 else void;

    /// One span per connection. Wide enough that a connection would have to
    /// serve four billion requests to reach the next one, and there would
    /// have to be four billion connections before the spans came round
    /// again — so in practice, never.
    var next_span: std.atomic.Value(u32) = .init(1);

    /// A Lifetime for one connection. `.{}` is span zero, which is what a
    /// test driving one request wants; a server calls this.
    pub fn init() Lifetime {
        if (!trap_enabled) return .{};
        return .{ .gen = @as(u64, next_span.fetchAdd(1, .monotonic)) << 32 };
    }

    pub fn end(self: *Lifetime) void {
        if (trap_enabled) self.gen +%= 1;
    }

    /// The connection is over. Everything from it is stale for good, and
    /// saying so here means a Str that outlived its connection is caught
    /// even while the memory this sat in is still readable.
    pub fn deinit(self: *Lifetime) void {
        if (trap_enabled) self.gen = dead;
    }

    /// A generation `init` can never hand out and `end` can never reach
    /// from one: the low half is all ones, and a span only ever counts up
    /// from zero.
    const dead: u64 = std.math.maxInt(u64);
};

pub const Str = struct {
    _bytes: []const u8,
    _marker: Marker,

    const Marker = if (trap_enabled) ?struct { gen_ptr: *const u64, gen: u64 } else void;

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

    /// Print the contents: `std.log.info("{f}", .{c.path()})`.
    ///
    /// `{s}` cannot be made to work — Zig reserves it for byte slices, and a
    /// Str is a struct — so it is `{f}` here and `{s}` with `.view()`. Worth
    /// the four lines anyway: logging the path is the first thing anybody
    /// writes, and without this the answer was a compile error from inside
    /// `std.Io.Writer` naming neither zfast nor the fix.
    pub fn format(self: Str, w: *std.Io.Writer) std.Io.Writer.Error!void {
        return w.writeAll(self.view());
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
/// What gets walked: Str, struct fields, the payload of an optional, the
/// active arm of a tagged union — which is how a `Patch(Str)` gets watched
/// too — array elements, and the elements of a mutable slice. Const slices
/// and untagged unions are skipped: Strs there still work, they just don't
/// get the debug trap watching over them.
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
        // Only the arm that is actually set: the others hold nothing.
        .@"union" => |u| if (u.tag_type != null) switch (value.*) {
            inline else => |_, tag| stampInner(&@field(value, @tagName(tag)), lifetime, depth - 1),
        },
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
        .@"union" => |u| u.tag_type != null and for (u.fields) |f| {
            if (containsStr(f.type, depth - 1)) break true;
        } else false,
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

test "a Str prints with {f}, and printing a dead one still trips the trap" {
    var lifetime = Lifetime{};
    const s = Str.fromRequest("/users/42", &lifetime);

    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("path=/users/42", try std.fmt.bufPrint(&buf, "path={f}", .{s}));
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

test "two connections never count through the same generations" {
    if (!trap_enabled) return;

    // What this is really testing is the mistake in the field: a handler
    // stashes a Str, the connection closes, and the next connection reuses
    // the same piece of stack. Before spans, the new Lifetime started at the
    // number the old Str was holding and the stale read came back clean.
    var first = Lifetime.init();
    const stashed = Str.fromRequest("secret-from-request-one", &first);
    try testing.expect(stashed.alive());

    first.deinit();
    try testing.expect(!stashed.alive());

    // The same memory, a new connection. Nothing it counts through can match
    // what the first one handed out.
    first = Lifetime.init();
    try testing.expect(!stashed.alive());
    for (0..8) |_| {
        first.end();
        try testing.expect(!stashed.alive());
    }
}

test "a Lifetime made with .{} is still a working one, for a test holding a single request" {
    if (!trap_enabled) return;
    var lifetime = Lifetime{};
    const s = Str.fromRequest("hello", &lifetime);
    try testing.expect(s.alive());
    lifetime.deinit();
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
