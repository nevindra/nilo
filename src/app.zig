//! App — satu aplikasi HTTP yang berdiri sendiri: kumpulan Rute dan
//! Layanan (Middleware menyusul di tahap 4). Merangkai Sekat, parser
//! HTTP/1.1, Router, Arena request, dan Ctx menjadi satu.
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
const layanan_mod = @import("layanan.zig");
const bertipe = @import("bertipe.zig");
const gagal = @import("gagal.zig");

const Ctx = ctx_mod.Ctx;

const RESPONS_400 = http1.responsStatis(400, "Bad Request", "text/plain", "permintaan rusak\n", false);
const RESPONS_431 = http1.responsStatis(431, "Request Header Fields Too Large", "text/plain", "kepala kepanjangan\n", false);

pub const App = struct {
    gpa: std.mem.Allocator,
    router: router_mod.Router,
    layanan: layanan_mod.Daftar,
    /// Layanan yang diminta handler, dikumpulkan saat rute didaftarkan
    /// dan dicek sekali di `dengarkan()` (ADR 0006).
    kebutuhan: std.ArrayList(layanan_mod.Kebutuhan) = .empty,

    pub fn init(gpa: std.mem.Allocator) App {
        return .{
            .gpa = gpa,
            .router = router_mod.Router.init(gpa),
            .layanan = layanan_mod.Daftar.init(gpa),
        };
    }

    pub fn deinit(self: *App) void {
        self.kebutuhan.deinit(self.gpa);
        self.layanan.deinit();
        self.router.deinit();
    }

    /// Daftarkan sebuah Layanan. `ptr` harus hidup selama App hidup.
    /// Urutannya bebas terhadap pendaftaran rute; yang penting semuanya
    /// selesai sebelum `dengarkan()`.
    pub fn daftarkan(self: *App, ptr: anytype) !void {
        try self.layanan.tambah(ptr);
    }

    pub fn get(self: *App, comptime pola: []const u8, comptime penangan: anytype) !void {
        try self.rute(.GET, pola, penangan);
    }

    pub fn post(self: *App, comptime pola: []const u8, comptime penangan: anytype) !void {
        try self.rute(.POST, pola, penangan);
    }

    pub fn put(self: *App, comptime pola: []const u8, comptime penangan: anytype) !void {
        try self.rute(.PUT, pola, penangan);
    }

    pub fn delete(self: *App, comptime pola: []const u8, comptime penangan: anytype) !void {
        try self.rute(.DELETE, pola, penangan);
    }

    pub fn patch(self: *App, comptime pola: []const u8, comptime penangan: anytype) !void {
        try self.rute(.PATCH, pola, penangan);
    }

    pub fn head(self: *App, comptime pola: []const u8, comptime penangan: anytype) !void {
        try self.rute(.HEAD, pola, penangan);
    }

    pub fn options(self: *App, comptime pola: []const u8, comptime penangan: anytype) !void {
        try self.rute(.OPTIONS, pola, penangan);
    }

    /// Semua pendaftaran rute lewat sini. Handler apa pun bentuknya —
    /// `fn (*Ctx) !void` maupun Handler bertipe — dijahit ke penangan Ctx
    /// oleh mesin comptime, jadi jalur requestnya cuma satu.
    pub fn rute(
        self: *App,
        metode: http1.Metode,
        comptime pola: []const u8,
        comptime penangan: anytype,
    ) !void {
        try self.kebutuhan.appendSlice(self.gpa, comptime bertipe.kebutuhan(pola, penangan));
        try self.router.tambah(metode, pola, comptime bertipe.bungkus(pola, penangan));
    }

    /// Kebutuhan Layanan pertama yang belum terpenuhi, atau null kalau
    /// semua handler kebagian apa yang mereka minta.
    pub fn layananKurang(self: *const App) ?layanan_mod.Kebutuhan {
        for (self.kebutuhan.items) |k| {
            if (!self.layanan.punya(k)) return k;
        }
        return null;
    }

    /// Sama seperti `layananKurang`, tapi mencatat semua yang kurang ke
    /// log lalu gagal. Dipanggil otomatis oleh `dengarkan()` — inilah yang
    /// membuat Layanan yang lupa didaftarkan ketahuan sebelum satu request
    /// pun dilayani, bukan jam tiga pagi (ADR 0006).
    pub fn periksaLayanan(self: *const App) error{LayananBelumDidaftarkan}!void {
        if (self.layananKurang() == null) return;
        for (self.kebutuhan.items) |k| {
            if (self.layanan.punya(k)) continue;
            std.log.err(
                "handler rute \"{s}\" minta Layanan {s}{s} yang belum didaftarkan " ++
                    "— panggil app.daftarkan() sebelum app.dengarkan()",
                .{ k.rute, if (k.perlu_ubah) "*" else "*const ", k.tipe },
            );
        }
        return error.LayananBelumDidaftarkan;
    }

    /// Mendengarkan dan melayani sampai proses dihentikan.
    pub fn dengarkan(self: *App, opsi: sekat.Opsi) !void {
        try self.periksaLayanan();
        try sekat.layani(self.gpa, opsi, self, urusKoneksi);
    }

    fn urusKoneksi(self: *App, in: *std.Io.Reader, out: *std.Io.Writer) void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        var umur = str_mod.Umur{};

        // Kotak Fungsi gagal diikat ke fiber ini sekali, lalu dipakai
        // ulang tiap request di koneksi yang sama (ADR 0007).
        var kotak = gagal.Kotak{};
        var ikatan = sekat.ikatan_kosong;
        sekat.ikatSlot(&ikatan, &kotak);
        defer sekat.lepasSlot(&ikatan);

        while (true) {
            const lanjut = self.urusSatuRequest(arena.allocator(), &umur, &kotak, in, out);
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
        kotak: *gagal.Kotak,
        in: *std.Io.Reader,
        out: *std.Io.Writer,
    ) bool {
        kotak.kosongkan();
        // Di server sungguhan slot fiber sudah terpasang dan menang;
        // ini yang membuat Fungsi gagal tetap bekerja saat App dipanggil
        // langsung dari tes, tanpa Mesin di bawahnya.
        const slot_lama = sekat.pasangSlotCadangan(kotak);
        defer _ = sekat.pasangSlotCadangan(slot_lama);

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
            ._layanan = &self.layanan,
        };

        const kecocokan = self.router.cocok(c.metode, jalur) orelse {
            http1.buangIsi(in, &p) catch return false;
            balasLangsung(out, c.metode, 404, "tidak ditemukan\n", p.keep_alive) catch return false;
            return p.keep_alive;
        };
        c._param = kecocokan.param[0..kecocokan.n_param];

        kecocokan.penangan(&c) catch |err| {
            // Jawaban yang sudah separuh terkirim tidak bisa ditarik, jadi
            // koneksinya ditutup: request berikutnya di koneksi yang sama
            // akan membaca sisa byte yang tidak jelas.
            if (c._terkirim) {
                std.log.warn("penangan {s} {s} gagal setelah menjawab: {s}", .{ @tagName(c.metode), jalur, @errorName(err) });
                return false;
            }
            // Belum menjawab: ini kegagalan yang rapi. Isi yang belum
            // dibaca tetap harus dibuang supaya koneksinya bisa dipakai
            // lagi — 404 dari Fungsi gagal adalah jalan hidup yang normal,
            // bukan alasan memutus keep-alive.
            if (c._isi == null) http1.buangIsi(in, &p) catch return false;
            balasGagal(out, kotak, err, c.metode, jalur, p.keep_alive) catch return false;
            return p.keep_alive;
        };

        // Isi yang tidak dibaca penangan dibuang supaya request
        // berikutnya di koneksi ini mulai dari byte yang benar.
        if (c._isi == null) http1.buangIsi(in, &p) catch return false;

        if (!c._terkirim) {
            balasLangsung(out, c.metode, 200, "", p.keep_alive) catch return false;
        }
        return p.keep_alive;
    }
};

