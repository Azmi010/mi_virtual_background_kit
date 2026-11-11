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

### Akurasi tepi (overlay, `doc/spike-t06/`)

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

## T13.1 — Integrasi LiveKit (10 November 2026)

Spike penentu mekanisme pemasangan efek ke track LiveKit untuk adapter v0.2
(bahan ADR 0002 butir 5, T15.2/T15.3). Log dan screenshot mentah per metode di
`doc/spike-t131/<A|B|C|D>/` (`<M>.log`, `<M>_t131.txt`, `<M>_<stage>.jpeg`).

### Lingkungan

- Device: **A1** (Samsung SM-A135F, Android 14) — satu-satunya device (T12.3);
  iOS di luar cakupan T13.1.
- `livekit_client 2.13.1`, `flutter_webrtc 1.6.2+hotfix.4`.
- Server: `livekit/livekit-server --dev` di Docker + `adb reverse tcp:7880`.
- Harness: `example/lib/spike_t131_page.dart` (branch `spike/t13.1-livekit`),
  stage maju manual lewat tombol "Next stage" agar screenshot tepat waktu.
  Log device: `tool/t131_log.sh <M>`; analisa teal: `tool/t131_teal.py`.
- Efek tes: `ColorEffect(0xFF00E5CC)` — teal mengisi latar saat tidak ada orang.

### Empat mekanisme yang dibandingkan

- **A**: `kit.attach(mediaStreamTrack)` sekali (rese v0.1, T7.4).
- **B**: wrapper `TrackProcessor` lewat `track.setProcessor()`.
- **C**: A + auto re-attach saat event track LiveKit.
- **D**: B + auto re-`setProcessor` saat event track LiveKit.

Skenario per metode: S1 baseline → S2 ganti kamera → S3a mute / S3b unmute →
S4a unpublish / S4b republish → S5 restart track. Empat run selesai
`ALL DONE`, tanpa `ACTION ERROR`.

### Hasil teal% per screenshot

Ambang: ≥30% = efek hidup, ≈0% = efek hilang (noise UI aplikasi ≈1%).

| Stage | A | B | C | D |
|---|---|---|---|---|
| S1-baseline | 31,7 | 31,4 | 35,1 | 33,3 |
| S2-switchcam | 0,0 | 0,7 | 60,3 | 60,3 |
| S3a-mute | 0,0 | 0,0 | 60,3 | 60,3 |
| S3b-unmute | 0,0 | 0,3 | 60,3 | 60,3 |
| S4a-unpublish | 0,0 | 0,0 | 60,3 | 60,3 |
| S4b-republish | 0,0 | 0,0 | 33,6 | 32,5 |
| S5-restart | 0,0 | 0,0 | 33,2 | 30,1 |

Catatan angka: nilai 60,3% di C/D = kamera belakang setelah switchcam (tanpa
orang di depannya, teal mengisi lebih banyak frame). Pada S3a/S4a kamera
berhenti, renderer menampilkan frame terakhir — teal di stage itu terutama
mencerminkan keadaan stage sebelumnya. S3a/S4a tidak menilai mekanisme;
penilaian ada di S2, S3b, S4b, S5.

### Temuan per metode

**A — efek hilang di S2, tidak pernah pulih.** Kit tetap `active` dan masih
terpasang ke track lama; LiveKit membuat MediaStreamTrack baru saat switchcam,
unmute, republish, dan restart (id berubah di log). Tanpa re-attach, renderer
menampilkan frame mentah: teal 0,0% di seluruh stage sesudah S1. Republish
bahkan memunculkan `PUBLISHED` track baru yang tidak pernah dipasangi kit.

**B — efek hilang di S2; hipotesis riset source `livekit_client` terbukti.**
Saat `restartTrack()`, LiveKit memanggil `stop()` lebih dulu →
`PROCESSOR_destroy` → `kit.detach()` → `KIT_STATUS idle`, lalu `PROCESSOR_SET
null`. Tidak ada yang memasang ulang → teal ≤0,7% (noise) di semua stage
sesudah S1. Mekanisme ini ditolak.

