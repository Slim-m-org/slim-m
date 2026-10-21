# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Absolute loudness of a received call recording against its reference clip.

`level_burst` compares frame by frame, so a word shifted by tens of milliseconds reads as a burst; this asks whether anything came out louder than the loudest the sender ever said.

usage: voice_burst_abs.py <harness output dir>   (reads <profile>/<who>-rx.wav)
"""
import json
import math
import os
import sys

import voice_quality_dsp as dsp

WINDOW_MS = 50
LOUD_MARGIN_DB = 3.0
SENDER = {"vqa": "B", "vqb": "A"}


def _short_term_db(samples, rate):
    step = max(1, int(rate * WINDOW_MS / 1000))
    return [dsp.rms_db(samples[i:i + step])
            for i in range(0, len(samples) - step + 1, step)]


def _peak_db(samples):
    top = max((abs(s) for s in samples), default=0.0)
    return 20.0 * math.log10(top) if top > 0 else dsp.FLOOR_DB


def measure(ref, ref_rate, rec, rec_rate):
    """Peak and 50 ms loudness of `rec` relative to the loudest of `ref`."""
    ref_max = max(_short_term_db(ref, ref_rate))
    rec_levels = _short_term_db(rec, rec_rate)
    return {
        "peak_over_ref_db": round(_peak_db(rec) - _peak_db(ref), 2),
        "short_term_over_ref_db": round(max(rec_levels) - ref_max, 2),
        "loud_windows": sum(1 for v in rec_levels if v > ref_max + LOUD_MARGIN_DB),
    }


def scan(directory):
    refs = {who: dsp.read_wav(os.path.join(directory, f"clip-{who}.wav")) for who in "AB"}
    out = {}
    for profile in sorted(os.listdir(directory)):
        folder = os.path.join(directory, profile)
        if not os.path.isdir(folder):
            continue
        for who, sender in SENDER.items():
            path = os.path.join(folder, f"{who}-rx.wav")
            if os.path.exists(path):
                rec, rate = dsp.read_wav(path)
                out.setdefault(profile, {})[who] = measure(*refs[sender], rec, rate)
    return out


if __name__ == "__main__":
    print(json.dumps(scan(sys.argv[1]), indent=2))
