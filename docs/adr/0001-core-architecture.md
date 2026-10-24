# ADR 0001 — Arsitektur inti mi_virtual_background_kit

Status: Accepted (untuk review)
Tanggal: 24 Oktober 2026
Milestone: M0 — spike dan keputusan teknologi
Angka pendukung: [docs/spike-results.md](../spike-results.md)

## Konteks

Package menerapkan efek latar belakang virtual (blur, gambar, warna solid) pada track
kamera lokal `flutter_webrtc`, on-device penuh, Android + iOS, API Dart hanya control
plane — frame tidak melewati Dart.

Perangkat spike (track ini):

| Perangkat | ABI | OS | Peran |
|---|---|---|---|
| Samsung SM-A135F | `armeabi-v7a` (32-bit saja) | Android 14 (API 34) | Fisik, low-end, device utama |
| iPhone 15 | arm64 | iOS 26.5 | Fisik, hook iOS |
| Emulator `sdk_gphone16k_arm64` | `arm64-v8a` | Android 17 (API 37) | Pembanding latency saja (GL software) |

Kode spike ada di `android/.../spike/`, `ios/.../MiVirtualBackgroundKitPlugin.swift`, dan
`example/` — dihapus sebelum rilis.

## Keputusan

### 1. Titik hook frame: API frame processor bawaan flutter_webrtc

Tanpa fork. Plugin memakai API native yang sudah ada dan terbukti dipakai `livekit_client`
dalam produksi:

- **Android** — `FlutterWebRTCPlugin.sharedSingleton.getLocalTrack(trackId)` →
  `LocalVideoTrack.addProcessor(ExternalVideoFrameProcessing.onFrame)`. Frame diproses di
  capture thread sebelum ke sink.
- **iOS** — `FlutterWebRTCPlugin.sharedSingleton().localTracks[trackId]` →
  `LocalVideoTrack.addProcessing(_:)` (`ExternalVideoProcessingDelegate.onFrame`).

Verifikasi live: Android `attach=true`, 30 fps stabil, toggle on/off terlihat di preview;
iOS `attach=true`, 30 fps stabil, transform terverifikasi visual di device fisik.

Aturan wajib yang terbukti dari desain API ini:

- Cache objek `LocalVideoTrack` saat attach; **jangan** lookup ulang by ID — panggilan
  Dart `stream.getMediaTracks()` menimpa map `localTracks` dengan objek baru yang tidak
  terpasang sebagai processor (silent no-op).
- Dokumentasikan ini sebagai kontrak internal di kode fase implementasi.

### 2. Format frame: GPU texture di kedua platform

- Android: `TextureBufferImpl` tipe `OES`, rotasi 270, 480x640 pada request 640x480.
- iOS: `RTCCVPixelBuffer` (CVPixelBuffer), rotasi 90, 640x480; format piksel
  (BGRA vs YCbCr biplanar) **dideteksi runtime** — asumsi statis terbukti salah pada
  spike pertama (hasil: garis, bukan geser warna).

Konsekuensi: pipeline komposit tetap di GPU; transform berbasis akses byte CPU pada
buffer Android tidak bekerja (bukan I420 CPU).

### 3. Mesin segmentasi: MediaPipe Image Segmenter

Dibandingkan head-to-head di dua perangkat (angka lengkap di spike-results T0.6):

| Kriteria | MediaPipe (`tasks-vision` 0.10.20 + `selfie_segmenter.tflite`) | ML Kit (`segmentation-selfie` 16.0.0-beta6) |
|---|---|---|
| Latensi P1 @640 (median) | 179 ms | **111 ms** (lebih cepat di device ini) |
| Resolusi mask | = resolusi input (256/640/…) | **fixed 256x256** (model baked) |
| Akurasi tepi (overlay) | detail rambut halus @640 | rapi tapi kasar (256) |
| Lisensi | **Apache-2.0** | **ML Kit Terms of Service** (bukan open-source) |
| Ukuran | AAR 18,8 MB + model asset 250 KB | tree ≈ 24,2 MB (model 249 KB bundled) |
| Dependensi privasi | `datatransport` ikut terpasang (belum dinonaktifkan — lihat Risiko) | `datatransport` + `firebase-encoders` + `play-services` |

**Diputuskan: MediaPipe.** Alasan penentu: lisensi Apache-2-0 kompatibel redistribusi
paket MIT (ML Kit ToS tidak), struktur dependensi lebih bersih untuk PRD G4, dan mask
resolusi-independen (ML Kit terkunci 256). Keunggulan latensi ML Kit di P1 dicatat apa
adanya dan tidak mengubah keputusan.

Fakta encoding yang wajib diketahui implementasi: category mask UINT8 dengan
**person=0, background=255** (terbukti histogram) — predicate `!= 0` = terbalik.

