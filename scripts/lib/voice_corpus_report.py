# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Per-category tables from corpus.json files written by voice_corpus_score.py.

usage: voice_corpus_report.py <label>=<corpus.json> [<label>=<corpus.json> ...]
Each cell is bursts / loud windows / dropouts / ViSQOL / worst peak over the reference (dB),
each clip is played in one direction.
"""
import json
import sys

import voice_corpus as corpus

HEAD = "bursts / loud / dropouts / ViSQOL / peak dB"


def rollup(results, categories):
    """`{profile: {category: stats}}` over every clip of both directions."""
    out = {}
    for profile, sides in results.items():
        cells = {}
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
        out[profile] = cells
    return out


def cell_text(cell):
    if cell is None:
        return "-"
    vis = f"{sum(cell['visqol']) / len(cell['visqol']):.2f}" if cell["visqol"] else "-"
    return f"{cell['bursts']} / {cell['loud']} / {cell['dropouts']} / {vis} / {cell['peak']:+.1f}"


def table(profile, rolled, order=corpus.CATEGORIES):
    """Markdown rows for one profile: a column per label in `rolled` = `{label: rollup}`."""
    labels = list(rolled)
    lines = [f"| category ({HEAD}) | " + " | ".join(labels) + " |",
             "|---|" + "---|" * len(labels)]
    for category in order:
        cells = [rolled[label].get(profile, {}).get(category) for label in labels]
        if any(cells):
            count = next(c["clips"] for c in cells if c)
            lines.append(f"| {category} ({count} clips) | "
                         + " | ".join(cell_text(c) for c in cells) + " |")
    return "\n".join(lines)


def main(argv):
    categories = {c["id"]: c["category"] for c in corpus.load_manifest()["clips"]}
    rolled = {}
    for arg in argv[1:]:
        label, path = arg.split("=", 1)
        with open(path, encoding="utf-8") as fh:
            rolled[label] = rollup(json.load(fh), categories)
    profiles = sorted({p for r in rolled.values() for p in r})
    for profile in profiles:
        print(f"\n### {profile}\n")
        print(table(profile, rolled))


if __name__ == "__main__":
    main(sys.argv)
