#!/usr/bin/env bash
# T6.2 Android benchmark snapshot: mem/cpu/battery/load + logcat tail.
# Usage: tool/bench_android.sh <label>   e.g. tool/bench_android.sh blur_before
set -euo pipefail

SERIAL="${ANDROID_SERIAL:-RR8T601FP0R}"
LABEL="${1:-snapshot}"
PKG="com.azmi010.mi_virtual_background_kit_example"
OUT_DIR="doc/bench-raw"
mkdir -p "$OUT_DIR"
TS="$(date +%Y%m%d_%H%M%S)"
BASE="$OUT_DIR/a1_${LABEL}_${TS}"

adb -s "$SERIAL" shell dumpsys battery  > "${BASE}_battery.txt"
adb -s "$SERIAL" shell dumpsys meminfo "$PKG" > "${BASE}_meminfo.txt"
adb -s "$SERIAL" shell dumpsys cpuinfo > "${BASE}_cpuinfo.txt"
adb -s "$SERIAL" shell cat /proc/loadavg > "${BASE}_loadavg.txt"
adb -s "$SERIAL" shell dumpsys activity processes "$PKG" 2>/dev/null | head -80 > "${BASE}_proc.txt" || true
adb -s "$SERIAL" shell dumpsys batterystats --charged 2>/dev/null | tail -40 > "${BASE}_batterystats.txt" || true
adb -s "$SERIAL" exec-out screencap -p > "${BASE}_screen.png" || true

echo "snapshot: ${BASE}_*"
