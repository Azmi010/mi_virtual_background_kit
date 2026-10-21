# PRD — mi_virtual_background_kit

Draft v0.1 · 20 Oktober 2026 · Status: draft untuk review

Daftar task detail ada di [TASKS.md](TASKS.md).

## 1. Ringkasan

`mi_virtual_background_kit` adalah package Flutter open-source untuk menerapkan efek latar belakang virtual (blur, gambar, warna solid) pada video kamera secara real-time di aplikasi video call atau konferensi berbasis WebRTC. Package diterbitkan di pub.dev dengan target awal Android dan iOS.

## 2. Latar belakang dan masalah

- Developer Flutter yang membangun aplikasi video call kesulitan menemukan package virtual background yang aktif dirawat, mendukung Android dan iOS, serta tidak terkunci ke satu vendor.
- Opsi yang tersedia umumnya fitur bawaan SDK vendor tertentu (sering tertutup atau berbayar), atau implementasi native buatan sendiri yang rumit: segmentasi orang, manajemen frame, threading, dan komposit.
- Akibatnya tiap tim menulis ulang pekerjaan yang sama, dan hasilnya sulit dirawat.

Package ini menyediakan lapisan yang fokus pada satu masalah: memproses frame kamera lokal agar latar belakangnya diganti, dengan API Dart yang sederhana.

## 3. Tujuan dan non-tujuan

### Tujuan

- G1: Menyediakan efek blur, gambar, dan warna solid yang bisa diganti saat runtime tanpa memutus kamera.
- G2: Bekerja dengan track kamera dari `flutter_webrtc`, sehingga bisa dipakai di app WebRTC apa pun.
- G3: Tetap bisa dipakai oleh pengguna LiveKit (yang berdiri di atas `flutter_webrtc`) lewat panduan atau adapter tipis.
- G4: Pemrosesan sepenuhnya on-device: tanpa jaringan, tanpa telemetri.
- G5: Performa cukup untuk video call nyata di perangkat kelas menengah.
- G6: Siap dipakai orang lain: dokumentasi jelas, example berjalan, skor pub.dev tinggi.

### Non-tujuan (versi awal)

- Bukan SDK video call: tidak ada signaling, room, atau transport.
- Tidak menyediakan hosting atau penyimpanan library gambar background. Gambar diberikan oleh aplikasi pengguna.
- Tidak mencakup noise suppression, filter wajah/AR, atau beauty filter.
- Web dan desktop tidak didukung di v0.1.
- Tidak memproses video remote, hanya track kamera lokal.

## 4. Pengguna target dan skenario

- P1, developer app video call berbasis `flutter_webrtc` (P2P, mediasoup, Janus, signaling custom).
- P2, developer yang memakai LiveKit untuk Flutter.
- P3, developer yang membuat prototipe atau demo dan butuh efek background cepat.

User stories:

- Sebagai developer, saya ingin memasang efek ke track kamera dengan beberapa baris kode.
- Sebagai developer, saya ingin mengganti efek (blur ke gambar ke tanpa efek) saat meeting berlangsung tanpa kamera berkedip atau restart.
- Sebagai developer, saya ingin tahu apakah perangkat mendukung fitur ini dan mendapat event ketika performa turun.
- Sebagai developer, saya ingin memasok gambar dari asset, file, atau bytes (mis. hasil unduhan dari backend saya).
- Sebagai pengguna akhir, saya ingin latar belakang saya tersamar atau diganti tanpa video menjadi patah-patah.

## 5. Ruang lingkup dan roadmap versi

### v0.1.0 (MVP)

- Android dan iOS.
- Efek: blur, gambar statis, warna solid, tanpa efek (bypass).
- Attach/detach ke track `flutter_webrtc`; ganti efek saat runtime.
- Status dan error lewat stream; `isSupported()`.
- Penanganan lifecycle dasar (ganti kamera, rotasi, app ke background).
- Example app mandiri, README, dokumentasi API, CI.
- Panduan integrasi LiveKit di README (resep, bukan dependensi).

### v0.2.0

