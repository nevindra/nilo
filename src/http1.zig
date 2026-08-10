//! Parser HTTP/1.1 tahap rangka: baris permintaan, header, keep-alive,
//! dan pembuangan isi ber-Content-Length. Chunked menyusul di tahap
//! berikutnya (lingkup v1), untuk sekarang ditolak dengan jujur.
//!
//! Jalur panasnya zero-copy: seluruh kepala (baris permintaan + header)
//! ditunggu sampai utuh di buffer reader, dicari ujungnya sekali, lalu
//! di-parse di tempat. `Permintaan` hanya menyimpan slice ke buffer itu —
//! tidak ada satu byte pun yang disalin dan tidak ada alokasi.
//!
//! Lapisan ini hanya melihat `std.Io.Reader`/`std.Io.Writer`, tidak tahu
//! Mesin apa yang ada di baliknya.

const std = @import("std");

pub const GalatParse = error{
    BarisPermintaanRusak,
    HeaderRusak,
    VersiTidakDidukung,
};

pub const Permintaan = struct {
    /// Slice ke buffer reader. Berlaku sampai pembacaan berikutnya dari
    /// koneksi yang sama (termasuk `buangIsi`) — setelah itu isinya bisa
    /// tertimpa. Umur yang lebih panjang datang di tahap 2 lewat Arena
    /// request dan `Str` (ADR 0004).
    metode: []const u8 = "",
    target: []const u8 = "",

    /// 0 untuk HTTP/1.0, 1 untuk HTTP/1.1.
    versi_minor: u1 = 1,
    keep_alive: bool = true,
    panjang_isi: u64 = 0,
    chunked: bool = false,
};

/// Baca satu kepala permintaan lengkap dari reader dan parse di tempat.
/// Isi (body) belum dibaca; panggil `buangIsi` setelahnya.
///
/// `error.KepalaKepanjangan` berarti kepala tidak muat di buffer reader —
/// jawab dengan 431. `error.EndOfStream` sebelum byte pertama adalah
/// koneksi keep-alive yang ditutup klien: jalan pulang normal.
pub fn bacaPermintaan(in: *std.Io.Reader) !Permintaan {
    const kepala = try bacaKepala(in);
    var p = Permintaan{};
    try parseKepala(kepala, &p);
    in.toss(kepala.len);
    return p;
}

/// Buang isi permintaan yang tidak dipakai, supaya koneksi keep-alive
/// bersih untuk permintaan berikutnya.
pub fn buangIsi(in: *std.Io.Reader, p: *const Permintaan) !void {
    if (p.chunked) return error.ChunkedBelumDidukung;
    if (p.panjang_isi > 0) try in.discardAll64(p.panjang_isi);
}

/// Tunggu sampai satu kepala utuh (sampai baris kosong) ada di buffer,
/// lalu kembalikan slice-nya tanpa menyalin dan tanpa memajukan reader.
fn bacaKepala(in: *std.Io.Reader) ![]const u8 {
    while (true) {
        const buf = in.buffered();
        if (cariAkhirKepala(buf)) |akhir| return buf[0..akhir];
        if (buf.len >= in.buffer.len) return error.KepalaKepanjangan;
        try in.fillMore();
    }
}

/// Indeks tepat setelah baris kosong pengakhir kepala, kalau sudah utuh.
/// Menerima CRLF maupun LF telanjang.
fn cariAkhirKepala(buf: []const u8) ?usize {
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, buf, i, '\n')) |nl| {
        if (nl + 1 < buf.len and buf[nl + 1] == '\n') return nl + 2;
        if (nl + 2 < buf.len and buf[nl + 1] == '\r' and buf[nl + 2] == '\n') return nl + 3;
        i = nl + 1;
    }
    return null;
}

pub fn parseKepala(kepala: []const u8, p: *Permintaan) GalatParse!void {
    var baris_iter = std.mem.splitScalar(u8, kepala, '\n');

    const baris_pertama = potongCR(baris_iter.next() orelse return error.BarisPermintaanRusak);
    try parseBarisPermintaan(baris_pertama, p);

    while (baris_iter.next()) |baris_mentah| {
        const baris = potongCR(baris_mentah);
        if (baris.len == 0) return;
        try terapkanHeader(baris, p);
    }
}

pub fn parseBarisPermintaan(baris: []const u8, p: *Permintaan) GalatParse!void {
    const spasi1 = std.mem.indexOfScalar(u8, baris, ' ') orelse return error.BarisPermintaanRusak;
    const spasi2 = std.mem.indexOfScalarPos(u8, baris, spasi1 + 1, ' ') orelse return error.BarisPermintaanRusak;

    const metode = baris[0..spasi1];
    const target = baris[spasi1 + 1 .. spasi2];
    const versi = baris[spasi2 + 1 ..];
    if (metode.len == 0 or target.len == 0) return error.BarisPermintaanRusak;

    if (std.mem.eql(u8, versi, "HTTP/1.1")) {
        p.versi_minor = 1;
        p.keep_alive = true;
    } else if (std.mem.eql(u8, versi, "HTTP/1.0")) {
        p.versi_minor = 0;
        p.keep_alive = false;
    } else {
        return error.VersiTidakDidukung;
    }

    p.metode = metode;
    p.target = target;
}

