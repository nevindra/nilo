//! Parser HTTP/1.1 tahap rangka: baris permintaan, header, keep-alive,
//! dan pembuangan isi ber-Content-Length. Chunked menyusul di tahap
//! berikutnya (lingkup v1), untuk sekarang ditolak dengan jujur.
//!
//! Lapisan ini hanya melihat `std.Io.Reader`/`std.Io.Writer`, tidak tahu
//! Mesin apa yang ada di baliknya.

const std = @import("std");

pub const GalatParse = error{
    BarisPermintaanRusak,
    HeaderRusak,
    VersiTidakDidukung,
    MetodeKepanjangan,
    TargetKepanjangan,
};

pub const Permintaan = struct {
    metode_buf: [16]u8 = undefined,
    metode_len: u8 = 0,
    target_buf: [1024]u8 = undefined,
    target_len: u16 = 0,

    /// 0 untuk HTTP/1.0, 1 untuk HTTP/1.1.
    versi_minor: u1 = 1,
    keep_alive: bool = true,
    panjang_isi: u64 = 0,
    chunked: bool = false,

    pub fn metode(self: *const Permintaan) []const u8 {
        return self.metode_buf[0..self.metode_len];
    }

    pub fn target(self: *const Permintaan) []const u8 {
        return self.target_buf[0..self.target_len];
    }
};

/// Baca satu permintaan lengkap (baris permintaan + semua header) dari
/// reader. Isi (body) belum dibaca; panggil `buangIsi` setelahnya.
pub fn bacaPermintaan(in: *std.Io.Reader) !Permintaan {
    var p = Permintaan{};

    const baris_pertama = potongUjungBaris(try in.takeDelimiterInclusive('\n'));
    try parseBarisPermintaan(baris_pertama, &p);

    while (true) {
        const baris = potongUjungBaris(try in.takeDelimiterInclusive('\n'));
        if (baris.len == 0) break;
        try terapkanHeader(baris, &p);
    }

    return p;
}

/// Buang isi permintaan yang tidak dipakai, supaya koneksi keep-alive
/// bersih untuk permintaan berikutnya.
pub fn buangIsi(in: *std.Io.Reader, p: *const Permintaan) !void {
    if (p.chunked) return error.ChunkedBelumDidukung;
    if (p.panjang_isi > 0) try in.discardAll(p.panjang_isi);
}

pub fn parseBarisPermintaan(baris: []const u8, p: *Permintaan) GalatParse!void {
    var bagian = std.mem.splitScalar(u8, baris, ' ');
    const metode = bagian.next() orelse return error.BarisPermintaanRusak;
    const target = bagian.next() orelse return error.BarisPermintaanRusak;
    const versi = bagian.next() orelse return error.BarisPermintaanRusak;
    if (bagian.next() != null) return error.BarisPermintaanRusak;
    if (metode.len == 0 or target.len == 0) return error.BarisPermintaanRusak;

    if (metode.len > p.metode_buf.len) return error.MetodeKepanjangan;
    if (target.len > p.target_buf.len) return error.TargetKepanjangan;

    if (std.mem.eql(u8, versi, "HTTP/1.1")) {
        p.versi_minor = 1;
        p.keep_alive = true;
    } else if (std.mem.eql(u8, versi, "HTTP/1.0")) {
        p.versi_minor = 0;
        p.keep_alive = false;
    } else {
        return error.VersiTidakDidukung;
    }

    @memcpy(p.metode_buf[0..metode.len], metode);
    p.metode_len = @intCast(metode.len);
    @memcpy(p.target_buf[0..target.len], target);
    p.target_len = @intCast(target.len);
}

pub fn terapkanHeader(baris: []const u8, p: *Permintaan) GalatParse!void {
    const titik_dua = std.mem.indexOfScalar(u8, baris, ':') orelse return error.HeaderRusak;
    const nama = baris[0..titik_dua];
    const nilai = std.mem.trim(u8, baris[titik_dua + 1 ..], " \t");

    if (std.ascii.eqlIgnoreCase(nama, "content-length")) {
        p.panjang_isi = std.fmt.parseInt(u64, nilai, 10) catch return error.HeaderRusak;
    } else if (std.ascii.eqlIgnoreCase(nama, "connection")) {
        if (std.ascii.eqlIgnoreCase(nilai, "close")) {
            p.keep_alive = false;
        } else if (std.ascii.eqlIgnoreCase(nilai, "keep-alive")) {
            p.keep_alive = true;
        }
    } else if (std.ascii.eqlIgnoreCase(nama, "transfer-encoding")) {
        if (std.ascii.indexOfIgnoreCase(nilai, "chunked") != null) p.chunked = true;
    }
}

