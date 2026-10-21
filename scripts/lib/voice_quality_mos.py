# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Objective quality scores per received recording: ViSQOL (full reference) and DNSMOS (none).

usage: voice_quality_mos.py <variant-dir>

ViSQOL (speech mode, 16 kHz) runs from the docker image built by `docker build -f scripts/lib/visqol.Dockerfile -t slimm-visqol:local scripts/lib`.
DNSMOS (the `speechmos` package) needs a venv python with numpy, scipy, onnxruntime, librosa and speechmos, e.g. ~/.slimm-scratch/mos-venv; either score is skipped when its tool is missing.
"""
import csv
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import voice_quality_align as align
import voice_quality_dsp as dsp
from work_roots import ROOTS

RATE = dsp.ANALYSIS_RATE
MIN_RUN_S = 3.0
SENDER = {"vqa": "B", "vqb": "A"}


def speech_mask(ref16):
    """1.0 where the reference is talking, 0.0 elsewhere; gaps under 1 s count as talking."""
    hop, floor, bridge = dsp.HOP, -42.0, int(1.0 * RATE / dsp.HOP)
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


def _dnsmos_pairs(rec16, expected, spans):
    """DNSMOS of the recording and of the reference per span; empty when speechmos is missing."""
    try:
        return ([_dnsmos(rec16[a:b]) for a, b in spans],
                [_dnsmos(expected[a:b]) for a, b in spans])
    except ImportError:
        print("  DNSMOS skipped: speechmos is not installed", flush=True)
        return [], []


def _mean(rows, key):
    return round(sum(r[key] for r in rows) / len(rows), 3) if rows else None


VISQOL_IMAGE = os.environ.get("E2E_VISQOL_IMAGE", "slimm-visqol:local")


def parse_visqol_csv(text, count):
    """MOS-LQO per pair index, matched on the degraded file name; None where ViSQOL gave no row."""
    found = {}
    for row in csv.DictReader(io.StringIO(text)):
        name = os.path.basename(row["degraded"])
        if name.startswith("deg") and name.endswith(".wav") and name[3:-4].isdigit():
            found[int(name[3:-4])] = float(row["moslqo"])
    return [found.get(i) for i in range(count)]


def visqol_scores(pairs):
    """MOS-LQO per `(reference, degraded)` pair of 16 kHz sample lists; None without the image."""
    have = shutil.which("docker") and subprocess.run(
        ["docker", "image", "inspect", VISQOL_IMAGE], capture_output=True).returncode == 0
    if not have or not pairs:
        return None
    with tempfile.TemporaryDirectory(prefix="visqol-") as work:
        lines = ["reference,degraded"]
        for i, (ref, deg) in enumerate(pairs):
            for kind, samples in (("ref", ref), ("deg", deg)):
                dsp.write_wav(os.path.join(work, f"{kind}{i}.wav"), list(samples), RATE)
            lines.append(f"/work/ref{i}.wav,/work/deg{i}.wav")
        with open(os.path.join(work, "in.csv"), "w") as fh:
            fh.write("\n".join(lines) + "\n")
        subprocess.run(
            ["docker", "run", "--rm", "--user", f"{os.getuid()}:{os.getgid()}", "-v", f"{work}:/work", VISQOL_IMAGE,
             "/visqol/bazel-bin/visqol", "--batch_input_csv", "/work/in.csv",
             "--results_csv", "/work/out.csv", "--use_speech_mode"],
            check=True, capture_output=True)
        with open(os.path.join(work, "out.csv")) as fh:
            return parse_visqol_csv(fh.read(), len(pairs))


def score(ref_samples, ref_rate, rec_samples, rec_rate):
    """ViSQOL and DNSMOS for the received speech, DNSMOS also for the aligned reference."""
    if not len(rec_samples):
        raise ValueError("the recording is empty")
    ref16, rec16 = _resample(ref_samples, ref_rate), _resample(rec_samples, rec_rate)
    spans, expected = aligned_runs(ref16.tolist(), rec16.tolist())
    got, want = _dnsmos_pairs(rec16, expected, spans)
    try:
        visqol = visqol_scores([(expected[a:b], rec16[a:b].tolist()) for a, b in spans])
    except subprocess.CalledProcessError as err:
        print(f"  ViSQOL failed: {(err.stderr or b'').decode(errors='replace')[-300:]}", flush=True)
        visqol = None
    visqol = [v for v in visqol or [] if v is not None]
    ovr_rec, ovr_ref = _mean(got, "ovrl_mos"), _mean(want, "ovrl_mos")
    return {"segments": len(spans), "ovrl": ovr_rec, "ovrl_reference": ovr_ref,
            "ovrl_delta": None if ovr_rec is None or ovr_ref is None else round(ovr_rec - ovr_ref, 3),
            "sig": _mean(got, "sig_mos"), "bak": _mean(got, "bak_mos"),
            "p808": _mean(got, "p808_mos"),
            "visqol": round(sum(visqol) / len(visqol), 3) if visqol else None}


def score_directory(directory):
    """Adds a `mos` block to every side in `results.json` and saves it back."""
    directory = Path(directory).resolve()
    if not any(directory.is_relative_to(root) for root in ROOTS):
        raise SystemExit(f"{directory}: outside the work directories")
    directory = str(directory)
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
            try:
                report["mos"] = score(ref, ref_rate, rec, rate)
            except (ValueError, ZeroDivisionError, OSError) as err:
                report["mos"] = {"error": str(err) or type(err).__name__}
            print(f"  {profile:18} {who} {report['mos']}", flush=True)
        with open(path, "w") as fh:
            json.dump(results, fh, indent=2)


if __name__ == "__main__":
    score_directory(sys.argv[1])
