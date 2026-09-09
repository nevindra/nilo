//! What a response holding a `sql.Uuid` costs, before and after ADR 0182.
//!
//! `covers()` used to answer false for any type carrying `jsonStringify`, and
//! it is answered for the **whole value** — so one `Uuid` field anywhere in a
//! response sent the entire struct to `std.json`, strings included, which is
//! the part the generated writer exists for. In a product whose every key is a
//! uuid that is every response.
//!
//! Path A: `std.json` on the whole value.   What nilo sent before.
//! Path B: the generated writer, with the leaf handed to `std.json`. After.
//! Path C: control. The same struct with the uuids as plain text fields, on
//!         the generated writer — the ceiling B is chasing, and it says how
//!         much of B's remaining cost is the leaf itself.
//!
//! ```
//! zig run --dep nilo_json_writer -Mroot=spike/leaf_json/main.zig \
//!   --dep nilo_core -Mnilo_json_writer=http/json.zig \
//!   -Mnilo_core=core/core.zig -O ReleaseFast
//! ```

const std = @import("std");
const json = @import("nilo_json_writer");
const print = std.debug.print;

/// A stand-in for `sql.Uuid`: sixteen bytes that write themselves as
/// thirty-six characters and say so.
const Uuid = struct {
    bytes: [16]u8,

    pub const nilo_openapi = .{ .type = "string", .format = "uuid" };

    pub fn toText(self: Uuid) [36]u8 {
        const hex = "0123456789abcdef";
        var out: [36]u8 = undefined;
        var at: usize = 0;
        for (self.bytes, 0..) |b, i| {
            if (i == 4 or i == 6 or i == 8 or i == 10) {
                out[at] = '-';
                at += 1;
            }
            out[at] = hex[b >> 4];
            out[at + 1] = hex[b & 0x0f];
            at += 2;
        }
        return out;
    }

    pub fn jsonStringify(self: Uuid, jw: anytype) !void {
        const text = self.toText();
        try jw.write(&text);
    }
};

/// One row of the ERP's partner list, which is where the report's 77 fields
/// live: three uuids and four strings.
const Contact = struct {
    id: Uuid,
    partner_id: Uuid,
    owner_id: Uuid,
    full_name: []const u8,
    email: []const u8,
    phone: []const u8,
    note: []const u8,
    active: bool,
    seats: u32,
};

/// The same shape with the keys already text, which is what a DTO layer wrote
/// out by hand before either of these existed.
const AsText = struct {
    id: []const u8,
    partner_id: []const u8,
    owner_id: []const u8,
    full_name: []const u8,
    email: []const u8,
    phone: []const u8,
    note: []const u8,
    active: bool,
    seats: u32,
};

const rounds = 200_000;

/// The same clock `spike/union_json/` reads, for the same reason: a monotonic
/// nanosecond counter with nothing between it and the syscall.
fn nanos() u64 {
    var ts: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

pub fn main() !void {
    const one: Contact = .{
        .id = .{ .bytes = .{ 1, 26, 1, 119, 92, 232, 121, 50, 180, 43, 160, 84, 49, 165, 196, 200 } },
        .partner_id = .{ .bytes = @splat(7) },
        .owner_id = .{ .bytes = @splat(9) },
        .full_name = "Wati Nurhayati",
        .email = "wati@example.dev",
        .phone = "+62 812 3456 7890",
        .note = "renewal in March, wants the annual plan",
        .active = true,
        .seats = 24,
    };

    const id_text = one.id.toText();
    const partner_text = one.partner_id.toText();
    const owner_text = one.owner_id.toText();
    const flat: AsText = .{
        .id = &id_text,
        .partner_id = &partner_text,
        .owner_id = &owner_text,
        .full_name = one.full_name,
        .email = one.email,
        .phone = one.phone,
        .note = one.note,
        .active = one.active,
        .seats = one.seats,
    };

    var buf: [4096]u8 = undefined;

    // Path A — what nilo sent before: one leaf sends the whole value.
    var a: u64 = 0;
    {
        const start = nanos();
        for (0..rounds) |_| {
            var w = std.Io.Writer.fixed(&buf);
            try std.json.Stringify.value(one, .{}, &w);
            std.mem.doNotOptimizeAway(w.end);
        }
        a = (nanos() - start) / rounds;
    }

    // Path B — the generated writer, with the leaf handed to `std.json`.
    var b: u64 = 0;
    {
        const start = nanos();
        for (0..rounds) |_| {
            var w = std.Io.Writer.fixed(&buf);
            try json.write(&w, one);
            std.mem.doNotOptimizeAway(w.end);
        }
        b = (nanos() - start) / rounds;
    }

    // Path C — the control: no leaf anywhere.
    var c: u64 = 0;
    {
        const start = nanos();
        for (0..rounds) |_| {
            var w = std.Io.Writer.fixed(&buf);
            try json.write(&w, flat);
            std.mem.doNotOptimizeAway(w.end);
        }
        c = (nanos() - start) / rounds;
    }

    // The bytes have to be the same, or the numbers are about two outputs.
    var one_buf: [4096]u8 = undefined;
    var two_buf: [4096]u8 = undefined;
    var wa = std.Io.Writer.fixed(&one_buf);
    var wb = std.Io.Writer.fixed(&two_buf);
    try std.json.Stringify.value(one, .{}, &wa);
    try json.write(&wb, one);
    if (!std.mem.eql(u8, one_buf[0..wa.end], two_buf[0..wb.end])) {
        print("MISMATCH\n  A: {s}\n  B: {s}\n", .{ one_buf[0..wa.end], two_buf[0..wb.end] });
        return error.OutputChanged;
    }

    print("{d} bytes, {d} rounds each\n\n", .{ wa.end, rounds });
    print("A  std.json, whole value (before)  {d} ns\n", .{a});
    print("B  generated writer, leaf to std   {d} ns\n", .{b});
    print("C  control, no leaf at all         {d} ns\n", .{c});
}
