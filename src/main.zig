//! Contoh App tahap 3 (lapisan bertipe) — sekaligus sasaran benchmark:
//! GET terute dengan path param yang mengembalikan JSON ~1KB, keep-alive
//! (metrik utama di docs/rencana.md).
//!
//! Perhatikan bentuk handler-nya: fungsi biasa yang menerima Layanan dan
//! path param, mengembalikan data. Tidak ada `Ctx` kecuali di tempat yang
//! memang butuh kendali penuh.

const std = @import("std");
const zfast = @import("zfast.zig");
const sekat = @import("sekat.zig");
const gagal = zfast.gagal;

pub const std_options_debug_io = sekat.debug_io;

const User = struct {
    id: u32,
    nama: []const u8,
    email: []const u8,
    bio: []const u8,
};

/// Layanan: didaftarkan sekali di `main`, diminta handler lewat tipenya.
const Db = struct {
    // Payload dibikin ~1KB supaya angka benchmark-nya sesuai metrik.
    const bio = "Penggemar sistem yang menulis Zig sebelum sarapan. " ** 18;

    maks_id: u32,

    fn cari(self: *const Db, id: u32) ?User {
        if (id == 0 or id > self.maks_id) return null;
        return .{
            .id = id,
            .nama = "Tester Terute",
            .email = "tester@contoh.dev",
            .bio = bio,
        };
    }
};

fn getUser(db: *Db, id: u32) !User {
    return db.cari(id) orelse gagal.notFound("user {d} tidak ditemukan", .{id});
}

fn sehat() []const u8 {
    return "hidup\n";
}

pub fn main() !void {
    var db = Db{ .maks_id = 1_000_000 };

    var app = zfast.App.init(std.heap.smp_allocator);
    defer app.deinit();

    try app.daftarkan(&db);
    try app.get("/users/:id", getUser);
    try app.get("/sehat", sehat);

    try app.dengarkan(.{});
}

// Handler adalah fungsi biasa, jadi diuji tanpa menyalakan server dan
// tanpa HTTP palsu — inilah yang dijanjikan ADR 0003.
test "getUser" {
    var db = Db{ .maks_id = 10 };
    try std.testing.expectEqual(@as(u32, 7), (try getUser(&db, 7)).id);
    try std.testing.expectError(error.Gagal, getUser(&db, 99));
}

test {
    _ = @import("zfast.zig");
}
