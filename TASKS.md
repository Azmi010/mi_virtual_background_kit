# Task Breakdown — mi_virtual_background_kit

Referensi: [PRD.md](PRD.md)

Konvensi: ID task `T<fase>.<nomor>`. Setiap task punya kriteria selesai (acceptance criteria) yang ringkas. Urutan fase mengikuti milestone M0 sampai M6. Repo dibuat di Fase 0 (T0.3).

## Fase 0 — Fondasi, repo, dan spike teknis (M0)

Repo dibuat di awal fase ini supaya spike dan ADR punya tempat. Kode spike dikerjakan di branch `spike/*` atau folder `spikes/` dan tidak ikut rilis; hanya hasil keputusan (ADR) yang masuk ke `main`.

- [x] T0.1 Cek ketersediaan nama `mi_virtual_background_kit` di pub.dev, nama repo GitHub, dan handle. Selesai: nama terkonfirmasi atau diganti sebelum scaffolding.
  - Hasil: nama `mi_virtual_background_kit` belum dipakai di pub.dev (404). Repo GitHub `Azmi010/mi_virtual_background_kit` sudah ada. Nama dipakai apa adanya.
- [x] T0.2 Putuskan lisensi (MIT atau BSD-3). Selesai: lisensi dipilih dan dicatat.
  - Hasil: **MIT**, file `LICENSE` sudah diisi. Dicatat di [ADR 0001](docs/adr/0001-core-architecture.md) bagian 8. Model segmentasi (MediaPipe `selfie_segmenter.tflite`) berlisensi Apache-2.0 dan kompatibel.
- [x] T0.3 Buat repo GitHub dan scaffold plugin dengan `flutter create --template=plugin --platforms=android,ios mi_virtual_background_kit`, lalu tambahkan file `LICENSE`. Selesai: repo ada di GitHub, proyek dan example bisa dibuild kosong.
  - Hasil: scaffold bersih. Package Android `com.azmi010.mi_virtual_background_kit`, bundle id example `com.azmi010.miVirtualBackgroundKitExample`, `pubspec.yaml` versi `0.1.0` dengan `flutter_webrtc: ^1.6.2`. Build Android dan iOS (SPM + CocoaPods) hijau. Catatan: `tool/link_example_build.sh` diperlukan sampai Flutter 3.48 rilis, lihat [docs/spike-results.md](docs/spike-results.md).
- [x] T0.4 Spike hook frame di `flutter_webrtc` untuk Android: tentukan cara memasang prosesor pada track kamera lokal dan versi yang mendukung. Selesai: prototipe yang mengubah frame (mis. membalik warna) terlihat di preview.
  - Hasil: `LocalVideoTrack.addProcessor(ExternalVideoFrameProcessing)` lewat `FlutterWebRTCPlugin.sharedSingleton.getLocalTrack(trackId)`. Frame masuk sebagai `TextureBufferImpl` tipe `OES`, rotasi 270, 640x480. 30 fps stabil. Lihat [docs/spike-results.md](docs/spike-results.md).
- [x] T0.5 Spike hook frame di `flutter_webrtc` untuk iOS dengan tujuan yang sama. Selesai: prototipe berjalan di perangkat fisik.
  - Hasil: `LocalVideoTrack.addProcessing(_:)` lewat `FlutterWebRTCPlugin.sharedSingleton().localTracks[trackId]`. Buffer `RTCCVPixelBuffer` rot=90 640x480, 30 fps stabil di iPhone 15 (iOS 26.5). Format buffer dideteksi runtime (YCbCr biplanar vs BGRA); transform swap chroma sesuai format, verifikasi visual enable/disable di device.
- [x] T0.6 Spike mesin segmentasi: bandingkan kandidat (MediaPipe Image Segmenter, ML Kit Selfie Segmentation) pada akurasi tepi, latency, ukuran, dan lisensi. Selesai: tabel perbandingan dengan angka dari minimal dua perangkat.
  - Hasil: tabel lengkap di [docs/spike-results.md](docs/spike-results.md) bagian T0.6 — angka dari P1 (Samsung SM-A135F fisik) + E1 (emulator, pembanding), overlay akurasi tepi di `docs/spike-t06/`. MediaPipe: mask resolusi input, Apache-2.0; ML Kit: mask fixed 256x256, lisensi ML Kit ToS (bukan open-source), dependensi telemetri Google. Rekomendasi sementara MediaPipe, final di T0.8.
