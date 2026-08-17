# nilo_s3 — PRD

**Status:** desain selesai, kode belum ditulis satu baris pun.
**Tanggal:** 17 Agustus 2026.
**Kalau lo balik ke sini dingin:** baca §1, terus §12 (yang masih terbuka), terus §14 (urutan kerja). Sisanya referensi.

---

## 1. Ringkasan

Client object storage buat nilo. Bucket jadi tipe, key jadi string, dan objek gede
lewat presigned URL — bukan lewat server lo.

| | |
|---|---|
| Keputusan kunci | **25** |
| Masih terbuka | **0** |
| Angka harus diukur | **6** (4 sebelum kode, 2 sesudah) |
| Dependency baru | **0** — cuma `std` |
| ADR ditulis | 0065, 0067, 0068, 0069 |
| ADR belum | 0070 (layer keempat), amandemen 0067 |
| Baris kode | **0** |

Kerjaan biasa yang bikin modul ini ada: **user upload file, server naro ke S3,
dan nyajiin balik.** Bukan bikin SDK AWS, bukan bikin file manager.

---

## 2. Dua premis di roadmap yang ternyata salah

Desain ini mulai dari ngecek yang ditulis di `docs/roadmap.md`. Dua-duanya nggak bener.

### 2.1 "A Service has no supported way to dial out" — salah

Roadmap bilang `nilo_sql` nembus jaringan lewat zio-nya pg.zig.

- `pg/build.zig.zon` **nggak punya zio sama sekali** — cuma `buffer`, `metrics`, `xsync`, `tls`.
- `pg/src/stream.zig` pakai `std.Io.net.Stream`, `std.Io.net.HostName`, `std.Io.net.UnixAddress`.
- `std.Io` itu **udah** diserahin ke Service lewat `ready(state, io)` sejak ADR 0040,
  dan `http/service.zig:61` nge-erase hook-nya jadi `*const fn (*anyopaque, std.Io) anyerror!void`.
- zio ngisi slot `netConnectIp` di vtable `std.Io`-nya (`zio/src/io.zig:243`).

**Jalan keluarnya udah kebuka bertahun-tahun.** Gap-nya kecatat dari ujung yang salah.

### 2.2 Yang beneran nggak ada: cara *ngerem*

- `std.Io.net.Stream.Reader` **nggak punya** timeout per-baca. Cuma `Socket.receiveTimeout`
  (datagram) dan timeout connect di `HostName.connectMany`.
- `std.http.Client` nggak punya slot deadline sama sekali.
- Tapi **cancel-nya nyampe**: semua operasi `std.Io.net` bawa `Io.Cancelable`, dan
  `std/http/Client.zig:8` nulis *"`error.Canceled` added to more error sets"*.

Jadi deadline di sini beneran bisa dipaksain, bukan hiasan — dia lolos ujian ADR 0047.

> Ini klaim ketiga yang dipublikasi tanpa run di belakangnya, setelah `connect_on_init`
> (ADR 0062) dan "8.767 byte, flat" (ADR 0063). Yang pertama ketauan dari baca
> `build.zig.zon` orang lain, bukan dari ngukur.

**Sudah dikoreksi** oleh sesi lain di `docs/roadmap.md` — tiga paragraf: known gaps
`nilo_core`, section "Modules that do not exist yet", dan entri "Not decided — where
`convert` belongs".

---

## 3. Keputusan: mekanika

### 3.1 Client penuh, layer Service

Bukan presign-only. Duduk sejajar `nilo_sql`.

Ditolak: modul tool presign-only di layer bawah (lebih murah, tapi nggak nyelesaiin
kerjaannya), dan "presign dulu tapi didaftarin sebagai Service" (kehilangan properti
`zig test` standalone tanpa dapet apa-apa).

### 3.2 TLS dari `std.crypto.tls.Client`

Buffer-nya nyaris identik sama alternatifnya:

| | buffer per koneksi TLS |
|---|---|
| `std.crypto.tls.Client` | `min_buffer_len` 16.645 × 2 = **33.290 B** |
| ianic `tls.zig` | 16.645 + 16.469 = **33.114 B** |

Selisih 176 byte — memory nggak mutusin apa-apa.

**Yang bikin std menang:** `Options`-nya minta persis dua hal yang nilo udah putusin
cara nyediainnya — `entropy` (ADR 0046) dan `realtime_now` (ADR 0045) — dan nggak minta
allocator buat buffer-nya. `ca: .self_signed` nutup kasus dev server bersertifikat sendiri.

**Yang matiin ianic:** pg.zig nge-pin dia di commit `5452bafc`. Zig nge-dedupe package
by **hash**, jadi program yang pake `nilo_sql` + `nilo_s3` dengan pin beda bakal
compile **dua salinan TLS dalam satu binary**. Ngindarinnya berarti ngunci jadwal
upgrade nilo ke jadwal orang lain selamanya. Plus ADR 0028 udah restuin jalur std:
*"that is how `zig fetch` reaches an HTTPS URL"*.

Kekurangan std yang diterima: kurang battle-tested, nggak ada pilihan cipher suite,
nggak ada mTLS. Kalau ada endpoint yang nggak mau handshake, ketauan di test integrasi
hari pertama.

### 3.3 HTTP dari `std.http.Client` — nol baris kode non-S3

Ini diukur, bukan ditebak. `http/http1.zig` = 1.068 baris (686 kode + 382 test, 28 test).

| bagian | baris | kepake client? |
|---|---|---|
| `readHead`, `findEndOfHead`, `HeaderIterator`, `takeLine`, codec chunked | **165** | ya |
| `Method`, `Request`, `parseHead` + 3 helper + dispatch | 140 | nggak — ini parser **request line**; client butuh **status line** |
| `isReservedHeader`, `repeats` | 20 | nggak — policy nulis response |
| `statusText`, `bodyless`, `writeResponse`, `staticResponse`, `writeResponseHeadOnly` | 225 | nggak |

**165 dari 686 = 24%.**

Dan bagian yang dioptimasi ada di `scan.zig`, yang angkanya (183ns → 51ns nyari ujung
head, 303ns → 163ns parsing) itu soal **masalah server**: client jahat nyicil head 8 KB
byte per byte, ribuan head 121-byte per detik. Client S3 baca **satu** response head
~300–500 byte per panggilan, di atas round trip 5–50 ms. Hemat 130 ns di operasi 20 ms
= **0,0007%**. ADR 0001 masang batas di 10%.