Model: `selfie_segmenter.tflite` 249.537 byte, **di-bundle sebagai asset** (tanpa
unduhan runtime), delegate CPU.

### 4. Metode komposit: GPU (wajib)

Hasil T0.7 di P1:

| | 640x480 | 1280x720 |
|---|---|---|
| GPU blur / image | 30 fps, compose 0,9–1,1 ms | 30 fps, compose 1,1–1,2 ms |
| CPU blur (readback + Java) | 76 ms ≈ 13 fps | 253 ms ≈ 4 fps |
| CPU image | 36 ms ≈ 28 fps | 133 ms ≈ 7,5 fps |

Jalur CPU belum termasuk upload texture dan sudah di luar budget 33 ms di kedua
resolusi. Komposit GLES2 dijalankan di capture thread (satu-satunya thread dengan EGL
context yang benar).

Konsekuensi untuk segmentasi: readback per frame di P1 = 5,9 ms @640 / 42 ms @720 —
ditambah latensi MediaPipe 179 ms @640, **segmentasi per-frame penuh tidak mungkin di
kelas low-end 32-bit**. Arah desain: mask dihitung pada resolusi turun / frekuensi
turun, komposit tetap per-frame dengan mask terakhir. Parameter ini masuk FR-11/FR-12
(Fase 5) dan diuji ulang di perangkat kelas menengah (belum tersedia di spike ini).

### 5. Minimum OS

- **Android `minSdk 24`** (sudah di `android/build.gradle.kts`; mengikuti kandidat PRD;
  Camera2 tersedia sejak 21, MediaPipe tasks membutuhkan 24).
- **iOS 13** (mengikuti `flutter_webrtc`; semua iPhone iOS-13 adalah arm64).

### 6. Rentang versi flutter_webrtc

`flutter_webrtc: ^1.6.2`, teruji pada `1.6.2+hotfix.4` (kedua platform).

Titik hook adalah API internal (bukan kontrak publik semver). Konsekuensi: rentang
dipin ketat, uji batas bawah/atas di CI (T6.4), dan pesan error yang jelas bila API
berubah. Bila versi berikutnya memutus hook, package harus membatasi rentang di
`pubspec.yaml` sampai penyesuaian.

### 7. Format paket dan workaround build

Satu plugin (folder `android/` + `ios/`), `Package.swift` dan `.podspec` keduanya
disediakan (mengikuti `flutter_webrtc`; aplikasi pengguna bisa memakai SPM maupun
CocoaPods).

Catatan build: Flutter < 3.48 menyalin isi package plugin (termasuk `example/build`)
rekursif via rsync saat build iOS SPM — repo memakai `tool/link_example_build.sh`
(menautkan `example/build` ke luar repo) sampai fix upstream (flutter/flutter#188647,
Flutter 3.48) tersedia.

### 8. Lisensi

- Kode: **MIT** (file `LICENSE`).
- Model segmentasi: **Apache-2.0** — kompatibel dengan redistribusi dalam paket MIT.

## Alternatif yang ditolak

- **Fork/patch flutter_webrtc** — menolak: biaya maintenance; API processor bawaan
  sudah terbukti cukup (pola sama dipakai LiveKit).
- **Komposit CPU** — menolak: 76 ms/frame @640, 253 ms @720 (T0.7), mustahil 30 fps.
- **ML Kit Selfie Segmentation** — menolak: lisensi ToS non-open-source, mask fixed
  256, dependensi telemetri Google (T0.6). Latensi lebih cepat di P1 tidak
  mengimbangi tiga hal itu.
- **Akses byte CPU / `toI420()` sebagai jalur utama** — menolak: buffer Android GPU
  OES, bukan I420 CPU; konversi readback mahal (5,9–42 ms).
- **Unduh model saat runtime** — menolak: melanggar G4 dan menambah kegagalan offline;
  model 250 KB cukup kecil untuk bundling.

## Risiko dan mitigasi

- **API hook internal flutter_webrtc** bisa berubah tanpa semver — pin `^1.6.2`, uji
  batas versi di CI, error jelas saat attach gagal.
- **`datatransport` masih aktif di classpath** (ikut MediaPipe). `disableTransportNetwork()`
  di spike saat ini **hanya logging, belum menonaktifkan scheduler** — wajib diimplementasikan
  sebelum rilis (Fase 3) dan diverifikasi tanpa panggilan jaringan.
- **Perangkat 32-bit (P1) tidak real-time untuk segmentasi per-frame** — desain
  fallback frekuensi/resolusi turun (FR-11/FR-12); kelas menengah belum diuji, angka
  spike hanya mewakili low-end.
- **Encoding mask MediaPipe person=0** berbeda konvensi umum — unit test overlay/compositing
  wajib memverifikasi arah mask.
- **Kebocoran resource** pada attach/detach berulang — diuji di T3.7/T6.5.
