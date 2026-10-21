# ADR 0001 — Arsitektur inti mi_virtual_background_kit

Status: Accepted
Tanggal: 21 Oktober 2026
Milestone: M0 (spike dan keputusan teknologi)

## Konteks

`mi_virtual_background_kit` menerapkan efek latar belakang virtual (blur, gambar, warna solid)
pada track kamera lokal milik `flutter_webrtc`, sepenuhnya on-device, di Android dan iOS.

Spike dilakukan di dua perangkat nyata dan satu emulator:

| Perangkat | ABI | Kamera | OS |
|---|---|---|---|
| Samsung SM A135F | `armeabi-v7a` (32-bit saja) | Ya | Android 14 (API 34) |
| iPhone 15 | arm64 | Ya | iOS 26.5 |
| Android Emulator Pixel 8a | `arm64-v8a` | Ya (sintetis) | Android 16 (API 37) |

Kode spike ada di `spikes/` dan tidak ikut rilis.

## Keputusan

### 1. Titik hook frame: API frame processor bawaan flutter_webrtc

Tidak perlu fork atau patch `flutter_webrtc`. Plugin ini memakai API yang sudah ada di kedua
platform dan sudah dipakai oleh `livekit_client`.

**Android** — `com.cloudwebrtc.webrtc.video.LocalVideoTrack` mengimplementasikan
`org.webrtc.VideoProcessor` dan mengekspos `addProcessor(ExternalVideoFrameProcessing)`.
Track lokal bisa dicari lewat
`FlutterWebRTCPlugin.sharedSingleton.getLocalTrack(trackId)`.

**iOS** — `LocalVideoTrack` mengekspos `addProcessing(_:)` dengan protokol
`ExternalVideoProcessingDelegate`, yang mengembalikan `RTCVideoFrame` yang sudah diproses.
Track lokal ada di `FlutterWebRTCPlugin.sharedSingleton().localTracks[trackId]`.

Hasil verifikasi:

- Android: 1.500+ frame per detik_detik, komposit GPU 0,8–1,3 ms per frame, 30 fps stabil.
- iOS: 4.920 frame diproses pada 640x480, buffer `RTCCVPixelBuffer`, rotasi 90.

**Konsekuensi:** rentang versi `flutter_webrtc` yang didukung harus memuat API ini.
Rentang yang diuji: `1.6.2` sampai `1.6.2+hotfix.4`.

### 2. Format frame: GPU texture di kedua platform

Kamera dari `flutter_webrtc` mengirim frame sebagai texture GPU, bukan piksel CPU:

- Android: `org.webrtc.TextureBufferImpl` dengan tipe `OES` (external OES texture).
- iOS: `RTCCVPixelBuffer` (CVPixelBuffer).

Artinya pipeline tetap di GPU dan tidak perlu readback untuk komposit.

### 3. Metode komposit: GPU

Pengukuran pada SM A135F (640x480):

| Operasi | Waktu |
|---|---|
| `VideoFrame.buffer.toI420()` (readback penuh) | 92.259 µs… 30.332 µs (variance tinggi, jalankan ulang 30 ms) |
| `glReadPixels` dari texture (RGBA) | 289–647 µs |
| Komposit GLES2 (texture → FBO → texture) | 772–1.728 µs |

Kesimpulan: `toI420()` terlalu lambat dan tidak stabil untuk dipakai di loop video.
Komposit GLES2 pada 1 ms memenuhi target 30 fps dengan sisa budget besar.

Untuk segmentasi, `glReadPixels` 0,3–0,6 ms sudah cukup untuk memberi CPU satu frame.

### 4. Mesin segmentasi: MediaPipe Image Segmenter

Dua kandidat diuji, keduanya memakai model `selfie_segmenter.tflite` (250 KB, Apache-2.0).

**ML Kit Selfie Segmentation ditolak.** AAR-nya menarik
`com.google.android.datatransport:transport-*` dan `com.google.firebase:firebase-encoders`.
`MlKitInitProvider` gagal saat inisialisasi bila pustaka itu dihapus dari classpath, dan
mempertahannya berarti aplikasi membuka jalan ke telemetri Google. Ini bertabrakan dengan
PRD G4 (on-device, tanpa jaringan, tanpa telemetri).

**MediaPipe Image Segmenter dipakai.** Native library-nya tidak melakukan panggilan
jaringan; `transport-runtime` hanya dibutuhkan agar kelasnya ada di classpath dan tidak
dipakai untuk apa pun selain log opsional.