Yang nggak kebantu reuse sama sekali:

| | tulis sendiri di `s3/` | modul `nilo_http1` bersama | `std.http.Client` |
|---|---|---|---|
| framing HTTP | ~165 | pinjem | 0 |
| parse status line | ~20 | ~20 | 0 |
| plumbing TLS | **~380** (cf. `pg/src/stream.zig`) | ~380 | 0 |
| connection pool | **~250** | ~250 | 0 |
| **total non-S3** | **~815** | **~650** | **0** |

Framing itu seperlima kerjaan. Empat perlima sisanya — di mana bug dan memory tinggal —
nggak dibantu berbagi apa pun.

**Tiga hal yang dicek sebelum ini dipilih**, karena satu aja gagal berarti opsi ini mati:

1. **SigV4 butuh request ditulis tepat-byte.** Semua header default di
   `std/http/Client.zig` overridable — `host`, `authorization`, `user-agent`,
   `connection`, `accept-encoding`, `content-type` — dan `extra_headers` ditulis
   verbatim, berurutan. ✅
2. **Handler nggak boleh blokir thread (ADR 0014).** Pool-nya pake `Io.Mutex`,
   bukan `std.Thread.Mutex`. Di zio itu markir fiber. ✅
3. **Satu alokasi per koneksi.** Semua empat buffer di-slice dari satu `alignedAlloc`. ✅

Ditolak juga: modul `nilo_http1` bersama di layer bawah — dia maksa tanda tangan
`readHead` kebuka (dia nerima `bulkhead.Deadlines` dan ngarm jam header **sekali**, pas
byte pertama, dan alasannya ketulis di doc comment-nya).

### 3.4 Bulkhead tumbuh primitif deadline → **ADR 0065**

`core.Limits` — struct + vtable di `nilo_core`. Nol IO, nol alokasi, nol engine.
Implementasinya `zio.AutoCancel` (`zio/src/zio.zig:27`, publik, stack-allocated,
bisa bertingkat, punya flag `triggered` buat bedain timeout dari cancel beneran),
dan cuma `http/engine/zio.zig` yang nyebut.

```zig
pub fn nilo_start(self: *Self, io: std.Io, limits: core.Limits) !void { ... }

var bound = self.limits.arm(2_000);
defer bound.release();
// ... operasi ...
if (bound.fired()) return error.TimedOut;
```

**`nilo_start` nerima dua arity.** `startHook` di `http/service.zig:61` udah baca
`@hasDecl`; dia juga baca jumlah parameter. Hook dua-parameter di-erase ke bentuk lama,
tiga-parameter ke bentuk baru. **`sql/db.zig` compile tanpa disentuh**, dan Service
siapa pun di luar repo nggak pecah.

`Bound` nyimpen state engine di slot opaque berukuran tetap, jadi arming nol alokasi.
Core nggak bisa tau `@sizeOf(zio.AutoCancel)`, jadi core deklarasiin slot-nya dan
`bulkhead.zig` nahan `comptime` check yang nolak engine yang nggak muat.

Ditolak: `io.async` + `future.cancel` murni std (harganya satu fiber plus stack-nya per
operasi yang lagi jalan — `zio/src/io.zig:283` `asyncImpl` nyampe `spawnTask` lewat
`concurrentImpl`; ADR 0063 baru aja netapin fiber nahan stack di titik tertingginya,
dari slab 64 stack); ngelebarin `nilo_start` buat semua orang (`!` di commit, mecahin
Service orang); marker kedua `nilo_limits` (dua hook yang selalu dipanggil barengan =
satu bisa kelupaan, dan itu diam).

### 3.5 Gerbang `max_in_flight` pakai `std.Io.Semaphore`

Pool `std.http.Client` **nggak mbatesin koneksi yang lagi kepake**:

```zig
pub const ConnectionPool = struct {
    used: std.DoublyLinkedList = .{},   // ← nggak ada batasnya
    free: std.DoublyLinkedList = .{},
    free_len: usize = 0,
    free_size: usize = 32,              // ← cuma yang NGANGGUR
};
```

500 handler barengan = 500 koneksi TLS = **29,6 MB** + 500 handshake, dan AWS mulai
throttling jauh sebelum itu. Default `free_size = 32` doang udah **1.892.832 B** nganggur.

`std.Io.Semaphore` (`std/Io/Semaphore.zig`) murni std, pake `Io.Mutex` + `Io.Condition`
(markir fiber di zio), dan `wait` balikin `Io.Cancelable!void` — jadi caller yang
dibatesin ADR 0065 keluar dari antrian pas jamnya habis.

**Ceiling = `max_in_flight × 59.151 B`, dan angka itu ditulis di dokumen.**

---

## 4. Keputusan: bentuk

### 4.1 Bucket adalah tipe, key bukan — **ADR 0068**

Pola ADR 0060: database kedua itu tipe kedua, jadi dua pool itu dua Service, dan mana
yang dipake ketulis di argument list handler. Bucket bentuknya sama persis.

```zig
const Avatars  = s3.Bucket("avatars",  .{ .max_bytes = 5 << 20, .sse = .aes256 });
const Invoices = s3.Bucket("invoices", .{ .max_bytes = 20 << 20, .style = .path });

var store   = try s3.open(io, gpa, .{
    .endpoint    = cfg.s3_endpoint,
    .region      = cfg.s3_region,
    .credentials = .{ .static = cfg.aws },
});
var avatars = try Avatars.open(&store);   // host + credential scope dibangun SEKALI di sini
try app.provide(&avatars);                // registry type-keyed ADR 0006, nol tambahan

fn getAvatar(id: Uuid, avatars: *Avatars, c: *nilo.Ctx) !s3.Object {
    return avatars.get(c, try key(c, id));
}
```

**Comptime vs runtime:**

| comptime, di tipe | runtime, di client |
|---|---|
| nama bucket | endpoint |
| gaya alamat (`virtual` / `path`) | region |
| `max_bytes` | kredensial |
| `sse` | `max_in_flight`, ambang drain |
| `presign_max` | |

Endpoint dan region runtime karena datengnya dari environment — `nilo_config` ada
supaya dev dan prod itu satu binary (ADR 0043).

