# Benchmark — Fase 6 (T6.2)

Tanggal: 2 November 2026  
Protocol: sesi 10 menit per efek, effect default quality **Balanced**, radius blur 20, kamera depan 640×480 @30 fps.  
Raw dump: `doc/bench-raw/` + logcat/`flutter run` (Android: `a1_*`, iOS: sesi di `/tmp/ios_*`).

## Perangkat

| ID | Perangkat | OS | Koneksi | Catatan |
|----|-----------|-----|---------|---------|
| A1 | Samsung SM-A135F (`RR8T601FP0R`) | Android 14 (API 34) | USB | kelas low |
| I1 | iPhone 15 (`00008120-0016195A0CC20032`, D37AP) | iOS 27.0.1 | USB (`flutter run`) | kelas high |

Cakupan: 2 device fisik. Kelas mid tidak diukur (lihat [test-matrix.md](test-matrix.md)). Emulator tidak dipakai.

## FPS per efek (10 menit)

Sumber: HUD `flutter: HUD frames=… fps=…` tiap detik selama sesi.

### A1 — Android low

| Efek | n (dtk) | min | max | mean | median | vs target 24–30 |
|------|---------|-----|-----|------|--------|-----------------|
| None (bypass) | 608 | 16 | 32 | **29.8** | 30 | ✅ |
| Blur | 608 | 19 | 32 | **28.4** | 30 | ✅ |
| Image cover | 607 | 19 | 32 | **28.4** | 30 | ✅ |
| Color teal | 607 | 25 | 32 | **30.0** | 30 | ✅ |

- Drop sesaat ke 16–19 fps terjadi di None/Blur/Img; median tetap 30.
- **Tidak ada** event `Performance fallback` / auto-disable di 4 sesi (FR-12 tidak terpicu di device ini dengan Balanced).

### I1 — iOS high

| Efek | n (dtk) | min | max | mean | median | vs target 24–30 |
|------|---------|-----|-----|------|--------|-----------------|
| Blur | 601 | 25 | 31 | **30.0** | 30 | ✅ |
| Image cover | 600 | 29 | 31 | **30.0** | 30 | ✅ |
| Color teal | 600 | 29 | 31 | **30.0** | 30 | ✅ |
| None (bypass) | 600 | 29 | 31 | **30.0** | 30 | ✅ |

- Stabil di 30, noise minimal. No fallback event.

## CPU (snapshot `dumpsys cpuinfo` — Android only)

% CPU proses app saat akhir sesi (bukan rata-rata 10 menit; spot check).

| Efek | CPU proses app | TOTAL system |
|------|----------------|--------------|
| None | ~83–143% * | ~33–40% |
| Blur | ~139% | ~40% |
| Image cover | ~133% | ~37% |
| Color teal | ~143% | ~40% |

\* None bervariasi karena snapshot jatuh di momen berbeda; bypass memang lebih murah saat segmentasi/matikan.

iOS: `dumpsys` tidak tersedia; CPU spot-check via Instruments belum dijalankan — **gap dicatat**.

## Memori (Pss TOTAL, Android, akhir sesi)

| Efek | Pss |
|------|-----|
| None | ~290 MB |
| Blur | ~285 MB |
| Image cover | ~287 MB |
| Color teal | ~286 MB |

Stabil ±5 MB antar efek → **tidak ada lonjakan leak** antar perpindahan efek dalam satu sesi panjang.  
iOS memori per sesi: belum diukur (perlu `devicectl`/Instruments) — **gap**.

## Latensi per frame

- Komposit GPU: angka spike T0.7 tetap acuan (~1 ms @640×480, device low-end 32-bit) — lihat [spike-results.md](spike-results.md).
- Segmentasi MediaPipe: angka spike (arm64 belasan ms, 32-bit ~179 ms @640) — tidak diukur ulang di sesi T6.2 (PROD path tidak memancarkan latensi mentah ke HUD).
- **Gap:** latensi end-to-end per frame di sesi 10 menit belum dipublikasikan per device.

## Baterai

| Platform | Hasil |
|----------|-------|
| A1 | **Tidak terukur** — selalu USB charging, `level` 100% sepanjang sesi |
| I1 | **Tidak terukur** — USB via `flutter run` |

Perlu sesi ulang tanpa kabel (wireless adb / lepas charger) untuk angka drain. **Gap.**

