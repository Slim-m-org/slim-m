# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Markdown tables from the latency, experience and desktop result files.

usage: voice_harness_tables.py latency|experience|desktop <voice-quality dir>
Reads `<dir>/latency/latency.json`, `<dir>/experience/experience.json` or
`<dir>/desktop/desktop.json`.
"""
import json
import os
import statistics
import sys


def _load(root, kind):
    with open(os.path.join(root, kind, f"{kind}.json")) as fh:
        return json.load(fh)


def _md(head, rows):
    return "\n".join(["| " + " | ".join(head) + " |", "|" + "---|" * len(head)]
                     + ["| " + " | ".join(str(c) for c in r) + " |" for r in rows])


def _num(value, digits=0):
    return "-" if value is None else f"{value:.{digits}f}"


def latency(root):
    rows = []
    for profile, row in _load(root, "latency").items():
        both = [row["vqa_to_vqb"], row["vqb_to_vqa"]]
        m2e = [d["mouth_to_ear_ms"] for d in both if d["mouth_to_ear_ms"].get("n")]
        jitter = [row["stats"][n].get("jitterBufferDelayMs", 0) for n in row["stats"]]
        median = statistics.mean(m["median"] for m in m2e) if m2e else None
        rows.append([profile, _num(median), _num(max((m["p95"] for m in m2e), default=None)),
                     _num(max((m["max"] for m in m2e), default=None)),
                     _num(statistics.mean(jitter)) if jitter else "-",
                     _num(median - statistics.mean(jitter)) if m2e and jitter else "-",
                     f"{statistics.mean(d['answered'] for d in both):.0%}"])
    return _md(["profile", "mouth-to-ear median ms", "p95 ms", "max ms",
                "jitter buffer ms", "median minus jitter buffer ms", "chirps heard"], rows)


def joins(root):
    rows = []
    for i, row in enumerate(_load(root, "experience")["joins"], 1):
        rows.append([i, "cold" if row["cold"] else "warm", _num(row["in_call_ms"]),
                     _num(row["first_packet_ms"]), _num(row["first_energy_ms"])])
    return _md(["join", "kind", "'in call' ms", "first remote packet ms",
                "first audible ms"], rows)


def speaking(root):
    rows = []
    for profile, row in _load(root, "experience")["speaking"].items():
        d = row["delay_ms"]
        rows.append([profile, row["onsets"], row["lit"], row["missed"],
                     _num(d.get("median")), _num(d.get("p95")), _num(d.get("max"))])
    return _md(["profile", "onsets", "ring lit", "missed", "median ms", "p95 ms", "max ms"], rows)


def cut(root):
    c = _load(root, "experience")["cut"]
    t = c["transport"]
    rows = [["outage ms", c["outage_ms"]], ["audio heard during outage s", c["audio_during_outage_s"]],
            ["first packet after link back ms", _num(c["time_to_packets_ms"])],
            ["first audio after link back ms", _num(c["time_to_audio_ms"])],
            ["full rejoin", "yes" if c["rejoined"] else "no"],
            ["call still open", "yes" if c["call_still_open"] else "no"],
            ["peer connections at end", c["peer_connections"]]]
    rows += [[k, v] for k, v in sorted(t.items())]
    return _md(["measure", "value"], rows)


def desktop(root):
    rows = []
    for arm, profiles in _load(root, "desktop").items():
        for profile, row in profiles.items():
            if profile == "gate_log":
                continue
            n = row["noise"]
            rows.append([arm, profile, _num(n["hum_floor"]["change_db"], 1),
                         _num(n["typing_gap"]["change_db"], 1), _num(n["bark_gap"]["change_db"], 1),
                         _num(n["typing_speech"].get("excess_over_speech_db"), 1),
                         _num(n["bark_speech"].get("excess_over_speech_db"), 1),
                         _num(n["speech_level_change_db"], 1),
                         n["onsets"]["clipped"], _num(n["onsets"]["mean_lost_ms"])])
    return _md(["arm", "network", "hum floor dB", "typing in gap dB", "bark in gap dB",
                "typing over speech: excess dB", "bark over speech: excess dB",
                "speech level dB", "clipped onsets", "mean onset lost ms"], rows)


KINDS = {"latency": latency, "joins": joins, "speaking": speaking, "cut": cut, "desktop": desktop}

if __name__ == "__main__":
    print(KINDS[sys.argv[1]](sys.argv[2]))
