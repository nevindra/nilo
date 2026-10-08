//! A float as JSON, spelled the way serde_json 1.0.150 spells it
//! ([ADR 096](../docs/adr/096-a-byte-that-is-not-text-is-not-a-string.md)).
//!
//! The digits are the shortest that read back as the same bits, which is what
//! `std.json` writes too. What differs is the layout around them:
//!
//! - **A decimal exponent from -5 to 15 is written positionally**, and an
//!   integral value keeps its `.0`: `0.0`, `1.0`, `-0.0`, `1000000000000000.0`,
//!   `0.000015`. The `.0` is what keeps a float distinguishable from an integer
//!   for a typed client.
//! - **Outside that range it is scientific with an explicit sign**: `1e+16`,
//!   `1.2345678901234568e+20`, `1e-7`, `5e-324`. `std.json` writes `f64::MAX`
//!   as 309 digits and `5e-324` as 320 characters, which is unbounded bloat on
//!   the response path.
//! - **An `f32` is spelled from its own shortest digits** (`1.1`, not the
//!   `1.100000023841858` that widening to `f64` gives), and its positional
//!   range is -6 to 12, which is serde_json's too.
//! - **Infinity and NaN are `null`**, as before.
//!
//! No allocation and no formatting machinery: the digits come from the routine
//! `std.fmt.float` runs for `{e}` (Ryu), and are laid out in a stack buffer of
//! `maxLen(T)` bytes, which is 24 for an `f64` and 17 for an `f32`. A whole
//! number below 2^53 (2^24 for an `f32`) skips Ryu: it is its own digits.

const std = @import("std");

/// The most bytes `spell` can write for a `T`: the sign, the digits and the
/// point, or the exponent. 24 for `f64`, 17 for `f32`.
pub fn maxLen(comptime T: type) comptime_int {
    const digits = switch (@bitSizeOf(T)) {
        16 => 5,
        32 => 9,
        64 => 17,
        80 => 21,
        128 => 36,
        else => @compileError("not a float width: " ++ @typeName(T)),
    };
    const exp_digits = if (@bitSizeOf(T) <= 32) 2 else if (@bitSizeOf(T) == 64) 3 else 4;
    const lo = positionalLow(T);
    const hi = positionalHigh(T);
    const small = 1 + 2 + (-lo - 1) + digits; // -0.000015 shape
    const big = 1 + (hi + 1) + 2; // -1000000000000000.0 shape
    const sci = 1 + digits + 1 + 2 + exp_digits; // -1.2345678901234568e+308 shape
    return @max(small, big, sci);
}

fn positionalLow(comptime T: type) comptime_int {
    return if (@bitSizeOf(T) <= 32) -6 else -5;
}

fn positionalHigh(comptime T: type) comptime_int {
    return if (@bitSizeOf(T) <= 32) 12 else 15;
}

/// Write `v` as JSON: its spelling when it is finite, `null` when it is not.
pub fn write(w: *std.Io.Writer, v: anytype) std.Io.Writer.Error!void {
    const T = if (@TypeOf(v) == comptime_float) f64 else @TypeOf(v);
    const x: T = v;
    if (!std.math.isFinite(x)) return w.writeAll("null");
    var buf: [maxLen(T)]u8 = undefined;
    return w.writeAll(spell(T, &buf, x));
}

/// The decimal digits of `m` at the end of `tmp`, two at a time from the right;
/// returns where they start.
fn digitsOf(tmp: *[40]u8, m_: anytype) usize {
    var m = m_;
    var start: usize = tmp.len;
    while (m >= 100) {
        start -= 2;
        tmp[start..][0..2].* = std.fmt.digits2(@intCast(m % 100));
        m /= 100;
    }
    if (m >= 10) {
        start -= 2;
        tmp[start..][0..2].* = std.fmt.digits2(@intCast(m));
    } else {
        start -= 1;
        tmp[start] = '0' + @as(u8, @intCast(m));
    }
    return start;
}

