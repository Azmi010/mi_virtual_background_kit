# Benchmark — Fase 6 (T6.2)

Tanggal: 2 November 2026  
Protocol: sesi 10 menit per efek, effect default quality **Balanced**, radius blur 20, kamera depan 640×480 @30 fps.  
Raw dump: `docs/bench-raw/` + logcat/`flutter run` (Android: `a1_*`, iOS: sesi di `/tmp/ios_*`).

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

Tanggal: 3 November 2026 · Tool: `tool/soak.sh 30` · Raw: `docs/bench-raw/a1_soak_20261103_104351*`

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
