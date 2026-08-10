//! App — satu aplikasi HTTP yang berdiri sendiri: kumpulan Rute (dan
//! nanti Middleware serta Layanan). Merangkai Sekat, parser HTTP/1.1,
//! Router, Arena request, dan Ctx menjadi satu.
//!
//! `urusSatuRequest` sengaja terpisah dari Mesin: ia hanya butuh
//! `std.Io.Reader`/`Writer`, jadi seluruh perilaku HTTP App bisa diuji
//! dengan buffer di memori, tanpa menyalakan server.

const std = @import("std");
const sekat = @import("sekat.zig");
const http1 = @import("http1.zig");
const router_mod = @import("router.zig");
const ctx_mod = @import("ctx.zig");
const str_mod = @import("str.zig");

const Ctx = ctx_mod.Ctx;

const RESPONS_400 = http1.responsStatis(400, "Bad Request", "text/plain", "permintaan rusak\n", false);
const RESPONS_431 = http1.responsStatis(431, "Request Header Fields Too Large", "text/plain", "kepala kepanjangan\n", false);

pub const App = struct {
    gpa: std.mem.Allocator,
    router: router_mod.Router,

    pub fn init(gpa: std.mem.Allocator) App {
        return .{ .gpa = gpa, .router = router_mod.Router.init(gpa) };
    }

    pub fn deinit(self: *App) void {
        self.router.deinit();
    }

    pub fn get(self: *App, pola: []const u8, penangan: router_mod.PenanganCtx) !void {
        try self.router.tambah(.GET, pola, penangan);
    }

    pub fn post(self: *App, pola: []const u8, penangan: router_mod.PenanganCtx) !void {
        try self.router.tambah(.POST, pola, penangan);
    }

    pub fn put(self: *App, pola: []const u8, penangan: router_mod.PenanganCtx) !void {
        try self.router.tambah(.PUT, pola, penangan);
    }

    pub fn delete(self: *App, pola: []const u8, penangan: router_mod.PenanganCtx) !void {
        try self.router.tambah(.DELETE, pola, penangan);
    }

    pub fn patch(self: *App, pola: []const u8, penangan: router_mod.PenanganCtx) !void {
        try self.router.tambah(.PATCH, pola, penangan);
    }

    /// Mendengarkan dan melayani sampai proses dihentikan.
    pub fn dengarkan(self: *App, opsi: sekat.Opsi) !void {
        try sekat.layani(self.gpa, opsi, self, urusKoneksi);
    }

    fn urusKoneksi(self: *App, in: *std.Io.Reader, out: *std.Io.Writer) void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        var umur = str_mod.Umur{};

        while (true) {
            const lanjut = self.urusSatuRequest(arena.allocator(), &umur, in, out);
            // Request selesai: semua Str-nya basi, lalu kantongnya
            // dikosongkan sekaligus tanpa melepas kapasitasnya.
            umur.selesai();
            _ = arena.reset(.retain_capacity);
            if (!lanjut) return;
        }
    }

    /// Urus tepat satu request dari `in`, tulis jawabannya ke `out`.
    /// Mengembalikan true kalau koneksi boleh dipakai untuk request
    /// berikutnya.
    pub fn urusSatuRequest(
        self: *App,
        arena: std.mem.Allocator,
        umur: *str_mod.Umur,
        in: *std.Io.Reader,
        out: *std.Io.Writer,
    ) bool {
        // Kepala disalin ke Arena request supaya semua Str dari request
        // ini tetap sah sekalipun buffer koneksi terisi ulang (misalnya
        // saat membaca isi). Satu memcpy kecil, dibayar sekali.
        const kepala_mentah = http1.bacaKepala(in) catch |err| {
            switch (err) {
                error.EndOfStream, error.ReadFailed => {},
                error.KepalaKepanjangan => balasTerakhir(out, RESPONS_431),
            }
            return false;
        };
        const kepala = arena.dupe(u8, kepala_mentah) catch return false;
        in.toss(kepala_mentah.len);

        var p = http1.Permintaan{};
        http1.parseKepala(kepala, &p) catch {
            balasTerakhir(out, RESPONS_400);
            return false;
        };

        var daftar_header: std.ArrayList(http1.IterasiHeader.Pasangan) = .empty;
        var iter = http1.IterasiHeader.dari(kepala);
        while (iter.next()) |pasangan| daftar_header.append(arena, pasangan) catch return false;

        const tanya = std.mem.indexOfScalar(u8, p.target, '?');
        const jalur = if (tanya) |i| p.target[0..i] else p.target;

        var c = Ctx{
            .metode = http1.metodeDari(p.metode),
            ._arena = arena,
            ._umur = umur,
            ._in = in,
            ._out = out,
            ._permintaan = &p,
            ._jalur = jalur,
            ._query = if (tanya) |i| p.target[i + 1 ..] else "",
            ._header = daftar_header.items,
            ._param = &.{},
        };

        const kecocokan = self.router.cocok(c.metode, jalur) orelse {
            http1.buangIsi(in, &p) catch return false;
            http1.tulisRespons(out, 404, http1.frasaStatus(404), "text/plain", "tidak ditemukan\n", p.keep_alive) catch return false;
            return p.keep_alive;
        };
        c._param = kecocokan.param[0..kecocokan.n_param];

        kecocokan.penangan(&c) catch |err| {
            // Jawaban sudah separuh jalan tidak bisa ditarik; kalau belum,
            // jadi 500. Dua-duanya menutup koneksi supaya tidak ada
            // request berikutnya membaca sisa keadaan yang tidak jelas.
            std.log.warn("penangan {s} {s} gagal: {s}", .{ @tagName(c.metode), jalur, @errorName(err) });
            if (!c._terkirim) {
                http1.tulisRespons(out, 500, http1.frasaStatus(500), "text/plain", "galat di server\n", false) catch {};
            }
            return false;
        };

        // Isi yang tidak dibaca penangan dibuang supaya request
        // berikutnya di koneksi ini mulai dari byte yang benar.
        if (c._isi == null) http1.buangIsi(in, &p) catch return false;

        if (!c._terkirim) {
            http1.tulisRespons(out, 200, http1.frasaStatus(200), "text/plain", "", p.keep_alive) catch return false;
        }
        return p.keep_alive;
    }
};

