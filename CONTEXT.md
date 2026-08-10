# zfast

Framework HTTP untuk Zig yang mengutamakan kenyamanan menulis kode, dengan performa sebagai konsekuensi — bukan sebaliknya. Sasarannya orang yang terbiasa di Go atau Node dan sedang mencoba Zig.

## Language

### Lapisan

**Mesin**:
Lapisan paling bawah yang berurusan dengan sistem operasi: menerima koneksi, membaca dan menulis byte. Tidak tahu apa-apa soal HTTP.
_Avoid_: runtime, backend, driver, event loop

**Sekat**:
Batas internal antara zfast dan Mesin. Semua yang zfast butuhkan dari Mesin lewat sini, sehingga Mesin bisa diganti tanpa menyentuh kode pengguna.
_Avoid_: adapter, abstraction layer, interface

**Ctx**:
Objek yang mewakili satu request yang sedang berjalan, beserta seluruh kendali atasnya. Ini API zfast yang sesungguhnya — semua lapisan di atasnya berubah menjadi pemanggilan ke sini saat kompilasi.
_Avoid_: Context, Request context, c

**Handler bertipe**:
Fungsi biasa yang hanya menerima data yang ia butuhkan dan mengembalikan data. zfast yang mencocokkan argumennya saat kompilasi. Ini wajah zfast bagi pengguna.
_Avoid_: magic handler, extractor, auto handler

### Data

**Str**:
Teks yang berasal dari sebuah request. Hidup hanya selama request itu berjalan, dan isinya tidak bisa diambil tanpa memanggil sesuatu secara sadar.
_Avoid_: string, slice, []const u8

**keep**:
Tindakan menyalin sebuah Str ke memori yang berumur lebih panjang, agar aman disimpan setelah request selesai.
_Avoid_: dupe, clone, copy, to_owned

**Arena request**:
Kantong memori milik satu request. Seluruh isinya dibuang sekaligus saat request selesai, dan pengguna tidak pernah menyentuhnya secara langsung.
_Avoid_: allocator request, pool, scratch

### Perakitan

**App**:
Satu aplikasi HTTP yang berdiri sendiri: kumpulan Rute, Middleware, dan Layanan. Satu proses boleh punya lebih dari satu.
_Avoid_: Server, Router, Engine

**Layanan**:
Barang berumur panjang yang didaftarkan sekali saat App dibuat — koneksi database, konfigurasi, logger — lalu diminta oleh Handler berdasarkan tipenya.
_Avoid_: dependency, state, context value, DI container

**Middleware**:
Potongan kerja yang berjalan sebelum dan sesudah Handler, bekerja di lapisan Ctx, dan tidak menghasilkan nilai untuk Handler.
_Avoid_: filter, interceptor, hook, penjaga

**Fungsi gagal**:
Fungsi yang bisa dipanggil dari mana saja untuk menghentikan request dengan status dan pesan tertentu, tanpa perlu memegang Ctx.
_Avoid_: abort, throw, bail
