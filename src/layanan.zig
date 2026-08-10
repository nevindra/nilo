//! Layanan — barang berumur panjang yang didaftarkan sekali saat App
//! dibuat (koneksi database, konfigurasi, logger), lalu diminta Handler
//! berdasarkan tipenya.
//!
//! ```zig
//! try app.daftarkan(&db);              // sekali, saat merakit App
//! fn getUser(db: *Db, id: u32) !User   // diminta lewat tipe argumen
//! ```
//!
//! Daftarnya runtime, kuncinya nama tipe. Alasannya ada di ADR 0006:
//! `App` tetap satu tipe biasa, dan handler yang meminta Layanan yang
//! belum didaftarkan tertangkap saat `dengarkan()` — sebelum satu
//! request pun dilayani, bukan jam tiga pagi.

const std = @import("std");

/// Apa yang sebuah handler butuhkan dari daftar. Dihitung saat kompilasi
/// oleh mesin comptime, lalu dicek sekali saat startup.
pub const Kebutuhan = struct {
    tipe: []const u8,
    /// Handler minta penunjuk yang bisa diubah (`*Db`, bukan `*const Db`).
    perlu_ubah: bool,
    /// Rute yang membutuhkannya, untuk pesan error yang bisa ditindaklanjuti.
    rute: []const u8,
};

/// Kebutuhan yang tersirat dari sebuah tipe penunjuk argumen handler.
pub fn kebutuhanDari(comptime P: type, comptime rute: []const u8) Kebutuhan {
    const info = @typeInfo(P).pointer;
    return .{
        .tipe = @typeName(info.child),
        .perlu_ubah = !info.is_const,
        .rute = rute,
    };
}

pub const Daftar = struct {
    gpa: std.mem.Allocator,
    isi: std.ArrayList(Entri) = .empty,

    const Entri = struct {
        tipe: []const u8,
        ptr: *anyopaque,
        konstan: bool,
    };

    pub fn init(gpa: std.mem.Allocator) Daftar {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Daftar) void {
        self.isi.deinit(self.gpa);
    }

    /// Daftarkan sebuah Layanan. `ptr` harus hidup selama App hidup —
    /// daftar ini hanya menyimpan penunjuknya, tidak menyalin apa pun.
    ///
    /// Dua Layanan bertipe sama (misalnya dua database) harus dibedakan
    /// dengan pembungkus bernama; yang kedua ditolak di sini (ADR 0003).
    pub fn tambah(self: *Daftar, ptr: anytype) !void {
        const P = @TypeOf(ptr);
        const info = switch (@typeInfo(P)) {
            .pointer => |p| p,
            else => @compileError(
                "zfast: app.daftarkan() minta penunjuk ke Layanan, bukan " ++ @typeName(P) ++
                    ".\n  Layanan hidup lebih panjang dari App, jadi yang didaftarkan penunjuknya: " ++
                    "`app.daftarkan(&db)`.",
            ),
        };
        if (info.size != .one) @compileError(
            "zfast: app.daftarkan() minta penunjuk ke satu nilai, bukan " ++ @typeName(P) ++ ".",
        );

        const tipe = @typeName(info.child);
        for (self.isi.items) |e| {
            if (namaSama(e.tipe, tipe)) return error.LayananSudahAda;
        }
        try self.isi.append(self.gpa, .{
            .tipe = tipe,
            .ptr = @constCast(@ptrCast(ptr)),
            .konstan = info.is_const,
        });
    }

    /// Ambil Layanan bertipe `P` (sebuah tipe penunjuk), atau null kalau
    /// belum didaftarkan — atau kalau didaftarkan sebagai `*const` tapi
    /// handler memintanya bisa diubah.
    pub fn ambil(self: *const Daftar, comptime P: type) ?P {
        const info = @typeInfo(P).pointer;
        const tipe = @typeName(info.child);
        for (self.isi.items) |e| {
            if (!namaSama(e.tipe, tipe)) continue;
            if (e.konstan and !info.is_const) return null;
            return @ptrCast(@alignCast(e.ptr));
        }
        return null;
    }

    pub fn punya(self: *const Daftar, k: Kebutuhan) bool {
        for (self.isi.items) |e| {
            if (!namaSama(e.tipe, k.tipe)) continue;
            return !(e.konstan and k.perlu_ubah);
        }
        return false;
    }

    /// Nama tipe dari `@typeName` biasanya literal yang sama persis, jadi
    /// bandingkan penunjuknya dulu; perbandingan isi cuma jaring pengaman.
    fn namaSama(a: []const u8, b: []const u8) bool {
        return a.ptr == b.ptr or std.mem.eql(u8, a, b);
    }
};

// ---- tes ----

const testing = std.testing;

const Db = struct { n: u32 = 0 };
const Konfigurasi = struct { debug: bool = false };

test "daftarkan lalu ambil berdasarkan tipe" {
    var d = Daftar.init(testing.allocator);
    defer d.deinit();

    var db = Db{ .n = 7 };
    var cfg = Konfigurasi{ .debug = true };
    try d.tambah(&db);
    try d.tambah(&cfg);

    try testing.expectEqual(@as(u32, 7), d.ambil(*Db).?.n);
    try testing.expect(d.ambil(*Konfigurasi).?.debug);

    // Diubah lewat Layanan-nya, terlihat di aslinya.
    d.ambil(*Db).?.n = 9;
    try testing.expectEqual(@as(u32, 9), db.n);
}

test "tipe yang belum didaftarkan mengembalikan null" {
    var d = Daftar.init(testing.allocator);
    defer d.deinit();

    var db = Db{};
    try d.tambah(&db);
    try testing.expect(d.ambil(*Konfigurasi) == null);
}

test "dua Layanan bertipe sama ditolak" {
    var d = Daftar.init(testing.allocator);
    defer d.deinit();

    var satu = Db{};
    var dua = Db{};
    try d.tambah(&satu);
    try testing.expectError(error.LayananSudahAda, d.tambah(&dua));
}

test "didaftarkan const, diminta bisa diubah, ditolak" {
    var d = Daftar.init(testing.allocator);
    defer d.deinit();

    const cfg = Konfigurasi{ .debug = true };
    try d.tambah(&cfg);

    try testing.expect(d.ambil(*const Konfigurasi) != null);
    try testing.expect(d.ambil(*Konfigurasi) == null);
    try testing.expect(d.punya(kebutuhanDari(*const Konfigurasi, "/x")));
    try testing.expect(!d.punya(kebutuhanDari(*Konfigurasi, "/x")));
}

test "punya menjawab kebutuhan yang dihitung saat kompilasi" {
    var d = Daftar.init(testing.allocator);
    defer d.deinit();

    var db = Db{};
    try d.tambah(&db);

    try testing.expect(d.punya(kebutuhanDari(*Db, "/users/:id")));
    try testing.expect(d.punya(kebutuhanDari(*const Db, "/users/:id")));
    try testing.expect(!d.punya(kebutuhanDari(*Konfigurasi, "/users/:id")));
}
