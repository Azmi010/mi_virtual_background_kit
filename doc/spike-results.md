# Phase 0 spike results

All numbers come from runs on this work track (October 2026), except those marked emulator. Spike code is in `android/src/main/kotlin/.../spike/`,
`ios/.../MiVirtualBackgroundKitPlugin.swift`, and `example/` (removed before release).

## Test devices

| ID | Device | ABI | OS | Role |
|---|---|---|---|---|
| P1 | Samsung SM-A135F (RR8T601FP0R) | `armeabi-v7a` (32-bit only) | Android 14 (SDK 34) | Physical, low-end class, primary device |
| P2 | iPhone 15 (00008120-0016195A0CC20032) | arm64 | iOS 26.5 | Physical, iOS spike (T0.5) |
| E1 | Emulator `sdk_gphone16k_arm64` (emulator-5554) | `arm64-v8a` | Android 17 (SDK 37) | Comparison only — software GL (swiftshader), latency numbers not representative |

General method: benchmark runs automatically once per example launch (flag
`_benchmarked`), input = real camera frame via GPU readback 640x480. Each engine:
scaled path first (256/144/96) as warmup, then 3 timed runs at 640x480.

## T0.4 — Android frame hook (P1)

Hook point: `LocalVideoTrack.addProcessor(ExternalVideoFrameProcessing)` obtained
via `FlutterWebRTCPlugin.sharedSingleton.getLocalTrack(trackId)`.

Live results:

```
SPIKE attach=true trackId=42f95020-...
first frame buffer=org.webrtc.TextureBufferImpl rot=270 size=480x640
SPIKE frames=... fps=27..31 gpu=717..1795us type=OES (stabil >1 menit)
```

- Incoming buffer is a GPU texture (`TextureBufferImpl`, OES type), not CPU I420.
  Transforms based on CPU byte access on this buffer will not work.
- Enable/disable toggle verified visually in preview (red on ↔ normal off).
- Spike composite (GLES2, texture → FBO → texture) ±0,8–1,7 ms per frame @640x480,
  30 fps remains stable (incidental numbers from timer log; official T0.7 measurement follows).

Design rules proven necessary (from API research + LiveKit patterns):

- Cache `LocalVideoTrack` object on attach; do not re-lookup by ID — Dart call
  `stream.getMediaTracks()` overwrites `localTracks` map with new objects that are
  not attached as processors.
- Pin `flutter_webrtc` version (this native API is not protected by semver).

## T0.5 — iOS frame hook (P2)

Hook point: `LocalVideoTrack.addProcessing(_:)` via
`FlutterWebRTCPlugin.sharedSingleton().localTracks[trackId]`.

Live results:

```
SPIKE attach=true trackId=FA4B3E0A-...
buffer=RTCCVPixelBuffer rot=90 size=640x480, 30 fps stabil
```

Finding: the first transform (BGRA assumption, half-pixel stride) produced thin
lines. Fix: runtime format detection (`CVPixelBufferGetPixelFormatType`), BGRA
branch (swap R/B per pixel) vs biplanar YCbCr (swap Cb/Cr pairs in plane 1, luma
untouched), check lock status. Visual verification on device: clean color slide
without lines when enabled, normal when disabled. FourCC format logged on the
first frame (device console not captured, verified via visual behavior).

## T0.6 — Segmentation engine

Candidates per PRD: **MediaPipe Image Segmenter** vs **ML Kit Selfie Segmentation**.

- MediaPipe: `com.google.mediapipe:tasks-vision:0.10.20` + asset
  `selfie_segmenter.tflite` (249.537 bytes) in app, CPU delegate.
- ML Kit: `com.google.mlkit:segmentation-selfie:16.0.0-beta6`, mode
  `SINGLE_IMAGE_MODE` + `enableRawSizeMask`, async API — timing = wall time
  call-to-result, run on a background thread (see "Blocking findings").

### Latency — P1 (physical, 640x480 → mask)

| Engine | Input 640 (3 runs, ms) | Median | Input 256 | Input 144 | Input 96 |
|---|---|---|---|---|---|
| MediaPipe | 155 / 182 / 179 | **179** | 174 | 123 | 122 |
| ML Kit* | 115 / 111 / 81 | **111** | 292† | 73 | 90 |

\* ML Kit mask is always 256x256 regardless of input — fixed model.
† Includes the first call of the session (model init); the first run of the
previous session was recorded at 417–610 ms. ML Kit steady state 80–140 ms.

Note: ML Kit numbers are faster on this device, BUT its mask is fixed at 256x256
(edge quality coarser than 640 input). MediaPipe mask = input resolution.

