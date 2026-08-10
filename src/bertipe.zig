//! Mesin comptime — mengubah Handler bertipe menjadi penangan `Ctx`
//! biasa saat kompilasi (ADR 0003).
//!
//! ```zig
//! fn getUser(db: *Db, id: u32) !User { ... }
//! app.get("/users/:id", getUser);
//! ```
//!
//! Yang dibaca mesin ini cuma daftar argumen. Aturannya satu kalimat:
//! **penunjuk itu Layanan, nilai itu data request.**
//!
//! | Argumen             | Artinya                                       |
//! |---------------------|-----------------------------------------------|
//! | `*Ctx`              | request mentah — jalan keluar kalau butuh kendali penuh |
//! | `*Db`, `*const Cfg` | Layanan, dicocokkan lewat tipenya             |
//! | `u32`, `Str`, `bool`, enum | path param, berurutan sesuai `:nama` di pola |
//! | sebuah struct       | isi request, di-parse dari JSON               |
//!
//! Nilai baliknya jadi jawaban: `void` → 200 kosong, `Str`/`[]const u8`
//! → text/plain, selain itu → JSON. Bungkus dengan `Jawaban(T)` kalau
//! statusnya bukan 200.
//!
//! Zig tidak menyimpan nama argumen, jadi path param dicocokkan **urut
//! posisi**, bukan nama. Semua ketidakcocokan — jumlah param, tipe yang
//! tidak masuk akal, dua isi request — berhenti saat kompilasi dengan
//! pesan yang menyebut rutenya. Kualitas pesan itu satu-satunya harga
//! yang dibayar lapisan ini (ADR 0003), jadi ia digarap serius di sini.

const std = @import("std");
const ctx_mod = @import("ctx.zig");
const router = @import("router.zig");
const layanan_mod = @import("layanan.zig");
const gagal = @import("gagal.zig");
const str_mod = @import("str.zig");

const Ctx = ctx_mod.Ctx;
const Str = str_mod.Str;

/// Jawaban dengan status selain 200.
///
/// ```zig
/// fn buatUser(masuk: UserBaru) !Jawaban(User) {
///     return .{ .status = 201, .nilai = ... };
/// }
/// ```
pub fn Jawaban(comptime T: type) type {
    return struct {
        pub const zfast_jawaban = T;

        status: u16 = 200,
        nilai: T,
    };
}

/// Peran satu argumen handler, diputuskan saat kompilasi.
const Peran = union(enum) {
    ctx,
    layanan,
    /// Indeks path param di pola rute, urut posisi.
    param: usize,
    isi,
};

/// Ubah `f` menjadi penangan `Ctx` biasa. `pola` ikut masuk supaya
/// jumlah path param bisa dicek dan pesan errornya bisa menyebut rute.
pub fn bungkus(comptime pola: []const u8, comptime f: anytype) router.PenanganCtx {
    const Fn = comptime fnDari(pola, @TypeOf(f));
    const params = @typeInfo(Fn).@"fn".params;
    const peran = comptime peranSemua(pola, params);
    const nama_param = comptime namaParamPola(pola);

    const Bungkus = struct {
        fn urus(c: *Ctx) anyerror!void {
            var args: std.meta.ArgsTuple(Fn) = undefined;
            inline for (params, 0..) |p, i| {
                const P = p.type.?;
                switch (comptime peran[i]) {
                    .ctx => args[i] = c,
                    .layanan => args[i] = c._layanan.ambil(P) orelse
                        return gagal.internal(
                            "Layanan {s} belum didaftarkan; panggil app.daftarkan() sebelum app.dengarkan()",
                            .{@typeName(P)},
                        ),
                    .param => |ke| args[i] = try ambilParam(P, c, nama_param[ke]),
                    .isi => args[i] = try c.json(P),
                }
            }
            return kirimHasil(c, @call(.auto, f, args));
        }
    };
    return Bungkus.urus;
}

/// Layanan apa saja yang dibutuhkan handler ini. Dihitung saat kompilasi,
/// dipakai App untuk memeriksa daftar Layanan sekali saat startup.
pub fn kebutuhan(comptime pola: []const u8, comptime f: anytype) []const layanan_mod.Kebutuhan {
    comptime {
        const Fn = fnDari(pola, @TypeOf(f));
        const params = @typeInfo(Fn).@"fn".params;
        const peran = peranSemua(pola, params);

        var daftar: []const layanan_mod.Kebutuhan = &.{};
        for (params, 0..) |p, i| {
            if (peran[i] != .layanan) continue;
            daftar = daftar ++ [_]layanan_mod.Kebutuhan{layanan_mod.kebutuhanDari(p.type.?, pola)};
        }
        return daftar;
    }
}

// ---- sisi kompilasi ----

