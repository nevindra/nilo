# Rencana zfast

Dokumen kerja: lingkup v1, urutan pengerjaan, risiko, dan hal yang sengaja belum diputuskan.
Keputusan yang sudah mengikat ada di [`docs/adr/`](./adr/), kosakatanya di [`CONTEXT.md`](../CONTEXT.md).

## Posisi

Kiblatnya **GoFiber**: rasa Express, mesin kencang. Sasarannya orang Go/Node yang sedang mencoba Zig.

Perlu disadari sejak awal: GoFiber bukan juara performa di Go — yang cepat itu fasthttp di bawahnya. Fiber juara *kenyamanan*. Mengambil Fiber sebagai kiblat berarti yang dikejar adalah **"http.zig-nya orang Go"**, bukan mahkota benchmark. Lihat [ADR 0001](./adr/0001-dx-menang-dengan-ambang-10-persen.md).

## Lingkup v1

**Masuk**

- HTTP/1.1 lengkap: keep-alive, chunked
- Router: path param, query param
- Handler bertipe di atas lapisan `Ctx`
- JSON masuk dan keluar
- Rantai Middleware
- Empat Middleware bawaan: logger, CORS, recover, static file

**Ditolak sampai v2** — dan penolakan ini sama pentingnya dengan yang diterima

- Auth (mekanismenya disediakan, isinya tidak — persis seperti Fiber)
- WebSocket dan SSE. Koneksi berumur panjang punya model memori yang berbeda total dari request-response; Arena request tidak berlaku di sana, dan memaksakannya akan merusak desain yang sudah rapi.
- Template engine, session, TLS

## Dukungan versi Zig

Hanya rilis stabil terbaru, satu branch. Sasaran penggunanya mengunduh Zig, menjalankan `zig build`, dan menyerah kalau gagal — mereka tidak akan mencari branch yang benar. Konsekuensinya: setiap Zig rilis versi baru ada jendela beberapa minggu yang merepotkan, diperberat karena zio juga mengikuti pola branch per versi.

## Urutan pengerjaan

1. ~~**Rangka jalan.**~~ *Selesai.* Terima koneksi lewat zio, parse HTTP/1.1, kembalikan "hello". Belum ada framework. Tujuan satu-satunya: Sekat terbentuk dengan benar.
2. ~~**Lapisan `Ctx`.**~~ *Selesai.* Router, param, JSON, Arena request, `Str`. Di titik ini sudah terpakai, sudah bisa dibenchmark, dan sudah bisa dirilis kalau terpaksa.
3. ~~**Lapisan bertipe.**~~ *Selesai.* Mesin comptime, pencocokan Layanan per tipe, Fungsi gagal. Keputusan yang lahir di sini: [ADR 0006](./adr/0006-layanan-lewat-daftar-runtime.md) dan [ADR 0007](./adr/0007-kotak-gagal-terikat-fiber.md).
4. **Middleware dan empat bawaan.**
5. **Dokumentasi dan contoh.** Untuk sasaran pengguna ini, dokumentasi bukan pelengkap — ia produknya.

Skrip benchmark ditaruh di repo sejak tahap 1 meski belum dijalankan serius, supaya saat mesin Linux tersedia ia tinggal satu perintah, bukan proyek baru.

## Risiko

| Risiko | Penanganan |
|---|---|
| ~~Lapisan comptime adalah bagian tersulit dan paling rawan~~ *Lewat.* Lapisan bertipe jadi di tahap 3 tanpa perlu memakai jaring pengamannya | Lapisan `Ctx` di bawahnya bisa dirilis sendiri — itu jaring pengamannya, dan itu disengaja |
| zio adalah proyek satu orang; bisa berhenti saat Zig 0.17 keluar | Sekat, dipasang sejak tahap 1, bukan ditambal belakangan |
| Klaim "high performance" belum ada buktinya | Tidak ada angka di README sampai ada mesin Linux |
| Jaminan `Str` tidak bisa penuh | Jebakan build debug harus ada sejak hari pertama |
| `std.json` mungkin tidak cukup cepat, dan ia ada di jalur panas metrik yang dipilih | Kemungkinan besar perlu serializer sendiri untuk jalur JSON kecil; ukur dulu |
| Static file lebih dalam dari kelihatannya (range request, caching, sendfile) | Kerjakan paling akhir di v1, atau lempar ke v2 kalau mepet |

## Belum diputuskan

- **Nama.** `zfast` adalah nama kerja. Awalan `z-` di ekosistem Zig sudah sesak (`zap`, `zzz`, `zon`, belasan `zig-*`), jadi mudah tertukar. Nama modul harus gampang diganti tanpa mengubah kode pengguna.
- **Tempat mengukur.** Masih belum ada. Tahap 3 sempat dijalankan `wrk` di sebuah VM Linux bersama, tapi itu cuma untuk memastikan servernya tidak roboh dan tidak ada respons yang tertukar — mesin bersama tidak bisa dipakai membandingkan angka, jadi tidak ada angka yang disimpan dan tidak ada yang masuk README. Sampai ada mesin yang tenang, [ADR 0001](./adr/0001-dx-menang-dengan-ambang-10-persen.md) belum aktif dan semua konflik menang ke DX.
- **Algoritma router.** Tidak terlihat oleh pengguna, jadi tidak ada konflik DX di sini — murni pekerjaan, diputuskan dengan angka nanti.

## Metrik

Yang dianggap "cepat" untuk zfast:

- **Utama:** request per detik **dan p99** pada GET terute dengan path param yang mengembalikan JSON ~1KB, keep-alive, tanpa pipelining.
- **Sekunder:** memori per koneksi menganggur.

p99 ikut dihitung supaya tidak menang di throughput sambil menghambat request ekor. Konsekuensinya sudah mengikat sejak sekarang: keep-alive adalah jalur utama, dan tidak boleh ada alokasi yang menghentikan dunia di tengah request.