### Latency — E1 (emulator, comparison only)

| Engine | Input 640 (3 runs, ms) | Input 256 | Input 144 | Input 96 |
|---|---|---|---|---|
| MediaPipe | 17 / 17 / 17 | 11,4 | 3,8 | 4,1 |
| ML Kit | 3,3 / 25,9 / 7,3 | 173† | 5,5 | 9,7 |

† First init in the emulator session.

### Mask resolution and encoding

- MediaPipe: `categoryMask` UINT8, size = input resolution (640x480 @ input 640).
  Empirical encoding **person=0, background=255** — proven by histogram on a frame
  without a person (all 255) and a frame with a face (v0=120.526, v255=186.674, no
  other values), plus a silhouette matching the ML Kit mask after the predicate
  is inverted.
- ML Kit: FLOAT32 confidence buffer, always 256x256 (model asset name:
  `selfiesegmentation_mlkit-256x256-2021_01_19-v1215.f16.tflite`, bundled in AAR).

### Edge accuracy (overlay, `doc/spike-t06/`)

Overlay = 50% green mask over the original frame, taken from P1 and E1.

| Scenario | MediaPipe (640) | ML Kit (256) |
|---|---|---|
| With face (P1) | Head silhouette detected, fine hair detail, some small leaks at shoulder/hair edges | Clean, compact silhouette, coarser/blocky edges (low resolution), no hair detail |
| Empty ceiling (P1) | False positive across whole frame | No detection |
| Virtual room (E1, no person) | Widespread false positive (walls + furniture) | Tighter false positive (furniture only, clean walls) |

Accuracy conclusion: both detected correctly when a person subject is present;
both false-positive in scenes without a person (expected for a person segmentation
model, especially synthetic scenes). MediaPipe gives a mask at input resolution
(finer edge detail when used at 640), ML Kit is limited to 256x256.

### Size

| Route | Component | Size |
|---|---|---|
| MediaPipe | `tasks-vision` AAR | 17,6 MB (native multi-ABI) |
| MediaPipe | `tasks-core` AAR | 1,2 MB |
| MediaPipe | model `selfie_segmenter.tflite` (app asset) | 250 KB |
| ML Kit | `segmentation-selfie` AAR (including model 249.024 B) | 739 KB |
| ML Kit | entire resolved tree (17 artifacts) | ≈ 24,2 MB — dominated by `mlkit:mediapipe-internal` 21,6 MB |

Per-ABI contribution in the final APK not measured (both AARs multi-ABI).

### Licenses (from resolved POM)

- MediaPipe `tasks-vision`: **Apache-2.0** — compatible with MIT package.
- ML Kit `segmentation-selfie`/`common`/`vision-common`: **"ML Kit Terms of
  Service"** — not an open-source license; potential conflict for MIT-licensed
  pub.dev package.

### Privacy and dependencies (PRD G4: no network/telemetry)

- ML Kit pulls a stack: `datatransport` (api/runtime/backend-cct),
  `firebase-encoders`(-json/-proto), `firebase-components`, `play-services`
  (base/basement/tasks), `odml:image`. Its structure is network-ready even though
  normal benchmark runs did not record triggered jobs/network (short observation
  window).
- MediaPipe also links `datatransport` (class `JobInfoScheduler` recorded present
  in classpath). Honest note: `disableTransportNetwork()` in the current spike
  **only logs class presence, does not actually disable the scheduler** — its
  no-op implementation follows during final integration.
- Recommendation for ADR (T0.8): **MediaPipe** — Apache-2.0 license, cleaner
  privacy, mask resolution follows needs; trade-off of higher latency on P1
  (179 ms vs 111 ms) that can be handled with smaller input / low-frequency
  strategy. MediaPipe GPU delegate **not yet tested on this track**.

## T0.7 — GPU vs CPU composite (P1)

Scope: blur (3x3 box shader, radius 1 texel) and image replacement (50/50 mix with
standalone asset `bench_bg.png`, 64x64 gradient). Physical device P1 only.

Method: 90-frame window (≈3 seconds) per mode. `fps` = frame arrival at
processor. `CPU%` = Δ(utime+stime) of whole app process / wall × 100 (CLK_TCK=100,
debug build). `avgUs` = Δ total compose time / number of composites (GPU modes
only). CPU path per frame = GPU readback + Java operations (texture upload not
measured).

### Results 640x480

