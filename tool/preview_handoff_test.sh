#!/usr/bin/env bash
# T16.3: run the preview handoff integration test on a real Android device.
#
# Usage: tool/preview_handoff_test.sh <device-id>
# Start the LiveKit dev server first: docker start t131-lk
set -euo pipefail

device="${1:-}"
if [[ -z "$device" ]]; then
  echo "usage: $0 <device-id>" >&2
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out_dir="$repo_root/doc/preview-raw"
mkdir -p "$out_dir"

adb -s "$device" reverse tcp:7880 tcp:7880
adb -s "$device" logcat -c
adb -s "$device" logcat -v time \
  flutter:V MiVBG:V MiVBGCompositor:V AndroidRuntime:E DEBUG:E '*:S' \
  >"$out_dir/handoff_logcat.txt" &
logcat_pid=$!

set +e
(
  cd "$repo_root/example"
  flutter test integration_test/preview_handoff_test.dart -d "$device"
) 2>&1 | tee "$out_dir/handoff_test.log"
status=${PIPESTATUS[0]}
set -e

kill "$logcat_pid" 2>/dev/null || true
wait "$logcat_pid" 2>/dev/null || true

grep 'T163|' "$out_dir/handoff_test.log" >"$out_dir/handoff_markers.txt" || true

echo "saved $out_dir/handoff_test.log"
echo "saved $out_dir/handoff_logcat.txt"
echo "saved $out_dir/handoff_markers.txt"
exit "$status"
