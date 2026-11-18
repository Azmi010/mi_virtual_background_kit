#!/usr/bin/env bash
# T17.6: soak the new v0.2 paths on one device and sample memory throughout.
#
# Usage: tool/t176_test.sh <label> <device-id> [preview|adapter|all]
#   e.g. tool/t176_test.sh a1 RR8T601FP0R
#        tool/t176_test.sh iphone15 00008120-0016195A0CC20032 adapter
#
# Suites:
#   preview  100x preview start/stop with a renderer bound
#   adapter  20x LiveKit camera switch (restartTrack -> adapter re-attach)
#
# Output (doc/soak-raw/): <label>_<suite>.log, _markers.txt, _mem.txt (Android),
# <label>_<suite>.trace + _toc.xml (iOS), plus _logcat.txt on Android.
#
# The adapter suite needs the LiveKit dev server. Android uses adb reverse;
# on iOS pass LK_URL=ws://HOST_IP:7880 and tap Allow on the Local Network dialog.
set -euo pipefail

label="${1:-}"
device="${2:-}"
suite="${3:-all}"
if [[ -z "$label" || -z "$device" ]]; then
  echo "usage: $0 <label> <device-id> [preview|adapter|all]" >&2
  exit 1
fi

selected=()
case "$suite" in
  all) selected=(preview adapter) ;;
  preview|adapter) selected=("$suite") ;;
  *) echo "unknown suite: $suite" >&2; exit 1 ;;
esac

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out_dir="$repo_root/doc/soak-raw"
mkdir -p "$out_dir"

android=false
logcat_pid=""
if adb -s "$device" get-state >/dev/null 2>&1; then
  android=true
  adb -s "$device" reverse tcp:7880 tcp:7880
  adb -s "$device" logcat -c
  adb -s "$device" logcat -v time \
    flutter:V MiVBG:V MiVBGCompositor:V AndroidRuntime:E DEBUG:E '*:S' \
    >"$out_dir/${label}_logcat.txt" &
  logcat_pid=$!
fi

overall=0
for s in "${selected[@]}"; do
  base="$out_dir/${label}_${s}"
  logfile="$base.log"
  rcfile="$base.rc"
  extra=(--dart-define="SOAK_SUITE=$s")
  if [[ -n "${LK_URL:-}" ]]; then
    extra+=(--dart-define="LK_URL=$LK_URL")
  fi

  # Snapshot Runner PIDs before launch: a stale Runner.app can already be on
  # the device, and attaching to it records an idle process (tiny footprint).
  baseline_pids=""
  if ! $android; then
    xcrun devicectl device info processes --device "$device" -q \
      --json-output "${base}_procs_before.json" >/dev/null 2>&1 || true
    baseline_pids="$(python3 - "${base}_procs_before.json" <<'PY'
import json
import sys

try:
    data = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
pids = []
for process in data.get('result', {}).get('runningProcesses', []):
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
            pids.append(str(int(identifier)))
print(' '.join(pids))
PY
)"
  fi

  echo "== T17.6 $s ($device) =="
  (
    set +e
    (
      cd "$repo_root/example"
      flutter test integration_test/soak_new_paths_test.dart -d "$device" \
        "${extra[@]+"${extra[@]}"}"
    ) 2>&1 | tee "$logfile"
    echo "${PIPESTATUS[0]}" >"$rcfile"
  ) &
  runner_pid=$!

  mem_pid=""
  trace_pid=""
  if $android; then
    (
      while kill -0 "$runner_pid" 2>/dev/null; do
        app_pid="$(adb -s "$device" shell \
          pidof com.azmi010.mi_virtual_background_kit_example 2>/dev/null || true)"
        if [[ -n "$app_pid" ]]; then
          pss="$(adb -s "$device" shell dumpsys meminfo "$app_pid" 2>/dev/null \
            | awk '/TOTAL PSS/{print $3}' || true)"
          echo "$(date +%H:%M:%S) pid=$app_pid pss_kb=${pss:-?}"
        else
          echo "$(date +%H:%M:%S) pid=DEAD"
        fi
        sleep 5
      done
    ) >"${base}_mem.txt" &
    mem_pid=$!
  else
    app_pid=""
    for attempt in {1..30}; do
      xcrun devicectl device info processes --device "$device" -q \
        --json-output "${base}_procs.json" >/dev/null 2>&1 || true
      app_pid="$(python3 - "${base}_procs.json" "$baseline_pids" <<'PY'