| Mode | fps | process CPU% | Cost per frame |
|---|---|---|---|
| off (no effect) | 30,1 | 93,8 | — |
| GPU blur | 30,2 | 91,6 | compose 1,05 ms |
| GPU image | 30,3 | 90,9 | compose 0,93 ms |
| CPU blur | — | — | readback 5,9 + blur 70,0 = **75,9 ms (≈13 fps)** |
| CPU image | — | — | readback 5,9 + lerp 30,4 = **36,3 ms (≈28 fps)** |

### Results 1280x720 (A135F front camera supports 720p — actual resolution confirmed)

| Mode | fps | process CPU% | Cost per frame |
|---|---|---|---|
| off (no effect) | 30,3 | 80,8 | — |
| GPU blur | 30,1 | 81,2 | compose 1,21 ms |
| GPU image | 30,2 | 82,5 | compose 1,06 ms |
| CPU blur | — | — | readback 42,4 + blur 211,0 = **253,4 ms (≈4 fps)** |
| CPU image | — | — | readback 42,4 + lerp 91,0 = **133,4 ms (≈7,5 fps)** |

Honest notes:

- 30 fps stable in all GPU modes at both resolutions; blur/image adds <0,3 ms
  over baseline.
- CPU% flat across modes (difference ≤3 points, not directional — 640 even
  higher than 720): dominated by baseline debug app load (camera, preview,
  logging, engine). GPU effect delta is below this metric's noise floor — CPU
  usage decided via direct operation timing above.
- "off" window shows spurious `avgUs` (985–2563 µs) — boundary artifact: 1–3
  in-flight frames still get composited when the flag is turned off. Off baseline
  = fps + CPU%, not avgUs.
- Texture upload (CPU→GPU path) not measured; with readback alone the CPU path is
  already 76 ms (640) / 253 ms (720) per frame — outside the 33 ms budget.

Conclusion: **GPU mandatory.** CPU path is not real-time at either resolution
(blur ≈13 fps @640, ≈4 fps @720 even before upload), while GPU blur/image holds
30 fps at ±1 ms cost.

## Blocking findings (fixed during spike)

1. **ML Kit deadlock on main thread.** ML Kit Task listener delivered on main
   looper; `latch.await()` in method channel (main thread) hangs forever — whole
   app stops (frame timer dies). Fix: ML Kit part runs on background thread,
   result.success posted back to main; latch given 60-second timeout.
2. **`glReadPixels` from main thread always zero.** EGL context lives on capture
   thread; GL calls from main thread are silent no-ops. Additionally the original
   `readBackRgba` never copied the direct buffer back to `ByteArray` — readback
   always empty (white overlay). Fix: readback moved inside `onFrame` (capture
   thread) via request+latch, and copy back added.
3. **Readback uses preview tint shader.** Red fragment program (`×(1,0,0)`)
   shared by compose and readback → all readback pixels only the red channel
   (mask computed from monochrome-red image, visible from red overlay). Fix:
   separate readback shader without tint.
4. **MediaPipe mask predicate inverted.** `!= 0` marks background (255) as
   person; read from value histogram (see T0.6). Fix: `== 0`.
5. **iOS buffer format wrong assumption (T0.5).** See T0.5 section.
6. **New compositor NPE on first readback (T0.7).** `vertexBuffer`/
   `texMatrixBuffer` only initialized by `buildProgram` (tint path). After 720p
   camera restart (new compositor), readback arrives before first compose →
   `glVertexAttribPointer(null)` → `Buffer.remaining()` NPE. Fix: lazy
   `ensureBuffers()` in `drawCamera` and `drawQuad`.

## T13.1 — LiveKit integration (10 November 2026)

Spike determining the mechanism for attaching effects to LiveKit tracks for the
v0.2 adapter (material for ADR 0002 item 5, T15.2/T15.3). Raw logs and screenshots
per method in `doc/spike-t131/<A|B|C|D>/` (`<M>.log`, `<M>_t131.txt`, `<M>_<stage>.jpeg`).

### Environment

- Device: **A1** (Samsung SM-A135F, Android 14) — only device (T12.3); iOS out of
  scope for T13.1.
- `livekit_client 2.13.1`, `flutter_webrtc 1.6.2+hotfix.4`.
- Server: `livekit/livekit-server --dev` in Docker + `adb reverse tcp:7880`.
- Harness: `example/lib/spike_t131_page.dart` (branch `spike/t13.1-livekit`),
  stage advanced manually via "Next stage" button for timely screenshots. Device
  log: `tool/t131_log.sh <M>`; teal analysis: `tool/t131_teal.py`.
- Test effect: `ColorEffect(0xFF00E5CC)` — teal fills background when no person
  present.

