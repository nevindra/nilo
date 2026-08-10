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

    // ---- lewat JSON ----
    //
    // Supaya `struct { nama: Str }` bisa dipakai sebagai isi masuk maupun
    // jawaban keluar, bukan cuma `[]const u8` telanjang yang justru
    // dihindari ADR 0004.

    /// Keluar sebagai string JSON biasa, bukan sebagai objek berisi
    /// field internal.
    pub fn jsonStringify(self: Str, jw: anytype) !void {
        try jw.write(self.lihat());
    }

    /// Masuk dari string JSON. Penandanya belum terpasang di sini —
    /// parser tidak tahu request mana yang sedang berjalan — jadi App
    /// memanggil `stempel` setelah parse selesai.
    pub fn jsonParse(gpa: std.mem.Allocator, sumber: anytype, opsi: std.json.ParseOptions) !Str {
        return statis(try std.json.innerParse([]const u8, gpa, sumber, opsi));
    }

    pub fn jsonParseFromValue(gpa: std.mem.Allocator, sumber: std.json.Value, opsi: std.json.ParseOptions) !Str {
        return statis(try std.json.innerParseFromValue([]const u8, gpa, sumber, opsi));
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

/// Pasang penanda umur `umur` ke semua Str di dalam `nilai` (sebuah
/// penunjuk). Dipakai App setelah mem-parse isi request: hasil parse
/// hidup di Arena request, jadi Str di dalamnya harus ikut mati saat
/// request selesai.
///
/// Yang ditelusuri: Str, field struct, isi optional, elemen array, dan
/// elemen slice yang bisa diubah. Slice `const` dan union dilewati —
/// Str di sana tetap jalan, hanya saja jebakan debug tidak menjaganya.
pub fn stempel(nilai: anytype, umur: *const Umur) void {
    if (!jebakan_aktif) return;
    stempelDalam(nilai, umur, 8);
}

fn stempelDalam(nilai: anytype, umur: *const Umur, comptime sisa: u8) void {
    if (sisa == 0) return;
    const T = @typeInfo(@TypeOf(nilai)).pointer.child;
    if (comptime !mengandungStr(T, sisa)) return;

    if (T == Str) {
        nilai._penanda = .{ .hidup = &umur.gen, .gen = umur.gen };
        return;
    }
    switch (@typeInfo(T)) {
        .@"struct" => |s| inline for (s.fields) |f| {
            stempelDalam(&@field(nilai, f.name), umur, sisa - 1);
        },
        .optional => if (nilai.*) |*isi| stempelDalam(isi, umur, sisa - 1),
        .array => for (nilai) |*elemen| stempelDalam(elemen, umur, sisa - 1),
        .pointer => |p| switch (p.size) {
            .slice => if (!p.is_const) for (nilai.*) |*elemen| stempelDalam(elemen, umur, sisa - 1),
            else => {},
        },
        else => {},
    }
}

/// Apakah `T` mungkin memuat Str di dalamnya. Tipe yang tidak memuat Str
/// sama sekali — mayoritas — tidak menghasilkan kode apa pun.
fn mengandungStr(comptime T: type, comptime sisa: u8) bool {
    if (sisa == 0) return false;
    if (T == Str) return true;
    return switch (@typeInfo(T)) {
        .@"struct" => |s| for (s.fields) |f| {
            if (mengandungStr(f.type, sisa - 1)) break true;
        } else false,
        .optional => |o| mengandungStr(o.child, sisa - 1),
        .array => |a| mengandungStr(a.child, sisa - 1),
        .pointer => |p| p.size == .slice and !p.is_const and mengandungStr(p.child, sisa - 1),
        else => false,
    };
}

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

test "Str keluar sebagai string JSON biasa" {
    var umur = Umur{};
    const Pesan = struct { nama: Str, umur_tahun: u8 };
    const json = try std.json.Stringify.valueAlloc(
        testing.allocator,
        Pesan{ .nama = Str.dariRequest("wati", &umur), .umur_tahun = 30 },
        .{},
    );
    defer testing.allocator.free(json);
    try testing.expectEqualStrings("{\"nama\":\"wati\",\"umur_tahun\":30}", json);
}

test "Str masuk dari JSON lalu distempel umur request" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var umur = Umur{};

    const Masuk = struct { nama: Str, tag: []Str };
    var nilai = try std.json.parseFromSliceLeaky(
        Masuk,
        arena.allocator(),
        "{\"nama\":\"wati\",\"tag\":[\"a\",\"b\"]}",
        .{},
    );
    stempel(&nilai, &umur);

    try testing.expectEqualStrings("wati", nilai.nama.lihat());
    try testing.expectEqualStrings("b", nilai.tag[1].lihat());

    if (!jebakan_aktif) return;
    umur.selesai();
    try testing.expect(!nilai.nama.hidup());
    try testing.expect(!nilai.tag[1].hidup()); // ikut basi sampai ke dalam slice
}

test "stempel tidak menyentuh tipe tanpa Str" {
    var umur = Umur{};
    var polos = struct { a: u32, b: [2]f64 }{ .a = 1, .b = .{ 2, 3 } };
    stempel(&polos, &umur);
    try testing.expectEqual(@as(u32, 1), polos.a);
}

test "stempel menembus optional dan struct bersarang" {
    if (!jebakan_aktif) return;
    var umur = Umur{};
    const Dalam = struct { teks: Str };
    var nilai = struct { mungkin: ?Dalam }{ .mungkin = .{ .teks = Str.statis("halo") } };
    stempel(&nilai, &umur);

    try testing.expect(nilai.mungkin.?.teks.hidup());
    umur.selesai();
    try testing.expect(!nilai.mungkin.?.teks.hidup());
}
