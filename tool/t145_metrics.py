#!/usr/bin/env python3
"""Aggregate T14.5 segmentation-strategy metric lines (FR-22, ADR 0002 §8).

Extends the T133| line with three freshness fields:

    T133| m=adaptive v=0.70 d0=0.06 st=ls256 rev=3 chg=120 d=1.2 lag=4.5 \
          px=49152 us=62 fps=29.7 gap=208 inf=88 iv=5

- gap  ms since the previous logged mask (mask freshness; -1 = first mask)
- inf  last segmentation inference, ms
- iv   live adaptive scheduling interval, frames
- st   config tag from the example page: sq256 / sq144 / ls256 / ls144

Per config it reports n, gap (mean/p50/p95), inference, interval, fps, and
masks/s, plus the gap change vs the first config present (baseline sq256).
Warmup masks (d < 0 after a stage/model switch), the first mask (gap = -1),
and the first 3 valid masks of each stage are skipped for settle.

Usage: python3 tool/t145_metrics.py [logfile ...]
Default input: doc/t145-raw/*_t133.txt
"""

import glob
import re
import statistics
import sys

LINE = re.compile(
    r"T133\| m=(?P<m>\w+) v=(?P<v>[\d.]+) d0=(?P<d0>[\d.]+) st=(?P<st>\S+) "
    r"rev=(?P<rev>-?\d+) chg=(?P<chg>-?\d+) d=(?P<d>-?[\d.]+) "
    r"lag=(?P<lag>-?[\d.]+) px=(?P<px>\d+) us=(?P<us>\d+) fps=(?P<fps>-?[\d.]+)"
    r"(?: gap=(?P<gap>-?\d+))?(?: inf=(?P<inf>-?\d+))?(?: iv=(?P<iv>\d+))?"
)
# Optional `adb logcat -v time` prefix, used for the masks/s column.
TS = re.compile(r"^(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})\.(\d{3})")

SETTLE_MASKS = 3


def _stamp(line: str):
    m = TS.match(line)
    if not m:
        return None
    mo, day, h, mi, s, ms = (int(x) for x in m.groups())
    return (((mo * 31 + day) * 24 + h) * 60 + mi) * 60 + s + ms / 1000.0


def parse(paths):
    rows, warmup = [], 0
    seen_per_stage = {}
    for path in paths:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                m = LINE.search(line)
                if not m:
                    continue
                if float(m["d"]) < 0 or m["gap"] in (None, "-1"):
                    warmup += 1
                    continue
                stage = m["st"]
                n = seen_per_stage.get(stage, 0)
                if n < SETTLE_MASKS:
                    seen_per_stage[stage] = n + 1
                    warmup += 1
                    continue
                seen_per_stage[stage] = n + 1
                rows.append(
                    {
                        "st": stage,
                        "gap": int(m["gap"]),
                        "inf": int(m["inf"]) if m["inf"] is not None else None,
                        "iv": int(m["iv"]) if m["iv"] is not None else None,
                        "fps": float(m["fps"]),
                        "ts": _stamp(line),
                    }
                )
    return rows, warmup


def _pct(vals, q):
    if not vals:
        return float("nan")
    s = sorted(vals)
    return s[min(len(s) - 1, int(q * len(s)))]


def _rate(recs):
    stamps = [r["ts"] for r in recs if r["ts"] is not None]
    if len(stamps) < 2:
        return float("nan")
    span = max(stamps) - min(stamps)
    return len(recs) / span if span > 0 else float("nan")


def table(rows):
    stages = list(dict.fromkeys(r["st"] for r in rows))
    groups = {s: [r for r in rows if r["st"] == s] for s in stages}
    base_gap = statistics.fmean(r["gap"] for r in groups[stages[0]])

    print(
        "| config | n | gap mean | gap p50 | gap p95 | inf mean "
        "| iv mean | fps | masks/s | gap vs base |"
    )
    print("|---|---|---|---|---|---|---|---|---|---|")
    for s in stages:
        recs = groups[s]
        gaps = [r["gap"] for r in recs]
        infs = [r["inf"] for r in recs if r["inf"] is not None]
        ivs = [r["iv"] for r in recs if r["iv"] is not None]
        gap_mean = statistics.fmean(gaps)
        inf_col = f"{statistics.fmean(infs):.0f} ms" if infs else "–"
        iv_col = f"{statistics.fmean(ivs):.1f}" if ivs else "–"
        fps = statistics.fmean(r["fps"] for r in recs)
        rate = _rate(recs)
        delta = (
            "baseline"
            if s == stages[0]
            else f"{100.0 * (gap_mean / base_gap - 1):+.1f}%"
        )
        print(
            f"| {s} | {len(recs)} | {gap_mean:.0f} ms | {_pct(gaps, 0.50):.0f} ms "
            f"| {_pct(gaps, 0.95):.0f} ms | {inf_col} | {iv_col} "
            f"| {fps:.1f} | {rate:.1f} | {delta} |"
        )


def main() -> None:
    paths = sys.argv[1:] or sorted(glob.glob("doc/t145-raw/*_t133.txt"))
    if not paths:
        sys.exit("no T145 log files found (see tool/t145_log.sh)")
    rows, warmup = parse(paths)
    if not rows:
        sys.exit(f"no T133 metric lines with gap= in: {', '.join(paths)}")
    print(f"parsed {len(rows)} masks from {len(paths)} file(s); skipped {warmup} warmup/settle")
    table(rows)


if __name__ == "__main__":
    main()
