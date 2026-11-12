#!/usr/bin/env python3
"""Aggregate T133| temporal-smoothing metric lines (T14.2 / T14.3, FR-20).

Each native mask emits one line:

    T133| m=adaptive v=0.70 d0=0.10 st=still rev=3 chg=120 d=1.2 lag=4.5 px=49152 us=62 fps=29.7

- rev   pixels flipping class A->B->A across three masks (edge flicker)
- chg   pixels changing class vs the previous mask (motion + flicker bound)
- d     mean |raw - displayed| before the update, % of range (innovation)
- lag   mean |displayed - raw|, % of range (ghosting proxy)
- us    cost of smoothing + metrics per mask, microseconds
- d0    adaptive innovation threshold (distinguished tuning variants)
Warmup masks (d = -1, right after a variant/stage switch) are skipped.

Usage: python3 tool/smoothing_metrics.py [logfile ...]
Default input: doc/smoothing-raw/*_t133.txt
(iOS: pass doc/smoothing-raw/iphone15.log)
"""

import glob
import re
import statistics
import sys

LINE = re.compile(
    r"T133\| m=(?P<m>\w+) v=(?P<v>[\d.]+) d0=(?P<d0>[\d.]+) st=(?P<st>\S+) "
    r"rev=(?P<rev>-?\d+) chg=(?P<chg>-?\d+) d=(?P<d>-?[\d.]+) "
    r"lag=(?P<lag>-?[\d.]+) px=(?P<px>\d+) us=(?P<us>\d+) fps=(?P<fps>-?[\d.]+)"
)
# Optional `adb logcat -v time` prefix, used for the mask-rate column.
TS = re.compile(r"^(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})\.(\d{3})")


def _stamp(line: str):
    m = TS.match(line)
    if not m:
        return None
    mo, day, h, mi, s, ms = (int(x) for x in m.groups())
    return (((mo * 31 + day) * 24 + h) * 60 + mi) * 60 + s + ms / 1000.0


def parse(paths):
    rows = []
    warmup = 0
    for path in paths:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                m = LINE.search(line)
                if not m:
                    continue
                if float(m["d"]) < 0:
                    warmup += 1
                    continue
                rows.append(
                    {
                        "file": path,
                        "m": m["m"],
                        "v": float(m["v"]),
                        "d0": float(m["d0"]),
                        "st": m["st"],
                        "rev": int(m["rev"]),
                        "chg": int(m["chg"]),
                        "d": float(m["d"]),
                        "lag": float(m["lag"]),
                        "us": int(m["us"]),
                        "fps": float(m["fps"]),
                        "ts": _stamp(line),
                    }
                )
    return rows, warmup


def _mean(vals):
    return statistics.fmean(vals) if vals else float("nan")


def _group(rows, key):
    out = {}
    for r in rows:
        out.setdefault(key(r), []).append(r)
    return out


def _fmt_rate(recs):
    stamps = [r["ts"] for r in recs if r["ts"] is not None]
    if len(stamps) < 2:
        return "–"
    span = max(stamps) - min(stamps)
    if span <= 0:
        return "–"
    return f"{len(recs) / span:.1f}"


def _label(mode, value, d0):
    if mode == "none":
        return "none"
    if mode == "adaptive":
        return f"adaptive {value:g} d0={d0:g}"
    return f"{mode} {value:g}"


def table(rows, stage):
    sel = [r for r in rows if r["st"] == stage]
    if not sel:
        return
    groups = _group(sel, lambda r: (r["m"], r["v"], r["d0"]))
    baseline_recs = [r for r in sel if r["m"] == "none"]
    base_rev = _mean([r["rev"] for r in baseline_recs])

    print(f"\n### stage `{stage}`\n")
    print("| variant | n | rev/mask | chg/mask | d% | lag% | us/mask | fps | masks/s | flicker vs none |")
    print("|---|---|---|---|---|---|---|---|---|---|")
    for (mode, value, d0), recs in sorted(groups.items()):
        rev = _mean([r["rev"] for r in recs])
        if baseline_recs and mode != "none":
            delta = f"{100.0 * (1 - rev / base_rev):+.0f}%" if base_rev > 0 else "–"
        elif mode == "none":
            delta = "baseline"
        else:
            delta = "–"
        print(
            f"| {_label(mode, value, d0)} "
            f"| {len(recs)} "
            f"| {rev:.1f} "
            f"| {_mean([r['chg'] for r in recs]):.1f} "
            f"| {_mean([r['d'] for r in recs]):.2f} "
            f"| {_mean([r['lag'] for r in recs]):.2f} "
            f"| {_mean([r['us'] for r in recs]):.0f} "
            f"| {_mean([r['fps'] for r in recs]):.1f} "
            f"| {_fmt_rate(recs)} "
            f"| {delta} |"
        )


def main() -> None:
    paths = sys.argv[1:] or sorted(glob.glob("doc/smoothing-raw/*_t133.txt"))
    if not paths:
        sys.exit("no T133 log files found (see tool/smoothing_log.sh)")
    rows, warmup = parse(paths)
    if not rows:
        sys.exit(f"no T133 metric lines in: {', '.join(paths)}")
    print(f"parsed {len(rows)} masks from {len(paths)} file(s); skipped {warmup} warmup")
    for stage in sorted({r["st"] for r in rows}):
        table(rows, stage)


if __name__ == "__main__":
    main()
