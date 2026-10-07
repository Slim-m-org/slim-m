# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Builds perf/baselines/<version>.json from a release run's own measurements.

perf.yml's baseline job calls this after `cargo bench` and several runs of
perf/measure-idle-rss.sh: each criterion benchmark's mean, and the median of
each RSS figure across the runs. `environment` names where it was measured,
since a CI runner's RSS is only comparable with another run on the same
runner; see perf/README.md.
"""
import argparse
import json
import re
import statistics
import sys
from pathlib import Path

RSS_LINE = re.compile(r"^\s*((?:idle|peak)_rss_(?:glibc|musl)) = (\d+) kB\s*$")


def criterion_metrics(criterion_dir: Path) -> list[dict]:
    """One `ns` entry per benchmark, its mean point estimate, sorted by name."""
    metrics = []
    for estimates in sorted(criterion_dir.glob("*/new/estimates.json")):
        name = estimates.parent.parent.name
        mean = json.loads(estimates.read_text())["mean"]["point_estimate"]
        metrics.append({"name": name, "value": round(mean, 2), "unit": "ns"})
    return metrics


def rss_metrics(logs: list[str]) -> list[dict]:
    """The median of each RSS figure across the runs' logs, in kB."""
    readings: dict[str, list[int]] = {}
    for log in logs:
        for line in log.splitlines():
            match = RSS_LINE.match(line)
            if match:
                readings.setdefault(match.group(1), []).append(int(match.group(2)))
    order = ["idle_rss_glibc", "peak_rss_glibc", "idle_rss_musl", "peak_rss_musl"]
    return [
        {"name": name, "value": int(statistics.median(readings[name])), "unit": "kB"}
        for name in order
        if name in readings
    ]


def build(version: str, environment: str, criterion_dir: Path, logs: list[str]) -> dict:
    metrics = criterion_metrics(criterion_dir)
    if not metrics:
        raise ValueError(f"no criterion estimates under {criterion_dir}")
    rss = rss_metrics(logs)
    if len(rss) != 4:
        raise ValueError(f"expected all four RSS figures, found {[m['name'] for m in rss]}")
    return {"version": version, "environment": environment, "metrics": metrics + rss}


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--version", required=True)
    parser.add_argument("--environment", required=True)
    parser.add_argument("--criterion-dir", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("rss_logs", nargs="+", type=Path)
    args = parser.parse_args(argv)
    baseline = build(
        args.version, args.environment, args.criterion_dir,
        [log.read_text() for log in args.rss_logs],
    )
    args.out.write_text(json.dumps(baseline, indent=2) + "\n")
    print(f"wrote {args.out} with {len(baseline['metrics'])} metrics")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
