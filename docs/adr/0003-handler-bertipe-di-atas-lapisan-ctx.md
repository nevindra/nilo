# Handler bertipe adalah pembungkus tipis di atas Ctx, bukan penggantinya

zfast punya dua lapisan API, dan itu disengaja. `Ctx` adalah API yang sesungguhnya. Handler bertipe hanyalah lapisan comptime yang, saat kompilasi, berubah menjadi pemanggilan `Ctx` yang sama persis — nol biaya saat berjalan.

```zig
fn getUser(db: *Db, id: u32) !User { ... }        // 90% kasus
fn download(ctx: *Ctx, id: u32) !void { ... }     // butuh kendali penuh
```

Layanan (database, konfigurasi, logger) ikut dicocokkan lewat mesin yang sama: didaftarkan sekali saat `App` dibuat, lalu diminta Handler berdasarkan tipenya. Mesin comptime-nya toh sudah harus membaca daftar argumen untuk membedakan path param dari body; membedakan Layanan hanyalah cabang tambahan di tempat yang sama.

Di Zig, "keajaiban" seperti ini gratis saat runtime — tidak ada reflection seperti Go, tidak ada mesin trait seperti Rust. Yang dibayar bukan kecepatan, melainkan **kualitas pesan error saat pengguna salah menulis signature**, dan itu harus ditangani manual dengan `@compileError` yang ditulis baik-baik.

## Consequences

- Handler menjadi fungsi biasa yang bisa diuji tanpa menyalakan server dan tanpa HTTP palsu, termasuk dengan Layanan tiruan. Tidak ada framework Zig lain yang bisa mengatakan ini, jadi ini bahan pemasaran utama — bukan efek samping.
- Jalur keluar untuk kasus yang tidak muat (streaming, unggahan besar, SSE) bukan tambalan: ia memang lapisan di bawahnya, tinggal minta `*Ctx`.
- Lapisan `Ctx` bisa selesai dan dirilis lebih dulu. Kalau mesin comptime ternyata mentok, sudah ada framework yang jalan dan bisa dipakai — itu jaring pengamannya.
- Middleware bekerja di lapisan `Ctx`, Handler di lapisan bertipe. Keduanya tidak bertabrakan dan tidak ada dua cara mengerjakan hal yang sama.
- Kalau ada dua Layanan bertipe sama (misalnya dua database), keduanya harus dibedakan dengan pembungkus bernama.