fn balasTerakhir(out: *std.Io.Writer, respons: []const u8) void {
    out.writeAll(respons) catch return;
    out.flush() catch return;
}

// ---- tes: seluruh perilaku HTTP tanpa menyalakan server ----

const testing = std.testing;

const Uji = struct {
    arena: std.heap.ArenaAllocator,
    umur: str_mod.Umur = .{},
    buf: [4096]u8 = undefined,

    fn init() Uji {
        return .{ .arena = std.heap.ArenaAllocator.init(testing.allocator) };
    }

    fn deinit(self: *Uji) void {
        self.arena.deinit();
    }

    fn kirim(self: *Uji, app: *App, permintaan: []const u8) struct { balasan: []const u8, lanjut: bool } {
        var in = std.Io.Reader.fixed(permintaan);
        var out = std.Io.Writer.fixed(&self.buf);
        const lanjut = app.urusSatuRequest(self.arena.allocator(), &self.umur, &in, &out);
        return .{ .balasan = out.buffered(), .lanjut = lanjut };
    }
};

fn ujiGetUser(c: *Ctx) anyerror!void {
    const id = try c.param("id").?.angka(u32);
    try c.balasJson(200, .{ .id = id, .nama = "tester" });
}

fn ujiEchoJson(c: *Ctx) anyerror!void {
    const Masuk = struct { pesan: []const u8 };
    const masuk = try c.json(Masuk);
    try c.balasJson(201, .{ .gema = masuk.pesan });
}

