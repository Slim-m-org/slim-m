# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""An objective quality score (DNSMOS) per received recording.

usage: voice_quality_mos.py <variant-dir>

ViSQOL needs a bazel build of google/visqol that does not fit a pip venv, so
this uses Microsoft's no-reference DNSMOS (the `speechmos` package, models
bundled) from the venv at ~/.slimm-scratch/mos-venv. The reference clips are
synthetic, so DNSMOS scores them low; the number that matters is the
received score next to the same speech cut from the aligned reference.
Run it with that venv's python: it needs numpy, scipy, onnxruntime, librosa.
"""
import json
import os
import sys

import voice_quality_align as align
import voice_quality_dsp as dsp

RATE = dsp.ANALYSIS_RATE
MIN_RUN_S = 3.0
SENDER = {"vqa": "B", "vqb": "A"}


def speech_mask(ref16):
    """1.0 where the reference is talking, 0.0 elsewhere; gaps under 0.4 s count as talking."""
    hop, floor, bridge = dsp.HOP, -42.0, int(0.4 * RATE / dsp.HOP)
    active = [dsp.rms_db(ref16[s:s + hop]) > floor for s in range(0, len(ref16), hop)]
    last = None
    for i, flag in enumerate(active):
        if flag:
            if last is not None and 0 < i - last <= bridge:
                active[last:i] = [True] * (i - last)
            last = i
    return [1.0 if a else 0.0 for a in active for _ in range(hop)][:len(ref16)]


def runs(mask, min_len):
    """`(start, end)` sample spans of consecutive mask values above half, at least `min_len` long."""
    spans, start = [], None
    for i, v in enumerate(mask):
        if v > 0.5 and start is None:
            start = i
        elif v <= 0.5 and start is not None:
            spans.append((start, i))
            start = None
    if start is not None:
        spans.append((start, len(mask)))
    return [s for s in spans if s[1] - s[0] >= min_len]


def aligned_runs(ref16, rec16):
    """Speech spans of `rec16` plus the reference audio aligned to the same samples."""
    starts, lags = align.track(ref16, rec16)
    expected = align.expected_signal(ref16, len(rec16), starts, lags)
    mask = align.expected_signal(speech_mask(ref16), len(rec16), starts, lags)
    return runs(mask, int(MIN_RUN_S * RATE)), expected


def _resample(samples, rate):
    from scipy.signal import resample_poly
    import numpy as np
    from math import gcd
    g = gcd(rate, RATE)
    return np.clip(resample_poly(np.asarray(samples, dtype=float), RATE // g, rate // g), -1, 1)


def _dnsmos(audio):
    import numpy as np
    from speechmos import dnsmos
    out = dnsmos.run(np.asarray(audio, dtype="float32"), RATE)
    return {k: float(out[k]) for k in ("ovrl_mos", "sig_mos", "bak_mos", "p808_mos")}


def _mean(rows, key):
    return round(sum(r[key] for r in rows) / len(rows), 3) if rows else None


def score(ref_samples, ref_rate, rec_samples, rec_rate):
    """DNSMOS for the received speech and the same speech from the reference."""
    ref16, rec16 = _resample(ref_samples, ref_rate), _resample(rec_samples, rec_rate)
    spans, expected = aligned_runs(ref16.tolist(), rec16.tolist())
    got = [_dnsmos(rec16[a:b]) for a, b in spans]
    want = [_dnsmos(expected[a:b]) for a, b in spans]
    ovr_rec, ovr_ref = _mean(got, "ovrl_mos"), _mean(want, "ovrl_mos")
    return {"segments": len(spans), "ovrl": ovr_rec, "ovrl_reference": ovr_ref,
            "ovrl_delta": None if ovr_rec is None else round(ovr_rec - ovr_ref, 3),
            "sig": _mean(got, "sig_mos"), "bak": _mean(got, "bak_mos"),
            "p808": _mean(got, "p808_mos")}


def score_directory(directory):
    """Adds a `mos` block to every side in `results.json` and saves it back."""
    refs = {who: dsp.read_wav(os.path.join(directory, f"clip-{who}.wav")) for who in "AB"}
    path = os.path.join(directory, "results.json")
    with open(path) as fh:
        results = json.load(fh)
    for profile, sides in results.items():
        for who, report in sides.items():
            wav = os.path.join(directory, profile, f"{who}-rx.wav")
            if not os.path.exists(wav):
                continue
            rec, rate = dsp.read_wav(wav)
            sender = SENDER[who]
            ref, ref_rate = refs[sender]
            report["mos"] = score(ref, ref_rate, rec, rate)
            print(f"  {profile:18} {who} {report['mos']}", flush=True)
    with open(path, "w") as fh:
        json.dump(results, fh, indent=2)


if __name__ == "__main__":
    score_directory(sys.argv[1])
