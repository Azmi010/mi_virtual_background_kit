# Hasil spike Fase 0

Semua angka berasal dari run di track pengerjaan ini (Oktober 2026), kecuali yang
ditandai emulator. Kode spike ada di `android/src/main/kotlin/.../spike/`,
`ios/.../MiVirtualBackgroundKitPlugin.swift`, dan `example/` (dihapus sebelum rilis).

## Perangkat uji

| ID | Perangkat | ABI | OS | Peran |
|---|---|---|---|---|
| P1 | Samsung SM-A135F (RR8T601FP0R) | `armeabi-v7a` (32-bit saja) | Android 14 (SDK 34) | Fisik, kelas low-end, device utama |
| P2 | iPhone 15 (00008120-0016195A0CC20032) | arm64 | iOS 26.5 | Fisik, spike iOS (T0.5) |
| E1 | Emulator `sdk_gphone16k_arm64` (emulator-5554) | `arm64-v8a` | Android 17 (SDK 37) | Pembanding saja — GL software (swiftshader), angka latency tidak representatif |

Metode umum: benchmark dijalankan otomatis sekali per launch example (flag
`_benchmarked`), input = frame kamera nyata lewat readback GPU 640x480. Tiap engine:
jalur ber-skala dulu (256/144/96) sebagai warmup, lalu 3 run ber-timing pada 640x480.

## T0.4 — Hook frame Android (P1)

Titik hook: `LocalVideoTrack.addProcessor(ExternalVideoFrameProcessing)` yang diambil
lewat `FlutterWebRTCPlugin.sharedSingleton.getLocalTrack(trackId)`.

Hasil live:

```
SPIKE attach=true trackId=42f95020-...
first frame buffer=org.webrtc.TextureBufferImpl rot=270 size=480x640
SPIKE frames=... fps=27..31 gpu=717..1795us type=OES (stabil >1 menit)
```

- Buffer masuk berupa texture GPU (`TextureBufferImpl`, tipe OES), bukan I420 CPU.
  Transform berbasis akses byte CPU pada buffer ini tidak akan bekerja.
- Toggle enable/disable terverifikasi visual di preview (merah on ↔ normal off).
- Komposit spike (GLES2, texture → FBO → texture) ±0,8–1,7 ms per frame @640x480,
  30 fps tetap stabil (angka insidental dari log timer; pengukuran resmi T0.7 menyusul).

Aturan desain yang terbukti perlu (dari riset API + pola LiveKit):

- Cache objek `LocalVideoTrack` saat attach; jangan lookup ulang by ID — panggilan
  Dart `stream.getMediaTracks()` menimpa map `localTracks` dengan objek baru yang
  tidak terpasang sebagai processor.
- Pin versi `flutter_webrtc` (API native ini tidak terlindungi semver).

## T0.5 — Hook frame iOS (P2)

Titik hook: `LocalVideoTrack.addProcessing(_:)` lewat
`FlutterWebRTCPlugin.sharedSingleton().localTracks[trackId]`.

Hasil live:

```
SPIKE attach=true trackId=FA4B3E0A-...
buffer=RTCCVPixelBuffer rot=90 size=640x480, 30 fps stabil
```

Temuan: transform pertama (asumsi BGRA, stride setengah pixel) menghasilkan
garis-garis halus. Perbaikan: deteksi format runtime
(`CVPixelBufferGetPixelFormatType`), branch BGRA (swap R/B tiap pixel) vs YCbCr
biplanar (swap pasangan Cb/Cr di plane 1, luma tidak disentuh), cek status lock.
Verifikasi visual di device: geser warna rapi tanpa garis saat enable, normal saat
disable. Format FourCC di-log di frame pertama (device console tidak di-capture,
verifikasi via perilaku visual).

## T0.6 — Mesin segmentasi

Kandidat sesuai PRD: **MediaPipe Image Segmenter** vs **ML Kit Selfie Segmentation**.

- MediaPipe: `com.google.mediapipe:tasks-vision:0.10.20` + asset
  `selfie_segmenter.tflite` (249.537 byte) di app, delegate CPU.
- ML Kit: `com.google.mlkit:segmentation-selfie:16.0.0-beta6`, mode
  `SINGLE_IMAGE_MODE` + `enableRawSizeMask`, API async — timing = wall time
  call-to-result, dijalankan di thread background (lihat "Temuan blocking").

### Latensi — P1 (fisik, 640x480 → mask)

| Engine | Input 640 (3 run, ms) | Median | Input 256 | Input 144 | Input 96 |
|---|---|---|---|---|---|
| MediaPipe | 155 / 182 / 179 | **179** | 174 | 123 | 122 |
| ML Kit* | 115 / 111 / 81 | **111** | 292† | 73 | 90 |