fn ujiMeledak(_: *Ctx) anyerror!void {
    return error.SengajaMeledak;
}

fn ujiDiam(_: *Ctx) anyerror!void {}

test "GET dengan path param membalas JSON dan koneksi lanjut" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/users/:id", ujiGetUser);

    var uji = Uji.init();
    defer uji.deinit();
    const hasil = uji.kirim(&app, "GET /users/42 HTTP/1.1\r\nHost: x\r\n\r\n");

    try testing.expect(hasil.lanjut);
    try testing.expect(std.mem.startsWith(u8, hasil.balasan, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.indexOf(u8, hasil.balasan, "Content-Type: application/json") != null);
    try testing.expect(std.mem.indexOf(u8, hasil.balasan, "{\"id\":42,\"nama\":\"tester\"}") != null);
}

test "POST JSON masuk, JSON keluar" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/gema", ujiEchoJson);

    var uji = Uji.init();
    defer uji.deinit();
    const isi = "{\"pesan\":\"halo\"}";
    var permintaan_buf: [256]u8 = undefined;
    const permintaan = std.fmt.bufPrint(&permintaan_buf, "POST /gema HTTP/1.1\r\nContent-Length: {d}\r\n\r\n{s}", .{ isi.len, isi }) catch unreachable;
    const hasil = uji.kirim(&app, permintaan);

    try testing.expect(std.mem.startsWith(u8, hasil.balasan, "HTTP/1.1 201 Created\r\n"));
    try testing.expect(std.mem.indexOf(u8, hasil.balasan, "{\"gema\":\"halo\"}") != null);
}

test "rute tak dikenal membalas 404 dan isi tetap terbuang" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/ada", ujiDiam);

    var uji = Uji.init();
    defer uji.deinit();
    const hasil = uji.kirim(&app, "POST /tidak-ada HTTP/1.1\r\nContent-Length: 4\r\n\r\nxxxxGET /ada HTTP/1.1\r\n\r\n");
    try testing.expect(hasil.lanjut);
    try testing.expect(std.mem.startsWith(u8, hasil.balasan, "HTTP/1.1 404 Not Found\r\n"));
}

test "penangan yang gagal jadi 500 dan koneksi ditutup" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/meledak", ujiMeledak);

    var uji = Uji.init();
    defer uji.deinit();
    const hasil = uji.kirim(&app, "GET /meledak HTTP/1.1\r\n\r\n");
    try testing.expect(!hasil.lanjut);
    try testing.expect(std.mem.startsWith(u8, hasil.balasan, "HTTP/1.1 500 Internal Server Error\r\n"));
}

test "penangan diam membalas 200 kosong" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/diam", ujiDiam);

    var uji = Uji.init();
    defer uji.deinit();
    const hasil = uji.kirim(&app, "GET /diam HTTP/1.1\r\n\r\n");
    try testing.expect(hasil.lanjut);
    try testing.expect(std.mem.startsWith(u8, hasil.balasan, "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 0\r\n"));
}

fn ujiHeaderDanQuery(c: *Ctx) anyerror!void {
    try testing.expectEqualStrings("zig", c.query("kata").?.lihat());
    try testing.expectEqualStrings("", c.query("kosong").?.lihat());
    try testing.expect(c.query("tidak-ada") == null);
    try testing.expectEqualStrings("rahasia", c.header("X-Token").?.lihat());
    try testing.expectEqualStrings("rahasia", c.header("x-token").?.lihat());
    try c.balasTeks(200, "oke");
}

test "query dan header terbaca dari Ctx" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/cari", ujiHeaderDanQuery);

    var uji = Uji.init();
    defer uji.deinit();
    const hasil = uji.kirim(&app, "GET /cari?kata=zig&kosong= HTTP/1.1\r\nX-Token: rahasia\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, hasil.balasan, "HTTP/1.1 200"));
}
