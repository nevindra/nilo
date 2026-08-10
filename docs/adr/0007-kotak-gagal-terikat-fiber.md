# Kotak Fungsi gagal terikat ke fiber, bukan ke utas

ADR 0005 memutuskan Fungsi gagal menyimpan pesannya ke "request yang sedang berjalan". Waktu itu tidak disebut bagaimana ia tahu request mana yang sedang berjalan. Ternyata itu bagian yang paling mudah salah.

Jawaban refleks adalah `threadlocal`. Di zfast jawaban itu **salah**, dan salahnya berbahaya. Mesin menjalankan tiap koneksi di fiber, dan banyak fiber berbagi satu utas OS. Urutan ini bisa terjadi kapan saja:

1. Fiber A masuk handler. Slot utas menunjuk ke Kotak A.
2. Handler A menunggu query database, jadi A tidur.
3. Fiber B jalan di utas yang sama. Slot utas sekarang menunjuk ke Kotak B.
4. A bangun, memanggil `gagal.notFound("saldo user 7 kurang")` — dan menulisnya ke Kotak B.
5. Pengguna B menerima 404 berisi pesan tentang user 7.

Itu bukan bug yang jarang, itu kebocoran data antar-pengguna, dan ia baru muncul saat ada beban — persis saat paling mahal.

Karena itu Kotak diikat ke **fiber**, lewat `zio.TaskLocal`: nilainya melekat pada fiber-nya, ikut pindah kalau fiber-nya berpindah utas, dan tidak terlihat oleh fiber lain. Yang bisa dicapai `gagal()` selalu Kotak milik request yang benar-benar sedang ia layani.

Karena hanya `src/mesin/` yang boleh menyebut zio (ADR 0002), ini masuk kontrak Sekat sebagai satu penunjuk yang terikat ke unit kerja yang sedang berjalan — `ikatSlot`/`lepasSlot`/`slot`. Mesin lain yang memakai utas biasa, bukan fiber, memenuhi kontrak yang sama dengan `threadlocal`.

Di luar Mesin tidak ada fiber sama sekali — unit test memanggil `App` langsung dengan buffer di memori. Untuk itu Sekat punya cadangan threadlocal yang dipakai hanya kalau slot fiber kosong. Di server sungguhan slot fiber selalu ada dan selalu menang, jadi cadangan itu tidak pernah terbaca.

Satu penyimpangan kecil dari ADR 0005: pesannya tidak disimpan ke Arena request melainkan ke buffer tetap di dalam Kotak. Jalur gagal tidak boleh punya jalur gagal sendiri — kehabisan memori saat hendak melaporkan sebuah error adalah tempat terakhir yang mau dipikirkan siapa pun. Konsekuensinya pesan dibatasi 240 byte dan yang lebih panjang dipotong.

## Consequences

- Fungsi gagal aman dipanggil dari handler yang tertidur di tengah jalan — yaitu hampir semua handler yang menyentuh jaringan atau database.
- Satu Kotak per koneksi, bukan per request: ia dipakai ulang dan dikosongkan di awal tiap request. Pesan dari request sebelumnya tidak bisa ikut terbawa.
- Sekat bertambah satu kewajiban. Mengganti Mesin sekarang berarti menyediakan penyimpanan per-unit-kerja juga, bukan cuma soket. Ini biaya yang sadar dibayar: alternatifnya adalah mewajibkan Handler memegang `*Ctx`, yang justru meruntuhkan seluruh lapisan bertipe.
- Diuji di bawah beban campuran 200 dan 404 dengan 64 koneksi bersamaan: tidak ada satu pun pesan yang tertukar dari ~400 ribu request. Tes ini bukan bagian dari `zig build test` karena butuh server yang menyala; ia dijalankan tangan lewat skrip di `bench/`.
