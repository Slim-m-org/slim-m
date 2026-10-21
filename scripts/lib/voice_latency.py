# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Mouth-to-ear delay from timed chirps: when each left the sender, when each arrived.

Matching each arrival to the latest send before it gives the delay through the real call, jitter buffer included, from taps stamped with one epoch clock.
"""
import statistics
from itertools import accumulate

import make_speech_clip as clip
import voice_quality_dsp as dsp

RATE = dsp.ANALYSIS_RATE
FOUND_AT = 0.35
APART_S = 0.4
MAX_DELAY_MS = 1500.0


def _correlate(signal, template):
    """Raw cross-correlation of `template` against every offset of `signal`."""
    size = 1
    while size < len(signal) + len(template):
        size *= 2
    fs = dsp.fft(list(signal) + [0.0] * (size - len(signal)))
    ft = dsp.fft(list(template) + [0.0] * (size - len(template)))
    back = dsp.fft([a * b.conjugate() for a, b in zip(fs, ft)], inverse=True)
    return [v.real for v in back[:len(signal) - len(template) + 1]]


def find_chirps(signal, rate=RATE):
    """Seconds into `signal` where each marker chirp starts, strongest first pass."""
    template = clip.chirp(rate)
    if len(signal) < len(template):
        return []
    raw = _correlate(signal, template)
    power = [0.0] + list(accumulate(v * v for v in signal))
    span = len(template)
    t_energy = sum(v * v for v in template)
    score = []
    for i, r in enumerate(raw):
        local = power[i + span] - power[i]
        score.append(r / ((t_energy * local) ** 0.5) if local > 1e-9 else 0.0)
    hits = [(s, i) for i, s in enumerate(score) if s > FOUND_AT
            and (i == 0 or s >= score[i - 1])
            and (i + 1 == len(score) or s > score[i + 1])]
    chosen = []
    for s, i in sorted(hits, reverse=True):
        if all(abs(i - j) > APART_S * rate for j in chosen):
            chosen.append(i)
    return sorted(i / rate for i in chosen)


def chirp_epochs_ms(samples, rate, start_epoch_ms):
    """Epoch milliseconds of each chirp in a recording that started at `start_epoch_ms`."""
    return [start_epoch_ms + t * 1000.0
            for t in find_chirps(dsp.decimate(samples, rate))]


def delays_ms(sent, heard, limit=MAX_DELAY_MS):
    """Each arrival minus the latest send before it; later than `limit` is a lost chirp."""
    out = []
    for arrival in heard:
        before = [t for t in sent if t <= arrival]
        if before and arrival - max(before) <= limit:
            out.append(arrival - max(before))
    return out


def summary(values):
    if not values:
        return {"n": 0}
    ordered = sorted(values)
    return {"n": len(ordered), "min": round(ordered[0], 1),
            "median": round(statistics.median(ordered), 1),
            "p95": round(ordered[min(len(ordered) - 1, int(0.95 * len(ordered)))], 1),
            "max": round(ordered[-1], 1)}


def heard_fraction(sent, heard, window_ms):
    """Share of the sends inside the listening window that a chirp answered; None with no sends."""
    inside = [t for t in sent if t + MAX_DELAY_MS <= window_ms[1] and t >= window_ms[0]]
    if not inside:
        return None
    got = sum(1 for t in inside if any(0 <= h - t <= MAX_DELAY_MS for h in heard))
    return round(got / len(inside), 3)