fn fnDari(comptime pola: []const u8, comptime F: type) type {
    const Fn = switch (@typeInfo(F)) {
        .@"fn" => F,
        // Penangan boleh diberikan sebagai penunjuk fungsi juga.
        .pointer => |p| if (@typeInfo(p.child) == .@"fn") p.child else salahBentuk(pola, F),
        else => salahBentuk(pola, F),
    };
    if (@typeInfo(Fn).@"fn".is_generic) @compileError(
        "zfast: handler rute \"" ++ pola ++ "\" masih generik (ada argumen `anytype` atau `comptime`).\n" ++
            "  zfast harus tahu tipe tiap argumen untuk mencocokkannya. Tulis tipenya secara eksplisit.",
    );
    if (@typeInfo(Fn).@"fn".is_var_args) @compileError(
        "zfast: handler rute \"" ++ pola ++ "\" memakai varargs C, yang tidak bisa dicocokkan.",
    );
    return Fn;
}

fn salahBentuk(comptime pola: []const u8, comptime F: type) noreturn {
    @compileError(
        "zfast: handler rute \"" ++ pola ++ "\" harus sebuah fungsi, bukan " ++ @typeName(F) ++ ".\n" ++
            "  Tulis `app.get(\"" ++ pola ++ "\", getUser)` — nama fungsinya, tanpa dipanggil.",
    );
}

fn peranSemua(
    comptime pola: []const u8,
    comptime params: []const std.builtin.Type.Fn.Param,
) []const Peran {
    comptime {
        const nama_param = namaParamPola(pola);
        var peran: [params.len]Peran = undefined;
        var terpakai: usize = 0;
        var sudah_ada_isi = false;
        var minta_ctx = false;

        for (params, 0..) |p, i| {
            const P = p.type orelse @compileError(
                "zfast: argumen ke-" ++ nomor(i + 1) ++ " handler rute \"" ++ pola ++ "\" tidak bertipe.",
            );
            peran[i] = peranSatu(pola, P, i);
            switch (peran[i]) {
                .ctx => minta_ctx = true,
                .param => {
                    if (terpakai == nama_param.len) @compileError(kurangPola(pola, P, i, nama_param));
                    peran[i] = .{ .param = terpakai };
                    terpakai += 1;
                },
                .isi => {
                    if (sudah_ada_isi) @compileError(
                        "zfast: handler rute \"" ++ pola ++ "\" minta dua isi request (argumen ke-" ++
                            nomor(i + 1) ++ " bertipe " ++ @typeName(P) ++ ").\n" ++
                            "  Satu request cuma punya satu isi. Kalau " ++ @typeName(P) ++
                            " itu Layanan, mintalah sebagai penunjuk: `*" ++ @typeName(P) ++ "`.",
                    );
                    sudah_ada_isi = true;
                },
                else => {},
            }
        }

        // Handler yang memegang `*Ctx` boleh mengabaikan path param —
        // ia bisa mengambilnya sendiri lewat `c.param("…")`. Yang tanpa
        // `*Ctx` tidak punya jalan lain, jadi param yang tak terpakai di
        // sana hampir pasti argumen yang lupa ditulis.
        if (!minta_ctx and terpakai < nama_param.len) @compileError(
            "zfast: rute \"" ++ pola ++ "\" punya " ++ nomor(nama_param.len) ++ " path param (:" ++
                gabung(nama_param, ", :") ++ "), tapi handler-nya cuma menerima " ++ nomor(terpakai) ++ ".\n" ++
                "  Path param dicocokkan urut posisi, jadi yang di belakang tidak akan pernah terbaca.\n" ++
                "  Tambahkan argumennya (`id: u32`, `nama: zfast.Str`, …), buang `:` yang tidak dipakai dari pola, " ++
                "atau minta `*Ctx` kalau mau mengambilnya sendiri lewat `c.param(\"…\")`.",
        );
        const beku = peran;
        return &beku;
    }
}

fn peranSatu(comptime pola: []const u8, comptime P: type, comptime i: usize) Peran {
    if (P == *Ctx or P == *const Ctx) return .ctx;
    if (P == Str) return .{ .param = 0 };

    return switch (@typeInfo(P)) {
        .int, .float, .bool, .@"enum" => .{ .param = 0 },

        .pointer => |p| switch (p.size) {
            .one => .layanan,
            .slice => @compileError(
                "zfast: argumen ke-" ++ nomor(i + 1) ++ " handler rute \"" ++ pola ++ "\" bertipe " ++
                    @typeName(P) ++ ".\n" ++
                    "  Teks dari request diminta sebagai `zfast.Str`, bukan slice telanjang: Str-lah yang " ++
                    "menjaga supaya isinya tidak ikut tersimpan setelah request selesai (ADR 0004).\n" ++
                    "  Di dalam handler, `.lihat()` untuk membacanya dan `.keep()` untuk menyimpannya.",
            ),
            else => @compileError(
                "zfast: argumen ke-" ++ nomor(i + 1) ++ " handler rute \"" ++ pola ++ "\" bertipe " ++
                    @typeName(P) ++ ", yang tidak bisa dicocokkan.\n" ++
                    "  Layanan diminta sebagai penunjuk ke satu nilai (`*Db`).",
            ),
        },

        .@"struct" => .isi,

        .optional => @compileError(
            "zfast: argumen ke-" ++ nomor(i + 1) ++ " handler rute \"" ++ pola ++ "\" bertipe " ++
                @typeName(P) ++ ".\n" ++
                "  Path param di rute yang cocok selalu ada, jadi optional tidak punya arti di sini. " ++
                "Untuk yang boleh tidak ada — query param, header — mintalah `*Ctx` lalu " ++
                "`c.query(\"…\")`.",
        ),

        else => @compileError(
            "zfast: argumen ke-" ++ nomor(i + 1) ++ " handler rute \"" ++ pola ++ "\" bertipe " ++
                @typeName(P) ++ ", yang tidak dikenali zfast.\n" ++
                "  Yang bisa diminta: `*Ctx`, penunjuk ke Layanan (`*Db`), path param " ++
                "(`u32`, `zfast.Str`, `bool`, enum), atau satu struct untuk isi request.",
        ),
    };
}

