# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Markdown tables from the results.json files the voice quality scenario writes.

usage: voice_quality_table.py <variant-dir> [<variant-dir> ...]
One table per directory: a row per profile, both directions summed.
"""
import json
import os
import sys
from pathlib import Path

from work_roots import ROOTS

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
    mos = [s["mos"] for s in sides.values() if s.get("mos")]
    got = [m["ovrl"] for m in mos if m.get("ovrl") is not None]
    ref = [m["ovrl_reference"] for m in mos if m.get("ovrl_reference") is not None]
    vis = [m["visqol"] for m in mos if m.get("visqol") is not None]
    cells = [profile, f"{min(sims):.3f}",
             f"{sum(vis) / len(vis):.2f}" if vis else "-",
             f"{sum(got) / len(got):.2f}" if got else "-",
             f"{sum(ref) / len(ref):.2f}" if ref else "-"]
    cells += [str(counts[c]) for c in CLASSES]
    cells += [str(int(concealed)), str(int(events)), str(int(lost)), f"{delay:.0f}", f"{kbps:.1f}"]
    return "| " + " | ".join(cells) + " |"


def table(directory):
    directory = Path(directory).resolve()
    if not any(directory.is_relative_to(root) for root in ROOTS):
        raise SystemExit(f"{directory}: outside the work directories")
    directory = str(directory)
    with open(os.path.join(directory, "results.json")) as fh:
        results = json.load(fh)
    head = ["profile", "min similarity", "ViSQOL MOS", "DNSMOS", "DNSMOS of the sent speech", *CLASSES, "concealed samples",
            "concealment events", "packets lost", "jitter buffer ms", "kbps"]
    lines = ["| " + " | ".join(head) + " |", "|" + "---|" * len(head)]
    lines += [row(p, results[p]) for p in results]
    return "\n".join(lines)


if __name__ == "__main__":
    for path in sys.argv[1:]:
        print(f"### {os.path.basename(path.rstrip('/'))}\n")
        print(table(path), "\n")