pub fn tulisRespons(
    out: *std.Io.Writer,
    status: u16,
    frasa: []const u8,
    tipe_konten: []const u8,
    isi: []const u8,
    keep_alive: bool,
) !void {
    try out.print(
        "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: {s}\r\n\r\n",
        .{ status, frasa, tipe_konten, isi.len, if (keep_alive) "keep-alive" else "close" },
    );
    try out.writeAll(isi);
    try out.flush();
}

fn potongUjungBaris(baris: []const u8) []const u8 {
    var b = baris;
    if (b.len > 0 and b[b.len - 1] == '\n') b = b[0 .. b.len - 1];
    if (b.len > 0 and b[b.len - 1] == '\r') b = b[0 .. b.len - 1];
    return b;
}

const testing = std.testing;

test "GET sederhana HTTP/1.1 default keep-alive" {
    var in = std.Io.Reader.fixed("GET /halo HTTP/1.1\r\nHost: contoh\r\n\r\n");
    const p = try bacaPermintaan(&in);
    try testing.expectEqualStrings("GET", p.metode());
    try testing.expectEqualStrings("/halo", p.target());
    try testing.expect(p.keep_alive);
    try testing.expectEqual(@as(u64, 0), p.panjang_isi);
}

test "HTTP/1.0 default tutup, keep-alive kalau diminta" {
    var in = std.Io.Reader.fixed("GET / HTTP/1.0\r\n\r\n");
    const p = try bacaPermintaan(&in);
    try testing.expect(!p.keep_alive);

    var in2 = std.Io.Reader.fixed("GET / HTTP/1.0\r\nConnection: keep-alive\r\n\r\n");
    const p2 = try bacaPermintaan(&in2);
    try testing.expect(p2.keep_alive);
}

test "Connection: close mematikan keep-alive" {
    var in = std.Io.Reader.fixed("GET / HTTP/1.1\r\nConnection: close\r\n\r\n");
    const p = try bacaPermintaan(&in);
    try testing.expect(!p.keep_alive);
}

test "Content-Length terbaca dan isi terbuang" {
    var in = std.Io.Reader.fixed("POST /kirim HTTP/1.1\r\nContent-Length: 5\r\n\r\nhalo!GET");
    const p = try bacaPermintaan(&in);
    try testing.expectEqualStrings("POST", p.metode());
    try testing.expectEqual(@as(u64, 5), p.panjang_isi);
    try buangIsi(&in, &p);
    try testing.expectEqualStrings("GET", try in.take(3));
}

test "transfer-encoding chunked terdeteksi dan ditolak buangIsi" {
    var in = std.Io.Reader.fixed("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n");
    const p = try bacaPermintaan(&in);
    try testing.expect(p.chunked);
    try testing.expectError(error.ChunkedBelumDidukung, buangIsi(&in, &p));
}

test "baris permintaan rusak" {
    var p = Permintaan{};
    try testing.expectError(error.BarisPermintaanRusak, parseBarisPermintaan("GET /", &p));
    try testing.expectError(error.BarisPermintaanRusak, parseBarisPermintaan("GET / HTTP/1.1 x", &p));
    try testing.expectError(error.VersiTidakDidukung, parseBarisPermintaan("GET / HTTP/2.0", &p));
}

test "header tanpa titik dua" {
    var p = Permintaan{};
    try testing.expectError(error.HeaderRusak, terapkanHeader("Host tanpa-titik-dua", &p));
}

test "tulisRespons membentuk respons utuh" {
    var buf: [256]u8 = undefined;
    var out = std.Io.Writer.fixed(&buf);
    try tulisRespons(&out, 200, "OK", "text/plain", "hello\n", true);
    try testing.expectEqualStrings(
        "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 6\r\nConnection: keep-alive\r\n\r\nhello\n",
        out.buffered(),
    );
}
