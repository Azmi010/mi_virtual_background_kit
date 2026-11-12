#!/usr/bin/env bash
# Run the T14.4 fallback-recovery device test and store the transcript.
#
# Usage: tool/fallback_recovery_test.sh <label> <device-id>
#   e.g. tool/fallback_recovery_test.sh a1 RR8T601FP0R
#        tool/fallback_recovery_test.sh iphone15 00008120-0016195A0CC20032
#
# Output (doc/fallback-raw/):
#   <label>.log          full flutter test output (incl. T144| markers)
#   <label>_t144.txt     only the T144| markers, for analysis
#   <label>_logcat.txt   raw logcat with native lines (Android only)
#
# Camera permission must already be granted (run the example app once first).
set -euo pipefail

label="${1:-}"
device="${2:-}"
if [[ -z "$label" || -z "$device" ]]; then
  echo "usage: $0 <label> <device-id>" >&2
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out_dir="$repo_root/doc/fallback-raw"
mkdir -p "$out_dir"
logfile="$out_dir/$label.log"
txtfile="$out_dir/${label}_t144.txt"

logcat_pid=""
if adb -s "$device" get-state >/dev/null 2>&1; then
  adb -s "$device" logcat -c
  adb -s "$device" logcat -v time \
    flutter:V MiVBG:V MiVBGCompositor:V AndroidRuntime:E DEBUG:E '*:S' \
    >"$out_dir/${label}_logcat.txt" &
  logcat_pid=$!
fi

set +e
(
  cd "$repo_root/example"
  flutter test integration_test/fallback_recovery_test.dart -d "$device"
) 2>&1 | tee "$logfile"
status=${PIPESTATUS[0]}
set -e

if [[ -n "$logcat_pid" ]]; then
  kill "$logcat_pid" 2>/dev/null || true
  wait "$logcat_pid" 2>/dev/null || true
fi

grep 'T144|' "$logfile" >"$txtfile" || true
markers=$(grep -c 'T144|' "$txtfile" || true)
echo "saved $logfile"
echo "saved $txtfile ($markers T144 markers)"
if [[ -n "$logcat_pid" ]]; then
  echo "saved $out_dir/${label}_logcat.txt"
fi
exit "$status"