**C — efek bertahan di semua stage.** Pemulihan lewat tiga jalur event:
`TrackStreamUpdatedEvent` → re-attach (3×: S2, S3b, S5),
`LocalTrackPublishedEvent` → attach (2×: setup, S4b),
`LocalTrackUnpublishedEvent` → detach (1×: S4a, saat kamera berhenti).
Pergantian stream memicu dua `TrackStreamUpdatedEvent` sehingga attach
dipanggil 2× — aman (FR-06 idempoten), `KIT_STATUS` kembali `active` setiap
kali, tanpa error. Teal ≥30% di semua stage.

**D — efek bertahan di semua stage, dengan tumpang tindih panggilan.**
Re-`setProcessor` pada event yang sama memulihkan efek. Pada S2 dua event
datang bersamaan → `init`/`destroy`/`init` saling susul, tetapi state akhir
benar: `PROCESSOR_SET MiVirtualBackgroundKit` + `KIT_STATUS active`. Mute dan
unpublish memicu `PROCESSOR_destroy` (wajar, kamera berhenti), pemulihan
terjadi di S3b/S4b. Teal ≥30% di semua stage.

### Rekomendasi mekanisme adapter

**Pilih C** (attach + re-attach otomatis pada event track):

1. Memakai API inti `attach(mediaStreamTrack)` — adapter tetap tipis dan tidak
   bergantung pada siklus `setProcessor` milik LiveKit yang terbukti membersihkan
   processor pada `restartTrack` (bukti di B).
2. Bertahan di seluruh tujuh stage, setara D, tanpa tumpang tindih panggilan.
3. Satu jalur attach; detach saat unpublish menjaga siklus rapi.

Catatan risiko C: pemulihan setelah switchcam/mute/restart bergantung pada
`TrackStreamUpdatedEvent` yang **internal** di `livekit_client 2.13.1` (tidak
di-export); harness mengenalinya lewat `runtimeType.toString()`. Mitigasi:
pencocokan nama event string + uji batas bawah/atas versi `livekit_client` di
CI (T15.4) agar perubahan nama event langsung gagal teruji.
`LocalTrackPublishedEvent`/`LocalTrackUnpublishedEvent` yang publik hanya
menangani publish/unpublish, bukan switchcam/mute/restart.

D tetap alternatif bila LiveKit mengekspor event-nya atau menyediakan siklus
processor yang aman. Untuk T15.3, skenario wajib didukung adapter: S2, S3b,
S4b, S5.

## T13.2 — Track shared dan registry replacement (11 November 2026)

Spike penentu apakah track `flutter_webrtc` yang tidak terikat ke video source
processor bisa didukung penuh atau hanya bisa dideteksi (FR-19; bahan T14.1 dan
ADR 0002 butir 4). Log dan screenshot mentah di `doc/spike-t132/{android,ios}/`.

### Lingkungan

- Android: A1 (SM-A135F, Android 14); iOS: P2 (iPhone 15, iOS 26.5).
- `flutter_webrtc 1.6.2+hotfix.4`. Harness `example/lib/spike_t132_page.dart`
  (tombol stage manual), log `tool/t132_log.sh`, screenshot PNG
  `tool/t132_shot.sh`. Efek tes `ColorEffect(0xFF00E5CC)`; keputusan native
  tercatat sebagai baris `T132| probe ...`.

### Temuan source (sebelum run)

Dua jalur flutter_webrtc menyerahkan `LocalVideoTrack` yang tidak di-wiring:

1. **Track shared — Android saja.** `getUserMedia` kedua pada kamera yang sama
   memicu `buildSharedVideoTrack`: track baru dibuat dari `primary.videoSource`
   tanpa `setVideoProcessor` (`GetUserMediaImpl.java`), sehingga wrapper tidak
   pernah menerima frame. iOS tidak punya jalur ini — tiap `getUserVideo`
   membuat chain baru (source + adapter + capturer), jadi `getUserMedia` kedua
   berjalan mandiri.
