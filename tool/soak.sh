#!/usr/bin/env bash
# T6.5 Android soak: keep example app running N minutes, sample mem/cpu/battery,
# watch logcat for crash/fallback. Usage: tool/soak.sh [minutes]  (default 30)
set -euo pipefail

SERIAL="${ANDROID_SERIAL:-RR8T601FP0R}"
PKG="com.azmi010.mi_virtual_background_kit_example"
MINUTES="${1:-30}"
OUT_DIR="doc/bench-raw"
mkdir -p "$OUT_DIR"
TS="$(date +%Y%m%d_%H%M%S)"
BASE="$OUT_DIR/a1_soak_${TS}"
LOG="${BASE}_logcat.txt"

adb -s "$SERIAL" shell svc power stayon usb
adb -s "$SERIAL" logcat -c
adb -s "$SERIAL" logcat -v time > "$LOG" 2>&1 &
LOGPID=$!
trap 'kill $LOGPID 2>/dev/null || true' EXIT

adb -s "$SERIAL" shell am force-stop "$PKG"
adb -s "$SERIAL" shell am start -n "$PKG/.MainActivity" >/dev/null
# Fail fast: app must be alive before the soak loop starts.
sleep 3
if ! adb -s "$SERIAL" shell pidof "$PKG" >/dev/null 2>&1; then
  echo "error: $PKG failed to start (reinstall example apk?)" >&2
  exit 1
fi
echo "started app, soak ${MINUTES}m, log=$LOG"

END=$(( $(date +%s) + MINUTES * 60 ))
N=0
while [ "$(date +%s)" -lt "$END" ]; do
  N=$((N+1))
  STAMP="$(date +%H:%M:%S)"
  ALIVE=$(adb -s "$SERIAL" shell pidof "$PKG" || true)
  MEM=$(adb -s "$SERIAL" shell dumpsys meminfo "$PKG" 2>/dev/null | awk '/TOTAL PSS/{print $3}' || echo '?')
  BAT=$(adb -s "$SERIAL" shell dumpsys battery | awk '/level:/{print $2}' || echo '?')
  echo "$STAMP sample=$N pid=${ALIVE:-DEAD} pss_kb=$MEM bat=$BAT" | tee -a "${BASE}_samples.txt"
  if [ -z "${ALIVE:-}" ]; then
    echo "PROCESS DEAD at sample $N" | tee -a "${BASE}_samples.txt"
    break
  fi
  sleep 60
done

kill $LOGPID 2>/dev/null || true
wait $LOGPID 2>/dev/null || true

echo '--- crash/fallback scan ---'
rg -i 'FATAL EXCEPTION|AndroidRuntime.*Exception|ANR in|Performance drop|Critical performance|auto-disabled|tombstone' "$LOG" | tee "${BASE}_events.txt" || echo 'no crash/fallback lines'
echo '--- MiVBG frame passes (last) ---'
rg 'Frame pass|MiVBG' "$LOG" | tail -5 || true
echo "soak done -> ${BASE}*"
