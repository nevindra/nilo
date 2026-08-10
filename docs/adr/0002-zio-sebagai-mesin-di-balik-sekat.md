# zio dipakai sebagai Mesin, ditaruh di balik Sekat

Untuk mengejar performa, jalan yang paling menggoda adalah menulis event loop sendiri di atas io_uring — itu yang dilakukan zzz lewat tardy. Kami tidak menempuh itu. zfast berdiri di atas [zio](https://github.com/lalinsky/zio), implementasi `std.Io` pihak ketiga yang sudah menyediakan io_uring/epoll di Linux, kqueue di macOS, dan IOCP di Windows, di atas fiber.

Alasannya: Mesin adalah bagian dengan risiko tertinggi dan pembeda terendah. Tidak ada yang memilih framework karena event loop-nya bagus — mereka memilih karena menulis handler-nya enak. Menulis Mesin sendiri berarti berbulan-bulan tanpa satu baris pun kode framework, di platform yang tidak dimiliki (io_uring hanya ada di Linux, pengembangan berjalan di macOS).

## Considered Options

- **`std.Io` bawaan Zig, langsung.** Ditolak setelah membaca `Io.VTable`: sisi jaringannya (`netAccept`, `netSend`, `netReceive`, `netRead`, `netWrite`) tidak punya *registered buffer*, tidak punya *multishot*, dan tidak punya tulis vektor. Tanpa tulis vektor, setiap response (header + body) berarti satu salinan tambahan atau satu syscall tambahan — di setiap request, selamanya. Implementasi `Io.Evented` yang cepat juga masih berstatus proof-of-concept.
- **Menulis runtime io_uring sendiri.** Plafon tertinggi, tapi lingkupnya terbesar dan tidak bisa diuji di mesin pengembangan.

## Consequences

- Semua kebutuhan zfast terhadap Mesin lewat Sekat: terima koneksi, baca, tulis, tutup. Tidak ada satu pun bagian zfast di luar Sekat yang menyebut zio.
- Sekat harus terbentuk di tahap paling awal, bukan ditambal belakangan. Ia satu-satunya asuransi terhadap dua risiko: zio berhenti dirawat, dan plafon performa zio ternyata kurang.
- Mengganti Mesin nanti tidak boleh mengubah satu baris pun kode pengguna.
