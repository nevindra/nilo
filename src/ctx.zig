//! Ctx — satu request yang sedang berjalan, beserta seluruh kendali
//! atasnya. Ini API zfast yang sesungguhnya (ADR 0003): lapisan bertipe
//! di atasnya nanti berubah menjadi pemanggilan ke sini saat kompilasi.
//!
//! Semua teks yang keluar dari Ctx adalah `Str`: hidup selama request,
//! disalin sadar lewat `.keep()` kalau perlu lebih lama (ADR 0004).
//! Field berawalan `_` milik internal zfast — Arena request di baliknya
//! tidak pernah disentuh pengguna secara langsung.

const std = @import("std");
const http1 = @import("http1.zig");
const router = @import("router.zig");
const layanan_mod = @import("layanan.zig");
const str_mod = @import("str.zig");
const Str = str_mod.Str;

/// Plafon isi request yang dibaca ke Arena. Batas yang bisa diatur per
/// App menyusul; untuk sekarang satu angka yang masuk akal.
pub const maks_isi = 1024 * 1024;

pub const Ctx = struct {
    metode: http1.Metode,

    _arena: std.mem.Allocator,
    _umur: *const str_mod.Umur,
    _in: *std.Io.Reader,
    _out: *std.Io.Writer,
    _permintaan: *const http1.Permintaan,
    _jalur: []const u8,
    _query: []const u8,
    _header: []const http1.IterasiHeader.Pasangan,
    _param: []const router.Param,
    _layanan: *const layanan_mod.Daftar,
    _isi: ?[]const u8 = null,
    _terkirim: bool = false,

    /// Layanan bertipe `P` (sebuah tipe penunjuk), untuk handler yang
    /// memegang `*Ctx` dan karena itu tidak lewat pencocokan argumen.
    /// Null kalau belum didaftarkan — di lapisan bertipe, kasus ini sudah
    /// tersaring saat `dengarkan()`.
    pub fn layanan(self: *const Ctx, comptime P: type) ?P {
        return self._layanan.ambil(P);
    }

    // ---- sisi permintaan ----

    pub fn jalur(self: *const Ctx) Str {
        return Str.dariRequest(self._jalur, self._umur);
    }

    /// Path param dari pola rute: `/users/:id` → `param("id")`.
    pub fn param(self: *const Ctx, nama: []const u8) ?Str {
        for (self._param) |p| {
            if (std.mem.eql(u8, p.nama, nama)) return Str.dariRequest(p.nilai, self._umur);
        }
        return null;
    }

    /// Query param: `/cari?kata=zig` → `query("kata")`.
    /// Catatan tahap 2: belum ada percent-decoding.
    pub fn query(self: *const Ctx, nama: []const u8) ?Str {
        var pasangan = std.mem.splitScalar(u8, self._query, '&');
        while (pasangan.next()) |p| {
            const sama_dengan = std.mem.indexOfScalar(u8, p, '=') orelse p.len;
            if (std.mem.eql(u8, p[0..sama_dengan], nama)) {
                const nilai = if (sama_dengan < p.len) p[sama_dengan + 1 ..] else "";
                return Str.dariRequest(nilai, self._umur);
            }
        }
        return null;
    }

    /// Header permintaan, nama tidak peka kapital.
    pub fn header(self: *const Ctx, nama: []const u8) ?Str {
        for (self._header) |h| {
            if (std.ascii.eqlIgnoreCase(h.nama, nama)) return Str.dariRequest(h.nilai, self._umur);
        }
        return null;
    }

    /// Seluruh isi (body) permintaan, dibaca sekali ke Arena request.
    pub fn isi(self: *Ctx) !Str {
        if (self._isi == null) {
            if (self._permintaan.chunked) return error.ChunkedBelumDidukung;
            if (self._permintaan.panjang_isi > maks_isi) return error.IsiKebesaran;
            const b = try self._arena.alloc(u8, @intCast(self._permintaan.panjang_isi));
            try self._in.readSliceAll(b);
            self._isi = b;
        }
        return Str.dariRequest(self._isi.?, self._umur);
    }

    /// Parse isi permintaan sebagai JSON menjadi `T`. Hasilnya hidup di
    /// Arena request — `keep` per field kalau perlu lebih lama.
    ///
    /// Field bertipe `Str` ikut distempel umur request, jadi memakainya
    /// setelah request selesai tertangkap jebakan debug seperti Str yang
    /// lain (ADR 0004).
    pub fn json(self: *Ctx, comptime T: type) !T {
        const b = (try self.isi()).lihat();
        var nilai = try std.json.parseFromSliceLeaky(T, self._arena, b, .{});
        str_mod.stempel(&nilai, self._umur);
        return nilai;
    }

    // ---- sisi jawaban ----

    pub fn balas(self: *Ctx, status: u16, tipe_konten: []const u8, isi_balasan: []const u8) !void {
        std.debug.assert(!self._terkirim); // satu request satu jawaban
        self._terkirim = true;
        // Handler tidak perlu tahu ini HEAD: ia merakit jawaban seperti
        // biasa, dan yang tidak boleh ikut terkirim disaring di sini.
        if (self.metode == .HEAD) return http1.tulisResponsTanpaIsi(
            self._out,
            status,
            http1.frasaStatus(status),
            tipe_konten,
            isi_balasan.len,
            self._permintaan.keep_alive,
        );
        try http1.tulisRespons(
            self._out,
            status,
            http1.frasaStatus(status),
            tipe_konten,
            isi_balasan,
            self._permintaan.keep_alive,
        );
    }

    pub fn balasTeks(self: *Ctx, status: u16, teks: []const u8) !void {
        try self.balas(status, "text/plain", teks);
    }

    /// Serialisasi `nilai` ke JSON (lewat Arena request) lalu kirim.
    pub fn balasJson(self: *Ctx, status: u16, nilai: anytype) !void {
        const b = try std.json.Stringify.valueAlloc(self._arena, nilai, .{});
        try self.balas(status, "application/json", b);
    }
};