2. **Registry replacement — kedua platform.** Dart `stream.getMediaTracks()` →
   native `mediaStreamGetTracks` mengganti entri `localTracks` dengan wrapper
   baru tanpa wiring (Android: `new LocalVideoTrack(track)` tanpa
   `setVideoProcessor`; iOS: `initWithTrack:` tanpa adapter). `addProcessor`
   pada wrapper pengganti = no-op senyap: attach sukses, efek tidak pernah
   jalan. Ini akar masalah yang dulu ditemukan di T7.4.

### Mekanisme yang diuji: deteksi + redirect di jalur attach kit

Tanpa fork `flutter_webrtc`, attach memilih objek yang benar-benar memproses
frame:

- **Android** (`SharedTrackProbe.kt`): mencapai `VideoSource.videoProcessor`
  (field privat; lewat dua field privat flutter_webrtc + `getCapturerInfo`).
  Identitas wrapper registry dibandingkan dengan processor source — sama →
  direct; berbeda → pasang di objek milik source (mencakup shared, replacement,
  dan normal dalam satu jalur). Reflection gagal → degradasi ke perilaku lama
  dengan log `reason=reflection-failed` (bukan crash).
- **iOS**: cek `track.processing` lewat KVC → direct; nil → redirect ke
  `videoCapturer?.delegate`, lalu fallback `retainedAdapter`. Adapter disimpan
  kit lintas detach (`retainedAdapter`): wrapper asli adalah pemilik kuat
  tunggal adapter (`capturer.delegate` lemah), sehingga tanpa penyimpanan ini
  `getMediaTracks()` + detach mematikan rantai kamera.

### Hasil teal% (5 stage × 2 platform)

| Stage | Android | iOS |
|---|---|---|
| S1-baseline | 33,4 | 39,8 |
| S2-shared (render track2, kit di track1) | 34,0 | 0,0 |
| S3-attach-shared | 35,6 | 37,8 |
| S4-replace | 37,6 | 37,9 |
| S5-stop-primary | 38,3 | 36,6 |

Interpretasi:

- **S1 dan S3–S5 hijau di kedua platform**: attach, redirect ke shared,
  redirect setelah registry replacement, dan promosi kamera (primary distop)
  semuanya mempertahankan efek. Log Android: S3/S4
  `action=redirect target=<track1> shared=true`; log iOS: S4
  `action=redirect-adapter` dan `Frame pass` berlanjut (frame mengalir lagi).
- **S2 Android 34,0%**: efek dari attach track1 merembet ke track shared di
  level source — frame diproses sebelum distribusi ke seluruh track dari source
  yang sama. S3 membuktikan attach langsung ke track shared pun berhasil.
- **S2 iOS 0,0%**: `getUserMedia` kedua = chain kamera mandiri; kit di track1
  tidak memengaruhi track2. Perilaku benar (bukan bug) — iOS tidak mengenal
  konsep track shared Android; solusinya attach biasa (S3, teal 37,8%).
- Tidak ada `ERROR`/exception di log kedua platform; semua stage `ALL DONE`.

### Bug yang ditemukan selama spike (iOS, run pertama)

Run pertama iOS: S4/S5 gagal — teal 0%, `Frame pass` berhenti total, kamera
beku (diff gambar S4-vs-S5 = 0,6). Dua penyebab:

1. Adapter dealloc saat detach setelah registry replacement → rantai kamera
   mati sekaligus target redirect hilang. Fix: `retainedAdapter`.
2. Baris probe memakai `NSLog` yang tidak ke-capture oleh `flutter run | tee`
   → bukti hilang. Fix: ganti `print()`.

Run kedua dengan fix: S4 `action=redirect-adapter`, teal 37,9%, `Frame pass`
lanjut sampai `ALL DONE`.

### Keputusan

**Didukung penuh di kedua platform** (FR-19 opsi b), tanpa fork:

- **Android**: redirect berbasis identitas `VideoSource.videoProcessor`
  menangani shared, replacement, dan kasus normal dalam satu jalur. Bukti:
  teal ≥33% di semua stage + probe log.
- **iOS**: tidak ada kasus shared; replacement ditangani deteksi `processing`
  nil + redirect adapter, dengan `retainedAdapter` menahan siklus hidup
  adapter. Bukti: teal ≥37% di S1/S3–S5 + `Frame pass` berlanjut.
- **Fallback aman**: reflection Android gagal atau adapter iOS tidak ditemukan
  → perilaku lama plus baris log jelas, tidak pernah crash.

Untuk T14.1: jadikan kedua jalur ini implementasi produksi — pindahkan probe ke
lokasi permanen, tambah unit test (mock reflection gagal, `processing` nil),
pertahankan regression test jalur encoder. Di luar cakupan spike: skenario
multi-kamera (adapter cache dipakai lintas track berbeda) — v0.1 tetap asumsi
kamera tunggal per aplikasi.

## T13.3 — Temporal smoothing mask (11 November 2026)

Spike perbandingan blend temporal mask antar run segmentasi (FR-20; bahan
T14.2/T14.3 dan ADR 0002 butir 5). Log mentah di `doc/spike-t133/`.

### Lingkungan

- Android: A1 (SM-A135F, Android 14); iOS: iPhone 15 (iOS 26.5).
- Harness `example/lib/spike_t133_page.dart`: 6 varian × 2 stage, tiap stage
  5 detik, skrip gerakan sama tiap varian (`still` = diam, `motion` = gerak
  cepat). Log `tool/t133_log.sh` (Android) dan `flutter run | tee` (iOS);
  agregasi `tool/t133_metrics.py`. Efek tes `ColorEffect(0xFF00E5CC)`.
- Data: 883 mask terurai dari dua platform, 26 mask warmup dibuang, semua 13
  stage `SETTLED` + `ALL DONE`, tanpa error.

### Varian dan metrik

Varian yang dibandingkan:

- `none` — mask apa adanya (baseline v0.1).
- `ema` — `out = prev*s + raw*(1-s)`, s = 0.3 / 0.5 / 0.7.
- `adaptive` — EMA yang menurunkan bobot riwayat menuju 0 saat mask berubah
  cepat (inovasi `d` melewati `D0 = 0.06`), agar gerak cepat menarik mask segar
  dan tidak meninggalkan ghosting.

Satu baris `T133|` per mask membawa: `rev` (piksel yang bolak-balik kelas
A→B→A antar tiga mask = kedipan tepi; gerak berkelanjutan bergerak satu arah
dan tidak dihitung), `chg` (piksel berubah kelas vs mask sebelumnya), `d`
(inovasi mask segar vs yang tampil, %), `lag` (jarak mask halus vs mask segar
%, proxy ghosting), `us`, `fps`. Mask iOS 640×480 (307200 px) dan Android
256×192 (49152 px), sehingga angka absolut hanya dibandingkan dalam-platform;
lintas platform dibandingkan pola persentasenya.

### Hasil — A1 (Android)

| Varian | rev still | Δ kedipan | rev motion | Δ kedipan | lag motion | fps |
|---|---|---|---|---|---|---|
| none | 69,6 | baseline | 714,5 | baseline | 0,0% | 24,7–24,8 |
| ema 0,3 | 61,1 | +12% | 365,5 | +49% | 1,54% | 24,8–25,2 |
| ema 0,5 | (205,7)¹ | −196%¹ | 614,0 | +14% | 4,20% | 25,3–26,9 |
| ema 0,7 | 14,3 | +79% | 317,5 | +56% | 6,38% | 24,9–25,8 |
| adaptive 0,5 | 46,8 | +33% | 643,1 | +10% | 0,41% | 28,0–29,1 |
| adaptive 0,7 | 20,5 | +71% | 519,8 | +27% | 0,45% | 25,3–25,9 |

