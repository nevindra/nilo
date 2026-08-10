//! Rangka jalan (tahap 1 di docs/rencana.md): terima koneksi lewat Sekat,
//! parse HTTP/1.1, balas "hello". Belum ada framework — tujuan satu-satunya
//! adalah memastikan Sekat terbentuk dengan benar.

const std = @import("std");
const sekat = @import("sekat.zig");
const http1 = @import("http1.zig");

pub const std_options_debug_io = sekat.debug_io;

// Respons yang isinya tetap dirakit sekali saat kompilasi; jalur panasnya
// tinggal satu writeAll + satu flush, tanpa formatting.
const HELLO_LANJUT = http1.responsStatis(200, "OK", "text/plain", "hello\n", true);
const HELLO_TUTUP = http1.responsStatis(200, "OK", "text/plain", "hello\n", false);
const RUSAK = http1.responsStatis(400, "Bad Request", "text/plain", "permintaan rusak\n", false);
const KEPANJANGAN = http1.responsStatis(431, "Request Header Fields Too Large", "text/plain", "kepala kepanjangan\n", false);
const CHUNKED = http1.responsStatis(501, "Not Implemented", "text/plain", "chunked belum didukung\n", false);

pub fn main() !void {
    try sekat.layani(std.heap.smp_allocator, .{}, layaniKoneksi);
}

fn layaniKoneksi(in: *std.Io.Reader, out: *std.Io.Writer) void {
    while (true) {
        const p = http1.bacaPermintaan(in) catch |err| {
            switch (err) {
                // Koneksi keep-alive yang ditutup klien di antara dua
                // request: jalan pulang yang normal, bukan galat.
                error.EndOfStream, error.ReadFailed => {},
                error.KepalaKepanjangan => balasTerakhir(out, KEPANJANGAN),
                else => balasTerakhir(out, RUSAK),
            }
            return;
        };

        http1.buangIsi(in, &p) catch return balasTerakhir(out, CHUNKED);

        if (p.keep_alive) {
            out.writeAll(HELLO_LANJUT) catch return;
            out.flush() catch return;
        } else {
            return balasTerakhir(out, HELLO_TUTUP);
        }
    }
}

fn balasTerakhir(out: *std.Io.Writer, respons: []const u8) void {
    out.writeAll(respons) catch return;
    out.flush() catch return;
}

test {
    _ = http1;
}