pub fn terapkanHeader(baris: []const u8, p: *Permintaan) GalatParse!void {
    const titik_dua = std.mem.indexOfScalar(u8, baris, ':') orelse return error.HeaderRusak;
    const nama = baris[0..titik_dua];
    const nilai = std.mem.trim(u8, baris[titik_dua + 1 ..], " \t");

    // Urut dari yang paling sering muncul; panjang nama dicek dulu supaya
    // perbandingan case-insensitive hampir selalu cuma satu kali.
    switch (nama.len) {
        "connection".len => if (std.ascii.eqlIgnoreCase(nama, "connection")) {
            if (std.ascii.eqlIgnoreCase(nilai, "close")) {
                p.keep_alive = false;
            } else if (std.ascii.eqlIgnoreCase(nilai, "keep-alive")) {
                p.keep_alive = true;
            }
        },
        "content-length".len => if (std.ascii.eqlIgnoreCase(nama, "content-length")) {
            p.panjang_isi = std.fmt.parseInt(u64, nilai, 10) catch return error.HeaderRusak;
        },
        "transfer-encoding".len => if (std.ascii.eqlIgnoreCase(nama, "transfer-encoding")) {
            if (std.ascii.indexOfIgnoreCase(nilai, "chunked") != null) p.chunked = true;
        },
        else => {},
    }
}

/// Rakit respons lengkap sebagai konstanta saat kompilasi — untuk respons
/// yang isinya tetap, menulisnya jadi satu `writeAll` tanpa formatting.
pub fn responsStatis(
    comptime status: u16,
    comptime frasa: []const u8,
    comptime tipe_konten: []const u8,
    comptime isi: []const u8,
    comptime keep_alive: bool,
) []const u8 {
    return std.fmt.comptimePrint(
        "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: {s}\r\n\r\n{s}",
        .{ status, frasa, tipe_konten, isi.len, if (keep_alive) "keep-alive" else "close", isi },
    );
}

/// Jalur dingin untuk respons yang isinya baru diketahui saat berjalan.
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

fn potongCR(baris: []const u8) []const u8 {
    return if (baris.len > 0 and baris[baris.len - 1] == '\r') baris[0 .. baris.len - 1] else baris;
}

const testing = std.testing;

test "GET sederhana HTTP/1.1 default keep-alive" {
    var in = std.Io.Reader.fixed("GET /halo HTTP/1.1\r\nHost: contoh\r\n\r\n");
    const p = try bacaPermintaan(&in);
    try testing.expectEqualStrings("GET", p.metode);
    try testing.expectEqualStrings("/halo", p.target);
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
    try testing.expectEqualStrings("POST", p.metode);
    try testing.expectEqual(@as(u64, 5), p.panjang_isi);
    try buangIsi(&in, &p);
    try testing.expectEqualStrings("GET", try in.take(3));
}

test "dua permintaan beruntun di satu koneksi" {
    var in = std.Io.Reader.fixed("GET /satu HTTP/1.1\r\n\r\nGET /dua HTTP/1.1\r\nConnection: close\r\n\r\n");
    const p1 = try bacaPermintaan(&in);
    try testing.expectEqualStrings("/satu", p1.target);
    const p2 = try bacaPermintaan(&in);
    try testing.expectEqualStrings("/dua", p2.target);
    try testing.expect(!p2.keep_alive);
}

test "baris LF telanjang tetap diterima" {
    var in = std.Io.Reader.fixed("GET / HTTP/1.1\nHost: contoh\n\n");
    const p = try bacaPermintaan(&in);
    try testing.expectEqualStrings("GET", p.metode);
}

test "kepala tanpa ujung tidak menghasilkan parse separuh" {
    // Pada Reader.fixed, buffer persis seukuran data, jadi kepala yang tak
    // kunjung berujung terdeteksi sebagai buffer penuh. Di koneksi
    // sungguhan dengan buffer lapang, kasus yang sama berujung
    // error.EndOfStream saat klien menutup koneksi.
    var in = std.Io.Reader.fixed("GET / HTTP/1.1\r\nHost: contoh\r\n");
    try testing.expectError(error.KepalaKepanjangan, bacaPermintaan(&in));
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
    try testing.expectError(error.VersiTidakDidukung, parseBarisPermintaan("GET / HTTP/2.0", &p));
    try testing.expectError(error.VersiTidakDidukung, parseBarisPermintaan("GET / HTTP/1.1 x", &p));
}

test "header tanpa titik dua" {
    var p = Permintaan{};
    try testing.expectError(error.HeaderRusak, terapkanHeader("Host tanpa-titik-dua", &p));
}

test "responsStatis dan tulisRespons menghasilkan byte yang sama" {
    const statis = comptime responsStatis(200, "OK", "text/plain", "hello\n", true);
    var buf: [256]u8 = undefined;
    var out = std.Io.Writer.fixed(&buf);
    try tulisRespons(&out, 200, "OK", "text/plain", "hello\n", true);
    try testing.expectEqualStrings(statis, out.buffered());
}
