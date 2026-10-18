# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Kenney edit: the ringback and the self-join, self-leave and deafen cues, cut from CC0 Interface Sounds clips."""
from __future__ import annotations

from fractions import Fraction
from pathlib import Path

import numpy as np
from scipy import signal as sg
from scipy.io import wavfile

from synth import OWN_ACTION_LUFS as OWN, SAMPLE_RATE as SR, loudness

SOURCES = Path(__file__).resolve().parent / "kenney"


def load(name: str) -> np.ndarray:
    rate, clip = wavfile.read(SOURCES / f"{name}.wav")
    assert rate == SR, f"{name} is not {SR} Hz"
    return clip.astype(np.float64)


def shift(x, st, max_denominator=500):
    """Pitch shift by resampling, so duration scales with it."""
    if st == 0:
        return x
    r = Fraction(2 ** (st / 12)).limit_denominator(max_denominator)
    return sg.resample_poly(x, r.denominator, r.numerator)


def highpass(x, hz):
    return sg.sosfilt(sg.butter(2, hz, "highpass", fs=SR, output="sos"), x)


def lowpass(x, hz):
    return sg.sosfilt(sg.butter(2, hz, "lowpass", fs=SR, output="sos"), x)


def peaking(x, f0, gain_db, q):
    a = 10 ** (gain_db / 40)
    w = 2 * np.pi * f0 / SR
    al = np.sin(w) / (2 * q)
    b = [1 + al * a, -2 * np.cos(w), 1 - al * a]
    c = [1 + al / a, -2 * np.cos(w), 1 - al / a]
    return sg.lfilter(b, c, x)


def echo(x, delay, decay, taps):
    out = np.concatenate([x, np.zeros(int(delay * SR * taps) + 1)])
    for k in range(1, taps + 1):
        at = int(delay * SR * k)
        out[at:at + x.size] += x * decay ** k
    return out


def layer(name, st=0, start=0.0, gain=1.0):
    x = lowpass(highpass(shift(load(name), st), 330), 6500)
    a, b = int(0.004 * SR), int(0.008 * SR)
    x[:a] *= np.linspace(0, 1, a) ** 2
    x[-b:] *= np.linspace(1, 0, b)
    return start, x * gain


def mix(layers, length):
    out = np.zeros(int(length * SR))
    for start, x in layers:
        at = int(start * SR)
        n = min(x.size, out.size - at)
        out[at:at + n] += x[:n]
    return out


def edges(x, fin=0.006, fout=0.02):
    x = x - x.mean()
    a, b = int(fin * SR), int(fout * SR)
    x[:a] *= np.linspace(0, 1, a) ** 2
    x[-b:] *= np.linspace(1, 0, b)
    return x


def normalise(x, target):
    y = x * 10 ** ((target - loudness(x)) / 20)
    pk = np.abs(y).max()
    ceil = 10 ** (-1.5 / 20)
    return y * ceil / pk if pk > ceil else y


def to_int16_range(x):
    """Round-trips the 16-bit quantisation the first edit was auditioned at."""
    return np.round(np.clip(x, -1, 1) * 32767).astype("<i2").astype(np.float64) / 32768.0


def fit(x, seconds):
    n = int(seconds * SR)
    return np.pad(x, (0, max(0, n - x.size)))[:n]


def first_edit(name, st, seconds):
    """A pack clip pitched, tailed with two soft echoes and levelled, before the final retune."""
    x = mix([(0, echo(layer(name, st)[1], 0.07, 0.4, 2))], seconds)
    return to_int16_range(normalise(edges(peaking(x, 3500, -3.0, 1.0)), OWN))


def retune(x, st, seconds):
    """Nudges the landing note onto the key and fits the length, as the second audition asked."""
    y = fit(shift(x, st, 2000), seconds)
    y = y - y.mean()
    a, b = int(0.004 * SR), int(0.02 * SR)
    y[:a] *= np.linspace(0, 1, a) ** 2
    y[-b:] *= np.linspace(1, 0, b)
    return normalise(y, OWN)


def ringback():
    rb = mix([layer("glass_001", -8, t, 0.9) for t in (0.0, 0.4)], 3.0)
    x = peaking(rb, 3500, -3.0, 1.0)
    x = x - x.mean()
    x[:48] *= np.linspace(0, 1, 48)
    x[-48:] *= np.linspace(1, 0, 48)
    return normalise(x, OWN)


def render_all() -> dict[str, np.ndarray]:
    return {
        "ringback": ringback(),
        "self_join": retune(first_edit("maximize_008", 10, 0.36), -0.25, 0.36),
        "self_leave": retune(first_edit("minimize_008", 10, 0.36), -0.25, 0.36),
        "deafen_on": retune(first_edit("minimize_006", 14, 0.32), -0.05, 0.32),
        "deafen_off": retune(first_edit("maximize_006", 14, 0.32), -0.05, 0.32),
    }