- Adapter atau helper LiveKit (paket terpisah atau modul opsional).
- Parameter kualitas: resolusi segmentasi, edge smoothing, target fps.
- Fallback performa adaptif.
- Widget preview opsional.

### v0.3.0

- Background video atau animasi.
- Evaluasi dukungan package `camera`.

### v1.0.0

- API stabil dan terdokumentasi lengkap, teruji di beragam perangkat, jejak issue sehat.
- Evaluasi web dan desktop.

## 6. Kebutuhan fungsional

- FR-01 Efek blur dengan radius yang dapat diatur.
- FR-02 Efek gambar: sumber dari asset, file path, atau bytes; mode fit (cover, contain).
- FR-03 Efek warna solid.
- FR-04 Tanpa efek (bypass) tanpa overhead pemrosesan berarti.
- FR-05 Ganti efek saat runtime tanpa menghentikan atau membuat ulang track kamera.
- FR-06 `attach` ke track kamera lokal dan `detach` bersih, termasuk dipanggil berulang tanpa crash.
- FR-07 Status prosesor (idle, initializing, active, error) tersedia sebagai `Stream`.
- FR-08 Error terdefinisi dengan tipe jelas: platform tidak didukung, model gagal dimuat, track tidak valid, gambar tidak valid.
- FR-09 Tahan terhadap pergantian kamera depan/belakang, rotasi orientasi, mirror, dan transisi app foreground/background.
- FR-10 `dispose` melepas semua resource native tanpa kebocoran memori.
- FR-11 Konfigurasi kualitas: resolusi input segmentasi, edge smoothing, target fps.
- FR-12 Fallback: jika perangkat tidak sanggup, turunkan kualitas atau nonaktifkan efek dan kirim event.
- FR-13 `isSupported()` untuk mengecek dukungan perangkat dan OS.

## 7. Kebutuhan non-fungsional

Angka di bawah adalah target awal yang divalidasi lewat benchmark pada fase pengujian.

- Performa: mempertahankan 24–30 fps pada resolusi 640×480 hingga 720p di perangkat kelas menengah; tambahan latency per frame dicatat dan dipublikasikan di README. Target diukur di spike: komposit GPU 1 ms per frame pada 640×480 di perangkat low-end 32-bit.
- Resource: penggunaan CPU, memori, dan baterai diukur dan dilaporkan di bagian "Batasan".
- Ukuran: model dan dependensi native tidak membengkakkan ukuran app secara berlebihan; model besar dibuat opsional atau diunduh saat runtime. Model segmentasi yang dipakai `selfie_segmenter.tflite` berukuran 250 KB dan di-_bundle_ sebagai asset, tanpa unduhan saat runtime.
- Privasi: semua pemrosesan on-device, tanpa panggilan jaringan, tanpa telemetri. Mesin segmentasi MediaPipe dipilih karena ML Kit Selfie Segmentation menarik `datatransport` dan `firebase` sehingga tidak bisa dibuang dari classpath tanpa membuat aplikasi gagal start.
- Kompatibilitas: rentang versi `flutter_webrtc` yang didukung dinyatakan eksplisit dan diuji di batas bawah dan atas. Rentang yang diuji pada spike: `1.6.2` sampai `1.6.2+hotfix.4`.
- Versi OS minimum: ditetapkan setelah spike (kandidat: Android minSdk 24, iOS 13). Ditetapkan pada spike: Android minSdk 24, iOS 13.
- Kualitas kode: `flutter analyze` tanpa peringatan; target pub points maksimum.
- Lisensi: MIT untuk kode plugin (lihat [ADR 0001](docs/adr/0001-core-architecture.md)); lisensi model segmentasi harus kompatibel dengan redistribusi.

## 8. Draft API publik

Bentuk final ditetapkan setelah spike teknis.