¹ Stage `still` varian ini terkontaminasi: `d = 3,64%` vs ~0,5% stage lain
berarti subjek bergerak saat stage berjalan. Baris ini dikecualikan dari
rekomendasi.

### Hasil — iPhone 15 (iOS)

| Varian | rev still | Δ kedipan | rev motion | Δ kedipan | lag motion | fps |
|---|---|---|---|---|---|---|
| none | 332,4 | baseline | 3017,8 | baseline | 0,0% | 30,0 |
| ema 0,3 | 343,4 | −3% | 1704,0 | +44% | 1,12% | 30,0 |
| ema 0,5 | 201,6 | +39% | 2243,1 | +26% | 2,53% | 30,0 |
| ema 0,7 | 95,2 | +71% | 978,8 | +68% | 3,34% | 30,0 |
| adaptive 0,5 | 176,0 | +47% | 1280,9 | +58% | 0,36% | 30,0 |
| adaptive 0,7 | 93,7 | +72% | 2105,8 | +30% | 0,51% | 30,0 |

Δ = pengurangan kedipan relatif baseline, positif = lebih baik.

### Interpretasi

1. **Pola identik di kedua platform** — metriknya valid.
2. **Masih diam, perlu s ≥ 0,5.** Varian 0,3 tidak efektif (−3% s/d +12%,
   dalam noise). s = 0,7 memotong kedipan 71–79% saat diam.
3. **EMA tetap menimbulkan ghosting saat gerak.** `lag` naik seiring s:
   ema 0,7 → 3,3–6,4% (siluet tertinggal, terlihat mata). Adaptive menjaga
   `lag` ≤ 0,5% di seluruh stage — `D0 = 0,06` bekerja sesuai desain: gerak
   cepat melepas smoothing.
4. **Target −50% (PRD §7) hanya tercapai saat diam.** Adaptive saat motion
   hanya −27..30%: `d` rata-rata saat gerak 4–9% melampaui `D0 = 6%`, sehingga
   adaptive nyaris nonaktif persis saat dibutuhkan. Hutang tuning untuk T14.2:
   naikkan `D0` ke ~0,10–0,12 lalu ukur ulang (trade-off `lag` vs kedipan).
5. **Tidak ada regresi fps** — iOS terkunci 30,0 di semua varian; A1 24,7–29,1
   tanpa pola penurunan.
6. **Biaya per mask.** Blend smoothing sendiri tidak terukur: `us` varian
   `none` (27–32 ms di A1, 95–119 ms di iOS) sama dengan varian EMA dalam
   noise — angka itu didominasi instrumentasi metrik (3 pass per mask) dan
   build debug; GPU tidak tersentuh karena blend di CPU. Angka produksi
   (release, tanpa metrik) jauh di bawah ini. `us` iOS naik monoton sepanjang
   run (94→119 ms) = thermal/build debug, bukan efek varian. Mask rate A1
   ~3 Hz (interval adaptif); iOS tanpa timestamp di tee, tidak dihitung.

### Keputusan

**Parameter bawaan yang disarankan untuk v0.2: mode `adaptive`,
`maskTemporalSmoothing = 0,7`, `D0 = 0,06`.** Alasan: kedipan saat diam
−71% (A1) dan −72% (iOS) — lolos target −50%; `lag` ≤ 0,5% di semua stage
(tanpa ghosting terlihat); fps tanpa regresi. Angka 0,4 pada contoh draf PRD
§8.3 perlu disesuaikan dengan angka spike ini.

Catatan untuk T14.2:

- `D0 = 0,06` terlalu konservatif untuk stage motion (temuan 4) — naikkan ke
  ~0,10–0,12 dan ukur ulang sebelum menyerah pada target −50% gerak.
- Pindahkan `MaskTemporalSmoother` dari folder `spike/` ke lokasi produksi,
  ekspos `maskTemporalSmoothing` di `BackgroundQuality` (validasi 0..1;
  nilai 0 = identik v0.1, terbukti `none` = baseline persis), pertahankan
  logika reset saat ganti stage/efek.