\* Mask ML Kit selalu 256x256 berapa pun input — model fixed.
† Termasuk panggilan pertama sesi (init model); run pertama sesi sebelumnya
tercatat 417–610 ms. Steady state ML Kit 80–140 ms.

Catatan: angka ML Kit lebih cepat di device ini, TAPI mask-nya fixed 256x256
(kualitas tepi lebih kasar dari input 640). MediaPipe mask = resolusi input.

### Latensi — E1 (emulator, pembanding saja)

| Engine | Input 640 (3 run, ms) | Input 256 | Input 144 | Input 96 |
|---|---|---|---|---|
| MediaPipe | 17 / 17 / 17 | 11,4 | 3,8 | 4,1 |
| ML Kit | 3,3 / 25,9 / 7,3 | 173† | 5,5 | 9,7 |

† Init pertama di sesi emulator.

### Resolusi dan encoding mask

- MediaPipe: `categoryMask` UINT8, ukuran = resolusi input (640x480 @ input 640).
  Encoding empiris **person=0, background=255** — dibuktikan histogram pada frame
  tanpa orang (semua 255) dan frame berwajah (v0=120.526, v255=186.674, tanpa nilai
  lain), serta siluet yang cocok dengan mask ML Kit setelah predicate dibalik.
- ML Kit: buffer FLOAT32 confidence, selalu 256x256 (nama asset model:
  `selfiesegmentation_mlkit-256x256-2021_01_19-v1215.f16.tflite`, bundel di AAR).

### Akurasi tepi (overlay, `docs/spike-t06/`)

Overlay = mask hijau 50% di atas frame asli, diambil dari P1 dan E1.

| Skenario | MediaPipe (640) | ML Kit (256) |
|---|---|---|
| Berwajah (P1) | Siluet kepala terdeteksi, detail rambut halus, beberapa leak kecil di tepi bahu/rambut | Siluet rapi dan kompak, tepi lebih kasar/blocky (resolusi rendah), tanpa detail rambut |
| Plafon kosong (P1) | False positive seluruh frame | Tidak ada deteksi |
| Ruangan virtual (E1, tanpa orang) | False positive luas (dinding + furnitur) | False positif lebih ketat (furnitur saja, dinding bersih) |

Kesimpulan akurasi: keduanya terdeteksi benar saat subjek orang ada; keduanya
false-positive di scene tanpa orang (wajar untuk model segmentasi orang, terutama
scene sintetis). MediaPipe memberi mask setara resolusi input (detail tepi lebih
halus saat dipakai 640), ML Kit terbatas 256x256.

### Ukuran

| Rute | Komponen | Ukuran |
|---|---|---|
| MediaPipe | `tasks-vision` AAR | 17,6 MB (multi-ABI native) |
| MediaPipe | `tasks-core` AAR | 1,2 MB |
| MediaPipe | model `selfie_segmenter.tflite` (asset app) | 250 KB |
| ML Kit | `segmentation-selfie` AAR (termasuk model 249.024 B) | 739 KB |
| ML Kit | seluruh tree resolved (17 artifact) | ≈ 24,2 MB — didominasi `mlkit:mediapipe-internal` 21,6 MB |

Kontribusi per-ABI di APK final belum diukur (kedua AAR multi-ABI).

### Lisensi (dari POM resolved)

- MediaPipe `tasks-vision`: **Apache-2.0** — kompatibel dengan paket MIT.
- ML Kit `segmentation-selfie`/`common`/`vision-common`: **"ML Kit Terms of
  Service"** — bukan lisensi open-source; konflik potensial untuk package
  pub.dev berlisensi MIT.

### Privasi dan dependensi (PRD G4: tanpa jaringan/telemetri)

- ML Kit menarik stack: `datatransport` (api/runtime/backend-cct),
  `firebase-encoders`(-json/-proto), `firebase-components`, `play-services`
  (base/basement/tasks), `odml:image`. Strukturnya siap network meski pada run
  normal benchmark tidak mencatat job/jaringan terpicu (jendela observasi pendek).
- MediaPipe juga me-link `datatransport` (class `JobInfoScheduler` tercatat ada di
  classpath). Catatan jujur: `disableTransportNetwork()` di spike saat ini **hanya
  log keberadaan class, belum benar-benar menonaktifkan scheduler** — implementasi
  no-op-nya menyusul saat integrasi final.
- Rekomendasi untuk ADR (T0.8): **MediaPipe** — lisensi Apache-2.0, privasi lebih
  bersih, resolusi mask mengikuti kebutuhan; trade-off latensi lebih tinggi di
  P1 (179 ms vs 111 ms) yang bisa ditangani dengan input lebih kecil / strategi
  frekuensi rendah. GPU delegate MediaPipe **belum diuji di track ini**.

## T0.7 — Komposit GPU dibanding CPU (P1)