- [x] T0.7 Spike komposit (GPU dibanding CPU) untuk blur dan penggantian gambar. Selesai: pengukuran fps dan CPU pada resolusi 640×480 dan 720p.
  - Hasil: tabel 640x480 + 1280x720 di [docs/spike-results.md](docs/spike-results.md) bagian T0.7 (device P1). GPU blur/image: 30 fps stabil, compose ±1 ms. CPU: blur 70 ms / image 30 ms @640, blur 211 ms / image 91 ms @720 — belum termasuk upload. **GPU wajib.**
- [x] T0.8 Tulis ADR (Architecture Decision Record) berisi keputusan: titik hook, mesin segmentasi, metode komposit, minimum OS, rentang versi `flutter_webrtc`. Selesai: file `docs/adr/0001-*.md` ter-commit di branch `main` repo (T0.3). Versi ringan yang dapat diterima: satu file `docs/decisions.md`.
  - Hasil: [docs/adr/0001-core-architecture.md](docs/adr/0001-core-architecture.md) — 8 keputusan (hook, format frame, MediaPipe, GPU, min OS, pin `^1.6.2`, paket, lisensi), alternatif ditolak, risiko + mitigasi. Angka pendukung di [docs/spike-results.md](docs/spike-results.md). Belum di-commit (menunggu review).
- [x] T0.9 Finalisasi bentuk API publik berdasarkan hasil spike. Selesai: bagian 8 PRD diperbarui.
  - Hasil: PRD bagian 8 diperbarui 24 Okt 2026 — angka latensi kita (P1 32-bit: MP 179 ms @640), pin `flutter_webrtc ^1.6.2`, semantics gambar-as-bytes, control-plane-only. Klaim lama di bagian 7 soal ML Kit diganti dengan alasan terverifikasi (dependensi kapabel-network + lisensi ToS).

## Fase 1 — Konfigurasi repo dan CI (M1)

- [x] T1.1 Rapikan `pubspec.yaml`: description 60–180 karakter, `repository`, `issue_tracker`, `topics`, rentang SDK, dan rentang `flutter_webrtc`. Selesai: `dart pub publish --dry-run` tidak mengeluhkan metadata.
  - Hasil: description dipendekkan (~119 char), topics 6→5 (batas pub.dev). Dry-run metadata bersih. Warning tersisa non-metadata: `docs/` vs `doc/` (tunda ke Fase 8).
- [x] T1.2 Atur lint (`analysis_options.yaml`) dan format. Selesai: `flutter analyze` dan `dart format --set-exit-if-changed .` lolos.
  - Hasil: `analysis_options.yaml` sudah benar (tidak diubah). 6 file Dart diformat ulang; spike folder tak tersentuh. Analyze bersih, format exit 0.
- [x] T1.3 Siapkan CI GitHub Actions: analyze, test, dan build example Android/iOS. Selesai: pipeline hijau di PR pertama.
  - Hasil: `.github/workflows/ci.yml` — 3 job: analyze-test (ubuntu), android build apk (ubuntu, JDK 17), ios build (macos + `tool/link_example_build.sh` untuk SPM bug Flutter <3.48). `example/test/widget_test.dart` placeholder (tanpa `main()`) dihapus. Pipeline hijau di push `696e985`.
- [x] T1.4 Siapkan template issue, template PR, `CONTRIBUTING.md`, dan `CODE_OF_CONDUCT.md`. Selesai: file ada di repo.
  - Hasil: bug_report + feature_request templates, PR template dengan checklist analyze/format/test, CONTRIBUTING.md, CODE_OF_CONDUCT.md (Contributor Covenant 2.1).
- [x] T1.5 Siapkan `CHANGELOG.md` dengan entri `0.1.0` kosong dan `README.md` kerangka. Selesai: kedua file ada.
  - Hasil: CHANGELOG sudah punya entri 0.1.0 (tak diubah). README skeleton: problem, tabel platform, install, effects, status, limitation; placeholder TODO untuk Fase 8 (GIF, native setup, contoh final, LiveKit).

## Fase 2 — Inti Dart (M1)

