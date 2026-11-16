#!/usr/bin/env python3
"""T14.6 (FR-23): compare native fps between metrics-off and metrics-on phases.

Usage: tool/metrics_overhead.py doc/metrics-raw/<label>_phases.txt

Input is the `grep -E 'T146\\| PHASE|T133\\|'` extract of logcat produced by
tool/metrics_test.sh. T146 PHASE lines carry a logcat timestamp; every T133
line's `fps=` value is attributed to the phase whose window contains it.

Reports mean/median fps per phase and the on-vs-off delta. Reporting overhead
is acceptable when the delta is within run noise (< ~1 fps on a stable device).
"""
import re
import statistics
import sys

PHASE_RE = re.compile(r"^(\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+).*T146\| PHASE (\w+)")
FPS_RE = re.compile(r"fps=([0-9.]+)")


def to_seconds(stamp: str) -> float:
    # "11-16 14:03:21.123" (logcat -v time) -> seconds; only ordering
    # and diffs matter, so the date part is ignored.
    _, time = stamp.rsplit(" ", 1)
    h, m, rest = time.split(":")
    s, ms = rest.split(".")
    return ((int(h) * 60 + int(m)) * 60 + int(s)) + int(ms) / 1000.0


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2

    phases: list[tuple[float, str]] = []
    events: list[tuple[float, float]] = []  # (timestamp, fps)
    with open(sys.argv[1], encoding="utf-8", errors="replace") as fh:
        for line in fh:
            m = PHASE_RE.match(line)
            if m:
                phases.append((to_seconds(m.group(1)), m.group(2)))
                continue
            m = FPS_RE.search(line)
            if m:
                ts = line.split(" ", 2)
                if len(ts) >= 3:
                    try:
                        events.append(
                            (to_seconds(f"{ts[0]} {ts[1]}"), float(m.group(1)))
                        )
                    except ValueError:
                        pass

    if len(phases) < 4:
        print(f"need 4 PHASE markers (off/on/off/on), found {len(phases)}")
        return 1
    if not events:
        print("no T133 fps lines found")
        return 1

    windows = []
    for i in range(0, len(phases) - 1, 2):
        (t0, name), (t1, _) = phases[i], phases[i + 1]
        fps = [f for t, f in events if t0 <= t < t1]
        windows.append((name, fps))

    means = {}
    for name, fps in windows:
        if not fps:
            print(f"phase {name}: no fps samples")
            continue
        mean = statistics.fmean(fps)
        means[name] = mean
        print(
            f"phase {name}: n={len(fps)} mean={mean:.1f} "
            f"median={statistics.median(fps):.1f} "
            f"min={min(fps):.1f} max={max(fps):.1f}"
        )

    off = [v for k, v in means.items() if k.startswith("off")]
    on = means.get("on")
    if off and on is not None:
        off_mean = statistics.fmean(off)
        delta = on - off_mean
        pct = 100.0 * delta / off_mean if off_mean else 0.0
        print(f"on - off(mean) = {delta:+.1f} fps ({pct:+.1f}%)")
        verdict = "negligible" if abs(delta) < 1.0 else "REVIEW"
        print(f"overhead verdict (|delta| < 1 fps): {verdict}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
