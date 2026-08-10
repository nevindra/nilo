# Data request pakai Arena request, dibungkus tipe Str

Setiap request punya Arena request: satu kantong memori yang dibuang sekaligus saat request selesai. Pengguna tidak pernah memegang allocator dan tidak pernah memanggil `deinit`. Cepat, dan tidak ada ritual di kode pengguna.

Konsekuensi berbahayanya: semua data request mati saat handler selesai. Pengguna yang datang dari Go atau Node belum pernah men-debug *use-after-free* — di kedua bahasa itu, menyimpan string dari request adalah hal yang mustahil salah. Di Zig tidak ada yang mencegahnya, dan crash-nya muncul acak berjam-jam kemudian di produksi.

Ini persis cacat paling terkenal dari GoFiber, yang mewarisinya dari fasthttp: aturan "jangan simpan apa pun dari `c` setelah handler selesai". Memperbaiki ini adalah salah satu alasan zfast layak ada.

Karena itu data request bukan `[]const u8` telanjang, melainkan **Str**:

1. Isinya tidak bisa diambil tanpa memanggil sesuatu — tidak ada jalan untuk "tidak sengaja" menyimpannya.
2. `.keep()` menyalin ke memori berumur panjang, satu fungsi dengan nama yang jelas.
3. Build debug menyematkan penanda umur; memakai Str dari request yang sudah selesai langsung berhenti keras dengan pesan yang menyebut `.keep()`. Build rilis membuang penanda ini, nol biaya.

## Consequences

- Jaminannya **tidak** bisa penuh. Zig tidak punya sistem kepemilikan; tidak ada cara membuat tipe yang ditolak compiler kalau disimpan. Yang dibangun adalah bentuk API yang membuat kesalahan terlihat, ditambah jebakan yang meledak di laptop alih-alih di produksi.
- Karena itu jebakan build debug bukan pelengkap — ia satu-satunya yang benar-benar menangkap, dan harus ada sejak hari pertama.
- Penggunaan memori naik seiring jumlah request yang sedang berjalan, bukan jumlah koneksi. Ini bisa diterima karena metrik yang dikejar adalah throughput dan p99, bukan kepadatan koneksi.