## Kesimpulan vs PRD §7

| Target | Status |
|--------|--------|
| 24–30 fps @ 640×480–720p di mid/low | ✅ terpenuhi di A1 (low) & I1 (high), mean 28.4–30 |
| Komposit ~1 ms/frame | ✅ dari spike, bukan sesi ini |
| Latensi per frame dipublikasikan di README | ⚠️ sebagian (spike saja) |
| CPU/mem/baterai dilaporkan di Batasan | ⚠️ CPU & mem Android; baterai & CPU/iOS & mem iOS = gap |
| 3 kelas perangkat | ❌ hanya 2 device (batasan akses hardware) |

## Batasan yang harus jujur di README

1. Hanya 2 device fisik; mid-tier tidak ada.
2. Baterai tidak terukur (perangkat terus dicharge).
3. CPU/mem iOS tidak di-snapshot di sesi ini.
4. Latensi per-frame end-to-end belum diukur di sesi 10 menit (hanya spike).

## Soak 30 menit (T6.5, A1)

Tanggal: 3 November 2026 · Tool: `tool/soak.sh 30` · Raw: `doc/bench-raw/a1_soak_20261103_104351*`

- Durasi penuh 30 menit, 30 sampel tiap 60 dtk, PID proses **sama** (29010) dari awal sampai akhir — tanpa restart atau crash.
- Memori Pss: 163 MB (cold start) → ~250 MB (warmup menit pertama) → **plateau 250–258 MB selama 27 menit sisanya**. Delta warmup→akhir +6,6 MB ≈ noise GC — **tidak ada kebocoran memori**.
- Crash / ANR / performance-fallback: **0 baris** di logcat 30 menit.
- Frame pass log terakhir `#54300` ≈ **30,1 fps** stabil sepanjang sesi.
- Baterai tidak informatif (USB terus mengisi; level naik 65→75).

### Loop attach/detach 100× (T6.5)

`example/integration_test/soak_loop_test.dart` — 100 siklus attach→(effek tiap 25)→detach, detach ganda tiap 50, attach final, tanpa error.

- **A1 (Android): lulus** dalam 10 dtk.
- **I1 (iOS): lulus** dalam 3 dtk.

## Soak 30 menit (T6.5, I1)

Tanggal: 3 November 2026 · Tool: `flutter run -d <I1> --debug` + monitor 60 dtk/sampel · Log: `/tmp/i1_soak_run.log`, samples: `/tmp/i1_soak30.log`

- 30 sampel / 30 menit, `flutter run` **ALIVE di semua sampel** — koneksi USB stabil, tanpa lost connection.
- FPS HUD **30 di setiap sampel** (seragam, tanpa drop ke 20-an).
- Frame pass log terakhir `#54750` ≈ **30,4 fps** (`30 fps stable`).
- Crash / lost connection / performance-fallback: **0 event** di 30 menit.
- Memori iOS tidak di-snapshot (tanpa Instruments) — gap metrik, bukan stabilitas.

### Gap tersisa T6.5

- Memori soak iOS tidak terukur (perlu Instruments/`xcrun` khusus) — stabilitas dan fps sudah terbukti.

## v0.2.0 — benchmark ulang (T17.1)

Tanggal: 17 November 2026.  
Protokol: 10 menit per efek, `BackgroundQuality.balanced`, kamera depan 640×480 @30 fps, radius blur 20. Sama dengan protokol v0.1; bedanya sumber angka fps — v0.2 memakai sample native `metricsStream` (~1 Hz), bukan HUD `flutter:` lama. Data mentah tidak disimpan; angka di bawah adalah ringkasan hasil.

A1 memakai Wi-Fi adb dengan kabel dicabut (`bstate=3` sepanjang sesi). I1 memakai USB untuk sesi integration; baterai iOS diukur terpisah pada sesi app standalone tanpa kabel. CPU/memori iOS tidak diukur di T17.1 — cakupan T17.2 (Instruments).

### FPS — A1 (Android low)

| Efek | n | mean | median | min | v0.1 mean | Δ |
|------|---|------|--------|-----|-----------|---|
| None | — | **29,96**¹ | — | — | 29,8 | +0,2 |
| Blur | 584 | **29,84** | 30,0 | 24,2 | 28,4 | +1,4 |
| Image cover | 583 | **29,83** | 30,0 | 17,3 | 28,4 | +1,4 |
| Color teal | 583 | **29,82** | 30,0 | 20,0 | 30,0 | −0,2 |

