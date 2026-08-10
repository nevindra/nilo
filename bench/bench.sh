#!/usr/bin/env bash
# Skrip benchmark zfast — ada di repo sejak tahap 1 (lihat docs/rencana.md)
# supaya saat mesin ukur tersedia ia tinggal satu perintah, bukan proyek baru.
#
# Metrik (docs/rencana.md):
#   Utama    : request/detik DAN p99, GET terute dengan path param yang
#              mengembalikan JSON ~1KB, keep-alive, tanpa pipelining.
#   Sekunder : memori per koneksi menganggur (belum diukur skrip ini).
#
# Catatan tahap 1: belum ada router dan belum ada JSON, jadi target default
# masih "hello". Begitu lapisan Ctx jadi, ganti URL default ke rute
# berparameter yang mengembalikan JSON ~1KB.

set -euo pipefail

URL="${1:-http://127.0.0.1:8787/users/42}"
DURASI="${DURASI:-30s}"
KONEKSI="${KONEKSI:-64}"
THREAD="${THREAD:-4}"

if command -v wrk >/dev/null; then
    # wrk memakai keep-alive secara default dan tidak melakukan pipelining.
    exec wrk -t"$THREAD" -c"$KONEKSI" -d"$DURASI" --latency "$URL"
elif command -v oha >/dev/null; then
    exec oha -z "$DURASI" -c "$KONEKSI" --no-tui "$URL"
else
    echo "butuh wrk atau oha. contoh pasang: sudo apt install wrk" >&2
    exit 1
fi