### Four mechanisms compared

- **A**: `kit.attach(mediaStreamTrack)` once (v0.1 recipe, T7.4).
- **B**: `TrackProcessor` wrapper via `track.setProcessor()`.
- **C**: A + auto re-attach on LiveKit track events.
- **D**: B + auto re-`setProcessor` on LiveKit track events.

Scenario per method: S1 baseline → S2 camera switch → S3a mute / S3b unmute →
S4a unpublish / S4b republish → S5 track restart. Four runs finished `ALL DONE`,
without `ACTION ERROR`.

### Teal% results per screenshot

Threshold: ≥30% = effect alive, ≈0% = effect gone (app UI noise ≈1%).

| Stage | A | B | C | D |
|---|---|---|---|---|
| S1-baseline | 31,7 | 31,4 | 35,1 | 33,3 |
| S2-switchcam | 0,0 | 0,7 | 60,3 | 60,3 |
| S3a-mute | 0,0 | 0,0 | 60,3 | 60,3 |
| S3b-unmute | 0,0 | 0,3 | 60,3 | 60,3 |
| S4a-unpublish | 0,0 | 0,0 | 60,3 | 60,3 |
| S4b-republish | 0,0 | 0,0 | 33,6 | 32,5 |
| S5-restart | 0,0 | 0,0 | 33,2 | 30,1 |

Number note: the 60,3% value in C/D = rear camera after switchcam (no person in
front, teal fills more of the frame). At S3a/S4a camera stops, renderer shows the
last frame — teal at those stages mostly reflects the previous stage's state.
S3a/S4a do not assess the mechanism; assessment is at S2, S3b, S4b, S5.

### Findings per method

**A — effect lost at S2, never recovers.** Kit stays `active` and still attached
to old track; LiveKit creates a new MediaStreamTrack on switchcam, unmute,
republish, and restart (id changes in log). Without re-attach, renderer shows raw
frames: teal 0,0% at all stages after S1. Republish even brings up a new
`PUBLISHED` track never fitted with the kit.

**B — effect lost at S2; source research hypothesis on `livekit_client` proven.**
On `restartTrack()`, LiveKit calls `stop()` first → `PROCESSOR_destroy` →
`kit.detach()` → `KIT_STATUS idle`, then `PROCESSOR_SET null`. Nothing
re-attaches → teal ≤0,7% (noise) at all stages after S1. This mechanism is
rejected.

**C — effect survives at all stages.** Recovery via three event paths:
`TrackStreamUpdatedEvent` → re-attach (3×: S2, S3b, S5),
`LocalTrackPublishedEvent` → attach (2×: setup, S4b),
`LocalTrackUnpublishedEvent` → detach (1×: S4a, when camera stops). Stream switch
triggers two `TrackStreamUpdatedEvent`s so attach called 2× — safe (FR-06
idempotent), `KIT_STATUS` returns `active` each time, without error. Teal ≥30% at
all stages.

**D — effect survives at all stages, with overlapping calls.** Re-`setProcessor`
on the same events restores the effect. At S2 two events arrive together →
`init`/`destroy`/`init` chase each other, but final state is correct:
`PROCESSOR_SET MiVirtualBackgroundKit` + `KIT_STATUS active`. Mute and unpublish
trigger `PROCESSOR_destroy` (expected, camera stops), recovery happens at
S3b/S4b. Teal ≥30% at all stages.

### Adapter mechanism recommendation

**Choose C** (attach + auto re-attach on track events):

1. Uses core API `attach(mediaStreamTrack)` — adapter stays thin and does not
   depend on LiveKit's `setProcessor` cycle, proven to clear the processor on
   `restartTrack` (evidence in B).
2. Survives all seven stages, equal to D, without overlapping calls.
3. One attach path; detach on unpublish keeps cycle clean.

C risk note: recovery after switchcam/mute/restart depends on
`TrackStreamUpdatedEvent` which is **internal** in `livekit_client 2.13.1` (not
exported); harness recognizes it via `runtimeType.toString()`. Mitigation: string
event-name matching + lower/upper bound version tests of `livekit_client` in CI
(T15.4) so event-name changes fail tested immediately. Public
`LocalTrackPublishedEvent`/`LocalTrackUnpublishedEvent` only handle
publish/unpublish, not switchcam/mute/restart.

D remains an alternative if LiveKit exports its events or provides a safe
processor cycle. For T15.3, scenarios the adapter must support: S2, S3b, S4b, S5.

## T13.2 — Shared track and registry replacement (11 November 2026)