fn balasTerakhir(out: *std.Io.Writer, respons: []const u8) void {
    out.writeAll(respons) catch return;
    out.flush() catch return;
}

/// Jawaban yang dirakit App sendiri — 404 rute tak dikenal, 200 kosong,
/// jawaban gagal — di luar `Ctx.balas`. Sama seperti di sana, isi tidak
/// ikut terkirim untuk HEAD.
fn balasLangsung(
    out: *std.Io.Writer,
    metode: http1.Metode,
    status: u16,
    isi: []const u8,
    keep_alive: bool,
) !void {
    if (metode == .HEAD) return http1.tulisResponsTanpaIsi(
        out,
        status,
        http1.frasaStatus(status),
        "text/plain",
        isi.len,
        keep_alive,
    );
    try http1.tulisRespons(out, status, http1.frasaStatus(status), "text/plain", isi, keep_alive);
}

/// Ubah kegagalan handler menjadi respons. Pesan dari Fungsi gagal
/// dipakai kalau ada; kalau tidak, errornya dipetakan lewat tabel dan
/// yang tidak dikenali jadi 500 sambil dicatat dengan nama errornya
/// (ADR 0005).
fn balasGagal(
    out: *std.Io.Writer,
    kotak: *const gagal.Kotak,
    err: anyerror,
    metode: http1.Metode,
    jalur: []const u8,
    keep_alive: bool,
) !void {
    var buf: [gagal.maks_pesan + 1]u8 = undefined;

    const status: u16, const pesan: []const u8 = if (kotak.ada())
        .{ kotak.status, kotak.pesan() }
    else blk: {
        const s = gagal.statusUntuk(err);
        if (s == 500) {
            std.log.warn("penangan {s} {s} gagal: {s}", .{ @tagName(metode), jalur, @errorName(err) });
            // Nama error internal tidak dibocorkan ke klien; yang mau
            // pesan yang enak dibaca memakai Fungsi gagal.
            break :blk .{ s, "galat di server" };
        }
        break :blk .{ s, http1.frasaStatus(s) };
    };

    // Baris pesan diakhiri newline supaya enak dibaca di curl.
    const isi = std.fmt.bufPrint(&buf, "{s}\n", .{pesan}) catch pesan;
    try balasLangsung(out, metode, status, isi, keep_alive);
}