```dart
import 'package:mi_virtual_background_kit/mi_virtual_background_kit.dart';

final kit = MiVirtualBackgroundKit();

if (await MiVirtualBackgroundKit.isSupported()) {
  // Pasang ke track kamera lokal dari flutter_webrtc
  await kit.attach(localVideoTrack);

  // Ganti efek saat runtime
  await kit.setEffect(const BlurEffect(radius: 12));
  await kit.setEffect(ImageEffect.asset('assets/office.jpg'));
  await kit.setEffect(ImageEffect.bytes(bytes, fit: BackgroundFit.cover));
  await kit.setEffect(const ColorEffect(Color(0xFF0E1114)));
  await kit.setEffect(const NoEffect());

  kit.statusStream.listen((status) { /* idle, initializing, active, error */ });
}

await kit.detach();
await kit.dispose();
```

Prinsip desain API:

- Efek adalah `sealed class` (`BlurEffect`, `ImageEffect`, `ColorEffect`, `NoEffect`) agar mudah diperluas dan aman di `switch`.
- Permukaan publik dibuat sekecil mungkin; implementasi berada di `lib/src/`.
- Gambar dikirim sebagai bytes ke native; Dart tidak pernah menangani frame video.

### Bentuk final setelah spike (21 Oktober 2026)

Bentuk di atas tetap, dengan penyesuaian berikut hasil spike (lihat
[ADR 0001](docs/adr/0001-core-architecture.md)):

- `attach` menerima `MediaStreamTrack` dari `flutter_webrtc`, bukan objek kit sendiri.
  Hook native mencari track lewat `track.id` di registry `flutter_webrtc`.
- `isSupported()` menjadi instance method (`kit.isSupported()`), karena kelayakan dukungan
  bergantung pada perangkat dan kapabilitas GPU, bukan hanya versi OS.
- Ditambah parameter kualitas pada `attach`, karena spike menunjukkan latensi segmentasi
  berbeda jauh antara perangkat arm64 (10 ms) dan 32-bit (115 ms):

  ```dart
  await kit.attach(
    localVideoTrack,
    quality: const BackgroundQuality(
      segmentationWidth: 256,   // lebar input segmentasi
      edgeSmoothing: 0.5,        // 0..1
      targetFps: 30,             // fps komposit
    ),
  );
  ```

- Ditambah `BackgroundFit` (`cover`, `contain`) dan enum `BackgroundQualityPreset`
  (`low`, `balanced`, `high`) sebagai jalan pintas ke nilai `BackgroundQuality`.
- `statusStream` tetap, dan setiap error membawa kode yang jelas (FR-08):
  `unsupportedPlatform`, `modelLoadFailed`, `invalidTrack`, `invalidImage`.
- `setEffect` bersifat idempoten dan tidak boleh membuat ulang track kamera (FR-05).
  Efek baru dikirim ke native sebagai descriptor; native yang memutuskan kapan
  menerapkannya pada frame berikutnya.
- Semua efek pada v0.1 memerlukan segmentasi orang, kecuali `NoEffect` yang benar-benar
  melewati seluruh pipeline.

## 9. Arsitektur

Prinsip utama: Dart hanya sebagai control plane. Frame video tidak melewati Dart.

```
Aplikasi pengguna
   │  (API Dart: attach, setEffect, detach)
   ▼
mi_virtual_background_kit (Dart)
   │  method channel + event channel
   ▼
Native (Android Kotlin / iOS Swift)
   ├─ Frame processor (hook ke pipeline flutter_webrtc)
   ├─ Segmenter (model segmentasi orang)
   └─ Compositor (blur / gambar / warna)
```

Keputusan teknis yang ditetapkan lewat spike (detail di
[ADR 0001](docs/adr/0001-core-architecture.md), angka di
[docs/spike-results.md](docs/spike-results.md)):

- Titik pemasangan prosesor frame: API frame processor bawaan `flutter_webrtc` di kedua
  platform, tanpa fork. Android memakai `LocalVideoTrack.addProcessor`, iOS memakai
  `LocalVideoTrack.addProcessing(_:)`. Rentang versi yang diuji `1.6.2` sampai
  `1.6.2+hotfix.4`.