Spike determining whether `flutter_webrtc` tracks not bound to a video source
processor can be fully supported or only detected (FR-19; material for T14.1 and
ADR 0002 item 4). Raw logs and screenshots in `doc/spike-t132/{android,ios}/`.

### Environment

- Android: A1 (SM-A135F, Android 14); iOS: P2 (iPhone 15, iOS 26.5).
- `flutter_webrtc 1.6.2+hotfix.4`. Harness `example/lib/spike_t132_page.dart`
  (manual stage buttons), log `tool/t132_log.sh`, PNG screenshot
  `tool/t132_shot.sh`. Test effect `ColorEffect(0xFF00E5CC)`; native decisions
  recorded as `T132| probe ...` lines.

### Source findings (before runs)

Two flutter_webrtc paths hand over `LocalVideoTrack` that are not wired:

1. **Shared track — Android only.** Second `getUserMedia` on same camera triggers
   `buildSharedVideoTrack`: new track created from `primary.videoSource` without
   `setVideoProcessor` (`GetUserMediaImpl.java`), so wrapper never receives
   frames. iOS has no such path — each `getUserVideo` builds a new chain (source +
   adapter + capturer), so second `getUserMedia` runs independently.
2. **Registry replacement — both platforms.** Dart `stream.getMediaTracks()` →
   native `mediaStreamGetTracks` replaces `localTracks` entries with new unwired
   wrappers (Android: `new LocalVideoTrack(track)` without `setVideoProcessor`;
   iOS: `initWithTrack:` without adapter). `addProcessor` on the replacement
   wrapper = silent no-op: attach succeeds, effect never runs. This is the root
   problem found earlier at T7.4.

### Mechanism tested: detection + redirect in kit attach path

Without forking `flutter_webrtc`, attach picks the object that actually processes
frames:

- **Android** (`SharedTrackProbe.kt`): reaches `VideoSource.videoProcessor`
  (private field; via two private flutter_webrtc fields + `getCapturerInfo`).
  Registry wrapper identity compared to source processor — same → direct;
  different → attach to source-owned object (covers shared, replacement, and
  normal in one path). Reflection fails → degrade to old behavior with
  `reason=reflection-failed` log (not a crash).
- **iOS**: check `track.processing` via KVC → direct; nil → redirect to
  `videoCapturer?.delegate`, then fallback to `retainedAdapter`. Kit stores
  adapter across detach (`retainedAdapter`): the original wrapper is the sole
  strong owner of the adapter (`capturer.delegate` is weak), so without this
  storage `getMediaTracks()` + detach kills the camera chain.

### Teal% results (5 stages × 2 platforms)

| Stage | Android | iOS |
|---|---|---|
| S1-baseline | 33,4 | 39,8 |
| S2-shared (render track2, kit on track1) | 34,0 | 0,0 |
| S3-attach-shared | 35,6 | 37,8 |
| S4-replace | 37,6 | 37,9 |
| S5-stop-primary | 38,3 | 36,6 |

Interpretation:

- **S1 and S3–S5 green on both platforms**: attach, redirect to shared, redirect
  after registry replacement, and camera promotion (primary stopped) all
  preserve the effect. Android log: S3/S4
  `action=redirect target=<track1> shared=true`; iOS log: S4
  `action=redirect-adapter` and `Frame pass` continues (frames flow again).
- **S2 Android 34,0%**: effect from attaching track1 spills to shared track at
  source level — frames processed before distribution to all tracks from the
  same source. S3 proves direct attach to the shared track also works.
- **S2 iOS 0,0%**: second `getUserMedia` = independent camera chain; kit on
  track1 does not affect track2. Correct behavior (not a bug) — iOS has no
  Android shared-track concept; solution is normal attach (S3, teal 37,8%).
- No `ERROR`/exception in either platform's log; all stages `ALL DONE`.

### Bug found during spike (iOS, first run)

First iOS run: S4/S5 failed — teal 0%, `Frame pass` stopped entirely, camera
frozen (S4-vs-S5 image diff = 0,6). Two causes:

1. Adapter deallocated on detach after registry replacement → camera chain dies
   and redirect target lost at once. Fix: `retainedAdapter`.
2. Probe line used `NSLog` not captured by `flutter run | tee` → evidence lost.
   Fix: replace with `print()`.

Second run with fix: S4 `action=redirect-adapter`, teal 37,9%, `Frame pass`
continues until `ALL DONE`.

### Decision

**Fully supported on both platforms** (FR-19 option b), without fork:

- **Android**: identity-based `VideoSource.videoProcessor` redirect handles
  shared, replacement, and normal cases in one path. Evidence: teal ≥33% at all
  stages + probe log.
- **iOS**: no shared case; replacement handled by nil `processing` detection +
  adapter redirect, with `retainedAdapter` holding adapter lifetime. Evidence:
  teal ≥37% at S1/S3–S5 + `Frame pass` continues.
- **Safe fallback**: Android reflection fails or iOS adapter not found → old
  behavior plus clear log line, never crashes.

For T14.1: make both paths the production implementation — move probes to
permanent location, add unit tests (mock reflection failure, `processing` nil),
keep encoder path regression tests. Out of spike scope: multi-camera scenarios
(adapter cache used across different tracks) — v0.1 keeps the single-camera-per-app
assumption.

## T13.3 — Mask temporal smoothing (11 November 2026)

Spike comparing temporal mask blending across segmentation runs (FR-20; material
for T14.2/T14.3 and ADR 0002 item 5). Raw logs in `doc/spike-t133/`.

### Environment

- Android: A1 (SM-A135F, Android 14); iOS: iPhone 15 (iOS 26.5).
- Harness `example/lib/spike_t133_page.dart`: 6 variants × 2 stages, each stage
  5 seconds, same motion script per variant (`still` = still, `motion` = fast
  motion). Log `tool/t133_log.sh` (Android) and `flutter run | tee` (iOS);
  aggregation `tool/t133_metrics.py`. Test effect `ColorEffect(0xFF00E5CC)`.
- Data: 883 masks decomposed from two platforms, 26 warmup masks discarded, all
  13 stages `SETTLED` + `ALL DONE`, without error.

### Variants and metrics

Variants compared:

- `none` — mask as-is (v0.1 baseline).
- `ema` — `out = prev*s + raw*(1-s)`, s = 0.3 / 0.5 / 0.7.
- `adaptive` — EMA that lowers history weight toward 0 when mask changes fast
  (innovation `d` exceeds `D0 = 0.06`), so fast motion pulls fresh mask and
  leaves no ghosting.

One `T133|` line per mask carries: `rev` (pixels flipping class A→B→A across
three masks = edge flicker; continuous motion moves one direction and is not
counted), `chg` (pixels changing class vs previous mask), `d` (fresh mask
innovation vs displayed, %), `lag` (distance of smoothed mask vs fresh mask %,
ghosting proxy), `us`, `fps`. iOS masks 640×480 (307200 px) and Android 256×192
(49152 px), so absolute numbers are only compared within-platform; cross-platform
compares percentage patterns.

### Results — A1 (Android)

| Variant | rev still | Δ flicker | rev motion | Δ flicker | lag motion | fps |
|---|---|---|---|---|---|---|
| none | 69,6 | baseline | 714,5 | baseline | 0,0% | 24,7–24,8 |
| ema 0,3 | 61,1 | +12% | 365,5 | +49% | 1,54% | 24,8–25,2 |
| ema 0,5 | (205,7)¹ | −196%¹ | 614,0 | +14% | 4,20% | 25,3–26,9 |
| ema 0,7 | 14,3 | +79% | 317,5 | +56% | 6,38% | 24,9–25,8 |
| adaptive 0,5 | 46,8 | +33% | 643,1 | +10% | 0,41% | 28,0–29,1 |
| adaptive 0,7 | 20,5 | +71% | 519,8 | +27% | 0,45% | 25,3–25,9 |

¹ `still` stage of this variant contaminated: `d = 3,64%` vs ~0,5% of other
stages means subject moved during the stage. This row is excluded from
recommendation.

### Results — iPhone 15 (iOS)

| Variant | rev still | Δ flicker | rev motion | Δ flicker | lag motion | fps |
|---|---|---|---|---|---|---|
| none | 332,4 | baseline | 3017,8 | baseline | 0,0% | 30,0 |
| ema 0,3 | 343,4 | −3% | 1704,0 | +44% | 1,12% | 30,0 |
| ema 0,5 | 201,6 | +39% | 2243,1 | +26% | 2,53% | 30,0 |
| ema 0,7 | 95,2 | +71% | 978,8 | +68% | 3,34% | 30,0 |
| adaptive 0,5 | 176,0 | +47% | 1280,9 | +58% | 0,36% | 30,0 |
| adaptive 0,7 | 93,7 | +72% | 2105,8 | +30% | 0,51% | 30,0 |

Δ = flicker reduction relative to baseline, positive = better.

### Interpretation

1. **Identical pattern on both platforms** — metric is valid.
2. **While still, need s ≥ 0,5.** The 0,3 variant ineffective (−3% to +12%,
   within noise). s = 0,7 cuts flicker 71–79% when still.
