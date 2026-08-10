//! Contoh App tahap 2 (lapisan Ctx) — sekaligus sasaran benchmark:
//! GET terute dengan path param yang mengembalikan JSON ~1KB, keep-alive
//! (metrik utama di docs/rencana.md).

const std = @import("std");
const zfast = @import("zfast.zig");
const sekat = @import("sekat.zig");

pub const std_options_debug_io = sekat.debug_io;

const User = struct {
    id: u32,
    nama: []const u8,
    email: []const u8,
    bio: []const u8,
};

// Payload dibikin ~1KB supaya angka benchmark-nya sesuai metrik.
const bio_contoh = "Penggemar sistem yang menulis Zig sebelum sarapan. " ** 18;

fn getUser(c: *zfast.Ctx) !void {
    const id = (c.param("id").?).angka(u32) catch
        return c.balasTeks(400, "id harus angka\n");
    try c.balasJson(200, User{
        .id = id,
        .nama = "Tester Terute",
        .email = "tester@contoh.dev",
        .bio = bio_contoh,
    });
}

fn sehat(c: *zfast.Ctx) !void {
    try c.balasTeks(200, "hidup\n");
}

pub fn main() !void {
    var app = zfast.App.init(std.heap.smp_allocator);
    defer app.deinit();

    try app.get("/users/:id", getUser);
    try app.get("/sehat", sehat);

    try app.dengarkan(.{});
}

test {
    _ = @import("zfast.zig");
}