- [x] T2.1 Definisikan model efek: `sealed class VirtualBackgroundEffect` dengan `BlurEffect`, `ImageEffect` (asset, file, bytes), `ColorEffect`, `NoEffect`. Selesai: unit test serialisasi ke map untuk method channel.
  - Hasil: `lib/src/effects/effects.dart` — sealed class + `BackgroundFit` + `ImageSourceType`. `toMap()` untuk channel. 7 test serialisasi + exhaustiveness. Commit `0ca8e76`.
- [x] T2.2 Definisikan enum dan class status serta hierarki exception. Selesai: semua kode error di FR-08 punya tipe dan pesan.
  - Hasil: `lib/src/status/status.dart` — enum `ProcessorStatus` (FR-07) + sealed `BackgroundException` dengan 4 subclass FR-08 (`unsupportedPlatform`, `modelLoadFailed`, `invalidTrack`, `invalidImage`). 6 test. Commit `452fe52`.
- [x] T2.3 Implementasikan class utama `MiVirtualBackgroundKit`: `attach`, `detach`, `setEffect`, `dispose`, `statusStream`, dan `isSupported()`. Selesai: perilaku sesuai API di PRD, termasuk idempoten untuk `detach` dan `dispose`.
  - Hasil: API sesuai PRD; `detach`/`dispose` idempoten; `dispose` membuat kit tak terpakai (`StateError`). Spike method dipertahankan sementara (dihapus Fase 7). `example/integration_test/` scaffold dihapus (referensi API lama). 30 test. Commit `129cb26`.
- [x] T2.4 Buat `platform_interface` dan implementasi method channel, plus event channel untuk status. Selesai: bisa di-mock penuh di unit test.
  - Hasil: method channel `isSupported`/`attach`/`setEffect`/`detach`/`dispose`; event channel `mi_virtual_background_kit/status` → `ProcessorStatus`; kode FR-08 di-map ke exception typed. 12 test channel. Commit `9bfaab2`.
- [x] T2.5 Validasi input di sisi Dart (radius di luar rentang, gambar kosong, track tidak valid). Selesai: error dilempar sebelum menyentuh native.
  - Hasil: blur radius harus di `(0, 100]` → `ArgumentError`; path/bytes kosong → `InvalidImageException`; track tanpa id → `InvalidTrackException` (dari T2.3). Platform tidak dipanggil saat validasi gagal. Commit `69b20f1`.
- [x] T2.6 Unit test seluruh logika Dart. Selesai: cakupan logika Dart mendekati penuh.
  - Hasil: coverage **197/197 = 100%** seluruh `lib/`. Tambah `platform_interface_test` (default throw + default instance), spike delegate tests, null-map fallback. 53 test. Commit `625c5df`.

## Fase 3 — Android native (M2)

- [x] T3.1 Integrasikan mesin segmentasi terpilih dan pemuatan model. Selesai: mask orang dihasilkan untuk satu frame uji.
  - Hasil: `Segmenter` (`android/.../segmentation/Segmenter.kt`) — MediaPipe ImageSegmenter, CPU delegate, model asset `selfie_segmenter.tflite`, mode IMAGE; gagal load → `SegmentationException` (map ke FR-08 `modelLoadFailed` di T3.6). `MaskCodec` men-normalisasi kategori mask ke alpha (255=orang): UINT8 `person=0` / FLOAT32 `>=0.5`, buffer output dipakai ulang — 5 unit test JVM. Uji frame: overlay tint `docs/spike-t06/phys_mp.png` dibalik ke warna asli → `example/android/app/src/androidTest/assets/person_frame.png`. Instrumentation test `SegmenterInstrumentationTest` **lulus di SM-A135F (P1, Android 14)**: model load + mask orang dari 1 frame. Terkait ADR 0001 risiko `datatransport`: scheduler dimatikan di manifest plugin (`JobInfoSchedulerService` + `AlarmManagerSchedulerBroadcastReceiver` `android:enabled="false"`) — verifikasi: merged manifest APK benar, `dumpsys jobscheduler` 0 job untuk package kit, logcat tanpa baris transport selama test.