Hasil pengukuran latensi inferensi (CPU delegate, 1st run termasuk inisialisasi model):

| Input | arm64 (Pixel 8a) | armeabi-v7a (SM A135F) |
|---|---|---|
| 640x480 | 11–14 ms | 170–190 ms |
| 256x192 | 10,5 ms | 174 ms |
| 144x108 | 6,3 ms | 128 ms |
| 96x72 | 2,9 ms | 115 ms |

GPU delegate (`Delegate.GPU`) untuk segmenter **crash** di SM A135F (32-bit) dan tidak
dipakai.

Kesimpulan: latensi segmentasi ditentukan arsitektur, bukan resolusi. Di arm64, input
256x192 cukup untuk 10 ms, jadi segmentasi per frame memungkinkan. Di perangkat 32-bit,
segmen harus berjalan pada frekuensi rendah atau di fallback.

### 5. Minimum OS dan batasan perangkat

- Android: `minSdk 24`, `compileSdk 36`. Agensi `armeabi-v7a` saja di perangkat 32-bit
  akan berjalan, tetapi segmentasi orang tidak memenuhi real-time. Deteksi ABI 32-bit
  dan pengurangan frekuensi segmentasi masuk daftar pekerjaan v0.2.
- iOS: `minSdk 13` mengikuti `flutter_webrtc`. Semua iPhone yang didukung iOS 13
  adalah arm64.

### 6. Format paket: satu plugin, SPM dan CocoaPods

Satu plugin dengan folder `android/` dan `ios/`.

`ios/mi_virtual_background_kit/Package.swift` dan `ios/mi_virtual_background_kit.podspec`
keduanya disediakan. Alasannya: `flutter_webrtc` menyediakan keduanya, dan aplikasi
pengguna bisa berada di salah satu dari kedua manager.

Masalah yang ditemukan: Flutter sebelum 3.48 menyalin seluruh isi package plugin ke
`example/build/ios/SourcePackages/` dengan `rsync` tanpa filter. Karena `example/` ada
di dalam repo plugin, salinan itu rekursif dan `example/build` tumbuh tanpa batas
(teramati 24 GB). Perbaikan upstream ada di flutter/flutter#188647
(`--exclude=/example/`) dan sudah masuk Flutter 3.48.

Sejak Flutter 3.48 belum rilis, repo ini menyertakan
`tool/link_example_build.sh` yang menautkan `example/build` ke direktori di luar repo.
Link simbolik disalin rsync sebagai link, sehingga salinan tetap berhingga.

### 7. Rentang versi `flutter_webrtc`

`flutter_webrtc: ^1.6.2` (teruji sampai `1.6.2+hotfix.4`).

### 8. Lisensi

MIT untuk kode plugin. Model `selfie_segmenter.tflite` milik Google, lisensi Apache-2.0,
kompatibel untuk redistribusi. Model di-_bundle_ sebagai asset (250 KB) supaya tidak ada
unduhan saat runtime dan tidak ada dependensi jaringan.

## Alternatif yang ditolak

- **Fork `flutter_webrtc`** agar bisa hook frame. Menolak: biaya maintenance tinggi dan
  API frame processor yang ada sudah cukup.
- **Komposit di CPU** (bitmap + Canvas). Menolak: readback `toI420()` 30–92 ms per frame.
- **ML Kit Selfie Segmentation.** Menolak: menarik stack telemetri, crash saat dihapus.
- **Segmentasi di thread terpisah dengan buffer antrean.** Diterima sebagian: mask boleh
  dihitung lebih sering dari komposit, jadi segmentasi berjalan pada thread sendiri dan
  komposit memakai mask terakhir yang tersedia. Detail implementasi di v0.2.
- **Unduh model saat runtime.** Menolak: melanggar prinsip tanpa jaringan dan menambah
  ukuran APK. Model 250 KB cukup kecil untuk di-_bundle_.

## Risiko

- API frame processor `flutter_webrtc` bersifat internal (bukan bagian dari API publik
  yang dijanjikan). Perubahan pada versi berikutnya dapat mematahkan hook. Mitigasi:
  kunci rentang versi, uji batas bawah dan atas, dan sediakan pesan error yang jelas.
- `transport-runtime` masih ada di classpath karena MediaPipe membutuhkannya. Yang
  dijamin adalah tidak ada kode dari kit yang memanggil jaringan. Logging opsional
  MediaPipe perlu dimatikan lewat API resminya sebelum rilis.
- Performa segmentasi pada perangkat 32-bit tidak mencapai real-time. Perlu strategi
  fallback yang jelas dan event ke Dart.
