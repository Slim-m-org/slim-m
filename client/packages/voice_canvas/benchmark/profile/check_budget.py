#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Fails when a profile-window row's raster time is past the budget.

The budget is milliseconds of GPU-thread time per frame: the median must stay
under PROFILE_RASTER_MEDIAN_MS (default 8) and the p99 under
PROFILE_RASTER_P99_MS (default 16.7, one 60 Hz frame). Rows are the scripted
sessions run.sh records, so a regression that makes busy boards miss frames
under Impeller fails here even though no unit test can rasterise.
"""
import json
import os
import sys
import tempfile
from pathlib import Path

MEDIAN_MS = float(os.environ.get("PROFILE_RASTER_MEDIAN_MS", "8"))
P99_MS = float(os.environ.get("PROFILE_RASTER_P99_MS", "16.7"))
ROOTS = tuple(
    Path(root).resolve()
    for root in (os.environ.get("CANVAS_PERF_OUT"), os.environ.get("TMPDIR"),
                 tempfile.gettempdir(), Path.home(), Path.cwd())
    if root
)


def main(paths):
    failures = []
    for arg in paths:
        path = Path(arg).resolve()
        if path.suffix != ".json" or not any(path.is_relative_to(root) for root in ROOTS):
            print(f"{arg}: not a results file under the work directories")
            return 2
        with open(path, encoding="utf-8") as handle:
            rows = json.load(handle)["rows"]
        for row in rows:
            raster = row["raster"]
            median = raster["median_us"] / 1000
            p99 = raster["p99_us"] / 1000
            if median > MEDIAN_MS or p99 > P99_MS:
                failures.append(
                    f"{row['name']}: raster median {median:.2f} ms, p99 {p99:.2f} ms"
                )
    if failures:
        print(f"raster budget ({MEDIAN_MS} ms median, {P99_MS} ms p99) exceeded:")
        print("\n".join(failures))
        return 1
    print(f"raster budget held: {MEDIAN_MS} ms median, {P99_MS} ms p99")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