**Yang dibeli comptime bukan kecepatan.** Kemenangan aslinya "nggak format host per
request", dan itu tetep dapet dari `Avatars.open(&store)` yang bangun host sekali.
Yang cuma bisa dibeli comptime itu:

**Refusals** — file di `refusals/` + baris di tabel kelima `s3_refusals` (ADR 0027):

- nama bucket yang virtual-host addressing nggak bisa bawa — bukan 3–63 karakter,
  bukan huruf kecil, ada underscore, bentuknya kayak IP
- **secret di opsi comptime**: `s3.Bucket("avatars", .{ .secret_access_key = "wJalr…" })`
  itu secret yang ke-compile ke binary, dan harus nggak bisa ditulis
- `presign_max` di atas 7 hari (SigV4 nolak di 604.800 detik)
- `max_bytes` nol

**`SignedHeaders` jadi konstanta** — ini yang nentuin permukaan API, bukan sekadar hiasan.
SigV4 nandatanganin daftar nama header yang diurut dan ngirim daftarnya di signature.
Kalau himpunan header-nya tetap pas compile, daftarnya **konstanta** dan penandatanganan
nggak nyortir apa-apa per request.

Himpunan tetapnya: `content-type`, `content-disposition`, `cache-control`, `host`,
`x-amz-date`, `x-amz-content-sha256`, plus `x-amz-server-side-encryption` kalau
bucket-nya minta.

**Key bukan tipe, dan itu sengaja.** Template key comptime
(`s3.Key(struct { user: Uuid, size: Size })` → `users/{uuid}/{size}.png`) itu ide paling
keliatan-nilo di seluruh desain ini, dan ditolak: itu DSL template, dan README nolak
template dengan alasan yang sama persis. Key itu string yang aplikasi yang mutusin;
tugas nilo cuma nge-encode dengan bener, sekali, per RFC 3986 dengan `/` dibiarin
(ADR 0066).

### 4.2 Object keluar, put dicek bentuknya comptime

```zig
pub const Object = struct { bytes: Str, content_type: Str, etag: Str, len: u64 };
```

`bytes` itu `Str` walaupun objek biasanya bukan teks — dan itu bukan dipaksain.
`http/form.zig:65` udah nulis soal `Upload.bytes`: *"doing lifetime duty rather than
claiming the contents are text"*.

