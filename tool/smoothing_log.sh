#!/usr/bin/env bash
# Record device logcat for a mask-smoothing measurement run (T14.2, Android).
#
# Usage: tool/smoothing_log.sh <label>   e.g. tool/smoothing_log.sh a1-d012
#
# Start it in a terminal before `flutter run`, then Ctrl-C when the run is
# done (after the page logs `T133| STAGE ALL DONE`). Output:
#   doc/smoothing-raw/<label>.log      filtered raw logcat
#   doc/smoothing-raw/<label>_t133.txt only the T133| lines, with mask count
#
# iOS: no adb — capture with
#   flutter run 2>&1 | tee doc/smoothing-raw/iphone15.log
set -euo pipefail

label="${1:-}"
if [[ -z "$label" ]]; then
  echo "usage: $0 <label>" >&2
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out_dir="$repo_root/doc/smoothing-raw"
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
  grep 'T133|' "$logfile" >"$txtfile" || true
  masks=$(grep -c 'rev=' "$txtfile" || true)
  stages=$(grep -c 'SETTLED' "$txtfile" || true)
  echo "saved $logfile"
  echo "saved $txtfile ($masks masks, $stages stages settled)"
}
trap finish INT TERM EXIT

wait "$pid"
