#!/usr/bin/env bash
# Record device logcat for a T14.5 segmentation-strategy run (FR-22, Android).
#
# Usage: tool/t145_log.sh <label>   e.g. tool/t145_log.sh a1-t145
#
# Start it in a terminal before `flutter run`, then Ctrl-C when the run is
# done (after the page logs `T145| STAGE ALL DONE`). Output:
#   doc/t145-raw/<label>.log        filtered raw logcat
#   doc/t145-raw/<label>_t133.txt   T133| metric lines + T145| markers
#
# iOS: no adb — capture with
#   flutter run 2>&1 | tee doc/t145-raw/iphone15.log
set -euo pipefail

label="${1:-}"
if [[ -z "$label" ]]; then
  echo "usage: $0 <label>" >&2
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out_dir="$repo_root/doc/t145-raw"
mkdir -p "$out_dir"
logfile="$out_dir/$label.log"
txtfile="$out_dir/${label}_t133.txt"

if ! adb get-state >/dev/null 2>&1; then
  echo "no adb device connected" >&2
  exit 1
fi

adb logcat -c
echo "recording to $logfile — Ctrl-C to stop"
adb logcat -v time \
  flutter:V MiVBG:V MiVBGCompositor:V FlutterWebRTCPlugin:V AndroidRuntime:E DEBUG:E '*:S' \
  >"$logfile" &
pid=$!

finished=0
finish() {
  [[ $finished -eq 1 ]] && return
  finished=1
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  grep -E 'T133\||T145\|' "$logfile" >"$txtfile" || true
  masks=$(grep -c 'gap=' "$txtfile" || true)
  configs=$(grep -c 'CONFIG .* DONE' "$txtfile" || true)
  echo "saved $logfile"
  echo "saved $txtfile ($masks masks, $configs configs done)"
}
trap finish INT TERM EXIT

wait "$pid"
