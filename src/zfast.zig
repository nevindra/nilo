//! zfast — framework HTTP untuk Zig yang mengutamakan kenyamanan menulis
//! kode. Kosakatanya ada di CONTEXT.md, keputusan desainnya di docs/adr/.

pub const App = @import("app.zig").App;
pub const Ctx = @import("ctx.zig").Ctx;
pub const Str = @import("str.zig").Str;
pub const Metode = @import("http1.zig").Metode;
pub const Opsi = @import("sekat.zig").Opsi;

/// Fungsi gagal — `gagal.notFound("user {d} tidak ada", .{id})` dan
/// kawan-kawannya, bisa dipanggil dari mana saja (ADR 0005).
pub const gagal = @import("gagal.zig");

/// Jawaban dengan status selain 200: `Jawaban(User){ .status = 201, … }`.
pub const Jawaban = @import("bertipe.zig").Jawaban;

test {
    _ = @import("str.zig");
    _ = @import("http1.zig");
    _ = @import("router.zig");
    _ = @import("gagal.zig");
    _ = @import("layanan.zig");
    _ = @import("bertipe.zig");
    _ = @import("ctx.zig");
    _ = @import("app.zig");
}
