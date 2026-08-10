# Layanan dicocokkan lewat daftar runtime, dicek saat startup

Handler bertipe meminta Layanan lewat tipe argumennya (ADR 0003). Pertanyaannya: di mana daftar Layanan itu hidup?

Cara yang paling Zig adalah membuat `App` generik atas kumpulan tipe Layanan, sehingga Layanan yang belum didaftarkan berhenti saat kompilasi:

```zig
var app = zfast.App(.{ *Db, *Konfigurasi }).init(gpa, .{ &db, &cfg });
```

Itu ditolak. Sasaran penggunanya orang Go dan Node, yang di sana cuma menulis `app := fiber.New()`. Menyuruh mereka menyebut tipe Layanan dua kali — sekali di parameter `App`, sekali saat mengisinya — dan membuat `App` jadi tipe yang berbeda-beda tergantung isinya adalah harga DX yang besar untuk satu kelas kesalahan yang jarang. Dokumentasinya pun jadi ikut bercabang.

Jadi daftarnya **runtime**, kuncinya nama tipe dari `@typeName`:

```zig
var app = zfast.App.init(gpa);
try app.daftarkan(&db);
try app.get("/users/:id", getUser);   // getUser minta *Db
```

Yang hilang dari cara ini — pengecekan saat kompilasi — dikembalikan dengan cara lain. Mesin comptime sudah membaca daftar argumen tiap handler, jadi ia sekalian mengumpulkan Layanan apa saja yang diminta, lengkap dengan rutenya. `dengarkan()` memeriksa daftar itu sebelum socket dibuka:

```
error: handler rute "/users/:id" minta Layanan *main.Db yang belum
didaftarkan — panggil app.daftarkan() sebelum app.dengarkan()
```

Salah tipe tetap ketahuan, hanya beberapa milidetik lebih lambat: saat proses menyala, bukan saat request pertama yang kebetulan lewat rute itu jam tiga pagi.

## Consequences

- Urutan pendaftaran bebas. Layanan boleh didaftarkan sebelum atau sesudah rute, asal semuanya selesai sebelum `dengarkan()`.
- Mengambil Layanan berarti pemindaian linear atas daftar yang isinya beberapa entri, membandingkan penunjuk nama tipe. Biayanya beberapa nanodetik di request yang memang memakai Layanan — jauh di bawah ambang 10% di ADR 0001, dan bisa diganti dengan indeks yang dihitung saat kompilasi kalau pengukuran nanti berkata lain, tanpa mengubah kode pengguna.
- Dua Layanan bertipe sama ditolak saat didaftarkan, bukan diam-diam menimpa. Membedakannya tetap dengan pembungkus bernama, seperti kata ADR 0003.
- Layanan yang didaftarkan sebagai `*const` dan diminta sebagai `*` ikut tertangkap `dengarkan()`, bukan jadi penunjuk const yang diubah diam-diam.
- Tes tidak perlu menyalakan server untuk memeriksa perakitan: `app.layananKurang()` mengembalikan kebutuhan pertama yang belum terpenuhi sebagai data biasa.
