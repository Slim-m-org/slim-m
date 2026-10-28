# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Per-category tables from corpus.json files written by voice_corpus_score.py.

usage: voice_corpus_report.py <label>=<corpus.json> [<label>=<corpus.json> ...]
A repeated label pools its files into one column.
Each cell is bursts / loud windows / dropouts / ViSQOL / worst peak over the reference (dB),
each clip is played in one direction.
The last row is the seconds the alignment lost and the largest step in delay (ms), summed and maxed over both directions.
"""
import json
import sys

import voice_corpus as corpus

HEAD = "bursts / loud / dropouts / ViSQOL / peak dB"


def rollup(results, categories, into=None):
    """`{profile: {category: stats}}` over every clip of both directions; `into` pools more runs."""
    out = into if into is not None else {}
    for profile, sides in results.items():
        cells = out.setdefault(profile, {})
        for side in sides.values():
            for name, row in side["clips"].items():
                cell = cells.setdefault(categories[name], {
                    "clips": 0, "bursts": 0, "loud": 0, "dropouts": 0, "visqol": [], "peak": -99.0})
                cell["clips"] += 1
                cell["bursts"] += row["counts"]["level_burst"]
                cell["loud"] += row["loud_windows"]
                cell["dropouts"] += row["counts"]["dropout"]
                cell["peak"] = max(cell["peak"], row["peak_over_ref_db"])
                if row["visqol"] is not None:
                    cell["visqol"].append(row["visqol"])
    return out


def timing_rollup(results, into=None):
    """`{profile: {lost_s, max_step_ms}}`: audio the alignment could not follow, and the worst jump in delay."""
    out = into if into is not None else {}
    for profile, sides in results.items():
        cell = out.setdefault(profile, {"lost_s": 0.0, "max_step_ms": 0.0})
        for side in sides.values():
            timing = side.get("timing", {})
            cell["lost_s"] = round(cell["lost_s"] + timing.get("lost_s", 0.0), 2)
            cell["max_step_ms"] = max(cell["max_step_ms"], timing.get("max_step_ms", 0.0))
    return out


def timing_text(cell):
    return "-" if cell is None else f"{cell['lost_s']:.2f} / {cell['max_step_ms']:.1f}"


def cell_text(cell, expected=None):
    """One cell; a clip count that differs from the row's is shown, because the sums are then not comparable."""
    if cell is None:
        return "-"
    vis = f"{sum(cell['visqol']) / len(cell['visqol']):.2f}" if cell["visqol"] else "-"
    text = f"{cell['bursts']} / {cell['loud']} / {cell['dropouts']} / {vis} / {cell['peak']:+.1f}"
    if expected is not None and cell["clips"] != expected:
        text += f" [{cell['clips']} of {expected} clips]"
    return text


def _total(cells):
    done = [c for c in cells if c]
    return None if not done else {
        "clips": sum(c["clips"] for c in done), "bursts": sum(c["bursts"] for c in done),
        "loud": sum(c["loud"] for c in done), "dropouts": sum(c["dropouts"] for c in done),
        "visqol": [v for c in done for v in c["visqol"]],
        "peak": max(c["peak"] for c in done)}


def table(profile, rolled, order=corpus.CATEGORIES, timings=None):
    """Markdown rows for one profile: a column per label in `rolled` = `{label: rollup}`; `timings` adds a lost-audio row."""
    labels = list(rolled)
    lines = [f"| category ({HEAD}) | " + " | ".join(labels) + " |",
             "|---|" + "---|" * len(labels)]
    for category in order:
        cells = [rolled[label].get(profile, {}).get(category) for label in labels]
        if any(cells):
            count = max(c["clips"] for c in cells if c)
            lines.append(f"| {category} ({count} clips) | "
                         + " | ".join(cell_text(c, count) for c in cells) + " |")
    totals = [_total([rolled[label].get(profile, {}).get(cat) for cat in order])
              for label in labels]
    lines.append("| all clips | " + " | ".join(cell_text(t) for t in totals) + " |")
    if timings:
        lines.append("| lost s / max delay step ms | "
                     + " | ".join(timing_text(timings.get(label, {}).get(profile)) for label in labels) + " |")
    return "\n".join(lines)


def main(argv):
    categories = {c["id"]: c["category"] for c in corpus.load_manifest()["clips"]}
    rolled, timings = {}, {}
    for arg in argv[1:]:
        label, path = arg.split("=", 1)
        with open(path, encoding="utf-8") as fh:
            results = json.load(fh)
        rolled[label] = rollup(results, categories, rolled.get(label))
        timings[label] = timing_rollup(results, timings.get(label))
    profiles = sorted({p for r in rolled.values() for p in r})
    for profile in profiles:
        print(f"\n### {profile}\n")
        print(table(profile, rolled, timings=timings))


if __name__ == "__main__":
    main(sys.argv)