3. **EMA still causes ghosting during motion.** `lag` rises with s: ema 0,7 →
   3,3–6,4% (silhouette lags, visible to eye). Adaptive keeps `lag` ≤ 0,5% at all
   stages — `D0 = 0,06` works as designed: fast motion releases smoothing.
4. **−50% target (PRD §7) only reached when still.** Adaptive during motion only
   −27..30%: average `d` during motion 4–9% exceeds `D0 = 6%`, so adaptive is
   nearly inactive exactly when needed. Tuning debt for T14.2: raise `D0` to
   ~0,10–0,12 then re-measure (trade-off `lag` vs flicker).
5. **No fps regression** — iOS locked at 30,0 in all variants; A1 24,7–29,1 with
   no declining pattern.
6. **Cost per mask.** Smoothing blend itself not measured: `us` of `none` variant
   (27–32 ms on A1, 95–119 ms on iOS) same as EMA variants within noise — those
   numbers dominated by metric instrumentation (3 passes per mask) and debug
   build; GPU untouched because blend on CPU. Production numbers (release,
   without metrics) far below this. iOS `us` rises monotonically across run
   (94→119 ms) = thermal/debug build, not variant effect. A1 mask rate ~3 Hz
   (adaptive interval); iOS without timestamp in tee, not counted.

### Decision

**Recommended default parameters for v0.2: `adaptive` mode,
`maskTemporalSmoothing = 0,7`, `D0 = 0,06`.** Reason: flicker when still −71% (A1)
and −72% (iOS) — passes −50% target; `lag` ≤ 0,5% at all stages (no visible
ghosting); fps without regression. The 0,4 figure in PRD §8.3 draft example needs
adjusting to these spike numbers.

Notes for T14.2:

- `D0 = 0,06` too conservative for motion stage (finding 4) — raise to ~0,10–0,12
  and re-measure before giving up on −50% motion target.
- Move `MaskTemporalSmoother` from `spike/` folder to production location, expose
  `maskTemporalSmoothing` in `BackgroundQuality` (validation 0..1; value 0 =
  identical to v0.1, proven `none` = exact baseline), keep reset logic on
  stage/effect change.
- Official −50% claim needs fixed test clip (PRD §7), not manual motion by one
  operator like this run — this run is indicative.
- Out of T13.3 scope: iOS mask is full size 640×480 — `segmentationWidth` appears
  not to shrink the mask on iOS; check during T14.2/T14.3.

## T13.4 — Segmentation strategy for slow devices (11 November 2026)

Spike determining FR-22: better adaptive interval, MediaPipe GPU delegate, and
available model variants — all measured on A1 (no mid class, T12.3; Android-only
because the issue is a 32-bit device). Raw logs in `doc/spike-t134/`:
`android.log` = final run5; `run1`/`run2`/`run4` = archive of GPU crash evidence
and partial bench.

### Environment

- A1 (SM-A135F, Android 14, 32-bit), debug build `flutter run`.
- Harness `example/lib/spike_t134_page.dart` + `SpikeT134Bench`:5 camera frames
  captured offline then each config tested on the same frames — 2 warmup passes +
  4 passes × 5 frames = 20 samples, 75 s budget per config, progress tick per
  pass (`BENCH_TICK`). Latency isolated from live pipeline (effect disabled).
- Comparison models pushed by `tool/t134_push_models.sh` to
  `/data/local/tmp/t134/`: `selfie_segmenter_landscape` (144×256, float16, 250 KB)
  and `selfie_multiclass_256x256` (float32, 16,4 MB).
- Quality = agreement + IoU of binary mask vs `cpu-square-256` baseline on same
  frame. Background per frame = border ring majority (selfie encoding bg=255 and
  multiclass bg=0 both readable without model knowledge).
- Interval strategy tested live, 8 seconds per variant, same motion script
  (still, camera to person). Single run for whole table.

### Latency table (median/p95 ms, run5)

| Config | med | p95 | Δ med | Model bytes | n |
|---|---|---|---|---|---|
| cpu-square-256 (v0.1 baseline) | 133,1 | 212,2 | – | 249.537 | 20 |
| cpu-square-144 | 121,6 | 147,1 | −11,5 (−9%) | 249.537 | 20 |
| **cpu-landscape-256** | **87,9** | 144,1 | **−45,2 (−34%)** | 250.177 | 20 |
| cpu-multiclass-256 | 2.430,5 | 2.492,1 | +2.297 (+1.729%) | 16.371.837 | 20 |