`put` nerima **apa pun yang punya `.bytes` dan `.content_type`**, dicek pas compile,
pola `core/scope.zig` (*"a shape checked while compiling, not an interface with a
function table"*). Jadi kerjaan biasa nyambung tanpa upacara, dan tanpa `s3/` nyebut
`nilo_http` yang emang dilarang layering:

```zig
fn save(form: Form(NewAvatar), avatars: *Avatars, c: *nilo.Ctx) !Redirect(303) {
    try avatars.put(c, key, form.value.image);   // nilo.Upload, langsung masuk
    return .to("/me");
}
```

### 4.3 Bounded dan streaming, dua arah — dan panjang wajib di streamed put

Streamed `get` mipe body S3 ke response writer, nol alokasi.

**Streamed `put` nerima panjang sebagai argumen biasa**: `put(scope, key, len, reader)`.
Karena S3 selalu butuh ukuran di depan:

- `Content-Length` biasa + `x-amz-content-sha256: UNSIGNED-PAYLOAD`, atau
- SigV4 streaming (`aws-chunked` / `STREAMING-UNSIGNED-PAYLOAD-TRAILER`) — tapi lo tetep
  harus **pre-compute total panjang payload termasuk metadata tiap chunk** dan kirim
  `x-amz-decoded-content-length`

Dan layanan S3-compatible banyak yang belum dukung format kedua, langsung balikin
`MissingContentLength` — SeaweedFS, Apache Ozone, gateway Storj.

**Upload ukuran-nggak-diketahui cuma bisa lewat multipart upload**, yang ditolak v1.
Naro panjang di tanda tangan bikin "gue nggak tau ukurannya" jadi **error compile**,
bukan 411 dari AWS pas produksi.

Konsekuensi yang harus disadari: kasus paling umum — *user POST form multipart, server
nerusin ke S3* — panjang per-part nggak ketauan sampai ketemu boundary. Jadi form upload
nggak bisa di-stream ke S3; dia dibaca utuh dulu, yang emang udah gitu hari ini
(roadmap baris 351).

### 4.4 Range GET

Nambal lubang di 4.3: tanpa range, objek 500 MB cuma bisa di-stream. Dengan range,
`get` yang bounded bisa narik byte 0–1 MB dari objek raksasa ke arena.

Satu header keluar, satu header masuk, nol alokasi, nol mesin baru. Vokabulernya udah
diputusin ADR 0021. `s3` punya struct `Range { start, end }` sendiri — duck typing itu
jatah `Upload` yang tiga field, bukan buat dua angka.

### 4.5 `getIf` balikin tagged union

`Object` bawa `ETag`, dan ETag yang caller nggak bisa pake itu setengah fitur — argumen
yang ADR 0047 pake buat `TimedOut`. Dan **304 itu sukses**, jadi dia nggak boleh jadi
error (ADR 0024):

```zig
switch (try avatars.getIf(c, key, .{ .none_match = tag })) {
    .unmodified => …,
    .object => |o| …,
}
```

Compiler bikin cabang kedua nggak bisa kelupaan; nilai balik nullable nggak.

### 4.6 `Presigned { url: Str, expires_at }`

Presign **nggak nyentuh socket sama sekali** — cuma HMAC dan hex. Nggak butuh loop,
nggak butuh izin gerbang.

Tapi URL yang ditandatangani pakai kredensial sementara **mati barengan kredensialnya**,
bukan pas `X-Amz-Expires` bilang. Minta 7 hari dengan token IRSA sisa 6 jam, dapetnya
6 jam — dan nggak ada apa pun di program yang bisa ngasih tau.

Jadi umurnya dipotong ke `min(diminta, sisa umur kredensial)` dan **dikembalikan**.
Caller yang nyimpen URL ke database atau ngirim lewat email punya angka yang bener.

### 4.7 S3-compatible, endpoint runtime, gaya alamat comptime

virtual-host jadi default, path-style opt-in sebagai opsi comptime di `Bucket` — jadi
pembangun URL-nya kepilih pas compile, bukan `if` per request.

Ini yang bikin SeaweedFS di docker-compose jadi mungkin, ngikutin pola `sql/` yang udah
ada. Kalau nilo_s3 cuma bisa ngomong ke AWS, `zig build test-s3` artinya nembak AWS
beneran pakai kartu kredit — dan ADR 0033 bilang penjaga baru jadi penjaga kalau udah
**keliatan gagal**.

---

## 5. Keputusan: kredensial dan penandatanganan — **ADR 0069**

### 5.1 Belahannya: nilo pegang cache, program pegang cara ngambil

Yang bikin DX kredensial jelek itu bukan **ngambilnya** — tapi nge-cache-nya, ngecek
kedaluwarsanya, dan ngamanin dari beberapa thread. Itu bagian yang generik dan susah.
Ngambilnya justru gampang dan beda-beda per deployment.

```zig
// 90% orang. Satu baris.
var store = try s3.open(io, gpa, .{
    .credentials = .{ .static = .{
        .access_key_id     = cfg.aws_access_key_id,
        .secret_access_key = cfg.aws_secret_access_key,
    } },
});

// Yang di EKS/EC2. Cuma nulis cara ngambil — nggak ada cache, lock, atau logika kedaluwarsa.
fn fromIrsa(gpa: Allocator, io: std.Io) !s3.Credentials {
    return .{ .access_key_id = …, .secret_access_key = …,
              .session_token = …, .expires_at = … };
}
var store = try s3.open(io, gpa, .{ .credentials = .{ .fetch = &fromIrsa } });
```

`fetch` dipanggil sekali pas `open()`, terus lagi pas udah deket `expires_at`.
**Malas, bukan tugas latar belakang** — ADR 0060 nolak tugas latar belakang, dan ini
nggak butuh satu pun. Request yang kebetulan lewat pas hampir kedaluwarsa yang bayar;
yang lain tetep pake kunci lama yang masih sah, karena marginnya bikin refresh-nya awal.

`.static` itu mekanisme yang sama dengan `expires_at` null.

### 5.2 Yang di-cache itu kunci turunan, bukan kredensial

```
kDate    = HMAC("AWS4" + secret, "20260817")
kRegion  = HMAC(kDate,   region)
kService = HMAC(kRegion, "s3")
kSigning = HMAC(kService,"aws4_request")
```

Region dan service udah settled di `open()`; tanggal berubah sekali sehari.
**Jadi kunci turunannya berubah sekali sehari**, dan penandatanganan setelah itu cuma
**1 HMAC** buat string-to-sign, bukan 5.

**Hemat 4 HMAC-SHA256 per request**, di tiap panggilan S3 yang proses itu bikin.

Cache-nya dikunci sama tanggal + counter generasi yang di-bump sama fetch. Jalur cepat
baca di bawah shared `std.Io.RwLock`; refresh ambil eksklusif, sekali per 6 jam atau
sekali sehari.

**Jangan pinter-pinter soal lock itu.** Seqlock atau generation-and-copy bakal ngilangin
`tryLock` pair yang nggak rebutan — sekitar 30 ns — dari operasi yang lantainya round
trip jaringan 5–50 ms. Itu **0,00015%**, dan ADR 0001 masang batas di 10%.

### 5.3 Payload hash: `UNSIGNED-PAYLOAD` di HTTPS, hash asli di HTTP polos

| | SHA-256 10 MB | SHA-256 100 MB |
|---|---|---|
| dengan SHA-NI (~2 GB/s) | ~5 ms | ~50 ms |
| tanpa (~500 MB/s) | ~20 ms | ~200 ms |

Itu CPU murni **di atas fiber**, dan ADR 0014 soal persis ini. 200 ms itu deket
`block_warning_ms` default 250 tanpa nyebrang — bentuk yang ADR 0048 temuin dengan cara
susah, di mana argon2 ternyata 13 ms bukan 100 dan detektornya jadi nggak pernah nyala.

Keputusannya jatuh dari skema endpoint, nggak ada yang perlu diatur. Di atas TLS,
hash-nya beli integritas yang TLS udah kasih; di atas plaintext — SeaweedFS dev, yang
endpoint runtime bikin mungkin — itu satu-satunya integritas yang ada, dan jalur itu
nggak pernah kena beban produksi.

Streamed `put` selalu `UNSIGNED-PAYLOAD` — nge-hash yang belum dibaca artinya baca dua kali.

---

## 6. Keputusan: kegagalan dan koneksi

### 6.1 Error set

Ngikutin `sql/wire.zig`: daftar pendek, tiap anggota dapet tempat karena handler bakal
ngelakuin hal berbeda, dan **default 500 kecuali dinyatakan lain**.

```zig
pub const Error = error{
    /// S3 bilang barangnya nggak ada (NoSuchKey, NoSuchBucket).
    /// SATU-SATUNYA yang bawa default: 404.
    NotFound,
    /// Lebih gede dari max_bytes punya Bucket. Penolakan nilo sendiri, kebaca dari
    /// Content-Length sebelum satu byte pun dibaca. Tanpa default: handler yang
    /// milih angkanya.
    TooLarge,
    /// S3 lagi nolak beban (503 SlowDown, 429). Tanpa default.
    Throttled,
    /// S3 jawab 5xx, atau koneksinya putus.
    Unavailable,
    /// Deadline yang dipasang caller kelewat. Tanpa default, alasannya sama persis
    /// kayak TimedOut punya sql.
    TimedOut,
    /// Kredensial atau request ditolak — 403 AccessDenied, InvalidAccessKeyId,
    /// SignatureDoesNotMatch, RequestTimeTooSkewed. <Code>-nya di-log, nggak nyampe
    /// ke client (ADR 0025).
    ///
    /// Tanpa default, dan JELAS bukan 403: itu bilang ke client "kamu nggak boleh"
    /// padahal yang nggak boleh itu server lo.
    Rejected,
    /// S3 nolak dengan cara yang modul ini nggak terjemahin. Teksnya di-log.
    Failed,
};
```

`Throttled → 503` dipertimbangkan dan ditolak, alasannya sama kayak `sql` nolak default
buat `Locked`: buat `GET /avatar/:id`, S3 nolak beban bisa aja artinya gambar default
dan status 200.

Baca `<Code>` **nggak butuh parser XML** — scan `<Code>…</Code>` itu ~20 baris.

### 6.2 Skew jam dibales, bukan cuma dicatat

`RequestTimeTooSkewed` itu satu-satunya 403 yang bukan salah program, dan body error S3
bawa waktu server. Scan `<ServerTime>` juga = 5 baris lagi, dan log-nya jadi
*"jam lo ketinggalan 23 menit dari S3"* bukan *"403"*. CLAUDE.md bilang error message
itu fitur.

### 6.3 Retry: cuma yang bukan kebijakan

`Request.deinit` (`std/http/Client.zig:890`) mutusin koneksi bisa dipake lagi atau nggak,
dan satu cabangnya jebakan:

```zig
connection.closing = connection.closing or switch (r.reader.state) {
    .ready => false,                          // body kebaca abis → dipake lagi
    .received_head => c: {
        …
        _ = reader.discardRemaining() catch …; // ← TANPA BATAS
        break :c r.reader.state != .ready;
    },
    else => true,                             // kebaca separo → dibuang
};
```

`get` yang ditolak `TooLarge` udah baca head dan nggak nyentuh body — jadi `deinit`
**ngedownload seluruh objeknya juga**, biar koneksinya kepake lagi. `max_bytes` 10 MB
lawan objek 500 MB = 500 MB egress buat request yang udah gagal, diam-diam.

Ini `drain(rows)`-nya `sql/wire.zig` lagi, dan lebih parah: pg.zig **ngancurin** koneksi
yang ditinggal kotor, std malah nyedot habis. `Request.connection` dan
`Connection.closing` dua-duanya field publik, jadi ini nggak butuh fork.

**Keputusan: sedot cuma kalau sisanya di bawah ambang yang dinyatakan; selain itu tandai
closing.** Ambangnya angka hasil ukur, bukan tebakan — usul awal 64 KB, harus diukur.

**Di luar itu, satu retry doang: koneksi pool yang udah ditutup S3.** Koneksi keep-alive
nganggur yang dipanen itu normal, dan tulisan pertama ke situ gagal; nggak ngulang sekali
bikin tiap idle timeout jadi kegagalan palsu. Itu **kebenaran**, bukan kebijakan.

**503 `SlowDown` dan 5xx balik ke handler bertipe.** Backoff ditolak, dan alasannya
gerbang di 3.5 bukan selera: fiber yang tidur sambil megang izin bikin throttling jadi
antrian, dan antrian jadi timeout buat semua request di belakangnya. Balik langsung
itu yang ngasih handler kesempatan nolak beban, jawab dari cache, atau sajiin default.
Dan streamed `put` emang nggak bisa di-retry — reader-nya udah kepake — jadi client yang
retry punya dua perilaku dalam satu API.

---

## 7. Lingkup v1

**Masuk:** `get` · `put` · `delete` · `head` · `presign` · Range GET · `getIf`

**Nol parser XML.** Body error cukup scan `<Code>`.

**Ditolak, dengan alasan tertulis:**

| Ditolak | Alasan | Ke mana |
|---|---|---|
| Multipart upload | Protokol tersendiri — Create/Upload/Complete plus XML, plus `Abort` yang **wajib** atau lo bayar storage part nyangkut selamanya. Plus state per-upload yang hidup lebih lama dari satu request | roadmap |
| `LIST` | Satu-satunya operasi yang jalur suksesnya XML: `<Contents>` bersarang, `<Key>`, `<Size>`, `<LastModified>`, `<ETag>`, continuation token, `<CommonPrefixes>`. ~300 baris parser + paginasi. Dan hasil list itu tipe punya AWS, bukan tipe punya caller — syarat masuk CLAUDE.md nggak kepenuhin. Daftar file punya user ada di Postgres | roadmap |
| `COPY` | Ikut LIST, plus jebakannya sendiri: S3 bisa jawab **200 dengan error di body** | roadmap |
| Backoff otomatis | Memperbesar overload lewat gerbang (§6.3) | handler |
| `x-amz-meta-*` sembarang | Bikin `SignedHeaders` jadi sortir per-request, bukan konstanta. Plus `\r\n` di nilai metadata itu header injection ke request yang lagi ditandatangani | — |
| SSE-KMS | ARN runtime, izin KMS, permukaan error baru. SSE-S3 gratis karena satu header konstan | roadmap |
| Provider chain IMDS/IRSA bawaan | Client HTTP ke `169.254.169.254` + parser respons STS + refresher latar belakang, di modul yang subjeknya object storage | `.fetch` |
| Template key comptime | Itu DSL template, dan README nolak template dengan alasan sama persis | — |

---

## 8. Angka

Aturan baru di CLAUDE.md: **angka tanpa run di belakangnya membusuk jadi klaim.**
Repo ini udah dua kali salah soal angka yang *udah dipublikasi* (`connect_on_init`,
"8.767 byte flat").

### 8.1 Udah diukur

| Angka | Nilai | Sumber |
|---|---|---|
| Koneksi HTTPS di pool `std.http.Client` | **59.151 B** | `tls_read` 24.837 (= 16.645 + 8.192) + `tls_write` 16.645 + `socket_read` 16.645 + `socket_write` 1.024 |
| Koneksi idle ditahan default | **1.892.832 B** | `free_size = 32` |
| Bagian `http1.zig` yang bisa dibagi | **165 / 686** (24%) | peta di §3.3 |
| Buffer TLS: std vs ianic | 33.290 / 33.114 | selisih 176 B |
| Kebijakan outbound, kode doang | **65 baris** | spike sesi lain di `spike/outbound/`, `./run.sh` |
| `std/http/Client.zig` + `std/crypto/tls/Client.zig` | 1.867 + 1.670 = 3.537 | 65 lawan 3.537 = **di bawah 2%** |

### 8.2 Harus diukur SEBELUM kode ditulis

| # | Angka | Kenapa penting |
|---|---|---|
| 1 | **Titik impas ambang drain** | 64 KB itu tebakan. Di ukuran sisa berapa nyedot lebih murah dari handshake TLS baru? |
| 2 | **`@sizeOf(zio.AutoCancel)`** | Nentuin slot opaque di `core.Limits`, dan comptime check yang nolak engine yang nggak muat |
| 3 | **RSS `Certificate.Bundle`** | Angka per-proses baru. ADR 0018 minta ditulis |
| 4 | **Delta binary size** | Stripped ReleaseFast, masuk total berjalan ADR 0018 |

### 8.3 Diukur SESUDAH kode jalan

| # | Angka | Kenapa penting |
|---|---|---|
| 5 | **Biaya signing per request** | Buktiin klaim "hemat 4 HMAC". Diukur **dua kali** — tanpa beban, dan di gerbang (CLAUDE.md: pool connection itu antrian serial) |
| 6 | **Titik tertinggi stack rute S3** | Metode ADR 0063. Ini biaya per-koneksi yang sebenernya |

### 8.4 Empat axis (ADR 0018)

| Axis | Biaya |
|---|---|
| **Alokasi per request** | Handler yang nggak nyentuh S3: **0**. `get` bounded: **1** (arena, ukurannya dari Content-Length). `get` streaming: **0**. `put` dari slice: **0**. `presign`: **1** (URL di arena). Buka koneksi pool baru: 1 `alignedAlloc`, teramortisasi |
| **Memory per koneksi idle** | **0** di koneksi masuk — nggak ada field baru di `Ctx` maupun koneksi yang dipool. Nambah angka **per-proses**: `max_in_flight × 59.151 B` + satu `Certificate.Bundle`. Per ADR 0063, handler yang manggil S3 juga nambahin titik tertinggi stack-nya ke tiap koneksi yang pernah dia jalanin |
| **Throughput dan p99** | **0** buat handler yang nggak nyentuh S3. Yang nyentuh: didominasi jaringan. Tambahan nilo = 1 HMAC-SHA256 + 1 shared `Io.RwLock` (~30ns) + 1 `Io.Semaphore.wait` + 1 indirect call ngarm deadline |
| **Binary size** | **0** buat program yang nggak import `nilo_s3` — nggak ada dependency buat di-fetch, nggak ada yang direferensiin buat linker tahan. `pg` sampai harus `.lazy`; ini nggak butuh |

---

## 9. Test

Tiga lapis.

### 9.1 Vektor offline — ini yang jadi bukti

**SeaweedFS lolos ≠ AWS lolos.** SigV4 itu kanonikalisasi tepat-byte, dan server
S3-compatible longgar soal beberapa aturannya. Kalau satu-satunya test nembak
SeaweedFS, bug kanonikalisasi lolos ke produksi dan ketauan sebagai
`SignatureDoesNotMatch` di server orang.

Dan S3 punya aturannya sendiri yang beda dari layanan AWS lain: **S3 nggak menormalkan
path dan nggak dobel-encode path.** Jadi test suite SigV4 resmi AWS pun nggak seluruhnya
berlaku — sebagiannya harus ditulis tangan khusus S3.

### 9.2 SeaweedFS di docker-compose

Ngikutin pola `sql/`: `docker-compose.yml` + modul `live_config` dari `b.addOptions()`
+ test yang **skip** kalau env-nya kosong (`build.zig:1114` buat versi `DATABASE_URL`-nya).

**Tiga syarat yang kalau kelewat bikin suite ini cuma hiasan:**

1. **Default SeaweedFS nggak minta tanda tangan sama sekali.** Kalau nggak ada identity
   yang dikonfigurasi, dia ngasih akses anonim ke semua operasi S3 — dan itu bakal
   ngeloloskan **semua** bug SigV4. Wajib `-s3.config=/etc/s3.json` dengan `identities`.
   Catatan: `-s3.iam.config` **nggak** dukung field `identities`.
2. **Pin versinya.** Verifikasi tanda tangan berubah antara 3.94 dan 3.95 dan bikin
   `SignatureDoesNotMatch` di deployment Docker. `:latest` bikin suite lo merah karena
   bug orang lain.
3. Dia tetep longgar, cuma di tempat beda dari MinIO.

**Kenapa SeaweedFS justru cocok:** dia salah satu server yang **nggak** dukung
`STREAMING-UNSIGNED-PAYLOAD-TRAILER` (seaweedfs#6583). Jadi dia jadi kenari di tambang
buat keputusan §4.3 — kalau desain Content-Length-only lolos di SeaweedFS, dia lolos di
dunia S3-compatible yang nyata.

### 9.3 AWS beneran, opt-in

Langkah terpisah, dijalanin tangan sebelum rilis, kapan terakhirnya ketulis di
`bench/RESULTS.md`. CI nggak jalanin, dan itu ditulis jujur.

### 9.4 Seam

**Usulan: satu seam.** Keputusan layer keempat (§10) ngambil sebagian besar yang butuh
seam keluar dari `s3/` — gerbang, pool, drain, deadline semuanya pindah. Yang tersisa
di nilo_s3 yang bisa salah tinggal **byte-nya request**.

Seam-nya: **request yang udah ditandatangani, sebagai nilai — dibangun, nggak dikirim.**

```
(operasi, key, opsi, kredensial, region, endpoint, jam)
        → { method, url, headers[] berurutan, bentuk body }
```

Di atasnya `Bucket.get/put/delete/head/presign` tipis. Di bawahnya semuanya punya std.
Nggak ada tempat lebih tinggi yang masih ngeliat byte.

Satu file, dua arah — request keluar dan respons masuk (status + `<Code>` → `Error` atau
`Object`), bentuknya kayak `sql/wire.zig` yang nulis seluruh kontraknya di header file.

**`sign.zig` sengaja BUKAN seam.** Itu detail implementasi. Ngetes dia langsung bakal
ngetes penyusunan canonical request tanpa ngetes apakah `get`/`put`/`presign` ngasih
input yang bener — dan di situ bug-nya tinggal. Lagian ADR 0066 (percent pindah ke
`nilo_core`) udah ngebunuh properti `zig test s3/sign.zig` standalone.

**Namanya belum diputusin.** `Wire` di `CONTEXT.md` udah didefinisiin sebagai *"the half
that speaks to the database"* — mesin ini justru yang **nggak** ngomong. Analogi yang
lebih pas `Dialect` (*"the half that writes the SQL, worked out entirely while
compiling"*). Ini keputusan `CONTEXT.md`, jangan dinamain diam-diam.

---

## 10. Fitting — layer keempat

**Keputusan: ada layer keempat antara Tool dan Service, dan namanya *Fitting*.**

| Layer | Modul | Loop |
|---|---|---|
| Core | `core/` | nggak butuh |
| Tool | `id`, `config`, `pw` | nggak butuh |
| **Fitting** | `fetch/` | **minjem, nggak megang tujuan** |
| Service | `sql`, `s3` | minjem, megang sistem bernama |
| App | `http/` | punya sendiri |

Namanya lolos tes yang `CONTEXT.md` pake buat tiap istilah: dia bilang **apa yang
nentuin keanggotaan**, bukan apa bentuknya. Sebuah fitting itu benda standar yang nggak
punya tujuan sendiri — lo pasang ke rangkaian pipa mana pun yang lagi lo punya. Register-nya
juga satu keluarga sama Bulkhead dan Engine.

Kalimat yang ngebedain:

> A Fitting borrows the loop and owns no destination. `nilo_fetch` is a Fitting;
> `nilo_sql` is a Service because it holds a pool to a database named in its URL.

*Transport* ditolak: nabrak arti OSI layer 4, dan **Engine** udah megang peran itu
(*"the bottom layer, the one that deals with the operating system"*). Plus layer ini
bukan cuma soal mindahin byte — penghuni berikutnya bisa rate limiter atau cache DNS,
dan nama yang nyempitin ke satu fungsi bakal salah buat layernya sendiri.

**Kenapa layer ini ada.**

Alasannya: gerbang, deadline, dan kebijakan drain itu temuan **level client**, bukan
level S3. Handler yang manggil Stripe kena persis sama. Kalau lapisan itu lahir di dalam
`s3/`, salinan keduanya ditulis buat user code — dan itu bukan 40 baris encoder kayak
`percent`, tapi ratusan baris plus TLS plus pool.

Kenapa nggak bisa ditaro di tempat yang udah ada:

- `http/` → `s3/` nggak bisa nyampe. Sibling, `zig build layering` nolak.
- `nilo_core` → core itu *"no IO at all"*. Kebijakan drain butuh `std.http.Client`.
- Modul sendiri di layer Service → `s3` import dia = Service import Service = sideways.

### 10.1 Syarat masuk yang diusulin

ADR 0042 bikin layer bawah **kebeli** karena syarat masuknya bisa dijalanin, bukan
karena paragraf. Layer keempat butuh yang setara.

| layer | butuh `std.Io`? | punya tujuan? | syarat masuk |
|---|---|---|---|
| **Tool** (`id`, `config`, `pw`) | nggak | — | `zig test id/id.zig` — tanpa module graph |
| **Fitting** (`fetch`) | **iya, dipinjem** | **nggak** | `zig test fetch/fetch.zig` **di bawah `std.Io.Threaded`** — tanpa module graph, tanpa engine |
| **Service** (`sql`, `s3`) | iya | **iya** — sistem eksternal bernama, didaftarin lewat `app.provide` | butuh module graph |

Garisnya: **modul yang megang koneksi hidup ke sistem bernama itu Service.** `nilo_sql`
megang pool ke database yang namanya ada di URL. `nilo_s3` megang kredensial dan endpoint.
Modul outbound HTTP nggak megang dua-duanya — dia dikasih URL per panggilan.

Peringatan dari ADR 0062 yang harus masuk ke syaratnya: `std.Io.Threaded` **nggak bisa
markir caller yang bukan task-nya sendiri** — reconnector pg.zig panik di situ. Jadi
syaratnya cuma berlaku buat modul yang nggak punya kerja latar sendiri, dan itu justru
bagian dari definisinya.

### 10.2 Spike-nya udah ada dan syaratnya LOLOS

Sesi lain bikin `spike/outbound/` — `./run.sh` ngeluarin angkanya.

- **65 baris kode kebijakan** (104 kalau ikut komentar), lawan 3.537 baris std. **Di bawah 2%.**
- Isinya persis tiga hal yang ketemu di desain ini: gerbang (`std.Io.Semaphore`), drain
  yang dibatesin (`req.connection.?.closing = true` sebelum `deinit`), dan plafon body
  yang dipaksain **sambil baca** lewat `allocRemaining(gpa, .limited(n))` — bukan dicek
  setelahnya, jadi pengirim yang boong soal content-length nggak bisa nembus.
- **`build.zig.zon`-nya nggak punya dependency sama sekali.** Tiga tes jalan lawan server
  loopback beneran, semuanya di atas `std.Io.Threaded`, tanpa zio, tanpa module graph.
  `zig build test` hijau.
- Ditambah deadline (ADR 0065) dan TLS (itu field di `std.http.Client`, bukan kode di
  layer ini), taksirannya jadi **90–100 baris**.

**Ini argumen berat lawan layer baru, tapi bukan yang mematikan.** Alasan bikin layer itu
soal **di mana sebuah aturan bisa dipaksain**, bukan berapa banyak kode yang duduk di
dalamnya — dan `zig build layering` itu alat pemaksa yang beneran ada di repo ini.

**ADR 0070 harus nyebut angka 65 itu di dalamnya, bukan menghindarinya.** Kalau nggak,
orang berikutnya yang ngukur bakal nanya kenapa.

---

## 11. ADR

| # | Judul | Isi | Status |
|---|---|---|---|
| 0065 | the way out was open; the clock was not | Seam deadline, `core.Limits`, `nilo_start` dua arity | **ditulis** |
| 0066 | percent is needed by two layers | `percent` pindah ke `core/`, encode ditambahin | sesi lain, **mendarat** |
| 0067 | most of an S3 client is not S3 | 24%, `std.http.Client`, gerbang, drain, retry | **ditulis** — perlu amandemen |
| 0068 | a bucket is a type, and a key is not | Bucket, API, refusals, error set | **ditulis** |
| 0069 | a signing key changes once a day | Kredensial, kunci turunan, payload hash, presign | **ditulis** |
| 0070 | — | Layer keempat + amandemen ADR 0041 & 0042 | **belum** — nunggu nama |

Amandemen 0067 nunggu 0070: gerbang dan kebijakan drain pindah keluar dari `s3/`.
Keempat pengukurannya tetep sah — itu properti `std.http.Client`, bukan properti S3.

Nomor ADR berikutnya buat siapa pun: **0071**.

---

## 12. Yang masih terbuka

**Nol.** Dua yang tadinya terbuka udah kejawab:

- **Apakah outbound HTTP itu modul atau cuma kebijakan tipis** → **65 baris**, diukur
  lewat spike beneran. Lihat §10.2.
- **Nama layer keempat** → **Fitting**. Lihat §10.

Satu yang belum diputusin tapi bukan blocker: **nama seam-nya** (§9.4). `Wire` udah
kepake buat arti lain di `CONTEXT.md`, jadi jangan dipake ulang. Itu keputusan yang
diambil pas nulis kodenya, bukan sekarang.

---

## 13. Kosakata buat `CONTEXT.md`

Belum ditulis. Istilah yang perlu masuk:

| Istilah | Arti | `_Avoid_` |
|---|---|---|
| **Bucket** | Tipe yang megang apa yang benar tentang satu bucket dan bukan tentang deployment-nya: namanya, gaya alamatnya, batas ukurannya. Dua bucket itu dua tipe, jadi dua Service | container, store, bin, folder |
| **Object** | Satu isi di satu key, dengan tipe isi dan ETag-nya, hidup selama request | blob, file, entry, item |
| **Presigned** | URL yang bawa izinnya sendiri dan tanggal matinya sendiri — dan tanggal matinya yang sebenarnya, bukan yang diminta | signed url, temporary link, share link |
| **Credentials** | Sepasang kunci dan kapan dia berhenti berlaku. Yang mengambilnya milik program; yang menyimpan dan memperbaruinya milik nilo | secret, token, auth, api key |
| **Limits** | Cara memberi batas waktu pada satu operasi yang berjalan di loop pinjaman. Kosakata tentang kapan sebuah operasi menyerah, sebagaimana Scope tentang di mana ia mengalokasi | timeout, cancel token, context, budget |

Plus entri layer, yang ikut ADR 0070:

> **Fitting**:
> A module that borrows the event loop and owns no destination. It is handed `std.Io`
> and given an address on every call, so it holds no connection to any named system —
> which is what separates it from a Service. It may name Core and nothing above it, and
> its tests run under `std.Io.Threaded` with no engine and no module graph: the entry
> condition rather than a nicety, the same way a Tool module's plain `zig test` is.
> _Avoid_: adapter, client, transport, driver, connector, integration

---

## 14. Urutan kerja

1. **Tulis ADR 0070 — Fitting.** Syarat masuknya, perubahan tabel `layers`, amandemen
   ADR 0041 dan 0042. **Harus nyebut angka 65 baris**, bukan menghindarinya: kalau layer
   ini berdiri, dia berdiri karena `zig build layering` bisa maksa aturannya, bukan
   karena penghuninya gede. Orang yang ngukur ulang nanti bakal nanya.
2. **Amandemen ADR 0067** — gerbang dan kebijakan drain pindah keluar dari `s3/` ke
   Fitting.
3. **Update header `core/core.zig`** — sekarang bunyinya *"Four things live here … which
   is the rule for a fifth"*; `core.Limits` bikin angka itu jadi lima.
4. **Ukur angka 1–4** (§8.2), tulis ke `bench/RESULTS.md`.
5. **Tambahin kosakata ke `CONTEXT.md`** (§13), termasuk entri **Fitting**.
6. **Cabut entri `nilo_s3` dari `docs/roadmap.md`**; pindahin LIST / COPY / multipart /
   SSE-KMS ke sana dengan alasannya.
7. **`build.zig`**: baris `.{ .root = "fetch", .may_import = &.{"nilo_core"} }` dan
   `.{ .root = "s3", .may_import = &.{"nilo_core", "nilo_fetch"}, .in_tests = &.{"nilo_http"} }`,
   plus `shipped_roots`, plus `.paths` di `build.zig.zon`.
8. **Tabel `s3_refusals` kelima** + langkah `refusals-s3` + `test-s3` (+ `test-fetch`).
   ⚠️ CLAUDE.md: nambah baris ke satu tabel sambil ngejalanin tabel lain itu check yang
   diam-diam nggak pernah jalan. Di lima tabel bahayanya lebih gede dari di empat.
9. **Baru nulis kode**, mulai dari penandatanganan lawan vektor offline.

---

## 15. Keadaan lintas sesi

Tiga sesi Claude jalan di repo ini barengan pas desain ini dibikin.

| Sesi | Pegang | Status |
|---|---|---|
| Ini | nilo_s3, ADR 0065/0067/0068/0069, seam deadline | ADR ditulis, nol kode |
| `zfast-87` | `percent` → `core/` (ADR 0066), koreksi roadmap, `spike/outbound/` | mendarat |
| `zfast-f1` | `nilo_config`, dotenv (ADR 0064) | mendarat |

**Kesepakatan yang berlaku:**

- Seam deadline (`http/bulkhead.zig`, `core.Limits`) **punya sesi ini**. `zfast-87`
  nggak nyentuh.
- `zfast-87` **nggak** nulis apa pun soal bentuk seam-nya di roadmap — itu jatah ADR 0065.
- Modul Fitting (`fetch/`) ditulis `zfast-87`, **setelah ADR 0070 mendarat** — syarat
  masuk layer itu yang nentuin modulnya boleh import apa.
- Nama **Fitting** diputusin user `zfast-87`; entri `CONTEXT.md`-nya ikut ADR 0070,
  jadi sesi ini yang nulis.

**Yang berubah di repo selama desain ini** (bukan kerjaan sesi ini):

- `percent.zig` pindah dari `http/` ke `core/`, plus encode: `Set.path` (biarin `/`),
  `Set.unreserved` (`/` → `%2F`), spasi selalu `%20` tanpa jalan ngeluarin `+`,
  uppercase hex satu-satunya perilaku, `encodedLen` + `encodeInto` + `encodeWrite`.
  Dipanggil `@import("nilo_core").percent`. `zig test core/core.zig` 32/32.
- Header `core/core.zig` sekarang bunyinya *"Four things live here … which is the rule
  for a fifth"* — **pas `core.Limits` mendarat, angka itu jadi lima, dan sesi ini yang
  edit.**
- Hitungan refusal di CLAUDE.md sekarang **109**, bukan 105.
- History `main` di-rewrite: `def3bbd` disatuin ke `d3ee93c`.
- `docs/roadmap.md` udah dikoreksi (§2).
- CLAUDE.md nambah aturan: **benchmark yang dijalanin masuk `bench/RESULTS.md`**, dengan
  apa yang dijalanin, mesinnya, commit-nya, angkanya, dan keputusan yang digerakinnya.

**Working tree kotor, nggak ada commit** — sesuai aturan lo, commit cuma pas diminta.
