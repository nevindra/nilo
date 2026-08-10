//! Router: mencocokkan metode + jalur ke penangan, dengan path param
//! bergaya `/users/:id`.
//!
//! Algoritmanya pemindaian linear per rute, segmen demi segmen. Ini
//! sengaja: algoritma router tidak terlihat pengguna dan diputuskan
//! dengan angka nanti (docs/rencana.md, "Belum diputuskan").

const std = @import("std");
const http1 = @import("http1.zig");
const Ctx = @import("ctx.zig").Ctx;

pub const PenanganCtx = *const fn (*Ctx) anyerror!void;

pub const maks_param = 8;

pub const Param = struct {
    nama: []const u8,
    nilai: []const u8,
};

pub const Kecocokan = struct {
    penangan: PenanganCtx,
    param: [maks_param]Param = undefined,
    n_param: usize = 0,
};

const Rute = struct {
    metode: http1.Metode,
    pola: []const u8,
    penangan: PenanganCtx,
};

pub const Router = struct {
    gpa: std.mem.Allocator,
    rute: std.ArrayList(Rute) = .empty,

    pub fn init(gpa: std.mem.Allocator) Router {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Router) void {
        self.rute.deinit(self.gpa);
    }

    /// `pola` harus hidup selama Router hidup (biasanya literal).
    pub fn tambah(self: *Router, metode: http1.Metode, pola: []const u8, penangan: PenanganCtx) !void {
        std.debug.assert(pola.len > 0 and pola[0] == '/');
        std.debug.assert(std.mem.count(u8, pola, ":") <= maks_param);
        try self.rute.append(self.gpa, .{ .metode = metode, .pola = pola, .penangan = penangan });
    }

    pub fn cocok(self: *const Router, metode: http1.Metode, jalur: []const u8) ?Kecocokan {
        for (self.rute.items) |rute| {
            if (rute.metode != metode) continue;
            var hasil = Kecocokan{ .penangan = rute.penangan };
            if (cocokPola(rute.pola, jalur, &hasil)) return hasil;
        }
        return null;
    }

    fn cocokPola(pola: []const u8, jalur: []const u8, hasil: *Kecocokan) bool {
        var seg_pola = std.mem.splitScalar(u8, potongMiring(pola), '/');
        var seg_jalur = std.mem.splitScalar(u8, potongMiring(jalur), '/');

        while (true) {
            const p = seg_pola.next();
            const j = seg_jalur.next();
            if (p == null and j == null) return true;
            if (p == null or j == null) return false;

            if (p.?.len > 0 and p.?[0] == ':') {
                if (j.?.len == 0) return false;
                hasil.param[hasil.n_param] = .{ .nama = p.?[1..], .nilai = j.? };
                hasil.n_param += 1;
            } else if (!std.mem.eql(u8, p.?, j.?)) {
                return false;
            }
        }
    }

    /// "/a/b/" dan "/a/b" dianggap jalur yang sama.
    fn potongMiring(jalur: []const u8) []const u8 {
        var s = jalur;
        if (s.len > 0 and s[0] == '/') s = s[1..];
        if (s.len > 0 and s[s.len - 1] == '/') s = s[0 .. s.len - 1];
        return s;
    }
};

const testing = std.testing;

fn penanganUji(_: *Ctx) anyerror!void {}
fn penanganLain(_: *Ctx) anyerror!void {}

test "rute statis dan metode" {
    var r = Router.init(testing.allocator);
    defer r.deinit();
    try r.tambah(.GET, "/sehat", penanganUji);

    try testing.expect(r.cocok(.GET, "/sehat") != null);
    try testing.expect(r.cocok(.POST, "/sehat") == null);
    try testing.expect(r.cocok(.GET, "/lain") == null);
    try testing.expect(r.cocok(.GET, "/sehat/") != null);
}

test "path param tertangkap" {
    var r = Router.init(testing.allocator);
    defer r.deinit();
    try r.tambah(.GET, "/users/:id", penanganUji);
    try r.tambah(.GET, "/users/:id/posts/:post", penanganLain);

    const k = r.cocok(.GET, "/users/42").?;
    try testing.expectEqual(@as(usize, 1), k.n_param);
    try testing.expectEqualStrings("id", k.param[0].nama);
    try testing.expectEqualStrings("42", k.param[0].nilai);

    const k2 = r.cocok(.GET, "/users/7/posts/99").?;
    try testing.expectEqual(@as(usize, 2), k2.n_param);
    try testing.expectEqualStrings("99", k2.param[1].nilai);
    try testing.expect(k2.penangan == &penanganLain);

    try testing.expect(r.cocok(.GET, "/users") == null);
    try testing.expect(r.cocok(.GET, "/users/42/posts") == null);
    try testing.expect(r.cocok(.GET, "/users//posts/9") == null);
}

test "rute pertama yang cocok menang" {
    var r = Router.init(testing.allocator);
    defer r.deinit();
    try r.tambah(.GET, "/users/aku", penanganUji);
    try r.tambah(.GET, "/users/:id", penanganLain);

    try testing.expect(r.cocok(.GET, "/users/aku").?.penangan == &penanganUji);
    try testing.expect(r.cocok(.GET, "/users/42").?.penangan == &penanganLain);
}