Scope: blur (shader 3x3 box, radius 1 texel) dan penggantian gambar (mix 50/50
dengan asset mandiri `bench_bg.png`, gradient 64x64). Hanya device
fisik P1.

Metode: window 90 frame (≈3 detik) per mode. `fps` = kedatangan frame ke
processor. `CPU%` = Δ(utime+stime) seluruh proses app / wall × 100 (CLK_TCK=100,
debug build). `avgUs` = Δ total waktu compose / jumlah compose (hanya mode GPU).
Jalur CPU per frame = readback GPU + operasi Java (upload texture belum diukur).

### Hasil 640x480

| Mode | fps | CPU% proses | Biaya per frame |
|---|---|---|---|
| off (tanpa efek) | 30,1 | 93,8 | — |
| GPU blur | 30,2 | 91,6 | compose 1,05 ms |
| GPU image | 30,3 | 90,9 | compose 0,93 ms |
| CPU blur | — | — | readback 5,9 + blur 70,0 = **75,9 ms (≈13 fps)** |
| CPU image | — | — | readback 5,9 + lerp 30,4 = **36,3 ms (≈28 fps)** |

### Hasil 1280x720 (kamera depan A135F mendukung 720p — resolusi aktual terkonfirmasi)

| Mode | fps | CPU% proses | Biaya per frame |
|---|---|---|---|
| off (tanpa efek) | 30,3 | 80,8 | — |
| GPU blur | 30,1 | 81,2 | compose 1,21 ms |
| GPU image | 30,2 | 82,5 | compose 1,06 ms |
| CPU blur | — | — | readback 42,4 + blur 211,0 = **253,4 ms (≈4 fps)** |
| CPU image | — | — | readback 42,4 + lerp 91,0 = **133,4 ms (≈7,5 fps)** |

Catatan jujur:

- fps 30 stabil di semua mode GPU pada kedua resolusi; blur/image menambah
  <0,3 ms terhadap baseline.
- CPU% datar antar mode (selisih ≤3 poin, tidak berarah — 640 malah lebih
  tinggi dari 720): didominasi beban baseline app debug (kamera, preview,
  logging, engine). Delta efek GPU berada di bawah noise floor metrik ini —
  pemakaian CPU diputuskan lewat timing operasi langsung di atas.
- Window "off" menampilkan `avgUs` semu (985–2563 µs) — artefak boundary:
  1–3 frame yang sedang berjalan tetap ter-compose saat flag dimatikan.
  Baseline off = fps + CPU%, bukan avgUs.
- Upload texture (jalur CPU→GPU) belum diukur; dengan readback saja jalur CPU
  sudah 76 ms (640) / 253 ms (720) per frame — di luar budget 33 ms.

Kesimpulan: **GPU wajib.** Jalur CPU tidak real-time di kedua resolusi (blur
≈13 fps @640, ≈4 fps @720 bahkan sebelum upload), sedangkan GPU blur/image
menahan 30 fps dengan biaya ±1 ms.

## Temuan blocking (diperbaiki selama spike)

1. **Deadlock ML Kit di main thread.** Task listener ML Kit diantarkan di main
   looper; `latch.await()` di method channel (main thread) menggantung selamanya —
   seluruh app berhenti (timer frames mati). Fix: bagian ML Kit dijalankan di
   thread background, result.success diposting balik ke main; latch diberi timeout
   60 detik.
2. **`glReadPixels` dari main thread selalu nol.** EGL context hidup di capture
   thread; GL call dari main thread silent no-op. Ditambah lagi `readBackRgba`
   asli tidak pernah meng-copy buffer direct balik ke `ByteArray` — readback
   selalu kosong (overlay putih). Fix: readback dipindah ke dalam `onFrame`
   (capture thread) via request+latch, dan copy back ditambahkan.
3. **Readback memakai shader tint preview.** Program fragment merah
   (`×(1,0,0)`) dipakai bersama oleh compose dan readback → semua pixel readback
   hanya kanal merah (mask dihitung dari gambar merah-monokrom, terlihat dari
   overlay merah). Fix: shader readback tersendiri tanpa tint.
4. **Predicate mask MediaPipe kebalik.** `!= 0` menandai background (255) sebagai
   orang; terbaca dari histogram nilai (lihat T0.6). Fix: `== 0`.
5. **Format buffer iOS salah asumsi (T0.5).** Lihat bagian T0.5.
6. **Compositor baru NPE saat readback pertama (T0.7).** `vertexBuffer`/
   `texMatrixBuffer` hanya di-init oleh `buildProgram` (jalur tint). Setelah
   restart kamera 720p (compositor baru), readback tiba sebelum compose
   pertama → `glVertexAttribPointer(null)` → `Buffer.remaining()` NPE. Fix:
   `ensureBuffers()` lazy di `drawCamera` dan `drawQuad`.
