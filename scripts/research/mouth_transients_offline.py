#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Mouth and desk sounds through the fork's offline suppressor, without libwebrtc's own processing around it.

usage: mouth_transients_offline.py TOOL [--clips DIR] [--gains -18,-6,0] [--modes strong,strongest] [--out DIR]
TOOL is the fork's test/native strongest_tool (see test/native/README.md there). Each recorded clip from DIR
(default: the folder fetch_mouth_noise.py builds) is laid in a silent tail after piper speech, so rnnoise has
adapted to a voice, and run through each mode at each gain; without recorded clips the synthetic set from
make_noise_bed is laid in the sentence gaps instead. Per event it prints the energy change, the loudest aligned
10 ms frame, rnnoise's speech probability, and the share of frames the input gate (modelled from
flutter_input_gate.cc) would open. Research only: docs/research/voice-transients-2026-11-02.md has the numbers.
"""
import argparse
import glob
import json
import os
import subprocess
import sys

import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))
import fetch_mouth_noise  # noqa: E402
import make_noise_bed as bed  # noqa: E402
import make_speech_clip as speech  # noqa: E402
import voice_quality_dsp as dsp  # noqa: E402

RATE, HOP, FLOOR_DB = 48000, 480, -90.0
# The gate's constants, from flutter_input_gate.cc.
SPEECH_OPEN, SPEECH_LOW, THRESHOLD_DB, LOUD_MARGIN_DB, HOLD, LOW_HOLD = 0.6, 0.3, -50.0, 15.0, 30, 10


def frame_db(x):
    n = len(x) // HOP
    frames = np.asarray(x[: n * HOP], dtype=np.float64).reshape(n, HOP)
    return np.maximum(FLOOR_DB, 20 * np.log10(np.sqrt((frames ** 2).mean(axis=1)) + 1e-9))


def power_mean(db):
    return float(10 * np.log10(np.mean(10 ** (np.asarray(db) / 10)) + 1e-12))


def lag_frames(a, b):
    """Whole frames `b` lags `a` by, from the correlation of their frame levels (DeepFilterNet adds one)."""
    best, best_lag = -1e9, 0
    for lag in range(0, 4):
        c = np.corrcoef(a[: len(a) - lag], b[lag:])[0, 1]
        if c > best:
            best, best_lag = c, lag
    return best_lag


def gate_opens(level_db, prob):
    """The gate's decision per frame: InputGate::ProcessWithSpeech with its hold and hysteresis."""
    hold, loud_run, out = 0, 0, []
    for db, p in zip(level_db, prob):
        was_open = hold > 0
        over_open = db >= THRESHOLD_DB
        over = db >= THRESHOLD_DB - 5.0 if was_open else over_open
        is_speech = over and p > SPEECH_OPEN
        loud = over_open and db >= THRESHOLD_DB + LOUD_MARGIN_DB
        loud_run = loud_run + 1 if (loud and not is_speech) else 0
        if is_speech or loud_run >= 2:
            hold = HOLD
        elif hold > 0:
            if over:
                hold = max(hold, LOW_HOLD)
            if p < SPEECH_LOW:
                hold = min(hold, LOW_HOLD)
            hold -= 1
        out.append(hold > 0)
    return np.array(out)


def run_tool(tool, samples, mode, out_dir):
    np.asarray(samples, dtype="<f4").tofile(f"{out_dir}/in.f32")
    subprocess.run([tool, f"{out_dir}/in.f32", f"{out_dir}/out.f32", mode], capture_output=True, text=True, check=True)
    y = np.fromfile(f"{out_dir}/out.f32", dtype="<f4").astype(np.float64)
    prob = np.fromfile(f"{out_dir}/out.f32.prob", dtype="<f4")
    return y, prob


