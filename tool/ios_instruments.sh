#!/usr/bin/env bash
# T17.2 iOS CPU/memory capture with Instruments Activity Monitor.
#
# Precondition: the example app is already running on the device and the
# desired effect is applied. This script only attaches the recorder.
# The device may host several Runner.app binaries (for example one from a
# previous flutter test install). Pass the exact PID as the 4th argument when
# `--attach` must target one of them.
#
# Usage: tool/ios_instruments.sh <label> <device-udid> [duration] [pid]
#   duration: xctrace time limit, default 30m (e.g. 5m, 30m, 1800s)
#   pid: force the app PID; without it, the highest matching PID is used
#
# Output: doc/ios-instruments-raw/<label>.{trace,toc.xml,processes.json,processes.xml}
set -euo pipefail

label="${1:-}"
device="${2:-}"
duration="${3:-30m}"
forced_pid="${4:-}"
if [[ -z "$label" || -z "$device" ]]; then
  echo "usage: $0 <label> <device-udid> [duration] [pid]" >&2
  exit 1
fi

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="$root/doc/ios-instruments-raw"
mkdir -p "$out"
base="$out/$label"

xcrun devicectl device info processes --device "$device" -q \
  --json-output "${base}_processes.json"

if [[ -n "$forced_pid" ]]; then
  pid="$forced_pid"
else
  pid="$(python3 - "${base}_processes.json" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1]))
processes = data.get('result', {}).get('runningProcesses', [])
candidates = []
for process in processes:
    executable = (
        process.get('executable')
        or process.get('ExecutablePath')
        or process.get('executablePath')
        or ''
    )
    if isinstance(executable, dict):
        executable = executable.get('path') or executable.get('url') or ''
    if 'miVirtualBackgroundKitExample' in executable or 'Runner.app' in executable:
        identifier = (
            process.get('processIdentifier')
            or process.get('pid')
            or process.get('processID')
        )
        if identifier is not None:
            candidates.append(int(identifier))
if candidates:
    # Several Runner.app installs can coexist; prefer the newest PID.
    print(max(candidates))
PY
)"
fi
if [[ -z "$pid" ]]; then
  echo "error: example app process not found on $device" >&2
  exit 1
fi
echo "app pid=$pid, recording $duration"

xcrun xctrace record \
  --template 'Activity Monitor' \
  --device "$device" \
  --attach "$pid" \
  --time-limit "$duration" \
  --output "${base}.trace" \
  --no-prompt

xcrun xctrace export --input "${base}.trace" --toc \
  --output "${base}_toc.xml"
xcrun xctrace export --input "${base}.trace" \
  --xpath '/trace-toc/run[@number="1"]/data/table[@schema="activity-monitor-process-live"]' \
  --output "${base}_processes.xml" || true

echo "saved ${base}.*"