- Klaim −50% resmi perlu klip uji tetap (PRD §7), bukan gerakan manual satu
  operator seperti run ini — run ini indikatif.
- Di luar cakupan T13.3: mask iOS berukuran penuh 640×480 — `segmentationWidth`
  tampak tidak mengecilkan mask di iOS; periksa saat T14.2/T14.3.

## T13.4 — Strategi segmentasi untuk perangkat lambat (11 November 2026)

Spike penentu FR-22: interval adaptif yang lebih baik, delegate GPU MediaPipe,
dan varian model yang tersedia — semua diukur di A1 (kelas mid tidak ada,
T12.3; Android-only karena masalahnya perangkat 32-bit). Log mentah di
`doc/spike-t134/`: `android.log` = run5 final; `run1`/`run2`/`run4` = arsip
bukti crash GPU dan bench parsial.

### Lingkungan

- A1 (SM-A135F, Android 14, 32-bit), build debug `flutter run`.
- Harness `example/lib/spike_t134_page.dart` + `SpikeT134Bench`:5 frame kamera
  ditangkap offline lalu tiap config diuji pada frame yang sama — 2 pass warmup
  + 4 pass × 5 frame = 20 sampel, budget 75 s per config, tick progres per pass
  (`BENCH_TICK`). Latensi terisolasi dari pipeline live (efek dimatikan).
- Model pembanding di-push `tool/t134_push_models.sh` ke
  `/data/local/tmp/t134/`: `selfie_segmenter_landscape` (144×256, float16,
  250 KB) dan `selfie_multiclass_256x256` (float32, 16,4 MB).
- Kualitas = agreement + IoU mask biner vs baseline `cpu-square-256` pada frame
  yang sama. Background per frame = mayoritas border ring (encoding selfie
  bg=255 dan multiclass bg=0 sama-sama terbaca tanpa pengetahuan model).
- Strategi interval diuji live, 8 detik per varian, skrip gerakan sama
  (diam, kamera ke orang). Satu run tunggal untuk seluruh tabel.

### Tabel latensi (median/p95 ms, run5)

| Config | med | p95 | Δ med | Model bytes | n |
|---|---|---|---|---|---|
| cpu-square-256 (baseline v0.1) | 133,1 | 212,2 | – | 249.537 | 20 |
| cpu-square-144 | 121,6 | 147,1 | −11,5 (−9%) | 249.537 | 20 |
| **cpu-landscape-256** | **87,9** | 144,1 | **−45,2 (−34%)** | 250.177 | 20 |
| cpu-multiclass-256 | 2.430,5 | 2.492,1 | +2.297 (+1.729%) | 16.371.837 | 20 |

Konsisten antar run: landscape 84,2 (run4) vs 87,9 (run5); square-256
127,9 / 133,1. Pola: yang menurunkan latensi adalah **bentuk input model** —
model landscape memproses ~37k piksel input alih-alih ~65k (resize ke
256×256), sedangkan mengecilkan bitmap readback hanya memotong preprocessing
(−9%). Ini sejalan T0.6 (arsitektur mendominasi, bukan resolusi bitmap).

### Tabel kualitas (vs baseline cpu-square-256,5 frame identik)

| Config | agree % | IoU % | bg | Catatan |
|---|---|---|---|---|
| cpu-square-144 | 99,3 | 98,0 | 255 | turunan readback kecil pengaruhnya |
| **cpu-landscape-256** | **98,9** | **96,8** | 255 | model berbeda, siluet nyaris identik |
| cpu-multiclass-256 | 99,7 | 99,0 | 0 | person = kelas ≠0 (hist: bg + kelas 1/3/4) |

Multiclass justru membuktikan biner `selfie` sudah cukup: person hasil
komposisi kelas multiclass99,7% sama dengan mask binary — kaya kelas tidak
memberi nilai tambah untuk background replace.

### Strategi interval (live,8 s per varian)

