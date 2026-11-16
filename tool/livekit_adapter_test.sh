#!/usr/bin/env bash
# Run the T15.4 LiveKit adapter lifecycle test on a real Android device.
#
# Usage: tool/livekit_adapter_test.sh <device-id>
#   e.g. tool/livekit_adapter_test.sh RR8T601FP0R
#
# Start the dev server before running. With the existing Docker container:
#   docker start t131-lk
# Or without Docker:
#   livekit-server --dev --bind 0.0.0.0
# Camera permission must already be granted on the device.
set -euo pipefail

device="${1:-}"
if [[ -z "$device" ]]; then
  echo "usage: $0 <device-id>" >&2
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out_dir="$repo_root/doc/livekit-raw"
mkdir -p "$out_dir"

adb -s "$device" reverse tcp:7880 tcp:7880
adb -s "$device" logcat -c
adb -s "$device" logcat -v time \
  flutter:V MiVBG:V MiVBGCompositor:V AndroidRuntime:E DEBUG:E '*:S' \
  >"$out_dir/adapter_logcat.txt" &
logcat_pid=$!

set +e
(
  cd "$repo_root/example"
  flutter test integration_test/livekit_adapter_test.dart -d "$device"
) 2>&1 | tee "$out_dir/adapter_test.log"
status=${PIPESTATUS[0]}
set -e

kill "$logcat_pid" 2>/dev/null || true
wait "$logcat_pid" 2>/dev/null || true

echo "saved $out_dir/adapter_test.log"
echo "saved $out_dir/adapter_logcat.txt"
exit "$status"