- [x] T3.2 Pasang frame processor pada track `flutter_webrtc` sesuai hasil T0.4. Selesai: frame melewati prosesor dan keluar ke preview.
  - Hasil: `FrameProcessor` (`android/.../processor/FrameProcessor.kt`) — `ExternalVideoFrameProcessing`, pass-through + counter (30 fps log tiap 150 frame); helper `attachFrameProcessor` menyimpan `LocalVideoTrack` sesuai kontrak ADR 0001 §1 (cache objek, jangan lookup ulang by id). Plugin: handler `attach` (re-attach melepas processor lama, gagal → error `invalidTrack`) dan `detach` idempoten; cleanup saat `onDetachedFromEngine`. 3 unit test handler (+`isReturnDefaultValues` utk `Log` di JVM). Verifikasi device P1: mode example `--dart-define=PROD_ATTACH=true`, logcat `frame pass #900` (30 fps stabil ±30 dtk), preview hidup (diff 2 screencap), tanpa exception. Catatan: `bool.fromEnvironment` **harus** lewat `const` — pemakaian bare di non-const context selalu `false` (terbukti probe `flutter test --dart-define`), guard example dipakai ulang `const prodMode`.
- [x] T3.3 Implementasikan komposit blur. Selesai: blur terlihat benar dengan tepi wajar pada preview.
  - Hasil: `GpuCompositor` (`android/.../compositor/GpuCompositor.kt`) mengimplementasikan interface `FrameCompositor` dengan shader OpenGL ES 2 (weighted 3x3 filter, linear map texel scale `radius / 25f`, support OES dan 2D texture, mask alpha upload ke `GL_LUMINANCE`). `FrameProcessor` (`android/.../processor/FrameProcessor.kt`) menerapkan `EffectState.Blur`, menjalankan segmentasi non-blocking di background thread dengan throttle per 5 frame (`SEGMENT_EVERY_N_FRAMES = 5`), upload mask saat siap, dan fallback transparan. `MiVirtualBackgroundKitPlugin` menangani method `setEffect` ("blur" dan "none"). 16 unit test JVM (`FrameProcessorTest`, `MiVirtualBackgroundKitPluginTest`, `MaskCodecTest`) dan 53 test Flutter/Dart 100% lulus, `flutter analyze` bersih tanpa warning.
- [x] T3.4 Implementasikan komposit gambar (cover dan contain) dan warna solid. Selesai: tampil benar pada orientasi portrait dan landscape.
  - Hasil: `GpuCompositor` (`android/.../compositor/GpuCompositor.kt`) mendukung solid color (`ColorEffect`, FR-03) dan image background (`ImageEffect`, FR-02) dengan shader OES dan 2D. Mode `cover` (center-crop) dan `contain` (letterbox/pillarbox hitam) dihitung melalui matriks affine 2D `calculateImageMatrix` yang memperhitungkan `frame.rotation` (0°, 90°, 180°, 270°) dan rasio aspek dengan inversi koordinat Bitmap raster vs OpenGL, sehingga gambar latar belakang tegak (upright) di portrait maupun landscape. Segmentasi berjalan langsung pada koordinat FBO tanpa rotasi MediaPipe agar mask dan texture kamera tetap selaras 1:1. `MiVirtualBackgroundKitPlugin` meng-handle decode image (asset, file, bytes) dengan mapping error `invalidImage` (FR-08) dan meneruskan metric `frameCount`/dimensi ke HUD. UI example mendukung panel kontrol responsif (side panel landscape + collapsible). 26 unit test JVM, 53 test Flutter lulus 100%, `flutter analyze` 0 issue.
- [x] T3.5 Atur threading dan buffer pool agar tidak ada alokasi berlebihan per frame. Selesai: tidak ada lonjakan GC saat profiling selama 5 menit.
  - Hasil: `GpuCompositor` (`android/.../compositor/GpuCompositor.kt`) menggunakan static singleton `IDENTITY_MATRIX` dan `EMPTY_RELEASE_CALLBACK` untuk `TextureBufferImpl`, buffer matriks pre-allocated (`camMatrixArray`, `imgMatrixArray`, `tempMatrixValues`), serta algoritma `calculateImageMatrix` bebas alokasi (menghilangkan `listOf`, `Pair`, dan boxed Floats). `FrameProcessor` (`android/.../processor/FrameProcessor.kt`) menerapkan buffer pool lengkap: reusable RGBA array (`workerRgbaBuffer`), ByteBuffer (`workerByteBuffer`), persistent pooled `Bitmap` (`reusableBitmap`), dan double-buffered mask arrays (`maskBufferA`, `maskBufferB`) sehingga alokasi memori berulang (~7 MB/s) turun menjadi 0 byte saat streaming aktif. Seluruh buffer dibersihkan dan bitmap di-recycle saat `release()`. 28 unit test JVM, 53 test Flutter, dan connected Android test di SM-A135F 100% lulus, `flutter analyze` 0 issue.
