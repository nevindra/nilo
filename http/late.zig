//! A value the program states while compiling, or one it fills before
//! `listen()` ([ADR 088](../docs/adr/088-an-origin-is-a-fact-about-the-deployment.md)).
//!
//! ```zig
//! var config: Config = undefined; // read from the environment in main()
//!
//! try app.useOn("/api", nilo.allowance.with(.{ .per_window = &config.rate, .window_s = 60 }));
//! try app.use(nilo.secure.pages(.{ .csp = &config.csp }));
//! ```
//!
//! **One idiom for three places.** `maxBody`, `allowance` and `secure` each
//! grew the same need on their own: a number or a text that is a fact about
//! where the program was deployed, which arrives through `nilo_config` at run
//! time, in a middleware that is a bare function pointer and so captures
//! nothing. The answer each reached is the one here: a comptime pointer to a
//! variable the program owns, read on each request. `Late(T)` is that answer
//! written once, so a fourth middleware does not invent a fourth spelling.
//!
//! **A plain literal still works where it always did.** `Late(T).of` is what
//! each Options struct runs its fields through, so `.per_window = 100` is a
//! stated value, `.per_window = &config.rate` is a held one, and neither
//! needs the union written out. A stated value is read by the compiler
//! (`read` on it folds away), so a program that states everything pays what it
//! paid before.
//!
//! **A held value is read, never watched.** One load per request with no
//! lock: a program that changes it while the server runs is racing every
//! request in flight, and reloading configuration is a separate feature that
//! does not exist. What a held value cannot be checked for while compiling
//! (zero, a character a header cannot hold) is checked by the middleware on
//! its first request, which answers 500 with the sentence until it is fixed.
//! No middleware has a hook at `listen()`.

const std = @import("std");

/// A `T` stated in the program, or the address of one the program fills.
pub fn Late(comptime T: type) type {
    return union(enum) {
        /// What a nilo compile error calls this type (ADR 074).
        pub const nilo_type_name = "nilo.Late";

        const Self = @This();

        value: T,
        held: *const T,

        /// The value now: a load for a held one, a constant for a stated one.
        pub fn read(self: Self) T {
            return switch (self) {
                .value => |v| v,
                .held => |p| p.*,
            };
        }

        /// Whether the value arrives after the program is compiled.
        pub fn isHeld(self: Self) bool {
            return self == .held;
        }

        /// What an argument of any of the three shapes means: a `Late(T)`
        /// itself, a pointer to a `T`, or anything a `T` can be made of
        /// (`100` for a `u32`, a string literal for a `[]const u8`).
        pub fn of(comptime x: anytype) Self {
            const X = @TypeOf(x);
            if (X == Self) return x;
            switch (@typeInfo(X)) {
                .pointer => |p| if (p.size == .one and p.child == T) {
                    return .{ .held = x };
                } else if (p.size == .one and @typeInfo(p.child) != .array) @compileError(
                    "nilo: this option takes a `" ++ @typeName(T) ++ "` or the address of one, and was " ++
                        "handed `" ++ @typeName(X) ++ "`.\n  A setting read from the environment has to " ++
                        "be declared as a `" ++ @typeName(T) ++ "` for its address to be taken.",
                ),
                .@"struct" => if (@hasField(X, "value") and !@hasField(X, "held")) return .{ .value = x.value } else if (@hasField(X, "held") and !@hasField(X, "value")) return .{ .held = x.held },
                else => {},
            }
            return .{ .value = x };
        }
    };
}

/// Whether `T` is a `Late`.
pub fn isLate(comptime T: type) bool {
    return @typeInfo(T) == .@"union" and @hasDecl(T, "nilo_type_name") and
        std.mem.eql(u8, T.nilo_type_name, "nilo.Late");
}