- Mesin segmentasi: **MediaPipe Image Segmenter** dengan model `selfie_segmenter.tflite`
  (250 KB, Apache-2.0, di-_bundle_ sebagai asset). ML Kit Selfie Segmentation ditolak
  karena menarik stack `datatransport` dan `firebase` yang tidak bisa dibuang dari
  classpath tanpa membuat aplikasi gagal start.
- Metode komposit: **GPU**. Spike mengukur komposit GLES2 1 ms per frame pada 640×480 di
  perangkat low-end, sedangkan readback ke CPU lewat `toI420()` memakan 30–92 ms dan tidak
  bisa dipakai. Komposit Android memakai OpenGL ES 2, iOS memakai Metal atau Core Image.
- Format frame: hook menerima frame sebagai texture GPU (`TextureBufferImpl` di Android,
  `RTCCVPixelBuffer` di iOS), sehingga pipeline tidak perlu readback untuk komposit.
- Batasan perangkat: segmentasi di arm64 memerlukan 10 ms pada input 256×192, sedangkan
  di perangkat 32-bit memerlukan 115 ms. Perlu strategi frekuensi segmentasi dan fallback
  untuk perangkat 32-bit.
- Format paket: satu plugin (dengan folder `android/` dan `ios/`) pada v0.1; pertimbangkan
  federated plugin jika web atau desktop ditambahkan. iOS menyediakan `Package.swift` dan
  `.podspec` sekaligus.

## 10. Platform dan dependensi

- Flutter dan Dart: rentang SDK dinyatakan di `pubspec.yaml`.
- Dependensi Dart: `flutter_webrtc` (rentang versi eksplisit), `plugin_platform_interface`.
- Dependensi native: mesin segmentasi terpilih (Android: Gradle; iOS: CocoaPods dan/atau Swift Package Manager).
- Dependensi LiveKit tidak dimasukkan ke package inti pada v0.1.

## 11. Struktur repo

```
mi_virtual_background_kit/
  lib/
    mi_virtual_background_kit.dart   // export API publik
    src/
      effects/
      status/
      platform/                      // method channel
  android/                           // Kotlin
  ios/                               // Swift
  example/                           // app demo mandiri
  test/
  docs/                              // arsitektur, benchmark, ADR
  .github/workflows/                 // CI dan publish otomatis
  README.md  CHANGELOG.md  LICENSE
```

## 12. Metrik keberhasilan

- Pub points maksimum saat rilis pertama.
- Example berjalan dari nol di perangkat bersih hanya dengan mengikuti README.
- Waktu respons issue pertama kurang dari 72 jam pada bulan pertama.
- Pertumbuhan likes, downloads, dan pemakaian nyata (issue dan PR dari pengguna lain).
- Benchmark performa dipublikasikan untuk sedikitnya tiga kelas perangkat.

## 13. Risiko dan mitigasi

- Hook frame di `flutter_webrtc` tidak tersedia atau berubah antarversi: lakukan spike lebih dulu, kunci rentang versi, uji di batas bawah dan atas, dan siapkan CI yang menguji beberapa versi.
- Performa buruk di perangkat low-end: sediakan fallback adaptif, parameter kualitas, dan dokumentasikan batasan secara jujur.
- Lisensi atau ukuran model: pilih model dengan lisensi permisif; model opsional atau diunduh saat runtime.
- Perilaku berbeda antara Android dan iOS (orientasi, mirror, color space): test matrix per platform dan example sebagai alat uji visual.
- Beban maintenance: batasi cakupan v0.1, tulis kontribusi dan template issue, otomatisasi CI dan publish.
- Kebocoran memori atau crash native: uji siklus attach/detach berulang dan profiling memori.

## 14. Milestone

- M0, Spike dan keputusan teknologi (hook frame, segmentasi, komposit).
- M1, Scaffolding dan inti Dart.
- M2, Android berfungsi (blur, gambar, warna).
- M3, iOS berfungsi (paritas dengan Android).
- M4, Stabilitas dan lifecycle, benchmark.
- M5, Dokumentasi, example, CI, kesiapan publish.
- M6, Rilis v0.1.0 dan pengumuman.