import json
import sys

try:
    data = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
baseline = set(sys.argv[2].split()) if len(sys.argv) > 2 else set()
processes = data.get('result', {}).get('runningProcesses', [])
pids = []
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
        if identifier is not None and str(int(identifier)) not in baseline:
            pids.append(int(identifier))
if pids:
    print(max(pids))
PY
)"
      [[ -n "$app_pid" ]] && break
      sleep 3
    done

    if [[ -z "$app_pid" ]]; then
      echo "warning: Runner PID not found; skipping Instruments capture" >&2
    else
      echo "app pid=$app_pid"
      # xctrace refuses an existing output path; start from a clean trace.
      rm -rf "${base}.trace" "${base}_toc.xml"
      # Background jobs in non-interactive bash ignore SIGINT by default.
      # Reset it in the child so Ctrl-C (SIGINT) finalizes the trace cleanly.
      (
        trap - INT
        exec xcrun xctrace record \
          --template 'Activity Monitor' \
          --device "$device" \
          --attach "$app_pid" \
          --time-limit 15m \
          --output "${base}.trace" \
          --no-prompt
      ) >"${base}_xctrace.log" 2>&1 &
      trace_pid=$!
    fi
  fi

  wait "$runner_pid" || true
  rc="$(cat "$rcfile" 2>/dev/null || echo 1)"

  if [[ -n "$mem_pid" ]]; then
    kill "$mem_pid" 2>/dev/null || true
    wait "$mem_pid" 2>/dev/null || true
  fi
  if [[ -n "$trace_pid" ]]; then
    # SIGINT is the documented Ctrl-C path and finalizes the trace. TERM/KILL
    # are only fallbacks so the script never waits out the full --time-limit.
    kill -INT "$trace_pid" 2>/dev/null || true
    for attempt in {1..10}; do
      kill -0 "$trace_pid" 2>/dev/null || break
      sleep 1
    done
    if kill -0 "$trace_pid" 2>/dev/null; then
      kill -TERM "$trace_pid" 2>/dev/null || true
      for attempt in {1..5}; do
        kill -0 "$trace_pid" 2>/dev/null || break
        sleep 1
      done
    fi
    if kill -0 "$trace_pid" 2>/dev/null; then
      kill -KILL "$trace_pid" 2>/dev/null || true
    fi
    wait "$trace_pid" 2>/dev/null || true
    xcrun xctrace export --input "${base}.trace" --toc \
      --output "${base}_toc.xml" 2>/dev/null || true
  fi

  grep -E 'T176\||All tests passed|Some tests failed|Test failed' "$logfile" \
    >"${base}_markers.txt" || true
  echo "saved $logfile"
  echo "saved ${base}_markers.txt, rc=$rc"
  [[ "$rc" -eq 0 ]] || overall=1
done

if $android && [[ -n "$logcat_pid" ]]; then
  kill "$logcat_pid" 2>/dev/null || true
  wait "$logcat_pid" 2>/dev/null || true
  rg -i 'FATAL EXCEPTION|AndroidRuntime.*Exception|ANR in|tombstone' \
    "$out_dir/${label}_logcat.txt" >"$out_dir/${label}_crash.txt" || true
  echo "saved $out_dir/${label}_logcat.txt"
  echo "saved $out_dir/${label}_crash.txt"
fi

exit "$overall"