/// `given`, the struct literal a caller wrote, as an `Options`: every field
/// that is a `Late(T)` (or an optional one) taken through `Late(T).of`, every
/// other field as written, and the default for one left out.
///
/// **A field the Options does not have is a compile error**, which a struct
/// literal handed to an `anytype` would otherwise swallow: `.perwindow = 5`
/// is a misspelling, not a setting of nothing.
pub fn fill(comptime Options: type, comptime given: anytype) Options {
    comptime {
        const G = @TypeOf(given);
        const given_info = @typeInfo(G).@"struct";
        const info = @typeInfo(Options).@"struct";
        for (given_info.field_names) |name| {
            if (!@hasField(Options, name)) @compileError(
                "nilo: the options of this call have no field `" ++ name ++ "`.\n  " ++
                    "The fields are listed on the reference page for " ++ @typeName(Options) ++ ".",
            );
        }
        var out: Options = undefined;
        for (info.field_names, info.field_types, info.field_attrs) |name, F, attr| {
            if (@hasField(G, name)) {
                @field(out, name) = settle(F, @field(given, name));
            } else if (attr.default_value_ptr) |ptr| {
                const d: *const F = @ptrCast(@alignCast(ptr));
                @field(out, name) = d.*;
            } else @compileError(
                "nilo: " ++ @typeName(Options) ++ " needs `." ++ name ++ "`, which has no default.",
            );
        }
        return out;
    }
}

fn settle(comptime F: type, comptime x: anytype) F {
    if (comptime isLate(F)) return F.of(x);
    switch (@typeInfo(F)) {
        .optional => |o| if (comptime isLate(o.child)) {
            const X = @TypeOf(x);
            if (X == @TypeOf(null)) return null;
            if (@typeInfo(X) == .optional) return if (x) |v| o.child.of(v) else null;
            return o.child.of(x);
        },
        else => {},
    }
    // A struct literal for a struct field (`.hsts = .{ … }`, optional or not)
    // is read field by field, because a literal of anonymous type does not
    // coerce to a named struct once it has crossed an `anytype`.
    const X = @TypeOf(x);
    const Target = switch (@typeInfo(F)) {
        .optional => |o| o.child,
        else => F,
    };
    if (@typeInfo(Target) == .@"struct" and @typeInfo(X) == .@"struct" and X != Target) return fill(Target, x);
    return x;
}

/// A decimal number written into `buf` at `at.*`, with no formatter: the
/// callers sit on a connection's fiber stack, where `std.fmt`'s machinery is
/// a cost per idle connection (ADR 062).
pub fn putDecimal(buf: []u8, at: *usize, n: u64) void {
    var digits: [20]u8 = undefined;
    var i: usize = digits.len;
    var rest = n;
    while (true) {
        i -= 1;
        digits[i] = '0' + @as(u8, @intCast(rest % 10));
        rest /= 10;
        if (rest == 0) break;
    }
    const part = digits[i..];
    @memcpy(buf[at.*..][0..part.len], part);
    at.* += part.len;
}

const testing = std.testing;

var held_number: u32 = 7;
var held_text: []const u8 = "a";

test "a literal, an address and a Late are each what they look like" {
    const L = Late(u32);
    const held = &held_number;
    held.* = 7;
    try testing.expectEqual(@as(u32, 100), comptime L.of(100).read());
    try testing.expect(!comptime L.of(100).isHeld());
    const h = comptime L.of(held);
    try testing.expect(h.isHeld());
    try testing.expectEqual(@as(u32, 7), h.read());
    held.* = 9;
    try testing.expectEqual(@as(u32, 9), h.read());
    try testing.expectEqual(@as(u32, 5), comptime L.of(L{ .value = 5 }).read());
    try testing.expectEqual(@as(u32, 6), comptime L.of(.{ .value = 6 }).read());
}

test "text is stated by a literal and held by the address of a slice" {
    const L = Late([]const u8);
    held_text = "a";
    try testing.expectEqualStrings("lit", comptime L.of("lit").read());
    const h = comptime L.of(&held_text);
    held_text = "b";
    try testing.expectEqualStrings("b", h.read());
}

test "fill takes the defaults for what was left out and the fields as written" {
    const O = struct { n: Late(u32) = .{ .value = 1 }, t: ?Late([]const u8) = .{ .value = "x" }, flag: bool = true };
    const a = comptime fill(O, .{ .n = 5, .t = null });
    try testing.expectEqual(@as(u32, 5), a.n.read());
    try testing.expect(a.t == null);
    try testing.expect(a.flag);
    const b = comptime fill(O, .{ .t = "y", .flag = false });
    try testing.expectEqual(@as(u32, 1), b.n.read());
    try testing.expectEqualStrings("y", b.t.?.read());
}

test "putDecimal writes a number without a formatter" {
    var buf: [24]u8 = undefined;
    var at: usize = 0;
    putDecimal(&buf, &at, 0);
    putDecimal(&buf, &at, 1234567890);
    try testing.expectEqualStrings("01234567890", buf[0..at]);
}