Consistent across runs: landscape 84,2 (run4) vs 87,9 (run5); square-256 127,9 /
133,1. Pattern: what lowers latency is **model input shape** — landscape model
processes ~37k input pixels instead of ~65k (resize to 256×256), while shrinking
readback bitmap only cuts preprocessing (−9%). This aligns with T0.6 (architecture
dominates, not bitmap resolution).

### Quality table (vs cpu-square-256 baseline, 5 identical frames)

| Config | agree % | IoU % | bg | Notes |
|---|---|---|---|---|
| cpu-square-144 | 99,3 | 98,0 | 255 | small readback derivative has little effect |
| **cpu-landscape-256** | **98,9** | **96,8** | 255 | different model, near-identical silhouette |
| cpu-multiclass-256 | 99,7 | 99,0 | 0 | person = class ≠0 (hist: bg + class 1/3/4) |

Multiclass actually proves binary `selfie` is enough: person from multiclass class
composition 99,7% matches binary mask — rich classes add no value for background
replace.

### Interval strategy (live, 8 s per variant)

| Strategy | masks | gap mean | gap p50 | age p50 | inf mean | fps mean |
|---|---|---|---|---|---|---|
| current (v0.1) | 26 | 318 | 318 | 24 | 126 | 25,0 |
| **always** | 52 | **158** | **158** | 22 | 129 | 24,9 |
| budget | 20 | 405 | 404 | 22 | 127 | 24,9 |

- `always` doubles mask freshness (158 vs 318 ms) **at no fps cost** (identical
  24,9–25,0). Worker duty cycle rises from ~40% to ~82% — that is the only cost,
  and battery/thermal not measured in this spike.
- `current` = frame-count-based mapping like v0.1; its cadence depends on fps
  (fps drops → interval rises → mask gets staler).
- `budget` (trigger when mask age > max(200 ms, 2×inference)) is actually slowest:
  waits fully from mask ready, then infers again → cadence = budget + inference.
  Stalest with unmeasured power-saving rationale — value unclear.

### Decision

1. **Model: switch to `selfie_segmenter_landscape`** (material for T14.2/T14.5 +
   ADR 0002): −34% latency, equivalent quality (98,9% / IoU 96,8%), identical
   size 250 KB, native input shape matches landscape camera frames. Landscape +
   readback 144 combination not tested — detail in T14.5.
2. **GPU delegate: rejected.** SIGABRT in 3 runs: run1 (without condition), run2
   and run5 (after `detach` — production segmenter already closed), identical:
   `Abort message: 'image_frame.cc:102] Check failed: ImageFormat::UNKNOWN != format_ (0 vs. 0)'`,
   stack `TaskRunner → ImageSegmenter.convertToTaskResult →
   PacketGetter.nativeGetImageWidth`. GPU result conversion failure → uncatchable
   native `abort()`, independent of other segmenters.
3. **Multiclass: rejected** —2.430 ms per mask (18× baseline), 835 ms init,
   size16,4 MB (66×). Quality figure99,7% only proves binary selfie is enough.
4. **Strategy: `budget` rejected** (stalest, 405 ms). **`always` default
   candidate** (FR-22/FR-20) provided battery and thermal are measured in v0.2
   benchmark (T17.1) before locking — 82% duty cycle risks heat/battery in long
   sessions. Meanwhile, `current` (v0.1) remains safe baseline because FR-12
   still guards.
5. **Readback width144 rejected** as main lever (−9%, quality drops slightly more
   per ms saved).

### Findings during spike (harness bugs, fixed + regression tests)

- TFLite rejects heap `ByteBuffer` (`setModelAssetBuffer`) → `allocateDirect` +
  `flip()`; without this landscape/multiclass configs fail to load in run2.
- 4-corner background heuristic wrong when subject covers two bottom corners
  (run2 baseline read `bg=0`, inverted) → **border ring** majority detection;
  regression test `backgroundValue_survivesPersonCoveringTwoCorners`.
- GPU crash mid bench loop cut all subsequent rows (run1) → GPU moved to last
  stage `gpu-probe` + `detach` first; detach proven not root cause (run2/run5
  still crash).
- Slow model looked like hang (run3:39 s without a line) → tick per pass + running
  seconds in UI + 75 s budget with partial `part=<p>/<iters>`.

For T14.2/T14.5: apply landscape model, consider `always` after T17.1, and test
landscape + readback144 combo. For ADR 0002: cite three rejection figures (GPU
abort, multiclass2.430 ms/16,4 MB, budget405 ms).
