//! Rangka jalan (tahap 1 di docs/rencana.md): terima koneksi lewat Sekat,
//! parse HTTP/1.1, balas "hello". Belum ada framework — tujuan satu-satunya
//! adalah memastikan Sekat terbentuk dengan benar.

const std = @import("std");
const sekat = @import("sekat.zig");
const http1 = @import("http1.zig");

pub const std_options_debug_io = sekat.debug_io;

pub fn main() !void {
    try sekat.layani(std.heap.smp_allocator, .{}, layaniKoneksi);
}

fn layaniKoneksi(in: *std.Io.Reader, out: *std.Io.Writer) void {
    while (true) {
        const p = http1.bacaPermintaan(in) catch |err| switch (err) {
            // Koneksi keep-alive yang ditutup klien di antara dua request:
            // jalan pulang yang normal, bukan galat.
            error.EndOfStream, error.ReadFailed => return,
            else => {
                http1.tulisRespons(out, 400, "Bad Request", "text/plain", "permintaan rusak\n", false) catch {};
                return;
            },
        };

        http1.buangIsi(in, &p) catch {
            http1.tulisRespons(out, 501, "Not Implemented", "text/plain", "chunked belum didukung\n", false) catch {};
            return;
        };

        http1.tulisRespons(out, 200, "OK", "text/plain", "hello\n", p.keep_alive) catch return;
        if (!p.keep_alive) return;
    }
}

test {
    _ = http1;
}
