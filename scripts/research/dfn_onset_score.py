# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Scores a Strongest variant on the dfn evaluation material (onsets, gap attenuation, speech level).
usage: dfn_onset_score.py TOOL MODE LABEL OUT_DIR
TOOL is the fork's test/native strongest_tool, MODE is strong or strongest and its
COVER_* and DFN_* environment knobs pass through; the material is the one
dfn_material.py wrote (see deepfilternet-evaluation.md). Needs numpy and scipy.
"""
import glob, json, os, subprocess, sys, re
import numpy as np
from scipy.signal import correlate

MATERIAL = os.environ.get("DFN_MATERIAL", os.path.expanduser("~/.slimm-scratch/tmp/report-ab/dfn/raw/material"))
RATE, HOP, SPEECH_DB, MARGIN_S = 48000, 480, -45.0, 0.3

def frames_db(x):
    f = x[: len(x) // HOP * HOP].reshape(-1, HOP)
    return 10 * np.log10((f ** 2).mean(axis=1) + 1e-12)

def power_mean(l): return 10 * np.log10(np.mean(10 ** (l / 10)) + 1e-12)

def lag_of(ref, out):
    n = min(len(ref), len(out))
    c = correlate(out[:n], ref[:n], mode="full", method="fft")
    return int(np.argmax(c)) - (n - 1)

def shift(out, lag, size):
    out = np.concatenate([out[lag:], np.zeros(max(lag, 0))]) if lag > 0 else out
    return np.concatenate([out, np.zeros(size)])[:size]

def mask_frames(spans, count, margin=0.0):
    keep = np.zeros(count, dtype=bool)
    for a, b in spans:
        keep[int(max(0, a - margin) * 100): int((b + margin) * 100)] = True
    return keep

def onsets(cdb):
    q = 50
    return [i for i in range(q, len(cdb)) if cdb[i] > SPEECH_DB and (cdb[max(0, i - q):i] <= SPEECH_DB).all()]

def metrics(meta, clean, noisy, out):
    cdb, ndb, odb = frames_db(clean), frames_db(noisy), frames_db(out)
    n = min(len(cdb), len(ndb), len(odb)); cdb, ndb, odb = cdb[:n], ndb[:n], odb[:n]
    talk = mask_frames(meta["spans"], n); live = talk & (cdb > SPEECH_DB)
    gain = float(np.median(odb[live] - cdb[live])) if live.any() else 0.0
    r = {"speech_change_db": gain}
    if meta["events"]:
        gap = mask_frames([(e["start"], e["end"]) for e in meta["events"] if e["kind"].endswith("_gap")], n)
    else:
        gap = ~mask_frames(meta["spans"], n, MARGIN_S)
    if gap.any() and meta["noise"] != "none":
        r["gap_atten_db"] = power_mean(ndb[gap]) - power_mean(odb[gap])
    lost = []
    for i in onsets(cdb):
        w = range(i, min(n, i + 20))
        lost.append(10 * sum(1 for j in w if cdb[j] > SPEECH_DB and odb[j] < cdb[j] + gain - 10.0))
    r["onsets"], r["clipped"] = len(lost), sum(1 for v in lost if v >= 30)
    r["lost_ms"] = float(np.mean(lost)) if lost else 0.0
    return r

def run(tool, mode, src, dst):
    res = subprocess.run([tool, src, dst, mode], capture_output=True, text=True, check=True)
    m = re.search(r"rtf ([0-9.]+)", res.stderr)
    return float(m.group(1)) if m else None

def main(tool, mode, label, outdir):
    os.makedirs(outdir, exist_ok=True)
    clean_a = os.path.join(MATERIAL, "clean_A", "clean.f32")
    d = os.path.join(outdir, "delay.f32"); run(tool, mode, clean_a, d)
    ref = np.fromfile(clean_a, dtype="<f4").astype(np.float64)
    lag = lag_of(ref, np.fromfile(d, dtype="<f4").astype(np.float64))
    rows, rtfs = {}, []
    for folder in sorted(glob.glob(os.path.join(MATERIAL, "*"))):
        case = os.path.basename(folder)
        if case.startswith("clean_"): continue
        clean = np.fromfile(os.path.join(folder, "clean.f32"), dtype="<f4").astype(np.float64)
        noisy = np.fromfile(os.path.join(folder, "noisy.f32"), dtype="<f4").astype(np.float64)
        meta = json.load(open(os.path.join(folder, "meta.json")))
        dst = os.path.join(outdir, f"{case}.f32")
        rtfs.append(run(tool, mode, os.path.join(folder, "noisy.f32"), dst))
        out = shift(np.fromfile(dst, dtype="<f4").astype(np.float64), lag, len(clean))
        rows[case] = metrics(meta, clean, noisy, out)
    a = {k: v for k, v in rows.items() if not k.endswith("_B")}
    allc = rows
    ons = sum(v["onsets"] for v in allc.values()); clip = sum(v["clipped"] for v in allc.values())
    lost = np.mean([v["lost_ms"] for v in a.values()])
    noise = {}
    for k, v in a.items():
        if "gap_atten_db" in v: noise.setdefault(k.split("_")[0], []).append(v["gap_atten_db"])
    gap = {k: round(float(np.mean(v)), 1) for k, v in noise.items()}
    sp = {k: round(float(np.mean([a[c]["speech_change_db"] for c in a if c.startswith(k)])), 1) for k in ("fan", "babble")}
    print(f"{label:28s} lag {lag/48:5.1f}ms clipped {clip:3d}/{ons} lost {lost:5.1f}ms rtf {np.mean(rtfs):.4f} speech {sp} gap {gap}")
    json.dump(rows, open(os.path.join(outdir, "rows.json"), "w"))

if __name__ == "__main__":
    main(*sys.argv[1:5])