| Strategy | masks | gap mean | gap p50 | age p50 | inf mean | fps mean |
|---|---|---|---|---|---|---|
| current (v0.1) | 26 | 318 | 318 | 24 | 126 | 25,0 |
| **always** | 52 | **158** | **158** | 22 | 129 | 24,9 |
| budget | 20 | 405 | 404 | 22 | 127 | 24,9 |

- `always` menggandakan kesegaran mask (158 vs 318 ms) **tanpa biaya fps**
  (identik 24,9–25,0). Duty cycle worker naik dari ~40% ke ~82% — itulah
  satu-satunya biaya, dan baterai/thermal tidak diukur di spike ini.
- `current` = mapping berbasis hitungan frame seperti v0.1; cadence-nya
  bergantung fps (fps turun → interval naik → mask makin basi).
- `budget` (trigger saat umur mask > max(200 ms, 2×inference)) justru
  paling lambat: menunggu penuh sejak mask siap, lalu inference lagi
  → cadence = budget + inference. Paling basi dengan alasan hemat daya
  yang tidak terukur — nilainya tidak jelas.

### Keputusan

1. **Model: ganti ke `selfie_segmenter_landscape`** (bahan T14.2/T14.5 +
   ADR 0002): −34% latensi, kualitas setara (98,9% / IoU 96,8%), ukuran
   identik 250 KB, bentuk input native cocok dengan frame kamera landscape.
   Kombinasi landscape + readback 144 tidak diuji — uraikan di T14.5.
2. **Delegate GPU: ditolak.** SIGABRT di3 run: run1 (tanpa condition),
   run2 dan run5 (setelah `detach` — segmenter produksi sudah tertutup),
   identik:
   `Abort message: 'image_frame.cc:102] Check failed: ImageFormat::UNKNOWN != format_ (0 vs. 0)'`,
   stack `TaskRunner → ImageSegmenter.convertToTaskResult →
   PacketGetter.nativeGetImageWidth`. Kegagalan konversi hasil GPU →
   `abort()` native yang tak bisa ditangkap, independen dari segmenter lain.
3. **Multiclass: ditolak** —2.430 ms per mask (18× baseline), init 835 ms,
   ukuran16,4 MB (66×). Angka kualitas99,7% hanya membuktikan cukup pakai
   binary selfie.
4. **Strategi: `budget` ditolak** (paling basi,405 ms). **`always`
   kandidat default** (FR-22/FR-20) dengan syarat baterai dan thermal diukur
   di benchmark v0.2 (T17.1) sebelum dikunci — duty cycle82% berpotensi
   panas/baterai pada sesi panjang. Selama itu, `current` (v0.1) tetap
   baseline yang aman karena FR-12 tetap menjaga.
5. **Readback width144 ditolak** sebagai lever utama (−9%, kualitas turun
   sedikit lebih banyak per ms yang dihemat).

### Temuan selama spike (bug harness, sudah diperbaiki + regression test)

- TFLite menolak heap `ByteBuffer` (`setModelAssetBuffer`) → `allocateDirect`
  + `flip()`; tanpa ini config landscape/multiclass gagal load di run2.
- Heuristik latar4-sudut salah saat subjek menutup dua sudut bawah (baseline
  run2 terbaca `bg=0`, terbalik) → deteksi mayoritas **border ring**; regression
  test `backgroundValue_survivesPersonCoveringTwoCorners`.
- Crash GPU di tengah loop bench memotong semua row berikutnya (run1) →
  GPU dipindah ke stage terakhir `gpu-probe` + `detach` lebih dulu; detach
  terbukti bukan akar masalah (run2/run5 tetap crash).
- Model lambat terlihat seperti hang (run3:39 s tanpa baris) → tick per pass
  + detik berjalan di UI + budget75 s dengan `part=<p>/<iters>` parsial.

Untuk T14.2/T14.5: terapkan model landscape, pertimbangkan `always` setelah
T17.1, dan uji combo landscape + readback144. Untuk ADR 0002: kutip tiga
angka penolakan (GPU abort, multiclass2.430 ms/16,4 MB, budget405 ms).
