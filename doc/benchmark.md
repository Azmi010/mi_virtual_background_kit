# Benchmark — Phase 6 (T6.2)

Date: 2 November 2026  
Protocol: 10-minute session per effect, default effect quality **Balanced**, blur radius 20, front camera 640×480 @30 fps.  
Raw dump: `doc/bench-raw/` + logcat/`flutter run` (Android: `a1_*`, iOS: sessions in `/tmp/ios_*`).

## Devices

| ID | Device | OS | Connection | Notes |
|----|-----------|-----|---------|---------|
| A1 | Samsung SM-A135F (`RR8T601FP0R`) | Android 14 (API 34) | USB | low class |
| I1 | iPhone 15 (`00008120-0016195A0CC20032`, D37AP) | iOS 27.0.1 | USB (`flutter run`) | high class |

Coverage: 2 physical devices. Mid class not measured (see [test-matrix.md](test-matrix.md)). No emulator used.

## FPS per effect (10 minutes)

Source: HUD `flutter: HUD frames=… fps=…` every second during the session.

### A1 — Android low

| Effect | n (dtk) | min | max | mean | median | vs target 24–30 |
|------|---------|-----|-----|------|--------|-----------------|
| None (bypass) | 608 | 16 | 32 | **29.8** | 30 | ✅ |
| Blur | 608 | 19 | 32 | **28.4** | 30 | ✅ |
| Image cover | 607 | 19 | 32 | **28.4** | 30 | ✅ |
| Color teal | 607 | 25 | 32 | **30.0** | 30 | ✅ |

- Momentary drop to 16–19 fps occurred in None/Blur/Img; median stayed at 30.
- **No** `Performance fallback` / auto-disable event in 4 sessions (FR-12 not triggered on this device with Balanced).

### I1 — iOS high

| Effect | n (dtk) | min | max | mean | median | vs target 24–30 |
|------|---------|-----|-----|------|--------|-----------------|
| Blur | 601 | 25 | 31 | **30.0** | 30 | ✅ |
| Image cover | 600 | 29 | 31 | **30.0** | 30 | ✅ |
| Color teal | 600 | 29 | 31 | **30.0** | 30 | ✅ |
| None (bypass) | 600 | 29 | 31 | **30.0** | 30 | ✅ |

- Stable at 30, minimal noise. No fallback event.

## CPU (`dumpsys cpuinfo` snapshot — Android only)

% CPU of app process at end of session (not 10-minute average; spot check).

| Effect | App process CPU | TOTAL system |
|------|----------------|--------------|
| None | ~83–143% * | ~33–40% |
| Blur | ~139% | ~40% |
| Image cover | ~133% | ~37% |
| Color teal | ~143% | ~40% |

\* None varied because the snapshot fell at different moments; bypass is indeed cheaper when segmentation is off.

iOS: `dumpsys` unavailable; CPU spot-check via Instruments not yet run — **gap noted**.

## Memory (Pss TOTAL, Android, end of session)

| Effect | Pss |
|------|-----|
| None | ~290 MB |
| Blur | ~285 MB |
| Image cover | ~287 MB |
| Color teal | ~286 MB |

Stable ±5 MB across effects → **no leak spike** across effect switches within a single long session.  
iOS memory per session: not yet measured (needs `devicectl`/Instruments) — **gap**.

## Latency per frame

- GPU composite: T0.7 spike figure remains the reference (~1 ms @640×480, 32-bit low-end device) — see [spike-results.md](spike-results.md).
- MediaPipe segmentation: spike figure (arm64 teens of ms, 32-bit ~179 ms @640) — not remeasured in T6.2 session (PROD path does not emit raw latency to HUD).
- **Gap:** end-to-end latency per frame in the 10-minute session not yet published per device.

## Battery

| Platform | Result |
|----------|-------|
| A1 | **Not measured** — always USB charging, `level` 100% throughout the session |
| I1 | **Not measured** — USB via `flutter run` |

Need a repeat session without cable (wireless adb / unplug charger) for drain figures. **Gap.**

## Conclusion vs PRD §7

| Target | Status |
|--------|--------|
| 24–30 fps @ 640×480–720p on mid/low | ✅ met on A1 (low) & I1 (high), mean 28.4–30 |
| Composite ~1 ms/frame | ✅ from spike, not this session |
| Latency per frame published in README | ⚠️ partial (spike only) |
| CPU/mem/battery reported in Limitations | ⚠️ CPU & mem Android; battery & CPU/iOS & mem iOS = gap |
| 3 device classes | ❌ only 2 devices (hardware access limitation) |

## Limitations to state honestly in README

1. Only 2 physical devices; no mid-tier.
2. Battery not measured (devices kept charging).
3. iOS CPU/mem not snapshotted in this session.
4. End-to-end per-frame latency not measured in the 10-minute session (spike only).

## 30-minute soak (T6.5, A1)

Date: 3 November 2026 · Tool: `tool/soak.sh 30` · Raw: `doc/bench-raw/a1_soak_20261103_104351*`

