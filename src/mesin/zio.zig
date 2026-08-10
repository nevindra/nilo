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

/// Fungsi yang mengurus satu koneksi sampai selesai. Reader/Writer sudah
/// ber-buffer; Penangan tidak perlu tahu socket di baliknya.
pub const Penangan = fn (in: *std.Io.Reader, out: *std.Io.Writer) void;

pub fn layani(gpa: std.mem.Allocator, opsi: Opsi, comptime penangan: Penangan) !void {
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();

    const addr = try zio.net.IpAddress.parseIp4(opsi.alamat, opsi.port);
    const server = try addr.listen(.{});
    defer server.close();

    std.log.info("zfast mendengarkan di {f}", .{server.socket.address});

    const Koneksi = struct {
        fn urus(stream: zio.net.Stream) void {
            defer stream.close();

            var buf_baca: [16 * 1024]u8 = undefined;
            var buf_tulis: [16 * 1024]u8 = undefined;
            var pembaca = stream.reader(&buf_baca);
            var penulis = stream.writer(&buf_tulis);

            penangan(&pembaca.interface, &penulis.interface);
        }
    };

    var group: zio.Group = .init;
    defer group.cancel();

    while (true) {
        const stream = try server.accept(.{});
        errdefer stream.close();
        try group.spawn(Koneksi.urus, .{stream});
    }
}
