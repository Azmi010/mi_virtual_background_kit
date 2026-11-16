#!/usr/bin/env bash
# Run the T14.6 metrics device test and store the transcript.
#
# Usage: tool/metrics_test.sh <label> <device-id>
#   e.g. tool/metrics_test.sh a1 RR8T601FP0R
#        tool/metrics_test.sh iphone15 00008120-0016195A0CC20032
#
# Output (doc/metrics-raw/):
#   <label>.log          full flutter test output (incl. T146| markers)
#   <label>_t146.txt     only the T146| markers, for analysis
#   <label>_logcat.txt   raw logcat with native T133| fps lines (Android only)
#
# Overhead comparison (FR-23 acceptance): mean native `T133| ... fps=`
# between the `PHASE off` / `PHASE on` / `PHASE off2` markers in the logcat.
# On iOS no adb exists — capture device logs separately with
# `xcrun devicectl` or compare via the T146 sample fps lines.
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
out_dir="$repo_root/doc/metrics-raw"
mkdir -p "$out_dir"
logfile="$out_dir/$label.log"
txtfile="$out_dir/${label}_t146.txt"

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
  flutter test integration_test/metrics_test.dart -d "$device"
) 2>&1 | tee "$logfile"
status=${PIPESTATUS[0]}
set -e

if [[ -n "$logcat_pid" ]]; then
  kill "$logcat_pid" 2>/dev/null || true
  wait "$logcat_pid" 2>/dev/null || true
fi

grep 'T146|' "$logfile" >"$txtfile" || true
markers=$(grep -c 'T146|' "$txtfile" || true)
echo "saved $logfile"
echo "saved $txtfile ($markers T146 markers)"
if [[ -n "$logcat_pid" ]]; then
  grep -E 'T146\| PHASE|T133\|' "$out_dir/${label}_logcat.txt" \
    >"$out_dir/${label}_phases.txt" || true
  phases=$(grep -c 'T146| PHASE' "$out_dir/${label}_phases.txt" || true)
  masks=$(grep -c 'T133|' "$out_dir/${label}_phases.txt" || true)
  echo "saved $out_dir/${label}_logcat.txt"
  echo "saved $out_dir/${label}_phases.txt ($phases phase markers, $masks T133 lines)"
fi
exit "$status"
