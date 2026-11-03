# Test Matrix — Fase 6

Referensi: [PRD.md](PRD.md) §7, [TASKS.md](TASKS.md) T6.1.  
Status: daftar siap, hasil diisi saat eksekusi T6.2–T6.5.

## 1. Perangkat

PRD meminta minimal tiga kelas perangkat per platform (low, mid, high).
Akses hardware terbatas — hanya dua perangkat fisik yang tersedia.
Kelas mid tidak diukur. Angka benchmark resmi hanya dari dua baris di bawah.
Emulator tidak dipakai (GPU/segmentasi tidak representatif).

| ID | Platform | Kelas | Perangkat / identitas | Koneksi | Peran |
|----|----------|-------|------------------------|----------|-------|
| A1 | Android | low | Serial `RR8T601FP0R` | USB (`adb`) | Benchmark resmi, integration test, soak, fallback |
| I1 | iOS | high | UDID `00008120-0016195A0CC20032` (iPhone 15) | Wireless (Xcode network) | Benchmark resmi, integration test, soak, fallback |

Identitas model lengkap (manufacturer/model SDK) diisi dari `adb shell getprop` / Xcode saat sesi pertama.

## 2. Skenario

Legend hasil: `pass` · `fail` · `n/a` · kosong = belum dijalankan.

| # | Skenario | FR | A1 | I1 | Catatan / bukti |
|---|----------|----|----|----|-----------------|
| S1 | `isSupported()` benar di device didukung | FR-13 | | | |
| S2 | `attach` ke track kamera lokal | FR-06 | | | Preview hidup |
| S3 | Efek blur (radius default + variasi) | FR-01 | | | Screenshot edge |
| S4 | Efek gambar `cover` | FR-02 | | | Orientasi portrait + landscape |
| S5 | Efek gambar `contain` | FR-02 | | | Letterbox benar |
| S6 | Efek warna solid | FR-03 | | | |
| S7 | `NoEffect` / bypass | FR-04 | | | |
| S8 | Ganti efek saat runtime (blur→image→color→none→blur) | FR-05 | | | No kedip, track tidak restart |
| S9 | Ganti kamera depan/belakang (re-attach), efek bertahan | FR-09 | | | |
| S10 | Rotasi orientasi | FR-09 | | | |
| S11 | App background → foreground | FR-09 | | | No false fallback |
| S12 | `setQuality` / preset low-balanced-high berpengaruh | FR-11 | | | fps/kualitas terukur |
| S13 | Fallback performa (turun kualitas / disable + event) | FR-12 | | | `fallbackStream` terima event |
| S14 | `statusStream` idle→initializing→active→error | FR-07 | | | |
| S15 | Error typed: invalidTrack / invalidImage / modelLoadFailed | FR-08 | | | |
| S16 | `detach` idempoten, kamera masih hidup untuk track asli | FR-06 | | | |
| S17 | `dispose` bersih, kit tidak terpakai lagi | FR-10 | | | |
| S18 | Loop attach/detach 100× tanpa leak/crash | FR-10 | pass | pass | T6.5 |
| S19 | Soak 30 menit: no crash, memori stabil | — | pass | pass | T6.5 |
| S20 | Benchmark 10 menit per efek: fps, latensi, CPU, mem, baterai | §7 | | | T6.2 → `docs/benchmark.md` |

## 3. Cakupan vs PRD

| PRD kelas | Tersedia? | Keterangan |
|-----------|-----------|------------|
| Android low | Ya (A1) | |
| Android mid | **Tidak** | Tidak ada hardware |
| Android high | **Tidak** | Tidak ada hardware |
| iOS high | Ya (I1) | |
| iOS low/mid | **Tidak** | Tidak ada hardware |

Konsekuensi: klaim performa di README/Batasan hanya boleh menyebut dua device di atas;
target "3 kelas perangkat" (metrik keberhasilan §12) **tidak terpenuhi di v0.1**,
dicatat sebagai batasan, bukan disamarkan.

## 4. Pelaksanaan

| Bagian | Pelaksana |
|-------|-----------|
| Sambung device, setup scene (foto/tablet orang), tekan start, verifikasi visual | Human |
| Script benchmark/soak, dump `adb`/log, jalankan integration test, olah hasil ke tabel/docs | Assistant |

Skenario visual (S3–S8, tepi & flicker): human ~2–3 menit per device.  
Sisanya bisa otomatis saat device menyala.
