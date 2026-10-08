//! Str — text that came from a request (ADR 003).
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

pub const trap_enabled = builtin.mode == .debug;

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
///
/// **The counter runs in every build; only the trap is Debug's.** A release
/// `Str` still carries no marker, but something below the framework has to
/// tell two requests on one connection apart without one: `sql.problem` keeps
/// the last failure in a thread-local whose strings the arena's reset hands
/// back, and the arena's pointer is the same for every request on the
/// connection (ADR 117). Eight bytes on the connection's frame, one atomic
/// add per connection, and `end` is one add.
pub const Lifetime = struct {
    gen: u64 = 0,

    /// One span per connection. Wide enough that a connection would have to
    /// serve four billion requests to reach the next one, and there would
    /// have to be four billion connections before the spans came round
    /// again — so in practice, never.
    var next_span: std.atomic.Value(u32) = .init(1);

    /// A Lifetime for one connection. `.{}` is span zero, which is what a
    /// test driving one request wants; a server calls this.
    pub fn init() Lifetime {
        return .{ .gen = @as(u64, next_span.fetchAdd(1, .monotonic)) << 32 };
    }

    pub fn end(self: *Lifetime) void {
        self.gen +%= 1;
    }

    /// The connection is over. Everything from it is stale for good, and
    /// saying so here means a Str that outlived its connection is caught
    /// even while the memory this sat in is still readable.
    pub fn deinit(self: *Lifetime) void {
        self.gen = dead;
    }

    /// Which piece of work this is: moved by every `end`, and never the same
    /// on two connections made by `init`. What a Scope's `serial` answers.
    pub fn serial(self: *const Lifetime) u64 {
        return self.gen;
    }

    /// A generation `init` can never hand out and `end` can never reach
    /// from one: the low half is all ones, and a span only ever counts up
    /// from zero.
    const dead: u64 = std.math.maxInt(u64);
};

