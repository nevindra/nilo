//! Mesin berbasis zio (https://github.com/lalinsky/zio).
//!
//! Satu-satunya file di zfast yang boleh menyebut zio. Lihat ADR 0002.

const std = @import("std");
const zio = @import("zio");

pub const debug_io = zio.debug_io;

pub const Opsi = struct {
    alamat: []const u8 = "127.0.0.1",
    port: u16 = 8787,
};

// ---- slot per-request (lihat ADR 0007) ----
//
// zio menjalankan tiap koneksi di fiber-nya sendiri, dan banyak fiber
// berbagi satu utas OS. Jadi threadlocal salah: fiber A bisa tertidur di
// tengah handler, fiber B jalan di utas yang sama, lalu A bangun dan
// menulis ke slot milik B. `zio.TaskLocal` mengikat nilai ke fiber-nya,
// ikut berpindah kalau fiber-nya pindah utas — persis yang dibutuhkan.

var slot_fiber: zio.TaskLocal(*anyopaque) = .{};

/// Tempat penyimpanan satu ikatan slot. Milik pemanggil: taruh di stack
/// fiber, jangan dipindah selama terikat.
pub const Ikatan = zio.TaskLocal(*anyopaque).Node;

pub const ikatan_kosong: Ikatan = .unset;

/// Ikat `p` ke fiber yang sedang berjalan. Panik kalau dipanggil di luar
/// fiber — hanya Mesin yang boleh memanggilnya, dan Mesin selalu tahu.
pub fn ikatSlot(n: *Ikatan, p: *anyopaque) void {
    slot_fiber.set(n, p);
}

pub fn lepasSlot(n: *Ikatan) void {
    slot_fiber.clear(n);
}

/// Slot fiber yang sedang berjalan, atau null kalau tidak ada fiber
/// (misalnya unit test yang memanggil App langsung).
pub fn slot() ?*anyopaque {
    return slot_fiber.get();
}

/// Jalankan `penangan(state, in, out)` untuk tiap koneksi yang diterima,
/// masing-masing di fiber-nya sendiri, sampai koneksinya selesai.
/// Reader/Writer sudah ber-buffer; penangan tidak perlu tahu socket di
/// baliknya. `penangan` harus `fn (@TypeOf(state), *std.Io.Reader,
/// *std.Io.Writer) void`.
pub fn layani(gpa: std.mem.Allocator, opsi: Opsi, state: anytype, comptime penangan: anytype) !void {
    const State = @TypeOf(state);
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();

    const addr = try zio.net.IpAddress.parseIp4(opsi.alamat, opsi.port);
    const server = try addr.listen(.{});
    defer server.close();

    std.log.info("zfast mendengarkan di {f}", .{server.socket.address});

    const Koneksi = struct {
        fn urus(st: State, stream: zio.net.Stream) void {
            defer stream.close();

            // Satu respons = satu flush = satu segmen; Nagle cuma nambah
            // latensi tanpa ada yang dihemat, jadi dimatikan.
            stream.socket.setNoDelay(true) catch {};

            // Buffer baca sekaligus plafon ukuran kepala permintaan (431
            // kalau lewat). Buffer tulis cukup untuk kepala respons + body
            // seukuran metrik utama (~1KB JSON).
            var buf_baca: [8 * 1024]u8 = undefined;
            var buf_tulis: [4 * 1024]u8 = undefined;
            var pembaca = stream.reader(&buf_baca);
            var penulis = stream.writer(&buf_tulis);

            penangan(st, &pembaca.interface, &penulis.interface);
        }
    };

    var group: zio.Group = .init;
    defer group.cancel();

    while (true) {
        const stream = try server.accept(.{});
        errdefer stream.close();
        try group.spawn(Koneksi.urus, .{ state, stream });
    }
}
