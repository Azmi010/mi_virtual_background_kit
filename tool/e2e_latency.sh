#!/usr/bin/env bash
# T17.3 device driver: capture camera-to-output latency samples from
# metricsStream. Stores the full transcript and parsed T173 markers.
#
# Usage: tool/e2e_latency.sh <label> <device-id> [seconds]
set -euo pipefail

label="${1:-}"
device="${2:-}"
seconds="${3:-120}"
if [[ -z "$label" || -z "$device" ]]; then
  echo "usage: $0 <label> <device-id> [seconds]" >&2
  exit 1
fi

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="$root/doc/e2e-raw"
mkdir -p "$out"
base="$out/$label"

set +e
(
  cd "$root/example"
  flutter test integration_test/e2e_latency_test.dart -d "$device" \
    --dart-define=E2E_SECONDS="$seconds"
) 2>&1 | tee "${base}.log"
status=${PIPESTATUS[0]}
set -e

grep -F 'T173|' "${base}.log" >"${base}_t173.txt" || true
echo "saved ${base}.log and ${base}_t173.txt"
exit "$status"
