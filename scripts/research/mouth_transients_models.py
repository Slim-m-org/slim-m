#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""GTCRN and DTLN on the mouth-noise corpus, scored like mouth_transients_offline.py.

usage: mouth_transients_models.py GTCRN_ONNX DTLN_MODEL_1_ONNX DTLN_MODEL_2_ONNX [--gains -18,-6,0] [--out FILE] [--tool TOOL]
With --tool the fork's strongest_tool runs strong and strongest through the same scoring, as the baseline rows.
Both models are 16 kHz, so each case is resampled 48 to 16 kHz, enhanced frame by frame (causal, as it would run live)
and resampled back. Per event it prints the energy change and the loudest aligned 10 ms frame; per model and case it
prints the speech level change, the word onsets clipped (voice_noise's measure) and the CPU the inference calls took as
a share of one core. Research only: docs/research/mouth-noise-models-2026-11-22.md has the numbers.
"""
import argparse
import json
import os
import sys
import time

import numpy as np
import onnxruntime as ort
from scipy.signal import resample_poly

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mouth_transients_offline as off  # noqa: E402
import voice_noise as vn  # noqa: E402

SPEECH_DB = -45.0
GTCRN_FFT, GTCRN_HOP, DTLN_BLOCK, DTLN_SHIFT = 512, 256, 512, 128


def session(path):
    opts = ort.SessionOptions()
    opts.intra_op_num_threads = opts.inter_op_num_threads = 1
    return ort.InferenceSession(path, opts, providers=["CPUExecutionProvider"])


class Timed:
    """Seconds spent inside inference calls, so numpy framing around them is not counted as model cost."""

    def __init__(self, sess):
        self.sess, self.seconds = sess, 0.0

    def run(self, feed):
        start = time.perf_counter()
        out = self.sess.run(None, feed)
        self.seconds += time.perf_counter() - start
        return out


def gtcrn(x, model):
    window = np.sqrt(np.hanning(GTCRN_FFT + 1)[:-1]).astype(np.float32)
    caches = {"conv_cache": np.zeros((2, 1, 16, 16, 33), np.float32),
              "tra_cache": np.zeros((2, 3, 1, 1, 16), np.float32),
              "inter_cache": np.zeros((2, 1, 33, 16), np.float32)}
    padded = np.concatenate([x, np.zeros(GTCRN_FFT, np.float32)])
    out = np.zeros(len(padded), np.float32)
    for start in range(0, len(x), GTCRN_HOP):
        spec = np.fft.rfft(padded[start:start + GTCRN_FFT] * window)
        feed = {"mix": np.stack([spec.real, spec.imag], -1).astype(np.float32)[None, :, None, :], **caches}
        enh, caches["conv_cache"], caches["tra_cache"], caches["inter_cache"] = model.run(feed)
        frame = enh[0, :, 0, 0] + 1j * enh[0, :, 0, 1]
        out[start:start + GTCRN_FFT] += np.fft.irfft(frame, GTCRN_FFT).astype(np.float32) * window
    return out[:len(x)]


def dtln(x, stage1, stage2):
    state = [np.zeros([d if isinstance(d, int) else 1 for d in m.sess.get_inputs()[1].shape], np.float32)
             for m in (stage1, stage2)]
    names = [[i.name for i in m.sess.get_inputs()] for m in (stage1, stage2)]
    in_buf, out_buf = np.zeros(DTLN_BLOCK, np.float32), np.zeros(DTLN_BLOCK, np.float32)
    out = np.zeros(len(x), np.float32)
    for idx in range((len(x) - (DTLN_BLOCK - DTLN_SHIFT)) // DTLN_SHIFT):
        in_buf[:-DTLN_SHIFT] = in_buf[DTLN_SHIFT:]
        in_buf[-DTLN_SHIFT:] = x[idx * DTLN_SHIFT:(idx + 1) * DTLN_SHIFT]
        spec = np.fft.rfft(in_buf)
        mag = np.abs(spec).astype(np.float32).reshape(1, 1, -1)
        mask, state[0] = stage1.run({names[0][0]: mag, names[0][1]: state[0]})
        block = np.fft.irfft(mag * mask * np.exp(1j * np.angle(spec))).astype(np.float32).reshape(1, 1, -1)
        piece, state[1] = stage2.run({names[1][0]: block, names[1][1]: state[1]})
        out_buf[:-DTLN_SHIFT] = out_buf[DTLN_SHIFT:]
        out_buf[-DTLN_SHIFT:] = 0
        out_buf += piece.reshape(-1)
        out[idx * DTLN_SHIFT:(idx + 1) * DTLN_SHIFT] = out_buf[:DTLN_SHIFT]
    # The block buffer delays the output by block minus shift; undo it so the offline lag search sees whole frames.
    return np.concatenate([out[DTLN_BLOCK - DTLN_SHIFT:], np.zeros(DTLN_BLOCK - DTLN_SHIFT, np.float32)])


def tool_output(tool, samples, mode):
    scratch = os.path.expanduser("~/.slimm-scratch/tmp/mouth-eval/tool")
    os.makedirs(scratch, exist_ok=True)
    return off.run_tool(tool, samples, mode, scratch)[0]


def enhance(samples, fn):
    x16 = resample_poly(np.asarray(samples, np.float64), 1, 3).astype(np.float32)
    y16 = fn(x16)
    return resample_poly(y16.astype(np.float64), 3, 1)[:len(samples)]


class View:
    """What voice_noise._onset_loss reads: frame levels of the clean speech and of the output."""

    def __init__(self, clean, rec):
        self.clean, self.rec, self.frames = clean, rec, min(len(clean), len(rec))


def speech_rows(clean_db, in_db, out_db, spans):
    inside = [i for i in range(min(len(clean_db), len(out_db))) if any(a * 100 <= i < b * 100 for a, b in spans)]
    live = [i for i in inside if clean_db[i] > SPEECH_DB]
    change = off.power_mean(out_db[live]) - off.power_mean(in_db[live])
    view = View(list(clean_db), list(out_db))
    onsets = vn._onset_loss(view, change, inside)
    return round(float(change), 2), onsets["clipped"], onsets["count"]


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("gtcrn")
    parser.add_argument("dtln1")
    parser.add_argument("dtln2")
    parser.add_argument("--clips", default=off.fetch_mouth_noise.DEFAULT_OUT)
    parser.add_argument("--gains", default="-18,-6,0")
    parser.add_argument("--tool")
    parser.add_argument("--out", default=os.path.expanduser("~/.slimm-scratch/tmp/mouth-eval/models.json"))
    args = parser.parse_args(argv)
    g_model, d1, d2 = Timed(session(args.gtcrn)), Timed(session(args.dtln1)), Timed(session(args.dtln2))
    models = {"gtcrn": (lambda x: gtcrn(x, g_model), [g_model]), "dtln": (lambda x: dtln(x, d1, d2), [d1, d2])}
    if args.tool:
        models = {mode: (lambda x, mode=mode: tool_output(args.tool, x, mode), []) for mode in ("strong", "strongest")}
    results, speech_done = [], set()
    for label, clean, spans, samples, events in off.recorded(args.clips, [float(g) for g in args.gains.split(",")]):
        xin, cl = off.frame_db(samples), off.frame_db(clean)
        talk = cl[:len(xin)] > -45
        seconds = len(samples) / off.RATE
        for name, (fn, timers) in models.items():
            before = sum(t.seconds for t in timers)
            y = off.frame_db(fn(samples) if args.tool else enhance(samples, fn))
            cpu_pct = 100 * (sum(t.seconds for t in timers) - before) / seconds
            lag = off.lag_frames(xin[:len(y)][talk[:len(y)]], y[:len(xin)][talk[:len(y)]])
            y = y[lag:]
            m = min(len(xin), len(y))
            # The speech and onset rows do not depend on the clip, so they are measured once per model and gain.
            gain_key = (name, label.split("@")[1])
            if gain_key not in speech_done:
                speech_done.add(gain_key)
                speech, clipped, count = speech_rows(cl, xin, y, spans)
                print(f"{name:6} {gain_key[1]:>6} speech {speech:6.2f} dB  onsets clipped {clipped}/{count}")
                results.append({"model": name, "gain": gain_key[1], "speech_change_db": speech,
                                "onsets_clipped": clipped, "onsets": count})
            for ev, start, end in events:
                sel = np.arange(int(start * 100), min(m, int(end * 100)))
                sel = sel[xin[sel] > -55]
                if not len(sel):
                    continue
                pin, pout = off.power_mean(xin[sel]), off.power_mean(y[sel])
                row = {"model": name, "event": ev, "in_db": round(pin, 1), "out_db": round(pout, 1),
                       "change_db": round(pout - pin, 1),
                       "worst_frame_change_db": round(float((y[sel] - xin[sel]).max()), 1), "cpu_pct": round(cpu_pct, 1)}
                results.append(row)
                print(f"{name:6} {ev[:28]:28} {row['in_db']:7.1f} {row['out_db']:7.1f} {row['change_db']:7.1f} "
                      f"{row['worst_frame_change_db']:6.1f} cpu {cpu_pct:4.1f}%")
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w") as fh:
        json.dump(results, fh, indent=1)


if __name__ == "__main__":
    main(sys.argv[1:])
