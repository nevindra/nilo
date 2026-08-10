//! Str — teks yang berasal dari sebuah request (ADR 0004).
//!
//! Hidupnya hanya selama request berjalan, karena byte-nya milik Arena
//! request. Isinya tidak bisa diambil tanpa memanggil sesuatu secara
//! sadar: `.lihat()` untuk meminjam selama request, `.keep()` untuk
//! menyalin ke memori berumur panjang.
//!
//! Jaminannya tidak bisa penuh — Zig tidak punya sistem kepemilikan.
//! Karena itu build debug menyematkan penanda umur: memakai Str setelah
//! request-nya selesai berhenti keras di laptop, bukan crash acak di
//! produksi. Build rilis membuang penanda ini, nol biaya.

const std = @import("std");
const builtin = @import("builtin");

pub const jebakan_aktif = builtin.mode == .Debug;

/// Penanda umur satu Arena request. Satu per koneksi, dinaikkan setiap
/// request selesai; semua Str dari request lama langsung basi.
pub const Umur = struct {
    gen: Gen = if (jebakan_aktif) 0 else {},

    const Gen = if (jebakan_aktif) u32 else void;

    pub fn selesai(self: *Umur) void {
        if (jebakan_aktif) self.gen +%= 1;
    }
};

pub const Str = struct {
    _byte: []const u8,
    _penanda: Penanda,

    const Penanda = if (jebakan_aktif) ?struct { hidup: *const u32, gen: u32 } else void;

    /// Str yang terikat umur sebuah request. Dipakai internal zfast.
    pub fn dariRequest(byte: []const u8, umur: *const Umur) Str {
        return .{
            ._byte = byte,
            ._penanda = if (jebakan_aktif) .{ .hidup = &umur.gen, .gen = umur.gen } else {},
        };
    }

    /// Str tanpa penanda umur, untuk literal di unit test handler.
    /// Tidak pernah dianggap basi.
    pub fn statis(byte: []const u8) Str {
        return .{ ._byte = byte, ._penanda = if (jebakan_aktif) null else {} };
    }

    /// Pinjam isinya. Hanya berlaku selama request-nya masih berjalan —
    /// untuk menyimpan lebih lama, pakai `.keep()`.
    pub fn lihat(self: Str) []const u8 {
        self.pastikanHidup();
        return self._byte;
    }

    /// Salin ke memori berumur panjang milik pemanggil, supaya aman
    /// disimpan setelah request selesai. Pemanggil yang membebaskan.
    pub fn keep(self: Str, gpa: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        self.pastikanHidup();
        return gpa.dupe(u8, self._byte);
    }

    pub fn panjang(self: Str) usize {
        self.pastikanHidup();
        return self._byte.len;
    }

    pub fn sama(self: Str, dengan: []const u8) bool {
        return std.mem.eql(u8, self.lihat(), dengan);
    }

    /// Parse sebagai bilangan basis 10.
    pub fn angka(self: Str, comptime T: type) std.fmt.ParseIntError!T {
        return std.fmt.parseInt(T, self.lihat(), 10);
    }

    /// Apakah penanda umurnya masih berlaku. Hanya ada saat jebakan
    /// aktif; dipakai di tes.
    pub fn hidup(self: Str) bool {
        comptime std.debug.assert(jebakan_aktif);
        const p = self._penanda orelse return true;
        return p.hidup.* == p.gen;
    }

    fn pastikanHidup(self: Str) void {
        if (jebakan_aktif) {
            if (!self.hidup()) @panic(
                "Str dipakai setelah request-nya selesai. " ++
                    "Data request mati bersama request; salin dengan .keep() " ++
                    "selama handler masih berjalan kalau perlu disimpan.",
            );
        }
    }
};

const testing = std.testing;

test "lihat dan sama" {
    var umur = Umur{};
    const s = Str.dariRequest("halo", &umur);
    try testing.expectEqualStrings("halo", s.lihat());
    try testing.expect(s.sama("halo"));
    try testing.expect(!s.sama("lain"));
}

test "keep menyalin ke memori pemanggil" {
    var umur = Umur{};
    const s = Str.dariRequest("halo", &umur);
    const salinan = try s.keep(testing.allocator);
    defer testing.allocator.free(salinan);
    umur.selesai();
    try testing.expectEqualStrings("halo", salinan);
}

test "angka" {
    var umur = Umur{};
    try testing.expectEqual(@as(u32, 42), try Str.dariRequest("42", &umur).angka(u32));
    try testing.expectError(error.InvalidCharacter, Str.dariRequest("4x", &umur).angka(u32));
}

test "penanda umur basi setelah request selesai" {
    if (!jebakan_aktif) return;
    var umur = Umur{};
    const s = Str.dariRequest("halo", &umur);
    try testing.expect(s.hidup());
    umur.selesai();
    try testing.expect(!s.hidup());
}

test "Str statis tidak pernah basi" {
    if (!jebakan_aktif) return;
    const s = Str.statis("literal");
    try testing.expect(s.hidup());
    try testing.expectEqualStrings("literal", s.lihat());
}