fn kurangPola(
    comptime pola: []const u8,
    comptime P: type,
    comptime i: usize,
    comptime nama_param: []const []const u8,
) []const u8 {
    const punya = if (nama_param.len == 0)
        "rutenya tidak punya path param sama sekali"
    else
        "rutenya cuma punya " ++ nomor(nama_param.len) ++ " (:" ++ gabung(nama_param, ", :") ++ ")";

    return "zfast: argumen ke-" ++ nomor(i + 1) ++ " handler rute \"" ++ pola ++ "\" bertipe " ++
        @typeName(P) ++ ", jadi zfast membacanya sebagai path param — tapi " ++ punya ++ ".\n" ++
        "  Tambahkan `:nama` ke pola rutenya, atau — kalau " ++ @typeName(P) ++
        " itu Layanan — mintalah sebagai penunjuk: `*" ++ @typeName(P) ++ "`.";
}

/// Nama tiap `:param` di pola, urut kemunculan.
fn namaParamPola(comptime pola: []const u8) []const []const u8 {
    comptime {
        var nama: []const []const u8 = &.{};
        var seg = std.mem.splitScalar(u8, pola, '/');
        while (seg.next()) |s| {
            if (s.len > 1 and s[0] == ':') nama = nama ++ [_][]const u8{s[1..]};
        }
        return nama;
    }
}

fn nomor(comptime n: usize) []const u8 {
    return std.fmt.comptimePrint("{d}", .{n});
}

fn gabung(comptime bagian: []const []const u8, comptime pemisah: []const u8) []const u8 {
    comptime {
        var hasil: []const u8 = "";
        for (bagian, 0..) |b, i| hasil = hasil ++ (if (i == 0) "" else pemisah) ++ b;
        return hasil;
    }
}

// ---- sisi berjalan ----

fn ambilParam(comptime P: type, c: *const Ctx, comptime nama: []const u8) !P {
    // Rute sudah cocok, jadi param-nya pasti ada; `orelse` di sini cuma
    // supaya bug di zfast sendiri muncul sebagai pesan, bukan panik.
    const s = c.param(nama) orelse
        return gagal.internal("path param :{s} tidak terisi oleh router", .{nama});
    if (P == Str) return s;

    const teks = s.lihat();
    return switch (@typeInfo(P)) {
        .int => std.fmt.parseInt(P, teks, 10) catch
            return gagal.badRequest(":{s} harus bilangan bulat, bukan \"{s}\"", .{ nama, teks }),
        .float => std.fmt.parseFloat(P, teks) catch
            return gagal.badRequest(":{s} harus bilangan, bukan \"{s}\"", .{ nama, teks }),
        .bool => if (std.mem.eql(u8, teks, "true")) true else if (std.mem.eql(u8, teks, "false")) false else
            return gagal.badRequest(":{s} harus true atau false, bukan \"{s}\"", .{ nama, teks }),
        .@"enum" => std.meta.stringToEnum(P, teks) orelse
            return gagal.badRequest(":{s} bukan pilihan yang dikenal: \"{s}\"", .{ nama, teks }),
        else => comptime unreachable,
    };
}

fn kirimHasil(c: *Ctx, hasil: anytype) !void {
    const R = @TypeOf(hasil);
    const nilai = if (@typeInfo(R) == .error_union) try hasil else hasil;
    const T = @TypeOf(nilai);

    if (T == void) return;
    if (comptime punyaDecl(T, "zfast_jawaban")) return kirimNilai(c, nilai.status, nilai.nilai);
    return kirimNilai(c, 200, nilai);
}

fn kirimNilai(c: *Ctx, status: u16, nilai: anytype) !void {
    const T = @TypeOf(nilai);
    if (T == Str) return c.balasTeks(status, nilai.lihat());
    if (T == []const u8 or T == []u8) return c.balasTeks(status, nilai);
    return c.balasJson(status, nilai);
}

fn punyaDecl(comptime T: type, comptime nama: []const u8) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, nama),
        else => false,
    };
}