pub const Str = struct {
    /// What a nilo compile error calls this type, which is the name the
    /// reader's own import line gives it (ADR 074).
    pub const nilo_type_name = "nilo.Str";

    _bytes: []const u8,
    _marker: Marker,

    const Marker = if (trap_enabled) ?struct { gen_ptr: *const u64, gen: u64 } else void;

    /// A Str tied to a request's lifetime. Used internally by nilo.
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
    // an outgoing response, instead of the bare `[]const u8` that ADR 003
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
    /// `std.Io.Writer` naming neither nilo nor the fix.
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

    /// The contents with whitespace taken off both ends, borrowed the way
    /// `view()` is.
    ///
    /// The set is `std.ascii.whitespace` — space, tab, newline, carriage
    /// return, vertical tab and form feed — rather than a literal written
    /// here, so there is one answer to *what counts as blank* and it is not
    /// this file's opinion.
    pub fn trimmed(self: Str) []const u8 {
        return std.mem.trim(u8, self.view(), &std.ascii.whitespace);
    }

    /// Whether there is nothing here but whitespace
    /// ([ADR 142](../docs/adr/142-required-text-arrives-as-two-spaces.md)).
    ///
    /// **This is the check in front of every write that takes a name, a title
    /// or a body**, because required text arrives as `"  "` in the ordinary
    /// case rather than the rare one: a form field the person tabbed through,
    /// a paste that brought its newline along. `len() == 0` does not catch
    /// either of them.
    ///
    /// A read of the bytes rather than a validation rule, which is the line
    /// `len()` and `eql()` already draw — what a blank field *means* is the
    /// caller's, and nilo has nothing to say about whether it is a 422.
    ///
    /// It is here rather than in a caller's own helper for the reason the
    /// charset is `std.ascii.whitespace` above: a copy that drops `\n` accepts
    /// a comment whose whole body is a newline, and the required field then
    /// holds a string every screen renders as empty.
    pub fn blank(self: Str) bool {
        return self.trimmed().len == 0;
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

/// The same walk, for a caller holding a Scope rather than its Lifetime.
///
/// A Fitting is handed its Scope as `anytype` and the two shipped ones keep
/// the Lifetime differently — a value on a `Run`, a pointer on a `Ctx` — so
/// reaching the field is a branch per Scope and a fourth thing a new Scope
/// would have to match. `str()` is the one call the Scope contract already
/// has for "text that lives as long as this work does" (`scope.zig`), so
/// each `Str` found is re-made through it, over the same bytes. `nilo_job`
/// is the caller: a payload parsed for a tick has to go stale at the tick's
/// end the way a body goes stale at the request's.
pub fn stampWith(value: anytype, scope: anytype) void {
    if (!trap_enabled) return;
    stampInner(value, scope, 8);
}

/// The same walk, copying the marker off a `Str` that already has one.
///
/// For a type that parses itself out of request text (ADR 113): its
/// `nilo_parse` takes bytes and can only build a `Str` with no marker, and
/// the engine, which holds the `Str` those bytes came from, puts that one's
/// marker on every `Str` the parse built — so a `nilo.Text` out of a form
/// goes stale with the form (ADR 193).
pub fn stampLike(value: anytype, like: Str) void {
    if (!trap_enabled) return;
    stampInner(value, like, 8);
}

/// `by` is a `*const Lifetime`, a `Str` to copy the marker from, or a Scope;
/// only the leaf tells them apart.
fn stampInner(value: anytype, by: anytype, comptime depth: u8) void {
    if (depth == 0) return;
    const T = @typeInfo(@TypeOf(value)).pointer.child;
    // Asking whether `T` holds a Str walks its fields once and the loop below
    // walks them again, so a body of 400 fields ran past the default 1,000
    // backwards branches at a line in this file
    // ([ADR 126](../docs/adr/126-a-check-pays-for-its-own-branches.md)).
    comptime @setEvalBranchQuota(1_000 + 20 * @as(u32, @intCast(fieldCount(T))));
    if (comptime !containsStr(T, depth)) return;

    if (T == Str) {
        if (comptime @TypeOf(by) == *const Lifetime) {
            value._marker = .{ .gen_ptr = &by.gen, .gen = by.gen };
        } else if (comptime @TypeOf(by) == Str) {
            value._marker = by._marker;
        } else {
            value.* = by.str(value._bytes);
        }
        return;
    }
    switch (@typeInfo(T)) {
        .@"struct" => |s| inline for (s.field_names) |name| {
            stampInner(&@field(value, name), by, depth - 1);
        },
        .optional => if (value.*) |*payload| stampInner(payload, by, depth - 1),
        // Only the arm that is actually set: the others hold nothing.
        .@"union" => |u| if (u.tag_type != null) switch (value.*) {
            inline else => |_, tag| stampInner(&@field(value, @tagName(tag)), by, depth - 1),
        },
        .array => for (value) |*item| stampInner(item, by, depth - 1),
        .pointer => |p| switch (p.size) {
            .slice => if (!p.attrs.@"const") for (value.*) |*item| stampInner(item, by, depth - 1),
            else => {},
        },
        else => {},
    }
}

/// How many fields `T` has, which is what a walk over it is sized from.
fn fieldCount(comptime T: type) usize {
    return switch (@typeInfo(T)) {
        .@"struct" => |s| s.field_names.len,
        .@"union" => |u| u.field_names.len,
        else => 0,
    };
}

/// Whether `T` could hold a Str anywhere inside it. Types that hold none
/// at all — most of them — generate no code.
fn containsStr(comptime T: type, comptime depth: u8) bool {
    if (depth == 0) return false;
    if (T == Str) return true;
    return switch (@typeInfo(T)) {
        .@"struct" => |s| for (s.field_types) |F| {
            if (containsStr(F, depth - 1)) break true;
        } else false,
        .optional => |o| containsStr(o.child, depth - 1),
        .@"union" => |u| u.tag_type != null and for (u.field_types) |F| {
            if (containsStr(F, depth - 1)) break true;
        } else false,
        .array => |a| containsStr(a.child, depth - 1),
        .pointer => |p| p.size == .slice and !p.attrs.@"const" and containsStr(p.child, depth - 1),
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

test "text that is nothing but whitespace is blank, and the empty string is too" {
    var lifetime = Lifetime{};
    try testing.expect(Str.fromRequest("", &lifetime).blank());
    try testing.expect(Str.fromRequest("  ", &lifetime).blank());
    try testing.expect(Str.fromRequest("\t", &lifetime).blank());
    // The one a hand-written charset drops, and the one it is dropped from: a
    // comment body that is a single newline is required text that renders as
    // an empty screen (ADR 142).
    try testing.expect(Str.fromRequest("\n", &lifetime).blank());
    try testing.expect(Str.fromRequest("\r\n", &lifetime).blank());
    try testing.expect(Str.fromRequest(" \t\r\n\x0b\x0c", &lifetime).blank());

    try testing.expect(!Str.fromRequest("wati", &lifetime).blank());
    try testing.expect(!Str.fromRequest("  wati  ", &lifetime).blank());
    // A non-breaking space is not ASCII whitespace and is not treated as any:
    // it is a character somebody typed, and guessing otherwise would be this
    // file deciding what a name may contain.
    try testing.expect(!Str.fromRequest("\u{00a0}", &lifetime).blank());
}

test "trimmed borrows the middle and leaves the contents alone" {
    var lifetime = Lifetime{};
    try testing.expectEqualStrings("wati", Str.fromRequest("  wati\n", &lifetime).trimmed());
    try testing.expectEqualStrings("a b", Str.fromRequest("\ta b\r\n", &lifetime).trimmed());
    try testing.expectEqualStrings("", Str.fromRequest("   ", &lifetime).trimmed());

    // Borrowed, not copied — the same bytes the Str is holding.
    const s = Str.fromRequest("  wati  ", &lifetime);
    try testing.expectEqual(s.view().ptr + 2, s.trimmed().ptr);
}

test "reading a dead Str as blank still trips the trap" {
    if (!trap_enabled) return;
    var lifetime = Lifetime{};
    const s = Str.fromRequest("  ", &lifetime);
    try testing.expect(s.blank());
    lifetime.end();
    // `blank` goes through `view()`, so a Str read after its request is the
    // same panic every other read gets rather than a quiet `true`.
    try testing.expect(!s.alive());
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

test "the serial moves at every request end and differs between connections, in every build" {
    // Not behind `trap_enabled`: `sql.problem` reads this in a release build
    // to tell the request that failed from the next one on the connection.
    var a = Lifetime.init();
    var b = Lifetime.init();
    try testing.expect(a.serial() != b.serial());

    const before = a.serial();
    a.end();
    try testing.expect(a.serial() != before);
    try testing.expect(a.serial() != b.serial());
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

test "stampWith reaches the same Strs through a Scope's own str()" {
    if (!trap_enabled) return;
    var lifetime = Lifetime{};
    const Scope = struct {
        lifetime: *const Lifetime,
        pub fn str(self: *@This(), bytes: []const u8) Str {
            return .fromRequest(bytes, self.lifetime);
        }
    };
    var scope: Scope = .{ .lifetime = &lifetime };

    const Incoming = struct { name: Str, tags: [2]Str };
    var value: Incoming = .{ .name = .static("wati"), .tags = .{ .static("a"), .static("b") } };
    stampWith(&value, &scope);

    try testing.expectEqualStrings("wati", value.name.view());
    try testing.expect(value.name.alive());
    lifetime.end();
    try testing.expect(!value.name.alive());
    try testing.expect(!value.tags[1].alive());
}

test "stampLike copies the marker off the Str the bytes came from" {
    if (!trap_enabled) return;
    var lifetime = Lifetime{};
    const from = Str.fromRequest("wati@example.com", &lifetime);
    const Parsed = struct { value: Str };
    var parsed: Parsed = .{ .value = .static(from._bytes) };
    stampLike(&parsed, from);

    try testing.expect(parsed.value.alive());
    lifetime.end();
    try testing.expect(!parsed.value.alive());
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

/// 600 fields with 40-character names and a Str among them, which is a body
/// no handler declares and a form or a JSON document can still be. Declared
/// apart from the test, so the test's own quota does not pay for it.
const WideBody = blk: {
    @setEvalBranchQuota(1_000_000);
    var names: [601][:0]const u8 = undefined;
    var types: [601]type = undefined;
    for (names[0..600], types[0..600], 0..) |*name, *T, i| {
        name.* = std.fmt.comptimePrint("a_field_with_a_long_descriptive_name_{d:0>4}", .{i});
        T.* = u32;
    }
    names[600] = "text";
    types[600] = Str;
    break :blk @Struct(.auto, null, &names, &types, &@splat(.{}));
};

test "a struct of 600 fields is stamped without a quota of the caller's" {
    var lifetime = Lifetime{};
    var body: WideBody = undefined;
    body.text = Str.fromRequest("hello", &lifetime);
    stamp(&body, &lifetime);
    try testing.expectEqualStrings("hello", body.text.view());
}