¹ `NoEffect` tidak menghasilkan sample metrik (bypass langsung kembali sebelum gate). Angka diturunkan dari logcat: `frame pass #1` 11:14:23.090 → `#18000` 11:24:23.818 = 17.999 frame / 600,7 s.

### FPS — I1 (iOS high)

| Efek | n | mean | median | min | v0.1 mean | Δ |
|------|---|------|--------|-----|-----------|---|
| None | — | tidak diukur² | — | — | 30,0 | — |
| Blur | 600 | **30,00** | 30,0 | 30,0 | 30,0 | 0 |
| Image cover | 600 | **30,00** | 30,0 | 30,0 | 30,0 | 0 |
| Color teal | 601 | **30,00** | 30,0 | 30,0 | 30,0 | 0 |

² Bypass tidak menghasilkan sample metrik, dan harness iOS tidak merekam log frame pass. Angka v0.1 (30,0) dipertahankan sebagai acuan; tidak ada alasan kode untuk berubah pada jalur bypass.

### Latensi per frame (baru di v0.2, FR-23)

Rata-rata sample 1 Hz. `seg` = durasi inferensi segmentasi terakhir; `age` = usia mask yang sedang dikomposit.

| Efek | A1 seg | A1 age | I1 seg | I1 age |
|------|--------|--------|--------|--------|
| Blur | 84,0 ms | 115,4 ms | 63,9 ms | 131,2 ms |
| Image cover | 79,1 ms | 107,2 ms | 113,0 ms | 284,2 ms |
| Color teal | 79,6 ms | 108,1 ms | 115,5 ms | 253,6 ms |

Angka A1 sesuai model landscape (spike T13.4: 87,9 ms). Angka iOS tidak dibandingkan lintas efek secara ketat — beban scene dan frekuensi segmentasi berbeda tiap sesi.

### CPU dan memori — A1

| Efek | CPU% (mean) | Pss mean | Pss awal → akhir |
|------|-------------|----------|------------------|
| None | 40,1% | 278,5 MB | 275,5 → 279,8 MB |
| Blur | 127,8% | 299,9 MB | 290,0 → 305,3 MB |
| Image cover | 114,0% | 307,1 MB | 297,3 → 311,8 MB |
| Color teal | 122,2% | 303,3 MB | 296,3 → 307,3 MB |

CPU% diverifikasi silang dengan `dumpsys cpuinfo` (blur 127%, image 116%, color 114%, none 39%). Angka absolut **tidak langsung sejajar** dengan v0.1: v0.2 diukur dari harness `flutter test integration_test`, v0.1 dari app standalone. Pss efek aktif v0.2 lebih tinggi ~13–20 MB daripada v0.1 (~285–290 MB); kenaikan ini dicatat apa adanya, bukan dianggap noise.

iOS: CPU/memori tidak diukur di sesi T17.1; lihat bagian T17.2 di bawah.

### Baterai

A1 — dari sesi integration 10 menit, kabel dicabut:

| Efek | Awal | Akhir | Turun |
|------|------|-------|-------|
| None | 60% | 57% | 3 poin |
| Blur | 57% | 54% | 3 poin |
| Image cover | 54% | 52% | 2 poin |
| Color teal | 52% | 50% | 2 poin |

Total 60% → 50% dalam 40 menit (~2,5 poin per 10 menit).

I1 — sesi app standalone terpisah, tanpa kabel, efek dipilih manual (None / Blur radius 20 / Teal / Asset Office):

| Efek | Awal | Akhir | Turun |
|------|------|-------|-------|
| None | 88% | 87% | 1 poin |
| Blur | 87% | 83% | 4 poin |
| Color teal | 83% | 81% | 2 poin |
| Image cover | 81% | 78% | 3 poin |

Catatan: angka iOS berasal dari sesi berbeda dengan angka fps, bukan dari harness yang sama. Hal ini menjadi batasan metode, bukan hasil pengukuran yang cacat.

### Anomali

- A1 image: tiga sample di t≈411,7–413,8 s turun ke 17,3–22,8 fps sementara `seg` tetap 68–76 ms. Pulih dalam 1 detik, tidak memicu fallback — gangguan sesaat di luar segmentasi.
- I1 color: satu sample `seg` 829 ms; fps tetap 30,0, tidak ada fallback.

