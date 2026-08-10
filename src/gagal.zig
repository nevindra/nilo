//! Fungsi gagal — hentikan request dengan status dan pesan tertentu,
//! dari mana saja, tanpa perlu memegang Ctx (ADR 0005).
//!
//! ```zig
//! fn getUser(db: *Db, id: u32) !User {
//!     return db.cari(id) orelse gagal.notFound("user {d} tidak ada", .{id});
//! }
//! ```
//!
//! Cara kerjanya: pesan ditulis ke Kotak milik request yang sedang
//! berjalan, lalu dikembalikan `error.Gagal`. App yang memanggil handler
//! membaca Kotak itu dan merakit responsnya.
//!
//! Kotak ditemukan lewat slot Sekat, yang terikat ke fiber — bukan ke
//! utas — sehingga dua request yang bergantian di satu utas tidak pernah
//! saling menimpa pesan (ADR 0007). Dipanggil di luar request, tidak ada
//! Kotak, dan Fungsi gagal hanya mengembalikan error biasa tanpa pesan;
//! handler tetap bisa diuji sebagai fungsi biasa.

const std = @import("std");
const sekat = @import("sekat.zig");

/// Pesan lebih panjang dari ini dipotong. Kotak sengaja berupa buffer
/// tetap, bukan alokasi dari Arena request: jalur gagal tidak boleh
/// punya jalur gagal sendiri, dan Fungsi gagal harus tetap bekerja saat
/// dipanggil di luar request.
pub const maks_pesan = 240;

pub const Galat = error{Gagal};

/// Tempat pesan Fungsi gagal untuk satu request. App menyediakan satu
/// per koneksi dan mengosongkannya di awal tiap request.
pub const Kotak = struct {
    status: u16 = 0,
    n: usize = 0,
    buf: [maks_pesan]u8 = undefined,

    pub fn kosongkan(self: *Kotak) void {
        self.status = 0;
        self.n = 0;
    }

    pub fn ada(self: *const Kotak) bool {
        return self.status != 0;
    }

    pub fn pesan(self: *const Kotak) []const u8 {
        return self.buf[0..self.n];
    }

    pub fn tulis(self: *Kotak, kode: u16, comptime fmt: []const u8, args: anytype) void {
        self.status = kode;
        var w = std.Io.Writer.fixed(&self.buf);
        // Pesan yang kepanjangan dipotong, bukan dibuang: separuh pesan
        // masih jauh lebih berguna daripada 500 tanpa keterangan.
        w.print(fmt, args) catch {};
        self.n = w.end;
    }
};

/// Kotak milik request yang sedang berjalan, atau null di luar request.
pub fn kotakAktif() ?*Kotak {
    const p = sekat.slot() orelse return null;
    return @ptrCast(@alignCast(p));
}

/// Hentikan request dengan status apa pun.
pub fn status(kode: u16, comptime fmt: []const u8, args: anytype) Galat {
    if (kotakAktif()) |k| k.tulis(kode, fmt, args);
    return error.Gagal;
}

pub fn badRequest(comptime fmt: []const u8, args: anytype) Galat {
    return status(400, fmt, args);
}

pub fn unauthorized(comptime fmt: []const u8, args: anytype) Galat {
    return status(401, fmt, args);
}

pub fn forbidden(comptime fmt: []const u8, args: anytype) Galat {
    return status(403, fmt, args);
}

pub fn notFound(comptime fmt: []const u8, args: anytype) Galat {
    return status(404, fmt, args);
}

pub fn conflict(comptime fmt: []const u8, args: anytype) Galat {
    return status(409, fmt, args);
}

pub fn unprocessable(comptime fmt: []const u8, args: anytype) Galat {
    return status(422, fmt, args);
}

pub fn tooManyRequests(comptime fmt: []const u8, args: anytype) Galat {
    return status(429, fmt, args);
}

/// 500 dengan pesan. Pesannya ikut terkirim ke klien, jadi jangan taruh
/// apa pun yang tidak boleh dilihat orang luar.
pub fn internal(comptime fmt: []const u8, args: anytype) Galat {
    return status(500, fmt, args);
}

/// Error Zig biasa yang datang dari mana pun — database, parsing,
/// alokasi — dipetakan lewat tabel ini. Yang tidak dikenali menjadi 500
/// dan dicatat dengan nama errornya (ADR 0005).
///
/// Nama Inggris maupun Indonesia diterima, supaya error dari pustaka
/// pihak ketiga ikut kena tanpa pengguna harus memetakannya sendiri.
pub fn statusUntuk(err: anyerror) u16 {
    return switch (err) {
        error.Gagal => 500, // seharusnya sudah tertangani lewat Kotak

        error.NotFound, error.TidakDitemukan, error.FileNotFound => 404,

        error.InvalidCharacter,
        error.Overflow,
        error.InvalidNumber,
        error.SyntaxError,
        error.UnexpectedToken,
        error.UnexpectedEndOfInput,
        error.InvalidEnumTag,
        error.MissingField,
        error.UnknownField,
        error.DuplicateField,
        error.LengthMismatch,
        error.MasukanTidakSah,
        => 400,

        error.Unauthorized, error.TidakBerwenang => 401,
        error.Forbidden, error.Terlarang => 403,
        error.Conflict, error.Konflik => 409,
        error.IsiKebesaran => 413,
        error.ChunkedBelumDidukung => 501,
        error.Timeout, error.Canceled => 503,

        else => 500,
    };
}

// ---- tes ----

const testing = std.testing;

/// Fungsi gagal mengembalikan nilai error telanjang supaya bisa dipakai
/// sebagai `orelse gagal.notFound(...)`; di tes ia dibungkus dulu jadi
/// error union.
fn hasil(e: Galat) Galat!void {
    return e;
}

test "tanpa Kotak, Fungsi gagal cuma error biasa" {
    const sebelumnya = sekat.pasangSlotCadangan(null);
    defer _ = sekat.pasangSlotCadangan(sebelumnya);

    try testing.expectError(error.Gagal, hasil(notFound("user {d} tidak ada", .{7})));
}

test "dengan Kotak, pesan dan status tersimpan" {
    var kotak = Kotak{};
    const sebelumnya = sekat.pasangSlotCadangan(&kotak);
    defer _ = sekat.pasangSlotCadangan(sebelumnya);

    try testing.expectError(error.Gagal, hasil(notFound("user {d} tidak ada", .{7})));
    try testing.expect(kotak.ada());
    try testing.expectEqual(@as(u16, 404), kotak.status);
    try testing.expectEqualStrings("user 7 tidak ada", kotak.pesan());

    kotak.kosongkan();
    try testing.expect(!kotak.ada());
    try testing.expectEqualStrings("", kotak.pesan());
}

test "pesan kepanjangan dipotong, bukan dibuang" {
    var kotak = Kotak{};
    const sebelumnya = sekat.pasangSlotCadangan(&kotak);
    defer _ = sekat.pasangSlotCadangan(sebelumnya);

    try testing.expectError(error.Gagal, hasil(badRequest("{s}", .{"x" ** (maks_pesan * 2)})));
    try testing.expectEqual(@as(u16, 400), kotak.status);
    try testing.expect(kotak.pesan().len <= maks_pesan);
}

test "tabel pemetaan error" {
    try testing.expectEqual(@as(u16, 404), statusUntuk(error.NotFound));
    try testing.expectEqual(@as(u16, 400), statusUntuk(error.InvalidCharacter));
    try testing.expectEqual(@as(u16, 413), statusUntuk(error.IsiKebesaran));
    try testing.expectEqual(@as(u16, 500), statusUntuk(error.SesuatuYangTidakDikenal));
}
