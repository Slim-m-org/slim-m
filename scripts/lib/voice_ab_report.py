# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Before/after markdown tables from two harness output trees.

usage: voice_ab_report.py <report-ab dir> quality|latency|joins|speaking|cut|desktop
The directory holds `before/` and `after/`, each written by the voice harness
(`baseline/`, `baseline2/`, `latency/`, `experience/`, `desktop/`).
"""
import json
import os
import statistics
import sys

SIDES = ("before", "after")
CLASSES = ("dropout", "click", "static", "tone", "clipping", "level_burst")


def _json(root, side, *parts):
    path = os.path.join(root, side, *parts)
    if not os.path.exists(path):
        return None
    with open(path) as fh:
        return json.load(fh)


def _md(head, rows):
    return "\n".join(["| " + " | ".join(head) + " |", "|" + "---|" * len(head)]
                     + ["| " + " | ".join(str(c) for c in r) + " |" for r in rows])


def _f(value, digits=0):
    return "n/a" if value is None else f"{value:.{digits}f}"


def _p95(values):
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(0.95 * len(ordered)))]


def _spread(values, digits=0):
    if not values:
        return "n/a"
    return (f"{statistics.median(values):.{digits}f} "
            f"(p95 {_p95(values):.{digits}f}, n {len(values)})")


def quality(root):
    rows = []
    runs = {s: [r for r in (_json(root, s, v, "results.json") for v in ("baseline", "baseline2")) if r]
            for s in SIDES}
    profiles = sorted({p for s in SIDES for r in runs[s] for p in r})
    for profile in profiles:
        row = [profile]
        for side in SIDES:
            sides = [x for r in runs[side] for x in r.get(profile, {}).values()]
            vis = [x["mos"]["visqol"] for x in sides if x.get("mos", {}).get("visqol") is not None]
            dn = [x["mos"]["ovrl"] for x in sides if x.get("mos", {}).get("ovrl") is not None]
            counts = ", ".join(f"{c} {sum(x['counts'].get(c, 0) for x in sides)}"
                               for c in CLASSES)
            row += [_spread(vis, 2), _spread(dn, 2), counts]
        rows.append(row)
    head = ["profile"]
    for side in SIDES:
        head += [f"{side} ViSQOL", f"{side} DNSMOS", f"{side} anomalies (sum over runs and both directions)"]
    return _md(head, rows)


def latency(root):
    rows = []
    data = {s: _json(root, s, "latency", "latency.json") or {} for s in SIDES}
    for profile in sorted(set(data["before"]) | set(data["after"])):
        row = [profile]
        for side in SIDES:
            r = data[side].get(profile)
            if not r:
                row += ["n/a", "n/a"]
                continue
            both = [r["vqa_to_vqb"], r["vqb_to_vqa"]]
            med = [d["mouth_to_ear_ms"] for d in both if d["mouth_to_ear_ms"].get("n")]
            jb = statistics.mean(v.get("jitterBufferDelayMs", 0) for v in r["stats"].values())
            row += [f"{statistics.mean(m['median'] for m in med):.0f} (p95 {max(m['p95'] for m in med):.0f}, "
                    f"n {sum(m['n'] for m in med)})" if med else "n/a", f"{jb:.0f}"]
        rows.append(row)
    return _md(["profile", "before mouth-to-ear ms", "before jitter buffer ms",
                "after mouth-to-ear ms", "after jitter buffer ms"], rows)


def joins(root):
    rows = []
    data = {s: (_json(root, s, "experience", "experience.json") or {}).get("joins", []) for s in SIDES}
    for key, label in (("in_call_ms", "'in call' shown"), ("first_packet_ms", "first remote packet"),
                       ("first_energy_ms", "first audible audio")):
        row = [label]
        for side in SIDES:
            warm = [j[key] for j in data[side] if not j["cold"] and j[key] is not None]
            cold = [j[key] for j in data[side] if j["cold"] and j[key] is not None]
            row += [_f(cold[0]) if cold else "n/a", _spread(warm)]
        rows.append(row)
    return _md(["click to", "before cold ms", "before warm ms", "after cold ms", "after warm ms"], rows)


def speaking(root):
    rows = []
    data = {s: (_json(root, s, "experience", "experience.json") or {}).get("speaking", {}) for s in SIDES}
    for profile in sorted(set(data["before"]) | set(data["after"])):
        row = [profile]
        for side in SIDES:
            r = data[side].get(profile)
            d = r["delay_ms"] if r else {}
            row += [f"{d['median']:.0f} (p95 {d['p95']:.0f}, n {d['n']}, missed {r['missed']})"
                    if d.get("n") else "n/a"]
        rows.append(row)
    return _md(["profile", "before ms", "after ms"], rows)


def cut(root):
    data = {s: (_json(root, s, "experience", "experience.json") or {}).get("cut") for s in SIDES}
    rows = []
    for key, label in (("time_to_packets_ms", "first packet after link back ms"),
                       ("time_to_audio_ms", "first audio after link back ms"),
                       ("audio_during_outage_s", "audio heard during outage s"),
                       ("rejoined", "full rejoin"), ("call_still_open", "call still open")):
        rows.append([label] + [("n/a" if not data[s] else str(data[s][key])) for s in SIDES])
    for key in ("ice_disconnected_ms", "ice_connected_ms"):
        rows.append([f"{key} after cut"] + [("n/a" if not data[s] else str(data[s]["transport"].get(key, "n/a")))
                                           for s in SIDES])
    return _md(["measure", "before", "after"], rows)


def desktop(root):
    data = {s: _json(root, s, "desktop", "desktop.json") or {} for s in SIDES}
    rows = []
    for arm in sorted(set(data["before"]) | set(data["after"])):
        for profile in ("clean", "loss5-jitter30", "burst"):
            row = [arm, profile]
            for side in SIDES:
                n = data[side].get(arm, {}).get(profile, {}).get("noise")
                if not n:
                    row += ["n/a"] * 4
                    continue
                row += [_f(n["hum_floor"]["change_db"], 1), _f(n["speech_level_change_db"], 1),
                        f"{n['onsets']['clipped']}/{n['onsets']['count']}",
                        _f(n["onsets"]["mean_lost_ms"])]
            rows.append(row)
    head = ["arm", "network"]
    for side in SIDES:
        head += [f"{side} hum floor dB", f"{side} speech dB", f"{side} clipped onsets", f"{side} onset lost ms"]
    return _md(head, rows)


KINDS = {"quality": quality, "latency": latency, "joins": joins, "speaking": speaking,
         "cut": cut, "desktop": desktop}

if __name__ == "__main__":
    print(KINDS[sys.argv[2]](sys.argv[1]))
