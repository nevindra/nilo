//! Sekat — batas internal antara zfast dan Mesin.
//!
//! Semua yang zfast butuhkan dari Mesin lewat file ini: terima koneksi,
//! baca, tulis, tutup. Tidak ada bagian zfast di luar `src/mesin/` yang
//! boleh menyebut zio. Mengganti Mesin berarti mengganti satu import
//! di bawah ini, tanpa menyentuh kode di lapisan atas.
//!
//! Kontrak untuk sebuah Mesin:
//! - `Opsi` — alamat dan port tempat mendengarkan.
//! - `layani(gpa, opsi, state, penangan)` — mendengarkan, menerima
//!   koneksi, dan menjalankan `penangan(state, in, out)` untuk tiap
//!   koneksi secara konkuren sampai koneksi selesai. `state` dibawa
//!   apa adanya (biasanya `*App`).
//! - `debug_io` — dipasang ke `std_options_debug_io` supaya `std.log`
//!   tidak memblokir event loop.
//! - `Ikatan`/`ikatSlot`/`lepasSlot`/`slot` — satu penunjuk yang terikat
//!   ke unit kerja yang sedang berjalan (fiber, utas, apa pun yang
//!   dipakai Mesin), untuk state per-request tersembunyi (ADR 0007).
//!
//! Reader/Writer yang diberikan ke penangan adalah tipe std murni
//! (`*std.Io.Reader`, `*std.Io.Writer`), jadi lapisan HTTP tidak tahu
//! Mesin apa yang ada di baliknya.

const mesin = @import("mesin/zio.zig");

pub const Opsi = mesin.Opsi;
pub const layani = mesin.layani;
pub const debug_io = mesin.debug_io;

pub const Ikatan = mesin.Ikatan;
pub const ikatan_kosong = mesin.ikatan_kosong;
pub const ikatSlot = mesin.ikatSlot;
pub const lepasSlot = mesin.lepasSlot;

/// Cadangan untuk pemakaian di luar Mesin: unit test memanggil App
/// langsung, tanpa fiber, jadi `mesin.slot()` di sana selalu null.
/// Di server sungguhan slot fiber selalu ada dan menang, sehingga
/// nilai di sini tidak pernah terbaca.
threadlocal var slot_cadangan: ?*anyopaque = null;

/// Pasang slot cadangan, kembalikan yang lama supaya bisa dipulihkan.
pub fn pasangSlotCadangan(p: ?*anyopaque) ?*anyopaque {
    const lama = slot_cadangan;
    slot_cadangan = p;
    return lama;
}

/// Slot request yang sedang berjalan, atau null kalau tidak ada.
pub fn slot() ?*anyopaque {
    return mesin.slot() orelse slot_cadangan;
}