/// The spelling of a finite `v`, in `buf`. Asserts `v` is finite.
pub fn spell(comptime T: type, buf: *[maxLen(T)]u8, v: T) []const u8 {
    std.debug.assert(std.math.isFinite(v));
    var at: usize = 0;
    if (std.math.signbit(v)) {
        buf[0] = '-';
        at = 1;
    }

    // **A whole number below 2^(fraction bits + 1) is its own digits**: every
    // such integer is exactly representable and spaced by at most 1, so no
    // shorter digit string reads back as it. `0.0` and `1.0` and `100.0` are
    // most of the floats a response carries, and they skip Ryu.
    if (comptime @bitSizeOf(T) <= 64) {
        const limit: T = comptime @floatFromInt(@as(u64, 1) << (std.math.floatFractionalBits(T) + 1));
        const a = @abs(v);
        if (a < limit and a == @floor(a)) {
            var tmp: [40]u8 = undefined;
            const start = digitsOf(&tmp, @as(u64, @intFromFloat(a)));
            const len = tmp.len - start;
            @memcpy(buf[at..][0..len], tmp[start..]);
            @memcpy(buf[at + len ..][0..2], ".0");
            return buf[0 .. at + len + 2];
        }
    }

    const I = @Int(.unsigned, @bitSizeOf(T));
    const DT = if (@bitSizeOf(T) <= 64) u64 else u128;
    const tables = comptime switch (DT) {
        u64 => if (@import("builtin").mode == .small)
            &std.fmt.float.Backend64_TablesSmall
        else
            &std.fmt.float.Backend64_TablesFull,
        else => &std.fmt.float.Backend128_Tables,
    };
    const explicit_leading_bit = std.math.floatMantissaBits(T) - std.math.floatFractionalBits(T) != 0;
    const d = std.fmt.float.binaryToDecimal(
        DT,
        @as(I, @bitCast(v)),
        std.math.floatMantissaBits(T),
        std.math.floatExponentBits(T),
        explicit_leading_bit,
        tables,
    );
    if (v == 0) {
        @memcpy(buf[at..][0..3], "0.0");
        return buf[0 .. at + 3];
    }

    // The digits of the mantissa. Ryu keeps the zeros of a value like 100 in
    // the exponent already; the strip below is for the day a `std` that does
    // not, and costs one compare.
    var tmp: [40]u8 = undefined;
    const start = digitsOf(&tmp, d.mantissa);
    var end: usize = tmp.len;
    var exp: i32 = d.exponent;
    while (end > start + 1 and tmp[end - 1] == '0') {
        end -= 1;
        exp += 1;
    }
    const digits = tmp[start..end];
    const n: i32 = @intCast(digits.len);
    // The decimal exponent of the first digit: 1.5e-5 has -5.
    const point = exp + n - 1;

    if (point >= positionalLow(T) and point <= positionalHigh(T)) {
        if (point < 0) {
            // 0.000015
            const zeros: usize = @intCast(-point - 1);
            @memcpy(buf[at..][0..2], "0.");
            at += 2;
            @memset(buf[at..][0..zeros], '0');
            at += zeros;
            @memcpy(buf[at..][0..digits.len], digits);
            at += digits.len;
        } else {
            const int_len: usize = @intCast(point + 1);
            if (digits.len <= int_len) {
                // 1000.0
                @memcpy(buf[at..][0..digits.len], digits);
                at += digits.len;
                @memset(buf[at..][0 .. int_len - digits.len], '0');
                at += int_len - digits.len;
                @memcpy(buf[at..][0..2], ".0");
                at += 2;
            } else {
                // 123456.789
                @memcpy(buf[at..][0..int_len], digits[0..int_len]);
                at += int_len;
                buf[at] = '.';
                at += 1;
                @memcpy(buf[at..][0 .. digits.len - int_len], digits[int_len..]);
                at += digits.len - int_len;
            }
        }
        return buf[0..at];
    }

    // 1.2345678901234568e+20
    buf[at] = digits[0];
    at += 1;
    if (digits.len > 1) {
        buf[at] = '.';
        at += 1;
        @memcpy(buf[at..][0 .. digits.len - 1], digits[1..]);
        at += digits.len - 1;
    }
    buf[at] = 'e';
    buf[at + 1] = if (point < 0) '-' else '+';
    at += 2;
    var e: u32 = @abs(point);
    var etmp: [4]u8 = undefined;
    var es: usize = etmp.len;
    while (true) {
        es -= 1;
        etmp[es] = '0' + @as(u8, @intCast(e % 10));
        e /= 10;
        if (e == 0) break;
    }
    const elen = etmp.len - es;
    @memcpy(buf[at..][0..elen], etmp[es..]);
    return buf[0 .. at + elen];
}