- Full 30-minute duration, 30 samples every 60 dtk, process PID **same** (29010) from start to finish — no restart or crash.
- Pss memory: 163 MB (cold start) → ~250 MB (first-minute warmup) → **plateau 250–258 MB for the remaining 27 minutes**. Warmup→end delta +6,6 MB ≈ GC noise — **no memory leak**.
- Crash / ANR / performance-fallback: **0 lines** in 30-minute logcat.
- Last frame pass log `#54300` ≈ **30,1 fps** stable throughout the session.
- Battery not informative (USB kept charging; level rose 65→75).

### 100× attach/detach loop (T6.5)

`example/integration_test/soak_loop_test.dart` — 100 cycles attach→(effect every 25)→detach, double detach every 50, final attach, no errors.

- **A1 (Android): passed** in 10 dtk.
- **I1 (iOS): passed** in 3 dtk.

## 30-minute soak (T6.5, I1)

Date: 3 November 2026 · Tool: `flutter run -d <I1> --debug` + monitor 60 dtk/sample · Log: `/tmp/i1_soak_run.log`, samples: `/tmp/i1_soak30.log`

- 30 samples / 30 minutes, `flutter run` **ALIVE in all samples** — stable USB connection, no lost connection.
- HUD FPS **30 in every sample** (uniform, no drop to the 20s).
- Last frame pass log `#54750` ≈ **30,4 fps** (`30 fps stable`).
- Crash / lost connection / performance-fallback: **0 events** in 30 minutes.
- iOS memory not snapshotted (without Instruments) — metric gap, not stability.

### Remaining T6.5 gaps

- iOS soak memory not measured (needs special Instruments/`xcrun`) — stability and fps already proven.

## v0.2.0 — benchmark rerun (T17.1)

Date: 17 November 2026.  
Protocol: 10 minutes per effect, `BackgroundQuality.balanced`, front camera 640×480 @30 fps, blur radius 20. Same as v0.1 protocol; difference is the fps figure source — v0.2 uses native `metricsStream` samples (~1 Hz), not the old `flutter:` HUD. Raw data not saved; figures below are result summaries.

A1 used Wi-Fi adb with cable unplugged (`bstate=3` throughout the session). I1 used USB for the integration session; iOS battery measured separately in a standalone app session without cable. iOS CPU/memory not measured in T17.1 — T17.2 scope (Instruments).

### FPS — A1 (Android low)

| Effect | n | mean | median | min | v0.1 mean | Δ |
|------|---|------|--------|-----|-----------|---|
| None | — | **29,96**¹ | — | — | 29,8 | +0,2 |
| Blur | 584 | **29,84** | 30,0 | 24,2 | 28,4 | +1,4 |
| Image cover | 583 | **29,83** | 30,0 | 17,3 | 28,4 | +1,4 |
| Color teal | 583 | **29,82** | 30,0 | 20,0 | 30,0 | −0,2 |

¹ `NoEffect` produces no metric samples (bypass returns immediately before the gate). Figure derived from logcat: `frame pass #1` 11:14:23.090 → `#18000` 11:24:23.818 = 17.999 frame / 600,7 s.

### FPS — I1 (iOS high)

| Effect | n | mean | median | min | v0.1 mean | Δ |
|------|---|------|--------|-----|-----------|---|
| None | — | not measured² | — | — | 30,0 | — |
| Blur | 600 | **30,00** | 30,0 | 30,0 | 30,0 | 0 |
| Image cover | 600 | **30,00** | 30,0 | 30,0 | 30,0 | 0 |
| Color teal | 601 | **30,00** | 30,0 | 30,0 | 30,0 | 0 |

² Bypass produces no metric samples, and the iOS harness does not record frame pass logs. The v0.1 figure (30,0) is kept as reference; no code reason to change on the bypass path.

### Latency per frame (new in v0.2, FR-23)

1 Hz sample average. `seg` = last segmentation inference duration; `age` = age of the mask being composited.

| Effect | A1 seg | A1 age | I1 seg | I1 age |
|------|--------|--------|--------|--------|
| Blur | 84,0 ms | 115,4 ms | 63,9 ms | 131,2 ms |
| Image cover | 79,1 ms | 107,2 ms | 113,0 ms | 284,2 ms |
| Color teal | 79,6 ms | 108,1 ms | 115,5 ms | 253,6 ms |

A1 figures match the landscape model (T13.4 spike: 87,9 ms). iOS figures not strictly compared across effects — scene load and segmentation frequency differ per session.

### CPU and memory — A1

| Effect | CPU% (mean) | Pss mean | Pss start → end |
|------|-------------|----------|------------------|
| None | 40,1% | 278,5 MB | 275,5 → 279,8 MB |
| Blur | 127,8% | 299,9 MB | 290,0 → 305,3 MB |
| Image cover | 114,0% | 307,1 MB | 297,3 → 311,8 MB |
| Color teal | 122,2% | 303,3 MB | 296,3 → 307,3 MB |