- [x] T3.6 Hubungkan ke method channel dan event channel. Selesai: semua operasi API Dart berfungsi di Android.
  - Hasil: `MiVirtualBackgroundKitPlugin` mengimplementasikan method channel lengkap: `isSupported` (FR-13, Android SDK >= 24), `attach` (FR-06), `setEffect` (FR-01/02/03/04), `detach`, dan `dispose` (FR-10). Menghubungkan `EventChannel` (`mi_virtual_background_kit/status`, FR-07) dengan `StreamHandler` yang memancarkan status `idle`, `initializing`, `active`, dan `error` secara thread-safe ke main thread Flutter. `FrameProcessor` dilengkapi callback `onStatusChange` untuk meneruskan error tak terduga. Example app berlangganan `statusStream` dan menampilkan status serta nilai `isSupported` secara live di HUD. 31 unit test JVM, 53 test Flutter, dan connected Android test di SM-A135F 100% lulus, `flutter analyze` 0 issue.
- [x] T3.7 Implementasikan dispose dan pelepasan resource. Selesai: attach/detach 100 kali tanpa kenaikan memori berkelanjutan.
  - Hasil: `GpuCompositor` (`release()`) melepas seluruh GL textures, shaders/programs, framebuffers, dan mengosongkan Direct ByteBuffers serta byte array readback/mask. `FrameProcessor` dilengkapi flag `isReleased` (`AtomicBoolean`); bila dilepas, `onFrame` langsung melakukan bypass nol-alokasi; `release()` idempoten menghentikan `segmentExecutor` (timeout 200ms / `shutdownNow`), menutup MediaPipe segmenter, me-recycle `reusableBitmap`, dan membebaskan buffer pool. `MiVirtualBackgroundKitPlugin` mengimplementasikan pelepasan idempoten pada `releaseFrameProcessor()`, `dispose`, dan `onDetachedFromEngine`. Teruji via unit test simulasi 100 siklus attach/detach tanpa memory leak atau error (`attachAndDetach_100Times_completesWithoutLeaksOrErrors`), 35 unit test JVM dan 53 test Flutter 100% lulus, connected Android test di SM-A135F 1/1 passed, `flutter analyze` 0 issue.

## Fase 4 — iOS native (M3)

- [x] T4.1 Integrasikan mesin segmentasi di iOS (CocoaPods dan/atau SPM). Selesai: mask dihasilkan di perangkat fisik.
  - Hasil: Integrasi MediaPipe Image Segmenter (`MediaPipeTasksVision`) via Swift Package Manager (`google-ai-edge/mediapipe`) dan CocoaPods `.podspec`. Model asset `selfie_segmenter.tflite` (250 KB) di-bundle ke dalam folder `Resources/` plugin. Dibuat arsitektur modular di `Segmentation/`: `PersonMask` (penampung alpha mask), `SegmentationError` (typed error handling FR-08), `MaskCodec` (menangani parsing category mask UINT8 `person=0` & FLOAT32 `>=0.5`), dan `Segmenter` (`MaskSegmenter`, CPU delegate, fallback multi-bundle path, dan zero-alloc alpha buffer). Hook verifikasi dipasang pada `spikeBenchmarkReadback`. Build iOS debug (`Runner.app`) berhasil 100%, `flutter analyze` 0 issue.
- [x] T4.2 Pasang frame processor sesuai hasil T0.5. Selesai: frame kamera melewati prosesor.
  - Hasil: `FrameProcessor` (`ios/.../Processor/FrameProcessor.swift`) mengimplementasikan `ExternalVideoProcessingDelegate`, pass-through frame nol-overhead saat bypass (FR-04), penghitung frame thread-safe (`frameCount`), dan logging berkala tiap 150 frame (30 fps stabil). Plugin mengimplementasikan caching `LocalVideoTrack` saat `attach` sesuai kontrak ADR 0001 §1 (tidak lookup ulang by id), release idempoten pada `detach` dan `dispose`, serta sinkronisasi status processor (`idle` -> `initializing` -> `active`). Unit test di `RunnerTests.swift` lulus, build iOS debug (`Runner.app`) berhasil 100%, `flutter analyze` 0 issue.
