//! zfast — framework HTTP untuk Zig yang mengutamakan kenyamanan menulis
//! kode. Kosakatanya ada di CONTEXT.md, keputusan desainnya di docs/adr/.

pub const App = @import("app.zig").App;
pub const Ctx = @import("ctx.zig").Ctx;
pub const Str = @import("str.zig").Str;
pub const Metode = @import("http1.zig").Metode;
pub const Opsi = @import("sekat.zig").Opsi;

test {
    _ = @import("str.zig");
    _ = @import("http1.zig");
    _ = @import("router.zig");
    _ = @import("ctx.zig");
    _ = @import("app.zig");
}
