#!/usr/bin/env bash
# T17.1 benchmark driver: one 10-minute session per effect on one device.
# Stores the Dart transcript, parsed T171 markers, and (on Android) native
# logcat plus 1-minute CPU/mem/battery samples and a closing dumpsys cpuinfo
# snapshot for analysis afterwards.
#
# Usage: tool/bench_v02.sh <label> <device-id> [effect] [seconds]
#   effect: none | blur | image | color   (default blur)
#   seconds: 600 (default; use 60 for a smoke test)
# iOS: connect over USB. `flutter test` cannot launch on a wirelessly tethered
# iOS device; battery is measured in a separate untethered run (see below).
#
# Output: doc/bench-v02-raw/<label>_<effect>.*
set -euo pipefail

label="${1:-}"
device="${2:-}"
effect="${3:-blur}"
seconds="${4:-600}"
if [[ -z "$label" || -z "$device" ]]; then
  echo "usage: $0 <label> <device-id> [none|blur|image|color] [seconds]" >&2
  exit 1
fi

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="$root/doc/bench-v02-raw"
mkdir -p "$out"
base="$out/${label}_${effect}"
pkg="com.azmi010.mi_virtual_background_kit_example"

logpid=""
samplepid=""
cleanup() {
  [[ -n "$samplepid" ]] && kill "$samplepid" 2>/dev/null || true
  [[ -n "$logpid" ]] && kill "$logpid" 2>/dev/null || true
}
trap cleanup EXIT

android=0
if adb -s "$device" get-state >/dev/null 2>&1; then android=1; fi

bat0=""
if (( android )); then
  adb -s "$device" logcat -c
  adb -s "$device" logcat -v time >"${base}_logcat.txt" 2>&1 &
  logpid=$!
  batt0="$(adb -s "$device" shell dumpsys battery 2>/dev/null || true)"
  bat0="$(printf '%s\n' "$batt0" | awk '/level:/{print $2}')"
  plug0="$(printf '%s\n' "$batt0" | awk '/ plugged:/{print $2}')"
  bstate0="$(printf '%s\n' "$batt0" | awk '/status:/{print $2}')"
  adb -s "$device" shell top -b -n 1 2>/dev/null | head -1 \
    >"${base}_top_header.txt" || true
  (
    while true; do
      pss="$(adb -s "$device" shell dumpsys meminfo "$pkg" 2>/dev/null | awk '/TOTAL PSS/{print $3}' || true)"
      cpu="$(adb -s "$device" shell "top -b -n 1 -p \$(pidof $pkg) | tail -1" 2>/dev/null || true)"
      batt="$(adb -s "$device" shell dumpsys battery 2>/dev/null || true)"
      bat="$(printf '%s\n' "$batt" | awk '/level:/{print $2}')"
      plug="$(printf '%s\n' "$batt" | awk '/ plugged:/{print $2}')"
      bstate="$(printf '%s\n' "$batt" | awk '/status:/{print $2}')"
      echo "$(date +%H:%M:%S) pss_kb=${pss:-?} bat=${bat:-?} plugged=${plug:-?} bstate=${bstate:-?} cpu=${cpu:-?}" \
        >>"${base}_samples.txt"
      sleep 60
    done
  ) &
  samplepid=$!
  echo "battery start: ${bat0}% plugged=${plug0:-n/a} bstate=${bstate0:-?} (3=discharging)" \
    | tee "${base}_summary.txt"
else
  {
    echo "iOS: record battery % from Settings > Battery before and after this run."
    echo "CPU/memory via Instruments is covered by T17.2."
  } | tee "${base}_summary.txt"
fi

set +e
(
  cd "$root/example"
  flutter test integration_test/benchmark_v02_test.dart -d "$device" \
    --dart-define=BENCH_EFFECT="$effect" \
    --dart-define=BENCH_SECONDS="$seconds"
) 2>&1 | tee "${base}.log"
status=${PIPESTATUS[0]}
set -e

if (( android )); then
  kill "$samplepid" 2>/dev/null || true
  wait "$samplepid" 2>/dev/null || true
  samplepid=""
  adb -s "$device" shell dumpsys cpuinfo >"${base}_cpuinfo.txt" 2>/dev/null || true
  batt1="$(adb -s "$device" shell dumpsys battery 2>/dev/null || true)"
  bat1="$(printf '%s\n' "$batt1" | awk '/level:/{print $2}')"
  plug1="$(printf '%s\n' "$batt1" | awk '/ plugged:/{print $2}')"
  bstate1="$(printf '%s\n' "$batt1" | awk '/status:/{print $2}')"
  echo "battery end: ${bat1}% plugged=${plug1:-n/a} bstate=${bstate1:-?} (start ${bat0}%, drop $((bat0 - bat1)) points)" \
    | tee -a "${base}_summary.txt"
  kill "$logpid" 2>/dev/null || true
  wait "$logpid" 2>/dev/null || true
  logpid=""
fi

grep -F 'T171|' "${base}.log" >"${base}_t171.txt" || true
echo "saved ${base}.* ($(wc -l <"${base}_t171.txt" | tr -d ' ') markers)"
exit "$status"
