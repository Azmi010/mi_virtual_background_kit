# Hasil spike Fase 0

Semua angka diukur di perangkat nyata kecuali yang ditandai emulator.
Kode spike ada di `spikes/` dan `android/src/main/kotlin/.../spike/` (dihapus sebelum rilis).

## Perangkat uji

| ID | Perangkat | ABI | OS | Catatan |
|---|---|---|---|---|
| D1 | Samsung SM A135F | `armeabi-v7a` (32-bit saja) | Android 14 | Perangkat low-end, kelas bawah |
| D2 | iPhone 15 | arm64 | iOS 26.5 | Perangkat nyata, tanpa kabel (wireless) |
| D3 | Emulator Pixel 8a | `arm64-v8a` | Android 16 | GL software (swiftshader), bukan GPU asli |

## T0.4 — Hook frame Android

Titik hook: `LocalVideoTrack.addProcessor(ExternalVideoFrameProcessing)` yang diambil lewat
`FlutterWebRTCPlugin.sharedSingleton.getLocalTrack(trackId)`.

Hasil:

```
MiVBGSpike: first frame buffer=org.webrtc.TextureBufferImpl rot=270 size=480x640
SPIKE frames=1804 fps=30 buffer=org.webrtc.TextureBufferImpl rot=270 size=480x640
```

Kesimpulan: hook bekerja, frame sampai ke renderer, 30 fps stabil, buffer berupa texture GPU.

## T0.5 — Hook frame iOS

Titik hook: `LocalVideoTrack.addProcessing(_:)` lewat
`FlutterWebRTCPlugin.sharedSingleton().localTracks[trackId]`.

Hasil (file marker di app container, dibaca dengan `xcrun devicectl device copy from`):

```
frames=4920 buffer=RTCCVPixelBuffer rot=90 size=640x480
```

Kesimpulan: hook bekerja, buffer berupa `RTCCVPixelBuffer` (CVPixelBuffer), 640x480 rotasi 90.

## T0.7 — Komposit GPU dibanding CPU (D1)

| Operasi | Waktu | Catatan |
|---|---|---|
| `VideoFrame.buffer.toI420()` | 30–92 ms | tidak stabil, terlalu lambat |
| `glReadPixels` RGBA dari texture | 289–647 µs | cukup untuk segmentasi |
| Komposit GLES2 (texture → FBO → texture) | 772–1.728 µs | 30 fps tetap stabil |
| Shader写出 warna solid ke texture | 1,1 ms | frame penuh menyala merah di layar |

Kesimpulan: komposit wajib di GPU. CPU tidak mungkin karena readback 30–92 ms.

## T0.6 — Mesin segmentasi

Model: `selfie_segmenter.tflite` (MediaPipe, 250 KB, Apache-2.0), input 640x480.

### MediaPipe Image Segmenter, CPU delegate

| Input | D3 (arm64) | D1 (armeabi-v7a) |
|---|---|---|
| 640x480 | 11–14 ms | 170–190 ms |
| 256x192 | 10,5 ms | 174 ms |
| 144x108 | 6,3 ms | 128 ms |
| 96x72 | 2,9 ms | 115 ms |

### MediaPipe Image Segmenter, GPU delegate

Crash di D1. Tidak dipakai.

### ML Kit Selfie Segmentation

Ditolak sebelum benchmark karena dependensinya:

```
com.google.android.datatransport:transport-api
com.google.android.datatransport:transport-backend-cct
com.google.android.datatransport:transport-runtime
com.google.firebase:firebase-encoders
com.google.firebase:firebase-encoders-json
com.google.firebase:firebase-encoders-proto
```

Menghapus `datatransport` dan `firebase` dari classpath membuat `MlKitInitProvider` gagal
saat aplikasi start:

```
E AndroidRuntime: at com.google.mlkit.common.sdkinternal.MlKitContext.zzb(common@@18.11.0:3)
E AndroidRuntime: at com.google.mlkit.common.internal.MlKitInitProvider.onCreate(common@@18.11.0:3)
```

Kesimpulan: ML Kit tidak bisa dipakai tanpa stack telemetri Google, bertentangan dengan
PRD G4. MediaPipe dipakai.

## Temuan blocking lain

### Flutter menyalin package plugin secara rekursif

`flutter build ios` untuk plugin yang punya `ios/Package.swift` menyalin seluruh isi package
ke `example/build/ios/SourcePackages/<nama>/` dengan `rsync -8 -av --delete` tanpa filter.
Karena `example/` ada di dalam repo plugin, `example/build` ikut tersalin secara rekursif.
Teramati `example/build` tumbuh sampai 24 GB dan build berikutnya gagal.

Perbaikan upstream: flutter/flutter#188647 menambahkan `--exclude=/example/`, masuk Flutter 3.48.
Flutter 3.48 belum rilis, jadi repo ini memakai `tool/link_example_build.sh` yang menautkan
`example/build` ke direktori di luar repo. `rsync` menyalin link simbolik sebagai link,
sehingga salinannya tetap berhingga.

## Ringkasan angka untuk batas performansi

- Komposit GPU: 1 ms per frame pada 640x480 di perangkat low-end. Batas aman 5 ms.
- Readback untuk segmentasi: 0,3–0,6 ms. Batas aman 2 ms.
- Segmentasi (arm64): 10 ms pada 256x192. Batas aman 15 ms.
- Segmentasi (32-bit): 115 ms minimum. Tidak real-time, butuh strategi frekuensi rendah.