CPU% cross-verified with `dumpsys cpuinfo` (blur 127%, image 116%, color 114%, none 39%). Absolute figures **not directly comparable** with v0.1: v0.2 measured from `flutter test integration_test` harness, v0.1 from standalone app. v0.2 active-effect Pss is ~13–20 MB higher than v0.1 (~285–290 MB); this increase is recorded as-is, not treated as noise.

iOS: CPU/memory not measured in T17.1 session; see T17.2 section below.

### Battery

A1 — from 10-minute integration session, cable unplugged:

| Effect | Start | End | Drop |
|------|--------|-------|-------|
| None | 60% | 57% | 3 points |
| Blur | 57% | 54% | 3 points |
| Image cover | 54% | 52% | 2 points |
| Color teal | 52% | 50% | 2 points |

Total 60% → 50% in 40 minutes (~2,5 points per 10 minutes).

I1 — separate standalone app session, without cable, effects selected manually (None / Blur radius 20 / Teal / Asset Office):

| Effect | Start | End | Drop |
|------|--------|-------|-------|
| None | 88% | 87% | 1 point |
| Blur | 87% | 83% | 4 points |
| Color teal | 83% | 81% | 2 points |
| Image cover | 81% | 78% | 3 points |

Note: iOS figures come from a different session than the fps figures, not from the same harness. This is a method limitation, not a flawed measurement result.

### Anomalies

- A1 image: three samples at t≈411,7–413,8 s dropped to 17,3–22,8 fps while `seg` stayed at 68–76 ms. Recovered within 1 second, no fallback triggered — momentary disturbance outside segmentation.
- I1 color: one `seg` sample 829 ms; fps stayed at 30,0, no fallback.

### Conclusion vs T17.1

| Target | Status |
|--------|--------|
| No fps regression vs v0.1 | ✅ A1 blur/image +1,4; I1 30,0 for all active effects |
| Battery measured on two platforms | ✅ A1 from integration; iOS from separate standalone session |
| CPU/memory | ⚠️ A1 available; iOS still a gap (T17.2) |
| Three device classes | ❌ still two devices; mid class unavailable (T12.3) |

## iOS CPU and memory — Instruments (T17.2)

Date: 18 November 2026.  
Method: `xctrace record` with **Activity Monitor** template, attached to verified `Runner.app` process (two instances installed on device; wrong one killed first). Main session: 30-minute soak with `BlurEffect(radius: 20)`. Short 5-minute session for other effects. Raw data not saved; figures below are result summaries.

| Effect | Duration | CPU% mean | CPU% median | CPU% max | Memory (physical footprint) | Real Mem |
|------|--------|-----------|-------------|-----------|------------------------------|----------|
| None | 5 mnt | 19,1% | 19,1% | 20,2% | 273,7 MB | 442,9 MB |
| Blur (soak) | 30 mnt | **115,4%** | 122,0% | 146,3% | 288,1 MB | 433,1 MB |
| Image (Asset Office) | 5 mnt | 100,8% | 99,4% | 131,8% | 291,3 MB | 587,3 MB |
| Color teal | 5 mnt | 99,7% | 98,7% | 126,8% | 288,0 MB | 621,6 MB |

30-minute soak produced 1.728 samples (~1 Hz), from `00:00.000` to `29:59.264`. Average CPU rose from **97,4%** in first 5 minutes to **123,9%** in last 5 minutes. Memory physical footprint stayed **291,2 → 286,7 MB**, Real Mem **442,1 → 437,1 MB** — no sustained growth. CPU increase not accompanied by memory swelling and no fps measurement in this session, so more likely load/scene change than a leak.

Active effects consume ~100–115% CPU, comparable to A1 (114–128%). `None` on iOS is much cheaper (19,1%) than A1 (40,1%); both figures come from different tools (Activity Monitor vs `top`), so not directly compared.

**T17.2 conclusion:** iOS CPU/memory gap from T6.2 and T6.5 closed. No indication of memory leak in 30-minute soak.

## Frame → output latency (T17.3)

Date: 18 November 2026.  
Source: `metricsStream.processorLatencyMs`, effect `ColorEffect(teal)`, `BackgroundQuality.balanced`, 640×480 @30 fps, 2-minute session per device. Raw data not saved; figures above are result summaries.

| Device | n | mean | median | min | max | p95 |
|--------|---|------|--------|-----|------|-----|
| A1 (Android low) | 116 | 5,97 ms | **0,90 ms** | 0,50 ms | 32,20 ms | 27,20 ms |
| I1 (iOS high) | 120 | 1,33 ms | **1,40 ms** | 1,00 ms | 1,60 ms | 1,50 ms |

A1 distribution two peaks: 92/116 samples ≈ 1,4 ms, 24/116 samples ≈ 23,5 ms. Slow samples coincided with frames doing mask readback/upload for segmentation; GPU composite itself stayed ~1 ms. I1 stable at ~1,3–1,4 ms.

**Definition:** start time = frame arrives at native processor; end time = composited frame returned to WebRTC. This figure **does not** include camera sensor readout, encode, network, or screen render — not a glass-to-glass figure. This figure is also published in README Limitations section.

**T17.3 conclusion:** pipeline latency figures available for both platforms and published in README.
