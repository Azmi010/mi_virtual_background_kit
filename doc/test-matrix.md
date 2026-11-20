# Test Matrix — Phase 6

Reference: [PRD.md](PRD.md) §7, [TASKS.md](TASKS.md) T6.1.  
Status: list ready, results filled in during execution of T6.2–T6.5.

## 1. Devices

PRD requires at least three device classes per platform (low, mid, high).
Hardware access is limited — only two physical devices are available.
The mid class is not measured. Official benchmark figures come only from the two rows below.
Emulators are not used (GPU/segmentation not representative).

| ID | Platform | Class | Device / identity | Connection | Role |
|----|----------|-------|-------------------|------------|------|
| A1 | Android | low | Serial `RR8T601FP0R` | USB (`adb`) | Official benchmark, integration test, soak, fallback |
| I1 | iOS | high | UDID `00008120-0016195A0CC20032` (iPhone 15) | Wireless (Xcode network) | Official benchmark, integration test, soak, fallback |

Full model identity (manufacturer/model SDK) filled in from `adb shell getprop` / Xcode during the first session.

## 2. Scenarios

Result legend: `pass` · `fail` · `n/a` · empty = not yet run.

| # | Scenario | FR | A1 | I1 | Notes / evidence |
|---|----------|----|----|----|------------------|
| S1 | `isSupported()` true on supported device | FR-13 | | | |
| S2 | `attach` to local camera track | FR-06 | | | Preview live |
| S3 | Blur effect (default radius + variations) | FR-01 | | | Screenshot edge |
| S4 | Image effect `cover` | FR-02 | | | Portrait + landscape orientation |
| S5 | Image effect `contain` | FR-02 | | | Letterbox correct |
| S6 | Solid color effect | FR-03 | | | |
| S7 | `NoEffect` / bypass | FR-04 | | | |
| S8 | Switch effects at runtime (blur→image→color→none→blur) | FR-05 | | | No flicker, track does not restart |
| S9 | Switch front/back camera (re-attach), effect persists | FR-09 | | | |
| S10 | Orientation rotation | FR-09 | | | |
| S11 | App background → foreground | FR-09 | | | No false fallback |
| S12 | `setQuality` / low-balanced-high preset takes effect | FR-11 | | | fps/quality measured |
| S13 | Performance fallback (lower quality / disable + event) | FR-12 | | | `fallbackStream` receives event |
| S14 | `statusStream` idle→initializing→active→error | FR-07 | | | |
| S15 | Typed error: invalidTrack / invalidImage / modelLoadFailed | FR-08 | | | |
| S16 | `detach` idempotent, camera still live for original track | FR-06 | | | |
| S17 | `dispose` clean, kit no longer in use | FR-10 | | | |
| S18 | attach/detach loop 100× without leak/crash | FR-10 | pass | pass | T6.5 |
| S19 | Soak 30 minutes: no crash, memory stable | — | pass | pass | T6.5 |
| S20 | Benchmark 10 minutes per effect: fps, latency, CPU, mem, battery | §7 | | | T6.2 → `doc/benchmark.md` |

## 3. Coverage vs PRD

| PRD class | Available? | Notes |
|-----------|------------|-------|
| Android low | Yes (A1) | |
| Android mid | **No** | No hardware |
| Android high | **No** | No hardware |
| iOS high | Yes (I1) | |
| iOS low/mid | **No** | No hardware |

Consequence: performance claims in README/Limitations may only mention the two devices above;
target "3 device classes" (success metric §12) **not met in v0.1 and v0.2**
(mid hardware unavailable — decision 10 Nov 2026, T12.3), recorded as a limitation,
not disguised.

## 4. Execution

| Part | Executor |
|------|----------|
| Connect device, set up scene (photo/tablet of person), press start, verify visually | Human |
| Script benchmark/soak, dump `adb`/log, run integration test, process results into tables/docs | Assistant |

Visual scenarios (S3–S8, edges & flicker): human ~2–3 minutes per device.  
The rest can be automated while the device is powered on.