// ---- tes: seluruh perilaku HTTP tanpa menyalakan server ----

const testing = std.testing;

const Uji = struct {
    arena: std.heap.ArenaAllocator,
    umur: str_mod.Umur = .{},
    kotak: gagal.Kotak = .{},
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
        const lanjut = app.urusSatuRequest(self.arena.allocator(), &self.umur, &self.kotak, &in, &out);
        self.umur.selesai();
        _ = self.arena.reset(.retain_capacity);
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

test "error yang tak dikenali jadi 500, tapi koneksi tetap hidup" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/meledak", ujiMeledak);

    var uji = Uji.init();
    defer uji.deinit();
    const hasil = uji.kirim(&app, "GET /meledak HTTP/1.1\r\n\r\n");

    try testing.expect(std.mem.startsWith(u8, hasil.balasan, "HTTP/1.1 500 Internal Server Error\r\n"));
    // Belum ada satu byte pun jawaban yang terkirim saat handler gagal,
    // jadi koneksinya masih bersih dan boleh dipakai lagi.
    try testing.expect(hasil.lanjut);
    // Nama error internal tidak ikut bocor ke klien.
    try testing.expect(std.mem.indexOf(u8, hasil.balasan, "SengajaMeledak") == null);
}

test "handler yang gagal setelah menjawab menutup koneksi" {
    const Sebagian = struct {
        fn urus(c: *Ctx) anyerror!void {
            try c.balasTeks(200, "separuh");
            return error.SengajaMeledak;
        }
    };

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/separuh", Sebagian.urus);

    var uji = Uji.init();
    defer uji.deinit();
    const hasil = uji.kirim(&app, "GET /separuh HTTP/1.1\r\n\r\n");

    try testing.expect(std.mem.startsWith(u8, hasil.balasan, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(!hasil.lanjut);
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

// ---- tahap 3: Handler bertipe, Layanan, Fungsi gagal ----

const Str = str_mod.Str;

const Db = struct {
    baris: []const User,

    const User = struct { id: u32, nama: []const u8 };

    fn cari(self: *const Db, id: u32) ?User {
        for (self.baris) |u| {
            if (u.id == id) return u;
        }
        return null;
    }
};

const Jawab = struct { id: u32, nama: []const u8 };

/// Bentuk yang dikejar sejak README: fungsi biasa, tanpa `Ctx`, tanpa
/// HTTP palsu, dengan Layanan yang diminta lewat tipenya.
fn getUser(db: *Db, id: u32) !Jawab {
    const u = db.cari(id) orelse return gagal.notFound("user {d} tidak ditemukan", .{id});
    return .{ .id = u.id, .nama = u.nama };
}

test "handler bertipe: Layanan dan path param dicocokkan lewat tipe" {
    var db = Db{ .baris = &.{.{ .id = 7, .nama = "wati" }} };

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.daftarkan(&db);
    try app.get("/users/:id", getUser);
    try app.periksaLayanan();

    var uji = Uji.init();
    defer uji.deinit();
    const hasil = uji.kirim(&app, "GET /users/7 HTTP/1.1\r\n\r\n");

    try testing.expect(hasil.lanjut);
    try testing.expect(std.mem.startsWith(u8, hasil.balasan, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.indexOf(u8, hasil.balasan, "Content-Type: application/json") != null);
    try testing.expect(std.mem.indexOf(u8, hasil.balasan, "{\"id\":7,\"nama\":\"wati\"}") != null);
}

// Nilai jual utamanya (ADR 0003): handler diuji sebagai fungsi biasa,
// tanpa menyalakan server dan tanpa HTTP palsu.
test "handler bertipe bisa diuji sebagai fungsi biasa" {
    var db = Db{ .baris = &.{.{ .id = 7, .nama = "wati" }} };

    try testing.expectEqual(@as(u32, 7), (try getUser(&db, 7)).id);
    try testing.expectError(error.Gagal, getUser(&db, 99));
}

test "Fungsi gagal jadi status dan pesannya, koneksi tetap hidup" {
    var db = Db{ .baris = &.{} };

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.daftarkan(&db);
    try app.get("/users/:id", getUser);

    var uji = Uji.init();
    defer uji.deinit();
    const hasil = uji.kirim(&app, "GET /users/99 HTTP/1.1\r\n\r\n");

    try testing.expect(std.mem.startsWith(u8, hasil.balasan, "HTTP/1.1 404 Not Found\r\n"));
    try testing.expect(std.mem.indexOf(u8, hasil.balasan, "user 99 tidak ditemukan") != null);
    try testing.expect(hasil.lanjut);
}

test "path param yang bukan angka jadi 400 dengan pesan yang jelas" {
    var db = Db{ .baris = &.{} };

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.daftarkan(&db);
    try app.get("/users/:id", getUser);

    var uji = Uji.init();
    defer uji.deinit();
    const hasil = uji.kirim(&app, "GET /users/abc HTTP/1.1\r\n\r\n");

    try testing.expect(std.mem.startsWith(u8, hasil.balasan, "HTTP/1.1 400 Bad Request\r\n"));
    try testing.expect(std.mem.indexOf(u8, hasil.balasan, ":id harus bilangan bulat") != null);
    try testing.expect(hasil.lanjut);
}

test "Kotak gagal tidak bocor ke request berikutnya di koneksi yang sama" {
    var db = Db{ .baris = &.{.{ .id = 7, .nama = "wati" }} };

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.daftarkan(&db);
    try app.get("/users/:id", getUser);

    var uji = Uji.init();
    defer uji.deinit();

    const gagal_dulu = uji.kirim(&app, "GET /users/99 HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, gagal_dulu.balasan, "HTTP/1.1 404"));

    const lalu_berhasil = uji.kirim(&app, "GET /users/7 HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, lalu_berhasil.balasan, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.indexOf(u8, lalu_berhasil.balasan, "tidak ditemukan") == null);
}

const UserBaru = struct { nama: Str };

fn buatUser(masuk: UserBaru) !bertipe.Jawaban(Jawab) {
    if (masuk.nama.panjang() == 0) return gagal.unprocessable("nama tidak boleh kosong", .{});
    return .{ .status = 201, .nilai = .{ .id = 1, .nama = masuk.nama.lihat() } };
}

test "isi JSON masuk sebagai struct, Jawaban(T) menentukan statusnya" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/users", buatUser);

    var uji = Uji.init();
    defer uji.deinit();
    const hasil = uji.kirim(&app, "POST /users HTTP/1.1\r\nContent-Length: 16\r\n\r\n{\"nama\":\"wati\"}\r\n");

    try testing.expect(std.mem.startsWith(u8, hasil.balasan, "HTTP/1.1 201 Created\r\n"));
    try testing.expect(std.mem.indexOf(u8, hasil.balasan, "{\"id\":1,\"nama\":\"wati\"}") != null);
}

test "isi JSON yang tidak lolos aturan jadi 422 lewat Fungsi gagal" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/users", buatUser);

    var uji = Uji.init();
    defer uji.deinit();
    const hasil = uji.kirim(&app, "POST /users HTTP/1.1\r\nContent-Length: 12\r\n\r\n{\"nama\":\"\"}\n");

    try testing.expect(std.mem.startsWith(u8, hasil.balasan, "HTTP/1.1 422 Unprocessable Content\r\n"));
    try testing.expect(std.mem.indexOf(u8, hasil.balasan, "nama tidak boleh kosong") != null);
}

test "JSON rusak dipetakan tabel error jadi 400" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/users", buatUser);

    var uji = Uji.init();
    defer uji.deinit();
    const hasil = uji.kirim(&app, "POST /users HTTP/1.1\r\nContent-Length: 5\r\n\r\n{nama");

    try testing.expect(std.mem.startsWith(u8, hasil.balasan, "HTTP/1.1 400 Bad Request\r\n"));
    try testing.expect(hasil.lanjut);
}

fn salamStr(nama: Str) Str {
    return nama;
}

fn hitung(a: i32, b: i32) i64 {
    return @as(i64, a) * b;
}

const Warna = enum { merah, hijau, biru };

fn pilihWarna(w: Warna, terang: bool) []const u8 {
    return if (terang) @tagName(w) else "gelap";
}

test "path param bertipe Str, angka, enum, dan bool" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/salam/:nama", salamStr);
    try app.get("/kali/:a/:b", hitung);
    try app.get("/warna/:w/:terang", pilihWarna);

    var uji = Uji.init();
    defer uji.deinit();

    const salam = uji.kirim(&app, "GET /salam/wati HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, salam.balasan, "Content-Type: text/plain") != null);
    try testing.expect(std.mem.endsWith(u8, salam.balasan, "wati"));

    const kali = uji.kirim(&app, "GET /kali/6/7 HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.endsWith(u8, kali.balasan, "42"));

    const warna = uji.kirim(&app, "GET /warna/hijau/true HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.endsWith(u8, warna.balasan, "hijau"));

    const salah = uji.kirim(&app, "GET /warna/ungu/true HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, salah.balasan, "HTTP/1.1 400 Bad Request\r\n"));
    try testing.expect(std.mem.indexOf(u8, salah.balasan, ":w bukan pilihan yang dikenal") != null);
}

test "Layanan yang belum didaftarkan tertangkap sebelum melayani" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/users/:id", getUser); // butuh *Db, tapi tidak didaftarkan

    // `dengarkan()` memanggil `periksaLayanan()`, yang mencatat tiap
    // kekurangan ke log lalu gagal. Di sini dicek lewat predikatnya
    // supaya tesnya tidak ikut menghitung log error itu sebagai kegagalan.
    const kurang = app.layananKurang().?;
    try testing.expectEqualStrings("/users/:id", kurang.rute);
    try testing.expectEqualStrings(@typeName(Db), kurang.tipe);
    try testing.expect(kurang.perlu_ubah);
}

fn pakaiKonfigurasi(cfg: *const Konfigurasi, c: *Ctx) !void {
    try c.balasTeks(200, if (cfg.debug) "debug" else "rilis");
}

const Konfigurasi = struct { debug: bool };

test "Layanan const dan *Ctx boleh diminta bersamaan" {
    const cfg = Konfigurasi{ .debug = true };

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.daftarkan(&cfg);
    try app.get("/mode", pakaiKonfigurasi);
    try app.periksaLayanan();

    var uji = Uji.init();
    defer uji.deinit();
    const hasil = uji.kirim(&app, "GET /mode HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.endsWith(u8, hasil.balasan, "debug"));
}

fn hanyaCtx(c: *Ctx) !void {
    // Handler `*Ctx` boleh mengabaikan path param di pola; ia mengambil
    // sendiri yang ia butuhkan.
    try c.balasTeks(200, c.param("id").?.lihat());
}

test "HEAD memberi kepala yang sama dengan GET, tanpa isi" {
    var db = Db{ .baris = &.{.{ .id = 7, .nama = "wati" }} };

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.daftarkan(&db);
    try app.get("/users/:id", getUser);
    try app.head("/users/:id", getUser);

    var uji = Uji.init();
    defer uji.deinit();

    const get = uji.kirim(&app, "GET /users/7 HTTP/1.1\r\n\r\n");
    const kepala_get = get.balasan[0 .. std.mem.indexOf(u8, get.balasan, "\r\n\r\n").? + 4];

    const head = uji.kirim(&app, "HEAD /users/7 HTTP/1.1\r\n\r\n");

    // Kepalanya identik — termasuk Content-Length yang menyebut panjang
    // isi seandainya dikirim — tapi tidak ada satu byte isi pun.
    try testing.expectEqualStrings(kepala_get, head.balasan);
    try testing.expect(std.mem.indexOf(u8, head.balasan, "Content-Length: 22\r\n") != null);
    try testing.expect(head.lanjut);
}

test "HEAD ke rute tak dikenal dan ke jalur gagal juga tanpa isi" {
    var db = Db{ .baris = &.{} };

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.daftarkan(&db);
    try app.head("/users/:id", getUser);

    var uji = Uji.init();
    defer uji.deinit();

    const gagal_404 = uji.kirim(&app, "HEAD /users/99 HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, gagal_404.balasan, "HTTP/1.1 404 Not Found\r\n"));
    try testing.expect(std.mem.endsWith(u8, gagal_404.balasan, "\r\n\r\n"));
    try testing.expect(std.mem.indexOf(u8, gagal_404.balasan, "tidak ditemukan\n") == null);

    const tak_terute = uji.kirim(&app, "HEAD /entah HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, tak_terute.balasan, "HTTP/1.1 404 Not Found\r\n"));
    try testing.expect(std.mem.endsWith(u8, tak_terute.balasan, "\r\n\r\n"));
}

test "handler *Ctx tidak wajib mendeklarasikan path param" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/mentah/:id/:lain", hanyaCtx);

    var uji = Uji.init();
    defer uji.deinit();
    const hasil = uji.kirim(&app, "GET /mentah/42/x HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.endsWith(u8, hasil.balasan, "42"));
}