const testing = std.testing;

fn expectSpelled(comptime T: type, expected: []const u8, v: T) !void {
    var buf: [maxLen(T)]u8 = undefined;
    try testing.expectEqualStrings(expected, spell(T, &buf, v));
}

// What `serde_json::to_string(&json!(x))` printed for these 26 values and two
// integers, serde_json 1.0.150 (zmij 1.0.21), by
// `photon/zig/spike/s4-checks/rust-fixtures/src/bin/json_numbers.rs`. The two
// that are not finite print as `null` and are the last test's.
const serde_f64 = [_]struct { v: f64, text: []const u8 }{
    .{ .v = 0.0, .text = "0.0" },
    .{ .v = -0.0, .text = "-0.0" },
    .{ .v = 1.0, .text = "1.0" },
    .{ .v = 2.5, .text = "2.5" },
    .{ .v = 10.0, .text = "10.0" },
    .{ .v = 100.0, .text = "100.0" },
    .{ .v = 0.1, .text = "0.1" },
    .{ .v = @as(f64, 0.1) + @as(f64, 0.2), .text = "0.30000000000000004" },
    .{ .v = 1e-7, .text = "1e-7" },
    .{ .v = 1.5e-5, .text = "0.000015" },
    .{ .v = 0.0001, .text = "0.0001" },
    .{ .v = 0.001, .text = "0.001" },
    .{ .v = 123456.789, .text = "123456.789" },
    .{ .v = 1e15, .text = "1000000000000000.0" },
    .{ .v = 1e16, .text = "1e+16" },
    .{ .v = 1e17, .text = "1e+17" },
    .{ .v = 123456789012345680000.0, .text = "1.2345678901234568e+20" },
    .{ .v = 1e21, .text = "1e+21" },
    .{ .v = 1e22, .text = "1e+22" },
    .{ .v = std.math.floatMax(f64), .text = "1.7976931348623157e+308" },
    .{ .v = 5e-324, .text = "5e-324" },
    .{ .v = @as(f64, 33.0) / @as(f64, 1630.0), .text = "0.020245398773006136" },
    .{ .v = @as(f64, 1630.0) / @as(f64, 3600.0), .text = "0.4527777777777778" },
    .{ .v = -1.5, .text = "-1.5" },
};

test "the floats serde_json 1.0.150 was asked about are spelled byte for byte" {
    for (serde_f64) |c| try expectSpelled(f64, c.text, c.v);
}

test "the edges of the positional range, on both sides, for an f64" {
    try expectSpelled(f64, "0.00001", 1e-5);
    try expectSpelled(f64, "1e-6", 1e-6);
    try expectSpelled(f64, "9999999999999998.0", 9999999999999998.0);
    try expectSpelled(f64, "1e+16", 1e16);
    try expectSpelled(f64, "1.5e-6", 1.5e-6);
    try expectSpelled(f64, "-0.00001234", -1.234e-5);
    try expectSpelled(f64, "2.2250738585072014e-308", std.math.floatMin(f64));
    try expectSpelled(f64, "-1.7976931348623157e+308", -std.math.floatMax(f64));
}

test "an f32 is spelled from its own digits and its own positional range" {
    try expectSpelled(f32, "1.1", 1.1);
    try expectSpelled(f32, "0.1", 0.1);
    try expectSpelled(f32, "1.0", 1.0);
    try expectSpelled(f32, "-0.0", -0.0);
    try expectSpelled(f32, "16777216.0", 16777216.0);
    try expectSpelled(f32, "0.000001", 1e-6);
    try expectSpelled(f32, "1e-7", 1e-7);
    try expectSpelled(f32, "1000000000000.0", 1e12);
    try expectSpelled(f32, "1e+13", 1e13);
    try expectSpelled(f32, "3.4028235e+38", std.math.floatMax(f32));
    try expectSpelled(f32, "1e-45", std.math.floatTrueMin(f32));
}

