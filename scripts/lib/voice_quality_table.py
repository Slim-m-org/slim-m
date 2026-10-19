# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Markdown tables from the results.json files the voice quality scenario writes.

usage: voice_quality_table.py <variant-dir> [<variant-dir> ...]
One table per directory: a row per profile, both directions summed.
"""
import json
import os
import sys

CLASSES = ("dropout", "click", "static", "tone", "clipping", "level_burst")


def row(profile, sides):
    counts = {c: sum(s["counts"].get(c, 0) for s in sides.values()) for c in CLASSES}
    sims = [s["similarity"] for s in sides.values()]
    stats = [s["stats"] for s in sides.values()]
    concealed = sum(t.get("concealedSamples", 0) for t in stats)
    events = sum(t.get("concealmentEvents", 0) for t in stats)
    lost = sum(t.get("packetsLost", 0) for t in stats)
    delay = max(t.get("jitterBufferDelayMs", 0) for t in stats)
    kbps = sum(t.get("bitrateKbps", 0) for t in stats) / len(stats)
    cells = [profile, f"{min(sims):.3f}"] + [str(counts[c]) for c in CLASSES]
    cells += [str(int(concealed)), str(int(events)), str(int(lost)), f"{delay:.0f}", f"{kbps:.1f}"]
    return "| " + " | ".join(cells) + " |"


def table(directory):
    with open(os.path.join(directory, "results.json")) as fh:
        results = json.load(fh)
    head = ["profile", "min similarity", *CLASSES, "concealed samples",
            "concealment events", "packets lost", "jitter buffer ms", "kbps"]
    lines = ["| " + " | ".join(head) + " |", "|" + "---|" * len(head)]
    lines += [row(p, results[p]) for p in results]
    return "\n".join(lines)


if __name__ == "__main__":
    for path in sys.argv[1:]:
        print(f"### {os.path.basename(path.rstrip('/'))}\n")
        print(table(path), "\n")