- [ ] T4.3 Implementasikan komposit blur, gambar, dan warna (Metal atau Core Image). Selesai: paritas visual dengan Android.
- [ ] T4.4 Tangani orientasi, mirror, dan color space. Selesai: hasil benar di kamera depan dan belakang.
- [ ] T4.5 Hubungkan ke method channel dan event channel. Selesai: semua operasi API Dart berfungsi di iOS.
- [ ] T4.6 Implementasikan dispose dan pelepasan resource. Selesai: pengujian siklus attach/detach tanpa kebocoran di Instruments.
- [ ] T4.7 Pastikan `.podspec` benar (versi minimum, dependensi, privacy manifest bila diperlukan). Selesai: `pod lib lint` lolos.

## Fase 5 — Fitur dan perilaku runtime (M4)

- [ ] T5.1 Ganti efek saat runtime tanpa kedipan atau restart kamera (FR-05). Selesai: transisi antar efek mulus di kedua platform.
- [ ] T5.2 Parameter kualitas: resolusi segmentasi, edge smoothing, target fps (FR-11). Selesai: perubahan parameter berpengaruh terukur pada fps dan kualitas.
  - Catatan dari T3.3: `BackgroundQuality` (segmentationWidth, edgeSmoothing, targetFps) belum diwiring ke Android. Segmentation width memengaruhi ukuran `PersonMask`; saat T3.3 mask diambil pada resolusi readback. edgeSmoothing belum ada di shader (mask mentah).
- [ ] T5.3 Fallback performa (FR-12): deteksi fps turun dan turunkan kualitas atau nonaktifkan dengan event. Selesai: skenario perangkat lambat tertangani tanpa crash.
  - Catatan keputusan dari T3.3 (jangan lupa saat mulai): segmentasi sudah di-throttle hardcode tiap 5 frame (~6 Hz, `SEGMENT_EVERY_N_FRAMES = 5`) dan radius blur pakai linear map `uTexelScale = radius / 25` (shortcut: box 3x3 + texel scale; radius > ~30 terlihat bertahap → upgrade ping-pong multi-pass bila perlu). T5.3 harus mengubah throttle jadi adaptif (deteksi fps turun → naikkan interval / turunkan resolusi) dan mengevaluasi apakah radius besar perlu multi-pass. Jangan hardcode ulang — sudah ada konstanta/map di T3.3.
- [ ] T5.4 Implementasikan `isSupported()` yang akurat per perangkat/OS. Selesai: hasil benar di perangkat yang didukung dan tidak.
- [ ] T5.5 Lifecycle: app ke background/foreground, ganti kamera, rotasi (FR-09). Selesai: tidak ada crash atau freeze di skenario tersebut.

## Fase 6 — Pengujian dan benchmark (M4)

- [ ] T6.1 Susun test matrix: minimal tiga kelas perangkat per platform (low, mid, high). Selesai: daftar perangkat dan hasil per skenario.
- [ ] T6.2 Benchmark fps, latency per frame, CPU, memori, dan baterai selama sesi 10 menit. Selesai: tabel hasil tercatat di `docs/benchmark.md`.
- [ ] T6.3 Integration test pada example (attach, ganti efek, detach) di CI atau perangkat uji. Selesai: skenario utama otomatis terverifikasi.
- [ ] T6.4 Uji di batas bawah dan atas rentang versi `flutter_webrtc`. Selesai: kedua batas lolos build dan uji dasar.
- [ ] T6.5 Uji soak: sesi panjang (30+ menit) dan attach/detach berulang. Selesai: tidak ada crash atau kebocoran.

## Fase 7 — Example app (M5)

- [ ] T7.1 Buat example mandiri: preview kamera lokal tanpa backend atau signaling. Selesai: berjalan di Android dan iOS dari nol.
- [ ] T7.2 UI pilihan efek: tanpa efek, blur (slider), gambar (beberapa asset), warna. Selesai: semua efek bisa dipilih saat runtime.
- [ ] T7.3 Tampilkan status dan error dari `statusStream`. Selesai: perubahan status terlihat di layar.
- [ ] T7.4 Tambahkan bagian contoh integrasi LiveKit sebagai panduan terpisah. Selesai: langkah jelas dan teruji sekali jalan.