### Kesimpulan vs T17.1

| Target | Status |
|--------|--------|
| Tidak ada regresi fps vs v0.1 | ✅ A1 blur/image +1,4; I1 30,0 semua efek aktif |
| Baterai terukur di dua platform | ✅ A1 dari integration; iOS dari sesi standalone terpisah |
| CPU/memori | ⚠️ A1 tersedia; iOS masih gap (T17.2) |
| Tiga kelas perangkat | ❌ tetap dua device; kelas mid tidak tersedia (T12.3) |

## CPU dan memori iOS — Instruments (T17.2)

Tanggal: 18 November 2026.  
Metode: `xctrace record` dengan template **Activity Monitor**, attach ke proses `Runner.app` yang diverifikasi (dua instance terpasang di device; yang salah dimatikan lebih dulu). Sesi utama: soak 30 menit dengan `BlurEffect(radius: 20)`. Sesi pendek 5 menit untuk efek lain. Data mentah tidak disimpan; angka di bawah adalah ringkasan hasil.

| Efek | Durasi | CPU% mean | CPU% median | CPU% maks | Memory (physical footprint) | Real Mem |
|------|--------|-----------|-------------|-----------|------------------------------|----------|
| None | 5 mnt | 19,1% | 19,1% | 20,2% | 273,7 MB | 442,9 MB |
| Blur (soak) | 30 mnt | **115,4%** | 122,0% | 146,3% | 288,1 MB | 433,1 MB |
| Image (Asset Office) | 5 mnt | 100,8% | 99,4% | 131,8% | 291,3 MB | 587,3 MB |
| Color teal | 5 mnt | 99,7% | 98,7% | 126,8% | 288,0 MB | 621,6 MB |

Soak 30 menit menghasilkan 1.728 sampel (~1 Hz), dari `00:00.000` sampai `29:59.264`. CPU rata-rata naik dari **97,4%** pada 5 menit pertama menjadi **123,9%** pada 5 menit terakhir. Memory physical footprint tetap **291,2 → 286,7 MB**, Real Mem **442,1 → 437,1 MB** — tidak ada pertumbuhan berkelanjutan. Kenaikan CPU tidak disertai pembengkakan memori dan tidak ada pengukuran fps pada sesi ini, jadi lebih mungkin perubahan beban/scene daripada kebocoran.

Efek aktif mengonsumsi ~100–115% CPU, sebanding dengan A1 (114–128%). `None` di iOS jauh lebih murah (19,1%) daripada A1 (40,1%); angka keduanya berasal dari alat berbeda (Activity Monitor vs `top`), jadi tidak dibandingkan langsung.

**Kesimpulan T17.2:** celah CPU/memori iOS dari T6.2 dan T6.5 tertutup. Tidak ada indikasi kebocoran memori pada soak 30 menit.

## Latensi frame → output (T17.3)

Tanggal: 18 November 2026.  
Sumber: `metricsStream.processorLatencyMs`, efek `ColorEffect(teal)`, `BackgroundQuality.balanced`, 640×480 @30 fps, sesi 2 menit per device. Data mentah tidak disimpan; angka di atas adalah ringkasan hasil.

| Device | n | mean | median | min | maks | p95 |
|--------|---|------|--------|-----|------|-----|
| A1 (Android low) | 116 | 5,97 ms | **0,90 ms** | 0,50 ms | 32,20 ms | 27,20 ms |
| I1 (iOS high) | 120 | 1,33 ms | **1,40 ms** | 1,00 ms | 1,60 ms | 1,50 ms |

Distribusi A1 dua puncak: 92/116 sampel ≈ 1,4 ms, 24/116 sampel ≈ 23,5 ms. Sampel lambat bertepatan dengan frame yang melakukan readback/upload mask untuk segmentasi; komposit GPU sendiri tetap ~1 ms. I1 stabil di ~1,3–1,4 ms.

**Definisi:** waktu mulai = frame tiba di processor native; waktu akhir = frame hasil komposit dikembalikan ke WebRTC. Angka ini **tidak** mencakup pembacaan sensor kamera, encode, jaringan, atau render layar — bukan angka glass-to-glass. Angka ini dipublikasikan juga di README bagian Limitations.

**Kesimpulan T17.3:** angka latensi pipeline tersedia untuk kedua platform dan dipublikasikan di README.
