-- Uji Kotak Fungsi gagal di bawah beban (ADR 0007).
--
-- Bukan benchmark: yang diukur bukan kecepatan, melainkan apakah pesan
-- Fungsi gagal pernah tertukar antar-request yang berjalan bersamaan.
-- Kalau Kotak-nya terikat ke utas dan bukan ke fiber, angka di baris
-- terakhir akan lebih dari nol.
--
--   wrk -t4 -c64 -d10s -s bench/campur.lua http://127.0.0.1:8787
--
-- Rutenya mengikuti contoh di src/main.zig: /users/7 ada, /users/9999999
-- tidak, dan yang tidak ada dijawab Fungsi gagal dengan pesan yang
-- menyebut id-nya.

local n = 0

request = function()
    n = n + 1
    if n % 2 == 0 then
        return wrk.format("GET", "/users/9999999")
    else
        return wrk.format("GET", "/users/7")
    end
end

local salah = 0

response = function(status, headers, body)
    if status == 404 then
        if not string.find(body, "user 9999999 tidak ditemukan", 1, true) then
            salah = salah + 1
        end
    elseif status == 200 then
        if not string.find(body, '"id":7', 1, true) then
            salah = salah + 1
        end
    else
        salah = salah + 1
    end
end

done = function(summary, latency, requests)
    io.write(string.format(
        "\nrespons salah atau tertukar: %d dari %d\n", salah, summary.requests))
    if salah > 0 then
        io.write("PESAN FUNGSI GAGAL BOCOR ANTAR-REQUEST — lihat ADR 0007\n")
    end
end