test "the longest spelling of each width fits the buffer maxLen promises" {
    try testing.expectEqual(24, maxLen(f64));
    try testing.expectEqual(17, maxLen(f32));
    try expectSpelled(f64, "-0.0000123456789012345", -0.0000123456789012345);
    try expectSpelled(f64, "-1.2345678901234567e+308", -1.2345678901234567e308);
    try expectSpelled(f32, "-0.000001234567", -0.000001234567);
}

fn roundTrips(comptime T: type, v: T) !void {
    var buf: [maxLen(T)]u8 = undefined;
    const text = spell(T, &buf, v);
    const back = try std.fmt.parseFloat(T, text);
    const U = @Int(.unsigned, @bitSizeOf(T));
    try testing.expectEqual(@as(U, @bitCast(v)), @as(U, @bitCast(back)));
    // JSON number grammar: no leading `+`, no bare `.`, no `inf`.
    try testing.expect(text[0] == '-' or std.ascii.isDigit(text[0]));
    try testing.expect(std.mem.indexOfAny(u8, text, "ni") == null);
}

test "every random bit pattern of an f64 reads back as the same bits" {
    var prng = std.Random.DefaultPrng.init(0x5eed_f10a7);
    const r = prng.random();
    var done: usize = 0;
    while (done < 300_000) {
        const v: f64 = @bitCast(r.int(u64));
        if (!std.math.isFinite(v)) continue;
        try roundTrips(f64, v);
        done += 1;
    }
}

test "every random bit pattern of an f32 reads back as the same bits" {
    var prng = std.Random.DefaultPrng.init(0x5eed_f32);
    const r = prng.random();
    var done: usize = 0;
    while (done < 300_000) {
        const v: f32 = @bitCast(r.int(u32));
        if (!std.math.isFinite(v)) continue;
        try roundTrips(f32, v);
        done += 1;
    }
}

test "the whole of an f16 reads back as the same bits" {
    var bits: u32 = 0;
    while (bits <= std.math.maxInt(u16)) : (bits += 1) {
        const v: f16 = @bitCast(@as(u16, @intCast(bits)));
        if (!std.math.isFinite(v)) continue;
        try roundTrips(f16, v);
    }
}

test "a whole number takes the integer path up to 2^53 and Ryu from there, with the same text either side" {
    try expectSpelled(f64, "9007199254740991.0", 9007199254740991.0);
    try expectSpelled(f64, "9007199254740992.0", 9007199254740992.0);
    try expectSpelled(f64, "9007199254740994.0", 9007199254740994.0);
    try expectSpelled(f64, "9999999999999998.0", 9999999999999998.0);
    try expectSpelled(f32, "16777215.0", 16777215.0);
    try expectSpelled(f32, "16777216.0", 16777216.0);
    try expectSpelled(f32, "999999900000.0", 999999900000.0);
    try expectSpelled(f16, "2047.0", 2047.0);
    try expectSpelled(f16, "65500.0", 65504.0);
    try expectSpelled(f64, "-42.0", -42.0);

    var prng = std.Random.DefaultPrng.init(0x1417);
    const r = prng.random();
    for (0..100_000) |_| {
        const n = r.uintLessThan(u64, 1 << 53);
        var want: [32]u8 = undefined;
        const text = try std.fmt.bufPrint(&want, "{d}.0", .{n});
        try expectSpelled(f64, text, @floatFromInt(n));
    }
}

test "a float that is not finite is written as null" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write(&out.writer, -std.math.inf(f32));
    try write(&out.writer, std.math.nan(f32));
    try write(&out.writer, std.math.inf(f64));
    try write(&out.writer, std.math.nan(f64));
    try testing.expectEqualStrings("nullnullnullnull", out.written());
}