def score(xin, yout, prob, talk, events):
    """Rows per event after aligning the output to the input."""
    m = min(len(xin), len(yout), len(prob))
    lag = lag_frames(xin[:m][talk[:m]], yout[:m][talk[:m]]) if talk[:m].sum() > 100 else 0
    yout, prob, m = yout[lag:m], prob[lag:m], m - lag
    xi = xin[:m]
    gate = gate_opens(yout, prob)
    rows = []
    for name, start, end in events:
        sel = np.arange(int(start * 100), min(m, int(end * 100)))
        sel = sel[xi[sel] > -55]
        if not len(sel):
            continue
        pin, pout = power_mean(xi[sel]), power_mean(yout[sel])
        rows.append({"event": name, "in_db": round(pin, 1), "out_db": round(pout, 1), "change_db": round(pout - pin, 1),
                     "worst_frame_change_db": round(float((yout[sel] - xi[sel]).max()), 1),
                     "prob_max": round(float(prob[sel].max()), 2), "prob_mean": round(float(prob[sel].mean()), 2),
                     "gate_open": round(float(gate[sel].mean()), 2)})
    return rows


def recorded(folder, gains):
    """`(label, samples, events)` per clip and gain: the clip in a silent tail after the speech."""
    spoken, spans = speech.build_gapped("A")
    tail_at = len(spoken) / RATE + 1.0
    base = spoken + [0.0] * (12 * RATE)
    for path in sorted(glob.glob(os.path.join(folder, "*.wav"))):
        clip, rate = dsp.read_wav(path)
        assert rate == RATE, f"{path} is {rate} Hz"
        clip = clip[: 8 * RATE]
        for gain_db in gains:
            gain = 10 ** (gain_db / 20)
            noisy, _ = bed.mix(base, spans)
            laid, _ = bed._lay([v * gain for v in clip], tail_at, len(noisy))
            samples = [max(-1.0, min(1.0, a + b)) for a, b in zip(noisy, laid)]
            name = f"{os.path.basename(path)[:-4]}@{gain_db:+.0f}dB"
            yield name, base, spans, samples, [(name, tail_at, tail_at + len(clip) / RATE)]


def synthetic():
    spoken, spans = speech.build_gapped("A")
    noisy, events = bed.mix(spoken, spans, transients=True)
    yield "synthetic", spoken, spans, noisy, [(e["kind"], e["start"], e["end"]) for e in events]


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("tool")
    parser.add_argument("--clips", default=fetch_mouth_noise.DEFAULT_OUT)
    parser.add_argument("--gains", default="-18,-6,0")
    parser.add_argument("--modes", default="strong,strongest")
    parser.add_argument("--out", default=os.path.expanduser("~/.slimm-scratch/tmp/mouth-transients-offline"))
    args = parser.parse_args(argv)
    os.makedirs(args.out, exist_ok=True)
    gains = [float(g) for g in args.gains.split(",")]
    cases = recorded(args.clips, gains) if glob.glob(os.path.join(args.clips, "*.wav")) else synthetic()
    print(f"{'mode':9} {'event':28} {'in dB':>7} {'out dB':>7} {'chg dB':>7} {'worst':>6} {'p max':>6} {'p mean':>7} {'gate':>5}")
    results = []
    for label, clean, spans, samples, events in cases:
        xin, cl = frame_db(samples), frame_db(clean)
        talk = cl[: len(xin)] > -45
        for mode in args.modes.split(","):
            y, prob = run_tool(args.tool, samples, mode, args.out)
            for row in score(xin, frame_db(y), prob, talk, events):
                row.update(mode=mode, case=label)
                results.append(row)
                print(f"{mode:9} {row['event'][:28]:28} {row['in_db']:7.1f} {row['out_db']:7.1f} {row['change_db']:7.1f} "
                      f"{row['worst_frame_change_db']:6.1f} {row['prob_max']:6.2f} {row['prob_mean']:7.2f} {row['gate_open']:5.2f}")
    with open(os.path.join(args.out, "results.json"), "w") as fh:
        json.dump(results, fh, indent=1)


if __name__ == "__main__":
    main(sys.argv[1:])