## Fase 8 — Dokumentasi (M5)

- [ ] T8.1 README: masalah yang diselesaikan, GIF demo di bagian atas, instalasi dan setup native (permission kamera, minSdk, versi iOS), contoh kode singkat, bagian Batasan dan Platform. Selesai: pembaca baru bisa memasang hanya dari README.
- [ ] T8.2 Dokumentasi API `///` untuk semua class dan method publik. Selesai: `dart doc` tanpa peringatan.
- [ ] T8.3 Tulis panduan integrasi `flutter_webrtc` dan resep LiveKit. Selesai: contoh kode dapat disalin dan jalan.
- [ ] T8.4 Tulis FAQ dan troubleshooting (kamera hitam, performa rendah, build iOS gagal). Selesai: minimal sepuluh entri berdasarkan masalah yang ditemui saat pengembangan.
- [ ] T8.5 Rekam GIF atau screenshot demo dan daftarkan di `screenshots:` pubspec. Selesai: tampil di halaman pub.dev.

## Fase 9 — Kesiapan publish (M5)

- [ ] T9.1 Audit API publik: pindahkan semua yang belum pasti ke `lib/src/` dan batasi export. Selesai: hanya API yang dijanjikan yang terekspos.
- [ ] T9.2 Jalankan `flutter analyze`, `dart format`, `flutter test`, dan `dart pub publish --dry-run`. Selesai: semuanya bersih.
- [ ] T9.3 Uji sebagai git dependency di proyek lain yang bersih. Selesai: package terpasang dan berjalan tanpa bergantung pada folder lokal mana pun.
- [ ] T9.4 Minta satu atau dua developer lain mencoba dari README saja. Selesai: temuan kebingungan diperbaiki di dokumentasi.
- [ ] T9.5 Periksa lisensi seluruh dependensi dan model, dan ukuran arsip package. Selesai: tidak ada konflik lisensi dan ukuran wajar.
- [ ] T9.6 Finalisasi `CHANGELOG.md` untuk `0.1.0` dan nomor versi. Selesai: konsisten dengan `pubspec.yaml`.

## Fase 10 — Rilis dan pasca rilis (M6)

- [ ] T10.1 Siapkan verified publisher (opsional, perlu domain) dan akun publisher. Selesai: publisher siap atau diputuskan ditunda.
- [ ] T10.2 Publish `0.1.0` dengan `dart pub publish`. Perhatian: tidak dapat dibatalkan. Selesai: package tampil di pub.dev.
- [ ] T10.3 Aktifkan automated publishing dari GitHub Actions dengan tag `v*`. Selesai: tag percobaan berhasil memicu workflow.
- [ ] T10.4 Tambahkan badge (pub version, CI) ke README. Selesai: badge tampil benar.
- [ ] T10.5 Pengumuman: r/FlutterDev, komunitas Flutter Indonesia, X/LinkedIn, dan artikel tentang alasan dan cara kerja. Selesai: minimal tiga kanal terisi.
- [ ] T10.6 Pantau issue dan respons cepat pada bulan pertama. Selesai: issue pertama dijawab dalam 72 jam.

## Fase 11 — Setelah v0.1 (backlog v0.2 dan seterusnya)

- [ ] T11.1 Adapter atau helper LiveKit (modul opsional atau package terpisah). Selesai: integrasi dengan beberapa baris kode tanpa menambah dependensi bagi pengguna non-LiveKit.
- [ ] T11.2 Widget preview opsional.
- [ ] T11.3 Background video atau animasi.
- [ ] T11.4 Evaluasi dukungan package `camera`.
- [ ] T11.5 Evaluasi web dan desktop.
- [ ] T11.6 Naik ke `1.0.0` setelah API stabil dari pemakaian pengguna lain.

## Urutan kritis

Task yang paling berisiko dan harus dikerjakan paling awal: T0.4 dan T0.5 (hook frame), lalu T0.6 dan T0.7 (segmentasi dan komposit). Hasilnya menentukan arsitektur, minimum OS, dan rentang versi `flutter_webrtc`. Jangan mulai Fase 3 dan 4 sebelum T0.8 selesai.
