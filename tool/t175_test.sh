#!/usr/bin/env bash
# T17.5: run the v0.2 integration suites on one real device and save evidence.
#
# Usage: tool/t175_test.sh <label> <device-id> [kit|shared|fallback|preview|all]
#   e.g. tool/t175_test.sh a1 RR8T601FP0R
#        tool/t175_test.sh iphone15 00008120-0016195A0CC20032 shared
#
# Suites (also runnable on their own):
#   kit       T6.3 baseline: attach, effects, detach, dispose
#   shared    T17.5 shared/registry-replacement track (T175| markers)
#   fallback  T14.4 fallback + recovery (T144| markers)
#   preview   T16.3 preview handoff, needs the LiveKit dev server (T163| markers)
#
# Output (doc/t175-raw/): <label>_<suite>.log, <label>_<suite>_markers.txt,
# plus <label>_logcat.txt and <label>_probe.txt on Android.
#
# Android: the script sets `adb reverse tcp:7880` for the preview suite.
# iOS: start the dev server on 0.0.0.0 and pass the host IP, e.g.
#   LK_URL=ws://192.168.1.5:7880 tool/t175_test.sh iphone15 <udid> preview
# Camera permission must already be granted (run the example app once first).
set -euo pipefail

label="${1:-}"
device="${2:-}"
suite="${3:-all}"
if [[ -z "$label" || -z "$device" ]]; then
  echo "usage: $0 <label> <device-id> [kit|shared|fallback|preview|all]" >&2
  exit 1
fi

selected=()
case "$suite" in
  all) selected=(kit shared fallback preview) ;;
  kit|shared|fallback|preview) selected=("$suite") ;;
  *) echo "unknown suite: $suite" >&2; exit 1 ;;
esac

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out_dir="$repo_root/doc/t175-raw"
mkdir -p "$out_dir"

logcat_pid=""
if adb -s "$device" get-state >/dev/null 2>&1; then
  adb -s "$device" reverse tcp:7880 tcp:7880
  adb -s "$device" logcat -c
  adb -s "$device" logcat -v time \
    flutter:V MiVBG:V MiVBGCompositor:V AndroidRuntime:E DEBUG:E '*:S' \
    >"$out_dir/${label}_logcat.txt" &
  logcat_pid=$!
fi

failed=0
for s in "${selected[@]}"; do
  case "$s" in
    kit) file='integration_test/kit_test.dart' ;;
    shared) file='integration_test/shared_track_test.dart' ;;
    fallback) file='integration_test/fallback_recovery_test.dart' ;;
    preview) file='integration_test/preview_handoff_test.dart' ;;
  esac

  extra=()
  if [[ "$s" == 'preview' && -n "${LK_URL:-}" ]]; then
    extra+=(--dart-define="LK_URL=$LK_URL")
  fi

  logfile="$out_dir/${label}_${s}.log"
  markers="$out_dir/${label}_${s}_markers.txt"
  echo "== T17.5 $s ($device) =="
  set +e
  (
    cd "$repo_root/example"
    flutter test "$file" -d "$device" ${extra[@]+"${extra[@]}"}
  ) 2>&1 | tee "$logfile"
  rc=${PIPESTATUS[0]}
  set -e

  grep -E 'T175\||T144\||T163\|' "$logfile" >"$markers" || true
  count=$(grep -c -E 'T175\||T144\||T163\|' "$markers" || true)
  echo "saved $logfile"
  echo "saved $markers ($count markers), rc=$rc"
  if [[ "$rc" -ne 0 ]]; then failed=1; fi
done

if [[ -n "$logcat_pid" ]]; then
  kill "$logcat_pid" 2>/dev/null || true
  wait "$logcat_pid" 2>/dev/null || true
  grep 'T132| probe' "$out_dir/${label}_logcat.txt" \
    >"$out_dir/${label}_probe.txt" || true
  probes=$(grep -c 'T132| probe' "$out_dir/${label}_probe.txt" || true)
  echo "saved $out_dir/${label}_logcat.txt"
  echo "saved $out_dir/${label}_probe.txt ($probes probe lines)"
else
  echo "no adb device: skipping logcat (iOS markers are in the .log files)"
fi

exit "$failed"
