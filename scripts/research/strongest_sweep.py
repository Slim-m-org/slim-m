#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Scores Strongest tunings on the material the `voice transients` scenario plays: speech level, word starts and smack suppression.

usage: strongest_sweep.py TOOL [--sets "label:ENV=V,ENV=V;label2:..."] [--voices A,B] [--out DIR]
TOOL is the fork's test/native strongest_tool; a set's variables are its COVER_* and DFN_* knobs, and the label `strong` runs
the Strong mode instead. The material is each piper voice's gapped sentences with the fan and the recorded mouth clips
laid in the gaps, as the scenario mixes them. Speech is the median change over frames where the clean voice is above
-45 dBFS, a clipped word start is one that loses 30 ms or more of its first 200 ms (a frame counts when it is more than
10 dB under the clean voice), and smack is the energy change of the recorded smack clip.
"""
import argparse
import os
import subprocess
import sys

import numpy as np
from scipy.signal import correlate

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import e2e_voice_transients as scenario  # noqa: E402
import fetch_mouth_noise  # noqa: E402
import make_noise_bed as bed  # noqa: E402
import make_speech_clip as speech  # noqa: E402
import mouth_transients_offline as offline  # noqa: E402

SPEECH_DB, WORD_FRAMES = -45.0, 20
CHAIN = os.environ.get('CHAIN') == '1'


def material(voice, clips):
    """`(clean, noisy, spans, events)` for one voice, the scenario's mix."""
    clean, spans = speech.build_gapped(voice)
    noisy, events = bed.mix(clean, spans, transients=clips)
    return clean, noisy, spans, [(e["kind"], e["start"], e["end"]) for e in events]


def run(tool, samples, mode, env, out_dir):
    np.asarray(samples, dtype="<f4").tofile(f"{out_dir}/in.f32")
    full = dict(os.environ, **env)
    subprocess.run([tool, f"{out_dir}/in.f32", f"{out_dir}/out.f32", mode], capture_output=True, text=True, check=True, env=full)
    return np.fromfile(f"{out_dir}/out.f32", dtype="<f4").astype(np.float64), np.fromfile(f"{out_dir}/out.f32.prob", dtype="<f4")


def onset_frames(clean_db):
    quiet = 50
    return [i for i in range(quiet, len(clean_db)) if clean_db[i] > SPEECH_DB and (clean_db[i - quiet:i] <= SPEECH_DB).all()]


def sample_lag(reference, out):
    """Samples `out` lags `reference` by, from their cross-correlation over the first 20 s."""
    n = min(len(reference), len(out), 20 * offline.RATE)
    ref = np.asarray(reference[:n], dtype=np.float64)
    c = correlate(out[:n], ref, mode="full", method="fft")
    return max(0, int(np.argmax(c)) - (n - 1))


def gated(out, prob):
    """`out` after the input gate: open where a decision from this frame to two frames later says voice (its lookahead)."""
    raw = offline.frame_db(out)
    n = min(len(raw), len(prob))
    voice = offline.gate_opens(raw[:n], prob[:n])
    open_ = np.array([voice[i:i + 3].any() for i in range(n)])
    mask = np.repeat(open_, offline.HOP)
    return out[: n * offline.HOP] * mask


def score_one(clean, noisy, out, prob, events):
    """Speech change, clipped and total word starts, and the energy change per event kind, after the gate."""
    out = out if CHAIN else gated(out, prob)
    out = out[sample_lag(clean, out):]
    cdb, ndb = offline.frame_db(clean), offline.frame_db(noisy)
    m = min(len(cdb), len(ndb), len(out) // offline.HOP, len(prob))
    odb = offline.frame_db(out)[:m]
    cdb, ndb = cdb[:m], ndb[:m]
    live = cdb > SPEECH_DB
    speech_change = float(np.median(odb[live] - cdb[live]))
    clipped = 0
    starts = onset_frames(cdb)
    for i in starts:
        lost = sum(1 for j in range(i, min(m, i + WORD_FRAMES)) if cdb[j] > SPEECH_DB and odb[j] < cdb[j] + speech_change - 10.0)
        clipped += lost >= 3
    kinds = {}
    for name, start, end in events:
        sel = np.arange(int(start * 100), min(m, int(end * 100)))
        sel = sel[ndb[sel] > -55]
        if len(sel):
            kinds.setdefault(name.rsplit("_", 1)[0], []).append(offline.power_mean(odb[sel]) - offline.power_mean(ndb[sel]))
    return speech_change, clipped, len(starts), {k: float(np.mean(v)) for k, v in kinds.items()}


def parse_sets(text):
    sets = []
    for item in text.split(";"):
        label, _, pairs = item.partition(":")
        env = dict(p.split("=") for p in pairs.split(",") if p)
        sets.append((label.strip(), env))
    return sets


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("tool")
    parser.add_argument("--sets", default="strong:;strongest:")
    parser.add_argument("--voices", default="A,B")
    parser.add_argument("--out", default=os.path.expanduser("~/.slimm-scratch/tmp/strongest-sweep"))
    args = parser.parse_args(argv)
    os.makedirs(args.out, exist_ok=True)
    clips = scenario.recorded_clips(fetch_mouth_noise.DEFAULT_OUT) or True
    scenes = [material(v, clips) for v in args.voices.split(",")]
    print(f"{'set':34} {'speech':>7} {'clipped':>8} {'smack':>7} {'chew':>7} {'swallow':>8} {'breath':>7}")
    for label, env in parse_sets(args.sets):
        mode = "strong" if label == "strong" else "strongest"
        speeches, clipped, total, kinds = [], 0, 0, {}
        for clean, noisy, _, events in scenes:
            out, prob = run(args.tool, noisy, mode, env, args.out)
            s, c, n, k = score_one(clean, noisy, out, prob, events)
            speeches.append(s)
            clipped, total = clipped + c, total + n
            for name, v in k.items():
                kinds.setdefault(name, []).append(v)
        mean = {k: float(np.mean(v)) for k, v in kinds.items()}
        print(f"{label[:34]:34} {np.mean(speeches):+7.1f} {clipped:4d}/{total:<3d} {mean.get('smack', 0):+7.1f} {mean.get('chew', 0):+7.1f} "
              f"{mean.get('swallow', 0):+8.1f} {mean.get('breath', 0):+7.1f}", flush=True)


if __name__ == "__main__":
    main(sys.argv[1:])
