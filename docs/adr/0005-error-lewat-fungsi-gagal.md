# Error HTTP dikirim lewat Fungsi gagal yang bisa dipanggil dari mana saja

Error di Zig tidak bisa membawa pesan — `error.NotFound` hanyalah sebuah nama. Tidak ada `error.NotFound{"user 7 tidak ada"}`. Jadi "bagaimana cara mengembalikan 404 dengan pesan yang jelas" bukan pertanyaan gaya, melainkan masalah teknis yang harus dipecahkan.

Jalan yang biasa ditempuh — ambil pesan lewat objek konteks — akan meruntuhkan Handler bertipe: kalau untuk mengembalikan 404 pengguna wajib memegang `*Ctx`, maka hampir semua handler nyata akan memegang `*Ctx`, dan bentuk yang rapi itu hanya terpakai di contoh README.

Karena itu ada **Fungsi gagal**: fungsi bebas yang menyimpan pesan ke Arena request yang sedang berjalan lalu mengembalikan error.

```zig
fn getUser(db: *Db, id: u32) !User {
    return db.find(id) orelse http.notFound("user {d} tidak ditemukan", .{id});
}
```

Error Zig biasa yang datang dari mana pun (database, parsing, alokasi) tetap dilayani: dipetakan lewat tabel, dan yang tidak dikenali menjadi 500 sambil dicatat dengan nama errornya.

## Consequences

- Ada state per-request tersembunyi. Ini bisa diterima karena Mesin memang sudah tahu request mana yang sedang berjalan, sehingga biayanya nyaris nol — tapi ia tetap state tersembunyi, dan itu harus disebut apa adanya di dokumentasi.
- Dipanggil di luar request (misalnya di dalam unit test handler), Fungsi gagal hanya mengembalikan error biasa tanpa pesan. Handler tetap bisa diuji sebagai fungsi biasa.
