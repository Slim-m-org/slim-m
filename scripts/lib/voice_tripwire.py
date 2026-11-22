# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The nightly voice quality tripwire: median-aggregates repeated harness runs and checks them against checked-in bands.

usage: voice_tripwire.py check <run-dir>... [--chrome TEXT] [--livekit TEXT] [--summary FILE]

Each run dir holds the results.json that e2e_voice_quality.py wrote; the bands live in voice_tripwire_bands.json.
Bands are provisional until they hold values measured on the GitHub runner; a provisional run reports but never fails.
"""
import argparse
import json
import os
import re
import statistics
import sys

BANDS_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "voice_tripwire_bands.json")
METRICS = ("visqol", "jitter_buffer_delay_ms")


def median(values):
    return round(statistics.median(values), 3) if values else None


def _side_metrics(report):
    mos = report.get("mos") or {}
    stats = report.get("stats") or {}
    return {"visqol": mos.get("visqol"), "jitter_buffer_delay_ms": stats.get("jitterBufferDelayMs")}


def aggregate(runs):
    """Median per profile and metric over every side of every run; None where nothing was scored."""
    pooled = {}
    for results in runs:
        for profile, sides in results.items():
            for report in sides.values():
                for metric, value in _side_metrics(report).items():
                    pooled.setdefault(profile, {m: [] for m in METRICS})[metric].append(value)
    return {profile: {m: median([v for v in values[m] if v is not None]) for m in METRICS}
            for profile, values in pooled.items()}


def check(measured, bands):
    """Human-readable violations: a profile or metric that is missing, a MOS too low, a delay too high."""
    problems = []
    for profile, want in bands["profiles"].items():
        got = measured.get(profile)
        if got is None:
            problems.append(f"{profile}: no recording was scored")
            continue
        if got["visqol"] is None:
            problems.append(f"{profile}: no ViSQOL score")
        elif got["visqol"] < round(want["visqol"] - bands["mos_band"], 3):
            problems.append(f"{profile}: ViSQOL {got['visqol']} is more than {bands['mos_band']} below {want['visqol']}")
        if got["jitter_buffer_delay_ms"] is None:
            problems.append(f"{profile}: no jitter buffer delay")
        elif got["jitter_buffer_delay_ms"] > want["jitter_buffer_delay_ms"] + bands["delay_band_ms"]:
            problems.append(f"{profile}: jitter buffer delay {got['jitter_buffer_delay_ms']} ms is more than "
                            f"{bands['delay_band_ms']} ms above {want['jitter_buffer_delay_ms']}")
    return problems


def parse_chrome_version(text):
    found = re.search(r"Chrome\s+(\d+(?:\.\d+)+)", text or "")
    return found.group(1) if found else None


def parse_livekit_version(text):
    found = re.search(r"livekit-server version\s+(\d+(?:\.\d+)+)", text or "")
    return found.group(1) if found else None


def summary(measured, bands, problems, versions, run_count):
    """Markdown for the job summary, ending in the measured values in the bands file's own shape."""
    lines = ["## Voice quality tripwire", "",
             f"Chrome {versions['chrome'] or 'unknown'}, livekit-server {versions['livekit'] or 'unknown'}, "
             f"median of {run_count} runs.", ""]
    if bands.get("provisional"):
        lines += ["Bands are provisional (not measured on this runner), so this run cannot fail.", ""]
    lines += ["| profile | ViSQOL | band | jitter buffer ms | band |", "| --- | --- | --- | --- | --- |"]
    for profile, want in bands["profiles"].items():
        got = measured.get(profile) or {m: None for m in METRICS}
        lines.append(f"| {profile} | {got['visqol']} | >= {round(want['visqol'] - bands['mos_band'], 3)} "
                     f"| {got['jitter_buffer_delay_ms']} | <= {want['jitter_buffer_delay_ms'] + bands['delay_band_ms']} |")
    lines += [""] + [f"- {p}" for p in problems] + ["", "Measured, in the bands file's shape:", "", "```json",
                                                       json.dumps({p: measured[p] for p in bands["profiles"] if p in measured},
                                                                  indent=2), "```"]
    return "\n".join(lines) + "\n"


def _load_runs(dirs):
    runs = []
    for directory in dirs:
        with open(os.path.join(directory, "results.json"), encoding="utf-8") as fh:
            runs.append(json.load(fh))
    return runs


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["check"])
    parser.add_argument("runs", nargs="+")
    parser.add_argument("--bands", default=BANDS_FILE)
    parser.add_argument("--chrome")
    parser.add_argument("--livekit")
    parser.add_argument("--summary")
    args = parser.parse_args(argv)
    with open(args.bands, encoding="utf-8") as fh:
        bands = json.load(fh)
    measured = aggregate(_load_runs(args.runs))
    problems = check(measured, bands)
    versions = {"chrome": parse_chrome_version(args.chrome), "livekit": parse_livekit_version(args.livekit)}
    text = summary(measured, bands, problems, versions, len(args.runs))
    print(text)
    if args.summary:
        with open(args.summary, "a", encoding="utf-8") as fh:
            fh.write(text)
    return 1 if problems and not bands.get("provisional") else 0


if __name__ == "__main__":
    sys.exit(main())
