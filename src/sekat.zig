//! Sekat — batas internal antara zfast dan Mesin.
//!
//! Semua yang zfast butuhkan dari Mesin lewat file ini: terima koneksi,
//! baca, tulis, tutup. Tidak ada bagian zfast di luar `src/mesin/` yang
//! boleh menyebut zio. Mengganti Mesin berarti mengganti satu import
//! di bawah ini, tanpa menyentuh kode di lapisan atas.
//!
//! Kontrak untuk sebuah Mesin:
//! - `Opsi` — alamat dan port tempat mendengarkan.
//! - `Penangan` — fungsi yang menerima satu koneksi sebagai pasangan
//!   `*std.Io.Reader` / `*std.Io.Writer` dan mengurusnya sampai selesai.
//! - `layani(gpa, opsi, penangan)` — mendengarkan, menerima koneksi,
//!   dan menjalankan `penangan` untuk tiap koneksi secara konkuren.
//! - `debug_io` — dipasang ke `std_options_debug_io` supaya `std.log`
//!   tidak memblokir event loop.
//!
//! Reader/Writer yang diberikan ke Penangan adalah tipe std murni, jadi
//! lapisan HTTP tidak tahu Mesin apa yang ada di baliknya.

const mesin = @import("mesin/zio.zig");

pub const Opsi = mesin.Opsi;
pub const Penangan = mesin.Penangan;
pub const layani = mesin.layani;
pub const debug_io = mesin.debug_io;
