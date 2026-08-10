# DX menang atas performa, dengan ambang 10%

zfast dijual sebagai framework HTTP cepat, jadi pembaca kode nanti akan wajar menyangka setiap keputusan dimenangkan oleh angka benchmark. Yang sebenarnya diputuskan justru kebalikannya: **kenyamanan menulis kode menang, kecuali biayanya di atas 10%.** Angka performa dipakai untuk menarik perhatian; kenyamanan dipakai untuk menahan orang.

Alasannya ada di sasaran penggunanya. Orang yang datang dari Go atau Node sekarang hidup di 30–80 ribu request per detik; framework Zig yang sudah ada memberi mereka 140 ribu. Selisih 40% di lapisan HTTP tidak akan mereka rasakan — hilang ditelan query database pertama. Yang mereka rasakan adalah apakah bisa jalan dalam 10 menit, apakah pesan errornya terbaca, dan apakah mereka harus memikirkan allocator.

## Consequences

- Sebagian besar konflik ternyata jauh di bawah ambang, karena bagian yang membuat server cepat (strategi event loop, kolam buffer, pembagian thread) tidak terlihat sama sekali oleh pengguna. Itu bukan konflik — itu hanya pekerjaan.
- Aturan ini belum aktif sampai ada mesin Linux untuk mengukur. Sampai saat itu semua konflik menang ke DX secara otomatis, karena tidak ada bukti yang bisa mengalahkannya. Ini bisa diterima karena keputusan yang sedang diambil semuanya soal bentuk API, dan bentuk API tidak butuh benchmark.
- Selama belum ada angka dari mesin sungguhan, README tidak boleh memuat klaim performa. Klaim tanpa angka adalah cara tercepat proyek ini dirobek di publik.
